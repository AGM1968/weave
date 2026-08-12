# Weave

Weave is the Bash/Python implementation of a durable work, memory, and policy graph for coding
agents. As of v1.71 it is maintained as a supported long-term maintenance (LTS) line, kept
deliberately separate from an in-progress Rust successor program.

## Two Separate Lifecycles

```
┌────────────────────────────────┐
│ Weave 1.71 LTS                  │
│ Bash/Python compatibility       │
│ Public maintenance releases     │
└────────────────┬─────────────────┘
                 │ contract / reference behavior
                 ▼
┌────────────────────────────────┐
│ Rust successor program          │
│ Shadow / read-only initially    │
│ E1–E7 gates before mutation     │
│ authority and cutover           │
└────────────────────────────────┘
```

- **Weave 1.71 (this repository)** is the supported line. It receives correctness, security,
  durability, compatibility, and installer fixes.
- **The Rust successor** is a separate, non-authoritative program: shadow/read-only against this
  repository's behavior as its reference contract, until it passes its own durability and evidence
  gates (E1 through E7). Those gates block _Rust_ mutation authority and cutover — they do not, and
  have never, blocked ordinary maintenance releases of this Bash/Python line.

## Public Status

- Weave 1.71 is an active, supported maintenance line — not archived, not frozen.
- Releases on this line are scoped to correctness, security, durability, compatibility, and
  installer fixes, not new features.
- No experimental Rust mutation authority, evaluation harness, or private evidence-lab code is part
  of this release, or of any release on this maintenance line.
- Internal graph state, transcripts, host session exports, and evidence-lab artifacts are not part
  of the public release surface — this repository is generated and stays graph-free by design.

See `CHANGELOG.md` for the fixes in each release.

## Existing Users

If you already use Weave, keep using the release you have unless you need a specific fix from a
newer one. This release is published as a prerelease and will not be pulled in automatically by
`wv-update`; install it explicitly if you want it before it is promoted.

For private/internal deployments from the upstream source repository, update via the source clone
and then refresh consumer repositories:

```bash
cd /path/to/memory-system
git pull --ff-only
./install.sh

cd /path/to/consumer-repo
wv repo-class --json
wv init-repo --agent=all --update
wv load
wv bootstrap --json
```

Run `init-repo` only for repositories classified as `owned`; bulk deployments must skip
`vendored-upstream` and `ambiguous` targets. Use `--agent=claude`, `--agent=codex`, or
`--agent=copilot` instead of `--agent=all` when a consumer repo should receive only one host
surface.

## Archive Direction

This repository is **not** being archived. Archival is a future decision, gated on all of the
following being true at once:

- a named successor repository is publicly accessible;
- it has compatible install/update and migration instructions;
- existing graphs load into it without semantic loss;
- its mutation authority has passed its E1–E7 evidence gates;
- rollback from the successor to Weave 1.71 has been demonstrated;
- owned-machine canaries have run successfully for a defined period;
- a final Weave 1.71 release ships migration and archival notices.

None of those conditions are met today: the Rust program remains gated, mutation cutover has not
happened, and no public production-ready successor exists yet. Until they are, Weave 1.71 continues
to receive maintenance releases.
