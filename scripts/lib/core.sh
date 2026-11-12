# shellcheck shell=bash
# The vocabulary every other script starts with: the one logger, the
# sed-escaping and root-template render shared by install.sh and verify.sh,
# and the small parsers the probes and jobs read with. dur_s/dur_valid are
# the exception: they wrap dur_ms, which deploy/root/status.sh owns so both
# tiers parse a duration the same way (docs/units.md).

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

# Print a script's leading comment block (shebang excluded) for --help. Stops at
# the first non-comment line, so keep each script's header one contiguous block.
usage_header() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$1"
}
