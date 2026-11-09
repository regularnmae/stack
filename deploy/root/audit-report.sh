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
# config) -- host-level changes that no script in this repo makes. stack_data
# events are counted and shown but never fail the run: bootstrap and
# `scripts/rotate.sh` write them on purpose, and a monitor that pages on its own
# deploy is a monitor nobody reads.
set -uo pipefail

ENV_FILE=/etc/stack-ids/audit.env
# shellcheck source=/dev/null
. "$ENV_FILE"   # DATA_DIR

# The status-file writer, installed beside this script by install.sh --root.
if [ ! -r /etc/stack-ids/status.sh ]; then
    printf 'ERROR: /etc/stack-ids/status.sh is missing; re-run sudo ./bootstrap.sh\n' >&2
    exit 1
fi
# shellcheck source=status.sh
. /etc/stack-ids/status.sh

STATUS="$DATA_DIR/audit/auditd.status"
CURSOR="$DATA_DIR/audit/auditd.cursor"
# What ausearch/aureport read. Its absence is the ordinary state on a host whose
# kernel audit subsystem is inert (see the verdict at the end of this file): there
# is nothing recorded, so there is no window to lose.
AUDIT_LOG=/var/log/audit/audit.log
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
# ... but aureport and ausearch take the window as TWO arguments, a date and a
# time: `--start "11/01/2026 17:38:06"` is refused with "Invalid start time ...
# Hour, Minute, and Second are required", and `2>/dev/null || true` is why that
# went unnoticed -- every count below came back empty.
since_date=$(date -d "@$since_epoch" '+%m/%d/%Y' 2>/dev/null) || since_date=""
since_time=$(date -d "@$since_epoch" '+%H:%M:%S' 2>/dev/null) || since_time=""

# `aureport --key --summary` is a count per key over a window -- exactly the
# shape needed, and it does not require parsing event records ourselves. Its
# exit status is the only signal that the read happened at all: an empty summary
# from a live-looking log is a quiet window, not a failure.
summary=""
read_state=ok
if ! summary=$(aureport --key --summary --no-config --start "$since_date" "$since_time" 2>/dev/null); then
    summary=""
    # A missing or empty log is not a failed read. aureport exits 1 when there is
    # no /var/log/audit/audit.log at all, which on this class of host is the
    # inert subsystem rather than an error -- pinning the cursor there would make
    # the window grow for events that do not exist.
    if [ -s "$AUDIT_LOG" ]; then
        read_state=failed
    fi
fi

count_key() { # key
    printf '%s\n' "$summary" | awk -v k="$1" '$2 == k { print $1 }' | tail -1
}

hard=$(count_key stack_hard)
data=$(count_key stack_data)
case "$hard" in ''|*[!0-9]*) hard=0 ;; esac
case "$data" in ''|*[!0-9]*) data=0 ;; esac

# The summary above is read with --no-config, because loading the rule set makes
# the kernel emit a keyed CONFIG_CHANGE per rule added: counting those would fail
# the sweep on every bootstrap (measured here: three per reload, from
# `auditctl -R`).
#
# A removal is the opposite kind of event -- that is how someone blinds the host
# -- but the kernel spells it op=remove_rule (audit_log_rule_change("remove_rule",
# ...) from AUDIT_DEL_RULE), never op=del_rule, so the old grep here matched
# nothing. Fixing the pattern alone is not enough either: `install.sh --root`
# removes every loaded stack_ watch (`auditctl -W`) and reloads them on every
# run, so a deploy legitimately writes nine op=remove_rule events with
# key="stack_*". Counting those would page on our own deploy. So:
#   * removals of rules that are NOT ours are counted here -- an ALLEXEC rule or
#     a daemon's own rule disappearing is somebody else turning the light off;
#   * our own nine are checked as STATE below (what `auditctl -l` reports). That
#     is also the only check that notices a removal which is never reloaded.
# The one hole left is a remove+re-add inside a single window, which neither the
# event filter nor the state can tell from a deploy.
removed=$(ausearch --start "$since_date" "$since_time" -m CONFIG_CHANGE 2>/dev/null \
    | grep 'op=remove_rule' | grep -v 'key="stack_' | wc -l || true)
case "$removed" in ''|*[!0-9]*) removed=0 ;; esac
[ "$removed" -gt 0 ] && hard=$((hard + removed))

# The kernel's rule list is what "watching" means. The rendered file is the
# expectation: a shortfall is a watch that is gone, and a missing file (the same
# --root run that installed this script renders it) is audit's own config
# disappearing -- exactly what stack_hard exists for. A host with no auditctl at
# all (EL10 ships it in the audit-rules package) is reported as unavailable, not
# paged: those watches were never loaded to be lost.
RULES_FILE=/etc/audit/rules.d/60-stack.rules
rules_expected=0
rules_loaded=0
rules_detail=""
if [ -s "$RULES_FILE" ]; then
    rules_expected=$(grep -c -- '-k stack_' "$RULES_FILE" 2>/dev/null || true)
    case "$rules_expected" in ''|*[!0-9]*) rules_expected=0 ;; esac
else
    hard=$((hard + 1))
    rules_detail="audit rules file $RULES_FILE is missing"
fi
if [ -x /usr/sbin/auditctl ]; then
    rules_loaded=$(/usr/sbin/auditctl -l 2>/dev/null | grep -c -- '-k stack_' || true)
    case "$rules_loaded" in ''|*[!0-9]*) rules_loaded=0 ;; esac
    if [ "$rules_expected" -gt 0 ] && [ "$rules_loaded" -lt "$rules_expected" ]; then
        hard=$((hard + 1))
        rules_detail="${rules_detail:+$rules_detail; }${rules_loaded} of ${rules_expected} stack audit watch(es) loaded"
    fi
fi

detail=""
if [ "$hard" -gt 0 ]; then
    # The one-line evidence: which file, and what kind of operation. Enough to
    # decide whether to look, without pasting the whole event into an alert.
    detail=$(ausearch --start "$since_date" "$since_time" -k stack_hard -i 2>/dev/null \
        | grep -E '^(type=PROCTITLE|.*name=)' \
        | tail -3 | tr '\n' ' ')
fi
[ "$removed" -gt 0 ] && detail="${detail:+$detail }$removed audit rule(s) removed"
[ -n "$rules_detail" ] && detail="${detail:+$detail }$rules_detail"

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
FIM_DIRS="/etc/systemd/system /etc/containers/systemd /etc/sudoers.d /etc/cron.d /etc/ssh/sshd_config.d /etc/stack-ids /etc/audit/rules.d"
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
        # one (its hash moved).
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            fim_changes=$((fim_changes + 1))
            [ "$fim_changes" -le 5 ] && fim_detail="$fim_detail ${line##* }"
        done <<< "$(comm -13 <(sort "$FIM_BASELINE") <(sort "$current") 2>/dev/null)"
        # A path that is gone is counted too: the interesting direction in these
        # directories is a unit, a sudoers drop-in or an audit rule file
        # disappearing. Comparing PATHS for the removals (not the "hash  path"
        # lines) keeps a modified file from being counted twice, since its old
        # hash vanished and its new one appeared.
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            fim_changes=$((fim_changes + 1))
            [ "$fim_changes" -le 5 ] && fim_detail="$fim_detail ${path}(removed)"
        done <<< "$(comm -23 <(awk '{print $2}' "$FIM_BASELINE" | sort) \
            <(awk '{print $2}' "$current" | sort) 2>/dev/null)"
    fi
    # The baseline becomes the current state, so a change is reported once and
    # then is the new normal: this is a timeline for an operator, not a latch.
    if mv -f "$current" "$FIM_BASELINE" 2>/dev/null; then
        chmod 644 "$FIM_BASELINE" 2>/dev/null || true
    else
        rm -f "$current"
    fi
    if [ "$SHOW" = 1 ] && [ "$fim_changes" -gt 0 ]; then
        printf 'fim: %s change(s):%s\n' "$fim_changes" "$fim_detail"
    fi
fi

result=ok
[ "$hard" -gt 0 ] && result=fail

# Is the audit half actually live? This host boots with the kernel audit
# subsystem initialized disabled ("audit: initializing netlink subsys (disabled)",
# audit_enabled=0 in dmesg) and, although `auditctl -s` then reports
# enabled 1, no kernel record is ever written -- not even the CONFIG_CHANGE for
# loading the rules at boot. Measured across a reboot, so it is not leftover
# state: the watches are loaded and inert. Saying so is the difference between
# "nothing happened" and "nothing is being watched".
audit_state=live
if [ -x /usr/sbin/auditctl ]; then
    n_kern=$(ausearch -m CONFIG_CHANGE -ts boot 2>/dev/null | grep -c 'type=CONFIG_CHANGE' || true)
    if [ "$rules_loaded" -gt 0 ] && [ "${n_kern:-0}" -eq 0 ]; then
        audit_state=inert
    fi
elif [ "$rules_expected" -gt 0 ]; then
    # The rules file exists but nothing can load it: bootstrap installs
    # audit-rules and warns when it cannot, so say so here rather than call an
    # unloaded ruleset "live".
    audit_state=unavailable
fi

status_write "$STATUS" \
    "# written by /etc/stack-ids/audit-report.sh (stack-audit.timer)" \
    "$result" "$detail" \
    "hard=$hard" "data=$data" "fim=$fim_changes" \
    "watches=$rules_loaded/$rules_expected" \
    "audit=$audit_state" "read=$read_state"

# Only advance the cursor on a clean read: a failed ausearch must re-examine the
# same window next time rather than skip it. The evidence read (`ausearch`, only
# when stack_hard fired) is not part of the gate -- the counts above are what
# decide whether a window may be skipped. `read=failed` is in the status file,
# and the sweep reports it.
if [ "$read_state" = ok ]; then
    printf '%s\n' "$now" > "$CURSOR"
fi

if [ "$SHOW" = 1 ]; then
    printf 'since %s: hard=%s data=%s fim=%s audit=%s\n' "$since" "$hard" "$data" "$fim_changes" "$audit_state"
    [ -n "$detail" ] && printf 'hard detail: %s\n' "$detail"
fi

[ "$result" = ok ] || { printf 'audit: %s host-level change(s) since %s\n' "$hard" "$since" >&2; exit 1; }
exit 0
