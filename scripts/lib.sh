#!/usr/bin/env bash
# Helpers shared by deploy.sh, bootstrap.sh and deploy/install.sh. Sourced, not
# executed. bootstrap.sh stays self-contained because it must run standalone
# (curl | bash) on a host with no checkout, so it does not use this file.

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

# If the data dir is not somewhere containers may read, give it a container
# label. A freshly formatted/extra disk is often unlabeled_t, and then podman's
# `:z` relabel fails ("lsetxattr ... operation not permitted") and every
# container that mounts it is denied.
ensure_data_dir_selinux() {
    [ -d "$DATA_DIR" ] || return 0
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0

    local ctx
    ctx=$(stat -c '%C' "$DATA_DIR" 2>/dev/null || true)
    case "$ctx" in
        *container_file_t*|*svirt_sandbox_file_t*) return 0 ;;
    esac

    log "SELinux: $DATA_DIR is '$ctx'; labelling it for containers"
    local regex
    regex="$(printf '%s' "$DATA_DIR" | sed -e 's/[][\.^$*+?(){}|]/\\&/g')(/.*)?"
    if command -v semanage >/dev/null 2>&1; then
        sudo semanage fcontext -a -t container_file_t "$regex" 2>/dev/null \
            || sudo semanage fcontext -m -t container_file_t "$regex" 2>/dev/null || true
        sudo restorecon -RF "$DATA_DIR" 2>/dev/null || true
    else
        sudo chcon -Rt container_file_t "$DATA_DIR" 2>/dev/null || true
    fi

    ctx=$(stat -c '%C' "$DATA_DIR" 2>/dev/null || true)
    case "$ctx" in
        *container_file_t*|*svirt_sandbox_file_t*) log "SELinux: $DATA_DIR labelled for containers" ;;
        *) warn "could not label $DATA_DIR for containers (context is still $ctx); containers may be denied" ;;
    esac
}

# Create the data dir (and its config / npm subdirs) if missing. A data dir on
# a separate disk (e.g. /data/stack) needs sudo to create, and it must be owned
# by this user: rootless containers write as this uid, so a root-owned data dir
# yields "Permission denied" no matter how it is labelled. Only the top-level
# data dir is chowned -- subdirs like bitcoin are deliberately the image uid.
ensure_data_dirs() {
    if [ ! -d "$DATA_DIR" ]; then
        # Plain mkdir covers the common case ($HOME/data); a path like
        # /data/stack has a root-owned parent and needs sudo.
        mkdir -p "$DATA_DIR" 2>/dev/null \
            || { log "creating $DATA_DIR (needs sudo)"; sudo mkdir -p "$DATA_DIR" || die "could not create $DATA_DIR"; }
    fi
    if [ "$(stat -c '%u' "$DATA_DIR" 2>/dev/null)" != "$(id -u)" ]; then
        sudo chown "$(id -u):$(id -g)" "$DATA_DIR" 2>/dev/null \
            || warn "could not take ownership of $DATA_DIR; containers may not be able to write"
    fi
    mkdir -p "$CONFIG_DIR" "$NPM_DIR/data" "$NPM_DIR/letsencrypt" \
        || die "could not create the data subdirectories under $DATA_DIR"
}
