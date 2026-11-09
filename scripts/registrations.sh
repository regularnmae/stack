#!/usr/bin/env bash
# Alert on new BoltMesh signups.
#
#   scripts/registrations.sh              # mail every signup since the last run
#   scripts/registrations.sh --quiet      # no stdout (deploy/registrations.service)
#   scripts/registrations.sh --dry-run    # print the rows; push nothing, change nothing
#   scripts/registrations.sh --test       # push one synthetic alert (proves the path)
#
# Run by deploy/registrations.timer every minute. The signup is read from the
# app's own users table, not from a log line: app/auth/services/registration.py
# writes exactly one journal line ("User registered successfully: ID <uuid>")
# and it carries neither the username nor the email, while the row is the record
# itself -- and the same row is written for an OAuth signup
# (app/auth/services/oauth.py), which never goes through the password form.
#
# Registration is an EVENT, not a fault, so it does not ride on
# scripts/monitor.sh: every monitor section is a condition that clears, its flap
# damper would hold a signup for ten minutes, and its explicit resolution would
# mail a second time. Here each signup is pushed ONCE to Alertmanager with
# severity=info and its own `signup=<uuid>` label -- one shared label set would
# let Alertmanager fold a second signup into the first -- plus an endsAt ten
# minutes out, so it fires once and then resolves without a "recovered" mail
# (alertmanager.yml routes severity=info to a receiver with send_resolved:
# false).
#
# The watermark is the (created_at, id) of the last row pushed, kept in
# $DATA_DIR/audit/registrations.status next to the verdict monitor.sh reads. A
# failed push leaves it alone, so a mail is delayed, never lost. The FIRST run
# seeds it from the newest row and mails nothing: deploying this must not mail
# the accounts that already exist.
#
# Read-only towards the app: the one query is a SELECT through
# `podman exec postgres psql`, and the local socket is trust (the access
# postgres-dump.service already uses), so no database password is read at all.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../stack.conf
[ -r "$REPO_DIR/stack.conf" ] && . "$REPO_DIR/stack.conf"
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

QUIET=0
DRY_RUN=0
ALERT_TEST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet|-q)   QUIET=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --test)       ALERT_TEST=1 ;;
        -h|--help)    usage_header "$0"; exit 0 ;;
        *)            die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

# The alert path is the host's own curl + jq, for the same reason as
# scripts/monitor.sh: Alertmanager is a loopback bind, and a container cannot be
# what reports a broken container runtime. Without them the watcher would read
# fine and deliver nothing, so refuse instead of half-working.
missing=""
command -v curl >/dev/null 2>&1 || missing="$missing curl"
command -v jq   >/dev/null 2>&1 || missing="$missing jq"
if [ -n "$missing" ]; then
    die "registrations needs${missing} on the host: the alert push uses them. Install: sudo dnf install -y${missing} (./bootstrap.sh does this)"
fi

resolve_data_dir
AUDIT_DIR="$DATA_DIR/audit"
STATE_FILE="$AUDIT_DIR/registrations.status"
AUDIT_LOG="$AUDIT_DIR/registrations.log"
mkdir -p "$AUDIT_DIR"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# The Alertmanager URL comes from the same file the monitor reads (the unit
# passes it through EnvironmentFile), so a host that turned the push off has a
# watcher that logs to the journal instead. Read here too, so a hand run behaves
# exactly like the timer. `off` is a word, not a blank: env_value cannot tell an
# absent key from an empty one.
MONITOR_ENV="$CONFIG_DIR/monitoring/monitor.env"
AM_URL="${MONITOR_ALERTMANAGER_URL:-$(env_value "$MONITOR_ENV" MONITOR_ALERTMANAGER_URL)}"
AM_URL="${AM_URL:-http://127.0.0.1:9093}"
AM_URL="${AM_URL%/}"

# What every alert carries, same label as the monitor's: inhibition and any
# future federation key on it.
ALERT_INSTANCE="$(hostname -s 2>/dev/null || echo stack)"

# The BoltMesh database. Both names are non-secret and come from the generated
# db.env, the same file the backend reads. The container check below, not this
# file, is what tells a --skip-apps host apart: db.env is seeded everywhere.
DB_ENV="$CONFIG_DIR/boltmesh/db.env"
PG_DB=$(env_value "$DB_ENV" POSTGRES_DB)
PG_USER=$(env_value "$DB_ENV" POSTGRES_USER)
# Two ways a host legitimately has nothing to watch: --skip-apps never installs
# the app tier (no postgres unit), and a checkout that has not run install.sh
# yet has no db.env. Both are a recorded skip, not a failure every minute --
# `podman container exists` is asked because db.env is seeded on every host.
if [ -z "$PG_DB" ] || [ -z "$PG_USER" ] || ! podman container exists postgres 2>/dev/null; then
    say "no BoltMesh app tier on this host ($DB_ENV, postgres container); nothing to watch"
    [ "$DRY_RUN" = 1 ] && exit 0
    status_write "$STATE_FILE" \
        "# written by scripts/registrations.sh (deploy/registrations.timer)" \
        ok "skipped: no BoltMesh app tier on this host" \
        "skipped=1" "new=0"
    exit 0
fi

# One row per line, tab-separated, no padding and no footer: the shape the read
# loop below expects. `-i` carries the SQL on stdin, which is how :'var' quoting
# is used instead of interpolating values into the statement.
psql_run() { # psql args... ; SQL on stdin
    podman exec -i -e PGTZ=UTC postgres psql -X -A -t -q -F $'\t' \
        -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" "$@" 2>/dev/null
}

# The watermark is (timestamp, uuid), never the timestamp alone: two signups can
# share a microsecond, and ids are UUIDs, so only the pair orders them. It is
# validated before it reaches the query because a truncated or hand-edited state
# file must re-seed, not fail forever.
valid_watermark() {
    [[ "${WM_TS:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$ ]] || return 1
    [[ "${WM_ID:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
}

# Seed the watermark from the newest account, so the first run after install
# mails nothing historical. An empty table seeds from the database clock with the
# nil uuid, which every real row compares greater than.
seed_watermark() {
    local row
    row=$(psql_run <<'SQL'
SELECT id, to_char(created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
FROM users ORDER BY created_at DESC, id DESC LIMIT 1
SQL
) || return 1
    if [ -n "$row" ]; then
        IFS=$'\t' read -r WM_ID WM_TS <<< "$row"
    else
        WM_TS=$(psql_run <<'SQL'
SELECT to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
SQL
) || return 1
        WM_ID="00000000-0000-0000-0000-000000000000"
    fi
    [ -n "$WM_TS" ] && [ -n "$WM_ID" ]
}

# --- what came in since the last run ----------------------------------------
# The history is taken from the status file rather than a separate cursor so
# there is one file to inspect and one write to get wrong.
WM_TS=$(env_value "$STATE_FILE" watermark_ts)
WM_ID=$(env_value "$STATE_FILE" watermark_id)
valid_watermark || { WM_TS=""; WM_ID=""; }

if [ "$ALERT_TEST" = 1 ]; then
    [ "$AM_URL" = off ] && die "alerting is off (MONITOR_ALERTMANAGER_URL=off)"
    starts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    ends=$(date -u -d '+2 minutes' '+%Y-%m-%dT%H:%M:%SZ')
    # A fresh signup id on every run: the route groups per signup, and the
    # notification log dedupes a group it has already mailed -- a fixed label
    # would make a second test look broken.
    body=$(jq -cn --arg inst "$ALERT_INSTANCE" --arg s "$starts" --arg e "$ends" \
        --arg id "test-$(date +%s)" \
        '[{labels:{alertname:"boltmesh_signup",severity:"info",service:"boltmesh",instance:$inst,signup:$id},
           annotations:{summary:"BoltMesh: test signup alert",description:"Sent by scripts/registrations.sh --test; it resolves in about two minutes and sends no recovered mail."},
           startsAt:$s, endsAt:$e}]')
    curl -fsS -m 10 -H 'Content-Type: application/json' \
        --data-binary "$body" "$AM_URL/api/v2/alerts" >/dev/null \
        || die "could not post a test alert to $AM_URL/api/v2/alerts"
    printf 'test alert accepted by %s\n' "$AM_URL"
    printf 'expect ONE mail within ~90s (group_wait 30s), with no resolved mail after it.\n'
    printf 'nothing arrived? Mail is proven by scripts/monitor.sh --test; if that works,\n'
    printf 'check the severity=info route in %s/monitoring/alertmanager/alertmanager.yml\n' "$CONFIG_DIR"
    exit 0
fi

if [ -z "$WM_TS" ]; then
    if ! seed_watermark; then
        detail="could not read the users table (is postgres up? see: podman logs --tail 30 postgres)"
        say "FAIL $detail"
        [ "$DRY_RUN" = 1 ] && exit 1
        status_write "$STATE_FILE" \
            "# written by scripts/registrations.sh (deploy/registrations.timer)" \
            fail "$detail" "new=0"
        printf '%s result=fail %s\n' "$(date -Is)" "$detail" >> "$AUDIT_LOG"
        exit 1
    fi
    say "seeded the watermark at $WM_TS ($WM_ID); existing accounts are not mailed"
    if [ "$DRY_RUN" = 1 ]; then
        printf 'would seed watermark_ts=%s watermark_id=%s\n' "$WM_TS" "$WM_ID"
        exit 0
    fi
    status_write "$STATE_FILE" \
        "# written by scripts/registrations.sh (deploy/registrations.timer)" \
        ok "" "watermark_ts=$WM_TS" "watermark_id=$WM_ID" "new=0"
    exit 0
fi

if ! rows=$(psql_run -v ts="$WM_TS" -v id="$WM_ID" <<'SQL'
SELECT id, username, email,
       to_char(created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
FROM users
WHERE (created_at, id) > (:'ts'::timestamptz, :'id'::uuid)
ORDER BY created_at, id
LIMIT 200
SQL
); then
    detail="could not read the users table (is postgres up? see: podman logs --tail 30 postgres)"
    say "FAIL $detail"
    [ "$DRY_RUN" = 1 ] && exit 1
    status_write "$STATE_FILE" \
        "# written by scripts/registrations.sh (deploy/registrations.timer)" \
        fail "$detail" "watermark_ts=$WM_TS" "watermark_id=$WM_ID" "new=0"
    printf '%s result=fail %s\n' "$(date -Is)" "$detail" >> "$AUDIT_LOG"
    exit 1
fi

# --- build one alert per signup ---------------------------------------------
# Count is capped at 200 rows per run. The watermark advances to the last row
# pushed, so a burst longer than that is mailed over consecutive runs rather than
# dropped -- the one thing that must never happen to this file.
NEW=0
LAST_TS="$WM_TS"
LAST_ID="$WM_ID"
payload='[]'
log_lines=''
ends=$(date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ')
starts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

while IFS=$'\t' read -r uid uname uemail uts; do
    [ -n "$uid" ] || continue
    NEW=$((NEW + 1))
    LAST_TS="$uts"
    LAST_ID="$uid"
    body=$(jq -cn --arg inst "$ALERT_INSTANCE" --arg id "$uid" --arg u "$uname" \
        --arg e "$uemail" --arg t "$uts" --arg s "$starts" --arg x "$ends" \
        '{labels:{alertname:"boltmesh_signup",severity:"info",service:"boltmesh",instance:$inst,signup:$id},
          annotations:{summary:("BoltMesh: new signup " + $u),
            description:("username: " + $u + "\nemail: " + $e + "\nregistered: " + $t + "\nid: " + $id)},
          startsAt:$s, endsAt:$x}')
    payload=$(jq -c --argjson a "$body" '. + [$a]' <<< "$payload")
    # Written only once the push succeeds: a retried run must not duplicate the
    # line, and "seen" is not the interesting fact -- "mailed" is.
    log_lines+="$(date -Is) signup id=$uid username=$uname"$'\n'
done <<< "$rows"

if [ "$NEW" = 0 ]; then
    say "no new signups"
    [ "$DRY_RUN" = 1 ] && exit 0
    status_write "$STATE_FILE" \
        "# written by scripts/registrations.sh (deploy/registrations.timer)" \
        ok "" "watermark_ts=$WM_TS" "watermark_id=$WM_ID" "new=0"
    exit 0
fi

say "$NEW new signup(s) since $WM_TS"
if [ "$DRY_RUN" = 1 ]; then
    jq -r '.[] | "  \(.labels.signup)\t\(.annotations.description | gsub("\n"; " | "))"' <<< "$payload"
    printf 'would advance watermark to %s (%s) and push %s\n' "$LAST_TS" "$LAST_ID" "$AM_URL"
    exit 0
fi

# Alertmanager accepts the whole set in one request. A failure here leaves the
# watermark untouched: the next tick re-reads the same rows, so the mail is late
# rather than gone. `off` is not a failure -- the signups are already in the
# audit log, and the watermark must advance or turning alerting back on would
# mail a backlog nobody asked for.
if [ "$AM_URL" = off ]; then
    say "alerting is off: signups are in $AUDIT_LOG only"
else
    if ! curl -fsS -m 10 -H 'Content-Type: application/json' \
            --data-binary "$payload" "$AM_URL/api/v2/alerts" >/dev/null 2>&1; then
        detail="could not push $NEW signup alert(s) to Alertmanager at $AM_URL; retrying next run"
        say "FAIL $detail"
        status_write "$STATE_FILE" \
            "# written by scripts/registrations.sh (deploy/registrations.timer)" \
            fail "$detail" "watermark_ts=$WM_TS" "watermark_id=$WM_ID" "new=0"
        printf '%s result=fail %s\n' "$(date -Is)" "$detail" >> "$AUDIT_LOG"
        exit 1
    fi
fi

status_write "$STATE_FILE" \
    "# written by scripts/registrations.sh (deploy/registrations.timer)" \
    ok "" "watermark_ts=$LAST_TS" "watermark_id=$LAST_ID" "new=$NEW"
printf '%s' "$log_lines" >> "$AUDIT_LOG"
printf '%s result=ok new=%s watermark_ts=%s\n' "$(date -Is)" "$NEW" "$LAST_TS" >> "$AUDIT_LOG"
say "advanced the watermark to $LAST_TS ($LAST_ID)"
# The query is capped at 200 rows so one POST stays bounded. The watermark is
# the last row in this batch, so "200" means the next tick mails the rest -- say
# so, because a silent truncation would read like a lost signup.
[ "$NEW" -ge 200 ] && say "stopped at 200 rows; the remaining signups go out on the next run"
exit 0
