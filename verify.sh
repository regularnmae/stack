#!/usr/bin/env bash
# Verify the running stack.
#
#   ./verify.sh                 # shallow: container health + the MCP endpoints
#                               # are gated (401 without a token) and answer an
#                               # authenticated initialize handshake
#   ./verify.sh --deep          # additionally call one read tool per endpoint,
#                               # proving the path through to the daemon
#   ./verify.sh --no-nodes      # the chain daemons were skipped (deploy.sh
#                               # --skip-daemons); don't call them missing
#
# Read-only. Exits non-zero if anything is wrong.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
# The tokens live under the data dir now, so resolving it is how we find them.
resolve_data_dir

DEEP=0
NO_NODES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --deep)     DEEP=1 ;;
        --no-nodes) NO_NODES=1 ;;
        -h|--help)  usage_header "$0"; exit 0 ;;
        *)          printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

fails=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
head2() { printf '\n%s\n' "$*"; }

# ---------------------------------------------------------------------------
head2 "Containers"
if [ "$NO_NODES" = 1 ]; then
    warn "chain daemons skipped by request; not checking bitcoind/monerod/lightningd/monero-wallet-rpc"
    containers=(
        tor valkey searxng nginx-proxy-manager
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp
    )
else
    containers=(
        bitcoind monerod monero-wallet-rpc lightningd
        tor valkey searxng nginx-proxy-manager
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp
    )
fi
for c in "${containers[@]}"; do
    line=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
    if [ -z "$line" ]; then
        bad "$c is not running"
    elif printf '%s' "$line" | grep -q '(healthy)'; then
        pass "$c: $line"
    elif printf '%s' "$line" | grep -q '^Up'; then
        warn "$c: $line (no health status)"
    else
        bad "$c: $line"
    fi
done

# ---------------------------------------------------------------------------
head2 "MCP endpoints"
# name|port|env-file|token-var|deep-tool|deep-args|needs-nodes
endpoints=(
    "searxng-mcp|8000|$CONFIG_DIR/searxng-mcp/token.env|SEARXNG_MCP_TOKEN|get_time|{\"tz\":\"UTC\"}|0"
    "bitcoin-node-mcp|8101|$CONFIG_DIR/bitcoin-node-mcp/token.env|BITCOIN_MCP_TOKEN|get_blockchain_info|{}|1"
    "monero-node-mcp|8102|$CONFIG_DIR/monero-node-mcp/token.env|MONERO_MCP_TOKEN|get_info|{}|1"
    "monero-wallet-mcp|8103|$CONFIG_DIR/monero-wallet-mcp/token.env|MONERO_MCP_TOKEN|get_balance|{}|1"
    "lightning-mcp|8104|$CONFIG_DIR/lightning-mcp/token.env|LIGHTNING_MCP_TOKEN|getinfo|{}|1"
)
read -r -d '' init_body <<'JSON' || true
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}
JSON

for e in "${endpoints[@]}"; do
    IFS='|' read -r name port envfile var tool args needs_nodes <<<"$e"
    base="http://${VERIFY_HOST:-127.0.0.1}:$port"

    health=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$base/health" 2>/dev/null || echo 000)
    if [ "$health" = "200" ]; then pass "$name /health 200"; else bad "$name /health -> $health"; fi

    gated=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$base/mcp" \
        -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)
    if [ "$gated" = "401" ]; then pass "$name /mcp is token-gated (401)"; else bad "$name /mcp without a token -> $gated (expected 401)"; fi

    token=$(env_value "$envfile" "$var")
    if [ -z "$token" ]; then
        bad "$name has no token in $envfile"
        continue
    fi

    hdr=$(mktemp)
    body=$(curl -s -D "$hdr" -m 15 -X POST "$base/mcp" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "Authorization: Bearer $token" -d "$init_body" 2>/dev/null || true)
    if printf '%s' "$body" | grep -q '"serverInfo"'; then
        pass "$name authenticated MCP handshake"
    else
        bad "$name authenticated handshake failed"
    fi

    if [ "$DEEP" = 1 ]; then
        if [ "$NO_NODES" = 1 ] && [ "$needs_nodes" = 1 ]; then
            warn "$name deep check skipped (needs a chain node)"
        else
            sid=$(tr -d '\r' < "$hdr" | sed -n 's/^[Mm]cp-[Ss]ession-[Ii]d: *//p')
            call_body=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$tool" "$args")
            resp=$(curl -s -m 30 -X POST "$base/mcp" \
                -H 'Content-Type: application/json' \
                -H 'Accept: application/json, text/event-stream' \
                -H "Authorization: Bearer $token" \
                ${sid:+-H "mcp-session-id: $sid"} -d "$call_body" 2>/dev/null || true)
            if printf '%s' "$resp" | grep -q '"isError":true'; then
                bad "$name deep call $tool returned an error"
            elif printf '%s' "$resp" | grep -q '"result"'; then
                pass "$name deep call $tool returned data"
            else
                bad "$name deep call $tool: no result"
            fi
        fi
    fi
    rm -f "$hdr"
done

# ---------------------------------------------------------------------------
head2 "Backups"
BACKUP_TIMER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/backup.timer"
if [ -f "$BACKUP_TIMER" ]; then
    pass "backup.timer installed"
else
    bad "backup.timer is not installed (run deploy/install.sh)"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet backup.timer 2>/dev/null; then
    pass "backup.timer is active"
else
    warn "backup.timer is not active (systemctl --user status backup.timer)"
fi
if [ "$DEEP" = 1 ]; then
    # Freshness is best-effort and a fresh host legitimately has no snapshot, so
    # this only warns. A failure means the repository or password is wrong.
    if out=$("$REPO_DIR/scripts/backup.sh" snapshots 2>/dev/null) \
        && printf '%s' "$out" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        pass "backup repository has snapshots"
    else
        warn "no backup snapshots yet (expected until the first backup runs)"
    fi
fi

# ---------------------------------------------------------------------------
head2 "Monitoring"
MONITOR_TIMER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/monitor.timer"
if [ -f "$MONITOR_TIMER" ]; then
    pass "monitor.timer installed"
else
    bad "monitor.timer is not installed (run deploy/install.sh)"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet monitor.timer 2>/dev/null; then
    pass "monitor.timer is active"
else
    warn "monitor.timer is not active (systemctl --user status monitor.timer)"
fi
AUDIT_DIR="$DATA_DIR/audit"
if [ -d "$AUDIT_DIR" ]; then
    pass "audit dir present ($AUDIT_DIR)"
else
    warn "no audit dir yet ($AUDIT_DIR); the first monitor run creates it"
fi

# ---------------------------------------------------------------------------
head2 "Summary"
if [ "$fails" = 0 ]; then
    [ "$DEEP" = 1 ] || printf 'All shallow checks passed. Re-run with --deep once the chains are synced.\n'
    [ "$DEEP" = 1 ] && printf 'All checks passed.\n'
    exit 0
fi
printf '%d check(s) failed.\n' "$fails"
printf 'Logs:  podman logs <container>\n'
printf 'Units: systemctl --user status <service>.service\n'
exit 1
