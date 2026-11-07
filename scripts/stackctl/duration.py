# Go duration strings ("1m30s", "500ms", "2h30m0.5s") -> milliseconds.
#
# This is a PORT of scripts/lib.sh's dur_ms, and it must not drift from it:
# lib.sh's copy is what wait_healthy and healthcheck-lint read, this one is
# what a Python collector would read, and tests/duration-fixtures.txt is the
# shared contract both are tested against (tests/test_stackctl.py on the
# Python side, tests/test-lib.sh on the bash side). The two implementations
# exist because lib.sh cannot call Python (bootstrap.sh must stay standalone)
# and Python cannot call lib.sh without a shell out per value.
#
# The details that are load-bearing (all learned the hard way in lib.sh):
#   * "ms" precedes "m" in the alternation, or "500ms" reads as 500 minutes;
#   * the integer part is parsed as decimal, never octal (bash needed 10#;
#     Python's int() is decimal by default -- the trap does not translate, but
#     "08m" is a fixture because it once broke the bash side);
#   * a fraction is padded/truncated to exactly three digits -- it is a
#     thousandths addend, not a decimal number: "2.5h" is 2h + 500*3600ms,
#     "1m30.5s" is 1m + 30s + 500ms;
#   * unparsable input (or none) is 0, matching lib.sh -- callers that must
#     tell "absent" from "zero" check the raw string first.
from __future__ import annotations

import re

# Same shape as the bash regex: optional non-digit lead, integer part,
# optional fraction, the unit (ms before m), and the unconsumed tail.
_COMPONENT = re.compile(r"^[^0-9]*([0-9]+)(?:\.([0-9]+))?(ms|h|m|s)(.*)$", re.DOTALL)

# Whole-unit and fraction-unit multipliers, in milliseconds. The fraction is
# a 3-digit thousandths-of-a-unit addend, so its multiplier is the unit's
# millisecond value divided by 1000 -- exactly bash's `+ 10#$frac` term. An
# "ms" fraction contributes nothing (bash drops it; sub-millisecond is below
# the floor).
_UNIT_MS = {"h": 3_600_000, "m": 60_000, "s": 1_000, "ms": 1}
_FRAC_MS = {"h": 3_600, "m": 60, "s": 1, "ms": 0}


def dur_ms(value: str) -> int:
    """Parse a Go duration string into whole milliseconds; 0 when unparsable."""
    total = 0
    rest = value or ""
    while rest:
        match = _COMPONENT.match(rest)
        if not match:
            break
        num, frac, unit, rest = match.groups()
        frac = (frac or "")[:3].ljust(3, "0")[:3]
        total += int(num) * _UNIT_MS[unit] + int(frac) * _FRAC_MS[unit]
    return total


def dur_s(value: str) -> int:
    """Whole seconds, rounded UP -- lib.sh's dur_s, wait_healthy's floor where
    waiting longer than the unit's own numbers is the safe direction."""
    return (dur_ms(value) + 999) // 1000
