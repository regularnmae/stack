#!/usr/bin/env bash
# Provision a bare Rocky Linux 10 (or RHEL/Fedora) host for the stack:
#
#   * rootless podman (+ quadlet, which is built into podman 5)
#   * systemd user linger, so the containers survive logout
#   * net.ipv4.ip_unprivileged_port_start=80, so nginx-proxy-manager can bind
#     80/443/81 without root
#   * firewalld enabled and the stack's ports opened (FIREWALL_PORTS)
#   * journald made persistent and bounded, so the container logs survive a
#     reboot (they are the source the log store collects from)
#   * the build dir and the quadlet directory (deploy.sh creates the data dirs)
#
# Run as your normal login user -- it uses sudo for the privileged parts. The
# containers themselves always run rootless. Idempotent.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || printf '%s' "$PWD")"
# FIREWALL_PORTS comes from stack.conf. Default it empty so `set -u` is happy
# when this script runs standalone (curl | bash) with no manifest yet; step 8
# reads it from the clone when there was none at the top.
FIREWALL_PORTS=()
# The manifest is optional: this script also runs standalone (curl | bash) on a
# host that has no clone yet, where REPO_DIR is just the current directory.
if [ -r "$REPO_DIR/stack.conf" ]; then
    # shellcheck source=stack.conf
    . "$REPO_DIR/stack.conf"
fi
GITHUB_ORG="${GITHUB_ORG:-regularnmae}"
BUILD_DIR="${BUILD_DIR:-$HOME/build}"

USER_NAME="$(id -un)"
DATA_HOME="$HOME"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your login user, not root; this script calls sudo itself"
command -v sudo >/dev/null 2>&1 || die "sudo is required"

# Prime sudo once, so the privileged calls below don't each prompt (and so a
# non-interactive session fails here with a clear message rather than halfway
# through provisioning).
if ! sudo -n true 2>/dev/null; then
    log "sudo needs a password; you may be prompted once"
    sudo -v || die "sudo authentication failed -- run bootstrap.sh from an interactive terminal (sudo needs a TTY to prompt), or configure passwordless sudo"
fi

# ---------------------------------------------------------------------------
# 1. distribution
# ---------------------------------------------------------------------------
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
case "${ID:-} ${ID_LIKE:-}" in
    *rhel*|*fedora*|*rocky*|*centos*) ;;
    *) die "unsupported distribution: ${PRETTY_NAME:-unknown} (expected RHEL/Rocky/Fedora)";;
esac
log "provisioning on ${PRETTY_NAME:-this host}"

# ---------------------------------------------------------------------------
# 2. packages
# ---------------------------------------------------------------------------
if ! command -v podman >/dev/null 2>&1; then
    log "installing podman, firewalld, git, openssl, jq"
    sudo dnf install -y podman firewalld git openssl jq
else
    log "podman already installed ($(podman --version))"
fi
command -v git >/dev/null 2>&1 || { log "installing git"; sudo dnf install -y git; }
# jq parses the nginx-proxy-manager admin API responses in
# scripts/npm-hosts.sh (the host has no curl either; netcheck carries it).
command -v jq >/dev/null 2>&1 || { log "installing jq"; sudo dnf install -y jq; }

# audit-rules provides auditctl/augenrules, which load the stack's audit rules
# (deploy/root/audit.rules). EL10 split them out of the `audit` package, so a
# host with auditd running can still have no way to add a rule -- which is
# exactly the state this host was in: a daemon watching nothing.
if [ ! -x /usr/sbin/augenrules ]; then
    log "installing audit-rules (auditctl/augenrules)"
    sudo dnf install -y audit-rules >/dev/null 2>&1 \
        || warn "could not install audit-rules; the stack's audit watches will not load"
fi

# Rootless networking needs one of these; both are optional per release.
command -v slirp4netns >/dev/null 2>&1 || sudo dnf install -y slirp4netns >/dev/null 2>&1 || true
command -v pasta >/dev/null 2>&1 || sudo dnf install -y passt >/dev/null 2>&1 || true
# semanage (policycoreutils-python-utils) lets the deploy label a data disk
# persistently; without it the deploy falls back to chcon.
command -v semanage >/dev/null 2>&1 || sudo dnf install -y policycoreutils-python-utils >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. subuid / subgid (rootless user namespaces)
# ---------------------------------------------------------------------------
if ! grep -q "^$USER_NAME:" /etc/subuid 2>/dev/null; then
    log "adding subuid/subgid ranges for $USER_NAME"
    sudo usermod --add-subuids 524288-589823 --add-subgids 524288-589823 "$USER_NAME"
else
    log "subuid/subgid already present for $USER_NAME"
fi

# ---------------------------------------------------------------------------
# 4. linger
# ---------------------------------------------------------------------------
if [ "$(loginctl show-user "$USER_NAME" 2>/dev/null | sed -n 's/^Linger=//p')" = "yes" ]; then
    log "linger already enabled"
else
    log "enabling systemd user linger for $USER_NAME"
    sudo loginctl enable-linger "$USER_NAME"
fi

# ---------------------------------------------------------------------------
# 5. unprivileged ports (nginx-proxy-manager binds :80/:443/:81 rootless)
# ---------------------------------------------------------------------------
SYSCTL_FILE=/etc/sysctl.d/99-stack-unprivileged-ports.conf
if [ "$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)" -gt 80 ]; then
    log "setting net.ipv4.ip_unprivileged_port_start=80"
    printf 'net.ipv4.ip_unprivileged_port_start=80\n' | sudo tee "$SYSCTL_FILE" >/dev/null
    sudo sysctl --system >/dev/null
else
    log "unprivileged port start is already <= 80"
fi

# ---------------------------------------------------------------------------
# 6. journald persistence (the source every log line is collected from)
# ---------------------------------------------------------------------------
# journald defaults to Storage=auto, which means VOLATILE when /var/log/journal
# does not exist -- and on this host it did not, so the whole journal was a
# 32 MB ring in /run that a reboot erased. Every container's stdout and every
# host script writes there, so that was the stack's only record of what
# happened, gone.
#
# Persistent, and bounded: ~10 MB of text an hour compresses to roughly 1.5 GB
# a day on this host, so 2 GB is about a day and a half on the root filesystem
# (36 GB free). The log store keeps 14 days; this only has to cover `podman
# logs` across a reboot and the window before `vector` has shipped an entry.
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/99-stack.conf
# Persistent means "journald is actually writing under /var/log/journal", not
# "the config file says so". Two things make the difference, both measured:
#   * journald starts on the runtime journal and only switches on a flush
#     (`journalctl --flush`, or SIGUSR1; systemd-journal-flush.service does it
#     at boot, which is why restarting the service alone changes nothing);
#   * /var/log/journal must carry the tmpfiles ACL (group wheel r-x) that the
#     rootless vector container reads through -- a plain `install -d` has none.
journald_persistent() {
    [ -n "$(find /var/log/journal -name '*.journal' -print -quit 2>/dev/null)" ]
}

if grep -q '^Storage=persistent' "$JOURNALD_DROPIN" 2>/dev/null && journald_persistent; then
    log "journald is already persistent ($JOURNALD_DROPIN)"
else
    log "making journald persistent and bounded (2G, 7 days)"
    sudo install -d -m 2755 /var/log/journal
    # journald creates this on flush; creating it here makes the group and the
    # inherited ACL deterministic from the first boot.
    sudo install -d -m 2755 -o root -g systemd-journal "/var/log/journal/$(cat /etc/machine-id)"
    sudo install -d -m 755 "$(dirname "$JOURNALD_DROPIN")"
    if ! grep -q '^Storage=persistent' "$JOURNALD_DROPIN" 2>/dev/null; then
        sudo tee "$JOURNALD_DROPIN" >/dev/null <<'EOF'
# Written by bootstrap.sh; the stack's containers and host scripts all log to
# journald, and the default (volatile) threw the record away on every reboot.
[Journal]
Storage=persistent
SystemMaxUse=2G
SystemMaxFileSize=200M
MaxRetentionSec=7d
EOF
    fi
    # tmpfiles owns /var/log/journal: it sets root:systemd-journal and the
    # inheritable ACL (group adm + wheel r-x) that the rootless vector container
    # reads the journal through.
    sudo systemd-tmpfiles --create --prefix /var/log/journal \
        || warn "could not apply tmpfiles to /var/log/journal; the shipper may not be able to read it"
    sudo systemctl restart systemd-journald \
        || warn "could not restart systemd-journald"
    # The step that actually switches storage. Without it journald keeps
    # logging to /run even though the config says persistent (journald.conf(5):
    # "journald will initially use volatile storage, until a call to journalctl
    # --flush ... will cause it to switch to persistent logging").
    sudo journalctl --flush >/dev/null 2>&1 \
        || warn "journalctl --flush failed; journald may stay on the runtime journal"
    if ! journald_persistent; then
        warn "journald is still writing to /run/log/journal; check 'systemctl status systemd-journald'"
    fi
fi

# ---------------------------------------------------------------------------
# 7. firewalld
# ---------------------------------------------------------------------------
log "enabling firewalld"
sudo systemctl enable --now firewalld >/dev/null 2>&1 || warn "could not enable firewalld"

# ---------------------------------------------------------------------------
# 8. directories
# ---------------------------------------------------------------------------
log "creating $BUILD_DIR and the quadlet directory"
mkdir -p "$BUILD_DIR" "$DATA_HOME/.config/containers/systemd"

systemctl --user daemon-reload 2>/dev/null || true

# If this is not a checkout (curl | bash), fetch one now that git exists, so
# the next step is always deploy.sh.
if [ -f "$REPO_DIR/deploy.sh" ]; then
    NEXT="$REPO_DIR/deploy.sh"
else
    NEXT="$BUILD_DIR/stack/deploy.sh"
    if [ ! -d "$BUILD_DIR/stack/.git" ]; then
        log "cloning $GITHUB_ORG/stack into $BUILD_DIR/stack"
        git clone -q "https://github.com/$GITHUB_ORG/stack.git" "$BUILD_DIR/stack" \
            || warn "could not clone; clone it yourself, then run deploy.sh"
    fi
fi

# ---------------------------------------------------------------------------
# 9. firewalld ports
# ---------------------------------------------------------------------------
# The list lives in stack.conf. From a checkout it was sourced at the top; under
# `curl | bash` there was no manifest until the clone above, so read it from
# there now. Opening the ports only needs firewalld, not the running stack.
if [ "${#FIREWALL_PORTS[@]}" -eq 0 ]; then
    MANIFEST="$REPO_DIR/stack.conf"
    [ -r "$MANIFEST" ] || MANIFEST="$BUILD_DIR/stack/stack.conf"
    if [ -r "$MANIFEST" ]; then
        # shellcheck source=stack.conf
        . "$MANIFEST"
    fi
fi

if [ "${#FIREWALL_PORTS[@]}" -eq 0 ]; then
    warn "no stack.conf found; open the stack's ports yourself"
elif ! command -v firewall-cmd >/dev/null 2>&1; then
    warn "firewall-cmd not found; open ${FIREWALL_PORTS[*]}/tcp yourself"
elif ! systemctl is-active --quiet firewalld; then
    warn "firewalld is not running; open ${FIREWALL_PORTS[*]}/tcp yourself"
else
    # firewall-cmd needs privilege (it talks to firewalld over D-Bus), and this
    # is the last sudo use -- sudo was primed at the top. --add-port is
    # idempotent, so a re-run is a no-op.
    args=()
    for p in "${FIREWALL_PORTS[@]}"; do args+=(--add-port="$p/tcp"); done
    log "opening ${FIREWALL_PORTS[*]}/tcp in firewalld"
    sudo firewall-cmd --permanent "${args[@]}" >/dev/null \
        || warn "could not open ports; run: sudo firewall-cmd --permanent ${args[*]} && sudo firewall-cmd --reload"
    sudo firewall-cmd --reload >/dev/null || true
fi

# ---------------------------------------------------------------------------
# 10. the root tier: the intrusion-detection sensor
# ---------------------------------------------------------------------------
# One unit in this repo runs as root: Suricata, because AF_PACKET capture needs
# CAP_NET_RAW in the init user namespace (deploy/root/suricata.container owns the
# long version). Everything else stays rootless, and this is the only place that
# writes outside the user's home.
#
# It is a *second* pass on purpose: the sensor's config references the data dir,
# which does not exist until deploy.sh has run. So the first bootstrap skips this
# step with a notice, and the follow-up run (bootstrap is idempotent) installs it.
# Rendering lives in deploy/install.sh --root so that the installer stays the one
# authority on what gets installed -- this script only supplies the data dir.
IDS_DATA_DIR="${STACK_DATA_DIR:-}"
if [ -z "$IDS_DATA_DIR" ]; then
    DATA_POINTER="${STACK_DATA_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/stack/data-dir.env}"
    if [ -r "$DATA_POINTER" ]; then
        # shellcheck disable=SC1090
        . "$DATA_POINTER"
        IDS_DATA_DIR="${STACK_DATA_DIR:-}"
    fi
fi

if [ ! -x "$REPO_DIR/deploy/install.sh" ]; then
    log "no stack checkout yet; re-run bootstrap.sh after the first deploy.sh to install the IDS sensor"
elif [ -z "$IDS_DATA_DIR" ] || [ ! -d "$IDS_DATA_DIR" ]; then
    log "no data dir yet; re-run bootstrap.sh after the first deploy.sh to install the IDS sensor"
else
    log "installing the root tier (Suricata IDS) with data dir $IDS_DATA_DIR"
    sudo "$REPO_DIR/deploy/install.sh" --root --data-dir "$IDS_DATA_DIR" \
        || warn "could not install the root tier; run: sudo $REPO_DIR/deploy/install.sh --root --data-dir $IDS_DATA_DIR"
fi

cat <<EOF

Bootstrap complete.

  podman      $(podman --version 2>/dev/null || echo missing)
  linger      $(loginctl show-user "$USER_NAME" 2>/dev/null | sed -n 's/^Linger=//p')
  port start  $(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null)
  firewall    $(systemctl is-active firewalld 2>/dev/null || echo unknown) (${#FIREWALL_PORTS[@]} ports)
  journald    $(journald_persistent && echo persistent || echo volatile)
  build       $BUILD_DIR

Next:
  $NEXT

That asks where the stack keeps its data (default \$HOME/data). Point it at a
separate disk to survive an OS reinstall.
EOF
