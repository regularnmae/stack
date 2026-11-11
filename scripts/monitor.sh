#!/usr/bin/env bash
# Health monitor and spend tripwire for the stack.
#
#   scripts/monitor.sh              # run every check, log, heartbeat, alert
#   scripts/monitor.sh --quiet      # no stdout (what deploy/monitor.service runs)
#   scripts/monitor.sh --no-verify  # skip the verify.sh base sweep
#   scripts/monitor.sh --test       # send one real alert through Alertmanager
#
# It finds WHAT is wrong and writes it as metrics: one stack_monitor_section
# series per failing section, plus that section's text as an info series, and the
# numbers some checks produce. The rules vmalert loads (deploy/monitoring/rules/)
# decide WHEN a fault has lasted long enough to page, and Alertmanager owns
# grouping, inhibition, silences and delivery. No alert state lives in this
# script -- `for:` damps the onset and `keep_firing_for:` the reset, so there is
# no explicit endsAt to remember and no lock to take.
#
# Three checks (unit restarts, disk saturation, Suricata bursts) are decided in
# the rules over a window, not here: their fact is a rate, and a per-sweep
# verdict on a rate is an event that fires and resolves around every burst.
#
# A failure fails the dead-man's-switch heartbeat: a host that is down cannot
# report itself, and neither can one whose mail is not leaving, so the heartbeat
# also fails when the facts could not be written, or when the alert path itself
# (the store, vmalert, Alertmanager, or its deliveries) is broken.
#
# Config comes from $DATA_DIR/config/monitoring/monitor.env (the unit's
# EnvironmentFile), read here too so a hand run behaves the same. Empty means
# journal only. `off` disables the alerting path: no section series are written,
# so no rule can fire. The SMTP credentials live in alertmanager.yml, never here.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

QUIET=0
DO_VERIFY=1
ALERT_TEST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)     QUIET=1 ;;
        --no-verify) DO_VERIFY=0 ;;
        --test)      ALERT_TEST=1 ;;
        -h|--help)   usage_header "$0"; exit 0 ;;
        *)           die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# The alert path is host `curl` + `jq`: Alertmanager is a loopback bind and the
# heartbeat is an outbound POST, so both are made from here, never from a
# container (a container cannot be what reports a broken container runtime).
# Without them every check can pass and nothing is delivered -- and with no
# channel left, nothing can say so -- so refuse to run rather than write a
# half-sweep over the flap-damper state. bootstrap.sh installs both; jq is
# checked for the same reason, since the alert bodies are built with it.
missing=""
command -v curl >/dev/null 2>&1 || missing="$missing curl"
command -v jq   >/dev/null 2>&1 || missing="$missing jq"
if [ -n "$missing" ]; then
    die "monitor needs${missing} on the host: the alert push, the Alertmanager check and the heartbeat all use them. Install: sudo dnf install -y${missing} (./bootstrap.sh does this) -- until then this host cannot be alerted on"
fi

resolve_data_dir
AUDIT_DIR="$DATA_DIR/audit"
mkdir -p "$AUDIT_DIR"
MONITOR_ENV="$CONFIG_DIR/monitoring/monitor.env"
AUDIT_LOG="$AUDIT_DIR/audit.log"

# The unit passes these through EnvironmentFile; reading the file here too makes
# a hand run behave the same. Order at every key: process environment, then the
# file, then the caller's default -- one helper, so the key that forgot the file
# read cannot alert differently by hand than from the timer.
monitor_var() { # NAME [default]
    local v="${!1:-}"
    [ -n "$v" ] || v=$(env_value "$MONITOR_ENV" "$1")
    [ -n "$v" ] || v="${2:-}"
    printf '%s' "$v"
}
MONITOR_PING_URL=$(monitor_var MONITOR_PING_URL)
MONITOR_ALERTMANAGER_URL=$(monitor_var MONITOR_ALERTMANAGER_URL)
# Default on, so a host that upgrades gets alerting without an env edit. `off` is
# the explicit opt-out: env_value returns nothing for both "absent" and "empty",
# which is why the sentinel is a word.
MONITOR_ALERTMANAGER_URL="${MONITOR_ALERTMANAGER_URL:-http://127.0.0.1:9093}"
MONITOR_GRACE_SYNC=$(monitor_var MONITOR_GRACE_SYNC)
MONITOR_GRACE_SYNC="${MONITOR_GRACE_SYNC:-1}"
# The shallow sweep is the default: this runs every five minutes, and --deep adds
# a read-tool round trip to every MCP server on each one. No fallback below on
# purpose -- empty means shallow, and a `${x:---deep}` default would silently keep
# paying for the read tools.
MONITOR_VERIFY_ARGS=$(monitor_var MONITOR_VERIFY_ARGS)
# A host deployed with ./deploy.sh --skip-daemons runs none of CHAIN_UNITS, so
# every chain check here and the chain-backed vhosts would fail forever. One
# declaration rather than two: --no-nodes is appended to the verify sweep below,
# so the flag and the sweep cannot disagree.
MONITOR_SKIP_NODES=$(monitor_var MONITOR_SKIP_NODES)
MONITOR_SKIP_NODES="${MONITOR_SKIP_NODES:-0}"
if [ "$MONITOR_SKIP_NODES" = 1 ]; then
    case " $MONITOR_VERIFY_ARGS " in
        *" --no-nodes "*) ;;
        *) MONITOR_VERIFY_ARGS="$MONITOR_VERIFY_ARGS --no-nodes" ;;
    esac
fi
# The instance label on the one alert this script posts itself (`--test`). The
# real ones come from the node scrape the facts arrive through, so this is not
# load-bearing for inhibition any more.
ALERT_INSTANCE="$(hostname -s 2>/dev/null || echo stack)"
# Alertmanager's failed-delivery counter, remembered between sweeps: a failed
# delivery cannot report itself, so the next sweep reads the growth. Host state,
# not config, so it lives in audit/.
ALERT_FAILED_FILE="$AUDIT_DIR/alertmanager.failed"

# The host-check thresholds follow the same order as the four above, so a hand
# run alerts on exactly what the timer would.
MONITOR_DISK_FREE_PCT=$(monitor_var MONITOR_DISK_FREE_PCT)
MONITOR_INODES_FREE_PCT=$(monitor_var MONITOR_INODES_FREE_PCT)
MONITOR_BACKUP_MAX_AGE_H=$(monitor_var MONITOR_BACKUP_MAX_AGE_H)
MONITOR_BACKUP_VERIFY_MAX_AGE_H=$(monitor_var MONITOR_BACKUP_VERIFY_MAX_AGE_H)
MONITOR_BACKUP_VERIFY_DB_MAX_AGE_H=$(monitor_var MONITOR_BACKUP_VERIFY_DB_MAX_AGE_H)
MONITOR_DUMP_MAX_AGE_H=$(monitor_var MONITOR_DUMP_MAX_AGE_H)
MONITOR_CERT_MIN_DAYS=$(monitor_var MONITOR_CERT_MIN_DAYS)
MONITOR_METRICS_MAX_AGE_S=$(monitor_var MONITOR_METRICS_MAX_AGE_S)
MONITOR_LOGS_MAX_AGE_S=$(monitor_var MONITOR_LOGS_MAX_AGE_S)
MONITOR_FULCRUM_LAG_BLOCKS=$(monitor_var MONITOR_FULCRUM_LAG_BLOCKS)
# The chain section reads these before the host checks define theirs, so they
# resolve here, next to THRESH_FULCRUM_LAG which unblocks that order.
MONITOR_BTC_MIN_PEERS=$(monitor_var MONITOR_BTC_MIN_PEERS)
MONITOR_MEMPOOL_MB=$(monitor_var MONITOR_MEMPOOL_MB)
MONITOR_XMR_LAG_BLOCKS=$(monitor_var MONITOR_XMR_LAG_BLOCKS)
MONITOR_IDS_MAX_AGE_MIN=$(monitor_var MONITOR_IDS_MAX_AGE_MIN)
MONITOR_BOUNCER_MAX_AGE_MIN=$(monitor_var MONITOR_BOUNCER_MAX_AGE_MIN)
MONITOR_AUDIT_MAX_AGE_MIN=$(monitor_var MONITOR_AUDIT_MAX_AGE_MIN)
MONITOR_REGISTRATIONS_MAX_AGE_MIN=$(monitor_var MONITOR_REGISTRATIONS_MAX_AGE_MIN)

# Defaults live here, not only in monitor.env, so an env file written before a
# check existed still monitors.
num_or() { # value default
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}
# How far Fulcrum's index may sit behind bitcoind. A healthy one polls every 5s
# and is 0-1 block behind, so this is a "stopped following" threshold: 12 blocks
# is about two hours at 10 minutes a block.
THRESH_FULCRUM_LAG=$(num_or "${MONITOR_FULCRUM_LAG_BLOCKS:-}" 12)
# Deliberately 1: during IBD zero peers means the download is stalled, not
# protected, so there is no grace here unlike the height checks.
THRESH_BTC_PEERS=$(num_or "${MONITOR_BTC_MIN_PEERS:-}" 1)
# A warn, not a failure: Core's default maxmempool is 300 MB and it grows well
# into a fee storm before rejecting, so this is the "look at the fees" signal.
THRESH_MEMPOOL_MB=$(num_or "${MONITOR_MEMPOOL_MB:-}" 250)
# While synchronized, monerod is normally 0-1 blocks from target_height; more
# means a wedged-but-alive RPC surface serving a stale chain. While not
# synchronized the grace covers it, like the other chain checks.
THRESH_XMR_LAG=$(num_or "${MONITOR_XMR_LAG_BLOCKS:-}" 3)
# The IDS roll-up runs every five minutes; 20 gives it four missed runs (or one
# long deploy that restarted the engines) before the sweep calls it stale. This
# is the check that notices a sensor that died quietly -- its unit can read
# "active" while the engine inside has stopped turning.
THRESH_IDS_AGE_M=$(num_or "${MONITOR_IDS_MAX_AGE_MIN:-}" 20)
# The applier runs every minute; five missed runs is a stopped timer or a wedged
# nft, and either one means decisions are being made but nothing is enforcing.
THRESH_BOUNCER_AGE_M=$(num_or "${MONITOR_BOUNCER_MAX_AGE_MIN:-}" 5)
# The audit report runs every five minutes; four missed runs is a stopped timer.
THRESH_AUDIT_AGE_M=$(num_or "${MONITOR_AUDIT_MAX_AGE_MIN:-}" 20)
# The signup watcher runs every minute. Thirty missed runs is a stopped timer or
# a host that cannot reach postgres. A warning, not a failure: nothing about the
# site is wrong, only the notification that somebody signed up.
THRESH_REG_AGE_M=$(num_or "${MONITOR_REGISTRATIONS_MAX_AGE_MIN:-}" 30)

PROBLEMS=()
WARNS=()
# Which check section each entry came from. The section is the alert's stable
# identity (its label); the text is the annotation. Without the split, "disk 9%
# free" and "disk 8% free" would be two different alerts and every sweep would
# look like a state change.
PROBLEM_SECTIONS=()
WARN_SECTIONS=()
SECTION="other"
verify_failures=0
backup_age_s=""
backup_count=""
backup_verify_age_s=""
backup_verify_ok=""
backup_verify_db_age_s=""
backup_verify_db_ok=""
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/_/g; s/^_//; s/_$//'; }
head3() { say ""; say "$*"; SECTION=$(slug "$*"); }
ok()   { say "  ok    $*"; }
soft() { WARNS+=("$*");   WARN_SECTIONS+=("$SECTION");    say "  warn  $*"; }
fail() { PROBLEMS+=("$*"); PROBLEM_SECTIONS+=("$SECTION"); say "  FAIL  $*"; }

# ---------------------------------------------------------------------------
# --test: prove the delivery path, once
# ---------------------------------------------------------------------------
# One alert posted straight at Alertmanager with an endsAt two minutes out: SMTP
# and the receiver's send_resolved, which is the half a real fault cannot report
# on. vmalert is deliberately not in this path -- its own liveness is one of the
# checks below, not something a synthetic alert could prove.
if [ "$ALERT_TEST" = 1 ]; then
    [ "$MONITOR_ALERTMANAGER_URL" = off ] && die "alerting is off (MONITOR_ALERTMANAGER_URL=off)"
    url="${MONITOR_ALERTMANAGER_URL%/}"
    starts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    ends=$(date -u -d '+2 minutes' '+%Y-%m-%dT%H:%M:%SZ')
    body=$(jq -cn --arg s "$starts" --arg e "$ends" --arg inst "$ALERT_INSTANCE" \
        '[{labels:{alertname:"stack_test",severity:"warning",service:"alerting",instance:$inst},
           annotations:{summary:"stack: test alert",description:"Sent by scripts/monitor.sh --test; it resolves in two minutes."},
           startsAt:$s, endsAt:$e}]')
    curl -fsS -m 10 -H 'Content-Type: application/json' \
        --data-binary "$body" "$url/api/v2/alerts" >/dev/null \
        || die "could not post a test alert to $url/api/v2/alerts"
    printf 'test alert accepted by %s\n' "$url"
    printf 'expect a warning mail now and a resolved mail in about two minutes.\n'
    printf 'nothing arrived? fill in SMTP in %s/monitoring/alertmanager/alertmanager.yml,\n' "$CONFIG_DIR"
    printf 'then: podman logs --tail 30 alertmanager\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. the base sweep: containers, MCP health, token gate, authenticated calls
# ---------------------------------------------------------------------------
if [ "$DO_VERIFY" = 1 ]; then
    head3 "verify.sh"
    read -r -a verify_args <<< "$MONITOR_VERIFY_ARGS"
    verify_out=$("$REPO_DIR/verify.sh" ${verify_args[@]+"${verify_args[@]}"} 2>&1) || verify_rc=$?
    if [ "${verify_rc:-0}" = 0 ]; then
        ok "verify.sh: all checks passed"
    else
        # Carry the verifier's own FAIL lines into the alert body.
        carried=0
        vcount=0
        while IFS= read -r line; do
            case "$line" in
                *FAIL*)
                    fail "verify: ${line#*FAIL }"
                    carried=1
                    vcount=$((vcount + 1))
                    ;;
            esac
        done <<< "$(printf '%s' "$verify_out" | sed 's/\x1b\[[0-9;]*m//g')"
        [ "$carried" = 1 ] || fail "verify.sh reported problems"
        verify_failures="$vcount"
    fi
fi

# ---------------------------------------------------------------------------
# 2. chain freshness -- the chain daemons, read at their RPCs
# ---------------------------------------------------------------------------
# One function so a host that runs no daemon tier can skip it whole: with
# MONITOR_SKIP_NODES=1 those units are absent on purpose, and every check below
# would fail on the same missing daemon. head3 runs at the call site, so the
# section -- the alert's identity -- is set before anything here can report.
chain_checks() {
    info=$(bitcoind_cli getblockchaininfo 2>/dev/null) || info=""
    if [ -z "$info" ]; then
        fail "bitcoind RPC unreachable"
    else
        blocks=$(printf '%s' "$info" | jq -r '.blocks // empty' 2>/dev/null)
        headers=$(printf '%s' "$info" | jq -r '.headers // empty' 2>/dev/null)
        ibd=$(printf '%s' "$info" | jq -r 'if has("initialblockdownload") then .initialblockdownload else empty end' 2>/dev/null)
        if [ "$ibd" = true ] && [ "$MONITOR_GRACE_SYNC" = 1 ]; then
            ok "bitcoind is in initial block download (blocks=$blocks, not paged)"
        elif [ -n "$blocks" ] && [ -n "$headers" ] && [ "$((headers - blocks))" -gt 6 ]; then
            fail "bitcoind is behind: blocks=$blocks headers=$headers"
        else
            ok "bitcoind at height $blocks"
        fi
        # Peers: the freshness check has a blind spot -- a node whose only peers
        # vanished keeps its height while its sync stalls. The floor defaults to 1, so
        # any 0-peer read fails, and this deliberately looks past IBD, where a stalled
        # download is the same fault as a stalled tip.
        json_peers=$(bitcoind_cli getpeerinfo 2>/dev/null) || json_peers=""
        n_peers=$(printf '%s' "$json_peers" | jq -r 'if type == "array" then length else empty end' 2>/dev/null) || n_peers=""
        if [ -z "$n_peers" ]; then
            soft "could not read bitcoind getpeerinfo; skipped the peer check"
        elif [ "$n_peers" -lt "$THRESH_BTC_PEERS" ]; then
            fail "bitcoind has $n_peers peer(s) (floor $THRESH_BTC_PEERS): its sync cannot advance without one"
        else
            ok "bitcoind has $n_peers peer(s)"
        fi
        # The mempool cap: a warn only, since Core fills it well into a fee storm
        # before rejecting and the right response is "look at the fees", not a page.
        mp=$(bitcoind_cli getmempoolinfo 2>/dev/null) || mp=""
        mp_mb=$(printf '%s' "$mp" | jq -r 'if type == "object" then ((.bytes // 0) / 1048576 | floor) else empty end' 2>/dev/null) || mp_mb=""
        if [ -n "$mp_mb" ]; then
            if [ "$mp_mb" -ge "$THRESH_MEMPOOL_MB" ]; then
                soft "bitcoind's mempool holds ${mp_mb} MB (warn threshold ${THRESH_MEMPOOL_MB} MB) -- fee storm or a packed signal"
            else
                ok "bitcoind's mempool at ${mp_mb} MB"
            fi
        fi
    fi
    
    # Fulcrum, the Electrum server: the one daemon whose own port says the least. Its
    # healthcheck is the process table, it keeps answering server.version while the
    # index is wedged, and the wallet/explorer surface then serves stale heights. So
    # ask the index-backed question -- the tip it reports -- and compare with bitcoind.
    ftip=$(electrum_tip 50001)
    if [ -z "$ftip" ]; then
        if [ "${ibd:-}" = true ] && [ "$MONITOR_GRACE_SYNC" = 1 ]; then
            ok "fulcrum is not serving Electrum yet (bitcoind is in initial block download)"
        else
            fail "fulcrum does not answer Electrum on 50001"
        fi
    elif [ -z "${blocks:-}" ]; then
        soft "fulcrum reports tip $ftip; bitcoind height unreadable, so lag is not compared"
    elif [ "${ibd:-}" = true ] && [ "$MONITOR_GRACE_SYNC" = 1 ]; then
        ok "fulcrum index at $ftip (bitcoind is in initial block download; lag $((blocks - ftip)) not paged)"
    else
        behind=$((blocks - ftip))
        if [ "$behind" -gt "$THRESH_FULCRUM_LAG" ]; then
            fail "fulcrum index is $behind block(s) behind bitcoind (tip $ftip, bitcoind $blocks)"
        else
            ok "fulcrum index at $ftip (bitcoind $blocks)"
        fi
    fi
    
    lninfo=$(lightning_cli getinfo 2>/dev/null) || lninfo=""
    if [ -z "$lninfo" ]; then
        fail "lightningd RPC unreachable"
    else
        if printf '%s' "$lninfo" | jq -e 'has("warning_bitcoind_sync")' >/dev/null 2>&1; then
            fail "lightningd reports warning_bitcoind_sync (its view of bitcoind is stale)"
        fi
        # Peers and channels come from the node's own view, not getinfo: getinfo's
        # num_peers counts peers "connected or with channels", so it stays >= 1 for a
        # node whose only peer is offline. listpeers carries `connected` per peer.
        #
        # listchannels is the gossip table: one entry per direction, and its `active`
        # is the channel_update's enabled bit, an operator setting that stays true
        # while the peer is offline -- a check against it passes every sweep.
        # listpeerchannels is the node's own view (peer_connected plus a state), and
        # only operational channels count (an ONCHAIN one is meant to be alone).
        lpeers=$(lightning_cli listpeers 2>/dev/null) || lpeers=""
        npeers=$(printf '%s' "$lpeers" | jq -r '[.peers[] | select(.connected)] | length' 2>/dev/null) || npeers=""
        if [ -z "$npeers" ]; then
            soft "could not read lightningd listpeers; skipped the peer check"
        elif [ "$npeers" = 0 ]; then
            soft "lightningd has no connected peers"
        else
            ok "lightningd has $npeers connected peer(s)"
        fi
        chans=$(lightning_cli listpeerchannels 2>/dev/null) || chans=""
        offline=$(printf '%s' "$chans" | jq -r \
            '[.channels[] | select(.state == "CHANNELD_NORMAL" and .peer_connected == false)] | length' \
            2>/dev/null) || offline=""
        if [ -z "$offline" ]; then
            soft "could not read lightningd listpeerchannels; skipped the offline-channel check"
        elif [ "$offline" -gt 0 ]; then
            fail "$offline lightning channel(s) have their peer offline"
        else
            ok "no lightning channel with an offline peer"
        fi
    fi
    
    # Monero heights are read through the node MCP and the wallet MCP (the daemons
    # carry no curl/wget), so this goes through mcp_call. Missing or unparseable
    # output is a warning only -- verify.sh already fails if the endpoint is down.
    #
    # The node's own probe is the process, not its RPC (the handler blocks while a
    # --block-sync-size batch holds the chain lock), so "alive but not answering" is
    # owned HERE and only here: an RPC that returns nothing is either that documented
    # stall or a wedged daemon, and the grace flag tells them apart. Under grace it is
    # a warning; with MONITOR_GRACE_SYNC=0 the node is expected to be current, so it
    # fails. The history is metrics.sh's stack_xmr_rpc_up.
    node_h=""
    sync=""
    xmrnode_token=$(env_value "$CONFIG_DIR/monero-node-mcp/token.env" MONERO_MCP_TOKEN)
    if [ -n "$xmrnode_token" ]; then
        node_body=$(mcp_call monero-node-mcp "$xmrnode_token" get_info '{}') || node_body=""
        node_h=$(mcp_result "$node_body" | jq -r '.height // empty' 2>/dev/null)
        sync=$(mcp_result "$node_body" | jq -r 'if has("synchronized") then .synchronized else empty end' 2>/dev/null)
        if [ -z "$node_h" ] && [ -z "$sync" ]; then
            if [ "$MONITOR_GRACE_SYNC" != 1 ]; then
                fail "monerod restricted RPC did not answer get_info (wedged handler, or the chain lock held; stack_xmr_rpc_up carries the history)"
            else
                soft "monerod restricted RPC did not answer get_info (normal while a sync batch holds the chain lock; raise MONITOR_GRACE_SYNC=0 to page on it)"
            fi
        elif [ "$sync" = false ] && [ "$MONITOR_GRACE_SYNC" != 1 ]; then
            fail "monerod is not synchronized (height ${node_h:-?})"
        else
            ok "monerod height ${node_h:-?} (synchronized=${sync:-?})"
            # Lag behind the network tip. A synchronized node above the threshold is
            # a fault: the RPC surface answers, but serves a stale chain. While not
            # synchronized, the grace covers it as usual.
            target_h=$(mcp_result "$node_body" | jq -r '.target_height // empty' 2>/dev/null)
            if [ -n "$node_h" ] && [ -n "$target_h" ] && [ "$target_h" -ge "$node_h" ]; then
                xlag=$(( target_h - node_h ))
                if [ "$sync" = true ] && [ "$xlag" -gt "$THRESH_XMR_LAG" ]; then
                    fail "monerod reports synchronized but is $xlag block(s) behind its target (height $node_h, target $target_h)"
                else
                    ok "monerod is $xlag block(s) from its target"
                fi
            fi
        fi
    else
        soft "no MONERO_MCP_TOKEN; skipped the monerod height check"
    fi
    
    xmrwallet_token=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
    if [ -n "$xmrwallet_token" ] && [ ! -f "$DATA_DIR/btcpay/xmr-wallet/wallet.keys" ]; then
        soft "the BTCPay view-only XMR wallet is not imported yet (config/btcpay/xmr-wallet.env); skipped the wallet height check"
    elif [ -n "$xmrwallet_token" ]; then
        w_body=$(mcp_call monero-wallet-mcp "$xmrwallet_token" get_height '{}') || w_body=""
        w_h=$(mcp_result "$w_body" | jq -r '.height // empty' 2>/dev/null)
        if [ -z "$w_h" ]; then
            # No answer is not "fine": the wallet RPC is down, wedged or (usually)
            # rebuilding its cache, and the container can sit "Up (unhealthy)" for
            # hours while every sweep reports the height as "?".
            fail "monero-wallet does not answer get_height (wallet RPC down or rebuilding; podman logs monero-wallet-btcpay)"
        elif [ -n "$node_h" ] && [ "$((node_h - w_h))" -gt 10 ]; then
            soft "monero-wallet is behind monerod: wallet=$w_h node=$node_h"
        else
            ok "monero-wallet height $w_h"
        fi
    fi
}

head3 "chain daemons"
if [ "$MONITOR_SKIP_NODES" = 1 ]; then
    ok "chain daemons skipped by request (MONITOR_SKIP_NODES=1: this host runs no daemon tier)"
else
    chain_checks
fi

# ---------------------------------------------------------------------------
# 3. host health -- the failures invisible from inside the containers: a full
# disk, an exhausted inode table, a saturated disk, a backup that stopped
# running, a certificate that stopped renewing, a unit crash-looping behind a
# "healthy" label, and the metrics collector going quiet.
#
# These read the host directly (df, /proc, /sys, restic, systemd, openssl) and
# never query the metrics store: alerting must not depend on the pipeline that
# exists to draw graphs of it.
# ---------------------------------------------------------------------------
head3 "host"

# Defaults live here too, so an env file written before a check existed still
# monitors. num_or is defined with the config above, because the chain section
# reads a threshold through it first.
THRESH_DISK=$(num_or "${MONITOR_DISK_FREE_PCT:-}" 10)
THRESH_INODES=$(num_or "${MONITOR_INODES_FREE_PCT:-}" 5)
THRESH_BACKUP_H=$(num_or "${MONITOR_BACKUP_MAX_AGE_H:-}" 36)
THRESH_VERIFY_H=$(num_or "${MONITOR_BACKUP_VERIFY_MAX_AGE_H:-}" 192)
THRESH_VERIFY_DB_H=$(num_or "${MONITOR_BACKUP_VERIFY_DB_MAX_AGE_H:-}" 1080)
THRESH_DUMP_H=$(num_or "${MONITOR_DUMP_MAX_AGE_H:-}" 36)
THRESH_CERT_D=$(num_or "${MONITOR_CERT_MIN_DAYS:-}" 14)
THRESH_METRICS_S=$(num_or "${MONITOR_METRICS_MAX_AGE_S:-}" 300)
# The log pipeline: how old the newest entry in the store may be. A "stopped
# shipping" alarm, not a threshold -- 15 minutes gives a restart room to come back.
THRESH_LOGS_S=$(num_or "${MONITOR_LOGS_MAX_AGE_S:-}" 900)
# The NIC's errs+drop columns, delta'd between sweeps like the restart counters:
# a carrier dropping packets looks like a slow sync to every chain check.
MONITOR_NET_DROP=$(monitor_var MONITOR_NET_DROP)
THRESH_NET_DROP=$(num_or "${MONITOR_NET_DROP:-}" 100)
# The hottest hwmon reading at sweep time; a warn, since a one-off spike is noise
# and a climbing trend shows in the graphs node-exporter already exports.
MONITOR_TEMP_MAX=$(monitor_var MONITOR_TEMP_MAX)
THRESH_TEMP_C=$(num_or "${MONITOR_TEMP_MAX:-}" 85)

# df -P's Use% is rounded *up*, so 100-Use% is a floor: erring towards alarming.
#   free_pct PATH            # per cent of the filesystem still free
#   free_pct --inodes PATH   # per cent of its inodes still free
free_pct() {
    if [ "$1" = --inodes ]; then
        df -Pi "$2" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print 100 - $5}'
    else
        df -P "$1" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print 100 - $5}'
    fi
}

for target in "$DATA_DIR" /; do
    dfree=$(free_pct "$target" 2>/dev/null || true)
    ifree=$(free_pct --inodes "$target" 2>/dev/null || true)
    if [ -n "$dfree" ] && [ "$dfree" -lt "$THRESH_DISK" ]; then
        fail "disk almost full: $target has ${dfree}% free (threshold ${THRESH_DISK}%)"
    else
        ok "$target has ${dfree:-?}% disk free"
    fi
    if [ -n "$ifree" ] && [ "$ifree" -lt "$THRESH_INODES" ]; then
        fail "inodes almost exhausted on $target: ${ifree}% free (threshold ${THRESH_INODES}%)"
    fi
done

# Saturation, not space: a disk 100% busy at a few MB/s is why every chain crawls,
# and it is invisible in df. io_ticks is field 10 of /sys/block/<dev>/stat -- note
# *10*, not the 13 of /proc/diskstats: the sysfs file omits major/minor/name, so
# it is three columns shorter. Sampling twice gives percent-busy directly.
# The device whose own /sys/block/<name>/stat is the I/O: sda for sda1, but
# dm-2 for /dev/mapper/vg-lv and md0 for an array. A partition has no
# /sys/block entry, while an LVM/dm/md/crypt device does even though its
# mapper name is not what the kernel calls it, so walk the inverse chain and
# take the first name sysfs knows.
block_device() { # path -> the device that owns its I/O
    local src dev
    src=$(findmnt -no SOURCE --target "$1" 2>/dev/null) || return 1
    src=${src%%\[*}                     # btrfs subvolume: /dev/sda1[/@data]
    while read -r dev; do
        [ -r "/sys/block/$dev/stat" ] || continue
        printf '%s' "$dev"
        return 0
    done < <(lsblk -sno KNAME -- "$src" 2>/dev/null)
    return 1
}
dev=$(block_device "$DATA_DIR" || true)
disk_dev=""
disk_util=""
if [ -n "${dev:-}" ] && [ -r "/sys/block/$dev/stat" ]; then
    io_a=$(awk '{print $10}' "/sys/block/$dev/stat")
    sleep 3
    io_b=$(awk '{print $10}' "/sys/block/$dev/stat")
    util=$(( (io_b - io_a) * 100 / 3000 ))
    [ "$util" -gt 100 ] && util=100
    # The measurement, not a verdict: a 3-second sample is a coin flip on a disk
    # that is syncing two chains and taking a backup, so `host` must not change
    # severity on it. The rule averages 15 minutes of these samples and pages on
    # sustained saturation, which is the thing worth waking somebody for.
    disk_dev="$dev"
    disk_util="$util"
    ok "$dev (holding $DATA_DIR) ${util}% busy over 3s"
else
    soft "could not identify the block device holding $DATA_DIR"
fi

# A rotation is reconciled, not journaled (rotate.sh): the dangerous residue is
# not a bookkeeping file but a live credential nothing references. Two are
# checkable from here.
#
# 1. The runes. Exactly the pair lightning-mcp/node.env carries may be live on the
#    node; anything else this stack minted is a key that survived a run and is
#    still valid, and one of those could also spend. The comparison (method sets
#    against stack.conf, not remembered ids) is in lib.sh so rotate.sh's pruner
#    and this check agree.
if podman container exists lightningd 2>/dev/null; then
    keep_runes=(
        "$(env_value "$CONFIG_DIR/lightning-mcp/node.env" LIGHTNING_RUNE)"
        "$(env_value "$CONFIG_DIR/lightning-mcp/node.env" LIGHTNING_SPEND_RUNE)"
    )
    if [ -z "${keep_runes[0]}" ] || [ -z "${keep_runes[1]}" ]; then
        # Without the pair there is no declared end state to compare against,
        # and every live rune would read as an orphan. verify.sh already
        # fails on the MCP server this would break.
        soft "lightning-mcp/node.env carries no rune pair; skipped the rune check"
    elif orphan_runes=$(cln_orphan_runes "${keep_runes[@]}" 2>/dev/null); then
        if [ -z "$orphan_runes" ]; then
            ok "only the rune pair in lightning-mcp/node.env is live"
        else
            fail "$(printf '%s\n' "$orphan_runes" | wc -l) live CLN rune(s) the stack does not reference (id $(printf '%s\n' "$orphan_runes" | cut -f1 | paste -sd, -)); a runes rotation blacklists them"
        fi
    else
        soft "could not read lightningd showrunes; skipped the rune check"
    fi
else
    soft "lightningd is not running; skipped the rune check"
fi

# 2. The bitcoin RPC password: bitcoind's own file and the copy every client reads
#    must agree. A half-applied bitcoin-rpc rotation leaves them different and
#    nothing notices until bitcoind restarts into a config its clients no longer
#    match. A plain string comparison -- no credentials change hands.
btc_conf_pw=$(bitcoind_conf_password)
btc_env_pw=$(env_value "$CONFIG_DIR/stack/secrets.env" BITCOIN_RPC_PASSWORD)
if [ -z "$btc_conf_pw" ] || [ -z "$btc_env_pw" ]; then
    soft "could not compare bitcoind's rpcpassword with secrets.env; skipped the check"
elif [ "$btc_conf_pw" = "$btc_env_pw" ]; then
    ok "bitcoind's rpcpassword matches secrets.env"
else
    fail "bitcoind's bitcoin.conf and config/stack/secrets.env disagree on the RPC password (a bitcoin-rpc rotation half-applied?); re-run: scripts/rotate.sh bitcoin-rpc"
fi

# A journal from the version that had one is inert now, but it is the only trace
# of a rotation interrupted before the reconciling design: a soft line so an
# operator can delete it or re-run the target it names.
if compgen -G "$CONFIG_DIR/rotation/*.pending" >/dev/null; then
    soft "stale rotation journal(s) from an older version: $(cd "$CONFIG_DIR/rotation" && printf '%s ' *.pending) -- delete them (nothing reads them)"
fi

# backup age: a timer that fires is not a repository that has a snapshot, and a
# fire-and-forget backup is the failure found on restore day.
# restic_snapshot_summary is the same read rotate.sh makes before it will rotate
# the repository password.
if bsummary=$(restic_snapshot_summary); then
    IFS=$'\t' read -r backup_count backup_epoch <<< "$bsummary"
    if [ -n "$backup_epoch" ]; then
        backup_age_s=$(( $(date +%s) - backup_epoch ))
        backup_age_h=$(( backup_age_s / 3600 ))
        if [ "$backup_age_h" -gt "$THRESH_BACKUP_H" ]; then
            fail "no restic snapshot for ${backup_age_h}h (threshold ${THRESH_BACKUP_H}h)"
        else
            ok "last backup ${backup_age_h}h ago ($backup_count snapshot(s))"
        fi
    else
        soft "no restic snapshot yet (expected until the first backup runs)"
    fi
else
    soft "could not list the restic repository (scripts/backup.sh list)"
fi

# The pre-backup dumps: the live database files are in BACKUP_EXCLUDES, so restic
# copies these dumps instead. A dump job that stops working does not break the
# backup -- restic keeps copying the last good copy -- which is why this check
# exists: otherwise the loss appears on restore day. Each dump is renamed into
# place only after validation, so its mtime is when it was taken.
dump_missing=""
dump_stale=""
dump_oldest=0
for dump_rel in postgres-dump/all.sql npm-dump/database.sqlite uptime-kuma-dump/kuma.sql; do
    dump_file="$DATA_DIR/$dump_rel"
    if [ ! -s "$dump_file" ]; then
        dump_missing="$dump_missing $dump_rel"
        continue
    fi
    dump_m=$(stat -c %Y "$dump_file" 2>/dev/null || true)
    case "$dump_m" in ''|*[!0-9]*) dump_missing="$dump_missing $dump_rel"; continue ;; esac
    dump_age_h=$(( ( $(date +%s) - dump_m ) / 3600 ))
    [ "$dump_age_h" -gt "$dump_oldest" ] && dump_oldest=$dump_age_h
    [ "$dump_age_h" -gt "$THRESH_DUMP_H" ] && dump_stale="$dump_stale $dump_rel (${dump_age_h}h)"
done
case "${backup_count:-}" in
    ''|*[!0-9]*|0)
        soft "no restic snapshot yet; skipped the pre-backup dump freshness check" ;;
    *)
        if [ -n "$dump_missing" ]; then
            fail "pre-backup dump(s) missing:$dump_missing -- the live databases are excluded from the snapshot, so a restore would lose them; run ./deploy.sh --only backup (or the dump units) to take them"
        elif [ -n "$dump_stale" ]; then
            fail "pre-backup dump(s) not refreshed:$dump_stale (threshold ${THRESH_DUMP_H}h) -- the dump job is failing and restic is copying the last good copy"
        else
            ok "pre-backup dumps fresh (oldest ${dump_oldest}h)"
        fi ;;
esac

# The restore drill (backup.sh verify, weekly): a repository that opens and lists
# is not one that restores. Age is measured from the last SUCCESS, not the last
# run -- a drill that skips (no disk space, an oversized set) must not look
# healthy because the timer fired.
VERIFY_STATUS_FILE="$AUDIT_DIR/backup-verify.status"
if [ ! -f "$VERIFY_STATUS_FILE" ]; then
    soft "no backup restore drill yet (expected until backup-verify.timer runs)"
else
    status_verdict "$VERIFY_STATUS_FILE"
    if [ "$STATUS_RESULT" = fail ]; then
        fail "backup restore drill failed: ${STATUS_DETAIL:-run scripts/backup.sh verify}"
        backup_verify_ok=0
    elif [ -n "$STATUS_AGE_S" ]; then
        backup_verify_age_s=$STATUS_AGE_S
        vage_h=$(( backup_verify_age_s / 3600 ))
        if [ "$vage_h" -gt "$THRESH_VERIFY_H" ]; then
            fail "no successful backup restore drill for ${vage_h}h (threshold ${THRESH_VERIFY_H}h, last result ${STATUS_RESULT:-?})"
            backup_verify_ok=0
        elif [ "$STATUS_RESULT" = skip ]; then
            soft "backup restore drill skipped: ${STATUS_DETAIL:-no detail} (last success ${vage_h}h ago)"
            backup_verify_ok=1
        else
            ok "backup restore drill passed ${vage_h}h ago"
            backup_verify_ok=1
        fi
    else
        soft "backup restore drill has no recorded success yet (expected until the first run)"
    fi
fi

# The database drill (backup.sh verify-db, monthly): the weekly drill proves
# restic mechanics and that the dump files are present, never that all.sql
# REPLAYS -- and the dump is the only copy of the app tier's data. Its verdict is
# its own file, judged on its own last success: sharing the weekly one would let
# either drill mask the other's age. A skip carries ok_epoch forward, so a run of
# skips fails on age instead of looking green.
VERIFY_DB_STATUS_FILE="$AUDIT_DIR/backup-verify-db.status"
if [ ! -f "$VERIFY_DB_STATUS_FILE" ]; then
    soft "no backup database drill yet (expected until backup-verify-db.timer runs)"
else
    status_verdict "$VERIFY_DB_STATUS_FILE"
    if [ "$STATUS_RESULT" = fail ]; then
        fail "backup database drill failed: ${STATUS_DETAIL:-run scripts/backup.sh verify-db}"
        backup_verify_db_ok=0
    elif [ -n "$STATUS_AGE_S" ]; then
        backup_verify_db_age_s=$STATUS_AGE_S
        vdage_h=$(( backup_verify_db_age_s / 3600 ))
        if [ "$vdage_h" -gt "$THRESH_VERIFY_DB_H" ]; then
            fail "no successful backup database drill for ${vdage_h}h (threshold ${THRESH_VERIFY_DB_H}h, last result ${STATUS_RESULT:-?})"
            backup_verify_db_ok=0
        elif [ "$STATUS_RESULT" = skip ]; then
            soft "backup database drill skipped: ${STATUS_DETAIL:-no detail} (last success ${vdage_h}h ago)"
            backup_verify_db_ok=1
        else
            ok "backup database drill passed ${vdage_h}h ago"
            backup_verify_db_ok=1
        fi
    else
        soft "backup database drill has no recorded success yet (expected until the first run)"
    fi
fi

# The schedules. Each job's *effect* is checked above (snapshot age, drill age,
# dump freshness, the signup watermark), so a stopped timer is proven by the job's
# output once its threshold passes. What the effect cannot show is a unit that was
# never installed (no output to age), and it shows a dead schedule only after
# hours. So this names the cause as a warning, not a failure: the effect check
# owns the alarm, and one fact never pages twice. (The metrics timer is checked in
# its own block below, where its staleness is judged.)
schedule_faults=""
if command -v systemctl >/dev/null 2>&1; then
    for u in backup.timer backup-verify.timer backup-verify-db.timer \
             registrations.timer monitor.timer; do
        if ! systemctl --user cat "$u" >/dev/null 2>&1; then
            schedule_faults="$schedule_faults $u(not installed)"
        elif ! systemctl --user is-active --quiet "$u" 2>/dev/null; then
            schedule_faults="$schedule_faults $u(not active)"
        fi
    done
    # db-dump is a oneshot service (backup.container Wants=/After= it), so its
    # "active" state is dead by design once it has run; only its installation is
    # a question here, and dump freshness above is the effect check.
    systemctl --user cat db-dump.service >/dev/null 2>&1 \
        || schedule_faults="$schedule_faults db-dump.service(not installed)"
fi
if [ -z "$schedule_faults" ]; then
    ok "every scheduled job is installed and active"
else
    soft "scheduled job(s) not running:$schedule_faults -- ./deploy/install.sh installs them; systemctl --user status <unit> says why"
fi

# Certificate expiry: NPM renews by itself, and fails silently. One cert per
# hosted name lives under letsencrypt/live/<id>/cert.pem.
CERT_MIN=""
CERT_WHICH=""
now_s=$(date +%s)
for cert in "$NPM_DIR"/letsencrypt/live/*/cert.pem; do
    [ -s "$cert" ] || continue
    end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2) || continue
    end_s=$(date -d "$end" +%s 2>/dev/null) || continue
    days=$(( (end_s - now_s) / 86400 ))
    if [ -z "$CERT_MIN" ] || [ "$days" -lt "$CERT_MIN" ]; then
        CERT_MIN="$days"; CERT_WHICH="$(basename "$(dirname "$cert")")"
    fi
done
if [ -n "$CERT_MIN" ]; then
    if [ "$CERT_MIN" -lt "$THRESH_CERT_D" ]; then
        fail "certificate $CERT_WHICH expires in ${CERT_MIN}d (threshold ${THRESH_CERT_D}d)"
    else
        ok "soonest certificate expiry ${CERT_MIN}d ($CERT_WHICH)"
    fi
else
    soft "no nginx-proxy-manager certificate yet (fill in $CONFIG_DIR/npm/api.env)"
fi

# Restart counts are not checked here. A per-sweep delta ("restarted 9 times
# since the last sweep") is an event: true for exactly one sweep, so the section
# fired and resolved around every burst. metrics.sh exports the monotonic
# stack_systemd_restarts{unit}, and the rules alert on increase() over an hour --
# the same fact as a condition, which stays true while the loop is running.

# The collector that produces every graph: if it stops, the history stops and
# nothing else notices, so it is checked from the outside.
STACK_PROM="$DATA_DIR/monitoring/textfile/stack.prom"
if systemctl --user is-active --quiet metrics.timer 2>/dev/null; then
    if [ -f "$STACK_PROM" ]; then
        prom_age=$(( $(date +%s) - $(stat -c %Y "$STACK_PROM" 2>/dev/null || echo 0) ))
        if [ "$prom_age" -gt "$THRESH_METRICS_S" ]; then
            fail "metrics collector is stale: stack.prom is ${prom_age}s old (threshold ${THRESH_METRICS_S}s)"
        else
            ok "metrics collector wrote ${prom_age}s ago"
        fi
    else
        fail "metrics collector has never written $STACK_PROM"
    fi
    # A fresh file is not a graph: node-exporter runs as uid 65534 (a subuid), so a
    # textfile left 0600 is a collector that works and a history that stops.
    # Proven from the outside, by the series the exporter actually serves.
    if ne_metrics=$(net_curl -s -m 10 http://host.containers.internal:9100/metrics 2>/dev/null) \
        && grep -q '^stack_metrics_timestamp' <<< "$ne_metrics"; then
        ok "node-exporter serves the stack's textfile series"
    else
        soft "node-exporter serves no stack_* series (textfile permissions 0600? the exporter is down?): $DATA_DIR/monitoring/textfile"
    fi
else
    soft "metrics.timer is not active; the metrics pipeline is not checked"
fi

# The log pipeline: the ONE query the sweep makes against a store, and it is here
# because the question *is* the pipeline's liveness -- journald -> vector ->
# victoria-logs is three processes and the failure that matters is the silent one
# (every unit "active", nothing arriving). A dead store cannot hide any other
# check, because every other check reads the daemons and the host directly.
logs_ok=0
if systemctl --user is-active --quiet vector.service 2>/dev/null; then
    if logs_detail=$("$REPO_DIR/scripts/logs.sh" --health --window "$THRESH_LOGS_S" --quiet 2>&1); then
        logs_ok=1
        ok "logs: entries arrived in the last ${THRESH_LOGS_S}s"
    else
        fail "log pipeline stopped: ${logs_detail:-no entries in the last ${THRESH_LOGS_S}s} (systemctl --user status vector victoria-logs)"
    fi
else
    soft "vector.service is not active; log shipping is not checked"
fi

# journald's storage: a reboot must not erase the record the store exists to keep.
# The config alone is not proof -- a /var/log/journal tmpfiles has not prepared
# leaves journald writing to /run while Storage=persistent is in force, which is
# why bootstrap.sh judges it by a *.journal file, not by the drop-in.
if [ -n "$(find /var/log/journal -name '*.journal' -print -quit 2>/dev/null)" ]; then
    ok "journald is persistent ($(du -sh /var/log/journal 2>/dev/null | cut -f1))"
elif grep -qs '^Storage=persistent' /etc/systemd/journald.conf.d/99-stack.conf; then
    soft "journald is configured persistent but still writes to /run (sudo ./bootstrap.sh re-applies tmpfiles)"
else
    soft "journald is volatile (sudo ./bootstrap.sh makes it persistent; the store still covers reboots)"
fi

# podman's own events are two lines per exec and one per healthcheck, so pointed
# at journald they are most of the store's volume. install.sh (user) and
# bootstrap (root) install deploy/podman/99-stack.conf into podman's config
# chain; a replaced or overridden drop-in turns the flood back on, which is
# silent until someone reads the store's growth. The user side is asked of podman
# (the effective value) -- which also catches a later-sorting drop-in -- while the
# root side is read from the files, because asking root's podman needs sudo.
podman_events=$(podman info --format '{{.Host.EventLogger}}' 2>/dev/null || true)
case "$podman_events" in
    journald) soft "podman events go to journald (deploy/install.sh moves them to a bounded file)" ;;
    "")       soft "could not read podman's event logger (podman info failed)" ;;
    *)        ok "podman events -> $podman_events, not the journal" ;;
esac
if grep -Eqs '^[[:space:]]*events_logger[[:space:]]*=[[:space:]]*"file"' \
    /etc/containers/containers.conf /etc/containers/containers.conf.d/*.conf; then
    ok "root podman events -> file (/etc/containers/containers.conf.d/99-stack.conf)"
else
    soft "root podman events still go to journald (sudo ./bootstrap.sh installs /etc/containers/containers.conf.d/99-stack.conf)"
fi

# The carrier, read the way the restart counters are: delta'd between sweeps
# against a state file. The chain checks have a blind spot here -- a NIC shedding
# packets still shows as "syncing, just slowly", which is what every IBD looks like.
NET_STATE="$AUDIT_DIR/net"
nic=""
if command -v ip >/dev/null 2>&1; then
    nic=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi
if [ -z "$nic" ]; then
    soft "no default route; skipped the NIC drop check"
elif [ ! -r /proc/net/dev ]; then
    soft "/proc/net/dev unreadable; skipped the NIC drop check"
else
    # errs+drop, both directions: field 1 is the interface name, so the receive
    # columns run 2..9 (errs 4, drop 5) and the transmit columns 10..17
    # (errs 12, drop 13).
    net_total=$(awk -v n="$nic:" '$1==n {print $4+$5+$12+$13; exit}' /proc/net/dev 2>/dev/null)
    case "$net_total" in ''|*[!0-9]*) net_total="" ;; esac
    if [ -z "$net_total" ]; then
        soft "could not read $nic's counters; skipped the NIC drop check"
    else
        prev_net=""
        if [ -f "$NET_STATE" ]; then
            while read -r pnic ptotal; do
                [ "$pnic" = "$nic" ] && prev_net="$ptotal"
            done < "$NET_STATE"
        fi
        printf '%s %s\n' "$nic" "$net_total" > "$NET_STATE" 2>/dev/null || true
        net_drop=""
        [ -n "$prev_net" ] && [ "$prev_net" -le "$net_total" ] && net_drop=$(( net_total - prev_net ))
        if [ -n "$net_drop" ] && [ "$net_drop" -ge "$THRESH_NET_DROP" ]; then
            soft "$nic dropped/errored $net_drop packet(s) since the last sweep (threshold $THRESH_NET_DROP)"
        else
            ok "no NIC drop growth on $nic since the last sweep"
        fi
    fi
fi

# The hottest sensor, read off sysfs here rather than from the graphs, so the
# graphs being down does not cost the check.
if command -v find >/dev/null 2>&1; then
    temp_max=-999
    temp_chip=""
    for t in /sys/class/hwmon/hwmon*/temp*_input; do
        [ -r "$t" ] || continue
        val=$(cat "$t" 2>/dev/null) || continue
        case "$val" in ''|*[!0-9-]*) continue ;; esac
        val_c=$(( val / 1000 ))
        if [ "$val_c" -gt "$temp_max" ]; then
            temp_max="$val_c"
            temp_chip=$(basename "$(dirname "$t")")
        fi
    done
    if [ "$temp_max" -eq -999 ]; then
        soft "no readable hwmon temperature; skipped the temperature check"
    else
        if [ "$temp_max" -ge "$THRESH_TEMP_C" ]; then
            soft "hottest sensor ($temp_chip) reads ${temp_max}°C (threshold ${THRESH_TEMP_C}°C)"
        else
            ok "hottest sensor ($temp_chip) at ${temp_max}°C"
        fi
    fi
fi

# The syslog socket. sshd, PAM, sudo and cron all log through /dev/log; if that
# inode goes stale every one of them gets ECONNREFUSED and the message is simply
# dropped -- /var/log/secure stays empty while SSH logins go unrecorded, and the
# journal keeps filling from container stdout, so nothing notices. Probe the whole
# path rather than the file: write a sentinel with logger (the same syslog(3) call
# sshd makes) and require it back out of the journal.
if command -v logger >/dev/null 2>&1 && command -v journalctl >/dev/null 2>&1; then
    auth_probe="stack-monitor-authlog-$$-$(date +%s)"
    if auth_err=$(logger -p authpriv.info -- "$auth_probe" 2>&1); then
        sleep 1
        if journalctl --since "-120 seconds" --no-pager -q 2>/dev/null | grep -qF -- "$auth_probe"; then
            ok "auth log path: /dev/log -> journal"
        else
            fail "logger accepted a message that never reached the journal; sshd/PAM/sudo events are being dropped unrecorded"
        fi
    else
        fail "the syslog socket is dead, so sshd/PAM/sudo events are dropped unrecorded (${auth_err:-logger failed})"
    fi
fi

# ---------------------------------------------------------------------------
# The BoltMesh signup watcher (registrations.sh, registrations.timer). Judged off
# its status file's ok_epoch, not the timer: a unit can read "active" while every
# run fails. A warning, because nothing about the site is broken -- but this is
# the only thing that mails a registration, so it must be noticed.
# ---------------------------------------------------------------------------
REG_STATUS_FILE="$AUDIT_DIR/registrations.status"
if [ ! -f "$REG_STATUS_FILE" ]; then
    soft "no signup watcher status yet (deploy/registrations.timer has not run)"
else
    status_verdict "$REG_STATUS_FILE"
    if [ "$STATUS_RESULT" = fail ]; then
        soft "the signup watcher is failing: ${STATUS_DETAIL:-see $AUDIT_DIR/registrations.log}"
    elif [ -z "$STATUS_AGE_S" ]; then
        soft "the signup watcher status has no ok_epoch yet"
    elif [ "$(( STATUS_AGE_S / 60 ))" -gt "$THRESH_REG_AGE_M" ]; then
        soft "the signup watcher has not run for $(( STATUS_AGE_S / 60 )) min (systemctl --user status registrations.timer)"
    elif [ "$(env_value "$REG_STATUS_FILE" skipped)" = 1 ]; then
        ok "signups: watcher live, skipped (no BoltMesh app tier on this host)"
    else
        ok "signups: watcher live, $(env_value "$REG_STATUS_FILE" new) new in the last run"
    fi
fi

# ---------------------------------------------------------------------------
# 4. the public surface -- every clearweb vhost through nginx-proxy-manager.
#
# The status page's monitors are UI-owned now, so the sweep owns this check. The
# probe connects to 127.0.0.1, not the public address: NPM terminates TLS and
# every vhost is a proxy host, so this proves the certificate, the server block
# and the loopback publish -- not DNS or the router, which --connect-to
# deliberately bypasses (without NAT reflection a hairpin would fail and the
# vhost would look down for the wrong reason).
#
# The list is the manifest's [npm.*] declarations (NPM_DOMAINS), so a new public
# name is checked the moment it is declared; a manifest that cannot be read stops
# the sweep here, which the heartbeat reports.
#
# Down is no answer at all (000 -- NPM, certificate or socket) or a 5xx (the
# upstream died). A 4xx is accepted on purpose: app roots 404 and token-gated
# endpoints 401. A declared host missing from NPM is indistinguishable from that
# default vhost's 404 here; verify.sh's per-surface probes name it.
#
# A 502 is also what a host deployed with --skip-daemons gets from every vhost
# whose upstream is in CHAIN_UNITS: the declaration marks those needs_nodes, so
# the same MONITOR_SKIP_NODES that drops the chain section reports them as
# skipped rather than as a fault it cannot clear.
# ---------------------------------------------------------------------------
head3 "public surface"
load_manifest "$REPO_DIR"
public_bad=0
if [ -z "${NPM_DOMAINS+x}" ] || [ "${#NPM_DOMAINS[@]}" -eq 0 ]; then
    soft "no [npm.*] hosts are declared; skipped the public-surface check"
else
    for i in "${!NPM_DOMAINS[@]}"; do
        vhost="${NPM_DOMAINS[$i]}"
        if [ "$MONITOR_SKIP_NODES" = 1 ] && [ "${NPM_NEEDS_NODES[$i]:-0}" = 1 ]; then
            ok "$vhost skipped by request (its upstream is in the daemon tier)"
            continue
        fi
        # http first: an HTTP-only vhost (no certificate issued yet) must not
        # read as down. A force-ssl host answers 301/308, and the https probe
        # then carries the certificate check.
        pcode=$(curl -sS -o /dev/null -w '%{http_code}' -m 10 \
            --connect-to "$vhost:80:127.0.0.1:80" "http://$vhost/" 2>/dev/null) || pcode=000
        case "$pcode" in
            301|302|307|308)
                pcode=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
                    --connect-to "$vhost:443:127.0.0.1:443" "https://$vhost/" 2>/dev/null) || pcode=000
                ;;
        esac
        case "$pcode" in
            000|5??)
                public_bad=$((public_bad + 1))
                fail "$vhost does not answer through nginx-proxy-manager ($pcode): certificate, proxy host or loopback publish"
                ;;
            *) ok "$vhost answers through nginx-proxy-manager ($pcode)" ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# 5. the spend tripwire
# ---------------------------------------------------------------------------
head3 "spend tripwire"
audit_out=$("$REPO_DIR/scripts/spend-audit.sh" 2>&1) || audit_rc=$?
audit_trips=0
while IFS= read -r line; do
    case "$line" in
        TRIP:*)
            fail "spend: ${line#TRIP: }"
            audit_trips=$((audit_trips + 1))
            ;;
    esac
done <<< "$audit_out"
if [ "$audit_trips" = 0 ]; then
    if [ "${audit_rc:-0}" = 0 ]; then
        ok "ENABLE_SPENDING=0 and no outgoing spends"
    else
        fail "spend-audit reported a problem"
    fi
fi

# ---------------------------------------------------------------------------
# 6. intrusion detection -- through ids.sh's status file, never directly
# ---------------------------------------------------------------------------
head3 "intrusion detection"
# The engines are not touched from here: Suricata is a rootful system unit whose
# logs live in a root-owned directory, and crowdsec is queried through
# `podman exec`. ids.sh (deploy/ids.timer, at *:2/5 so it lands between sweeps)
# does both and leaves a verdict in audit/ids.status, so a wedged engine shows up
# as a stale or failed status -- the same contract as the backup drill's, and the
# reason a dead sensor cannot look healthy because its unit is "active".
IDS_STATUS_FILE="$AUDIT_DIR/ids.status"
ids_alerts=0
ids_decisions=0
ids_up=0
if [ ! -f "$IDS_STATUS_FILE" ]; then
    soft "no IDS status yet (deploy/ids.timer has not run; sudo ./bootstrap.sh installs the sensor)"
else
    status_verdict "$IDS_STATUS_FILE"
    ids_alerts=$(num_or "$(env_value "$IDS_STATUS_FILE" alerts)" 0)
    ids_decisions=$(num_or "$(env_value "$IDS_STATUS_FILE" decisions)" 0)
    isuri=$(env_value "$IDS_STATUS_FILE" suricata)
    icrowd=$(env_value "$IDS_STATUS_FILE" crowdsec)
    if [ "$STATUS_RESULT" = fail ]; then
        fail "intrusion detection is degraded: ${STATUS_DETAIL:-see $AUDIT_LOG}"
        ids_up=0
    elif [ -z "$STATUS_AGE_S" ]; then
        soft "IDS status has no ok_epoch yet"
    else
        ids_age_m=$(( STATUS_AGE_S / 60 ))
        if [ "$ids_age_m" -gt "$THRESH_IDS_AGE_M" ]; then
            fail "the IDS has not reported for ${ids_age_m} min (ids.timer stopped, or ids.sh cannot read the sensor)"
        else
            ids_up=1
            ok "IDS: suricata=$isuri crowdsec=$icrowd, $ids_alerts alert(s), $ids_decisions decision(s)"
        fi
    fi
    # A report, not a page: the count goes to VictoriaMetrics as
    # stack_ids_alerts, and the rule holds a burst for 15 minutes. Deciding it
    # here made the section fire and resolve around every spike.
fi

# The audit report: host-level changes no script in this repo makes (account
# databases, sudoers, sshd, audit's own config), plus the hash diff over the
# persistence directories -- which catches a *new* unit file, because this kernel
# emits no audit events for directory watches.
AUDIT_STATUS_FILE="$AUDIT_DIR/auditd.status"
audit_fim=0
if [ -f /etc/systemd/system/stack-audit.timer ]; then
    if [ ! -f "$AUDIT_STATUS_FILE" ]; then
        soft "no audit report yet (stack-audit.timer has not run)"
    else
        status_verdict "$AUDIT_STATUS_FILE"
        audit_fim=$(num_or "$(env_value "$AUDIT_STATUS_FILE" fim)" 0)
        if [ "$STATUS_RESULT" = fail ]; then
            fail "host-level configuration changed: ${STATUS_DETAIL:-see $AUDIT_STATUS_FILE}"
        elif [ -z "$STATUS_AGE_S" ]; then
            soft "the audit report has no ok_epoch yet"
        else
            aage_m=$(( STATUS_AGE_S / 60 ))
            if [ "$aage_m" -gt "$THRESH_AUDIT_AGE_M" ]; then
                fail "the audit report has not run for ${aage_m} min (systemctl status stack-audit.timer)"
            else
                case "$(env_value "$AUDIT_STATUS_FILE" audit)" in
                    inert)
                        ok "audit: ${audit_fim} persistence-dir change(s); the kernel audit subsystem emits nothing on this host, so the hash diff is the live check" ;;
                    unavailable)
                        ok "audit: ${audit_fim} persistence-dir change(s) reported; no stack watches are loaded"
                        soft "auditctl/augenrules are missing, so the stack's audit watches cannot load (sudo dnf install audit-rules && sudo ./bootstrap.sh)" ;;
                    *)
                        ok "audit: no host-level changes; ${audit_fim} persistence-dir change(s) reported" ;;
                esac
                # `aureport` failing means the window is re-read, not skipped, so
                # this is a report: nothing was lost, but the counters are stale.
                if [ "$(env_value "$AUDIT_STATUS_FILE" read)" = failed ]; then
                    soft "the audit report could not read the audit log; it is re-examining the same window"
                fi
            fi
        fi
    fi
fi
# The applier. Separate from the engines on purpose: detection can be perfectly
# healthy while nothing enforces (a stopped timer, a wrong key, an nft that refuses
# the table) -- the state where the host believes it is protected and is not.
BOUNCER_STATUS_FILE="$AUDIT_DIR/bouncer.status"
bouncer_bans=0
if [ -f /etc/systemd/system/stack-bouncer.timer ]; then
    if [ ! -f "$BOUNCER_STATUS_FILE" ]; then
        soft "no bouncer status yet (stack-bouncer.timer has not run)"
    else
        status_verdict "$BOUNCER_STATUS_FILE"
        bouncer_bans=$(num_or "$(env_value "$BOUNCER_STATUS_FILE" banned)" 0)
        # Decisions enforcement declined because they name an address the operator
        # holds or their own egress: worth a line, because "0 banned" next to a
        # live decision reads like a broken applier.
        bouncer_skipped=$(num_or "$(env_value "$BOUNCER_STATUS_FILE" skipped)" 0)
        if [ "$STATUS_RESULT" = fail ]; then
            fail "the bouncer is not applying decisions: ${STATUS_DETAIL:-see $AUDIT_DIR/bouncer.status}"
        elif [ -z "$STATUS_AGE_S" ]; then
            soft "bouncer status has no ok_epoch yet"
        else
            bage_m=$(( STATUS_AGE_S / 60 ))
            if [ "$bage_m" -gt "$THRESH_BOUNCER_AGE_M" ]; then
                fail "the bouncer has not applied decisions for ${bage_m} min (systemctl status stack-bouncer.timer)"
            else
                ok "bouncer: ${bouncer_bans} address(es) banned"
                if [ "${bouncer_skipped:-0}" -gt 0 ]; then
                    soft "the bouncer declined ${bouncer_skipped} decision(s) naming an address this host is or uses (its own egress): something here is tripping a rule -- a stale token will do it"
                fi
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 7. the alert path itself
# ---------------------------------------------------------------------------
# Checked before the record so a broken path shows in the same sweep's exit code
# and audit log. Four failures are distinguishable here and nowhere else: the
# store the rules read, the evaluator itself, Alertmanager not answering, and
# Alertmanager answering but failing to deliver. The last can never be reported
# through the channel it broke, so it is remembered as a counter and turned into
# a page on the *next* sweep -- and the heartbeat is pushed after this block,
# because "all checks pass but nobody can be told" must fail it.
#
# The store and vmalert are on this path now, and the first is the sharp edge:
# `for:` is evaluated against VictoriaMetrics, so a wedged store means no rule
# fires at all. Nothing delivered by those rules can say so -- the heartbeat is
# the only channel left, which is why the alert path is judged here rather than
# only by a rule's own threshold.
head3 "alerting"
am_ok=1
vm_ok=1
vmalert_ok=1
if [ "$MONITOR_ALERTMANAGER_URL" = off ]; then
    ok "alerting is off (MONITOR_ALERTMANAGER_URL=off): facts are not written, so no rule can fire"
else
    vm_url="http://127.0.0.1:8428"
    vm_code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$vm_url/-/healthy" 2>/dev/null) || vm_code=""
    if [ "$vm_code" != 200 ]; then
        vm_ok=0
        fail "VictoriaMetrics does not answer at $vm_url/-/healthy: the rules cannot be evaluated, so no alert can fire (the heartbeat carries this one)"
    else
        ok "VictoriaMetrics answers"
    fi

    # vmalert's own health, plus the reload counter: it parses the rules at start,
    # so a healthy process means the rendered file was accepted. A failed RELOAD
    # runs the previous rules -- like Alertmanager's invalid config, that is a
    # warning, not a page.
    vmalert_url="http://127.0.0.1:8880"
    vmalert_code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$vmalert_url/-/healthy" 2>/dev/null) || vmalert_code=""
    if [ "$vmalert_code" != 200 ]; then
        vmalert_ok=0
        fail "vmalert does not answer at $vmalert_url/-/healthy: the sweep's facts are not being evaluated"
    else
        vmalert_metrics=$(curl -fsS -m 5 "$vmalert_url/metrics" 2>/dev/null) || vmalert_metrics=""
        if [ -n "$vmalert_metrics" ] \
            && printf '%s\n' "$vmalert_metrics" | grep -q '^vmalert_config_last_reload_successful 0'; then
            soft "vmalert's last rule reload failed; it is running the previous rules (podman logs vmalert)"
        else
            ok "vmalert answers and its rules are loaded"
        fi
    fi

    am_url="${MONITOR_ALERTMANAGER_URL%/}"
    am_code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$am_url/-/healthy" 2>/dev/null) || am_code=""
    if [ "$am_code" != 200 ]; then
        am_ok=0
        fail "Alertmanager does not answer at $am_url/-/healthy: alerts are going nowhere (the heartbeat carries this one)"
    fi
    # Cumulative since the process started, so a restart (a smaller number) is
    # not a failure; only a growth since the last sweep is. A failed read must
    # leave the stored number alone: awk on an empty body prints 0, which would
    # erase it and turn the next successful read into a fake burst.
    if [ "$am_code" = 200 ]; then
        am_metrics=$(curl -fsS -m 5 "$am_url/metrics" 2>/dev/null) || am_metrics=""
        if [ -n "$am_metrics" ]; then
            am_failed=$(printf '%s\n' "$am_metrics" \
                | awk '/^alertmanager_notifications_failed_total\{/ {s += $NF} END {printf "%d", s + 0}')
            am_prev=$(cat "$ALERT_FAILED_FILE" 2>/dev/null) || am_prev=""
            if [ -n "$am_prev" ] && [ "$am_failed" -gt "$am_prev" ]; then
                am_ok=0
                fail "Alertmanager failed to deliver $((am_failed - am_prev)) notification(s) since the last sweep (SMTP or receiver; podman logs alertmanager)"
            fi
            printf '%s\n' "$am_failed" > "$ALERT_FAILED_FILE" 2>/dev/null || true
            [ "$am_ok" = 1 ] && ok "Alertmanager answers, and nothing failed to deliver since the last sweep"
        else
            soft "Alertmanager answers /-/healthy but /metrics did not; delivery failures could not be checked this sweep"
        fi
    fi
    # The config on disk is operator-owned and hand-edited. Alertmanager keeps
    # running the last good config when it refuses a new one, so an invalid edit is
    # silent until the next restart -- a warning: the running path still works.
    AM_CFG="$CONFIG_DIR/monitoring/alertmanager/alertmanager.yml"
    if [ ! -f "$AM_CFG" ]; then
        soft "no alertmanager config at $AM_CFG (run deploy/install.sh)"
    else
        # amtool lives in the image, so only ask when the health probe answered --
        # otherwise a stopped container reads as a broken config, already reported.
        if [ "$am_code" = 200 ] \
            && ! am_chk=$(podman exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml 2>&1); then
            soft "alertmanager config is invalid (${am_chk##*$'\n'}); it runs the last good one until that is fixed"
        fi
        # The seeded config ships with the paging receiver's email block
        # commented out: until it is filled in the path accepts alerts and
        # delivers nothing. Keyed on the default route's receiver, not on any
        # email_configs in the file -- filling in only the signups sub-route
        # pages nobody and must keep saying so.
        alertmanager_paging "$AM_CFG"
        if [ "$AM_PAGING" != 1 ]; then
            soft "alerting is inert: the default route${AM_RECEIVER:+ (receiver $AM_RECEIVER)} has no email_configs in $AM_CFG (fill in SMTP, then scripts/monitor.sh --test)"
        fi
    fi
    # Not a detail: with the rules in the paging path, a dead evaluator mails a
    # false recovery and a dead host says nothing at all. The heartbeat is the
    # only channel for both, so its absence is worth a line every sweep.
    if [ -z "$MONITOR_PING_URL" ]; then
        soft "no MONITOR_PING_URL: a dead host or a dead vmalert cannot be reported (set a healthchecks.io ping URL)"
    fi
fi

# ---------------------------------------------------------------------------
# 8. the record, the heartbeat, the alert
# ---------------------------------------------------------------------------
status=ok
[ "${#PROBLEMS[@]}" -gt 0 ] && status=fail

summary() {
    if [ "${#PROBLEMS[@]}" -gt 0 ]; then
        printf 'PROBLEMS:\n'
        printf '  - %s\n' "${PROBLEMS[@]}"
    fi
    if [ "${#WARNS[@]}" -gt 0 ]; then
        printf 'warnings:\n'
        printf '  - %s\n' "${WARNS[@]}"
    fi
}

heartbeat() { # ok|fail [body]
    [ -n "$MONITOR_PING_URL" ] || return 0
    local base url
    base="${MONITOR_PING_URL%/}"
    if [ "$1" = fail ]; then
        url="$base/fail"
        # The body is what a healthchecks.io check shows on its page; when the
        # failure is not a check but the alert path, there is no summary to send.
        curl -fsS -m 15 -X POST --data-binary "${2:-$(summary)}" "$url" >/dev/null 2>&1 \
            || soft "heartbeat POST failed"
    else
        curl -fsS -m 15 -X POST "$base" >/dev/null 2>&1 || soft "heartbeat POST failed"
    fi
}

# One series per bad section, plus that section's text as an info series: the
# facts vmalert's rules read. The section is the alert's identity and the text is
# fetched at notification time, so a changing "9% free" never forks the alert.
# Under `off` neither these nor the sweep timestamp are written -- with no facts
# there is nothing for a rule to fire on, and a timestamp alone would page as
# stale.
sections_prom() {
    local i s
    local -A sev=() desc=()
    for i in "${!PROBLEMS[@]}"; do
        s="${PROBLEM_SECTIONS[$i]}"
        sev[$s]=critical
        desc[$s]+="${desc[$s]:+; }${PROBLEMS[$i]}"
    done
    for i in "${!WARNS[@]}"; do
        s="${WARN_SECTIONS[$i]}"
        [ "${sev[$s]:-}" = critical ] || sev[$s]=warning
        desc[$s]+="${desc[$s]:+; }${WARNS[$i]}"
    done
    [ "${#sev[@]}" -gt 0 ] || return 0
    printf '# TYPE stack_monitor_section gauge\n'
    for s in $(printf '%s\n' "${!sev[@]}" | LC_ALL=C sort); do
        printf 'stack_monitor_section{service="%s",severity="%s"} 1\n' "$s" "${sev[$s]}"
    done
    printf '# TYPE stack_monitor_detail_info gauge\n'
    for s in $(printf '%s\n' "${!desc[@]}" | LC_ALL=C sort); do
        printf 'stack_monitor_detail_info{service="%s",detail="%s"} 1\n' \
            "$s" "$(prom_label_value "${desc[$s]}")"
    done
}

# The other half of node-exporter's textfile: the numbers this sweep computes
# anyway (backup age, verifier failures, spend trips), so they get history without
# metrics.sh paying for them again. prom_write owns the exporter's uid permissions.
prom_ok=1
{
    printf '# written by scripts/monitor.sh (deploy/monitor.timer)\n'
    [ "$MONITOR_ALERTMANAGER_URL" = off ] \
        || printf 'stack_sweep_timestamp %s\n' "$(date +%s)"
    printf 'stack_verify_failures %s\n' "${verify_failures:-0}"
    printf 'stack_public_vhosts_bad %s\n' "${public_bad:-0}"
    printf 'stack_spend_trips %s\n' "${audit_trips:-0}"
    printf 'stack_monitor_problems %s\n' "${#PROBLEMS[@]}"
    printf 'stack_monitor_warnings %s\n' "${#WARNS[@]}"
    printf 'stack_monitor_alertmanager_up %s\n' "${am_ok:-1}"
    printf 'stack_monitor_vmalert_up %s\n' "${vmalert_ok:-1}"
    printf 'stack_monitor_vm_up %s\n' "${vm_ok:-1}"
    [ -n "${disk_util:-}" ] && printf 'stack_disk_util_pct{device="%s"} %s\n' "$disk_dev" "$disk_util"
    [ -n "$backup_age_s" ] && printf 'stack_backup_age_seconds %s\n' "$backup_age_s"
    [ -n "$backup_count" ] && printf 'stack_backup_snapshots %s\n' "$backup_count"
    [ -n "$backup_verify_age_s" ] && printf 'stack_backup_verify_age_seconds %s\n' "$backup_verify_age_s"
    [ -n "$backup_verify_ok" ] && printf 'stack_backup_verify_ok %s\n' "$backup_verify_ok"
    [ -n "$backup_verify_db_age_s" ] && printf 'stack_backup_verify_db_age_seconds %s\n' "$backup_verify_db_age_s"
    [ -n "$backup_verify_db_ok" ] && printf 'stack_backup_verify_db_ok %s\n' "$backup_verify_db_ok"
    printf 'stack_ids_up %s\n' "${ids_up:-0}"
    printf 'stack_ids_alerts %s\n' "${ids_alerts:-0}"
    printf 'stack_ids_decisions %s\n' "${ids_decisions:-0}"
    printf 'stack_bouncer_bans %s\n' "${bouncer_bans:-0}"
    printf 'stack_bouncer_skipped %s\n' "${bouncer_skipped:-0}"
    printf 'stack_audit_fim_changes %s\n' "${audit_fim:-0}"
    printf 'stack_logs_ok %s\n' "${logs_ok:-0}"
    [ "$MONITOR_ALERTMANAGER_URL" = off ] || sections_prom
} | prom_write "$DATA_DIR/monitoring/textfile/monitor.prom" \
    || { soft "could not write monitor.prom"; prom_ok=0; }

# The facts first, then the heartbeat's verdict: a sweep whose checks pass but
# whose metrics could not be written is a monitor that decides nothing, and the
# mail about that failure would ride the rules it just failed to feed.
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    heartbeat fail "$(summary)"
elif [ "$prom_ok" = 0 ]; then
    heartbeat fail "monitor: every check passed, but its metrics could not be written -- no rule can fire on this sweep"
else
    heartbeat ok
fi

[ "$prom_ok" = 0 ] && status=fail

{
    printf '%s status=%s problems=%d warnings=%d\n' \
        "$(date -Is)" "$status" "${#PROBLEMS[@]}" "${#WARNS[@]}"
    for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do
        printf '%s   FAIL %s\n' "$(date -Is)" "$p"
    done
} >> "$AUDIT_LOG"

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    say ""
    say "${#PROBLEMS[@]} problem(s):"
    printf '  - %s\n' "${PROBLEMS[@]}" | { [ "$QUIET" = 1 ] || cat; }
    exit 1
fi

if [ "$prom_ok" = 0 ]; then
    say ""
    say "all checks passed, but the facts could not be written (see above)"
    exit 1
fi

say ""
say "all checks passed"
exit 0
