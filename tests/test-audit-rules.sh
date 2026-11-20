#!/usr/bin/env bash
# Offline regression tests for deploy/root/audit-rules-load.sh.
#
# The wrapper exists because augenrules exits 1 on a duplicate rule even with a
# correct ruleset. The one distinction it must keep: duplicate-only diagnostics
# are success, anything else is a real failure. A stub augenrules supplies both
# shapes; nothing here reloads the host's audit rules.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT_DIR/deploy/root/audit-rules-load.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

write_stub() { # body -> executable stub
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "$TMP_DIR/bin/augenrules"
    chmod +x "$TMP_DIR/bin/augenrules"
}

run_wrapper() {
    AUGENRULES="$TMP_DIR/bin/augenrules" "$WRAPPER" >"$TMP_DIR/out" 2>&1
}

# --- a clean load ----------------------------------------------------------
write_stub 'exit 0'
run_wrapper || { printf 'FAIL: a clean load must succeed\n' >&2; exit 1; }

# --- the known duplicate pair ---------------------------------------------
write_stub "cat <<'EOF'
/usr/sbin/augenrules: No change
Error sending add rule data request (Rule exists)
There was an error in line 5 of /etc/audit/audit.rules
enabled 1
failure 1
EOF
exit 1"
run_wrapper || { printf 'FAIL: duplicate-only diagnostics must succeed\n' >&2; exit 1; }
grep -qF 'already loaded' "$TMP_DIR/out" \
    || { printf 'FAIL: duplicate success was not explained\n' >&2; exit 1; }

# --- a real error alongside a duplicate ------------------------------------
write_stub "cat <<'EOF'
Error sending add rule data request (Rule exists)
There was an error in line 5 of /etc/audit/audit.rules
Error sending add rule data request (No such file or directory)
EOF
exit 1"
if run_wrapper; then
    printf 'FAIL: a real error must not be treated as a duplicate\n' >&2
    exit 1
fi
grep -qF 'No such file or directory' "$TMP_DIR/out" \
    || { printf 'FAIL: the wrapper did not pass the real error through\n' >&2; exit 1; }

# --- a non-duplicate failure ----------------------------------------------
write_stub "printf '%s\\n' 'Error sending add rule data request (Permission denied)'
exit 1"
if run_wrapper; then
    printf 'FAIL: a non-duplicate failure must fail\n' >&2
    exit 1
fi

# A failure that does not use the word "error" still must not hide behind the
# duplicate line.
write_stub "cat <<'EOF'
Error sending add rule data request (Rule exists)
There was an error in line 5 of /etc/audit/audit.rules
Could not open /etc/audit/rules.d/70-local.rules
EOF
exit 1"
if run_wrapper; then
    printf 'FAIL: a non-error-word failure must fail\n' >&2
    exit 1
fi

# --- a numeric exit code is preserved -------------------------------------
write_stub 'exit 7'
rc=0
AUGENRULES="$TMP_DIR/bin/augenrules" "$WRAPPER" >"$TMP_DIR/out" 2>&1 || rc=$?
assert_eq 7 "$rc" 'the wrapper preserves a non-duplicate exit code'
