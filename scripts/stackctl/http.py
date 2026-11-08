# The one HTTP client: urllib behind a small JSON-shaped API.
#
# Replaces the two curl dialects the bash reconcilers needed -- net_curl_host
# (curl inside the netcheck-host container, because the host was not guaranteed
# a curl) and the curl-config-on-stdin dance (`-K -`), which existed only to
# keep a bearer token or a password out of an argv that `ps` can read. A Python
# process holds credentials in its own memory, so neither mechanism survives
# here; what MUST survive is the rule itself, and it is why nothing in this
# package ever shells out with a secret in argv.
#
# Both reconcilers talk to a loopback surface (nginx-proxy-manager binds :81 on
# the host network, uptime-kuma publishes 127.0.0.1:8107), so the host's own
# Python reaches them directly -- no container transport at all.
from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Optional, Tuple


class HttpError(Exception):
    """A transport-level failure (refused, timeout, DNS): status is None."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def request(
    method: str,
    url: str,
    *,
    headers: Optional[dict] = None,
    body: Optional[bytes] = None,
    timeout: float = 30,
) -> Tuple[Optional[int], dict, bytes]:
    """One HTTP exchange -> (status, headers, body). An HTTP error answer is a
    normal result (status 4xx/5xx with its body); only a transport failure
    raises HttpError -- callers decide whether "no answer" is fatal (npm's API
    probe) or an empty result (a status-page probe whose content stays
    unknown)."""
    req = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers.items()), e.read()
    except (urllib.error.URLError, OSError, ValueError) as e:
        reason = getattr(e, "reason", e)
        raise HttpError(str(reason)) from e


def json_request(
    method: str,
    url: str,
    *,
    headers: Optional[dict] = None,
    payload: Any = None,
    timeout: float = 30,
) -> Tuple[Optional[int], Any]:
    """request() with a JSON body out and a best-effort JSON answer back
    (None when the body is not JSON -- an HTML error page is data, not a
    crash)."""
    hdrs = dict(headers or {})
    body = None
    if payload is not None:
        body = json.dumps(payload).encode()
        hdrs.setdefault("Content-Type", "application/json")
    status, _, raw = request(method, url, headers=hdrs, body=body, timeout=timeout)
    try:
        return status, json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return status, None
