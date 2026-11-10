# Units, the installer, and what the host is running

How `deploy/install.sh` renders the Quadlet units, how `deploy.sh` decides which
of them to restart, what a unit may mount, and the healthcheck contract every
container unit has to meet. Read this before touching `deploy/*.container*`,
`deploy/install.sh`, `deploy.sh`'s `sync_units`, or
`scripts/healthcheck-lint.sh`. The operator narrative is README's "Layout" and
"Rollback".

## Invariants

- **`install.sh` is the only installer.** Every env file is seeded and every unit
  rendered there; the unit inventory is the files in `deploy/` (`*.container`,
  `*.container.in`, `*.network`, and the plain `*.service`/`*.timer`), so a new
  service is a file there, never a change in an app repo. An env file's *shape* lives in `deploy/env/<app>/<file>.env.in`
  and is rendered by the same substitution list as the units (`render_to`).
- **A re-render does not change a running container.** `install.sh` advances
  `units.rendered`; only `deploy.sh` and `rotate.sh` advance `units.applied`,
  and only after applying. A hand render is drift and `verify.sh` names it.
- **`HealthOnFailure=kill`, never `restart`** -- podman's own restart leaves the
  unit active, so `NRestarts` never moves and the monitor cannot see the flap.
- **`HealthCmd` proves the process, not the data path.** A probe that is red
  while recovering (IBD, sync, first index) belongs in `monitor.sh`.
- **A durable unit is stopped, not killed.** `[Container] StopTimeout=` plus a
  larger `[Service] TimeoutStopSec=` on every unit in `stack.conf`'s
  `STATEFUL_UNITS`; Quadlet's 10 s default and systemd's 90 s default both
  SIGKILL a daemon mid-flush. See "A durable unit is stopped, not killed".
- **A container unit mounts only from `$DATA_DIR` (or a podman volume).** A bind
  source from the checkout breaks at the container's *next* start, not at
  deploy time.

## The render, and what the host is running

- **`install.sh` is the only installer:** every env file is seeded and every unit
  rendered there. A new service means a unit file in `deploy/` plus env seeding —
  nothing in the app repos, and no list to add it to: `UNITS`, `USER_UNITS` and
  `USER_TIMERS` are derived from the directory.

- **Secret resolution order** is `secrets.env` → the installed unit
  (`flag_value`) → the daemon's config (`bitcoin_conf_value`) → generate. That
  order is what makes adoption on a running host a no-op; keep it.

- **Env files have three write policies, and they are not interchangeable**
  (`install.sh` §6). `seed_rendered` writes only when the file is missing: an
  operator edit (`boltmesh/app.env`) and a rotation (`scripts/rotate.sh`'s
  `set_env_key` on `bitcoin-node-mcp/upstream.env` and `btc-explorer.env`)
  survive every install. `write_rendered_if_changed` is for machine-owned files
  (`crowdsec-mcp/lapi.env`, the view-only wallet's `upstream.env`) and rewrites
  them only when the bytes differ, so an unchanged credential does not churn a
  file's mtime. `render_unit` is for units only -- using it on a config file
  would silently undo a rotation. Token values are resolved *inside* the
  missing-file branch: a value computed before it would call
  `new_or_reused_token` (and announce a new token) on every run.

- **`install.sh` runs twice per deploy cycle** — `deploy.sh` renders up front,
  and `./configure.sh` re-runs it after `lightningd` is up, because the CLN
  runes need a running node. Don't collapse them: the second render is the one
  that can mint runes.

- **A re-render alone does not change a running container** (systemd keeps the
  old one), so the host persists the answer to "which definition are the
  containers running?": `install.sh` writes `$DATA_DIR/audit/units.rendered` on
  every render, and `deploy.sh`/`scripts/rotate.sh` write
  `$DATA_DIR/audit/units.applied` only after applying it. `deploy.sh` compares
  the live digests against `units.applied` (`scripts/lib.sh`'s `unit_digest` /
  `unit_digest_changed`, shared with `install.sh` and `verify.sh` so render and
  compare cannot drift apart) and restarts exactly the units whose definition
  changed — never ones that are inactive, since those are started later in
  order. The digest pass records the changed set once (`CHANGED_UNITS`, and
  `CHANGED_ACTIVE_UNITS` for the ones that were running), and the app tier and
  the explorers are in `DEFER_UNITS`: their own phase restarts them after its
  build, so a unit that is both changed and rebuilt is restarted once, not twice
  (once on the old bits, once on the new). `restart_applied` is the phase-side
  gate: it restarts only when `unit_was_changed` or the container's image id
  differs from the tag's, and starts an unchanged stopped unit instead. This is
  what makes **a hand `deploy/install.sh` visible drift instead of a swallowed
  signal**: it advances `units.rendered`, `verify.sh` fails naming the units
  (and the monitor pages through it), and the next deploy restarts them. Do not
  go back to digesting the files either side of the installer: that compares the
  render with itself. `units.applied` advances per unit: a tier that warns does
  not abort the deploy, but a changed unit no phase restarted keeps its own line
  where it is (`unit_digest_hold`), so `verify.sh` keeps naming it and the next
  run repeats it rather than hiding it — without holding back the units this run
  did apply, which would restart all of them a second time. The first deploy on a
  host without a baseline adopts the render on disk once, with a warning (drift
  older than that run is unknowable).
  `nginx-proxy-manager` is only flagged by the restart pass: its restart is
  deferred to `sync_npm_network`, after the proxy hosts are rewritten
  (`deploy.sh` says why the order is load-bearing), and `units_commit` keeps its
  baseline line behind while that flag is still set — a `--only` branch that
  never reached the rewrite must not claim NPM applied. `--only
  nginx-proxy-manager` is the exception: its branch restarts the unit directly
  (no branch rewrites the hosts) and settles the flag itself, so only a change
  that also moves the network mode still needs `--only npm-hosts`. Every `--only`
  branch goes through `sync_units` and commits at the end; `agent-skills` runs no
  installer and therefore commits nothing. Two ordering facts inside
  `sync_units`: **`ensure_netcheck` is its last step, not part of the `--only`
  prologue**, because `install.sh` rebuilds the `netcheck` image in
  `install_units` and a refresh before that compared the container with the old
  image and did nothing (the new client reached the containers one deploy
  later); and an app branch sets `DEFER_UNITS` so `restart_changed_units` leaves
  that unit alone — `deploy_app` restarts it after the build, and restarting it
  twice is two outages for one edit. `deploy.sh` does not wait for health at
  all: it restarts what changed and returns, and `./verify.sh` (or the monitor's
  sweep) is the verdict. The work that needs a service to be answering -- the
  CLN runes, the wallets, the BTCPay databases/bootstrap and the BoltMesh
  migrations -- is the second step, `./configure.sh`, which owns every bounded
  wait (`wait_healthy`, `wait_cmd`). It also restarts `lightning-mcp` when the
  rune file changed: the server reads `LIGHTNING_RUNE` from its
  `EnvironmentFile=` at start, so a rune minted after it started is otherwise
  invisible (a fresh host deploys the server before any rune exists).

- **`scripts/rotate.sh` is the third writer of `units.applied`.** A rotation
  re-renders through `install.sh` (only `bitcoin-rpc` and `tor-control` bake a
  secret into a unit's `Exec=` or `Environment=`), restarts its dependents and
  then advances the baseline — otherwise the next deploy would bounce the units
  it just restarted. Because `install.sh` re-renders *every* unit, `complete()`
  commits only when the changed definitions are ones the rotation restarted or
  proved already current; anything else stays unapplied for the next deploy,
  with a warning. That is why the units baking the RPC credential live in one
  list, `BITCOIN_RPC_UNITS`: it drives the restarts, and `apply_bitcoin_rpc`
  refuses to run when a unit in `deploy/` embeds the placeholder without being
  in it (`nbxplorer` was re-rendered and never restarted until it joined).

- **`<unit>.bak` is the *previous* render, and only when the render changes
  something.** It used to be written only if it did not already exist, so it
  was frozen at the host's first install while README's Rollback section
  presents it as the rollback path. The fix cannot be "always overwrite it":
  `./configure.sh` re-runs `install.sh` to mint the CLN runes once the node
  answers (the deploy itself renders once), so the second run would back up the
  file the first run just wrote and destroy the rollback. Hence the `cmp`: back
  up the old bytes only when the new ones differ, always as one generation,
  always mode 600 (`cp -p` — several rendered units carry `@PLACEHOLDER@`
  secrets).

## Units, mounts and runes

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

## Healthchecks follow a contract

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
  stay visible. (The old HC009 — "every non-oneshot unit is named in
  `verify.sh`" — is gone with the list it policed: both sides now derive that
  inventory from `deploy/*.container`, so there is nothing to keep in step.) Three decisions carry the reasoning:
  **`HealthOnFailure=kill`, never `restart`** — podman's own restart leaves the
  unit active, so `NRestarts` does not move and `monitor.sh`'s restart delta
  cannot see a container flapping every 30 s; systemd's `Restart=always` is the
  process that should act, and HC011 requires it on every non-oneshot unit
  (`crowdsec` shipped without it, so a kill was terminal). The two exceptions
  are `monero-wallet-btcpay` (red for a whole refresh) and `boltmesh-backend`,
  whose health is **deep** (postgres +
  valkey): a database blip must not restart-loop the app tier, and `verify.sh`
  pages on the same endpoint. **`HealthCmd` proves the process/serving path, not
  the data path** — a check that is legitimately red while recovering (IBD,
  monerod sync, wallet refresh, Fulcrum's first index) belongs in `monitor.sh`,
  never in a unit; that is why `fulcrum`'s and `monerod`'s probes are the
  process table, `tor`'s is a port and `bitcoind`'s is a bare TCP connect to its
  RPC listener (`nc -z`, no request), and replacing any of them with a data
  probe is a regression, not a fix. A liveness *file* is the one data-shaped
  probe that belongs in a unit (`boltmesh-worker` serves no port, so its own
  cron refreshes one), and it must assert a **match**: bare `find -mmin -3`
  exits 0 when nothing matched, so a stopped cron would look healthy — hence
  `-print -quit | grep -q .`. `bitcoind` is the second worked example, and
  the sharper one: its probe *was* `bitcoin-cli getblockchaininfo`, so it
  entered the RPC work queue that Fulcrum's first index, the explorers and
  nbxplorer were already filling — the check itself answered "error: Server
  response: Work queue depth exceeded", and `HealthOnFailure=kill` turned three
  of those into a restart every ~8 minutes (13 starts in 48 h), each one
  resetting Fulcrum's connections and re-verifying the index. A probe that
  competes for the resource under load is a kill switch aimed at the work.
  `monerod` is the worked example: its
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
  answer. That is `./configure.sh`'s wait, not the deploy's. Durations are **Go
  duration strings and may be fractional** (`HealthTimeout=7.5s` is legal),
  which is why `dur_ms` (in `deploy/root/status.sh`, sourced by `lib.sh` and
  installed for the root tier) parses each
  component by its unit: the whole-second regex it replaced matched the digits
  *after* the dot, reading `2.5h` as `5h`, `1m30.5s` as 65 s and `500ms` as 500
  minutes — and `healthcheck-lint.sh` judges HC006 in ms for the same reason, so
  a 6 s probe still fails against a 5.5 s timeout. The bouncer takes the same
  parse floored (`dur_to_sec`) and clamps it to 1s..24h. A **one-shot unit
  (`Type=oneshot`) is the other way a wait lies**:
  the job *exits* instead of reporting `(healthy)` and never appears in
  `podman ps`, so `wait_healthy` reads its terminal state instead
  (`exited 0` = done) — before that, waiting on a `postgres-dump`/`btcpay-bootstrap`
  job spun its whole 180 s and warned "container missing" about a job that had
  succeeded. The ten MCP servers' `healthcheck.py` (authenticated `initialize`,
  SSE `data:` unwrap, 5 s bound) is the model for an app-side probe. Their
  **data path is a separate, unauthenticated `GET /ready`** -- a bounded probe
  of the upstream that answers 200 with its height/lag or 503 with the reason.
  It exists so "the process is up" and "the upstream answers" are different
  answers, and it must never replace `healthcheck.py` in `HealthCmd`: a syncing
  or stopped upstream is legitimately red, and `HealthOnFailure=kill` would
  restart-loop the container. `/ready` is for an operator or a host-side probe;
  no unit's `HealthCmd` depends on it.

- **A failing probe is a FAIL, not a warning -- `verify.sh` reads the suffix,
  not the "Up".** `podman ps` renders a container whose probe is failing as
  `Up 5 minutes (unhealthy)` and one whose probe has not answered yet as
  `Up 10 seconds (starting)` (podman 5.x; some builds render
  `(health: starting)`); both begin with `Up`, so the old prefix-match reported
  a red container as a warning, and `warn` never counts as a failure. That
  mattered because `scripts/monitor.sh` carries only `verify.sh`'s FAIL lines
  and its exit code: an unhealthy container was invisible to alerting while
  every sweep said the stack was fine. The states are now classified once, by
  `container_health_state` in `scripts/lib.sh` (tested in
  `tests/test-lib.sh`), and `verify.sh` fails on `unhealthy`, naming the remedy.
  `starting` stays a warning deliberately: podman promotes a probe that never
  succeeds to `unhealthy` after `HealthStartPeriod` x `HealthRetries`, so the
  state is bounded and transient, whereas a FAIL would page on the tail of
  every ordinary restart (the sweep runs every five minutes and
  `bitcoind`/`lightningd` carry a 5m start period). Plain `Up` with no health
  status is a warning too, except for the `HEALTHLESS_UNITS` above. Two units
  are still expected to be red for long stretches -- `monero-wallet-btcpay`
  during a rescan, `boltmesh-backend` on a database blip (HC008's exemptions) --
  but both already fail their own functional checks (`/health`, `get_height`),
  so this adds no new page there.

## A durable unit is stopped, not killed

- **Quadlet's stop path has two deadlines, and raising one alone changes
  nothing.** Quadlet renders `ExecStop=/usr/bin/podman rm -v -f -i <name>`, and
  the container carries podman's default `--stop-timeout` of **10 s**: SIGTERM
  now, SIGKILL ten seconds later. Outside that, systemd's
  `DefaultTimeoutStopSec` is **90 s** for the whole stop job. So
  `StopTimeout=300` with the default systemd ceiling still ends in a SIGKILL at
  90 s, and the daemon dies uncleanly anyway. The two knobs are not symmetric:
  `[Container] StopTimeout=` is integer seconds and renders `--stop-timeout`;
  `[Service] TimeoutStopSec=` is a systemd time span rendered verbatim (write
  `150s`). `StopTimeout` in `[Service]` is an unknown systemd key, which systemd
  logs and ignores -- it is not a typo that works. `TimeoutStopSec` must exceed
  `StopTimeout` by at least 30 s: it covers `ExecStop` and `ExecStopPost`, and
  systemd's kill is the last resort, not the plan.

- **This is what put Fulcrum into its rebuild.** On 2026-11-08 23:47 the stop of
  `fulcrum` hit the 10 s ceiling mid-flush and the next start logged "previous
  run of Fulcrum may have shut down uncleanly, however undo info is missing from
  the DB" -- the same message seven times since 10-31. Its clean stops on this
  host measured 1.5 s, 6.7 s, 8.3 s and 9.2 s: one slow flush is all it takes.

- **`monerod` is the case the ceiling exists for.** Its LMDB close
  (`Deinitializing core...`) never finished inside 10 s here; on 11-08 16:21 the
  SIGKILL itself took 34 s to be honoured (uninterruptible I/O on the rotational
  data disk, a 150 GB DB) and the unit took 44 s to stop. `StopTimeout=300` on it
  is the only value that is not a guess -- the full flush has never been observed
  to complete. `bitcoind` (`Shutdown: done` in 3-5 s) and `postgres` (fast
  shutdown plus checkpoint, ~2 s) are on the same disk and get 120 s and 60 s.

- **The rest of the tier is not decoration.** `lightningd`, `nbxplorer`,
  `btc-explorer` and `monero-node-mcp` were all SIGKILLed at 10 s during the
  11-03 event, when a host-wide stop saturates the same disk for every unit at
  once. The MCP servers lose nothing; the daemons are the ones that must be
  allowed to finish.

- **Declared once, in `stack.conf`'s `STATEFUL_UNITS`, and checked by
  `healthcheck-lint.sh`'s HC010.** The lint requires each listed unit to carry
  both keys with 30 s of headroom, and that every listed name is a real
  template; a waiver needs an inline `# health-lint: HC010 <reason>`. Not every
  `@DATA_DIR@` mount is on the list -- a search cache or a metrics history is
  not state -- so a new daemon whose database must be closed cleanly has to be
  added there.

- **`HealthOnFailure=kill` bypasses all of it.** Podman's own health kill is not
  a graceful stop, and no `StopTimeout` can make it one. That is why the probe
  contract above matters: a probe that is red while recovering (IBD, monerod
  sync, Fulcrum's first index) is a SIGKILL aimed at a durable daemon's data.

## Ownership and images

- **Data-dir ownership:** `bitcoind` runs as the image uid
  (host 525287 = in-container 1000) and do **not** re-own their bind mounts, so
  `install.sh` hands it the datadir entry and `bitcoin.conf` (top-level only,
  never a recursive walk over the chain: bitcoind creates the block and
  LevelDB subdirectories as that uid itself); `monerod` re-owns its
  own directory. `cln/`, `tor/`, `uptime-kuma/` and `fulcrum/` are written by
  container root (= the host user under rootless podman).

- **Every pulled image carries a real tag, and two managers cover them.**
  Renovate's Quadlet manager reads `*.container`/`*.image`/`*.volume` and
  **cannot see `deploy/*.container.in`**; those three templates, and the one
  image default that lives in shell (`RESTIC_IMAGE`, which both
  `scripts/backup.sh` and `scripts/rotate.sh` define — no manager reads a shell
  default), are matched by `renovate.json`'s regex manager. Both files are
  matched so a restic bump moves them together. The wallet tag appears in
  the `btcpayserver/monero` unit, and one PR moves both; it also appears in
  the README's "What runs" table, which `stackctl units check` holds to the
  units' own `Image=` lines. `postgres` (hand
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

- **Workflow actions go the opposite way: pinned by digest.**
  `helpers:pinGitHubActionDigests` in `renovate.json` rewrites every `uses:`
  ref in `.github/workflows/*.yml` to `<sha> # <tag>`, and keeps it there. The
  asymmetry with the images is deliberate: a moved image tag only reaches the
  host through a deploy the operator asked for, while a moved action tag *is*
  the code that runs, on a runner, with the repo's token -- so an unreviewed
  tag move is exactly the supply-chain hole, and a digest bump that arrives as
  a PR is not noise but the review. By hand the bump is
  `git ls-remote <repo> refs/tags/<tag>`. The job's
  `permissions: contents: read` is the same reasoning: checkout, curl and
  `git ls-files` write nothing.

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
  (each build directory is that one file), which is why the hash is
  the Containerfile's and not the directory's.

## The app tier, shared mounts, and the root tier

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

- **`sudo` lives only in `bootstrap.sh`.** `deploy.sh`, `configure.sh`,
  `install.sh`, `verify.sh` and the `scripts/` helpers never call it; an
  unprepared data dir is an error
  carrying the one-time commands, not a prompt. The one thing bootstrap uses it
  for beyond provisioning is the **root tier** (`deploy/install.sh --root`): the
  Suricata sensor, which cannot be rootless because AF_PACKET needs
  `CAP_NET_RAW` in the init user namespace. That is why bootstrap is a
  **two-pass** install -- the sensor's unit and config reference `@DATA_DIR@`,
  so the first run (before any data dir exists) only prints a notice and the
  rerun after the first `./deploy.sh` installs it. Everything it installs is
  root-owned: the unit in `/etc/containers/systemd/`, the config in
  `/etc/stack-ids/`, the logrotate rule in `/etc/logrotate.d/`, and the
  bouncer/audit units in `/etc/systemd/system/`. That unit is mode
  0644 (not the 0600 the user units get) because `verify.sh` diffs it against
  `deploy/root/` to catch drift and it carries no secret -- the secret-bearing
  templates are the *user* units. Nothing
  root-owned is *read* from `$DATA_DIR` -- the sensor only writes its logs there
  (root-owned, 0644, so the unprivileged `scripts/ids.sh` can read them), and a
  user-writable config consumed by a root container would be a privilege
  boundary. A change to `deploy/root/` therefore needs `sudo ./bootstrap.sh`
  again; `verify.sh` walks a declared table (`ROOT_FILES`) of every file
  `install.sh --root` renders and warns per file when one has drifted or is
  missing. One file in that directory is also read by the user tier:
  `deploy/root/status.sh` is sourced from the checkout by `scripts/lib.sh` and
  from `/etc/stack-ids/` by the root jobs, so the status writer and the
  Go-duration parser have one implementation across the boundary. Content only
  -- bootstrap owns the modes -- and two kinds are
  excluded on purpose: the 0600 env files (written from heredocs, no repo
  counterpart) and `60-stack.rules` (0640 in a 0750 directory,
  unreadable to an unprivileged sweep; the audit section reads the report's
  verdict instead). The bouncer's four are marked `opt`, absent until the
  second bootstrap pass has a key, so they are skipped rather than warned about
  on a host that has not got one yet.

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

## The host-side probes

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
  (`exec`/`exec_died`) out of the journal too, as belt to the drop-in's braces:
  the mechanism itself is `events_logger` in `deploy/podman/99-stack.conf`, which
  installs as `~/.config/containers/containers.conf.d/99-stack.conf` (the bullet
  above), because a flag at
  the call site cannot reach podman's own healthcheck units. `netcheck_ready`
  fails with the one-line fix when either is stopped; `deploy.sh` starts them
  first in `start_infra`, after `refresh_image_unit` because install.sh rebuilds
  the image in place (a plain `start` on an active unit keeps the old bits), and
  `ensure_netcheck` covers every `--only` branch (the monitor's verify sweep and
  npm-hosts both probe). One-shot `podman run`s elsewhere keep
  `--log-driver=none`: the driver only
  controls persistence, so their stdout still reaches the caller's command
  substitution while the journal stays clean. `wait_healthy` treats a container
  with no healthcheck as "up" -- `victoria-logs` is distroless and the netcheck
  pair only sleeps, so neither can define a health command; their functional
  checks are the LogsQL query and the probes themselves.

## The knobs in stack.conf

`stack.conf` is plain shell sourced by `bootstrap.sh` and `deploy.sh`; each knob
carries one line there and its reasoning is here.

- **`FIREWALL_PORTS`** is the complete LAN-reachable surface: `80/443/81` for
  nginx-proxy-manager, which is on the host network and binds them itself (that is
  what makes a client's real address reach its logs), and `50001/50002` for
  Fulcrum, because the Electrum protocol is raw TCP and NPM cannot front it. Every
  other service publishes on the host's loopback only, which is where NPM's
  forwards point; a loopback bind is not LAN-reachable, so those ports stay closed.
- **`APP_REPOS` order is load-bearing**, not alphabetical: each server reads
  something the step above it brings up. A server whose upstream is missing on
  first boot is retried by `./configure.sh` rather than ordering the whole deploy
  around it.
- **`HEALTHLESS_UNITS` and `STATEFUL_UNITS` are policy lists**, not inventories
  (the inventory is `deploy/` itself). The first is the complete set of units that
  cannot define a health command, with the reason; the second is the units whose
  on-disk database must be closed cleanly, and the test is whether a SIGKILL
  mid-write costs a rebuild or a resync -- not whether the unit writes at all.
- **`CHAIN_UNITS` is the one list `deploy.sh --skip-daemons`, `verify.sh
  --no-nodes` and `MONITOR_SKIP_NODES` share**, so a skipped unit is not
  reported missing. The monitor's flag is what a long-lived skip-daemons host
  sets: it skips the chain section and the declared `needs_nodes` vhosts, and
  appends `--no-nodes` to its own verify sweep.
- **`BTCPAY_PLUGIN_URL`/`_SHA256` are edited together.** Renovate cannot track a
  plugin-builder URL, and the marker file install.sh writes is what makes the edit
  land, since the DLL's name does not change between versions.
- **Retention** (`METRICS_RETENTION`, `LOGS_RETENTION`, `LOGS_MAX_BYTES`,
  `IDS_RETENTION_DAYS`) is sized for a postmortem, not an archive. The metrics and
  log stores are regenerable and outside the backup set; `LOGS_MAX_BYTES` is a
  second, independent bound so a crash-loop cannot fill the data disk.
