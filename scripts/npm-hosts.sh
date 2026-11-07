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
# for an upstream that speaks TLS, if one is ever added), and `flags` is a
# comma-separated subset of
#
#   force-ssl  redirect :80 to :443 (needs a certificate)
#   http2      negotiate HTTP/2
#   ws         allow websocket upgrade
#   block      block common exploits
#   mcp        serve the MCP servers instead of a single forward: one location
#              per MCP_HOSTS entry, each rewritten onto that container's /mcp,
#              with the streaming nginx settings an SSE transport needs
#
# This wrapper owns the CLI and stack.conf; the reconciler itself is Python
# (scripts/stackctl/npm.py, run as `python3 -m stackctl npm-hosts`), fed the
# declarations over stdin -- the line protocol is documented in
# scripts/stackctl/decl.py. Python talks to NPM's admin API directly:
# nginx-proxy-manager runs on the host network and its own nginx owns :81 in
# the host's namespace, so the host's python3 (already a bootstrap dependency)
# reaches it on the loopback with urllib -- no netcheck transport, no jq, and
# no curl-config-on-stdin dance, because a credential held in a Python
# process's memory never reaches an argv that `ps` can read.
#
# Credentials live in $DATA_DIR/config/npm/api.env (mode 600), seeded by
# deploy/install.sh; the Python core reads that file itself. A Let's Encrypt
# certificate is requested for any declared host that has none -- except a
# `.onion`: tor already encrypts and authenticates the hidden service and
# Let's Encrypt cannot issue for an onion. NPM_REQUEST_CERT=0 leaves TLS to
# the UI.
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

command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to run the reconciler (bootstrap.sh installs it)"

if [ "${NPM_HOSTS+x}" != x ] || [ "${#NPM_HOSTS[@]}" -eq 0 ]; then
    die "NPM_HOSTS is empty; set it in stack.conf"
fi

resolve_data_dir

# nginx-proxy-manager is on the host network, so its own nginx owns :81 in the
# host's namespace: the admin API is reached on the loopback.
NPM_API="${NPM_API_URL:-http://127.0.0.1:81}"

stream_decls() {
    local entry
    printf 'V\tDATA_DIR\t%s\n' "$DATA_DIR"
    printf 'V\tCONFIG_DIR\t%s\n' "$CONFIG_DIR"
    printf 'V\tNPM_API\t%s\n' "$NPM_API"
    printf 'V\tDRY_RUN\t%s\n' "$DRY_RUN"
    printf 'V\tPRUNE\t%s\n' "$PRUNE"
    for entry in "${NPM_HOSTS[@]}"; do printf 'H\t%s\n' "$entry"; done
    if [ "${MCP_HOSTS+x}" = x ]; then
        for entry in "${MCP_HOSTS[@]}"; do printf 'M\t%s\n' "$entry"; done
    fi
    if [ "${ONION_SERVICES+x}" = x ]; then
        for entry in "${ONION_SERVICES[@]}"; do printf 'O\t%s\n' "$entry"; done
    fi
}

stream_decls \
    | PYTHONPATH="$REPO_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" python3 -m stackctl npm-hosts
