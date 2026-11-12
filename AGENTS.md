# stack — agent notes

This repo is the **single owner of the runtime**: these scripts and every unit
the host runs. The ten `*-mcp` servers and BoltMesh's `backend`/`frontend` ship
only code, tests, CI and a `Containerfile`; a unit or env file changes here.
`README.md` is the operator narrative, `docs/` owns each subsystem's invariants —
read that one before changing the area.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`**, so every unit is
*rendered* by `deploy/install.sh` from `deploy/*.container[.in]`, and an env
file's shape is a `deploy/env/<app>/*.env.in` template: `@PLACEHOLDER@`s only,
never a value. What is rendered is mode 600 and never committed, so never put a
secret on a committed `.container` or a token in a `.env.in`. `docs/units.md`
owns the render, the digest and the secret resolution.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewall, dirs
./deploy.sh                         # fetch, build, start/restart (never waits); --dry-run plans
./configure.sh                      # second step: waits, then runes/wallet/BTCPay/BoltMesh
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health, MCP handshakes, onion fetches
./deploy.sh --only <name>           # one service; backup, db-dump, backup-verify, npm-hosts
                                    # and agent-skills are jobs of their own
./scripts/logs.sh --since 1h        # cross-service log search (LogsQL; UI on :9428)
./scripts/registrations.sh --dry-run # what the BoltMesh signup watcher would mail
./scripts/btcpay-wallet.sh          # import the view-only BTCPay Monero wallet
./scripts/backup.sh                 # restic backup / restore / verify / inspect
./scripts/ids.sh -v                 # the IDS roll-up by hand (ids.timer: every 5 min)
./scripts/spend-audit.sh            # spend drift + outgoing-activity tripwire
./scripts/rotate.sh --list          # --list/--status/--dry-run; one target per run
# the CI gates, each runnable on its own
./scripts/healthcheck-lint.sh       # every unit against the healthcheck contract
./scripts/docs-lint.sh              # every README/docs section reference resolves
./scripts/docs-render.sh --check    # generated README/AGENTS tables are current
# markdown lint; the tag matches the CLI the CI action bundles -- bump both together
podman run --rm -v "$PWD":/work:z -w /work docker.io/davidanson/markdownlint-cli2:v0.24.0
# -P . : scripts/lib.sh's source= directives spell paths from the repo root, so
# run this from the root (CI does); SCRIPTDIR alone resolves them from the
# directory of whichever script is being checked.
shellcheck -x -P SCRIPTDIR -P . -S info $(git ls-files '*.sh')  # CI pins v0.11.0
```

`--only victoria-logs`, `vector`, `tor` and `crowdsec` have no case in the
dispatch on purpose: they are ordinary restarts that `install.sh` re-renders and
`unit_digest` decides, over `torrc`, the CrowdSec config tree and `vector.toml`.

## Comments

A comment earns its place only if it changes what the next reader does: it names
a trap (something that looks wrong and is not) or points at the `docs/` file
that owns the reasoning. Measurements and what a design used to be belong in the
commit message and `docs/`, not beside code that must be re-read; keep the trap,
drop the history around it. Two forms behave like code: a script's leading `#`
block is its `--help` (`usage_header` prints it verbatim, so it stays contiguous
from line 2), and `# shellcheck source=`/`disable=` are directives.

## Invariants and traps

- `docs/units.md` — the runtime: render, digest, healthchecks, mounts.
- `docs/logs.md` — journald is the source, `vector` the only shipper, `victoria-logs` the history.
- `docs/ids.md` — Suricata sees packets, CrowdSec reads the logs, enforcement is ours.
- `docs/backup.md` — a oneshot job, a verdict file, dumps never files.
- `docs/proxy.md` — the manifest is the public surface; NPM owns the host network.
- `docs/alerting.md` — the monitor produces, vmalert decides, Alertmanager speaks; metrics are history.
- `docs/chains.md` — archival daemons; peers come from `listpeerchannels`.
- `docs/credentials.md` — spending stays off; rotation re-runs install.
- `docs/btcpay.md` — view-only XMR wallet; the plugin is a file.
- `docs/clients.md` — agent-skills is client tooling; tokens are read, never copied.

## Interface contract with the app repos

The MCP servers read only env vars — never a stack path, config file or data dir —
so a container name, port or variable name changes on both sides at once.
`deploy/services.toml` is the declaration and the table below is generated from
it and the units (`./scripts/docs-render.sh`): edit the declaration, never the
row.

Every server binds `0.0.0.0:8000` and answers `/health`, except `crowdsec-mcp`,
which binds the host's `127.0.0.1:8113` because it runs on the host network and
reaches the CrowdSec LAPI on `127.0.0.1:8080`. `victoriametrics-mcp` also reads
`ALERTMANAGER_URL` (`alertmanager:9093`); the rest reach only the single
upstream named above.

<!-- BEGIN GENERATED: agents-mcp -->

| Server | Container / unit / image | Env files (`$DATA_DIR/config/<app>/`) | Upstream it defaults to | On npm-network | NPM target |
| --- | --- | --- | --- | --- | --- |
| `searxng-mcp` | `searxng-mcp` / `localhost/searxng-mcp:latest` | `token.env` | `searxng:8080/search` | `searxng-mcp:8000` | `127.0.0.1:8100` |
| `bitcoin-node-mcp` | `bitcoin-node-mcp` / `localhost/bitcoin-node-mcp:latest` | `token.env`, `upstream.env` | `bitcoind:8332` | `bitcoin-node-mcp:8000` | `127.0.0.1:8101` |
| `monero-node-mcp` | `monero-node-mcp` / `localhost/monero-node-mcp:latest` | `token.env`, `upstream.env` | `monerod:18089` | `monero-node-mcp:8000` | `127.0.0.1:8102` |
| `monero-wallet-mcp` | `monero-wallet-mcp` / `localhost/monero-wallet-mcp:latest` | `token.env`, `upstream.env`, `spend.env` | `monero-wallet-btcpay:18083/json_rpc` | `monero-wallet-mcp:8000` | `127.0.0.1:8103` |
| `lightning-mcp` | `lightning-mcp` / `localhost/lightning-mcp:latest` | `token.env`, `node.env`, `spend.env` | `lightningd:3010` | `lightning-mcp:8000` | `127.0.0.1:8104` |
| `fulcrum-mcp` | `fulcrum-mcp` / `localhost/fulcrum-mcp:latest` | `token.env`, `upstream.env` | `fulcrum:50001` | `fulcrum-mcp:8000` | `127.0.0.1:8110` |
| `victoria-logs-mcp` | `victoria-logs-mcp` / `localhost/victoria-logs-mcp:latest` | `token.env`, `upstream.env` | `victoria-logs:9428` | `victoria-logs-mcp:8000` | `127.0.0.1:8111` |
| `victoriametrics-mcp` | `victoriametrics-mcp` / `localhost/victoriametrics-mcp:latest` | `token.env`, `upstream.env` | `victoriametrics:8428` | `victoriametrics-mcp:8000` | `127.0.0.1:8112` |
| `crowdsec-mcp` | `crowdsec-mcp` / `localhost/crowdsec-mcp:latest` | `token.env`, `lapi.env` | `127.0.0.1:8080` | — (`Network=host`) | `127.0.0.1:8113` |
| `btcpay-mcp` | `btcpay-mcp` / `localhost/btcpay-mcp:latest` | `token.env`, `upstream.env` | `btcpay:49392` | `btcpay-mcp:8000` | `127.0.0.1:8114` |

<!-- END GENERATED -->

`NPM target` is each unit's `PublishPort=`; NPM terminates TLS and is the only
client path, so nothing here is LAN-reachable (`docs/proxy.md`).

The env an app reads is what its unit names: `deploy/env/<app>/*.env.in`, the
`<X>_MCP_TOKEN` that `seed_token_env` mints, and stray `Environment=` literals.
Names are compiler-baked upstream, so a rename breaks the server.

### The BoltMesh app tier

Not MCP servers, so absent from the table above; same contract with `boltmesh-labs`.

<!-- BEGIN GENERATED: agents-app -->

| Unit | Image | Env files | On npm-network | NPM target | Health |
| --- | --- | --- | --- | --- | --- |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `db.env`, `secrets.env`, `app.env`, `backend.env` | `boltmesh-backend:8000` | `127.0.0.1:8105` | `curl -fsS -o /dev/null --max-time 4 http://127.0.0.1:8000/health` |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | — | `boltmesh-frontend:80` | `127.0.0.1:8106` | `wget -q -T 4 -t 1 -O /dev/null http://127.0.0.1/` |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | `db.env`, `secrets.env`, `app.env`, `backend.env` | — | — | `find /tmp/arq-worker-liveness -mmin -3 -print -quit \| grep -q .` |
| `postgres` | `docker.io/library/postgres:18-alpine` | `db.env` | — | — | `pg_isready -h 127.0.0.1 -U vpnuser -d vpndb` |

<!-- END GENERATED -->

The env files live under `$DATA_DIR/config/`: the three `boltmesh/` ones plus
`btcpay/backend.env`, which `configure.sh` writes. The worker runs the same four
and reaches the same upstreams as the backend (`postgres:5432`, `valkey:6379`,
`btcpay:49392`); the frontend has none (its `VITE_*` are baked at build) and is
probed on `/`. `Health` is each unit's own `HealthCmd`, so a probe change is a
unit change and the table follows on the next render.

`db.env`/`secrets.env` are generated, `app.env` is operator-editable (seeded from
`BOLTMESH_*`) and `btcpay/backend.env` comes from `configure.sh`. `APP_ENV=prod` keeps
the refresh cookie `Secure` + `SameSite=None` for the split hosting.
