# The monitor and alerting

How a fault becomes a page: the host-side sweep, the Alertmanager hop, and the
one place metrics and alerting touch. Read this before touching
`scripts/monitor.sh`, `monitor.env.example`, `alertmanager.yml`, or
`scripts/metrics.sh`. The operator narrative is README's "Monitoring & the spend
tripwire". Signups are the one event on this path rather than a fault; they are
produced by `scripts/registrations.sh` (see "Events are not faults").

## Invariants

- **The monitor is alert-only and never queries the metrics store** -- that is
  what keeps a wedged store from silencing an alert. The log store's health is
  the one exception, and a failure there can only add an alert.
- **`resolve_timeout` must be far longer than the sweep** (24h); it is not a
  "how long before I page" knob.
- **`send_resolved: false` by default** makes every recovery silent.
- **The flap damper lives in the producer**, not in Alertmanager.
- **A failed delivery is read back on the next sweep**, because the alert path
  cannot report itself.
- **The alert path is the host's own `curl`/`jq`, never `net_curl`.**
- **Events ride the alert path but never the monitor's state machine.** A
  signup is not a condition that clears: it is pushed once, from its own timer,
  with `severity="info"` and its own label, and ends by `endsAt`. The monitor's
  hold-down and explicit resolution would turn one event into two mails.

## The monitor

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
  hottest sensor, a stale metrics textfile, the exporter that serves it, the
  backup/drill/dump/metrics and registrations **schedules**, journald's persistence, podman's event backend,
  the syslog socket, the signup watcher's freshness), the Alertmanager facts the
  mail path depends on (its config still parses, a receiver is filled in) and the
  chain/daemon checks (a
  `verify.sh` sweep, bitcoind freshness/peers/mempool, Fulcrum's tip, CLN
  peers/channels, monerod's lag, the wallet's lag). It also probes every
  clearweb vhost through nginx-proxy-manager on loopback (`NPM_DOMAINS`, from
  the manifest, so a new `[npm.*]` host is covered the moment it is declared)
  — the continuous public-surface check the UI-owned status page no longer
  provides. A `000` or `5xx` there means certificate, proxy host or loopback
  publish, never DNS: `--connect-to` deliberately bypasses it.

- **`verify.sh` is the on-demand diagnostic; the monitor is the only periodic
  decider.** The schedules, the metrics textfile, the log pipeline and
  Alertmanager's config used to be checked in both places, so one fault arrived
  as two alerts with two hold-downs and two resolutions. `verify.sh` no longer
  carries its Backups/Monitoring/Metrics/Alerting/Logs sections; its header says
  which section owns each fact now. The rule that follows: a check belongs in the
  sweep when it is a condition that clears and should page, and in `verify.sh`
  when it is config drift worth naming to a human (a rendered unit that was never
  applied, a hand-edited `servers.json`, the root tier's files).

- **The syslog socket is probed, not assumed:** sshd, PAM, sudo and cron all log
  through `/dev/log`, and a stale socket inode drops every one of those messages —
  this host ran six days (Oct 31 → Nov 7, 2026) with SSH logins recorded nowhere
  while the journal still looked healthy, because container stdout kept filling
  it. The sweep writes a `logger -p authpriv.info` sentinel and fails unless it
  comes back out of the journal: that is the only probe covering the whole path,
  and `/var/log/secure` is root-only so the file cannot be the check.

## Alerting is two processes

- **Alerting is two processes because they fail differently: the monitor finds
  faults, Alertmanager decides when to speak.** `scripts/monitor.sh` groups
  every finding under its `head3` section, pushes one alert per section to
  `alertmanager` (`POST /api/v2/alerts`, loopback `9093`) and resolves a section
  explicitly with an `endsAt` in the past when it clears. Alertmanager owns
  grouping, `repeat_interval`, inhibition, silences and delivery. Five traps
  found by running it, all load-bearing:
  (1) **`resolve_timeout` must be far longer than the sweep.** A pushed alert
  carries no `endsAt`, so Alertmanager resolves it once it has not been updated
  for `resolve_timeout` — the default 5m is exactly the timer interval, and
  `0` does not disable it (the API sets `EndsAt = now + resolveTimeout`, so `0`
  resolves instantly). It is **24h** here, and explicit `endsAt` is what
  actually ends an alert, which also keeps a dead monitor from mailing
  "recovered". **A severity change is a label change**, so it is a *different*
  alert: the monitor resolves the old label set in the same push. Without that
  the stale critical lives to `resolve_timeout` and its inhibition — `equal:
  ['instance']` — keeps every warning on the host silent meanwhile.
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

- **Editing `alertmanager.yml` needs an explicit reload.** Alertmanager v0.34
  ships no config-file watcher (the process holds no inotify fd at all: verified
  on this host), so an edit — even an atomic write/rename — changes nothing
  until `curl -X POST http://127.0.0.1:9093/-/reload` (or SIGHUP), and
  `alertmanager_config_last_reload_successful` is the proof that it took. The
  comments in `alertmanager.container` and the example used to claim otherwise,
  which is exactly how a route can be added and silently not exist.

## Events are not faults

- **A registration is an event, so it gets its own producer and its own route.**
  `scripts/registrations.sh` (host script, `deploy/registrations.timer` every
  minute) reads new rows from BoltMesh's `users` table through
  `podman exec postgres psql` — the row is the record; the app's one journal
  line (`User registered successfully: ID <uuid>`, in
  `app/auth/services/registration.py`) carries neither username nor email, and an
  OAuth signup (`app/auth/services/oauth.py`) writes no such line at all. It is
  not folded into `monitor.sh` because every monitor section is a condition that
  clears: the flap damper would hold a signup for `MONITOR_ALERT_FOR` and the
  explicit resolution would mail a second time.
- **Each signup is pushed once, with its own label and its own group.** The
  alert is `alertname=boltmesh_signup`, `severity=info`, plus `signup=<uuid>`;
  without that per-signup label Alertmanager sees one label set and folds a
  second signup into the first. The `severity="info"` sub-route sets
  `group_by: ['signup']` for the same reason one level lower: with the inherited
  `group_by: ['severity']`, a signup could be folded into a group whose
  notification was already sent, and — this was observed while testing — a group
  whose notification log entry survived an Alertmanager restart held the next
  signup until `group_interval`, after which an alert that had already passed its
  `endsAt` was gone and mailed nothing. A unique group key has no such history.
  `endsAt` is ten minutes out, so it fires once and clears itself.
  `alertmanager.yml` routes `severity="info"` to `stack-signups`, whose
  `send_resolved: false` is load-bearing: the default receiver mails
  resolutions, and every registration would otherwise arrive with a meaningless
  "recovered".
- **The watermark is the state machine, and it is `(created_at, id)`.**
  `$DATA_DIR/audit/registrations.status` holds the last row pushed; ids are
  UUIDs, so the pair is what orders two rows sharing a microsecond. A failed
  push leaves the watermark alone (so the mail is late, never lost) and the
  *first* run seeds it from the newest existing row, because deploying this must
  not mail the accounts that already exist. `--dry-run` shows what would be sent;
  `--test` proves the `info` route without touching the watermark, and it runs
  before the app-tier check, so a `--skip-apps` host can use it too.
- **A dead watcher is a warning, not a page.** The sweep reads the status
  file's `ok_epoch` against `MONITOR_REGISTRATIONS_MAX_AGE_MIN` (20, i.e. twenty
  missed runs) and warns; the site is fine, only the notification is missing.
  `--skip-apps` hosts have no postgres unit at all, so the watcher records
  `skipped=1` instead of failing every minute.

## Metrics are history

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
  stopped while everything is healthy" is almost always that, so the sweep
  checks both halves: `stack.prom`'s mtime (the writer) and whether
  node-exporter actually serves a `stack_*` series (the reader).
  `$DATA_DIR/monitoring` is regenerable and outside the backup set, and
  `monitor.prom` carries the sweep's own numbers. The series and the
  observe/decide split are documented in `scripts/metrics.sh`.
  `victoriametrics-mcp` is the authenticated front door (`/metrics` on the
  MCP host), for the same reason as the log store: the store's own API has
  no authentication, so it stays loopback-only and a bearer token gates the
  PromQL the agent can ask. Its `get_metrics_health` reads
  `stack_metrics_timestamp`, the same heartbeat the monitor's staleness
  check is about, so an agent can tell an empty graph from a dead collector.
  `get_stack_status` is the one-call answer to "what is broken?": it combines
  Alertmanager's live `/api/v2/alerts` (reached at `alertmanager:9093` on the
  same network -- the unit publishes only to loopback) with the verify,
  chain and job series, and reports `ok`/`warning`/`critical`/`unknown`
  plus the alerts themselves. It is a convenience for an agent, not a second
  alerting path: severity still comes from the monitor, and a dead store or
  Alertmanager is named in the answer rather than turned into a green one.
  A series with no sample is `null`, never `0` -- a collector skips an
  unreachable daemon.

- **Per-container cost is stored, but only as counters and gauges a query can
  trust.** `scripts/metrics.sh` reads `podman stats --no-stream --format json`
  once a minute and emits `stack_container_cpu_seconds_total`,
  `stack_container_mem_working_set_bytes`, `stack_container_pids` and
  `stack_container_network_{receive,transmit}_bytes_total`, labelled by
  container **name** (a recreated container keeps its series, and `rate()`
  handles the reset). Three deliberate omissions: podman's `cpu_percent` on
  `--no-stream` is a one-shot reading over an unknown interval — measured at
  25.5% against a 1.8% lifetime average — so `rate()` over the counter is the
  query, not a stored percentage; `mem_usage` is the working set
  (`memory.current - inactive_file`), not RSS, hence the name; and `block_io`
  reads `0B / 0B` on every container here because the io controller does not
  account under rootless cgroups, so it is not exported. This is history only:
  `monitor.sh` gains no container check, preserving the rule above. A container
  whose counters cannot be parsed is skipped and `stack_collector_error` names
  the parse, so a hole is never written as a zero.

## The one store query

- **The monitor queries a store exactly once, and only to prove the log
  pipeline is alive.** `scripts/logs.sh --health` (newest entry within
  `MONITOR_LOGS_MAX_AGE_S`, default 900) is the one exception to "alerting never
  queries the pipeline": the failure it catches is the pipeline's own silent
  death, and a failure there can only *add* an alert. The same call also proves
  the nginx-proxy-manager **file** source is being read (the access log's mtime
  against the store's newest `npm_access` entry, because a quiet site and a dead
  source both look like "no requests"); that is a second query in the same
  script, not a second call site. Everything else still reads the daemons and the
  host directly.

