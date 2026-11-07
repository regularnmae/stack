# An Engine.IO v4 / Socket.IO v4 client over ws.WebSocket -- exactly the slice
# Uptime-Kuma's management API uses: one namespace, server pushes, and
# emit-with-ack request/response. It replaces the kuma-ctl image's
# socket.io-client (Node), whose behaviour kuma-monitors.sh depended on; the
# protocol facts below are the ones that Node library was silently providing.
#
# Packet framing, condensed (the specs: socket.io protocol v5 / engine.io v4):
#   * every websocket TEXT frame carries ONE Engine.IO packet: "<type><data>"
#       0 open (handshake JSON: pingInterval/pingTimeout, ms)
#       1 close   2 ping   3 pong   4 message (a Socket.IO packet)
#     In EIO4 the SERVER pings ("2") and the CLIENT must pong ("3") within
#     pingTimeout -- the reverse of EIO3, and a client that gets it wrong is
#     disconnected silently mid-reconcile.
#   * a Socket.IO packet inside "4" is "<sio-type>[<ack-id>]<json-array>"
#       0 CONNECT ("40" -> the server answers "40{"sid":...}")
#       1 DISCONNECT   2 EVENT   3 ACK   4 CONNECT_ERROR
#     an EVENT the server wants acked carries digits between the type and the
#     "["; an ACK echoes that id: "43<id>[...]".
#   * a client EVENT that wants an ack sends its own id: "42<id>["ev",args]"
#     and the answer arrives as "43<id>[result-args]". Kuma's handlers answer
#     with ONE argument ({ok:..., msg:...} or {monitorID:...}); socket.io's
#     timeout() convention on the Node side delivered that as the callback's
#     second parameter with err=null on success -- so `emit_ack` here returns
#     the server's first ack argument, and a timeout raises TimeoutError
#     (kuma.py's login retry keys on exactly that).
#
# Threading: one reader thread owns the socket's read side and dispatches --
# pongs are answered there (they must not wait on a slow reconcile step),
# pushes are buffered on a deque, acks land in per-id slots. Everything a
# caller waits for is a Condition wait with a deadline, so a dead connection
# (no ping within pingInterval+pingTimeout) wakes every waiter with the
# reader's error instead of letting them burn their full timeout.
from __future__ import annotations

import json
import threading
import time
from collections import deque
from typing import Any, Deque, Dict, List, Optional, Tuple

from . import ws


class SocketIOError(Exception):
    """The connection failed or died."""


class SocketIOClient:
    def __init__(self, base_url: str, path: str = "/socket.io/", timeout: float = 20):
        self.base_url = base_url.rstrip("/")
        self.path = path
        self.timeout = timeout
        self._ws: Optional[ws.WebSocket] = None
        self._cond = threading.Condition()
        self._pushes: Deque[Tuple[str, List[Any]]] = deque()
        self._acks: Dict[int, List[Any]] = {}
        self._next_ack_id = 1
        self._connected = threading.Event()
        self._error: Optional[str] = None
        self._reader: Optional[threading.Thread] = None
        self._stopping = False
        self._ping_interval = 25.0  # EIO default; the open packet overrides
        self._ping_timeout = 20.0

    # --- connection ----------------------------------------------------------
    def connect(self) -> None:
        """Handshake, join the default namespace, start the reader. Raises
        SocketIOError when the server never answers the namespace CONNECT --
        the message mirrors the Node client's connect_error path."""
        scheme_swap = {"http": "ws", "https": "wss"}
        url = self.base_url
        for a, b in scheme_swap.items():
            if url.startswith(a + "://"):
                url = b + url[len(a):]
                break
        url += f"{self.path}?EIO=4&transport=websocket"
        try:
            self._ws = ws.WebSocket.connect(url, timeout=self.timeout)
        except (ws.WebSocketError, TimeoutError, OSError) as e:
            raise SocketIOError(f"connect failed: {e}") from e

        # The open packet is the first message and is read synchronously: it
        # carries the ping schedule the reader thread's watchdog needs.
        try:
            opcode, payload = self._ws.recv_message(timeout=self.timeout)
        except (ws.WebSocketError, TimeoutError, OSError) as e:
            raise SocketIOError(f"connect failed: {e}") from e
        text = payload.decode("utf-8", "replace")
        if opcode != ws.OP_TEXT or not text.startswith("0"):
            raise SocketIOError(f"connect failed: expected the Engine.IO open packet, got {text[:80]!r}")
        try:
            handshake = json.loads(text[1:])
            self._ping_interval = float(handshake.get("pingInterval", 25000)) / 1000
            self._ping_timeout = float(handshake.get("pingTimeout", 20000)) / 1000
        except ValueError:
            pass  # defaults stand; the handshake JSON is informational here

        self._ws.send_text("40")  # CONNECT, default namespace
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        if not self._connected.wait(timeout=self.timeout):
            raise SocketIOError(self._error or f"could not connect to {self.base_url}")
        if self._error:
            # _fail() sets the event to unblock this waiter -- a CONNECT_ERROR
            # or an instantly-dead connection must not read as success.
            raise SocketIOError(self._error)

    def _read_loop(self) -> None:
        assert self._ws is not None
        watchdog = self._ping_interval + self._ping_timeout + 10
        while not self._stopping:
            try:
                opcode, payload = self._ws.recv_message(timeout=watchdog)
            except TimeoutError:
                self._fail(f"the server stopped pinging (no packet in {watchdog:.0f}s)")
                return
            except (ws.WebSocketError, OSError) as e:
                self._fail(str(e))
                return
            if opcode != ws.OP_TEXT:
                continue
            try:
                self._dispatch(payload.decode("utf-8", "replace"))
            except (ValueError, ws.WebSocketError) as e:
                self._fail(f"bad packet from the server: {e}")
                return

    def _dispatch(self, text: str) -> None:
        if not text:
            return
        eio, body = text[0], text[1:]
        if eio == "2":  # server ping -> our pong, answered on the read side
            assert self._ws is not None
            self._ws.send_text("3")
            return
        if eio in ("1", "3"):  # engine close / our pong echoed: nothing to do
            if eio == "1":
                self._fail("the server closed the Engine.IO connection")
            return
        if eio != "4":
            return  # unknown engine packet: ignore rather than die
        self._dispatch_sio(body)

    def _dispatch_sio(self, body: str) -> None:
        if not body:
            return
        sio_type = body[0]
        rest = body[1:]
        ack_id: Optional[int] = None
        if sio_type in ("2", "3"):  # EVENT / ACK may carry an id before the JSON
            digits = ""
            while rest and rest[0].isdigit():
                digits += rest[0]
                rest = rest[1:]
            if digits:
                ack_id = int(digits)
        if sio_type == "0":  # CONNECT ack
            self._connected.set()
            return
        if sio_type == "4":  # CONNECT_ERROR
            try:
                msg = json.loads(rest).get("message", rest)
            except ValueError:
                msg = rest
            self._fail(f"connect failed: {msg}")
            return
        if sio_type == "1":  # DISCONNECT
            self._fail("the server disconnected the namespace")
            return
        if sio_type == "3":  # ACK for one of our emits
            try:
                args = json.loads(rest) if rest else []
            except ValueError:
                args = []
            if ack_id is not None:
                with self._cond:
                    self._acks[ack_id] = args if isinstance(args, list) else [args]
                    self._cond.notify_all()
            return
        if sio_type == "2":  # EVENT (a server push)
            try:
                data = json.loads(rest)
            except ValueError:
                return
            if not isinstance(data, list) or not data:
                return
            name, args = str(data[0]), data[1:]
            if ack_id is not None:
                # The server asked for an ack on a push (kuma never does; the
                # Node client did not answer these either) -- stay silent
                # rather than inventing a reply the handler never expects.
                pass
            with self._cond:
                self._pushes.append((name, args))
                self._cond.notify_all()

    def _fail(self, msg: str) -> None:
        with self._cond:
            if self._error is None:
                self._error = msg
            self._cond.notify_all()
        self._connected.set()  # unblock a connect() still waiting

    # --- the caller-facing waits ----------------------------------------------
    def wait_event(self, name: str, timeout: float) -> Optional[List[Any]]:
        """The next buffered push called `name`, or None on timeout/death.
        Pushes are buffered from the moment the reader starts, so an event
        that races the caller (kuma's `info`, its post-login `monitorList`)
        cannot be missed -- the failure mode the Node client needed an
        attached-first listener for."""
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                for i, (ev, args) in enumerate(self._pushes):
                    if ev == name:
                        del self._pushes[i]
                        return args
                remaining = deadline - time.monotonic()
                if remaining <= 0 or self._error:
                    return None
                self._cond.wait(remaining)

    def emit_ack(self, event: str, args: Optional[List[Any]] = None,
                 timeout: float = 60) -> Any:
        """Emit with an ack callback and return the server's first ack
        argument. TimeoutError on timeout (the message names the event, so a
        caller can pattern-match "timeout" the way the Node retry did);
        SocketIOError when the connection died."""
        if self._ws is None:
            raise SocketIOError("not connected")
        with self._cond:
            if self._error:
                raise SocketIOError(self._error)
            ack_id = self._next_ack_id
            self._next_ack_id += 1
        packet = "42%d%s" % (ack_id, json.dumps([event] + list(args or []),
                                                separators=(",", ":")))
        self._ws.send_text(packet)
        deadline = time.monotonic() + timeout
        with self._cond:
            while ack_id not in self._acks:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"{event}: timeout")
                if self._error:
                    raise SocketIOError(f"{event}: {self._error}")
                self._cond.wait(remaining)
            ack_args = self._acks.pop(ack_id)
        return ack_args[0] if ack_args else None

    @property
    def error(self) -> Optional[str]:
        with self._cond:
            return self._error

    def close(self) -> None:
        self._stopping = True
        if self._ws is not None:
            try:
                self._ws.send_text("41")  # namespace DISCONNECT
            except (ws.WebSocketError, OSError):
                pass
            self._ws.send_close()
            self._ws.shutdown()
        if self._reader is not None:
            self._reader.join(timeout=5)
