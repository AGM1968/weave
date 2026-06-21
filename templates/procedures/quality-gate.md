---
id: quality-gate
description:
  "Recover from a GraphPolicyViolation when wv done is blocked by a complexity threshold. Use when a
  closure fails on CC limits and you need to refactor or exempt the path."
fallback: "wv guide --procedure=quality-gate"
adapters: [codex, copilot]
visibility: shared
---

# Quality Gate — GraphPolicyViolation

`wv done` enforces CC thresholds (Bash: 100, Python: 25, TypeScript: 15). If a node touches a file
over the limit, closure is blocked with `GraphPolicyViolation`.

**Resolution path:**

```bash
wv quality functions <file>    # see which functions are over the limit
# Option A: refactor the file, commit, wv quality scan, retry wv done
# Option B: exempt the path in .weave/quality.conf then wv load
```

**Exempting a path** (monolithic scripts, archived code, one-off utilities):

```ini
# .weave/quality.conf
[exempt]
install.sh          # full path match — monolithic, not application logic
archive/            # directory prefix (trailing / required)
```

After editing `.weave/quality.conf`, run `wv load` to sync exemptions into the live DB, then retry
`wv done`. The `WV_REQUIRE_QUALITY=0` env var bypasses the refresh functions only — the DB
constraint still fires; use the conf file instead.

**Per-developer override** (gitignored, never shared): `.weave/quality.local.conf` is loaded after
`.weave/quality.conf` and lets you suppress `warn`-level gates locally without touching the shared
config. Team-wide `test_gate=2` (block) gates cannot be downgraded by the local layer.
