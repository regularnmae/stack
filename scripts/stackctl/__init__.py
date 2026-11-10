# stackctl: the Python core behind the stack's host-side reconciler.
#
# Why Python, and why only here: nginx-proxy-manager's admin API is a JSON
# protocol with real data structures -- declarations to validate, payloads to
# build, responses to diff. In bash that meant a jq forest and hand-rolled
# escaping layers (json_escape/config_escape). Python is already a bootstrap
# dependency (agent-mcp runs on it), and no secret ever needs the
# curl-config-on-stdin dance because a Python process keeps credentials in
# memory, not in an argv that `ps` can read.
#
# Rules this package holds:
#   * stdlib only. manifest.py, envfile.py and npm.py run on the host's bare
#     python3 (bootstrap.sh), because load_manifest is called by
#     install.sh/verify.sh/monitor.sh/CI and there is no venv to assume;
#   * the bash wrapper in scripts/ owns the CLI contract (flags, usage header,
#     stack.conf, resolve_data_dir) and passes its facts in the environment, so
#     every command in AGENTS.md and every deploy.sh branch keeps working;
#   * output conventions match scripts/lib.sh exactly: log() is "==> msg" on
#     stdout, warn() "WARNING: msg" and die() "ERROR: msg" on stderr, exit 1;
#   * behaviour is ported, not reimagined: the comments that explain a trap
#     (NPM's rate-limit zones, the parked-config rescue, the onion certificate
#     rule) travel with the code they protect.
__all__ = ["envfile", "http", "manifest", "npm", "ui"]
