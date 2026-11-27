#!/usr/bin/env bash
# Health monitor and spend tripwire for the stack.
#
#   scripts/monitor.sh              # run every check, log, heartbeat, alert
#   scripts/monitor.sh --quiet      # no stdout; failures go to stderr (monitor.service)
#   scripts/monitor.sh --no-verify  # skip the verify.sh base sweep
#   scripts/monitor.sh --test       # send one real alert through Alertmanager
#
# It finds WHAT is wrong and writes it as metrics: one stack_monitor_check
# series per failing component/check (plus its detail) and one
# stack_component_up/health sample per expected container, so a dead service and
# its symptoms share a component label. stack_monitor_section stays as the human
# roll-up and history graph. The rules vmalert loads (deploy/monitoring/rules/)
# decide WHEN a fault has lasted long enough to page, and Alertmanager owns
# grouping, inhibition, silences and delivery. No alert state lives in this
# script -- `for:` damps the onset and `keep_firing_for:` the reset, so there is
# no explicit endsAt to remember and no lock to take.
#
# Four checks (unit restarts, disk saturation, Suricata bursts, SSH auth
# failures) are decided in the rules over a window, not here: their fact is a
# rate, and a per-sweep verdict on a rate is an event that fires and resolves
# around every burst.
#
# A broken sweep or alert path fails the dead-man's-switch heartbeat -- a host
# that is down cannot report itself, and neither can one whose mail is not
# leaving, so the heartbeat also fails when the facts could not be written or
# when the alert path itself (the store, vmalert, Alertmanager, or its
# deliveries) is broken. A finding does not fail it: that is the rules' job, and
# a second copy on the heartbeat is how every fault arrived twice.
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
MONITOR_IDS_RULES_MAX_AGE_H=$(monitor_var MONITOR_IDS_RULES_MAX_AGE_H)
MONITOR_IDS_UPDATE_MAX_AGE_H=$(monitor_var MONITOR_IDS_UPDATE_MAX_AGE_H)
MONITOR_BOUNCER_MAX_AGE_MIN=$(monitor_var MONITOR_BOUNCER_MAX_AGE_MIN)
MONITOR_AUDIT_MAX_AGE_MIN=$(monitor_var MONITOR_AUDIT_MAX_AGE_MIN)
MONITOR_REGISTRATIONS_MAX_AGE_MIN=$(monitor_var MONITOR_REGISTRATIONS_MAX_AGE_MIN)
MONITOR_SMART_MAX_AGE_H=$(monitor_var MONITOR_SMART_MAX_AGE_H)
# The SMART attributes are facts in the root probe's file; these are the policy
# thresholds the sweep applies. Reallocated and pending sectors fail by default
# because any growth is a drive retiring/unstable area; raise the realloc limit
# only for a disk with a known historical count. Temperature warns earlier than
# the hwmon check: a rotational disk is rated near 60C, not 85C.
MONITOR_SMART_REALLOC_MAX=$(monitor_var MONITOR_SMART_REALLOC_MAX)
MONITOR_SMART_PENDING_MAX=$(monitor_var MONITOR_SMART_PENDING_MAX)
MONITOR_SMART_TEMP_MAX=$(monitor_var MONITOR_SMART_TEMP_MAX)
# How long after a container starts its dependent checks are treated as
# "starting", not failing. A container that is actually down is not graced --
# stack_component_up and the component rule still page at once. 0 disables it.
MONITOR_STARTUP_GRACE_S=$(monitor_var MONITOR_STARTUP_GRACE_S)
STARTUP_GRACE_S=$(num_or "${MONITOR_STARTUP_GRACE_S:-}" 900)
# The floor on how long Fulcrum's last "Processed height" log line stays
# evidence of an active reindex. It logs every 1000 blocks, so the expected gap
# is the line cadence, not this: the sweep measures the gap between the last two
# lines and allows 1.5x, because a slow index can take hours per 1000 blocks and
# a fixed window would call a live reindex stalled.
MONITOR_INDEX_PROGRESS_MAX_AGE_MIN=$(monitor_var MONITOR_INDEX_PROGRESS_MAX_AGE_MIN)
THRESH_INDEX_PROGRESS_S=$(( $(num_or "${MONITOR_INDEX_PROGRESS_MAX_AGE_MIN:-}" 360) * 60 ))
# How recently Fulcrum's RocksDB WAL must have been written to call the index
# alive when the 1000-block line is overdue or absent (a restart starts with an
# empty container log). Every block commits to the WAL, so a quarter hour of
# silence is a stopped index, not a slow one.
FULCRUM_DB_ACTIVE_S=900

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

# How old each scheduled job's verdict file may be, in seconds -- the whole of
# the per-job input to verdict_judge (scripts/lib/jobs.sh), whose default and unit
# sit together here rather than being split across a THRESH_ and a monitor_var
# line. The job names are the ones verdict_judge's callers pass.
#   ids: every five minutes, 20 gives four missed runs (or one long deploy that
#   restarted the engines) before the sweep calls it stale -- the check that
#   notices a sensor whose unit reads "active" while the engine inside stopped.
#   suricata-update / crowdsec-update: weekly; 336h (14 days) is two missed runs.
#   bouncer: every minute; five missed runs is a stopped timer or a wedged nft,
#   either of which means decisions are made and nothing is enforcing.
#   registrations: every minute; thirty missed runs is a stopped timer or a host
#   that cannot reach postgres.
#   auditd: every five minutes; four missed runs is a stopped timer.
#   smart: every hour; six missed runs is a stopped timer or a root probe that
#   cannot open the disks.
verdict_age() { # job -> seconds
    case "$1" in
        backup-verify)    printf '%s' $(( $(num_or "$MONITOR_BACKUP_VERIFY_MAX_AGE_H" 192) * 3600 )) ;;
        backup-verify-db) printf '%s' $(( $(num_or "$MONITOR_BACKUP_VERIFY_DB_MAX_AGE_H" 1080) * 3600 )) ;;
        ids)              printf '%s' $(( $(num_or "$MONITOR_IDS_MAX_AGE_MIN" 20) * 60 )) ;;
        suricata-update|crowdsec-update)
                          printf '%s' $(( $(num_or "$MONITOR_IDS_UPDATE_MAX_AGE_H" 336) * 3600 )) ;;
        bouncer)          printf '%s' $(( $(num_or "$MONITOR_BOUNCER_MAX_AGE_MIN" 5) * 60 )) ;;
        auditd)           printf '%s' $(( $(num_or "$MONITOR_AUDIT_MAX_AGE_MIN" 20) * 60 )) ;;
        registrations)    printf '%s' $(( $(num_or "$MONITOR_REGISTRATIONS_MAX_AGE_MIN" 30) * 60 )) ;;
        smart)            printf '%s' $(( $(num_or "$MONITOR_SMART_MAX_AGE_H" 6) * 3600 )) ;;
        *)                die "verdict_age: unknown job $1" ;;
    esac
}

PROBLEMS=()
WARNS=()
# Every finding keeps its section (the human grouping and the history series)
# and its component/check pair (the alert identity). Without the second pair,
# one dead btc-explorer is a unit fault, a verify failure and a 502, and
# Alertmanager cannot inhibit the two symptoms of the one cause.
PROBLEM_SECTIONS=()
WARN_SECTIONS=()
PROBLEM_COMPONENTS=()
WARN_COMPONENTS=()
PROBLEM_CHECKS=()
WARN_CHECKS=()
SECTION="other"
COMPONENT="other"
CHECK="other"
verify_failures=0
backup_age_s=""
backup_count=""
backup_verify_age_s=""
backup_verify_ok=""
backup_verify_db_age_s=""
backup_verify_db_ok=""
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/_/g; s/^_//; s/_$//'; }
# Component labels are container/unit names, so they keep `.` and `-`:
# stack_component_up{component="btc-explorer"} is what StackComponentDown
# inhibits against. Checks are slugs (rpc_password, unit_failed).
component_label() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]\+/_/g; s/^_//; s/_$//'; }
scope() { # component check
    COMPONENT=$(component_label "$1"); [ -n "$COMPONENT" ] || COMPONENT=other
    CHECK=$(slug "$2");                [ -n "$CHECK" ]     || CHECK=other
}
head3() { say ""; say "$*"; SECTION=$(slug "$*"); scope "$SECTION" "$SECTION"; }
ok()      { say "  ok    $*"; }
starting(){ say "  skip  $*"; }
soft() {
    local comp chk
    comp=$(component_label "${2:-$COMPONENT}"); [ -n "$comp" ] || comp=other
    chk=$(slug "${3:-$CHECK}");                [ -n "$chk" ] || chk=other
    WARNS+=("$1"); WARN_SECTIONS+=("$SECTION")
    WARN_COMPONENTS+=("$comp"); WARN_CHECKS+=("$chk")
    say "  warn  $1"
}
fail() {
    local comp chk
    comp=$(component_label "${2:-$COMPONENT}"); [ -n "$comp" ] || comp=other
    chk=$(slug "${3:-$CHECK}");                [ -n "$chk" ] || chk=other
    PROBLEMS+=("$1"); PROBLEM_SECTIONS+=("$SECTION")
    PROBLEM_COMPONENTS+=("$comp"); PROBLEM_CHECKS+=("$chk")
    say "  FAIL  $1"
}

# verify.sh's free text names the component a line is about, and that name is
# the alert's identity. The mapping is explicit: a line that falls through is
# "verify/verify", not a new alert for every changing message.
classify_verify_line() { # message -> "component check"
    local msg lmsg comp check
    msg=$1
    lmsg=$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')
    # Component-specific names first: "fulcrum ... behind bitcoind" and
    # "btc-explorer ... bitcoind RPC unreachable" both mention bitcoind, and the
    # last pattern would otherwise win.
    case "$lmsg" in
        *fulcrum*)           comp=fulcrum;             check=electrum ;;
        *lightningd*sync*)   comp=lightningd;          check=sync ;;
        *lightningd*peer*)   comp=lightningd;          check=peers ;;
        *lightningd*rpc*|*lightningd*unreachable*)
                             comp=lightningd;          check=rpc ;;
        *lightningd*|*"lightning channel"*)
                             comp=lightningd;          check=channels ;;
        *monerod*sync*|*monerod*behind*|*monerod*height*)
                             comp=monerod;             check=sync ;;
        *monerod*)           comp=monerod;             check=rpc ;;
        *monero-wallet*)     comp=monero-wallet-btcpay; check=wallet ;;
        *btc-explorer*)      comp=btc-explorer;        check=explorer ;;
        *xmr-explorer*)      comp=xmr-explorer;        check=explorer ;;
        *btcpay*)            comp=btcpay;              check=health ;;
        *postgres*)          comp=postgres;            check=health ;;
        *valkey*)            comp=valkey;              check=health ;;
        *victoriametrics*|*vmalert*|*alertmanager*)
                             comp=alerting;            check=alert_path ;;
        *nginx-proxy-manager*|*"npm "*)
                             comp=nginx-proxy-manager; check=proxy ;;
        *searxng*)           comp=searxng;             check=health ;;
        *crowdsec*)          comp=crowdsec;            check=health ;;
        *suricata*)          comp=suricata;            check=health ;;
        *uptime-kuma*)       comp=uptime-kuma;         check=health ;;
        *tor:*|*"tor is"*)   comp=tor;                 check=health ;;
        *netcheck*)          comp=netcheck;            check=health ;;
        *bitcoind*behind*|*bitcoind*blocks*|*bitcoind*headers*)
                             comp=bitcoind;            check=sync ;;
        *bitcoind*peer*)     comp=bitcoind;            check=peers ;;
        *bitcoind*mempool*)  comp=bitcoind;            check=mempool ;;
        *bitcoind*)          comp=bitcoind;            check=rpc ;;
        *)                   comp=verify;              check=verify ;;
    esac
    printf '%s %s\n' "$comp" "$check"
}

# A container's state from one `podman ps` read, and how long ago it started.
# `component_starting` is deliberately false for a down or unhealthy container:
# a crash loop is a fault, not a slow start, and stack_component_up owns it.
# The caches matter: verify.sh can contribute dozens of lines, and every one
# would otherwise be a fresh podman call.
declare -A COMPONENT_STATE_CACHE=() COMPONENT_START_CACHE=()
component_state() { # container -> healthy|unhealthy|starting|up|down|other
    local c=$1 state
    if [ -n "${COMPONENT_STATE_CACHE[$c]+x}" ]; then
        printf '%s' "${COMPONENT_STATE_CACHE[$c]}"
        return 0
    fi
    state=$(container_health_state "$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null)")
    COMPONENT_STATE_CACHE[$c]=$state
    printf '%s' "$state"
}
within_startup_grace() { # container
    local c=$1 ts now
    [ "$STARTUP_GRACE_S" -gt 0 ] || return 1
    if [ -n "${COMPONENT_START_CACHE[$c]+x}" ]; then
        ts=${COMPONENT_START_CACHE[$c]}
    else
        ts=$(podman inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null) || return 1
        # podman prints Go's time as "YYYY-MM-DD HH:MM:SS.nnnnnnnnn +0400 +04";
        # date(1) rejects the trailing zone abbreviation, so drop it first.
        ts=${ts% +*}
        ts=$(date -d "$ts" +%s 2>/dev/null) || return 1
        COMPONENT_START_CACHE[$c]=$ts
    fi
    now=$(date +%s)
    [ $((now - ts)) -lt "$STARTUP_GRACE_S" ]
}
component_starting() { # container
    case "$(component_state "$1")" in
        healthy|up|starting) within_startup_grace "$1" ;;
        *) return 1 ;;
    esac
}

# Fulcrum writes "Processed height: N, P%, ..." every 1000 blocks while it
# indexes, and its Electrum port serves nothing until the index catches up. A
# restart can put it days behind, so "not answering" is not enough to call it
# broken. The line is the fact; there is no producer state file, and a healthy
# Fulcrum never reaches this function.
#
# The age alone cannot say "stalled": 1000 blocks is the clock, and on a
# rotational disk that can be hours. The gap between the last two lines is the
# measured cadence (1.5x for wobble); the configured threshold is only the floor.
fulcrum_index_progress() { # -> "height pct age_seconds limit_seconds", empty when no progress line
    local lines line prev ts prev_ts height prev_height pct now age limit expected
    lines=$(podman logs --timestamps --tail 400 fulcrum 2>/dev/null \
        | grep 'Processed height') || return 0
    [ -n "$lines" ] || return 0
    line=$(printf '%s\n' "$lines" | tail -n1)
    ts=$(date -d "${line%% *}" +%s 2>/dev/null) || return 0
    height=$(printf '%s' "$line" | sed -n 's/.*Processed height: \([0-9][0-9]*\).*/\1/p')
    pct=$(printf '%s' "$line" | sed -n 's/.*, \([0-9][0-9.]*\)%.*/\1/p')
    [ -n "$height" ] || return 0
    now=$(date +%s)
    age=$((now - ts))
    [ "$age" -ge 0 ] || return 0
    limit=$THRESH_INDEX_PROGRESS_S
    prev=$(printf '%s\n' "$lines" | tail -n2 | sed -n '1p')
    if prev_ts=$(date -d "${prev%% *}" +%s 2>/dev/null); then
        prev_height=$(printf '%s' "$prev" | sed -n 's/.*Processed height: \([0-9][0-9]*\).*/\1/p')
        if [ -n "$prev_height" ] && [ "$ts" -gt "$prev_ts" ] && [ "$height" -gt "$prev_height" ]; then
            expected=$(( (ts - prev_ts) * 1000 / (height - prev_height) ))
            limit=$(( expected * 3 / 2 ))
        fi
    fi
    [ "$limit" -lt "$THRESH_INDEX_PROGRESS_S" ] && limit=$THRESH_INDEX_PROGRESS_S
    printf '%s %s %s %s\n' "$height" "${pct:-?}" "$age" "$limit"
}

# Seconds since Fulcrum last wrote its RocksDB write-ahead log, empty when the
# DB is not there. A block commits to the WAL, so this is the "the index is
# still advancing" fact when the 1000-block line is overdue or absent; the line
# alone cannot tell a stretched cadence from a stop.
fulcrum_db_age() {
    local wal mtime
    wal=$(find "$DATA_DIR/fulcrum/fulc2_db" -maxdepth 1 -name '*.log' \
        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-) || return 0
    [ -n "$wal" ] || return 0
    mtime=$(stat -c %Y -- "$wal" 2>/dev/null) || return 0
    printf '%s\n' $(( $(date +%s) - mtime ))
}

# Set before the verify sweep: both that sweep's Fulcrum lines and the chain
# section below would otherwise report the same multi-day catch-up as a critical.
# Only an Electrum probe that fails is worth the log read, and only a container
# that is up: a down Fulcrum is StackComponentDown's fault, not a reindex.
# FULCRUM_INDEXING=1 means the index is advancing -- the line is inside its
# cadence, or the WAL is still being written; STALLED means the line is overdue
# and the WAL has gone quiet, which is the only case worth a critical.
FULCRUM_INDEXING=0
FULCRUM_INDEX_STALLED=0
FULCRUM_INDEX_DETAIL=""
fulcrum_index_state() {
    [ "$MONITOR_SKIP_NODES" = 1 ] && return 0
    case "$(component_state fulcrum)" in
        healthy|up|starting) ;;
        *) return 0 ;;
    esac
    [ -z "$(electrum_tip 50001)" ] || return 0
    local progress height pct age limit mins db_age
    progress=$(fulcrum_index_progress) || return 0
    if [ -n "$progress" ]; then
        read -r height pct age limit <<< "$progress"
        mins=$((age / 60))
        if [ "$age" -le "$limit" ]; then
            FULCRUM_INDEXING=1
            FULCRUM_INDEX_DETAIL="fulcrum is reindexing: ${pct}% (height ${height}), last progress ${mins}m ago; Electrum is unavailable until the index catches up (no action unless progress stops)"
            return 0
        fi
        db_age=$(fulcrum_db_age) || db_age=""
        if [ -n "$db_age" ] && [ "$db_age" -le "$FULCRUM_DB_ACTIVE_S" ]; then
            FULCRUM_INDEXING=1
            FULCRUM_INDEX_DETAIL="fulcrum is reindexing: ${pct}% (height ${height}), last progress ${mins}m ago; the 1000-block line is overdue but the DB is still being written, so Electrum stays unavailable until the index catches up (no action unless the DB stops changing)"
        elif [ "$mins" -ge 60 ]; then
            FULCRUM_INDEX_STALLED=1
            FULCRUM_INDEX_DETAIL="fulcrum stopped progressing at ${pct}% (height ${height}), last log line $((mins / 60))h ago; Electrum is unavailable (podman logs --tail 50 fulcrum)"
        else
            FULCRUM_INDEX_STALLED=1
            FULCRUM_INDEX_DETAIL="fulcrum stopped progressing at ${pct}% (height ${height}), last log line ${mins}m ago; Electrum is unavailable (podman logs --tail 50 fulcrum)"
        fi
        return 0
    fi
    # A restarted Fulcrum has no progress line until it has processed another
    # 1000 blocks -- the container log starts empty -- so the line is not the
    # fact yet. A WAL that is still being written is a reindex; only a quiet DB
    # is the stall the critical level is for.
    db_age=$(fulcrum_db_age) || db_age=""
    if [ -n "$db_age" ] && [ "$db_age" -le "$FULCRUM_DB_ACTIVE_S" ]; then
        FULCRUM_INDEXING=1
        FULCRUM_INDEX_DETAIL="fulcrum is reindexing: no progress line yet (the DB was written $((db_age / 60))m ago); Electrum is unavailable until the index catches up (no action unless the DB stops changing)"
    elif [ -n "$db_age" ]; then
        FULCRUM_INDEX_STALLED=1
        FULCRUM_INDEX_DETAIL="fulcrum is not answering Electrum and its index has not advanced for $((db_age / 60))m (no progress line; podman logs --tail 50 fulcrum)"
    fi
}

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
        '[{labels:{alertname:"stack_test",severity:"test",service:"alerting",component:"alerting",check:"test",instance:$inst},
           annotations:{summary:"alerting/test is failing",description:"Sent by scripts/monitor.sh --test; it resolves in two minutes."},
           startsAt:$s, endsAt:$e}]')
    curl -fsS -m 10 -H 'Content-Type: application/json' \
        --data-binary "$body" "$url/api/v2/alerts" >/dev/null \
        || die "could not post a test alert to $url/api/v2/alerts"
    printf 'test alert accepted by %s\n' "$url"
    printf 'expect a test mail in about a minute and a resolved mail a few minutes later.\n'
    printf 'nothing arrived? fill in SMTP in %s/monitoring/alertmanager/alertmanager.yml,\n' "$CONFIG_DIR"
    printf 'then: podman logs --tail 30 alertmanager\n'
    exit 0
fi

# One fact both the verify sweep and the chain section need: a Fulcrum that is
# still catching up. Read once, before either can turn it into a critical.
fulcrum_index_state

# ---------------------------------------------------------------------------
# 1. the base sweep: containers, MCP health, token gate, authenticated calls
# ---------------------------------------------------------------------------
# verify.sh has three finding levels and this is the only consumer that decides
# which reach the alert path: FAIL -> critical, warn -> warning (the same
# stack_monitor_check the sweep's own soft() lines use), skip -> not carried.
# `skip` is verify's expected-absence level (a check skipped by request, a
# service not yet set up), so a host that chose not to run something does not
# warn every sweep. A warning does not fail verify's exit code, which is why the
# carry runs whether or not the sweep looked clean; a non-zero exit with no FAIL
# line means verify died before it could report.
if [ "$DO_VERIFY" = 1 ]; then
    head3 "verify.sh"
    read -r -a verify_args <<< "$MONITOR_VERIFY_ARGS"
    verify_out=$("$REPO_DIR/verify.sh" ${verify_args[@]+"${verify_args[@]}"} 2>&1) || verify_rc=$?
    carried=0
    vcount=0
    vskipped=0
    while IFS= read -r line; do
        case "$(verify_line_level "$line")" in
            fail)
                msg="${line#"  FAIL "}"
                read -r vcomp vcheck <<< "$(classify_verify_line "$msg")"
                if [ "$FULCRUM_INDEXING" = 1 ] && [ "$vcomp" = fulcrum ] && [ "$vcheck" = electrum ]; then
                    starting "verify: $msg (fulcrum is reindexing; the chain section carries the progress)"
                    vskipped=1
                    continue
                fi
                if component_starting "$vcomp"; then
                    starting "verify: $msg ($vcomp started less than ${STARTUP_GRACE_S}s ago)"
                    vskipped=1
                    continue
                fi
                fail "verify: $msg" "$vcomp" "$vcheck"
                carried=1
                vcount=$((vcount + 1))
                ;;
            warn)
                msg="${line#"  warn "}"
                read -r vcomp vcheck <<< "$(classify_verify_line "$msg")"
                if [ "$FULCRUM_INDEXING" = 1 ] && [ "$vcomp" = fulcrum ] && [ "$vcheck" = electrum ]; then
                    starting "verify: $msg (fulcrum is reindexing; the chain section carries the progress)"
                    vskipped=1
                    continue
                fi
                if component_starting "$vcomp"; then
                    starting "verify: $msg ($vcomp started less than ${STARTUP_GRACE_S}s ago)"
                    vskipped=1
                    continue
                fi
                soft "verify: $msg" "$vcomp" "$vcheck"
                carried=1
                ;;
        esac
    done <<< "$(printf '%s' "$verify_out" | sed 's/\x1b\[[0-9;]*m//g')"
    if [ "${verify_rc:-0}" != 0 ] && [ "$vcount" = 0 ] && [ "$vskipped" = 0 ]; then
        fail "verify.sh reported problems (exit ${verify_rc})"
    elif [ "${verify_rc:-0}" = 0 ] && [ "$carried" = 0 ]; then
        ok "verify.sh: no failures or warnings"
    fi
    verify_failures="$vcount"
fi

# ---------------------------------------------------------------------------
# 2. chain freshness -- the chain daemons, read at their RPCs
# ---------------------------------------------------------------------------
# One function so a host that runs no daemon tier can skip it whole: with
# MONITOR_SKIP_NODES=1 those units are absent on purpose, and every check below
# would fail on the same missing daemon. The individual checks set their own
# component/check scope, so one dead Fulcrum is not reported as "chain daemons".
chain_checks() {
    # One start inside the daemon tier makes every RPC look stale for a few
    # minutes (lightningd sync, Fulcrum indexing, the wallet rebuilding). Skip
    # the whole section while any of its containers is inside that window; a
    # container that is down is not "starting" and still pages through
    # stack_component_up below.
    local c
    for c in bitcoind fulcrum lightningd monerod; do
        if component_starting "$c"; then
            starting "chain daemons are starting ($c started less than ${STARTUP_GRACE_S}s ago)"
            return 0
        fi
    done
    scope bitcoind rpc
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
            scope bitcoind sync
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
        scope bitcoind peers
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
            scope bitcoind mempool
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
    scope fulcrum electrum
    ftip=$(electrum_tip 50001)
    if [ -z "$ftip" ]; then
        if [ "${ibd:-}" = true ] && [ "$MONITOR_GRACE_SYNC" = 1 ]; then
            ok "fulcrum is not serving Electrum yet (bitcoind is in initial block download)"
        elif [ "$FULCRUM_INDEXING" = 1 ]; then
            soft "$FULCRUM_INDEX_DETAIL"
        elif [ "$FULCRUM_INDEX_STALLED" = 1 ]; then
            fail "$FULCRUM_INDEX_DETAIL"
        else
            fail "fulcrum does not answer Electrum on 50001 (no indexing progress in its log; podman logs --tail 50 fulcrum)"
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
    
    scope lightningd rpc
    lninfo=$(lightning_cli getinfo 2>/dev/null) || lninfo=""
    if [ -z "$lninfo" ]; then
        fail "lightningd RPC unreachable"
    else
        if printf '%s' "$lninfo" | jq -e 'has("warning_bitcoind_sync")' >/dev/null 2>&1; then
            scope lightningd sync
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
        scope lightningd peers
        lpeers=$(lightning_cli listpeers 2>/dev/null) || lpeers=""
        npeers=$(printf '%s' "$lpeers" | jq -r '[.peers[] | select(.connected)] | length' 2>/dev/null) || npeers=""
        if [ -z "$npeers" ]; then
            soft "could not read lightningd listpeers; skipped the peer check"
        elif [ "$npeers" = 0 ]; then
            soft "lightningd has no connected peers"
        else
            ok "lightningd has $npeers connected peer(s)"
        fi
        scope lightningd channels
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
    scope monerod rpc
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
            scope monerod sync
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
                    scope monerod sync
                    fail "monerod reports synchronized but is $xlag block(s) behind its target (height $node_h, target $target_h)"
                else
                    ok "monerod is $xlag block(s) from its target"
                fi
            fi
        fi
    else
        soft "no MONERO_MCP_TOKEN; skipped the monerod height check"
    fi
    
    scope monero-wallet-btcpay wallet
    if component_starting monero-wallet-btcpay; then
        starting "monero-wallet is starting (started less than ${STARTUP_GRACE_S}s ago)"
    else
        xmrwallet_token=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
        if [ -n "$xmrwallet_token" ] && [ ! -f "$DATA_DIR/btcpay/xmr-wallet/wallet.keys" ]; then
            soft "the BTCPay view-only XMR wallet is not imported yet (config/btcpay/xmr-wallet.env); skipped the wallet height check"
        elif [ -n "$xmrwallet_token" ]; then
            w_body=$(mcp_call monero-wallet-mcp "$xmrwallet_token" get_height '{}') || w_body=""
            w_raw=$(mcp_result_raw "$w_body")
            w_h=$(mcp_result "$w_body" | jq -r '.height // empty' 2>/dev/null)
            if [ -z "$w_h" ]; then
                case "$w_raw" in
                    *"No wallet file"*)
                        # The RPC is up and has no wallet open. That is the normal
                        # state of the BTCPay view-only wallet: the plugin opens it
                        # on demand and closes it again, so get_height is not a
                        # liveness probe. The unit's get_version healthcheck is.
                        ok "monero-wallet RPC is up; no wallet is open (BTCPay opens the view-only wallet on demand)"
                        ;;
                    *)
                        fail "monero-wallet does not answer get_height: ${w_raw:-no reply} (podman logs --tail 50 monero-wallet-btcpay)"
                        ;;
                esac
            elif [ -n "$node_h" ] && [ "$((node_h - w_h))" -gt 10 ]; then
                soft "monero-wallet is behind monerod: wallet=$w_h node=$node_h"
            else
                ok "monero-wallet height $w_h"
            fi
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
THRESH_DUMP_H=$(num_or "${MONITOR_DUMP_MAX_AGE_H:-}" 36)
THRESH_CERT_D=$(num_or "${MONITOR_CERT_MIN_DAYS:-}" 14)
THRESH_METRICS_S=$(num_or "${MONITOR_METRICS_MAX_AGE_S:-}" 300)
# The log pipeline: how old the newest entry in the store may be. A "stopped
# shipping" alarm, not a threshold -- 15 minutes gives a restart room to come back.
THRESH_LOGS_S=$(num_or "${MONITOR_LOGS_MAX_AGE_S:-}" 900)
# The ET Open ruleset's age, from the mtime scripts/ids.sh records. 14 days is
# two missed weekly refreshes: one week of stale signatures is not a page, two
# is a sensor that has stopped following upstream.
THRESH_RULES_AGE_H=$(num_or "${MONITOR_IDS_RULES_MAX_AGE_H:-}" 336)
# The NIC's errs+drop columns, delta'd between sweeps like the restart counters:
# a carrier dropping packets looks like a slow sync to every chain check.
MONITOR_NET_DROP=$(monitor_var MONITOR_NET_DROP)
THRESH_NET_DROP=$(num_or "${MONITOR_NET_DROP:-}" 100)
# The hottest hwmon reading at sweep time; a warn, since a one-off spike is noise
# and a climbing trend shows in the graphs node-exporter already exports.
MONITOR_TEMP_MAX=$(monitor_var MONITOR_TEMP_MAX)
THRESH_TEMP_C=$(num_or "${MONITOR_TEMP_MAX:-}" 85)
# SMART policy: the root probe records the counters; these decide when they are
# worth a page or a warning. The temperature threshold is separate from
# THRESH_TEMP_C because a rotational disk is rated near 60C, long before the
# hwmon sensor's 85C.
THRESH_SMART_REALLOC=$(num_or "${MONITOR_SMART_REALLOC_MAX:-}" 0)
THRESH_SMART_PENDING=$(num_or "${MONITOR_SMART_PENDING_MAX:-}" 0)
THRESH_SMART_TEMP=$(num_or "${MONITOR_SMART_TEMP_MAX:-}" 60)

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

# Space and inodes are per filesystem, not per path: $STACK_BACKUP_DIR defaults
# under $HOME, and /home is often a separate device. Read every path that can
# brick a different part of the stack, but check each st_dev once so one full
# disk is one finding, not one per path name.
disk_seen=" "
for target in / "$DATA_DIR" "$HOME" "$STACK_BACKUP_DIR"; do
    scope disk space
    if [ ! -d "$target" ]; then
        soft "disk check skipped: $target does not exist"
        continue
    fi
    if ! disk_key=$(stat -c %d -- "$target" 2>/dev/null); then
        soft "disk check skipped: could not stat $target"
        continue
    fi
    case "$disk_seen" in
        *" $disk_key "*)
            ok "$target is on a filesystem already checked"
            continue ;;
    esac
    disk_seen="$disk_seen$disk_key "

    dfree=$(free_pct "$target" 2>/dev/null || true)
    ifree=$(free_pct --inodes "$target" 2>/dev/null || true)
    # df -P's Use% is rounded up, so free_pct can be negative on a full disk;
    # a non-numeric answer is a failed read, not "0% free".
    case "$dfree" in ''|*[!0-9-]*|-) dfree="" ;; esac
    case "$ifree" in ''|*[!0-9-]*|-) ifree="" ;; esac
    if [ -z "$dfree" ]; then
        soft "could not read disk usage for $target"
    elif [ "$dfree" -lt "$THRESH_DISK" ]; then
        fail "disk almost full: $target has ${dfree}% free (threshold ${THRESH_DISK}%)"
    else
        ok "$target has ${dfree}% disk free"
    fi
    scope disk inodes
    if [ -n "$ifree" ] && [ "$ifree" -lt "$THRESH_INODES" ]; then
        fail "inodes almost exhausted on $target: ${ifree}% free (threshold ${THRESH_INODES}%)"
    fi
done

# A clock that stopped being disciplined breaks TLS validation and ACME, and
# gives Lightning's gossip and invoices the wrong wall time. timedated reads the
# kernel's STA_UNSYNC state, so this works with chrony or systemd-timesyncd.
scope ntp sync
if command -v timedatectl >/dev/null 2>&1; then
    ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null) || ntp_sync=""
    case "$ntp_sync" in
        yes) ok "clock is synchronized by NTP" ;;
        no)  fail "clock is not synchronized by NTP: TLS/ACME and Lightning timestamps will drift (timedatectl status; chronyc tracking)" ;;
        *)   soft "could not read NTPSynchronized from timedatectl; skipped the clock check" ;;
    esac
else
    soft "timedatectl is unavailable; skipped the clock check"
fi

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

# Disk health: SMART needs root to open the block device, so a root oneshot
# (stack-smart.timer) writes the verdict and the per-disk facts; this sweep
# never calls sudo or smartctl. The file is judged only when the timer is
# installed, like the audit and bouncer jobs, so a host that has not re-run
# bootstrap does not warn every five minutes.
SMART_STATUS_FILE="$AUDIT_DIR/smart.status"
smart_up=0
smart_disks=0
SMART_PROM=()
if [ -f /etc/systemd/system/stack-smart.timer ]; then
    scope smart status
    verdict_judge "$SMART_STATUS_FILE" fail "$(verdict_age smart)" "SMART report" \
        "see $SMART_STATUS_FILE" "systemctl status stack-smart.timer"
    smart_disks=$(num_or "$(env_value "$SMART_STATUS_FILE" disks)" 0)
    [ "$VERDICT_OUTCOME" = ok ] && smart_up=1

    i=0
    while [ "$i" -lt "$smart_disks" ]; do
        dev=$(env_value "$SMART_STATUS_FILE" "disk${i}_dev")
        name=$(env_value "$SMART_STATUS_FILE" "disk${i}_name")
        protocol=$(env_value "$SMART_STATUS_FILE" "disk${i}_protocol")
        state=$(env_value "$SMART_STATUS_FILE" "disk${i}_state")
        health=$(env_value "$SMART_STATUS_FILE" "disk${i}_health")
        model=$(env_value "$SMART_STATUS_FILE" "disk${i}_model")
        realloc=$(env_value "$SMART_STATUS_FILE" "disk${i}_realloc")
        pending=$(env_value "$SMART_STATUS_FILE" "disk${i}_pending")
        uncorrected=$(env_value "$SMART_STATUS_FILE" "disk${i}_uncorrected")
        temp=$(env_value "$SMART_STATUS_FILE" "disk${i}_temp")
        media=$(env_value "$SMART_STATUS_FILE" "disk${i}_media_errors")
        [ -n "$name" ] || name=${dev##*/}
        label=${name:-disk$i}
        scope "disk-$label" smart

        case "$state" in
            standby)
                [ "$VERDICT_OUTCOME" = ok ] \
                    && ok "$label is in standby; SMART not read (not woken)" ;;
            error)
                # verdict_judge already reports the probe's fail; this is the
                # per-disk identity in the same section.
                ;;
            unsupported)
                # A RAID virtual disk (the controller's /dev/sdX) normally
                # reports no SMART; the physical members are the disks that
                # do, and they are separate entries in this file. Warn only
                # when there is no other disk to report on.
                if [ "$smart_disks" -gt 1 ]; then
                    ok "SMART $label is unsupported (virtual/RAID disk?); other disks report"
                else
                    soft "SMART $label reports no usable health or attributes (bridge/controller limitation)"
                fi ;;
            *)
                bad_disk=0
                if [ "$health" != PASSED ]; then
                    fail "SMART $label health ${health:-unknown}"
                    bad_disk=1
                fi

                case "$protocol" in
                    NVMe)
                        # media_errors is the NVMe equivalent of an unstable
                        # sector: any is a failure, not a threshold to tune.
                        case "$media" in
                            ''|*[!0-9]*) ;;
                            *) if [ "$media" -gt 0 ]; then
                                   fail "SMART $label has $media media error(s)"
                                   bad_disk=1
                               fi ;;
                        esac ;;
                    *)
                        if [ -z "$realloc" ] && [ -z "$pending" ]; then
                            soft "SMART $label exposes no reallocated/pending-sector counts (health and temperature only)"
                            bad_disk=1
                        else
                            case "$pending" in
                                ''|*[!0-9]*) ;;
                                *) if [ "$pending" -gt "$THRESH_SMART_PENDING" ]; then
                                       fail "SMART $label has $pending pending sector(s) (threshold $THRESH_SMART_PENDING)"
                                       bad_disk=1
                                   fi ;;
                            esac
                            case "$realloc" in
                                ''|*[!0-9]*) ;;
                                *) if [ "$realloc" -gt "$THRESH_SMART_REALLOC" ]; then
                                       fail "SMART $label has $realloc reallocated sector(s) (threshold $THRESH_SMART_REALLOC)"
                                       bad_disk=1
                                   fi ;;
                            esac
                        fi ;;
                esac

                # SCSI/SAS: the error counter log's uncorrected total is the
                # "the medium failed and the drive could not fix it" signal.
                case "$uncorrected" in
                    ''|*[!0-9]*) ;;
                    *) if [ "$uncorrected" -gt 0 ]; then
                           fail "SMART $label has $uncorrected uncorrected error(s)"
                           bad_disk=1
                       fi ;;
                esac

                scope "disk-$label" temperature
                case "$temp" in
                    ''|0|*[!0-9]*) soft "SMART $label reports no temperature"
                                   bad_disk=1 ;;
                    *) if [ "$temp" -gt "$THRESH_SMART_TEMP" ]; then
                           soft "SMART $label is ${temp}C (threshold ${THRESH_SMART_TEMP}C)"
                           bad_disk=1
                       fi ;;
                esac

                case "$health" in
                    PASSED) health_n=1 ;;
                    FAILED) health_n=0 ;;
                    *)      health_n="" ;;
                esac
                labels="device=\"$(prom_label_value "$label")\""
                [ -n "$model" ] && labels="$labels,model=\"$(prom_label_value "$model")\""
                [ -n "$health_n" ] && SMART_PROM+=("stack_smart_healthy{$labels} $health_n")
                case "$realloc" in ''|*[!0-9]*) ;; *) SMART_PROM+=("stack_smart_reallocated_sectors{$labels} $realloc") ;; esac
                case "$pending" in ''|*[!0-9]*) ;; *) SMART_PROM+=("stack_smart_pending_sectors{$labels} $pending") ;; esac
                case "$uncorrected" in ''|*[!0-9]*) ;; *) SMART_PROM+=("stack_smart_uncorrected_errors{$labels} $uncorrected") ;; esac
                case "$temp" in ''|*[!0-9]*) ;; *) SMART_PROM+=("stack_smart_temperature_celsius{$labels} $temp") ;; esac
                case "$media" in ''|*[!0-9]*) ;; *) SMART_PROM+=("stack_smart_media_errors{$labels} $media") ;; esac

                if [ "$bad_disk" = 0 ] && [ "$VERDICT_OUTCOME" = ok ]; then
                    case "$protocol" in
                        NVMe) ok "$label${model:+ ($model)}: $health, ${temp:-?}C, ${media:-?} media error(s)" ;;
                        SCSI) ok "$label${model:+ ($model)}: $health, ${realloc:-?} grown defect(s), ${pending:+$pending pending, }${uncorrected:+$uncorrected uncorrected, }${temp:-?}C" ;;
                        *)    ok "$label${model:+ ($model)}: $health, ${realloc:-?} reallocated, ${pending:-?} pending, ${temp:-?}C" ;;
                    esac
                fi ;;
        esac
        i=$((i + 1))
    done
fi

# A rotation is reconciled, not journaled (rotate.sh): the dangerous residue is
# not a bookkeeping file but a live credential nothing references. Two are
# checkable from here.
#
# 1. The runes. Exactly the pair lightning-mcp/node.env carries may be live on the
#    node; anything else this stack minted is a key that survived a run and is
#    still valid, and one of those could also spend. The comparison (method sets
#    against stack.conf, not remembered ids) is in scripts/lib/daemons.sh so
#    and this check agree.
scope lightningd runes
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
scope bitcoind rpc_password
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
    scope stack rotation
    soft "stale rotation journal(s) from an older version: $(cd "$CONFIG_DIR/rotation" && printf '%s ' *.pending) -- delete them (nothing reads them)"
fi

# backup age: a timer that fires is not a repository that has a snapshot, and a
# fire-and-forget backup is the failure found on restore day.
# restic_snapshot_summary is the same read rotate.sh makes before it will rotate
# the repository password.
scope backup age
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
#
# The mtime is the effect; the producer's verdict file is the cause. Reading it
# only when a dump is missing or stale keeps the healthy sweep quiet and turns
# "postgres-dump/all.sql is 38h old" into "postgres-dump.service exited 1".
dump_verdict() { # dump-relative-path -> producer summary
    local job f
    case "$1" in
        postgres-dump/*) job=postgres-dump ;;
        *)               job=db-dump ;;
    esac
    f="$AUDIT_DIR/$job.status"
    if [ ! -f "$f" ]; then
        printf '%s has no verdict yet' "$job"
        return 0
    fi
    status_verdict "$f"
    if [ "$STATUS_RESULT" = ok ]; then
        printf '%s reported ok; the dump file itself is the fault' "$job"
    else
        printf '%s=%s%s' "$job" "${STATUS_RESULT:-unknown}" \
            "${STATUS_DETAIL:+ -- $STATUS_DETAIL}"
    fi
}

dump_missing=""
dump_stale=""
dump_oldest=0
for dump_rel in postgres-dump/all.sql npm-dump/database.sqlite uptime-kuma-dump/kuma.sql; do
    dump_file="$DATA_DIR/$dump_rel"
    if [ ! -s "$dump_file" ]; then
        dump_missing="$dump_missing $dump_rel [$(dump_verdict "$dump_rel")]"
        continue
    fi
    dump_m=$(stat -c %Y "$dump_file" 2>/dev/null || true)
    case "$dump_m" in
        ''|*[!0-9]*)
            dump_missing="$dump_missing $dump_rel [$(dump_verdict "$dump_rel")]"
            continue ;;
    esac
    dump_age_h=$(( ( $(date +%s) - dump_m ) / 3600 ))
    [ "$dump_age_h" -gt "$dump_oldest" ] && dump_oldest=$dump_age_h
    [ "$dump_age_h" -gt "$THRESH_DUMP_H" ] \
        && dump_stale="$dump_stale $dump_rel (${dump_age_h}h) [$(dump_verdict "$dump_rel")]"
done
scope db-dump freshness
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
# healthy because the timer fired. verdict_judge owns that judgement for every
# job (scripts/lib/jobs.sh); only the file, the severity and the age are passed
# here.
VERIFY_STATUS_FILE="$AUDIT_DIR/backup-verify.status"
scope backup verify
verdict_judge "$VERIFY_STATUS_FILE" fail "$(verdict_age backup-verify)" \
    "backup restore drill" "run scripts/backup.sh verify"
backup_verify_age_s="${STATUS_AGE_S:-}"
case "$VERDICT_OUTCOME" in
    ok|skip)   backup_verify_ok=1 ;;
    fail|stale) backup_verify_ok=0 ;;
    *)         backup_verify_ok="" ;;
esac
if [ "$VERDICT_OUTCOME" = ok ]; then
    ok "backup restore drill passed $(( STATUS_AGE_S / 3600 ))h ago"
fi

# The database drill (backup.sh verify-db, monthly): the weekly drill proves
# restic mechanics and that the dump files are present, never that all.sql
# REPLAYS -- and the dump is the only copy of the app tier's data. Its verdict is
# its own file, judged on its own last success: sharing the weekly one would let
# either drill mask the other's age. A skip carries ok_epoch forward, so a run of
# skips fails on age instead of looking green.
VERIFY_DB_STATUS_FILE="$AUDIT_DIR/backup-verify-db.status"
scope backup verify_db
verdict_judge "$VERIFY_DB_STATUS_FILE" fail "$(verdict_age backup-verify-db)" \
    "backup database drill" "run scripts/backup.sh verify-db"
backup_verify_db_age_s="${STATUS_AGE_S:-}"
case "$VERDICT_OUTCOME" in
    ok|skip)   backup_verify_db_ok=1 ;;
    fail|stale) backup_verify_db_ok=0 ;;
    *)         backup_verify_db_ok="" ;;
esac
if [ "$VERDICT_OUTCOME" = ok ]; then
    ok "backup database drill passed $(( STATUS_AGE_S / 3600 ))h ago"
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
             registrations.timer monitor.timer crowdsec-update.timer; do
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
scope systemd schedules
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
scope nginx-proxy-manager certificate
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
# fired and resolved around every burst. metrics.sh exports NRestarts as
# stack_systemd_restarts{unit}; it is a gauge that resets on a manual restart, so
# the rule uses changes() over 30 minutes -- the same fact as a condition, and
# not increase(), which is only valid on a counter.

# The collector that produces every graph: if it stops, the history stops and
# nothing else notices, so it is checked from the outside.
STACK_PROM="$DATA_DIR/monitoring/textfile/stack.prom"
scope node-exporter metrics
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
scope vector logs
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
scope journald persistence
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
scope podman events
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
scope network drops
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
scope host temperature
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
scope journald syslog
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
scope registrations watcher
verdict_judge "$REG_STATUS_FILE" soft "$(verdict_age registrations)" \
    "signup watcher" "see $AUDIT_DIR/registrations.log" \
    "systemctl --user status registrations.timer"
if [ "$VERDICT_OUTCOME" = ok ]; then
    if [ "$(env_value "$REG_STATUS_FILE" skipped)" = 1 ]; then
        ok "signups: watcher live, skipped (no BoltMesh app tier on this host)"
    else
        ok "signups: watcher live, $(env_value "$REG_STATUS_FILE" new) new in the last run"
    fi
fi

# ---------------------------------------------------------------------------
# 4. failed systemd units -- the gaps the timers and verdict files do not cover
# ---------------------------------------------------------------------------
# A timer can be active while the oneshot it starts fails, and a failed job with
# no status file is invisible to every check above. Read both managers: the
# stack's units are user units, while audit-rules and the distro's boot jobs are
# system units.
#
# `systemctl --failed` only sees the state a stop or reset-failed has already
# cleared. An inactive oneshot keeps its last exit code, so the second read still
# names a stopped unit whose last run failed. Both are warnings, not pages: the
# checks that own each effect (audit watches, bouncer, backup age, IDS) already
# decide the critical level, and audit-rules now exits 0 for the duplicate-only
# reload it used to report (deploy/root/audit-rules-load.sh). monitor.service is
# excluded from the user list: a sweep that finds any other problem is itself
# failed until the next start and must not report itself.
#
# Podman runs each container HealthCmd as a transient user unit named by the
# container id and an opaque suffix. A failing healthcheck therefore shows up as
# a failed user unit under a component nobody can read, while
# stack_component_health already reports the same fact under the container's
# name -- the label the mail and inhibition are built on. Skip those runners; a
# real unit whose description merely mentions podman is still reported.
podman_healthcheck_unit() { # unit-name
    local desc
    desc=$(systemctl --user show -p Description --value -- "$1" 2>/dev/null) || return 1
    case "$desc" in
        "[systemd-run] /usr/bin/podman healthcheck run "*) return 0 ;;
        *) return 1 ;;
    esac
}
head3 "systemd units"
unit_faults=()
unit_read_ok=1
if command -v systemctl >/dev/null 2>&1; then
    if failed_system=$(systemctl --failed --no-legend --plain --no-pager 2>/dev/null); then
        failed_system=$(printf '%s\n' "$failed_system" | awk '{print $1}' | paste -sd' ' -)
        [ -n "$failed_system" ] && unit_faults+=("system: $failed_system")
    else
        unit_read_ok=0
        soft "could not read the system manager's failed units; skipped that half of the check"
    fi
    if failed_user=$(systemctl --user --failed --no-legend --plain --no-pager 2>/dev/null); then
        failed_user_units=""
        for u in $(printf '%s\n' "$failed_user" | awk '$1 != "monitor.service" {print $1}'); do
            podman_healthcheck_unit "$u" || failed_user_units="$failed_user_units $u"
        done
        failed_user=${failed_user_units# }
        [ -n "$failed_user" ] && unit_faults+=("user: $failed_user")
    else
        unit_read_ok=0
        soft "could not read the user manager's failed units; skipped that half of the check"
    fi

    # Inactive system oneshots: the last invocation's exit code survives a stop,
    # unlike the failed state. Only services have ExecMainStatus; the user tier's
    # jobs carry verdict files, so the history that matters here is the system
    # manager's.
    inactive_units=""
    if inactive_units=$(systemctl list-units --all --type=service --state=inactive \
        --no-legend --plain --no-pager 2>/dev/null); then
        inactive_units=$(printf '%s\n' "$inactive_units" | awk '{print $1}')
        if [ -n "$inactive_units" ]; then
            mapfile -t inactive_oneshot_units <<< "$inactive_units"
            if last_out=$(systemctl show "${inactive_oneshot_units[@]}" \
                -p Id -p Type -p ExecMainStatus --no-pager 2>/dev/null); then
                last_failed=$(printf '%s\n' "$last_out" \
                    | awk 'BEGIN { RS=""; FS="\n" }
                        {
                            id=""; type=""; status=""
                            for (i = 1; i <= NF; i++) {
                                if ($i ~ /^Id=/) { id=$i; sub(/^Id=/, "", id) }
                                else if ($i ~ /^Type=/) { type=$i; sub(/^Type=/, "", type) }
                                else if ($i ~ /^ExecMainStatus=/) { status=$i; sub(/^ExecMainStatus=/, "", status) }
                            }
                            if (type == "oneshot" && status ~ /^[0-9]+$/ && status + 0 != 0)
                                printf "%s:%s ", id, status
                        }' | sed 's/ $//')
                [ -n "$last_failed" ] && unit_faults+=("inactive oneshot: $last_failed")
            else
                unit_read_ok=0
                soft "could not read the last exit status of inactive services; skipped that half of the check"
            fi
        fi
    else
        unit_read_ok=0
        soft "could not list inactive services; skipped the oneshot last-exit check"
    fi
else
    unit_read_ok=0
    soft "systemctl is unavailable; skipped the failed-unit check"
fi
if [ "${#unit_faults[@]}" -gt 0 ]; then
    for unit_fault in "${unit_faults[@]}"; do
        case "$unit_fault" in
            "system: "*)
                for u in ${unit_fault#system: }; do
                    soft "failed system unit: $u -- systemctl status/journalctl names the cause" "${u%.service}" unit_failed
                done ;;
            "user: "*)
                for u in ${unit_fault#user: }; do
                    soft "failed user unit: $u -- systemctl status/journalctl names the cause" "${u%.service}" unit_failed
                done ;;
            "inactive oneshot: "*)
                for pair in ${unit_fault#inactive oneshot: }; do
                    u=${pair%%:*}; code=${pair#*:}
                    soft "failed inactive oneshot: $u (exit $code) -- systemctl status/journalctl names the cause" "${u%.service}" oneshot_failed
                done ;;
            *) soft "$unit_fault -- systemctl status/journalctl names the cause" systemd units ;;
        esac
    done
elif [ "$unit_read_ok" = 1 ]; then
    ok "no systemd unit failed or left a failed oneshot invocation"
fi

# ---------------------------------------------------------------------------
# 5. the public surface -- every clearweb vhost through nginx-proxy-manager.
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
# The manifest also says which vhosts declare force-ssl (NPM_FORCE_SSL,
# index-aligned). A 200 from one of those on :80 is not "up": NPM is serving
# plaintext because it has no certificate or the host was never reconciled. The
# redirect is NPM's own, so it is asserted before MONITOR_SKIP_NODES -- a
# skipped upstream cannot make a plaintext vhost safe. A vhost without force-ssl
# may answer 200 (no certificate issued yet) and is then checked on :80.
#
# The https probe carries the certificate check and, for a force-ssl host that
# is not skipped, the HSTS header NPM emits with hsts_enabled (per host, never
# advanced_config: see docs/proxy.md).
#
# The path is NPM_PROBE_PATHS (index-aligned, default `/`): xmr-explorer's root
# blocks while monerod syncs, so its declaration probes a static asset instead.
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
        comp="${NPM_CONTAINERS[$i]:-nginx-proxy-manager}"
        force_ssl="${NPM_FORCE_SSL[$i]:-0}"
        probe_path="${NPM_PROBE_PATHS[$i]:-/}"
        scope "$comp" http
        if component_starting nginx-proxy-manager || component_starting "$comp"; then
            starting "$vhost skipped: nginx-proxy-manager or $comp started less than ${STARTUP_GRACE_S}s ago"
            continue
        fi
        https_headers=""
        # http first: a declared force-ssl vhost must redirect here; anything
        # else is plaintext. A vhost without it may answer on :80 until a
        # certificate exists.
        pcode=$(curl -sS -o /dev/null -w '%{http_code}' -m 10 \
            --connect-to "$vhost:80:127.0.0.1:80" "http://$vhost$probe_path" 2>/dev/null) || pcode=000
        if [ "$force_ssl" = 1 ]; then
            case "$pcode" in
                301|308) ;;
                000|5??)
                    public_bad=$((public_bad + 1))
                    fail "$vhost does not answer through nginx-proxy-manager ($pcode): certificate, proxy host or loopback publish"
                    continue ;;
                *)
                    public_bad=$((public_bad + 1))
                    scope "$comp" redirect
                    fail "$vhost serves plaintext HTTP ($pcode): force-ssl is declared but nginx-proxy-manager is not redirecting to https (no certificate, or scripts/npm-hosts.sh has not run)"
                    continue ;;
            esac
        fi
        if [ "$MONITOR_SKIP_NODES" = 1 ] && [ "${NPM_NEEDS_NODES[$i]:-0}" = 1 ]; then
            ok "$vhost skipped by request (its upstream is in the daemon tier; force-ssl redirect checked)"
            continue
        fi
        case "$pcode" in
            301|302|307|308)
                # Capture the https response headers in the same request: HSTS
                # is a header-level fact, and -D - costs no second connection.
                https_out=$(curl -sS -o /dev/null -D - -w '\n%{http_code}' -m 15 \
                    --connect-to "$vhost:443:127.0.0.1:443" "https://$vhost$probe_path" 2>/dev/null) \
                    || https_out=""
                if [ -n "$https_out" ]; then
                    pcode=${https_out##*$'\n'}
                    https_headers=${https_out%$'\n'*}
                else
                    pcode=000
                fi
                ;;
        esac
        case "$pcode" in
            000|5??)
                public_bad=$((public_bad + 1))
                fail "$vhost does not answer through nginx-proxy-manager ($pcode): certificate, proxy host or loopback publish"
                ;;
            *)
                if [ "$force_ssl" = 1 ] \
                    && ! printf '%s' "$https_headers" | grep -qi '^strict-transport-security:.*max-age='; then
                    public_bad=$((public_bad + 1))
                    scope "$comp" hsts
                    fail "$vhost answers HTTPS ($pcode) without the HSTS header: force-ssl is declared, so NPM's hsts_enabled should be set (run scripts/npm-hosts.sh)"
                elif [ "$force_ssl" = 1 ]; then
                    ok "$vhost redirects to HTTPS and sends HSTS ($pcode)"
                else
                    ok "$vhost answers through nginx-proxy-manager ($pcode)"
                fi
                ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# 6. the spend tripwire
# ---------------------------------------------------------------------------
head3 "spend tripwire"
scope spend tripwire
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
# 7. intrusion detection -- through ids.sh's status file, never directly
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
ids_ssh_fail=0
ids_rules=""
ids_rules_epoch=""
ids_rules_age_h=""
ids_up=0
scope suricata ids
verdict_judge "$IDS_STATUS_FILE" fail "$(verdict_age ids)" "IDS roll-up" \
    "see $AUDIT_LOG" "ids.timer stopped, or ids.sh cannot read the sensor"
# The counters are read whichever way the verdict went: a stale roll-up's last
# numbers are history, and reporting 0 would graph a dead sensor as a quiet one.
ids_alerts=$(num_or "$(env_value "$IDS_STATUS_FILE" alerts)" 0)
ids_decisions=$(num_or "$(env_value "$IDS_STATUS_FILE" decisions)" 0)
ids_ssh_fail=$(num_or "$(env_value "$IDS_STATUS_FILE" ssh_fail)" 0)
ids_rules=$(env_value "$IDS_STATUS_FILE" rules)
ids_rules_epoch=$(env_value "$IDS_STATUS_FILE" rules_epoch)

# The ET Open age policy. ids.sh records the rules file's mtime; this sweep owns
# the threshold, like every other MONITOR_* number. Only judged while the
# roll-up itself is healthy: a stale roll-up is already the failure, and one
# fact must not page twice. missing/unreadable/empty already fail ids.sh; age is
# the only state this adds.
rules_problem=""
rules_problem_sev=""
if [ "$VERDICT_OUTCOME" = ok ] && [ "$ids_rules" = ok ]; then
    case "$ids_rules_epoch" in
        ''|*[!0-9]*)
            rules_problem="IDS roll-up reports rules=ok but $IDS_STATUS_FILE has no rules_epoch"
            rules_problem_sev=soft
            ;;
        *)
            ids_rules_age_h=$(( ( $(date +%s) - ids_rules_epoch ) / 3600 ))
            [ "$ids_rules_age_h" -ge 0 ] || ids_rules_age_h=0
            if [ "$ids_rules_age_h" -gt "$THRESH_RULES_AGE_H" ]; then
                ids_rules=stale
                rules_problem="suricata's ET Open ruleset is ${ids_rules_age_h}h old (threshold ${THRESH_RULES_AGE_H}h): stack-suricata-update.timer has not refreshed it"
                rules_problem_sev=fail
            fi
            ;;
    esac
fi

case "$VERDICT_OUTCOME" in
    ok)
        ids_up=1
        ok "IDS: suricata=$(env_value "$IDS_STATUS_FILE" suricata) crowdsec=$(env_value "$IDS_STATUS_FILE" crowdsec), $ids_alerts alert(s), $ids_decisions decision(s), $ids_ssh_fail SSH auth failure(s), rules=${ids_rules:-?}${ids_rules_age_h:+ (${ids_rules_age_h}h)}"
        scope suricata rules
        case "$rules_problem_sev" in
            fail) fail "$rules_problem" ;;
            soft) soft "$rules_problem" ;;
        esac ;;
    *)
        ids_up=0 ;;
esac
# The alert count is a report, not a page: it goes to VictoriaMetrics as
# stack_ids_alerts and the rule holds a burst for 15 minutes. Deciding it here
# made the section fire and resolve around every spike.
# SSH failures are the same kind of report, with their own burst rule
# (StackSshBruteforce) over the last-window count in stack_ids_ssh_fail; SSH
# is LAN-only, so the threshold is deliberately a warning.

# The weekly refresh jobs. Their *effect* is the rules age above and the hub
# items themselves; these verdicts add the reason and an early warning. A
# missing status is deliberately not a fault: both jobs are weekly, so a fresh
# deploy has none until its first run, and verify.sh / the schedule check names
# a missing timer. A skipped run is also not judged: the job skips because the
# engine is stopped, and ids.sh already reports that state; judging it here
# would add a warning for one fact.
SURICATA_UPDATE_STATUS_FILE="$AUDIT_DIR/suricata-update.status"
scope suricata update
if [ -f /etc/systemd/system/stack-suricata-update.timer ] \
    && [ -f "$SURICATA_UPDATE_STATUS_FILE" ] \
    && [ "$(env_value "$SURICATA_UPDATE_STATUS_FILE" result)" != skip ]; then
    verdict_judge "$SURICATA_UPDATE_STATUS_FILE" soft "$(verdict_age suricata-update)" \
        "Suricata rule update" "see $DATA_DIR/ids/suricata/suricata-update.log" \
        "systemctl status stack-suricata-update.timer"
fi
CROWDSEC_UPDATE_STATUS_FILE="$AUDIT_DIR/crowdsec-update.status"
scope crowdsec update
if [ -f "$CROWDSEC_UPDATE_STATUS_FILE" ] \
    && [ "$(env_value "$CROWDSEC_UPDATE_STATUS_FILE" result)" != skip ]; then
    verdict_judge "$CROWDSEC_UPDATE_STATUS_FILE" soft "$(verdict_age crowdsec-update)" \
        "CrowdSec hub update" "see $AUDIT_DIR/crowdsec-update.log" \
        "systemctl --user status crowdsec-update.timer"
fi

# The audit report: host-level changes no script in this repo makes (account
# databases, sudoers, sshd, audit's own config), plus the hash diff over the
# persistence directories -- which catches a *new* unit file, because this kernel
# emits no audit events for directory watches.
AUDIT_STATUS_FILE="$AUDIT_DIR/auditd.status"
audit_fim=0
scope audit auditd
if [ -f /etc/systemd/system/stack-audit.timer ]; then
    verdict_judge "$AUDIT_STATUS_FILE" fail "$(verdict_age auditd)" "audit report" \
        "see $AUDIT_STATUS_FILE" "systemctl status stack-audit.timer"
    audit_fim=$(num_or "$(env_value "$AUDIT_STATUS_FILE" fim)" 0)
    if [ "$VERDICT_OUTCOME" = ok ]; then
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
# The applier. Separate from the engines on purpose: detection can be perfectly
# healthy while nothing enforces (a stopped timer, a wrong key, an nft that refuses
# the table) -- the state where the host believes it is protected and is not.
BOUNCER_STATUS_FILE="$AUDIT_DIR/bouncer.status"
bouncer_bans=0
bouncer_skipped=0
scope crowdsec bouncer
if [ -f /etc/systemd/system/stack-bouncer.timer ]; then
    verdict_judge "$BOUNCER_STATUS_FILE" fail "$(verdict_age bouncer)" "bouncer" \
        "see $BOUNCER_STATUS_FILE" "systemctl status stack-bouncer.timer"
    bouncer_bans=$(num_or "$(env_value "$BOUNCER_STATUS_FILE" banned)" 0)
    # Decisions enforcement declined because they name an address the operator
    # holds or their own egress: worth a line, because "0 banned" next to a
    # live decision reads like a broken applier.
    bouncer_skipped=$(num_or "$(env_value "$BOUNCER_STATUS_FILE" skipped)" 0)
    if [ "$VERDICT_OUTCOME" = ok ]; then
        ok "bouncer: ${bouncer_bans} address(es) banned"
        if [ "${bouncer_skipped:-0}" -gt 0 ]; then
            soft "the bouncer declined ${bouncer_skipped} decision(s) naming an address this host is or uses (its own egress): something here is tripping a rule -- a stale token will do it"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 8. the alert path itself
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
#
# ALERT_PATH_BROKEN is what the heartbeat keys on, not "any finding": a finding
# is delivered by the rules, and a second copy over the dead-man's switch makes
# every fault arrive twice. The switch is for the case the mail path cannot
# report -- the store, vmalert, Alertmanager or its deliveries.
ALERT_PATH_BROKEN=0
head3 "alerting"
am_ok=1
vm_ok=1
vmalert_ok=1
if [ "$MONITOR_ALERTMANAGER_URL" = off ]; then
    ok "alerting is off (MONITOR_ALERTMANAGER_URL=off): facts are not written, so no rule can fire"
else
    vm_url="http://127.0.0.1:8428"
    scope victoriametrics health
    vm_code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$vm_url/-/healthy" 2>/dev/null) || vm_code=""
    if [ "$vm_code" != 200 ]; then
        vm_ok=0
        ALERT_PATH_BROKEN=1
        fail "VictoriaMetrics does not answer at $vm_url/-/healthy: the rules cannot be evaluated, so no alert can fire (the heartbeat carries this one)"
    else
        ok "VictoriaMetrics answers"
    fi

    # vmalert's own health, plus the reload counter: it parses the rules at start,
    # so a healthy process means the rendered file was accepted. A failed RELOAD
    # runs the previous rules -- like Alertmanager's invalid config, that is a
    # warning, not a page.
    vmalert_url="http://127.0.0.1:8880"
    scope vmalert health
    vmalert_code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$vmalert_url/-/healthy" 2>/dev/null) || vmalert_code=""
    if [ "$vmalert_code" != 200 ]; then
        vmalert_ok=0
        ALERT_PATH_BROKEN=1
        fail "vmalert does not answer at $vmalert_url/-/healthy: the sweep's facts are not being evaluated"
    else
        vmalert_metrics=$(curl -fsS -m 5 "$vmalert_url/metrics" 2>/dev/null) || vmalert_metrics=""
        if [ -n "$vmalert_metrics" ] \
            && printf '%s\n' "$vmalert_metrics" | grep -q '^vmalert_config_last_reload_successful 0'; then
            scope vmalert rules
            soft "vmalert's last rule reload failed; it is running the previous rules (podman logs vmalert)"
        else
            ok "vmalert answers and its rules are loaded"
        fi
    fi

    am_url="${MONITOR_ALERTMANAGER_URL%/}"
    scope alertmanager health
    am_code=$(curl -fsS -m 5 -o /dev/null -w '%{http_code}' "$am_url/-/healthy" 2>/dev/null) || am_code=""
    if [ "$am_code" != 200 ]; then
        am_ok=0
        ALERT_PATH_BROKEN=1
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
                ALERT_PATH_BROKEN=1
                scope alertmanager delivery
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
    scope alertmanager config
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
        scope monitor heartbeat
        soft "no MONITOR_PING_URL: a dead host or a dead vmalert cannot be reported (set a healthchecks.io ping URL)"
    fi
fi

# ---------------------------------------------------------------------------
# 9. the record, the heartbeat, the alert
# ---------------------------------------------------------------------------
status=ok
# The record, not the exit code: a finding is a successful sweep that found
# something, and Alertmanager is its channel. The unit fails only when the
# monitor could not do its job (facts unwritten, alert path broken), which is
# exactly what the heartbeat reports. status stays "fail" so audit.log keeps the
# distinction between a clean sweep and one with findings.
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
    scope monitor heartbeat
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

# One fact per expected container: down is the root cause, unhealthy is the
# slower warning, and both are labels the per-check alerts already carry. A
# component that is down inhibits its dependent checks in Alertmanager, so one
# dead btc-explorer is one page, not a unit fault plus a verify failure plus a
# 502 from the public surface.
components_prom() {
    local ps_out f c line state up
    local -A ps_status=() seen=()
    ps_out=$(podman ps --format '{{.Names}}|{{.Status}}' 2>/dev/null) || return 0
    while IFS='|' read -r c line; do
        [ -n "$c" ] && ps_status[$c]=$line
    done <<< "$ps_out"
    for f in "$REPO_DIR"/deploy/*.container "$REPO_DIR"/deploy/*.container.in; do
        [ -f "$f" ] || continue
        # A oneshot has no running state to report; its verdict file is the
        # check (backup, dumps, drills).
        grep -qE '^Type=oneshot[[:space:]]*$' "$f" && continue
        c=$(basename "$f"); c=${c%.in}; c=${c%.container}
        [ -n "${seen[$c]:-}" ] && continue
        seen[$c]=1
        if [ "$MONITOR_SKIP_NODES" = 1 ] && unit_in_set "$c" "${CHAIN_UNITS[*]:-}"; then
            continue
        fi
        state=$(container_health_state "${ps_status[$c]:-}")
        up=1
        [ "$state" = down ] && up=0
        printf 'stack_component_up{component="%s"} %s\n' "$c" "$up"
        printf 'stack_component_health{component="%s",state="%s"} 1\n' "$c" "$state"
    done
}

# The facts vmalert's rules read. stack_monitor_check is the alert identity:
# component/check, so a dead btc-explorer is one component and its HTTP/verify
# symptoms share that label and can be inhibited by the component rule.
# stack_monitor_section stays as the human roll-up (and the history graph); it is
# no longer an alert. The detail is one info series per component/check, fetched
# at notification time, so a changing "9% free" never forks the alert.
# Under `off` neither these nor the sweep timestamp are written -- with no facts
# there is nothing for a rule to fire on, and a timestamp alone would page as
# stale.
sections_prom() {
    local i key s comp chk
    local -A secsev=() sev=() desc=()
    for i in "${!PROBLEMS[@]}"; do
        s="${PROBLEM_SECTIONS[$i]}"; comp="${PROBLEM_COMPONENTS[$i]}"; chk="${PROBLEM_CHECKS[$i]}"
        secsev[$s]=critical
        key="$comp|$chk"
        sev[$key]=critical
        desc[$key]+="${desc[$key]:+; }${PROBLEMS[$i]}"
    done
    for i in "${!WARNS[@]}"; do
        s="${WARN_SECTIONS[$i]}"; comp="${WARN_COMPONENTS[$i]}"; chk="${WARN_CHECKS[$i]}"
        [ "${secsev[$s]:-}" = critical ] || secsev[$s]=warning
        key="$comp|$chk"
        [ "${sev[$key]:-}" = critical ] || sev[$key]=warning
        desc[$key]+="${desc[$key]:+; }${WARNS[$i]}"
    done
    [ "${#secsev[@]}" -gt 0 ] || return 0
    printf '# TYPE stack_monitor_section gauge\n'
    for s in $(printf '%s\n' "${!secsev[@]}" | LC_ALL=C sort); do
        printf 'stack_monitor_section{service="%s",severity="%s"} 1\n' "$s" "${secsev[$s]}"
    done
    printf '# TYPE stack_monitor_check gauge\n'
    for key in $(printf '%s\n' "${!sev[@]}" | LC_ALL=C sort); do
        comp=${key%%|*}; chk=${key#*|}
        printf 'stack_monitor_check{component="%s",check="%s",severity="%s"} 1\n' \
            "$comp" "$chk" "${sev[$key]}"
    done
    printf '# TYPE stack_monitor_check_detail gauge\n'
    for key in $(printf '%s\n' "${!desc[@]}" | LC_ALL=C sort); do
        comp=${key%%|*}; chk=${key#*|}
        printf 'stack_monitor_check_detail{component="%s",check="%s",detail="%s"} 1\n' \
            "$comp" "$chk" "$(prom_label_value "${desc[$key]}")"
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
    printf 'stack_ids_ssh_fail %s\n' "${ids_ssh_fail:-0}"
    [ -n "$ids_rules_age_h" ] && printf 'stack_ids_rules_age_hours %s\n' "$ids_rules_age_h"
    printf 'stack_bouncer_bans %s\n' "${bouncer_bans:-0}"
    printf 'stack_bouncer_skipped %s\n' "${bouncer_skipped:-0}"
    printf 'stack_smart_up %s\n' "${smart_up:-0}"
    printf 'stack_smart_disks %s\n' "${smart_disks:-0}"
    for line in ${SMART_PROM[@]+"${SMART_PROM[@]}"}; do
        printf '%s\n' "$line"
    done
    printf 'stack_audit_fim_changes %s\n' "${audit_fim:-0}"
    printf 'stack_logs_ok %s\n' "${logs_ok:-0}"
    [ "$MONITOR_ALERTMANAGER_URL" = off ] || components_prom
    [ "$MONITOR_ALERTMANAGER_URL" = off ] || sections_prom
} | prom_write "$DATA_DIR/monitoring/textfile/monitor.prom" \
    || { scope monitor metrics; soft "could not write monitor.prom"; prom_ok=0; }

# The facts first, then the heartbeat's verdict. A completed sweep pings OK even
# when it has findings: the findings ride the rules, and the dead-man's switch
# exists for what the rules cannot report (a dead host, a wedged store, vmalert
# or Alertmanager, or a delivery that did not leave). Sending /fail for every
# finding made healthchecks.io a second copy of the alert path.
if [ "$ALERT_PATH_BROKEN" = 1 ]; then
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
    for w in ${WARNS[@]+"${WARNS[@]}"}; do
        printf '%s   warn %s\n' "$(date -Is)" "$w"
    done
} >> "$AUDIT_LOG"

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    if [ "$QUIET" = 1 ]; then
        # A finding no longer fails the unit, so the journal is the only place a
        # hand run and the timer read the same list. Keep printing it.
        summary >&2
    else
        say ""
        say "${#PROBLEMS[@]} problem(s):"
        printf '  - %s\n' "${PROBLEMS[@]}"
    fi
fi

if [ "$prom_ok" = 0 ]; then
    if [ "$QUIET" = 1 ]; then
        printf 'monitor: no check problems, but the facts could not be written to %s; no rule can fire\n' \
            "$DATA_DIR/monitoring/textfile/monitor.prom" >&2
    else
        say ""
        say "no problems, but the facts could not be written (see above)"
    fi
    exit 1
fi

if [ "$ALERT_PATH_BROKEN" = 1 ]; then
    if [ "$QUIET" = 1 ]; then
        printf 'monitor: the alert path is broken; the findings above could not be delivered (heartbeat and podman logs alertmanager/vmalert)\n' >&2
    else
        say ""
        say "the alert path is broken; the findings above could not be delivered"
    fi
    exit 1
fi

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    exit 0
fi

if [ "${#WARNS[@]}" -gt 0 ]; then
    say ""
    say "${#WARNS[@]} warning(s); no problems"
    exit 0
fi

say ""
say "all checks passed"
exit 0
