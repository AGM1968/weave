#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

TEST_DIR="/tmp/wv-memory-test-$$"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$WV_HOT_ZONE/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_PROJECT_DIR="$TEST_DIR"
export WV_SUITE_LOG="$TEST_DIR/suite_runs.jsonl"

cleanup() {
    rm -rf "$TEST_DIR"
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
    assert_equals "5" "$all_render_count" "render all writes five repo-local projections"
    assert_equals "universal" "$(cat "$TEST_DIR/AGENTS.md")" "render all does not touch AGENTS.md"
    assert_contains "$(cat "$TEST_DIR/CLAUDE.md")" "verified:" "CLAUDE projection includes verified_at"
    assert_contains "$(cat "$TEST_DIR/.claude/MEMORY.md")" "$memory_id" "Claude MEMORY projection includes source node id"
    assert_contains "$(cat "$TEST_DIR/.codex/MEMORY.md")" "$memory_id" "Codex MEMORY projection includes source node id"
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
    assert_equals "0" "$(grep -c "$memory_id" <<<"$prune_dry_run" || true)" "prune dry-run excludes durable memory nodes"

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
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM edges WHERE source='$clean_id' AND target='$dup_id' AND type='supersedes';")" "apply creates a supersedes edge"

    # Contradiction stays candidate (unresolved) and produces a finding + edge.
    assert_equals "candidate" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.mem_status') FROM nodes WHERE id='$contra_id';")" "apply leaves contradiction candidate unresolved"
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM nodes WHERE json_extract(metadata,'\$.finding.violation_type')='memory_contradiction';")" "apply creates a contradiction finding"
    assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT count(*) FROM edges WHERE source='$contra_id' AND type='contradicts';")" "apply creates a contradicts edge"

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
    assert_equals "5" "$count" "unknown current renders the full projection set"

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
    "$WV" memory import --source=claude --path="$mem_dir" --repo-root="$TEST_DIR" --json >/dev/null 2>&1

    local prose_id missing_id dry
    prose_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%prose.md';")
    missing_id=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE json_extract(metadata,'\$.source_path') LIKE '%missing.md';")
    dry=$("$WV" memory crystallize --dry-run --repo-root="$TEST_DIR" --json)

    assert_equals "" "$(printf '%s' "$dry" | jq -r --arg id "$prose_id" '.results[]|select(.id==$id)|.stale_reason // ""')" "prose slash-phrases + relative ref to a real file are not marked stale"
    assert_equals "stale" "$(printf '%s' "$dry" | jq -r --arg id "$missing_id" '.results[]|select(.id==$id)|.action')" "genuinely-absent slash-path is still detected stale"
}

test_memory_lifecycle_contract_shapes
test_remember_recall_ready_and_render
test_memory_scan_and_import
test_memory_crystallize
test_memory_doctor_authority
test_memory_doctor_authority_codex
test_memory_recall_agent_observable
test_memory_render_current_unknown_fallback
test_memory_verify_prose

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
