#!/usr/bin/env bash
# Consistent dumps of the two live application databases, taken immediately
# before the nightly restic run: nginx-proxy-manager's SQLite database and
# Uptime-Kuma's embedded MariaDB.
#
#   scripts/db-dump.sh          # both (what deploy/db-dump.service runs)
#   scripts/db-dump.sh npm      # one target, for debugging
#   scripts/db-dump.sh kuma
#
# Why this exists: BACKUP_PATHS must never include the live files
# (npm/data/database.sqlite and uptime-kuma/mariadb/). A file-by-file copy of a
# database a daemon is writing is only crash-recoverable -- the same reason the
# raw postgres/ cluster is not in the set -- and restic reads each file at its own
# instant, so even a datadir that would recover from a crash image can come back
# with a redo log and data pages from different moments. stack.conf's
# BACKUP_EXCLUDES takes those files out of the snapshot; this script
# writes what replaces them:
#
#   $DATA_DIR/npm-dump/database.sqlite      SQLite online-backup-API copy
#   $DATA_DIR/uptime-kuma-dump/kuma.sql     mariadb-dump --single-transaction
#
# Each target is written to a staging file OUTSIDE the backup set
# ($DATA_DIR/.db-dump/), validated there, and only renamed into place when it is
# good. A failed target therefore leaves the previous dump in the snapshot -- a
# stale dump, which scripts/monitor.sh fails on (MONITOR_DUMP_MAX_AGE_H) -- and
# never a torn fresh one. The exit status is non-zero if either target failed;
# backup.service Wants= this unit, so the restic run proceeds with the old copy.
#
# The NPM half is a throwaway container from the image the unit is running (so a
# Renovate bump cannot leave a stale tag here), mounting npm/data read-only. The
# kuma half is `podman exec` because its MariaDB listens on a unix socket inside
# its own container and a sibling container cannot reach it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

# Arguments are parsed before anything with a side effect: resolve_data_dir
# persists ~/.config/stack/data-dir.env, so a bare `--help` (or a typo'd target)
# must not get that far, and the dump directories must not be created for it.
DUMPS=(npm kuma)
case "${1:-}" in
    -h|--help) usage_header "$0"; exit 0 ;;
    npm)  DUMPS=(npm) ;;
    kuma) DUMPS=(kuma) ;;
    "")   ;;
    *)    die "unknown target: $1 (expected npm or kuma, or no argument for both)" ;;
esac

resolve_data_dir
command -v podman >/dev/null 2>&1 || die "podman is required"

# The dumps carry user tables (NPM's account hashes, kuma's users and monitors):
# 0600, in directories install.sh has already made 0700.
umask 077
NPM_DATA="$DATA_DIR/npm/data"
NPM_DUMP_DIR="$DATA_DIR/npm-dump"
KUMA_DUMP_DIR="$DATA_DIR/uptime-kuma-dump"
NPM_DUMP="$NPM_DUMP_DIR/database.sqlite"
KUMA_DUMP="$KUMA_DUMP_DIR/kuma.sql"
# Staging lives outside BACKUP_PATHS, so a kill between write and rename cannot
# leave a partial file for restic to walk.
STAGE="$DATA_DIR/.db-dump"

mkdir -p "$NPM_DUMP_DIR" "$KUMA_DUMP_DIR" "$STAGE"
chmod 700 "$NPM_DUMP_DIR" "$KUMA_DUMP_DIR" "$STAGE" 2>/dev/null || true
trap 'rm -rf "$STAGE"' EXIT

# One `podman run` that copies the live database through SQLite's online backup
# API and then proves the COPY: the API takes a read snapshot and restarts if a
# writer commits mid-copy, so this is consistent while NPM keeps serving, and
# quick_check is what catches a damaged result. --user 0 is the image's usual
# user made explicit: under rootless podman that is the host user, which owns the
# staging directory.
dump_npm() {
    local image stage="$STAGE/database.sqlite" js
    [ -s "$NPM_DATA/database.sqlite" ] \
        || { warn "npm: $NPM_DATA/database.sqlite does not exist (has nginx-proxy-manager started?)"; return 1; }
    image=$(npm_image)
    if ! podman image exists "$image" 2>/dev/null; then
        warn "npm: image $image is not present; cannot take a consistent copy"
        return 1
    fi
    js='
const Database = require("/app/node_modules/better-sqlite3");
const src = "/data/database.sqlite";
const out = "/stage/database.sqlite";
const db = new Database(src, { readonly: true, fileMustExist: true });
db.backup(out).then(() => {
  db.close();
  const copy = new Database(out, { readonly: true, fileMustExist: true });
  const rows = copy.pragma("quick_check");
  copy.close();
  const verdict = Array.isArray(rows) && rows[0] ? rows[0].quick_check : "";
  if (verdict !== "ok") {
    console.error("quick_check on the copy: " + JSON.stringify(rows));
    process.exit(1);
  }
  process.exit(0);
}).catch((e) => {
  console.error("sqlite backup failed: " + (e && e.message ? e.message : e));
  process.exit(1);
});
'
    # --network none: nothing here needs the network. :ro on the live data dir:
    # the backup API only reads it, and the copy is written to the staging mount.
    if ! podman run --rm --pull=never --network none --user 0 \
        --entrypoint /usr/bin/node \
        -v "$NPM_DATA:/data:ro,z" -v "$STAGE:/stage:z" \
        "$image" -e "$js" >/dev/null; then
        warn "npm: the SQLite online backup failed; keeping the previous dump"
        rm -f "$stage"
        return 1
    fi
    [ -s "$stage" ] || { warn "npm: the SQLite copy is empty; keeping the previous dump"; return 1; }
    # set -e does NOT reach into a function called as `dump_npm || rc=1`, so the
    # install step has to check itself or a failed rename exits 0 with the old
    # dump in place.
    mv -f "$stage" "$NPM_DUMP" \
        || { warn "npm: could not install $NPM_DUMP; keeping the previous dump"; rm -f "$stage"; return 1; }
    # The container writes with its own umask (022), so the copy arrives 0644;
    # this one carries NPM's account hashes. The kuma half is written by this
    # shell and already honours umask 077.
    chmod 600 "$NPM_DUMP" 2>/dev/null || true
    log "npm: wrote $NPM_DUMP ($(du -h "$NPM_DUMP" | cut -f1), quick_check ok)"
}

# --single-transaction is the InnoDB consistent snapshot: no table locks, no
# service interruption. Only the `kuma` database is dumped -- the MariaDB system
# tables are rebuilt by the freshly initialised datadir at restore time -- and
# --databases keeps the CREATE DATABASE/USE so the import is self-contained.
dump_kuma() {
    local stage="$STAGE/kuma.sql"
    if ! podman container exists uptime-kuma 2>/dev/null \
        || [ "$(podman inspect uptime-kuma --format '{{.State.Running}}' 2>/dev/null || true)" != true ]; then
        warn "kuma: uptime-kuma is not running; keeping the previous dump"
        return 1
    fi
    if ! podman exec uptime-kuma mariadb-dump \
        --socket=/app/data/run/mariadb.sock -u root \
        --single-transaction --databases kuma >"$stage"; then
        warn "kuma: mariadb-dump failed; keeping the previous dump"
        rm -f "$stage"
        return 1
    fi
    # Header and completion trailer: a dump killed mid-write is still a valid
    # SQL prefix, so the trailer is the cheap proof it finished.
    if ! grep -q '^-- MariaDB dump' "$stage" || ! grep -q '^-- Dump completed' "$stage"; then
        warn "kuma: the dump is truncated (no header or completion trailer); keeping the previous one"
        rm -f "$stage"
        return 1
    fi
    mv -f "$stage" "$KUMA_DUMP" \
        || { warn "kuma: could not install $KUMA_DUMP; keeping the previous dump"; rm -f "$stage"; return 1; }
    chmod 600 "$KUMA_DUMP" 2>/dev/null || true
    log "kuma: wrote $KUMA_DUMP ($(du -h "$KUMA_DUMP" | cut -f1), completion trailer present)"
}

rc=0
for target in "${DUMPS[@]}"; do
    case "$target" in
        npm)  dump_npm  || rc=1 ;;
        kuma) dump_kuma || rc=1 ;;
    esac
done
[ "$rc" -eq 0 ] || warn "at least one database dump failed; the backup keeps the previous copy"
exit "$rc"
