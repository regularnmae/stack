#!/usr/bin/env bash
# Install the quadlet units for the crypto node stack (bitcoind, monerod,
# tor, lightningd, monero-wallet-rpc).
#
# One owner for the node config, so a fresh checkout can rebuild the stack.
# The committed units carry NO secrets: Quadlet does not expand environment
# variables in Exec=, so the secrets the daemons need live in config files
# they read themselves (bitcoin.conf, ~/data/cln/config,
# ~/data/monero-wallet-rpc/wallet.conf, ~/data/tor/torrc), all outside the
# repo. This script seeds those files, reusing the values the
# previously-installed units carried so adopting it on a running host changes
# no secret, then symlinks the units into the quadlet directory.
#
# Idempotent: re-running refreshes the symlinks and never clobbers an
# existing secret or config file.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deploy"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QUADLET_DIR="$CONFIG_HOME/containers/systemd"
ENV_DIR="$CONFIG_HOME/crypto-nodes"
SECRETS_FILE="$ENV_DIR/secrets.env"

DATA_DIR="${CRYPTO_NODES_DATA_DIR:-$HOME/data}"
CLN_DIR="$DATA_DIR/cln"
WALLET_DIR="$DATA_DIR/monero-wallet-rpc"
TOR_DIR="$DATA_DIR/tor"

MONERO_WALLET_IMAGE="ghcr.io/sethforprivacy/simple-monero-wallet-rpc:latest"
TOR_IMAGE="localhost/tor:0.4.9.11-alpine3.20"

# Every unit this repo owns. All are secret-free and symlinked.
UNITS=(
    bitcoind.container
    monerod.container
    tor.container
    lightningd.container
    monero-wallet-rpc.container
)

log() { printf '==> %s\n' "$*"; }

rand_hex() {
    openssl rand -hex 32 2>/dev/null && return 0
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

write_secret() {
    local path="$1"
    local old_umask
    old_umask=$(umask)
    umask 077
    cat > "$path"
    umask "$old_umask"
    chmod 600 "$path"
}

# First non-empty argument wins.
first_nonempty() {
    local v
    for v in "$@"; do
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
}

# A value already in secrets.env (so re-runs are stable).
read_secret() {
    [ -s "$SECRETS_FILE" ] || return 0
    sed -n "s/^$1=//p" "$SECRETS_FILE" | head -n1
}

# A --flag=value from a unit file (strips the trailing line continuation).
flag_value() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    awk -v n="--$name=" '
        index($0, n) { v = substr($0, index($0, n) + length(n)); sub(/[[:space:]\\]+$/, "", v); print v; exit }
    ' "$file"
}

# A key=value from bitcoind's own config (via the container, since the file is
# owned by the image's uid on the host).
bitcoin_conf_value() {
    local key="$1" v=""
    if command -v podman >/dev/null 2>&1; then
        v=$(podman exec bitcoind sh -c "grep -E '^$key=' /data/.bitcoin/bitcoin.conf" 2>/dev/null \
            | head -n1 | cut -d= -f2- || true)
    fi
    if [ -z "$v" ]; then
        v=$(sed -n "s/^$key=//p" "$DATA_DIR/bitcoin/bitcoin.conf" 2>/dev/null | head -n1 || true)
    fi
    printf '%s' "$v"
}

# Write a file inside a data dir owned by the image's uid, by doing it from a
# container so the ownership is right. Uses the running container when there
# is one, otherwise a throwaway.
mkdir -p "$ENV_DIR" "$DATA_DIR"

# --- 1. resolve secrets (reuse > previous unit > daemon config > generate) --
BITCOIN_RPC_USER=$(first_nonempty \
    "$(read_secret BITCOIN_RPC_USER)" \
    "$(flag_value "$QUADLET_DIR/lightningd.container" bitcoin-rpcuser)" \
    "$(bitcoin_conf_value rpcuser)" \
    "btcuser")
BITCOIN_RPC_PASSWORD=$(first_nonempty \
    "$(read_secret BITCOIN_RPC_PASSWORD)" \
    "$(flag_value "$QUADLET_DIR/lightningd.container" bitcoin-rpcpassword)" \
    "$(bitcoin_conf_value rpcpassword)" \
    "$(rand_hex)")
TOR_SERVICE_PASSWORD=$(first_nonempty \
    "$(read_secret TOR_SERVICE_PASSWORD)" \
    "$(flag_value "$QUADLET_DIR/lightningd.container" tor-service-password)" \
    "$(rand_hex)")
MONERO_WALLET_PASSWORD=$(first_nonempty \
    "$(read_secret MONERO_WALLET_PASSWORD)" \
    "$(flag_value "$QUADLET_DIR/monero-wallet-rpc.container" password)" \
    "$(rand_hex)")
MONERO_RPC_LOGIN=$(first_nonempty \
    "$(read_secret MONERO_RPC_LOGIN)" \
    "$(flag_value "$QUADLET_DIR/monero-wallet-rpc.container" rpc-login)" \
    "monero:$(rand_hex)")

if [ -s "$SECRETS_FILE" ]; then
    log "secrets present: $SECRETS_FILE"
else
    write_secret "$SECRETS_FILE" <<EOF
# Secrets for the crypto node stack. Written by deploy/install.sh (mode 600),
# seeded from the previously-installed units where possible so adopting it
# changes no credential. Never committed.
BITCOIN_RPC_USER=$BITCOIN_RPC_USER
BITCOIN_RPC_PASSWORD=$BITCOIN_RPC_PASSWORD
TOR_SERVICE_PASSWORD=$TOR_SERVICE_PASSWORD
MONERO_WALLET_PASSWORD=$MONERO_WALLET_PASSWORD
MONERO_RPC_LOGIN=$MONERO_RPC_LOGIN
EOF
    log "wrote $SECRETS_FILE (mode 600)"
fi

# --- 2. CLN config (~/data/cln/config, read by lightningd at startup) -------
mkdir -p "$CLN_DIR"
if [ -s "$CLN_DIR/config" ]; then
    log "keeping existing $CLN_DIR/config"
else
    write_secret "$CLN_DIR/config" <<EOF
# Managed by crypto-nodes/deploy/install.sh. lightningd reads this at startup
# (default path \$LIGHTNINGDIR/config). The two secrets below are why the
# lightningd unit no longer carries them on its Exec line.
bitcoin-rpcuser=$BITCOIN_RPC_USER
bitcoin-rpcpassword=$BITCOIN_RPC_PASSWORD
tor-service-password=$TOR_SERVICE_PASSWORD
EOF
    log "seeded $CLN_DIR/config (mode 600)"
fi

# --- 3. monero-wallet-rpc config (in a dir owned by the image's uid) --------
seed_wallet_conf() {
    local body="$1"
    if command -v podman >/dev/null 2>&1 \
        && [ "$(podman inspect -f '{{.State.Running}}' monero-wallet-rpc 2>/dev/null || echo false)" = "true" ]; then
        printf '%s' "$body" | podman exec -i monero-wallet-rpc sh -c \
            'cat > /home/monero/wallet/wallet.conf && chown monero:monero /home/monero/wallet/wallet.conf && chmod 600 /home/monero/wallet/wallet.conf'
        return 0
    fi
    mkdir -p "$WALLET_DIR"
    if command -v podman >/dev/null 2>&1; then
        podman unshare chown 1000:1000 "$WALLET_DIR" 2>/dev/null || true
        printf '%s' "$body" | podman run --rm -i --entrypoint sh \
            -v "$WALLET_DIR:/home/monero/wallet:z" "$MONERO_WALLET_IMAGE" -c \
            'cat > /home/monero/wallet/wallet.conf && chown monero:monero /home/monero/wallet/wallet.conf && chmod 600 /home/monero/wallet/wallet.conf'
    else
        log "podman not available; cannot seed $WALLET_DIR/wallet.conf"
    fi
}

if [ -f "$WALLET_DIR/wallet.conf" ]; then
    log "keeping existing $WALLET_DIR/wallet.conf"
else
    seed_wallet_conf "# Managed by crypto-nodes/deploy/install.sh. The two secrets
# below are why the monero-wallet-rpc unit no longer carries them on its
# Exec line.
password=$MONERO_WALLET_PASSWORD
rpc-login=$MONERO_RPC_LOGIN
"
    log "seeded $WALLET_DIR/wallet.conf (mode 600)"
fi

# --- 4. torrc (fresh hosts only; its control password must match) -----------
if [ -s "$TOR_DIR/torrc" ]; then
    log "keeping existing $TOR_DIR/torrc"
else
    mkdir -p "$TOR_DIR"
    hash=""
    if command -v podman >/dev/null 2>&1 && podman image exists "$TOR_IMAGE" 2>/dev/null; then
        hash=$(podman run --rm "$TOR_IMAGE" tor --hash-password "$TOR_SERVICE_PASSWORD" 2>/dev/null | head -n1 || true)
    fi
    if [ -n "$hash" ]; then
        cat > "$TOR_DIR/torrc" <<EOF
SocksPort 0.0.0.0:9050
ControlPort 0.0.0.0:9051

HashedControlPassword $hash

# Only containers on the podman npm-network may use the SOCKS proxy.
SocksPolicy accept 10.89.0.0/24
SocksPolicy reject *

Log notice stdout
EOF
        log "seeded $TOR_DIR/torrc with a control-password hash"
    else
        log "could not seed $TOR_DIR/torrc (tor image '$TOR_IMAGE' not built?)"
    fi
fi

# --- 5. symlink units into the quadlet search path --------------------------
mkdir -p "$QUADLET_DIR"

NETWORK_TARGET="$QUADLET_DIR/npm-network.network"
if [ ! -e "$NETWORK_TARGET" ]; then
    ln -sfn "$DEPLOY_DIR/npm-network.network" "$NETWORK_TARGET"
    log "linked npm-network.network"
else
    log "npm-network.network already present"
fi

for unit in "${UNITS[@]}"; do
    target="$QUADLET_DIR/$unit"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        mv -f "$target" "$target.bak"
        log "backed up existing $unit -> $unit.bak"
    fi
    ln -sfn "$DEPLOY_DIR/$unit" "$target"
    log "linked $unit"
done

# --- 6. reload systemd so the generator re-reads the units ------------------
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    log "systemd --user reloaded"
fi

cat <<EOF

Done. Adopting new units on a running host needs a restart of each unit whose
Exec changed (lightningd and monero-wallet-rpc moved their secrets to config):

  systemctl --user restart bitcoind.service monerod.service tor.service
  systemctl --user restart lightningd.service monero-wallet-rpc.service

Verify with:
  podman exec lightningd lightning-cli getinfo | head -5
  podman exec monero-wallet-rpc /healthcheck.sh && echo wallet-rpc healthy

Secrets live in $SECRETS_FILE (mode 600). Roll back a unit from its
.bak beside it in $QUADLET_DIR.
EOF
