#!/usr/bin/env bash
# Offline regression test for `./deploy.sh --dry-run`, which promises to change
# nothing. The three fetch wrappers used to create $BUILD_DIR outside run(), so a
# dry run against a build dir that did not exist yet left one behind -- a
# directory nobody asked for, on a path that may be a volume meant to stay empty.
#
# A full dry run reaches all three (fetch_repos, deploy_boltmesh -> fetch_boltmesh,
# fetch_agent_skills), so one invocation covers every guarded site.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

# Every writable root is redirected under the throwaway dir, so the run cannot
# read or write anything of the host's: BUILD_DIR is the case under test (absent),
# and the empty quadlet dir keeps the digest pass off the host's units.
status=0
BUILD_DIR="$TMP_DIR/build" \
STACK_DATA_DIR="$TMP_DIR/data" \
STACK_DATA_ENV="$TMP_DIR/data.env" \
XDG_CONFIG_HOME="$TMP_DIR/xdg" \
    "$ROOT_DIR/deploy.sh" --dry-run >"$TMP_DIR/out" 2>&1 || status=$?

assert_eq 0 "$status" 'the dry run exits 0'

# The bug and the promise it broke: neither path may exist afterwards.
[ ! -e "$TMP_DIR/build" ] \
    || { printf 'FAIL: the dry run created %s\n' "$TMP_DIR/build" >&2; exit 1; }
[ ! -e "$TMP_DIR/data" ] \
    || { printf 'FAIL: the dry run created %s\n' "$TMP_DIR/data" >&2; exit 1; }

grep -qF 'dry run complete; nothing was changed' "$TMP_DIR/out" \
    || { printf 'FAIL: the dry run did not reach its own end:\n' >&2
         cat "$TMP_DIR/out" >&2; exit 1; }

# Skipping the creation is not the fix -- the real run still needs the dir, so
# the plan has to say it would make one.
grep -qF "[dry-run] mkdir -p $TMP_DIR/build" "$TMP_DIR/out" \
    || { printf 'FAIL: the plan does not name the build dir it would create\n' >&2; exit 1; }

printf 'ok: deploy.sh --dry-run created nothing\n'
