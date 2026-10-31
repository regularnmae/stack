#!/usr/bin/env bash
# Create or restore the Bitcoin Core wallet this stack needs.
#
#   scripts/wallets.sh [--bitcoin]
#
# Uses bitcoin-cli in the running bitcoind container. The BTCPay Monero wallet
# is a different thing: it is view-only and imported by scripts/btcpay-wallet.sh
# from an address + private view key, never from a seed.
#
# Interactive; skipped when there is no TTY. Nothing is destroyed: an existing
# wallet is never overwritten.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The secrets live under the configured data dir ($DATA_DIR/config) now, so we
# resolve that dir the same way deploy.sh/verify.sh do: stack.conf ->
# data-dir.env -> prompt/default -> $HOME/data. deploy.sh exports
# STACK_DATA_DIR, so an invoked run never re-prompts. The resolution happens
# after the TTY check below, so --help and the no-TTY skip stay side-effect free.
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

BITCOIN_WALLET="mainnet"

DO_BITCOIN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --bitcoin) DO_BITCOIN=1 ;;
        -h|--help) usage_header "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
[ "$DO_BITCOIN" = 1 ] || DO_BITCOIN=1

if [ ! -t 0 ]; then
    log "no TTY; skipping interactive wallet setup"
    exit 0
fi

resolve_data_dir

ask() { local p="$1" a; read -r -p "$p" a; printf '%s' "$a"; }

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
# needs its path. Try both, then prove it with listwallets. "Already loaded" is
# success, not failure: loadwallet answers -35 for it, and reporting that as a
# broken wallet is what made a healthy node look unconfigured here.
load_bitcoin_wallet() {
    local err=""
    btc_wallet_loaded && return 0
    err=$(bitcoin_cli loadwallet "$BITCOIN_WALLET" 2>&1) || true
    btc_wallet_loaded && return 0
    err=$(bitcoin_cli loadwallet "/data/.bitcoin/$BITCOIN_WALLET" 2>&1) || true
    btc_wallet_loaded && return 0
    warn "loadwallet '$BITCOIN_WALLET': ${err:-no output}"
    warn "loaded wallets: $(bitcoin_cli listwallets 2>/dev/null | tr -d ' \n')"
    return 1
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

[ "$DO_BITCOIN" = 1 ] && setup_bitcoin
exit 0
