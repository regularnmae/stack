# stack — agent notes

This repo is the **single owner of the runtime**: the scripts listed below and
every unit the host runs. The application repos (`searxng-mcp`,
`bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`, `lightning-mcp`,
`fulcrum-mcp`, `victoria-logs-mcp`, `victoriametrics-mcp`, and BoltMesh's
`backend`/`frontend` under
`boltmesh-labs`) ship only code, tests, CI and a `Containerfile` — if a unit or
an env file changes, it changes here.

Operator-facing narrative (install, data dir, restore, rollback, layout) lives
in `README.md`. This file is the agent-facing complement and does not repeat it:
decisions, traps, and where the detail actually lives. When a script or unit
already documents a mechanism in its own header, this file points at it instead
of restating it — read that file before changing the behaviour.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`** — `EnvironmentFile=`
/`Environment=` reach the container's environment, not the daemon's argv, so a
secret cannot reach `--bitcoin-rpcpassword` etc. from an env file. So **every
unit is rendered** by `install.sh` from `deploy/*.container[.in]`, substituting
`@DATA_DIR@`/`@CONFIG_DIR@` (the plain user units also use `@REPO_DIR@`); the
three secret-bearing units, `lightningd`, `fulcrum` and `crowdsec`,
additionally substitute `@PLACEHOLDERS@` from `config/stack/secrets.env`. Rendered
units are mode 600 and never committed; none is a symlink. Never move a secret
onto a committed `.container`. The BTCPay wallet uses the `btcpayserver/monero`
image on purpose: the `simple-monero-wallet-rpc` entrypoint binds `0.0.0.0` only
when `--rpc-login` is on the command line, and the plugin hardcodes empty
credentials, so that image would be unreachable.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewall ports, dirs
./deploy.sh                         # fetch repos, build, start, verify
./deploy.sh --only <name>           # one service; --dry-run to plan
./deploy.sh --only backup           # run the backup job now
./deploy.sh --only db-dump          # refresh the two live-database dumps now
./deploy.sh --only backup-verify    # run the restore drill now (weekly on a timer)
./deploy.sh --only backup-verify-db # replay the snapshot's postgres dump now (monthly on a timer)
./deploy.sh --only monitor          # run the health + spend checks now
./deploy.sh --only victoria-logs    # generic unit restart (LOGS_* land in the .container)
./deploy.sh --only vector           # generic unit restart; vector.toml is in unit_digest
./scripts/logs.sh --since 1h        # cross-service log search (LogsQL; UI on :9428)
./deploy.sh --only npm-hosts        # (re)reconcile every proxy host in nginx-proxy-manager
./deploy.sh --only agent-skills     # re-link the skills + agent-mcp into the harnesses
./deploy.sh --only tor              # generic unit restart; the torrc digest is in unit_digest
./deploy.sh --only crowdsec         # generic unit restart; its config tree digest is in unit_digest
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health, MCP handshakes, onion fetches
./scripts/healthcheck-lint.sh       # every unit against the healthcheck contract (the CI gate)
./scripts/btcpay-wallet.sh          # import the view-only BTCPay Monero wallet
./scripts/backup.sh                 # restic backup / restore / verify / inspect
./scripts/monitor.sh                # the monitor.timer sweep, by hand
./scripts/ids.sh -v                 # the IDS roll-up, by hand (ids.timer runs it every 5 min)
./scripts/spend-audit.sh            # spend drift + outgoing-activity tripwire
./scripts/rotate.sh --list          # credentials this repo can rotate (+ --dry-run)
./scripts/rotate.sh --status        # credential invariants (runes, RPC password), last 10 runs
./scripts/npm-hosts.sh              # reconcile every proxy host, via the NPM admin API
./scripts/kuma-monitors.sh          # reconcile the status page's monitors, via uptime-kuma's socket.io API
shellcheck -x -P SCRIPTDIR -S info $(git ls-files '*.sh')  # the CI lint: every tracked shell script, enumerated from git so a new one cannot be skipped; CI pins shellcheck v0.11.0, so match it locally (the runner's own is older and disagrees -- SC2015)
```

Four `--only` targets above -- `victoria-logs`, `vector`, `tor`, `crowdsec` --
have no dedicated case in `deploy.sh`, on purpose: they are ordinary unit
restarts. `install.sh` re-renders them, and the restart is what `unit_digest`
decides, over `torrc`, the CrowdSec config tree and `vector.toml` under their
unit's stem (`LOGS_*` reach `victoria-logs` through the rendered `.container`
itself). Only the targets with real extra work -- rebuild, migrate, host
rewrite, run-now -- are branches in the dispatch.

## Where the detail lives

This file is the index: the invariants, the traps, and the contract the app repos
share. The reasoning behind each rule -- the measurements, the exceptions and the
"we tried this and it cost a day" -- is in `docs/`, one file per subsystem. Read
the file for the area you are about to change *before* changing it; each line
below states the rule, the doc says why it is the rule.

## Invariants and traps

### The runtime -- `docs/units.md`

- **`install.sh` is the only installer:** every env file is seeded and every unit
  rendered there. A new service is a unit in its `UNITS` array, nothing in an app
  repo.
- **Secret resolution order** is `secrets.env` → the installed unit → the
  daemon's config → generate; that order is what makes adoption a no-op.
- **`deploy.sh` runs `install.sh` twice** -- the CLN runes need a running node.
- **A re-render alone does not change a running container:** `units.rendered`
  vs `units.applied`, compared by `unit_digest`. Never digest the files either
  side of the installer; a hand render is drift, and `verify.sh` names the units.
- **`rotate.sh` is the third writer of `units.applied`**, and commits only what
  it restarted or proved already current.
- **`<unit>.bak` is the previous render**, written only when the bytes changed --
  else the second install pass of a deploy destroys the rollback.
- **A container unit mounts only from `$DATA_DIR`**, never the checkout. Host
  scripts may run from the checkout; a daemon-started container may not.
- **CLN runes are verified, not trusted:** `createrune` can return a blacklisted
  `unique_id`, so each is proved with `checkrune`.
- **Healthchecks:** five keys explicit, `kill` never `restart`, and the probe
  proves the serving path, never the data path. `wait_healthy` raises its timeout
  to the unit's start period, and `dur_ms` parses fractional Go durations.
- **Data-dir ownership:** bitcoind runs as the image uid and does not re-own its
  bind mount; `monerod` re-owns its own.
- **Every pulled image carries a real tag**, and two Renovate managers cover
  them -- the Quadlet one cannot see `deploy/*.container.in`. Workflow actions
  go the *other* way: digest-pinned, because their tag is mutable.
- **A merged Containerfile digest bump reaches the host on the next deploy**:
  images are labelled with their Containerfile's hash.
- **BoltMesh is a tier of four units, not an MCP server**, and holds no CLN rune.
- **Shared bind mounts use `:z`, not `:Z`.**
- **`sudo` lives only in `bootstrap.sh`**, which is why the root tier makes it
  two-pass.
- **A Quadlet unit without `[Install]` never starts at boot** -- `crowdsec` was
  absent after a reboot with no symptom but a failing bouncer.
- **Host-side probes exec into the two long-lived `netcheck` containers**, never
  a `podman run` per probe; `crowdsec-mcp` is the one host-network exception.

### Logs -- `docs/logs.md`

- **journald is the source, `vector` the only shipper, `victoria-logs` the
  history.** Neither store is published; the MCP servers are the front doors.
- **podman's event log is a config value**, not a per-call flag: `file`, not
  `journald`. `podman logs -f` then stops working by podman's own rule.
- **Reading the host journal from a container is two settings**: `keep-groups`
  and `SecurityLabelDisable`, plus `/etc/machine-id` and *both* journal dirs.
- **`Storage=persistent` takes effect on a flush, not a restart**; judge it by a
  file under `/var/log/journal`, never by the config.
- **`current_boot_only=false` is unsupported on systemd 250-257**; it is pinned
  `true`.
- **Three more sources feed the store** -- Suricata's `eve.json`, BoltMesh's
  structlog, and NPM's access/error logs, which are the only record of a request
  because NPM terminates TLS.

### Intrusion detection -- `docs/ids.md`

- **Two engines, two privilege domains, neither redundant:** Suricata sees
  packets and no TLS content, CrowdSec sees NPM's log and nothing on the wire.
- **Enforcement is ours** and refuses private space, every address the host
  holds, and `STACK_WAN_IP`. `CROWDSEC_BOUNCER_KEY` is never regenerated.
- **The audit tier watches files only** -- directory watches record nothing on
  this kernel -- and never, ever runs `auditctl -D`.

### Backup -- `docs/backup.md`

- **Backup is a oneshot Quadlet job plus a plain user timer** (no `[Install]`, no
  `RemainAfterExit`, or the timer never fires).
- **The drill's verdict is a file** (`audit/backup-verify.status`), because that
  is what the monitor reads; only an unapplied SELinux label is an acceptable
  restore error, and it is counted, not pinned.
- **The dump is drilled monthly, by a second drill**: the weekly run must not
  depend on pulling an image.
- **Restore before deploy, replay the dump after, migrate last** -- the seed-once
  files are why the order is load-bearing.
- **The set is declared once**, as `BACKUP_PATHS`/`BACKUP_EXCLUDES` in
  `stack.conf`, read by both the unit and the hand run.
- **Every live database is backed up as a dump, never as files.**

### The proxy tier -- `docs/proxy.md`

- **`uptime-kuma` is UI-configured for its own account, declared for everything
  else**, through the `kuma-ctl` image; notifications stay UI-configured.
- **Rate limiting is per ingress:** clearweb by `$binary_remote_addr`, the onion
  zone *global* (every `.onion` visitor is the host's own address), and the MCP
  host gets `limit_conn` only.
- **The subnet is pinned** (`10.89.0.0/24`), and four containers pin `.241`-`.244`
  because tor validates a target at startup.
- **`torrc`'s `HashedControlPassword` must hash to `TOR_SERVICE_PASSWORD`.**
- **`tor` is the onion publisher**, and its address is key material in
  `$DATA_DIR/tor/onion/` -- never seed it anywhere. The wildcard `*.onion` host
  gets no certificate and never `force-ssl`.
- **nginx-proxy-manager runs on the host network**, so every fronted unit
  publishes on loopback and NPM cannot resolve a container name.
- **Every proxy host is declared**, in `NPM_HOSTS`, reconciled by
  `scripts/npm-hosts.sh`; `--prune` is the only destructive mode.

### The monitor and alerting -- `docs/alerting.md`

- **The monitor is a read-only host script, never a container**, and it never
  restarts a unit.
- **Alerting is two processes:** the monitor finds faults, Alertmanager decides
  when to speak. `resolve_timeout` must be far longer than the sweep (24h), the
  flap damper lives in the producer, and a failed delivery is read back on the
  next sweep.
- **Metrics are history, not alerting, and the two must not be coupled**: the
  monitor never queries the store.
- **The one exception** is the log pipeline's own health, where a failure can
  only *add* an alert.

### The chain tier -- `docs/chains.md`

- **`lightningd` can die with its container still "Up"**, which is why the unit
  carries `HealthOnFailure=kill`.
- **CLN peers and channels come from `listpeerchannels`/`listpeers`**, never
  `listchannels` or `getinfo`'s `num_peers`.
- **Both daemons are full archival nodes**, and the data disk must be sized for
  it.
- **`fulcrum` is the one non-NPM LAN surface**, and its probe is the process
  table: ask it for `blockchain.headers.subscribe`, never `server.version`.
- **The two explorers add no index** -- one reads bitcoind (and Fulcrum), the
  other is RPC-only against monerod.

### Credentials -- `docs/credentials.md`

- **Spending stays off**; `spend-audit.sh` asserts it.
- **Rotation goes through the same two authorities as install**, with no journal
  and no `--resume`: re-run the target.
- **A daemon-side mutation is guarded for `--dry-run` inside the function that
  performs it**, never only at the call site.
- **No bearer token reaches the host's argv** -- a curl config on stdin carries
  them.

### BTCPay Server -- `docs/btcpay.md`

- **The XMR wallet is view-only and optional at first**, and a restore height
  above monerod's tip stalls it rather than failing cleanly.
- **The plugin is a file, so nothing else notices a bump** -- no unit digest can
  see it.
- **`btcpay-mcp` holds a read-only key**, minted by the bootstrap, with four
  `canview*` permissions.

### Agent tooling -- `docs/clients.md`

- **`agent-skills` is client tooling, not a service**, and never joins
  `APP_REPOS`; its tokens are read from `$DATA_DIR` on every call, never copied.

## Interface contract with the app repos

The ten MCP servers are pure env-configured services: **they never read a stack
path, a config file or a data dir** — only the variables below. This table is
the shared contract; the app repos' docs own the *meaning* of the variables,
this repo owns everything about *how they get set*. If a container name, port or
variable name changes, it changes on both sides at once.

| Server | Container / unit / image | Env files (`$DATA_DIR/config/<app>/`) | Upstream it defaults to | On npm-network | NPM target | Bind + health |
| --- | --- | --- | --- | --- | --- | --- |
| `searxng-mcp` | `searxng-mcp` / `localhost/searxng-mcp:latest` | `token.env` | `searxng:8080/search` | `searxng-mcp:8000` | `127.0.0.1:8100` | `0.0.0.0:8000`, `/health` |
| `bitcoin-node-mcp` | `bitcoin-node-mcp` / `localhost/bitcoin-node-mcp:latest` | `token.env`, `upstream.env` | `bitcoind:8332` | `bitcoin-node-mcp:8000` | `127.0.0.1:8101` | `0.0.0.0:8000`, `/health` |
| `monero-node-mcp` | `monero-node-mcp` / `localhost/monero-node-mcp:latest` | `token.env`, `upstream.env` | `monerod:18089` | `monero-node-mcp:8000` | `127.0.0.1:8102` | `0.0.0.0:8000`, `/health` |
| `monero-wallet-mcp` | `monero-wallet-mcp` / `localhost/monero-wallet-mcp:latest` | `token.env`, `upstream.env`, `spend.env` | `monero-wallet-btcpay:18083/json_rpc` | `monero-wallet-mcp:8000` | `127.0.0.1:8103` | `0.0.0.0:8000`, `/health` |
| `lightning-mcp` | `lightning-mcp` / `localhost/lightning-mcp:latest` | `token.env`, `node.env`, `spend.env` | `lightningd:3010` | `lightning-mcp:8000` | `127.0.0.1:8104` | `0.0.0.0:8000`, `/health` |
| `fulcrum-mcp` | `fulcrum-mcp` / `localhost/fulcrum-mcp:latest` | `token.env`, `upstream.env` | `fulcrum:50001` | `fulcrum-mcp:8000` | `127.0.0.1:8110` | `0.0.0.0:8000`, `/health` |
| `victoria-logs-mcp` | `victoria-logs-mcp` / `localhost/victoria-logs-mcp:latest` | `token.env`, `upstream.env` | `victoria-logs:9428` | `victoria-logs-mcp:8000` | `127.0.0.1:8111` | `0.0.0.0:8000`, `/health` |
| `victoriametrics-mcp` | `victoriametrics-mcp` / `localhost/victoriametrics-mcp:latest` | `token.env`, `upstream.env` | `victoriametrics:8428` | `victoriametrics-mcp:8000` | `127.0.0.1:8112` | `0.0.0.0:8000`, `/health` |
| `crowdsec-mcp` | `crowdsec-mcp` / `localhost/crowdsec-mcp:latest` | `token.env`, `lapi.env` | CrowdSec LAPI, `127.0.0.1:8080` | **— (`Network=host`)** | `127.0.0.1:8113` | `127.0.0.1:8113` (host net), `/health` |
| `btcpay-mcp` | `btcpay-mcp` / `localhost/btcpay-mcp:latest` | `token.env`, `upstream.env` | `btcpay:49392` | `btcpay-mcp:8000` | `127.0.0.1:8114` | `0.0.0.0:8000`, `/health` |

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

**`crowdsec-mcp` is the one exception, and it is forced from upstream.**
`crowdsec` runs on the host network because `stack-bouncer` (root, on the host)
must reach the LAPI on `127.0.0.1:8080`, and a rootless bridge is not routable
from the host; pasta's `host.containers.internal` lands on the host's LAN
address, not its loopback, so a bridge container cannot reach the LAPI at all.
The MCP unit therefore also runs `Network=host` and binds `MCP_HOST=127.0.0.1`,
`MCP_PORT=8113` itself — no `PublishPort`, and no LAN surface. Two consequences
worth knowing: NPM reaches it exactly like a loopback publish, but every
host-side probe must go through `netcheck-host`, which `scripts/lib.sh`'s
`MCP_HOST_NETNS` declares once (`mcp_base`/`mcp_curl`, used by `verify.sh`,
`rotate.sh` and `monitor.sh`) — so callers keep naming the container. And the
container joins the host's network namespace, i.e. it can reach every
loopback-only service (alertmanager, the metrics and log stores, NPM's admin
API); the app is three fixed-URL GETs behind a bearer token with no generic
fetch tool, which bounds but does not remove that blast radius.

**The CrowdSec tier's read surface stops at decisions, on purpose.** A bouncer
key answers `/v1/decisions` and nothing else; `/v1/alerts` needs a *machine*
credential, and a machine may also create and delete decisions and push alerts
— i.e. ban and unban — which is exactly the authority this stack keeps out of
an agent's reach. So there is no alert tool and no ban/unban tool, and
`lapi.env` must never hold a machine password. The key is a **second** bouncer
(`mcp`, rendered into the crowdsec unit from `CROWDSEC_MCP_BOUNCER_KEY`) rather
than stack-bouncer's `firewall` one: the LAPI attributes each client's pulls
separately in `cs_lapi_bouncer_requests_total`, and `cscli bouncers delete mcp`
revokes the server without touching enforcement. Both keys are
never-regenerate (the entrypoint only registers a bouncer when the name is
absent). `list_bouncers` is not implementable over the LAPI at all — there is no
`/v1/bouncers` route, and `cscli bouncers list` reads the DB and shows stale
entries for our hand-rolled poller, which never heartbeats; enforcement
freshness stays `audit/bouncer.status`. The engine's own Prometheus endpoint is
pinned to `127.0.0.1:6060` in `deploy/crowdsec/config.yaml.local` (upstream
defaults to `0.0.0.0`), and `crowdsec-mcp` is its one reader.

The variables the apps read (names and defaults are the app repos' contract):
`SEARXNG_URL`/`SEARXNG_MCP_TOKEN`; `BITCOIN_RPC_URL`/`BITCOIN_RPC_USER`/
`BITCOIN_RPC_PASSWORD`/`BITCOIN_MCP_TOKEN`; `MONERO_RPC_URL`/`MONERO_RPC_USER`/
`MONERO_RPC_PASSWORD`/`MONERO_MCP_TOKEN`; `MONERO_WALLET_RPC_URL`/
`MONERO_WALLET_RPC_USER`/`MONERO_WALLET_RPC_PASSWORD`/`MONERO_MCP_TOKEN`/
`MONERO_MCP_SPEND_TOKEN`; `LIGHTNING_REST_URL`/`LIGHTNING_RUNE`/
`LIGHTNING_SPEND_RUNE`/`LIGHTNING_TLS_INSECURE`/`LIGHTNING_CA_CERT`/
`LIGHTNING_MCP_TOKEN`/`LIGHTNING_MCP_SPEND_TOKEN`; `FULCRUM_URL`/
`FULCRUM_MCP_TOKEN`; and the shared `MCP_HOST`/`MCP_PORT`, `ENABLE_SPENDING`
and the spend caps.

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
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `db.env`, `secrets.env`, `app.env`, `config/btcpay/backend.env` | `postgres:5432`, `valkey:6379`, `btcpay:49392` | `boltmesh-backend:8000` | `127.0.0.1:8105` | `0.0.0.0:8000`, `/health` (deep) |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | the same four | the same | — | — | liveness file `/tmp/arq-worker-liveness` |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | — (`VITE_*` baked at build) | — | `boltmesh-frontend:80` | `127.0.0.1:8106` | `0.0.0.0:80`, `/` |

The four env files are `db.env`/`secrets.env` (generated), `app.env`
(operator-editable, seeded from `BOLTMESH_*` in `stack.conf`) and
`btcpay/backend.env` (written by `deploy.sh` from the bootstrap state). The backend reads the app repos'
variables (`DATABASE_URL`, `CACHE_URL`,
`SECRET_KEY`/`REFRESH_SECRET_KEY`/`NODE_SECRET_KEY`/`BOOTSTRAP_SECRET_PEPPER`,
`BTCPAY_URL`/`BTCPAY_API_KEY`/`BTCPAY_STORE_ID`/`BTCPAY_WEBHOOK_SECRET`, `APP_ENV`,
`API_BASE_URL`/`FRONTEND_URL`/`CORS_ALLOW_ORIGINS`, `GOOGLE_*`/`GITHUB_*`,
`MAIL_*`, `GITHUB_REPO`/`GITHUB_TOKEN`). `APP_ENV=prod` is what makes the
refresh cookie `Secure` + `SameSite=None`, which the split
`boltmesh.net`/`api.boltmesh.net` hosting needs.
