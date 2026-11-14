#!/bin/sh
# Container entrypoint for the Suricata sensor.
#
# The image's own entrypoint is bypassed: it accepts a bare "-i <iface>" and
# runs with the shipped 94 KB config, while this stack needs two interfaces
# (enp8s0 and lo), a short config of its own, and its rules on the data disk.
#
# What happens here, in order:
#   1. the repo's local.rules is copied where default-rule-path points, so a
#      config change lands without rebuilding anything;
#   2. update.sh fetches ET Open, best effort: a host with no internet (or a
#      failed update) keeps the previous set, and a fresh host gets an empty
#      file so Suricata still starts on local.rules alone -- a sensor that
#      refuses to start because the ruleset could not be downloaded is worse
#      than one that starts with ten rules. The same script's --strict mode is
#      the weekly stack-suricata-update job's path (docs/ids.md);
#   3. exec suricata, so the container's PID 1 is the engine and its exit
#      status is the unit's.
#
# Runs as root inside a rootful container on the host network: AF_PACKET needs
# CAP_NET_RAW in the init namespace, which a rootless container cannot have.
set -eu

RULES=/var/lib/suricata/rules
CONF=/etc/suricata-stack

mkdir -p "$RULES" /var/log/suricata

# The enforcement feed (see the second eve-log output in suricata.yaml). CrowdSec
# may be tailing it already; an empty file at sensor start is better than a
# stat error, and `:` does not truncate a file the previous run left behind.
[ -e /var/log/suricata/alerts.json ] || : > /var/log/suricata/alerts.json

cp -f "$CONF/rules/local.rules" "$RULES/local.rules"

# ET Open. update.sh owns the command and its flags; this is its best-effort
# mode (no rule test, no --fail), because we are about to start the engine and a
# cached ruleset beats refusing to start. Timeout so a stalled mirror cannot
# keep the unit "activating" forever.
if [ -x "$CONF/update.sh" ]; then
    if timeout 180 "$CONF/update.sh" \
        >/var/log/suricata/suricata-update.log 2>&1; then
        echo "suricata: ET Open rules updated"
    else
        echo "suricata: suricata-update failed (see /var/log/suricata/suricata-update.log); keeping the previous ruleset" >&2
    fi
else
    echo "suricata: $CONF/update.sh is missing; keeping the previous ruleset" >&2
fi
[ -s "$RULES/suricata.rules" ] || : > "$RULES/suricata.rules"

# --af-packet with no device: capture mode from the yaml's two interfaces.
# Without it, Suricata 8 refuses to start ("USAGE: suricata..." and exit 1) --
# the config alone does not imply a runmode, which cost a debugging session and
# is why the flag is spelled out rather than left to detection.
exec suricata -c "$CONF/suricata.yaml" --af-packet --pidfile /run/suricata.pid "$@"
