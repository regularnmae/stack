# Agent tooling on the host

`agent-skills` and `agent-mcp`: the one thing a deploy writes outside
`$DATA_DIR`. Read this before touching `deploy.sh`'s `fetch_agent_skills`/
`install_agent_skills`, `~/.config/agent-skills`, or `~/.local/bin/agent-mcp`.

## Invariants

- **Never run its `install.sh --from-opencode` here** -- this host's
  `opencode.json` carries `{env:...}` references.
- **Tokens are read from `$DATA_DIR/config/<server>/token.env` on every call**,
  never copied into `~/.config/agent-skills/env`.
- **The URL prefixes are hardcoded in `servers.json`**; only the host comes from
  `AGENT_MCP_BASE_URL`, and `verify.sh` fails when it disagrees with `MCP_HOSTS`.

## agent-skills

- **`agent-skills` is client tooling, not a service, and never joins
  `APP_REPOS`:** it ships no Containerfile and starts no container, so
  `deploy_app` would bail on it. `deploy.sh`'s `fetch_agent_skills`/
  `install_agent_skills` clone it into `$BUILD_DIR/agent-skills` and run its
  `install.sh`, which links eleven skills into the harnesses under `$HOME` and puts
  `agent-mcp` in `~/.local/bin` — the only thing a deploy writes outside
  `$DATA_DIR`, which is what `--skip-agent-skills` is for. Three traps: never run
  its `install.sh --from-opencode` here, because this host's `opencode.json`
  carries `{env:…}` references and copying the literal text writes a placeholder
  as the bearer token (it now resolves them, but the registry makes the copy
  unnecessary anyway); the tokens are read from
  `$DATA_DIR/config/<server>/token.env` on every call (`token_file` in
  `servers.json`), never seeded into `~/.config/agent-skills/env`, because a
  copy goes stale the moment `scripts/rotate.sh` rotates a token; and the URL
  *prefixes* are hardcoded in `servers.json` (only the host comes from
  `$AGENT_MCP_BASE_URL`, defaulting to `mcp.boltmesh.net`, the default
  `MCP_HOST`; a host that changed `MCP_HOST` must export it, and `verify.sh`
  warns when the two disagree), so `verify.sh` compares the resolved registry
  with `MCP_HOSTS` and fails on the drift. `agent-mcp` is python3 (stdlib only),
  which `bootstrap.sh` now installs for it.

