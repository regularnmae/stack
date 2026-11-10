# The chain tier: bitcoind, monerod, CLN, Fulcrum and the explorers

The daemons themselves: what each one is, what its health probe may and may not
check, and how to read CLN's peer and channel state. Read this before touching a
daemon unit, `fulcrum`, or an explorer.

## Invariants

- **Both daemons are full archival nodes**, and the data disk is sized for it.
- **`fulcrum` is the one non-NPM LAN surface**: raw Electrum on 50001/50002, no
  `[npm.*]` entry, ports kept in `FIREWALL_PORTS`. Ask it for
  `blockchain.headers.subscribe`, never `server.version`.
- **CLN peers and channels come from `listpeerchannels`/`listpeers`**, never
  `listchannels` or `getinfo`'s `num_peers`.
- **`lightningd` can die with its container still "Up"**, which is why its unit
  carries `HealthOnFailure=kill`.
- **The explorers add no index**; they read bitcoind (plus Fulcrum) or monerod.
- **A wallet restore is `restorewallet` with `backup_file`, `load_on_startup=true`
  and no RPC timeout** (`-rpcclienttimeout=0`).

## lightningd dies with its container left Up

- **lightningd dies with its container left "Up":** bcli can time out while
  bitcoind is still loading its wallet, the entrypoint then keeps PID 1 alive,
  the unit reads "active" and `Restart=always` never fires -- which is how
  lightning-mcp answers 502 while the unit looks fine. The unit therefore
  carries `HealthOnFailure=kill` (podman's own advice: inside a unit prefer
  kill/stop so systemd's restart policy is the one that acts), so the failing
  healthcheck ends the container and `Restart=always` recreates it. `deploy.sh`
  still restarts a still-active but `unhealthy` lightningd, as the fallback for
  a container older than that unit line; it does not wait. `./configure.sh`
  waits for wallet-level RPC before waiting on lightningd (and dumps the log on
  a timeout) before minting the runes, then restarts `lightning-mcp` when the
  rune file changed. That wait is
  `bitcoind_wallet_ready` (`listwallets` non-empty), **never a bare
  `getwalletinfo`**: a node with two wallets loaded -- a legacy datadir-root
  `mainnet` plus an unnamed `""` -- answers `-19` "Wallet file not specified",
  which says nothing about readiness, so that wait burned its full 120 s on every
  configure run and then skipped the lightningd wait. The same class of trap in
  `scripts/wallets.sh`: `loadwallet` answering `-35` means the wallet is already
  loaded, i.e. success, and reporting it as failure is how a healthy node came
  to look unconfigured (a transient `podman exec` miss is why the first check
  can disagree with the second, so each load attempt re-proves it with
  `listwallets`). Not on
  `monero-wallet-btcpay`: its healthcheck is red for as long as the wallet
  refreshes, so killing it would restart the refresh from scratch.

## Restoring the Bitcoin wallet

`scripts/wallets.sh` restores a `.dat` backup by copying it into the container and
calling `restorewallet`. Three things about that call are traps:

- The named parameter is `backup_file`; `wallet_backup_file` does not exist and
  answers `-8 Unknown named parameter`.
- `load_on_startup=true` is what writes the name into `settings.json`. Without it
  the restore succeeds and the wallet is absent at the next bitcoind restart.
- `restorewallet` rescans, and this node has no `blockfilterindex`, so the call can
  outlast `bitcoin-cli`'s 900 s default: pass `-rpcclienttimeout=0`.

The temp copy inside the datadir is removed whether the call succeeds or fails, so
its status is captured instead of letting `set -e` abort at the RPC.

## CLN peers and channels

- **CLN peers and channels come from `listpeerchannels`/`listpeers`, never
  `listchannels` or `getinfo`'s `num_peers`:** the gossmap's `active` is an
  operator setting that stays true while a peer is offline, and `num_peers`
  counts peers with channels whether or not they are connected.
  `scripts/monitor.sh` carries the shapes and the counting rule;
  `scripts/metrics.sh` emits `stack_cln_peers`/`stack_cln_channels_offline`.
  `lightning-cli` through `podman exec` is not gated by the clnrest rune — the
  MCP needs the method added to `READ_METHODS` in `deploy/install.sh`.

## Both daemons are full nodes

- **Both daemons are full (archival) nodes:** the chains are large (roughly
  800 GB Bitcoin / 250 GB Monero in late 2026) and the data disk must be sized
  for that. `install.sh` seeds `bitcoin.conf` only when it is missing, so an
  existing host keeps its own values until edited.

## fulcrum

- **`fulcrum` is the Electrum server, and the one non-NPM LAN surface:**
  `deploy/fulcrum.container.in` runs the official image on `npm-network` and
  publishes raw Electrum `50001`/`50002` straight on the LAN, because NPM only
  proxies HTTP — don't add an `[npm.*]` entry for it, and keep the ports in
  `FIREWALL_PORTS`. It indexes from bitcoind's RPC and follows it through IBD,
  accepting wallets only once its own index catches up. `--db_mem` is left at
  Fulcrum 2.1.4's own autodetect — 2048 MiB or 25% of physical RAM, whichever is
  smaller, i.e. 2048 MiB on a 16 GB host — which is what keeps bitcoind and
  monerod their room instead of being swapped out. Setting the flag explicitly
  trades RAM for index throughput (the old 3072 was such a trade); check
  `free -h` during a full resync before raising it. A rebuild loses the DB's
  undo info (Fulcrum's "presume the DB is consistent"), so the next restart
  cannot undo a block. `$DATA_DIR` is a rotational disk, so a from-scratch index
  runs ~40 blocks/min — slow is not a fault to chase, `--db_mem` is the only
  knob, and 2.1.4 exposes no fast-sync or history cap to shrink the work. Its
  `HealthCmd` is the process check on purpose: an index probe would paint a
  normal first run red.
  The functional check is outside the unit — `scripts/lib.sh`'s `electrum_call`/
  `electrum_call_tls`/`electrum_tip` (bash `/dev/tcp` and `openssl s_client`;
  the host has no `nc`), used by `verify.sh --deep` and `scripts/monitor.sh`.
  Ask it for `blockchain.headers.subscribe`, never just `server.version`: that
  one is answered from memory and passes a wedged index.

## The two explorers

- **The two explorers read the daemons; neither adds an index.** `btc-explorer`
  reads bitcoind RPC plus Fulcrum for address history; bitcoind runs
  `txindex=1`, so any historical txid resolves without a block height (the
  index is bitcoind's, built in the background from `blk*.dat`); `xmr-explorer`
  (MoneroBlock) is **RPC-only**
  against monerod's restricted RPC, with no chain copy and no LMDB reader. Both
  are loopback-published, NPM-fronted with `force-ssl`, mirrored as onions,
  watched by `scripts/monitor.sh` through NPM (and, if you add them to the
  status page, by its UI monitors), and built by
  `deploy.sh` only when missing
  (`--only btc-explorer|xmr-explorer|explorers` forces a rebuild). Neither has
  state in the backup set; `config/btc-explorer/btc-explorer.env` is the BTC
  RPC/Fulcrum wiring. `xmr-explorer` probes its static `/style.css`, not `/`,
  which can time out during monerod's initial sync.
