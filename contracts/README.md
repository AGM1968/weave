# Weave IPC Contract v1

This directory is the machine-readable contract for the bounded v1 read/policy slice. It is not a
service implementation and it does not advertise mutation support.

- `protocol-v1.schema.json` defines envelopes, repository identity, bounds, and capabilities.
- `errors-v1.schema.json` defines stable machine errors and code-discriminated detail shapes;
  `error-catalog-v1.json` supplies every policy.
- `policy-reason-catalog-v1.json` is the separate stable vocabulary for policy verdict reasons.
- `hook-events-v1.schema.json` and `policy-v1.schema.json` define pure hook evaluation.
- `durability-v1.schema.json` distinguishes revision-scoped graph serialization from Git durability.
- `checkpoint-manifest-v1.schema.json` binds a checkpoint to `state.sql` and records covered legacy
  SQL by raw hash.
- `legacy-delta-catalog-v1.schema.json` preserves covered legacy SQL as non-executable audit
  evidence.
- `canonical-json-v1.json` defines the canonical byte form used for Delta v2 operation hashes.
- `node-field-registry-v1.json` defines the semantic node fields available to Delta v2 `node_patch`
  CAS.
- `node-kinds-v1.json` enumerates node kinds (`metadata.node_kind`, mirrored to `metadata.type` for
  one release), the kinds a command may write, the creation precedence and the backfill mapping
  (ontology S1, `wv-f7dfd3`). It is not a Delta v2 field: kind travels inside metadata patches.
- `edge-types-v1.json` states each edge type's meaning and direction and the invariant it carries
  (no self-edge, acyclic `blocks`/`implements`, `supersedes` old to new unless declared, `resolves`
  to a finding, `addresses` from the newer node), plus the close rule over open `implements`
  children (ontology S2, `wv-76b361`). `wv link` and every close path refuse a violation;
  `wv doctor` reports stored ones.
- `delta-operation-v2.schema.json` defines immutable, integrity-checked semantic operations with
  field-level CAS across all six changeset arms (`node_create`/`node_patch`/`node_delete`,
  `edge_create`/`edge_patch`/`edge_delete`), each carrying a Lamport `lineage`.
- `checkpoint-generation-v1.schema.json` and `checkpoint-current-v1.schema.json` define immutable
  checkpoint pairs and their selector.
- `checkpoint-stage-v1.schema.json` defines the durable staged/published/selected recovery journal.
- `ownership-v1.json` states Git ownership independently of schema vocabulary.
- `host-hook-manifest-v1.json` is the Claude Code row of the host hook surface: each `.claude/hooks`
  script, the events it is registered for, and the one call it makes (a `scripts/lib` `wv_*`
  function or `wv hook dispatch`). Each hook body must equal its named template, and the templates
  hold the only approved fail-closed fallbacks (`wv-3f70a7`).
- `host-skill-allowlist-v1.json` admits a hand-written Claude Code skill beside the procedure
  projections, one node-linked entry per skill; it is empty. `tests/test-host-adapter-parity.sh`
  checks both files.

The current artifacts cover the bounded static contract: CLI observations exactly match mapped
operations and argv templates, bounded result cardinality is correlated to requests, and hook
identity is correlated structurally. Remaining exit work is dynamic: compare normalized fixtures
against live Bash output, then exercise fresh-clone, crash-recovery, and stale-delta durability
scenarios.

`evaluate_hook_policy` is pure: it cannot mutate graph state, phase files, `.weave/`, journals, or
Git. Git fetch/checkout/merge/add/commit/push remain host or CLI operations; GitHub projection is an
adapter operation. Mutation fallback is prohibited unless dispatch is known absent or a durable
shared idempotency key makes a retry safe.
