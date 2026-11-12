#!/usr/bin/env bash
# Helpers shared by deploy.sh, configure.sh, deploy/install.sh, verify.sh and
# the scripts/ helpers. Sourced, not executed. bootstrap.sh stays self-contained
# because it must run standalone (curl | bash) on a host with no checkout, so it
# does not use this file.
#
# The functions live one concern per file under scripts/lib/; this file is the
# single entry point, so every caller still sources this path and none of them
# names a topic. Order matters in one place only: log/warn/die come from core.sh
# before deploy/root/status.sh is sourced.
#
#   core.sh      log/warn/die, esc, render_root_template, rand_hex, usage_header,
#                dur_s/dur_valid, human_bytes, complete_line_bytes
#   datadir.sh   resolve/persist/ensure the data dir, SELinux, write_env_file
#   probes.sh    NETCHECK_*, net_curl(_host), container_health_state, wait_healthy
#   daemons.sh   bitcoind_*, lightning_cli, cscli, monerod_*, rune_json, cln_*
#   electrum.sh  electrum_call, electrum_call_tls, electrum_tip
#   units.sh     the generation stamp and the image label: unit_*, image_*
#   jobs.sh      status_verdict, verdict_*, restic_snapshot_summary,
#                alertmanager_paging, prom_write/prom_label_value
#   mcp.sh       MCP_*, _mcp_transport, mcp_*
#   manifest.sh  load_manifest, stackctl_wrapper
STACK_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/core.sh
. "$STACK_SCRIPTS_DIR/lib/core.sh"

# env_value, write_atomic, status_write and dur_ms live in deploy/root/status.sh,
# which root sources as its installed copy and this sources from the checkout:
# one implementation, so the status contract the monitor reads cannot drift from
# what the root tier writes. Sourced after warn/die because that file must not
# depend on them.
# shellcheck source=deploy/root/status.sh
. "$STACK_SCRIPTS_DIR/../deploy/root/status.sh"

# shellcheck source=scripts/lib/datadir.sh
. "$STACK_SCRIPTS_DIR/lib/datadir.sh"
# shellcheck source=scripts/lib/probes.sh
. "$STACK_SCRIPTS_DIR/lib/probes.sh"
# shellcheck source=scripts/lib/daemons.sh
. "$STACK_SCRIPTS_DIR/lib/daemons.sh"
# shellcheck source=scripts/lib/electrum.sh
. "$STACK_SCRIPTS_DIR/lib/electrum.sh"
# shellcheck source=scripts/lib/units.sh
. "$STACK_SCRIPTS_DIR/lib/units.sh"
# shellcheck source=scripts/lib/jobs.sh
. "$STACK_SCRIPTS_DIR/lib/jobs.sh"
# shellcheck source=scripts/lib/mcp.sh
. "$STACK_SCRIPTS_DIR/lib/mcp.sh"
# shellcheck source=scripts/lib/manifest.sh
. "$STACK_SCRIPTS_DIR/lib/manifest.sh"
