#!/bin/sh
# Fetch the ET Open ruleset into /var/lib/suricata/rules.
#
# Two callers, one command:
#   start.sh                      best effort: a cached set is better than none,
#                                 so a fetch failure is not fatal;
#   stack-suricata-update.timer   --strict: a fetch failure is a failure, and
#                                 suricata-update's own rule test stays enabled
#                                 before the new file replaces the old one.
# --no-reload in both: start.sh is about to exec the engine, and the weekly host
# job sends the reload only after this command exits 0.
set -eu

RULES=/var/lib/suricata/rules
CONF=/etc/suricata-stack

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

mkdir -p "$RULES"

if ! command -v suricata-update >/dev/null 2>&1; then
    printf 'suricata-update is not installed in this image\n' >&2
    exit 127
fi

set -- --no-reload --disable-conf "$CONF/disable.conf"
if [ "$STRICT" = 1 ]; then
    # --fail turns "the mirror is down, use the cached copy" into a non-zero
    # exit. That is what makes the weekly status file tell the truth; the start
    # mode deliberately keeps the old behaviour.
    set -- "$@" --fail
else
    set -- "$@" --no-test
fi

exec suricata-update "$@"
