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
APPRISE_IMAGE="${APPRISE_IMAGE:-docker.io/caronc/apprise:2.0.2}"

# The unit passes these through EnvironmentFile; reading the file here too makes
# a hand run behave the same. env_value never sources the file.
MONITOR_PING_URL="${MONITOR_PING_URL:-$(env_value "$MONITOR_ENV" MONITOR_PING_URL)}"
MONITOR_APPRISE_URLS="${MONITOR_APPRISE_URLS:-$(env_value "$MONITOR_ENV" MONITOR_APPRISE_URLS)}"
MONITOR_GRACE_SYNC="${MONITOR_GRACE_SYNC:-$(env_value "$MONITOR_ENV" MONITOR_GRACE_SYNC)}"
MONITOR_GRACE_SYNC="${MONITOR_GRACE_SYNC:-1}"
MONITOR_VERIFY_ARGS="${MONITOR_VERIFY_ARGS:-$(env_value "$MONITOR_ENV" MONITOR_VERIFY_ARGS)}"
MONITOR_VERIFY_ARGS="${MONITOR_VERIFY_ARGS:---deep}"
# The host-check thresholds follow the same order as the four above -- the unit's
# EnvironmentFile when systemd runs it, then this file, then the default inside
# num_or below -- so `scripts/monitor.sh` by hand alerts on exactly what the
# timer would.
MONITOR_DISK_FREE_PCT="${MONITOR_DISK_FREE_PCT:-$(env_value "$MONITOR_ENV" MONITOR_DISK_FREE_PCT)}"
MONITOR_INODES_FREE_PCT="${MONITOR_INODES_FREE_PCT:-$(env_value "$MONITOR_ENV" MONITOR_INODES_FREE_PCT)}"
MONITOR_IO_UTIL_PCT="${MONITOR_IO_UTIL_PCT:-$(env_value "$MONITOR_ENV" MONITOR_IO_UTIL_PCT)}"
MONITOR_BACKUP_MAX_AGE_H="${MONITOR_BACKUP_MAX_AGE_H:-$(env_value "$MONITOR_ENV" MONITOR_BACKUP_MAX_AGE_H)}"
MONITOR_CERT_MIN_DAYS="${MONITOR_CERT_MIN_DAYS:-$(env_value "$MONITOR_ENV" MONITOR_CERT_MIN_DAYS)}"
MONITOR_RESTART_MAX="${MONITOR_RESTART_MAX:-$(env_value "$MONITOR_ENV" MONITOR_RESTART_MAX)}"
MONITOR_METRICS_MAX_AGE_S="${MONITOR_METRICS_MAX_AGE_S:-$(env_value "$MONITOR_ENV" MONITOR_METRICS_MAX_AGE_S)}"
MONITOR_FULCRUM_LAG_BLOCKS="${MONITOR_FULCRUM_LAG_BLOCKS:-$(env_value "$MONITOR_ENV" MONITOR_FULCRUM_LAG_BLOCKS)}"

# Defaults live here, not only in monitor.env, so an older env file (one written
# before these checks existed) still monitors. The helper and the one threshold
# the chain section reads live up here rather than with the host checks below.
num_or() { # value default
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}
# How far Fulcrum's index may sit behind bitcoind before it is a failure. A
# healthy one polls every 5s (--polltime) and is 0-1 block behind, so this is a
# "stopped following" threshold, not a "slightly late" one: 12 blocks is about
# two hours at 10 minutes a block.
THRESH_FULCRUM_LAG=$(num_or "${MONITOR_FULCRUM_LAG_BLOCKS:-}" 12)

PROBLEMS=()
WARNS=()
verify_failures=0
backup_age_s=""
backup_count=""
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

# Fulcrum, the Electrum server: the one daemon whose own port says the least. Its
# healthcheck is the process table (`grep -qx Fulcrum /proc/1/comm`), it keeps
# accepting connections and answering server.version while the index is wedged,
# and the wallet/explorer surface then silently serves stale heights. So ask it
# the index-backed question -- the tip it reports -- and compare with bitcoind.
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

lninfo=$(podman exec lightningd lightning-cli getinfo 2>/dev/null) || lninfo=""
if [ -z "$lninfo" ]; then
    fail "lightningd RPC unreachable"
else
    if printf '%s' "$lninfo" | grep -qE '"warning_bitcoind_sync"'; then
        fail "lightningd reports warning_bitcoind_sync (its view of bitcoind is stale)"
    fi
    # Peers and channels both come from the node's own view, not from getinfo:
    # getinfo's num_peers is "the total count of peers, connected or with
    # channels" (CLN's wording), so it stays >= 1 for a node whose only peer is
    # offline -- measured live: the peer container was stopped and this still
    # printed "1 peer(s)". listpeers carries `connected` per peer.
    #
    # Channels: listchannels is the gossip table (one entry per direction, for
    # every channel the node knows) and its `active` is the channel_update's
    # enabled bit -- an operator setting that stays true while the peer is
    # offline. It has no connectivity field, so a `grep '"connected": false'`
    # there matched nothing and the check passed every sweep. listpeerchannels
    # is the node's own view, with peer_connected and a state; only operational
    # channels count (an ONCHAIN one is meant to be alone).
    if command -v jq >/dev/null 2>&1; then
        lpeers=$(podman exec lightningd lightning-cli listpeers 2>/dev/null) || lpeers=""
        npeers=$(printf '%s' "$lpeers" | jq -r '[.peers[] | select(.connected)] | length' 2>/dev/null) || npeers=""
        if [ -z "$npeers" ]; then
            soft "could not read lightningd listpeers; skipped the peer check"
        elif [ "$npeers" = 0 ]; then
            soft "lightningd has no connected peers"
        else
            ok "lightningd has $npeers connected peer(s)"
        fi
        chans=$(podman exec lightningd lightning-cli listpeerchannels 2>/dev/null) || chans=""
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
    else
        soft "jq missing; skipped the lightning peer and channel checks"
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

# Defaults live here, not only in monitor.env, so an older env file (one written
# before these checks existed) still monitors. num_or is defined with the config
# above, because the chain section reads a threshold through it first.
THRESH_DISK=$(num_or "${MONITOR_DISK_FREE_PCT:-}" 10)
THRESH_INODES=$(num_or "${MONITOR_INODES_FREE_PCT:-}" 5)
THRESH_IO=$(num_or "${MONITOR_IO_UTIL_PCT:-}" 90)
THRESH_BACKUP_H=$(num_or "${MONITOR_BACKUP_MAX_AGE_H:-}" 36)
THRESH_CERT_D=$(num_or "${MONITOR_CERT_MIN_DAYS:-}" 14)
THRESH_RESTART=$(num_or "${MONITOR_RESTART_MAX:-}" 3)
THRESH_METRICS_S=$(num_or "${MONITOR_METRICS_MAX_AGE_S:-}" 300)

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

# Saturation, not space: a disk that is 100% busy at a few MB/s is why every
# chain crawls, and it is invisible in df. io_ticks (wall-clock milliseconds
# during which the device had I/O in flight) is field 10 of
# /sys/block/<dev>/stat -- note *10*, not the 13 of /proc/diskstats: the sysfs
# file omits major/minor/name, so it is three columns shorter. Sampling it twice
# gives percent-busy directly.
block_device() { # path -> the whole-disk name behind it (sda for sda1)
    local src name=""
    src=$(findmnt -no SOURCE --target "$1" 2>/dev/null) || return 1
    name=$(basename "$src")
    case "$name" in
        *p[0-9]*) name="${name%p[0-9]*}" ;;   # nvme0n1p1, mmcblk0p1
        *[0-9])   name="${name%[0-9]*}" ;;    # sda1, vda2
    esac
    [ -n "$name" ] && printf '%s' "$name"
}
dev=$(block_device "$DATA_DIR" || true)
if [ -n "${dev:-}" ] && [ -r "/sys/block/$dev/stat" ]; then
    io_a=$(awk '{print $10}' "/sys/block/$dev/stat")
    sleep 3
    io_b=$(awk '{print $10}' "/sys/block/$dev/stat")
    util=$(( (io_b - io_a) * 100 / 3000 ))
    [ "$util" -gt 100 ] && util=100
    if [ "$util" -ge "$THRESH_IO" ]; then
        soft "$dev (holding $DATA_DIR) was ${util}% busy over 3s; everything on it is queueing"
    else
        ok "$dev (holding $DATA_DIR) ${util}% busy"
    fi
else
    soft "could not identify the block device holding $DATA_DIR"
fi

# backup age: a timer that fires is not a repository that has a snapshot, and a
# fire-and-forget backup is the failure you find out about on restore day.
if command -v jq >/dev/null 2>&1; then
    if bjson=$("$REPO_DIR/scripts/backup.sh" list --json 2>/dev/null) \
        && printf '%s' "$bjson" | jq -e 'type == "array"' >/dev/null 2>&1; then
        backup_count=$(printf '%s' "$bjson" | jq 'length')
        latest=$(printf '%s' "$bjson" | jq -r 'map(.time) | max // empty' 2>/dev/null)
        if [ -n "$latest" ]; then
            latest_s=$(date -d "$latest" +%s 2>/dev/null || echo "")
            if [ -n "$latest_s" ]; then
                backup_age_s=$(( $(date +%s) - latest_s ))
                backup_age_h=$(( backup_age_s / 3600 ))
                if [ "$backup_age_h" -gt "$THRESH_BACKUP_H" ]; then
                    fail "no restic snapshot for ${backup_age_h}h (threshold ${THRESH_BACKUP_H}h)"
                else
                    ok "last backup ${backup_age_h}h ago ($backup_count snapshot(s))"
                fi
            fi
        fi
        [ -n "$backup_age_s" ] || soft "no restic snapshot yet (expected until the first backup runs)"
    else
        soft "could not list the restic repository (scripts/backup.sh list)"
    fi
else
    soft "jq missing; skipped the backup age check"
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

# Restart deltas between sweeps: systemd restarts a crashed unit and podman
# briefly reports it healthy again, so a crash loop can hide inside a green
# health check. Counted per sweep against the last one.
RESTART_STATE="$AUDIT_DIR/restarts"
declare -A prev_restarts=()
if [ -f "$RESTART_STATE" ]; then
    while read -r rname rcount; do
        [ -n "${rname:-}" ] && prev_restarts[$rname]="${rcount:-0}"
    done < "$RESTART_STATE"
fi
restart_state=""
restarted=0
if command -v systemctl >/dev/null 2>&1; then
    for c in $(podman ps --format '{{.Names}}' 2>/dev/null); do
        nr=$(systemctl --user show "$c.service" -p NRestarts --value 2>/dev/null || true)
        [ -n "$nr" ] || continue
        case "$nr" in (*[!0-9]*) continue ;; esac
        was="${prev_restarts[$c]:-0}"
        if [ "$nr" -gt "$((was + THRESH_RESTART))" ]; then
            fail "$c restarted $((nr - was)) time(s) since the last sweep"
            restarted=$((restarted + 1))
        fi
        restart_state+="$c $nr"$'\n'
    done
    printf '%s' "$restart_state" > "$RESTART_STATE" 2>/dev/null || true
    [ "$restarted" = 0 ] && ok "no unit restarted more than $THRESH_RESTART time(s) since the last sweep"
fi

# The collector that produces every graph. If it stops, the history stops and
# nothing else notices -- so the thing that is meant to give visibility is
# itself checked, from the outside.
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
else
    soft "metrics.timer is not active; the metrics pipeline is not checked"
fi

# ---------------------------------------------------------------------------
# 4. the spend tripwire
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
# 5. the record, the heartbeat, the alert
# ---------------------------------------------------------------------------
status=ok
[ "${#PROBLEMS[@]}" -gt 0 ] && status=fail

# The other half of node-exporter's textfile: the numbers this sweep has to
# compute anyway (backup age, the verifier's failures, spend trips), so they get
# history without scripts/metrics.sh paying for them again. prom_write owns the
# 0755/0644 permissions the exporter's uid needs.
{
    printf '# written by scripts/monitor.sh (deploy/monitor.timer)\n'
    printf 'stack_sweep_timestamp %s\n' "$(date +%s)"
    printf 'stack_verify_failures %s\n' "${verify_failures:-0}"
    printf 'stack_spend_trips %s\n' "${audit_trips:-0}"
    printf 'stack_monitor_problems %s\n' "${#PROBLEMS[@]}"
    printf 'stack_monitor_warnings %s\n' "${#WARNS[@]}"
    [ -n "$backup_age_s" ] && printf 'stack_backup_age_seconds %s\n' "$backup_age_s"
    [ -n "$backup_count" ] && printf 'stack_backup_snapshots %s\n' "$backup_count"
} | prom_write "$DATA_DIR/monitoring/textfile/monitor.prom" || soft "could not write monitor.prom"

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
