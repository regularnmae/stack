#!/usr/bin/env bash
# Back up and restore the stack's irreplaceable state with restic.
#
#   scripts/backup.sh [backup]        # run the job now: init if needed, back up, prune
#   scripts/backup.sh init            # initialise the repository only
#   scripts/backup.sh list            # list snapshots
#   scripts/backup.sh list --json     # the same, for scripts (restic's JSON)
#   scripts/backup.sh ls [<snap>]     # list the paths inside a snapshot
#   scripts/backup.sh check           # verify repository integrity
#   scripts/backup.sh verify [opts]   # restore a snapshot to a scratch dir and check it
#   scripts/backup.sh forget          # apply the retention policy (and prune)
#   scripts/backup.sh restore <snap>  # restore into the data dir, in place
#   scripts/backup.sh unlock          # clear stale locks
#
# `verify` is the restore drill, run weekly by deploy/backup-verify.timer: it
# reads a slice of the repository's data, restores the snapshot into a scratch
# directory ($DATA_DIR/backup-verify, wiped afterwards), and asserts that every
# BACKUP_PATHS entry came back non-empty along with the markers in
# BACKUP_VERIFY_PATHS. It never touches the live data dirs -- only the repository,
# the cache and the scratch target are mounted -- so it is safe on a running
# host. Its result is written to $DATA_DIR/audit/backup-verify.status, which is
# what scripts/monitor.sh alerts on: a failed oneshot unit is otherwise just a
# line in `systemctl --user status`. Options:
#   --snapshot <id>   the snapshot to restore (default latest)
#   --no-check        skip `restic check --read-data-subset` (the restore still
#                     verifies the restored bytes)
#   --keep            leave the restored tree in place to inspect it
#   --with-db         additionally replay all three dumps -- postgres-dump/all.sql
#                     into a throwaway postgres, uptime-kuma-dump/kuma.sql into a
#                     throwaway MariaDB -- and prove they produce tables. The
#                     SQLite copy is checked on every run instead (quick_check is
#                     cheap); this is the quarterly drill for the two server dumps.
#
# The scheduled run lives in deploy/backup.container + deploy/backup.timer;
# this helper runs the same job by hand and adds the read/restore commands. Both
# read the backup set from one declaration -- BACKUP_PATHS in stack.conf -- which
# deploy/install.sh also renders into the unit, so what a hand run copies is
# exactly what the nightly job copies. The database dumps are refreshed here the
# same way the unit's Wants=postgres-dump.service/db-dump.service refreshes them:
# the live database files are in BACKUP_EXCLUDES, and the dumps replace them.
#
# The repository and password are read from the ENVIRONMENT FIRST, then from
# $DATA_DIR/config/backup/backup.env. That order is what makes recovery on a
# fresh host possible at all: the backed-up backup.env lives inside the
# repository, so it cannot be the only source of the password that opens it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

# The backup set. Not defaulted: an empty set would produce a snapshot that
# silently holds nothing, which is worse than a clear error.
if [ "${BACKUP_PATHS+x}" != x ] || [ "${#BACKUP_PATHS[@]}" -eq 0 ]; then
    die "stack.conf must define BACKUP_PATHS (the backup set)"
fi

RESTIC_IMAGE="${RESTIC_IMAGE:-docker.io/restic/restic:0.19.1}"
STACK_BACKUP_DIR="${STACK_BACKUP_DIR:-$HOME/data-backup}"
RETENTION=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

command -v podman >/dev/null 2>&1 || die "podman is required"

cmd="${1:-backup}"
[ $# -gt 0 ] && shift

case "$cmd" in
    -h|--help) usage_header "$0"; exit 0 ;;
    backup|init|list|snapshots|ls|check|forget|restore|unlock|version|verify) ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac

# restore and ls take a snapshot argument; verify takes a snapshot plus flags;
# everything else takes none.
snapshot=""
VERIFY_CHECK=1
VERIFY_KEEP=0
VERIFY_DB=0
case "$cmd" in
    restore|ls)
        for a in "$@"; do
            case "$a" in
                -y|--yes) ASSUME_YES=1 ;;
                *) [ -n "$snapshot" ] && die "$cmd takes one snapshot id"; snapshot="$a" ;;
            esac
        done
        snapshot="${snapshot:-latest}"
        ;;
    verify)
        while [ $# -gt 0 ]; do
            case "$1" in
                --snapshot) [ $# -ge 2 ] || die "--snapshot needs an id"; snapshot="$2"; shift ;;
                --no-check) VERIFY_CHECK=0 ;;
                --keep)     VERIFY_KEEP=1 ;;
                --with-db)  VERIFY_DB=1 ;;
                *)          die "verify: unknown argument: $1 (try --help)" ;;
            esac
            shift
        done
        snapshot="${snapshot:-latest}"
        ;;
esac

# Resolving the data dir can prompt on a fresh host, so it happens after the
# argument parsing (--help stays side-effect free).
resolve_data_dir
BACKUP_ENV="$CONFIG_DIR/backup/backup.env"

# Environment wins over the file (see the header): a restore on a fresh host
# has no backup.env yet.
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-$(env_value "$BACKUP_ENV" RESTIC_REPOSITORY)}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-$(env_value "$BACKUP_ENV" RESTIC_PASSWORD)}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$(env_value "$BACKUP_ENV" RESTIC_CACHE_DIR)}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/cache}"
[ -n "$RESTIC_REPOSITORY" ] || die "no repository: set RESTIC_REPOSITORY, or run deploy/install.sh first"
[ -n "$RESTIC_PASSWORD" ] || die "no password: set RESTIC_PASSWORD, or run deploy/install.sh first"
export RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_CACHE_DIR

# The repo is mounted at /repo for the local default; a remote
# RESTIC_REPOSITORY makes that mount unused, which is harmless.
#
# --log-driver=none: restic's output is the *caller's* (a hand run prints it, the
# monitor captures `list --json`, verify captures the snapshot table) and the
# driver only controls whether podman also journals a copy. Without it every
# monitor and verify sweep wrote the whole snapshot table into the journal --
# 161 lines every five minutes -- which the log store then indexed: the same
# one-shot-container noise kuma-ctl and the apprise probe already avoid.
common=(
    --rm
    --log-driver=none
    -v "$STACK_BACKUP_DIR:/repo:z"
    -v "$DATA_DIR/backup-cache:/cache:z"
    --env RESTIC_REPOSITORY --env RESTIC_PASSWORD --env RESTIC_CACHE_DIR
)
# The backup set, derived from BACKUP_PATHS in stack.conf -- the same
# declaration deploy/install.sh renders into deploy/backup.container's Volume=
# lines and Exec=. Nothing below repeats the list: a directory added there is
# mounted, backed up, created before a restore and named in the prompt
# automatically.
#
# The mount paths mirror $DATA_DIR (/data/<name>), which is what lets `restore
# --target /` land the contents back in the data dir. `:z` (shared) because
# lightningd, nginx-proxy-manager and tor mount some of these directories too.
data_ro=()
data_rw=()
backup_paths=()
for p in "${BACKUP_PATHS[@]}"; do
    # audit/ holds a root-owned auditd.fim that podman cannot relabel (:z fails);
    # the directory already carries container_file_t, so leave the label alone.
    # Both arrays: `backup` reads through data_ro, `restore` writes through
    # data_rw, and a relabel on the write path fails for the same reason.
    if [ "$p" = audit ]; then
        data_ro+=(-v "$DATA_DIR/$p:/data/$p:ro")
        data_rw+=(-v "$DATA_DIR/$p:/data/$p")
    else
        data_ro+=(-v "$DATA_DIR/$p:/data/$p:ro,z")
        data_rw+=(-v "$DATA_DIR/$p:/data/$p:z")
    fi
    backup_paths+=("/data/$p")
done

# What restic must not walk inside those directories (BACKUP_EXCLUDES in
# stack.conf): the live database files, whose consistent copies are the dumps.
# Each flag is single-quoted because an entry can be a glob
# (npm/data/database.sqlite* covers the db and any -journal/-wal/-shm beside it):
# restic matches it, and the container's shell must pass it through unexpanded.
exclude_args=""
for p in ${BACKUP_EXCLUDES[@]+"${BACKUP_EXCLUDES[@]}"}; do
    exclude_args+="--exclude='/data/$p' "
done
exclude_args="${exclude_args% }"

restic() { podman run "${common[@]}" "$RESTIC_IMAGE" "$@"; }

# Every bind-mount source must exist before podman runs: with SELinux relabel
# (:z) podman statfs's the source and fails rather than creating it. A restore
# is exactly the case where they are missing, so create them.
ensure_mount_dirs() {
    mkdir -p "$STACK_BACKUP_DIR" "$DATA_DIR/backup-cache"
    local p
    for p in "${BACKUP_PATHS[@]}"; do
        mkdir -p "$DATA_DIR/$p"
    done
}
ensure_mount_dirs

# The same job the nightly unit runs (deploy/backup.container's Exec=), built
# from the same declaration: the path list, the excludes and the retention
# policy are generated, so the two cannot drift.
job_script=$(
    printf 'set -e\n'
    printf 'restic snapshots >/dev/null 2>&1 || restic init\n'
    printf 'restic backup %s %s --host stack --tag stack\n' "${backup_paths[*]}" "$exclude_args"
    printf 'restic forget --tag stack --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune\n'
)

# The nightly unit gets fresh dumps from postgres-dump.service and
# db-dump.service, pulled in by Wants=/After= in deploy/backup.container. A hand
# run has no such ordering, so it runs whichever of the two are installed here.
# Best-effort, exactly like the units: a database outage must never stop the run
# that protects the wallet and the CLN identity, and the previous dump is still
# worth copying.
refresh_dumps() {
    local p unit in_set=0 ran=0
    for p in "${BACKUP_PATHS[@]}"; do
        case "$p" in postgres-dump|npm-dump|uptime-kuma-dump) in_set=1 ;; esac
    done
    [ "$in_set" = 1 ] || return 0

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl is unavailable; copying the dumps as they stand"
        return 0
    fi
    for unit in postgres-dump db-dump; do
        systemctl --user cat "$unit.service" >/dev/null 2>&1 || continue
        ran=1
        if systemctl --user start "$unit.service"; then
            log "refreshed the $unit dump"
        else
            warn "$unit.service failed; copying the previous dump (if any)"
        fi
    done
    [ "$ran" = 1 ] || warn "the dump services are not installed; copying the dumps as they stand"
}

# ---------------------------------------------------------------------------
# the restore drill (`verify`)
# ---------------------------------------------------------------------------
# Everything below reads the repository and writes only to a scratch directory:
# the live data dirs are not mounted at all, which is what makes this safe to run
# on a serving host.
VERIFY_STATUS="$DATA_DIR/audit/backup-verify.status"
VERIFY_SUBSET_FILE="$DATA_DIR/audit/backup-verify.subset"
VERIFY_LOCK="$DATA_DIR/audit/backup.lock"
VERIFY_TARGET="${BACKUP_VERIFY_TARGET:-$DATA_DIR/backup-verify}"
VERIFY_MAX_MB="${BACKUP_VERIFY_MAX_MB:-5120}"
VERIFY_SUBSET_PARTS="${BACKUP_VERIFY_SUBSET_PARTS:-4}"
VERIFY_DB_CONTAINER=""

# The record scripts/monitor.sh alerts on (a failed oneshot unit is otherwise
# just a line in `systemctl --user status`). KEY=VALUE so env_value can read it,
# written atomically so a sweep never sees half a line. ok_epoch is the last
# SUCCESS and is carried forward by a failure or a skip: the age check keys on
# it, so a drill that skips forever (no disk space, an oversized set) cannot
# look healthy just because the timer fired.
write_verify_status() { # result detail [snapshot files bytes subset]
    local result="$1" detail="$2" snap="${3:-}" files="${4:-}" bytes="${5:-}" subset="${6:-}"
    local now prev_ok="" ok_epoch tmp
    now=$(date +%s)
    [ -f "$VERIFY_STATUS" ] && prev_ok=$(env_value "$VERIFY_STATUS" ok_epoch)
    case "$prev_ok" in ''|*[!0-9]*) prev_ok="" ;; esac
    if [ "$result" = ok ]; then ok_epoch="$now"; else ok_epoch="$prev_ok"; fi
    mkdir -p "$DATA_DIR/audit"
    tmp=$(mktemp "$DATA_DIR/audit/.backup-verify.XXXXXX") \
        || { warn "could not write $VERIFY_STATUS"; return 0; }
    if {
        printf '# written by scripts/backup.sh verify (deploy/backup-verify.timer)\n'
        printf 'time=%s\n' "$(date -Is)"
        printf 'epoch=%s\n' "$now"
        printf 'result=%s\n' "$result"
        printf 'ok_epoch=%s\n' "$ok_epoch"
        printf 'snapshot=%s\n' "$snap"
        printf 'files=%s\n' "$files"
        printf 'bytes=%s\n' "$bytes"
        printf 'subset=%s\n' "$subset"
        printf 'detail=%s\n' "$(printf '%s' "$detail" | tr '\n' ' ')"
    } > "$tmp"; then
        mv -f "$tmp" "$VERIFY_STATUS" || warn "could not write $VERIFY_STATUS"
    else
        rm -f "$tmp"
        warn "could not write $VERIFY_STATUS"
    fi
}

# The scratch tree and the drill's throwaway postgres, removed on any exit path
# (a failure must not leave a 700 MiB copy of the wallet on the data disk).
verify_cleanup() {
    if [ -n "${VERIFY_DB_CONTAINER:-}" ]; then
        podman rm -f "$VERIFY_DB_CONTAINER" >/dev/null 2>&1 || true
    fi
    case "${VERIFY_TARGET:-}" in
        ""|/) return 0 ;;
    esac
    if [ "${VERIFY_KEEP:-0}" = 1 ]; then
        log "kept the restored tree at $VERIFY_TARGET"
        return 0
    fi
    remove_verify_target
}

# restic restores the numeric owners, so the wallet comes back as the image uid
# (host 525287): a plain `rm -rf` as the host user cannot unlink inside those
# directories. `podman unshare` enters the user namespace where they are mapped,
# which is the same trick install.sh uses to chown the wallet. Fall back to rm
# when podman is unavailable.
remove_verify_target() {
    case "${VERIFY_TARGET:-}" in
        ""|/) return 0 ;;
    esac
    if command -v podman >/dev/null 2>&1 && podman unshare rm -rf "$VERIFY_TARGET" 2>/dev/null; then
        return 0
    fi
    rm -rf "$VERIFY_TARGET" 2>/dev/null || warn "could not remove $VERIFY_TARGET"
}

# Count and measure a restored subtree from inside the user namespace: restic
# restores the numeric owners, so the wallet comes back owned by a subuid the
# host user cannot read. A plain find/du would under-count it (and, with
# pipefail, abort the drill on exactly the directories that matter).
tree_count() { # path -> number of files
    local n
    n=$(podman unshare find "$1" -type f 2>/dev/null | wc -l | tr -d ' ') || n=0
    printf '%s' "${n:-0}"
}
tree_size() { # path -> bytes
    local n
    n=$(podman unshare du -sb "$1" 2>/dev/null | cut -f1) || n=0
    printf '%s' "${n:-0}"
}

# restic restore exits 1 when it cannot apply a SELinux label recorded in the
# snapshot. In the backup container /data is not a bind mount, so the tree
# carries that container's label, and the host-run scripts that write into
# $DATA_DIR/audit give their files a different one (unconfined_u vs system_u);
# rootless podman cannot set security.selinux at all. The file itself restores
# fine -- only the label is left alone -- but restic still exits non-zero, which
# would abort an in-place restore before the wallet's chown. Both restore calls
# therefore pass --exclude-xattr security.selinux, which removes the error at its
# source: the same files keep the label they already have, which is what happens
# when the setxattr fails anyway.
#
# What follows is the safety net for that class, not the primary fix. It counts
# the label errors instead of assuming a number, because which files mismatch
# depends on what a host script rewrote since the snapshot: this was written
# against one error on /data, and the 2026-11-01 drill produced two (/data and
# /data/audit/ids.status, which ids.sh had rewritten). It also does not pin the
# path -- a restore narrowed to a subfolder reports e.g. /restore/ids.status, and
# a path anchor is exactly the brittleness that broke the first version. The
# cause is what must be SELinux-only, not the path.
restore_acceptable() { # log rc
    local log="$1" rc="$2" seen benign sum fatals
    [ "$rc" -eq 0 ] && return 0
    # Every error restic reported (it counts these in the summary below)...
    seen=$(grep -cE '^ignoring error for ' "$log" 2>/dev/null || true)
    # ...is one of them...
    benign=$(grep -cE '^ignoring error for [^:]*: xattr\.LSet .* security\.selinux: permission denied$' "$log" 2>/dev/null || true)
    # ...restic's own summary agrees on the count...
    sum=$(sed -nE 's/^Fatal: There (was|were) ([0-9]+) errors?$/\2/p' "$log" | head -n1)
    # ...and the only Fatal line is that summary.
    fatals=$(grep -cE '^Fatal:' "$log" 2>/dev/null || true)
    [ "${seen:-0}" -gt 0 ] && [ "${seen:-0}" -eq "${benign:-0}" ] \
        && [ "${sum:-x}" = "${seen}" ] && [ "${fatals:-0}" -eq 1 ] || return 1
    warn "ignored ${seen} SELinux label error(s) (rootless podman cannot set security.selinux)"
    return 0
}

# A restic command that failed because another run holds the repository lock is a
# scheduling collision, not a broken backup: record a skip (leaving the last
# success in place) and stop. `check` and `forget --prune` take exclusive locks,
# and both timers are Persistent, so a post-downtime catch-up can overlap.
verify_skip_if_locked() { # log
    grep -qiE 'already locked|unable to create lock' "$1" 2>/dev/null || return 1
    write_verify_status skip "another restic run holds the repository lock" "${snap_id:-}" "" "" "${subset:-}"
    log "skipping the drill: another restic run holds the repository lock"
    return 0
}

# One slice of the repository's pack data per run, cycling 1..parts, so a
# repository too large for a full `check --read-data` every week is still read
# completely over a few runs. The counter is regenerable state, like the status
# file, and lives beside it.
next_subset() { # parts -> n (and advance the counter)
    local parts="$1" n=1
    [ -f "$VERIFY_SUBSET_FILE" ] && n=$(head -n1 "$VERIFY_SUBSET_FILE" 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "$parts" ]; then n=1; fi
    printf '%s' "$n"
    printf '%s\n' "$(( n % parts + 1 ))" > "$VERIFY_SUBSET_FILE" 2>/dev/null || true
}

# Replay the restored pg_dumpall into a throwaway postgres: the one thing a
# file-level restore cannot prove. Only on request (--with-db): it puts the
# postgres image in the drill's path, and the weekly run must stay deterministic.
# The database name is not hardcoded -- whatever the dump creates is discovered
# afterwards and must hold at least one table.
verify_replay_dump() { # restored data root
    local root="$1" dump="$1/postgres-dump/all.sql"
    local image="${POSTGRES_IMAGE:-docker.io/library/postgres:18-alpine}"
    local name="stack-restore-drill" deadline db tables total=0
    [ -s "$dump" ] || die "--with-db: the snapshot holds no postgres-dump/all.sql"
    VERIFY_DB_CONTAINER="$name"
    podman rm -f "$name" >/dev/null 2>&1 || true
    log "replaying all.sql into a throwaway $image"
    podman run -d --name "$name" -e POSTGRES_PASSWORD=drill "$image" >/dev/null \
        || die "--with-db: could not start the drill postgres"
    deadline=$(( $(date +%s) + 120 ))
    until podman exec "$name" pg_isready -U postgres >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            die "--with-db: postgres did not come up within 120s"
        fi
        sleep 2
    done
    # Deliberately not ON_ERROR_STOP: the dump carries the role, and psql always
    # reports the already-exists / drop-while-connected errors on a fresh
    # cluster. The table count below is the assertion that matters.
    podman exec -i "$name" psql -q -U postgres -d postgres < "$dump" >/dev/null 2>&1 || true
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        tables=$(podman exec "$name" psql -At -U postgres -d "$db" -c \
            "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" \
            2>/dev/null || echo 0)
        case "$tables" in ''|*[!0-9]*) tables=0 ;; esac
        total=$(( total + tables ))
        log "replayed $db: $tables table(s)"
    done <<< "$(podman exec "$name" psql -At -U postgres -d postgres \
        -c "select datname from pg_database where not datistemplate and datname <> 'postgres'")"
    [ "$total" -gt 0 ] || die "--with-db: the dump replayed but produced no tables"
    log "database replay passed: $total table(s)"
}

# Replay the restored kuma dump into a throwaway MariaDB started from the
# uptime-kuma image: the same server version that wrote it, so no second image to
# pull, and the only proof that matters -- the SQL imports and the kuma schema is
# there. Manual (--with-db) for the same reason as the postgres replay.
verify_replay_kuma_dump() { # restored data root
    local root="$1" dump="$1/uptime-kuma-dump/kuma.sql" image out tables
    image=$(kuma_image)
    [ -s "$dump" ] || die "--with-db: the snapshot holds no uptime-kuma-dump/kuma.sql"
    if ! podman image exists "$image" 2>/dev/null; then
        warn "--with-db: $image is not present; skipped the kuma replay"
        return 0
    fi
    log "replaying kuma.sql into a throwaway $image"
    if ! out=$(podman run --rm --pull=never --network none \
        -v "$root/uptime-kuma-dump:/dump:ro,z" \
        --entrypoint /bin/sh "$image" -c '
set -e
d=$(mktemp -d)
mariadb-install-db --user=root --datadir="$d" --auth-root-authentication-method=normal >/dev/null 2>&1
mariadbd --user=root --datadir="$d" --socket=/tmp/m.sock --skip-networking --pid-file=/tmp/m.pid >/dev/null 2>&1 &
i=0
until mariadb --socket=/tmp/m.sock -u root -e "select 1" >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -lt 60 ] || { echo "mariadbd did not come up" >&2; exit 1; }
    sleep 2
done
mariadb --socket=/tmp/m.sock -u root < /dump/kuma.sql
n=$(mariadb --socket=/tmp/m.sock -u root -N -B -e "select count(*) from information_schema.tables where table_schema=\"kuma\"")
echo "KUMA_TABLES=$n"
' 2>&1); then
        printf '%s\n' "$out"
        die "--with-db: the kuma dump did not import"
    fi
    tables=$(printf '%s\n' "$out" | sed -n 's/.*KUMA_TABLES=\([0-9][0-9]*\).*/\1/p' | tail -n1)
    case "$tables" in ''|*[!0-9]*) tables=0 ;; esac
    [ "$tables" -gt 0 ] || die "--with-db: the kuma dump replayed but produced no tables"
    log "kuma replay passed: $tables table(s)"
}

# The dumps are the only part of the set whose CONTENT can be wrong while every
# file is present -- and presence is all the marker loop proves. Each format gets
# the cheapest check that can actually tell:
#   * kuma      header + completion trailer; a dump killed mid-write is still a
#               valid SQL prefix, so the trailer is the proof it finished
#   * npm       PRAGMA quick_check on the restored copy (SQLite has no trailer),
#               read through the NPM image; soft-skipped if that image is gone
#   * freshness every dump's mtime sits inside the snapshot's own run. restic
#               preserves mtimes, so a dump job that has been failing for months
#               while restic kept copying the last good file cannot pass -- the
#               exact hole "the marker exists" leaves open.
# --with-db is the expensive proof that the SQL imports at all.
verify_dump_contents() { # restored data root
    local root="$1" dump image snap_epoch dump_epoch age_h
    local max_h="${VERIFY_DUMP_MAX_AGE_H:-12}"

    dump="$root/uptime-kuma-dump/kuma.sql"
    if [ -s "$dump" ]; then
        if ! grep -q '^-- MariaDB dump' "$dump"; then
            write_verify_status fail "uptime-kuma-dump/kuma.sql has no mariadb-dump header" "$snap_id" "$files" "$total_bytes" "$subset"
            die "uptime-kuma-dump/kuma.sql has no mariadb-dump header"
        fi
        if ! grep -q '^-- Dump completed' "$dump"; then
            write_verify_status fail "uptime-kuma-dump/kuma.sql is truncated (no completion trailer)" "$snap_id" "$files" "$total_bytes" "$subset"
            die "uptime-kuma-dump/kuma.sql is truncated: the dump did not finish"
        fi
    fi

    dump="$root/npm-dump/database.sqlite"
    if [ -s "$dump" ]; then
        image=$(npm_image)
        if ! podman image exists "$image" 2>/dev/null; then
            warn "npm-dump/database.sqlite integrity not checked: $image is not present"
        elif ! podman run --rm --pull=never --network none --user 0 \
            --entrypoint /usr/bin/node -v "$root/npm-dump:/d:ro,z" "$image" -e '
const Database = require("/app/node_modules/better-sqlite3");
const db = new Database("/d/database.sqlite", { readonly: true, fileMustExist: true });
const rows = db.pragma("quick_check");
db.close();
const verdict = Array.isArray(rows) && rows[0] ? rows[0].quick_check : "";
if (verdict !== "ok") { console.error("quick_check: " + JSON.stringify(rows)); process.exit(1); }
' >/dev/null 2>&1; then
            write_verify_status fail "npm-dump/database.sqlite failed SQLite quick_check" "$snap_id" "$files" "$total_bytes" "$subset"
            die "npm-dump/database.sqlite failed SQLite quick_check: the copy is damaged"
        fi
    fi

    if [ -n "${snap_time:-}" ] && command -v jq >/dev/null 2>&1; then
        snap_epoch=$(date -d "$snap_time" +%s 2>/dev/null || true)
        case "$snap_epoch" in ''|*[!0-9]*) snap_epoch="" ;; esac
        if [ -n "$snap_epoch" ]; then
            for dump in "$root/postgres-dump/all.sql" \
                "$root/npm-dump/database.sqlite" \
                "$root/uptime-kuma-dump/kuma.sql"; do
                [ -s "$dump" ] || continue
                dump_epoch=$(stat -c %Y "$dump" 2>/dev/null || true)
                case "$dump_epoch" in ''|*[!0-9]*) continue ;; esac
                age_h=$(( (snap_epoch - dump_epoch) / 3600 ))
                if [ "$age_h" -gt "$max_h" ]; then
                    write_verify_status fail "${dump#"$root"/} is ${age_h}h older than the snapshot: the dump job was not refreshed for this run" "$snap_id" "$files" "$total_bytes" "$subset"
                    die "${dump#"$root"/} is ${age_h}h older than the snapshot (max ${max_h}h): the dump was not taken as part of this backup"
                fi
            done
        fi
    fi

    return 0
}

case "$cmd" in
    init)
        restic init
        log "initialised $RESTIC_REPOSITORY"
        ;;
    list|snapshots)
        # Any extra argument goes to restic, which is how scripts/monitor.sh
        # gets `list --json` for the backup-age check (one source of truth for
        # the repository, the password and the mounts).
        restic snapshots --tag stack "$@"
        ;;
    ls)
        # What is actually inside a snapshot: the check that a run really did
        # hold the database dump and not just the wallet.
        restic ls "$snapshot"
        ;;
    check)
        restic check
        ;;
    verify)
        mkdir -p "$DATA_DIR/audit"
        # The nightly job's restic lock and a hand run are the same resource. A
        # drill that cannot get the lock in half an hour is recorded as skipped
        # (with the last success carried forward) rather than as a broken backup.
        exec 9>"$VERIFY_LOCK"
        if command -v flock >/dev/null 2>&1 && ! flock -w 1800 9; then
            write_verify_status skip "another backup/restore run holds $VERIFY_LOCK" "$snapshot"
            die "timed out waiting for $VERIFY_LOCK"
        fi
        trap verify_cleanup EXIT

        # Resolve `latest` so the report names the snapshot that was proven, and
        # keep its time: the dumps inside it must come from that run, not from
        # months earlier (see verify_dump_contents).
        snap_id="$snapshot"
        snap_time=""
        if command -v jq >/dev/null 2>&1; then
            sjson=$(restic snapshots --latest 1 --json "$snapshot" 2>/dev/null || true)
            snap_id=$(printf '%s' "$sjson" | jq -r '.[0].short_id // empty' 2>/dev/null || true)
            snap_time=$(printf '%s' "$sjson" | jq -r '.[0].time // empty' 2>/dev/null || true)
            snap_id="${snap_id:-$snapshot}"
        fi

        subset=""
        if [ "$VERIFY_CHECK" = 1 ]; then
            subset="$(next_subset "$VERIFY_SUBSET_PARTS")/$VERIFY_SUBSET_PARTS"
            log "checking repository data (subset $subset)"
            clog=$(mktemp)
            crc=0
            restic check --read-data-subset="$subset" >"$clog" 2>&1 || crc=$?
            cat "$clog"
            if [ "$crc" -ne 0 ]; then
                # check takes an exclusive lock. A nightly run that was missed
                # and caught up (Persistent=true) can still be holding it; that is
                # a scheduling collision, not a broken repository.
                if verify_skip_if_locked "$clog"; then
                    rm -f "$clog"
                    exit 0
                fi
                rm -f "$clog"
                write_verify_status fail "restic check failed (subset $subset): the repository holds unreadable data" "$snap_id" "" "" "$subset"
                die "restic check failed: the repository holds unreadable data (see above)"
            fi
            rm -f "$clog"
        fi

        # Size the restore before writing a byte: a drill that fills the data
        # disk would be a worse outage than the one it is looking for.
        slog=$(mktemp)
        src=0
        restic stats --mode restore-size --json "$snap_id" >"$slog" 2>&1 || src=$?
        if [ "$src" -ne 0 ]; then
            if verify_skip_if_locked "$slog"; then rm -f "$slog"; exit 0; fi
            cat "$slog"
            rm -f "$slog"
            write_verify_status fail "restic stats failed" "$snap_id" "" "" "$subset"
            die "restic stats failed"
        fi
        stats=$(cat "$slog")
        rm -f "$slog"
        size=$(printf '%s' "$stats" | sed -n 's/.*"total_size":\([0-9][0-9]*\).*/\1/p')
        size="${size:-0}"
        if [ "$size" -gt $(( VERIFY_MAX_MB * 1024 * 1024 )) ]; then
            write_verify_status skip "restore is $(( size / 1048576 )) MiB, above BACKUP_VERIFY_MAX_MB=$VERIFY_MAX_MB" "$snap_id" "" "$size" "$subset"
            log "skipping the restore: $(( size / 1048576 )) MiB exceeds BACKUP_VERIFY_MAX_MB=$VERIFY_MAX_MB"
            log "raise BACKUP_VERIFY_MAX_MB to drill a set that large, or run it by hand with --keep"
            exit 0
        fi
        mkdir -p "$VERIFY_TARGET"
        avail=$(df -Pk "$VERIFY_TARGET" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')
        need=$(( size + size / 2 ))
        if [ -n "${avail:-}" ] && [ "$avail" -lt "$need" ]; then
            write_verify_status skip "not enough space at $VERIFY_TARGET: need $(( need / 1048576 )) MiB, have $(( avail / 1048576 )) MiB free" "$snap_id" "" "$size" "$subset"
            log "skipping the restore: $(( need / 1048576 )) MiB needed at $VERIFY_TARGET, $(( avail / 1048576 )) MiB free"
            exit 0
        fi

        remove_verify_target
        mkdir -p "$VERIFY_TARGET"
        log "restoring $snap_id ($(( size / 1048576 )) MiB) into $VERIFY_TARGET"
        # The snapshot stores absolute /data/<name> paths, so mounting the
        # scratch dir at /restore lands them under <target>/data/<name>. The live
        # data dirs are not mounted: the drill cannot write to them.
        rlog=$(mktemp)
        rrc=0
        podman run "${common[@]}" -v "$VERIFY_TARGET:/restore:z" \
            "$RESTIC_IMAGE" restore "$snap_id" --exclude-xattr security.selinux \
            --target /restore --verify >"$rlog" 2>&1 || rrc=$?
        cat "$rlog"
        if [ "$rrc" -ne 0 ] && verify_skip_if_locked "$rlog"; then
            rm -f "$rlog"
            exit 0
        fi
        if ! restore_acceptable "$rlog" "$rrc"; then
            rm -f "$rlog"
            write_verify_status fail "restore failed (restic restore --verify)" "$snap_id" "" "$size" "$subset"
            die "restore failed"
        fi
        rm -f "$rlog"

        root="$VERIFY_TARGET/data"
        files=0
        total_bytes=0
        for vp in "${BACKUP_PATHS[@]}"; do
            if [ ! -d "$root/$vp" ]; then
                write_verify_status fail "the snapshot holds no /data/$vp" "$snap_id" "$files" "$total_bytes" "$subset"
                die "the restored snapshot holds no /data/$vp"
            fi
            vfiles=$(tree_count "$root/$vp")
            vbytes=$(tree_size "$root/$vp")
            if [ "$vfiles" -eq 0 ] || [ "$vbytes" -eq 0 ]; then
                write_verify_status fail "/data/$vp came back empty" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$vp came back empty: the snapshot does not hold it"
            fi
            files=$(( files + vfiles ))
            total_bytes=$(( total_bytes + vbytes ))
        done

        # The markers: the files whose absence makes the directory worthless.
        for marker in ${BACKUP_VERIFY_PATHS[@]+"${BACKUP_VERIFY_PATHS[@]}"}; do
            if [ ! -e "$root/$marker" ]; then
                write_verify_status fail "/data/$marker is missing from the snapshot" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$marker is missing from the snapshot"
            fi
            if [ -d "$root/$marker" ] && [ "$(tree_count "$root/$marker")" -eq 0 ]; then
                write_verify_status fail "/data/$marker is an empty directory in the snapshot" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$marker is an empty directory in the snapshot"
            fi
            if [ -f "$root/$marker" ] && [ ! -s "$root/$marker" ]; then
                write_verify_status fail "/data/$marker is empty in the snapshot" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$marker is empty in the snapshot"
            fi
        done

        # A dump killed mid-write is still a valid SQL prefix, so its completion
        # trailer is the cheap proof it finished; --with-db is the expensive one.
        dump="$root/postgres-dump/all.sql"
        if [ -s "$dump" ]; then
            if ! awk 'NR <= 5 && /^-- PostgreSQL database cluster dump$/ { found = 1 } END { exit(found ? 0 : 1) }' "$dump"; then
                write_verify_status fail "postgres-dump/all.sql has no pg_dumpall header" "$snap_id" "$files" "$total_bytes" "$subset"
                die "postgres-dump/all.sql has no pg_dumpall header"
            fi
            if ! grep -q '^-- PostgreSQL database cluster dump complete$' "$dump"; then
                write_verify_status fail "postgres-dump/all.sql is truncated (no completion trailer)" "$snap_id" "$files" "$total_bytes" "$subset"
                die "postgres-dump/all.sql is truncated: the dump did not finish"
            fi
        fi

        # The other two dumps, plus the freshness of all three: presence is not
        # consistency, and a stale dump passes every marker.
        verify_dump_contents "$root"

        if [ "$VERIFY_DB" = 1 ]; then
            verify_replay_dump "$root"
            verify_replay_kuma_dump "$root"
        fi

        write_verify_status ok "" "$snap_id" "$files" "$total_bytes" "$subset"
        log "restore drill passed: $files file(s), $(( total_bytes / 1048576 )) MiB restored from $snap_id"
        ;;
    forget)
        restic forget --tag stack "${RETENTION[@]}" --prune
        ;;
    unlock)
        restic unlock
        ;;
    version)
        restic version
        ;;
    backup)
        refresh_dumps
        log "backing up ${backup_paths[*]} to $RESTIC_REPOSITORY"
        podman run "${common[@]}" "${data_ro[@]}" \
            --entrypoint /bin/sh "$RESTIC_IMAGE" -c "$job_script"
        log "backup complete"
        ;;
    restore)
        if [ "${ASSUME_YES:-0}" != 1 ]; then
            if [ -t 0 ]; then
                set_list=$(IFS=,; printf '%s' "${BACKUP_PATHS[*]}")
                printf 'Restore snapshot "%s" over %s/{%s}?\n' \
                    "$snapshot" "$DATA_DIR" "$set_list"
                read -r -p "Type 'yes' to continue: " answer || answer=""
                [ "$answer" = yes ] || die "aborted"
            else
                die "refusing to restore without a TTY; pass -y to proceed"
            fi
        fi
        log "restoring $snapshot into $DATA_DIR (in place)"
        # The snapshot stores absolute /data/... paths, so target / writes them
        # back onto the mounts. The container runs as root, so restic restores
        # the numeric owners: the wallet dir comes back as uid 1000 (= the
        # image uid), the rest as root (= the host user).
        rlog=$(mktemp)
        rrc=0
        podman run "${common[@]}" "${data_rw[@]}" \
            "$RESTIC_IMAGE" restore "$snapshot" --exclude-xattr security.selinux \
            --target / >"$rlog" 2>&1 || rrc=$?
        cat "$rlog"
        # Not a failure: the SELinux label is excluded above because rootless
        # podman cannot set it, and this must not return before the chown below
        # -- that chown is what makes bitcoind's image-uid datadir readable, and
        # a "restore failed" here would leave the operator with a complete tree
        # and a daemon that cannot open it.
        if ! restore_acceptable "$rlog" "$rrc"; then
            rm -f "$rlog"
            die "restore failed (see above)"
        fi
        rm -f "$rlog"
        # Belt and braces: install.sh hands bitcoind's dir to the image uid too.
        podman unshare chown -R 1000:1000 "$DATA_DIR/bitcoin" 2>/dev/null \
            || warn "could not chown $DATA_DIR/bitcoin to the image uid"
        log "restore complete; start the stack with ./deploy.sh"
        # The two live databases are not in the snapshot as files: their dumps
        # are. Say so here, where an operator finishing a restore is looking.
        log "after ./deploy.sh: copy $DATA_DIR/npm-dump/database.sqlite over $DATA_DIR/npm/data/database.sqlite (NPM stopped), and import $DATA_DIR/uptime-kuma-dump/kuma.sql into kuma's MariaDB -- see README 'Disaster recovery'"
        ;;
esac
