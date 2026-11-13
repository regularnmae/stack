#!/usr/bin/env bash
# stack-smart: read disk SMART health into the one file the monitor reads.
#
# Runs as root from deploy/root/stack-smart.timer (hourly), installed to
# /etc/stack-ids/smart.sh by `deploy/install.sh --root`. Opening a block device
# for SMART needs privileges the stack user does not have, so this is the same
# verdict-file pattern as stack-audit and stack-bouncer: root reads, the
# unprivileged monitor judges.
#
#   /etc/stack-ids/smart.sh            write $DATA_DIR/audit/smart.status
#   /etc/stack-ids/smart.sh --show     ... and print the per-disk summary
#
# The result is the probe's own verdict: fail when a disk cannot be opened or
# its overall SMART health is FAILED. Reallocated/pending sectors and
# temperature are facts -- scripts/monitor.sh compares them against the
# MONITOR_SMART_* thresholds, so tuning needs no root reinstall.
#
# A disk in standby is reported as `state=standby` and not woken (`-n
# standby,0`). SMART being unavailable behind a bridge is `state=unsupported`
# and a skip, not a failure: the monitor warns that the attributes cannot be
# read, while a block device that cannot be opened at all is a failure.
set -uo pipefail

ENV_FILE=/etc/stack-ids/smart.env
if [ ! -r "$ENV_FILE" ]; then
    printf 'ERROR: %s is missing; re-run sudo ./bootstrap.sh\n' "$ENV_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$ENV_FILE"   # DATA_DIR, optional SMART_DEVICES

if [ -z "${DATA_DIR:-}" ]; then
    printf 'ERROR: %s does not set DATA_DIR; re-run sudo ./bootstrap.sh\n' "$ENV_FILE" >&2
    exit 1
fi

# The status-file writer, installed beside this script by install.sh --root.
if [ ! -r /etc/stack-ids/status.sh ]; then
    printf 'ERROR: /etc/stack-ids/status.sh is missing; re-run sudo ./bootstrap.sh\n' >&2
    exit 1
fi
# shellcheck source=status.sh
. /etc/stack-ids/status.sh

STATUS="$DATA_DIR/audit/smart.status"
# The verdict file this run owns; deploy/root/status.sh owns the contract.
verdict_init "$STATUS" /etc/stack-ids/smart.sh stack-smart.timer

SHOW=0
[ "${1:-}" = "--show" ] && SHOW=1

mkdir -p "$DATA_DIR/audit"

TMP_JSON=$(mktemp) || { verdict_write fail "could not create a temporary file"; exit 1; }
TMP_ERR=$(mktemp) || { rm -f "$TMP_JSON"; verdict_write fail "could not create a temporary file"; exit 1; }
# A killed run must not leave the previous result=ok in place. The timer's
# TimeoutStartSec is the other half: a SIGKILL cannot run this, so the status
# age check backstops it (deploy/root/status.sh).
# shellcheck disable=SC2317  # invoked by the EXIT trap below
cleanup() {
    rm -f "$TMP_JSON" "$TMP_ERR"
    verdict_unrecorded "the SMART probe exited without recording a verdict"
}
trap cleanup EXIT

missing=""
command -v smartctl >/dev/null 2>&1 || missing="$missing smartctl"
command -v jq       >/dev/null 2>&1 || missing="$missing jq"
if [ -n "$missing" ]; then
    verdict_write skip "SMART probe cannot run: missing$missing (sudo dnf install -y smartmontools jq)"
    exit 0
fi

# The JSON fields the monitor and the tests read. One jq program so the field
# names and the fallbacks for a drive that exposes them differently are in one
# place:
#   * ATA attributes 5 and 197 are the reallocated and current-pending counts;
#   * temperature is the decoded value, then attribute 194, then the NVMe log;
#   * NVMe has media_errors instead of ATA realloc/pending.
smart_fields() { # json -> KEY=VALUE lines
    jq -r '
        def attr($id):
            ([.ata_smart_attributes.table[]? | select(.id == $id) | .raw.value] | first) // "";
        def temperature:
            ((.temperature.current)
             // ([.ata_smart_attributes.table[]? | select(.id == 194) | .raw.value] | first)
             // (.nvme_smart_health_information_log.temperature)) // "";
        # ATA: attributes 5/197. SCSI/SAS: the grown defect list is the
        # reallocated analogue, and the pending-defects log is the pending one
        # (SBC-4; not every drive implements it).
        def realloc:
            (attr(5) | if . == "" then null else . end) // (.scsi_grown_defect_list) // "";
        def pending:
            (attr(197) | if . == "" then null else . end) // (.scsi_pending_defects.count) // "";
        # SCSI has no pending-sector counter, but uncorrected read/write/verify
        # errors are the equivalent "the medium failed and the drive could not
        # fix it" signal. Sum the three pages.
        def uncorrected:
            ([.scsi_error_counter_log[]? | .total_uncorrected_errors] | add) // "";
        "health=" + (if .smart_status.passed == true then "PASSED"
                     elif .smart_status.passed == false then "FAILED"
                     else "UNKNOWN" end),
        "smart_support=" + (if .smart_support.available == true then "1"
                            elif .smart_support.available == false then "0"
                            else "" end),
        "mode=" + (.power_mode // ""),
        "protocol=" + (.device.protocol // ""),
        # model_name is set for ATA/NVMe and (since smartctl 7.x) SCSI; the
        # scsi_* fallbacks cover the older and RAID-passthrough shapes.
        "model=" + ((.model_name // .scsi_model_name // .scsi_product // "") | tostring),
        "serial=" + (.serial_number // ""),
        "rotation=" + ((.rotation_rate // "") | tostring),
        "realloc=" + ((realloc) | tostring),
        "pending=" + ((pending) | tostring),
        "uncorrected=" + ((uncorrected) | tostring),
        "temp=" + ((temperature) | tostring),
        "media_errors=" + ((.nvme_smart_health_information_log.media_errors // "") | tostring)
    ' "$1"
}

field() { # KEY=VALUE text key
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# Every device smartctl knows, as "name<TAB>type". SMART_DEVICES in smart.env
# pins the list (and the interface) for a bridge whose auto-detection is wrong:
#   SMART_DEVICES="/dev/sda:sat /dev/nvme0:nvme"
device_list() {
    local spec
    if [ -n "${SMART_DEVICES:-}" ]; then
        # shellcheck disable=SC2086  # a root-owned env file supplies the words
        for spec in $SMART_DEVICES; do
            case "$spec" in
                *:*) printf '%s\t%s\n' "${spec%%:*}" "${spec#*:}" ;;
                *)   printf '%s\t\n' "$spec" ;;
            esac
        done
        return 0
    fi
    smartctl --scan -j 2>/dev/null \
        | jq -r '.devices[]? | [.name, (.type // "")] | @tsv'
}

# smart_probe: set PROBE_RC, write JSON to $TMP_JSON, stderr to $TMP_ERR.
smart_probe() { # dev type
    local dev="$1" type="$2"
    # Empty both files first: a failed probe writes no JSON on some
    # smartctl/drive combinations, and the previous disk's answer must not be
    # read as this one's.
    : > "$TMP_JSON"
    : > "$TMP_ERR"
    if [ -n "$type" ]; then
        smartctl -j -H -A -i -l error -n standby,0 -d "$type" "$dev" > "$TMP_JSON" 2> "$TMP_ERR"
    else
        smartctl -j -H -A -i -l error -n standby,0 "$dev" > "$TMP_JSON" 2> "$TMP_ERR"
    fi
    PROBE_RC=$?
    return 0
}

# The interface to try, in order. --scan reports a SATA disk behind a SCSI
# bridge as `scsi` (this host's data disk does), and that type alone can hide
# the ATA attribute table. Try the scanned type first, then the SAT/ATA
# passthroughs, and keep the first answer that has health or attributes.
probe_types() { # dev scanned-type
    local dev="$1" type="$2"
    # `auto` is smartctl's own default; it also gives a pinned SMART_DEVICES
    # entry with no :type a first attempt.
    printf '%s\n' "${type:-auto}"
    case "$dev" in
        /dev/sd*|/dev/hd*)
            [ "$type" = sat ] || printf 'sat\n'
            [ "$type" = ata ] || printf 'ata\n'
            ;;
    esac
}

devices=$(device_list 2>/dev/null || true)
if [ -z "$devices" ]; then
    verdict_write skip "smartctl found no SMART-capable disks (see: smartctl --scan)"
    exit 0
fi

fields=("disks=0")
n=0
active=0
standby=0
unsupported=0
failed=0
detail=""

while IFS=$'\t' read -r dev type; do
    [ -n "$dev" ] || continue
    name=${dev##*/}
    best=""
    best_type=""
    state=""

    while IFS= read -r try_type; do
        [ -n "$try_type" ] || continue
        smart_probe "$dev" "$try_type"
        candidate=$(smart_fields "$TMP_JSON" 2>/dev/null || true)
        if [ -z "$candidate" ]; then
            # -n standby,0 exits 2 without a usable JSON body on some
            # smartctl/drive combinations; the message is still the proof.
            if [ "$PROBE_RC" = 2 ] \
               && grep -qiE 'STANDBY|SLEEP' "$TMP_JSON" "$TMP_ERR" 2>/dev/null; then
                state=standby
                break
            fi
            continue
        fi

        mode=$(field "$candidate" mode)
        case "$mode" in
            STANDBY|SLEEP)
                state=standby
                best=""
                break ;;
        esac

        health=$(field "$candidate" health)
        if [ "$health" = PASSED ] || [ "$health" = FAILED ]; then
            if [ -z "$best" ]; then
                best=$candidate
                best_type=$try_type
            fi
            # ATA attributes are the reason to prefer SAT/ATA over the scanned
            # `scsi` type. A drive with health but no table still counts as
            # readable; the monitor warns that the counters are unavailable.
            if [ -n "$(field "$candidate" realloc)" ] || [ -n "$(field "$candidate" pending)" ]; then
                best=$candidate
                best_type=$try_type
                break
            fi
        elif [ -n "$(field "$candidate" temp)" ] && [ -z "$best" ]; then
            best=$candidate
            best_type=$try_type
        elif [ "$(field "$candidate" smart_support)" = 0 ] && [ -z "$best" ]; then
            # The device answered and says SMART is unavailable (a bridge in
            # front of an ATA disk is the usual case). Keep it as the best
            # answer so the try of SAT/ATA can still win, but do not turn the
            # device's own limitation into a failed probe.
            best=$candidate
            best_type=$try_type
        fi
    done < <(probe_types "$dev" "$type")

    # /dev/bus/0 is a MegaRAID controller address, not a disk name: every
    # physical disk behind it would otherwise be labelled "0" and collide in the
    # monitor's per-device metrics. Use the bus and the passthrough type.
    case "$dev" in
        /dev/bus/*)
            name="bus${name}-$(printf '%s' "${best_type:-$type}" | tr ',' '-')" ;;
    esac

    if [ "$state" = standby ]; then
        standby=$((standby + 1))
        fields+=("disk${n}_dev=$dev" "disk${n}_name=$name" "disk${n}_state=standby")
        detail="${detail:+$detail; }$name: standby (not woken)"
    elif [ -n "$best" ]; then
        health=$(field "$best" health)
        if [ "$health" = FAILED ]; then
            failed=$((failed + 1))
            state=active
        elif [ "$health" = PASSED ]; then
            active=$((active + 1))
            state=active
        else
            unsupported=$((unsupported + 1))
            state=unsupported
        fi
        protocol=$(field "$best" protocol)
        model=$(field "$best" model)
        serial=$(field "$best" serial)
        rotation=$(field "$best" rotation)
        realloc=$(field "$best" realloc)
        pending=$(field "$best" pending)
        uncorrected=$(field "$best" uncorrected)
        temp=$(field "$best" temp)
        media=$(field "$best" media_errors)
        # A SCSI pass-through that does not implement SMART reports 0/0; that is
        # a missing reading, not a 0C disk. The monitor applies the same rule.
        [ "$temp" = 0 ] && temp=""
        fields+=(
            "disk${n}_dev=$dev"
            "disk${n}_name=$name"
            "disk${n}_type=$best_type"
            "disk${n}_state=$state"
            "disk${n}_health=$health"
            "disk${n}_protocol=$protocol"
            "disk${n}_model=$model"
            "disk${n}_serial=$serial"
            "disk${n}_rotation=$rotation"
            "disk${n}_realloc=$realloc"
            "disk${n}_pending=$pending"
            "disk${n}_uncorrected=$uncorrected"
            "disk${n}_temp=$temp"
            "disk${n}_media_errors=$media"
        )
        if [ "$state" = unsupported ]; then
            summary="$name: SMART unsupported"
        else
            summary="$name: ${health:-unknown}"
            [ -n "$temp" ] && summary="$summary ${temp}C"
        fi
        detail="${detail:+$detail; }$summary"
    else
        failed=$((failed + 1))
        state=error
        fields+=("disk${n}_dev=$dev" "disk${n}_name=$name" "disk${n}_state=error")
        err=$(head -n1 "$TMP_ERR" 2>/dev/null || true)
        detail="${detail:+$detail; }$name: unreadable (${err:-smartctl failed})"
    fi

    n=$((n + 1))
done <<< "$devices"

fields[0]="disks=$n"

if [ "$failed" -gt 0 ]; then
    result=fail
elif [ "$active" -gt 0 ] || [ "$standby" -gt 0 ]; then
    result=ok
else
    result=skip
fi

# A host whose only disk is in standby is healthy; the probe did not read it.
if [ "$result" = ok ] && [ "$active" -eq 0 ] && [ "$standby" -gt 0 ]; then
    detail="${detail:+$detail; }no disk was spinning, so no SMART attributes were read"
fi
[ -n "$detail" ] || detail="no SMART data"

verdict_write "$result" "$detail" "${fields[@]}"

if [ "$SHOW" = 1 ]; then
    printf '%s\n' "$detail"
fi

[ "$result" = fail ] && exit 1
exit 0
