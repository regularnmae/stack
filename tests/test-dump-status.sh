#!/usr/bin/env bash
# Offline regression tests for scripts/dump-status.sh, the postgres-dump
# ExecStopPost writer.
#
# The dump unit's exit code is pg_dumpall's; this helper only records the cause.
# These tests pin that it always exits 0, that its detail names the service and
# the kept file, and that a success is recorded as ok.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/dump-status.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"
# env_value is the status-file reader; source the one implementation directly.
# shellcheck source=../deploy/root/status.sh
source "$ROOT_DIR/deploy/root/status.sh"

DATA="$TMP_DIR/data"
AUDIT="$DATA/audit"
mkdir -p "$DATA/postgres-dump"

run_helper() { # result [status]
    STACK_DATA_DIR="$DATA" STACK_STATUS_SH="$ROOT_DIR/deploy/root/status.sh" \
        "$HELPER" postgres-dump "$1" "${2:-}"
}

# --- a failed dump is recorded as fail, and the helper still exits 0 -------
run_helper exit-code 1
assert_eq fail "$(env_value "$AUDIT/postgres-dump.status" result)" \
    'a failed dump is recorded as fail'
grep -qF 'postgres-dump.service exited 1' "$AUDIT/postgres-dump.status" \
    || { printf 'FAIL: the detail does not name the failed service\n' >&2; exit 1; }
grep -qF 'previous all.sql was kept' "$AUDIT/postgres-dump.status" \
    || { printf 'FAIL: the detail does not say the previous dump was kept\n' >&2; exit 1; }

# --- a timeout has its own detail ------------------------------------------
run_helper timeout
grep -qF 'timed out' "$AUDIT/postgres-dump.status" \
    || { printf 'FAIL: a timeout is not named\n' >&2; exit 1; }

# --- success replaces the file and advances ok_epoch -----------------------
printf 'dump\n' > "$DATA/postgres-dump/all.sql"
run_helper success 0
assert_eq ok "$(env_value "$AUDIT/postgres-dump.status" result)" \
    'a successful dump is recorded as ok'
assert_eq "$(env_value "$AUDIT/postgres-dump.status" epoch)" \
    "$(env_value "$AUDIT/postgres-dump.status" ok_epoch)" \
    'success advances ok_epoch'

# --- a success with no file is a failure, not a false green ----------------
rm -f "$DATA/postgres-dump/all.sql"
run_helper success 0
assert_eq fail "$(env_value "$AUDIT/postgres-dump.status" result)" \
    'success without a dump file is a failure'

# --- the staged path derives the data dir ----------------------------------
# Runtime is $DATA_DIR/bin/dump-status.sh, not the checkout, and the unit passes
# no STACK_DATA_DIR. Pin that the parent of bin/ is the data dir.
mkdir -p "$DATA/bin"
cp "$HELPER" "$DATA/bin/dump-status.sh"
printf 'dump\n' > "$DATA/postgres-dump/all.sql"
STACK_STATUS_SH="$ROOT_DIR/deploy/root/status.sh" \
    "$DATA/bin/dump-status.sh" postgres-dump success 0
assert_eq ok "$(env_value "$AUDIT/postgres-dump.status" result)" \
    'the staged helper finds the data dir from its own path'

# --- a missing writer cannot fail the unit ---------------------------------
STACK_DATA_DIR="$DATA" STACK_STATUS_SH="$TMP_DIR/missing-status.sh" \
    "$HELPER" postgres-dump exit-code 1 >/dev/null 2>&1 \
    || { printf 'FAIL: a missing status writer made the helper fail\n' >&2; exit 1; }
