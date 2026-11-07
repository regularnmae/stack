# KEY=VALUE env/secrets file reader -- the exact semantics of lib.sh's
# env_value(), because both implementations read the same files
# ($DATA_DIR/config/<app>/*.env) and a disagreement would be invisible:
#   * first match wins (env_value pipes through `head -n1`);
#   * the value is everything after the FIRST "=";
#   * every CR is stripped (`tr -d '\r'`), so a CRLF file still parses;
#   * a missing file or key yields "" -- never an error. Callers decide
#     whether empty is fatal (npm/kuma print their "fill in the file" hint).
from __future__ import annotations

import os


def env_value(path: str, key: str) -> str:
    """The value of KEY in a KEY=VALUE file, "" when file or key is absent."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(key + "="):
                    return line[len(key) + 1:].rstrip("\n").replace("\r", "")
    except OSError:
        return ""
    return ""


def env_or_file(key: str, path: str, default: str = "") -> str:
    """The bash `${KEY:-$(env_value file KEY)}` then `${KEY:-default}` chain:
    a non-empty process environment wins, then the file, then the default."""
    return os.environ.get(key) or env_value(path, key) or default
