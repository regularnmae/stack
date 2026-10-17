#!/usr/bin/env bash
# Serve every MCP server under one TLS hostname, as path prefixes, through
# nginx-proxy-manager:
#
#   https://mcp.boltmesh.net/searxng        -> searxng-mcp:8000/mcp
#   https://mcp.boltmesh.net/bitcoin        -> bitcoin-node-mcp:8000/mcp
#   https://mcp.boltmesh.net/monero         -> monero-node-mcp:8000/mcp
#   https://mcp.boltmesh.net/monero-wallet  -> monero-wallet-mcp:8000/mcp
#   https://mcp.boltmesh.net/lightning      -> lightning-mcp:8000/mcp
#
#   scripts/npm-mcp-hosts.sh            # create or update the proxy host
#   scripts/npm-mcp-hosts.sh --dry-run  # print the payload; change nothing
#
# The public host, the prefixes and the containers come from MCP_HOST/MCP_HOSTS
# in stack.conf. Every MCP server serves the streamable-HTTP transport at /mcp
# (the SDK default); the public URL hides that, mapping each prefix straight
# onto /mcp, so a client uses https://<MCP_HOST>/<prefix> with an
# `Authorization: Bearer <token>` header.
#
# nginx-proxy-manager publishes the only host port in the stack and is the only
# way in, so this is configuration of a running service, applied through its
# admin API on 81 rather than by hand. Credentials live in
# $DATA_DIR/config/npm/api.env (mode 600), seeded by deploy/install.sh.
#
# Streamable HTTP replies with text/event-stream, so the host turns nginx
# buffering off (an SSE body buffered until the buffer fills just hangs the MCP
# client) and sets the long read timeout a slow tool call needs.
#
# Idempotent: a host already serving $MCP_HOST is updated in place, otherwise
# one is created. Re-run it after changing MCP_HOSTS, or ./deploy.sh --only npm-mcp-hosts.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
. "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage_header "$0"; exit 0 ;;
        *)         die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

MCP_HOST="${MCP_HOST:-mcp.boltmesh.net}"
MCP_PORT="${MCP_PORT:-8000}"
# The admin API answers on the container's published 81; read it by container
# name the way every other host-side check reads a service (net_curl).
NPM_API="${NPM_API_URL:-http://nginx-proxy-manager:81}"

# jq parses the API's JSON responses; net_curl is only curl. bootstrap.sh
# installs it -- this is the clear error for a host provisioned before that.
command -v jq >/dev/null 2>&1 \
    || die "jq is required to read the nginx-proxy-manager API. Install it: sudo dnf install -y jq"

if [ "${MCP_HOSTS+x}" != x ] || [ "${#MCP_HOSTS[@]}" -eq 0 ]; then
    die "MCP_HOSTS is empty; set it in stack.conf"
fi

resolve_data_dir
NPM_ENV="$CONFIG_DIR/npm/api.env"

NPM_EMAIL="${NPM_EMAIL:-$(env_value "$NPM_ENV" NPM_EMAIL)}"
NPM_PASSWORD="${NPM_PASSWORD:-$(env_value "$NPM_ENV" NPM_PASSWORD)}"
NPM_TOKEN="${NPM_TOKEN:-$(env_value "$NPM_ENV" NPM_TOKEN)}"
NPM_CERT_ID="${NPM_CERT_ID:-$(env_value "$NPM_ENV" NPM_CERT_ID)}"
NPM_REQUEST_CERT="${NPM_REQUEST_CERT:-$(env_value "$NPM_ENV" NPM_REQUEST_CERT)}"
NPM_REQUEST_CERT="${NPM_REQUEST_CERT:-1}"

if [ -z "$NPM_TOKEN" ] && { [ -z "$NPM_EMAIL" ] || [ -z "$NPM_PASSWORD" ]; }; then
    log "no nginx-proxy-manager API credentials in $NPM_ENV"
    log "fill in NPM_EMAIL/NPM_PASSWORD (the admin login) or NPM_TOKEN, then re-run"
    exit 0
fi

# --- JSON / curl-config escaping ------------------------------------------
# The token request carries the admin password in the BODY, so it goes out as a
# curl config on stdin (`-K -`), never on a command line `ps` can read. Two
# layers of escaping hold that together: a value must be a valid JSON string,
# and the whole JSON must be a valid double-quoted value in the curl config.
# (Only the password is secret here; every other body -- nginx directives, host
# and container names -- is not.)
json_escape()   { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'; }
config_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

TOKEN_CFG=""
if [ -n "$NPM_EMAIL" ] && [ -n "$NPM_PASSWORD" ]; then
    login_json=$(printf '{"identity":"%s","secret":"%s"}' \
        "$(printf '%s' "$NPM_EMAIL" | json_escape)" \
        "$(printf '%s' "$NPM_PASSWORD" | json_escape)")
    TOKEN_CFG=$(printf 'url = "%s/api/tokens"\nrequest = "POST"\nheader = "Content-Type: application/json"\ndata = "%s"\n' \
        "$NPM_API" "$(printf '%s' "$login_json" | config_escape)")
fi

# A short-lived NPM token expires, so a plain login is preferred when the admin
# credentials are present; NPM_TOKEN is the fallback for a host that stores only
# a token. On success NPM_TOKEN holds a bearer token (both paths end there).
npm_login() {
    local resp
    resp=$(printf '%s' "$TOKEN_CFG" | net_curl -s -m 60 -K - 2>/dev/null) || return 1
    NPM_TOKEN=$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null)
    [ -n "$NPM_TOKEN" ]
}

# One admin API call. The bearer goes in a curl config on stdin, so it never
# reaches the host's argv. Prints the response body; never fails the script --
# callers check what came back.
npm_call() { # METHOD PATH [JSON_BODY]
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$NPM_TOKEN" \
            | net_curl -s -m 120 -K - -H 'Content-Type: application/json' \
                -X "$method" "$NPM_API$path" -d "$body" || true
    else
        printf 'header = "Authorization: Bearer %s"\n' "$NPM_TOKEN" \
            | net_curl -s -m 120 -K - -X "$method" "$NPM_API$path" || true
    fi
}

# --- the proxy host payload -----------------------------------------------
# Streaming settings, applied at server scope so every location inherits them.
# `Connection` is cleared (NPM's per-location proxy.conf sets it per request, so
# this only covers the paths that do not) and buffering is off for SSE.
ADVANCED_JSON='proxy_buffering off;\nproxy_cache off;\ngzip off;\nproxy_read_timeout 3600s;\nproxy_send_timeout 3600s;\nproxy_http_version 1.1;\nproxy_set_header Connection \"\";\nchunked_transfer_encoding on;'

locations=""
for pair in "${MCP_HOSTS[@]}"; do
    prefix="${pair%%:*}"
    host="${pair##*:}"
    [ -n "$prefix" ] && [ -n "$host" ] || die "bad MCP_HOSTS entry: $pair (want \"/prefix:container\")"
    obj=$(printf '{"path":"%s","forward_scheme":"http","forward_host":"%s","forward_port":%s,"forward_path":"/mcp","access_list_id":0}' \
        "$prefix" "$host" "$MCP_PORT")
    locations="${locations:+$locations,}$obj"
done
# The root path is not part of the contract; NPM still needs a forward for it.
default_host="${MCP_HOSTS[0]##*:}"

build_payload() { # certificate_id ssl_forced http2_support
    printf '{"domain_names":["%s"],"forward_scheme":"http","forward_host":"%s","forward_port":%s,"certificate_id":%s,"ssl_forced":%s,"http2_support":%s,"block_exploits":false,"caching_enabled":false,"allow_websocket_upgrade":false,"access_list_id":0,"enabled":true,"advanced_config":"%s","locations":[%s]}' \
        "$MCP_HOST" "$default_host" "$MCP_PORT" "$1" "$2" "$3" "$ADVANCED_JSON" "$locations"
}

print_urls() {
    log "MCP endpoints (Authorization: Bearer <token from the file named below>):"
    local pair
    for pair in "${MCP_HOSTS[@]}"; do
        printf '  https://%s%s  (%s/%s/token.env)\n' \
            "$MCP_HOST" "${pair%%:*}" "$CONFIG_DIR" "${pair##*:}"
    done
}

# --- talk to nginx-proxy-manager ------------------------------------------
log "configuring https://$MCP_HOST/<prefix> -> the MCP servers, through $NPM_API"

if [ -n "$NPM_EMAIL" ] && [ -n "$NPM_PASSWORD" ]; then
    npm_login || die "could not get a token from $NPM_API/api/tokens (check NPM_EMAIL/NPM_PASSWORD in $NPM_ENV)"
fi

hosts=$(npm_call GET /api/nginx/proxy-hosts)
existing_id=$(printf '%s' "$hosts" | jq -r --arg d "$MCP_HOST" \
    '[.[]? | select((.domain_names // []) | index($d)) | .id] | (.[0] // empty)' 2>/dev/null || true)

# The certificate: an explicit NPM_CERT_ID wins, else reuse an existing
# Let's Encrypt cert that covers $MCP_HOST, else request one.
cert_id=""
if [ -n "$NPM_CERT_ID" ]; then
    cert_id="$NPM_CERT_ID"
else
    certs=$(npm_call GET /api/nginx/certificates)
    cert_id=$(printf '%s' "$certs" | jq -r --arg d "$MCP_HOST" \
        '[.[]? | select(.provider=="letsencrypt") | select((.domain_names // []) | index($d))] | max_by(.id) | .id // empty' 2>/dev/null || true)
fi

if [ -z "$cert_id" ] && [ "$NPM_REQUEST_CERT" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would request a Let's Encrypt certificate for $MCP_HOST"
    else
        log "requesting a Let's Encrypt certificate for $MCP_HOST (needs its DNS and :80 to reach this host)"
        cert_payload=$(printf '{"provider":"letsencrypt","nice_name":"%s","domain_names":["%s"],"meta":{"dns_challenge":false}}' \
            "$MCP_HOST" "$MCP_HOST")
        cert_resp=$(npm_call POST /api/nginx/certificates "$cert_payload")
        cert_id=$(printf '%s' "$cert_resp" | jq -r '.id // empty' 2>/dev/null || true)
        if [ -z "$cert_id" ]; then
            warn "Let's Encrypt did not issue a certificate; the host will be plain HTTP"
            printf '%s\n' "$cert_resp" | sed 's/^/  | /' >&2
            warn "finish it in the admin UI (81), set NPM_CERT_ID in $NPM_ENV, and re-run"
        fi
    fi
fi

ssl_forced=false
http2=false
if [ -n "$cert_id" ] && [ "$cert_id" != 0 ]; then
    ssl_forced=true
    http2=true
fi
[ -n "$cert_id" ] || cert_id=0

payload=$(build_payload "$cert_id" "$ssl_forced" "$http2")

if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$existing_id" ]; then
        log "[dry-run] would update proxy host $existing_id for $MCP_HOST"
    else
        log "[dry-run] would create a proxy host for $MCP_HOST"
    fi
    printf '%s\n' "$payload" | jq . 2>/dev/null || printf '%s\n' "$payload"
    print_urls
    exit 0
fi

if [ -n "$existing_id" ]; then
    resp=$(npm_call PUT "/api/nginx/proxy-hosts/$existing_id" "$payload")
    if printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
        log "updated proxy host $existing_id ($MCP_HOST)"
    else
        die "could not update proxy host $existing_id: $(printf '%s' "$resp" | head -c 400)"
    fi
else
    resp=$(npm_call POST /api/nginx/proxy-hosts "$payload")
    new_id=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)
    [ -n "$new_id" ] || die "could not create the proxy host: $(printf '%s' "$resp" | head -c 400)"
    log "created proxy host $new_id ($MCP_HOST)"
fi

if [ "$ssl_forced" = true ]; then
    log "TLS on, certificate $cert_id, HTTP/2, force-SSL"
else
    warn "no certificate attached: serving plain HTTP until one is added (NPM_CERT_ID in $NPM_ENV)"
fi
print_urls
