#!/usr/bin/env bash
# Install the whole stack: every quadlet unit, every secret/env file, and the
# data directories the containers need.
#
# This is the **only** installer. The application repos (searxng-mcp and the
# four crypto MCP servers, plus BoltMesh's backend and frontend) ship code,
# tests, CI and their Containerfile; their units and env wiring live here.
#
# EVERYTHING persistent lives under one data dir ($STACK_DATA_DIR, default
# $HOME/data): the daemon data, the nginx-proxy-manager data, and the
# config/secrets. Point it at a separate disk and a rebuild only has to keep
# that one directory.
#
# Idempotent and non-destructive: an existing secret/env file is never
# overwritten, secret resolution order is secrets.env -> the installed unit ->
# the daemon's own config -> generate, and the unit a render replaces is kept as
# <unit>.bak (one generation: what the last deploy changed, which is what the
# README's rollback section promises). Every rendered unit also carries a digest
# of its own definition as an OCI label, so the container that starts from it
# says which definition it is running and deploy.sh can restart exactly the units
# whose definition moved -- running this script by hand is visible drift rather
# than a swallowed signal. Nothing here prints a secret.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deploy"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QUADLET_DIR="$CONFIG_HOME/containers/systemd"
# podman's rootless configuration (podman_events_conf below). Same tree as the
# quadlet units -- podman and the quadlet generator read it from here.
PODMAN_CONF_DIR="$CONFIG_HOME/containers"
# Plain systemd user units live here, not in the quadlet dir: Quadlet generates
# .service files from .container/.volume/.network/... but has no .timer type,
# and the monitors and jobs are host scripts rather than containers. USER_UNITS
# below is the whole list.
USER_UNIT_DIR="$CONFIG_HOME/systemd/user"

# shellcheck source=../scripts/lib.sh
. "$REPO_DIR/scripts/lib.sh"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# The public surface (the *_HOST names, the MCP prefixes, the onion services) is
# declared in deploy/services.toml; stack.conf keeps the non-registry knobs.
load_manifest "$REPO_DIR"
# Where the backup job keeps its restic repository (mounted at /repo). Defined
# in stack.conf; default here so install.sh works standalone too.
STACK_BACKUP_DIR="${STACK_BACKUP_DIR:-$HOME/data-backup}"
# Not optional: render_unit substitutes it into the victoriametrics unit, and
# this default covers a checkout whose stack.conf predates the monitoring block.
METRICS_RETENTION="${METRICS_RETENTION:-30d}"
# The same for the log store: rendered into victoria-logs.container.
LOGS_RETENTION="${LOGS_RETENTION:-14d}"
LOGS_MAX_BYTES="${LOGS_MAX_BYTES:-10GiB}"
export STACK_BACKUP_DIR

# Uptime-Kuma's static host entries (deploy/uptime-kuma.container). Every
# monitored vhost that did not opt out with `kuma_add_host = false` resolves to
# the container's host gateway, so its checks reach nginx-proxy-manager directly
# instead of hairpinning through the router and coming back wearing the WAN
# address. MCP_HOST and the status page's host stay literal: MCP_HOST's monitor
# is the canary verify.sh reads to notice a WAN change. Built from the manifest,
# so a renamed vhost cannot leave a stale entry behind.
kuma_add_hosts=""
for _kuma_host in "${KUMA_ADD_HOST_HOSTS[@]}"; do
    kuma_add_hosts="${kuma_add_hosts:+$kuma_add_hosts }--add-host=$_kuma_host:host-gateway"
done
unset _kuma_host

# ---------------------------------------------------------------------------
# the root tier
# ---------------------------------------------------------------------------
# `--root` installs deploy/root/, the privileged tier: the Suricata sensor
# (CAP_NET_RAW in the init user namespace, so it cannot be a rootless Quadlet)
# and the root host jobs that cannot do their work as the stack user (audit,
# bouncer, SMART). bootstrap.sh is its only caller, under sudo; the user-side
# install never runs in this mode.
#
# The split is deliberate: $DATA_DIR stays user-owned (the sensor writes its logs
# into $DATA_DIR/ids, which the host user reads), while everything a rootful
# container *reads* lives root-owned under /etc/stack-ids. A user-writable config
# consumed by a root container would be a privilege boundary.
# Values substituted into a unit go through esc() on both the render side and
# verify.sh's comparison side; esc() says what an unescaped `|` or `&` does.

# ---------------------------------------------------------------------------
# podman's own event log
# ---------------------------------------------------------------------------
# Every podman invocation writes an event and the default backend is the journal:
# an exec is two lines (each with the image's label dump) and every healthcheck
# run is a `health_status` line, all of it reaching the log store and burying the
# cross-service timeline logs.sh exists to answer from. The measurement, and the
# reasons this lives in podman's own config rather than at the 64 exec call
# sites, are in docs/logs.md ("podman's own event log is a config value").
#
# "file", not "none": events are a diagnostic (what started when, did the check
# fire) and the ring keeps `podman events` readable; at this volume 10m is about
# eight hours. Nothing needs a restart -- podman reads it per invocation, unlike
# a rendered unit.
#
# A drop-in, not an edit of containers.conf: podman merges
# containers.conf.d/*.conf after the main file, so an operator's own file is
# never rewritten and the setting is one declarative file. A later-sorting
# drop-in overrides it -- which is how an operator can put events back.
PODMAN_EVENTS_CONF="$DEPLOY_DIR/podman/99-stack.conf"

podman_events_dropin() { # conf-dir
    install -d -m 755 "$1"
    install -m 644 "$PODMAN_EVENTS_CONF" "$1/99-stack.conf"
}

# The effective value rather than the file, because a later-sorting drop-in of
# the operator's own is exactly the case worth reporting.
podman_events_check() {
    local val
    command -v podman >/dev/null 2>&1 || return 0
    val=$(podman info --format '{{.Host.EventLogger}}' 2>/dev/null || true)
    [ -z "$val" ] || [ "$val" = file ] \
        || warn "podman's event logger is $val, not file -- a later containers.conf.d drop-in overrides $PODMAN_EVENTS_CONF"
}

ROOT_UNIT_DIR=/etc/containers/systemd
ROOT_CONFIG_DIR=/etc/stack-ids

root_render() { # src dest mode [data-dir]
    local tmp
    mkdir -p "$(dirname "$2")"
    tmp=$(mktemp)
    render_root_template "$1" "$4" > "$tmp" || { rm -f "$tmp"; return 1; }
    install -m "$3" "$tmp" "$2"
    rm -f "$tmp"
}

install_root_tier() {
    local data="$1" f bkey benv aenv senv smart_devices n_rules bouncer_installed=0
    [ "$(id -u)" = 0 ] || die "install.sh --root must run as root (bootstrap.sh calls it with sudo)"
    [ -n "$data" ] || die "install.sh --root needs --data-dir (bootstrap.sh passes the resolved data dir)"
    [ -d "$data" ] || die "$data does not exist; run ./deploy.sh once first, or pass the right --data-dir"
    [ -f "$DEPLOY_DIR/root/suricata.container" ] || die "missing $DEPLOY_DIR/root/suricata.container"

    log "installing the root tier (Suricata + disk health) for data dir $data"

    # Root's podman config, so the sensor's own healthchecks stop writing a
    # `health_status` event every 30s. They are podman children of the *system*
    # manager, so the user-side drop-in cannot reach them; /etc is where a system
    # manager's podman reads its chain.
    podman_events_dropin /etc/containers/containers.conf.d

    # The configuration the container reads. Root-owned: a rootful container
    # consuming a file the stack user can edit is a privilege boundary.
    install -d -m 755 "$ROOT_CONFIG_DIR/suricata" "$ROOT_CONFIG_DIR/suricata/rules"
    for f in suricata.yaml threshold.conf disable.conf; do
        root_render "$DEPLOY_DIR/root/suricata/$f" "$ROOT_CONFIG_DIR/suricata/$f" 644 "$data"
    done
    root_render "$DEPLOY_DIR/root/suricata/start.sh" "$ROOT_CONFIG_DIR/suricata/start.sh" 755 "$data"
    root_render "$DEPLOY_DIR/root/suricata/rules/local.rules" \
        "$ROOT_CONFIG_DIR/suricata/rules/local.rules" 644 "$data"

    # $DATA_DIR/ids has two owners: the sensor's state (ids/suricata, root-owned,
    # because a rootful container writes it) and crowdsec's next to it
    # (ids/crowdsec, user-owned, because that container is rootless). The parent
    # goes to the invoking user so the user-side install can keep creating
    # ids/crowdsec on later deploys. 0755/0644 so scripts/ids.sh can read eve.json.
    install -d -m 755 "$data/ids"
    if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$data/ids" || warn "could not hand $data/ids back to uid $SUDO_UID"
    fi
    install -d -m 755 "$data/ids/suricata" "$data/ids/suricata/lib"

    # The alert-only feed CrowdSec tails (the second eve-log output in
    # suricata.yaml). Created here because crowdsec may start first, and a fixed
    # path that does not exist yet is not retried by its file acquisition. `:`
    # creates without truncating a live file. The label is load-bearing: a file
    # created under this root-owned dir inherits default_t, which a container
    # cannot read, so it is set explicitly. start.sh recreates it if missing.
    [ -e "$data/ids/suricata/alerts.json" ] || : > "$data/ids/suricata/alerts.json"
    chmod 644 "$data/ids/suricata/alerts.json" 2>/dev/null || true
    chcon -t container_file_t "$data/ids/suricata/alerts.json" 2>/dev/null \
        || warn "could not label $data/ids/suricata/alerts.json for containers"

    # No /etc/tmpfiles.d rule: every path here crosses the user-owned data dir
    # before reaching root-owned ids/suricata, and systemd-tmpfiles refuses that
    # ("unsafe path transition"). Rotation is the host logrotate's job instead
    # (deploy/root/logrotate-stack-ids, rendered below): Suricata rotates only a
    # `filename` with a strftime template, and ours are static.
    rm -f /etc/tmpfiles.d/stack-ids.conf

    # The unit itself. Render, then let systemd regenerate suricata.service --
    # the same render-then-daemon-reload cycle as the user side, in the system
    # manager. Mode 0644, unlike the 0600 user units: a system unit carries no
    # secret, and the unprivileged verify.sh must read it to catch drift.
    root_render "$DEPLOY_DIR/root/suricata.container" "$ROOT_UNIT_DIR/suricata.container" 644 "$data"

    # A silent substitution failure is worse than a loud one: an empty @DATA_DIR@
    # renders a unit that mounts /ids/suricata, which podman rejects only after
    # systemd has tried to start it. Nothing reaches the system manager untested.
    grep -qF "$data/ids/suricata" "$ROOT_UNIT_DIR/suricata.container" \
        || die "rendered $ROOT_UNIT_DIR/suricata.container does not reference $data/ids/suricata -- the substitution failed"

    # Rotation and retention for the EVE files (see the header of
    # deploy/root/logrotate-stack-ids): Suricata cannot rotate a static filename,
    # so the host's logrotate renames, creates and SIGHUPs. Rendered here because
    # the paths carry @DATA_DIR@ and the keep count is IDS_RETENTION_DAYS.
    root_render "$DEPLOY_DIR/root/logrotate-stack-ids" /etc/logrotate.d/stack-ids 644 "$data"
    grep -qF "$data/ids/suricata" /etc/logrotate.d/stack-ids \
        || die "rendered /etc/logrotate.d/stack-ids does not reference $data/ids/suricata -- the substitution failed"
    logrotate -d /etc/logrotate.d/stack-ids >/dev/null 2>&1 \
        || warn "logrotate rejects /etc/logrotate.d/stack-ids; check it, the EVE files will not rotate"
    if systemctl cat logrotate.timer >/dev/null 2>&1; then
        systemctl enable --now logrotate.timer >/dev/null 2>&1 \
            || warn "could not enable logrotate.timer; the EVE files will not rotate"
    else
        warn "logrotate.timer is not installed (sudo dnf install logrotate); the EVE files will not rotate"
    fi

    # ------------------------------------------------------------------
    # auditd: watch the host-level surfaces nothing in this repo writes
    # ------------------------------------------------------------------
    # The daemon runs with an empty rules.d. The rules are rendered (they carry
    # @DATA_DIR@ for the data-dir watches) and loaded with augenrules; the report
    # unit turns the root-only log into a status file the monitor can read.
    #
    # audit/ is shared: root writes the verdict files, the stack user writes
    # audit.log and the spend baselines. If this root phase creates it (a host
    # where the user-side install has not run yet), hand it back -- a root-owned
    # 0755 directory would leave the monitor unable to write its own log.
    install -d -m 755 "$data/audit"
    if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$data/audit" \
            || warn "could not hand $data/audit back to uid $SUDO_UID"
    fi
    install -d -m 750 /etc/audit/rules.d
    root_render "$DEPLOY_DIR/root/audit.rules" /etc/audit/rules.d/60-stack.rules 640 "$data"
    aenv=$(mktemp)
    printf '# Written by deploy/install.sh --root; do not edit (deploy/root/ owns it).\nDATA_DIR=%s\n' "$data" > "$aenv"
    install -m 600 "$aenv" "$ROOT_CONFIG_DIR/audit.env"
    rm -f "$aenv"
    root_render "$DEPLOY_DIR/root/audit-report.sh" "$ROOT_CONFIG_DIR/audit-report.sh" 755 "$data"
    # The status-file writer and duration parser audit-report.sh and bouncer.sh
    # share. Also sourced by the user tier, from the checkout, so this render is
    # the only copy root gets and there is no second implementation to drift.
    # Installed unconditionally, because the bouncer block below runs only once a
    # key exists, and the bouncer must never be left without it.
    root_render "$DEPLOY_DIR/root/status.sh" "$ROOT_CONFIG_DIR/status.sh" 644 "$data"
    root_render "$DEPLOY_DIR/root/stack-audit.service" /etc/systemd/system/stack-audit.service 644 "$data"
    root_render "$DEPLOY_DIR/root/stack-audit.timer" /etc/systemd/system/stack-audit.timer 644 "$data"
    # augenrules ADDS rules; it never removes the ones a previous render left
    # behind, so remove only OUR rules, one at a time -- NOT `auditctl -D`: a
    # global delete has left this kernel accepting rules but emitting no events
    # at all, not even CONFIG_CHANGE, until a reboot. Deleting by rule text has
    # no such effect and leaves an operator's own rules alone.
    if [ -x /usr/sbin/auditctl ]; then
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            # -W takes the WATCH PATH, not the whole `-w ...` line. Passing the
            # line makes auditctl read "-w" as the path and fail ("The path must
            # start with '/'"), after which augenrules aborts on the first
            # duplicate ("Rule exists") and a new watch never loads. Only file
            # watches are ours in this ruleset.
            case "$rule" in
                -w\ *) rule="${rule#-w }" ;;
                *)     continue ;;
            esac
            # shellcheck disable=SC2086  # the rule text IS the argument list
            /usr/sbin/auditctl -W $rule >/dev/null 2>&1 \
                || warn "could not remove stack audit rule: $rule"
        done <<< "$(/usr/sbin/auditctl -l 2>/dev/null | grep -- '-k stack_' || true)"
    fi
    # augenrules exits non-zero on "Rule exists" even when the ruleset is already
    # right, so the verdict is the kernel's rule list, not the exit code.
    /usr/sbin/augenrules --load >/dev/null 2>&1 || true
    n_expected=$(grep -c -- '-k stack_' /etc/audit/rules.d/60-stack.rules 2>/dev/null || true)
    case "$n_expected" in ''|*[!0-9]*) n_expected=0 ;; esac
    n_rules=$(/usr/sbin/auditctl -l 2>/dev/null | grep -c -- '-k stack_' || true)
    if [ ! -x /usr/sbin/augenrules ]; then
        warn "auditctl/augenrules are missing (EL10 ships them in the audit-rules package); run: sudo dnf install -y audit-rules && sudo ./bootstrap.sh"
    elif [ "${n_rules:-0}" -gt 0 ]; then
        log "audit rules loaded (${n_rules}/${n_expected} watch(es))"
        if [ "${n_rules:-0}" -lt "$n_expected" ]; then
            warn "audit: only ${n_rules} of ${n_expected} stack watches loaded; run: sudo /usr/sbin/auditctl -R /etc/audit/audit.rules"
        fi
    else
        warn "no stack audit rules are loaded; run: sudo /usr/sbin/augenrules --load"
    fi

    # ------------------------------------------------------------------
    # stack-smart: per-disk SMART health -> the monitor
    # ------------------------------------------------------------------
    # smartctl opens the block device directly, which the rootless stack user
    # cannot do; the probe writes the same kind of verdict file as the audit
    # report and the bouncer, and the unprivileged monitor judges it. The env
    # file is root-owned because it carries the device list root reads -- never
    # $DATA_DIR/config, which the stack user can edit.
    # SMART_DEVICES is the one operator knob here; keep it across a re-render
    # while DATA_DIR follows the data dir the deploy actually resolved.
    smart_devices=""
    [ -f "$ROOT_CONFIG_DIR/smart.env" ] \
        && smart_devices=$(env_value "$ROOT_CONFIG_DIR/smart.env" SMART_DEVICES)
    # env_value returns the literal line, quotes included. Strip the pair this
    # file writes (single) or an operator may have typed (double) before
    # re-quoting it for the shell.
    smart_devices=$(printf '%s' "$smart_devices" | sed -e 's/^["'\'']//' -e 's/["'\'']$//')
    senv=$(mktemp)
    {
        printf '# Written by deploy/install.sh --root. DATA_DIR is machine-owned;\n'
        printf '# SMART_DEVICES below is preserved across a re-render.\n'
        printf 'DATA_DIR=%s\n' "$data"
        printf '# Empty = every device smartctl --scan reports. Pin a bridge that\n'
        printf '# auto-detects wrong: SMART_DEVICES="/dev/sda:sat /dev/nvme0:nvme"\n'
        printf "SMART_DEVICES='%s'\n" "$smart_devices"
    } > "$senv"
    install -m 600 "$senv" "$ROOT_CONFIG_DIR/smart.env"
    rm -f "$senv"
    root_render "$DEPLOY_DIR/root/smart.sh" "$ROOT_CONFIG_DIR/smart.sh" 755 "$data"
    root_render "$DEPLOY_DIR/root/stack-smart.service" /etc/systemd/system/stack-smart.service 644 "$data"
    root_render "$DEPLOY_DIR/root/stack-smart.timer" /etc/systemd/system/stack-smart.timer 644 "$data"
    if ! command -v smartctl >/dev/null 2>&1; then
        warn "smartctl is missing (sudo dnf install -y smartmontools); the SMART probe will record skip until it is installed"
    fi

    # ------------------------------------------------------------------
    # stack-bouncer: CrowdSec's decisions -> nftables
    # ------------------------------------------------------------------
    # Its key is generated by the user-side install (it must be in secrets.env,
    # where the crowdsec template reads it), so a root phase that runs before the
    # first ./deploy.sh has nothing to install yet; the second bootstrap pass
    # picks it up.
    local bkey
    bkey=$(env_value "$data/config/stack/secrets.env" CROWDSEC_BOUNCER_KEY)
    if [ -z "$bkey" ]; then
        warn "no CROWDSEC_BOUNCER_KEY in $data/config/stack/secrets.env yet; skipping the bouncer (re-run sudo ./bootstrap.sh after ./deploy.sh)"
    else
        root_render "$DEPLOY_DIR/root/bouncer.sh" "$ROOT_CONFIG_DIR/bouncer.sh" 755 "$data"
        # The bouncer's address guard: CIDR classification in stdlib python, so
        # the private-space rules are exact rather than globs. No secret.
        root_render "$DEPLOY_DIR/root/ipguard.py" "$ROOT_CONFIG_DIR/ipguard.py" 644 "$data"
        # Root-owned 0600, deliberately not $DATA_DIR/config: this key reads every
        # decision, and root must not take instructions from a file the stack user
        # can write.
        benv=$(mktemp)
        {
            printf '# Written by deploy/install.sh --root; do not edit (deploy/root/ owns it).\n'
            printf 'CROWDSEC_BOUNCER_KEY=%s\n' "$bkey"
            printf 'LAPI=127.0.0.1:8080\n'
            printf 'DATA_DIR=%s\n' "$data"
            # The host's own public address (stack.conf). Root must not read it
            # from $DATA_DIR/config -- that tree belongs to the stack user, and
            # this value decides what enforcement never touches.
            printf 'STACK_WAN_IP=%s\n' "${STACK_WAN_IP:-}"
        } > "$benv"
        install -m 600 "$benv" "$ROOT_CONFIG_DIR/bouncer.env"
        rm -f "$benv"
        root_render "$DEPLOY_DIR/root/stack-bouncer.service" /etc/systemd/system/stack-bouncer.service 644 "$data"
        root_render "$DEPLOY_DIR/root/stack-bouncer.timer" /etc/systemd/system/stack-bouncer.timer 644 "$data"
        bouncer_installed=1
    fi

    systemctl daemon-reload
    # Quadlet turns the rendered .container into suricata.service, and the
    # generator's [Install] WantedBy=multi-user.target is what pulls it in at
    # boot -- exactly like the rootless units, which are never `systemctl --user
    # enable`d either. `systemctl enable` is REFUSED for a generated unit
    # ("transient or generated").
    #
    # `restart`, not `start`: a re-render never reaches a running process, and
    # `start` on an already-active unit is a no-op -- a changed suricata.yaml
    # (a new eve-log output, a rule) would sit in /etc/stack-ids until someone
    # restarted it by hand. The sensor has no packet path, so a restart costs a
    # few seconds of visibility, never an outage. A failure is a warning, not a
    # failed bootstrap: the rest of the stack is unaffected by a sensor that
    # cannot open its interface (a renamed NIC is the usual cause).
    if systemctl restart suricata 2>/dev/null; then
        log "suricata restarted with the rendered config"
    else
        warn "suricata did not start; check: journalctl -u suricata"
    fi
    # The applier. Unlike the Quadlet units this one is a real system unit, so it
    # is enabled the ordinary way; the first run is triggered here so the status
    # file the monitor reads exists immediately rather than in a minute.
    if [ "${bouncer_installed:-0}" = 1 ]; then
        if systemctl enable --now stack-bouncer.timer >/dev/null 2>&1; then
            log "stack-bouncer.timer enabled (decisions -> nftables every minute)"
            systemctl start stack-bouncer.service >/dev/null 2>&1 \
                || warn "stack-bouncer's first run failed; see: systemctl status stack-bouncer"
        else
            warn "could not enable stack-bouncer.timer"
        fi
    fi
    if systemctl enable --now stack-audit.timer >/dev/null 2>&1; then
        log "stack-audit.timer enabled (audit events -> monitor every five minutes)"
        systemctl start stack-audit.service >/dev/null 2>&1 || true
    else
        warn "could not enable stack-audit.timer"
    fi
    if systemctl enable --now stack-smart.timer >/dev/null 2>&1; then
        log "stack-smart.timer enabled (disk SMART health -> monitor hourly)"
        systemctl start stack-smart.service >/dev/null 2>&1 \
            || warn "stack-smart's first run failed; see: systemctl status stack-smart"
    else
        warn "could not enable stack-smart.timer"
    fi
    log "root tier installed; run ./verify.sh to check the sensor and disks"
}

ROOT_TIER=0
ROOT_DATA_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT_TIER=1 ;;
        --data-dir) ROOT_DATA_DIR="${2:?--data-dir needs a path}"; shift ;;
        -h|--help)  usage_header "$0"
                    printf '  --root            install the root tier: IDS + host jobs (bootstrap.sh only)\n'
                    printf '  --data-dir <path> with --root: the existing data dir to point it at\n'
                    exit 0 ;;
        *)          die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

if [ "$ROOT_TIER" = 1 ]; then
    install_root_tier "$ROOT_DATA_DIR"
    exit 0
fi

# The backup set. Not defaulted here: an empty set would render a backup unit
# that copies nothing, so a stack.conf that lost the declaration is a hard error
# rather than a silent empty snapshot.
if [ "${BACKUP_PATHS+x}" != x ] || [ "${#BACKUP_PATHS[@]}" -eq 0 ]; then
    die "stack.conf must define BACKUP_PATHS (the backup set)"
fi
# The keep policy is rendered into the same unit: an empty array would render
# `restic forget --tag stack --prune`, i.e. delete every snapshot.
if [ "${BACKUP_RETENTION+x}" != x ] || [ "${#BACKUP_RETENTION[@]}" -eq 0 ]; then
    die "stack.conf must define BACKUP_RETENTION (the keep policy)"
fi

# Every unit is rendered. The inventory is the directory, not a list here: every
# *.container and *.container.in under deploy/ is a unit (the .in suffix marks a
# template, the render drops it) and the podman network is the .network. A
# hand-written list would be a second copy of `ls deploy/` that drifts silently.
# deploy/root/ is not in this glob: that tier is `install.sh --root`.
deploy_entry_names() { # glob...
    local f
    for f in "$@"; do
        [ -f "$f" ] && printf '%s\n' "$(basename "$f")"
    done
}
mapfile -t UNITS < <(deploy_entry_names "$DEPLOY_DIR"/*.container \
    "$DEPLOY_DIR"/*.container.in "$DEPLOY_DIR"/*.network | LC_ALL=C sort)
[ "${#UNITS[@]}" -gt 0 ] || die "no units found in $DEPLOY_DIR"

# Plain systemd user units (USER_UNIT_DIR, not the quadlet dir): the same
# derivation over the two unit suffixes. The host jobs are here because a
# container cannot do them -- db-dump.service `podman exec`s into a sibling, and
# btcpay-plugin.service swaps a directory on the host.
mapfile -t USER_UNITS < <(deploy_entry_names "$DEPLOY_DIR"/*.service \
    "$DEPLOY_DIR"/*.timer | LC_ALL=C sort)
[ "${#USER_UNITS[@]}" -gt 0 ] || die "no user units found in $DEPLOY_DIR"

# The subset that is enabled --now: the timers. monitor.service and
# metrics.service have no [Install] -- only their timers activate them -- so
# they must not be enabled on their own.
mapfile -t USER_TIMERS < <(deploy_entry_names "$DEPLOY_DIR"/*.timer)

# Method allowlists for the CLN runes (`method^<prefix>` is a prefix match). The
# prefixes live in stack.conf because rotate.sh mints the same runes; rune_json
# turns each array into the restriction JSON. SPEND is READ plus the payments.
SPEND_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}" "${CLN_SPEND_METHODS[@]}")
READ_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}")
# ---------------------------------------------------------------------------
# where the data lives
# ---------------------------------------------------------------------------
resolve_data_dir
ensure_data_dirs
ensure_data_dir_selinux

SECRETS_FILE="$CONFIG_DIR/stack/secrets.env"
SEARXNG_DATA_DIR="$DATA_DIR/searxng"
TOR_DIR="$DATA_DIR/tor"

# The alert-rule values, resolved the way monitor.sh resolves its own keys:
# process environment, then the installed monitor.env, then the default. They are
# rendered into the vmalert rules rather than read at runtime -- vmalert parses
# its rules at start, so monitor.env is a deploy-time input for these.
resolve_monitor_timing() { # NAME default
    local v="${!1:-}"
    [ -n "$v" ] || v=$(env_value "$CONFIG_DIR/monitoring/monitor.env" "$1")
    case "$v" in
        ''|*[!0-9]*) v="$2" ;;
    esac
    printf '%s' "$v"
}
MONITOR_ALERT_FOR=$(resolve_monitor_timing MONITOR_ALERT_FOR 600)
MONITOR_ALERT_HOLD_S=$(resolve_monitor_timing MONITOR_ALERT_HOLD_S 900)
MONITOR_SWEEP_MAX_AGE_S=$(resolve_monitor_timing MONITOR_SWEEP_MAX_AGE_S 900)
MONITOR_RESTART_MAX=$(resolve_monitor_timing MONITOR_RESTART_MAX 3)
MONITOR_IO_UTIL_PCT=$(resolve_monitor_timing MONITOR_IO_UTIL_PCT 90)
MONITOR_IDS_ALERT_WARN=$(resolve_monitor_timing MONITOR_IDS_ALERT_WARN 20)
MONITOR_SSH_FAIL_WARN=$(resolve_monitor_timing MONITOR_SSH_FAIL_WARN 10)

# write_secret is scripts/lib/datadir.sh's write_env_file (atomic, 0600);
# configure.sh writes the BTCPay env files with the same one, so both halves
# agree on the mode.

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

# A seed-once file is never rewritten, so a mode set by an older seed path
# outlives the fix: tighten it on every run. A file the container owns is a
# warning, not a failed install (SearXNG's settings.yml, torrc).
tighten_secret() { # path
    [ -e "$1" ] || return 0
    chmod 600 "$1" 2>/dev/null || warn "could not tighten $1 to mode 600"
}

new_or_reused_token() {
    new_or_reused_env "$1" "$2" announce
}

# Like new_or_reused_token, but for a value nobody presents (a JWT signing key,
# the bootstrap pepper): reuse what the running container carries so adopting a
# host keeps sessions and node tokens valid. Prints the value on stdout.
new_or_reused_secret() {
    new_or_reused_env "$1" "$2" quiet
}

# The one body behind both: read what the running container already has, else
# generate. A generated TOKEN is announced (every client must match); a generated
# secret is silent, because nobody presents it.
new_or_reused_env() { # container var announce|quiet
    local container="$1" var="$2" mode="$3" val=""
    if command -v podman >/dev/null 2>&1; then
        val=$(podman exec "$container" printenv "$var" 2>/dev/null || true)
    fi
    if [ -n "$val" ]; then
        printf '==> reused %s from the running %s\n' "$var" "$container" >&2
    else
        if [ "$mode" = announce ]; then
            printf '==> generated a new %s -- update clients to match\n' "$var" >&2
        fi
        val=$(rand_hex)
    fi
    printf '%s' "$val"
}

# Seed stdin into PATH when missing, mode 600. A no-op when it exists: an existing
# secret is never overwritten (see the header), in one place instead of twenty.
seed_env() { # path label
    ensure_secret "$1" "$2" || return 0
    write_secret "$1"
    log "wrote $1 (mode 600)"
}

# The eight servers whose token.env is one seed-once bearer token: same shape,
# same log line, so the table is the whole difference. The value is resolved
# INSIDE the missing-file branch -- a heredoc body would announce "a new token" on
# every install, even when the file is left alone.
seed_token_env() { # container VAR
    local container="$1" var="$2" token
    ensure_secret "$CONFIG_DIR/$container/token.env" "$container token env" || return 0
    token=$(new_or_reused_token "$container" "$var")
    write_secret "$CONFIG_DIR/$container/token.env" <<EOF
$var=$token
EOF
    log "wrote $CONFIG_DIR/$container/token.env (mode 600)"
}

# Hand paths to the image's in-container uid 1000 (a host subuid).
# Deliberately NOT recursive: a recursive chown over a Bitcoin datadir walked
# hundreds of GB of block and LevelDB files on every deploy, with bitcoind
# running. Callers name the datadir and its config; subdirectories are created by
# the container itself, already as that uid.
chown_image_uid() {
    command -v podman >/dev/null 2>&1 || return 0
    podman unshare chown 1000:1000 "$@" 2>/dev/null \
        || log "could not chown $* -- run: podman unshare chown 1000:1000 $*"
}

# BACKUP_PATHS rendered the two ways deploy/backup.container needs it: one
# read-only Volume= per entry, and the path list restic backs up in its Exec=.
# backup.sh derives its mounts and arguments from the same array, so the
# declaration is the only place a directory is added or removed.
#
# `:z` (shared), not `:Z`: lightningd, nginx-proxy-manager and tor mount some of
# these too, and two containers cannot share a path one labels private. No
# escaping here: these go into the unit verbatim, not through sed.
backup_mounts() {
    local p
    for p in "${BACKUP_PATHS[@]}"; do
        # audit/ is also written by the rootful IDS. podman's :z relabel fails on
        # its root-owned auditd.fim (initrc_tmp_t) and aborts the whole backup;
        # the directory already carries container_file_t, so mount it read-only
        # without another relabel. restic warns about the one unreadable file.
        if [ "$p" = audit ]; then
            printf 'Volume=%s/%s:/data/%s:ro\n' "$DATA_DIR" "$p" "$p"
        else
            printf 'Volume=%s/%s:/data/%s:ro,z\n' "$DATA_DIR" "$p" "$p"
        fi
    done
}

backup_restic_paths() {
    local p out=""
    for p in "${BACKUP_PATHS[@]}"; do
        out+="${out:+ }/data/$p"
    done
    printf '%s' "$out"
}

# BACKUP_EXCLUDES as restic flags. Quoted because an entry may be a glob
# (npm/data/database.sqlite* covers the db and its -journal/-wal/-shm): restic
# matches it, and the container's /bin/sh must not expand it first. backup.sh
# builds the same flags for a hand run.
backup_excludes() {
    local p out=""
    for p in ${BACKUP_EXCLUDES[@]+"${BACKUP_EXCLUDES[@]}"}; do
        out+="--exclude='/data/$p' "
    done
    printf '%s' "${out% }"
}

# The keep policy (BACKUP_RETENTION) as `restic forget` flags. Space-joined: the
# entries are flags and counts, never a path, so each is a word in Exec= and no
# quoting is needed. backup.sh passes the same array to its own forget.
backup_retention_flags() {
    printf '%s' "${BACKUP_RETENTION[*]}"
}

# ---------------------------------------------------------------------------
# the one template render
# ---------------------------------------------------------------------------
# Every template -- a unit or an env file -- goes through this substitution list.
# The caller owns the output: render_unit installs it, the env writers below
# apply their own policy. The root tier has its own list (render_root_template,
# which verify.sh re-renders against), so a placeholder shared with it must be
# added on both sides. Values only some templates use are `${x:-}` because every
# template is evaluated against this list.
#
# The script goes to sed on stdin (`-f -`), never as `-e` arguments: the list
# carries every rendered secret (the RPC and Tor passwords, BTCPay's DB role
# password, both bouncer keys, the MCP tokens, the JWT keys), and `ps` reads a
# command line.
render_to() { # src out
    local src="$1" out="$2" vol
    sed -f - "$src" > "$out" <<EOF
s|@DATA_DIR@|$(esc "$DATA_DIR")|g
s|@CONFIG_DIR@|$(esc "$CONFIG_DIR")|g
s|@REPO_DIR@|$(esc "$REPO_DIR")|g
s|@BACKUP_DIR@|$(esc "$STACK_BACKUP_DIR")|g
s|@BACKUP_PATHS@|$(esc "$(backup_restic_paths)")|g
s|@BACKUP_EXCLUDES@|$(esc "$(backup_excludes)")|g
s|@BACKUP_RETENTION@|$(esc "$(backup_retention_flags)")|g
s|@BITCOIN_RPC_USER@|$(esc "$BITCOIN_RPC_USER")|g
s|@BITCOIN_RPC_PASSWORD@|$(esc "$BITCOIN_RPC_PASSWORD")|g
s|@TOR_SERVICE_PASSWORD@|$(esc "$TOR_SERVICE_PASSWORD")|g
s|@BTCPAY_DB_PASSWORD@|$(esc "$BTCPAY_DB_PASSWORD")|g
s|@BTCPAY_HOST@|$(esc "$BTCPAY_HOST")|g
s|@KUMA_ADD_HOSTS@|$(esc "$kuma_add_hosts")|g
s|@CROWDSEC_BOUNCER_KEY@|$(esc "${CROWDSEC_BOUNCER_KEY:-}")|g
s|@CROWDSEC_MCP_BOUNCER_KEY@|$(esc "${CROWDSEC_MCP_BOUNCER_KEY:-}")|g
s|@METRICS_RETENTION@|$(esc "$METRICS_RETENTION")|g
s|@MONITOR_ALERT_FOR@|$(esc "$MONITOR_ALERT_FOR")|g
s|@MONITOR_ALERT_HOLD_S@|$(esc "$MONITOR_ALERT_HOLD_S")|g
s|@MONITOR_SWEEP_MAX_AGE_S@|$(esc "$MONITOR_SWEEP_MAX_AGE_S")|g
s|@MONITOR_RESTART_MAX@|$(esc "$MONITOR_RESTART_MAX")|g
s|@MONITOR_IO_UTIL_PCT@|$(esc "$MONITOR_IO_UTIL_PCT")|g
s|@MONITOR_IDS_ALERT_WARN@|$(esc "$MONITOR_IDS_ALERT_WARN")|g
s|@MONITOR_SSH_FAIL_WARN@|$(esc "$MONITOR_SSH_FAIL_WARN")|g
s|@LOGS_RETENTION@|$(esc "$LOGS_RETENTION")|g
s|@LOGS_MAX_BYTES@|$(esc "$LOGS_MAX_BYTES")|g
s|@MONERO_MCP_TOKEN@|$(esc "${MONERO_MCP_TOKEN:-}")|g
s|@MONERO_MCP_SPEND_TOKEN@|$(esc "${MONERO_MCP_SPEND_TOKEN:-}")|g
s|@LIGHTNING_MCP_TOKEN@|$(esc "${LIGHTNING_MCP_TOKEN:-}")|g
s|@LIGHTNING_MCP_SPEND_TOKEN@|$(esc "${LIGHTNING_MCP_SPEND_TOKEN:-}")|g
s|@PG_PASSWORD@|$(esc "${PG_PASSWORD:-}")|g
s|@SECRET_KEY@|$(esc "${SECRET_KEY:-}")|g
s|@REFRESH_SECRET_KEY@|$(esc "${REFRESH_SECRET_KEY:-}")|g
s|@NODE_SECRET_KEY@|$(esc "${NODE_SECRET_KEY:-}")|g
s|@BOOTSTRAP_SECRET_PEPPER@|$(esc "${BOOTSTRAP_SECRET_PEPPER:-}")|g
s|@BOLTMESH_API_HOST@|$(esc "$BOLTMESH_API_HOST")|g
s|@BOLTMESH_FRONTEND_HOST@|$(esc "$BOLTMESH_FRONTEND_HOST")|g
s|@BOLTMESH_COMPANY_NAME@|$(esc "$BOLTMESH_COMPANY_NAME")|g
s|@BOLTMESH_SUPPORT_EMAIL@|$(esc "$BOLTMESH_SUPPORT_EMAIL")|g
s|@BOLTMESH_AGENT_REPO@|$(esc "$BOLTMESH_AGENT_REPO")|g
s|@BTCPAY_ADMIN_PASSWORD@|$(esc "${BTCPAY_ADMIN_PASSWORD:-}")|g
s|@RESTIC_PASSWORD@|$(esc "${RESTIC_PASSWORD:-}")|g
EOF
    # @BACKUP_VOLUMES@ becomes one Volume= line per entry, which sed cannot carry
    # (the value is multi-line); substitute the whole line here. Only
    # backup.container carries the token, so this is a no-op elsewhere.
    if grep -qF '@BACKUP_VOLUMES@' "$out"; then
        vol="$(mktemp)"
        backup_mounts > "$vol"
        awk -v f="$vol" '
            index($0, "@BACKUP_VOLUMES@") { while ((getline l < f) > 0) print l; close(f); next }
            { print }
        ' "$out" > "$out.vol"
        mv -f "$out.vol" "$out"
        rm -f "$vol"
    fi
}

# Render into PATH only when PATH is missing: the seed-once rule for every env
# file. An operator edit (boltmesh/app.env) and a rotation (rotate.sh's
# set_env_key) must survive every install, so this never installs over an
# existing file. Values are resolved by the caller INSIDE the ensure_secret
# branch -- one computed earlier would announce a new token on every run.
seed_rendered() { # path label src [log hint]
    local path="$1" label="$2" src="$3" hint="" tmp
    ensure_secret "$path" "$label" || return 0
    tmp="$(mktemp)"
    render_to "$src" "$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; die "rendered $src is empty"; }
    write_secret "$path" < "$tmp"
    rm -f "$tmp"
    [ -z "${4:-}" ] || hint=" -- $4"
    log "wrote $path (mode 600)$hint"
}

# Render a machine-owned env file and rewrite it only when the bytes differ: a
# rewritten mtime is what makes an operator think a credential moved.
write_rendered_if_changed() { # path src
    local path="$1" src="$2" tmp
    tmp="$(mktemp)"
    render_to "$src" "$tmp"
    if [ -s "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 0
    fi
    write_secret "$path" < "$tmp"
    rm -f "$tmp"
    log "wrote $path (mode 600)"
}

first_nonempty() {
    local v
    for v in "$@"; do
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
}

read_secret() {
    env_value "$SECRETS_FILE" "$1"
}

# The one append-if-missing rule for a key in secrets.env. An existing value is
# NEVER regenerated: the two CrowdSec bouncer keys are registered in the LAPI
# under exactly the rendered value, so a new one leaves the old registration live
# and enforcement silently dead. An absent value is written once (the caller's
# candidate, else the first non-empty duplicate already in the file, else a fresh
# hex secret) and echoed for the caller to assign and export.
#
# A key present but empty goes through write_secret rather than an append:
# appending a second `KEY=value` after an empty `KEY=` is invisible to env_value
# (which reads the first match), so every install would mint another key.
ensure_secret_key() { # key [value] -> the value now in the file
    local key="$1" value="${2:-}" cur found
    cur=$(read_secret "$key")
    if [ -n "$cur" ]; then
        printf '%s' "$cur"
        return 0
    fi
    # An adopted file can carry the key with an empty value, or a duplicate from
    # an older installer. Reuse the first non-empty duplicate: that is what the
    # LAPI most likely registered, so a broken host is repaired rather than handed
    # a third key that would 403.
    found=$(sed -n "s/^$key=//p" "$SECRETS_FILE" 2>/dev/null | grep -v '^$' | head -n1 || true)
    value="${value:-${found:-$(rand_hex)}}"
    if grep -q "^$key=" "$SECRETS_FILE" 2>/dev/null; then
        awk -v k="$key" -v v="$value" '
            index($0, k "=") == 1 {
                if (!done) { print k "=" v; done = 1 }
                next
            }
            { print }
        ' "$SECRETS_FILE" | write_secret "$SECRETS_FILE"
    else
        if [ -s "$SECRETS_FILE" ] && [ "$(tail -c 1 "$SECRETS_FILE" | wc -l)" -eq 0 ]; then
            printf '\n' >> "$SECRETS_FILE"
        fi
        printf '%s=%s\n' "$key" "$value" >> "$SECRETS_FILE"
        chmod 600 "$SECRETS_FILE"
    fi
    log "wrote $key to $SECRETS_FILE (mode 600)" >&2
    printf '%s' "$value"
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
        v=$(bitcoind_conf_value "$key")
    fi
    if [ -z "$v" ]; then
        v=$(sed -n "s/^$key=//p" "$DATA_DIR/bitcoin/bitcoin.conf" 2>/dev/null | head -n1 || true)
    fi
    printf '%s' "$v"
}

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
BTCPAY_DB_PASSWORD=$(first_nonempty \
    "$(read_secret BTCPAY_DB_PASSWORD)" \
    "$(rand_hex)")

if ensure_secret "$SECRETS_FILE" "secrets"; then
    write_secret "$SECRETS_FILE" <<EOF
# Secrets for the whole stack. Written by deploy/install.sh (mode 600), seeded
# from the previously-installed units where possible so adopting it changes no
# credential. Never committed. BTCPAY_DB_PASSWORD is the btcpay role in the
# existing Postgres cluster -- keep this file with the data.
BITCOIN_RPC_USER=$BITCOIN_RPC_USER
BITCOIN_RPC_PASSWORD=$BITCOIN_RPC_PASSWORD
TOR_SERVICE_PASSWORD=$TOR_SERVICE_PASSWORD
BTCPAY_DB_PASSWORD=$BTCPAY_DB_PASSWORD
EOF
    log "wrote $SECRETS_FILE (mode 600)"
fi

# Adopted hosts have a secrets.env from before BTCPay existed. ensure_secret
# never rewrites it, so add this one key when it is missing.
BTCPAY_DB_PASSWORD=$(ensure_secret_key BTCPAY_DB_PASSWORD "$BTCPAY_DB_PASSWORD")

# The bouncer's key is not in the heredoc above: it must also exist on a host
# deployed before the bouncer did, and ensure_secret never touches an existing
# file. So it is appended when missing, which also covers a fresh host.
#
# NEVER regenerate it. crowdsec.container.in renders it into BOUNCER_KEY_firewall
# and the entrypoint registers that exact key in its LAPI; a new value leaves the
# old bouncer registered and enforcement silently dead (LAPI 403, bouncer reports
# "LAPI unreachable" -- the status file exists for this).
CROWDSEC_BOUNCER_KEY=$(ensure_secret_key CROWDSEC_BOUNCER_KEY)
export CROWDSEC_BOUNCER_KEY

# The MCP server's own bouncer key: a second, read-only client of the same LAPI,
# separate so its pulls are attributable in cs_lapi_bouncer_requests_total and
# revoking it (`cscli bouncers delete mcp`) never touches enforcement. Appended
# for the same reason, under the same never-regenerate rule: the entrypoint
# registers a bouncer only when the name is absent, so a new value would leave
# `mcp` holding the old key and every tool answering 403.
CROWDSEC_MCP_BOUNCER_KEY=$(ensure_secret_key CROWDSEC_MCP_BOUNCER_KEY)
export CROWDSEC_MCP_BOUNCER_KEY

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

# Full (archival) node: keep and validate the whole chain. txindex is on so
# btc-explorer resolves any historical txid; on a node that already has the
# blocks Core builds it in the background (it reads blk*.dat, never -reindex).
# It costs another index; the MCP server and lightningd do not need it.
prune=0
txindex=1

# Validation cache, in MiB (range 4-16384; Core's default is 450). A bigger
# cache is the one knob that materially speeds up the initial block download,
# because it cuts chainstate writes to disk -- it does not change the download
# itself. 3072 fits a 16 GB host next to monerod and Fulcrum; drop it back to
# 450 once the chain is synced and the cache buys nothing -- it only speeds the
# initial download, not steady-state validation.
dbcache=3072

# RPC. rpcallowip is the podman subnet only, so a re-added PublishPort would
# still be refused: a request via a host port arrives from the LAN address.
rpcuser=$BITCOIN_RPC_USER
rpcpassword=$BITCOIN_RPC_PASSWORD
rpcbind=0.0.0.0
rpcallowip=127.0.0.1
rpcallowip=10.89.0.0/24

# NBXplorer (BTCPay) needs the P2P endpoint to follow blocks; no host port is
# published, so this only accepts the podman subnet.
listen=1
EOF
    log "seeded $DATA_DIR/bitcoin/bitcoin.conf"
fi
[ -d "$DATA_DIR/bitcoin" ] && chown_image_uid "$DATA_DIR/bitcoin"
[ -s "$DATA_DIR/bitcoin/bitcoin.conf" ] && chown_image_uid "$DATA_DIR/bitcoin/bitcoin.conf"

# BTCPay's datadir (data-protection keys), its plugin dir, the view-only Monero
# wallet and NBXplorer's cookie. All are written by container root == the host
# user under rootless podman, so a plain mkdir is enough. The plugin inside
# Plugins/ is staged by deploy/btcpay-plugin.service, which docs/btcpay.md owns.
mkdir -p "$DATA_DIR/btcpay/Plugins" "$DATA_DIR/btcpay/xmr-wallet" "$DATA_DIR/nbxplorer"

mkdir -p "$DATA_DIR/monero" "$DATA_DIR/cln" "$TOR_DIR"

# Fulcrum's index, self-signed cert and admin latch. The Fulcrum image runs as
# container root (the host user under rootless podman, like cln/ and tor/), so
# this stays user-owned; only the directory has to exist for the :z mount.
mkdir -p "$DATA_DIR/fulcrum"

# The onion services' keys ([onion.*] in services.toml): mounted into tor at
# /var/lib/tor/onion. Mode 700 because tor only checks the leaf HiddenServiceDir
# it creates -- a world-listable parent leaks the service names (not the keys).
mkdir -p "$TOR_DIR/onion"
chmod 700 "$TOR_DIR/onion"

# BoltMesh's data: the postgres cluster (fresh on a new host) and the directory
# the pre-backup pg_dumpall writes into. The dump container runs as the image's
# root (the host user under rootless podman) and the postgres image chowns its
# own PGDATA, so neither dir needs the image-uid chown the other apps need.
mkdir -p "$DATA_DIR/postgres" "$DATA_DIR/postgres-dump"

# Uptime-Kuma's state: its UI-authored monitors/status page, history and login,
# plus the EMBEDDED MARIADB (kuma v2 runs MariaDB, not sqlite). Written by
# container root = the host user, so a plain mkdir. Nothing is seeded: the admin
# account and every monitor are created in its web UI, which is therefore the
# only record of them outside the database dump (db-dump.sh).
mkdir -p "$DATA_DIR/uptime-kuma"

# Every BACKUP_PATHS entry must exist before the job's first run: restic would
# otherwise create it as the wrong owner inside the container, and the unit's :z
# relabel statfs's the source. postgres-dump and the dump dirs are listed above so
# their modes can be set here; the loop keeps a new stack.conf entry from needing
# a second edit.
for _backup_path in "${BACKUP_PATHS[@]}"; do
    mkdir -p "$DATA_DIR/$_backup_path"
done
unset _backup_path
# The pre-backup dumps carry live user tables: keep the staging/dump dirs private.
chmod 700 "$DATA_DIR/npm-dump" "$DATA_DIR/uptime-kuma-dump" 2>/dev/null || true

# Monitoring: the metrics store and the textfile node-exporter serves. Both run as
# container root = the login user, so a plain mkdir. The textfile dir is 0755
# because the exporter runs as uid 65534 (a subuid) and reads what metrics.sh
# writes, which chmods 0644 for the same reason. $DATA_DIR/monitoring is
# regenerable and stays out of the backup set.
mkdir -p "$DATA_DIR/monitoring/vm" "$DATA_DIR/monitoring/textfile"
chmod 0755 "$DATA_DIR/monitoring/textfile" 2>/dev/null || true

# The scrape config is structural (which exporters exist), not operator tuning,
# so it is copied on every run from deploy/monitoring/scrape.yml -- unlike
# monitor.env below, which is seeded once and belongs to the operator. Two things
# matter here and both are easy to get wrong:
#   * it lives in its own directory because the VM unit mounts that directory (a
#     single-file bind mount keeps the inode it opened);
#   * it is written IN PLACE (cat >), not installed/moved into place, because VM
#     watches the inode: a replaced file is invisible to it even though the
#     directory mount shows the new one, so the config would silently stay stale
#     until a restart.
mkdir -p "$CONFIG_DIR/monitoring/vm"
( umask 077; cat "$DEPLOY_DIR/monitoring/scrape.yml" > "$CONFIG_DIR/monitoring/vm/scrape.yml" )
log "wrote $CONFIG_DIR/monitoring/vm/scrape.yml"

# The vmalert rules: structural config, rendered on every run like scrape.yml,
# because the hold-down is a threshold monitor.env carries. unit_digest hashes
# this file, so a changed rule or a new MONITOR_ALERT_FOR restarts vmalert instead
# of leaving the process on the file it started with. The unit mounts the
# DIRECTORY (a single-file bind keeps the inode it opened).
mkdir -p "$CONFIG_DIR/monitoring/vmalert"
write_rendered_if_changed "$CONFIG_DIR/monitoring/vmalert/stack.yml" \
    "$DEPLOY_DIR/monitoring/rules/stack.yml.in"
log "wrote $CONFIG_DIR/monitoring/vmalert/stack.yml"

# Alertmanager: the alert state machine vmalert and the signup watcher push
# into. The state dir (silences, notification log) is regenerable -- losing a
# silence un-mutes an alert for one repeat interval -- so it lives outside
# BACKUP_PATHS.
mkdir -p "$DATA_DIR/monitoring/alertmanager" "$CONFIG_DIR/monitoring/alertmanager"

# The config is seeded ONCE and then belongs to the operator: it carries the SMTP
# password, so rewriting it would clobber an edited route tree and re-arm a
# placeholder. It goes through write_secret like every credential-bearing file,
# and the unit mounts the DIRECTORY so the replaced inode is visible. That buys no
# reload: Alertmanager v0.34 has no config watcher, so an edit takes effect only
# after `curl -X POST http://127.0.0.1:9093/-/reload` (docs/alerting.md).
ALERT_CFG="$CONFIG_DIR/monitoring/alertmanager/alertmanager.yml"
if ensure_secret "$ALERT_CFG" "alertmanager config"; then
    write_secret "$ALERT_CFG" < "$DEPLOY_DIR/examples/monitoring/alertmanager.yml.example"
    log "wrote $ALERT_CFG (mode 600) -- fill in SMTP before alerts are actually mailed"
fi

# Logs: the store, the shipper's checkpoint, and its config. Both run as container
# root = the login user, so a plain mkdir (no podman-unshare chown, unlike
# bitcoind). The config is rendered on every run, in place and through the
# directory mount, for the same two reasons as scrape.yml above. It is
# secret-free, so it renders like the other plain configs.
mkdir -p "$DATA_DIR/logs/vl" "$DATA_DIR/logs/vector" "$CONFIG_DIR/logs/vector"
( umask 077; cat "$DEPLOY_DIR/logs/vector.toml" > "$CONFIG_DIR/logs/vector/vector.toml" )
log "wrote $CONFIG_DIR/logs/vector/vector.toml"

# The backup job's restic cache (regenerable) and its repository. The repo is
# outside $DATA_DIR on purpose, so wiping the data dir does not delete it.
mkdir -p "$DATA_DIR/backup-cache" "$STACK_BACKUP_DIR"

# ---------------------------------------------------------------------------
# 3. the images built here: netcheck, tor
# ---------------------------------------------------------------------------
# None of these is pulled, so "is it built?" is the wrong question: a base-image
# bump rewrites only that image's Containerfile (Renovate's dockerfile manager),
# so leaving an existing image alone is how such a bump never reaches the host.
# The Containerfile's hash is baked in as a label and compared here
# (scripts/lib/units.sh).
ensure_local_image() { # image build-context
    local image="$1" dir="$2"
    [ -f "$dir/Containerfile" ] || return 0
    if image_is_current "$image" "$dir/Containerfile"; then
        log "$image is current"
        return 0
    fi
    if podman image exists "$image" 2>/dev/null; then
        # Worth rebuilding, but failing the install over a helper image would take
        # the host down: keep the bits that work and let verify.sh report the
        # drift (a broken Containerfile is an authoring bug, not an outage).
        log "$image is stale: its Containerfile changed since it was built"
        podman build --label "$(image_inputs_label "$dir/Containerfile")" \
            -t "$image" "$dir" >/dev/null \
            || warn "could not rebuild $image; keeping the current image (verify.sh reports it stale)"
        return 0
    fi
    log "building $image"
    podman build --label "$(image_inputs_label "$dir/Containerfile")" \
        -t "$image" "$dir" >/dev/null \
        || die "could not build $image"
}

# netcheck: the curl client the bridge-network checks exec into. net_curl
# (scripts/lib/probes.sh) runs it in a long-lived container to read a service by
# name on npm-network; loopback binds are read by the host's own curl.
if command -v podman >/dev/null 2>&1; then
    ensure_local_image "$NETCHECK_IMAGE" "$REPO_DIR/netcheck"
fi

# ---------------------------------------------------------------------------
# 4. tor image + torrc (+ the onion services)
# ---------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    ensure_local_image "$TOR_IMAGE" "$REPO_DIR/tor"
fi

# The onion services, rendered from the [onion.*] tables. Tor's own config is
# hand-tuned (the control-password hash is derived once, the SocksPolicy is
# deliberate), so it is seeded once and never rewritten as a whole. The
# hidden-service part is a *declaration*, so it lives in a marked region this
# installer rewrites on every run; deploy.sh digests torrc alongside the units and
# restarts tor when it changed.
ONION_MARK="# >>> onion services"
ONION_BEGIN="$ONION_MARK (rendered by deploy/install.sh from [onion.*])"
ONION_END="# <<< onion services"

onion_stanzas() {
    local i
    [ "${ONION_NAMES+x}" = x ] || return 0
    for i in "${!ONION_NAMES[@]}"; do
        # HiddenServicePort applies to the HiddenServiceDir above it, and the
        # directory must exist or be creatable: the mount is there, tor makes the
        # per-service dir 700 itself.
        printf 'HiddenServiceDir /var/lib/tor/onion/%s\n' "${ONION_NAMES[$i]}"
        printf 'HiddenServicePort 80 %s\n' "${ONION_TARGETS[$i]}"
    done
}

# Replace the marked region in torrc with the current declaration, appending it
# when absent (an adopted host predates it). Everything outside the markers --
# the hash, the SOCKS policy, the log line -- is left byte for byte.
#
# The block is identified by the marker's prefix, not the whole line: the
# description after it has been renamed once already, and an exact match left the
# older block in place with no terminator -- two HiddenServiceDir stanzas for the
# same directory, which tor refuses to start on.
sync_torrc_onions() { # torrc
    local torrc="$1" tmp stanzas
    [ -s "$torrc" ] || return 0
    stanzas=$(onion_stanzas)
    tmp=$(mktemp "$torrc.XXXXXX")
    awk -v b="$ONION_MARK" -v e="$ONION_END" '
        index($0, b) == 1 { inblock = 1; next }
        $0 == e { inblock = 0; next }
        inblock { next }
        { print }
    ' "$torrc" > "$tmp"
    # Drop the blank line(s) the removed region left behind, then re-append.
    awk 'BEGIN { n = 0 }
         { line[++n] = $0 }
         END { last = n
               while (last > 0 && line[last] == "") last--
               for (i = 1; i <= last; i++) print line[i] }' "$tmp" > "$tmp.trim"
    if [ -n "$stanzas" ]; then
        printf '\n%s\n%s\n%s\n' "$ONION_BEGIN" "$stanzas" "$ONION_END" >> "$tmp.trim"
    fi
    # cat into the original path: keeps its mode (600) and ownership.
    cat "$tmp.trim" > "$torrc"
    rm -f "$tmp" "$tmp.trim"
}

if [ -s "$TOR_DIR/torrc" ]; then
    log "keeping existing $TOR_DIR/torrc"
else
    mkdir -p "$TOR_DIR"
    hash=""
    if command -v podman >/dev/null 2>&1 && podman image exists "$TOR_IMAGE" 2>/dev/null; then
        # `tor --hash-password` prints a warning line to *stdout* first ("You
        # are running Tor as root..."), so take the hash by its shape -- Tor
        # writes it as 16:<hex> -- rather than the first line. The password goes
        # to the container on stdin, never as a `podman run` argument `ps` can
        # read (rotate.sh's tor_hash does the same).
        hash=$(printf '%s\n' "$TOR_SERVICE_PASSWORD" | podman run --rm -i "$TOR_IMAGE" sh -c '
            read -r pw
            tor --hash-password "$pw" 2>/dev/null
        ' | grep -E '^16:' | head -n1 || true)
    fi
    if [ -n "$hash" ]; then
        write_secret "$TOR_DIR/torrc" <<EOF
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
tighten_secret "$TOR_DIR/torrc"
sync_torrc_onions "$TOR_DIR/torrc"

# ---------------------------------------------------------------------------
# 5. SearXNG config (seed only; never clobber a live file)
# ---------------------------------------------------------------------------
mkdir -p "$SEARXNG_DATA_DIR"
if [ -s "$SEARXNG_DATA_DIR/settings.yml" ]; then
    log "keeping existing $SEARXNG_DATA_DIR/settings.yml"
else
    secret=$(rand_hex)
    log "seeding $SEARXNG_DATA_DIR/settings.yml with a fresh secret_key"
    sed "s/^  secret_key: .*/  secret_key: \"${secret}\"/" \
        "$DEPLOY_DIR/searxng/settings.yml" \
        | write_secret "$SEARXNG_DATA_DIR/settings.yml"
fi
tighten_secret "$SEARXNG_DATA_DIR/settings.yml"
if [ -s "$SEARXNG_DATA_DIR/limiter.toml" ]; then
    log "keeping existing $SEARXNG_DATA_DIR/limiter.toml"
else
    log "seeding $SEARXNG_DATA_DIR/limiter.toml"
    cp "$DEPLOY_DIR/searxng/limiter.toml" "$SEARXNG_DATA_DIR/limiter.toml"
fi

# ---------------------------------------------------------------------------
# 6. per-application env files (under the data dir)
# ---------------------------------------------------------------------------
# The SHAPE of every file below is deploy/env/<app>/<file>.env.in; this section
# keeps only the values and the write policy. The three policies are not
# interchangeable:
#   - seed_rendered: write only when missing. An operator edit (boltmesh/app.env)
#     and a rotation (rotate.sh's set_env_key) survive every install.
#   - write_rendered_if_changed: machine-owned, rewritten when the bytes differ.
#   - render_unit: units only, never a config file.
# The eight one-line token.env files stay table-driven by seed_token_env: a
# template per file would be worse, not better.

seed_token_env searxng-mcp SEARXNG_MCP_TOKEN
seed_token_env bitcoin-node-mcp BITCOIN_MCP_TOKEN
seed_token_env fulcrum-mcp FULCRUM_MCP_TOKEN
seed_token_env victoria-logs-mcp LOGS_MCP_TOKEN
seed_token_env victoriametrics-mcp METRICS_MCP_TOKEN
seed_token_env crowdsec-mcp CROWDSEC_MCP_TOKEN
seed_token_env btcpay-mcp BTCPAY_MCP_TOKEN
seed_token_env monero-node-mcp MONERO_MCP_TOKEN

# Static shapes: the table is the whole difference between them.
SEED_ENV_TEMPLATES=(
    "fulcrum-mcp/upstream.env"
    "victoria-logs-mcp/upstream.env"
    "victoriametrics-mcp/upstream.env"
    "monero-node-mcp/upstream.env"
    "monero-wallet-mcp/spend.env"
    "lightning-mcp/spend.env"
)
for rel in "${SEED_ENV_TEMPLATES[@]}"; do
    seed_rendered "$CONFIG_DIR/$rel" \
        "$(dirname "$rel") $(basename "$rel" .env) env" \
        "$DEPLOY_DIR/env/$rel.in"
done

# bitcoin-node-mcp: the node's own RPC credentials, derived from §1.
seed_rendered "$CONFIG_DIR/bitcoin-node-mcp/upstream.env" \
    "bitcoin-node-mcp upstream env" \
    "$DEPLOY_DIR/env/bitcoin-node-mcp/upstream.env.in"

# crowdsec-mcp: the bearer token clients present (seeded above), and the bouncer
# key it reads decisions with. NOT seed-once -- derived from
# $CROWDSEC_MCP_BOUNCER_KEY in secrets.env, which is the authority (the same value
# the rendered crowdsec unit registers as the "mcp" bouncer), so this is rewritten
# whenever the two disagree. Seeding once would split a rotated secret.
write_rendered_if_changed "$CONFIG_DIR/crowdsec-mcp/lapi.env" \
    "$DEPLOY_DIR/env/crowdsec-mcp/lapi.env.in"

# btcpay-mcp: the bearer token clients present (seeded above), and the upstream
# wiring. The key is not seeded from a copy: btcpay_bootstrap.py mints it into
# config/btcpay/bootstrap.env, and configure.sh's write_btcpay_mcp_env() rewrites
# this file from that state after every bootstrap. This seed only gives the unit a
# URL before the first bootstrap.
seed_env "$CONFIG_DIR/btcpay-mcp/upstream.env" "btcpay-mcp upstream env" <<EOF
# The BTCPay instance this server reads. configure.sh rewrites this file from
# config/btcpay/bootstrap.env (URL, the read-only BTCPAY_MCP_KEY, store id and
# the public origin) after every bootstrap; do not hand-edit it.
BTCPAY_URL=http://btcpay:49392
EOF

# BTC RPC Explorer's configuration. The app is configured entirely through the
# environment (EnvironmentFile=, not a rendered Exec=), needs the same bitcoind
# RPC credentials plus Fulcrum's Electrum endpoint, and keeps no data of its own.
# Address history comes from Fulcrum; any txid resolves through bitcoind's txindex.
seed_rendered "$CONFIG_DIR/btc-explorer/btc-explorer.env" "btc explorer env" \
    "$DEPLOY_DIR/env/btc-explorer/btc-explorer.env.in"

XMRW_ENV="$CONFIG_DIR/monero-wallet-mcp"
if ensure_secret "$XMRW_ENV/token.env" "monero-wallet-mcp token env"; then
    MONERO_MCP_TOKEN=$(new_or_reused_token monero-wallet-mcp MONERO_MCP_TOKEN) \
    MONERO_MCP_SPEND_TOKEN=$(rand_hex) \
        seed_rendered "$XMRW_ENV/token.env" "monero-wallet-mcp token env" \
            "$DEPLOY_DIR/env/monero-wallet-mcp/token.env.in" \
            "with a read and a spend token"
fi
# Derived every run: the MCP reads BTCPay's view-only plugin wallet. The wallet
# RPC has no login by design (the plugin hardcodes empty credentials) and holds no
# spend key, so the MCP's spend tools cannot move funds.
write_rendered_if_changed "$XMRW_ENV/upstream.env" \
    "$DEPLOY_DIR/env/monero-wallet-mcp/upstream.env.in"

LN_ENV="$CONFIG_DIR/lightning-mcp"
if ensure_secret "$LN_ENV/token.env" "lightning-mcp token env"; then
    LIGHTNING_MCP_TOKEN=$(new_or_reused_token lightning-mcp LIGHTNING_MCP_TOKEN) \
    LIGHTNING_MCP_SPEND_TOKEN=$(rand_hex) \
        seed_rendered "$LN_ENV/token.env" "lightning-mcp token env" \
            "$DEPLOY_DIR/env/lightning-mcp/token.env.in" \
            "with a read and a spend token"
fi

# ---------------------------------------------------------------------------
# BoltMesh env files (under the data dir, like every other app's)
# ---------------------------------------------------------------------------
# The app reads one flat environment, so the split is by who owns each value:
# install.sh generates the database and signing keys, the operator fills in the
# third-party credentials, and btcpay/backend.env comes from configure.sh after
# the bootstrap provisioned the store.
BOLT_DB="$CONFIG_DIR/boltmesh"

if ensure_secret "$BOLT_DB/db.env" "boltmesh db env"; then
    PG_PASSWORD=$(rand_hex) \
        seed_rendered "$BOLT_DB/db.env" "boltmesh db env" \
            "$DEPLOY_DIR/env/boltmesh/db.env.in"
fi

# The pre-backup dump's connection settings, read back from db.env so a second
# run keeps the same password.
pg_password=$(env_value "$BOLT_DB/db.env" POSTGRES_PASSWORD)
if ensure_secret "$BOLT_DB/dump.env" "boltmesh dump env"; then
    PG_PASSWORD="$pg_password" \
        seed_rendered "$BOLT_DB/dump.env" "boltmesh dump env" \
            "$DEPLOY_DIR/env/boltmesh/dump.env.in"
fi

if ensure_secret "$BOLT_DB/secrets.env" "boltmesh secrets env"; then
    SECRET_KEY=$(new_or_reused_secret boltmesh-backend SECRET_KEY) \
    REFRESH_SECRET_KEY=$(new_or_reused_secret boltmesh-backend REFRESH_SECRET_KEY) \
    NODE_SECRET_KEY=$(new_or_reused_secret boltmesh-backend NODE_SECRET_KEY) \
    BOOTSTRAP_SECRET_PEPPER=$(new_or_reused_secret boltmesh-backend BOOTSTRAP_SECRET_PEPPER) \
        seed_rendered "$BOLT_DB/secrets.env" "boltmesh secrets env" \
            "$DEPLOY_DIR/env/boltmesh/secrets.env.in"
fi

if ensure_secret "$BOLT_DB/app.env" "boltmesh app env"; then
    seed_rendered "$BOLT_DB/app.env" "boltmesh app env" \
        "$DEPLOY_DIR/env/boltmesh/app.env.in" \
        "fill in OAuth/SMTP/GitHub before use"
fi

# Backup repository settings for backup.container. The unit is secret-free and
# reads these through EnvironmentFile; the password follows the same resolution
# order (an operator-supplied value wins, so an offsite repo opens on a fresh
# host before this file exists -- see backup.sh). Keep a copy off the data disk.
BACKUP_ENV="$CONFIG_DIR/backup/backup.env"
if ensure_secret "$BACKUP_ENV" "backup env"; then
    restic_password=$(first_nonempty \
        "$(read_secret RESTIC_PASSWORD)" \
        "${RESTIC_PASSWORD:-}" \
        "$(rand_hex)")
    RESTIC_PASSWORD="$restic_password" \
        seed_rendered "$BACKUP_ENV" "backup env" \
            "$DEPLOY_DIR/env/backup/backup.env.in"
fi

# Monitoring: the alert targets, the dead-man's-switch heartbeat and the
# thresholds for monitor.service. Empty values mean journal-only / the built-in
# default, so a fresh host is safe before this file is filled in.
#
# The example IS the seeded file, copied verbatim: one file documents every key
# monitor.sh reads, so the two cannot drift. install.sh never overwrites it.
MON_ENV="$CONFIG_DIR/monitoring/monitor.env"
if ensure_secret "$MON_ENV" "monitoring env"; then
    write_secret "$MON_ENV" < "$DEPLOY_DIR/examples/monitoring/monitor.env.example"
    log "wrote $MON_ENV (mode 600) -- fill in the heartbeat (and SMTP in the alertmanager config) to be paged"
fi

# nginx-proxy-manager's admin API, for npm-hosts.sh: it reconciles every proxy
# host the stack serves ([npm.*] in services.toml). The admin login (or a
# pre-created API token) is a secret, so mode 600; empty means the script logs a
# one-line skip rather than failing a deploy.
NPM_ENV="$CONFIG_DIR/npm/api.env"
if ensure_secret "$NPM_ENV" "nginx-proxy-manager api env"; then
    write_secret "$NPM_ENV" <<'EOF'
# Credentials for the nginx-proxy-manager admin API (port 81), used by
# scripts/npm-hosts.sh to reconcile every proxy host the stack serves (declared
# in deploy/services.toml). See deploy/examples/npm/api.env.example.
#
# The admin login (as set on first access to the UI on port 81). Preferred: a
# token minted from it is short-lived and refreshed on every run.
NPM_EMAIL=
NPM_PASSWORD=
# Optional: an API token from the UI (Settings -> API Tokens). Use this only if
# you would rather not store the admin login; it expires, so re-runs after that
# need a fresh one.
NPM_TOKEN=
# Request a Let's Encrypt certificate for any declared host that has none (1/0),
# reusing an existing one otherwise. Needs each host's DNS and port 80 to reach
# this machine.
NPM_REQUEST_CERT=1
EOF
    log "wrote $NPM_ENV (mode 600) -- fill in NPM_EMAIL/NPM_PASSWORD (or NPM_TOKEN)"
fi

# Uptime-Kuma's admin login is NOT seeded: the account is created in its setup
# wizard on first visit, and the UI owns the monitors and the status page (see
# docs/proxy.md). Nothing host-side reads that login any more, so there is no
# api.env to fill in.

# The monitor's record: the audit log, the spend baseline and its state file.
# Deliberately NOT under config/ (it is not secret); deploy/backup.container
# backs it up. scripts/spend-audit.sh seeds its own baselines on the first run.
mkdir -p "$DATA_DIR/audit"

# The runes need a running lightningd. configure.sh re-runs this once the daemon
# is up, so it is best-effort here and self-heals. The proof and the mint/retry
# loop live in scripts/lib/daemons.sh (cln_rune_usable / cln_mint_rune) because
# rotate.sh mints the same runes on a rotation.

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
    && ! { cln_rune_usable "$read_rune" && cln_rune_usable "$spend_rune"; }; then
    if lightning_cli getinfo >/dev/null 2>&1; then
        log "creating runes on the node"
        new_read=$(cln_mint_rune "$READ_RESTRICTIONS" | cut -d' ' -f1 || true)
        new_spend=$(cln_mint_rune "$SPEND_RESTRICTIONS" | cut -d' ' -f1 || true)
        if [ -n "$new_read" ] && [ -n "$new_spend" ]; then
            read_rune="$new_read"
            spend_rune="$new_spend"
            node_needs_write=1
            log "created a usable read rune and a read+spend rune"
        fi
    else
        log "lightningd not reachable yet; runes will be created by a later ./configure.sh run"
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

# BoltMesh's payment wiring is BTCPay now. The store URL/key/id/webhook secret
# are written after the bootstrap has provisioned them (see the
# btcpay/backend.env contract in the backend unit); nothing here talks to CLN or
# a wallet-rpc directly.

# ---------------------------------------------------------------------------
# BTCPay config. The bootstrap owns the store/keys/webhook and writes them back
# into bootstrap.env; backend.env is the four-value contract the backend reads
# and is written after a successful bootstrap (configure.sh), not here.
# ---------------------------------------------------------------------------
BTC_CONFIG="$CONFIG_DIR/btcpay"
mkdir -p "$BTC_CONFIG"
if ensure_secret "$BTC_CONFIG/bootstrap.env" "btcpay bootstrap env"; then
    BTCPAY_ADMIN_PASSWORD=$(rand_hex) \
        seed_rendered "$BTC_CONFIG/bootstrap.env" "btcpay bootstrap env" \
            "$DEPLOY_DIR/env/btcpay/bootstrap.env.in" \
            "change the admin email/password before first use"
fi
if [ ! -s "$BTC_CONFIG/backend.env" ]; then
    write_secret "$BTC_CONFIG/backend.env" <<EOF
# Written by configure.sh from $BTC_CONFIG/bootstrap.env after the bootstrap has
# run. The backend/worker units read exactly these four values.
EOF
    log "seeded $BTC_CONFIG/backend.env (filled in after the bootstrap)"
fi
if ensure_secret "$BTC_CONFIG/xmr-wallet.env" "btcpay xmr wallet env"; then
    seed_rendered "$BTC_CONFIG/xmr-wallet.env" "btcpay xmr wallet env" \
        "$DEPLOY_DIR/env/btcpay/xmr-wallet.env.in" \
        "fill it in to enable XMR"
fi

# ---------------------------------------------------------------------------
# 7. units: render every one (they all reference the data or config dir)
# ---------------------------------------------------------------------------
render_unit() {
    local src="$1" target="$2" tmp stamp=""
    # Carry the generation stamp the installed unit already has. The stamp is a
    # digest of everything *except* its own line, so it changes nothing the digest
    # covers -- and it keeps render_unit_backedup's cmp honest: without it every
    # re-render would differ from the previous file by the stamp alone and .bak
    # would be rewritten on every run, destroying the rollback.
    if [ "${target##*.}" = container ] && [ -f "$target" ]; then
        stamp=$(unit_stamp_value "$target")
    fi
    tmp="$(mktemp)"
    render_to "$src" "$tmp"
    if [ -n "$stamp" ]; then
        unit_stamped "$tmp" "$stamp" > "$tmp.stamped"
        mv -f "$tmp.stamped" "$tmp"
    fi
    [ -L "$target" ] && rm -f "$target"
    install -m 600 "$tmp" "$target"
    rm -f "$tmp"
}

# Render a whole directory tree through render_unit, preserving its shape. Used
# for the CrowdSec config (parsers/, scenarios/, acquis.d/), whose files the
# container mounts one by one -- a directory mount over /etc/crowdsec would fight
# the image's entrypoint, which seeds the rest of that tree.
#
# The destination is an install-owned MIRROR, not a merge: a file deleted from
# deploy/crowdsec/ must leave the installed tree too, or CrowdSec keeps loading
# it -- and since unit_digest hashes that tree, its removal would not show as
# drift and the unit would not restart. Runtime state is in $DATA_DIR/ids/crowdsec.
sync_tree() { # src-dir dest-dir
    local src="$1" dest="$2" rel stale=()
    [ -d "$src" ] || return 0
    ( cd "$src" && find . -type f -print ) | while IFS= read -r rel; do
        rel="${rel#./}"
        mkdir -p "$dest/$(dirname "$rel")"
        render_unit "$src/$rel" "$dest/$rel"
    done
    [ -d "$dest" ] || return 0
    while IFS= read -r rel; do
        rel="${rel#./}"
        [ -f "$src/$rel" ] || stale+=("$rel")
    done < <( cd "$dest" && find . -type f -print )
    for rel in "${stale[@]}"; do
        rm -f "$dest/$rel" \
            || die "could not remove stale $dest/$rel (deleted from $src)"
    done
    find "$dest" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# runtime files a container runs, but that the checkout owns
# ---------------------------------------------------------------------------
# Two units run a file this checkout owns rather than one in $DATA_DIR: monerod's
# --block-notify helper and the BTCPay bootstrap script. Mounting them from the
# repo would make the checkout a *runtime* dependency of a container's start
# (podman fails on a missing bind source, naming a path nobody edited). Host
# scripts in deploy/*.service still run from the checkout -- they are the tooling
# -- but a container a daemon starts must not. So both are staged here, and CI
# fails if a container template mentions @REPO_DIR@.
mkdir -p "$DATA_DIR/bin"
install -m 755 "$DEPLOY_DIR/btcpay/monero-notify.sh" "$DATA_DIR/bin/monero-notify.sh"
install -m 755 "$REPO_DIR/scripts/btcpay_bootstrap.py" "$DATA_DIR/bin/btcpay_bootstrap.py"

# Render a unit over the installed one, keeping the render it replaces as
# <target>.bak. Three things are load-bearing:
#   - the backup is the *previous* render, not the first the host ever had;
#   - cp -p keeps mode 600 -- several rendered units carry @PLACEHOLDER@ secrets;
#   - it backs up only when the render changes the file, because configure.sh
#     re-runs install.sh (the runes need a running node). An unconditional backup
#     would record what the first run just wrote, destroying the rollback.
render_unit_backedup() { # src target
    local prev="" label
    if [ -e "$2" ] && [ ! -L "$2" ]; then
        prev=$(mktemp)
        cp -p "$2" "$prev"
    fi
    render_unit "$1" "$2"
    [ -n "$prev" ] || return 0
    if cmp -s "$prev" "$2"; then
        rm -f "$prev"
        return 0
    fi
    label=$(basename "$2")
    mv -f "$prev" "$2.bak"
    log "backed up previous $label -> $label.bak"
}

mkdir -p "$QUADLET_DIR"
# Before the units: podman's event log is a host config, installed once here
# rather than flagged at every exec call site (deploy/podman/99-stack.conf).
podman_events_dropin "$PODMAN_CONF_DIR/containers.conf.d"
podman_events_check
for u in "${UNITS[@]}"; do
    # An .in is a template; the rendered target drops the suffix.
    render_unit_backedup "$DEPLOY_DIR/$u" "$QUADLET_DIR/${u%.in}"
done
log "rendered ${#UNITS[@]} units (mode 600)"

# netcheck-host folded into the host's own curl (docs/units.md). A host
# upgrading from an older checkout still has the rendered unit, and removing the
# template alone leaves its generated service restarting the container forever.
if [ -e "$QUADLET_DIR/netcheck-host.container" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop netcheck-host.service >/dev/null 2>&1 || true
        systemctl --user reset-failed netcheck-host.service >/dev/null 2>&1 || true
    fi
    rm -f "$QUADLET_DIR/netcheck-host.container" "$QUADLET_DIR/netcheck-host.container.bak"
    log "removed the retired netcheck-host unit"
fi

# Plain user units go to USER_UNIT_DIR: Quadlet will not generate them. The timers
# activate the services they name -- backup.service (generated by Quadlet from
# backup.container) and monitor.service (a plain host-script unit).
mkdir -p "$USER_UNIT_DIR"
for u in "${USER_UNITS[@]}"; do
    render_unit_backedup "$DEPLOY_DIR/$u" "$USER_UNIT_DIR/$u"
done
log "installed ${#USER_UNITS[@]} user unit(s) into $USER_UNIT_DIR"

# ---------------------------------------------------------------------------
# the nginx rate-limit zones
# ---------------------------------------------------------------------------
# nginx-proxy-manager includes /data/nginx/custom/http.conf inside http {} and
# never regenerates custom/, so zones declared there survive every reconciliation
# -- which is why they cannot live in proxy_host/*.conf (NPM rewrites those from
# its database).
#
# Seeded before deploy.sh starts NPM, because a vhost referencing an undeclared
# zone makes nginx refuse to start -- and on Network=host that takes the admin UI
# down with the site.
mkdir -p "$NPM_DIR/data/nginx/custom"
# vector ships NPM's access and error logs and bind-mounts this directory, so it
# has to exist before that unit starts, or podman creates it at the wrong moment
# with the wrong owner. NPM creates it itself on first start, after install.sh.
mkdir -p "$NPM_DIR/data/logs"
if ! cmp -s "$DEPLOY_DIR/npm/http.conf" "$NPM_DIR/data/nginx/custom/http.conf" 2>/dev/null; then
    install -m 644 "$DEPLOY_DIR/npm/http.conf" "$NPM_DIR/data/nginx/custom/http.conf"
    # The npm/data tree is mounted with :z, which relabels the subtree when the
    # container starts -- but a file written *after* that keeps the default label,
    # and nginx then refuses to load it ("failed (13: Permission denied)").
    # Relabel here rather than relying on a restart a deploy may not perform.
    if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        chcon -t container_file_t "$NPM_DIR/data/nginx/custom/http.conf" 2>/dev/null \
            || warn "could not label $NPM_DIR/data/nginx/custom/http.conf for containers"
    fi
    log "seeded the nginx rate-limit zones into $NPM_DIR/data/nginx/custom/http.conf"
fi

# ---------------------------------------------------------------------------
# the IDS config tree
# ---------------------------------------------------------------------------
# CrowdSec's parsers, scenarios, whitelists and acquisition, rendered into
# $CONFIG_DIR/ids/crowdsec and mounted file by file. Rendered rather than mounted
# from the repo for the same reason as scrape.yml: an install artifact changes on
# a deploy, and unit_digest hashes this tree under "crowdsec", so a changed parser
# restarts the unit instead of waiting for a reboot.
sync_tree "$DEPLOY_DIR/crowdsec" "$CONFIG_DIR/ids/crowdsec"
# The container's own state: /etc/crowdsec (seeded on first start, then the hub
# installs live there) and the sqlite decisions DB. Both regenerable, so both
# stay outside BACKUP_PATHS.
mkdir -p "$DATA_DIR/ids/crowdsec/etc" "$DATA_DIR/ids/crowdsec/data"
log "rendered the crowdsec config into $CONFIG_DIR/ids/crowdsec"

# Stamp every rendered unit with the digest of its own definition: the answer to
# "which definition was this container started from?" travels with the container
# as an OCI label, so nothing has to record an apply and no writer can claim one
# that did not happen (scripts/lib/units.sh, docs/units.md). Last, after every
# render and every config tree the digest folds in, and before the daemon-reload
# below --
# the stamp only takes effect when the unit next starts, which is the point.
unit_stamp_generations "$QUADLET_DIR" \
    || die "could not stamp the rendered units in $QUADLET_DIR"
log "stamped the rendered unit generations in $QUADLET_DIR"
# The render/applied digest files are superseded by the stamps above: a host
# upgraded from the previous scheme keeps them until this runs once, and nothing
# reads them any more.
if [ -e "$DATA_DIR/audit/units.rendered" ] || [ -e "$DATA_DIR/audit/units.applied" ]; then
    rm -f "$DATA_DIR/audit/units.rendered" "$DATA_DIR/audit/units.applied"
    log "removed the superseded unit-digest baseline from $DATA_DIR/audit"
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    # enable --now so the schedules are live without a reboot. On a fresh host with
    # Persistent=true this may run one backup immediately; it initialises the
    # repository and is harmless.
    systemctl --user enable --now "${USER_TIMERS[@]}" >/dev/null 2>&1 \
        || log "could not enable ${USER_TIMERS[*]}; run: systemctl --user enable --now ${USER_TIMERS[*]}"
    log "systemd --user reloaded"
fi

cat <<EOF

Done. Everything the stack owns lives under:
  $DATA_DIR
    bitcoin/ monero/ fulcrum/ btcpay/ nbxplorer/ cln/ tor/ searxng/ npm/
    uptime-kuma/    <- the status page's state: embedded MariaDB, monitors, login
    ids/            <- suricata's eve.json (root-owned) and crowdsec's state
    postgres/       <- the BoltMesh cluster (dumped, not backed up raw)
    postgres-dump/  <- the pre-backup pg_dumpall
    npm-dump/       <- NPM's SQLite database, consistent copy for the backup
    uptime-kuma-dump/ <- kuma's embedded MariaDB, mariadb-dump for the backup
    config/         <- all bearer tokens and secrets (mode 600)
    audit/          <- the monitor's log and the spend tripwire baselines
    monitoring/     <- the metrics store and node-exporter's textfile (regenerable)
    logs/           <- the log store and vector's checkpoint (regenerable)
    backup-cache/   <- restic's cache (regenerable)
    backup-verify/  <- the restore drill's scratch target: created by its first
                       run, wiped before and after each one (regenerable)
    backup-verify-db/ <- the database drill's scratch target: the postgres dump
                       only, same lifecycle as backup-verify/ (regenerable)
  $STACK_BACKUP_DIR
    the restic repository the nightly backup writes (backup.timer);
    backup-verify.timer restores it to a scratch dir every week (verdict in
    $DATA_DIR/audit/backup-verify.status), and backup-verify-db.timer replays
    the postgres dump into a throwaway cluster every month (verdict in
    $DATA_DIR/audit/backup-verify-db.status)

Next:  ./deploy.sh         # build images, start/restart everything
       ./configure.sh      # wait, then mint runes / BTCPay state / migrations
The two explorers are built by ./deploy.sh from btc-explorer/ and xmr-explorer/
  (not pulled): BTC RPC Explorer (Node) and MoneroBlock (Go, RPC-only). Both are
  small local builds. They are served at https://$BTC_EXPLORER_HOST and
  https://$XMR_EXPLORER_HOST once the NPM admin login is in place.
Spending is OFF on both money servers until you set ENABLE_SPENDING=1 under
  $CONFIG_DIR/monero-wallet-mcp/spend.env  and  $CONFIG_DIR/lightning-mcp/spend.env
BoltMesh is wired to BTCPay; fill in the OAuth / SMTP / GitHub values in
  $CONFIG_DIR/boltmesh/app.env before first use, and put the XMR address / view
  key / restore height in $CONFIG_DIR/btcpay/xmr-wallet.env to enable XMR-CHAIN.
The monitor runs every 5 minutes (monitor.timer) and writes its findings as
  metrics; vmalert (rules in $CONFIG_DIR/monitoring/vmalert/stack.yml) decides
  when one has held long enough and hands it to Alertmanager (loopback :9093).
  Mail goes out through Alertmanager once SMTP is filled in under
  $CONFIG_DIR/monitoring/alertmanager/alertmanager.yml (seeded once with those
  keys commented out, then yours to edit), and the dead-man's switch
  (MONITOR_PING_URL) is set in $CONFIG_DIR/monitoring/monitor.env. Prove the
  delivery path with scripts/monitor.sh --test.
BoltMesh signups are mailed one per registration (registrations.timer, every
  minute): scripts/registrations.sh --dry-run shows what would be sent and
  --test proves the severity=info route. The existing accounts are seeded as
  already seen on the first run, so nothing historical is mailed.
Metrics are collected every minute (metrics.timer) and stored for
  ${METRICS_RETENTION} in $DATA_DIR/monitoring/vm; read them at
  http://127.0.0.1:8428/vmui over an SSH tunnel (no public host, on purpose).
Logs are shipped from journald every second into $DATA_DIR/logs/vl and kept for
  ${LOGS_RETENTION} (${LOGS_MAX_BYTES} cap). Search them with scripts/logs.sh, or
  open http://127.0.0.1:9428/select/vmui over an SSH tunnel:
  ssh -L 9428:127.0.0.1:9428 <host>
The MCP servers are served as https://$MCP_HOST/<prefix> once
  $CONFIG_DIR/npm/api.env has the nginx-proxy-manager admin login
  (scripts/npm-hosts.sh, which ./deploy.sh runs).
The status page's monitors and its published page are created in the
  Uptime-Kuma UI (https://$UPTIME_KUMA_HOST, the setup wizard's account);
  nothing reconciles them, so keep the database dump in the backup set.
  docs/proxy.md lists the checks the public surface expects.
Keep a copy of RESTIC_PASSWORD ($BACKUP_ENV) off the data disk: it is the only
key to the backups.
EOF
