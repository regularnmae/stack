#!/usr/bin/env bash
# Install the quadlet units for the crypto node stack (bitcoind, monerod,
# tor, lightningd, monero-wallet-rpc).
#
# One owner for the node config, so a fresh checkout can rebuild the stack.
# The committed files carry NO secrets. Two different mechanisms, for a reason:
#
#   * bitcoind, monerod and tor are secret-free and are symlinked.
#   * lightningd and monero-wallet-rpc need their secrets as arguments, and
#     Quadlet does not expand environment variables in Exec=, so install.sh
#     renders them from a `.container.in` template with the secrets
#     substituted. The rendered unit is mode 600 and never enters git. (A
#     daemon config file would be an alternative for lightningd, but the
#     monero-wallet-rpc image forces its bind address based on whether
#     `--rpc-login` is on the command line, so the secret has to be there.)
#
# install.sh reuses the values the previously-installed units carried, so
# adopting it on a running host changes no credential. It is idempotent and
# never clobbers an existing secret.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deploy"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QUADLET_DIR="$CONFIG_HOME/containers/systemd"
ENV_DIR="$CONFIG_HOME/crypto-nodes"
SECRETS_FILE="$ENV_DIR/secrets.env"

DATA_DIR="${CRYPTO_NODES_DATA_DIR:-$HOME/data}"
TOR_DIR="$DATA_DIR/tor"
TOR_IMAGE="localhost/tor:0.4.9.11-alpine3.20"

# Secret-free units: symlinked.
UNITS=(bitcoind.container monerod.container tor.container)

# Secret-bearing units: rendered from these templates into the quadlet dir.
# Pairs are "template:target".
RENDERED=(
    "lightningd.container.in:lightningd.container"
    "monero-wallet-rpc.container.in:monero-wallet-rpc.container"
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

# Escape a value for a sed replacement (delimiter is |).
esc() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }

first_nonempty() {
    local v
    for v in "$@"; do
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
}

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

# A key=value from bitcoind's own config (via the container, as the file is
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

# Render a .container.in into the quadlet dir, mode 600. Replaces a symlink
# first so the write can never follow one back into the repo.
render_unit() {
    local template="$1" target="$2" tmp
    tmp="$(mktemp)"
    sed -e "s|@BITCOIN_RPC_USER@|$(esc "$BITCOIN_RPC_USER")|g" \
        -e "s|@BITCOIN_RPC_PASSWORD@|$(esc "$BITCOIN_RPC_PASSWORD")|g" \
        -e "s|@TOR_SERVICE_PASSWORD@|$(esc "$TOR_SERVICE_PASSWORD")|g" \
        -e "s|@MONERO_WALLET_PASSWORD@|$(esc "$MONERO_WALLET_PASSWORD")|g" \
        -e "s|@MONERO_RPC_LOGIN@|$(esc "$MONERO_RPC_LOGIN")|g" \
        "$template" > "$tmp"
    [ -L "$target" ] && rm -f "$target"
    install -m 600 "$tmp" "$target"
    rm -f "$tmp"
}

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

# --- 2. torrc (fresh hosts only; its control password must match) -----------
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

# --- 3. install units into the quadlet search path --------------------------
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

for pair in "${RENDERED[@]}"; do
    template="${pair%%:*}"
    unit="${pair##*:}"
    target="$QUADLET_DIR/$unit"
    if [ -e "$target" ] && [ ! -L "$target" ] && [ ! -e "$target.bak" ]; then
        mv -f "$target" "$target.bak"
        log "backed up existing $unit -> $unit.bak"
    fi
    render_unit "$DEPLOY_DIR/$template" "$target"
    log "rendered $unit (mode 600)"
done

# --- 4. reload systemd so the generator re-reads the units ------------------
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    log "systemd --user reloaded"
fi

cat <<EOF

Done. Adopting new units on a running host needs a restart of the units whose
Exec changed (lightningd and monero-wallet-rpc):

  systemctl --user restart lightningd.service monero-wallet-rpc.service

Verify with:
  podman exec lightningd lightning-cli getinfo | head -5
  podman exec monero-wallet-rpc /healthcheck.sh && echo wallet-rpc healthy

Secrets live in $SECRETS_FILE (mode 600) and in the two rendered units
(mode 600) beside their siblings in $QUADLET_DIR. Roll back a unit from its
.bak there.
EOF
