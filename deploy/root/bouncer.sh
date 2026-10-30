#!/usr/bin/env bash
# stack-bouncer: apply CrowdSec's decisions to the host's nftables.
#
# Runs as root from deploy/root/stack-bouncer.timer (every minute), installed to
# /etc/stack-ids/bouncer.sh by `deploy/install.sh --root`. It is the ONLY thing in
# this stack that drops a packet, and it is deliberately dumb: CrowdSec owns the
# decision (who, why, how long), this owns the plumbing.
#
#   /etc/stack-ids/bouncer.sh --dry-run    print the rules, change nothing
#   /etc/stack-ids/bouncer.sh             apply, write $DATA_DIR/audit/bouncer.status
#
# Why not the upstream bouncer: docker.io/crowdsecurity/cs-firewall-bouncer is
# gone ("requested access to the resource is denied"), and the packaged one is a
# second daemon with its own config file, outside this repo. This is ~120 lines,
# reads the same LAPI, and the whitelist is in one place -- which matters, because
# the failure mode here is a ban on the operator's own monitoring.
#
# FAIL-OPEN, in the direction that matters: a failed or empty LAPI response
# leaves the existing bans alone (never "no decisions = unban everything"), while
# a failed nft apply leaves the previous ruleset in place. Losing enforcement is
# worse than losing detection, but neither may take the site down.
set -uo pipefail

ENV_FILE=/etc/stack-ids/bouncer.env
NFT=/usr/sbin/nft
TABLE=stack_bans
SET_V4=banned_v4
SET_V6=banned_v6

# Rendered by install.sh --root: CROWDSEC_BOUNCER_KEY, LAPI (127.0.0.1:8081),
# DATA_DIR. Root-owned 0600 -- root must not read its config from a file the
# stack user can edit.
# shellcheck source=/dev/null
. "$ENV_FILE"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

STATUS="$DATA_DIR/audit/bouncer.status"
mkdir -p "$DATA_DIR/audit"

say() { [ "$DRY_RUN" = 1 ] && printf '%s\n' "$*"; return 0; }

# ---------------------------------------------------------------------------
# LAPI fetch: /dev/tcp, because this host has no curl and the point is to avoid
# a dependency on an image or a package just to read one JSON document.
# ---------------------------------------------------------------------------
lapi_get() { # host port path key -> body on stdout, non-zero on a non-200
    local host="$1" port="$2" path="$3" key="$4" raw status
    exec 3<>"/dev/tcp/$host/$port" || return 1
    printf 'GET %s HTTP/1.0\r\nHost: %s\r\nX-Api-Key: %s\r\nAccept: application/json\r\nConnection: close\r\n\r\n' \
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
# Two classes, both learned from this host's own logs:
#   * private space -- 10.89.0.0/24 is the podman network, 192.168.0.0/16 the
#     LAN, and the .onion proxies plus Uptime-Kuma's self-checks arrive from the
#     host's own address (192.168.1.112) or its WAN address. Banning any of it
#     takes the onion services, the status page, or the operator's own session
#     down -- all at once, including the SSH session doing the unbanning.
#   * any address this host actually holds (checked at run time, so a DHCP
#     change or a new WAN address cannot produce a self-ban).
own_ips() {
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' '
}

is_internal() { # ip -> 0 when it must never be banned
    local ip="$1"
    case "$ip" in
        127.*|10.*|192.168.*|169.254.*|0.0.0.0) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-9].*) return 0 ;;
        ::1|fe80:*|fc*|fd*) return 0 ;;
    esac
    case " $OWN_IPS " in *" $ip "*) return 0 ;; esac
    return 1
}

# ---------------------------------------------------------------------------
# Go duration ("3h59m59.7s") -> seconds nft understands. Sub-minute precision is
# dropped: the LAPI re-sends the decision every minute, so a ban that comes back
# a few seconds short is refreshed long before it lapses.
# ---------------------------------------------------------------------------
dur_to_sec() {
    local d="$1" s=0
    [[ $d =~ ([0-9]+)h ]] && s=$((s + BASH_REMATCH[1] * 3600))
    [[ $d =~ ([0-9]+)m ]] && s=$((s + BASH_REMATCH[1] * 60))
    [[ $d =~ ([0-9]+)s ]] && s=$((s + BASH_REMATCH[1]))
    [ "$s" -gt 0 ] || s=3600
    [ "$s" -le 86400 ] || s=86400
    printf '%s' "$s"
}

write_status() { # result detail banned
    local result="$1" detail="$2" banned="$3" now prev_ok="" ok_epoch tmp
    now=$(date +%s)
    [ -f "$STATUS" ] && prev_ok=$(sed -n 's/^ok_epoch=//p' "$STATUS" | tail -1)
    case "$prev_ok" in ''|*[!0-9]*) prev_ok="" ;; esac
    if [ "$result" = ok ]; then ok_epoch="$now"; else ok_epoch="$prev_ok"; fi
    tmp=$(mktemp "$DATA_DIR/audit/.bouncer.XXXXXX") || return 0
    {
        printf '# written by /etc/stack-ids/bouncer.sh (stack-bouncer.timer)\n'
        printf 'time=%s\n' "$(date -Is)"
        printf 'epoch=%s\n' "$now"
        printf 'result=%s\n' "$result"
        printf 'ok_epoch=%s\n' "$ok_epoch"
        printf 'banned=%s\n' "$banned"
        printf 'detail=%s\n' "$(printf '%s' "$detail" | tr '\n' ' ')"
    } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$STATUS"
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

rules=$(mktemp) || exit 1
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
    printf '%s' "$body" | jq -r '(. // [])[] | "\(.value)\t\(.duration // "1h")"' 2>/dev/null \
        | while IFS=$'\t' read -r ip dur; do
            [ -n "$ip" ] || continue
            if is_internal "$ip"; then
                say "skip (internal): $ip"
                continue
            fi
            case "$ip" in
                *:*) printf 'add element inet %s %s { %s timeout %ss }\n' "$TABLE" "$SET_V6" "$ip" "$(dur_to_sec "$dur")" ;;
                *)   printf 'add element inet %s %s { %s timeout %ss }\n' "$TABLE" "$SET_V4" "$ip" "$(dur_to_sec "$dur")" ;;
            esac
        done
} > "$rules"

banned=$(grep -c '^add element' "$rules" 2>/dev/null || true)
case "$banned" in ''|*[!0-9]*) banned=0 ;; esac

if [ "$DRY_RUN" = 1 ]; then
    say "--- would apply ($banned ban(s)):"
    cat "$rules"
    rm -f "$rules"
    exit 0
fi

if ! "$NFT" -f "$rules" 2>/tmp/stack-bouncer.err; then
    detail=$(tail -3 /tmp/stack-bouncer.err 2>/dev/null | tr '\n' ' ')
    rm -f "$rules"
    # The previous transaction is still in place: nft applies atomically, so a
    # failed apply changes nothing rather than emptying the set.
    write_status fail "nft apply failed: ${detail:-unknown}" ""
    exit 1
fi
rm -f "$rules"

write_status ok "" "$banned"
exit 0
