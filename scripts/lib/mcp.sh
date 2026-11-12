# shellcheck shell=bash
# The hand-rolled MCP client every host-side check uses: transport, handshake,
# one tool call, and the envelope reader (docs/clients.md).

# What the last mcp_initialize saw: the session id, the revision the server
# actually agreed to, the handshake body (kept because capturing the function's
# stdout would run it in a subshell and lose these globals), and the marker -w
# uses to put the session id after the body rather than mixed into it.
MCP_SESSION_ID=""
MCP_NEGOTIATED_VERSION=""
MCP_INIT_RESPONSE=""
MCP_SID_MARKER='__mcp_session_id__'

# MCP servers not on npm-network, as "<container>:<port>". One entry: crowdsec-mcp
# runs with Network=host, because its upstream (the CrowdSec LAPI) is a loopback
# bind a bridge cannot reach -- pasta's host.containers.internal lands on the
# LAN address, not loopback. Such a unit binds the host's loopback itself instead
# of publishing, so it is reached as 127.0.0.1:<port> through netcheck-host.
# Declared once so every caller names the container and gets the transport right.
MCP_HOST_NETNS=("crowdsec-mcp:8113")

# "<curl function> <address>" for a container's MCP endpoint.
_mcp_transport() { # container
    local entry
    for entry in "${MCP_HOST_NETNS[@]}"; do
        if [ "${entry%%:*}" = "$1" ]; then
            printf 'net_curl_host 127.0.0.1:%s' "${entry##*:}"
            return 0
        fi
    done
    printf 'net_curl %s:8000' "$1"
}

# The container's MCP base URL, for callers that build their own paths
# (verify.sh's /health and its 401 gate).
mcp_base() { # container
    local transport
    transport=$(_mcp_transport "$1")
    printf 'http://%s' "${transport#* }"
}

# curl against the container's MCP endpoint, from the network namespace that can
# reach it. Arguments are curl's, verbatim.
mcp_curl() { # container curl-args...
    local transport
    transport=$(_mcp_transport "$1")
    shift
    "${transport%% *}" "$@"
}

# The handshake every MCP streamable-HTTP session starts with. The version is
# the protocol revision, not this stack's: what agent-mcp sends and what the
# servers implement (agent-skills' lib/mcp_http.py PROTOCOL_VERSION). Named once
# because this hand-rolled client and the real one disagree about it silently
# when a revision lands -- a bump is this line plus agent-skills', and
# tests/test-lib.sh asserts the body carries it.
#
# It is a request, not an agreement: the server may answer with an older
# revision, and that answer is what every later request must name
# (MCP_NEGOTIATED_VERSION). verify.sh compares the two and warns when a server
# has moved, which is the only way a bump here is noticed.
MCP_PROTOCOL_VERSION='2025-06-18'
MCP_INIT_BODY="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$MCP_PROTOCOL_VERSION\",\"capabilities\":{},\"clientInfo\":{\"name\":\"monitor\",\"version\":\"0\"}}}"

# The notification the lifecycle requires after a successful initialize. No id,
# 202 with no body, so nothing useful comes back: fire-and-forget by design (a
# failed notification must not fail a probe that has a working session).
#   mcp_initialized CONTAINER TOKEN [timeout]
mcp_initialized() {
    printf 'header = "Authorization: Bearer %s"\n' "$2" | \
        mcp_curl "$1" -s -o /dev/null -m "${3:-20}" -K - \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            ${MCP_SESSION_ID:+-H "mcp-session-id: $MCP_SESSION_ID"} \
            -H "MCP-Protocol-Version: ${MCP_NEGOTIATED_VERSION:-$MCP_PROTOCOL_VERSION}" \
            -X POST "$(mcp_base "$1")/mcp" \
            -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
            2>/dev/null || true
}

# Authenticate against CONTAINER's MCP endpoint: initialize, print the response
# body, record the session id and the revision the server agreed to. Returns 1
# when the server did not answer with a serverInfo result. The bearer token goes
# in a curl config on stdin, so it never reaches the host's argv.
#   mcp_initialize CONTAINER TOKEN [timeout]
mcp_initialize() {
    local c="$1" token="$2" t="${3:-20}" resp
    MCP_SESSION_ID=""
    MCP_NEGOTIATED_VERSION=""
    MCP_INIT_RESPONSE=""
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | \
        mcp_curl "$c" -s -m "$t" -K - \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            -w "\n$MCP_SID_MARKER%header{mcp-session-id}" \
            -X POST "$(mcp_base "$c")/mcp" -d "$MCP_INIT_BODY" 2>/dev/null) || return 1
    case "$resp" in *"$MCP_SID_MARKER"*) ;; *) return 1 ;; esac
    MCP_SESSION_ID="${resp##*"$MCP_SID_MARKER"}"
    resp="${resp%%"$MCP_SID_MARKER"*}"
    printf '%s' "$resp" | grep -q '"serverInfo"' || return 1
    # The answer names the revision the session will speak. A server that does
    # not answer with one is assumed to have accepted ours.
    MCP_NEGOTIATED_VERSION=$(mcp_protocol "$resp")
    [ -n "$MCP_NEGOTIATED_VERSION" ] || MCP_NEGOTIATED_VERSION="$MCP_PROTOCOL_VERSION"
    mcp_initialized "$c" "$token" "$t"
    # verify.sh reads this for the drift check; nothing in this file does.
    # shellcheck disable=SC2034
    MCP_INIT_RESPONSE="$resp"
    printf '%s\n' "$resp"
}

# Call one tool once the handshake above has run (mcp_call does both). Prints the
# response body; read-only from the server's point of view.
#   mcp_tool_call CONTAINER TOKEN TOOL ARGS_JSON [timeout]
mcp_tool_call() {
    local c="$1" token="$2" tool="$3" args="$4" t="${5:-20}" call
    call=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$tool" "$args")
    printf 'header = "Authorization: Bearer %s"\n' "$token" | \
        mcp_curl "$c" -s -m "$t" -K - \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            ${MCP_SESSION_ID:+-H "mcp-session-id: $MCP_SESSION_ID"} \
            -H "MCP-Protocol-Version: ${MCP_NEGOTIATED_VERSION:-$MCP_PROTOCOL_VERSION}" \
            -X POST "$(mcp_base "$c")/mcp" -d "$call" 2>/dev/null
}

# Call one tool on an MCP streamable-HTTP endpoint and print the response body.
# Nothing (and 1) when the handshake fails. verify.sh calls the two halves itself
# because it also proves the 401 gate and reports the session id.
#   mcp_call CONTAINER TOKEN TOOL ARGS_JSON [timeout]
mcp_call() {
    local c="$1" token="$2" tool="$3" args="$4" t="${5:-20}"
    mcp_initialize "$c" "$token" "$t" >/dev/null || return 1
    mcp_tool_call "$c" "$token" "$tool" "$args" "$t"
}

# The last JSON-RPC envelope in a response body: the body when it is plain JSON,
# or the last `data:` line of an SSE stream, since progress notifications and
# pings may surround the result. Nothing when the body carries no envelope.
mcp_envelope() { # response-body -> the last result/error envelope
    local body="$1"
    case "$body" in
        'data: '*|*$'\ndata: '*)
            printf '%s\n' "$body" | sed -n 's/^data: //p' \
                | jq -R -c 'fromjson? | select(type == "object" and (has("result") or has("error")))' 2>/dev/null \
                | tail -n1 ;;
        *) printf '%s' "$body" ;;
    esac
}

# The protocol revision the server answered the handshake with. Empty when the
# body is not a handshake (an error, or a transport that said nothing useful),
# which mcp_initialize reads as "it accepted the one we sent".
mcp_protocol() { # response-body -> negotiated protocolVersion
    local doc
    doc=$(mcp_envelope "$1")
    [ -n "$doc" ] || return 0
    printf '%s' "$doc" | jq -r '.result.protocolVersion // empty' 2>/dev/null || true
}

# Unpack the text document a tools/call returned. mcp_call prints the HTTP body
# verbatim -- a plain JSON-RPC envelope, or an SSE stream -- and the tool's own
# result is a JSON *string* at .result.content[0].text (MCP's text content).
# Nothing when the call failed or the body is not what the transport promises, so
# callers keep their "empty means unavailable" branches.
mcp_result_raw() { # response-body -> the tool's text content
    local doc
    doc=$(mcp_envelope "$1")
    [ -n "$doc" ] || return 0
    printf '%s' "$doc" | jq -r '.result.content[0].text // empty' 2>/dev/null || true
}

# The same, but only when the text is a JSON document -- what a caller running
# its own jq filter wants. Some servers answer an RPC error as plain text ("No
# wallet file (RPC error -13)"), and feeding that to jq is noise, not data.
# mcp_result_raw is for callers that only ask "did the tool answer?" (a token
# proof, verify's deep call), where searxng's get_time returns prose.
mcp_result() { # response-body -> the tool's text, when it is JSON
    local text
    text=$(mcp_result_raw "$1") || return 0
    [ -n "$text" ] || return 0
    printf '%s' "$text" | jq -e . >/dev/null 2>&1 || return 0
    printf '%s' "$text"
}
