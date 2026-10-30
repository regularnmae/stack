# stack

The whole server stack for the mainnet host, in one repo: every podman/quadlet
unit, every secret/env wiring, and a one-click deploy that can rebuild the host
from scratch.

The application code lives in sibling repos — `searxng-mcp`,
`bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`, `lightning-mcp`,
plus BoltMesh's `backend` and `frontend` (under the `boltmesh-labs` org) — each
of which ships only its code, tests, CI and `Containerfile`. **Their units
and env files live here**, so there is exactly one place that defines how the
stack runs and one script that fixes a deployment problem.

## What runs

| Unit | Image | Published on the host | Data |
| --- | --- | --- | --- |
| `bitcoind` | `docker.io/lncm/bitcoind:v28.0` | — | `$DATA_DIR/bitcoin` |
| `monerod` | `ghcr.io/sethforprivacy/simple-monerod:v0.18.5.4` | — | `$DATA_DIR/monero` |
| `fulcrum` | `docker.io/cculianu/fulcrum:v2.1.4` | `50001`, `50002` | `$DATA_DIR/fulcrum` |
| `btc-explorer` | `localhost/btc-explorer:local` (built from `btc-explorer/Containerfile`) | `127.0.0.1:8108` | — |
| `xmr-explorer` | `localhost/xmr-explorer:local` (MoneroBlock, built from `xmr-explorer/Containerfile`) | `127.0.0.1:8109` | — |
| `monero-wallet-rpc` | `ghcr.io/sethforprivacy/simple-monero-wallet-rpc:v0.18.5.4` | `127.0.0.1:18083` | `$DATA_DIR/monero-wallet-rpc` |
| `lightningd` | `docker.io/elementsproject/lightningd:v26.06.9` | `127.0.0.1:3010` (clnrest) | `$DATA_DIR/cln` |
| `tor` | `localhost/tor:local` (built from `tor/Containerfile`) | — | `$DATA_DIR/tor` |
| `valkey` | `docker.io/valkey/valkey:9.1.3-alpine` | — | — |
| `searxng` | `docker.io/searxng/searxng:2026.10.29-cff884f98` | `127.0.0.1:8080` | `$DATA_DIR/searxng` |
| `nginx-proxy-manager` | `docker.io/jc21/nginx-proxy-manager:2.16.0` | `80`, `443`, `81` | `$DATA_DIR/npm/{data,letsencrypt}` |
| `netcheck`, `netcheck-host` | `localhost/netcheck:local` (built from `netcheck/Containerfile`) | — | — |
| `uptime-kuma` | `docker.io/louislam/uptime-kuma:2` | `127.0.0.1:8107` | `$DATA_DIR/uptime-kuma` |
| `victoriametrics` | `docker.io/victoriametrics/victoria-metrics:v1.155.0` | `127.0.0.1:8428` | `$DATA_DIR/monitoring/vm` |
| `node-exporter` | `docker.io/prom/node-exporter:v1.12.1` | host network, `:9100` (wildcard bind; LAN closed by firewall) | — (serves `$DATA_DIR/monitoring/textfile`) |
| `victoria-logs` | `docker.io/victoriametrics/victoria-logs:v1.53.0` | `127.0.0.1:9428` | `$DATA_DIR/logs/vl` |
| `vector` | `docker.io/timberio/vector:0.61.0-debian` | — | `$DATA_DIR/logs/vector` (checkpoint) |
| `searxng-mcp` | `localhost/searxng-mcp:latest` | `127.0.0.1:8100` | — |
| `bitcoin-node-mcp` | `localhost/bitcoin-node-mcp:latest` | `127.0.0.1:8101` | — |
| `monero-node-mcp` | `localhost/monero-node-mcp:latest` | `127.0.0.1:8102` | — |
| `monero-wallet-mcp` | `localhost/monero-wallet-mcp:latest` | `127.0.0.1:8103` 🔑 | — |
| `lightning-mcp` | `localhost/lightning-mcp:latest` | `127.0.0.1:8104` 🔑 | — |
| `postgres` | `docker.io/library/postgres:18-alpine` | — | `$DATA_DIR/postgres` |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `127.0.0.1:8105` | — |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | — | — |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | `127.0.0.1:8106` | — |
| `crowdsec` | `docker.io/crowdsecurity/crowdsec:v1.8.2` | — | `$DATA_DIR/ids/crowdsec` |
| `suricata` ⚙️ | `docker.io/jasonish/suricata:8.0.8` | host network (IDS only, publishes nothing) | `$DATA_DIR/ids/suricata` |
| `stack-bouncer` ⚙️ | — (a host script on a system timer, `deploy/root/bouncer.sh`) | — (writes the `inet stack_bans` nft set) | `$DATA_DIR/audit/bouncer.status` |

`bitcoind` and `monerod` are **full (archival) nodes**, storing and validating
the whole chain; `fulcrum` indexes that chain for Bitcoin wallets over the
Electrum protocol. See [Full nodes and disk](#full-nodes-and-disk) before sizing
the data disk. The two explorers read those services rather than keeping a
chain of their own — see [Block explorers](#block-explorers).

**Every pulled image is pinned to a tag, and Renovate watches the tags** —
`postgres` is the one deliberate exception, hand-pinned and untracked. Merging
one of those PRs changes nothing on the host: a unit keeps
running its old image until it is restarted, and
`./deploy.sh --only <service>` is what pulls the new tag (podman only pulls a
*missing* image, so nothing upgrades on its own; the backup job, which runs on a
timer rather than a restart, picks up a merged restic bump by itself). Back up
before `lightningd` (CLN's wallet migrations are forward-only), move `monerod`
and `monero-wallet-rpc` together (an upgrade is driven by a hardfork height, and a
wallet older than its daemon is unsupported), then run `./verify.sh`.

**Only `nginx-proxy-manager` is reachable from the LAN over HTTP.** It runs on
the **host network** (`Network=host`), so its own nginx binds `80`/`443`/`81` in
the host's namespace — nothing is port-forwarded for it, and a request therefore
arrives with the client's real address. That is what its access log, its fail2ban
surface and the `X-Forwarded-For` it sets on the way to an app need. A
*published* port
cannot do that on a rootless build: podman's `rootlessport` forwards from inside
the rootless namespace, so NPM logged its own container IP (`10.89.0.5`) for
every client. Podman ≥ 6.0 can forward with `pasta` instead
(`rootless_port_forwarder="pasta"` under `[network]` in
`~/.config/containers/containers.conf`), which does preserve the source address,
but Rocky 10's podman 5.8 has no such key.

Because NPM is no longer a peer on `npm-network` (`10.89.0.0/24`, pinned in
`deploy/npm-network.network` because `tor.container` pins `--ip=10.89.0.240` and
both `bitcoin.conf` and `torrc` allow that subnet), it cannot resolve a container
name. The four containers behind onion services also pin their IPs
(`10.89.0.241`–`.244`) for a related reason: tor validates a
`HiddenServicePort` target at startup, so a container *name* that does not exist
yet would keep tor from starting at all. Every unit it proxies to therefore publishes its port on the **host's
loopback** only — the `127.0.0.1:…` entries above, i.e.
`PublishPort=127.0.0.1:…` in that unit — and `NPM_HOSTS`/`MCP_HOSTS` in
`stack.conf` name `127.0.0.1`, not a container. A loopback bind is invisible to
the LAN, so NPM (which terminates TLS) plus each server's bearer token are still
the one way in for a client. The host-side checks (`verify.sh`, the monitor) read
the services by container name on `npm-network`, through `net_curl` in
`scripts/lib.sh`, which execs into the long-lived **`netcheck`** container
(`netcheck/Containerfile`); `net_curl_host` uses **`netcheck-host`**, the same
image on the host network, for NPM's own admin API on `127.0.0.1:81`. The proxy
hosts are declared in `NPM_HOSTS`
(`stack.conf`) and reconciled from this repo by `scripts/npm-hosts.sh` — see
[Proxy hosts (nginx-proxy-manager)](#proxy-hosts-nginx-proxy-manager). The hosts
themselves live in NPM's database, not in this repo.

Only `80`, `443` and `81` (NPM) are opened on the LAN (`FIREWALL_PORTS` in
`stack.conf`), plus Fulcrum's Electrum ports `50001` (TCP) and `50002` (SSL) —
the one deliberate exception, because the Electrum protocol is raw TCP and NPM
cannot proxy it. The loopback publishes are not opened, and another machine
cannot reach them. Point a Bitcoin wallet at this host on `50001`/`50002`; the
SSL certificate is self-signed and generated in `$DATA_DIR/fulcrum`.

The same public hostnames are also published as **Tor onion services** from
the same `tor` unit that lightningd already uses as its SOCKS proxy — no extra
container, no DNS and no certificate needed. See
[Tor onion services](#tor-onion-services).

> **Upgrading from the published-port layout.** The proxy hosts are rewritten to
> `127.0.0.1` upstreams, which only work once NPM itself is on the host network,
> so `./deploy.sh` rewrites them *first* and restarts NPM afterwards. That order
> is load-bearing: NPM's nginx resolves every upstream when it starts, so a saved
> host still naming a container keeps its nginx down — and the admin UI on `81`
> is served by that same nginx. A plain `./deploy.sh` also restarts every unit
> whose rendered file changed (`searxng`, the daemons, the whole app tier), so it
> is the only command needed. If NPM was restarted by hand first, park the
> generated configs (the database is the real source of truth; the next reconcile
> rewrites them) and re-run:
>
> ```sh
> mkdir -p /tmp/npm-proxy-host-parked
> mv "$DATA_DIR"/npm/data/nginx/proxy_host/*.conf /tmp/npm-proxy-host-parked/
> ./deploy.sh --only npm-hosts
> ```

🔑 = a money-moving surface. Spending is **off** by default on both.
⚙️ = the stack's only rootful unit (needs `CAP_NET_RAW` to capture packets);
everything else runs rootless. See [Intrusion detection](#intrusion-detection).

A nightly, encrypted restic backup of the irreplaceable state (`cln/`,
`monero-wallet-rpc/`, `tor/`, `config/`, `npm/`, `audit/`, and the BoltMesh
database as a `pg_dumpall`) runs from `backup.timer` into
`$STACK_BACKUP_DIR`, and `backup-verify.timer` restores one snapshot a week to
prove it works. It is the one thing that recovers you if the data disk
itself is lost — see [Backup & restore](#backup--restore) and the
[Disaster recovery](#disaster-recovery) runbooks.

A health monitor and spend tripwire run every five minutes from `monitor.timer`;
they alert (and fail a dead-man's-switch heartbeat) once you fill in
`$DATA_DIR/config/monitoring/monitor.env`. See
[Monitoring & the spend tripwire](#monitoring--the-spend-tripwire).

## One-click install

On a truly bare Rocky Linux 10 host (no git, no podman):

```sh
curl -fsSL https://raw.githubusercontent.com/regularnmae/stack/main/bootstrap.sh | bash
~/build/stack/deploy.sh
```

`bootstrap.sh` installs podman/firewalld/git/jq, enables user linger, sets
`net.ipv4.ip_unprivileged_port_start=80` (so nginx-proxy-manager can bind
80/443/81 rootless), opens the stack's ports (`FIREWALL_PORTS`) in firewalld,
makes journald persistent and bounded (so the container logs survive a reboot
and the log store has something to collect), creates the build dir and the
quadlet directory, and clones this repo to `~/build/stack`. `deploy.sh` then
resolves and creates the data directories, clones the app repos, builds every
image, starts everything in order and verifies.

With git already present, the equivalent is:

```sh
git clone https://github.com/regularnmae/stack ~/build/stack
cd ~/build/stack
./bootstrap.sh
./deploy.sh           # or: ./deploy.sh --bootstrap to do both in one step
```

`bootstrap.sh` uses `sudo` for the privileged host setup (packages, linger, the
sysctl, firewalld); `sudo` needs a terminal to prompt, so run it from an
interactive shell (over SSH, `ssh -t`). `deploy.sh` and `verify.sh` never use
`sudo`.

On the first run, `deploy.sh` asks **where the stack keeps its data** (default
`$HOME/data`) and remembers the answer; point it at a separate disk to survive
an OS reinstall. See [Where the data lives](#where-the-data-lives).

`deploy.sh` is idempotent and never destructive: re-running reuses every
existing secret, leaves the running daemons alone, and rebuilds + restarts the
five MCP servers and the BoltMesh app tier (a plain start would keep running a
stale image). The five images built here — the two explorers, `kuma-ctl`,
`netcheck` and `tor` — are rebuilt when their Containerfile changed and left
alone otherwise: the digest of that file is baked into the image as a label, so
a merged base-image bump reaches the host on the next deploy instead of needing
a hand rebuild (`--only` forces one anyway). Common flags:

```sh
./deploy.sh --only bitcoin-node-mcp   # rebuild and restart one service
./deploy.sh --only boltmesh           # rebuild + migrate the whole BoltMesh tier
./deploy.sh --only explorers          # rebuild both explorer images
./deploy.sh --only backup             # run the backup job now
./deploy.sh --only backup-verify      # run the restore drill now (weekly on a timer)
./deploy.sh --only monitor            # run the health + spend checks now
./deploy.sh --only npm-hosts           # re-apply every proxy host in NPM
./deploy.sh --only tor                 # re-render the onion services and restart tor
./deploy.sh --skip-apps               # infrastructure only (daemons, searxng, NPM)
./deploy.sh --no-wallets              # skip the interactive wallet prompts
./deploy.sh --dry-run                 # print the plan, change nothing
./verify.sh                           # container health, MCP handshakes, onion fetches
./scripts/monitor.sh                  # the scheduled health + spend sweep, by hand
./scripts/metrics.sh                  # one metrics collection (metrics.timer runs it)
```

The first run also builds the two explorers. Both are small local builds
(MoneroBlock is Go, BTC RPC Explorer is Node), so the stack is already up while
they build (see [Block explorers](#block-explorers)).

Chain sync takes hours to days on a truly bare host: both daemons are **full
(archival) nodes**, so the first start downloads and validates the whole Bitcoin
and Monero chains. `fulcrum` starts indexing from `bitcoind`'s RPC as soon as it
answers and follows the node through initial block download; it only accepts
wallet connections once its own index has caught up (watch `podman logs fulcrum`).
See [Full nodes and disk](#full-nodes-and-disk) for the disk budget.
`deploy.sh` starts the containers and does **not** wait for sync — re-run it once
the chains are current and anything that was waiting (notably the CLN runes)
completes.

### Wallets

A bare host has no wallets. `deploy.sh` prompts:

- **Monero** — create a new wallet (and print its 25-word seed once) or restore
  an existing one from its seed. This must exist before `monero-wallet-rpc`
  starts, so it happens between `monerod` and the wallet RPC.
- **Bitcoin** — create a new descriptor wallet or restore from a `.dat` backup.

Both are skipped when there is no TTY. See `scripts/wallets.sh`.

### Electrum (Bitcoin wallet)

`fulcrum` serves the Bitcoin wallet interface at this host's **`50001`** (plain
TCP) or **`50002`** (SSL, self-signed) — not through nginx-proxy-manager, because
the Electrum protocol is not HTTP. Point Sparrow/Electrum at it once
`podman logs fulcrum` shows the index caught up; the node and the indexer can
sync at the same time, but a wallet must not rely on a partial index. On an
existing host, re-run `./bootstrap.sh` (or open `50001`/`50002` in firewalld
yourself) so the new ports reach the LAN.

Its container healthcheck is the process table and nothing else, on purpose: a
first index legitimately refuses wallets for hours, so the unit must not go red
for it. The index is checked from outside instead —

```sh
./verify.sh --deep        # asks 50001/50002 for the Electrum banner, then compares
                          # the tip Fulcrum reports with bitcoind's height
./scripts/monitor.sh      # pages when the gap passes MONITOR_FULCRUM_LAG_BLOCKS
```

— because a wedged index keeps the process alive, the port open and
`server.version` answering, so the height is the only thing that says whether
wallets are being served *current* data.

### Block explorers

Two read-only web explorers are served behind nginx-proxy-manager:

- **BTC RPC Explorer** at `https://$BTC_EXPLORER_HOST` (`BTC_EXPLORER_HOST`,
  default `btc.boltmesh.net`). It reads `bitcoind` over RPC and uses the
  existing `fulcrum` for address history, so it adds no index and no second
  chain scan. Because `bitcoin.conf` keeps `txindex=0`, an **address** lookup
  works through Fulcrum and a transaction in the last few blocks is found by
  txid, but an older txid needs its block height. Enabling `txindex=1` would
  remove that limit at the cost of another full-chain index; the stack
  deliberately does not. Until Fulcrum's index has caught up, the explorer logs
  `ECONNREFUSED fulcrum:50001` and its address pages fail; block/transaction
  pages (bitcoind RPC) already work.
- **MoneroBlock** at `https://$XMR_EXPLORER_HOST` (`XMR_EXPLORER_HOST`,
  default `xmr.boltmesh.net`). It is a trustless, **RPC-only** explorer: blocks,
  transactions and network info come from monerod's restricted RPC (18089), so
  it needs no chain mount, no LMDB reader and no local index, and keeps no
  state of its own. Its UI is narrower than the Onion Monero explorer's
  (no ring/mixin or address-proof pages), but it is stateless and its image is
  a small Go build. Its healthcheck and status monitor use the static
  `/style.css`; the home page calls monerod's RPC, which can be slow enough to
  time out while the node is in initial sync (`verify.sh` warns instead of
  failing in that window).

Both images are built locally from `btc-explorer/Containerfile` and
`xmr-explorer/Containerfile`; they are not pulled. `./deploy.sh` builds each
only when the image is missing. Neither needs a Monero compile:
MoneroBlock is Go and BTC RPC Explorer is Node, so both builds are quick.
`./deploy.sh --only xmr-explorer` (or `--only explorers`) forces a rebuild,
and `--only btc-explorer` does the same for the Bitcoin one. The explorer
commits are pinned in their Containerfiles; Renovate's dockerfile manager
tracks the base images, and custom git-refs managers track both pinned commits.

Both hosts redirect HTTP to HTTPS and carry a Let's Encrypt certificate like the
rest of the public surface, and both are mirrored as onion services. The BTC
explorer is public; set `BTCEXP_BASIC_AUTH_PASSWORD` in
`$DATA_DIR/config/btc-explorer/btc-explorer.env` and re-run
`./deploy.sh --only btc-explorer` to put it behind basic auth (any username,
that password). `verify.sh` asks each explorer for its chain height, which
proves the path through to its daemon (the BTC check degrades to a warning when
basic auth is on).

## Where the data lives

Everything the stack must not lose sits under **one directory**, `$DATA_DIR`
(`STACK_DATA_DIR`, default `$HOME/data`). `deploy.sh` asks for it once and
remembers the answer in `~/.config/stack/data-dir.env`:

  - `bitcoin/ monero/ fulcrum/ monero-wallet-rpc/ cln/ tor/ searxng/` — daemon state
    (`tor/onion/` holds the onion services' keys, `tor/torrc` the config; `fulcrum/`
    is the Electrum index and its self-signed certificate, regenerable and excluded
    from backups)
  - `npm/{data,letsencrypt}` — nginx-proxy-manager
  - `uptime-kuma/` — the status page's state (sqlite, history; configured in its UI)
  - `postgres/` — the BoltMesh database (dumped before backup, not copied raw)
  - `postgres-dump/` — the pre-backup `pg_dumpall`
  - `config/` — every bearer token and secret
  - `audit/` — the monitor's log and the spend tripwire baselines
  - `monitoring/` — the metrics store (`vm/`) and node-exporter's textfile
    (both regenerable, both excluded from backups)
  - `logs/` — the log store (`vl/`) and `vector`'s checkpoint; journald history,
    regenerable and excluded from backups
  - `backup-cache/` — restic's cache (regenerable)
  - `backup-verify/` — the restore drill's scratch target; a copy of the backup
    set, wiped before and after every drill (regenerable, excluded from backups)

The explorers keep no data directory: both are stateless and read their daemon
over RPC. Their only persistent input is
`config/btc-explorer/btc-explorer.env` (the Bitcoin node/Fulcrum wiring);
MoneroBlock needs no env file.

The backup *repository* lives outside `$DATA_DIR`, in `$STACK_BACKUP_DIR`
(default `$HOME/data-backup`), so wiping the data dir does not delete it — see
[Backup & restore](#backup--restore).

Point it at a separate disk and an OS reinstall only has to keep that one
directory. `deploy.sh` never uses `sudo`: it creates the path when its parent is
writable, and for a path it cannot prepare (a separate disk with a root-owned
parent) it prints the one-time commands instead:

```sh
sudo mkdir -p /data/stack && sudo chown "$(id -u):$(id -g)" /data/stack
```

When SELinux is enforcing, the dir must be labelled for containers. The units
mount their subdirectories with `:z`/`:Z`, which podman relabels rootlessly on
every start, so `deploy.sh` only needs a top-level label and attempts it
unprivileged. If the path is not yours to relabel (a freshly formatted disk is
often `unlabeled_t`), it prints the root commands:

```sh
sudo semanage fcontext -a -t container_file_t "/data/stack(/.*)?"
sudo restorecon -RF /data/stack
```

### Full nodes and disk

`bitcoind` and `monerod` are **full (archival) nodes**: both store and validate
the entire chain, which dominates the data dir — roughly 800 GB for Bitcoin and
250 GB for Monero as of late 2026, both growing. Fulcrum's Electrum index adds
roughly 100–135 GB and ~3–4 GB of RAM (`--db_mem 3072` caps its RocksDB cache;
a rebuild is compaction-bound below that). Budget a 2 TB data disk. The chains
and the index are excluded from the backup set for exactly this reason: they are
large and re-downloadable, not irreplaceable state.

The data dir sits on a rotational disk in this layout, which is fine for serving
but not for building: a Fulcrum index that has to be rebuilt from block 0 runs
at roughly 40 blocks/min there, and it serves no wallets until it finishes. If
that is too slow for you, give `$DATA_DIR/fulcrum` a separate SSD before
starting the rebuild — don't wait for a resync to finish and then move it.

## Reinstalling the host without re-syncing

With the data dir on a separate disk (e.g. `/data/stack`), a Rocky reinstall on
the system disk keeps the chains, the Electrum index, wallets, CLN identity and
every token:

1. Reinstall the OS. Do **not** touch the data disk.
2. Make sure it is mounted at the same path again (`/etc/fstab` — a reinstall
   rewrites fstab), then:

   ```sh
   git clone https://github.com/regularnmae/stack ~/build/stack
   cd ~/build/stack
   ./bootstrap.sh
   ./deploy.sh                 # answer the data-dir prompt with /data/stack
   ./verify.sh --deep
   ```

`deploy.sh` finds the existing
`bitcoin/ monero/ fulcrum/ monero-wallet-rpc/ cln/ tor/ npm/ config/` there
(labelling the path for containers if it has to) — so nothing re-syncs, the
wallet still opens (its password is in `config/stack/secrets.env`), and the
client tokens are
unchanged.

That is the *lucky* reinstall: the data disk survived. If it did not — a lost
disk, a new host, a compromised machine — the chains and the index have to be
rebuilt and the state comes out of the backup repository: see
[Disaster recovery](#disaster-recovery).

## Backup & restore

`install.sh` installs a nightly, encrypted [restic](https://restic.net) backup of
the things in `$DATA_DIR` that cannot be re-downloaded:

- `cln/` — the CLN node identity, channel state and onion keys
- `monero-wallet-rpc/` — the Monero wallet (funds)
- `tor/` — `torrc` and the onion services' keys, which are what make every
  `.onion` address stable (see [Tor onion services](#tor-onion-services))
- `config/` — every token, rune and secret
- `npm/` — nginx-proxy-manager's config and TLS material
- `audit/` — the monitor's log and the spend tripwire baselines (see
  [Monitoring & the spend tripwire](#monitoring--the-spend-tripwire))
- `uptime-kuma/` — the status page's own state (its monitors, history and login;
  UI-configured, see [Status page](#status-page))
- `postgres-dump/` — `pg_dumpall` of the BoltMesh database, taken by
  `deploy/postgres-dump.container` immediately before each backup run (the raw
  `postgres/` cluster is not copied: a file-by-file copy of a live `PGDATA` is
  only crash-recoverable)

The chains (`bitcoin/`, `monero/`), the Electrum index (`fulcrum/`), `searxng/`,
the two explorers (stateless, RPC-only) and the raw `postgres/` cluster are
deliberately **excluded**: they are large and regenerable, so restic never walks
them.

That set is declared **once**, as `BACKUP_PATHS` in `stack.conf`. `install.sh`
renders it into the job's mounts and its `Exec=`, and `scripts/backup.sh` derives
its own mounts, restic arguments and restore prompt from the same array — so a
hand run copies exactly what the nightly run copies, and adding a directory is a
one-line edit in `stack.conf` rather than four edits in two files.

- `deploy/backup.container` — the one-shot job (a Quadlet unit, rendered like
  the rest).
- `deploy/backup.timer` — the schedule (`*-*-* 03:30:00`, plus 30 min of
  jitter). Quadlet has no `.timer` type, so this is an ordinary systemd **user**
  unit at `~/.config/systemd/user/backup.timer`, enabled by `install.sh`.
- `deploy/backup-verify.service` + `deploy/backup-verify.timer` — the weekly
  restore drill (below), also plain user units.
- `scripts/backup.sh` — run it by hand and inspect what you have:
  `backup | init | list | ls | check | verify | forget | restore <snap> | unlock`.
  `ls [<snap>]` lists the paths inside a snapshot, which is how you prove a
  given run really holds the database dump and not just the wallet. `backup`
  also takes the same pre-backup `pg_dumpall` as the unit (it starts
  `postgres-dump.service` when that unit is installed), because a hand run has
  none of the unit's `Wants=` ordering.
- `./deploy.sh --only backup` runs the job once, now.

The repository defaults to the host directory `$STACK_BACKUP_DIR` (default
`$HOME/data-backup`, from `stack.conf`) mounted at `/repo`. It sits outside
`$DATA_DIR`, so wiping the data dir leaves it alone — but a same-disk repo will
not survive the disk itself. For real disaster recovery point `RESTIC_REPOSITORY`
in `$DATA_DIR/config/backup/backup.env` at an offsite target (`s3:`, `b2:`,
`sftp:`) — restic works with all of them.

**Keep a copy of `RESTIC_PASSWORD` (same file) somewhere other than the data
disk.** It encrypts the whole repository: no password, no restore. The helper
reads the repository and password from the **environment first**, then the file,
which is what makes recovery possible at all — the backed-up `backup.env` lives
inside the repository, so it cannot be the only source of the key that opens it.

### Disaster recovery

Four things decide whether a bad day costs an afternoon or a week: the
repository is **off the data disk**, `RESTIC_PASSWORD` is **off the host**, the
Monero seed is **on paper**, and you restore **before** running `./deploy.sh`.
The runbooks below assume all four; the last one covers losing them.

#### Before you need it

- `RESTIC_REPOSITORY` and `RESTIC_PASSWORD`, in a password manager or on paper.
  They encrypt and locate everything else; without them nothing here is
  recoverable. Point the repository at an offsite target (`s3:`, `b2:`,
  `sftp:`) — a same-disk repository survives deletion, not the disk.
- The Monero **25-word seed**, written down when the wallet was created. The
  wallet file is in the backup, but the seed is what survives losing both.
- An SSH key that can clone the private `boltmesh-labs` repos, and DNS for the
  public hostnames (nginx-proxy-manager requests their certificates).
- Nothing else: `config/`, `tor/onion/`, `cln/` and the wallet all come out of
  the repository, and `scripts/backup.sh` reads the location and password from
  the environment first for exactly this reason.

#### Pick the runbook

| What happened | Go to | Lost since the snapshot |
| --- | --- | --- |
| bad config, torn wallet cache, lost onion key, broken CLN state — disk fine | [State is wrong, disk is fine](#state-is-wrong-disk-is-fine) | that state only |
| data disk lost, host replaced, OS reinstalled onto a new disk | [The data disk is gone](#the-data-disk-is-gone-or-a-new-host) | everything written after it |
| host compromised | [The host was compromised](#the-host-was-compromised) | everything, plus every credential |
| repository or its password lost | [When a piece is missing](#when-a-piece-is-missing) | whatever is not off-host |

#### State is wrong, disk is fine

Restoring **in place** is safe as long as nothing is writing to the directories
being replaced, so stop the daemons that own them — they are the ones whose
data is in the backup set:

```sh
systemctl --user stop lightningd monero-wallet-rpc tor nginx-proxy-manager uptime-kuma
./scripts/backup.sh ls latest      # what the snapshot holds, before overwriting anything
./scripts/backup.sh restore latest # in place; add -y when there is no TTY
./deploy.sh                        # adopts, re-renders, restarts, reconciles, verifies
./verify.sh --deep
```

`restore` writes the whole set, which is the right default: the snapshot is the
source of truth, and a partly-restored host is how you get two versions of the
same secret. For one path only — a lost `tor/onion/`, a corrupted
`config/stack/secrets.env` — mount just that directory and ask restic for just
that path (the environment file supplies the repository, password and cache):

```sh
podman run --rm \
  -v "$HOME/data-backup:/repo:z" -v "$DATA_DIR/backup-cache:/cache:z" \
  -v "$DATA_DIR/config:/data/config:z" \
  --env-file "$DATA_DIR/config/backup/backup.env" \
  docker.io/restic/restic:0.19.1 restore latest --target / --include /data/config
```

Then restart what reads it (`./deploy.sh` for config, `./deploy.sh --only tor`
for the onion keys). Keep the single-directory mount: a target of `/` with the
whole data dir mounted is an in-place restore of everything, which is the
previous runbook.

#### The data disk is gone (or a new host)

Order is load-bearing: **restore, then deploy.** `install.sh` seeds
`bitcoin.conf` and `torrc` once and never overwrites them, so a `./deploy.sh`
that runs first writes a *fresh* RPC password into `bitcoin.conf`, and the
restored `config/stack/secrets.env` then disagrees with the daemon. Restoring
first means every seed-once file is derived from the snapshot.

1. Rebuild the host and the data disk, then get this repo:

   ```sh
   git clone https://github.com/regularnmae/stack ~/build/stack
   cd ~/build/stack
   ./bootstrap.sh
   ```

2. Open the repository **from the environment** (there is no `backup.env` on a
   fresh host — that is why the order is environment first), and prove the
   password before writing anything:

   ```sh
   export RESTIC_REPOSITORY=s3:…   # or /repo, or the path of a copied repository
   export RESTIC_PASSWORD=…        # from your password manager
   ./scripts/backup.sh list        # a snapshot list here means the repo and key are right
   ```

3. Restore into the data dir. Setting `STACK_DATA_DIR` for this one command
   both places the files and remembers the answer, so `deploy.sh` will not
   prompt later:

   ```sh
   STACK_DATA_DIR=/data/stack ./scripts/backup.sh restore latest -y
   ```

   It writes `cln/`, `monero-wallet-rpc/`, `tor/`, `config/`, `npm/`, `audit/`,
   `uptime-kuma/` and `postgres-dump/`, and hands the wallet directory back to
   the image uid, so `monero-wallet-rpc` opens it directly.

4. Deploy. This adopts the restored secrets (never overwriting an existing
   file), seeds `bitcoin.conf`/`torrc` from them, builds the images, proves the
   restored CLN runes with `checkrune` (minting new ones if the node does not
   know them), re-derives `config/boltmesh/gateway.env`, and reconciles the
   proxy hosts and the status page:

   ```sh
   ./deploy.sh
   ```

5. Replay the database. It comes back as a file, not a running server, and the
   `postgres` that `deploy.sh` started is empty:

   ```sh
   systemctl --user stop boltmesh-backend.service boltmesh-worker.service
   podman exec -i postgres psql -U vpnuser -d postgres < "$DATA_DIR/postgres-dump/all.sql"
   ./deploy.sh --only boltmesh     # alembic upgrade head, then start the API + worker
   ```

   The dump was taken with `pg_dumpall --clean --if-exists`, so it recreates the
   `vpndb` database itself. It also carries the role, which already exists on a
   host whose `postgres/` was just initialised with the same credentials:
   `psql` reports those role errors (`already exists`, or a role it will not
   drop while you are connected as it), carries on because it is not run with
   `ON_ERROR_STOP`, and the database load is what matters. Confirm the schema
   landed with `podman exec postgres psql -U vpnuser -d vpndb -c '\dt'`, then
   migrate: the dump is as old as the snapshot, and the code is not.

6. Check it with [After any recovery](#after-any-recovery). The chains and
   Fulcrum start from zero — see [What comes back](#what-comes-back-what-re-downloads)
   for what that costs in time.

#### The host was compromised

Assume every secret in the snapshot is known to whoever had the host: restoring
it is the fastest way back, not a recovery. Follow the runbook above, then treat
every credential as burned:

```sh
./scripts/rotate.sh --list            # what this repo can rotate
./scripts/rotate.sh --dry-run <target>
./scripts/rotate.sh <target>          # write, re-render, restart, prove
```

That covers every target `--list` shows: the RPC passwords, the CLN runes, the
MCP tokens, SearXNG's key, the postgres role, BoltMesh's keys, the restic key
and the wallet password. Two preflights will stop you on a host that was just
restored, on purpose:

- `monero-wallet` refuses without a snapshot younger than 24 h (and `--yes`).
  Take one first (`./deploy.sh --only backup`) rather than reaching for
  `--force`: the new password is the one value nobody can recover.
- `restic` adds the new key, proves it, and only then removes the old one, so a
  run that dies in between leaves two working keys, not none.

What rotation cannot fix, and what to do instead:

- **The wallet's keys**, not just its password. A fresh password does not
  un-share the file. Create a new wallet from a new seed and sweep the funds
  into it; the restored file is burned.
- **CLN's `hsm_secret`**, which is the node's signing key. Treat the channels as
  lost: force-close them yourself so the funds land in a wallet you control, and
  open new channels from a fresh node.
- **The old snapshots.** Rotating the restic key protects new snapshots; the old
  password still opens everything already in the repository. Start a fresh
  repository, or accept that the old snapshots are readable.
- **The onion addresses.** Nothing rotates them; if the old keys must be
  considered public, delete `tor/onion/<name>/` so tor generates new ones, then
  tell every client — the address is the key.
- **Anything the tokens grant outside this stack** — revoke those at the
  provider.

#### When a piece is missing

- **The repository is gone** and there is no offsite copy: nothing in it is
  recoverable. The stack comes back with new identities — a new CLN node, new
  onion addresses, a new wallet (funds only from the seed) — and every token
  re-issued, so every client must be updated. This is the case `s3:`/`b2:`
  exists to prevent.
- **`RESTIC_PASSWORD` is gone**: the repository is unreadable. No recovery, no
  workaround.
- **`tor/onion/` is gone**, the rest restored: every `.onion` address changes.
  The wildcard `*.onion` proxy host keeps working, but clients holding the old
  address do not.
- **`cln/` is gone**, `config/` restored: a new node identity. The runes in
  `config/lightning-mcp/node.env` are dead; `./deploy.sh` proves them with
  `checkrune` and mints new ones, and the MCP servers restart with the new
  values. The channels are gone with the `hsm_secret` — CLN has no seed phrase,
  which is why `cln/` is the most valuable directory in the set.
- **`monero-wallet-rpc/` is gone**, `config/` restored: the password is there
  but the wallet is not. Run `scripts/wallets.sh --monero` and choose restore;
  it rescans from the restore height you give it.

#### What comes back, what re-downloads

| Path | Backed up | After a fresh-host restore |
| --- | --- | --- |
| `config/`, `tor/`, `npm/`, `audit/`, `uptime-kuma/` | yes | exactly as snapshotted |
| `cln/` | yes | channels as of the snapshot; an older state can force-close |
| `monero-wallet-rpc/` | yes | opens directly; may rescan against `monerod` |
| `postgres-dump/all.sql` | yes | a file — replay it (step 5) |
| `bitcoin/` | no | re-download; `bitcoin.conf` is seeded from the restored secret |
| `monero/` | no | re-download |
| `fulcrum/` | no | re-index from block 0: weeks on this disk (see [Full nodes and disk](#full-nodes-and-disk)) |
| `searxng/`, `monitoring/` | no | recreated; the metrics history is gone |
| `postgres/` | no | a new cluster, then the dump is replayed into it |
| the bitcoind wallet | no | a new empty descriptor wallet (export a `.dat` if you keep funds there) |

Rough order of magnitude on a rotational disk: bitcoind validation is days to
weeks, monerod a few days, Fulcrum's index weeks. All three run at the same
time, and none of them blocks the wallet, CLN, BoltMesh or the MCP surface from
coming up — the stack is *serving* long before it is *synced*.

> **Consistency:** the job snapshots `cln/` and the wallet while their daemons
> are running. CLN's `hsm_secret` and `emergency.recover` are static and restore
> cleanly even if `lightningd.sqlite3` is torn, so the worst case is a
> force-close and on-chain recovery, not lost funds; the wallet is written
> periodically, so a live copy is safe in practice.
>
> "Safe" means *funds*: a wallet cache is a cache. One captured while the wallet
> was rebuilding, or torn mid-write, is rejected when it is loaded, and the
> wallet then rescans from its restore height — hours, not minutes, with the RPC
> unavailable until it finishes (the daemons report it as unhealthy, and
> `scripts/monitor.sh` says so). The keys file is the part that matters, and it
> always restores.
>
> The hours are the daemon's fault, not the wallet's: `monerod`'s RPC answers in
> seconds rather than milliseconds while it syncs (measured on this host during
> the Bitcoin/Monero/Fulcrum catch-up: 5.8 s for a six-block
> `get_block_headers_range`, 10 s for `get_info`), and a rescan is a long series
> of such calls, with `--untrusted-daemon` adding the wallet's own verification
> instead of a shortcut. Expect it to bind only at the end, and note that the
> refresh logs at INFO while the unit leaves `wallet.wallet2` at WARNING —
> `podman logs` shows nothing until `Binding on 0.0.0.0:18083`. Do not restart it
> to "check": every restart throws the pass away.

#### After any recovery

```sh
./verify.sh --deep                  # containers, MCP handshakes, chains, Fulcrum
./scripts/monitor.sh                # the sweep, including backup age and the drill
./scripts/spend-audit.sh            # ENABLE_SPENDING=0 and no drift
./scripts/backup.sh verify          # the new repository restores too
```

Then look at the things a sweep cannot judge:

- `podman exec lightningd lightning-cli listpeerchannels` — are the channels
  back, and in the state you expect?
- `systemctl --user list-timers` — backup, drill, monitor and metrics all
  scheduled; `./scripts/backup.sh list` shows the nightly job writing again.
- the `.onion` addresses match what clients hold (`./deploy.sh` and
  `scripts/npm-hosts.sh` print them).
- `config/rotation/*.pending` — a snapshot can carry an unfinished rotation;
  `scripts/rotate.sh --status` explains it and `--resume` finishes it.
- the spend baseline: `audit/` came back from the snapshot, so if anything
  happened after it, `scripts/spend-audit.sh --rebaseline` is the deliberate
  "this is known-good now" act.

### Verifying the backups

A nightly snapshot that has never been opened is a hope, not a backup, so a
second timer opens one:

- `deploy/backup-verify.timer` runs `scripts/backup.sh verify` every Sunday at
  05:30 (plus up to 30 min of jitter) — two hours after the nightly job, so it
  proves a *fresh* snapshot and cannot collide with the backup's restic lock.
- The drill reads a slice of the repository's pack data
  (`restic check --read-data-subset=n/4`, rotating, so the whole repository is
  read every four weeks), restores the snapshot into `$DATA_DIR/backup-verify`
  with `restic restore --verify`, and asserts that every directory in
  `BACKUP_PATHS` came back non-empty along with the markers in
  `BACKUP_VERIFY_PATHS` (`cln/bitcoin/hsm_secret`, the wallet's `.keys`,
  `tor/onion`, `config/stack/secrets.env`, NPM's sqlite database,
  uptime-kuma's embedded mariadb). The database dump must also carry its
  `pg_dumpall` completion trailer, which is what catches a dump killed
  mid-write.
- It never touches the live data dirs: only the repository, restic's cache and
  the scratch target are mounted, and that tree is removed on every exit path.
  A restore larger than `BACKUP_VERIFY_MAX_MB` (5 GiB) or one that does not fit
  in the free space is skipped and recorded as such rather than attempted.
- The verdict lands in `$DATA_DIR/audit/backup-verify.status` (result, snapshot
  id, file and byte counts, and the last *success*). `scripts/monitor.sh` fails
  on a failed drill and on a last success older than
  `MONITOR_BACKUP_VERIFY_MAX_AGE_H` (192 h by default), so a drill that keeps
  skipping is an alert rather than a green tick.

Run it by hand:

```sh
./scripts/backup.sh verify              # check + restore + assertions
./scripts/backup.sh verify --keep       # leave the restored tree to inspect it
./scripts/backup.sh verify --snapshot <id>
./scripts/backup.sh verify --no-check   # skip the read-data check, still restore
./deploy.sh --only backup-verify        # what the timer does
```

What it proves is the mechanics: the password opens the repository, the pack
data is intact, a snapshot restores, and the files that matter are inside it.
What it does **not** prove is what only a real recovery exercises — that an
*offsite* repository is reachable (the default one is on the same disk, so a
drill against it survives nothing the disk does not), that the restored wallet
opens and re-syncs, or that the daemons come up on the restored state. That is
what the walkthrough above is for, and it is worth running once against a spare
host rather than trusting a green drill.

The database is the one part a file-level check cannot settle, so replay it on
demand:

```sh
./scripts/backup.sh verify --with-db
```

That restores as usual and then replays `postgres-dump/all.sql` into a throwaway
`postgres` container, asserting the dump produces tables (the database name is
not hardcoded: whatever the dump creates is discovered and counted). It is
deliberately not part of the weekly run — it puts the postgres image in the
drill's path, and the weekly run should stay deterministic. Do it before a
release, or quarterly.

## Monitoring & the spend tripwire

Nothing in the stack pages on its own: a container has a healthcheck and
`Restart=always` (so a crash restarts), but a crash-loop, an offline channel, a
stalled chain or a spend is otherwise silent. `install.sh` installs a monitor
that closes that gap.

- `scripts/monitor.sh` — runs every five minutes from
  `deploy/monitor.timer`. Read-only: it starts nothing and rewrites no config.
  It runs `verify.sh` for the container/MCP base checks and adds the ones
  nothing else does — bitcoind freshness, **Fulcrum's Electrum index** (the tip
  it serves against bitcoind's height), CLN peers and **offline channels**, the
  Monero wallet's lag behind `monerod`, the host itself (disk and inode space,
  disk saturation, backup age, certificate expiry, units that crash-looped
  since the last sweep, the metrics collector going quiet, the log pipeline
  going quiet, and a credential rotation left half-finished) — then the spend
  tripwire.
- `deploy/monitor.timer` + `deploy/monitor.service` — a plain systemd **user**
  unit (Quadlet has no `.timer` type) and its one-shot service, installed to
  `~/.config/systemd/user/` and enabled by `install.sh`, like `backup.timer`.
- `scripts/spend-audit.sh` — the spend tripwire (below); also runnable alone.

The monitor reads the daemons and the host **directly**; it never queries the
metrics store. That is deliberate: alerting must not depend on the pipeline that
exists to draw graphs of itself, so VictoriaMetrics can be down, wedged or
deleted without silencing an alert.

**Alerting is off until you fill in
`$DATA_DIR/config/monitoring/monitor.env`** (mode 600, seeded empty):

  - `MONITOR_APPRISE_URLS` — [Apprise](https://github.com/caronc/apprise)
    targets, space-separated (`mailto://…`, `ntfy://…`, `json://…`), sent
    through a one-shot `caronc/apprise` container. One alert per state
    **change**, plus a recovery notice.
  - `MONITOR_PING_URL` — a dead-man's-switch heartbeat (a healthchecks.io ping
    URL): a plain `curl` hits the URL on success and `<url>/fail` with the
    failure list on failure. This is the only thing that notices when the
    **whole host** is down, which is why it is not an Apprise target. Set the
    check's period to the timer interval (5 minutes).

With both empty the monitor still runs and records to
`$DATA_DIR/audit/audit.log`, and `verify.sh` reports whether the timer is
installed and active. The host checks' thresholds are the same file
(`MONITOR_DISK_FREE_PCT`, `MONITOR_IO_UTIL_PCT`, `MONITOR_BACKUP_MAX_AGE_H`,
`MONITOR_CERT_MIN_DAYS`, `MONITOR_RESTART_MAX`, `MONITOR_METRICS_MAX_AGE_S`,
`MONITOR_FULCRUM_LAG_BLOCKS`, `MONITOR_BTC_MIN_PEERS`, `MONITOR_MEMPOOL_MB`,
`MONITOR_XMR_LAG_BLOCKS`, `MONITOR_NET_DROP`, `MONITOR_TEMP_MAX`,
`MONITOR_LOGS_MAX_AGE_S`, …);
each falls back to its default in the script, so a monitor.env written before a
check existed still monitors.

### Metrics and history

Alerting tells you *that* something is wrong. These two units answer *when it
started, how bad it got and whether it is improving* — the questions a chain
sync on one shared disk actually raises ("how fast was the IBD at 03:00?", "when
did the Monero RPC wedge?").

| | |
| --- | --- |
  | `victoriametrics` | the store: Prometheus-compatible, single process, 30 days (`METRICS_RETENTION` in `stack.conf`), `127.0.0.1:8428` |
| `node-exporter` | the host: disk space, inodes, I/O saturation, memory, load, NIC bandwidth/errors, temperatures — plus the **textfile collector**, which is how the stack's own numbers get in |
| `scripts/metrics.sh` (`deploy/metrics.timer`, every minute) | writes `$DATA_DIR/monitoring/textfile/stack.prom`: chain heights and IBD, bitcoind's peer count and mempool, Fulcrum's Electrum reachability, the tip it serves and its lag behind bitcoind, CLN peers/offline channels, `monerod`'s restricted-RPC **reachability** and its lag behind `target_height`, the wallet's lag, and each managed unit's systemd restart counter |
| `scripts/monitor.sh` (every five minutes) | writes `monitor.prom` beside it: backup age and snapshot count, verify failures, spend trips, sweep timestamp |

**Read it over an SSH tunnel, by design:**

```sh
ssh -L 8428:127.0.0.1:8428 you@host      # then http://127.0.0.1:8428/vmui
```

`vmui` has no authentication of its own, and every public host in this stack is
declared in `NPM_HOSTS` and TLS-terminated — so the metrics store publishes on
the host's **loopback only** and adds nothing to the firewall. If you want it on
the LAN, put it behind `nginx-proxy-manager` with basic auth *and* declare it in
`NPM_HOSTS`; don't publish it directly.

Two consequences worth knowing:

- **`$DATA_DIR/monitoring` is not in the backup set.** It is history, not state:
  losing it costs you the graphs, and nothing else. Same reasoning as
  `fulcrum/` and `searxng/`.
- **The textfile is a permissions trap.** `node-exporter` runs as uid 65534 (a
  subuid under rootless podman), so it owns neither the directory nor the files.
  Both writers chmod the directory `0755` and the files `0644`; if you ever see
  graphs stop while the containers are healthy, check that first — `verify.sh`
  has a check for it (`node-exporter /metrics` must carry `stack_*` series).

### Logs and history

journald is the source: podman's default log driver writes every container's
stdout there, and the host scripts (`monitor.sh`, `metrics.sh`, `ids.sh`,
`backup.sh`) log there too — so no unit needed a logging change to be
collected. What was missing was search across services and any history at all:
journald was **volatile** (a 32 MB ring in `/run`), so a reboot erased the only
record. Three pieces fix that:

| | |
| --- | --- |
| `bootstrap.sh` | makes journald persistent and bounded (`/var/log/journal`, 2 GB, 7 days), so `podman logs` works across a reboot |
| `vector` | ships the journal to `victoria-logs` continuously; it checkpoints one cursor per batch, so a restart resumes instead of replaying |
| `victoria-logs` | the store and the LogsQL UI: 14 days (`LOGS_RETENTION`) or 10 GiB (`LOGS_MAX_BYTES`), whichever comes first |

Search it from the CLI — this is the cross-service timeline that used to mean
five `podman logs -f` windows:

```sh
./scripts/logs.sh --since 30m                        # everything, labelled
./scripts/logs.sh --since 2h --container lightningd
./scripts/logs.sh --since 1h --grep 'WARN|ERR' --priority warning
./scripts/logs.sh --since 24h --stats                # who is spamming
./scripts/logs.sh --follow --container boltmesh-backend
./scripts/logs.sh --health                           # is anything still arriving?
```

…or open the LogsQL UI over an SSH tunnel, exactly like `vmui`:

```sh
ssh -L 9428:127.0.0.1:9428 you@host      # then http://127.0.0.1:9428/select/vmui
```

`victoria-logs` publishes on the host's **loopback only**: it has no
authentication of its own, and every log line every container wrote is in it
(including any token someone echoed). It is not in `NPM_HOSTS` and adds nothing
to the firewall — if you ever want it on the LAN, put it behind NPM with basic
auth *and* declare it, the same rule as `vmui`.

Two consequences worth knowing:

- **`$DATA_DIR/logs` is not in the backup set.** It is history, not state, like
  the metrics store: losing it costs the history, and the journal's own 7 days
  cover a restore.
- **The monitor makes exactly one query against a store, and it is this one.**
  It asks "has anything arrived in the last 15 minutes?", because the failure
  that matters is the silent one (all three units read "active" while nothing
  is shipping). A dead store therefore *adds* an alert; every other check still
  reads the daemons and the host directly, so the pipeline can never silence
  one. `verify.sh` runs the same query plus a real LogsQL search.

No Grafana, for logs either: `vmui` and VictoriaLogs' own LogsQL UI answer the
two questions ("how did it move" and "what did it say"), and one less container
on a disk that is the stack's bottleneck is worth more than dashboards.

### The spend tripwire

Spending is **off** (`ENABLE_SPENDING=0`) on both money servers, and the
tripwire is what makes that impossible to change or spend, silently:

1. **Policy drift.** `scripts/spend-audit.sh` keeps a hash baseline
   (`$DATA_DIR/audit/spend-baseline.tsv`) of both `spend.env` files, both token
   files and `lightning-mcp/node.env` (the spend rune). Any edit or removal
   trips, and `ENABLE_SPENDING` is asserted to read `0` on every run whatever
   the baseline says. A trip repeats until you accept the change with
   `./scripts/spend-audit.sh --rebaseline` (a deliberate act).
2. **Activity.** It reads outgoing payments (`lightning listpays`) and outgoing
   transfers (monero-wallet `get_transfers`, outgoing only) through the **read**
   tokens and diffs them against `$DATA_DIR/audit/outgoing-baseline.txt`. A new
   outgoing entry trips — independent of what the servers log.

Trips are appended to `$DATA_DIR/audit/spend.log` (so there is a record even
with no alert configured) and folded into the monitor's alert and heartbeat. It
is **not** a gate: it cannot stop a spend, only make one impossible to miss.
`audit/` is part of the [backup set](#backup--restore).

## Intrusion detection

Two engines, because the traffic splits in a way one product cannot cover.
`nginx-proxy-manager` terminates TLS, so the wire carries handshakes and scans
while the request itself exists only in NPM's access log:

| Engine | Sees | Runs as | Installed by |
| --- | --- | --- | --- |
| `suricata` | packets on `enp8s0` and `lo` | **rootful** (AF_PACKET needs `CAP_NET_RAW` in the init namespace) | `sudo ./bootstrap.sh` |
| `crowdsec` | NPM's access logs → decisions | rootless | `./deploy.sh` |

That rootful unit is the one exception to "everything runs rootless", and it is
why `bootstrap.sh` is a **two-pass** install: the sensor's config references the
data dir, which does not exist until `./deploy.sh` has run. The first bootstrap
prints a notice; re-running it after the first deploy installs the sensor. The
rendered unit lives in `/etc/containers/systemd/`, its config in
`/etc/stack-ids/`, and `./verify.sh` warns when the two have drifted apart.

### What each can and cannot see

* **Suricata** sees the LAN NIC and the host loopback — the latter is where each
  MCP server's plaintext HTTP and the daemon RPC ports live. It cannot see the
  rootless container bridge (a rootful sensor cannot enter the user's network
  namespace) and it cannot see inside TLS.
* **CrowdSec** sees every request NPM served, which is the whole attack surface
  of the public vhosts. It cannot attribute anything on the `.onion` vhosts: tor
  forwards to `host.containers.internal`, so NPM logs the host's own address for
  every onion visitor.

It is **detection then enforcement**: CrowdSec's decisions are applied to
nftables by `stack-bouncer` (below). Nothing in the *packet* path is inline —
enforcement happens at the kernel's input hook, with per-entry timeouts, so a
sensor crash or a rules reload cannot be an outage.

It is also **local only**: `DISABLE_ONLINE_API=true` means no console
enrolment, no community blocklist and no telemetry leaving the host. The cost is
that a known-bad address is only banned here after it has misbehaved here.

### Enforcement

Decisions are applied by `stack-bouncer` — a root oneshot on a one-minute timer
(`deploy/root/bouncer.sh`, installed to `/etc/stack-ids/`). It polls the
crowdsec container's LAPI over its loopback publish (`127.0.0.1:8081`, key-gated:
an unauthenticated request gets 403) and writes one nftables set:

```
table inet stack_bans
  set banned_v4 { type ipv4_addr; flags timeout; }
  set banned_v6 { type ipv6_addr; flags timeout; }
  chain input  { type filter hook input priority -10; ip saddr @banned_v4 drop; ... }
```

Each element carries the decision's own duration as an nft timeout, so a ban
expires even if everything above it dies. The set is refreshed wholesale every
minute in one transaction — the LAPI's list is the truth — which also means
`nft flush table inet stack_bans` cannot unban anyone permanently.

There is no upstream bouncer image any more (`crowdsecurity/cs-firewall-bouncer`
answers *access denied*), and the packaged one would be a second daemon outside
this repo's control. CrowdSec keeps the hard half (decision lifecycle, TTLs,
dedup); this is the plumbing, and it is ~120 lines you can read.

```sh
sudo /etc/stack-ids/bouncer.sh --dry-run    # the rules it would apply, applied to nothing
sudo nft list table inet stack_bans         # who is banned right now
systemctl stop stack-bouncer.timer          # the kill switch: detection keeps working
```

Three properties worth knowing:

* **Never bans the operator.** The script refuses private space, the podman
  network, and every address the host itself holds — checked at run time, so a
  DHCP change cannot produce a self-ban. Banning `192.168.1.112` would cut the
  `.onion` proxies, the status page and your own SSH session at once.
* **Fails open in the safe direction.** An unreachable LAPI or a non-JSON answer
  leaves the existing bans alone (it never reads "no decisions" as "unban
  everything"), and a failed `nft -f` rolls back atomically.
* **Its key is never regenerated.** `CROWDSEC_BOUNCER_KEY` in
  `config/stack/secrets.env` is registered into the LAPI by the crowdsec
  container at start; a new value leaves the old bouncer registered and
  enforcement silently dead. `scripts/monitor.sh` fails on a stale
  `audit/bouncer.status` for exactly that reason.

### Reading it

```sh
./scripts/ids.sh -v                       # the roll-up, by hand
cat $DATA_DIR/audit/ids.status            # what monitor.timer reads
podman exec crowdsec cscli decisions list  # every decision the engine holds
sudo nft list table inet stack_bans        # what is actually being dropped
podman exec crowdsec cscli metrics         # lines read/parsed/whitelisted per log
tail -f $DATA_DIR/ids/suricata/eve.json | jq 'select(.event_type=="alert")'
```

`deploy/ids.timer` runs the roll-up every five minutes at `*:2/5` — deliberately
between the monitor's sweeps — and `scripts/monitor.sh` alerts on a stale or
failed status, so a sensor that dies quietly cannot look healthy. Alert counts
are a *warning*, not a page: one Suricata alert needs a human to read it, and the
rate is in VictoriaMetrics (`stack_ids_alerts`).

### The whitelist is load-bearing

`deploy/crowdsec/parsers/s02-enrich/stack-whitelists.yaml` exists because a naive
threshold is a self-inflicted outage on this host, not a false positive:

* the onion proxies and Uptime-Kuma's self-checks are logged as the host's **own**
  address (`192.168.1.112` / the WAN IP), so banning it would take every onion
  service and the status page down at once;
* Uptime-Kuma probes nine vhosts a minute, including a permanent 401 on the
  token-gated ones;
* the podman network (`10.89.0.0/24`) and the LAN are internal by definition.

Read that file before tightening a scenario. `scripts/verify.sh` replays a sample
access-log line through `cscli explain` on every sweep, because a change to NPM's
`log_format` would otherwise disable detection silently.

Two survivors of a real scan are worth knowing about: `93.123.109.247`
(`tlm-scanner/2.0`, ~7,500 requests, 100% 404, `/.git/…` and traversal probes)
was probing this host before the sensor existed, and the `default-host` vhost
exists only to answer that kind of traffic — any request to it is worth a look.

### Resources and retention

~650 MB RSS for Suricata with the full ET Open ruleset (refreshed at container
start, best effort — a host without internet starts on the twelve local rules),
~150 MB for CrowdSec, and nothing measurable for the bouncer (one nft
transaction a minute). EVE JSON rotates daily and is pruned at
`IDS_RETENTION_DAYS` (14) by `/etc/tmpfiles.d/stack-ids.conf`; `$DATA_DIR/ids`
is regenerable and stays out of the backup set.

### Rate limiting (the onion's only defence)

Every visitor to a `.onion` vhost reaches NPM as the host's **own** address, so
no IP-based control — ban, fail2ban, CrowdSec — can touch them individually.
What is left is a global brake, and that is `stack_onion`: a request-rate zone
keyed on `$server_name` rather than the client address, at 60 r/s with a 120
burst. The clearweb vhosts get `stack_ip` keyed on the real address (30 r/s,
burst 60) plus `stack_conn` (40 concurrent).

The MCP host gets **`limit_conn` only**, never `limit_req`: it is JSON-RPC (a
client legitimately bursts) and its `GET /mcp` is a long-lived SSE stream, where
a request-rate limit either does nothing or cuts healthy clients.

The zones are declared in `deploy/npm/http.conf`, seeded to
`$DATA_DIR/npm/data/nginx/custom/http.conf` — the one NPM directory that is never
regenerated. The directives themselves are per host, in the `advanced_config`
field `scripts/npm-hosts.sh` sends, because which limit applies depends on what
the vhost is. Measured on this host: a 100-request burst produced 16 × `503`
while a normal page load was unaffected.

### Host integrity

`auditd` was already running on this host with an **empty** `rules.d` — a daemon
watching nothing. `deploy/root/audit.rules` now watches the files this repo never
writes: the account databases, `sudoers`, `sshd_config`, `auditd.conf`, and the
stack's own `secrets.env` and `hsm_secret`. `stack-audit.timer` turns the
root-only log into `audit/$DATA_DIR/auditd.status`, which the monitor pages on.

Two things about it are worth knowing:

* **Directory watches do not work on this kernel.** `-w /etc/sudoers.d/ -p wa`
  (with and without the trailing slash, and the `-a always,exit -F dir=…` form)
  produces no record for a file created inside it, while the same watch on a file
  fires normally. Entry creation — a new unit file, a new sudoers drop-in, a new
  cron job, the classic persistence moves — is therefore covered by a **hash diff**
  in the same report: every file under `/etc/systemd/system`,
  `/etc/containers/systemd`, `/etc/sudoers.d`, `/etc/cron.d` and
  `/etc/ssh/sshd_config.d` is hashed each run, and anything new or changed is
  counted and named. That also survives environments where audit is unavailable.
* Events carry a **key** (`stack_hard` for host-level config the repo never
  writes, `stack_data` for the stack's secrets), and only `stack_hard` fails the
  sweep. Rotation and deploys touch the data-dir files on purpose; a monitor that
  pages on its own deploy stops being read.
* **On this host the kernel audit subsystem is inert.** It initializes disabled
  (`audit: initializing netlink subsys (disabled)`, `audit_enabled=0` in dmesg)
  and, although `auditctl -s` then reports `enabled 1`, no kernel record is ever
  written — not even the `CONFIG_CHANGE` for loading the rules at boot. That
  survives a reboot, so it is not leftover state. The rules stay loaded (they are
  correct if the host is ever booted with auditing on), the report says
  `audit=inert` in its status and the sweep says so in plain words, and the
  **hash diff is the live check** — which is why it is the part that has to be
  right.

## Status page

`uptime-kuma` serves a public status page on
`https://status.boltmesh.net` (`UPTIME_KUMA_HOST` in `stack.conf`, proxied by
nginx-proxy-manager like every public hostname). It complements the monitor
above, not replaces it: the monitor is the host-side, alert-only sweep that
knows the tokens and the wallets, while the status page watches the public
surface — the sites and the token-gated endpoints — and shows it to the world.

The **monitors are declared, like the proxy hosts**: `KUMA_MONITORS` in
`stack.conf` — `name | url [| accepted-status-codes [| interval [| retries ]]]`
— is reconciled into Uptime-Kuma by `scripts/kuma-monitors.sh` (which
`./deploy.sh` runs after the proxy hosts): a missing monitor is created, one
whose *declared* fields changed is updated in place, notifications and other
UI-tuned settings an existing monitor has picked up are carried over
untouched, and `--prune` is the only destructive mode. The script creates the
status page (`KUMA_STATUS_SLUG`) with one group holding every declared
monitor — and only while the page has nothing on it yet: an existing page's
layout is never rewritten, so rearranging it in the UI is safe.

A url of the form `tcp://host:port` declares Uptime-Kuma's **TCP-port** monitor
instead of an HTTP one — there is no status code to accept, so that field stays
empty while interval and retries keep their positions. `fulcrum`'s `50001` is
the only entry that needs it (Electrum is raw TCP, so it cannot be probed as a
URL), and it is declared against `host.containers.internal:50001` — pasta's
gateway to this host — so it watches the **published** port wallets use, not the
container. A port monitor proves the socket accepts a connection and nothing
more; whether the index behind it is current is what `verify.sh --deep` and
`scripts/monitor.sh` read (above).

Uptime-Kuma has no REST write API, so the reconciler speaks its socket.io
API from the `kuma-ctl` image (built by `deploy/install.sh` from `kuma-ctl/`,
like `tor` and `netcheck`). The admin login lives in
`$DATA_DIR/config/uptime-kuma/api.env` (mode 600, seeded empty — fill in what
the setup wizard asked for and re-run `./deploy.sh --only kuma-monitors`); the
reconciler self-skips until it is filled in. The login never reaches a command
line: it travels to the container through the environment. The page's
**notifications** (an Apprise or SMTP target) stay UI-configured — they are
set once in kuma's own settings; kuma embeds Apprise, so the monitor's
Apprise URLs are reusable there.

Notes:

- **No tokens enter kuma's database.** Everything the declared monitors check
  is on the public surface (a token-gated endpoint answering 401 counts as
  up); the authenticated MCP handshakes stay in `verify.sh`/`monitor.sh`.
- Its state (`$DATA_DIR/uptime-kuma`) is part of the [backup set](#backup--restore).
- `verify.sh` checks the dashboard through nginx-proxy-manager and by container
  name on `npm-network`, and probes the published page's public data endpoint.
- The websockets it serves for its dashboard are why the proxy host carries the
  `ws` flag in `NPM_HOSTS`.

## Proxy hosts (nginx-proxy-manager)

nginx-proxy-manager is the stack's only LAN-facing HTTP unit, so every public
hostname is a proxy host in NPM. (Fulcrum's raw Electrum ports `50001`/`50002`
are the deliberate non-HTTP exception; see [What runs](#what-runs).) They are
declared in `NPM_HOSTS` in
`stack.conf` — `domain | forward_host:port | flags` — and reconciled from this
repo by `scripts/npm-hosts.sh` through the NPM admin API on `127.0.0.1:81` (NPM
binds it on the host network): a host already serving the domain is updated in
place, otherwise it is created, and a Let's Encrypt certificate is requested for
any host that has none. `./deploy.sh` runs it after the app tier (so a fresh host
deploys before the admin login exists), and `./deploy.sh --only npm-hosts`
re-applies it after a change.

```sh
NPM_HOSTS=(
    "${BOLTMESH_FRONTEND_HOST}|127.0.0.1:8106|ws,block"
    "${BOLTMESH_API_HOST}|127.0.0.1:8105|ws,block"
    "${SEARXNG_HOST}|127.0.0.1:8080|ws,block"
    "${CLNREST_HOST}|https://127.0.0.1:3010|ws,block"
    "${XMR_RPC_HOST}|127.0.0.1:18083|ws,block"
    "${BTC_EXPLORER_HOST}|127.0.0.1:8108|force-ssl,block"
    "${XMR_EXPLORER_HOST}|127.0.0.1:8109|force-ssl,block"
    "${UPTIME_KUMA_HOST}|127.0.0.1:8107|ws,block"
    "${MCP_HOST}|127.0.0.1:8100|mcp,force-ssl,http2"
)
```

Each entry is `domain | forward | flags`, where `forward` is
`[scheme://]host:port` (scheme defaults to `http`; `https` for an upstream that
speaks TLS, like `clnrest`) and `flags` is a comma-separated subset of
`force-ssl` (redirect `:80` to `:443`), `http2`, `ws` (websocket upgrade),
`block` (block common exploits) and `mcp`. The host is always `127.0.0.1`: it is
the loopback publish of the unit the host fronts — NPM runs on the host network
and cannot resolve a container name. `--dry-run` prints the API payloads without
changing anything, and `--prune` additionally **deletes** hosts and certificates
that `NPM_HOSTS` does not declare — the only destructive mode.

The credentials for the API are in `$DATA_DIR/config/npm/api.env` (mode 600,
seeded by `deploy/install.sh`):

```sh
NPM_EMAIL=you@example.com
NPM_PASSWORD=…        # the password you set on the NPM UI's first visit (81)
```

### The MCP host

Every MCP server speaks the Streamable HTTP transport at `/mcp` (the SDK's
default). Rather than one hostname per server, they share one, each on a **path
prefix** (`mcp` flag above):

| Public URL | NPM forwards to |
| --- | --- |
| `https://mcp.boltmesh.net/searxng` | `127.0.0.1:8100` |
| `https://mcp.boltmesh.net/bitcoin` | `127.0.0.1:8101` |
| `https://mcp.boltmesh.net/monero` | `127.0.0.1:8102` |
| `https://mcp.boltmesh.net/monero-wallet` | `127.0.0.1:8103` |
| `https://mcp.boltmesh.net/lightning` | `127.0.0.1:8104` |

Each prefix maps onto the upstream `/mcp`, so the `/mcp` never appears in a
client's URL. The host and the prefixes are `MCP_HOST`/`MCP_HOSTS` in
`stack.conf`; each entry is `prefix:container:port`, where the port is that
server's loopback publish (the container name is kept because it also names the
`token.env` that is the prefix's credential). Each server's bearer token still
gates it (the tokens are the `token.env` files under
`$DATA_DIR/config/<server>/`). The host's nginx config turns buffering off and
sets a long read timeout, because Streamable HTTP answers with `text/event-stream`
and a buffered SSE body just hangs the MCP client.

Each declared host needs its DNS pointing here and `:80` reachable for the
HTTP-01 challenge; set `NPM_REQUEST_CERT=0` to leave TLS to the UI instead.
`./verify.sh` checks the MCP path a client takes — the public URL connected to
NPM itself (`--connect-to`), following its redirect to `:443` once TLS is on, so
it works before public DNS exists.

## Tor onion services

The public hostnames are also published as Tor v3 onion services, from the
`tor` unit that already exists (lightningd's SOCKS proxy and CLN's own onion
client). There is no extra container and nothing to open in the firewall: a
hidden service is made of a few lines in `torrc` and outbound connections, which
the stack already makes.

The declaration is `ONION_SERVICES` in `stack.conf`:

```sh
ONION_SERVICES=(
    "boltmesh|10.89.0.241:80|${BOLTMESH_FRONTEND_HOST}|/|200"
    "api|10.89.0.242:8000|${BOLTMESH_API_HOST}|/health|200"
    "btc-explorer|10.89.0.243:3002|${BTC_EXPLORER_HOST}|/|200,401"
    "xmr-explorer|10.89.0.244:31312|${XMR_EXPLORER_HOST}|/|200"
    "mcp|${ONION_NPM_TARGET}|${MCP_HOST}|/searxng|401"
)
```

`deploy/install.sh` renders it into a marked block at the end of
`$DATA_DIR/tor/torrc` — the rest of that file (the control-password hash, the
SOCKS policy) is still seeded once and never rewritten — and `./deploy.sh` hashes
`torrc` alongside the units, so editing `ONION_SERVICES` and re-running it is all
it takes to add, remove or retarget a service.

The address itself is key material, not configuration: tor writes it to
`$DATA_DIR/tor/onion/<name>/` (mounted at `/var/lib/tor/onion`, mode 700), which
is part of the [backup set](#backup--restore). Restore those keys and the
addresses come back; lose them and every address changes.

tor logs a `ControlPort ... non-local address` warning at startup. That is
expected: lightningd drives the statictor service through
`10.89.0.240:9051`, which is not loopback. The port is protected by
`HashedControlPassword` and is reachable only from `npm-network`.

```sh
cat "$DATA_DIR"/tor/onion/*/hostname   # what each service is called
./verify.sh                            # fetches each of them through tor
./deploy.sh --only tor                 # just re-read torrc
```

| `ONION_SERVICES` name | Serves | Forwarded to |
| --- | --- | --- |
| `boltmesh` | the BoltMesh SPA | `http://<addr>.onion/` → `10.89.0.241:80` |
| `api` | the BoltMesh API | `http://<addr>.onion/health`, `/v1` → `10.89.0.242:8000` |
| `btc-explorer` | BTC RPC Explorer | `http://<addr>.onion/` → `10.89.0.243:3002` |
| `xmr-explorer` | MoneroBlock | `http://<addr>.onion/style.css` → `10.89.0.244:31312` |
| `mcp` | the five MCP servers | `http://<addr>.onion/<searxng\|bitcoin\|monero\|monero-wallet\|lightning>` → NPM's `*.onion` host |

All but the MCP host forward to a container's pinned IP (the units set `IP=`):
tor validates the target when it starts, so a name for a container that has not
started yet would keep tor down. The MCP host cannot use an IP target — it is
five servers split by *path*, which only nginx-proxy-manager does, and NPM is on
the host network, where a container has no route (`10.89.0.1:80` is refused from
`npm-network`). The one reachable name is `host.containers.internal` (pasta's
host gateway, added by podman), so the mcp onion forwards there and NPM matches
the wildcard `*.onion` proxy host. A wildcard is required because **tor cannot
rewrite the `Host` header** and the address is not known when the proxy hosts are
declared. That host is the only one without a certificate: tor already encrypts
and authenticates the onion, Let's Encrypt cannot issue for `.onion`, and the
hidden service reaches NPM over plain HTTP — `scripts/npm-hosts.sh` skips TLS for
it on purpose.

**What a browser can and cannot do over onion.** The API and the MCP servers are
fully usable: point a client at the `.onion` address and everything above still
holds, bearer tokens included (`verify.sh` proves the 401 gate through the onion).
The BoltMesh SPA is not, on its own: `VITE_API_URL` is baked into the bundle at
build time as `https://api.boltmesh.net/v1` and the refresh cookie is `Secure`,
so a DNS-less browser loads the shell but cannot reach the API. An onion-native
SPA means rebuilding it with the onion origin (`BOLTMESH_API_HOST=`) and adding
the frontend's onion origin to `CORS_ALLOW_ORIGINS` in
`$DATA_DIR/config/boltmesh/app.env` — a separate decision, not something the
hidden service can do by itself.

The onion checks therefore live in `./verify.sh` (it fetches each address through
tor's SOCKS port); the status page cannot do them, because uptime-kuma has no
SOCKS egress.

## BoltMesh

The application tier — `postgres`, `boltmesh-backend`, `boltmesh-worker` and
`boltmesh-frontend` — is deployed by the same `./deploy.sh` as everything else,
from the `boltmesh-labs` GitHub org (`GITHUB_ORG_BOLTMESH` in `stack.conf`). It
is the one part of the stack that is not an MCP server, so it is built by its
own step (`deploy_boltmesh` in `deploy.sh`): the images need a build target and
`VITE_*` build arguments the generic app path does not pass.

Those two repos are **private** (the `$GITHUB_ORG` ones are public), so they are
cloned over **SSH**, not HTTPS: the host must authenticate to GitHub as a user
with access (`ssh -T git@github.com` must greet you). `deploy.sh` exports
`GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, so a
missing key is a clear error rather than a username prompt hanging the deploy.
Set `GITHUB_SSH_HOST` to an `~/.ssh/config` alias if `git@github.com` is not the
key's host. An existing HTTPS checkout is re-pointed at the SSH URL on the next
run.

It does not bring its own chains. The backend is pointed at the stack's own
`lightningd` (clnrest) and `monero-wallet-rpc`:

| Value | Source |
| --- | --- |
| `DATABASE_URL`, `POSTGRES_*` | `$DATA_DIR/config/boltmesh/db.env` (generated) |
| `SECRET_KEY`, `REFRESH_SECRET_KEY`, `NODE_SECRET_KEY`, `BOOTSTRAP_SECRET_PEPPER` | `$DATA_DIR/config/boltmesh/secrets.env` (generated) |
| `LIGHTNING_GATEWAY_URL`, `LIGHTNING_API_KEY` | `$DATA_DIR/config/boltmesh/gateway.env` — a rune `install.sh` creates on `lightningd` that permits only `getinfo`, `listinvoices`, `invoice`, so BoltMesh can bill but never move funds |
| `MONERO_RPC_URL`, `MONERO_RPC_USER`, `MONERO_RPC_PASSWORD` | the same `gateway.env`, from the wallet's `--rpc-login` |
| URLs, CORS, OAuth, SMTP, `GITHUB_REPO`/`GITHUB_TOKEN` | `$DATA_DIR/config/boltmesh/app.env` — **operator-editable**, fill it in before first use |

### Before it works

0. (once per host) The `boltmesh-labs` repos are private, so the host needs
   GitHub **SSH** access before the first `./deploy.sh`: `ssh -T git@github.com`
   must greet you. Without it the clone fails fast with a clear error (git is
   not allowed to prompt).
1. Point `boltmesh.net` and `api.boltmesh.net` at the host (`BOLTMESH_FRONTEND_HOST`
   / `BOLTMESH_API_HOST` in `stack.conf`), and make `:80` reachable for the
   Let's Encrypt challenge.
2. Fill in `$DATA_DIR/config/npm/api.env` with the NPM admin login and re-run
   `./deploy.sh --only npm-hosts`: the two hosts (`boltmesh.net` →
   `127.0.0.1:8106`, `api.boltmesh.net` → `127.0.0.1:8105`) come
   from `NPM_HOSTS` in `stack.conf`, each with its own TLS certificate.
3. Fill in `$DATA_DIR/config/boltmesh/app.env` (OAuth client id/secret, SMTP,
   the agent `GITHUB_TOKEN`) and register
   `https://api.boltmesh.net/v1/auth/google/callback` and `…/github/callback`
   in the provider consoles — `API_BASE_URL` is the base of every redirect_uri.
4. Re-run `./deploy.sh` (or `./deploy.sh --only boltmesh`). `VITE_API_URL` is
   baked into the frontend bundle at build time, so a hostname change means a
   rebuild, not an env edit.

The database is dumped (`pg_dumpall`) into `$DATA_DIR/postgres-dump/` by
`postgres-dump.container` immediately before each restic run, and the dump — not
the raw cluster — is what the [backup set](#backup--restore) holds.

## How secrets are kept out of git

No secret is committed. Everything real is generated or adopted on the host,
under `$DATA_DIR/config/`, mode 600.

- **`$DATA_DIR/config/stack/secrets.env`** holds the node secrets (bitcoind RPC
  user and password, Tor service password, Monero wallet password and RPC
  login). It is resolved in the order **`secrets.env` → the currently-installed
  unit → the daemon's own config → generate**, so adopting the deploy on a
  running host changes no credential. `MONERO_WALLET_PASSWORD` is the **only**
  key to the wallet file — keep it with the data.
- **Per-app env files**
  (`$DATA_DIR/config/<name>/{token,upstream,spend,node}.env`) hold the bearer
  tokens, upstream credentials, spend policy and CLN runes. The unit reads them
  with `EnvironmentFile=`; the shapes are documented in
  `deploy/examples/<name>/`.
- **`$DATA_DIR/config/btc-explorer/btc-explorer.env`** holds the BTC
  explorer's bitcoind RPC credentials and its Fulcrum endpoint. The unit reads
  it with `EnvironmentFile=` (the explorer has no other configuration).
- **`$DATA_DIR/config/npm/api.env`** holds the nginx-proxy-manager admin login
  that `scripts/npm-hosts.sh` uses to reconcile every proxy host (`NPM_HOSTS`)
  through the API on `81` (or an API token instead). The script sends the
  password in a curl config on stdin, so it never reaches the host's argv.

**Quadlet does not expand environment variables in `Exec=`**, which is why
`lightningd`, `monero-wallet-rpc` and `fulcrum` are *rendered* from
`deploy/*.container.in` by `install.sh` (substituting `@PLACEHOLDERS@`). Every
unit is rendered the same way — the secret-free ones only substitute
`@DATA_DIR@`/`@CONFIG_DIR@` — so no unit is a symlink. The rendered units are
mode 600 and never enter git. Do not "simplify" `monero-wallet-rpc` to a config
file: its entrypoint binds `0.0.0.0` only when `--rpc-login` is on the command
line.

`bitcoind` keeps its RPC credentials in its own `bitcoin.conf`, which
`install.sh` seeds on a fresh host and hands to the image uid. It is edited
through the container: `podman exec -it bitcoind vi /data/.bitcoin/bitcoin.conf`.

### Rotating a credential

`scripts/rotate.sh` changes one credential and brings every consumer of it along
in dependency order:

```sh
./scripts/rotate.sh --list                  # the targets and what each one touches
./scripts/rotate.sh --status                # a pending journal + the last 10 runs
./scripts/rotate.sh bitcoin-rpc --dry-run   # the plan, no values, no writes
./scripts/rotate.sh bitcoin-rpc             # rotate, re-render, restart, verify
./scripts/rotate.sh runes --scope spend     # read | spend | boltmesh | all
./scripts/rotate.sh token:lightning-mcp     # one server's bearer token
./scripts/rotate.sh token:lightning-mcp --spend
./scripts/rotate.sh postgres
```

| Target | Rotates | Restarts |
| --- | --- | --- |
| `bitcoin-rpc` | `bitcoind`'s RPC password (and `--user`) | bitcoind, then fulcrum, lightningd, bitcoin-node-mcp, btc-explorer |
| `monero-rpc` | `monero-wallet-rpc`'s `--rpc-login` | monero-wallet-rpc, then monero-wallet-mcp, BoltMesh |
| `tor-control` | Tor's control password (lightningd's statictor) | tor, then lightningd |
| `runes` | the CLN runes: lightning-mcp's read/spend pair and BoltMesh's gateway | lightning-mcp and/or BoltMesh |
| `token:<server>` | one MCP server's bearer token (`--spend` rotates a money server's spend token instead) | that server |
| `searxng-secret` | SearXNG's `settings.yml` `secret_key` | searxng |
| `monero-wallet` | the wallet file's password (`--yes`, and a snapshot younger than 24h) | monero-wallet-rpc → wallet-mcp, BoltMesh |
| `postgres` | the `vpnuser` role's password (`ALTER ROLE`) | postgres → BoltMesh |
| `boltmesh-keys` | the four signing keys/node pepper (`--yes`: ends every session and node token) | BoltMesh |
| `restic` | the backup repository's key (`key add` → verify → `key remove`, `--yes`) | nothing |

None of it is scheduled. These credentials are also held by clients outside the
stack (an MCP client's config, a wallet, nginx-proxy-manager), so a rotation on a
timer would break them silently; it is an operator action, and the entry it
leaves in `$DATA_DIR/audit/rotation.log` is the record (never a value).

Three things make it more than an env-file edit, and `rotate.sh` is built around
them:

- **Part of each credential lives in a file `install.sh` never refreshes.**
  `bitcoin.conf`, `torrc` and the per-app `upstream.env`/`btc-explorer.env` are
  seeded once, so the script edits them in place (`bitcoin.conf` from inside the
  container, only the `HashedControlPassword` line of `torrc`) *and* rewrites
  `secrets.env` and the rest, so the next install renders the same value. A
  rotation is never just one file.
- **A re-render does not change a running container.** Every target restarts its
  own dependents in order and waits for podman's health, so a credential the
  daemon has not picked up cannot look rotated.
- **Revocation is last.** The CLN runes are minted, proved with `checkrune`, put in
  `lightning-mcp/node.env`/`boltmesh/gateway.env`, proven again through the server
  with `getinfo`, and only then blacklisted with `destroyrune` — a failed swap
  leaves the old rune working instead of leaving the server unable to read the
  node. `runes` rehashes only `node.env` in the spend baseline, so the tripwire
  does not report a rotation as policy drift.
- **A token rotation proves both halves.** The new bearer token has to answer a
  real tool call, and the old one has to be refused with 401; the old value is
  kept in the journal just long enough to test it. Nothing prints a token: the
  clients that hold one read it from `$DATA_DIR/config/<server>/token.env`
  (`~/.config/opencode/mcp.env` does exactly that at shell start), so a new
  shell is all a client needs. A *spend* token is only exercised by a spend
  call, which the script never makes — it proves the server reloaded and keeps
  serving, and says so.
- **A secret that lives in a database is changed there first.** `postgres`
  runs `ALTER ROLE … PASSWORD` through psql on stdin, then rewrites `db.env`
  (`POSTGRES_PASSWORD` *and* the `DATABASE_URL` that embeds it) and `dump.env`,
  restarts postgres so its own environment agrees, and only counts it done when
  the role authenticates **over the podman network** — the image's `pg_hba.conf`
  trusts `127.0.0.1`, so a loopback probe succeeds with any password. The
  nightly `pg_dumpall` carries the role's new hash; a dump taken before the
  rotation would restore the old one.
- **`restic` adds before it removes.** The new key is created with
  `key add --new-password-file`, proven with `restic snapshots`, and only then is
  the old key removed — a run that dies in between leaves two working keys, not
  zero. Both passwords reach the container as 0600 files in the rotation dir
  (mounted at `/rot`), never on a command line. Note that
  `scripts/backup.sh` reads `RESTIC_PASSWORD` from the **environment first**, so
  a shell that exports the old value keeps using it until you update it.
- **`boltmesh-keys` is a logout button wearing a rotation's clothes.** It rewrites
  `SECRET_KEY`/`REFRESH_SECRET_KEY` (every session ends), `NODE_SECRET_KEY` and
  `BOOTSTRAP_SECRET_PEPPER` (every registered server and outstanding bootstrap
  secret stops verifying), and requires `--yes`.
- **`monero-wallet` is the careful one.** The wallet file's password exists in
  exactly two places — the file, and the rendered unit — so the change is made
  at the daemon (`change_wallet_password` over the wallet RPC), and both sides
  of that call are journaled *before* it is sent, because after it lands the old
  password may already be dead. It demands `--yes` and a snapshot younger than
  24 hours, and `--resume` knows from the journal whether the daemon call
  already happened (it must not be sent twice). Losses are not on the table: a
  Monero wallet is deterministic, so the worst case is a rescan from a snapshot.

**If a run dies half-way** the new values are already journaled (mode 600,
`$DATA_DIR/config/rotation/<target>.pending`) with the stage it reached, and no
daemon is left holding a credential that nobody recorded:

```sh
./scripts/rotate.sh --status        # what is pending, and which step it stopped at
./scripts/rotate.sh --resume        # finish it with the SAME values (never re-mints)
./scripts/rotate.sh --resume --yes  # when the target demands --yes (wallet, restic)
```

`--resume` also refuses to restart a daemon that is already running the journaled
value — it checks the container's own command line — so finishing a rotation that
was interrupted after the restart costs a verification, not a second outage.

`--force` skips the preflight (an unhealthy daemon, or a nightly backup in
flight, which would otherwise snapshot one side of a credential pair).

## Layout

```
stack/
  bootstrap.sh            # bare host -> podman, linger, sysctl, firewall ports, dirs
  deploy.sh               # the one-click orchestrator (asks for the data dir)
  verify.sh               # health + endpoint checks
  stack.conf              # repo / port / order manifest, data-dir + backup defaults
  renovate.json           # Renovate policy (pinned images and git refs)
  .github/workflows/ci.yml  # shellcheck + bash -n on the scripts
  scripts/lib.sh          # data-dir resolution + SELinux labelling + the
                          #   net_curl / mcp_* helpers every check goes through
  scripts/wallets.sh      # Monero + Bitcoin create/restore
  scripts/backup.sh       # restic backup / restore / inspect the repository
  scripts/monitor.sh      # scheduled health + spend sweep (monitor.timer)
  scripts/logs.sh         # cross-service log search over victoria-logs (LogsQL)
  scripts/ids.sh          # scheduled IDS roll-up (ids.timer): suricata + crowdsec
  scripts/spend-audit.sh  # spend drift + outgoing-activity tripwire
  scripts/rotate.sh       # rotate one credential + every dependent service
  scripts/npm-hosts.sh    # every nginx-proxy-manager proxy host, via its API
  scripts/kuma-monitors.sh # the status page's monitors (KUMA_MONITORS) + page, via socket.io
  deploy/
    install.sh            # the ONLY installer: units + secrets + data dirs
    *.container           # every unit, rendered (they reference the data dir)
    *.container.in        # lightningd, monero-wallet-rpc, fulcrum, rendered (secrets)
    *.timer               # backup.timer, monitor.timer (plain user units;
                          #   Quadlet has no .timer type)
    monitor.service       # the monitor script as a plain user unit
    npm-network.network
    crowdsec.container    # rootless: NPM access log -> decisions (local only)
    ids.service ids.timer # the IDS roll-up (plain user units)
    root/                 # the ONE rootful tier: suricata.container + its config,
                          #   rendered by install.sh --root (bootstrap.sh only)
    crowdsec/             # this repo's parser, scenarios, whitelists, acquisition;
                          #   rendered into $CONFIG_DIR/ids/crowdsec
    logs/vector.toml      # the shipper's config (journald -> victoria-logs),
                          #   rendered into $CONFIG_DIR/logs/vector
    monitoring/scrape.yml # what victoriametrics scrapes, rendered into place
    searxng/{settings.yml,limiter.toml}
    examples/<app>/*.example      # env-file shapes, kept in sync with install.sh by hand
    examples/stack/*.example      # bitcoin.conf / torrc / secrets templates
    examples/backup/*.example     # backup.env shape
    examples/monitoring/*.example # monitor.env shape (Apprise targets + heartbeat)
    examples/npm/*.example        # npm/api.env shape (the NPM admin API login)
    examples/boltmesh/*.example   # db/secrets/app/gateway env shapes
    examples/btc-explorer/*.example # btc-explorer.env shape (RPC + Fulcrum wiring)
  tor/Containerfile       # built by install.sh: the Tor proxy + onion services
  netcheck/Containerfile  # built by install.sh: the curl client the host checks run
  btc-explorer/Containerfile # built by deploy.sh: BTC RPC Explorer (stateless)
  xmr-explorer/Containerfile # built by deploy.sh: MoneroBlock (Go, RPC-only)
```

## Rollback

Everything is idempotent and every replaced real unit is backed up to
`~/.config/containers/systemd/<unit>.bak`. Restore the `.bak` beside its unit
and `systemctl --user daemon-reload`. To roll back an application, check out an
older commit in its repo and `./deploy.sh --only <app>`.
