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
./deploy.sh --only backup-verify    # run the restore drill now (weekly on a timer)
./deploy.sh --only monitor          # run the health + spend checks now
./deploy.sh --only victoria-logs    # after a LOGS_* change or an image bump
./deploy.sh --only vector           # after deploy/logs/vector.toml changes
./scripts/logs.sh --since 1h        # cross-service log search (LogsQL; UI on :9428)
./deploy.sh --only npm-hosts        # (re)reconcile every proxy host in nginx-proxy-manager
./deploy.sh --only agent-skills     # re-link the skills + agent-mcp into the harnesses
./deploy.sh --only tor              # re-render the onion services into torrc and restart tor
./deploy.sh --only crowdsec         # re-render its parser/scenarios and restart the engine
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
  the order is load-bearing). **Running `deploy/install.sh` by hand consumes
  that signal**: it rewrites the rendered files, so the next `deploy.sh`
  digests the already-new files either side of its own `install.sh`, finds no
  change and restarts nothing — the unit edit then sits unapplied while every
  health check reports `(healthy)`. After a hand render, restart the affected
  units yourself (`systemctl --user restart <unit>`); this is also why
  `install.sh` alone is not a deploy. Every `--only` branch goes through
  `sync_units` (the same digest pair) for exactly this reason — an `--only` run
  must not consume the signal for the units it was not asked about. The one
  exception is `nginx-proxy-manager`, which `--only` only warns about: its
  restart belongs after the host rewrite, so `--only npm-hosts` rewrites and
  then calls `sync_npm_network`, and every other branch tells the operator to
  finish with a full deploy. Two ordering facts inside `sync_units`:
  **`ensure_netcheck` is its last step, not part of the `--only` prologue**,
  because `install.sh` rebuilds the `netcheck` image in `install_units` and a
  refresh before that compared the container with the old image and did nothing
  (the new client reached the containers one deploy later); and an app branch
  sets `DEFER_UNITS` so `restart_changed_units` leaves that unit alone —
  `deploy_app` restarts it after the build, and restarting it twice is two
  outages for one edit.
- **`<unit>.bak` is the *previous* render, and only when the render changes
  something.** It used to be written only if it did not already exist, so it
  was frozen at the host's first install while README's Rollback section
  presents it as the rollback path. The fix cannot be "always overwrite it":
  `deploy.sh` runs `install.sh` twice per deploy (the CLN runes need a running
  node), so the second run would back up the file the first run just wrote and
  destroy the rollback. Hence the `cmp`: back up the old bytes only when the new
  ones differ, always as one generation, always mode 600 (`cp -p` — several
  rendered units carry `@PLACEHOLDER@` secrets).
- **A container unit mounts only from `$DATA_DIR` (or a podman volume), never
  from the checkout.** The host scripts in `deploy/*.service` do run from the
  checkout — they *are* the tooling — but a container that a daemon starts is
  different: `monerod`'s `--block-notify` helper and the BTCPay bootstrap script
  were the last two exceptions, and moving or deleting the repo broke them at
  their *next* start, with podman naming a missing bind source nobody had
  edited. `install.sh` stages both into `$DATA_DIR/bin` on every run (small,
  secret-free, regenerable, so not in `BACKUP_PATHS`); edit the repo copy and
  deploy. CI fails if any `deploy/*.container*` mentions `@REPO_DIR@`, which is
  what keeps the next one from creeping back.
- **CLN runes are verified, not trusted:** `createrune` can return a rune whose
  `unique_id` the node blacklisted, so `install.sh` proves each with `checkrune`
  and retries on a fresh id.
- **The BTCPay Monero wallet is view-only and optional at first.** `deploy.sh`
  starts `monero-wallet-btcpay` (no wallet file yet), then
  `scripts/btcpay-wallet.sh` imports it only when
  `config/btcpay/xmr-wallet.env` has an address and view key. The bootstrap
  leaves XMR-CHAIN disabled while the wallet RPC has no wallet open.
- **lightningd dies with its container left "Up":** bcli can time out while
  bitcoind is still loading its wallet, the entrypoint then keeps PID 1 alive,
  the unit reads "active" and `Restart=always` never fires -- which is how
  lightning-mcp answers 502 while the unit looks fine. The unit therefore
  carries `HealthOnFailure=kill` (podman's own advice: inside a unit prefer
  kill/stop so systemd's restart policy is the one that acts), so the failing
  healthcheck ends the container and `Restart=always` recreates it. `deploy.sh`
  still restarts a still-active but `unhealthy` lightningd, as the fallback for
  a container older than that unit line, waits for wallet-level RPC before
  waiting on lightningd, and dumps the log on any timeout. That wait is
  `bitcoind_wallet_ready` (`listwallets` non-empty), **never a bare
  `getwalletinfo`**: a node with two wallets loaded -- a legacy datadir-root
  `mainnet` plus an unnamed `""` -- answers `-19` "Wallet file not specified",
  which says nothing about readiness, so the wait burned its full 120 s on every
  deploy and then skipped the lightningd wait. The same class of trap in
  `scripts/wallets.sh`: `loadwallet` answering `-35` means the wallet is already
  loaded, i.e. success, and reporting it as failure is how a healthy node came
  to look unconfigured (a transient `podman exec` miss is why the first check
  can disagree with the second, so each load attempt re-proves it with
  `listwallets`). Not on
  `monero-wallet-btcpay`: its healthcheck is red for as long as the wallet
  refreshes, so killing it would restart the refresh from scratch.
- **Healthchecks follow a contract, and `HealthOnFailure=restart` hides a
  restart from the monitor.** Every container unit that is not `Type=oneshot`
  defines a probe with all five keys explicit (`HealthCmd`, `HealthInterval`,
  `HealthStartPeriod`, `HealthRetries`, `HealthTimeout`). The units that cannot
  are declared once, with a reason, in `stack.conf`'s `HEALTHLESS_UNITS`
  (`victoria-logs` is distroless — podman runs a string health command through
  the container's `/bin/sh` — and the two netcheck clients only sleep), which
  `verify.sh` reads instead of keeping its own copy. `scripts/healthcheck-lint.sh`
  is the gate: interval is 30 s (HTTP) or 60 s (daemons), retries 3 or 5 with a
  reason, timeout explicit and 5–20 s, an HTTP probe fails on non-2xx, discards
  the body and bounds itself, and a rule is waived only by an inline
  `# health-lint: <code> <reason>` comment, printed on every run so exemptions
  stay visible. Three decisions carry the reasoning:
  **`HealthOnFailure=kill`, never `restart`** — podman's own restart leaves the
  unit active, so `NRestarts` does not move and `monitor.sh`'s restart delta
  cannot see a container flapping every 30 s; systemd's `Restart=always` is the
  process that should act. The two exceptions are `monero-wallet-btcpay` (red for a
  whole refresh) and `boltmesh-backend`, whose health is **deep** (postgres +
  valkey): a database blip must not restart-loop the app tier, and `verify.sh`
  pages on the same endpoint. **`HealthCmd` proves the process/serving path, not
  the data path** — a check that is legitimately red while recovering (IBD,
  monerod sync, wallet refresh, Fulcrum's first index) belongs in `monitor.sh`,
  never in a unit; that is why `fulcrum`'s and `monerod`'s probes are the
  process table and `tor`'s is a port, and replacing any of them with a data
  probe is a regression, not a fix. `monerod` is the worked example: its
  restricted-RPC handler blocks for 60 s or more while the chain lock is held
  across a `--block-sync-size` batch, so the image's own `/healthcheck.sh` (an
  unbounded curl of `/get_height`) went stall → stall → stall → a killed full
  node roughly once an hour, mid-sync (6 `unhealthy` transitions and 8
  container instances in six hours here). A socket check does not fix it
  either: after such a kill the daemon refuses connections until LMDB reopens
  (134 s measured, 0.5 s after a clean stop), which puts the same kill switch
  on a different trigger with only `StartPeriod` in the way. So `monitor.sh`
  owns "alive but not answering" — a warning under `MONITOR_GRACE_SYNC`, a
  failure without it — and `metrics.sh`'s `stack_xmr_rpc_up` is the history.
  And **`wait_healthy` raises a caller's timeout to the unit's
  `StartPeriod + Interval`**: podman runs no check during the start period, so a
  shorter wait reports "not healthy" about a service that never had a chance to
  answer. A **one-shot unit (`Type=oneshot`) is the other way a wait lies**:
  the job *exits* instead of reporting `(healthy)` and never appears in
  `podman ps`, so `wait_healthy` reads its terminal state instead
  (`exited 0` = done) — before that, `./deploy.sh --only postgres-dump` spun
  its whole 180 s and warned "container missing" about a job that had
  succeeded. The eight MCP servers' `healthcheck.py` (authenticated `initialize`,
  SSE `data:` unwrap, 5 s bound) is the model for an app-side probe.
- **CLN peers and channels come from `listpeerchannels`/`listpeers`, never
  `listchannels` or `getinfo`'s `num_peers`:** the gossmap's `active` is an
  operator setting that stays true while a peer is offline, and `num_peers`
  counts peers with channels whether or not they are connected.
  `scripts/monitor.sh` carries the shapes and the counting rule;
  `scripts/metrics.sh` emits `stack_cln_peers`/`stack_cln_channels_offline`.
  `lightning-cli` through `podman exec` is not gated by the clnrest rune — the
  MCP needs the method added to `READ_METHODS` in `deploy/install.sh`.
- **Data-dir ownership:** `bitcoind` runs as the image uid
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
  **cannot see `deploy/*.container.in`**; those three templates, and the one
  image default that lives in shell (`RESTIC_IMAGE`, which both
  `scripts/backup.sh` and `scripts/rotate.sh` define — no manager reads a shell
  default), are matched by `renovate.json`'s regex manager. Both files are
  matched so a restic bump moves them together. The wallet tag appears in
  the `btcpayserver/monero` unit, and one PR moves both; it also appears in
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
- **The BTCPay Monero plugin is a file, so nothing else notices a bump.**
  `install.sh` writes `.artifact-sha256` into the plugin directory and skips the
  download only while that marker still matches `BTCPAY_PLUGIN_SHA256`; the
  extraction goes into a staging sibling and is swapped in whole, so a new
  version never inherits the old one's leftover files and a failed download or
  extract leaves the working plugin alone. But a unit digest cannot see a file in
  `$DATA_DIR`, `start` is a no-op on an active container, and `--only btcpay`
  never runs `unit_digest` at all — so `start_btcpay` calls
  `btcpay_plugin_newer` (the DLL's mtime against podman's `StartedAt`, i.e.
  `refresh_image_unit` answered for a file) and restarts before its single health
  wait. BTCPay loads plugin assemblies at start and keeps the mapped copy, which
  is why the restart is required, not tidy: `btcpay-bootstrap` enables XMR-CHAIN
  through BTCPay's API and needs the new assembly loaded.
- **Backup is a oneshot Quadlet job plus a plain user timer.** `backup.container`
  is `Type=oneshot` with **no `[Install]` and no `RemainAfterExit`** (either would
  stop the timer ever firing); `backup.timer` is not Quadlet (it has no `.timer`
  type), so `install.sh` renders it into `~/.config/systemd/user/` and enables it.
- **The backup is drilled weekly, and the drill's verdict is a file, not an exit
  code.** `deploy/backup-verify.timer` (Sunday 05:30, two hours clear of the
  nightly job) runs `scripts/backup.sh verify`: `restic check
  --read-data-subset=n/4` with a rotating counter, a `restore --target /restore`
  into `$DATA_DIR/backup-verify` (the live data dirs are **not** mounted, which is
  what makes it safe on a serving host), and assertions that every `BACKUP_PATHS`
  entry came back non-empty plus the `BACKUP_VERIFY_PATHS` markers and the dump's
  `pg_dumpall` completion trailer. It writes
  `$DATA_DIR/audit/backup-verify.status`, and **that file is what
  `scripts/monitor.sh` reads** — a failed oneshot unit is otherwise just a line
  in `systemctl --user status`. The age check keys on `ok_epoch` (the last
  success), so a drill that skips forever (over `BACKUP_VERIFY_MAX_MB`, or
  without 1.5× the restore size free) fails instead of looking healthy. The
  scratch tree is `trap`-removed on every exit path and must stay out of
  `BACKUP_PATHS`; `--with-db` replays the dump into a throwaway postgres and is
  manual on purpose, because the weekly run must not depend on pulling an image.
  The drill proves restore *mechanics* only: not that an offsite repo is
  reachable, and not that the wallet or the daemons come up on the restored
  state. **The one restic error a restore tolerates is an unapplied SELinux
  label** — rootless podman cannot set `security.selinux`, so both `restore`
  calls pass `--exclude-xattr security.selinux` (the file keeps the label it
  already has, which is what the failed `setxattr` left anyway) and
  `restore_acceptable` is only the net for that class. It must count those
  errors, never pin them: which files mismatch depends on what a host script
  rewrote since the snapshot (`unconfined_u` vs `system_u`), so the rule was
  written against one error and the 2026-11-01 drill produced two — `/data` and
  `/data/audit/ids.status` — and failing on that marked a good restore
  `result=fail`, which `monitor.sh` then paged on. Do not anchor the pattern to
  `/data` either: a subfolder restore reports `/restore/<file>`. In the in-place
  path this matters more than noise, since the `die` would fire before the
  `chown` that makes bitcoind's datadir readable.
- **Restore before deploy, replay the dump after, migrate last.** The order is
  load-bearing, not stylistic: `install.sh` seeds `bitcoin.conf` and `torrc` once
  and never overwrites them, so a `./deploy.sh` that runs first writes a *fresh*
  RPC password into `bitcoin.conf` and the restored `config/stack/secrets.env`
  then disagrees with the daemon. Restoring first makes every seed-once file come
  from the snapshot, which is also why `scripts/backup.sh` reads
  `RESTIC_REPOSITORY`/`RESTIC_PASSWORD` from the environment first. The database
  comes back as a file (`postgres-dump/all.sql`): replay it into the empty
  cluster the deploy started, then `./deploy.sh --only boltmesh` to
  `alembic upgrade head` — the dump is as old as the snapshot, the code is not.
  The operator steps, the per-scenario runbooks and the post-recovery checklist
  are README's "Disaster recovery"; `scripts/backup.sh restore` writes the whole
  set in place, and a single-path restore is a raw restic invocation documented
  there.
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
  reads bitcoind RPC plus Fulcrum for address history; bitcoind runs
  `txindex=1`, so any historical txid resolves without a block height (the
  index is bitcoind's, built in the background from `blk*.dat`); `xmr-explorer`
  (MoneroBlock) is **RPC-only**
  against monerod's restricted RPC, with no chain copy and no LMDB reader. Both
  are loopback-published, NPM-fronted with `force-ssl`, mirrored as onions,
  declared in `KUMA_MONITORS`, and built by `deploy.sh` only when missing
  (`--only btc-explorer|xmr-explorer|explorers` forces a rebuild). Neither has
  state in the backup set; `config/btc-explorer/btc-explorer.env` is the BTC
  RPC/Fulcrum wiring. `xmr-explorer` probes its static `/style.css`, not `/`,
  which can time out during monerod's initial sync.
- **The backup set is declared once, as `BACKUP_PATHS` in `stack.conf`**
  (`cln btcpay tor config npm audit uptime-kuma postgres-dump`).
  `install.sh` renders it into `backup.container` (one read-only `Volume=` per
  entry plus the path list in `Exec=`), and `scripts/backup.sh` derives its own
  mounts, restic arguments, restore directories and confirmation prompt from the
  same array, so a hand run and the nightly job copy the same thing. Chains, the
  Fulcrum index, `searxng/`, `monitoring/`, `logs/` and the raw `postgres/`
  cluster stay out so restic never walks them. `tor/` is in it for `tor/onion/` — a lost key
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
  into the bundle, so a hostname change is a rebuild). **BoltMesh holds no CLN
  rune:** BTCPay is its settlement engine and reaches CLN itself over the unix
  socket (`BTCPAY_BTCLIGHTNING`), so the only runes are `lightning-mcp`'s
  read/spend pair -- `stack.conf` says why there is no boltmesh rune to mint.
- **Shared bind mounts use `:z`, not `:Z`** — the backup container mounts `cln/`
  and `npm/` read-only alongside `lightningd` and NPM, and two containers cannot
  share a path one labels private.
- **`sudo` lives only in `bootstrap.sh`.** `deploy.sh`, `install.sh`, `verify.sh`
  and the `scripts/` helpers never call it; an unprepared data dir is an error
  carrying the one-time commands, not a prompt. The one thing bootstrap uses it
  for beyond provisioning is the **root tier** (`deploy/install.sh --root`): the
  Suricata sensor, which cannot be rootless because AF_PACKET needs
  `CAP_NET_RAW` in the init user namespace. That is why bootstrap is a
  **two-pass** install -- the sensor's unit and config reference `@DATA_DIR@`,
  so the first run (before any data dir exists) only prints a notice and the
  rerun after the first `./deploy.sh` installs it. Everything it installs is
  root-owned: the unit in `/etc/containers/systemd/`, the config in
  `/etc/stack-ids/`, the tmpfiles rule in `/etc/tmpfiles.d/`. That unit is mode
  0644 (not the 0600 the user units get) because `verify.sh` diffs it against
  `deploy/root/` to catch drift and it carries no secret -- the secret-bearing
  templates are the *user* units. Nothing
  root-owned is *read* from `$DATA_DIR` -- the sensor only writes its logs there
  (root-owned, 0644, so the unprivileged `scripts/ids.sh` can read them), and a
  user-writable config consumed by a root container would be a privilege
  boundary. A change to `deploy/root/` therefore needs `sudo ./bootstrap.sh`
  again; `verify.sh` walks a declared table (`ROOT_FILES`) of every file
  `install.sh --root` renders and warns per file when one has drifted or is
  missing. Content only -- bootstrap owns the modes -- and three kinds are
  excluded on purpose: the 0600 env files and the tmpfiles rule (written from
  heredocs, no repo counterpart) and `60-stack.rules` (0640 in a 0750 directory,
  unreadable to an unprivileged sweep; the audit section reads the report's
  verdict instead). The bouncer's three are marked `opt`, absent until the
  second bootstrap pass has a key, so they are skipped rather than warned about
  on a host that has not got one yet.
- **Intrusion detection is two engines and two privilege domains:**
  `suricata` (rootful, `deploy/root/`, enp8s0 + lo) sees packets and no TLS
  content; `crowdsec` (rootless) sees NPM's access log and nothing on the wire.
  Neither is redundant: NPM terminates TLS, so the request exists only in its
  log, and the onion traffic exists only on the wire as ciphertext. Silencing
  either one loses a distinct half. `DISABLE_ONLINE_API=true` is deliberate
  ("local detection only": no console, no CAPI blocklist, no telemetry).
  **Enforcement is `stack-bouncer`** (`deploy/root/bouncer.sh`, a root oneshot on
  a one-minute system timer): crowdsec runs on the host network, so it polls the
  LAPI on `127.0.0.1:8080` directly — no published port, because rootless
  podman's bridge is not routable from the host and its `rootlessport` forwarder
  is owned by no unit (one vanished on 2026-11-02 and left enforcement off for
  7h39m with the container still green) — with `CROWDSEC_BOUNCER_KEY`, and
  writes the `inet stack_bans` set, each element
  carrying the decision's own duration as an nft timeout. There is no upstream
  bouncer image any more (`crowdsecurity/cs-firewall-bouncer` answers *access
  denied*), which is why the applier is ours: CrowdSec keeps the decision
  lifecycle, we own the plumbing.
  Four traps, all found by running it: (1) the LAPI answers **`null`**, not
  `[]`, when nothing is banned -- a strict array check reads that as a protocol
  error and blocks enforcement; (2) `nft -f` **merges** a table declaration
  rather than recreating it, so re-declaring the chain each run appends a
  duplicate drop rule every minute -- create the table only when missing, then
  `flush set` and re-add; (3) `CROWDSEC_BOUNCER_KEY` must **never** be
  regenerated (the container registers that exact key at start; a new one leaves
  a stale bouncer and a LAPI answering 403, i.e. silent non-enforcement), and it
  is the one secret appended to `secrets.env` rather than written by its heredoc,
  because it has to exist on hosts deployed before it; (4) the script refuses
  private space **and every address the host holds** -- `192.168.1.112` is what
  onion traffic and Uptime-Kuma look like, so banning it takes the onion
  services, the status page and the operator's own SSH session down together.
  Failure directions are chosen: an unreachable LAPI leaves existing bans alone
  (never read "no decisions" as "unban all"), and a failed `nft -f` rolls back
  atomically. `scripts/monitor.sh` fails on a stale `audit/bouncer.status`, which
  is the only signal that detection is healthy while nothing enforces.
  `scripts/ids.sh` rolls the engines up into `$DATA_DIR/audit/ids.status` (the
  `backup-verify.status` pattern) rather than letting the monitor reach into a
  rootful unit and a `podman exec`; a stale status is the failure signal.
  Two more traps: NPM writes a **custom log_format**, not `combined`, so the
  stock nginx parser matches nothing --
  `deploy/crowdsec/parsers/s01-parse/stack-npm.yaml` owns both shapes and
  `verify.sh` replays a sample line through `cscli explain` on every sweep,
  because a silent log-format change turns detection off; and the whitelist in
  `s02-enrich/` protects the host's **own** address, which is what onion traffic
  and Uptime-Kuma's self-checks look like in the log. A whitelist expression is a
  **plain string prefix, not a network**: `startsWith '172.2'` covered
  172.2.0.0/16 and 172.200.0.0/14 as well as the intended 172.20.0.0/14, so
  ~4.4M public addresses were reported as `whitelisted` -- and because the
  whitelist runs in `s02-enrich`, *before* the scenarios, a whitelisted event
  never becomes a decision and `cscli decisions list --all` cannot show it
  (`cscli metrics`' whitelisted count is the only trace, so an over-broad entry
  looks exactly like a quiet internet). The /12 is an `IpInRange` now, and
  `verify.sh` asserts both directions with `cscli explain`: a public
  `172.220.10.5` must **not** be whitelisted, `172.18.0.5` must be, and a
  Uptime-Kuma user agent must be -- that last one is the only probe the stock
  `crowdsecurity/whitelists` cannot answer for us, so it is what proves this file
  is loaded at all.
- **Rate limiting is per ingress, and the onion case is the awkward one:**
  every `.onion` visitor reaches NPM as the host's own address (tor forwards to
  `host.containers.internal`), so the onion zone is keyed on `$server_name` and is
  a *global* brake (60 r/s, burst 120) -- there is no such thing as a per-client
  limit there. Clearweb hosts use `$binary_remote_addr`. The MCP host gets
  `limit_conn` only and never `limit_req`: JSON-RPC bursts are legitimate and
  `GET /mcp` is an SSE stream, so a request-rate limit either does nothing or
  cuts healthy clients. Zones live in `deploy/npm/http.conf` ->
  `$DATA_DIR/npm/data/nginx/custom/http.conf`, the one NPM directory that is never
  regenerated; the directives are per host in `advanced_config`. A new file in
  that directory is created with the *default* SELinux label even though the tree
  is mounted `:z`, and nginx then refuses to load it -- `install.sh` chcons it,
  because a deploy does not necessarily restart NPM.
- **The audit tier watches files only, because directory watches do nothing on
  this kernel.** Measured: `-w /etc/sudoers.d/ -p wa` (and the
  `-a always,exit -F dir=… -F perm=wa` form) records nothing for a file created
  inside it, while the same watch on a file fires. Entry creation -- a new unit
  file, a sudoers drop-in, a cron job -- is covered instead by the hash diff in
  `deploy/root/audit-report.sh` over `/etc/systemd/system`,
  `/etc/containers/systemd`, `/etc/sudoers.d`, `/etc/cron.d` and
  `/etc/ssh/sshd_config.d`, which also names the file. Keys split the verdict:
  `stack_hard` (account databases, sudoers, sshd, audit's own config -- nothing
  in this repo writes them) fails the sweep, `stack_data` (the stack's secrets,
  which rotation and deploys do write) only reports. Two EL10 details:
  `auditctl`/`augenrules` are the separate **`audit-rules`** package, so a host
  can run auditd with no way to add a rule; and **never run `auditctl -D`** --
  doing it once on this host left the kernel accepting rules while emitting no
  events at all, not even the next rule's CONFIG_CHANGE, until a reboot. Remove
  our rules one at a time (`auditctl -W <rule>`), anything else is left alone.
  `augenrules` exits non-zero on "Rule exists" even when the ruleset is already
  right, so `install.sh` judges the result by `auditctl -l`, not the exit code.
  **Whether the kernel audit subsystem records anything is a measurement, not an
  assumption.** This host once initialized disabled (`audit_enabled=0` in dmesg,
  journald "Collecting audit messages is disabled") while `auditctl -s` still
  reported `enabled 1` and no kernel record was ever written, not even the
  CONFIG_CHANGE for loading the rules; it survived a reboot. The report marks
  itself `audit=inert` in that state (watches loaded in `auditctl -l`, no
  `CONFIG_CHANGE` from `ausearch`) and the sweep says so, so nobody reads "no
  host-level changes" as coverage. The hash diff over the persistence
  directories is the half that works regardless. **Re-measured 2026-11-01 it is
  live** — `enabled 1`, the nine watches loaded, records being written — which
  surfaced three things worth keeping: (1) `aureport`/`ausearch` take the window
  as **two** arguments, a date and a time; passing one string like
  `--start "11/01/2026 17:38:06"` is refused with "Hour, Minute, and Second are
  required", and the `2>/dev/null || true` around both calls is why every count
  came back empty and the sweep reported "no host-level changes" from a read that
  never happened — `read=ok|failed` in the status file is the guard against that
  recurring. (2) The summary is read with `--no-config`, because loading the rule
  set makes the kernel emit a keyed CONFIG_CHANGE per rule added (three per
  reload from `auditctl -R`), and counting those pages on every deploy; a rule
  *removed* (`op=del_rule`) is counted instead, since that is how somebody blinds
  the host. (3) Volume is whatever rules are actually in the kernel, not what is
  in `rules.d`: this host carries a runtime-only `-a always,exit -F arch=b64 -S
  execve -F key=ALLEXEC` that no file in `/etc/audit/` mentions (`auditctl -l` is
  the only place to see it), so every exec on the host is logged — ~16/s here,
  which rotates `/var/log/audit` every ~5 minutes. The repo's own nine watches
  produce a handful of events at steady state. The report advances its
  `auditd.cursor` only when `aureport` exits 0 (`read=ok|failed` in the status
  file, reported by the sweep as a soft line), so a failed read re-examines the
  same window instead of stepping over it. A missing (or empty)
  `/var/log/audit/audit.log` is not a failed read — `aureport` exits 1 when there
  is no log at all, which is what an inert subsystem looks like, so that case
  still advances and the window stays bounded.
- **A Quadlet unit without `[Install]` never starts at boot.** `crowdsec` was
  written without it, so after the first reboot it was simply absent, and the
  only visible symptom was `stack-bouncer` failing every minute with "LAPI
  unreachable" -- the applier failing loudly is what made it findable. Every
  other container in `deploy/` has `[Install] WantedBy=default.target`; the
  generator creates the `.wants` symlink from it, so `systemctl enable` is neither
  needed nor possible ("transient or generated").
  `podman exec crowdsec cscli …` is how decisions are read (no credentials on the
  host), and `Network=none` was rejected because the agent installs hub parsers
  on first boot. Suricata costs ~650 MB with the full ET
  Open ruleset, which `start.sh` refreshes best-effort at container start and
  falls back from to the twelve local rules. Three tuning facts learned by running
  it here: (1) `tpacket-v3` on `lo` needs a block size **above the loopback MTU**
  (128 KB, not the 32 KB default) -- with the default the ring mmap fails with
  "Invalid argument", and the copy-mode fallback it forced made the worker spin at
  **98% of a core on an interface carrying 30 packets/s**, which read as normal
  load until `ps -L` showed one thread hot and the other two idle; (2) the ET TOR
  family must be disabled through `disable.conf`'s `re:` filter --
  `suricata-update`'s `group:` matching does not resolve ET's rule-file groups,
  and this host's own tor client otherwise buries the inbound reputation alerts;
  (3) ring sizes are per interface and mmapped at start: 4096 blocks x 32 KB for
  the LAN NIC is 128 MB per thread, and the 32768 I copied from a tuning example
  bought nothing while making VIRT read 1.3 GB.
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
  units and only then revokes (the superseded runes, the superseded restic key). The three
  seed-once files are why a rotation is not an env edit — `bitcoin.conf` is
  edited inside the container, `torrc` only in its `HashedControlPassword` line
  (the onion block is `install.sh`'s), and `btc-explorer.env`/
  `bitcoin-node-mcp/upstream.env` are rewritten because install.sh never
  refreshes them. The CLN method allowlists live in `stack.conf`
  (`CLN_READ_METHODS`/`CLN_SPEND_METHODS`, rendered by
  `rune_json`) precisely so the installer and the rotator mint the same runes.
  **Nothing is journaled and there is no `--resume`: a half-applied rotation is
  finished by re-running the same target**, which is why every target either
  rewrites every copy of its credential or reconciles a declared end state
  against the authority that holds it. `runes` blacklists every live rune whose
  method set is *exactly* one of `stack.conf`'s except the pair in
  `lightning-mcp/node.env` (`cln_orphan_runes` in `scripts/lib.sh`, shared with
  `scripts/monitor.sh` so the pruner and the alarm agree) — a set comparison,
  because a rune has no label and a remembered id missed five live leftovers,
  two of them spend-capable, on this host. `restic` writes
  `RESTIC_PASSWORD_NEXT` into `backup.env` *before* `key add`, promotes it, then
  removes the superseded keys, so no crash leaves the repository openable only
  by a password nobody holds; the spend baseline is rehashed per file rather
  than `--rebaseline`d, and `rotation.log` records the act without the value. A
  re-run also skips a restart when the container's own PID 1 already carries the
  value (`container_runs_secret` for argv, `container_env_is` for an
  `EnvironmentFile=`), which is the only restart-avoidance there is: anything a
  daemon reads out of a config file, or consumed at `initdb`, restarts. No
  timer: these tokens have clients outside the stack.
  The in-stack credentials are `bitcoin-rpc`, `tor-control` and `runes`, plus
  `token:<server>` (proves the new bearer TOKEN answers a real tool call; the
  old one cannot, a server holding one token, and it is not on the host any more
  to test -- `--spend` only proves the reload, since the spend token is exercised
  by a spend call)
  and `searxng-secret`. There is **no `monero-wallet` target** any more: BTCPay's
  wallet is imported view-only (address + view key only), opens with an empty
  password and runs with `--disable-rpc-login`, so the file holds nothing to
  rotate -- `--list` is the authority on the set.
  **Any daemon-side mutation must be guarded for `--dry-run` inside the
  function that performs it, not only at the call site** -- the rule outlives
  the target that taught it: an unguarded `change_wallet_password` during a dry
  run, back when `monero-wallet` was a target, changed a live wallet's password
  to a value nothing had recorded, which cost a restore from backup and a cache
  rebuild. What replaces a journal as the alarm is the invariant, not a file:
  `scripts/monitor.sh` fails on a live stack rune the pair does not reference and
  on bitcoind's `rpcpassword` disagreeing with `secrets.env`, and only mentions a
  stale `config/rotation/*.pending` (inert, from the version that had them).
  The rest (`postgres`, `boltmesh-keys`, `restic`) follow the same rule: change
  the daemon/authority first (ALTER ROLE, key add), keep the client copy in its
  env file, and prove the new value end to end. Two traps worth remembering:
  the postgres image's `pg_hba.conf` trusts `127.0.0.1`, so a password check over
  loopback succeeds with anything and says nothing (use the podman-network
  address, as `pg_tcp_login` does), and `restic` must make the new password
  durable (the `RESTIC_PASSWORD_NEXT` line), add, prove, promote, then remove —
  never remove first, and never let the durable copy lag the repository.
- **The monitor is a read-only host script, not a container:** `monitor.timer` (a
  plain user unit) schedules `monitor.service`, which runs
  `scripts/monitor.sh --quiet` with an optional
  `EnvironmentFile=-@CONFIG_DIR@/monitoring/monitor.env` — the leading `-` keeps
  an unfilled file from stopping the sweep. The script reads that file through
  `env_value` (environment first, never sourcing it), so a hand run alerts on
  exactly what the timer would. It is alert-only (never restarts a unit).
  Thresholds are `MONITOR_*` keys **with defaults in the script**, so an env
  file written before a check existed still monitors. The file itself is
  `deploy/examples/monitoring/monitor.env.example` **copied verbatim** by
  `install.sh` (the alertmanager config's pattern), because the two used to be
  hand-kept and drifted: the seeded copy was missing keys the example documented
  and `monitor.sh` read five keys no file mentioned. `ci.yml` therefore fails
  when `monitor.sh` resolves a `MONITOR_*` key the example does not declare —
  that check is the only thing keeping a new threshold discoverable. It carries
  the host checks (disk, inodes, disk saturation,
  backup age, certificate expiry, `NRestarts` deltas, NIC errors/drops, the
  hottest sensor, a stale metrics textfile) and the chain/daemon checks (a
  `verify.sh` sweep, bitcoind freshness/peers/mempool, Fulcrum's tip, CLN
  peers/channels, monerod's lag, the wallet's lag).
- **Alerting is two processes because they fail differently: the monitor finds
  faults, Alertmanager decides when to speak.** `scripts/monitor.sh` groups
  every finding under its `head3` section, pushes one alert per section to
  `alertmanager` (`POST /api/v2/alerts`, loopback `9093`) and resolves a section
  explicitly with an `endsAt` in the past when it clears. Alertmanager owns
  grouping, `repeat_interval`, inhibition, silences and delivery. Four traps
  found by running it, all load-bearing:
  (1) **`resolve_timeout` must be far longer than the sweep.** A pushed alert
  carries no `endsAt`, so Alertmanager resolves it once it has not been updated
  for `resolve_timeout` — the default 5m is exactly the timer interval, and
  `0` does not disable it (the API sets `EndsAt = now + resolveTimeout`, so `0`
  resolves instantly). It is **24h** here, and explicit `endsAt` is what
  actually ends an alert, which also keeps a dead monitor from mailing
  "recovered".
  (2) **`email_configs` defaults `send_resolved: false`**, so recoveries are
  silent unless it is set. The seeded example sets it.
  (3) **The flap damper cannot live in Alertmanager.** It only sees what is
  pushed at it, so it cannot tell a check that fails every other sweep from one
  that has been down for an hour. The producer holds that state
  (`$DATA_DIR/audit/alerts.state`: name, service, severity, first seen, last
  pushed) and pushes nothing until `MONITOR_ALERT_FOR` (600s) has passed. The
  `alerting` section bypasses it, because a broken alert path is never a flap.
  (4) **A delivery failure cannot report itself.** `alertmanager_notifications_failed_total`
  is read back on the next sweep and turned into a failure; the heartbeat is
  pushed *after* the alert push and fails when the push failed, so "all checks
  pass but you cannot be told" is a page rather than a silent host.
  (5) **The alert path is the host's own `curl` (and `jq`), not
  `net_curl`.** Alertmanager is a `127.0.0.1` bind and the heartbeat an
  outbound POST, so making them from a container would put the host's only
  paging path behind the thing that is most likely to be broken — which is
  exactly what an unmounted host `curl` was: the package was only in the
  bundle that runs when podman is *missing*, so a host provisioned earlier
  could pass every check and deliver nothing. `bootstrap.sh` now checks `curl`
  and `openssl` individually, `verify.sh`'s "Host tools" section names a gap,
  and `scripts/monitor.sh` refuses to run without `curl`/`jq` (one journal
  line, `alerts.state` untouched) rather than burn the sweep into a
  half-written flap-damper state.
  Two smaller things: a **config with no receiver integrations is valid** (that
  is what makes a fresh host safe before SMTP is filled in), and the image runs
  as uid **65534**, which cannot read a 0600 SMTP-bearing config — the unit sets
  `User=0`, which under rootless podman is the login user (same as
  `victoriametrics`), not an escalation. Proving the path end to end is
  `scripts/monitor.sh --test`.
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
  `victoriametrics-mcp` is the authenticated front door (`/metrics` on the
  MCP host), for the same reason as the log store: the store's own API has
  no authentication, so it stays loopback-only and a bearer token gates the
  PromQL the agent can ask. Its `get_metrics_health` reads
  `stack_metrics_timestamp`, the same heartbeat the monitor's staleness
  check is about, so an agent can tell an empty graph from a dead collector.
- **Logs: journald is the source, `vector` the only shipper, `victoria-logs` the
  history.** Nothing in the units sets a log driver: podman's default is
  journald, so every container's stdout and every host script's output is
  already in the **system** journal (`journalctl --user` is empty on this host
  -- user-unit output lands in the system journal with `_SYSTEMD_USER_UNIT`).
  `bootstrap.sh` makes journald persistent and bounded (`/var/log/journal`, 2 G,
  7 days) because the default was volatile, a 32 MB ring in `/run` that a
  reboot erased; `vector` reads the journal and pushes to `victoria-logs`
  (`LOGS_RETENTION`/`LOGS_MAX_BYTES` in `stack.conf`), which is loopback-only,
  not in `NPM_HOSTS`, not in `FIREWALL_PORTS`, and **not** in `BACKUP_PATHS`.
  `scripts/logs.sh` is the CLI over the same store. Read it over an SSH tunnel
  (`ssh -L 9428:…`, then `/select/vmui`), like `vmui`; there is no Grafana, by
  the same reasoning as the metrics store. `victoria-logs-mcp` is the
  authenticated front door for a client (`/logs` on the MCP host): the store
  itself stays loopback-only and out of `NPM_HOSTS`, because its own API has no
  authentication — publishing that would add a second, unauthenticated door to
  the same history the MCP token already gates.
- **podman's own event log is a config value, not a per-call flag.** Every podman
  invocation writes an event, and the backend is `events_logger`, `journald` by
  default (`/usr/share/containers/containers.conf`; there is no environment
  variable for it): an exec is **two** lines (`exec`, `exec_died`, each
  carrying the image's label dump) and podman's generated healthcheck units log
  a `health_status` line on *every* check. Measured before `deploy/install.sh`
  set it: 4,156 of 9,315 journal lines an hour (1.8 of 2.4 MB) -- 2,357
  `health_status`, 1,352 exec -- all shipped into the store, i.e. the noise
  `scripts/logs.sh` was supposed to answer past. `podman_events_conf` writes
  `[engine] events_logger = "file"` plus `events_logfile_max_size = "10m"` into
  `~/.config/containers/containers.conf`, and `verify.sh` fails if `podman info
  --format {{.Host.EventLogger}}` reports `journald` again. Four reasons it
  lives there rather than at the 64 `podman exec` call sites: a per-call
  `--events-backend=none` cannot reach the healthcheck units at all; no
  discipline survives the 65th call site (that is how the first one-place
  mitigation decayed); `file` keeps `podman events` readable from a bounded ring
  (`$XDG_RUNTIME_DIR/libpod/tmp/events`, tmpfs, ~8 h at this rate, gone at
  reboot) where `none` would throw the diagnostic away; and **nothing needs a
  restart** -- podman reads the file per invocation, unlike a rendered unit,
  where a re-render alone changes nothing. Two traps: the merge must be
  **table-aware**, because a second `[engine]` table is a TOML duplicate-table
  error and podman then refuses to run *anything* for that user, so the candidate
  is validated with `CONTAINERS_CONF=<candidate> podman info` before it replaces
  the real file (a file that fails is left alone); and the price is that the
  complete per-check health series leaves the journal, so a flap older than that
  ring is answered by `monitor.sh`'s restart delta and the unit's state, not by
  history. There are **two** copies of the setting, because root's podman is a
  different config chain: the login user's file (written by the user-side
  install) and `/etc/containers/containers.conf` (written by
  `install.sh --root`, i.e. `sudo ./bootstrap.sh`), which is what the
  `deploy/root/` sensor's own healthchecks read -- they are podman children of
  the *system* manager, so the user file cannot reach them, and they were the
  whole remainder of the flood (~120 lines an hour). `verify.sh` checks both: the
  user side through `podman info`, the root side by reading the merged file,
  since asking root's podman would need sudo.
  **`podman logs -f` stops working, by podman's own rule** (`using --follow with
  the journald --log-driver but without the journald --events-backend (file) is
  not supported`): follow reads the events stream to learn the container died,
  and that stream is now a file. Do not revert the setting for it -- `podman
  logs` without `-f` is unaffected, and the follow is `journalctl -f
  CONTAINER_NAME=<name>` (podman's journald driver sets that field, priority
  included, so it is a superset of the container's stdout) or `scripts/logs.sh
  --follow --container <name>` over the store. Both are named in README's "Logs
  and history".
- **Reading the host journal from a rootless container is two settings, and
  both were measured.** `GroupAdd=keep-groups` (the journal files carry an ACL
  for the login user's groups, and supplementary groups are dropped by default
  -- without it `journalctl` says "No journal files were opened due to
  insufficient permissions") **and** `SecurityLabelDisable=true` (the host label
  on the journal directories is unreadable to a container domain, and
  relabelling `/run` is not an option -- so mount them plain `:ro`, never
  `:z`). `vector` is the second unit after `node-exporter` with SELinux
  separation off; the mounts are `:ro` and it publishes nothing. Two further
  traps, both found only after persistence "worked":
  `Volume=/etc/machine-id:...:ro` -- journalctl resolves `/var/log/journal/<id>`
  from *its own* machine-id, so without it the container looks for the image's
  id, finds nothing and reports "No journal files were found" (the `/run`-only
  mount happened to work because that directory is scanned whole); and **both**
  `/run/log/journal` and `/var/log/journal` must be mounted, because journald
  starts volatile and is switched by a flush.
- **`Storage=persistent` does not take effect on restart -- only on a flush.**
  journald starts on the runtime journal and switches on `journalctl --flush`
  (SIGUSR1; journald.conf(5) says so, and systemd-journal-flush.service does it
  at boot). Restarting the service with the right config therefore changes
  nothing, which is exactly the state this host was in: config effective,
  `/var/log/journal` empty, `journalctl` logging only "Runtime Journal".
  `bootstrap.sh` writes the drop-in, pre-creates `/var/log/journal/<id>` with
  `root:systemd-journal` and the tmpfiles ACL (`systemd-tmpfiles --create
  --prefix /var/log/journal` -- the ACL is what `vector` reads through), then
  restarts **and flushes**, and judges the result by whether a `*.journal` exists
  under `/var/log/journal`, never by the config file. `verify.sh` does the same.
- **`vector`'s journald source: `current_boot_only=false` does not work on
  systemd 250-257** ("not supported for systemd versions 250 through 257"), so
  it is pinned `true` -- a restart resumes from its `data_dir` checkpoint rather
  than replaying, and entries from an earlier boot are not re-read (the journal
  itself keeps them for `podman logs`). Labels are only
  `host`/`unit`/`container`: `container` comes from `CONTAINER_NAME`; `unit` is
  set only for non-container entries, and podman's generated scopes
  (`libpod-conmon-<id>.scope`, `<64hex>-<invocation>.service`) are dropped --
  one name per container start is not a label. `priority` is a field, not a
  stream, and `_CMDLINE`/`CONTAINER_ID*` are deleted before ingest (VRL: a
  missing path is an error, so `.container == ""` must be tested *before*
  `del(.container)` or every `unit` is silently lost).
- **The host-side probes exec into two long-lived `netcheck` containers; they do
  not `podman run` per probe.** `net_curl`/`net_curl_host` run
  `podman --events-backend=none exec` against `netcheck` (npm-network) and
  `netcheck-host` (host network). A throwaway container per probe created a veth
  pair and a cgroup scope each time, and `verify.sh` makes dozens per sweep --
  the kernel logged ~12k lines an hour of veth churn, the biggest stream in the
  journal, and journald paid for it twice once the log store indexed it. Two
  containers, not one, because podman rejects host + bridge on the same
  container ("cannot set multiple networks without bridge network mode") and
  NPM's admin API is a `127.0.0.1` bind that only a host-netns client can reach.
  `--events-backend=none` keeps the exec session
  (`exec`/`exec_died`) out of the journal too, as belt to
  `deploy/install.sh`'s braces: the mechanism itself is `events_logger` in the
  user's `~/.config/containers/containers.conf` (the bullet above), because a flag at
  the call site cannot reach podman's own healthcheck units. `netcheck_ready`
  fails with the one-line fix when either is stopped; `deploy.sh` starts them
  first in `start_infra`, after `refresh_image_unit` because install.sh rebuilds
  the image in place (a plain `start` on an active unit keeps the old bits), and
  `ensure_netcheck` covers every `--only` branch (the monitor's verify sweep,
  npm-hosts, kuma-monitors all probe). `kuma-ctl` is still a one-shot
  `podman run` and keeps `--log-driver=none`: the driver only
  controls persistence, so their stdout still reaches the caller's command
  substitution while the journal stays clean. `wait_healthy` treats a container
  with no healthcheck as "up" -- `victoria-logs` is distroless and the netcheck
  pair only sleeps, so neither can define a health command; their functional
  checks are the LogsQL query and the probes themselves.
- **Two more sources feed the store, and each needed a correction.** Suricata's
  `eve.json` is a file (the sensor never writes alerts to stdout), read by
  `vector`'s file source and labelled `unit=suricata.service`; the container
  mounts the **parent** `$DATA_DIR/ids`, not `ids/suricata`, because a
  bind-mount source that does not exist is created by podman as the host user,
  and the root tier owns that directory (the rootful sensor must not write into
  a user-owned directory). Suricata stamps `+0000`, which is not RFC3339, so the
  remap normalizes it -- otherwise the store falls back to arrival time and the
  alert timeline drifts. Rotated `eve.json.YYYYMMDD` files are deliberately not
  matched; a fresh start backfills the current day (~21k events / 12 MB here,
  ~2 MB compressed in the store) and checkpoints resume from there. BoltMesh's
  backend and worker write structlog JSON to stdout: the remap parses it for
  those two containers only, promotes `level`/`logger`, replaces `message` with
  the human line, and **overrides `priority`** with the app's level, because
  journald reports every stdout line as informational -- without that,
  `--priority warning` silently misses every BoltMesh warning.
- **The monitor queries a store exactly once, and only to prove the log
  pipeline is alive.** `scripts/logs.sh --health` (newest entry within
  `MONITOR_LOGS_MAX_AGE_S`, default 900) is the one exception to "alerting never
  queries the pipeline": the failure it catches is the pipeline's own silent
  death, and a failure there can only *add* an alert. Everything else still
  reads the daemons and the host directly.
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
  `container:8000` on `npm-network` through `net_curl` (exec'd into the
  long-lived `netcheck` container; `netcheck-host` is the same image on the host
  network for NPM's own admin API on `127.0.0.1:81`). The units set `HealthCmd=`/`HealthInterval=`, so podman
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
  still validates. BTCPay's admin UI is gated by its own login (2FA expected),
  and its API by the store-scoped key the backend carries; no daemon RPC has a
  public NPM host any more.
- **`agent-skills` is client tooling, not a service, and never joins
  `APP_REPOS`:** it ships no Containerfile and starts no container, so
  `deploy_app` would bail on it. `deploy.sh`'s `fetch_agent_skills`/
  `install_agent_skills` clone it into `$BUILD_DIR/agent-skills` and run its
  `install.sh`, which links eight skills into the harnesses under `$HOME` and puts
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

## Interface contract with the app repos

The eight MCP servers are pure env-configured services: **they never read a stack
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
