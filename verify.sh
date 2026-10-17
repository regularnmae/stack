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
# Run it on the host: it reads the containers with podman and reaches each MCP
# server the way nginx-proxy-manager does -- as <container>:8000 on npm-network,
# from a throwaway netcheck container (no service publishes a host port).
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

# The public host the MCP servers are proxied under (path prefix per server).
MCP_HOST="${MCP_HOST:-mcp.boltmesh.net}"

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
        postgres boltmesh-backend boltmesh-worker boltmesh-frontend
    )
else
    containers=(
        bitcoind monerod monero-wallet-rpc lightningd
        tor valkey searxng nginx-proxy-manager
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp
        postgres boltmesh-backend boltmesh-worker boltmesh-frontend
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
# name|env-file|token-var|deep-tool|deep-args|needs-nodes
# The name is both the container name and the host nginx-proxy-manager proxies
# to, so this checks the request path a real client takes.
endpoints=(
    "searxng-mcp|$CONFIG_DIR/searxng-mcp/token.env|SEARXNG_MCP_TOKEN|get_time|{\"tz\":\"UTC\"}|0"
    "bitcoin-node-mcp|$CONFIG_DIR/bitcoin-node-mcp/token.env|BITCOIN_MCP_TOKEN|get_blockchain_info|{}|1"
    "monero-node-mcp|$CONFIG_DIR/monero-node-mcp/token.env|MONERO_MCP_TOKEN|get_info|{}|1"
    "monero-wallet-mcp|$CONFIG_DIR/monero-wallet-mcp/token.env|MONERO_MCP_TOKEN|get_balance|{}|1"
    "lightning-mcp|$CONFIG_DIR/lightning-mcp/token.env|LIGHTNING_MCP_TOKEN|getinfo|{}|1"
)

# The token each container's endpoint needs, keyed by container name, so the
# through-nginx-proxy-manager section below can reuse it.
declare -A EP_ENV=() EP_VAR=()

for e in "${endpoints[@]}"; do
    IFS='|' read -r name envfile var tool args needs_nodes <<<"$e"
    EP_ENV["$name"]="$envfile"
    EP_VAR["$name"]="$var"

    # Read from a throwaway curl container on npm-network: no service publishes
    # a host port, so this is also the path nginx-proxy-manager takes (net_curl
    # and the mcp_* helpers live in scripts/lib.sh).
    health=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$name:8000/health" 2>/dev/null || echo 000)
    if [ "$health" = "200" ]; then pass "$name /health 200"; else bad "$name /health -> $health"; fi

    gated=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "http://$name:8000/mcp" \
        -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)
    if [ "$gated" = "401" ]; then pass "$name /mcp is token-gated (401)"; else bad "$name /mcp without a token -> $gated (expected 401)"; fi

    token=$(env_value "$envfile" "$var")
    if [ -z "$token" ]; then
        bad "$name has no token in $envfile"
        continue
    fi

    if mcp_initialize "$name" "$token" 15 >/dev/null; then
        pass "$name authenticated MCP handshake"
    else
        bad "$name authenticated handshake failed"
    fi

    if [ "$DEEP" = 1 ]; then
        if [ "$NO_NODES" = 1 ] && [ "$needs_nodes" = 1 ]; then
            warn "$name deep check skipped (needs a chain node)"
        else
            # mcp_tool_call reuses the session mcp_initialize just opened.
            resp=$(mcp_tool_call "$name" "$token" "$tool" "$args" 30 || true)
            if printf '%s' "$resp" | grep -q '"isError":true'; then
                bad "$name deep call $tool returned an error"
            elif printf '%s' "$resp" | grep -q '"result"'; then
                pass "$name deep call $tool returned data"
            else
                bad "$name deep call $tool: no result"
            fi
        fi
    fi
done

# ---------------------------------------------------------------------------
head2 "MCP through nginx-proxy-manager"
# The path a real client takes: https://$MCP_HOST/<prefix> -> <container>:8000/mcp.
# Read through NPM's own :80 with the Host header, so this works before public
# DNS and TLS exist. A configured host answers 401 without a token and a
# serverInfo handshake with one; an unconfigured one (NPM's default host) does
# neither, which is a warning rather than a failure until it is set up.
if [ "${MCP_HOSTS+x}" != x ] || [ "${#MCP_HOSTS[@]}" -eq 0 ]; then
    warn "MCP_HOSTS is not set in stack.conf; skipping the proxy checks"
else
    for pair in "${MCP_HOSTS[@]}"; do
        prefix="${pair%%:*}"; name="${pair##*:}"
        # Probe the public URL but connect to NPM itself (--connect-to), so this
        # works before public DNS exists and the certificate still validates:
        # SNI and Host are the real host, only the connection target changes.
        url="http://$MCP_HOST$prefix"
        connect="$MCP_HOST:80:nginx-proxy-manager:80"
        code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 --connect-to "$connect" \
            -X POST "$url" -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)
        [ -n "$code" ] || code=000
        # Force-SSL makes the :80 vhost redirect; follow it to the :443 one.
        case "$code" in
            301|308)
                url="https://$MCP_HOST$prefix"
                connect="$MCP_HOST:443:nginx-proxy-manager:443"
                code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 --connect-to "$connect" \
                    -X POST "$url" -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)
                [ -n "$code" ] || code=000 ;;
        esac
        case "$code" in
            401) ;;
            000|404|502|503)
                warn "$MCP_HOST$prefix is not proxied yet ($code); run scripts/npm-mcp-hosts.sh"
                continue ;;
            *) bad "$MCP_HOST$prefix without a token -> $code (expected 401)"; continue ;;
        esac
        pass "$MCP_HOST$prefix is token-gated (401)"

        token=$(env_value "${EP_ENV[$name]:-}" "${EP_VAR[$name]:-}")
        if [ -z "$token" ]; then bad "$name has no token; cannot handshake through NPM"; continue; fi
        resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
            | net_curl -s -m 15 -K - --connect-to "$connect" \
                -H 'Content-Type: application/json' \
                -H 'Accept: application/json, text/event-stream' \
                -X POST "$url" -d "$MCP_INIT_BODY" 2>/dev/null || true)
        if printf '%s' "$resp" | grep -q '"serverInfo"'; then
            pass "$MCP_HOST$prefix authenticated handshake"
        else
            bad "$MCP_HOST$prefix authenticated handshake failed"
        fi
    done
fi

# ---------------------------------------------------------------------------
head2 "BoltMesh"
# The API's /health is deep: 200 only when it can reach postgres and valkey.
# Read as a peer on npm-network, the same address nginx-proxy-manager uses.
be_body=$(net_curl -s -m 10 "http://boltmesh-backend:8000/health" 2>/dev/null || true)
if printf '%s' "$be_body" | grep -q '"status": *"healthy"'; then
    pass "boltmesh-backend /health healthy"
else
    bad "boltmesh-backend /health not healthy"
fi
fe_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 "http://boltmesh-frontend:80/" 2>/dev/null || echo 000)
if [ "$fe_code" = "200" ]; then pass "boltmesh-frontend / 200"; else bad "boltmesh-frontend / -> $fe_code"; fi

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
