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

# The bounded EVE window is staged here while it is counted. The trap covers a
# failure between creating the chunk and removing it at the end of the block.
CHUNK=""
trap '[ -z "${CHUNK:-}" ] || rm -f "$CHUNK"' EXIT

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
    decisions_json=$(cscli decisions list -o json 2>/dev/null || true)
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
# is supposed to notice. The cursor carries the inode as well as the offset:
# logrotate (deploy/root/logrotate-stack-ids) renames the file and creates a new
# one, and a same-size-or-larger new file would otherwise be read from the old
# offset, skipping its beginning. A truncate still trips the size check. The
# offset always lands on a line boundary, so a line still being written is read
# whole next sweep rather than started mid-line.
ALERTS=0
LAST_ALERT=""
# eve=ok|missing|unreadable|na goes into the status file: "0 alerts" is only
# good news if the file was actually read. The guard used to be
# `[ -s "$EVE" ]` with no else, so a permission/SELinux problem, a missing jq,
# or an eve.json removed under a running sensor left ALERTS at 0, the verdict
# looked only at the engine states, and the roll-up said ok -- alert counting
# could be dead for as long as nobody looked. A missing feed is normal only when
# the sensor is not running.
EVE_STATE=na
if [ "$SURICATA_STATE" = active ]; then
    EVE_STATE=ok
    if [ ! -e "$EVE" ]; then
        EVE_STATE=missing
    elif [ ! -r "$EVE" ]; then
        EVE_STATE=unreadable
    elif ! size=$(stat -c %s "$EVE" 2>/dev/null); then
        EVE_STATE=unreadable
    else
        ino=$(stat -c %i "$EVE" 2>/dev/null || echo "")
        off=0
        cur=""
        [ -f "$CURSOR_FILE" ] && cur=$(cat "$CURSOR_FILE" 2>/dev/null)
        case "$cur" in
            *:*) cur_ino=${cur%%:*}; off=${cur#*:} ;;
            # A cursor from before inode tracking: trust the offset, do not re-read
            # the whole file once just because the format changed.
            *)   cur_ino="$ino"; off="$cur" ;;
        esac
        case "$off" in ''|*[!0-9]*) off=0 ;; esac
        if [ -n "$ino" ] && [ "$cur_ino" != "$ino" ]; then off=0; fi
        if [ "$size" -lt "$off" ]; then off=0; fi
        if [ "$size" -gt "$off" ]; then
            # Read exactly the window [off, size) -- never "to EOF". The file is
            # being appended to while this runs: tail-to-EOF counted alerts past
            # size and then rewound the cursor to size, so the next sweep counted
            # them again. dd's byte-count flags bound the read, and unlike
            # `tail | head` they do not fail on a SIGPIPE at the boundary.
            #
            # -R + fromjson? so a torn final line (an unfinished write) is
            # skipped instead of failing the whole stream. Only the signature is
            # printed, not signature_id: the id was in the stream as a second
            # tab-separated field once, and `read -a` splits on tabs as well as
            # spaces, so LAST_ALERT came back as "2010936" while the message
            # claimed it was the signature. Two fields, count and signature, and
            # `read` with two names keeps the rest of the line (spaces and all).
            window=$((size - off))
            CHUNK=""
            if ! CHUNK=$(mktemp "$AUDIT_DIR/.ids-chunk.XXXXXX" 2>/dev/null); then
                CHUNK=""
                EVE_STATE=unreadable
            elif dd if="$EVE" of="$CHUNK" iflag=skip_bytes,count_bytes \
                    skip="$off" count="$window" 2>/dev/null; then
                if raw=$(jq -Rr 'fromjson? | select(.event_type == "alert") | .alert.signature' \
                        < "$CHUNK" 2>/dev/null \
                        | awk '{n++; last=$0} END {print n+0 "\t" last}'); then
                    read -r ALERTS LAST_ALERT <<< "$raw"
                    ALERTS="${ALERTS:-0}"
                    LAST_ALERT="${LAST_ALERT:-}"
                    case "$ALERTS" in ''|*[!0-9]*) ALERTS=0 ;; esac
                    # Advance only over COMPLETE lines: if size lands inside a
                    # line, that line is re-read whole next sweep instead of
                    # being started mid-line and dropped by fromjson?. The inode
                    # is re-checked because logrotate may have replaced the file
                    # between the stat above and this read; a changed inode means
                    # the next sweep must start at 0, not at this offset.
                    consumed=$(complete_line_bytes "$CHUNK") || consumed=0
                    if [ "$consumed" -gt 0 ] \
                        && [ "$(stat -c %i "$EVE" 2>/dev/null || echo "")" = "$ino" ]; then
                        printf '%s:%s\n' "$ino" "$((off + consumed))" > "$CURSOR_FILE"
                    fi
                else
                    EVE_STATE=unreadable
                fi
            else
                EVE_STATE=unreadable
            fi
            [ -z "$CHUNK" ] || { rm -f "$CHUNK"; CHUNK=""; }
        fi
    fi
fi
if [ "$EVE_STATE" = na ]; then
    say "suricata alerts since the last run: $ALERTS${LAST_ALERT:+ (last: $LAST_ALERT)}"
else
    say "suricata alerts since the last run: $ALERTS${LAST_ALERT:+ (last: $LAST_ALERT)} (eve=$EVE_STATE)"
fi

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
# The sensor being up is not the same as its output being readable: without this
# the counters above are zero because nothing was read, not because nothing
# happened, and ok_epoch would keep advancing.
case "$EVE_STATE" in
    ok|na) ;;
    missing)    problem="${problem:+$problem; }suricata is active but $EVE is missing" ;;
    unreadable) problem="${problem:+$problem; }suricata is active but $EVE could not be read" ;;
esac

result=ok
[ -n "$problem" ] && result=fail

status_write "$STATUS_FILE" \
    "# written by scripts/ids.sh (deploy/ids.timer)" \
    "$result" "$problem" \
    "suricata=$SURICATA_STATE" "crowdsec=$CROWDSEC_STATE" \
    "alerts=$ALERTS" "decisions=$DECISIONS" "eve=$EVE_STATE"

printf '%s result=%s suricata=%s crowdsec=%s eve=%s alerts=%d decisions=%d%s\n' \
    "$(date -Is)" "$result" "$SURICATA_STATE" "$CROWDSEC_STATE" "$EVE_STATE" "$ALERTS" "$DECISIONS" \
    "${problem:+ -- $problem}" >> "$AUDIT_LOG"

[ "$result" = ok ] || { printf 'ids: %s\n' "$problem" >&2; exit 1; }
say "ok"
