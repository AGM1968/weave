#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv --version must identify the BUILD, not just the release tag.
#
# The tag cannot tell two installs apart. This machine and the gpu box both
# reported 1.71.0-rc.12 while running different persistence code, 72 commits
# apart, and nothing on either side could reveal it (wv-84447f). install.sh has
# recorded the source commit and `git describe` since 274974d2d; until now only
# wv doctor read it, so the question "which build is this?" had no cheap answer.
#
# The fixtures below encode that divergence directly: two installs whose VERSION
# is byte-identical and whose describe differs.
#
# wv_install_provenance_file / wv_build_identity are sourced from wv-config.sh
# rather than driven through the CLI: pointing WV_LIB_DIR at a fixture breaks
# the binary outright, because it sources its command modules from there.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

echo "build identity in wv --version"

TEST_DIR=$(mktemp -d /tmp/wv-build-id-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

# Two installs, same release tag, different source commits — the real shape.
make_install() {
    local name="$1" describe="$2" commit="$3" dirty="${4:-false}"
    mkdir -p "$TEST_DIR/$name/lib"
    echo "1.71.0-rc.12" > "$TEST_DIR/$name/lib/VERSION"
    {
        echo "installed_at=2026-09-18T00:00:00Z"
        echo "source_path=/some/checkout"
        echo "commit=$commit"
        echo "describe=$describe"
        echo "branch=main"
        echo "dirty=$dirty"
    } > "$TEST_DIR/$name/lib/INSTALL_PROVENANCE"
}

# identity <install-name> — build identity as the helper reports it.
identity() {
    ( WV_LIB_DIR="$TEST_DIR/$1" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
wv_build_identity 2>/dev/null || echo '<none>'
" )
}
tag() {
    ( WV_LIB_DIR="$TEST_DIR/$1" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
printf '%s' \"\$WV_VERSION\"
" )
}

make_install laptop "v1.71.0-rc.12-72-g9dd266526" "9dd266526cb22848c4518421be0ec76a3e1ce2e0"
make_install gpu    "v1.71.0-rc.12"               "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"

laptop_tag=$(tag laptop); gpu_tag=$(tag gpu)
laptop_id=$(identity laptop); gpu_id=$(identity gpu)

check "both installs report the same release tag" "$laptop_tag" "$gpu_tag"
check "the shared tag is the one from the real divergence" "1.71.0-rc.12" "$laptop_tag"

if [ "$laptop_id" != "$gpu_id" ]; then
    ok "two installs from different commits are distinguishable ($laptop_id vs $gpu_id)"
else
    bad "two installs from different commits are distinguishable" "both reported [$laptop_id]"
fi
check "the build identity carries the source commit" \
    "v1.71.0-rc.12-72-g9dd266526" "$laptop_id"

# ── a dirty install says so ───────────────────────────────────────────────────

make_install scratch "v1.71.0-rc.12-72-g9dd266526-dirty" "9dd266526cb22848c4518421be0ec76a3e1ce2e0" true
if grep -q -- "-dirty" <<<"$(identity scratch)"; then
    ok "a build from a dirty tree is marked dirty"
else
    bad "a build from a dirty tree is marked dirty" "got [$(identity scratch)]"
fi

# ── absent or unknown provenance degrades, it does not fail ───────────────────

mkdir -p "$TEST_DIR/bare/lib"
echo "1.71.0-rc.12" > "$TEST_DIR/bare/lib/VERSION"
check "an install with no provenance reports no build" "<none>" "$(identity bare)"

make_install unknowns "unknown" "unknown"
check "a provenance recording 'unknown' is treated as no build" "<none>" "$(identity unknowns)"

# ── the real binary keeps the parseable prefix ────────────────────────────────

real_out=$("$ROOT/scripts/wv" --version 2>/dev/null)
if grep -qE "^wv [0-9]" <<<"$real_out"; then
    ok "the first two fields stay 'wv <version>' for anything parsing them"
else
    bad "the first two fields stay 'wv <version>' for anything parsing them" "got [$real_out]"
fi
check "the running binary reports its own release tag" \
    "$(cat "$ROOT/scripts/lib/VERSION" | tr -d '[:space:]')" "$(awk '{print $2}' <<<"$real_out")"

# The E5 preflight parses this line into a release token it matches against a
# declared one; when the build suffix arrived it parsed the whole line and every
# preflight failed (wv-a9cccf). That suite takes ~12 minutes and no change to
# scripts/wv or wv-config.sh selects it, so the parse is pinned here (wv-0dfeb6).
# A checkout's wv reads provenance from $HOME's install, so the fixture HOME
# carries one: without it the line has no build suffix and the old parse passes.
mkdir -p "$TEST_DIR/home/.local/lib/weave/lib"
cp "$TEST_DIR/laptop/lib/INSTALL_PROVENANCE" "$TEST_DIR/home/.local/lib/weave/lib/"
e5_line=$(HOME="$TEST_DIR/home" "$ROOT/scripts/wv" --version 2>/dev/null)
check "the fixture install gives the real --version line a build suffix" "yes" \
    "$(grep -q ' (build v1.71.0-rc.12-72-g9dd266526)$' <<<"$e5_line" && echo yes || echo "no: $e5_line")"
# The E5 runner does not ship, so neither does this check (wv-43d08d).

# ── doctor and --version resolve the SAME install ─────────────────────────────
#
# Two independent resolutions could describe different installs, which is the
# failure this node is about one level up. Pinned structurally: doctor must use
# the shared helper rather than rebuilding the path.

ops="$ROOT/scripts/cmd/wv-cmd-doctor.sh"
if grep -q "wv_install_provenance_file" "$ops"; then
    ok "doctor resolves provenance through the shared helper"
else
    bad "doctor resolves provenance through the shared helper" "no call in wv-cmd-doctor.sh"
fi
if grep -qE '_prov_dir=.*WV_LIB_DIR' "$ops"; then
    bad "doctor no longer rebuilds the provenance path itself" "found a local _prov_dir resolution"
else
    ok "doctor no longer rebuilds the provenance path itself"
fi

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
