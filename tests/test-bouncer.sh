#!/usr/bin/env bash
# Offline regression tests for deploy/root/bouncer.sh: the Go-duration parser
# and the reason a `--dry-run` leaves the live status file alone.
#
# The bouncer runs as root and deliberately does not read the checkout, so it
# cannot source scripts/lib.sh -- which is why its dur_to_sec is a second copy
# of the rule and tests/fixtures/durations.txt is the one contract both copies
# read. The address guard that used to live here is deploy/root/ipguard.py now;
# tests/test-ipguard.py covers it.
#
# This file extracts the function from the template (read-only; nothing here
# needs root) and pins its behaviour, including the clamp that turns a
# sub-second or absurd LAPI duration into a sane nft timeout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOUNCER="$ROOT_DIR/deploy/root/bouncer.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

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

# --- dur_to_sec: the shared Go-duration fixtures, floored instead of rounded.
# The bouncer's clamp (1s floor, 86400s ceiling) is what the LAPI's `duration`
# field becomes in an nft timeout.
while IFS=$'\t' read -r input want_ms; do
    case "$input" in ''|\#*) continue ;; esac
    [ "$input" = '<empty>' ] && input=''
    want_s=$(( want_ms / 1000 ))
    [ "$want_s" -gt 0 ] || want_s=3600          # unparsable -> the 1h default
    [ "$want_s" -le 86400 ] || want_s=86400
    assert_eq "$want_s" "$(dur_to_sec "$input")" "dur_to_sec fixture '$input'"
done < "$ROOT_DIR/tests/fixtures/durations.txt"

# The clamp itself: a one-second decision is refreshed every minute, so a
# sub-second remainder must not become 0 (nft would reject it), and an absurd
# duration must not become a permanent ban.
assert_eq 3600 "$(dur_to_sec '')" 'dur_to_sec defaults an absent duration to 1h'
assert_eq 3600 "$(dur_to_sec 'abc')" 'dur_to_sec defaults garbage to 1h'
assert_eq 86400 "$(dur_to_sec '48h')" 'dur_to_sec caps a long ban at 24h'

# --- write_status: a dry run must not replace the live verdict --------------
# The guard is inside write_status so every failure path is covered (LAPI, JSON
# shape, classifier, nft), not just the success path that exits before the real
# write. A manual --dry-run against a down LAPI used to overwrite
# audit/bouncer.status with result=fail and page the monitor.
extract write_status "$BOUNCER" > "$TMP_DIR/write_status.sh"
[ -s "$TMP_DIR/write_status.sh" ] \
    || { printf 'FAIL: write_status not found in %s\n' "$BOUNCER" >&2; exit 1; }

STATUS="$TMP_DIR/bouncer.status"
CALLS="$TMP_DIR/status-calls"
: > "$CALLS"
say() { :; }
status_write() { printf '%s\n' "$1" >> "$CALLS"; }
# shellcheck source=/dev/null
. "$TMP_DIR/write_status.sh"

export DRY_RUN=1
write_status fail "LAPI unreachable at 127.0.0.1:8080" ""
[ -s "$CALLS" ] && { printf 'FAIL: --dry-run wrote the live status file\n' >&2; exit 1; }
[ -e "$STATUS" ] && { printf 'FAIL: --dry-run created %s\n' "$STATUS" >&2; exit 1; }

export DRY_RUN=0
write_status ok "" 2 1
assert_eq "$STATUS" "$(cat "$CALLS")" 'write_status writes the live verdict outside --dry-run'

printf 'bouncer parser tests: ok\n'
