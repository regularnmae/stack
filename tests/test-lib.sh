#!/usr/bin/env bash
# Offline regression tests for the shared shell helpers.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=lib.sh
source "$ROOT_DIR/tests/lib.sh"

assert_eq 9000500 "$(dur_ms 2h30m0.5s)" 'fractional duration'
assert_eq 500 "$(dur_ms 500ms)" 'millisecond duration'
assert_eq 5 "$(dur_s 4.5s)" 'duration rounds up'

# A failing probe is still "Up 5 minutes (unhealthy)", and an undecided one is
# "Up 10 seconds (starting)" (podman 5.x) or "(health: starting)" (Docker and
# some builds) -- both start with "Up", so the status must be classified by its
# health suffix. verify.sh fails on `unhealthy` and the monitor carries only its
# FAIL lines, so a regression here is a silent red.
assert_eq unhealthy "$(container_health_state 'Up 5 minutes (unhealthy)')" 'unhealthy probe'
assert_eq starting  "$(container_health_state 'Up 10 seconds (health: starting)')" 'probe not yet decided (Docker-style)'
assert_eq starting  "$(container_health_state 'Up 10 seconds (starting)')" 'probe not yet decided (podman 5.x)'
assert_eq healthy   "$(container_health_state 'Up 3 hours (healthy)')" 'healthy probe'
assert_eq up        "$(container_health_state 'Up 2 hours')" 'no probe defined'
assert_eq down      "$(container_health_state '')" 'not running'
assert_eq other     "$(container_health_state 'Exited (1) 5 minutes ago')" 'exited'
assert_eq '[["method^getinfo","method^listpeers"]]' \
    "$(rune_json getinfo listpeers)" 'rune restriction JSON'

# dur_ms is deploy/root/status.sh's parser, shared with the root tier (the
# bouncer floors it, wait_healthy rounds it up). These fixtures are the table
# that pins it: every row is a misread that happened -- 500ms as 500 minutes,
# "08m" as octal, the digits after the dot taken as the component.
while IFS=$'\t' read -r input want; do
    case "$input" in ''|\#*) continue ;; esac
    [ "$input" = '<empty>' ] && input=''
    assert_eq "$want" "$(dur_ms "$input")" "dur_ms fixture '$input'"
done < "$ROOT_DIR/tests/fixtures/durations.txt"

# dur_ms deliberately answers 0 for junk; callers that must keep a hole as a
# hole (metrics.sh's podman cpu_time "N/A") need the separate whole-string test.
assert_eq yes "$(dur_valid 2h30m0.5s && echo yes || echo no)" 'duration accepted'
assert_eq yes "$(dur_valid 47m45.158824s && echo yes || echo no)" 'podman duration accepted'
assert_eq no  "$(dur_valid N/A && echo yes || echo no)" 'non-duration rejected'
assert_eq no  "$(dur_valid '' && echo yes || echo no)" 'empty value rejected'

# A byte cursor may only advance over complete lines. "a\nb" has two complete
# bytes and a torn tail; the reader must not claim the tail.
printf 'a\nb'   > "$TMP_DIR/torn";   assert_eq 2 "$(complete_line_bytes "$TMP_DIR/torn")" 'partial tail not counted'
printf 'a\nb\n' > "$TMP_DIR/whole";  assert_eq 4 "$(complete_line_bytes "$TMP_DIR/whole")" 'all complete lines counted'
: > "$TMP_DIR/empty";                assert_eq 0 "$(complete_line_bytes "$TMP_DIR/empty")" 'empty file'
printf 'abc'    > "$TMP_DIR/nonl";   assert_eq 0 "$(complete_line_bytes "$TMP_DIR/nonl")" 'no newline means nothing consumed'

# The container name is not the unit stem when a unit sets ContainerName (the
# backup job is stack-backup under backup.service), and metrics/monitor both
# used to assume they were equal.
mkdir -p "$TMP_DIR/units"
printf '[Container]\nContainerName=stack-backup\n' > "$TMP_DIR/units/backup.container"
printf '[Container]\n' > "$TMP_DIR/units/bitcoind.container"
QUADLET_DIR="$TMP_DIR/units"
assert_eq backup    "$(unit_for_container stack-backup)" 'ContainerName maps to its unit'
assert_eq bitcoind  "$(unit_for_container bitcoind)"     'unit stem is the default name'
assert_eq stranger  "$(unit_for_container stranger)"     'unknown name falls back to itself'

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

# The negotiation: the server answers the handshake with the revision it will
# speak, which is not necessarily the one asked for. verify.sh compares that
# answer with MCP_PROTOCOL_VERSION, so the two shapes must both parse.
assert_eq '2025-06-18' \
    "$(mcp_protocol '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"x"}}}')" \
    'mcp_protocol reads a plain handshake'
assert_eq '2024-11-05' \
    "$(mcp_protocol 'event: message
data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"x"}}}')" \
    'mcp_protocol reads an SSE handshake'
assert_eq "" "$(mcp_protocol '{"jsonrpc":"2.0","id":1,"error":{"code":-1}}')" \
    'mcp_protocol prints nothing for an error envelope'

# ... and the requests that follow name it. Stub mcp_curl and record its argv,
# one per line: a header whose quoting broke would appear as two lines.
mcp_curl() { # container curl-args...
    local arg
    printf '<%s>\n' "$@" >> "$TMP_DIR/curl.log"
    for arg in "$@"; do
        case "$arg" in
            *'"method":"initialize"'*)
                printf '%s\n%s%s\n' \
                    '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"fake","version":"0"}}}' \
                    "$MCP_SID_MARKER" 'sess-1'
                return 0 ;;
        esac
    done
}
mcp_initialize fake-mcp token 5 >/dev/null
assert_eq '2024-11-05' "$MCP_NEGOTIATED_VERSION" \
    'initialize records the revision the server agreed to'
assert_eq '2024-11-05' "$(mcp_protocol "$MCP_INIT_RESPONSE")" \
    'initialize keeps the handshake body for the drift check'
assert_eq 'sess-1' "$MCP_SESSION_ID" 'initialize records the session id'
mcp_tool_call fake-mcp token some_tool '{}' 5 >/dev/null
grep -qx '<MCP-Protocol-Version: 2024-11-05>' "$TMP_DIR/curl.log" \
    || { printf 'FAIL: tools/call does not name the negotiated revision\n' >&2; exit 1; }
grep -qx '<mcp-session-id: sess-1>' "$TMP_DIR/curl.log" \
    || { printf 'FAIL: tools/call lost the session id\n' >&2; exit 1; }
grep -q 'notifications/initialized' "$TMP_DIR/curl.log" \
    || { printf 'FAIL: initialize did not send notifications/initialized\n' >&2; exit 1; }

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

# status_verdict is the read side, shared by scripts/monitor.sh and verify.sh.
# The cases that matter are the ones a TAB-joined line could not carry: a skip
# with no ok_epoch yet but a detail, and a failure with no detail at all.
now=$(date +%s)
sv="$TMP_DIR/verdict.status"
printf 'result=ok\nok_epoch=%s\ndetail=fine\n' "$(( now - 100 ))" > "$sv"
status_verdict "$sv"
assert_eq ok "$STATUS_RESULT" 'status_verdict reads the result'
assert_eq fine "$STATUS_DETAIL" 'status_verdict reads the detail'
case "$STATUS_AGE_S" in
    ''|*[!0-9]*) printf 'FAIL: status_verdict age is not a number: %s\n' "$STATUS_AGE_S" >&2; exit 1 ;;
esac
if [ "$STATUS_AGE_S" -lt 100 ] || [ "$STATUS_AGE_S" -ge 130 ]; then
    printf 'FAIL: status_verdict age %s is not ~100s\n' "$STATUS_AGE_S" >&2
    exit 1
fi
printf 'result=skip\nok_epoch=\ndetail=no disk space left\n' > "$sv"
status_verdict "$sv"
assert_eq '' "$STATUS_AGE_S" 'status_verdict leaves the age empty without a success'
assert_eq 'no disk space left' "$STATUS_DETAIL" \
    'status_verdict keeps a detail when the age is empty'
printf 'result=fail\ndetail=\n' > "$sv"
status_verdict "$sv"
assert_eq fail "$STATUS_RESULT" 'status_verdict reads a bare failure'
assert_eq '' "$STATUS_DETAIL" 'status_verdict leaves an empty detail empty'
status_verdict "$TMP_DIR/does-not-exist.status"
assert_eq '||' "$STATUS_RESULT|$STATUS_AGE_S|$STATUS_DETAIL" \
    'status_verdict clears all three for a missing file'

# restic_snapshot_summary: one read of `backup.sh list --json` for the monitor
# and the rotator. A fake repository keeps this offline.
mkdir -p "$TMP_DIR/repo/scripts"
cat > "$TMP_DIR/repo/scripts/backup.sh" <<'SH'
#!/usr/bin/env bash
printf '[{"time":"2026-11-08T00:00:00Z"},{"time":"2026-11-07T00:00:00Z"}]\n'
SH
chmod +x "$TMP_DIR/repo/scripts/backup.sh"
REPO_DIR="$TMP_DIR/repo"
summary=$(restic_snapshot_summary)
assert_eq 2 "${summary%%$'\t'*}" 'restic_snapshot_summary counts the snapshots'
assert_eq "$(date -d 2026-11-08T00:00:00Z +%s)" "${summary#*$'\t'}" \
    'restic_snapshot_summary takes the newest time'
printf 'not json\n' > "$TMP_DIR/repo/scripts/backup.sh"
if restic_snapshot_summary >/dev/null; then
    printf 'FAIL: restic_snapshot_summary accepted a non-array answer\n' >&2
    exit 1
fi

# stackctl_wrapper hands the reconciler its paths, flags and the caller's
# NAME=value overrides in the environment, and nothing more. The overrides are
# the easy part to lose: the parse loop shifts every argument away, so they
# must be collected as they are seen. They were silently dropped for one
# refactor, and the core has a loopback default, so nothing failed.
mkdir -p "$TMP_DIR/ctl/bin" "$TMP_DIR/ctl/deploy"
cat > "$TMP_DIR/ctl/bin/python3" <<'SH'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*"
printf 'MANIFEST=%s\n' "${MANIFEST:-}"
printf 'DRY_RUN=%s\n' "${DRY_RUN:-}"
printf 'PRUNE=%s\n' "${PRUNE:-}"
printf 'NPM_API=%s\n' "${NPM_API:-}"
SH
chmod +x "$TMP_DIR/ctl/bin/python3"
: > "$TMP_DIR/ctl/deploy/services.toml"
got=$(
    PATH="$TMP_DIR/ctl/bin:$PATH" \
    REPO_DIR="$TMP_DIR/ctl" STACK_DATA_DIR="$TMP_DIR" \
    STACK_DATA_ENV="$TMP_DIR/data-dir.env" \
        stackctl_wrapper npm-hosts "NPM_API=http://example.invalid:81" --dry-run
    printf 'LEAK=%s|%s|%s\n' "${MANIFEST:-unset}" "${DRY_RUN:-unset}" "${NPM_API:-unset}"
)
assert_eq "argv=-m stackctl npm-hosts
MANIFEST=$TMP_DIR/ctl/deploy/services.toml
DRY_RUN=1
PRUNE=0
NPM_API=http://example.invalid:81
LEAK=unset|unset|unset" "$got" 'stackctl_wrapper passes paths, flags and overrides only'

# write_atomic is the primitive behind prom_write and status_write: stdin -> a
# hidden temp beside the target, the mode, then a rename. The rename is the
# point -- a reader sees the old file or the new one.
printf 'hello\n' | write_atomic "$TMP_DIR/atomic.txt" 600
assert_eq hello "$(cat "$TMP_DIR/atomic.txt")" 'write_atomic writes stdin'
assert_eq 600 "$(stat -c %a "$TMP_DIR/atomic.txt")" 'write_atomic sets the mode'
mkdir -p "$TMP_DIR/atdir"
chmod 700 "$TMP_DIR/atdir"
printf 'x\n' | write_atomic "$TMP_DIR/atdir/f" 644 755
assert_eq 755 "$(stat -c %a "$TMP_DIR/atdir")" 'write_atomic sets the directory mode'
assert_eq 644 "$(stat -c %a "$TMP_DIR/atdir/f")" 'write_atomic sets the file mode'
assert_eq 0 "$(find "$TMP_DIR" -name '.atomic.txt.*' | wc -l)" \
    'write_atomic leaves no temp file behind'
# A failed write must not replace what is already there. Root ignores the
# directory mode, so this is only meaningful as an unprivileged user (CI is).
if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$TMP_DIR/rodir"
    printf 'old\n' > "$TMP_DIR/rodir/f"
    chmod 500 "$TMP_DIR/rodir"
    if printf 'new\n' | write_atomic "$TMP_DIR/rodir/f" 644 2>/dev/null; then
        printf 'FAIL: write_atomic succeeded in a read-only directory\n' >&2
        exit 1
    fi
    chmod 700 "$TMP_DIR/rodir"
    assert_eq old "$(cat "$TMP_DIR/rodir/f")" 'write_atomic keeps the old file on failure'
fi

# Podman renders a size as go-units does ("4.176GB", "512B") or, on a change,
# binary ("2GiB"); numfmt reads both once the trailing B is gone.
assert_eq 500000000 "$(human_bytes 500MB)" 'human_bytes parses an SI size'
assert_eq 512 "$(human_bytes 512B)" 'human_bytes parses a bare byte count'
assert_eq 0 "$(human_bytes 0B)" 'human_bytes parses zero'
assert_eq 2147483648 "$(human_bytes 2GiB)" 'human_bytes parses an IEC size'
assert_eq "" "$(human_bytes nonsense)" 'human_bytes refuses garbage'

# One substitution list for the root tier, shared by install.sh and verify.sh.
printf '@DATA_DIR@|@CONFIG_DIR@|@REPO_DIR@|@IDS_RETENTION_DAYS@\n' > "$TMP_DIR/root.tmpl"
assert_eq '/d&|y|/d&|y/config|/r&|x|14' \
    "$(REPO_DIR='/r&|x' IDS_RETENTION_DAYS=14 render_root_template "$TMP_DIR/root.tmpl" '/d&|y')" \
    'render_root_template escapes sed metacharacters'

mkdir -p "$TMP_DIR/quadlet" "$TMP_DIR/data"
printf '[Container]\nImage=one\n\n[Service]\nRestart=always\n\n[Install]\nWantedBy=default.target\n' \
    > "$TMP_DIR/quadlet/a.container"
printf '[Container]\nImage=two\n' > "$TMP_DIR/quadlet/b.container"
printf '[Container]\nContainerName=stack-backup\n' > "$TMP_DIR/quadlet/c.container"
export QUADLET_DIR="$TMP_DIR/quadlet" DATA_DIR="$TMP_DIR/data"
before=$(unit_digest)
printf '[Container]\nImage=changed\n' > "$TMP_DIR/quadlet/b.container"
assert_eq b "$(unit_digest_changed "$before" "$(unit_digest)")" 'unit digest identifies changed unit'

# The generation stamp is how a running container reports the definition it was
# created from: install.sh writes it, podman reads it back, and it is never part
# of the digest it carries -- a re-stamp must not look like a changed unit.
unstamped=$(unit_digest)
unit_stamp_generations "$QUADLET_DIR"
assert_eq "$unstamped" "$(unit_digest)" 'stamping a unit does not change its digest'
assert_eq 600 "$(stat -c %a "$TMP_DIR/quadlet/a.container")" \
    'a stamped unit keeps mode 600'
# Quadlet reads a key in the wrong section as absent, and [Install] is the last
# section of most units -- a stamp appended at EOF would never reach a container.
assert_eq '[Container]' \
    "$(awk -v p="$UNIT_STAMP_LINE" '/^\[/ { s = $0 } index($0, p) == 1 { print s }' \
        "$TMP_DIR/quadlet/a.container")" \
    'the stamp lands inside [Container]'
cp "$TMP_DIR/quadlet/a.container" "$TMP_DIR/a.snapshot"
unit_stamp_generations "$QUADLET_DIR"
assert_eq "$(cat "$TMP_DIR/a.snapshot")" "$(cat "$TMP_DIR/quadlet/a.container")" \
    're-stamping an unchanged unit is a no-op'
assert_eq b "$(unit_digest_changed "$before" "$(unit_digest)")" \
    'a stamp alone is not a changed unit'

# The applied side is the label on the running container, not a file. A container
# created before the stamps existed has none: it is recorded as unstamped so the
# next deploy recreates it instead of adopting a definition nobody can identify.
mkdir -p "$TMP_DIR/bin"
stamp_a=$(unit_stamp_value "$TMP_DIR/quadlet/a.container")
cat > "$TMP_DIR/bin/podman" <<EOF
#!/bin/sh
printf 'a $stamp_a\n'
printf 'stack-backup \n'
EOF
chmod +x "$TMP_DIR/bin/podman"
assert_eq "$stamp_a  a.container
unstamped  c.container" \
    "$(PATH="$TMP_DIR/bin:$PATH" unit_digest_applied)" \
    'unit_digest_applied reads the stamp and calls an unstamped container drift'

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

# "alerting is inert" keys on the receiver the default route sends to, not on
# any email_configs in the file. A signups-only setup delivers no pages, so it
# must still report itself -- that is the regression the file-wide grep had.
alertmanager_paging "$ROOT_DIR/deploy/examples/monitoring/alertmanager.yml.example"
assert_eq stack-email "$AM_RECEIVER" 'the example names its paging receiver'
assert_eq 0 "$AM_PAGING" 'the seeded example delivers nothing, so it is inert'

cat > "$TMP_DIR/am-paging.yml" <<'YAML'
route:
  receiver: stack-email
receivers:
  - name: stack-email
    email_configs:
      - to: ops@example.com
  - name: stack-signups
YAML
alertmanager_paging "$TMP_DIR/am-paging.yml"
assert_eq 1 "$AM_PAGING" 'an uncommented email_configs on the default receiver pages'

cat > "$TMP_DIR/am-signups.yml" <<'YAML'
route:
  receiver: stack-email
  routes:
    - receiver: stack-signups
      matchers:
        - severity = "info"
receivers:
  - name: stack-email
    # email_configs:
    #   - to: ops@example.com
  - name: stack-signups
    email_configs:
      - to: events@example.com
YAML
alertmanager_paging "$TMP_DIR/am-signups.yml"
assert_eq stack-email "$AM_RECEIVER" 'a sub-route does not replace the default receiver'
assert_eq 0 "$AM_PAGING" 'signups-only email_configs must not silence the inert warning'

cat > "$TMP_DIR/am-noroute.yml" <<'YAML'
receivers:
  - name: stack-email
    email_configs:
      - to: ops@example.com
YAML
alertmanager_paging "$TMP_DIR/am-noroute.yml"
assert_eq "" "$AM_RECEIVER" 'no [route] receiver means there is no paging path to judge'
assert_eq 0 "$AM_PAGING" 'a config with no default route stays inert'

# A script's leading comment block IS its --help: usage_header prints it
# verbatim, so a header that is not one contiguous block from line 2 gives a
# truncated usage message, and healthcheck-lint used to hard-code a line range
# that did exactly that. Compare the two for every script that has a --help.
for script in "$ROOT_DIR"/deploy.sh "$ROOT_DIR"/verify.sh "$ROOT_DIR"/configure.sh \
              "$ROOT_DIR"/scripts/*.sh; do
    grep -q usage_header "$script" || continue
    case "$script" in */scripts/lib.sh) continue ;; esac
    want=$(awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$script")
    [ -n "$want" ] || continue
    # Run it with no data dir recorded. A host that runs these tests has one,
    # which hid a real failure until CI: resolve_data_dir stops when nothing is
    # recorded, so a script that resolves it before its argument loop answered
    # --help with nothing here and with the header there.
    got=$(cd "$ROOT_DIR" && env -u STACK_DATA_DIR -u STACK_DATA_ENV -u XDG_CONFIG_HOME \
        HOME="$TMP_DIR/no-data-dir" "$script" --help 2>/dev/null) || true
    # Prefix, not equality: some scripts append an options table after the block.
    if [ "${got:0:${#want}}" != "$want" ]; then
        printf 'FAIL: %s --help does not start with its leading comment block\n' "$script" >&2
        exit 1
    fi
done

# node-exporter rejects the WHOLE textfile over one malformed label, so a daemon
# message's quote, backslash or newline must never reach it raw.
assert_eq 'a\"b\\c' "$(prom_label_value 'a"b\c')" 'label values escape quotes and backslashes'
assert_eq 'one two' "$(prom_label_value "$(printf 'one\ntwo')")" 'a newline becomes a separator'
assert_eq 'a b'     "$(prom_label_value "$(printf 'a\tb')")"     'a tab becomes a separator'
assert_eq 'plain'   "$(prom_label_value plain)"                  'plain text is untouched'

printf 'shared shell helper tests: ok\n'
