# shellcheck shell=bash
# What a unit is running, read back from the container rather than a baseline:
# the generation stamp install.sh writes, and the image label the build writes
# (docs/units.md).

# --- unit generation stamps -------------------------------------------------
# A running container keeps the definition it started with: re-rendering a unit
# changes nothing until that unit restarts, and `systemctl show -p ExecStart`
# answers with the *new* file as soon as install.sh's daemon-reload has run --
# systemd keeps no copy of what the live process was started with. So the applied
# definition is read back from the container instead: install.sh stamps every
# rendered .container with a digest of its own definition as an OCI label, and
# podman never rewrites a label on a container it did not create. Drift is then
# "the label differs from the digest of the file on disk" -- one observation, no
# baseline file, and no writer that can claim an apply which did not happen.
#
# The digest excludes the stamp line itself: the stamp is the answer, not an
# input, so it must not be able to change what it is a digest of.
#
# Here because install.sh, deploy.sh and verify.sh must agree byte for byte: two
# implementations would report permanent drift.
UNIT_STAMP_LABEL="org.stack.unit-digest"
UNIT_STAMP_LINE="Label=$UNIT_STAMP_LABEL="
# What the applied side records for a running container that carries no stamp:
# a container created before the stamps existed. Never equal to a digest, so the
# next deploy recreates it rather than adopting a definition nobody can identify.
UNIT_UNSTAMPED="unstamped"

# The start-only config a unit owns, keyed by stem. A container reads these once
# at start, so a change has to reach its definition digest or the restart pass
# never sees it. Folded into the owning container's digest rather than given a
# stem of its own: a label lives on a container, and "torrc changed" means
# "tor was started from an older definition".
unit_config_digest() { # stem -> digest, empty when the unit owns no such config
    case "$1" in
        tor)
            # The onion services are rendered into torrc, so a retargeted service
            # reaches a running tor only through a restart.
            if [ -s "$DATA_DIR/tor/torrc" ]; then
                sha256sum -- "$DATA_DIR/tor/torrc" | awk '{ print $1 }'
            fi ;;
        crowdsec)
            if [ -d "$DATA_DIR/config/ids/crowdsec" ]; then
                find "$DATA_DIR/config/ids/crowdsec" -type f -print0 2>/dev/null \
                    | sort -z | xargs -0 -r sha256sum 2>/dev/null \
                    | sha256sum | awk '{ print $1 }'
            fi ;;
        vector)
            # Vector reads its rendered config only at start (there is no reload).
            if [ -s "$DATA_DIR/config/logs/vector/vector.toml" ]; then
                sha256sum -- "$DATA_DIR/config/logs/vector/vector.toml" | awk '{ print $1 }'
            fi ;;
        vmalert)
            # The rules carry MONITOR_ALERT_FOR: editing the hold-down in
            # monitor.env has to reach a running vmalert, or the file says one
            # thing and the process does another.
            if [ -s "$DATA_DIR/config/monitoring/vmalert/stack.yml" ]; then
                sha256sum -- "$DATA_DIR/config/monitoring/vmalert/stack.yml" \
                    | awk '{ print $1 }'
            fi ;;
    esac
}

# The stamp line's value in a rendered unit, empty when it carries none. Fixed
# prefix, not a regex: the label contains dots.
unit_stamp_value() { # rendered .container -> stamp
    awk -v p="$UNIT_STAMP_LINE" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' \
        "$1" 2>/dev/null || true
}

# The unit's content with its stamp line set, on stdout. The line goes at the end
# of the [Container] section: Quadlet reads a key in the wrong section as absent,
# and a stamp appended at EOF lands in [Install] (the last section of most units).
unit_stamped() { # rendered .container stamp -> content on stdout
    awk -v p="$UNIT_STAMP_LINE" -v ins="$UNIT_STAMP_LINE$2" '
        BEGIN { done = 0; seen = 0; in_container = 0 }
        /^\[/ {
            if (in_container && !done) { print ins; done = 1 }
            if ($0 == "[Container]") seen = 1
            in_container = ($0 == "[Container]")
        }
        index($0, p) != 1 { print }
        END {
            if (done) exit
            if (in_container) { print ins; exit }
            if (!seen) print "[Container]"
            print ins
        }
    ' "$1"
}

# Everything the container will be created from, except the stamp: the rendered
# unit file plus the config it reads once at start.
unit_definition_digest() { # rendered .container -> sha256
    local f="$1" stem
    stem=${f##*/}
    stem=${stem%.container}
    {
        awk -v p="$UNIT_STAMP_LINE" 'index($0, p) != 1' "$f" 2>/dev/null || true
        unit_config_digest "$stem"
    } | sha256sum | awk '{ print $1 }'
}

# The definition each rendered unit currently asks for, in sha256sum's format.
unit_digest() {
    local q="${QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
    local f
    [ -d "$q" ] || return 0
    for f in "$q"/*.container; do
        [ -f "$f" ] || continue
        printf '%s  %s\n' "$(unit_definition_digest "$f")" "${f##*/}"
    done
}

# container-name <TAB> unit stem, one per rendered unit. Usually the same string,
# but a unit may set ContainerName to something else (backup.container is
# stack-backup under backup.service), and `systemctl show stack-backup.service`
# answers 0 just like a real unit -- so assuming name == unit records restarts for
# a unit that does not exist.
unit_container_map() {
    local q="${QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
    local f stem cname
    [ -d "$q" ] || return 0
    for f in "$q"/*.container; do
        [ -f "$f" ] || continue
        stem=${f##*/}
        stem=${stem%.container}
        cname=$(sed -n 's/^ContainerName=//p' "$f" 2>/dev/null | head -n1)
        printf '%s\t%s\n' "${cname:-$stem}" "$stem"
    done
}

# A container name to the unit stem that owns it, or the name itself when no
# rendered unit claims it.
unit_for_container() { # container-name -> unit stem
    local stem
    stem=$(unit_container_map | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }')
    printf '%s' "${stem:-$1}"
}

# Is a unit in a space-delimited set of unit stems (" bitcoind tor ")? Kept in
# one place so a substring like "tor" never matches "tor-control".
unit_in_set() { # unit set
    [ -n "${1:-}" ] || return 1
    case " ${2:-} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# The unit stems whose digest differs between two sets, one per line. A unit on
# only one side is not reported: a new one is not running yet (it starts from the
# new file), and a removed one is not this function's business.
unit_digest_changed() { # before-digest after-digest
    awk 'NR==FNR { old[$2] = $1; next }
         ($2 in old) && old[$2] != $1 { print $2 }' \
        <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
        | sed 's/\.[^.]*$//' | sort -u
}

# One unit's line from a digest set ("<sha>  <stem>.container"), empty when the
# set has none. Compared against unit_digest_applied's output it answers "does
# the running container already carry this definition?".
unit_digest_line() { # digest-set stem -> line
    printf '%s\n' "$1" | awk -v f="$2.container" '$2 == f { print; exit }'
}

# The definition each running container was created from, in unit_digest's
# format. `podman ps` rather than one inspect per unit: one fork, and it lists
# exactly the containers that are running -- a stopped unit has no definition to
# be stale, and its next start reads the new file. A container with no stamp was
# created before the stamps existed and is recorded as UNIT_UNSTAMPED, so the next
# deploy recreates it instead of adopting a definition nobody can identify.
unit_digest_applied() {
    local name stamp stem
    local -A owner=()
    while IFS=$'\t' read -r name stem; do
        if [ -n "$name" ]; then owner[$name]=$stem; fi
    done < <(unit_container_map)
    while read -r name stamp; do
        if [ -z "$name" ]; then continue; fi
        stem=${owner[$name]:-}
        if [ -z "$stem" ]; then continue; fi
        printf '%s  %s.container\n' "${stamp:-$UNIT_UNSTAMPED}" "$stem"
    done < <(podman ps --format "{{.Names}} {{.Label \"$UNIT_STAMP_LABEL\"}}" 2>/dev/null || true)
}

# Write the stamp a rendered unit should carry, in place and mode 600 (several
# rendered units embed a secret). No-op when it is already current, so a re-render
# that changes nothing does not churn the file.
unit_stamp_generation() { # rendered .container
    local f="$1" want tmp
    [ -f "$f" ] || return 0
    want=$(unit_definition_digest "$f")
    if [ "$(unit_stamp_value "$f")" = "$want" ]; then
        return 0
    fi
    tmp=$(mktemp)
    unit_stamped "$f" "$want" > "$tmp"
    install -m 600 "$tmp" "$f"
    rm -f "$tmp"
}

# Stamp every rendered unit. install.sh calls this last, after the config trees
# unit_config_digest folds in have been written: a stamp computed before them
# would describe a definition the host does not have.
unit_stamp_generations() { # [quadlet-dir]
    local q="${1:-${QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}}"
    local f
    [ -d "$q" ] || return 0
    for f in "$q"/*.container; do
        [ -f "$f" ] || continue
        unit_stamp_generation "$f" || return 1
    done
}

# --- locally-built images --------------------------------------------------
# The images this repo builds (btc-explorer, xmr-explorer, netcheck, tor) are
# described completely by their Containerfile: base image digest-pinned in FROM,
# every upstream pin an ARG, nothing COPYed out of the build context. So the hash
# of that file *is* the build identity, and baking it in as a label answers "is
# this image the one this Containerfile describes?" without rebuilding. That is
# what lets a merged Renovate digest bump reach the host: it changes no unit file
# and no tag, so `podman image exists` alone would keep the old bits forever. No
# label means stale, and it is rebuilt once.
image_inputs_digest() { # containerfile -> sha256 of its bytes
    sha256sum "$1" 2>/dev/null | awk '{ print $1 }'
}

image_is_current() { # image containerfile -> 0 when the label matches the file
    local image="$1" cf="$2" want have
    podman image exists "$image" 2>/dev/null || return 1
    want=$(image_inputs_digest "$cf")
    [ -n "$want" ] || return 1
    have=$(podman image inspect \
        --format '{{if .Labels}}{{index .Labels "org.stack.inputs"}}{{end}}' \
        "$image" 2>/dev/null) || return 1
    [ "$have" = "$want" ]
}

# The same value as it goes onto the image: one place for the label name.
image_inputs_label() { # containerfile -> LABEL=VALUE for podman build --label
    printf 'org.stack.inputs=%s' "$(image_inputs_digest "$1")"
}

# The image a unit is running, falling back to a given tag when the container
# does not exist yet (a fresh host, before the first start). Host-side jobs that
# read a service's own database must not pin a second copy of its Image=: on a
# deployed host the running container answers, so a Renovate bump reaches them
# too. The fallback is a bootstrap default, not a pin to maintain.
container_image_or() { # container default-image
    local img=""
    if command -v podman >/dev/null 2>&1 && podman container exists "$1" 2>/dev/null; then
        img=$(podman inspect "$1" --format '{{.ImageName}}' 2>/dev/null || true)
    fi
    printf '%s' "${img:-$2}"
}
npm_image() {
    container_image_or nginx-proxy-manager "${NPM_IMAGE:-docker.io/jc21/nginx-proxy-manager:2.16.0}"
}
kuma_image() {
    container_image_or uptime-kuma "${UPTIME_KUMA_IMAGE:-docker.io/louislam/uptime-kuma:2}"
}
