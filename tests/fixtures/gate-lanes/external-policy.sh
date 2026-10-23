#!/usr/bin/env bash
# Sourced by test-gate-lanes.sh inside its private synthetic repository.
# These files are created here, not read from the checkout or release. Keep
# their real gate-role names: the hook's external callers dispatch by path.

echo "external candidate lanes keep the other external enforcement at HEAD"
reset_all
mkdir -p tests/lib
cat > tests/test-memory-projection-parity.sh <<EXTERNAL_EOF
#!/usr/bin/env bash
set -eu
# The pool may also select this file as a suite; observe only the hook call.
[ "\${1:-}" = --fixture-policy ] || exit 0
policy=\$(cat "\$(dirname "\${BASH_SOURCE[0]}")/lib/release-leak-pattern.ere")
printf '%s:checker-base\\n' "\$policy" >> "$MARK/external"
EXTERNAL_EOF
printf 'policy-base\n' > tests/lib/release-leak-pattern.ere
jq '.enforcement += ["tests/test-memory-projection-parity.sh", "tests/lib/release-leak-pattern.ere"]
    | .invoking += ["tests/test-memory-projection-parity.sh", "tests/lib/release-leak-pattern.ere"]' \
    "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
# shellcheck disable=SC2016  # execute beside the protected hook, not REPO_ROOT
printf '%s\n' 'bash "$_PC_SCRIPTS/../tests/test-memory-projection-parity.sh" --fixture-policy || exit 1' > "$T/snip"
into_hook "$T/snip"
commit_nohook "fixture declares external enforcement"
stage_src; gate
check "(control) unchanged external enforcement admits a product edit" "0" "$RC"
check "...using the baseline checker and policy" "policy-base:checker-base" "$(cat "$MARK/external")"

reset_all; rm -f "$MARK/external"
sed -i 's/checker-base/checker-candidate/' tests/test-memory-projection-parity.sh
printf 'policy-candidate\n' > tests/lib/release-leak-pattern.ere
git add tests/test-memory-projection-parity.sh tests/lib/release-leak-pattern.ere
gate
check "two changed external files admit in separate lanes" "0" "$RC"
has "...with both lanes admitted" "$OUT" "candidate lanes: 2 of 2 admitted"
check "...each changes only its own file, retaining the other's baseline" \
    $'policy-base:checker-base\npolicy-base:checker-candidate\npolicy-candidate:checker-base' \
    "$(sort "$MARK/external")"

reset_all
printf 'not enforcement\n' > tests/test-memory-projection-parity.sh.backup
git add tests/test-memory-projection-parity.sh.backup; stage_src; gate
check "a similarly named file stays outside the declared exact root" "0" "$RC"
hasnt "...and gains no candidate lane" "$OUT" "candidate lanes"
rm -f tests/test-memory-projection-parity.sh.backup
git reset -q --hard HEAD~1
rm -f tests/test-memory-projection-parity.sh tests/lib/release-leak-pattern.ere "$MARK/external"

echo "the real parity and release callers execute their candidate policy"
reset_all
mkdir -p tests/lib
printf '#!/bin/sh\nexit 0\n' > tests/test-memory-projection-parity.sh
printf '# fixture builder\n' > build-release.sh
printf 'allow\n' > tests/lib/release-leak-pattern.ere
cat > tests/test-shipped-test-refs.sh <<'POLICY_EOF'
#!/bin/sh
[ "${1:-}" = --scan ] || exit 0
policy=${4:-$2}
if ! grep -qx allow "$policy/tests/lib/release-leak-pattern.ere"; then
    echo 'release fixture policy refuses' >&2
    exit 1
fi
POLICY_EOF
jq '.enforcement += ["tests/test-memory-projection-parity.sh", "tests/test-shipped-test-refs.sh",
                       "tests/lib/release-leak-pattern.ere", "build-release.sh"]
    | .invoking += ["tests/test-memory-projection-parity.sh", "tests/test-shipped-test-refs.sh",
                    "tests/lib/release-leak-pattern.ere", "build-release.sh"]
    | .shared = ["build-release.sh"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
printf 'CLAUDE.md = tests/test-memory-projection-parity.sh\n' >> .weave/test-map.conf
commit_nohook "real policy caller fixture"
stage_src; fresh tests/test-probe.sh; gate
check "(control) baseline release policy admits a healthy subject" "0" "$RC"

reset_all
printf '#!/bin/sh\n[ "${1:-}" = --scan ] || exit 0\nexit 1\n' > tests/test-shipped-test-refs.sh
git add tests/test-shipped-test-refs.sh; gate
check "a rejecting candidate release checker is actually run" "1" "$RC"
has "...in its own lane, not substituted into the protected pass" "$OUT" \
    "the candidate version of tests/test-shipped-test-refs.sh does not admit"

reset_all
printf '#!/bin/sh\nexit 0\n' > tests/test-shipped-test-refs.sh
printf 'refuse\n' > tests/lib/release-leak-pattern.ere
git add tests/test-shipped-test-refs.sh tests/lib/release-leak-pattern.ere; gate
check "a weakened checker cannot hide another policy file's refusal" "1" "$RC"
has "...the pattern lane retains the baseline checker and runs its own pattern" "$OUT" \
    "the candidate version of tests/lib/release-leak-pattern.ere does not admit"

reset_all
printf '#!/bin/sh\n[ "${1:-}" = --subject ] || exit 0\nexit 1\n' > tests/test-memory-projection-parity.sh
printf '%s\n' '{"id":"wv-000001","text":"fixture memory","metadata":{"type":"memory","mem_status":"active"}}' \
    >> .weave/nodes.jsonl
git add tests/test-memory-projection-parity.sh .weave/nodes.jsonl; gate
check "a rejecting candidate parity checker is actually run" "1" "$RC"
has "...in its own lane after the baseline parity check admitted" "$OUT" \
    "the candidate version of tests/test-memory-projection-parity.sh does not admit"
git reset -q --hard HEAD~1
rm -f tests/test-memory-projection-parity.sh tests/test-shipped-test-refs.sh tests/lib/release-leak-pattern.ere build-release.sh
