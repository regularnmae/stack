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
# README's rollback section promises). Nothing here prints a secret.
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

# ---------------------------------------------------------------------------
# the root tier
# ---------------------------------------------------------------------------
# `--root` installs deploy/root/, the ONE privileged unit in this repo: the
# Suricata sensor, which needs CAP_NET_RAW in the init user namespace and
# therefore cannot be a rootless Quadlet (see deploy/root/suricata.container).
# bootstrap.sh is its only caller, under sudo; the user-side install below never
# runs in this mode, so nothing here creates a root-owned file inside the data
# dir.
#
# The split is deliberate: $DATA_DIR stays user-owned (the sensor only writes
# its logs into $DATA_DIR/ids, which the host user can read and this script
# creates), while everything a rootful container *reads* lives root-owned under
# /etc/stack-ids. A user-writable config consumed by a root container would be a
# privilege boundary.
# Values substituted into a unit go through esc() (scripts/lib.sh) on both the
# render side and verify.sh's comparison side; the comment there says what an
# unescaped `|` or `&` does to a data dir.

# ---------------------------------------------------------------------------
# podman's own event log
# ---------------------------------------------------------------------------
# Every podman invocation writes an event and the default backend is the
# journal: an exec session is two lines (`exec`, `exec_died`, each with
# the image's full label dump) and podman's generated healthcheck units log a
# `health_status` line on *every* check, healthy or not. Measured on this host
# before this setting existed: 4,156 of 9,315 journal lines an hour (1.8 MB of
# 2.4 MB) were podman events -- 2,357 health_status, 1,352 exec -- and all of it
# reached the log store, burying the cross-service timeline `scripts/logs.sh`
# exists to answer questions from. metrics.sh alone makes eight execs a minute,
# i.e. sixteen journal lines, every minute.
#
# This belongs in podman's own config, not in a flag at the 64 `podman exec`
# call sites: `--events-backend=none` (scripts/lib.sh's net_curl) cannot reach
# the healthcheck units at all, says nothing about the next script anyone
# writes, and the one-flag-at-one-place version of it is exactly how the flood
# came back. `events_logger` has no environment-variable equivalent, so the
# config file is the one lever that covers them all -- and there are two of
# them, because the sensor (deploy/root/, started by the *system* manager) is
# not the login user's podman: the rootless file below, and root's own in
# install_root_tier. Both are rendered here.
#
# "file", not "none": the events are a diagnostic (what started when, did the
# check fire), and the file backend keeps `podman events` reading them from a
# size-capped ring in the runtime dir (tmpfs, gone at reboot). At ~1.2 MB an
# hour of events here, 10m is about eight hours; "none" would throw the
# diagnostic away to save the same bytes. Nothing needs a restart: podman reads
# this per invocation, so the next metrics tick and the next healthcheck pick it
# up -- unlike a rendered unit, where a re-render alone changes nothing.
#
# The merge has to be table-aware. Appending a second `[engine]` to a file that
# already has one is a TOML duplicate-table error, and podman then refuses to
# run *anything* for that user, so the candidate is validated with podman itself
# (`CONTAINERS_CONF` pointed at it, `podman info` must report "file") before it
# replaces the real file. A file that does not pass is left alone.
#
# Defined above the root-tier block for the same reason as esc(): the root pass
# runs before the rest of this file has been read, so a helper defined below it
# is "command not found" when install_root_tier calls it.
podman_events_write() { # conf-file
    local conf="$1" src tmp val header=0
    command -v podman >/dev/null 2>&1 || return 0
    if [ -f "$conf" ]; then
        src="$conf"
    else
        # A missing file is not the same as an empty one: only this case gets the
        # header comment, so an operator's own file is never annotated.
        src=/dev/null
        header=1
    fi
    mkdir -p "$(dirname "$conf")"

    tmp=$(mktemp) || return 1
    awk -v header="$header" '
        function flush(   i, last, line) {
            # Trailing blank lines inside the table are held back, so an added
            # key lands at the end of the table rather than after a gap.
            last = 0
            for (i = 1; i <= n; i++) if (body[i] ~ /[^[:space:]]/) last = i
            print hdr
            for (i = 1; i <= last; i++) {
                line = body[i]
                if (line ~ /^[[:space:]]*events_logger[[:space:]]*=/) {
                    print "events_logger = \"file\""; saw1 = 1; continue
                }
                if (line ~ /^[[:space:]]*events_logfile_max_size[[:space:]]*=/) {
                    print "events_logfile_max_size = \"10m\""; saw2 = 1; continue
                }
                print line
            }
            if (!saw1) print "events_logger = \"file\""
            if (!saw2) print "events_logfile_max_size = \"10m\""
            n = 0; saw1 = 0; saw2 = 0
        }
        BEGIN {
            if (header) {
                print "# Podman configuration written by deploy/install.sh."
                print "# events_logger: journald is where podman events used to pile"
                print "# up, two lines per exec and one per healthcheck, and it is the log"
                print "# store behind it that paid for them."
            }
        }
        /^[[:space:]]*\[/ {
            if (in_engine) { flush(); in_engine = 0 }
            if ($0 ~ /^[[:space:]]*\[[[:space:]]*engine[[:space:]]*\][[:space:]]*$/) {
                in_engine = 1; seen = 1; hdr = $0
            } else print
            next
        }
        in_engine { body[++n] = $0; next }
        { print }
        END {
            if (in_engine) flush()
            else if (!seen) {
                print ""
                print "[engine]"
                print "events_logger = \"file\""
                print "events_logfile_max_size = \"10m\""
            }
        }
    ' "$src" > "$tmp" || { rm -f "$tmp"; warn "could not render $conf"; return 0; }

    if cmp -s "$tmp" "$conf" 2>/dev/null; then
        rm -f "$tmp"
        return 0
    fi
    if ! val=$(CONTAINERS_CONF="$tmp" podman info --format '{{.Host.EventLogger}}' 2>/dev/null) \
        || [ "$val" != file ]; then
        rm -f "$tmp"
        warn "podman would not accept the event-logger setting (${val:-no answer}); leaving $conf alone -- fix or remove it by hand"
        return 0
    fi
    install -m 644 "$tmp" "$conf"
    rm -f "$tmp"
    log "podman events -> bounded file, not journald ($conf)"
}

# The login user's own podman -- every script and timer this repo runs, plus the
# shell an operator pokes a container from. Root's is written by the root tier
# (install_root_tier) because the sensor's healthchecks are podman children of
# the *system* manager. Called from the main flow below, and a no-op when the
# file is already right.
podman_events_conf() {
    podman_events_write "$PODMAN_CONF_DIR/containers.conf"
}

ROOT_UNIT_DIR=/etc/containers/systemd
ROOT_CONFIG_DIR=/etc/stack-ids

root_render() { # src dest mode [data-dir]
    local tmp
    mkdir -p "$(dirname "$2")"
    tmp=$(mktemp)
    sed -e "s|@DATA_DIR@|$(esc "$4")|g" \
        -e "s|@CONFIG_DIR@|$(esc "$4/config")|g" \
        -e "s|@REPO_DIR@|$(esc "$REPO_DIR")|g" \
        -e "s|@IDS_RETENTION_DAYS@|$(esc "${IDS_RETENTION_DAYS:-14}")|g" \
        "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
    install -m "$3" "$tmp" "$2"
    rm -f "$tmp"
}

install_root_tier() {
    local data="$1" f bkey benv aenv n_rules bouncer_installed=0
    [ "$(id -u)" = 0 ] || die "install.sh --root must run as root (bootstrap.sh calls it with sudo)"
    [ -n "$data" ] || die "install.sh --root needs --data-dir (bootstrap.sh passes the resolved data dir)"
    [ -d "$data" ] || die "$data does not exist; run ./deploy.sh once first, or pass the right --data-dir"
    [ -f "$DEPLOY_DIR/root/suricata.container" ] || die "missing $DEPLOY_DIR/root/suricata.container"

    log "installing the root tier (Suricata) for data dir $data"

    # Root's podman config, so the sensor's own healthchecks stop writing a
    # `health_status` event to the journal every 30 seconds. They are podman's
    # children under the *system* manager, so the login user's config (written on
    # the user side, podman_events_write) cannot reach them; this is the same
    # setting in root's chain, and it is the whole remainder of the flood once
    # the user side is in place. /etc is where a system manager's podman reads it.
    podman_events_write /etc/containers/containers.conf

    # The configuration the container reads. Root-owned: a rootful container
    # consuming a file the stack user can edit is a privilege boundary.
    install -d -m 755 "$ROOT_CONFIG_DIR/suricata" "$ROOT_CONFIG_DIR/suricata/rules"
    for f in suricata.yaml threshold.conf disable.conf; do
        root_render "$DEPLOY_DIR/root/suricata/$f" "$ROOT_CONFIG_DIR/suricata/$f" 644 "$data"
    done
    root_render "$DEPLOY_DIR/root/suricata/start.sh" "$ROOT_CONFIG_DIR/suricata/start.sh" 755 "$data"
    root_render "$DEPLOY_DIR/root/suricata/rules/local.rules" \
        "$ROOT_CONFIG_DIR/suricata/rules/local.rules" 644 "$data"

    # $DATA_DIR/ids is the one directory with two owners: the sensor's state
    # (ids/suricata, root-owned, because a rootful container writes it) and the
    # crowdsec state next to it (ids/crowdsec, user-owned, because that container
    # is rootless). The parent goes to the invoking user so the *user-side*
    # install can keep creating ids/crowdsec/ on later deploys -- root writes
    # ids/suricata/ regardless of the mode bits. 0755/0644 so the unprivileged
    # scripts/ids.sh can read eve.json.
    install -d -m 755 "$data/ids"
    if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$data/ids" || warn "could not hand $data/ids back to uid $SUDO_UID"
    fi
    install -d -m 755 "$data/ids/suricata" "$data/ids/suricata/lib"

    # Retention for Suricata's rotated EVE files, which no unprivileged process
    # may delete. tmpfiles.d owns that, on the same schedule as the rest of the
    # host's cleanup.
    root_render /dev/stdin /etc/tmpfiles.d/stack-ids.conf 644 "$data" <<'EOF'
# Written by deploy/install.sh --root; do not edit (deploy/root/ owns it).
# Suricata rotates eve.json daily (rotate-interval) and never prunes; the files
# are root-owned, so this is the only thing that can delete them.
d @DATA_DIR@/ids/suricata 0755 root root -
e @DATA_DIR@/ids/suricata/*.json.* - - - @IDS_RETENTION_DAYS@d
EOF

    # The unit itself. Render, then let systemd regenerate suricata.service from
    # it -- the same render-then-daemon-reload cycle as the user side, just in
    # the system manager. Mode 0644, unlike the 0600 user units: a system unit in
    # /etc carries no secret (the secret-bearing templates are the *user* units
    # with @PLACEHOLDERS@), and this one has to be readable by the unprivileged
    # ./verify.sh, which diffs it against the repo to catch drift.
    root_render "$DEPLOY_DIR/root/suricata.container" "$ROOT_UNIT_DIR/suricata.container" 644 "$data"

    # A silent substitution failure is worse than a loud one: an empty @DATA_DIR@
    # renders a unit that mounts /ids/suricata, which podman rejects only after
    # systemd has already tried to start it (this happened once -- the helper that
    # escapes sed replacements was defined below its first use, and a failed
    # $(...) in an argument does not trip set -e). Nothing reaches the system
    # manager under test.
    grep -qF "$data/ids/suricata" "$ROOT_UNIT_DIR/suricata.container" \
        || die "rendered $ROOT_UNIT_DIR/suricata.container does not reference $data/ids/suricata -- the substitution failed"
    grep -qF "$data/ids/suricata" /etc/tmpfiles.d/stack-ids.conf \
        || die "rendered /etc/tmpfiles.d/stack-ids.conf does not reference $data/ids/suricata -- the substitution failed"

    # ------------------------------------------------------------------
    # auditd: watch the host-level surfaces nothing in this repo writes
    # ------------------------------------------------------------------
    # The daemon was already running with an empty rules.d. The rules are
    # rendered (they carry @DATA_DIR@ for the data-dir watches) and loaded with
    # augenrules; the report unit turns the root-only log into a status file the
    # unprivileged monitor can read.
    install -d -m 750 /etc/audit/rules.d
    root_render "$DEPLOY_DIR/root/audit.rules" /etc/audit/rules.d/60-stack.rules 640 "$data"
    aenv=$(mktemp)
    printf '# Written by deploy/install.sh --root; do not edit (deploy/root/ owns it).\nDATA_DIR=%s\n' "$data" > "$aenv"
    install -m 600 "$aenv" "$ROOT_CONFIG_DIR/audit.env"
    rm -f "$aenv"
    root_render "$DEPLOY_DIR/root/audit-report.sh" "$ROOT_CONFIG_DIR/audit-report.sh" 755 "$data"
    root_render "$DEPLOY_DIR/root/stack-audit.service" /etc/systemd/system/stack-audit.service 644 "$data"
    root_render "$DEPLOY_DIR/root/stack-audit.timer" /etc/systemd/system/stack-audit.timer 644 "$data"
    # augenrules ADDS rules; it never removes the ones a previous render left
    # behind (that is how a watch I deleted kept firing). Remove only OUR rules,
    # one at a time -- NOT `auditctl -D`: on this host (kernel 6.12 / audit 4.0.3)
    # a global delete left the kernel accepting rules but emitting no events at
    # all, not even the CONFIG_CHANGE for the next one, until a reboot. Deleting
    # by rule text has no such effect and leaves an operator's own rules alone.
    if [ -x /usr/sbin/auditctl ]; then
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            # shellcheck disable=SC2086  # the rule text IS the argument list
            /usr/sbin/auditctl -W $rule >/dev/null 2>&1 || true
        done <<< "$(/usr/sbin/auditctl -l 2>/dev/null | grep -- '-k stack_' || true)"
    fi
    # augenrules exits non-zero on "Rule exists" even when the ruleset is already
    # what we want (it replays the whole file), so the verdict is the kernel's
    # rule list, not the exit code.
    /usr/sbin/augenrules --load >/dev/null 2>&1 || true
    n_rules=$(/usr/sbin/auditctl -l 2>/dev/null | grep -c -- '-k stack_' || true)
    if [ ! -x /usr/sbin/augenrules ]; then
        warn "auditctl/augenrules are missing (EL10 ships them in the audit-rules package); run: sudo dnf install -y audit-rules && sudo ./bootstrap.sh"
    elif [ "${n_rules:-0}" -gt 0 ]; then
        log "audit rules loaded (${n_rules} watch(es))"
    else
        warn "no stack audit rules are loaded; run: sudo /usr/sbin/augenrules --load"
    fi

    # ------------------------------------------------------------------
    # stack-bouncer: CrowdSec's decisions -> nftables
    # ------------------------------------------------------------------
    # Its key is generated by the *user-side* install (it has to be in
    # secrets.env, where the crowdsec template reads it), so a root phase that
    # runs before the first ./deploy.sh has nothing to install yet -- the second
    # bootstrap pass picks it up. Same two-pass reason as the sensor itself.
    local bkey
    bkey=$(env_value "$data/config/stack/secrets.env" CROWDSEC_BOUNCER_KEY)
    if [ -z "$bkey" ]; then
        warn "no CROWDSEC_BOUNCER_KEY in $data/config/stack/secrets.env yet; skipping the bouncer (re-run sudo ./bootstrap.sh after ./deploy.sh)"
    else
        root_render "$DEPLOY_DIR/root/bouncer.sh" "$ROOT_CONFIG_DIR/bouncer.sh" 755 "$data"
        # Root-owned 0600, deliberately not $DATA_DIR/config: this key reads every
        # decision, and root must not take instructions from a file the stack user
        # can write.
        benv=$(mktemp)
        {
            printf '# Written by deploy/install.sh --root; do not edit (deploy/root/ owns it).\n'
            printf 'CROWDSEC_BOUNCER_KEY=%s\n' "$bkey"
            printf 'LAPI=127.0.0.1:8080\n'
            printf 'DATA_DIR=%s\n' "$data"
        } > "$benv"
        install -m 600 "$benv" "$ROOT_CONFIG_DIR/bouncer.env"
        rm -f "$benv"
        root_render "$DEPLOY_DIR/root/stack-bouncer.service" /etc/systemd/system/stack-bouncer.service 644 "$data"
        root_render "$DEPLOY_DIR/root/stack-bouncer.timer" /etc/systemd/system/stack-bouncer.timer 644 "$data"
        bouncer_installed=1
    fi

    systemctl daemon-reload
    systemd-tmpfiles --create /etc/tmpfiles.d/stack-ids.conf 2>/dev/null \
        || warn "could not apply /etc/tmpfiles.d/stack-ids.conf"
    # Quadlet turns the rendered .container into suricata.service, and the
    # generator's [Install] WantedBy=multi-user.target is what pulls it in at
    # boot -- exactly like the rootless units, which are never `systemctl --user
    # enable`d either. `systemctl enable` is REFUSED for a generated unit
    # ("transient or generated"), so starting is all there is to do here. A
    # failure is a warning, not a failed bootstrap: the rest of the stack is
    # unaffected by a sensor that cannot open its interface (a renamed NIC is the
    # usual cause).
    if systemctl start suricata 2>/dev/null; then
        log "suricata started"
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
    log "root tier installed; run ./verify.sh to check the sensor"
}

ROOT_TIER=0
ROOT_DATA_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT_TIER=1 ;;
        --data-dir) ROOT_DATA_DIR="${2:?--data-dir needs a path}"; shift ;;
        -h|--help)  usage_header "$0"
                    printf '  --root            install the rootful IDS tier (bootstrap.sh only)\n'
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

# Every unit is rendered: all of them reference either the data dir or the
# config dir, so none is a plain symlink any more. Pairs are "source:target".
UNITS=(
    "npm-network.network:npm-network.network"
    "netcheck.container:netcheck.container"
    "netcheck-host.container:netcheck-host.container"
    "nginx-proxy-manager.container:nginx-proxy-manager.container"
    "valkey.container:valkey.container"
    "searxng.container:searxng.container"
    "bitcoind.container:bitcoind.container"
    "monerod.container:monerod.container"
    "fulcrum.container.in:fulcrum.container"
    "btc-explorer.container:btc-explorer.container"
    "xmr-explorer.container:xmr-explorer.container"
    "tor.container:tor.container"
    "lightningd.container.in:lightningd.container"
    "nbxplorer.container:nbxplorer.container"
    "btcpay.container:btcpay.container"
    "monero-wallet-btcpay.container:monero-wallet-btcpay.container"
    "btcpay-bootstrap.container:btcpay-bootstrap.container"
    "searxng-mcp.container:searxng-mcp.container"
    "bitcoin-node-mcp.container:bitcoin-node-mcp.container"
    "monero-node-mcp.container:monero-node-mcp.container"
    "monero-wallet-mcp.container:monero-wallet-mcp.container"
    "lightning-mcp.container:lightning-mcp.container"
    "fulcrum-mcp.container:fulcrum-mcp.container"
    "postgres.container:postgres.container"
    "uptime-kuma.container:uptime-kuma.container"
    "boltmesh-backend.container:boltmesh-backend.container"
    "boltmesh-worker.container:boltmesh-worker.container"
    "boltmesh-frontend.container:boltmesh-frontend.container"
    "postgres-dump.container:postgres-dump.container"
    "backup.container:backup.container"
    "victoriametrics.container:victoriametrics.container"
    "alertmanager.container:alertmanager.container"
    "node-exporter.container:node-exporter.container"
    "victoria-logs.container:victoria-logs.container"
    "vector.container:vector.container"
    "crowdsec.container.in:crowdsec.container"
)

# Plain systemd user units (installed to USER_UNIT_DIR, not the quadlet dir).
USER_UNITS=(
    "backup.timer"
    "backup-verify.service"
    "backup-verify.timer"
    "monitor.service"
    "monitor.timer"
    "metrics.service"
    "metrics.timer"
    "ids.service"
    "ids.timer"
)
# The subset that is enabled --now. monitor.service and metrics.service have no
# [Install] -- only their timers activate them -- so they must not be enabled on
# their own.
USER_TIMERS=(
    "backup.timer"
    "backup-verify.timer"
    "monitor.timer"
    "metrics.timer"
    "ids.timer"
)

# Method allowlists for the CLN runes (`method^<prefix>` is a prefix match).
# The prefixes themselves are declared in stack.conf (CLN_READ_METHODS,
# CLN_SPEND_METHODS) because scripts/rotate.sh mints the
# same runes on a rotation; rune_json (scripts/lib.sh) turns each array into the
# restriction JSON. SPEND is the read set plus the payment methods.
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

# Like new_or_reused_token, but for a value nobody has to present (a JWT
# signing key, the bootstrap pepper): reuse whatever the running container
# already carries so adopting a host keeps existing sessions and node tokens
# valid, otherwise generate. Prints the value on stdout, never the reverse.
new_or_reused_secret() {
    local container="$1" var="$2" val=""
    if command -v podman >/dev/null 2>&1; then
        val=$(podman exec "$container" printenv "$var" 2>/dev/null || true)
    fi
    if [ -n "$val" ]; then
        printf '==> reused %s from the running %s\n' "$var" "$container" >&2
    else
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

# The backup set (BACKUP_PATHS in stack.conf) rendered the two ways
# deploy/backup.container needs it: one read-only Volume= per entry, and the
# space-separated path list restic backs up in its Exec=. scripts/backup.sh
# derives its mounts and arguments from the same array, so the declaration is
# the only place a directory is added or removed.
#
# `:z` (shared), not `:Z`: lightningd, nginx-proxy-manager and tor mount some of
# these same directories, and two containers cannot share a path one labels
# private. No escaping here: these go into the unit verbatim, not through sed.
backup_mounts() {
    local p
    for p in "${BACKUP_PATHS[@]}"; do
        # audit/ is also written by the rootful IDS. podman's :z relabel fails on
        # its root-owned auditd.fim (initrc_tmp_t), which aborted the whole
        # backup; the directory itself already carries container_file_t, so mount
        # it read-only without asking for another relabel. restic warns about the
        # one unreadable root-owned file, exactly as it did before.
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
    for d in searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp fulcrum-mcp; do
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
# never rewrites it, so append this one key when it is missing (same pattern as
# the bouncer key below).
if [ -z "$(read_secret BTCPAY_DB_PASSWORD)" ]; then
    printf 'BTCPAY_DB_PASSWORD=%s\n' "$BTCPAY_DB_PASSWORD" >> "$SECRETS_FILE"
    log "added BTCPAY_DB_PASSWORD to $SECRETS_FILE"
fi

# The bouncer's key is the one secret NOT in that heredoc: it has to exist on a
# host deployed before the bouncer did, and ensure_secret would never touch an
# existing file. So it is read and only *appended* when missing -- which also
# covers a fresh host, whose file the block above just wrote.
#
# NEVER regenerate it. deploy/crowdsec.container.in renders it into
# BOUNCER_KEY_firewall, and the image's entrypoint registers that exact key in
# its LAPI on start; a new value would leave the old bouncer registered and
# enforcement silently dead (the LAPI answers 403 and stack-bouncer reports "LAPI
# unreachable" -- the status file exists for exactly this).
CROWDSEC_BOUNCER_KEY=$(read_secret CROWDSEC_BOUNCER_KEY)
if [ -z "$CROWDSEC_BOUNCER_KEY" ]; then
    CROWDSEC_BOUNCER_KEY=$(rand_hex)
    printf 'CROWDSEC_BOUNCER_KEY=%s\n' "$CROWDSEC_BOUNCER_KEY" >> "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    log "generated CROWDSEC_BOUNCER_KEY and appended it to $SECRETS_FILE"
fi
export CROWDSEC_BOUNCER_KEY

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
# 450 once the chain is synced and the cache buys nothing (README: "Speeding up
# the initial sync").
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

# Download and extract the pinned Monero plugin when the pinned artifact is not
# the one on disk. A failure is a warning, not a fatal error: BTC-LN still works
# and the bootstrap re-runs the XMR method on the next deploy. Renovate cannot
# track plugin-builder URLs, so the version and hash in stack.conf are edited
# together -- and the marker is what makes that edit land, since the DLL's own
# name does not change between versions.
stage_btcpay_plugin() {
    local dir="$DATA_DIR/btcpay/Plugins/$BTCPAY_PLUGIN_ID"
    local marker="$dir/.artifact-sha256" tmp stage
    local installed=""
    [ -f "$marker" ] && installed=$(cat "$marker" 2>/dev/null)
    if [ -f "$dir/$BTCPAY_PLUGIN_ID.dll" ] && [ "$installed" = "$BTCPAY_PLUGIN_SHA256" ]; then
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        warn "curl is missing; cannot download the BTCPay Monero plugin"
        return 0
    fi
    tmp=$(mktemp)
    if ! curl -fsSL --max-time 120 "$BTCPAY_PLUGIN_URL" -o "$tmp"; then
        warn "could not download the BTCPay Monero plugin; the installed one stays, XMR will stay disabled if there is none"
        rm -f "$tmp"
        return 0
    fi
    if [ "$(sha256sum "$tmp" | awk '{print $1}')" != "$BTCPAY_PLUGIN_SHA256" ]; then
        warn "BTCPay Monero plugin hash mismatch; refusing to install it"
        rm -f "$tmp"
        return 0
    fi
    # Extract into a sibling directory and swap it in whole: extracting over the
    # previous version would leave its extra files behind, and a failed extract
    # must not destroy a plugin that works.
    stage=$(mktemp -d "$DATA_DIR/btcpay/Plugins/.stage.XXXXXX") || {
        warn "could not create a staging directory for the BTCPay Monero plugin"
        rm -f "$tmp"
        return 0
    }
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$tmp" -d "$stage" || { warn "could not extract the BTCPay Monero plugin"; rm -rf "$stage" "$tmp"; return 0; }
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp" "$stage" \
            || { warn "could not extract the BTCPay Monero plugin"; rm -rf "$stage" "$tmp"; return 0; }
    else
        warn "neither unzip nor python3 is available to extract the BTCPay Monero plugin"
        rm -rf "$stage"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    if [ ! -s "$stage/$BTCPAY_PLUGIN_ID.dll" ]; then
        warn "the BTCPay Monero plugin artifact has no $BTCPAY_PLUGIN_ID.dll; keeping the installed one"
        rm -rf "$stage"
        return 0
    fi
    # The container keeps its already-loaded assemblies mapped, so replacing the
    # directory under a running BTCPay is safe; deploy.sh restarts it when the
    # DLL is newer than the container (btcpay_plugin_newer).
    rm -rf "$dir"
    chmod 755 "$stage"
    mv "$stage" "$dir" || { warn "could not move the BTCPay Monero plugin into $dir"; rm -rf "$stage"; return 0; }
    printf '%s\n' "$BTCPAY_PLUGIN_SHA256" > "$marker"
    log "installed the BTCPay Monero plugin into $dir"
}

# BTCPay's datadir (data-protection keys), its plugin dir, the view-only Monero
# wallet and NBXplorer's cookie. All are written by container root == the host
# user under rootless podman, so a plain mkdir is enough.
mkdir -p "$DATA_DIR/btcpay/Plugins" "$DATA_DIR/btcpay/xmr-wallet" "$DATA_DIR/nbxplorer"
stage_btcpay_plugin

mkdir -p "$DATA_DIR/monero" "$DATA_DIR/cln" "$TOR_DIR"

# Fulcrum's index, self-signed cert and admin latch. The Fulcrum image runs as
# container root (the host user under rootless podman, like cln/ and tor/), so
# this stays user-owned; only the directory has to exist for the :z mount.
mkdir -p "$DATA_DIR/fulcrum"

# The onion services' keys (ONION_SERVICES in stack.conf): mounted into tor at
# /var/lib/tor/onion. Mode 700 here, because tor only checks the leaf
# HiddenServiceDir it creates -- a world-listable parent leaks the service names
# (not the keys). Written by tor as container root = the host user under rootless
# podman, like cln/ and tor/torrc, so a plain mkdir and no uid chown.
mkdir -p "$TOR_DIR/onion"
chmod 700 "$TOR_DIR/onion"

# BoltMesh's data: the postgres cluster (fresh on a new host) and the directory
# the pre-backup pg_dumpall writes into. The dump container runs as the image's
# root (the host user under rootless podman) and the postgres image chowns its
# own PGDATA, so neither dir needs the image-uid chown the other apps need.
mkdir -p "$DATA_DIR/postgres" "$DATA_DIR/postgres-dump"

# Uptime-Kuma's state (sqlite, history, monitor config): written by container
# root -- the host user under rootless podman, same as cln/ and tor/ -- so a
# plain mkdir, no uid chown. Nothing is seeded into the state itself: the admin
# account is created in its web UI on first use, and the monitors are
# reconciled by scripts/kuma-monitors.sh once the api.env has the login.
mkdir -p "$DATA_DIR/uptime-kuma"

# Monitoring: the metrics store, and the textfile node-exporter serves.
# victoriametrics and node-exporter both run as container root == the login user
# under rootless podman, so a plain mkdir is enough. The textfile dir is 0755
# because the exporter runs as uid 65534 (a subuid) and has to read what
# scripts/metrics.sh writes; the writers chmod the files 0644 for the same
# reason. $DATA_DIR/monitoring is regenerable and stays out of the backup set.
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

# Alertmanager: the alert state machine scripts/monitor.sh pushes into.
#
# The state dir (silences, notification log) is regenerable -- losing a silence
# un-mutes an alert for one repeat interval -- so it lives with the rest of
# $DATA_DIR/monitoring, outside BACKUP_PATHS. The unit runs as container root ==
# the login user under rootless podman, so a plain mkdir is enough.
mkdir -p "$DATA_DIR/monitoring/alertmanager" "$CONFIG_DIR/monitoring/alertmanager"

# The config is seeded ONCE and then belongs to the operator: it carries the
# SMTP password, so rewriting it on every deploy would both clobber an edited
# route tree and re-arm a placeholder credential. Written in place (`cat >`),
# not installed/moved, because Alertmanager watches the path: a replaced inode
# behind the directory mount would still be seen, but a move would break the
# open file the reloader is stat-ing. The unit mounts the directory for the
# same reason (deploy/alertmanager.container explains it).
ALERT_CFG="$CONFIG_DIR/monitoring/alertmanager/alertmanager.yml"
if ensure_secret "$ALERT_CFG" "alertmanager config"; then
    write_secret "$ALERT_CFG" < "$DEPLOY_DIR/examples/monitoring/alertmanager.yml.example"
    log "wrote $ALERT_CFG (mode 600) -- fill in SMTP before alerts are actually mailed"
fi

# Logs: the store, the shipper's checkpoint, and the shipper's config.
#
# victoria-logs and vector both run as container root == the login user under
# rootless podman (like victoriametrics), so a plain mkdir is enough -- no
# podman-unshare chown, unlike bitcoind.
#
# The config is rendered on every run from deploy/logs/vector.toml, in place and
# through the directory mount, for the same two reasons as scrape.yml above: a
# single-file bind mount keeps the inode it opened, and a replaced inode is
# invisible to the process watching the directory. The file itself is
# secret-free (no @PLACEHOLDERS@), so it renders like the other plain configs.
mkdir -p "$DATA_DIR/logs/vl" "$DATA_DIR/logs/vector" "$CONFIG_DIR/logs/vector"
( umask 077; cat "$DEPLOY_DIR/logs/vector.toml" > "$CONFIG_DIR/logs/vector/vector.toml" )
log "wrote $CONFIG_DIR/logs/vector/vector.toml"

# The backup job's restic cache (regenerable) and its repository. The repo is
# outside $DATA_DIR on purpose, so wiping the data dir does not delete it.
mkdir -p "$DATA_DIR/backup-cache" "$STACK_BACKUP_DIR"

# ---------------------------------------------------------------------------
# 3. the images built here: netcheck, kuma-ctl, tor
# ---------------------------------------------------------------------------
# None of these is pulled, so "is it built?" is the wrong question: a base-image
# bump rewrites only that image's Containerfile (Renovate's dockerfile manager),
# so leaving an existing image alone forever is how such a bump never reaches
# the host. The Containerfile's hash is baked in as a label and compared here
# (scripts/lib.sh), so a stale image is rebuilt and a current one is left alone.
ensure_local_image() { # image build-context
    local image="$1" dir="$2"
    [ -f "$dir/Containerfile" ] || return 0
    if image_is_current "$image" "$dir/Containerfile"; then
        log "$image is current"
        return 0
    fi
    if podman image exists "$image" 2>/dev/null; then
        # A stale image is worth rebuilding, but failing the whole install over
        # it would take the host down for a helper image: keep the bits that
        # work and let verify.sh report the drift (a broken Containerfile -- an
        # apk pin that moved, say -- is a fixable authoring bug, not an outage).
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

# netcheck: the curl client the host-side checks exec into. scripts/lib.sh's
# net_curl runs it in a long-lived container to read a service by name on
# npm-network, and net_curl_host the same image in a second one on the host
# network for nginx-proxy-manager, which binds 127.0.0.1:81 there.
if command -v podman >/dev/null 2>&1; then
    ensure_local_image "$NETCHECK_IMAGE" "$REPO_DIR/netcheck"
fi

# kuma-ctl: the socket.io client scripts/kuma-monitors.sh runs (kuma has no REST
# write API). The reconcile script is bind-mounted on every run, so a change to
# kuma-ctl/monitors.mjs does not need a rebuild -- only the pinned
# node/socket.io-client base does.
if command -v podman >/dev/null 2>&1; then
    ensure_local_image "$KUMA_CTL_IMAGE" "$REPO_DIR/kuma-ctl"
fi

# ---------------------------------------------------------------------------
# 4. tor image + torrc (+ the onion services)
# ---------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    ensure_local_image "$TOR_IMAGE" "$REPO_DIR/tor"
fi

# The onion services, rendered from ONION_SERVICES in stack.conf. Tor's own
# config is a hand-tuned file (the control-password hash is derived once and the
# SocksPolicy is deliberate), so it is seeded once and never rewritten as a
# whole. The hidden-service part is the exception: it is a *declaration*, so it
# lives in a marked region that this installer rewrites on every run. Changing
# ONION_SERVICES is therefore enough -- deploy.sh digests torrc alongside the
# units and restarts tor when it changed.
ONION_BEGIN="# >>> onion services (rendered by deploy/install.sh from ONION_SERVICES)"
ONION_END="# <<< onion services"

onion_stanzas() {
    local entry name target _rest
    [ "${ONION_SERVICES+x}" = x ] || return 0
    for entry in "${ONION_SERVICES[@]}"; do
        IFS='|' read -r name target _rest <<<"$entry"
        # HiddenServicePort applies to the HiddenServiceDir above it, and the
        # directory must exist or be creatable: the mount is there, tor makes the
        # per-service dir 700 itself.
        printf 'HiddenServiceDir /var/lib/tor/onion/%s\n' "$name"
        printf 'HiddenServicePort 80 %s\n' "$target"
    done
}

# Replace the marked region in torrc with the current declaration, appending it
# when absent (an adopted host predates it). Everything outside the markers --
# the hash, the SOCKS policy, the log line -- is left byte for byte.
sync_torrc_onions() { # torrc
    local torrc="$1" tmp stanzas entry name target
    [ -s "$torrc" ] || return 0
    # Validated here, in the main shell: a die inside $(onion_stanzas) would only
    # end the subshell and quietly install no services at all.
    if [ "${ONION_SERVICES+x}" = x ]; then
        for entry in "${ONION_SERVICES[@]}"; do
            IFS='|' read -r name target _ <<<"$entry"
            [ -n "$name" ] && [ -n "$target" ] \
                || die "bad ONION_SERVICES entry: $entry (want \"name|target|mirrors|path|code\")"
        done
    fi
    stanzas=$(onion_stanzas)
    tmp=$(mktemp "$torrc.XXXXXX")
    awk -v b="$ONION_BEGIN" -v e="$ONION_END" '
        $0 == b { inblock = 1; next }
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
        "$DEPLOY_DIR/searxng/settings.yml" > "$SEARXNG_DATA_DIR/settings.yml"
fi
if [ -s "$SEARXNG_DATA_DIR/limiter.toml" ]; then
    log "keeping existing $SEARXNG_DATA_DIR/limiter.toml"
else
    log "seeding $SEARXNG_DATA_DIR/limiter.toml"
    cp "$DEPLOY_DIR/searxng/limiter.toml" "$SEARXNG_DATA_DIR/limiter.toml"
fi

# ---------------------------------------------------------------------------
# 6. per-application env files (under the data dir)
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

FULCRUM_ENV="$CONFIG_DIR/fulcrum-mcp"
if ensure_secret "$FULCRUM_ENV/token.env" "fulcrum-mcp token env"; then
    token=$(new_or_reused_token fulcrum-mcp FULCRUM_MCP_TOKEN)
    write_secret "$FULCRUM_ENV/token.env" <<EOF
FULCRUM_MCP_TOKEN=$token
EOF
    log "wrote $FULCRUM_ENV/token.env (mode 600)"
fi
if ensure_secret "$FULCRUM_ENV/upstream.env" "fulcrum-mcp upstream env"; then
    write_secret "$FULCRUM_ENV/upstream.env" <<EOF
# The Electrum endpoint this server reads. Fulcrum is reachable only on
# npm-network, and the Electrum protocol has no authentication of its own.
FULCRUM_URL=tcp://fulcrum:50001
EOF
    log "wrote $FULCRUM_ENV/upstream.env (mode 600)"
fi

# BTC RPC Explorer's configuration. The app is configured entirely through the
# environment (so the unit uses EnvironmentFile=, not a rendered Exec=), and it
# needs the same bitcoind RPC credentials plus Fulcrum's Electrum endpoint. It
# keeps no data of its own. Address history comes from Fulcrum; any txid
# resolves through bitcoind's txindex (README: "Block explorers").
BTCEXP_ENV="$CONFIG_DIR/btc-explorer"
if ensure_secret "$BTCEXP_ENV/btc-explorer.env" "btc explorer env"; then
    write_secret "$BTCEXP_ENV/btc-explorer.env" <<EOF
# BTC RPC Explorer (deploy/btc-explorer.container). Read via EnvironmentFile=.
# The RPC password is a secret; the rest is wiring. Empty
# BTCEXP_BASIC_AUTH_PASSWORD means the explorer is public (as served by NPM).
BTCEXP_HOST=0.0.0.0
BTCEXP_PORT=3002
BTCEXP_BITCOIND_HOST=bitcoind
BTCEXP_BITCOIND_PORT=8332
BTCEXP_BITCOIND_USER=$BITCOIN_RPC_USER
BTCEXP_BITCOIND_PASS=$BITCOIN_RPC_PASSWORD
# Address history and balances come from the stack's own Fulcrum; no second
# index and no external API. BTCEXP_ELECTRUM_TXINDEX is electrs-only, so it is
# deliberately absent (Fulcrum is not electrs).
BTCEXP_ADDRESS_API=electrum
BTCEXP_ELECTRUM_SERVERS=tcp://fulcrum:50001
# Served behind nginx-proxy-manager, which terminates TLS. Privacy mode keeps
# the explorer from calling out for exchange rates or IP geolocation.
BTCEXP_SECURE_SITE=true
BTCEXP_PRIVACY_MODE=true
BTCEXP_NO_RATES=true
BTCEXP_SLOW_DEVICE_MODE=true
BTCEXP_RPC_ALLOWALL=false
# Optional HTTP basic auth (any username, this password). Empty = public.
BTCEXP_BASIC_AUTH_PASSWORD=
EOF
    log "wrote $BTCEXP_ENV/btc-explorer.env (mode 600)"
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
# Derived every run (machine-owned): the MCP now reads BTCPay's view-only
# plugin wallet. The wallet RPC has no login by design (the plugin hardcodes
# empty credentials) and holds no spend key, so the MCP's spend tools cannot
# move funds.
write_secret "$XMRW_ENV/upstream.env" <<EOF
MONERO_WALLET_RPC_URL=http://monero-wallet-btcpay:18083/json_rpc
MONERO_WALLET_RPC_USER=
MONERO_WALLET_RPC_PASSWORD=
EOF
log "wrote $XMRW_ENV/upstream.env (mode 600)"
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

# ---------------------------------------------------------------------------
# BoltMesh env files (under the data dir, like every other app's)
# ---------------------------------------------------------------------------
# The app reads one flat environment, so the split here is by who owns each
# value: install.sh generates the database and the signing keys, the operator
# fills in the third-party credentials, and btcpay/backend.env is written by
# deploy.sh after the bootstrap has provisioned the store.
BOLT_DB="$CONFIG_DIR/boltmesh"

if ensure_secret "$BOLT_DB/db.env" "boltmesh db env"; then
    pg_password=$(rand_hex)
    write_secret "$BOLT_DB/db.env" <<EOF
# The BoltMesh database. Read by the postgres unit (POSTGRES_*) and by the
# backend/worker (DATABASE_URL, same password). The server ignores DATABASE_URL.
POSTGRES_DB=vpndb
POSTGRES_USER=vpnuser
POSTGRES_PASSWORD=$pg_password
DATABASE_URL=postgresql+asyncpg://vpnuser:$pg_password@postgres:5432/vpndb
EOF
    log "wrote $BOLT_DB/db.env (mode 600)"
fi

# The pre-backup dump's connection settings, read back from db.env so a second
# run keeps the same password.
pg_password=$(env_value "$BOLT_DB/db.env" POSTGRES_PASSWORD)
if ensure_secret "$BOLT_DB/dump.env" "boltmesh dump env"; then
    write_secret "$BOLT_DB/dump.env" <<EOF
# libpq settings for deploy/postgres-dump.container (the pre-backup pg_dumpall).
# Deliberately NOT in db.env: PGHOST/PGUSER in the postgres server's own
# environment would break its socket-based entrypoint bootstrap.
PGHOST=postgres
PGUSER=vpnuser
PGPASSWORD=$pg_password
EOF
    log "wrote $BOLT_DB/dump.env (mode 600)"
fi

if ensure_secret "$BOLT_DB/secrets.env" "boltmesh secrets env"; then
    write_secret "$BOLT_DB/secrets.env" <<EOF
# JWT signing keys and the node-bootstrap pepper (each min 32 chars, distinct).
# Generated once; regenerating them invalidates every session and node token.
SECRET_KEY=$(new_or_reused_secret boltmesh-backend SECRET_KEY)
REFRESH_SECRET_KEY=$(new_or_reused_secret boltmesh-backend REFRESH_SECRET_KEY)
NODE_SECRET_KEY=$(new_or_reused_secret boltmesh-backend NODE_SECRET_KEY)
BOOTSTRAP_SECRET_PEPPER=$(new_or_reused_secret boltmesh-backend BOOTSTRAP_SECRET_PEPPER)
EOF
    log "wrote $BOLT_DB/secrets.env (mode 600)"
fi

if ensure_secret "$BOLT_DB/app.env" "boltmesh app env"; then
    write_secret "$BOLT_DB/app.env" <<EOF
# BoltMesh API + worker configuration. Operator-editable: the app reads one flat
# environment, so the credentials YOU supply (OAuth, SMTP, the agent deploy
# token) live here beside the URLs. The stack-owned values (database, JWT keys,
# payment gateways) are in db.env/secrets.env/btcpay/backend.env -- do not duplicate
# them here.
#
# APP_ENV=prod: the app derives Secure + SameSite=None cookies from it (the SPA
# and the API are on different hosts) and stops loading any .env file.
APP_ENV=prod
APP_DEBUG=0
CACHE_URL=redis://valkey:6379/0

# Public URLs. API_BASE_URL is also the base of every OAuth redirect_uri, so it
# must match the provider consoles and the nginx-proxy-manager proxy host.
API_BASE_URL=https://$BOLTMESH_API_HOST
FRONTEND_URL=https://$BOLTMESH_FRONTEND_HOST
CORS_ALLOW_ORIGINS=https://$BOLTMESH_FRONTEND_HOST
COMPANY_NAME=$BOLTMESH_COMPANY_NAME
TRUST_PROXY_HEADERS=1

# OAuth: register https://<api host>/v1/auth/google/callback and
# https://<api host>/v1/auth/github/callback in each provider's console.
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=

# SMTP for activation and password-reset mail.
MAIL_SERVER=
MAIL_PORT=587
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_FROM=$BOLTMESH_SUPPORT_EMAIL
MAIL_STARTTLS=true
MAIL_SSL_TLS=false
SUPPRESS_EMAIL=false
TEMPLATES_DIR=templates

# Node provisioning: the agent repo and a token that can read it.
GITHUB_REPO=$BOLTMESH_AGENT_REPO
GITHUB_TOKEN=
AWS_IID_ACCOUNT_ID=
AWS_IID_SIGNER_FINGERPRINTS=
MANUAL_BOOTSTRAP_SECRET_TTL_DAYS=30
SERVER_STALE_SECONDS=120
EOF
    log "wrote $BOLT_DB/app.env (mode 600) -- fill in OAuth/SMTP/GitHub before use"
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

# Monitoring: the alert targets, the dead-man's-switch heartbeat and the
# thresholds for deploy/monitor.service (scripts/monitor.sh). Empty values mean
# journal-only / the built-in default, so a fresh host is safe before this file
# is filled in.
#
# The example IS the seeded file, copied verbatim like the alertmanager config
# above -- the two used to be maintained by hand and drifted (the seeded copy
# was missing keys the example documented, and scripts/monitor.sh read five keys
# no file mentioned), so the file a fresh host gets is now always the one that
# documents every key. install.sh still never overwrites an existing one.
MON_ENV="$CONFIG_DIR/monitoring/monitor.env"
if ensure_secret "$MON_ENV" "monitoring env"; then
    write_secret "$MON_ENV" < "$DEPLOY_DIR/examples/monitoring/monitor.env.example"
    log "wrote $MON_ENV (mode 600) -- fill in the heartbeat (and SMTP in the alertmanager config) to be paged"
fi

# nginx-proxy-manager's admin API, for scripts/npm-hosts.sh: it reconciles every
# proxy host the stack serves (NPM_HOSTS in stack.conf). The admin login
# (or a pre-created API token) is a secret, so the file is mode 600; empty means
# the script logs a one-line skip rather than failing a deploy.
NPM_ENV="$CONFIG_DIR/npm/api.env"
if ensure_secret "$NPM_ENV" "nginx-proxy-manager api env"; then
    write_secret "$NPM_ENV" <<'EOF'
# Credentials for the nginx-proxy-manager admin API (port 81), used by
# scripts/npm-hosts.sh to reconcile every proxy host the stack serves (declared
# in NPM_HOSTS in stack.conf). See deploy/examples/npm/api.env.example.
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

# Uptime-Kuma's admin login, for scripts/kuma-monitors.sh: it reconciles the
# status page's monitors (declared in KUMA_MONITORS in stack.conf) and creates
# + publishes the public status page. Same UI-first flow as npm/api.env: the
# account is created on the setup wizard's first visit, the login is recorded
# here, and the reconciler self-skips until it is filled in.
KUMA_ENV="$CONFIG_DIR/uptime-kuma/api.env"
if ensure_secret "$KUMA_ENV" "uptime-kuma api env"; then
    write_secret "$KUMA_ENV" <<'EOF'
# Credentials for the Uptime-Kuma admin account, used by
# scripts/kuma-monitors.sh to reconcile the status page's monitors (declared
# in KUMA_MONITORS in stack.conf) and create + publish the status page. See
# deploy/examples/kuma/api.env.example. Never committed.
#
# The username and password the setup wizard asked for on the first visit to
# https://$UPTIME_KUMA_HOST (status.boltmesh.net) — kuma's login is
# username-based, not email-based. Leave empty and the reconciler self-skips;
# the monitors are still configurable in the UI.
KUMA_USERNAME=
KUMA_PASSWORD=
EOF
    log "wrote $KUMA_ENV (mode 600) -- fill in KUMA_USERNAME/KUMA_PASSWORD (or leave empty: the reconciler skips)"
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
        new_read=$(create_rune "$READ_RESTRICTIONS")
        new_spend=$(create_rune "$SPEND_RESTRICTIONS")
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

# BoltMesh's payment wiring is BTCPay now. The store URL/key/id/webhook secret
# are written after the bootstrap has provisioned them (see the
# btcpay/backend.env contract in the backend unit); nothing here talks to CLN or
# a wallet-rpc directly.

# ---------------------------------------------------------------------------
# BTCPay config. The bootstrap owns the store/keys/webhook and writes them back
# into bootstrap.env; backend.env is the four-value contract the backend reads
# and is written after a successful bootstrap (deploy.sh), not here.
# ---------------------------------------------------------------------------
BTC_CONFIG="$CONFIG_DIR/btcpay"
mkdir -p "$BTC_CONFIG"
if ensure_secret "$BTC_CONFIG/bootstrap.env" "btcpay bootstrap env"; then
    write_secret "$BTC_CONFIG/bootstrap.env" <<EOF
# Input for scripts/btcpay_bootstrap.py and, after the first run, the state
# file it writes back (admin key, runtime key, store id, webhook secret).
BTCPAY_URL=http://btcpay:49392
BTCPAY_ADMIN_EMAIL=admin@boltmesh.local
BTCPAY_ADMIN_PASSWORD=$(rand_hex)
BTCPAY_STORE_NAME=BoltMesh
BTCPAY_WEBHOOK_URL=http://boltmesh-backend:8000/v1/webhooks/btcpay
BTCPAY_XMR_ACCOUNT_INDEX=0
BTCPAY_XMR_CONFIRMATIONS=1
BTCPAY_MONITORING_MINUTES=10080
BTCPAY_WAIT_SECONDS=120
EOF
    log "wrote $BTC_CONFIG/bootstrap.env (mode 600) -- change the admin email/password before first use"
fi
if [ ! -s "$BTC_CONFIG/backend.env" ]; then
    write_secret "$BTC_CONFIG/backend.env" <<EOF
# Written by deploy.sh from $BTC_CONFIG/bootstrap.env after the bootstrap has
# run. The backend/worker units read exactly these four values.
EOF
    log "seeded $BTC_CONFIG/backend.env (filled in after the bootstrap)"
fi
if ensure_secret "$BTC_CONFIG/xmr-wallet.env" "btcpay xmr wallet env"; then
    write_secret "$BTC_CONFIG/xmr-wallet.env" <<EOF
# The BTCPay plugin's VIEW-ONLY Monero wallet. Fill in the primary address and
# private view key of the wallet whose spend key you keep offline, plus its
# restore height; scripts/btcpay-wallet.sh imports it and the bootstrap enables
# XMR-CHAIN. Leaving these empty keeps XMR disabled (the BTC-LN rail is
# unaffected).
XMR_WALLET_ADDRESS=
XMR_VIEW_KEY=
XMR_RESTORE_HEIGHT=0
EOF
    log "wrote $BTC_CONFIG/xmr-wallet.env (mode 600) -- fill it in to enable XMR"
fi

# ---------------------------------------------------------------------------
# 7. units: render every one (they all reference the data or config dir)
# ---------------------------------------------------------------------------
render_unit() {
    local src="$1" target="$2" tmp vol
    tmp="$(mktemp)"
    sed -e "s|@DATA_DIR@|$(esc "$DATA_DIR")|g" \
        -e "s|@CONFIG_DIR@|$(esc "$CONFIG_DIR")|g" \
        -e "s|@REPO_DIR@|$(esc "$REPO_DIR")|g" \
        -e "s|@BACKUP_DIR@|$(esc "$STACK_BACKUP_DIR")|g" \
        -e "s|@BACKUP_PATHS@|$(esc "$(backup_restic_paths)")|g" \
        -e "s|@BITCOIN_RPC_USER@|$(esc "$BITCOIN_RPC_USER")|g" \
        -e "s|@BITCOIN_RPC_PASSWORD@|$(esc "$BITCOIN_RPC_PASSWORD")|g" \
        -e "s|@TOR_SERVICE_PASSWORD@|$(esc "$TOR_SERVICE_PASSWORD")|g" \
        -e "s|@BTCPAY_DB_PASSWORD@|$(esc "$BTCPAY_DB_PASSWORD")|g" \
        -e "s|@BTCPAY_HOST@|$(esc "$BTCPAY_HOST")|g" \
        -e "s|@CROWDSEC_BOUNCER_KEY@|$(esc "${CROWDSEC_BOUNCER_KEY:-}")|g" \
        -e "s|@METRICS_RETENTION@|$(esc "$METRICS_RETENTION")|g" \
        -e "s|@LOGS_RETENTION@|$(esc "$LOGS_RETENTION")|g" \
        -e "s|@LOGS_MAX_BYTES@|$(esc "$LOGS_MAX_BYTES")|g" \
        "$src" > "$tmp"
    # @BACKUP_VOLUMES@ becomes one Volume= line per BACKUP_PATHS entry, which a
    # sed replacement cannot carry (its value is multi-line and would need the
    # newlines escaped); substitute the whole line here instead. Only
    # backup.container carries the token.
    if grep -qF '@BACKUP_VOLUMES@' "$tmp"; then
        vol="$(mktemp)"
        backup_mounts > "$vol"
        awk -v f="$vol" '
            index($0, "@BACKUP_VOLUMES@") { while ((getline l < f) > 0) print l; close(f); next }
            { print }
        ' "$tmp" > "$tmp.vol"
        mv -f "$tmp.vol" "$tmp"
        rm -f "$vol"
    fi
    [ -L "$target" ] && rm -f "$target"
    install -m 600 "$tmp" "$target"
    rm -f "$tmp"
}

# Render a whole directory tree through render_unit, preserving its shape. Used
# for the CrowdSec config (parsers/, scenarios/, acquis.d/), whose files the
# container mounts one by one -- a directory mount over /etc/crowdsec would
# fight the image's own entrypoint, which seeds the rest of that tree.
sync_tree() { # src-dir dest-dir
    local src="$1" dest="$2" rel
    [ -d "$src" ] || return 0
    ( cd "$src" && find . -type f -print ) | while IFS= read -r rel; do
        rel="${rel#./}"
        mkdir -p "$dest/$(dirname "$rel")"
        render_unit "$src/$rel" "$dest/$rel"
    done
}

# ---------------------------------------------------------------------------
# runtime files a container runs, but that the checkout owns
# ---------------------------------------------------------------------------
# Two units run a file that belongs to this checkout rather than to $DATA_DIR:
# monerod's --block-notify helper and the BTCPay bootstrap script. Mounting them
# straight out of the repo made the checkout a *runtime* dependency of a
# container's start: moving or deleting it broke monerod's next start (podman
# fails on a missing bind source, naming a path nobody edited). The host scripts
# in deploy/*.service still run from the checkout -- they are the tooling itself
# -- but a container that a daemon starts must not. So stage both under
# $DATA_DIR/bin on every run (small, secret-free, regenerable) and let the units
# reference only the data dir. CI fails if a container template mentions
# @REPO_DIR@ again, because this is the rule and not an accident of these two.
mkdir -p "$DATA_DIR/bin"
install -m 755 "$DEPLOY_DIR/btcpay/monero-notify.sh" "$DATA_DIR/bin/monero-notify.sh"
install -m 755 "$REPO_DIR/scripts/btcpay_bootstrap.py" "$DATA_DIR/bin/btcpay_bootstrap.py"

# Render a unit over the one already installed, keeping the render it replaces
# as <target>.bak. Three things here are load-bearing:
#   - the backup is the *previous* render, not the first one the host ever had:
#     that copy was written once and then frozen, so "roll back to the .bak"
#     reverted every unit edit since the first install;
#   - cp -p keeps mode 600 -- several rendered units carry @PLACEHOLDER@ secrets;
#   - it backs up only when this render actually changes the file, because
#     deploy.sh runs install.sh twice per deploy (the CLN runes need a running
#     node). An unconditional backup would have the second run record the file
#     the first run just wrote, i.e. destroy the rollback it exists for.
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
# Before the units: podman's event log is a host config, rendered once here
# rather than flagged at every exec call site (see podman_events_conf).
podman_events_conf
for pair in "${UNITS[@]}"; do
    src="$DEPLOY_DIR/${pair%%:*}"
    unit="${pair##*:}"
    render_unit_backedup "$src" "$QUADLET_DIR/$unit"
done
log "rendered ${#UNITS[@]} units (mode 600)"

# Plain user units go to the user unit dir (see USER_UNIT_DIR): Quadlet will
# not generate them. The timers activate the services they name --
# backup.service (generated by Quadlet from backup.container) and
# monitor.service (a plain host-script unit).
mkdir -p "$USER_UNIT_DIR"
for u in "${USER_UNITS[@]}"; do
    render_unit_backedup "$DEPLOY_DIR/$u" "$USER_UNIT_DIR/$u"
done
log "installed ${#USER_UNITS[@]} user unit(s) into $USER_UNIT_DIR"

# ---------------------------------------------------------------------------
# the nginx rate-limit zones
# ---------------------------------------------------------------------------
# nginx-proxy-manager includes /data/nginx/custom/http.conf inside http {} and
# never regenerates custom/, so the zones declared there survive every
# reconciliation of the proxy hosts -- which is why they cannot live in the
# proxy_host/*.conf files (NPM rewrites those from its database).
#
# Seeded here, before deploy.sh starts NPM, because a vhost that references an
# undeclared zone makes nginx refuse to start -- and on Network=host that takes
# the admin UI down with the site.
mkdir -p "$NPM_DIR/data/nginx/custom"
if ! cmp -s "$DEPLOY_DIR/npm/http.conf" "$NPM_DIR/data/nginx/custom/http.conf" 2>/dev/null; then
    install -m 644 "$DEPLOY_DIR/npm/http.conf" "$NPM_DIR/data/nginx/custom/http.conf"
    # The npm/data tree is mounted with :z, which relabels the whole subtree when
    # the container starts -- but a file written *after* that is created with the
    # default label, and nginx then refuses to load it ("open() ... failed (13:
    # Permission denied)"). Relabel it here rather than relying on a restart that
    # a deploy may not perform.
    if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        chcon -t container_file_t "$NPM_DIR/data/nginx/custom/http.conf" 2>/dev/null \
            || warn "could not label $NPM_DIR/data/nginx/custom/http.conf for containers"
    fi
    log "seeded the nginx rate-limit zones into $NPM_DIR/data/nginx/custom/http.conf"
fi

# ---------------------------------------------------------------------------
# the IDS config tree
# ---------------------------------------------------------------------------
# CrowdSec's parser, scenarios, whitelists and acquisition, rendered into
# $CONFIG_DIR/ids/crowdsec and mounted file by file by deploy/crowdsec.container.
# Rendered rather than mounted from the repo for the same reason as the
# VictoriaMetrics scrape config: what the container reads is an install artifact,
# so a change lands on a deploy -- and deploy.sh's unit_digest hashes this tree
# under the stem "crowdsec", so a changed parser restarts the unit instead of
# waiting for the next reboot.
sync_tree "$DEPLOY_DIR/crowdsec" "$CONFIG_DIR/ids/crowdsec"
# The container's own state: /etc/crowdsec (seeded on first start, then the hub
# installs live there) and the sqlite decisions DB. Both regenerable, so both
# stay outside BACKUP_PATHS.
mkdir -p "$DATA_DIR/ids/crowdsec/etc" "$DATA_DIR/ids/crowdsec/data"
log "rendered the crowdsec config into $CONFIG_DIR/ids/crowdsec"

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
    bitcoin/ monero/ fulcrum/ btcpay/ nbxplorer/ cln/ tor/ searxng/ npm/
    uptime-kuma/    <- the status page's sqlite, history and login (its own UI)
    ids/            <- suricata's eve.json (root-owned) and crowdsec's state
    postgres/       <- the BoltMesh cluster (dumped, not backed up raw)
    postgres-dump/  <- the pre-backup pg_dumpall
    config/         <- all bearer tokens and secrets (mode 600)
    audit/          <- the monitor's log and the spend tripwire baselines
    monitoring/     <- the metrics store and node-exporter's textfile (regenerable)
    logs/           <- the log store and vector's checkpoint (regenerable)
    backup-cache/   <- restic's cache (regenerable)
    backup-verify/  <- the restore drill's scratch target: created by its first
                       run, wiped before and after each one (regenerable)
  $STACK_BACKUP_DIR
    the restic repository the nightly backup writes (backup.timer);
    backup-verify.timer restores it to a scratch dir every week and records the
    verdict in $DATA_DIR/audit/backup-verify.status

Next:  ./deploy.sh         # build images, start everything, verify
The two explorers are built by ./deploy.sh from btc-explorer/ and xmr-explorer/
  (not pulled): BTC RPC Explorer (Node) and MoneroBlock (Go, RPC-only). Both are
  small local builds. They are served at https://$BTC_EXPLORER_HOST and
  https://$XMR_EXPLORER_HOST once the NPM admin login is in place.
Spending is OFF on both money servers until you set ENABLE_SPENDING=1 under
  $CONFIG_DIR/monero-wallet-mcp/spend.env  and  $CONFIG_DIR/lightning-mcp/spend.env
BoltMesh is wired to BTCPay; fill in the OAuth / SMTP / GitHub values in
  $CONFIG_DIR/boltmesh/app.env before first use, and put the XMR address / view
  key / restore height in $CONFIG_DIR/btcpay/xmr-wallet.env to enable XMR-CHAIN.
The monitor runs every 5 minutes (monitor.timer) and pushes its alert set to
  Alertmanager (loopback :9093). Mail needs SMTP in
  $CONFIG_DIR/monitoring/alertmanager/alertmanager.yml, and the dead-man's
  switch (MONITOR_PING_URL) is set in $CONFIG_DIR/monitoring/monitor.env.
  Prove the path with scripts/monitor.sh --test.
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
The status page's monitors are reconciled by scripts/kuma-monitors.sh once
  $CONFIG_DIR/uptime-kuma/api.env has the login the setup wizard asked for;
  the declaration is KUMA_MONITORS in stack.conf.
Keep a copy of RESTIC_PASSWORD ($BACKUP_ENV) off the data disk: it is the only
key to the backups.
EOF
