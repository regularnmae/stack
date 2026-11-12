#!/usr/bin/env bash
# Offline regression tests for the status-file contract. There is one
# implementation, deploy/root/status.sh: the root tier sources it as
# /etc/stack-ids/status.sh and scripts/lib.sh sources it from the checkout.
#
# The contract is what scripts/monitor.sh and verify.sh read, so it is pinned
# here -- the fields, the ok_epoch carry-forward, the atomic write and its mode,
# and that the file loads with nothing but bash and coreutils. The last check
# pins that the user tier is still calling the shared function: a copy pasted
# back into lib.sh would pass every behavioural assert above and fails there.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED="$ROOT_DIR/deploy/root/status.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

HDR='# written by tests/test-status.sh'

# --- the writer, reached the way the user tier reaches it ------------------
ok_f="$TMP_DIR/ok.status"
status_write "$ok_f" "$HDR" ok 'all good' 'alerts=3' 'decisions=0'
fail_f="$TMP_DIR/fail.status"
printf 'ok_epoch=111\n' > "$fail_f"
status_write "$fail_f" "$HDR" fail $'two\nlines' 'alerts=4'

assert_eq "$HDR" "$(head -n1 "$ok_f")" 'the header names the scheduling unit'
assert_eq ok "$(env_value "$ok_f" result)" 'a success is recorded as ok'
assert_eq 'all good' "$(env_value "$ok_f" detail)" 'the detail is recorded'
assert_eq 3 "$(env_value "$ok_f" alerts)" 'the caller fields are recorded'
assert_eq 0 "$(env_value "$ok_f" decisions)" 'a zero caller field is kept'
assert_eq fail "$(env_value "$fail_f" result)" 'a failure is recorded as fail'
assert_eq 111 "$(env_value "$fail_f" ok_epoch)" \
    'a failure carries the previous ok_epoch'
assert_eq 'two lines' "$(env_value "$fail_f" detail)" \
    'the detail is flattened to one line'
# A success advances it; the same file, so it must be the run's own epoch.
assert_eq "$(env_value "$ok_f" epoch)" "$(env_value "$ok_f" ok_epoch)" \
    'a success advances ok_epoch'

assert_eq 644 "$(stat -c %a "$ok_f")" 'the status file is mode 644'
assert_eq 0 "$(find "$TMP_DIR" -name '.ok.status.*' | wc -l)" \
    'no temp file is left behind'

# --- the root tier's load path --------------------------------------------
# bouncer.sh and audit-report.sh source the INSTALLED copy, in a shell that has
# never seen scripts/lib.sh, stack.conf or podman. A helper that grew a
# dependency on the user tier would break here, not in the bouncer's timer.
root_f="$TMP_DIR/root.status"
cat > "$TMP_DIR/root-load.sh" <<'EOF'
. "$1"
status_write "$2" "$3" ok 'from root' 'banned=2'
EOF
env -i PATH="$PATH" bash --noprofile --norc "$TMP_DIR/root-load.sh" \
    "$SHARED" "$root_f" "$HDR"
assert_eq ok "$(env_value "$root_f" result)" \
    'the shared file loads and writes with no lib.sh present'
assert_eq 2 "$(env_value "$root_f" banned)" 'the root path passes its own fields'

# --- the completed-verdict protocol ---------------------------------------
# One writer for every job's verdict: the header, the dry-run rule and the
# "exited without a verdict" rule. A job that skips a wrapper is how a broken
# run keeps the previous result=ok in place and reads healthy.
vdir="$TMP_DIR/audit"
v="$vdir/job.status"

verdict_init "$v" 'tests/test-status.sh' 'deploy/job.timer'
verdict_write ok 'all good' 'alerts=1'
assert_eq '# written by tests/test-status.sh (deploy/job.timer)' "$(head -n1 "$v")" \
    'verdict_init composes the header from the writer and its scheduler'
assert_eq ok "$(env_value "$v" result)" 'verdict_write records the verdict'
assert_eq 1 "$(env_value "$v" alerts)" 'verdict_write passes the caller fields'

# A run that dies before naming its verdict: the previous ok must not survive.
verdict_init "$v" 'tests/test-status.sh' 'deploy/job.timer'
verdict_unrecorded 'the drill exited without recording a verdict'
assert_eq fail "$(env_value "$v" result)" \
    'verdict_unrecorded records a failure for a run with no verdict'
assert_eq 'the drill exited without recording a verdict' "$(env_value "$v" detail)" \
    'verdict_unrecorded keeps the caller detail'

# A recorded verdict is the run's own, and the trap that follows it is
# idempotent: a signal trap exits through the EXIT trap as well.
verdict_write ok 'fine'
verdict_unrecorded
verdict_unrecorded
assert_eq ok "$(env_value "$v" result)" \
    'verdict_unrecorded leaves a recorded verdict alone, twice'

# A dry run is a read, down to the directory: bouncer.sh --dry-run may be run
# against a down LAPI and must not page the monitor from a live verdict.
d="$TMP_DIR/dry/audit/bouncer.status"
DRY_RUN=1
verdict_init "$d" 'tests/test-status.sh' 'deploy/job.timer'
verdict_write fail 'LAPI unreachable' 2>/dev/null
verdict_unrecorded 2>/dev/null
DRY_RUN=0
if [ -e "$d" ] || [ -d "$TMP_DIR/dry/audit" ]; then
    fail 'a dry run created the status file or its directory'
fi

# --- one implementation, not two ------------------------------------------
# declare -f is the function as this shell has it; a fresh shell that has only
# the shared file shows what root would run. They must be the same text, which
# is the check that a copy-pasted second definition cannot pass.
cat > "$TMP_DIR/print-fn.sh" <<'EOF'
. "$1"
declare -f "$2"
EOF
for fn in env_value write_atomic status_write verdict_init verdict_write \
          verdict_unrecorded dur_ms; do
    fresh=$(env -i PATH="$PATH" bash --noprofile --norc "$TMP_DIR/print-fn.sh" \
        "$SHARED" "$fn")
    [ "$(declare -f "$fn")" = "$fresh" ] \
        || fail "lib.sh's $fn is not deploy/root/status.sh's"
done

# The two root reporters must actually source the installed copy: a shared file
# nobody loads is not shared.
for script in bouncer.sh audit-report.sh; do
    grep -qx '\. /etc/stack-ids/status.sh' "$ROOT_DIR/deploy/root/$script" \
        || fail "deploy/root/$script does not source /etc/stack-ids/status.sh"
done

printf 'status writer tests: ok\n'
