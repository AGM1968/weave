#!/usr/bin/env bash
# test-delta-retention.sh -- wv compact --pre-cutover (wv-28ef47), Stage A of
# docs/PROPOSAL-delta-retention.md, tests 1-7 of its Verification section plus
# the two review requirements: a pending transaction fences writers and E5
# capture-start until --resume or --abort, and the pinned source is
# revalidated before anything is removed.
#
# Every case works on its own copy of one fixture repository. GIT_* is unset
# first: an exported GIT_DIR would point the scratch repositories at the real
# one (wv-8f1da6).

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091  # resolved at run time
source "$REPO_ROOT/scripts/lib/wv-lock.sh"  # flock(1) is util-linux; macOS has none (wv-412db3)
WV="$REPO_ROOT/scripts/wv"

T=$(mktemp -d)
trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg"
export WV_AGENT_ID="retention-test"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_NONINTERACTIVE=1
export WV_SYNC_INTERVAL=0
export WV_MAINT_LOCK_WAIT=60
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

# use DIR -- point wv at the repository DIR with its own hot zone.
use() {
    export WV_PROJECT_DIR="$1" WEAVE_DIR="$1/.weave" WV_HOT_ZONE="$1/.hot"
    unset WV_DB
    mkdir -p "$WV_HOT_ZONE"; chmod 700 "$WV_HOT_ZONE"
    cd "$1" || exit 1
}
db() { echo "$WV_HOT_ZONE/brain.db"; }
gitc() { git -c user.email=t@t -c user.name=t "$@"; }
maint() { echo "$(git rev-parse --absolute-git-dir)/weave-maintenance"; }

# fork_sidecars DIR NODE SEQ -- two v2 ops from one preimage on NODE's text:
# the second loses and is reported as a lost write on every load (wv-898c73).
fork_sidecars() {
    python3 - "$1" "$2" "$3" <<'PY'
import hashlib, json, pathlib, sys, uuid
out, node, seq = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(x) for x in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v).__name__)
for i, value in enumerate(("side a", "side b")):
    s = seq + i
    doc = {"format": "weave.delta.v2", "operation_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"fork-{i}")),
           "actor_id": "peer", "actor_sequence": s, "canonicalization": "weave.canonical-json.v1",
           "payload": {"entity": {"kind": "node", "id": node}, "lineage": {"seq": s, "actor": "peer"},
                       "mutation": {"kind": "node_patch",
                                    "fields": {"text": {"expected": "fork target", "value": value}}}}}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / f"{s:012d}-{doc['operation_id']}.json").write_text(canonical(doc) + "\n")
PY
}

# ── fixture ─────────────────────────────────────────────────────────────────
# Pre-cutover header-less v1 deltas (4 eligible), a header-less file changed
# after the marker and one added after it (both listed, not candidates),
# post-cutover headed v1 and v2 emissions, an unresolved lost write, and a
# delete as the newest op (tombstone at the top seq).
FIX="$T/fixture"
mkdir -p "$FIX"
use "$FIX"
git init -q
# Compaction commits by itself; the gate's frozen runner sets GIT_CONFIG_GLOBAL
# to /dev/null and a scratch HOME, so the fixture carries its own identity.
git config user.email t@t && git config user.name t
# The runtime files a Weave checkout ignores: the one list wv-init-repo gives
# consumers (wv-9a54da), not this repository's .gitignore, which the release
# ships as a bare '.weave/' and so left the fixture's marker uncommitted
# (wv-581ec2).
# shellcheck source=scripts/lib/wv-runtime-ignores.sh
source "$REPO_ROOT/scripts/lib/wv-runtime-ignores.sh"
wv_runtime_ignores > .gitignore
printf '.hot/\nscripts\n' >> .gitignore
# E5 capture-start snapshots the runtime through <repo>/scripts/wv.
ln -s "$REPO_ROOT/scripts" scripts
"$WV" init >/dev/null 2>&1
add_node() { "$WV" add "$1" --criteria=c --risks=low 2>&1 | sed -nE 's/^✓ (wv-[a-f0-9]{6}): .*/\1/p' | head -1; }
N_KEEP=$(add_node "keeper")
N_FORK=$(add_node "fork target")
N_DEL=$(add_node "to be deleted")
"$WV" sync >/dev/null 2>&1
old="$WEAVE_DIR/deltas/2026-08-01"
mkdir -p "$old"
for i in 1 2 3 4 5; do
    printf -- "-- pre-lineage delta %s\nUPDATE nodes SET text='keeper' WHERE id='%s';\n" "$i" "$N_KEEP" \
        > "$old/175400000$i-old-agent-$i.sql"
done
gitc add -A >/dev/null; gitc commit -qm "fixture: pre-cutover catalog"
"$WV" cutover --yes >/dev/null 2>&1
gitc add -A >/dev/null; gitc commit -qm "fixture: causal cutover marker"
# After the marker: one header-less file changed, one added.
printf -- "-- edited after the marker\n" >> "$old/1754000005-old-agent-5.sql"
printf -- "-- hand-written after the marker\n" > "$WEAVE_DIR/deltas/2026-08-01/1754000099-hand.sql"
"$WV" update "$N_KEEP" --text="keeper, edited after cutover" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1
base=$(sqlite3 "$(db)" "SELECT COALESCE(MAX(lineage_seq),0) FROM nodes;")
fork_sidecars "$WEAVE_DIR/deltas/2026-09-10/v2" "$N_FORK" $((base + 1))
gitc add -A >/dev/null; gitc commit -qm "fixture: post-cutover work and a fork"
"$WV" load >/dev/null 2>&1
"$WV" delete "$N_DEL" --force >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1
gitc add -A >/dev/null; gitc commit -qm "fixture: delete as the newest op"
FIX_HEAD=$(git rev-parse HEAD)

# copy NAME -- a fresh copy of the fixture, loaded, selected with use().
copy() {
    cp -a "$FIX" "$T/$1"
    rm -rf "$T/$1/.hot" "$(git -C "$T/$1" rev-parse --absolute-git-dir)/weave-maintenance"
    use "$T/$1"
    "$WV" load >/dev/null 2>&1
}

echo "--- fixture ---"
check "fixture has 6 header-less pre-marker-dir files, a marker and a tombstone" \
    test "$(( $(git ls-files '.weave/deltas/2026-08-01/*.sql' | wc -l) ))" -eq 6 -a -f "$FIX/.weave/causal-cutover"
copy probe
check "fixture load reports the lost write" bash -c "'$WV' load 2>&1 | grep -q 'lost a conflict on the same field'"
check "fixture holds the tombstone" test "$(sqlite3 "$(db)" "SELECT COUNT(*) FROM tombstones WHERE id='$N_DEL';")" -eq 1
check "the tombstone is the newest op" test \
    "$(sqlite3 "$(db)" "SELECT MAX(lineage_seq) FROM tombstones;")" -ge "$(sqlite3 "$(db)" "SELECT MAX(lineage_seq) FROM nodes;")"

# observe DIR OUT -- load DIR's committed tree in isolation and write the four
# compared components: durable dump, tombstones, clock base, lost writes.
observe() {
    local src="$1" out="$2"
    mkdir -p "$out/hot" && chmod 700 "$out/hot"
    git -C "$src" archive HEAD -- .weave | tar -x -C "$out"
    ( export WV_PROJECT_DIR="$out" WEAVE_DIR="$out/.weave" WV_HOT_ZONE="$out/hot"
      "$WV" load >/dev/null 2>"$out/load.err"
      sqlite3 "$out/hot/brain.db" ".dump nodes" ".dump edges" ".dump node_files" ".dump tombstones" > "$out/durable"
      sqlite3 "$out/hot/brain.db" "SELECT * FROM tombstones ORDER BY 1;" > "$out/tomb"
      bash -c "source '$REPO_ROOT/scripts/lib/wv-delta.sh' && wv_lineage_seq_base '$out/hot/brain.db' '$out/.weave/deltas'" > "$out/seq"
      grep -A50 'lost a conflict' "$out/load.err" | grep '^    ' > "$out/lost" || true )
}
same_obs() { local c; for c in durable tomb seq lost; do cmp -s "$1/$c" "$2/$c" || { echo "    $c differs" >&2; return 1; }; done; }

# ── 1. equivalence and the exact manifest ──────────────────────────────────
echo "--- 1. equivalence ---"
copy c1
observe "$T/c1" "$T/obs-before"
rc=0; out=$("$WV" compact --pre-cutover 2>&1) || rc=$?
echo "$out" | sed 's/^/      /'
check "compaction succeeds (rc=$rc)" test "$rc" -eq 0
check "it committed on the source" test "$(git rev-parse HEAD^)" = "$FIX_HEAD"
manifest=$(git show --name-only --format= HEAD | grep '^.weave/compaction/.*-pre-cutover.json$')
check "the commit carries one manifest" test -n "$manifest" -a -f "$manifest"
check "the pending record is gone" test ! -e "$(maint)/pending.json"
observe "$T/c1" "$T/obs-after"
check "durable tables, tombstones, clock base and lost writes are identical" same_obs "$T/obs-before" "$T/obs-after"
check "the lost write is still reported" test -s "$T/obs-after/lost"
check "the observed loads are not empty" grep -q "INSERT INTO nodes" "$T/obs-after/durable"
expected=$(for i in 1 2 3 4; do f=".weave/deltas/2026-08-01/175400000$i-old-agent-$i.sql"
    printf '%s %s %s\n' "$f" "$(git rev-parse "$FIX_HEAD:$f")" 100644; done)
got=$(python3 -c 'import json,sys
for e in sorted(json.load(open(sys.argv[1]))["entries"], key=lambda e: e["path"]):
    print(e["path"], e["blob"], e["mode"])' "$manifest")
check "the manifest is exactly the eligible set, path, blob and mode" test "$got" = "$expected"
listed=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["not_candidates"]))' "$manifest")
check "the header-less files changed or added after the marker are listed, not candidates" test \
    "$listed" = "$(printf '%s\n' .weave/deltas/2026-08-01/1754000005-old-agent-5.sql .weave/deltas/2026-08-01/1754000099-hand.sql)"
check "no v2 path and no headed v1 file is in the manifest" bash -c \
    "! grep -q '/v2/' <<< '$got' && ! grep -l 'weave-lineage seq=' \$(git show '$FIX_HEAD' --name-only --format= | head -0) /dev/null >/dev/null 2>&1"
check "the source commit and marker commit are recorded" test \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["source_commit"], bool(d["marker_commit"]))' "$manifest")" = "$FIX_HEAD True"
mkdir -p "$T/id-before"; git archive "$FIX_HEAD" -- .weave/deltas | tar -x -C "$T/id-before"
ident() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"][sys.argv[2]])' "$manifest" "$1"; }
check "the identity changed" test "$(ident before)" != "$(ident after)"
check "the commit message declares the transition" bash -c "git log -1 --format=%B | grep -q 'Declared causal identity transition'"
check "the compaction commit touches .weave/ only" bash -c "! git show --name-only --format= HEAD | grep -v '^.weave/'"
C1_MANIFEST="$manifest"

# ── 6. restore ──────────────────────────────────────────────────────────────
echo "--- 6. restore ---"
rc=0; "$WV" compact --pre-cutover --restore="$C1_MANIFEST" >/dev/null 2>&1 || rc=$?
check "restore succeeds" test "$rc" -eq 0
check "every manifest path is back, byte for byte from the source commit" bash -c '
    for i in 1 2 3 4; do f=.weave/deltas/2026-08-01/175400000$i-old-agent-$i.sql
        git show "'"$FIX_HEAD"':$f" | cmp -s - "$f" || exit 1
        [ "$(git ls-files -s "$f" | cut -d" " -f2)" = "$(git rev-parse "'"$FIX_HEAD"':$f")" ] || exit 1
    done'

# ── 2. refusals ─────────────────────────────────────────────────────────────
echo "--- 2. refusals ---"
# refuses NAME -- compaction exits nonzero, HEAD unchanged, no pending record.
refuses() {
    local name="$1" head rc=0 out
    head=$(git rev-parse HEAD)
    out=$("$WV" compact --pre-cutover 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] && [ "$(git rev-parse HEAD)" = "$head" ] && [ ! -e "$(maint)/pending.json" ]; then
        ok "refuses: $name"
    else
        bad "refuses: $name (rc=$rc): $(echo "$out" | tail -2)"
    fi
    LAST_OUT="$out"
}
copy r-nomarker; gitc rm -q .weave/causal-cutover; gitc commit -qm "drop marker"
refuses "no cutover marker"
copy r-badmarker; printf '{"schema":"weave.causal-cutover.v1","lineage_seq":"x"}\n' > .weave/causal-cutover
gitc commit -qam "garble marker"
refuses "a malformed marker"
copy r-uncommitted; gitc rm -q --cached .weave/causal-cutover; gitc commit -qm "untrack marker"
refuses "a marker not in HEAD's ancestry"
grep -q "not committed in HEAD's ancestry" <<< "$LAST_OUT" && ok "...and says so" || bad "...and says so: $LAST_OUT"
copy r-dirty; echo "x" > .weave/stray
refuses "a dirty .weave/"
# Another actor's claim, synced and committed, so the refusal is the claim's
# and not a dirty .weave/ (this actor's own claim is allowed: wv-8bf28e).
copy r-claim; WV_AGENT_ID=other-agent "$WV" work "$N_KEEP" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1; gitc add -A; gitc commit -qm "other actor's claim" >/dev/null
refuses "a node claimed by another actor"
grep -q "claimed by other actors" <<< "$LAST_OUT" && ok "...and names the other actor's claim" || bad "...and names the other actor's claim: $LAST_OUT"
copy r-reserved; "$WV" update "$N_KEEP" --metadata='{"e5_reserved":true}' >/dev/null 2>&1; "$WV" sync >/dev/null 2>&1
gitc add -A; gitc commit -qm "reserve" >/dev/null
refuses "an open E5 reservation"
copy r-locked; mkdir -p "$(maint)"
( exec 9>>"$(maint)/lock"; wv_lock_fd 9 -s 10; sleep 30 ) & holder=$!
sleep 0.5
refuses "the lock held shared by another process"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# ── 2b. the commit gate (wv-8bf28e) ─────────────────────────────────────────
# The first real run (2026-11-06) was refused at its commit: compaction refused
# any claim, and the repository's pre-commit gate refuses a commit without one.
# This hook stands in for the gate's claim check (_pc_require_claim reads the
# same listing); the fixture repository has no Weave hooks of its own.
echo "--- 2b. own claim and the commit gate ---"
# The gate and its frozen runner force core.hooksPath=/dev/null through
# GIT_CONFIG_*, which would silence this hook; the cases below need it to run.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
claim_hook() {
    mkdir -p "$(git rev-parse --git-path hooks)"
    cat > "$(git rev-parse --git-path hooks)/pre-commit" <<HOOK
#!/usr/bin/env bash
n=\$("$WV" list --status=active --claimed-by=current --json 2>/dev/null | jq length)
[ "\${n:-0}" -gt 0 ] || { echo "pre-commit: no active claim held by this actor" >&2; exit 1; }
HOOK
    chmod +x "$(git rev-parse --git-path hooks)/pre-commit"
}
copy g-noclaim; claim_hook
refuses "no claim of its own where a pre-commit hook runs"
grep -q "claim the compaction's node first" <<< "$LAST_OUT" && ok "...before writing anything, naming wv work" \
    || bad "...before writing anything, naming wv work: $LAST_OUT"
copy g-ownclaim; claim_hook
"$WV" work "$N_KEEP" >/dev/null 2>&1; "$WV" sync >/dev/null 2>&1
gitc add -A; gitc commit -qm "own claim" >/dev/null
g_head=$(git rev-parse HEAD)
rc=0; out=$("$WV" compact --pre-cutover 2>&1) || rc=$?
check "with its own claim, compaction commits through a claim-requiring pre-commit hook (rc=$rc)" test "$rc" -eq 0
check "...on the source commit" test "$(git rev-parse HEAD^)" = "$g_head"
check "...with the claimed node's Weave-ID trailer" bash -c "git log -1 --format=%B | grep -qx 'Weave-ID: $N_KEEP'"
check "...and lifts the pending record" test ! -e "$(maint)/pending.json"

# ── 3. the equivalence guard bites ─────────────────────────────────────────
echo "--- 3. equivalence guard ---"
# plant NAME PATH COMPONENT -- PATH as an extra candidate is refused, the
# COMPONENT difference is printed, and nothing is touched.
plant() {
    local name="$1" path="$2" comp="$3" head rc=0 out
    head=$(git rev-parse HEAD)
    out=$(WV_TEST_MODE=1 WV_TEST_COMPACT_PLANT_CANDIDATE="$path" "$WV" compact --pre-cutover 2>&1) || rc=$?
    check "a planted $name is refused" test "$rc" -ne 0 -a "$(git rev-parse HEAD)" = "$head"
    check "...with the $comp difference printed" grep -qF -- "$comp differs" <<< "$out"
    check "...and nothing deleted" test -z "$(git status --porcelain)" -a ! -e "$(maint)/pending.json"
}
copy g
plant "lost-write sidecar" "$(git ls-files '.weave/deltas/2026-09-10/v2/*.json' | LC_ALL=C sort | tail -1)" lost_writes
# The review's clock counterexample: the newest op was a delete, and its seq
# once survived only in the sidecar name. Since the clock floor (wv-5575bb)
# the tombstone holds it, so removing that sidecar no longer moves the base.
copy g2
seqb() { bash -c "source '$REPO_ROOT/scripts/lib/wv-delta.sh' && wv_lineage_seq_base '$(db)' '$WEAVE_DIR/deltas'"; }
top=$(git ls-files '.weave/deltas/*/v2/*.json' | LC_ALL=C sort -t/ -k5 | tail -1)
b0=$(seqb); rc=0
out=$(WV_TEST_MODE=1 WV_TEST_COMPACT_PLANT_CANDIDATE="$top" "$WV" compact --pre-cutover 2>&1) || rc=$?
"$WV" load >/dev/null 2>&1
check "removing the delete-as-newest-op sidecar passes the equivalence guard" \
    test "$rc" -eq 0 -a ! -e "$top" -a -z "$(git ls-files "$top")"
check "...and leaves the clock base unchanged" test "$(seqb)" = "$b0" -a "$b0" -gt 0
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/    /' >&2
# The guard still bites on the clock: a seq held by no row and no tombstone (a
# second fork above the top, both sides losing) lives only in its sidecar.
copy g3
top=$(seqb)
fork_sidecars "$WEAVE_DIR/deltas/2026-09-11/v2" "$N_FORK" $((top + 1))
gitc add -A >/dev/null; gitc commit -qm "fixture: a fork above the top seq"
"$WV" load >/dev/null 2>&1
plant "sidecar-only top seq" "$(git ls-files '.weave/deltas/2026-09-11/v2/*.json' | LC_ALL=C sort | tail -1)" seq_base

# ── 4. coordination ─────────────────────────────────────────────────────────
echo "--- 4. coordination ---"
# A local edit not yet published: the sync below has something to publish.
copy k; WV_AUTO_SYNC=0 "$WV" update "$N_KEEP" --text="pending local edit" >/dev/null 2>&1
before_files=$(( $(git ls-files -o --exclude-standard .weave | wc -l) ))
touch "$T/pause"
( WV_TEST_MODE=1 WV_TEST_COMPACT_PAUSE_FILE="$T/pause" "$WV" compact --pre-cutover >"$T/k.out" 2>&1; echo $? > "$T/k.rc" ) &
for _ in $(seq 300); do [ -e "$T/pause.paused" ] && break; sleep 0.1; done
check "compaction is paused under its lock" test -e "$T/pause.paused"
( "$WV" sync >"$T/k-sync.out" 2>&1; echo $? > "$T/k-sync.rc" ) &
sleep 2
check "wv sync waits while compaction holds the lock" test ! -e "$T/k-sync.rc"
check "nothing was published meanwhile" test "$(( $(git ls-files -o --exclude-standard .weave | wc -l) ))" -eq "$before_files"
rm -f "$T/pause"
for _ in $(seq 600); do [ -e "$T/k.rc" ] && [ -e "$T/k-sync.rc" ] && break; sleep 0.1; done
check "compaction then commits (rc=$(cat "$T/k.rc" 2>/dev/null))" test "$(cat "$T/k.rc" 2>/dev/null)" = 0
check "the compaction commit holds no writer's files" bash -c \
    "git show --name-status --format= HEAD | grep -v '^D' | grep -v '.weave/compaction/' | grep -q . && exit 1 || exit 0"
check "the waiting sync completes after it (rc=$(cat "$T/k-sync.rc" 2>/dev/null))" test "$(cat "$T/k-sync.rc" 2>/dev/null)" = 0
copy k2; mkdir -p "$(maint)"
( exec 9>>"$(maint)/lock"; wv_lock_fd 9 -s 10; sleep 30 ) & holder=$!
sleep 0.5
refuses "while another process holds the lock shared"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# ── the fault hooks are gated ──────────────────────────────────────────────
echo "--- fault hooks ---"
copy h
# env -u: the gate's frozen runner exports WV_TEST_MODE=1 to every suite.
rc=0; out=$(env -u WV_TEST_MODE WV_TEST_COMPACT_FAULT_AFTER_REMOVALS=1 "$WV" compact --pre-cutover 2>&1) || rc=$?
check "a fault hook without WV_TEST_MODE=1 is ignored, with a warning" test "$rc" -eq 0 -a ! -e "$(maint)/pending.json"
check "...naming the hook" grep -qF -- "WV_TEST_COMPACT_FAULT_AFTER_REMOVALS is set but WV_TEST_MODE=1 is not" <<< "$out"
copy h2; head=$(git rev-parse HEAD); rc=0
WV_TEST_MODE=1 WV_TEST_COMPACT_FAULT_AFTER_REMOVALS=two "$WV" compact --pre-cutover >/dev/null 2>&1 || rc=$?
check "an unrecognised fault-hook value is an error that changes nothing" \
    test "$rc" -ne 0 -a "$(git rev-parse HEAD)" = "$head" -a -z "$(git status --porcelain)" -a ! -e "$(maint)/pending.json"

# ── 5. interruption ─────────────────────────────────────────────────────────
echo "--- 5. interruption ---"
# crash NAME -- a copy, killed after 2 of 4 removals.
crash() {
    copy "$1"
    WV_TEST_MODE=1 WV_TEST_COMPACT_FAULT_AFTER_REMOVALS=2 "$WV" compact --pre-cutover >/dev/null 2>&1
    CRASH_MANIFEST=$(ls .weave/compaction/*.json 2>/dev/null | head -1)
}
crash i1
check "the killed compaction left its pending record and manifest" test -f "$(maint)/pending.json" -a -n "$CRASH_MANIFEST"
check "...and half the removals" test "$(( $(git ls-files -d | wc -l) ))" -eq 2
check "...and no commit" test "$(git rev-parse HEAD)" = "$FIX_HEAD"
# Through wv_lock_fd, the mechanism the product uses (flock(1), else python3
# fcntl): flock(1) is util-linux, absent on macOS (wv-412db3).
check "...and released its lock" bash -c '. "$1/scripts/lib/wv-lock.sh"; exec 9>>"$2"; wv_lock_fd 9 -x 0' _ "$REPO_ROOT" "$(maint)/lock"
# The fence: every writer and capture-start refuses before recovery.
"$WV" update "$N_KEEP" --text="edit during crash" >/dev/null 2>&1
rc=0; out=$("$WV" sync 2>&1) || rc=$?
check "wv sync refuses while the transaction is pending" test "$rc" -ne 0
check "...and names the recovery" grep -q -- "--resume" <<< "$out"
check "...and published nothing" test -z "$(git ls-files -o --exclude-standard .weave | grep -v '^.weave/compaction/')"
rc=0; "$WV" compact --pre-cutover >/dev/null 2>&1 || rc=$?
check "a fresh compaction refuses while one is pending" test "$rc" -ne 0
rc=0; "$WV" compact --pre-cutover --resume >/dev/null 2>&1 || rc=$?
check "--resume completes from the manifest" test "$rc" -eq 0 -a "$(git rev-parse HEAD^)" = "$FIX_HEAD" -a ! -e "$(maint)/pending.json"
check "...removing exactly the manifest" test "$(git show --name-status --format= HEAD | grep -c '^D')" -eq 4
rc=0; "$WV" sync >/dev/null 2>&1 || rc=$?
check "wv sync works again after recovery" test "$rc" -eq 0

crash i2
rc=0; "$WV" compact --pre-cutover --abort >/dev/null 2>&1 || rc=$?
check "--abort succeeds" test "$rc" -eq 0
check "...restoring tree and index to the source commit" test -z "$(git status --porcelain)" -a "$(git rev-parse HEAD)" = "$FIX_HEAD"
check "...and removing the manifest and the pending record" test ! -e "$CRASH_MANIFEST" -a ! -e "$(maint)/pending.json"

# pinned STATE-CHANGE -- resume and abort both refuse and change nothing.
pinned() {
    local name="$1" snap rc1=0 rc2=0
    snap=$(git status --porcelain; git rev-parse HEAD; git ls-files -s | sha256sum)
    "$WV" compact --pre-cutover --resume >/dev/null 2>&1 || rc1=$?
    "$WV" compact --pre-cutover --abort >/dev/null 2>&1 || rc2=$?
    if [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] && [ -e "$(maint)/pending.json" ] \
        && [ "$snap" = "$(git status --porcelain; git rev-parse HEAD; git ls-files -s | sha256sum)" ]; then
        ok "resume and abort refuse, changing nothing, when $name"
    else
        bad "resume and abort refuse, changing nothing, when $name (rc=$rc1/$rc2)"
    fi
}
crash i3; gitc commit -q --allow-empty -m "someone else moved HEAD"
pinned "HEAD has moved"
crash i4; f=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entries"][-1]["path"])' "$CRASH_MANIFEST")
echo "-- tampered" >> "$f"
pinned "a manifest path holds an unexpected blob"
crash i5; echo "x" > .weave/outside-the-manifest
pinned "a path outside the manifest changed"

# ── 7. peer merge ───────────────────────────────────────────────────────────
echo "--- 7. peer merge ---"
pre_marker=$(git -C "$T/c1" log --format=%H --diff-filter=A -- .weave/causal-cutover | tail -1)^
git clone -q "$T/c1" "$T/peer" && git -C "$T/peer" checkout -q -B main "$pre_marker"
use "$T/peer"; "$WV" load >/dev/null 2>&1
git -C "$T/peer" pull -q --ff-only "$T/c1" HEAD 2>/dev/null || git -C "$T/peer" merge -q --ff-only FETCH_HEAD
"$WV" load >/dev/null 2>&1
check "the peer has the deletion commit" test "$(git rev-parse HEAD)" = "$(git -C "$T/c1" rev-parse HEAD)"
git clone -q "$T/c1" "$T/fresh"
observe "$T/peer" "$T/obs-peer"; observe "$T/fresh" "$T/obs-fresh"
check "a peer behind the marker loads the same graph as a clone that never had the files" same_obs "$T/obs-peer" "$T/obs-fresh"
sqlite3 "$WV_HOT_ZONE/brain.db" ".dump nodes" ".dump edges" ".dump node_files" ".dump tombstones" > "$T/peer-live"
check "...and so does the peer's own live database" cmp -s "$T/peer-live" "$T/obs-fresh/durable"

echo ""
echo "$pass/$run passed"
[ "$pass" -eq "$run" ]
