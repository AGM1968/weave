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
# projector can adopt an unedited copy and still refuse an edited one, and
# "<sha256> hook:<file>" for every .claude/hooks/<file>.sh version, so a
# retired hook's unedited copy can be removed (wv-96b61e).
#
# The list is derived from git history at install time, never kept by hand:
# install.sh runs it in the clone it installs from (memory-system or the public
# release repository), whose history holds exactly the bytes it shipped.
#
# Usage: gen-skill-provenance.sh [--repo=DIR] [--out=FILE]
# Exit: 0 written; 1 not a git repository or git failed (nothing written).
# wv bash guard (wv-7257a8): bash >= 4 or a clear refusal. Identical in every executed entry point; master: scripts/lib/wv-bash-guard.sh.
_wv_bash_guard() {
    if [ -n "${WV_TEST_BASH_TOO_OLD:-}" ] && [ "${WV_TEST_MODE:-}" != 1 ]; then echo "wv: WV_TEST_BASH_TOO_OLD needs WV_TEST_MODE=1; ignoring it." >&2; fi
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && ! { [ "${WV_TEST_MODE:-}" = 1 ] && [ "${WV_TEST_BASH_TOO_OLD:-}" = 1 ]; }; then
        unset WV_BASH_REEXEC
        return 0
    fi
    local b
    if [ -z "${WV_BASH_REEXEC:-}" ] && [ -f "$0" ]; then
        for b in ${WV_BASH:-} /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
            # shellcheck disable=SC2016  # the child bash expands it
            if [ -x "$b" ] && [ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" -ge 4 ] 2>/dev/null; then
                WV_BASH_REEXEC=1 WV_TEST_BASH_TOO_OLD='' exec "$b" "$0" "$@"
            fi
        done
    fi
    echo "wv: $0 needs bash 4 or newer but is running under bash ${BASH_VERSION:-unknown}." >&2
    echo "    On macOS /bin/bash is 3.2: install a newer one (brew install bash) or set WV_BASH to it." >&2
    exit 1
}
_wv_bash_guard "$@"
# end wv bash guard

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
# Hook versions (.claude/hooks/<file>.sh) are listed as hook:<file>, so a
# retired hook's unedited copy can be told from an edited one (wv-96b61e).
git -C "$REPO" log --format= --raw --no-abbrev --no-renames HEAD -- '.claude/skills/*/SKILL.md' '.claude/hooks/*.sh' \
    | awk '$5 ~ /^D/ { next }
           { n = split($NF, p, "/")
             if (n == 4 && p[1] == ".claude" && p[2] == "skills" && p[4] == "SKILL.md") print $4, p[3]
             else if (n == 3 && p[1] == ".claude" && p[2] == "hooks" && p[3] ~ /\.sh$/) print $4, "hook:" p[3] }' \
    | sort -u \
    | while read -r blob name; do
        [ "$blob" = "0000000000000000000000000000000000000000" ] && continue
        # shasum where macOS has no sha256sum (wv-7d7d41)
        sha=$(git -C "$REPO" cat-file blob "$blob" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1) || exit 1
        printf '%s %s\n' "$sha" "$name"
    done | sort -u > "$tmp"

if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    mv "$tmp" "$OUT"
    trap - EXIT
else
    cat "$tmp"
fi
