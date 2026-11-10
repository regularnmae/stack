#!/usr/bin/env bash
# Rotate one credential and update every service that depends on it.
#
#   scripts/rotate.sh --list                     # targets, what each one touches
#   scripts/rotate.sh --status                   # credential invariants + recent runs
#   scripts/rotate.sh <target> --dry-run         # the plan, no values, no writes
#   scripts/rotate.sh <target>                   # rotate, re-render, restart, verify
#
# Targets (one credential each; every run writes its source of truth, re-renders
# the units through deploy/install.sh, restarts the dependents and verifies):
#
#   bitcoin-rpc    bitcoind's RPC password (and --user, its RPC user). Touches
#                  bitcoin.conf, stack/secrets.env, the rendered lightningd and
#                  fulcrum units, bitcoin-node-mcp/upstream.env and
#                  btc-explorer/btc-explorer.env.
#   tor-control    Tor's control password, which lightningd uses for its
#                  statictor onion service. Touches torrc's hash and the
#                  rendered lightningd unit. The onion address does not change.
#   runes          Core Lightning runes (lightning-mcp's read/spend pair):
#                  mint, swap, verify, THEN blacklist every other stack rune.
#                  --scope read|spend|all (default all).
#   token:<server> one MCP server's bearer token (token.env) -- the credential
#                  with the most copies outside the stack. --spend rotates the
#                  additional spend token of a money server instead.
#   searxng-secret SearXNG's settings.yml secret_key (limiter/session signing).
#
# Why this is not "rewrite the env file and restart": part of each credential
# lives in a file install.sh seeds ONCE and never rewrites -- bitcoind's own
# bitcoin.conf, tor's torrc with its hashed password, and the per-app
# upstream/explorer env files -- so the source of truth and the copy the daemon
# is actually using have to be moved together, in an order that leaves a re-run
# able to finish. Hence: write the files, re-render through deploy/install.sh
# (the only installer), restart the dependents in dependency order, verify, and
# only then revoke anything (a rune, a restic key).
#
# There is no --resume and nothing is journaled: a run that dies half-way is
# finished by running the same target again. Every target either rewrites every
# copy of its credential (bitcoin.conf and secrets.env, torrc and its hash,
# token.env, db.env, the BoltMesh keys) or reconciles a DECLARED end state
# against the authority that holds it:
#
#   runes   once the new pair is proven in node.env, every other live rune whose
#           method set is exactly one of stack.conf's is blacklisted. That is a
#           set comparison, not a remembered id, so it also collects leftovers
#           from crashes that happened before this script existed.
#   restic  RESTIC_PASSWORD_NEXT is written to backup.env BEFORE the repository
#           learns the password, then promoted to RESTIC_PASSWORD and the
#           superseded key removed, so no crash can strand the repository on a
#           password nobody holds.
#
# A journal was the earlier design and could describe only the state one run
# expected; converging from whatever is actually there is the same job with less to
# get wrong. The one thing a re-run cannot reproduce is the proof that the
# *previous* value is dead (a bearer token, a role password): those negative checks
# are implied by the positive one -- the server and the role each hold exactly one
# credential.
#
# Nothing here is scheduled. These tokens have consumers outside the stack
# (opencode's MCP config, a wallet, nginx-proxy-manager), and rotating one on a
# timer would break them silently at 3am. A rotation is an operator action; the
# entry it leaves in $DATA_DIR/audit/rotation.log is the record (never a value).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
FORCE=0
ROTATE_USER=0
ASSUME_YES=0
SPEND_ONLY=0
RUNE_SCOPE="all"
TARGET=""
# 1 once preflight has passed and the target is about to run: the EXIT trap must
# not report a refusal-to-start as a failed rotation.
STARTED=0
# The applied-unit baseline (scripts/lib.sh's units_baseline) read before the
# target edits anything, the units this rotation restarted or proved already
# current, and whether it re-rendered at all. Only bitcoin-rpc and tor-control
# re-render (the secrets they rotate are baked into a unit's Exec=), and only
# those advance the baseline -- see complete().
UNITS_BEFORE=""
APPLIED_UNITS=" "
RERENDERED=0

# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"
# The MCP server table (names, token variables, probe tool/args, spend token)
# comes from deploy/services.toml as the manifest's index-aligned arrays, so a
# server added there is a rotation target here without a second list to keep in
# step.
load_manifest "$REPO_DIR"

RESTIC_IMAGE="${RESTIC_IMAGE:-docker.io/restic/restic:0.19.1}"
BITCOIND_WAIT="${BITCOIND_WAIT:-600}"
LN_WAIT="${LN_WAIT:-300}"
APP_HEALTH_WAIT="${APP_HEALTH_WAIT:-180}"

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --list)     LIST=1; shift ;;
        --status)   STATUS=1; shift ;;
        --resume)   die "--resume is gone: re-run the target instead (./scripts/rotate.sh <target>); every target converges from a half-applied run" ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --force)    FORCE=1; shift ;;
        --user)     ROTATE_USER=1; shift ;;
        --yes)      ASSUME_YES=1; shift ;;
        --spend)    SPEND_ONLY=1; shift ;;
        --scope)    RUNE_SCOPE="${2:?--scope needs read|spend|all}"; shift 2 ;;
        -h|--help)  usage_header "$0"; exit 0 ;;
        -*)         die "unknown argument: $1 (try --help)" ;;
        *)          [ -z "$TARGET" ] || die "one target at a time"; TARGET="$1"; shift ;;
    esac
done

if [ "${LIST:-0}" = 1 ]; then
    cat <<'EOF'
targets (each one writes its source of truth, re-renders, restarts, verifies):

  bitcoin-rpc    bitcoind RPC password/user -> bitcoin.conf, secrets.env,
                 lightningd + fulcrum units, bitcoin-node-mcp, btc-explorer
  tor-control    Tor control password -> torrc hash, secrets.env, lightningd
                 (the onion address is unchanged)
  runes          CLN runes -> lightning-mcp/node.env;
                 every other stack rune is blacklisted once the new pair works
                 (--scope read|spend|all, default all)
  token:<server> one MCP bearer token (token.env), then prove the new one works
                 --spend rotates the spend token of monero-wallet-mcp or
                 lightning-mcp instead of the read token
                 servers: searxng-mcp bitcoin-node-mcp monero-node-mcp
                          monero-wallet-mcp lightning-mcp fulcrum-mcp
                          victoria-logs-mcp victoriametrics-mcp crowdsec-mcp
                          btcpay-mcp
  searxng-secret SearXNG's settings.yml secret_key
  postgres       the vpnuser role's password -> db.env, dump.env, BoltMesh
  boltmesh-keys  SECRET_KEY/REFRESH_SECRET_KEY/NODE_SECRET_KEY/BOOTSTRAP_SECRET_PEPPER
                 (--yes: every session and node token ends)
  restic         the backup repository's key: add, prove, promote, then remove
                 the superseded one (--yes)

flags: --dry-run (print the plan)  --force (ignore preflight, e.g. a running
backup)  --yes  --spend  --status  --list

a run that dies half-way is finished by running the same target again
EOF
    exit 0
fi

resolve_data_dir
SECRETS_FILE="$CONFIG_DIR/stack/secrets.env"
SEARXNG_DATA_DIR="$DATA_DIR/searxng"
BACKUP_ENV="$CONFIG_DIR/backup/backup.env"
# Scratch for the restic password files and the searxng rewrite: a place with
# mode 0700 that a container can be handed (restic) and that no daemon owns.
# Nothing durable lives here -- there is no journal any more.
ROT_DIR="$CONFIG_DIR/rotation"

# The BoltMesh env directory: deploy/install.sh calls it BOLT_DB, and it holds
# the three files the postgres and boltmesh-keys targets rewrite (db.env,
# dump.env, secrets.env).
BOLT_DIR="$CONFIG_DIR/boltmesh"

# The rune restriction JSON, built from the allowlists stack.conf declares --
# the same source deploy/install.sh mints from, so a rotation cannot hand out a
# wider (or narrower) rune than a fresh install would.
if [ "${CLN_READ_METHODS+x}" != x ] || [ "${#CLN_READ_METHODS[@]}" -eq 0 ]; then
    die "stack.conf must declare CLN_READ_METHODS and CLN_SPEND_METHODS"
fi
READ_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}")
SPEND_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}" "${CLN_SPEND_METHODS[@]}")
case "$RUNE_SCOPE" in
    read|spend|all) ;;
    *) die "--scope must be read, spend or all" ;;
esac

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
say() { printf '    %s\n' "$*"; }

# Print what a mutating step would do (dry run) or do it. Descriptions only:
# a command line may carry a secret, so it is never echoed.
run_step() { # description command...
    local desc="$1"; shift
    if [ "$DRY_RUN" = 1 ]; then say "would $desc"; return 0; fi
    "$@"
}

# A description-only wrapper for a command whose stdout is noise (podman and
# lightning-cli print JSON nobody needs in the middle of a rotation log).
quiet() { "$@" >/dev/null 2>&1; }

# A fresh secret. Hex only -- these values end up in a systemd Exec= line, which
# is split on whitespace and never shell-quoted, and in a container's argv.
gen() { rand_hex; }

# --- file writers (atomic, keep mode, never print a value) ------------------
# Set KEY=value in an env file in place (keeps comments, order and mode; appends
# when the key is absent). awk gets the values through the environment so a
# value is never re-interpreted as awk -v escapes.
set_env_key() { # file key value
    local f="$1" k="$2" v="$3" mode
    [ -f "$f" ] || die "missing $f; run deploy/install.sh first"
    if [ "$DRY_RUN" = 1 ]; then say "would set $k in $f"; return 0; fi
    mode=$(stat -c %a "$f")
    if ! K="$k" V="$v" awk '
        BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$f" | write_atomic "$f" "$mode"; then
        die "could not rewrite $f"
    fi
}

set_env_key_if_file() { # file key value
    [ -f "$1" ] || { say "no $1; not deployed, skipping $2"; return 0; }
    set_env_key "$@"
}

# Drop KEY from an env file (keeps comments, order and mode). Used for the one
# key that is deliberately transient: RESTIC_PASSWORD_NEXT, the write-ahead
# copy of a restic password the repository has not accepted yet.
unset_env_key() { # file key
    local f="$1" k="$2" mode
    [ -f "$f" ] || return 0
    grep -q "^$k=" "$f" || return 0
    if [ "$DRY_RUN" = 1 ]; then say "would remove $k from $f"; return 0; fi
    mode=$(stat -c %a "$f")
    if ! { grep -v "^$k=" "$f" || true; } | write_atomic "$f" "$mode"; then
        die "could not rewrite $f"
    fi
}

# bitcoind owns its data dir and install.sh hands bitcoin.conf to the image uid,
# so the file is edited from inside the container (the README says the same).
# The key must already be there: appending one would be a silent no-op for the
# daemon and leave the two copies disagreeing.
edit_bitcoin_conf() { # key value
    local key="$1" val="$2"
    if [ "$DRY_RUN" = 1 ]; then say "would set $key in /data/.bitcoin/bitcoin.conf"; return 0; fi
    case "$val" in
        *[!A-Za-z0-9._-]*) die "refusing to write $key: unsupported characters in the value" ;;
    esac
    podman exec bitcoind sh -c "
        test -f /data/.bitcoin/bitcoin.conf || { echo 'no /data/.bitcoin/bitcoin.conf' >&2; exit 1; }
        grep -q '^${key}=' /data/.bitcoin/bitcoin.conf || { echo 'no ${key}= line in bitcoin.conf' >&2; exit 1; }
        sed -i 's|^${key}=.*|${key}=${val}|' /data/.bitcoin/bitcoin.conf
        chmod 600 /data/.bitcoin/bitcoin.conf
    "
}

# torrc is seeded once, so the hash is replaced in place. Only that one line is
# touched: the onion-service block at the end of the file belongs to the
# [onion.*] tables and the SocksPolicy lines are hand-written.
set_torrc_hash() { # hashed-password
    local hash="$1" f="$DATA_DIR/tor/torrc" tmp mode
    [ -f "$f" ] || die "missing $f; run deploy/install.sh first"
    if [ "$DRY_RUN" = 1 ]; then say "would set HashedControlPassword in $f"; return 0; fi
    mode=$(stat -c %a "$f")
    tmp=$(mktemp "$(dirname "$f")/.rot.XXXXXX")
    if ! H="$hash" awk '
        /^HashedControlPassword / { print "HashedControlPassword " ENVIRON["H"]; found = 1; next }
        { print }
        END { if (!found) { print "no HashedControlPassword line" > "/dev/stderr"; exit 1 } }
    ' "$f" > "$tmp"; then
        rm -f "$tmp"
        die "could not rewrite $f"
    fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$f"
}

# tor hashes the control password itself; the value goes in on stdin so it never
# appears in a podman argv (install.sh passes it as an argument, this does not).
tor_hash() { # password -> 16:<hash>
    local pw="$1"
    if [ "$DRY_RUN" = 1 ]; then printf '16:dryrun'; return 0; fi
    printf '%s\n' "$pw" | podman run --rm -i "$TOR_IMAGE" sh -c '
        read -r pw
        tor --hash-password "$pw" 2>/dev/null | grep -E "^16:" | head -n1
    '
}

# --- units ------------------------------------------------------------------
# install.sh is the only installer: it re-renders the units from the env files
# and reloads systemd. A re-render alone changes nothing that is running, which
# is why every target restarts its own dependents afterwards. Its output is
# captured so a rotation's own log stays readable; a failure prints all of it.
install_rerender() {
    local out
    if [ "$DRY_RUN" = 1 ]; then say "would re-render the units (deploy/install.sh)"; return 0; fi
    log "re-rendering the units (deploy/install.sh)"
    out=$(mktemp)
    if ! "$REPO_DIR/deploy/install.sh" > "$out" 2>&1; then
        cat "$out" >&2
        rm -f "$out"
        die "deploy/install.sh failed; the units may be half-rendered. Re-run it, or ./deploy.sh"
    fi
    rm -f "$out"
    RERENDERED=1
}

restart_unit_and_wait() { # container [timeout]
    local c="$1" t="${2:-$APP_HEALTH_WAIT}"
    run_step "restart $c" systemctl --user restart "$c.service"
    if ! wait_healthy "$c" "$t"; then
        die "$c did not report healthy; re-run the same target once it does (./scripts/rotate.sh $TARGET)"
    fi
    APPLIED_UNITS="$APPLIED_UNITS$c "
}

# True when the RUNNING container's PID 1 already carries the value the unit was
# rendered with (checked on its own command line, not on the file). A re-run
# after a half-applied rotation must not bounce a daemon that is already running
# the new secret: it is a second outage for no reason.
container_runs_secret() { # container value
    podman exec "$1" sh -c 'tr "\0" "\n" < /proc/1/cmdline' 2>/dev/null \
        | grep -qxF -- "$2"
}

# The env-file twin: what Quadlet's EnvironmentFile= delivers to PID 1. Only the
# process's own copy counts -- the file is what a half-applied run rewrites.
container_env_is() { # container KEY=value
    podman exec "$1" sh -c 'tr "\0" "\n" < /proc/1/environ' 2>/dev/null \
        | grep -qxF -- "$2"
}

restart_if_deployed() { # container...
    local c
    for c in "$@"; do
        if podman container exists "$c" 2>/dev/null; then
            restart_unit_and_wait "$c"
        else
            say "$c is not deployed; skipping"
        fi
    done
}

# Restart a container unless its PID 1 already carries the new value, proven the
# way that value reaches the process: argv for an Exec= argument, env for an
# EnvironmentFile= key. It is only ever an optimisation -- anything that cannot
# be proven from the running process (a secret a daemon reads out of a config
# file, or one it consumed at initdb) is restarted.
restart_if_stale() { # container argv|env value
    local c="$1" via="$2" val="$3"
    if ! podman container exists "$c" 2>/dev/null; then
        say "$c is not deployed; skipping"
        return 0
    fi
    if [ "$DRY_RUN" = 0 ]; then
        case "$via" in
            argv) if container_runs_secret "$c" "$val"; then
                      log "$c already runs the new value; not restarting it"
                      APPLIED_UNITS="$APPLIED_UNITS$c "
                      return 0
                  fi ;;
            env)  if container_env_is "$c" "$val"; then
                      log "$c already carries the new value; not restarting it"
                      APPLIED_UNITS="$APPLIED_UNITS$c "
                      return 0
                  fi ;;
        esac
    fi
    restart_unit_and_wait "$c"
}

# --- audit trail ------------------------------------------------------------
record_rotation() { # target status [detail]
    local f="$DATA_DIR/audit/rotation.log"
    [ "$DRY_RUN" = 0 ] || return 0
    mkdir -p "$DATA_DIR/audit"
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" "${3:-}" >> "$f"
    chmod 600 "$f" 2>/dev/null || true
}

on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$STARTED" = 1 ] && [ -n "$TARGET" ]; then
        record_rotation "$TARGET" failed
        warn "the rotation of $TARGET did not finish; re-run it to converge: ./scripts/rotate.sh $TARGET"
    fi
}
trap on_exit EXIT

# A rotation is not spend-policy drift, but scripts/spend-audit.sh hashes the
# files it touches. Rehash exactly those rows: --rebaseline would also accept
# an unrelated edit, which is the one thing the tripwire exists to notice.
rehash_audit() { # file...
    local baseline="$DATA_DIR/audit/spend-baseline.tsv" f h tmp
    [ -s "$baseline" ] || return 0
    if [ "$DRY_RUN" = 1 ]; then say "would rehash $* in the spend baseline"; return 0; fi
    tmp=$(mktemp "${baseline}.XXXXXX")
    cp "$baseline" "$tmp"
    for f in "$@"; do
        [ -f "$f" ] || continue
        h=$(sha256sum "$f" | awk '{ print $1 }')
        F="$f" H="$h" awk '
            BEGIN { FS = OFS = "\t"; f = ENVIRON["F"]; h = ENVIRON["H"]; found = 0 }
            $1 == f { $2 = h; found = 1 }
            { print }
            END { if (!found) print f, h }
        ' "$tmp" > "$tmp.new"
        mv -f "$tmp.new" "$tmp"
    done
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$baseline"
    log "rehashed the rotated file(s) in the spend baseline"
}

# --- preflight --------------------------------------------------------------
require_healthy() { # container...
    local c st
    command -v podman >/dev/null 2>&1 || die "podman is required"
    for c in "$@"; do
        podman container exists "$c" 2>/dev/null \
            || die "$c has not been deployed; run ./deploy.sh first"
        st=$(podman ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null || true)
        case "$st" in
            *"(healthy)"*) ;;
            *)
                if [ "$FORCE" = 1 ]; then
                    warn "$c is not healthy (${st:-not running}); continuing (--force)"
                    continue
                fi
                die "$c is not healthy (${st:-not running}); fix it first, or --force"
                ;;
        esac
    done
    # A nightly backup taken mid-rotation would carry one side of a credential
    # pair. The restore would recover a config that cannot open what it points
    # at, which is worse than waiting.
    if [ "$FORCE" = 0 ] && systemctl --user is-active --quiet backup.service 2>/dev/null; then
        die "a backup is running right now; a snapshot taken mid-rotation is not restorable. Wait for it (systemctl --user status backup.service), or --force"
    fi
    command -v systemctl >/dev/null 2>&1 || die "systemctl is required (rootless podman user units)"
}

# An authenticated tool call that actually worked: mcp_call's exit status is
# curl's, and a JSON-RPC error answers 200, so the body has to be inspected.
mcp_ok() { # container token tool args
    local c="$1" token="$2" tool="$3" args="$4" body
    [ -n "$token" ] || return 1
    body=$(mcp_call "$c" "$token" "$tool" "$args" 30 2>/dev/null || true)
    [ -n "$(mcp_result_raw "$body")" ]
}

# What must be healthy before a target runs. Kept out of the apply functions so
# a refusal happens before anything is written: "bitcoind is unhealthy" must not
# leave a half-applied credential behind.
preflight_target() { # target
    case "$1" in
        bitcoin-rpc) require_healthy bitcoind ;;
        tor-control) require_healthy tor lightningd ;;
        runes)       require_healthy lightningd ;;
        token:*)     require_healthy "${1#token:}" ;;
        searxng-secret) require_healthy searxng ;;
        postgres)    require_healthy postgres ;;
        boltmesh-keys)
            require_healthy boltmesh-backend
            if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
                die "this ends every BoltMesh session and invalidates every node token; re-run with --yes"
            fi
            ;;
        restic)
            [ -f "$BACKUP_ENV" ] || die "missing $BACKUP_ENV; run deploy/install.sh first"
            if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
                die "the restic password is the only key to the backups; re-run with --yes"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# target: bitcoin-rpc
# ---------------------------------------------------------------------------
verify_bitcoin_rpc() {
    local token
    [ "$DRY_RUN" = 0 ] || return 0
    token=$(env_value "$CONFIG_DIR/bitcoin-node-mcp/token.env" BITCOIN_MCP_TOKEN)
    if mcp_ok bitcoin-node-mcp "$token" get_blockchain_info '{}'; then
        log "bitcoin-node-mcp answers get_blockchain_info with the new RPC credentials"
    else
        die "bitcoin-node-mcp did not answer with the new credentials; check: podman logs bitcoin-node-mcp"
    fi
    if [ -n "$(electrum_tip 50001)" ]; then
        log "Fulcrum serves its Electrum tip with the new credentials"
    else
        warn "Fulcrum is not answering yet (its index may still be starting); check: podman logs fulcrum"
    fi
    if lightning_cli getinfo >/dev/null 2>&1; then
        log "lightningd's bcli is talking to bitcoind"
    else
        warn "lightningd is not answering; check: podman logs lightningd"
    fi
}

apply_bitcoin_rpc() {
    local pass user rpcuser_old=""
    pass=$(gen)
    if [ "$ROTATE_USER" = 1 ]; then
        user="u$(rand_hex | cut -c1-12)"
    else
        user=$(env_value "$SECRETS_FILE" BITCOIN_RPC_USER)
        [ -n "$user" ] || die "no BITCOIN_RPC_USER in $SECRETS_FILE; run deploy/install.sh first"
    fi
    if [ "$DRY_RUN" = 0 ]; then
        rpcuser_old=$(bitcoind_conf_value rpcuser)
    fi
    if [ -n "$rpcuser_old" ] && [ "$rpcuser_old" != "$user" ]; then
        edit_bitcoin_conf rpcuser "$user"
    fi

    edit_bitcoin_conf rpcpassword "$pass"

    set_env_key "$SECRETS_FILE" BITCOIN_RPC_USER "$user"
    set_env_key "$SECRETS_FILE" BITCOIN_RPC_PASSWORD "$pass"
    set_env_key "$CONFIG_DIR/bitcoin-node-mcp/upstream.env" BITCOIN_RPC_USER "$user"
    set_env_key "$CONFIG_DIR/bitcoin-node-mcp/upstream.env" BITCOIN_RPC_PASSWORD "$pass"
    set_env_key_if_file "$CONFIG_DIR/btc-explorer/btc-explorer.env" BTCEXP_BITCOIND_USER "$user"
    set_env_key_if_file "$CONFIG_DIR/btc-explorer/btc-explorer.env" BTCEXP_BITCOIND_PASS "$pass"

    install_rerender

    # bitcoind reads bitcoin.conf at start, so it always goes first and always
    # restarts: no probe can prove what the running process will read next.
    restart_unit_and_wait bitcoind "$BITCOIND_WAIT"

    restart_if_stale lightningd argv "--bitcoin-rpcpassword=$pass"
    restart_if_stale fulcrum argv "$pass"
    restart_if_stale bitcoin-node-mcp env "BITCOIN_RPC_PASSWORD=$pass"
    restart_if_stale btc-explorer env "BTCEXP_BITCOIND_PASS=$pass"

    verify_bitcoin_rpc
    complete
}

# ---------------------------------------------------------------------------
# target: tor-control
# ---------------------------------------------------------------------------
verify_tor_control() {
    [ "$DRY_RUN" = 0 ] || return 0
    if lightning_cli getinfo >/dev/null 2>&1; then
        log "lightningd is up with the new Tor control password (statictor re-registered)"
    else
        die "lightningd is not answering; check: podman logs lightningd"
    fi
}

apply_tor_control() {
    local pw hash
    pw=$(gen)
    hash=$(tor_hash "$pw" || true)
    [ -n "$hash" ] || die "could not hash the password: is $TOR_IMAGE built? (deploy/install.sh builds it)"

    set_torrc_hash "$hash"

    set_env_key "$SECRETS_FILE" TOR_SERVICE_PASSWORD "$pw"

    install_rerender

    # tor owns the control port, so it goes first: lightningd cannot register
    # its statictor service while the old hash is live. tor reads torrc (a file,
    # not its argv or environment), so there is nothing to prove about the
    # running process -- it restarts.
    restart_unit_and_wait tor
    restart_if_stale lightningd argv "--tor-service-password=$pw"

    verify_tor_control
    complete
}

# ---------------------------------------------------------------------------
# target: runes
# ---------------------------------------------------------------------------
# A rune is a bearer token: mint it, prove it, swap it in, prove the consumer
# works, and only then blacklist everything that is not the pair -- a failed swap
# that had already destroyed the live rune would leave lightning-mcp unable to read
# the node.
mint_rune() { # restriction-json -> "rune unique_id"
    if [ "$DRY_RUN" = 1 ]; then
        printf 'dryrun 0'
        return 0
    fi
    # The mint -> checkrune -> retry loop is lib.sh's cln_mint_rune, shared with
    # install.sh so the installer and the rotator cannot disagree about what makes
    # a rune usable.
    cln_mint_rune "$1"
}

want_scope() { [ "$RUNE_SCOPE" = all ] || [ "$RUNE_SCOPE" = "$1" ]; }

verify_runes() {
    local token
    [ "$DRY_RUN" = 0 ] || return 0
    token=$(env_value "$CONFIG_DIR/lightning-mcp/token.env" LIGHTNING_MCP_TOKEN)
    if mcp_ok lightning-mcp "$token" getinfo '{}'; then
        log "lightning-mcp answers getinfo with the new rune"
    else
        die "lightning-mcp did not answer; check: podman logs lightning-mcp"
    fi
}

# Revocation is a SET reconciliation, not a remembered id: every live rune whose
# method set is exactly one of stack.conf's must be the pair node.env carries, and
# anything else is a leftover (this run's predecessor, or an older crash). lib.sh
# owns the comparison -- monitor.sh checks the same invariant -- and it is
# restricted to exact method-set matches so a rune minted for something else is
# never touched.
prune_orphan_runes() {
    local node_env="$CONFIG_DIR/lightning-mcp/node.env" keep_read keep_spend orphans id

    keep_read=$(env_value "$node_env" LIGHTNING_RUNE)
    keep_spend=$(env_value "$node_env" LIGHTNING_SPEND_RUNE)

    if [ -z "$keep_read" ] || [ -z "$keep_spend" ]; then
        warn "$node_env does not carry both runes; not blacklisting anything"
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then
        # the pair in node.env now is itself about to be superseded, so this is
        # only the backlog the run already has to clean up.
        orphans=$(cln_orphan_runes "$keep_read" "$keep_spend" 2>/dev/null | cut -f1 | paste -sd, - || true)
        say "would blacklist every other stack rune (orphaned already: ${orphans:-none})"
        return 0
    fi

    if ! orphans=$(cln_orphan_runes "$keep_read" "$keep_spend"); then
        warn "could not read the node's rune list; leaving any superseded rune alone"
        return 0
    fi
    if [ -z "$orphans" ]; then
        say "no other stack rune is live"
        return 0
    fi
    say "blacklisting $(printf '%s\n' "$orphans" | wc -l) superseded stack rune(s): $(printf '%s\n' "$orphans" | cut -f1 | paste -sd, -)"
    while read -r id; do
        [ -n "$id" ] || continue
        if quiet lightning_cli destroyrune "$id" "$id"; then
            say "blacklisted rune id $id"
        else
            warn "could not blacklist rune id $id; do it by hand: podman exec lightningd lightning-cli destroyrune $id $id"
        fi
    done <<< "$(printf '%s\n' "$orphans" | cut -f1)"
}

apply_runes() {
    local node_env="$CONFIG_DIR/lightning-mcp/node.env"
    local new_read="" new_spend="" minted=""
    local do_read=0 do_spend=0

    if want_scope read; then do_read=1; fi
    if want_scope spend; then do_spend=1; fi
    [ "$do_read" = 1 ] || [ "$do_spend" = 1 ] || die "nothing to rotate"
    [ -f "$node_env" ] || die "missing $node_env; run deploy/install.sh first"

    if [ "$do_read" = 1 ]; then
        minted=$(mint_rune "$READ_RESTRICTIONS" || true)
        read -r new_read _ <<< "$minted"
        [ -n "$new_read" ] || die "could not mint a usable read rune"
        set_env_key "$node_env" LIGHTNING_RUNE "$new_read"
    fi
    if [ "$do_spend" = 1 ]; then
        minted=$(mint_rune "$SPEND_RESTRICTIONS" || true)
        read -r new_spend _ <<< "$minted"
        [ -n "$new_spend" ] || die "could not mint a usable spend rune"
        set_env_key "$node_env" LIGHTNING_SPEND_RUNE "$new_spend"
    fi

    # A re-run after a crash finds the runes it is about to write already in the
    # container's environment; restarting for that is a second outage for no
    # reason. Anything unprovable restarts.
    if [ "$DRY_RUN" = 0 ] && podman container exists lightning-mcp 2>/dev/null \
       && container_env_is lightning-mcp "LIGHTNING_RUNE=$(env_value "$node_env" LIGHTNING_RUNE)" \
       && container_env_is lightning-mcp "LIGHTNING_SPEND_RUNE=$(env_value "$node_env" LIGHTNING_SPEND_RUNE)"; then
        log "lightning-mcp already carries these runes; not restarting it"
    else
        restart_if_deployed lightning-mcp
    fi

    verify_runes
    prune_orphan_runes
    rehash_audit "$node_env"
    complete
}


# ---------------------------------------------------------------------------
# target: token:<server>
# ---------------------------------------------------------------------------
# The MCP bearer tokens are the stack's most-copied secret: every client config
# holds one. Rotating has two halves -- the server's token.env and, for the client,
# a pointer at that file (the value is never printed; ~/.config/opencode/mcp.env
# reads it from there at shell start). The targets and their token specs are the
# manifest's [mcp.*] table, emitted as index-aligned arrays: MCP_CONTAINERS /
# PROBE_TOKEN_VARS / PROBE_TOOLS / PROBE_ARGS / PROBE_SPEND_VARS. The token file is
# $CONFIG_DIR/<container>/token.env by convention, exactly as verify.sh reads it.
TOKEN_SERVERS=(${MCP_CONTAINERS[@]+"${MCP_CONTAINERS[@]}"})

# The index of a server in those columns, or non-zero when it is not declared.
# One lookup serves every field, because the columns are aligned.
probe_index() { # server -> index
    local i
    for i in "${!MCP_CONTAINERS[@]}"; do
        [ "${MCP_CONTAINERS[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

# A bearer token is the endpoint's own credential, and the server holds exactly
# one: proving the NEW token answers is therefore the whole rotation. There is
# no "the old one is refused" probe, because by the time the file is rewritten
# the old value is gone from the host -- and a server with one token cannot
# accept it (see the header).
verify_token() { # server envfile readvar tool args [spend]
    local server="$1" envf="$2" readvar="$3" tool="$4" args="$5" spend="${6:-0}"
    local token
    [ "$DRY_RUN" = 0 ] || return 0
    token=$(env_value "$envf" "$readvar")
    if mcp_ok "$server" "$token" "$tool" "$args"; then
        log "$server answers $tool with the new token"
    else
        die "$server did not answer with the new token; check: podman logs $server"
    fi
    if [ "$spend" = 1 ]; then
        # A spend token is only checked by a spend tool, which this must never
        # call. The proof here is the restart plus the read path above: the
        # server reloaded its env and still serves. Prove the token itself on a
        # host that deliberately turns ENABLE_SPENDING on.
        say "the spend token itself is only exercised by a spend call; not attempted"
    fi
}

apply_token() {
    local server="$1" i envf readvar tool args spendvar var new
    i=$(probe_index "$server") \
        || die "no bearer token for '$server' (servers: ${TOKEN_SERVERS[*]})"
    envf="$CONFIG_DIR/$server/token.env"
    readvar="${PROBE_TOKEN_VARS[$i]}"
    tool="${PROBE_TOOLS[$i]}"
    args="${PROBE_ARGS[$i]}"
    spendvar="${PROBE_SPEND_VARS[$i]}"
    [ -f "$envf" ] || die "missing $envf; run deploy/install.sh first"

    var="$readvar"
    if [ "$SPEND_ONLY" = 1 ]; then
        [ -n "$spendvar" ] || die "$server has no spend token (only monero-wallet-mcp and lightning-mcp do)"
        var="$spendvar"
    fi

    new=$(gen)
    set_env_key "$envf" "$var" "$new"

    restart_if_stale "$server" env "$var=$new"

    verify_token "$server" "$envf" "$readvar" "$tool" "$args" "$SPEND_ONLY"

    # token.env of the two money servers is hash-baselined by spend-audit.
    rehash_audit "$envf"
    complete
}

# ---------------------------------------------------------------------------
# target: searxng-secret
# ---------------------------------------------------------------------------
# settings.yml is seeded once (install.sh only copies it when it is missing), so
# the key is replaced in place. Only the `secret_key:` line is touched; it signs
# the limiter's sessions, so the visible effect of a rotation is that existing
# rate-limit state is dropped.
set_searxng_secret() { # value
    local v="$1" f="$SEARXNG_DATA_DIR/settings.yml" tmp
    [ -f "$f" ] || die "missing $f; run deploy/install.sh first"
    if [ "$DRY_RUN" = 1 ]; then say "would set secret_key in $f"; return 0; fi
    # $DATA_DIR/searxng belongs to the image uid, so a temp file cannot be
    # created beside the file (mktemp -> EACCES) even though settings.yml itself
    # is the host user's. Build the new content in the 0700 rotation dir instead
    # and write the existing file in place (cat >, so the inode keeps its mode).
    tmp=$(mktemp "$ROT_DIR/.settings.XXXXXX")
    if ! V="$v" awk '
        BEGIN { v = ENVIRON["V"]; found = 0 }
        /^[[:space:]]+secret_key:/ { print "  secret_key: \"" v "\""; found = 1; next }
        { print }
        END { if (!found) { print "no secret_key: line in settings.yml" > "/dev/stderr"; exit 1 } }
    ' "$f" > "$tmp"; then
        rm -f "$tmp"
        die "could not rewrite $f"
    fi
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

apply_searxng_secret() {
    local new code
    new=$(gen)

    set_searxng_secret "$new"

    restart_unit_and_wait searxng

    if [ "$DRY_RUN" = 0 ]; then
        code=$(net_curl -s -o /dev/null -w '%{http_code}' -m 10 http://searxng:8080/ 2>/dev/null || true)
        if [ "$code" = 200 ]; then
            log "searxng serves its front page with the new secret_key"
        else
            die "searxng answered $code; check: podman logs searxng"
        fi
    fi
    complete
}

# ---------------------------------------------------------------------------
# target: postgres
# ---------------------------------------------------------------------------
# The role's password lives in the cluster, not in a file: db.env and dump.env
# carry the client's copy of it. So the ALTER comes first and the files follow --
# a crash in between leaves the running backend working (it already
# authenticated) and the next ./deploy.sh restarting it into a failure, which
# re-running this target fixes: it ALTERs again and rewrites every copy.
pg_sql() { # sql on stdin, against the stack's own database
    podman exec -i postgres psql -U vpnuser -d postgres -v ON_ERROR_STOP=1 -q
}

# Log in as vpnuser with an explicitly supplied password, from the container's
# podman-network address. NOT over 127.0.0.1: the postgres image's pg_hba trusts
# loopback (`host all all 127.0.0.1/32 trust`), so a probe there succeeds with
# any password and proves nothing. The password goes in on stdin, never an argv.
pg_tcp_login() { # password -> 0 when it authenticates
    local out
    out=$(printf '%s\n' "$1" | podman exec -i postgres sh -c \
        'PGPASSWORD=$(cat) psql -h "$(hostname -i)" -U vpnuser -d vpndb -tAc "select 1"' 2>/dev/null || true)
    [ "$(printf '%s' "$out" | tr -d '[:space:]')" = 1 ]
}

verify_postgres() {
    local new
    new=$(env_value "$BOLT_DIR/db.env" POSTGRES_PASSWORD)
    [ "$DRY_RUN" = 0 ] || return 0
    if pg_tcp_login "$new"; then
        log "vpnuser authenticates over the podman network with the new password"
    else
        die "vpnuser did not authenticate with the password in $BOLT_DIR/db.env; re-run this target"
    fi
    if podman container exists boltmesh-backend 2>/dev/null; then
        if net_curl -fsS http://boltmesh-backend:8000/health >/dev/null 2>&1; then
            log "boltmesh-backend is healthy on the new DATABASE_URL"
        else
            warn "boltmesh-backend is not healthy yet; check: podman logs boltmesh-backend"
        fi
    fi
}

apply_postgres() {
    local new
    new=$(gen)
    [ -n "$(env_value "$BOLT_DIR/db.env" POSTGRES_PASSWORD)" ] \
        || die "no POSTGRES_PASSWORD in $BOLT_DIR/db.env; run deploy/install.sh first"

    if [ "$DRY_RUN" = 1 ]; then
        say "would set vpnuser's password at postgres (ALTER ROLE ... PASSWORD)"
    else
        if ! printf "BEGIN;\nALTER ROLE vpnuser PASSWORD '%s';\nCOMMIT;\n" "$new" | pg_sql; then
            die "psql refused the password change; nothing was written"
        fi
        log "the vpnuser role carries the new password"
    fi

    # The role is authoritative, so the files only ever have to catch up with it;
    # a re-run rewrites all three and ALTERs again.
    set_env_key "$BOLT_DIR/db.env" POSTGRES_PASSWORD "$new"
    set_env_key "$BOLT_DIR/db.env" DATABASE_URL "postgresql+asyncpg://vpnuser:$new@postgres:5432/vpndb"
    set_env_key_if_file "$BOLT_DIR/dump.env" PGPASSWORD "$new"

    # postgres itself only uses POSTGRES_PASSWORD on an empty cluster, but the
    # restart keeps podman inspect agreeing with the role it serves.
    restart_unit_and_wait postgres "${POSTGRES_WAIT:-180}"

    restart_if_stale boltmesh-backend env "DATABASE_URL=postgresql+asyncpg://vpnuser:$new@postgres:5432/vpndb"
    restart_if_deployed boltmesh-worker

    verify_postgres
    say "the next backup's pg_dumpall carries the new hash; a dump taken before this rotation would restore the old one"
    complete
}

# ---------------------------------------------------------------------------
# target: boltmesh-keys
# ---------------------------------------------------------------------------
# The JWT signing keys and the node-bootstrap pepper. Regenerating them is a
# deliberate, user-visible act: every session ends and every node token minted
# from NODE_SECRET_KEY/BOOTSTRAP_SECRET_PEPPER stops verifying.
apply_boltmesh_keys() {
    local f="$BOLT_DIR/secrets.env" k v secret_key=""
    [ -f "$f" ] || die "missing $f; run deploy/install.sh first"
    for k in SECRET_KEY REFRESH_SECRET_KEY NODE_SECRET_KEY BOOTSTRAP_SECRET_PEPPER; do
        v=$(gen)
        [ "$k" = SECRET_KEY ] && secret_key="$v"
        set_env_key "$f" "$k" "$v"
    done

    restart_if_stale boltmesh-backend env "SECRET_KEY=$secret_key"
    restart_if_deployed boltmesh-worker

    if [ "$DRY_RUN" = 0 ]; then
        if net_curl -fsS http://boltmesh-backend:8000/health >/dev/null 2>&1; then
            log "boltmesh-backend is healthy with the new keys"
        else
            die "boltmesh-backend did not come back; check: podman logs boltmesh-backend"
        fi
    fi
    complete
}

# ---------------------------------------------------------------------------
# target: restic
# ---------------------------------------------------------------------------
# The one secret whose loss loses the backups. The order is what makes a re-run
# safe, and it is a write-ahead, not a journal:
#
#   1. RESTIC_PASSWORD_NEXT goes into backup.env BEFORE the repository learns the
#      password, so the value is durable on disk first;
#   2. the key is added only if that password does not already open the repo (a
#      re-run after 'key add' must not add a second one);
#   3. the new key must read the repository;
#   4. it is promoted to RESTIC_PASSWORD and the transient key removed;
#   5. every superseded key is removed, so the repo ends with exactly one.
#
# A crash between any two steps is finished by running the target again.
restic_run() { # restic args...
    local repo cache
    repo=$(env_value "$BACKUP_ENV" RESTIC_REPOSITORY)
    cache=$(env_value "$BACKUP_ENV" RESTIC_CACHE_DIR)
    [ -n "$repo" ] || die "no RESTIC_REPOSITORY in $BACKUP_ENV"
    podman run --rm -i \
        -v "$STACK_BACKUP_DIR:/repo:z" \
        -v "$DATA_DIR/backup-cache:/cache:z" \
        -v "$ROT_DIR:/rot:z" \
        --env RESTIC_CACHE_DIR="${cache:-/cache}" \
        "$RESTIC_IMAGE" --repo "$repo" "$@"
}

restic_write_passwords() { # current new
    # -p/--password-file on the command line would be fine (a path is not a
    # secret), but the VALUES have to reach the container somehow: a 0600 file
    # in the 0700 rotation dir, mounted at /rot, keeps them out of any argv.
    ( umask 077
      printf '%s\n' "$1" > "$ROT_DIR/.current.pw"
      printf '%s\n' "$2" > "$ROT_DIR/.new.pw" )
}

restic_cleanup() {
    rm -f "$ROT_DIR/.current.pw" "$ROT_DIR/.new.pw"
}

# Drop every key the repository still holds that is not the one this run proved,
# so "the credential is dead" is true of the old key rather than aspirational.
prune_restic_keys() {
    local list ids id total removed=0
    command -v jq >/dev/null 2>&1 || { warn "jq missing; skipped removing the superseded restic key"; return 0; }
    if ! list=$(restic_run key list --json --password-file /rot/.new.pw 2>/dev/null); then
        warn "could not list the repository's keys; check: restic key list"
        return 0
    fi
    total=$(printf '%s' "$list" | jq 'length' 2>/dev/null || echo "")
    ids=$(printf '%s' "$list" | jq -r '.[] | select(.current|not) | .id' 2>/dev/null || true)
    for id in $ids; do
        if restic_run key remove "$id" --password-file /rot/.new.pw >/dev/null 2>&1; then
            removed=$(( removed + 1 ))
            say "removed the superseded restic key $id"
        else
            warn "could not remove the superseded restic key $id; remove it by hand: restic key remove $id"
        fi
    done
    if [ -n "$total" ]; then
        total=$(( total - removed ))
        [ "$total" = 1 ] || warn "the repository reports $total key(s) left; check: restic key list"
    fi
}

apply_restic() {
    local cur new
    cur=$(env_value "$BACKUP_ENV" RESTIC_PASSWORD)
    [ -n "$cur" ] || die "no RESTIC_PASSWORD in $BACKUP_ENV; run deploy/install.sh first"

    if [ "$DRY_RUN" = 1 ]; then
        say "would write RESTIC_PASSWORD_NEXT to $BACKUP_ENV (durable before the repo learns it)"
        say "would add a restic key unless that password already opens the repository"
        say "would prove it reads the repository (restic snapshots), promote it to RESTIC_PASSWORD"
        say "and remove every superseded key"
        complete
        return 0
    fi

    # A value left behind by an interrupted run is reused, not replaced: it may
    # already be a key in the repository.
    new=$(env_value "$BACKUP_ENV" RESTIC_PASSWORD_NEXT)
    if [ -z "$new" ]; then
        new=$(gen)
        set_env_key "$BACKUP_ENV" RESTIC_PASSWORD_NEXT "$new"
    fi
    restic_write_passwords "$cur" "$new"

    if restic_run key list --json --password-file /rot/.new.pw >/dev/null 2>&1; then
        log "the pending restic key already opens the repository; not adding another"
    else
        if ! restic_run key list --json --password-file /rot/.current.pw >/dev/null 2>&1; then
            restic_cleanup
            # Neither password opens the repository, so the NEXT written above
            # can never have become a key: drop it rather than leave the file
            # pointing at two dead values.
            unset_env_key "$BACKUP_ENV" RESTIC_PASSWORD_NEXT
            die "neither RESTIC_PASSWORD nor RESTIC_PASSWORD_NEXT in $BACKUP_ENV opens the repository; fix it by hand (restic key list)"
        fi
        restic_run key add --password-file /rot/.current.pw --new-password-file /rot/.new.pw >/dev/null \
            || { restic_cleanup; die "restic refused the new key; the repository is unchanged"; }
    fi

    if ! restic_run snapshots --latest 1 --password-file /rot/.new.pw >/dev/null 2>&1; then
        # Two keys are alive here, so this is recoverable: re-run the target.
        restic_cleanup
        die "the new key cannot read the repository; the old key is still valid -- re-run the target"
    fi
    log "the new restic key opens the repository"

    set_env_key "$BACKUP_ENV" RESTIC_PASSWORD "$new"
    prune_restic_keys
    unset_env_key "$BACKUP_ENV" RESTIC_PASSWORD_NEXT
    restic_cleanup

    say "if RESTIC_PASSWORD is exported in your shell, update it: the environment wins over backup.env"
    complete
}

# The newest restic snapshot's age in hours (empty when it cannot be read).
# status_verdict's sibling in scripts/lib.sh owns the read, so the rotator and
# scripts/monitor.sh cannot disagree about how old the last backup is.
backup_age_h() {
    local summary epoch
    summary=$(restic_snapshot_summary) || return 1
    epoch=${summary#*$'\t'}
    [ -n "$epoch" ] || return 1
    printf '%s' $(( ($(date +%s) - epoch) / 3600 ))
}

# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------
complete() {
    local changed unexpected u now
    if [ "$DRY_RUN" = 1 ]; then
        log "dry run complete for $TARGET; nothing was written and nothing was restarted"
        return 0
    fi
    # A rotation that re-rendered through install.sh has to advance the applied-unit
    # baseline, or the next ./deploy.sh would restart the units this run just
    # restarted (and verify.sh would report drift until it did). install.sh
    # re-renders *every* unit, so commit only when the definitions that changed are
    # ones this rotation restarted or proved current; anything else was never
    # applied and must stay visible to the next deploy.
    if [ "$RERENDERED" = 1 ]; then
        now=$(unit_digest)
        changed=$(unit_digest_changed "$UNITS_BEFORE" "$now")
        unexpected=""
        for u in $changed; do
            case "$APPLIED_UNITS" in *" $u "*) ;; *) unexpected="$unexpected $u" ;; esac
        done
        if [ -n "$unexpected" ]; then
            warn "the re-render also changed$unexpected, which this rotation did not restart; leaving the applied-unit baseline alone -- run ./deploy.sh to apply them"
        else
            unit_digest_write "$DATA_DIR/audit/units.applied" "$now"
        fi
    fi
    record_rotation "$TARGET" ok
    log "$TARGET rotated"
    if [ "$TARGET" = runes ]; then
        say "lightning-mcp reads its rune from node.env; nothing else to update"
    fi
}

cmd_status() {
    local leftover orphans keep_read keep_spend btc_conf_pw btc_env_pw
    printf '==> credential invariants\n'

    # A journal from an older version of this script is inert -- nothing reads
    # it -- but it is also the only hint that a rotation was interrupted before
    # this version existed, so it is named rather than ignored.
    if compgen -G "$ROT_DIR/*.pending" >/dev/null; then
        printf '  stale journal(s) from an older version (nothing reads them):\n'
        for leftover in "$ROT_DIR"/*.pending; do
            printf '    %s\n' "$(basename "$leftover")"
        done
        printf '  delete them once you have re-run the target they name.\n'
    else
        printf '  no stale journal\n'
    fi

    # The runes: exactly the pair node.env carries may be live. This is the same
    # check scripts/monitor.sh pages on, including its refusal to judge a host
    # whose node.env has no pair to compare against.
    if podman container exists lightningd 2>/dev/null; then
        keep_read=$(env_value "$CONFIG_DIR/lightning-mcp/node.env" LIGHTNING_RUNE)
        keep_spend=$(env_value "$CONFIG_DIR/lightning-mcp/node.env" LIGHTNING_SPEND_RUNE)
        if [ -z "$keep_read" ] || [ -z "$keep_spend" ]; then
            printf '  runes: node.env carries no rune pair; skipped the check\n'
        elif cln_live_runes >/dev/null; then
            orphans=$(cln_orphan_runes "$keep_read" "$keep_spend" 2>/dev/null || true)
            if [ -z "$orphans" ]; then
                printf '  runes: only the pair in node.env is live\n'
            else
                printf '  runes: %s live rune(s) the stack does not reference: %s\n' \
                    "$(printf '%s\n' "$orphans" | wc -l)" \
                    "$(printf '%s\n' "$orphans" | cut -f1 | paste -sd, -)"
                printf '  a runes rotation blacklists them; or: podman exec lightningd lightning-cli destroyrune <id> <id>\n'
            fi
        else
            printf '  runes: could not read showrunes (is lightningd healthy?)\n'
        fi
    else
        printf '  runes: lightningd is not deployed\n'
    fi

    # bitcoind's own file and the copy every client reads: the two the
    # bitcoin-rpc target moves together, compared the way the monitor compares
    # them.
    btc_conf_pw=$(bitcoind_conf_password)
    btc_env_pw=$(env_value "$SECRETS_FILE" BITCOIN_RPC_PASSWORD)
    if [ -z "$btc_conf_pw" ] || [ -z "$btc_env_pw" ]; then
        printf '  bitcoin RPC password: could not read both copies; skipped the check\n'
    elif [ "$btc_conf_pw" = "$btc_env_pw" ]; then
        printf '  bitcoin RPC password: bitcoin.conf and secrets.env agree\n'
    else
        printf '  bitcoin RPC password: bitcoin.conf and secrets.env DISAGREE; re-run: ./scripts/rotate.sh bitcoin-rpc\n'
    fi

    printf '==> recent rotations (%s)\n' "$DATA_DIR/audit/rotation.log"
    if [ -s "$DATA_DIR/audit/rotation.log" ]; then
        tail -n 10 "$DATA_DIR/audit/rotation.log" | sed 's/^/  /'
    else
        printf '  none\n'
    fi
}

if [ "${STATUS:-0}" = 1 ]; then
    cmd_status
    exit 0
fi

[ -n "$TARGET" ] || die "no target; try --list"
case "$TARGET" in
    bitcoin-rpc|tor-control|runes|searxng-secret|postgres|boltmesh-keys|restic) ;;
    token:*)
        probe_index "${TARGET#token:}" >/dev/null \
            || die "unknown server '${TARGET#token:}' (servers: ${TOKEN_SERVERS[*]})"
        ;;
    *) die "unknown target: $TARGET (try --list)" ;;
esac
if [ "$SPEND_ONLY" = 1 ]; then
    case "$TARGET" in
        token:*) ;;
        *) die "--spend only applies to token:<server>" ;;
    esac
fi
preflight_target "$TARGET"
printf '==> rotating %s\n' "$TARGET"
if [ "$DRY_RUN" = 1 ]; then
    say "(dry run: nothing is written and no secret is generated for real)"
else
    # The scratch dir held the journal in the version that had one; nothing else
    # creates it now, and the restic password files and the searxng rewrite both
    # need a 0700 directory a container can be handed.
    mkdir -p "$ROT_DIR"
    chmod 700 "$ROT_DIR"
fi
STARTED=1
# Read before any target edits or re-renders: complete() compares this with the
# state after the rotation to decide what it is allowed to record as applied.
UNITS_BEFORE=$(units_baseline)

case "$TARGET" in
    bitcoin-rpc) apply_bitcoin_rpc ;;
    tor-control) apply_tor_control ;;
    runes)       apply_runes ;;
    token:*)     apply_token "${TARGET#token:}" ;;
    searxng-secret) apply_searxng_secret ;;
    postgres)       apply_postgres ;;
    boltmesh-keys)  apply_boltmesh_keys ;;
    restic)         apply_restic ;;
    *)           die "unknown target: $TARGET (try --list)" ;;
esac
