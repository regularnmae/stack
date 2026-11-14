#!/usr/bin/env bash
# stack-suricata-update: refresh the live sensor's ET Open ruleset.
#
# Runs as root from deploy/root/stack-suricata-update.timer (weekly), installed
# to /etc/stack-ids/suricata-update.sh by `deploy/install.sh --root`.
#
#   /etc/stack-ids/suricata-update.sh     update + live reload
#
# The sensor is the repo's one rootful container, so this job is root: the rule
# fetch happens inside the running container (suricata-update lives in the
# image), and the reload is its control socket. It never restarts the container:
# a failed reload leaves the previous, working set loaded, and the sensor's
# healthcheck plus Restart=always own a wedged engine. The next weekly run (or
# any container start) retries.
#
# The rules file's mtime is the freshness fact scripts/ids.sh reports. The
# updater rewrites it on every successful run even when the rule set is
# unchanged, and a failed fetch leaves the old file alone.
set -uo pipefail

DATA_DIR="@DATA_DIR@"
RULES="$DATA_DIR/ids/suricata/lib/rules/suricata.rules"
LOG="$DATA_DIR/ids/suricata/suricata-update.log"

if [ ! -r /etc/stack-ids/status.sh ]; then
    printf 'ERROR: /etc/stack-ids/status.sh is missing; re-run sudo ./bootstrap.sh\n' >&2
    exit 1
fi
# shellcheck source=status.sh
. /etc/stack-ids/status.sh

STATUS="$DATA_DIR/audit/suricata-update.status"
# The verdict file this run owns; deploy/root/status.sh owns the contract.
verdict_init "$STATUS" /etc/stack-ids/suricata-update.sh stack-suricata-update.timer

# A killed run must not leave the previous result=ok in place. The unit's
# TimeoutStartSec is the other half: a SIGKILL cannot run this, so the status
# age check backstops it (deploy/root/status.sh).
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below
cleanup() {
    verdict_unrecorded "the Suricata rule update exited without recording a verdict"
}
trap cleanup EXIT

PODMAN=$(command -v podman 2>/dev/null || true)
if [ -z "$PODMAN" ]; then
    verdict_write fail "podman is not available, so the ruleset cannot be refreshed"
    exit 1
fi

mkdir -p "$DATA_DIR/ids/suricata" \
    || { verdict_write fail "could not create $DATA_DIR/ids/suricata"; exit 1; }

if ! "$PODMAN" container exists suricata >/dev/null 2>&1; then
    verdict_write skip "no suricata container on this host; the next container start refreshes the ruleset"
    exit 0
fi

state=$("$PODMAN" inspect suricata --format '{{.State.Status}}' 2>/dev/null) \
    || { verdict_write fail "could not read the suricata container state"; exit 1; }
if [ "$state" != running ]; then
    verdict_write skip "the suricata container is ${state:-not running}; the next start refreshes the ruleset"
    exit 0
fi

# The strict mode bounds the whole run's policy: --fail for the fetch and the
# rule test before the file is replaced. A timeout is a failure, not a partial
# success.
if ! timeout 600 "$PODMAN" exec suricata /etc/suricata-stack/update.sh --strict \
        > "$LOG" 2>&1; then
    err=$(tail -n 1 "$LOG" 2>/dev/null || true)
    verdict_write fail \
        "ET Open update failed; keeping the previous ruleset${err:+ ($err)}" \
        "reloaded=0"
    exit 1
fi

if [ ! -s "$RULES" ]; then
    verdict_write fail "the update left $RULES empty; the sensor is on local.rules only" \
        "reloaded=0"
    exit 1
fi

rules_epoch=$(stat -c %Y "$RULES" 2>/dev/null || true)
rules_lines=$(wc -l < "$RULES" 2>/dev/null | tr -d ' ')
case "$rules_epoch" in ''|*[!0-9]*) rules_epoch="" ;; esac
case "$rules_lines" in
    ''|*[!0-9]*|0)
        verdict_write fail "the update left $RULES unreadable or empty; the sensor is on local.rules only" \
            "reloaded=0"
        exit 1 ;;
esac

# The live reload. suricatasc exits 0 and prints a NOK message on some failures
# (suricata-update greps for exactly that in its own reload command), so both
# the exit status and the payload are checked.
reload_rc=0
reload_out=$(timeout 180 "$PODMAN" exec suricata /usr/bin/suricatasc \
    -c reload-rules /run/suricata-command.socket 2>&1) || reload_rc=$?
printf '%s\n' "$reload_out" >> "$LOG"
if [ "$reload_rc" != 0 ] || printf '%s' "$reload_out" | grep -q 'NOK'; then
    verdict_write fail \
        "the new ruleset was written but the live reload failed; the previous set stays loaded until the sensor restarts (${reload_out:-suricatasc failed})" \
        "rules_epoch=$rules_epoch" "rules_lines=$rules_lines" "reloaded=0"
    exit 1
fi

verdict_write ok \
    "ET Open ruleset refreshed (${rules_lines} rules) and reloaded" \
    "rules_epoch=$rules_epoch" "rules_lines=$rules_lines" "reloaded=1"
printf 'suricata-update: ok (%s rules, epoch %s)\n' \
    "$rules_lines" "${rules_epoch:-unknown}"
