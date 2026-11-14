#!/usr/bin/env bash
# Refresh CrowdSec's hub index and installed items, then reload the engine.
#
#   scripts/crowdsec-update.sh              # update/upgrade, restart the agent
#   scripts/crowdsec-update.sh --dry-run    # print the plan, change nothing
#
# Run by deploy/crowdsec-update.timer (weekly). A USER job on purpose: crowdsec
# is a rootless container, so root's podman cannot see it, and the root tier
# must not learn to run commands as the stack user (docs/ids.md).
#
# `cscli hub upgrade` updates the installed parsers/scenarios, but the agent
# reads them at start; the container's own reload command is `systemctl reload
# crowdsec`, which a Quadlet unit has no ExecReload for. A try-restart applies
# the new files and leaves an intentionally stopped unit stopped. The restart
# is why this job and the root Suricata refresh are an hour apart.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help)    usage_header "$0"; exit 0 ;;
        *)            die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

resolve_data_dir
AUDIT_DIR="$DATA_DIR/audit"
STATUS="$AUDIT_DIR/crowdsec-update.status"
LOG="$AUDIT_DIR/crowdsec-update.log"
mkdir -p "$AUDIT_DIR"

# The verdict file this run owns; deploy/root/status.sh owns the contract and a
# dry run writes nothing (verdict_write's guard).
verdict_init "$STATUS" scripts/crowdsec-update.sh deploy/crowdsec-update.timer

# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below
cleanup() {
    verdict_unrecorded "the CrowdSec hub update exited without recording a verdict"
}
trap cleanup EXIT

say() { [ "$DRY_RUN" = 1 ] && printf '%s\n' "$*"; return 0; }

command -v podman >/dev/null 2>&1 \
    || { verdict_write fail "podman is not available, so the hub cannot be refreshed"; exit 1; }

if ! podman container exists crowdsec 2>/dev/null; then
    say "no crowdsec container on this host; the next container start refreshes the hub"
    verdict_write skip "no crowdsec container on this host; the next container start refreshes the hub"
    exit 0
fi

state=$(podman inspect crowdsec --format '{{.State.Status}}' 2>/dev/null) \
    || { verdict_write fail "could not read the crowdsec container state"; exit 1; }
if [ "$state" != running ]; then
    say "the crowdsec container is ${state:-not running}; the next start refreshes the hub"
    verdict_write skip "the crowdsec container is ${state:-not running}; the next start refreshes the hub"
    exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
    printf 'would run: podman exec crowdsec cscli hub update\n'
    printf 'would run: podman exec crowdsec cscli hub upgrade\n'
    printf 'would run: systemctl --user try-restart crowdsec.service\n'
    exit 0
fi

{
    printf '# %s crowdsec hub refresh\n' "$(date -Is)"
} > "$LOG"

# Both commands are attempted: hub upgrade can still work from the cached index
# when the network fetch fails, and the status names whichever half broke.
update_rc=0
timeout 180 podman exec crowdsec cscli hub update >> "$LOG" 2>&1 || update_rc=$?
upgrade_rc=0
timeout 180 podman exec crowdsec cscli hub upgrade >> "$LOG" 2>&1 || upgrade_rc=$?

restart_rc=0
if [ "$upgrade_rc" = 0 ]; then
    systemctl --user try-restart crowdsec.service >> "$LOG" 2>&1 || restart_rc=$?
fi

hub_update=ok
[ "$update_rc" = 0 ] || hub_update=failed
hub_upgrade=ok
[ "$upgrade_rc" = 0 ] || hub_upgrade=failed

fields=("hub_update=$hub_update" "hub_upgrade=$hub_upgrade" "restarted=0")
[ "$restart_rc" = 0 ] && [ "$upgrade_rc" = 0 ] && fields[2]="restarted=1"

if [ "$update_rc" != 0 ] && [ "$upgrade_rc" != 0 ]; then
    detail="hub update and upgrade failed (see $LOG)"
elif [ "$update_rc" != 0 ]; then
    detail="hub index update failed; the upgrade used the cached index (see $LOG)"
elif [ "$upgrade_rc" != 0 ]; then
    detail="hub upgrade failed; the installed items are unchanged (see $LOG)"
elif [ "$restart_rc" != 0 ]; then
    detail="hub items upgraded but crowdsec did not restart (see $LOG)"
else
    detail="hub index updated, installed items upgraded, crowdsec reloaded"
fi

if [ "$update_rc" = 0 ] && [ "$upgrade_rc" = 0 ] && [ "$restart_rc" = 0 ]; then
    verdict_write ok "$detail" "${fields[@]}"
    printf 'crowdsec-update: %s\n' "$detail"
    exit 0
fi

verdict_write fail "$detail" "${fields[@]}"
printf 'crowdsec-update: %s\n' "$detail" >&2
exit 1
