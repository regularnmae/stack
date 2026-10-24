#!/usr/bin/env bash
# Verify the running stack.
#
#   ./verify.sh                 # shallow: container health + the MCP endpoints
#                               # are gated (401 without a token) and answer an
#                               # authenticated initialize handshake; every
#                               # onion service in ONION_SERVICES answers through
#                               # tor too
#   ./verify.sh --deep          # additionally call one read tool per endpoint,
#                               # proving the path through to the daemon
#   ./verify.sh --no-nodes      # the chain daemons were skipped (deploy.sh
#                               # --skip-daemons); don't call them missing
#
# Run it on the host: it reads the containers with podman and reaches each MCP
# server on npm-network as <container>:8000, from a throwaway netcheck container
# (the app images carry no curl). The one exception is nginx-proxy-manager,
# which is on the host network -- it is read on 127.0.0.1, the same place it
# listens.
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
        tor valkey searxng uptime-kuma nginx-proxy-manager
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp
        postgres boltmesh-backend boltmesh-worker boltmesh-frontend
    )
else
    containers=(
        bitcoind monerod fulcrum monero-wallet-rpc lightningd
        tor valkey searxng uptime-kuma nginx-proxy-manager
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

# The exposure model in one line: NPM on the host network is what makes a
# client's real address reach its logs, fail2ban surface and X-Forwarded-For. A
# rootless published port cannot (rootlessport forwards from inside the rootless
# namespace, so NPM would see its own address), and that is also why every
# service it fronts publishes its port on the host's loopback instead.
npm_net=$(podman inspect nginx-proxy-manager --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)
if [ -z "$npm_net" ]; then
    warn "nginx-proxy-manager is not running; skipping the host-network check"
elif [ "$npm_net" = "host" ]; then
    pass "nginx-proxy-manager is on the host network (clients' real addresses)"
else
    bad "nginx-proxy-manager network mode is '$npm_net', expected host: NPM would log its own IP for every client"
fi

# ---------------------------------------------------------------------------
head2 "MCP endpoints"
# name|env-file|token-var|deep-tool|deep-args|needs-nodes
# The name is the container name; it is read by name on npm-network, and it
# names the MCP_HOSTS entry whose loopback publish nginx-proxy-manager fronts.
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

    # Read from a throwaway curl container on npm-network (net_curl and the
    # mcp_* helpers live in scripts/lib.sh). This is the container's own
    # address; nginx-proxy-manager, on the host network, reaches the same
    # server through the loopback publish the unit declares.
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
# The path a real client takes: https://$MCP_HOST/<prefix> -> 127.0.0.1:<port>/mcp
# (NPM is on the host network, so the upstream is the loopback publish of that
# unit). Read through NPM's own :80 with the Host header, so this works before
# public DNS and TLS exist. A configured host answers 401 without a token and a
# serverInfo handshake with one; an unconfigured one (NPM's default host) does
# neither, which is a warning rather than a failure until it is set up.
if [ "${MCP_HOSTS+x}" != x ] || [ "${#MCP_HOSTS[@]}" -eq 0 ]; then
    warn "MCP_HOSTS is not set in stack.conf; skipping the proxy checks"
else
    for pair in "${MCP_HOSTS[@]}"; do
        prefix="${pair%%:*}"; rest="${pair#*:}"; name="${rest%%:*}"
        # Probe the public URL but connect to NPM itself (--connect-to), so this
        # works before public DNS exists and the certificate still validates:
        # SNI and Host are the real host, only the connection target changes.
        # NPM binds :80/:443 on the host itself, hence 127.0.0.1 here.
        url="http://$MCP_HOST$prefix"
        connect="$MCP_HOST:80:127.0.0.1:80"
        code=$(net_curl_host -s -o /dev/null -w '%{http_code}' -m 10 --connect-to "$connect" \
            -X POST "$url" -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)
        [ -n "$code" ] || code=000
        # Force-SSL makes the :80 vhost redirect; follow it to the :443 one.
        case "$code" in
            301|308)
                url="https://$MCP_HOST$prefix"
                connect="$MCP_HOST:443:127.0.0.1:443"
                code=$(net_curl_host -s -o /dev/null -w '%{http_code}' -m 10 --connect-to "$connect" \
                    -X POST "$url" -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)
                [ -n "$code" ] || code=000 ;;
        esac
        case "$code" in
            401) ;;
            000|404|502|503)
                warn "$MCP_HOST$prefix is not proxied yet ($code); run scripts/npm-hosts.sh"
                continue ;;
            *) bad "$MCP_HOST$prefix without a token -> $code (expected 401)"; continue ;;
        esac
        pass "$MCP_HOST$prefix is token-gated (401)"

        token=$(env_value "${EP_ENV[$name]:-}" "${EP_VAR[$name]:-}")
        if [ -z "$token" ]; then bad "$name has no token; cannot handshake through NPM"; continue; fi
        resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
            | net_curl_host -s -m 15 -K - --connect-to "$connect" \
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
head2 "Onion services (tor)"
# The same public surface without DNS or a certificate. tor publishes one hidden
# service per ONION_SERVICES entry (stack.conf) and forwards it; the address is
# read from tor's own data dir, because it is key material and not declared.
# The probe goes through tor's SOCKS port from a throwaway container on
# npm-network (torrc's SocksPolicy allows nothing else) and asks tor to resolve
# the .onion name itself (--socks5-hostname), exactly as a client does. A fresh
# service takes a minute to become reachable, so "no answer" is a warning.
# The mcp entry expects 401: that proves the whole onion -> NPM -> container path
# and the bearer-token gate, since NPM cannot match an onion by name (see
# ONION_SERVICES).
TOR_SOCKS="${TOR_SOCKS:-10.89.0.240:9050}"
if [ "${ONION_SERVICES+x}" != x ] || [ "${#ONION_SERVICES[@]}" -eq 0 ]; then
    warn "ONION_SERVICES is not set in stack.conf; skipping the onion checks"
else
    for entry in "${ONION_SERVICES[@]}"; do
        IFS='|' read -r name _target mirrors path expect <<<"$entry"
        addrfile="$DATA_DIR/tor/onion/$name/hostname"
        if [ ! -s "$addrfile" ]; then
            warn "onion $name ($mirrors): tor has published no address yet ($addrfile)"
            continue
        fi
        addr=$(tr -d '\r\n' < "$addrfile")
        code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 30 \
            --socks5-hostname "$TOR_SOCKS" "http://$addr$path" 2>/dev/null || true)
        [ -n "$code" ] || code=000
        case "$code" in
            "$expect")
                pass "$mirrors served at http://$addr$path ($code)" ;;
            000)
                warn "no answer for $mirrors at $addr (tor still publishing? give it a minute)" ;;
            *)
                bad "$mirrors at $addr$path -> $code (expected $expect)" ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
head2 "BoltMesh"
# The API's /health is deep: 200 only when it can reach postgres and valkey.
# Read as a peer on npm-network; nginx-proxy-manager, on the host network,
# reaches the same server through the unit's loopback publish.
be_body=$(net_curl -s -m 10 "http://boltmesh-backend:8000/health" 2>/dev/null || true)
if printf '%s' "$be_body" | grep -q '"status": *"healthy"'; then
    pass "boltmesh-backend /health healthy"
else
    bad "boltmesh-backend /health not healthy"
fi
fe_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 "http://boltmesh-frontend:80/" 2>/dev/null || echo 000)
if [ "$fe_code" = "200" ]; then pass "boltmesh-frontend / 200"; else bad "boltmesh-frontend / -> $fe_code"; fi

# ---------------------------------------------------------------------------
head2 "Status page"
# Uptime-Kuma serves its dashboard SPA at /; on npm-network it is a peer like
# the rest. The public path through nginx-proxy-manager is checked like the MCP
# hosts above, but it answers 200 (a login page) rather than 401 -- until the
# admin account exists and a status page is published, any 200 from the SPA
# still proves the proxy host is wired.
#
# A fresh v2 answers / with a 302 to /dashboard, so the probes follow
# redirects: the SPA (login included) and every published status page return
# 200 there. The scheme dance (80 -> 443, --connect-to pinned to NPM) is done
# by hand first, as in the MCP section; -L answers only kuma's own redirects.
kuma_code=$(net_curl -s -L -o /dev/null -w '%{http_code}' -m 15 "http://uptime-kuma:3001/" 2>/dev/null || echo 000)
if [ "$kuma_code" = "200" ]; then pass "uptime-kuma / 200 (after redirects)"; else bad "uptime-kuma / (following redirects) -> $kuma_code"; fi

if [ "${UPTIME_KUMA_HOST+x}" = x ] && [ -n "$UPTIME_KUMA_HOST" ]; then
    kurl="http://$UPTIME_KUMA_HOST/"
    kconnect="$UPTIME_KUMA_HOST:80:127.0.0.1:80"
    kcode=$(net_curl_host -s -o /dev/null -w '%{http_code}' -m 10 --connect-to "$kconnect" "$kurl" 2>/dev/null || true)
    [ -n "$kcode" ] || kcode=000
    case "$kcode" in
        301|308)
            kurl="https://$UPTIME_KUMA_HOST/"
            kconnect="$UPTIME_KUMA_HOST:443:127.0.0.1:443" ;;
    esac
    kcode=$(net_curl_host -s -L -o /dev/null -w '%{http_code}' -m 20 --connect-to "$kconnect" "$kurl" 2>/dev/null || true)
    [ -n "$kcode" ] || kcode=000
    case "$kcode" in
        200) pass "$UPTIME_KUMA_HOST serves the status page through nginx-proxy-manager" ;;
        000|404|502|503)
            warn "$UPTIME_KUMA_HOST is not proxied yet ($kcode); run scripts/npm-hosts.sh" ;;
        *) bad "$UPTIME_KUMA_HOST -> $kcode (expected 200)" ;;
    esac
fi

# A published status page answers its public data endpoint without auth -- so
# the check runs from the host by container name and needs no token. A 404
# means the page does not exist (yet), not that the monitor is broken: the
# reconciler (scripts/kuma-monitors.sh) creates and publishes it, or it is
# published in the UI.
if [ "${KUMA_STATUS_SLUG+x}" = x ] && [ -n "$KUMA_STATUS_SLUG" ]; then
    slug_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 \
        "http://uptime-kuma:3001/api/status-page/$KUMA_STATUS_SLUG" 2>/dev/null || echo 000)
    case "$slug_code" in
        200) pass "status page '$KUMA_STATUS_SLUG' is published" ;;
        404) warn "status page '$KUMA_STATUS_SLUG' is not published yet (run scripts/kuma-monitors.sh --dry-run, or publish it in the UI)" ;;
        *)   warn "status page '$KUMA_STATUS_SLUG' -> $slug_code" ;;
    esac
fi

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
