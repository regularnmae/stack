#!/usr/bin/env bash
# Check every pulled container image names a concrete version. This is the gate
# that would have caught the two tags that silently froze on this host:
#
#   postgres:18-alpine       a major-only tag, left at 18.6 after 18.7 shipped
#   uptime-kuma:2            a major-only tag, left at 2.5.7 after the RCE fix
#
# Podman only pulls a *missing* image. A tag that never changes is therefore
# never refreshed, no matter what Renovate says about it. `localhost/*` is
# exempt because those images are built here, not pulled; a digest-pinned image
# is exempt because it cannot move under the tag.
#
#   ./scripts/image-lint.sh
#   ./scripts/image-lint.sh --units-dir tests/fixtures/units
#
# The pair checks encode the couplings a single-unit edit can break: the dump
# image must match the server's minor, vmalert must match VictoriaMetrics, and
# the BTCPay Monero wallet must match monerod's release.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

UNITS_DIR="$REPO_DIR/deploy"
while [ $# -gt 0 ]; do
    case "$1" in
        --units-dir)
            [ $# -ge 2 ] || die "--units-dir needs a directory"
            UNITS_DIR="$2"
            shift 2
            ;;
        -h|--help) usage_header "$0"; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -d "$UNITS_DIR" ] || die "no such units directory: $UNITS_DIR"

fail=0
count=0
declare -A image_of=()

bad() { # file image why
    printf 'image-lint: %s: %s (%s)\n' "$1" "$2" "$3" >&2
    fail=1
}

# The version part before a variant suffix: 18.7 from 18.7-alpine, 2.5.11 from
# 2.5.11-slim, 2026.10.29 from searxng's date-commit tag. A bare integer (with
# or without a leading v) is a major-only tag.
major_only() {
    local base="${1%%-*}"
    [[ "$base" =~ ^v?[0-9]+$ ]]
}

while IFS= read -r file; do
    while IFS= read -r line; do
        image="${line#Image=}"
        image="${image#"${image%%[![:space:]]*}"}"
        image="${image%"${image##*[![:space:]]}"}"
        [ -n "$image" ] || continue
        count=$((count + 1))
        case "$image" in
            localhost/*) continue ;;
            *@sha256:*) continue ;;
        esac
        case "$image" in
            *:*) tag="${image##*:}" ;;
            *)   bad "$file" "$image" "no tag"; continue ;;
        esac
        case "$tag" in
            latest|master|main|stable|next|edge)
                bad "$file" "$image" "floating tag"
                continue
                ;;
        esac
        if major_only "$tag"; then
            bad "$file" "$image" "major-only tag"
            continue
        fi
        image_of["$(basename "$file")"]="$image"
    done < <(grep -E '^Image=' "$file" || true)
done < <(find "$UNITS_DIR" -maxdepth 2 -type f \( -name '*.container' -o -name '*.container.in' \) | sort)

# A pair that must move together. strip_v is for the Monero pair, where one
# image tags v0.18.5.4 and the other 0.18.5.4.
pair_same() { # label file-a file-b [strip-v]
    local label="$1" a="$2" b="$3" strip="${4:-0}" ia ib ta tb
    ia="${image_of[$a]:-}"
    ib="${image_of[$b]:-}"
    [ -n "$ia" ] && [ -n "$ib" ] || return 0
    ta="${ia##*:}"
    tb="${ib##*:}"
    if [ "$strip" = 1 ]; then
        ta="${ta#v}"
        tb="${tb#v}"
    fi
    [ "$ta" = "$tb" ] && return 0
    printf 'image-lint: %s: %s and %s disagree (%s vs %s)\n' "$label" "$a" "$b" "$ta" "$tb" >&2
    fail=1
}

pair_same postgres postgres.container postgres-dump.container
pair_same victoriametrics victoriametrics.container vmalert.container
pair_same monero monerod.container monero-wallet-btcpay.container 1

if [ "$count" -eq 0 ]; then
    die "no Image= lines found under $UNITS_DIR"
fi

[ "$fail" -eq 0 ] || exit 1
printf 'image-lint: %d image(s), all pulled tags name a concrete version\n' "$count"
