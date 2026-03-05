# Weave Tests

Regression tests for Weave system functionality.

## Cache Invalidation Tests

**File:** `test-cache-invalidation.sh`

Tests that context cache is properly invalidated when edges are modified. Prevents regressions in
cache invalidation for all edge-modifying commands.

### What is Tested

1. **cmd_refs --link** - Verifies cache is invalidated for both source and target nodes when
   `wv refs --link` creates edges

2. **cmd_block** - Verifies cache is invalidated when `wv block` creates blocking edges

3. **cmd_done** - Verifies cache is invalidated when `wv done` completes nodes and auto-unblocks
   dependents

4. **cmd_link** - Verifies cache is invalidated when `wv link` creates arbitrary edge types

5. **cmd_prune** - Verifies cache is invalidated when `wv prune` deletes old nodes and their edges

6. **Cache file lifecycle** - Verifies cache files are created in tmpfs and removed when edges
   change

### Running Tests

```bash
./tests/test-cache-invalidation.sh
```

Expected output:

```txt
Cache Invalidation Tests
========================
Testing: cmd_refs, cmd_block, cmd_done, cmd_link, cmd_prune

Test 1: cmd_refs --link invalidates cache
=========================================
[PASS] Initial context has no related nodes
[PASS] Context shows new related node after refs --link
[PASS] Related node is the target node

...

Test Summary
============
Tests run:    13
Tests passed: 13
All tests passed!
```

### Test Environment

- Tests run in isolated `/tmp` directory
- Each test creates fresh Weave instance
- Cleanup happens automatically via trap on exit
- Tests are idempotent and safe to run repeatedly

### Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed

### Context

These tests address the cache invalidation bugs documented in:

- **wv-e8a4**: Cache invalidation must happen in ALL commands that modify edges
- **wv-1330**: CONTEXT phase must re-query when graph changes
- **wv-9b42**: EXECUTE must re-query CONTEXT on graph mutation
- **wv-3ae9**: Test cache invalidation
- **wv-b5fa**: Blocking edges can become stale

Fixed in **wv-3c0b** (cache invalidation implementation).

## Adding New Tests

When adding new edge-modifying commands to `scripts/wv`, add corresponding tests here:

1. Create test function following the naming pattern `test_cmd_<name>_invalidation`
2. Use `setup_test_env` to get a fresh test environment
3. Use `assert_equals` or `assert_contains` for assertions
4. Add test function call to `main()`
5. Run tests to verify

Example:

```bash
test_cmd_newcommand_invalidation() {
    echo ""
    echo "Test: cmd_newcommand invalidates cache"
    echo "======================================="

    setup_test_env

    # Test setup
    local node1=$("$WV" add "Test node" | tail -1)

    # Verify before state
    local before=$("$WV" context "$node1" --json | jq -r '.related | length')
    assert_equals "0" "$before" "Initial state description"

    # Execute command that modifies edges
    "$WV" newcommand "$node1" >/dev/null 2>&1

    # Verify cache was invalidated (context reflects change)
    local after=$("$WV" context "$node1" --json | jq -r '.related | length')
    assert_equals "1" "$after" "After state description"
}
```
