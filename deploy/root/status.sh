#!/usr/bin/env bash
# The one status-file writer and Go-duration parser both privilege tiers use.
#
# Installed to /etc/stack-ids/status.sh by `deploy/install.sh --root`. Sourced,
# never executed:
#   . /etc/stack-ids/status.sh
#
# One implementation, two paths to it. bouncer.sh and audit-report.sh run as
# root from /etc/stack-ids and must not read the user-writable checkout, so they
# source the installed copy; scripts/lib.sh sources this file out of the
# checkout, so a change here reaches the user tier without a second copy to keep
# in step. That is why nothing in this file may depend on lib.sh: it is bash and
# coreutils only, and must load with no stack.conf, no podman, no config.
#
# The status contract, which scripts/monitor.sh and verify.sh depend on:
#   * KEY=VALUE, read with env_value (sed), never sourced -- a status file is
#     data, not code;
#   * written atomically, so a sweep never reads half a line;
#   * ok_epoch is the last SUCCESS and is carried through a failure or skip, so
#     a job that skips forever (no disk space, no bouncer key, a dead LAPI)
#     cannot look healthy just because its timer fired.
#
# A status write is best-effort: the job already did its work, and turning a full
# disk into a failed unit would hide the job's own verdict. Callers warn; the
# monitor sees the stale ok_epoch.

# Echo the value of KEY from a KEY=VALUE file (first match). Never sources it,
# and strips a trailing CR so a CRLF file still parses.
env_value() {
    local file="$1" key="$2"
    [ -s "$file" ] || return 0
    sed -n "s/^$key=//p" "$file" | head -n1 | tr -d '\r'
}

# lib.sh's warn(), without depending on lib.sh. Same "WARNING: ..." on stderr, so
# a root run and a user run read the same way.
_status_note() { printf 'WARNING: %s\n' "$*" >&2; }

# Write stdin to PATH in one step: a hidden temp beside it, the mode, then a
# rename in the same directory. The rename is the point -- a reader sees the old
# file or the new one, never half of either, wherever a timer writes and a sweep
# reads.
#
# DIR-MODE is for the case where the reader owns neither directory nor file:
# node-exporter runs as uid 65534 (a *subuid* under rootless podman), and if
# either mode slips the collector serves nothing, the quietest way to lose every
# metric. The root tier passes no third argument.
#
#   printf 'stack_x 1\n' | write_atomic "$path" 644 755
#
# On failure the destination is untouched and the temp file removed.
write_atomic() { # path mode [dir-mode]
    local path="$1" mode="$2" dmode="${3:-}" dir tmp
    dir=$(dirname "$path")
    mkdir -p "$dir" || return 1
    [ -z "$dmode" ] || chmod "$dmode" "$dir" 2>/dev/null || true
    tmp=$(mktemp "$dir/.$(basename "$path").XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod "$mode" "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Write a status file: the caller supplies the path, the line naming the unit
# that scheduled it, the result, a detail (newlines flattened to one line), and
# its own extra KEY=VALUE fields.
status_write() { # path header result detail [KEY=VALUE ...]
    local path="$1" header="$2" result="$3" detail="$4"
    shift 4
    local now prev_ok="" ok_epoch line
    now=$(date +%s)
    [ -f "$path" ] && prev_ok=$(env_value "$path" ok_epoch)
    case "$prev_ok" in ''|*[!0-9]*) prev_ok="" ;; esac
    if [ "$result" = ok ]; then ok_epoch="$now"; else ok_epoch="$prev_ok"; fi
    if ! {
        printf '%s\n' "$header"
        printf 'time=%s\n' "$(date -Is)"
        printf 'epoch=%s\n' "$now"
        printf 'result=%s\n' "$result"
        printf 'ok_epoch=%s\n' "$ok_epoch"
        for line in "$@"; do
            printf '%s\n' "$line"
        done
        printf 'detail=%s\n' "$(printf '%s' "$detail" | tr '\n' ' ')"
    } | write_atomic "$path" 644; then
        _status_note "could not write $path"
    fi
    return 0
}

# "1m30s" / "500ms" / "1h2m3.5s" -> MILLIseconds. Podman and CrowdSec's LAPI
# both print Go duration strings with an optional fraction on any component, so
# each is parsed by its unit and summed. Three details are load-bearing: `ms`
# before `m` in the alternation, or "500ms" reads as 500 minutes; `10#`, or
# "08m" is octal; and the fraction padded to three digits, because bash has no
# arithmetic on it. Unparsable input (or an unset field) is 0.
#
# The bouncer floors this answer and clamps it; wait_healthy rounds it up
# (dur_s in lib.sh). The parse is the shared part, the rounding is not.
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
