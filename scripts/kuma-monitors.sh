#!/usr/bin/env bash
# Reconcile the status page's monitors against the declarations in the
# service manifest.
#
#   scripts/kuma-monitors.sh            # reconcile every declared monitor
#                                       # + create/fill the status page (only
#                                       #   while it has no monitors of its own)
#   scripts/kuma-monitors.sh --dry-run  # print the plan; change nothing
#   scripts/kuma-monitors.sh --prune    # additionally DELETE monitors the
#                                       # manifest does not declare
#
# The declaration is deploy/services.toml (the [kuma.monitor.*] tables -- a
# `host` reference plus accepted status codes, or a `tcp` target for kuma's
# port monitor -- and [kuma.page] for the page they are published on; the
# format notes, including the "401 without a token counts as up" reasoning,
# live in that file). This wrapper owns only the CLI and the data dir.
#
# Uptime-Kuma has no REST write API -- its management surface is socket.io.
# The client is scripts/stackctl/kuma.py (socketio.py over ws.py, stdlib
# only), which loads the manifest directly and reaches kuma through its
# loopback publish -- the loopback_port of [uptime_kuma] there, which mirrors
# the PublishPort= of deploy/uptime-kuma.container. Proving the publish
# (rather than the container name on npm-network) is deliberate: it is the
# same surface nginx-proxy-manager forwards the dashboard through. Set
# KUMA_URL in the environment to override it.
#
# The admin login lives in $DATA_DIR/config/uptime-kuma/api.env (mode 600,
# seeded by deploy/install.sh; fill it in with the login the setup wizard
# asked for). The Python core reads that file itself -- no credential reaches
# an argv or a container env `ps` can read -- and self-skips while it is
# empty (a fresh host deploys before the UI-first registration exists).
#
# Idempotent and UI-preserving: missing monitors are created, monitors whose
# *declared* fields changed are updated in place (UI-tuned interval, retries
# and notifications are carried over untouched), and the status page is only
# written when it does not exist at all -- an existing page's layout is the
# UI's. --prune is the only destructive mode.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

# The manifest's [uptime_kuma] loopback_port is kuma.py's default; KUMA_URL (an
# environment override) wins when it is set. The CLI, the data dir and the
# declaration stream are lib.sh's stackctl_wrapper -- the same half
# npm-hosts.sh uses.
if [ -n "${KUMA_URL:-}" ]; then
    stackctl_wrapper kuma-monitors "KUMA_URL=$KUMA_URL" "$@"
else
    stackctl_wrapper kuma-monitors "$@"
fi
