# Credentials, spending and rotation

The secrets the stack holds, the one command that rotates each of them, and the
two things that must stay off. Read this before touching `scripts/rotate.sh`,
`stack.conf`'s method allowlists, any `spend.env`, or anything that passes a
token on a command line.

## Invariants

- **Spending stays off** (`ENABLE_SPENDING=0`, never seeded `1`), and
  `spend-audit.sh` asserts it.
- **Rotation goes through the same two authorities as install**: `rotate.sh`
  writes the source of truth and re-runs `install.sh`, never a unit by hand.
- **There is no journal and no `--resume`**: re-run the same target.
- **Any daemon-side mutation is guarded for `--dry-run` inside the function that
  performs it**, not at the call site.
- **No bearer token reaches the host's argv**; a curl config on stdin carries
  them.
- **A secret key is minted once and never duplicated.** `install.sh`'s
  `ensure_secret_key` rewrites an empty or duplicated `KEY=` line (reusing the
  first non-empty value) instead of appending a second line that `env_value`
  would not read, and never regenerates a value that is already set -- the
  CrowdSec bouncer registrations depend on that.

## Spending stays off

- **Spending stays off:** `install.sh` writes `ENABLE_SPENDING=0` to both money
  servers' `spend.env` (never seed `1`); `scripts/spend-audit.sh` asserts it,
  hash-baselines both `spend.env`, both token files and `node.env` (the spend
  rune), and diffs outgoing `listpays`/`get_transfers` against a baseline.

## Rotation

- **Rotation goes through the same two authorities as install, so it cannot
  drift from it:** `scripts/rotate.sh` writes the source of truth, re-runs
  `deploy/install.sh` to re-render (never a unit by hand), restarts the affected
  units and only then revokes (the superseded runes, the superseded restic key). The three
  seed-once files are why a rotation is not an env edit — `bitcoin.conf` is
  edited inside the container, `torrc` only in its `HashedControlPassword` line
  (the onion block is `install.sh`'s), and `btc-explorer.env`/
  `bitcoin-node-mcp/upstream.env` are rewritten by `rotate.sh` because
  install.sh seeds them once (`seed_rendered`, §6; the policy is in
  `docs/units.md`). The CLN method allowlists live in `stack.conf`
  (`CLN_READ_METHODS`/`CLN_SPEND_METHODS`, rendered by
  `rune_json`) precisely so the installer and the rotator mint the same runes.
  **Nothing is journaled and there is no `--resume`: a half-applied rotation is
  finished by re-running the same target**, which is why every target either
  rewrites every copy of its credential or reconciles a declared end state
  against the authority that holds it. `runes` blacklists every live rune whose
  method set is *exactly* one of `stack.conf`'s except the pair in
  `lightning-mcp/node.env` (`cln_orphan_runes` in `scripts/lib.sh`, shared with
  `scripts/monitor.sh` so the pruner and the alarm agree) — a set comparison,
  because a rune has no label and a remembered id missed five live leftovers,
  two of them spend-capable, on this host. `restic` writes
  `RESTIC_PASSWORD_NEXT` into `backup.env` *before* `key add`, promotes it, then
  removes the superseded keys, so no crash leaves the repository openable only
  by a password nobody holds; the spend baseline is rehashed per file rather
  than `--rebaseline`d, and `rotation.log` records the act without the value. A
  re-run also skips a restart when the container's own PID 1 already carries the
  value (`container_runs_secret` for argv, `container_env_is` for an
  `EnvironmentFile=`), which is the only restart-avoidance there is: anything a
  daemon reads out of a config file, or consumed at `initdb`, restarts. No
  timer: these tokens have clients outside the stack.
  The in-stack credentials are `bitcoin-rpc`, `tor-control` and `runes`, plus
  `token:<server>` (proves the new bearer TOKEN answers a real tool call; the
  old one cannot, a server holding one token, and it is not on the host any more
  to test -- `--spend` only proves the reload, since the spend token is exercised
  by a spend call)
  and `searxng-secret`. There is **no `monero-wallet` target** any more: BTCPay's
  wallet is imported view-only (address + view key only), opens with an empty
  password and runs with `--disable-rpc-login`, so the file holds nothing to
  rotate -- `--list` is the authority on the set.
  **Any daemon-side mutation must be guarded for `--dry-run` inside the
  function that performs it, not only at the call site** -- the rule outlives
  the target that taught it: an unguarded `change_wallet_password` during a dry
  run, back when `monero-wallet` was a target, changed a live wallet's password
  to a value nothing had recorded, which cost a restore from backup and a cache
  rebuild. What replaces a journal as the alarm is the invariant, not a file:
  `scripts/monitor.sh` fails on a live stack rune the pair does not reference and
  on bitcoind's `rpcpassword` disagreeing with `secrets.env`, and only mentions a
  stale `config/rotation/*.pending` (inert, from the version that had them).
  The rest (`postgres`, `boltmesh-keys`, `restic`) follow the same rule: change
  the daemon/authority first (ALTER ROLE, key add), keep the client copy in its
  env file, and prove the new value end to end. Two traps worth remembering:
  the postgres image's `pg_hba.conf` trusts `127.0.0.1`, so a password check over
  loopback succeeds with anything and says nothing (use the podman-network
  address, as `pg_tcp_login` does), and `restic` must make the new password
  durable (the `RESTIC_PASSWORD_NEXT` line), add, prove, promote, then remove —
  never remove first, and never let the durable copy lag the repository.

## Tokens never reach the host's argv

- **The bearer tokens never reach the host's argv** — `mcp_initialize` /
  `mcp_tool_call` pass them in a curl config on stdin (`-K -`), so `ps` cannot
  read a token out of a running verify/monitor/audit sweep. `npm-hosts.sh`
  does the same with the NPM admin password and the API token it mints.

