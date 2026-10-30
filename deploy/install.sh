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
# backup-verify.service, backup-verify.timer, monitor.timer and monitor.service
# are installed as ordinary user units.
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
# Escape a value for sed's replacement side (&, \, |). Defined here, above the
# root-tier block, because that block renders files too -- defining it later (as
# it once was) silently substituted an empty string into every @DATA_DIR@, since
# a failed command substitution in an argument does not trip `set -e`.
esc() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }

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
            printf 'LAPI=127.0.0.1:8081\n'
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
    "monero-wallet-rpc.container.in:monero-wallet-rpc.container"
    "searxng-mcp.container:searxng-mcp.container"
    "bitcoin-node-mcp.container:bitcoin-node-mcp.container"
    "monero-node-mcp.container:monero-node-mcp.container"
    "monero-wallet-mcp.container:monero-wallet-mcp.container"
    "lightning-mcp.container:lightning-mcp.container"
    "postgres.container:postgres.container"
    "uptime-kuma.container:uptime-kuma.container"
    "boltmesh-backend.container:boltmesh-backend.container"
    "boltmesh-worker.container:boltmesh-worker.container"
    "boltmesh-frontend.container:boltmesh-frontend.container"
    "postgres-dump.container:postgres-dump.container"
    "backup.container:backup.container"
    "victoriametrics.container:victoriametrics.container"
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
# CLN_SPEND_METHODS, BOLTMESH_RUNE_METHODS) because scripts/rotate.sh mints the
# same runes on a rotation; rune_json (scripts/lib.sh) turns each array into the
# restriction JSON. SPEND is the read set plus the payment methods.
SPEND_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}" "${CLN_SPEND_METHODS[@]}")
READ_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}")
# BoltMesh's Lightning gateway only creates invoices and reads them back (the
# clnrest calls are /v1/invoice and /v1/listinvoices), so its rune is a subset:
# no pay/keysend/withdraw/close. getinfo is included so `checkrune` proves it.
BOLTMESH_RESTRICTIONS=$(rune_json "${BOLTMESH_RUNE_METHODS[@]}")

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
        printf 'Volume=%s/%s:/data/%s:ro,z\n' "$DATA_DIR" "$p" "$p"
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

# Full (archival) node: keep and validate the whole chain. txindex stays off;
# the MCP server and lightningd do not need it, and it costs another index.
prune=0
txindex=0

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

# Logs: the store, the shipper's checkpoint, and the shipper's config.
#
# victoria-logs and vector both run as container root == the login user under
# rootless podman (like victoriametrics), so a plain mkdir is enough -- no
# podman-unshare chown, unlike bitcoind and monero-wallet-rpc.
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

# BTC RPC Explorer's configuration. The app is configured entirely through the
# environment (so the unit uses EnvironmentFile=, not a rendered Exec=), and it
# needs the same bitcoind RPC credentials plus Fulcrum's Electrum endpoint. It
# keeps no data of its own. txindex stays 0: address history comes from Fulcrum;
# an old txid needs its block height (README: "Block explorers").
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

# ---------------------------------------------------------------------------
# BoltMesh env files (under the data dir, like every other app's)
# ---------------------------------------------------------------------------
# The app reads one flat environment, so the split here is by who owns each
# value: install.sh generates the database and the signing keys, the operator
# fills in the third-party credentials, and gateway.env is derived from the
# running daemons (written further down, once lightningd can be reached).
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
# payment gateways) are in db.env/secrets.env/gateway.env -- do not duplicate
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

# Thresholds for the host checks. Each is a number the script compares against;
# leaving it empty keeps the default shown here, and they are read at run time,
# so editing this file needs no reload.
#   disk/inodes: per cent still free. This is the number node_exporter graphs,
#                read here directly with df so alerting needs no query engine.
#   io:          % of wall time the data dir's disk is busy, sampled over 3s;
#                sustained contention is what makes every chain crawl.
#   backup:      hours since the last successful restic snapshot (a timer that
#                fires is not the same as a repository that has a snapshot).
#   drill:       hours since the last successful restore drill (scripts/backup.sh
#                verify). Keyed on the last SUCCESS, so a drill that skips for
#                lack of disk space cannot look healthy just because it ran.
#   cert:        days of remaining validity on the shortest-lived certificate
#                nginx-proxy-manager holds (a failed renewal is otherwise silent).
#   restarts:    systemd restarts of any stack unit between two sweeps.
#   metrics:     seconds before stack.prom counts as stale (the collector is a
#                60s timer; five missed ticks is a real failure).
#   logs:        seconds before the newest log entry counts as stale (vector
#                ships continuously; 15 minutes is a stopped pipeline, not lag).
#   fulcrum:     blocks Fulcrum's Electrum index may lag bitcoind (it polls every
#                5s when healthy, so the default 12 means "stopped following").
MONITOR_DISK_FREE_PCT=10
MONITOR_INODES_FREE_PCT=5
MONITOR_IO_UTIL_PCT=90
MONITOR_BACKUP_MAX_AGE_H=36
MONITOR_BACKUP_VERIFY_MAX_AGE_H=192
MONITOR_CERT_MIN_DAYS=14
MONITOR_RESTART_MAX=3
MONITOR_METRICS_MAX_AGE_S=300
MONITOR_LOGS_MAX_AGE_S=900
MONITOR_FULCRUM_LAG_BLOCKS=12
EOF
    log "wrote $MON_ENV (mode 600) -- empty targets: journal-only until filled in"
fi

# nginx-proxy-manager's admin API, for scripts/npm-hosts.sh: it reconciles every
# proxy host the stack serves (NPM_HOSTS in stack.conf) -- the BoltMesh,
# SearXNG and explorer web hosts and the MCP path-prefix host. The admin login
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

# BoltMesh's payment gateway wiring, derived from the running daemons: the CLN
# rune (created here, so it lands on the run that sees a live lightningd) and
# the Monero wallet's RPC login from secrets.env. Rewritten every run -- the
# file is machine-owned, never hand-edited.
BOLT_GATEWAY="$BOLT_DB/gateway.env"
bolt_rune=$(env_value "$BOLT_GATEWAY" LIGHTNING_API_KEY)
if command -v podman >/dev/null 2>&1 && ! rune_usable "$bolt_rune"; then
    if podman exec lightningd lightning-cli getinfo >/dev/null 2>&1; then
        new_bolt_rune=$(create_rune "$BOLTMESH_RESTRICTIONS")
        if [ -n "$new_bolt_rune" ]; then
            bolt_rune="$new_bolt_rune"
            log "created a usable BoltMesh rune"
        fi
    else
        log "lightningd not reachable yet; the BoltMesh rune is created by a later install.sh run"
    fi
fi
write_secret "$BOLT_GATEWAY" <<EOF
# Derived by deploy/install.sh; do not hand-edit. The URL is clnrest over the
# podman network and the rune permits only invoice + listinvoices (+ getinfo for
# the reachability probe), so BoltMesh cannot move funds through CLN.
LIGHTNING_GATEWAY_URL=https://lightningd:3010
LIGHTNING_API_KEY=$bolt_rune
LIGHTNING_TLS_INSECURE=1
MONERO_RPC_URL=http://monero-wallet-rpc:18083/json_rpc
MONERO_RPC_USER=${MONERO_RPC_LOGIN%%:*}
MONERO_RPC_PASSWORD=${MONERO_RPC_LOGIN#*:}
EOF
log "wrote $BOLT_GATEWAY (mode 600)"

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
        -e "s|@MONERO_WALLET_PASSWORD@|$(esc "$MONERO_WALLET_PASSWORD")|g" \
        -e "s|@MONERO_RPC_LOGIN@|$(esc "$MONERO_RPC_LOGIN")|g" \
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
    bitcoin/ monero/ fulcrum/ monero-wallet-rpc/ cln/ tor/ searxng/ npm/
    postgres/       <- the BoltMesh cluster (dumped, not backed up raw)
    postgres-dump/  <- the pre-backup pg_dumpall
    config/         <- all bearer tokens and secrets (mode 600)
    audit/          <- the monitor's log and the spend tripwire baselines
    monitoring/     <- the metrics store and node-exporter's textfile (regenerable)
    logs/           <- the log store and vector's checkpoint (regenerable)
    backup-verify/  <- the restore drill's scratch target (regenerable, wiped each run)
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
BoltMesh is wired to the stack's lightningd and monero-wallet-rpc; fill in the
  OAuth / SMTP / GitHub values in $CONFIG_DIR/boltmesh/app.env before first use.
The monitor runs every 5 minutes (monitor.timer) and alerts only once
  $CONFIG_DIR/monitoring/monitor.env has an Apprise target and/or a heartbeat.
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
