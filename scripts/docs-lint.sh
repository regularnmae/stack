#!/usr/bin/env bash
# Check every cross-reference into README and docs/ against the headings that
# exist. A reference is a quoted name right after its target -- `README's "Logs
# and history"`, `docs/units.md, "Healthchecks follow a contract"` -- so a renamed
# section is caught here instead of being discovered months later by someone
# following it.
#
#   scripts/docs-lint.sh            # report dangling references, fail if any
#   scripts/docs-lint.sh --quiet    # exit code only
#
# Why this exists: the operator narrative is README's and the invariants are
# docs/'s, each side says so, and nothing checked that the names still agreed --
# four pointers were already dangling when this was written.
#
# Quotes wrapped across two comment lines are joined first, so an over-long
# reference is still checked. README.md itself is not scanned: it links by anchor
# (`#logs-and-history`), not by section name.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# usage_header is the one reader of a leading block; lib.sh only defines, so
# --help opens no config.
# shellcheck source=lib.sh
. "$REPO_DIR/scripts/lib.sh"

QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1 ;;
        -h|--help)  usage_header "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# The files that carry references. README.md is the target, not a source; the two
# explorers are vendored app code whose README is their own; this file quotes
# example references, so scanning it would read its own documentation as prose;
# tests/ quote README table syntax as fixtures, which is not a reference to it.
mapfile -t SOURCES < <(
    cd "$REPO_DIR" && git ls-files -- \
        '*.sh' '*.md' '*.py' '*.yml' '*.yaml' '*.toml' '*.conf' \
        '*.container' '*.container.in' '*.service' '*.timer' \
        ':!README.md' ':!btc-explorer/*' ':!xmr-explorer/*' \
        ':!scripts/docs-lint.sh' ':!tests/*'
)

# Headings of a markdown file, one per line, without the leading #s.
headings() {
    sed -n 's/^#\{1,4\}[[:space:]]\{1,\}//p' "$1" | sed 's/[[:space:]]*$//'
}

# A logical line is a line plus any following lines needed to close an odd number
# of quotes, so a reference wrapped by a comment's column limit is still one
# reference. The comment prefix is stripped and runs of spaces collapsed, so the
# joined text reads like the sentence it was. Prints "<first-line>\t<text>".
#
# With comments_only, a file is read for its comment lines alone: in code a
# cross-reference is prose and prose is a comment, while a line that merely
# quotes table syntax (a usage string, a test fixture) is not a reference.
logical_lines() { # file [comments_only]
    awk -v comments="${2:-0}" '
        comments && $0 !~ /^[[:space:]]*#/ { next }
        { line = $0; sub(/^[[:space:]]*#+[[:space:]]?/, "", line)
          gsub(/[[:space:]]+/, " ", line)
          sub(/^ /, "", line); sub(/ $/, "", line)
          if (buf == "") start = NR
          buf = (buf == "" ? line : buf " " line)
          tmp = line; gsub(/\\"/, "", tmp)   # an escaped quote is text, not a delimiter
          q += gsub(/"/, "&", tmp)
          if (q % 2 == 0) { print start "\t" buf; buf = ""; q = 0 }
        }
        END { if (buf != "") print start "\t" buf }
    ' "$1"
}

# The quoted names on this line that could be section references. An apostrophe
# inside a word (kuma's) is not an opening quote, and spans that look like code
# (`x/y`, `a.b`, `k=v`) are ignored.
refs_in() {
    grep -oP "(?<![A-Za-z0-9])[\"'][^\"']+[\"']" <<< "$1" \
        | sed -E "s/^[\"']//; s/[\"']$//" \
        | grep -vE '[/.#=$]' || true
}

# In-file anchors: [text](#slug) must resolve to a heading in the same file, with
# GitHub's slug rule (lowercase, punctuation dropped, spaces to hyphens, not
# collapsed -- "Backup & restore" is #backup--restore). A renamed heading breaks a
# link silently, which is the same failure the section names have.
check_anchors() { # markdown-file
    local file="$1" have bad=0 slug
    have=$(sed -n 's/^#\{1,4\}[[:space:]]\{1,\}//p' "$file" \
        | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 _-]//g; s/ /-/g')
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        grep -qxF -- "$slug" <<< "$have" && continue
        printf '  FAIL %s  #%s  (no such heading in the same file)\n' "${file#"$REPO_DIR"/}" "$slug"
        bad=$((bad + 1))
    done < <(grep -oP '\]\(#\K[^)]+' "$file" 2>/dev/null || true)
    fails=$((fails + bad))
}

fails=0
bad() { # source line ref target
    printf '  FAIL %s:%s  "%s"  (no such heading in %s)\n' "$1" "$2" "$3" "$4"
    fails=$((fails + 1))
}

check() { # source-file line-number text target-md
    local src="$1" ln="$2" text="$3" target="$4" ref have
    have=$(headings "$target")
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        grep -qxF -- "$ref" <<< "$have" || bad "$src" "$ln" "$ref" "${target#"$REPO_DIR"/}"
    done < <(refs_in "$text")
}

for src in "${SOURCES[@]}"; do
    while IFS=$'\t' read -r ln text; do
        case "$text" in
            *README*) check "$src" "$ln" "$text" "$REPO_DIR/README.md" ;;
        esac
        case "$src" in
            docs/*.md) ;;
            *) continue ;;
        esac
        for target in $(printf '%s' "$text" | grep -oP 'docs/[a-z-]+\.md'); do
            if [ ! -f "$REPO_DIR/$target" ]; then
                bad "$src" "$ln" "$target" "(the file itself)"
                continue
            fi
            check "$src" "$ln" "$text" "$REPO_DIR/$target"
        done
    done < <(logical_lines "$REPO_DIR/$src" \
             "$([ "${src##*.}" = md ] && echo 0 || echo 1)")
done

check_anchors "$REPO_DIR/README.md"
for f in "$REPO_DIR"/docs/*.md; do
    [ -f "$f" ] && check_anchors "$f"
done

if [ "$fails" -gt 0 ]; then
    printf '%d dangling documentation reference(s)\n' "$fails" >&2
    exit 1
fi
[ "$QUIET" = 1 ] || printf 'documentation references: ok\n'
