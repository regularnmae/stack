#!/usr/bin/env bash
# Reconcile the status page's monitors against the declarations in stack.conf.
#
#   scripts/kuma-monitors.sh            # reconcile every monitor in KUMA_MONITORS
#                                       # + create/fill the status page (only
#                                       #   while it has no monitors of its own)
#   scripts/kuma-monitors.sh --dry-run  # print the plan; change nothing
#   scripts/kuma-monitors.sh --prune    # additionally DELETE monitors that
#                                       # KUMA_MONITORS does not declare
#
# KUMA_MONITORS in stack.conf is the declaration; each entry is
#
#   name | url [| accepted-status-codes [| interval [| retries ]] ]
#
# where codes is a comma-separated list of Uptime-Kuma ranges ("200-299,400-
# 499" -- a token-gated endpoint answers 401 without a token, which is *up*),
# interval the seconds between beats (default 60) and retries the attempts
# before down (default 2). A url of the form `tcp://host:port` declares kuma's
# "port" monitor instead of an HTTP one: no status code applies, so that field
# stays empty and the interval/retries keep their positions:
#
#   "Fulcrum (Electrum TCP)|tcp://host.containers.internal:50001||60|2"
#
# The page every declared monitor is published on is
# KUMA_STATUS_SLUG/KUMA_STATUS_TITLE/KUMA_STATUS_GROUP.
#
# Uptime-Kuma has no REST write API -- its management surface is socket.io.
# The client is scripts/stackctl/kuma.py (socketio.py over ws.py, stdlib
# only), fed the declarations over stdin (scripts/stackctl/decl.py). The
# kuma-ctl Node image this script used to `podman run` is retired: no image
# build, no container and no bind mount stand between the declaration and the
# server any more. Kuma is reached through its loopback publish -- the
# PublishPort=127.0.0.1:8107:3001 of deploy/uptime-kuma.container, which is
# what the KUMA_URL default below mirrors; move the publish and the default
# moves with it. Proving the publish (rather than the container name on
# npm-network) is deliberate: it is the same surface nginx-proxy-manager
# forwards the dashboard through.
#
# The admin login lives in $DATA_DIR/config/uptime-kuma/api.env (mode 600,
# seeded by deploy/install.sh; fill it in with the login the setup wizard
# asked for). The Python core reads that file itself -- no credential reaches
# an argv or a container env `ps` can read.
#
# Idempotent and UI-preserving: missing monitors are created, monitors whose
# *declared* fields changed are updated in place (UI-tuned interval, retries
# and notifications are carried over untouched), and the status page is only
# written when it does not exist at all -- an existing page's layout is the
# UI's. --prune is the only destructive mode.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
. "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

DRY_RUN=0
PRUNE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --prune)   PRUNE=1 ;;
        -h|--help) usage_header "$0"; exit 0 ;;
        *)         die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to run the reconciler (bootstrap.sh installs it)"

if [ "${KUMA_MONITORS+x}" != x ] || [ "${#KUMA_MONITORS[@]}" -eq 0 ]; then
    die "KUMA_MONITORS is empty; set it in stack.conf"
fi

resolve_data_dir
KUMA_ENV="$CONFIG_DIR/uptime-kuma/api.env"

KUMA_USERNAME="${KUMA_USERNAME:-$(env_value "$KUMA_ENV" KUMA_USERNAME)}"
KUMA_PASSWORD="${KUMA_PASSWORD:-$(env_value "$KUMA_ENV" KUMA_PASSWORD)}"

if [ -z "$KUMA_USERNAME" ] || [ -z "$KUMA_PASSWORD" ]; then
    log "no Uptime-Kuma admin login in $KUMA_ENV"
    log "fill in KUMA_USERNAME/KUMA_PASSWORD (the login the setup wizard asked for), then re-run"
    exit 0
fi

# The loopback publish of deploy/uptime-kuma.container (see the header).
KUMA_URL="${KUMA_URL:-http://127.0.0.1:8107}"

if [ -n "${KUMA_STATUS_SLUG:-}" ]; then
    KUMA_STATUS_TITLE="${KUMA_STATUS_TITLE:-BoltMesh services}"
    KUMA_STATUS_GROUP="${KUMA_STATUS_GROUP:-Public services}"
else
    log "KUMA_STATUS_SLUG is empty in stack.conf; only the monitors will be reconciled"
fi

if [ -n "${KUMA_STATUS_SLUG:-}" ]; then
    log "reconciling ${#KUMA_MONITORS[@]} monitor(s) + status page '$KUMA_STATUS_SLUG'"
else
    log "reconciling ${#KUMA_MONITORS[@]} monitor(s)"
fi

stream_decls() {
    local entry
    printf 'V\tKUMA_URL\t%s\n' "$KUMA_URL"
    printf 'V\tCONFIG_DIR\t%s\n' "$CONFIG_DIR"
    printf 'V\tDRY_RUN\t%s\n' "$DRY_RUN"
    printf 'V\tPRUNE\t%s\n' "$PRUNE"
    printf 'V\tKUMA_STATUS_SLUG\t%s\n' "${KUMA_STATUS_SLUG:-}"
    printf 'V\tKUMA_STATUS_TITLE\t%s\n' "${KUMA_STATUS_TITLE:-}"
    printf 'V\tKUMA_STATUS_GROUP\t%s\n' "${KUMA_STATUS_GROUP:-}"
    for entry in "${KUMA_MONITORS[@]}"; do printf 'K\t%s\n' "$entry"; done
}

stream_decls \
    | PYTHONPATH="$REPO_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" python3 -m stackctl kuma-monitors

log "done"
