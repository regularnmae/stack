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
# before down (default 2). The page every declared monitor is published on is
# KUMA_STATUS_SLUG/KUMA_STATUS_TITLE/KUMA_STATUS_GROUP.
#
# Uptime-Kuma has no REST write API, so the work runs as a socket.io client in
# the kuma-ctl image (built by deploy/install.sh from kuma-ctl/), reached by
# container name on npm-network. The admin login lives in
# $DATA_DIR/config/uptime-kuma/api.env (mode 600, seeded by deploy/install.sh;
# fill it in with the login the setup wizard asked for) and is passed to the
# container through the environment, never a command line `ps` can read.
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

# jq composes the payload for the container's environment (the declaration
# itself is plain shell); bootstrap.sh installs it, like for npm-hosts.sh.
command -v jq >/dev/null 2>&1 \
    || die "jq is required. Install it: sudo dnf install -y jq"

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

KUMA_CTL_IMAGE="${KUMA_CTL_IMAGE:-localhost/kuma-ctl:local}"
if ! podman image exists "$KUMA_CTL_IMAGE" 2>/dev/null; then
    die "$KUMA_CTL_IMAGE is not built. Re-run ./deploy.sh (deploy/install.sh builds it from kuma-ctl/), or: podman build -t $KUMA_CTL_IMAGE $REPO_DIR/kuma-ctl/"
fi

# --- declaration -> payload -------------------------------------------------
# Every entry becomes a normalized monitor object. Numbers must be verifiably
# numbers before they reach --argjson; codes are trimmed and split on commas.
monitors_json="[]"
for entry in "${KUMA_MONITORS[@]}"; do
    IFS='|' read -r mname murl mcodes minterval mretries <<<"$entry"
    [ -n "$mname" ] && [ -n "$murl" ] \
        || die "bad KUMA_MONITORS entry: $entry (want \"name|url[|codes[|interval[|retries]]]\")"
    case "$murl" in
        http://*|https://*) ;;
        *) die "bad monitor URL in KUMA_MONITORS entry: $entry (want scheme://...)" ;;
    esac
    mcodes="${mcodes:-200-299}"
    minterval="${minterval:-60}"
    mretries="${mretries:-2}"
    case "$minterval" in ''|*[!0-9]*) die "bad interval in KUMA_MONITORS entry: $entry (seconds)" ;; esac
    case "$mretries"  in ''|*[!0-9]*) die "bad retries in KUMA_MONITORS entry: $entry (attempts)" ;; esac
    printf '%s' "$mcodes" | grep -qE '^[0-9]{3}-[0-9]{3}(,[0-9]{3}-[0-9]{3})*$' \
        || die "bad accepted status codes in KUMA_MONITORS entry: $entry (want ranges like 200-299,400-499)"
    monitors_json=$(printf '%s' "$monitors_json" | jq -c \
        --arg name "$mname" --arg url "$murl" --arg codes "$mcodes" \
        --argjson interval "$minterval" --argjson retries "$mretries" \
        '. + [{name: $name, url: $url,
               codes: ($codes | gsub(" "; "") | split(",")),
               interval: $interval, retryInterval: $interval, maxretries: $retries}]')
done

status_json=""
if [ -n "${KUMA_STATUS_SLUG:-}" ]; then
    KUMA_STATUS_TITLE="${KUMA_STATUS_TITLE:-BoltMesh services}"
    KUMA_STATUS_GROUP="${KUMA_STATUS_GROUP:-Public services}"
    status_json=$(jq -nc --arg slug "$KUMA_STATUS_SLUG" --arg title "${KUMA_STATUS_TITLE}" \
        --arg group "${KUMA_STATUS_GROUP}" '{slug: $slug, title: $title, group: $group}')
else
    log "KUMA_STATUS_SLUG is empty in stack.conf; only the monitors will be reconciled"
fi

# --- reconcile inside the kuma-ctl container --------------------------------
# The script is bind-mounted so the repo owns the runtime code; the login is
# delivered through the environment -- `podman run -e` is not a command line
# `ps` can read, the same rule `scripts/npm-hosts.sh` holds with its curl
# config on stdin.
runtime_args=(
    --rm
    --network npm-network
    -e "KUMA_URL=http://uptime-kuma:3001"
    -e "KUMA_USERNAME=$KUMA_USERNAME"
    -e "KUMA_PASSWORD=$KUMA_PASSWORD"
    -e "KUMA_MONITORS_JSON=$monitors_json"
    -e "KUMA_DRY_RUN=$DRY_RUN"
    -e "KUMA_PRUNE=$PRUNE"
    -v "$REPO_DIR/kuma-ctl/monitors.mjs:/kuma-ctl/monitors.mjs:ro,z"
)
[ -n "$status_json" ] && runtime_args+=(-e "KUMA_STATUS_JSON=$status_json")

# --- reconcile inside the kuma-ctl container --------------------------------
# The script is bind-mounted so the repo owns the runtime code; the login is
# delivered through the environment -- podman run -e is not a command line ps
# can read, holding the same rule scripts/npm-hosts.sh's curl config holds.
if [ -n "$status_json" ]; then
    log "reconciling ${#KUMA_MONITORS[@]} monitor(s) + status page '$KUMA_STATUS_SLUG'"
else
    log "reconciling ${#KUMA_MONITORS[@]} monitor(s)"
fi
podman run "${runtime_args[@]}" "$KUMA_CTL_IMAGE" node /kuma-ctl/monitors.mjs

log "done"
