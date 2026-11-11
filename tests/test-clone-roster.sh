#!/usr/bin/env bash
# test-clone-roster.sh -- Stage B prerequisite 4 (wv-6e44d9) of
# docs/PROPOSAL-delta-retention.md: an operator-declared roster of clones,
# with catalog actors used only as evidence of writers. Owner rulings
# 2026-11-07: accounting is by declared coarse prefixes plus exact ids; the
# acknowledgement stays local (its publication is wv-bac5a7). Owner decision
# 4 (2026-11-05): 21 days unconfirmed is a warning only.
#
# Done criteria pinned here:
#   - an unaccounted catalog actor blocks compaction (check exits 1 and names it)
#   - 21-day staleness is a warning only, no expiry or retirement
#
# GIT_* is unset first: an exported GIT_DIR would point the scratch
# repositories at the real one (wv-8f1da6).

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
ROSTER="$REPO_ROOT/scripts/lib/wv-clone-roster.py"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_NONINTERACTIVE=1
export WV_SYNC_INTERVAL=0
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

TODAY=2026-11-07
H16=0123456789abcdef
W="$T/w/.weave"

# v2 ACTOR DAY NAME -- a v2 sidecar written by ACTOR.
v2() { mkdir -p "$W/deltas/$2/v2"; printf '{"format":"weave.delta.v2","actor_id":"%s"}\n' "$1" > "$W/deltas/$2/v2/$3.json"; }
# v1h ACTOR DAY NAME -- a v1 delta whose lineage header names ACTOR.
v1h() { mkdir -p "$W/deltas/$2"; printf 'BEGIN;\n/* weave-lineage seq=7 actor=%s */\nCOMMIT;\n' "$1" > "$W/deltas/$2/$3"; }
# v1n DAY NAME -- a v1 delta with no header; only its name can say who wrote it.
v1n() { mkdir -p "$W/deltas/$1"; printf 'BEGIN;\nCOMMIT;\n' > "$W/deltas/$1/$2"; }
# clone NAME LINE... -- write a roster file.
clone() { local n="$1"; shift; mkdir -p "$W/clones"; printf '%s\n' "$@" > "$W/clones/$n.roster"; }
# run_check -- check the fixture; sets rc, out, err.
run_check() {
    rc=0
    python3 "$ROSTER" check "$W" --today="$TODAY" >"$T/out" 2>"$T/err" || rc=$?
    out=$(cat "$T/out"); err=$(cat "$T/err")
}
fresh() { rm -rf "$T/w"; mkdir -p "$W/deltas"; }

# ── the catalog every accounting case uses ──────────────────────────────────
catalog() {
    fresh
    v2 "claude-host-me" 2026-11-01 a1
    v2 "claude-host-me-h$H16" 2026-11-01 a2
    v1h "claude-host-me-sAbC123" 2026-11-02 1-2-0-x-9.sql
    v1n 2026-11-02 1762000000-123-0-human-host-me-4242.sql
    v1n 2026-11-03 1700000000-human-host-me.sql
    v2 "gate-handoff" 2026-11-03 a3
}

echo "--- an unaccounted actor blocks ---"
catalog
run_check
check "no roster: refuses" test "$rc" -eq 1
check "...naming every writer in the catalog" test "$(grep -c '^unaccounted ' <<<"$out")" -eq 5
clone main "prefix claude-host-me" "confirmed $TODAY"
run_check
check "a roster that misses writers: refuses" test "$rc" -eq 1
check "...naming the exact id it lacks" grep -q '^unaccounted gate-handoff 1 deltas/2026-11-03/v2/a3.json$' <<<"$out"
check "...and the coarse actor read from a v1 filename" grep -q '^unaccounted human-host-me 2 ' <<<"$out"
check "...but not the declared prefix's session forms" bash -c "! grep -q 'claude-host-me' <<<'$out'"
clone main "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
run_check
check "every writer declared: passes" test "$rc" -eq 0 -a -z "$out"

echo "--- a prefix covers the actor and its session forms only ---"
for a in "claude-host-meX" "claude-host-me-h${H16}0" "claude-host-me-hXYZ" "claude-host-me-other" \
         "claude-host" "xclaude-host-me" "claude-host-me-s" "claude-host-me-sTOOLONG123456"; do
    catalog; v2 "$a" 2026-11-04 extra
    clone main "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
    run_check
    check "'$a' is not covered by prefix claude-host-me" grep -qxF -- "unaccounted $a 1 deltas/2026-11-04/v2/extra.json" <<<"$out"
done
catalog; v2 "gate-handoff-h$H16" 2026-11-04 extra
clone main "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
run_check
check "an exact id does not cover session forms" grep -qF -- "unaccounted gate-handoff-h$H16 " <<<"$out"
catalog
clone a "prefix claude-host-me" "confirmed $TODAY"
clone b "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
run_check
check "two clones may declare one prefix (two checkouts on a host)" test "$rc" -eq 0

echo "--- a delta whose writer cannot be read blocks ---"
catalog
clone main "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
v1n 2026-11-05 not-a-delta-name.sql
run_check
check "an unnamed headerless v1 file: refuses" test "$rc" -eq 1
check "...listing it as unattributed" grep -qx 'unattributed deltas/2026-11-05/not-a-delta-name.sql' <<<"$out"
catalog
clone main "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
mkdir -p "$W/deltas/2026-11-05/v2"; printf '{"truncated' > "$W/deltas/2026-11-05/v2/bad.json"
printf '{"format":"weave.delta.v2"}\n' > "$W/deltas/2026-11-05/v2/noactor.json"
run_check
check "a corrupt sidecar and one with no actor: both unattributed" \
    test "$rc" -eq 1 -a "$(grep -c '^unattributed ' <<<"$out")" -eq 2
catalog
clone main "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
mkdir -p "$W/deltas/2026-11-05/.staging-1/v2"; printf '{"actor_id":"ghost"}\n' > "$W/deltas/2026-11-05/.staging-1/v2/s.json"
printf 'x\n' > "$W/deltas/2026-11-05/notes.txt"
run_check
check "staging directories and non-delta files are not catalog" test "$rc" -eq 0
catalog
clone main "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
v1h "header-wins" 2026-11-05 1762000000-1-0-name-loses-1.sql
run_check
check "a v1 header outranks its filename" \
    test "$out" = "unaccounted header-wins 1 deltas/2026-11-05/1762000000-1-0-name-loses-1.sql"

echo "--- a malformed roster refuses to judge ---"
for case in "unknown:prefix claude-host-me|owner me|confirmed $TODAY" \
            "no-date:prefix claude-host-me" \
            "two-dates:prefix claude-host-me|confirmed $TODAY|confirmed $TODAY" \
            "bad-date:prefix claude-host-me|confirmed 2026-13-01" \
            "empty:confirmed $TODAY" \
            "three-words:prefix claude host|confirmed $TODAY"; do
    name="${case%%:*}"; IFS='|' read -r -a lines <<<"${case#*:}"
    catalog; clone main "${lines[@]}"
    run_check
    check "$name: exit 2, nothing judged" test "$rc" -eq 2 -a -z "$out"
done
catalog; clone main "prefix claude-host-me" "confirmed $TODAY"; cp "$W/clones/main.roster" "$W/clones/-bad.roster"
run_check
check "a bad clone name: exit 2" test "$rc" -eq 2
catalog; clone main "# the main checkout" "" "prefix claude-host-me" "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
printf 'ignored\n' > "$W/clones/README"
run_check
check "comments, blank lines and other files are ignored" test "$rc" -eq 0

echo "--- 21 days unconfirmed is a warning only ---"
all="prefix claude-host-me|prefix human-host-me|id gate-handoff"
catalog; IFS='|' read -r -a l <<<"$all"; clone main "${l[@]}" "confirmed 2026-10-18"
run_check
check "20 days: no warning" test "$rc" -eq 0 -a -z "$err"
clone main "${l[@]}" "confirmed 2026-10-17"
before=$(cat "$W/clones/main.roster")
run_check
check "21 days: warns, naming the clone and its age" grep -q "clone 'main' last confirmed 2026-10-17 (21 days)" <<<"$err"
check "...and still passes" test "$rc" -eq 0
check "...and the clone is not retired" test "$(cat "$W/clones/main.roster")" = "$before"
clone main "${l[@]}" "confirmed 2025-01-01"
run_check
check "a year: still a warning, still passes" test "$rc" -eq 0 -a -n "$err"
v2 undeclared 2026-11-06 late
run_check
check "a stale roster that misses a writer still refuses" test "$rc" -eq 1

echo "--- watermarks (prune policy wv-3937eb) ---"
wm() { rc=0; python3 "$ROSTER" watermark "$W" >"$T/out" 2>"$T/err" || rc=$?; out=$(cat "$T/out"); err=$(cat "$T/err"); }
fresh; rm -rf "$W/clones"
wm
check "no roster: exit 1, nothing may compact" test "$rc" -eq 1
catalog
clone a "prefix claude-host-me" "confirmed $TODAY" "watermark 120"
clone b "prefix human-host-me" "id gate-handoff" "confirmed $TODAY"
wm
check "a clone without a watermark: exit 1" test "$rc" -eq 1
check "...named on stdout" test "$out" = "unwatermarked b"
clone b "prefix human-host-me" "id gate-handoff" "confirmed $TODAY" "watermark 95"
wm
check "every clone watermarked: exit 0 and the lowest is printed" test "$rc" -eq 0 -a "$out" = "95"
run_check
check "the check still passes with watermark lines present" test "$rc" -eq 0
clone b "prefix human-host-me" "id gate-handoff" "confirmed $TODAY" "watermark 9x"
wm
check "a non-numeric watermark: exit 2" test "$rc" -eq 2
clone b "prefix human-host-me" "id gate-handoff" "confirmed $TODAY" "watermark 1" "watermark 2"
wm
check "two watermark lines: exit 2" test "$rc" -eq 2

echo "--- the census reads what the real writer emits ---"
R="$T/clone"; mkdir -p "$R"; cd "$R" || exit 1
export WV_PROJECT_DIR="$R" WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$R/.hot"; unset WV_DB
mkdir -p "$WV_HOT_ZONE"; chmod 700 "$WV_HOT_ZONE"
git init -q && git config user.email t@t && git config user.name t
WV_AGENT_ID=roster-real "$WV" init >/dev/null 2>&1
WV_AGENT_ID=roster-real "$WV" add "target" --criteria=c --risks=low >/dev/null 2>&1
WV_AGENT_ID=roster-real "$WV" sync >/dev/null 2>&1
census=$(python3 "$ROSTER" actors "$WEAVE_DIR")
check "v1 and v2 files from wv sync are both attributed to their actor" \
    bash -c "grep -Eq '^[0-9]+ roster-real$' <<<'$census' && ! grep -q unattributed <<<'$census' \
             && [ \$(sed -E 's/ .*//' <<<'$census') -ge 2 ]"
rc=0; python3 "$ROSTER" check "$WEAVE_DIR" >/dev/null 2>&1 || rc=$?
check "...and with no roster the real catalog refuses" test "$rc" -eq 1

echo ""
echo "$pass/$run passed"
[ "$pass" -eq "$run" ]
