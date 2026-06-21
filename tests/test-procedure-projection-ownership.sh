#!/usr/bin/env bash
# Projection ownership + contract-integrity gate (pre-S3):
#   - cross-file uniqueness of id and claude_skill (gen-procedures)
#   - status:draft never projects to any adapter
#   - managed Claude stale removal across claude/codex/copilot on demotion
#   - collision protection for hand-written skills
#   - resource copy semantics (non-executable resources are copied)
#   - Codex ownership: deleted/demoted managed entries pruned, manual preserved
#   - resources removed from a contract are reconciled out of the skill dir
#   - validate-before-mutate: unsafe paths / collisions / bad adapters rejected
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/scripts/gen-procedures.sh"
PROJECT="$ROOT/scripts/project-procedures.sh"
MARKER='WEAVE-MANAGED-SKILL'
TMP=$(mktemp -d)
trap 'cd /tmp; rm -rf "$TMP"' EXIT

mkproc() { # dir name adapters extra-lines...
    local dir="$1" name="$2" adapters="$3"; shift 3
    {
        printf '%s\n' '---' "id: $name" "description: $name proc" \
            "fallback: \"wv guide --procedure=$name\"" "adapters: $adapters"
        local line; for line in "$@"; do printf '%s\n' "$line"; done
        printf '%s\n' '---' "# $name body"
    } > "$dir/$name.md"
}

# --- A. cross-file uniqueness (gen-procedures) -------------------------------
A="$TMP/a"; mkdir -p "$A"
mkproc "$A" alpha '[codex]' 'visibility: shared'
mkproc "$A" beta '[codex]' 'visibility: shared'
"$GEN" --source="$A" --check >/dev/null    # unique -> passes

# duplicate id (two files declaring id: alpha)
sed -i 's/^id: beta/id: alpha/' "$A/beta.md"
if "$GEN" --source="$A" --check >/dev/null 2>&1; then echo "FAIL: duplicate id not rejected"; exit 1; fi
sed -i 's/^id: alpha/id: beta/' "$A/beta.md"

# duplicate claude_skill (distinct ids, same skill name)
mkproc "$A" alpha '[claude]' 'visibility: shared' 'claude_skill: shared-skill'
mkproc "$A" beta '[claude]' 'visibility: shared' 'claude_skill: shared-skill'
if "$GEN" --source="$A" --check >/dev/null 2>&1; then echo "FAIL: duplicate claude_skill not rejected"; exit 1; fi

# --- B. status:draft never projects -----------------------------------------
B="$TMP/b"; BREPO="$TMP/brepo"; mkdir -p "$B" "$BREPO"
mkproc "$B" draftproc '[claude, codex, copilot]' 'visibility: shared' 'status: draft' 'claude_skill: wv-draftproc'
bash "$PROJECT" --source="$B" --repo="$BREPO"
[ ! -e "$BREPO/.claude/skills/wv-draftproc" ] || { echo "FAIL: draft projected to claude"; exit 1; }
[ ! -e "$BREPO/.codex/weave.json" ] || [ "$(jq -r '[.procedures[]?.id] | index("draftproc")' "$BREPO/.codex/weave.json")" = "null" ] || { echo "FAIL: draft projected to codex"; exit 1; }
[ ! -e "$BREPO/.github/copilot-instructions.md" ] || ! grep -qF 'wv guide --procedure=draftproc' "$BREPO/.github/copilot-instructions.md" || { echo "FAIL: draft projected to copilot"; exit 1; }

# --- C. demotion stale removal across all three adapters ---------------------
C="$TMP/c"; CREPO="$TMP/crepo"; mkdir -p "$C" "$CREPO"
mkproc "$C" liveproc '[claude, codex, copilot]' 'visibility: shared' 'claude_skill: wv-liveproc'
bash "$PROJECT" --source="$C" --repo="$CREPO"
[ -f "$CREPO/.claude/skills/wv-liveproc/SKILL.md" ]
grep -qF "$MARKER" "$CREPO/.claude/skills/wv-liveproc/SKILL.md"   # generated skills carry the marker
[ "$(jq -r '[.procedures[].id] | index("liveproc")' "$CREPO/.codex/weave.json")" != "null" ]
grep -qF 'wv guide --procedure=liveproc' "$CREPO/.github/copilot-instructions.md"

# demote shared -> local and re-project: must disappear from every surface
mkproc "$C" liveproc '[claude, codex, copilot]' 'visibility: local' 'claude_skill: wv-liveproc'
bash "$PROJECT" --source="$C" --repo="$CREPO"
[ ! -e "$CREPO/.claude/skills/wv-liveproc" ] || { echo "FAIL: demoted claude skill not removed"; exit 1; }
[ "$(jq -r '[.procedures[].id] | index("liveproc")' "$CREPO/.codex/weave.json")" = "null" ] || { echo "FAIL: demoted codex entry not removed"; exit 1; }
! grep -qF 'wv guide --procedure=liveproc' "$CREPO/.github/copilot-instructions.md" || { echo "FAIL: demoted copilot line not removed"; exit 1; }

# --- D. collision protection: hand-written skill is never overwritten/removed --
D="$TMP/d"; DREPO="$TMP/drepo"; mkdir -p "$D" "$DREPO/.claude/skills/manual"
printf '%s\n' '---' 'name: manual' 'description: hand written' '---' '# do not touch' > "$DREPO/.claude/skills/manual/SKILL.md"
mkproc "$D" collide '[claude]' 'visibility: shared' 'claude_skill: manual'
if bash "$PROJECT" --source="$D" --repo="$DREPO" 2>/dev/null; then echo "FAIL: collision with hand-written skill not rejected"; exit 1; fi
grep -qF '# do not touch' "$DREPO/.claude/skills/manual/SKILL.md" || { echo "FAIL: hand-written skill body clobbered"; exit 1; }
# stale-removal must also leave the unmarked manual skill alone
DREPO2="$TMP/drepo2"; mkdir -p "$DREPO2/.claude/skills/manual"
printf '%s\n' '---' 'name: manual' '---' '# keep' > "$DREPO2/.claude/skills/manual/SKILL.md"
E2="$TMP/e2"; mkdir -p "$E2"   # no procedures map to 'manual'
mkproc "$E2" other '[codex]' 'visibility: shared'
bash "$PROJECT" --source="$E2" --repo="$DREPO2"
[ -f "$DREPO2/.claude/skills/manual/SKILL.md" ] || { echo "FAIL: stale-removal deleted a hand-written skill"; exit 1; }

# --- E. resource semantics: non-executable resource is copied ----------------
E="$TMP/e"; EREPO="$TMP/erepo"; mkdir -p "$E" "$EREPO"
printf '%s\n' 'reference data' > "$E/data.txt"
printf '%s\n' '#!/usr/bin/env bash' > "$E/run.sh"
{
    printf '%s\n' '---' 'id: withres' 'description: withres proc' \
        'fallback: "wv guide --procedure=withres"' 'adapters: [claude]' 'visibility: shared' \
        'claude_skill: wv-withres' 'resources:' \
        '  - path: data.txt' \
        '  - path: run.sh' '    executable: true' \
        '---' '# body'
} > "$E/withres.md"
bash "$PROJECT" --source="$E" --repo="$EREPO"
[ -f "$EREPO/.claude/skills/wv-withres/data.txt" ] || { echo "FAIL: non-executable resource not copied"; exit 1; }
[ ! -x "$EREPO/.claude/skills/wv-withres/data.txt" ] || { echo "FAIL: non-executable resource gained exec bit"; exit 1; }
[ -x "$EREPO/.claude/skills/wv-withres/run.sh" ] || { echo "FAIL: executable resource missing exec bit"; exit 1; }

# --- F. Codex ownership: deleted managed entry pruned, manual entry preserved -
F="$TMP/f"; FREPO="$TMP/frepo"; mkdir -p "$F" "$FREPO"
mkproc "$F" delproc '[codex]' 'visibility: shared'
bash "$PROJECT" --source="$F" --repo="$FREPO"
ftmp=$(mktemp)
jq '.procedures += [{id:"manualx",description:"hand-authored",fallback:"x"}]' "$FREPO/.codex/weave.json" > "$ftmp" && mv "$ftmp" "$FREPO/.codex/weave.json"
rm "$F/delproc.md"   # procedure deleted from canonical source
bash "$PROJECT" --source="$F" --repo="$FREPO"
[ "$(jq -r '[.procedures[].id] | index("delproc")' "$FREPO/.codex/weave.json")" = "null" ] || { echo "FAIL: deleted codex entry not pruned"; exit 1; }
[ "$(jq -r '[.procedures[].id] | index("manualx")' "$FREPO/.codex/weave.json")" != "null" ] || { echo "FAIL: manual codex entry not preserved"; exit 1; }

# --- G. Resources removed from a contract are reconciled out of the skill dir -
G="$TMP/g"; GREPO="$TMP/grepo"; mkdir -p "$G" "$GREPO"
printf 'keep\n' > "$G/keep.txt"; printf 'drop\n' > "$G/drop.txt"
gproc() { # resources-block-lines...
    { printf '%s\n' '---' 'id: gres' 'description: gres proc' 'fallback: "wv guide --procedure=gres"' \
        'adapters: [claude]' 'visibility: shared' 'claude_skill: wv-gres' 'resources:'; printf '%s\n' "$@"; printf '%s\n' '---' '# body'; } > "$G/gres.md"
}
gproc '  - path: keep.txt' '  - path: drop.txt'
bash "$PROJECT" --source="$G" --repo="$GREPO"
[ -f "$GREPO/.claude/skills/wv-gres/drop.txt" ] || { echo "FAIL: resource not copied on first projection"; exit 1; }
gproc '  - path: keep.txt'   # drop.txt removed from contract
bash "$PROJECT" --source="$G" --repo="$GREPO"
[ -f "$GREPO/.claude/skills/wv-gres/keep.txt" ] || { echo "FAIL: kept resource missing after update"; exit 1; }
[ ! -e "$GREPO/.claude/skills/wv-gres/drop.txt" ] || { echo "FAIL: removed resource not reconciled out"; exit 1; }

# --- H. validate-before-mutate: unsafe path is rejected (no projection) -------
H="$TMP/h"; HREPO="$TMP/hrepo"; mkdir -p "$H" "$HREPO"
printf '%s\n' '---' 'id: hres' 'description: hres' 'fallback: "wv guide --procedure=hres"' \
    'adapters: [claude]' 'visibility: shared' 'claude_skill: wv-hres' 'resources:' '  - path: ../escape.sh' '---' '# body' > "$H/hres.md"
if bash "$PROJECT" --source="$H" --repo="$HREPO" 2>/dev/null; then echo "FAIL: traversal resource path not rejected"; exit 1; fi

# --- I. basename collision across resources is rejected ----------------------
I="$TMP/i"; IREPO="$TMP/irepo"; mkdir -p "$I/a" "$I/b" "$IREPO"
printf 'x\n' > "$I/a/dup.txt"; printf 'y\n' > "$I/b/dup.txt"
printf '%s\n' '---' 'id: ires' 'description: ires' 'fallback: "wv guide --procedure=ires"' \
    'adapters: [claude]' 'visibility: shared' 'claude_skill: wv-ires' 'resources:' '  - path: a/dup.txt' '  - path: b/dup.txt' '---' '# body' > "$I/ires.md"
if bash "$PROJECT" --source="$I" --repo="$IREPO" 2>/dev/null; then echo "FAIL: basename collision not rejected"; exit 1; fi

# --- J. unknown adapter name is rejected (exact allowlist, no substring) ------
J="$TMP/j"; JREPO="$TMP/jrepo"; mkdir -p "$J" "$JREPO"
mkproc "$J" jres '[notcodex]' 'visibility: shared'
if bash "$PROJECT" --source="$J" --repo="$JREPO" 2>/dev/null; then echo "FAIL: unknown adapter 'notcodex' not rejected"; exit 1; fi

# --- K. Codex same-id collision: manual entry must never be adopted silently --
K="$TMP/k"; KREPO="$TMP/krepo"; mkdir -p "$K" "$KREPO/.codex"
mkproc "$K" owned '[codex]' 'visibility: shared'
printf '%s\n' '{"schema":"weave.codex.v1","procedures":[{"id":"owned","description":"manual","fallback":"manual"}]}' > "$KREPO/.codex/weave.json"
if bash "$PROJECT" --source="$K" --repo="$KREPO" 2>/dev/null; then echo "FAIL: same-id manual Codex entry was adopted"; exit 1; fi
[ "$(jq -r '.procedures[0].fallback' "$KREPO/.codex/weave.json")" = manual ] || { echo "FAIL: manual Codex entry changed"; exit 1; }

# --- L. Resource sub-schema: malformed item and executable value fail ---------
L="$TMP/l"; mkdir -p "$L"
printf '%s\n' '---' 'id: malformed' 'description: malformed' 'fallback: "wv guide --procedure=malformed"' \
    'adapters: [claude]' 'visibility: shared' 'claude_skill: wv-malformed' 'resources:' '  - bogus: data.txt' '---' '# body' > "$L/malformed.md"
if "$GEN" --source="$L" --check >/dev/null 2>&1; then echo "FAIL: malformed resource item accepted"; exit 1; fi
printf '%s\n' 'data' > "$L/data.txt"
printf '%s\n' '---' 'id: malformed' 'description: malformed' 'fallback: "wv guide --procedure=malformed"' \
    'adapters: [claude]' 'visibility: shared' 'claude_skill: wv-malformed' 'resources:' '  - path: data.txt' '    executable: maybe' '---' '# body' > "$L/malformed.md"
if "$GEN" --source="$L" --check >/dev/null 2>&1; then echo "FAIL: non-boolean executable accepted"; exit 1; fi

# --- M. Empty/nested adapter/resource contracts are rejected ------------------
M="$TMP/m"; mkdir -p "$M/sub"
printf '%s\n' 'nested' > "$M/sub/data.txt"
printf '%s\n' '---' 'id: emptyadapters' 'description: empty adapters' 'fallback: "wv guide --procedure=emptyadapters"' \
    'adapters: []' 'visibility: shared' '---' '# body' > "$M/empty.md"
if "$GEN" --source="$M" --check >/dev/null 2>&1; then echo "FAIL: empty adapters accepted"; exit 1; fi
printf '%s\n' '---' 'id: nestedresource' 'description: nested resource' 'fallback: "wv guide --procedure=nestedresource"' \
    'adapters: [claude]' 'visibility: shared' 'claude_skill: wv-nested' 'resources:' '  - path: sub/data.txt' '---' '# body' > "$M/nested.md"
rm "$M/empty.md"
if "$GEN" --source="$M" --check >/dev/null 2>&1; then echo "FAIL: nested resource accepted"; exit 1; fi

# --- N. Full-set preflight: later collision leaves earlier procedure untouched -
N="$TMP/n"; NREPO="$TMP/nrepo"; mkdir -p "$N" "$NREPO/.claude/skills/manual"
mkproc "$N" first '[claude]' 'visibility: shared' 'claude_skill: wv-first'
mkproc "$N" second '[claude]' 'visibility: shared' 'claude_skill: manual'
printf '%s\n' '---' 'name: manual' '---' '# hand written' > "$NREPO/.claude/skills/manual/SKILL.md"
if bash "$PROJECT" --source="$N" --repo="$NREPO" 2>/dev/null; then echo "FAIL: late collision accepted"; exit 1; fi
[ ! -e "$NREPO/.claude/skills/wv-first" ] || { echo "FAIL: earlier procedure mutated before late collision"; exit 1; }

echo 'Results: 28/28 passed'
