# deploy/services.toml: the loader, the shell emission, and the CI check.
#
# This file is what turned five parallel lists in stack.conf (MCP_HOSTS,
# NPM_HOSTS, ONION_SERVICES, KUMA_MONITORS and the *_HOST scalars) into ONE
# declaration. Two audiences read it:
#
#   * the Python reconcilers (npm.py, kuma.py) -- typed objects, directly;
#   * the bash callers (deploy.sh, verify.sh, deploy/install.sh) -- through
#     `manifest shell`, which emits the SAME variable names they always
#     sourced from stack.conf (plus MCP_PROBES, verify.sh's probe table, which
#     has no stack.conf predecessor), so scripts/lib.sh's load_manifest is a
#     one-line addition per consumer and no caller's body changed. The
#     emission is only NAME='value' lines and array assignments, and is
#     eval-safe by construction (shlex.quote).
#
# Operator overrides keep the old contract: every [host.*] carries an `env`
# name, and a non-empty $<env> in the process environment wins over the
# TOML's `domain` -- exactly what stack.conf's `${VAR:-default}` did, so
# `BOLTMESH_FRONTEND_HOST=staging.example.net ./deploy.sh` still works.
#
# Validation strategy: the TOML tables are THIN -- they reference [host.*]
# keys instead of repeating domains -- and each composed entry goes through
# decl.py's parsers, which are the same validators the old stack.conf strings
# went through. One validation implementation, two input formats, and the
# error messages name the composed entry so the offending line is obvious.
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from typing import Any, Dict, List, Optional

from . import decl
from .ui import die

try:
    import tomllib  # Python 3.11+; the guard gives the clear error below
except ImportError:  # pragma: no cover - the host bootstrap installs 3.12
    tomllib = None


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


class Manifest:
    def __init__(self) -> None:
        self.hosts: Dict[str, Host] = {}
        self.mcp: List[decl.McpHost] = []
        self.npm: List[decl.NpmHost] = []
        self.onion: List[decl.OnionService] = []
        self.kuma_monitors: List[decl.KumaMonitor] = []
        self.kuma_page: Optional[KumaPage] = None
        self.kuma_loopback: int = 8107

    # --- the emission the bash callers eval -------------------------------
    def shell(self) -> str:
        _validate_probes(self)
        lines = []
        for host in self.hosts.values():
            lines.append(f"{host.env}={shlex.quote(host.domain)}")
        if self.mcp:
            entries = " ".join(shlex.quote(f"{m.prefix}:{m.container}:{m.port}") for m in self.mcp)
            lines.append(f"MCP_HOSTS=({entries})")
            # verify.sh's probe table: container|token-var|tool|args|needs-nodes.
            # The env file is the container's own token.env by convention, so it
            # is not repeated here.
            probes = " ".join(shlex.quote(_probe_entry(m)) for m in self.mcp)
            lines.append(f"MCP_PROBES=({probes})")
        if self.onion:
            entries = " ".join(shlex.quote(o.raw) for o in self.onion)
            lines.append(f"ONION_SERVICES=({entries})")
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


def _table(data: dict, name: str) -> Dict[str, Any]:
    table = data.get(name)
    if table is None:
        return {}
    if not isinstance(table, dict):
        die(f"deploy/services.toml: [{name}] must be a table")
    return table


def _probe_entry(e: decl.McpHost) -> str:
    """One verify.sh probe record. `|` is the bash field separator, so the
    fields must not contain one; probe_args is JSON and validated below."""
    return "|".join((
        e.container, e.token_var, e.probe_tool, e.probe_args,
        "1" if e.needs_nodes else "0",
    ))


def _validate_probes(m: "Manifest") -> None:
    """Every [mcp.*] must declare its probe: MCP_PROBES is consumed as a complete
    table, and a server silently missing from it is exactly the drift this
    manifest exists to prevent."""
    for e in m.mcp:
        where = f"[mcp.{e.container}]"
        if not e.token_var:
            die(f"deploy/services.toml: {where} needs token_var "
                f"(the variable in its token.env)")
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", e.token_var):
            die(f"deploy/services.toml: {where} token_var must be an env-var name")
        if not e.probe_tool:
            die(f"deploy/services.toml: {where} needs probe_tool")
        if "|" in e.probe_args:
            die(f"deploy/services.toml: {where} probe_args must not contain '|'")
        try:
            args = json.loads(e.probe_args)
        except ValueError:
            die(f"deploy/services.toml: {where} probe_args is not JSON")
        if not isinstance(args, dict):
            die(f"deploy/services.toml: {where} probe_args must be a JSON object")


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
        if not isinstance(table, dict) or "domain" not in table:
            die(f"deploy/services.toml: [host.{key}] needs a domain")
        domain = str(table["domain"])
        env = str(table.get("env", key.upper()))
        # The operator override: a non-empty $<env> wins, like ${VAR:-default}.
        domain = os.environ.get(env) or domain
        if not domain:
            die(f"deploy/services.toml: [host.{key}] resolves to an empty domain")
        if domain in domains:
            die(f"deploy/services.toml: [host.{key}] and [host.{domains[domain]}] "
                f"both serve {domain}")
        domains[domain] = key
        m.hosts[key] = Host(key, domain, env, bool(table.get("kuma_add_host", True)))

    # --- the MCP servers ----------------------------------------------------
    seen_prefixes: Dict[str, str] = {}
    seen_containers: Dict[str, str] = {}
    seen_ports: Dict[int, str] = {}
    for key, table in _table(data, "mcp").items():
        if not isinstance(table, dict):
            die(f"deploy/services.toml: [mcp.{key}] must be a table")
        prefix = str(table.get("prefix", ""))
        container = str(table.get("container", ""))
        port = table.get("port")
        entry = decl.parse_mcp_host(f"{prefix}:{container}:{port}")
        for seen, value, label in ((seen_prefixes, entry.prefix, "prefix"),
                                   (seen_containers, entry.container, "container")):
            if value in seen:
                die(f"deploy/services.toml: [mcp.{key}] reuses the {label} "
                    f"of [mcp.{seen[value]}] ({value})")
            seen[value] = key
        if entry.port in seen_ports:
            die(f"deploy/services.toml: [mcp.{key}] and [mcp.{seen_ports[entry.port]}] "
                f"both publish loopback port {entry.port}")
        seen_ports[entry.port] = key
        for field in ("token_var", "probe_tool", "probe_args"):
            if not isinstance(table.get(field, ""), str):
                die(f"deploy/services.toml: [mcp.{key}] {field} must be a string")
        if not isinstance(table.get("needs_nodes", False), bool):
            die(f"deploy/services.toml: [mcp.{key}] needs_nodes must be true or false")
        entry.token_var = table.get("token_var", "")
        entry.probe_tool = table.get("probe_tool", "")
        entry.probe_args = table.get("probe_args", "{}")
        entry.needs_nodes = table.get("needs_nodes", False)
        m.mcp.append(entry)

    # --- the proxy hosts -----------------------------------------------------
    mcp_ports = {e.port for e in m.mcp}
    npm_domains: Dict[str, str] = {}
    for key, table in _table(data, "npm").items():
        if not isinstance(table, dict):
            die(f"deploy/services.toml: [npm.{key}] must be a table")
        forward = str(table.get("forward", ""))
        flags = table.get("flags", [])
        if not isinstance(flags, list):
            die(f"deploy/services.toml: [npm.{key}] flags must be a list")
        flags_str = ",".join(str(f) for f in flags)
        if "domain" in table:
            domain = str(table["domain"])
        else:
            domain = _host(data, str(table.get("host", "")), m.hosts, f"npm.{key}").domain
        host = decl.parse_npm_host(f"{domain}|{forward}|{flags_str}")
        if host.domain in npm_domains:
            die(f"deploy/services.toml: [npm.{key}] and [npm.{npm_domains[host.domain]}] "
                f"both serve {host.domain}")
        npm_domains[host.domain] = key
        if host.has_flag("mcp") and host.port not in mcp_ports:
            die(f"deploy/services.toml: [npm.{key}] carries the mcp flag but forwards "
                f"to {host.port}, which no [mcp.*] entry publishes")
        m.npm.append(host)

    # --- the onion services ---------------------------------------------------
    for key, table in _table(data, "onion").items():
        if not isinstance(table, dict):
            die(f"deploy/services.toml: [onion.{key}] must be a table")
        target = str(table.get("target", ""))
        mirrors = _host(data, str(table.get("mirrors", "")), m.hosts, f"onion.{key}").domain
        path = str(table.get("path", "/"))
        codes = table.get("codes", [])
        if not isinstance(codes, list) or not codes \
                or not all(isinstance(c, int) and 100 <= c <= 599 for c in codes):
            die(f"deploy/services.toml: [onion.{key}] codes must be HTTP status codes")
        entry = decl.parse_onion_service(
            f"{key}|{target}|{mirrors}|{path}|{','.join(str(c) for c in codes)}")
        m.onion.append(entry)

    # --- the status page's monitors --------------------------------------------
    # [kuma.monitor.*] nests two levels deep in TOML, unlike the flat tables
    # above: data["kuma"]["monitor"][<key>].
    names: Dict[str, str] = {}
    for key, table in _table(_table(data, "kuma"), "monitor").items():
        if not isinstance(table, dict):
            die(f"deploy/services.toml: [kuma.monitor.{key}] must be a table")
        name = str(table.get("name", ""))
        if name in names:
            die(f"deploy/services.toml: [kuma.monitor.{key}] and "
                f"[kuma.monitor.{names[name]}] are both named \"{name}\"")
        names[name] = key
        interval = int(table.get("interval", 60))
        retries = int(table.get("retries", 2))
        if "tcp" in table:
            entry = f"{name}|tcp://{table['tcp']}||{interval}|{retries}"
        else:
            host = _host(data, str(table.get("host", "")), m.hosts, f"kuma.monitor.{key}")
            codes = table.get("codes", ["200-299"])
            if not isinstance(codes, list):
                die(f"deploy/services.toml: [kuma.monitor.{key}] codes must be a list")
            path = str(table.get("path", ""))
            entry = f"{name}|https://{host.domain}{path}|{','.join(str(c) for c in codes)}|{interval}|{retries}"
        m.kuma_monitors.append(decl.parse_kuma_monitor(entry))

    page = _table(_table(data, "kuma"), "page")
    if page:
        m.kuma_page = KumaPage(
            slug=str(page.get("slug", "")),
            title=str(page.get("title", "BoltMesh services")),
            group=str(page.get("group", "Public services")),
        )

    kuma = _table(data, "uptime_kuma")
    port = int(kuma.get("loopback_port", 8107))
    if not 1 <= port <= 65535:
        die(f"deploy/services.toml: [uptime_kuma] loopback_port {port} is not a port")
    m.kuma_loopback = port
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
