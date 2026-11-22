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

printf 'monitor alert identity tests: ok\n'
