# Output conventions shared with scripts/lib.sh, so a wrapper's bash half and
# its Python half are indistinguishable on a terminal (and in a golden diff of
# the two implementations' --dry-run output).
import sys


def log(msg: str, err: bool = False) -> None:
    """lib.sh's log(): "==> msg" on stdout (or stderr, where the bash callers
    redirected it -- npm-hosts' certificate lines did)."""
    print(f"==> {msg}", file=sys.stderr if err else sys.stdout, flush=True)


def warn(msg: str) -> None:
    """lib.sh's warn(): "WARNING: msg" on stderr."""
    print(f"WARNING: {msg}", file=sys.stderr, flush=True)


class Fatal(Exception):
    """A die() that unwinds to main() instead of exiting mid-reconcile."""

    def __init__(self, msg: str):
        super().__init__(msg)
        self.msg = msg


def die(msg: str):
    """Raise a Fatal carrying lib.sh's die() message ("ERROR: " is added by main)."""
    raise Fatal(msg)
