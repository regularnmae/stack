#!/usr/bin/env bash
# Offline regression tests for the status-file contract, run against BOTH
# implementations: scripts/lib.sh's status_write (the user tier) and
# deploy/root/status.sh (the root tier, which cannot source the checkout).
#
# They are two files because the privilege boundary is real, not because the
# shape may differ: this runs the same table through each and diffs the result,
# so a change to one side that forgets the other fails here -- the same
# arrangement tests/test-lib.sh and tests/test-bouncer.sh use for the two
# Go-duration parsers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_eq() {
    local want="$1" got="$2" label="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$label" "$want" "$got" >&2
        exit 1
    fi
}

HDR='# written by tests/test-status.sh'
# time= and epoch= are the clock, and the two runs necessarily disagree on both.
strip_clock() { grep -v -e '^time=' -e '^epoch=' "$1"; }

# --- the user tier ---------------------------------------------------------
lib_ok="$TMP_DIR/lib-ok.status"
status_write "$lib_ok" "$HDR" ok 'all good' 'alerts=3' 'decisions=0'
lib_fail="$TMP_DIR/lib-fail.status"
printf 'ok_epoch=111\n' > "$lib_fail"
status_write "$lib_fail" "$HDR" fail $'two\nlines' 'alerts=4'

# --- the root tier (sourcing it replaces the functions above) ---------------
# shellcheck source=../deploy/root/status.sh
source "$ROOT_DIR/deploy/root/status.sh"

root_ok="$TMP_DIR/root-ok.status"
status_write "$root_ok" "$HDR" ok 'all good' 'alerts=3' 'decisions=0'
root_fail="$TMP_DIR/root-fail.status"
printf 'ok_epoch=111\n' > "$root_fail"
status_write "$root_fail" "$HDR" fail $'two\nlines' 'alerts=4'

# --- the two files are one contract ----------------------------------------
strip_clock "$lib_ok" > "$TMP_DIR/lib-ok.stripped"
strip_clock "$root_ok" > "$TMP_DIR/root-ok.stripped"
cmp -s "$TMP_DIR/lib-ok.stripped" "$TMP_DIR/root-ok.stripped" \
    || fail "lib.sh and deploy/root/status.sh disagree on a successful run:
$(diff -u "$TMP_DIR/lib-ok.stripped" "$TMP_DIR/root-ok.stripped" || true)"
strip_clock "$lib_fail" > "$TMP_DIR/lib-fail.stripped"
strip_clock "$root_fail" > "$TMP_DIR/root-fail.stripped"
cmp -s "$TMP_DIR/lib-fail.stripped" "$TMP_DIR/root-fail.stripped" \
    || fail "lib.sh and deploy/root/status.sh disagree on a failure:
$(diff -u "$TMP_DIR/lib-fail.stripped" "$TMP_DIR/root-fail.stripped" || true)"

# --- and it is the contract the monitor reads ------------------------------
assert_eq ok "$(env_value "$root_ok" result)" 'a success is recorded as ok'
assert_eq 'all good' "$(env_value "$root_ok" detail)" 'the detail is recorded'
assert_eq 3 "$(env_value "$root_ok" alerts)" 'the caller fields are recorded'
assert_eq 0 "$(env_value "$root_ok" decisions)" 'a zero caller field is kept'
assert_eq fail "$(env_value "$root_fail" result)" 'a failure is recorded as fail'
assert_eq 111 "$(env_value "$root_fail" ok_epoch)" \
    'a failure carries the previous ok_epoch'
assert_eq 'two lines' "$(env_value "$root_fail" detail)" \
    'the detail is flattened to one line'
# A success advances it; the same file, so it must be the run's own epoch.
assert_eq "$(env_value "$root_ok" epoch)" "$(env_value "$root_ok" ok_epoch)" \
    'a success advances ok_epoch'

assert_eq 644 "$(stat -c %a "$root_ok")" 'the status file is mode 644'
assert_eq 0 "$(find "$TMP_DIR" -name '.root-ok.status.*' | wc -l)" \
    'no temp file is left behind'

# The two reporters must actually use it -- a copy nobody sources is not shared.
for script in bouncer.sh audit-report.sh; do
    grep -qx '\. /etc/stack-ids/status.sh' "$ROOT_DIR/deploy/root/$script" \
        || fail "deploy/root/$script does not source /etc/stack-ids/status.sh"
done

printf 'status writer tests: ok\n'
