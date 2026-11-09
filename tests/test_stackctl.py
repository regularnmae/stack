#!/usr/bin/env python3
# Offline tests for the Python core behind the bash wrappers (scripts/stackctl/).
#
# Run: .venv/bin/python tests/test_stackctl.py     (CI runs it from the venv;
# the kuma tests only need the code, not the library -- the socket client sits
# behind KumaClient and the tests drive a fake of it)
#
# What is covered, and why each layer exists:
#   * manifest.py -- the declarations, their per-field validation, and the
#     shell emission bash evaluates;
#   * npm.py -- payload construction byte-for-byte (field order included,
#     which is what made the golden diff against the bash original a real
#     check), plus a full reconcile against a fake NPM admin API;
#   * kuma.py -- the declared fields that reach an add/edit, the UI-tuned
#     fields that must not, prune, the status page's "only while empty" rule,
#     and the login failure, all against a fake of the library client (the
#     socket.io protocol itself is uptime-kuma-api2's to test).
#
# The live behaviour was additionally proven against the running stack before
# this suite was written: both reconcilers' --dry-run output matched the bash
# and Node originals byte for byte, and the kuma add/edit/prune write paths
# were exercised against the live server and restored. That cannot run in CI;
# this file is what keeps those semantics from regressing afterwards.
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

from stackctl import envfile, kuma, manifest, npm  # noqa: E402
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
    TestManifest's job; these pin the small behaviours the reconcilers rely on."""

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

    def test_kuma_describe_and_defaults(self):
        p = manifest.KumaMonitor("Fulcrum (Electrum TCP)", "port",
                                 url="tcp://h.internal:50001",
                                 hostname="h.internal", port=50001)
        self.assertEqual(p.describe(), "h.internal:50001 (tcp)")
        self.assertEqual(p.url, "tcp://h.internal:50001")
        self.assertEqual((p.codes, p.interval, p.retry_interval, p.maxretries),
                         ([], 60, 60, 2))
        h = manifest.KumaMonitor("X", "http", url="https://x", codes=["200-299"],
                                 interval=120, retry_interval=120, maxretries=3)
        self.assertEqual(h.describe(), "https://x (codes 200-299)")


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


class TestKumaLogic(unittest.TestCase):
    def test_normalized_codes_array_and_json_string(self):
        self.assertEqual(kuma.normalized_codes({"accepted_statuscodes": ["400-499", "200-299"]}),
                         ["200-299", "400-499"])
        self.assertEqual(kuma.normalized_codes(
            {"accepted_statuscodes_json": '["200-299"]'}), ["200-299"])
        self.assertEqual(kuma.normalized_codes({}), [])
        self.assertEqual(kuma.normalized_codes({"accepted_statuscodes": "junk"}), [])

    def test_differs(self):
        http = manifest.KumaMonitor("n", "http", url="https://x", codes=["200-299"])
        self.assertFalse(kuma.differs({"type": "http", "url": "https://x",
                                       "accepted_statuscodes": ["200-299"]}, http))
        self.assertTrue(kuma.differs({"type": "http", "url": "https://y",
                                      "accepted_statuscodes": ["200-299"]}, http))
        self.assertTrue(kuma.differs({"type": "http", "url": "https://x",
                                      "accepted_statuscodes": ["200-299,300-399"]}, http))
        port = manifest.KumaMonitor("n", "port", url="tcp://h:50001",
                                    hostname="h", port=50001)
        self.assertFalse(kuma.differs({"type": "port", "hostname": "h", "port": 50001}, port))
        self.assertTrue(kuma.differs({"type": "port", "hostname": "h", "port": "50002"}, port))
        self.assertTrue(kuma.differs({"type": "http", "url": "https://x",
                                      "accepted_statuscodes": ["200-299"]}, port))
        # an existing type of None reads as http, like the mjs's `?? "http"`
        self.assertFalse(kuma.differs({"url": "https://x",
                                       "accepted_statuscodes": ["200-299"]}, http))


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
        self.assertIn("deleted proxy host 99 (not in NPM_HOSTS)", out)
        self.assertIn("deleted certificate 7 (unused, not in NPM_HOSTS)", out)
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


# A fake of uptime-kuma-api2's client, i.e. of what KumaClient exposes to a
# reconcile: the monitors the server would list, the status page it stores, and
# a record of every write. The socket.io protocol itself is the library's to
# test; what this file pins down is the decisions -- which fields reach an add
# or an edit, what prune deletes, when a page may be filled.
class FakeKumaApi:
    # KumaClient exposes the library's exception classes as attributes so
    # reconcile can catch them without importing the library at module load; a
    # fake has no library errors to raise.
    errors = ()
    timeout_error = TimeoutError

    def __init__(self, monitors=None, page=None):
        self._monitors = list(monitors or [])
        self._page = page
        self.calls = []
        self.next_id = 10

    def login(self, username, password):
        self.calls.append(("login", username, password))
        return {"token": "t"}

    def monitors(self):
        return [dict(m) for m in self._monitors]

    def add_monitor(self, **fields):
        self.calls.append(("add", fields))
        self.next_id += 1
        return {"monitorID": self.next_id, "msg": "Added Successfully."}

    def edit_monitor(self, id_, **fields):
        self.calls.append(("editMonitor", id_, fields))
        return {"monitorID": id_, "msg": "Saved."}

    def delete_monitor(self, id_):
        self.calls.append(("deleteMonitor", id_))
        return {}

    def status_page(self, slug):
        return self._page

    def add_status_page(self, slug, title):
        self.calls.append(("addStatusPage", slug, title))
        return {"msg": "OK!"}

    def save_status_page(self, slug, **fields):
        self.calls.append(("saveStatusPage", slug, fields))
        return {}

    def close(self):
        self.calls.append(("close",))

    def writes(self):
        return [c for c in self.calls if c[0] not in ("login", "close")]


class KumaFailure(Exception):
    """Stands in for uptime_kuma_api.UptimeKumaException."""


class FailingKumaApi(FakeKumaApi):
    errors = (KumaFailure,)

    def login(self, username, password):
        raise KumaFailure("Incorrect username or password")


class TestKumaReconcile(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="stackctl-kuma-")
        self.config = os.path.join(self.tmp, "config")
        os.makedirs(os.path.join(self.config, "uptime-kuma"))
        with open(os.path.join(self.config, "uptime-kuma", "api.env"), "w") as f:
            f.write("KUMA_USERNAME=admin\nKUMA_PASSWORD=secret\n")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_manifest(self, monitors, slug="stack"):
        """Expand the old pipe-shaped monitor entries into the manifest tables
        ([host.*] per HTTP URL, [kuma.monitor.*], [kuma.page])."""
        blocks = []
        seen_hosts = {}
        for i, entry in enumerate(monitors):
            name, url, codes, interval, retries = (entry.split("|") + ["", "", "", ""])[:5]
            extra = f'interval = {interval or 60}\nretries = {retries or 2}\n'
            if url.startswith("tcp://"):
                blocks.append(f'[kuma.monitor.m{i}]\nname = "{name}"\n'
                              f'tcp = "{url[6:]}"\n{extra}')
                continue
            scheme, _, rest = url.partition("://")
            hostpart, _, path = rest.partition("/")
            path = "/" + path if path else ""
            if hostpart not in seen_hosts:
                key = f"k{i}"
                seen_hosts[hostpart] = key
                blocks.append(f'[host.{key}]\ndomain = "{hostpart}"\n')
            codes_list = json.dumps(codes.split(",") if codes else ["200-299"])
            blocks.append(f'[kuma.monitor.m{i}]\nname = "{name}"\n'
                          f'host = "{seen_hosts[hostpart]}"\npath = "{path}"\n'
                          f'codes = {codes_list}\n{extra}')
        if slug:
            blocks.append(f'[kuma.page]\nslug = "{slug}"\n'
                          'title = "Test services"\ngroup = "Public"\n')
        path = os.path.join(self.tmp, "services.toml")
        with open(path, "w") as f:
            f.write("\n".join(blocks))
        return path

    def facts(self, monitors, dry="0", prune="0", slug="stack"):
        """Put the wrapper's facts in the environment, where the reconciler
        reads them."""
        env = {
            "MANIFEST": self.write_manifest(monitors, slug),
            "CONFIG_DIR": self.config,
            "DRY_RUN": dry,
            "PRUNE": prune,
        }
        for key, value in env.items():
            os.environ[key] = value
            self.addCleanup(os.environ.pop, key, None)

    def reconcile(self, api):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = kuma.reconcile(client_factory=lambda url: api)
        return rc, out.getvalue(), err.getvalue()

    def test_all_unchanged_and_page_left_alone(self):
        api = FakeKumaApi(
            monitors=[
                {"id": 1, "name": "SearXNG", "type": "http", "url": "https://s",
                 "accepted_statuscodes": ["200-299"], "notificationIDList": {"5": True}},
                {"id": 2, "name": "Fulcrum", "type": "port", "hostname": "h", "port": 50001},
            ],
            page={"id": 7, "publicGroupList": [{"monitorList": [{"id": 1}]}]},
        )
        self.facts(["SearXNG|https://s|200-299", "Fulcrum|tcp://h:50001"])
        rc, out, _ = self.reconcile(api)
        self.assertEqual(rc, 0)
        self.assertIn('monitor "SearXNG" unchanged (id 1)', out)
        self.assertIn('monitor "Fulcrum" unchanged (id 2)', out)
        self.assertIn("status page 'stack' exists and carries monitors; "
                      "the layout stays with the UI", out)
        # nothing was written, and the credentials came from api.env
        self.assertEqual(api.writes(), [])
        self.assertEqual(api.calls[0], ("login", "admin", "secret"))
        self.assertEqual(api.calls[-1], ("close",))

    def test_add_edit_and_dry_run(self):
        api = FakeKumaApi(monitors=[
            {"id": 3, "name": "SearXNG", "type": "http", "url": "https://old",
             "accepted_statuscodes": ["200-299"], "notificationIDList": {"9": True},
             "interval": 300, "conditions": ["cond"]},
        ])
        self.facts([
            "SearXNG|https://new|200-299,400-499",
            "New port|tcp://p:50001",
            "New http|https://n|200-299",
        ])
        rc, out, _ = self.reconcile(api)
        self.assertEqual(rc, 0)
        self.assertIn('updated monitor "SearXNG" (id 3)', out)
        self.assertIn('created monitor "New port" (id 11', out)
        self.assertIn('created monitor "New http" (id 12', out)

        edits = [c for c in api.writes() if c[0] == "editMonitor"]
        adds = [c for c in api.writes() if c[0] == "add"]
        self.assertEqual(len(edits), 1)
        self.assertEqual(len(adds), 2)
        edit, (add_port, add_http) = edits[0], adds
        # EXACTLY the declared fields: the library merges the stored monitor
        # back in, so the UI's notification list, interval and conditions are
        # never rewritten by a reconcile.
        self.assertEqual(edit, ("editMonitor", 3,
                                {"url": "https://new",
                                 "accepted_statuscodes": ["200-299", "400-499"]}))
        fields = add_port[1]
        self.assertEqual(fields["type"], "port")
        self.assertEqual(fields["hostname"], "p")
        self.assertEqual(fields["port"], 50001)
        self.assertEqual(fields["url"], "tcp://p:50001")
        self.assertEqual(fields["accepted_statuscodes"], ["200-299"])  # the .every() trap
        self.assertEqual(fields["interval"], 60)
        self.assertEqual(fields["retryInterval"], 60)
        self.assertEqual(fields["maxretries"], 2)
        fields = add_http[1]
        self.assertEqual(fields["type"], "http")
        self.assertEqual(fields["method"], "GET")
        self.assertEqual(fields["url"], "https://n")
        self.assertEqual(fields["accepted_statuscodes"], ["200-299"])

        # dry-run plans the same edits but writes nothing
        api = FakeKumaApi(monitors=[
            {"id": 3, "name": "SearXNG", "type": "http", "url": "https://old",
             "accepted_statuscodes": ["200-299"]},
        ])
        self.facts([
            "SearXNG|https://newer|200-299", "New port|tcp://p:50001"], dry="1")
        rc, out, _ = self.reconcile(api)
        self.assertIn("[dry-run] would update monitor", out)
        self.assertIn("[dry-run] would create monitor", out)
        self.assertEqual(api.writes(), [])

    def test_prune_and_fill_an_empty_page(self):
        api = FakeKumaApi(
            monitors=[
                {"id": 1, "name": "Keep", "type": "http", "url": "https://k",
                 "accepted_statuscodes": ["200-299"]},
                {"id": 9, "name": "Stale", "type": "http", "url": "https://s",
                 "accepted_statuscodes": ["200-299"]},
            ],
            page={"id": 7, "publicGroupList": []},  # exists but empty -> we fill it
        )
        self.facts(["Keep|https://k|200-299"], prune="1")
        rc, out, _ = self.reconcile(api)
        self.assertEqual(rc, 0)
        self.assertIn('deleted monitor "Stale" (id 9, not declared)', out)
        self.assertIn("published status page 'stack' (1 monitor(s))", out)
        self.assertIn(("deleteMonitor", 9), api.calls)
        self.assertNotIn("addStatusPage", [c[0] for c in api.calls])
        save = [c for c in api.calls if c[0] == "saveStatusPage"][0]
        self.assertEqual(save[1], "stack")
        self.assertEqual(save[2]["title"], "Test services")
        self.assertIs(save[2]["published"], True)
        self.assertEqual(save[2]["publicGroupList"][0]["monitorList"],
                         [{"id": 1, "weight": 1}])

    def test_new_page_is_created_then_filled(self):
        api = FakeKumaApi(
            monitors=[{"id": 1, "name": "Keep", "type": "http", "url": "https://k",
                       "accepted_statuscodes": ["200-299"]}],
            page=None,
        )
        self.facts(["Keep|https://k|200-299"])
        rc, out, _ = self.reconcile(api)
        self.assertEqual(rc, 0)
        self.assertIn("created status page 'stack'", out)
        names = [c[0] for c in api.calls]
        self.assertLess(names.index("addStatusPage"), names.index("saveStatusPage"))
        self.assertEqual([c for c in api.calls if c[0] == "addStatusPage"][0],
                         ("addStatusPage", "stack", "Test services"))

    def test_bad_login_dies(self):
        api = FailingKumaApi()
        self.facts(["X|https://x"])
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(Fatal) as ctx:
                kuma.reconcile(client_factory=lambda url: api)
        self.assertIn("Incorrect username", ctx.exception.msg)
        self.assertEqual(api.calls[-1], ("close",))

    def test_missing_credentials_self_skip(self):
        os.remove(os.path.join(self.config, "uptime-kuma", "api.env"))
        api = FakeKumaApi()
        self.facts(["X|https://x"])
        rc, out, _ = self.reconcile(api)
        self.assertEqual(rc, 0)
        self.assertIn("no Uptime-Kuma admin login", out)
        self.assertEqual(api.calls, [])


# ---------------------------------------------------------------------------
# deploy/services.toml: the loader, the shell emission and the CI gate. The
# real manifest is exercised (not just fixtures) because it IS the declaration
# of this host's public surface -- if it stops loading, every reconciler does.
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
        self.assertEqual(len(m.kuma_monitors), 8)
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
        self.assertEqual(m.kuma_loopback, 8107)
        self.assertEqual(m.kuma_page.slug, "stack")
        fulcrum = [x for x in m.kuma_monitors if x.type == "port"][0]
        self.assertEqual((fulcrum.hostname, fulcrum.port), ("host.containers.internal", 50001))

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
        # gets the same variable names stack.conf used to define.
        script = (
            'set -euo pipefail; eval "$(PYTHONPATH=' + shlex_quote(ROOT + "/scripts")
            + ' python3 -m stackctl manifest shell ' + shlex_quote(MANIFEST) + ')"; '
            'printf "%s\\n" "${#MCP_HOSTS[@]}" "$MCP_HOST" "${#ONION_SERVICES[@]}" '
            '"${#KUMA_ADD_HOST_HOSTS[@]}" "$KUMA_STATUS_SLUG" "${MCP_HOSTS[0]}" '
            '"${ONION_SERVICES[2]}" "$BOLTMESH_FRONTEND_HOST" "${#MCP_PROBES[@]}" '
            '"${MCP_PROBES[0]}"'
        )
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                             check=True).stdout.splitlines()
        self.assertEqual(out[0], "10")
        self.assertEqual(out[1], "mcp.boltmesh.net")
        self.assertEqual(out[2], "5")
        self.assertEqual(out[3], "6")       # mcp + status opt out of --add-host
        self.assertEqual(out[4], "stack")
        self.assertEqual(out[5], "/searxng:searxng-mcp:8100")
        self.assertEqual(out[6], "btc-explorer|10.89.0.243:3002|btc.boltmesh.net|/|200,401")
        self.assertEqual(out[7], "boltmesh.net")
        self.assertEqual(out[8], "10")
        self.assertEqual(out[9], 'searxng-mcp|SEARXNG_MCP_TOKEN|get_time|{"tz":"UTC"}|0|')

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

        bad("bad-kuma-codes.toml", """
[host.a]
domain = "a.example"
[kuma.monitor.x]
name = "X"
host = "a"
codes = ["200"]
""", "codes must be ranges")
        bad("tcp-and-host.toml", """
[host.a]
domain = "a.example"
[kuma.monitor.x]
name = "X"
host = "a"
tcp = "h:1"
""", "declares tcp AND")

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

[uptime_kuma]
loopback_port = 8107
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

[uptime_kuma]
loopback_port = 8107
""")
        agents = self.write("AGENTS.md", "| Server | Container | ... | NPM target |\n"
                            "| --- | --- | --- | --- |\n"
                            "| `one-mcp` | `one-mcp` | ... | `127.0.0.1:8100` |\n")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(manifest.check(path, agents), 0)
            m = manifest.load(path)
        out = m.shell()
        self.assertIn("MCP_HOST=mcp.example.net", out)
        self.assertIn("MCP_HOSTS=(/one:one-mcp:8100)", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
