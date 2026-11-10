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
#                                      (the follow to use: `podman logs -f`
#                                       refuses while podman's events go to a
#                                       file -- see README's "Logs and history")
#   scripts/logs.sh --health                   # is the pipeline still shipping?
#
# This is the CLI over the same store the LogsQL UI reads: journald -> vector ->
# victoria-logs (127.0.0.1:9428, no public host). Two things journald never sees
# are shipped by the same shipper as files -- Suricata's eve.json, and
# nginx-proxy-manager's access and error logs -- so `--container
# nginx-proxy-manager` returns both NPM's own output and every public request.
# The UI is one SSH tunnel away (`ssh -L 9428:127.0.0.1:9428 host`, then
# /select/vmui); this script exists so the common question -- "what did
# everything do around 03:10?" -- does not need a browser or a LogsQL query.
#
# `--since` takes VictoriaLogs durations: 15m, 2h, 7d. Times are printed in UTC,
# which is what the store keeps; the journal on the host shows local time.
#
# Queries go through net_curl (scripts/lib.sh), i.e. curl inside the long-lived
# netcheck container on npm-network: victoria-logs is addressed by its container
# name, and that keeps this CLI independent of the host's own package set (the
# monitor needs a host curl; nothing else does). Read-only and safe to run at
# any time. A failed request is an error, not an empty result: a refused
# connection, a rejected query (a bad --since, an invalid --grep regex) or
# malformed JSON exits non-zero with the store's own reason, and only a
# completed query with no rows prints "no matching entries".
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
  --container NAME     only this container (repeatable; values are OR-ed)
  --unit NAME          only this systemd unit (repeatable; together with
                       --container it means either source)
  --grep REGEX         keep entries matching an RE2 regular expression
  --priority LEVEL     this severity and worse: emerg|alert|crit|err|warning|
                       notice|info|debug
  --limit N            entries to return (default 200; stats: top N groups)
  --follow             stream new entries instead of a window (^C to stop)
  --stats              count entries per container for the window
  --health             exit non-zero when the pipeline is not shipping
                       (includes the nginx-proxy-manager file source)
  --window S           --health: how recent the newest entry must be (default 900)
  --json               print the store's JSON, one object per line
  --no-color           plain output even on a TTY
  --quiet              no human summary (for scripts)
  -h, --help           this text
EOF
}

need_arg() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        die "$1 needs a value"
    fi
}

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
        # The store's names are VRL's to_syslog_level() output, i.e. the SHORT
        # RFC forms -- "info", not "informational". Listing the long form here
        # made `--priority info` ("everything") silently drop every info entry,
        # which is the one thing it must not do.
        6|info|informational) printf 'emerg,alert,crit,err,warning,notice,info' ;;
        7|debug)             printf 'emerg,alert,crit,err,warning,notice,info,debug' ;;
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

# One `field:in("v1","v2")` filter for the repeated flags. Repeating a filter in
# LogsQL is an AND (`container:"a" container:"b"`), and no row can carry two
# container labels or two units -- so the list belongs inside in(), not beside
# it. Values are quoted so a name with `-`, `:` or a space stays one phrase.
in_filter() { # field value...
    local field="$1" out="" v
    shift
    for v in "$@"; do
        out+="${out:+,}\"$(escape_ql "$v")\""
    done
    printf '%s:in(%s)' "$field" "$out"
}

build_query() { # since -> a LogsQL query string
    local q="_time:$1" levels sources=()
    # --container and --unit together mean either source: one row can never be
    # both, so the groups are OR-ed rather than appended as separate ANDs.
    if [ "${#CONTAINERS[@]}" -gt 0 ]; then
        sources+=("$(in_filter container "${CONTAINERS[@]}")")
    fi
    if [ "${#UNITS[@]}" -gt 0 ]; then
        sources+=("$(in_filter unit "${UNITS[@]}")")
    fi
    case "${#sources[@]}" in
        1) q+=" ${sources[0]}" ;;
        2) q+=" (${sources[0]} OR ${sources[1]})" ;;
    esac
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
        jq --unbuffered -c .
        return
    fi
    jq --unbuffered -r '
        [ ._time,
          (.container // .unit // .SYSLOG_IDENTIFIER // "-"),
          (.priority // "-"),
          (._msg | tostring | rtrimstr("\n") | gsub("\n"; " ⏎ ")) ] | @tsv
    ' | while IFS=$'\t' read -r ts src prio msg; do
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

# One request to the LogsQL query endpoint. Sets $body; a transport failure or
# an HTTP error is fatal, because the alternative is an outage -- or a query the
# store rejected -- reading as "no matching entries". VictoriaLogs answers a
# rejected query with HTTP 4xx and a one-line plain-text reason, so the status
# and the body are both load-bearing: curl's -f would throw the reason away.
vl_query() { # path [curl args...]
    local path="$1" raw rc code
    shift
    raw=$(net_curl -sS -m 30 -w '__VL_HTTP__%{http_code}' "$@" "$LOGS_URL$path") || rc=$?
    if [ "${rc:-0}" -ne 0 ]; then
        die "log store query failed (curl ${rc}): $LOGS_URL is not answering"
    fi
    code=${raw##*__VL_HTTP__}
    body=${raw%__VL_HTTP__*}
    case "$code" in
        2??) ;;
        *) die "log store rejected the query (HTTP ${code:-?}): ${body:-no reason given}" ;;
    esac
}

if [ "$HEALTH" = 1 ]; then
    code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 5 "$LOGS_URL/health" 2>/dev/null) || code=""
    if [ "${code:-000}" != 200 ]; then
        printf 'log store unreachable: %s/health -> %s\n' "$LOGS_URL" "${code:-no answer}" >&2
        exit 1
    fi
    vl_query /select/logsql/query --get \
        --data-urlencode "query=_time:${WINDOW}s | stats count() as n"
    count=$(printf '%s' "$body" | jq -r '.n // empty' 2>/dev/null) || count=""
    case "$count" in
        ''|*[!0-9]*) die "log store returned an unreadable count: ${body:-empty response}" ;;
    esac
    if [ "$count" -eq 0 ]; then
        printf 'no log entries in the last %ss (vector stopped, or the store is not being written)\n' "$WINDOW" >&2
        exit 1
    fi
    # The NPM file source is the half journald cannot see, and it fails on its own:
    # an image update that moves the log path or changes log_format leaves vector
    # reading nothing, forever, with every unit green -- and CrowdSec reads the same
    # directory, so detection goes blind at the same moment. "No requests" is not a
    # fault on a quiet site, so the access log's own mtime decides: written inside
    # the window with no entries in the store means the source is not being read,
    # while both being old means nobody visited.
    resolve_data_dir
    vl_query /select/logsql/query --get \
        --data-urlencode "query=_time:${WINDOW}s log_type:\"npm_access\" | stats count() as n"
    npm_count=$(printf '%s' "$body" | jq -r '.n // empty' 2>/dev/null) || npm_count=""
    case "$npm_count" in
        ''|*[!0-9]*) die "log store returned an unreadable nginx-proxy-manager count: ${body:-empty response}" ;;
    esac
    if [ "$npm_count" -eq 0 ]; then
        newest_npm=""
        if [ -d "$DATA_DIR/npm/data/logs" ]; then
            newest_npm=$(find "$DATA_DIR/npm/data/logs" -name '*_access.log' -printf '%T@\n' 2>/dev/null \
                | sort -n | tail -1 | cut -d. -f1)
        fi
        case "$newest_npm" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$(( $(date +%s) - newest_npm ))" -le "$WINDOW" ]; then
                    printf 'no nginx-proxy-manager entries in the last %ss although its access log was written %ss ago (deploy/logs/vector.toml npm source is not reading %s)\n' \
                        "$WINDOW" "$(( $(date +%s) - newest_npm ))" "$DATA_DIR/npm/data/logs" >&2
                    exit 1
                fi ;;
        esac
    fi
    [ "$QUIET" = 1 ] || printf 'ok: %s entr%s in the last %ss\n' \
        "$count" "$([ "$count" = 1 ] && printf 'y' || printf 'ies')" "$WINDOW"
    exit 0
fi

if [ "$STATS" = 1 ]; then
    query="$(build_query "$SINCE") | stats by (container) count() as n | sort by (n desc) | limit $LIMIT"
    vl_query /select/logsql/query --get --data-urlencode "query=$query"
    if [ -z "$body" ]; then
        [ "$JSON" = 1 ] && exit 0
        printf 'no entries in the last %s\n' "$SINCE" >&2
        exit 0
    fi
    printf '%s\n' "$body" | jq empty >/dev/null 2>&1 \
        || die "log store returned malformed JSON"
    if [ "$JSON" = 1 ]; then
        printf '%s\n' "$body" | jq -c .
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
    # Tail announces a failure only as curl's exit status (the store's reason is
    # an HTTP body that would feed the formatter), so prove the query once
    # through the ordinary endpoint, where vl_query can report it.
    vl_query /select/logsql/query --get \
        --data-urlencode "query=$query" \
        --data-urlencode "limit=1"
    net_curl -sN -f -m 0 --get --data-urlencode "query=$query" \
        "$LOGS_URL/select/logsql/tail" | format_entries
    rcs=("${PIPESTATUS[@]}")
    case "${rcs[0]}" in
        0) [ "${rcs[1]}" -eq 0 ] || die "could not format the log stream" ;;
        # Requested stops: ^C, SIGTERM, and SIGPIPE when the consumer closes the
        # pipe (head -n, grep -m). None of them is a shipper failure.
        130|141|143) exit "${rcs[0]}" ;;
        *) die "log stream failed (curl ${rcs[0]})" ;;
    esac
    exit 0
fi

query=$(build_query "$SINCE")
vl_query /select/logsql/query --get \
    --data-urlencode "query=$query" \
    --data-urlencode "limit=$LIMIT"
if [ -z "$body" ]; then
    [ "$JSON" = 1 ] && exit 0
    printf 'no matching entries in the last %s\n' "$SINCE" >&2
    exit 0
fi
printf '%s\n' "$body" | jq empty >/dev/null 2>&1 \
    || die "log store returned malformed JSON"
printf '%s\n' "$body" | format_entries
exit 0
