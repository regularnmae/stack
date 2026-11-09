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
# server on npm-network as <container>:8000, through the long-lived `netcheck`
# container (the app images vary and several carry no curl; scripts/lib.sh says
# why it is not a throwaway `podman run` per probe). The one exception is
# nginx-proxy-manager, which is on the host network -- it is read on 127.0.0.1,
# the same place it listens.
#
# Read-only. Exits non-zero if anything is wrong.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
# The public surface (the *_HOST names, MCP_HOSTS, ONION_SERVICES) is declared
# in deploy/services.toml; stack.conf keeps the non-registry knobs.
load_manifest "$REPO_DIR"
# The tokens live under the data dir now, so resolving it is how we find them.
resolve_data_dir

# MCP_HOST (the [host.mcp] name) and the rest of the public surface come from
# the service manifest via load_manifest, above.

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
    warn "chain daemons skipped by request; not checking bitcoind/monerod/lightningd/btcpay/nbxplorer/monero-wallet-btcpay"
    containers=(
        tor valkey searxng uptime-kuma nginx-proxy-manager
        netcheck netcheck-host victoriametrics alertmanager node-exporter victoria-logs vector crowdsec
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp fulcrum-mcp victoria-logs-mcp victoriametrics-mcp crowdsec-mcp btcpay-mcp
        postgres boltmesh-backend boltmesh-worker boltmesh-frontend
    )
else
    containers=(
        bitcoind monerod fulcrum btc-explorer xmr-explorer monero-wallet-btcpay lightningd btcpay nbxplorer
        tor valkey searxng uptime-kuma nginx-proxy-manager
        netcheck netcheck-host victoriametrics alertmanager node-exporter victoria-logs vector crowdsec
        searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp fulcrum-mcp victoria-logs-mcp victoriametrics-mcp crowdsec-mcp btcpay-mcp
        postgres boltmesh-backend boltmesh-worker boltmesh-frontend
    )
fi
# The units that cannot define a health command are declared once, in
# stack.conf's HEALTHLESS_UNITS (each with its reason): victoria-logs' image is
# distroless, and the two netcheck clients just sleep until something execs
# into them. scripts/healthcheck-lint.sh keeps that declaration and the units
# in agreement; here it only decides what an "Up but unprobed" container means.
healthless=" "
for _u in "${HEALTHLESS_UNITS[@]:-}"; do
    healthless+="${_u%%|*} "
done
# One classifier for every container check in this file, because a failing probe
# still reads "Up ... (unhealthy)": the old prefix match passed (or, worse,
# warned about) a container whose healthcheck was red, and a warning never
# increments fails -- so the monitor, which carries only FAIL lines and the exit
# code, could not see it. `starting` stays a warning on purpose: podman promotes
# a probe that never succeeds to (unhealthy) after HealthStartPeriod x retries,
# so the state is bounded and transient, while a FAIL there would page on the
# tail of every ordinary restart (a 5-minute sweep, StartPeriod up to 5m).
check_container() { # container
    local c="$1" line
    line=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
    case "$(container_health_state "$line")" in
        healthy)
            pass "$c: $line" ;;
        unhealthy)
            bad "$c: $line -- its healthcheck is failing (podman inspect -f '{{json .State.Health}}' $c; podman logs --tail 50 $c)" ;;
        starting)
            warn "$c: $line (the healthcheck has not answered yet)" ;;
        down)
            bad "$c is not running" ;;
        up)
            case "$healthless" in
                *" $c "*) pass "$c: $line (no healthcheck by design)" ;;
                *)        warn "$c: $line (no health status)" ;;
            esac ;;
        *)
            bad "$c: $line" ;;
    esac
}
for c in "${containers[@]}"; do
    check_container "$c"
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
# These four are built here, not pulled, so a healthy container says nothing
# about whether its image still matches its Containerfile -- a merged base-image
# bump (Renovate's dockerfile manager) changes only that file. deploy.sh and
# install.sh rebuild on the label mismatch (scripts/lib.sh's image_is_current);
# this is how a bump that was merged but never deployed becomes visible. A stale
# image is a warning, not a failure: the service is running the last good bits.
local_images=(
    "btc-explorer|$BTC_EXPLORER_IMAGE|btc-explorer"
    "xmr-explorer|$XMR_EXPLORER_IMAGE|xmr-explorer"
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
head2 "Unit definitions"
# A running container keeps the definition it started with, so a rendered unit
# that was never applied is invisible to every health check -- the one failure
# mode that silently leaves the host on old config. install.sh records what it
# rendered ($DATA_DIR/audit/units.rendered); deploy.sh and scripts/rotate.sh
# record what they applied (units.applied). Comparing the live digests with the
# applied set makes a hand render, a hand edit and an interrupted deploy fail
# here instead of waiting to be noticed. This is a FAIL, not a warning: the
# monitor carries verify's FAIL lines, and a warning would be silent.
unit_lines() { # digest-set stem -> that unit's manifest lines
    printf '%s\n' "$1" | awk -v u="$2" '$2 ~ ("^" u "\\.") { print }' | sort
}
unit_applied=$(unit_applied_read)
unit_current=$(unit_digest)
if [ -z "$unit_applied" ]; then
    warn "no applied-unit baseline ($DATA_DIR/audit/units.applied); ./deploy.sh establishes it"
elif [ -z "$unit_current" ]; then
    warn "no rendered unit files found (is the stack installed?); ./deploy.sh renders them"
else
    unit_changed=$(unit_digest_changed "$unit_applied" "$unit_current")
    if [ -z "$unit_changed" ]; then
        pass "every rendered unit matches the definition last applied"
    else
        unit_rendered=$(cat "$DATA_DIR/audit/units.rendered" 2>/dev/null || true)
        for unit in $unit_changed; do
            if [ -n "$unit_rendered" ] \
                && [ "$(unit_lines "$unit_rendered" "$unit")" = "$(unit_lines "$unit_current" "$unit")" ]; then
                how="rendered by install.sh and never applied"
            else
                how="edited after install.sh rendered it"
            fi
            bad "$unit: $how; run ./deploy.sh (or ./deploy.sh --only $unit)"
        done
    fi
fi


# ---------------------------------------------------------------------------
head2 "Host tools"
# The monitor's alert path is the host's own curl + jq (Alertmanager is a
# loopback bind and the heartbeat an outbound POST), and openssl reads
# certificate expiry and runs Fulcrum's TLS probe. They are requirements, not
# conveniences: a missing one turns a check off silently, which is how a stack
# can look healthy while nothing can page. bootstrap.sh installs all three --
# including on a host that already had podman, where the package bundle above
# never runs -- so this names the gap on a host provisioned before that.
for t in curl openssl jq; do
    if command -v "$t" >/dev/null 2>&1; then
        pass "$t is installed"
    else
        bad "$t is missing: alerting, the certificate check or the alert payload will not work (sudo dnf install -y $t)"
    fi
done
for t in git python3; do
    if command -v "$t" >/dev/null 2>&1; then
        pass "$t is installed"
    else
        warn "$t is missing: the repo fetch or agent-mcp needs it (./bootstrap.sh installs it)"
    fi
done


# ---------------------------------------------------------------------------
head2 "BTCPay settlement"
if [ "$NO_NODES" = 1 ]; then
    warn "chain daemons skipped by request; not checking BTCPay/NBXplorer"
else
    # btcpay, nbxplorer and monero-wallet-btcpay are in the container inventory
    # above (both branches), so check_container already names their state with the
    # one classifier. This section owns the functional question instead -- what
    # the endpoint answers -- rather than keeping a second, laxer copy of the
    # status rules.
    # The same endpoint the backend's /health uses: a 200 means BTCPay and its
    # database are serving, not merely that the container is up.
    btcpay_health=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 http://btcpay:49392/api/v1/health 2>/dev/null || echo 000)
    if [ "$btcpay_health" = "200" ]; then
        pass "BTCPay /api/v1/health 200"
    else
        bad "BTCPay /api/v1/health -> $btcpay_health"
    fi
fi

# ---------------------------------------------------------------------------
head2 "MCP endpoints"
# name|token-var|deep-tool|deep-args|needs-nodes|spend-token-var
# The list is declared with each server in deploy/services.toml ([mcp.*]) and
# emitted by the manifest as MCP_PROBES (scripts/lib.sh's load_manifest), so a
# server added there is probed here without a second table to keep in step. The
# token file is the container's own token.env by convention. The name is the
# container name: scripts/lib.sh decides where it is reached -- by name on
# npm-network for every server but crowdsec-mcp, which runs on the host network
# and is read through netcheck-host at 127.0.0.1:8113 (mcp_base / mcp_curl). It
# also names the MCP_HOSTS entry whose loopback port nginx-proxy-manager fronts.
# The last field is scripts/rotate.sh's; verify.sh does not use it.
[ -n "${MCP_PROBES[*]:-}" ] \
    || die "the manifest emitted no MCP_PROBES (run ./deploy.sh)"

# The token each container's endpoint needs, keyed by container name, so the
# through-nginx-proxy-manager section below can reuse it.
declare -A EP_ENV=() EP_VAR=()

for e in "${MCP_PROBES[@]}"; do
    IFS='|' read -r name var tool args needs_nodes _spend_var <<<"$e"
    envfile="$CONFIG_DIR/$name/token.env"
    EP_ENV["$name"]="$envfile"
    EP_VAR["$name"]="$var"

    # Read through mcp_curl (scripts/lib.sh), which picks netcheck or
    # netcheck-host for this container and knows its base URL. nginx-proxy-manager,
    # on the host network, reaches the same server through its loopback port.
    health=$(mcp_curl "$name" -s -o /dev/null -w '%{http_code}' -m 10 "$(mcp_base "$name")/health" 2>/dev/null || echo 000)
    if [ "$health" = "200" ]; then pass "$name /health 200"; else bad "$name /health -> $health"; fi

    gated=$(mcp_curl "$name" -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$(mcp_base "$name")/mcp" \
        -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)
    if [ "$gated" = "401" ]; then pass "$name /mcp is token-gated (401)"; else bad "$name /mcp without a token -> $gated (expected 401)"; fi

    token=$(env_value "$envfile" "$var")
    if [ -z "$token" ]; then
        bad "$name has no token in $envfile"
        continue
    fi

    if mcp_initialize "$name" "$token" 15 >/dev/null; then
        pass "$name authenticated MCP handshake"
        # The revision the server agreed to. A mismatch is not a failure -- a
        # server legitimately negotiates down -- but it means this client's
        # pinned MCP_PROTOCOL_VERSION is no longer what the server speaks, and
        # nothing else in the stack would notice.
        pv=$(mcp_protocol "$MCP_INIT_RESPONSE")
        case "$pv" in
            '')
                warn "$name did not answer the handshake with a protocolVersion" ;;
            "$MCP_PROTOCOL_VERSION")
                pass "$name speaks MCP $pv" ;;
            *)
                warn "$name negotiated MCP $pv, but scripts/lib.sh sends $MCP_PROTOCOL_VERSION (bump it, and agent-skills' PROTOCOL_VERSION, together)" ;;
        esac
    else
        bad "$name authenticated handshake failed"
    fi

    if [ "$DEEP" = 1 ]; then
        if [ "$name" = monero-wallet-mcp ] && [ ! -f "$DATA_DIR/btcpay/xmr-wallet/wallet.keys" ]; then
            if grep -q '^XMR_WALLET_ADDRESS=.' "$CONFIG_DIR/btcpay/xmr-wallet.env" 2>/dev/null; then
                warn "$name deep check skipped (view-only wallet not imported yet; monerod must reach its restore height)"
            else
                warn "$name deep check skipped (fill in config/btcpay/xmr-wallet.env to import the view-only wallet)"
            fi
        elif [ "$NO_NODES" = 1 ] && [ "$needs_nodes" = 1 ]; then
            warn "$name deep check skipped (needs a chain node)"
        else
            # mcp_tool_call reuses the session mcp_initialize just opened.
            resp=$(mcp_tool_call "$name" "$token" "$tool" "$args" 30 || true)
            if printf '%s' "$resp" | grep -q '"isError":true'; then
                bad "$name deep call $tool returned an error"
            elif [ -n "$(mcp_result_raw "$resp")" ]; then
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
    warn "MCP_HOSTS is not declared in deploy/services.toml; skipping the proxy checks"
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
head2 "Agent tooling"
# The eleven skills plus `agent-mcp` from the agent-skills repo: the same servers,
# through the same tokens, for harnesses that do not speak MCP (Codex, a plain
# shell, CI). The registry reads $DATA_DIR/config/<server>/token.env on every
# call -- never a copy -- so a rotated token needs no second edit. A host that
# only serves has none of it, so that is a warning, not a failure. The live call
# is kept for --deep so the shallow sweep stays offline.
AGENT_BIN="${AGENT_MCP_BIN:-$HOME/.local/bin/agent-mcp}"
AGENT_DIR="$BUILD_DIR/${AGENT_SKILLS_REPO:-agent-skills}"
# The revision agent-mcp sends is hand-maintained in scripts/lib.sh too
# (MCP_PROTOCOL_VERSION): two clients of the same servers must name the same
# one, so a bump that lands on one side only is drift. Read the constant,
# never import the module.
if [ -r "$AGENT_DIR/lib/mcp_http.py" ]; then
    agent_proto=$(sed -n 's/^PROTOCOL_VERSION *= *"\(.*\)"/\1/p' "$AGENT_DIR/lib/mcp_http.py" | head -n1)
    if [ -z "$agent_proto" ]; then
        warn "could not read PROTOCOL_VERSION from $AGENT_DIR/lib/mcp_http.py"
    elif [ "$agent_proto" = "$MCP_PROTOCOL_VERSION" ]; then
        pass "agent-mcp and the host probes both speak MCP $agent_proto"
    else
        warn "agent-mcp speaks MCP $agent_proto but scripts/lib.sh sends $MCP_PROTOCOL_VERSION (bump both)"
    fi
fi
if [ ! -x "$AGENT_BIN" ]; then
    warn "agent-mcp is not installed (./deploy.sh --only agent-skills)"
else
    pass "agent-mcp is installed"
    missing=()
    for harness in "$HOME/.config/opencode" "$HOME/.codex" "$HOME/.claude"; do
        [ -d "$harness" ] || continue
        for skill in bitcoin-node monero-node monero-wallet lightning searxng fulcrum victoria-logs victoriametrics; do
            [ -e "$harness/skills/$skill/SKILL.md" ] || missing+=("$harness/skills/$skill")
        done
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        pass "every skill is linked into the harnesses installed here"
    else
        bad "${#missing[@]} skill link(s) missing (e.g. ${missing[0]}); run ./deploy.sh --only agent-skills"
    fi

    # servers.json is the skills' copy of the public surface: one URL per
    # MCP_HOSTS prefix. A prefix that moved in the manifest and not here means a
    # skill calls a URL nginx-proxy-manager no longer serves, so compare the
    # resolved registry with the declaration -- using the CLI's own resolver,
    # never a second copy of the expansion rules. The host is compared
    # separately and only warns: a harness deliberately pointed at another stack
    # (AGENT_MCP_BASE_URL) is the operator's call, a missing prefix is not.
    if [ -r "$AGENT_DIR/lib/config.py" ] && command -v python3 >/dev/null 2>&1 \
       && [ "${MCP_HOSTS+x}" = x ] && [ "${#MCP_HOSTS[@]}" -gt 0 ]; then
        agent_urls=()
        while IFS= read -r url; do
            [ -n "$url" ] && agent_urls+=("$url")
        done < <(
            python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from config import load_servers, resolve_url; print("\n".join(resolve_url(e) for e in load_servers().values()))' \
                "$AGENT_DIR/lib" 2>/dev/null
        )
        drift=()
        for entry in "${MCP_HOSTS[@]}"; do
            prefix="${entry%%:*}"
            printf '%s\n' "${agent_urls[@]}" | grep -qE "^[a-z]+://[^/]+${prefix}$" \
                || drift+=("$prefix")
        done
        if [ "${#drift[@]}" -gt 0 ]; then
            bad "servers.json does not cover ${drift[*]} (did MCP_HOSTS change?); update $AGENT_DIR/servers.json"
        elif [ "${#agent_urls[@]}" -ne "${#MCP_HOSTS[@]}" ]; then
            bad "servers.json declares ${#agent_urls[@]} endpoint(s) for ${#MCP_HOSTS[@]} MCP_HOSTS prefix(es)"
        else
            pass "servers.json matches every MCP_HOSTS prefix"
        fi
        elsewhere=()
        for url in "${agent_urls[@]}"; do
            case "$url" in
                "https://$MCP_HOST/"*) ;;
                *) elsewhere+=("$url") ;;
            esac
        done
        if [ "${#elsewhere[@]}" -gt 0 ]; then
            warn "the skills point at ${elsewhere[*]}, not https://$MCP_HOST (AGENT_MCP_BASE_URL in this shell?)"
        fi
    else
        warn "servers.json not compared with MCP_HOSTS (no $AGENT_DIR clone, no python3, or no MCP_HOSTS)"
    fi

    if [ "$DEEP" = 1 ]; then
        if out=$("$AGENT_BIN" bitcoin-node get_blockchain_info 2>&1); then
            pass "agent-mcp read the bitcoin node (chain $(printf '%s' "$out" | jq -r '.chain // "?"'))"
        else
            bad "agent-mcp could not call bitcoin-node: $(printf '%s' "$out" | head -1)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
head2 "Onion services (tor)"
# The same public surface without DNS or a certificate. tor publishes one hidden
# service per ONION_SERVICES entry (stack.conf) and forwards it; the address is
# read from tor's own data dir, because it is key material and not declared.
# The probe goes through tor's SOCKS port from the netcheck container on
# npm-network (torrc's SocksPolicy allows nothing else) and asks tor to resolve
# the .onion name itself (--socks5-hostname), exactly as a client does. A fresh
# service takes a minute to become reachable, so "no answer" is a warning.
# The mcp entry expects 401: that proves the whole onion -> NPM -> container path
# and the bearer-token gate, since NPM cannot match an onion by name (see
# ONION_SERVICES).
TOR_SOCKS="${TOR_SOCKS:-10.89.0.240:9050}"
if [ "${ONION_SERVICES+x}" != x ] || [ "${#ONION_SERVICES[@]}" -eq 0 ]; then
    warn "ONION_SERVICES is not declared in deploy/services.toml; skipping the onion checks"
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
if printf '%s' "$be_body" | jq -e '.status == "healthy"' >/dev/null 2>&1; then
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
    btc_h=$(printf '%s' "$btc_tip" | jq -r '.height // empty' 2>/dev/null || true)
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
    btc_chain=$(bitcoind_cli getblockchaininfo 2>/dev/null || true)
    btc_ibd=$(printf '%s' "$btc_chain" | jq -r 'if has("initialblockdownload") then .initialblockdownload else empty end' 2>/dev/null || true)
    btc_blocks=$(printf '%s' "$btc_chain" | jq -r '.blocks // empty' 2>/dev/null || true)

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
        if printf '%s' "$reply" | jq -e '.result' >/dev/null 2>&1; then
            pass "fulcrum answers Electrum on $label: $(printf '%s' "$reply" | jq -r '.result | if type == "array" then .[0] else . end // empty' 2>/dev/null)"
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

# The monitors must resolve their vhosts to the host gateway, not the public
# name: that resolution is what stopped seven checks a minute from leaving the
# host and coming back as the WAN address (89,766 handshakes in eight days).
# A warning, not a failure -- Uptime-Kuma is UI-configured for its own account,
# and a hand-added monitor may still hairpin. Read the entry from /etc/hosts
# because it is exactly what podman wrote from --add-host.
if podman container exists uptime-kuma 2>/dev/null; then
    kuma_host_ip=$(podman exec uptime-kuma awk -v h="$BOLTMESH_FRONTEND_HOST" \
        '$2 == h { print $1; exit }' /etc/hosts 2>/dev/null || true)
    case "$kuma_host_ip" in
        169.254.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
            pass "uptime-kuma resolves $BOLTMESH_FRONTEND_HOST through the host gateway ($kuma_host_ip)" ;;
        "")
            warn "uptime-kuma has no static entry for $BOLTMESH_FRONTEND_HOST (re-run deploy/install.sh)" ;;
        *)
            warn "uptime-kuma resolves $BOLTMESH_FRONTEND_HOST to $kuma_host_ip (expected the host gateway, not a public address)" ;;
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
# The monthly database drill: the weekly run proves restic mechanics, never that
# postgres-dump/all.sql replays -- and that dump is the only copy of the app
# tier's data, because the live cluster is excluded from the snapshot.
BACKUP_VERIFY_DB_TIMER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/backup-verify-db.timer"
if [ -f "$BACKUP_VERIFY_DB_TIMER" ]; then
    pass "backup-verify-db.timer installed"
else
    bad "backup-verify-db.timer is not installed (run deploy/install.sh)"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet backup-verify-db.timer 2>/dev/null; then
    pass "backup-verify-db.timer is active"
else
    warn "backup-verify-db.timer is not active (systemctl --user status backup-verify-db.timer)"
fi
# The dump job that replaces the live databases in the snapshot: without it
# restic still succeeds, copying the previous dumps, so a missing unit is silent
# until monitor.sh's freshness check (36h) or a restore.
DB_DUMP_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/db-dump.service"
if [ -f "$DB_DUMP_UNIT" ]; then
    pass "db-dump.service installed"
else
    bad "db-dump.service is not installed (run deploy/install.sh)"
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
        status_verdict "$VSTATUS"
        if [ -z "$STATUS_AGE_S" ]; then
            warn "backup restore drill has no recorded success yet"
        else
            vage=$(( STATUS_AGE_S / 3600 ))
            if [ "$STATUS_RESULT" = fail ]; then
                bad "last backup restore drill failed: ${STATUS_DETAIL:-run scripts/backup.sh verify}"
            else
                pass "last backup restore drill passed ${vage}h ago"
            fi
        fi
    else
        warn "no backup restore drill yet (expected until backup-verify.timer runs)"
    fi
    # The database drill's verdict, written by scripts/backup.sh verify-db. Same
    # rule: judged on the last success, so a drill that keeps skipping (no image,
    # no repository lock) is visible rather than invisible.
    DBSTATUS="$DATA_DIR/audit/backup-verify-db.status"
    if [ -f "$DBSTATUS" ]; then
        status_verdict "$DBSTATUS"
        if [ -z "$STATUS_AGE_S" ]; then
            warn "database drill has no recorded success yet"
        else
            dage=$(( STATUS_AGE_S / 3600 ))
            if [ "$STATUS_RESULT" = fail ]; then
                bad "last database drill failed: ${STATUS_DETAIL:-run scripts/backup.sh verify-db}"
            else
                pass "last database drill passed ${dage}h ago"
            fi
        fi
    else
        warn "no database drill yet (expected until backup-verify-db.timer runs)"
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
# The signup watcher is the one unit that only *notifies*: losing it breaks no
# service, so a missing or stopped timer is a warning here and not a failure.
# scripts/monitor.sh separately warns on a stale registrations.status.
REG_TIMER="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/registrations.timer"
if [ -f "$REG_TIMER" ]; then
    pass "registrations.timer installed"
else
    warn "registrations.timer is not installed (run deploy/install.sh); signups are not mailed"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet registrations.timer 2>/dev/null; then
    pass "registrations.timer is active"
else
    warn "registrations.timer is not active (systemctl --user status registrations.timer)"
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
# host network and listens on the wildcard: rootless podman keeps npm-network's
# gateway inside its userns, so there is no gateway address here to bind (see
# deploy/node-exporter.container for the measurement), and only a wildcard bind
# catches a dial from a container. This side therefore reaches it as
# host.containers.internal -- never by the (no longer a peer) container name.
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
    if printf '%s' "$q" | jq -e '.data.result | length > 0' >/dev/null 2>&1; then
        pass "victoriametrics answers a PromQL query"
    else
        warn "victoriametrics has no stack_metrics_timestamp series yet (first scrape?)"
    fi
fi

# ---------------------------------------------------------------------------
head2 "Alerting"
# Two failures look nothing alike here: the container can be healthy while mail
# is not leaving it. /-/healthy answers the first; the config is inspected for
# the second, and "no receiver configured" is a WARN, not a failure -- a fresh
# host is not broken before its SMTP is filled in, it is just not paging yet.
# The runtime half (did a delivery fail?) is monitor.sh's counter check, because
# that is the sweep that can turn it into a page.
am_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 http://alertmanager:9093/-/healthy 2>/dev/null) || am_code=""
[ -n "$am_code" ] || am_code=000
if [ "$am_code" = 200 ]; then
    pass "alertmanager /-/healthy 200"
else
    bad "alertmanager /-/healthy -> $am_code"
fi
# The config is operator-owned and hand-edited, so a YAML slip is a real
# possibility. Alertmanager keeps running the last good config when it refuses a
# new one, which is silent unless someone parses it.
AM_CFG="$CONFIG_DIR/monitoring/alertmanager/alertmanager.yml"
if [ -f "$AM_CFG" ]; then
    if am_chk=$(podman exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml 2>&1); then
        pass "alertmanager config parses"
    else
        bad "alertmanager config is invalid ($AM_CFG): ${am_chk##*$'\n'}"
    fi
    # The seeded config ships with the receiver's email block commented out: the
    # alert path accepts alerts and delivers nothing until it is filled in.
    if grep -qE '^[[:space:]]*email_configs:' "$AM_CFG"; then
        pass "alertmanager has an email receiver configured"
    else
        warn "alerting is inert: no email_configs in $AM_CFG (fill in SMTP, then scripts/monitor.sh --test)"
    fi
else
    warn "no alertmanager config at $AM_CFG (run deploy/install.sh)"
fi
if [ "$(env_value "$CONFIG_DIR/monitoring/monitor.env" MONITOR_ALERTMANAGER_URL)" = off ]; then
    warn "alerting is disabled by config (MONITOR_ALERTMANAGER_URL=off in monitor.env)"
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
# The file sources are the half journald cannot see, and each fails on its own:
# eve.json stops being written, or the NPM log directory is not mounted. Check
# the NPM one by content -- a request in the last 15m -- because it is both the
# newest source and the one an NPM image update could move (a changed log path or
# log_format leaves the source reading nothing, forever, with the unit green).
npm_q=$(net_curl -s -m 15 --get --data-urlencode 'query=_time:15m log_type:"npm_access" | stats count() as n' \
    http://victoria-logs:9428/select/logsql/query 2>/dev/null) || npm_q=""
npm_n=$(printf '%s' "$npm_q" | jq -r '.n // empty' 2>/dev/null) || npm_n=""
case "$npm_n" in ''|*[!0-9]*) npm_n=0 ;; esac
if [ "$npm_n" -gt 0 ]; then
    pass "log store has $npm_n nginx-proxy-manager request(s) from the last 15m"
else
    bad "no nginx-proxy-manager access entries in the last 15m (deploy/logs/vector.toml's npm source is not reading $DATA_DIR/npm/data/logs)"
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
# podman's own events are the noisiest thing this store could index: two lines
# per exec (each carrying the image's label dump) and a `health_status` line on
# every check, healthy or not -- measured at 4,156 of 9,315 journal lines an
# hour before this was set. deploy/install.sh points them at a bounded file
# (podman_events_conf, ~/.config/containers/containers.conf), which is the only
# lever that also reaches podman's generated healthcheck units: the per-call
# `--events-backend=none` in scripts/lib.sh covers two call sites, not the
# mechanism. "journald" here means the flood is back.
podman_events=$(podman info --format '{{.Host.EventLogger}}' 2>/dev/null || true)
case "$podman_events" in
    journald) bad "podman events go to journald (deploy/install.sh moves them to a bounded file)" ;;
    "")       warn "could not read podman's event logger (podman info failed)" ;;
    *)        pass "podman events -> $podman_events, not the journal" ;;
esac
# ...and the sensor has its own, because its healthchecks are podman children of
# the *system* manager, not of anything this login user runs. That file is
# root-owned 0644 and merged (not rendered from deploy/root/), so it is read
# rather than diffed, and the answer podman would give needs root: hence the
# grep. Missing means ~120 health_status lines an hour -- small, but it is the
# remainder of the flood, and bootstrap.sh is the only thing that can write it.
if grep -Eq '^[[:space:]]*events_logger[[:space:]]*=[[:space:]]*"file"' /etc/containers/containers.conf 2>/dev/null; then
    pass "root podman events -> file (/etc/containers/containers.conf)"
else
    warn "root podman events still go to journald (sudo ./bootstrap.sh writes /etc/containers/containers.conf)"
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
    # The parser is the whole detection chain's front door. Two replayed lines
    # through cscli explain prove it still matches NPM's format -- a log-format
    # change would otherwise disable detection silently. The second is the shape
    # that used to be dropped: NPM logs $upstream_status before $status, and it
    # is "-" whenever no upstream was contacted (the 301 onto https, a 499 on a
    # client abort), which was 13% of this host's real traffic.
    npm_parse_ok=0
    for sample in \
        '[30/Oct/2026:13:31:19 +0000] - 404 404 - GET https api.example.invalid "/probe" [Client 203.0.113.9] [Length 22] [Gzip -] [Sent-to 127.0.0.1] "verify/1.0" "-"' \
        '[30/Oct/2026:13:31:19 +0000] - - 301 - GET http api.example.invalid "/" [Client 203.0.113.9] [Length 166] [Gzip -] [Sent-to 127.0.0.1] "verify/1.0" "-"'
    do
        explain=$(cscli explain --type npm --log "$sample" 2>/dev/null) || continue
        if printf '%s' "$explain" | grep -q 'stack/npm-logs' \
           && printf '%s' "$explain" | grep -q 'parser success'; then
            npm_parse_ok=$((npm_parse_ok + 1))
        fi
    done
    if [ "$npm_parse_ok" -eq 2 ]; then
        pass "crowdsec parses both nginx-proxy-manager log shapes"
    else
        warn "crowdsec parsed ${npm_parse_ok}/2 sample access log lines (parser or log_format changed)"
    fi
    # The packet tier's half of the same chain: Suricata's EVE alert must reach
    # a scenario, and a loopback-sourced one must be whitelisted before it can.
    # The first sample is a public undeclared-Host alert -- the rule that
    # actually bans the scanners in this host's log -- and the second is the
    # same alert from 127.0.0.1, the NPM re-originated leg that has no client
    # identity. A parser rename, an acquisition label change or a missing
    # scenario fails here instead of silently disabling enforcement.
    eve_sample='{"timestamp":"2026-11-07T12:00:00.000000+0000","event_type":"alert","in_iface":"enp8s0","src_ip":"198.51.100.7","dest_ip":"192.0.2.10","dest_port":80,"proto":"TCP","alert":{"signature_id":9000004,"rev":2,"signature":"STACK HTTP request to an undeclared Host","severity":1}}'
    eve_ok=0
    if explain=$(cscli explain --type suricata-evelogs --log "$eve_sample" 2>/dev/null); then
        printf '%s' "$explain" | grep -q 'stack/suricata-policy' && eve_ok=1
    fi
    if [ "$eve_ok" -eq 1 ]; then
        pass "crowdsec turns a public Suricata alert into stack/suricata-policy"
    else
        warn "crowdsec did not match a Suricata EVE alert to stack/suricata-policy (parser, acquisition label or scenario changed)"
    fi
    eve_private=${eve_sample/198.51.100.7/127.0.0.1}
    if explain=$(cscli explain --type suricata-evelogs --log "$eve_private" 2>/dev/null); then
        if printf '%s' "$explain" | grep -q 'stack/whitelists.*whitelisted'; then
            pass "crowdsec whitelists a loopback Suricata alert"
        else
            bad "crowdsec does not whitelist a loopback Suricata alert (it would ban the host's own traffic)"
        fi
    fi
    # The acquisition's file is root-owned; a container that cannot read it
    # produces no decisions and no error anyone reads. The label is the real
    # failure mode (a default_t file is unreadable), so prove the read.
    if podman exec crowdsec sh -c 'test -r /ids/suricata/alerts.json' 2>/dev/null; then
        pass "crowdsec can read Suricata's alert feed"
    else
        warn "crowdsec cannot read /ids/suricata/alerts.json (sensor not installed, or the file lost its container label)"
    fi
    # The whitelist is the other half of detection, and it fails QUIETLY: its
    # expressions are plain string matches and the parser runs in s02-enrich,
    # before any scenario, so a prefix one octet too short reports the traffic as
    # `whitelisted` and it can never become a decision. This file once carried
    # `startsWith '172.2'` for the LAN's middle span and so swallowed 172.2.0.0/16
    # and 172.200.0.0/14 with it (~4.4M public addresses reported as whitelisted).
    # Probe both directions: over-matching hides detections, while under-matching
    # -- a file that stopped loading, or a range that lost its entry -- bans the
    # onion path and the status page. The Uptime-Kuma probe is the only one the
    # stock crowdsecurity/whitelists cannot answer for us, so it is what proves
    # this file is actually loaded.
    for wl_probe in \
        '172.220.10.5|verify/1.0|no' \
        '172.18.0.5|verify/1.0|yes' \
        '203.0.113.9|Uptime-Kuma/1.23.13|yes'
    do
        wl_ip=${wl_probe%%|*}
        wl_rest=${wl_probe#*|}
        wl_ua=${wl_rest%%|*}
        wl_want=${wl_rest##*|}
        wl_line=${sample/203.0.113.9/"$wl_ip"}
        wl_line=${wl_line/verify\/1.0/"$wl_ua"}
        if ! explain=$(cscli explain --type npm --log "$wl_line" 2>/dev/null); then
            warn "could not ask crowdsec to explain a whitelist probe ($wl_ip)"
            continue
        fi
        wl_hit=no
        printf '%s' "$explain" | grep -q 'stack/whitelists.*whitelisted' && wl_hit=yes
        if [ "$wl_want" = yes ]; then wl_text='is whitelisted'; else wl_text='is not whitelisted'; fi
        if [ "$wl_hit" = "$wl_want" ]; then
            pass "crowdsec whitelist: $wl_ip $wl_text"
        elif [ "$wl_want" = yes ]; then
            bad "crowdsec does not whitelist $wl_ip (stack/whitelists is not loading, or lost that range)"
        else
            bad "crowdsec whitelists public $wl_ip (stack-whitelists.yaml over-matches)"
        fi
    done
else
    warn "crowdsec unit is not installed (run deploy/install.sh)"
fi

# The other half of not banning the operator: stack-bouncer refuses to ENFORCE a
# ban on the host's own public address (STACK_WAN_IP, stack.conf), because
# traffic that leaves this host and comes back through the router's NAT loopback
# arrives with that one address as its source, and a decision against it takes
# the whole public surface down. A stale declaration is silently that
# self-lockout waiting to happen again, and an empty one is no protection at
# all, so compare it with the address NPM actually logs for the host's own
# monitoring: the Uptime-Kuma user agent is what identifies it (the agent
# clients share the address, but poll too rarely to rely on).
#
# The monitors no longer hairpin -- deploy/uptime-kuma.container resolves every
# vhost but MCP_HOST to the container's host gateway -- so MCP_HOST's monitor is
# the only public Uptime-Kuma source left, and it is the canary this check
# reads. Private sources are filtered out first: otherwise the internal
# monitors (192.168.1.112) would be the top entry and the WAN address would look
# unverified forever.
npm_logs="$DATA_DIR/npm/data/logs"
wan_seen=$(grep -h 'Uptime-Kuma/' "$npm_logs"/*_access.log 2>/dev/null \
    | sed -n 's/.*\[Client \([^]]*\)\].*/\1/p' \
    | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
if [ -z "${STACK_WAN_IP:-}" ]; then
    warn "no STACK_WAN_IP in stack.conf: a decision against the host's own public address (Uptime-Kuma, the MCP clients) will be enforced"
elif [ -z "$wan_seen" ]; then
    warn "STACK_WAN_IP=$STACK_WAN_IP is unverified (no public Uptime-Kuma request in $npm_logs -- the MCP_HOST canary has not run, or its monitor was removed)"
elif [ "$wan_seen" = "$STACK_WAN_IP" ]; then
    pass "stack-bouncer will not enforce a ban on the host's own public address ($STACK_WAN_IP)"
else
    warn "STACK_WAN_IP=$STACK_WAN_IP but NPM logs the host's own monitoring from $wan_seen (WAN change or a CDN? update stack.conf, then sudo ./bootstrap.sh)"
fi

# Render a deploy/root/ file the way install.sh does, so a drift check compares
# what bootstrap would write, not the literal template. The substitution list
# itself lives in scripts/lib.sh (render_root_template), which install.sh's
# root_render also calls -- one list, so a new placeholder cannot make a
# correctly installed file look permanently drifted.
root_want() { # src
    render_root_template "$1" "$DATA_DIR"
}

# Everything install.sh --root renders from deploy/root/, as source:target[:opt].
# Content only -- bootstrap owns the modes. Two kinds of file are absent on
# purpose: the 0600 env files it writes from heredocs (audit.env, bouncer.env),
# and /etc/audit/rules.d/60-stack.rules, which it writes 0640 into a 0750
# directory -- an unprivileged sweep cannot read it at all, and `auditctl -l`
# needs CAP_AUDIT_CONTROL, so the audit section reads the report's verdict
# instead.
# `opt` marks a target that is legitimately absent until there is a bouncer key
# in secrets.env (the second bootstrap pass installs it): skip those silently
# when missing, since the bouncer block above already reports its own state.
ROOT_FILES=(
    "deploy/root/suricata.container:/etc/containers/systemd/suricata.container"
    "deploy/root/suricata/suricata.yaml:/etc/stack-ids/suricata/suricata.yaml"
    "deploy/root/suricata/threshold.conf:/etc/stack-ids/suricata/threshold.conf"
    "deploy/root/suricata/disable.conf:/etc/stack-ids/suricata/disable.conf"
    "deploy/root/suricata/start.sh:/etc/stack-ids/suricata/start.sh"
    "deploy/root/suricata/rules/local.rules:/etc/stack-ids/suricata/rules/local.rules"
    "deploy/root/logrotate-stack-ids:/etc/logrotate.d/stack-ids"
    "deploy/root/audit-report.sh:/etc/stack-ids/audit-report.sh"
    "deploy/root/status.sh:/etc/stack-ids/status.sh"
    "deploy/root/stack-audit.service:/etc/systemd/system/stack-audit.service"
    "deploy/root/stack-audit.timer:/etc/systemd/system/stack-audit.timer"
    "deploy/root/bouncer.sh:/etc/stack-ids/bouncer.sh:opt"
    "deploy/root/ipguard.py:/etc/stack-ids/ipguard.py:opt"
    "deploy/root/stack-bouncer.service:/etc/systemd/system/stack-bouncer.service:opt"
    "deploy/root/stack-bouncer.timer:/etc/systemd/system/stack-bouncer.timer:opt"
)

if [ -f /etc/containers/systemd/suricata.container ]; then
    if systemctl is-active --quiet suricata 2>/dev/null; then
        pass "suricata is active"
    else
        bad "suricata is not active (sudo systemctl status suricata)"
    fi
    # Rotation is the host logrotate's job (a static filename is never rotated
    # by Suricata's rotate-interval). The file size is the signal that it
    # stopped: a daily rotation keeps eve.json well under 100 MB, so 500 MB
    # means ~a week of unrotated growth and the disk is the loser.
    eve_file="$DATA_DIR/ids/suricata/eve.json"
    if [ -s "$eve_file" ]; then
        eve_mb=$(( $(stat -c %s "$eve_file" 2>/dev/null || echo 0) / 1048576 ))
        if [ "$eve_mb" -gt 500 ]; then
            warn "suricata eve.json is ${eve_mb} MB -- logrotate is not rotating it (systemctl status logrotate.timer)"
        else
            pass "suricata eve.json is ${eve_mb} MB (rotated by logrotate)"
        fi
    fi
    if systemctl is-active --quiet logrotate.timer 2>/dev/null; then
        pass "logrotate.timer is active (EVE rotation)"
    else
        warn "logrotate.timer is not active; eve.json and alerts.json will not rotate"
    fi
    # A rendered file that no longer matches the repo means someone edited
    # deploy/root/ without re-running bootstrap -- the root tier is then not the
    # one in git, which is exactly the drift the digest check exists for. It is
    # checked over every rendered file because the config matters as much as the
    # unit: suricata reads /etc/stack-ids/suricata/suricata.yaml, so a unit-only
    # check reported a clean sweep while the engine ran a config nobody had
    # committed.
    root_checked=0 root_faults=0
    for row in "${ROOT_FILES[@]}"; do
        src=${row%%:*}
        rest=${row#*:}
        opt=""
        case "$rest" in
            *:*) dst=${rest%%:*}; opt=${rest#*:} ;;
            *)   dst=$rest ;;
        esac
        [ -f "$REPO_DIR/$src" ] || continue
        if [ ! -f "$dst" ]; then
            [ "$opt" = opt ] && continue
            warn "rendered $dst is missing (sudo ./bootstrap.sh installs it)"
            root_faults=$((root_faults + 1))
            continue
        fi
        root_checked=$((root_checked + 1))
        if ! root_want "$REPO_DIR/$src" | diff -q - "$dst" >/dev/null 2>&1; then
            warn "rendered $dst differs from $src (sudo ./bootstrap.sh re-renders it)"
            root_faults=$((root_faults + 1))
        fi
    done
    if [ "$root_faults" -eq 0 ]; then
        pass "rendered root-tier files match deploy/root/ ($root_checked files)"
    else
        warn "$root_faults rendered root-tier file(s) are stale -- the root tier is not what is in git"
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
