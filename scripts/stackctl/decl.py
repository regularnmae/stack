# The stdin declaration protocol, and the parsers for stack.conf's entries.
#
# The bash wrappers own stack.conf (it is plain shell, sourced, with ${VAR:-
# default} operator overrides) and stream what they found to the Python core,
# one TAB-separated record per line:
#
#   V<TAB>NAME<TAB>value    a scalar (DATA_DIR, DRY_RUN, KUMA_URL, ...)
#   H<TAB>raw               an NPM_HOSTS entry   "domain|forward|flags"
#   M<TAB>raw               an MCP_HOSTS entry   "/prefix:container:port"
#   O<TAB>raw               an ONION_SERVICES entry "name|target|mirrors|probe|codes"
#   K<TAB>raw               a KUMA_MONITORS entry "name|url[|codes[|interval[|retries]]]"
#
# TAB because the raw entries are already pipe-delimited (and kuma monitor
# *names* contain spaces), so neither separator can be re-escaped; no record
# value can contain a TAB. Line-based on purpose: it needs no jq in the
# wrapper and no JSON escaping layer -- the exact class of bug the bash
# reconcilers' json_escape/config_escape pair existed to prevent.
#
# The parsers below reproduce lib.sh's field splitting exactly, quirks
# included: `IFS='|' read -r a b c` puts EVERY remaining pipe into the last
# variable, so split() uses the same maxsplit. Error messages are verbatim
# ports -- operators (and docs/proxy.md) know them.
from __future__ import annotations

import re
import sys
from typing import Dict, List, Optional

from .ui import die

_CODES_RE = re.compile(r"^[0-9]{3}-[0-9]{3}(,[0-9]{3}-[0-9]{3})*$")


class Decls:
    """One stdin stream's worth of declarations."""

    def __init__(self) -> None:
        self.vars: Dict[str, str] = {}
        self.npm_hosts: List[str] = []
        self.mcp_hosts: List[str] = []
        self.onion_services: List[str] = []
        self.kuma_monitors: List[str] = []

    def var(self, name: str, default: str = "") -> str:
        return self.vars.get(name, default)

    def flag(self, name: str) -> bool:
        return self.vars.get(name, "0") == "1"


def read_decls(stream=sys.stdin) -> Decls:
    decls = Decls()
    for line in stream:
        line = line.rstrip("\n")
        if not line:
            continue
        kind, _, raw = line.partition("\t")
        if kind == "V":
            name, _, value = raw.partition("\t")
            decls.vars[name] = value
        elif kind == "H":
            decls.npm_hosts.append(raw)
        elif kind == "M":
            decls.mcp_hosts.append(raw)
        elif kind == "O":
            decls.onion_services.append(raw)
        elif kind == "K":
            decls.kuma_monitors.append(raw)
        else:
            die(f"bad declaration line from the wrapper: {line!r}")
    return decls


# --- NPM_HOSTS: "domain | [scheme://]forward_host:port | flags" --------------
class NpmHost:
    __slots__ = ("domain", "scheme", "host", "port", "flags", "raw")

    def __init__(self, domain, scheme, host, port, flags, raw):
        self.domain = domain
        self.scheme = scheme
        self.host = host
        self.port = port
        self.flags = flags  # the raw comma-separated string, as declared
        self.raw = raw

    def has_flag(self, flag: str) -> bool:
        # lib.sh's has_flag(): match on the comma-wrapped string, so "mcp"
        # never matches inside another flag's name.
        return f",{flag}," in f",{self.flags},"

    def flags_without(self, flag: str) -> str:
        kept = [f for f in self.flags.split(",") if f and f != flag]
        return ",".join(kept)


def parse_npm_host(raw: str) -> NpmHost:
    # IFS='|' read -r domain forward flags: at most three fields, the last one
    # keeps any remaining pipes.
    parts = raw.split("|", 2)
    domain = parts[0]
    forward = parts[1] if len(parts) > 1 else ""
    flags = parts[2] if len(parts) > 2 else ""
    if not domain or not forward:
        die(f'bad NPM_HOSTS entry: {raw} (want "domain|[scheme://]forward_host:port|flags")')
    # `forward` may carry a scheme; a TLS-speaking upstream would need https.
    scheme = "http"
    if "://" in forward:
        scheme, forward = forward.split("://", 1)
    if scheme not in ("http", "https"):
        die(f"bad forward scheme in NPM_HOSTS entry: {raw}")
    host = forward.rpartition(":")[0] if ":" in forward else forward
    port = forward.rpartition(":")[2] if ":" in forward else forward
    if not port.isdigit():
        die(f'bad forward port in NPM_HOSTS entry: {raw} (want "host:port")')
    return NpmHost(domain, scheme, host, port, flags, raw)


# --- MCP_HOSTS: "/prefix:container:loopback-port" ----------------------------
class McpHost:
    __slots__ = ("prefix", "container", "port", "raw")

    def __init__(self, prefix, container, port, raw):
        self.prefix = prefix
        self.container = container
        self.port = port
        self.raw = raw


def parse_mcp_host(raw: str) -> McpHost:
    bad = f'bad MCP_HOSTS entry: {raw} (want "/prefix:container:loopback-port")'
    # bash: prefix=${pair%%:*} rest=${pair#*:} host=${rest%%:*} port=${rest##*:}
    # -- the port is what follows the LAST colon, the container what precedes
    # the first colon of the remainder.
    if ":" not in raw:
        die(bad)
    prefix, rest = raw.split(":", 1)
    container = rest.split(":", 1)[0]
    port = rest.rpartition(":")[2] if ":" in rest else ""
    if not prefix or not container:
        die(bad)
    if not port.isdigit():
        die(bad)
    return McpHost(prefix, container, port, raw)


# --- ONION_SERVICES: "name | target | mirrors | probe-path | expected-code" --
class OnionService:
    __slots__ = ("name", "target", "mirrors", "rest", "raw")

    def __init__(self, name, target, mirrors, rest, raw):
        self.name = name
        self.target = target
        self.mirrors = mirrors
        self.rest = rest  # probe-path|expected-code (npm-hosts only prints)
        self.raw = raw


def parse_onion_service(raw: str) -> OnionService:
    # IFS='|' read -r name _target mirrors _rest: four fields, the last keeps
    # the remainder.
    parts = raw.split("|", 3)
    name = parts[0]
    target = parts[1] if len(parts) > 1 else ""
    mirrors = parts[2] if len(parts) > 2 else ""
    rest = parts[3] if len(parts) > 3 else ""
    if not name:
        die(f"bad ONION_SERVICES entry: {raw}")
    return OnionService(name, target, mirrors, rest, raw)


# --- KUMA_MONITORS: "name | url [| codes [| interval [| retries ]]]" ---------
class KumaMonitor:
    """A normalized monitor declaration, in the shape kuma's add/edit handlers
    read. `type` is "http" (url + codes) or "port" (hostname + port, kuma's TCP
    check). interval/retryInterval/maxretries default exactly as the bash
    wrapper did (60/interval/2)."""

    __slots__ = ("name", "type", "url", "hostname", "port", "codes",
                 "interval", "retry_interval", "maxretries", "raw")

    def __init__(self, **kw):
        self.name = kw["name"]
        self.type = kw["type"]
        self.url = kw.get("url")
        self.hostname = kw.get("hostname")
        self.port = kw.get("port")
        self.codes: List[str] = kw.get("codes", [])
        self.interval = kw["interval"]
        self.retry_interval = kw["retry_interval"]
        self.maxretries = kw["maxretries"]
        self.raw = kw["raw"]

    def describe(self) -> str:
        """How a declaration reads in a log line (monitors.mjs's describe())."""
        if self.type == "port":
            return f"{self.hostname}:{self.port} (tcp)"
        return f"{self.url} (codes {','.join(self.codes)})"


def parse_kuma_monitor(raw: str) -> KumaMonitor:
    parts = raw.split("|")
    while len(parts) < 5:
        parts.append("")
    name, url, codes, interval, retries = parts[0], parts[1], parts[2], parts[3], parts[4]
    if not name or not url:
        die(f'bad KUMA_MONITORS entry: {raw} (want "name|url[|codes[|interval[|retries]]]")')

    mtype: str
    hostname: Optional[str] = None
    port: Optional[int] = None
    code_list: List[str] = []
    if url.startswith("http://") or url.startswith("https://"):
        mtype = "http"
        codes = codes or "200-299"
        if not _CODES_RE.match(codes):
            die(f"bad accepted status codes in KUMA_MONITORS entry: {raw} "
                "(want ranges like 200-299,400-499)")
        code_list = [c.strip() for c in codes.replace(" ", "").split(",") if c.strip()]
    elif url.startswith("tcp://"):
        if codes:
            die(f"a tcp:// monitor accepts no status codes: {raw} (leave that field empty)")
        mtype = "port"
        target = url[len("tcp://"):]
        hostname = target.rpartition(":")[0] if ":" in target else target
        port_s = target.rpartition(":")[2] if ":" in target else ""
        if not hostname or not port_s:
            die(f'bad tcp:// target in KUMA_MONITORS entry: {raw} (want tcp://host:port)')
        if not port_s.isdigit():
            die(f"bad port in KUMA_MONITORS entry: {raw} (1-65535)")
        port = int(port_s)
        if not 1 <= port <= 65535:
            die(f"bad port in KUMA_MONITORS entry: {raw} (1-65535)")
    else:
        die(f"bad monitor URL in KUMA_MONITORS entry: {raw} (want scheme://..., or tcp://host:port)")

    interval = interval or "60"
    retries = retries or "2"
    if not interval.isdigit():
        die(f"bad interval in KUMA_MONITORS entry: {raw} (seconds)")
    if not retries.isdigit():
        die(f"bad retries in KUMA_MONITORS entry: {raw} (attempts)")

    return KumaMonitor(
        name=name, type=mtype,
        url=url if mtype == "http" else f"tcp://{hostname}:{port}",
        hostname=hostname, port=port,
        codes=code_list,
        interval=int(interval), retry_interval=int(interval), maxretries=int(retries),
        raw=raw,
    )
