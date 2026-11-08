#!/usr/bin/env python3
# Classify CrowdSec decision addresses for stack-bouncer.
#
# READ THE CONTRACT BEFORE CHANGING A LINE: this decides whether a ban may be
# enforced, so its failure mode is a lockout (the operator's LAN, egress or SSH
# session) rather than a missed ban. Every SKIP below is deliberate, and every
# value that reaches BAN is a canonical address string from ipaddress -- which
# also keeps a malformed LAPI value out of the nft transaction.
#
# Why this replaced the shell glob table: private space is a CIDR question. The
# old table matched `fe80:*` (fe80:: only, not the whole fe80::/10), let
# `::ffff:10.0.0.1` fall through to a ban, and had no answer for a network
# value. ipaddress is stdlib, python3 is already a bootstrap dependency, and
# this file is installed root-owned under /etc/stack-ids -- the bouncer still
# reads nothing from the user-writable checkout.
#
# Protocol (one record per line, TAB-separated; no address can contain a TAB):
#
#   stdin    value<TAB>duration        (from the LAPI; duration defaults to 1h)
#   stdout   BAN<TAB>v4|v6<TAB>value<TAB>duration
#            SKIP<TAB>-<TAB>value<TAB>reason
#
# env: STACK_WAN_IP -- the operator's public egress, never enforced against
#      (empty disables the refusal, as stack.conf documents);
#      OWN_IPS -- space-separated addresses this host holds, from `ip -o addr`.
#
# Exit 0 on success, including when every record is a SKIP. A non-zero exit
# means the guard itself failed: the bouncer must then apply nothing (fail
# closed), because guessing is how the operator gets banned. A set-but-
# unparsable STACK_WAN_IP is a config error for that reason, not a no-op.
from __future__ import annotations

import ipaddress
import os
import sys
from typing import Optional, Set, Union

Address = Union[ipaddress.IPv4Address, ipaddress.IPv6Address]

# The addresses the host holds. A token that does not parse is ignored: the
# string comparison it replaces could not match it either, and the CIDR rules
# below still cover it if it is private space.
def _own_addresses() -> Set[Address]:
    own: Set[Address] = set()
    for token in os.environ.get("OWN_IPS", "").split():
        try:
            own.add(ipaddress.ip_address(token))
        except ValueError:
            continue
    return own


def _classify(
    value: str,
    wan: Optional[Address],
    own: Set[Address],
):
    """(address to enforce, None) or (None, reason to skip)."""
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        # A Range-scope decision is a network, and the sets are single-address
        # (ipv4_addr / ipv6_addr without `flags interval`). Refusing it here is
        # honest; enforcing half of it would not be.
        try:
            ipaddress.ip_network(value, strict=False)
        except ValueError:
            return None, "unparsable"
        return None, "range"

    # An IPv4-mapped IPv6 address (::ffff:a.b.c.d) has to be judged by the
    # IPv4 address it maps, or 10.0.0.0/8 walks straight past every rule. The
    # enforceable value becomes that IPv4 address: a mapped element in the v6
    # set can never match an IPv4 packet.
    check = addr
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
        check = addr.ipv4_mapped

    # The address the host holds, then the operator's declared egress. Both are
    # compared as addresses, not strings: an uncompressed IPv6 spelling of the
    # host's own address must not turn into a ban.
    if addr in own or check in own:
        return None, "own"
    if wan is not None and (addr == wan or check == wan):
        return None, "wan"

    if check.is_multicast:
        return None, "multicast"
    if check.is_unspecified:
        return None, "unspecified"
    if check.is_loopback:
        return None, "loopback"
    if check.is_link_local:
        return None, "link-local"
    # A zone id is meaningful only on a link-local address (skipped above) and
    # nft cannot parse one at all.
    if getattr(addr, "scope_id", None):
        return None, "zoned"
    if check.is_private:
        return None, "private"
    if check.is_reserved:
        return None, "reserved"
    if not check.is_global:
        return None, "non-global"
    return check, None


def main() -> int:
    wan: Optional[Address] = None
    raw_wan = os.environ.get("STACK_WAN_IP", "").strip()
    if raw_wan:
        try:
            wan = ipaddress.ip_address(raw_wan)
        except ValueError:
            print(
                f"STACK_WAN_IP is not an address: {raw_wan!r}; refusing to guess "
                "which source is the operator's own egress",
                file=sys.stderr,
            )
            return 1

    own = _own_addresses()
    out = sys.stdout

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        value, _, duration = line.partition("\t")
        value = value.strip()
        if not value:
            continue
        # The bouncer's dur_to_sec owns the duration parse; a value that would
        # break the record framing is neutralised here and parses to its 1h
        # default there anyway.
        duration = (duration.strip() or "1h").replace("\t", " ").replace("\n", " ")

        address, reason = _classify(value, wan, own)
        if address is None:
            out.write(f"SKIP\t-\t{value}\t{reason}\n")
            continue
        family = "v6" if isinstance(address, ipaddress.IPv6Address) else "v4"
        out.write(f"BAN\t{family}\t{address}\t{duration}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
