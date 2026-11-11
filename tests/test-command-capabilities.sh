#!/usr/bin/env bash
# Command capability registry: the single authority the dispatcher, the cache
# logic and E1 project from. Guards that the schema document is EXECUTED rather
# than restated (malformed-shape forgeries, cross-checked against ajv), that ajv
# certifies the schema itself since the Python executor cannot, that the contract
# identity covers the schema as well as the registry, the invariants JSON Schema
# cannot state (totality, dominance), the generated artifact's byte identity,
# and -- until wv-cache.sh is migrated -- that the registry still agrees with the
# live Bash lists it will replace.
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/weave_registry.py"
REGISTRY="$ROOT/contracts/command-capabilities.json"
ARTIFACT="$ROOT/scripts/lib/wv-command-capabilities.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; run=0
check() { run=$((run+1)); if eval "$2"; then pass=$((pass+1)); echo "  ✓ $1"; else echo "  ✗ $1"; fi; }
# Counts toward neither pass nor run: a host without an optional dev dependency
# is a narrower run, not a failing one.
skip() { echo "  ~ skipped: $1"; }

echo "=== command capability registry ==="

check "registry validates" "python3 '$TOOL' validate"
check "generated artifact matches the registry" "python3 '$TOOL' check"
check "artifact is valid shell" "bash -n '$ARTIFACT'"
check "artifact records the registry digest" \
  "grep -q \"WV_CAPABILITIES_SHA256=\\\"\$(python3 '$TOOL' digest)\\\"\" '$ARTIFACT'"

# SHAPE. contracts/command-capabilities-v1.schema.json is the only shape
# authority and scripts/weave_registry.py executes it; each forgery below breaks
# exactly one keyword of it. A validator that merely resembles the schema would
# pass the accept case and quietly admit these, which is what the parallel Python
# shape check it replaced actually did.
FORGE="$TMP/forge"
mapfile -t CASES < <(python3 "$ROOT/tests/lib/capability-forge.py" "$REGISTRY" "$FORGE")
check "the forged corpus covers every shape rule the schema states" "[ ${#CASES[@]} -eq 12 ]"
for forgery in "${CASES[@]}"; do
  set +e
  python3 "$TOOL" validate "$FORGE/$forgery.json" "$ROOT/scripts/wv" >"$TMP/out-$forgery" 2>&1
  rc=$?
  set -e
  check "malformed shape is rejected: $forgery" "[ $rc -ne 0 ]"
done

# The executor is only as good as its keyword coverage, so an unimplemented
# keyword must fail loudly rather than be read and ignored.
python3 - "$ROOT/contracts/command-capabilities-v1.schema.json" "$TMP/schema-extra.json" <<'PY'
import json, sys
sys.path.insert(0, "scripts")
from weave_registry import SCHEMA_KEYWORDS
# Pick a real JSON Schema keyword the executor does not implement, rather than
# naming one: when the executor learns a keyword, a hard-coded control quietly
# stops testing anything (it did -- minLength was added for the attempt journal).
candidates = ["maxLength", "maxItems", "multipleOf", "not", "exclusiveMinimum", "propertyNames"]
keyword = next(name for name in candidates if name not in SCHEMA_KEYWORDS)
doc = json.load(open(sys.argv[1]))
doc['$defs']['command']['properties']['operation'][keyword] = 64
json.dump(doc, open(sys.argv[2], 'w'), indent=2)
PY
set +e
python3 "$TOOL" validate "$REGISTRY" "$ROOT/scripts/wv" "$TMP/schema-extra.json" >"$TMP/out-keyword" 2>&1
rc=$?
set -e
check "a schema keyword the executor cannot apply fails validation" \
  "[ $rc -ne 0 ] && grep -q 'does not execute' '$TMP/out-keyword'"

# DERIVATION. Enforcement must come from the schema document, not from Python
# that happens to agree with it: drop a keyword from a private copy of the schema
# and the forgery it governs must become acceptable.
python3 - "$ROOT/contracts/command-capabilities-v1.schema.json" "$TMP/schema-lax.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
del doc['$defs']['command']['properties']['mutation_targets']['uniqueItems']
json.dump(doc, open(sys.argv[2], 'w'), indent=2)
PY
set +e
python3 "$TOOL" validate "$FORGE/dup-targets.json" "$ROOT/scripts/wv" "$TMP/schema-lax.json" >"$TMP/out-lax" 2>&1
rc=$?
set -e
check "removing uniqueItems from the schema stops uniqueItems being enforced" "[ $rc -eq 0 ]"

# TRUST BOUNDARY. The executor applies the schema; it does not judge it, and it
# fails unevenly by construction -- an unsound regex on the unused handler
# pattern is never compiled, while the same regex on the exercised operation
# pattern stops the run. Both are stated behaviour, and neither is a verdict
# about the schema: ajv is what certifies that, below.
python3 - "$ROOT/contracts/command-capabilities-v1.schema.json" "$TMP" <<'PY'
import json, sys
from pathlib import Path
doc = json.load(open(sys.argv[1]))
out = Path(sys.argv[2])
for field, name in (("handler", "unsound-unused"), ("operation", "unsound-exercised")):
    broken = json.loads(json.dumps(doc))
    broken['$defs']['command']['properties'][field]['pattern'] = "^[a-z"
    (out / f"schema-{name}.json").write_text(json.dumps(broken, indent=2), encoding="utf-8")
PY
set +e
python3 "$TOOL" validate "$REGISTRY" "$ROOT/scripts/wv" "$TMP/schema-unsound-unused.json" >"$TMP/out-unused" 2>&1
unused_rc=$?
python3 "$TOOL" validate "$REGISTRY" "$ROOT/scripts/wv" "$TMP/schema-unsound-exercised.json" >"$TMP/out-exercised" 2>&1
exercised_rc=$?
set -e
check "an unsound keyword the executor never applies is not detected" "[ $unused_rc -eq 0 ]"
check "an unsound keyword the executor does apply is reported, not raised" \
  "[ $exercised_rc -ne 0 ] && grep -q 'could not be applied' '$TMP/out-exercised' &&
   ! grep -q Traceback '$TMP/out-exercised'"

# CROSS-CHECK. A real JSON Schema implementation must reach the same verdicts on
# the same corpus, or 'the schema is enforced' is a claim about our lookalike --
# and it must compile the schema in strict mode, which is the only gate here that
# certifies the schema itself.
if [ -d "$ROOT/mcp/node_modules/ajv" ]; then
  FORGE="$FORGE" TMP="$TMP" node --input-type=module - "$ROOT" >"$TMP/ajv" 2>&1 <<'JS' || true
import fs from "node:fs";
import Ajv2020 from "./mcp/node_modules/ajv/dist/2020.js";
const [root] = process.argv.slice(2);
const read = (p) => JSON.parse(fs.readFileSync(p));
const compile = (schema) => new Ajv2020({strict: true, allErrors: true}).compile(schema);
let validate;
try {
  validate = compile(read(`${root}/contracts/command-capabilities-v1.schema.json`));
  console.log("COMPILE ok");
} catch (error) {
  console.log(`COMPILE failed: ${error.message}`);
  process.exit(0);
}
const disagreements = [];
if (!validate(read(`${root}/contracts/command-capabilities.json`))) {
  disagreements.push(`ajv rejects the checked-in registry`);
}
for (const file of fs.readdirSync(process.env.FORGE).sort()) {
  if (validate(read(`${process.env.FORGE}/${file}`))) disagreements.push(`ajv accepts forgery ${file}`);
}
console.log(disagreements.length ? `CORPUS ${disagreements.join("; ")}` : "CORPUS agreed");
const unsound = ["schema-unsound-unused.json", "schema-unsound-exercised.json"].filter((file) => {
  try { compile(read(`${process.env.TMP}/${file}`)); return true; } catch { return false; }
});
console.log(unsound.length ? `UNSOUND compiled ${unsound.join("; ")}` : "UNSOUND rejected");
JS
  check "ajv compiles the checked-in schema in strict mode" "grep -qx 'COMPILE ok' '$TMP/ajv'"
  check "ajv reaches the same verdicts on the same corpus" "grep -qx 'CORPUS agreed' '$TMP/ajv'"
  check "ajv rejects both unsound schemas, including the one the executor cannot judge" \
    "grep -qx 'UNSOUND rejected' '$TMP/ajv'"
else
  # Environment-dependent, so it counts toward neither pass nor run. ajv is a dev
  # dependency of this repository and is absent from a fresh clone of the public
  # projection, which retains this suite; a missing second opinion is a narrower
  # result, not a red suite. The Python executor's verdicts above still run.
  skip "ajv cross-check (install with: npm --prefix mcp install)"
fi

# IDENTITY. What a manifest binds must move when either half of the contract
# moves. A registry digest alone would let the schema change which rows are
# admissible while every captured digest still matched.
python3 "$TOOL" identity >"$TMP/identity.json" 2>&1
check "identity carries the schema id, both digests and the composite" "python3 - <<'PY'
import json
got = json.load(open('$TMP/identity.json'))
raise SystemExit(0 if set(got) == {'schema', 'schema_sha256', 'registry_sha256', 'identity_sha256'} else 1)
PY"
# Recomputed from the two files by the documented formula, the way a Rust or
# shell consumer would have to.
check "identity is reproducible from the schema and registry files alone" "python3 - <<'PY'
import hashlib, json
identity = json.load(open('$TMP/identity.json'))
schema = hashlib.sha256(open('$ROOT/contracts/command-capabilities-v1.schema.json','rb').read()).hexdigest()
doc = json.load(open('$REGISTRY'))
canonical = json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=False) + '\n'
registry = hashlib.sha256(canonical.encode()).hexdigest()
want = hashlib.sha256(f\"{doc['schema']}\n{schema}\n{registry}\n\".encode()).hexdigest()
raise SystemExit(0 if (identity['schema_sha256'], identity['registry_sha256'], identity['identity_sha256'])
                 == (schema, registry, want) else 1)
PY"
python3 "$TOOL" identity "$REGISTRY" "$ROOT/scripts/wv" "$TMP/schema-lax.json" >"$TMP/identity-lax.json" 2>&1
check "a schema edit moves the identity while the registry digest stands still" "python3 - <<'PY'
import json
base = json.load(open('$TMP/identity.json'))
lax = json.load(open('$TMP/identity-lax.json'))
raise SystemExit(0 if base['registry_sha256'] == lax['registry_sha256']
                 and base['schema_sha256'] != lax['schema_sha256']
                 and base['identity_sha256'] != lax['identity_sha256'] else 1)
PY"
# The assertion that the private evidence consumer binds this identity rather
# than reimplementing it lives with that consumer, in the private evidence
# suite. It used to live here, which made a retained public test import a
# package the release excludes, so it could not run in the projection it shipped
# into. A public contract suite asserts the contract; the private consumer
# asserts that it consumes it.

# TOTALITY. Every dispatched command has a command-level row, read the same way
# wv pattern-audit reads the dispatch table.
check "every dispatched command has a command-level row" "python3 - <<'PY'
import json, re, sys
rows = json.load(open('$REGISTRY'))['commands']
base = {r['operation'] for r in rows if 'suboperation' not in r}
disp = set()
for line in open('$ROOT/scripts/wv', encoding='utf-8'):
    m = re.match(r'^\s+([a-z][a-zA-Z_-]+)\)', line)
    if m: disp.add(m.group(1))
raise SystemExit(0 if base == disp else 1)
PY"

# DOMINANCE negative controls. A fallback row that is weaker than a suboperation
# beneath it must fail, or 'conservative where flags alter effects' is only prose.
weaken() {
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for row in doc['commands']:
    if row['operation'] == 'config' and 'suboperation' not in row:
        if sys.argv[2] == 'class':
            row['evidence_class'] = 'observation'
        elif sys.argv[2] == 'targets':
            row['mutation_targets'] = []
        elif sys.argv[2] == 'invalidate':
            row['cache'] = {'serve': False, 'invalidate': False}
open(sys.argv[1], 'w').write(json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=False) + '\n')
PY
}
for weakness in class targets invalidate; do
  cp "$REGISTRY" "$TMP/reg-$weakness.json"
  weaken "$TMP/reg-$weakness.json" "$weakness"
  set +e
  python3 "$TOOL" validate "$TMP/reg-$weakness.json" "$ROOT/scripts/wv" >"$TMP/out-$weakness" 2>&1
  rc=$?
  set -e
  check "a weakened $weakness fallback is rejected" "[ $rc -ne 0 ]"
done

# The generated projection must resolve an unlisted suboperation to the
# command-level row, which dominance guarantees is never weaker.
check "an unlisted suboperation falls back to the command-level row" "
  out=\$(bash -c '. \"$ARTIFACT\"; _wv_cap_evidence_class config wibble')
  [ \"\$out\" = mutation_attempt ]"
check "a listed suboperation resolves to its own row" "
  out=\$(bash -c '. \"$ARTIFACT\"; _wv_cap_evidence_class config get')
  [ \"\$out\" = observation ]"
check "an undeclared operation is reported unknown" "
  ! bash -c '. \"$ARTIFACT\"; _wv_cap_known definitely-not-a-command'"

# RUNTIME CONSUMERS. The three hand-maintained lists in wv-cache.sh are gone and
# the dispatcher now asks the projection directly, so these assert the wiring
# rather than the agreement of two copies (the migration guard they replace).
check "wv sources the generated projection before dispatching" \
  "grep -q 'source \"\$WV_LIB_DIR/lib/wv-command-capabilities.sh\"' '$ROOT/scripts/wv'"
check "the retired cache classifiers are gone from wv-cache.sh" \
  "! grep -qE '_wv_run_cache_is_(read|write|exempt)_cmd' '$ROOT/scripts/lib/wv-cache.sh' '$ROOT/scripts/wv' '$ROOT/scripts/cmd/wv-cmd-ops.sh' '$ROOT/scripts/cmd/wv-cmd-doctor.sh' '$ROOT/scripts/cmd/wv-cmd-health.sh' '$ROOT/scripts/cmd/wv-cmd-help.sh' '$ROOT/scripts/cmd/wv-cmd-orient.sh'"
check "the dispatcher classifies at command level through the registry" \
  "grep -q '_wv_cap_serve \"\$cmd\" \"\"' '$ROOT/scripts/wv' &&
   grep -q '_wv_cap_invalidate \"\$cmd\" \"\"' '$ROOT/scripts/wv'"
check "pattern-audit totality reads the registry" \
  "grep -q '_wv_cap_known \"\$cmd\"' '$ROOT/scripts/cmd/wv-cmd-doctor.sh'"

# Cache behaviour must be unchanged by the migration. The registry is compared
# against the classification the retired lists produced, pinned here as data:
# with the functions deleted there is nothing left to compare against at
# runtime, and "behaviour-preserving" would otherwise be an untested claim.
PINNED="$ROOT/tests/fixtures/cache-classification-pre-registry.txt"
grep -E '^[a-z]' "$PINNED" | cut -d' ' -f1 | bash -c '
  . "'"$ARTIFACT"'"
  while read -r c; do
    if _wv_cap_serve "$c" ""; then s=1; else s=0; fi
    if _wv_cap_invalidate "$c" ""; then i=1; else i=0; fi
    printf "%s %s %s\n" "$c" "$s" "$i"
  done' > "$TMP/cache-now.txt"
check "cache behaviour matches the retired lists for every dispatched command" \
  "diff <(grep -E '^[a-z]' '$PINNED') '$TMP/cache-now.txt' >/dev/null"
check "the pinned classification still covers every dispatched command" "
  dispatched=\$(grep -E '^[[:space:]]+[a-z][a-zA-Z_-]+\)' '$ROOT/scripts/wv' | sed 's/[[:space:]]//g; s/).*\$//' | sort -u | wc -l)
  pinned=\$(grep -cE '^[a-z]' '$PINNED')
  [ \"\$dispatched\" -eq \"\$pinned\" ]"

# The projection carries what a consumer binds and what an attempt journal will
# record: the contract identity, and the targets a mutation may touch.
check "the projection records the contract identity" "python3 - <<'PY'
import json, re, subprocess
identity = json.loads(subprocess.run(
    ['python3', '$TOOL', 'identity'], capture_output=True, text=True, check=True).stdout)
artifact = open('$ARTIFACT', encoding='utf-8').read()
want = {
    'WV_CAPABILITIES_SHA256': identity['registry_sha256'],
    'WV_CAPABILITIES_SCHEMA_SHA256': identity['schema_sha256'],
    'WV_CAPABILITIES_IDENTITY': identity['identity_sha256'],
}
missing = [k for k, v in want.items() if f'{k}=\"{v}\"' not in artifact]
raise SystemExit(1 if missing else 0)
PY"
check "a suboperation resolves its own targets and an unlisted one falls back" "
  base=\$(bash -c '. \"$ARTIFACT\"; _wv_cap_targets config')
  refined=\$(bash -c '. \"$ARTIFACT\"; _wv_cap_targets config get')
  fallback=\$(bash -c '. \"$ARTIFACT\"; _wv_cap_targets config wibble')
  [ \"\$base\" = 'installation repo_state' ] && [ -z \"\$refined\" ] && [ \"\$fallback\" = \"\$base\" ]"
check "an undeclared operation has no targets" \
  "! bash -c '. \"$ARTIFACT\"; _wv_cap_targets definitely-not-a-command'"

# Evidence class is NOT the cache write list: the registry must classify the
# commands that list exempts but which genuinely mutate the repository.
check "cache-exempt repository mutations are still evidence-class mutations" "python3 - <<'PY'
import json
rows = json.load(open('$REGISTRY'))['commands']
base = {r['operation']: r for r in rows if 'suboperation' not in r}
missed = [c for c in ('cutover','init','init-repo','repo-class','doctor','trails','breadcrumbs','quality')
          if base[c]['evidence_class'] != 'mutation_attempt' or base[c]['cache']['invalidate']]
raise SystemExit(1 if missed else 0)
PY"

# wv-e07ee4: nothing fed resolve() a ref it must refuse, so dropping the raise
# survived; a circular ref then loops forever, hence the timeout. The chained
# control keeps a refusal from meaning a broken fixture.
cat >"$TMP/ref-probe.py" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from weave_registry import resolve
root = {"$defs": {"a": {"$ref": "#/$defs/b"}, "b": {"$ref": "#/$defs/a"},
                  "c": {"$ref": "#/$defs/d"}, "d": {"type": "string"}}}
if resolve({"$ref": "#/$defs/c"}, root) != {"type": "string"}:
    raise SystemExit("control: a ref chain did not resolve")
for ref in ("#/$defs/a", "other.json#/x"):
    try:
        resolve({"$ref": ref}, root)
    except ValueError as exc:
        if "unsupported or circular $ref" not in str(exc):
            raise SystemExit(f"{ref}: wrong refusal: {exc}")
    else:
        raise SystemExit(f"{ref}: accepted")
PY
check "a circular or non-local \$ref is refused, not followed" \
  "timeout 10 python3 '$TMP/ref-probe.py' '$ROOT/scripts'"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
