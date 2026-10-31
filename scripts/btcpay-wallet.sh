#!/usr/bin/env bash
# Import the BTCPay Monero plugin's view-only wallet.
#
#   scripts/btcpay-wallet.sh
#
# The plugin never receives a seed or a spend key: it is given the primary
# address, the private view key and a restore height, and it asks wallet-rpc for
# a view-only wallet named `wallet`. This script applies the same three values
# from config/btcpay/xmr-wallet.env, then restarts BTCPay so the plugin opens
# it. Until that file is filled in, the script is a no-op and XMR-CHAIN stays
# disabled; btcpay-bootstrap re-enables it on the next run.
#
# The spend key must stay offline (the wallet you created the address with).
# Losing the view key only means re-importing it; losing the spend key means
# losing the funds.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

resolve_data_dir
WALLET_ENV="$CONFIG_DIR/btcpay/xmr-wallet.env"
WALLET_DIR="$DATA_DIR/btcpay/xmr-wallet"
WALLET_RPC=monero-wallet-btcpay

if [ ! -f "$WALLET_ENV" ]; then
    log "no $WALLET_ENV; skipping the BTCPay Monero wallet"
    exit 0
fi

address=$(env_value "$WALLET_ENV" XMR_WALLET_ADDRESS)
view_key=$(env_value "$WALLET_ENV" XMR_VIEW_KEY)
restore_height=$(env_value "$WALLET_ENV" XMR_RESTORE_HEIGHT)

case "$address" in
    ""|"<"*)
        log "XMR_WALLET_ADDRESS is unset in $WALLET_ENV; skipping the BTCPay Monero wallet"
        exit 0
        ;;
esac
if [ -z "$view_key" ] || [ "${view_key#<}" != "$view_key" ]; then
    warn "XMR_VIEW_KEY is unset in $WALLET_ENV; skipping the BTCPay Monero wallet"
    exit 0
fi
[ -n "$restore_height" ] || restore_height=0

if [ -f "$WALLET_DIR/wallet.keys" ]; then
    log "BTCPay Monero wallet already exists: $WALLET_DIR/wallet (leaving it alone)"
    exit 0
fi

if ! podman ps --filter 'name=^monero-wallet-btcpay$' --format '{{.Status}}' 2>/dev/null | grep -q '^Up'; then
    warn "monero-wallet-btcpay is not running; start the stack first"
    exit 1
fi

log "importing the view-only Monero wallet (restore height $restore_height)"
json=$(printf '{"jsonrpc":"2.0","id":"0","method":"generate_from_keys","params":{"filename":"wallet","address":"%s","viewkey":"%s","password":"","restore_height":%s,"language":"English","save_height":true}}' \
    "$address" "$view_key" "$restore_height")
response=$(printf '%s' "$json" | podman exec -i "$WALLET_RPC" curl -s -m 120 \
    -H 'Content-Type: application/json' --data-binary @- \
    http://127.0.0.1:18083/json_rpc)
if printf '%s' "$response" | grep -q '"error"'; then
    warn "the wallet RPC refused the import: $response"
    exit 1
fi

# The plugin only opens the wallet at BTCPay startup; restart it so the wallet
# becomes visible, then the caller re-runs btcpay-bootstrap to enable XMR-CHAIN.
systemctl --user restart btcpay.service
log "view-only Monero wallet imported; BTCPay restarted"
