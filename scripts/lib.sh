#!/usr/bin/env bash
# Helpers shared by deploy.sh, deploy/install.sh, verify.sh and the scripts/
# helpers. Sourced, not executed. bootstrap.sh stays self-contained because it
# must run standalone (curl | bash) on a host with no checkout, so it does not
# use this file.

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Escape a value for sed's replacement side (&, \, |). Every @PLACEHOLDER@ whose
# value can be a path or a secret goes through this: an unescaped `|` in a data
# dir turns `sed -e "s|@DATA_DIR@|/a|b|g"` into "unknown option to `s'" (so the
# substitution silently produces nothing and the diff reports permanent drift),
# and `&` re-inserts the matched text. Shared because deploy/install.sh renders
# units and verify.sh renders the same files to compare them; one copy is what
# keeps the comparison honest.
esc() { printf '%s' "$1" | sed -e 's/[&\\|]/\\&/g'; }

# Echo the value of KEY from a KEY=VALUE env/secrets file (first match). Reads
# the file line by line and never sources it, and strips a trailing CR so a
# CRLF file still parses. Prints nothing when the file or the key is absent.
env_value() {
    local file="$1" key="$2"
    [ -s "$file" ] || return 0
    sed -n "s/^$key=//p" "$file" | head -n1 | tr -d '\r'
}

# A fresh secret. Hex only, on purpose: these values end up in a rendered
# systemd Exec= line (Quadlet splits it on whitespace and quotes nothing) and in
# podman argv, so a value with a space, a quote or a dollar sign would be a
# foot-gun in three places at once. 32 bytes = the 64 characters bitcoind, Tor,
# Monero and CLN all accept.
rand_hex() {
    openssl rand -hex 32 2>/dev/null && return 0
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# The image the host-side checks speak through: a curl client (see
# netcheck/Containerfile), built by deploy/install.sh. It is a container rather
# than a host package, so the host needs only podman for a check to reach a
# service (the app images vary, and several carry no curl).
#
# The checks EXEC into a long-lived container instead of starting a throwaway
# one per probe. That is not tidiness: verify.sh makes dozens of probes in a
# sweep, and each `podman run` created a veth pair and a cgroup scope, which the
# kernel logged as a line per step -- about 12k lines an hour, the biggest
# stream in the journal, and a third of what the log store was indexing.
#
# The exec *event* is a separate stream and is not this function's business:
# podman writes two lines per exec (`exec`, `exec_died`) and one per
# healthcheck run, and deploy/install.sh points the user's event log at a
# bounded file instead of journald (podman_events_conf). That is the only place
# it can be set -- a per-call flag cannot reach podman's own healthcheck units,
# or the next script anyone writes.
#
# Two containers because podman refuses host + bridge on one ("cannot set
# multiple networks without bridge network mode"), and nginx-proxy-manager's
# admin API is a 127.0.0.1 bind only a host-netns client can reach.
NETCHECK_IMAGE="${NETCHECK_IMAGE:-localhost/netcheck:local}"
NETCHECK_CONTAINER="${NETCHECK_CONTAINER:-netcheck}"
NETCHECK_HOST_CONTAINER="${NETCHECK_HOST_CONTAINER:-netcheck-host}"

# Is the client up? Fail before podman does, so a host that has not run
# deploy/install.sh (or whose container was stopped) reads as one clear error
# rather than a podman stack trace. Takes the container name so each helper
# checks only the one it uses.
netcheck_ready() { # container
    local c="${1:-$NETCHECK_CONTAINER}"
    if [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]; then
        return 0
    fi
    printf 'ERROR: %s is not running; run deploy/install.sh, then systemctl --user start %s\n' "$c" "$c" >&2
    return 127
}

# Run curl against a container on npm-network, from the long-lived netcheck
# container. Arguments are curl's, verbatim, so call sites read exactly as they
# did when this was a host curl against a published loopback port:
#   net_curl -s -o /dev/null -w '%{http_code}' http://searxng-mcp:8000/health
# -i keeps stdin attached, which is how a caller passes a secret in a curl
# config (`-K -`) rather than on a command line that `ps` can read.
net_curl() {
    netcheck_ready "$NETCHECK_CONTAINER" || return 127
    # --events-backend=none is belt to install.sh's braces: deploy/install.sh
    # moves podman's event log to a bounded file (podman_events_conf), and a
    # sweep's dozens of probes are not worth an entry even there.
    podman --events-backend=none exec -i "$NETCHECK_CONTAINER" curl "$@"
}

# The same, from the host's own network namespace -- through netcheck-host, the
# second long-lived client. It is for the one service that is not on
# npm-network: nginx-proxy-manager runs on the host network
# (deploy/nginx-proxy-manager.container) so that its logs and the
# X-Forwarded-For it sets carry a client's real address. That also means it
# binds :80/:443/:81 itself and speaks to the app tier on the loopback publishes
# its units declare, so its admin API is 127.0.0.1:81 and a host name it fronts
# is reached by looping back to this host:
#   net_curl_host -s -o /dev/null -w '%{http_code}' http://127.0.0.1:81/
net_curl_host() {
    netcheck_ready "$NETCHECK_HOST_CONTAINER" || return 127
    podman --events-backend=none exec -i "$NETCHECK_HOST_CONTAINER" curl "$@"
}

# "1m30s" / "500ms" / "1h2m3.5s" -> MILLIseconds. Podman prints a healthcheck's
# durations as Go duration strings, and so does CrowdSec's LAPI ("3h59m59.7s" is
# what a decision carries), so a fraction can sit on any component. Each
# component is therefore parsed by its unit and summed in ms. The whole-second
# regexes this replaced matched the digits AFTER the dot instead of the component
# before it, which is not a rounding difference: "1m30.5s" became 65s, "2.5h"
# became 18000s and "1.5m" became 300s. Three details are load-bearing: `ms`
# precedes `m` in the alternation or "500ms" reads as 500 minutes, 10# keeps
# "08m" from being parsed as octal, and the fraction is padded/truncated to three
# digits because bash has no arithmetic on it. Unparsable input (or none, which
# is an unset healthcheck field) is 0.
dur_ms() {
    local d="$1" total=0 num frac unit
    while [ -n "$d" ] && [[ $d =~ ^[^0-9]*([0-9]+)(\.([0-9]+))?(ms|h|m|s)(.*)$ ]]; do
        num=${BASH_REMATCH[1]} frac=${BASH_REMATCH[3]} unit=${BASH_REMATCH[4]} d=${BASH_REMATCH[5]}
        frac="${frac}000"; frac="${frac:0:3}"
        case "$unit" in
            h)  total=$(( total + 10#$num * 3600000 + 10#$frac * 3600 )) ;;
            m)  total=$(( total + 10#$num * 60000 + 10#$frac * 60 )) ;;
            s)  total=$(( total + 10#$num * 1000 + 10#$frac )) ;;
            ms) total=$(( total + 10#$num )) ;;
        esac
    done
    printf '%s' "$total"
}

# Whole seconds, rounded UP. The caller is wait_healthy's floor, where waiting
# longer than the unit's own numbers is the safe direction -- so a sub-second
# value still becomes 1s. Anything that needs the value exactly (healthcheck-lint
# judging a 5-20s window, or a probe bound against a timeout) rounds in dur_ms
# instead; rounding here would let a 4.5s timeout pass a 5s floor.
dur_s() {
    local ms
    ms=$(dur_ms "$1")
    printf '%s' $(( (ms + 999) / 1000 ))
}

# Wait for a container's own healthcheck to report healthy. Shared by deploy.sh
# (which starts the units) and scripts/rotate.sh (which restarts the ones a
# rotated credential touches), so both wait the same way. Honours DRY_RUN when
# the caller sets it, and returns non-zero after the timeout rather than dying:
# the caller decides whether that is fatal.
wait_healthy() { # container timeout
    local c="$1" t="${2:-180}" deadline st="" hp start_s floor st_result
    [ "${DRY_RUN:-0}" = 1 ] && return 0

    # A one-shot job (Type=oneshot) never reports "(healthy)" and never shows up
    # in `podman ps`: it *exits*. Waiting for "Up" burns the caller's whole
    # timeout and then warns about a job that did its work -- which is what
    # `./deploy.sh --only postgres-dump|btcpay-bootstrap` used to do (180 s of
    # spin, then "container missing"). `systemctl restart` already blocked on
    # the job and failed loudly, so the only thing left to read is its result;
    # this also catches a job that systemd accepted and that exceeded
    # TimeoutStartSec, which is a failure however the unit reports it.
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

    # No healthcheck to wait on: victoria-logs' image is distroless (no shell,
    # so podman cannot run a health command), and a unit like that would wait
    # out every timeout for a "(healthy)" that never appears. "Up" is the only
    # state to wait for; the functional check lives in verify.sh.
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

    # A unit's own profile can make the caller's timeout unreachable: podman
    # runs no health check during HealthStartPeriod, so the first possible
    # "(healthy)" is at StartPeriod + Interval. A caller that waits less than
    # that reports "not healthy" about a service that never had the chance to
    # answer -- so the unit's numbers raise the caller's, and the log says which
    # number won. (The caller's timeout is a give-up bound, not a promise: this
    # only prevents a give-up that is shorter than one probe cycle.)
    hp=$(podman inspect -f '{{if .Config.Healthcheck}}{{.Config.Healthcheck.StartPeriod}} {{.Config.Healthcheck.Interval}}{{end}}' "$c" 2>/dev/null || true)
    if [ -n "$hp" ]; then
        start_s=$(dur_s "${hp%% *}")
        floor=$(( start_s + $(dur_s "${hp##* }") ))
        if [ "$floor" -gt "$t" ]; then
            log "$c: first health check can arrive at ${floor}s (start period + interval), waiting that instead of ${t}s"
            t=$floor
        fi
    fi

    # Prefer podman's own health wait: it wakes the instant the state changes
    # instead of a shell `sleep 5` loop that spawns podman and date per tick.
    # `podman wait` has no --timeout of its own (it was never a flag -- passing
    # one made every wait fail instantly, so the caller always saw "not
    # healthy"), so coreutils `timeout` bounds it; killing the client leaves the
    # container alone. Only when the container defines a healthcheck, else
    # podman has nothing to wait on.
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
# JSON shape `createrune` wants (an array of groups, each an array of
# alternatives). Declared once in stack.conf (CLN_READ_METHODS and friends) so
# deploy/install.sh and scripts/rotate.sh mint the SAME runes -- a rotator that
# granted more, or less, than the installer would be a security bug.
rune_json() { # prefix...
    local out="" p
    for p in "$@"; do
        out+="${out:+,}\"method^$p\""
    done
    printf '[[%s]]' "$out"
}

# --- the live rune set ------------------------------------------------------
# A rune carries no label -- this CLN's `createrune` takes no comment -- so the
# only identity a rune has is its method set. These read the live set off the
# node and compare it with the prefixes stack.conf declares, which makes "a rune
# this stack minted" a reproducible fact instead of a remembered id (that is the
# lesson from a host whose rune table had collected five live leftovers no
# bookkeeping had ever seen).
#
# scripts/rotate.sh blacklists the ones lightning-mcp/node.env does not carry,
# and scripts/monitor.sh pages on them; both go through here so the pruner and
# the alarm cannot disagree about what a stack rune is.
cln_live_runes() { # -> unique_id<TAB>rune<TAB>methodset, per non-blacklisted rune
    local out
    out=$(podman exec lightningd lightning-cli showrunes 2>/dev/null) || return 1
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

# Live runes whose method set is EXACTLY one of stack.conf's and that are not one
# of the runes passed as arguments: the leftovers a rotation blacklists and the
# monitor pages on. An exact match is deliberate -- a rune minted for something
# else keeps its methods and must never be touched. Empty output plus exit 0 is
# the clean case; a non-zero exit means the node could not be read (showrunes or
# jq failed), which the caller must not mistake for "nothing to do".
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

# The RPC password bitcoind's OWN bitcoin.conf carries (empty when the container
# or the file cannot be read). Compared with secrets.env by scripts/rotate.sh
# --status and scripts/monitor.sh: the two copies are the ones a half-applied
# bitcoin-rpc rotation pulls apart, and nothing else would notice before the next
# restart. Never printed by either caller -- only compared.
bitcoind_conf_password() {
    podman exec bitcoind sh -c 'sed -n "s/^rpcpassword=//p" /data/.bitcoin/bitcoin.conf' 2>/dev/null \
        | head -n1 || true
}

# --- the Electrum protocol (Fulcrum) ----------------------------------------
# Electrum is newline-delimited JSON-RPC over raw TCP, not HTTP: 50001 plaintext
# and 50002 TLS with a certificate the image self-signs. net_curl cannot read it
# and nginx-proxy-manager cannot front it, so this is the stack's one protocol
# that needs a TCP client of its own.
#
# The client is bash's /dev/tcp. The host has no nc -- bootstrap.sh installs
# podman, firewalld, git, openssl and jq and nothing else -- and `read -t` is the
# whole timeout, so a probe costs no container start and no package. It runs in
# a subshell because a failed `exec` redirection can end a non-interactive shell:
# a refused port has to cost the caller an empty string, never the sweep. TLS
# goes through openssl, which is already a bootstrap dependency (scripts/monitor.sh
# reads certificate expiry with it).
#
# Callers dial 127.0.0.1 -- deploy/fulcrum.container.in publishes 50001/50002 on
# every interface, so the published port on the host's loopback is exactly what a
# wallet on the LAN reaches. Reading the container by name would prove less (it
# stays up if the publish is lost) and is not what the protocol surface is.
electrum_call() { # host port request-line -> the server's reply, empty on failure
    bash -c '
        exec 3<>"/dev/tcp/$1/$2" || exit 0
        printf "%s\n" "$3" >&3
        IFS= read -r -t 5 reply <&3
        printf "%s" "$reply"
    ' _ "$1" "$2" "$3" 2>/dev/null
}

# The same over TLS. -quiet drops the handshake chatter; stdin has to stay open a
# moment after the request or s_client closes the connection before the answer
# arrives, hence the sleep -- two seconds, not a timeout loop (five runs of a
# local TLS server answered inside it every time).
electrum_call_tls() { # host port request-line -> the server's reply, empty on failure
    { printf '%s\n' "$3"; sleep 2; } \
        | timeout 10 openssl s_client -quiet -connect "$1:$2" 2>/dev/null \
        | head -n1
}

# The tip height Fulcrum reports, or empty when it does not answer. This is the
# index-backed question on purpose: `server.version` is answered from memory and
# stays green on exactly the failure this exists to catch -- an index that has
# wedged while the process, the port and the healthcheck all still look fine.
# Callers compare it with bitcoind's `blocks`; a healthy Fulcrum polls every 5s
# (--polltime), so the gap is 0-1 block once it has caught up.
#
# Fulcrum answers nothing useful while it is still catching up on a fresh host,
# so an empty result is expected during initial block download: verify.sh warns
# and scripts/monitor.sh softens it under MONITOR_GRACE_SYNC.
electrum_tip() { # port [tls] -> height, empty on failure
    local port="$1" tls="${2:-}" reply
    local req='{"id":1,"method":"blockchain.headers.subscribe","params":[]}'
    if [ "$tls" = tls ]; then
        reply=$(electrum_call_tls 127.0.0.1 "$port" "$req")
    else
        reply=$(electrum_call 127.0.0.1 "$port" "$req")
    fi
    printf '%s' "$reply" | grep -oE '"height"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$' | head -n1
}

# --- rendered-unit digests -------------------------------------------------
# A *running* container keeps the definition it started with: re-rendering a
# unit changes nothing until that unit restarts. deploy.sh therefore has to know
# which rendered definitions the running containers were started from, and it
# used to answer that by digesting the files either side of its own install.sh
# run. That made the baseline "whatever was on disk when this process started",
# so a hand `deploy/install.sh` (or scripts/rotate.sh's re-render) rewrote the
# files and the next deploy compared them with themselves -- the edit sat
# unapplied while every health check reported healthy. The fix is to persist the
# answer:
#
#   $DATA_DIR/audit/units.rendered   what install.sh just wrote (every render)
#   $DATA_DIR/audit/units.applied    the render the containers were started from
#
# install.sh owns the first; deploy.sh and rotate.sh advance the second only
# after they have applied it. Live digests are compared against `applied`, never
# against the render, so a unit edited after install.sh wrote it is caught too.
# The format is exactly `sha256sum`'s (`<hash>  <stem>`), with the pseudo-names
# `tor.unit`, `crowdsec.unit` and `vector.unit` for the three config trees that
# are not units but are read only at start. A digest is not a secret, but the
# files are mode 600 like the rest of audit/: several rendered units embed one.
#
# These live here because deploy/install.sh, deploy.sh, verify.sh and
# scripts/rotate.sh must agree byte for byte: two implementations would report
# permanent drift (esc() above exists for the same reason).
unit_digest() {
    local q="${QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
    [ -d "$q" ] || return 0
    ( cd "$q" && sha256sum -- *.container 2>/dev/null ) || true
    # torrc is not a unit, but a running tor keeps the config it started with all
    # the same -- and the onion services are declared in stack.conf and rendered
    # into it. Hash it under a pseudo-name whose stem is the unit ("tor"), so the
    # restart pass bounces tor when a hidden service was added, removed or
    # retargeted.
    if [ -s "$DATA_DIR/tor/torrc" ]; then
        sha256sum -- "$DATA_DIR/tor/torrc" | awk '{ print $1 " tor.unit" }'
    fi
    # The crowdsec config is not a unit either, and the container reads it only
    # at start: a changed parser, scenario or whitelist would otherwise wait for
    # the next reboot. One digest over the rendered tree, under the stem
    # "crowdsec", so exactly that unit is restarted.
    if [ -d "$DATA_DIR/config/ids/crowdsec" ]; then
        find "$DATA_DIR/config/ids/crowdsec" -type f -print0 2>/dev/null \
            | sort -z | xargs -0 -r sha256sum 2>/dev/null \
            | sha256sum | awk '{ print $1 " crowdsec.unit" }'
    fi
    # The log shipper's config is rendered by install.sh, not mounted from the
    # repo, and Vector reads it only at start (there is no reload). Hash it under
    # the unit's stem so a changed transform restarts exactly that unit, the same
    # contract as crowdsec's tree.
    if [ -s "$DATA_DIR/config/logs/vector/vector.toml" ]; then
        sha256sum -- "$DATA_DIR/config/logs/vector/vector.toml" | awk '{ print $1 " vector.unit" }'
    fi
}

# The unit stems whose digest differs between two digest sets, one per line.
# A unit present on only one side is not reported: a newly rendered unit is not
# running yet (it starts from the new file), and a removed one is not this
# function's business.
unit_digest_changed() { # before-digest after-digest
    awk 'NR==FNR { old[$2] = $1; next }
         ($2 in old) && old[$2] != $1 { print $2 }' \
        <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
        | sed 's/\.[^.]*$//' | sort -u
}

# Write a digest set to a manifest file, atomically and mode 600. Called with an
# explicit set when the caller already holds one (deploy.sh records the digests
# that were applied, not whatever is on disk a moment later).
unit_digest_write() { # file [digest-set]
    local f="$1" d="${2:-}" tmp
    [ -n "$d" ] || d=$(unit_digest)
    mkdir -p "$(dirname "$f")" || return 1
    tmp=$(mktemp "${f}.XXXXXX") || return 1
    if [ -n "$d" ]; then
        printf '%s\n' "$d" > "$tmp"
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
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
# existed (the first deploy after this change) the only baseline available is the
# render on disk -- which is what the old before/after comparison used -- so
# adopt it once, loudly, rather than bouncing every daemon on the host. Drift
# that predates that first run is invisible; the run that adopts the baseline
# becomes it. deploy.sh and scripts/rotate.sh both read it here.
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
# The images this repo builds itself (btc-explorer, xmr-explorer, netcheck,
# tor) are described completely by their Containerfile: the base image
# is digest-pinned in `FROM`, every upstream pin is an `ARG` in the same file,
# and none of them COPYs anything out of its build context (each directory is
# that one file). So the
# hash of that file *is* the image's build identity. Baking it in as a label
# lets a later deploy answer "is this image the one this Containerfile
# describes?" without rebuilding to find out -- which is what makes a merged
# Renovate digest bump reach the host at all: it changes nothing else, no unit
# file and no tag, so `podman image exists` alone would keep the old bits
# forever. An image with no label (built before this existed) is stale by
# definition and is rebuilt once.
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
# .prom file, atomically, with the permissions the exporter needs. node-exporter
# runs as uid 65534 -- a *subuid* under rootless podman -- so it owns neither the
# directory nor the file and must still be able to read them; getting that wrong
# is the quietest way to lose every custom metric, which is why the mode lives
# here and not in each writer:
#   printf 'stack_x 1\n' | prom_write "$DATA_DIR/monitoring/textfile/stack.prom"
prom_write() {
    local target="$1" dir tmp
    dir=$(dirname "$target")
    mkdir -p "$dir" || return 1
    # 0755 the directory, 0644 the file: the exporter has only "other" access.
    chmod 0755 "$dir" 2>/dev/null || true
    tmp=$(mktemp "$dir/.$(basename "$target").XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 0644 "$tmp"
    # Atomic within the directory, so the collector never serves half a file.
    mv -f "$tmp" "$target"
}

# The session id the last mcp_initialize was given, and the marker that -w uses
# to put it after the response body rather than mixed into it.
MCP_SESSION_ID=""
MCP_SID_MARKER='__mcp_session_id__'

# MCP servers that are not on npm-network, as "<container>:<port>". One entry
# today: crowdsec-mcp runs with Network=host, because its upstream (the CrowdSec
# LAPI) is a loopback bind that a bridge container cannot reach -- pasta's
# host.containers.internal lands on the host's LAN address, not its loopback.
# Such a unit binds its own port on the host's loopback instead of publishing
# one, so it is reached as 127.0.0.1:<port> through netcheck-host, the same
# client nginx-proxy-manager's admin API needs. Declared once here so every
# caller (verify.sh, rotate.sh, monitor.sh, spend-audit.sh) keeps naming the
# container and gets the right transport.
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
# the protocol revision, not this stack's.
MCP_INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"monitor","version":"0"}}}'

# Authenticate against CONTAINER's MCP endpoint: do the initialize handshake,
# print the response body and record the session id in MCP_SESSION_ID. Returns 1
# when the server did not answer with a serverInfo result. The bearer token goes
# in a curl config on stdin, so it never reaches the host's argv. CONTAINER is
# the unit's container name; MCP_HOST_NETNS above decides where it is reached.
#   mcp_initialize CONTAINER TOKEN [timeout]
mcp_initialize() {
    local c="$1" token="$2" t="${3:-20}" resp
    MCP_SESSION_ID=""
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
            -X POST "$(mcp_base "$c")/mcp" -d "$call" 2>/dev/null
}

# Call one tool on an MCP streamable-HTTP endpoint and print the response body.
# Prints nothing and returns 1 when the handshake fails. Used by
# scripts/monitor.sh and scripts/spend-audit.sh; verify.sh calls the two halves
# itself, because it also proves the 401 gate and reports the session id.
#   mcp_call CONTAINER TOKEN TOOL ARGS_JSON [timeout]
mcp_call() {
    local c="$1" token="$2" tool="$3" args="$4" t="${5:-20}"
    mcp_initialize "$c" "$token" "$t" >/dev/null || return 1
    mcp_tool_call "$c" "$token" "$tool" "$args" "$t"
}

# Print a script's leading comment block (shebang excluded) for --help. Stops at
# the first non-comment line, so keep each script's header one contiguous block.
usage_header() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$1"
}

# Where the stack keeps everything it must not lose: the daemon data dirs, the
# nginx-proxy-manager data, AND the config/secrets. That way a rebuild only has
# to preserve one directory. Resolved in this order, then persisted so it is
# asked once per host:
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

# Give the data dir a container label when SELinux is enforcing and it does not
# have one. The units mount their subdirectories with `:z`/`:Z`, which podman
# relabels rootlessly on every start, so only a path podman cannot relabel (one
# the login user does not own -- a freshly formatted disk is often unlabeled_t)
# needs help. We attempt an unprivileged label and, if even that fails, print
# the exact root commands instead of running sudo: nothing here (or in
# deploy.sh, install.sh, verify.sh) uses sudo.
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
# separate disk must already be created and owned by you (the README shows the
# one-time commands); a path we cannot prepare is a clear error rather than an
# implicit sudo. Only the top-level data dir is owned by us -- subdirs like
# bitcoin are deliberately the image uid.
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
# deploy/services.toml is the ONE declaration of the public surface: the
# *_HOST domain names, MCP_HOSTS, ONION_SERVICES, the proxy hosts and the
# status page's monitors (npm-hosts.sh and kuma-monitors.sh reconcile it
# through their Python cores, scripts/stackctl/). stack.conf no longer
# carries those lists; this helper is how a bash caller gets them back under
# the SAME variable names it always sourced, by eval'ing the shell emission
# of `python3 -m stackctl manifest shell` -- NAME='value' lines and array
# assignments, nothing else. python3 is a bootstrap dependency (agent-mcp
# already needed it).
#
# The one thing it must never do is run inside stack.conf: bootstrap.sh
# sources that file standalone (curl | bash, no checkout present), so
# stack.conf stays plain data and the manifest load is each caller's own
# explicit step, right after it sources stack.conf.
#
#   . "$REPO_DIR/stack.conf"; load_manifest     # then $MCP_HOSTS etc. exist
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
