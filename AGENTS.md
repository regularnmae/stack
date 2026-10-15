# crypto-nodes — agent notes

Not a program: a set of podman/quadlet units in `deploy/` plus an idempotent
`install.sh`, and the `tor/Containerfile` that builds the tor image. This repo
is the **single owner** of the crypto node units; the MCP repos and
`searxng-mcp` own only their own unit and (conditionally) `npm-network.network`.

## The one rule that shapes everything

**Quadlet does not expand environment variables in `Exec=`.** An
`EnvironmentFile=`/`Environment=` reaches the container's environment, not the
daemon's argv. So a secret cannot be fed to `--bitcoin-rpcpassword` etc. from
an env file — it has to live in a config file the daemon reads. Do not
"simplify" a secret back onto an `Exec=` line; it would either break or force
the unit out of version control. The mapping is in README.md.

## Commands

```sh
./deploy/install.sh                                   # idempotent; seeds configs, symlinks units, reloads
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
- `install.sh` seeds files **only if absent**; it must never clobber a live
  secret. `~/data/cln` is writable by `$USER`; `~/data/monero-wallet-rpc` is
  owned by the image's uid, so its `wallet.conf` is written **through a
  container** (running one via `podman exec`, else `podman run --rm
  --entrypoint sh`). `~/data/bitcoin` is likewise image-owned.
- The `lightningd` secret file is `$LIGHTNINGDIR/config`, i.e.
  `~/data/cln/config` (host) == `/root/.lightning/config` (container),
  the default path lightningd reads at startup — no `--conf` flag needed.
- `monero-wallet-rpc` needs an explicit `--config-file=/home/monero/wallet/wallet.conf`.
- `tor.container` pins `PodmanArgs=--ip=10.89.0.240`; lightningd references
  that IP (not the name) because `--always-use-proxy=true` suppresses DNS.
- `torrc`'s `HashedControlPassword` must hash to the plaintext
  `TOR_SERVICE_PASSWORD` lightningd sends; `install.sh` derives it with
  `tor --hash-password` on a fresh host and otherwise leaves `torrc` alone.
- On adoption, `install.sh` backs a real unit file up to `<unit>.container.bak`
  before symlinking. That is the rollback path.
- MCP `EnvironmentFile=` files (token/upstream/spend) are unrelated to this
  repo and belong to each MCP repo.
