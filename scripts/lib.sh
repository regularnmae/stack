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

# The image the host-side checks speak through: a curl client on npm-network
# (see netcheck/Containerfile), built by deploy/install.sh. Nothing in the stack
# publishes a host port, so this is how a host script reaches a service -- by
# container name, exactly as nginx-proxy-manager does. stack.conf sets it; the
# default here covers a script run with a stale environment.
NETCHECK_IMAGE="${NETCHECK_IMAGE:-localhost/netcheck:local}"

# Run curl against a container on npm-network, from a throwaway container.
# Arguments are curl's, verbatim, so call sites read exactly as they did when
# this was a host curl against a published loopback port:
#   net_curl -s -o /dev/null -w '%{http_code}' http://searxng-mcp:8000/health
# -i keeps stdin attached, which is how a caller passes a secret in a curl
# config (`-K -`) rather than on a command line that `ps` can read.
net_curl() {
    if ! podman image exists "$NETCHECK_IMAGE" 2>/dev/null; then
        printf 'ERROR: %s is missing; run deploy/install.sh to build it\n' "$NETCHECK_IMAGE" >&2
        return 127
    fi
    podman run --rm -i --network npm-network "$NETCHECK_IMAGE" curl "$@"
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
