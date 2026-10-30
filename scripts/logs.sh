#!/usr/bin/env bash
# Search the stack's logs, across every service at once.
#
#   scripts/logs.sh                            # the last 15 minutes, everything
#   scripts/logs.sh --since 1h                 # a wider window
#   scripts/logs.sh --since 2h --container lightningd
#   scripts/logs.sh --since 30m --grep 'WARN|ERR' --priority warning
#   scripts/logs.sh --unit monitor.service --since 24h
#   scripts/logs.sh --stats --since 24h        # entries per container: who is spamming
#   scripts/logs.sh --follow --container boltmesh-backend
#   scripts/logs.sh --health                   # is the pipeline still shipping?
#
# This is the CLI over the same store the LogsQL UI reads: journald -> vector ->
# victoria-logs (127.0.0.1:9428, no public host). The UI is one SSH tunnel away
# (`ssh -L 9428:127.0.0.1:9428 host`, then /select/vmui); this script exists so
# the common question -- "what did everything do around 03:10?" -- does not need
# a browser or a LogsQL query.
#
# `--since` takes VictoriaLogs durations: 15m, 2h, 7d. Times are printed in UTC,
# which is what the store keeps; the journal on the host shows local time.
#
# Queries go through net_curl (scripts/lib.sh), i.e. a throwaway curl container
# on npm-network: the host has no curl, and victoria-logs is addressed by its
# container name. Read-only and safe to run at any time.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

LOGS_URL="${LOGS_URL:-http://victoria-logs:9428}"

SINCE=15m
SINCE_SET=0
CONTAINERS=()
UNITS=()
GREP=""
PRIORITY=""
LIMIT=200
FOLLOW=0
STATS=0
HEALTH=0
QUIET=0
JSON=0
WINDOW=900
COLOR=0
[ -t 1 ] && COLOR=1

usage() {
    usage_header "$0"
    cat <<'EOF'

Options:
  --since DUR          window to read (default 15m; 30s, 90m, 2h, 7d)
  --container NAME     only this container (repeatable; the unit names in
                       README's "What runs")
  --unit NAME          only this systemd unit (repeatable; host scripts such as
                       monitor.service or ids.service)
  --grep REGEX         keep entries matching an RE2 regular expression
  --priority LEVEL     this severity and worse: emerg|alert|crit|err|warning|
                       notice|info|debug
  --limit N            entries to return (default 200; stats: top N groups)
  --follow             stream new entries instead of a window (^C to stop)
  --stats              count entries per container for the window
  --health             exit non-zero when the pipeline is not shipping
  --window S           --health: how recent the newest entry must be (default 900)
  --json               print the store's JSON, one object per line
  --no-color           plain output even on a TTY
  --quiet              no human summary (for scripts)
  -h, --help           this text
EOF
}

need_arg() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

# The severities at or above the requested one, worst first. LogsQL's in()
# matches any of them, so `--priority warning` means warning + err + crit... --
# what an operator means by "show me the bad ones". Defined before the argument
# loop because the loop validates --priority against it.
priority_levels() {
    case "$1" in
        0|emerg|emergency)   printf 'emerg' ;;
        1|alert)             printf 'emerg,alert' ;;
        2|crit|critical)     printf 'emerg,alert,crit' ;;
        3|err|error)         printf 'emerg,alert,crit,err' ;;
        4|warn|warning)      printf 'emerg,alert,crit,err,warning' ;;
        5|notice)            printf 'emerg,alert,crit,err,warning,notice' ;;
        6|info|informational) printf 'emerg,alert,crit,err,warning,notice,informational' ;;
        7|debug)             printf 'emerg,alert,crit,err,warning,notice,informational,debug' ;;
        *)                   die "unknown --priority level: $1" ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)    need_arg "$@"; SINCE="$2"; SINCE_SET=1; shift ;;
        --container) need_arg "$@"; CONTAINERS+=("$2"); shift ;;
        --unit)     need_arg "$@"; UNITS+=("$2"); shift ;;
        --grep)     need_arg "$@"; GREP="$2"; shift ;;
        --priority) need_arg "$@"; PRIORITY="$2"; shift ;;
        --limit)    need_arg "$@"; LIMIT="$2"; shift ;;
        --window)   need_arg "$@"; WINDOW="$2"; shift ;;
        --follow)   FOLLOW=1 ;;
        --stats)    STATS=1 ;;
        --health)   HEALTH=1 ;;
        --json)     JSON=1 ;;
        --no-color) COLOR=0 ;;
        --quiet)    QUIET=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

case "$LIMIT" in ''|*[!0-9]*) die "--limit needs a positive number" ;; esac
case "$WINDOW" in ''|*[!0-9]*) die "--window needs a positive number" ;; esac
# Fail on a misspelt level here, not with an empty in() the store rejects.
[ -n "$PRIORITY" ] && priority_levels "$PRIORITY" >/dev/null
netcheck_ready || exit 127

# Quote a value for a LogsQL phrase, then let --data-urlencode do the URL.
escape_ql() { printf '%s' "$1" | sed -e 's/[\\"]/\\&/g'; }

build_query() { # since -> a LogsQL query string
    local q="_time:$1" one levels
    for one in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
        q+=" container:\"$(escape_ql "$one")\""
    done
    for one in ${UNITS[@]+"${UNITS[@]}"}; do
        q+=" unit:\"$(escape_ql "$one")\""
    done
    [ -n "$GREP" ] && q+=" ~\"$(escape_ql "$GREP")\""
    if [ -n "$PRIORITY" ]; then
        levels=$(priority_levels "$PRIORITY")
        q+=" priority:in($levels)"
    fi
    printf '%s' "$q"
}

# One line per entry: time, source (container, else unit, else syslog tag),
# severity, message. Newlines inside a message become a visible separator so a
# traceback stays on one row instead of breaking the column layout.
format_entries() {
    if [ "$JSON" = 1 ]; then
        jq -c .
        return
    fi
    jq -r '
        [ ._time,
          (.container // .unit // .SYSLOG_IDENTIFIER // "-"),
          (.priority // "-"),
          (._msg | tostring | rtrimstr("\n") | gsub("\n"; " ⏎ ")) ] | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r ts src prio msg; do
        local colour="" reset="" when
        if [ "$COLOR" = 1 ]; then
            reset=$'\033[0m'
            case "$prio" in
                emerg|alert|crit|err) colour=$'\033[31m' ;;
                warning)              colour=$'\033[33m' ;;
                notice|informational) colour=$'\033[36m' ;;
                debug)                colour=$'\033[2m' ;;
            esac
        fi
        # RFC3339 -> HH:MM:SS.mmm (UTC); the date is implied by --since.
        when="${ts:11:12}"
        printf '%s %s%-24.24s%s %s\n' "${when:-?}" "$colour" "$src" "$reset" "$msg"
    done
}

if [ "$HEALTH" = 1 ]; then
    code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 5 "$LOGS_URL/health" 2>/dev/null) || code=""
    if [ "${code:-000}" != 200 ]; then
        printf 'log store unreachable: %s/health -> %s\n' "$LOGS_URL" "${code:-no answer}" >&2
        exit 1
    fi
    body=$(net_curl -s -m 10 --get \
        --data-urlencode "query=_time:${WINDOW}s | stats count() as n" \
        "$LOGS_URL/select/logsql/query" 2>/dev/null) || body=""
    count=$(printf '%s' "$body" | jq -r '.n // empty' 2>/dev/null) || count=""
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    if [ "$count" -eq 0 ]; then
        printf 'no log entries in the last %ss (vector stopped, or the store is not being written)\n' "$WINDOW" >&2
        exit 1
    fi
    [ "$QUIET" = 1 ] || printf 'ok: %s entr%s in the last %ss\n' \
        "$count" "$([ "$count" = 1 ] && printf 'y' || printf 'ies')" "$WINDOW"
    exit 0
fi

if [ "$STATS" = 1 ]; then
    query="$(build_query "$SINCE") | stats by (container) count() as n | sort by (n desc) | limit $LIMIT"
    body=$(net_curl -s -m 30 --get --data-urlencode "query=$query" \
        "$LOGS_URL/select/logsql/query" 2>/dev/null) || body=""
    if [ "$JSON" = 1 ]; then
        printf '%s\n' "$body" | jq -c .
        exit 0
    fi
    if ! printf '%s' "$body" | jq -e 'length > 0' >/dev/null 2>&1; then
        printf 'no entries in the last %s\n' "$SINCE" >&2
        exit 0
    fi
    printf '%8s  %s\n' "count" "container"
    printf '%s\n' "$body" | jq -r '[.n, (.container // "(no container)")] | @tsv' \
        | while IFS=$'\t' read -r n name; do printf '%8s  %s\n' "$n" "$name"; done
    exit 0
fi

if [ "$FOLLOW" = 1 ]; then
    # Streaming from "now": --since is meaningless here, so a window would only
    # replay history before following (unless the operator asked for it).
    [ "$SINCE_SET" = 1 ] || SINCE=1s
    query=$(build_query "$SINCE")
    net_curl -sN -m 0 --get --data-urlencode "query=$query" \
        "$LOGS_URL/select/logsql/tail" 2>/dev/null | format_entries
    exit 0
fi

query=$(build_query "$SINCE")
body=$(net_curl -s -m 30 --get \
    --data-urlencode "query=$query" \
    --data-urlencode "limit=$LIMIT" \
    "$LOGS_URL/select/logsql/query" 2>/dev/null) || body=""
if [ -z "$body" ] && [ "$JSON" = 0 ]; then
    printf 'no matching entries in the last %s\n' "$SINCE" >&2
    exit 0
fi
printf '%s\n' "$body" | format_entries
exit 0
