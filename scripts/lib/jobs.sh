# shellcheck shell=bash
# The scheduled job contract: one status-file reader, one verdict judge, the
# textfile writer the metrics collector feeds, and the two external reads
# monitor.sh judges on (docs/alerting.md, docs/backup.md).

# Write a Prometheus textfile for node-exporter's textfile collector: stdin -> a
# .prom file, atomically, with the permissions the exporter needs (write_atomic
# in deploy/root/status.sh says why 0755/0644):
#   printf 'stack_x 1\n' | prom_write "$DATA_DIR/monitoring/textfile/stack.prom"
prom_write() {
    write_atomic "$1" 644 755
}

# A label value for that textfile. A daemon message carries quotes, backslashes
# and newlines, and node-exporter rejects the WHOLE textfile over one malformed
# line -- so the detail is escaped here rather than at each writer, and a
# newline becomes a separator (the format has no escape for a literal newline).
prom_label_value() { # text -> escaped for label="..."
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

# Read one of those status files: the primitive under verdict_judge, and what
# verify.sh's lighter checks use when they want the result without a threshold.
#
# Sets STATUS_RESULT, STATUS_AGE_S and STATUS_DETAIL rather than printing a line:
# a delimiter-separated line cannot carry the empty fields this read exists for
# (a failure with no detail, a skip before the first success), because `read`
# collapses runs of a whitespace IFS. The age is empty when no success is
# recorded or ok_epoch is not a number, and floored at 0 so a clock that stepped
# back reads "just now" rather than a negative age that passes every threshold.
# A missing file leaves all three empty.
# shellcheck disable=SC2034  # set for the caller to read after this returns
status_verdict() { # file -> STATUS_RESULT, STATUS_AGE_S, STATUS_DETAIL
    local ok
    STATUS_RESULT=""; STATUS_AGE_S=""; STATUS_DETAIL=""
    [ -f "$1" ] || return 0
    STATUS_RESULT=$(env_value "$1" result)
    STATUS_DETAIL=$(env_value "$1" detail)
    ok=$(env_value "$1" ok_epoch)
    case "$ok" in
        ''|*[!0-9]*) ;;
        *) STATUS_AGE_S=$(( $(date +%s) - ok ))
           [ "$STATUS_AGE_S" -ge 0 ] || STATUS_AGE_S=0 ;;
    esac
}

# --- judging a verdict, for the sweep and verify.sh -------------------------
# One scheduled job's file, judged the one way: no file yet, failed, stale,
# skipped, ok. The job-specific parts are the path, how bad its failure is, how
# old is too old, the noun in the message and what to look at -- everything else
# is identical for every job and lives here, so the next scheduled job does not
# cost a copied block whose branch order can drift from its neighbours'.
#
# An outcome of absent/fail/stale/skip prints one line; ok prints none, on
# purpose: the ok line carries the job's own numbers ("IDS: 3 alert(s), 1
# decision(s)"), which is the job's point rather than this function's.
#
# VERDICT_PAGE/VERDICT_WARN name the printers, so this file calls no script's
# function by name -- monitor.sh points them at fail/soft. `severity` is `fail`
# for a job whose failure is the host's problem and `soft` for one whose failure
# is a missing notification.
VERDICT_OUTCOME=""
VERDICT_PAGE=fail
VERDICT_WARN=soft

# A number from an env file or a status field, or the caller's default when it
# is unset or not numeric. Shared by monitor.sh (thresholds, counters) and
# verify.sh (the counts it prints), so "missing reads as the default" is one rule.
num_or() { # value default
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}

# A duration in the unit the threshold is stated in, so a 5-minute job reads
# "5 min" and a weekly one "192h" rather than 11520 minutes.
verdict_span() { # seconds max-seconds -> "12h" / "5 min"
    if [ "$2" -ge 3600 ] && [ $(( $2 % 3600 )) -eq 0 ]; then
        printf '%s' "$(( $1 / 3600 ))h"
    else
        printf '%s' "$(( $1 / 60 )) min"
    fi
}

_verdict_report() { # severity text
    case "$1" in
        fail) "$VERDICT_PAGE" "$2" ;;
        *)    "$VERDICT_WARN" "$2" ;;
    esac
}

#   verdict_judge "$IDS_STATUS_FILE" fail "$(verdict_age ids)" "IDS roll-up" \
#       "see $AUDIT_LOG" "ids.timer stopped, or ids.sh cannot read the sensor"
#
# HINT is what to read about a failure (a log, the file itself); AGE-HINT is what
# to check about the schedule, and defaults to HINT. They differ because a
# failure and a stopped timer are different questions.
verdict_judge() { # path severity max-age-s noun [hint] [age-hint]
    local path="$1" sev="$2" max="$3" noun="$4" hint="${5:-}" agehint="${6:-${5:-}}"
    VERDICT_OUTCOME=""
    if [ ! -f "$path" ]; then
        VERDICT_OUTCOME=absent
        "$VERDICT_WARN" "no $noun yet (expected until its timer first runs)"
        return 0
    fi
    status_verdict "$path"
    if [ "$STATUS_RESULT" = fail ]; then
        VERDICT_OUTCOME=fail
        _verdict_report "$sev" \
            "$noun failed: ${STATUS_DETAIL:-no detail}${hint:+; $hint}"
    elif [ -z "$STATUS_AGE_S" ]; then
        # A verdict with no ok_epoch: nothing has ever succeeded, so there is no
        # age to judge. Same outcome as a missing file (absent), different text.
        VERDICT_OUTCOME=absent
        "$VERDICT_WARN" \
            "$noun has no recorded success yet${STATUS_DETAIL:+ ($STATUS_DETAIL)}"
    elif [ "$STATUS_AGE_S" -gt "$max" ]; then
        VERDICT_OUTCOME=stale
        _verdict_report "$sev" \
            "no successful $noun for $(verdict_span "$STATUS_AGE_S" "$max") (threshold $(verdict_span "$max" "$max"), last result ${STATUS_RESULT:-?})${agehint:+; $agehint}"
    elif [ "$STATUS_RESULT" = skip ]; then
        # Skipped is not healthy and not a failure: the last SUCCESS is still
        # carried in ok_epoch, so a run of skips fails the age check above.
        VERDICT_OUTCOME=skip
        "$VERDICT_WARN" \
            "$noun skipped: ${STATUS_DETAIL:-no detail} (last success $(verdict_span "$STATUS_AGE_S" "$max") ago)"
    else
        # shellcheck disable=SC2034  # set for the caller to read after this returns
        VERDICT_OUTCOME=ok
    fi
}

# How old the newest restic snapshot is, and how many there are -- one read of
# `backup.sh list --json` for monitor.sh (age and count) and rotate.sh (refuses
# to rotate the restic password without a recent backup). Prints
# "count<TAB>newest-epoch"; non-zero means the repository could not be listed AT
# ALL, which is not "no snapshots yet".
restic_snapshot_summary() { # -> "count<TAB>newest-epoch"
    local backup="${REPO_DIR:-}/scripts/backup.sh" json latest count epoch=""
    [ -n "${REPO_DIR:-}" ] || return 1
    json=$("$backup" list --json 2>/dev/null) || return 1
    printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
    count=$(printf '%s' "$json" | jq 'length' 2>/dev/null) || return 1
    latest=$(printf '%s' "$json" | jq -r 'map(.time) | max // empty' 2>/dev/null) || return 1
    [ -z "$latest" ] || epoch=$(date -d "$latest" +%s 2>/dev/null || true)
    printf '%s\t%s' "$count" "$epoch"
}

# The receiver a config's default route sends to, and whether that receiver has
# a live email_configs. "Alerting is inert" must key on the paging path, not on
# any email_configs in the file: filling in only the signups sub-route pages
# nobody, and a file-wide grep would go quiet anyway.
# shellcheck disable=SC2034  # set for the caller to read after this returns
alertmanager_paging() { # config -> AM_RECEIVER, AM_PAGING=1|0
    AM_RECEIVER=""
    AM_PAGING=0
    [ -r "$1" ] || return 0
    AM_RECEIVER=$(awk '
        /^route:[[:space:]]*(#.*)?$/ { inroute = 1; next }
        inroute && /^[^[:space:]#]/ { inroute = 0 }
        inroute && /^[[:space:]]+receiver:[[:space:]]*/ {
            v = $0
            sub(/^[[:space:]]+receiver:[[:space:]]*/, "", v)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/["\047]/, "", v)
            print v
            exit
        }
    ' "$1")
    [ -n "$AM_RECEIVER" ] || return 0
    if awk -v want="$AM_RECEIVER" '
        /^receivers:[[:space:]]*(#.*)?$/ { inlist = 1; next }
        inlist && /^[^[:space:]#]/ { inlist = 0 }
        inlist && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
            v = $0
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", v)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/["\047]/, "", v)
            inrecv = (v == want)
            next
        }
        inrecv && /^[[:space:]]*email_configs:/ { found = 1; exit }
        END { exit !found }
    ' "$1"; then
        AM_PAGING=1
    fi
    return 0
}
