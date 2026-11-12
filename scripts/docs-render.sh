#!/usr/bin/env bash
# Regenerate the Markdown this repo derives from its unit templates.
#
#   scripts/docs-render.sh            # rewrite the generated blocks in place
#   scripts/docs-render.sh --check    # fail when a committed block is stale
#                                     # (what CI runs)
#
# README's "What runs" and the two interface tables in AGENTS.md repeat facts
# that live in deploy/*.container[.in] and deploy/services.toml. Each table sits
# in a marked block (`<!-- BEGIN GENERATED: ... -->`) and is rendered by
# scripts/stackctl/docs.py, so changing a unit or an [mcp.*] entry is one render
# instead of a hand edit; --check is the only thing that has to notice a stale
# one.
#
# The renderer reads the templates, not ~/.config/containers/systemd: this is a
# question about a commit, not about a host.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

MODE=render
case "${1:-}" in
    "") ;;
    --check)    MODE=check ;;
    -h|--help)  usage_header "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac

# The domain overrides deploy.sh honours ($BOLTMESH_API_HOST et al.) are
# deliberately not passed on: a committed table must not name whichever host
# happened to run the render.
PYTHONPATH="$REPO_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m stackctl docs "$MODE" --root "$REPO_DIR"
