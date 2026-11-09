# deploy/services.toml: the declarations, the loader, and the shell emission.
#
# This file owns every cross-cutting registry fact the stack has -- the DNS
# names it answers on, which loopback publishes nginx-proxy-manager forwards to,
# the MCP path prefixes, the tor onion services, and the status page's monitors
# -- so there is one declaration and no parallel lists. It replaced the five
# tables stack.conf used to carry (the MCP prefixes, the proxy hosts, the onion
# services, the status-page monitors and the *_HOST scalars), each of which had
# to be edited in step with the others and with the table in AGENTS.md.
#
# Two audiences read the TOML, and neither sees a second grammar:
#
#   * the Python reconcilers (npm.py, kuma.py) -- these typed objects, directly;
#   * the bash callers (deploy.sh, verify.sh, deploy/install.sh, rotate.sh) --
#     through `manifest shell`, which emits the same variable names they always
#     sourced from stack.conf (plus the probe table verify.sh and rotate.sh need,
#     which has no stack.conf predecessor). scripts/lib.sh's load_manifest is a
#     one-line addition per consumer.
#
# The fields are validated here, once, as they are read: each table is checked
# field by field and an error names the TOML table it came from. Nothing composes
# a string and re-parses it, so there is no second format to keep in step.
#
# Operator overrides keep the old contract: every [host.*] carries an `env`
# name, and a non-empty $<env> in the process environment wins over the TOML's
# `domain` -- exactly what stack.conf's ${VAR:-default} did, so
# `BOLTMESH_FRONTEND_HOST=staging.example.net ./deploy.sh` still works.
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from typing import Any, Dict, List, Optional

from .ui import die

try:
    import tomllib  # Python 3.11+; the guard gives the clear error below
except ImportError:  # pragma: no cover - the host bootstrap installs 3.12
    tomllib = None

# A status-code field is one or more `NNN-NNN` ranges (kuma's own shape).
_CODES_RE = re.compile(r"^[0-9]{3}-[0-9]{3}$")
# A vhost flag ("force-ssl", "mcp", ...) and a container name.
_FLAG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_CONTAINER_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]*$")
_ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
# tor's HiddenServicePort target: a name or address and a numeric port.
_TARGET_RE = re.compile(r"^[A-Za-z0-9_.-]+:[0-9]+$")
_MAX_PORT = 65535


class Host:
    __slots__ = ("key", "domain", "env", "kuma_add_host")

    def __init__(self, key: str, domain: str, env: str, kuma_add_host: bool):
        self.key = key
        self.domain = domain
        self.env = env
        self.kuma_add_host = kuma_add_host


class KumaPage:
    __slots__ = ("slug", "title", "group")

    def __init__(self, slug: str, title: str, group: str):
        self.slug = slug
        self.title = title
        self.group = group


class NpmHost:
    """One [npm.*] proxy host: the name NPM serves and where it forwards."""

    __slots__ = ("domain", "scheme", "host", "port", "flags")

    def __init__(self, domain: str, scheme: str, host: str, port: int, flags: str):
        self.domain = domain
        self.scheme = scheme
        self.host = host
        self.port = port
        self.flags = flags  # the comma-separated string, as declared

    def has_flag(self, flag: str) -> bool:
        # lib.sh's has_flag(): match on the comma-wrapped string, so "mcp"
        # never matches inside another flag's name.
        return f",{flag}," in f",{self.flags},"

    def flags_without(self, flag: str) -> str:
        kept = [f for f in self.flags.split(",") if f and f != flag]
        return ",".join(kept)


class McpHost:
    """One [mcp.*] server: its path prefix, loopback publish and probe.

    Probe metadata lives in the same table as the server, so adding a server
    adds its verify probe and its rotation target -- there is no second table in
    verify.sh or rotate.sh to keep in step. `token_var` is the variable in
    $DATA_DIR/config/<container>/token.env; `probe_tool`/`probe_args` are the one
    read-only tool that proves the server reaches its upstream; `needs_nodes`
    skips the deep call under verify.sh --no-nodes; `spend_token_var` is empty
    for everything but the two money servers.
    """

    __slots__ = ("prefix", "container", "port", "token_var", "probe_tool",
                 "probe_args", "needs_nodes", "spend_token_var")

    def __init__(self, prefix: str, container: str, port: int):
        self.prefix = prefix
        self.container = container
        self.port = port
        self.token_var = ""
        self.probe_tool = ""
        self.probe_args = "{}"
        self.needs_nodes = False
        self.spend_token_var = ""


class OnionService:
    """One [onion.*] hidden service. The table key is the HiddenServiceDir name
    under $DATA_DIR/tor/onion/<name> -- a rename is a new onion address."""

    __slots__ = ("name", "target", "mirrors", "path", "codes")

    def __init__(self, name: str, target: str, mirrors: str, path: str,
                 codes: List[str]):
        self.name = name
        self.target = target
        self.mirrors = mirrors
        self.path = path
        self.codes = codes


class KumaMonitor:
    """One [kuma.monitor.*] declaration, in the shape kuma's add/edit handlers
    read. `type` is "http" (url + codes) or "port" (hostname + port, kuma's TCP
    check). interval/retryInterval/maxretries default as the old bash wrapper did
    (60/interval/2)."""

    __slots__ = ("name", "type", "url", "hostname", "port", "codes",
                 "interval", "retry_interval", "maxretries")

    def __init__(self, name: str, type: str, url: str = "",
                 hostname: Optional[str] = None, port: Optional[int] = None,
                 codes: Optional[List[str]] = None, interval: int = 60,
                 retry_interval: int = 60, maxretries: int = 2):
        self.name = name
        self.type = type
        self.url = url
        self.hostname = hostname
        self.port = port
        self.codes = codes or []
        self.interval = interval
        self.retry_interval = retry_interval
        self.maxretries = maxretries

    def describe(self) -> str:
        """How a declaration reads in a log line."""
        if self.type == "port":
            return f"{self.hostname}:{self.port} (tcp)"
        return f"{self.url} (codes {','.join(self.codes)})"


class Manifest:
    def __init__(self) -> None:
        self.hosts: Dict[str, Host] = {}
        self.mcp: List[McpHost] = []
        self.npm: List[NpmHost] = []
        self.onion: List[OnionService] = []
        self.kuma_monitors: List[KumaMonitor] = []
        self.kuma_page: Optional[KumaPage] = None
        self.kuma_loopback: int = 8107

    # --- the emission the bash callers eval -------------------------------
    # Bash cannot read JSON, so each table leaves as one array per column,
    # index-aligned: MCP_CONTAINERS[i] is the server PROBE_TOKEN_VARS[i] names.
    # No field is packed into a delimited string, so nothing downstream has to
    # take a record apart (and a probe argument may contain any character).
    def shell(self) -> str:
        _validate_probes(self)
        lines = []
        for host in self.hosts.values():
            lines.append(f"{host.env}={shlex.quote(host.domain)}")
        if self.mcp:
            lines.append(_array("MCP_PREFIXES", [m.prefix for m in self.mcp]))
            lines.append(_array("MCP_CONTAINERS", [m.container for m in self.mcp]))
            lines.append(_array("MCP_PORTS", [str(m.port) for m in self.mcp]))
            # The probe/token columns, aligned with MCP_CONTAINERS. The env file
            # is the container's own token.env by convention, so it is not
            # repeated here.
            lines.append(_array("PROBE_TOKEN_VARS", [m.token_var for m in self.mcp]))
            lines.append(_array("PROBE_TOOLS", [m.probe_tool for m in self.mcp]))
            lines.append(_array("PROBE_ARGS", [m.probe_args for m in self.mcp]))
            lines.append(_array("PROBE_NEEDS_NODES",
                                ["1" if m.needs_nodes else "0" for m in self.mcp]))
            lines.append(_array("PROBE_SPEND_VARS",
                                [m.spend_token_var for m in self.mcp]))
        if self.onion:
            lines.append(_array("ONION_NAMES", [o.name for o in self.onion]))
            lines.append(_array("ONION_TARGETS", [o.target for o in self.onion]))
            lines.append(_array("ONION_MIRRORS", [o.mirrors for o in self.onion]))
            lines.append(_array("ONION_PATHS", [o.path for o in self.onion]))
            lines.append(_array("ONION_CODES",
                                [",".join(o.codes) for o in self.onion]))
        # The vhosts uptime-kuma's own monitors may resolve on the host
        # (install.sh renders --add-host=<domain>:host-gateway per entry):
        # every host whose [host.*] did not opt out.
        add_hosts = [h.domain for h in self.hosts.values() if h.kuma_add_host]
        if add_hosts:
            entries = " ".join(shlex.quote(d) for d in add_hosts)
            lines.append(f"KUMA_ADD_HOST_HOSTS=({entries})")
        if self.kuma_page is not None:
            lines.append(f"KUMA_STATUS_SLUG={shlex.quote(self.kuma_page.slug)}")
            lines.append(f"KUMA_STATUS_TITLE={shlex.quote(self.kuma_page.title)}")
            lines.append(f"KUMA_STATUS_GROUP={shlex.quote(self.kuma_page.group)}")
        return "\n".join(lines) + "\n"


def _array(name: str, values: List[str]) -> str:
    """One eval-safe bash array assignment; an empty value stays a placeholder
    so every column keeps the same length."""
    return f"{name}=({' '.join(shlex.quote(v) for v in values)})"


# --- reading the TOML --------------------------------------------------------
def _table(data: dict, name: str) -> Dict[str, Any]:
    table = data.get(name)
    if table is None:
        return {}
    if not isinstance(table, dict):
        die(f"deploy/services.toml: [{name}] must be a table")
    return table


def _text(table: dict, field: str, where: str, default: Optional[str] = None) -> str:
    value = table.get(field, default)
    if value is None:
        die(f"deploy/services.toml: {where} needs {field}")
    if not isinstance(value, str) or not value:
        die(f"deploy/services.toml: {where} {field} must be a non-empty string")
    return value


def _number(value: Any, where: str, field: str, low: int, high: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        die(f"deploy/services.toml: {where} {field} must be a whole number "
            f"({low}-{high})")
    if not low <= value <= high:
        die(f"deploy/services.toml: {where} {field} {value} is out of range "
            f"({low}-{high})")
    return value


def _validate_probes(m: "Manifest") -> None:
    """Every [mcp.*] must declare its probe: the probe columns are consumed as a
    complete, index-aligned table, and a server silently missing from it is
    exactly the drift this manifest exists to prevent."""
    for e in m.mcp:
        where = f"[mcp.{e.container}]"
        if not e.token_var:
            die(f"deploy/services.toml: {where} needs token_var "
                f"(the variable in its token.env)")
        if not _ENV_RE.fullmatch(e.token_var):
            die(f"deploy/services.toml: {where} token_var must be an env-var name")
        if not e.probe_tool:
            die(f"deploy/services.toml: {where} needs probe_tool")
        try:
            args = json.loads(e.probe_args)
        except ValueError:
            die(f"deploy/services.toml: {where} probe_args is not JSON")
        if not isinstance(args, dict):
            die(f"deploy/services.toml: {where} probe_args must be a JSON object")
        if e.spend_token_var and not _ENV_RE.fullmatch(e.spend_token_var):
            die(f"deploy/services.toml: {where} spend_token_var must be an env-var name")


def _host(data: dict, key: str, hosts: Dict[str, Host], where: str) -> Host:
    host = hosts.get(key)
    if host is None:
        die(f"deploy/services.toml: [{where}] names host '{key}', "
            f"but there is no [host.{key}]")
    return host


def load(path: str) -> Manifest:
    if tomllib is None:
        die("reading deploy/services.toml needs Python 3.11+ (tomllib); "
            "bootstrap.sh installs a newer python3")
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        die(f"the service manifest is missing: {path}")
    except tomllib.TOMLDecodeError as e:
        die(f"deploy/services.toml does not parse: {e}")

    m = Manifest()

    # --- the hosts, in file order, env overrides applied -------------------
    domains: Dict[str, str] = {}
    for key, table in _table(data, "host").items():
        where = f"[host.{key}]"
        if not isinstance(table, dict):
            die(f"deploy/services.toml: {where} must be a table")
        domain = _text(table, "domain", where)
        env = str(table.get("env", key.upper()))
        # The operator override: a non-empty $<env> wins, like ${VAR:-default}.
        domain = os.environ.get(env) or domain
        if not domain:
            die(f"deploy/services.toml: {where} resolves to an empty domain")
        if domain in domains:
            die(f"deploy/services.toml: {where} and [host.{domains[domain]}] "
                f"both serve {domain}")
        domains[domain] = key
        m.hosts[key] = Host(key, domain, env, bool(table.get("kuma_add_host", True)))

    # --- the MCP servers ----------------------------------------------------
    seen_prefixes: Dict[str, str] = {}
    seen_containers: Dict[str, str] = {}
    seen_ports: Dict[int, str] = {}
    for key, table in _table(data, "mcp").items():
        where = f"[mcp.{key}]"
        if not isinstance(table, dict):
            die(f"deploy/services.toml: {where} must be a table")
        prefix = _text(table, "prefix", where)
        container = _text(table, "container", where)
        port = _number(table.get("port"), where, "port", 1, _MAX_PORT)
        # The prefix is a URL path segment and one of the bash emitters' keys;
        # a ':' or '|' in it would be a different declaration in the emission.
        if not prefix.startswith("/") or len(prefix) < 2 \
                or any(c in prefix for c in ":| \t"):
            die(f"deploy/services.toml: {where} prefix '{prefix}' is not a path "
                f"(want \"/name\")")
        if not _CONTAINER_RE.fullmatch(container):
            die(f"deploy/services.toml: {where} container '{container}' is not a "
                f"container name")
        entry = McpHost(prefix, container, port)
        for seen, value, label in ((seen_prefixes, entry.prefix, "prefix"),
                                   (seen_containers, entry.container, "container")):
            if value in seen:
                die(f"deploy/services.toml: {where} reuses the {label} "
                    f"of [mcp.{seen[value]}] ({value})")
            seen[value] = key
        if entry.port in seen_ports:
            die(f"deploy/services.toml: {where} and [mcp.{seen_ports[entry.port]}] "
                f"both publish loopback port {entry.port}")
        seen_ports[entry.port] = key
        for field in ("token_var", "probe_tool", "probe_args", "spend_token_var"):
            if not isinstance(table.get(field, ""), str):
                die(f"deploy/services.toml: {where} {field} must be a string")
        if not isinstance(table.get("needs_nodes", False), bool):
            die(f"deploy/services.toml: {where} needs_nodes must be true or false")
        entry.token_var = table.get("token_var", "")
        entry.probe_tool = table.get("probe_tool", "")
        entry.probe_args = table.get("probe_args", "{}")
        entry.needs_nodes = table.get("needs_nodes", False)
        entry.spend_token_var = table.get("spend_token_var", "")
        m.mcp.append(entry)

    # --- the proxy hosts -----------------------------------------------------
    mcp_ports = {e.port for e in m.mcp}
    npm_domains: Dict[str, str] = {}
    for key, table in _table(data, "npm").items():
        where = f"[npm.{key}]"
        if not isinstance(table, dict):
            die(f"deploy/services.toml: {where} must be a table")
        if "domain" in table:
            domain = _text(table, "domain", where)
        else:
            domain = _host(data, str(table.get("host", "")), m.hosts, f"npm.{key}").domain
        forward_host = _text(table, "forward_host", where)
        forward_port = _number(table.get("forward_port"), where, "forward_port",
                               1, _MAX_PORT)
        scheme = str(table.get("scheme", "http"))
        if scheme not in ("http", "https"):
            die(f"deploy/services.toml: {where} scheme '{scheme}' is neither "
                f"http nor https")
        flags = table.get("flags", [])
        if not isinstance(flags, list) or not all(
                isinstance(f, str) and _FLAG_RE.fullmatch(f) for f in flags):
            die(f"deploy/services.toml: {where} flags must be a list of names "
                f"like force-ssl, http2, ws, block, mcp")
        host = NpmHost(domain, scheme, forward_host, forward_port, ",".join(flags))
        if host.domain in npm_domains:
            die(f"deploy/services.toml: {where} and [npm.{npm_domains[host.domain]}] "
                f"both serve {host.domain}")
        npm_domains[host.domain] = key
        if host.has_flag("mcp") and host.port not in mcp_ports:
            die(f"deploy/services.toml: {where} carries the mcp flag but forwards "
                f"to {host.port}, which no [mcp.*] entry publishes")
        m.npm.append(host)

    # --- the onion services ---------------------------------------------------
    for key, table in _table(data, "onion").items():
        where = f"[onion.{key}]"
        if not isinstance(table, dict):
            die(f"deploy/services.toml: {where} must be a table")
        target = _text(table, "target", where)
        if not _TARGET_RE.fullmatch(target):
            die(f"deploy/services.toml: {where} target '{target}' is not "
                f"host:port (tor validates it, so a name that does not resolve "
                f"keeps tor from starting)")
        mirrors = _host(data, str(table.get("mirrors", "")), m.hosts,
                        f"onion.{key}").domain
        path = str(table.get("path", "/"))
        if not path.startswith("/"):
            die(f"deploy/services.toml: {where} path '{path}' must start with /")
        codes = table.get("codes", [])
        if not isinstance(codes, list) or not codes \
                or not all(isinstance(c, int) and 100 <= c <= 599 for c in codes):
            die(f"deploy/services.toml: {where} codes must be HTTP status codes")
        m.onion.append(OnionService(key, target, mirrors, path,
                                    [str(c) for c in codes]))

    # --- the status page's monitors --------------------------------------------
    # [kuma.monitor.*] nests two levels deep in TOML, unlike the flat tables
    # above: data["kuma"]["monitor"][<key>].
    names: Dict[str, str] = {}
    for key, table in _table(_table(data, "kuma"), "monitor").items():
        where = f"[kuma.monitor.{key}]"
        if not isinstance(table, dict):
            die(f"deploy/services.toml: {where} must be a table")
        name = _text(table, "name", where)
        if name in names:
            die(f"deploy/services.toml: {where} and "
                f"[kuma.monitor.{names[name]}] are both named \"{name}\"")
        names[name] = key
        interval = _number(table.get("interval", 60), where, "interval", 1, 86400)
        retries = _number(table.get("retries", 2), where, "retries", 1, 10)
        if "tcp" in table:
            if "host" in table or "path" in table or "codes" in table:
                die(f"deploy/services.toml: {where} declares tcp AND host/path/codes; "
                    f"a port monitor takes no URL or status codes")
            target = _text(table, "tcp", where)
            if not _TARGET_RE.fullmatch(target):
                die(f"deploy/services.toml: {where} tcp '{target}' is not host:port")
            hostname, _, port_s = target.rpartition(":")
            m.kuma_monitors.append(KumaMonitor(
                name, "port", url=f"tcp://{target}", hostname=hostname,
                port=int(port_s), interval=interval, retry_interval=interval,
                maxretries=retries))
            continue
        host = _host(data, str(table.get("host", "")), m.hosts, f"kuma.monitor.{key}")
        codes = table.get("codes", ["200-299"])
        if not isinstance(codes, list) or not codes or not all(
                isinstance(c, str) and _CODES_RE.fullmatch(c) for c in codes):
            die(f"deploy/services.toml: {where} codes must be ranges like "
                f"\"200-299\" (a token-gated endpoint answers 401, which counts as up)")
        mon_path = str(table.get("path", ""))
        if mon_path and not mon_path.startswith("/"):
            die(f"deploy/services.toml: {where} path '{mon_path}' must start with /")
        m.kuma_monitors.append(KumaMonitor(
            name, "http", url=f"https://{host.domain}{mon_path}", codes=list(codes),
            interval=interval, retry_interval=interval, maxretries=retries))

    page = _table(_table(data, "kuma"), "page")
    if page:
        m.kuma_page = KumaPage(
            slug=str(page.get("slug", "")),
            title=str(page.get("title", "BoltMesh services")),
            group=str(page.get("group", "Public services")),
        )

    kuma = _table(data, "uptime_kuma")
    m.kuma_loopback = _number(kuma.get("loopback_port", 8107), "[uptime_kuma]",
                              "loopback_port", 1, _MAX_PORT)
    return m


# --- the CI check -------------------------------------------------------------
def check(path: str, agents_path: Optional[str] = None) -> int:
    m = load(path)
    _validate_probes(m)
    print(f"manifest: {len(m.hosts)} host(s), {len(m.mcp)} mcp server(s), "
          f"{len(m.npm)} proxy host(s), {len(m.onion)} onion service(s), "
          f"{len(m.kuma_monitors)} monitor(s)")
    if agents_path:
        _check_agents(m, agents_path)
    return 0


def _check_agents(m: Manifest, agents_path: str) -> None:
    # AGENTS.md's interface table is the contract with the app repos; it is
    # maintained by hand, so this is the one drift a manifest edit can cause
    # that nothing else would notice. A row is matched by the manifest's own
    # facts (container name + loopback port in the same line), and the count
    # of rows carrying an MCP port must equal the manifest's server count --
    # so a server deleted here fails the check until the table follows.
    try:
        with open(agents_path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        die(f"could not read {agents_path} for the manifest cross-check")
    ports = {e.port for e in m.mcp}
    rows = [l for l in lines
            if l.startswith("| `") and any(f"127.0.0.1:{p}" in l for p in ports)]
    if len(rows) != len(m.mcp):
        die(f"{agents_path}: the interface table has {len(rows)} row(s) carrying an "
            f"MCP loopback port, but the manifest declares {len(m.mcp)} server(s)")
    for e in m.mcp:
        row = next((l for l in rows if f"`{e.container}`" in l), None)
        if row is None:
            die(f"{agents_path}: no interface-table row for the container "
                f"`{e.container}` (manifest entry {e.prefix})")
        if f"127.0.0.1:{e.port}" not in row:
            die(f"{agents_path}: the row for `{e.container}` does not carry its "
                f"loopback publish 127.0.0.1:{e.port}")
    print(f"agents table: {len(m.mcp)} mcp row(s) agree with the manifest")


def main(argv: List[str]) -> int:
    # argv is what __main__'s dispatch passes after the command word:
    #   ["shell", "deploy/services.toml"]
    #   ["check", "deploy/services.toml", "--agents", "AGENTS.md"]
    if len(argv) < 2 or argv[0] not in ("shell", "check"):
        print("usage: python3 -m stackctl manifest {shell|check} <services.toml> "
              "[--agents AGENTS.md]", file=sys.stderr)
        return 2
    mode, path, rest = argv[0], argv[1], argv[2:]
    agents: Optional[str] = None
    if "--agents" in rest:
        i = rest.index("--agents")
        if i + 1 >= len(rest):
            die("--agents needs a path")
        agents = rest[i + 1]
    if mode == "shell":
        sys.stdout.write(load(path).shell())
        return 0
    return check(path, agents)
