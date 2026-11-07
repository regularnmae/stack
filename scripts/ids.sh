#!/usr/bin/env bash
# Roll the intrusion-detection state up into one file the monitor can read.
#
#   scripts/ids.sh              # write $DATA_DIR/audit/ids.status, append a log line
#   scripts/ids.sh --verbose    # ... and print what it found
#
# Run by deploy/ids.timer every five minutes (offset from monitor.timer, so the
# sweep reads a fresh status rather than racing this script). Read-only towards
# everything it inspects: it starts no unit, applies no decision and deletes no
# log.
#
# WHY A STATUS FILE AND NOT DIRECT QUERIES IN monitor.sh: the two engines have
# different privilege shapes. Suricata is a rootful system service whose logs
# live in a root-owned directory (readable, 0644), and crowdsec is a rootless
# container asked through `podman exec`. Neither is something monitor.sh should
# reach into during a sweep -- and a wedged engine should make the *file* stale,
# which is exactly the signal a dead-man's switch can see. This is the same
# pattern as backup-verify.status: a oneshot unit's failure is otherwise just a
# line in `systemctl status`.
#
# The record is KEY=VALUE (read with env_value in scripts/monitor.sh, never
# sourced), written atomically, with ok_epoch carried forward on failure so the
# age check measures "detection last worked", not "the timer fired".
#

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

VERBOSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=1 ;;
        -h|--help)    usage_header "$0"; exit 0 ;;
        *)            die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

resolve_data_dir
AUDIT_DIR="$DATA_DIR/audit"
STATUS_FILE="$AUDIT_DIR/ids.status"
CURSOR_FILE="$AUDIT_DIR/ids.cursor"
AUDIT_LOG="$AUDIT_DIR/ids.log"
mkdir -p "$AUDIT_DIR"

# Suricata writes here (deploy/root/suricata.container): root-owned directory,
# world-readable files. A missing file is a normal state on a host whose root
# tier has not been installed yet, not an error.
EVE="$DATA_DIR/ids/suricata/eve.json"

say() { [ "$VERBOSE" = 1 ] && printf '%s\n' "$*"; return 0; }

# ---------------------------------------------------------------------------
# the engines
# ---------------------------------------------------------------------------
# `systemctl is-active` talks to the system manager and needs no privilege,
# which is the reason the check is here and not a `podman inspect` (rootful
# podman is not reachable from this user at all).
SURICATA_STATE=absent
if [ -f /etc/containers/systemd/suricata.container ]; then
    SURICATA_STATE=$(systemctl is-active suricata 2>/dev/null || true)
    [ -n "$SURICATA_STATE" ] || SURICATA_STATE=unknown
fi
say "suricata: $SURICATA_STATE"

CROWDSEC_STATE=absent
DECISIONS=0
NEWEST=""
if podman container exists crowdsec 2>/dev/null; then
    CROWDSEC_STATE=$(podman inspect crowdsec --format '{{.State.Status}}' 2>/dev/null || true)
    [ -n "$CROWDSEC_STATE" ] || CROWDSEC_STATE=unknown
    # cscli inside the running container: the same binary the LAPI answers, no
    # extra credentials to hold on the host.
    #
    # The shape is ALERT-grouped, not decision-flat: `cscli decisions list -o json`
    # marshals the Alerts.List response (upstream clidecision's decisionsToTable),
    # so the array holds one entry per alert -- scenario, source.value, created_at
    # -- and the decision(s) that alert produced under .decisions[] (one per
    # scope/origin variant). There is no top-level .value. Reading the top level
    # as the decision list therefore counted groups rather than decisions and
    # formatted NEWEST out of the group, which is how the roll-up printed
    # "stack/http-probing ?" instead of the offending address. bouncer.sh is not
    # the other side of this: it reads /v1/decisions, which really is flat -- do
    # not "align" the two.
    decisions_json=$(podman exec crowdsec cscli decisions list -o json 2>/dev/null || true)
    if [ -n "$decisions_json" ]; then
        # Distinct decisions, not nested rows: the same decision can come back
        # under two alert groups (the human table dedupes by
        # simulated:type:scope:value for the same reason), and this counter means
        # "how many are in force". .id is the LAPI's own decision id; the tuple is
        # only the fallback for an entry that carries none.
        #
        # cscli's default --limit 100 caps this at the first 100 groups, on
        # purpose: each group carries its event list, so lifting the cap would
        # make a five-minute sweep parse an arbitrary payload. The counter is a
        # report (monitor.sh shows it, metrics.sh graphs it), never a threshold.
        DECISIONS=$(printf '%s' "$decisions_json" | jq -r '
            if type == "array"
            then ([.[] | .decisions[]?]
                  | unique_by(.id // "\(.scope):\(.value):\(.type):\(.simulated)")
                  | length)
            else 0 end' 2>/dev/null) || DECISIONS=0
        # Newest = the first decision of the first group, i.e. the LAPI's own
        # newest-first order (the assumption the old code already made);
        # .decisions[]? walks past a group with none instead of printing a bare "?".
        NEWEST=$(printf '%s' "$decisions_json" | jq -r '
            if type == "array" then ([.[] | .decisions[]?][0]) else null end
            | if . == null then "" else "\(.scenario // "?") \(.value // "?")" end' 2>/dev/null) || NEWEST=""
    else
        CROWDSEC_STATE="unreachable"
    fi
fi
say "crowdsec: $CROWDSEC_STATE, $DECISIONS decision(s)${NEWEST:+ (newest: $NEWEST)}"

# ---------------------------------------------------------------------------
# Suricata alerts since the last run
# ---------------------------------------------------------------------------
# A byte cursor, not a scan of the whole file: eve.json is the highest-volume
# artefact in the stack (every HTTP/TLS/DNS record), and re-reading it every
# five minutes to count a handful of alerts is how a monitor becomes the load it
# is supposed to notice. A truncate -- or a rotation, if the filename ever
# gains a strftime template -- shrinks the file, which the size-decreased check
# catches by restarting from zero.
ALERTS=0
LAST_ALERT=""
if [ -s "$EVE" ]; then
    size=$(stat -c %s "$EVE" 2>/dev/null || echo 0)
    off=0
    [ -f "$CURSOR_FILE" ] && off=$(cat "$CURSOR_FILE" 2>/dev/null)
    case "$off" in ''|*[!0-9]*) off=0 ;; esac
    [ "$size" -ge "$off" ] || off=0
    if [ "$size" -gt "$off" ]; then
        # -R + fromjson? so a torn final line (an unfinished write) is skipped
        # instead of failing the whole stream. The cursor advances whenever the
        # read *completed*, not only when it found an alert -- zero alerts is the
        # normal state, and leaving the cursor behind re-reads the whole file
        # every sweep, which is the load the cursor exists to avoid. pipefail
        # makes a failing tail/jq skip the advance instead, so an unreadable
        # window is re-examined rather than silently stepped over.
        #
        # Only the signature is printed, not signature_id: the id was in the
        # stream as a second tab-separated field once, and `read -a` splits on
        # tabs as well as spaces, so LAST_ALERT came back as "2010936" while the
        # message claimed it was the signature. Two fields, count and signature,
        # and `read` with two names keeps the rest of the line (spaces and all).
        if raw=$(tail -c +$((off + 1)) "$EVE" 2>/dev/null \
            | jq -Rr 'fromjson? | select(.event_type == "alert") | .alert.signature' 2>/dev/null \
            | awk '{n++; last=$0} END {print n+0 "\t" last}'); then
            read -r ALERTS LAST_ALERT <<< "$raw"
            ALERTS="${ALERTS:-0}"
            LAST_ALERT="${LAST_ALERT:-}"
            case "$ALERTS" in ''|*[!0-9]*) ALERTS=0 ;; esac
            printf '%s\n' "$size" > "$CURSOR_FILE"
        fi
    fi
fi
say "suricata alerts since the last run: $ALERTS${LAST_ALERT:+ (last: $LAST_ALERT)}"

# ---------------------------------------------------------------------------
# the verdict
# ---------------------------------------------------------------------------
# A tier that is not installed is not a failure -- a fresh host that has not run
# `sudo ./bootstrap.sh` yet has no sensor, and pretending otherwise would turn
# every sweep red. An installed tier that is not running is a failure: the host
# believes it is being watched and is not.
problem=""
case "$SURICATA_STATE" in
    absent|active) ;;
    *) problem="suricata is $SURICATA_STATE" ;;
esac
case "$CROWDSEC_STATE" in
    absent|running) ;;
    unreachable) problem="${problem:+$problem; }crowdsec LAPI is not answering" ;;
    *) problem="${problem:+$problem; }crowdsec is $CROWDSEC_STATE" ;;
esac

result=ok
[ -n "$problem" ] && result=fail

now=$(date +%s)
prev_ok=""
[ -f "$STATUS_FILE" ] && prev_ok=$(env_value "$STATUS_FILE" ok_epoch)
case "$prev_ok" in ''|*[!0-9]*) prev_ok="" ;; esac
if [ "$result" = ok ]; then ok_epoch="$now"; else ok_epoch="$prev_ok"; fi

tmp=$(mktemp "$AUDIT_DIR/.ids.XXXXXX") || die "could not write $STATUS_FILE"
if {
    printf '# written by scripts/ids.sh (deploy/ids.timer)\n'
    printf 'time=%s\n' "$(date -Is)"
    printf 'epoch=%s\n' "$now"
    printf 'result=%s\n' "$result"
    printf 'ok_epoch=%s\n' "$ok_epoch"
    printf 'suricata=%s\n' "$SURICATA_STATE"
    printf 'crowdsec=%s\n' "$CROWDSEC_STATE"
    printf 'alerts=%s\n' "$ALERTS"
    printf 'decisions=%s\n' "$DECISIONS"
    printf 'detail=%s\n' "$(printf '%s' "$problem" | tr '\n' ' ')"
} > "$tmp"; then
    mv -f "$tmp" "$STATUS_FILE" || warn "could not write $STATUS_FILE"
else
    rm -f "$tmp"
    warn "could not write $STATUS_FILE"
fi

printf '%s result=%s suricata=%s crowdsec=%s alerts=%d decisions=%d%s\n' \
    "$(date -Is)" "$result" "$SURICATA_STATE" "$CROWDSEC_STATE" "$ALERTS" "$DECISIONS" \
    "${problem:+ -- $problem}" >> "$AUDIT_LOG"

[ "$result" = ok ] || { printf 'ids: %s\n' "$problem" >&2; exit 1; }
say "ok"
