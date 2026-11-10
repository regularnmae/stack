#!/usr/bin/env bash
# Stage the pinned BTCPay Monero plugin -- a file, so no unit digest sees a bump.
#
#   scripts/btcpay-plugin.sh
#
# Downloads BTCPAY_PLUGIN_URL (stack.conf), verifies BTCPAY_PLUGIN_SHA256,
# extracts into a staging sibling of $DATA_DIR/btcpay/Plugins/$BTCPAY_PLUGIN_ID
# and swaps it in whole, writing .artifact-sha256 as the marker that makes the
# next run a no-op. Run by deploy/btcpay-plugin.service, which btcpay.container
# Wants= and After= (a first start cannot race it) and which deploy.sh starts
# before the BTCPay tier -- starting an already-active btcpay does not re-run
# its Wants=.
#
# A failure is a warning, not an error: BTC-LN still works, an installed plugin
# stays loadable, and the next start retries. BTCPay maps the assemblies at
# start, so a swapped DLL does nothing until the container is recreated --
# deploy.sh's btcpay_plugin_newer is what notices. docs/btcpay.md owns this.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

resolve_data_dir
mkdir -p "$DATA_DIR/btcpay/Plugins"

dir="$DATA_DIR/btcpay/Plugins/$BTCPAY_PLUGIN_ID"
marker="$dir/.artifact-sha256"

installed=""
[ -f "$marker" ] && installed=$(cat "$marker" 2>/dev/null)
if [ -f "$dir/$BTCPAY_PLUGIN_ID.dll" ] && [ "$installed" = "$BTCPAY_PLUGIN_SHA256" ]; then
    exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
    warn "curl is missing; cannot download the BTCPay Monero plugin"
    exit 0
fi

tmp=$(mktemp)
if ! curl -fsSL --max-time 120 "$BTCPAY_PLUGIN_URL" -o "$tmp"; then
    warn "could not download the BTCPay Monero plugin; the installed one stays, XMR will stay disabled if there is none"
    rm -f "$tmp"
    exit 0
fi
if [ "$(sha256sum "$tmp" | awk '{print $1}')" != "$BTCPAY_PLUGIN_SHA256" ]; then
    warn "BTCPay Monero plugin hash mismatch; refusing to install it"
    rm -f "$tmp"
    exit 0
fi

# Extract into a sibling directory and swap it in whole: extracting over the
# previous version would leave its extra files behind, and a failed download,
# extract or swap must not destroy a plugin that works.
stage=$(mktemp -d "$DATA_DIR/btcpay/Plugins/.stage.XXXXXX") || {
    warn "could not create a staging directory for the BTCPay Monero plugin"
    rm -f "$tmp"
    exit 0
}
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$tmp" -d "$stage" || { warn "could not extract the BTCPay Monero plugin"; rm -rf "$stage" "$tmp"; exit 0; }
elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp" "$stage" \
        || { warn "could not extract the BTCPay Monero plugin"; rm -rf "$stage" "$tmp"; exit 0; }
else
    warn "neither unzip nor python3 is available to extract the BTCPay Monero plugin"
    rm -rf "$stage"
    rm -f "$tmp"
    exit 0
fi
rm -f "$tmp"
if [ ! -s "$stage/$BTCPAY_PLUGIN_ID.dll" ]; then
    warn "the BTCPay Monero plugin artifact has no $BTCPAY_PLUGIN_ID.dll; keeping the installed one"
    rm -rf "$stage"
    exit 0
fi

# Move the installed tree aside rather than deleting it: a directory cannot be
# replaced atomically, so the old copy is what keeps BTCPay loadable if the
# second rename fails. The aside name is fixed and OUTSIDE Plugins/ (BTCPay
# scans that directory and must not find a second copy), removed only after the
# new tree is in place.
old="$DATA_DIR/btcpay/.plugin-previous"
if [ ! -e "$dir" ] && [ -e "$old" ]; then
    # A previous run died between the two renames; the only working copy is
    # still here.
    if ! mv "$old" "$dir"; then
        warn "could not restore the BTCPay Monero plugin from $old"
        rm -rf "$stage"
        exit 0
    fi
fi
rm -rf "$old"
has_old=0
if [ -e "$dir" ]; then
    if ! mv "$dir" "$old"; then
        warn "could not move the installed BTCPay Monero plugin aside; keeping it"
        rm -rf "$stage"
        exit 0
    fi
    has_old=1
fi
chmod 755 "$stage"
if ! mv "$stage" "$dir"; then
    warn "could not move the BTCPay Monero plugin into $dir"
    if [ "$has_old" = 1 ]; then
        mv "$old" "$dir" 2>/dev/null || warn "the previous plugin is left in $old"
    fi
    rm -rf "$stage"
    exit 0
fi
if [ "$has_old" = 1 ]; then
    rm -rf "$old"
fi
printf '%s\n' "$BTCPAY_PLUGIN_SHA256" > "$marker"
log "installed the BTCPay Monero plugin into $dir"
