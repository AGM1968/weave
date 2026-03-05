# weave_quality — Code Quality Scanner

Static analysis and hotspot tracking for the Weave CLI. Produces a per-repo `quality.db` with
cyclomatic complexity, essential complexity, git-derived churn, CK metrics, and hotspot scores.

- **Version:** v1.13.1
- **Academic foundations:** McCabe (1976), Tornhill (2018), Chidamber & Kemerer (1994)
- **Zero external dependencies** — Python stdlib (`ast`, `re`, `subprocess`, `pathlib`) + git

---

## Table of Contents

1. [Architecture](#architecture)
2. [Commands](#commands)
3. [Metrics Reference](#metrics-reference)
4. [Scoring Formula](#scoring-formula)
5. [File Classification](#file-classification)
6. [CC Methodology & Divergences](#cc-methodology--divergences)
7. [Performance](#performance)
8. [Data Storage](#data-storage)
9. [Module Guide](#module-guide)
10. [Configuration](#configuration)
11. [Known Limitations](#known-limitations)

---

## Architecture

```txt
wv quality scan [path]
  │
  ├── classification.py   — production / test / script / generated
  ├── python_parser.py    — AST: CC, ev, CK metrics, per-function CC
  ├── bash_heuristic.py   — regex: complexity proxy for Bash
  ├── git_metrics.py      — churn, authors, ownership, co-change (batched)
  ├── hotspots.py         — normalize(complexity) × normalize(churn), scoring
  └── db.py               — quality.db schema, incremental scan state
        │
        ▼
  quality.db  (hot zone: /dev/shm/weave/<repo-hash>/quality.db)
  Never synced. Never git-tracked. Rebuildable via `wv quality scan`.
        │
  wv quality hotspots / diff / functions / promote / health-info
```

### Data Flow

The scan pipeline runs in this order:

1. **Discover files** — git-tracked files matching include patterns, minus excludes
2. **Classify** — each file gets a category (`production`, `test`, `script`, `generated`)
3. **Incremental check** — compare `mtime` + git blob SHA against `file_state` table; skip unchanged
   files
4. **Parse** — Python files via AST; Bash/shell via regex heuristic
5. **Git metrics** — single batched `git log` call for churn/authors/ownership; single `git ls-tree`
   call for blob SHAs; single `git log --name-only` for co-change pairs
6. **Hotspot scoring** — `normalize(complexity) × normalize(churn)` per file
7. **Quality score** — graduated per-function penalty model (see
   [Scoring Formula](#scoring-formula))

---

## Commands

All commands are exposed via `wv quality <subcommand>`. The Bash wrapper
(`scripts/cmd/wv-cmd-quality.sh`) invokes `python3 -m weave_quality`.

### `wv quality scan [path]`

Full or incremental scan. Defaults to the git root of the current directory.

```bash
wv quality scan                     # scan current repo
wv quality scan /path/to/repo       # explicit path
wv quality scan --exclude="dist/**" # additional excludes (stacks with .weave/quality.conf)
wv quality scan --json              # JSON output: scan_id, files_scanned, quality_score, ...
```

Incremental: only re-parses files where `mtime` or git blob SHA changed since last scan. Git metrics
are always recomputed (they reflect the full log).

### `wv quality hotspots [--top=N]`

Ranked hotspot report. Files above `hotspot=0.5` are flagged.

```bash
wv quality hotspots --top=10
wv quality hotspots --scope=all          # include test/script files (default: production)
wv quality hotspots --json               # machine-readable
```

Output columns: `path`, `hotspot`, `CC`, `ev`, `Gini`, `churn`, `severity`

### `wv quality functions <path>`

Per-function CC breakdown for a file or directory.

```bash
wv quality functions src/monitoring/runner.py
wv quality functions src/                      # all Python files under path
wv quality functions src/runner.py --json      # {functions, histogram, cc_gini}
```

Dispatch-exempt functions (pure `match/case` or flat `if/elif` chains) are flagged `[dispatch]` and
exempt from the CC ≥ 10 threshold per McCabe's explicit exception.

### `wv quality diff`

Delta report between the two most recent scans.

```bash
wv quality diff
wv quality diff --scope=production    # production files only (default)
wv quality diff --json
```

### `wv quality promote --top=N`

Creates Weave nodes in `brain.db` for top findings. The only way quality data enters the graph.
Idempotent — re-running updates existing nodes rather than duplicating them.

```bash
wv quality promote --top=5 --parent=wv-xxxxxx
```

### `wv quality health-info`

Compact quality summary for `wv health` output. Not a standalone command — called internally.

### `wv quality reset`

Deletes `quality.db` entirely. Use when schema changes break an existing DB or after major Weave
upgrades.

```bash
wv quality reset
```

**Note:** After any Weave upgrade that changes metric computation, delete the DB and rescan from
scratch. Incremental scans will not recompute metrics for unchanged files.

---

## Metrics Reference

### File-Level Metrics

| Metric                 | Source      | Description                                              |
| ---------------------- | ----------- | -------------------------------------------------------- |
| `complexity`           | AST / regex | Cyclomatic complexity v(G) — predicate count + 1         |
| `essential_complexity` | AST         | Essential complexity ev(G) — unstructured-flow heuristic |
| `indent_sd`            | Source text | Standard deviation of indentation levels (nesting proxy) |
| `functions`            | AST         | Function definition count                                |
| `max_nesting`          | AST         | Maximum syntactic nesting depth                          |
| `avg_fn_len`           | AST         | Average function length in lines                         |
| `loc`                  | Source text | Lines of code (non-empty, non-comment)                   |
| `category`             | Classifier  | `production`, `test`, `script`, or `generated`           |

### CK Object-Oriented Metrics (Python only)

| Metric | Full Name                   | Implementation                                     |
| ------ | --------------------------- | -------------------------------------------------- |
| `wmc`  | Weighted Methods per Class  | Sum of per-method CC (class methods only)          |
| `cbo`  | Coupling Between Objects    | Unique import count per module                     |
| `dit`  | Direct Inheritance Bases    | `len(cls.bases)` — counts direct bases, not depth¹ |
| `rfc`  | Response for Class          | Method count + unique `Call` nodes                 |
| `lcom` | Lack of Cohesion in Methods | Shared `self.attr` analysis across method pairs    |

¹ Renamed from `dit` to `direct_bases` in v1.12.2 to reflect what it actually measures. The standard
DIT (depth across the inheritance chain) requires cross-file resolution, which the scanner does not
do.

### Per-Function Metrics

| Metric        | Description                                                      |
| ------------- | ---------------------------------------------------------------- |
| `complexity`  | CC for this function (with `per_function=True` guard — no        |
|               | double-counting of nested functions)                             |
| `ev`          | Essential complexity for this function                           |
| `is_dispatch` | True if function is a pure dispatch (match/case or flat if/elif) |
| `line_start`  | First line of function definition                                |
| `line_end`    | Last line of function body                                       |

### Git-Derived Metrics

| Metric               | Description                                               |
| -------------------- | --------------------------------------------------------- |
| `churn`              | Total commits touching this file                          |
| `authors`            | Unique author count                                       |
| `ownership_fraction` | Top author's share of commits (Tornhill ownership model)  |
| `minor_contributors` | Authors contributing < 5% of commits                      |
| `age_days`           | Days since last modification                              |
| `hotspot`            | `normalize(complexity) × normalize(churn)` — range [0, 1] |

### Aggregate Metrics

| Metric         | Description                                          |
| -------------- | ---------------------------------------------------- |
| `cc_gini`      | Gini coefficient of per-function CC distribution     |
|                | 0 = equal distribution, 1 = all complexity in one fn |
| `cc_histogram` | Function counts in buckets [1–5, 6–10, 11–20, 21+]   |

---

## Scoring Formula

The quality score (0–100) uses a graduated per-function penalty model, scoped to production files by
default. There is no density normalization — repos with more absolute problems score lower
regardless of size.

```txt
score = 100.0

for each non-dispatch function:
    if CC > 10:
        score -= min((CC - 10) × 0.5, 8.0)   # capped at 8 per function

for each production file:
    if ev > 4:                                 # McCabe's "troublesome" threshold
        score -= min((ev - 4) × 0.5, 3.0)

    if hotspot > 0.5:
        score -= 5.0

    if file has ≥ 3 functions and Gini > 0.7:
        score -= 1.0

return clamp(score, 0, 100)
```

**Thresholds:**

| Constant            | Value | Source                                     |
| ------------------- | ----- | ------------------------------------------ |
| `HOTSPOT_THRESHOLD` | 0.5   | Tornhill empirical baseline                |
| `CC_WARNING`        | 15    | 1.5× McCabe's recommended limit of 10      |
| `CC_CRITICAL`       | 30    | 3× McCabe's limit — used in legacy reports |
| ev threshold        | 4     | McCabe: ev > 4 = "troublesome" module      |
| Gini threshold      | 0.7   | Concentration risk signal                  |

**Calibration results (v1.13.0, earth-engine-analysis):**

| v1.12.2 | v1.13.0 | Change                                     |
| ------: | ------: | ------------------------------------------ |
|   0/100 |  38/100 | +38 (scope separation + graduated formula) |

The v1.12.2 score of 0 was caused by 28 test files at CC ≥ 30 each contributing −3 to the score. The
v1.13.0 scope filter excludes test/script files by default.

---

## File Classification

Every file is classified into one of four categories before scoring:

| Category     | Heuristics                                                                            |
| ------------ | ------------------------------------------------------------------------------------- |
| `generated`  | `dist/`, `build/`, `generated/`, `*.pb2.py`, `*_pb2.py`                               |
| `test`       | `test/`, `tests/`, `test_*.py`, `*_test.py`                                           |
| `script`     | `scripts/`, `Makefile`, `setup.py`, `conftest.py`, `*.sh`, `*.toml`, `*.cfg`, `*.ini` |
| `production` | Everything else                                                                       |

Priority order: `generated` > `test` > `script` > `production`.

**Per-project overrides** via `.weave/quality.conf`:

```ini
[classify]
production = scripts/mylib/   # promote library code to production
test = custom_tests/          # add extra test directories
```

The `--scope` flag on `wv quality hotspots` and `wv quality diff` accepts: `production` (default),
`all`, `test`, `script`, `generated`.

---

## CC Methodology & Divergences

CC is computed by direct predicate counting on the Python AST (`_ComplexityVisitor`). This is
mathematically equivalent to the graph-based `E - V + 2` formula for structured programs.

**Constructs that add to CC:**

| Construct           | +CC | Notes                                               |
| ------------------- | --- | --------------------------------------------------- |
| `if` / `elif`       | +1  | Each `elif` is a separate AST `If` node             |
| `for` / `async for` | +1  | Loop entry path                                     |
| `while`             | +1  |                                                     |
| `except` handler    | +1  | Per handler                                         |
| `and` / `or`        | +1  | Per operator — short-circuit creates separate paths |
| `assert`            | +1  | Can fail — branch path                              |
| Comprehension `for` | +1  | Per `for` clause                                    |
| Comprehension `if`  | +1  | Per filter clause                                   |
| `match/case` arm    | +1  | Python 3.10+ (version-guarded)                      |

**Divergences from PyCQA/mccabe (flake8 C901):**

| Construct      | PyCQA             | Weave    | Rationale                                   |
| -------------- | ----------------- | -------- | ------------------------------------------- |
| `and`/`or`     | Not counted       | +1/op    | Faithful to McCabe §III compound predicates |
| `assert`       | Not counted       | +1       | Branch path — can raise `AssertionError`    |
| Comprehensions | Not counted       | +1/for   | Iteration creates independent paths         |
| Nested funcs   | Counted in parent | Separate | Per-function isolation (D1 decision)        |
| `try` block    | +1 (path node)    | Not +1   | `except` handlers are counted instead       |

**Practical implication:** Weave CC values are 13–27% higher than PyCQA/mccabe for files with
BoolOps, asserts, or comprehensions. This is intentional — Weave targets path-coverage estimation
while PyCQA targets flake8 workflow compatibility. Use `flake8 --max-complexity` as a cross-check
when Weave reports unexpectedly high CC.

**Essential complexity ev(G):**

`ev(G) = 1` for a fully structured function. Non-reducible constructs detected:

- `break` inside a loop (breaks single-exit property)
- `continue` inside nested conditionals
- Multiple `return` statements at different nesting depths
- Bare `raise` inside `except` handlers

McCabe found `ev > 4` disproportionately identifies "troublesome" modules, independent of CC.

---

## Performance

Benchmark on memory-system repo (75 files: 32 Python + 43 Bash), v1.8.1:

| Component               | Before (v1.8.0) | After (v1.8.1) | Improvement |
| ----------------------- | --------------- | -------------- | ----------- |
| Total scan time         | 6.5s            | 2.4s           | 2.7×        |
| Subprocess calls        | ~654            | 5              | 131×        |
| `compute_co_changes`    | 1.65s           | 0.09s          | 18×         |
| `git_blob_sha` per file | 0.40s           | 0 (batched)    | eliminated  |
| `ast.walk` calls        | 353,009         | 96,839         | 3.6×        |

At scale (earth-engine-analysis, 175 Python files, v1.8.1): **5.5s total** — fewer than the 75-file
pre-optimisation baseline.

**Key optimisations:**

- **Batch blob SHAs** — single `git ls-tree -r HEAD` replaces one `git hash-object` per file
- **Batch co-changes** — single `git log --name-only --format=COMMIT_SEP` replaces one
  `git diff-tree` per commit SHA (was 500+ spawns)
- **Single-pass AST** — `_single_pass_ast()` collects CC, ev, function list, imports, and class
  nodes in one walk; eliminates 4 of 7 redundant top-level `ast.walk` calls
- **Batch git stats** — single `git log` pass for churn/authors/ownership (established in v1.7.1)

**Remaining hotspot:** `_ast_ck_metrics` (specifically LCOM computation) requires the full class
method list before computing set intersections — structurally resistant to the single-pass approach.
Accounts for ~1s at 175-file scale.

---

## Data Storage

`quality.db` lives at `$WV_HOT_ZONE/quality.db` — a sibling to `brain.db` in the per-repo hot zone
(e.g. `/dev/shm/weave/a1b2c3d4/quality.db`). It is:

- **Never synced** to `.weave/state.sql`
- **Never git-tracked**
- **Rebuildable** at any time via `wv quality scan`
- **Retained across sessions** (lives on tmpfs until machine reboot, or until `wv quality reset`)

**Retention:** 5 scans (expanded from 2 in v1.8.0 for trend analysis).

**Schema summary:**

```sql
scan_meta    -- scan_id, git_head, files_count, duration_ms, scanned_at
files        -- path, scan_id, language, loc, complexity, essential_complexity,
             --   indent_sd, functions, max_nesting, avg_fn_len, category
file_metrics -- path, scan_id, metric, value, detail  (CK suite + fn_cc EAV)
git_stats    -- path, churn, authors, age_days, hotspot,
             --   ownership_fraction, minor_contributors
file_state   -- path, mtime, git_blob  (incremental scan state)
co_change    -- path_a, path_b, count
```

Per-function CC is stored in `file_metrics` using EAV pattern:
`metric = "fn_cc:<function_name>@<line_start>"`, with `detail` JSON containing
`{line_start, line_end, is_dispatch, essential_complexity}`.

---

## Module Guide

| Module              | Responsibility                                                     |
| ------------------- | ------------------------------------------------------------------ |
| `__main__.py`       | CLI entry point — argument parsing, subcommand dispatch, scope     |
|                     | filtering, JSON output schemas                                     |
| `models.py`         | Dataclasses: `FileEntry`, `FunctionCC`, `ASTAnalysis`,             |
|                     | `CKMetrics`, `GitStats`, `CoChange`, `ScanMeta`, `ProjectMetrics`  |
| `python_parser.py`  | AST visitors: `_ComplexityVisitor`, `_EssentialComplexityVisitor`, |
|                     | `_single_pass_ast()`, CK metrics, regex fallback                   |
| `bash_heuristic.py` | Regex-based CC proxy and indent_sd for Bash/shell files            |
| `classification.py` | File category classifier with `.weave/quality.conf` overrides      |
| `git_metrics.py`    | Batched git subprocess calls: `_batch_git_stats()`,                |
|                     | `batch_blob_shas()`, `compute_co_changes()`                        |
| `hotspots.py`       | Hotspot scoring, quality score formula, Gini, CC histogram         |
| `db.py`             | SQLite schema creation, reads/writes, 5-scan retention policy      |

### Key internal patterns

**`_single_pass_ast(tree)`** — Collects all file-level data in one `ast.walk`: complexity, nesting
depth, function list with line ranges, essential complexity per function, imports, class nodes.
Returns `ASTAnalysis`. CK metrics (`_ast_ck_metrics`) take the `ASTAnalysis` result as input to
avoid re-walking for imports and class nodes.

**`per_function=True` guard** — `_ComplexityVisitor` stops recursing at `FunctionDef` boundaries
when computing per-function CC, preventing nested function branches from inflating the outer
function's count (fixed in v1.13.0).

**Dispatch detection** — `_is_dispatch_function()` classifies a function as dispatch if its body is
a single `match/case` statement (Python 3.10+) or a flat `if/elif` chain with no nesting in the
branches. Dispatch functions are stored with `is_dispatch=True` and exempt from CC ≥ 10 threshold
per McCabe's explicit exception for "a single selection function with many independent cases."

**Regex fallback** — `analyze_python_file()` calls `ast.parse()` first. If it raises `SyntaxError`,
`ValueError`, or `RecursionError`, the regex fallback in `_regex_analyze()` runs automatically. The
fallback produces CC and function count but no CK metrics or per-function CC.

---

## Configuration

**`.weave/quality.conf`** (optional, per-repo):

```ini
[exclude]
# One glob per line. Inline comments are supported.
dist/**
build/**

[classify]
# Override default category assignments. Inline comments are supported.
production = scripts/mylib/   # promote library code in scripts/
test = custom_tests/          # additional test directory
script = infra/               # additional script directory
```

**Environment variables** (inherited from `wv-config.sh`):

| Variable      | Effect                                              |
| ------------- | --------------------------------------------------- |
| `WV_HOT_ZONE` | Override hot zone path (default: `/dev/shm/weave/`) |
| `WV_DB`       | Override brain.db path (quality.db resolved nearby) |

---

## Known Limitations

**CC vs PyCQA values:** Weave CC is 13–27% higher than `flake8 --max-complexity` due to BoolOp,
assert, and comprehension counting. This is intentional — see
[CC Methodology](#cc-methodology--divergences).

**`direct_bases` ≠ DIT:** The `dit` metric (renamed `direct_bases` in v1.12.2) counts direct base
classes (`len(cls.bases)`), not inheritance chain depth. True DIT requires cross-file resolution,
which the scanner does not perform.

**LCOM scaling:** LCOM computation requires the full class method list and is O(methods²). At 175+
Python file scale it accounts for ~1s. No optimization path identified without fundamental algorithm
change.

**Hotspot threshold is absolute on a relative scale:** `HOTSPOT_THRESHOLD = 0.5` is compared against
min-max normalised scores (per repo, per scan). Adding or removing a single extreme outlier file
shifts all hotspot scores and can toggle borderline files across the threshold without any code
change. This is acceptable for the two-repo calibration basis but may produce unexpected churn in
larger, more heterogeneous repos.

**`wv quality diff` score delta is partly a git-history artifact:** `git_stats` (churn, authorship)
is not scan-versioned — both the current and previous score are computed with current git data. If
churn or commit-history changed between the two scans (e.g. a force-push, history rewrite, or large
batch of commits), the diff delta reflects the git-history change, not only code quality
improvement.

**Incremental scan after upgrade:** The scanner version is stored in `scan_meta.scanner_version`.
When a scan detects the version differs from the previous scan, it automatically forces a full
re-scan so no stale metrics are carried forward. No manual `wv quality reset` is needed after a
Weave upgrade.

**Test failures on GPG-signing systems:** Tests that create ephemeral git repos will fail if git
commit signing is globally enforced (`commit.gpgsign=true`) and the GPG agent is unavailable. Set
`WV_SKIP_PRECOMMIT=1` or configure per-repo `gpgsign=false` in the test environment.

**Rust accelerator (wv-c1483e) deferred:** A tree-sitter Rust binary (`wvc`) was designed for
large-repo acceleration. At current scale (300 files ≈ 5.5s), the Python path is fast enough.
Implement if a >1000-file monorepo demands it — the CST/AST gap makes it a reimplementation, not a
port (see `docs/PROPOSAL-wv-mccabe-review.md`).
