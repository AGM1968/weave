# Weave IPC Contract v1

This directory is the machine-readable contract for the bounded v1 read/policy slice. It is not a
service implementation and it does not advertise mutation support.

- `protocol-v1.schema.json` defines envelopes, repository identity, bounds, and capabilities.
- `errors-v1.schema.json` defines stable machine errors and code-discriminated detail shapes; `error-catalog-v1.json` supplies every policy.
- `policy-reason-catalog-v1.json` is the separate stable vocabulary for policy verdict reasons.
- `hook-events-v1.schema.json` and `policy-v1.schema.json` define pure hook evaluation.
- `durability-v1.schema.json` distinguishes revision-scoped graph serialization from Git durability.
- `checkpoint-manifest-v1.schema.json` binds a checkpoint to `state.sql` and records covered legacy SQL by raw hash.
- `legacy-delta-catalog-v1.schema.json` preserves covered legacy SQL as non-executable audit evidence.
- `canonical-json-v1.json` defines the canonical byte form used for Delta v2 operation hashes.
- `node-field-registry-v1.json` defines the semantic node fields available to Delta v2 CAS patches.
- `delta-operation-v2.schema.json` defines immutable, integrity-checked semantic operations with field-level CAS.
- `checkpoint-generation-v1.schema.json` and `checkpoint-current-v1.schema.json` define immutable checkpoint pairs and their selector.
- `checkpoint-stage-v1.schema.json` defines the durable staged/published/selected recovery journal.
- `ownership-v1.json` states Git ownership independently of schema vocabulary.

The current artifacts cover the bounded static contract: CLI observations exactly match mapped
operations and argv templates, bounded result cardinality is correlated to requests, and hook identity
is correlated structurally. Remaining exit work is dynamic: compare normalized fixtures against live
Bash output, then exercise fresh-clone, crash-recovery, and stale-delta durability scenarios.

`evaluate_hook_policy` is pure: it cannot mutate graph state, phase files, `.weave/`, journals, or
Git. Git fetch/checkout/merge/add/commit/push remain host or CLI operations; GitHub projection is an
adapter operation. Mutation fallback is prohibited unless dispatch is known absent or a durable shared
idempotency key makes a retry safe.
