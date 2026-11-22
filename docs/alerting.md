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
- **Recovery mail is for criticals; warnings are batched and silent on
  recovery.** `email_configs` defaults `send_resolved: false`, so the warning
  receiver is explicit about it: a Suricata burst or a busy disk that clears ten
  times a day is not a state change worth a mail. The critical receiver sets it
  to true.
- **The heartbeat is a liveness signal, not a second alert channel.** A sweep
  that completes pings OK even when it has findings; `/fail` is for a monitor
  that could not write facts or an alert path that is broken (the store,
  vmalert, Alertmanager, a delivery). The unit exits 0 for findings too:
  `status=fail` in `audit.log` is the record, Alertmanager is the channel.
  Sending `/fail` for every finding is what made healthchecks.io duplicate every
  fault and left `monitor.service` red on every five-minute tick.
- **A check whose fact is a rate is decided by a rule over a window**, not by the
  sweep: unit restarts (`changes` over 30 minutes; `NRestarts` is not a counter),
  disk saturation, Suricata and SSH bursts (`avg`/`max` over 15 minutes). The
  sweep writes the number. A per-sweep verdict on a rate is an event -- true for
  one sweep -- so the alert fired and resolved around every burst.
- **The flap damper is a pair: `for:` holds the onset and `keep_firing_for:`
  holds the reset**, rendered from `MONITOR_ALERT_FOR` and `MONITOR_ALERT_HOLD_S`.
  Nothing in the producer holds alert state.
- **A notification is a state change, then a reminder** (`repeat_interval: 24h`
  for criticals, `96h` for warnings; both are below Alertmanager's
  notification-log retention of 120h, because a larger value is repeated at the
  retention boundary instead). A critical mails when a component/check starts
  failing, when it recovers, and once a day while it stays the same. A warning
  waits `group_wait: 15m` (so one that clears on its own never mails), updates at
  most hourly, sends no recovery, and reminds every four days. Warnings are the
  half that flaps; the route is what keeps a burst or a busy disk from becoming
  a mail per transition.
- **A startup is not an outage.** For `MONITOR_STARTUP_GRACE_S` after a container
  starts (15 minutes by default), the checks that depend on it are `skip`, not
  findings: a chain daemon that is still indexing and a wallet rebuilding its
  cache are expected states. A container that is actually down or unhealthy is
  not graced -- `stack_component_up` pages it at 2m and `stack_component_health`
  warns after 5m. A long reindex is the same fact at a different scale: when
  Fulcrum is not answering Electrum, the sweep reads its `Processed height` log
  and emits one warning with the percentage while progress is recent
  (`MONITOR_INDEX_PROGRESS_MAX_AGE_MIN`); only a stalled index is critical. The
  BTCPay view-only wallet is not a fault when `get_height` says "No wallet
  file": the RPC is up and BTCPay opens the wallet on demand, so the unit's
  `get_version` healthcheck is its liveness probe.
- **The alert identity is `(component, check)`, not the section.** A section is a
  human grouping and a history graph; an alert names the component whose fault it
  is and the check that failed. That is what lets Alertmanager inhibit the
  `verify`/`public_surface` symptoms of one dead service instead of mailing three
  alerts for one cause.
- **`verify.sh`'s `warn` is the sweep's warning severity, and `skip` is not a
  finding.** The monitor runs `verify.sh` as its base sweep and carries both
  levels whether or not it exits non-zero -- a warning never fails its exit code,
  so the exit code alone would hide it. Each `FAIL` line becomes a critical
  finding and each `warn` line a warning, mapped to the component the line names
  (the `verify.sh` section itself stays the roll-up).
  `skip` is the level for an expected absence (a check skipped by request, a
  service not yet set up, a job that has not run yet) and is deliberately not
  carried, because a warning that is true on every sweep on a host that chose not
  to run something is a permanent alert, and that is how an alert path stops
  being read. A new check in `verify.sh` therefore has to pick its level: `warn`
  reaches the alert path, `skip` does not.
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
  the host checks (disk space and inodes on every filesystem behind `/`, the
  data dir, `$HOME` and the backup dir, NTP synchronization, SMART disk health,
  backup age, certificate expiry, NIC errors/drops, the hottest sensor, a stale
  metrics textfile, the exporter that serves it, the backup/drill/dump/metrics
  and registrations **schedules**, journald's persistence, podman's event
  backend, the syslog socket, the signup watcher's freshness), the failed-unit
  check (current failures in both managers and inactive oneshots whose last run
  exited non-zero), the alert path itself
  (the store answers, vmalert answers and its rules loaded, Alertmanager answers
  and its config parses, a receiver is filled in, and nothing failed to deliver
  since the last sweep), and the
  chain/daemon checks (a shallow `verify.sh` sweep -- the `--deep` read-tool pass
  is on demand, not part of the five-minute cadence -- bitcoind
  freshness/peers/mempool, Fulcrum's tip, CLN peers/channels, monerod's lag, the
  wallet's lag). It also probes every
  clearweb vhost through nginx-proxy-manager on loopback (`NPM_DOMAINS` and
  `NPM_PROBE_PATHS`, from the manifest, so a new `[npm.*]` host is covered the
  moment it is declared)
  — the continuous public-surface check the UI-owned status page no longer
  provides. A `000` or `5xx` there means certificate, proxy host or loopback
  publish, never DNS: `--connect-to` deliberately bypasses it. A declared
  `force-ssl` host must answer `:80` with `301`/`308` and carry HSTS on the
  HTTPS response; a plaintext `200` is a fault, not a healthy vhost.

- **Failed units are a warning, and the sweep reads two facts about them.**
  `systemctl --failed` (system and user) names what is failed now. A oneshot that
  is stopped after a failure keeps its `ExecMainStatus`, so the sweep also reads
  the last exit of inactive system services and names a non-zero oneshot after
  `systemctl stop`, when `--failed` is already empty. Both are warnings, not
  pages: the checks that own each effect (audit watches, bouncer, backup age,
  IDS) already decide the critical level. `audit-rules.service` no longer
  contributes the known duplicate-only failure: its
  `deploy/root/audit-rules-load.sh` wrapper treats only the "Rule exists" reload
  as success and still fails on a real error. `monitor.service` is excluded from
  the user list, because a failing sweep must not report itself.

- **The clock is a check, not an assumption.** `timedatectl show -p
  NTPSynchronized` is a yes/no fact; `no` fails because certificate issuance and
  Lightning's wall-clock checks depend on it. It works with chrony or
  systemd-timesyncd.

- **`--quiet` hides the per-check output, not the reason.** The timer runs the
  sweep with `--quiet`; when it fails, the final problem list is written to
  stderr, so `journalctl -u monitor.service` names the fault instead of only
  "Failed". A hand run prints every check.

- **SMART is a root-written verdict, not a `smartctl` call in the sweep.** Opening
  a block device needs root, so `stack-smart.timer` runs
  `/etc/stack-ids/smart.sh` hourly and writes `$DATA_DIR/audit/smart.status`. The
  sweep judges that file with `verdict_judge` (age
  `MONITOR_SMART_MAX_AGE_H`) and reads its `disk0_*` fields for reallocated and
  pending sectors, SCSI grown-defect/uncorrected counts, NVMe media errors and
  temperature. The probe records the facts; the policy is
  `MONITOR_SMART_REALLOC_MAX`, `MONITOR_SMART_PENDING_MAX`
  and `MONITOR_SMART_TEMP_MAX` in `monitor.env`, so tuning needs no root
  reinstall. A standby disk is `state=standby` and is not woken (`-n
  standby,0`); a bridge that exposes no attribute table is a warning, not a
  failure -- while a block device that cannot be opened is the probe's own
  `result=fail`.

- **A stale dump names its producer.** The dump files' mtimes are the effect
  check; when one is missing or older than `MONITOR_DUMP_MAX_AGE_H`, the sweep
  also reads `audit/postgres-dump.status` or `audit/db-dump.status` and prints
  that producer's result and detail. A healthy sweep does not read them, so the
  added context costs nothing until it is needed.

- **`verify.sh` is the on-demand diagnostic; the monitor is the only periodic
  producer.** The schedules, the metrics textfile, the log pipeline and
  Alertmanager's config used to be checked in both places, so one fault arrived
  as two alerts with two holds and two recoveries. `verify.sh` no longer
  carries its Backups/Monitoring/Metrics/Alerting/Logs sections; its header says
  which section owns each fact now. The placement rule follows: a condition the
  monitor can read directly lives in `monitor.sh`; a check that needs the
  installed stack (the render comparison, the per-prefix proxy probes, the root
  tier's files) lives in `verify.sh`. Its findings are still in the sweep --
  `FAIL` as critical, `warn` as warning (above) -- so moving a check there does
  not make it human-only.

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
  speak.** `scripts/monitor.sh` gives every finding a `component` and a `check`
  and writes `stack_monitor_check{component,check,severity}` plus a
  `stack_monitor_check_detail{component,check,detail}` line carrying its text.
  It also writes one `stack_component_up`/`stack_component_health` sample per
  expected container: down is the root cause, unhealthy the slow half. The
  section still exists as `stack_monitor_section{service,severity}`, but it is
  the human roll-up and history graph, not an alert identity.
  The rules in `deploy/monitoring/rules/stack.yml.in` (rendered to
  `$DATA_DIR/config/monitoring/vmalert/stack.yml`) fire one alert per failing
  component/check after `for: MONITOR_ALERT_FOR`, hold it for `keep_firing_for:
  MONITOR_ALERT_HOLD_S` after the check clears, and pull the detail into the
  annotation with vmalert's `query` template function. `StackComponentDown`
  pages a stopped container at 2 minutes; `StackComponentUnhealthy` warns after
  5. Four checks are rules of their own over a window -- `StackRestartLoop`,
  `StackDiskSaturated`, `StackIdsNoisy`, `StackSshBruteforce` -- because their
  fact is a rate.
  Alertmanager's inhibition is component-scoped: a critical mutes the warning
  for the same `(component, check)`, a down component mutes its dependent
  checks, and the chain's known dependency edges (`bitcoind` -> Fulcrum/
  Lightning/explorers, `monerod` -> wallet/explorer, NPM -> every vhost) get
  their own rules. One dead `btc-explorer` is one page, not a unit fault plus a
  verify failure plus a 502. A `backup` critical also mutes the `backup-verify`
  unit warning: the verifier exited non-zero for the same stale dump, and two
  alerts for one failed drill is exactly what inhibition is for. The route keeps
  one digest per severity
  (`group_by: ['severity']`). A critical waits `group_wait: 1m` for a wave and
  for inhibiting alerts, batches follow-ups for `group_interval: 5m`, reminds
  once a day (`repeat_interval: 24h`), and sends its recovery. A warning goes to
  the `stack-warnings` sub-route instead: `group_wait: 15m`, `group_interval:
  1h`, `repeat_interval: 96h`, and `send_resolved: false`, because warnings are
  the half that flaps. A deploy still wants a silence, not a longer interval.
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
  vmalert persists `ALERTS`/`ALERTS_FOR_STATE` through
  `-remoteWrite.url`/`-remoteRead.url`, so a restart restores the hold-downs and
  does not re-announce a standing fault as new; the restore only reads samples
  from the last hour, so a longer outage or a wiped store still re-arms them.
  **A severity change is a different alertname**, so the old rule
  goes inactive and the new one starts its own `for:` -- but it does not
  *inactivate* at once: `keep_firing_for` holds it, so the flip is one resolve
  for the critical and one fire for the warning, not a pair per sweep. While
  both are active the critical inhibits the warning, so the overlap is silent.
  (2) **`email_configs` defaults `send_resolved: false`**, so a receiver without
  it sends no recovery. That is what the warning route wants; the critical
  receiver sets it, because a recovered page is the useful half.
  (3) **The alert's identity is (component, check), and the text is not a
  label.** Putting the changing message in a label would make "disk 9% free" and
  "disk 8% free" two alerts, and every sweep a state change; it lives in
  `stack_monitor_check_detail` and is fetched at notification time instead. The
  same split is why `for:` replaced the producer-side hold-down: Alertmanager
  only sees what is pushed at it, but vmalert evaluates the query, so it can tell
  a check that fails every other sweep from one that has been down an hour. The
  component is also the inhibition key: a `StackComponentDown` for
  `btc-explorer` mutes the checks whose component is `btc-explorer`, including
  the `verify` and `public_surface` symptoms of that one fault.
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

- **The mail template is stack-owned; the config is not.** `install.sh` copies
  `deploy/monitoring/alertmanager/stack.tmpl` to
  `$CONFIG_DIR/monitoring/alertmanager/templates/` on every run, because it
  carries no secret. It replaces the stock template, which prints every label
  before the annotations and buries the one sentence that says what is wrong;
  this one leads with the detail, makes each semicolon-joined finding a bullet, and
  drops the loopback links. `alertmanager.yml` still holds the SMTP password and
  is seeded once. A template edit is read on `/-/reload` or a restart;
  `unit_config_digest` hashes the directory so `./deploy.sh` restarts
  Alertmanager when the repo copy changes.

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
  deliberately high-churn: `stack_monitor_check_detail`'s label is the check's
  free text, so each distinct message is a short-lived series. It exists so the
  mail can carry the findings, it is bounded by the number of component/check
  pairs (not by traffic), and nothing queries or graphs it. The series and the
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
