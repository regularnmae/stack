#!/usr/bin/env bash
# Provision a bare Rocky Linux 10 (or RHEL/Fedora) host for the stack:
#
#   * rootless podman (+ quadlet, which is built into podman 5)
#   * systemd user linger, so the containers survive logout
#   * net.ipv4.ip_unprivileged_port_start=80, so nginx-proxy-manager can bind
#     80/443/81 without root
#   * firewalld enabled (deploy.sh opens the specific ports)
#   * the build, data and NPM directories
#
# Run as your normal login user -- it uses sudo for the privileged parts. The
# containers themselves always run rootless. Idempotent.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || printf '%s' "$PWD")"
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
    log "installing podman, firewalld, git, openssl"
    sudo dnf install -y podman firewalld git openssl
else
    log "podman already installed ($(podman --version))"
fi
command -v git >/dev/null 2>&1 || { log "installing git"; sudo dnf install -y git; }

# Rootless networking needs one of these; both are optional per release.
command -v slirp4netns >/dev/null 2>&1 || sudo dnf install -y slirp4netns >/dev/null 2>&1 || true
command -v pasta >/dev/null 2>&1 || sudo dnf install -y passt >/dev/null 2>&1 || true

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
# 6. firewalld
# ---------------------------------------------------------------------------
log "enabling firewalld"
sudo systemctl enable --now firewalld >/dev/null 2>&1 || warn "could not enable firewalld"

# ---------------------------------------------------------------------------
# 7. directories
# ---------------------------------------------------------------------------
log "creating $BUILD_DIR, $DATA_HOME/data and $DATA_HOME/npm"
mkdir -p "$BUILD_DIR" \
    "$DATA_HOME/data" \
    "$DATA_HOME/npm/data" "$DATA_HOME/npm/letsencrypt" \
    "$DATA_HOME/.config/containers/systemd"

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

cat <<EOF

Bootstrap complete.

  podman      $(podman --version 2>/dev/null || echo missing)
  linger      $(loginctl show-user "$USER_NAME" 2>/dev/null | sed -n 's/^Linger=//p')
  port start  $(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null)
  data        $DATA_HOME/data
  npm         $DATA_HOME/npm

Next:
  $NEXT
EOF
