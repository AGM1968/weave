#!/usr/bin/env bash
# gen-skill-provenance.sh — the content-addressed record of every skill version
# Weave has shipped (wv-ef7ad7).
#
# A file is Weave's if its bytes match a version Weave shipped. Skills written
# before the WEAVE-MANAGED-SKILL marker existed carry no marker, so the
# projector (project-procedures.sh) cannot tell Weave's own copy from a user's
# and refuses to replace it; every consumer holds such copies. This script
# lists "<sha256> <skill name>" for every committed version of every
# .claude/skills/<name>/SKILL.md in the given repository's history, so the
# projector can adopt an unedited copy and still refuse an edited one.
#
# The list is derived from git history at install time, never kept by hand:
# install.sh runs it in the clone it installs from (memory-system or the public
# release repository), whose history holds exactly the bytes it shipped.
#
# Usage: gen-skill-provenance.sh [--repo=DIR] [--out=FILE]
# Exit: 0 written; 1 not a git repository or git failed (nothing written).
set -euo pipefail

REPO="$(pwd)"
OUT=""
for arg in "$@"; do
    case "$arg" in
        --repo=*) REPO="${arg#*=}" ;;
        --out=*) OUT="${arg#*=}" ;;
        *) echo "Usage: $0 [--repo=DIR] [--out=FILE]" >&2; exit 2 ;;
    esac
done

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "gen-skill-provenance: $REPO is not a git repository" >&2
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# Every blob ever committed at .claude/skills/<name>/SKILL.md on HEAD's history:
# --raw lists "<old> <new> <status> <path>" per change; the new blob id is the
# version that commit shipped. Deletions carry an all-zero new id and are skipped.
git -C "$REPO" log --format= --raw --no-abbrev --no-renames HEAD -- '.claude/skills/*/SKILL.md' \
    | awk '$5 ~ /^D/ { next }
           { split($NF, p, "/"); if (p[1] == ".claude" && p[2] == "skills" && p[4] == "SKILL.md") print $4, p[3] }' \
    | sort -u \
    | while read -r blob name; do
        [ "$blob" = "0000000000000000000000000000000000000000" ] && continue
        sha=$(git -C "$REPO" cat-file blob "$blob" | sha256sum | cut -d' ' -f1) || exit 1
        printf '%s %s\n' "$sha" "$name"
    done | sort -u > "$tmp"

if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    mv "$tmp" "$OUT"
    trap - EXIT
else
    cat "$tmp"
fi
