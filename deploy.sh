#!/usr/bin/env bash
# One-click deploy for the whole stack.
#
#   ./deploy.sh                    # fetch repos, install, build every image,
#                                  # start everything, verify
#   ./deploy.sh --bootstrap        # also provision a bare Rocky 10 host first
#   ./deploy.sh --only <name>      # redeploy a single service (app or unit);
#                                  # --only boltmesh rebuilds the whole app tier
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

# git must never prompt mid-deploy: on a host with no credentials that is a
# one-time setup step, not a question, and a prompt would hang the run.
# BatchMode makes ssh fail fast too (no passphrase or host-key prompt). An
# operator-provided GIT_SSH_COMMAND wins.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
# Appended to a fetch failure. The public $GITHUB_ORG repos clone over HTTPS,
# but the private boltmesh-labs ones need SSH.
GIT_CRED_HINT="git could not authenticate (it is not allowed to prompt). The $GITHUB_ORG_BOLTMESH repos are private: run 'ssh -T $GITHUB_SSH_HOST' -- it must greet you -- then re-run ./deploy.sh"
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
POSTGRES_WAIT="${POSTGRES_WAIT:-180}"
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
# One repo, cloned or fast-forwarded into $BUILD_DIR/<dir> from <url>. git must
# never prompt (GIT_TERMINAL_PROMPT/GIT_SSH_COMMAND are exported below): on a
# host without credentials that is a one-time setup step, and a prompt would
# hang the deploy. The remote URL is re-set on every run so a checkout that was
# first cloned over a different protocol (HTTPS -> SSH) heals itself.
fetch_repo() { # url dir label
    local url="$1" dir="$2" label="$3"
    if [ -d "$dir/.git" ]; then
        log "updating $label"
        run git -C "$dir" remote set-url origin "$url"
        run git -C "$dir" pull --ff-only -q \
            || die "could not update $label from $url -- $GIT_CRED_HINT"
    else
        log "cloning $label"
        run git clone -q "$url" "$dir" \
            || die "could not clone $label from $url -- $GIT_CRED_HINT"
    fi
}

fetch_repos() { # [repo...]  (default: every APP_REPOS entry)
    mkdir -p "$BUILD_DIR"
    local repos=("$@") r
    [ "${#repos[@]}" -gt 0 ] || repos=("${APP_REPOS[@]}")
    for r in "${repos[@]}"; do
        fetch_repo "https://github.com/$GITHUB_ORG/$r.git" "$BUILD_DIR/$r" "$r"
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
    # `podman wait` has no --timeout of its own (it was never a flag -- passing
    # one made every wait fail instantly, so the caller always saw "not
    # healthy"), so coreutils `timeout` bounds it; killing the client leaves the
    # container alone. Only when the container defines a healthcheck, else
    # podman has nothing to wait on.
    if command -v timeout >/dev/null 2>&1 \
        && podman wait --help 2>/dev/null | grep -q -- '--condition' \
        && [ "$(podman inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$c" 2>/dev/null)" = yes ]; then
        timeout "$t" podman wait --condition=healthy --condition=unhealthy --interval 2 "$c" >/dev/null 2>&1 || true
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
    # Containerfiles), but every unit here sets HealthCmd/HealthInterval: the
    # MCP servers probe their own /mcp with an authenticated initialize, the
    # BoltMesh tier its own /health. So podman's health status IS the readiness
    # signal, and nothing has to be polled from the host -- which is just as
    # well, because no service publishes a port for the host to poll.
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
# 6b. the BoltMesh app tier (postgres + backend + worker + frontend)
# ---------------------------------------------------------------------------
# Not deploy_app: the BoltMesh repos live in a second org and, while they ship a
# Containerfile, the frontend needs an explicit build target and VITE_* build
# args (inlined into the bundle at build time) that deploy_app does not pass.
# The private boltmesh-labs repos are fetched over SSH (GITHUB_SSH_HOST), unlike
# the public $GITHUB_ORG ones. Same repo:dir pairs as stack.conf.
fetch_boltmesh() { # every BOLTMESH_REPOS entry ("repo:dir" pairs)
    mkdir -p "$BUILD_DIR"
    local pair repo dir
    for pair in "${BOLTMESH_REPOS[@]}"; do
        repo="${pair%%:*}"            # GitHub repo name
        dir="$BUILD_DIR/${pair##*:}"  # local build dir (namespaced)
        fetch_repo "$GITHUB_SSH_HOST:$GITHUB_ORG_BOLTMESH/$repo.git" "$dir" "$repo"
    done
}

# Prefer Containerfile (the stack's contract); Dockerfile is the pre-rename
# name, kept working so a host that pinned an older checkout still builds.
boltmesh_containerfile() { # dir
    if [ -f "$1/Containerfile" ]; then printf '%s' "$1/Containerfile"; else printf '%s' "$1/Dockerfile"; fi
}

build_boltmesh_backend() {
    local dir="$BUILD_DIR/boltmesh-backend" df
    [ -d "$dir" ] || { warn "boltmesh-backend is not cloned under $BUILD_DIR"; return 1; }
    df=$(boltmesh_containerfile "$dir")
    [ -f "$df" ] || { warn "boltmesh-backend has no Containerfile"; return 1; }
    log "building localhost/boltmesh-backend:latest (API and worker share it)"
    run podman build -t localhost/boltmesh-backend:latest -f "$df" "$dir"
}

build_boltmesh_frontend() {
    local dir="$BUILD_DIR/boltmesh-frontend" df
    [ -d "$dir" ] || { warn "boltmesh-frontend is not cloned under $BUILD_DIR"; return 1; }
    df=$(boltmesh_containerfile "$dir")
    [ -f "$df" ] || { warn "boltmesh-frontend has no Containerfile"; return 1; }
    log "building localhost/boltmesh-frontend:latest (target prod, VITE_* baked in)"
    run podman build --target prod \
        --build-arg "VITE_API_URL=https://$BOLTMESH_API_HOST/v1" \
        --build-arg "VITE_APP_COMPANY_NAME=$BOLTMESH_COMPANY_NAME" \
        --build-arg "VITE_APP_SUPPORT_EMAIL=$BOLTMESH_SUPPORT_EMAIL" \
        -t localhost/boltmesh-frontend:latest -f "$df" "$dir"
}

# The four env files the backend/worker read; passed to the one-off migration
# container below. install.sh wrote them, so they exist by the time we run.
boltmesh_env_args() {
    printf '%s\n' \
        "--env-file" "$CONFIG_DIR/boltmesh/db.env" \
        "--env-file" "$CONFIG_DIR/boltmesh/secrets.env" \
        "--env-file" "$CONFIG_DIR/boltmesh/app.env" \
        "--env-file" "$CONFIG_DIR/boltmesh/gateway.env"
}

run_boltmesh_migrations() {
    log "applying BoltMesh database migrations"
    local -a envs=()
    # shellcheck disable=SC2207
    envs=($(boltmesh_env_args))
    run podman run --rm --network npm-network \
        "${envs[@]}" \
        localhost/boltmesh-backend:latest alembic upgrade head
}

deploy_boltmesh() {
    # Failures warn and return 0, exactly like deploy_apps: the deploy brings up
    # as much as it can and verify.sh reports what is actually broken, so one
    # bad build does not abort the rest of the run (or a --dry-run).
    fetch_boltmesh

    if ! build_boltmesh_backend; then
        warn "the BoltMesh backend image did not build; skipping the tier"
        return 0
    fi
    if ! build_boltmesh_frontend; then
        warn "the BoltMesh frontend image did not build; starting the API/worker anyway"
    fi

    start_unit postgres
    wait_healthy postgres "${POSTGRES_WAIT:-180}" \
        || { warn "postgres not healthy"; dump_tail postgres 20; return 0; }

    # Migrations run before the API so it never serves against a missing schema.
    run_boltmesh_migrations || warn "migrations failed; the API may not start cleanly"

    restart_unit boltmesh-backend
    wait_healthy boltmesh-backend "$APP_HEALTH_WAIT" \
        || { warn "boltmesh-backend did not report healthy"; dump_tail boltmesh-backend 40; }

    restart_unit boltmesh-worker
    wait_healthy boltmesh-worker "$APP_HEALTH_WAIT" || warn "boltmesh-worker not healthy"

    restart_unit boltmesh-frontend
    wait_healthy boltmesh-frontend 60 || warn "boltmesh-frontend not healthy"
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
    elif [ "$ONLY" = boltmesh ]; then
        # The whole app tier: fetch, build, migrate, start. Individual members
        # (postgres, boltmesh-backend/-worker/-frontend) fall through to the
        # generic branch below, which restarts the one unit and waits.
        install_units
        deploy_boltmesh
    else
        install_units
        restart_unit "$ONLY"
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
[ "$SKIP_APPS" = 1 ] || deploy_boltmesh
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
                searxng-mcp, bitcoin-node-mcp, monero-node-mcp,
                monero-wallet-mcp, lightning-mcp
  BoltMesh app: postgres, boltmesh-backend, boltmesh-worker,
                boltmesh-frontend

Nothing but nginx-proxy-manager publishes a host port: it reaches every service
by container name on npm-network, and so do ./verify.sh and the monitoring
scripts (add a proxy host per server by hand in the admin UI on 81). The MCP
tools error until their daemons exist. Drop --skip-daemons to bring up bitcoind,
monerod, lightningd and monero-wallet-rpc.
EOF
else
    cat <<EOF

Stack deployed.

  Daemons and web:  bitcoind, monerod, monero-wallet-rpc, lightningd, tor,
                    valkey, searxng, nginx-proxy-manager
  MCP servers:      searxng-mcp, bitcoin-node-mcp, monero-node-mcp,
                    monero-wallet-mcp, lightning-mcp
  BoltMesh app:     postgres, boltmesh-backend, boltmesh-worker,
                    boltmesh-frontend
  Exposure:         nothing but nginx-proxy-manager (80/443/81); every service
                    is reached by container name on npm-network
  Spending:         OFF on both money servers (ENABLE_SPENDING=0)
  Backups:          nightly restic job (backup.timer) -> $STACK_BACKUP_DIR
  Monitoring:       every 5 min (monitor.timer) + spend tripwire; both alert
                    only once $DATA_DIR/config/monitoring/monitor.env is filled in

Chain sync continues in the background (bitcoind is pruned; monerod is
pruned). Re-run ./deploy.sh once the chains are current to finish anything
that was waiting on them.
EOF
fi
