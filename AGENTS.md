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
  the five MCP units) are **symlinked** — their secrets live in the daemons' own
  files or in `EnvironmentFile=`;
- secret-bearing units (`lightningd`, `monero-wallet-rpc`) are **rendered** from
  a `.container.in` by `install.sh`, substituting `@PLACEHOLDERS@` from
  `$DATA_DIR/config/stack/secrets.env`. The rendered unit is mode 600, never committed.

Do not move a secret onto a committed `.container`, and do not "simplify"
`monero-wallet-rpc` to a config file: the image's entrypoint only binds `0.0.0.0`
when `--rpc-login` is on the command line, otherwise it forces `127.0.0.1` and
the wallet is unreachable from the MCP server.

## Commands

```sh
./bootstrap.sh                      # bare host -> podman, linger, sysctl, firewalld, dirs
./deploy.sh                         # fetch repos, build, start, firewall, verify
./deploy.sh --only <name>           # one service; --dry-run to plan
./deploy/install.sh                 # units + secrets + data dirs only
./verify.sh                         # container health + MCP handshakes
./scripts/wallets.sh --monero       # create/restore the Monero wallet
```

## Facts that are easy to get wrong

- **`install.sh` is the only installer.** It seeds every env file and links or
  renders every unit. Adding a service means adding its unit to `STATIC_UNITS`
  (or `RENDERED`) and its env seeding to `install.sh` — nothing in the app repos.
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
