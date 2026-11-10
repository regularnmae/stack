# stack

The whole server stack for the mainnet host, in one repo: every podman/quadlet
unit, every secret/env wiring, and a one-click deploy that can rebuild the host
from scratch.

The application code lives in sibling repos — `searxng-mcp`,
`bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`, `lightning-mcp`,
`fulcrum-mcp`, `victoria-logs-mcp`, `victoriametrics-mcp`, `crowdsec-mcp`,
`btcpay-mcp`,
plus BoltMesh's
`backend` and `frontend`
(under the `boltmesh-labs` org) — each of which ships only its code, tests, CI
and `Containerfile`. **Their units and env files live here**, so there is
exactly one place that defines how the stack runs and one script that fixes a
deployment problem.

## What runs

| Unit | Image | Published on the host | Data |
| --- | --- | --- | --- |
| `bitcoind` | `docker.io/lncm/bitcoind:v28.0` | — | `$DATA_DIR/bitcoin` |
| `monerod` | `ghcr.io/sethforprivacy/simple-monerod:v0.18.5.4` | — | `$DATA_DIR/monero` |
| `fulcrum` | `docker.io/cculianu/fulcrum:v2.1.4` | `50001`, `50002` | `$DATA_DIR/fulcrum` |
| `btc-explorer` | `localhost/btc-explorer:local` (built from `btc-explorer/Containerfile`) | `127.0.0.1:8108` | — |
| `xmr-explorer` | `localhost/xmr-explorer:local` (MoneroBlock, built from `xmr-explorer/Containerfile`) | `127.0.0.1:8109` | — |
| `btcpay` | `docker.io/btcpayserver/btcpayserver:2.4.5` | `127.0.0.1:49392` (NPM: `btcpay.boltmesh.net`; an SSH tunnel to the same port still works) | `$DATA_DIR/btcpay` |
| `nbxplorer` | `docker.io/nicolasdorier/nbxplorer:2.6.21` | — | `$DATA_DIR/nbxplorer` |
| `monero-wallet-btcpay` | `docker.io/btcpayserver/monero:0.18.5.4` | — (BTCPay only) | `$DATA_DIR/btcpay/xmr-wallet` |
| `lightningd` | `docker.io/elementsproject/lightningd:v26.06.9` | — (clnrest internal for the MCP) | `$DATA_DIR/cln` |
| `tor` | `localhost/tor:local` (built from `tor/Containerfile`) | — | `$DATA_DIR/tor` |
| `valkey` | `docker.io/valkey/valkey:9.1.3-alpine` | — | — |
| `searxng` | `docker.io/searxng/searxng:2026.10.29-cff884f98` | `127.0.0.1:8082` | `$DATA_DIR/searxng` |
| `nginx-proxy-manager` | `docker.io/jc21/nginx-proxy-manager:2.16.0` | `80`, `443`, `81` | `$DATA_DIR/npm/{data,letsencrypt}` |
| `netcheck`, `netcheck-host` | `localhost/netcheck:local` (built from `netcheck/Containerfile`) | — | — |
| `uptime-kuma` | `docker.io/louislam/uptime-kuma:2` | `127.0.0.1:8107` | `$DATA_DIR/uptime-kuma` |
| `victoriametrics` | `docker.io/victoriametrics/victoria-metrics:v1.155.0` | `127.0.0.1:8428` | `$DATA_DIR/monitoring/vm` |
| `alertmanager` | `docker.io/prom/alertmanager:v0.34.2` | `127.0.0.1:9093` | `$DATA_DIR/monitoring/alertmanager` (silences, notification log) |
| `node-exporter` | `docker.io/prom/node-exporter:v1.12.1` | host network, `:9100` (wildcard bind; LAN closed by firewall) | — (serves `$DATA_DIR/monitoring/textfile`) |
| `victoria-logs` | `docker.io/victoriametrics/victoria-logs:v1.53.0` | `127.0.0.1:9428` | `$DATA_DIR/logs/vl` |
| `vector` | `docker.io/timberio/vector:0.61.0-debian` | — | `$DATA_DIR/logs/vector` (checkpoint) |
| `searxng-mcp` | `localhost/searxng-mcp:latest` | `127.0.0.1:8100` | — |
| `bitcoin-node-mcp` | `localhost/bitcoin-node-mcp:latest` | `127.0.0.1:8101` | — |
| `monero-node-mcp` | `localhost/monero-node-mcp:latest` | `127.0.0.1:8102` | — |
| `monero-wallet-mcp` | `localhost/monero-wallet-mcp:latest` | `127.0.0.1:8103` 🔑 | — |
| `lightning-mcp` | `localhost/lightning-mcp:latest` | `127.0.0.1:8104` 🔑 | — |
| `fulcrum-mcp` | `localhost/fulcrum-mcp:latest` | `127.0.0.1:8110` | — |
| `victoria-logs-mcp` | `localhost/victoria-logs-mcp:latest` | `127.0.0.1:8111` | — |
| `victoriametrics-mcp` | `localhost/victoriametrics-mcp:latest` | `127.0.0.1:8112` | — |
| `crowdsec-mcp` | `localhost/crowdsec-mcp:latest` | host network, `127.0.0.1:8113` (the app's own bind) | — |
| `btcpay-mcp` | `localhost/btcpay-mcp:latest` | `127.0.0.1:8114` | — |
| `postgres` | `docker.io/library/postgres:18-alpine` | — | `$DATA_DIR/postgres` |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | `127.0.0.1:8105` | — |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | — | — |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | `127.0.0.1:8106` | — |
| `crowdsec` | `docker.io/crowdsecurity/crowdsec:v1.8.2` | host network, `127.0.0.1:8080` (LAPI, key-gated) | `$DATA_DIR/ids/crowdsec` |
| `suricata` ⚙️ | `docker.io/jasonish/suricata:8.0.8` | host network (IDS only, publishes nothing) | `$DATA_DIR/ids/suricata` |
| `stack-bouncer` ⚙️ | — (a host script on a system timer, `deploy/root/bouncer.sh`) | — (writes the `inet stack_bans` nft set) | `$DATA_DIR/audit/bouncer.status` |

`bitcoind` and `monerod` are **full (archival) nodes**, storing and validating
the whole chain; `fulcrum` indexes that chain for Bitcoin wallets over the
Electrum protocol. `btcpay` (with `nbxplorer`) is the settlement engine: it
creates invoices, watches the store's addresses, and receives the Lightning and
Monero rails. NBXplorer needs bitcoind's P2P port, which is why `bitcoin.conf`
must run with `listen=1` (still unpublished). See [Full nodes and disk](#full-nodes-and-disk) before sizing
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
and `btcpayserver/monero` together (an upgrade is driven by a hardfork height, and a
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
`~/.config/containers/containers.conf`, or in a drop-in under
`~/.config/containers/containers.conf.d/` — where the stack's own `99-stack.conf`
lives), which does preserve the source address,
but Rocky 10's podman 5.8 has no such key.

Because NPM is no longer a peer on `npm-network` (`10.89.0.0/24`, pinned in
`deploy/npm-network.network` because `tor.container` pins `--ip=10.89.0.240` and
both `bitcoin.conf` and `torrc` allow that subnet), it cannot resolve a container
name. The four containers behind onion services also pin their IPs
(`10.89.0.241`–`.244`) for a related reason: tor validates a
`HiddenServicePort` target at startup, so a container *name* that does not exist
yet would keep tor from starting at all. Every unit it proxies to therefore publishes its port on the **host's
loopback** only — the `127.0.0.1:…` entries above, i.e.
`PublishPort=127.0.0.1:…` in that unit — and the `[npm.*]`/`[mcp.*]` tables in
`deploy/services.toml` name `127.0.0.1`, not a container. A loopback bind is invisible to
the LAN, so NPM (which terminates TLS) plus each server's bearer token are still
the one way in for a client. The host-side checks (`verify.sh`, the monitor) read
the services by container name on `npm-network`, through `net_curl` in
`scripts/lib.sh`, which execs into the long-lived **`netcheck`** container
(`netcheck/Containerfile`); `net_curl_host` uses **`netcheck-host`**, the same
image on the host network, for NPM's own admin API on `127.0.0.1:81`. One path
is deliberately the exception: the monitor's alerts go to Alertmanager on
`127.0.0.1:9093` and its dead-man's-switch heartbeat out to the internet with
the **host's own curl** (`bootstrap.sh` installs it), because a container
cannot be what reports a broken container runtime. The proxy
hosts are declared in `deploy/services.toml`
and reconciled from this repo by `scripts/npm-hosts.sh` — see
[Proxy hosts](#proxy-hosts). The hosts
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
> whose rendered file changed (`searxng`, the daemons, the app tier), so it is
> the only command needed. If NPM was restarted by hand first, park the
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
`btcpay/` (plugin + the view-only wallet), `tor/`, `config/`, `npm/`, `audit/`,
`uptime-kuma/`, and the three live databases as dumps: BoltMesh's `pg_dumpall`,
NPM's SQLite copy and kuma's `mariadb-dump`) runs from `backup.timer` into
`$STACK_BACKUP_DIR`, and `backup-verify.timer` restores one snapshot a week to
prove it works. `backup-verify-db.timer` then proves once a month that the
`pg_dumpall` actually replays into a cluster. It is the one thing that recovers
you if the data disk
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

`bootstrap.sh` installs podman/firewalld/git/jq/curl/openssl, enables user
linger, sets
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
./configure.sh        # second step: runes, wallet, BTCPay state, migrations
```

`bootstrap.sh` uses `sudo` for the privileged host setup (packages, linger, the
sysctl, firewalld); `sudo` needs a terminal to prompt, so run it from an
interactive shell (over SSH, `ssh -t`). `deploy.sh`, `configure.sh` and
`verify.sh` never use `sudo`.

`deploy.sh` and `configure.sh` need only the host's own `python3`: the
reconciler (`scripts/stackctl/`) is stdlib-only, so there is no venv and no
pip step in a deploy.

On the first run, `deploy.sh` asks **where the stack keeps its data** (default
`$HOME/data`) and remembers the answer; point it at a separate disk to survive
an OS reinstall. See [Where the data lives](#where-the-data-lives).

`deploy.sh` is idempotent and never destructive: re-running reuses every
existing secret, leaves the running daemons alone, and rebuilds the ten MCP
servers and the BoltMesh app tier, but **restarts only what actually changed** —
a unit whose rendered definition differs, or a container running an image older
than the tag the build just produced. An unchanged image and unit means no
outage, not a restart for its own sake. It also records the unit definitions it
applied in `$DATA_DIR/audit/units.applied`, while `deploy/install.sh` records
what it rendered in `units.rendered` — so running the installer by hand shows up
as drift (`./verify.sh` fails naming the units) instead of being swallowed by the
next deploy. The four images built here — the two explorers, `netcheck`
and `tor` — are rebuilt when their Containerfile changed and left
alone otherwise: the digest of that file is baked into the image as a label, so
a merged base-image bump reaches the host on the next deploy instead of needing
a hand rebuild (`--only` forces one anyway). `deploy.sh` does not run
`verify.sh`, and it never waits for a container's health or for a chain to
sync: verification is the separate `./verify.sh` (or the monitor's sweep), and
the work that can only happen against a *running* stack is the second step,
`./configure.sh` (Bitcoin wallet, CLN runes, BTCPay databases/plugin
wallet/bootstrap, BoltMesh migrations). Common flags:

```sh
./deploy.sh --only bitcoin-node-mcp   # rebuild and restart one service
./deploy.sh --only boltmesh           # rebuild/start the whole BoltMesh tier
./deploy.sh --only explorers          # rebuild both explorer images
./deploy.sh --only backup             # run the backup job now
./deploy.sh --only backup-verify      # run the restore drill now (weekly on a timer)
./deploy.sh --only backup-verify-db   # replay the snapshot's postgres dump now (monthly on a timer)
./deploy.sh --only monitor            # run the health + spend checks now
./deploy.sh --only victoria-logs      # generic unit restart after a LOGS_* change or image bump
./deploy.sh --only vector             # generic unit restart after deploy/logs/vector.toml changes
./deploy.sh --only npm-hosts          # re-apply every proxy host in NPM
./deploy.sh --only tor                # generic unit restart; the onion services re-render into torrc
./deploy.sh --only crowdsec           # generic unit restart; its parsers/scenarios re-render
./deploy.sh --only agent-skills       # re-link the agent skills + agent-mcp
./deploy.sh --skip-apps               # infrastructure only (daemons, searxng, NPM)
./deploy.sh --skip-agent-skills       # leave the operator's harnesses untouched
./deploy.sh --dry-run                 # print the plan, change nothing
./configure.sh                        # wait for each service, then do the post-start work
./configure.sh --only runes           # one section (wallet|runes|btcpay|boltmesh|agents)
./configure.sh --skip-daemons         # no daemon-dependent work (wallet/runes/BTCPay/handshake)
./configure.sh --skip-apps            # no BoltMesh migrations
./configure.sh --no-wallets           # skip the interactive wallet prompts
./configure.sh --dry-run              # print the plan, change nothing
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
`deploy.sh` starts the containers and does **not** wait for sync or health. Run
`./configure.sh` after it (and again once the chains are current): it waits for
the daemons, then mints the CLN runes, imports the wallets and bootstraps BTCPay.

### Wallets

A bare host has a Bitcoin Core wallet, created by `scripts/wallets.sh`
(prompted by `./configure.sh` when a TTY is present; skipped without one).

The BTCPay Monero wallet is different and is never generated on the payment
server: `scripts/btcpay-wallet.sh` imports a **view-only** wallet into the
dedicated plugin wallet-rpc from `$DATA_DIR/config/btcpay/xmr-wallet.env`:

```sh
XMR_WALLET_ADDRESS=<primary address>
XMR_VIEW_KEY=<private view key>
XMR_RESTORE_HEIGHT=<height>
```

Keep the spend key offline (a hardware/offline wallet). Until these are filled
in, XMR-CHAIN stays disabled and `btcpay-bootstrap` re-enables it on the next
`./configure.sh --only btcpay`. The import also refuses while monerod is below
the restore height: a wallet cannot open above the daemon's height (Monero's
"Blocks start before blockchain offset"), and the stalled refresh takes the
plugin's wallet RPC down with it. The env can be filled at any time; re-run
`./configure.sh --only btcpay` once the chain is current. The plugin wallet is
internal-only and holds no spend key, so `monero-wallet-mcp` can read it but
cannot move funds.

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
  existing `fulcrum` for address history. `bitcoin.conf` sets `txindex=1`, so
  any historical txid also resolves without a block height; on a node that
  already has the blocks, bitcoind builds that index in the background from
  `blk*.dat` (no `-reindex`, no revalidation — hours of disk I/O, not a resync).
  Until Fulcrum's index has caught up, the explorer logs
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

  - `bitcoin/ monero/ fulcrum/ btcpay/ nbxplorer/ cln/ tor/ searxng/` — daemon state
    (`tor/onion/` holds the onion services' keys, `tor/torrc` the config; `fulcrum/`
    is the Electrum index and its self-signed certificate, regenerable and excluded
    from backups)
  - `npm/{data,letsencrypt}` — nginx-proxy-manager
  - `uptime-kuma/` — the status page's state (its embedded MariaDB, history and
    login; configured in its UI). The live `mariadb/` datadir is excluded from
    the backup — see below
  - `ids/` — the two IDS engines' state: suricata's `eve.json` and rules
    (root-owned) and crowdsec's database beside them (see
    [Intrusion detection](#intrusion-detection))
  - `postgres/` — the BoltMesh database (dumped before backup, not copied raw)
  - `postgres-dump/` — the pre-backup `pg_dumpall`
  - `npm-dump/` — NPM's SQLite database as a consistent copy, written before
    each backup (`scripts/db-dump.sh`)
  - `uptime-kuma-dump/` — kuma's database as a `mariadb-dump`, written by the
    same job
  - `config/` — every bearer token and secret
  - `bin/` — the two scripts `install.sh` stages for the containers that run them
    (`monerod`'s block-notify helper, the BTCPay bootstrap); rewritten on every
    deploy, so edit the copy in the repo, not this one
  - `audit/` — the monitor's log, the spend tripwire baselines and the
    rendered/applied unit digests
  - `monitoring/` — the metrics store (`vm/`) and node-exporter's textfile
    (both regenerable, both excluded from backups)
  - `logs/` — the log store (`vl/`) and `vector`'s checkpoint; journald history,
    regenerable and excluded from backups
  - `backup-cache/` — restic's cache (regenerable)
  - `backup-verify/` — the restore drill's scratch target; a copy of the backup
    set, wiped before and after every drill (regenerable, excluded from backups)
  - `backup-verify-db/` — the database drill's scratch target; just the
    snapshot's `postgres-dump/`, same lifecycle (regenerable, excluded from
    backups)

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
mount their subdirectories with `:z` (shared), which podman relabels rootlessly
on every start, so `deploy.sh` only needs a top-level label and attempts it
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
roughly 100–135 GB and ~2–4 GB of RAM (`--db_mem` is left at Fulcrum's own
autodetect, 2048 MiB here; a rebuild is compaction-bound below that). Budget a
2 TB data disk. The chains and the index are excluded from the backup set for
exactly this reason: they are large and re-downloadable, not irreplaceable
state.

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
   ./configure.sh              # runes, wallets, BTCPay state, migrations
   ./verify.sh --deep
   ```

`deploy.sh` finds the existing
`bitcoin/ monero/ fulcrum/ btcpay/ nbxplorer/ cln/ tor/ npm/ config/ bin/` there
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
everything in `$DATA_DIR` that cannot be re-downloaded:

- `cln/` — the CLN identity, channel state and onion keys
- `btcpay/` — BTCPay's datadir, the pinned Monero plugin and the view-only wallet
- `tor/` — `torrc` and the onion services' keys (see [Tor onion services](#tor-onion-services))
- `config/` — every token, rune and secret
- `npm/` — nginx-proxy-manager's config and TLS material
- `audit/` — the monitor's log, the spend baselines and the unit digests
- `uptime-kuma/` — the status page's state (see [Status page](#status-page)), minus
  the live datadir
- `postgres-dump/`, `npm-dump/`, `uptime-kuma-dump/` — the three live databases as
  dumps, taken immediately before each run

The chains, the Electrum index, `searxng/`, `bin/` and the raw `postgres/` cluster
are excluded: large, and regenerable. The live databases are **dumps, never file
copies** — a file-by-file copy of something a daemon is writing is only
crash-recoverable. `docs/backup.md` carries that reasoning, the set's declaration
(`BACKUP_PATHS`/`BACKUP_EXCLUDES` in `stack.conf`) and what each drill proves.

Run it by hand:

```sh
./deploy.sh --only backup                 # the nightly job, now
./scripts/backup.sh backup                # ... and refresh the dumps first
./scripts/backup.sh list                  # snapshots in the repository
./scripts/backup.sh ls latest             # what one snapshot holds
./scripts/backup.sh check                 # repository integrity
./scripts/backup.sh restore <snap>        # the whole set, in place
./scripts/backup.sh unlock                # after a killed run
```

`backup.timer` runs at 03:30 with 30 minutes of jitter; `db-dump.service` (or the
`backup` action above) writes the dumps just before it. The repository is
`$STACK_BACKUP_DIR` (default `$HOME/data-backup`) mounted at `/repo` — outside
`$DATA_DIR`, so wiping the data dir leaves it alone. A same-disk repository does
not survive the disk: for real disaster recovery point `RESTIC_REPOSITORY` in
`config/backup/backup.env` at an offsite target (`s3:`, `b2:`, `sftp:`).

**Keep `RESTIC_PASSWORD` somewhere other than the data disk.** It encrypts the
whole repository: no password, no restore. `scripts/backup.sh` reads
`RESTIC_REPOSITORY`/`RESTIC_PASSWORD` from the environment first and the file
second — the `backup.env` it would read lives inside the repository it opens.

### Disaster recovery

Four things decide whether a bad day costs an afternoon or a week: the repository
is **off the data disk**, `RESTIC_PASSWORD` is **off the host**, the Monero seed is
**on paper**, and you restore **before** running `./deploy.sh`. The runbooks below
assume all four; the last one covers losing them.

#### Before you need it

- `RESTIC_REPOSITORY` and `RESTIC_PASSWORD`, in a password manager or on paper.
  They locate and decrypt everything else. Point the repository at an offsite
  target (`s3:`, `b2:`, `sftp:`) — a same-disk repository survives deletion, not
  the disk.
- The Monero **25-word seed**, written down when the wallet was created. The
  wallet file is in the backup; the seed is what survives losing both.
- An SSH key that can clone the private `boltmesh-labs` repos, and DNS for the
  public hostnames (nginx-proxy-manager requests their certificates).
- Nothing else: `config/`, `tor/onion/`, `cln/` and the wallet all come out of the
  repository.

#### Pick the runbook

| What happened | Go to | Lost since the snapshot |
| --- | --- | --- |
| bad config, torn wallet cache, lost onion key, broken CLN state — disk fine | [State is wrong, disk is fine](#state-is-wrong-disk-is-fine) | that state only |
| data disk lost, host replaced, OS reinstalled onto a new disk | [The data disk is gone](#the-data-disk-is-gone-or-a-new-host) | everything written after it |
| host compromised | [The host was compromised](#the-host-was-compromised) | everything, plus every credential |
| repository or its password lost | [When a piece is missing](#when-a-piece-is-missing) | whatever is not off-host |

#### State is wrong, disk is fine

Restoring **in place** is safe as long as nothing is writing to the directories
being replaced, so stop the daemons that own them:

```sh
systemctl --user stop lightningd btcpay nbxplorer monero-wallet-btcpay tor nginx-proxy-manager uptime-kuma
./scripts/backup.sh ls latest      # what the snapshot holds, before overwriting anything
./scripts/backup.sh restore latest # in place; add -y when there is no TTY
./deploy.sh                        # adopts, re-renders, restarts, reconciles
./configure.sh                     # waits, then mints runes and writes the btcpay env
# then replay the live databases (the next section) -- the servers are up but empty
./verify.sh --deep
```

For one path only — a lost `tor/onion/`, a corrupted
`config/stack/secrets.env` — mount just that directory and ask restic for just
that path:

```sh
podman run --rm \
  -v "$HOME/data-backup:/repo:z" -v "$DATA_DIR/backup-cache:/cache:z" \
  -v "$DATA_DIR/config:/data/config:z" \
  --env-file "$DATA_DIR/config/backup/backup.env" \
  docker.io/restic/restic:0.19.1 restore latest --target / --include /data/config
```

Then restart what reads it (`./deploy.sh` for config, `./deploy.sh --only tor`
for the onion keys). Re-mint the runes with `./configure.sh --only runes`: the
restored `config/` carries runes the node may no longer know. Keep the
single-directory mount — a target of `/` with the whole data dir mounted is an
in-place restore of everything, which is the previous runbook.

#### Replay the live databases

The three live databases are in the snapshot as dumps, so a restore leaves the
servers with nothing to open. Postgres's `postgres-dump/all.sql` is replayed in
[step 5 of the next runbook](#the-data-disk-is-gone-or-a-new-host). The other two:

NPM's copy is a consistent single file — stop NPM, put it in place, start it:

```sh
systemctl --user stop nginx-proxy-manager
install -m 600 "$DATA_DIR/npm-dump/database.sqlite" "$DATA_DIR/npm/data/database.sqlite"
systemctl --user start nginx-proxy-manager
```

kuma's is SQL, so it needs a datadir to import into. `./deploy.sh` has already had
kuma initialise one (empty); replace it with a fresh datadir carrying the dump:

```sh
systemctl --user stop uptime-kuma
podman unshare rm -rf "$DATA_DIR/uptime-kuma/mariadb"
mkdir -p "$DATA_DIR/uptime-kuma/mariadb"
podman run --rm --network none \
  -v "$DATA_DIR/uptime-kuma/mariadb:/var/lib/mysql:z" \
  -v "$DATA_DIR/uptime-kuma-dump:/dump:ro,z" \
  --entrypoint /bin/sh \
  "$(podman inspect uptime-kuma --format '{{.ImageName}}')" -c '
    set -e
    mariadb-install-db --user=root --datadir=/var/lib/mysql --auth-root-authentication-method=normal >/dev/null
    mariadbd --user=root --datadir=/var/lib/mysql --socket=/tmp/m.sock --skip-networking --pid-file=/tmp/m.pid >/dev/null 2>&1 &
    i=0
    until mariadb --socket=/tmp/m.sock -u root -e "select 1" >/dev/null 2>&1; do
        i=$((i+1)); [ "$i" -lt 60 ] || { echo "mariadbd did not start" >&2; exit 1; }; sleep 2
    done
    mariadb --socket=/tmp/m.sock -u root < /dump/kuma.sql'
# the container ran as root; kuma runs as its own uid inside the image
podman unshare chown -R 1000:1000 "$DATA_DIR/uptime-kuma/mariadb"
systemctl --user start uptime-kuma
```

`mariadb-install-db` builds the system tables the dump deliberately does not
carry; the dump recreates the `kuma` database and its tables.
`./scripts/backup.sh verify --with-db` runs the same import, so a passing drill is
a rehearsal of this step. Confirm both replays with `./verify.sh --deep` and by
the status page and proxy hosts actually serving.

#### The data disk is gone (or a new host)

Order is load-bearing: **restore, then deploy.** `install.sh` seeds
`bitcoin.conf` and `torrc` once and never overwrites them, so a `./deploy.sh` that
runs first writes a *fresh* RPC password into `bitcoin.conf`, and the restored
`config/stack/secrets.env` then disagrees with the daemon.

1. Rebuild the host and the data disk, then get this repo:

   ```sh
   git clone https://github.com/regularnmae/stack ~/build/stack
   cd ~/build/stack
   ./bootstrap.sh
   ```

2. Open the repository **from the environment** (there is no `backup.env` on a
   fresh host), and prove the password before writing anything:

   ```sh
   export RESTIC_REPOSITORY=s3:…   # or /repo, or the path of a copied repository
   export RESTIC_PASSWORD=…        # from your password manager
   ./scripts/backup.sh list        # a snapshot list here means the repo and key are right
   ```

3. Restore into the data dir. Setting `STACK_DATA_DIR` for this one command both
   places the files and remembers the answer, so `deploy.sh` will not prompt:

   ```sh
   STACK_DATA_DIR=/data/stack ./scripts/backup.sh restore latest -y
   ```

   It writes the whole set and hands bitcoind's directory back to the image uid,
   so bitcoind opens it directly.

4. Deploy and configure. `deploy.sh` adopts the restored secrets (never
   overwriting an existing file), seeds `bitcoin.conf`/`torrc` from them, builds
   the images and reconciles the proxy hosts. `configure.sh` does the work that
   needs the restored daemons up: it proves the restored CLN runes with
   `checkrune` (minting new ones if the node does not know them) and writes
   `config/btcpay/backend.env` from the bootstrap state.

   ```sh
   ./deploy.sh
   ./configure.sh
   ```

5. Replay the database. It comes back as a file, not a running server, and the
   `postgres` that `deploy.sh` started is empty:

   ```sh
   systemctl --user stop boltmesh-backend.service boltmesh-worker.service
   podman exec -i postgres psql -U vpnuser -d postgres < "$DATA_DIR/postgres-dump/all.sql"
   ./configure.sh --only boltmesh  # alembic upgrade head
   systemctl --user start boltmesh-backend.service boltmesh-worker.service
   ```

   The dump was taken with `pg_dumpall --clean --if-exists`, so it recreates the
   `vpndb` database itself. It also carries the role, which already exists on the
   freshly initialised cluster: `psql` reports those role errors, carries on
   because it is not run with `ON_ERROR_STOP`, and the database load is what
   matters. Confirm the schema with
   `podman exec postgres psql -U vpnuser -d vpndb -c '\dt'`, then migrate — the
   dump is as old as the snapshot, the code is not.

6. Replay the other two — NPM's `database.sqlite` and kuma's MariaDB: see
   [Replay the live databases](#replay-the-live-databases).

7. Check it with [After any recovery](#after-any-recovery). The chains and
   Fulcrum start from zero — see
   [What comes back](#what-comes-back-what-re-downloads) for what that costs.

#### The host was compromised

Assume every secret in the snapshot is known to whoever had the host: restoring is
the fastest way back, not a recovery. Follow the runbook above, then treat every
credential as burned:

```sh
./scripts/rotate.sh --list            # what this repo can rotate
./scripts/rotate.sh --dry-run <target>
./scripts/rotate.sh <target>          # write, re-render, restart, prove
```

That covers every target `--list` shows. There is no wallet target: BTCPay's
Monero wallet is imported view-only and has no password. `boltmesh-keys` requires
`--yes` (it ends every session and invalidates every node token), and `restic`
writes the new password before adding the key, so a run that dies in between
leaves two working keys, never none.

What rotation cannot fix:

- **The view-only wallet's history.** `btcpay/xmr-wallet` can leak the view key and
  the address — no spend key was ever here, so funds are not at risk — but every
  transaction it can see is then public. Move the funds to a new seed and re-import
  the view-only wallet from it (`scripts/btcpay-wallet.sh`).
- **CLN's `hsm_secret`**, the node's signing key. Treat the channels as lost:
  force-close them so the funds land in a wallet you control, and open new channels
  from a fresh node.
- **The old snapshots.** Rotating the restic key protects new snapshots; the old
  password still opens everything already in the repository. Start a fresh
  repository, or accept that the old ones are readable.
- **The onion addresses.** Nothing rotates them; delete `tor/onion/<name>/` so tor
  generates new ones, then tell every client — the address is the key.
- **Anything the tokens grant outside this stack** — revoke those at the provider.

#### When a piece is missing

- **The repository is gone**, no offsite copy: nothing in it is recoverable. The
  stack comes back with new identities — a new CLN node, new onion addresses, a
  new wallet (funds only from the seed) — and every token re-issued.
- **`RESTIC_PASSWORD` is gone**: the repository is unreadable. No recovery.
- **`tor/onion/` is gone**, the rest restored: every `.onion` address changes. The
  wildcard `*.onion` proxy host keeps working; clients holding the old address do
  not.
- **`cln/` is gone**, `config/` restored: a new node identity. The runes in
  `config/lightning-mcp/node.env` are dead; `./configure.sh` mints new ones. The
  channels are gone with the `hsm_secret` — CLN has no seed phrase, which is why
  `cln/` is the most valuable directory in the set.
- **`btcpay/` is gone**, `config/` restored: re-run `./configure.sh --only btcpay`.
  The datadir's keys and the plugin are recreated, the store is in Postgres, and
  `scripts/btcpay-wallet.sh` re-imports the view-only wallet.

#### What comes back, what re-downloads

| Path | Backed up | After a fresh-host restore |
| --- | --- | --- |
| `config/`, `tor/`, `audit/` | yes | exactly as snapshotted |
| `npm/` | yes | config and TLS material; the database is a dump (next rows) |
| `uptime-kuma/` | yes | monitors, login and uploads; the database is a dump (next rows) |
| `cln/` | yes | channels as of the snapshot; an older state can force-close |
| `btcpay/` | yes | the plugin and view-only wallet reopen; may rescan against `monerod` |
| `postgres-dump/all.sql` | yes | a file — replay it (step 5) |
| `npm-dump/database.sqlite` | yes | a file — copy it over `npm/data/database.sqlite` (step 6) |
| `uptime-kuma-dump/kuma.sql` | yes | SQL — import it into a fresh datadir (step 6) |
| `bitcoin/` | no | re-download; `bitcoin.conf` is seeded from the restored secret |
| `monero/` | no | re-download |
| `fulcrum/` | no | re-index from block 0: weeks on this disk (see [Full nodes and disk](#full-nodes-and-disk)) |
| `searxng/`, `monitoring/` | no | recreated; the metrics history is gone |
| `postgres/` | no | a new cluster, then the dump is replayed into it |
| the bitcoind wallet | no | a new empty descriptor wallet (export a `.dat` if you keep funds there) |

Rough order of magnitude on a rotational disk: bitcoind validation days to weeks,
monerod a few days, Fulcrum's index weeks. All three run at once, and none blocks
the wallet, CLN, BoltMesh or the MCP surface from coming up — the stack is
*serving* long before it is *synced*.

> **Consistency:** the job snapshots `cln/` and the wallet while their daemons run.
> CLN's `hsm_secret` and `emergency.recover` are static and restore cleanly even if
> `lightningd.sqlite3` is torn, so the worst case is a force-close and on-chain
> recovery, not lost funds. "Safe" means *funds*: a wallet cache captured
> mid-rebuild is rejected when loaded, and the wallet rescans — unavailable RPC
> until it finishes, which `monitor.sh` reports. The keys file always restores.
> Do not restart a wallet to "check" it: every restart throws away the pass.

#### After any recovery

```sh
./verify.sh --deep                  # containers, MCP handshakes, chains, Fulcrum
./scripts/monitor.sh                # the sweep, including backup age, the dumps and the drill
./scripts/spend-audit.sh            # ENABLE_SPENDING=0 and no drift
./scripts/backup.sh verify          # the new repository restores too
```

Then the things a sweep cannot judge:

- `podman exec lightningd lightning-cli listpeerchannels` — are the channels back,
  in the state you expect?
- `systemctl --user list-timers` — backup, drill, monitor and metrics scheduled;
  `./scripts/backup.sh list` shows the nightly job writing again.
- the `.onion` addresses match what clients hold (`./deploy.sh` and
  `scripts/npm-hosts.sh` print them).
- `scripts/rotate.sh --status` — only the rune pair in
  `lightning-mcp/node.env` is live, and bitcoind's `rpcpassword` matches
  `secrets.env`.
- `audit/` came back from the snapshot, so if anything happened after it,
  `scripts/spend-audit.sh --rebaseline` is the deliberate "known-good now" act.

### Verifying the backups

A nightly snapshot that has never been opened is a hope, not a backup, so a second
timer opens one. `backup-verify.timer` runs `scripts/backup.sh verify` every Sunday
at 05:30, two hours after the nightly job so it proves a *fresh* snapshot and
cannot collide with the backup's restic lock:

```sh
./scripts/backup.sh verify              # check + restore + assertions
./scripts/backup.sh verify --keep       # leave the restored tree to inspect it
./scripts/backup.sh verify --snapshot <id>
./scripts/backup.sh verify --no-check   # skip the read-data check, still restore
./deploy.sh --only backup-verify        # what the timer does
```

It reads a quarter of the repository's pack data (rotating, so the whole thing is
read every four weeks), restores into `$DATA_DIR/backup-verify`, and asserts every
`BACKUP_PATHS` entry and every `BACKUP_VERIFY_PATHS` marker came back non-empty.
The dumps are checked by content too (trailers, `PRAGMA quick_check`, and an mtime
inside the snapshot's own run), because presence is not consistency. The live data
dirs are never mounted, and the verdict lands in
`$DATA_DIR/audit/backup-verify.status` — a file, not an exit code, because that is
what `scripts/monitor.sh` reads. A drill that keeps skipping (over
`BACKUP_VERIFY_MAX_MB`, or short of free space) fails on the age of its last
success rather than looking green.

What it proves is mechanics: the password opens the repository, the pack data is
intact, a snapshot restores, and the files that matter are inside it. What it does
**not** prove: that an offsite repository is reachable, that the restored wallet
opens and re-syncs, or that the daemons come up on the restored state. That is the
walkthrough above, and it is worth running once against a spare host rather than
trusting a green drill. `docs/backup.md` has the drill's design.

### Proving the database dump replays

Every file can be present and every trailer intact while `pg_dumpall`'s output is
unloadable, so a second drill owns that claim, monthly:
`backup-verify-db.timer` runs `scripts/backup.sh verify-db` on the first Wednesday
at 06:30.

```sh
./scripts/backup.sh verify-db           # what the timer does
./scripts/backup.sh verify-db --keep    # leave the restored dump to inspect it
./scripts/backup.sh verify-db --snapshot <id>
./deploy.sh --only backup-verify-db     # run it now
```

It restores only the snapshot's `postgres-dump/`, checks the dump's header,
completion trailer and mtime, then replays it into a throwaway `postgres` and
asserts the databases hold tables. A failed pull is recorded as a *skip*, not a
failure: a registry that will not answer says nothing about the dump, and the
status file's age check is what turns a run of skips into an alert. The verdict is
`$DATA_DIR/audit/backup-verify-db.status`, a file of its own so neither drill's
result can mask the other's age.

The full drill — restore everything, then replay both SQL dumps — is still
available on demand:

```sh
./scripts/backup.sh verify --with-db
```

That replays `postgres-dump/all.sql` into a throwaway `postgres` and
`uptime-kuma-dump/kuma.sql` into a throwaway MariaDB from the uptime-kuma image
(the same server version that wrote it), asserting each produces tables. If an
image the replay needs cannot be pulled, the run records a **skip**, not a pass.
It is also a rehearsal of [Replay the live databases](#replay-the-live-databases).

## Monitoring & the spend tripwire

Nothing pages on its own: a container has a healthcheck and `Restart=always`, but a
crash-loop, an offline channel, a stalled chain or a spend is otherwise silent.
`install.sh` installs a monitor that closes that gap.

- `scripts/monitor.sh` — every five minutes from `deploy/monitor.timer`.
  Read-only: it starts nothing and rewrites no config. It runs `verify.sh` for the
  container/MCP base checks and adds the ones nothing else does: chain freshness
  (bitcoind, Fulcrum's Electrum tip against bitcoind's height, `monerod`, the
  wallet's lag), CLN peers and offline channels, host space/inodes/I/O/disk
  saturation, backup and dump age, certificate expiry, restart deltas, the
  schedules themselves, the metrics and log pipelines going quiet, journald
  persistence and podman's event backend, live runes the stack does not reference,
  bitcoind's RPC password against `secrets.env`, the public vhosts through
  nginx-proxy-manager — then the spend tripwire.
- `deploy/monitor.timer` + `deploy/monitor.service` — a plain systemd **user** unit
  (Quadlet has no `.timer` type), like `backup.timer`.
- `scripts/registrations.sh` — one alert per **BoltMesh signup**, every minute. It
  reads the app's `users` table, keeps a `(created_at, id)` watermark so a failed
  push is retried, and seeds it on first run. An event, not a fault: it does not go
  through `monitor.sh`. Run it by hand with `--dry-run` or `--test`.
- `scripts/spend-audit.sh` — the tripwire (below).

The monitor reads the daemons and the host **directly**; it never queries the
metrics store, so the pipeline can be down without silencing an alert. The
healthcheck contract it relies on — and why a probe must not touch the data path —
is `docs/units.md`, "Healthchecks follow a contract"; the alert path's design is
`docs/alerting.md`.

**The monitor decides *what* is wrong; Alertmanager decides *when* to say it.**
`deploy/alertmanager.container` (`prom/alertmanager`, loopback `:9093`, no public
host: `ssh -L 9093:127.0.0.1:9093`) owns grouping, repeat intervals, inhibition,
silences and delivery, and reports failed deliveries back to the next sweep. What
stays in `monitor.sh` is the one thing it cannot do — the **flap damper**, because
it only sees what is pushed at it: an alert is held until
`MONITOR_ALERT_FOR` (600s, two sweeps), and a recovery is pushed explicitly.

**Mail is off until you fill in
`$DATA_DIR/config/monitoring/alertmanager/alertmanager.yml`** (mode 600, seeded
from `deploy/examples/monitoring/alertmanager.yml.example`; uncomment
`email_configs` and set `global.smtp_*`). Until then Alertmanager accepts alerts
and delivers nothing, and `monitor.sh` says so in the journal. Prove the path with
`scripts/monitor.sh --test`. `smtp_smarthost` is the **submission** server, not the
recipient's domain — a provider relay, not a residential IP, or the mail lands in
spam for want of SPF, DKIM and a matching PTR.

`$DATA_DIR/config/monitoring/monitor.env` (mode 600) holds the two things only you
can set:

- `MONITOR_ALERTMANAGER_URL` — default `http://127.0.0.1:9093`; `off` keeps alerts
  in the journal only.
- `MONITOR_PING_URL` — a dead-man's-switch heartbeat (a healthchecks.io ping URL):
  `curl` on success, `<url>/fail` with the failure list. This is the only thing
  that notices when the **whole host** is down, which is why it is not an email —
  and it also fails when the alert push fails, so a broken mail path is never
  silent. Set the check's period to the timer interval.

The thresholds are the same file (`MONITOR_DISK_FREE_PCT`, `MONITOR_BACKUP_MAX_AGE_H`,
`MONITOR_ALERT_FOR`, …); each falls back to its default in the script, so an env
file written before a check existed still monitors. With no heartbeat the sweep
still runs and records to `$DATA_DIR/audit/audit.log`.

### Metrics and history

Alerting tells you *that* something is wrong; these answer *when it started, how
bad it got and whether it is improving*.

| | |
| --- | --- |
| `victoriametrics` | the store: Prometheus-compatible, single process, 30 days (`METRICS_RETENTION`), `127.0.0.1:8428` |
| `node-exporter` | the host: disk, inodes, I/O saturation, memory, load, NIC, temperatures — plus the **textfile collector**, which is how the stack's own numbers get in |
| `scripts/metrics.sh` (every minute) | `$DATA_DIR/monitoring/textfile/stack.prom`: chain heights and IBD, peers and mempool, Fulcrum's Electrum reachability and lag, CLN peers/offline channels, `monerod`'s RPC reachability and lag, the wallet's lag, restart counters, per-container CPU/memory/pids/network |
| `scripts/monitor.sh` (every five) | `monitor.prom` beside it: backup age and count, verify failures, spend trips, sweep timestamp |

**Read it over an SSH tunnel, by design:**

```sh
ssh -L 8428:127.0.0.1:8428 you@host      # then http://127.0.0.1:8428/vmui
```

`vmui` has no authentication of its own, so the store publishes on the host's
loopback only. To put it on the LAN, front it with nginx-proxy-manager *with basic
auth* and declare it as a proxy host; do not publish it directly.

Two consequences worth knowing:

- **`$DATA_DIR/monitoring` is not in the backup set.** History, not state.
- **The textfile is a permissions trap.** `node-exporter` runs as uid 65534, so it
  owns neither the directory nor the files; both writers chmod `0755`/`0644`. If
  graphs stop while the containers are healthy, check that first — the sweep
  distinguishes "metrics collector is stale" from "node-exporter serves no `stack_*`
  series", and `ls -l $DATA_DIR/monitoring/textfile` names the permission.

### Logs and history

journald is the source: podman's log driver writes every container's stdout there,
and the host scripts log there too. What was missing was search across services
and any history at all, so `bootstrap.sh` makes journald persistent and bounded
(`/var/log/journal`, 2 GB, 7 days), `vector` ships it to `victoria-logs`
continuously (one cursor per batch, so a restart resumes), and the store keeps 14
days (`LOGS_RETENTION`) or 10 GiB (`LOGS_MAX_BYTES`).

Two things never reach journald and are read as files: Suricata's `eve.json` and
**nginx-proxy-manager's access and error logs** — the second is what answers a
question about a *request*, because NPM terminates TLS:

```sh
./scripts/logs.sh --since 30m                        # everything, labelled
./scripts/logs.sh --since 2h --container lightningd
./scripts/logs.sh --since 1h --grep 'WARN|ERR' --priority warning
./scripts/logs.sh --since 24h --priority notice      # every Suricata alert
./scripts/logs.sh --since 24h --stats                # who is spamming
./scripts/logs.sh --follow --container boltmesh-backend
./scripts/logs.sh --health                           # is anything still arriving?
```

`--follow` is the one to use: **`podman logs -f` no longer works**, because follow
reads podman's events stream and that stream is a file now (see below).
`journalctl -f CONTAINER_NAME=bitcoind` is the other.

Podman's own events stay out of the journal on purpose: every exec and every
healthcheck run would otherwise be two lines, and `install.sh` points podman's
event log at a bounded file (root's own podman via `bootstrap.sh`). `podman events`
still reads it; `monitor.sh` warns if the setting is lost. `docs/logs.md` has the
whole pipeline, including why the setting cannot be a per-call flag.

Read the store in the UI over an SSH tunnel (`ssh -L 9428:127.0.0.1:9428`, then
`/select/vmui`), or through `victoria-logs-mcp` (`/logs` on the MCP host, one
bearer token) with the same bounded read-only surface. `victoriametrics-mcp`
(`/metrics`) does the same for PromQL, and its `get_stack_status` answers "what is
broken?" in one call. Neither store is a proxy host, and both stay on loopback
because every line every container wrote is in the log store, tokens included.

**`$DATA_DIR/logs` is not in the backup set** — history, not state; the journal's
own 7 days cover a restore.

### The spend tripwire

Spending is **off** (`ENABLE_SPENDING=0`) on both money servers, and the tripwire
makes that impossible to change or spend silently:

1. **Policy drift.** `scripts/spend-audit.sh` keeps a hash baseline
   (`$DATA_DIR/audit/spend-baseline.tsv`) of both `spend.env` files, both token
   files and `lightning-mcp/node.env`. Any edit or removal trips, and
   `ENABLE_SPENDING` is asserted `0` on every run whatever the baseline says. A
   trip repeats until you accept it with `./scripts/spend-audit.sh --rebaseline`.
2. **Activity.** It reads outgoing payments (`lightning listpays`) and transfers
   (monero-wallet `get_transfers`, outgoing only) through the **read** tokens and
   diffs them against `$DATA_DIR/audit/outgoing-baseline.txt`.

Trips are appended to `$DATA_DIR/audit/spend.log` and folded into the monitor's
alert and heartbeat. It is **not** a gate: it cannot stop a spend, only make one
impossible to miss. `audit/` is in the [backup set](#backup--restore).

## Intrusion detection

Two engines, because the traffic splits in a way one product cannot cover.
`nginx-proxy-manager` terminates TLS, so the wire carries handshakes and scans
while the request itself exists only in NPM's access log:

| Engine | Sees | Runs as | Installed by |
| --- | --- | --- | --- |
| `suricata` | packets on `enp8s0` and `lo` | **rootful** (AF_PACKET needs `CAP_NET_RAW` in the init namespace) | `sudo ./bootstrap.sh` |
| `crowdsec` | NPM's access logs + Suricata's alert feed → decisions | rootless | `./deploy.sh` |

That rootful unit is the one exception to "everything runs rootless", and it is
why `bootstrap.sh` is a **two-pass** install: the sensor's config references the
data dir, which does not exist until `./deploy.sh` has run. The first bootstrap
prints a notice; re-running it installs the sensor and restarts it. The rendered
unit lives in `/etc/containers/systemd/`, its config in `/etc/stack-ids/`, and
`./verify.sh` compares every root-tier file against `deploy/root/`.

### What each can and cannot see

* **Suricata** sees the LAN NIC and the host loopback (where each MCP server's
  plaintext HTTP and the daemon RPC ports live). It cannot see the rootless
  container bridge (a rootful sensor cannot enter the user's network namespace),
  inside TLS, or a client address on the re-originated loopback leg NPM opens — so
  everything on `lo` is whitelisted before a scenario sees it. Its external alerts
  feed CrowdSec, which bans the policy sids and three ET severity 1/2 signatures.
* **CrowdSec** sees every request NPM served, the whole attack surface of the
  public vhosts. It cannot attribute anything on the `.onion` vhosts: tor forwards
  to `host.containers.internal`, so NPM logs the host's own address for every
  onion visitor.

**Detection then enforcement**: decisions reach nftables through `stack-bouncer`,
never inline in the packet path, so a sensor crash cannot be an outage. It is also
**local only** (`DISABLE_ONLINE_API=true`): no console enrolment, no community
blocklist, no telemetry — the cost is that a known-bad address is banned here only
after it misbehaves here. The attribution limits and the two privilege domains are
`docs/ids.md`, "What the sensor can attribute, and what it can ban".

### Enforcement

`stack-bouncer` is a root oneshot on a one-minute timer (`deploy/root/bouncer.sh`).
CrowdSec runs with host networking, so it polls the LAPI on the host's own loopback
(`127.0.0.1:8080`, key-gated: an unauthenticated request gets 403) and writes one
nftables table:

```
table inet stack_bans
  set banned_v4 { type ipv4_addr; flags timeout; }
  set banned_v6 { type ipv6_addr; flags timeout; }
  chain input  { type filter hook input priority -10; ip saddr @banned_v4 drop; ... }
```

Each element carries the decision's own duration as an nft timeout, so a ban
expires even if everything above it dies. The set is refreshed wholesale every
minute in one transaction — the LAPI's list is the truth — so
`nft flush table inet stack_bans` cannot unban anyone permanently.

```sh
sudo /etc/stack-ids/bouncer.sh --dry-run    # the rules it would apply; writes nothing
sudo nft list table inet stack_bans         # who is banned right now
systemctl stop stack-bouncer.timer          # the kill switch: detection keeps working
```

Three properties:

* **Never bans the operator.** `ipguard.py` refuses private space, the podman
  network, every address the host holds (checked at run time, so a DHCP change
  cannot self-ban), and **`STACK_WAN_IP`** from `stack.conf` — the router holds
  that one, and a LAN client using a public name arrives as it through NAT
  loopback, where `stack/http-authfail` bans five 401s in ten seconds. The refusal
  is at the bouncer, **not** in the whitelist: the decision still exists and still
  pages, only the drop is skipped, so `skipped=1` means "your own egress is
  tripping a rule", not a quiet host.
* **Fails open in the safe direction.** An unreachable LAPI or a non-JSON answer
  leaves existing bans alone, and a failed `nft -f` rolls back. The address guard
  is the other direction on purpose: if it cannot classify, nothing is applied and
  the status file says why.
* **Its key is never regenerated.** `CROWDSEC_BOUNCER_KEY` is registered into the
  LAPI by the crowdsec container at start; a new value leaves the old bouncer
  registered and enforcement silently dead.

### Reading it

```sh
./scripts/ids.sh -v                       # the roll-up, by hand
cat $DATA_DIR/audit/ids.status            # what monitor.timer reads
podman exec crowdsec cscli decisions list  # every decision the engine holds
sudo nft list table inet stack_bans        # what is actually being dropped
podman exec crowdsec cscli metrics         # lines read/parsed/whitelisted per log
tail -f $DATA_DIR/ids/suricata/eve.json | jq 'select(.event_type=="alert")'
./scripts/logs.sh --since 6h --unit suricata.service   # the same alerts, searchable
```

The same read state reaches an agent at `https://mcp.boltmesh.net/crowdsec`
(`crowdsec-mcp`): `list_decisions`, `check_ip`, `get_engine_health`. It holds a
**second, read-only bouncer key**, so its pulls are attributable and
`cscli bouncers delete mcp` revokes it without touching enforcement. Deliberately
absent: alerts (they need a machine credential that can also ban and unban) and any
ban/unban tool — it sees active decisions only.

`ids.status` carries `eve=ok|missing|unreadable|na`: the alert count is a report
only if the file was read, so a missing or unreadable `eve.json` fails the roll-up
instead of leaving `alerts=0`. `ids.timer` runs at `*:2/5`, between the monitor's
sweeps, and the monitor alerts on a stale or failed status. Counts are a *warning*,
not a page; the rate is in VictoriaMetrics (`stack_ids_alerts`). eve.json is in the
log store too (see [Logs and history](#logs-and-history)), so an alert reads next
to what the proxy, the daemons and BoltMesh were doing at that moment.

### The whitelist is load-bearing

`deploy/crowdsec/parsers/s02-enrich/stack-whitelists.yaml` exists because a naive
threshold here is a self-inflicted outage, not a false positive: the onion proxies
and Uptime-Kuma's self-checks are logged as the host's **own** address, Uptime-Kuma
probes every monitor once a minute including a permanent 401 on the token-gated
ones, and the podman network and the LAN are internal by definition.

Read that file before tightening a scenario. `./verify.sh` replays a sample
access-log line through `cscli explain` every sweep, because a change to NPM's
`log_format` would otherwise disable detection silently. Every entry is a *plain
string match*, so it is written per octet — and an entry one octet too short is a
silent widening, not a syntax error. A whitelisted event is dropped in
`s02-enrich` before the scenarios, so it never becomes a decision and `cscli
metrics`' whitelisted count is the only trace; that is why the sweep asserts both
directions (a public address in the LAN's range must not be whitelisted, while the
LAN's own must be).

The `default-host` vhost exists only to answer scanners, so any request to it is
worth a look.

### Resources and retention

~650 MB RSS for Suricata with the full ET Open ruleset (refreshed at container
start, best effort), ~150 MB for CrowdSec, nothing measurable for the bouncer.
Suricata only rotates a `filename` containing a strftime template, and ours are
static, so the host's `logrotate` does it from `/etc/logrotate.d/stack-ids`,
keeping `IDS_RETENTION_DAYS` (14) compressed rotations. `eve.json` is ~50 MB/day,
so that is the budget the data disk must cover; `$DATA_DIR/ids` is regenerable and
stays out of the backup set.

### Rate limiting (the onion's only defence)

Every visitor to a `.onion` vhost reaches NPM as the host's **own** address, so no
IP-based control can touch them individually. What is left is a global brake,
`stack_onion`: a request-rate zone keyed on `$server_name` rather than the client
address, at 60 r/s with a 120 burst. The clearweb vhosts get `stack_ip` keyed on
the real address (30 r/s, burst 60) plus `stack_conn` (40 concurrent). The MCP host
gets **`limit_conn` only**, never `limit_req`: it is JSON-RPC, where a client
legitimately bursts, and its `GET /mcp` is a long-lived SSE stream.

The zones are declared in `deploy/npm/http.conf`, seeded to
`$DATA_DIR/npm/data/nginx/custom/http.conf` — the one NPM directory never
regenerated. The directives are per host, in the `advanced_config` field
`scripts/npm-hosts.sh` sends.

### Host integrity

`deploy/root/audit.rules` watches the files this repo never writes: the account
databases, `sudoers`, `sshd_config`, `auditd.conf`, and the stack's own
`secrets.env` and `hsm_secret`. `stack-audit.timer` turns the root-only log into
`$DATA_DIR/audit/auditd.status`, which the monitor pages on.

Two facts decide how you read that status:

* **Directory watches do not work on this kernel**, so entry creation — a new unit
  file, a sudoers drop-in, a cron job — is covered by a **hash diff** of
  `/etc/systemd/system`, `/etc/containers/systemd`, `/etc/sudoers.d`, `/etc/cron.d`,
  `/etc/ssh/sshd_config.d` and `/etc/audit/rules.d`. Anything new, changed or
  removed is counted and named.
* **The ruleset is checked as state, not as an event.** `install.sh --root` removes
  and re-adds every `stack_` watch on each run, so `op=remove_rule` events cannot
  tell a deploy from tampering; the report compares `60-stack.rules` with
  `auditctl -l`. Events carry a **key** — `stack_hard` for host config the repo
  never writes, `stack_data` for the stack's secrets — and only `stack_hard` fails
  the sweep, because rotation and deploys touch the data-dir files on purpose.

**On this host the kernel audit subsystem is inert**: it initializes disabled and
never writes a record, even though `auditctl -s` then reports `enabled 1`. The rules
stay loaded (correct if the host is ever booted with auditing on), the status says
`audit=inert`, and the **hash diff is the live check**. `docs/ids.md` covers the
rest, including the one case neither half sees.

## Status page

`uptime-kuma` serves a public status page on `https://status.boltmesh.net`
(`[host.status]` in `deploy/services.toml`). It complements the monitor, not
replaces it: the monitor is the host-side, alert-only sweep, while the page watches
the same public surface for visitors.

**The page is UI-authored, not declared.** Its monitors, the page and its layout are
created in kuma's own UI (the setup wizard's account); nothing reconciles them, and
nothing host-side holds a kuma credential. The monitors are therefore data: they
live in kuma's embedded MariaDB and come back with the
[backup](#backup--restore) (`uptime-kuma-dump/`). [Proxy hosts](#proxy-hosts) is
the contrast — those *are* declared and reconciled, because NPM's admin API
replaces a whole host object and the UI has no safe way to share ownership of one.

`docs/proxy.md` lists the checks the public surface expects and the two traps that
are easy to get wrong in the UI (a token-gated endpoint answering `401` counts as
up; a **TCP-port** monitor still needs accepted status codes). Fulcrum's `50001` is
the one TCP-port monitor, and it watches the **published** port wallets use — a
port monitor proves the socket accepts a connection, and whether the index behind
it is current is what `verify.sh --deep` and `monitor.sh` read.

The host side is still the repo's: `install.sh` renders
`--add-host=<vhost>:host-gateway` for every `[host.*]` with `kuma_add_host = true`,
so the checks resolve their vhosts on the host instead of hairpinning through the
router and arriving as the WAN address. And `monitor.sh` probes every clearweb
vhost through NPM on loopback itself — the page stays for visitors, the sweep is
what pages.

The page's **notifications** stay UI-configured too (kuma embeds Apprise). That is
the *status page's* channel, not the alerting path: the stack's alerts go monitor →
Alertmanager → mail, and the two are independent on purpose, so a kuma that dies
with the host does not take the pager with it.

- **No tokens enter kuma's database.** Every monitor checks the public surface; the
  authenticated handshakes stay in `verify.sh`/`monitor.sh`.
- Its state (`$DATA_DIR/uptime-kuma`, embedded MariaDB included) is in the backup
  set as a `mariadb-dump`, not a copy of the live datadir.
- Its dashboard uses websockets, which is why `[npm.status]` carries the `ws` flag.

## Proxy hosts

nginx-proxy-manager is the stack's only LAN-facing HTTP unit, so every public
hostname is a proxy host in NPM. (Fulcrum's `50001`/`50002` are the deliberate
non-HTTP exception; see [What runs](#what-runs).) They are declared in the
`[npm.*]` tables of `deploy/services.toml` — a `host` reference (or a literal
`domain` for the `*.onion` wildcard), a `forward` and `flags` — and reconciled by
`scripts/npm-hosts.sh` through the NPM admin API on `127.0.0.1:81`: a host already
serving the domain is updated in place, otherwise it is created, and a Let's
Encrypt certificate is requested for any host that has none. The hostnames
themselves are the `[host.*]` tables, each with an operator env override
(`BOLTMESH_FRONTEND_HOST`, `MCP_HOST`, ...). `./deploy.sh` runs it after the app
tier; `./deploy.sh --only npm-hosts` re-applies it after a change.

```toml
[npm.frontend]
host = "frontend"                 # a [host.*] key: boltmesh.net
forward = "127.0.0.1:8106"        # the boltmesh-frontend unit's loopback publish
flags = ["ws", "block"]

[npm.mcp_edge]
host = "mcp"
forward = "127.0.0.1:8100"
flags = ["mcp", "force-ssl", "http2"]
```

`forward` is `[scheme://]host:port` (scheme defaults to `http`) and is always
`127.0.0.1`: NPM runs on the host network and cannot resolve a container name, so
it reaches the unit's loopback publish. The flags are `force-ssl` (redirect `:80`
to `:443`), `http2`, `ws` (websocket upgrade), `block` (common exploits) and `mcp`.
`--dry-run` prints the API payloads without changing anything; `--prune`
additionally **deletes** hosts and certificates the manifest does not declare — the
only destructive mode.

The credentials are in `$DATA_DIR/config/npm/api.env` (mode 600, seeded by
`install.sh`):

```sh
NPM_EMAIL=you@example.com
NPM_PASSWORD=…        # the password you set on the NPM UI's first visit (81)
```

### The MCP host

Every MCP server speaks Streamable HTTP at `/mcp`. Rather than one hostname per
server, they share one, each on a **path prefix** (`mcp` flag above) that maps onto
the upstream `/mcp`, so `/mcp` never appears in a client's URL:

| Public URL | NPM forwards to |
| --- | --- |
| `https://mcp.boltmesh.net/searxng` | `127.0.0.1:8100` |
| `https://mcp.boltmesh.net/bitcoin` | `127.0.0.1:8101` |
| `https://mcp.boltmesh.net/monero` | `127.0.0.1:8102` |
| `https://mcp.boltmesh.net/monero-wallet` | `127.0.0.1:8103` |
| `https://mcp.boltmesh.net/lightning` | `127.0.0.1:8104` |
| `https://mcp.boltmesh.net/fulcrum` | `127.0.0.1:8110` |
| `https://mcp.boltmesh.net/logs` | `127.0.0.1:8111` |
| `https://mcp.boltmesh.net/metrics` | `127.0.0.1:8112` |
| `https://mcp.boltmesh.net/crowdsec` | `127.0.0.1:8113` (host network: the app's own bind) |
| `https://mcp.boltmesh.net/btcpay` | `127.0.0.1:8114` |

The prefixes are the `[mcp.*]` tables, each carrying `prefix`, `container` and
`port` (the container name also names the `token.env` that is the prefix's
credential). `crowdsec-mcp` is the exception: it runs on the host network, binds
`127.0.0.1:8113` itself, and host-side probes go through `netcheck-host`. The host's
nginx config turns buffering off and sets a long read timeout, because Streamable
HTTP answers with `text/event-stream` and a buffered SSE body just hangs the client.

`/btcpay` is the read-only front door to BTCPay's Greenfield API. Its credential is
a store-scoped key with four `canview*` permissions, minted by `btcpay-bootstrap`
and kept in `config/btcpay/bootstrap.env` — never the admin key and never the
backend's write-capable one — so it cannot create or refund an invoice, pay out,
generate an address or broadcast. `get_btcpay_health` reports the key's permissions
when a tool returns 403, and preimages, the API-key echo and connection strings are
redacted from every answer.

Each declared host needs its DNS pointing here and `:80` reachable for the HTTP-01
challenge; `NPM_REQUEST_CERT=0` leaves TLS to the UI instead. `./verify.sh` checks
the path a client takes — the public URL connected to NPM itself (`--connect-to`),
following its redirect to `:443` once TLS is on, so it works before public DNS.

### Agent skills (harnesses without MCP)

The [`agent-skills`](https://github.com/regularnmae/agent-skills) repo wraps the same
endpoints as eleven skills plus `agent-mcp`, a stdlib-only MCP client, for harnesses
that do not speak MCP: Codex, a plain shell, CI. `./deploy.sh` clones it into
`$BUILD_DIR/agent-skills` and runs its `install.sh`, which links each skill into the
harnesses this host has and puts `agent-mcp` in `~/.local/bin`:

```sh
agent-mcp bitcoin-node get_blockchain_info
agent-mcp lightning decode bolt11=<invoice>
agent-mcp bitcoin-node --list
```

It is not a service — no unit, no container, no port, nothing in the backup set, and
`--skip-agent-skills` leaves a host that only serves untouched. It adds no
credential either: `servers.json` expands `$AGENT_MCP_BASE_URL` and reads each
server's token from `$DATA_DIR/config/<server>/token.env` on every call, so
`rotate.sh` needs no second step and no copy can go stale. A host that changed
`MCP_HOST` exports `AGENT_MCP_BASE_URL` to match; `./verify.sh` warns when the two
disagree. The prefixes live in that registry rather than being derived from the
manifest, so moving one means editing both — `./verify.sh` fails on the drift.

## Tor onion services

The public hostnames are also published as Tor v3 onion services, from the `tor`
unit that already exists (lightningd's SOCKS proxy and CLN's own onion client).
No extra container, nothing to open in the firewall: a hidden service is a few
lines in `torrc` and outbound connections.

The declaration is the `[onion.*]` tables:

```toml
[onion.boltmesh]
target = "10.89.0.241:80"       # the unit's pinned IP; tor validates it at start
mirrors = "frontend"            # the public name this onion serves
path = "/"                      # what verify.sh probes through it
codes = [200]

[onion.mcp]
target = "host.containers.internal:80"   # through NPM's wildcard *.onion host
mirrors = "mcp"
path = "/searxng"
codes = [401]
```

`install.sh` renders the table into a marked block at the end of
`$DATA_DIR/tor/torrc` — the rest of that file (the control-password hash, the SOCKS
policy) is seeded once and never rewritten — and `deploy.sh` hashes `torrc`
alongside the units, so editing the tables and re-running it adds, removes or
retargets a service. The `[onion.*]` key is the `HiddenServiceDir` name under
`$DATA_DIR/tor/onion/`: renaming it is a new onion address, not a rename.

The address itself is key material: tor writes it to `$DATA_DIR/tor/onion/<name>/`
(mode 700), which is in the [backup set](#backup--restore). Restore the keys and
the addresses come back; lose them and every address changes.

tor logs a `ControlPort ... non-local address` warning at startup. Expected:
lightningd drives the statictor service through `10.89.0.240:9051`, which is not
loopback; the port is protected by `HashedControlPassword` and reachable only from
`npm-network`.

```sh
cat "$DATA_DIR"/tor/onion/*/hostname   # what each service is called
./verify.sh                            # fetches each of them through tor
./deploy.sh --only tor                 # just re-read torrc
```

| `[onion.*]` name | Serves | Forwarded to |
| --- | --- | --- |
| `boltmesh` | the BoltMesh SPA | `http://<addr>.onion/` → `10.89.0.241:80` |
| `api` | the BoltMesh API | `http://<addr>.onion/health`, `/v1` → `10.89.0.242:8000` |
| `btc-explorer` | BTC RPC Explorer | `http://<addr>.onion/` → `10.89.0.243:3002` |
| `xmr-explorer` | MoneroBlock | `http://<addr>.onion/style.css` → `10.89.0.244:31312` |
| `mcp` | the ten MCP servers | `http://<addr>.onion/<prefix>` → NPM's `*.onion` host |

All but the MCP host forward to a container's pinned IP (the units set `IP=`), which
tor validates at start. The MCP host cannot: it is ten servers split by *path*,
which only nginx-proxy-manager does, and NPM is on the host network, where a
container has no route. The one reachable name is `host.containers.internal`
(pasta's host gateway), so the mcp onion forwards there and NPM matches the
wildcard `*.onion` proxy host — a wildcard because **tor cannot rewrite the `Host`
header** and the address is not known when the proxy hosts are declared. That host
is the only one without a certificate: tor already encrypts and authenticates the
onion, Let's Encrypt cannot issue for `.onion`, and the hidden service reaches NPM
over plain HTTP — `npm-hosts.sh` skips TLS for it on purpose.

**What a browser can do over onion.** The API and the MCP servers are fully usable:
point a client at the `.onion` address and everything above still holds, bearer
tokens included (`verify.sh` proves the 401 gate through the onion). The BoltMesh
SPA is not, on its own: `VITE_API_URL` is baked at build time and the refresh
cookie is `Secure`, so a DNS-less browser loads the shell but cannot reach the API.
An onion-native SPA means rebuilding it with the onion origin (`BOLTMESH_API_HOST=`)
and adding that origin to `CORS_ALLOW_ORIGINS` in `boltmesh/app.env`.

The onion checks therefore live in `./verify.sh` (it fetches each address through
tor's SOCKS port); the status page cannot do them, because uptime-kuma has no SOCKS
egress.

## BoltMesh

The application tier — `postgres`, `boltmesh-backend`, `boltmesh-worker` and
`boltmesh-frontend` — is deployed by the same `./deploy.sh` as everything else, from
the `boltmesh-labs` GitHub org (`GITHUB_ORG_BOLTMESH` in `stack.conf`). It is the
one part of the stack that is not an MCP server, so it has its own build step
(`deploy_boltmesh`): the images need a build target and `VITE_*` build arguments the
generic app path does not pass.

Those two repos are **private**, so they are cloned over **SSH**: the host must
authenticate to GitHub as a user with access (`ssh -T git@github.com` must greet
you). `deploy.sh` exports `GIT_TERMINAL_PROMPT=0` and
`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, so a missing key is a clear error rather
than a prompt hanging the deploy. Set `GITHUB_SSH_HOST` to an `~/.ssh/config` alias
if `git@github.com` is not the key's host; an existing HTTPS checkout is re-pointed
on the next run.

It does not bring its own chains: the backend is pointed at BTCPay, which fronts the
stack's own `lightningd` and the view-only Monero wallet.

| Value | Source |
| --- | --- |
| `DATABASE_URL`, `POSTGRES_*` | `$DATA_DIR/config/boltmesh/db.env` (generated) |
| `SECRET_KEY`, `REFRESH_SECRET_KEY`, `NODE_SECRET_KEY`, `BOOTSTRAP_SECRET_PEPPER` | `$DATA_DIR/config/boltmesh/secrets.env` (generated) |
| `BTCPAY_URL`, `BTCPAY_API_KEY`, `BTCPAY_STORE_ID`, `BTCPAY_WEBHOOK_SECRET` | `$DATA_DIR/config/btcpay/backend.env` — written by `configure.sh` from the bootstrap state; the runtime key is store-scoped |
| URLs, CORS, OAuth, SMTP, `GITHUB_REPO`/`GITHUB_TOKEN` | `$DATA_DIR/config/boltmesh/app.env` — **operator-editable**, fill it in before first use |

### Before it works

1. Point `boltmesh.net` and `api.boltmesh.net` at the host (`[host.frontend]` /
   `[host.api]`), and make `:80` reachable for the Let's Encrypt challenge.
2. Fill in `$DATA_DIR/config/npm/api.env` with the NPM admin login and re-run
   `./deploy.sh --only npm-hosts`: the two hosts (`boltmesh.net` → `127.0.0.1:8106`,
   `api.boltmesh.net` → `127.0.0.1:8105`) come from the manifest, each with its own
   certificate.
3. Fill in `$DATA_DIR/config/boltmesh/app.env` (OAuth client id/secret, SMTP, the
   agent `GITHUB_TOKEN`) and register
   `https://api.boltmesh.net/v1/auth/google/callback` and `…/github/callback` in the
   provider consoles — `API_BASE_URL` is the base of every redirect_uri.
4. Re-run `./deploy.sh` (or `./deploy.sh --only boltmesh`). `VITE_API_URL` is baked
   into the frontend bundle at build time, so a hostname change means a rebuild.

The database is dumped (`pg_dumpall`) into `$DATA_DIR/postgres-dump/` immediately
before each restic run; the dump, not the raw cluster, is what the
[backup set](#backup--restore) holds.

## How secrets are kept out of git

No secret is committed. Everything real is generated or adopted on the host, under
`$DATA_DIR/config/`, mode 600.

Coming from the **pre-data-dir layout** (`~/.config/stack/`,
`~/.config/crypto-nodes/` and `~/.config/<name>/*.env`), copy those files into
`$DATA_DIR/config/` before the first deploy. The installer no longer moves them
itself: without the copy, `secrets.env` and the MCP tokens are generated fresh,
and clients holding the old tokens get 401 until their configuration is updated.

- **`config/stack/secrets.env`** holds the node secrets (bitcoind RPC user and
  password, Tor service password), `BTCPAY_DB_PASSWORD` (the `btcpay` role in the
  Postgres cluster) and the two CrowdSec bouncer keys — which are append-only and
  must never be regenerated, because the crowdsec container registers those exact
  values in its LAPI at start. Resolved in the order **`secrets.env` → the
  installed unit → the daemon's own config → generate**, so adopting the deploy on
  a running host changes no credential. There is no wallet password: BTCPay's
  plugin wallet is imported view-only and its RPC runs with `--disable-rpc-login`.
- **`config/<name>/{token,upstream,spend,node,lapi}.env`** hold the bearer tokens,
  upstream credentials, spend policy and CLN runes. Units read them with
  `EnvironmentFile=`; their shapes are `deploy/env/<name>/<file>.env.in`, rendered by
  `install.sh` (seed-once, except the machine-owned `lapi.env` and the view-only
  wallet's `upstream.env`). What `install.sh` does not render is documented in
  `deploy/examples/<name>/`.
- **`config/btc-explorer/btc-explorer.env`** — that explorer's bitcoind RPC
  credentials and Fulcrum endpoint; the explorer has no other configuration.
- **`config/npm/api.env`** — the nginx-proxy-manager admin login
  `scripts/npm-hosts.sh` reconciles through (or an API token). The Python core reads
  the file itself, so no credential reaches an argv `ps` can read.

**Quadlet does not expand environment variables in `Exec=`**, which is why
`lightningd`, `fulcrum` and `crowdsec` are *rendered* from `deploy/*.container.in`
by `install.sh`. Every unit is rendered that way — the secret-free ones only
substitute `@DATA_DIR@`/`@CONFIG_DIR@` — so no unit is a symlink, and rendered
units are mode 600 and never enter git. The BTCPay wallet deliberately uses the
`btcpayserver/monero` image: the alternative forces `127.0.0.1` unless
`--rpc-login` is on the command line, and the plugin hardcodes empty credentials.

`bitcoind` keeps its RPC credentials in its own `bitcoin.conf`, seeded once and
handed to the image uid: `podman exec -it bitcoind vi /data/.bitcoin/bitcoin.conf`.
`docs/credentials.md` has the invariants behind all of this and why spending stays
off.

### Rotating a credential

`scripts/rotate.sh` changes one credential and brings every consumer along in
dependency order:

```sh
./scripts/rotate.sh --list                  # the targets and what each one touches
./scripts/rotate.sh --status                # the credential invariants + the last 10 runs
./scripts/rotate.sh bitcoin-rpc --dry-run   # the plan, no values, no writes
./scripts/rotate.sh bitcoin-rpc             # rotate, re-render, restart, verify
./scripts/rotate.sh runes --scope spend     # read | spend | all
./scripts/rotate.sh token:lightning-mcp     # one server's bearer token
./scripts/rotate.sh token:lightning-mcp --spend
./scripts/rotate.sh postgres
```

| Target | Rotates | Restarts |
| --- | --- | --- |
| `bitcoin-rpc` | `bitcoind`'s RPC password (and `--user`) | bitcoind, then fulcrum, lightningd, bitcoin-node-mcp, btc-explorer |
| `tor-control` | Tor's control password (lightningd's statictor) | tor, then lightningd |
| `runes` | the CLN runes: lightning-mcp's read/spend pair | lightning-mcp |
| `token:<server>` | one MCP server's bearer token (`--spend` for a money server's spend token) | that server |
| `searxng-secret` | SearXNG's `settings.yml` `secret_key` | searxng |
| `postgres` | the `vpnuser` role's password (`ALTER ROLE`) | postgres → BoltMesh |
| `boltmesh-keys` | the four signing keys/node pepper (`--yes`: ends every session and node token) | BoltMesh |
| `restic` | the repository's key (`key add` → verify → `key remove`, `--yes`) | nothing |

None of it is scheduled: these credentials are also held by clients outside the
stack (an MCP client's config, a wallet, nginx-proxy-manager), so a rotation on a
timer would break them silently. The record is
`$DATA_DIR/audit/rotation.log` — never a value.

**If a run dies half-way, run the same target again.** Nothing is journaled and
there is no `--resume`: every target either rewrites every copy of its credential
or reconciles a declared end state against the authority that holds it (the rune
set, the repository's keys), so a second run converges from whatever the first left.
A re-run also refuses to restart a daemon that already carries the new value, so
finishing an interrupted rotation costs a verification, not a second outage.
`--status` shows the window a crash can leave open; `--force` skips the preflight
(an unhealthy daemon, or a nightly backup in flight).

```sh
./scripts/rotate.sh --status        # rune set, bitcoin.conf vs secrets.env, last 10 runs
./scripts/rotate.sh <target>        # finish a half-applied rotation
./scripts/rotate.sh <target> --yes  # when the target demands it (boltmesh-keys, restic)
```

The design — why a rotation is never one file, why revocation is a set comparison
rather than a remembered id, and the write-ahead order for the restic key — is in
`docs/credentials.md`, "Rotation".

## Layout

```
stack/
  bootstrap.sh            # bare host -> podman, linger, sysctl, firewall ports, dirs
  deploy.sh               # the one-click orchestrator (asks for the data dir)
  configure.sh            # the second step: waits, then the running-stack work
  verify.sh               # health + endpoint checks
  stack.conf              # repo / port / order manifest, data-dir + backup defaults
  renovate.json           # Renovate policy (pinned images, git refs, actions)
  .github/workflows/ci.yml  # shellcheck + bash -n on the scripts
  AGENTS.md               # agent index: invariants, traps, the shared contract
  docs/                   # the detail behind that index, one file per subsystem
                          #   (units, logs, ids, backup, proxy, alerting,
                          #   chains, credentials, btcpay, clients)
  scripts/lib.sh          # data-dir resolution + SELinux labelling + the
                          #   net_curl / mcp_* helpers every check goes through
  scripts/wallets.sh      # the Bitcoin Core wallet (create/restore/load)
  scripts/btcpay-wallet.sh # import BTCPay's view-only Monero wallet
  scripts/backup.sh       # restic backup / restore / inspect the repository
  scripts/monitor.sh      # scheduled health + spend sweep (monitor.timer)
  scripts/metrics.sh      # one metrics scrape into the textfile collector (metrics.timer)
  scripts/logs.sh         # cross-service log search over victoria-logs (LogsQL)
  scripts/ids.sh          # scheduled IDS roll-up (ids.timer): suricata + crowdsec
  scripts/spend-audit.sh  # spend drift + outgoing-activity tripwire
  scripts/rotate.sh       # rotate one credential + every dependent service
  scripts/npm-hosts.sh    # every nginx-proxy-manager proxy host, via its API
  scripts/healthcheck-lint.sh # the healthcheck contract every unit is checked against
  deploy/
    install.sh            # the ONLY installer: units + secrets + data dirs
    *.container           # every unit, rendered (they reference the data dir)
    *.container.in        # lightningd, fulcrum, crowdsec, rendered (secrets)
    *.timer               # every schedule: backup, backup-verify,
                          #   backup-verify-db, monitor, metrics, ids (plain
                          #   user units; Quadlet has no .timer type)
    *.service             # their one-shot hosts: backup-verify,
                          #   backup-verify-db, monitor, metrics, ids,
                          #   db-dump, btcpay-plugin
    npm-network.network
    crowdsec.container    # rootless: NPM access log -> decisions (local only)
    root/                 # the ONE rootful tier: suricata.container + its config,
                          #   rendered by install.sh --root (bootstrap.sh only)
    crowdsec/             # this repo's parser, scenarios, whitelists, acquisition;
                          #   rendered into $CONFIG_DIR/ids/crowdsec
    logs/vector.toml      # the shipper's config (journald -> victoria-logs),
                          #   rendered into $CONFIG_DIR/logs/vector
    podman/99-stack.conf  # podman's event log: file, not journald; installed as
                          #   containers.conf.d/99-stack.conf for user and root
    monitoring/scrape.yml # what victoriametrics scrapes, rendered into place
    searxng/{settings.yml,limiter.toml}
    env/<app>/<file>.env.in       # the shape of every env file install.sh seeds
                                  #   (upstream/spend/token/boltmesh/backup/btcpay);
                                  #   rendered by install.sh, never mounted
    examples/<app>/*.example      # shapes install.sh does not render (the one-line
                                  #   token.env files, node.env, btcpay/backend.env)
                                  #   -- except monitor.env and alertmanager.yml,
                                  #   which install.sh copies verbatim
    examples/stack/*.example      # bitcoin.conf / torrc / secrets templates
    examples/monitoring/*.example # the monitor env (seeded verbatim) + alertmanager.yml
    examples/npm/*.example        # npm/api.env shape (the NPM admin API login)
  tor/Containerfile       # built by install.sh: the Tor proxy + onion services
  netcheck/Containerfile  # built by install.sh: the curl client the host checks run
  btc-explorer/Containerfile # built by deploy.sh: BTC RPC Explorer (stateless)
  xmr-explorer/Containerfile # built by deploy.sh: MoneroBlock (Go, RPC-only)
```

## Rollback

Everything is idempotent and the unit each deploy replaces is kept as
`~/.config/containers/systemd/<unit>.bak` — one generation, the one before the
last deploy, and only rewritten when that deploy actually changed the file. (It
is not a history: for anything older, check the unit template out of an older
commit.) Restore the `.bak` beside its unit, `systemctl --user daemon-reload`,
and restart that unit — a daemon-reload alone leaves the running container on
the old definition. The restored file is not what the last deploy recorded as
applied, so `./verify.sh` keeps naming that unit as drift until the checkout is
rolled back too: check out the older stack commit and run
`./deploy.sh --only <unit>`, which re-renders it and records the baseline. To
roll back an application, check out an older commit in its repo and
`./deploy.sh --only <app>`.
