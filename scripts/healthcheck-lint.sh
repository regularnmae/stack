#!/usr/bin/env bash
# Check every container unit against the healthcheck contract (AGENTS.md,
# "Healthchecks follow a contract"). Reads the TEMPLATES in deploy/, not the
# rendered units in ~/.config/containers/systemd: this answers "does the repo
# still say the same thing about health", which is a question about a commit,
# not about a host. CI runs it; an operator runs it after editing a unit.
#
#   ./scripts/healthcheck-lint.sh           # fail on any violation
#   ./scripts/healthcheck-lint.sh --strict  # also fail on waivers (a release gate)
#
# The rules, and why each exists:
#
#   HC001  a unit with HealthCmd must set Interval/StartPeriod/Retries/Timeout.
#          Podman's defaults are not a contract: the timeout default (30s) is
#          half of a 60s interval, and nothing in the file says so.
#   HC002  every container unit that is not Type=oneshot is either probed or
#          declared healthless in stack.conf with a reason. A new unit cannot
#          quietly ship without one.
#   HC003  the declaration and the units agree in both directions: a name in
#          HEALTHLESS_UNITS must not carry a HealthCmd, and vice versa.
#   HC004  HealthInterval is 30s (HTTP apps) or 60s (daemons, stores).
#   HC005  HealthRetries is 3, or 5 with a reason (a slow starter, not a flaky
#          probe: retries hide a real outage for interval x retries).
#   HC006  HealthTimeout is explicit, 5-20s, and at least as long as the HTTP
#          probe's own bound, else podman kills a probe that was still working.
#   HC007  an HTTP probe fails on non-2xx, discards the body and bounds itself.
#          The body is otherwise kept in the health log, and an unbounded probe
#          hangs for podman's default instead of its own timeout.
#   HC008  HealthOnFailure=kill, so the restart is systemd's and monitor.sh's
#          NRestarts delta sees it. `restart` restarts the container inside
#          podman: the unit stays active and a container flapping every 30s
#          reports "no unit restarted". monero-wallet-rpc is the one exemption
#          (red for a whole refresh; killing it restarts the refresh).
#
# A rule can be waived for ONE unit with an inline comment carrying the code and
# the reason, so the exemption lives beside the thing it is about:
#
#   # health-lint: HC005 5 retries -- the image's entrypoint migrates its DB
#
# Waivers are printed on every run, including passing ones, so they stay visible
# instead of rotting into the default.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --strict) STRICT=1 ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# The healthless declaration lives in the manifest so verify.sh and this lint
# read the same list. Sourcing it is how deploy.sh and verify.sh read every
# other declaration too; it sets defaults and runs nothing.
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# dur_s, shared with wait_healthy: the same parser reads a unit's durations here
# and at deploy time.
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"
HEALTHLESS_UNITS=("${HEALTHLESS_UNITS[@]:-}")

fails=0 waivers=0
bad() { printf '  FAIL %-22s [%s] %s\n' "$1" "$2" "$3"; fails=$((fails+1)); }
waived() { printf '  skip %-22s [%s] %s (%s)\n' "$1" "$2" "$3" "$4"; waivers=$((waivers+1)); }

# A waiver is the code plus the text after it, on any comment line in the unit.
# Matching the code as a word keeps HC001 from being waived by HC0010.
waiver_for() { # file code -> reason text, or nothing
    local file="$1" code="$2"
    sed -n "s/.*# health-lint: *${code} *//p" "$file" 2>/dev/null | head -n1
}

kv() { # file key -> the value of the first `key=` line
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

# name -> the unit template that renders it. The .in templates are the
# secret-bearing ones (rendered by install.sh, invisible to Renovate); they are
# units like any other and carry the same contract.
unit_files=()
for f in "$REPO_DIR"/deploy/*.container "$REPO_DIR"/deploy/*.container.in \
         "$REPO_DIR"/deploy/root/*.container; do
    [ -f "$f" ] || continue
    unit_files+=("$f")
done

# Declared healthless, by name. The reason after `|` is documentation; the name
# is what this lint and verify.sh compare against.
declare -A DECLARED=() DECLARED_REASON=()
for entry in "${HEALTHLESS_UNITS[@]}"; do
    [ -n "$entry" ] || continue
    name="${entry%%|*}"
    reason="${entry#*|}"
    if [ "$name" = "$reason" ] || [ -z "$reason" ]; then
        bad "$name" HC003 "HEALTHLESS_UNITS entry has no reason (name|why)"
        continue
    fi
    DECLARED["$name"]=1
    DECLARED_REASON["$name"]="$reason"
done

printf 'Healthcheck contract (deploy/, %d templates)\n' "${#unit_files[@]}"

declare -A SEEN=()
for f in "${unit_files[@]}"; do
    name=$(basename "$f")
    name=${name%.in}
    name=${name%.container}
    SEEN["$name"]=1
    fails_before=$fails

    hcmd=$(kv "$f" HealthCmd)
    oneshot=$(kv "$f" Type)
    onfail=$(kv "$f" HealthOnFailure)

    # --- healthless / oneshot ------------------------------------------------
    if [ -z "$hcmd" ]; then
        if [ "$oneshot" = "oneshot" ]; then
            continue    # the job's exit status is its health; nothing to probe
        fi
        if [ -n "${DECLARED[$name]:-}" ]; then
            printf '  ok   %-22s healthless: %s\n' "$name" "${DECLARED_REASON[$name]}"
            continue
        fi
        w=$(waiver_for "$f" HC002)
        if [ -n "$w" ]; then
            waived "$name" HC002 "no HealthCmd" "$w"
        else
            bad "$name" HC002 "no HealthCmd and not declared in HEALTHLESS_UNITS"
        fi
        continue
    fi

    if [ -n "${DECLARED[$name]:-}" ]; then
        bad "$name" HC003 "declared healthless in stack.conf but sets HealthCmd"
    fi

    # --- the five keys ------------------------------------------------------
    interval=$(kv "$f" HealthInterval)
    start=$(kv "$f" HealthStartPeriod)
    retries=$(kv "$f" HealthRetries)
    timeout=$(kv "$f" HealthTimeout)
    missing=""
    [ -n "$interval" ] || missing="$missing HealthInterval"
    [ -n "$start" ]    || missing="$missing HealthStartPeriod"
    [ -n "$retries" ]  || missing="$missing HealthRetries"
    [ -n "$timeout" ]  || missing="$missing HealthTimeout"
    if [ -n "$missing" ]; then
        w=$(waiver_for "$f" HC001)
        if [ -n "$w" ]; then
            waived "$name" HC001 "missing:$missing" "$w"
        else
            bad "$name" HC001 "HealthCmd without:$missing"
        fi
    fi

    # --- vocabulary ---------------------------------------------------------
    case "$interval" in
        ''|30s|60s) ;;
        *) w=$(waiver_for "$f" HC004)
           if [ -n "$w" ]; then waived "$name" HC004 "interval $interval" "$w"
           else bad "$name" HC004 "HealthInterval=$interval (30s or 60s)"; fi ;;
    esac
    case "$retries" in
        ''|3|5) ;;
        *) w=$(waiver_for "$f" HC005)
           if [ -n "$w" ]; then waived "$name" HC005 "retries $retries" "$w"
           else bad "$name" HC005 "HealthRetries=$retries (3, or 5 with a reason)"; fi ;;
    esac
    if [ "$retries" = "5" ] && [ -z "$(waiver_for "$f" HC005)" ]; then
        bad "$name" HC005 "HealthRetries=5 needs a '# health-lint: HC005' reason"
    fi

    # --- timeout ------------------------------------------------------------
    if [ -n "$timeout" ]; then
        ts=$(dur_s "$timeout")
        if [ "$ts" -lt 5 ] || [ "$ts" -gt 20 ]; then
            w=$(waiver_for "$f" HC006)
            if [ -n "$w" ]; then waived "$name" HC006 "timeout $timeout" "$w"
            else bad "$name" HC006 "HealthTimeout=$timeout (5-20s)"; fi
        fi
    fi

    # --- HTTP probe hygiene -------------------------------------------------
    case "$hcmd" in
        curl*)
            why=""
            printf '%s' "$hcmd" | grep -qE -- '(^| )(-f|--fail)' || why="$why no-fail"
            printf '%s' "$hcmd" | grep -qE -- '-o /dev/null|--output /dev/null' || why="$why body-kept"
            bound=$(printf '%s' "$hcmd" | grep -oE -- '(--max-time|-m) [0-9]+' | grep -oE '[0-9]+$' | head -n1)
            [ -n "$bound" ] || why="$why unbounded"
            ;;
        wget*)
            why=""
            printf '%s' "$hcmd" | grep -qE -- '-O /dev/null|--output-document=/dev/null' || why="$why body-kept"
            bound=$(printf '%s' "$hcmd" | grep -oE -- '(-T|--timeout)[= ]+[0-9]+' | grep -oE '[0-9]+$' | head -n1)
            [ -n "$bound" ] || why="$why unbounded"
            printf '%s' "$hcmd" | grep -qE -- '(-t 1|-t=1|--tries=1)' || why="$why retries-default"
            ;;
        *) why="" bound="" ;;
    esac
    if [ -n "$why" ]; then
        w=$(waiver_for "$f" HC007)
        if [ -n "$w" ]; then waived "$name" HC007 "http probe:$why" "$w"
        else bad "$name" HC007 "http probe:$why"; fi
    fi
    # A probe bound longer than podman's timeout is killed mid-request, which
    # reads as a failure of the service instead of of the probe.
    if [ -n "$bound" ] && [ -n "$timeout" ] && [ "$bound" -gt "$(dur_s "$timeout")" ]; then
        w=$(waiver_for "$f" HC006)
        if [ -n "$w" ]; then waived "$name" HC006 "probe $bound""s > timeout $timeout" "$w"
        else bad "$name" HC006 "probe bound ${bound}s exceeds HealthTimeout=$timeout"; fi
    fi

    # --- restart ownership --------------------------------------------------
    if [ "$onfail" != "kill" ]; then
        w=$(waiver_for "$f" HC008)
        if [ -n "$w" ]; then
            waived "$name" HC008 "HealthOnFailure=${onfail:-unset}" "$w"
        else
            bad "$name" HC008 "HealthOnFailure=${onfail:-unset} (kill: systemd owns the restart)"
        fi
    fi

    # Everything checked out for this unit: one quiet line, so a passing run
    # still lists what it looked at (and names the cadence it accepted).
    [ "$fails" -eq "$fails_before" ] && printf '  ok   %-22s %s/%s/%s every %s\n' \
        "$name" "${timeout}" "${retries}x" "$start" "$interval"
done

# --- the declaration must not name a unit that does not exist ---------------
for name in "${!DECLARED[@]}"; do
    [ -n "${SEEN[$name]:-}" ] || bad "$name" HC003 "declared healthless but no such unit template"
done

printf '\n%d violation(s), %d waiver(s)\n' "$fails" "$waivers"
if [ "$fails" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = 1 ] && [ "$waivers" -gt 0 ]; then
    printf 'strict: %d waiver(s) must be resolved before a release\n' "$waivers"
    exit 1
fi
