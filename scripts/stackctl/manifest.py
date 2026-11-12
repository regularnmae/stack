# deploy/services.toml: the declarations, the loader, and the shell emission.
#
# This file owns every cross-cutting registry fact the stack has -- the DNS
# names it answers on, which loopback publishes nginx-proxy-manager forwards to,
# the MCP path prefixes, and the tor onion services -- so there is one
# declaration and no parallel lists. It replaced the five tables stack.conf used
# to carry (the MCP prefixes, the proxy hosts, the onion services, the
# status-page monitors and the *_HOST scalars), each of which had to be edited in
# step with the others and with the table in AGENTS.md -- and the two Markdown
# tables that repeated it are now generated from here.
#
# Three audiences read the TOML, and none sees a second grammar:
#
#   * the Python reconciler (npm.py) -- these typed objects, directly;
#   * the bash callers (deploy.sh, verify.sh, monitor.sh, deploy/install.sh,
#     rotate.sh) -- through `manifest shell`, which emits the same variable names
#     they always sourced from stack.conf (plus the probe table verify.sh and
#     rotate.sh need, which has no stack.conf predecessor). scripts/lib.sh's
#     load_manifest is a one-line addition per consumer.
#   * stackctl docs -- the same objects again, rendered into the two Markdown
#     tables AGENTS.md and README used to repeat by hand.
#
# The fields are validated here, once, as they are read: each table is checked
# field by field and an error names the TOML table it came from. Nothing composes
# a string and re-parses it, so there is no second format to keep in step.
#
# `check` goes one step further than `load`: it reads deploy/ and reconciles
# every [mcp.*] port and [npm.*] forward with the unit that publishes it. A
# manifest that forwards to a port no unit publishes, or to another live
# service's port, is internally valid -- only the pair can prove it.
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
from typing import Any, Dict, List, Optional, Tuple

from . import units as units_mod
from .ui import die

try:
    import tomllib  # Python 3.11+; the guard gives the clear error below
except ImportError:  # pragma: no cover - the host bootstrap installs 3.12
    tomllib = None

# A vhost flag ("force-ssl", "mcp", ...) and a container name.
_FLAG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_CONTAINER_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]*$")
_ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
# A [host.*] env name is emitted as `NAME=domain` ahead of every array, so one
# that collides with a name the emission itself defines is silently overwritten
# below it (the override stops working), and a shell special would clobber the
# caller's own environment inside the eval.
_RESERVED_ENVS = frozenset({
    "MCP_PREFIXES", "MCP_CONTAINERS", "MCP_PORTS",
    "PROBE_TOKEN_VARS", "PROBE_TOOLS", "PROBE_ARGS",
    "PROBE_NEEDS_NODES", "PROBE_SPEND_VARS",
    "ONION_NAMES", "ONION_TARGETS", "ONION_MIRRORS", "ONION_PATHS", "ONION_CODES",
    "NPM_DOMAINS", "NPM_NEEDS_NODES", "KUMA_ADD_HOST_HOSTS", "KUMA_STATUS_SLUG",
    "PATH", "IFS", "HOME", "PWD", "OLDPWD", "SHELL", "USER", "LOGNAME",
    "ENV", "BASH_ENV", "PS1", "PS4", "CDPATH", "GLOBIGNORE", "SHELLOPTS",
})
# tor's HiddenServicePort target: a name or address and a numeric port.
_TARGET_RE = re.compile(r"^[A-Za-z0-9_.-]+:[0-9]+$")
# An [mcp.*] upstream: the same, with an optional path (monero-wallet's
# /json_rpc, searxng's /search).
_UPSTREAM_RE = re.compile(r"^[A-Za-z0-9_.-]+:[0-9]+(/[^\s]*)?$")
_MAX_PORT = 65535


class Host:
    __slots__ = ("key", "domain", "env", "kuma_add_host")

    def __init__(self, key: str, domain: str, env: str, kuma_add_host: bool):
        self.key = key
        self.domain = domain
        self.env = env
        self.kuma_add_host = kuma_add_host


class KumaPage:
    """The [kuma] page slug, kept only so verify.sh can tell "not published yet"
    from "broken". The page itself -- title, group, monitors, layout -- belongs to
    the Uptime-Kuma UI, which is the only thing that writes it."""

    __slots__ = ("slug",)

    def __init__(self, slug: str):
        self.slug = slug


class NpmHost:
    """One [npm.*] proxy host: the name NPM serves and where it forwards.

    `container` is the unit whose loopback publish this vhost fronts; it is
    empty only on an `mcp` host, whose targets are the [mcp.*] entries.
    `needs_nodes` marks a vhost whose upstream is in stack.conf's CHAIN_UNITS:
    on a host deployed with ./deploy.sh --skip-daemons nothing answers on that
    publish, and scripts/monitor.sh skips the name instead of failing a 502.
    """

    __slots__ = ("domain", "scheme", "host", "port", "flags", "container",
                 "needs_nodes")

    def __init__(self, domain: str, scheme: str, host: str, port: int,
                 flags: str, container: str = ""):
        self.domain = domain
        self.scheme = scheme
        self.host = host
        self.port = port
        self.flags = flags  # the comma-separated string, as declared
        self.container = container
        self.needs_nodes = False

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
    for everything but the two money servers. `upstream` is the image's default
    endpoint, stated once for AGENTS.md's generated interface table.
    """

    __slots__ = ("prefix", "container", "port", "token_var", "probe_tool",
                 "probe_args", "needs_nodes", "spend_token_var", "upstream")

    def __init__(self, prefix: str, container: str, port: int):
        self.prefix = prefix
        self.container = container
        self.port = port
        self.token_var = ""
        self.probe_tool = ""
        self.probe_args = "{}"
        self.needs_nodes = False
        self.spend_token_var = ""
        self.upstream = ""


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


class Manifest:
    def __init__(self) -> None:
        self.hosts: Dict[str, Host] = {}
        self.mcp: List[McpHost] = []
        self.npm: List[NpmHost] = []
        self.onion: List[OnionService] = []
        self.kuma_page: Optional[KumaPage] = None

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
        # The clearweb vhosts, for monitor.sh's public-surface probe (the onion
        # wildcard has no name to probe; tor publishes those separately). One
        # entry per [npm.*] host, so a new public name is monitored the moment
        # it is declared. NPM_NEEDS_NODES is index-aligned with it: the sweep
        # cannot tell a dead upstream from one that --skip-daemons never
        # started, so the declaration says which.
        public = [h for h in self.npm if not h.domain.endswith(".onion")]
        if public:
            lines.append(_array("NPM_DOMAINS", [h.domain for h in public]))
            lines.append(_array("NPM_NEEDS_NODES",
                                ["1" if h.needs_nodes else "0" for h in public]))
        # The vhosts uptime-kuma's own UI-authored monitors may resolve on the
        # host (install.sh renders --add-host=<domain>:host-gateway per entry):
        # every host whose [host.*] did not opt out.
        add_hosts = [h.domain for h in self.hosts.values() if h.kuma_add_host]
        if add_hosts:
            entries = " ".join(shlex.quote(d) for d in add_hosts)
            lines.append(f"KUMA_ADD_HOST_HOSTS=({entries})")
        if self.kuma_page is not None:
            lines.append(f"KUMA_STATUS_SLUG={shlex.quote(self.kuma_page.slug)}")
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


def _bool(table: dict, field: str, where: str, default: bool) -> bool:
    value = table.get(field, default)
    if not isinstance(value, bool):
        die(f"deploy/services.toml: {where} {field} must be true or false")
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
        if not e.upstream:
            die(f"deploy/services.toml: {where} needs upstream "
                f"(the image's default endpoint, for the generated interface table)")
        if not _UPSTREAM_RE.fullmatch(e.upstream):
            die(f"deploy/services.toml: {where} upstream '{e.upstream}' is not "
                f"host:port[/path]")


def _host(data: dict, key: str, hosts: Dict[str, Host], where: str) -> Host:
    host = hosts.get(key)
    if host is None:
        die(f"deploy/services.toml: [{where}] names host '{key}', "
            f"but there is no [host.{key}]")
    return host


def load(path: str, overrides: bool = True) -> Manifest:
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
    envs: Dict[str, str] = {}
    for key, table in _table(data, "host").items():
        where = f"[host.{key}]"
        if not isinstance(table, dict):
            die(f"deploy/services.toml: {where} must be a table")
        domain = _text(table, "domain", where)
        env = table.get("env", key.upper())
        if not isinstance(env, str) or not _ENV_RE.fullmatch(env):
            die(f"deploy/services.toml: {where} env must be an env-var name "
                f"(like {key.upper()})")
        if env in _RESERVED_ENVS:
            die(f"deploy/services.toml: {where} env '{env}' is a name the "
                f"emission itself sets; pick another")
        if env in envs:
            die(f"deploy/services.toml: {where} and [host.{envs[env]}] both "
                f"read ${env}; one would overwrite the other")
        envs[env] = key
        kuma_add_host = _bool(table, "kuma_add_host", where, True)
        # The operator override: a non-empty $<env> wins, like ${VAR:-default}.
        # Generated docs pass overrides=False: a committed file must not carry
        # the domain of whichever host happened to run the render.
        domain = (os.environ.get(env) if overrides else None) or domain
        if not domain:
            die(f"deploy/services.toml: {where} resolves to an empty domain")
        if domain in domains:
            die(f"deploy/services.toml: {where} and [host.{domains[domain]}] "
                f"both serve {domain}")
        domains[domain] = key
        m.hosts[key] = Host(key, domain, env, kuma_add_host)

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
        for field in ("token_var", "probe_tool", "probe_args", "spend_token_var",
                      "upstream"):
            if not isinstance(table.get(field, ""), str):
                die(f"deploy/services.toml: {where} {field} must be a string")
        entry.token_var = table.get("token_var", "")
        entry.probe_tool = table.get("probe_tool", "")
        entry.probe_args = table.get("probe_args", "{}")
        entry.needs_nodes = _bool(table, "needs_nodes", where, False)
        entry.spend_token_var = table.get("spend_token_var", "")
        entry.upstream = table.get("upstream", "")
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
        container = ""
        if "container" in table:
            container = _text(table, "container", where)
            if not _CONTAINER_RE.fullmatch(container):
                die(f"deploy/services.toml: {where} container '{container}' is "
                    f"not a container name")
        scheme = str(table.get("scheme", "http"))
        if scheme not in ("http", "https"):
            die(f"deploy/services.toml: {where} scheme '{scheme}' is neither "
                f"http nor https")
        flags = table.get("flags", [])
        if not isinstance(flags, list) or not all(
                isinstance(f, str) and _FLAG_RE.fullmatch(f) for f in flags):
            die(f"deploy/services.toml: {where} flags must be a list of names "
                f"like force-ssl, http2, ws, block, mcp")
        host = NpmHost(domain, scheme, forward_host, forward_port,
                       ",".join(flags), container)
        host.needs_nodes = _bool(table, "needs_nodes", where, False)
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

    # --- the status page ------------------------------------------------------
    # The page, its monitors and their layout are authored in Uptime-Kuma's UI.
    # Only the slug is declared, so verify.sh can probe the published page.
    page = _table(_table(data, "kuma"), "page")
    if page:
        m.kuma_page = KumaPage(slug=str(page.get("slug", "")))
    return m


# --- the manifest/unit cross-check -------------------------------------------
def _loopback_publishes(
        units: Dict[str, units_mod.Unit]) -> Dict[str, List[Tuple[str, str]]]:
    """host-side address -> [(unit name, container side)] for every publish."""
    published: Dict[str, List[Tuple[str, str]]] = {}
    for unit in units.values():
        for host_side, container_side in unit.ports:
            published.setdefault(host_side, []).append((unit.name, container_side))
    return published


def _ports_text(unit: units_mod.Unit) -> str:
    return ", ".join(f"{host}:{container}" for host, container in unit.ports) \
        or "no PublishPort"


def cross_check(m: "Manifest", units: Dict[str, units_mod.Unit]) -> None:
    """Reconcile the manifest's port claims with the units that publish them.

    The manifest declares NPM's targets and each MCP server's loopback publish;
    the unit declares the actual PublishPort=. Validating the manifest against
    itself cannot see a target no unit publishes, or one another live service
    owns, so `check` reads deploy/ and compares the pair here.
    """
    published = _loopback_publishes(units)

    for entry in m.mcp:
        where = f"[mcp.*] {entry.container}"
        unit = units.get(entry.container)
        if unit is None:
            die(f"deploy/services.toml: {where} names container "
                f"'{entry.container}', but no unit in deploy/ has that "
                f"ContainerName")
        if unit.network_host:
            if unit.ports:
                die(f"deploy/services.toml: {where} port {entry.port}: "
                    f"{unit.path} is Network=host, so it must not publish a "
                    f"port (found {_ports_text(unit)})")
            mcp_host = unit.environment.get("MCP_HOST")
            if mcp_host != "127.0.0.1":
                die(f"deploy/services.toml: {where} port {entry.port}: "
                    f"{unit.path} sets MCP_HOST={mcp_host or '<unset>'}; the "
                    f"host-network exception must bind 127.0.0.1")
            mcp_port = unit.environment.get("MCP_PORT")
            if mcp_port != str(entry.port):
                die(f"deploy/services.toml: {where} port {entry.port}: "
                    f"{unit.path} sets MCP_PORT={mcp_port or '<unset>'} "
                    f"(want {entry.port})")
            continue
        key = f"127.0.0.1:{entry.port}"
        own = [container for host, container in unit.ports if host == key]
        if own != ["8000"]:
            die(f"deploy/services.toml: {where} port {entry.port}: "
                f"{unit.path} must publish {key}:8000 "
                f"(found {_ports_text(unit)})")
        others = sorted({name for name, _ in published.get(key, [])
                         if name != entry.container})
        if others:
            die(f"deploy/services.toml: {where} port {entry.port}: {key} is "
                f"also published by {', '.join(others)}")

    for host in m.npm:
        where = f"[npm.*] {host.domain}"
        if host.host != "127.0.0.1":
            die(f"deploy/services.toml: {where} forward_host is "
                f"'{host.host}'; NPM runs on the host network, so it must be "
                f"127.0.0.1")
        key = f"127.0.0.1:{host.port}"
        matches = published.get(key, [])
        if host.container:
            unit = units.get(host.container)
            if unit is None:
                die(f"deploy/services.toml: {where} names container "
                    f"'{host.container}', but no unit in deploy/ has that "
                    f"ContainerName")
            names = sorted({name for name, _ in matches})
            if names == [host.container]:
                continue
            if not names:
                die(f"deploy/services.toml: {where} names container "
                    f"'{host.container}', but no unit publishes {key} "
                    f"({unit.path} publishes {_ports_text(unit)})")
            if host.container not in names:
                die(f"deploy/services.toml: {where} names container "
                    f"'{host.container}', but {key} is published by "
                    f"{', '.join(names)}")
            die(f"deploy/services.toml: {where} names container "
                f"'{host.container}', but {key} is published by more than one "
                f"unit: {', '.join(names)}")
        if not host.has_flag("mcp"):
            die(f"deploy/services.toml: {where} needs container = \"<unit>\" "
                f"(the unit whose PublishPort= is {key}); only an mcp host may "
                f"omit it")
        if not matches:
            die(f"deploy/services.toml: {where} forwards to {key}, but no unit "
                f"publishes that loopback address")


# --- the CI check -------------------------------------------------------------
def check(path: str, units_dir: Optional[str] = None) -> int:
    m = load(path)
    _validate_probes(m)
    if units_dir is None:
        units_dir = os.path.dirname(os.path.abspath(path))
    units = units_mod.load_units(units_dir)
    cross_check(m, units)
    print(f"manifest: {len(m.hosts)} host(s), {len(m.mcp)} mcp server(s), "
          f"{len(m.npm)} proxy host(s), {len(m.onion)} onion service(s); "
          f"ports agree with {len(units)} unit(s)")
    return 0


def main(argv: List[str]) -> int:
    # argv is what __main__'s dispatch passes after the command word:
    #   ["shell", "deploy/services.toml"]
    #   ["check", "deploy/services.toml", "--units", "deploy"]
    usage = ("usage: python3 -m stackctl manifest {shell|check} "
             "<services.toml> [--units DIR]")
    if len(argv) < 2 or argv[0] not in ("shell", "check"):
        print(usage, file=sys.stderr)
        return 2
    mode, path = argv[0], argv[1]
    rest = list(argv[2:])
    if mode == "shell":
        if rest:
            print(usage, file=sys.stderr)
            return 2
        sys.stdout.write(load(path).shell())
        return 0
    units_dir = None
    while rest:
        flag = rest.pop(0)
        if flag != "--units" or not rest:
            print(f"unknown or incomplete argument: {flag}", file=sys.stderr)
            return 2
        units_dir = rest.pop(0)
    return check(path, units_dir)
