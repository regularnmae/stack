#!/usr/bin/env python3
# Offline tests for the Python core behind the bash wrapper (scripts/stackctl/).
#
# Run: python3 tests/test_stackctl.py     (stdlib only -- there is no venv)
#
# What is covered, and why each layer exists:
#   * manifest.py -- the declarations, their per-field validation, and the
#     shell emission bash evaluates;
#   * npm.py -- payload construction byte-for-byte (field order included,
#     which is what made the golden diff against the bash original a real
#     check), plus a full reconcile against a fake NPM admin API.
#
# The live behaviour was additionally proven against the running stack before
# this suite was written: the reconciler's --dry-run output matched the bash
# original byte for byte. That cannot run in CI; this file is what keeps those
# semantics from regressing afterwards.
import contextlib
import io
import json
import os
import shlex
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from stackctl import envfile, manifest, npm, units  # noqa: E402
from stackctl.ui import Fatal  # noqa: E402


def shlex_quote(s):
    import shlex
    return shlex.quote(s)


def die_msg(fn, *args, **kwargs):
    """Run a parser that is expected to die; return its message, or None when
    it did not (which is the test failure)."""
    try:
        fn(*args, **kwargs)
    except Fatal as e:
        return e.msg
    return None


# ---------------------------------------------------------------------------


class TestEnvfile(unittest.TestCase):
    def test_first_match_wins_and_cr_stripped(self):
        path = os.path.join(self.tmp, "api.env")
        with open(path, "w", encoding="utf-8") as f:
            f.write("FIRST=one\r\nSECOND=two\nFIRST=three\r\nNOEQ\n=x\n")
        self.assertEqual(envfile.env_value(path, "FIRST"), "one")  # head -n1
        self.assertEqual(envfile.env_value(path, "SECOND"), "two")
        self.assertEqual(envfile.env_value(path, "ABSENT"), "")
        self.assertEqual(envfile.env_value(path + ".missing", "FIRST"), "")

    def test_env_or_file_order(self):
        path = os.path.join(self.tmp, "api.env")
        with open(path, "w", encoding="utf-8") as f:
            f.write("KEY=from-file\n")
        self.assertEqual(envfile.env_or_file("KEY", path), "from-file")
        self.assertEqual(envfile.env_or_file("KEY", path, "default"), "from-file")
        self.assertEqual(envfile.env_or_file("ABSENT", path, "default"), "default")

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="stackctl-test-")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)


# ---------------------------------------------------------------------------


class TestDeclarations(unittest.TestCase):
    """The declaration types themselves. Reading them out of TOML is
    TestManifest's job; these pin the small behaviours the reconciler relies on."""

    def test_npm_host_flags(self):
        h = manifest.NpmHost("status.example.net", "http", "127.0.0.1", 8107,
                             "ws,block")
        self.assertEqual((h.domain, h.scheme, h.host, h.port, h.flags),
                         ("status.example.net", "http", "127.0.0.1", 8107, "ws,block"))
        self.assertTrue(h.has_flag("ws"))
        self.assertFalse(h.has_flag("w"))
        self.assertFalse(h.has_flag("bloc"))
        self.assertEqual(h.flags_without("ws"), "block")

    def test_mcp_host_probe_defaults(self):
        m = manifest.McpHost("/searxng", "searxng-mcp", 8100)
        self.assertEqual((m.prefix, m.container, m.port),
                         ("/searxng", "searxng-mcp", 8100))
        # Empty until manifest.load fills them from the [mcp.*] table.
        self.assertEqual((m.token_var, m.probe_tool, m.probe_args,
                          m.needs_nodes, m.spend_token_var),
                         ("", "", "{}", False, ""))


# ---------------------------------------------------------------------------


class TestNpmPayloads(unittest.TestCase):
    def test_build_payload_bytes(self):
        # Field order and escaping match the bash printf template: the JSON
        # text is the comparison the golden diff of the two implementations
        # made, so pin it here.
        payload = npm.build_payload(
            "d.example.net", "http", "127.0.0.1", 8107, 6, "ws,force-ssl,block",
            "proxy_buffering off;\nlimit_conn stack_conn 200;", [])
        self.assertEqual(
            json.dumps(payload),
            '{"domain_names": ["d.example.net"], "forward_scheme": "http", '
            '"forward_host": "127.0.0.1", "forward_port": 8107, '
            '"certificate_id": 6, "ssl_forced": true, "http2_support": false, '
            '"block_exploits": true, "caching_enabled": false, '
            '"allow_websocket_upgrade": true, "access_list_id": 0, '
            '"enabled": true, "advanced_config": '
            '"proxy_buffering off;\\nlimit_conn stack_conn 200;", "locations": []}')

    def test_advanced_mcp_string(self):
        # The bash ADVANCED_JSON carried literal \" and \n that JSON-decoded
        # to real quotes and newlines; the Python string must match.
        self.assertIn('proxy_set_header Connection "";', npm.ADVANCED_MCP)
        self.assertIn("\n", npm.ADVANCED_MCP)
        self.assertTrue(npm.ADVANCED_MCP.startswith("proxy_buffering off;"))
        self.assertTrue(npm.ADVANCED_MCP.endswith("chunked_transfer_encoding on;"))

    def test_rate_limits_per_ingress(self):
        clearweb = manifest.NpmHost("d", "http", "127.0.0.1", 1, "block")
        mcp = manifest.NpmHost("m", "http", "127.0.0.1", 1, "mcp,http2")
        onion = manifest.NpmHost("x.onion", "http", "127.0.0.1", 1, "mcp")
        self.assertEqual(npm.rate_limits(clearweb),
                         "limit_req zone=stack_ip burst=60 nodelay;\nlimit_conn stack_conn 40;")
        self.assertEqual(npm.rate_limits(mcp), "limit_conn stack_conn 200;")
        # The onion branch wins even when the mcp flag is set -- dropping that
        # precedence silently removes the onion side's only brake.
        self.assertEqual(npm.rate_limits(onion), "limit_req zone=stack_onion burst=120 nodelay;")

    def test_flags_without(self):
        h = manifest.NpmHost("d", "http", "127.0.0.1", 1, "mcp,force-ssl,http2")
        self.assertEqual(h.flags_without("force-ssl"), "mcp,http2")

    def test_mcp_locations(self):
        locs = npm.mcp_locations([manifest.McpHost("/x", "c", 8100),
                                  manifest.McpHost("/y", "d", 8101)])
        self.assertEqual(locs, [
            {"path": "/x", "forward_scheme": "http", "forward_host": "127.0.0.1",
             "forward_port": 8100, "forward_path": "/mcp", "access_list_id": 0},
            {"path": "/y", "forward_scheme": "http", "forward_host": "127.0.0.1",
             "forward_port": 8101, "forward_path": "/mcp", "access_list_id": 0},
        ])

    def test_find_host_id(self):
        hosts = [{"id": 5, "domain_names": ["a.net"]},
                 {"id": 6, "domain_names": ["b.net", "c.net"]}]
        self.assertEqual(npm.find_host_id(hosts, "c.net"), 6)
        self.assertIsNone(npm.find_host_id(hosts, "zzz"))


# ---------------------------------------------------------------------------
# A fake nginx-proxy-manager admin API: enough of the real one's shapes (token
# mint, bearer-gated /api/nginx/*, plain-text DELETE answers) to run the whole
# reconcile offline, including prune.
class FakeNpmHandler(BaseHTTPRequestHandler):
    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if self.headers.get("Authorization") == "Bearer testtoken":
            return True
        self._json({"error": "Permission Denied"}, 403)
        return False

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length)) if length else None

    def do_GET(self):
        self.server.requests.append(("GET", self.path, None))
        if self.path == "/":
            self._json({"ok": True})
        elif not self._authorized():
            pass
        elif self.path == "/api/nginx/proxy-hosts":
            self._json(self.server.hosts)
        elif self.path == "/api/nginx/certificates":
            self._json(self.server.certs)

    def do_POST(self):
        body = self._read_json()
        self.server.requests.append(("POST", self.path, body))
        if self.path == "/api/tokens":
            # the login is reachable WITHOUT a bearer -- that is the whole
            # point of it (a real NPM answers it unauthenticated too)
            self.server.logins.append((body.get("identity"), body.get("secret")))
            self._json({"token": "testtoken"})
            return
        if not self._authorized():
            return
        if self.path == "/api/nginx/proxy-hosts":
            body["id"] = self.server.next_id()
            self.server.hosts.append(body)
            self._json(body)
        elif self.path == "/api/nginx/certificates":
            body["id"] = self.server.next_id()
            self.server.certs.append(body)
            self._json(body)

    def do_PUT(self):
        body = self._read_json()
        self.server.requests.append(("PUT", self.path, body))
        if not self._authorized():
            return
        hid = int(self.path.rsplit("/", 1)[1])
        for i, h in enumerate(self.server.hosts):
            if h["id"] == hid:
                body["id"] = hid
                self.server.hosts[i] = body
                self._json(body)
                return
        self._json({"error": "not found"}, 404)

    def do_DELETE(self):
        self.server.requests.append(("DELETE", self.path, None))
        if not self._authorized():
            return
        # NPM's DELETE answers plain text; keep that shape so the non-JSON
        # branch of raw_call is what the reconcile actually exercises.
        if self.path.startswith("/api/nginx/proxy-hosts/"):
            hid = int(self.path.rsplit("/", 1)[1])
            self.server.hosts = [h for h in self.server.hosts if h["id"] != hid]
        elif self.path.startswith("/api/nginx/certificates/"):
            cid = int(self.path.rsplit("/", 1)[1])
            self.server.certs = [c for c in self.server.certs if c["id"] != cid]
        body = b"OK"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class FakeNpm(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), FakeNpmHandler)
        self.hosts = []
        self.certs = []
        self.requests = []
        self.logins = []
        self._next = 1

    def next_id(self):
        self._next += 1
        return self._next - 1


class TestNpmReconcile(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="stackctl-npm-")
        self.config = os.path.join(self.tmp, "config")
        os.makedirs(os.path.join(self.config, "npm"))
        with open(os.path.join(self.config, "npm", "api.env"), "w") as f:
            f.write("NPM_EMAIL=admin@example.net\nNPM_PASSWORD=secret\n")
        self.server = FakeNpm()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.api = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_manifest(self, hosts_lines, mcp=()):
        """The reconciler reads the service manifest (deploy/services.toml's
        schema). The tests author a host as "domain|host:port|flags" shorthand
        and expand it into the TOML tables the manifest loader expects."""
        blocks = []
        for i, entry in enumerate(hosts_lines):
            domain, forward, flags = entry.split("|", 2)
            flag_list = json.dumps([f for f in flags.split(",") if f])
            fwd_host, fwd_port = forward.rsplit(":", 1)
            forward_keys = (f'forward_host = "{fwd_host}"\n'
                            f'forward_port = {fwd_port}\n')
            if domain == "*.onion":
                blocks.append(f'[npm.h{i}]\ndomain = "*.onion"\n'
                              f'{forward_keys}flags = {flag_list}\n')
            else:
                blocks.append(f'[host.h{i}]\ndomain = "{domain}"\n')
                blocks.append(f'[npm.h{i}]\nhost = "h{i}"\n'
                              f'{forward_keys}flags = {flag_list}\n')
        for i, entry in enumerate(mcp):
            prefix, container, port = entry[1:].split(":")
            blocks.append(f'[mcp.m{i}]\nprefix = "/{prefix}"\n'
                          f'container = "{container}"\nport = {port}\n')
        path = os.path.join(self.tmp, "services.toml")
        with open(path, "w") as f:
            f.write("\n".join(blocks))
        return path

    def facts(self, hosts_lines, mcp=(), dry="0", prune="0", request_cert=None):
        """Put the wrapper's facts in the environment, where the reconciler
        reads them (NPM_REQUEST_CERT included -- it never travelled the old
        declaration stream either)."""
        if request_cert is not None:
            os.environ["NPM_REQUEST_CERT"] = request_cert
            self.addCleanup(os.environ.pop, "NPM_REQUEST_CERT", None)
        env = {
            "MANIFEST": self.write_manifest(hosts_lines, mcp),
            "NPM_API": self.api,
            "DATA_DIR": self.tmp,
            "CONFIG_DIR": self.config,
            "DRY_RUN": dry,
            "PRUNE": prune,
        }
        for key, value in env.items():
            os.environ[key] = value
            self.addCleanup(os.environ.pop, key, None)

    def reconcile(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = npm.reconcile()
        return rc, out.getvalue(), err.getvalue()

    def test_dry_run_touches_nothing(self):
        self.facts(["d.example.net|127.0.0.1:8107|ws,block"], dry="1")
        rc, out, err = self.reconcile()
        self.assertEqual(rc, 0)
        self.assertIn("[dry-run] would create a proxy host for d.example.net", out)
        payload = json.loads(out[out.index("{"):out.rindex("}") + 1])
        self.assertEqual(payload["domain_names"], ["d.example.net"])
        writes = [r for r in self.server.requests if r[0] in ("POST", "PUT", "DELETE")]
        # one login POST only -- no host write, no certificate request
        self.assertEqual([r[1] for r in writes], ["/api/tokens"])
        self.assertIn("done", out)

    def test_create_then_update_reusing_certificate(self):
        self.server.certs.append({"id": 6, "provider": "letsencrypt",
                                  "domain_names": ["d.example.net"]})
        older = {"id": 2, "provider": "letsencrypt", "domain_names": ["d.example.net"]}
        self.server.certs.insert(0, older)  # newest (id 6) must win
        self.facts(["d.example.net|127.0.0.1:8107|force-ssl,block"])
        rc, out, _ = self.reconcile()
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"created proxy host \d+")
        created = [r for r in self.server.requests if r[0] == "POST" and r[1] == "/api/nginx/proxy-hosts"]
        self.assertEqual(created[0][2]["certificate_id"], 6)
        self.assertTrue(created[0][2]["ssl_forced"])

        self.server.requests.clear()
        rc, out, _ = self.reconcile()
        self.assertRegex(out, r"updated proxy host")
        updated = [r for r in self.server.requests if r[0] == "PUT"]
        self.assertEqual(updated[0][2]["certificate_id"], 6)
        cert_posts = [r for r in self.server.requests
                      if r[0] == "POST" and r[1] == "/api/nginx/certificates"]
        self.assertEqual(cert_posts, [])  # reused, never re-requested

    def test_no_certificate_strips_force_ssl(self):
        self.facts(["d.example.net|127.0.0.1:8107|force-ssl,block"],
                       request_cert="0")
        rc, out, _ = self.reconcile()
        self.assertEqual(rc, 0)
        created = [r for r in self.server.requests if r[0] == "POST" and r[1] == "/api/nginx/proxy-hosts"]
        self.assertEqual(created[0][2]["certificate_id"], 0)
        self.assertFalse(created[0][2]["ssl_forced"])

    def test_mcp_host_locations_and_limits(self):
        self.facts(["m.example.net|127.0.0.1:8100|mcp,force-ssl,http2"],
                       mcp=["/searxng:searxng-mcp:8100", "/bitcoin:bitcoin-node-mcp:8101"],
                       request_cert="0")
        rc, out, _ = self.reconcile()
        self.assertEqual(rc, 0)
        body = [r for r in self.server.requests if r[0] == "POST" and r[1] == "/api/nginx/proxy-hosts"][0][2]
        self.assertEqual([l["path"] for l in body["locations"]], ["/searxng", "/bitcoin"])
        self.assertEqual([l["forward_port"] for l in body["locations"]], [8100, 8101])
        self.assertIn("proxy_buffering off;", body["advanced_config"])
        self.assertIn("limit_conn stack_conn 200;", body["advanced_config"])
        self.assertIn("MCP endpoints", out)
        self.assertIn("searxng-mcp/token.env", out)

    def test_onion_host(self):
        self.facts(["*.onion|127.0.0.1:8100|mcp"],
                       mcp=["/searxng:searxng-mcp:8100"], request_cert="1")
        rc, out, _ = self.reconcile()
        self.assertEqual(rc, 0)
        body = [r for r in self.server.requests if r[0] == "POST" and r[1] == "/api/nginx/proxy-hosts"][0][2]
        self.assertEqual(body["certificate_id"], 0)
        self.assertIn("limit_req zone=stack_onion burst=120 nodelay;", body["advanced_config"])
        self.assertNotIn("stack_ip", body["advanced_config"])
        certs = [r for r in self.server.requests if "certificates" in r[1]]
        self.assertEqual(certs, [r for r in certs if r[0] == "GET"])  # never requested
        self.assertIn("MCP endpoints", out)
        self.assertIn("http://<onion>/searxng", out)  # onion has no https URL

    def test_prune(self):
        self.server.hosts.append({"id": 99, "domain_names": ["stale.example.net"],
                                  "certificate_id": 7})
        self.server.hosts.append({"id": 5, "domain_names": ["keep.example.net"],
                                  "certificate_id": 0})
        self.server.certs.append({"id": 7, "provider": "letsencrypt",
                                  "domain_names": ["stale.example.net"]})
        self.facts(["keep.example.net|127.0.0.1:8107|block"], prune="1")
        rc, out, _ = self.reconcile()
        self.assertEqual(rc, 0)
        self.assertIn("deleted proxy host 99 (not declared in deploy/services.toml)", out)
        self.assertIn("deleted certificate 7 (unused, not declared in deploy/services.toml)", out)
        kept = [r for r in self.server.requests if r[0] == "DELETE"]
        self.assertEqual([r[1] for r in kept],
                         ["/api/nginx/proxy-hosts/99", "/api/nginx/certificates/7"])

    def test_missing_credentials_self_skip(self):
        os.remove(os.path.join(self.config, "npm", "api.env"))
        self.facts(["d|127.0.0.1:1|"])
        rc, out, _ = self.reconcile()
        self.assertEqual(rc, 0)
        self.assertIn("no nginx-proxy-manager API credentials", out)
        self.assertEqual(self.server.requests, [])


# ---------------------------------------------------------------------------
# deploy/services.toml: the loader, the shell emission and the CI gate. The
# real manifest is exercised (not just fixtures) because it IS the declaration
# of this host's public surface -- if it stops loading, the reconciler does.
MANIFEST = os.path.join(ROOT, "deploy", "services.toml")
AGENTS = os.path.join(ROOT, "AGENTS.md")


class TestManifest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="stackctl-manifest-")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def test_real_manifest(self):
        from stackctl import manifest
        m = manifest.load(MANIFEST)
        self.assertEqual(len(m.hosts), 8)
        self.assertEqual(len(m.mcp), 10)
        self.assertEqual(len(m.npm), 9)
        self.assertEqual(len(m.onion), 5)
        self.assertEqual(m.hosts["frontend"].domain, "boltmesh.net")
        self.assertEqual(m.hosts["frontend"].env, "BOLTMESH_FRONTEND_HOST")
        self.assertEqual(m.mcp[0].prefix, "/searxng")
        self.assertEqual(m.mcp[0].port, 8100)
        self.assertEqual(m.mcp[0].token_var, "SEARXNG_MCP_TOKEN")
        self.assertEqual(m.mcp[0].probe_tool, "get_time")
        wallet = [x for x in m.mcp if x.container == "monero-wallet-mcp"][0]
        self.assertEqual(wallet.spend_token_var, "MONERO_MCP_SPEND_TOKEN")
        self.assertEqual(m.onion[2].name, "btc-explorer")   # HiddenServiceDir name
        self.assertEqual((m.onion[2].path, m.onion[2].codes), ("/", ["200", "401"]))
        self.assertEqual(m.kuma_page.slug, "stack")
        # The clearweb surface monitor.sh probes: every [npm.*] name but the
        # onion wildcard, which has no name to resolve.
        self.assertEqual(m.shell().count("NPM_DOMAINS=("), 1)
        self.assertNotIn("*.onion", m.shell().split("NPM_DOMAINS=(")[1].split(")", 1)[0])

    def test_env_override_keeps_the_stack_conf_contract(self):
        from stackctl import manifest
        os.environ["BOLTMESH_FRONTEND_HOST"] = "staging.example.net"
        self.addCleanup(os.environ.pop, "BOLTMESH_FRONTEND_HOST", None)
        m = manifest.load(MANIFEST)
        self.assertEqual(m.hosts["frontend"].domain, "staging.example.net")
        # ... and the composed entries follow the resolved domain.
        self.assertTrue(any(n.domain == "staging.example.net" for n in m.npm))
        self.assertTrue(any(o.mirrors == "staging.example.net" for o in m.onion))

    def test_shell_emission_is_eval_safe_in_bash(self):
        # The contract load_manifest relies on: bash evaluates the emission and
        # gets one array per column, index-aligned, plus the *_HOST scalars.
        script = (
            'set -euo pipefail; eval "$(PYTHONPATH=' + shlex_quote(ROOT + "/scripts")
            + ' python3 -m stackctl manifest shell ' + shlex_quote(MANIFEST) + ')"; '
            'printf "%s\\n" "${#MCP_PREFIXES[@]}" "$MCP_HOST" "${#ONION_NAMES[@]}" '
            '"${#KUMA_ADD_HOST_HOSTS[@]}" "$KUMA_STATUS_SLUG" "${MCP_PREFIXES[0]}" '
            '"${MCP_CONTAINERS[0]}" "${MCP_PORTS[0]}" '
            '"${ONION_NAMES[2]}" "${ONION_TARGETS[2]}" "${ONION_MIRRORS[2]}" '
            '"${ONION_PATHS[2]}" "${ONION_CODES[2]}" '
            '"$BOLTMESH_FRONTEND_HOST" "${#PROBE_TOKEN_VARS[@]}" '
            '"${PROBE_TOKEN_VARS[0]}" "${PROBE_ARGS[0]}" '
            '"${PROBE_NEEDS_NODES[1]}" "${PROBE_SPEND_VARS[3]}"'
        )
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                             check=True).stdout.splitlines()
        self.assertEqual(out[0], "10")
        self.assertEqual(out[1], "mcp.boltmesh.net")
        self.assertEqual(out[2], "5")
        self.assertEqual(out[3], "6")       # mcp + status opt out of --add-host
        self.assertEqual(out[4], "stack")
        self.assertEqual(out[5], "/searxng")
        self.assertEqual(out[6], "searxng-mcp")
        self.assertEqual(out[7], "8100")
        self.assertEqual(out[8], "btc-explorer")
        self.assertEqual(out[9], "10.89.0.243:3002")
        self.assertEqual(out[10], "btc.boltmesh.net")
        self.assertEqual(out[11], "/")
        self.assertEqual(out[12], "200,401")
        self.assertEqual(out[13], "boltmesh.net")
        self.assertEqual(out[14], "10")
        self.assertEqual(out[15], "SEARXNG_MCP_TOKEN")
        self.assertEqual(out[16], '{"tz":"UTC"}')
        self.assertEqual(out[17], "1")
        self.assertEqual(out[18], "MONERO_MCP_SPEND_TOKEN")

    def test_real_manifest_agrees_with_agents_md(self):
        from stackctl import manifest
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(manifest.check(MANIFEST, AGENTS), 0)

    def test_agents_drift_is_caught(self):
        from stackctl import manifest
        text = open(AGENTS, encoding="utf-8").read()
        # Remove the row of a declared server: the count gate must fire.
        line = next(l for l in text.splitlines() if "`searxng-mcp`" in l and "127.0.0.1:8100" in l)
        path = self.write("AGENTS.md", text.replace(line + "\n", ""))
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(Fatal) as ctx:
                manifest.check(MANIFEST, path)
        self.assertIn("row", ctx.exception.msg)

    def test_validation_errors(self):
        from stackctl import manifest
        bad_port = self.write("bad-port.toml", """
[host.a]
domain = "a.example"
[mcp.one]
prefix = "/one"
container = "one-mcp"
port = 8100
[mcp.two]
prefix = "/two"
container = "two-mcp"
port = 8100
""")
        self.assertIn("both publish loopback port 8100",
                      die_msg(manifest.load, bad_port))

        unknown_host = self.write("unknown-host.toml", """
[npm.x]
host = "nope"
forward_host = "127.0.0.1"
forward_port = 8100
""")
        self.assertIn("no [host.nope]", die_msg(manifest.load, unknown_host))

        bad_flag = self.write("bad-flag.toml", """
[host.a]
domain = "a.example"
[mcp.one]
prefix = "/one"
container = "one-mcp"
port = 8100
[npm.x]
host = "a"
forward_host = "127.0.0.1"
forward_port = 8105
flags = ["mcp"]
""")
        self.assertIn("no [mcp.*] entry publishes", die_msg(manifest.load, bad_flag))

        bad_toml = self.write("broken.toml", "[host.a\ndomain = \"x\"\n")
        self.assertIn("does not parse", die_msg(manifest.load, bad_toml))

        missing = os.path.join(self.tmp, "missing.toml")
        self.assertIn("missing", die_msg(manifest.load, missing))

    def test_field_errors_name_the_table(self):
        from stackctl import manifest

        def bad(name, body, needle):
            path = self.write(name, body)
            msg = die_msg(manifest.load, path)
            self.assertIsNotNone(msg, f"{name} was accepted")
            self.assertIn(needle, msg)

        base_mcp = """
[host.a]
domain = "a.example"
[mcp.one]
prefix = "/one"
container = "one-mcp"
port = 8100
"""
        bad("bad-prefix.toml", base_mcp.replace('"/one"', '"one"'),
            "is not a path")
        bad("bad-mcp-port.toml", base_mcp.replace("port = 8100", "port = 0"),
            "out of range")

        bad("no-forward.toml", """
[host.a]
domain = "a.example"
[npm.x]
host = "a"
""", "needs forward_host")
        bad("bad-forward-scheme.toml", """
[host.a]
domain = "a.example"
[npm.x]
host = "a"
forward_host = "127.0.0.1"
forward_port = 8100
scheme = "ftp"
""", "neither http nor https")

        bad("bad-onion-target.toml", """
[host.a]
domain = "a.example"
[onion.x]
target = "noport"
mirrors = "a"
""", "is not host:port")

    def test_host_table_is_checked_like_the_mcp_one(self):
        # A quoted boolean is a string, not a bool: `bool("false")` is True, so
        # an unchecked read turned status/mcp back into --add-host hosts.
        from stackctl import manifest

        def bad(name, host_body, needle):
            path = self.write(name, host_body)
            msg = die_msg(manifest.load, path)
            self.assertIsNotNone(msg, f"{name} was accepted")
            self.assertIn(needle, msg)

        bad("quoted-bool.toml", """
[host.a]
domain = "a.example"
kuma_add_host = "false"
""", "kuma_add_host must be true or false")

        # The env name is emitted as `NAME=domain` and then eval'ed: a name the
        # shell cannot parse must fail here, naming the table, not in bash.
        bad("bad-env.toml", """
[host.a]
domain = "a.example"
env = "MCP HOST"
""", "env must be an env-var name")

        bad("reserved-env.toml", """
[host.a]
domain = "a.example"
env = "NPM_DOMAINS"
""", "is a name the emission itself sets")

        bad("dup-env.toml", """
[host.a]
domain = "a.example"
env = "SHARED_HOST"
[host.b]
domain = "b.example"
env = "SHARED_HOST"
""", "both read $SHARED_HOST")

        # The positive side: the opt-out actually removes the host from the
        # --add-host list install.sh renders.
        ok = self.write("kuma-optout.toml", """
[host.a]
domain = "a.example"
[host.b]
domain = "b.example"
kuma_add_host = false
[npm.a]
host = "a"
forward_host = "127.0.0.1"
forward_port = 8100
""")
        out = manifest.load(ok).shell()
        self.assertIn("KUMA_ADD_HOST_HOSTS=(a.example)", out)

    def test_probe_fields_are_required_and_valid(self):
        from stackctl import manifest
        base = """
[host.mcp]
domain = "mcp.example.net"
env = "MCP_HOST"

[mcp.one]
prefix = "/one"
container = "one-mcp"
port = 8100
%s

[npm.one]
host = "mcp"
forward_host = "127.0.0.1"
forward_port = 8100
flags = ["mcp"]
"""
        agents = self.write("AGENTS.md", "| `one-mcp` | ... | `127.0.0.1:8100` |\n")

        missing = self.write("missing-probe.toml", base % "")
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(Fatal) as ctx:
                manifest.check(missing, agents)
        self.assertIn("token_var", ctx.exception.msg)

        bad_args = self.write("bad-args.toml", base % (
            'token_var = "ONE_MCP_TOKEN"\nprobe_tool = "get_one"\n'
            "probe_args = 'not json'"))
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(Fatal) as ctx:
                manifest.check(bad_args, agents)
        self.assertIn("not JSON", ctx.exception.msg)

    def test_minimal_manifest_check(self):
        from stackctl import manifest
        path = self.write("tiny.toml", """
[host.mcp]
domain = "mcp.example.net"
env = "MCP_HOST"

[mcp.one]
prefix = "/one"
container = "one-mcp"
port = 8100
token_var = "ONE_MCP_TOKEN"
probe_tool = "get_one"
probe_args = '{}'
needs_nodes = false

[npm.one]
host = "mcp"
forward_host = "127.0.0.1"
forward_port = 8100
flags = ["mcp"]
""")
        agents = self.write("AGENTS.md", "| Server | Container | ... | NPM target |\n"
                            "| --- | --- | --- | --- |\n"
                            "| `one-mcp` | `one-mcp` | ... | `127.0.0.1:8100` |\n")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(manifest.check(path, agents), 0)
            m = manifest.load(path)
        out = m.shell()
        self.assertIn("MCP_HOST=mcp.example.net", out)
        self.assertIn("MCP_PREFIXES=(/one)", out)
        self.assertIn("MCP_CONTAINERS=(one-mcp)", out)
        self.assertIn("MCP_PORTS=(8100)", out)
        # The public-surface list monitor.sh probes: one clearweb vhost.
        self.assertIn("NPM_DOMAINS=(mcp.example.net)", out)


class TestUnits(unittest.TestCase):
    """README's "What runs" against the unit files. The three facts checked are
    the ones a Renovate bump can invalidate without touching the README, plus the
    reverse direction (a row left behind by a deleted unit)."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="stackctl-units-")
        self.deploy = os.path.join(self.tmp, "deploy")
        os.makedirs(os.path.join(self.deploy, "root"))
        self.readme = os.path.join(self.tmp, "README.md")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def unit(self, name, image="docker.io/x/y:1", ports=(), oneshot=False, root=False):
        body = ["[Container]", f"ContainerName={name}", f"Image={image}"]
        body += [f"PublishPort={p}" for p in ports]
        if oneshot:
            body.append("Type=oneshot")
        path = os.path.join(self.deploy, "root" if root else "", f"{name}.container")
        with open(path, "w") as f:
            f.write("\n".join(body) + "\n")

    def rows(self, rows):
        text = ["# stack", "", "## What runs", "",
                "| Unit | Image | Published | Data |",
                "| --- | --- | --- | --- |"]
        for names, image, published in rows:
            text.append(f"| {', '.join(f'`{n}`' for n in names)} | {image} "
                        f"| {published} | — |")
        text += ["", "The prose below the table is not a row.", "", "## Next", ""]
        with open(self.readme, "w") as f:
            f.write("\n".join(text) + "\n")

    def run_check(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = units.check(self.deploy, self.readme)
        return rc, out.getvalue()

    def test_real_tree_agrees(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = units.check(os.path.join(ROOT, "deploy"),
                             os.path.join(ROOT, "README.md"))
        self.assertEqual(rc, 0, out.getvalue())

    def test_a_matching_row_passes(self):
        self.unit("bitcoind", ports=["8333:8333"])
        self.rows([(["bitcoind"], "`docker.io/x/y:1`", "`8333`")])
        rc, out = self.run_check()
        self.assertEqual(rc, 0, out)

    def test_bumped_image_is_caught(self):
        # The drift this exists for: Renovate moves Image=, the table keeps the tag.
        self.unit("bitcoind", image="docker.io/lncm/bitcoind:v29.0")
        self.rows([(["bitcoind"], "`docker.io/lncm/bitcoind:v28.0`", "—")])
        rc, out = self.run_check()
        self.assertEqual(rc, 1)
        self.assertIn("does not carry its Image=", out)
        self.assertIn("v29.0", out)

    def test_missing_row_is_caught(self):
        self.unit("bitcoind")
        self.rows([(["monerod"], "`docker.io/x/y:1`", "—")])
        # ... and monerod has no unit, so that row is stale in the other direction.
        self.unit("monerod")
        rc, out = self.run_check()
        self.assertEqual(rc, 1)
        self.assertIn("no ", out)
        self.assertIn("row names the unit `bitcoind`", out)

    def test_oneshot_needs_no_row(self):
        self.unit("stack-backup", oneshot=True)
        self.unit("bitcoind")
        self.rows([(["bitcoind"], "`docker.io/x/y:1`", "`8333`")])
        rc, out = self.run_check()
        self.assertEqual(rc, 0, out)

    def test_new_publish_port_is_caught(self):
        self.unit("fulcrum", ports=["50001:50001", "50003:50003"])
        self.rows([(["fulcrum"], "`docker.io/x/y:1`", "`50001`")])
        rc, out = self.run_check()
        self.assertEqual(rc, 1)
        self.assertIn("port 50003", out)

    def test_a_row_may_name_two_units(self):
        self.unit("netcheck")
        self.unit("netcheck-host")
        self.rows([(["netcheck", "netcheck-host"], "`docker.io/x/y:1`", "—")])
        rc, out = self.run_check()
        self.assertEqual(rc, 0, out)

    def test_a_host_unit_row_is_allowed(self):
        # stack-bouncer is a root oneshot script: a row, no ContainerName.
        self.unit("bitcoind")
        self.rows([(["bitcoind"], "`docker.io/x/y:1`", "—"),
                   (["stack-bouncer"], "— (a host script)", "—")])
        rc, out = self.run_check()
        self.assertEqual(rc, 0, out)

    def test_a_stale_row_is_caught(self):
        self.unit("bitcoind")
        self.rows([(["bitcoind"], "`docker.io/x/y:1`", "—"),
                   (["gone-unit"], "`docker.io/x/z:1`", "—")])
        rc, out = self.run_check()
        self.assertEqual(rc, 1)
        self.assertIn("not a container unit", out)

    def test_no_table_is_an_error(self):
        with open(self.readme, "w") as f:
            f.write("# stack\n\n## Next\n")
        self.unit("bitcoind")
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(Fatal):
                self.run_check()

    def test_main_arg_handling(self):
        self.unit("bitcoind")
        self.rows([(["bitcoind"], "`docker.io/x/y:1`", "`8333`")])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(units.main(["check", self.readme,
                                         "--units", self.deploy]), 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(units.main(["nope"]), 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
