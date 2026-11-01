#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

SCRATCH=$(bash "$PROJECT_ROOT/scripts/lib/wv-scratch.sh")
export TMPDIR="$SCRATCH"
unset WV_SCRATCH_ROOT
TEST_DIR="$SCRATCH/repo"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$WV_HOT_ZONE/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_PROJECT_DIR="$TEST_DIR"
export WV_SUITE_LOG="$TEST_DIR/suite_runs.jsonl"

cleanup() {
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

assert_jq_true() {
    local json="$1"
    local jq_expr="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$json" | jq -e "$jq_expr" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  jq: $jq_expr"
        echo "  In: $json"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
    "$WV" init >/dev/null 2>&1
}

test_memory_lifecycle_contract_shapes() {
    echo ""
    echo "Test: memory lifecycle contract shapes"
    echo "======================================"

    setup_test_env

    local remembered memory_id recall_json render_json scan_json import_json dry_json applied_json
    remembered=$("$WV" remember "Lifecycle contract fact" --kind=project --scope=repo --source-agent=contract --json)
    memory_id=$(printf '%s' "$remembered" | jq -r '.id')

    assert_jq_true "$remembered" \
        '.id | test("^wv-[a-f0-9]+$")' \
        "contract: remember returns a node id"
    assert_jq_true "$remembered" \
        '.status == "done" and .text == "Lifecycle contract fact" and .metadata.type == "memory" and .metadata.mem_status == "active" and .metadata.source_agent == "contract" and .metadata.source_kind == "remember" and (.metadata.verified_at | test("T"))' \
        "contract: remember JSON carries active memory lifecycle metadata"

    recall_json=$("$WV" memory recall --agent=codex --json 2>/dev/null)
    assert_jq_true "$recall_json" \
        'type == "array" and length == 1 and .[0].id == "'"$memory_id"'" and .[0].metadata.type == "memory" and .[0].metadata.mem_status == "active" and .[0].metadata.source_kind == "remember"' \
        "contract: recall JSON is an agent-agnostic active-memory array"

    mkdir -p "$TEST_DIR/.codex"
    render_json=$("$WV" memory render --agent=codex --path="$TEST_DIR/.codex/weave.json" --json)
    assert_jq_true "$render_json" \
        '.projection == "codex" and .path == "'"$TEST_DIR"'/.codex/weave.json" and (.paths | length == 1) and .paths[0].projection == "codex" and .entries == 1' \
        "contract: render JSON reports projection, paths, and entry count"
    assert_jq_true "$(cat "$TEST_DIR/.codex/weave.json")" \
        '.memory.authority == "weave-graph" and .memory.lifecycle_field == "metadata.mem_status" and .memory.entries[0].id == "'"$memory_id"'" and .memory.entries[0].metadata.mem_status == "active"' \
        "contract: rendered Codex projection preserves graph authority and lifecycle metadata"

    local fake_home slug claude_project claude_memory_dir
    fake_home="$TEST_DIR/home"
    slug=$(printf '%s' "$TEST_DIR" | tr '/' '-')
    claude_project="$fake_home/.claude/projects/$slug"
    claude_memory_dir="$claude_project/memory"
    mkdir -p "$claude_memory_dir"
    printf '%s\n' "# Contract" "Imported contract candidate" > "$claude_memory_dir/project.md"
    printf '%s\n' '{"event":"session"}' > "$claude_project/session.jsonl"

    scan_json=$(HOME="$fake_home" "$WV" memory scan --source=claude --repo-root="$TEST_DIR" --json)
    assert_jq_true "$scan_json" \
        'type == "array" and any(.[]; .source_agent == "claude" and .source_kind == "memory_file" and (.source_path | endswith("/memory/project.md")) and .repo_root == "'"$TEST_DIR"'") and any(.[]; .source_agent == "claude" and .source_kind == "session")' \
        "contract: scan JSON reports observations with source provenance"

    import_json=$(HOME="$fake_home" "$WV" memory import --source=claude --path="$claude_memory_dir" --repo-root="$TEST_DIR" --json)
    assert_jq_true "$import_json" \
        '.count == 1 and .skipped == 0 and (.imported | length == 1) and (.imported[0].id | test("^wv-[a-f0-9]+$")) and (.imported[0].source_path | endswith("/memory/project.md"))' \
        "contract: import JSON reports imported candidates and skipped count"

    local candidate_id
    candidate_id=$(printf '%s' "$import_json" | jq -r '.imported[0].id')
    assert_equals "candidate" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$candidate_id';")" "contract: imported memory starts as candidate"

    "$WV" update "$candidate_id" --metadata='{"reviewed":true}' >/dev/null 2>&1
    dry_json=$("$WV" memory crystallize --dry-run --repo-root="$TEST_DIR" --json)
    assert_jq_true "$dry_json" \
        '.mode == "dry-run" and .candidates >= 1 and any(.results[]; .id == "'"$candidate_id"'" and .action == "promote" and .reviewed == true)' \
        "contract: crystallize dry-run reports candidate actions without mutation"
    assert_equals "candidate" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$candidate_id';")" "contract: dry-run leaves candidate status unchanged"

    applied_json=$("$WV" memory crystallize --apply-reviewed --repo-root="$TEST_DIR" --json)
    assert_jq_true "$applied_json" \
        '.mode == "apply-reviewed" and .candidates >= 1 and any(.results[]; .id == "'"$candidate_id"'" and .action == "promote" and .reviewed == true)' \
        "contract: crystallize apply-reviewed reports applied actions"
    assert_equals "active" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$candidate_id';")" "contract: apply-reviewed promotes reviewed candidates"
}

test_remember_recall_ready_and_render() {
    echo ""
    echo "Test: graph-native memory"
    echo "========================="

    setup_test_env

    local remembered memory_id mem_type mem_status recall_json
    remembered=$("$WV" remember "Use WORKFLOW.md as the canonical bridge" --kind=project --scope=repo --source-agent=test --json)
    memory_id=$(printf '%s' "$remembered" | jq -r '.id')
    mem_type=$(printf '%s' "$remembered" | jq -r '.metadata.type')
    mem_status=$(printf '%s' "$remembered" | jq -r '.metadata.mem_status')

    assert_contains "$memory_id" "wv-" "remember returns a node id"
    assert_equals "memory" "$mem_type" "remember stores metadata.type=memory"
    assert_equals "active" "$mem_status" "remember stores metadata.mem_status=active"

    local dynamic_agent
    dynamic_agent=$(WV_OPERATING_AGENT=copilot "$WV" remember "Dynamic agent identity" --json | jq -r '.metadata.source_agent')
    assert_equals "copilot" "$dynamic_agent" "remember resolves operating agent dynamically"

    # Memory provenance takes its harness from resolve_agent_harness, the ladder
    # claimed_by uses, so the two agree when markers collide; it kept its own
    # codex-first copy until wv-50640a. CLAUDECODE=1 alone is Claude Code.
    local _no_agent=(-u WV_OPERATING_AGENT -u WV_AGENT_NAME -u WV_AGENT_ID -u CLAUDE_PROJECT_DIR
        -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT)
    local tie_agent tie_claim
    tie_agent=$(env "${_no_agent[@]}" CLAUDE_CODE_SSE_PORT=1 CODEX_CI=1 \
        "$WV" remember "Marker tie provenance" --json 2>/dev/null | jq -r '.metadata.source_agent')
    tie_claim=$(env "${_no_agent[@]}" CLAUDE_CODE_SSE_PORT=1 CODEX_CI=1 \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_agent_id" 2>/dev/null)
    assert_equals "${tie_claim%%-*}" "$tie_agent" "remember and claimed_by agree on a claude/codex marker tie"
    assert_equals "claude" "$(env "${_no_agent[@]}" CLAUDECODE=1 \
        "$WV" remember "CLAUDECODE provenance" --json 2>/dev/null | jq -r '.metadata.source_agent')" \
        "remember resolves CLAUDECODE=1 alone as claude"

    recall_json=$("$WV" memory recall --agent=codex --json)
    assert_contains "$recall_json" "Use WORKFLOW.md as the canonical bridge" "memory recall returns active memories"

    local claude_ids codex_ids copilot_ids mcp_ids native_ids all_ids
    claude_ids=$("$WV" memory recall --agent=claude --json | jq -c '[.[].id] | sort')
    codex_ids=$("$WV" memory recall --agent=codex --json | jq -c '[.[].id] | sort')
    copilot_ids=$("$WV" memory recall --agent=copilot --json | jq -c '[.[].id] | sort')
    mcp_ids=$("$WV" memory recall --agent=mcp --json | jq -c '[.[].id] | sort')
    native_ids=$("$WV" memory recall --agent=native --json | jq -c '[.[].id] | sort')
    all_ids=$("$WV" memory recall --agent=all --json | jq -c '[.[].id] | sort')
    assert_equals "$all_ids" "$claude_ids" "claude recall sees the shared graph memory set"
    assert_equals "$all_ids" "$codex_ids" "codex recall sees the shared graph memory set"
    assert_equals "$all_ids" "$copilot_ids" "copilot recall sees the shared graph memory set"
    assert_equals "$all_ids" "$mcp_ids" "mcp recall sees the shared graph memory set"
    assert_equals "$all_ids" "$native_ids" "native recall sees the shared graph memory set"

    "$WV" add "candidate memory should not be ready" \
        --metadata='{"type":"memory","mem_status":"candidate"}' \
        --force >/dev/null 2>&1
    local ready_json ready_text
    ready_json=$("$WV" ready --json)
    ready_text=$("$WV" ready --mode=bootstrap)
    assert_equals "0" "$(printf '%s' "$ready_json" | jq '[.[] | select(.text == "candidate memory should not be ready")] | length')" "ready JSON excludes type=memory"
    assert_equals "" "$ready_text" "ready text excludes type=memory"

    mkdir -p "$TEST_DIR/.codex"
    # shellcheck disable=SC2016  # the expected text contains a literal $ reference
    printf '%s\n' '{"schema":"weave.codex.v1","bootstrap":{"command":"./scripts/wv bootstrap-agent --json","fallback":"$HOME/.local/bin/wv bootstrap-agent --json"}}' > "$TEST_DIR/.codex/weave.json"
    local render_json rendered_authority rendered_command rendered_count
    render_json=$("$WV" memory render --agent=codex --path="$TEST_DIR/.codex/weave.json" --json)
    rendered_authority=$(jq -r '.memory.authority' "$TEST_DIR/.codex/weave.json")
    rendered_command=$(jq -r '.memory.recall.command' "$TEST_DIR/.codex/weave.json")
    rendered_count=$(jq '[.memory.entries[] | select(.text == "Use WORKFLOW.md as the canonical bridge")] | length' "$TEST_DIR/.codex/weave.json")

    assert_equals "$TEST_DIR/.codex/weave.json" "$(printf '%s' "$render_json" | jq -r '.path')" "render reports target path"
    assert_equals "weave-graph" "$rendered_authority" "render marks graph as memory authority"
    assert_equals "./scripts/wv memory recall --agent=all --json" "$rendered_command" "render uses agent-agnostic graph recall"
    assert_equals "1" "$rendered_count" "render writes active memory entries"

    printf '%s\n' "# Weave Workflow Reference" > "$TEST_DIR/WORKFLOW.md"
    local workflow_json workflow_block_count
    workflow_json=$("$WV" memory render --agent=workflow --path="$TEST_DIR/WORKFLOW.md" --json)
    workflow_block_count=$(grep -c "BEGIN WEAVE:MEMORY" "$TEST_DIR/WORKFLOW.md")
    assert_equals "$TEST_DIR/WORKFLOW.md" "$(printf '%s' "$workflow_json" | jq -r '.path')" "workflow render reports target path"
    assert_equals "workflow" "$(printf '%s' "$workflow_json" | jq -r '.projection')" "workflow render reports shared projection"
    assert_equals "1" "$workflow_block_count" "workflow render writes one managed memory block"
    assert_contains "$(cat "$TEST_DIR/WORKFLOW.md")" "Capture records dynamic agent provenance, but recall is agent-agnostic" "workflow render is agent-neutral"

    printf '%s\n' "universal" > "$TEST_DIR/AGENTS.md"
    printf '%s\n' "# Claude" > "$TEST_DIR/CLAUDE.md"
    mkdir -p "$TEST_DIR/.github"
    printf '%s\n' "# Copilot" > "$TEST_DIR/.github/copilot-instructions.md"
    local all_render_json all_render_count
    all_render_json=$("$WV" memory render --agent=all --base-dir="$TEST_DIR" --json)
    all_render_count=$(printf '%s' "$all_render_json" | jq '.paths | length')
    assert_equals "3" "$all_render_count" "render all writes the loaded projections (CLAUDE.md, weave.json, copilot; AGENTS.md is marker-gated)"
    assert_equals "universal" "$(cat "$TEST_DIR/AGENTS.md")" "render all does not touch AGENTS.md"
    assert_contains "$(cat "$TEST_DIR/CLAUDE.md")" "verified:" "CLAUDE projection includes verified_at"
    # wv-91f0ca: no harness loads these two, so render all no longer writes them.
    assert_equals "absent absent" "$([ -e "$TEST_DIR/.claude/MEMORY.md" ] && echo present || echo absent) $([ -e "$TEST_DIR/.codex/MEMORY.md" ] && echo present || echo absent)" "render all writes no .claude/MEMORY.md or .codex/MEMORY.md"
    "$WV" memory render --agent=claude-memory --base-dir="$TEST_DIR" --json >/dev/null
    assert_contains "$(cat "$TEST_DIR/.claude/MEMORY.md")" "$memory_id" "an explicit claude-memory render still writes it"
    rm -f "$TEST_DIR/.claude/MEMORY.md"
    assert_contains "$(cat "$TEST_DIR/.github/copilot-instructions.md")" "$memory_id" "Copilot projection includes source node id"
    assert_equals "weave-graph" "$(jq -r '.memory.authority' "$TEST_DIR/.codex/weave.json")" "Codex contract projection marks graph authority"
    assert_equals "$memory_id" "$(jq -r --arg id "$memory_id" '.memory.entries[] | select(.id == $id) | .id' "$TEST_DIR/.codex/weave.json")" "Codex contract entries include source node id"
    assert_contains "$(jq -r --arg id "$memory_id" '.memory.entries[] | select(.id == $id) | (.metadata.verified_at // "unknown")' "$TEST_DIR/.codex/weave.json")" "T" "Codex contract entries carry verified_at metadata"

    "$WV" memory render --agent=all --base-dir="$TEST_DIR" --json >/dev/null
    assert_equals "1" "$(grep -c "BEGIN WEAVE:MEMORY" "$TEST_DIR/CLAUDE.md")" "CLAUDE projection is idempotent"
    assert_equals "1" "$(grep -c "BEGIN WEAVE:MEMORY" "$TEST_DIR/.github/copilot-instructions.md")" "Copilot projection is idempotent"

    sqlite3 "$WV_DB" "UPDATE nodes SET updated_at = datetime('now', '-72 hours') WHERE id='$memory_id';"
    local prune_dry_run post_prune_recall memory_live_count
    prune_dry_run=$("$WV" prune --age=48h --dry-run)
    assert_equals "0" "$(grep -c -- "$memory_id" <<<"$prune_dry_run" || true)" "prune dry-run excludes durable memory nodes"

    "$WV" prune --age=48h >/dev/null
    memory_live_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$memory_id';")
    post_prune_recall=$("$WV" memory recall --agent=all --json)
    assert_equals "1" "$memory_live_count" "prune keeps durable memory node live"
    assert_equals "1" "$(printf '%s' "$post_prune_recall" | jq --arg id "$memory_id" '[.[] | select(.id == $id)] | length')" "pruned-age memory remains recalled"
}

test_memory_scan_and_import() {
    echo ""
    echo "Test: harness memory scan and import"
    echo "===================================="

    setup_test_env

    local fake_home slug claude_project claude_memory_dir
    fake_home="$TEST_DIR/home"
    slug=$(printf '%s' "$TEST_DIR" | tr '/' '-')
    claude_project="$fake_home/.claude/projects/$slug"
    claude_memory_dir="$claude_project/memory"

    mkdir -p "$claude_memory_dir"
    printf '%s\n' "# Project Memory" "Consumer repos receive repo-local WORKFLOW projections." > "$claude_memory_dir/project.md"
    printf '%s\n' '{"event":"session"}' > "$claude_project/session.jsonl"

    mkdir -p "$fake_home/.codex/sessions/2026/06/18" "$fake_home/.codex/sessions/2026/06/19"
    sqlite3 "$fake_home/.codex/state_5.sqlite" "CREATE TABLE threads (id TEXT, cwd TEXT, rollout_path TEXT, memory_mode TEXT, title TEXT);"
    sqlite3 "$fake_home/.codex/state_5.sqlite" "INSERT INTO threads VALUES ('t1', '$TEST_DIR', '$fake_home/.codex/sessions/2026/06/18/rollout-test.jsonl', 'auto', 'repo thread');"
    sqlite3 "$fake_home/.codex/state_5.sqlite" "INSERT INTO threads VALUES ('t2', '/other/repo', '$fake_home/.codex/sessions/2026/06/19/rollout-other.jsonl', 'auto', 'other thread');"
    sqlite3 "$fake_home/.codex/memories_1.sqlite" "CREATE TABLE stage1_outputs (job_id TEXT, thread_id TEXT, output TEXT);"
    sqlite3 "$fake_home/.codex/memories_1.sqlite" "INSERT INTO stage1_outputs VALUES ('j1', 't1', 'codex extracted memory candidate');"
    sqlite3 "$fake_home/.codex/memories_1.sqlite" "INSERT INTO stage1_outputs VALUES ('j2', 't2', 'other repo codex memory');"
    printf '%s\n' '{"prompt":"memory"}' > "$fake_home/.codex/history.jsonl"
    printf '%s\n' '{"event":"rollout"}' > "$fake_home/.codex/sessions/2026/06/18/rollout-test.jsonl"
    printf '%s\n' '{"event":"other"}' > "$fake_home/.codex/sessions/2026/06/19/rollout-other.jsonl"

    mkdir -p \
        "$fake_home/.config/Code/User/workspaceStorage/ws1/chatSessions" \
        "$fake_home/.config/Code/User/workspaceStorage/ws1/chatEditingSessions/edit1" \
        "$fake_home/.config/Code/User/workspaceStorage/ws1/GitHub.copilot-chat" \
        "$fake_home/.config/Code/User/workspaceStorage/ws2/chatSessions"
    printf '{"folder":"file://%s"}\n' "$TEST_DIR" > "$fake_home/.config/Code/User/workspaceStorage/ws1/workspace.json"
    printf '%s\n' '{"message":"chat"}' > "$fake_home/.config/Code/User/workspaceStorage/ws1/chatSessions/chat.jsonl"
    printf '%s\n' '{"state":"editing"}' > "$fake_home/.config/Code/User/workspaceStorage/ws1/chatEditingSessions/edit1/state.json"
    : > "$fake_home/.config/Code/User/workspaceStorage/ws1/GitHub.copilot-chat/codebase.sqlite"
    printf '%s\n' '{"folder":"file:///other/repo"}' > "$fake_home/.config/Code/User/workspaceStorage/ws2/workspace.json"
    printf '%s\n' '{"message":"other"}' > "$fake_home/.config/Code/User/workspaceStorage/ws2/chatSessions/other.jsonl"

    local claude_scan codex_scan copilot_scan all_scan
    claude_scan=$(HOME="$fake_home" "$WV" memory scan --source=claude --repo-root="$TEST_DIR" --json)
    codex_scan=$(HOME="$fake_home" "$WV" memory scan --source=codex --repo-root="$TEST_DIR" --json)
    copilot_scan=$(HOME="$fake_home" "$WV" memory scan --source=copilot --repo-root="$TEST_DIR" --json)
    all_scan=$(HOME="$fake_home" "$WV" memory scan --source=all --repo-root="$TEST_DIR" --json)

    assert_equals "1" "$(printf '%s' "$claude_scan" | jq '[.[] | select(.source_agent == "claude" and .source_kind == "memory_file")] | length')" "Claude scanner finds project memory files"
    assert_equals "1" "$(printf '%s' "$claude_scan" | jq '[.[] | select(.source_agent == "claude" and .source_kind == "session")] | length')" "Claude scanner finds session jsonl files"
    assert_equals "1" "$(printf '%s' "$codex_scan" | jq '[.[] | select(.source_agent == "codex" and .source_kind == "thread_db" and .source_session == "t1")] | length')" "Codex scanner finds repo-scoped thread rows"
    assert_equals "1" "$(printf '%s' "$codex_scan" | jq '[.[] | select(.source_agent == "codex" and .source_kind == "rollout" and (.source_path | contains("rollout-test.jsonl")))] | length')" "Codex scanner follows repo thread rollout_path"
    assert_equals "0" "$(printf '%s' "$codex_scan" | jq '[.[] | select(.source_agent == "codex" and (.source_path | contains("rollout-other.jsonl")))] | length')" "Codex scanner excludes other repos' rollouts"
    assert_equals "1" "$(printf '%s' "$codex_scan" | jq '[.[] | select(.source_agent == "codex" and .source_kind == "memory_db" and (.excerpt | contains("codex extracted")))] | length')" "Codex scanner reads memory pipeline stage1 outputs"
    assert_equals "0" "$(printf '%s' "$codex_scan" | jq '[.[] | select(.source_agent == "codex" and .source_kind == "memory_db" and (.excerpt | contains("other repo")))] | length')" "Codex scanner excludes other repos' memory DB outputs"
    assert_equals "1" "$(printf '%s' "$copilot_scan" | jq '[.[] | select(.source_agent == "copilot" and .source_kind == "workspace")] | length')" "Copilot scanner maps the repo workspace"
    assert_equals "0" "$(printf '%s' "$copilot_scan" | jq '[.[] | select(.source_agent == "copilot" and .source_kind == "index_db")] | length')" "Copilot scanner treats index DBs as caches, not memory observations"
    assert_equals "1" "$(printf '%s' "$copilot_scan" | jq '[.[] | select(.source_agent == "copilot" and .source_kind == "editing_state")] | length')" "Copilot scanner finds editing state files"
    assert_equals "0" "$(printf '%s' "$copilot_scan" | jq '[.[] | select(.source_agent == "copilot" and (.source_path | contains("other.jsonl")))] | length')" "Copilot scanner excludes other workspaces"
    assert_equals "3" "$(printf '%s' "$all_scan" | jq '[.[].source_agent] | unique | length')" "all scanner reports every supported agent"

    local import_json imported_id imported_show recall_json ready_json
    import_json=$(HOME="$fake_home" "$WV" memory import --source=claude --path="$claude_memory_dir" --repo-root="$TEST_DIR" --json)
    imported_id=$(printf '%s' "$import_json" | jq -r '.imported[0].id')
    imported_show=$("$WV" show "$imported_id" --json-v2)
    recall_json=$("$WV" memory recall --agent=all --json)
    ready_json=$("$WV" ready --json)

    assert_equals "1" "$(printf '%s' "$import_json" | jq -r '.count')" "Claude import creates one candidate node"
    assert_contains "$imported_id" "wv-" "Claude import returns a node id"
    assert_equals "memory" "$(printf '%s' "$imported_show" | jq -r '.[0].metadata.type')" "Claude import stores metadata.type=memory"
    assert_equals "candidate" "$(printf '%s' "$imported_show" | jq -r '.[0].metadata.mem_status')" "Claude import stores candidate lifecycle"
    assert_equals "claude" "$(printf '%s' "$imported_show" | jq -r '.[0].metadata.source_agent')" "Claude import records source agent as provenance"
    assert_equals "$TEST_DIR" "$(printf '%s' "$imported_show" | jq -r '.[0].metadata.repo_root')" "Claude import records repo root"
    assert_equals "64" "$(printf '%s' "$imported_show" | jq -r '.[0].metadata.source_hash | length')" "Claude import records source hash"
    assert_equals "0" "$(printf '%s' "$recall_json" | jq --arg id "$imported_id" '[.[] | select(.id == $id)] | length')" "candidate imports are not active recall"
    assert_equals "0" "$(printf '%s' "$ready_json" | jq --arg id "$imported_id" '[.[] | select(.id == $id)] | length')" "candidate imports do not surface in ready"

    # Idempotency: re-importing the same dir creates no new nodes and reports skips.
    local claude_reimport claude_candidates_before claude_candidates_after
    claude_candidates_before=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_agent')='claude' AND json_extract(metadata,'\$.source_kind')='memory_file';")
    claude_reimport=$(HOME="$fake_home" "$WV" memory import --source=claude --path="$claude_memory_dir" --repo-root="$TEST_DIR" --json)
    claude_candidates_after=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_agent')='claude' AND json_extract(metadata,'\$.source_kind')='memory_file';")
    assert_equals "0" "$(printf '%s' "$claude_reimport" | jq -r '.count')" "Claude re-import is idempotent (no new candidates)"
    assert_equals "1" "$(printf '%s' "$claude_reimport" | jq -r '.skipped')" "Claude re-import reports skipped count"
    assert_equals "$claude_candidates_before" "$claude_candidates_after" "Claude re-import does not duplicate candidate nodes"

    # wv-99990b: Claude's MEMORY.md index is not a memory, and an edited file
    # leaves one live candidate, not the old import beside the new one.
    local index_import edited_import first_file new_id old_status
    printf '%s\n' '- [Note](note.md) — an index line' > "$claude_memory_dir/MEMORY.md"
    index_import=$(HOME="$fake_home" "$WV" memory import --source=claude --path="$claude_memory_dir" --repo-root="$TEST_DIR" --json)
    assert_equals "0 1" "$(jq -r '"\(.count) \(.skipped_index)"' <<< "$index_import")" "Claude import skips the MEMORY.md index"
    assert_equals "0" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%/MEMORY.md';")" "no candidate is made of the index"
    assert_equals "memory_index" "$(HOME="$fake_home" "$WV" memory scan --source=claude --repo-root="$TEST_DIR" --json | jq -r '[.[] | select(.source_path | endswith("/MEMORY.md"))][0].source_kind')" "scan labels the index apart from memory files"
    first_file=$(printf '%s' "$import_json" | jq -r '.imported[0].source_path')
    printf '\nEdited after the first import.\n' >> "$first_file"
    edited_import=$(HOME="$fake_home" "$WV" memory import --source=claude --path="$claude_memory_dir" --repo-root="$TEST_DIR" --json)
    new_id=$(jq -r '.imported[0].id' <<< "$edited_import")
    old_status=$("$WV" show "$imported_id" --json-v2 | jq -r '.[0].metadata | "\(.mem_status) \(.superseded_by)"')
    assert_equals "1" "$(jq -r '.count' <<< "$edited_import")" "an edited file is imported again"
    assert_equals "superseded $new_id" "$old_status" "the earlier candidate is superseded by the new import"
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_path')='$first_file' AND json_extract(metadata,'\$.mem_status')='candidate';")" "one live candidate per source file"
    # An active memory from the same file is named for review, not superseded.
    sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(metadata,'\$.mem_status','active') WHERE id='$new_id';"
    printf '\nEdited a second time.\n' >> "$first_file"
    edited_import=$(HOME="$fake_home" "$WV" memory import --source=claude --path="$claude_memory_dir" --repo-root="$TEST_DIR" --json)
    assert_equals "active [\"$new_id\"]" "$("$WV" show "$new_id" --json-v2 | jq -r '.[0].metadata.mem_status') $("$WV" show "$(jq -r '.imported[0].id' <<< "$edited_import")" --json-v2 | jq -c '.[0].metadata.revises')" "a changed source names the active memory it revises and leaves it active"
    sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(metadata,'\$.mem_status','superseded') WHERE id='$new_id';"
    rm -f "$claude_memory_dir/MEMORY.md"

    local codex_import_json codex_id codex_show recall_after_codex ready_after_codex
    codex_import_json=$(HOME="$fake_home" "$WV" memory import --source=codex --repo-root="$TEST_DIR" --json)
    codex_id=$(printf '%s' "$codex_import_json" | jq -r '.imported[0].id')
    codex_show=$("$WV" show "$codex_id" --json-v2)
    recall_after_codex=$("$WV" memory recall --agent=all --json)
    ready_after_codex=$("$WV" ready --json)

    assert_equals "1" "$(printf '%s' "$codex_import_json" | jq -r '.count')" "Codex import creates one candidate node from repo-scoped memory_db observations"
    assert_contains "$codex_id" "wv-" "Codex import returns a node id"
    assert_equals "codex extracted memory candidate" "$(printf '%s' "$codex_show" | jq -r '.[0].text')" "Codex import stores memory_db excerpt as text"
    assert_equals "memory" "$(printf '%s' "$codex_show" | jq -r '.[0].metadata.type')" "Codex import stores metadata.type=memory"
    assert_equals "candidate" "$(printf '%s' "$codex_show" | jq -r '.[0].metadata.mem_status')" "Codex import stores candidate lifecycle"
    assert_equals "codex" "$(printf '%s' "$codex_show" | jq -r '.[0].metadata.source_agent')" "Codex import records source agent as provenance"
    assert_equals "memory_db" "$(printf '%s' "$codex_show" | jq -r '.[0].metadata.source_kind')" "Codex import records source kind"
    assert_equals "j1" "$(printf '%s' "$codex_show" | jq -r '.[0].metadata.source_session')" "Codex import records source session"
    assert_equals "$TEST_DIR" "$(printf '%s' "$codex_show" | jq -r '.[0].metadata.repo_root')" "Codex import records repo root"
    assert_equals "64" "$(printf '%s' "$codex_show" | jq -r '.[0].metadata.source_hash | length')" "Codex import records deterministic source hash"
    assert_equals "0" "$(printf '%s' "$recall_after_codex" | jq --arg id "$codex_id" '[.[] | select(.id == $id)] | length')" "Codex candidates are not active recall"
    assert_equals "0" "$(printf '%s' "$ready_after_codex" | jq --arg id "$codex_id" '[.[] | select(.id == $id)] | length')" "Codex candidates do not surface in ready"

    # Idempotency: re-importing the same Codex rows creates no new nodes and reports skips.
    local codex_reimport codex_candidates_before codex_candidates_after
    codex_candidates_before=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_agent')='codex' AND json_extract(metadata,'\$.source_kind')='memory_db';")
    codex_reimport=$(HOME="$fake_home" "$WV" memory import --source=codex --repo-root="$TEST_DIR" --json)
    codex_candidates_after=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_agent')='codex' AND json_extract(metadata,'\$.source_kind')='memory_db';")
    assert_equals "0" "$(printf '%s' "$codex_reimport" | jq -r '.count')" "Codex re-import is idempotent (no new candidates)"
    assert_equals "1" "$(printf '%s' "$codex_reimport" | jq -r '.skipped')" "Codex re-import reports skipped count"
    assert_equals "$codex_candidates_before" "$codex_candidates_after" "Codex re-import does not duplicate candidate nodes"

    # wv-99990b: Codex rewrote the thread's output; one live candidate per thread.
    local codex_edited codex_new
    sqlite3 "$fake_home/.codex/memories_1.sqlite" "UPDATE stage1_outputs SET output='codex extracted memory candidate, revised' WHERE thread_id='t1';"
    codex_edited=$(HOME="$fake_home" "$WV" memory import --source=codex --repo-root="$TEST_DIR" --json)
    codex_new=$(jq -r '.imported[0].id' <<< "$codex_edited")
    assert_equals "superseded $codex_new" "$("$WV" show "$codex_id" --json-v2 | jq -r '.[0].metadata | "\(.mem_status) \(.superseded_by)"')" "a revised Codex output supersedes the thread's earlier candidate"
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_agent')='codex' AND json_extract(metadata,'\$.mem_status')='candidate';")" "one live Codex candidate per thread"
}

test_memory_crystallize() {
    echo ""
    echo "Test: memory crystallization (S4)"
    echo "================================="

    setup_test_env

    # Real file the "clean" candidate references, so verify keeps it.
    mkdir -p "$TEST_DIR/scripts"
    printf '#wv\n' > "$TEST_DIR/scripts/wv"

    # Seed an active memory the contradiction candidate will oppose (shared FTS
    # terms: production deployment pipeline; positive polarity).
    "$WV" remember "production deployment pipeline always required" --source-agent=test >/dev/null 2>&1

    # Build candidate memory files via import.
    local mem_dir="$TEST_DIR/mem"
    mkdir -p "$mem_dir"
    printf '# t\n\nThe scripts/wv entrypoint dispatches commands here.\n' > "$mem_dir/clean.md"
    printf '# t\n\nThis references missing/ghost-file.sh which is gone now.\n' > "$mem_dir/stale.md"
    printf '# t\n\nproduction deployment pipeline never permitted, avoid disable.\n' > "$mem_dir/contra.md"
    "$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json >/dev/null 2>&1

    # A duplicate candidate sharing clean.md's source_hash (a legacy pre-idempotency
    # or cross-agent dup) -> crystallize marks the later one superseded. Inserted
    # directly because `wv memory import` is now idempotent on source_hash.
    local clean_hash dup_meta
    clean_hash=$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.source_hash') FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%mem/clean.md';")
    dup_meta=$(jq -nc --arg h "$clean_hash" --arg p "$TEST_DIR/dup/clean.md" --arg r "$TEST_DIR" \
        '{type:"memory",kind:"project",scope:"repo",mem_status:"candidate",source_agent:"claude",source_kind:"memory_file",source_path:$p,source_hash:$h,repo_root:$r}')
    sqlite3 "$WV_DB" "INSERT INTO nodes (id, text, status, metadata) VALUES ('wv-dddddd', 'The scripts/wv entrypoint dispatches commands here.', 'done', '$(printf '%s' "$dup_meta" | sed "s/'/''/g")');"

    local clean_id stale_id contra_id dup_id
    clean_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%mem/clean.md';")
    stale_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%stale.md';")
    contra_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%contra.md';")
    dup_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%dup/clean.md';")

    # Mark the clean candidate reviewed so apply promotes it.
    "$WV" update "$clean_id" --metadata='{"reviewed":true}' >/dev/null 2>&1

    # --- dry-run: reports actions, makes no changes ---
    local dry
    dry=$("$WV" memory crystallize --dry-run --repo-root="$TEST_DIR" --json)
    assert_equals "promote" "$(printf '%s' "$dry" | jq -r --arg id "$clean_id" '.results[]|select(.id==$id)|.action')" "dry-run flags reviewed-clean candidate as promote"
    assert_equals "stale" "$(printf '%s' "$dry" | jq -r --arg id "$stale_id" '.results[]|select(.id==$id)|.action')" "dry-run flags missing-path candidate as stale"
    assert_contains "$(printf '%s' "$dry" | jq -r --arg id "$stale_id" '.results[]|select(.id==$id)|.stale_reason')" "missing path" "dry-run records stale_reason"
    assert_equals "contradicts" "$(printf '%s' "$dry" | jq -r --arg id "$contra_id" '.results[]|select(.id==$id)|.action')" "dry-run flags opposite-polarity candidate as contradicts"
    assert_equals "superseded" "$(printf '%s' "$dry" | jq -r --arg id "$dup_id" '.results[]|select(.id==$id)|.action')" "dry-run flags identical re-import as superseded"
    assert_equals "candidate" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$clean_id';")" "dry-run does not mutate node status"

    # --- apply-reviewed: applies the marks ---
    local applied
    applied=$("$WV" memory crystallize --apply-reviewed --repo-root="$TEST_DIR" --json)
    assert_equals "active" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$clean_id';")" "apply promotes reviewed-clean candidate to active"
    assert_contains "$("$WV" show "$clean_id" --json-v2 | jq -r '.[0].metadata.verified_at')" "T" "apply stamps verified_at on promoted memory"
    assert_equals "stale" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$stale_id';")" "apply marks missing-path candidate stale"
    assert_equals "superseded" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$dup_id';")" "apply marks identical re-import superseded"
    assert_equals "$clean_id" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.superseded_by') FROM nodes WHERE id='$dup_id';")" "apply records superseded_by pointer"
    # wv-fc6fc2: supersedes means the target replaces the source (the registry,
    # and wv remember --supersedes), so the superseded duplicate is the source.
    # This assertion used to pin the reverse direction.
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM edges WHERE source='$dup_id' AND target='$clean_id' AND type='supersedes';")" "apply creates a supersedes edge from the superseded duplicate to its replacement"
    assert_equals "0" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM edges WHERE source='$clean_id' AND target='$dup_id' AND type='supersedes';")" "apply writes no reversed supersedes edge"
    assert_contains "$(sqlite3 "$WV_DB" "SELECT json_extract(context,'\$.summary') FROM edges WHERE source='$dup_id' AND target='$clean_id' AND type='supersedes';")" "$clean_id supersedes $dup_id" "the edge summary names the replacement first"

    # Contradiction stays candidate (unresolved) and produces a finding + edge.
    assert_equals "candidate" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$contra_id';")" "apply leaves contradiction candidate unresolved"
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM nodes WHERE json_extract(metadata,'\$.finding.violation_type')='memory_contradiction';")" "apply creates a contradiction finding"
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM edges WHERE source='$contra_id' AND type='contradicts';")" "apply creates a contradicts edge"
    # wv-031d08: edge context is JSON for every writer (E5 applies json() to it)
    assert_equals "0" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM edges WHERE context IS NOT NULL AND context != '' AND json_valid(context) = 0;")" "crystallize edges carry JSON context"
    # wv-b3d2b6: a second run files no second finding, and closing the finding
    # resolves the pair so the candidate is no longer held back.
    "$WV" memory crystallize --apply-reviewed --repo-root="$TEST_DIR" --json >/dev/null 2>&1 || true
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM nodes WHERE json_extract(metadata,'\$.finding.violation_type')='memory_contradiction';")" "a repeat run files no duplicate contradiction finding"
    sqlite3 "$WV_DB" "UPDATE nodes SET status='done' WHERE json_extract(metadata,'\$.finding.violation_type')='memory_contradiction';"
    assert_equals "overlap" "$("$WV" memory crystallize --dry-run --repo-root="$TEST_DIR" --json 2>/dev/null | jq -r --arg id "$contra_id" '.results[]|select(.id==$id)|.action')" "a closed finding resolves the pair"

    # Promoted memory now surfaces in active recall; stale/superseded do not.
    local recall
    recall=$("$WV" memory recall --agent=all --json)
    assert_equals "1" "$(printf '%s' "$recall" | jq --arg id "$clean_id" '[.[]|select(.id==$id)]|length')" "promoted candidate enters active recall"
    assert_equals "0" "$(printf '%s' "$recall" | jq --arg id "$stale_id" '[.[]|select(.id==$id)]|length')" "stale candidate stays out of recall"
}

test_memory_doctor_authority() {
    echo ""
    echo "Test: doctor duplicate-authority check (S5)"
    echo "==========================================="

    setup_test_env

    local fake_home slug memdir
    fake_home="$TEST_DIR/dh-home"
    slug=$(printf '%s' "$TEST_DIR" | tr '/' '-')
    memdir="$fake_home/.claude/projects/$slug/memory"
    mkdir -p "$memdir"
    printf '%s\n' "# Memory" "A durable fact that should live in the graph." > "$memdir/note.md"

    local before after
    before=$(HOME="$fake_home" "$WV" doctor 2>&1 | grep -i "memory authority" || true)
    assert_contains "$before" "dual authority risk" "doctor warns on un-imported Claude memory file"

    HOME="$fake_home" "$WV" memory import --source=claude --path="$memdir" --repo-root="$TEST_DIR" --json >/dev/null 2>&1
    after=$(HOME="$fake_home" "$WV" doctor 2>&1 | grep -i "memory authority" || true)
    assert_contains "$after" "all represented in graph" "doctor passes once the memory file is imported"
}

test_memory_doctor_authority_policy() {
    echo ""
    echo "Test: doctor honours a recorded memory-authority choice (wv-27131a)"
    echo "==================================================================="

    setup_test_env

    local fake_home slug memdir out
    fake_home="$TEST_DIR/dh-home-policy"
    slug=$(printf '%s' "$TEST_DIR" | tr '/' '-')
    memdir="$fake_home/.claude/projects/$slug/memory"
    mkdir -p "$memdir"
    printf '%s\n' "# Memory" "A field note this repository keeps in Claude memory." > "$memdir/note.md"

    # The import advice names the alternative, so the choice is discoverable.
    out=$(HOME="$fake_home" "$WV" doctor 2>&1 | grep -i "memory authority" || true)
    assert_contains "$out" ".weave/policy.conf [memory]" "the import advice names the recorded-choice alternative"

    printf '[memory]\n# kept by choice\noutside_graph = claude\nreason = field notes stay in Claude memory\n' > .weave/policy.conf
    out=$(HOME="$fake_home" "$WV" doctor --json 2>/dev/null | jq -r '.checks[] | select(.check == "memory authority") | .status + " " + .detail')
    assert_contains "$out" "pass Claude memory kept outside the graph by choice (.weave/policy.conf): field notes stay in Claude memory" \
        "a recorded choice passes and reports its reason"
    assert_not_contains "$out" "dual authority risk" "a recorded choice silences the import advice"

    printf '[memory]\noutside_graph = claude\n' > .weave/policy.conf
    out=$(HOME="$fake_home" "$WV" doctor --json 2>/dev/null | jq -r '.checks[] | select(.check == "memory authority") | .status + " " + .detail')
    assert_contains "$out" "warn" "a choice without a reason does not pass"
    assert_contains "$out" "records no choice without a reason" "doctor asks for the reason"
    assert_contains "$out" "dual authority risk" "without a reason the import advice stands"

    printf '[memory]\noutside_graph = claude, copilot\nreason = r\n' > .weave/policy.conf
    out=$(HOME="$fake_home" "$WV" doctor --json 2>/dev/null | jq -r '.checks[] | select(.check == "memory authority") | .status + " " + .detail')
    assert_contains "$out" "warn" "an unknown harness name warns"
    assert_contains "$out" "outside_graph names 'copilot'" "doctor names the unknown harness"
}

test_memory_doctor_authority_codex() {
    echo ""
    echo "Test: doctor dual-authority guard covers Codex (F1)"
    echo "==================================================="

    setup_test_env

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "SKIP: sqlite3 not available"
        return 0
    fi

    local fake_home cdxdb out after_import
    fake_home="$TEST_DIR/dh-home-codex"
    cdxdb="$fake_home/.codex/memories_1.sqlite"
    mkdir -p "$fake_home/.codex"
    # Codex's durable memory pipeline holds a row scoped to this repo (cwd), but
    # there is no codex import path, so the graph cannot represent it yet.
    sqlite3 "$cdxdb" \
        "CREATE TABLE stage1_outputs(id INTEGER PRIMARY KEY, cwd TEXT, output TEXT);
         INSERT INTO stage1_outputs(cwd, output) VALUES('$TEST_DIR', 'a durable codex memory');" \
        2>/dev/null

    out=$(HOME="$fake_home" "$WV" doctor 2>&1 | grep -i "memory authority" || true)
    assert_contains "$out" "dual authority risk" "doctor warns on un-represented Codex memory rows"
    assert_contains "$out" "Codex memory-pipeline" "doctor names the Codex pipeline gap"

    HOME="$fake_home" "$WV" memory import --source=codex --repo-root="$TEST_DIR" --json >/dev/null 2>&1
    after_import=$(HOME="$fake_home" "$WV" doctor 2>&1 | grep -i "memory authority" || true)
    assert_contains "$after_import" "all represented in graph" "doctor passes once Codex memory rows are imported"

    # A repo with no Codex memory pipeline rows must not warn (no false positive).
    rm -f "$cdxdb"
    sqlite3 "$cdxdb" \
        "CREATE TABLE stage1_outputs(id INTEGER PRIMARY KEY, cwd TEXT, output TEXT);" 2>/dev/null
    out=$(HOME="$fake_home" "$WV" doctor 2>&1 | grep -i "memory authority" || true)
    assert_not_contains "$out" "Codex memory-pipeline" "doctor stays quiet when no Codex rows match this repo"
}

test_memory_recall_agent_observable() {
    echo ""
    echo "Test: recall --agent is observable but never filters (F2)"
    echo "========================================================="

    setup_test_env

    "$WV" remember "shared fact for agnostic recall" --json >/dev/null 2>&1

    local all_ids bogus_ids stdout_only err_codex err_current
    all_ids=$("$WV" memory recall --agent=all --json 2>/dev/null | jq -c '[.[].id] | sort')
    bogus_ids=$("$WV" memory recall --agent=totally-made-up --json 2>/dev/null | jq -c '[.[].id] | sort')
    assert_equals "$all_ids" "$bogus_ids" "an unknown agent name still returns the shared set (never filters)"

    # stdout stays a clean JSON array even though stderr carries the diagnostic.
    stdout_only=$("$WV" memory recall --agent=codex --json 2>/dev/null)
    assert_equals "array" "$(printf '%s' "$stdout_only" | jq -r 'type')" "stdout is the bare JSON array (stderr does not leak in)"

    # The resolved caller is observable on stderr.
    err_codex=$("$WV" memory recall --agent=codex --json 2>&1 >/dev/null)
    assert_contains "$err_codex" "caller=codex" "stderr reports the resolved caller"
    assert_contains "$err_codex" "never filters" "stderr states the agnostic contract"

    # current resolves to the operating agent for provenance reporting.
    err_current=$(WV_OPERATING_AGENT=copilot "$WV" memory recall --agent=current --json 2>&1 >/dev/null)
    assert_contains "$err_current" "caller=copilot" "current resolves the operating agent for the stderr report"
}

test_memory_render_current_unknown_fallback() {
    echo ""
    echo "Test: render --agent=current falls back to all for unknown labels (F3)"
    echo "======================================================================"

    setup_test_env

    "$WV" remember "fact for render fallback" --json >/dev/null 2>&1
    printf '%s\n' "universal" > "$TEST_DIR/AGENTS.md"

    # current resolves to a label with no dedicated projection -> render the full
    # set instead of erroring.
    local out rc count
    out=$(WV_OPERATING_AGENT=amp "$WV" memory render --agent=current --base-dir="$TEST_DIR" --json 2>/dev/null)
    rc=$?
    assert_equals "0" "$rc" "render --agent=current with an unknown operating-agent label succeeds"
    count=$(printf '%s' "$out" | jq '.paths | length')
    # wv-91f0ca: the agnostic set is CLAUDE.md, weave.json, copilot and the
    # marker-gated AGENTS.md (skipped here, no block).
    assert_equals "3" "$count" "unknown current renders the full projection set"

    # A known operating agent still renders only its own surface.
    local claude_paths
    claude_paths=$(WV_OPERATING_AGENT=claude "$WV" memory render --agent=current --base-dir="$TEST_DIR" --json 2>/dev/null | jq -c '[.paths[].projection]')
    assert_equals '["claude"]' "$claude_paths" "known current still renders only the caller's surface"

    # An explicit unknown --agent=<name> is still a hard error (typo guard).
    local err
    err=$("$WV" memory render --agent=amp --base-dir="$TEST_DIR" 2>&1 >/dev/null || true)
    assert_contains "$err" "unsupported memory projection" "explicit unknown --agent still errors"
}

test_memory_verify_prose() {
    echo ""
    echo "Test: crystallize verify is conservative on prose (wv-6e06c7)"
    echo "============================================================"

    setup_test_env

    # A real file in a subdir, referenced by a relative path in memory prose.
    mkdir -p "$TEST_DIR/scripts/lib"
    printf '#\n' > "$TEST_DIR/scripts/lib/realfile.sh"

    local mem_dir="$TEST_DIR/mem"
    mkdir -p "$mem_dir"
    # Prose full of slash-phrases that are NOT paths, plus a real relative path.
    printf '# t\n\nUse commit/sync/push order; trace read/write paths with offset/limit. See scripts/lib/realfile.sh.\n' > "$mem_dir/prose.md"
    # A genuinely-absent path reference (slash + extension, basename not in repo).
    printf '# t\n\nThis cites gone/deleted-xyz.sh which is removed.\n' > "$mem_dir/missing.md"
    # Finding E mechanism 1. $TEST_DIR/scripts holds only this test's own files,
    # standing in for a consumer repo. Flags belonging to OTHER tools must not be
    # checked at all, a real wv flag must resolve against wv's own surface
    # (WV_LIB_DIR, not $repo_root/scripts), and a bogus wv flag must still fire.
    # shellcheck disable=SC2016  # backticks are Markdown code spans, not command substitution
    printf '# t\n\nRunning `uv sync --all-extras` pulls the XPU build; use `uv sync --extra cpu`.\n' > "$mem_dir/foreignflags.md"
    # shellcheck disable=SC2016  # backticks are Markdown code spans, not command substitution
    printf '# t\n\nPrefer `wv remember "<text>" --kind=project` over editing the index.\n' > "$mem_dir/wvflag.md"
    # shellcheck disable=SC2016  # backticks are Markdown code spans, not command substitution
    printf '# t\n\nClose with `wv done <id> --frobnicate-widget` to record it.\n' > "$mem_dir/bogusflag.md"
    "$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json >/dev/null 2>&1

    local prose_id missing_id dry
    prose_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%prose.md';")
    missing_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%missing.md';")
    dry=$("$WV" memory crystallize --dry-run --repo-root="$TEST_DIR" --json)

    assert_equals "" "$(printf '%s' "$dry" | jq -r --arg id "$prose_id" '.results[]|select(.id==$id)|.stale_reason // ""')" "prose slash-phrases + relative ref to a real file are not marked stale"
    assert_equals "stale" "$(printf '%s' "$dry" | jq -r --arg id "$missing_id" '.results[]|select(.id==$id)|.action')" "genuinely-absent slash-path is still detected stale"

    local foreign_id wvflag_id bogus_id
    foreign_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%foreignflags.md';")
    wvflag_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%wvflag.md';")
    bogus_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%bogusflag.md';")

    assert_equals "" "$(printf '%s' "$dry" | jq -r --arg id "$foreign_id" '.results[]|select(.id==$id)|.stale_reason // ""')" "another tool's flags (uv --all-extras/--extra) are not checked against wv"
    assert_equals "" "$(printf '%s' "$dry" | jq -r --arg id "$wvflag_id" '.results[]|select(.id==$id)|.stale_reason // ""')" "a real wv flag resolves in a consumer repo (WV_LIB_DIR, not repo scripts/)"
    assert_equals "stale" "$(printf '%s' "$dry" | jq -r --arg id "$bogus_id" '.results[]|select(.id==$id)|.action')" "a bogus wv flag is still detected stale"
}

test_memory_lifecycle_contract_shapes
test_remember_recall_ready_and_render
test_memory_scan_and_import
test_memory_crystallize
test_memory_doctor_authority
test_memory_doctor_authority_policy
test_memory_doctor_authority_codex
test_memory_recall_agent_observable
test_memory_render_current_unknown_fallback
test_memory_overlap_guards() {
    echo ""
    echo "Test: crystallize overlap needs 3 terms and a matching kind (Finding E mech 2)"
    echo "============================================================"

    setup_test_env

    # Active memories a candidate could be proposed against. Same vocabulary,
    # different kind.
    "$WV" remember "telemetry ingestion backlog reprocessing" --kind=feedback --source-agent=test >/dev/null 2>&1
    "$WV" remember "filesystem checkpoint validation ordering" --kind=project --source-agent=test >/dev/null 2>&1

    local mem_dir="$TEST_DIR/mem"
    mkdir -p "$mem_dir"
    # Shares all three FTS terms with the seed, but the seed is kind=feedback
    # and an imported memory is kind=project -- different classes of record, so
    # proposing a merge would misfile the one a reader goes looking for.
    printf '# t\n\ntelemetry ingestion backlog reprocessing is slow.\n' > "$mem_dir/crosskind.md"
    # Fewer than three qualifying terms: one shared noun is not a conjunction.
    printf '# t\n\ntelemetry is odd.\n' > "$mem_dir/tooshort.md"
    # Positive control: same kind as the project seed below, three shared terms.
    printf '# t\n\nfilesystem checkpoint validation is slow.\n' > "$mem_dir/samekind.md"
    "$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json >/dev/null 2>&1

    local cross_id short_id same_id dry
    cross_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%crosskind.md';")
    short_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%tooshort.md';")
    same_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%samekind.md';")
    dry=$("$WV" memory crystallize --dry-run --repo-root="$TEST_DIR" --json)

    # Positive control FIRST: without it the two guards below pass against any
    # implementation, including one that never proposes an overlap at all.
    assert_contains "$(printf '%s' "$dry" | jq -r --arg id "$same_id" '.results[]|select(.id==$id)|.duplicate_of // "NONE"')" "wv-" "a same-kind memory sharing three terms IS still proposed as an overlap"
    assert_equals "" "$(printf '%s' "$dry" | jq -r --arg id "$cross_id" '.results[]|select(.id==$id)|.duplicate_of // ""')" "a memory of a different kind is not proposed as an overlap target"
    assert_equals "" "$(printf '%s' "$dry" | jq -r --arg id "$short_id" '.results[]|select(.id==$id)|.duplicate_of // ""')" "fewer than three FTS terms proposes no overlap"
}

test_memory_supersede() {
    echo ""
    echo "Test: remember --supersedes appends a successor and tombstones the old (wv-ffaf3e)"
    echo "============================================================"

    setup_test_env

    local old new old_meta new_meta edge block
    old=$("$WV" remember "Placement follows the agent" --source-agent=test --json | jq -r '.id')
    new=$("$WV" remember "Placement follows the runtime class" --supersedes="$old" --source-agent=test --json | jq -r '.id')
    old_meta=$("$WV" show "$old" --json | jq -c '.metadata | if type == "string" then fromjson else . end')
    new_meta=$("$WV" show "$new" --json | jq -c '.metadata | if type == "string" then fromjson else . end')
    assert_equals "superseded" "$(jq -r '.mem_status' <<< "$old_meta")" "the old memory is marked superseded, not deleted"
    assert_equals "$new" "$(jq -r '.superseded_by' <<< "$old_meta")" "the tombstone points at its successor"
    assert_equals "Placement follows the agent" "$("$WV" show "$old" --json | jq -r '.text')" "the old claim's text is kept as written"
    assert_equals "active" "$(jq -r '.mem_status' <<< "$new_meta")" "the successor is active"
    assert_equals "$old" "$(jq -r '.supersedes' <<< "$new_meta")" "the successor names what it supersedes"
    assert_contains "$(jq -r '.verified_at' <<< "$new_meta")" "T" "the successor carries its own verified_at"
    edge=$("$WV" edges "$old" --json | jq -r --arg n "$new" '[.[] | select(.type=="supersedes" and .direction=="outbound" and .other_id==$n)] | length')
    assert_equals "1" "$edge" "a supersedes edge links old to new (target supersedes source)"
    assert_equals "1" "$(sqlite3 "$("$WV" hotzone db)" "SELECT json_valid(context) FROM edges WHERE source='$old' AND target='$new' AND type='supersedes';")" \
        "the supersedes edge context is JSON (wv-031d08)"

    "$WV" memory render --agent=claude --base-dir="$TEST_DIR" >/dev/null 2>&1
    block=$(sed -n '/BEGIN WEAVE:MEMORY/,/END WEAVE:MEMORY/p' "$TEST_DIR/CLAUDE.md")
    assert_contains "$block" "$new" "render lists the successor"
    assert_not_contains "$block" "$old" "render omits the superseded memory"

    assert_equals "1" "$("$WV" remember "second successor" --supersedes="$old" >/dev/null 2>&1; echo $?)" \
        "a superseded memory cannot be superseded again (one live head per chain)"
    local task
    task=$("$WV" add "not a memory" --standalone --force 2>&1 | sed -nE 's/^✓ (wv-[0-9a-f]{6}): .*/\1/p')
    assert_equals "1" "$("$WV" remember "x" --supersedes="$task" >/dev/null 2>&1; echo $?)" \
        "a non-memory node cannot be superseded"
    assert_equals "1" "$("$WV" remember "x" --supersedes=not-an-id >/dev/null 2>&1; echo $?)" \
        "a malformed id is rejected"
    assert_equals "superseded" "$("$WV" show "$old" --json | jq -r '.metadata | if type == "string" then fromjson else . end | .mem_status')" \
        "rejected attempts leave the tombstone unchanged"
}

test_memory_agents_projection_marker_gated() {
    echo ""
    echo "Test: the agents projection (AGENTS.md) only refreshes an existing block (wv-6ef83b)"
    echo "============================================================"

    setup_test_env

    local id out block
    id=$("$WV" remember "fact for every harness" --source-agent=test --json | jq -r '.id')
    # No AGENTS.md: not created, not reported
    out=$("$WV" memory render --agent=all --base-dir="$TEST_DIR" --json)
    assert_equals "false" "$(if [ -e "$TEST_DIR/AGENTS.md" ]; then echo true; else echo false; fi)" "render --agent=all does not create AGENTS.md"
    assert_equals "0" "$(jq '[.paths[]? // .rendered[]? | select(.projection=="agents")] | length' <<< "$out")" "a skipped AGENTS.md is not reported as rendered"
    # AGENTS.md without markers: byte-identical
    printf '%s\n' '# Our agents' 'hand text only' > "$TEST_DIR/AGENTS.md"
    cp "$TEST_DIR/AGENTS.md" "$TEST_DIR/agents.before"
    "$WV" memory render --agent=all --base-dir="$TEST_DIR" >/dev/null 2>&1
    assert_equals "0" "$(cmp -s "$TEST_DIR/AGENTS.md" "$TEST_DIR/agents.before"; echo $?)" "an AGENTS.md without markers is left untouched"
    # AGENTS.md with markers: block filled, hand text kept
    printf '%s\n' '# Our agents' 'hand text above' \
        '<!-- ── BEGIN WEAVE:MEMORY ── managed by wv memory render, do not edit manually -->' \
        '<!-- ── END WEAVE:MEMORY ── -->' 'hand text below' > "$TEST_DIR/AGENTS.md"
    "$WV" memory render --agent=agents --base-dir="$TEST_DIR" >/dev/null 2>&1
    block=$(sed -n '/BEGIN WEAVE:MEMORY/,/END WEAVE:MEMORY/p' "$TEST_DIR/AGENTS.md")
    assert_contains "$block" "$id" "a marked AGENTS.md block lists the active memory"
    assert_contains "$(cat "$TEST_DIR/AGENTS.md")" "hand text above" "hand text before the block is kept"
    assert_contains "$(cat "$TEST_DIR/AGENTS.md")" "hand text below" "hand text after the block is kept"
}

test_memory_render_index() {
    echo ""
    echo "Test: projections carry an index, not full bodies (wv-91f0ca)"
    echo "============================================================="
    setup_test_env
    local long hooked full long_id hooked_id full_id block json
    long="First sentence of a long memory, e.g. with an abbreviation. SECOND-SENTENCE-BODY must stay out of the projection."
    long_id=$("$WV" remember "$long" --source-agent=test --json | jq -r '.id')
    hooked_id=$("$WV" remember "HOOKED-BODY text the hook replaces. More." --source-agent=test --json | jq -r '.id')
    "$WV" update "$hooked_id" --metadata='{"hook":"The author-written hook"}' >/dev/null 2>&1
    full="A rule kept resident in full. FULL-SECOND-SENTENCE stays visible."
    full_id=$("$WV" remember "$full" --source-agent=test --json | jq -r '.id')
    "$WV" update "$full_id" --metadata='{"resident":"full"}' >/dev/null 2>&1
    printf '# Claude\n' > "$TEST_DIR/CLAUDE.md"
    "$WV" memory render --agent=all --base-dir="$TEST_DIR" --json >/dev/null 2>&1 || true
    block=$(sed -n '/BEGIN WEAVE:MEMORY/,/END WEAVE:MEMORY/p' "$TEST_DIR/CLAUDE.md")
    assert_contains "$block" "- [\`$long_id\`] First sentence of a long memory, e.g. with an abbreviation. (verified:" "the index line is the first sentence, past an abbreviation"
    assert_equals "0" "$(grep -c 'SECOND-SENTENCE-BODY' <<< "$block" || true)" "the rest of the body stays out of the projection"
    assert_contains "$block" "- [\`$hooked_id\`] The author-written hook (verified:" "metadata.hook replaces the derived line"
    assert_equals "0" "$(grep -c 'HOOKED-BODY' <<< "$block" || true)" "a hooked memory shows none of its body"
    assert_contains "$block" "FULL-SECOND-SENTENCE stays visible" "resident=full keeps the whole text"
    assert_contains "$block" "Read a memory in full with" "the block says where the full text is"
    json=$(jq -c --arg id "$long_id" '.memory.entries[] | select(.id == $id) | {text, index}' "$TEST_DIR/.codex/weave.json")
    assert_equals '{"text":"First sentence of a long memory, e.g. with an abbreviation.","index":true}' "$json" "weave.json carries the same index entry"
    assert_equals "$long" "$("$WV" memory recall --agent=all --json | jq -r --arg id "$long_id" '.[] | select(.id == $id) | .text')" "recall still returns the full text"
    # wv-bff31b: bootstrap carries the same index on the agnostic path.
    local boot
    boot=$("$WV" bootstrap --json 2>/dev/null | jq -c '.memory')
    assert_equals "3 wv memory recall --agent=all --json" "$(jq -r '"\(.count) \(.recall)"' <<< "$boot")" "bootstrap reports the active memory count and the recall command"
    assert_equals '{"text":"First sentence of a long memory, e.g. with an abbreviation.","full":false}' "$(jq -c --arg id "$long_id" '.entries[] | select(.id == $id) | {text, full}' <<< "$boot")" "bootstrap carries the index line, not the body"
    assert_equals "true" "$(jq -r --arg id "$full_id" '.entries[] | select(.id == $id) | .full' <<< "$boot")" "bootstrap marks a resident=full memory"
}

test_memory_review() {
    echo ""
    echo "Test: memory review verdicts (wv-de2e83)"
    echo "========================================"
    setup_test_env
    local target mem_dir p m r v u out rc
    target=$("$WV" remember "deployment rule kept as the merge target" --source-agent=test --json 2>/dev/null | jq -r '.id')
    mem_dir="$TEST_DIR/review-mem"
    mkdir -p "$mem_dir"
    for f in promote merge reject verify unreviewed; do
        printf '# t\n\nCandidate destined for %s review.\n' "$f" > "$mem_dir/$f.md"
    done
    "$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json >/dev/null 2>&1 || true
    _rid() { sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%review-mem/$1.md';"; }
    _rmeta() { "$WV" show "$1" --json-v2 2>/dev/null | jq -c ".[0].metadata | $2" 2>/dev/null || true; }
    p=$(_rid promote); m=$(_rid merge); r=$(_rid reject); v=$(_rid verify); u=$(_rid unreviewed)

    # Refusals: each leaves the candidate untouched.
    for args in "$p --verdict=promote" "$p --verdict=keep --reason=x" "$m --verdict=merge --reason=x" \
        "$m --verdict=merge --reason=x --target=$p" "$p --verdict=promote --reason=x --target=$target" \
        "$target --verdict=reject --reason=x"; do
        rc=0
        # shellcheck disable=SC2086  # deliberate word splitting of the argument set
        "$WV" memory review $args >/dev/null 2>&1 || rc=$?
        assert_equals "refused" "$([ "$rc" -ne 0 ] && echo refused || echo accepted)" "review refuses: $args"
    done
    assert_equals "null" "$(_rmeta "$p" .review)" "a refused review records nothing"

    # Recording a verdict never sets reviewed, so crystallize cannot promote early.
    "$WV" memory review "$p" --verdict=promote --reason="durable rule" >/dev/null 2>&1 || true
    "$WV" memory review "$m" --verdict=merge --reason="same subject" --target="$target" >/dev/null 2>&1 || true
    "$WV" memory review "$r" --verdict=merge --reason="first thought" --target="$target" >/dev/null 2>&1 || true
    "$WV" memory review "$r" --verdict=reject --reason="point-in-time status" >/dev/null 2>&1 || true
    "$WV" memory review "$v" --verdict=verify --reason="claim unchecked" >/dev/null 2>&1 || true
    assert_equals '{"verdict":"merge","target":"'"$target"'","applied":false}' "$(_rmeta "$m" '{verdict: .review.verdict, target: .review.target, applied: .review.applied}')" "a merge verdict records its target, unapplied"
    assert_equals "null" "$(_rmeta "$r" .review.target)" "a changed verdict drops the old target"
    assert_equals "0" "$("$WV" memory crystallize --dry-run --json | jq '[.results[] | select(.reviewed)] | length')" "recorded verdicts mark nothing reviewed"

    # A dry run reports and writes nothing.
    out=$("$WV" memory review --apply --dry-run --json 2>/dev/null) || true
    assert_equals "4 dry-run" "$(jq -r '"\(.results | length) \(.mode)"' <<< "$out")" "dry run lists the four recorded verdicts"
    assert_equals '"candidate"' "$(_rmeta "$r" .mem_status)" "dry run leaves the reject a candidate"

    out=$("$WV" memory review --apply --json 2>/dev/null) || true
    assert_equals "3 1 0" "$(jq -r '"\(.applied) \(.pending) \(.refused)"' <<< "$out")" "apply: three applied, verify pending"
    assert_equals '{"s":"candidate","rv":true,"a":true}' "$(_rmeta "$p" '{s: .mem_status, rv: .reviewed, a: .review.applied}')" "promote: reviewed and applied, still a candidate"
    assert_equals '{"s":"superseded","by":"'"$target"'"}' "$(_rmeta "$m" '{s: .mem_status, by: .superseded_by}')" "merge: superseded onto its target"
    assert_equals '["'"$m"'"]' "$(_rmeta "$target" .merge_from)" "merge: the target lists the candidate for amendment"
    assert_equals '{"s":"rejected","why":"point-in-time status"}' "$(_rmeta "$r" '{s: .mem_status, why: .rejected_reason}')" "reject: retired with its reason"
    assert_equals "0" "$("$WV" memory recall --agent=all --json | jq --arg r "$r" '[.[] | select(.id == $r)] | length')" "a rejected candidate is not recalled"
    assert_equals '{"s":"candidate","a":false}' "$(_rmeta "$v" '{s: .mem_status, a: .review.applied}')" "verify: still a candidate, unapplied"
    assert_equals '{"s":"candidate","rv":null}' "$(_rmeta "$u" '{s: .mem_status, rv: .review}')" "an unreviewed candidate is untouched"

    # Applying again changes nothing; an applied verdict cannot be re-recorded.
    out=$("$WV" memory review --apply --json 2>/dev/null) || true
    assert_equals "0 1" "$(jq -r '"\(.applied) \(.pending)"' <<< "$out")" "re-apply is idempotent"
    rc=0; "$WV" memory review "$p" --verdict=reject --reason=x >/dev/null 2>&1 || rc=$?
    assert_equals "refused" "$([ "$rc" -ne 0 ] && echo refused || echo accepted)" "an applied verdict cannot be re-recorded"

    # End to end: crystallize promotes the reviewed candidate after its own checks.
    "$WV" memory crystallize --apply-reviewed --json >/dev/null 2>&1 || true
    assert_equals '"active"' "$(_rmeta "$p" .mem_status)" "crystallize --apply-reviewed promotes the reviewed candidate"
    unset -f _rid _rmeta
}

test_memory_graduate() {
    echo ""
    echo "Test: graduate verdict moves a lesson out of the projections (wv-a8f91e)"
    echo "========================================================================"
    setup_test_env
    local cfg g d e k c out rc args block
    # The procedure contract is checked by the gen-procedures.sh in
    # WV_CONFIG_DIR: give it this checkout's copy, never the installed one.
    cfg="$TEST_DIR/cfg"
    mkdir -p "$cfg" .weave/procedures .weave/patterns docs
    cp "$PROJECT_ROOT/scripts/gen-procedures.sh" "$cfg/"
    chmod +x "$cfg/gen-procedures.sh"
    _gw() { WV_CONFIG_DIR="$cfg" "$WV" "$@"; }
    _gmeta() { "$WV" show "$1" --json-v2 2>/dev/null | jq -c ".[0].metadata | $2" 2>/dev/null || true; }
    g=$("$WV" remember "House lesson now carried by a procedure" --source-agent=test --json | jq -r '.id')
    d=$("$WV" remember "House lesson now carried by a repo doc" --source-agent=test --json | jq -r '.id')
    e=$("$WV" remember "House lesson whose detector breaks before apply" --source-agent=test --json | jq -r '.id')
    k=$("$WV" remember "Lesson that stays a memory" --source-agent=test --json | jq -r '.id')
    c=$("$WV" remember "Lesson still under review" --source-agent=test --json | jq -r '.id')
    sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(metadata,'\$.mem_status','candidate') WHERE id='$c';"
    printf '%s\n' '---' 'id: house' 'description: house procedure' 'fallback: "wv guide --procedure=house"' \
        'adapters: [claude]' 'visibility: local' 'claude_skill: house' '---' '# House' > .weave/procedures/house.md
    printf '%s\n' 'id: rule' 'language: bash' 'severity: warning' 'message: m' 'rule:' '  pattern: rm -rf $X' > .weave/patterns/rule.yaml
    printf '%s\n' 'id: other' 'language: bash' 'rule:' '  pattern: x' > .weave/patterns/broken.yaml
    printf '# Lessons\n' > docs/lessons.md
    printf '#!/bin/sh\n' > tool.sh
    printf 'outside\n' > "$SCRATCH/outside.md"
    ln -s "$SCRATCH/outside.md" docs/escape.md
    printf 'untracked\n' > docs/untracked.md
    git add docs/lessons.md docs/escape.md tool.sh

    for args in "$g --verdict=graduate --reason=x" \
        "$g --verdict=graduate --reason=x --target=$SCRATCH/outside.md" \
        "$g --verdict=graduate --reason=x --target=../outside.md" \
        "$g --verdict=graduate --reason=x --target=docs/escape.md" \
        "$g --verdict=graduate --reason=x --target=docs/untracked.md" \
        "$g --verdict=graduate --reason=x --target=tool.sh" \
        "$g --verdict=graduate --reason=x --target=.weave/patterns/broken.yaml" \
        "$g --verdict=graduate --reason=x --target=.weave/procedures/missing.md" \
        "$c --verdict=graduate --reason=x --target=docs/lessons.md" \
        "$g --verdict=reject --reason=x"; do
        rc=0
        # shellcheck disable=SC2086  # deliberate word splitting of the argument set
        _gw memory review $args >/dev/null 2>&1 || rc=$?
        assert_equals "refused" "$([ "$rc" -ne 0 ] && echo refused || echo accepted)" "graduate refuses: ${args#* }"
    done
    assert_equals "null" "$(_gmeta "$g" .review)" "a refused graduate records nothing"

    _gw memory review "$g" --verdict=graduate --reason="the procedure carries it" --target=.weave/procedures/house.md >/dev/null 2>&1 || true
    _gw memory review "$d" --verdict=graduate --reason="the doc carries it" --target=./docs/../docs/lessons.md >/dev/null 2>&1 || true
    _gw memory review "$e" --verdict=graduate --reason="the detector carries it" --target=.weave/patterns/rule.yaml >/dev/null 2>&1 || true
    assert_equals '{"s":"active","v":"graduate","t":"docs/lessons.md","a":false}' \
        "$(_gmeta "$d" '{s: .mem_status, v: .review.verdict, t: .review.target, a: .review.applied}')" \
        "a graduate verdict records the canonical target and leaves the memory active"

    # The target is checked again when the verdict is applied.
    printf '%s\n' 'id: renamed' 'language: bash' 'rule:' '  pattern: x' > .weave/patterns/rule.yaml
    out=$(_gw memory review --apply --json 2>/dev/null) || true
    assert_equals "2 0 1" "$(jq -r '"\(.applied) \(.pending) \(.refused)"' <<< "$out")" "apply: two graduated, one refused"
    assert_contains "$(jq -r --arg e "$e" '.results[] | select(.id == $e) | .status' <<< "$out")" "refused:" "a target that stopped parsing is refused at apply"
    assert_equals '{"s":"graduated","to":".weave/procedures/house.md","a":true}' \
        "$(_gmeta "$g" '{s: .mem_status, to: .graduated_to, a: .review.applied}')" "graduate: mem_status=graduated with graduated_to"
    assert_equals '{"s":"active","a":false}' "$(_gmeta "$e" '{s: .mem_status, a: .review.applied}')" "a refused graduate stays active, unapplied"

    # Every projection drops a graduated memory; recall keeps it.
    printf '# Claude\n' > CLAUDE.md
    "$WV" memory render --agent=all --base-dir="$TEST_DIR" --json >/dev/null 2>&1 || true
    block=$(sed -n '/BEGIN WEAVE:MEMORY/,/END WEAVE:MEMORY/p' CLAUDE.md)
    assert_not_contains "$block" "$g" "CLAUDE.md drops the graduated memory"
    assert_not_contains "$block" "$d" "CLAUDE.md drops the doc-graduated memory"
    assert_contains "$block" "$k" "CLAUDE.md keeps an active memory"
    assert_equals "0" "$(jq --arg g "$g" '[.memory.entries[] | select(.id == $g)] | length' .codex/weave.json)" ".codex/weave.json drops the graduated memory"
    assert_equals "0" "$("$WV" bootstrap --json 2>/dev/null | jq --arg g "$g" '[.memory.entries[] | select(.id == $g)] | length')" "bootstrap drops the graduated memory"
    out=$("$WV" memory recall --agent=all --json 2>/dev/null)
    assert_equals '"docs/lessons.md"' "$(jq -c --arg d "$d" '.[] | select(.id == $d) | (.metadata | if type == "string" then fromjson else . end) | .graduated_to' <<< "$out")" "recall still returns a graduated memory with graduated_to"
    assert_equals "0" "$(jq --arg c "$c" '[.[] | select(.id == $c)] | length' <<< "$out")" "recall still leaves out candidates"

    out=$(_gw memory review --apply --json 2>/dev/null) || true
    assert_equals "0 1" "$(jq -r '"\(.applied) \(.refused)"' <<< "$out")" "re-apply touches no graduated memory"
    unset -f _gw _gmeta
}

test_memory_budget() {
    echo ""
    echo "Test: doctor memory budget and expiry are advisory (wv-986c3d)"
    echo "=============================================================="
    setup_test_env
    local long carried dated missing plain done_id out check
    mkdir -p .weave/procedures
    printf '# House rule\n' > .weave/procedures/house-rule.md
    done_id=$("$WV" add "finished work a memory cites" --json 2>/dev/null | jq -r '.id')
    sqlite3 "$WV_DB" "UPDATE nodes SET status='done' WHERE id='$done_id';"
    long=$("$WV" remember "A long rule kept resident. $(printf 'LONG-BODY %.0s' $(seq 1 60))" --source-agent=test --json | jq -r '.id')
    "$WV" update "$long" --metadata='{"resident":"full"}' >/dev/null 2>&1
    carried=$("$WV" remember "Run the house-rule procedure before closing." --source-agent=test --json | jq -r '.id')
    dated=$("$WV" remember "Vendor access is pending as of 2026-01-02, see $done_id." --source-agent=test --json | jq -r '.id')
    missing=$("$WV" remember "Lesson recorded under wv-abc123, since removed." --source-agent=test --json | jq -r '.id')
    plain=$("$WV" remember "A settled rule with no date." --source-agent=test --json | jq -r '.id')
    sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(metadata,'\$.verified_at','2025-01-01T00:00:00Z') WHERE id='$plain';"
    check() { jq -r --arg c "$1" '.checks[] | select(.check == $c) | "\(.status) \(.detail)"' <<< "$out"; }

    printf '[memory]\nblock_budget_bytes = 600\n' > .weave/policy.conf
    out=$("$WV" doctor --json 2>/dev/null) || true
    assert_contains "$(check "memory budget")" "warn " "an over-budget block warns"
    assert_contains "$(check "memory budget")" "600-byte budget" "the warning names the budget"
    assert_contains "$(check "memory budget")" "$carried (house-rule)" "a memory a repo procedure carries is a candidate"
    assert_contains "$(check "memory budget")" "$long" "the longest memory is a candidate"
    assert_contains "$(check "memory budget")" "$plain (2025-01-01)" "the oldest verified memory is a candidate"
    assert_contains "$(check "memory expiry")" "warn " "time-bound memories warn"
    assert_contains "$(check "memory expiry")" "$dated (pending, as of 2026-01-02; cites done $done_id)" "dated state with a done citation is flagged"
    assert_contains "$(check "memory expiry")" "$missing (cites wv-abc123, not in the graph)" "a citation missing from the graph is flagged"
    assert_not_contains "$(check "memory expiry")" "$plain" "a settled memory is not flagged"
    assert_equals "active active" "$(sqlite3 "$WV_DB" "SELECT group_concat(json_extract(metadata,'\$.mem_status'), ' ') FROM nodes WHERE id IN ('$dated','$missing');")" "flagged memories are not retired"

    printf '[memory]\nblock_budget_bytes = 1000000\n' > .weave/policy.conf
    out=$("$WV" doctor --json 2>/dev/null) || true
    assert_contains "$(check "memory budget")" "pass " "a block under budget passes"
    printf '[memory]\nblock_budget_bytes = lots\n' > .weave/policy.conf
    out=$("$WV" doctor --json 2>/dev/null) || true
    assert_contains "$(check "memory budget")" "block_budget_bytes = lots is not a byte count" "a malformed budget is reported, not ignored"
    unset -f check
}

test_memory_import_frontmatter() {
    echo ""
    echo "Test: Claude import keeps the body, not the frontmatter (wv-b3d2b6)"
    echo "==================================================================="
    setup_test_env
    local mem_dir file id out legacy n
    mem_dir="$TEST_DIR/fm-mem"
    mkdir -p "$mem_dir"
    file="$mem_dir/rule.md"
    {
        printf -- '---\nname: rule-name\ndescription: "Hook line with \\"quotes\\" from the description"\nmetadata:\n  type: feedback\n---\n\n'
        for n in $(seq 1 24); do printf 'Body line %s.\n' "$n"; done
        printf '**How to apply:** TAIL-PAST-LINE-TWENTY survives the import.\n'
    } > "$file"
    out=$("$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json 2>/dev/null) || true
    id=$(jq -r '.imported[0].id // empty' <<< "$out")
    assert_equals "Body line 1." "$(sqlite3 "$WV_DB" "SELECT substr(text, 1, 12) FROM nodes WHERE id='$id';")" "the text starts at the body, not the frontmatter"
    assert_contains "$(sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$id';")" "TAIL-PAST-LINE-TWENTY" "the body is not cut at 20 lines"
    assert_equals 'Hook line with "quotes" from the description|rule-name' "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.hook') || '|' || json_extract(metadata,'\$.source_name') FROM nodes WHERE id='$id';")" "the description becomes the hook"

    # A pre-wv-b3d2b6 import of an unchanged file is reshaped in place; one whose
    # text was edited since is left alone.
    legacy="--- name: rule-name description: old shape Body line 1."
    sqlite3 "$WV_DB" "UPDATE nodes SET text='$legacy', metadata=json_remove(metadata,'\$.hook','\$.source_name') WHERE id='$id';"
    out=$("$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json 2>/dev/null) || true
    assert_equals "0 1 [\"$id\"]" "$(jq -r '"\(.count) \(.skipped) \(.reshaped)"' <<< "$out")" "re-import creates nothing and reports the reshape"
    assert_equals "Body line 1.|Hook line with \"quotes\" from the description" "$(sqlite3 "$WV_DB" "SELECT substr(text, 1, 12) || '|' || json_extract(metadata,'\$.hook') FROM nodes WHERE id='$id';")" "re-import reshapes the legacy text and sets the hook"
    sqlite3 "$WV_DB" "UPDATE nodes SET text='Edited by the owner.' WHERE id='$id';"
    "$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json >/dev/null 2>&1 || true
    assert_equals "Edited by the owner." "$(sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$id';")" "an edited node is not reshaped"
}

test_memory_verify_prose
test_memory_import_frontmatter
test_memory_review
test_memory_graduate
test_memory_budget
test_memory_render_index
test_memory_overlap_guards
test_memory_supersede
test_memory_agents_projection_marker_gated

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
