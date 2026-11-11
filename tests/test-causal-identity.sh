#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The composite causal identity recorded on every instrumented call.
#
# The identity it replaced covered nodes, edges and node_files: it moved when a
# node's text changed and stood still when a tombstone was written, a cutover
# was stamped, or a delta arrived. Each check below moves exactly ONE component
# and requires the identity to move with it, because a causal identity that
# misses an input is worse than none -- it reports "nothing changed" about a
# change it cannot see.
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
differs() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "identity did not move: $2"; fi; }

TEST_DIR=$(mktemp -d /tmp/wv-causal-identity-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
# config.env is sourced with `set -a` on every invocation and therefore beats an
# ambient export: without a config dir of its own this suite would write into the
# operator's real call log and read identities that are not its own.
export WV_CONFIG_DIR="$TEST_DIR/config"
mkdir -p "$WV_CONFIG_DIR"
export WV_CALL_LOG="$TEST_DIR/calls.jsonl"
cd "$TEST_DIR" || exit 1
git init -q . >/dev/null 2>&1
git config user.email test@test.com; git config user.name Test; git config commit.gpgsign false
"$WV" init >/dev/null 2>&1

echo "=== composite causal identity ==="

# The identity after the previous call, read back from the log the call wrote.
identity() {
    "$WV" status >/dev/null 2>&1
    tail -1 "$WV_CALL_LOG" | jq -r '.graph_identity_after.value // "unavailable"'
}
kind() { tail -1 "$WV_CALL_LOG" | jq -r '.graph_identity_after.kind // "missing"'; }

base=$(identity)
check "the identity is a composite, not a graph fingerprint" "composite_causal_identity" "$(kind)"
case "$base" in
    sha256:*) ok "the identity is a sha256 value" ;;
    *) bad "the identity is a sha256 value" "got [$base]" ;;
esac
check "a call that changes nothing leaves the identity where it was" "$base" "$(identity)"

# ROWS. The one component the old fingerprint already covered.
"$WV" add "identity probe" --standalone >/dev/null 2>&1
rows_moved=$(identity)
differs "a new node moves the identity" "$base" "$rows_moved"

# TOMBSTONES. A delete writes a tombstone; nodes and edges lose a row, so this
# would move any fingerprint. What the tombstone check needs is a change that
# ONLY touches the tombstone table, which is why it is written directly.
probe=$("$WV" add "tombstone probe" --standalone --json 2>/dev/null | jq -r '.id // empty')
before_tombstone=$(identity)
# wv hotzone --db is the supported way to reach the live database; guessing a
# hot-zone path is how a test ends up asserting against a file nothing wrote.
db=$("$WV" hotzone --db 2>/dev/null | tail -1)
sqlite3 "$db" "INSERT OR REPLACE INTO tombstones (kind, id, lineage_seq, lineage_actor)
               VALUES ('node','${probe:-wv-probe}',1,'identity-suite');" 2>/dev/null
tombstones=$(sqlite3 "$db" "SELECT count(*) FROM tombstones WHERE lineage_actor='identity-suite';" 2>/dev/null)
check "the tombstone probe was actually written" "1" "$tombstones"
differs "a tombstone-only change moves the identity" "$before_tombstone" "$(identity)"

# CUTOVER MARKER.
before_marker=$(identity)
printf 'lineage_seq=1\n' > "$WEAVE_DIR/causal-cutover"
after_marker=$(identity)
differs "a cutover-marker-only change moves the identity" "$before_marker" "$after_marker"
printf 'lineage_seq=2\n' > "$WEAVE_DIR/causal-cutover"
differs "editing the marker's contents moves the identity again" "$after_marker" "$(identity)"

# CUTOVER AUTHORIZATION MANIFEST. No writer exists yet (wv-7e17b9): what is
# pinned here is that absence is hashed as absence, so the file appearing is
# itself a change. Without this, authorization evidence could arrive, or be
# rewritten, under an unmoved identity.
before_manifest=$(identity)
printf '{"observed_frontiers":{}}\n' > "$WEAVE_DIR/cutover-authorization.json"
after_manifest=$(identity)
differs "an authorization-manifest-only change moves the identity" "$before_manifest" "$after_manifest"
printf '{"observed_frontiers":{"actor":1}}\n' > "$WEAVE_DIR/cutover-authorization.json"
differs "rewriting the manifest moves the identity again" "$after_manifest" "$(identity)"
rm -f "$WEAVE_DIR/cutover-authorization.json"
differs "removing the manifest moves the identity back off its present state" "$(identity)" "$after_manifest"

# DELTA-CATALOG FRONTIER. Paths are not enough: the repository calls deltas
# immutable and does not enforce it, so a frontier over paths alone stands still
# through an in-place rewrite -- the one delta mutation that should be loudest.
before_delta=$(identity)
mkdir -p "$WEAVE_DIR/deltas/2026-01-01"
probe_delta="$WEAVE_DIR/deltas/2026-01-01/1700000000-000000-probe.sql"
printf -- '-- probe\n' > "$probe_delta"
after_delta=$(identity)
differs "an arriving delta moves the identity" "$before_delta" "$after_delta"
printf -- '-- probe rewritten in place\n' > "$probe_delta"
rewritten=$(identity)
differs "rewriting a delta's contents at the same path moves the identity" "$after_delta" "$rewritten"
# Same byte length as the line before it, so a size-only signature would not see
# this either; only the content digest does.
printf -- '-- probe rewritten in placX\n' > "$probe_delta"
differs "a same-length rewrite moves the identity" "$rewritten" "$(identity)"
rm -f "$probe_delta"
differs "removing the delta moves the identity again" "$(identity)" "$rewritten"

# Staging directories are NOT part of the frontier. They are PID-scoped scratch
# no peer can see, and a sync that crashes or fails to publish between staging
# and rename leaves one behind. Hashing it made this machine's causal identity
# depend on that residue -- identity drift with no graph change behind it, and
# the reason a failed publication now discards its staging rather than keeping
# files no later process would come back for.
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "identity moved: $2 -> $3"; fi; }
before_staging=$(identity)
mkdir -p "$WEAVE_DIR/deltas/2026-01-01/.staging-99999/v2"
printf -- '-- staged, never published\n' > "$WEAVE_DIR/deltas/2026-01-01/.staging-99999/probe.sql"
printf '{"staged":true}' > "$WEAVE_DIR/deltas/2026-01-01/.staging-99999/v2/000000000001-op.json"
same "an unpublished staging directory does not move the identity" "$before_staging" "$(identity)"
rm -rf "$WEAVE_DIR/deltas/2026-01-01/.staging-99999"
same "removing an unpublished staging directory does not move it either" "$before_staging" "$(identity)"

# The digest is cached against a (path, size, mtime) signature. The cache must
# make an unchanged catalog cheap without making a changed one invisible.
cache="$WV_HOT_ZONE/delta-catalog-digest"
[ -s "$cache" ] && ok "the content digest is cached for an unchanged catalog" \
  || bad "the content digest is cached for an unchanged catalog" "no cache at $cache"
cached_before=$(cat "$cache")
"$WV" status >/dev/null 2>&1
check "an unchanged catalog reuses the cached digest" "$cached_before" "$(cat "$cache")"

# The hit path takes the file count from the entry instead of re-reading the
# listing (wv-78e154). A planted wrong count surfacing in the identity proves a
# hit really serves the entry; an entry in the older two-field form is a miss
# that is rewritten without moving the identity.
delta_sig="" delta_digest="" delta_count=""
read -r delta_sig delta_digest delta_count < "$cache" || true
[[ "${delta_count:-}" =~ ^[0-9]+$ ]] && ok "the delta cache entry records the file count" \
  || bad "the delta cache entry records the file count" "entry: $(cat "$cache")"
catalog_identity=$(identity)
printf '%s %s %s\n' "$delta_sig" "$delta_digest" 999 > "$cache"
differs "a matching signature serves the cached count" "$catalog_identity" "$(identity)"
printf '%s %s\n' "$delta_sig" "$delta_digest" > "$cache"
check "a two-field entry is recomputed to the same identity" "$catalog_identity" "$(identity)"
check "and rewritten with its count" "$delta_sig $delta_digest $delta_count" "$(cat "$cache")"

# ONE FRONTIER WALK FOR A CALL THAT CANNOT WRITE (wv-1b2a92). The walk stats
# every published delta and ran on both sides of every call. An observation
# command (status, show, list ...) never writes, so its after-identity reuses
# the frontier its before-identity saw; a mutation still walks on both sides,
# because its own write is what the after-identity must see. Counted from an
# xtrace of the wrapper: each call of the walk function is one walk.
walks() { PS4='+ ' bash -x "$WV" "$@" 2>&1 >/dev/null | grep -c '^+* _wv_identity_delta_frontier_line '; }
check "an observation command walks the delta catalog once" "1" "$(walks status)"
check "a mutation command walks it on both sides" "2" "$(walks add "frontier walk probe")"
# wv-2ddb44: the version tokens only echo, so they walk once; help still twice.
check "wv --version walks the delta catalog once" "1" "$(walks --version)"
check "wv help still walks it on both sides" "2" "$(walks help)"
truth=$(identity)
_WV_FRONTIER_LINE=$'delta_catalog_frontier\tpresent\t0\tsha256:planted' "$WV" status >/dev/null 2>&1
check "a frontier handed in through the environment is ignored" "$truth" \
  "$(tail -1 "$WV_CALL_LOG" | jq -r '.graph_identity_after.value')"
probe_reuse="$WEAVE_DIR/deltas/2026-01-02/1700000001-000000-reuse.sql"
mkdir -p "$(dirname "$probe_reuse")"; printf -- '-- reuse probe\n' > "$probe_reuse"
differs "the next observation call still sees a delta that arrived after the last one" "$truth" "$(identity)"
rm -f "$probe_reuse"

# AN IDENTITY CACHE NEVER CREATES THE HOT ZONE (wv-1b2a92). The delta-catalog
# cache once ran mkdir -p on its own directory, so under a 002 umask the first
# call to reach it made a group-writable zone that the hot-zone guard then
# refused for every later call. No directory a call creates may be writable by
# group or others, whatever the caller's umask. (Files inside take the umask;
# the zone directory's mode 700 is what keeps others out of them.)
fresh_zone="$TEST_DIR/fresh-zone/zone"
mkdir -p "$TEST_DIR/fresh-zone" && chmod 700 "$TEST_DIR/fresh-zone"
# The database stays where it is, so the identity is computed and its caches
# are written while the zone directory does not exist yet.
( umask 002; WV_HOT_ZONE="$fresh_zone" WV_DB="$db" "$WV" status >/dev/null 2>&1 )
loose=$(find "$TEST_DIR/fresh-zone" -type d -perm /022 -printf '%m %P\n' 2>/dev/null)
check "a call under umask 002 creates no group- or world-writable directory in its zone" "" "$loose"

# GRAPH-ROWS CACHE (wv-78e154). The row dump is reused while the database file
# is unchanged. A planted digest under a matching key shows that a hit serves
# the entry, so the write after it is what has to move the value back.
rows_cache="$WV_HOT_ZONE/graph-rows-digest"
rm -f "$rows_cache"
WV_IDENTITY_RACY_NS=0 "$WV" status >/dev/null 2>&1
rows_truth=$(tail -1 "$WV_CALL_LOG" | jq -r '.graph_identity_after.value')
rows_db="" rows_key="" rows_digest=""
IFS=$'\t' read -r rows_db rows_key rows_digest < "$rows_cache" 2>/dev/null || true
check "the rows cache names the database it describes" "$db" "$rows_db"
check "an unchanged graph keeps its value through the cache" "$rows_truth" "$(identity)"
printf '%s\t%s\t%064d\n' "$rows_db" "$rows_key" 0 > "$rows_cache"
planted=$(identity)
differs "a matching database key serves the cached digest" "$rows_truth" "$planted"
sqlite3 "$db" "UPDATE nodes SET text = text || ' (rows cache probe)' WHERE id = '${probe:-wv-probe}';"
after_write=$(identity)
rm -f "$rows_cache"
check "a graph write invalidates the cached digest" "$(identity)" "$after_write"
differs "and the value moved with the write" "$rows_truth" "$after_write"

# Racy-clean (as in git's index): file times move in coarse ticks, so a
# database written inside the margin is not stored, or a second write in the
# same tick would be served the first write's digest.
rm -f "$rows_cache"
sqlite3 "$db" "UPDATE nodes SET text = text || '.' WHERE id = '${probe:-wv-probe}';"
WV_IDENTITY_RACY_NS=60000000000 "$WV" status >/dev/null 2>&1
[ ! -e "$rows_cache" ] && ok "a database written inside the racy margin is not cached" \
  || bad "a database written inside the racy margin is not cached" "entry: $(cat "$rows_cache")"
WV_IDENTITY_RACY_NS=0 "$WV" status >/dev/null 2>&1
[ -s "$rows_cache" ] && ok "outside the margin it is" \
  || bad "outside the margin it is" "no cache at $rows_cache"

# ONE VALUE. The log line carries a single identity per side, not a set of
# per-component hashes -- the growing-ad-hoc-hash shape this replaced.
fields=$(tail -1 "$WV_CALL_LOG" | jq -r '[keys[] | select(test("identity|fingerprint"))] | sort | join(",")')
check "the call line carries exactly one identity per side" "graph_identity_after,graph_identity_before" "$fields"
covers=$(tail -1 "$WV_CALL_LOG" | jq -r '.graph_identity_after.covers | join(",")')
check "the identity declares what it covers" \
  "graph_rows,lineage,tombstones,cutover_marker,cutover_authorization_manifest,delta_catalog_frontier" "$covers"

# The private evidence programme recomputes this value in Python and compares it
# to call-log rows byte for byte when it admits a counted capture. That
# agreement is checked on live values in the private suite that owns the
# recomputation. It was checked here, which made a retained public suite import
# a package the release excludes, so the assertion could not run in the
# projection it shipped into.

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
