# shellcheck shell=bash
# The one protocol with a client of its own: Fulcrum's Electrum JSON-RPC over
# /dev/tcp and openssl (docs/chains.md).

# --- the Electrum protocol (Fulcrum) ----------------------------------------
# Newline-delimited JSON-RPC over raw TCP, not HTTP: 50001 plaintext and 50002
# TLS with a self-signed certificate. Neither net_curl nor nginx-proxy-manager
# can speak it, so it is the stack's one protocol with a client of its own:
# bash's /dev/tcp, because no `nc` is installed and `read -t` is the whole
# timeout. The call runs in a subshell -- a failed `exec` redirection can end a
# non-interactive shell, and a refused port must cost an empty string, never the
# sweep. TLS goes through openssl, already a bootstrap dependency.
#
# Callers dial 127.0.0.1: fulcrum publishes 50001/50002 on every interface, so
# the host's loopback is exactly what a LAN wallet reaches. Dialling the
# container name would prove less (it stays up if the publish is lost).
electrum_call() { # host port request-line -> the server's reply, empty on failure
    bash -c '
        exec 3<>"/dev/tcp/$1/$2" || exit 0
        printf "%s\n" "$3" >&3
        IFS= read -r -t 5 reply <&3
        printf "%s" "$reply"
    ' _ "$1" "$2" "$3" 2>/dev/null
}

# The same over TLS. -quiet drops the handshake chatter; stdin has to stay open a
# moment after the request, or s_client closes before the answer arrives.
electrum_call_tls() { # host port request-line -> the server's reply, empty on failure
    { printf '%s\n' "$3"; sleep 2; } \
        | timeout 10 openssl s_client -quiet -connect "$1:$2" 2>/dev/null \
        | head -n1
}

# The tip height Fulcrum reports, or empty when it does not answer.
# `server.version` is answered from memory and stays green on exactly the failure
# this exists to catch: an index that has wedged while the process, the port and
# the healthcheck all still look fine. Callers compare it with bitcoind's
# `blocks`; Fulcrum polls every 5s (--polltime), so the gap is 0-1 block.
#
# Empty is expected during initial block download, so verify.sh warns and
# monitor.sh softens it under MONITOR_GRACE_SYNC.
electrum_tip() { # port [tls] -> height, empty on failure
    local port="$1" tls="${2:-}" reply
    local req='{"id":1,"method":"blockchain.headers.subscribe","params":[]}'
    if [ "$tls" = tls ]; then
        reply=$(electrum_call_tls 127.0.0.1 "$port" "$req")
    else
        reply=$(electrum_call 127.0.0.1 "$port" "$req")
    fi
    printf '%s' "$reply" | jq -r '.result.height // empty' 2>/dev/null || true
}
