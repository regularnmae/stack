# nginx-proxy-manager's proxy-host reconciler -- the Python core of
# scripts/npm-hosts.sh (which keeps the CLI, sources stack.conf and passes its
# facts in the environment; deploy/services.toml is the declaration).
#
# Ported behaviour-for-behaviour from the bash original, including its output
# lines and exit semantics, so `--dry-run` output is diffable against the old
# script's and deploy.sh's callers see no change. The pieces whose reasoning
# must not get lost:
#
#   * NPM runs on the HOST network and its admin API is 127.0.0.1:81 there, so
#     the host's own Python reaches it directly. The bash version ran curl in a
#     container because the host was not then guaranteed one; bootstrap installs
#     curl now, and urllib removes the transport entirely -- not the network
#     fact.
#   * The API probe before any credential is used, so "NPM is not answering"
#     never reads as "your password is wrong" -- and its die message carries
#     the parked-configs rescue, because the failure it guards against is
#     specific (NPM's nginx resolves every saved upstream at start; on the host
#     network a container name no longer resolves and nginx refuses to come up,
#     admin UI included).
#   * A `.onion` gets no certificate and never force-ssl: tor already encrypts
#     and authenticates the hidden service and Let's Encrypt cannot issue for
#     an onion. Skipping ensure_cert there also keeps the reconciler from
#     burning a Let's Encrypt attempt on every run.
#   * Rate limiting is per ingress (docs/proxy.md): clearweb per-IP, the onion
#     zone GLOBAL (every .onion visitor is the host's own address), and the MCP
#     edge gets limit_conn only -- a request rate there either does nothing or
#     cuts healthy SSE clients; the bearer token is the real control.
#   * HSTS rides with force-ssl and is NPM's own hsts_enabled field, not an
#     add_header in advanced_config: NPM's location / defines its own
#     add_header, which would suppress a server-scope one (build_payload).
#   * --prune is the only destructive mode.
from __future__ import annotations

import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

from . import envfile, http, manifest
from .ui import die, log, warn

# Streaming settings for the MCP host, applied at server scope so every
# location inherits them. Buffering is off for SSE; `Connection` is cleared for
# the paths NPM's per-location proxy.conf does not already set it on.
ADVANCED_MCP = (
    'proxy_buffering off;\n'
    'proxy_cache off;\n'
    'gzip off;\n'
    'proxy_read_timeout 3600s;\n'
    'proxy_send_timeout 3600s;\n'
    'proxy_http_version 1.1;\n'
    'proxy_set_header Connection "";\n'
    'chunked_transfer_encoding on;'
)


class NpmApi:
    """The admin API: one login, then bearer calls. The bearer never reaches an
    argv (http.py's header) -- the property the bash version's curl-config-on-
    stdin dance existed for."""

    def __init__(self, base: str, token: str = ""):
        self.base = base.rstrip("/")
        self.token = token

    def login(self, email: str, password: str, env_path: str) -> None:
        # The admin password goes in the POST body; a short-lived NPM token
        # comes back. Both credential paths (login, stored token) end at
        # self.token.
        try:
            status, body = http.json_request(
                "POST", f"{self.base}/api/tokens",
                payload={"identity": email, "secret": password}, timeout=60)
        except http.HttpError:
            status, body = None, None
        token = (body or {}).get("token") if isinstance(body, dict) else None
        if not token:
            die(f"could not get a token from {self.base}/api/tokens "
                f"(check NPM_EMAIL/NPM_PASSWORD in {env_path})")
        self.token = token

    def call(self, method: str, path: str, payload: Any = None) -> Any:
        """One admin API call. Returns the parsed body (None when unparseable);
        never raises on an HTTP error answer -- callers check what came back,
        exactly like the bash npm_call did."""
        headers = {"Authorization": f"Bearer {self.token}"}
        try:
            _, body = http.json_request(method, f"{self.base}{path}",
                                        headers=headers, payload=payload, timeout=120)
        except http.HttpError:
            return None
        return body

    def raw_call(self, method: str, path: str, payload: Any = None) -> Tuple[Optional[Any], Optional[str]]:
        """(parsed-body-or-None, raw-text) for the calls whose failure message
        shows the server's own first 400 bytes. A transport failure is
        (None, None); an HTTP error answer is a normal result -- its body is
        data the caller reads."""
        hdrs = {"Authorization": f"Bearer {self.token}"}
        body_bytes = None
        if payload is not None:
            body_bytes = json.dumps(payload).encode()
            hdrs["Content-Type"] = "application/json"
        try:
            _, _, raw = http.request(method, f"{self.base}{path}",
                                     headers=hdrs, body=body_bytes, timeout=120)
        except http.HttpError:
            return None, None
        text = raw.decode("utf-8", "replace")
        try:
            return json.loads(text), text
        except ValueError:
            return None, text


def mcp_locations(mcp_hosts: List[manifest.McpHost]) -> List[Dict[str, Any]]:
    """One location per [mcp.*] entry, each rewritten onto that container's
    /mcp. Three fields per entry: the container name is kept for the credential
    path (the endpoint list names its token.env), but NPM forwards to the
    loopback publish -- it is on the host network and cannot resolve a
    container name."""
    locations = []
    for m in mcp_hosts:
        locations.append({
            "path": m.prefix,
            "forward_scheme": "http",
            "forward_host": "127.0.0.1",
            "forward_port": m.port,
            "forward_path": "/mcp",
            "access_list_id": 0,
        })
    return locations


def build_payload(domain: str, scheme: str, host: str, port: str, cert_id: int,
                  flags: str, advanced: str, locations: List[dict]) -> Dict[str, Any]:
    """The proxy-host body, field order included: the bash printf template and
    this dict serialize byte-identically, which is what makes a golden diff of
    the two implementations' --dry-run output a real check."""
    def has(flag: str) -> bool:
        return f",{flag}," in f",{flags},"

    # HSTS is NPM's own field, not a server-scope add_header in advanced_config:
    # NPM's location / includes conf.d/include/proxy.conf, which sets
    # add_header X-Served-By, and nginx does not inherit a server-level
    # add_header into a location that defines one. NPM includes _hsts.conf at
    # both scopes and suppresses it unless a certificate is attached and
    # ssl_forced is true; `flags` here is already the effective set.
    force_ssl = has("force-ssl")
    return {
        "domain_names": [domain],
        "forward_scheme": scheme,
        "forward_host": host,
        "forward_port": int(port),
        "certificate_id": cert_id,
        "ssl_forced": force_ssl,
        "hsts_enabled": force_ssl,
        "hsts_subdomains": False,
        "http2_support": has("http2"),
        "block_exploits": has("block"),
        "caching_enabled": False,
        "allow_websocket_upgrade": has("ws"),
        "access_list_id": 0,
        "enabled": True,
        "advanced_config": advanced,
        "locations": locations,
    }


def rate_limits(host: manifest.NpmHost) -> str:
    """The zone a vhost gets pointed at. The zones themselves are declared in
    $DATA_DIR/npm/data/nginx/custom/http.conf (deploy/npm/http.conf, seeded by
    install.sh); this is where one is attached to a host, because which applies
    depends on what the vhost is."""
    if host.domain.endswith(".onion"):
        # Ingress first: the onion host also carries the MCP locations, and an
        # mcp-flag branch that overwrote this would silently drop the only
        # brake the onion side has.
        return "limit_req zone=stack_onion burst=120 nodelay;"
    if host.has_flag("mcp"):
        return "limit_conn stack_conn 200;"
    return "limit_req zone=stack_ip burst=60 nodelay;\nlimit_conn stack_conn 40;"


def ensure_cert(api: NpmApi, domain: str, request_cert: bool, dry_run: bool) -> int:
    """Reuses the newest Let's Encrypt certificate that already covers DOMAIN,
    else requests one (a no-op when NPM_REQUEST_CERT=0). Returns the cert id,
    or 0 when the host should be served without TLS."""
    certs = api.call("GET", "/api/nginx/certificates") or []
    covering = [c for c in certs
                if isinstance(c, dict)
                and c.get("provider") == "letsencrypt"
                and domain in (c.get("domain_names") or [])]
    if covering:
        return max(c["id"] for c in covering)
    if not request_cert:
        return 0
    if dry_run:
        log(f"[dry-run] would request a Let's Encrypt certificate for {domain}", err=True)
        return 0
    log(f"requesting a Let's Encrypt certificate for {domain} "
        "(needs its DNS and :80 to reach this host)", err=True)
    resp, raw = api.raw_call("POST", "/api/nginx/certificates", {
        "provider": "letsencrypt",
        "nice_name": domain,
        "domain_names": [domain],
        "meta": {"dns_challenge": False},
    })
    cert_id = (resp or {}).get("id") if isinstance(resp, dict) else None
    if not cert_id:
        warn(f"Let's Encrypt did not issue a certificate for {domain}; "
             "that host will be plain HTTP")
        for line in (raw or "").splitlines():
            print(f"  | {line}", file=sys.stderr, flush=True)
        return 0
    return int(cert_id)


def find_host_id(hosts: Any, domain: str) -> Optional[int]:
    """The id of the first proxy host already serving one of the domain's
    names, or None -- "update in place" versus "create"."""
    if not isinstance(hosts, list):
        return None
    for h in hosts:
        if isinstance(h, dict) and domain in (h.get("domain_names") or []):
            return h.get("id")
    return None


def reconcile() -> int:
    # deploy/services.toml is the one home of the proxy hosts, the MCP
    # prefixes and the onion services (manifest.py loads and validates). The
    # wrapper passes its paths and flags in the environment.
    manifest_path = os.environ.get("MANIFEST", "")
    if not manifest_path:
        die("the wrapper did not pass MANIFEST (the path to deploy/services.toml)")
    mf = manifest.load(manifest_path)

    api_base = os.environ.get("NPM_API", "http://127.0.0.1:81")
    data_dir = os.environ.get("DATA_DIR", "")
    config_dir = os.environ.get("CONFIG_DIR") or os.path.join(data_dir, "config")
    dry_run = os.environ.get("DRY_RUN") == "1"
    prune = os.environ.get("PRUNE") == "1"
    npm_env = os.path.join(config_dir, "npm", "api.env")

    email = envfile.env_or_file("NPM_EMAIL", npm_env)
    password = envfile.env_or_file("NPM_PASSWORD", npm_env)
    token = envfile.env_or_file("NPM_TOKEN", npm_env)
    request_cert = envfile.env_or_file("NPM_REQUEST_CERT", npm_env, "1") == "1"

    if not mf.npm:
        die(f"no proxy hosts are declared in {manifest_path}")

    if not token and not (email and password):
        log(f"no nginx-proxy-manager API credentials in {npm_env}")
        log("fill in NPM_EMAIL/NPM_PASSWORD (the admin login) or NPM_TOKEN, then re-run")
        return 0

    api = NpmApi(api_base, token)

    # One request at the API root, before any credential is used, so "NPM is
    # not answering" never reads as "your password is wrong".
    try:
        status, _, _ = http.request("GET", f"{api_base}/", timeout=15)
        answered = status is not None
    except http.HttpError:
        answered = False
    if not answered:
        die(f"no answer from {api_base}. If nginx-proxy-manager is running but "
            "unhealthy, its nginx is refusing to start (on Network=host a saved "
            "proxy host naming a container no longer resolves). Park the "
            "generated configs and re-run:\n"
            f"    mkdir -p /tmp/npm-proxy-host-parked && mv {data_dir}/npm/data/nginx/proxy_host/*.conf /tmp/npm-proxy-host-parked/")

    hosts_decls = mf.npm
    mcp_hosts = mf.mcp
    onions = mf.onion

    log(f"reconciling {len(hosts_decls)} proxy host(s) through {api_base}")

    # A short-lived NPM token expires, so a plain login is preferred when the
    # admin credentials are present; NPM_TOKEN is the fallback for a host that
    # stores only a token.
    if email and password:
        api.login(email, password, npm_env)

    hosts = api.call("GET", "/api/nginx/proxy-hosts")

    declared_domains: List[str] = []
    for host in hosts_decls:
        declared_domains.append(host.domain)

        advanced = ""
        locations: List[dict] = []
        if host.has_flag("mcp"):
            locations = mcp_locations(mcp_hosts)
            advanced = ADVANCED_MCP
        limits = rate_limits(host)
        advanced = f"{advanced}\n{limits}" if advanced else limits

        # A `.onion` needs no certificate and must not be force-SSL (see the
        # module header); every other declared host reuses or requests one.
        if host.domain.endswith(".onion"):
            cert_id = 0
        else:
            cert_id = ensure_cert(api, host.domain, request_cert, dry_run)
        flags = host.flags
        # A pinned certificate only forces SSL when the declaration asks for it.
        if cert_id == 0 and host.has_flag("force-ssl"):
            flags = host.flags_without("force-ssl")

        payload = build_payload(host.domain, host.scheme, host.host, host.port,
                                cert_id, flags, advanced, locations)
        existing_id = find_host_id(hosts, host.domain)

        if dry_run:
            if existing_id is not None:
                log(f"[dry-run] would update proxy host {existing_id} ({host.domain})")
            else:
                log(f"[dry-run] would create a proxy host for {host.domain}")
            print(json.dumps(payload, indent=2), flush=True)
            continue

        if existing_id is not None:
            resp, raw = api.raw_call("PUT", f"/api/nginx/proxy-hosts/{existing_id}", payload)
            if not (isinstance(resp, dict) and resp.get("id")):
                die(f"could not update proxy host {existing_id} ({host.domain}): "
                    f"{(raw or 'no answer from the API')[:400]}")
            log(f"updated proxy host {existing_id} "
                f"({host.domain} -> {host.scheme}://{host.host}:{host.port})")
        else:
            resp, raw = api.raw_call("POST", "/api/nginx/proxy-hosts", payload)
            new_id = resp.get("id") if isinstance(resp, dict) else None
            if not new_id:
                die(f"could not create the proxy host for {host.domain}: "
                    f"{(raw or 'no answer from the API')[:400]}")
            log(f"created proxy host {new_id} "
                f"({host.domain} -> {host.scheme}://{host.host}:{host.port})")

        if host.has_flag("mcp"):
            log("  MCP endpoints (Authorization: Bearer <token from the file named below>):")
            # An onion host has no URL to print (its address is key material)
            # and is plain HTTP: say so rather than showing https://*.onion.
            base = "http://<onion>" if host.domain.endswith(".onion") else f"https://{host.domain}"
            for m in mcp_hosts:
                print(f"    {base}{m.prefix}  ({config_dir}/{m.container}/token.env)", flush=True)

    if prune:
        _prune(api, declared_domains, dry_run)

    # The onion addresses, once tor has published them. Read from tor's own
    # files: the address is key material, not configuration, so it exists only
    # after tor has started (the keys live in $DATA_DIR/tor/onion and are
    # backed up, which is what keeps the address stable).
    if onions:
        log("onion services (no DNS, no Let's Encrypt -- give tor a minute after a first start):")
        for o in onions:
            addrfile = os.path.join(data_dir, "tor", "onion", o.name, "hostname")
            try:
                with open(addrfile, "r", encoding="ascii") as f:
                    addr = f.read().strip()
            except OSError:
                addr = ""
            if addr:
                print(f"    http://{addr}  ({o.mirrors})", flush=True)
            else:
                print(f"    {o.mirrors}: no address yet -- tor has not written {addrfile}", flush=True)

    log("done")
    return 0


def _prune(api: NpmApi, declared_domains: List[str], dry_run: bool) -> None:
    if dry_run:
        log("[dry-run] would delete every host and certificate not declared in "
            "deploy/services.toml")
        return

    def covers_declared(domain_names) -> bool:
        return any(n in declared_domains for n in (domain_names or []))

    hosts = api.call("GET", "/api/nginx/proxy-hosts") or []
    for h in hosts if isinstance(hosts, list) else []:
        if isinstance(h, dict) and not covers_declared(h.get("domain_names")):
            _, raw = api.raw_call("DELETE", f"/api/nginx/proxy-hosts/{h['id']}")
            if raw is not None:
                log(f"deleted proxy host {h['id']} "
                    f"(not declared in deploy/services.toml)")

    # Certificates no longer attached to any surviving host and covering no
    # declared domain -- the leftovers of a host that was pruned.
    hosts = api.call("GET", "/api/nginx/proxy-hosts") or []
    used = [h.get("certificate_id") for h in hosts if isinstance(h, dict)]
    certs = api.call("GET", "/api/nginx/certificates") or []
    for c in certs if isinstance(certs, list) else []:
        if not isinstance(c, dict):
            continue
        if not covers_declared(c.get("domain_names")) and c.get("id") not in used:
            _, raw = api.raw_call("DELETE", f"/api/nginx/certificates/{c['id']}")
            if raw is not None:
                log(f"deleted certificate {c['id']} "
                    f"(unused, not declared in deploy/services.toml)")


def main(argv: List[str]) -> int:
    return reconcile()
