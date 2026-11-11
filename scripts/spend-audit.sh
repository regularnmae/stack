#!/usr/bin/env bash
# Spend tripwire for the two money servers (monero-wallet-mcp, lightning-mcp).
#
#   scripts/spend-audit.sh     # check and report; non-zero on a trip
#
# Spending is OFF (ENABLE_SPENDING=0). This is what notices if that changes, or
# if either server has ever sent money:
#
#   1. ENABLE_SPENDING must read 0 in both spend.env files, every run.
#   2. Neither server has an outgoing payment (lightning listpays) or transfer
#      (monero-wallet get_transfers). Any entry trips on every run: spending is
#      off, so there is nothing to accept and no baseline to keep.
#
# Trips are printed as "TRIP: ..." and appended to $DATA_DIR/audit/spend.log, so
# there is a record even when nothing alerts. This is not a gate -- it cannot
# stop a spend, only make one impossible to miss. Read-only otherwise.
#
# Run by scripts/monitor.sh, which folds any TRIP into the alert and heartbeat.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

case "${1:-}" in
    "")        ;;
    -h|--help) usage_header "$0"; exit 0 ;;
    *)         die "unknown argument: $1 (try --help)" ;;
esac

resolve_data_dir
command -v jq >/dev/null 2>&1 \
    || die "jq is required to read the MCP payloads (bootstrap.sh installs it)"
AUDIT_DIR="$DATA_DIR/audit"
mkdir -p "$AUDIT_DIR"
SPEND_LOG="$AUDIT_DIR/spend.log"

TRIPS=()
trip() { TRIPS+=("$*"); printf 'TRIP: %s\n' "$*"; }
# Notes go to stderr so they never look like output to a caller.
note() { printf 'audit: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# policy: spending must stay off
# ---------------------------------------------------------------------------
for env in "$CONFIG_DIR/monero-wallet-mcp/spend.env" "$CONFIG_DIR/lightning-mcp/spend.env"; do
    v=$(env_value "$env" ENABLE_SPENDING)
    if [ "$v" != "0" ]; then
        trip "ENABLE_SPENDING is '${v:-unset}' in $env (must be 0)"
    fi
done

# ---------------------------------------------------------------------------
# activity: outgoing payments (lightning) and transfers (monero)
# ---------------------------------------------------------------------------
# Both read through the server's READ token. A source that cannot be read is a
# note, not a trip: the monitor has its own checks for a server being down.
lightning_outgoing() {
    local token body payload
    token=$(env_value "$CONFIG_DIR/lightning-mcp/token.env" LIGHTNING_MCP_TOKEN)
    [ -n "$token" ] || { note "no LIGHTNING_MCP_TOKEN; skipping lightning activity"; return 0; }
    body=$(mcp_call lightning-mcp "$token" listpays '{}' 60) || body=""
    [ -n "$body" ] || { note "lightning listpays unavailable"; return 0; }
    payload=$(mcp_result "$body")
    [ -n "$payload" ] || { note "lightning listpays answered no JSON"; return 0; }
    printf '%s' "$payload" | jq -r '.pays[]?.payment_hash // empty' 2>/dev/null
}

monero_outgoing() {
    local token body payload
    token=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
    [ -n "$token" ] || { note "no MONERO_MCP_TOKEN; skipping monero activity"; return 0; }
    body=$(mcp_call monero-wallet-mcp "$token" get_transfers \
        '{"incoming":false,"pool":false,"pending":false,"failed":false,"outgoing":true}' 60) || body=""
    [ -n "$body" ] || { note "monero get_transfers unavailable"; return 0; }
    payload=$(mcp_result "$body")
    [ -n "$payload" ] || { note "monero get_transfers answered no JSON"; return 0; }
    printf '%s' "$payload" | jq -r '.out[]?.txid // empty' 2>/dev/null
}

while IFS= read -r h; do
    [ -n "$h" ] && trip "lightning has an outgoing payment: $h"
done < <(lightning_outgoing)
while IFS= read -r t; do
    [ -n "$t" ] && trip "monero-wallet has an outgoing transfer: $t"
done < <(monero_outgoing)

# ---------------------------------------------------------------------------
# the record
# ---------------------------------------------------------------------------
{
    printf '%s spend-audit\n' "$(date -Is)"
    if [ "${#TRIPS[@]}" -gt 0 ]; then
        printf '  TRIP: %s\n' "${TRIPS[@]}"
    else
        printf '  clean\n'
    fi
} >> "$SPEND_LOG"

if [ "${#TRIPS[@]}" -gt 0 ]; then
    printf 'spend-audit: %d trip(s); see %s\n' "${#TRIPS[@]}" "$SPEND_LOG" >&2
    exit 1
fi
exit 0
