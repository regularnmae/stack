#!/usr/bin/env bash
# Health monitor and spend tripwire for the stack.
#
#   scripts/monitor.sh              # run every check, log, heartbeat, alert
#   scripts/monitor.sh --quiet      # no stdout (what deploy/monitor.service runs)
#   scripts/monitor.sh --no-verify  # skip the verify.sh base sweep
#
# Driven by deploy/monitor.timer (a plain systemd user unit) every five minutes.
# Read-only: it starts nothing, restarts nothing and rewrites no config. It
# reuses verify.sh for the container/MCP base checks and adds the ones nothing
# else does -- chain freshness, CLN peers and channels, the Monero wallet's lag,
# and the spend tripwire in scripts/spend-audit.sh.
#
# Nothing here pauses a failing service; a failure fails the dead-man's-switch
# heartbeat ($MONITOR_PING_URL) and sends one alert per state CHANGE through
# Apprise ($MONITOR_APPRISE_URLS). A host that is down cannot report itself --
# the missed heartbeat is the only thing that catches that, which is why the
# heartbeat is a plain outbound ping and not an Apprise target.
#
# Config comes from $DATA_DIR/config/monitoring/monitor.env (the unit's
# EnvironmentFile); it is read here too so the script also runs by hand. Empty
# values mean "journal only": no heartbeat, no alerts.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

QUIET=0
DO_VERIFY=1
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)     QUIET=1 ;;
        --no-verify) DO_VERIFY=0 ;;
        -h|--help)   usage_header "$0"; exit 0 ;;
        *)           die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

resolve_data_dir
AUDIT_DIR="$DATA_DIR/audit"
mkdir -p "$AUDIT_DIR"
MONITOR_ENV="$CONFIG_DIR/monitoring/monitor.env"
STATE_FILE="$AUDIT_DIR/state"
AUDIT_LOG="$AUDIT_DIR/audit.log"
APPRISE_IMAGE="${APPRISE_IMAGE:-docker.io/caronc/apprise:latest}"

# The unit passes these through EnvironmentFile; reading the file here too makes
# a hand run behave the same. env_value never sources the file.
MONITOR_PING_URL="${MONITOR_PING_URL:-$(env_value "$MONITOR_ENV" MONITOR_PING_URL)}"
MONITOR_APPRISE_URLS="${MONITOR_APPRISE_URLS:-$(env_value "$MONITOR_ENV" MONITOR_APPRISE_URLS)}"
MONITOR_GRACE_SYNC="${MONITOR_GRACE_SYNC:-$(env_value "$MONITOR_ENV" MONITOR_GRACE_SYNC)}"
MONITOR_GRACE_SYNC="${MONITOR_GRACE_SYNC:-1}"
MONITOR_VERIFY_ARGS="${MONITOR_VERIFY_ARGS:-$(env_value "$MONITOR_ENV" MONITOR_VERIFY_ARGS)}"
MONITOR_VERIFY_ARGS="${MONITOR_VERIFY_ARGS:---deep}"

PROBLEMS=()
WARNS=()
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
head3() { say ""; say "$*"; }
ok()   { say "  ok    $*"; }
soft() { WARNS+=("$*");    say "  warn  $*"; }
fail() { PROBLEMS+=("$*"); say "  FAIL  $*"; }

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
        while IFS= read -r line; do
            case "$line" in
                *FAIL*)
                    fail "verify: ${line#*FAIL }"
                    carried=1
                    ;;
            esac
        done <<< "$(printf '%s' "$verify_out" | sed 's/\x1b\[[0-9;]*m//g')"
        [ "$carried" = 1 ] || fail "verify.sh reported problems"
    fi
fi

# ---------------------------------------------------------------------------
# 2. chain freshness -- the chain daemons, read at their RPCs
# ---------------------------------------------------------------------------
head3 "chain daemons"

info=$(podman exec bitcoind bitcoin-cli getblockchaininfo 2>/dev/null) || info=""
if [ -z "$info" ]; then
    fail "bitcoind RPC unreachable"
else
    blocks=$(printf '%s' "$info" | grep -oE '"blocks":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
    headers=$(printf '%s' "$info" | grep -oE '"headers":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
    ibd=$(printf '%s' "$info" | grep -oE '"initialblockdownload":[[:space:]]*(true|false)' | grep -oE '(true|false)')
    if [ "$ibd" = true ] && [ "$MONITOR_GRACE_SYNC" = 1 ]; then
        ok "bitcoind is in initial block download (blocks=$blocks, not paged)"
    elif [ -n "$blocks" ] && [ -n "$headers" ] && [ "$((headers - blocks))" -gt 6 ]; then
        fail "bitcoind is behind: blocks=$blocks headers=$headers"
    else
        ok "bitcoind at height $blocks"
    fi
fi

lninfo=$(podman exec lightningd lightning-cli getinfo 2>/dev/null) || lninfo=""
if [ -z "$lninfo" ]; then
    fail "lightningd RPC unreachable"
else
    peers=$(printf '%s' "$lninfo" | grep -oE '"num_peers":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
    if [ "${peers:-0}" = 0 ]; then
        soft "lightningd has no peers"
    else
        ok "lightningd has $peers peer(s)"
    fi
    if printf '%s' "$lninfo" | grep -qE '"warning_bitcoind_sync"'; then
        fail "lightningd reports warning_bitcoind_sync (its view of bitcoind is stale)"
    fi
    chans=$(podman exec lightningd lightning-cli listchannels 2>/dev/null) || chans=""
    offline=$(printf '%s' "$chans" | grep -oE '"connected":[[:space:]]*false' | grep -c . )
    if [ "${offline:-0}" -gt 0 ]; then
        fail "$offline lightning channel(s) are offline"
    else
        ok "no offline lightning channels"
    fi
fi

# Monero heights are read through the node MCP and the wallet MCP (the daemons
# carry no curl/wget of their own, so this goes through the MCP servers, which
# mcp_call reaches as containers on npm-network). Missing/unparseable
# output is a warning only -- verify.sh already fails if the endpoint is down.
node_h=""
sync=""
xmrnode_token=$(env_value "$CONFIG_DIR/monero-node-mcp/token.env" MONERO_MCP_TOKEN)
if [ -n "$xmrnode_token" ]; then
    node_body=$(mcp_call monero-node-mcp "$xmrnode_token" get_info '{}') || node_body=""
    node_h=$(printf '%s' "$node_body" | grep -oE '\\?"height\\?":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)
    sync=$(printf '%s' "$node_body" | grep -oE '\\?"synchronized\\?":[[:space:]]*(true|false)' | grep -oE '(true|false)' | head -n1)
    if [ "$sync" = false ] && [ "$MONITOR_GRACE_SYNC" != 1 ]; then
        fail "monerod is not synchronized (height ${node_h:-?})"
    else
        ok "monerod height ${node_h:-?} (synchronized=${sync:-?})"
    fi
else
    soft "no MONERO_MCP_TOKEN; skipped the monerod height check"
fi

xmrwallet_token=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
if [ -n "$xmrwallet_token" ]; then
    w_body=$(mcp_call monero-wallet-mcp "$xmrwallet_token" get_height '{}') || w_body=""
    w_h=$(printf '%s' "$w_body" | grep -oE '\\?"height\\?":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)
    if [ -n "$node_h" ] && [ -n "$w_h" ] && [ "$((node_h - w_h))" -gt 10 ]; then
        soft "monero-wallet is behind monerod: wallet=$w_h node=$node_h"
    else
        ok "monero-wallet height ${w_h:-?}"
    fi
fi

# ---------------------------------------------------------------------------
# 3. the spend tripwire
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
        ok "no spend drift, no outgoing spends, ENABLE_SPENDING=0"
    else
        fail "spend-audit reported a problem"
    fi
fi

# ---------------------------------------------------------------------------
# 4. the record, the heartbeat, the alert
# ---------------------------------------------------------------------------
status=ok
[ "${#PROBLEMS[@]}" -gt 0 ] && status=fail
{
    printf '%s status=%s problems=%d warnings=%d\n' \
        "$(date -Is)" "$status" "${#PROBLEMS[@]}" "${#WARNS[@]}"
    for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do
        printf '%s   FAIL %s\n' "$(date -Is)" "$p"
    done
} >> "$AUDIT_LOG"

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

heartbeat() { # ok|fail
    [ -n "$MONITOR_PING_URL" ] || return 0
    local base url
    base="${MONITOR_PING_URL%/}"
    if [ "$1" = fail ]; then
        url="$base/fail"
        curl -fsS -m 15 -X POST --data-binary "$(summary)" "$url" >/dev/null 2>&1 \
            || soft "heartbeat POST failed"
    else
        curl -fsS -m 15 -X POST "$base" >/dev/null 2>&1 || soft "heartbeat POST failed"
    fi
}

notify() { # title body
    [ -n "$MONITOR_APPRISE_URLS" ] || return 0
    command -v podman >/dev/null 2>&1 || { soft "podman missing; cannot send the alert"; return 0; }
    local -a urls=()
    read -r -a urls <<< "$MONITOR_APPRISE_URLS"
    [ "${#urls[@]}" -gt 0 ] || return 0
    podman run --rm "$APPRISE_IMAGE" apprise -t "$1" -b "$2" "${urls[@]}" >/dev/null 2>&1 \
        || soft "apprise notification failed"
}

# One alert per state change: the digest of the failure set. A repeat of the
# same failure is not mailed again, but the heartbeat keeps failing until it is
# acknowledged (or fixed), which is the point.
digest=$(printf '%s\n' ${PROBLEMS[@]+"${PROBLEMS[@]}"} | sha256sum | awk '{print $1}')
prev=""
[ -f "$STATE_FILE" ] && prev=$(cat "$STATE_FILE")
if [ "$digest" != "$prev" ]; then
    if [ "${#PROBLEMS[@]}" -gt 0 ]; then
        notify "stack: ${#PROBLEMS[@]} problem(s)" "$(summary)"
    elif [ -n "$prev" ]; then
        # Only announce a recovery if a failure was recorded first; the very
        # first run on a fresh host is not a recovery.
        notify "stack: recovered" "all checks pass"
    fi
    printf '%s\n' "$digest" > "$STATE_FILE"
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    heartbeat fail
    say ""
    say "${#PROBLEMS[@]} problem(s):"
    printf '  - %s\n' "${PROBLEMS[@]}" | { [ "$QUIET" = 1 ] || cat; }
    exit 1
fi

heartbeat ok
say ""
say "all checks passed"
exit 0
