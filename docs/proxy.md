# The proxy tier: NPM, proxy hosts, tor and the onion services

Everything between a client and a container: nginx-proxy-manager's host network,
the declared host list, rate limits, the pinned subnet, and onion publishing.
Read this before touching `deploy/nginx-proxy-manager.container`,
`scripts/npm-hosts.sh`, `NPM_HOSTS`/`ONION_SERVICES`/`MCP_HOSTS`, or `torrc`.
The operator narrative is README's "Proxy hosts", "Tor onion services" and
"Status page".

## Invariants

- **NPM runs on the host network**, so a client's real address reaches it and it
  cannot resolve a container name: every fronted unit publishes on loopback.
- **Every proxy host is declared in `stack.conf`**, never hand-clicked; `--prune`
  is the only destructive mode.
- **The onion rate limit is global** -- every `.onion` visitor arrives as the
  host's own address, so it is keyed on `$server_name`.
- **Never seed the `.onion` address anywhere**; it is key material in
  `$DATA_DIR/tor/onion/`.
- **The wildcard `*.onion` host gets no certificate and no `force-ssl`.**
- **The subnet is pinned** (`10.89.0.0/24`) and the four onion-backed containers
  pin `.241`-`.244`, because tor validates a target at startup.

## uptime-kuma

- **`uptime-kuma` is UI-configured for its own account, declared for everything
  else:** no env file, nothing seeded into its state — kuma v2 runs an
  **embedded MariaDB** (`UPTIME_KUMA_ENABLE_EMBEDDED_MARIADB=1`,
  `db-config.json` says `embedded-mariadb`; the sqlite-era `kuma.db` is a 0-byte
  leftover) — and its monitors are
  `KUMA_MONITORS` in `stack.conf`, reconciled by `scripts/kuma-monitors.sh`
  through the `kuma-ctl` image because kuma has no REST write API. The admin
  login the setup wizard creates lives in `config/uptime-kuma/api.env` (UI-first
  like `npm/api.env`), and the reconciler, `deploy.sh` and `verify.sh` self-skip
  until it is filled in. The declaration format and every socket.io payload
  trap (positional events, the `info` handshake, the status-code array) are in
  `scripts/kuma-monitors.sh` and `kuma-ctl/monitors.mjs` — don't reimplement the
  reconcile as curl. Note v2 answers `/` with a **302 to `/dashboard`**, so a
  probe must follow redirects. Notifications stay UI-configured.

## Rate limiting is per ingress

- **Rate limiting is per ingress, and the onion case is the awkward one:**
  every `.onion` visitor reaches NPM as the host's own address (tor forwards to
  `host.containers.internal`), so the onion zone is keyed on `$server_name` and is
  a *global* brake (60 r/s, burst 120) -- there is no such thing as a per-client
  limit there. Clearweb hosts use `$binary_remote_addr`. The MCP host gets
  `limit_conn` only and never `limit_req`: JSON-RPC bursts are legitimate and
  `GET /mcp` is an SSE stream, so a request-rate limit either does nothing or
  cuts healthy clients. Zones live in `deploy/npm/http.conf` ->
  `$DATA_DIR/npm/data/nginx/custom/http.conf`, the one NPM directory that is never
  regenerated; the directives are per host in `advanced_config`. A new file in
  that directory is created with the *default* SELinux label even though the tree
  is mounted `:z`, and nginx then refuses to load it -- `install.sh` chcons it,
  because a deploy does not necessarily restart NPM.

## The pinned subnet

- **The subnet is pinned** (`10.89.0.0/24`) because `tor.container` pins
  `--ip=10.89.0.240` and both `bitcoin.conf` (`rpcallowip`) and `torrc`
  (`SocksPolicy`) allow it; `tor` is addressed by that IP, not by name
  (`lightningd` runs `--always-use-proxy=true`, which suppresses DNS). The four
  containers that back onion services pin `.241`–`.244` because tor validates a
  `HiddenServicePort` target at startup: a container *name* that does not exist
  yet is an unparseable address and stops tor from starting. Keep the range
  unique; don't drop the subnet.

## torrc and the control password

- **`torrc`'s `HashedControlPassword` must hash to `TOR_SERVICE_PASSWORD`**;
  `install.sh` derives it with `tor --hash-password` on a fresh host and
  otherwise leaves `torrc` alone. tor logs a `ControlPort ... non-local address`
  warning because lightningd drives the statictor service over `10.89.0.240:9051`;
  that is deliberate, the port is password-protected and only on `npm-network`.

## tor is the onion publisher

- **`tor` is also the onion publisher, and the onion side does not go through NPM
  the way the clearweb side does.** `ONION_SERVICES` in `stack.conf` is the
  declaration; `install.sh` rewrites only the marked region at the end of
  `torrc` so the hash and the `SocksPolicy` are never touched, and `deploy.sh`'s
  `unit_digest` hashes `torrc` so a changed declaration restarts tor. The
  `.onion` address is key material, not config: it comes from
  `$DATA_DIR/tor/onion/<name>/` (mounted `/var/lib/tor/onion`, hence `tor/` in
  the backup set), so never "clean up" that directory and never seed the address
  anywhere. The frontend and API onions forward to their **containers**; the mcp
  one cannot, because the path split is NPM's job and NPM is on the host
  network, so it targets `host.containers.internal`. Tor cannot rewrite `Host`
  and the address is unknown at install time, so NPM gets a **wildcard
  `*.onion`** host (the only host with no certificate — `npm-hosts.sh` skips
  Let's Encrypt for `.onion`, and `force-ssl` must never be added to it). Don't
  "fix" the mcp target to a container name or give the wildcard a cert.

## nginx-proxy-manager runs on the host network

- **nginx-proxy-manager runs on the host network, and health comes from podman.**
  `Network=host` with no `PublishPort=`, so NPM's own nginx binds :80/:443/:81 in
  the host's namespace and every request carries the client's real address; a
  rootless published port went through `rootlessport` and showed NPM its own
  container IP. `deploy/nginx-proxy-manager.container` carries the full
  explanation, including why podman 6's `pasta` forwarder would be the other way
  out. The price is that NPM cannot resolve a container name: every unit it
  fronts publishes on the host's **loopback** (`PublishPort=127.0.0.1:<port>:…`),
  which is what `NPM_HOSTS`/`MCP_HOSTS` point at, and only 80/443/81 plus
  Fulcrum's raw ports stay LAN-reachable. Host-side checks still read
  `container:8000` on `npm-network` through `net_curl` (exec'd into the
  long-lived `netcheck` container; `netcheck-host` is the same image on the host
  network for NPM's own admin API on `127.0.0.1:81`). The units set `HealthCmd=`/`HealthInterval=`, so podman
  really does report `(healthy)` and `deploy.sh` waits with `wait_healthy`; the
  MCP probe is an authenticated `initialize`, strictly stronger than a `/health`
  GET.

## Every proxy host is declared

- **Every proxy host is declared, not hand-clicked:** `NPM_HOSTS` in `stack.conf`
  is the whole public surface, and `scripts/npm-hosts.sh` reconciles it through
  NPM's admin API on `127.0.0.1:81` (update in place by `domain_names`, else
  create, plus a Let's Encrypt certificate per host). It needs the admin login in
  `config/npm/api.env` and `jq` on the host (bootstrap), and self-skips when the
  login is absent. `--prune` is the only destructive mode. The `mcp` flag is the
  one exception to "one forward": one location per `MCP_HOSTS` entry
  (`/prefix:container:port`), each rewritten onto the container's `/mcp`, with
  the streaming settings an SSE transport needs — the script's header owns that
  payload. `verify.sh` re-checks the path through NPM's `:80` (following the
  force-SSL redirect) with `--connect-to` onto `127.0.0.1`, so the certificate
  still validates. BTCPay's admin UI is gated by its own login (2FA expected),
  and its API by the store-scoped key the backend carries; no daemon RPC has a
  public NPM host any more.

