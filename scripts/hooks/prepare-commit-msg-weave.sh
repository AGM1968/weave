#!/usr/bin/env sh
# Weave: append Weave-ID trailers to commit messages

# Stale-copy guard (wv-98f12b): see pre-commit-weave.sh.
_wv_root="$(git rev-parse --show-toplevel 2>/dev/null)"
_wv_hook_src="$_wv_root/scripts/hooks/prepare-commit-msg-weave.sh"
if [ -z "${WV_HOOK_REEXEC:-}" ] && [ -f "$_wv_hook_src" ] && ! cmp -s "$_wv_hook_src" "$0"; then
    # ./install.sh exists only in Weave's own tree; a consumer whose vendored
    # source wv init-repo wrote refreshes with wv (wv-376de3).
    _wv_refresh='wv self-update, then wv init-repo --update'
    [ "$(git ls-tree HEAD -- install.sh scripts/wv 2>/dev/null | wc -l)" -eq 2 ] && _wv_refresh='./install.sh'
    echo "Weave prepare-commit-msg: installed hook differs from scripts/hooks/prepare-commit-msg-weave.sh — running the source (refresh with $_wv_refresh)" >&2
    WV_HOOK_REEXEC=1
    export WV_HOOK_REEXEC
    exec sh "$_wv_hook_src" "$@"
fi

COMMIT_MSG_FILE="$1"
COMMIT_SOURCE="$2"

case "$COMMIT_SOURCE" in
    merge|squash) exit 0 ;;
esac

git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
# wv on PATH, else the one beside this hook (scripts/wv when the source runs),
# else the installed copy. Never the working tree through REPO_ROOT, which a
# changed gate file may not name (S2b review N1, wv-376de3).
_wv_beside="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/wv"
WV="$(command -v wv 2>/dev/null)" || WV=""
[ -n "$WV" ] || { [ -x "$_wv_beside" ] && WV="$_wv_beside"; } || WV="$HOME/.local/bin/wv"
[ ! -x "$WV" ] && exit 0
# Tag this hook's wv calls as hook traffic, keeping a test run's tag (wv-f47c10;
# see pre-commit-weave.sh).
[ "${WV_CALL_SOURCE:-}" = "test" ] || { WV_CALL_SOURCE=hook; export WV_CALL_SOURCE; }

ACTIVE_IDS=$("$WV" list --status=active --claimed-by=current --json 2>/dev/null | jq -r '.[].id' 2>/dev/null)
[ -z "$ACTIVE_IDS" ] && exit 0
grep -q "^Weave-ID:" "$COMMIT_MSG_FILE" 2>/dev/null && exit 0

for id in $ACTIVE_IDS; do
    if grep -q "^Co-Authored-By:" "$COMMIT_MSG_FILE" 2>/dev/null; then
        tmp="${COMMIT_MSG_FILE}.wv$$"
        awk -v wid="Weave-ID: $id" '/^Co-Authored-By:/ && !done {print wid; done=1} {print}' \
            "$COMMIT_MSG_FILE" > "$tmp" && mv "$tmp" "$COMMIT_MSG_FILE"
    else
        printf '\nWeave-ID: %s\n' "$id" >> "$COMMIT_MSG_FILE"
    fi
done

exit 0
