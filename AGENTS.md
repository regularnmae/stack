# stack — agent notes

This repo is the **single owner of the runtime**: the scripts listed below and
every unit the host runs. The application repos (`searxng-mcp`,
`bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`, `lightning-mcp`, and
BoltMesh's `backend`/`frontend` under `boltmesh-labs`) ship only code, tests, CI
and a `Containerfile` — if a unit or an env file changes, it changes here.

Operator-facing narrative (install, data dir, restore, rollback, layout) lives
in `README.md`; this file is the agent-facing complement and does not repeat it.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`** — `EnvironmentFile=`
/`Environment=` reach the container's environment, not the daemon's argv, so a
secret cannot reach `--bitcoin-rpcpassword` etc. from an env file. So **every
unit is rendered** by `install.sh` from `deploy/*.container[.in]`, substituting
`@DATA_DIR@`/`@CONFIG_DIR@` (the plain user units also use `@REPO_DIR@`); the two
secret-bearing units, `lightningd` and `monero-wallet-rpc`, additionally
substitute `@PLACEHOLDERS@` from `config/stack/secrets.env`. Rendered units are
mode 600 and never committed; none is a symlink. Never move a secret onto a
committed `.container`, and never "simplify" `monero-wallet-rpc` to a config
file: its entrypoint binds `0.0.0.0` only when `--rpc-login` is on the command
line, otherwise it forces `127.0.0.1` and the wallet is unreachable from the MCP
server.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewall ports, dirs
./deploy.sh                         # fetch repos, build, start, verify
./deploy.sh --only <name>           # one service; --dry-run to plan
./deploy.sh --only backup           # run the backup job now
./deploy.sh --only monitor          # run the health + spend checks now
./deploy.sh --only npm-hosts        # (re)reconcile every proxy host in nginx-proxy-manager
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health + MCP handshakes
./scripts/wallets.sh --monero       # create/restore the Monero wallet
./scripts/backup.sh                 # restic backup / restore / inspect
./scripts/monitor.sh                # the monitor.timer sweep, by hand
./scripts/spend-audit.sh            # spend drift + outgoing-activity tripwire
./scripts/npm-hosts.sh              # reconcile every proxy host, via the NPM admin API
./scripts/kuma-monitors.sh          # reconcile the status page's monitors, via uptime-kuma's socket.io API
shellcheck -x -P SCRIPTDIR -S info bootstrap.sh deploy.sh verify.sh deploy/install.sh scripts/lib.sh scripts/wallets.sh scripts/backup.sh scripts/monitor.sh scripts/spend-audit.sh scripts/npm-hosts.sh scripts/kuma-monitors.sh  # the CI lint; CI pins shellcheck v0.11.0, so match it locally (the runner's own is older and disagrees -- SC2015)
```

## Facts that are easy to get wrong

- **`install.sh` is the only installer:** every env file is seeded and every unit
  rendered there. A new service means a unit added to its `UNITS` (or
  `USER_UNITS`/`USER_TIMERS`) array plus env seeding — nothing in the app repos.
- **Secret resolution order** is `secrets.env` → the installed unit
  (`flag_value`) → the daemon's config (`bitcoin_conf_value`) → generate. That
  order is what makes adoption on a running host a no-op; keep it.
- **`deploy.sh` runs `install.sh` twice** — up front, then again after
  `lightningd` is up, because the CLN runes need a running node. Don't collapse
  them.
- **A re-render alone does not change a running container** (systemd keeps the
  old one), so `deploy.sh` digest-compares the rendered `.container` files
  either side of the first `install.sh` (`unit_digest` /
  `restart_changed_units`) and restarts exactly the units whose definition
  changed — never ones that are inactive, since those are started later in
  order. `nginx-proxy-manager` is only flagged there: its restart is deferred to
  `sync_npm_network`, after the proxy hosts are rewritten.
- **CLN runes are verified, not trusted:** `createrune` can return a rune whose
  `unique_id` the node blacklisted, so `install.sh` proves each with `checkrune`
  and retries on a fresh id.
- **`monero-wallet-rpc` cannot start before the wallet exists**, so `deploy.sh`
  runs the wallet step between `monerod` and the wallet RPC.
- **lightningd dies with its container left "Up":** bcli can time out while
  bitcoind is still loading its wallet, the entrypoint then keeps PID 1 alive,
  the unit reads "active" and `Restart=always` never fires. So `deploy.sh`
  restarts a still-active but `unhealthy` lightningd, waits for `getwalletinfo`
  before waiting on lightningd, and dumps the log on any timeout.
- **Data-dir ownership:** `bitcoind`/`monero-wallet-rpc` run as the image uid
  (host 525287 = in-container 1000) and do **not** re-own their bind mounts, so
  `install.sh` `podman unshare chown -R 1000:1000`s them; `monerod` re-owns its
  own directory. `cln/`, `tor/` and `uptime-kuma/` are written by container root
  (= the host user under rootless podman).
- **`uptime-kuma` is UI-configured for its own account, declared for
  everything else:** there is no env file in the unit and nothing is seeded
  into its sqlite — but its monitors are `KUMA_MONITORS` in `stack.conf`,
  reconciled by `scripts/kuma-monitors.sh` into the socket.io server (no REST
  write API) through the `kuma-ctl` image (built like `netcheck`, from
  `kuma-ctl/`). The admin login the setup wizard creates lives in
  `$DATA_DIR/config/uptime-kuma/api.env` (UI-first like `npm/api.env`); the
  reconciler, `deploy.sh` and `verify.sh` self-skip/warn until it is filled in.
  The reconciler carries UI-tuned monitor settings over untouched (compare
  declared fields only: url + accepted status codes) and only creates/fills
  the status page while it has no monitors of its own. Two more socket.io
  shape traps it lives with: multi-arg management events
  (`addStatusPage(title, slug)`, `saveStatusPage(slug, config, imgDataUrl,
  publicGroupList)`) are positional — send one object and the *ack callback*
  takes the next data slot, the handler never answers, and the client burns
  its whole ack timeout; and `imgDataUrl` must be a string (`null` throws in
  `saveStatusPage`). Notifications stay UI-configured. Note v2
  answers `/` with a **302 to `/dashboard`** — any probe must follow redirects
  (`verify.sh` does); a bare 200 on `/` is not what kuma returns. All this repo
  knows about it is the unit, the `8107` loopback publish, the
  `status.boltmesh.net` proxy host (`ws` for the dashboard's socket.io) and the
  backup dir. Don't "seed" its login into `config/` beyond `api.env`. Don't
  "simplify" the reconcile into curl calls: `add`/`editMonitor` are socket.io
  events, not REST endpoints. And anything sent over that socket.io — login
  first of all — must wait for the server's `info` event first: v2.5 registers
  its handlers only *after* `await sendInfo()`, so an event emitted straight
  after `connect` is dropped, not queued, and the client sees only its own ack
  timeout (`kuma-ctl/monitors.mjs` waits for `info` and retries). And the
  `add`/`editMonitor` payloads are shape-sensitive: `accepted_statuscodes`
  must be the **array** (the handler builds `accepted_statuscodes_json`
  itself and `.every()`-checks the array — sending the `_json` string or
  omitting it crashes server-side with "Cannot read properties of undefined
  (reading 'every')"), and `conditions`/`kafkaProducerBrokers`/
  `kafkaProducerSaslOptions`/`rabbitmqNodes` must arrive as raw arrays because
  the handler `JSON.stringify`es them itself (`monitors.mjs` carries a
  `rawArray()` helper). The `monitorList` push object is already in the shape
  `editMonitor` reads — spread it and override only declared fields.
  Renovate is
  taught about the `louislam/
  uptime-kuma` image tag by a custom `regex` manager in `renovate.json`
  (Renovate has no Quadlet manager, and its other `Image=` lines —
  `postgres:18-alpine`, `restic:latest` — are pinned deliberately, so the
  manager is scoped to that one file); the `kuma-ctl` Containerfile's node
  digest comes from the ordinary dockerfile manager.
- **Backup is a oneshot Quadlet job plus a plain user timer.** `backup.container`
  is `Type=oneshot` with **no `[Install]` and no `RemainAfterExit`** (either would
  stop the timer ever firing); `backup.timer` is not Quadlet (it has no `.timer`
  type), so `install.sh` renders it into `~/.config/systemd/user/` and enables it.
- **The backup set is `cln/ monero-wallet-rpc/ config/ npm/ audit/
  uptime-kuma/ postgres-dump/` only** — chains, `searxng/` and the raw
  `postgres/` cluster stay out so restic never walks them. `postgres-dump.container` (a oneshot) `pg_dumpall`s into
  `$DATA_DIR/postgres-dump`; its libpq settings belong in
  `config/boltmesh/dump.env`, **not** `db.env` (`PGHOST`/`PGUSER` in the server's
  own env break its socket-based entrypoint bootstrap). The repo is
  `$STACK_BACKUP_DIR`, reached through `backup.env`; `scripts/backup.sh` reads
  `RESTIC_*` from **the environment first, then the file** — the only order that
  can recover a fresh host, since the file lives inside the repository.
- **BoltMesh is a tier of four units, not an MCP server**, built by
  `deploy_boltmesh` (not `deploy_app`). The private `boltmesh-labs` repos clone
  over SSH (`GITHUB_SSH_HOST`), and `deploy.sh` sets `GIT_TERMINAL_PROMPT=0`/
  `GIT_SSH_COMMAND=ssh -o BatchMode=yes` so a missing key is a clear error, not a
  prompt. The frontend needs `--target prod` plus the `VITE_*` build args (baked
  into the bundle, so a hostname change is a rebuild). Its rune is deliberately
  minimal (`getinfo`/`listinvoices`/`invoice`), so BoltMesh can bill but never
  move funds.
- **Shared bind mounts use `:z`, not `:Z`** — the backup container mounts `cln/`
  and `npm/` read-only alongside `lightningd` and NPM, and two containers cannot
  share a path one labels private.
- **`sudo` lives only in `bootstrap.sh`.** `deploy.sh`, `install.sh`, `verify.sh`
  and the `scripts/` helpers never call it; an unprepared data dir is an error
  carrying the one-time commands, not a prompt.
- **The subnet is pinned** (`10.89.0.0/24`) because `tor.container` pins
  `--ip=10.89.0.240` and both `bitcoin.conf` (`rpcallowip`) and `torrc`
  (`SocksPolicy`) allow it. `tor` is addressed by that IP, not by name
  (`lightningd` runs `--always-use-proxy=true`, which suppresses DNS). Don't drop
  it.
- **`torrc`'s `HashedControlPassword` must hash to `TOR_SERVICE_PASSWORD`**;
  `install.sh` derives it with `tor --hash-password` on a fresh host and
  otherwise leaves `torrc` alone.
- **Spending stays off:** `install.sh` writes `ENABLE_SPENDING=0` to both money
  servers' `spend.env` (never seed `1`); `scripts/spend-audit.sh` asserts it,
  hash-baselines both `spend.env`, both token files and `node.env` (the spend
  rune), and diffs outgoing `listpays`/`get_transfers` against a baseline.
- **The monitor is a read-only host script, not a container:** `monitor.timer` (a
  plain user unit) runs `scripts/monitor.sh` with
  `EnvironmentFile=@CONFIG_DIR@/monitoring/monitor.env`; it is alert-only (never
  restarts a unit) and silent until `monitor.env` is filled in. Apprise traps:
  the `caronc/apprise` image has no ENTRYPOINT, so the CLI must be named
  (`podman run --rm caronc/apprise apprise -t TITLE -b BODY URL...`), and a
  `mailto://` URL on 587 needs `?mode=starttls` (`465` → `?mode=ssl`) or it
  fails with a bare "Connection error".
- **nginx-proxy-manager runs on the host network, and health comes from podman** —
  `deploy/nginx-proxy-manager.container` sets `Network=host` and has no
  `PublishPort=`, so NPM's own nginx binds :80/:443/:81 in the host's namespace
  and every request carries the client's real address. That is the *reason* it is
  not published: rootless podman forwards a published port with `rootlessport`, a
  userspace proxy that dials the container from inside the rootless namespace, so
  NPM logged its own container IP (`10.89.0.5`) as the client for every request.
  Podman ≥ 6.0 can forward with `pasta` instead (`rootless_port_forwarder="pasta"`
  under `[network]` in `~/.config/containers/containers.conf`), which does
  preserve the source address, but Rocky 10 ships podman 5.8 with no such key and
  no `pesto` — so don't "simplify" NPM back to `PublishPort=80:80`. Restart
  order is load-bearing too: `deploy.sh` rewrites the proxy hosts and only then
  restarts NPM (`sync_npm_network`), because its nginx resolves every upstream at
  start and refuses to come up while a saved host still names a container — which
  also takes the admin API on `:81` down, so the reverse order cannot be
  recovered through the API (park `$DATA_DIR/npm/data/nginx/proxy_host/*.conf`,
  then re-run). The price of
  `Network=host` is that NPM can no longer resolve a container name: every unit it
  fronts publishes its port on the host's **loopback**
  (`PublishPort=127.0.0.1:<port>:…`), those are the `127.0.0.1:` targets in
  `NPM_HOSTS`/`MCP_HOSTS`, and only 80/443/81 stay LAN-reachable. The host-side
  checks still read the services by container name on `npm-network` through
  `net_curl` — a throwaway `localhost/netcheck:local` container
  (`netcheck/Containerfile`, built by `install.sh`) — with `net_curl_host` the
  same image on the host network, for NPM's own admin API on `127.0.0.1:81`. The
  units *do* set `HealthCmd=`/`HealthInterval=`, so podman really does report
  `(healthy)` for them and `deploy.sh` waits with `wait_healthy`; the MCP probe is
  an authenticated `initialize`, i.e. strictly stronger than a `/health` GET.
- **The bearer tokens never reach the host's argv** — `mcp_initialize` /
  `mcp_tool_call` pass them in a curl config on stdin (`-K -`), so `ps` cannot
  read a token out of a running verify/monitor/audit sweep. `npm-hosts.sh`
  does the same with the NPM admin password and the API token it mints.
- **Every proxy host is declared, not hand-clicked:** `NPM_HOSTS` in
  `stack.conf` (`domain | [scheme://]host:port | flags`, where host is always
  `127.0.0.1` — the loopback publish of the unit being fronted) is the whole
  public surface, and `scripts/npm-hosts.sh` (run by `deploy.sh`, or
  `--only npm-hosts`) reconciles it through nginx-proxy-manager's admin API on
  `127.0.0.1:81` — update in place by `domain_names`, else create, plus a Let's
  Encrypt certificate per host. It needs the admin login in
  `$DATA_DIR/config/npm/api.env` and `jq` on the host (bootstrap); it self-skips
  when the login is absent. `--prune` (the only destructive mode) deletes hosts
  and certificates `NPM_HOSTS` does not declare. The `mcp` flag is the exception
  to "one forward": that host serves a location per `MCP_HOSTS` entry
  (`/prefix:container:port` — the container names the `token.env` that is the
  prefix's credential, the port is its loopback publish), each prefix rewritten
  onto the container's `/mcp` (the MCP SDK's streamable-HTTP default; the apps
  expose no path knob), and its nginx config must keep `proxy_buffering off` and
  a long `proxy_read_timeout` — the transport is SSE, and a buffered body hangs
  the client. `verify.sh` re-checks that path through NPM's `:80` (following the
  force-SSL redirect to `:443`) by connecting the public host to NPM itself with
  `--connect-to` — onto `127.0.0.1`, since NPM binds those ports in the host
  namespace — so the certificate still validates. Proxying a daemon's own
  API (`clnrest`, `xmr-rpc`) is gated only by that daemon's RPC credentials, not
  by an MCP token.

## Interface contract with the app repos

The five MCP servers are pure env-configured services: **they never read a stack
path, a config file or a data dir** — only the variables below. This table is
the shared contract; the app repos' docs own the *meaning* of the variables,
this repo owns everything about *how they get set*. If a container name, port or
variable name changes, it changes on both sides at once.

| Server | Container / unit / image | Env files (`$DATA_DIR/config/<app>/`) | Upstream it defaults to | On npm-network | NPM target | Bind + health |
| --- | --- | --- | --- | --- | --- | --- |
| `searxng-mcp` | `searxng-mcp` / `localhost/searxng-mcp:latest` | `token.env` | `searxng:8080/search` | `searxng-mcp:8000` | `127.0.0.1:8100` | `0.0.0.0:8000`, `/health` |
| `bitcoin-node-mcp` | `bitcoin-node-mcp` / `localhost/bitcoin-node-mcp:latest` | `token.env`, `upstream.env` | `bitcoind:8332` | `bitcoin-node-mcp:8000` | `127.0.0.1:8101` | `0.0.0.0:8000`, `/health` |
| `monero-node-mcp` | `monero-node-mcp` / `localhost/monero-node-mcp:latest` | `token.env`, `upstream.env` | `monerod:18089` | `monero-node-mcp:8000` | `127.0.0.1:8102` | `0.0.0.0:8000`, `/health` |
| `monero-wallet-mcp` | `monero-wallet-mcp` / `localhost/monero-wallet-mcp:latest` | `token.env`, `upstream.env`, `spend.env` | `monero-wallet-rpc:18083/json_rpc` | `monero-wallet-mcp:8000` | `127.0.0.1:8103` | `0.0.0.0:8000`, `/health` |
| `lightning-mcp` | `lightning-mcp` / `localhost/lightning-mcp:latest` | `token.env`, `node.env`, `spend.env` | `lightningd:3010` | `lightning-mcp:8000` | `127.0.0.1:8104` | `0.0.0.0:8000`, `/health` |

None of them is reachable from the LAN. NPM terminates TLS on :80/:443 (its own
bind, on the host network) and is the sole path to every MCP server for a client;
`NPM target` is the unit's loopback publish — `PublishPort=127.0.0.1:<port>:...`
in that unit — which is what `NPM_HOSTS`/`MCP_HOSTS` point at, because NPM can no
longer resolve a container name. The host-side checks read the very same
`<container>:8000` (`On npm-network`) through `net_curl`. `Bind + health` is the
bind and health path *inside* the container, which is still `0.0.0.0` — the app's
`MCP_HOST`/`MCP_PORT` contract is unchanged. For a client, the servers appear as
one host with a path prefix each — `https://$MCP_HOST/<prefix>`, mapped onto the
container's `/mcp` by the `mcp` proxy host `scripts/npm-hosts.sh` reconciles
from `NPM_HOSTS`; each `MCP_HOSTS` entry is `/prefix:container:port` (the
container names the `token.env`, the port is the loopback publish).

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
though: the container name and env file paths below are the shared contract with
the `boltmesh-labs` repos.

| Unit | Image | Env files (`$DATA_DIR/config/boltmesh/`) | Upstream it reaches | On npm-network | NPM target | Health |
| --- | --- | --- | --- | --- | --- | --- |
| `postgres` | `docker.io/library/postgres:18-alpine` | `db.env` (`POSTGRES_*`) | — | — | — | `pg_isready -h 127.0.0.1` |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `db.env`, `secrets.env`, `app.env`, `gateway.env` | `postgres:5432`, `valkey:6379`, `lightningd:3010`, `monero-wallet-rpc:18083` | `boltmesh-backend:8000` | `127.0.0.1:8105` | `0.0.0.0:8000`, `/health` (deep) |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | the same four | the same | — | — | liveness file `/tmp/arq-worker-liveness` |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | — (`VITE_*` baked at build) | — | `boltmesh-frontend:80` | `127.0.0.1:8106` | `0.0.0.0:80`, `/` |

The four env files are `db.env`/`secrets.env` (generated), `app.env`
(operator-editable, seeded from `BOLTMESH_*` in `stack.conf`) and `gateway.env`
(machine-written from the running daemons). The backend reads the app repos'
variables (`DATABASE_URL`, `CACHE_URL`,
`SECRET_KEY`/`REFRESH_SECRET_KEY`/`NODE_SECRET_KEY`/`BOOTSTRAP_SECRET_PEPPER`,
`LIGHTNING_GATEWAY_URL`/`LIGHTNING_API_KEY`/`LIGHTNING_TLS_INSECURE`,
`MONERO_RPC_URL`/`MONERO_RPC_USER`/`MONERO_RPC_PASSWORD`, `APP_ENV`,
`API_BASE_URL`/`FRONTEND_URL`/`CORS_ALLOW_ORIGINS`, `GOOGLE_*`/`GITHUB_*`,
`MAIL_*`, `GITHUB_REPO`/`GITHUB_TOKEN`). `APP_ENV=prod` is what makes the
refresh cookie `Secure` + `SameSite=None`, which the split
`boltmesh.net`/`api.boltmesh.net` hosting needs.
