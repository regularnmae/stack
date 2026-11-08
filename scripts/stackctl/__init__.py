# stackctl: the Python core behind the stack's host-side reconcilers.
#
# Why Python, and why only here: the reconcilers (nginx-proxy-manager's admin
# API, Uptime-Kuma's socket.io) are JSON protocols with real data structures --
# declarations to validate, payloads to build, responses to diff. In bash that
# meant a jq forest, hand-rolled escaping layers (json_escape/config_escape) and
# a Node container just to speak socket.io. Python is already a bootstrap
# dependency (agent-mcp runs on it), and no secret ever needs the
# curl-config-on-stdin dance because a Python process keeps credentials in
# memory, not in an argv that `ps` can read.
#
# Rules this package holds:
#   * stdlib for the declaration layer -- manifest.py, decl.py, envfile.py and
#     npm.py run on the host's bare python3 (bootstrap.sh), because
#     load_manifest is called by install.sh/verify.sh/CI before any venv can be
#     assumed;
#   * one third-party dependency, and only where a library replaced a protocol
#     we were writing ourselves: kuma.py speaks socket.io through
#     uptime-kuma-api2, pinned in requirements.txt and imported lazily in
#     KumaClient.__init__, so importing the package never needs the venv;
#     deploy/install.sh builds $REPO_DIR/.venv from that file and the wrappers
#     exec its interpreter;
#   * the bash wrappers in scripts/ own the CLI contract (flags, usage header,
#     stack.conf, resolve_data_dir) and pipe declarations in over stdin, so
#     every command in AGENTS.md and every deploy.sh branch keeps working;
#   * output conventions match scripts/lib.sh exactly: log() is "==> msg" on
#     stdout, warn() "WARNING: msg" and die() "ERROR: msg" on stderr, exit 1;
#   * behaviour is ported, not reimagined: the comments that explain a trap
#     (kuma's login race, the status page that belongs to the UI, NPM's
#     rate-limit zones) travel with the code they protect.
__all__ = ["decl", "envfile", "http", "kuma", "manifest", "npm", "ui"]
