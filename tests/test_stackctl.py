#!/usr/bin/env python3
# Offline tests for the Python core behind the bash wrappers (scripts/stackctl/).
#
# Run: python3 tests/test_stackctl.py          (CI runs this verbatim)
#
# What is covered, and why each layer exists:
#   * duration.py -- the SAME fixture file tests/test-lib.sh reads, so the
#     bash and Python parsers cannot drift apart;
#   * decl.py -- the declaration parsers and their verbatim error messages;
#   * npm.py -- payload construction byte-for-byte (field order included,
#     which is what made the golden diff against the bash original a real
#     check), plus a full reconcile against a fake NPM admin API;
#   * ws.py / socketio.py -- the frame codec from fixtures (fragmentation,
#     7/16/64-bit lengths, control frames, protocol violations), packet
#     dispatch with no socket at all, and a scripted fake socket.io server
#     (one port serving both the websocket upgrade and the REST status-page
#     probe, like real kuma) driving the whole kuma reconcile offline.
#
# The live behaviour was additionally proven against the running stack before
# this suite was written: both reconcilers' --dry-run output matched the bash
# and Node originals byte for byte, and the kuma add/edit/prune write paths
# were exercised against the live server and restored. That cannot run in CI;
# this file is what keeps those semantics from regressing afterwards.
import base64
import contextlib
import io
import json
import os
import re
import socket
import struct
import sys
import threading
import time
import unittest
from hashlib import sha1
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from stackctl import decl, duration, envfile, kuma, npm, socketio, ws  # noqa: E402
from stackctl.ui import Fatal  # noqa: E402


def die_msg(fn, *args, **kwargs):
    """Run a parser that is expected to die; return its message, or None when
    it did not (which is the test failure)."""
    try:
        fn(*args, **kwargs)
    except Fatal as e:
        return e.msg
    return None


# ---------------------------------------------------------------------------


class TestDuration(unittest.TestCase):
    def test_shared_fixtures(self):
        path = os.path.join(ROOT, "tests", "fixtures", "durations.txt")
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                raw, _, want = line.partition("\t")
                value = "" if raw == "<empty>" else raw
                with self.subTest(dur=value):
                    self.assertEqual(duration.dur_ms(value), int(want))

    def test_dur_s_rounds_up(self):
        self.assertEqual(duration.dur_s("4.5s"), 5)
        self.assertEqual(duration.dur_s("500ms"), 1)
        self.assertEqual(duration.dur_s("2s"), 2)


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


class TestDecl(unittest.TestCase):
    def test_npm_host(self):
        h = decl.parse_npm_host("status.example.net|127.0.0.1:8107|ws,block")
        self.assertEqual((h.domain, h.scheme, h.host, h.port, h.flags),
                         ("status.example.net", "http", "127.0.0.1", "8107", "ws,block"))
        self.assertTrue(h.has_flag("ws"))
        self.assertFalse(h.has_flag("w"))

    def test_npm_host_scheme_and_tail_pipes(self):
        h = decl.parse_npm_host("d|https://up:443|a|b|c")
        self.assertEqual((h.scheme, h.host, h.port), ("https", "up", "443"))
        # IFS='|' read keeps every remaining pipe in the last field.
        self.assertEqual(h.flags, "a|b|c")

    def test_npm_host_errors(self):
        self.assertIn("bad NPM_HOSTS entry",
                      die_msg(decl.parse_npm_host, "only-one-field"))
        self.assertIn("bad forward scheme",
                      die_msg(decl.parse_npm_host, "d|ftp://x:1|"))
        self.assertIn("bad forward port",
                      die_msg(decl.parse_npm_host, "d|no-port-here|"))

    def test_mcp_host_greedy_port(self):
        m = decl.parse_mcp_host("/searxng:searxng-mcp:8100")
        self.assertEqual((m.prefix, m.container, m.port),
                         ("/searxng", "searxng-mcp", "8100"))
        self.assertIn("bad MCP_HOSTS entry", die_msg(decl.parse_mcp_host, "no-colons"))
        self.assertIn("bad MCP_HOSTS entry",
                      die_msg(decl.parse_mcp_host, "/x:c:notaport"))

    def test_onion_service(self):
        o = decl.parse_onion_service("boltmesh|10.89.0.241:80|mirror|/|200,401")
        self.assertEqual((o.name, o.target, o.mirrors), ("boltmesh", "10.89.0.241:80", "mirror"))

    def test_kuma_http_and_port(self):
        m = decl.parse_kuma_monitor("SearXNG|https://search.example.net|200-299,400-499|120|3")
        self.assertEqual((m.type, m.url, m.codes, m.interval, m.maxretries),
                         ("http", "https://search.example.net", ["200-299", "400-499"], 120, 3))
        p = decl.parse_kuma_monitor("Fulcrum (Electrum TCP)|tcp://h.internal:50001||60|2")
        self.assertEqual((p.type, p.hostname, p.port, p.codes), ("port", "h.internal", 50001, []))
        self.assertEqual(p.describe(), "h.internal:50001 (tcp)")
        self.assertEqual(p.url, "tcp://h.internal:50001")
        # defaults
        d = decl.parse_kuma_monitor("X|https://x")
        self.assertEqual((d.codes, d.interval, d.maxretries), (["200-299"], 60, 2))

    def test_kuma_errors(self):
        self.assertIn("bad KUMA_MONITORS entry", die_msg(decl.parse_kuma_monitor, "name-only"))
        self.assertIn("bad accepted status codes",
                      die_msg(decl.parse_kuma_monitor, "n|https://x|200"))
        self.assertIn("accepts no status codes",
                      die_msg(decl.parse_kuma_monitor, "n|tcp://h:1|200-299"))
        self.assertIn("bad tcp:// target", die_msg(decl.parse_kuma_monitor, "n|tcp://noport"))
        self.assertIn("bad port", die_msg(decl.parse_kuma_monitor, "n|tcp://h:0"))
        self.assertIn("bad monitor URL", die_msg(decl.parse_kuma_monitor, "n|ftp://x"))
        self.assertIn("bad interval", die_msg(decl.parse_kuma_monitor, "n|https://x|200-299|x"))
        self.assertIn("bad retries", die_msg(decl.parse_kuma_monitor, "n|https://x|200-299|60|x"))

    def test_read_decls_protocol(self):
        d = decl.read_decls(io.StringIO(
            "V\tDATA_DIR\t/data\n"
            "V\tDRY_RUN\t1\n"
            "H\td|127.0.0.1:1|block\n"
            "M\t/x:c:8100\n"
            "O\tname|target|mirror|/|200\n"
            "K\tn|https://x\n"))
        self.assertEqual(d.var("DATA_DIR"), "/data")
        self.assertTrue(d.flag("DRY_RUN"))
        self.assertFalse(d.flag("PRUNE"))
        self.assertEqual(len(d.npm_hosts), 1)
        self.assertEqual(len(d.mcp_hosts), 1)
        self.assertEqual(len(d.onion_services), 1)
        self.assertEqual(len(d.kuma_monitors), 1)


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
        clearweb = decl.parse_npm_host("d|127.0.0.1:1|block")
        mcp = decl.parse_npm_host("m|127.0.0.1:1|mcp,http2")
        onion = decl.parse_npm_host("x.onion|127.0.0.1:1|mcp")
        self.assertEqual(npm.rate_limits(clearweb),
                         "limit_req zone=stack_ip burst=60 nodelay;\nlimit_conn stack_conn 40;")
        self.assertEqual(npm.rate_limits(mcp), "limit_conn stack_conn 200;")
        # The onion branch wins even when the mcp flag is set -- dropping that
        # precedence silently removes the onion side's only brake.
        self.assertEqual(npm.rate_limits(onion), "limit_req zone=stack_onion burst=120 nodelay;")

    def test_flags_without(self):
        h = decl.parse_npm_host("d|127.0.0.1:1|mcp,force-ssl,http2")
        self.assertEqual(h.flags_without("force-ssl"), "mcp,http2")

    def test_mcp_locations(self):
        locs = npm.mcp_locations([decl.parse_mcp_host("/x:c:8100"),
                                  decl.parse_mcp_host("/y:d:8101")])
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

    def test_raw_array(self):
        self.assertEqual(kuma.raw_array(["a"]), ["a"])
        self.assertEqual(kuma.raw_array('["a","b"]'), ["a", "b"])
        self.assertEqual(kuma.raw_array("not json"), [])
        self.assertEqual(kuma.raw_array(None), [])

    def test_differs(self):
        http = decl.parse_kuma_monitor("n|https://x|200-299")
        self.assertFalse(kuma.differs({"type": "http", "url": "https://x",
                                       "accepted_statuscodes": ["200-299"]}, http))
        self.assertTrue(kuma.differs({"type": "http", "url": "https://y",
                                      "accepted_statuscodes": ["200-299"]}, http))
        self.assertTrue(kuma.differs({"type": "http", "url": "https://x",
                                      "accepted_statuscodes": ["200-299,300-399"]}, http))
        port = decl.parse_kuma_monitor("n|tcp://h:50001")
        self.assertFalse(kuma.differs({"type": "port", "hostname": "h", "port": 50001}, port))
        self.assertTrue(kuma.differs({"type": "port", "hostname": "h", "port": "50002"}, port))
        self.assertTrue(kuma.differs({"type": "http", "url": "https://x",
                                      "accepted_statuscodes": ["200-299"]}, port))
        # an existing type of None reads as http, like the mjs's `?? "http"`
        self.assertFalse(kuma.differs({"url": "https://x",
                                       "accepted_statuscodes": ["200-299"]}, http))


# ---------------------------------------------------------------------------


class TestWsCodec(unittest.TestCase):
    def test_encode_masked_round_trip(self):
        payload = b'42["login",{"username":"u","password":"p"}]'
        frame = ws.encode_frame(ws.OP_TEXT, payload, mask_key=b"\x01\x02\x03\x04")
        # Client frames are always masked: the mask bit is set and the payload
        # does not appear in the clear.
        self.assertEqual(frame[1] & 0x80, 0x80)
        self.assertNotIn(payload, frame)
        # Demask (what a server does) and recover the payload.
        head, mask, masked = frame[:2], frame[2:6], frame[6:]
        clear = bytes(b ^ mask[i % 4] for i, b in enumerate(masked))
        self.assertEqual(clear, payload)

    def test_length_forms(self):
        small = ws.encode_frame(ws.OP_TEXT, b"x" * 100, mask_key=b"abcd")
        self.assertEqual(small[1] & 0x7F, 100)
        medium = ws.encode_frame(ws.OP_TEXT, b"x" * 300, mask_key=b"abcd")
        self.assertEqual(medium[1] & 0x7F, 126)
        self.assertEqual(struct.unpack(">H", medium[2:4])[0], 300)
        big = ws.encode_frame(ws.OP_TEXT, b"x" * 70000, mask_key=b"abcd")
        self.assertEqual(big[1] & 0x7F, 127)
        self.assertEqual(struct.unpack(">Q", big[2:10])[0], 70000)

    def feed(self, frames):
        dec = ws.FrameDecoder()
        return dec, b"".join(frames)

    def test_decode_whole_and_byte_at_a_time(self):
        payload = b"0" + b"y" * 70000
        frame = ws.encode_frame(ws.OP_TEXT, payload)  # unmasked = server style
        for chunking in (lambda b: [b], lambda b: [bytes([x]) for x in b]):
            dec = ws.FrameDecoder()
            out = []
            for chunk in chunking(frame):
                out.extend(dec.feed(chunk))
            self.assertEqual([(ws.OP_TEXT, payload)], out)

    def test_fragmentation_with_interleaved_control(self):
        # encode_frame always sets FIN; build the unmasked fragment headers by
        # hand to exercise the decoder's assembly path (a real server sends
        # FIN=0 first frames + continuation frames).
        def raw(fin, opcode, payload):
            head = bytearray()
            head.append((0x80 if fin else 0x00) | opcode)
            head.append(len(payload))
            return bytes(head) + payload

        dec = ws.FrameDecoder()
        got = []
        got += dec.feed(raw(False, ws.OP_TEXT, b"hello "))
        got += dec.feed(ws.encode_frame(ws.OP_PING, b"pi"))  # control mid-fragment
        got += dec.feed(raw(False, ws.OP_CONT, b"wor"))
        got += dec.feed(raw(True, ws.OP_CONT, b"ld"))
        self.assertEqual(got, [(ws.OP_PING, b"pi"), (ws.OP_TEXT, b"hello world")])

    def test_protocol_violations(self):
        dec = ws.FrameDecoder()
        with self.assertRaises(ws.WebSocketError):
            list(dec.feed(ws.encode_frame(ws.OP_TEXT, b"x", mask_key=b"abcd")))
        dec2 = ws.FrameDecoder()
        with self.assertRaises(ws.WebSocketError):
            list(dec2.feed(bytes([0x80 | ws.OP_CONT, 3]) + b"abc"))

    def test_close_stops_the_stream(self):
        dec = ws.FrameDecoder()
        out = list(dec.feed(ws.encode_frame(ws.OP_CLOSE, struct.pack(">H", 1000))))
        self.assertEqual(out, [(ws.OP_CLOSE, struct.pack(">H", 1000))])
        with self.assertRaises(ws.WebSocketError):
            list(dec.feed(ws.encode_frame(ws.OP_TEXT, b"after")))


class TestSocketIODispatch(unittest.TestCase):
    def client(self):
        c = socketio.SocketIOClient("http://fake")
        c._reader = threading.Thread(target=lambda: None, daemon=True)  # not None
        return c

    def test_connect_and_pushes(self):
        c = self.client()
        c._dispatch("40{\"sid\":\"abc\"}")
        self.assertTrue(c._connected.is_set())
        c._dispatch("42[\"info\",{\"version\":\"2.5\"}]")
        c._dispatch("42[\"monitorList\",{\"1\":{\"id\":1}}]")
        self.assertEqual(c.wait_event("info", 0), [{"version": "2.5"}])
        self.assertEqual(c.wait_event("monitorList", 0), [{"1": {"id": 1}}])
        self.assertIsNone(c.wait_event("never-pushed", 0))

    def test_ping_pong_and_acks(self):
        c = self.client()
        sent = []
        c._ws = type("W", (), {"send_text": staticmethod(lambda t: sent.append(t))})()
        c._dispatch("2")
        self.assertEqual(sent, ["3"])
        c._dispatch_sio("3[{\"ok\":true}]")
        # an ACK with no id (or a bad body) is dropped, not fatal
        c._dispatch_sio("9[{\"ok\":true}]")
        c._dispatch_sio("3notjson")
        # login emit -> ack round trip
        ack = {}

        def waiter():
            ack["res"] = c.emit_ack("login", [{"username": "u"}], timeout=2)

        threading.Thread(target=waiter, daemon=True).start()
        packet = None
        for _ in range(500):  # poll with yields: the waiter thread must run
            packet = next((s for s in sent if s.startswith("42")), None)
            if packet:
                break
            time.sleep(0.01)
        self.assertIsNotNone(packet)  # skip the pong
        m = re.match(r"42(\d+)(\[.*)", packet, re.DOTALL)
        self.assertIsNotNone(m)
        self.assertEqual(json.loads(m.group(2)), ["login", {"username": "u"}])
        c._dispatch_sio(f"3{m.group(1)}" + '[{"ok":true,"token":"t"}]')  # 43<id>[...]
        for _ in range(500):
            if "res" in ack:
                break
            time.sleep(0.01)
        self.assertEqual(ack.get("res"), {"ok": True, "token": "t"})

    def test_connect_error_and_disconnect(self):
        c = self.client()
        c._dispatch_sio("4{\"message\":\"not v2\"}")
        self.assertIn("not v2", c.error)
        c2 = self.client()
        c2._dispatch_sio("1")
        self.assertIn("disconnected", c2.error)


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
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def decls(self, hosts_lines, mcp=(), dry="0", prune="0", request_cert=None):
        if request_cert is not None:
            # NPM_REQUEST_CERT reaches the reconciler through the process
            # environment (inherited from the operator's shell), exactly as it
            # reached the bash original -- not through the declaration stream.
            os.environ["NPM_REQUEST_CERT"] = request_cert
            self.addCleanup(os.environ.pop, "NPM_REQUEST_CERT", None)
        lines = [f"V\tNPM_API\t{self.api}",
                 f"V\tDATA_DIR\t{self.tmp}",
                 f"V\tCONFIG_DIR\t{self.config}",
                 f"V\tDRY_RUN\t{dry}",
                 f"V\tPRUNE\t{prune}"]
        lines += [f"H\t{h}" for h in hosts_lines]
        lines += [f"M\t{m}" for m in mcp]
        return decl.read_decls(io.StringIO("\n".join(lines) + "\n"))

    def reconcile(self, d):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = npm.reconcile(d)
        return rc, out.getvalue(), err.getvalue()

    def test_dry_run_touches_nothing(self):
        d = self.decls(["d.example.net|127.0.0.1:8107|ws,block"], dry="1")
        rc, out, err = self.reconcile(d)
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
        d = self.decls(["d.example.net|127.0.0.1:8107|force-ssl,block"])
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"created proxy host \d+")
        created = [r for r in self.server.requests if r[0] == "POST" and r[1] == "/api/nginx/proxy-hosts"]
        self.assertEqual(created[0][2]["certificate_id"], 6)
        self.assertTrue(created[0][2]["ssl_forced"])

        self.server.requests.clear()
        rc, out, _ = self.reconcile(d)
        self.assertRegex(out, r"updated proxy host")
        updated = [r for r in self.server.requests if r[0] == "PUT"]
        self.assertEqual(updated[0][2]["certificate_id"], 6)
        cert_posts = [r for r in self.server.requests
                      if r[0] == "POST" and r[1] == "/api/nginx/certificates"]
        self.assertEqual(cert_posts, [])  # reused, never re-requested

    def test_no_certificate_strips_force_ssl(self):
        d = self.decls(["d.example.net|127.0.0.1:8107|force-ssl,block"],
                       request_cert="0")
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        created = [r for r in self.server.requests if r[0] == "POST" and r[1] == "/api/nginx/proxy-hosts"]
        self.assertEqual(created[0][2]["certificate_id"], 0)
        self.assertFalse(created[0][2]["ssl_forced"])

    def test_mcp_host_locations_and_limits(self):
        d = self.decls(["m.example.net|127.0.0.1:8100|mcp,force-ssl,http2"],
                       mcp=["/searxng:searxng-mcp:8100", "/bitcoin:bitcoin-node-mcp:8101"],
                       request_cert="0")
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        body = [r for r in self.server.requests if r[0] == "POST" and r[1] == "/api/nginx/proxy-hosts"][0][2]
        self.assertEqual([l["path"] for l in body["locations"]], ["/searxng", "/bitcoin"])
        self.assertEqual([l["forward_port"] for l in body["locations"]], [8100, 8101])
        self.assertIn("proxy_buffering off;", body["advanced_config"])
        self.assertIn("limit_conn stack_conn 200;", body["advanced_config"])
        self.assertIn("MCP endpoints", out)
        self.assertIn("searxng-mcp/token.env", out)

    def test_onion_host(self):
        d = self.decls(["*.onion|127.0.0.1:8100|mcp"],
                       mcp=["/searxng:searxng-mcp:8100"], request_cert="1")
        rc, out, _ = self.reconcile(d)
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
        d = self.decls(["keep.example.net|127.0.0.1:8107|block"], prune="1")
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        self.assertIn("deleted proxy host 99 (not in NPM_HOSTS)", out)
        self.assertIn("deleted certificate 7 (unused, not in NPM_HOSTS)", out)
        kept = [r for r in self.server.requests if r[0] == "DELETE"]
        self.assertEqual([r[1] for r in kept],
                         ["/api/nginx/proxy-hosts/99", "/api/nginx/certificates/7"])

    def test_missing_credentials_self_skip(self):
        os.remove(os.path.join(self.config, "npm", "api.env"))
        d = self.decls(["d|127.0.0.1:1|"])
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        self.assertIn("no nginx-proxy-manager API credentials", out)
        self.assertEqual(self.server.requests, [])


# ---------------------------------------------------------------------------
# A fake Uptime-Kuma: one port that speaks both the socket.io websocket (a
# manual hijack of the HTTP connection) and the public REST status-page
# endpoint, scripted per test through `script`.
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def server_send_frame(sock, text):
    # Reuse the production codec, unmasked (server style): a hand-rolled
    # header breaks the moment a payload crosses 125 bytes, because the
    # length byte then carries the mask bit.
    sock.sendall(ws.encode_frame(ws.OP_TEXT, text.encode()))


def server_read_frame(rfile):
    b = rfile.read(2)
    if not b or len(b) < 2:
        return None
    opcode = b[0] & 0x0F
    masked = bool(b[1] & 0x80)
    length = b[1] & 0x7F
    pos = 2
    if length == 126:
        length = struct.unpack(">H", rfile.read(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", rfile.read(8))[0]
    mask = rfile.read(4) if masked else None
    payload = rfile.read(length)
    if masked and mask:
        payload = bytes(x ^ mask[i % 4] for i, x in enumerate(payload))
    return opcode, payload.decode("utf-8", "replace")


class FakeKumaHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/socket.io/"):
            key = self.headers.get("Sec-WebSocket-Key")
            accept = base64.b64encode(sha1(key.encode() + GUID).digest()).decode()
            self.connection.sendall((
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            self.close_connection = True
            self.server.websocket_session(self.connection)
            return
        self.server.http_requests.append(self.path)
        if self.path.startswith("/api/status-page/"):
            self._json({"publicGroupList": self.server.status_groups})
        else:
            self._json({"error": "not found"}, 404)

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class FakeKuma(ThreadingHTTPServer):
    """script: dict event -> ack value; monitor_list: the object pushed after
    login; status_groups: what the public REST endpoint reports."""

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FakeKumaHandler)
        self.events = []
        self.http_requests = []
        self.script = {}
        self.monitor_list = {}
        self.status_groups = []
        self.pings_before_login = 1

    def websocket_session(self, sock):
        sock.settimeout(30)
        rfile = sock.makefile("rb")
        try:
            server_send_frame(sock, '0{"sid":"s","pingInterval":25000,"pingTimeout":20000}')
            got = server_read_frame(rfile)
            assert got == (ws.OP_TEXT, "40"), f"expected namespace CONNECT, got {got}"
            server_send_frame(sock, '40{"sid":"ns"}')
            server_send_frame(sock, '42["info",{"version":"2.5.x"}]')
            # A real server pings whenever its interval fires; prove the
            # client answers from its read side before any reconcile step.
            sock.sendall(bytes([0x80 | ws.OP_PING, 3]) + b"abc")
            while True:
                got = server_read_frame(rfile)
                if got is None or got[1] == "41":
                    break
                if got[0] == ws.OP_PONG or got[1] == "3":
                    self.ponged = True
                    continue
                if got[1] == "2":
                    server_send_frame(sock, "3")
                    continue
                if not got[1].startswith("42"):
                    continue
                body = got[1][2:]
                digits = ""
                while body and body[0].isdigit():
                    digits += body[0]
                    body = body[1:]
                data = json.loads(body)
                event, args = data[0], data[1:]
                self.events.append((event, args))
                if event == "login" and args and args[0].get("username") == "BOOM":
                    server_send_frame(sock, f"43{digits}" + '[{"ok":false,"msg":"bad"}]')
                    continue
                server_send_frame(sock, f"43{digits}" + json.dumps([self.script.get(event, {"ok": True})]))
                if event == "login":
                    server_send_frame(sock, "42[\"monitorList\"," + json.dumps(self.monitor_list) + "]")
        except (OSError, AssertionError):
            pass
        finally:
            try:
                sock.close()
            except OSError:
                pass


class TestKumaReconcile(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="stackctl-kuma-")
        self.config = os.path.join(self.tmp, "config")
        os.makedirs(os.path.join(self.config, "uptime-kuma"))
        with open(os.path.join(self.config, "uptime-kuma", "api.env"), "w") as f:
            f.write("KUMA_USERNAME=admin\nKUMA_PASSWORD=secret\n")
        self.server = FakeKuma()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def decls(self, monitors, dry="0", prune="0", slug="stack"):
        lines = [f"V\tKUMA_URL\t{self.url}",
                 f"V\tCONFIG_DIR\t{self.config}",
                 f"V\tDRY_RUN\t{dry}",
                 f"V\tPRUNE\t{prune}",
                 f"V\tKUMA_STATUS_SLUG\t{slug}",
                 "V\tKUMA_STATUS_TITLE\tTest services",
                 "V\tKUMA_STATUS_GROUP\tPublic"]
        lines += [f"K\t{m}" for m in monitors]
        return decl.read_decls(io.StringIO("\n".join(lines) + "\n"))

    def reconcile(self, d):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = kuma.reconcile(d)
        return rc, out.getvalue(), err.getvalue()

    def events(self, name):
        return [a for ev, a in self.server.events if ev == name]

    def test_all_unchanged_and_page_left_alone(self):
        self.server.monitor_list = {
            "1": {"id": 1, "name": "SearXNG", "type": "http", "url": "https://s",
                  "accepted_statuscodes": ["200-299"], "notificationIDList": {"5": True}},
            "2": {"id": 2, "name": "Fulcrum", "type": "port", "hostname": "h", "port": 50001},
        }
        self.server.status_groups = [{"monitorList": [{"id": 1}]}]  # page carries monitors
        self.server.script = {"login": {"ok": True}, "getStatusPage": {"ok": True, "config": {}}}
        d = self.decls(["SearXNG|https://s|200-299",
                        "Fulcrum|tcp://h:50001"])
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        self.assertIn('monitor "SearXNG" unchanged (id 1)', out)
        self.assertIn('monitor "Fulcrum" unchanged (id 2)', out)
        self.assertIn("status page 'stack' exists and carries monitors; "
                      "the layout stays with the UI", out)
        # no write events at all, the pong was answered, REST was probed
        self.assertEqual(self.events("add"), [])
        self.assertEqual(self.events("editMonitor"), [])
        self.assertEqual(self.events("saveStatusPage"), [])
        self.assertTrue(getattr(self.server, "ponged", False))
        self.assertTrue(any(p == "/api/status-page/stack" for p in self.server.http_requests))

    def test_add_edit_and_dry_run(self):
        self.server.monitor_list = {
            "3": {"id": 3, "name": "SearXNG", "type": "http", "url": "https://old",
                  "accepted_statuscodes": ["200-299"],
                  "notificationIDList": {"9": True}, "interval": 300,
                  "conditions": '["cond"]', "kafkaProducerBrokers": "junk"},
        }
        self.server.script = {"login": {"ok": True}, "add": {"ok": True, "monitorID": 11},
                              "editMonitor": {"ok": True},
                              "getStatusPage": {"ok": True, "config": {"icon": "x"}}}
        d = self.decls(["SearXNG|https://new|200-299,400-499",
                        "New port|tcp://p:50001"])
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        self.assertIn('updated monitor "SearXNG" (id 3)', out)
        self.assertIn('created monitor "New port" (id 11', out)
        edit = self.events("editMonitor")[0][0]
        # UI-tuned fields are carried over untouched, declared fields override,
        # and DB-string fields are decoded back to raw arrays.
        self.assertEqual(edit["notificationIDList"], {"9": True})
        self.assertEqual(edit["interval"], 300)
        self.assertEqual(edit["url"], "https://new")
        self.assertEqual(edit["accepted_statuscodes"], ["200-299", "400-499"])
        self.assertEqual(edit["conditions"], ["cond"])
        self.assertEqual(edit["kafkaProducerBrokers"], [])
        add = self.events("add")[0][0]
        self.assertEqual(add["type"], "port")
        self.assertEqual(add["hostname"], "p")
        self.assertEqual(add["port"], 50001)
        self.assertEqual(add["accepted_statuscodes"], ["200-299"])  # the .every() trap
        self.assertEqual(add["interval"], 60)
        self.assertTrue(add["active"])

        # dry-run plans the same edits but writes nothing
        self.server.events.clear()
        d = self.decls(["SearXNG|https://newer|200-299",
                        "New port|tcp://p:50001"], dry="1")
        rc, out, _ = self.reconcile(d)
        self.assertIn("[dry-run] would update monitor", out)
        self.assertEqual(self.events("add"), [])
        self.assertEqual(self.events("editMonitor"), [])

    def test_prune_and_publish(self):
        self.server.monitor_list = {
            "1": {"id": 1, "name": "Keep", "type": "http", "url": "https://k",
                  "accepted_statuscodes": ["200-299"]},
            "9": {"id": 9, "name": "Stale", "type": "http", "url": "https://s",
                  "accepted_statuscodes": ["200-299"]},
        }
        self.server.status_groups = []  # page exists but is empty -> we fill it
        self.server.script = {"login": {"ok": True}, "getStatusPage": {"ok": True, "config": {"icon": "i"}},
                              "deleteMonitor": {"ok": True}, "saveStatusPage": {"ok": True},
                              "addStatusPage": {"ok": True}}
        d = self.decls(["Keep|https://k|200-299"], prune="1")
        rc, out, _ = self.reconcile(d)
        self.assertEqual(rc, 0)
        self.assertIn('deleted monitor "Stale" (id 9, not declared)', out)
        self.assertIn("published status page 'stack' (1 monitor(s))", out)
        self.assertEqual(self.events("deleteMonitor"), [[9]])
        save = self.events("saveStatusPage")[0]
        self.assertEqual(save[0], "stack")
        self.assertEqual(save[2], "i")            # imgDataUrl stays a string
        self.assertEqual(save[3][0]["monitorList"], [{"id": 1, "weight": 1}])
        self.assertEqual(save[1]["published"], True)

    def test_bad_login_dies(self):
        self.server.script = {"login": {"ok": False, "msg": "Incorrect username or password"}}
        d = self.decls(["X|https://x"])
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(Fatal) as ctx:
                kuma.reconcile(d)
        self.assertIn("Incorrect username", ctx.exception.msg)


if __name__ == "__main__":
    unittest.main(verbosity=1)
