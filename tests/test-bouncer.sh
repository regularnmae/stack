#!/usr/bin/env bash
# Offline regression tests for the two parsers in deploy/root/bouncer.sh.
#
# The bouncer runs as root and deliberately does not read the checkout, so it
# cannot source scripts/lib.sh -- which is why its Go-duration parser is a
# fourth copy of the rule and its private-space test is a hand-written glob
# table. Neither had a test, and both decide whether a packet is dropped or a
# ban is shortened. This file extracts the two functions from the template
# (read-only; nothing here needs root) and pins their behaviour.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOUNCER="$ROOT_DIR/deploy/root/bouncer.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

assert_eq() {
    local want="$1" got="$2" label="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$label" "$want" "$got" >&2
        exit 1
    fi
}

# Pull one function out of the template by its definition line, up to the
# closing brace in column 0. Keeps this test from executing the script (which
# would read bouncer.env and apply nft rules).
extract() { # name src -> the function on stdout
    local name="$1"
    sed -n "/^${name}()/,/^}/p" "$2"
}

for fn in is_internal dur_to_sec; do
    extract "$fn" "$BOUNCER" > "$TMP_DIR/$fn.sh"
    [ -s "$TMP_DIR/$fn.sh" ] || { printf 'FAIL: %s not found in %s\n' "$fn" "$BOUNCER" >&2; exit 1; }
done
# shellcheck source=/dev/null
. "$TMP_DIR/is_internal.sh"
# shellcheck source=/dev/null
. "$TMP_DIR/dur_to_sec.sh"

# --- is_internal: both directions, because a whitelist that is too wide fails
# quietly (the decision still exists, it is just never enforced).
STACK_WAN_IP=203.0.113.7          # TEST-NET-3, the operator's declared egress
# shellcheck disable=SC2034  # read by the sourced is_internal()
OWN_IPS=" 198.51.100.9 192.168.1.112 "  # TEST-NET-2, plus the LAN address

expect_internal() { # ip label
    if ! is_internal "$1"; then
        printf 'FAIL: %s: %s is not treated as internal (it would be banned)\n' "$2" "$1" >&2
        exit 1
    fi
}

expect_external() { # ip label
    if is_internal "$1"; then
        printf 'FAIL: %s: %s is treated as internal (it would never be banned)\n' "$2" "$1" >&2
        exit 1
    fi
}

# Loopback, RFC1918, link-local, the unspecified address.
for ip in 127.0.0.1 127.255.255.255 10.0.0.1 10.89.0.5 \
          192.168.0.1 192.168.1.112 169.254.1.1 0.0.0.0; do
    expect_internal "$ip" 'private space'
done

# 172.16.0.0/12 -- exact boundaries, and the two widenings documented in
# deploy/crowdsec/parsers/s02-enrich/stack-whitelists.yaml (172.2/172.200).
for ip in 172.16.0.1 172.19.255.255 172.20.0.1 172.29.255.255 \
          172.30.0.1 172.31.255.255; do
    expect_internal "$ip" '172.16/12'
done
for ip in 172.15.255.255 172.2.0.1 172.200.0.1 172.32.0.1; do
    expect_external "$ip" 'public 172'
done

# 100.64.0.0/10 (CGNAT) -- the regression this file exists for: the old
# `100.1[0-2][0-9]` also matched 100.128.0.0/16 and 100.129.0.0/16.
for ip in 100.64.0.1 100.69.255.255 100.70.0.1 100.99.255.255 \
          100.100.0.1 100.119.255.255 100.120.0.1 100.127.255.255; do
    expect_internal "$ip" 'CGNAT'
done
for ip in 100.63.255.255 100.128.0.1 100.129.0.1 100.129.255.255 100.130.0.1; do
    expect_external "$ip" 'public 100'
done

# IPv6: loopback, link-local, unique-local.
for ip in ::1 fe80::1 fc00::1 fd12:3456:789a::1; do
    expect_internal "$ip" 'IPv6 private'
done

# The two address classes that come from the host itself.
expect_internal "$STACK_WAN_IP" 'the declared WAN address'
expect_internal 198.51.100.9 'an address the host holds'
expect_external 198.51.100.10 'an address the host does not hold'

# Ordinary public space, and the reserved documentation ranges themselves.
for ip in 1.1.1.1 8.8.8.8 192.169.0.1 203.0.113.8; do
    expect_external "$ip" 'public space'
done

# --- dur_to_sec: the shared Go-duration fixtures, floored instead of rounded.
# tests/fixtures/durations.txt is the one contract all four parsers read; the
# bouncer's clamp (1s floor, 86400s ceiling) is what the LAPI's `duration`
# field becomes in an nft timeout.
while IFS=$'\t' read -r input want_ms; do
    case "$input" in ''|\#*) continue ;; esac
    [ "$input" = '<empty>' ] && input=''
    want_s=$(( want_ms / 1000 ))
    [ "$want_s" -gt 0 ] || want_s=3600          # unparsable -> the 1h default
    [ "$want_s" -le 86400 ] || want_s=86400
    assert_eq "$want_s" "$(dur_to_sec "$input")" "dur_to_sec fixture '$input'"
done < "$ROOT_DIR/tests/fixtures/durations.txt"

# The clamp itself: a one-second decision is refreshed every minute, so a
# sub-second remainder must not become 0 (nft would reject it), and an absurd
# duration must not become a permanent ban.
assert_eq 3600 "$(dur_to_sec '')" 'dur_to_sec defaults an absent duration to 1h'
assert_eq 3600 "$(dur_to_sec 'abc')" 'dur_to_sec defaults garbage to 1h'
assert_eq 86400 "$(dur_to_sec '48h')" 'dur_to_sec caps a long ban at 24h'

printf 'bouncer parser tests: ok\n'
