# A minimal RFC 6455 WebSocket CLIENT -- the transport under socketio.py, and
# the reason the kuma-ctl Node image could be retired: Uptime-Kuma has no REST
# write API, its management surface is socket.io, and the stack's only other
# socket.io client was a pinned node+socket.io-client image built, labelled,
# Renovate-watched and `podman run` per reconcile. The protocol surface kuma
# needs is small (masked text frames both ways, ping/pong, close), so the
# stdlib covers it: http.client performs the handshake, and the framing below
# is ~150 lines with no dependencies.
#
# Two pieces, deliberately split:
#   * the codec (encode_frame / FrameDecoder) is pure bytes-in/bytes-out, so
#     tests drive fragmentation, 7/16/64-bit lengths and control-frame
#     interleaving from fixtures with no socket at all;
#   * WebSocket is the I/O shell around it.
#
# Client-side rules the codec must not get wrong: every frame a client sends
# is MASKED (a server MUST close the connection on an unmasked client frame),
# every frame a server sends is NOT (and a masked server frame is itself a
# protocol error worth refusing), control frames are never fragmented and
# never exceed 125 bytes, and continuation frames reassemble into the opcode
# of the frame that started the message -- kuma's monitorList push is tens of
# kilobytes and arrives fragmented.
from __future__ import annotations

import base64
import hashlib
import os
import socket
import ssl
import struct
import threading
import urllib.parse
from typing import Iterator, List, Optional, Tuple

OP_CONT = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

_CLOSE_CODES = {OP_CLOSE, OP_PING, OP_PONG}


class WebSocketError(Exception):
    """A protocol violation or a closed connection."""


def encode_frame(opcode: int, payload: bytes, mask_key: Optional[bytes] = None) -> bytes:
    """One frame. mask_key set -> a masked (client) frame; None -> an unmasked
    (server-style) frame, which is what the tests feed FrameDecoder."""
    if opcode in _CLOSE_CODES and len(payload) > 125:
        raise WebSocketError("control frame over 125 bytes")
    head = bytearray()
    head.append(0x80 | opcode)  # FIN + opcode
    length = len(payload)
    mask_bit = 0x80 if mask_key else 0x00
    if length < 126:
        head.append(mask_bit | length)
    elif length < 65536:
        head.append(mask_bit | 126)
        head += struct.pack(">H", length)
    else:
        head.append(mask_bit | 127)
        head += struct.pack(">Q", length)
    if mask_key:
        head += mask_key
        masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
        return bytes(head) + masked
    return bytes(head) + payload


class FrameDecoder:
    """Feed bytes, get complete messages. Handles fragmentation (continuation
    frames reassemble under the first frame's opcode), interleaved control
    frames (yielded immediately, mid-fragment), and both extended-length
    forms. A protocol violation raises WebSocketError; a close frame is
    yielded as (OP_CLOSE, payload) and the decoder refuses further input."""

    def __init__(self) -> None:
        self._buf = bytearray()
        self._frag_opcode: Optional[int] = None
        self._frag = bytearray()
        self._closed = False

    def feed(self, data: bytes) -> Iterator[Tuple[int, bytes]]:
        if self._closed:
            raise WebSocketError("data after close")
        self._buf += data
        while True:
            frame = self._take_frame()
            if frame is None:
                return
            fin, opcode, payload = frame
            if opcode in _CLOSE_CODES:
                if not fin:
                    raise WebSocketError("fragmented control frame")
                if opcode == OP_CLOSE:
                    self._closed = True
                yield opcode, payload
                if opcode == OP_CLOSE:
                    return
                continue
            if opcode == OP_CONT:
                if self._frag_opcode is None:
                    raise WebSocketError("continuation without a start frame")
            else:
                if self._frag_opcode is not None:
                    raise WebSocketError("new data frame mid-fragment")
                self._frag_opcode = opcode
                self._frag = bytearray()
            self._frag += payload
            if fin:
                done_opcode, done = self._frag_opcode, bytes(self._frag)
                self._frag_opcode, self._frag = None, bytearray()
                yield done_opcode, done

    def _take_frame(self) -> Optional[Tuple[bool, int, bytes]]:
        """The next whole frame from the buffer, or None when incomplete."""
        buf = self._buf
        if len(buf) < 2:
            return None
        fin = bool(buf[0] & 0x80)
        opcode = buf[0] & 0x0F
        rsv = buf[0] & 0x70
        if rsv:
            raise WebSocketError("reserved bits set")
        masked = bool(buf[1] & 0x80)
        if masked:
            raise WebSocketError("server sent a masked frame")
        length = buf[1] & 0x7F
        pos = 2
        if length == 126:
            if len(buf) < pos + 2:
                return None
            length = struct.unpack(">H", buf[pos:pos + 2])[0]
            pos += 2
        elif length == 127:
            if len(buf) < pos + 8:
                return None
            length = struct.unpack(">Q", buf[pos:pos + 8])[0]
            pos += 8
        if len(buf) < pos + length:
            return None
        payload = bytes(buf[pos:pos + length])
        del self._buf[:pos + length]
        return fin, opcode, payload


class WebSocket:
    """A connected WebSocket. Text only (socket.io's websocket transport
    sends text frames); recv_message auto-answers pings and raises
    WebSocketError on a close frame, after echoing the close.

    The handshake is done on the raw socket, NOT via http.client: a 101
    response hands the connection over to a different protocol, and
    HTTPResponse's buffered reader is closed (Python 3.12) or positioned
    unpredictably with respect to the first frames -- reading the status line
    and headers byte-wise from the socket keeps whatever the server pipelined
    after them in our own buffer, where the frame decoder picks it up."""

    _GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self, sock: socket.socket, decoder: FrameDecoder, pending: List[Tuple[int, bytes]]):
        self._sock = sock
        self._decoder = decoder
        self._pending: List[Tuple[int, bytes]] = pending
        self._send_lock = threading.Lock()
        self._eof = False

    @classmethod
    def connect(cls, url: str, timeout: float = 20,
                extra_headers: Optional[dict] = None) -> "WebSocket":
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("ws", "wss", "http", "https"):
            raise WebSocketError(f"not a websocket URL: {url}")
        secure = parts.scheme in ("wss", "https")
        default_port = 443 if secure else 80
        host = parts.hostname or ""
        port = parts.port or default_port
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query

        sock = socket.create_connection((host, port), timeout=timeout)
        try:
            if secure:
                ctx = ssl.create_default_context()
                sock = ctx.wrap_socket(sock, server_hostname=host)
            key = base64.b64encode(os.urandom(16)).decode()
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
            )
            for k, v in (extra_headers or {}).items():
                request += f"{k}: {v}\r\n"
            request += "\r\n"
            sock.sendall(request.encode())

            # Read the response head (up to the empty line) byte-buffer-wise;
            # anything after it is already frame data.
            buf = bytearray()
            while b"\r\n\r\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    raise WebSocketError("connection closed during the handshake")
                buf += chunk
            head, _, rest = bytes(buf).partition(b"\r\n\r\n")
            lines = head.split(b"\r\n")
            status_parts = lines[0].decode("iso-8859-1").split(" ", 2)
            if len(status_parts) < 2 or status_parts[1] != "101":
                raise WebSocketError(
                    f"websocket handshake got HTTP {status_parts[1] if len(status_parts) > 1 else '?'}, want 101")
            headers = {}
            for line in lines[1:]:
                k, _, v = line.decode("iso-8859-1").partition(":")
                headers[k.strip().lower()] = v.strip()
            expect = base64.b64encode(
                hashlib.sha1(key.encode() + cls._GUID).digest()).decode()
            if headers.get("sec-websocket-accept") != expect:
                raise WebSocketError("websocket handshake: bad Sec-WebSocket-Accept")

            decoder = FrameDecoder()
            pending: List[Tuple[int, bytes]] = []
            sock.settimeout(timeout)
            ws = cls(sock, decoder, pending)
            if rest:
                pending.extend(decoder.feed(rest))
            return ws
        except BaseException:
            try:
                sock.close()
            except OSError:
                pass
            raise

    def send_text(self, text: str) -> None:
        payload = text.encode("utf-8")
        frame = encode_frame(OP_TEXT, payload, mask_key=os.urandom(4))
        with self._send_lock:
            self._sock.sendall(frame)

    def send_close(self, code: int = 1000) -> None:
        try:
            frame = encode_frame(OP_CLOSE, struct.pack(">H", code), mask_key=os.urandom(4))
            with self._send_lock:
                self._sock.sendall(frame)
        except OSError:
            pass

    def recv_message(self, timeout: Optional[float] = None) -> Tuple[int, bytes]:
        """The next data message (OP_TEXT/OP_BINARY). Pings are answered with
        a pong transparently; pongs are swallowed; a close frame echoes the
        close and raises WebSocketError. TimeoutError on deadline."""
        while True:
            while self._pending:
                opcode, payload = self._pending.pop(0)
                if opcode == OP_PING:
                    self._send_pong(payload)
                    continue
                if opcode == OP_PONG:
                    continue
                if opcode == OP_CLOSE:
                    self.send_close()
                    self.shutdown()
                    code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
                    raise WebSocketError(f"server closed the websocket"
                                         + (f" (code {code})" if code else ""))
                return opcode, payload
            if self._eof:
                raise WebSocketError("connection closed")
            self._pump(timeout)

    def _send_pong(self, payload: bytes) -> None:
        try:
            frame = encode_frame(OP_PONG, payload, mask_key=os.urandom(4))
            with self._send_lock:
                self._sock.sendall(frame)
        except OSError:
            pass

    def _pump(self, timeout: Optional[float]) -> None:
        if timeout is not None:
            self._sock.settimeout(timeout)
        try:
            chunk = self._sock.recv(65536)
        except (socket.timeout, TimeoutError):
            raise TimeoutError("websocket read timed out") from None
        except OSError as e:
            raise WebSocketError(f"websocket read failed: {e}") from e
        if not chunk:
            self._eof = True
            return
        self._pending.extend(self._decoder.feed(chunk))

    def shutdown(self) -> None:
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass
