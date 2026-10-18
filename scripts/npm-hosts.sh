#!/usr/bin/env bash
# Create or update every nginx-proxy-manager proxy host the stack serves.
#
#   scripts/npm-hosts.sh            # reconcile every host declared in NPM_HOSTS
#   scripts/npm-hosts.sh --dry-run  # print the payloads; change nothing
#   scripts/npm-hosts.sh --prune    # additionally DELETE hosts and certificates
#                                   # that NPM_HOSTS does not declare
#
# NPM_HOSTS in stack.conf is the declaration; each entry is
#
#   domain | forward | flags
#
# where `forward` is `[scheme://]host:port` (scheme defaults to http; use https
# for an upstream that speaks TLS, e.g. clnrest), and `flags` is a comma-
# separated subset of
#
#   force-ssl  redirect :80 to :443 (needs a certificate)
#   http2      negotiate HTTP/2
#   ws         allow websocket upgrade
#   block      block common exploits
#   mcp        serve the MCP servers instead of a single forward: one location
#              per MCP_HOSTS entry, each rewritten onto that container's /mcp,
#              with the streaming nginx settings an SSE transport needs
#
# nginx-proxy-manager runs on the host network and is the only way in, so its
# configuration is applied through the admin API on 127.0.0.1:81 rather than by
# hand. Credentials live in $DATA_DIR/config/npm/api.env (mode 600), seeded by
# deploy/install.sh. A Let's Encrypt certificate is requested for any declared
# host that has none (its DNS must point here and :80 must reach this machine);
# NPM_REQUEST_CERT=0 leaves TLS to the UI.
#
# Idempotent: a host already serving one of the domain's names is updated in
# place, otherwise it is created. --prune is the only destructive mode.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
. "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

DRY_RUN=0
PRUNE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --prune)   PRUNE=1 ;;
        -h|--help) usage_header "$0"; exit 0 ;;
        *)         die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# nginx-proxy-manager is on the host network, so its own nginx owns :81 in the
# host's namespace: the admin API is reached on the loopback, not as a peer on
# npm-network (net_curl_host runs curl in that namespace).
NPM_API="${NPM_API_URL:-http://127.0.0.1:81}"

# jq parses the API's JSON responses; net_curl is only curl. bootstrap.sh
# installs it -- this is the clear error for a host provisioned before that.
command -v jq >/dev/null 2>&1 \
    || die "jq is required to read the nginx-proxy-manager API. Install it: sudo dnf install -y jq"

if [ "${NPM_HOSTS+x}" != x ] || [ "${#NPM_HOSTS[@]}" -eq 0 ]; then
    die "NPM_HOSTS is empty; set it in stack.conf"
fi

resolve_data_dir
NPM_ENV="$CONFIG_DIR/npm/api.env"

NPM_EMAIL="${NPM_EMAIL:-$(env_value "$NPM_ENV" NPM_EMAIL)}"
NPM_PASSWORD="${NPM_PASSWORD:-$(env_value "$NPM_ENV" NPM_PASSWORD)}"
NPM_TOKEN="${NPM_TOKEN:-$(env_value "$NPM_ENV" NPM_TOKEN)}"
NPM_REQUEST_CERT="${NPM_REQUEST_CERT:-$(env_value "$NPM_ENV" NPM_REQUEST_CERT)}"
NPM_REQUEST_CERT="${NPM_REQUEST_CERT:-1}"

if [ -z "$NPM_TOKEN" ] && { [ -z "$NPM_EMAIL" ] || [ -z "$NPM_PASSWORD" ]; }; then
    log "no nginx-proxy-manager API credentials in $NPM_ENV"
    log "fill in NPM_EMAIL/NPM_PASSWORD (the admin login) or NPM_TOKEN, then re-run"
    exit 0
fi

# One curl at the API root, before any credential is used, so "NPM is not
# answering" never reads as "your password is wrong". The failure it guards
# against is specific: NPM's nginx resolves every upstream when it starts, so a
# saved proxy host that names a container keeps nginx from coming up at all once
# NPM is on the host network -- and the admin UI on 81 is served by that same
# nginx. The fix is to park the generated configs (the database is the source of
# truth, so the host is rewritten normally afterwards) and let nginx start.
api_probe=$(net_curl_host -s -o /dev/null -w '%{http_code}' -m 15 "$NPM_API/" 2>/dev/null || true)
case "$api_probe" in
    000|"")
        die "no answer from $NPM_API. If nginx-proxy-manager is running but unhealthy, its nginx is refusing to start (on Network=host a saved proxy host naming a container no longer resolves). Park the generated configs and re-run:
    mkdir -p /tmp/npm-proxy-host-parked && mv $DATA_DIR/npm/data/nginx/proxy_host/*.conf /tmp/npm-proxy-host-parked/" ;;
esac

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
    resp=$(printf '%s' "$TOKEN_CFG" | net_curl_host -s -m 60 -K - 2>/dev/null) || return 1
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
            | net_curl_host -s -m 120 -K - -H 'Content-Type: application/json' \
                -X "$method" "$NPM_API$path" -d "$body" || true
    else
        printf 'header = "Authorization: Bearer %s"\n' "$NPM_TOKEN" \
            | net_curl_host -s -m 120 -K - -X "$method" "$NPM_API$path" || true
    fi
}

has_flag() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

# --- payloads --------------------------------------------------------------
# Streaming settings for the MCP host, applied at server scope so every location
# inherits them. Buffering is off for SSE; `Connection` is cleared for the paths
# NPM's per-location proxy.conf does not already set it on.
ADVANCED_JSON='proxy_buffering off;\nproxy_cache off;\ngzip off;\nproxy_read_timeout 3600s;\nproxy_send_timeout 3600s;\nproxy_http_version 1.1;\nproxy_set_header Connection \"\";\nchunked_transfer_encoding on;'

mcp_locations() {
    local locations="" prefix rest host port obj pair
    for pair in "${MCP_HOSTS[@]}"; do
        prefix="${pair%%:*}"
        rest="${pair#*:}"
        host="${rest%%:*}"
        port="${rest##*:}"
        # Three fields: /prefix:container:loopback-port. The container name is
        # kept for the credential path (see the endpoint list below), but NPM
        # forwards to the loopback publish, not to a container name -- it is on
        # the host network and cannot resolve one.
        if [ -z "$prefix" ] || [ -z "$host" ]; then
            die "bad MCP_HOSTS entry: $pair (want \"/prefix:container:loopback-port\")"
        fi
        case "$port" in
            ''|*[!0-9]*) die "bad MCP_HOSTS entry: $pair (want \"/prefix:container:loopback-port\")" ;;
        esac
        obj=$(printf '{"path":"%s","forward_scheme":"http","forward_host":"127.0.0.1","forward_port":%s,"forward_path":"/mcp","access_list_id":0}' \
            "$prefix" "$port")
        locations="${locations:+$locations,}$obj"
    done
    printf '%s' "$locations"
}

build_payload() { # domain forward_scheme forward_host forward_port cert_id flags advanced locations
    printf '{"domain_names":["%s"],"forward_scheme":"%s","forward_host":"%s","forward_port":%s,"certificate_id":%s,"ssl_forced":%s,"http2_support":%s,"block_exploits":%s,"caching_enabled":false,"allow_websocket_upgrade":%s,"access_list_id":0,"enabled":true,"advanced_config":"%s","locations":[%s]}' \
        "$1" "$2" "$3" "$4" "$5" \
        "$(has_flag "$6" force-ssl && echo true || echo false)" \
        "$(has_flag "$6" http2 && echo true || echo false)" \
        "$(has_flag "$6" block && echo true || echo false)" \
        "$(has_flag "$6" ws && echo true || echo false)" \
        "$7" "$8"
}

# --- certificate for a domain ---------------------------------------------
# Reuses the newest Let's Encrypt certificate that already covers DOMAIN, else
# requests one (a no-op when NPM_REQUEST_CERT=0). Sets CERT_ID to the id, or to
# 0 when the host should be served without TLS.
ensure_cert() { # domain
    local domain="$1" certs existing resp
    CERT_ID=""
    certs=$(npm_call GET /api/nginx/certificates)
    existing=$(printf '%s' "$certs" | jq -r --arg d "$domain" \
        '[.[]? | select(.provider=="letsencrypt") | select((.domain_names // []) | index($d))] | max_by(.id) | .id // empty' 2>/dev/null || true)
    if [ -n "$existing" ]; then
        CERT_ID="$existing"
        return 0
    fi
    [ "$NPM_REQUEST_CERT" = 1 ] || return 0
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would request a Let's Encrypt certificate for $domain" >&2
        return 0
    fi
    log "requesting a Let's Encrypt certificate for $domain (needs its DNS and :80 to reach this host)" >&2
    resp=$(npm_call POST /api/nginx/certificates \
        "$(printf '{"provider":"letsencrypt","nice_name":"%s","domain_names":["%s"],"meta":{"dns_challenge":false}}' "$domain" "$domain")")
    CERT_ID=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)
    if [ -z "$CERT_ID" ]; then
        warn "Let's Encrypt did not issue a certificate for $domain; that host will be plain HTTP" >&2
        printf '%s\n' "$resp" | sed 's/^/  | /' >&2
        CERT_ID=""
    fi
}

# --- talk to nginx-proxy-manager ------------------------------------------
log "reconciling ${#NPM_HOSTS[@]} proxy host(s) through $NPM_API"

if [ -n "$NPM_EMAIL" ] && [ -n "$NPM_PASSWORD" ]; then
    npm_login || die "could not get a token from $NPM_API/api/tokens (check NPM_EMAIL/NPM_PASSWORD in $NPM_ENV)"
fi

hosts=$(npm_call GET /api/nginx/proxy-hosts)

declared=()
for entry in "${NPM_HOSTS[@]}"; do
    IFS='|' read -r domain forward flags <<<"$entry"
    if [ -z "$domain" ] || [ -z "$forward" ]; then
        die "bad NPM_HOSTS entry: $entry (want \"domain|[scheme://]forward_host:port|flags\")"
    fi
    # `forward` may carry a scheme; the upstream of a TLS-speaking daemon
    # (clnrest) needs https. Everything else is plain http inside npm-network.
    scheme="http"
    case "$forward" in
        *://*) scheme="${forward%%://*}"; forward="${forward#*://}" ;;
    esac
    case "$scheme" in
        http|https) ;;
        *) die "bad forward scheme in NPM_HOSTS entry: $entry" ;;
    esac
    fhost="${forward%:*}"
    fport="${forward##*:}"
    declared+=("$domain")

    locations=""
    advanced=""
    if has_flag "$flags" mcp; then
        locations=$(mcp_locations)
        advanced="$ADVANCED_JSON"
    fi

    ensure_cert "$domain"
    cert_id="${CERT_ID:-0}"
    # A pinned certificate only forces SSL when the declaration asks for it.
    if [ "$cert_id" = 0 ]; then
        flags="$(printf '%s' "$flags" | sed -e 's/force-ssl//' -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//')"
    fi

    payload=$(build_payload "$domain" "$scheme" "$fhost" "$fport" "$cert_id" "$flags" "$advanced" "$locations")

    existing_id=$(printf '%s' "$hosts" | jq -r --arg d "$domain" \
        '[.[]? | select((.domain_names // []) | index($d)) | .id] | (.[0] // empty)' 2>/dev/null || true)

    if [ "$DRY_RUN" = 1 ]; then
        if [ -n "$existing_id" ]; then
            log "[dry-run] would update proxy host $existing_id ($domain)"
        else
            log "[dry-run] would create a proxy host for $domain"
        fi
        printf '%s\n' "$payload" | jq . 2>/dev/null || printf '%s\n' "$payload"
        continue
    fi

    if [ -n "$existing_id" ]; then
        resp=$(npm_call PUT "/api/nginx/proxy-hosts/$existing_id" "$payload")
        if printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
            log "updated proxy host $existing_id ($domain -> $scheme://$fhost:$fport)"
        else
            die "could not update proxy host $existing_id ($domain): $(printf '%s' "$resp" | head -c 400)"
        fi
    else
        resp=$(npm_call POST /api/nginx/proxy-hosts "$payload")
        new_id=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)
        [ -n "$new_id" ] || die "could not create the proxy host for $domain: $(printf '%s' "$resp" | head -c 400)"
        log "created proxy host $new_id ($domain -> $scheme://$fhost:$fport)"
    fi

    if has_flag "$flags" mcp; then
        log "  MCP endpoints (Authorization: Bearer <token from the file named below>):"
        for pair in "${MCP_HOSTS[@]}"; do
            rest="${pair#*:}"
            printf '    https://%s%s  (%s/%s/token.env)\n' \
                "$domain" "${pair%%:*}" "$CONFIG_DIR" "${rest%%:*}"
        done
    fi
done

# --- prune ----------------------------------------------------------------
if [ "$PRUNE" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] would delete every host and certificate not in NPM_HOSTS"
    else
        declared_json=$(printf '%s\n' "${declared[@]}" | jq -R . | jq -s -c .)
        hosts=$(npm_call GET /api/nginx/proxy-hosts)
        stale=$(printf '%s' "$hosts" | jq -r --argjson d "$declared_json" \
            '.[]? | select([.domain_names[] as $n | $d | index($n)] | any | not) | .id' 2>/dev/null || true)
        for id in $stale; do
            if npm_call DELETE "/api/nginx/proxy-hosts/$id" >/dev/null; then
                log "deleted proxy host $id (not in NPM_HOSTS)"
            fi
        done
        # Certificates no longer attached to any surviving host and covering no
        # declared domain -- the leftovers of a host that was pruned.
        hosts=$(npm_call GET /api/nginx/proxy-hosts)
        used=$(printf '%s' "$hosts" | jq -c '[.[]? | .certificate_id]')
        certs=$(npm_call GET /api/nginx/certificates)
        stale_certs=$(printf '%s' "$certs" | jq -r --argjson d "$declared_json" --argjson used "$used" \
            '.[]? | select([.domain_names[] as $n | $d | index($n)] | any | not)
                  | select(.id as $i | $used | index($i) | not) | .id' 2>/dev/null || true)
        for id in $stale_certs; do
            if npm_call DELETE "/api/nginx/certificates/$id" >/dev/null; then
                log "deleted certificate $id (unused, not in NPM_HOSTS)"
            fi
        done
    fi
fi

log "done"
