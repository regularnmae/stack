#!/usr/bin/env bash
# Verify the running stack: every container healthy, every published port
# answering, and every MCP endpoint both gated (401 without a token) and
# working (an authenticated MCP initialize handshake).
#
# Read-only. Exits non-zero if anything is wrong, but prints the full table
# either way. Run it directly or from deploy.sh.
set -uo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

fails=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }
head2() { printf '\n%s\n' "$*"; }

token_from() { # env-file var-name
    [ -s "$1" ] && sed -n "s/^$2=//p" "$1" | head -n1 || true
}

# ---------------------------------------------------------------------------
head2 "Containers"
containers=(
    bitcoind monerod monero-wallet-rpc lightningd tor
    valkey searxng nginx-proxy-manager
    searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp
)
for c in "${containers[@]}"; do
    line=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
    if [ -z "$line" ]; then
        bad "$c is not running"
    elif printf '%s' "$line" | grep -q '(healthy)'; then
        pass "$c: $line"
    elif printf '%s' "$line" | grep -q '^Up'; then
        # No healthcheck defined (bitcoind, nginx-proxy-manager) or not yet past
        # the start period.
        warn "$c: $line (no health status)"
    else
        bad "$c: $line"
    fi
done

# ---------------------------------------------------------------------------
head2 "MCP endpoints"
# name:port:envfile:var
endpoints=(
    "searxng-mcp:8000:$CONFIG_HOME/searxng-mcp/token.env:SEARXNG_MCP_TOKEN"
    "bitcoin-node-mcp:8101:$CONFIG_HOME/bitcoin-node-mcp/token.env:BITCOIN_MCP_TOKEN"
    "monero-node-mcp:8102:$CONFIG_HOME/monero-node-mcp/token.env:MONERO_MCP_TOKEN"
    "monero-wallet-mcp:8103:$CONFIG_HOME/monero-wallet-mcp/token.env:MONERO_MCP_TOKEN"
    "lightning-mcp:8104:$CONFIG_HOME/lightning-mcp/token.env:LIGHTNING_MCP_TOKEN"
)
read -r -d '' init_body <<'JSON' || true
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}
JSON

for e in "${endpoints[@]}"; do
    IFS=: read -r name port envfile var <<<"$e"
    base="http://127.0.0.1:$port"

    health=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$base/health" 2>/dev/null || echo 000)
    [ "$health" = "200" ] && pass "$name /health 200" || bad "$name /health -> $health"

    gated=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$base/mcp" \
        -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)
    [ "$gated" = "401" ] && pass "$name /mcp is token-gated (401)" || bad "$name /mcp without a token -> $gated (expected 401)"

    token=$(token_from "$envfile" "$var")
    if [ -z "$token" ]; then
        bad "$name has no token in $envfile"
        continue
    fi
    body=$(curl -s -m 15 -X POST "$base/mcp" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "Authorization: Bearer $token" -d "$init_body" 2>/dev/null || true)
    if printf '%s' "$body" | grep -q '"serverInfo"'; then
        pass "$name authenticated MCP handshake"
    else
        bad "$name authenticated handshake failed"
    fi
done

# ---------------------------------------------------------------------------
head2 "Summary"
if [ "$fails" = 0 ]; then
    printf 'All checks passed.\n'
    exit 0
fi
printf '%d check(s) failed.\n' "$fails"
printf 'Logs:  podman logs <container>\n'
printf 'Units: systemctl --user status <service>.service\n'
exit 1
