#!/usr/bin/env bash
# Helpers shared by deploy.sh, configure.sh, deploy/install.sh, verify.sh and
# the scripts/ helpers. Sourced, not executed. bootstrap.sh stays self-contained
# because it must run standalone (curl | bash) on a host with no checkout, so it
# does not use this file.

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# env_value, write_atomic, status_write and dur_ms live in deploy/root/status.sh,
# which root sources as its installed copy and this sources from the checkout:
# one implementation, so the status contract the monitor reads cannot drift from
# what the root tier writes. Sourced after warn/die because that file must not
# depend on them.
# shellcheck source=../deploy/root/status.sh
. "$(dirname "${BASH_SOURCE[0]}")/../deploy/root/status.sh"

# Escape a value for sed's replacement side (&, \, |): an unescaped `|` in a
# data dir breaks the expression, and `&` re-inserts the match. install.sh renders
# through this and verify.sh re-renders to compare, so one copy keeps them honest.
esc() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }

# The substitutions every deploy/root/ template gets, shared by install.sh's
# render and verify.sh's comparison: a placeholder added on one side only would
# make drifted files read as clean. src and data-dir are arguments because the
# root pass may run with another user's data dir.
render_root_template() { # src data-dir
    sed -e "s|@DATA_DIR@|$(esc "$2")|g" \
        -e "s|@CONFIG_DIR@|$(esc "$2/config")|g" \
        -e "s|@REPO_DIR@|$(esc "${REPO_DIR:-}")|g" \
        -e "s|@IDS_RETENTION_DAYS@|$(esc "${IDS_RETENTION_DAYS:-14}")|g" \
        "$1"
}

# A fresh secret. Hex only: these reach a rendered systemd Exec= (Quadlet splits
# on whitespace and quotes nothing) and podman argv, where a space, quote or
# dollar sign is a foot-gun. 32 bytes is the 64 characters every daemon accepts.
rand_hex() {
    openssl rand -hex 32 2>/dev/null && return 0
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# The image the host-side checks speak through: a curl client (see
# netcheck/Containerfile), built by deploy/install.sh. A container, not the
# host's curl, because a probe resolves a service by its npm-network container
# name, and several app images carry no curl. The checks exec into a long-lived
# container rather than starting one per probe: each `podman run` added a veth
# pair and a cgroup scope, which the kernel logs per step (docs/logs.md).
#
# Two containers because podman refuses host + bridge on one ("cannot set
# multiple networks without bridge network mode"), and nginx-proxy-manager's
# admin API is a 127.0.0.1 bind only a host-netns client can reach.
NETCHECK_IMAGE="${NETCHECK_IMAGE:-localhost/netcheck:local}"
NETCHECK_CONTAINER="${NETCHECK_CONTAINER:-netcheck}"
NETCHECK_HOST_CONTAINER="${NETCHECK_HOST_CONTAINER:-netcheck-host}"

# Fail before podman does, so a host that never ran install.sh (or whose client
# is stopped) reads as one clear error rather than a stack trace.
netcheck_ready() { # container
    local c="${1:-$NETCHECK_CONTAINER}"
    if [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]; then
        return 0
    fi
    printf 'ERROR: %s is not running; run deploy/install.sh, then systemctl --user start %s\n' "$c" "$c" >&2
    return 127
}

# curl from the netcheck container, arguments verbatim:
#   net_curl -s -o /dev/null -w '%{http_code}' http://searxng-mcp:8000/health
# -i keeps stdin attached, so a caller can pass a secret as a curl config
# (`-K -`) instead of on a command line `ps` can read.
net_curl() {
    netcheck_ready "$NETCHECK_CONTAINER" || return 127
    # --events-backend=none: a sweep's probes are not worth an event either.
    podman --events-backend=none exec -i "$NETCHECK_CONTAINER" curl "$@"
}

# The same from the host's own namespace, for the one service that is not on
# npm-network: nginx-proxy-manager binds :80/:443/:81 itself (docs/proxy.md), so
# its admin API is 127.0.0.1:81 and a vhost it fronts is reached by looping back
# to this host:
#   net_curl_host -s -o /dev/null -w '%{http_code}' http://127.0.0.1:81/
net_curl_host() {
    netcheck_ready "$NETCHECK_HOST_CONTAINER" || return 127
    podman --events-backend=none exec -i "$NETCHECK_HOST_CONTAINER" curl "$@"
}

# Whole seconds, rounded UP: the caller is wait_healthy's floor, where waiting
# longer than the unit's own numbers is safe. Anything needing the value exactly
# (healthcheck-lint's 5-20s window) uses dur_ms.
dur_s() {
    local ms
    ms=$(dur_ms "$1")
    printf '%s' $(( (ms + 999) / 1000 ))
}

# True when dur_ms would have parsed the WHOLE string. dur_ms answers 0 for junk,
# which hides the difference between no duration and an unreadable one -- and
# `podman stats` prints cpu_time: "N/A", which must stay a hole, not 0.000.
dur_valid() { [[ ${1:-} =~ ^([0-9]+(\.[0-9]+)?(ms|h|m|s))+$ ]]; }

# Bytes of complete lines: everything through the last newline. A cursor must
# not advance past a half-written line, or the rest of it is lost on the next
# read; no newline at all answers 0 ("do not advance"). A file ending in a
# newline is one stat and one byte; otherwise the last newline is searched for
# in a 64 KiB block from the end, widened if one line is longer than that.
complete_line_bytes() {
    local n block=65536 from bytes last
    n=$(stat -c %s "$1" 2>/dev/null) || return 1
    [ "$n" -gt 0 ] || { printf 0; return 0; }
    if [ "$(tail -c 1 "$1" | wc -l)" -gt 0 ]; then
        printf '%s' "$n"
        return 0
    fi
    while :; do
        from=$(( n - block ))
        [ "$from" -lt 0 ] && from=0
        bytes=$(( n - from ))
        last=$(tail -c "$bytes" "$1" \
            | LC_ALL=C od -An -v -tu1 \
            | awk '{ for (i = 1; i <= NF; i++) { k++; if ($i == 10) last = k } } END { print last + 0 }')
        [ "$last" -gt 0 ] && { printf '%s' $(( from + last )); return 0; }
        [ "$from" -eq 0 ] && { printf 0; return 0; }
        block=$(( block * 4 ))
    done
}

# "4.176GB" -> bytes, the way go-units renders a size in `podman stats`. numfmt
# parses both spellings ("4.176GB" and "2GiB") once the trailing "B" is stripped,
# since its suffixes stop at the unit letter. LC_ALL=C pins the decimal point: a
# comma locale reads "4.176" as a grouped integer. Prints nothing and fails on
# anything unparsable, which is how the metrics collector keeps a hole a hole.
human_bytes() {
    LC_ALL=C numfmt --from=auto --to=none "${1%B}" 2>/dev/null
}

# The container's healthcheck state from `podman ps`'s Status column. A failing
# probe still starts with "Up", so matching "^Up" reads a red container as green.
# Podman 5.x prints "(starting)"; Docker and older builds "(health: starting)" --
# both accepted. One of: healthy | unhealthy | starting | up | down | other
# (up = no probe defined; tested in tests/test-lib.sh).
container_health_state() { # status
    case "$1" in
        '')                                    printf 'down' ;;
        *'(unhealthy)'*)                       printf 'unhealthy' ;;
        *'(health: starting)'*|*'(starting)'*) printf 'starting' ;;
        *'(healthy)'*)                         printf 'healthy' ;;
        'Up'*)                                 printf 'up' ;;
        *)                                     printf 'other' ;;
    esac
}

# Wait for a container's own healthcheck to report healthy. Shared by
# configure.sh and scripts/rotate.sh so both wait the same way. Honours DRY_RUN;
# returns non-zero after the timeout rather than dying, because the caller
# decides whether that is fatal.
wait_healthy() { # container timeout
    local c="$1" t="${2:-180}" deadline st="" hp start_s floor st_result
    [ "${DRY_RUN:-0}" = 1 ] && return 0

    # A Type=oneshot job never reports "(healthy)" and never appears in
    # `podman ps`: it exits. Waiting for "Up" would burn the caller's whole
    # timeout and then warn about a job that did its work. `systemctl restart`
    # already blocked on the job, so the only thing left to read is its result --
    # which also catches one that exceeded TimeoutStartSec.
    if [ "$(systemctl --user show -p Type --value "$c.service" 2>/dev/null)" = oneshot ]; then
        st=$(podman inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$c" 2>/dev/null || true)
        case "$st" in
            "exited 0") log "$c is a one-shot job and completed"; return 0 ;;
        esac
        # Quadlet passes --rm for a oneshot unit, so by the time the job returns
        # the container is usually gone and the unit's own result is the only
        # evidence left. `podman inspect` above still matters for a unit without
        # --rm, where the terminal state names the failure.
        st_result=$(systemctl --user show -p Result --value "$c.service" 2>/dev/null || true)
        if [ "$st_result" = success ]; then
            log "$c is a one-shot job and completed"
            return 0
        fi
        warn "$c is a one-shot job and did not complete (result: ${st_result:-unit not found}${st:+, container: $st})"
        return 1
    fi

    # No healthcheck to wait on: victoria-logs is distroless (no shell, so no
    # health command) and a unit like that would wait out every timeout for a
    # "(healthy)" that cannot appear. The functional check lives in verify.sh.
    if [ "$(podman inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$c" 2>/dev/null)" != yes ]; then
        deadline=$(( $(date +%s) + t ))
        while :; do
            st=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
            case "$st" in
                *Up*) log "$c is running (no healthcheck defined)"; return 0 ;;
            esac
            if [ "$(date +%s)" -ge "$deadline" ]; then
                warn "$c did not start after ${t}s (status: ${st:-container missing})"
                return 1
            fi
            sleep 2
        done
    fi

    # A unit's own profile can make the caller's timeout unreachable: podman runs
    # no probe during HealthStartPeriod, so the first possible "(healthy)" is at
    # StartPeriod + Interval. A caller that waits less reports "not healthy"
    # about a service that never had a chance to answer, so the unit's numbers
    # raise the caller's (a give-up bound, not a promise).
    hp=$(podman inspect -f '{{if .Config.Healthcheck}}{{.Config.Healthcheck.StartPeriod}} {{.Config.Healthcheck.Interval}}{{end}}' "$c" 2>/dev/null || true)
    if [ -n "$hp" ]; then
        start_s=$(dur_s "${hp%% *}")
        floor=$(( start_s + $(dur_s "${hp##* }") ))
        if [ "$floor" -gt "$t" ]; then
            log "$c: first health check can arrive at ${floor}s (start period + interval), waiting that instead of ${t}s"
            t=$floor
        fi
    fi

    # Prefer podman's own wait: it wakes the instant the state changes instead of
    # a sleep-and-poll loop. `podman wait` takes no --timeout (passing one made
    # every wait fail instantly), so coreutils `timeout` bounds it; killing the
    # client leaves the container alone.
    if command -v timeout >/dev/null 2>&1 \
        && podman wait --help 2>/dev/null | grep -q -- '--condition' \
        && [ "$(podman inspect -f '{{if .Config.Healthcheck}}yes{{end}}' "$c" 2>/dev/null)" = yes ]; then
        timeout "$t" podman wait --condition=healthy --condition=unhealthy --interval 2 "$c" >/dev/null 2>&1 || true
        st=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
        case "$st" in
            *"(healthy)"*) log "$c is healthy"; return 0 ;;
        esac
        warn "$c not healthy after ${t}s (status: ${st:-container missing})"
        return 1
    fi

    # Fallback (no podman --condition, or no healthcheck): poll.
    deadline=$(( $(date +%s) + t ))
    while :; do
        st=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
        case "$st" in *"(healthy)"*) log "$c is healthy"; return 0 ;; esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "$c not healthy after ${t}s (status: ${st:-container missing})"
            return 1
        fi
        sleep 5
    done
}

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
    # -datadir is redundant (the lncm image runs with HOME=/data, so the default
    # ~/.bitcoin IS /data/.bitcoin) but pins the answer against an image change.
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

# --- rendered-unit digests -------------------------------------------------
# A running container keeps the definition it started with: re-rendering a unit
# changes nothing until that unit restarts. So the baseline is persisted rather
# than compared either side of install.sh -- otherwise a hand install.sh (or
# rotate.sh's re-render) rewrites the files and the next deploy compares them
# with themselves.
#
#   $DATA_DIR/audit/units.rendered   what install.sh just wrote (every render)
#   $DATA_DIR/audit/units.applied    the render the containers were started from
#
# install.sh owns the first; deploy.sh and rotate.sh advance the second only
# after applying it, and live digests are compared against `applied`, never the
# render. The format is sha256sum's, with tor.unit/crowdsec.unit/vector.unit for
# the three config trees that are read only at start. Mode 600 like the rest of
# audit/: several rendered units embed a secret.
#
# Here because install.sh, deploy.sh, verify.sh and rotate.sh must agree byte for
# byte: two implementations would report permanent drift.
unit_digest() {
    local q="${QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
    [ -d "$q" ] || return 0
    ( cd "$q" && sha256sum -- *.container 2>/dev/null ) || true
    # torrc is not a unit, but a running tor keeps the config it started with,
    # and the onion services are rendered into it. Hashing it under the stem
    # "tor" makes the restart pass bounce tor when a service was retargeted.
    if [ -s "$DATA_DIR/tor/torrc" ]; then
        sha256sum -- "$DATA_DIR/tor/torrc" | awk '{ print $1 " tor.unit" }'
    fi
    # The crowdsec config is read only at start, so a changed parser, scenario or
    # whitelist would otherwise wait for the next reboot. One digest over the
    # rendered tree, under the stem "crowdsec".
    if [ -d "$DATA_DIR/config/ids/crowdsec" ]; then
        find "$DATA_DIR/config/ids/crowdsec" -type f -print0 2>/dev/null \
            | sort -z | xargs -0 -r sha256sum 2>/dev/null \
            | sha256sum | awk '{ print $1 " crowdsec.unit" }'
    fi
    # Vector reads its rendered config only at start (there is no reload), so a
    # changed transform restarts exactly that unit -- the same contract.
    if [ -s "$DATA_DIR/config/logs/vector/vector.toml" ]; then
        sha256sum -- "$DATA_DIR/config/logs/vector/vector.toml" | awk '{ print $1 " vector.unit" }'
    fi
}

# Map a running container name to the systemd unit that owns it. Usually the same
# string, but a unit may set ContainerName to something else (backup.container is
# stack-backup under backup.service), and `systemctl show stack-backup.service`
# answers 0 just like a real unit -- so assuming name == unit records restarts
# for a unit that does not exist. Falls back to the name when no rendered unit
# claims it.
unit_for_container() { # container-name -> unit stem
    local name="$1" q f stem cname
    q="${QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
    for f in "$q"/*.container; do
        [ -f "$f" ] || continue
        stem=${f##*/}
        stem=${stem%.container}
        cname=$(sed -n 's/^ContainerName=//p' "$f" 2>/dev/null | head -n1)
        [ -n "$cname" ] || cname="$stem"
        if [ "$cname" = "$name" ]; then
            printf '%s' "$stem"
            return 0
        fi
    done
    printf '%s' "$name"
}

# Is a unit in a space-delimited set of unit stems (" bitcoind tor ")? Kept in
# one place so a substring like "tor" never matches "tor-control".
unit_in_set() { # unit set
    [ -n "${1:-}" ] || return 1
    case " ${2:-} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# The unit stems whose digest differs between two sets, one per line. A unit on
# only one side is not reported: a new one is not running yet (it starts from the
# new file), and a removed one is not this function's business.
unit_digest_changed() { # before-digest after-digest
    awk 'NR==FNR { old[$2] = $1; next }
         ($2 in old) && old[$2] != $1 { print $2 }' \
        <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
        | sed 's/\.[^.]*$//' | sort -u
}

# Write a digest set to a manifest file, atomically and mode 600. Takes an
# explicit set when the caller already holds one (deploy.sh records what was
# applied, not whatever is on disk a moment later).
unit_digest_write() { # file [digest-set]
    local f="$1" d="${2:-}"
    [ -n "$d" ] || d=$(unit_digest)
    if [ -n "$d" ]; then
        printf '%s\n' "$d" | write_atomic "$f" 600
    else
        write_atomic "$f" 600 </dev/null
    fi
}

# The set to record when some units are not applied yet: the new render with a
# held unit's line replaced by its applied one, so the baseline still advances
# for everything that was applied (one unapplied unit must not make the next
# deploy restart all of them again) while verify.sh keeps naming the held one --
# its live digest still differs. Fails (exit 3) when a held unit has no applied
# line, because keeping a never-applied unit out of the baseline would hide it:
# unit_digest_changed ignores names on one side only.
unit_digest_hold() { # new-set applied-set held-stems -> the set to record
    awk -v held="$3" '
        BEGIN { n = split(held, h, " "); for (i = 1; i <= n; i++) hold[h[i]] = 1 }
        NR == FNR { applied[$2] = $0; next }
        {
            stem = $2; sub(/\.[^.]*$/, "", stem)
            if (stem in hold) {
                if (!($2 in applied)) missing = 1
                else print applied[$2]
                next
            }
            print
        }
        END { exit (missing ? 3 : 0) }
    ' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

# The last applied digest set, empty when this host has no baseline yet (a fresh
# host, or the first deploy after this file was introduced).
unit_applied_read() {
    local f="$DATA_DIR/audit/units.applied"
    if [ -s "$f" ]; then
        cat "$f"
    fi
}

# The digest set the running containers were last started from. Before that file
# exists (a fresh host, or the first deploy after it was introduced) the only
# baseline is the render on disk, so adopt it once, loudly, rather than bouncing
# every daemon. Drift older than that first run is invisible; the run that adopts
# the baseline becomes it.
units_baseline() {
    local applied
    applied=$(unit_applied_read)
    if [ -n "$applied" ]; then
        printf '%s\n' "$applied"
        return 0
    fi
    warn "no applied-unit baseline yet ($DATA_DIR/audit/units.applied); adopting the units on disk as deployed. Drift that predates this run is invisible -- this run becomes the baseline."
    unit_digest
}

# --- locally-built images --------------------------------------------------
# The images this repo builds (btc-explorer, xmr-explorer, netcheck, tor) are
# described completely by their Containerfile: base image digest-pinned in FROM,
# every upstream pin an ARG, nothing COPYed out of the build context. So the hash
# of that file *is* the build identity, and baking it in as a label answers "is
# this image the one this Containerfile describes?" without rebuilding. That is
# what lets a merged Renovate digest bump reach the host: it changes no unit file
# and no tag, so `podman image exists` alone would keep the old bits forever. No
# label means stale, and it is rebuilt once.
image_inputs_digest() { # containerfile -> sha256 of its bytes
    sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

image_is_current() { # image containerfile -> 0 when the label matches the file
    local image="$1" cf="$2" want have
    podman image exists "$image" 2>/dev/null || return 1
    want=$(image_inputs_digest "$cf")
    [ -n "$want" ] || return 1
    have=$(podman image inspect \
        --format '{{if .Labels}}{{index .Labels "org.stack.inputs"}}{{end}}' \
        "$image" 2>/dev/null) || return 1
    [ "$have" = "$want" ]
}

# The same value as it goes onto the image: one place for the label name.
image_inputs_label() { # containerfile -> LABEL=VALUE for podman build --label
    printf 'org.stack.inputs=%s' "$(image_inputs_digest "$1")"
}

# The image a unit is running, falling back to a given tag when the container
# does not exist yet (a fresh host, before the first start). Host-side jobs that
# read a service's own database must not pin a second copy of its Image=: on a
# deployed host the running container answers, so a Renovate bump reaches them
# too. The fallback is a bootstrap default, not a pin to maintain.
container_image_or() { # container default-image
    local img=""
    if command -v podman >/dev/null 2>&1 && podman container exists "$1" 2>/dev/null; then
        img=$(podman inspect "$1" --format '{{.ImageName}}' 2>/dev/null || true)
    fi
    printf '%s' "${img:-$2}"
}
npm_image() {
    container_image_or nginx-proxy-manager "${NPM_IMAGE:-docker.io/jc21/nginx-proxy-manager:2.16.0}"
}
kuma_image() {
    container_image_or uptime-kuma "${UPTIME_KUMA_IMAGE:-docker.io/louislam/uptime-kuma:2}"
}

# Write a Prometheus textfile for node-exporter's textfile collector: stdin -> a
# .prom file, atomically, with the permissions the exporter needs (write_atomic
# in deploy/root/status.sh says why 0755/0644):
#   printf 'stack_x 1\n' | prom_write "$DATA_DIR/monitoring/textfile/stack.prom"
prom_write() {
    write_atomic "$1" 644 755
}

# The one writer for an env file carrying a secret (or a credential-bearing URL):
# atomic, 0600, parent created. install.sh seeds them and configure.sh rewrites
# two from the BTCPay bootstrap state -- one writer, so the two cannot disagree
# about the mode, which is exactly the split where one side forgets it.
write_env_file() { # path
    write_atomic "$1" 600
}

# install.sh's name for it: every seed site there reads as what it is, a secret
# being written. An alias rather than renaming thirty call sites.
write_secret() { # path
    write_env_file "$1"
}

# Read one of those status files, in one place: monitor.sh and verify.sh judge the
# oneshot jobs' verdicts the same way, and only the judgement (thresholds, wording,
# units) differs per caller.
#
# Sets STATUS_RESULT, STATUS_AGE_S and STATUS_DETAIL rather than printing a line:
# a delimiter-separated line cannot carry the empty fields this read exists for
# (a failure with no detail, a skip before the first success), because `read`
# collapses runs of a whitespace IFS. The age is empty when no success is
# recorded or ok_epoch is not a number, and floored at 0 so a clock that stepped
# back reads "just now" rather than a negative age that passes every threshold.
# A missing file leaves all three empty.
# shellcheck disable=SC2034  # set for the caller to read after this returns
status_verdict() { # file -> STATUS_RESULT, STATUS_AGE_S, STATUS_DETAIL
    local ok
    STATUS_RESULT=""; STATUS_AGE_S=""; STATUS_DETAIL=""
    [ -f "$1" ] || return 0
    STATUS_RESULT=$(env_value "$1" result)
    STATUS_DETAIL=$(env_value "$1" detail)
    ok=$(env_value "$1" ok_epoch)
    case "$ok" in
        ''|*[!0-9]*) ;;
        *) STATUS_AGE_S=$(( $(date +%s) - ok ))
           [ "$STATUS_AGE_S" -ge 0 ] || STATUS_AGE_S=0 ;;
    esac
}

# How old the newest restic snapshot is, and how many there are -- one read of
# `backup.sh list --json` for monitor.sh (age and count) and rotate.sh (refuses
# to rotate the restic password without a recent backup). Prints
# "count<TAB>newest-epoch"; non-zero means the repository could not be listed AT
# ALL, which is not "no snapshots yet".
restic_snapshot_summary() { # -> "count<TAB>newest-epoch"
    local backup="${REPO_DIR:-}/scripts/backup.sh" json latest count epoch=""
    [ -n "${REPO_DIR:-}" ] || return 1
    json=$("$backup" list --json 2>/dev/null) || return 1
    printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
    count=$(printf '%s' "$json" | jq 'length' 2>/dev/null) || return 1
    latest=$(printf '%s' "$json" | jq -r 'map(.time) | max // empty' 2>/dev/null) || return 1
    [ -z "$latest" ] || epoch=$(date -d "$latest" +%s 2>/dev/null || true)
    printf '%s\t%s' "$count" "$epoch"
}

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

# Print a script's leading comment block (shebang excluded) for --help. Stops at
# the first non-comment line, so keep each script's header one contiguous block.
usage_header() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$1"
}

# Where the stack keeps everything it must not lose: the daemon data dirs, NPM's
# data, and config/secrets, so a rebuild only has to preserve one directory.
# Resolved in this order, then persisted so it is asked once per host:
#   1. $STACK_DATA_DIR (environment, or stack.conf)
#   2. the value saved in $STACK_DATA_ENV by an earlier run
#   3. an interactive prompt, defaulting to $HOME/data
#   4. $HOME/data
resolve_data_dir() {
    local default="${HOME}/data" answer=""
    STACK_DATA_ENV="${STACK_DATA_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/stack/data-dir.env}"

    if [ -z "${STACK_DATA_DIR:-}" ] && [ -s "$STACK_DATA_ENV" ]; then
        # shellcheck disable=SC1090
        . "$STACK_DATA_ENV"
    fi
    if [ -z "${STACK_DATA_DIR:-}" ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            read -r -p "Data directory for the stack [${default}]: " answer || answer=""
            STACK_DATA_DIR="${answer:-$default}"
        else
            STACK_DATA_DIR="$default"
        fi
    fi

    STACK_DATA_DIR="${STACK_DATA_DIR%/}"
    [ -n "$STACK_DATA_DIR" ] || STACK_DATA_DIR="$default"
    DATA_DIR="$STACK_DATA_DIR"
    CONFIG_DIR="$DATA_DIR/config"
    NPM_DIR="$DATA_DIR/npm"
    export STACK_DATA_DIR DATA_DIR CONFIG_DIR NPM_DIR STACK_DATA_ENV
    persist_data_dir
}

persist_data_dir() {
    [ -n "${STACK_DATA_ENV:-}" ] || return 0
    [ "${DRY_RUN:-0}" = 1 ] && return 0
    mkdir -p "$(dirname "$STACK_DATA_ENV")"
    printf 'STACK_DATA_DIR=%s\n' "$DATA_DIR" > "$STACK_DATA_ENV"
}

# Give the data dir a container label when SELinux is enforcing and it lacks one.
# The units mount subdirectories with `:z`/`:Z`, which podman relabels rootlessly
# on every start, so only a path podman cannot relabel (one the login user does
# not own -- a freshly formatted disk is often unlabeled_t) needs help. Try an
# unprivileged label, and if even that fails print the root commands: nothing
# here (or in deploy.sh, install.sh, verify.sh) uses sudo.
ensure_data_dir_selinux() {
    [ -d "$DATA_DIR" ] || return 0
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null)" = "Enforcing" ] || return 0

    local ctx
    ctx=$(stat -c '%C' "$DATA_DIR" 2>/dev/null || true)
    case "$ctx" in
        *container_file_t*|*svirt_sandbox_file_t*) return 0 ;;
    esac

    # Not recursive on purpose: the image-uid subdirs (bitcoin)
    # are not ours to relabel, and podman's `:z` covers the mounted subdirs.
    log "SELinux: $DATA_DIR is '$ctx'; labelling it for containers"
    chcon -t container_file_t "$DATA_DIR" 2>/dev/null || true

    ctx=$(stat -c '%C' "$DATA_DIR" 2>/dev/null || true)
    case "$ctx" in
        *container_file_t*|*svirt_sandbox_file_t*) log "SELinux: $DATA_DIR labelled for containers" ;;
        *)
            local regex
            regex="$(printf '%s' "$DATA_DIR" | sed -e 's/[][\.^$*+?(){}|]/\\&/g')(/.*)?"
            warn "$DATA_DIR is '$ctx', not labelled for containers and not ours to relabel; containers may be denied"
            warn "fix it once, as root, then re-run:"
            printf '    sudo semanage fcontext -a -t container_file_t "%s"\n    sudo restorecon -RF "%s"\n' "$regex" "$DATA_DIR" >&2
            ;;
    esac
}

# Create the data dir (and its config / npm subdirs) if missing. A data dir on a
# separate disk must already exist and be yours (README has the one-time
# commands); a path we cannot prepare is a clear error, never an implicit sudo.
# Only the top-level dir is ours -- subdirs like bitcoin are the image uid.
ensure_data_dirs() {
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR" 2>/dev/null || die "cannot create $DATA_DIR: its parent is not writable by $(id -un). Create it first:
    sudo mkdir -p \"$DATA_DIR\" && sudo chown \"$(id -u):$(id -g)\" \"$DATA_DIR\""
    fi
    if [ ! -w "$DATA_DIR" ]; then
        die "$DATA_DIR is not writable by $(id -un). Take ownership first:
    sudo chown \"$(id -u):$(id -g)\" \"$DATA_DIR\""
    fi
    mkdir -p "$CONFIG_DIR" "$NPM_DIR/data" "$NPM_DIR/letsencrypt" \
        || die "could not create the data subdirectories under $DATA_DIR"
}

# --- the service manifest -----------------------------------------------------
# deploy/services.toml is the ONE declaration of the public surface: the *_HOST
# names, the MCP prefixes/containers/ports, the onion services and the proxy
# hosts. This is how a bash caller reads them, by eval'ing
# `python3 -m stackctl manifest shell` -- NAME='value' lines and array
# assignments, nothing else. Each table leaves as one array per column
# (MCP_PREFIXES / MCP_CONTAINERS / MCP_PORTS, and ONION_*), so no caller splits a
# record apart.
#
# It must never run inside stack.conf: bootstrap.sh sources that file standalone
# (curl | bash, no checkout), so stack.conf stays plain data and the manifest load
# is each caller's explicit step, right after sourcing it.
#
#   . "$REPO_DIR/stack.conf"; load_manifest     # then $MCP_PREFIXES etc. exist
load_manifest() { # [repo-dir] (defaults to $REPO_DIR)
    local repo="${1:-${REPO_DIR:-}}" script_dir out
    [ -n "$repo" ] || die "load_manifest: no repository directory (REPO_DIR is unset)"
    [ -f "$repo/deploy/services.toml" ] \
        || die "load_manifest: $repo/deploy/services.toml is missing"
    command -v python3 >/dev/null 2>&1 \
        || die "load_manifest: python3 is required (bootstrap.sh installs it)"
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    out=$(PYTHONPATH="$script_dir${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m stackctl manifest shell "$repo/deploy/services.toml") \
        || die "load_manifest: could not read $repo/deploy/services.toml"
    eval "$out"
}

# The half of npm-hosts.sh that is not its CLI: it owns a CLI (--dry-run,
# --prune, --help), the data dir and one endpoint override; everything else is
# the Python core in scripts/stackctl/, which loads services.toml itself. So the
# wrapper resolves the data dir and hands the core its facts -- paths and flags,
# never a secret.
#
# Extra facts are NAME=value arguments, so a wrapper reads as the one thing it
# adds, and only when the operator set it:
#   stackctl_wrapper npm-hosts "NPM_API=$NPM_API"
stackctl_wrapper() { # module [NAME=value ...]
    local module="$1"; shift
    local dry_run=0 prune=0 py
    local -a overrides=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            --prune)   prune=1 ;;
            -h|--help) usage_header "$0"; exit 0 ;;
            *=*)       overrides+=("$1") ;;
            *)         die "unknown argument: $1 (try --help)" ;;
        esac
        shift
    done
    # stdlib-only (npm.py talks urllib to NPM's admin API), so the host's own
    # python3 runs it -- a bootstrap dependency like load_manifest. No venv.
    python_bin=python3
    command -v "$python_bin" >/dev/null 2>&1 \
        || die "python3 is required to run the reconciler (bootstrap.sh installs it)"
    resolve_data_dir
    py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Passed through env(1) rather than exported: a subshell `export DRY_RUN`
    # makes shellcheck think the sourcing scripts can lose it (SC2031). The
    # NAME=value arguments are collected while parsing, because the loop has
    # shifted them away by the time the core runs.
    local -a envs=("MANIFEST=$REPO_DIR/deploy/services.toml" "DRY_RUN=$dry_run" "PRUNE=$prune")
    envs+=(${overrides[@]+"${overrides[@]}"})
    PYTHONPATH="$py${PYTHONPATH:+:$PYTHONPATH}" \
        env "${envs[@]}" "$python_bin" -m stackctl "$module"
}

