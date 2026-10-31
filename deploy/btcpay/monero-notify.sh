#!/bin/sh
# monerod --block-notify target for the BTCPay Monero plugin.
#
# monerod's --block-notify spec is whitespace-split, so the script takes no
# argument and sends a constant non-empty hash (the plugin only checks that the
# hash is non-empty for the block event). The wallet is refreshed first because
# the plugin scans the wallet's cached transfer list, which can still be a few
# seconds behind the chain on a newly mined block.
#
# Both calls are best-effort: a BTCPay outage must not make monerod's notify
# helper fail or block block processing.
curl -s -o /dev/null -m 5 http://monero-wallet-btcpay:18083/json_rpc \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"0","method":"refresh"}'
curl -s -o /dev/null -m 5 \
    "http://btcpay:49392/MoneroLikeDaemonCallback/block?cryptoCode=xmr&hash=block"
