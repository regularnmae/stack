#!/usr/bin/env bash
# Rotate one credential and update every service that depends on it.
#
#   scripts/rotate.sh --list                     # targets, what each one touches
#   scripts/rotate.sh --status                   # pending journal + recent runs
#   scripts/rotate.sh <target> --dry-run         # the plan, no values, no writes
#   scripts/rotate.sh <target>                   # rotate, re-render, restart, verify
#   scripts/rotate.sh --resume                   # finish an interrupted rotation
#
# Targets (phase 1: the credentials whose consumers are all inside the stack):
#
#   bitcoin-rpc    bitcoind's RPC password (and --user, its RPC user). Touches
#                  bitcoin.conf, stack/secrets.env, the rendered lightningd and
#                  fulcrum units, bitcoin-node-mcp/upstream.env and
#                  btc-explorer/btc-explorer.env.
#   monero-rpc     monero-wallet-rpc's --rpc-login. Touches stack/secrets.env,
#                  the rendered wallet unit, monero-wallet-mcp/upstream.env and
#                  (through the re-render) boltmesh/gateway.env.
#   tor-control    Tor's control password, which lightningd uses for its
#                  statictor onion service. Touches torrc's hash and the
#                  rendered lightningd unit. The onion address does not change.
#   runes          Core Lightning runes (lightning-mcp's read/spend pair and
#                  BoltMesh's gateway rune): mint, swap, verify, THEN blacklist
#                  the old ones. --scope read|spend|boltmesh|all (default all).
#   token:<server> one MCP server's bearer token (token.env) -- the credential
#                  with the most copies outside the stack. --spend rotates the
#                  additional spend token of a money server instead.
#   searxng-secret SearXNG's settings.yml secret_key (limiter/session signing).
#   monero-wallet  the wallet FILE's password: change_wallet_password at the
#                  daemon, then the rendered unit and secrets.env. --yes
#                  required and a recent backup demanded: this is the one value
#                  that cannot be recovered if it is lost.
#
# Why this is not "rewrite the env file and restart": part of each credential
# lives in a file install.sh seeds ONCE and never rewrites -- bitcoind's own
# bitcoin.conf, tor's torrc with its hashed password, and the per-app
# upstream/explorer env files -- so the source of truth and the copy the daemon
# is actually using have to be moved together, in an order that leaves a re-run
# able to finish. Hence: write the files, re-render through deploy/install.sh
# (the only installer), restart the dependents in dependency order, verify, and
# only then revoke anything (destroyrune, the old password in bitcoin.conf).
#
# Crash safety: every new value is journaled under $DATA_DIR/config/rotation/
# (mode 600) BEFORE it is applied, and the stage is rewritten as the run
# advances. A run that dies half-way leaves that file behind -- `--status` says
# where it stopped, `--resume` finishes with the SAME values instead of minting
# new ones. That matters most for a credential that only exists inside a run:
# a fresh run would otherwise leave nobody knowing which password is live.
#
# Nothing here is scheduled. These tokens have consumers outside the stack
# (opencode's MCP config, a wallet, nginx-proxy-manager), and rotating one on a
# timer would break them silently at 3am. A rotation is an operator action; the
# entry it leaves in $DATA_DIR/audit/rotation.log is the record (never a value).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
FORCE=0
RESUME=0
ROTATE_USER=0
ASSUME_YES=0
SPEND_ONLY=0
RUNE_SCOPE="all"
TARGET=""
JOURNAL=""
# 1 once this run has actually created (or adopted) a journal: the EXIT trap
# must not report a refusal-to-start as a failed rotation.
STARTED=0

# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

BITCOIND_WAIT="${BITCOIND_WAIT:-600}"
MONERO_WALLET_WAIT="${MONERO_WALLET_WAIT:-300}"
LN_WAIT="${LN_WAIT:-300}"
APP_HEALTH_WAIT="${APP_HEALTH_WAIT:-180}"

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --list)     LIST=1; shift ;;
        --status)   STATUS=1; shift ;;
        --resume)   RESUME=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --force)    FORCE=1; shift ;;
        --user)     ROTATE_USER=1; shift ;;
        --yes)      ASSUME_YES=1; shift ;;
        --spend)    SPEND_ONLY=1; shift ;;
        --scope)    RUNE_SCOPE="${2:?--scope needs read|spend|boltmesh|all}"; shift 2 ;;
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
  monero-rpc     monero-wallet-rpc --rpc-login -> secrets.env, wallet unit,
                 monero-wallet-mcp, boltmesh gateway/env
  tor-control    Tor control password -> torrc hash, secrets.env, lightningd
                 (the onion address is unchanged)
  runes          CLN runes -> lightning-mcp/node.env, boltmesh/gateway.env;
                 the old runes are blacklisted only after the new ones work
                 (--scope read|spend|boltmesh|all, default all)
  token:<server> one MCP bearer token (token.env), then prove the new one works
                 and the old one is refused; --spend rotates the spend token of
                 monero-wallet-mcp/lightning-mcp instead of the read token
                 servers: searxng-mcp bitcoin-node-mcp monero-node-mcp
                          monero-wallet-mcp lightning-mcp
  searxng-secret SearXNG's settings.yml secret_key
  monero-wallet  the wallet file's password (--yes; demands a recent backup)

flags: --dry-run (print the plan)  --force (ignore preflight, e.g. a running
backup)  --resume (finish a pending journal)  --yes  --spend  --status  --list
EOF
    exit 0
fi

resolve_data_dir
SECRETS_FILE="$CONFIG_DIR/stack/secrets.env"
SEARXNG_DATA_DIR="$DATA_DIR/searxng"
ROT_DIR="$CONFIG_DIR/rotation"

# The rune restriction JSON, built from the allowlists stack.conf declares --
# the same source deploy/install.sh mints from, so a rotation cannot hand out a
# wider (or narrower) rune than a fresh install would.
if [ "${CLN_READ_METHODS+x}" != x ] || [ "${#CLN_READ_METHODS[@]}" -eq 0 ] \
    || [ "${BOLTMESH_RUNE_METHODS+x}" != x ]; then
    die "stack.conf must declare CLN_READ_METHODS, CLN_SPEND_METHODS and BOLTMESH_RUNE_METHODS"
fi
READ_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}")
SPEND_RESTRICTIONS=$(rune_json "${CLN_READ_METHODS[@]}" "${CLN_SPEND_METHODS[@]}")
BOLTMESH_RESTRICTIONS=$(rune_json "${BOLTMESH_RUNE_METHODS[@]}")

case "$RUNE_SCOPE" in
    read|spend|boltmesh|all) ;;
    *) die "--scope must be read, spend, boltmesh or all" ;;
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

# --- the journal -----------------------------------------------------------
journal_path() { printf '%s/%s.pending' "$ROT_DIR" "$1"; }

journal_get() { env_value "$JOURNAL" "$1"; }

# Rewrite one key of the journal atomically (the file is the only record of a
# value that may already be live in a daemon, so it is never truncated in place).
journal_put() { # key value
    local key="$1" val="$2" tmp
    [ -n "$JOURNAL" ] || return 0
    [ "$DRY_RUN" = 0 ] || return 0
    mkdir -p "$ROT_DIR"
    chmod 700 "$ROT_DIR"
    tmp=$(mktemp "${JOURNAL}.XXXXXX")
    if [ -f "$JOURNAL" ]; then
        grep -v "^${key}=" "$JOURNAL" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$JOURNAL"
}

journal_begin() { # target
    JOURNAL=$(journal_path "$1")
    printf '==> rotating %s\n' "$1"
    if [ "$DRY_RUN" = 1 ]; then
        say "(dry run: nothing is written and no secret is generated for real)"
        return 0
    fi
    mkdir -p "$ROT_DIR"
    chmod 700 "$ROT_DIR"
    if [ -s "$JOURNAL" ]; then
        die "a rotation of $1 is already pending (step: $(journal_get step)); finish it with ./scripts/rotate.sh --resume"
    fi
    printf 'target=%s\nstarted=%s\nstep=begin\n' "$1" "$(date -Is)" > "$JOURNAL"
    chmod 600 "$JOURNAL"
    STARTED=1
}

journal_clear() {
    if [ "$DRY_RUN" = 0 ] && [ -n "$JOURNAL" ]; then
        rm -f "$JOURNAL"
    fi
    return 0
}

# The value for a journal key: reuse the pending one (a --resume must not mint
# anything new), else generate. Hex only -- these values end up in a systemd
# Exec= line, which is split on whitespace and never shell-quoted.
gen() { # journal-key [prefix]
    local key="$1" prefix="${2:-}" v
    v=$(journal_get "$key")
    if [ -z "$v" ]; then
        v="${prefix}$(rand_hex)"
        journal_put "$key" "$v"
    fi
    printf '%s' "$v"
}

# --- file writers (atomic, keep mode, never print a value) ------------------
# Set KEY=value in an env file in place (keeps comments, order and mode; appends
# when the key is absent). awk gets the values through the environment so a
# value is never re-interpreted as awk -v escapes.
set_env_key() { # file key value
    local f="$1" k="$2" v="$3" tmp mode
    [ -f "$f" ] || die "missing $f; run deploy/install.sh first"
    if [ "$DRY_RUN" = 1 ]; then say "would set $k in $f"; return 0; fi
    mode=$(stat -c %a "$f")
    tmp=$(mktemp "$(dirname "$f")/.rot.XXXXXX")
    K="$k" V="$v" awk '
        BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$f" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$f"
}

set_env_key_if_file() { # file key value
    [ -f "$1" ] || { say "no $1; not deployed, skipping $2"; return 0; }
    set_env_key "$@"
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
# touched: the onion-service block at the end of the file belongs to
# ONION_SERVICES and the SocksPolicy lines are hand-written.
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
}

restart_unit_and_wait() { # container [timeout]
    local c="$1" t="${2:-$APP_HEALTH_WAIT}"
    run_step "restart $c" systemctl --user restart "$c.service"
    if ! wait_healthy "$c" "$t"; then
        die "$c did not report healthy; finish the rotation with ./scripts/rotate.sh --resume"
    fi
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
    if [ "$rc" -ne 0 ] && [ "$STARTED" = 1 ] && [ -n "$JOURNAL" ] && [ -s "$JOURNAL" ]; then
        record_rotation "$TARGET" failed "step=$(journal_get step)"
        warn "the rotation of $TARGET did not finish (journal: $JOURNAL)"
        warn "finish it with the same values: ./scripts/rotate.sh --resume"
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
    printf '%s' "$body" | grep -q '"result"'
}

# What must be healthy before a target runs. Kept out of the apply functions so
# a refusal happens BEFORE the journal exists: "bitcoind is unhealthy" must not
# leave a pending rotation that the next run has to --resume.
preflight_target() { # target
    local age
    case "$1" in
        bitcoin-rpc) require_healthy bitcoind ;;
        monero-rpc)  require_healthy monero-wallet-rpc ;;
        tor-control) require_healthy tor lightningd ;;
        runes)       require_healthy lightningd ;;
        token:*)     require_healthy "${1#token:}" ;;
        searxng-secret) require_healthy searxng ;;
        monero-wallet)
            require_healthy monero-wallet-rpc
            # The one credential here that cannot be recovered if it is lost:
            # both the acknowledgement and a restore point are prerequisites.
            if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
                die "the wallet file's password is the one value nobody can recover; re-run with --yes"
            fi
            age=$(backup_age_h || true)
            if [ -z "$age" ] || [ "$age" -gt 24 ]; then
                if [ "$FORCE" = 1 ] || [ "$DRY_RUN" = 1 ]; then
                    say "no backup in the last 24h (${age:+${age}h old}${age:-unreadable}); continuing"
                else
                    die "the newest restic snapshot is ${age:+${age}h old}${age:-unreadable}; take one first: ./deploy.sh --only backup (or --force)"
                fi
            else
                say "newest restic snapshot is ${age}h old"
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
    if podman exec lightningd lightning-cli getinfo >/dev/null 2>&1; then
        log "lightningd's bcli is talking to bitcoind"
    else
        warn "lightningd is not answering; check: podman logs lightningd"
    fi
}

apply_bitcoin_rpc() {
    local pass user rpcuser_old=""
    pass=$(gen NEW_BITCOIN_RPC_PASSWORD)
    if [ "$ROTATE_USER" = 1 ]; then
        user=$(journal_get NEW_BITCOIN_RPC_USER)
        if [ -z "$user" ]; then
            user="u$(rand_hex | cut -c1-12)"
            journal_put NEW_BITCOIN_RPC_USER "$user"
        fi
    else
        user=$(env_value "$SECRETS_FILE" BITCOIN_RPC_USER)
        [ -n "$user" ] || die "no BITCOIN_RPC_USER in $SECRETS_FILE; run deploy/install.sh first"
    fi
    if [ "$DRY_RUN" = 0 ]; then
        rpcuser_old=$(podman exec bitcoind sh -c 'sed -n "s/^rpcuser=//p" /data/.bitcoin/bitcoin.conf' 2>/dev/null | head -n1 || true)
    fi
    if [ -n "$rpcuser_old" ] && [ "$rpcuser_old" != "$user" ]; then
        edit_bitcoin_conf rpcuser "$user"
    fi

    journal_put step "bitcoin.conf"
    edit_bitcoin_conf rpcpassword "$pass"

    journal_put step "config files"
    set_env_key "$SECRETS_FILE" BITCOIN_RPC_USER "$user"
    set_env_key "$SECRETS_FILE" BITCOIN_RPC_PASSWORD "$pass"
    set_env_key "$CONFIG_DIR/bitcoin-node-mcp/upstream.env" BITCOIN_RPC_USER "$user"
    set_env_key "$CONFIG_DIR/bitcoin-node-mcp/upstream.env" BITCOIN_RPC_PASSWORD "$pass"
    set_env_key_if_file "$CONFIG_DIR/btc-explorer/btc-explorer.env" BTCEXP_BITCOIND_USER "$user"
    set_env_key_if_file "$CONFIG_DIR/btc-explorer/btc-explorer.env" BTCEXP_BITCOIND_PASS "$pass"

    journal_put step "re-render"
    install_rerender

    journal_put step "restart:bitcoind"
    restart_unit_and_wait bitcoind "$BITCOIND_WAIT"

    journal_put step "restart:dependents"
    restart_if_deployed fulcrum lightningd bitcoin-node-mcp btc-explorer

    journal_put step "verify"
    verify_bitcoin_rpc
    complete
}

# ---------------------------------------------------------------------------
# target: monero-rpc
# ---------------------------------------------------------------------------
verify_monero_rpc() {
    local token
    [ "$DRY_RUN" = 0 ] || return 0
    token=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
    if mcp_ok monero-wallet-mcp "$token" get_height '{}'; then
        log "monero-wallet-mcp reaches the wallet RPC with the new login"
    else
        die "monero-wallet-mcp did not answer; check: podman logs monero-wallet-mcp"
    fi
    if podman container exists boltmesh-backend 2>/dev/null; then
        if net_curl -fsS http://boltmesh-backend:8000/health >/dev/null 2>&1; then
            log "boltmesh-backend is healthy with the new Monero RPC login"
        else
            warn "boltmesh-backend is not healthy yet; check: podman logs boltmesh-backend"
        fi
    fi
}

apply_monero_rpc() {
    local login
    login=$(gen NEW_MONERO_RPC_LOGIN "monero:")

    journal_put step "config files"
    set_env_key "$SECRETS_FILE" MONERO_RPC_LOGIN "$login"
    set_env_key "$CONFIG_DIR/monero-wallet-mcp/upstream.env" MONERO_WALLET_RPC_USER "${login%%:*}"
    set_env_key "$CONFIG_DIR/monero-wallet-mcp/upstream.env" MONERO_WALLET_RPC_PASSWORD "${login#*:}"

    # The re-render covers both consumers that are rendered: the wallet unit's
    # --rpc-login and boltmesh/gateway.env, which install.sh rewrites from
    # secrets.env on every run.
    journal_put step "re-render"
    install_rerender

    journal_put step "restart:monero-wallet-rpc"
    restart_unit_and_wait monero-wallet-rpc "$MONERO_WALLET_WAIT"

    journal_put step "restart:dependents"
    restart_if_deployed monero-wallet-mcp boltmesh-backend boltmesh-worker

    journal_put step "verify"
    verify_monero_rpc
    complete
}

# ---------------------------------------------------------------------------
# target: tor-control
# ---------------------------------------------------------------------------
verify_tor_control() {
    [ "$DRY_RUN" = 0 ] || return 0
    if podman exec lightningd lightning-cli getinfo >/dev/null 2>&1; then
        log "lightningd is up with the new Tor control password (statictor re-registered)"
    else
        die "lightningd is not answering; check: podman logs lightningd"
    fi
}

apply_tor_control() {
    local pw hash
    pw=$(gen NEW_TOR_SERVICE_PASSWORD)
    hash=$(journal_get NEW_TOR_SERVICE_HASH)
    if [ -z "$hash" ]; then
        hash=$(tor_hash "$pw" || true)
        [ -n "$hash" ] || die "could not hash the password: is $TOR_IMAGE built? (deploy/install.sh builds it)"
        journal_put NEW_TOR_SERVICE_HASH "$hash"
    fi

    journal_put step "torrc"
    set_torrc_hash "$hash"

    journal_put step "config files"
    set_env_key "$SECRETS_FILE" TOR_SERVICE_PASSWORD "$pw"

    journal_put step "re-render"
    install_rerender

    # tor owns the control port, so it goes first: lightningd cannot register
    # its statictor service while the old hash is live.
    journal_put step "restart:tor"
    restart_unit_and_wait tor
    journal_put step "restart:lightningd"
    restart_unit_and_wait lightningd "$LN_WAIT"

    journal_put step "verify"
    verify_tor_control
    complete
}

# ---------------------------------------------------------------------------
# target: runes
# ---------------------------------------------------------------------------
# A rune is a bearer token: mint it, prove it, swap it in, prove the consumer
# works, and only then blacklist the old one -- a failed swap that had already
# destroyed the old rune would leave lightning-mcp unable to read the node.
mint_rune() { # restriction-json -> "rune unique_id"
    local restrictions="$1" out rune id tries
    if [ "$DRY_RUN" = 1 ]; then
        printf 'dryrun 0'
        return 0
    fi
    for ((tries = 1; tries <= 12; tries++)); do
        out=$(podman exec lightningd lightning-cli createrune null "$restrictions" 2>/dev/null || true)
        rune=$(printf '%s' "$out" | grep -o '"rune": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
        id=$(printf '%s' "$out" | grep -o '"unique_id": *"[0-9]*"' | head -n1 | grep -o '[0-9]*' || true)
        [ -n "$rune" ] && [ -n "$id" ] || return 1
        if podman exec lightningd lightning-cli -k checkrune rune="$rune" method=getinfo >/dev/null 2>&1; then
            printf '%s %s' "$rune" "$id"
            return 0
        fi
        # createrune can hand back a rune whose unique_id is already blacklisted;
        # the next id works. install.sh retries the same way.
        warn "new rune id $id was refused (already blacklisted?); retrying"
    done
    return 1
}

blacklist_rune() { # unique_id description
    local id="$1" what="$2"
    if [ "$DRY_RUN" = 1 ]; then
        say "would blacklist the old $what rune"
        return 0
    fi
    case "$id" in
        ''|*[!0-9]*)
            warn "could not resolve the old $what rune's unique_id; revoke it by hand:"
            warn "  podman exec lightningd lightning-cli destroyrune <id> <id>"
            return 0
            ;;
    esac
    run_step "blacklist the old $what rune (id $id)" \
        quiet podman exec lightningd lightning-cli destroyrune "$id" "$id"
}

# showrunes is the only place the unique_id of an EXISTING rune can be read --
# `destroyrune` takes ids, not runes, and node.env stores only the runes.
rune_id() { # rune -> unique_id (empty when unknown)
    [ -n "$1" ] || return 0
    podman exec lightningd lightning-cli -k showrunes rune="$1" 2>/dev/null \
        | grep -o '"unique_id": *"[0-9]*"' | head -n1 | grep -o '[0-9]*' || true
}

want_scope() { [ "$RUNE_SCOPE" = all ] || [ "$RUNE_SCOPE" = "$1" ]; }

verify_runes() { # scopes that changed
    local token
    [ "$DRY_RUN" = 0 ] || return 0
    token=$(env_value "$CONFIG_DIR/lightning-mcp/token.env" LIGHTNING_MCP_TOKEN)
    if mcp_ok lightning-mcp "$token" getinfo '{}'; then
        log "lightning-mcp answers getinfo with the new rune"
    else
        die "lightning-mcp did not answer; check: podman logs lightning-mcp"
    fi
    if printf '%s' "$1" | grep -q boltmesh && podman container exists boltmesh-backend 2>/dev/null; then
        if net_curl -fsS http://boltmesh-backend:8000/health >/dev/null 2>&1; then
            log "boltmesh-backend is healthy with the new gateway rune"
        else
            warn "boltmesh-backend is not healthy yet; check: podman logs boltmesh-backend"
        fi
    fi
}

apply_runes() {
    local node_env="$CONFIG_DIR/lightning-mcp/node.env"
    local gateway_env="$CONFIG_DIR/boltmesh/gateway.env"
    local old_read old_spend old_bolt
    local old_read_id="" old_spend_id="" old_bolt_id=""
    local new_read="" id_read="" new_spend="" id_spend="" new_bolt="" id_bolt=""
    local do_read=0 do_spend=0 do_bolt=0 changed="" minted

    old_read=$(env_value "$node_env" LIGHTNING_RUNE)
    old_spend=$(env_value "$node_env" LIGHTNING_SPEND_RUNE)
    old_bolt=$(env_value "$gateway_env" LIGHTNING_API_KEY)

    if want_scope read; then do_read=1; fi
    if want_scope spend; then do_spend=1; fi
    if want_scope boltmesh; then
        if [ -f "$gateway_env" ]; then
            do_bolt=1
        else
            say "no $gateway_env (BoltMesh is not deployed); skipping its rune"
        fi
    fi

    if [ "$do_read" = 1 ] || [ "$do_spend" = 1 ]; then
        [ -f "$node_env" ] || die "missing $node_env; run deploy/install.sh first"
    fi
    [ "$do_read" = 1 ] || [ "$do_spend" = 1 ] || [ "$do_bolt" = 1 ] \
        || die "nothing to rotate"

    journal_put step "mint read"
    if [ "$do_read" = 1 ]; then
        new_read=$(journal_get NEW_READ_RUNE)
        id_read=$(journal_get NEW_READ_RUNE_ID)
        if [ -z "$new_read" ]; then
            minted=$(mint_rune "$READ_RESTRICTIONS" || true)
            read -r new_read id_read <<< "$minted"
            [ -n "$new_read" ] && [ -n "$id_read" ] || die "could not mint a usable read rune"
            journal_put NEW_READ_RUNE "$new_read"
            journal_put NEW_READ_RUNE_ID "$id_read"
        fi
        changed+="read "
    fi
    journal_put step "mint spend"
    if [ "$do_spend" = 1 ]; then
        new_spend=$(journal_get NEW_SPEND_RUNE)
        id_spend=$(journal_get NEW_SPEND_RUNE_ID)
        if [ -z "$new_spend" ]; then
            minted=$(mint_rune "$SPEND_RESTRICTIONS" || true)
            read -r new_spend id_spend <<< "$minted"
            [ -n "$new_spend" ] && [ -n "$id_spend" ] || die "could not mint a usable spend rune"
            journal_put NEW_SPEND_RUNE "$new_spend"
            journal_put NEW_SPEND_RUNE_ID "$id_spend"
        fi
        changed+="spend "
    fi
    journal_put step "mint boltmesh"
    if [ "$do_bolt" = 1 ]; then
        new_bolt=$(journal_get NEW_BOLT_RUNE)
        id_bolt=$(journal_get NEW_BOLT_RUNE_ID)
        if [ -z "$new_bolt" ]; then
            minted=$(mint_rune "$BOLTMESH_RESTRICTIONS" || true)
            read -r new_bolt id_bolt <<< "$minted"
            [ -n "$new_bolt" ] && [ -n "$id_bolt" ] || die "could not mint a usable BoltMesh rune"
            journal_put NEW_BOLT_RUNE "$new_bolt"
            journal_put NEW_BOLT_RUNE_ID "$id_bolt"
        fi
        changed+="boltmesh "
    fi

    journal_put step "write runes"
    if [ "$do_read" = 1 ]; then
        set_env_key "$node_env" LIGHTNING_RUNE "$new_read"
    fi
    if [ "$do_spend" = 1 ]; then
        set_env_key "$node_env" LIGHTNING_SPEND_RUNE "$new_spend"
    fi
    if [ "$do_bolt" = 1 ]; then
        set_env_key "$gateway_env" LIGHTNING_API_KEY "$new_bolt"
    fi

    journal_put step "restart:consumers"
    if [ "$do_read" = 1 ] || [ "$do_spend" = 1 ]; then
        restart_if_deployed lightning-mcp
    fi
    if [ "$do_bolt" = 1 ]; then
        restart_if_deployed boltmesh-backend boltmesh-worker
    fi

    journal_put step "verify"
    verify_runes "$changed"

    # Revocation last, and only now that the replacements are proven in use.
    journal_put step "revoke"
    if [ "$do_read" = 1 ] && [ -n "$old_read" ]; then
        [ "$DRY_RUN" = 1 ] || old_read_id=$(rune_id "$old_read")
        blacklist_rune "$old_read_id" read
    fi
    if [ "$do_spend" = 1 ] && [ -n "$old_spend" ]; then
        [ "$DRY_RUN" = 1 ] || old_spend_id=$(rune_id "$old_spend")
        blacklist_rune "$old_spend_id" spend
    fi
    if [ "$do_bolt" = 1 ] && [ -n "$old_bolt" ]; then
        [ "$DRY_RUN" = 1 ] || old_bolt_id=$(rune_id "$old_bolt")
        blacklist_rune "$old_bolt_id" boltmesh
    fi

    if [ "$do_read" = 1 ] || [ "$do_spend" = 1 ]; then
        rehash_audit "$node_env"
    fi
    complete
}


# ---------------------------------------------------------------------------
# target: token:<server>
# ---------------------------------------------------------------------------
# The MCP bearer tokens are the stack's most-copied secret: every client config
# holds one. Rotating therefore has two halves -- the server's token.env and,
# for the client, a pointer at that file (the value is never printed, and
# ~/.config/opencode/mcp.env already reads it from there at shell start).
TOKEN_SERVERS=(searxng-mcp bitcoin-node-mcp monero-node-mcp monero-wallet-mcp lightning-mcp)

# env-file | read-token var | a read tool it answers | its args | spend-token var
token_spec() { # server
    case "$1" in
        searxng-mcp)
            printf '%s|%s|%s|%s|%s' "$CONFIG_DIR/searxng-mcp/token.env" \
                SEARXNG_MCP_TOKEN get_time '{"tz":"UTC"}' "" ;;
        bitcoin-node-mcp)
            printf '%s|%s|%s|%s|%s' "$CONFIG_DIR/bitcoin-node-mcp/token.env" \
                BITCOIN_MCP_TOKEN get_blockchain_info '{}' "" ;;
        monero-node-mcp)
            printf '%s|%s|%s|%s|%s' "$CONFIG_DIR/monero-node-mcp/token.env" \
                MONERO_MCP_TOKEN get_info '{}' "" ;;
        monero-wallet-mcp)
            printf '%s|%s|%s|%s|%s' "$CONFIG_DIR/monero-wallet-mcp/token.env" \
                MONERO_MCP_TOKEN get_balance '{}' MONERO_MCP_SPEND_TOKEN ;;
        lightning-mcp)
            printf '%s|%s|%s|%s|%s' "$CONFIG_DIR/lightning-mcp/token.env" \
                LIGHTNING_MCP_TOKEN getinfo '{}' LIGHTNING_MCP_SPEND_TOKEN ;;
        *) return 1 ;;
    esac
}

# The endpoint's own gate, the same probe verify.sh runs every sweep: an
# unauthenticated -- or revoked -- token gets 401 on /mcp. The token goes in a
# curl config on stdin, so it never reaches a podman argv.
http_code_token() { # container token
    printf 'header = "Authorization: Bearer %s"\n' "$2" | \
        net_curl -s -o /dev/null -w '%{http_code}' -m 10 -K - \
            -X POST "http://$1:8000/mcp" -H 'Content-Type: application/json' -d '{}' 2>/dev/null
}

verify_token() { # server envfile readvar tool args old-read-token [spend]
    local server="$1" envf="$2" readvar="$3" tool="$4" args="$5" old="$6" spend="${7:-0}"
    local token code
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
        return 0
    fi
    [ -n "$old" ] || return 0
    code=$(http_code_token "$server" "$old")
    if [ "$code" = 401 ]; then
        log "the old token is refused (401)"
    else
        warn "the old token still answers ($code); check: podman logs $server"
    fi
}

apply_token() {
    local server="$1" spec envf readvar tool args spendvar var key old new
    spec=$(token_spec "$server") || die "no bearer token for '$server' (servers: ${TOKEN_SERVERS[*]})"
    IFS='|' read -r envf readvar tool args spendvar <<< "$spec"
    [ -f "$envf" ] || die "missing $envf; run deploy/install.sh first"

    var="$readvar"
    key="NEW_TOKEN"
    if [ "$SPEND_ONLY" = 1 ]; then
        [ -n "$spendvar" ] || die "$server has no spend token (only monero-wallet-mcp and lightning-mcp do)"
        var="$spendvar"
        key="NEW_SPEND_TOKEN"
    fi

    # The old value has to survive into the journal: proving it is now refused
    # is half the rotation, and a resume wants to know what it replaced.
    old=$(env_value "$envf" "$var")
    new=$(gen "$key")
    journal_put OLD_TOKEN "$old"

    journal_put step "token.env"
    set_env_key "$envf" "$var" "$new"

    journal_put step "restart"
    restart_if_deployed "$server"

    journal_put step "verify"
    verify_token "$server" "$envf" "$readvar" "$tool" "$args" "$old" "$SPEND_ONLY"

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
    new=$(gen NEW_SEARXNG_SECRET)

    journal_put step "settings.yml"
    set_searxng_secret "$new"

    journal_put step "restart:searxng"
    restart_unit_and_wait searxng

    journal_put step "verify"
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
# target: monero-wallet
# ---------------------------------------------------------------------------
# The wallet file's password is the only value here that nobody can recover if
# it is lost, so it is changed in the one place that can change it (the wallet
# RPC, which owns the file) and then copied into the journal BEFORE anything
# else, in case the run dies between the two.
wallet_change_password() { # old new
    local login json
    # A dry run must never reach this. It is the one call in the whole script
    # that changes something no file records, so the guard lives here, not only
    # at the call site: a future caller cannot reintroduce the bug.
    if [ "$DRY_RUN" = 1 ]; then
        say "would change the wallet file's password at monero-wallet-rpc"
        return 0
    fi
    login=$(env_value "$SECRETS_FILE" MONERO_RPC_LOGIN)
    [ -n "$login" ] || die "no MONERO_RPC_LOGIN in $SECRETS_FILE"
    json=$(printf '{"jsonrpc":"2.0","id":"0","method":"change_wallet_password","params":{"old_password":"%s","new_password":"%s"}}' "$1" "$2")
    # -u is the wallet's own RPC login, which already sits on the container's
    # PID-1 command line (--rpc-login in the rendered unit), so passing it here
    # is not a new exposure; the JSON carries the wallet-file passwords, so it
    # goes in on stdin rather than in an argv.
    printf '%s' "$json" | net_curl -s -m 120 -u "$login" --digest \
        -H 'Content-Type: application/json' --data-binary @- \
        http://monero-wallet-rpc:18083/json_rpc
}

verify_monero_wallet() {
    local token
    [ "$DRY_RUN" = 0 ] || return 0
    token=$(env_value "$CONFIG_DIR/monero-wallet-mcp/token.env" MONERO_MCP_TOKEN)
    if mcp_ok monero-wallet-mcp "$token" get_balance '{}'; then
        log "the wallet opens with the new password (get_balance answered)"
    else
        die "the wallet did not open; the new password is in $JOURNAL -- check: podman logs monero-wallet-rpc"
    fi
}

apply_monero_wallet() {
    local old new resp
    old=$(env_value "$SECRETS_FILE" MONERO_WALLET_PASSWORD)
    [ -n "$old" ] || die "no MONERO_WALLET_PASSWORD in $SECRETS_FILE"
    new=$(gen NEW_MONERO_WALLET_PASSWORD)

    if [ "$DRY_RUN" = 1 ]; then
        say "would change the wallet file's password, then rewrite the unit and secrets.env"
    elif [ "$(journal_get WALLET_CHANGED)" = 1 ]; then
        say "the wallet already carries the journaled password; continuing after the change"
    else
        # Both sides of the one call that cannot be undone are journaled first:
        # after this line the old password may stop being the truth at any
        # moment, and a resume has to be able to tell which case it is in.
        journal_put OLD_WALLET_PASSWORD "$old"
        journal_put step "wallet password"
        resp=$(wallet_change_password "$old" "$new" || true)
        case "$resp" in
            *'"error"'*)
                warn "monero-wallet-rpc refused the change: $resp"
                die "nothing was written; the wallet still opens with the current password"
                ;;
            *'"result"'*)
                journal_put WALLET_CHANGED 1
                log "the wallet file now has the new password"
                ;;
            *)
                die "no answer from monero-wallet-rpc (is it healthy?): the wallet is UNCHANGED"
                ;;
        esac
    fi

    journal_put step "config files"
    set_env_key "$SECRETS_FILE" MONERO_WALLET_PASSWORD "$new"

    journal_put step "re-render"
    install_rerender

    journal_put step "restart:monero-wallet-rpc"
    restart_unit_and_wait monero-wallet-rpc "$MONERO_WALLET_WAIT"

    journal_put step "restart:dependents"
    restart_if_deployed monero-wallet-mcp boltmesh-backend boltmesh-worker

    journal_put step "verify"
    verify_monero_wallet
    complete
}

# The newest restic snapshot's age in hours (empty when it cannot be read).
backup_age_h() {
    command -v jq >/dev/null 2>&1 || return 1
    local json latest s
    json=$("$REPO_DIR/scripts/backup.sh" list --json 2>/dev/null) || return 1
    latest=$(printf '%s' "$json" | jq -r 'map(.time) | max // empty' 2>/dev/null) || return 1
    [ -n "$latest" ] || return 1
    s=$(date -d "$latest" +%s 2>/dev/null) || return 1
    printf '%s' $(( ($(date +%s) - s) / 3600 ))
}

# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------
complete() {
    if [ "$DRY_RUN" = 1 ]; then
        log "dry run complete for $TARGET; nothing was written and nothing was restarted"
        return 0
    fi
    journal_put step "done"
    record_rotation "$TARGET" ok
    journal_clear
    log "$TARGET rotated"
    if [ "$TARGET" = runes ]; then
        say "lightning-mcp and BoltMesh read their rune from the env files; nothing else to update"
    fi
}

cmd_status() {
    local f
    printf '==> pending rotations (%s)\n' "$ROT_DIR"
    if compgen -G "$ROT_DIR/*.pending" >/dev/null; then
        for f in "$ROT_DIR"/*.pending; do
            JOURNAL="$f"
            printf '  %-14s started=%s step=%s\n' \
                "$(basename "$f" .pending)" "$(journal_get started)" "$(journal_get step)"
        done
        JOURNAL=""
        printf '  finish one with: %s --resume\n' "$0"
    else
        printf '  none\n'
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

if [ "$RESUME" = 1 ]; then
    [ -z "$TARGET" ] || die "--resume reads the target from the journal; do not pass one"
    pending=()
    while IFS= read -r f; do pending+=("$f"); done \
        < <(find "$ROT_DIR" -maxdepth 1 -name '*.pending' -type f 2>/dev/null | sort)
    [ "${#pending[@]}" -gt 0 ] || die "no pending rotation to resume"
    [ "${#pending[@]}" -eq 1 ] || die "more than one pending rotation (${pending[*]}); resume needs a single one"
    TARGET=$(basename "${pending[0]}" .pending)
    JOURNAL="${pending[0]}"
    STARTED=1
    log "resuming $TARGET from step: $(journal_get step)"
fi

[ -n "$TARGET" ] || die "no target; try --list"
case "$TARGET" in
    bitcoin-rpc|monero-rpc|tor-control|runes|searxng-secret|monero-wallet) ;;
    token:*)
        token_spec "${TARGET#token:}" >/dev/null \
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
if [ "$RESUME" = 0 ]; then
    journal_begin "$TARGET"
fi
[ -n "$JOURNAL" ] || JOURNAL=$(journal_path "$TARGET")

case "$TARGET" in
    bitcoin-rpc) apply_bitcoin_rpc ;;
    monero-rpc)  apply_monero_rpc ;;
    tor-control) apply_tor_control ;;
    runes)       apply_runes ;;
    token:*)     apply_token "${TARGET#token:}" ;;
    searxng-secret) apply_searxng_secret ;;
    monero-wallet)  apply_monero_wallet ;;
    *)           die "unknown target: $TARGET (try --list)" ;;
esac
