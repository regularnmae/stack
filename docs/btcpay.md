# BTCPay Server

The settlement engine's moving parts that are not a container: the view-only
XMR wallet, the plugin that is a file, and the read-only key the MCP holds. Read
this before touching `config/btcpay/`, `btcpay-wallet.sh`, the bootstrap, or the
`btcpay` unit.

## Invariants

- **The XMR wallet is view-only and optional at first**; the bootstrap leaves
  XMR-CHAIN disabled while the wallet RPC has no wallet open.
- **Never import a wallet whose restore height is above monerod's tip** -- the
  wallet RPC stalls and the plugin's load times out.
- **The plugin is a file, so no unit digest sees a bump**: `install.sh` keeps a
  `.artifact-sha256` marker, and `start_btcpay` compares the DLL's mtime against
  the container's `StartedAt`.
- **`btcpay-mcp` holds a read-only key** with four `canview*` permissions, minted
  by the bootstrap; `/api/v1/server/info` needs `unrestricted` and is not
  exposed.

## The view-only Monero wallet

- **The BTCPay Monero wallet is view-only and optional at first.** `deploy.sh`
  starts `monero-wallet-btcpay` (no wallet file yet); `./configure.sh` then runs
  `scripts/btcpay-wallet.sh`, which imports it only when
  `config/btcpay/xmr-wallet.env` has an address and view key. The bootstrap
  leaves XMR-CHAIN disabled while the wallet RPC has no wallet open. The one
  import that must not run is a restore height **above monerod's current
  height**: Monero answers "Blocks start before blockchain offset", the wallet
  RPC stalls in a refresh loop, and the plugin's wallet load times out — so
  `btcpay-wallet.sh` compares the two and skips until the daemon catches up.
  The env can be filled at any time; re-run `./configure.sh --only btcpay` once
  the chain is current.

## The plugin is a file

- **The BTCPay Monero plugin is a file, so nothing else notices a bump.**
  `install.sh` writes `.artifact-sha256` into the plugin directory and skips the
  download only while that marker still matches `BTCPAY_PLUGIN_SHA256`; the
  extraction goes into a staging sibling and is swapped in whole, so a new
  version never inherits the old one's leftover files and a failed download or
  extract leaves the working plugin alone. But a unit digest cannot see a file in
  `$DATA_DIR` — it hashes the unit definitions, and `--only btcpay` finds
  btcpay's unit unchanged — and `start` is a no-op on an active container, so
  `start_btcpay` calls
  `btcpay_plugin_newer` (the DLL's mtime against podman's `StartedAt`, i.e.
  `refresh_image_unit` answered for a file) and restarts before its single health
  wait. BTCPay loads plugin assemblies at start and keeps the mapped copy, which
  is why the restart is required, not tidy: `btcpay-bootstrap` enables XMR-CHAIN
  through BTCPay's API and needs the new assembly loaded.

## The read-only MCP key

- **`btcpay-mcp` holds a read-only BTCPay key, and the bootstrap mints it.**
  `scripts/btcpay_bootstrap.py`'s `ensure_mcp_key()` creates
  `BTCPAY_MCP_KEY` with four `canview*` store permissions (store settings,
  invoices, payment requests, wallet) and saves it in
  `config/btcpay/bootstrap.env`; it is never the `unrestricted` admin key and
  never the backend's write-capable runtime key. The key is scoped
  (`perm:<storeId>`) when BTCPay accepts that form; the four permissions are
  the boundary either way. `configure.sh`'s `write_btcpay_mcp_env()` rewrites
  `config/btcpay-mcp/upstream.env` from that state on every run, so a re-minted
  key never leaves a stale copy, and it restarts a running `btcpay-mcp` when
  the content changed.
  The minting step is deliberately best-effort: a key problem leaves the MCP
  reporting `unconfigured`, never the store, webhook or backend key unmade.
  `GET /api/v1/server/info` needs `unrestricted` and is not exposed, and
  `GET .../payment-methods?includeConfig=true` needs a *modify* permission, so
  the tools never ask for either. The server redacts
  `additionalData.preimage`, the `apiKey` that `/api/v1/api-keys/current`
  echoes, and connection strings, and it rewrites BTCPay's internal
  `http://btcpay:49392` links to `BTCPAY_PUBLIC_URL`.

