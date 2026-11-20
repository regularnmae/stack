#!/usr/bin/env bash
# Record the postgres-dump unit's verdict for the monitor.
#
#   scripts/dump-status.sh postgres-dump "$SERVICE_RESULT" "$EXIT_STATUS"
#
# deploy/postgres-dump.container runs this from [Service] ExecStopPost, after
# both a successful pg_dumpall and a failed one. The unit's exit code is the
# dump's; this file only names the cause, because monitor.sh already fails on
# the dump file's mtime (the effect). The leading `-` on the unit's ExecStopPost
# keeps a write failure from turning a good dump into a failed unit.
#
# install.sh stages this into $DATA_DIR/bin, so the path is the data dir and the
# writer is the installed /etc/stack-ids/status.sh, never the checkout. The
# environment overrides exist for tests/test-dump-status.sh.
set -uo pipefail

case "${1:-}" in
    -h|--help)
        printf 'usage: %s <job> <SERVICE_RESULT> <EXIT_STATUS>\n' "$0"
        exit 0 ;;
esac

JOB="${1:-postgres-dump}"
RESULT="${2:-unknown}"
STATUS="${3:-}"

DATA_DIR="${STACK_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATUS_SH="${STACK_STATUS_SH:-/etc/stack-ids/status.sh}"
if [ ! -r "$STATUS_SH" ]; then
    printf 'WARNING: %s is missing; cannot record the %s verdict\n' "$STATUS_SH" "$JOB" >&2
    exit 0
fi
# shellcheck source=/dev/null
. "$STATUS_SH"

DUMP="$DATA_DIR/postgres-dump/all.sql"
verdict_init "$DATA_DIR/audit/$JOB.status" scripts/dump-status.sh \
    "deploy/$JOB.container"

case "$RESULT" in
    success)
        if [ -s "$DUMP" ]; then
            verdict_write ok "pg_dumpall completed; postgres-dump/all.sql was replaced"
        else
            verdict_write fail \
                "the unit reported success but postgres-dump/all.sql is missing or empty"
        fi ;;
    timeout)
        verdict_write fail \
            "postgres-dump.service timed out; the previous all.sql was kept" ;;
    exit-code)
        verdict_write fail \
            "postgres-dump.service exited ${STATUS:-?}; the previous all.sql was kept" ;;
    signal)
        verdict_write fail \
            "postgres-dump.service was killed by a signal; the previous all.sql was kept" ;;
    resources)
        verdict_write fail \
            "postgres-dump.service hit a resource limit; the previous all.sql was kept" ;;
    protocol)
        verdict_write fail \
            "postgres-dump.service failed to start; the previous all.sql was kept" ;;
    watchdog)
        verdict_write fail \
            "postgres-dump.service hit its watchdog; the previous all.sql was kept" ;;
    *)
        verdict_write fail \
            "postgres-dump.service ended with ${RESULT}${STATUS:+ (status $STATUS)}; the previous all.sql was kept" ;;
esac

# ExecStopPost must never change the unit's result.
exit 0
