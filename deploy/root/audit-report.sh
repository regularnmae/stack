#!/usr/bin/env bash
# Summarise the audit log into the one file the monitor reads.
#
# Runs as root from deploy/root/stack-audit.timer (every five minutes), installed
# to /etc/stack-ids/audit-report.sh. /var/log/audit/audit.log is root-only, so
# this is the only way an unprivileged monitor can see the events at all -- the
# same pattern as the backup drill's verdict and the bouncer's status.
#
#   /etc/stack-ids/audit-report.sh            summary into $DATA_DIR/audit/auditd.status
#   /etc/stack-ids/audit-report.sh --show     ... and print what it found
#
# The verdict is about stack_hard (account databases, sudoers, sshd, cron, audit
# config) -- host-level changes that no script in this repo makes. stack_tier and
# stack_data events are counted and shown but never fail the run: bootstrap and
# `scripts/rotate.sh` write them on purpose, and a monitor that pages on its own
# deploy is a monitor nobody reads.
set -uo pipefail

ENV_FILE=/etc/stack-ids/audit.env
# shellcheck source=/dev/null
. "$ENV_FILE"   # DATA_DIR

STATUS="$DATA_DIR/audit/auditd.status"
CURSOR="$DATA_DIR/audit/auditd.cursor"
SHOW=0
[ "${1:-}" = "--show" ] && SHOW=1

mkdir -p "$DATA_DIR/audit"

# Start from the last successful run, so a gap (a stopped timer, a reboot) is
# covered rather than skipped. Unknown/absent cursor = the last ten minutes,
# which is ausearch's own "recent".
since_epoch=""
[ -f "$CURSOR" ] && since_epoch=$(cat "$CURSOR" 2>/dev/null)
case "$since_epoch" in ''|*[!0-9]*) since_epoch=$(( $(date +%s) - 600 )) ;; esac
now=$(date +%s)
since=$(date -d "@$since_epoch" '+%m/%d/%Y %H:%M:%S' 2>/dev/null) \
    || since=$(date -d "-10 minutes" '+%m/%d/%Y %H:%M:%S')

# `aureport --key --summary` is a count per key over a window -- exactly the
# shape needed, and it does not require parsing event records ourselves.
summary=$(aureport --key --summary --start "$since" 2>/dev/null || true)

count_key() { # key
    printf '%s\n' "$summary" | awk -v k="$1" '$2 == k { print $1 }' | tail -1
}

hard=$(count_key stack_hard)
data=$(count_key stack_data)
tier=$(count_key stack_tier)
case "$hard" in ''|*[!0-9]*) hard=0 ;; esac
case "$data" in ''|*[!0-9]*) data=0 ;; esac
case "$tier" in ''|*[!0-9]*) tier=0 ;; esac

detail=""
if [ "$hard" -gt 0 ]; then
    # The one-line evidence: which file, and what kind of operation. Enough to
    # decide whether to look, without pasting the whole event into an alert.
    detail=$(ausearch --start "$since" -k stack_hard -i 2>/dev/null \
        | grep -E '^(type=PROCTITLE|.*name=)' \
        | tail -3 | tr '\n' ' ')
fi

# ---------------------------------------------------------------------------
# the hash diff: entry creation in the directories audit will not watch
# ---------------------------------------------------------------------------
# This kernel emits no events for a watch on a directory (see audit.rules), so a
# unit file, a sudoers.d drop-in or a cron job appearing would go unseen. Hashing
# the trees instead catches exactly that, and unlike an audit rule it names the
# file. Directories only; the files inside are small and few.
#
# Changes are reported, not paged, even in /etc/sudoers.d: `sudo ./bootstrap.sh`
# legitimately rewrites stack-bouncer.* and suricata.container every time it runs,
# and a monitor that pages on its own deploy stops being read. The count and the
# filenames go into the sweep; an unexplained one is what an operator looks at.
FIM_DIRS="/etc/systemd/system /etc/containers/systemd /etc/sudoers.d /etc/cron.d /etc/ssh/sshd_config.d /etc/stack-ids"
FIM_BASELINE="$DATA_DIR/audit/auditd.fim"
fim_changes=0
fim_detail=""
if [ -d /etc/systemd/system ]; then
    current=$(mktemp) || exit 1
    # A stable manifest: "hash  path" per regular file, so the comparison is about
    # content and not about inode or mtime churn.
    : > "$current"
    for d in $FIM_DIRS; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -type f -print0 2>/dev/null \
            | sort -z | xargs -0 -r sha256sum 2>/dev/null >> "$current"
    done
    if [ -s "$FIM_BASELINE" ]; then
        # Entries present now and not in the baseline: a new file, or a changed
        # one (its hash moved). Deletions are ordinary churn and are ignored.
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            fim_changes=$((fim_changes + 1))
            [ "$fim_changes" -le 5 ] && fim_detail="$fim_detail ${line##* }"
        done <<< "$(comm -13 <(sort "$FIM_BASELINE") <(sort "$current") 2>/dev/null)"
    fi
    # The baseline becomes the current state, so a change is reported once and
    # then is the new normal: this is a timeline for an operator, not a latch.
    if mv -f "$current" "$FIM_BASELINE" 2>/dev/null; then
        chmod 644 "$FIM_BASELINE" 2>/dev/null || true
    else
        rm -f "$current"
    fi
    if [ "$SHOW" = 1 ] && [ "$fim_changes" -gt 0 ]; then
        printf 'fim: %s new/changed file(s):%s\n' "$fim_changes" "$fim_detail"
    fi
fi

result=ok
[ "$hard" -gt 0 ] && result=fail

prev_ok=""
[ -f "$STATUS" ] && prev_ok=$(sed -n 's/^ok_epoch=//p' "$STATUS" | tail -1)
case "$prev_ok" in ''|*[!0-9]*) prev_ok="" ;; esac
if [ "$result" = ok ]; then ok_epoch="$now"; else ok_epoch="$prev_ok"; fi

tmp=$(mktemp "$DATA_DIR/audit/.auditd.XXXXXX") || exit 1
{
    printf '# written by /etc/stack-ids/audit-report.sh (stack-audit.timer)\n'
    printf 'time=%s\n' "$(date -Is)"
    printf 'epoch=%s\n' "$now"
    printf 'result=%s\n' "$result"
    printf 'ok_epoch=%s\n' "$ok_epoch"
    printf 'hard=%s\n' "$hard"
    printf 'tier=%s\n' "$tier"
    printf 'data=%s\n' "$data"
    printf 'fim=%s\n' "$fim_changes"
    printf 'detail=%s\n' "$(printf '%s' "$detail" | tr '\n' ' ')"
} > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$STATUS"

# Only advance the cursor on a clean read: a failed ausearch must re-examine the
# same window next time rather than skip it.
printf '%s\n' "$now" > "$CURSOR"

if [ "$SHOW" = 1 ]; then
    printf 'since %s: hard=%s tier=%s data=%s fim=%s\n' "$since" "$hard" "$tier" "$data" "$fim_changes"
    [ -n "$detail" ] && printf 'hard detail: %s\n' "$detail"
fi

[ "$result" = ok ] || { printf 'audit: %s host-level change(s) since %s\n' "$hard" "$since" >&2; exit 1; }
exit 0
