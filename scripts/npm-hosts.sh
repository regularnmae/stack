#!/usr/bin/env bash
# Create or update every nginx-proxy-manager proxy host the stack serves.
#
#   scripts/npm-hosts.sh            # reconcile every host in the manifest
#   scripts/npm-hosts.sh --dry-run  # print the payloads; change nothing
#   scripts/npm-hosts.sh --prune    # additionally DELETE hosts and certificates
#                                   # the manifest does not declare
#
# The declaration is deploy/services.toml (the [npm.*] tables: one entry per
# vhost, `host` referencing a [host.*] domain, `forward` naming the unit's
# loopback publish, `flags` selecting force-ssl/http2/ws/block/mcp). This
# wrapper owns only the CLI and the data dir; the reconciler itself is Python
# (scripts/stackctl/npm.py, run as `python3 -m stackctl npm-hosts`), which
# loads the manifest directly and talks to NPM's admin API with urllib:
# nginx-proxy-manager runs on the host network and its own nginx owns :81 in
# the host's namespace, so the host's python3 (already a bootstrap dependency)
# reaches it on the loopback -- no netcheck transport, no jq, and no
# curl-config-on-stdin dance, because a credential held in a Python process's
# memory never reaches an argv that `ps` can read.
#
# Credentials live in $DATA_DIR/config/npm/api.env (mode 600), seeded by
# deploy/install.sh; the Python core reads that file itself and self-skips
# while it is empty (a fresh host deploys before the admin login exists). A
# Let's Encrypt certificate is requested for any declared host that has none
# -- except a `.onion`: tor already encrypts and authenticates the hidden
# service and Let's Encrypt cannot issue for an onion. NPM_REQUEST_CERT=0
# leaves TLS to the UI.
#
# Idempotent: a host already serving one of the domain's names is updated in
# place, otherwise it is created. --prune is the only destructive mode.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

# nginx-proxy-manager is on the host network, so its own nginx owns :81 in the
# host's namespace: the admin API is reached on the loopback.
NPM_API="${NPM_API_URL:-http://127.0.0.1:81}"

# The CLI, the data dir and the declaration stream are lib.sh's
# stackctl_wrapper -- the same half kuma-monitors.sh uses.
stackctl_wrapper npm-hosts "NPM_API=$NPM_API" "$@"
