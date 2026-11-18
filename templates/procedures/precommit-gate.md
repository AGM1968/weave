---
id: precommit-gate
description:
  "Configure the impact-scoped pre-commit test gate and keep CI quiet on .weave/ pushes. Use when
  tuning test-impacted.sh / test-map.conf or setting up paths-ignore for a consumer repo."
fallback: "wv guide --procedure=precommit-gate"
adapters: [codex, copilot]
visibility: shared
---

# Pre-commit Test Gate & CI Hygiene

`wv init-repo` scaffolds two optional, consumer-tunable files for a fast, low-noise gate:

- **`scripts/test-impacted.sh`** (seeded if-absent) — a fast, impact-scoped pre-commit test runner.
  It inspects the STAGED sources and runs the test command on ONLY their mirror test dirs (nearest
  existing ancestor), falling back to the full suite when nothing resolves. Edit the CONFIG block
  (`SRC_PREFIX`/`TEST_ROOT`/`RUNNER`/`RUN_ENV`) per repo, then route sources to it in
  `.weave/test-map.conf` (glob/prefix/`[default]` keys, wv 1.60.0+):

  ```ini
  [map]
  src/ = scripts/test-impacted.sh
  ```

  Origin (a consumer test-bed): cut a localized change from 6.2s/1385 tests to ~1.1s. It is never
  overwritten on `--update` — it carries per-repo edits.

  A staged file that no row, pattern or `[default]` entry covers runs no test. When a commit mixes
  routed and unrouted files, the hook passes it but warns, naming the unrouted ones; with nothing
  routed it says the gate is inert. `wv impact --suites --unmatched --files=<paths>` lists the same
  files. To check every path, opt in to a fail-safe for the files nothing else covers:

  ```ini
  [default]
  scripts/test-impacted.sh
  ```

- **`.weave/prose-gate.conf`** (opt-in, not scaffolded) — commit this file, with any content, to
  turn on the staged-markdown prose gate. The pre-commit hook then refuses a commit whose staged
  `.md` files add findings from managed or custom pattern rules (`.weave/patterns/`). Findings
  already in HEAD never block. The checker is the one installed with Weave, never a file in the
  repository. The commit that deletes the file is still judged, so the gate is off from the next
  commit.

- **`.weave/ci-weave-paths-ignore.snippet.yml`** (refreshed on `--update`) — reference snippet
  recommending a `paths-ignore: ['.weave/**']` rule on each workflow trigger. Prefer this over the
  `[skip ci]` commit token: GitHub scans the whole message for `[skip ci]`, so a real commit that
  merely mentions the token self-skips. `paths-ignore` keys on changed files — pure-`.weave/` pushes
  skip while mixed code+`.weave/` pushes still run.
