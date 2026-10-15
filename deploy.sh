#!/usr/bin/env bash
# One-click deploy for the whole stack.
#
#   ./deploy.sh                    # fetch repos, install, build every image,
#                                  # start everything, open firewalld, verify
#   ./deploy.sh --bootstrap        # also provision a bare Rocky 10 host first
#   ./deploy.sh --only <name>      # redeploy a single service (app or unit)
#   ./deploy.sh --skip-apps        # infra only (daemons, searxng, NPM)
#   ./deploy.sh --no-wallets       # do not prompt for the Monero/Bitcoin wallet
#   ./deploy.sh --dry-run          # print the plan; change nothing
#
# Ordering is load-bearing: the daemons come up before the MCP servers that
# read them, and lightning-mcp's runes are created only once lightningd's RPC
# answers. Chain sync takes hours to days; this script starts the containers and
# does NOT wait for sync -- re-run it (idempotent) when the chains are current.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stack.conf
. "$REPO_DIR/stack.conf"

DRY_RUN=0
ONLY=""
DO_BOOTSTRAP=0
DO_WALLETS=1
SKIP_APPS=0

BITCOIND_WAIT="${BITCOIND_WAIT:-600}"
MONEROD_WAIT="${MONEROD_WAIT:-300}"
LIGHTNINGD_WAIT="${LIGHTNINGD_WAIT:-900}"
APP_HEALTH_WAIT="${APP_HEALTH_WAIT:-180}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$REPO_DIR/deploy.sh"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bootstrap)   DO_BOOTSTRAP=1 ;;
        --only)        ONLY="${2:?--only needs a service name}"; shift ;;
        --no-wallets)  DO_WALLETS=0 ;;
        --skip-apps)   SKIP_APPS=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

in_list() { local needle="$1"; shift; local x; for x in "$@"; do [ "$x" = "$needle" ] && return 0; done; return 1; }

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
preflight() {
    [ "$(id -u)" -ne 0 ] || die "run as your login user, not root (containers are rootless)"
    [ -n "${HOME:-}" ] || die "HOME is not set"

    if ! command -v podman >/dev/null 2>&1; then
        if [ "$DO_BOOTSTRAP" = 1 ]; then
            "$REPO_DIR/bootstrap.sh"
        else
            die "podman is not installed. Re-run with --bootstrap, or run ./bootstrap.sh first."
        fi
    fi

    local linger
    linger=$(loginctl show-user "$(id -un)" 2>/dev/null | sed -n 's/^Linger=//p' || true)
    [ "$linger" = "yes" ] || warn "user linger is off; containers stop when you log out. Fix: sudo loginctl enable-linger $(id -un)"

    local portstart
    portstart=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 0)
    if [ "${portstart:-0}" -gt 80 ] 2>/dev/null; then
        warn "net.ipv4.ip_unprivileged_port_start=$portstart: nginx-proxy-manager cannot bind 80/443/81. Run ./bootstrap.sh."
    fi
}

# ---------------------------------------------------------------------------
# 1. fetch the application repos
# ---------------------------------------------------------------------------
fetch_repos() {
    mkdir -p "$BUILD_DIR"
    local r dir
    for r in "${APP_REPOS[@]}"; do
        dir="$BUILD_DIR/$r"
        if [ -d "$dir/.git" ]; then
            log "updating $r"
            run git -C "$dir" pull --ff-only -q
        else
            log "cloning $r"
            run git clone -q "https://github.com/$GITHUB_ORG/$r.git" "$dir"
        fi
    done
}

# ---------------------------------------------------------------------------
# 2. units + secrets + data dirs
# ---------------------------------------------------------------------------
install_units() {
    log "installing units, seeding secrets and data dirs"
    run "$REPO_DIR/deploy/install.sh"
}

# ---------------------------------------------------------------------------
# helpers for the runtime steps
# ---------------------------------------------------------------------------
start_unit() { log "starting $1.service"; run systemctl --user start "$1.service"; }

wait_healthy() { # container timeout
    local c="$1" t="${2:-180}" deadline st=""
    [ "$DRY_RUN" = 1 ] && return 0
    deadline=$(( $(date +%s) + t ))
    while :; do
        st=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
        case "$st" in *"(healthy)"*) log "$c is healthy"; return 0 ;; esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "$c not healthy after ${t}s (status: ${st:-container missing})"
            return 1
        fi
        sleep 5
    done
}

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

# ---------------------------------------------------------------------------
# 3. start the infrastructure, in dependency order
# ---------------------------------------------------------------------------
start_infra() {
    # tor first: lightningd requires it and addresses it by its pinned IP.
    start_unit tor
    start_unit bitcoind
    start_unit monerod
    start_unit valkey
    start_unit searxng
    start_unit nginx-proxy-manager

    # RPC-level readiness, not sync: getblockchaininfo answers while syncing.
    wait_cmd "bitcoind RPC" "$BITCOIND_WAIT" podman exec bitcoind bitcoin-cli getblockchaininfo \
        || warn "continuing without bitcoind RPC (it may still be starting)"
    wait_healthy monerod "$MONEROD_WAIT" || warn "continuing; monerod may still be syncing"
}

# ---------------------------------------------------------------------------
# 4. wallets (Monero must exist before monero-wallet-rpc can start)
# ---------------------------------------------------------------------------
setup_wallets() {
    [ "$DO_WALLETS" = 1 ] || { log "skipping wallet setup (--no-wallets)"; return 0; }
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] %s --monero\n' "$REPO_DIR/scripts/wallets.sh"
        printf '  [dry-run] %s --bitcoin\n' "$REPO_DIR/scripts/wallets.sh"
        return 0
    fi
    "$REPO_DIR/scripts/wallets.sh" --monero || warn "Monero wallet setup did not complete"
    "$REPO_DIR/scripts/wallets.sh" --bitcoin || warn "Bitcoin wallet setup did not complete"
}

# ---------------------------------------------------------------------------
# 5. the rest of the daemons, then lightning-mcp's runes
# ---------------------------------------------------------------------------
start_daemons() {
    start_unit lightningd
    wait_cmd "lightningd RPC" "$LIGHTNINGD_WAIT" podman exec lightningd lightning-cli getinfo \
        || warn "lightningd RPC not up; runes are created on a later ./deploy.sh run"

    # monero-wallet-rpc opens the wallet at startup, so it only starts once the
    # wallet file exists (scripts/wallets.sh ensures that).
    start_unit monero-wallet-rpc
    wait_healthy monero-wallet-rpc "${MONERO_WALLET_WAIT:-300}" || warn "monero-wallet-rpc not healthy"

    # Re-run the installer now that lightningd answers, to mint the runes.
    log "re-running installer to create CLN runes"
    run "$REPO_DIR/deploy/install.sh"
}

# ---------------------------------------------------------------------------
# 6. the application servers
# ---------------------------------------------------------------------------
deploy_app() { # repo name
    local r="$1"
    local dir="$BUILD_DIR/$r"
    local image="localhost/$r:latest"
    [ -d "$dir" ] || { warn "$r is not cloned under $BUILD_DIR"; return 1; }
    [ -f "$dir/Containerfile" ] || { warn "$r has no Containerfile"; return 1; }

    log "building $image"
    run podman build -t "$image" "$dir"
    start_unit "$r"
    wait_healthy "$r" "$APP_HEALTH_WAIT" || { warn "$r did not report healthy"; return 1; }
}

deploy_apps() {
    local r failed=0
    for r in "${APP_REPOS[@]}"; do
        deploy_app "$r" || failed=1
    done
    [ "$failed" = 0 ] || warn "one or more app servers did not report healthy; see: podman ps -a"
}

# ---------------------------------------------------------------------------
# 7. firewalld
# ---------------------------------------------------------------------------
open_firewall() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        warn "firewall-cmd not found; open ${FIREWALL_PORTS[*]}/tcp yourself"
        return 0
    fi
    if ! firewall-cmd --state >/dev/null 2>&1; then
        warn "firewalld is not running; open ${FIREWALL_PORTS[*]}/tcp yourself"
        return 0
    fi
    local p args=()
    for p in "${FIREWALL_PORTS[@]}"; do args+=(--add-port="$p/tcp"); done
    log "opening ${FIREWALL_PORTS[*]}/tcp in firewalld"
    run sudo firewall-cmd --permanent "${args[@]}" >/dev/null
    run sudo firewall-cmd --reload >/dev/null
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
preflight

if [ -n "$ONLY" ]; then
    if in_list "$ONLY" "${APP_REPOS[@]}"; then
        fetch_repos
        install_units
        deploy_app "$ONLY"
    else
        install_units
        start_unit "$ONLY"
        wait_healthy "$ONLY" "$APP_HEALTH_WAIT" || true
    fi
    log "done (--only $ONLY)"
    exit 0
fi

fetch_repos
install_units
start_infra
setup_wallets
start_daemons
[ "$SKIP_APPS" = 1 ] || deploy_apps
open_firewall

if [ "$DRY_RUN" = 1 ]; then
    log "dry run complete; nothing was changed"
    exit 0
fi

log "running verification"
"$REPO_DIR/verify.sh" || warn "verification reported problems"

cat <<EOF

Stack deployed.

  Daemons and web:  bitcoind, monerod, monero-wallet-rpc, lightningd, tor,
                    valkey, searxng, nginx-proxy-manager
  MCP servers:      searxng-mcp :8000, bitcoin-node-mcp :8101,
                    monero-node-mcp :8102, monero-wallet-mcp :8103,
                    lightning-mcp :8104
  Spending:         OFF on both money servers (ENABLE_SPENDING=0)

Chain sync continues in the background (bitcoind is pruned; monerod is
pruned). Re-run ./deploy.sh once the chains are current to finish anything
that was waiting on them.
EOF
