# Deliberately safe: the scanner must report none of these. Not executed.
grep -q -- "$barrier" file
grep -qF -- "${braced}" file
git grep -e "$pattern" -- ':!*.lock'
grep -q '$literal_dollar' file
grep -qE '^[0-9]+$' file
grep -q "plain-literal" file
grep -q -- "$before_barrier" file
grep -q \
  -- "$continued_safe" file
git grep -e \
  "$git_bound" -- ':!*.lock'
