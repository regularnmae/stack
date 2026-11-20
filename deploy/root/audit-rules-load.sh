#!/usr/bin/env bash
# Load the audit rules through the duplicate-tolerant wrapper.
#
# The distro's audit-rules.service runs `augenrules --load`. Re-running it after
# install.sh has already loaded the same rules fails at the first duplicate:
#
#   Error sending add rule data request (Rule exists)
#   There was an error in line 5 of /etc/audit/audit.rules
#
# The rules are already in the kernel, so the unit is not broken -- but systemd
# records exit 1, and `systemctl --failed` then contradicts the audit report.
# This wrapper treats exactly that pair as success and nothing else: an unmounted
# data directory (ENOENT), a permission error or a malformed rule still fails.
#
# The stack's own watch count is not proved here; deploy/root/audit-report.sh
# compares 60-stack.rules with auditctl -l and monitor.sh pages on a shortfall.
set -uo pipefail

AUGENRULES="${AUGENRULES:-/usr/sbin/augenrules}"
out=$("$AUGENRULES" --load 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    exit 0
fi

# `failure 1` from auditctl -s is informational, and "Old style watch rules are
# slower" is a notice; neither matches the error filter below.
unexpected=$(printf '%s\n' "$out" \
    | grep -E 'Error|error|failed|Failed|denied|Denied|No such|Invalid|invalid|Could not|could not|cannot|Cannot|unable|Unable|Permission|permission|not permitted|Operation' \
    | grep -vE '^[[:space:]]*Error sending add rule data request \(Rule exists\)[[:space:]]*$|^[[:space:]]*There was an error in line [0-9]+ of /etc/audit/[^[:space:]]+[[:space:]]*$' \
    || true)
if [ -z "$unexpected" ] \
    && printf '%s\n' "$out" | grep -qF 'Error sending add rule data request (Rule exists)'; then
    printf '%s\n' 'audit-rules: the ruleset is already loaded (Rule exists); treating the reload as success'
    exit 0
fi

printf '%s\n' "$out" >&2
exit "$rc"
