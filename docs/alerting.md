# The monitor and alerting

How a fault becomes a page: the host-side sweep, the Alertmanager hop, and the
one place metrics and alerting touch. Read this before touching
`scripts/monitor.sh`, `monitor.env.example`, `alertmanager.yml`, or
`scripts/metrics.sh`. The operator narrative is README's "Monitoring & the spend
tripwire".

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
  hottest sensor, a stale metrics textfile) and the chain/daemon checks (a
  `verify.sh` sweep, bitcoind freshness/peers/mempool, Fulcrum's tip, CLN
  peers/channels, monerod's lag, the wallet's lag).

## Alerting is two processes

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

## The one store query

- **The monitor queries a store exactly once, and only to prove the log
  pipeline is alive.** `scripts/logs.sh --health` (newest entry within
  `MONITOR_LOGS_MAX_AGE_S`, default 900) is the one exception to "alerting never
  queries the pipeline": the failure it catches is the pipeline's own silent
  death, and a failure there can only *add* an alert. Everything else still
  reads the daemons and the host directly.

