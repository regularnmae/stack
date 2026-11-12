# The unit templates in deploy/, parsed into the facts the generated docs repeat.
#
# This is the reading half of what used to be `stackctl units check`: README's
# "What runs" table and AGENTS.md's interface tables are rendered from these
# facts by `stackctl docs`, so a unit bump is one render away instead of a
# hand edit the old check had to police.
from __future__ import annotations

import glob
import os
import re
from typing import Dict, List

from .ui import die

# Where a unit can live, relative to the units dir (the same three globs
# scripts/healthcheck-lint.sh reads).
_UNIT_GLOBS = ("*.container", "*.container.in", "root/*.container")

# Quadlet keys repeat (Volume, EnvironmentFile, PublishPort) and comments are
# skipped, so a unit is read as key -> values rather than line by line.
_KEY_RE = re.compile(r"^([A-Za-z]+)=(.*)$")


class Unit:
    """The facts a unit template states about itself.

    `ports` holds the host side (what the docs publish) and the in-container
    port (what the app is told to listen on); `network_host` is what makes the
    publish unnecessary -- a host-network unit binds the host's own namespace.
    """

    __slots__ = ("name", "image", "path", "ports", "network_host", "env_files",
                 "health_cmd", "oneshot", "root")

    def __init__(self, name: str, path: str):
        self.name = name
        self.path = path
        self.image = ""
        self.ports: List[tuple] = []      # [(host side, container side)]
        self.network_host = False
        self.env_files: List[str] = []
        self.health_cmd = ""
        self.oneshot = False
        self.root = os.sep + "root" + os.sep in path


def load_units(units_dir: str = "deploy") -> Dict[str, Unit]:
    files: List[str] = []
    for pattern in _UNIT_GLOBS:
        files.extend(sorted(glob.glob(os.path.join(units_dir, pattern))))
    if not files:
        die(f"{units_dir}: no container units matched {', '.join(_UNIT_GLOBS)}")
    units: Dict[str, Unit] = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        values: Dict[str, List[str]] = {}
        for line in text.splitlines():
            m = _KEY_RE.match(line)
            if m:
                values.setdefault(m.group(1), []).append(m.group(2).strip())
        container = (values.get("ContainerName") or [""])[0]
        if not container:
            continue        # a .container.in template that only renders Exec=
        unit = units.setdefault(container, Unit(container, path))
        image = values.get("Image")
        if image:
            unit.image = image[0]
        for spec in values.get("PublishPort", []):
            fields = spec.split(":")
            if len(fields) >= 3:
                unit.ports.append((f"{fields[0]}:{fields[1]}", fields[2]))
            elif len(fields) == 2:
                unit.ports.append((fields[0], fields[1]))
        if "host" in values.get("Network", []):
            unit.network_host = True
        for spec in values.get("EnvironmentFile", []):
            unit.env_files.append(os.path.basename(spec))
        if values.get("HealthCmd"):
            unit.health_cmd = values["HealthCmd"][0]
        if "oneshot" in values.get("Type", []):
            unit.oneshot = True
    return units
