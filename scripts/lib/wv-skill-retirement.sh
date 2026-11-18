#!/bin/bash
# wv-skill-retirement.sh — the one list of skills Weave has retired, and the
# content-addressed test that tells Weave's own copy of a skill from a user's
# (wv-853052, wv-ef7ad7).
#
# A retired skill stops being delivered, but a copy already placed stays: in
# CONFIG_DIR/skills (install.sh prunes it) and in every consumer's
# .claude/skills (wv-init-repo removes it). Either copy is a second, stale
# source of rules that now live in a procedure. A copy is removed only when its
# bytes match a version Weave shipped under that same name; an edited copy, an
# unknown one, or a missing provenance list is kept and reported (fail closed).
#
# Add a name here in the same commit that removes the skill's source.
# Defines data and functions only: no exports, no other sources.

# name              retired by   where its rules went
WV_RETIRED_SKILLS=(
    breadcrumbs     # wv-d231af  renamed to trails (agent-memory procedure)
    epic-breakdown  # consolidation, before the manifest; epic-decompose procedure
    prove-it        # consolidation, before the manifest; verify-before-fixed procedure
    rubber-duck     # consolidation, before the manifest
    stay-in-lane    # consolidation, before the manifest; wv-guard-scope
    unstuck         # consolidation, before the manifest; wv-detect-loop, now session
    ship-it         # wv-e0cbe3  folded into quality-gate (wv-verify-complete)
    resolve-refs    # wv-631bb6  folded into code-search (zero-in)
    sanity-check    # wv-262d14  folded into blindspot-pass (plan assumptions step)
    wv-detect-loop  # wv-65e21a  folded into session (Break a Retry Loop, limit of two)
    fix-issue       # wv-1fc64f  phase gates moved into the WORKFLOW Work Loop
)

# wv_skill_shipped_copy <skill name> <SKILL.md> <provenance file> — 0 when the
# file is byte-identical to a version Weave shipped under that name. The
# provenance file lists "<sha256> <name>" (gen-skill-provenance.sh).
wv_skill_shipped_copy() {
    local name="$1" file="$2" provenance="$3" sha
    [ -n "$provenance" ] && [ -f "$provenance" ] || return 1
    sha=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1) || return 1
    [ -n "$sha" ] && grep -qxF -- "$sha $name" "$provenance"
}

# wv_retire_skill_copies <skills dir> <provenance file> — remove each retired
# skill under <skills dir> whose SKILL.md is a shipped copy; keep and report any
# other. A directory holding files besides SKILL.md loses only SKILL.md and is
# reported, since the rest is not Weave's to delete. Prints one line per skill
# it finds; returns 0.
wv_retire_skill_copies() {
    local dir="$1" provenance="$2" name skill_md rest
    for name in "${WV_RETIRED_SKILLS[@]}"; do
        skill_md="$dir/$name/SKILL.md"
        [ -f "$skill_md" ] || continue
        if ! wv_skill_shipped_copy "$name" "$skill_md" "$provenance"; then
            if [ -n "$provenance" ] && [ -f "$provenance" ]; then
                echo "  ⚠ $name: retired skill kept - its SKILL.md differs from every version Weave shipped; review and remove it"
            else
                echo "  ⚠ $name: retired skill kept - no skill provenance list to prove it is Weave's copy (run wv self-update)"
            fi
            continue
        fi
        rm -f "$skill_md"
        rest=$(find "$dir/$name" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)
        if [ -z "$rest" ]; then
            rmdir "$dir/$name" 2>/dev/null || true
            echo "  ✓ $name: retired skill removed (an unedited Weave copy)"
        else
            echo "  ⚠ $name: retired SKILL.md removed; other files left in $dir/$name"
        fi
    done
    return 0
}
