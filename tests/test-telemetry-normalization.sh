#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Call-log operation normalization.
#
# An operation name is not a secret; an unrecognized first argument may be. The
# set of names that are not secret is exactly the dispatch table, and the
# capability registry already declares it. A separate allowlist inside scripts/wv
# claimed to be that set and was not: cutover and repo-class were dispatched for
# months while every call line recorded <redacted:N>, which is how the E1
# denominator came to be missing two mutating commands.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

TEST_DIR=$(mktemp -d /tmp/wv-telemetry-norm-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_CONFIG_DIR="$TEST_DIR/config"; mkdir -p "$WV_CONFIG_DIR"
export WV_CALL_LOG="$TEST_DIR/calls.jsonl"
cd "$TEST_DIR" || exit 1
git init -q . >/dev/null 2>&1
git config user.email test@test.com; git config user.name Test; git config commit.gpgsign false
"$WV" init >/dev/null 2>&1

echo "=== call-log operation normalization ==="

logged() { tail -1 "$WV_CALL_LOG" | jq -r '.cmd'; }

for op in cutover repo-class quality trails breadcrumbs; do
    "$WV" "$op" --help >/dev/null 2>&1
    check "$op logs as itself, not a redaction" "wv $op" "$(logged)"
done

"$WV" definitely-not-a-command >/dev/null 2>&1
check "an unknown first argument is still redacted" "wv <redacted:24>" "$(logged)"
"$WV" --help >/dev/null 2>&1
check "a help flag is not treated as a secret" "wv --help" "$(logged)"

# DERIVATION. A command the registry declares normalizes with no edit anywhere
# else: the projection below is regenerated from a registry with one row added,
# and nothing in scripts/wv is touched. If normalization were still an allowlist,
# this would come back redacted.
LIB_OVERRIDE="$TEST_DIR/lib-override"
mkdir -p "$LIB_OVERRIDE"
cp -a "$ROOT/scripts/lib" "$ROOT/scripts/cmd" "$LIB_OVERRIDE/"
python3 - "$ROOT" "$TEST_DIR/registry.json" "$LIB_OVERRIDE/lib/wv-command-capabilities.sh" <<'PY'
import json, sys
from pathlib import Path
root, registry_out, artifact = (Path(p) for p in sys.argv[1:4])
sys.path.insert(0, str(root / "scripts"))
from weave_registry import shell  # noqa: E402
doc = json.loads((root / "contracts" / "command-capabilities.json").read_text(encoding="utf-8"))
doc["commands"].append({
    "operation": "fictional-command",
    "cache": {"serve": False, "invalidate": False},
    "evidence_class": "observation",
    "mutation_targets": [],
})
doc["commands"].sort(key=lambda row: (row["operation"], row.get("suboperation", "")))
registry_out.write_text(json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
artifact.write_text(shell(registry_out), encoding="utf-8")
PY
WV_LIB_DIR="$LIB_OVERRIDE" "$WV" fictional-command >/dev/null 2>&1
check "a command the registry declares needs no allowlist edit" "wv fictional-command" "$(logged)"
"$WV" fictional-command >/dev/null 2>&1
check "and is redacted again against the real registry" "wv <redacted:17>" "$(logged)"

# shellcheck disable=SC2016  # the pattern matches literal $ in the source text it reads
check "scripts/wv keeps no operation allowlist of its own" "1" \
  "$(grep -c '_wv_cap_known "$operation"' "$WV")"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
