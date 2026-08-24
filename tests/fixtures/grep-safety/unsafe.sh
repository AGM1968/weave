# Deliberately unsafe: every form the scanner must recognise. Not executed.
grep -q "$lower" file
grep -q "$UPPER" file
grep -q "${braced}" file
grep -qE "$alpha|$beta" file
git -C "$repo" grep -Il -E "$marker_ere" -- ':!*.lock'
grep -q "$after_barrier" -- file
grep -q \
  "$continued" file
git -C "$repo" grep -E \
  "$git_continued" -- ':!*.lock'
