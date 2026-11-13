#!/usr/bin/env bash
# Offline regression tests for scripts/image-lint.sh. The gate has to reject the
# two tags that froze on this host (postgres:18-alpine, uptime-kuma:2), keep the
# deliberate localhost/* exception, and catch a pair that drifted apart.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT_DIR/scripts/image-lint.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

UNITS="$TMP_DIR/units"
mkdir -p "$UNITS"

write_unit() { # name image
    printf '[Container]\nImage=%s\n' "$2" > "$UNITS/$1.container"
}

write_unit postgres 'docker.io/library/postgres:18.7-alpine'
write_unit postgres-dump 'docker.io/library/postgres:18.7-alpine'
write_unit victoriametrics 'docker.io/victoriametrics/victoria-metrics:v1.156.0'
write_unit vmalert 'docker.io/victoriametrics/vmalert:v1.156.0'
write_unit monerod 'ghcr.io/sethforprivacy/simple-monerod:v0.18.5.4'
write_unit monero-wallet-btcpay 'docker.io/btcpayserver/monero:0.18.5.4'
write_unit local 'localhost/netcheck:latest'

expect_ok() {
    if ! "$LINT" --units-dir "$UNITS" >/dev/null; then
        printf 'FAIL: %s should pass image-lint\n' "$1" >&2
        exit 1
    fi
}

expect_fail() {
    if "$LINT" --units-dir "$UNITS" >/dev/null 2>&1; then
        printf 'FAIL: %s should fail image-lint\n' "$1" >&2
        exit 1
    fi
}

expect_ok 'the baseline'

# The two historical bugs: a major-only tag, with and without a variant suffix.
write_unit bad 'docker.io/library/postgres:18-alpine'
expect_fail 'postgres:18-alpine'
write_unit bad 'docker.io/louislam/uptime-kuma:2'
expect_fail 'uptime-kuma:2'
write_unit bad 'docker.io/example/app:latest'
expect_fail 'latest'
rm -f "$UNITS/bad.container"
expect_ok 'a localhost image may use a floating tag'

# A pair that moved apart: the dump must follow the server's minor.
write_unit postgres-dump 'docker.io/library/postgres:18.6-alpine'
expect_fail 'postgres and postgres-dump disagree'
write_unit postgres-dump 'docker.io/library/postgres:18.7-alpine'
expect_ok 'the pair restored'

# The Monero pair differs only by the leading v.
write_unit monero-wallet-btcpay 'docker.io/btcpayserver/monero:v0.18.5.4'
expect_ok 'monero v-prefix normalisation'
write_unit monero-wallet-btcpay 'docker.io/btcpayserver/monero:0.18.4.0'
expect_fail 'monero releases disagree'

printf 'image-lint tests: ok\n'
