---
id: unquoted-expansion
violation_type: code:unquoted-expansion
summary: An unquoted shell expansion is split on whitespace and globbed before the command sees it.
---

## Why

In a shell, `$var` without quotes is not one value. The shell splits it on whitespace and then
expands any `*`, `?` or `[` in the pieces against the file system. A path with a space becomes two
arguments, an empty variable disappears and shifts the arguments after it, and a value containing
`*` silently becomes a list of whatever files happen to match. Scripts pass their tests on tidy
inputs and then fail, or act on the wrong files, the first time a name contains a space.

## Corrective move

Quote every expansion that holds one value: `"$file"`, `"${dir}/name"`, `"$(command)"`. When a
variable holds a list, store it in an array and expand it as `"${items[@]}"`, which keeps each
element as one argument. When splitting really is the intent, do it explicitly
(`read -ra parts <<< "$line"`) so a reader can see where the boundaries come from instead of
inheriting whatever the shell's word splitting decides.

## Expected outcome

Each argument a command receives corresponds to one value the script meant to pass. File names with
spaces, empty strings and literal glob characters behave as data.

## Avoid

Disabling the check (a blanket `SC2086` exclusion) to make the warnings go away. Avoid also quoting
a variable that deliberately holds several arguments, which turns a list into one argument; the fix
there is an array, not quotes.
