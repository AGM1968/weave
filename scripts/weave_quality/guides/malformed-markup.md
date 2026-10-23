---
id: malformed-markup
violation_type: markdown:malformed-markup
summary: Markup that renders differently from what the author wrote.
---

## Why

Markdown is read twice: as source by people editing it, and as rendered output by everyone else.
Some constructions look right in the source and break in rendering. A bare URL may or may not become
a link depending on the renderer, and its trailing punctuation may be swallowed into the address. An
inline code span split across two source lines can lose its formatting, or swallow the text between
its halves into code.

## Corrective move

Write a URL as a link with descriptive text (`[the release notes](https://example.org/notes)`) or as
an autolink in angle brackets, and every renderer treats it the same way. Keep each inline code span
on one source line. When a path or command is too long for that, name it in prose or move it into a
fenced code block, which can span lines.

## Expected outcome

The rendered document shows what the source shows: links are links, code is code, and no formatting
depends on which renderer the reader happens to use.

## Avoid

Breaking the line somewhere else inside the span, or escaping characters until the checker stops
matching while the rendering stays wrong. Check the rendered output, not only the source.
