---
id: unsafe-subprocess
violation_type: code:unsafe-subprocess
summary: A subprocess call hands its arguments to a shell that will reinterpret them.
---

## Why

When a command runs through a shell (`shell=True`, `os.system`, a single command string), every
argument is parsed a second time: spaces split it, `$` expands it, `;` and `&&` start new commands,
and quotes change meaning. Any value that came from a file name, a user, a config entry or another
program can turn into extra commands or extra arguments. The defect is usually invisible in testing,
because test inputs rarely contain the characters that break it, and it appears later as a failure
on an unusual path name or as a command nobody wrote.

## Corrective move

Pass the program and its arguments as a list and leave the shell out:
`subprocess.run(["git", "log", "--", path], check=True)`. Each list element reaches the program as
one argument, exactly as written, with no second parse. The program still parses its own options, so
a value beginning with `-` would be read as one: end the options with `--` before any argument that
came from outside, as the example does. If the command needs a pipe or a redirect, build it from
separate calls (one process's `stdout` feeding the next) or do the step in Python rather than asking
a shell to assemble it. Where a shell is the only reasonable tool, keep the command string constant
and pass every variable part through `shlex.quote`: the shell then sees data where you meant data.

## Expected outcome

Every subprocess call states its argument vector directly, and an argument containing spaces, quotes
or shell punctuation arrives at the program unchanged. A reader can see from the call alone which
program runs and with what arguments.

## Avoid

Quoting part of an interpolated string and leaving the rest raw, which protects the one value you
thought of and leaves the others open. Avoid also silencing the finding with a suppression comment
while the call still builds its command by string formatting: the report disappears and the
injection path stays.
