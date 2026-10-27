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
| `bitcoind` | `docker.io/lncm/bitcoind:v27.2` | — | `$DATA_DIR/bitcoin` |
| `monerod` | `ghcr.io/sethforprivacy/simple-monerod:latest` | — | `$DATA_DIR/monero` |
| `fulcrum` | `docker.io/cculianu/fulcrum:v2.1.4` | `50001`, `50002` | `$DATA_DIR/fulcrum` |
| `btc-explorer` | `localhost/btc-explorer:local` (built from `btc-explorer/Containerfile`) | `127.0.0.1:8108` | — |
| `xmr-explorer` | `localhost/xmr-explorer:local` (MoneroBlock, built from `xmr-explorer/Containerfile`) | `127.0.0.1:8109` | — |
| `monero-wallet-rpc` | `ghcr.io/sethforprivacy/simple-monero-wallet-rpc:latest` | `127.0.0.1:18083` | `$DATA_DIR/monero-wallet-rpc` |
| `lightningd` | `docker.io/elementsproject/lightningd:latest` | `127.0.0.1:3010` (clnrest) | `$DATA_DIR/cln` |
| `tor` | `localhost/tor:local` (built from `tor/Containerfile`) | — | `$DATA_DIR/tor` |
| `valkey` | `docker.io/valkey/valkey:9-alpine` | — | — |
| `searxng` | `docker.io/searxng/searxng:latest` | `127.0.0.1:8080` | `$DATA_DIR/searxng` |
| `nginx-proxy-manager` | `docker.io/jc21/nginx-proxy-manager:latest` | `80`, `443`, `81` | `$DATA_DIR/npm/{data,letsencrypt}` |
| `uptime-kuma` | `docker.io/louislam/uptime-kuma:2` | `127.0.0.1:8107` | `$DATA_DIR/uptime-kuma` |
| `victoriametrics` | `docker.io/victoriametrics/victoria-metrics:v1.154.1` | `127.0.0.1:8428` | `$DATA_DIR/monitoring/vm` |
| `node-exporter` | `docker.io/prom/node-exporter:v1.12.1` | `127.0.0.1:9100` | — (serves `$DATA_DIR/monitoring/textfile`) |
| `searxng-mcp` | `localhost/searxng-mcp:latest` | `127.0.0.1:8100` | — |
| `bitcoin-node-mcp` | `localhost/bitcoin-node-mcp:latest` | `127.0.0.1:8101` | — |
| `monero-node-mcp` | `localhost/monero-node-mcp:latest` | `127.0.0.1:8102` | — |
| `monero-wallet-mcp` | `localhost/monero-wallet-mcp:latest` | `127.0.0.1:8103` 🔑 | — |
| `lightning-mcp` | `localhost/lightning-mcp:latest` | `127.0.0.1:8104` 🔑 | — |
| `postgres` | `docker.io/library/postgres:18-alpine` | — | `$DATA_DIR/postgres` |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `127.0.0.1:8105` | — |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | — | — |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | `127.0.0.1:8106` | — |

`bitcoind` and `monerod` are **full (archival) nodes**, storing and validating
the whole chain; `fulcrum` indexes that chain for Bitcoin wallets over the
Electrum protocol. See [Full nodes and disk](#full-nodes-and-disk) before sizing
the data disk. The two explorers read those services rather than keeping a
chain of their own — see [Block explorers](#block-explorers).

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
the services by container name on `npm-network`, through a throwaway curl
container on that network — `netcheck/Containerfile`, run by `net_curl` in
`scripts/lib.sh`; `net_curl_host` is that same container on the host network, for
NPM's own admin API on `127.0.0.1:81`. The proxy hosts are declared in `NPM_HOSTS`
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

A nightly, encrypted restic backup of the irreplaceable state (`cln/`,
`monero-wallet-rpc/`, `tor/`, `config/`, `npm/`, `audit/`, and the BoltMesh
database as a `pg_dumpall`) runs from `backup.timer` into
`$STACK_BACKUP_DIR`. It is the one thing that recovers you if the data disk
itself is lost — see [Backup & restore](#backup--restore).

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
creates the build dir and the quadlet directory, and clones this repo to
`~/build/stack`. `deploy.sh` then resolves and creates the data directories,
clones the app repos, builds every image, starts everything in order and
verifies.

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
stale image). The two explorer images are built only when missing — `--only`
forces a rebuild. Common flags:

```sh
./deploy.sh --only bitcoin-node-mcp   # rebuild and restart one service
./deploy.sh --only boltmesh           # rebuild + migrate the whole BoltMesh tier
./deploy.sh --only explorers          # rebuild both explorer images
./deploy.sh --only backup             # run the backup job now
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
  - `backup-cache/` — restic's cache (regenerable)

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

`bitcoind` and `monerod` are **full (archival) nodes**: `bitcoin.conf` is seeded
with `prune=0` and `monerod` runs without `--prune-blockchain`. Both store and
validate the entire chain, which dominates the data dir — roughly 800 GB for
Bitcoin and 250 GB for Monero as of late 2026, both growing. Fulcrum's Electrum
index adds roughly 100–135 GB and ~1–2 GB of RAM (`--db_mem 1024` caps its
RocksDB cache). Budget a 2 TB data disk. The chains and the index are excluded
from the backup set for exactly this reason: they are large and re-downloadable,
not irreplaceable state.

#### Speeding up the initial sync

The first Bitcoin sync is validation-bound, not bandwidth-bound, and the cost is
dominated by chainstate writes. `bitcoin.conf` is seeded with `dbcache=3072`
(MiB) for that reason: Core's default is 450, and the extra cache is the single
setting that materially shortens the initial block download. It does **not**
speed up the download of blocks — only their validation and the UTXO writes
behind it — so a node that is far behind still spends most of its time waiting
on peers.

On a small host, or while Fulcrum is indexing the same chain, lower it. The
value is a cache ceiling, not an allocation, so a too-large number mostly means
the kernel reclaims page cache instead:

```sh
podman exec bitcoind sh -c 'sed -i -e "s|^[[:space:]]*dbcache[[:space:]]*=.*|dbcache=1536|" /data/.bitcoin/bitcoin.conf'
systemctl --user restart bitcoind.service   # resumes the sync, no re-download
```

Once `getblockchaininfo` reports `"initialblockdownload": false`, drop it back
to `450`: the cache buys nothing in steady state and is RAM the rest of the
stack can use. As with `prune=`, `install.sh` seeds the file only when it is
missing, so an existing host keeps whatever it has until it is edited. Two
smaller knobs: `par=<n>` caps script-verification threads (default 0 = one per
core) and `maxmempool` shares unused memory with the same cache.

#### Converting a pruned host

Changing the config does not restore history. An existing pruned data directory
stays pruned (pruning is one-way), so both chains must be re-synced from
genesis. The wallets live outside the chain data — `monero-wallet-rpc/` and
`bitcoin/wallets/` — so they are untouched:

```sh
# The data dir you answered at install time (default: $HOME/data).
DATA_DIR="${STACK_DATA_DIR:-$HOME/data}"

# Bitcoin: edit its config as the container user, then drop only the pruned
# chain. The image uid owns bitcoin/, so the delete goes through podman unshare.
podman exec bitcoind sed -i -e 's|^[[:space:]]*prune[[:space:]]*=.*|prune=0|' /data/.bitcoin/bitcoin.conf
systemctl --user stop bitcoind.service
podman unshare rm -rf "$DATA_DIR/bitcoin/blocks" "$DATA_DIR/bitcoin/chainstate"
./deploy.sh --only bitcoind

# Monero: the node data dir is chain-only; the wallet is elsewhere.
systemctl --user stop monerod.service
podman unshare rm -rf "$DATA_DIR/monero"
./deploy.sh --only monerod
```

`./deploy.sh` cannot do this for you: `install.sh` seeds `bitcoin.conf` only
when it is missing, so an existing host keeps its old `prune=` line until it is
edited. Check the result with `podman exec bitcoind bitcoin-cli
getblockchaininfo` (`"pruned": false`); Monero does not report its prune state
through the restricted RPC, so a fresh `$DATA_DIR/monero` is the proof.

If `bitcoind` is restarted before its chain is dropped, it crash-loops with
`You need to rebuild the database using -reindex to go back to unpruned mode`.
Stop it and run the Bitcoin delete step above: removing `blocks/` and
`chainstate/` clears the `prunedblockfiles` flag in `blocks/index` and forces
the same full re-download a one-off `-reindex` would, without leaving a flag in
the unit.

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
- `scripts/backup.sh` — run it by hand and inspect what you have:
  `backup | init | list | ls | check | forget | restore <snap> | unlock`.
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

### Restoring onto a fresh host

If the disk that held `$DATA_DIR` is gone (or you want a second host), restore
from the repository **before** `./deploy.sh`:

```sh
export RESTIC_REPOSITORY=s3:…      # or /repo for the local default
export RESTIC_PASSWORD=…           # from your password manager

git clone https://github.com/regularnmae/stack ~/build/stack
cd ~/build/stack
./bootstrap.sh
./scripts/backup.sh restore latest # writes cln/, monero-wallet-rpc/, tor/, config/, npm/, audit/, uptime-kuma/, postgres-dump/
./deploy.sh                        # adopts the restored secrets and wallet
```

This works because `install.sh` never overwrites an existing file and resolves
secrets in the order `secrets.env → the installed unit → the daemon's config →
generate`: a restored `config/` and wallet are adopted as-is instead of being
regenerated. The Monero wallet directory comes back owned by the image uid
(`scripts/backup.sh` fixes that up), so `monero-wallet-rpc` opens it directly.

**The database is not restored by that step.** `postgres-dump/` comes back as a
file (`all.sql`), and `./deploy.sh` starts an empty `postgres` next to it. Replay
it once the stack is up, with the API and the worker stopped so nothing writes
underneath the load:

```sh
systemctl --user stop boltmesh-backend.service boltmesh-worker.service
podman exec -i postgres psql -U vpnuser -d postgres < "$DATA_DIR/postgres-dump/all.sql"
systemctl --user start boltmesh-backend.service boltmesh-worker.service
```

The dump was taken with `pg_dumpall --clean --if-exists`, so it recreates the
`vpndb` database itself. It also carries the role, which already exists on a host
whose `postgres/` was just initialised with the same credentials: `psql` reports
those role errors (`already exists`, or a role it will not drop while you are
connected as it), carries on because it is not run with `ON_ERROR_STOP`, and the
database load is what matters. Confirm the schema landed with
`podman exec postgres psql -U vpnuser -d vpndb -c '\dt'` before letting the API
back in.

> **Consistency:** the job snapshots `cln/` and the wallet while their daemons
> are running. CLN's `hsm_secret` and `emergency.recover` are static and restore
> cleanly even if `lightningd.sqlite3` is torn, so the worst case is a
> force-close and on-chain recovery, not lost funds; the wallet is written
> periodically, so a live copy is safe in practice.

## Monitoring & the spend tripwire

Nothing in the stack pages on its own: a container has a healthcheck and
`Restart=always` (so a crash restarts), but a crash-loop, an offline channel, a
stalled chain or a spend is otherwise silent. `install.sh` installs a monitor
that closes that gap.

- `scripts/monitor.sh` — runs every five minutes from
  `deploy/monitor.timer`. Read-only: it starts nothing and rewrites no config.
  It runs `verify.sh` for the container/MCP base checks and adds the ones
  nothing else does — bitcoind freshness, CLN peers and **offline channels**,
  the Monero wallet's lag behind `monerod`, the host itself (disk and inode
  space, disk saturation, backup age, certificate expiry, units that
  crash-looped since the last sweep, and the metrics collector going quiet) —
  then the spend tripwire.
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
`MONITOR_CERT_MIN_DAYS`, `MONITOR_RESTART_MAX`, `MONITOR_METRICS_MAX_AGE_S`, …);
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
| `node-exporter` | the host: disk space, inodes, I/O saturation, memory, load — plus the **textfile collector**, which is how the stack's own numbers get in |
| `scripts/metrics.sh` (`deploy/metrics.timer`, every minute) | writes `$DATA_DIR/monitoring/textfile/stack.prom`: chain heights and IBD, Fulcrum's index height, CLN peers/offline channels, `monerod`'s restricted-RPC **reachability**, the wallet's lag |
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

No Grafana: `vmui` is a PromQL frontend with charts, and one less container on a
disk that is the stack's bottleneck is worth more than dashboards.

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
  scripts/spend-audit.sh  # spend drift + outgoing-activity tripwire
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
