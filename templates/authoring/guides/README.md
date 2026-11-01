# Project coaching guides

Files in `.weave/guides/` override the coaching prose Weave ships. A guide answers, for one
violation type, what is wrong and what to do instead. It is prose, not code: there is no templating,
no executable Markdown, and no runner.

Weave installs its own guides with the package. That directory is where THIS repository says
something the package guide cannot. Nothing but guides belongs in it, which is why this file sits
beside it rather than inside.

## Naming

A guide is found by the basename the violation vocabulary maps its type to, not by the type name.
Look the mapping up in the installed vocabulary:

    python3 -c "import json,sys; print('\n'.join(f'{k} -> {v[\"guide\"]}' for k,v in json.load(open(sys.argv[1]))['types'].items()))" \
        "${WV_LIB_DIR:-$HOME/.local/lib/weave}/contracts/violation-vocabulary-v1.json"

So `prose:register` is coached by `register.md`, and a file named after the type itself would never
be read. `wv findings list --detail` renders what resolved.

## Resolution

First hit wins. Layers are never merged.

    .weave/guides/<id>.<language>.md      this directory, language-specific
    .weave/guides/<id>.md                 this directory, generic
    <package>/guides/<id>.<language>.md   package, language-specific
    <package>/guides/<id>.md              package, generic
    <package>/guides/_uncoached.md        fallback

A file here that fails validation is NOT skipped in favour of the package copy. It fails closed,
because silently preferring the package guide would hide a broken override for as long as nobody
looked. That also means one invalid guide takes the coaching run with it -- validate before
committing.

## Required contents

Frontmatter: `id` (equal to the filename without `.md` and any `.<language>` suffix),
`violation_type`, `summary`. Optionally `language`, and `sections`.

Sections, as `##` headings: `Why` and `Corrective move` are required. `Expected outcome` and `Avoid`
are optional; `Avoid` matters more than it looks, because the reader is usually an agent that can
satisfy a detector without fixing anything.

## Declaring extra sections

Four sections cannot express a violation type with named sub-forms, or a block of corpus exemplars.
When yours outgrows them, name the extra headings in frontmatter, pipe-separated:

    sections: The appended negation|Clause accretion|Exemplars from the corpus

Separate names with `|`, not a comma: a comma is part of a name. A name starts with a letter or
digit and holds up to 80 letters, digits, spaces and `, . : ' ( ) / -`.

The vocabulary stays closed around that declaration. A heading you did not declare is an error, a
declaration the body never uses is an error, a declaration may not restate one of the four fixed
names, and a declared section may not be empty. Declared sections render after the fixed four, in
the order your file puts them.

## This repository's own violation types

A lesson that holds only here can have a violation type of its own. Declare it on a detector in
`.weave/patterns/<id>.yaml` with a top-level line:

    violation_type: project:<name>

`<name>` is lowercase letters and digits joined by single hyphens. The type is coached by
`<name>.md` here, or `<name>.<language>.md`, which resolve as above; with neither, findings fall
back to `_uncoached`. The type exists in this repository only: a finding elsewhere may not set it,
and the shipped vocabulary never holds a `project:` type.

## Promotion

A declared section is the local tier. It says this repository needs a heading, and it does not say
anything about anyone else's repository.

A section name that turns up in unrelated repositories is a different claim: it describes a
construction rather than a house preference, and it belongs in the fixed set every repository
inherits. That promotion happens upstream, in Weave, and a repository cannot grant it to itself --
the same rule that decides when a local quality rule becomes a managed one. If a name here has
earned it, say so upstream rather than waiting.

## Checking a guide before you commit it

A broken guide is otherwise found when a finding of its type is coached, which may be long after it
was written, and it fails the run rather than itself. Run `wv doctor` instead. Two records cover
this directory:

- `guide-validity` fails when a guide here does not parse, or parses but does not resolve where it
  is selected (for example a `.python.md` override whose `violation_type` names a different type),
  and warns about a guide no catalogued or declared type selects.
- `guide-completeness` warns about canonical types that coach only through the `_uncoached`
  fallback.

Both come from the parser and resolver the coaching run uses, in the same installed copy. For every
error in full:

    python3 -m weave_quality.guides doctor --project-root .

with `PYTHONPATH` set to the directory holding `weave_quality` (the installed library directory,
usually `~/.local/lib/weave`).

## example-violation.md

Seeded once, never refreshed, safe to delete. Its id is not in the vocabulary. Nothing resolves to
it and it coaches nobody: it is there to be copied, and `wv doctor` lists it as an example rather
than an unused guide.
