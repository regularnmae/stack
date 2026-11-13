# shellcheck shell=bash
# Asking each daemon through its own client, and the CLN rune set install.sh
# and rotate.sh mint and prune together (docs/credentials.md, docs/chains.md).

# A CLN rune restriction: one alternatives group naming method prefixes, in the
# JSON shape `createrune` wants. Declared once in stack.conf so install.sh and
# rotate.sh mint the SAME runes -- a rotator granting more, or less, would be a
# security bug.
rune_json() { # prefix...
    local out="" p
    for p in "$@"; do
        out+="${out:+,}\"method^$p\""
    done
    printf '[[%s]]' "$out"
}

# --- the live rune set ------------------------------------------------------
# A rune carries no label (this CLN's `createrune` takes no comment), so its
# only identity is its method set. These compare the live set with the prefixes
# stack.conf declares, which makes "a rune this stack minted" reproducible
# instead of a remembered id. rotate.sh blacklists the leftovers and monitor.sh
# pages on them, both through here, so the pruner and the alarm agree.
cln_live_runes() { # -> unique_id<TAB>rune<TAB>methodset, per non-blacklisted rune
    local out
    out=$(lightning_cli showrunes 2>/dev/null) || return 1
    printf '%s' "$out" | jq -r '
        .runes[]
        | select(.blacklisted|not)
        | [ (.unique_id|tostring), .rune,
            ([.restrictions[].alternatives[]
              | select(.fieldname == "method")
              | .value | sub("\\$"; "")]
             | sort | join(",")) ]
        | @tsv' 2>/dev/null
}

cln_method_set() { # method... -> comma-joined, sorted (the comparison form)
    printf '%s\n' "$@" | sort | paste -sd, -
}

# Live runes whose method set is EXACTLY one of stack.conf's and that are not
# among the runes passed as arguments: the leftovers rotate.sh blacklists and
# monitor.sh pages on. An exact match is deliberate -- a rune minted for
# something else keeps its methods and must never be touched. Empty output with
# exit 0 is the clean case; non-zero means the node could not be read, which is
# not "nothing to do".
cln_orphan_runes() { # keep-rune...
    local keep live id rune methods rset sset
    if [ "${CLN_READ_METHODS+x}" != x ] || [ "${#CLN_READ_METHODS[@]}" -eq 0 ]; then
        return 0
    fi
    rset=$(cln_method_set "${CLN_READ_METHODS[@]}")
    sset=$(cln_method_set "${CLN_READ_METHODS[@]}" "${CLN_SPEND_METHODS[@]}")
    keep=$(printf '%s\n' "$@")
    live=$(cln_live_runes) || return 1
    [ -n "$live" ] || return 0
    while IFS=$'\t' read -r id rune methods; do
        [ -n "$id" ] || continue
        if printf '%s\n' "$keep" | grep -qxF -- "$rune"; then
            continue
        fi
        if [ "$methods" = "$rset" ] || [ "$methods" = "$sset" ]; then
            printf '%s\t%s\n' "$id" "$methods"
        fi
    done <<< "$live"
}

# Prove a rune is accepted by the node (checkrune exits non-zero for a rune the
# node refuses or has blacklisted). Shared by the installer and the rotator so
# both judge usability the same way.
cln_rune_usable() { # rune
    [ -n "$1" ] || return 1
    lightning_cli -k checkrune rune="$1" method=getinfo >/dev/null 2>&1
}

# Mint one rune and prove it before handing it back: createrune can return a
# unique_id the node has already blacklisted, so only mint -> checkrune -> retry
# is safe. Prints "<rune> <unique_id>" (the shape rotate.sh reads), or nothing
# after 12 failures -- never an unproven rune, which would leave lightning-mcp
# unable to read the node.
cln_mint_rune() { # restriction-json -> "rune unique_id"
    local restrictions="$1" out rune id tries
    command -v jq >/dev/null 2>&1 \
        || { warn "cln_mint_rune needs jq (bootstrap.sh installs it)"; return 1; }
    for ((tries = 1; tries <= 12; tries++)); do
        out=$(lightning_cli createrune null "$restrictions" 2>/dev/null || true)
        rune=$(printf '%s' "$out" | jq -r '.rune // empty' 2>/dev/null) || rune=""
        id=$(printf '%s' "$out" | jq -r '.unique_id // empty' 2>/dev/null) || id=""
        [ -n "$rune" ] && [ -n "$id" ] || return 1
        if cln_rune_usable "$rune"; then
            printf '%s %s' "$rune" "$id"
            return 0
        fi
        warn "new rune id $id was refused (already blacklisted?); retrying"
    done
    return 1
}

# One KEY from the bitcoind config inside the RUNNING container (empty when the
# container or the file cannot be read). The key is a literal from stack.conf or
# this repo, never user input. Reading the installed file, not the host copy, is
# what makes a half-applied rotation visible: this is what the daemon loaded.
bitcoind_conf_value() { # key
    podman exec bitcoind sh -c "sed -n 's/^$1=//p' /data/.bitcoin/bitcoin.conf" 2>/dev/null \
        | head -n1 || true
}

# The RPC password bitcoind's own bitcoin.conf carries, compared with secrets.env
# by rotate.sh --status and monitor.sh: a half-applied rotation pulls the two
# copies apart and nothing else would notice before the next restart.
bitcoind_conf_password() {
    bitcoind_conf_value rpcpassword
}

# --- asking a daemon through its own client ---------------------------------
# The container name and the binary are one fact each, so they live here: a
# rename is one edit, and a call site reads as the question it asks. These wrap
# ONLY the transport; each caller keeps its own error handling (a monitor read
# wants the empty answer, a rotation wants the failure).
bitcoind_cli() { # bitcoin-cli args...
    # bitcoin/bitcoin's BITCOIN_DATA is /data/.bitcoin (deploy/bitcoind.container);
    # the explicit -datadir also pins the answer against an image change.
    podman exec bitcoind bitcoin-cli -datadir=/data/.bitcoin "$@"
}

lightning_cli() { # lightning-cli args...
    podman exec lightningd lightning-cli "$@"
}

# cscli inside the running container: the binary the LAPI answers, with no extra
# credential on the host (verify.sh, scripts/ids.sh).
cscli() { # cscli args...
    podman exec crowdsec cscli "$@"
}

# The monerod restricted RPC, read with the curl the image ships: the daemon has
# no CLI, and net_curl is for npm-network peers, not a loopback in another
# container. METHOD is the path minus the slash (get_info). The timeout is the
# caller's budget: a read can block while a --block-sync-size batch holds the
# chain lock. Empty output means "did not answer", which keeps a hole a hole.
monerod_rpc() { # method [timeout] -> the daemon's JSON, empty on failure
    podman exec monerod curl -fsS -m "${2:-5}" "http://127.0.0.1:18089/$1"
}

# The same daemon's JSON-RPC endpoint (the unrestricted port), posted to rather
# than GETed. scripts/btcpay-wallet.sh needs it with a two-minute budget: it
# asks get_info while a sync batch may hold the chain lock.
monerod_json_rpc() { # method [timeout] -> the daemon's JSON, empty on failure
    podman exec monerod curl -s -m "${2:-120}" -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$1\"}" \
        http://127.0.0.1:18081/json_rpc
}
