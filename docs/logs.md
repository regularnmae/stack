# Logs: journald, vector, victoria-logs

The log pipeline and the traps in reading it back. Read this before touching
`deploy/vector.container`, `vector.toml`, `scripts/logs.sh`, or the podman
event-logger setting. The operator narrative is README's "Logs and history".

## Invariants

- **journald is the source, `vector` the only shipper, `victoria-logs` the
  history.** Neither store is published through NPM: their own APIs have no
  authentication, so the MCP servers are the front doors.
- **`events_logger` is `file`, not `journald`** -- otherwise podman's own health
  checks and execs are most of the journal. `podman logs -f` then stops working
  by podman's own rule; follow with `journalctl -f CONTAINER_NAME=<name>`.
- **`Storage=persistent` takes effect on a flush, not a restart.**
- **`current_boot_only=false` is unsupported on systemd 250-257**; it is pinned
  `true`.
- **An unrecognised NPM log line must be kept, never dropped** (`npm_raw`) --
  silent loss is the failure that source exists to prevent.

## The pipeline

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

## podman's own event log is a config value

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

## Reading the host journal from a container

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

## The other sources

- **Three more sources feed the store, and each needed a correction.** Suricata's
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
  `--priority warning` silently misses every BoltMesh warning. nginx-proxy-manager's
  **access and error logs** are the third source, and the one to reach for when a
  question is about a request rather than a service: NPM terminates TLS, so the
  request exists in those files and nowhere else (Suricata sees ciphertext on the
  wire, and CrowdSec reads the same files but keeps only as long as logrotate
  does -- two days plain, four more gzipped). `sources.npm` globs
  `*_access.log` and `*_error.log` out of `$DATA_DIR/npm/data/logs` (mounted
  `:ro` at `/npm-logs`; the same directory crowdsec mounts, which is the point --
  enforcement and history are two different reads of one record). The remap
  handles three shapes and keeps a fourth rather than dropping it: NPM's custom
  proxy format, combined (the default-host catch-all), nginx's own error-log
  lines (whose `[error]`/`[warn]` becomes `priority`, which is what makes a dead
  upstream a `--priority err` search), and `npm_raw` for anything else -- an
  unrecognised line means the format moved again, and silent loss is the failure
  this source exists to prevent. Error-log timestamps are left at arrival time on
  purpose: nginx writes them in the host's local time with no offset, so a naive
  parse is four hours out on this host. Both file sources set `host` themselves
  -- a file source labels it from the container's hostname, which is neither the
  host nor stable across a recreate, and `host` is a *stream* field.

