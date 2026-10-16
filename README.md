# stack

The whole server stack for the mainnet host, in one repo: every podman/quadlet
unit, every secret/env wiring, and a one-click deploy that can rebuild the host
from scratch.

The application code lives in sibling repos — `searxng-mcp`,
`bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`, `lightning-mcp` —
each of which ships only its code, tests, CI and `Containerfile`. **Their units
and env files live here**, so there is exactly one place that defines how the
stack runs and one script that fixes a deployment problem.

## What runs

| Unit | Image | Published on the host | Data |
| --- | --- | --- | --- |
| `bitcoind` | `docker.io/lncm/bitcoind:v27.2` | — (RPC stays on `npm-network`) | `$DATA_DIR/bitcoin` |
| `monerod` | `ghcr.io/sethforprivacy/simple-monerod:latest` | — | `$DATA_DIR/monero` |
| `monero-wallet-rpc` | `ghcr.io/sethforprivacy/simple-monero-wallet-rpc:latest` | `127.0.0.1:18083` | `$DATA_DIR/monero-wallet-rpc` |
| `lightningd` | `docker.io/elementsproject/lightningd:latest` | — (onion over Tor) | `$DATA_DIR/cln` |
| `tor` | `localhost/tor:local` (built from `tor/Containerfile`) | `127.0.0.1:9050-9051` | `$DATA_DIR/tor` |
| `valkey` | `docker.io/valkey/valkey:9-alpine` | — | — |
| `searxng` | `docker.io/searxng/searxng:latest` | `127.0.0.1:8080` (via NPM) | `$DATA_DIR/searxng` |
| `nginx-proxy-manager` | `docker.io/jc21/nginx-proxy-manager:latest` | `80`, `443`, `81` | `$DATA_DIR/npm/{data,letsencrypt}` |
| `searxng-mcp` | `localhost/searxng-mcp:latest` | `127.0.0.1:8000` (via NPM) | — |
| `bitcoin-node-mcp` | `localhost/bitcoin-node-mcp:latest` | `127.0.0.1:8101` (via NPM) | — |
| `monero-node-mcp` | `localhost/monero-node-mcp:latest` | `127.0.0.1:8102` (via NPM) | — |
| `monero-wallet-mcp` | `localhost/monero-wallet-mcp:latest` | `127.0.0.1:8103` 🔑 (via NPM) | — |
| `lightning-mcp` | `localhost/lightning-mcp:latest` | `127.0.0.1:8104` 🔑 (via NPM) | — |

No daemon RPC port is published on the LAN: the daemons address each other by
container name on `npm-network` (`10.89.0.0/24`, pinned in
`deploy/npm-network.network` because `tor.container` pins `--ip=10.89.0.240` and
both `bitcoin.conf` and `torrc` allow that subnet). The MCP servers and searxng
bind **loopback only** (`127.0.0.1`), and those loopback ports are **not** opened
in firewalld: `nginx-proxy-manager` terminates TLS and is the sole path in,
reaching each container by name on `npm-network`. The proxy hosts are added by
hand in the NPM admin UI (`81`) and live in NPM's database, not in this repo.

Only `80`, `443` and `81` (NPM) are opened on the LAN (`FIREWALL_PORTS` in
`stack.conf`). If you adopted an older host that still had `8000`/`8080`/
`8101-8104` open, close them once by hand — `bootstrap.sh` only ever opens ports,
it never closes them:

```sh
sudo firewall-cmd --permanent --remove-port=8000/tcp --remove-port=8080/tcp \
  --remove-port=8101/tcp --remove-port=8102/tcp --remove-port=8103/tcp \
  --remove-port=8104/tcp && sudo firewall-cmd --reload
```

🔑 = a money-moving surface. Spending is **off** by default on both.

A nightly, encrypted restic backup of the irreplaceable state (`cln/`,
`monero-wallet-rpc/`, `config/`, `npm/`) runs from `backup.timer` into
`$STACK_BACKUP_DIR`. It is the one thing that recovers you if the data disk
itself is lost — see [Backup & restore](#backup--restore).

## One-click install

On a truly bare Rocky Linux 10 host (no git, no podman):

```sh
curl -fsSL https://raw.githubusercontent.com/regularnmae/stack/main/bootstrap.sh | bash
~/build/stack/deploy.sh
```

`bootstrap.sh` installs podman/firewalld/git, enables user linger, sets
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
five MCP servers (a plain start would keep running a stale image). Common flags:

```sh
./deploy.sh --only bitcoin-node-mcp   # rebuild and restart one service
./deploy.sh --only backup             # run the backup job now
./deploy.sh --skip-apps               # infrastructure only (daemons, searxng, NPM)
./deploy.sh --no-wallets              # skip the interactive wallet prompts
./deploy.sh --dry-run                 # print the plan, change nothing
./verify.sh                           # container health + MCP handshakes
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
  - `config/` — every bearer token and secret
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
the four things in `$DATA_DIR` that cannot be re-downloaded:

- `cln/` — the CLN node identity, channel state and onion keys
- `monero-wallet-rpc/` — the Monero wallet (funds)
- `config/` — every token, rune and secret
- `npm/` — nginx-proxy-manager's config and TLS material

The chains (`bitcoin/`, `monero/`) and `searxng/` are deliberately **excluded**:
they are large and regenerable, so restic never walks them.

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
./scripts/backup.sh restore latest # writes cln/, monero-wallet-rpc/, config/, npm/
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
  scripts/lib.sh          # data-dir resolution + SELinux labelling
  scripts/wallets.sh      # Monero + Bitcoin create/restore
  scripts/backup.sh       # restic backup / restore / inspect the repository
  deploy/
    install.sh            # the ONLY installer: units + secrets + data dirs
    *.container           # every unit, rendered (they reference the data dir)
    *.container.in        # lightningd and monero-wallet-rpc, rendered (secrets)
    *.timer               # backup.timer (plain user unit; Quadlet has no .timer)
    npm-network.network
    searxng/{settings.yml,limiter.toml}
    examples/<app>/*.example      # env-file shapes, kept in sync with install.sh by hand
    examples/stack/*.example      # bitcoin.conf / torrc / secrets templates
    examples/backup/*.example     # backup.env shape
  tor/Containerfile
```

## Rollback

Everything is idempotent and every replaced real unit is backed up to
`~/.config/containers/systemd/<unit>.bak`. Restore the `.bak` beside its unit
and `systemctl --user daemon-reload`. To roll back an application, check out an
older commit in its repo and `./deploy.sh --only <app>`.
