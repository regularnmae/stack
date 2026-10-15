# crypto-nodes

The podman/quadlet units for the crypto node stack on the mainnet host: a
Bitcoin Core node, a Monero node, a Monero wallet RPC, Core Lightning, and the
Tor proxy lightningd uses. This is the **single owner** of those units — the
MCP servers (`bitcoin-node-mcp`, `monero-node-mcp`, `monero-wallet-mcp`,
`lightning-mcp`) and `searxng-mcp` each own only their own unit and the shared
`npm-network.network`, so nothing else can rewrite the node config.

| Unit | Image | Reaches | Data dir |
| --- | --- | --- | --- |
| `bitcoind.container` | `lncm/bitcoind:v27.2` | mainnet, RPC `8332` on `npm-network` | `~/data/bitcoin` |
| `monerod.container` | `simple-monerod` | mainnet, restricted RPC `18089` on `npm-network` | `~/data/monero` |
| `tor.container` | `localhost/tor:0.4.9.11-alpine3.20` | SOCKS/control on `127.0.0.1:9050-9051` | `~/data/tor` |
| `lightningd.container` | `elementsproject/lightningd` | clnrest `3010` + P2P `9735` on `npm-network` | `~/data/cln` |
| `monero-wallet-rpc.container` | `simple-monero-wallet-rpc` | `127.0.0.1:18083` + `npm-network` | `~/data/monero-wallet-rpc` |

No daemon RPC port is published on the LAN. The MCP servers join
`npm-network` and address the daemons by container name.

## How secrets are kept out of git

The original units carried secrets on their `Exec=` lines
(`--bitcoin-rpcpassword`, `--tor-service-password`, `--password`,
`--rpc-login`), which made them uncommittable — they were `chmod 600` host
files in no version control.

**Quadlet does not expand environment variables in `Exec=`**, so an
`EnvironmentFile=` cannot feed those flags (verified: a literal `$FOO` stays a
literal `$FOO` in the generated `ExecStart`). Two mechanisms, chosen per unit:

- **Secret-free units are symlinked.** `bitcoind`, `monerod` and `tor` carry
  no secret — bitcoind's RPC password lives in its own `bitcoin.conf`, and
  tor's control password is a hash in `~/data/tor/torrc`. Their committed
  `.container` files are static and linked.
- **Secret-bearing units are rendered from a template.** `lightningd` and
  `monero-wallet-rpc` need their secrets as arguments, so each ships a
  `.container.in` with `@PLACEHOLDER@` tokens; `install.sh` substitutes values
  from `~/.config/crypto-nodes/secrets.env` and writes the real unit, mode
  `600`, into the quadlet directory. The rendered file is the only copy and
  never enters git.

Why a template and not a daemon config file for the wallet: the
`simple-monero-wallet-rpc` entrypoint only binds `0.0.0.0`
(`--confirm-external-bind`) when it sees `--rpc-login` **on the command line**,
and otherwise forces `127.0.0.1` — which would make the wallet unreachable from
the other containers on `npm-network`. So the secret has to be on `Exec`.

`deploy/secrets.env.example`, `torrc.example` and `bitcoin.conf.example`
document the shapes; none carries a real value.

## Install

```sh
# On the node host, from a checkout under ~/build:
./deploy/install.sh
```

`install.sh` is idempotent and non-destructive:

- resolves each secret in the order **`secrets.env` → the currently-installed
  unit → the daemon's own config → generate**. So adopting it on a host that
  already runs the stack reuses every existing credential and changes nothing;
- writes `~/.config/crypto-nodes/secrets.env` (mode 600);
- renders `lightningd.container` and `monero-wallet-rpc.container` from their
  templates (mode 600), replacing any earlier symlink first;
- symlinks `bitcoind`, `monerod`, `tor` (backing up any real file to `.bak`)
  plus `npm-network.network` if no other repo already provided it;
- seeds `~/data/tor/torrc` on a fresh host, computing the control-password
  hash with `tor --hash-password`;
- reloads systemd.

Then restart the units whose `Exec` is rendered, and verify:

```sh
systemctl --user restart lightningd.service monero-wallet-rpc.service

podman exec lightningd lightning-cli getinfo | head -5
podman exec monero-wallet-rpc /healthcheck.sh && echo wallet-rpc healthy
```

Roll back a single unit by restoring `<unit>.container.bak` beside it in
`~/.config/containers/systemd/` and re-running `systemctl --user daemon-reload`.

### The Tor image

`tor.container` uses `localhost/tor:0.4.9.11-alpine3.20`, built from
`tor/Containerfile`:

```sh
podman build -t localhost/tor:0.4.9.11-alpine3.20 tor/
```

### Fresh hosts

This repo seeds `secrets.env` and the rendered units, but two prerequisites
belong to the nodes themselves and are only referenced here for completeness:

- **`bitcoin.conf`** must exist with an `rpcuser`/`rpcpassword` before
  `install.sh` can reuse it; a fresh host gets a generated password in
  `secrets.env` that must then be written into `bitcoin.conf` (see
  `deploy/bitcoin.conf.example`). That file is owned by the image's uid, so
  edit it through `podman exec bitcoind ...`.
- **The Monero wallet file** (`~/data/monero-wallet-rpc/mainnet`) is created
  out of band; the wallet password in `secrets.env` must match it.

## Layout

```
crypto-nodes/
  deploy/
    bitcoind.container            monerod.container     tor.container
    lightningd.container.in       monero-wallet-rpc.container.in
    npm-network.network
    install.sh
    *.example                     # config/secret templates, no real values
  tor/Containerfile               # the tor image
```
