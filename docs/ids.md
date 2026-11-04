# Intrusion detection and the audit tier

Two detection engines in two privilege domains, the enforcement applier, and the
kernel audit watches. Read this before touching `deploy/root/`, the CrowdSec
config tree, `scripts/ids.sh`, or the bouncer. The operator narrative is
README's "Intrusion detection".

## Invariants

- **Neither engine is redundant.** NPM terminates TLS, so a request exists only
  in its log; onion traffic exists only on the wire as ciphertext.
- **Enforcement is ours** (`deploy/root/bouncer.sh`), because no upstream bouncer
  image works, and it refuses private space, every address the host holds, and
  `STACK_WAN_IP` -- that last one is the operator's own shared egress.
- **`CROWDSEC_BOUNCER_KEY` is never regenerated.** The container registers that
  exact key at start.
- **A whitelist expression is a plain string prefix, not a network.**
- **Never run `auditctl -D`.** Remove our rules one at a time with `auditctl -W`.
- **Directory watches record nothing on this kernel**; entry creation is caught
  by the hash diff over the persistence directories instead.
- **A crowdsec unit without `[Install]` never starts at boot** -- that rule and
  its evidence are in `units.md`, "The app tier, shared mounts, and the root
  tier".

## Intrusion detection is two engines and two privilege domains

- **Intrusion detection is two engines and two privilege domains:**
  `suricata` (rootful, `deploy/root/`, enp8s0 + lo) sees packets and no TLS
  content; `crowdsec` (rootless) sees NPM's access log and nothing on the wire.
  Neither is redundant: NPM terminates TLS, so the request exists only in its
  log, and the onion traffic exists only on the wire as ciphertext. Silencing
  either one loses a distinct half. `DISABLE_ONLINE_API=true` is deliberate
  ("local detection only": no console, no CAPI blocklist, no telemetry).
  **Enforcement is `stack-bouncer`** (`deploy/root/bouncer.sh`, a root oneshot on
  a one-minute system timer): crowdsec runs on the host network, so it polls the
  LAPI on `127.0.0.1:8080` directly — no published port, because rootless
  podman's bridge is not routable from the host and its `rootlessport` forwarder
  is owned by no unit (one vanished on 2026-11-02 and left enforcement off for
  7h39m with the container still green) — with `CROWDSEC_BOUNCER_KEY`, and
  writes the `inet stack_bans` set, each element
  carrying the decision's own duration as an nft timeout. There is no upstream
  bouncer image any more (`crowdsecurity/cs-firewall-bouncer` answers *access
  denied*), which is why the applier is ours: CrowdSec keeps the decision
  lifecycle, we own the plumbing.
  Four traps, all found by running it: (1) the LAPI answers **`null`**, not
  `[]`, when nothing is banned -- a strict array check reads that as a protocol
  error and blocks enforcement; (2) `nft -f` **merges** a table declaration
  rather than recreating it, so re-declaring the chain each run appends a
  duplicate drop rule every minute -- create the table only when missing, then
  `flush set` and re-add; (3) `CROWDSEC_BOUNCER_KEY` must **never** be
  regenerated (the container registers that exact key at start; a new one leaves
  a stale bouncer and a LAPI answering 403, i.e. silent non-enforcement), and it
  is the one secret appended to `secrets.env` rather than written by its heredoc,
  because it has to exist on hosts deployed before it; (4) the script refuses
  private space **and every address the host holds** -- `192.168.1.112` is what
  onion traffic and Uptime-Kuma look like, so banning it takes the onion
  services, the status page and the operator's own SSH session down together.
  Enforcement also refuses **`STACK_WAN_IP`**, and that one is not in `OWN_IPS`:
  the router holds the public address, not the host, yet every check that leaves
  this host resolves the public names and comes back through the router's NAT
  loopback, so Uptime-Kuma, agent-mcp and the MCP clients all arrive as one
  shared source IP. Measured near miss: three 401s from one MCP client in one
  second against `stack/http-authfail`'s bucket of five, i.e. two retries from
  banning the operator's own egress (5 minutes of a dark public surface,
  including the status page). The refusal is at the **bouncer**, deliberately
  not in the whitelist: detection still decides, `cscli` still shows it, the
  monitor still pages -- only the drop is skipped, so `bouncer.status` gains
  `skipped=` and `banned=0 skipped=1` means "your own egress is tripping a
  rule", not a quiet host. The address is a declaration (`stack.conf`), never a
  DNS lookup, because a future CDN would turn a lookup into an exemption for one
  of its edges; `verify.sh` warns when it disagrees with the source address NPM
  logs for the host's own monitoring, which is how a WAN change is noticed.
  Failure directions are chosen: an unreachable LAPI leaves existing bans alone
  (never read "no decisions" as "unban all"), and a failed `nft -f` rolls back
  atomically. `scripts/monitor.sh` fails on a stale `audit/bouncer.status`, which
  is the only signal that detection is healthy while nothing enforces.
  `scripts/ids.sh` rolls the engines up into `$DATA_DIR/audit/ids.status` (the
  `backup-verify.status` pattern) rather than letting the monitor reach into a
  rootful unit and a `podman exec`; a stale status is the failure signal. Its
  decision counter reads `cscli **decisions** list -o json`, which is
  **alert-shaped** -- an array of groups, each holding the decision(s) that alert
  produced under `.decisions[]` and the address under `.source.value` -- because
  the command prints `Alerts.List`'s response, not `/v1/decisions`. Reading the
  top level as the decision list counts groups and formats `NEWEST` out of a
  group that has no `.value` ("stack/http-probing ?"); the flat shape belongs to
  `bouncer.sh`'s `/v1/decisions` pull, so the two must not be "aligned".
  Two more traps: NPM writes a **custom log_format**, not `combined`, so the
  stock nginx parser matches nothing --
  `deploy/crowdsec/parsers/s01-parse/stack-npm.yaml` owns both shapes and
  `verify.sh` replays a sample line through `cscli explain` on every sweep,
  because a silent log-format change turns detection off; and the whitelist in
  `s02-enrich/` protects the host's **own** address, which is what onion traffic
  and Uptime-Kuma's self-checks look like in the log. A whitelist expression is a
  **plain string prefix, not a network**: `startsWith '172.2'` covered
  172.2.0.0/16 and 172.200.0.0/14 as well as the intended 172.20.0.0/14, so
  ~4.4M public addresses were reported as `whitelisted` -- and because the
  whitelist runs in `s02-enrich`, *before* the scenarios, a whitelisted event
  never becomes a decision and `cscli decisions list --all` cannot show it
  (`cscli metrics`' whitelisted count is the only trace, so an over-broad entry
  looks exactly like a quiet internet). The /12 is an `IpInRange` now, and
  `verify.sh` asserts both directions with `cscli explain`: a public
  `172.220.10.5` must **not** be whitelisted, `172.18.0.5` must be, and a
  Uptime-Kuma user agent must be -- that last one is the only probe the stock
  `crowdsecurity/whitelists` cannot answer for us, so it is what proves this file
  is loaded at all.

## The audit tier watches files only

- **The audit tier watches files only, because directory watches do nothing on
  this kernel.** Measured: `-w /etc/sudoers.d/ -p wa` (and the
  `-a always,exit -F dir=… -F perm=wa` form) records nothing for a file created
  inside it, while the same watch on a file fires. Entry creation -- a new unit
  file, a sudoers drop-in, a cron job -- is covered instead by the hash diff in
  `deploy/root/audit-report.sh` over `/etc/systemd/system`,
  `/etc/containers/systemd`, `/etc/sudoers.d`, `/etc/cron.d` and
  `/etc/ssh/sshd_config.d`, which also names the file. Keys split the verdict:
  `stack_hard` (account databases, sudoers, sshd, audit's own config -- nothing
  in this repo writes them) fails the sweep, `stack_data` (the stack's secrets,
  which rotation and deploys do write) only reports. Two EL10 details:
  `auditctl`/`augenrules` are the separate **`audit-rules`** package, so a host
  can run auditd with no way to add a rule; and **never run `auditctl -D`** --
  doing it once on this host left the kernel accepting rules while emitting no
  events at all, not even the next rule's CONFIG_CHANGE, until a reboot. Remove
  our rules one at a time (`auditctl -W <rule>`), anything else is left alone.
  `augenrules` exits non-zero on "Rule exists" even when the ruleset is already
  right, so `install.sh` judges the result by `auditctl -l`, not the exit code.
  **Whether the kernel audit subsystem records anything is a measurement, not an
  assumption.** This host once initialized disabled (`audit_enabled=0` in dmesg,
  journald "Collecting audit messages is disabled") while `auditctl -s` still
  reported `enabled 1` and no kernel record was ever written, not even the
  CONFIG_CHANGE for loading the rules; it survived a reboot. The report marks
  itself `audit=inert` in that state (watches loaded in `auditctl -l`, no
  `CONFIG_CHANGE` from `ausearch`) and the sweep says so, so nobody reads "no
  host-level changes" as coverage. The hash diff over the persistence
  directories is the half that works regardless. **Re-measured 2026-11-01 it is
  live** — `enabled 1`, the nine watches loaded, records being written — which
  surfaced three things worth keeping: (1) `aureport`/`ausearch` take the window
  as **two** arguments, a date and a time; passing one string like
  `--start "11/01/2026 17:38:06"` is refused with "Hour, Minute, and Second are
  required", and the `2>/dev/null || true` around both calls is why every count
  came back empty and the sweep reported "no host-level changes" from a read that
  never happened — `read=ok|failed` in the status file is the guard against that
  recurring. (2) The summary is read with `--no-config`, because loading the rule
  set makes the kernel emit a keyed CONFIG_CHANGE per rule added (three per
  reload from `auditctl -R`), and counting those pages on every deploy; a rule
  *removed* (`op=del_rule`) is counted instead, since that is how somebody blinds
  the host. (3) Volume is whatever rules are actually in the kernel, not what is
  in `rules.d`: this host carries a runtime-only `-a always,exit -F arch=b64 -S
  execve -F key=ALLEXEC` that no file in `/etc/audit/` mentions (`auditctl -l` is
  the only place to see it), so every exec on the host is logged — ~16/s here,
  which rotates `/var/log/audit` every ~5 minutes. The repo's own nine watches
  produce a handful of events at steady state. The report advances its
  `auditd.cursor` only when `aureport` exits 0 (`read=ok|failed` in the status
  file, reported by the sweep as a soft line), so a failed read re-examines the
  same window instead of stepping over it. A missing (or empty)
  `/var/log/audit/audit.log` is not a failed read — `aureport` exits 1 when there
  is no log at all, which is what an inert subsystem looks like, so that case
  still advances and the window stays bounded.

