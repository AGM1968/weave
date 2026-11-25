#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-gate-zone-guard.sh — the gate fails a suite that leaks into the live hot
# zone (wv-e200f6).
#
# Two suites ran wv in temporary repositories with default placement, so each
# run left a per-repository directory in the LIVE hot zone, owned by a
# repository the suite's trap had already deleted. The gate pool
# (scripts/lib/wv-gate-pool.sh) now lists the live zones before its suites run
# and fails on any directory that appeared and belongs to a temporary or
# vanished repository.
#
# The "live" zones here sit under WV_TEST_HOT_ZONE_ROOT (WV_TEST_MODE=1), which
# both the resolver and the guard honour, so nothing touches the real zone.
#
# Covers:
#   - a suite that runs wv init in a temp repo without isolation fails the gate,
#     which names the directory, its owner and the suites it ran
#   - a suite that isolates its hot zone passes, and the gate stays silent
#   - a real repository (outside the temp dir, still present) opening its zone
#     during the run is not reported
#   - wv init alone in a temp repository is caught too: init stamps the owner
#     from the working directory's git toplevel (wv-29e416)
#   - a zone with no recorded owner (wv init outside any repository) is not
#     judged (wv-db641c)
#   - the guard reads only the test root's zones, never the real ones
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain [$2], got [$3]"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "did not expect [$2] in [$3]"; fi; }

# Canonical from the start: the guard reports owners by their physical path,
# and macOS /tmp is a link into /private (wv-e6ca42).
T=$(mktemp -d /tmp/wv-gate-zone-guard-XXXXXX); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
uid=$(id -u)

# A fake checkout holding the suites the pool runs, a stub wv for the pool's
# ledger calls, and the zones the guard treats as live.
FAKE="$T/checkout"; mkdir -p "$FAKE/tests" "$T/tmpdir" "$T/zones/tmp"
# On macOS a hot zone lives under $TMPDIR, and the pool gives each suite a
# private TMPDIR, so a suite that keeps it cannot reach the live zone at all;
# the leak the guard watches there is a suite that points TMPDIR back at the
# gate's own. The fixtures that stand for live-zone writers do that on darwin;
# on Linux the line is empty (wv-19572f).
LIVE_TMP=""
case "${OSTYPE:-}" in darwin*) LIVE_TMP="export TMPDIR=\"$T/tmpdir\"" ;; esac
git -C "$FAKE" init -q
cat > "$T/wv-stub" <<'STUB'
#!/usr/bin/env bash
# test-status: never reuse (exit 1), so every suite runs; test-record: accept.
case "$1" in test-status) exit 1 ;; *) exit 0 ;; esac
STUB
chmod +x "$T/wv-stub"

# leaky: a temp repository, wv init and a later command with default
# placement (the later command stamps the zone's owner, as in both leaking
# suites), then the repository removed by the suite's own cleanup.
cat > "$FAKE/tests/leaky.sh" <<EOF
export WV_TEST_HOT_ZONE_ROOT="$T/zones"
$LIVE_TMP
r=\$(mktemp -d "\${TMPDIR:-/tmp}/wvz.XXXXXX")/repo; mkdir -p "\$r"; git -C "\$r" init -q
(cd "\$r" && WV_CONFIG_DIR="\$r/../cfg" "$ROOT/scripts/wv" init >/dev/null 2>&1)
(cd "\$r" && WV_CONFIG_DIR="\$r/../cfg" "$ROOT/scripts/wv" status >/dev/null 2>&1)
rm -rf "\${r%/repo}"
EOF
# init-only: the same leak without a later command. wv init now records the
# owner itself from the git toplevel (wv-29e416), so this is caught as well.
cat > "$FAKE/tests/init-only.sh" <<EOF
export WV_TEST_HOT_ZONE_ROOT="$T/zones"
$LIVE_TMP
r=\$(mktemp -d "\${TMPDIR:-/tmp}/wvz.XXXXXX")/repo; mkdir -p "\$r"; git -C "\$r" init -q
(cd "\$r" && WV_CONFIG_DIR="\$r/../cfg" "$ROOT/scripts/wv" init >/dev/null 2>&1)
rm -rf "\${r%/repo}"
EOF
# no-repo: wv init from a directory outside any repository names no owner,
# so the zone stays unstamped and is not judged (wv-db641c).
cat > "$FAKE/tests/no-repo.sh" <<EOF
export WV_TEST_HOT_ZONE_ROOT="$T/zones"
$LIVE_TMP
r=\$(mktemp -d "\${TMPDIR:-/tmp}/wvz.XXXXXX")/scratch; mkdir -p "\$r"
(cd "\$r" && WV_CONFIG_DIR="\$r/../cfg" "$ROOT/scripts/wv" init >/dev/null 2>&1)
rm -rf "\${r%/scratch}"
EOF
# isolated: the same, with its hot zone under its own temp directory.
cat > "$FAKE/tests/isolated.sh" <<EOF
d=\$(mktemp -d "\${TMPDIR:-/tmp}/wvz.XXXXXX"); r="\$d/repo"; mkdir -p "\$r"; git -C "\$r" init -q
(cd "\$r" && WV_CONFIG_DIR="\$d/cfg" WV_TEST_HOT_ZONE_ROOT="\$d/zones" "$ROOT/scripts/wv" init >/dev/null 2>&1)
rm -rf "\$d"
EOF
# holder: a sibling pool's suite (wv-7061a0). It makes a temp repository's
# zone, says so, and holds it until released, then removes both, as
# test-budget-location.sh did while another lane's guard read its zones.
# Its hold bound is minutes, not seconds: under a loaded gate (four lanes on
# four slots) this pool's own run outlasted a 60 s hold, and the sibling's
# zone was gone before the precondition looked.
cat > "$FAKE/tests/holder.sh" <<EOF
export WV_TEST_HOT_ZONE_ROOT="$T/zones"
$LIVE_TMP
d=\$(mktemp -d "\${TMPDIR:-/tmp}/wvz.XXXXXX"); r="\$d/repo"; mkdir -p "\$r"; git -C "\$r" init -q
(cd "\$r" && WV_CONFIG_DIR="\$d/cfg" "$ROOT/scripts/wv" init >/dev/null 2>&1)
(cd "\$r" && WV_CONFIG_DIR="\$d/cfg" "$ROOT/scripts/wv" status >/dev/null 2>&1)
z=\$(cd "\$r" && WV_CONFIG_DIR="\$d/cfg" "$ROOT/scripts/wv" hotzone db 2>/dev/null); z=\${z%/*}
printf '%s\n' "\$z" > "$T/held.tmp" && mv "$T/held.tmp" "$T/held"
n=0; while [ ! -f "$T/release" ] && [ \$n -lt 6000 ]; do sleep 0.1; n=\$((n + 1)); done
rm -rf "\$d" "\$z"
EOF
# waiter: this pool's suite, which runs while the sibling's zone is held.
cat > "$FAKE/tests/waiter.sh" <<EOF
n=0; while [ ! -f "$T/held" ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done
[ -f "$T/held" ]
EOF
# untagged: a temp repository's orphan made outside any gate pool, as another
# session's suites would make one: no pool tag reaches its wv.
cat > "$FAKE/tests/untagged.sh" <<EOF
export WV_TEST_HOT_ZONE_ROOT="$T/zones"
$LIVE_TMP
r=\$(mktemp -d "\${TMPDIR:-/tmp}/wvz.XXXXXX")/repo; mkdir -p "\$r"; git -C "\$r" init -q
(cd "\$r" && env -u WV_GATE_POOL_TAG WV_CONFIG_DIR="\$r/../cfg" "$ROOT/scripts/wv" init >/dev/null 2>&1)
rm -rf "\${r%/repo}"
EOF
# real: a repository outside the temp directory that stays, opening its zone.
REAL="$T/real-repo"; mkdir -p "$REAL"; git -C "$REAL" init -q
cat > "$FAKE/tests/real.sh" <<EOF
export WV_TEST_HOT_ZONE_ROOT="$T/zones"
$LIVE_TMP
(cd "$REAL" && WV_CONFIG_DIR="$T/real-cfg" "$ROOT/scripts/wv" init >/dev/null 2>&1)
(cd "$REAL" && WV_CONFIG_DIR="$T/real-cfg" "$ROOT/scripts/wv" status >/dev/null 2>&1)
EOF

# gate <suite>... — run the real pool on the suites; prints stderr then rc=.
gate() {
    local lines="" i=0 s
    for s in "$@"; do lines+="$i"$'\t'"tests/$s"$'\t'"1"$'\n'; i=$((i + 1)); done
    (
        export WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$T/zones" TMPDIR="$T/tmpdir"
        export REPO_ROOT="$FAKE" WV="$T/wv-stub" WV_GATE_JOBS=1
        hook_progress() { :; }
        hook_duration_ms() { echo 0; }
        # shellcheck source=/dev/null
        source "$ROOT/scripts/lib/wv-gate-pool.sh"
        git -C "$FAKE" add tests
        export WV_GATE_TREE=$(git -C "$FAKE" write-tree)
        unset WV_GATE_BASE
        run_hook_suites <<< "$lines"
    ) 2>&1
    echo "rc=$?"
}

# The per-repository zone directories under the test root: <root>/tmp/weave-*/<hash>
# on Linux, <root>$TMPDIR/weave-<uid>/<hash> on macOS (wv-19572f).
zone_dirs() {
    case "${OSTYPE:-}" in
        darwin*) find "$T/zones$T/tmpdir/weave-$uid" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort ;;
        *) find "$T/zones" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort ;;
    esac
}
# real_owned_here — real-zone directories whose owner is under this test's temp
# directory: other processes on the host may add their own meanwhile.
real_owned_here() {
    local d
    for d in /tmp/weave-codex-"$uid"/*/ /tmp/weave-hotzone-"$uid"/*/; do
        [ -f "$d.repo_root" ] || continue
        [[ "$(cat "$d.repo_root" 2>/dev/null)" == "$T"/* ]] && printf '%s\n' "$d"
    done
}

echo "== a suite that leaks into the live zone fails the gate"
out=$(gate leaky.sh)
has "the gate fails" "rc=1" "$out"
has "and says a suite left directories in the live zone" "left hot-zone directories in the LIVE zone (wv-e200f6)" "$out"
mapfile -t found < <(zone_dirs)
leaked="${found[0]:-}"
check "the leak happened in the test root" "1" "$(zone_dirs | wc -l | tr -d ' ')"
has "the directory is named" "${leaked##*/}" "$out"
has "with the vanished temp owner" "(owner $T/tmpdir/" "$out"
has "and the suites the gate ran" "(tests/leaky.sh)" "$out"
has "and how to fix it" "WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT=<its temp dir>" "$out"
_zg_tag=$(cat "$leaked/.gate_pool" 2>/dev/null)
check "the orphan carries the pool's tag, so it is judged as this pool's own (wv-7061a0)" "yes" \
    "$([[ "$_zg_tag" == wv-gate.*-* ]] && echo yes || echo "no: [$_zg_tag]")"

echo "== a sibling pool's in-flight zone does not fail this pool (wv-7061a0)"
rm -f "$T/held" "$T/release"
gate holder.sh > "$T/sibling.out" 2>&1 &
_zg_sib=$!
# The sibling must hold its zone before this pool starts; under load its pool
# took longer than the waiter's own 60 s wait, which then failed this pool
# for want of a precondition, not a defect (lane of wv-58b10e, 2026-11-05).
n=0; while [ ! -f "$T/held" ] && kill -0 "$_zg_sib" 2>/dev/null && [ $n -lt 6000 ]; do sleep 0.1; n=$((n + 1)); done
out=$(gate waiter.sh)
check "(precondition) the sibling's zone was live, its owner present, while this pool ran" "present present" \
    "$(z=$(cat "$T/held" 2>/dev/null); [ -n "$z" ] && [ -d "$z" ] && echo present || echo absent) $(z=$(cat "$T/held" 2>/dev/null); o=$(cat "$z/.repo_root" 2>/dev/null); [ -n "$o" ] && [ -d "$o" ] && echo present || echo absent)"
check "this pool passes" "rc=0" "${out##*$'\n'}"
lacks "without reporting the sibling's zone" "LIVE zone" "$out"
touch "$T/release"; wait "$_zg_sib"
check "and the sibling, which removed its own zone, passes too" "rc=0" "$(tail -1 "$T/sibling.out")"

echo "== an orphan from outside any gate pool is reported, not counted (wv-7061a0)"
out=$(gate untagged.sh)
check "the gate passes" "rc=0" "${out##*$'\n'}"
has "and names it as made outside any gate pool" "made outside any gate pool (no pool tag)" "$out"
lacks "without calling it this pool's leak" "left hot-zone directories in the LIVE zone" "$out"

echo "== an isolated suite passes, silently"
out=$(gate isolated.sh)
check "the gate passes" "rc=0" "${out##*$'\n'}"
lacks "and reports no leak" "LIVE zone" "$out"

echo "== a real repository opening its zone meanwhile is not a leak"
before=$(zone_dirs | wc -l | tr -d ' ')
out=$(gate real.sh)
check "its zone appeared" "$((before + 1))" "$(zone_dirs | wc -l | tr -d ' ')"
check "and the gate passes" "rc=0" "${out##*$'\n'}"
lacks "without reporting it" "LIVE zone" "$out"

echo "== wv init alone in a temp repository is caught (wv-29e416)"
zones_before=$(zone_dirs)
out=$(gate init-only.sh)
mapfile -t added < <(comm -13 <(printf '%s\n' "$zones_before") <(zone_dirs))
check "its zone appeared" "1" "${#added[@]}"
has "the gate fails" "rc=1" "$out"
_added0="${added[0]:-/none-appeared}"  # no zone appeared fails the check above, not set -u here
has "naming the directory" "${_added0##*/}" "$out"
has "with the vanished temp owner init recorded" "(owner $T/tmpdir/" "$out"

echo "== a zone with no recorded owner is not judged (wv-db641c)"
zones_before=$(zone_dirs)
out=$(gate no-repo.sh)
mapfile -t added < <(comm -13 <(printf '%s\n' "$zones_before") <(zone_dirs))
check "its zone appeared" "1" "${#added[@]}"
check "with no owner recorded" "absent" "$([ -e "${added[0]:-/nonexistent}/.repo_root" ] && echo present || echo absent)"
check "and the gate passes" "rc=0" "${out##*$'\n'}"

echo "== the real live zone is untouched"
check "no directory in the real /tmp zone belongs to this test" "" "$(real_owned_here)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && echo "All tests passed" || { echo "FAILED"; exit 1; }
