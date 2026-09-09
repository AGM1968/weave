---
id: cutover
description:
  "Migrate an existing consumer repo to causal delta ordering — when and how to run `wv cutover`,
  the coordination gate it requires, and what happens if it's skipped. Use when upgrading wv in a
  repo whose committed .weave/deltas/ catalog predates causal lineage ordering."
fallback: "wv guide --procedure=cutover"
adapters: [codex, copilot]
visibility: shared
status: ready
---

# Causal Cutover

Upgrading `wv` flips two things automatically: `WV_DELTA_V2_WRITE` defaults on, and
`wv init-repo --update` adds the causal-cutover and `v2` merge rules to `.gitattributes`. Neither
stamps the cutover marker itself — that step is never automatic, because it is the one operation in
the delta path that can lose data: once `.weave/causal-cutover` is committed, `wv load` fail-closes
every v1 delta with no lineage header instead of replaying it by wall-clock rank.

Run it only when every agent has closed and synced. `wv cutover` refuses by default while any node
is claimed, because that in-flight work's un-synced deltas would become permanently unreplayable the
moment the marker lands.

```bash
wv init-repo --update      # picks up the new .gitattributes rules first
wv cutover --yes           # refuses at lineage_seq 0 or while a node is claimed
git add .weave/causal-cutover && git commit -m "chore: stamp causal cutover" && git push
```

Every clone only gets the fail-closed behavior once it has pulled that commit. A repo that never
runs this keeps working exactly as before — there is no forced migration window.

After cutover, verify convergence from a fresh clone before trusting it in a repo with real history:
`wv load` should show no unexpected `Skipped corrupt delta` lines, and `wv doctor` should stay
clean.
