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

| Unit | Image | Published on the LAN | Data |
| --- | --- | --- | --- |
| `bitcoind` | `docker.io/lncm/bitcoind:v27.2` | — (RPC stays on `npm-network`) | `~/data/bitcoin` |
| `monerod` | `ghcr.io/sethforprivacy/simple-monerod:latest` | — | `~/data/monero` |
| `monero-wallet-rpc` | `ghcr.io/sethforprivacy/simple-monero-wallet-rpc:latest` | `127.0.0.1:18083` | `~/data/monero-wallet-rpc` |
| `lightningd` | `docker.io/elementsproject/lightningd:latest` | — (onion over Tor) | `~/data/cln` |
| `tor` | `localhost/tor:0.4.9.11-alpine3.20` | `127.0.0.1:9050-9051` | `~/data/tor` |
| `valkey` | `docker.io/valkey/valkey:9-alpine` | — | — |
| `searxng` | `docker.io/searxng/searxng:latest` | `8080` | `~/data/searxng` |
| `nginx-proxy-manager` | `docker.io/jc21/nginx-proxy-manager:latest` | `80`, `443`, `81` | `~/npm/{data,letsencrypt}` |
| `searxng-mcp` | `localhost/searxng-mcp:latest` | `8000` | — |
| `bitcoin-node-mcp` | `localhost/bitcoin-node-mcp:latest` | `8101` | — |
| `monero-node-mcp` | `localhost/monero-node-mcp:latest` | `8102` | — |
| `monero-wallet-mcp` | `localhost/monero-wallet-mcp:latest` | `8103` 🔑 | — |
| `lightning-mcp` | `localhost/lightning-mcp:latest` | `8104` 🔑 | — |

No daemon RPC port is published on the LAN: the daemons address each other by
container name on `npm-network` (`10.89.0.0/24`, pinned in
`deploy/npm-network.network` because `tor.container` pins `--ip=10.89.0.240` and
both `bitcoin.conf` and `torrc` allow that subnet). The MCP servers publish
their own raw ports; `nginx-proxy-manager` is available for you to add proxy
hosts by hand but is **not** in the request path for any MCP server.

🔑 = a money-moving surface. Spending is **off** by default on both.

## One-click install

On a truly bare Rocky Linux 10 host (no git, no podman):

```sh
curl -fsSL https://raw.githubusercontent.com/regularnmae/stack/main/bootstrap.sh | bash
~/build/stack/deploy.sh
```

`bootstrap.sh` installs podman/firewalld/git, enables user linger, sets
`net.ipv4.ip_unprivileged_port_start=80` (so nginx-proxy-manager can bind
80/443/81 rootless), creates the data directories and clones this repo to
`~/build/stack`. `deploy.sh` then clones the app repos, builds every image,
starts everything in order, opens firewalld and verifies.

With git already present, the equivalent is:

```sh
git clone https://github.com/regularnmae/stack ~/build/stack
cd ~/build/stack
./bootstrap.sh
./deploy.sh           # or: ./deploy.sh --bootstrap to do both in one step
```

`sudo` needs a terminal to prompt for its password, so run these from an
interactive shell (over SSH, `ssh -t`).

`deploy.sh` is idempotent and never destructive: re-running reuses every
existing secret and leaves running containers alone. Common flags:

```sh
./deploy.sh --only bitcoin-node-mcp   # rebuild and restart one service
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

## How secrets are kept out of git

No secret is committed. Everything real is generated or adopted on the host,
under `~/.config/<name>/` and `~/data/`, mode 600.

- **`~/.config/stack/secrets.env`** holds the node secrets (bitcoind RPC user
  and password, Tor service password, Monero wallet password and RPC login).
  It is resolved in the order **`secrets.env` → the currently-installed unit →
  the daemon's own config → generate**, so adopting the deploy on a running
  host changes no credential.
- **Per-app env files** (`~/.config/<name>/{token,upstream,spend,node}.env`)
  hold the bearer tokens, upstream credentials, spend policy and CLN runes. The
  unit reads them with `EnvironmentFile=`; the shapes are documented in
  `deploy/examples/<name>/`.

**Quadlet does not expand environment variables in `Exec=`**, which is why
`lightningd` and `monero-wallet-rpc` are *rendered* from `deploy/*.container.in`
by `install.sh` (substituting `@PLACEHOLDERS@`), while the secret-free units are
symlinked. The rendered units are mode 600 and never enter git. Do not "simplify"
`monero-wallet-rpc` to a config file: its entrypoint binds `0.0.0.0` only when
`--rpc-login` is on the command line.

`bitcoind` keeps its RPC credentials in its own `bitcoin.conf`, which
`install.sh` seeds on a fresh host and hands to the image uid. It is edited
through the container: `podman exec -it bitcoind vi /data/.bitcoin/bitcoin.conf`.

## Layout

```
stack/
  bootstrap.sh            # bare host -> podman, linger, sysctl, firewalld, dirs
  deploy.sh               # the one-click orchestrator
  verify.sh               # health + endpoint checks
  stack.conf              # repo / port / order manifest
  scripts/wallets.sh      # Monero + Bitcoin create/restore
  deploy/
    install.sh            # the ONLY installer: units + secrets + data dirs
    *.container           # every unit, symlinked
    *.container.in        # lightningd and monero-wallet-rpc, rendered (secrets)
    npm-network.network
    searxng/{settings.yml,limiter.toml}
    examples/<app>/*.example
  tor/Containerfile
```

## Rollback

Everything is idempotent and every replaced real unit is backed up to
`~/.config/containers/systemd/<unit>.bak`. Restore the `.bak` beside its unit
and `systemctl --user daemon-reload`. To roll back an application, check out an
older commit in its repo and `./deploy.sh --only <app>`.
