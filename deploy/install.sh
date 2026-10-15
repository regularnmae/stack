#!/usr/bin/env bash
# Install the whole stack: every quadlet unit, every secret/env file, and the
# data directories the containers need.
#
# This is the **only** installer. The application repos (searxng-mcp and the
# four crypto MCP servers) ship code, tests, CI and their Containerfile; their
# units and env wiring live here, in one file, so a fix lands once instead of
# in five near-identical copies.
#
# Idempotent and non-destructive:
#   * an existing secret/env file is never overwritten (so re-running on a
#     running host changes no credential and no client token);
#   * secret resolution order is secrets.env -> the currently-installed unit
#     -> the daemon's own config -> generate, which is what makes adoption on
#     a running host a no-op;
#   * a pre-existing real unit file is backed up to <unit>.bak first.
#
# Nothing here prints a secret. The files land under ~/.config (mode 600) and
# ~/data (owned by the containers' uid).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deploy"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QUADLET_DIR="$CONFIG_HOME/containers/systemd"
DATA_DIR="${STACK_DATA_DIR:-$HOME/data}"
NPM_DIR="${STACK_NPM_DIR:-$HOME/npm}"

SECRETS_DIR="$CONFIG_HOME/stack"
SECRETS_FILE="$SECRETS_DIR/secrets.env"

TOR_IMAGE="localhost/tor:0.4.9.11-alpine3.20"
SEARXNG_DATA_DIR="${SEARXNG_DATA_DIR:-$DATA_DIR/searxng}"

# Secret-free units, symlinked verbatim into the quadlet search path.
STATIC_UNITS=(
    npm-network.network
    nginx-proxy-manager.container
    valkey.container
    searxng.container
    bitcoind.container
    monerod.container
    tor.container
    searxng-mcp.container
    bitcoin-node-mcp.container
    monero-node-mcp.container
    monero-wallet-mcp.container
    lightning-mcp.container
)

# Secret-bearing units, rendered from a template (Quadlet does not expand
# env vars in Exec=, so the secret has to be substituted into the unit).
RENDERED=(
    "lightningd.container.in:lightningd.container"
    "monero-wallet-rpc.container.in:monero-wallet-rpc.container"
)

# Method allowlists for the CLN runes (`method^<prefix>` is a prefix match).
# The read rune cannot name a payment method at all, so the node refuses a
# spend through it regardless of this server's own token gate.
READ_METHODS='"method^getinfo","method^listfunds","method^listchannels","method^listpeers","method^listinvoices","method^listpays","method^decode"'
SPEND_METHODS="$READ_METHODS,\"method^invoice\",\"method^pay\",\"method^keysend\",\"method^withdraw\",\"method^close\""

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

# Echo 0 (true) when the file is missing and the caller should write it, so a
# call site reads: if ensure_secret "$F" "token env"; then write_secret ...; fi
ensure_secret() {
    local path="$1" label="$2"
    if [ -s "$path" ]; then
        log "$label present: $path"
        return 1
    fi
    mkdir -p "$(dirname "$path")"
    return 0
}

# Echo the token a running container already has, else a fresh one. Notes go
# to stderr so they are not captured by $(...).
new_or_reused_token() {
    local container="$1" var="$2" val=""
    if command -v podman >/dev/null 2>&1; then
        val=$(podman exec "$container" printenv "$var" 2>/dev/null || true)
    fi
    if [ -n "$val" ]; then
        printf '==> reused %s from the running %s\n' "$var" "$container" >&2
    else
        printf '==> generated a new %s -- update clients to match\n' "$var" >&2
        val=$(rand_hex)
    fi
    printf '%s' "$val"
}

# Hand paths to the image's in-container uid 1000 (host subuid, 525287 here).
# bitcoind and monero-wallet-rpc run as that user and do NOT re-own their bind
# mounts, so a fresh host has to do it or they cannot write.
chown_image_uid() {
    command -v podman >/dev/null 2>&1 || return 0
    podman unshare chown -R 1000:1000 "$@" 2>/dev/null \
        || log "could not chown $* -- run: podman unshare chown -R 1000:1000 $*"
}

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

flag_value() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    awk -v n="--$name=" '
        index($0, n) { v = substr($0, index($0, n) + length(n)); sub(/[[:space:]\\]+$/, "", v); print v; exit }
    ' "$file"
}

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

# ---------------------------------------------------------------------------
# 0. legacy migration + directories
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_HOME" "$QUADLET_DIR" "$DATA_DIR" "$NPM_DIR/data" "$NPM_DIR/letsencrypt"
mkdir -p "$DATA_DIR/monero" "$DATA_DIR/cln" "$DATA_DIR/tor"

# A host that ran the stack before the crypto-nodes -> stack rename keeps its
# secrets under the old name.
if [ ! -s "$SECRETS_FILE" ] && [ -s "$CONFIG_HOME/crypto-nodes/secrets.env" ]; then
    mkdir -p "$SECRETS_DIR"
    cp -p "$CONFIG_HOME/crypto-nodes/secrets.env" "$SECRETS_FILE"
    log "migrated crypto-nodes/secrets.env -> stack/secrets.env"
fi

# ---------------------------------------------------------------------------
# 1. resolve the node secrets (reuse > installed unit > daemon config > new)
# ---------------------------------------------------------------------------
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

if ensure_secret "$SECRETS_FILE" "secrets"; then
    write_secret "$SECRETS_FILE" <<EOF
# Secrets for the whole stack. Written by deploy/install.sh (mode 600), seeded
# from the previously-installed units where possible so adopting it changes no
# credential. Never committed.
BITCOIN_RPC_USER=$BITCOIN_RPC_USER
BITCOIN_RPC_PASSWORD=$BITCOIN_RPC_PASSWORD
TOR_SERVICE_PASSWORD=$TOR_SERVICE_PASSWORD
MONERO_WALLET_PASSWORD=$MONERO_WALLET_PASSWORD
MONERO_RPC_LOGIN=$MONERO_RPC_LOGIN
EOF
    log "wrote $SECRETS_FILE (mode 600)"
fi

# ---------------------------------------------------------------------------
# 2. bitcoind config + ownership (fresh host)
# ---------------------------------------------------------------------------
if [ ! -s "$DATA_DIR/bitcoin/bitcoin.conf" ]; then
    mkdir -p "$DATA_DIR/bitcoin"
    write_secret "$DATA_DIR/bitcoin/bitcoin.conf" <<EOF
# bitcoind configuration, seeded once by deploy/install.sh and handed to the
# image's uid. It carries the RPC credentials the MCP server and lightningd
# use. Edit it through the container:
#   podman exec -it bitcoind vi /data/.bitcoin/bitcoin.conf
server=1
daemon=0

# Rolling prune keeps the node small. Incompatible with -txindex.
prune=20000
txindex=0

# RPC. rpcallowip is the podman subnet only, so a re-added PublishPort would
# still be refused: a request via a host port arrives from the LAN address.
rpcuser=$BITCOIN_RPC_USER
rpcpassword=$BITCOIN_RPC_PASSWORD
rpcbind=0.0.0.0
rpcallowip=127.0.0.1
rpcallowip=10.89.0.0/24

# Outbound-only: no inbound P2P peers.
listen=0
EOF
    log "seeded $DATA_DIR/bitcoin/bitcoin.conf"
    chown_image_uid "$DATA_DIR/bitcoin" "$DATA_DIR/bitcoin/bitcoin.conf"
fi

# monero-wallet-rpc's image does not re-own its bind mount; create it for the
# image uid so the wallet-rpc can write the wallet once it is restored.
if [ ! -d "$DATA_DIR/monero-wallet-rpc" ]; then
    mkdir -p "$DATA_DIR/monero-wallet-rpc"
    chown_image_uid "$DATA_DIR/monero-wallet-rpc"
fi

# ---------------------------------------------------------------------------
# 3. tor image + torrc
# ---------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1 && ! podman image exists "$TOR_IMAGE" 2>/dev/null; then
    if [ -f "$REPO_DIR/tor/Containerfile" ]; then
        log "building $TOR_IMAGE"
        podman build -t "$TOR_IMAGE" "$REPO_DIR/tor/" >/dev/null
    fi
fi

if [ -s "$DATA_DIR/tor/torrc" ]; then
    log "keeping existing $DATA_DIR/tor/torrc"
else
    mkdir -p "$DATA_DIR/tor"
    hash=""
    if command -v podman >/dev/null 2>&1 && podman image exists "$TOR_IMAGE" 2>/dev/null; then
        hash=$(podman run --rm "$TOR_IMAGE" tor --hash-password "$TOR_SERVICE_PASSWORD" 2>/dev/null | head -n1 || true)
    fi
    if [ -n "$hash" ]; then
        cat > "$DATA_DIR/tor/torrc" <<EOF
SocksPort 0.0.0.0:9050
ControlPort 0.0.0.0:9051

HashedControlPassword $hash

# Only containers on the podman npm-network may use the SOCKS proxy.
SocksPolicy accept 10.89.0.0/24
SocksPolicy reject *

Log notice stdout
EOF
        log "seeded $DATA_DIR/tor/torrc with a control-password hash"
    else
        log "could not seed $DATA_DIR/tor/torrc (tor image '$TOR_IMAGE' not built?) -- re-run after the build"
    fi
fi

# ---------------------------------------------------------------------------
# 4. SearXNG config (seed only; never clobber a live file)
# ---------------------------------------------------------------------------
mkdir -p "$SEARXNG_DATA_DIR"
if [ -s "$SEARXNG_DATA_DIR/settings.yml" ]; then
    log "keeping existing $SEARXNG_DATA_DIR/settings.yml"
else
    secret=$(rand_hex)
    log "seeding $SEARXNG_DATA_DIR/settings.yml with a fresh secret_key"
    sed "s/^  secret_key: .*/  secret_key: \"${secret}\"/" \
        "$DEPLOY_DIR/searxng/settings.yml" > "$SEARXNG_DATA_DIR/settings.yml"
    chmod 600 "$SEARXNG_DATA_DIR/settings.yml"
fi
if [ -s "$SEARXNG_DATA_DIR/limiter.toml" ]; then
    log "keeping existing $SEARXNG_DATA_DIR/limiter.toml"
else
    log "seeding $SEARXNG_DATA_DIR/limiter.toml"
    cp "$DEPLOY_DIR/searxng/limiter.toml" "$SEARXNG_DATA_DIR/limiter.toml"
fi

# ---------------------------------------------------------------------------
# 5. per-application env files
# ---------------------------------------------------------------------------

# searxng-mcp -- a single bearer token.
SEARXNG_ENV="$CONFIG_HOME/searxng-mcp/token.env"
if ensure_secret "$SEARXNG_ENV" "searxng-mcp token env"; then
    token=$(new_or_reused_token searxng-mcp SEARXNG_MCP_TOKEN)
    write_secret "$SEARXNG_ENV" <<EOF
SEARXNG_MCP_TOKEN=$token
EOF
    log "wrote $SEARXNG_ENV (mode 600)"
fi

# bitcoin-node-mcp -- token + bitcoind RPC credentials (already resolved).
BTC_ENV="$CONFIG_HOME/bitcoin-node-mcp"
if ensure_secret "$BTC_ENV/token.env" "bitcoin-node-mcp token env"; then
    token=$(new_or_reused_token bitcoin-node-mcp BITCOIN_MCP_TOKEN)
    write_secret "$BTC_ENV/token.env" <<EOF
BITCOIN_MCP_TOKEN=$token
EOF
    log "wrote $BTC_ENV/token.env (mode 600)"
fi
if ensure_secret "$BTC_ENV/upstream.env" "bitcoin-node-mcp upstream env"; then
    write_secret "$BTC_ENV/upstream.env" <<EOF
# Upstream credentials for the Bitcoin Core node this server reads. Derived
# from the node secrets; the unit reads this via EnvironmentFile.
BITCOIN_RPC_USER=$BITCOIN_RPC_USER
BITCOIN_RPC_PASSWORD=$BITCOIN_RPC_PASSWORD
EOF
    log "wrote $BTC_ENV/upstream.env (mode 600)"
fi

# monero-node-mcp -- token + (usually empty) restricted-RPC credentials.
XMR_ENV="$CONFIG_HOME/monero-node-mcp"
if ensure_secret "$XMR_ENV/token.env" "monero-node-mcp token env"; then
    token=$(new_or_reused_token monero-node-mcp MONERO_MCP_TOKEN)
    write_secret "$XMR_ENV/token.env" <<EOF
MONERO_MCP_TOKEN=$token
EOF
    log "wrote $XMR_ENV/token.env (mode 600)"
fi
if ensure_secret "$XMR_ENV/upstream.env" "monero-node-mcp upstream env"; then
    write_secret "$XMR_ENV/upstream.env" <<EOF
# Empty unless monerod was started with --rpc-login. The unit reads this via
# EnvironmentFile.
MONERO_RPC_USER=
MONERO_RPC_PASSWORD=
EOF
    log "wrote $XMR_ENV/upstream.env (mode 600)"
fi

# monero-wallet-mcp -- read+spend tokens, the wallet RPC login, spend policy.
XMRW_ENV="$CONFIG_HOME/monero-wallet-mcp"
if ensure_secret "$XMRW_ENV/token.env" "monero-wallet-mcp token env"; then
    read_token=$(new_or_reused_token monero-wallet-mcp MONERO_MCP_TOKEN)
    write_secret "$XMRW_ENV/token.env" <<EOF
# Read token: admits the endpoint, cannot call spend tools.
MONERO_MCP_TOKEN=$read_token
# Spend token: additionally required for transfer / sweep_all / create_address.
MONERO_MCP_SPEND_TOKEN=$(rand_hex)
EOF
    log "wrote $XMRW_ENV/token.env (mode 600) with a read and a spend token"
fi
if ensure_secret "$XMRW_ENV/upstream.env" "monero-wallet-mcp upstream env"; then
    write_secret "$XMRW_ENV/upstream.env" <<EOF
# Upstream credentials for monero-wallet-rpc (--rpc-login), split out of the
# resolved wallet login.
MONERO_WALLET_RPC_USER=${MONERO_RPC_LOGIN%%:*}
MONERO_WALLET_RPC_PASSWORD=${MONERO_RPC_LOGIN#*:}
EOF
    log "wrote $XMRW_ENV/upstream.env (mode 600)"
fi
if ensure_secret "$XMRW_ENV/spend.env" "monero-wallet-mcp spend env"; then
    write_secret "$XMRW_ENV/spend.env" <<EOF
# Spending is OFF until you set ENABLE_SPENDING=1. With it on, both caps below
# must be positive (in XMR) or the server refuses to start. MAINNET: real money.
ENABLE_SPENDING=0
MAX_SPEND_PER_CALL=1
MAX_SPEND_PER_DAY=5
# Optional comma-separated destination allowlist; empty allows any address.
ALLOWED_DESTINATIONS=
EOF
    log "wrote $XMRW_ENV/spend.env (mode 600) with ENABLE_SPENDING=0"
fi

# lightning-mcp -- read+spend tokens, runes + TLS, spend policy.
LN_ENV="$CONFIG_HOME/lightning-mcp"
if ensure_secret "$LN_ENV/token.env" "lightning-mcp token env"; then
    read_token=$(new_or_reused_token lightning-mcp LIGHTNING_MCP_TOKEN)
    write_secret "$LN_ENV/token.env" <<EOF
# Read token: admits the endpoint, cannot call spend tools.
LIGHTNING_MCP_TOKEN=$read_token
# Spend token: additionally required for invoice / pay / keysend / withdraw / close.
LIGHTNING_MCP_SPEND_TOKEN=$(rand_hex)
EOF
    log "wrote $LN_ENV/token.env (mode 600) with a read and a spend token"
fi
if ensure_secret "$LN_ENV/spend.env" "lightning-mcp spend env"; then
    write_secret "$LN_ENV/spend.env" <<EOF
# Spending (payments) is OFF until you set ENABLE_SPENDING=1. With it on, both
# caps below must be positive (in satoshis) or the server refuses to start.
# MAINNET: this is real money.
ENABLE_SPENDING=0
MAX_PAYMENT_PER_CALL_SATS=10000
MAX_PAYMENT_PER_DAY_SATS=100000
EOF
    log "wrote $LN_ENV/spend.env (mode 600) with ENABLE_SPENDING=0"
fi

# The runes need a running lightningd. install.sh is re-run by deploy.sh once
# the daemon is up, so this is best-effort here and self-heals on re-run.
rune_usable() {
    [ -n "$1" ] || return 1
    podman exec lightningd lightning-cli -k checkrune rune="$1" method=getinfo \
        >/dev/null 2>&1
}

create_rune() {
    local restrictions="$1" rune=""
    for _ in $(seq 1 12); do
        rune=$(podman exec lightningd lightning-cli createrune null "$restrictions" 2>/dev/null \
            | grep -o '"rune": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
        [ -n "$rune" ] || return 0
        if rune_usable "$rune"; then
            printf '%s' "$rune"
            return 0
        fi
        printf '==> created rune %s... was refused (blacklisted id?); retrying\n' \
            "${rune:0:8}" >&2
    done
    printf '%s' "$rune"
}

read_rune=""
spend_rune=""
tls_insecure=""
ca_cert=""
if [ -s "$LN_ENV/node.env" ]; then
    read_rune=$(sed -n 's/^LIGHTNING_RUNE=//p' "$LN_ENV/node.env" | head -n1)
    spend_rune=$(sed -n 's/^LIGHTNING_SPEND_RUNE=//p' "$LN_ENV/node.env" | head -n1)
    tls_insecure=$(sed -n 's/^LIGHTNING_TLS_INSECURE=//p' "$LN_ENV/node.env" | head -n1)
    ca_cert=$(sed -n 's/^LIGHTNING_CA_CERT=//p' "$LN_ENV/node.env" | head -n1)
fi

# Re-running is a no-op only while the stored runes are usable. A rune can be
# silently unusable -- a blacklisted unique_id, which the first deploy of
# lightning-mcp hit -- so check rather than trust the file. If the node is
# unreachable nothing is refreshed and any existing values are kept.
node_needs_write=0
[ -s "$LN_ENV/node.env" ] || node_needs_write=1
if command -v podman >/dev/null 2>&1 \
    && ! { rune_usable "$read_rune" && rune_usable "$spend_rune"; }; then
    if podman exec lightningd lightning-cli getinfo >/dev/null 2>&1; then
        log "creating runes on the node"
        new_read=$(create_rune "[[$READ_METHODS]]")
        new_spend=$(create_rune "[[$SPEND_METHODS]]")
        if [ -n "$new_read" ] && [ -n "$new_spend" ]; then
            read_rune="$new_read"
            spend_rune="$new_spend"
            node_needs_write=1
            log "created a usable read rune and a read+spend rune"
        fi
    else
        log "lightningd not reachable yet; runes will be created by a later install.sh run"
    fi
fi

if [ "$node_needs_write" = 1 ]; then
    if [ -n "$read_rune" ]; then
        log "runes ready"
    else
        log "no runes available yet; fill in $LN_ENV/node.env by hand if this persists"
    fi
    [ -n "$tls_insecure" ] || tls_insecure=1
    write_secret "$LN_ENV/node.env" <<EOF
# Runes created by deploy/install.sh. The read rune names only read methods;
# the spend rune adds the payment methods. The server uses the spend rune only
# for spend tools.
LIGHTNING_RUNE=$read_rune
LIGHTNING_SPEND_RUNE=$spend_rune
# clnrest serves a self-signed certificate. 1 skips verification, which is
# acceptable over the podman network; set LIGHTNING_CA_CERT to the node's
# cert.pem and this to 0 for a stricter setup.
LIGHTNING_TLS_INSECURE=$tls_insecure
EOF
    if [ -n "$ca_cert" ]; then
        printf 'LIGHTNING_CA_CERT=%s\n' "$ca_cert" >> "$LN_ENV/node.env"
    fi
    log "wrote $LN_ENV/node.env (mode 600)"
fi

# ---------------------------------------------------------------------------
# 6. units
# ---------------------------------------------------------------------------
for unit in "${STATIC_UNITS[@]}"; do
    target="$QUADLET_DIR/$unit"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        mv -f "$target" "$target.bak"
        log "backed up existing $unit -> $unit.bak"
    fi
    ln -sfn "$DEPLOY_DIR/$unit" "$target"
done
log "linked ${#STATIC_UNITS[@]} static units"

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

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    log "systemd --user reloaded"
fi

cat <<EOF

Done. Units are installed and env files are seeded under:
  $CONFIG_HOME/{stack,searxng-mcp,bitcoin-node-mcp,monero-node-mcp,monero-wallet-mcp,lightning-mcp}/
  $DATA_DIR/{bitcoin,monero,monero-wallet-rpc,cln,tor,searxng}/
  $NPM_DIR/{data,letsencrypt}/

Next:  ./deploy.sh         # build images, start everything, open firewalld, verify
Spending is OFF on both money servers until you set ENABLE_SPENDING=1 in
  $CONFIG_HOME/monero-wallet-mcp/spend.env  and  $CONFIG_HOME/lightning-mcp/spend.env
EOF
