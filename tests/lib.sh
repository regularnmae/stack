# shellcheck shell=bash
# Helpers shared by the shell regression tests. Sourced, not executed -- each
# test computes ROOT_DIR and TMP_DIR first, then sources this beside scripts/lib.sh.
#
# Only the assertions live here. A test's fixtures, extraction and cleanup stay
# in the test: assert_eq was the one function all three carried a copy of, and a
# failure that reads differently depending on which test caught it is a small
# but real cost on a red build.
assert_eq() {
    local want="$1" got="$2" label="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$label" "$want" "$got" >&2
        exit 1
    fi
}
