#!/usr/bin/env bash
# The second step of a deploy: everything that needs a *running* stack.
#
#   ./deploy.sh            # units, images, start/restart -- it never waits
#   ./configure.sh         # the work that needs the services answering:
#                          #   wallet    the Bitcoin Core wallet
#                          #   runes     the CLN read/spend runes
#                          #   btcpay    DB/role, plugin wallet, bootstrap, envs
#                          #   boltmesh  the BoltMesh database migrations
#                          #   agents    the agent-mcp read-only handshake
#
# Each section waits (bounded) for the service it needs and warns instead of
# failing when that service is not up, so the script is safe to run early and
# safe to re-run after a chain sync. Health is still ./verify.sh's and the
# monitor's verdict; this script is the deploy's other half, not a checker.
#
#   ./configure.sh                    # all of the above, in that order
#   ./configure.sh --only runes       # one section
#   ./configure.sh --skip-daemons     # no daemon-dependent work (wallet/runes/
#                                     # BTCPay/handshake)
#   ./configure.sh --skip-apps        # no BoltMesh migrations
#   ./configure.sh --no-wallets       # do not prompt for the Bitcoin wallet
#   ./configure.sh --dry-run          # print the plan; change nothing
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
ONLY=""
SKIP_APPS=0
SKIP_DAEMONS=0
DO_WALLETS=1

# A give-up bound, not a promise: wait_healthy raises it to the unit's own
# StartPeriod + Interval when that is larger.
APP_HEALTH_WAIT="${APP_HEALTH_WAIT:-60}"
BITCOIND_WAIT="${BITCOIND_WAIT:-600}"
# lightningd's bcli plugin starts with RPC while bitcoind is still loading its
# wallet, and dies on the first timeout ("The Bitcoin backend died"). Require
# wallet-level RPC before anything depends on it; the chain RPC alone answers
# long before that (getblockchaininfo is served mid-init).
BITCOIND_WALLET_WAIT="${BITCOIND_WALLET_WAIT:-120}"
LIGHTNINGD_WAIT="${LIGHTNINGD_WAIT:-900}"
MONERO_WALLET_WAIT="${MONERO_WALLET_WAIT:-300}"
POSTGRES_WAIT="${POSTGRES_WAIT:-180}"
BTCPAY_WAIT="${BTCPAY_WAIT:-300}"
NBXPLORER_WAIT="${NBXPLORER_WAIT:-300}"

# shellcheck source=stack.conf
. "$REPO_DIR/stack.conf"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
load_manifest "$REPO_DIR"

usage() { usage_header "$REPO_DIR/configure.sh"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --only)         ONLY="${2:?--only needs a section}"; shift ;;
        --skip-apps)    SKIP_APPS=1 ;;
        --skip-daemons) SKIP_DAEMONS=1; DO_WALLETS=0 ;;
        --no-wallets)   DO_WALLETS=0 ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# --only names one section; the skip flags describe the stack. A section that
# the flags exclude would otherwise run anyway, so catch the contradiction
# before any wait starts.
if [ -n "$ONLY" ]; then
    if [ "$SKIP_DAEMONS" = 1 ]; then
        case "$ONLY" in
            wallet|runes|btcpay|agents)
                die "--only $ONLY needs the chain daemons; drop --skip-daemons" ;;
        esac
    fi
    if [ "$SKIP_APPS" = 1 ] && [ "$ONLY" = boltmesh ]; then
        die "--only boltmesh conflicts with --skip-apps"
    fi
fi

# ---------------------------------------------------------------------------
# readiness helpers
# ---------------------------------------------------------------------------
# Poll a command until it answers or the deadline passes. This is the waiting
# half of the split: deploy.sh starts the unit, configure.sh waits for it.
wait_cmd() { # description timeout cmd...
    local desc="$1" t="$2"; shift 2
    local deadline
    [ "$DRY_RUN" = 1 ] && return 0
    deadline=$(( $(date +%s) + t ))
    while :; do
        if "$@" >/dev/null 2>&1; then log "$desc ready"; return 0; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "$desc not ready after ${t}s"
            return 1
        fi
        sleep 5
    done
}

# Print the last lines of a container's log with an indent, so a timeout shows
# *why* instead of just spinning. Never fails: it runs after a failed wait, when
# the container may not exist at all, and the caller's "warn and move on" must
# not turn into a set -e exit over a missing log.
dump_tail() { # container [lines]
    local c="$1" n="${2:-30}"
    [ "$DRY_RUN" = 1 ] && return 0
    warn "last $n log lines from $c:"
    podman logs --tail "$n" "$c" 2>&1 | sed 's/^/  | /' || true
}

# True while bitcoind is in initial block download. CLN cannot finish starting
# until it is caught up, so waiting on lightningd then is wasted time.
bitcoind_syncing() {
    [ "$DRY_RUN" = 1 ] && return 1
    bitcoind_cli getblockchaininfo 2>/dev/null \
        | jq -e '.initialblockdownload == true' >/dev/null 2>&1
}

# Wallet-level RPC answers *and* a wallet is loaded -- what lightningd's bcli
# needs. Never `getwalletinfo` on its own: with two wallets loaded a node answers
# -19 ("Wallet file not specified"), which says nothing about readiness.
# listwallets answers either way, and `[]` (nothing loaded) correctly reads as
# "not ready".
bitcoind_wallet_ready() {
    bitcoind_cli listwallets 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1
}

restart_if_active() { # unit
    systemctl --user is-active --quiet "$1.service" 2>/dev/null || return 0
    log "restarting $1 to pick up its new env"
    systemctl --user restart "$1.service" \
        || warn "$1 did not restart; it keeps the old env"
}

# Write stdin to PATH only when the bytes differ: 0 when it wrote, 1 when the
# file was already current, 2 when the write failed (already warned). Split so a
# caller restarts the unit that reads PATH only for 0, and can still tell an
# unchanged file from a broken write.
write_if_changed() { # path
    local path="$1" tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    # write_env_file is the one atomic, mode-600 writer the stack uses for
    # secret-carrying env files (scripts/lib.sh's write_atomic underneath).
    if ! write_env_file "$path" < "$tmp"; then
        warn "could not write $path"
        rm -f "$tmp"
        return 2
    fi
    rm -f "$tmp"
    return 0
}

# A file's bytes as a digest, empty when it does not exist. Used to decide
# whether a unit that reads its EnvironmentFile= at start needs a restart --
# systemd does not re-read it for a running service.
file_digest() { # path
    [ -f "$1" ] || return 0
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true
}

# ---------------------------------------------------------------------------
# wallet: the Bitcoin Core wallet (lightningd's bcli and the operator's tools)
# ---------------------------------------------------------------------------
configure_wallet() {
    log "configuring the Bitcoin Core wallet"
    if ! wait_cmd "bitcoind RPC" "$BITCOIND_WAIT" bitcoind_cli getblockchaininfo; then
        warn "bitcoind RPC is not up; skipping the wallet (re-run ./configure.sh once it is)"
        return 0
    fi
    "$REPO_DIR/scripts/wallets.sh" || warn "Bitcoin wallet setup did not complete"
}

# ---------------------------------------------------------------------------
# runes: install.sh mints them once lightningd answers
# ---------------------------------------------------------------------------
configure_runes() {
    log "minting the CLN runes"
    if ! wait_cmd "bitcoind RPC" "$BITCOIND_WAIT" bitcoind_cli getblockchaininfo; then
        warn "bitcoind RPC is not up; not waiting on lightningd"
        warn "the CLN runes (and lightning-mcp's tools) come alive on a later ./configure.sh run"
        return 0
    fi
    # CLN does not finish starting until bitcoind is caught up, so during
    # initial block download the wait below would burn the whole timeout for
    # nothing. Let a later run create the runes.
    if bitcoind_syncing; then
        warn "bitcoind is still in initial block download; not waiting on lightningd"
        warn "the CLN runes (and lightning-mcp's tools) come alive on a later ./configure.sh run"
        return 0
    fi
    if ! wait_cmd "bitcoind wallet RPC" "$BITCOIND_WALLET_WAIT" bitcoind_wallet_ready; then
        warn "bitcoind wallet RPC not up; not waiting on lightningd"
        warn "the CLN runes (and lightning-mcp's tools) come alive on a later ./configure.sh run"
        dump_tail bitcoind 20
        return 0
    fi
    if ! wait_cmd "lightningd RPC" "$LIGHTNINGD_WAIT" lightning_cli getinfo; then
        warn "lightningd RPC not up; runes are created on a later ./configure.sh run"
        dump_tail lightningd 40
        return 0
    fi
    # install.sh checks the node is reachable and mints the read/spend runes;
    # it is idempotent and a no-op once both runes are usable.
    local envf="$CONFIG_DIR/lightning-mcp/node.env" before after
    before=$(file_digest "$envf")
    log "re-running the installer to mint the CLN runes"
    "$REPO_DIR/deploy/install.sh" || warn "the installer did not complete"
    after=$(file_digest "$envf")
    if [ "$before" != "$after" ]; then
        # lightning-mcp reads LIGHTNING_RUNE from its EnvironmentFile= at start,
        # so a rune minted after the server started is invisible to it until it
        # restarts. scripts/rotate.sh restarts it for the same reason. On a
        # fresh host deploy.sh started the server before any rune existed.
        restart_if_active lightning-mcp
    fi
}

# ---------------------------------------------------------------------------
# btcpay: the settlement tier's state (needs postgres/nbxplorer/btcpay up)
# ---------------------------------------------------------------------------
ensure_btcpay_db() {
    local pw
    pw=$(env_value "$CONFIG_DIR/stack/secrets.env" BTCPAY_DB_PASSWORD)
    [ -n "$pw" ] || { warn "no BTCPAY_DB_PASSWORD in $CONFIG_DIR/stack/secrets.env; run deploy/install.sh first"; return 1; }
    # Roles and databases are idempotent. The password is hex from install.sh,
    # so embedding it in the SQL is safe.
    if ! podman exec postgres psql -U vpnuser -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='btcpay'" | grep -q 1; then
        podman exec postgres psql -U vpnuser -d postgres -v ON_ERROR_STOP=1             -c "CREATE ROLE btcpay LOGIN PASSWORD '$pw' CREATEDB" >/dev/null || return 1
        log "created the btcpay Postgres role"
    fi
    local db
    for db in btcpay nbxplorer; do
        if ! podman exec postgres psql -U vpnuser -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
            podman exec postgres psql -U vpnuser -d postgres -v ON_ERROR_STOP=1                 -c "CREATE DATABASE $db OWNER btcpay" >/dev/null || return 1
            log "created the $db database"
        fi
    done
}

write_btcpay_backend_env() {
    local state="$CONFIG_DIR/btcpay/bootstrap.env" key store secret rc=0
    [ -s "$state" ] || { warn "no $state; the BTCPay bootstrap has not completed"; return 1; }
    key=$(env_value "$state" BTCPAY_API_KEY)
    store=$(env_value "$state" BTCPAY_STORE_ID)
    secret=$(env_value "$state" BTCPAY_WEBHOOK_SECRET)
    if [ -z "$key" ] || [ -z "$store" ] || [ -z "$secret" ]; then
        warn "the BTCPay bootstrap state is incomplete; not writing the backend env"
        return 1
    fi
    write_if_changed "$CONFIG_DIR/btcpay/backend.env" <<EOF || rc=$?
# Written by configure.sh from btcpay/bootstrap.env. Do not hand-edit.
BTCPAY_URL=http://btcpay:49392
BTCPAY_API_KEY=$key
BTCPAY_STORE_ID=$store
BTCPAY_WEBHOOK_SECRET=$secret
EOF
    case "$rc" in
        0)
            log "wrote $CONFIG_DIR/btcpay/backend.env (mode 600)"
            # The backend and worker read it as an EnvironmentFile when they start.
            restart_if_active boltmesh-backend
            restart_if_active boltmesh-worker
            ;;
        1) ;;  # already current
        *) return 1 ;;
    esac
}

# The read side of the same state: the store-scoped, read-only key
# btcpay_bootstrap.py minted. It is rewritten every run (not seeded) so a
# re-minted key cannot leave a stale copy in the unit's EnvironmentFile -- the
# same reason crowdsec's lapi.env is derived from secrets.env.
write_btcpay_mcp_env() {
    local state="$CONFIG_DIR/btcpay/bootstrap.env" key store envf rc=0
    [ -s "$state" ] || { warn "no $state; the BTCPay bootstrap has not completed"; return 1; }
    key=$(env_value "$state" BTCPAY_MCP_KEY)
    store=$(env_value "$state" BTCPAY_STORE_ID)
    if [ -z "$key" ] || [ -z "$store" ]; then
        warn "the BTCPay bootstrap has no read-only MCP key yet; btcpay-mcp will report unconfigured"
        return 1
    fi
    envf="$CONFIG_DIR/btcpay-mcp/upstream.env"
    mkdir -p "$(dirname "$envf")"
    write_if_changed "$envf" <<EOF || rc=$?
# Written by configure.sh from btcpay/bootstrap.env. Do not hand-edit.
BTCPAY_URL=http://btcpay:49392
BTCPAY_PUBLIC_URL=https://$BTCPAY_HOST
BTCPAY_API_KEY=$key
BTCPAY_STORE_ID=$store
EOF
    case "$rc" in
        0)
            log "wrote $envf (mode 600)"
            restart_if_active btcpay-mcp
            ;;
        1) ;;  # already current
        *) return 1 ;;
    esac
}

configure_btcpay() {
    log "configuring BTCPay"
    if ! wait_healthy postgres "$POSTGRES_WAIT"; then
        warn "postgres not healthy; skipping the BTCPay databases"
        dump_tail postgres 20
        return 0
    fi
    # BTCPay uses the existing Postgres cluster (separate databases), so the
    # role/database step precedes the store bootstrap; NBXplorer and BTCPay may
    # already be restarting themselves until these exist.
    ensure_btcpay_db || { warn "could not prepare the BTCPay databases"; return 0; }

    wait_healthy nbxplorer "$NBXPLORER_WAIT" \
        || { warn "nbxplorer did not become healthy"; dump_tail nbxplorer 30; return 0; }
    wait_healthy monero-wallet-btcpay "$MONERO_WALLET_WAIT" \
        || warn "monero-wallet-btcpay not healthy"
    if ! wait_healthy btcpay "$BTCPAY_WAIT"; then
        warn "btcpay did not become healthy"
        dump_tail btcpay 40
        return 0
    fi

    # Import the view-only plugin wallet once the operator has supplied the
    # address/view key; the script is a no-op otherwise (and restarts BTCPay
    # itself when it does import, so wait before the bootstrap).
    if "$REPO_DIR/scripts/btcpay-wallet.sh"; then
        wait_healthy btcpay "$BTCPAY_WAIT" \
            || warn "btcpay did not come back healthy after the wallet import"
    else
        warn "the BTCPay Monero wallet was not imported; XMR-CHAIN will stay disabled"
    fi

    # A oneshot job: systemctl start blocks until the bootstrap exits.
    systemctl --user start btcpay-bootstrap.service \
        || warn "the BTCPay bootstrap did not complete; check: podman logs btcpay-bootstrap"
    write_btcpay_backend_env || warn "BTCPay is up but the backend env was not written"
    write_btcpay_mcp_env || warn "BTCPay is up but the btcpay-mcp env was not written"
}

# ---------------------------------------------------------------------------
# boltmesh: the database migrations (need postgres up)
# ---------------------------------------------------------------------------
# The four env files the backend/worker read; passed to the one-off migration
# container. install.sh and configure_btcpay wrote them by the time we run.
boltmesh_env_args() {
    printf '%s\n' \
        "--env-file" "$CONFIG_DIR/boltmesh/db.env" \
        "--env-file" "$CONFIG_DIR/boltmesh/secrets.env" \
        "--env-file" "$CONFIG_DIR/boltmesh/app.env" \
        "--env-file" "$CONFIG_DIR/btcpay/backend.env"
}

run_boltmesh_migrations() {
    log "applying BoltMesh database migrations"
    local -a envs=()
    # shellcheck disable=SC2207
    envs=($(boltmesh_env_args))
    podman run --rm --network npm-network \
        "${envs[@]}" \
        localhost/boltmesh-backend:latest alembic upgrade head
}

configure_boltmesh() {
    if ! wait_healthy postgres "$POSTGRES_WAIT"; then
        warn "postgres not healthy; skipping the BoltMesh migrations"
        dump_tail postgres 20
        return 0
    fi
    [ -s "$CONFIG_DIR/btcpay/backend.env" ] \
        || { warn "no $CONFIG_DIR/btcpay/backend.env (the BTCPay bootstrap has not completed); skipping the migrations"; return 0; }
    run_boltmesh_migrations || warn "migrations failed; the API may not start cleanly"
}

# ---------------------------------------------------------------------------
# agents: prove the read-only token path through nginx-proxy-manager
# ---------------------------------------------------------------------------
configure_agents() {
    if [ ! -x "$HOME/.local/bin/agent-mcp" ]; then
        log "agent-mcp is not installed; skipping the handshake (./deploy.sh --only agent-skills)"
        return 0
    fi
    if [ "$SKIP_DAEMONS" = 1 ]; then
        log "skipping the agent-mcp handshake (--skip-daemons): bitcoin-node-mcp has no chain to read"
        return 0
    fi
    if ! podman container exists bitcoin-node-mcp 2>/dev/null; then
        log "bitcoin-node-mcp is not deployed; skipping the agent-mcp handshake"
        return 0
    fi
    wait_healthy bitcoin-node-mcp "$APP_HEALTH_WAIT" \
        || { warn "bitcoin-node-mcp is not healthy; skipping the agent-mcp handshake"; return 0; }
    if "$HOME/.local/bin/agent-mcp" bitcoin-node get_blockchain_info >/dev/null 2>&1; then
        log "agent-mcp read the bitcoin node through $MCP_HOST"
    else
        warn "agent-mcp could not call bitcoin-node: check the token in $CONFIG_DIR/bitcoin-node-mcp/token.env and the $MCP_HOST proxy host (./verify.sh)"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
preflight() {
    [ "$(id -u)" -ne 0 ] || die "run as your login user, not root (containers are rootless)"
    [ -n "${HOME:-}" ] || die "HOME is not set"
    command -v podman >/dev/null 2>&1 \
        || die "podman is not installed; run ./deploy.sh --bootstrap first"
    resolve_data_dir
    log "data directory: $DATA_DIR"
}

run_all() {
    if [ "$SKIP_DAEMONS" = 0 ]; then
        [ "$DO_WALLETS" = 0 ] || configure_wallet
        configure_runes
        configure_btcpay
    fi
    [ "$SKIP_APPS" = 1 ] || configure_boltmesh
    configure_agents
}

preflight

# The per-section plan, for --dry-run. The dispatch below runs the real thing.
plan_section() {
    case "$1" in
        wallet)   printf '  wallet    scripts/wallets.sh (bitcoind RPC)\n' ;;
        runes)    printf '  runes     deploy/install.sh (bitcoind wallet RPC + lightningd RPC)\n' ;;
        btcpay)   printf '  btcpay    role/databases, plugin wallet, bootstrap, backend/btcpay-mcp envs\n' ;;
        boltmesh) printf '  boltmesh  alembic upgrade head (postgres)\n' ;;
        agents)   printf '  agents    agent-mcp bitcoin-node get_blockchain_info (via %s)\n' "${MCP_HOST:-NPM}" ;;
        *)        return 1 ;;
    esac
}

if [ "$DRY_RUN" = 1 ]; then
    log "dry run: would wait for each service, then run:"
    if [ -n "$ONLY" ]; then
        plan_section "$ONLY" || die "unknown --only: $ONLY (wallet|runes|btcpay|boltmesh|agents)"
    else
        if [ "$SKIP_DAEMONS" = 0 ]; then
            [ "$DO_WALLETS" = 0 ] || plan_section wallet
            plan_section runes
            plan_section btcpay
        fi
        [ "$SKIP_APPS" = 1 ] || plan_section boltmesh
        [ "$SKIP_DAEMONS" = 1 ] || plan_section agents
    fi
    exit 0
fi

case "$ONLY" in
    wallet)   configure_wallet ;;
    runes)    configure_runes ;;
    btcpay)   configure_btcpay ;;
    boltmesh) configure_boltmesh ;;
    agents)   configure_agents ;;
    "")       run_all ;;
    *)        die "unknown --only: $ONLY (wallet|runes|btcpay|boltmesh|agents)" ;;
esac

log "done (configure${ONLY:+ --only $ONLY}); health is ./verify.sh's verdict"
