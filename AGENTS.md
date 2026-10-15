# crypto-nodes — agent notes

Not a program: a set of podman/quadlet units in `deploy/` plus an idempotent
`install.sh`, and the `tor/Containerfile` that builds the tor image. This repo
is the **single owner** of the crypto node units; the MCP repos and
`searxng-mcp` own only their own unit and (conditionally) `npm-network.network`.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`.** An
`EnvironmentFile=`/`Environment=` reaches the container's environment, not the
daemon's argv. So a secret cannot be fed to `--bitcoin-rpcpassword` etc. from
an env file. There are two answers, and the split is deliberate:

- secret-free units (`bitcoind`, `monerod`, `tor`) are **symlinked** — their
  secrets live in the daemons' own files (`bitcoin.conf`, `torrc`);
- secret-bearing units (`lightningd`, `monero-wallet-rpc`) are **rendered**
  from a `.container.in` template by `install.sh`, substituting
  `@PLACEHOLDERS@` from `~/.config/crypto-nodes/secrets.env`. The rendered unit
  is mode 600 and is never committed.

Do not move a secret back onto a committed `.container`, and do not "simplify"
`monero-wallet-rpc` to a config file: the image's entrypoint only binds
`0.0.0.0` when `--rpc-login` is on the command line, otherwise it forces
`127.0.0.1` and the MCP cannot reach the wallet.

## Commands

```sh
./deploy/install.sh                                           # idempotent; renders units, seeds torrc, reloads
podman build -t localhost/tor:0.4.9.11-alpine3.20 tor/
systemctl --user restart lightningd.service monero-wallet-rpc.service
podman exec lightningd lightning-cli getinfo
podman exec monero-wallet-rpc /healthcheck.sh
```

## Facts that are easy to get wrong

- **Secret resolution order** in `install.sh`: `secrets.env` → the
  currently-installed unit (`flag_value`) → the daemon's config
  (`bitcoin_conf_value`) → generate. This is what makes adoption on a running
  host a no-op. Keep that order.
- `render_unit` removes a pre-existing **symlink** at the target before writing,
  so the write can never follow a symlink back into the repo. `install -m 600`
  sets the mode.
- `install.sh` backs a real unit file up to `<unit>.container.bak` before
  replacing it. That is the rollback path.
- The rendered `lightningd` unit's secrets were read from the old unit's
  `--bitcoin-rpcpassword` / `--tor-service-password`; the rendered
  `monero-wallet-rpc`'s from `--password` / `--rpc-login`. If a future unit
  renames a flag, update `flag_value` calls accordingly.
- `tor.container` pins `PodmanArgs=--ip=10.89.0.240`; lightningd references
  that IP (not the name) because `--always-use-proxy=true` suppresses DNS.
- `torrc`'s `HashedControlPassword` must hash to the plaintext
  `TOR_SERVICE_PASSWORD` lightningd sends; `install.sh` derives it with
  `tor --hash-password` on a fresh host and otherwise leaves `torrc` alone.
- `~/data/bitcoin` and `~/data/monero-wallet-rpc` are owned by the image's uid,
  so their config files are edited through a container, not as `$USER`.
- MCP `EnvironmentFile=` files (token/upstream/spend) are unrelated to this
  repo and belong to each MCP repo.
