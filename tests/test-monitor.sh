#!/usr/bin/env bash
# shellcheck disable=SC2034  # the extracted functions read these globals at call time
# Offline tests for the sweep's alert identity: a finding becomes
# stack_monitor_check{component,check}, not a section-sized bucket. The
# classifier is what keeps a verify.sh line from becoming a new alert every time
# its free text changes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITOR="$ROOT_DIR/scripts/monitor.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

extract() { # function-name file
    sed -n "/^$1()/,/^}/p" "$2"
}

# The pure pieces of monitor.sh. say() is the only output side effect; the
# section/check builders are tested through sections_prom's textfile output.
{
    printf 'set -euo pipefail\n'
    printf 'say() { :; }\n'
    extract prom_label_value "$ROOT_DIR/scripts/lib/jobs.sh"
    extract slug "$MONITOR"
    extract component_label "$MONITOR"
    extract scope "$MONITOR"
    extract soft "$MONITOR"
    extract fail "$MONITOR"
    extract classify_verify_line "$MONITOR"
    extract fulcrum_index_progress "$MONITOR"
    extract fulcrum_db_age "$MONITOR"
    extract fulcrum_index_state "$MONITOR"
    extract podman_healthcheck_unit "$MONITOR"
    extract sections_prom "$MONITOR"
} > "$TMP_DIR/functions.sh"
# shellcheck source=/dev/null
source "$TMP_DIR/functions.sh"

reset() {
    PROBLEMS=(); WARNS=()
    PROBLEM_SECTIONS=(); WARN_SECTIONS=()
    PROBLEM_COMPONENTS=(); WARN_COMPONENTS=()
    PROBLEM_CHECKS=(); WARN_CHECKS=()
    SECTION=other; COMPONENT=other; CHECK=other
}

# --- the verify.sh classifier ------------------------------------------------
assert_eq "btc-explorer explorer" \
    "$(classify_verify_line 'btc-explorer is not running')" \
    'a container name is the component'
assert_eq "btcpay health" \
    "$(classify_verify_line 'BTCPay /api/v1/health -> 000000')" \
    'the case-insensitive match keeps BTCPay on btcpay'
assert_eq "monero-wallet-btcpay wallet" \
    "$(classify_verify_line 'monero-wallet-btcpay: Up 42 minutes (unhealthy)')" \
    'the wallet container is the component'
assert_eq "fulcrum electrum" \
    "$(classify_verify_line 'fulcrum index is 20 block(s) behind bitcoind')" \
    'a component-specific name wins over the bitcoind mention'
assert_eq "lightningd sync" \
    "$(classify_verify_line 'lightningd reports warning_bitcoind_sync')" \
    'lightningd wins over its bitcoind mention'
assert_eq "verify verify" \
    "$(classify_verify_line 'a check this classifier has never seen')" \
    'an unknown line is one stable verify/verify alert, not one per message'

# --- the alert identity ------------------------------------------------------
reset
SECTION=verify_sh
scope verify_sh verify_sh
fail "btc-explorer is not running" btc-explorer explorer
soft "btc-explorer is slow" btc-explorer explorer
out=$(sections_prom)
grep -qx 'stack_monitor_check{component="btc-explorer",check="explorer",severity="critical"} 1' <<< "$out" \
    || { printf 'FAIL: the critical check series is missing\n%s\n' "$out" >&2; exit 1; }
grep -qx 'stack_monitor_check_detail{component="btc-explorer",check="explorer",detail="btc-explorer is not running; btc-explorer is slow"} 1' <<< "$out" \
    || { printf 'FAIL: the check detail is not aggregated\n%s\n' "$out" >&2; exit 1; }
grep -qx 'stack_monitor_section{service="verify_sh",severity="critical"} 1' <<< "$out" \
    || { printf 'FAIL: the section roll-up is missing\n%s\n' "$out" >&2; exit 1; }

# A warning-only check stays a warning; the section keeps the max severity.
reset
SECTION=host
scope host host
soft "SMART disk0 is warm" disk-sda temperature
out=$(sections_prom)
grep -qx 'stack_monitor_check{component="disk-sda",check="temperature",severity="warning"} 1' <<< "$out" \
    || { printf 'FAIL: the warning check series is missing\n%s\n' "$out" >&2; exit 1; }
grep -qx 'stack_monitor_section{service="host",severity="warning"} 1' <<< "$out" \
    || { printf 'FAIL: the warning section roll-up is missing\n%s\n' "$out" >&2; exit 1; }

# scope() keeps the hyphen/dot a container name carries, because that label is
# what Alertmanager's StackComponentDown inhibition matches.
reset
scope btc-explorer explorer
fail "btc-explorer is not running"
out=$(sections_prom)
grep -q 'component="btc-explorer"' <<< "$out" \
    || { printf 'FAIL: component_label dropped the hyphen\n%s\n' "$out" >&2; exit 1; }

# A changing message changes the detail, never the alert identity.
reset
scope db-dump freshness
fail 'pre-backup dump(s) not refreshed: kuma.sql (201h)'
a=$(sections_prom)
reset
scope db-dump freshness
fail 'pre-backup dump(s) not refreshed: kuma.sql (202h)'
b=$(sections_prom)
[ "$(printf '%s\n' "$a" | grep '^stack_monitor_check{' | sed 's/,detail=.*//')" = \
  "$(printf '%s\n' "$b" | grep '^stack_monitor_check{' | sed 's/,detail=.*//')" ] \
    || { printf 'FAIL: a changing detail forked the alert identity\n' >&2; exit 1; }

# --- Fulcrum reindex detection -----------------------------------------------
# The log line is the fact: a recent "Processed height" is a catch-up, a stale
# one is a stalled index. The podman call is stubbed so the test stays offline.
DATA_DIR="$TMP_DIR"
THRESH_INDEX_PROGRESS_S=21600
FULCRUM_DB_ACTIVE_S=900

# shellcheck disable=SC2317,SC2329  # called indirectly by fulcrum_index_progress
podman() {
    printf '%s [2026-11-22 11:45:36.726] <Controller> Processed height: 863000, 88.3%%, 4.56 blocks/min\n' \
        "$(date -u -d '-5 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')"
}
read -r fh fp fa fl <<< "$(fulcrum_index_progress)"
if [ "$fh" != 863000 ] || [ "$fp" != 88.3 ]; then
    printf 'FAIL: fulcrum progress parsed as height=%s pct=%s\n' "$fh" "$fp" >&2
    exit 1
fi
if [ "$fa" -lt 240 ] || [ "$fa" -gt 360 ]; then
    printf 'FAIL: fulcrum progress age=%s, expected about 300\n' "$fa" >&2
    exit 1
fi
if [ "$fl" -ne 21600 ]; then
    printf 'FAIL: one progress line should leave the limit at the floor, got %s\n' "$fl" >&2
    exit 1
fi

# The cadence is the gap between lines, not the floor: two lines 8h apart allow
# 1.5x that gap, so a live index that takes hours per 1000 blocks is not stalled.
# shellcheck disable=SC2317,SC2329  # called indirectly by fulcrum_index_progress
podman() {
    printf '%s [2026-11-22 03:45:36.726] <Controller> Processed height: 862000, 88.2%%, 2.28 blocks/min\n' \
        "$(date -u -d '-8 hours 5 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')"
    printf '%s [2026-11-22 11:45:36.726] <Controller> Processed height: 863000, 88.3%%, 2.28 blocks/min\n' \
        "$(date -u -d '-5 minutes' '+%Y-%m-%dT%H:%M:%S+00:00')"
}
read -r fh fp fa fl <<< "$(fulcrum_index_progress)"
if [ "$fl" -lt 40000 ] || [ "$fl" -gt 45000 ]; then
    printf 'FAIL: an 8h line gap should allow about 12h, got %s\n' "$fl" >&2
    exit 1
fi

# A healthy container with no Electrum answer and recent progress is INDEXING,
# not STALLED; the detail carries the percentage the mail shows.
MONITOR_SKIP_NODES=0
component_state() { printf 'healthy'; }
electrum_tip() { :; }
# shellcheck disable=SC2317,SC2329  # called indirectly by fulcrum_index_state
fulcrum_index_progress() { printf '863000 88.3 60 21600\n'; }
FULCRUM_INDEXING=0; FULCRUM_INDEX_STALLED=0; FULCRUM_INDEX_DETAIL=""
fulcrum_index_state
if [ "$FULCRUM_INDEXING" != 1 ] || [ "$FULCRUM_INDEX_STALLED" != 0 ]; then
    printf 'FAIL: recent progress was not classified as indexing\n' >&2
    exit 1
fi
case "$FULCRUM_INDEX_DETAIL" in
    *"88.3%"*) ;;
    *) { printf 'FAIL: indexing detail lost the percentage: %s\n' "$FULCRUM_INDEX_DETAIL" >&2; exit 1; } ;;
esac

# The same line, old, is a stalled index and must reach the critical path.
# shellcheck disable=SC2317,SC2329  # called indirectly by fulcrum_index_state
fulcrum_index_progress() { printf '863000 88.3 999999 21600\n'; }
FULCRUM_INDEXING=0; FULCRUM_INDEX_STALLED=0; FULCRUM_INDEX_DETAIL=""
fulcrum_index_state
if [ "$FULCRUM_INDEXING" != 0 ] || [ "$FULCRUM_INDEX_STALLED" != 1 ]; then
    printf 'FAIL: stale progress with no DB was not classified as stalled\n' >&2
    exit 1
fi

# The line can be overdue while the index is still committing. The WAL is the
# tie-breaker: a fresh one keeps the check at warning, a quiet one is the stall.
mkdir -p "$TMP_DIR/fulcrum/fulc2_db"
: > "$TMP_DIR/fulcrum/fulc2_db/000001.log"
# shellcheck disable=SC2317,SC2329  # called indirectly by fulcrum_index_state
fulcrum_index_progress() { printf '863000 88.3 999999 21600\n'; }
FULCRUM_INDEXING=0; FULCRUM_INDEX_STALLED=0; FULCRUM_INDEX_DETAIL=""
fulcrum_index_state
if [ "$FULCRUM_INDEXING" != 1 ] || [ "$FULCRUM_INDEX_STALLED" != 0 ]; then
    printf 'FAIL: an overdue line with a live DB was not classified as indexing\n' >&2
    exit 1
fi

# A restarted Fulcrum has no progress line yet; a fresh WAL is still a reindex.
# shellcheck disable=SC2317,SC2329  # called indirectly by fulcrum_index_state
fulcrum_index_progress() { :; }
FULCRUM_INDEXING=0; FULCRUM_INDEX_STALLED=0; FULCRUM_INDEX_DETAIL=""
fulcrum_index_state
if [ "$FULCRUM_INDEXING" != 1 ] || [ "$FULCRUM_INDEX_STALLED" != 0 ]; then
    printf 'FAIL: no line with a live DB was not classified as indexing\n' >&2
    exit 1
fi
case "$FULCRUM_INDEX_DETAIL" in
    *"no progress line yet"*) ;;
    *) { printf 'FAIL: no-line detail is missing: %s\n' "$FULCRUM_INDEX_DETAIL" >&2; exit 1; } ;;
esac

# A WAL that has also gone quiet is the stall the critical level is for.
touch -d '1 hour ago' "$TMP_DIR/fulcrum/fulc2_db/000001.log"
FULCRUM_INDEXING=0; FULCRUM_INDEX_STALLED=0; FULCRUM_INDEX_DETAIL=""
fulcrum_index_state
if [ "$FULCRUM_INDEXING" != 0 ] || [ "$FULCRUM_INDEX_STALLED" != 1 ]; then
    printf 'FAIL: no line with a quiet DB was not classified as stalled\n' >&2
    exit 1
fi

# --- podman healthcheck runner units -----------------------------------------
# A failing HealthCmd creates a transient `<container-id>-<hash>.service`; the
# container's own health is already an alert identity, so the runner unit must
# not become a second failed unit under an opaque name.
systemctl() {
    printf '%s\n' "${STUB_DESC:-}"
}
STUB_DESC='[systemd-run] /usr/bin/podman healthcheck run 1234'
if ! podman_healthcheck_unit '1234-deadbeef.service'; then
    printf 'FAIL: the podman healthcheck runner unit was not recognised\n' >&2
    exit 1
fi
STUB_DESC='a normal failed unit'
if podman_healthcheck_unit 'ordinary.service'; then
    printf 'FAIL: a normal unit was taken for a podman healthcheck runner\n' >&2
    exit 1
fi

printf 'monitor alert identity tests: ok\n'
