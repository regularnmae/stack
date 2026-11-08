# Uptime-Kuma's monitor + status-page reconciler -- the Python core of
# scripts/kuma-monitors.sh.
#
# The transport is uptime-kuma-api2 (the v2 continuation of uptime-kuma-api),
# which brings python-socketio and its websocket transport. It replaced the
# hand-rolled ws.py + socketio.py pair, and the kuma-ctl Node image before them
# -- kuma has no REST write API, its management surface is socket.io, and all
# three existed only to speak it. What the library already knows, and what the
# comments below no longer have to: it waits for kuma to register its handlers
# before anything is sent, it merges `getMonitor` into an edit (so the
# UI-tuned fields are carried, never rewritten), it knows which fields a given
# kuma version accepts, it defaults accepted_statuscodes -- the `.every()`
# trap, which fires before the handler looks at the monitor's type -- and it
# sends the raw arrays the handler stringifies.
#
# It is imported in KumaClient.__init__, NOT at module import: the stdlib-only
# `manifest` command shares this package with the reconcilers and runs on the
# bare interpreter (load_manifest, install.sh, verify.sh, CI). See
# requirements.txt and deploy/install.sh's venv step.
#
# The three rules that keep a reconcile from fighting the UI (unchanged):
#   * a monitor is only touched when a *declared* field changed (url + accepted
#     status codes, or hostname + port for a port monitor) -- the UI-tuned ones
#     (interval, retries with their drift, notifications it got attached to)
#     are never rewritten;
#   * the status page is created and filled with the declared monitors only
#     while it is empty; a page that already carries monitors belongs to the
#     UI, layout and all;
#   * --prune is the only destructive mode (mirrors scripts/npm-hosts.sh).
from __future__ import annotations

import json
import os
import re
import time
from typing import Any, Dict, List, Optional

from . import decl, envfile, manifest
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
    # Only what the declaration owns: uptime-kuma-api merges the rest of the
    # stored monitor back in (getMonitor + update), so the UI's method, body,
    # headers, interval and notifications survive an edit untouched. A port
    # monitor carries no codes, so accepted_statuscodes is left as it is.
    if m.type == "port":
        return {"type": "port", "hostname": m.hostname, "port": m.port,
                "url": f"tcp://{m.hostname}:{m.port}"}
    return {"url": m.url, "accepted_statuscodes": m.codes}


def add_fields(m: decl.KumaMonitor) -> Dict[str, Any]:
    """The whole new-monitor payload (an add has no stored state to carry).

    accepted_statuscodes is explicit even for a port monitor: kuma's `add`
    handler .every()s the array before it looks at the type, and the library's
    default would already cover it -- spelling it out keeps the trap visible
    beside the declaration that triggers it."""
    fields = {
        "name": m.name,
        **declared_fields(m),
        "interval": m.interval,
        "retryInterval": m.retry_interval,
        "maxretries": m.maxretries,
        "accepted_statuscodes": m.codes or ["200-299"],
    }
    return fields


def normalized_codes(m: Any) -> List[str]:
    # The monitor list carries accepted_statuscodes as an array (the DB's _json
    # string only exists on older payloads).
    codes = m.get("accepted_statuscodes") if isinstance(m, dict) else None
    if not (isinstance(codes, list) and codes):
        try:
            codes = json.loads(m.get("accepted_statuscodes_json") or "[]")
        except (ValueError, AttributeError, TypeError):
            codes = []
    return sorted(str(c) for c in codes) if isinstance(codes, list) else []


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


class KumaClient:
    """uptime-kuma-api2 behind the handful of calls a reconcile makes.

    One adapter, not a wrapper: every method is the library call with the same
    name, so the shapes reconcile reads (`get_monitors` -> list of the server's
    own monitor objects, `get_status_page` -> the stored config) stay the
    library's. Its two exception classes are exposed as `errors` (any of them is
    a reconcile failure) and `timeout_error` (the one worth a login retry), so
    this module needs no import of the library at load time."""

    def __init__(self, base_url: str, timeout: float = 20) -> None:
        from uptime_kuma_api import Timeout, UptimeKumaApi, UptimeKumaException

        self._api = UptimeKumaApi(base_url, timeout=timeout)
        self.errors = (Timeout, UptimeKumaException)
        self.timeout_error = Timeout

    def login(self, username: str, password: str) -> Any:
        return self._api.login(username, password)

    def monitors(self) -> List[Dict[str, Any]]:
        return self._api.get_monitors()

    def add_monitor(self, **fields: Any) -> Any:
        return self._api.add_monitor(**fields)

    def edit_monitor(self, id_: Any, **fields: Any) -> Any:
        return self._api.edit_monitor(id_, **fields)

    def delete_monitor(self, id_: Any) -> Any:
        return self._api.delete_monitor(id_)

    def status_page(self, slug: str) -> Optional[Dict[str, Any]]:
        """The page's stored config, or None when no page carries that slug.

        The library raises when the server answers ok:false, which is how kuma
        says "no such page"; a page that exists comes back as the config the
        status-page editor reads, `publicGroupList` included."""
        try:
            page = self._api.get_status_page(slug)
        except self.errors[1]:
            return None
        return page if isinstance(page, dict) else None

    def add_status_page(self, slug: str, title: str) -> Any:
        return self._api.add_status_page(slug, title)

    def save_status_page(self, slug: str, **fields: Any) -> Any:
        return self._api.save_status_page(slug, **fields)

    def close(self) -> None:
        self._api.disconnect()


def _login(api: Any, username: str, password: str) -> Any:
    # Two attempts: the library waits for kuma's handlers, but a dropped login
    # TIMES OUT instead of erroring, so a short retry is safe and cheap.
    for attempt in (1, 2):
        try:
            return api.login(username, password)
        except api.timeout_error as e:
            if attempt == 2:
                raise
            say(f"login attempt {attempt} timed out (dropped by the server); retrying")
            time.sleep(3)
    return None


def reconcile(d: decl.Decls, client_factory: Any = None) -> int:
    """Load the declarations, connect, reconcile, disconnect.

    `client_factory` exists for the offline tests: it is called with the base
    URL and must return something shaped like KumaClient."""
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

    api = (client_factory or KumaClient)(base_url)
    try:
        try:
            login = _login(api, username, password)
        except api.errors as e:
            die(f"login: {e}")
        if not isinstance(login, dict):
            die("login failed: no answer from the server")

        try:
            monitor_list = api.monitors()
            by_name: Dict[str, Dict[str, Any]] = {}
            for m in monitor_list:
                if isinstance(m, dict) and m.get("name"):
                    by_name[m["name"]] = m
            declared_names = {m.name for m in monitors}
            resolved_ids: List[Any] = []  # per declared monitor, in order; status page members

            for m in monitors:
                existing = by_name.get(m.name)
                if existing is None:
                    if dry_run:
                        say(f'[dry-run] would create monitor "{m.name}" ({m.describe()})')
                        continue
                    res = api.add_monitor(**add_fields(m))
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
                    res = api.edit_monitor(existing.get("id"), **edit_fields(m))
                    # The library raises on ok:false, so any dict answer is a
                    # success; requiring monitorID here would fail on a kuma
                    # whose edit ack omits it, and the id is one we already know.
                    if not isinstance(res, dict):
                        die(f'could not update monitor "{m.name}": no answer from the server')
                    say(f'updated monitor "{m.name}" (id {existing.get("id")})')
                else:
                    say(f'monitor "{m.name}" unchanged (id {existing.get("id")})')
                resolved_ids.append(existing.get("id"))

            if prune:
                stale = [m for m in monitor_list
                         if isinstance(m, dict) and m.get("name") not in declared_names]
                if not stale:
                    say("nothing to prune")
                for m in stale:
                    if dry_run:
                        say(f'[dry-run] would delete monitor "{m.get("name")}" (id {m.get("id")})')
                        continue
                    api.delete_monitor(m.get("id"))
                    say(f'deleted monitor "{m.get("name")}" (id {m.get("id")}, not declared)')

            if page is not None and page.slug:
                _status_page(api, page.slug, page.title, page.group,
                             resolved_ids, dry_run)
        except api.errors as e:
            die(str(e))
    finally:
        api.close()
    log("done")
    return 0


def _status_page(api: Any, slug: str, title: str, group: str,
                 resolved_ids: List[Any], dry_run: bool) -> None:
    # The status page: created + filled only while it is empty -- a page that
    # already carries monitors belongs to the UI, layout and all. Existence and
    # content both come from the authenticated getStatusPage event the library
    # exposes (kuma v2's public routes answer for any slug that exists,
    # `published` or not, so a REST probe says nothing about what the page is).
    page = api.status_page(slug)
    groups = (page or {}).get("publicGroupList") or []
    has_monitors = any(isinstance(g, dict) and g.get("monitorList") for g in groups)

    if page is not None and has_monitors:
        say(f"status page '{slug}' exists and carries monitors; the layout stays with the UI")
        return
    if dry_run:
        if page is not None:
            say(f"[dry-run] would fill the (empty) status page '{slug}' "
                f"with {len(resolved_ids)} monitor(s)")
        else:
            say(f"[dry-run] would create + publish status page '{slug}' "
                f"with {len(resolved_ids)} monitor(s)")
        return

    if page is None:
        try:
            api.add_status_page(slug, title)
            say(f"created status page '{slug}'")
        except api.errors[1] as e:
            msg = str(e)
            if not re.search(r"unique|duplicate|exist", msg, re.IGNORECASE):
                die(f"could not create status page '{slug}': {msg or 'no ok'}")
            say(f"status page '{slug}' exists (created between the check and here); continuing")

    # The save carries the declared monitor set only; the library merges the
    # page's own stored config (description, icon, theme, ...) back in.
    group_list: List[Dict[str, Any]] = []
    if resolved_ids:
        group_list = [{
            "name": group or "Public services",
            "weight": 0,
            "monitorList": [{"id": i, "weight": 1} for i in resolved_ids],
        }]
    api.save_status_page(slug, title=title, published=True, publicGroupList=group_list)
    say(f"published status page '{slug}' ({len(resolved_ids)} monitor(s))")


def main(argv: List[str]) -> int:
    return reconcile(decl.read_decls())
