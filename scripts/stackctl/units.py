# The README's "What runs" table, checked against the units it describes.
#
# The table is the operator's map of the stack and it is hand-written, which is
# fine for the prose in it (why one port is an SSH tunnel and another is a
# wildcard bind). What it cannot be hand-written about is the facts Renovate
# owns: a pull request bumps `Image=` in a unit, `./deploy.sh --only <svc>`
# ships it, and the table keeps naming the old tag -- the one edit that reaches
# a host without the README following it. Three facts are mechanical, and every
# one of them is currently true, so this is a gate and not a cleanup:
#
#   * coverage -- every unit that is not `Type=oneshot` is named by a row
#     (oneshot jobs have no steady state to report, and the README says so);
#   * image -- the row carries that unit's `Image=` verbatim;
#   * published -- every `PublishPort=<host>:...` names <host> in the row.
#
# `Network=host` is deliberately not checked. Five of the six host-network units
# say so in the row, but nginx-proxy-manager spells out the ports it binds (that
# *is* its job) and netcheck-host shares a row whose Published column is "—"
# (nothing listens). A rule that covers those two needs an exception list, which
# is the thing this check exists to avoid.
#
# The reverse direction is checked too: a row naming something with no unit is
# drift from a deleted unit, unless the name is in HOST_UNITS below.
from __future__ import annotations

import glob
import os
import re
import sys
from typing import Dict, List, Optional

from .ui import die

# Where a unit can live, relative to the units dir (the same three globs
# scripts/healthcheck-lint.sh reads).
_UNIT_GLOBS = ("*.container", "*.container.in", "root/*.container")

# Rows that describe something with no Quadlet unit. stack-bouncer is a root
# oneshot on a system timer (deploy/root/bouncer.sh), so it has no
# ContainerName= for the table to match.
HOST_UNITS = {"stack-bouncer"}

# The three keys that hold a fact the table repeats: the image it names, the host
# side of `PublishPort=[ip:]host:container` (second-to-last field), and the
# oneshot marker that exempts a unit from having a row at all.
_PORT_RE = re.compile(r"^Image=(?P<image>\S+)$|^PublishPort=(?P<port>\S+)$"
                      r"|^Type=(?P<type>\S+)$", re.M)
_TOKEN_RE = re.compile(r"`([^`]+)`")


class Unit:
    """The three facts the table claims about one container unit."""

    __slots__ = ("name", "image", "ports", "oneshot", "path")

    def __init__(self, name: str, path: str):
        self.name = name
        self.path = path
        self.image: Optional[str] = None
        self.ports: List[str] = []
        self.oneshot = False


class Row:
    """One table row: the units it names, and the two cells compared against them."""

    __slots__ = ("line", "names", "image", "published")

    def __init__(self, line: int, names: List[str], image: str, published: str):
        self.line = line
        self.names = names
        self.image = image
        self.published = published


def load_units(units_dir: str) -> Dict[str, Unit]:
    files: List[str] = []
    for pattern in _UNIT_GLOBS:
        files.extend(sorted(glob.glob(os.path.join(units_dir, pattern))))
    if not files:
        die(f"{units_dir}: no container units matched {', '.join(_UNIT_GLOBS)}")
    units: Dict[str, Unit] = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        name = next((m.group(1) for m in re.finditer(r"^ContainerName=(\S+)$",
                                                     text, re.M)), None)
        if name is None:
            continue          # a .container.in template that only renders Exec=
        unit = units.setdefault(name, Unit(name, path))
        for m in _PORT_RE.finditer(text):
            if m.group("image"):
                unit.image = m.group("image")
            elif m.group("port"):
                fields = m.group("port").split(":")
                if len(fields) >= 2:
                    unit.ports.append(fields[-2])
            elif m.group("type") == "oneshot":
                unit.oneshot = True
    return units


def read_rows(readme: str) -> List[Row]:
    try:
        with open(readme, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        die(f"could not read {readme}")
    rows: List[Row] = []
    inside = False
    for n, line in enumerate(lines, 1):
        if line.startswith("## "):
            inside = line.strip() == "## What runs"
            continue
        if not inside or not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3:
            continue
        names = _TOKEN_RE.findall(cells[0])
        if not names:
            continue          # the header and its separator
        rows.append(Row(n, names, cells[1], cells[2]))
    if not rows:
        die(f"{readme}: no \"What runs\" table (a ## What runs section with rows)")
    return rows


def check(units_dir: str = "deploy", readme: str = "README.md") -> int:
    units = load_units(units_dir)
    rows = read_rows(readme)
    covered = {name: row for row in rows for name in row.names}
    fails = 0

    def bad(where: str, msg: str) -> None:
        nonlocal fails
        print(f"  FAIL {where}: {msg}")
        fails += 1

    for unit in units.values():
        row = covered.get(unit.name)
        if row is None:
            if not unit.oneshot:
                bad(unit.path, f"no {readme} row names the unit `{unit.name}`")
            continue
        where = f"{readme}:{row.line}"
        if unit.image and not re.search(re.escape(unit.image) + r"(?![0-9A-Za-z.])",
                                        row.image):
            bad(where, f"the row for `{unit.name}` does not carry its Image= "
                       f"({unit.image})")
        for port in unit.ports:
            if not re.search(r"(?<![0-9])" + port + r"(?![0-9])", row.published):
                bad(where, f"the row for `{unit.name}` does not show published "
                           f"port {port}")

    for name in covered:
        if name not in units and name not in HOST_UNITS:
            bad(f"{readme}:{covered[name].line}",
                f"the row names `{name}`, which is not a container unit")

    if fails:
        print(f"{fails} README \"What runs\" row(s) disagree with the units")
        return fails
    named = sum(1 for name in covered if name in units)
    print(f"what runs: {named} unit(s) in {len(rows)} row(s) agree with the units")
    return 0


def main(argv: List[str]) -> int:
    # argv is what __main__'s dispatch passes after the command word: `check`
    # alone reads README.md and deploy/ from the top; anything after it is the
    # doc path, then --units DIR.
    if not argv or argv[0] != "check":
        print("usage: python3 -m stackctl units check [README.md] [--units DIR]",
              file=sys.stderr)
        return 2
    rest = list(argv[1:])
    units_dir = "deploy"
    if "--units" in rest:
        i = rest.index("--units")
        if i + 1 >= len(rest):
            die("--units needs a directory")
        units_dir = rest[i + 1]
        del rest[i:i + 2]
    readme = rest[0] if rest else "README.md"
    return 0 if check(units_dir, readme) == 0 else 1
