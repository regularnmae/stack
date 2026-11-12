#!/usr/bin/env bash
# Offline regression tests for deploy/root/bouncer.sh: the clamp it puts on a
# LAPI duration, and why a `--dry-run` leaves the live status file alone.
#
# The parse itself is dur_ms in deploy/root/status.sh, shared with the user tier
# and replayed against the fixtures by tests/test-lib.sh. What is bouncer-only is
# the clamp: the LAPI's `duration` becomes an nft timeout, where 0s is rejected
# and an unbounded value would be a permanent ban.
#
# This file extracts the function from the template (read-only; nothing here
# needs root) and pins its behaviour.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOUNCER="$ROOT_DIR/deploy/root/bouncer.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

# The bouncer sources the installed copy of this file; the test takes the
# checkout's, which is what install.sh renders it from.
# shellcheck source=../deploy/root/status.sh
source "$ROOT_DIR/deploy/root/status.sh"

# Pull one function out of the template by its definition line, up to the
# closing brace in column 0. Keeps this test from executing the script (which
# would read bouncer.env and apply nft rules).
extract() { # name src -> the function on stdout
    local name="$1"
    sed -n "/^${name}()/,/^}/p" "$2"
}

extract dur_to_sec "$BOUNCER" > "$TMP_DIR/dur_to_sec.sh"
[ -s "$TMP_DIR/dur_to_sec.sh" ] \
    || { printf 'FAIL: dur_to_sec not found in %s\n' "$BOUNCER" >&2; exit 1; }
# shellcheck source=/dev/null
. "$TMP_DIR/dur_to_sec.sh"

# --- dur_to_sec: dur_ms floored, then clamped ------------------------------
assert_eq 9000  "$(dur_to_sec '2h30m0.5s')" 'a fractional duration is floored'
assert_eq 1     "$(dur_to_sec '1s')" 'a one-second decision stays one second'
assert_eq 3600  "$(dur_to_sec '')" 'dur_to_sec defaults an absent duration to 1h'
assert_eq 3600  "$(dur_to_sec 'abc')" 'dur_to_sec defaults garbage to 1h'
# The clamp is the point: nft rejects a 0s timeout, so a sub-second remainder
# must not become 0; an absurd duration must not become a permanent ban.
assert_eq 3600  "$(dur_to_sec '999ms')" 'a sub-second decision becomes the 1h default'
assert_eq 86400 "$(dur_to_sec '48h')" 'dur_to_sec caps a long ban at 24h'
assert_eq 86400 "$(dur_to_sec '86401s')" 'dur_to_sec caps a just-over-a-day ban'

# --- write_status: the bouncer's fields, and the dry-run guard --------------
# bouncer.sh delegates the write to verdict_write (deploy/root/status.sh), which
# owns the dry-run rule because it has to cover every failure route (LAPI, JSON
# shape, classifier, nft), not only the success path that exits before the real
# write. A manual --dry-run against a down LAPI used to overwrite
# audit/bouncer.status with result=fail and page the monitor.
extract write_status "$BOUNCER" > "$TMP_DIR/write_status.sh"
[ -s "$TMP_DIR/write_status.sh" ] \
    || { printf 'FAIL: write_status not found in %s\n' "$BOUNCER" >&2; exit 1; }

STATUS="$TMP_DIR/bouncer.status"
CALLS="$TMP_DIR/status-calls"
: > "$CALLS"
say() { :; }
# The bouncer's own contribution is the field set it hands the shared writer.
# shellcheck disable=SC2317  # called by the extracted write_status below
verdict_write() { printf '%s\n' "$@" >> "$CALLS"; }
# shellcheck source=/dev/null
. "$TMP_DIR/write_status.sh"

write_status fail "LAPI unreachable at 127.0.0.1:8080" ""
assert_eq $'fail\nLAPI unreachable at 127.0.0.1:8080\nbanned=\nskipped=0' \
    "$(cat "$CALLS")" 'write_status passes the result, detail and its own counters'

# The guard itself, through the real writer: a dry run must neither create the
# file nor replace a live verdict.
# shellcheck source=../deploy/root/status.sh
. "$ROOT_DIR/deploy/root/status.sh"
verdict_init "$STATUS" /etc/stack-ids/bouncer.sh stack-bouncer.timer
DRY_RUN=1
write_status fail "LAPI unreachable at 127.0.0.1:8080" "" 2>/dev/null
[ -e "$STATUS" ] && { printf 'FAIL: --dry-run created %s\n' "$STATUS" >&2; exit 1; }
printf 'result=ok\nok_epoch=1\n' > "$STATUS"
DRY_RUN=1
write_status fail "LAPI unreachable at 127.0.0.1:8080" "" 2>/dev/null
assert_eq ok "$(env_value "$STATUS" result)" \
    '--dry-run leaves the live verdict in place'

DRY_RUN=0
write_status ok "" 2 1
assert_eq ok "$(env_value "$STATUS" result)" 'a real run replaces the verdict'
assert_eq 2 "$(env_value "$STATUS" banned)" 'a real run records the ban count'

printf 'bouncer parser tests: ok\n'
