# stack — agent notes

Not a program: `bootstrap.sh`, `deploy.sh`, `verify.sh`, `deploy/install.sh`,
`scripts/{lib,wallets,backup,monitor,spend-audit}.sh`, and every unit the host
runs (quadlet, plus the plain systemd user units `backup.timer`,
`monitor.service`, `monitor.timer`). This repo is the
**single owner of the runtime** for the whole stack. The application repos
(`searxng-mcp`, `bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`,
`lightning-mcp`, and BoltMesh's `backend`/`frontend`) ship only code, tests, CI
and a `Containerfile` — no unit, no `deploy/`, no `deploy.sh`. If a unit or an
env file changes, it changes here.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`.** An
`EnvironmentFile=`/`Environment=` reaches the container's environment, not the
daemon's argv. So a secret cannot be fed to `--bitcoin-rpcpassword` etc. from an
env file. Two answers, and the split is deliberate:

- secret-free units (`bitcoind`, `monerod`, `tor`, `valkey`, `searxng`, NPM and
  the five MCP units) are **rendered** too, but their `@PLACEHOLDERS@` are only
  `@DATA_DIR@`/`@CONFIG_DIR@` — their secrets live in the daemons' own files or
  in `EnvironmentFile=`. The plain user units additionally use `@REPO_DIR@` to
  reach the scripts (`monitor.service` runs `@REPO_DIR@/scripts/monitor.sh`);
- secret-bearing units (`lightningd`, `monero-wallet-rpc`) are **rendered** from
  a `.container.in` by `install.sh`, substituting `@PLACEHOLDERS@` from
  `$DATA_DIR/config/stack/secrets.env` as well. The rendered units are mode 600,
  never committed. (Every unit is rendered — `install.sh` `UNITS` — because all
  of them reference the data or config dir; none is a symlink.)

Do not move a secret onto a committed `.container`, and do not "simplify"
`monero-wallet-rpc` to a config file: the image's entrypoint only binds `0.0.0.0`
when `--rpc-login` is on the command line, otherwise it forces `127.0.0.1` and
the wallet is unreachable from the MCP server.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewall ports, dirs
./deploy.sh                         # fetch repos, build, start, verify
./deploy.sh --only <name>           # one service; --dry-run to plan
./deploy.sh --only backup           # run the backup job now
./deploy.sh --only monitor          # run the health + spend checks now
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health + MCP handshakes
./scripts/wallets.sh --monero       # create/restore the Monero wallet
./scripts/backup.sh                 # restic backup / restore / inspect
./scripts/monitor.sh                # the monitor.timer sweep, by hand
./scripts/spend-audit.sh            # spend drift + outgoing-activity tripwire
shellcheck -x -P SCRIPTDIR -S info bootstrap.sh deploy.sh verify.sh deploy/install.sh scripts/lib.sh scripts/wallets.sh scripts/backup.sh scripts/monitor.sh scripts/spend-audit.sh  # the CI lint
```

## Facts that are easy to get wrong

- **`install.sh` is the only installer.** It seeds every env file and renders
  every unit. Adding a service means adding its unit to the `UNITS` array (or the
  plain-user-unit `USER_UNITS`/`USER_TIMERS` arrays) and its env seeding to
  `install.sh` — nothing in the app repos. It also creates `$DATA_DIR/audit` and
  seeds `config/monitoring/monitor.env` (empty: journal-only until filled in).
- **Secret resolution order** is `secrets.env` → the currently-installed unit
  (`flag_value`) → the daemon's config (`bitcoin_conf_value`) → generate. Keep
  that order: it is what makes adoption on a running host a no-op.
- **`deploy.sh` is re-entrant and ordered.** It runs `install.sh` twice: once up
  front (units, secrets, data dirs) and once after `lightningd` is up, because
  the CLN runes need a running node. Do not collapse those into one call.
- **CLN runes are verified, not trusted.** `createrune` happily returns a rune
  whose `unique_id` the node has blacklisted; `install.sh` proves each one with
  `checkrune` and retries on a fresh id. This bit the first deploy (server
  reported healthy while every tool call failed with 1503).
- **`monero-wallet-rpc` cannot start before the wallet exists.** `deploy.sh`
  runs the wallet step between `monerod` and the wallet RPC for that reason.
- **lightningd needs bitcoind's *wallet* RPC, and it dies with the container
  left "Up".** Lightningd's bcli plugin can time out on its first RPC while
  bitcoind is still loading its wallet ("The Bitcoin backend died"); the
  lightningd image's entrypoint then keeps PID 1 alive, so the quadlet unit
  reads "active", `Restart=always` never fires, and the RPC is gone until the
  unit is restarted by hand. deploy.sh therefore restarts a still-active
  lightningd whose container health reports `unhealthy`, waits for
  wallet-level RPC (`getwalletinfo`) before waiting on lightningd, and dumps
  the container log when any of those waits time out.
- **Data-dir ownership.** `bitcoind` and `monero-wallet-rpc` run as the image's
  uid (host 525287 = in-container 1000) and do **not** re-own their bind mounts;
  `install.sh` does `podman unshare chown -R 1000:1000` for them. `monerod`'s
  entrypoint does re-own its own directory. `$DATA_DIR/cln` and `$DATA_DIR/tor` are
  written by container root, which is the host user under rootless podman.
- **Backup is a one-shot Quadlet job plus a plain user timer.** `backup.container`
  is `Type=oneshot` with **no `[Install]` and no `RemainAfterExit`** (either would
  stop the timer from ever firing again); `backup.timer` is not Quadlet at all --
  Quadlet has no `.timer` type -- so `install.sh` renders it into
  `~/.config/systemd/user/` and `systemctl --user enable --now`s it. It activates
  the `backup.service` the generator makes from `backup.container`.
- **The backup set is `cln/ monero-wallet-rpc/ config/ npm/ audit/ postgres-dump/` only.**
  The chains, `searxng/` and the raw `postgres/` cluster are re-downloadable (or,
  for postgres, only crash-recoverable) and stay out, so restic never walks them.
  `deploy/postgres-dump.container` is a oneshot that `backup.container`
  `Wants=`/`After=`; it runs `pg_dumpall` into `$DATA_DIR/postgres-dump` (the
  only thing the backup mounts for BoltMesh). Its libpq settings are in
  `config/boltmesh/dump.env`, **not** `db.env`: `PGHOST`/`PGUSER` in the postgres
  server's own environment would break its socket-based entrypoint bootstrap. The
  repo lives in `$STACK_BACKUP_DIR` (stack.conf), outside `$DATA_DIR`,
  and the unit is secret-free: the repo path and `RESTIC_PASSWORD` reach it through
  `backup.env` (`EnvironmentFile`). `scripts/backup.sh` reads them from the
  **environment first, then the file** -- the only order that can recover a fresh
  host, since the file lives inside the repository.
- **BoltMesh is a tier of four units, not an MCP server.** `postgres`,
  `boltmesh-backend`, `boltmesh-worker`, `boltmesh-frontend`. It is built by
  `deploy_boltmesh` in `deploy.sh`, not `deploy_app`: the repos live under a
  second org (`GITHUB_ORG_BOLTMESH`) and the frontend needs `--target prod` plus
  the `VITE_*` build args (baked into the bundle, so a hostname change is a
  rebuild). It brings no chains: the backend points at the stack's `lightningd`
  (clnrest) and `monero-wallet-rpc`. Its rune is deliberately minimal
  (`getinfo`/`listinvoices`/`invoice`), so BoltMesh can bill but never move funds.
  Its four env files live under `$DATA_DIR/config/boltmesh/`: `db.env` and
  `secrets.env` are generated, `app.env` is operator-editable, `gateway.env` is
  machine-written from the running daemons. `install.sh` seeds `app.env` from the
  `BOLTMESH_*` values in `stack.conf`.
- **Shared bind mounts use `:z`, not `:Z`.** The backup container mounts `cln/` and
  `npm/` read-only alongside `lightningd` and `nginx-proxy-manager`; two containers
  cannot share a path one labels private (whichever starts last relabels it and
  locks the other out). Those two units were flipped from `:Z` to `:z` for this.
- **`sudo` lives only in `bootstrap.sh`.** `deploy.sh`, `deploy/install.sh`,
  `verify.sh` and the `scripts/` helpers never call it; privileged host setup
  (packages, linger, the unprivileged-port sysctl, firewalld ports) is bootstrap's
  job. A data dir the deploy cannot prepare is an error carrying the one-time
  commands, not an implicit prompt. SELinux labelling is best-effort unprivileged
  (`chcon` on the top dir only -- the image-uid subdirs are not ours to relabel,
  and podman's `:z` labels the mounted subdirs); the `semanage`/`restorecon` form is
  printed only when the path is not ours to relabel.
- **The network subnet is pinned** (`10.89.0.0/24` in
  `deploy/npm-network.network`) because `tor.container` pins `--ip=10.89.0.240`
  and both `bitcoin.conf` (`rpcallowip`) and `torrc` (`SocksPolicy`) allow that
  subnet. Every copy of the file carries it; don't drop it.
- **`:80` rootless** needs `net.ipv4.ip_unprivileged_port_start<=80`, which
  `bootstrap.sh` sets — otherwise nginx-proxy-manager cannot bind.
- `tor.container` addresses Tor by pinned IP, not name: `lightningd` runs with
  `--always-use-proxy=true`, which suppresses DNS.
- `torrc`'s `HashedControlPassword` must hash to the plaintext
  `TOR_SERVICE_PASSWORD`; `install.sh` derives it with `tor --hash-password` on a
  fresh host (after building the tor image) and otherwise leaves `torrc` alone.
- **Spending stays off**: `install.sh` writes `ENABLE_SPENDING=0` to both money
  servers' `spend.env`. Never seed it to 1. `scripts/spend-audit.sh` (run by the
  monitor) then asserts it on every run, hash-baselines both `spend.env`, both
  token files and `node.env` (the spend rune), and diffs outgoing `listpays` /
  `get_transfers` against a baseline -- so a flip or a spend cannot pass
  unnoticed.
- **The monitor is a host script, not a container.** `monitor.timer` (plain user
  unit; Quadlet has no `.timer`) activates `monitor.service`, which runs
  `scripts/monitor.sh` with `EnvironmentFile=@CONFIG_DIR@/monitoring/monitor.env`.
  It reuses `verify.sh` for the base checks and adds chain freshness, CLN
  peers/channels and the spend tripwire. It is **alert-only** (never restarts a
  unit) and read-only. Alerting is **off until `monitor.env` is filled in**: the
  `MONITOR_APPRISE_URLS` Apprise targets (sent through a one-shot
  `caronc/apprise` container) and the `MONITOR_PING_URL` dead-man's-switch
  heartbeat (plain `curl` to healthchecks.io; the only thing that notices a dead
  *host*). Two Apprise traps: the image defines no ENTRYPOINT, so the call is
  `podman run --rm caronc/apprise apprise -t TITLE -b BODY URL...` (the CLI must
  be named or the runtime tries to exec `-t`), and a `mailto://` URL on port 587
  needs `?mode=starttls` (`465` uses `?mode=ssl`) -- anything else fails with a
  bare "Connection error", not an SMTP auth failure. URLs are space-separated in
  `MONITOR_APPRISE_URLS` and go on the container's command line.
  Its record lives in `$DATA_DIR/audit/`, which is in the backup set.
- **App health is polled by port, not podman status.** The five MCP images
  define no podman healthcheck (their app repos own the Containerfiles), so
  podman never reports `(healthy)` for them and `wait_healthy` would burn its
  whole timeout. `deploy.sh` polls each server's `/health` contract on its host
  loopback port (`app_port` in `deploy.sh`) before verification runs.
- MCP test suites live in their own repos; `./verify.sh` is the runtime check
  (health, 401-without-token, authenticated handshake per endpoint) and also
  reports whether `monitor.timer` is installed and active.

## Interface contract with the app repos

The five MCP servers are pure env-configured services: **they never read a stack
path, a config file or a data dir** — only the variables below. This table is
the shared contract; the app repos' docs own the *meaning* of the variables,
this repo owns everything about *how they get set*. If a container name, port or
variable name changes, it changes on both sides at once.

| Server | Container / unit / image | Env files (`$DATA_DIR/config/<app>/`) | Upstream it defaults to | Host port (loopback) | Bind + health |
| --- | --- | --- | --- | --- | --- |
| `searxng-mcp` | `searxng-mcp` / `localhost/searxng-mcp:latest` | `token.env` | `searxng:8080/search` | `127.0.0.1:8100` | `0.0.0.0:8000`, `/health` |
| `bitcoin-node-mcp` | `bitcoin-node-mcp` / `localhost/bitcoin-node-mcp:latest` | `token.env`, `upstream.env` | `bitcoind:8332` | `127.0.0.1:8101` | `0.0.0.0:8000`, `/health` |
| `monero-node-mcp` | `monero-node-mcp` / `localhost/monero-node-mcp:latest` | `token.env`, `upstream.env` | `monerod:18089` | `127.0.0.1:8102` | `0.0.0.0:8000`, `/health` |
| `monero-wallet-mcp` | `monero-wallet-mcp` / `localhost/monero-wallet-mcp:latest` | `token.env`, `upstream.env`, `spend.env` | `monero-wallet-rpc:18083/json_rpc` | `127.0.0.1:8103` | `0.0.0.0:8000`, `/health` |
| `lightning-mcp` | `lightning-mcp` / `localhost/lightning-mcp:latest` | `token.env`, `node.env`, `spend.env` | `lightningd:3010` | `127.0.0.1:8104` | `0.0.0.0:8000`, `/health` |

The host ports are **loopback only** and are not opened in firewalld: NPM
terminates TLS and is the sole path to every MCP server (reaching it by container
name on `npm-network`). `Bind + health` is the bind and health path *inside* the
container, which is still `0.0.0.0` — the app's `MCP_HOST`/`MCP_PORT` contract is
unchanged.

The variables the apps read (names and defaults are the app repos' contract):
`SEARXNG_URL`/`SEARXNG_MCP_TOKEN`; `BITCOIN_RPC_URL`/`BITCOIN_RPC_USER`/
`BITCOIN_RPC_PASSWORD`/`BITCOIN_MCP_TOKEN`; `MONERO_RPC_URL`/`MONERO_RPC_USER`/
`MONERO_RPC_PASSWORD`/`MONERO_MCP_TOKEN`; `MONERO_WALLET_RPC_URL`/
`MONERO_WALLET_RPC_USER`/`MONERO_WALLET_RPC_PASSWORD`/`MONERO_MCP_TOKEN`/
`MONERO_MCP_SPEND_TOKEN`; `LIGHTNING_REST_URL`/`LIGHTNING_RUNE`/
`LIGHTNING_SPEND_RUNE`/`LIGHTNING_TLS_INSECURE`/`LIGHTNING_CA_CERT`/
`LIGHTNING_MCP_TOKEN`/`LIGHTNING_MCP_SPEND_TOKEN`; and the shared
`MCP_HOST`/`MCP_PORT`, `ENABLE_SPENDING` and the spend caps.

Because the upstream names/ports are compiler-baked defaults, renaming a daemon
in `deploy/` without updating this table (and the app's default) silently breaks
that server — treat this section as the thing to check when either side moves.

### The BoltMesh app tier

Not MCP servers, so they are absent from the table above. Same rule applies
though: the container name, host loopback port and env file paths below are the
shared contract with the `boltmesh-labs` repos.

| Unit | Image | Env files (`$DATA_DIR/config/boltmesh/`) | Upstream it reaches | Host port (loopback) | Health |
| --- | --- | --- | --- | --- | --- |
| `postgres` | `docker.io/library/postgres:18-alpine` | `db.env` (`POSTGRES_*`) | — | — | `pg_isready -h 127.0.0.1` |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `db.env`, `secrets.env`, `app.env`, `gateway.env` | `postgres:5432`, `valkey:6379`, `lightningd:3010`, `monero-wallet-rpc:18083` | `127.0.0.1:8105` | `0.0.0.0:8000`, `/health` (deep) |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | the same four | the same | — | liveness file `/tmp/arq-worker-liveness` |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | — (`VITE_*` baked at build) | — | `127.0.0.1:8106` | `0.0.0.0:80`, `/` |

The backend reads the app repos' variables (`DATABASE_URL`, `CACHE_URL`,
`SECRET_KEY`/`REFRESH_SECRET_KEY`/`NODE_SECRET_KEY`/`BOOTSTRAP_SECRET_PEPPER`,
`LIGHTNING_GATEWAY_URL`/`LIGHTNING_API_KEY`/`LIGHTNING_TLS_INSECURE`,
`MONERO_RPC_URL`/`MONERO_RPC_USER`/`MONERO_RPC_PASSWORD`, `APP_ENV`,
`API_BASE_URL`/`FRONTEND_URL`/`CORS_ALLOW_ORIGINS`, `GOOGLE_*`/`GITHUB_*`,
`MAIL_*`, `GITHUB_REPO`/`GITHUB_TOKEN`). `APP_ENV=prod` is what makes the
refresh cookie `Secure` + `SameSite=None`, which the split
`boltmesh.net`/`api.boltmesh.net` hosting needs.
