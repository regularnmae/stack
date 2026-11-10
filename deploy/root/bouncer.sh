#!/usr/bin/env bash
# stack-bouncer: apply CrowdSec's decisions to the host's nftables.
#
# Runs as root from deploy/root/stack-bouncer.timer (every minute), installed to
# /etc/stack-ids/bouncer.sh by `deploy/install.sh --root`. It is the ONLY thing in
# this stack that drops a packet, and it is deliberately dumb: CrowdSec owns the
# decision (who, why, how long), this owns the plumbing.
#
#   /etc/stack-ids/bouncer.sh --dry-run    print the rules, write nothing
#   /etc/stack-ids/bouncer.sh             apply, write $DATA_DIR/audit/bouncer.status
#
# Why not the upstream bouncer: docker.io/crowdsecurity/cs-firewall-bouncer is
# gone ("requested access to the resource is denied"), and the packaged one is a
# second daemon with its own config file, outside this repo. This reads the same
# LAPI and leaves the enforcement guard in one place (deploy/root/ipguard.py,
# installed beside this script) -- which matters, because the failure mode here
# is a ban on the operator's own monitoring.
#
# FAIL-OPEN, in the direction that matters: a failed or empty LAPI response
# leaves the existing bans alone (never "no decisions = unban everything"), while
# a failed nft apply leaves the previous ruleset in place. Losing enforcement is
# worse than losing detection, but neither may take the site down.
#
# The address classifier is the one part that is not shell: private space is a
# CIDR question, not a glob one, and python3 is already a bootstrap dependency.
# A classifier failure is fail-closed too -- nothing is applied and the status
# file says why.
set -uo pipefail

ENV_FILE=/etc/stack-ids/bouncer.env
NFT=/usr/sbin/nft
IPGUARD=${IPGUARD:-/etc/stack-ids/ipguard.py}
TABLE=stack_bans
SET_V4=banned_v4
SET_V6=banned_v6

# Rendered by install.sh --root: CROWDSEC_BOUNCER_KEY, LAPI (the host's own
# loopback -- crowdsec runs on the host network, so there is no published port
# between root and the decisions), DATA_DIR, and STACK_WAN_IP (the operator's
# public address, which is never enforced against). Root-owned 0600 -- root must
# not read its config from a file the stack user can edit.
# shellcheck source=/dev/null
. "$ENV_FILE"

# The status-file writer, installed beside this script by install.sh --root. A
# missing one is fatal rather than optional: without it this run cannot leave a
# verdict, and the monitor's age check is what notices. Failing here (nothing is
# applied) is the safe direction, exactly as an ipguard failure is.
if [ ! -r /etc/stack-ids/status.sh ]; then
    printf 'ERROR: /etc/stack-ids/status.sh is missing; re-run sudo ./bootstrap.sh\n' >&2
    exit 1
fi
# shellcheck source=status.sh
. /etc/stack-ids/status.sh

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# A private stderr sink for the classifier and nft. /tmp/stack-bouncer.err was
# a fixed, predictable path: an unprivileged user could pre-create it (or a
# symlink) and root's `2>` would follow it. mktemp is O_EXCL, and the trap
# removes it on every exit path.
errlog=$(mktemp) || exit 1
trap 'rm -f "$errlog"' EXIT

STATUS="$DATA_DIR/audit/bouncer.status"
# A dry run is a read, down to the directory: bouncer.status is the live verdict
# the monitor pages on, and an operator checking the rules while the LAPI is down
# must not replace it (nor create the audit dir on a host that has none yet).
[ "$DRY_RUN" = 1 ] || mkdir -p "$DATA_DIR/audit"

say() { [ "$DRY_RUN" = 1 ] && printf '%s\n' "$*"; return 0; }

# ---------------------------------------------------------------------------
# LAPI fetch: /dev/tcp, because the point is to avoid a dependency on an image
# or a package just to read one JSON document. The host's own curl is the
# monitor's alert path; this root oneshot must not care whether it exists.
# ---------------------------------------------------------------------------
lapi_get() { # host port path key -> body on stdout, non-zero on a non-200
    local host="$1" port="$2" path="$3" key="$4" raw status
    exec 3<>"/dev/tcp/$host/$port" || return 1
    # CrowdSec parses the UA against the bouncer spec (crowdsec-<type>-bouncer/v<x.y>)
    # and warns on anything else; the plain spec shape is the only accepted form.
    printf 'GET %s HTTP/1.0\r\nHost: %s\r\nX-Api-Key: %s\r\nUser-Agent: crowdsec-firewall-bouncer/v1.4\r\nAccept: application/json\r\nConnection: close\r\n\r\n' \
        "$path" "$host" "$key" >&3
    raw=$(cat <&3)
    exec 3<&- 3>&-
    status=$(printf '%s' "${raw%%$'\r'*}" | awk '{print $2}')
    [ "$status" = 200 ] || return 1
    # strip the header block (HTTP/1.0 has no chunking, so the body is the rest)
    printf '%s' "${raw#*$'\r\n\r\n'}"
}

# ---------------------------------------------------------------------------
# never ban these, whatever the LAPI says
# ---------------------------------------------------------------------------
# The classes -- private space, every address this host holds, and the declared
# WAN address -- and why each is a self-inflicted outage live in ipguard.py, which
# classifies every decision for this script. The two inputs it cannot discover are
# collected here: the host's own addresses, and STACK_WAN_IP from bouncer.env.
#
# STACK_WAN_IP is NOT in OWN_IPS: the router holds it, not the host. Every check
# leaving this host comes back through the router's NAT loopback, so Uptime-Kuma,
# agent-mcp and the MCP clients all appear as the operator's own egress -- one
# shared source IP, so five 401s from one stale token would ban all of them
# together. Detection is untouched (the decision still pages and shows in cscli);
# only enforcement skips it.
own_ips() {
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' '
}

# ---------------------------------------------------------------------------
# Go duration ("3h59m59.7s") -> whole seconds nft understands. Sub-SECOND precision
# is dropped: the LAPI re-sends the decision every minute, so a ban arriving a
# fraction short is refreshed long before it lapses.
#
# Parsed by unit. Reading the digits after the dot as the component turned "2.5h"
# into a 5-hour ban and "500ms" into 30000 s (no ms case) -- the worst direction,
# a sub-second decision becoming an eight-hour ban -- and 10# keeps "08m" from
# being read as octal. It is the same parser as lib.sh's dur_ms, floored instead of
# rounded up, and cannot be sourced from there: this runs as root and must not read
# a helper out of the user-writable checkout.
# ---------------------------------------------------------------------------
dur_to_sec() {
    local d="$1" ms=0 num frac unit s
    while [ -n "$d" ] && [[ $d =~ ^[^0-9]*([0-9]+)(\.([0-9]+))?(ms|h|m|s)(.*)$ ]]; do
        num=${BASH_REMATCH[1]} frac=${BASH_REMATCH[3]} unit=${BASH_REMATCH[4]} d=${BASH_REMATCH[5]}
        frac="${frac}000"; frac="${frac:0:3}"
        case "$unit" in
            h)  ms=$(( ms + 10#$num * 3600000 + 10#$frac * 3600 )) ;;
            m)  ms=$(( ms + 10#$num * 60000 + 10#$frac * 60 )) ;;
            s)  ms=$(( ms + 10#$num * 1000 + 10#$frac )) ;;
            ms) ms=$(( ms + 10#$num )) ;;
        esac
    done
    s=$(( ms / 1000 ))
    [ "$s" -gt 0 ] || s=3600
    [ "$s" -le 86400 ] || s=86400
    printf '%s' "$s"
}

write_status() { # result detail banned [skipped]
    # The guard lives here, not at the single success path at the end of the
    # file: every failure path (LAPI, JSON shape, classifier, nft) calls this
    # too, and each of them used to overwrite the live verdict -- so a manual
    # `--dry-run` against a down LAPI set result=fail and made the monitor page,
    # despite the header saying "write nothing".
    if [ "$DRY_RUN" = 1 ]; then
        say "dry-run: would have written $STATUS result=$1${2:+ ($2)}"
        return 0
    fi
    status_write "$STATUS" \
        "# written by /etc/stack-ids/bouncer.sh (stack-bouncer.timer)" \
        "$1" "$2" "banned=$3" "skipped=${4:-0}"
}

# ---------------------------------------------------------------------------
# the apply
# ---------------------------------------------------------------------------
OWN_IPS=$(own_ips)
host="${LAPI%%:*}"
port="${LAPI##*:}"

if ! body=$(lapi_get "$host" "$port" "/v1/decisions?type=ban&scope=Ip" "$CROWDSEC_BOUNCER_KEY"); then
    say "LAPI unreachable at $LAPI; leaving the current bans in place"
    write_status fail "LAPI unreachable at $LAPI" ""
    exit 1
fi

# An empty decision list is a legitimate answer -- and CrowdSec spells it `null`,
# not `[]`, which is why the check accepts both. Anything else is a protocol
# error, and trusting it would flush the ban set.
if ! printf '%s' "$body" | jq -e 'type == "array" or . == null' >/dev/null 2>&1; then
    say "unexpected LAPI answer: $(printf '%s' "$body" | head -c 200)"
    write_status fail "unexpected LAPI answer (not a JSON array or null)" ""
    exit 1
fi

# Classify every decision in ONE process: the guard is a CIDR question, and a
# failure here is fail-closed -- the status file records it and nothing is
# applied, so a broken guard can never ban the operator. Each record is
# TAB-separated: BAN<TAB>v4|v6<TAB>value<TAB>duration, or
# SKIP<TAB>-<TAB>value<TAB>reason.
classified=$(mktemp) || exit 1
if ! printf '%s' "$body" \
    | jq -r '(. // [])[] | "\(.value)\t\(.duration // "1h")"' 2>/dev/null \
    | STACK_WAN_IP="${STACK_WAN_IP:-}" OWN_IPS="$OWN_IPS" \
        python3 "$IPGUARD" > "$classified" 2>"$errlog"; then
    detail=$(tail -3 "$errlog" 2>/dev/null | tr '\n' ' ')
    rm -f "$classified"
    write_status fail "address classification failed: ${detail:-unknown}" ""
    exit 1
fi

rules=$(mktemp) || { rm -f "$classified"; exit 1; }
{
    # The table is created once; `nft -f` MERGES a table declaration rather than
    # recreating it, so re-declaring the chain on every run would append a second
    # copy of each rule every minute (it did, twice, before this was split out).
    # Create-if-missing, then operate only on the sets.
    if ! "$NFT" list table inet "$TABLE" >/dev/null 2>&1; then
        printf 'table inet %s {\n  set %s { type ipv4_addr; flags timeout; }\n  set %s { type ipv6_addr; flags timeout; }\n' \
            "$TABLE" "$SET_V4" "$SET_V6"
        printf '  chain input { type filter hook input priority -10; policy accept;\n'
        printf '    ip saddr @%s drop\n    ip6 saddr @%s drop\n  }\n}\n' "$SET_V4" "$SET_V6"
    fi
    # Refreshed wholesale every run: the LAPI's list is the truth, and re-adding
    # an element resets its timeout. One nft transaction, so the set is never
    # empty in between.
    printf 'flush set inet %s %s\nflush set inet %s %s\n' "$TABLE" "$SET_V4" "$TABLE" "$SET_V6"
    while IFS=$'\t' read -r kind family value extra; do
        case "$kind" in
            SKIP)
                say "skip ($extra): $value"
                ;;
            BAN)
                case "$family" in
                    v4) family_set="$SET_V4" ;;
                    v6) family_set="$SET_V6" ;;
                    *)  continue ;;
                esac
                printf 'add element inet %s %s { %s timeout %ss }\n' \
                    "$TABLE" "$family_set" "$value" "$(dur_to_sec "$extra")"
                ;;
        esac
    done < "$classified"
} > "$rules"

banned=$(grep -c '^add element' "$rules" 2>/dev/null || true)
case "$banned" in ''|*[!0-9]*) banned=0 ;; esac
skipped=$(grep -c '^SKIP' "$classified" 2>/dev/null || true)
case "$skipped" in ''|*[!0-9]*) skipped=0 ;; esac

if [ "$DRY_RUN" = 1 ]; then
    say "--- would apply ($banned ban(s), $skipped skipped):"
    cat "$rules"
    rm -f "$rules" "$classified"
    exit 0
fi

if ! "$NFT" -f "$rules" 2>"$errlog"; then
    detail=$(tail -3 "$errlog" 2>/dev/null | tr '\n' ' ')
    rm -f "$rules" "$classified"
    # The previous transaction is still in place: nft applies atomically, so a
    # failed apply changes nothing rather than emptying the set.
    write_status fail "nft apply failed: ${detail:-unknown}" ""
    exit 1
fi
rm -f "$rules" "$classified"

write_status ok "" "$banned" "$skipped"
exit 0
