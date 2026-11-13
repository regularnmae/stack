# The monitor and alerting

How a fault becomes a page: the host-side sweep writes facts, the rules decide
when, and Alertmanager speaks. Read this before touching `scripts/monitor.sh`,
`deploy/monitoring/rules/`, `deploy/vmalert.container`, `monitor.env.example`,
`alertmanager.yml`, or `scripts/metrics.sh`. The operator narrative is README's
"Monitoring & the spend tripwire". Signups are the one event on this path rather
than a fault; they are produced by `scripts/registrations.sh` (see "Events are
not faults").

## Invariants

- **The producer writes facts and never queries the metrics store.** That is what
  keeps a wedged store from silencing the checks themselves. The evaluator does
  query it (`for:` is a query), so the store is on the paging path: the sweep's
  `alerting` section checks the store, vmalert and Alertmanager every run and
  fails the external heartbeat when any is down. It is not a backstop but the
  primary channel for that failure: a dead evaluator mails a false "recovered"
  about two minutes later, and only the heartbeat can say it died. The log
  store's health is the one exception on the producer's side, and a failure
  there can only add an alert.
- **`resolve_timeout` must be far longer than the sweep** (24h); it is not a
  "how long before I page" knob, and vmalert's own end-stamp (4x the group
  interval) is what ends a live alert.
- **`send_resolved: false` by default** makes every recovery silent.
- **A check whose fact is a rate is decided by a rule over a window**, not by the
  sweep: unit restarts (`increase` over an hour), disk saturation and Suricata
  bursts (`avg`/`max` over 15 minutes). The sweep writes the number. A per-sweep
  verdict on a rate is an event -- true for one sweep -- so the section fired and
  resolved around every burst.
- **The flap damper is a pair: `for:` holds the onset and `keep_firing_for:`
  holds the reset**, rendered from `MONITOR_ALERT_FOR` and `MONITOR_ALERT_HOLD_S`.
  Nothing in the producer holds alert state.
- **A notification is a state change, never a reminder** (`repeat_interval:
  8760h`). One mail when a section starts failing, one when it recovers, and
  nothing while it stays the same.
- **A failed delivery is read back on the next sweep**, because the alert path
  cannot report itself.
- **The alert path is the host's own `curl`/`jq`, never `net_curl`.**
- **Events ride the alert path but never the rules' state machine.** A signup is
  not a condition that clears: it is pushed once, from its own timer, with
  `severity="info"` and its own label, and ends by `endsAt`. A rule's `for:` and
  its inactive transition would turn one event into two mails.

## The monitor

- **The monitor is a read-only host script, not a container:** `monitor.timer` (a
  plain user unit) schedules `monitor.service`, which runs
  `scripts/monitor.sh --quiet` with an optional
  `EnvironmentFile=-@CONFIG_DIR@/monitoring/monitor.env` — the leading `-` keeps
  an unfilled file from stopping the sweep. The script reads that file through
  `env_value` (environment first, never sourcing it), so a hand run reports on
  exactly what the timer would. It writes facts and never restarts a unit.
  Thresholds are `MONITOR_*` keys **with defaults in the script**, so an env
  file written before a check existed still monitors. The file itself is
  `deploy/examples/monitoring/monitor.env.example` **copied verbatim** by
  `install.sh` (the alertmanager config's pattern), because the two used to be
  hand-kept and drifted: the seeded copy was missing keys the example documented
  and `monitor.sh` read five keys no file mentioned. `ci.yml` therefore fails
  when `monitor.sh` resolves a `MONITOR_*` key the example does not declare —
  that check is the only thing keeping a new threshold discoverable. It carries
  the host checks (disk space, inodes,
  backup age, certificate expiry, NIC errors/drops, the
  hottest sensor, a stale metrics textfile, the exporter that serves it, the
  backup/drill/dump/metrics and registrations **schedules**, journald's persistence, podman's event backend,
  the syslog socket, the signup watcher's freshness), the alert path itself
  (the store answers, vmalert answers and its rules loaded, Alertmanager answers
  and its config parses, a receiver is filled in, and nothing failed to deliver
  since the last sweep), and the
  chain/daemon checks (a shallow `verify.sh` sweep -- the `--deep` read-tool pass
  is on demand, not part of the five-minute cadence -- bitcoind
  freshness/peers/mempool, Fulcrum's tip, CLN peers/channels, monerod's lag, the
  wallet's lag). It also probes every
  clearweb vhost through nginx-proxy-manager on loopback (`NPM_DOMAINS`, from
  the manifest, so a new `[npm.*]` host is covered the moment it is declared)
  — the continuous public-surface check the UI-owned status page no longer
  provides. A `000` or `5xx` there means certificate, proxy host or loopback
  publish, never DNS: `--connect-to` deliberately bypasses it. A declared
  `force-ssl` host must answer `:80` with `301`/`308` and carry HSTS on the
  HTTPS response; a plaintext `200` is a fault, not a healthy vhost.

- **`verify.sh` is the on-demand diagnostic; the monitor is the only periodic
  producer.** The schedules, the metrics textfile, the log pipeline and
  Alertmanager's config used to be checked in both places, so one fault arrived
  as two alerts with two holds and two recoveries. `verify.sh` no longer
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

## Alerting is three processes

- **Alerting is three processes because they fail differently: the producer finds
  faults, vmalert decides when one has lasted, Alertmanager decides how to
  speak.** `scripts/monitor.sh` groups every finding under its `head3` section
  and writes one `stack_monitor_section{service,severity}` series per bad section
  plus a `stack_monitor_detail_info{service,detail}` line carrying that section's
  text. The rules in `deploy/monitoring/rules/stack.yml.in` (rendered to
  `$DATA_DIR/config/monitoring/vmalert/stack.yml`) fire one alert per section
  after `for: MONITOR_ALERT_FOR`, hold it for `keep_firing_for:
  MONITOR_ALERT_HOLD_S` after the section clears, and pull the detail into the
  annotation with vmalert's `query` template function. Three checks are not
  sections but rules of their own over a window -- `stack_unit_restarting`,
  `stack_disk_saturated`, `stack_ids_noisy` -- because their fact is a rate.
  Alertmanager owns grouping, inhibition, silences and delivery, and a recovery
  is vmalert's transition to inactive -- there is no `endsAt` for the producer to
  send and no producer state to keep. Five traps, all load-bearing:
  (1) **`resolve_timeout` is neither the paging delay nor a resolution
  override.** vmalert ends a normal alert itself, by sending an update whose
  endsAt is the moment the rule went inactive, so a real recovery does not wait
  for this. It applies only to an alert nothing updates any more (the signup
  watcher's alerts carry their own endsAt, so they bypass it too); it is **24h**
  here. The evaluator's own
  end-stamp is shorter: vmalert refreshes `endsAt` to now + 4x the group interval
  (two minutes at 30s), so a **dead vmalert** has Alertmanager mail "recovered"
  about two minutes later -- a false recovery for a fault that never cleared.
  That is the behaviour of every Prometheus-style notifier, and no Alertmanager
  setting can tell it from a real one, which is why the external heartbeat is
  mandatory here: it is the only thing that reports the evaluator itself dying.
  When vmalert returns, the rule re-fires after a fresh `for:`, so the fault is
  re-announced. **A severity change is a different alertname**, so the old rule
  goes inactive and the new one starts its own `for:` -- but it does not
  *inactivate* at once: `keep_firing_for` holds it, so the flip is one resolve
  for the critical and one fire for the warning, not a pair per sweep. While
  both are active the critical inhibits the warning, so the overlap is silent.
  (2) **`email_configs` defaults `send_resolved: false`**, so recoveries are
  silent unless it is set. The seeded example sets it.
  (3) **The alert's identity is (alertname, service), and the text is not a
  label.** Putting the section's message in a label would make "disk 9% free" and
  "disk 8% free" two alerts, and every sweep a state change; it lives in
  `stack_monitor_detail_info` and is fetched at notification time instead. The
  same split is why `for:` replaced the producer-side hold-down: Alertmanager
  only sees what is pushed at it, but vmalert evaluates the query, so it can tell
  a check that fails every other sweep from one that has been down an hour. A
  `for:` in flight resets on a vmalert restart (there is no `-remoteRead.url`),
  which is a page late by at most one hold-down, never lost.
  (4) **A delivery failure cannot report itself.** `alertmanager_notifications_failed_total`
  is read back on the next sweep and turned into a failure; the heartbeat is
  pushed *after* the facts are written and fails when they could not be, so "all
  checks pass but you cannot be told" is a page rather than a silent host. A
  sweep that cannot read `/metrics` leaves the stored counter untouched, so the
  outage is not later misread as a burst of delivery failures.
  (5) **The alert path is the host's own `curl` (and `jq`), not
  `net_curl`.** Alertmanager and vmalert are `127.0.0.1` binds and the heartbeat
  an outbound POST, so making them from a container would put the host's only
  paging path behind the thing that is most likely to be broken — which is
  exactly what an unmounted host `curl` was: the package was only in the
  bundle that runs when podman is *missing*, so a host provisioned earlier
  could pass every check and deliver nothing. `bootstrap.sh` now checks `curl`
  and `openssl` individually, `verify.sh`'s "Host tools" section names a gap,
  and `scripts/monitor.sh` refuses to run without `curl`/`jq` (one journal line,
  no facts written) rather than report a half-sweep as a clean one.
  Two smaller things: a **config with no receiver integrations is valid** (that
  is what makes a fresh host safe before SMTP is filled in; the "inert" warning
  follows the default route's receiver, so filling in only a signups sub-route
  still reports it), and the image runs as uid **65534**, which cannot read a
  0600 SMTP-bearing config — the unit sets `User=0`, which under rootless podman
  is the login user (same as `victoriametrics`), not an escalation. Proving the
  path end to end is `scripts/monitor.sh --test`.

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
  clears: the rules' `for:` would hold a signup for `MONITOR_ALERT_FOR` and the
  transition back to inactive would mail a second time.
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
  file's `ok_epoch` against `MONITOR_REGISTRATIONS_MAX_AGE_MIN` (30, i.e. thirty
  missed runs) and warns; the site is fine, only the notification is missing.
  `--skip-apps` hosts have no postgres unit at all, so the watcher records
  `skipped=1` instead of failing every minute.

## Metrics are history

- **Metrics are history, not alerting, and the two must not be coupled:**
  `victoriametrics` (loopback `8428`, 30d via `METRICS_RETENTION`) +
  `node-exporter` + `scripts/metrics.sh` on `metrics.timer` every minute.
  `monitor.sh` never queries the store — the *producer* must be able to speak
  while the pipeline is wedged, which is also why it reads the daemons and the
  host directly. The rules do query it (`for:` is an evaluation against the
  datasource), so the paging path does depend on the store; the sweep's
  `alerting` section and the external heartbeat are what cover that, and it is
  the one accepted regression of moving the hold-down out of the producer.
  Neither `vmui` nor `vmalert` gets an NPM host (neither has auth of its own), so
  nothing is added to `FIREWALL_PORTS`. node-exporter runs on
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
  `monitor.prom` carries the sweep's own numbers. One series there is
  deliberately high-churn: `stack_monitor_detail_info`'s label is the section's
  free text, so each distinct message is a short-lived series. It exists so the
  mail can carry the findings, it is bounded by the number of sections (not by
  traffic), and nothing queries or graphs it. The series and the
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
  alerting path: severity still comes from the rules, and a dead store or
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

- **The producer queries a store exactly once, and only to prove the log
  pipeline is alive.** `scripts/logs.sh --health` (newest entry within
  `MONITOR_LOGS_MAX_AGE_S`, default 900) is the one exception to "the producer
  never queries a store": the failure it catches is the pipeline's own silent
  death, and a failure there can only *add* an alert. The same call also proves
  the nginx-proxy-manager **file** source is being read (the access log's mtime
  against the store's newest `npm_access` entry, because a quiet site and a dead
  source both look like "no requests"); that is a second query in the same
  script, not a second call site. Everything else still reads the daemons and the
  host directly.
