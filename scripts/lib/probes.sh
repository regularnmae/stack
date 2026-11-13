# shellcheck shell=bash
# Reaching a service and deciding whether it is up: the netcheck container the
# bridge-network checks speak through, the host's own curl for loopback binds,
# and the health/wait contract in docs/units.md.

# The image the bridge-network checks speak through: a curl client (see
# netcheck/Containerfile), built by deploy/install.sh. A container, not the
# host's curl, because a probe resolves a service by its npm-network container
# name, and several app images carry no curl. The checks exec into a long-lived
# container rather than starting one per probe: each `podman run` added a veth
# pair and a cgroup scope, which the kernel logs per step (docs/logs.md).
#
# Host-network surfaces (nginx-proxy-manager's :80/:443/:81, crowdsec-mcp's
# 127.0.0.1:8113) are read by host_curl below: the checks address them on host
# loopback, which a bridge container cannot reach, and the host already carries
# curl for the alert path.
NETCHECK_IMAGE="${NETCHECK_IMAGE:-localhost/netcheck:local}"
NETCHECK_CONTAINER="${NETCHECK_CONTAINER:-netcheck}"

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

# The same from the host's own namespace, for services that are not on
# npm-network: nginx-proxy-manager binds :80/:443/:81 itself (docs/proxy.md) and
# is read on 127.0.0.1, so its admin API is 127.0.0.1:81 and a vhost it fronts
# is reached by looping back to this host; crowdsec-mcp binds 127.0.0.1:8113 for
# the same reason.
#   host_curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:81/
# -q and --noproxy keep a ~/.curlrc or *_proxy in the operator's environment out
# of a probe, so a host-local check answers the same way every time.
host_curl() {
    command -v curl >/dev/null 2>&1 || {
        printf 'ERROR: host curl is missing; install curl (bootstrap.sh does) -- the alert path needs it too\n' >&2
        return 127
    }
    command curl -q --noproxy '*' "$@"
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
