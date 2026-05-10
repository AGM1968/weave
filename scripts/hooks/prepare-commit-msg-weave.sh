#!/usr/bin/env sh
# Weave: append Weave-ID trailers to commit messages

COMMIT_MSG_FILE="$1"
COMMIT_SOURCE="$2"

case "$COMMIT_SOURCE" in
    merge|squash) exit 0 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
[ ! -x "$WV" ] && exit 0

ACTIVE_IDS=$("$WV" list --status=active --json 2>/dev/null | jq -r '.[].id' 2>/dev/null)
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