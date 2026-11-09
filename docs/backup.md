# Backup, the two drills, and restore

What restic copies, how the snapshot is drilled, and the order a restore has to
follow. Read this before touching `stack.conf`'s `BACKUP_PATHS`, `backup.sh`,
either drill, or `db-dump.sh`. The operator runbooks are README's "Backup &
restore" and "Disaster recovery".

## Invariants

- **The set is declared once, in `stack.conf`**; `install.sh` renders it into the
  unit and `scripts/backup.sh` derives its mounts and arguments from the same
  arrays, so a hand run copies what the nightly job copies.
- **Every live database is a dump, never a file** -- restic reads each file at
  its own instant.
- **The drill's verdict is a file** (`audit/backup-verify.status`), not an exit
  code, because that is what `monitor.sh` reads.
- **Only an unapplied SELinux label is an acceptable restore error**, and it is
  counted, never pinned.
- **Restore before deploy, replay the dump after, migrate last.**
- **The monthly DB drill is separate on purpose**: the weekly run must not depend
  on pulling an image.

## Backup is a oneshot job plus a timer

- **Backup is a oneshot Quadlet job plus a plain user timer.** `backup.container`
  is `Type=oneshot` with **no `[Install]` and no `RemainAfterExit`** (either would
  stop the timer ever firing); `backup.timer` is not Quadlet (it has no `.timer`
  type), so `install.sh` renders it into `~/.config/systemd/user/` and enables it.

## The weekly drill

- **The backup is drilled weekly, and the drill's verdict is a file, not an exit
  code.** `deploy/backup-verify.timer` (Sunday 05:30, two hours clear of the
  nightly job) runs `scripts/backup.sh verify`: `restic check
  --read-data-subset=n/4` with a rotating counter, a `restore --target /restore`
  into `$DATA_DIR/backup-verify` (the live data dirs are **not** mounted, which is
  what makes it safe on a serving host), and assertions that every `BACKUP_PATHS`
  entry came back non-empty plus the `BACKUP_VERIFY_PATHS` markers. Presence is
  not consistency, so the three dumps get content checks on every run: the
  `pg_dumpall` and `mariadb-dump` completion trailers, `PRAGMA quick_check` on
  the restored SQLite copy (run in the NPM image), and a freshness check — each
  dump's mtime (restic preserves them) must sit inside the snapshot's own run, so
  a dump job that has been failing for months cannot pass on the last good file.
  It writes
  `$DATA_DIR/audit/backup-verify.status`, and **that file is what
  `scripts/monitor.sh` reads** — a failed oneshot unit is otherwise just a line
  in `systemctl --user status`. The age check keys on `ok_epoch` (the last
  success), so a drill that skips forever (over `BACKUP_VERIFY_MAX_MB`, or
  without 1.5× the restore size free) fails instead of looking healthy. The
  scratch tree is `trap`-removed on every exit path and must stay out of
  `BACKUP_PATHS`; `--with-db` replays the dump into a throwaway postgres and is
  manual on purpose, because the weekly run must not depend on pulling an image.
  A `--with-db` run whose replay cannot happen (the image is missing, or its pull
  fails) records **`skip`, never `ok`**: `ok_epoch` is the age the monitor keys on,
  so a drill that never replayed must not look like one that did. That is the same
  rule the monthly drill applies to a failed pull, and it is why the kuma replay
  returns rc 2 instead of reporting a missing image as a pass.
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

## The monthly dump drill

- **The dump is drilled monthly, and by a second drill for a reason.**
  `deploy/backup-verify-db.timer` (first Wednesday 06:30 — `Wed *-*-01..07`, not a
  monthly-on-the-1st expression, which can land on the weekly drill's Sunday and
  its restic lock) runs `scripts/backup.sh verify-db`: it restores **only**
  `/data/postgres-dump` (`restore --include`) into `$DATA_DIR/backup-verify-db`,
  checks header, completion trailer and mtime, and replays the dump into a
  throwaway `postgres` — the one claim the weekly run cannot make, because the
  weekly proves mechanics and presence but never that the SQL applies. Three
  decisions carry it. **No `BACKUP_VERIFY_MAX_MB` gate**: a subset restore is a
  few MiB, and inheriting the weekly's gate would stop the proof at exactly the
  set size where a restore matters. **A pull is allowed, and a failed pull is a
  `skip`, never a `fail`**: a registry that will not answer says nothing about
  the dump, so the status file's age check (not the failed run) is what turns a
  run of skips into an alert — the same shape as the weekly's lost-lock skip.
  The image is read from the running `postgres` container, so a Renovate bump
  reaches the drill without an edit here. **Its own status file and scratch
  root** (`audit/backup-verify-db.status`), because one drill's result or
  `ok_epoch` must not mask the other's age. Two mechanics are load-bearing and
  easy to undo: the replay helpers return a code and a message instead of calling
  `die` (a `die` exits with the previous `result=ok` still in the file, i.e. a
  failed drill reading healthy), and an `EXIT` trap records a failure for any
  exit path that wrote no verdict, including the unit's `TimeoutStartSec` kill.
  `monitor.sh` reads the file against `MONITOR_BACKUP_VERIFY_DB_MAX_AGE_H`
  (1080 h). Do not fold this back into `backup-verify`: the weekly run staying
  free of image pulls is the property the split buys.

## Restoring

- **Restore before deploy, replay the dump after, migrate last.** The order is
  load-bearing, not stylistic: `install.sh` seeds `bitcoin.conf` and `torrc` once
  and never overwrites them, so a `./deploy.sh` that runs first writes a *fresh*
  RPC password into `bitcoin.conf` and the restored `config/stack/secrets.env`
  then disagrees with the daemon. Restoring first makes every seed-once file come
  from the snapshot, which is also why `scripts/backup.sh` reads
  `RESTIC_REPOSITORY`/`RESTIC_PASSWORD` from the environment first. The database
  comes back as a file (`postgres-dump/all.sql`): replay it into the empty
  cluster the deploy started, then `./configure.sh --only boltmesh` to
  `alembic upgrade head` — the dump is as old as the snapshot, the code is not.
  The operator steps, the per-scenario runbooks and the post-recovery checklist
  are README's "Disaster recovery"; `scripts/backup.sh restore` writes the whole
  set in place, and a single-path restore is a raw restic invocation documented
  there.

## What is in the set

- **The backup set is declared once, as `BACKUP_PATHS` in `stack.conf`**
  (`cln btcpay tor config npm audit uptime-kuma postgres-dump npm-dump
  uptime-kuma-dump`), and what restic must skip inside it once too, as
  `BACKUP_EXCLUDES` (`audit/auditd.fim` plus the three live database files).
  `install.sh` renders both into `backup.container` (one read-only `Volume=` per
  entry, the path list and the `--exclude` flags in `Exec=`), and
  `scripts/backup.sh` derives its own mounts, restic arguments, restore
  directories and confirmation prompt from the same arrays, so a hand run and the
  nightly job copy the same thing. Chains, the Fulcrum index, `searxng/`,
  `monitoring/`, `logs/` and the raw `postgres/` cluster stay out so restic never
  walks them. `tor/` is in it for `tor/onion/` — a lost key
  is a new `.onion` address.

- **Every live database is backed up as a dump, never as files.** The same
  sentence `postgres-dump.container` carries for `PGDATA` applies to NPM's
  SQLite db and kuma's MariaDB datadir: a file-by-file copy of something a daemon
  is writing is only crash-recoverable, and restic reads each file at its own
  instant, so an InnoDB tree can come back with a redo log and data pages from
  different moments. So `postgres-dump.container` `pg_dumpall`s into
  `$DATA_DIR/postgres-dump`; its libpq settings belong in
  `config/boltmesh/dump.env`, **not** `db.env` (`PGHOST`/`PGUSER` in the server's
  own env break its socket-based entrypoint bootstrap). `scripts/db-dump.sh`
  (run by `db-dump.service`, a plain user unit — the kuma half is `podman exec`,
  which a container cannot do) writes `npm-dump/database.sqlite` through SQLite's
  online backup API and `uptime-kuma-dump/kuma.sql` through `mariadb-dump
  --single-transaction`. Both units are reached through
  `Wants=/After=postgres-dump.service db-dump.service`, but a bare
  `scripts/backup.sh backup` starts them itself (best-effort — a database outage
  must not stop the run that protects the wallet; `monitor.sh` fails on a dump
  that stops being refreshed, `MONITOR_DUMP_MAX_AGE_H`). The repo is
  `$STACK_BACKUP_DIR`, reached
  through `backup.env`; `scripts/backup.sh` reads `RESTIC_*` from **the
  environment first, then the file** — the only order that can recover a fresh
  host.

