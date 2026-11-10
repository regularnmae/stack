# `python3 -m stackctl <command>` -- the entry point the bash wrappers in
# scripts/ exec. The wrappers own the CLI contract (flags, usage header,
# stack.conf, resolve_data_dir) and pass their facts in the environment; this
# dispatch only routes to the reconciler and translates ui.Fatal into
# lib.sh's die() output shape ("ERROR: msg" on stderr, exit 1).
import sys
from typing import Dict


def main(argv) -> int:
    from . import manifest, npm, units
    from .ui import Fatal

    commands: Dict[str, object] = {
        "npm-hosts": npm.main,
        "manifest": manifest.main,
        "units": units.main,
    }
    cmd = argv[1] if len(argv) > 1 else ""
    handler = commands.get(cmd)
    if handler is None:
        print(f"usage: python3 -m stackctl {{{'|'.join(commands)}}}", file=sys.stderr)
        print("run the bash wrapper (scripts/npm-hosts.sh) "
              "-- it owns stack.conf and the declarations", file=sys.stderr)
        return 2
    try:
        return handler(argv[2:]) or 0
    except Fatal as e:
        print(f"ERROR: {e.msg}", file=sys.stderr, flush=True)
        return 1
    except BrokenPipeError:
        return 0
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv))
