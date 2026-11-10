#!/usr/bin/env bash
# One-click deploy for the whole stack: units, images, start/restart.
#
#   ./deploy.sh                    # fetch repos, install, build every image,
#                                  # start everything; restarts only what changed
#   ./deploy.sh --bootstrap        # also provision a bare Rocky 10 host first
#   ./deploy.sh --only <name>      # redeploy a single service (app or unit);
#                                  # --only boltmesh rebuilds the whole app tier;
#                                  # --only explorers rebuilds both explorer
#                                  # images, --only btc-explorer /
#                                  # --only xmr-explorer just one (and restarts it)
#   ./deploy.sh --skip-apps        # infrastructure only (daemons, searxng, NPM)
#   ./deploy.sh --skip-daemons     # everything except the chain nodes: no
#                                  # bitcoind/monerod/lightningd/btcpay
#                                  # (for testing without a chain)
#   ./deploy.sh --skip-agent-skills # do not link the agent skills / agent-mcp
#                                  # into the operator's harnesses ($HOME)
#   ./deploy.sh --dry-run          # print the plan; change nothing
#
# This script deploys; it does not verify. It never waits for a container's
# health or for a daemon to sync: `./verify.sh` (and monitor.timer) own the
# health verdict. Work that can only happen against a running service -- the
# Bitcoin wallet, the CLN runes, the BTCPay databases/plugin wallet/bootstrap
# and the BoltMesh migrations -- is the second step, `./configure.sh`:
#
#   ./deploy.sh && ./configure.sh
#
# Ordering is load-bearing: the daemons are started before the MCP servers that
# read them, and a changed definition is applied by the phase that rebuilt its
# image. A service that is not answering yet is configure.sh's problem.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
# Where deploy/install.sh renders the units (docs/units.md). Read here to
# compare a running container's network mode with its unit's (sync_npm_network);
# unit digests come from scripts/lib.sh's unit_digest, which defaults to this
# path.
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
# Set by restart_changed_units when nginx-proxy-manager's unit changed.
NPM_UNIT_CHANGED=0
# The units this run restarted, space-delimited with a leading space (" bitcoind
# tor "). units_commit compares it with the changed set so the baseline never
# claims a restart that did not happen; refresh_image_unit skips a unit the
# digest pass already restarted.
APPLIED_UNITS=" "
# Unit stems whose rendered definition differs from the applied baseline, and
# the subset active when the digest pass ran. A changed unit is restarted by the
# phase that owns it, after its build, never twice.
CHANGED_UNITS=""
CHANGED_ACTIVE_UNITS=""
# The digest set last reconciled with the running containers, and whether
# install.sh ran at all (the agent-skills branch runs no installer, so it must
# not record a baseline it never applied).
UNITS_SYNCED=0
UNITS_APPLIED_DIGEST=""
# shellcheck source=stack.conf
. "$REPO_DIR/stack.conf"
# shellcheck source=scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
# The public surface (the *_HOST names, the MCP prefixes, the onion services) is
# declared in deploy/services.toml; stack.conf keeps the non-registry knobs.
load_manifest "$REPO_DIR"

# Fallbacks for a manifest that predates the log block: install.sh carries the
# same defaults, and a rendered unit must not fail on a stale checkout.
LOGS_RETENTION="${LOGS_RETENTION:-14d}"
LOGS_MAX_BYTES="${LOGS_MAX_BYTES:-10GiB}"

# git must never prompt mid-deploy -- a prompt would hang the run; BatchMode
# makes ssh fail fast too. An operator-provided GIT_SSH_COMMAND wins.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
# Appended to a fetch failure: the private boltmesh-labs repos need SSH.
GIT_CRED_HINT="git could not authenticate (it is not allowed to prompt). The $GITHUB_ORG_BOLTMESH repos are private: run 'ssh -T $GITHUB_SSH_HOST' -- it must greet you -- then re-run ./deploy.sh"
ONLY=""
DO_BOOTSTRAP=0
DO_AGENT_SKILLS=1
SKIP_APPS=0
SKIP_DAEMONS=0

# The two blockchain explorers: built from this repo, not pulled, so they deploy
# after the daemons they read and rebuild only when --only asks.
EXPLORER_UNITS=(btc-explorer xmr-explorer)

run()  { if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

usage() { usage_header "$REPO_DIR/deploy.sh"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --bootstrap)   DO_BOOTSTRAP=1 ;;
        --only)        ONLY="${2:?--only needs a service name}"; shift ;;
        --skip-agent-skills) DO_AGENT_SKILLS=0 ;;
        --skip-apps)   SKIP_APPS=1 ;;
        --skip-daemons) SKIP_DAEMONS=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

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

    # deploy.sh never uses sudo: bootstrap.sh owns the privileged host setup,
    # and a data dir we cannot prepare is an error from lib.sh, never an
    # implicit prompt. resolve_data_dir only persists the answer (skipped on a
    # dry run); creating and labelling the dirs is a real change.
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
# One repo, cloned or fast-forwarded into $BUILD_DIR/<dir> from <url>. The
# remote URL is re-set on every run, so a checkout first cloned over another
# protocol (HTTPS vs SSH) heals itself.
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

# install.sh + the digest comparison, for every `--only` branch. A re-render is
# not an application -- a running container keeps the definition it started with
# (docs/units.md) -- so the baseline is the render last *applied*
# ($DATA_DIR/audit/units.applied, see units_baseline), advanced at the end of
# the branch by units_commit: a branch whose own restart fails must not record
# success. Defined before the functions it calls on purpose: bash resolves those
# at call time.
sync_units() {
    local before after
    before=$(units_baseline)
    install_units
    after=$(unit_digest)
    restart_changed_units "$before" "$after"
    UNITS_APPLIED_DIGEST="$after"
    UNITS_SYNCED=1
    # restart_changed_units only flags nginx-proxy-manager: its restart has to
    # follow the proxy-host rewrite (sync_npm_network says why). A --only branch
    # does not rewrite the hosts, so leave it to `--only npm-hosts` or a full
    # deploy, in the right order -- except `--only nginx-proxy-manager` itself,
    # whose branch restarts it after this returns.
    if [ "${NPM_UNIT_CHANGED:-0}" = 1 ] && [ "${ONLY:-}" != npm-hosts ] \
        && [ "${ONLY:-}" != nginx-proxy-manager ]; then
        warn "nginx-proxy-manager's unit changed; its restart is deferred -- run ./deploy.sh (or ./deploy.sh --only npm-hosts) to apply it"
    fi
    # Last, not in the --only prologue: install.sh runs inside install_units and
    # *rebuilds* the netcheck image when its Containerfile changed, so a refresh
    # before it compares against the old image, finds them equal and does
    # nothing. It also keeps `--only monitor` on a fresh host from starting
    # netcheck before its image exists. agent-skills is the one branch that does
    # not need it.
    ensure_netcheck
}

# Record the render this run applied: at the end of a full deploy and of every
# --only branch that ran install.sh, never on a dry run, and never after a
# failure. A baseline that advances past a restart that did not happen is the
# silent-stale-config bug this manifest exists to prevent -- so a changed unit
# no phase restarted keeps its own line where it is (unit_digest_hold) instead of
# holding back the whole file: withholding all of it makes the next run restart
# every unit this one applied.
units_commit() {
    local now unit pending="" record
    [ "$DRY_RUN" = 0 ] || return 0
    [ "$UNITS_SYNCED" = 1 ] || return 0
    # install.sh is also runnable by hand, so a render can land after the digest
    # pass and change a definition without restart_changed_units seeing it.
    # Catch it up before recording. Every phase has run by now, so a changed
    # unit still unapplied has no owner left: clear DEFER_UNITS and restart it
    # here.
    now=$(unit_digest)
    if [ "$now" != "$UNITS_APPLIED_DIGEST" ]; then
        DEFER_UNITS=""
        restart_changed_units "$UNITS_APPLIED_DIGEST" "$now"
        UNITS_APPLIED_DIGEST="$now"
    fi
    # A branch that did not reach sync_npm_network leaves NPM's new unit
    # unapplied on purpose (the next full deploy restarts it, after the rewrite).
    if [ "${NPM_UNIT_CHANGED:-0}" = 1 ] && [ "${ONLY:-}" != npm-hosts ]; then
        pending="$pending nginx-proxy-manager "
    fi
    # A changed unit that was active had to be restarted to apply its
    # definition. If no phase did, its baseline line stays put.
    for unit in $CHANGED_ACTIVE_UNITS; do
        unit_applied "$unit" || pending="$pending$unit "
    done
    if [ -n "$pending" ]; then
        if record=$(unit_digest_hold "$UNITS_APPLIED_DIGEST" \
            "$(unit_applied_read)" "$pending"); then
            UNITS_APPLIED_DIGEST="$record"
            warn "not applied yet; their baseline lines stay put:$pending"
        else
            warn "not recording the applied-unit baseline: still unapplied:$pending"
            return 0
        fi
    fi
    unit_digest_write "$DATA_DIR/audit/units.applied" "$UNITS_APPLIED_DIGEST"
    log "recorded the applied-unit baseline ($DATA_DIR/audit/units.applied)"
}

# ---------------------------------------------------------------------------
# what changed, and what this run applied
# ---------------------------------------------------------------------------
# The digest pass records the changed set once; every later phase asks these.
# mark_* are idempotent because one unit can be named by two rendered files
# (tor.container and the torrc digest).
unit_was_changed() { unit_in_set "$1" "$CHANGED_UNITS"; }
unit_applied() { unit_in_set "$1" "$APPLIED_UNITS"; }
mark_changed() { unit_was_changed "$1" || CHANGED_UNITS="$CHANGED_UNITS$1 "; }
mark_changed_active() {
    unit_in_set "$1" "$CHANGED_ACTIVE_UNITS" || CHANGED_ACTIVE_UNITS="$CHANGED_ACTIVE_UNITS$1 "
}
mark_applied() { unit_applied "$1" || APPLIED_UNITS="$APPLIED_UNITS$1 "; }

# Is the container running the image currently tagged IMAGE? The app phases need
# it separately because they build first, then decide whether to restart at all.
image_is_running() { # container image
    local name="$1" image="$2" running current
    podman container exists "$name" 2>/dev/null || return 1
    running=$(podman inspect "$name" --format '{{.Image}}' 2>/dev/null || true)
    current=$(podman image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)
    [ -n "$running" ] && [ -n "$current" ] && [ "$running" = "$current" ]
}

# Restart a unit only when this run changed it: its rendered definition differs
# from the baseline, or it runs an image older than the tag now points at. A
# rebuilt but unchanged image would otherwise take every app down for nothing.
# An unchanged, stopped unit is started. Nothing here waits for health.
restart_applied() { # unit image [force]
    local unit="$1" image="$2" force="${3:-0}"
    # An earlier phase (the digest pass) may have restarted it: one per run.
    if [ "$force" = 0 ] && unit_applied "$unit" \
        && systemctl --user is-active --quiet "$unit.service" 2>/dev/null \
        && image_is_running "$unit" "$image"; then
        log "$unit was already restarted this run; not restarting it again"
        return 0
    fi
    if [ "$force" = 1 ] || unit_was_changed "$unit" || ! image_is_running "$unit" "$image"; then
        restart_unit "$unit" || { warn "$unit did not restart"; return 1; }
        mark_applied "$unit"
    else
        start_unit "$unit"
        log "$unit is unchanged; not restarting it"
    fi
}

# .container only, never *.network: a network cannot be restarted under the
# containers using it. A oneshot unit is inactive and skipped by the is-active
# check; a unit not running yet is started later, in dependency order, by
# start_infra/start_daemons -- restarting it here would jump that order
# (lightningd before bitcoind). nginx-proxy-manager is only flagged
# (sync_npm_network), and a unit in DEFER_UNITS is skipped: the phase that
# rebuilt its image restarts it.
restart_changed_units() { # before-digest after-digest
    local before="$1" after="$2" unit
    local -a changed=()
    [ -n "$before" ] && [ -n "$after" ] || return 0
    while IFS= read -r unit; do
        [ -n "$unit" ] && changed+=("$unit")
    done < <(unit_digest_changed "$before" "$after")
    for unit in "${changed[@]}"; do
        mark_changed "$unit"
        if [ "$unit" = nginx-proxy-manager ]; then
            NPM_UNIT_CHANGED=1
            systemctl --user is-active --quiet "$unit.service" 2>/dev/null \
                && mark_changed_active "$unit"
            continue
        fi
        # DEFER_UNITS is set by the branch that rebuilds this unit's image and
        # restarts it itself (deploy_app): a restart here would be an outage on
        # the old bits and a second one seconds later.
        if unit_in_set "$unit" "${DEFER_UNITS:-}"; then
            systemctl --user is-active --quiet "$unit.service" 2>/dev/null \
                && mark_changed_active "$unit"
            continue
        fi
        systemctl --user is-active --quiet "$unit.service" 2>/dev/null || continue
        mark_changed_active "$unit"
        # A unit can be named by two rendered files (tor.container and the torrc
        # digest above, which both mean tor): restart it once.
        unit_applied "$unit" && continue
        log "$unit.service changed; restarting it to pick up the new unit"
        if restart_unit "$unit"; then
            mark_applied "$unit"
        else
            warn "$unit did not restart; its new definition is not applied"
        fi
    done
}

# ---------------------------------------------------------------------------
# helpers for the runtime steps
# ---------------------------------------------------------------------------
start_unit() { log "starting $1.service"; run systemctl --user start "$1.service"; }
# `start` is a no-op on an already-active unit, so a redeploy that rebuilt the
# image would keep running the old container. Redeploys restart instead.
restart_unit() { log "restarting $1.service"; run systemctl --user restart "$1.service"; }

# A locally-built image can be rebuilt while its unit stays byte-identical: that
# is the point of install.sh's Containerfile label, and no unit digest can see
# it (the definition did not change), so a bare ./deploy/install.sh leaves the
# old container on the old bits. Compare what it runs with the image on disk.
refresh_image_unit() { # container image -> restart when the container is older
    local name="$1" image="$2"
    [ "$DRY_RUN" = 0 ] || return 0
    podman container exists "$name" 2>/dev/null || return 0
    systemctl --user is-active --quiet "$name.service" 2>/dev/null || return 0
    # The digest pass may have restarted it already (its unit changed); a second
    # restart is another outage for the same definition.
    unit_applied "$name" && return 0
    # An unreadable image id is "cannot prove staleness", not "stale" --
    # image_is_running reads it the other way, so the guard stays here.
    [ -n "$(podman inspect "$name" --format '{{.Image}}' 2>/dev/null || true)" ] \
        && [ -n "$(podman image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)" ] \
        || return 0
    image_is_running "$name" "$image" && return 0
    log "$name is running an older $image; restarting it"
    if restart_unit "$name"; then
        mark_applied "$name"
    else
        warn "$name did not restart; it keeps the old image"
    fi
}

# BTCPay loads the Monero plugin assemblies at start and keeps the copy it
# mapped, so replacing the DLL on disk does nothing until the container is
# recreated -- and its unit is unchanged by a plugin bump (docs/btcpay.md). Same
# question as refresh_image_unit, answered against a file.
btcpay_plugin_newer() {
    local dll="$DATA_DIR/btcpay/Plugins/$BTCPAY_PLUGIN_ID/$BTCPAY_PLUGIN_ID.dll"
    local started mtime
    [ -f "$dll" ] || return 1
    podman container exists btcpay 2>/dev/null || return 1
    started=$(podman inspect btcpay --format '{{.State.StartedAt}}' 2>/dev/null || true)
    [ -n "$started" ] || return 1
    started=$(date -d "$started" +%s 2>/dev/null || true)
    [ -n "$started" ] || return 1
    mtime=$(stat -c %Y "$dll" 2>/dev/null || true)
    [ -n "$mtime" ] || return 1
    # Whole-second mtimes against a start time that carries fractions: an equal
    # second is "the process loaded it".
    [ "$mtime" -gt "$started" ]
}

# Make sure the podman network exists before anything joins it. The quadlet unit
# can be left "active (exited)" while the network itself is gone (removed by
# hand) and systemd will not re-run it. Recreate it from the unit, which pins
# the subnet the tor IP and the rpcallowip/SocksPolicy allowlists rely on.
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

# The `--only` branches run their checks through the two curl clients and never
# reach start_infra. Called at the end of sync_units, after install.sh had its
# chance to rebuild the image, so `--only monitor` on a freshly booted host
# finds them up.
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
    # The curl clients every host-side check execs into: first, because the
    # checks that read a service by name (verify.sh, the MCP handshakes) go
    # through them, and refreshed because install.sh rebuilds the image in place
    # -- `start` on an already-active unit would keep the old bits.
    refresh_image_unit netcheck "$NETCHECK_IMAGE"
    start_unit netcheck
    refresh_image_unit netcheck-host "$NETCHECK_IMAGE"
    start_unit netcheck-host
    # Monitoring first: it depends on nothing, and starting it before the daemons
    # captures the whole initial sync in the metrics history.
    start_unit node-exporter
    start_unit victoriametrics
    # Alertmanager: the monitor pushes into it, so start it before the first
    # sweep (a start is a no-op when active).
    start_unit alertmanager
    # The log pipeline: journald -> vector -> victoria-logs (docs/logs.md). It
    # depends on nothing, so it starts before the daemons; vector buffers and
    # retries, so the order inside this pair is not gating.
    start_unit victoria-logs
    start_unit vector
    # tor first: lightningd requires it and addresses it by its pinned IP. Its
    # image is rebuilt in place, so refresh it before starting.
    refresh_image_unit tor "$TOR_IMAGE"
    start_unit tor
    if [ "$SKIP_DAEMONS" = 0 ]; then
        start_unit bitcoind
        start_unit monerod
        # Fulcrum indexes from bitcoind's RPC and follows it through IBD; it
        # retries the connection itself, so it is not gated on a wait.
        start_unit fulcrum
    fi
    start_unit valkey
    start_unit searxng
    start_unit uptime-kuma
    start_unit nginx-proxy-manager
    # CrowdSec reads nginx-proxy-manager's access log (NPM's directory), so it
    # starts after the proxy. Nothing gates on it: a crowdsec that fails to
    # start leaves detection off, not the site down (docs/ids.md).
    start_unit crowdsec

    if [ "$SKIP_DAEMONS" = 1 ]; then
        log "skipping the chain daemons (--skip-daemons)"
    fi
}

# ---------------------------------------------------------------------------
# 5. lightningd (the CLN runes are minted by ./configure.sh)
# ---------------------------------------------------------------------------
start_daemons() {
    if [ "$SKIP_DAEMONS" = 1 ]; then log "skipping the chain daemons (--skip-daemons)"; return 0; fi

    # The lightningd image's entrypoint stays alive as PID 1 after the daemon
    # dies (its bcli plugin backed into a bitcoind still loading its wallet), so
    # the unit reads "active" and Restart=always never fires. The unit's
    # HealthOnFailure=kill ends that container; this check is the fallback for
    # one created before that line existed, since an active unit reporting
    # unhealthy is exactly that zombie.
    if [ "$DRY_RUN" = 0 ] && systemctl --user is-active --quiet lightningd.service \
        && [ "$(podman inspect -f '{{.State.Health.Status}}' lightningd 2>/dev/null)" = unhealthy ]; then
        warn "lightningd container is up but the daemon is dead inside; restarting it"
        restart_unit lightningd
    else
        start_unit lightningd
    fi
    # The CLN runes need a lightningd that answers: that wait and the re-run
    # that mints them are ./configure.sh's job.
}

# ---------------------------------------------------------------------------
# 5b. BTCPay: the settlement tier the BoltMesh backend talks to
# ---------------------------------------------------------------------------
# install.sh renders the BTCPay/NBXplorer/Monero-wallet units; this only starts
# them, in dependency order. The work that needs them answering -- the btcpay
# role and databases, the view-only plugin wallet, the store bootstrap, the env
# files -- is ./configure.sh's (docs/btcpay.md).
start_btcpay() {
    if [ "$SKIP_DAEMONS" = 1 ]; then log "skipping BTCPay (--skip-daemons)"; return 0; fi
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] systemctl --user start btcpay-plugin postgres nbxplorer monero-wallet-btcpay btcpay\n'
        return 0
    fi

    # The plugin is btcpay's input, and starting an already-active btcpay does
    # not re-run its Wants=: stage it here so a bump reaches the plugin dir even
    # on `--only btcpay`, then let btcpay_plugin_newer below decide about the
    # restart.
    start_unit btcpay-plugin || warn "could not stage the BTCPay Monero plugin"

    start_unit postgres || warn "postgres did not start"
    start_unit nbxplorer || warn "nbxplorer did not start"
    start_unit monero-wallet-btcpay || warn "monero-wallet-btcpay did not start"

    local btcpay_active=0 btcpay_applied=0
    systemctl --user is-active --quiet btcpay.service 2>/dev/null && btcpay_active=1
    if start_unit btcpay; then btcpay_applied=1; else warn "btcpay did not start"; fi
    # btcpay is deferred by the digest pass: its restart belongs here, after
    # postgres/nbxplorer. A failed restart is not "applied".
    if [ "$btcpay_active" = 1 ] && unit_was_changed btcpay && ! unit_applied btcpay; then
        log "btcpay.service changed; restarting it to pick up the new unit"
        if restart_unit btcpay; then btcpay_applied=1; else warn "btcpay did not restart"; btcpay_applied=0; fi
    fi
    [ "$btcpay_applied" = 0 ] || mark_applied btcpay
    # A plugin bump is a file, so no unit digest notices it: compare what is
    # loaded with what is on disk. This covers `--only btcpay` too.
    if btcpay_plugin_newer; then
        log "the BTCPay Monero plugin on disk is newer than the running container; restarting btcpay"
        restart_unit btcpay || warn "btcpay did not restart"
    fi
}

# ---------------------------------------------------------------------------
# 6. the application servers
# ---------------------------------------------------------------------------
deploy_app() { # repo [force]
    local r="$1" force="${2:-0}"
    local dir="$BUILD_DIR/$r"
    local image="localhost/$r:latest"
    [ -d "$dir" ] || { warn "$r is not cloned under $BUILD_DIR"; return 1; }
    [ -f "$dir/Containerfile" ] || { warn "$r has no Containerfile"; return 1; }

    log "building $image"
    run podman build -t "$image" "$dir" \
        || { warn "$r did not build; keeping the running image"; return 1; }
    # Health is ./verify.sh's and monitor.timer's verdict, not the deploy's;
    # it never waits. A plain `--only <app>` forces the restart.
    if [ "$force" = 1 ]; then
        restart_unit "$r" || { warn "$r did not restart"; return 1; }
        mark_applied "$r"
    else
        restart_applied "$r" "$image" || return 1
    fi
}

deploy_apps() {
    local r
    for r in "${APP_REPOS[@]}"; do
        deploy_app "$r" || warn "$r did not deploy"
    done
}

# ---------------------------------------------------------------------------
# 6b. the BoltMesh app tier (postgres + backend + worker + frontend)
# ---------------------------------------------------------------------------
# Not deploy_app: the BoltMesh repos live in a second org, and the frontend
# needs an explicit build target and VITE_* build args (inlined into the bundle
# at build time) that deploy_app does not pass. The private boltmesh-labs repos
# are fetched over SSH (GITHUB_SSH_HOST); same repo:dir pairs as stack.conf.
fetch_boltmesh() { # every BOLTMESH_REPOS entry ("repo:dir" pairs)
    mkdir -p "$BUILD_DIR"
    local pair repo dir
    for pair in "${BOLTMESH_REPOS[@]}"; do
        repo="${pair%%:*}"            # GitHub repo name
        dir="$BUILD_DIR/${pair##*:}"  # local build dir (namespaced)
        fetch_repo "$GITHUB_SSH_HOST:$GITHUB_ORG_BOLTMESH/$repo.git" "$dir" "$repo"
    done
}

# Prefer Containerfile (the stack's contract); Dockerfile is the old name, kept
# so a host pinned to an older checkout still builds.
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

deploy_boltmesh() { # [force]
    local force="${1:-0}"
    # Failures warn and return 0, exactly like deploy_apps: the deploy brings up
    # what it can and verify.sh reports what is broken, so one bad build does
    # not abort the run.
    fetch_boltmesh

    if ! build_boltmesh_backend; then
        warn "the BoltMesh backend image did not build; skipping the tier"
        return 0
    fi
    if ! build_boltmesh_frontend; then
        warn "the BoltMesh frontend image did not build; starting the API/worker anyway"
    fi

    start_unit postgres || warn "postgres did not start"
    # The migrations are ./configure.sh's job: they need a postgres that
    # answers, and deploy.sh does not wait. The API/worker start regardless, so
    # a run that never reaches configure.sh serves against a missing schema.

    # Backend and worker share one image; the frontend has its own.
    restart_applied boltmesh-backend localhost/boltmesh-backend:latest "$force" \
        || warn "boltmesh-backend did not restart"
    restart_applied boltmesh-worker localhost/boltmesh-backend:latest "$force" \
        || warn "boltmesh-worker did not restart"
    restart_applied boltmesh-frontend localhost/boltmesh-frontend:latest "$force" \
        || warn "boltmesh-frontend did not restart"
}

# ---------------------------------------------------------------------------
# 6b-bis. the blockchain explorers
# ---------------------------------------------------------------------------
# BTC RPC Explorer and MoneroBlock are local images (btc-explorer/ and
# xmr-explorer/ Containerfiles), so they are built here rather than by
# install.sh, after the daemons they read. Nothing here is secret: the BTC unit
# reads its RPC credentials from an EnvironmentFile install.sh seeded.
explorer_image() { # name -> the local image tag
    case "$1" in
        btc-explorer) printf '%s' "$BTC_EXPLORER_IMAGE" ;;
        xmr-explorer) printf '%s' "$XMR_EXPLORER_IMAGE" ;;
        *) return 1 ;;
    esac
}

build_explorer() { # name [force]
    local name="$1" force="${2:-0}" dir="$REPO_DIR/$1" image
    image=$(explorer_image "$name") || { warn "unknown explorer: $name"; return 1; }
    [ -f "$dir/Containerfile" ] || { warn "$name has no Containerfile"; return 1; }
    # "exists" is not enough: a digest bump changes only the Containerfile, so a
    # stale label means the old bits under the same local tag
    # (scripts/lib.sh's image_is_current).
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

    # Build first, then decide what needs a restart: only a changed unit or a
    # rebuilt image costs an outage. xmr-explorer panics while monerod is still
    # opening its LMDB, but its unit retries every RestartSec, so leave recovery
    # to systemd instead of waiting on monerod's restricted RPC.
    local name image
    for name in "${EXPLORER_UNITS[@]}"; do
        build_explorer "$name" \
            || { warn "$name did not build; the other explorer continues"; continue; }
        image=$(explorer_image "$name") || continue
        if unit_was_changed "$name" || ! image_is_running "$name" "$image"; then
            restart_unit "$name" || { warn "$name did not restart"; continue; }
            mark_applied "$name"
        else
            start_unit "$name"
            log "$name is unchanged; not restarting it"
        fi
    done
}

# ---------------------------------------------------------------------------
# 6c. the nginx-proxy-manager proxy hosts
# ---------------------------------------------------------------------------
# Not a unit: nginx-proxy-manager already serves. Every backend it fronts
# publishes on the host's loopback, where NPM (on the host network) forwards, so
# this only writes the hosts declared in NPM_HOSTS through NPM's admin API
# (docs/proxy.md). It self-skips when $DATA_DIR/config/npm/api.env has no
# credentials, so a fresh host deploys before the admin login exists.
configure_npm_hosts() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] %s\n' "$REPO_DIR/scripts/npm-hosts.sh"
        return 0
    fi
    "$REPO_DIR/scripts/npm-hosts.sh" \
        || warn "the proxy hosts were not (re)configured; see scripts/npm-hosts.sh"
}

# ---------------------------------------------------------------------------
# 6d. nginx-proxy-manager's network mode
# ---------------------------------------------------------------------------
# A running container keeps its old unit, so NPM serves the old layout until it
# restarts -- and that restart must come *after* the rewrite above, never
# before: nginx resolves every upstream at start and refuses to come up when a
# saved host names something it cannot resolve (on the host network, a container
# name). That would also take the admin API on :81 down, leaving the rewrite
# with nothing to talk to (docs/proxy.md).
sync_npm_network() {
    local want got why=""
    want=$(sed -n 's/^Network=//p' "$QUADLET_DIR/nginx-proxy-manager.container" 2>/dev/null | head -n1 || true)
    [ -n "$want" ] || return 0
    got=$(podman inspect nginx-proxy-manager --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)
    if [ -z "$got" ]; then
        # Not running: whenever it starts, it starts on the new unit.
        NPM_UNIT_CHANGED=0
        mark_applied nginx-proxy-manager
        return 0
    fi
    if [ "$got" != "$want" ]; then why="its unit asks for '$want', not '$got'"
    elif [ "$NPM_UNIT_CHANGED" = 1 ]; then why="its unit changed"
    else
        NPM_UNIT_CHANGED=0
        return 0
    fi
    log "restarting nginx-proxy-manager: $why"
    if restart_unit nginx-proxy-manager; then
        mark_applied nginx-proxy-manager
        # The unit question is settled: units_commit may now record NPM's
        # definition as applied.
        NPM_UNIT_CHANGED=0
    else
        warn "nginx-proxy-manager did not restart; its new unit is not applied"
    fi
}

# ---------------------------------------------------------------------------
# 6e. agent tooling: the skills + `agent-mcp`, for harnesses without MCP
# ---------------------------------------------------------------------------
# Not a service: agent-skills ships no Containerfile and starts no container, so
# it is absent from APP_REPOS (deploy_app would bail on the missing
# Containerfile). Its install.sh links the skills into whichever harnesses exist
# under $HOME and drops agent-mcp in ~/.local/bin -- the only thing a deploy
# writes outside $DATA_DIR, hence --skip-agent-skills (docs/clients.md).
#
# No --from-opencode: servers.json reads each server's token from
# $DATA_DIR/config/<server>/token.env, so seeding ~/.config/agent-skills/env
# would only create a copy that goes stale on the next rotation. The handshake
# that proves the path through $MCP_HOST needs the stack answering, so it lives
# in ./configure.sh.
agent_skills_dir() { printf '%s/%s' "$BUILD_DIR" "$AGENT_SKILLS_REPO"; }

fetch_agent_skills() {
    fetch_repo "https://github.com/$GITHUB_ORG/$AGENT_SKILLS_REPO.git" \
        "$(agent_skills_dir)" "$AGENT_SKILLS_REPO"
}

install_agent_skills() {
    local dir; dir=$(agent_skills_dir)
    [ -d "$dir" ] || { warn "$AGENT_SKILLS_REPO is not cloned under $BUILD_DIR"; return 1; }
    [ -x "$dir/install.sh" ] || { warn "$AGENT_SKILLS_REPO has no install.sh"; return 1; }

    log "installing the agent skills and agent-mcp"
    run "$dir/install.sh" || { warn "$dir/install.sh failed"; return 1; }
}

# ---------------------------------------------------------------------------
# 7. firewalld
# ---------------------------------------------------------------------------
# bootstrap.sh opens FIREWALL_PORTS -- it owns every privileged host setting, so
# deploy.sh stays rootless. Querying firewalld needs privilege, so this can only
# report, never check: a notice, not a gate.
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
    # from the unit, as the full deploy does. The curl clients are started by
    # sync_units, after install.sh had its chance to rebuild their image.
    ensure_network
    if unit_in_set "$ONLY" "${APP_REPOS[*]}"; then
        # deploy_app rebuilds the image and restarts the unit itself, so the
        # digest pass must leave this one alone: a restart there is an outage on
        # the old bits.
        DEFER_UNITS=" $ONLY "
        fetch_repos "$ONLY"
        sync_units
        # An explicit --only is a request to redeploy: force the restart.
        deploy_app "$ONLY" 1
    elif [ "$ONLY" = backup ]; then
        # A one-shot job: install.sh has (re)enabled the timer; run it once now.
        sync_units
        start_unit backup
    elif [ "$ONLY" = backup-verify ]; then
        # The weekly restore drill (scripts/backup.sh verify), now. It reads
        # only the repository, so it is safe on a serving host; the verdict
        # lands in $DATA_DIR/audit/backup-verify.status (docs/backup.md).
        sync_units
        start_unit backup-verify
    elif [ "$ONLY" = backup-verify-db ]; then
        # The monthly database drill (scripts/backup.sh verify-db): replay the
        # snapshot's postgres dump into a throwaway cluster. Same safety
        # property -- the live data dirs are never mounted -- and it may pull
        # the postgres image, which the weekly drill does not. Verdict in
        # $DATA_DIR/audit/backup-verify-db.status.
        sync_units
        start_unit backup-verify-db
    elif [ "$ONLY" = monitor ]; then
        # Like backup: install.sh has (re)enabled monitor.timer; run one sweep.
        # monitor.service is oneshot and takes no arguments.
        sync_units
        start_unit monitor
    elif [ "$ONLY" = registrations ]; then
        # The signup watcher (scripts/registrations.sh): run one pass now. To
        # see what it would mail or prove the channel, run the script by hand
        # (`--dry-run`, `--test`).
        sync_units
        start_unit registrations
    elif [ "$ONLY" = btcpay ]; then
        # btcpay's restart belongs after postgres and nbxplorer, so the digest
        # pass leaves it to start_btcpay. The databases, plugin wallet,
        # bootstrap and env files are ./configure.sh --only btcpay.
        DEFER_UNITS=" btcpay "
        sync_units
        start_btcpay
        log "next: ./configure.sh --only btcpay  # databases, plugin wallet, bootstrap, envs"
    elif [ "$ONLY" = boltmesh ]; then
        # The whole app tier: fetch, build, start. Individual members fall
        # through to the generic branch below, which restarts the one unit. The
        # migrations are ./configure.sh --only boltmesh (they need a ready
        # postgres).
        DEFER_UNITS=" boltmesh-backend boltmesh-worker boltmesh-frontend "
        sync_units
        deploy_boltmesh 1
        log "next: ./configure.sh --only boltmesh  # alembic upgrade head"
    elif [ "$ONLY" = explorers ]; then
        # Both explorer images, rebuilt even if they exist (their Containerfiles
        # are the only place their versions live). Deferred so the digest pass
        # does not restart them on the old image first.
        DEFER_UNITS=" ${EXPLORER_UNITS[*]} "
        sync_units
        for name in "${EXPLORER_UNITS[@]}"; do
            build_explorer "$name" 1 || continue
            restart_unit "$name" || { warn "$name did not restart"; continue; }
            mark_applied "$name"
        done
    elif [ "$ONLY" = btc-explorer ] || [ "$ONLY" = xmr-explorer ]; then
        # One explorer: rebuild its image and restart only that unit; the
        # generic branch below would skip the build and keep the old image.
        DEFER_UNITS=" $ONLY "
        sync_units
        build_explorer "$ONLY" 1
        restart_unit "$ONLY" || warn "$ONLY did not restart"
        mark_applied "$ONLY"
    elif [ "$ONLY" = npm-hosts ]; then
        # Re-apply the proxy hosts after a manifest change, or after filling in
        # $DATA_DIR/config/npm/api.env. This is the one branch that owns
        # nginx-proxy-manager's deferred restart: rewrite the hosts first, then
        # let sync_npm_network apply a changed unit (it says why the order
        # matters).
        sync_units
        configure_npm_hosts
        sync_npm_network
    elif [ "$ONLY" = agent-skills ]; then
        # Client-side tooling only: no unit, no secret -- it reads the tokens
        # the stack already wrote and links the skills into the harnesses under
        # $HOME.
        fetch_agent_skills
        install_agent_skills || true
    else
        sync_units
        # sync_units may already have restarted it; a second restart is a second
        # outage for one edit, so only restart when it did not.
        if unit_applied "$ONLY"; then
            log "$ONLY.service was restarted to pick up its new unit; not restarting it again"
        else
            restart_unit "$ONLY"
            mark_applied "$ONLY"
        fi
        # A direct restart settles NPM's unit question for units_commit, which
        # otherwise keeps its baseline line behind. This branch did not rewrite
        # the proxy hosts first, so a unit change that also changes the network
        # mode still needs `--only npm-hosts` (sync_npm_network says why).
        if [ "$ONLY" = nginx-proxy-manager ]; then
            NPM_UNIT_CHANGED=0
        fi
    fi
    units_commit
    log "done (--only $ONLY)"
    exit 0
fi

fetch_repos
# The app tier and the explorers are restarted by the phase that owns them,
# after its build, so the early digest pass leaves them alone: a unit both
# changed and rebuilt would otherwise be restarted twice (once on the old bits).
# btcpay's restart belongs in start_btcpay. Only units whose phase will run are
# deferred -- with --skip-apps or --skip-daemons the digest pass applies their
# changes.
DEFER_UNITS=" "
[ "$SKIP_APPS" = 1 ] || DEFER_UNITS="$DEFER_UNITS${APP_REPOS[*]} boltmesh-backend boltmesh-worker boltmesh-frontend "
[ "$SKIP_DAEMONS" = 1 ] || DEFER_UNITS="$DEFER_UNITS${EXPLORER_UNITS[*]} btcpay "
units_before=$(units_baseline)
install_units
units_after=$(unit_digest)
restart_changed_units "$units_before" "$units_after"
UNITS_APPLIED_DIGEST="$units_after"
UNITS_SYNCED=1
start_infra
start_daemons
# A BTCPay failure is a tier failure, not a deploy failure: the rest still
# deploys and ./verify.sh names what is down. A bare call would let `set -e`
# abort before units_commit and leave the baseline stale.
start_btcpay || warn "BTCPay did not come up; continuing -- run ./verify.sh"
[ "$SKIP_APPS" = 1 ] || deploy_apps
[ "$SKIP_APPS" = 1 ] || deploy_boltmesh
# Configure the proxy hosts before the explorers: their images are local builds,
# and the rest of the public surface must not wait for them. NPM does not
# connect to a loopback upstream until a request arrives.
configure_npm_hosts
sync_npm_network
if [ "$DO_AGENT_SKILLS" = 1 ]; then
    fetch_agent_skills
    install_agent_skills || true
else
    log "agent skills skipped (--skip-agent-skills)"
fi
deploy_explorers
note_firewall
# Record the definitions this deploy applied: which unit files the containers
# were started from, not whether the stack is healthy. A tier that warns must
# not withhold the baseline -- every re-run would bounce units that are current.
units_commit

if [ "$DRY_RUN" = 1 ]; then
    log "dry run complete; nothing was changed"
    exit 0
fi

if [ "$DO_AGENT_SKILLS" = 1 ]; then
    agent_skills_summary="agent-mcp + eleven read-only skills in \$HOME"
else
    agent_skills_summary="not installed (--skip-agent-skills)"
fi

# The prefix list is the manifest's, not a second copy: "/searxng" -> "searxng",
# joined with "|" (empty when the manifest is old).
mcp_prefix_list=""
for prefix in ${MCP_PREFIXES[@]+"${MCP_PREFIXES[@]}"}; do
    mcp_prefix_list+="${mcp_prefix_list:+|}${prefix#/}"
done

if [ "$SKIP_DAEMONS" = 1 ]; then
    cat <<EOF

Stack deployed (chain daemons skipped).

  Web and MCP:  valkey, searxng, nginx-proxy-manager (80/443/81),
                searxng-mcp, bitcoin-node-mcp, monero-node-mcp,
                monero-wallet-mcp, lightning-mcp, fulcrum-mcp,
                victoria-logs-mcp, victoriametrics-mcp, crowdsec-mcp,
                btcpay-mcp
  BoltMesh app: postgres, boltmesh-backend, boltmesh-worker,
                boltmesh-frontend
  Explorers:    skipped with the chain daemons (--skip-daemons)
  Agent skills: $agent_skills_summary

nginx-proxy-manager is the only HTTP service a client reaches: it runs on the
host network, so it binds 80/443/81 itself and every request keeps the client's
real address. Every service it fronts publishes its port on the host's loopback,
which is where NPM's proxy hosts point. Fulcrum's Electrum ports 50001 (TCP) and
50002 (SSL) are the one non-HTTP exception, opened directly on the LAN because
NPM cannot proxy the Electrum protocol. ./verify.sh and the monitoring scripts
read the other services by container name on npm-network.
The MCP servers are served as https://$MCP_HOST/<prefix> once
  $DATA_DIR/config/npm/api.env has the NPM admin login (scripts/npm-hosts.sh
  applies every proxy host the manifest declares).
The status page's monitors and its published page are created in the
  Uptime-Kuma UI (https://$UPTIME_KUMA_HOST, the setup wizard's account); the
  checks it should carry are listed in docs/proxy.md.
The MCP tools error until their daemons exist. Drop --skip-daemons to bring up
bitcoind, monerod, fulcrum, lightningd, btcpay, nbxplorer and the BTCPay wallet.

deploy.sh does not wait for health and does not do the work that needs a
running service. Next:

  ./configure.sh --skip-daemons  # BoltMesh migrations (the agent-mcp
                                 # handshake needs the chain daemons)
  ./verify.sh                    # container health, MCP handshakes, onion fetches
EOF
else
    cat <<EOF

Stack deployed.

  Daemons and web:  bitcoind, monerod, fulcrum, lightningd, btcpay, nbxplorer,
                    tor, valkey, searxng, nginx-proxy-manager
  MCP servers:      searxng-mcp, bitcoin-node-mcp, monero-node-mcp,
                    monero-wallet-mcp, lightning-mcp, fulcrum-mcp,
                    victoria-logs-mcp, victoriametrics-mcp, crowdsec-mcp,
                    btcpay-mcp
  BoltMesh app:     postgres, boltmesh-backend, boltmesh-worker,
                    boltmesh-frontend
  Explorers:        https://$BTC_EXPLORER_HOST (BTC RPC Explorer: bitcoind RPC
                    + Fulcrum for address history) and
                    https://$XMR_EXPLORER_HOST (MoneroBlock: monerod's
                    restricted RPC)
  Agent skills:     $agent_skills_summary
  Exposure:         nginx-proxy-manager (80/443/81) plus Fulcrum's Electrum
                    ports 50001 (TCP) / 50002 (SSL). NPM runs on the host
                    network, so it keeps clients' real addresses; everything it
                    fronts is on the host's loopback (see the [npm.*] tables in
                    deploy/services.toml). Fulcrum is the one non-HTTP LAN surface
  Electrum:         point a Bitcoin wallet at this host on 50001 (TCP) or
                    50002 (SSL, self-signed). Fulcrum indexes alongside
                    bitcoind and accepts wallets once its index has caught up
                    (podman logs fulcrum)
  MCP over NPM:     https://$MCP_HOST/<${mcp_prefix_list}>
                    once $DATA_DIR/config/npm/api.env has the NPM admin login
  Onion (no DNS):   the same surface as http://<onion>.onion/ (the [onion.*]
                    tables in deploy/services.toml); the addresses are printed
                    below once
                    tor has published them
  Status page:      uptime-kuma on https://$UPTIME_KUMA_HOST; its monitors and
                    page are UI-authored (docs/proxy.md lists the expected
                    checks)
  Spending:         OFF on both money servers (ENABLE_SPENDING=0)
  Backups:          nightly restic job (backup.timer) -> $STACK_BACKUP_DIR;
                    weekly restore drill (backup-verify.timer), verdict in
                    $DATA_DIR/audit/backup-verify.status; monthly postgres dump
                    replay (backup-verify-db.timer), verdict in
                    $DATA_DIR/audit/backup-verify-db.status
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
first sync downloads and validates the whole Bitcoin and Monero chains).

deploy.sh does not wait for health and does not do the work that needs a
running service. Next, once the daemons answer:

  ./configure.sh   # Bitcoin wallet, CLN runes, BTCPay databases/plugin
                   # wallet/bootstrap and the BoltMesh migrations. It waits
                   # (bounded) for each service, warns and moves on when one is
                   # not up, and finishes anything the chain sync delayed on a
                   # later run.
  ./verify.sh      # container health, MCP handshakes, onion fetches
EOF
fi

# The onion addresses are key material, not configuration (they exist only once
# tor has started), so they cannot live in stack.conf or a README. Print them
# when they exist; scripts/npm-hosts.sh prints the same list on its own.
if [ "${ONION_NAMES+x}" = x ] && [ "${#ONION_NAMES[@]}" -gt 0 ]; then
    onion_lines=""
    for i in "${!ONION_NAMES[@]}"; do
        name="${ONION_NAMES[$i]}"; mirrors="${ONION_MIRRORS[$i]}"
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
