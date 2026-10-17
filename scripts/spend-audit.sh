#!/usr/bin/env bash
# Spend tripwire for the two money servers (monero-wallet-mcp, lightning-mcp).
#
#   scripts/spend-audit.sh                 # check and report; non-zero on a trip
#   scripts/spend-audit.sh --rebaseline    # accept the current state as known-good
#
# Spending is OFF (ENABLE_SPENDING=0). This is what notices if that changes, or
# if a spend ever happens, without trusting the servers to log it:
#
#   1. policy drift -- a hash baseline of both spend.env files, both token
#      files and lightning-mcp/node.env (which holds the spend rune). Any edit
#      or removal trips. ENABLE_SPENDING must read 0 on every run regardless.
#   2. activity -- outgoing payments (lightning listpays) and outgoing
#      transfers (monero-wallet get_transfers, outgoing only), read through the
#      READ tokens and diffed against a stored baseline. A new entry trips.
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

REBASELINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --rebaseline) REBASELINE=1 ;;
        -h|--help)    usage_header "$0"; exit 0 ;;
        *)            die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

resolve_data_dir
AUDIT_DIR="$DATA_DIR/audit"
mkdir -p "$AUDIT_DIR"
BASELINE="$AUDIT_DIR/spend-baseline.tsv"
OUTGOING="$AUDIT_DIR/outgoing-baseline.txt"
SPEND_LOG="$AUDIT_DIR/spend.log"

# The config that decides whether money can move: both spend policies, both
# token files (the spend tokens live there) and node.env (the spend rune).
TRACKED=(
    "$CONFIG_DIR/monero-wallet-mcp/spend.env"
    "$CONFIG_DIR/monero-wallet-mcp/token.env"
    "$CONFIG_DIR/lightning-mcp/spend.env"
    "$CONFIG_DIR/lightning-mcp/token.env"
    "$CONFIG_DIR/lightning-mcp/node.env"
)

TRIPS=()
trip() { TRIPS+=("$*"); printf 'TRIP: %s\n' "$*"; }
note() { printf 'audit: %s\n' "$*"; }

# ---------------------------------------------------------------------------
# policy drift
# ---------------------------------------------------------------------------
# The baseline is a TSV of <absolute path> TAB <sha256>. It is append-only:
# a newly-seen file is added, but a changed one keeps its old hash so the trip
# repeats until --rebaseline (a deliberate act) accepts the new state.
if [ "$REBASELINE" = 1 ]; then
    : > "$BASELINE"
    for f in "${TRACKED[@]}"; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')" >> "$BASELINE"
    done
    note "rebaselined; the next run compares against this state"
    exit 0
fi

declare -A base_hash=()
if [ -s "$BASELINE" ]; then
    while IFS=$'\t' read -r p h; do
        [ -n "$p" ] && base_hash["$p"]="$h"
    done < "$BASELINE"
fi

added=()
for f in "${TRACKED[@]}"; do
    [ -f "$f" ] || continue
    h=$(sha256sum "$f" | awk '{print $1}')
    if [ -z "${base_hash[$f]:-}" ]; then
        added+=("$(printf '%s\t%s' "$f" "$h")")
        note "now tracking $f"
    elif [ "$h" != "${base_hash[$f]}" ]; then
        trip "spend config changed: $f"
    fi
done
# A baselined file that vanished is drift too (removing spend.env would have
# left the server to its own defaults).
for p in "${!base_hash[@]}"; do
    [ -f "$p" ] || trip "spend config removed: $p"
done
if [ "${#added[@]}" -gt 0 ]; then
    printf '%s\n' "${added[@]}" >> "$BASELINE"
fi

# The invariant, checked every run whatever the baseline says.
for env in "$CONFIG_DIR/monero-wallet-mcp/spend.env" "$CONFIG_DIR/lightning-mcp/spend.env"; do
    v=$(env_value "$env" ENABLE_SPENDING)
    if [ "$v" != "0" ]; then
        trip "ENABLE_SPENDING is '${v:-unset}' in $env (must be 0)"
    fi
done

# ---------------------------------------------------------------------------
# activity: outgoing payments (lightning) and transfers (monero)
# ---------------------------------------------------------------------------
lightning_outgoing() {
    local token body
    token=$(env_value "$CONFIG_DIR/lightning-mcp/token.env" LIGHTNING_MCP_TOKEN)
    [ -n "$token" ] || { note "no LIGHTNING_MCP_TOKEN; skipping lightning activity"; return 0; }
    body=$(mcp_call lightning-mcp "$token" listpays '{}') || body=""
    [ -n "$body" ] || { note "lightning listpays unavailable"; return 0; }
    printf '%s' "$body" \
        | grep -oE 'payment_hash\\?":[[:space:]]*\\?"[0-9a-f]{64}' \
        | grep -oE '[0-9a-f]{64}'
}

monero_outgoing() {
    local token body
    token=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
    [ -n "$token" ] || { note "no MONERO_MCP_TOKEN; skipping monero activity"; return 0; }
    body=$(mcp_call monero-wallet-mcp "$token" get_transfers \
        '{"incoming":false,"pool":false,"pending":false,"failed":false,"outgoing":true}') || body=""
    [ -n "$body" ] || { note "monero get_transfers unavailable"; return 0; }
    printf '%s' "$body" \
        | grep -oE 'txid\\?":[[:space:]]*\\?"[0-9a-f]{64}' \
        | grep -oE '[0-9a-f]{64}'
}

current=$({ lightning_outgoing; monero_outgoing; } | grep -v '^$' | sort -u)
if [ ! -e "$OUTGOING" ]; then
    { [ -n "$current" ] && printf '%s\n' "$current"; } > "$OUTGOING"
    note "recorded the outgoing baseline"
else
    # comm -13 = lines only in the current set, i.e. spends not seen before.
    new=$(comm -13 "$OUTGOING" <(printf '%s' "$current" | grep -v '^$') | grep -v '^$')
    if [ -n "$new" ]; then
        while IFS= read -r h; do
            trip "new outgoing spend: $h"
        done <<< "$new"
    fi
fi

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
