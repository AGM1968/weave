#!/usr/bin/env bash
# test-graph-credentials.sh — no free-text graph write path stores a credential
# (wv-320587).
#
# Graph text is committed to .weave/ and mirrored to GitHub issues by wv sync
# --gh, so a token pasted into a node, a learning or a memory is published
# twice. Pinned here:
#   - every credential shape is refused through wv add, and the refusal names
#     the shape, never the value;
#   - every free-text write path refuses one: argv (add, update, done
#     --learning, remember, link --context, quick), --metadata-file from a file
#     and from stdin, bulk-update stdin, import, plan, and memory import from
#     Claude memory files and Codex memory rows (a refused source does not stop
#     the others importing, and the command exits nonzero);
#   - text that only talks about the shapes is not refused, and the repository's
#     own committed graph holds no match;
#   - wv doctor reports a credential already in the graph by node and shape.
#
# The planted tokens are built from fragments at run time, so this file holds
# no credential-shaped literal for a push scanner to find.
set -u
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hot"
WV_DB="$WV_HOT_ZONE/brain.db"
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="graph-credentials-test-agent"
export WV_REQUIRE_LEARNING=0 WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0 WV_DISABLE_AUTOPRUNE=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR" || exit 1
git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
git config core.hooksPath /dev/null

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
q() { sqlite3 "$WV_DB" "$1"; }
rep() { local s=""; while [ "${#s}" -lt "$2" ]; do s="$s$1"; done; printf '%s' "$s"; }
# graph_holds <token>: yes when any node text, metadata or edge context holds it.
graph_holds() {
    local hit
    hit=$(sqlite3 "$WV_DB" "SELECT text || COALESCE(metadata,'') FROM nodes; SELECT COALESCE(context,'') FROM edges;" | grep -cF -- "$1")
    [ "$hit" -gt 0 ] && echo yes || echo no
}

"$WV" init >/dev/null 2>&1
a36=$(rep a 36)
GH="gh""p_$a36"
declare -A SHAPES=(
    [github_token]="$GH"
    [github_pat]="github""_pat_$(rep b 64)"
    [anthropic_key]="sk-""ant-api03-$a36"
    [openai_key]="sk-""proj-$a36"
    [aws_access_key]="AK""IA$(rep A 16)"
    [private_key]="-----BEGIN RSA PRIVATE"" KEY-----"
    [slack_token]="xo""xb-1234567890-abcdef"
    [google_api_key]="AI""za$(rep a 35)"
    [url_credentials]="https://deploy:hunter""2secret@example.com/repo"
    [bearer_token]="Authorization: Bearer ""$a36"
)

echo "every shape is refused, by name, never echoed"
for shape in "${!SHAPES[@]}"; do
    tok="${SHAPES[$shape]}"
    before=$(q "SELECT count(*) FROM nodes;")
    # --force: the duplicate-text guard must not be what refuses these adds.
    err=$("$WV" add "note with $tok inside" --force 2>&1 >/dev/null); rc=$?
    check "$shape: wv add refused" "1 $before" "$([ "$rc" -ne 0 ] && echo 1 || echo 0) $(q "SELECT count(*) FROM nodes;")"
    grep -qF -- "credential-shaped string ($shape)" <<< "$err" && ok "$shape: the refusal names the shape" || bad "$shape: the refusal names the shape" "$err"
    if [ "$rc" -ne 0 ] && ! grep -qF -- "$tok" <<< "$err"; then ok "$shape: the refusal does not echo the value"
    else bad "$shape: the refusal does not echo the value" "rc=$rc"; fi
done

echo "every free-text write path refuses a credential"
NODE=$("$WV" add "target node" --criteria="c1" --risks=low 2>/dev/null | grep -oE 'wv-[0-9a-f]{6}' | head -1)
OTHER=$("$WV" add "other node" --criteria="c1" --risks=low 2>/dev/null | grep -oE 'wv-[0-9a-f]{6}' | head -1)
check "(fixture) two nodes exist" "2" "$(q "SELECT count(*) FROM nodes WHERE id IN ('$NODE','$OTHER');")"
refused() {  # refused <label> <rc>
    check "$1 is refused and stores nothing" "1 no" "$([ "$2" -ne 0 ] && echo 1 || echo 0) $(graph_holds "$GH")"
}
"$WV" add "clean text" --force --metadata="{\"note\":\"$GH\"}" >/dev/null 2>&1; refused "add --metadata" $?
"$WV" update "$NODE" --text="text $GH" >/dev/null 2>&1; refused "update --text" $?
"$WV" update "$NODE" --metadata="{\"note\":\"$GH\"}" >/dev/null 2>&1; refused "update --metadata" $?
printf '{"note":"%s"}\n' "$GH" > "$TEST_DIR/meta.json"
"$WV" update "$NODE" --metadata-file "$TEST_DIR/meta.json" >/dev/null 2>&1; refused "update --metadata-file <file>" $?
"$WV" update "$NODE" --metadata-file - < "$TEST_DIR/meta.json" >/dev/null 2>&1; refused "update --metadata-file - (stdin)" $?
printf '[{"id":"%s","text":"bulk %s"}]\n' "$NODE" "$GH" | "$WV" bulk-update >/dev/null 2>&1; refused "bulk-update stdin" $?
"$WV" link "$NODE" "$OTHER" --type=relates_to --context="{\"why\":\"$GH\"}" >/dev/null 2>&1; refused "link --context" $?
"$WV" remember "memory holding $GH" >/dev/null 2>&1; refused "remember" $?
"$WV" quick "quick fix $GH" >/dev/null 2>&1; refused "quick" $?
"$WV" work "$NODE" >/dev/null 2>&1
"$WV" "done" "$NODE" --skip-verification --learning="pitfall: $GH" >/dev/null 2>&1; refused "done --learning" $?
check "...and the refused close leaves the node open" "active" "$(q "SELECT status FROM nodes WHERE id='$NODE';")"
printf '{"id":"wv-imp001","text":"imported %s","status":"todo"}\n' "$GH" > "$TEST_DIR/import.jsonl"
"$WV" import "$TEST_DIR/import.jsonl" >/dev/null 2>&1; refused "import <file>" $?
printf '# Plan\n\n## Sprint 1: work\n\n- [ ] task carrying %s\n' "$GH" > "$TEST_DIR/plan.md"
"$WV" plan "$TEST_DIR/plan.md" --sprint=1 >/dev/null 2>&1; refused "plan <file>" $?

echo "memory import refuses the credential and imports the rest"
mem="$TEST_DIR/claude-memory"; mkdir -p "$mem"
printf -- '---\nname: clean\ndescription: a clean memory\n---\n\nthe build runs make check first\n' > "$mem/clean.md"
printf -- '---\nname: leaky\ndescription: a leaky memory\n---\n\nthe deploy key is %s\n' "$GH" > "$mem/leaky.md"
out=$("$WV" memory import --source=claude --path="$mem" --repo-root="$TEST_DIR" --json 2>/dev/null); rc=$?
refused "memory import (claude)" "$rc"
check "...the clean file still imports" "1" "$(q "SELECT count(*) FROM nodes WHERE json_extract(metadata,'\$.source_path')='$mem/clean.md';")"
check "...and the report names the refused file" "$mem/leaky.md" "$(jq -r '.refused[0].source_path // empty' <<< "$out")"
fake_home="$TEST_DIR/home"; mkdir -p "$fake_home/.codex"
sqlite3 "$fake_home/.codex/state_5.sqlite" "CREATE TABLE threads (id TEXT, cwd TEXT, rollout_path TEXT, memory_mode TEXT, title TEXT);
    INSERT INTO threads VALUES ('t1', '$TEST_DIR', '$fake_home/.codex/sessions/r1.jsonl', 'auto', 'repo thread');"
sqlite3 "$fake_home/.codex/memories_1.sqlite" "CREATE TABLE stage1_outputs (job_id TEXT, thread_id TEXT, output TEXT);
    INSERT INTO stage1_outputs VALUES ('j1', 't1', 'codex memory holding $GH');"
HOME="$fake_home" "$WV" memory import --source=codex --repo-root="$TEST_DIR" --json >/dev/null 2>&1; rc=$?
refused "memory import (codex)" "$rc"

echo "no false refusal"
"$WV" add "prose about ghp_ and AKIA prefixes, sk-ant- keys, risk-level fields, https://example.com/path and a Bearer token header" >/dev/null 2>&1
check "text that only names the shapes is stored" "0" "$?"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/wv-validate.sh"
check "the repository's committed graph holds no credential shape" "0" \
    "$(cat "$REPO_ROOT/.weave/nodes.jsonl" "$REPO_ROOT/.weave/edges.jsonl" 2>/dev/null | grep -cE -- "$(wv_credential_regex)")"

echo "wv doctor reports a credential already in the graph"
check "a clean graph passes" "pass" \
    "$("$WV" doctor --json 2>/dev/null | jq -r '.checks[] | select(.check == "graph credentials") | .status')"
q "INSERT INTO nodes(id,text,status,metadata) VALUES('wv-leak01','raw write ${SHAPES[aws_access_key]}','todo','{}');"
doc=$("$WV" doctor --json 2>/dev/null | jq -c '.checks[] | select(.check == "graph credentials")')
check "a planted credential warns" "warn" "$(jq -r '.status' <<< "$doc")"
grep -qF -- 'wv-leak01 (aws_access_key)' <<< "$doc" && ok "...naming the node and the shape" || bad "...naming the node and the shape" "$doc"
if [ -n "$doc" ] && ! grep -qF -- "${SHAPES[aws_access_key]}" <<< "$doc"; then ok "...without the value"; else bad "...without the value" "$doc"; fi

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
