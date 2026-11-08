# Uptime-Kuma's monitor + status-page reconciler -- the Python core of
# scripts/kuma-monitors.sh, and a port of the kuma-ctl image's monitors.mjs
# (retired with this file: kuma has no REST write API, its management surface
# is socket.io, and the Node image existed only to bring a socket.io client).
# The transport is socketio.py over ws.py; the declarations arrive over stdin
# (decl.py) exactly as the bash wrapper validated and normalized them before.
#
# The three rules that keep a reconcile from fighting the UI (from the mjs):
#   * a monitor is only touched when a *declared* field changed (url + accepted
#     status codes, or hostname + port for a port monitor) -- the UI-tuned ones
#     (interval, retries with their drift, notifications it got attached to)
#     are never rewritten;
#   * the status page is created and filled with the declared monitors only
#     while it is empty; a page that already carries monitors belongs to the
#     UI, layout and all;
#   * --prune is the only destructive mode (mirrors scripts/npm-hosts.sh).
#
# Protocol traps, all verified against kuma 2.5.x by the mjs and carried over:
#   * handler ARITY is positional: login({username,password}); add(monitor);
#     editMonitor(monitor); deleteMonitor(id); getStatusPage(slug);
#     addStatusPage(title, slug) -- ONE object instead of two args lands in
#     `title` and puts the ack callback into `slug`'s slot, the handler throws
#     server-side, and the client waits out its full timeout;
#     saveStatusPage(slug, config, imgDataUrl, publicGroupList), where
#     imgDataUrl must be a STRING (the handler calls .startsWith() on it);
#   * kuma registers its socket handlers only after an `await sendInfo()`, so
#     a login emitted the instant the connection opens can be dropped -- wait
#     for the server's `info` push first (socketio.py buffers pushes, so the
#     race the mjs solved by attaching its listener early cannot recur), and
#     retry a timed-out login once;
#   * the `add` handler .every()s accepted_statuscodes BEFORE it looks at the
#     monitor's type, so a port monitor missing that array crashes the handler
#     server-side: ["200-299"] (what kuma's own form submits for a port
#     monitor) is sent either way. conditions, kafkaProducerBrokers,
#     kafkaProducerSaslOptions and rabbitmqNodes are JSON.stringified by the
#     handler directly, so they must arrive as raw arrays -- a string in means
#     a double-encoded string in the database.
from __future__ import annotations

import json
import os
import re
import time
from typing import Any, Dict, List, Optional

from . import decl, envfile, http, manifest, socketio
from .ui import die, log


def say(msg: str) -> None:
    """A reconcile-status line, bare on stdout -- exactly what the retired
    monitors.mjs printed with console.log. The "==> "-prefixed log() lines are
    this module's bookends (and the wrapper's die/usage paths)."""
    print(msg, flush=True)

# A monitor is only touched when a *declared* field changed; interval and
# retries belong to the UI once the monitor exists.
def declared_fields(m: decl.KumaMonitor) -> Dict[str, Any]:
    if m.type == "port":
        return {
            "type": "port",
            "hostname": m.hostname,
            "port": m.port,
            # url on a port monitor is inert (kuma's form keeps "https://" in
            # it); it is written as the tcp:// target so an operator reading
            # the database sees what it checks.
            "url": f"tcp://{m.hostname}:{m.port}",
        }
    return {"type": "http", "method": "GET", "url": m.url,
            "accepted_statuscodes": m.codes}


def edit_fields(m: decl.KumaMonitor) -> Dict[str, Any]:
    # For an edit the UI-tuned monitor is carried over: only what the
    # declaration owns is overridden, so an http monitor's method, body and
    # headers stay whatever the UI set. A port monitor carries no codes, so
    # accepted_statuscodes is left exactly as the list push had it.
    if m.type == "port":
        return {"type": "port", "hostname": m.hostname, "port": m.port,
                "url": f"tcp://{m.hostname}:{m.port}"}
    return {"url": m.url, "accepted_statuscodes": m.codes}


def normalized_codes(m: Any) -> List[str]:
    # The list push carries accepted_statuscodes as an array (the DB's _json
    # string only exists on older payloads).
    codes = m.get("accepted_statuscodes") if isinstance(m, dict) else None
    if not (isinstance(codes, list) and codes):
        try:
            codes = json.loads(m.get("accepted_statuscodes_json") or "[]")
        except (ValueError, AttributeError, TypeError):
            codes = []
    return sorted(str(c) for c in codes) if isinstance(codes, list) else []


def raw_array(val: Any) -> List[Any]:
    """Decode a DB JSON string into the raw array the server-side handlers
    stringify back; arrays pass through, anything unrecoverable becomes []."""
    if isinstance(val, list):
        return val
    if isinstance(val, str):
        try:
            parsed = json.loads(val)
            return parsed if isinstance(parsed, list) else []
        except ValueError:
            return []
    return []


def differs(existing: Dict[str, Any], m: decl.KumaMonitor) -> bool:
    if (existing.get("type") or "http") != m.type:
        return True
    if m.type == "port":
        try:
            existing_port = int(existing.get("port"))
        except (TypeError, ValueError):
            existing_port = None
        return existing.get("hostname") != m.hostname or existing_port != m.port
    return (existing.get("url") or "") != m.url \
        or normalized_codes(existing) != sorted(m.codes)


def _login(client: socketio.SocketIOClient, username: str, password: str) -> Any:
    # Two attempts: the info-wait in reconcile() is the primary defense
    # against the dropped-login race, but a future kuma moving its `await`
    # could drop a login again. A dropped login TIMES OUT instead of erroring,
    # so a short retry is safe and cheap.
    for attempt in (1, 2):
        try:
            return client.emit_ack("login", [{"username": username, "password": password}],
                                   timeout=20)
        except TimeoutError:
            if attempt == 2:
                raise
            say(f"login attempt {attempt} timed out (dropped by the server); retrying")
            time.sleep(3)
    return None


def reconcile(d: decl.Decls) -> int:
    # The declarations come from the service manifest, not the stdin pipe:
    # deploy/services.toml is the one home of the monitors and the page
    # (manifest.py loads and validates), and it also names kuma's loopback
    # publish, which is the default URL below.
    manifest_path = d.var("MANIFEST")
    if not manifest_path:
        die("the wrapper did not pass MANIFEST (the path to deploy/services.toml)")
    mf = manifest.load(manifest_path)

    config_dir = d.var("CONFIG_DIR")
    dry_run = d.flag("DRY_RUN")
    prune = d.flag("PRUNE")
    kuma_env = os.path.join(config_dir, "uptime-kuma", "api.env")

    username = envfile.env_or_file("KUMA_USERNAME", kuma_env)
    password = envfile.env_or_file("KUMA_PASSWORD", kuma_env)
    if not username or not password:
        # A fresh host deploys before the UI-first registration exists: this
        # is a self-skip, not an error (deploy.sh only warns on it).
        log(f"no Uptime-Kuma admin login in {kuma_env}")
        log("fill in KUMA_USERNAME/KUMA_PASSWORD (the login the setup wizard asked for), then re-run")
        return 0

    monitors = mf.kuma_monitors
    if not monitors:
        die(f"no monitors are declared in {manifest_path}")

    page = mf.kuma_page
    base_url = d.var("KUMA_URL") or f"http://127.0.0.1:{mf.kuma_loopback}"
    if page is None or not page.slug:
        log("KUMA_STATUS_SLUG is empty; only the monitors will be reconciled")
        log(f"reconciling {len(monitors)} monitor(s)")
    else:
        log(f"reconciling {len(monitors)} monitor(s) + status page '{page.slug}'")

    client = socketio.SocketIOClient(base_url, timeout=20)
    try:
        try:
            client.connect()
        except socketio.SocketIOError as e:
            die(str(e))

        # The server's `info` push is the proof that kuma finished registering
        # its socket handlers; sending anything before it risks a dropped
        # event (see the module header).
        if client.wait_event("info", 20) is None:
            die(client.error or
                "the server never sent its `info` event (kuma did not finish "
                "registering its handlers); is this uptime-kuma v2?")

        try:
            login = _login(client, username, password)
        except (TimeoutError, socketio.SocketIOError) as e:
            die(f"login: {e}")
        if not (isinstance(login, dict) and login.get("ok")):
            msg = login.get("msg") if isinstance(login, dict) else None
            die(f"login failed: {msg or 'no answer from the server'}")

        # The `monitorList` push lands once after login; wait up to 15s. An
        # *empty* list still counts as arrived -- a fresh instance has no
        # monitors, and the server will never push another one.
        pushed = client.wait_event("monitorList", 15)
        monitor_list: Dict[str, Any] = pushed[0] if pushed and isinstance(pushed[0], dict) else {}

        by_name: Dict[str, Dict[str, Any]] = {}
        for m in monitor_list.values():
            if isinstance(m, dict) and m.get("name"):
                by_name[m["name"]] = m
        declared_names = {m.name for m in monitors}
        resolved_ids: List[Any] = []  # per declared monitor, in order; status page members

        try:
            for m in monitors:
                existing = by_name.get(m.name)
                if existing is None:
                    if dry_run:
                        say(f'[dry-run] would create monitor "{m.name}" ({m.describe()})')
                        continue
                    res = client.emit_ack("add", [{
                        "name": m.name,
                        **declared_fields(m),
                        "interval": m.interval,
                        "retryInterval": m.retry_interval,
                        "maxretries": m.maxretries,
                        "resendInterval": 0,
                        # A port monitor has no codes to accept by definition;
                        # ["200-299"] is what kuma's own form submits for it,
                        # and the handler .every()s the array before it looks
                        # at the type at all (module header).
                        "accepted_statuscodes": m.codes or ["200-299"],
                        "notificationIDList": {},
                        "conditions": [],
                        "kafkaProducerBrokers": [],
                        "kafkaProducerSaslOptions": [],
                        "rabbitmqNodes": [],
                        "active": True,
                    }])
                    if not (isinstance(res, dict) and res.get("monitorID")):
                        msg = res.get("msg") if isinstance(res, dict) else None
                        die(f'could not create monitor "{m.name}": {msg or "no monitorID"}')
                    say(f'created monitor "{m.name}" (id {res["monitorID"]}, {m.describe()})')
                    resolved_ids.append(res["monitorID"])
                    continue

                if differs(existing, m):
                    if dry_run:
                        say(f'[dry-run] would update monitor "{m.name}" (id {existing.get("id")})')
                        continue
                    # Carry what exists, override the declared fields: the
                    # UI's settings (interval, notifications, ...) survive
                    # untouched. The list push's object is already in the
                    # shape the edit handler reads -- only anything that still
                    # arrives as a DB string has to be decoded (raw_array).
                    carry = {k: v for k, v in existing.items()
                             if k != "accepted_statuscodes_json"}
                    payload = {
                        **carry,
                        **edit_fields(m),
                        "conditions": raw_array(carry.get("conditions")),
                        "kafkaProducerBrokers": raw_array(carry.get("kafkaProducerBrokers")),
                        "kafkaProducerSaslOptions": raw_array(carry.get("kafkaProducerSaslOptions")),
                        "rabbitmqNodes": raw_array(carry.get("rabbitmqNodes")),
                    }
                    res = client.emit_ack("editMonitor", [payload])
                    if not (isinstance(res, dict) and res.get("ok")):
                        msg = res.get("msg") if isinstance(res, dict) else None
                        die(f'could not update monitor "{m.name}": {msg or "no ok"}')
                    say(f'updated monitor "{m.name}" (id {existing.get("id")})')
                else:
                    say(f'monitor "{m.name}" unchanged (id {existing.get("id")})')
                resolved_ids.append(existing.get("id"))

            if prune:
                stale = [m for m in monitor_list.values()
                         if isinstance(m, dict) and m.get("name") not in declared_names]
                if not stale:
                    say("nothing to prune")
                for m in stale:
                    if dry_run:
                        say(f'[dry-run] would delete monitor "{m.get("name")}" (id {m.get("id")})')
                        continue
                    res = client.emit_ack("deleteMonitor", [m.get("id")])
                    if not (isinstance(res, dict) and res.get("ok")):
                        msg = res.get("msg") if isinstance(res, dict) else None
                        die(f'could not delete monitor "{m.get("name")}" (id {m.get("id")}): '
                            f'{msg or "no ok"}')
                    say(f'deleted monitor "{m.get("name")}" (id {m.get("id")}, not declared)')

            if page is not None and page.slug:
                _status_page(client, base_url, page.slug, page.title, page.group,
                             resolved_ids, dry_run)
        except (TimeoutError, socketio.SocketIOError) as e:
            die(str(e))
    finally:
        client.close()
    log("done")
    return 0


def _status_page(client: socketio.SocketIOClient, base_url: str, slug: str,
                 title: str, group: str, resolved_ids: List[Any],
                 dry_run: bool) -> None:
    # The status page: created + filled only while it is empty -- a page that
    # already carries monitors belongs to the UI, layout and all. Existence is
    # checked through the authenticated `getStatusPage` event: kuma v2's public
    # routes answer for any slug that exists, `published` or not, so a REST
    # probe says nothing about what the page is.
    page = client.emit_ack("getStatusPage", [slug], timeout=30)
    page_exists = isinstance(page, dict) and page.get("ok") is True

    # What a visitor would see, straight from the public data endpoint; the
    # reconcile only fills a page with *nothing* on it, so unknown content
    # counts as content (leave it alone).
    has_monitors = False
    content_known = False
    if page_exists and not dry_run:
        try:
            status, body = http.json_request(
                "GET", f"{base_url.rstrip('/')}/api/status-page/{slug}", timeout=15)
        except http.HttpError:
            status, body = None, None
        if status is not None and 200 <= status < 300 and isinstance(body, dict):
            groups = body.get("publicGroupList") or []
            public_monitors = sum(len(g.get("monitorList") or [])
                                  for g in groups if isinstance(g, dict))
            has_monitors = public_monitors > 0
            content_known = True

    if page_exists and (not content_known or has_monitors):
        say(f"status page '{slug}' exists and carries monitors; the layout stays with the UI")
    elif dry_run:
        if page_exists:
            say(f"[dry-run] would fill the (empty) status page '{slug}' "
                f"with {len(resolved_ids)} monitor(s)")
        else:
            say(f"[dry-run] would create + publish status page '{slug}' "
                f"with {len(resolved_ids)} monitor(s)")
    else:
        if not page_exists:
            # TWO positional args -- see the arity trap in the module header.
            created = client.emit_ack("addStatusPage", [title, slug], timeout=30)
            ok = isinstance(created, dict) and created.get("ok")
            msg = str(created.get("msg", "")) if isinstance(created, dict) else ""
            if not ok and not re.search(r"unique|duplicate|exist", msg, re.IGNORECASE):
                die(f"could not create status page '{slug}': {msg or 'no ok'}")
            if ok:
                say(f"created status page '{slug}'")
            else:
                say(f"status page '{slug}' exists (created between the check and here); continuing")
        # The save payload: start from what the server stored (a fresh page's
        # defaults are its own), override only title + description, and keep
        # its icon. imgDataUrl must be a string -- the handler calls
        # .startsWith() on it and None throws.
        page = client.emit_ack("getStatusPage", [slug], timeout=30)
        cfg_stored = (page or {}).get("config") if isinstance(page, dict) else None
        cfg: Dict[str, Any] = dict(cfg_stored or {})
        cfg.update({
            "description": (cfg_stored or {}).get("description", ""),
            "title": title,
            "slug": slug,
            "published": True,
        })
        group_list: List[Dict[str, Any]] = []
        if resolved_ids:
            group_list = [{
                "name": group or "Public services",
                "weight": 0,
                "monitorList": [{"id": i, "weight": 1} for i in resolved_ids],
            }]
        icon = str((cfg_stored or {}).get("icon") or "")
        saved = client.emit_ack("saveStatusPage", [slug, cfg, icon, group_list], timeout=30)
        if not (isinstance(saved, dict) and saved.get("ok")):
            msg = saved.get("msg") if isinstance(saved, dict) else None
            die(f"could not publish status page '{slug}': {msg or 'no ok'}")
        say(f"published status page '{slug}' ({len(resolved_ids)} monitor(s))")


def main(argv: List[str]) -> int:
    return reconcile(decl.read_decls())
