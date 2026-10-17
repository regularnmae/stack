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
| `monero-wallet-rpc` | `ghcr.io/sethforprivacy/simple-monero-wallet-rpc:latest` | — | `$DATA_DIR/monero-wallet-rpc` |
| `lightningd` | `docker.io/elementsproject/lightningd:latest` | — (onion over Tor) | `$DATA_DIR/cln` |
| `tor` | `localhost/tor:local` (built from `tor/Containerfile`) | — | `$DATA_DIR/tor` |
| `valkey` | `docker.io/valkey/valkey:9-alpine` | — | — |
| `searxng` | `docker.io/searxng/searxng:latest` | — | `$DATA_DIR/searxng` |
| `nginx-proxy-manager` | `docker.io/jc21/nginx-proxy-manager:latest` | `80`, `443`, `81` | `$DATA_DIR/npm/{data,letsencrypt}` |
| `searxng-mcp` | `localhost/searxng-mcp:latest` | — | — |
| `bitcoin-node-mcp` | `localhost/bitcoin-node-mcp:latest` | — | — |
| `monero-node-mcp` | `localhost/monero-node-mcp:latest` | — | — |
| `monero-wallet-mcp` | `localhost/monero-wallet-mcp:latest` | — 🔑 | — |
| `lightning-mcp` | `localhost/lightning-mcp:latest` | — 🔑 | — |
| `postgres` | `docker.io/library/postgres:18-alpine` | — | `$DATA_DIR/postgres` |
| `boltmesh-backend` | `localhost/boltmesh-backend:latest` | — | — |
| `boltmesh-worker` | `localhost/boltmesh-backend:latest` | — | — |
| `boltmesh-frontend` | `localhost/boltmesh-frontend:latest` | — | — |

**`nginx-proxy-manager` is the only unit that publishes a port.** Every other
service is reached by container name on `npm-network` (`10.89.0.0/24`, pinned in
`deploy/npm-network.network` because `tor.container` pins `--ip=10.89.0.240` and
both `bitcoin.conf` and `torrc` allow that subnet): NPM terminates TLS and is
the one way in for a client, and the host-side checks (`verify.sh`, the monitor)
read the same addresses through a throwaway curl container on that network —
`netcheck/Containerfile`, run by `net_curl` in `scripts/lib.sh`. The proxy hosts
are declared in `NPM_HOSTS` (`stack.conf`) and reconciled from this repo by
`scripts/npm-hosts.sh` through the NPM admin API (`81`) — see
[Proxy hosts (nginx-proxy-manager)](#proxy-hosts-nginx-proxy-manager). The hosts
themselves live in NPM's database, not in this repo.

Only `80`, `443` and `81` (NPM) are opened on the LAN (`FIREWALL_PORTS` in
`stack.conf`), and there is nothing to reach on loopback either: if you cloned an
older host that still had `8000`/`8080`/`8100-8106` published or open, close
them once by hand — `bootstrap.sh` only ever opens ports, it never closes them:

```sh
sudo firewall-cmd --permanent --remove-port=8000/tcp --remove-port=8080/tcp \
  --remove-port=8100/tcp --remove-port=8101/tcp --remove-port=8102/tcp \
  --remove-port=8103/tcp --remove-port=8104/tcp --remove-port=8105/tcp \
  --remove-port=8106/tcp && sudo firewall-cmd --reload
```

🔑 = a money-moving surface. Spending is **off** by default on both.

A nightly, encrypted restic backup of the irreplaceable state (`cln/`,
`monero-wallet-rpc/`, `config/`, `npm/`, `audit/`, and the BoltMesh database as
a `pg_dumpall`) runs from `backup.timer` into
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
stale image). Common flags:

```sh
./deploy.sh --only bitcoin-node-mcp   # rebuild and restart one service
./deploy.sh --only boltmesh           # rebuild + migrate the whole BoltMesh tier
./deploy.sh --only backup             # run the backup job now
./deploy.sh --only monitor            # run the health + spend checks now
./deploy.sh --only npm-hosts           # re-apply every proxy host in NPM
./deploy.sh --skip-apps               # infrastructure only (daemons, searxng, NPM)
./deploy.sh --no-wallets              # skip the interactive wallet prompts
./deploy.sh --dry-run                 # print the plan, change nothing
./verify.sh                           # container health + MCP handshakes
./scripts/monitor.sh                  # the scheduled health + spend sweep, by hand
```

Chain sync takes hours to days on a truly bare host (`bitcoind` is pruned, so
it re-downloads the chain; `monerod` is pruned too). `deploy.sh` starts the
containers and does **not** wait for sync — re-run it once the chains are
current and anything that was waiting (notably the CLN runes) completes.

### Wallets

A bare host has no wallets. `deploy.sh` prompts:

- **Monero** — create a new wallet (and print its 25-word seed once) or restore
  an existing one from its seed. This must exist before `monero-wallet-rpc`
  starts, so it happens between `monerod` and the wallet RPC.
- **Bitcoin** — create a new descriptor wallet or restore from a `.dat` backup.

Both are skipped when there is no TTY. See `scripts/wallets.sh`.

## Where the data lives

Everything the stack must not lose sits under **one directory**, `$DATA_DIR`
(`STACK_DATA_DIR`, default `$HOME/data`). `deploy.sh` asks for it once and
remembers the answer in `~/.config/stack/data-dir.env`:

  - `bitcoin/ monero/ monero-wallet-rpc/ cln/ tor/ searxng/` — daemon state
  - `npm/{data,letsencrypt}` — nginx-proxy-manager
  - `postgres/` — the BoltMesh database (dumped before backup, not copied raw)
  - `postgres-dump/` — the pre-backup `pg_dumpall`
  - `config/` — every bearer token and secret
  - `audit/` — the monitor's log and the spend tripwire baselines
  - `backup-cache/` — restic's cache (regenerable)

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

## Reinstalling the host without re-syncing

With the data dir on a separate disk (e.g. `/data/stack`), a Rocky reinstall on
the system disk keeps the chains, wallets, CLN identity and every token:

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
`bitcoin/ monero/ monero-wallet-rpc/ cln/ tor/ npm/ config/` there (labelling
the path for containers if it has to) — so nothing re-syncs, the wallet still
opens (its password is in `config/stack/secrets.env`), and the client tokens are
unchanged.

## Backup & restore

`install.sh` installs a nightly, encrypted [restic](https://restic.net) backup of
the things in `$DATA_DIR` that cannot be re-downloaded:

- `cln/` — the CLN node identity, channel state and onion keys
- `monero-wallet-rpc/` — the Monero wallet (funds)
- `config/` — every token, rune and secret
- `npm/` — nginx-proxy-manager's config and TLS material
- `audit/` — the monitor's log and the spend tripwire baselines (see
  [Monitoring & the spend tripwire](#monitoring--the-spend-tripwire))
- `postgres-dump/` — `pg_dumpall` of the BoltMesh database, taken by
  `deploy/postgres-dump.container` immediately before each backup run (the raw
  `postgres/` cluster is not copied: a file-by-file copy of a live `PGDATA` is
  only crash-recoverable)

The chains (`bitcoin/`, `monero/`), `searxng/` and the raw `postgres/` cluster
are deliberately **excluded**: they are large and regenerable, so restic never
walks them.

- `deploy/backup.container` — the one-shot job (a Quadlet unit, rendered like
  the rest).
- `deploy/backup.timer` — the schedule (`*-*-* 03:30:00`, plus 30 min of
  jitter). Quadlet has no `.timer` type, so this is an ordinary systemd **user**
  unit at `~/.config/systemd/user/backup.timer`, enabled by `install.sh`.
- `scripts/backup.sh` — run it by hand and inspect what you have:
  `backup | init | list | check | forget | restore <snap> | unlock`.
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
./scripts/backup.sh restore latest # writes cln/, monero-wallet-rpc/, config/, npm/, audit/
./deploy.sh                        # adopts the restored secrets and wallet
```

This works because `install.sh` never overwrites an existing file and resolves
secrets in the order `secrets.env → the installed unit → the daemon's config →
generate`: a restored `config/` and wallet are adopted as-is instead of being
regenerated. The Monero wallet directory comes back owned by the image uid
(`scripts/backup.sh` fixes that up), so `monero-wallet-rpc` opens it directly.

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
  the Monero wallet's lag behind `monerod` — then the spend tripwire.
- `deploy/monitor.timer` + `deploy/monitor.service` — a plain systemd **user**
  unit (Quadlet has no `.timer` type) and its one-shot service, installed to
  `~/.config/systemd/user/` and enabled by `install.sh`, like `backup.timer`.
- `scripts/spend-audit.sh` — the spend tripwire (below); also runnable alone.

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
installed and active.

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

## Proxy hosts (nginx-proxy-manager)

nginx-proxy-manager publishes the stack's only host ports, so every public
hostname is a proxy host in NPM. They are declared in `NPM_HOSTS` in
`stack.conf` — `domain | forward_host:port | flags` — and reconciled from this
repo by `scripts/npm-hosts.sh` through the NPM admin API on `81`: a host already
serving the domain is updated in place, otherwise it is created, and a Let's
Encrypt certificate is requested for any host that has none. `./deploy.sh` runs
it after the app tier (so a fresh host deploys before the admin login exists),
and `./deploy.sh --only npm-hosts` re-applies it after a change.

```sh
NPM_HOSTS=(
    "${BOLTMESH_FRONTEND_HOST}|boltmesh-frontend:80|ws,block"
    "${BOLTMESH_API_HOST}|boltmesh-backend:8000|ws,block"
    "${SEARXNG_HOST}|searxng:8080|ws,block"
    "${CLNREST_HOST}|https://lightningd:3010|ws,block"
    "${XMR_RPC_HOST}|monero-wallet-rpc:18083|ws,block"
    "${MCP_HOST}|searxng-mcp:8000|mcp,force-ssl,http2"
)
```

Each entry is `domain | forward | flags`, where `forward` is
`[scheme://]host:port` (scheme defaults to `http`; `https` for an upstream that
speaks TLS, like `clnrest`) and `flags` is a comma-separated subset of
`force-ssl` (redirect `:80` to `:443`), `http2`, `ws` (websocket upgrade),
`block` (block common exploits) and `mcp`. `--dry-run` prints the API payloads
without changing anything, and `--prune` additionally **deletes** hosts and
certificates that `NPM_HOSTS` does not declare — the only destructive mode.

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

| Public URL | Container |
| --- | --- |
| `https://mcp.boltmesh.net/searxng` | `searxng-mcp:8000` |
| `https://mcp.boltmesh.net/bitcoin` | `bitcoin-node-mcp:8000` |
| `https://mcp.boltmesh.net/monero` | `monero-node-mcp:8000` |
| `https://mcp.boltmesh.net/monero-wallet` | `monero-wallet-mcp:8000` |
| `https://mcp.boltmesh.net/lightning` | `lightning-mcp:8000` |

Each prefix maps onto the upstream `/mcp`, so the `/mcp` never appears in a
client's URL. The host and the prefixes are `MCP_HOST`/`MCP_HOSTS` in
`stack.conf`; each server's bearer token still gates it (the tokens are the
`token.env` files under `$DATA_DIR/config/<server>/`). The host's nginx config
turns buffering off and sets a long read timeout, because Streamable HTTP answers
with `text/event-stream` and a buffered SSE body just hangs the MCP client.

Each declared host needs its DNS pointing here and `:80` reachable for the
HTTP-01 challenge; set `NPM_REQUEST_CERT=0` to leave TLS to the UI instead.
`./verify.sh` checks the MCP path a client takes — the public URL connected to
NPM itself (`--connect-to`), following its redirect to `:443` once TLS is on, so
it works before public DNS exists.

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
   `boltmesh-frontend:80`, `api.boltmesh.net` → `boltmesh-backend:8000`) come
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
- **`$DATA_DIR/config/npm/api.env`** holds the nginx-proxy-manager admin login
  that `scripts/npm-hosts.sh` uses to reconcile every proxy host (`NPM_HOSTS`)
  through the API on `81` (or an API token instead). The script sends the
  password in a curl config on stdin, so it never reaches the host's argv.

**Quadlet does not expand environment variables in `Exec=`**, which is why
`lightningd` and `monero-wallet-rpc` are *rendered* from `deploy/*.container.in`
by `install.sh` (substituting `@PLACEHOLDERS@`). Every unit is rendered the same
way — the secret-free ones only substitute `@DATA_DIR@`/`@CONFIG_DIR@` — so no
unit is a symlink. The rendered units are mode 600 and never enter git. Do not
"simplify" `monero-wallet-rpc` to a config file: its entrypoint binds `0.0.0.0`
only when `--rpc-login` is on the command line.

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
  renovate.json           # Renovate policy (tor image base/image bumps)
  .github/workflows/ci.yml  # shellcheck + bash -n on the scripts
  scripts/lib.sh          # data-dir resolution + SELinux labelling + the
                          #   net_curl / mcp_* helpers every check goes through
  scripts/wallets.sh      # Monero + Bitcoin create/restore
  scripts/backup.sh       # restic backup / restore / inspect the repository
  scripts/monitor.sh      # scheduled health + spend sweep (monitor.timer)
  scripts/spend-audit.sh  # spend drift + outgoing-activity tripwire
  scripts/npm-hosts.sh    # every nginx-proxy-manager proxy host, via its API
  deploy/
    install.sh            # the ONLY installer: units + secrets + data dirs
    *.container           # every unit, rendered (they reference the data dir)
    *.container.in        # lightningd and monero-wallet-rpc, rendered (secrets)
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
  tor/Containerfile       # built by install.sh: the Tor proxy
  netcheck/Containerfile  # built by install.sh: the curl client the host checks run
```

## Rollback

Everything is idempotent and every replaced real unit is backed up to
`~/.config/containers/systemd/<unit>.bak`. Restore the `.bak` beside its unit
and `systemctl --user daemon-reload`. To roll back an application, check out an
older commit in its repo and `./deploy.sh --only <app>`.
