#!/usr/bin/env bash
# Back up and restore the stack's irreplaceable state with restic.
#
#   scripts/backup.sh [backup]        # run the job now: init if needed, back up, prune
#   scripts/backup.sh init            # initialise the repository only
#   scripts/backup.sh list            # list snapshots
#   scripts/backup.sh check           # verify repository integrity
#   scripts/backup.sh forget          # apply the retention policy (and prune)
#   scripts/backup.sh restore <snap>  # restore into the data dir, in place
#   scripts/backup.sh unlock          # clear stale locks
#
# The scheduled run lives in deploy/backup.container + deploy/backup.timer;
# this helper runs the same job by hand and adds the read/restore commands. It
# uses the same read-only mounts as the unit, so what it copies is exactly what
# the nightly job copies.
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

RESTIC_IMAGE="${RESTIC_IMAGE:-docker.io/restic/restic:latest}"
STACK_BACKUP_DIR="${STACK_BACKUP_DIR:-$HOME/data-backup}"
RETENTION=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

command -v podman >/dev/null 2>&1 || die "podman is required"

cmd="${1:-backup}"
[ $# -gt 0 ] && shift

case "$cmd" in
    -h|--help) usage_header "$0"; exit 0 ;;
    backup|init|list|snapshots|check|forget|restore|unlock|version) ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac

# restore takes a snapshot argument; everything else takes none.
snapshot=""
if [ "$cmd" = restore ]; then
    for a in "$@"; do
        case "$a" in
            -y|--yes) ASSUME_YES=1 ;;
            *) [ -n "$snapshot" ] && die "restore takes one snapshot id"; snapshot="$a" ;;
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
data_ro=(
    -v "$DATA_DIR/cln:/data/cln:ro,z"
    -v "$DATA_DIR/monero-wallet-rpc:/data/monero-wallet-rpc:ro,z"
    -v "$DATA_DIR/config:/data/config:ro,z"
    -v "$DATA_DIR/npm:/data/npm:ro,z"
)
data_rw=(
    -v "$DATA_DIR/cln:/data/cln:z"
    -v "$DATA_DIR/monero-wallet-rpc:/data/monero-wallet-rpc:z"
    -v "$DATA_DIR/config:/data/config:z"
    -v "$DATA_DIR/npm:/data/npm:z"
)

restic() { podman run "${common[@]}" "$RESTIC_IMAGE" "$@"; }

# Every bind-mount source must exist before podman runs: with SELinux relabel
# (:z) podman statfs's the source and fails rather than creating it. A restore
# is exactly the case where they are missing, so create them.
ensure_mount_dirs() {
    mkdir -p "$STACK_BACKUP_DIR" "$DATA_DIR/backup-cache" \
        "$DATA_DIR/cln" "$DATA_DIR/monero-wallet-rpc" "$DATA_DIR/config" "$DATA_DIR/npm"
}
ensure_mount_dirs

# The exact set the nightly unit copies: identity, wallet, secrets, NPM. The
# chains and searxng are regenerable and stay out.
backup_paths=(/data/cln /data/monero-wallet-rpc /data/config /data/npm)

# Mirrors the Exec= in deploy/backup.container; keep the two in step.
read -r -d '' job_script <<'SH' || true
set -e
restic snapshots >/dev/null 2>&1 || restic init
restic backup /data/cln /data/monero-wallet-rpc /data/config /data/npm --host stack --tag stack
restic forget --tag stack --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
SH

case "$cmd" in
    init)
        restic init
        log "initialised $RESTIC_REPOSITORY"
        ;;
    list|snapshots)
        restic snapshots --tag stack
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
        log "backing up ${backup_paths[*]} to $RESTIC_REPOSITORY"
        podman run "${common[@]}" "${data_ro[@]}" \
            --entrypoint /bin/sh "$RESTIC_IMAGE" -c "$job_script"
        log "backup complete"
        ;;
    restore)
        if [ "${ASSUME_YES:-0}" != 1 ]; then
            if [ -t 0 ]; then
                printf 'Restore snapshot "%s" over %s/{cln,monero-wallet-rpc,config,npm}?\n' \
                    "$snapshot" "$DATA_DIR"
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
