#!/usr/bin/env bash
# Install the whole stack: every quadlet unit, every secret/env file, and the
# data directories the containers need.
#
# This is the **only** installer. The application repos (searxng-mcp and the
# four crypto MCP servers) ship code, tests, CI and their Containerfile; their
# units and env wiring live here.
#
# EVERYTHING persistent lives under one data dir ($STACK_DATA_DIR, default
# $HOME/data): the daemon data, the nginx-proxy-manager data, and the
# config/secrets. Point it at a separate disk and a rebuild only has to keep
# that one directory.
#
# Idempotent and non-destructive: an existing secret/env file is never
# overwritten, secret resolution order is secrets.env -> the installed unit ->
# the daemon's own config -> generate, and a pre-existing real unit is backed
# up to <unit>.bak. Nothing here prints a secret.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deploy"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QUADLET_DIR="$CONFIG_HOME/containers/systemd"
# Plain systemd user units live here, not in the quadlet dir: Quadlet generates
# .service files from .container/.volume/.network/... but has no .timer type,
# and the health monitor is a host script rather than a container. backup.timer,
# monitor.timer and monitor.service are installed as ordinary user units.
USER_UNIT_DIR="$CONFIG_HOME/systemd/user"

# shellcheck source=../scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# Where the backup job keeps its restic repository (mounted at /repo). Defined
# in stack.conf; default here so install.sh works standalone too.
STACK_BACKUP_DIR="${STACK_BACKUP_DIR:-$HOME/data-backup}"
export STACK_BACKUP_DIR

# Every unit is rendered: all of them reference either the data dir or the
# config dir, so none is a plain symlink any more. Pairs are "source:target".
UNITS=(
    "npm-network.network:npm-network.network"
    "nginx-proxy-manager.container:nginx-proxy-manager.container"
    "valkey.container:valkey.container"
    "searxng.container:searxng.container"
    "bitcoind.container:bitcoind.container"
    "monerod.container:monerod.container"
    "tor.container:tor.container"
    "lightningd.container.in:lightningd.container"
    "monero-wallet-rpc.container.in:monero-wallet-rpc.container"
    "searxng-mcp.container:searxng-mcp.container"
    "bitcoin-node-mcp.container:bitcoin-node-mcp.container"
    "monero-node-mcp.container:monero-node-mcp.container"
    "monero-wallet-mcp.container:monero-wallet-mcp.container"
    "lightning-mcp.container:lightning-mcp.container"
    "backup.container:backup.container"
)

# Plain systemd user units (installed to USER_UNIT_DIR, not the quadlet dir).
USER_UNITS=(
    "backup.timer"
    "monitor.service"
    "monitor.timer"
)
# The subset that is enabled --now. monitor.service has no [Install] -- only the
# timer activates it -- so it must not be enabled on its own.
USER_TIMERS=(
    "backup.timer"
    "monitor.timer"
)

# Method allowlists for the CLN runes (`method^<prefix>` is a prefix match).
READ_METHODS='"method^getinfo","method^listfunds","method^listchannels","method^listpeers","method^listinvoices","method^listpays","method^decode"'
SPEND_METHODS="$READ_METHODS,\"method^invoice\",\"method^pay\",\"method^keysend\",\"method^withdraw\",\"method^close\""

# ---------------------------------------------------------------------------
# where the data lives
# ---------------------------------------------------------------------------
resolve_data_dir
ensure_data_dirs
ensure_data_dir_selinux

SECRETS_FILE="$CONFIG_DIR/stack/secrets.env"
SEARXNG_DATA_DIR="$DATA_DIR/searxng"
TOR_DIR="$DATA_DIR/tor"

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
    env_value "$SECRETS_FILE" "$1"
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

# Move a file into the data dir if it is not there yet, and drop the old copy
# once the two are byte-identical. Used to adopt the pre-data-dir layout.
adopt_file() {
    local src="$1" dest="$2"
    [ -s "$src" ] || return 0
    mkdir -p "$(dirname "$dest")"
    [ -e "$dest" ] || cp -p "$src" "$dest" || return 0
    if cmp -s "$src" "$dest"; then
        rm -f "$src"
        log "moved into the data dir: $src -> $dest"
    fi
}

# ---------------------------------------------------------------------------
# 0. adopt the old ~/.config layout
# ---------------------------------------------------------------------------
migrate_legacy_config() {
    adopt_file "$CONFIG_HOME/crypto-nodes/secrets.env" "$CONFIG_DIR/stack/secrets.env"
    adopt_file "$CONFIG_HOME/stack/secrets.env"        "$CONFIG_DIR/stack/secrets.env"
    local d f
    for d in searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp; do
        [ -d "$CONFIG_HOME/$d" ] || continue
        for f in "$CONFIG_HOME/$d"/*.env; do
            [ -e "$f" ] || continue
            adopt_file "$f" "$CONFIG_DIR/$d/$(basename "$f")"
        done
    done
}
migrate_legacy_config

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
# credential. Never committed. MONERO_WALLET_PASSWORD is the only key to the
# wallet file -- keep this file with the data.
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
fi
[ -d "$DATA_DIR/bitcoin" ] && chown_image_uid "$DATA_DIR/bitcoin"

# monero-wallet-rpc's image does not re-own its bind mount; create it for the
# image uid so the wallet-rpc can write the wallet.
if [ ! -d "$DATA_DIR/monero-wallet-rpc" ]; then
    mkdir -p "$DATA_DIR/monero-wallet-rpc"
fi
chown_image_uid "$DATA_DIR/monero-wallet-rpc"

mkdir -p "$DATA_DIR/monero" "$DATA_DIR/cln" "$TOR_DIR"

# The backup job's restic cache (regenerable) and its repository. The repo is
# outside $DATA_DIR on purpose, so wiping the data dir does not delete it.
mkdir -p "$DATA_DIR/backup-cache" "$STACK_BACKUP_DIR"

# ---------------------------------------------------------------------------
# 3. tor image + torrc
# ---------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1 && ! podman image exists "$TOR_IMAGE" 2>/dev/null; then
    if [ -f "$REPO_DIR/tor/Containerfile" ]; then
        log "building $TOR_IMAGE"
        podman build -t "$TOR_IMAGE" "$REPO_DIR/tor/" >/dev/null
    fi
fi

if [ -s "$TOR_DIR/torrc" ]; then
    log "keeping existing $TOR_DIR/torrc"
else
    mkdir -p "$TOR_DIR"
    hash=""
    if command -v podman >/dev/null 2>&1 && podman image exists "$TOR_IMAGE" 2>/dev/null; then
        # `tor --hash-password` prints a warning line to *stdout* first ("You
        # are running Tor as root..."), so take the hash by its shape -- Tor
        # writes it as 16:<hex> -- rather than the first line.
        hash=$(podman run --rm "$TOR_IMAGE" tor --hash-password "$TOR_SERVICE_PASSWORD" 2>/dev/null \
            | grep -E '^16:' | head -n1 || true)
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
        log "could not seed $TOR_DIR/torrc (tor image '$TOR_IMAGE' not built?) -- re-run after the build"
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
fi
if [ -s "$SEARXNG_DATA_DIR/limiter.toml" ]; then
    log "keeping existing $SEARXNG_DATA_DIR/limiter.toml"
else
    log "seeding $SEARXNG_DATA_DIR/limiter.toml"
    cp "$DEPLOY_DIR/searxng/limiter.toml" "$SEARXNG_DATA_DIR/limiter.toml"
fi

# ---------------------------------------------------------------------------
# 5. per-application env files (under the data dir)
# ---------------------------------------------------------------------------

SEARXNG_ENV="$CONFIG_DIR/searxng-mcp/token.env"
if ensure_secret "$SEARXNG_ENV" "searxng-mcp token env"; then
    token=$(new_or_reused_token searxng-mcp SEARXNG_MCP_TOKEN)
    write_secret "$SEARXNG_ENV" <<EOF
SEARXNG_MCP_TOKEN=$token
EOF
    log "wrote $SEARXNG_ENV (mode 600)"
fi

BTC_ENV="$CONFIG_DIR/bitcoin-node-mcp"
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

XMR_ENV="$CONFIG_DIR/monero-node-mcp"
if ensure_secret "$XMR_ENV/token.env" "monero-node-mcp token env"; then
    token=$(new_or_reused_token monero-node-mcp MONERO_MCP_TOKEN)
    write_secret "$XMR_ENV/token.env" <<EOF
MONERO_MCP_TOKEN=$token
EOF
    log "wrote $XMR_ENV/token.env (mode 600)"
fi
if ensure_secret "$XMR_ENV/upstream.env" "monero-node-mcp upstream env"; then
    write_secret "$XMR_ENV/upstream.env" <<EOF
# Empty unless monerod was started with --rpc-login.
MONERO_RPC_USER=
MONERO_RPC_PASSWORD=
EOF
    log "wrote $XMR_ENV/upstream.env (mode 600)"
fi

XMRW_ENV="$CONFIG_DIR/monero-wallet-mcp"
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
# Upstream credentials for monero-wallet-rpc (--rpc-login).
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

LN_ENV="$CONFIG_DIR/lightning-mcp"
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
ENABLE_SPENDING=0
MAX_PAYMENT_PER_CALL_SATS=10000
MAX_PAYMENT_PER_DAY_SATS=100000
EOF
    log "wrote $LN_ENV/spend.env (mode 600) with ENABLE_SPENDING=0"
fi

# Backup repository settings for deploy/backup.container. The unit is
# secret-free and reads these through EnvironmentFile; the password is a real
# secret, so it follows the same resolution order (an operator-supplied value
# wins, so an offsite repo can be opened on a fresh host before this file
# exists -- see scripts/backup.sh). Keep a copy off the data disk.
BACKUP_ENV="$CONFIG_DIR/backup/backup.env"
if ensure_secret "$BACKUP_ENV" "backup env"; then
    restic_password=$(first_nonempty \
        "$(read_secret RESTIC_PASSWORD)" \
        "${RESTIC_PASSWORD:-}" \
        "$(rand_hex)")
    write_secret "$BACKUP_ENV" <<EOF
# restic repository for the nightly backup (deploy/backup.container). The
# local default is the STACK_BACKUP_DIR host dir mounted at /repo; point
# RESTIC_REPOSITORY at an offsite target (s3:, b2:, sftp:) for real disaster
# recovery. RESTIC_PASSWORD is the only key to the encrypted backups -- keep a
# copy somewhere other than the data disk. See
# deploy/examples/backup/backup.env.example.
RESTIC_REPOSITORY=/repo
RESTIC_PASSWORD=$restic_password
RESTIC_CACHE_DIR=/cache
EOF
    log "wrote $BACKUP_ENV (mode 600)"
fi

# Monitoring: the alert targets and the dead-man's-switch heartbeat for
# deploy/monitor.service (scripts/monitor.sh). Empty values mean journal-only,
# so a fresh host is safe before this file is filled in.
MON_ENV="$CONFIG_DIR/monitoring/monitor.env"
if ensure_secret "$MON_ENV" "monitoring env"; then
    write_secret "$MON_ENV" <<'EOF'
# Alerts (Apprise targets, space-separated) and the dead-man's-switch
# heartbeat, for scripts/monitor.sh via deploy/monitor.service. Empty means
# journal-only. See deploy/examples/monitoring/monitor.env.example.
MONITOR_APPRISE_URLS=
MONITOR_PING_URL=
MONITOR_GRACE_SYNC=1
MONITOR_VERIFY_ARGS=--deep
EOF
    log "wrote $MON_ENV (mode 600) -- empty: journal-only until filled in"
fi

# The monitor's record: the audit log, the spend baseline and its state file.
# Deliberately NOT under config/ (it is not secret); deploy/backup.container
# backs it up. scripts/spend-audit.sh seeds its own baselines on the first run.
mkdir -p "$DATA_DIR/audit"

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
    # Never hand back an unproven rune: return empty so the caller keeps the
    # existing node.env (or retries on a later run) instead of writing a rune
    # the node will refuse.
    printf '==> gave up creating a usable rune after 12 tries\n' >&2
}

read_rune=""
spend_rune=""
tls_insecure=""
ca_cert=""
read_rune=$(env_value "$LN_ENV/node.env" LIGHTNING_RUNE)
spend_rune=$(env_value "$LN_ENV/node.env" LIGHTNING_SPEND_RUNE)
tls_insecure=$(env_value "$LN_ENV/node.env" LIGHTNING_TLS_INSECURE)
ca_cert=$(env_value "$LN_ENV/node.env" LIGHTNING_CA_CERT)

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
# 6. units: render every one (they all reference the data or config dir)
# ---------------------------------------------------------------------------
render_unit() {
    local src="$1" target="$2" tmp
    tmp="$(mktemp)"
    sed -e "s|@DATA_DIR@|$(esc "$DATA_DIR")|g" \
        -e "s|@CONFIG_DIR@|$(esc "$CONFIG_DIR")|g" \
        -e "s|@REPO_DIR@|$(esc "$REPO_DIR")|g" \
        -e "s|@BACKUP_DIR@|$(esc "$STACK_BACKUP_DIR")|g" \
        -e "s|@BITCOIN_RPC_USER@|$(esc "$BITCOIN_RPC_USER")|g" \
        -e "s|@BITCOIN_RPC_PASSWORD@|$(esc "$BITCOIN_RPC_PASSWORD")|g" \
        -e "s|@TOR_SERVICE_PASSWORD@|$(esc "$TOR_SERVICE_PASSWORD")|g" \
        -e "s|@MONERO_WALLET_PASSWORD@|$(esc "$MONERO_WALLET_PASSWORD")|g" \
        -e "s|@MONERO_RPC_LOGIN@|$(esc "$MONERO_RPC_LOGIN")|g" \
        "$src" > "$tmp"
    [ -L "$target" ] && rm -f "$target"
    install -m 600 "$tmp" "$target"
    rm -f "$tmp"
}

mkdir -p "$QUADLET_DIR"
for pair in "${UNITS[@]}"; do
    src="$DEPLOY_DIR/${pair%%:*}"
    unit="${pair##*:}"
    target="$QUADLET_DIR/$unit"
    if [ -e "$target" ] && [ ! -L "$target" ] && [ ! -e "$target.bak" ]; then
        mv -f "$target" "$target.bak"
        log "backed up existing $unit -> $unit.bak"
    fi
    render_unit "$src" "$target"
done
log "rendered ${#UNITS[@]} units (mode 600)"

# Plain user units go to the user unit dir (see USER_UNIT_DIR): Quadlet will
# not generate them. The timers activate the services they name --
# backup.service (generated by Quadlet from backup.container) and
# monitor.service (a plain host-script unit).
mkdir -p "$USER_UNIT_DIR"
for u in "${USER_UNITS[@]}"; do
    target="$USER_UNIT_DIR/$u"
    if [ -e "$target" ] && [ ! -L "$target" ] && [ ! -e "$target.bak" ]; then
        mv -f "$target" "$target.bak"
        log "backed up existing $u -> $u.bak"
    fi
    render_unit "$DEPLOY_DIR/$u" "$target"
done
log "installed ${#USER_UNITS[@]} user unit(s) into $USER_UNIT_DIR"

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    # enable --now so the schedules are live without waiting for a reboot. On a
    # fresh host with Persistent=true this may run one backup immediately; it
    # initialises the repository and is harmless.
    systemctl --user enable --now "${USER_TIMERS[@]}" >/dev/null 2>&1 \
        || log "could not enable ${USER_TIMERS[*]}; run: systemctl --user enable --now ${USER_TIMERS[*]}"
    log "systemd --user reloaded"
fi

cat <<EOF

Done. Everything the stack owns lives under:
  $DATA_DIR
    bitcoin/ monero/ monero-wallet-rpc/ cln/ tor/ searxng/ npm/
    config/   <- all bearer tokens and secrets (mode 600)
    audit/    <- the monitor's log and the spend tripwire baselines
  $STACK_BACKUP_DIR
    the restic repository the nightly backup writes (backup.timer)

Next:  ./deploy.sh         # build images, start everything, verify
Spending is OFF on both money servers until you set ENABLE_SPENDING=1 under
  $CONFIG_DIR/monero-wallet-mcp/spend.env  and  $CONFIG_DIR/lightning-mcp/spend.env
The monitor runs every 5 minutes (monitor.timer) and alerts only once
  $CONFIG_DIR/monitoring/monitor.env has an Apprise target and/or a heartbeat.
Keep a copy of RESTIC_PASSWORD ($BACKUP_ENV) off the data disk: it is the only
key to the backups.
EOF
