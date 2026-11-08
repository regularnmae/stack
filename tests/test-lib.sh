#!/usr/bin/env bash
# Offline regression tests for the shared shell helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

assert_eq() {
    local want="$1" got="$2" label="$3"
    if [ "$want" != "$got" ]; then
        printf 'FAIL: %s: expected %s, got %s\n' "$label" "$want" "$got" >&2
        exit 1
    fi
}

assert_eq 9000500 "$(dur_ms 2h30m0.5s)" 'fractional duration'
assert_eq 500 "$(dur_ms 500ms)" 'millisecond duration'
assert_eq 5 "$(dur_s 4.5s)" 'duration rounds up'
assert_eq '[["method^getinfo","method^listpeers"]]' \
    "$(rune_json getinfo listpeers)" 'rune restriction JSON'

# The Go-duration parser has a second implementation in deploy/root/bouncer.sh
# (dur_to_sec); both are tested against the SAME fixture file, so a fix on one
# side that forgets the other fails here rather than silently splitting
# wait_healthy and enforcement.
while IFS=$'\t' read -r input want; do
    case "$input" in ''|\#*) continue ;; esac
    [ "$input" = '<empty>' ] && input=''
    assert_eq "$want" "$(dur_ms "$input")" "dur_ms fixture '$input'"
done < "$ROOT_DIR/tests/fixtures/durations.txt"

# mcp_result unwraps the two shapes mcp_call can print: a plain JSON-RPC body,
# and the streamable-HTTP transport's SSE stream. The tool's payload is a JSON
# string at .result.content[0].text, so the caller's jq filter runs on JSON.
sse='event: message
data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"height\":42,\"synchronized\":false}"}]}}'
assert_eq 42 "$(mcp_result "$sse" | jq -r '.height')" 'mcp_result unpacks SSE'
assert_eq false "$(mcp_result "$sse" | jq -r '.synchronized')" 'mcp_result keeps false'
plain='{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"ok\":true}"}]}}'
assert_eq true "$(mcp_result "$plain" | jq -r '.ok')" 'mcp_result unpacks plain JSON'
assert_eq "" "$(mcp_result '{"jsonrpc":"2.0","id":2,"error":{"code":-1}}')" \
    'mcp_result prints nothing for an error envelope'
assert_eq "" "$(mcp_result 'event: message
data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"text":"No wallet file (RPC error -13)","type":"text"}]}}')" \
    'mcp_result prints nothing for non-JSON tool text'
assert_eq 'ISO-8601: 2026-11-08T00:00:00+00:00' "$(mcp_result_raw 'event: message
data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"text":"ISO-8601: 2026-11-08T00:00:00+00:00","type":"text"}]}}')" \
    'mcp_result_raw keeps non-JSON tool text (a token probe only needs an answer)'
assert_eq "" "$(mcp_result 'event: message
data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"text":"ISO-8601: 2026-11-08T00:00:00+00:00","type":"text"}]}}')" \
    'mcp_result rejects non-JSON tool text'

# The handshake body is built from MCP_PROTOCOL_VERSION, so the revision is one
# named fact instead of a literal a sed can miss. The body must stay valid JSON
# and carry that exact version -- the servers refuse an unknown revision, and
# this client exists only because the probes may not go through agent-mcp.
assert_eq "$MCP_PROTOCOL_VERSION" \
    "$(printf '%s' "$MCP_INIT_BODY" | jq -r '.params.protocolVersion')" \
    'MCP_INIT_BODY carries MCP_PROTOCOL_VERSION'
assert_eq '"initialize"' \
    "$(printf '%s' "$MCP_INIT_BODY" | jq -c '.method')" \
    'MCP_INIT_BODY is the initialize method'

# The status-file contract: ok_epoch moves only on success and is carried
# through a failure, which is what the monitor's age checks key on.
status="$TMP_DIR/ids.status"
status_write "$status" '# test' ok 'all good' 'alerts=3'
assert_eq ok "$(env_value "$status" result)" 'status_write records the result'
assert_eq 'all good' "$(env_value "$status" detail)" 'status_write records the detail'
assert_eq 3 "$(env_value "$status" alerts)" 'status_write records the caller fields'
first_ok=$(env_value "$status" ok_epoch)
status_write "$status" '# test' fail 'broken' 'alerts=4'
assert_eq fail "$(env_value "$status" result)" 'status_write records a failure'
assert_eq "$first_ok" "$(env_value "$status" ok_epoch)" \
    'status_write carries ok_epoch through a failure'

# One substitution list for the root tier, shared by install.sh and verify.sh.
printf '@DATA_DIR@|@CONFIG_DIR@|@REPO_DIR@|@IDS_RETENTION_DAYS@\n' > "$TMP_DIR/root.tmpl"
assert_eq '/d&|y|/d&|y/config|/r&|x|14' \
    "$(REPO_DIR='/r&|x' IDS_RETENTION_DAYS=14 render_root_template "$TMP_DIR/root.tmpl" '/d&|y')" \
    'render_root_template escapes sed metacharacters'

mkdir -p "$TMP_DIR/quadlet" "$TMP_DIR/data"
printf 'one\n' > "$TMP_DIR/quadlet/a.container"
printf 'two\n' > "$TMP_DIR/quadlet/b.container"
export QUADLET_DIR="$TMP_DIR/quadlet" DATA_DIR="$TMP_DIR/data"
before=$(unit_digest)
printf 'changed\n' > "$TMP_DIR/quadlet/b.container"
assert_eq b "$(unit_digest_changed "$before" "$(unit_digest)")" 'unit digest identifies changed unit'

# The space-delimited unit sets deploy.sh passes around: an exact stem, never a
# substring (tor must not match tor-control), and the empty set matches nothing.
if ! unit_in_set tor " bitcoind tor "; then
    printf 'FAIL: unit_in_set exact stem\n' >&2
    exit 1
fi
if unit_in_set tor " tor-control "; then
    printf 'FAIL: unit_in_set matched a substring\n' >&2
    exit 1
fi
if unit_in_set "" " tor "; then
    printf 'FAIL: unit_in_set matched an empty unit\n' >&2
    exit 1
fi
assert_eq 0 "$(wait_healthy_many 1; echo $?)" 'wait_healthy_many with no containers'

printf 'shared shell helper tests: ok\n'
