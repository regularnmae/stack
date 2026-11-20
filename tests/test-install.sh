#!/usr/bin/env bash
# Sandbox regression test for deploy/install.sh: the render, secret seeding and
# seed-once paths deploy.sh's --dry-run never reaches (it wraps install.sh in
# run()). Every writable root is redirected under a throwaway dir, and
# podman/systemctl/getenforce are stubs, so nothing here reads or writes the
# host's own data dir, units or quadlet config.
#
# The stub's `podman exec ... printenv` answers with $ADOPT_TOKEN: the installer
# must reuse a credential the running container already carries, and the second
# run (a different answer) must leave the seeded file alone.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/xdg" "$TMP_DIR/data"

cat > "$TMP_DIR/bin/podman" <<'SH'
#!/usr/bin/env bash
# The install path only needs these answers: no image is "current", builds are
# no-ops, the running container carries ADOPT_TOKEN, and nothing else exists.
case "$*" in
    "info --format "*)  printf 'file\n' ;;
    "image exists "*)   exit 1 ;;
    build*)             exit 0 ;;
    unshare*)           exit 0 ;;
    *" printenv "*)     [ -n "${ADOPT_TOKEN:-}" ] && printf '%s\n' "$ADOPT_TOKEN" ;;
    *)                  exit 1 ;;
esac
SH
cat > "$TMP_DIR/bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP_DIR/bin/getenforce" <<'SH'
#!/usr/bin/env bash
printf 'Disabled\n'
SH
chmod +x "$TMP_DIR/bin/"*

QUADLET="$TMP_DIR/xdg/containers/systemd"
USER_UNITS="$TMP_DIR/xdg/systemd/user"
CONFIG="$TMP_DIR/data/config"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

install_once() { # token
    HOME="$TMP_DIR/home" \
    XDG_CONFIG_HOME="$TMP_DIR/xdg" \
    STACK_DATA_DIR="$TMP_DIR/data" \
    STACK_DATA_ENV="$TMP_DIR/data.env" \
    STACK_BACKUP_DIR="$TMP_DIR/backup" \
    ADOPT_TOKEN="$1" \
    PATH="$TMP_DIR/bin:$PATH" \
        "$ROOT_DIR/deploy/install.sh"
}

check_modes() {
    local bad
    bad=$(find "$QUADLET" "$USER_UNITS" "$CONFIG" -type f ! -perm 600 -print)
    [ -z "$bad" ] || fail "rendered file(s) not mode 600:
$bad"
}

check_placeholders() {
    local hits
    # The awk program is single-quoted on purpose: $0 and FILENAME are awk's.
    # shellcheck disable=SC2016
    hits=$(find "$QUADLET" "$USER_UNITS" "$CONFIG" -type f -print0 \
        | xargs -0 -r awk '!/^[[:space:]]*#/ && /@[A-Z_][A-Z0-9_]*@/ {
            print FILENAME ":" FNR ":" $0
        }')
    [ -z "$hits" ] || fail "unsubstituted placeholder(s):
$hits"
}

token_a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
token_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# --- first install: adopt and seed -----------------------------------------
install_once "$token_a" >"$TMP_DIR/run1" 2>&1 \
    || fail "the first install exited non-zero:
$(cat "$TMP_DIR/run1")"

assert_eq "$token_a" \
    "$(sed -n 's/^SEARXNG_MCP_TOKEN=//p' "$CONFIG/searxng-mcp/token.env")" \
    'the token is reused from the running container'
grep -qF 'reused SEARXNG_MCP_TOKEN from the running searxng-mcp' "$TMP_DIR/run1" \
    || fail 'the install did not report the reused token'
if grep -qF "$token_a" "$TMP_DIR/run1"; then
    fail 'install.sh printed the adopted token'
fi

want=$(find "$ROOT_DIR/deploy" -maxdepth 1 \
    \( -name '*.container' -o -name '*.container.in' \) | wc -l)
got=$(find "$QUADLET" -maxdepth 1 -name '*.container' | wc -l)
assert_eq "$want" "$got" 'every container template is rendered'
if [ -n "$(find "$QUADLET" "$USER_UNITS" -name '*.in' -print -quit)" ]; then
    fail 'a rendered target still carries the .in suffix'
fi
check_modes
check_placeholders

# --- second install: seed-once ---------------------------------------------
# An operator edit and a seeded token both survive a re-run, even though the
# running container now answers with a different token.
printf '\n# operator edit\nBOLTMESH_EXTRA=1\n' >> "$CONFIG/boltmesh/app.env"
before=$(sha256sum "$CONFIG/searxng-mcp/token.env" | awk '{ print $1 }')
install_once "$token_b" >"$TMP_DIR/run2" 2>&1 \
    || fail "the second install exited non-zero:
$(cat "$TMP_DIR/run2")"
after=$(sha256sum "$CONFIG/searxng-mcp/token.env" | awk '{ print $1 }')
assert_eq "$before" "$after" 'the existing token survives a second install'
grep -qxF 'BOLTMESH_EXTRA=1' "$CONFIG/boltmesh/app.env" \
    || fail 'the second install overwrote an operator edit'
if grep -qF 'generated a new SEARXNG_MCP_TOKEN' "$TMP_DIR/run2"; then
    fail 'the second install announced a token it did not change'
fi
check_modes
check_placeholders

printf 'ok: install.sh renders and seeds in a sandbox, twice\n'
