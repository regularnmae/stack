#!/usr/bin/env bash
# Verify the running stack.
#
#   ./verify.sh                 # shallow: container health + the MCP endpoints
#                               # are gated (401 without a token) and answer an
#                               # authenticated initialize handshake; every
#                               # onion service in ONION_SERVICES answers through
#                               # tor too
#   ./verify.sh --deep          # additionally call one read tool per endpoint,
#                               # proving the path through to the daemon, and
#                               # compare Fulcrum's Electrum index height with
#                               # bitcoind's
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
        victoriametrics node-exporter victoria-logs vector crowdsec
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp
        postgres boltmesh-backend boltmesh-worker boltmesh-frontend
    )
else
    containers=(
        bitcoind monerod fulcrum btc-explorer xmr-explorer monero-wallet-rpc lightningd
        tor valkey searxng uptime-kuma nginx-proxy-manager
        victoriametrics node-exporter victoria-logs vector crowdsec
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp
        postgres boltmesh-backend boltmesh-worker boltmesh-frontend
    )
fi
# victoria-logs' image is distroless (no shell), so podman cannot run a health
# command in it; its liveness is proven by the Logs section below instead.
healthless=" victoria-logs "
for c in "${containers[@]}"; do
    line=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
    if [ -z "$line" ]; then
        bad "$c is not running"
    elif printf '%s' "$line" | grep -q '(healthy)'; then
        pass "$c: $line"
    elif printf '%s' "$line" | grep -q '^Up'; then
        case "$healthless" in
            *" $c "*) pass "$c: $line (no healthcheck by design; the Logs section probes it)" ;;
            *)        warn "$c: $line (no health status)" ;;
        esac
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
head2 "Local images"
# These five are built here, not pulled, so a healthy container says nothing
# about whether its image still matches its Containerfile -- a merged base-image
# bump (Renovate's dockerfile manager) changes only that file. deploy.sh and
# install.sh rebuild on the label mismatch (scripts/lib.sh's image_is_current);
# this is how a bump that was merged but never deployed becomes visible. A stale
# image is a warning, not a failure: the service is running the last good bits.
local_images=(
    "btc-explorer|$BTC_EXPLORER_IMAGE|btc-explorer"
    "xmr-explorer|$XMR_EXPLORER_IMAGE|xmr-explorer"
    "kuma-ctl|$KUMA_CTL_IMAGE|kuma-ctl"
    "netcheck|$NETCHECK_IMAGE|netcheck"
    "tor|$TOR_IMAGE|tor"
)
for entry in "${local_images[@]}"; do
    IFS='|' read -r name image dir <<<"$entry"
    if ! podman image exists "$image" 2>/dev/null; then
        warn "$name image ($image) is missing; ./deploy.sh builds it"
    elif image_is_current "$image" "$REPO_DIR/$dir/Containerfile"; then
        pass "$name image matches its Containerfile"
    else
        warn "$name image is stale or unlabelled; ./deploy.sh rebuilds it from the current Containerfile"
    fi
done


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
        case ",$expect," in
            *",$code,"*)
                pass "$mirrors served at http://$addr$path ($code)" ;;
            *)
                if [ "$code" = 000 ]; then
                    warn "no answer for $mirrors at $addr (tor still publishing? give it a minute)"
                else
                    bad "$mirrors at $addr$path -> $code (expected $expect)"
                fi ;;
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
head2 "Block explorers"
# Both explorers are read as peers on npm-network; NPM reaches the same servers
# through their loopback publishes (127.0.0.1:8108/8109 in NPM_HOSTS). Asking
# each for something RPC-backed proves more than a bare 200 on a static page:
# BTC's /api/blocks/tip reads bitcoind, and MoneroBlock's / calls get_info and
# get_block_headers_range against monerod.
if [ "$NO_NODES" = 1 ]; then
    warn "chain daemons skipped by request; not checking the explorers"
else
    # -w puts the status after the body, so a basic-auth-protected explorer
    # (BTCEXP_BASIC_AUTH_PASSWORD) reads as a warning rather than a failure.
    btc_resp=$(net_curl -s -m 15 -w '\n%{http_code}' "http://btc-explorer:3002/api/blocks/tip" 2>/dev/null || true)
    btc_code="${btc_resp##*$'\n'}"
    btc_tip="${btc_resp%$'\n'*}"
    btc_h=$(printf '%s' "$btc_tip" | grep -oE '"height":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)
    case "$btc_code" in
        401)
            warn "btc-explorer is behind basic auth; chain-height check skipped" ;;
        *)
            if [ -n "$btc_h" ]; then
                pass "btc-explorer sees bitcoind at height $btc_h"
            else
                bad "btc-explorer did not report a chain tip (bitcoind RPC unreachable?)"
            fi ;;
    esac

    xmr_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 15 "http://xmr-explorer:31312/style.css" 2>/dev/null || true)
    [ -n "$xmr_code" ] || xmr_code=000
    if [ "$xmr_code" = "200" ]; then
        pass "xmr-explorer /style.css 200"
    else
        bad "xmr-explorer /style.css -> $xmr_code (listener down?)"
    fi

    # The home page exercises monerod's restricted RPC. During initial sync that
    # RPC is slow enough to time out, so this is a warning, not a failure --
    # monerod's own freshness is checked separately by the monitor.
    xmr_home=$(net_curl -s -o /dev/null -w '%{http_code}' -m 30 "http://xmr-explorer:31312/" 2>/dev/null || true)
    [ -n "$xmr_home" ] || xmr_home=000
    if [ "$xmr_home" = "200" ]; then
        pass "xmr-explorer / 200 (MoneroBlock read monerod over RPC)"
    else
        warn "xmr-explorer home page -> $xmr_home (monerod RPC busy during sync?)"
    fi
fi

# ---------------------------------------------------------------------------
head2 "Fulcrum (Electrum)"
# Fulcrum is the one service that is not HTTP: the Electrum protocol is
# newline-delimited JSON-RPC over raw TCP (50001) and TLS (50002), so neither
# net_curl nor nginx-proxy-manager can read it. Its healthcheck is the process
# table (`grep -qx Fulcrum /proc/1/comm`), which a wedged index passes forever --
# before this probe existed, an index that had stopped following bitcoind read
# healthy from every direction. The probes dial the published ports on the host's
# loopback, i.e. exactly what a wallet on the LAN reaches (see scripts/lib.sh).
if [ "$NO_NODES" = 1 ]; then
    warn "chain daemons skipped by request; not checking Fulcrum"
else
    # One getblockchaininfo for the whole section: it is what decides whether a
    # silent 50001 is broken or just a first-run index that has not caught up.
    btc_chain=$(podman exec bitcoind bitcoin-cli getblockchaininfo 2>/dev/null || true)
    btc_ibd=$(printf '%s' "$btc_chain" \
        | grep -oE '"initialblockdownload":[[:space:]]*(true|false)' | grep -oE '(true|false)' | head -n1)
    btc_blocks=$(printf '%s' "$btc_chain" \
        | grep -oE '"blocks":[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)

    # server.version is the banner: it names the server and the protocol revision,
    # which is the cheapest proof that something is speaking Electrum rather than
    # merely listening (a listening socket with a stuck app passes a TCP connect).
    ver_req='{"id":0,"method":"server.version","params":["stack-verify","1.4"]}'
    for spec in "50001|plain|$ver_req" "50002|tls|$ver_req"; do
        IFS='|' read -r port kind req <<<"$spec"
        if [ "$kind" = tls ]; then
            reply=$(electrum_call_tls 127.0.0.1 "$port" "$req")
            label="50002 (TLS)"
        else
            reply=$(electrum_call 127.0.0.1 "$port" "$req")
            label="50001 (TCP)"
        fi
        if printf '%s' "$reply" | grep -q '"result"'; then
            pass "fulcrum answers Electrum on $label: $(printf '%s' "$reply" | grep -oE 'Fulcrum[^"]*' | head -n1)"
        elif [ "$btc_ibd" = true ]; then
            warn "fulcrum does not answer on $label yet (bitcoind is in initial block download)"
        else
            bad "fulcrum is not answering Electrum on $label: ${reply:-no reply}"
        fi
    done

    if [ "$DEEP" = 1 ]; then
        # The index-backed question. server.version comes from memory and stays
        # green on a wedged index, so the height is what separates "serving" from
        # "serving stale". Fulcrum polls bitcoind every 5s (--polltime), so a
        # healthy one sits 0-1 block behind; a big gap in the other direction is
        # either a first index or a stall -- monitor.sh decides which, and pages.
        tip=$(electrum_tip 50001)
        if [ -z "$tip" ]; then
            if [ "$btc_ibd" = true ]; then
                warn "fulcrum reports no tip yet (indexing from scratch)"
            else
                bad "fulcrum reports no tip on 50001"
            fi
        elif [ -n "$btc_blocks" ]; then
            lag=$((btc_blocks - tip))
            if [ "$lag" -gt 12 ]; then
                warn "fulcrum index is $lag block(s) behind bitcoind (tip $tip, bitcoind $btc_blocks)"
            else
                pass "fulcrum index at $tip (bitcoind $btc_blocks)"
            fi
        else
            warn "fulcrum reports tip $tip but bitcoind's height is unreadable; lag not compared"
        fi
    fi
fi

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
# The restore drill: a timer that fires is not a backup that restores, and the
# weekly run is the only thing that ever opens a snapshot for real.
BACKUP_VERIFY_TIMER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/backup-verify.timer"
if [ -f "$BACKUP_VERIFY_TIMER" ]; then
    pass "backup-verify.timer installed"
else
    bad "backup-verify.timer is not installed (run deploy/install.sh)"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet backup-verify.timer 2>/dev/null; then
    pass "backup-verify.timer is active"
else
    warn "backup-verify.timer is not active (systemctl --user status backup-verify.timer)"
fi
if [ "$DEEP" = 1 ]; then
    # Freshness is best-effort and a fresh host legitimately has no snapshot, so
    # this only warns. A failure means the repository or password is wrong.
    if out=$("$REPO_DIR/scripts/backup.sh" snapshots 2>/dev/null) \
        && grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' <<< "$out"; then
        pass "backup repository has snapshots"
    else
        warn "no backup snapshots yet (expected until the first backup runs)"
    fi
    # The drill's own verdict, written by scripts/backup.sh verify. The age is
    # measured from the last success, so a drill that keeps skipping is visible.
    VSTATUS="$DATA_DIR/audit/backup-verify.status"
    if [ -f "$VSTATUS" ]; then
        vres=$(sed -n 's/^result=//p' "$VSTATUS" | head -n1)
        vok=$(sed -n 's/^ok_epoch=//p' "$VSTATUS" | head -n1)
        vdet=$(sed -n 's/^detail=//p' "$VSTATUS" | head -n1)
        case "$vok" in
            ''|*[!0-9]*) warn "backup restore drill has no recorded success yet" ;;
            *)
                vage=$(( ( $(date +%s) - vok ) / 3600 ))
                if [ "$vres" = fail ]; then
                    bad "last backup restore drill failed: ${vdet:-run scripts/backup.sh verify}"
                else
                    pass "last backup restore drill passed ${vage}h ago"
                fi
                ;;
        esac
    else
        warn "no backup restore drill yet (expected until backup-verify.timer runs)"
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
head2 "Metrics"
# The pipeline is history, not alerting (scripts/monitor.sh never queries it), so
# a problem here is reported but cannot hide an alert. It is checked because a
# silently dead collector is invisible otherwise: the graph just stops.
METRICS_TIMER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/metrics.timer"
if [ -f "$METRICS_TIMER" ]; then
    pass "metrics.timer installed"
else
    bad "metrics.timer is not installed (run deploy/install.sh)"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet metrics.timer 2>/dev/null; then
    pass "metrics.timer is active"
else
    warn "metrics.timer is not active (systemctl --user status metrics.timer)"
fi

vm_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 http://victoriametrics:8428/-/healthy 2>/dev/null) || vm_code=""
[ -n "$vm_code" ] || vm_code=000
if [ "$vm_code" = 200 ]; then
    pass "victoriametrics /-/healthy 200"
else
    bad "victoriametrics /-/healthy -> $vm_code"
fi

# /metrics is what the scrape reads, and it carries the textfile collector --
# asking for the stack's own series proves the whole path (writer, permissions,
# exporter), not just that the exporter is listening. node-exporter runs on the
# host network and is bound to npm-network's gateway IP, so this side reaches it
# as host.containers.internal -- never by the (no longer a peer) container name.
ne_metrics=$(net_curl -s -m 10 http://host.containers.internal:9100/metrics 2>/dev/null) || ne_metrics=""
if [ -n "$ne_metrics" ]; then
    pass "node-exporter /metrics answers"
    # Here-strings, not `printf | grep -q`: this body is >64KB, so a match early
    # in it makes grep exit and printf take SIGPIPE -- which `pipefail` turns
    # into a failed check. It reads as a false alarm ("no filesystem metrics")
    # exactly when the metric is present.
    if grep -q '^stack_metrics_timestamp' <<< "$ne_metrics"; then
        pass "textfile collector serves the stack's series"
    else
        warn "no stack_* series in node-exporter (scripts/metrics.sh has not run, or the textfile is unreadable)"
    fi
    if grep -q '^node_filesystem_avail_bytes' <<< "$ne_metrics"; then
        pass "node-exporter reads the host filesystems"
    elif grep -q '^node_scrape_collector_success{collector="filesystem"} 0' <<< "$ne_metrics"; then
        # Seen under heavy I/O: the collector hits statfs on a mount that is
        # being torn down (a container's overlay, a churny tmpfs) and gives up
        # for that scrape only. The next one recovers.
        warn "the filesystem collector failed on this scrape (a mount disappeared mid-scan? re-run)"
    else
        warn "node-exporter reports no filesystem metrics (the / host mount is missing?)"
    fi
else
    bad "node-exporter /metrics -> no answer"
fi

# The ages, read off the host: the file the collector writes and the scrape
# that turns it into history. A collector that runs but is not scraped is just
# as blind as one that does not run.
STACK_PROM="$DATA_DIR/monitoring/textfile/stack.prom"
if [ -f "$STACK_PROM" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$STACK_PROM" 2>/dev/null || echo 0) ))
    if [ "$age" -le 300 ]; then
        pass "stack.prom written ${age}s ago"
    else
        warn "stack.prom is ${age}s old (metrics.timer / scripts/metrics.sh)"
    fi
else
    warn "no stack.prom yet ($STACK_PROM); the first metrics run creates it"
fi

if [ "$DEEP" = 1 ]; then
    # A real query, not a health endpoint: this is the path vmui and any future
    # dashboard uses.
    q=$(net_curl -s -m 10 --get --data-urlencode 'query=stack_metrics_timestamp' \
        http://victoriametrics:8428/api/v1/query 2>/dev/null) || q=""
    if printf '%s' "$q" | grep -q '"value"'; then
        pass "victoriametrics answers a PromQL query"
    else
        warn "victoriametrics has no stack_metrics_timestamp series yet (first scrape?)"
    fi
fi

# ---------------------------------------------------------------------------
head2 "Logs"
# journald -> vector -> victoria-logs. History, not alerting (the monitor's one
# store query is the pipeline's own liveness), but a silently dead shipper is
# otherwise invisible: every unit reads "active" while the store stops growing.
if systemctl --user is-active --quiet vector.service 2>/dev/null; then
    pass "vector.service is active"
else
    warn "vector.service is not active (systemctl --user status vector)"
fi
vl_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 http://victoria-logs:9428/health 2>/dev/null) || vl_code=""
[ -n "$vl_code" ] || vl_code=000
if [ "$vl_code" = 200 ]; then
    pass "victoria-logs /health 200"
else
    bad "victoria-logs /health -> $vl_code"
fi
# A real LogsQL query, not the liveness endpoint: it proves the journal ->
# shipper -> store path, not just that the process is up.
logs_q=$(net_curl -s -m 15 --get --data-urlencode 'query=_time:15m | stats count() as n' \
    http://victoria-logs:9428/select/logsql/query 2>/dev/null) || logs_q=""
logs_n=$(printf '%s' "$logs_q" | jq -r '.n // empty' 2>/dev/null) || logs_n=""
case "$logs_n" in ''|*[!0-9]*) logs_n=0 ;; esac
if [ "$logs_n" -gt 0 ]; then
    pass "log store has $logs_n entries from the last 15m"
else
    bad "no log entries in the last 15m (vector is not shipping)"
fi
if [ -x "$REPO_DIR/scripts/logs.sh" ] && "$REPO_DIR/scripts/logs.sh" --health --quiet >/dev/null 2>&1; then
    pass "scripts/logs.sh --health"
elif [ -x "$REPO_DIR/scripts/logs.sh" ]; then
    warn "scripts/logs.sh --health failed (the check above says why)"
fi
# journald is the source. Volatile storage means a reboot erases the record even
# with the store in place, because the shipper only reads the current boot. The
# config alone is not proof: a /var/log/journal that tmpfiles has not prepared
# leaves journald on /run while Storage=persistent is in force.
if [ -n "$(find /var/log/journal -name '*.journal' -print -quit 2>/dev/null)" ]; then
    pass "journald is persistent ($(du -sh /var/log/journal 2>/dev/null | cut -f1))"
elif grep -qs '^Storage=persistent' /etc/systemd/journald.conf.d/99-stack.conf; then
    warn "journald is configured persistent but still writes to /run (sudo ./bootstrap.sh re-applies tmpfiles)"
else
    warn "journald is volatile (sudo ./bootstrap.sh makes it persistent; the store still covers reboots)"
fi
if [ -d "$DATA_DIR/logs/vl" ]; then
    pass "log store present ($(du -sh "$DATA_DIR/logs/vl" 2>/dev/null | cut -f1))"
else
    warn "no log store yet ($DATA_DIR/logs/vl); the first shipper run creates it"
fi

# ---------------------------------------------------------------------------
head2 "Intrusion detection"
# Two tiers, and they fail differently:
#   crowdsec is an ordinary rootless user unit, so this sweep can talk to it.
#   suricata is the repo's one ROOTFUL unit (AF_PACKET needs CAP_NET_RAW in the
#   init namespace), installed by `sudo ./bootstrap.sh` into the system manager.
#   A host that has not re-run bootstrap simply has no sensor -- report that as a
#   warning, not a failure, so an older host does not fail every sweep.
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/crowdsec.container" ]; then
    # The parser is the whole detection chain's front door. One replayed log line
    # through cscli explain proves it still matches NPM's format -- a log-format
    # change would otherwise disable detection silently.
    sample='[30/Oct/2026:13:31:19 +0000] - 404 404 - GET https api.example.invalid "/probe" [Client 203.0.113.9] [Length 22] [Gzip -] [Sent-to 127.0.0.1] "verify/1.0" "-"'
    if explain=$(podman exec crowdsec cscli explain --type npm --log "$sample" 2>/dev/null); then
        if printf '%s' "$explain" | grep -q 'stack/npm-logs' \
           && printf '%s' "$explain" | grep -q 'parser success'; then
            pass "crowdsec parses nginx-proxy-manager's log format"
        else
            warn "crowdsec did not parse a sample access log line (parser or log_format changed)"
        fi
    else
        warn "could not ask crowdsec to explain a sample line"
    fi
else
    warn "crowdsec unit is not installed (run deploy/install.sh)"
fi

if [ -f /etc/containers/systemd/suricata.container ]; then
    if systemctl is-active --quiet suricata 2>/dev/null; then
        pass "suricata is active"
    else
        bad "suricata is not active (sudo systemctl status suricata)"
    fi
    # A rendered unit that no longer matches the repo means someone edited
    # deploy/root/ without re-running bootstrap -- the running sensor is then not
    # the one in git, which is exactly the drift the digest check exists for.
    if [ -f "$REPO_DIR/deploy/root/suricata.container" ]; then
        want=$(mktemp)
        sed -e "s|@DATA_DIR@|$DATA_DIR|g" "$REPO_DIR/deploy/root/suricata.container" > "$want"
        if diff -q "$want" /etc/containers/systemd/suricata.container >/dev/null 2>&1; then
            pass "rendered suricata unit matches deploy/root/"
        else
            warn "rendered suricata unit differs from deploy/root/ (sudo ./bootstrap.sh re-renders it)"
        fi
        rm -f "$want"
    fi
else
    warn "the root tier is not installed (run: sudo ./bootstrap.sh) -- no network IDS"
fi

if [ -f "$DATA_DIR/audit/ids.status" ]; then
    ids_result=$(env_value "$DATA_DIR/audit/ids.status" result)
    if [ "$ids_result" = ok ]; then
        pass "IDS roll-up reports ok"
    else
        bad "IDS roll-up reports ${ids_result:-unknown} ($DATA_DIR/audit/ids.status)"
    fi
else
    warn "no IDS status yet (deploy/ids.timer has not run)"
fi

# The applier. Detection can be healthy while nothing enforces, which is the one
# state where the host looks protected and is not -- so it is checked separately
# from the engines, and it is a *system* unit (root, nftables).
if [ -f /etc/systemd/system/stack-bouncer.timer ]; then    if systemctl is-active --quiet stack-bouncer.timer 2>/dev/null; then
        pass "stack-bouncer.timer is active (decisions -> nftables)"
    else
        bad "stack-bouncer.timer is not active (sudo systemctl status stack-bouncer.timer)"
    fi
    if [ -f "$DATA_DIR/audit/bouncer.status" ]; then
        b_result=$(env_value "$DATA_DIR/audit/bouncer.status" result)
        b_banned=$(env_value "$DATA_DIR/audit/bouncer.status" banned)
        if [ "$b_result" = ok ]; then
            pass "bouncer: ${b_banned:-0} address(es) in the nftables ban set"
        else
            bad "bouncer last run failed: $(env_value "$DATA_DIR/audit/bouncer.status" detail)"
        fi
    else
        warn "the bouncer has not written a status yet (systemctl start stack-bouncer)"
    fi
else
    warn "the bouncer is not installed (sudo ./bootstrap.sh) -- decisions are not enforced"
fi

# Audit: the rules watch host-level files nothing in this repo writes, and the
# report's hash diff covers the entry creation this kernel will not audit (a new
# unit file, a new sudoers drop-in).
if [ -f /etc/systemd/system/stack-audit.timer ]; then
    if systemctl is-active --quiet stack-audit.timer 2>/dev/null; then
        pass "stack-audit.timer is active (audit + persistence-dir hashes)"
    else
        bad "stack-audit.timer is not active (sudo systemctl status stack-audit.timer)"
    fi
    if [ -f "$DATA_DIR/audit/auditd.status" ]; then
        a_result=$(env_value "$DATA_DIR/audit/auditd.status" result)
        a_fim=$(env_value "$DATA_DIR/audit/auditd.status" fim)
        if [ "$a_result" = ok ]; then
            pass "audit report ok (${a_fim:-0} persistence-dir change(s) since the last run)"
        else
            bad "audit report: $(env_value "$DATA_DIR/audit/auditd.status" detail)"
        fi
    else
        warn "the audit report has not run yet (systemctl start stack-audit)"
    fi
    # The ruleset itself cannot be checked from here: `auditctl -l` needs
    # CAP_AUDIT_CONTROL, so an unprivileged verify would always see zero rules and
    # warn about nothing. The status file above is the signal (a report that runs
    # at all means auditd answered), and `sudo auditctl -l | grep stack_` is the
    # manual check.
else
    warn "the audit tier is not installed (sudo ./bootstrap.sh)"
fi

# ---------------------------------------------------------------------------
head2 "Summary"
if [ "$fails" = 0 ]; then
    [ "$DEEP" = 1 ] || printf 'All shallow checks passed. Re-run with --deep once the chains are synced.\n'
    [ "$DEEP" = 1 ] && printf 'All checks passed.\n'
    exit 0
fi
printf '%d check(s) failed.\n' "$fails"
printf 'Logs:  scripts/logs.sh --since 15m   (or podman logs <container>)\n'
printf 'Units: systemctl --user status <service>.service\n'
exit 1
