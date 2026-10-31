#!/usr/bin/env bash
# Health monitor and spend tripwire for the stack.
#
#   scripts/monitor.sh              # run every check, log, heartbeat, alert
#   scripts/monitor.sh --quiet      # no stdout (what deploy/monitor.service runs)
#   scripts/monitor.sh --no-verify  # skip the verify.sh base sweep
#   scripts/monitor.sh --test       # send one real alert through Alertmanager
#
# Driven by deploy/monitor.timer (a plain systemd user unit) every five minutes.
# Read-only: it starts nothing, restarts nothing and rewrites no config. It
# reuses verify.sh for the container/MCP base checks and adds the ones nothing
# else does -- chain freshness, CLN peers and channels, the Monero wallet's lag,
# and the spend tripwire in scripts/spend-audit.sh.
#
# This script decides WHAT is wrong; it does not decide when to say it. Each
# check section becomes one alert, pushed to Alertmanager
# ($MONITOR_ALERTMANAGER_URL, loopback :9093), which owns grouping, repeat
# intervals, inhibition, silences and delivery. The one state machine that stays
# here is the flap damper: an alert must be bad for MONITOR_ALERT_FOR seconds
# (two sweeps) before it is pushed at all, because Alertmanager only sees what
# is pushed at it and cannot tell a flapping check from one that never settled.
# A recovery is pushed explicitly (endsAt in the past) as soon as a sweep sees
# it, so it is not delayed by Alertmanager's resolve_timeout.
#
# Nothing here pauses a failing service; a failure fails the dead-man's-switch
# heartbeat ($MONITOR_PING_URL). A host that is down cannot report itself, and
# neither can a host whose mail is not leaving -- which is why the heartbeat
# also fails when the alert push fails or Alertmanager reports failed
# deliveries. That heartbeat is a plain outbound ping for exactly this reason.
#
# Config comes from $DATA_DIR/config/monitoring/monitor.env (the unit's
# EnvironmentFile); it is read here too so the script also runs by hand. Empty
# values mean "journal only": no heartbeat. The SMTP credentials live in
# $CONFIG_DIR/monitoring/alertmanager/alertmanager.yml, never here.
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

resolve_data_dir
AUDIT_DIR="$DATA_DIR/audit"
mkdir -p "$AUDIT_DIR"
MONITOR_ENV="$CONFIG_DIR/monitoring/monitor.env"
AUDIT_LOG="$AUDIT_DIR/audit.log"

# The unit passes these through EnvironmentFile; reading the file here too makes
# a hand run behave the same. env_value never sources the file.
MONITOR_PING_URL="${MONITOR_PING_URL:-$(env_value "$MONITOR_ENV" MONITOR_PING_URL)}"
MONITOR_ALERTMANAGER_URL="${MONITOR_ALERTMANAGER_URL:-$(env_value "$MONITOR_ENV" MONITOR_ALERTMANAGER_URL)}"
# Default on: the container is part of the stack now, so a host that upgrades
# gets alerting without an env edit. `off` is the explicit opt-out (an empty
# value cannot mean it: env_value returns nothing for both "absent" and
# "empty", which is why the sentinel is a word, not a blank).
MONITOR_ALERTMANAGER_URL="${MONITOR_ALERTMANAGER_URL:-http://127.0.0.1:9093}"
MONITOR_ALERT_FOR="${MONITOR_ALERT_FOR:-$(env_value "$MONITOR_ENV" MONITOR_ALERT_FOR)}"
MONITOR_GRACE_SYNC="${MONITOR_GRACE_SYNC:-$(env_value "$MONITOR_ENV" MONITOR_GRACE_SYNC)}"
MONITOR_GRACE_SYNC="${MONITOR_GRACE_SYNC:-1}"
MONITOR_VERIFY_ARGS="${MONITOR_VERIFY_ARGS:-$(env_value "$MONITOR_ENV" MONITOR_VERIFY_ARGS)}"
MONITOR_VERIFY_ARGS="${MONITOR_VERIFY_ARGS:---deep}"
# What every alert carries as its instance label: inhibition rules and a future
# federated setup both key on it, and it is what makes "critical here mutes the
# warnings here" expressible at all.
ALERT_INSTANCE="$(hostname -s 2>/dev/null || echo stack)"
# Where the pushed alert set and Alertmanager's delivery counter are remembered
# between sweeps. Both are host state, not config, so they live in audit/.
ALERT_STATE="$AUDIT_DIR/alerts.state"
ALERT_FAILED_FILE="$AUDIT_DIR/alertmanager.failed"

# The host-check thresholds follow the same order as the four above -- the unit's
# EnvironmentFile when systemd runs it, then this file, then the default inside
# num_or below -- so `scripts/monitor.sh` by hand alerts on exactly what the
# timer would.
MONITOR_DISK_FREE_PCT="${MONITOR_DISK_FREE_PCT:-$(env_value "$MONITOR_ENV" MONITOR_DISK_FREE_PCT)}"
MONITOR_INODES_FREE_PCT="${MONITOR_INODES_FREE_PCT:-$(env_value "$MONITOR_ENV" MONITOR_INODES_FREE_PCT)}"
MONITOR_IO_UTIL_PCT="${MONITOR_IO_UTIL_PCT:-$(env_value "$MONITOR_ENV" MONITOR_IO_UTIL_PCT)}"
MONITOR_BACKUP_MAX_AGE_H="${MONITOR_BACKUP_MAX_AGE_H:-$(env_value "$MONITOR_ENV" MONITOR_BACKUP_MAX_AGE_H)}"
MONITOR_BACKUP_VERIFY_MAX_AGE_H="${MONITOR_BACKUP_VERIFY_MAX_AGE_H:-$(env_value "$MONITOR_ENV" MONITOR_BACKUP_VERIFY_MAX_AGE_H)}"
MONITOR_CERT_MIN_DAYS="${MONITOR_CERT_MIN_DAYS:-$(env_value "$MONITOR_ENV" MONITOR_CERT_MIN_DAYS)}"
MONITOR_RESTART_MAX="${MONITOR_RESTART_MAX:-$(env_value "$MONITOR_ENV" MONITOR_RESTART_MAX)}"
MONITOR_METRICS_MAX_AGE_S="${MONITOR_METRICS_MAX_AGE_S:-$(env_value "$MONITOR_ENV" MONITOR_METRICS_MAX_AGE_S)}"
MONITOR_LOGS_MAX_AGE_S="${MONITOR_LOGS_MAX_AGE_S:-$(env_value "$MONITOR_ENV" MONITOR_LOGS_MAX_AGE_S)}"
MONITOR_FULCRUM_LAG_BLOCKS="${MONITOR_FULCRUM_LAG_BLOCKS:-$(env_value "$MONITOR_ENV" MONITOR_FULCRUM_LAG_BLOCKS)}"
# The chain section (below) reads these before the host checks define theirs, so
# they resolve here too, next to THRESH_FULCRUM_LAG which unblocks that order:
# bitcoind's peer floor and mempool cap, and monerod's lag behind its target.
MONITOR_BTC_MIN_PEERS="${MONITOR_BTC_MIN_PEERS:-$(env_value "$MONITOR_ENV" MONITOR_BTC_MIN_PEERS)}"
MONITOR_MEMPOOL_MB="${MONITOR_MEMPOOL_MB:-$(env_value "$MONITOR_ENV" MONITOR_MEMPOOL_MB)}"
MONITOR_XMR_LAG_BLOCKS="${MONITOR_XMR_LAG_BLOCKS:-$(env_value "$MONITOR_ENV" MONITOR_XMR_LAG_BLOCKS)}"
MONITOR_IDS_MAX_AGE_MIN="${MONITOR_IDS_MAX_AGE_MIN:-$(env_value "$MONITOR_ENV" MONITOR_IDS_MAX_AGE_MIN)}"
MONITOR_IDS_ALERT_WARN="${MONITOR_IDS_ALERT_WARN:-$(env_value "$MONITOR_ENV" MONITOR_IDS_ALERT_WARN)}"
MONITOR_BOUNCER_MAX_AGE_MIN="${MONITOR_BOUNCER_MAX_AGE_MIN:-$(env_value "$MONITOR_ENV" MONITOR_BOUNCER_MAX_AGE_MIN)}"
MONITOR_AUDIT_MAX_AGE_MIN="${MONITOR_AUDIT_MAX_AGE_MIN:-$(env_value "$MONITOR_ENV" MONITOR_AUDIT_MAX_AGE_MIN)}"

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
# The peer floor is deliberately 1: any peer count below it (i.e. zero) fails,
# and during IBD zero peers means the download is stalled, not protected --
# there is no grace here, unlike the height checks.
THRESH_BTC_PEERS=$(num_or "${MONITOR_BTC_MIN_PEERS:-}" 1)
# A warn, not a failure: bitcoind's default maxmempool is 300 MB and Core
# grows the mempool well into a fee storm before it rejects; this is the
# "look at the fees" signal long before anything else notices.
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
# A warn threshold, not a failure: one Suricata alert is not a page, and an
# operator who gets paged per alert stops reading them. The rate lives in
# VictoriaMetrics.
THRESH_IDS_ALERTS=$(num_or "${MONITOR_IDS_ALERT_WARN:-}" 20)
# How long a failing section must stay failing before it is pushed to
# Alertmanager. Two sweeps: anything shorter is the flapping this exists to
# stop, anything longer delays a real page. The `alerting` section bypasses it
# (a broken alert path is never a flap, and waiting ten minutes to say the mail
# is not leaving defeats the point).
THRESH_ALERT_FOR=$(num_or "${MONITOR_ALERT_FOR:-}" 600)
# The applier runs every minute; five missed runs is a stopped timer or a wedged
# nft, and either one means decisions are being made but nothing is enforcing.
THRESH_BOUNCER_AGE_M=$(num_or "${MONITOR_BOUNCER_MAX_AGE_MIN:-}" 5)
# The audit report runs every five minutes; four missed runs is a stopped timer.
THRESH_AUDIT_AGE_M=$(num_or "${MONITOR_AUDIT_MAX_AGE_MIN:-}" 20)

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
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/_/g; s/^_//; s/_$//'; }
head3() { say ""; say "$*"; SECTION=$(slug "$*"); }
ok()   { say "  ok    $*"; }
soft() { WARNS+=("$*");   WARN_SECTIONS+=("$SECTION");    say "  warn  $*"; }
fail() { PROBLEMS+=("$*"); PROBLEM_SECTIONS+=("$SECTION"); say "  FAIL  $*"; }

# ---------------------------------------------------------------------------
# 0. the alert path: what Alertmanager is told, and what is held back
# ---------------------------------------------------------------------------
# One alert per section, never per line. The section is the alert's identity
# (its label) and the lines are its annotation, so a changing number ("disk 9%
# free" vs "disk 8% free") is the same alert instead of a new one every sweep.
#
# What stays here instead of moving into Alertmanager is the flap damper.
# Alertmanager has group_wait/repeat_interval/inhibition/silences, but it only
# sees what is pushed at it: it cannot tell a check that fails every other sweep
# from one that has been down for an hour unless the producer holds the state.
# The state file is that memory -- name, service, severity, first seen, last
# pushed -- and it is also what makes explicit resolution possible.
emit_alerts() { # push the current set; resolve the sections that cleared
    [ "$MONITOR_ALERTMANAGER_URL" = off ] && return 0
    local now url i s name psev psince psent body starts ends
    local -A sev=() desc=() p_since=() p_sent=() p_svc=() p_sev=() current=()
    local payload='[]' resolved='[]' new_state='' retry_state=''
    now=$(date +%s)
    url="${MONITOR_ALERTMANAGER_URL%/}"

    if [ "${#PROBLEMS[@]}" -gt 0 ]; then
        for i in "${!PROBLEMS[@]}"; do
            s="${PROBLEM_SECTIONS[$i]}"
            sev[$s]=critical
            desc[$s]+="${desc[$s]:+$'\n'}- ${PROBLEMS[$i]}"
        done
    fi
    if [ "${#WARNS[@]}" -gt 0 ]; then
        for i in "${!WARNS[@]}"; do
            s="${WARN_SECTIONS[$i]}"
            [ "${sev[$s]:-}" = critical ] || sev[$s]=warning
            desc[$s]+="${desc[$s]:+$'\n'}- ${WARNS[$i]}"
        done
    fi

    if [ -f "$ALERT_STATE" ]; then
        while IFS=$'\t' read -r name s psev psince psent; do
            [ -n "$name" ] || continue
            p_since[$name]="$psince"
            p_sent[$name]="$psent"
            p_svc[$name]="$s"
            p_sev[$name]="$psev"
        done < "$ALERT_STATE"
    fi

    for s in ${sev[@]+"${!sev[@]}"}; do
        name="stack_$s"
        current[$name]=1
        psince="${p_since[$name]:-$now}"
        psent="${p_sent[$name]:-0}"
        # Hold-down: bad for THRESH_ALERT_FOR before it is ever pushed. Held
        # alerts are remembered but not posted, so the first-seen time survives
        # a sweep in which the check recovers and fails again.
        if [ "$s" != alerting ] && [ "$((now - psince))" -lt "$THRESH_ALERT_FOR" ]; then
            new_state+="$name"$'\t'"$s"$'\t'"${sev[$s]}"$'\t'"$psince"$'\t'"$psent"$'\n'
            retry_state+="$name"$'\t'"$s"$'\t'"${sev[$s]}"$'\t'"$psince"$'\t'"$psent"$'\n'
            continue
        fi
        starts=$(date -u -d "@$psince" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
            || starts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        body=$(jq -cn --arg n "$name" --arg svc "$s" --arg sev "${sev[$s]}" \
            --arg inst "$ALERT_INSTANCE" --arg d "${desc[$s]}" --arg st "$starts" \
            '{labels:{alertname:$n,severity:$sev,service:$svc,instance:$inst},
              annotations:{summary:("stack: " + $svc + " is " + $sev), description:$d},
              startsAt:$st}')
        payload=$(jq -c --argjson a "$body" '. + [$a]' <<< "$payload")
        new_state+="$name"$'\t'"$s"$'\t'"${sev[$s]}"$'\t'"$psince"$'\t'"$now"$'\n'
        retry_state+="$name"$'\t'"$s"$'\t'"${sev[$s]}"$'\t'"$psince"$'\t'"$psent"$'\n'
    done

    # What cleared. Resolving needs the ALERT's own labels, not the ones it
    # would have now, so they come back out of the state file. An alert that
    # never left (held, then cleared) is not "resolved" -- Alertmanager never
    # heard of it, and mailing a recovery for an alert nobody saw is noise.
    for name in ${p_since[@]+"${!p_since[@]}"}; do
        [ -n "${current[$name]:-}" ] && continue
        [ "${p_sent[$name]:-0}" -gt 0 ] || continue
        ends=$(date -u -d "@$((now - 1))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
            || ends=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        body=$(jq -cn --arg n "$name" --arg svc "${p_svc[$name]}" --arg sev "${p_sev[$name]}" \
            --arg inst "$ALERT_INSTANCE" --arg e "$ends" \
            '{labels:{alertname:$n,severity:$sev,service:$svc,instance:$inst}, endsAt:$e}')
        resolved=$(jq -c --argjson a "$body" '. + [$a]' <<< "$resolved")
        # Kept only for the failure path: an undelivered resolution is retried.
        retry_state+="$name"$'\t'"${p_svc[$name]}"$'\t'"${p_sev[$name]}"$'\t'"${p_since[$name]}"$'\t'"${p_sent[$name]}"$'\n'
    done

    body=$(jq -c -n --argjson f "$payload" --argjson r "$resolved" '$f + $r')
    if [ "$(jq -r 'length' <<< "$body")" = 0 ]; then
        printf '%s' "$new_state" > "$ALERT_STATE"
        return 0
    fi
    if curl -fsS -m 10 -H 'Content-Type: application/json' \
            --data-binary "$body" "$url/api/v2/alerts" >/dev/null 2>&1; then
        printf '%s' "$new_state" > "$ALERT_STATE"
        return 0
    fi
    # The retry state is written on purpose: the next sweep resumes with the
    # original first-seen time, so a failed push neither loses a pending
    # resolution nor restarts the hold-down, and nothing is marked delivered
    # that Alertmanager never received. The caller fails the heartbeat, which is
    # the only path that survives a broken alert channel.
    printf '%s' "$retry_state" > "$ALERT_STATE"
    say "  warn  could not push alerts to Alertmanager at $url (state kept for the next sweep)"
    return 1
}

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
    # Peers: the freshness check above has a blind spot -- a connected node
    # whose only peers vanished keeps its height while its sync stalls. The
    # floor defaults to 1, so any 0-peer read fails ("$THRESH" wording below);
    # this deliberately looks past IBD, where a stalled download is the same
    # fault as a stalled tip.
    json_peers=$(podman exec bitcoind bitcoin-cli getpeerinfo 2>/dev/null) || json_peers=""
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
    mp=$(podman exec bitcoind bitcoin-cli getmempoolinfo 2>/dev/null) || mp=""
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
        # Lag behind the network tip (get_info's target_height minus height).
        # A synchronized node sitting above the threshold is a fault: the RPC
        # surface (explorer, wallet-RPC) then answers, but serves a stale
        # chain. While not synchronized, the grace covers it as usual.
        target_h=$(printf '%s' "$node_body" | grep -oE '\\?"target_height\\?":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)
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
if [ -n "$xmrwallet_token" ]; then
    w_body=$(mcp_call monero-wallet-mcp "$xmrwallet_token" get_height '{}') || w_body=""
    w_h=$(printf '%s' "$w_body" | grep -oE '\\?"height\\?":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)
    if [ -z "$w_h" ]; then
        # No answer at all is not "fine": the wallet RPC is down, wedged or (the
        # usual cause) rebuilding its cache, and nothing else notices -- the
        # container can sit "Up (unhealthy)" for hours while every sweep reports
        # the height as "?".
        fail "monero-wallet does not answer get_height (wallet RPC down or rebuilding; podman logs monero-wallet-rpc)"
    elif [ -n "$node_h" ] && [ "$((node_h - w_h))" -gt 10 ]; then
        soft "monero-wallet is behind monerod: wallet=$w_h node=$node_h"
    else
        ok "monero-wallet height $w_h"
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
THRESH_VERIFY_H=$(num_or "${MONITOR_BACKUP_VERIFY_MAX_AGE_H:-}" 192)
THRESH_CERT_D=$(num_or "${MONITOR_CERT_MIN_DAYS:-}" 14)
THRESH_RESTART=$(num_or "${MONITOR_RESTART_MAX:-}" 3)
THRESH_METRICS_S=$(num_or "${MONITOR_METRICS_MAX_AGE_S:-}" 300)
# The log pipeline: how old the newest entry in the store may be. The shipper
# runs continuously, so this is a "stopped shipping" alarm, not a threshold --
# 15 minutes gives a restart of vector or the store room to come back.
THRESH_LOGS_S=$(num_or "${MONITOR_LOGS_MAX_AGE_S:-}" 900)
# The NIC's errs+drop columns, delta'd between sweeps like the restart counters:
# a carrier dropping packets is invisible to every chain check (all of them
# see is a slow sync) and to node-exporter's *counters* until someone looks.
MONITOR_NET_DROP="${MONITOR_NET_DROP:-$(env_value "$MONITOR_ENV" MONITOR_NET_DROP)}"
THRESH_NET_DROP=$(num_or "${MONITOR_NET_DROP:-}" 100)
# The hottest hwmon reading at sweep time; a warn, since this box is headless
# and a one-off spike (a compile, a busy sweep) is noise, while a climbing
# trend shows in the graphs node-exporter already exports from the same sysfs.
MONITOR_TEMP_MAX="${MONITOR_TEMP_MAX:-$(env_value "$MONITOR_ENV" MONITOR_TEMP_MAX)}"
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

# A credential rotation that died half-way leaves a journal behind, and nothing
# else notices: the daemons still hold the old value while the configs hold the
# new one, so the next restart is the surprise. The journal is the only state
# scripts/rotate.sh keeps, and `--resume` is the safe way out of it.
if compgen -G "$CONFIG_DIR/rotation/*.pending" >/dev/null; then
    for jf in "$CONFIG_DIR"/rotation/*.pending; do
        jt=$(basename "$jf" .pending)
        js=$(sed -n 's/^started=//p' "$jf" 2>/dev/null | head -n1)
        jstep=$(sed -n 's/^step=//p' "$jf" 2>/dev/null | head -n1)
        jage=""
        if [ -n "$js" ] && js_epoch=$(date -d "$js" +%s 2>/dev/null); then
            jsecs=$(( $(date +%s) - js_epoch ))
            if [ "$jsecs" -ge 3600 ]; then jage="$(( jsecs / 3600 ))h old"
            else jage="$(( jsecs / 60 ))m old"
            fi
        fi
        fail "credential rotation of $jt unfinished (step ${jstep:-?}${jage:+, started $jage}); finish it with scripts/rotate.sh --resume"
    done
else
    ok "no pending credential rotation"
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

# The restore drill (scripts/backup.sh verify, run weekly by backup-verify.timer):
# a repository that opens and lists is not a repository that restores. The age is
# measured from the last SUCCESS, not the last run -- a drill that skips (no disk
# space, an oversized set) must not look healthy just because the timer fired.
VERIFY_STATUS_FILE="$AUDIT_DIR/backup-verify.status"
if [ -f "$VERIFY_STATUS_FILE" ]; then
    vres=$(env_value "$VERIFY_STATUS_FILE" result)
    vok=$(num_or "$(env_value "$VERIFY_STATUS_FILE" ok_epoch)" "")
    vdetail=$(env_value "$VERIFY_STATUS_FILE" detail)
    if [ "$vres" = fail ]; then
        fail "backup restore drill failed: ${vdetail:-run scripts/backup.sh verify}"
        backup_verify_ok=0
    elif [ -n "$vok" ]; then
        backup_verify_age_s=$(( $(date +%s) - vok ))
        vage_h=$(( backup_verify_age_s / 3600 ))
        if [ "$vage_h" -gt "$THRESH_VERIFY_H" ]; then
            fail "no successful backup restore drill for ${vage_h}h (threshold ${THRESH_VERIFY_H}h, last result ${vres:-?})"
            backup_verify_ok=0
        elif [ "$vres" = skip ]; then
            soft "backup restore drill skipped: ${vdetail:-no detail} (last success ${vage_h}h ago)"
            backup_verify_ok=1
        else
            ok "backup restore drill passed ${vage_h}h ago"
            backup_verify_ok=1
        fi
    else
        soft "backup restore drill has no recorded success yet (expected until the first run)"
    fi
else
    soft "no backup restore drill yet (expected until backup-verify.timer runs)"
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

# The log pipeline. This is the ONE query the sweep makes against a store, and
# it is here because the question *is* the pipeline's own liveness: journald ->
# vector -> victoria-logs is three processes, and the failure that matters is
# the silent one (every unit "active", nothing arriving). A dead store or an
# empty window adds a problem; it cannot hide any other check, because every
# other check reads the daemons and the host directly.
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

# The carrier, read the way the restart counters above are: delta'd between
# sweeps, against a state file. The chain checks have a blind spot here -- a
# NIC shedding packets still shows as "syncing, just slowly", which is what
# every IBD looks like anyway.
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

# The hottest sensor, read off the same sysfs node-exporter graphs -- but the
# alert reads it here so the graphs being down does not cost the check.
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
# 5. intrusion detection -- through ids.sh's status file, never directly
# ---------------------------------------------------------------------------
head3 "intrusion detection"
# The engines are not touched from here: Suricata is a rootful system unit whose
# logs live in a root-owned directory, and crowdsec is queried through
# `podman exec`. scripts/ids.sh (deploy/ids.timer, at *:2/5 so it lands between
# sweeps) does both and leaves a verdict in $DATA_DIR/audit/ids.status. A wedged
# engine therefore shows up as a stale or failed status, which is the same
# contract as the backup drill's verdict -- and the reason a dead sensor cannot
# look healthy just because its unit is "active".
IDS_STATUS_FILE="$AUDIT_DIR/ids.status"
ids_alerts=0
ids_decisions=0
ids_up=0
if [ ! -f "$IDS_STATUS_FILE" ]; then
    soft "no IDS status yet (deploy/ids.timer has not run; sudo ./bootstrap.sh installs the sensor)"
else
    ires=$(env_value "$IDS_STATUS_FILE" result)
    iok=$(num_or "$(env_value "$IDS_STATUS_FILE" ok_epoch)" "")
    idetail=$(env_value "$IDS_STATUS_FILE" detail)
    ids_alerts=$(num_or "$(env_value "$IDS_STATUS_FILE" alerts)" 0)
    ids_decisions=$(num_or "$(env_value "$IDS_STATUS_FILE" decisions)" 0)
    isuri=$(env_value "$IDS_STATUS_FILE" suricata)
    icrowd=$(env_value "$IDS_STATUS_FILE" crowdsec)
    if [ "$ires" = fail ]; then
        fail "intrusion detection is degraded: ${idetail:-see $AUDIT_LOG}"
        ids_up=0
    elif [ -z "$iok" ]; then
        soft "IDS status has no ok_epoch yet"
    else
        ids_age_s=$(( $(date +%s) - iok ))
        ids_age_m=$(( ids_age_s / 60 ))
        if [ "$ids_age_m" -gt "$THRESH_IDS_AGE_M" ]; then
            fail "the IDS has not reported for ${ids_age_m} min (ids.timer stopped, or ids.sh cannot read the sensor)"
        else
            ids_up=1
            ok "IDS: suricata=$isuri crowdsec=$icrowd, $ids_alerts alert(s), $ids_decisions decision(s)"
        fi
    fi
    # Alerts are a report, not a page: Suricata's output needs a human to read it,
    # and a page per alert would make the sweep's signal unreadable. The counter
    # goes to VictoriaMetrics so a change in *rate* is visible without one.
    if [ "$ids_alerts" -gt "$THRESH_IDS_ALERTS" ]; then
        soft "$ids_alerts Suricata alert(s) since the last report (threshold $THRESH_IDS_ALERTS) -- read $DATA_DIR/ids/suricata/eve.json"
    fi
fi

# The audit report: host-level changes that no script in this repo makes
# (account databases, sudoers, sshd, audit's own config), plus the hash diff over
# the persistence directories -- which is the part that catches a *new* unit file,
# because this kernel emits no audit events for directory watches.
AUDIT_STATUS_FILE="$AUDIT_DIR/auditd.status"
audit_fim=0
if [ -f /etc/systemd/system/stack-audit.timer ]; then
    if [ ! -f "$AUDIT_STATUS_FILE" ]; then
        soft "no audit report yet (stack-audit.timer has not run)"
    else
        ares=$(env_value "$AUDIT_STATUS_FILE" result)
        aok=$(num_or "$(env_value "$AUDIT_STATUS_FILE" ok_epoch)" "")
        adetail=$(env_value "$AUDIT_STATUS_FILE" detail)
        audit_fim=$(num_or "$(env_value "$AUDIT_STATUS_FILE" fim)" 0)
        if [ "$ares" = fail ]; then
            fail "host-level configuration changed: ${adetail:-see $AUDIT_STATUS_FILE}"
        elif [ -z "$aok" ]; then
            soft "the audit report has no ok_epoch yet"
        else
            aage_m=$(( ($(date +%s) - aok) / 60 ))
            if [ "$aage_m" -gt "$THRESH_AUDIT_AGE_M" ]; then
                fail "the audit report has not run for ${aage_m} min (systemctl status stack-audit.timer)"
            else
                if [ "$(env_value "$AUDIT_STATUS_FILE" audit)" = inert ]; then
                    ok "audit: ${audit_fim} persistence-dir change(s); the kernel audit subsystem emits nothing on this host, so the hash diff is the live check"
                else
                    ok "audit: no host-level changes; ${audit_fim} persistence-dir change(s) reported"
                fi
            fi
        fi
    fi
fi
# The applier. A separate check from the engines on purpose: detection can be
# perfectly healthy while nothing enforces (a stopped timer, a wrong key, an nft
# that refuses the table), and that is the state where the host believes it is
# protected and is not.
BOUNCER_STATUS_FILE="$AUDIT_DIR/bouncer.status"
bouncer_bans=0
if [ -f /etc/systemd/system/stack-bouncer.timer ]; then
    if [ ! -f "$BOUNCER_STATUS_FILE" ]; then
        soft "no bouncer status yet (stack-bouncer.timer has not run)"
    else
        bres=$(env_value "$BOUNCER_STATUS_FILE" result)
        bok=$(num_or "$(env_value "$BOUNCER_STATUS_FILE" ok_epoch)" "")
        bdetail=$(env_value "$BOUNCER_STATUS_FILE" detail)
        bouncer_bans=$(num_or "$(env_value "$BOUNCER_STATUS_FILE" banned)" 0)
        if [ "$bres" = fail ]; then
            fail "the bouncer is not applying decisions: ${bdetail:-see $AUDIT_DIR/bouncer.status}"
        elif [ -z "$bok" ]; then
            soft "bouncer status has no ok_epoch yet"
        else
            bage_m=$(( ($(date +%s) - bok) / 60 ))
            if [ "$bage_m" -gt "$THRESH_BOUNCER_AGE_M" ]; then
                fail "the bouncer has not applied decisions for ${bage_m} min (systemctl status stack-bouncer.timer)"
            else
                ok "bouncer: ${bouncer_bans} address(es) banned"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 6. the alert path itself
# ---------------------------------------------------------------------------
# Checked before the record so a broken path shows up in the same sweep's exit
# code and audit log. Two failures are distinguishable here and nowhere else:
# Alertmanager not answering, and Alertmanager answering but failing to deliver.
# The second one can never be reported through the channel it broke, which is
# why it is remembered as a counter and turned into a page on the *next* sweep
# -- and why the heartbeat is pushed after this block: "all checks pass but
# nobody can be told" must fail it.
head3 "alerting"
am_ok=1
if [ "$MONITOR_ALERTMANAGER_URL" = off ]; then
    ok "alerting is off (MONITOR_ALERTMANAGER_URL=off): journal only"
else
    am_url="${MONITOR_ALERTMANAGER_URL%/}"
    am_code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$am_url/-/healthy" 2>/dev/null) || am_code=""
    if [ "$am_code" != 200 ]; then
        am_ok=0
        fail "Alertmanager does not answer at $am_url/-/healthy: alerts are going nowhere (the heartbeat carries this one)"
    fi
    # Cumulative since the process started, so a restart (a smaller number) is
    # not a failure; only a growth since the last sweep is.
    am_failed=$(curl -fsS -m 5 "$am_url/metrics" 2>/dev/null \
        | awk '/^alertmanager_notifications_failed_total\{/ {s += $NF} END {printf "%d", s + 0}')
    am_prev=$(cat "$ALERT_FAILED_FILE" 2>/dev/null) || am_prev=""
    if [ -n "$am_failed" ]; then
        if [ -n "$am_prev" ] && [ "$am_failed" -gt "$am_prev" ]; then
            am_ok=0
            fail "Alertmanager failed to deliver $((am_failed - am_prev)) notification(s) since the last sweep (SMTP or receiver; podman logs alertmanager)"
        fi
        printf '%s\n' "$am_failed" > "$ALERT_FAILED_FILE" 2>/dev/null || true
    fi
    [ "$am_ok" = 1 ] && ok "Alertmanager answers, and nothing failed to deliver since the last sweep"
fi

# ---------------------------------------------------------------------------
# 7. the record, the heartbeat, the alert
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

# The push, then the heartbeat's verdict. Order is load-bearing: a host whose
# checks all pass but whose alerts cannot leave must still fail the heartbeat,
# because the email about that failure would take the same broken path.
alert_push_ok=1
emit_alerts || alert_push_ok=0

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    heartbeat fail "$(summary)"
elif [ "$alert_push_ok" = 0 ]; then
    heartbeat fail "monitor: every check passed, but the alert push to $MONITOR_ALERTMANAGER_URL failed -- the alert path is broken, see the journal"
else
    heartbeat ok
fi

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
    printf 'stack_monitor_alert_push %s\n' "$alert_push_ok"
    printf 'stack_monitor_alertmanager_up %s\n' "${am_ok:-1}"
    [ -n "$backup_age_s" ] && printf 'stack_backup_age_seconds %s\n' "$backup_age_s"
    [ -n "$backup_count" ] && printf 'stack_backup_snapshots %s\n' "$backup_count"
    [ -n "$backup_verify_age_s" ] && printf 'stack_backup_verify_age_seconds %s\n' "$backup_verify_age_s"
    [ -n "$backup_verify_ok" ] && printf 'stack_backup_verify_ok %s\n' "$backup_verify_ok"
    printf 'stack_ids_up %s\n' "${ids_up:-0}"
    printf 'stack_ids_alerts %s\n' "${ids_alerts:-0}"
    printf 'stack_ids_decisions %s\n' "${ids_decisions:-0}"
    printf 'stack_bouncer_bans %s\n' "${bouncer_bans:-0}"
    printf 'stack_audit_fim_changes %s\n' "${audit_fim:-0}"
    printf 'stack_logs_ok %s\n' "${logs_ok:-0}"
} | prom_write "$DATA_DIR/monitoring/textfile/monitor.prom" || soft "could not write monitor.prom"

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

if [ "$alert_push_ok" = 0 ]; then
    say ""
    say "all checks passed, but the alert push failed (see above)"
    exit 1
fi

say ""
say "all checks passed"
exit 0
