#!/usr/bin/env bash
# Create or restore the wallets this stack needs.
#
#   scripts/wallets.sh [--monero] [--bitcoin]     # default: both
#
# Monero: the node images ship no wallet CLI, so a throwaway monero-wallet-rpc
# is started against the wallet directory (bound to loopback *inside* the
# container, reached with `podman exec` + curl) and driven over JSON-RPC. The
# seed never appears in an argv; restore reads it from stdin.
#
# Bitcoin: uses bitcoin-cli in the running bitcoind container.
#
# Both are interactive and are skipped when there is no TTY. Nothing is
# destroyed: an existing wallet is never overwritten.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# The secrets live under the configured data dir ($DATA_DIR/config) now, so we
# resolve that dir the same way deploy.sh/verify.sh do: stack.conf ->
# data-dir.env -> prompt/default -> $HOME/data. deploy.sh exports
# STACK_DATA_DIR, so an invoked run never re-prompts. The resolution happens
# after the TTY check below, so --help and the no-TTY skip stay side-effect free.
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

# Must stay the same tag as monero-wallet-rpc.container.in: the wallet this
# script creates is served by that unit. Renovate updates both in one PR.
MONERO_IMAGE="ghcr.io/sethforprivacy/simple-monero-wallet-rpc:v0.18.5.1"
MONERO_WALLET="mainnet"
SETUP_NAME="monero-wallet-setup"
SETUP_PORT=18099

BITCOIN_WALLET="mainnet"

DO_MONERO=0
DO_BITCOIN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --monero)  DO_MONERO=1 ;;
        --bitcoin) DO_BITCOIN=1 ;;
        -h|--help) usage_header "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
[ "$DO_MONERO$DO_BITCOIN" = "00" ] && { DO_MONERO=1; DO_BITCOIN=1; }

if [ ! -t 0 ]; then
    log "no TTY; skipping interactive wallet setup"
    exit 0
fi

resolve_data_dir
SECRETS_FILE="$CONFIG_DIR/stack/secrets.env"
# Fall back to the pre-data-dir layout if install.sh has not migrated yet.
[ -s "$SECRETS_FILE" ] || SECRETS_FILE="$CONFIG_HOME/crypto-nodes/secrets.env"
MONERO_DIR="$DATA_DIR/monero-wallet-rpc"

ask() { local p="$1" a; read -r -p "$p" a; printf '%s' "$a"; }

# ---------------------------------------------------------------------------
# Monero
# ---------------------------------------------------------------------------
monero_rpc() { # json -> response
    printf '%s' "$1" | podman exec -i "$SETUP_NAME" curl -s \
        -H 'Content-Type: application/json' --data-binary @- \
        "http://127.0.0.1:$SETUP_PORT/json_rpc"
}

setup_monero() {
    command -v podman >/dev/null 2>&1 || die "podman is required"
    if [ -f "$MONERO_DIR/$MONERO_WALLET" ]; then
        log "Monero wallet already exists: $MONERO_DIR/$MONERO_WALLET (leaving it alone)"
        return 0
    fi
    podman network exists npm-network 2>/dev/null || { warn "npm-network does not exist yet; run ./deploy.sh first"; return 1; }

    local pw; pw=$(env_value "$SECRETS_FILE" MONERO_WALLET_PASSWORD)
    [ -n "$pw" ] || { warn "no MONERO_WALLET_PASSWORD in $SECRETS_FILE; run deploy/install.sh first"; return 1; }

    echo
    log "No Monero wallet at $MONERO_DIR/$MONERO_WALLET."
    echo "    [c] create a new wallet"
    echo "    [r] restore an existing wallet from its 25-word seed"
    echo "    [s] skip"
    local choice; choice=$(ask "Choose [c/r/s]: ")
    case "$choice" in
        c|C) ;;
        r|R) ;;
        *) log "skipping the Monero wallet"; return 0 ;;
    esac

    mkdir -p "$MONERO_DIR"
    podman rm -f "$SETUP_NAME" >/dev/null 2>&1 || true
    log "starting a throwaway monero-wallet-rpc against $MONERO_DIR"
    podman run -d --rm --name "$SETUP_NAME" \
        --network npm-network \
        -v "$MONERO_DIR:/home/monero/wallet:z" \
        "$MONERO_IMAGE" \
        --wallet-dir=/home/monero/wallet \
        --disable-rpc-login \
        --rpc-bind-port="$SETUP_PORT" \
        --daemon-address=http://monerod:18089 --untrusted-daemon >/dev/null

    # shellcheck disable=SC2064
    trap "podman rm -f '$SETUP_NAME' >/dev/null 2>&1 || true" EXIT

    local deadline; deadline=$(( $(date +%s) + 60 ))
    # The wallet RPC answers `{"result":{...}}`; unlike the daemon's responses
    # it carries no "status":"OK", so probe for the result object.
    until monero_rpc '{"jsonrpc":"2.0","id":"0","method":"get_version"}' 2>/dev/null | grep -q '"result"'; do
        [ "$(date +%s)" -ge "$deadline" ] && { warn "the setup wallet-rpc did not come up"; return 1; }
        sleep 2
    done

    if [ "$choice" = "c" ] || [ "$choice" = "C" ]; then
        log "creating a new wallet"
        monero_rpc "$(printf '{"jsonrpc":"2.0","id":"0","method":"create_wallet","params":{"filename":"%s","password":"%s","language":"English"}}' "$MONERO_WALLET" "$pw")" >/dev/null
        echo
        echo "  Write this 25-word seed down NOW. It is the only way to restore this wallet:"
        echo
        seed=$(monero_rpc '{"jsonrpc":"2.0","id":"0","method":"query_key","params":{"key_type":"mnemonic"}}' \
            | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
        printf '    %s\n\n' "$seed"
        ask "Press Enter once you have written it down... " >/dev/null
    else
        echo
        echo "  Paste the 25-word seed (input is hidden; nothing is echoed or logged):"
        local seed; read -rs -p "  seed: " seed; echo
        local height; height=$(ask "  restore height (or 0 to scan from the beginning): ")
        [ -n "$height" ] || height=0
        log "restoring the wallet (this also rescans the chain)"
        monero_rpc "$(printf '{"jsonrpc":"2.0","id":"0","method":"restore_deterministic_wallet","params":{"filename":"%s","password":"%s","seed":"%s","restore_height":%s,"language":"English"}}' \
            "$MONERO_WALLET" "$pw" "$seed" "$height")" >/dev/null
        unset seed
    fi

    podman rm -f "$SETUP_NAME" >/dev/null 2>&1 || true
    trap - EXIT

    if [ -f "$MONERO_DIR/$MONERO_WALLET" ]; then
        log "Monero wallet ready: $MONERO_DIR/$MONERO_WALLET"
        systemctl --user restart monero-wallet-rpc.service 2>/dev/null || true
    else
        warn "the wallet file was not created; check: podman logs $SETUP_NAME"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Bitcoin
# ---------------------------------------------------------------------------
bitcoin_cli() { podman exec bitcoind bitcoin-cli -datadir=/data/.bitcoin "$@"; }

btc_wallet_loaded() {
    bitcoin_cli listwallets 2>/dev/null | grep -q "\"$BITCOIN_WALLET\""
}

# The wallet may live in the default wallets/ directory or, on a host that
# created it before that layout, at the datadir root (e.g. /data/.bitcoin/mainnet
# -- which is where this stack's older runs put it). listwalletdir does not
# always report the latter, so check the filesystem too.
btc_wallet_on_disk() {
    bitcoin_cli listwalletdir 2>/dev/null | grep -q "\"name\": \"$BITCOIN_WALLET\"" \
        || podman exec bitcoind test -f "/data/.bitcoin/$BITCOIN_WALLET/wallet.dat" 2>/dev/null \
        || podman exec bitcoind test -f "/data/.bitcoin/wallets/$BITCOIN_WALLET/wallet.dat" 2>/dev/null
}

# loadwallet <name> resolves against the wallet dir; an older datadir-root wallet
# needs its path. Try both, then prove it with listwallets.
load_bitcoin_wallet() {
    bitcoin_cli loadwallet "$BITCOIN_WALLET" >/dev/null 2>&1 || true
    btc_wallet_loaded && return 0
    bitcoin_cli loadwallet "/data/.bitcoin/$BITCOIN_WALLET" >/dev/null 2>&1 || true
    btc_wallet_loaded
}

setup_bitcoin() {
    command -v podman >/dev/null 2>&1 || die "podman is required"
    if ! podman ps --filter 'name=^bitcoind$' --format '{{.Status}}' 2>/dev/null | grep -q '^Up'; then
        warn "bitcoind is not running; start it first (./deploy.sh) and re-run --bitcoin"
        return 1
    fi

    # bitcoind serves chain RPC (getblockchaininfo) while it is still loading its
    # wallets, and deploy.sh's wallet step runs in exactly that window. Without
    # this wait, listwallets is empty and the script prompts to create a wallet
    # that already exists -- then createwallet fails with "Database already
    # exists".
    local deadline
    deadline=$(( $(date +%s) + ${BITCOIND_WALLET_WAIT:-120} ))
    until bitcoin_cli listwallets >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "bitcoind wallet RPC did not answer; start it first (./deploy.sh) and re-run --bitcoin"
            return 1
        fi
        sleep 2
    done

    if btc_wallet_loaded; then
        log "Bitcoin wallet '$BITCOIN_WALLET' already loaded (leaving it alone)"
        return 0
    fi
    if btc_wallet_on_disk; then
        log "Bitcoin wallet '$BITCOIN_WALLET' exists on disk; loading it"
        load_bitcoin_wallet || { warn "could not load the existing wallet '$BITCOIN_WALLET'"; return 1; }
        return 0
    fi

    echo
    log "No Bitcoin wallet '$BITCOIN_WALLET'."
    echo "    [c] create a new descriptor wallet"
    echo "    [r] restore from a wallet backup (.dat)"
    echo "    [s] skip"
    local choice; choice=$(ask "Choose [c/r/s]: ")
    case "$choice" in
        c|C)
            log "creating wallet '$BITCOIN_WALLET'"
            if ! bitcoin_cli -named createwallet wallet_name="$BITCOIN_WALLET" descriptors=true load_on_startup=true; then
                # A directory can exist without listwalletdir reporting it (the
                # older datadir-root layout). Load it rather than failing the
                # whole wallet step for a wallet that is already there.
                if load_bitcoin_wallet; then
                    log "loaded the existing wallet '$BITCOIN_WALLET'"
                else
                    warn "could not create or load wallet '$BITCOIN_WALLET'"
                    return 1
                fi
            fi
            ;;
        r|R)
            local path; path=$(ask "  path to the wallet backup .dat: ")
            [ -f "$path" ] || { warn "no such file: $path"; return 1; }
            log "copying the backup into the container"
            podman cp "$path" "bitcoind:/data/.bitcoin/restorewallet.dat"
            podman exec -u 0 bitcoind chown 1000:1000 /data/.bitcoin/restorewallet.dat >/dev/null 2>&1 || true
            log "restoring wallet '$BITCOIN_WALLET'"
            bitcoin_cli -named restorewallet wallet_name="$BITCOIN_WALLET" wallet_backup_file=/data/.bitcoin/restorewallet.dat
            podman exec bitcoind rm -f /data/.bitcoin/restorewallet.dat >/dev/null 2>&1 || true
            ;;
        *)
            log "skipping the Bitcoin wallet"
            return 0
            ;;
    esac
    if ! btc_wallet_loaded; then
        warn "Bitcoin wallet '$BITCOIN_WALLET' was not loaded; check: podman logs bitcoind"
        return 1
    fi
    log "Bitcoin wallet '$BITCOIN_WALLET' ready"
}

[ "$DO_MONERO" = 1 ] && setup_monero
[ "$DO_BITCOIN" = 1 ] && setup_bitcoin
exit 0
