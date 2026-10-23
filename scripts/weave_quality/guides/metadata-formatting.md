---
id: metadata-formatting
violation_type: markdown:metadata-formatting
summary: Metadata written as bold labels on consecutive lines instead of in a structure.
---

## Why

Lines such as `**Status:** draft` followed by `**Owner:** platform` look like separate fields in the
source. In Markdown, consecutive lines without a blank line between them form one paragraph, and
they render as a single run-on line. The structure the author saw is lost, and no tool can read the
fields back out.

## Corrective move

Give metadata a structure that keeps one field per line. For document-level metadata, use YAML front
matter. For a short set of fields in the body, use a list (one item per field) or a two-column
table. Keep bold for emphasis inside prose, where it marks a word rather than a key.

## Expected outcome

Each field renders on its own line, and the metadata can be read by a person and parsed by a tool
without depending on how the source happens to be wrapped.

## Avoid

Inserting trailing spaces or line-break tags to force the bold labels onto separate lines. The
rendering improves, but the fields are still unstructured text that nothing can parse.
