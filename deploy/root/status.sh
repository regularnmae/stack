#!/usr/bin/env bash
# The status-file writer shared by the root tier's two reporters.
#
# Sourced, not executed:
#   . /etc/stack-ids/status.sh
#
# This is deploy/root/'s own copy of scripts/lib.sh's status_write. It has to be
# a copy: bouncer.sh and audit-report.sh run as root from /etc/stack-ids and must
# not read the user-writable checkout, and lib.sh pulls in stack.conf, podman and
# the whole host-side toolchain besides. Everything here is coreutils plus bash,
# and tests/test-status.sh runs this file and lib.sh over one table so the two
# cannot drift apart.
#
# The contract, which scripts/monitor.sh and verify.sh depend on:
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

# stdin -> PATH atomically: a hidden temp beside it, the mode, then a rename, so
# a reader sees the old file or the new one and never half of either.
write_atomic() { # path mode
    local path="$1" mode="$2" dir tmp
    dir=$(dirname "$path")
    mkdir -p "$dir" || return 1
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
