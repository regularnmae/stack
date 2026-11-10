#!/usr/bin/env bash
# Verify the running stack.
#
#   ./verify.sh                 # shallow: container health, the MCP endpoints
#                               # (token-gated: 401, then an authenticated
#                               # initialize) and every onion service declared
#                               # in services.toml, via tor
#   ./verify.sh --deep          # additionally call one read tool per endpoint,
#                               # proving the path through to the daemon, and
#                               # compare Fulcrum's index height with bitcoind's
#   ./verify.sh --no-nodes      # the chain daemons were skipped (deploy.sh
#                               # --skip-daemons); don't call them missing
#
# The scheduled jobs' own health is scripts/monitor.sh's, not this script's: a
# second copy here would be a quieter answer to the same question. This is the
# diagnostic -- the container and MCP surface, the chains, the proxy/onion paths,
# and the config drift only a human run should act on. docs/units.md,
# docs/proxy.md and docs/ids.md own the reasoning.
#
# Run it on the host: it reads containers with podman and reaches each MCP server
# on npm-network as <container>:8000 through the long-lived `netcheck` container
# (scripts/lib.sh says why not a throwaway `podman run` per probe), except
# nginx-proxy-manager, which owns the host network and is read on 127.0.0.1.
#
# Read-only against the stack: it starts nothing, writes nothing in $DATA_DIR and
# changes no unit. It does resolve the data dir like every host script, so a host
# whose pointer is missing gets ~/.config/stack/data-dir.env written. Exits
# non-zero if anything is wrong.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
# The public surface (the *_HOST names, the MCP prefixes, the onion services) is
# declared in deploy/services.toml; stack.conf keeps the non-registry knobs.
load_manifest "$REPO_DIR"
# The tokens live under the data dir, so resolving it is how we find them.
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
# The inventory is the declaration, not a list here: install.sh renders every
# deploy/*.container[.in], so that directory is what this host runs. Type=oneshot
# units have finished by the time a sweep starts, so they are not containers to
# find up. `--no-nodes` drops stack.conf's CHAIN_UNITS.
containers=()
for _f in "$REPO_DIR"/deploy/*.container "$REPO_DIR"/deploy/*.container.in; do
    [ -f "$_f" ] || continue
    if grep -qE '^Type=oneshot[[:space:]]*$' "$_f"; then
        continue
    fi
    _c=$(basename "$_f"); _c="${_c%.in}"; _c="${_c%.container}"
    if [ "$NO_NODES" = 1 ] && unit_in_set "$_c" "${CHAIN_UNITS[*]:-}"; then
        continue
    fi
    containers+=("$_c")
done
unset _f _c
[ "${#containers[@]}" -gt 0 ] \
    || die "no container units found under $REPO_DIR/deploy (is this the checkout?)"
if [ "$NO_NODES" = 1 ]; then
    warn "daemon tier skipped by request; not checking ${CHAIN_UNITS[*]:-}"
fi
# Units that cannot define a health command are declared once in stack.conf's
# HEALTHLESS_UNITS (victoria-logs is distroless; the netcheck clients just sleep
# until something execs into them). scripts/healthcheck-lint.sh keeps that
# declaration and the units in agreement; here it only decides what an "Up but
# unprobed" container means.
healthless=" "
for _u in "${HEALTHLESS_UNITS[@]:-}"; do
    healthless+="${_u%%|*} "
done
# One classifier for every container check in this file, because a failing probe
# still reads "Up ... (unhealthy)" and a warning never increments fails -- so the
# monitor, which carries only FAIL lines and the exit code, could not see it.
# `starting` stays a warning on purpose: podman promotes a probe that never
# succeeds to (unhealthy) after HealthStartPeriod x retries, so the state is
# bounded and transient, while a FAIL there would page on every ordinary restart.
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

# NPM on the host network is what makes a client's real address reach its logs
# and X-Forwarded-For: a rootless published port cannot (rootlessport forwards
# from inside the namespace, so NPM would see its own address), which is also why
# every service it fronts publishes on the host's loopback. See docs/proxy.md.
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
# These are built here, not pulled, so a healthy container says nothing about
# whether its image still matches its Containerfile -- a merged base-image bump
# changes only that file. deploy.sh and install.sh rebuild on the label mismatch
# (scripts/lib.sh's image_is_current); a stale image is a warning, because the
# service is running the last good bits.
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
# never applied is invisible to every health check. install.sh records what it
# rendered ($DATA_DIR/audit/units.rendered); deploy.sh and scripts/rotate.sh
# record what they applied (units.applied). Comparing the live digests against
# that applied set catches a hand render, a hand edit and an interrupted deploy.
# It is a FAIL, not a warning: the monitor carries only verify's FAIL lines.
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
# The monitor's alert path is the host's own curl + jq (Alertmanager is a loopback
# bind, the heartbeat an outbound POST), and openssl reads certificate expiry and
# runs Fulcrum's TLS probe. They are requirements, not conveniences: a missing one
# turns a check off silently, which is how a stack looks healthy while nothing can
# page. bootstrap.sh installs all three.
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
    # btcpay, nbxplorer and monero-wallet-btcpay are already in the container
    # inventory above, so check_container owns their state; this section owns the
    # functional question. The same endpoint the backend's /health uses: a 200
    # means BTCPay and its database serve, not merely that the container is up.
    btcpay_health=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 http://btcpay:49392/api/v1/health 2>/dev/null || echo 000)
    if [ "$btcpay_health" = "200" ]; then
        pass "BTCPay /api/v1/health 200"
    else
        bad "BTCPay /api/v1/health -> $btcpay_health"
    fi
fi

# ---------------------------------------------------------------------------
head2 "MCP endpoints"
# The servers, their token variable, the one deep tool each answers and whether it
# needs a chain are declared in deploy/services.toml ([mcp.*]) and emitted by the
# manifest as index-aligned arrays, so a server added there is probed here with no
# second table to keep in step. The token file is the container's own token.env;
# scripts/lib.sh decides where it is reached (mcp_base / mcp_curl) -- by name on
# npm-network, except crowdsec-mcp (host network, 127.0.0.1:8113). MCP_PORTS[$i] is
# the loopback publish NPM fronts; the spend column is rotate.sh's, unused here.
if [ "${PROBE_TOKEN_VARS+x}" != x ] || [ "${#MCP_CONTAINERS[@]}" -eq 0 ]; then
    die "the manifest emitted no probe table (run ./deploy.sh)"
fi
# A column shorter than the others would pair a container with another server's
# token, silently.
manifest_columns_agree() {
    local n
    for n in "${#PROBE_TOKEN_VARS[@]}" "${#PROBE_TOOLS[@]}" "${#PROBE_ARGS[@]}" \
             "${#PROBE_NEEDS_NODES[@]}" "${#PROBE_SPEND_VARS[@]}" \
             "${#MCP_PREFIXES[@]}" "${#MCP_PORTS[@]}"; do
        [ "$n" -eq "${#MCP_CONTAINERS[@]}" ] || return 1
    done
    return 0
}
manifest_columns_agree \
    || die "the manifest emission is ragged (its columns differ in length)"

# Each endpoint's token file and variable, keyed by container, for the proxy
# section below.
declare -A EP_ENV=() EP_VAR=()

for i in "${!MCP_CONTAINERS[@]}"; do
    name="${MCP_CONTAINERS[$i]}"
    var="${PROBE_TOKEN_VARS[$i]}"
    tool="${PROBE_TOOLS[$i]}"
    args="${PROBE_ARGS[$i]}"
    needs_nodes="${PROBE_NEEDS_NODES[$i]}"
    envfile="$CONFIG_DIR/$name/token.env"
    EP_ENV["$name"]="$envfile"
    EP_VAR["$name"]="$var"

    # mcp_curl picks netcheck or netcheck-host and the base URL for this
    # container (scripts/lib.sh).
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
        # server legitimately negotiates down -- but this client's pinned
        # MCP_PROTOCOL_VERSION is then not what the server speaks, and nothing
        # else in the stack would notice.
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
# (NPM owns the host network, so the upstream is that unit's loopback publish).
# Read through NPM's own :80 with the real Host header, so this works before
# public DNS and TLS exist. A configured host answers 401 without a token and a
# serverInfo handshake with one; an unconfigured one does neither -- a warning,
# not a failure, until it is set up.
if [ "${MCP_PREFIXES+x}" != x ] || [ "${#MCP_PREFIXES[@]}" -eq 0 ]; then
    warn "no MCP prefixes are declared in deploy/services.toml; skipping the proxy checks"
else
    for i in "${!MCP_PREFIXES[@]}"; do
        prefix="${MCP_PREFIXES[$i]}"; name="${MCP_CONTAINERS[$i]}"
        # Probe the public URL but connect to NPM itself (--connect-to): SNI and
        # Host stay the real host, so the certificate still validates before
        # public DNS exists. NPM binds :80/:443 on the host, hence 127.0.0.1.
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
# The skills plus `agent-mcp` from the agent-skills repo: the same servers, through
# the same tokens, for harnesses that do not speak MCP (Codex, a plain shell, CI).
# The registry reads $DATA_DIR/config/<server>/token.env on every call -- never a
# copy -- so a rotated token needs no second edit. A host that only serves has
# none of it: a warning, not a failure. The live call is --deep only, so the
# shallow sweep stays offline.
AGENT_BIN="${AGENT_MCP_BIN:-$HOME/.local/bin/agent-mcp}"
AGENT_DIR="$BUILD_DIR/${AGENT_SKILLS_REPO:-agent-skills}"
# agent-mcp's revision is hand-maintained in scripts/lib.sh too
# (MCP_PROTOCOL_VERSION): two clients of the same servers must name the same one,
# so a bump on one side only is drift. Read the constant, never import the module.
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
    # Enumerate the clone, never a copy of its list: a hand-written list goes
    # stale silently, and "every skill is linked" then passes while links are
    # missing.
    skills=()
    if [ -d "$AGENT_DIR/skills" ]; then
        for skill_dir in "$AGENT_DIR"/skills/*/; do
            [ -f "$skill_dir/SKILL.md" ] && skills+=("$(basename "$skill_dir")")
        done
    fi
    if [ "${#skills[@]}" -eq 0 ]; then
        warn "cannot enumerate the skills ($AGENT_DIR/skills is missing); skipping the link check (./deploy.sh --only agent-skills re-clones them)"
    else
        missing=()
        for harness in "$HOME/.config/opencode" "$HOME/.codex" "$HOME/.claude"; do
            [ -d "$harness" ] || continue
            for skill in "${skills[@]}"; do
                [ -e "$harness/skills/$skill/SKILL.md" ] || missing+=("$harness/skills/$skill")
            done
        done
        if [ "${#missing[@]}" -eq 0 ]; then
            pass "every skill is linked into the harnesses installed here (${#skills[@]})"
        else
            bad "${#missing[@]} skill link(s) missing (e.g. ${missing[0]}); run ./deploy.sh --only agent-skills"
        fi
    fi

    # servers.json is the skills' copy of the public surface: one URL per MCP
    # prefix. A prefix that moved in the manifest and not here makes a skill call
    # a URL nginx-proxy-manager no longer serves, so compare the resolved registry
    # with the declaration through the CLI's own resolver -- never a second copy of
    # the expansion rules. The host only warns: AGENT_MCP_BASE_URL pointing at
    # another stack is the operator's call, a missing prefix is not.
    if [ -r "$AGENT_DIR/lib/config.py" ] && command -v python3 >/dev/null 2>&1 \
       && [ "${MCP_PREFIXES+x}" = x ] && [ "${#MCP_PREFIXES[@]}" -gt 0 ]; then
        agent_urls=()
        while IFS= read -r url; do
            [ -n "$url" ] && agent_urls+=("$url")
        done < <(
            python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from config import load_servers, resolve_url; print("\n".join(resolve_url(e) for e in load_servers().values()))' \
                "$AGENT_DIR/lib" 2>/dev/null
        )
        drift=()
        for prefix in "${MCP_PREFIXES[@]}"; do
            printf '%s\n' "${agent_urls[@]}" | grep -qE "^[a-z]+://[^/]+${prefix}$" \
                || drift+=("$prefix")
        done
        if [ "${#drift[@]}" -gt 0 ]; then
            bad "servers.json does not cover ${drift[*]} (did a manifest prefix change?); update $AGENT_DIR/servers.json"
        elif [ "${#agent_urls[@]}" -ne "${#MCP_PREFIXES[@]}" ]; then
            bad "servers.json declares ${#agent_urls[@]} endpoint(s) for ${#MCP_PREFIXES[@]} declared prefix(es)"
        else
            pass "servers.json matches every declared MCP prefix"
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
        warn "servers.json not compared with the declared prefixes (no $AGENT_DIR clone, no python3, or none declared)"
    fi

    if [ "$DEEP" = 1 ] && [ "$NO_NODES" = 0 ]; then
        if out=$("$AGENT_BIN" bitcoin-node get_blockchain_info 2>&1); then
            pass "agent-mcp read the bitcoin node (chain $(printf '%s' "$out" | jq -r '.chain // "?"'))"
        else
            bad "agent-mcp could not call bitcoin-node: $(printf '%s' "$out" | head -1)"
        fi
    elif [ "$DEEP" = 1 ]; then
        warn "agent-mcp deep call skipped (needs a chain node)"
    fi
fi

# ---------------------------------------------------------------------------
head2 "Onion services (tor)"
# The same public surface without DNS or a certificate: tor publishes one hidden
# service per [onion.*] entry. The address is read from tor's own data dir because
# it is key material and not declared. The probe goes through tor's SOCKS port
# from netcheck on npm-network (torrc's SocksPolicy allows nothing else) and lets
# tor resolve the .onion itself (--socks5-hostname), as a client does. "No answer"
# is a warning: a fresh service takes a minute to become reachable. The mcp entry
# expects 401, which proves the onion -> NPM -> container path and the token gate,
# since NPM cannot match an onion by name (see [npm.onion_wildcard]).
TOR_SOCKS="${TOR_SOCKS:-10.89.0.240:9050}"
if [ "${ONION_NAMES+x}" != x ] || [ "${#ONION_NAMES[@]}" -eq 0 ]; then
    warn "no onion services are declared in deploy/services.toml; skipping the onion checks"
else
    for i in "${!ONION_NAMES[@]}"; do
        name="${ONION_NAMES[$i]}"; mirrors="${ONION_MIRRORS[$i]}"
        path="${ONION_PATHS[$i]}"; expect="${ONION_CODES[$i]}"
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
# The API's /health is deep: 200 only when it reaches postgres and valkey. Read
# as a peer on npm-network; NPM reaches the same server on its loopback publish.
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
# Both explorers are read as peers on npm-network; NPM reaches them on their
# loopback publishes. An RPC-backed request proves more than a bare 200 on a
# static page: BTC's /api/blocks/tip reads bitcoind, and MoneroBlock's / calls
# get_info and get_block_headers_range against monerod.
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

    # The home page exercises monerod's restricted RPC, which is slow enough to
    # time out during initial sync, so this is a warning -- monerod's own
    # freshness is the monitor's check.
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
# Fulcrum is the one service that is not HTTP: Electrum is newline-delimited
# JSON-RPC over raw TCP (50001) and TLS (50002), so neither net_curl nor
# nginx-proxy-manager can read it. Its healthcheck is the process table
# (`grep -qx Fulcrum /proc/1/comm`), which a wedged index passes forever. The
# probes dial the host's loopback publishes -- what a wallet on the LAN reaches
# (see scripts/lib.sh, docs/chains.md).
if [ "$NO_NODES" = 1 ]; then
    warn "chain daemons skipped by request; not checking Fulcrum"
else
    # One getblockchaininfo for the whole section: it decides whether a silent
    # 50001 is broken or just a first-run index that has not caught up.
    btc_chain=$(bitcoind_cli getblockchaininfo 2>/dev/null || true)
    btc_ibd=$(printf '%s' "$btc_chain" | jq -r 'if has("initialblockdownload") then .initialblockdownload else empty end' 2>/dev/null || true)
    btc_blocks=$(printf '%s' "$btc_chain" | jq -r '.blocks // empty' 2>/dev/null || true)

    # server.version is the banner: it names the server and the protocol revision,
    # the cheapest proof that something speaks Electrum rather than merely
    # listening (a stuck app behind a listening socket passes a TCP connect).
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
        # The index-backed question: server.version comes from memory and stays
        # green on a wedged index, so the height separates "serving" from "serving
        # stale". A big gap is either a first index or a stall -- scripts/monitor.sh
        # decides which, and pages (docs/chains.md).
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
# Uptime-Kuma serves its dashboard SPA at /, a peer on npm-network. Through NPM it
# answers 200 (a login page) rather than 401, and any 200 from the SPA still proves
# the proxy host is wired before an admin account or a status page exists.
#
# It answers / with a 302 to /dashboard, so the probes follow redirects; -L follows
# only kuma's own, the 80 -> 443 dance is done by hand as in the MCP section.
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

# A published status page answers its data endpoint without auth, so this runs by
# container name and needs no token. A 404 means the page does not exist yet, not
# that the monitor is broken: pages and their monitors are authored in kuma's UI
# (docs/proxy.md), so this only names the missing publish.
if [ "${KUMA_STATUS_SLUG+x}" = x ] && [ -n "$KUMA_STATUS_SLUG" ]; then
    slug_code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 \
        "http://uptime-kuma:3001/api/status-page/$KUMA_STATUS_SLUG" 2>/dev/null || echo 000)
    case "$slug_code" in
        200) pass "status page '$KUMA_STATUS_SLUG' is published" ;;
        404) warn "status page '$KUMA_STATUS_SLUG' is not published yet (publish it in the Uptime-Kuma UI)" ;;
        *)   warn "status page '$KUMA_STATUS_SLUG' -> $slug_code" ;;
    esac
fi

# The monitors must resolve their vhosts to the host gateway, not the public name:
# otherwise every check leaves the host and returns as the WAN address. A warning,
# not a failure -- Uptime-Kuma is UI-configured, and a hand-added monitor may still
# hairpin. Read /etc/hosts because it is exactly what podman wrote from --add-host.
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
head2 "Intrusion detection"
# Two tiers, and they fail differently: crowdsec is an ordinary rootless user unit,
# so this sweep can talk to it; suricata is the repo's one ROOTFUL unit (AF_PACKET
# needs CAP_NET_RAW in the init namespace), installed by `sudo ./bootstrap.sh`. A
# host that never re-ran bootstrap has no sensor: a warning, not a failure.
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/crowdsec.container" ]; then
    # The parser is the detection chain's front door: two replayed lines through
    # cscli explain prove it still matches NPM's log format, which a format change
    # would otherwise break silently. The second is the shape that traps naive
    # parsers -- NPM logs $upstream_status before $status, and it is "-" whenever
    # no upstream was contacted (the 301 onto https, a 499 on a client abort).
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
    # The packet tier's half: Suricata's EVE alert must reach a scenario, and a
    # loopback-sourced one must be whitelisted first -- that leg is NPM
    # re-originating and has no client identity. A parser rename, an acquisition
    # label change or a missing scenario fails here instead of silently disabling
    # enforcement.
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
    # produces no decisions and no error anyone reads, so prove the read. The label
    # is the usual failure (a default_t file is unreadable).
    if podman exec crowdsec sh -c 'test -r /ids/suricata/alerts.json' 2>/dev/null; then
        pass "crowdsec can read Suricata's alert feed"
    else
        warn "crowdsec cannot read /ids/suricata/alerts.json (sensor not installed, or the file lost its container label)"
    fi
    # The whitelist fails QUIETLY: its expressions are plain string matches and the
    # parser runs in s02-enrich, before any scenario, so a prefix one octet too short
    # reports traffic as `whitelisted` and it can never become a decision. Probe both
    # directions: over-matching hides detections, while under-matching -- a file that
    # stopped loading, or a range that lost its entry -- bans the onion path and the
    # status page. The Uptime-Kuma probe is the one the stock
    # crowdsecurity/whitelists cannot answer for us, so it proves this file loads.
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

# stack-bouncer refuses to ENFORCE a ban on the host's own public address
# (STACK_WAN_IP, stack.conf): traffic returning through the router's NAT loopback
# arrives with it as its source, so a decision against it takes the whole public
# surface down -- an empty value protects nothing, a stale one is the same
# self-lockout. Compare it with the address NPM logs for the host's own monitoring,
# identified by the Uptime-Kuma user agent (the agent clients share it but poll too
# rarely). The status page's MCP_HOST monitor is the canary (docs/proxy.md); private
# sources are filtered first, or the internal monitors would be the top entry.
npm_logs="$DATA_DIR/npm/data/logs"
wan_seen=$(grep -h 'Uptime-Kuma/' "$npm_logs"/*_access.log 2>/dev/null \
    | sed -n 's/.*\[Client \([^]]*\)\].*/\1/p' \
    | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
if [ -z "${STACK_WAN_IP:-}" ]; then
    warn "no STACK_WAN_IP in stack.conf: a decision against the host's own public address (Uptime-Kuma, the MCP clients) will be enforced"
elif [ -z "$wan_seen" ]; then
    warn "STACK_WAN_IP=$STACK_WAN_IP is unverified (no public Uptime-Kuma request in $npm_logs -- the MCP_HOST canary has not run, or the status page's MCP monitor was removed)"
elif [ "$wan_seen" = "$STACK_WAN_IP" ]; then
    pass "stack-bouncer will not enforce a ban on the host's own public address ($STACK_WAN_IP)"
else
    warn "STACK_WAN_IP=$STACK_WAN_IP but NPM logs the host's own monitoring from $wan_seen (WAN change or a CDN? update stack.conf, then sudo ./bootstrap.sh)"
fi

# Render a deploy/root/ file the way install.sh does, so a drift check compares
# what bootstrap would write, not the literal template. The substitution list is
# scripts/lib.sh's render_root_template, which install.sh's root_render also calls
# -- one list, so a new placeholder cannot make a correct file look drifted.
root_want() { # src
    render_root_template "$1" "$DATA_DIR"
}

# Everything install.sh --root renders from deploy/root/, as source:target[:opt].
# Content only, bootstrap owns the modes. Deliberately absent: the 0600 env files it
# writes from heredocs (audit.env, bouncer.env), and /etc/audit/rules.d/60-stack.rules,
# which an unprivileged sweep cannot read (the audit section reads the verdict).
# `opt` marks a target legitimately absent until a bouncer key exists in
# secrets.env: skip it silently, the bouncer block reports itself.
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
    # Rotation is the host logrotate's job: a static filename is never rotated by
    # Suricata's rotate-interval, and the file size is the only signal that it
    # stopped (the threshold is generous; docs/ids.md owns the rotation).
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
    # A rendered file that no longer matches the repo means deploy/root/ was edited
    # without re-running bootstrap, so the host is not on what git holds. Every
    # rendered file is compared, not just the unit: suricata reads
    # /etc/stack-ids/suricata/suricata.yaml, so a unit-only check would report a
    # clean sweep while the engine ran an uncommitted config.
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
    # The ruleset cannot be checked from here: `auditctl -l` needs CAP_AUDIT_CONTROL,
    # so an unprivileged verify would always see zero rules. The status file above is
    # the signal; `sudo auditctl -l | grep stack_` is the manual check.
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
