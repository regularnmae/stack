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
#   scripts/backup.sh verify-db [opts] # restore just the postgres dump and replay it
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
#   --with-db         additionally replay the two SQL dumps -- postgres-dump/all.sql
#                     into a throwaway postgres, uptime-kuma-dump/kuma.sql into a
#                     throwaway MariaDB -- and prove they produce tables. The
#                     SQLite copy is checked on every run instead (quick_check is
#                     cheap, and there is no server to replay it into); this is
#                     the manual, on-demand full drill. A replay
#                     that cannot run because its image is missing or unpullable
#                     is recorded as a skip (the file-level drill still passed):
#                     writing `ok` there would reset the last success and hide
#                     the fact that nothing was replayed.
#
# `verify-db` is the monthly database drill, run by deploy/backup-verify-db.timer:
# it restores ONLY the snapshot's postgres-dump directory (a few MiB, not the
# whole set), asserts the dump came from that snapshot's own run, and replays it
# into a throwaway postgres, asserting it produces tables. That is the one claim
# the weekly drill cannot make: the weekly proves restic mechanics and file
# presence, never that all.sql applies. Keeping this out of the weekly run is what
# lets that one stay deterministic -- no image pull in its path -- so the pull
# lives here instead, monthly. Its verdict goes to
# $DATA_DIR/audit/backup-verify-db.status, a separate file: one drill's failure or
# skip must not mask the other's age. Options:
#   --snapshot <id>   the snapshot to replay (default latest)
#   --keep            leave the restored dump tree in place to inspect it
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
# The keep policy, from the same declaration install.sh renders into
# deploy/backup.container. Not defaulted: `restic forget --prune` with no keep
# rule deletes every snapshot, which is the one way this array can hurt.
if [ "${BACKUP_RETENTION+x}" != x ] || [ "${#BACKUP_RETENTION[@]}" -eq 0 ]; then
    die "stack.conf must define BACKUP_RETENTION (the keep policy)"
fi

RESTIC_IMAGE="${RESTIC_IMAGE:-docker.io/restic/restic:0.19.1}"
STACK_BACKUP_DIR="${STACK_BACKUP_DIR:-$HOME/data-backup}"

command -v podman >/dev/null 2>&1 || die "podman is required"

cmd="${1:-backup}"
[ $# -gt 0 ] && shift

case "$cmd" in
    -h|--help) usage_header "$0"; exit 0 ;;
    backup|init|list|snapshots|ls|check|forget|restore|unlock|version|verify|verify-db) ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac

# restore and ls take a snapshot argument; verify takes a snapshot plus flags;
# verify-db takes the same two it understands; everything else takes none.
snapshot=""
VERIFY_CHECK=1
VERIFY_KEEP=0
VERIFY_WITH_DB=0
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
                --with-db)  VERIFY_WITH_DB=1 ;;
                *)          die "verify: unknown argument: $1 (try --help)" ;;
            esac
            shift
        done
        snapshot="${snapshot:-latest}"
        ;;
    verify-db)
        while [ $# -gt 0 ]; do
            case "$1" in
                --snapshot) [ $# -ge 2 ] || die "--snapshot needs an id"; snapshot="$2"; shift ;;
                --keep)     VERIFY_KEEP=1 ;;
                *)          die "verify-db: unknown argument: $1 (try --help)" ;;
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
# --log-driver=none: restic's output is the *caller's* -- a hand run prints it, the
# monitor captures `list --json`, verify captures the snapshot table -- and the
# driver only controls whether podman also journals a copy. Without it every sweep
# wrote the whole table into the journal for the log store to index.
common=(
    --rm
    --log-driver=none
    -v "$STACK_BACKUP_DIR:/repo:z"
    -v "$DATA_DIR/backup-cache:/cache:z"
    --env RESTIC_REPOSITORY --env RESTIC_PASSWORD --env RESTIC_CACHE_DIR
)
# The backup set, derived from BACKUP_PATHS in stack.conf -- the same declaration
# install.sh renders into backup.container's Volume= lines and Exec=. Nothing below
# repeats the list: a directory added there is mounted, backed up, created before a
# restore and named in the prompt automatically.
#
# The mount paths mirror $DATA_DIR (/data/<name>), which is what lets `restore
# --target /` land the contents back in the data dir. `:z` (shared) because
# lightningd, nginx-proxy-manager and tor mount some of these too.
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
# policy all come from stack.conf, so the two cannot drift.
job_script=$(
    printf 'set -e\n'
    printf 'restic snapshots >/dev/null 2>&1 || restic init\n'
    printf 'restic backup %s %s --host stack --tag stack\n' "${backup_paths[*]}" "$exclude_args"
    printf 'restic forget --tag stack %s --prune\n' "${BACKUP_RETENTION[*]}"
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
# The database drill (`verify-db`) has its own scratch root and its own record:
# the two drills must be able to disagree. Sharing the tree would let one run's
# cleanup delete the other's restore (both take the lock, so not concurrently --
# but --keep or a failed cleanup would), and sharing the status file would let a
# pass of one hide the age of the other.
VERIFY_DB_STATUS="$DATA_DIR/audit/backup-verify-db.status"
VERIFY_DB_TARGET="${BACKUP_VERIFY_DB_TARGET:-$DATA_DIR/backup-verify-db}"
VERIFY_DB_MIN_FREE_MB="${BACKUP_VERIFY_DB_MIN_FREE_MB:-512}"
REPLAY_CONTAINER=""
# Set by the replay helpers: the failure's detail, and (rc 2) the reason the
# image could not be obtained -- a registry outage is not a broken dump. The
# caller collects the ones that were skipped into replay_skips, because a drill
# that could not replay must record `skip`, never `ok` (ok_epoch is the age).
replay_detail=""
replay_skip_detail=""
replay_tables=""
replay_skips=""
# Set once this run records a verdict of its own; verify_cleanup's guard reads
# it so an exit with no verdict (set -e, TimeoutStartSec) cannot leave the
# previous `result=ok` in place and read healthy. Same discipline as
# VERIFY_DB_WROTE for the monthly drill.
VERIFY_WROTE=0

# The record scripts/monitor.sh alerts on (a failed oneshot unit is otherwise
# just a line in `systemctl --user status`). status_write owns the format --
# KEY=VALUE, atomic, ok_epoch carried forward on failure/skip -- and these two
# wrappers are what keep each drill's verdict in its own file.
write_verify_status() { # result detail [snapshot files bytes subset]
    local result="$1" detail="$2" snap="${3:-}" files="${4:-}" bytes="${5:-}" subset="${6:-}"
    status_write "$VERIFY_STATUS" \
        "# written by scripts/backup.sh verify (deploy/backup-verify.timer)" \
        "$result" "$detail" \
        "snapshot=$snap" "files=$files" "bytes=$bytes" "subset=$subset"
}

# Every verdict the weekly drill records goes through this, so the cleanup guard
# below knows one was written. It is the only path that sets the flag -- a
# `write_verify_status` that bypassed it would fake an unrecorded exit.
verify_status() { # result detail [snapshot files bytes subset]
    write_verify_status "$@"
    VERIFY_WROTE=1
}

write_verify_db_status() { # result detail [snapshot tables]
    local result="$1" detail="$2" snap="${3:-}" tables="${4:-}"
    status_write "$VERIFY_DB_STATUS" \
        "# written by scripts/backup.sh verify-db (deploy/backup-verify-db.timer)" \
        "$result" "$detail" \
        "snapshot=$snap" "tables=$tables"
}

# Resolve `latest` (or an id) to the short id the report names, plus its time,
# as "id<TAB>time" -- one read for both drills: the dump inside must come from
# that run, not from months earlier. Falls back to the literal ref without jq.
resolve_snapshot() { # ref -> "short-id<TAB>time"
    local ref="$1" json id="" time=""
    id="$ref"
    if command -v jq >/dev/null 2>&1; then
        json=$(restic snapshots --latest 1 --json "$ref" 2>/dev/null || true)
        id=$(printf '%s' "$json" | jq -r '.[0].short_id // empty' 2>/dev/null || true)
        time=$(printf '%s' "$json" | jq -r '.[0].time // empty' 2>/dev/null || true)
        id="${id:-$ref}"
    fi
    printf '%s\t%s' "$id" "$time"
}

# The scratch tree and the drill's throwaway postgres, removed on any exit path
# (a failure must not leave a 700 MiB copy of the wallet on the data disk).
verify_cleanup() {
    if [ -n "${REPLAY_CONTAINER:-}" ]; then
        podman rm -f "$REPLAY_CONTAINER" >/dev/null 2>&1 || true
    fi
    # The guard against a drill that dies before writing a verdict. `set -e` can
    # exit from anywhere; the timer's TimeoutStartSec is a SIGTERM and a hand run
    # a SIGINT, and bash runs no EXIT trap for either, so both signals are
    # trapped to reach this function too. A status file left at the previous
    # `result=ok` would make a broken weekly run read healthy, so an exit with no
    # verdict of our own records a failure.
    if [ "${VERIFY_WROTE:-0}" != 1 ]; then
        write_verify_status fail \
            "the drill exited without recording a verdict; see journalctl --user -u backup-verify.service"
        # A signal trap exits through the EXIT trap as well; the second call has
        # nothing left to record.
        VERIFY_WROTE=1
    fi
    case "${VERIFY_TARGET:-}" in
        ""|/) return 0 ;;
    esac
    if [ "${VERIFY_KEEP:-0}" = 1 ]; then
        log "kept the restored tree at $VERIFY_TARGET"
        return 0
    fi
    remove_restore_target "$VERIFY_TARGET"
}

# The db drill's cleanup, with one extra duty: it is also the guard against a
# drill that dies before writing a verdict. `set -e` can exit from anywhere, and
# a status file left at the previous `result=ok` would make a broken monthly run
# read healthy -- so an exit with no verdict of our own records a failure. The
# timer's TimeoutStartSec is a SIGTERM and a hand run a SIGINT, neither of which
# runs an EXIT trap, so both are trapped to this function too (which is what a
# hung drill deserves). A SIGKILL cannot be caught; the age check is the backstop.
verify_db_cleanup() {
    if [ -n "${REPLAY_CONTAINER:-}" ]; then
        podman rm -f "$REPLAY_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [ "${VERIFY_DB_WROTE:-0}" != 1 ]; then
        write_verify_db_status fail \
            "the drill exited without recording a verdict; see journalctl --user -u backup-verify-db.service"
        # A signal trap exits through the EXIT trap as well; the second call has
        # nothing left to record.
        VERIFY_DB_WROTE=1
    fi
    case "${VERIFY_DB_TARGET:-}" in
        ""|/) return 0 ;;
    esac
    if [ "${VERIFY_KEEP:-0}" = 1 ]; then
        log "kept the restored dump tree at $VERIFY_DB_TARGET"
        return 0
    fi
    remove_restore_target "$VERIFY_DB_TARGET"
}

# Every verdict the db drill records goes through this, so the cleanup guard
# above knows one was written. It is the only path that sets the flag -- a
# `write_verify_db_status` that bypassed it would fake an unrecorded exit.
db_status() { # result detail [snapshot tables]
    write_verify_db_status "$@"
    VERIFY_DB_WROTE=1
}

# restic restores the numeric owners, so the wallet comes back as the image uid
# (host 525287): a plain `rm -rf` as the host user cannot unlink inside those
# directories. `podman unshare` enters the user namespace where they are mapped,
# which is the same trick install.sh uses to chown the wallet. Fall back to rm
# when podman is unavailable.
remove_restore_target() { # path
    local target="$1"
    case "${target:-}" in
        ""|/) return 0 ;;
    esac
    if command -v podman >/dev/null 2>&1 && podman unshare rm -rf "$target" 2>/dev/null; then
        return 0
    fi
    rm -rf "$target" 2>/dev/null || warn "could not remove $target"
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
# snapshot: the tree carries the backup container's label, host-run scripts write
# $DATA_DIR/audit under a different one, and rootless podman cannot set
# security.selinux at all. The file restores fine, only the label is left alone,
# but the non-zero exit would abort an in-place restore before the wallet's chown.
# Both restore calls therefore pass --exclude-xattr security.selinux, which
# removes the error at its source.
#
# What follows is the safety net for that class, not the primary fix. It counts
# the label errors instead of assuming a number, because which files mismatch
# depends on what a host script rewrote since the snapshot, and it does not pin the
# path -- a restore narrowed to a subfolder reports a different one. The cause must
# be SELinux-only, not the path.
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
# scheduling collision, not a broken backup: the caller records a skip (leaving the
# last success in place) and stops. `check` and `forget --prune` take exclusive
# locks and every timer here is Persistent, so a post-downtime catch-up can
# overlap. A predicate rather than a writer: the two drills record skips in
# different files.
verify_skip_if_locked() { # log -> 0 if the failure was the repository lock
    grep -qiE 'already locked|unable to create lock' "$1" 2>/dev/null
}

# One slice of the repository's pack data per run, cycling 1..parts, so a
# repository too large for a full `check --read-data` every week is still read
# completely over a few runs. The counter is regenerable state, like the status
# file beside it.
next_subset() { # parts -> n (and advance the counter)
    local parts="$1" n=1
    [ -f "$VERIFY_SUBSET_FILE" ] && n=$(head -n1 "$VERIFY_SUBSET_FILE" 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) n=1 ;; esac
    if [ "$n" -lt 1 ] || [ "$n" -gt "$parts" ]; then n=1; fi
    printf '%s' "$n"
    printf '%s\n' "$(( n % parts + 1 ))" > "$VERIFY_SUBSET_FILE" 2>/dev/null || true
}

# Which postgres image to replay into: the one the stack is actually running, so
# a Renovate bump of deploy/postgres.container reaches the drill with no edit
# here and the replay uses the same server version that wrote the dump. Falls
# back to the pinned tag when the unit is down: this is a monthly drill, not a
# recovery tool, so it must not depend on the stack being up.
replay_image() {
    local running=""
    if command -v podman >/dev/null 2>&1; then
        running=$(podman inspect --format '{{.ImageName}}' postgres 2>/dev/null || true)
    fi
    printf '%s' "${running:-${POSTGRES_IMAGE:-docker.io/library/postgres:18-alpine}}"
}

# Replay the restored pg_dumpall into a throwaway postgres: the one thing a
# file-level restore cannot prove. Shared by `verify --with-db` (manual) and
# `verify-db` (monthly). The database name is not hardcoded -- whatever the dump
# creates is discovered afterwards and must hold at least one table.
#
# Returns 0 on success, 1 on a failed replay ($replay_detail), 2 when the image
# could not be obtained ($replay_skip_detail): a registry that will not answer says
# nothing about the dump, so the caller records a skip and the status file's age
# decides when it has gone on too long. The pull is explicit, not implicit in
# `podman run`, precisely so the two can be told apart.
verify_replay_dump() { # restored data root
    local root="$1" dump="$1/postgres-dump/all.sql"
    local image name deadline db tables total=0 out
    [ -s "$dump" ] || { replay_detail="the snapshot holds no postgres-dump/all.sql"; return 1; }
    image=$(replay_image)
    if ! podman image exists "$image" 2>/dev/null; then
        log "pulling $image for the replay"
        if ! out=$(podman pull "$image" 2>&1); then
            replay_skip_detail="could not pull $image: $(printf '%s\n' "$out" | tail -n1)"
            return 2
        fi
    fi
    name="stack-restore-drill"
    REPLAY_CONTAINER="$name"
    podman rm -f "$name" >/dev/null 2>&1 || true
    log "replaying all.sql into a throwaway $image"
    # --network none: the drill's server has nothing to talk to, so a throwaway
    # database should not appear on any network -- not even podman's default.
    # --pull=missing completes the explicit pull above without offering a second
    # registry trip.
    podman run -d --name "$name" --pull=missing --network none \
        -e POSTGRES_PASSWORD=drill "$image" >/dev/null \
        || { replay_detail="could not start the drill postgres from $image"; return 1; }
    deadline=$(( $(date +%s) + 120 ))
    until podman exec "$name" pg_isready -U postgres >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            replay_detail="the drill postgres did not come up within 120s"
            return 1
        fi
        sleep 2
    done
    # Deliberately not ON_ERROR_STOP: the dump carries the role, and psql always
    # reports the already-exists / drop-while-connected errors on a fresh cluster.
    # The table count below is the assertion -- and because psql would replay a
    # truncated dump's prefix just as happily, the trailer is checked first.
    podman exec -i "$name" psql -q -U postgres -d postgres < "$dump" >/dev/null 2>&1 || true
    # Every non-template database, INCLUDING `postgres`: the app database is
    # normally its own, but a dump whose only data lives in `postgres` would
    # otherwise replay into a cluster this loop cannot see and be reported empty.
    # The stock `postgres` database has no user tables, so counting it cannot
    # manufacture a pass.
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        tables=$(podman exec "$name" psql -At -U postgres -d "$db" -c \
            "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" \
            2>/dev/null || echo 0)
        case "$tables" in ''|*[!0-9]*) tables=0 ;; esac
        total=$(( total + tables ))
        log "replayed $db: $tables table(s)"
    done <<< "$(podman exec "$name" psql -At -U postgres -d postgres \
        -c "select datname from pg_database where not datistemplate")"
    [ "$total" -gt 0 ] || { replay_detail="the dump replayed but produced no tables"; return 1; }
    replay_tables="$total"
    log "database replay passed: $total table(s)"
    return 0
}

# Replay the restored kuma dump into a throwaway MariaDB started from the
# uptime-kuma image: the same server version that wrote it, so no second image, and
# the only proof that matters -- the SQL imports and the kuma schema is there.
# Reached only from `verify --with-db`; same return codes as verify_replay_dump, and
# it is never pulled: the weekly run must not acquire a registry dependency.
verify_replay_kuma_dump() { # restored data root
    local root="$1" dump="$1/uptime-kuma-dump/kuma.sql" image out tables
    image=$(kuma_image)
    [ -s "$dump" ] || { replay_detail="the snapshot holds no uptime-kuma-dump/kuma.sql"; return 1; }
    if ! podman image exists "$image" 2>/dev/null; then
        replay_skip_detail="$image is not present, and the kuma replay never pulls"
        return 2
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
        replay_detail="the kuma dump did not import: $(printf '%s\n' "$out" | tail -n1)"
        return 1
    fi
    tables=$(printf '%s\n' "$out" | sed -n 's/.*KUMA_TABLES=\([0-9][0-9]*\).*/\1/p' | tail -n1)
    case "$tables" in ''|*[!0-9]*) tables=0 ;; esac
    [ "$tables" -gt 0 ] || { replay_detail="the kuma dump replayed but produced no tables"; return 1; }
    log "kuma replay passed: $tables table(s)"
    return 0
}

# Every dump's mtime must sit inside the snapshot's own run: restic preserves
# mtimes, so a dump job that has been failing for months while restic kept
# copying the last good file would otherwise pass every marker and every trailer
# check. Cheap, and the only check that notices that class of failure.
#
# Returns non-zero with the reason in $dump_stale_detail, so either drill can
# record it in its own file.
assert_dump_fresh() { # root path...
    local root="$1"; shift
    local dump dump_epoch age_h snap_epoch max_h="${VERIFY_DUMP_MAX_AGE_H:-12}"
    dump_stale_detail=""
    [ -n "${snap_time:-}" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    snap_epoch=$(date -d "$snap_time" +%s 2>/dev/null || true)
    case "$snap_epoch" in ''|*[!0-9]*) return 0 ;; esac
    for dump in "$@"; do
        [ -s "$root/$dump" ] || continue
        dump_epoch=$(stat -c %Y "$root/$dump" 2>/dev/null || true)
        case "$dump_epoch" in ''|*[!0-9]*) continue ;; esac
        age_h=$(( (snap_epoch - dump_epoch) / 3600 ))
        if [ "$age_h" -gt "$max_h" ]; then
            dump_stale_detail="$dump is ${age_h}h older than the snapshot (max ${max_h}h): the dump was not taken as part of this backup"
            return 1
        fi
    done
    return 0
}

# A dump killed mid-write is still a valid SQL prefix, and psql without
# ON_ERROR_STOP replays that prefix just as happily and leaves a cluster that
# looks non-empty -- so the header and completion trailer are checked before any
# replay. An ABSENT dump is deliberately not this helper's business: presence is
# the markers' job (weekly) or the caller's, so a missing file passes here.
assert_pg_dump_shaped() { # postgres-dump/all.sql -> 0 shaped or absent, 1 bad
    local dump="$1"
    pg_dump_bad_detail=""
    [ -s "$dump" ] || return 0
    if ! awk 'NR <= 5 && /^-- PostgreSQL database cluster dump$/ { found = 1 } END { exit(found ? 0 : 1) }' "$dump"; then
        pg_dump_bad_detail="postgres-dump/all.sql has no pg_dumpall header"
        return 1
    fi
    if ! grep -q '^-- PostgreSQL database cluster dump complete$' "$dump"; then
        pg_dump_bad_detail="postgres-dump/all.sql is truncated: the dump did not finish"
        return 1
    fi
    return 0
}

# The dumps are the only part of the set whose CONTENT can be wrong while every
# file is present -- and presence is all the marker loop proves. Each format gets
# the cheapest check that can tell:
#   * kuma      header + completion trailer: a dump killed mid-write is still a
#               valid SQL prefix, so the trailer proves it finished
#   * npm       PRAGMA quick_check on the restored copy (SQLite has no trailer),
#               read through the NPM image; soft-skipped if that image is gone
#   * freshness every dump's mtime sits inside the snapshot's own run: restic
#               preserves mtimes, so a dump job failing for months while restic
#               copied the last good file cannot pass.
# The replay (`verify-db` monthly, `verify --with-db` by hand) is the expensive
# proof that the SQL imports at all.
verify_dump_contents() { # restored data root
    local root="$1" dump image

    dump="$root/uptime-kuma-dump/kuma.sql"
    if [ -s "$dump" ]; then
        if ! grep -q '^-- MariaDB dump' "$dump"; then
            verify_status fail "uptime-kuma-dump/kuma.sql has no mariadb-dump header" "$snap_id" "$files" "$total_bytes" "$subset"
            die "uptime-kuma-dump/kuma.sql has no mariadb-dump header"
        fi
        if ! grep -q '^-- Dump completed' "$dump"; then
            verify_status fail "uptime-kuma-dump/kuma.sql is truncated (no completion trailer)" "$snap_id" "$files" "$total_bytes" "$subset"
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
            verify_status fail "npm-dump/database.sqlite failed SQLite quick_check" "$snap_id" "$files" "$total_bytes" "$subset"
            die "npm-dump/database.sqlite failed SQLite quick_check: the copy is damaged"
        fi
    fi

    if ! assert_dump_fresh "$root" postgres-dump/all.sql npm-dump/database.sqlite uptime-kuma-dump/kuma.sql; then
        verify_status fail "$dump_stale_detail" "$snap_id" "$files" "$total_bytes" "$subset"
        die "$dump_stale_detail"
    fi

    return 0
}

# The monthly database drill (`verify-db`). The claim it makes is the one the
# weekly run cannot: that the snapshot's postgres-dump/all.sql REPLAYS into a
# cluster. Everything except the restore is shared with the weekly run; what
# differs is deliberate:
#   * only /data/postgres-dump is restored (a few MiB), so it has no
#     BACKUP_VERIFY_MAX_MB gate -- inheriting that would stop the proof at exactly
#     the set size where a restore matters most;
#   * its own scratch root and its own status file, so one drill's failure or skip
#     cannot mask the other's age;
#   * a pull is allowed here and a failed pull is a skip, not a failure: a registry
#     outage is not evidence about the dump. The status file's age check is what
#     turns a run of skips into an alert.
run_verify_db() {
    local snap_id snap_time root avail need rlog rrc rres
    mkdir -p "$DATA_DIR/audit"
    exec 9>"$VERIFY_LOCK"
    if command -v flock >/dev/null 2>&1 && ! flock -w 1800 9; then
        db_status skip "another backup/restore run holds $VERIFY_LOCK" "$snapshot"
        die "timed out waiting for $VERIFY_LOCK"
    fi
    trap verify_db_cleanup EXIT
    # TimeoutStartSec (SIGTERM) and a hand Ctrl-C (SIGINT) run no EXIT trap:
    # without these, a drill killed mid-replay leaves the previous `result=ok`
    # behind and reads healthy.
    trap 'verify_db_cleanup; exit 143' TERM
    trap 'verify_db_cleanup; exit 130' INT

    # Resolve `latest` so the report names the snapshot that was proven, and keep
    # its time: the dump must come from that run, not from months earlier.
    IFS=$'\t' read -r snap_id snap_time <<< "$(resolve_snapshot "$snapshot")"

    # The dump is small, but the disk is shared with two chains: never start a
    # restore that could fill it.
    mkdir -p "$VERIFY_DB_TARGET"
    avail=$(df -Pk "$VERIFY_DB_TARGET" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')
    need=$(( VERIFY_DB_MIN_FREE_MB * 1024 * 1024 ))
    if [ -n "${avail:-}" ] && [ "$avail" -lt "$need" ]; then
        db_status skip "not enough space at $VERIFY_DB_TARGET: need $(( need / 1048576 )) MiB, have $(( avail / 1048576 )) MiB free" "$snap_id"
        log "skipping the replay: $(( need / 1048576 )) MiB needed at $VERIFY_DB_TARGET, $(( avail / 1048576 )) MiB free"
        exit 0
    fi

    remove_restore_target "$VERIFY_DB_TARGET"
    mkdir -p "$VERIFY_DB_TARGET"
    log "restoring $snap_id/postgres-dump into $VERIFY_DB_TARGET"
    rlog=$(mktemp)
    rrc=0
    podman run "${common[@]}" -v "$VERIFY_DB_TARGET:/restore:z" \
        "$RESTIC_IMAGE" restore "$snap_id" --include /data/postgres-dump \
        --exclude-xattr security.selinux --target /restore --verify >"$rlog" 2>&1 || rrc=$?
    cat "$rlog"
    if [ "$rrc" -ne 0 ] && verify_skip_if_locked "$rlog"; then
        rm -f "$rlog"
        db_status skip "another restic run holds the repository lock" "$snap_id"
        log "skipping the replay: another restic run holds the repository lock"
        exit 0
    fi
    if ! restore_acceptable "$rlog" "$rrc"; then
        rm -f "$rlog"
        db_status fail "restore of /data/postgres-dump failed (restic restore --verify)" "$snap_id"
        die "restore of /data/postgres-dump failed"
    fi
    rm -f "$rlog"

    # Presence, shape and freshness, in that order: a truncated dump is a valid
    # SQL prefix that psql will replay into a cluster that looks non-empty, and a
    # dump from months ago replays perfectly -- both would otherwise pass.
    root="$VERIFY_DB_TARGET/data"
    if [ ! -s "$root/postgres-dump/all.sql" ]; then
        db_status fail "the snapshot holds no postgres-dump/all.sql" "$snap_id"
        die "the snapshot holds no postgres-dump/all.sql"
    fi
    if ! assert_pg_dump_shaped "$root/postgres-dump/all.sql"; then
        db_status fail "$pg_dump_bad_detail" "$snap_id"
        die "$pg_dump_bad_detail"
    fi
    if ! assert_dump_fresh "$root" postgres-dump/all.sql; then
        db_status fail "$dump_stale_detail" "$snap_id"
        die "$dump_stale_detail"
    fi

    rres=0
    verify_replay_dump "$root" || rres=$?
    case "$rres" in
        0) ;;
        2) db_status skip "$replay_skip_detail" "$snap_id"
           log "skipping the replay: $replay_skip_detail"
           exit 0 ;;
        *) db_status fail "$replay_detail" "$snap_id"
           die "$replay_detail" ;;
    esac

    db_status ok "" "$snap_id" "${replay_tables:-0}"
    log "database drill passed: $snap_id replayed into ${replay_tables:-0} table(s)"
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
            verify_status skip "another backup/restore run holds $VERIFY_LOCK" "$snapshot"
            die "timed out waiting for $VERIFY_LOCK"
        fi
        trap verify_cleanup EXIT
        # TimeoutStartSec (SIGTERM) and a hand Ctrl-C (SIGINT) run no EXIT trap:
        # without these, a drill killed mid-restore leaves the previous
        # `result=ok` behind and reads healthy.
        trap 'verify_cleanup; exit 143' TERM
        trap 'verify_cleanup; exit 130' INT

        # Resolve `latest` so the report names the snapshot that was proven, and
        # keep its time: the dumps inside it must come from that run, not from
        # months earlier (see verify_dump_contents).
        IFS=$'\t' read -r snap_id snap_time <<< "$(resolve_snapshot "$snapshot")"

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
                    verify_status skip "another restic run holds the repository lock" "$snap_id" "" "" "$subset"
                    log "skipping the drill: another restic run holds the repository lock"
                    exit 0
                fi
                rm -f "$clog"
                verify_status fail "restic check failed (subset $subset): the repository holds unreadable data" "$snap_id" "" "" "$subset"
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
            if verify_skip_if_locked "$slog"; then
                rm -f "$slog"
                verify_status skip "another restic run holds the repository lock" "$snap_id" "" "" "$subset"
                log "skipping the drill: another restic run holds the repository lock"
                exit 0
            fi
            cat "$slog"
            rm -f "$slog"
            verify_status fail "restic stats failed" "$snap_id" "" "" "$subset"
            die "restic stats failed"
        fi
        stats=$(cat "$slog")
        rm -f "$slog"
        size=$(printf '%s' "$stats" | jq -r '.total_size // 0' 2>/dev/null || true)
        size="${size:-0}"
        if [ "$size" -gt $(( VERIFY_MAX_MB * 1024 * 1024 )) ]; then
            verify_status skip "restore is $(( size / 1048576 )) MiB, above BACKUP_VERIFY_MAX_MB=$VERIFY_MAX_MB" "$snap_id" "" "$size" "$subset"
            log "skipping the restore: $(( size / 1048576 )) MiB exceeds BACKUP_VERIFY_MAX_MB=$VERIFY_MAX_MB"
            log "raise BACKUP_VERIFY_MAX_MB to drill a set that large, or run it by hand with --keep"
            exit 0
        fi
        mkdir -p "$VERIFY_TARGET"
        avail=$(df -Pk "$VERIFY_TARGET" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')
        need=$(( size + size / 2 ))
        if [ -n "${avail:-}" ] && [ "$avail" -lt "$need" ]; then
            verify_status skip "not enough space at $VERIFY_TARGET: need $(( need / 1048576 )) MiB, have $(( avail / 1048576 )) MiB free" "$snap_id" "" "$size" "$subset"
            log "skipping the restore: $(( need / 1048576 )) MiB needed at $VERIFY_TARGET, $(( avail / 1048576 )) MiB free"
            exit 0
        fi

        remove_restore_target "$VERIFY_TARGET"
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
            verify_status skip "another restic run holds the repository lock" "$snap_id" "" "" "$subset"
            log "skipping the drill: another restic run holds the repository lock"
            exit 0
        fi
        if ! restore_acceptable "$rlog" "$rrc"; then
            rm -f "$rlog"
            verify_status fail "restore failed (restic restore --verify)" "$snap_id" "" "$size" "$subset"
            die "restore failed"
        fi
        rm -f "$rlog"

        root="$VERIFY_TARGET/data"
        files=0
        total_bytes=0
        for vp in "${BACKUP_PATHS[@]}"; do
            if [ ! -d "$root/$vp" ]; then
                verify_status fail "the snapshot holds no /data/$vp" "$snap_id" "$files" "$total_bytes" "$subset"
                die "the restored snapshot holds no /data/$vp"
            fi
            vfiles=$(tree_count "$root/$vp")
            vbytes=$(tree_size "$root/$vp")
            if [ "$vfiles" -eq 0 ] || [ "$vbytes" -eq 0 ]; then
                verify_status fail "/data/$vp came back empty" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$vp came back empty: the snapshot does not hold it"
            fi
            files=$(( files + vfiles ))
            total_bytes=$(( total_bytes + vbytes ))
        done

        # The markers: the files whose absence makes the directory worthless.
        for marker in ${BACKUP_VERIFY_PATHS[@]+"${BACKUP_VERIFY_PATHS[@]}"}; do
            if [ ! -e "$root/$marker" ]; then
                verify_status fail "/data/$marker is missing from the snapshot" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$marker is missing from the snapshot"
            fi
            if [ -d "$root/$marker" ] && [ "$(tree_count "$root/$marker")" -eq 0 ]; then
                verify_status fail "/data/$marker is an empty directory in the snapshot" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$marker is an empty directory in the snapshot"
            fi
            if [ -f "$root/$marker" ] && [ ! -s "$root/$marker" ]; then
                verify_status fail "/data/$marker is empty in the snapshot" "$snap_id" "$files" "$total_bytes" "$subset"
                die "/data/$marker is empty in the snapshot"
            fi
        done

        # A dump killed mid-write is still a valid SQL prefix, so its header and
        # completion trailer are the cheap proof it finished; the replay
        # (`verify-db` monthly, `--with-db` by hand) is the expensive one.
        if ! assert_pg_dump_shaped "$root/postgres-dump/all.sql"; then
            verify_status fail "$pg_dump_bad_detail" "$snap_id" "$files" "$total_bytes" "$subset"
            die "$pg_dump_bad_detail"
        fi

        # The other two dumps, plus the freshness of all three: presence is not
        # consistency, and a stale dump passes every marker.
        verify_dump_contents "$root"

        if [ "$VERIFY_WITH_DB" = 1 ]; then
            # An unobtainable image is a skip, not a verdict -- and not an `ok`
            # either: ok_epoch is the age monitor.sh reads, so a drill that could
            # not replay must not reset it. Both helpers report that as rc 2.
            for pair in postgres:verify_replay_dump kuma:verify_replay_kuma_dump; do
                engine="${pair%%:*}"
                helper="${pair#*:}"
                rrc=0
                "$helper" "$root" || rrc=$?
                case "$rrc" in
                    0) ;;
                    2) replay_skips="${replay_skips:+$replay_skips; }$engine: $replay_skip_detail" ;;
                    *) verify_status fail "$replay_detail" "$snap_id" "$files" "$total_bytes" "$subset"
                       die "$replay_detail" ;;
                esac
            done
        fi

        if [ -n "$replay_skips" ]; then
            verify_status skip "the replay was skipped -- $replay_skips" \
                "$snap_id" "$files" "$total_bytes" "$subset"
            warn "restore drill restored $files file(s) from $snap_id, but the replay was skipped: $replay_skips"
        else
            verify_status ok "" "$snap_id" "$files" "$total_bytes" "$subset"
            log "restore drill passed: $files file(s), $(( total_bytes / 1048576 )) MiB restored from $snap_id"
        fi
        ;;
    verify-db)
        run_verify_db
        ;;
    forget)
        restic forget --tag stack "${BACKUP_RETENTION[@]}" --prune
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
        # The three live databases are not in the snapshot as files: their dumps
        # are. Say so here, where an operator finishing a restore is looking --
        # postgres first, because that is the one the BoltMesh tier cannot start
        # without.
        log "after ./deploy.sh: replay $DATA_DIR/postgres-dump/all.sql into the cluster (README 'Disaster recovery', step 5), copy $DATA_DIR/npm-dump/database.sqlite over $DATA_DIR/npm/data/database.sqlite (NPM stopped), and import $DATA_DIR/uptime-kuma-dump/kuma.sql into kuma's MariaDB"
        ;;
esac
