#!/usr/bin/env python3
# Offline tests for deploy/root/ipguard.py, the stack-bouncer address classifier.
#
# Run: python3 tests/test-ipguard.py          (CI runs this verbatim)
#
# This is the guard that decides whether a CrowdSec ban may be enforced, so it
# is tested in both directions: every private boundary must SKIP, and the
# public space immediately outside it must BAN. A skip that is too wide only
# loses enforcement; a ban that is too wide can lock the operator out -- so the
# table names the failures the old shell glob had (fe80::/10 beyond fe80::,
# ::ffff:10.0.0.1) and the range ipaddress itself gets wrong (fec0::/10, which
# Python 3.12 still calls global) rather than just the happy path.
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "deploy", "root", "ipguard.py")


class IpguardTest(unittest.TestCase):
    def run_guard(self, records, wan="", own=""):
        """One record per line: 'value<TAB>duration' (duration may be omitted)."""
        env = dict(os.environ, STACK_WAN_IP=wan, OWN_IPS=own)
        stdin = "".join(f"{record}\n" for record in records)
        return subprocess.run(
            [sys.executable, GUARD],
            input=stdin,
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def classify(self, value, wan="", own=""):
        proc = self.run_guard([f"{value}\t1h"], wan=wan, own=own)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.splitlines()
        self.assertEqual(len(lines), 1, f"{value!r} produced {lines!r}")
        fields = lines[0].split("\t")
        self.assertEqual(len(fields), 4, fields)
        return fields

    def assert_skip(self, value, reason, wan="", own=""):
        kind, _, seen, got = self.classify(value, wan=wan, own=own)
        self.assertEqual((kind, got), ("SKIP", reason), f"{value!r} -> {seen!r}")

    def assert_ban(self, value, family, canonical=None, wan="", own=""):
        kind, got_family, seen, _ = self.classify(value, wan=wan, own=own)
        self.assertEqual(kind, "BAN", f"{value!r} -> {seen!r}")
        self.assertEqual(got_family, family, value)
        self.assertEqual(seen, canonical or value, value)

    # --- IPv4 private space and its exact boundaries -------------------------
    def test_ipv4_private(self):
        for value, reason in (
            ("127.0.0.1", "loopback"), ("127.255.255.255", "loopback"),
            ("10.0.0.1", "private"), ("10.89.0.5", "private"),
            ("192.168.0.1", "private"), ("192.168.1.112", "private"),
            ("169.254.1.1", "link-local"), ("0.0.0.0", "unspecified"),
        ):
            self.assert_skip(value, reason)

    def test_172_16_12_boundaries(self):
        for value in ("172.16.0.1", "172.19.255.255", "172.20.0.1",
                      "172.29.255.255", "172.30.0.1", "172.31.255.255"):
            self.assert_skip(value, "private")
        for value in ("172.15.255.255", "172.2.0.1", "172.200.0.1", "172.32.0.1"):
            self.assert_ban(value, "v4")

    def test_cgnat_100_64_10_boundaries(self):
        # The regression that named the old table: 100.128/16 and 100.129/16 are
        # public and must be enforced against.
        for value in ("100.64.0.1", "100.69.255.255", "100.70.0.1",
                      "100.99.255.255", "100.100.0.1", "100.119.255.255",
                      "100.120.0.1", "100.127.255.255"):
            self.assert_skip(value, "non-global")
        for value in ("100.63.255.255", "100.128.0.1", "100.129.255.255", "100.130.0.1"):
            self.assert_ban(value, "v4")

    def test_ipv4_reserved_space(self):
        # Nothing in reserved/benchmark/documentation space can be a real
        # source; refusing it cannot lose enforcement, and the old glob banned
        # the documentation ranges pointlessly.
        for value in ("255.255.255.255", "198.18.0.1", "192.0.2.5",
                      "198.51.100.9", "203.0.113.8"):
            kind, _, _, _ = self.classify(value)
            self.assertEqual(kind, "SKIP", value)
        self.assert_skip("224.0.0.1", "multicast")

    # --- IPv6 ----------------------------------------------------------------
    def test_ipv6_private(self):
        self.assert_skip("::1", "loopback")
        for value in ("fe80::1", "fe90::1", "febf::1"):
            self.assert_skip(value, "link-local")
        for value in ("fc00::1", "fd12:3456:789a::1"):
            self.assert_skip(value, "private")
        self.assert_skip("2001:db8::1", "private")
        # Deprecated site-local space (RFC 3879) is not routable, but Python
        # 3.12 reports it as global, so the guard carries the rule itself. Both
        # ends of the /10: the boundary, and the last address in the block.
        for value in ("fec0::1", "fec0:ffff:ffff:ffff::1", "feff::1"):
            self.assert_skip(value, "site-local")

    def test_ipv6_public(self):
        self.assert_ban("2606:4700::1111", "v6")
        self.assert_ban("2001:4860:4860::8888", "v6")

    def test_ipv4_mapped(self):
        # The old table had no IPv4 case for these: ::ffff:10.0.0.1 walked past
        # every private rule, and ::ffff:8.8.8.8 was added to the v6 set where
        # it can never match an IPv4 packet.
        self.assert_skip("::ffff:10.0.0.1", "private")
        self.assert_skip("::ffff:127.0.0.1", "loopback")
        self.assert_ban("::ffff:8.8.8.8", "v4", canonical="8.8.8.8")

    def test_zoned_link_local(self):
        self.assert_skip("fe80::1%eth0", "link-local")

    # --- the two declared exceptions -----------------------------------------
    def test_declared_wan_and_own_addresses(self):
        self.assert_skip("1.0.0.1", "own", own="192.168.1.112 1.0.0.1")
        self.assert_skip("192.168.1.112", "own", own="192.168.1.112")
        # A different representation of an address the host holds is still the
        # host's address; the string comparison this replaced would have banned
        # ::ffff:1.0.0.1 and the uncompressed v6 form of it.
        self.assert_skip("::ffff:1.0.0.1", "own", own="1.0.0.1")
        self.assert_skip("1.0.0.1", "wan", wan="1.0.0.1")
        self.assert_skip("198.51.100.9", "wan", wan="198.51.100.9")

    def test_unparsable_wan_is_fatal(self):
        proc = self.run_guard(["1.1.1.1\t1h"], wan="not-an-address")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        self.assertIn("STACK_WAN_IP", proc.stderr)

    # --- values that are refused rather than guessed --------------------------
    def test_ranges_and_garbage_are_skipped(self):
        self.assert_skip("10.0.0.0/8", "range")
        self.assert_skip("2606:4700::/32", "range")
        self.assert_skip("not-an-address", "unparsable")

    def test_blank_lines_are_dropped(self):
        proc = self.run_guard(["", "\t1h", "1.1.1.1\t1h"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "BAN\tv4\t1.1.1.1\t1h\n")

    # --- record framing -------------------------------------------------------
    def test_duration_passes_through(self):
        for duration in ("1h", "3h59m59.7s", "500ms", "08m"):
            proc = self.run_guard([f"1.1.1.1\t{duration}"])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout, f"BAN\tv4\t1.1.1.1\t{duration}\n")

    def test_missing_duration_defaults_to_one_hour(self):
        proc = self.run_guard(["1.1.1.1"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "BAN\tv4\t1.1.1.1\t1h\n")

    def test_batch_preserves_order_and_reasons(self):
        proc = self.run_guard(
            ["1.1.1.1\t2h", "10.0.0.1\t1h", "2606:4700::1111\t30m", "garbage\t1h"]
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.splitlines(), [
            "BAN\tv4\t1.1.1.1\t2h",
            "SKIP\t-\t10.0.0.1\tprivate",
            "BAN\tv6\t2606:4700::1111\t30m",
            "SKIP\t-\tgarbage\tunparsable",
        ])


if __name__ == "__main__":
    unittest.main()
