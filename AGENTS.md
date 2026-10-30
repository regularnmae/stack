# stack — agent notes

This repo is the **single owner of the runtime**: the scripts listed below and
every unit the host runs. The application repos (`searxng-mcp`,
`bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`, `lightning-mcp`, and
BoltMesh's `backend`/`frontend` under `boltmesh-labs`) ship only code, tests, CI
and a `Containerfile` — if a unit or an env file changes, it changes here.

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
three secret-bearing units, `lightningd`, `monero-wallet-rpc` and `fulcrum`,
additionally substitute `@PLACEHOLDERS@` from `config/stack/secrets.env`. Rendered
units are mode 600 and never committed; none is a symlink. Never move a secret
onto a committed `.container`, and never "simplify" `monero-wallet-rpc` to a
config file: its entrypoint binds `0.0.0.0` only when `--rpc-login` is on the
command line, otherwise it forces `127.0.0.1` and the wallet is unreachable from
the MCP server.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewall ports, dirs
./deploy.sh                         # fetch repos, build, start, verify
./deploy.sh --only <name>           # one service; --dry-run to plan
./deploy.sh --only backup           # run the backup job now
./deploy.sh --only monitor          # run the health + spend checks now
./deploy.sh --only npm-hosts        # (re)reconcile every proxy host in nginx-proxy-manager
./deploy.sh --only tor              # re-render the onion services into torrc and restart tor
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health, MCP handshakes, onion fetches
./scripts/wallets.sh --monero       # create/restore the Monero wallet
./scripts/backup.sh                 # restic backup / restore / inspect
./scripts/monitor.sh                # the monitor.timer sweep, by hand
./scripts/spend-audit.sh            # spend drift + outgoing-activity tripwire
./scripts/rotate.sh --list          # credentials this repo can rotate (+ --dry-run)
./scripts/rotate.sh --status        # a pending rotation journal, last 10 runs
./scripts/npm-hosts.sh              # reconcile every proxy host, via the NPM admin API
./scripts/kuma-monitors.sh          # reconcile the status page's monitors, via uptime-kuma's socket.io API
shellcheck -x -P SCRIPTDIR -S info bootstrap.sh deploy.sh verify.sh deploy/install.sh scripts/lib.sh scripts/wallets.sh scripts/backup.sh scripts/monitor.sh scripts/metrics.sh scripts/spend-audit.sh scripts/rotate.sh scripts/npm-hosts.sh scripts/kuma-monitors.sh  # the CI lint; CI pins shellcheck v0.11.0, so match it locally (the runner's own is older and disagrees -- SC2015)
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
  `sync_npm_network`, after the proxy hosts are rewritten (`deploy.sh` says why
  the order is load-bearing).
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
- **CLN peers and channels come from `listpeerchannels`/`listpeers`, never
  `listchannels` or `getinfo`'s `num_peers`:** the gossmap's `active` is an
  operator setting that stays true while a peer is offline, and `num_peers`
  counts peers with channels whether or not they are connected.
  `scripts/monitor.sh` carries the shapes and the counting rule;
  `scripts/metrics.sh` emits `stack_cln_peers`/`stack_cln_channels_offline`.
  `lightning-cli` through `podman exec` is not gated by the clnrest rune — the
  MCP needs the method added to `READ_METHODS` in `deploy/install.sh`.
- **Data-dir ownership:** `bitcoind`/`monero-wallet-rpc` run as the image uid
  (host 525287 = in-container 1000) and do **not** re-own their bind mounts, so
  `install.sh` `podman unshare chown -R 1000:1000`s them; `monerod` re-owns its
  own directory. `cln/`, `tor/`, `uptime-kuma/` and `fulcrum/` are written by
  container root (= the host user under rootless podman).
- **`uptime-kuma` is UI-configured for its own account, declared for everything
  else:** no env file, nothing seeded into its sqlite, and its monitors are
  `KUMA_MONITORS` in `stack.conf`, reconciled by `scripts/kuma-monitors.sh`
  through the `kuma-ctl` image because kuma has no REST write API. The admin
  login the setup wizard creates lives in `config/uptime-kuma/api.env` (UI-first
  like `npm/api.env`), and the reconciler, `deploy.sh` and `verify.sh` self-skip
  until it is filled in. The declaration format and every socket.io payload
  trap (positional events, the `info` handshake, the status-code array) are in
  `scripts/kuma-monitors.sh` and `kuma-ctl/monitors.mjs` — don't reimplement the
  reconcile as curl. Note v2 answers `/` with a **302 to `/dashboard`**, so a
  probe must follow redirects. Notifications stay UI-configured.
- **Every pulled image carries a real tag, and two managers cover them.**
  Renovate's Quadlet manager reads `*.container`/`*.image`/`*.volume` and
  **cannot see `deploy/*.container.in`**; those three templates, and the three
  image defaults that live in shell (`MONERO_IMAGE` in `scripts/wallets.sh`,
  `APPRISE_IMAGE` in `scripts/monitor.sh`, `RESTIC_IMAGE` in `scripts/backup.sh`
  — no manager reads a shell default), are matched by `renovate.json`'s regex
  manager. The wallet tag appears in both `wallets.sh` and
  `monero-wallet-rpc.container.in`, and one PR moves both; it also appears in
  the README's "What runs" table, which is hand-maintained. `postgres` (hand
  pinned) and `localhost/*` are disabled. Units stay **tag**-pinned
  (`pinDigests` off): kuma's `2` and searxng's date tags move on their own, a
  digest pin would turn a reviewable version bump into a PR per upstream
  rebuild, and a regex manager can only *update* a digest, never add one —
  inheriting `docker:pinDigests` failed the whole branch. Every managed tag must
  carry a version (`latest` buys nothing), and docker versioning wants the same
  suffix and component count, so `9-alpine` never becomes `9.1-alpine` and
  searxng's `<date>-<commit>` tags need `versioning: loose`. Digests belong in
  the Containerfiles; the helper images' apk packages stay unpinned to the
  branch for the same reason. The Monero pair is grouped (a wallet older than
  its daemon is unsupported) and the daemons' PRs carry `prBodyNotes` that
  merging changes nothing until `./deploy.sh --only <svc>`.
- **A merged Containerfile digest bump reaches the host on the next
  `./deploy.sh`:** each locally-built image is labelled with the sha256 of the
  Containerfile that built it, and `deploy_explorers`/`ensure_local_image`
  rebuild when the label differs (`scripts/lib.sh`'s `image_is_current`; no
  label counts as stale). `podman image exists` alone would keep the old bits
  forever, and `verify.sh`'s "Local images" section runs the same comparison. A
  failed rebuild is fatal only when the image is *missing* — a stale one warns
  and keeps the bits that work. `tor` is the only long-lived one, so
  `start_infra` calls `refresh_image_unit` to restart it when the image id
  changed; a changed `Image=` otherwise arrives only via
  `restart_changed_units`. The Containerfile is the whole recipe — base digest,
  upstream `ARG` pins, and deliberately no `COPY` out of the build context
  (`kuma-ctl/monitors.mjs` is bind-mounted at run time), which is why the hash is
  the Containerfile's and not the directory's.
- **Backup is a oneshot Quadlet job plus a plain user timer.** `backup.container`
  is `Type=oneshot` with **no `[Install]` and no `RemainAfterExit`** (either would
  stop the timer ever firing); `backup.timer` is not Quadlet (it has no `.timer`
  type), so `install.sh` renders it into `~/.config/systemd/user/` and enables it.
- **Both daemons are full (archival) nodes:** the chains are large (roughly
  800 GB Bitcoin / 250 GB Monero in late 2026) and the data disk must be sized
  for that. `install.sh` seeds `bitcoin.conf` only when it is missing, so an
  existing host keeps its own values until edited.
- **`fulcrum` is the Electrum server, and the one non-NPM LAN surface:**
  `deploy/fulcrum.container.in` runs the official image on `npm-network` and
  publishes raw Electrum `50001`/`50002` straight on the LAN, because NPM only
  proxies HTTP — don't add it to `NPM_HOSTS`, and keep the ports in
  `FIREWALL_PORTS`. It indexes from bitcoind's RPC and follows it through IBD,
  accepting wallets only once its own index catches up. `--db_mem 3072` bounds
  RocksDB and still leaves ~6 GB for the daemons on a 16 GB host; check
  `free -h` before going to RocksDB's default 4096. A rebuild loses the DB's
  undo info (Fulcrum's "presume the DB is consistent"), so the next restart
  cannot undo a block. `$DATA_DIR` is a rotational disk, so a from-scratch index
  runs ~40 blocks/min — slow is not a fault to chase, `--db_mem` is the only
  knob, and 2.1.4 exposes no fast-sync or history cap to shrink the work. Its
  `HealthCmd` is the process check on purpose: an index probe would paint a
  normal first run red.
  The functional check is outside the unit — `scripts/lib.sh`'s `electrum_call`/
  `electrum_call_tls`/`electrum_tip` (bash `/dev/tcp` and `openssl s_client`;
  the host has no `nc`), used by `verify.sh --deep` and `scripts/monitor.sh`.
  Ask it for `blockchain.headers.subscribe`, never just `server.version`: that
  one is answered from memory and passes a wedged index.
- **The two explorers read the daemons; neither adds an index.** `btc-explorer`
  reads bitcoind RPC plus Fulcrum for address history (`txindex=0`, so an old
  txid needs its block height); `xmr-explorer` (MoneroBlock) is **RPC-only**
  against monerod's restricted RPC, with no chain copy and no LMDB reader. Both
  are loopback-published, NPM-fronted with `force-ssl`, mirrored as onions,
  declared in `KUMA_MONITORS`, and built by `deploy.sh` only when missing
  (`--only btc-explorer|xmr-explorer|explorers` forces a rebuild). Neither has
  state in the backup set; `config/btc-explorer/btc-explorer.env` is the BTC
  RPC/Fulcrum wiring. `xmr-explorer` probes its static `/style.css`, not `/`,
  which can time out during monerod's initial sync.
- **The backup set is declared once, as `BACKUP_PATHS` in `stack.conf`**
  (`cln monero-wallet-rpc tor config npm audit uptime-kuma postgres-dump`).
  `install.sh` renders it into `backup.container` (one read-only `Volume=` per
  entry plus the path list in `Exec=`), and `scripts/backup.sh` derives its own
  mounts, restic arguments, restore directories and confirmation prompt from the
  same array, so a hand run and the nightly job copy the same thing. Chains, the
  Fulcrum index, `searxng/`, `monitoring/` and the raw `postgres/` cluster stay
  out so restic never walks them. `tor/` is in it for `tor/onion/` — a lost key
  is a new `.onion` address. `postgres-dump.container` `pg_dumpall`s into
  `$DATA_DIR/postgres-dump`; its libpq settings belong in
  `config/boltmesh/dump.env`, **not** `db.env` (`PGHOST`/`PGUSER` in the server's
  own env break its socket-based entrypoint bootstrap). The unit reaches it
  through `Wants=/After=postgres-dump.service`, but a bare `scripts/backup.sh
  backup` starts that unit itself (best-effort — a Postgres outage must not stop
  the run that protects the wallet). The repo is `$STACK_BACKUP_DIR`, reached
  through `backup.env`; `scripts/backup.sh` reads `RESTIC_*` from **the
  environment first, then the file** — the only order that can recover a fresh
  host.
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
  (`SocksPolicy`) allow it; `tor` is addressed by that IP, not by name
  (`lightningd` runs `--always-use-proxy=true`, which suppresses DNS). The four
  containers that back onion services pin `.241`–`.244` because tor validates a
  `HiddenServicePort` target at startup: a container *name* that does not exist
  yet is an unparseable address and stops tor from starting. Keep the range
  unique; don't drop the subnet.
- **`torrc`'s `HashedControlPassword` must hash to `TOR_SERVICE_PASSWORD`**;
  `install.sh` derives it with `tor --hash-password` on a fresh host and
  otherwise leaves `torrc` alone. tor logs a `ControlPort ... non-local address`
  warning because lightningd drives the statictor service over `10.89.0.240:9051`;
  that is deliberate, the port is password-protected and only on `npm-network`.
- **`tor` is also the onion publisher, and the onion side does not go through NPM
  the way the clearweb side does.** `ONION_SERVICES` in `stack.conf` is the
  declaration; `install.sh` rewrites only the marked region at the end of
  `torrc` so the hash and the `SocksPolicy` are never touched, and `deploy.sh`'s
  `unit_digest` hashes `torrc` so a changed declaration restarts tor. The
  `.onion` address is key material, not config: it comes from
  `$DATA_DIR/tor/onion/<name>/` (mounted `/var/lib/tor/onion`, hence `tor/` in
  the backup set), so never "clean up" that directory and never seed the address
  anywhere. The frontend and API onions forward to their **containers**; the mcp
  one cannot, because the path split is NPM's job and NPM is on the host
  network, so it targets `host.containers.internal`. Tor cannot rewrite `Host`
  and the address is unknown at install time, so NPM gets a **wildcard
  `*.onion`** host (the only host with no certificate — `npm-hosts.sh` skips
  Let's Encrypt for `.onion`, and `force-ssl` must never be added to it). Don't
  "fix" the mcp target to a container name or give the wildcard a cert.
- **Spending stays off:** `install.sh` writes `ENABLE_SPENDING=0` to both money
  servers' `spend.env` (never seed `1`); `scripts/spend-audit.sh` asserts it,
  hash-baselines both `spend.env`, both token files and `node.env` (the spend
  rune), and diffs outgoing `listpays`/`get_transfers` against a baseline.
- **Rotation goes through the same two authorities as install, so it cannot
  drift from it:** `scripts/rotate.sh` writes the source of truth, re-runs
  `deploy/install.sh` to re-render (never a unit by hand), restarts the affected
  units and only then revokes (`destroyrune`, the old RPC password). The three
  seed-once files are why a rotation is not an env edit — `bitcoin.conf` is
  edited inside the container, `torrc` only in its `HashedControlPassword` line
  (the onion block is `install.sh`'s), and `btc-explorer.env`/
  `bitcoin-node-mcp/upstream.env` are rewritten because install.sh never
  refreshes them. The CLN method allowlists live in `stack.conf`
  (`CLN_READ_METHODS`/`CLN_SPEND_METHODS`/`BOLTMESH_RUNE_METHODS`, rendered by
  `rune_json`) precisely so the installer and the rotator mint the same runes.
  New values are journaled under `$DATA_DIR/config/rotation/` before they are
  applied (`--status`/`--resume`, never a second mint), the spend baseline is
  rehashed per file rather than `--rebaseline`d, and `rotation.log` records the
  act without the value. No timer: these tokens have clients outside the stack.
  Phase 1 is the four in-stack credentials (`bitcoin-rpc`, `monero-rpc`,
  `tor-control`, `runes`), plus `token:<server>` (proves the new bearer TOKEN and
  the old one's 401; `--spend` only proves the reload, since the spend token is
  exercised by a spend call), `searxng-secret` and `monero-wallet`
  (`change_wallet_password` at the daemon, `--yes` + a <24h snapshot, and the
  journal records that the daemon call landed so `--resume` never sends it
  twice). **Any daemon-side mutation must be guarded for `--dry-run` inside the
  function that performs it, not only at the call site** -- an unguarded
  `change_wallet_password` during a dry run once changed a live wallet's
  password to a value nothing had recorded, which cost a restore from backup
  and a cache rebuild. `scripts/monitor.sh` alerts on any leftover
  `config/rotation/*.pending` for the same reason.
- **The monitor is a read-only host script, not a container:** `monitor.timer` (a
  plain user unit) schedules `monitor.service`, which runs
  `scripts/monitor.sh --quiet` with an optional
  `EnvironmentFile=-@CONFIG_DIR@/monitoring/monitor.env` — the leading `-` keeps
  an unfilled file from stopping the sweep. The script reads that file through
  `env_value` (environment first, never sourcing it), so a hand run alerts on
  exactly what the timer would. It is alert-only (never restarts a unit) and
  silent until `monitor.env` is filled in; thresholds are `MONITOR_*` keys
  **with defaults in the script**, so an env file written before a check existed
  still monitors. It carries the host checks (disk, inodes, disk saturation,
  backup age, certificate expiry, `NRestarts` deltas, NIC errors/drops, the
  hottest sensor, a stale metrics textfile) and the chain/daemon checks (a
  `verify.sh` sweep, bitcoind freshness/peers/mempool, Fulcrum's tip, CLN
  peers/channels, monerod's lag, the wallet's lag). The Apprise traps
  (`caronc/apprise` has no ENTRYPOINT, so name the CLI; a `mailto://` URL on 587
  needs `?mode=starttls`) live in the script.
- **Metrics are history, not alerting, and the two must not be coupled:**
  `victoriametrics` (loopback `8428`, 30d via `METRICS_RETENTION`) +
  `node-exporter` + `scripts/metrics.sh` on `metrics.timer` every minute.
  `monitor.sh` never queries the store — that is what keeps a wedged or deleted
  VM from silencing an alert — and `vmui` gets **no** NPM host (it has no auth
  of its own), so nothing is added to `FIREWALL_PORTS`. node-exporter runs on
  the **host network** bound to the wildcard: a containered exporter's netdev
  and netstat collectors only ever saw its own `eth0`/`lo`, and pasta delivers a
  container's `host.containers.internal` dial into the host netns but not onto
  host loopback. The numbers are published through its **textfile collector**,
  whose permissions are the trap: the exporter is uid 65534 (a subuid), so both
  writers chmod the directory `0755` and the files `0644` — a silent "graphs
  stopped while everything is healthy" is almost always that.
  `$DATA_DIR/monitoring` is regenerable and outside the backup set, and
  `monitor.prom` carries the sweep's own numbers. The series and the
  observe/decide split are documented in `scripts/metrics.sh`.
- **nginx-proxy-manager runs on the host network, and health comes from podman.**
  `Network=host` with no `PublishPort=`, so NPM's own nginx binds :80/:443/:81 in
  the host's namespace and every request carries the client's real address; a
  rootless published port went through `rootlessport` and showed NPM its own
  container IP. `deploy/nginx-proxy-manager.container` carries the full
  explanation, including why podman 6's `pasta` forwarder would be the other way
  out. The price is that NPM cannot resolve a container name: every unit it
  fronts publishes on the host's **loopback** (`PublishPort=127.0.0.1:<port>:…`),
  which is what `NPM_HOSTS`/`MCP_HOSTS` point at, and only 80/443/81 plus
  Fulcrum's raw ports stay LAN-reachable. Host-side checks still read
  `container:8000` on `npm-network` through `net_curl` (the throwaway
  `localhost/netcheck:local` image), with `net_curl_host` for NPM's own admin API
  on `127.0.0.1:81`. The units set `HealthCmd=`/`HealthInterval=`, so podman
  really does report `(healthy)` and `deploy.sh` waits with `wait_healthy`; the
  MCP probe is an authenticated `initialize`, strictly stronger than a `/health`
  GET.
- **The bearer tokens never reach the host's argv** — `mcp_initialize` /
  `mcp_tool_call` pass them in a curl config on stdin (`-K -`), so `ps` cannot
  read a token out of a running verify/monitor/audit sweep. `npm-hosts.sh`
  does the same with the NPM admin password and the API token it mints.
- **Every proxy host is declared, not hand-clicked:** `NPM_HOSTS` in `stack.conf`
  is the whole public surface, and `scripts/npm-hosts.sh` reconciles it through
  NPM's admin API on `127.0.0.1:81` (update in place by `domain_names`, else
  create, plus a Let's Encrypt certificate per host). It needs the admin login in
  `config/npm/api.env` and `jq` on the host (bootstrap), and self-skips when the
  login is absent. `--prune` is the only destructive mode. The `mcp` flag is the
  one exception to "one forward": one location per `MCP_HOSTS` entry
  (`/prefix:container:port`), each rewritten onto the container's `/mcp`, with
  the streaming settings an SSE transport needs — the script's header owns that
  payload. `verify.sh` re-checks the path through NPM's `:80` (following the
  force-SSL redirect) with `--connect-to` onto `127.0.0.1`, so the certificate
  still validates. Proxying a daemon's own API (`clnrest`, `xmr-rpc`) is gated
  only by that daemon's RPC credentials, not by an MCP token.

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
