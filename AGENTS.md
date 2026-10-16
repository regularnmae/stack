# stack — agent notes

Not a program: `bootstrap.sh`, `deploy.sh`, `verify.sh`, `deploy/install.sh`,
`scripts/wallets.sh`, and every quadlet unit the host runs. This repo is the
**single owner of the runtime** for the whole stack. The application repos
(`searxng-mcp`, `bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`,
`lightning-mcp`) ship only code, tests, CI and a `Containerfile` — no unit, no
`deploy/`, no `deploy.sh`. If a unit or an env file changes, it changes here.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`.** An
`EnvironmentFile=`/`Environment=` reaches the container's environment, not the
daemon's argv. So a secret cannot be fed to `--bitcoin-rpcpassword` etc. from an
env file. Two answers, and the split is deliberate:

- secret-free units (`bitcoind`, `monerod`, `tor`, `valkey`, `searxng`, NPM and
  the five MCP units) are **rendered** too, but their `@PLACEHOLDERS@` are only
  `@DATA_DIR@`/`@CONFIG_DIR@` — their secrets live in the daemons' own files or
  in `EnvironmentFile=`;
- secret-bearing units (`lightningd`, `monero-wallet-rpc`) are **rendered** from
  a `.container.in` by `install.sh`, substituting `@PLACEHOLDERS@` from
  `$DATA_DIR/config/stack/secrets.env` as well. The rendered units are mode 600,
  never committed. (Every unit is rendered — `install.sh` `UNITS` — because all
  of them reference the data or config dir; none is a symlink.)

Do not move a secret onto a committed `.container`, and do not "simplify"
`monero-wallet-rpc` to a config file: the image's entrypoint only binds `0.0.0.0`
when `--rpc-login` is on the command line, otherwise it forces `127.0.0.1` and
the wallet is unreachable from the MCP server.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewall ports, dirs
./deploy.sh                         # fetch repos, build, start, verify
./deploy.sh --only <name>           # one service; --dry-run to plan
./deploy.sh --only backup           # run the backup job now
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health + MCP handshakes
./scripts/wallets.sh --monero       # create/restore the Monero wallet
./scripts/backup.sh                 # restic backup / restore / inspect
shellcheck -x -P SCRIPTDIR -S info bootstrap.sh deploy.sh verify.sh deploy/install.sh scripts/lib.sh scripts/wallets.sh scripts/backup.sh  # the CI lint
```

## Facts that are easy to get wrong

- **`install.sh` is the only installer.** It seeds every env file and renders
  every unit. Adding a service means adding its unit to the `UNITS` array and its
  env seeding to `install.sh` — nothing in the app repos.
- **Secret resolution order** is `secrets.env` → the currently-installed unit
  (`flag_value`) → the daemon's config (`bitcoin_conf_value`) → generate. Keep
  that order: it is what makes adoption on a running host a no-op.
- **`deploy.sh` is re-entrant and ordered.** It runs `install.sh` twice: once up
  front (units, secrets, data dirs) and once after `lightningd` is up, because
  the CLN runes need a running node. Do not collapse those into one call.
- **CLN runes are verified, not trusted.** `createrune` happily returns a rune
  whose `unique_id` the node has blacklisted; `install.sh` proves each one with
  `checkrune` and retries on a fresh id. This bit the first deploy (server
  reported healthy while every tool call failed with 1503).
- **`monero-wallet-rpc` cannot start before the wallet exists.** `deploy.sh`
  runs the wallet step between `monerod` and the wallet RPC for that reason.
- **Data-dir ownership.** `bitcoind` and `monero-wallet-rpc` run as the image's
  uid (host 525287 = in-container 1000) and do **not** re-own their bind mounts;
  `install.sh` does `podman unshare chown -R 1000:1000` for them. `monerod`'s
  entrypoint does re-own its own directory. `$DATA_DIR/cln` and `$DATA_DIR/tor` are
  written by container root, which is the host user under rootless podman.
- **Backup is a one-shot Quadlet job plus a plain user timer.** `backup.container`
  is `Type=oneshot` with **no `[Install]` and no `RemainAfterExit`** (either would
  stop the timer from ever firing again); `backup.timer` is not Quadlet at all --
  Quadlet has no `.timer` type -- so `install.sh` renders it into
  `~/.config/systemd/user/` and `systemctl --user enable --now`s it. It activates
  the `backup.service` the generator makes from `backup.container`.
- **The backup set is `cln/ monero-wallet-rpc/ config/ npm/` only.** The chains and
  `searxng/` are re-downloadable and stay out, so restic never walks them. The repo
  lives in `$STACK_BACKUP_DIR` (stack.conf), outside `$DATA_DIR`, and the unit is
  secret-free: the repo path and `RESTIC_PASSWORD` reach it through `backup.env`
  (`EnvironmentFile`). `scripts/backup.sh` reads them from the **environment first,
  then the file** -- the only order that can recover a fresh host, since the file
  lives inside the repository.
- **Shared bind mounts use `:z`, not `:Z`.** The backup container mounts `cln/` and
  `npm/` read-only alongside `lightningd` and `nginx-proxy-manager`; two containers
  cannot share a path one labels private (whichever starts last relabels it and
  locks the other out). Those two units were flipped from `:Z` to `:z` for this.
- **`sudo` lives only in `bootstrap.sh`.** `deploy.sh`, `deploy/install.sh`,
  `verify.sh` and the `scripts/` helpers never call it; privileged host setup
  (packages, linger, the unprivileged-port sysctl, firewalld ports) is bootstrap's
  job. A data dir the deploy cannot prepare is an error carrying the one-time
  commands, not an implicit prompt. SELinux labelling is best-effort unprivileged
  (`chcon` on the top dir only -- the image-uid subdirs are not ours to relabel,
  and podman's `:z` labels the mounted subdirs); the `semanage`/`restorecon` form is
  printed only when the path is not ours to relabel.
- **The network subnet is pinned** (`10.89.0.0/24` in
  `deploy/npm-network.network`) because `tor.container` pins `--ip=10.89.0.240`
  and both `bitcoin.conf` (`rpcallowip`) and `torrc` (`SocksPolicy`) allow that
  subnet. Every copy of the file carries it; don't drop it.
- **`:80` rootless** needs `net.ipv4.ip_unprivileged_port_start<=80`, which
  `bootstrap.sh` sets — otherwise nginx-proxy-manager cannot bind.
- `tor.container` addresses Tor by pinned IP, not name: `lightningd` runs with
  `--always-use-proxy=true`, which suppresses DNS.
- `torrc`'s `HashedControlPassword` must hash to the plaintext
  `TOR_SERVICE_PASSWORD`; `install.sh` derives it with `tor --hash-password` on a
  fresh host (after building the tor image) and otherwise leaves `torrc` alone.
- **Spending stays off**: `install.sh` writes `ENABLE_SPENDING=0` to both money
  servers' `spend.env`. Never seed it to 1.
- MCP test suites live in their own repos; `./verify.sh` is the runtime check
  (health, 401-without-token, authenticated handshake per endpoint).

## Interface contract with the app repos

The five MCP servers are pure env-configured services: **they never read a stack
path, a config file or a data dir** — only the variables below. This table is
the shared contract; the app repos' docs own the *meaning* of the variables,
this repo owns everything about *how they get set*. If a container name, port or
variable name changes, it changes on both sides at once.

| Server | Container / unit / image | Env files (`$DATA_DIR/config/<app>/`) | Upstream it defaults to | Host port | Bind + health |
| --- | --- | --- | --- | --- | --- |
| `searxng-mcp` | `searxng-mcp` / `localhost/searxng-mcp:latest` | `token.env` | `searxng:8080/search` | `8000` | `0.0.0.0:8000`, `/health` |
| `bitcoin-node-mcp` | `bitcoin-node-mcp` / `localhost/bitcoin-node-mcp:latest` | `token.env`, `upstream.env` | `bitcoind:8332` | `8101` | `0.0.0.0:8000`, `/health` |
| `monero-node-mcp` | `monero-node-mcp` / `localhost/monero-node-mcp:latest` | `token.env`, `upstream.env` | `monerod:18089` | `8102` | `0.0.0.0:8000`, `/health` |
| `monero-wallet-mcp` | `monero-wallet-mcp` / `localhost/monero-wallet-mcp:latest` | `token.env`, `upstream.env`, `spend.env` | `monero-wallet-rpc:18083/json_rpc` | `8103` | `0.0.0.0:8000`, `/health` |
| `lightning-mcp` | `lightning-mcp` / `localhost/lightning-mcp:latest` | `token.env`, `node.env`, `spend.env` | `lightningd:3010` | `8104` | `0.0.0.0:8000`, `/health` |

The variables the apps read (names and defaults are the app repos' contract):
`SEARXNG_URL`/`SEARXNG_MCP_TOKEN`; `BITCOIN_RPC_URL`/`BITCOIN_RPC_USER`/
`BITCOIN_RPC_PASSWORD`/`BITCOIN_MCP_TOKEN`; `MONERO_RPC_URL`/`MONERO_RPC_USER`/
`MONERO_RPC_PASSWORD`/`MONERO_MCP_TOKEN`; `MONERO_WALLET_RPC_URL`/
`MONERO_WALLET_RPC_USER`/`MONERO_WALLET_RPC_PASSWORD`/`MONERO_MCP_TOKEN`/
`MONERO_MCP_SPEND_TOKEN`; `LIGHTNING_REST_URL`/`LIGHTNING_RUNE`/
`LIGHTNING_SPEND_RUNE`/`LIGHTNING_TLS_INSECURE`/`LIGHTNING_CA_CERT`/
`LIGHTNING_MCP_TOKEN`/`LIGHTNING_MCP_SPEND_TOKEN`; and the shared
`MCP_HOST`/`MCP_PORT`, `ENABLE_SPENDING` and the spend caps.

Because the upstream names/ports are compiler-baked defaults, renaming a daemon
in `deploy/` without updating this table (and the app's default) silently breaks
that server — treat this section as the thing to check when either side moves.
