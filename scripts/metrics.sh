#!/usr/bin/env bash
# The stack's metrics collector: the numbers no daemon exports, written as a
# Prometheus textfile for node-exporter to serve.
#
#   scripts/metrics.sh            # collect, write, print what was written
#   scripts/metrics.sh --quiet    # no stdout (what deploy/metrics.service runs)
#
# Driven by deploy/metrics.timer every minute. This is the *observation* half of
# the monitoring pair, and the split is deliberate:
#
#   * scripts/monitor.sh DECIDES and NOTIFIES -- it reads the daemons directly
#     and never queries the store, so the metrics pipeline can be down without
#     the alerts going with it, and an alert needs no query engine to be
#     healthy;
#   * this script only OBSERVES, for history: how fast a chain synced, when the
#     Monero RPC wedged, how the wallet's lag moved. It never alerts.
#
# A metric that cannot be collected is omitted and its collector is recorded as
# stack_collector_error{collector="..."} 1, so a hole in a graph is never
# mistaken for a zero. stack_metrics_timestamp is always written, and
# scripts/monitor.sh alerts on it going stale -- a silently dead timer is the
# one failure this pipeline cannot report about itself.
#
# Output goes to $DATA_DIR/monitoring/textfile/stack.prom atomically. The
# directory is 0755 and the file 0644 on purpose: node-exporter runs as uid
# 65534, a subuid that owns nothing here, and a permissions slip is the
# quietest possible way to lose every metric (README: "Monitoring and metrics").
#
# scripts/monitor.sh writes the *other* textfile, monitor.prom, with the
# numbers it has to compute anyway (backup age, spend trips, verify failures).
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)     QUIET=1 ;;
        -h|--help)   usage_header "$0"; exit 0 ;;
        *)           die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

resolve_data_dir
TEXTFILE_DIR="$DATA_DIR/monitoring/textfile"
TARGET="$TEXTFILE_DIR/stack.prom"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# The body, built in memory and written once at the end by prom_write (lib.sh),
# which owns the 0755/0644 permissions node-exporter's uid needs.
BODY=""
emit() { BODY+="$1 $2"$'\n'; }

# A collector that could not read its source: visible as a series rather than as
# a silent hole, and named so the graph says which one broke.
collector_error() { emit "stack_collector_error{collector=\"$1\"}" 1; }

# ---------------------------------------------------------------------------
# bitcoind -- the chain's own view, which is what makes "is it syncing?" and
# "how far behind?" answerable over time. verificationprogress is a float.
# ---------------------------------------------------------------------------
btc=""
if btc=$(podman exec bitcoind bitcoin-cli getblockchaininfo 2>/dev/null) && [ -n "$btc" ]; then
    emit stack_btc_blocks "$(jq -r '.blocks' <<<"$btc")"
    emit stack_btc_headers "$(jq -r '.headers' <<<"$btc")"
    emit stack_btc_progress "$(jq -r '.verificationprogress' <<<"$btc")"
    # 1/0 rather than a boolean: PromQL compares numbers, and the sync grace in
    # monitor.sh keys off the same thing.
    emit stack_btc_ibd "$(jq -r 'if .initialblockdownload then 1 else 0 end' <<<"$btc")"
    say "bitcoind $(jq -r '.blocks' <<<"$btc")/$(jq -r '.headers' <<<"$btc")"
else
    collector_error bitcoind
    say "bitcoind RPC unreachable"
fi

# ---------------------------------------------------------------------------
# bitcoind -- the mempool and the peers, the two reads that a *synced* node
# makes interesting: how close the mempool sits to its cap (bitcoin.conf's
# maxmempool; a fee storm fills it long before anything else in the stack
# degrades) and whether the node is actually peered (a node answering RPC on
# zero peers is exactly the silent-stalling failure class CLN's check below
# is about; during IBD zero peers means stalled, so the grace is not applied).
# ---------------------------------------------------------------------------
if mp=$(podman exec bitcoind bitcoin-cli getmempoolinfo 2>/dev/null) && [ -n "$mp" ]; then
    emit stack_btc_mempool_bytes "$(jq -r '.bytes' <<<"$mp")"
    emit stack_btc_mempool_txs "$(jq -r '.size' <<<"$mp")"
else
    collector_error bitcoind-mempool
fi
if peers=$(podman exec bitcoind bitcoin-cli getpeerinfo 2>/dev/null) && [ -n "$peers" ]; then
    emit stack_btc_peers "$(jq -r 'length' <<<"$peers")"
else
    collector_error bitcoind-peers
fi

# ---------------------------------------------------------------------------
# fulcrum -- the process (the container's own healthcheck), the Electrum surface,
# and how far its index has actually got. The tip is asked of the server over
# 50001 rather than scraped from `podman logs`: Fulcrum prints "Processed height:
# N, X%" only at 1% steps, so once it has caught up `--tail 200` legitimately
# holds no line and the scrape reported a stale height indefinitely.
#
# stack_fulcrum_up and stack_fulcrum_electrum_up disagree in the case that
# matters: a healthy process with a wedged index answers server.version all day.
# No collector_error here -- a first-run index answers nothing on 50001 for days,
# and that is a state to graph (up=0, lag growing), not a broken collector.
# ---------------------------------------------------------------------------
if podman inspect -f '{{.State.Health.Status}}' fulcrum 2>/dev/null | grep -qx healthy; then
    emit stack_fulcrum_up 1
else
    emit stack_fulcrum_up 0
fi
if ftip=$(electrum_tip 50001) && [ -n "$ftip" ]; then
    emit stack_fulcrum_electrum_up 1
    emit stack_fulcrum_electrum_tip "$ftip"
    # btc_blocks is only present when bitcoind answered above; without it there is
    # nothing to compare the tip with, so the lag series is omitted, not zeroed.
    if [ -n "${btc:-}" ]; then
        bblocks=$(jq -r '.blocks // empty' <<<"$btc" 2>/dev/null || true)
        [ -n "$bblocks" ] && emit stack_fulcrum_lag_blocks "$((bblocks - ftip))"
    fi
    say "fulcrum tip $ftip"
else
    emit stack_fulcrum_electrum_up 0
    say "fulcrum is not answering Electrum on 50001"
fi

# ---------------------------------------------------------------------------
# lightningd -- RPC up, peers, offline channels, and the warning it raises when
# its view of bitcoind is stale (the state CLN sits in while a rewound backend
# catches up; README "Full nodes and disk").
# ---------------------------------------------------------------------------
ln=""
if ln=$(podman exec lightningd lightning-cli getinfo 2>/dev/null) && [ -n "$ln" ]; then
    emit stack_cln_rpc_up 1
    # Connected peers, not getinfo's num_peers: that one is documented as "the
    # total count of peers, connected or with channels", so it stays >= 1 for a
    # node whose only peer is offline and the series would read as healthy.
    lpeers=$(podman exec lightningd lightning-cli listpeers 2>/dev/null || echo '{"peers":[]}')
    emit stack_cln_peers \
        "$(jq -r '[.peers[] | select(.connected)] | length' <<<"$lpeers" 2>/dev/null || echo 0)"
    # Present only while the condition holds, so test for the key rather than
    # its value.
    emit stack_cln_bitcoind_sync_warning \
        "$(jq -r 'if has("warning_bitcoind_sync") then 1 else 0 end' <<<"$ln")"
    # The node's own channels, with each peer's connection state: listchannels is
    # the gossip table and has no connectivity field (see scripts/monitor.sh), so
    # this reads listpeerchannels and counts only operational ones.
    pchans=$(podman exec lightningd lightning-cli listpeerchannels 2>/dev/null || echo '{"channels":[]}')
    emit stack_cln_channels_offline \
        "$(jq -r '[.channels[] | select(.state == "CHANNELD_NORMAL" and .peer_connected == false)] | length' <<<"$pchans" 2>/dev/null || echo 0)"
    say "lightningd $(jq -r '[.peers[] | select(.connected)] | length' <<<"$lpeers" 2>/dev/null || echo 0) connected peer(s)"
else
    emit stack_cln_rpc_up 0
    collector_error lightningd
    say "lightningd RPC unreachable"
fi

# ---------------------------------------------------------------------------
# monerod -- height and whether its restricted RPC answers at all. The RPC *
# *blocks for minutes while the daemon syncs**, so this is the series that
# explains a dead Monero MCP surface, the xmr-explorer home page timing out and
# monero-wallet-rpc's health flipping: none of those fail on their own.
#
# Read with curl *inside* the container (the image ships one) rather than
# through a netcheck run, so a wedged RPC costs one short exec, not a container
# start, every minute.
# ---------------------------------------------------------------------------
xnode=""
if xnode=$(podman exec monerod curl -s -m 5 http://127.0.0.1:18089/get_height 2>/dev/null) \
    && [ -n "$xnode" ] && jq -e '.height' <<<"$xnode" >/dev/null 2>&1; then
    emit stack_xmr_rpc_up 1
    emit stack_xmr_height "$(jq -r '.height' <<<"$xnode")"
    # The lag behind the network tip: target_height only reaches the RPC through
    # get_info (get_height above does not carry it), which is why this is a
    # second read rather than more of the first. Omitted, not zeroed, when
    # get_info does not answer within the same budget -- a hole keeps a wedge
    # visible, a zero would erase it. This is the daemon-side lag; the wallet's
    # lag below subtracts from `height`, the local tip.
    if xinfo=$(podman exec monerod curl -s -m 5 http://127.0.0.1:18089/get_info 2>/dev/null) \
        && jq -e '.height and .target_height and (.target_height >= .height)' <<<"$xinfo" >/dev/null 2>&1; then
        emit stack_xmr_lag "$(( $(jq -r '.target_height' <<<"$xinfo") - $(jq -r '.height' <<<"$xinfo") ))"
    fi
    say "monerod $(jq -r '.height' <<<"$xnode")"
else
    emit stack_xmr_rpc_up 0
    collector_error monerod
    say "monerod restricted RPC did not answer in 5s"
fi

# ---------------------------------------------------------------------------
# the Monero wallet -- height and lag behind the node. This goes through the MCP
# server (mcp_call, a netcheck run on npm-network) because monero-wallet-rpc
# wants digest auth and the MCP server already holds the credential.
# ---------------------------------------------------------------------------
wtoken=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
if [ -n "$wtoken" ]; then
    wbody=$(mcp_call monero-wallet-mcp "$wtoken" get_height '{}' 8) || wbody=""
    wh=$(printf '%s' "$wbody" | grep -oE '\\?"height\\?":[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$' | head -n1)
    if [ -n "$wh" ]; then
        emit stack_xmr_wallet_height "$wh"
        if [ -n "${xnode:-}" ] && jq -e '.height' <<<"$xnode" >/dev/null 2>&1; then
            emit stack_xmr_wallet_lag "$(( $(jq -r '.height' <<<"$xnode") - wh ))"
        fi
        say "monero-wallet $wh"
    else
        collector_error monero-wallet
        say "monero-wallet-mcp get_height returned nothing"
    fi
else
    say "no MONERO_MCP_TOKEN; skipped the wallet height"
fi

# ---------------------------------------------------------------------------
# systemd -- the restart counter of every unit that is managing a running
# container, read straight off the user manager. monitor.sh pages on the
# *delta* between its sweeps; this is the monotonic counter for the graph, so
# "when did it start crash-looping and did it stop" is a query, not a scroll
# through the journal. Units that are not running (deleted, failed and never
# restarted) are simply absent, as podman ps does not know them.
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    while read -r cname; do
        [ -n "$cname" ] || continue
        nr=$(systemctl --user show "$cname.service" -p NRestarts --value 2>/dev/null) || continue
        case "$nr" in (*[!0-9]*) continue ;; esac
        emit "stack_systemd_restarts{unit=\"$cname\"}" "$nr"
    done < <(podman ps --format '{{.Names}}' 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# the file itself
# ---------------------------------------------------------------------------
# A fresh timestamp on every successful write, so monitor.sh can tell "the
# timer died" from "the values are unchanged".
emit stack_metrics_timestamp "$(date +%s)"

printf '%s' "$BODY" | prom_write "$TARGET" || die "cannot write $TARGET"

say ""
say "wrote $TARGET ($(printf '%s' "$BODY" | grep -cv '^#') series)"
