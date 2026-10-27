#!/usr/bin/env bash
# Back up and restore the stack's irreplaceable state with restic.
#
#   scripts/backup.sh [backup]        # run the job now: init if needed, back up, prune
#   scripts/backup.sh init            # initialise the repository only
#   scripts/backup.sh list            # list snapshots
#   scripts/backup.sh list --json     # the same, for scripts (restic's JSON)
#   scripts/backup.sh ls [<snap>]     # list the paths inside a snapshot
#   scripts/backup.sh check           # verify repository integrity
#   scripts/backup.sh forget          # apply the retention policy (and prune)
#   scripts/backup.sh restore <snap>  # restore into the data dir, in place
#   scripts/backup.sh unlock          # clear stale locks
#
# The scheduled run lives in deploy/backup.container + deploy/backup.timer;
# this helper runs the same job by hand and adds the read/restore commands. Both
# read the backup set from one declaration -- BACKUP_PATHS in stack.conf -- which
# deploy/install.sh also renders into the unit, so what a hand run copies is
# exactly what the nightly job copies, and the database dump is refreshed here
# the same way the unit's Wants=postgres-dump.service refreshes it.
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

RESTIC_IMAGE="${RESTIC_IMAGE:-docker.io/restic/restic:latest}"
STACK_BACKUP_DIR="${STACK_BACKUP_DIR:-$HOME/data-backup}"
RETENTION=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

command -v podman >/dev/null 2>&1 || die "podman is required"

cmd="${1:-backup}"
[ $# -gt 0 ] && shift

case "$cmd" in
    -h|--help) usage_header "$0"; exit 0 ;;
    backup|init|list|snapshots|ls|check|forget|restore|unlock|version) ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac

# restore and ls take a snapshot argument; everything else takes none.
snapshot=""
if [ "$cmd" = restore ] || [ "$cmd" = ls ]; then
    for a in "$@"; do
        case "$a" in
            -y|--yes) ASSUME_YES=1 ;;
            *) [ -n "$snapshot" ] && die "$cmd takes one snapshot id"; snapshot="$a" ;;
        esac
    done
    snapshot="${snapshot:-latest}"
fi

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
common=(
    --rm
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
    data_ro+=(-v "$DATA_DIR/$p:/data/$p:ro,z")
    data_rw+=(-v "$DATA_DIR/$p:/data/$p:z")
    backup_paths+=("/data/$p")
done

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
# from the same declaration: the path list and the retention policy are
# generated, so the two cannot drift.
job_script=$(
    printf 'set -e\n'
    printf 'restic snapshots >/dev/null 2>&1 || restic init\n'
    printf 'restic backup %s --host stack --tag stack\n' "${backup_paths[*]}"
    printf 'restic forget --tag stack --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune\n'
)

# The nightly unit gets a fresh pg_dumpall from postgres-dump.service, pulled in
# by Wants=/After= in deploy/backup.container. A hand run has no such ordering,
# so it takes the same dump here. Best-effort, exactly like the unit: a Postgres
# outage must never stop the run that protects the wallet and the CLN identity,
# and the previous dump is still worth copying.
refresh_postgres_dump() {
    local p in_set=0
    for p in "${BACKUP_PATHS[@]}"; do
        [ "$p" = postgres-dump ] && in_set=1
    done
    [ "$in_set" = 1 ] || return 0

    if ! command -v systemctl >/dev/null 2>&1 \
        || ! systemctl --user cat postgres-dump.service >/dev/null 2>&1; then
        warn "postgres-dump.service is not installed (or not reachable); copying $DATA_DIR/postgres-dump as it stands"
        return 0
    fi
    if systemctl --user start postgres-dump.service; then
        log "took a fresh BoltMesh database dump"
    else
        warn "postgres-dump.service failed; copying the previous dump (if any)"
    fi
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
        refresh_postgres_dump
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
        podman run "${common[@]}" "${data_rw[@]}" \
            "$RESTIC_IMAGE" restore "$snapshot" --target /
        # Belt and braces: install.sh hands this dir to the image uid too.
        podman unshare chown -R 1000:1000 "$DATA_DIR/monero-wallet-rpc" 2>/dev/null \
            || warn "could not chown $DATA_DIR/monero-wallet-rpc to the image uid"
        log "restore complete; start the stack with ./deploy.sh"
        ;;
esac
