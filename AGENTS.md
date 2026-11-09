# stack — agent notes

This repo is the **single owner of the runtime**: the scripts below and every
unit the host runs. The application repos (the ten `*-mcp` servers in the table
below, and BoltMesh's `backend`/`frontend`) ship only code, tests, CI and a
`Containerfile` — a unit or env file changes here. `README.md` is the operator
narrative; the invariants and traps live in `docs/`, one file per subsystem —
read that one before changing the area.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`** — `EnvironmentFile=`
/`Environment=` reach the container's environment, not the daemon's argv, so a
secret cannot reach `--bitcoin-rpcpassword` etc. from an env file. So **every
unit is rendered** by `install.sh` from `deploy/*.container[.in]`, substituting
`@DATA_DIR@`/`@CONFIG_DIR@` (plain user units also `@REPO_DIR@`); `lightningd`,
`fulcrum` and `crowdsec` additionally substitute `@PLACEHOLDERS@` from
`config/stack/secrets.env`. Rendered units are mode 600, never committed, never
symlinks: never move a secret onto a committed `.container`. Env files are
rendered the same way from `deploy/env/<app>/<file>.env.in`, which carry
`@PLACEHOLDER@`s and never a value: never paste a real token into one. The
BTCPay wallet uses `btcpayserver/monero` on purpose — its entrypoint binds
`0.0.0.0` only with `--rpc-login` on argv, and the plugin hardcodes empty
credentials.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewall ports, dirs
./deploy.sh                         # fetch repos, build, start/restart (never waits)
./configure.sh                      # second step: waits for each service, then runes/
                                    # wallet/BTCPay state/BoltMesh migrations
./deploy.sh --only <name>           # one service; --dry-run to plan
./deploy.sh --only backup           # run the backup job now
./deploy.sh --only db-dump          # refresh the two live-database dumps now
./deploy.sh --only backup-verify    # run the restore drill now (weekly on a timer)
./deploy.sh --only npm-hosts        # (re)reconcile every proxy host in nginx-proxy-manager
./deploy.sh --only agent-skills     # re-link the skills + agent-mcp into the harnesses
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health, MCP handshakes, onion fetches
./scripts/logs.sh --since 1h        # cross-service log search (LogsQL; UI on :9428)
./scripts/healthcheck-lint.sh       # every unit against the healthcheck contract (the CI gate)
./scripts/btcpay-wallet.sh          # import the view-only BTCPay Monero wallet
./scripts/backup.sh                 # restic backup / restore / verify / inspect
./scripts/ids.sh -v                 # the IDS roll-up, by hand (ids.timer runs it every 5 min)
./scripts/spend-audit.sh            # spend drift + outgoing-activity tripwire
./scripts/rotate.sh --list          # credentials this repo can rotate (+ --dry-run)
./scripts/rotate.sh --status        # credential invariants (runes, RPC password), last 10 runs
shellcheck -x -P SCRIPTDIR -S info $(git ls-files '*.sh')  # the CI lint; CI pins v0.11.0
```

`--only victoria-logs`, `vector`, `tor` and `crowdsec` have no case in the
dispatch on purpose: they are ordinary restarts that `install.sh` re-renders and
`unit_digest` decides, over `torrc`, the CrowdSec config tree and `vector.toml`.

## Invariants and traps

- `docs/units.md` — the runtime: render, digest, healthchecks, mounts.
- `docs/logs.md` — journald is the source, `vector` the only shipper, `victoria-logs` the history.
- `docs/ids.md` — Suricata sees packets, CrowdSec reads the logs, enforcement is ours.
- `docs/backup.md` — a oneshot job, a verdict file, dumps never files.
- `docs/proxy.md` — the manifest is the public surface; NPM owns the host network.
- `docs/alerting.md` — the monitor produces, Alertmanager speaks; metrics are history.
- `docs/chains.md` — archival daemons; peers come from `listpeerchannels`.
- `docs/credentials.md` — spending stays off; rotation re-runs install.
- `docs/btcpay.md` — view-only XMR wallet; the plugin is a file.
- `docs/clients.md` — agent-skills is client tooling; tokens are read, never copied.

## Interface contract with the app repos

The ten MCP servers never read a stack path, a config file or a data dir — only
these variables. The app repos' docs own their *meaning*; this repo owns how they
get set. A container name, port or variable name changes on both sides at once.

| Server | Container / unit / image | Env files (`$DATA_DIR/config/<app>/`) | Upstream it defaults to | On npm-network | NPM target | Bind + health |
| --- | --- | --- | --- | --- | --- | --- |
| `searxng-mcp` | `searxng-mcp` / `localhost/searxng-mcp:latest` | `token.env` | `searxng:8080/search` | `searxng-mcp:8000` | `127.0.0.1:8100` | `0.0.0.0:8000`, `/health` |
| `bitcoin-node-mcp` | `bitcoin-node-mcp` / `localhost/bitcoin-node-mcp:latest` | `token.env`, `upstream.env` | `bitcoind:8332` | `bitcoin-node-mcp:8000` | `127.0.0.1:8101` | `0.0.0.0:8000`, `/health` |
| `monero-node-mcp` | `monero-node-mcp` / `localhost/monero-node-mcp:latest` | `token.env`, `upstream.env` | `monerod:18089` | `monero-node-mcp:8000` | `127.0.0.1:8102` | `0.0.0.0:8000`, `/health` |
| `monero-wallet-mcp` | `monero-wallet-mcp` / `localhost/monero-wallet-mcp:latest` | `token.env`, `upstream.env`, `spend.env` | `monero-wallet-btcpay:18083/json_rpc` | `monero-wallet-mcp:8000` | `127.0.0.1:8103` | `0.0.0.0:8000`, `/health` |
| `lightning-mcp` | `lightning-mcp` / `localhost/lightning-mcp:latest` | `token.env`, `node.env`, `spend.env` | `lightningd:3010` | `lightning-mcp:8000` | `127.0.0.1:8104` | `0.0.0.0:8000`, `/health` |
| `fulcrum-mcp` | `fulcrum-mcp` / `localhost/fulcrum-mcp:latest` | `token.env`, `upstream.env` | `fulcrum:50001` | `fulcrum-mcp:8000` | `127.0.0.1:8110` | `0.0.0.0:8000`, `/health` |
| `victoria-logs-mcp` | `victoria-logs-mcp` / `localhost/victoria-logs-mcp:latest` | `token.env`, `upstream.env` | `victoria-logs:9428` | `victoria-logs-mcp:8000` | `127.0.0.1:8111` | `0.0.0.0:8000`, `/health` |
| `victoriametrics-mcp` | `victoriametrics-mcp` / `localhost/victoriametrics-mcp:latest` | `token.env`, `upstream.env` | `victoriametrics:8428`, `alertmanager:9093` (`ALERTMANAGER_URL`) | `victoriametrics-mcp:8000` | `127.0.0.1:8112` | `0.0.0.0:8000`, `/health` |
| `crowdsec-mcp` | `crowdsec-mcp` / `localhost/crowdsec-mcp:latest` | `token.env`, `lapi.env` | CrowdSec LAPI, `127.0.0.1:8080` | **— (`Network=host`)** | `127.0.0.1:8113` | `127.0.0.1:8113` (host net), `/health` |
| `btcpay-mcp` | `btcpay-mcp` / `localhost/btcpay-mcp:latest` | `token.env`, `upstream.env` | `btcpay:49392` | `btcpay-mcp:8000` | `127.0.0.1:8114` | `0.0.0.0:8000`, `/health` |

None is LAN-reachable: NPM terminates TLS and is the sole client path, `NPM
target` is each unit's `PublishPort=127.0.0.1:<port>:…`. `crowdsec-mcp` alone is
`Network=host` (its LAPI is a loopback bind a bridge cannot reach), binding
`127.0.0.1:8113` itself, probed via `netcheck-host`. See `docs/proxy.md`.

The variables the apps read (names and defaults are the app repos' contract) are
`SEARXNG_URL`/`SEARXNG_MCP_TOKEN`, `BITCOIN_RPC_{URL,USER,PASSWORD}`/
`BITCOIN_MCP_TOKEN`, `MONERO_RPC_{URL,USER,PASSWORD}`/`MONERO_MCP_TOKEN`,
`MONERO_WALLET_RPC_{URL,USER,PASSWORD}`/`MONERO_MCP_TOKEN`/`MONERO_MCP_SPEND_TOKEN`,
`LIGHTNING_{REST_URL,RUNE,SPEND_RUNE,TLS_INSECURE,CA_CERT}`/`LIGHTNING_MCP_{TOKEN,SPEND_TOKEN}`,
`FULCRUM_URL`/`FULCRUM_MCP_TOKEN`, plus `MCP_HOST`/`MCP_PORT`, `ENABLE_SPENDING`
and the spend caps. They are compiler-baked upstream, so a rename breaks the server.

### The BoltMesh app tier

Not MCP servers, so absent from the table above; same contract with `boltmesh-labs`.

| Unit | Image | Env files (`$DATA_DIR/config/boltmesh/`) | Upstream it reaches | On npm-network | NPM target | Health |
| --- | --- | --- | --- | --- | --- | --- |
| `postgres` | `docker.io/library/postgres:18-alpine` | `db.env` (`POSTGRES_*`) | — | — | — | `pg_isready -h 127.0.0.1` |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `db.env`, `secrets.env`, `app.env`, `config/btcpay/backend.env` | `postgres:5432`, `valkey:6379`, `btcpay:49392` | `boltmesh-backend:8000` | `127.0.0.1:8105` | `0.0.0.0:8000`, `/health` (deep) |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | the same four | the same | — | — | liveness file `/tmp/arq-worker-liveness` |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | — (`VITE_*` baked at build) | — | `boltmesh-frontend:80` | `127.0.0.1:8106` | `0.0.0.0:80`, `/` |

`db.env`/`secrets.env` are generated, `app.env` is operator-editable (seeded from
`BOLTMESH_*`) and `btcpay/backend.env` comes from `configure.sh`. `APP_ENV=prod` keeps
the refresh cookie `Secure` + `SameSite=None` for the split hosting.
