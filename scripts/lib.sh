#!/usr/bin/env bash
# Helpers shared by deploy.sh, deploy/install.sh, verify.sh and the scripts/
# helpers. Sourced, not executed. bootstrap.sh stays self-contained because it
# must run standalone (curl | bash) on a host with no checkout, so it does not
# use this file.

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Echo the value of KEY from a KEY=VALUE env/secrets file (first match). Reads
# the file line by line and never sources it, and strips a trailing CR so a
# CRLF file still parses. Prints nothing when the file or the key is absent.
env_value() {
    local file="$1" key="$2"
    [ -s "$file" ] || return 0
    sed -n "s/^$key=//p" "$file" | head -n1 | tr -d '\r'
}

# The image the host-side checks speak through: a curl client (see
# netcheck/Containerfile), built by deploy/install.sh. It is a throwaway
# container rather than a host package, so the host needs only podman for a
# check to reach a service (the app images vary, and several carry no curl).
# stack.conf sets it; the default here covers a script run with a stale
# environment.
NETCHECK_IMAGE="${NETCHECK_IMAGE:-localhost/netcheck:local}"

# Fail before podman does, so a host that has not run deploy/install.sh reads as
# one clear error rather than a podman stack trace.
netcheck_ready() {
    if podman image exists "$NETCHECK_IMAGE" 2>/dev/null; then
        return 0
    fi
    printf 'ERROR: %s is missing; run deploy/install.sh to build it\n' "$NETCHECK_IMAGE" >&2
    return 127
}

# Run curl against a container on npm-network, from a throwaway container.
# Arguments are curl's, verbatim, so call sites read exactly as they did when
# this was a host curl against a published loopback port:
#   net_curl -s -o /dev/null -w '%{http_code}' http://searxng-mcp:8000/health
# -i keeps stdin attached, which is how a caller passes a secret in a curl
# config (`-K -`) rather than on a command line that `ps` can read.
net_curl() {
    netcheck_ready || return 127
    podman run --rm -i --network npm-network "$NETCHECK_IMAGE" curl "$@"
}

# The same, from the host's own network namespace. It is for the one service
# that is not on npm-network: nginx-proxy-manager runs on the host network
# (deploy/nginx-proxy-manager.container) so that its logs and the
# X-Forwarded-For it sets carry a client's real address. That also means it
# binds :80/:443/:81 itself and speaks to the app tier on the loopback publishes
# its units declare, so its admin API is 127.0.0.1:81 and a host name it fronts
# is reached by looping back to this host:
#   net_curl_host -s -o /dev/null -w '%{http_code}' http://127.0.0.1:81/
net_curl_host() {
    netcheck_ready || return 127
    podman run --rm -i --network host "$NETCHECK_IMAGE" curl "$@"
}

# --- the Electrum protocol (Fulcrum) ----------------------------------------
# Electrum is newline-delimited JSON-RPC over raw TCP, not HTTP: 50001 plaintext
# and 50002 TLS with a certificate the image self-signs. net_curl cannot read it
# and nginx-proxy-manager cannot front it, so this is the stack's one protocol
# that needs a TCP client of its own.
#
# The client is bash's /dev/tcp. The host has no nc -- bootstrap.sh installs
# podman, firewalld, git, openssl and jq and nothing else -- and `read -t` is the
# whole timeout, so a probe costs no container start and no package. It runs in
# a subshell because a failed `exec` redirection can end a non-interactive shell:
# a refused port has to cost the caller an empty string, never the sweep. TLS
# goes through openssl, which is already a bootstrap dependency (scripts/monitor.sh
# reads certificate expiry with it).
#
# Callers dial 127.0.0.1 -- deploy/fulcrum.container.in publishes 50001/50002 on
# every interface, so the published port on the host's loopback is exactly what a
# wallet on the LAN reaches. Reading the container by name would prove less (it
# stays up if the publish is lost) and is not what the protocol surface is.
electrum_call() { # host port request-line -> the server's reply, empty on failure
    bash -c '
        exec 3<>"/dev/tcp/$1/$2" || exit 0
        printf "%s\n" "$3" >&3
        IFS= read -r -t 5 reply <&3
        printf "%s" "$reply"
    ' _ "$1" "$2" "$3" 2>/dev/null
}

# The same over TLS. -quiet drops the handshake chatter; stdin has to stay open a
# moment after the request or s_client closes the connection before the answer
# arrives, hence the sleep -- two seconds, not a timeout loop (five runs of a
# local TLS server answered inside it every time).
electrum_call_tls() { # host port request-line -> the server's reply, empty on failure
    { printf '%s\n' "$3"; sleep 2; } \
        | timeout 10 openssl s_client -quiet -connect "$1:$2" 2>/dev/null \
        | head -n1
}

# The tip height Fulcrum reports, or empty when it does not answer. This is the
# index-backed question on purpose: `server.version` is answered from memory and
# stays green on exactly the failure this exists to catch -- an index that has
# wedged while the process, the port and the healthcheck all still look fine.
# Callers compare it with bitcoind's `blocks`; a healthy Fulcrum polls every 5s
# (--polltime), so the gap is 0-1 block once it has caught up.
#
# Fulcrum answers nothing useful while it is still catching up on a fresh host,
# so an empty result is expected during initial block download: verify.sh warns
# and scripts/monitor.sh softens it under MONITOR_GRACE_SYNC.
electrum_tip() { # port [tls] -> height, empty on failure
    local port="$1" tls="${2:-}" reply
    local req='{"id":1,"method":"blockchain.headers.subscribe","params":[]}'
    if [ "$tls" = tls ]; then
        reply=$(electrum_call_tls 127.0.0.1 "$port" "$req")
    else
        reply=$(electrum_call 127.0.0.1 "$port" "$req")
    fi
    printf '%s' "$reply" | grep -oE '"height"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$' | head -n1
}

# --- locally-built images --------------------------------------------------
# The images this repo builds itself (btc-explorer, xmr-explorer, kuma-ctl,
# netcheck, tor) are described completely by their Containerfile: the base image
# is digest-pinned in `FROM`, every upstream pin is an `ARG` in the same file,
# and none of them COPYs anything out of its build context (the one sibling
# file, kuma-ctl/monitors.mjs, is bind-mounted at run time on purpose). So the
# hash of that file *is* the image's build identity. Baking it in as a label
# lets a later deploy answer "is this image the one this Containerfile
# describes?" without rebuilding to find out -- which is what makes a merged
# Renovate digest bump reach the host at all: it changes nothing else, no unit
# file and no tag, so `podman image exists` alone would keep the old bits
# forever. An image with no label (built before this existed) is stale by
# definition and is rebuilt once.
image_inputs_digest() { # containerfile -> sha256 of its bytes
    sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

image_is_current() { # image containerfile -> 0 when the label matches the file
    local image="$1" cf="$2" want have
    podman image exists "$image" 2>/dev/null || return 1
    want=$(image_inputs_digest "$cf")
    [ -n "$want" ] || return 1
    have=$(podman image inspect \
        --format '{{if .Labels}}{{index .Labels "org.stack.inputs"}}{{end}}' \
        "$image" 2>/dev/null) || return 1
    [ "$have" = "$want" ]
}

# The same value as it goes onto the image: one place for the label name.
image_inputs_label() { # containerfile -> LABEL=VALUE for podman build --label
    printf 'org.stack.inputs=%s' "$(image_inputs_digest "$1")"
}

# Write a Prometheus textfile for node-exporter's textfile collector: stdin -> a
# .prom file, atomically, with the permissions the exporter needs. node-exporter
# runs as uid 65534 -- a *subuid* under rootless podman -- so it owns neither the
# directory nor the file and must still be able to read them; getting that wrong
# is the quietest way to lose every custom metric, which is why the mode lives
# here and not in each writer:
#   printf 'stack_x 1\n' | prom_write "$DATA_DIR/monitoring/textfile/stack.prom"
prom_write() {
    local target="$1" dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir" || return 1
    # 0755 the directory, 0644 the file: the exporter has only "other" access.
    chmod 0755 "$dir" 2>/dev/null || true
    tmp=$(mktemp "$dir/.$(basename "$target").XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 0644 "$tmp"
    # Atomic within the directory, so the collector never serves half a file.
    mv -f "$tmp" "$target"
}

# The session id the last mcp_initialize was given, and the marker that -w uses
# to put it after the response body rather than mixed into it.
MCP_SESSION_ID=""
MCP_SID_MARKER='__mcp_session_id__'

# The handshake every MCP streamable-HTTP session starts with. The version is
# the protocol revision, not this stack's.
MCP_INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"monitor","version":"0"}}}'

# Authenticate against CONTAINER's MCP endpoint: do the initialize handshake,
# print the response body and record the session id in MCP_SESSION_ID. Returns 1
# when the server did not answer with a serverInfo result. The bearer token goes
# in a curl config on stdin, so it never reaches the host's argv.
#   mcp_initialize CONTAINER TOKEN [timeout]
mcp_initialize() {
    local c="$1" token="$2" t="${3:-20}" resp
    MCP_SESSION_ID=""
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
        net_curl -s -m "$t" -K - \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            -w "\n$MCP_SID_MARKER%header{mcp-session-id}" \
            -X POST "http://$c:8000/mcp" -d "$MCP_INIT_BODY" 2>/dev/null) || return 1
    case "$resp" in *"$MCP_SID_MARKER"*) ;; *) return 1 ;; esac
    MCP_SESSION_ID="${resp##*"$MCP_SID_MARKER"}"
    resp="${resp%%"$MCP_SID_MARKER"*}"
    printf '%s' "$resp" | grep -q '"serverInfo"' || return 1
    printf '%s\n' "$resp"
}

# Call one tool once the handshake above has run (mcp_call does both). Prints the
# response body; read-only from the server's point of view.
#   mcp_tool_call CONTAINER TOKEN TOOL ARGS_JSON [timeout]
mcp_tool_call() {
    local c="$1" token="$2" tool="$3" args="$4" t="${5:-20}" call
    call=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$tool" "$args")
    printf 'header = "Authorization: Bearer %s"\n' "$token" | \
        net_curl -s -m "$t" -K - \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            ${MCP_SESSION_ID:+-H "mcp-session-id: $MCP_SESSION_ID"} \
            -X POST "http://$c:8000/mcp" -d "$call" 2>/dev/null
}

# Call one tool on an MCP streamable-HTTP endpoint and print the response body.
# Prints nothing and returns 1 when the handshake fails. Used by
# scripts/monitor.sh and scripts/spend-audit.sh; verify.sh calls the two halves
# itself, because it also proves the 401 gate and reports the session id.
#   mcp_call CONTAINER TOKEN TOOL ARGS_JSON [timeout]
mcp_call() {
    local c="$1" token="$2" tool="$3" args="$4" t="${5:-20}"
    mcp_initialize "$c" "$token" "$t" >/dev/null || return 1
    mcp_tool_call "$c" "$token" "$tool" "$args" "$t"
}

# Print a script's leading comment block (shebang excluded) for --help. Stops at
# the first non-comment line, so keep each script's header one contiguous block.
usage_header() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$1"
}

# Where the stack keeps everything it must not lose: the daemon data dirs, the
# nginx-proxy-manager data, AND the config/secrets. That way a rebuild only has
# to preserve one directory. Resolved in this order, then persisted so it is
# asked once per host:
#   1. $STACK_DATA_DIR (environment, or stack.conf)
#   2. the value saved in $STACK_DATA_ENV by an earlier run
#   3. an interactive prompt, defaulting to $HOME/data
#   4. $HOME/data
resolve_data_dir() {
    local default="${HOME}/data" answer=""
    STACK_DATA_ENV="${STACK_DATA_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/stack/data-dir.env}"

    if [ -z "${STACK_DATA_DIR:-}" ] && [ -s "$STACK_DATA_ENV" ]; then
        # shellcheck disable=SC1090
        . "$STACK_DATA_ENV"
    fi
    if [ -z "${STACK_DATA_DIR:-}" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            read -r -p "Data directory for the stack [${default}]: " answer || answer=""
            STACK_DATA_DIR="${answer:-$default}"
        else
            STACK_DATA_DIR="$default"
        fi
    fi

    STACK_DATA_DIR="${STACK_DATA_DIR%/}"
    [ -n "$STACK_DATA_DIR" ] || STACK_DATA_DIR="$default"
    DATA_DIR="$STACK_DATA_DIR"
    CONFIG_DIR="$DATA_DIR/config"
    NPM_DIR="$DATA_DIR/npm"
    export STACK_DATA_DIR DATA_DIR CONFIG_DIR NPM_DIR STACK_DATA_ENV
    persist_data_dir
}

persist_data_dir() {
    [ -n "${STACK_DATA_ENV:-}" ] || return 0
    [ "${DRY_RUN:-0}" = 1 ] && return 0
    mkdir -p "$(dirname "$STACK_DATA_ENV")"
    printf 'STACK_DATA_DIR=%s\n' "$DATA_DIR" > "$STACK_DATA_ENV"
}

# Give the data dir a container label when SELinux is enforcing and it does not
# have one. The units mount their subdirectories with `:z`/`:Z`, which podman
# relabels rootlessly on every start, so only a path podman cannot relabel (one
# the login user does not own -- a freshly formatted disk is often unlabeled_t)
# needs help. We attempt an unprivileged label and, if even that fails, print
# the exact root commands instead of running sudo: nothing here (or in
# deploy.sh, install.sh, verify.sh) uses sudo.
ensure_data_dir_selinux() {
    [ -d "$DATA_DIR" ] || return 0
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0

    local ctx
    ctx=$(stat -c '%C' "$DATA_DIR" 2>/dev/null || true)
    case "$ctx" in
        *container_file_t*|*svirt_sandbox_file_t*) return 0 ;;
    esac

    # Not recursive on purpose: the image-uid subdirs (bitcoin, monero-wallet-rpc)
    # are not ours to relabel, and podman's `:z` covers the mounted subdirs.
    log "SELinux: $DATA_DIR is '$ctx'; labelling it for containers"
    chcon -t container_file_t "$DATA_DIR" 2>/dev/null || true

    ctx=$(stat -c '%C' "$DATA_DIR" 2>/dev/null || true)
    case "$ctx" in
        *container_file_t*|*svirt_sandbox_file_t*) log "SELinux: $DATA_DIR labelled for containers" ;;
        *)
            local regex
            regex="$(printf '%s' "$DATA_DIR" | sed -e 's/[][\.^$*+?(){}|]/\\&/g')(/.*)?"
            warn "$DATA_DIR is '$ctx', not labelled for containers and not ours to relabel; containers may be denied"
            warn "fix it once, as root, then re-run:"
            printf '    sudo semanage fcontext -a -t container_file_t "%s"\n    sudo restorecon -RF "%s"\n' "$regex" "$DATA_DIR" >&2
            ;;
    esac
}

# Create the data dir (and its config / npm subdirs) if missing. A data dir on a
# separate disk must already be created and owned by you (the README shows the
# one-time commands); a path we cannot prepare is a clear error rather than an
# implicit sudo. Only the top-level data dir is owned by us -- subdirs like
# bitcoin are deliberately the image uid.
ensure_data_dirs() {
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR" 2>/dev/null || die "cannot create $DATA_DIR: its parent is not writable by $(id -un). Create it first:
    sudo mkdir -p \"$DATA_DIR\" && sudo chown \"$(id -u):$(id -g)\" \"$DATA_DIR\""
    fi
    if [ ! -w "$DATA_DIR" ]; then
        die "$DATA_DIR is not writable by $(id -un). Take ownership first:
    sudo chown \"$(id -u):$(id -g)\" \"$DATA_DIR\""
    fi
    mkdir -p "$CONFIG_DIR" "$NPM_DIR/data" "$NPM_DIR/letsencrypt" \
        || die "could not create the data subdirectories under $DATA_DIR"
}
