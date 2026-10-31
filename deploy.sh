#!/usr/bin/env bash
# One-click deploy for the whole stack.
#
#   ./deploy.sh                    # fetch repos, install, build every image,
#                                  # start everything, verify
#   ./deploy.sh --bootstrap        # also provision a bare Rocky 10 host first
#   ./deploy.sh --only <name>      # redeploy a single service (app or unit);
#                                  # --only boltmesh rebuilds the whole app tier;
#                                  # --only explorers rebuilds both explorer
#                                  # images, --only btc-explorer /
#                                  # --only xmr-explorer just one (and restarts it)
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
# Where deploy/install.sh renders the units. Read here to compare a running
# container's network mode with the one its unit asks for (see sync_npm_network),
# and to notice a unit whose definition changed (restart_changed_units).
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
# Set by restart_changed_units when nginx-proxy-manager's unit changed.
NPM_UNIT_CHANGED=0
# shellcheck source=stack.conf
. "$REPO_DIR/stack.conf"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"

# Fallbacks for a manifest that predates the log block, so the summary below
# still prints something true (install.sh carries the same defaults, and a
# rendered unit must not fail on a stale checkout).
LOGS_RETENTION="${LOGS_RETENTION:-14d}"
LOGS_MAX_BYTES="${LOGS_MAX_BYTES:-10GiB}"

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

# The two blockchain explorers. Their images are built from this repo (not
# pulled), so they are deployed like the app tier -- after the daemons they
# read -- and only when their image is missing, unless --only forces a rebuild.
EXPLORER_UNITS=(btc-explorer xmr-explorer)
EXPLORER_WAIT="${EXPLORER_WAIT:-180}"

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

# A *running* container keeps the definition it started with: re-rendering a unit
# changes nothing until that unit restarts. Digest the rendered files either side
# of install.sh so deploy.sh can restart exactly the units whose definition
# changed -- and only those, because a redeploy must not bounce bitcoind for an
# untouched unit.
unit_digest() {
    [ -d "$QUADLET_DIR" ] || return 0
    ( cd "$QUADLET_DIR" && sha256sum -- *.container 2>/dev/null ) || true
    # torrc is not a unit, but a running tor keeps the config it started with all
    # the same -- and the onion services are declared in stack.conf and rendered
    # into it. Hash it under a pseudo-name whose stem is the unit ("tor"), so
    # restart_changed_units restarts tor when a hidden service was added, removed
    # or retargeted.
    if [ -s "$DATA_DIR/tor/torrc" ]; then
        sha256sum -- "$DATA_DIR/tor/torrc" | awk '{ print $1 " tor.unit" }'
    fi
    # The crowdsec config is not a unit either, and the container reads it only
    # at start: a changed parser, scenario or whitelist would otherwise wait for
    # the next reboot. One digest over the rendered tree, under the stem
    # "crowdsec", so restart_changed_units bounces exactly that unit.
    if [ -d "$DATA_DIR/config/ids/crowdsec" ]; then
        find "$DATA_DIR/config/ids/crowdsec" -type f -print0 2>/dev/null \
            | sort -z | xargs -0 -r sha256sum 2>/dev/null \
            | sha256sum | awk '{ print $1 " crowdsec.unit" }'
    fi
    # The log shipper's config is rendered by install.sh, not mounted from the
    # repo, and Vector reads it only at start (there is no reload). Hash it under
    # the unit's stem so a changed transform restarts exactly that unit, the same
    # contract as crowdsec's tree.
    if [ -s "$DATA_DIR/config/logs/vector/vector.toml" ]; then
        sha256sum -- "$DATA_DIR/config/logs/vector/vector.toml" | awk '{ print $1 " vector.unit" }'
    fi
}

# .container only, never *.network: a network cannot be restarted under the
# containers that use it. A oneshot unit is inactive and gets skipped by the
# is-active check; a unit that is not running yet is started later, in order, by
# start_infra/start_daemons -- restarting it here would jump that order (e.g.
# lightningd before bitcoind). nginx-proxy-manager is only flagged: its restart
# has to follow the proxy-host rewrite (sync_npm_network).
restart_changed_units() { # before-digest after-digest
    local before="$1" after="$2" file unit restarted=" "
    [ -n "$before" ] && [ -n "$after" ] || return 0
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        unit="${file%.*}"
        if [ "$unit" = nginx-proxy-manager ]; then
            NPM_UNIT_CHANGED=1
            continue
        fi
        # A unit can be named by two rendered files (tor.container and the torrc
        # digest above, which both mean tor): restart it once.
        case "$restarted" in *" $unit "*) continue ;; esac
        systemctl --user is-active --quiet "$unit.service" 2>/dev/null || continue
        restarted="$restarted$unit "
        log "$unit.service changed; restarting it to pick up the new unit"
        restart_unit "$unit"
        if [ "$(podman inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$unit" 2>/dev/null)" = yes ]; then
            wait_healthy "$unit" "$APP_HEALTH_WAIT" || warn "$unit did not report healthy"
        fi
    done < <(awk 'NR==FNR { old[$2] = $1; next }
                  ($2 in old) && old[$2] != $1 { print $2 }' \
                 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
}

# ---------------------------------------------------------------------------
# helpers for the runtime steps
# ---------------------------------------------------------------------------
start_unit() { log "starting $1.service"; run systemctl --user start "$1.service"; }
# `start` is a no-op on an already-active unit, so a redeploy that rebuilt the
# image would keep running the old container. Redeploys restart instead.
restart_unit() { log "restarting $1.service"; run systemctl --user restart "$1.service"; }

# A locally-built image can be rebuilt while its unit stays identical: that is
# the whole point of install.sh's Containerfile label, and a bare
# ./deploy/install.sh leaves the old container behind with no unit digest to
# notice. So compare what the container is actually running with the image on
# disk and restart when they differ -- `start` alone is a no-op on an active
# unit, which is what would otherwise keep the old bits forever.
refresh_image_unit() { # container image -> restart when the container is older
    local name="$1" image="$2" running current
    [ "$DRY_RUN" = 0 ] || return 0
    podman container exists "$name" 2>/dev/null || return 0
    systemctl --user is-active --quiet "$name.service" 2>/dev/null || return 0
    running=$(podman inspect "$name" --format '{{.Image}}' 2>/dev/null || true)
    current=$(podman image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)
    if [ -z "$running" ] || [ -z "$current" ] || [ "$running" = "$current" ]; then
        return 0
    fi
    log "$name is running an older $image; restarting it"
    restart_unit "$name"
    wait_healthy "$name" "$APP_HEALTH_WAIT" || true
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

# The `--only` branches run their checks (verify.sh inside the monitor sweep,
# npm-hosts, kuma-monitors, the app health handshakes) through the two curl
# clients, and never reach start_infra. Start them here -- a start is a no-op
# when they are already up -- so `./deploy.sh --only monitor` on a freshly
# booted host does not fail with "netcheck is not running".
ensure_netcheck() {
    [ "$DRY_RUN" = 1 ] && return 0
    # A rebuilt image would otherwise never reach the running container (start
    # is a no-op on an active unit); the same refresh start_infra does.
    refresh_image_unit netcheck "$NETCHECK_IMAGE"
    refresh_image_unit netcheck-host "$NETCHECK_IMAGE"
    systemctl --user start netcheck.service netcheck-host.service 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 3. start the infrastructure, in dependency order
# ---------------------------------------------------------------------------
start_infra() {
    ensure_network
    # The curl clients every host-side check execs into. First, because the
    # checks that read a service by name (verify.sh, npm-hosts.sh,
    # kuma-monitors.sh, the MCP handshakes) all go through them, and
    # refresh_image_unit because install.sh rebuilds the image in place: a
    # `start` on an already-active unit would keep the old bits.
    refresh_image_unit netcheck "$NETCHECK_IMAGE"
    start_unit netcheck
    refresh_image_unit netcheck-host "$NETCHECK_IMAGE"
    start_unit netcheck-host
    # Monitoring first: it depends on nothing, it is cheap, and starting it
    # before the daemons is what puts a whole initial sync in the history
    # instead of beginning mid-way through it.
    start_unit node-exporter
    start_unit victoriametrics
    # Alertmanager: the monitor pushes into it, and the monitor's first sweep
    # may land before this line, so starting it here (a start is a no-op when
    # active) keeps a fresh host from logging "Alertmanager unreachable" on its
    # very first run.
    start_unit alertmanager
    # The log pipeline: journald -> vector -> victoria-logs. Same reasoning as
    # the metrics store -- it depends on nothing, and starting it before the
    # daemons is what captures their first minutes. vector buffers and retries
    # if the store is not up yet, so the order inside this pair is not gating.
    start_unit victoria-logs
    start_unit vector
    # tor first: lightningd requires it and addresses it by its pinned IP. Its
    # image is the one install.sh rebuilds in place, so bounce it first when the
    # container predates the image (see refresh_image_unit).
    refresh_image_unit tor "$TOR_IMAGE"
    start_unit tor
    if [ "$SKIP_DAEMONS" = 0 ]; then
        start_unit bitcoind
        start_unit monerod
    fi
    start_unit valkey
    start_unit searxng
    start_unit uptime-kuma
    start_unit nginx-proxy-manager
    # CrowdSec reads nginx-proxy-manager's access log, so it starts after the
    # proxy does (the log directory is NPM's). Nothing gates on it: a crowdsec
    # that fails to start leaves detection off, not the site down, and
    # scripts/monitor.sh reports the stale status.
    start_unit crowdsec

    if [ "$SKIP_DAEMONS" = 1 ]; then
        log "skipping the chain daemons (--skip-daemons)"
        return 0
    fi

    # RPC-level readiness, not sync: getblockchaininfo answers while syncing.
    if wait_cmd "bitcoind RPC" "$BITCOIND_WAIT" podman exec bitcoind bitcoin-cli getblockchaininfo; then
        BITCOIND_READY=1
        # Fulcrum indexes from bitcoind's RPC and follows it through IBD, so it
        # can be started now; it opens its Electrum ports only once caught up.
        start_unit fulcrum
        wait_healthy fulcrum 60 || warn "fulcrum is still starting; check: podman logs fulcrum"
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
    # Restart=always never sees anything to restart. The unit's
    # HealthOnFailure=kill is what ends that container now; this check stays as
    # the fallback for one created before that line existed, since an active
    # unit whose healthcheck reports unhealthy is exactly that zombie.
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
    # signal, and this never polls an app through nginx-proxy-manager.
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
# 6b-bis. the blockchain explorers
# ---------------------------------------------------------------------------
# BTC RPC Explorer and MoneroBlock are local images (btc-explorer/ and
# xmr-explorer/ Containerfiles), not pulled ones, so they are built here like
# the app tier rather than by install.sh. They read the daemons over RPC, so
# they come after start_daemons; they are built only when the image is missing
# (a rebuild is --only). Nothing here is secret: the BTC unit reads its RPC
# credentials from an EnvironmentFile install.sh seeded.
build_explorer() { # name [force]
    local name="$1" force="${2:-0}" dir="$REPO_DIR/$1" image
    case "$name" in
        btc-explorer) image="$BTC_EXPLORER_IMAGE" ;;
        xmr-explorer) image="$XMR_EXPLORER_IMAGE" ;;
        *) warn "unknown explorer: $name"; return 1 ;;
    esac
    [ -f "$dir/Containerfile" ] || { warn "$name has no Containerfile"; return 1; }
    # "exists" is not enough: a digest bump changes only the Containerfile, so
    # an unlabelled or label-mismatched image is the old bits under the same
    # local tag. See scripts/lib.sh's image_is_current.
    if [ "$force" = 0 ] && image_is_current "$image" "$dir/Containerfile"; then
        log "$image is current"
        return 0
    fi
    if [ "$force" = 0 ]; then
        log "$image is stale: its Containerfile changed since it was built"
    fi
    log "building $image"
    if [ "$name" = xmr-explorer ]; then
        log "MoneroBlock is a small Go build; no Monero compile"
    fi
    run podman build --label "$(image_inputs_label "$dir/Containerfile")" \
        -t "$image" "$dir"
}

deploy_explorers() {
    if [ "$SKIP_DAEMONS" = 1 ]; then
        log "skipping the blockchain explorers (--skip-daemons)"
        return 0
    fi
    local name
    for name in "${EXPLORER_UNITS[@]}"; do
        build_explorer "$name" \
            || { warn "$name did not build; the other explorer continues"; continue; }
        restart_unit "$name"
        wait_healthy "$name" "$EXPLORER_WAIT" \
            || { warn "$name did not report healthy"; dump_tail "$name" 30; }
    done
}

# ---------------------------------------------------------------------------
# 6c. the nginx-proxy-manager proxy hosts
# ---------------------------------------------------------------------------
# Not a unit: nginx-proxy-manager already serves. Every backend it fronts
# publishes its port on the host's loopback, where NPM (on the host network)
# forwards -- so this only configures NPM, through its admin API, to serve the
# hosts declared in NPM_HOSTS. It runs before the explorers so their proxy hosts
# exist even while their images build: NPM does not connect to a loopback
# upstream until a request arrives. It self-skips with a one-line note when
# $DATA_DIR/config/npm/api.env has no credentials, so a fresh host deploys
# before the admin login exists.
configure_npm_hosts() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] %s\n' "$REPO_DIR/scripts/npm-hosts.sh"
        return 0
    fi
    "$REPO_DIR/scripts/npm-hosts.sh" \
        || warn "the proxy hosts were not (re)configured; see scripts/npm-hosts.sh"
}

# The status page's monitors: declared in KUMA_MONITORS (stack.conf), reconciled
# into uptime-kuma by scripts/kuma-monitors.sh. Runs after the proxy hosts are
# rewritten (the monitors probe the public URLs) and self-skips with a one-line
# note while $DATA_DIR/config/uptime-kuma/api.env has no login -- like
# configure_npm_hosts, a fresh host deploys before the UI-first registration.
kuma_monitors() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] %s\n' "$REPO_DIR/scripts/kuma-monitors.sh"
        return 0
    fi
    "$REPO_DIR/scripts/kuma-monitors.sh" \
        || warn "the status-page monitors were not (re)reconciled; see scripts/kuma-monitors.sh"
}

# ---------------------------------------------------------------------------
# 6d. nginx-proxy-manager's network mode
# ---------------------------------------------------------------------------
# A unit change is not picked up by an already-running container, so a host that
# served from the old published-port layout keeps doing so until NPM restarts.
# That restart must come *after* the rewrite above and never before: NPM's nginx
# resolves every upstream at start and refuses to come up when a saved host names
# something it cannot resolve -- on the host network, a container name. That also
# takes the admin API on :81 down (same nginx), leaving the rewrite with nothing
# to talk to, so the order is load-bearing.
sync_npm_network() {
    local want got why=""
    want=$(sed -n 's/^Network=//p' "$QUADLET_DIR/nginx-proxy-manager.container" 2>/dev/null | head -n1 || true)
    [ -n "$want" ] || return 0
    got=$(podman inspect nginx-proxy-manager --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)
    [ -n "$got" ] || return 0    # not running: whenever it starts, it starts on the new unit
    if [ "$got" != "$want" ]; then why="its unit asks for '$want', not '$got'"
    elif [ "$NPM_UNIT_CHANGED" = 1 ]; then why="its unit changed"
    else return 0
    fi
    log "restarting nginx-proxy-manager: $why"
    restart_unit nginx-proxy-manager
    wait_healthy nginx-proxy-manager 120 || warn "nginx-proxy-manager did not report healthy"
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
    ensure_netcheck
    if in_list "$ONLY" "${APP_REPOS[@]}"; then
        fetch_repos "$ONLY"
        install_units
        deploy_app "$ONLY"
    elif [ "$ONLY" = backup ]; then
        # A one-shot job: install.sh has just (re)enabled the timer; this also
        # runs it once now instead of waiting for the schedule.
        install_units
        start_unit backup
    elif [ "$ONLY" = backup-verify ]; then
        # The weekly restore drill (scripts/backup.sh verify): run one now rather
        # than waiting for Sunday. It reads only the repository, so it is safe on
        # a host whose stack is serving; the verdict lands in
        # $DATA_DIR/audit/backup-verify.status.
        install_units
        start_unit backup-verify
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
    elif [ "$ONLY" = explorers ]; then
        # Both explorer images, rebuilt even if they exist (their Containerfiles
        # are the only place their versions live).
        install_units
        for name in "${EXPLORER_UNITS[@]}"; do
            build_explorer "$name" 1 || continue
            restart_unit "$name"
            wait_healthy "$name" "$EXPLORER_WAIT" || true
        done
    elif [ "$ONLY" = btc-explorer ] || [ "$ONLY" = xmr-explorer ]; then
        # One explorer: rebuild its image and restart only that unit. The
        # generic branch below would skip the build and keep the old image.
        install_units
        build_explorer "$ONLY" 1
        restart_unit "$ONLY"
        wait_healthy "$ONLY" "$EXPLORER_WAIT" || true
    elif [ "$ONLY" = npm-hosts ]; then
        # Re-apply the proxy hosts after a stack.conf change, or after filling
        # in $DATA_DIR/config/npm/api.env. Touches no container.
        install_units
        configure_npm_hosts
    elif [ "$ONLY" = kuma-monitors ]; then
        # Reconcile the status page's monitors after a KUMA_MONITORS change, or
        # after filling in $DATA_DIR/config/uptime-kuma/api.env. Touches no
        # container, but reaches uptime-kuma by name, so the network stays up.
        install_units
        kuma_monitors
    else
        install_units
        restart_unit "$ONLY"
        wait_healthy "$ONLY" "$APP_HEALTH_WAIT" || true
    fi
    log "done (--only $ONLY)"
    exit 0
fi

fetch_repos
units_before=$(unit_digest)
install_units
restart_changed_units "$units_before" "$(unit_digest)"
start_infra
setup_wallets
start_daemons
[ "$SKIP_APPS" = 1 ] || deploy_apps
[ "$SKIP_APPS" = 1 ] || deploy_boltmesh
# Configure the proxy hosts before the explorers: their images are local builds,
# and the rest of the public surface must not wait for them. The explorer hosts
# point at loopback ports, so NPM starts fine before the containers do; kuma's
# monitors run after deploy_explorers so they see them up.
configure_npm_hosts
sync_npm_network
deploy_explorers
kuma_monitors
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
  Explorers:    skipped with the chain daemons (--skip-daemons)

nginx-proxy-manager is the only HTTP service a client reaches: it runs on the
host network, so it binds 80/443/81 itself and every request keeps the client's
real address. Every service it fronts publishes its port on the host's loopback,
which is where NPM's proxy hosts point. Fulcrum's Electrum ports 50001 (TCP) and
50002 (SSL) are the one non-HTTP exception, opened directly on the LAN because
NPM cannot proxy the Electrum protocol. ./verify.sh and the monitoring scripts
read the other services by container name on npm-network.
The MCP servers are served as https://$MCP_HOST/<prefix> once
  $DATA_DIR/config/npm/api.env has the NPM admin login (scripts/npm-hosts.sh
  applies every proxy host in NPM_HOSTS).
The status page's monitors are reconciled once
  $DATA_DIR/config/uptime-kuma/api.env has the Uptime-Kuma admin login
  (scripts/kuma-monitors.sh applies every monitor in KUMA_MONITORS).
The MCP tools error until their daemons exist. Drop --skip-daemons to bring up
bitcoind, monerod, fulcrum, lightningd and monero-wallet-rpc.
EOF
else
    cat <<EOF

Stack deployed.

  Daemons and web:  bitcoind, monerod, fulcrum, monero-wallet-rpc, lightningd,
                    tor, valkey, searxng, nginx-proxy-manager
  MCP servers:      searxng-mcp, bitcoin-node-mcp, monero-node-mcp,
                    monero-wallet-mcp, lightning-mcp
  BoltMesh app:     postgres, boltmesh-backend, boltmesh-worker,
                    boltmesh-frontend
  Explorers:        https://$BTC_EXPLORER_HOST (BTC RPC Explorer: bitcoind RPC
                    + Fulcrum for address history) and
                    https://$XMR_EXPLORER_HOST (MoneroBlock: monerod's
                    restricted RPC)
  Exposure:         nginx-proxy-manager (80/443/81) plus Fulcrum's Electrum
                    ports 50001 (TCP) / 50002 (SSL). NPM runs on the host
                    network, so it keeps clients' real addresses; everything it
                    fronts is on the host's loopback (see NPM_HOSTS in
                    stack.conf). Fulcrum is the one non-HTTP LAN surface
  Electrum:         point a Bitcoin wallet at this host on 50001 (TCP) or
                    50002 (SSL, self-signed). Fulcrum indexes alongside
                    bitcoind and accepts wallets once its index has caught up
                    (podman logs fulcrum)
  MCP over NPM:     https://$MCP_HOST/<searxng|bitcoin|monero|monero-wallet|lightning>
                    once $DATA_DIR/config/npm/api.env has the NPM admin login
  Onion (no DNS):   the same surface as http://<onion>.onion/ (ONION_SERVICES in
                    stack.conf); the addresses are printed below once tor has
                    published them
  Status page:      uptime-kuma on https://$UPTIME_KUMA_HOST, its monitors
                    declared in KUMA_MONITORS in stack.conf and reconciled
                    once $DATA_DIR/config/uptime-kuma/api.env has the login
  Spending:         OFF on both money servers (ENABLE_SPENDING=0)
  Backups:          nightly restic job (backup.timer) -> $STACK_BACKUP_DIR;
                    weekly restore drill (backup-verify.timer), verdict in
                    $DATA_DIR/audit/backup-verify.status
  Monitoring:       every 5 min (monitor.timer) + spend tripwire, pushed to
                    alertmanager (loopback :9093); mail once SMTP is filled in
                    $DATA_DIR/config/monitoring/alertmanager/alertmanager.yml
                    (scripts/monitor.sh --test proves the path)
  Metrics:          every minute (metrics.timer) into victoriametrics, which is
                    loopback-only by design -- read it over an SSH tunnel:
                    ssh -L 8428:127.0.0.1:8428 <host>, then
                    http://127.0.0.1:8428/vmui (30d of history)
  Logs:             journald -> vector -> victoria-logs, ${LOGS_RETENTION} or
                    ${LOGS_MAX_BYTES} (whichever comes first), also loopback-only:
                    scripts/logs.sh --since 1h, or ssh -L 9428:127.0.0.1:9428
                    <host> then http://127.0.0.1:9428/select/vmui

Chain sync continues in the background (both daemons are full nodes, so the
first sync downloads and validates the whole Bitcoin and Monero chains). Re-run
./deploy.sh once the chains are current to finish anything that was waiting on
them.
EOF
fi

# The onion addresses are key material, not configuration (they appear only once
# tor has started), so they cannot live in stack.conf or a README. Print them when
# they exist; scripts/npm-hosts.sh prints the same list on its own.
if [ "${ONION_SERVICES+x}" = x ] && [ "${#ONION_SERVICES[@]}" -gt 0 ]; then
    onion_lines=""
    for entry in "${ONION_SERVICES[@]}"; do
        IFS='|' read -r name _target mirrors _rest <<<"$entry"
        addrfile="$DATA_DIR/tor/onion/$name/hostname"
        if [ -s "$addrfile" ]; then
            onion_lines="${onion_lines}  http://$(tr -d '\r\n' < "$addrfile")  ($mirrors)"$'\n'
        fi
    done
    if [ -n "$onion_lines" ]; then
        printf '\nOnion services (no DNS, no certificates):\n%s' "$onion_lines"
    else
        printf '\nOnion services: tor has not published its addresses yet (see podman logs tor);\nscripts/npm-hosts.sh prints them once they exist.\n'
    fi
fi
