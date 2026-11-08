# stackctl: the Python core behind the stack's host-side reconcilers.
#
# Why Python, and why only here: the reconcilers (nginx-proxy-manager's admin
# API, Uptime-Kuma's socket.io) are JSON protocols with real data structures --
# declarations to validate, payloads to build, responses to diff. In bash that
# meant a jq forest, hand-rolled escaping layers (json_escape/config_escape) and
# a Node container just to speak socket.io. Python is already a bootstrap
# dependency (agent-mcp runs on it), the stdlib covers everything here (urllib,
# json, socket, tomllib), and no secret ever needs the curl-config-on-stdin
# dance because a Python process keeps credentials in memory, not in an argv
# that `ps` can read.
#
# Rules this package holds:
#   * stdlib only -- the host's python3 (bootstrap.sh) is the whole runtime;
#   * the bash wrappers in scripts/ own the CLI contract (flags, usage header,
#     stack.conf, resolve_data_dir) and pipe declarations in over stdin, so
#     every command in AGENTS.md and every deploy.sh branch keeps working;
#   * output conventions match scripts/lib.sh exactly: log() is "==> msg" on
#     stdout, warn() "WARNING: msg" and die() "ERROR: msg" on stderr, exit 1;
#   * behaviour is ported, not reimagined: the comments that explain a trap
#     (kuma's login race, an ack's positional arity, NPM's rate-limit zones)
#     travel with the code they protect.
__all__ = ["decl", "duration", "envfile", "http", "kuma", "manifest", "npm", "socketio", "ui", "ws"]
