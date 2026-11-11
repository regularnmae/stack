#!/usr/bin/env bash
# The stack's metrics collector: the numbers no daemon exports, written as a
# Prometheus textfile for node-exporter to serve.
#
#   scripts/metrics.sh            # collect, write, print what was written
#   scripts/metrics.sh --quiet    # no stdout (what deploy/metrics.service runs)
#
# Driven by metrics.timer every minute. This is the *observation* half of the
# monitoring pair: monitor.sh decides what is wrong and writes the facts,
# reading the daemons directly and never the store, so the checks survive a
# wedged pipeline; vmalert evaluates the rules against the store, and this
# script only observes, for history, and never alerts.
#
# A metric that cannot be collected is omitted and its collector recorded as
# stack_collector_error{collector="..."} 1, so a hole in a graph is never mistaken
# for a zero. stack_metrics_timestamp is always written, and monitor.sh alerts on
# it going stale: a silently dead timer is the one failure this pipeline cannot
# report about itself.
#
# Output goes to $DATA_DIR/monitoring/textfile/stack.prom atomically. The
# directory is 0755 and the file 0644 because node-exporter runs as uid 65534 (a
# subuid that owns nothing here), and a permissions slip is the quietest way to
# lose every metric. monitor.sh writes the other textfile, monitor.prom.
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
if btc=$(bitcoind_cli getblockchaininfo 2>/dev/null) && [ -n "$btc" ]; then
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
# bitcoind -- the mempool and the peers: how close the mempool sits to its cap (a
# fee storm fills it long before anything else degrades) and whether the node is
# actually peered. Zero peers while synced is the silent-stalling failure class;
# during IBD it means stalled, so the grace is not applied.
# ---------------------------------------------------------------------------
if mp=$(bitcoind_cli getmempoolinfo 2>/dev/null) && [ -n "$mp" ]; then
    emit stack_btc_mempool_bytes "$(jq -r '.bytes' <<<"$mp")"
    emit stack_btc_mempool_txs "$(jq -r '.size' <<<"$mp")"
else
    collector_error bitcoind-mempool
fi
if peers=$(bitcoind_cli getpeerinfo 2>/dev/null) && [ -n "$peers" ]; then
    emit stack_btc_peers "$(jq -r 'length' <<<"$peers")"
else
    collector_error bitcoind-peers
fi

# ---------------------------------------------------------------------------
# fulcrum -- the process, the Electrum surface, and how far its index has got. The
# tip is asked over 50001 rather than scraped from `podman logs`: Fulcrum prints
# "Processed height: N, X%" only at 1% steps, so once caught up a `--tail 200`
# legitimately holds no line. stack_fulcrum_up and stack_fulcrum_electrum_up
# disagree in the case that matters: a healthy process with a wedged index answers
# server.version all day. No collector_error here -- a first-run index answers
# nothing for days, which is a state to graph (up=0, lag growing).
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
# lightningd -- RPC up, peers, offline channels, and the warning it raises when its
# view of bitcoind is stale (the state CLN sits in while a rewound backend catches
# up; docs/chains.md).
# ---------------------------------------------------------------------------
ln=""
if ln=$(lightning_cli getinfo 2>/dev/null) && [ -n "$ln" ]; then
    emit stack_cln_rpc_up 1
    # Connected peers, not getinfo's num_peers: that one is documented as "the
    # total count of peers, connected or with channels", so it stays >= 1 for a
    # node whose only peer is offline and the series would read as healthy.
    # A failed listpeers/listpeerchannels is a HOLE, not an empty list: a
    # `{"peers":[]}` fallback would turn an unreachable node into a healthy zero
    # and write no collector_error.
    npeers=""
    if lpeers=$(lightning_cli listpeers 2>/dev/null) && [ -n "$lpeers" ]; then
        npeers=$(jq -r '[.peers[] | select(.connected)] | length' <<<"$lpeers" 2>/dev/null) || npeers=""
    fi
    case "$npeers" in
        ''|*[!0-9]*) collector_error lightningd-peers ;;
        *)           emit stack_cln_peers "$npeers" ;;
    esac
    # Present only while the condition holds, so test for the key rather than
    # its value.
    emit stack_cln_bitcoind_sync_warning \
        "$(jq -r 'if has("warning_bitcoind_sync") then 1 else 0 end' <<<"$ln")"
    # The node's own channels, with each peer's connection state: listchannels is
    # the gossip table and has no connectivity field (see scripts/monitor.sh), so
    # this reads listpeerchannels and counts only operational ones.
    noff=""
    if pchans=$(lightning_cli listpeerchannels 2>/dev/null) && [ -n "$pchans" ]; then
        noff=$(jq -r '[.channels[] | select(.state == "CHANNELD_NORMAL" and .peer_connected == false)] | length' <<<"$pchans" 2>/dev/null) || noff=""
    fi
    case "$noff" in
        ''|*[!0-9]*) collector_error lightningd-channels ;;
        *)           emit stack_cln_channels_offline "$noff" ;;
    esac
    say "lightningd ${npeers:-?} connected peer(s)"
else
    emit stack_cln_rpc_up 0
    collector_error lightningd
    say "lightningd RPC unreachable"
fi

# ---------------------------------------------------------------------------
# monerod -- height and whether its restricted RPC answers at all. The RPC *blocks
# for minutes while the daemon syncs*, so this series explains a dead Monero MCP
# surface, the explorer home page timing out and the BTCPay wallet's health
# flipping: none of those fail on their own.
#
# Read with curl *inside* the container rather than through a netcheck run, so a
# wedged RPC costs one short exec, not a container start, every minute. The unit's
# own probe is the process for that reason: this is the history half, and
# monitor.sh says whether the RPC answers at all.
# ---------------------------------------------------------------------------
xnode=""
if xnode=$(monerod_rpc get_height 2>/dev/null) \
    && [ -n "$xnode" ] && jq -e '.height' <<<"$xnode" >/dev/null 2>&1; then
    emit stack_xmr_rpc_up 1
    emit stack_xmr_height "$(jq -r '.height' <<<"$xnode")"
    # The lag behind the network tip: target_height only reaches the RPC through
    # get_info (get_height above does not carry it), which is why this is a
    # second read rather than more of the first. Omitted, not zeroed, when
    # get_info does not answer within the same budget -- a hole keeps a wedge
    # visible, a zero would erase it. This is the daemon-side lag; the wallet's
    # lag below subtracts from `height`, the local tip.
    if xinfo=$(monerod_rpc get_info 2>/dev/null) \
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
# the BTCPay Monero wallet -- height and lag behind the node, through the MCP
# server (mcp_call, a netcheck run on npm-network), which reads the plugin's
# view-only wallet. Before it is imported there is nothing to report.
# ---------------------------------------------------------------------------
wtoken=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
if [ -n "$wtoken" ] && [ -f "$DATA_DIR/btcpay/xmr-wallet/wallet.keys" ]; then
    wbody=$(mcp_call monero-wallet-mcp "$wtoken" get_height '{}' 8) || wbody=""
    wh=$(mcp_result "$wbody" | jq -r '.height // empty' 2>/dev/null)
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
# systemd -- the restart counter of every unit managing a running container, read
# off the user manager. monitor.sh pages on the *delta* between sweeps; this is the
# monotonic counter for the graph, so "when did it start crash-looping and did it
# stop" is a query, not a scroll through the journal. Units that are not running
# are absent, as podman ps does not know them.
# ---------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    while read -r cname; do
        [ -n "$cname" ] || continue
        # The container name is not always the unit stem (backup.container sets
        # ContainerName=stack-backup under backup.service), and `systemctl show
        # stack-backup.service` answers 0 like a real unit.
        unit=$(unit_for_container "$cname")
        nr=$(systemctl --user show "$unit.service" -p NRestarts --value 2>/dev/null) || continue
        [ -n "$nr" ] || continue
        case "$nr" in (*[!0-9]*) continue ;; esac
        emit "stack_systemd_restarts{unit=\"$unit\"}" "$nr"
    done < <(podman ps --format '{{.Names}}' 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# containers -- what each running unit actually costs. One `podman stats
# --no-stream` call reads the cgroup counters for the whole stack, which is the
# only place they exist: no daemon exports its resource use, and node-exporter's
# cpu collector is host-wide. The shape is deliberate:
#   * cpu_time is cumulative -> a *_total counter, so the query is rate().
#     cpu_percent is NOT written: on --no-stream it is a one-shot reading over an
#     unknown interval, not comparable across scrapes.
#   * mem_usage is podman's working set (memory.current - inactive_file), not RSS,
#     hence the name. Sizes inherit podman's 4-significant-digit rendering: right
#     for a graph, and the exact values are in the cgroup.
#   * block_io reads 0B/0B on every container here -- the io controller does not
#     account under rootless cgroups -- so it is not exported at all.
#   * the label is the container NAME, never the id: a recreated container keeps
#     its series and rate() sees the counter reset instead of a new series.
#
# A hole stays a hole: an unparsable field is omitted, with one collector_error
# naming the parse and no per-container label (that would explode cardinality on
# a bad podman release). The two fields are independent.
# ---------------------------------------------------------------------------

# podman prints cpu_time as a Go duration ("47m45.158824s"), and lib.sh's dur_ms
# already parses those -- one parser, so a fraction cannot disagree with
# wait_healthy. Its floor is a millisecond, which rate() tolerates. An unparsable
# field ("N/A") is rejected by dur_valid before it gets here: dur_ms answers 0 for
# it too, and that is not the same thing.
cpu_seconds() { awk -v ms="$(dur_ms "$1")" 'BEGIN { printf "%.3f", ms / 1000 }'; }

if cstats=$(podman stats --no-stream --format json 2>/dev/null) \
    && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$cstats"; then
    cbad=0
    while IFS=$'\t' read -r cname cputime cmem cpids cnet; do
        [ -n "$cname" ] || continue
        # The label is written into the exposition text, so refuse anything that
        # is not a container-name character rather than emit a broken line.
        case "$cname" in
            *[!A-Za-z0-9_.-]*) cbad=1; continue ;;
        esac
        csecs=""
        # dur_valid, not just non-empty: dur_ms answers 0 for junk, so podman's
        # cpu_time: "N/A" would be written as a real 0.000 instead of a hole.
        if [ -n "$cputime" ] && dur_valid "$cputime"; then
            csecs=$(cpu_seconds "$cputime")
        fi
        cmem_b=$(human_bytes "$cmem") || cmem_b=""
        # Emit each half independently: a broken CPU reading must not also erase
        # the memory series, but either missing value is recorded as a parse
        # error (and never written as a zero).
        if [ -n "$csecs" ]; then
            emit "stack_container_cpu_seconds_total{container=\"$cname\"}" "$csecs"
        else
            cbad=1
        fi
        if [ -n "$cmem_b" ]; then
            emit "stack_container_mem_working_set_bytes{container=\"$cname\"}" "$cmem_b"
        else
            cbad=1
        fi
        case "$cpids" in
            ''|*[!0-9]*) cbad=1 ;;
            *) emit "stack_container_pids{container=\"$cname\"}" "$cpids" ;;
        esac
        # rx / tx, both cumulative for the container's lifetime. A container on
        # the host network legitimately reports 0B/0B (no veth), which is a real
        # value, not a missing one.
        crx="" tx=""
        case "$cnet" in
            *" / "*)
                crx=$(human_bytes "${cnet%% / *}") || crx=""
                tx=$(human_bytes "${cnet##* / }") || tx=""
                ;;
        esac
        if [ -n "$crx" ] && [ -n "$tx" ]; then
            emit "stack_container_network_receive_bytes_total{container=\"$cname\"}" "$crx"
            emit "stack_container_network_transmit_bytes_total{container=\"$cname\"}" "$tx"
        else
            cbad=1
        fi
    done < <(jq -r '.[] | [.name, .cpu_time, (.mem_usage | split(" ")[0]), .pids, .net_io] | @tsv' <<<"$cstats")
    [ "$cbad" = 0 ] || collector_error podman-stats-parse
    say "containers: $(jq -r 'length' <<<"$cstats") running"
else
    collector_error podman-stats
    say "podman stats did not answer"
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
