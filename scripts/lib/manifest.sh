# shellcheck shell=bash
# Reading deploy/services.toml from bash, and the wrapper that hands the Python
# core its facts (docs/proxy.md, and AGENTS.md's interface contract).

# stackctl/ sits beside lib.sh and this file is two levels below it, so its
# own BASH_SOURCE would point PYTHONPATH at scripts/lib/.
: "${STACK_SCRIPTS_DIR:?scripts/lib.sh sets STACK_SCRIPTS_DIR}"

# --- the service manifest -----------------------------------------------------
# deploy/services.toml is the ONE declaration of the public surface: the *_HOST
# names, the MCP prefixes/containers/ports, the onion services and the proxy
# hosts. This is how a bash caller reads them, by eval'ing
# `python3 -m stackctl manifest shell` -- NAME='value' lines and array
# assignments, nothing else. Each table leaves as one array per column
# (MCP_PREFIXES / MCP_CONTAINERS / MCP_PORTS, and ONION_*), so no caller splits a
# record apart.
#
# It must never run inside stack.conf: bootstrap.sh sources that file standalone
# (curl | bash, no checkout), so stack.conf stays plain data and the manifest load
# is each caller's explicit step, right after sourcing it.
#
#   . "$REPO_DIR/stack.conf"; load_manifest     # then $MCP_PREFIXES etc. exist
load_manifest() { # [repo-dir] (defaults to $REPO_DIR)
    local repo="${1:-${REPO_DIR:-}}" out
    [ -n "$repo" ] || die "load_manifest: no repository directory (REPO_DIR is unset)"
    [ -f "$repo/deploy/services.toml" ] \
        || die "load_manifest: $repo/deploy/services.toml is missing"
    command -v python3 >/dev/null 2>&1 \
        || die "load_manifest: python3 is required (bootstrap.sh installs it)"
    out=$(PYTHONPATH="$STACK_SCRIPTS_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m stackctl manifest shell "$repo/deploy/services.toml") \
        || die "load_manifest: could not read $repo/deploy/services.toml"
    eval "$out"
}

# The half of npm-hosts.sh that is not its CLI: it owns a CLI (--dry-run,
# --prune, --help), the data dir and one endpoint override; everything else is
# the Python core in scripts/stackctl/, which loads services.toml itself. So the
# wrapper resolves the data dir and hands the core its facts -- paths and flags,
# never a secret.
#
# Extra facts are NAME=value arguments, so a wrapper reads as the one thing it
# adds, and only when the operator set it:
#   stackctl_wrapper npm-hosts "NPM_API=$NPM_API"
stackctl_wrapper() { # module [NAME=value ...]
    local module="$1"; shift
    local dry_run=0 prune=0
    local -a overrides=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            --prune)   prune=1 ;;
            -h|--help) usage_header "$0"; exit 0 ;;
            *=*)       overrides+=("$1") ;;
            *)         die "unknown argument: $1 (try --help)" ;;
        esac
        shift
    done
    # stdlib-only (npm.py talks urllib to NPM's admin API), so the host's own
    # python3 runs it -- a bootstrap dependency like load_manifest. No venv.
    python_bin=python3
    command -v "$python_bin" >/dev/null 2>&1 \
        || die "python3 is required to run the reconciler (bootstrap.sh installs it)"
    resolve_data_dir
    # Passed through env(1) rather than exported: a subshell `export DRY_RUN`
    # makes shellcheck think the sourcing scripts can lose it (SC2031). The
    # NAME=value arguments are collected while parsing, because the loop has
    # shifted them away by the time the core runs.
    local -a envs=("MANIFEST=$REPO_DIR/deploy/services.toml" "DRY_RUN=$dry_run" "PRUNE=$prune")
    envs+=(${overrides[@]+"${overrides[@]}"})
    PYTHONPATH="$STACK_SCRIPTS_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        env "${envs[@]}" "$python_bin" -m stackctl "$module"
}
