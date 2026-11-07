#!/usr/bin/env bash
# Offline regression tests for the shared shell helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

assert_eq() {
    local want="$1" got="$2" label="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$label" "$want" "$got" >&2
        exit 1
    fi
}

assert_eq 9000500 "$(dur_ms 2h30m0.5s)" 'fractional duration'
assert_eq 500 "$(dur_ms 500ms)" 'millisecond duration'
assert_eq 5 "$(dur_s 4.5s)" 'duration rounds up'
assert_eq '[["method^getinfo","method^listpeers"]]' \
    "$(rune_json getinfo listpeers)" 'rune restriction JSON'

mkdir -p "$TMP_DIR/quadlet" "$TMP_DIR/data"
printf 'one\n' > "$TMP_DIR/quadlet/a.container"
printf 'two\n' > "$TMP_DIR/quadlet/b.container"
export QUADLET_DIR="$TMP_DIR/quadlet" DATA_DIR="$TMP_DIR/data"
before=$(unit_digest)
printf 'changed\n' > "$TMP_DIR/quadlet/b.container"
assert_eq b "$(unit_digest_changed "$before" "$(unit_digest)")" 'unit digest identifies changed unit'

printf 'shared shell helper tests: ok\n'
