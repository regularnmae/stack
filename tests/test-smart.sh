#!/usr/bin/env bash
# Offline regression tests for the SMART JSON parser in deploy/root/smart.sh.
#
# The probe itself needs root and a real disk, but the field extraction is pure
# jq. This extracts smart_fields from the template (read-only; nothing here
# needs root) and pins the ATA and NVMe shapes the monitor reads: overall health,
# reallocated/pending sectors, temperature and the NVMe media-error counter.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMART="$ROOT_DIR/deploy/root/smart.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

command -v jq >/dev/null 2>&1 \
    || { printf 'FAIL: jq is required to test the SMART parser\n' >&2; exit 1; }

# Pull the function out by its definition line, up to the closing brace in
# column 0. Sourcing the whole script would read smart.env and probe devices.
extract() { # name src -> the function on stdout
    local name="$1"
    sed -n "/^${name}()/,/^}/p" "$2"
}

extract smart_fields "$SMART" > "$TMP_DIR/smart_fields.sh"
[ -s "$TMP_DIR/smart_fields.sh" ] \
    || { printf 'FAIL: smart_fields not found in %s\n' "$SMART" >&2; exit 1; }
# shellcheck source=/dev/null
. "$TMP_DIR/smart_fields.sh"

field() { # KEY=VALUE text key
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

ata=$(smart_fields "$ROOT_DIR/tests/fixtures/smart-ata.json")
assert_eq PASSED "$(field "$ata" health)" 'ATA health maps to PASSED'
assert_eq ATA "$(field "$ata" protocol)" 'ATA protocol is recorded'
assert_eq 8 "$(field "$ata" realloc)" 'attribute 5 is the reallocated count'
assert_eq 2 "$(field "$ata" pending)" 'attribute 197 is the pending count'
assert_eq 34 "$(field "$ata" temp)" 'decoded temperature wins'
assert_eq 7200 "$(field "$ata" rotation)" 'rotation_rate distinguishes an HDD'

failed=$(smart_fields "$ROOT_DIR/tests/fixtures/smart-ata-failed.json")
assert_eq FAILED "$(field "$failed" health)" 'ATA health maps to FAILED'
assert_eq 12 "$(field "$failed" realloc)" 'a failing drive keeps its counts'
assert_eq 4 "$(field "$failed" pending)" 'a failing drive keeps its pending count'
assert_eq 61 "$(field "$failed" temp)" 'a hot drive keeps its temperature'

scsi=$(smart_fields "$ROOT_DIR/tests/fixtures/smart-scsi.json")
assert_eq PASSED "$(field "$scsi" health)" 'SCSI health maps to PASSED'
assert_eq SCSI "$(field "$scsi" protocol)" 'SCSI protocol is recorded'
assert_eq 'SEAGATE ST3000NM0023' "$(field "$scsi" model)" \
    'SCSI model falls back to scsi_model_name'
assert_eq 5 "$(field "$scsi" realloc)" 'grown defect list is the SCSI realloc count'
assert_eq 2 "$(field "$scsi" pending)" 'SCSI pending defects map to pending'
assert_eq 3 "$(field "$scsi" uncorrected)" \
    'SCSI uncorrected errors sum read, write and verify'
assert_eq 37 "$(field "$scsi" temp)" 'SCSI temperature is decoded'

nvme=$(smart_fields "$ROOT_DIR/tests/fixtures/smart-nvme.json")
assert_eq PASSED "$(field "$nvme" health)" 'NVMe health maps to PASSED'
assert_eq NVMe "$(field "$nvme" protocol)" 'NVMe protocol is recorded'
assert_eq 37 "$(field "$nvme" temp)" 'NVMe temperature comes from its own log'
assert_eq 0 "$(field "$nvme" media_errors)" 'NVMe media errors are recorded'
# NVMe has no ATA attribute table; empty is not zero.
assert_eq '' "$(field "$nvme" realloc)" 'NVMe has no ATA reallocated count'
assert_eq '' "$(field "$nvme" pending)" 'NVMe has no ATA pending count'

printf 'SMART parser tests passed\n'
