# shellcheck shell=bash
# Where the stack keeps what it must not lose, and the one writer for a file
# carrying a secret or a credential-bearing URL (docs/units.md owns the layout).

# The one writer for an env file carrying a secret (or a credential-bearing URL):
# atomic, 0600, parent created. install.sh seeds them and configure.sh rewrites
# two from the BTCPay bootstrap state -- one writer, so the two cannot disagree
# about the mode, which is exactly the split where one side forgets it.
write_env_file() { # path
    write_atomic "$1" 600
}

# install.sh's name for it: every seed site there reads as what it is, a secret
# being written. An alias rather than renaming thirty call sites.
write_secret() { # path
    write_env_file "$1"
}

# Where the stack keeps everything it must not lose: the daemon data dirs, NPM's
# data, and config/secrets, so a rebuild only has to preserve one directory.
# Resolved in this order; only an answer a person gives is persisted, and a
# non-interactive run with nothing recorded stops instead of guessing:
#   1. $STACK_DATA_DIR (environment, or stack.conf)
#   2. the value saved in $STACK_DATA_ENV by an earlier run
#   3. an interactive prompt, defaulting to $HOME/data -- this one is saved
resolve_data_dir() {
    local default="${HOME}/data" answer="" asked=0
    STACK_DATA_ENV="${STACK_DATA_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/stack/data-dir.env}"

    if [ -z "${STACK_DATA_DIR:-}" ] && [ -s "$STACK_DATA_ENV" ]; then
        # shellcheck disable=SC1090
        . "$STACK_DATA_ENV"
    fi
    if [ -z "${STACK_DATA_DIR:-}" ]; then
        # Only a person at a terminal picks the data dir. A non-interactive run
        # must never invent one: guessing $HOME/data is how a host ends up with
        # two data dirs -- the second one empty.
        if [ ! -t 0 ] || [ ! -t 1 ]; then
            die "no data directory recorded in $STACK_DATA_ENV; run ./deploy.sh from a terminal once, or set STACK_DATA_DIR"
        fi
        read -r -p "Data directory for the stack [${default}]: " answer || answer=""
        STACK_DATA_DIR="${answer:-$default}"
        asked=1
    fi

    STACK_DATA_DIR="${STACK_DATA_DIR%/}"
    [ -n "$STACK_DATA_DIR" ] || die "STACK_DATA_DIR resolves to an empty path"
    DATA_DIR="$STACK_DATA_DIR"
    CONFIG_DIR="$DATA_DIR/config"
    NPM_DIR="$DATA_DIR/npm"
    export STACK_DATA_DIR DATA_DIR CONFIG_DIR NPM_DIR STACK_DATA_ENV
    # Record only the answer a person gave; a value that was merely read is not
    # ours to rewrite.
    if [ "$asked" = 1 ]; then persist_data_dir; fi
}

persist_data_dir() {
    local tmp
    [ -n "${STACK_DATA_ENV:-}" ] || return 0
    [ "${DRY_RUN:-0}" = 1 ] && return 0
    mkdir -p "$(dirname "$STACK_DATA_ENV")"
    # Rename, not truncate: a concurrent resolve that sources this file
    # mid-write would see no value, fall back to $HOME/data and persist it.
    tmp="$STACK_DATA_ENV.$$"
    printf 'STACK_DATA_DIR=%s\n' "$DATA_DIR" > "$tmp" && mv -f "$tmp" "$STACK_DATA_ENV"
}

# Give the data dir a container label when SELinux is enforcing and it lacks one.
# The units mount subdirectories with `:z`/`:Z`, which podman relabels rootlessly
# on every start, so only a path podman cannot relabel (one the login user does
# not own -- a freshly formatted disk is often unlabeled_t) needs help. Try an
# unprivileged label, and if even that fails print the root commands: nothing
# here (or in deploy.sh, install.sh, verify.sh) uses sudo.
ensure_data_dir_selinux() {
    [ -d "$DATA_DIR" ] || return 0
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0

    local ctx
    ctx=$(stat -c '%C' "$DATA_DIR" 2>/dev/null || true)
    case "$ctx" in
        *container_file_t*|*svirt_sandbox_file_t*) return 0 ;;
    esac

    # Not recursive on purpose: the image-uid subdirs (bitcoin)
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
# separate disk must already exist and be yours (README has the one-time
# commands); a path we cannot prepare is a clear error, never an implicit sudo.
# Only the top-level dir is ours -- subdirs like bitcoin are the image uid.
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
