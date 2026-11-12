# The generated Markdown: README's "What runs" and AGENTS.md's interface tables.
#
# Both were hand-written copies of facts that live in deploy/ and
# deploy/services.toml, held in step by two validators (`stackctl units check`
# and `manifest check --agents`). Here the tables are derived from the
# declaration instead, inside a marked block per table:
#
#   <!-- BEGIN GENERATED: what-runs -->
#   ...
#   <!-- END GENERATED -->
#
# `render` rewrites the block in place; `check` (CI) fails when the committed
# block is not what a fresh render produces. The prose around a block is still
# the operator's, so a cell that is not a fact (why a port is an SSH tunnel,
# what a worker's liveness file proves) belongs in that prose, not the table.
#
# One declaration is deliberately not derived from a block: `stack-bouncer` is
# a root host script with no Quadlet unit, so it has no facts to read.
from __future__ import annotations

import difflib
import os
import sys
from typing import Dict, List, Tuple

from . import manifest as manifest_mod
from . import units as units_mod
from .ui import die

BEGIN = "<!-- BEGIN GENERATED: {name} -->"
END = "<!-- END GENERATED -->"

# The BoltMesh app tier: not MCP servers, so absent from the [mcp.*] table, but
# units like any other. They share the `boltmesh-` prefix (plus the database
# they own), which is how the second table picks its rows.
_APP_NAMES = {"postgres"}
_APP_PREFIX = "boltmesh-"

# A row for a host script with no unit. Its image and published columns are the
# two things the table would otherwise have to read from a file.
_HOST_ROWS = {
    "stack-bouncer": "| `stack-bouncer` ⚙️ | — (a host script on a system timer, "
                     "`deploy/root/bouncer.sh`) | — |",
}


def _container_port(unit: units_mod.Unit) -> str:
    """The port inside the container: the third field of its PublishPort."""
    return unit.ports[0][1] if unit.ports else ""


def _code_list(values: List[str]) -> str:
    return ", ".join(f"`{v}`" for v in values) if values else "—"


def _readme_table(units: Dict[str, units_mod.Unit]) -> str:
    rows: Dict[str, str] = {}
    for unit in units.values():
        if unit.oneshot:
            continue
        marks = ""
        if "spend.env" in unit.env_files:
            marks += " 🔑"
        if unit.root:
            marks += " ⚙️"
        if unit.ports:
            published = ", ".join(f"`{host}`" for host, _ in unit.ports)
        else:
            published = "host network" if unit.network_host else "—"
        rows[unit.name] = f"| `{unit.name}`{marks} | `{unit.image}` | {published} |"
    rows.update(_HOST_ROWS)
    body = ["| Unit | Image | Published on the host |",
            "| --- | --- | --- |"]
    body += [rows[name] for name in sorted(rows)]
    return "\n".join(body)


def _mcp_table(m: manifest_mod.Manifest,
               units: Dict[str, units_mod.Unit]) -> str:
    body = ["| Server | Container / unit / image | Env files "
            "(`$DATA_DIR/config/<app>/`) | Upstream it defaults to "
            "| On npm-network | NPM target |",
            "| --- | --- | --- | --- | --- | --- |"]
    for entry in m.mcp:
        unit = units.get(entry.container)
        if unit is None:
            die(f"{entry.container}: declared in [mcp.*] but no unit in deploy/ "
                f"names it")
        if not entry.upstream:
            die(f"[mcp.*] {entry.container}: no upstream declared")
        if unit.network_host:
            network = "— (`Network=host`)"
        else:
            network = f"`{entry.container}:{_container_port(unit)}`"
        body.append(f"| `{entry.container}` | `{entry.container}` / "
                    f"`{unit.image}` | {_code_list(unit.env_files)} | "
                    f"`{entry.upstream}` | {network} | "
                    f"`127.0.0.1:{entry.port}` |")
    return "\n".join(body)


def _app_tier(units: Dict[str, units_mod.Unit]) -> List[units_mod.Unit]:
    return [units[name] for name in sorted(units)
            if name in _APP_NAMES or name.startswith(_APP_PREFIX)]


def _app_table(units: Dict[str, units_mod.Unit]) -> str:
    body = ["| Unit | Image | Env files | On npm-network | NPM target | Health |",
            "| --- | --- | --- | --- | --- | --- |"]
    for unit in _app_tier(units):
        if unit.network_host:
            network = "— (`Network=host`)"
        elif unit.ports:
            network = f"`{unit.name}:{_container_port(unit)}`"
        else:
            network = "—"
        target = f"`{unit.ports[0][0]}`" if unit.ports else "—"
        health = "—"
        if unit.health_cmd:
            # A probe may pipe; an unescaped | would end the table cell.
            health = "`" + unit.health_cmd.replace("|", "\\|") + "`"
        body.append(f"| `{unit.name}` | `{unit.image}` | "
                    f"{_code_list(unit.env_files)} | {network} | {target} | "
                    f"{health} |")
    return "\n".join(body)


def _format_block(name: str, body: str) -> str:
    # The blank lines are for markdownlint's MD058 (a table needs blank lines
    # around it); the HTML comment would otherwise sit directly above a row.
    return "\n".join([BEGIN.format(name=name), "", body, "", END])


def _splice(text: str, path: str, name: str,
            block: str) -> Tuple[str, str]:
    """Replace one marked block and return the new text and the old block."""
    begin = BEGIN.format(name=name)
    start = text.find(begin)
    if start < 0:
        die(f"{path}: no '{begin}' block -- add the marker where the table goes")
    end = text.find(END, start)
    if end < 0:
        die(f"{path}: '{begin}' has no '{END}'")
    end += len(END)
    return text[:start] + block + text[end:], text[start:end]


def _render_file(path: str, blocks: List[Tuple[str, str]]) -> Tuple[str, int]:
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        die(f"could not read {path}")
    for name, body in blocks:
        text, _ = _splice(text, path, name, _format_block(name, body))
    return text, len(blocks)


def _check_file(path: str, blocks: List[Tuple[str, str]]) -> int:
    try:
        with open(path, encoding="utf-8") as f:
            old_text = f.read()
    except OSError:
        die(f"could not read {path}")
    text = old_text
    failed = 0
    for name, body in blocks:
        new_block = _format_block(name, body)
        text, old_block = _splice(text, path, name, new_block)
        if old_block == new_block:
            continue
        failed += 1
        print(f"  FAIL {path}: the '{name}' block is stale "
              f"(./scripts/docs-render.sh rewrites it)", file=sys.stderr)
        sys.stderr.writelines(line + "\n" for line in difflib.unified_diff(
            old_block.splitlines(), new_block.splitlines(),
            fromfile=f"{path} (committed)", tofile=f"{path} (generated)",
            lineterm=""))
    return failed


def _facts(root: str, units_dir: str, manifest_path: str):
    units = units_mod.load_units(os.path.join(root, units_dir))
    # Operator overrides ($BOLTMESH_API_HOST and friends) must not reach a
    # committed file: a host that exports one would bake its staging name in.
    m = manifest_mod.load(os.path.join(root, manifest_path), overrides=False)
    return units, m


def run(argv: List[str]) -> int:
    if not argv or argv[0] not in ("render", "check"):
        print("usage: python3 -m stackctl docs {render|check} [--root DIR] "
              "[--units DIR] [--manifest PATH] [--readme PATH] [--agents PATH]",
              file=sys.stderr)
        return 2
    mode = argv[0]
    opts = {"--root": ".", "--units": "deploy",
            "--manifest": "deploy/services.toml",
            "--readme": "README.md", "--agents": "AGENTS.md"}
    rest = list(argv[1:])
    while rest:
        flag = rest.pop(0)
        if flag not in opts or not rest:
            print(f"unknown or incomplete argument: {flag}", file=sys.stderr)
            return 2
        opts[flag] = rest.pop(0)
    root = opts["--root"]
    units, m = _facts(root, opts["--units"], opts["--manifest"])
    targets = [
        (os.path.join(root, opts["--readme"]),
         [("what-runs", _readme_table(units))]),
        (os.path.join(root, opts["--agents"]),
         [("agents-mcp", _mcp_table(m, units)),
          ("agents-app", _app_table(units))]),
    ]
    if mode == "render":
        total = 0
        for path, blocks in targets:
            text, count = _render_file(path, blocks)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            total += count
        print(f"docs: rendered {total} block(s) in {len(targets)} file(s)")
        return 0
    failed = sum(_check_file(path, blocks) for path, blocks in targets)
    if failed:
        print(f"{failed} generated block(s) are stale", file=sys.stderr)
        return 1
    print(f"docs: {sum(len(blocks) for _, blocks in targets)} generated "
          f"block(s) are up to date")
    return 0


def main(argv: List[str]) -> int:
    return run(argv)
