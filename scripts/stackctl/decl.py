# The stdin scalar protocol, and the canonical pipe-formats' parsers.
#
# The bash wrappers own the CLI and stream what they resolved to the Python
# core over stdin, one TAB-separated record per line:
#
#   V<TAB>NAME<TAB>value    a scalar (DATA_DIR, DRY_RUN, MANIFEST, ...)
#
# TAB because a value can contain spaces; no value can contain a TAB. The
# declarations themselves (proxy hosts, MCP prefixes, onion services,
# monitors) no longer travel this pipe: deploy/services.toml is their one
# home, and the cores load it directly (manifest.py). What survives below is
# the canonical pipe-FORMAT of each declaration --
#
#   proxy host    "domain|[scheme://]forward_host:port|flags"
#   MCP endpoint  "/prefix:container:port"
#   onion service "name|target|mirrors|probe-path|expected-code"
#   monitor       "name|url[|codes[|interval[|retries]]]"
#
# -- because manifest.py composes exactly these strings from the TOML tables
# and validates them through these parsers. One validation implementation,
# two eras of input format, and the bash consumers (verify.sh,
# deploy/install.sh) still parse the shell emission with the same shapes.
#
# The parsers reproduce the original field splitting exactly, quirks
# included: `IFS='|' read -r a b c` puts EVERY remaining pipe into the last
# variable, so split() uses the same maxsplit.
from __future__ import annotations

import re
import sys
from typing import Dict, List, Optional

from .ui import die

_CODES_RE = re.compile(r"^[0-9]{3}-[0-9]{3}(,[0-9]{3}-[0-9]{3})*$")


class Decls:
    """One stdin stream's worth of scalars."""

    def __init__(self) -> None:
        self.vars: Dict[str, str] = {}

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
        die(f'bad proxy-host declaration: {raw} (want "domain|[scheme://]forward_host:port|flags")')
    # `forward` may carry a scheme; a TLS-speaking upstream would need https.
    scheme = "http"
    if "://" in forward:
        scheme, forward = forward.split("://", 1)
    if scheme not in ("http", "https"):
        die(f"bad forward scheme in the proxy-host declaration: {raw}")
    host = forward.rpartition(":")[0] if ":" in forward else forward
    port = forward.rpartition(":")[2] if ":" in forward else forward
    if not port.isdigit():
        die(f'bad forward port in the proxy-host declaration: {raw} (want "host:port")')
    return NpmHost(domain, scheme, host, port, flags, raw)


# --- MCP_HOSTS: "/prefix:container:loopback-port" ----------------------------
class McpHost:
    __slots__ = ("prefix", "container", "port", "raw",
                 "token_var", "probe_tool", "probe_args", "needs_nodes")

    def __init__(self, prefix, container, port, raw):
        self.prefix = prefix
        self.container = container
        self.port = port
        self.raw = raw
        # Probe metadata lives in services.toml alongside the server; it is
        # empty for hand-built McpHost objects (decl.py's own tests) and filled
        # by manifest.py. Keeping the defaults here means the parser's contract
        # is unchanged for callers that only need the routing facts.
        self.token_var = ""
        self.probe_tool = ""
        self.probe_args = "{}"
        self.needs_nodes = False


def parse_mcp_host(raw: str) -> McpHost:
    bad = f'bad MCP endpoint declaration: {raw} (want "/prefix:container:port")'
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
        die(f"bad onion-service declaration: {raw}")
    return OnionService(name, target, mirrors, rest, raw)


# --- kuma.monitor.* -> "name | url [| codes [| interval [| retries ]]]" ------
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
        die(f'bad monitor declaration: {raw} (want "name|url[|codes[|interval[|retries]]]")')

    mtype: str
    hostname: Optional[str] = None
    port: Optional[int] = None
    code_list: List[str] = []
    if url.startswith("http://") or url.startswith("https://"):
        mtype = "http"
        codes = codes or "200-299"
        if not _CODES_RE.match(codes):
            die(f"bad accepted status codes in the monitor declaration: {raw} "
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
            die(f'bad tcp:// target in the monitor declaration: {raw} (want tcp://host:port)')
        if not port_s.isdigit():
            die(f"bad port in the monitor declaration: {raw} (1-65535)")
        port = int(port_s)
        if not 1 <= port <= 65535:
            die(f"bad port in the monitor declaration: {raw} (1-65535)")
    else:
        die(f"bad monitor URL in the declaration: {raw} (want scheme://..., or tcp://host:port)")

    interval = interval or "60"
    retries = retries or "2"
    if not interval.isdigit():
        die(f"bad interval in the monitor declaration: {raw} (seconds)")
    if not retries.isdigit():
        die(f"bad retries in the monitor declaration: {raw} (attempts)")

    return KumaMonitor(
        name=name, type=mtype,
        url=url if mtype == "http" else f"tcp://{hostname}:{port}",
        hostname=hostname, port=port,
        codes=code_list,
        interval=int(interval), retry_interval=int(interval), maxretries=int(retries),
        raw=raw,
    )
