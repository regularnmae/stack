#!/usr/bin/env bash
# One-click deploy for the whole stack.
#
#   ./deploy.sh                    # fetch repos, install, build every image,
#                                  # start everything, verify
#   ./deploy.sh --bootstrap        # also provision a bare Rocky 10 host first
#   ./deploy.sh --only <name>      # redeploy a single service (app or unit)
#   ./deploy.sh --skip-apps        # infrastructure only (daemons, searxng, NPM)
#   ./deploy.sh --skip-daemons     # everything except the chain nodes: no
#                                  # bitcoind/monerod/lightningd/monero-wallet-rpc,
#                                  # no wallets (for testing without a chain)
#   ./deploy.sh --no-wallets       # do not prompt for the Monero/Bitcoin wallet
#   ./deploy.sh --dry-run          # print the plan; change nothing
#
# Ordering is load-bearing: the daemons come up before the MCP servers that
# read them, and lightning-mcp's runes are created only once lightningd's RPC
# answers. Chain sync takes hours to days; this script never waits for it --
# when bitcoind is mid-sync it skips the lightningd wait, and you re-run the
# script (idempotent) once the chain is current.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
# shellcheck source=stack.conf
. "$REPO_DIR/stack.conf"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
ONLY=""
DO_BOOTSTRAP=0
DO_WALLETS=1
SKIP_APPS=0
SKIP_DAEMONS=0

BITCOIND_WAIT="${BITCOIND_WAIT:-600}"
# lightningd's bcli plugin starts with RPC while bitcoind is still loading its
# wallet, and dies on the first timeout ("The Bitcoin backend died"). Require
# wallet-level RPC before it depends on bitcoind; the chain RPC alone answers
# long before that (getblockchaininfo is served mid-init).
BITCOIND_WALLET_WAIT="${BITCOIND_WALLET_WAIT:-120}"
MONEROD_WAIT="${MONEROD_WAIT:-300}"
LIGHTNINGD_WAIT="${LIGHTNINGD_WAIT:-900}"
APP_HEALTH_WAIT="${APP_HEALTH_WAIT:-180}"
BITCOIND_READY=0

run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() { usage_header "$REPO_DIR/deploy.sh"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bootstrap)   DO_BOOTSTRAP=1 ;;
        --only)        ONLY="${2:?--only needs a service name}"; shift ;;
        --no-wallets)  DO_WALLETS=0 ;;
        --skip-apps)   SKIP_APPS=1 ;;
        --skip-daemons) SKIP_DAEMONS=1; DO_WALLETS=0 ;;
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
        if [ "$DRY_RUN" = 1 ]; then
            printf '  [dry-run] %s/bootstrap.sh\n' "$REPO_DIR"
        elif [ "$DO_BOOTSTRAP" = 1 ]; then
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

    # Choose where the stack keeps its data (asked once, then remembered) and
    # make sure it is usable: owned by us (containers write as this uid) and
    # labelled for containers. deploy.sh never uses sudo -- bootstrap.sh owns
    # the privileged host setup, and a data dir we cannot prepare is a clear
    # error from lib.sh rather than an implicit prompt here. resolve_data_dir
    # only persists the answer, which it skips on a dry run; creating/labelling
    # the dirs is a real change.
    resolve_data_dir
    log "data directory: $DATA_DIR"
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] would create and label %s\n' "$DATA_DIR"
    else
        ensure_data_dirs
        ensure_data_dir_selinux
    fi
}

# ---------------------------------------------------------------------------
# 1. fetch the application repos
# ---------------------------------------------------------------------------
fetch_repos() { # [repo...]  (default: every APP_REPOS entry)
    mkdir -p "$BUILD_DIR"
    local repos=("$@") r dir
    [ "${#repos[@]}" -gt 0 ] || repos=("${APP_REPOS[@]}")
    for r in "${repos[@]}"; do
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
# `start` is a no-op on an already-active unit, so a redeploy that rebuilt the
# image would keep running the old container. Redeploys restart instead.
restart_unit() { log "restarting $1.service"; run systemctl --user restart "$1.service"; }

wait_healthy() { # container timeout
    local c="$1" t="${2:-180}" deadline st=""
    [ "$DRY_RUN" = 1 ] && return 0

    # Prefer podman's own health wait: it wakes the instant the state changes
    # instead of a shell `sleep 5` loop that spawns podman and date per tick.
    # Only when the container actually defines a healthcheck, else podman has
    # nothing to wait on.
    if podman wait --help 2>/dev/null | grep -q -- '--condition' \
        && [ "$(podman inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$c" 2>/dev/null)" = yes ]; then
        podman wait --condition=healthy --condition=unhealthy --interval 2 --timeout "$t" "$c" >/dev/null 2>&1 || true
        st=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
        case "$st" in
            *"(healthy)"*) log "$c is healthy"; return 0 ;;
        esac
        warn "$c not healthy after ${t}s (status: ${st:-container missing})"
        return 1
    fi

    # Fallback (no podman --condition, or no healthcheck): poll.
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

wait_http() { # description timeout url
    local desc="$1" t="$2" url="$3"
    local deadline
    [ "$DRY_RUN" = 1 ] && return 0
    deadline=$(( $(date +%s) + t ))
    while :; do
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then log "$desc ready"; return 0; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "$desc not ready after ${t}s"
            return 1
        fi
        sleep 2
    done
}

# The host-side loopback port of each MCP server (the interface contract in the
# README: NPM terminates TLS and forwards to these; the servers themselves are
# still 0.0.0.0 inside the container).
app_port() {
    case "$1" in
        searxng-mcp)       echo 8000 ;;
        bitcoin-node-mcp)  echo 8101 ;;
        monero-node-mcp)   echo 8102 ;;
        monero-wallet-mcp) echo 8103 ;;
        lightning-mcp)     echo 8104 ;;
    esac
}

# Print the last lines of a container's log with an indent. Used when a wait
# times out, so the deploy output shows *why* instead of just spinning.
dump_tail() { # container [lines]
    local c="$1" n="${2:-30}"
    [ "$DRY_RUN" = 1 ] && return 0
    warn "last $n log lines from $c:"
    podman logs --tail "$n" "$c" 2>&1 | sed 's/^/  | /'
}

# True while bitcoind is in initial block download. CLN cannot finish starting
# until it is caught up, so waiting on lightningd then is wasted time.
bitcoind_syncing() {
    [ "$DRY_RUN" = 1 ] && return 1
    podman exec bitcoind bitcoin-cli getblockchaininfo 2>/dev/null \
        | grep -q '"initialblockdownload": *true'
}

# Make sure the podman network exists before anything joins it. The quadlet
# unit can be left "active (exited)" while the network itself is gone (e.g. the
# network was removed by hand), and systemd will not re-run it, so a plain
# start of a dependent unit fails. Recreate it from the unit (which pins the
# subnet the tor IP and the rpcallowip/SocksPolicy allowlists rely on).
ensure_network() {
    if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] ensure npm-network exists\n'; return 0; fi
    if podman network exists npm-network 2>/dev/null; then
        log "npm-network present"
        return 0
    fi
    log "creating npm-network"
    systemctl --user reset-failed npm-network-network.service 2>/dev/null || true
    systemctl --user restart npm-network-network.service 2>/dev/null || true
    if ! podman network exists npm-network 2>/dev/null; then
        podman network create --subnet 10.89.0.0/24 --gateway 10.89.0.1 npm-network >/dev/null
    fi
}

# ---------------------------------------------------------------------------
# 3. start the infrastructure, in dependency order
# ---------------------------------------------------------------------------
start_infra() {
    ensure_network
    # tor first: lightningd requires it and addresses it by its pinned IP.
    start_unit tor
    if [ "$SKIP_DAEMONS" = 0 ]; then
        start_unit bitcoind
        start_unit monerod
    fi
    start_unit valkey
    start_unit searxng
    start_unit nginx-proxy-manager

    if [ "$SKIP_DAEMONS" = 1 ]; then
        log "skipping the chain daemons (--skip-daemons)"
        return 0
    fi

    # RPC-level readiness, not sync: getblockchaininfo answers while syncing.
    if wait_cmd "bitcoind RPC" "$BITCOIND_WAIT" podman exec bitcoind bitcoin-cli getblockchaininfo; then
        BITCOIND_READY=1
    else
        warn "continuing without bitcoind RPC (it may still be starting)"
    fi
    wait_healthy monerod "$MONEROD_WAIT" || warn "continuing; monerod may still be syncing"
}

# ---------------------------------------------------------------------------
# 4. wallets (Monero must exist before monero-wallet-rpc can start)
# ---------------------------------------------------------------------------
setup_wallets() {
    if [ "$SKIP_DAEMONS" = 1 ]; then log "skipping wallet setup (--skip-daemons)"; return 0; fi
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
    if [ "$SKIP_DAEMONS" = 1 ]; then log "skipping the chain daemons (--skip-daemons)"; return 0; fi

    # The lightningd image's entrypoint stays alive as PID 1 even after the
    # daemon dies (e.g. its bcli plugin backed into a bitcoind that was still
    # loading its wallet), so the quadlet unit reads "active" and systemd's
    # Restart=always never sees anything to restart. An active unit whose
    # container healthcheck reports unhealthy is exactly that zombie; restart
    # it instead of leaving it in place for the wait below.
    if [ "$DRY_RUN" = 0 ] && systemctl --user is-active --quiet lightningd.service \
        && [ "$(podman inspect -f '{{.State.Health.Status}}' lightningd 2>/dev/null)" = unhealthy ]; then
        warn "lightningd container is up but the daemon is dead inside; restarting it"
        restart_unit lightningd
    else
        start_unit lightningd
    fi

    if [ "$BITCOIND_READY" != 1 ]; then
        warn "bitcoind RPC is not up; not waiting on lightningd"
        warn "the CLN runes (and lightning-mcp's tools) come alive on a later ./deploy.sh run"
    # CLN does not finish starting until bitcoind is caught up, so during
    # initial block download the wait below would burn the whole timeout for
    # nothing. Skip it and let a later re-run create the runes.
    elif bitcoind_syncing; then
        warn "bitcoind is still in initial block download; not waiting on lightningd"
        warn "the CLN runes (and lightning-mcp's tools) come alive on a later ./deploy.sh run"
    # bitcoind was observed to serve chain-level RPC while still loading its
    # wallet; lightningd's bcli timed out on exactly that window and killed
    # lightningd. Wait for wallet-level RPC before anything depends on it.
    elif ! wait_cmd "bitcoind wallet RPC" "$BITCOIND_WALLET_WAIT" \
            podman exec bitcoind bitcoin-cli getwalletinfo; then
        warn "bitcoind wallet RPC not up; not waiting on lightningd"
        warn "the CLN runes (and lightning-mcp's tools) come alive on a later ./deploy.sh run"
        dump_tail bitcoind 20
    else
        wait_cmd "lightningd RPC" "$LIGHTNINGD_WAIT" podman exec lightningd lightning-cli getinfo \
            || { warn "lightningd RPC not up; runes are created on a later ./deploy.sh run"
                 dump_tail lightningd 40; }
    fi

    # monero-wallet-rpc opens the wallet at startup, so it only starts once the
    # wallet file exists (scripts/wallets.sh ensures that).
    start_unit monero-wallet-rpc
    wait_healthy monero-wallet-rpc "${MONERO_WALLET_WAIT:-300}" || warn "monero-wallet-rpc not healthy"

    # Re-run the installer now that lightningd may answer, to mint the runes.
    # install.sh checks the node is reachable, so this is safe either way.
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
    restart_unit "$r"
    # The app images define no podman healthcheck (the app repos own their
    # Containerfiles), so podman never reports "(healthy)" and wait_healthy
    # would burn the whole timeout and then verify. Poll the stack's /health
    # contract on the host loopback port instead -- it answers the moment the
    # server is actually accepting connections.
    local port
    port=$(app_port "$r")
    if [ -n "$port" ]; then
        wait_http "$r health" "$APP_HEALTH_WAIT" "http://127.0.0.1:$port/health" \
            || { warn "$r did not report healthy"; return 1; }
    else
        wait_healthy "$r" "$APP_HEALTH_WAIT" || { warn "$r did not report healthy"; return 1; }
    fi
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
# bootstrap.sh opens FIREWALL_PORTS: it owns every privileged host setting, so
# deploy.sh stays rootless here. Querying firewalld needs privilege, so this can
# only report on it, never check it -- a notice, not a gate.
note_firewall() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        warn "firewall-cmd not found; run ./bootstrap.sh to open ${FIREWALL_PORTS[*]}/tcp"
    elif ! systemctl is-active --quiet firewalld; then
        warn "firewalld is not running; run ./bootstrap.sh to enable it and open ${FIREWALL_PORTS[*]}/tcp"
    else
        log "firewalld ports (${FIREWALL_PORTS[*]}/tcp) are opened by ./bootstrap.sh; re-run it if you changed FIREWALL_PORTS"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
preflight

if [ -n "$ONLY" ]; then
    # A hand-removed network would make every restart below fail; recreate it
    # from the unit exactly as the full deploy does.
    ensure_network
    if in_list "$ONLY" "${APP_REPOS[@]}"; then
        fetch_repos "$ONLY"
        install_units
        deploy_app "$ONLY"
    elif [ "$ONLY" = backup ]; then
        # A one-shot job: install.sh has just (re)enabled the timer; this also
        # runs it once now instead of waiting for the schedule.
        install_units
        start_unit backup
    elif [ "$ONLY" = monitor ]; then
        # Like backup: install.sh has (re)enabled monitor.timer; run the sweep
        # once now. monitor.service is oneshot and takes no arguments.
        install_units
        start_unit monitor
    else
        install_units
        restart_unit "$ONLY"
        only_port=$(app_port "$ONLY")
        if [ -n "$only_port" ]; then
            wait_http "$ONLY health" "$APP_HEALTH_WAIT" "http://127.0.0.1:$only_port/health" || true
        else
            wait_healthy "$ONLY" "$APP_HEALTH_WAIT" || true
        fi
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
note_firewall

if [ "$DRY_RUN" = 1 ]; then
    log "dry run complete; nothing was changed"
    exit 0
fi

log "running verification"
verify_args=()
if [ "$SKIP_DAEMONS" = 1 ]; then verify_args+=(--no-nodes); fi
"$REPO_DIR/verify.sh" ${verify_args[@]+"${verify_args[@]}"} || warn "verification reported problems"

if [ "$SKIP_DAEMONS" = 1 ]; then
    cat <<EOF

Stack deployed (chain daemons skipped).

  Web and MCP:  valkey, searxng, nginx-proxy-manager (80/443/81),
                searxng-mcp 127.0.0.1:8000, bitcoin-node-mcp 127.0.0.1:8101,
                monero-node-mcp 127.0.0.1:8102, monero-wallet-mcp 127.0.0.1:8103,
                lightning-mcp 127.0.0.1:8104

The MCP servers and searxng bind loopback only -- nginx-proxy-manager is the
sole path in (add a proxy host per server by hand in the admin UI on 81). The
MCP tools error until their daemons exist. Drop --skip-daemons to bring up
bitcoind, monerod, lightningd and monero-wallet-rpc.
EOF
else
    cat <<EOF

Stack deployed.

  Daemons and web:  bitcoind, monerod, monero-wallet-rpc, lightningd, tor,
                    valkey, searxng, nginx-proxy-manager
  MCP servers:      searxng-mcp 127.0.0.1:8000, bitcoin-node-mcp 127.0.0.1:8101,
                    monero-node-mcp 127.0.0.1:8102, monero-wallet-mcp 127.0.0.1:8103,
                    lightning-mcp 127.0.0.1:8104
  Exposure:         loopback only; nginx-proxy-manager (80/443/81) is the way in
  Spending:         OFF on both money servers (ENABLE_SPENDING=0)
  Backups:          nightly restic job (backup.timer) -> $STACK_BACKUP_DIR
  Monitoring:       every 5 min (monitor.timer) + spend tripwire; both alert
                    only once $DATA_DIR/config/monitoring/monitor.env is filled in

Chain sync continues in the background (bitcoind is pruned; monerod is
pruned). Re-run ./deploy.sh once the chains are current to finish anything
that was waiting on them.
EOF
fi
