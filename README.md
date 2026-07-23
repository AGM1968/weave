# Weave

Weave is currently in maintenance mode while the upstream `memory-system` repository completes a
private evidence-hardening phase.

No new public feature release is planned until the private evidence gates are lifted. The active
work is to prove trusted capture, execution, durability, and host-verdict channels before expanding
public claims or mutation authority.

## Public Status

- Existing public releases remain available as-is.
- New public releases are limited to critical safety or durability fixes.
- Experimental mutation authority is not released.
- Experimental evidence fixtures are not product guarantees.
- Internal graph state, transcripts, host session exports, and evidence-lab artifacts are not part of
  the public release surface.

## Current Internal Gates

The upstream project is intentionally fail-closed:

- E5 workflow evidence requires a trusted capture runner before workflows count.
- E6 durability evidence requires a trusted execution runner before cases pass.
- E2 dispatched remediation evidence requires an IPC verdict shape with `policy_revision`,
  `reason_codes[]`, and `evidence_ids[]`.
- E7 shadow evaluation depends on authoritative E2, E3, and E6 corpora.

Until those gates close, the public channel should be treated as stable/archival rather than an
active feature stream.

## Maintenance Fixes

The current maintenance projection is limited to:

- skipping legacy pre-checkpoint SQL deltas correctly when the checkpoint `updated_at` value is an
  ISO timestamp rather than a numeric epoch;
- publishing this maintenance/freeze notice;
- keeping private E1/E2/E4/E5/E6 evidence gate suites and fixtures out of the public release
  bundle.

## Existing Users

If you already use Weave, keep using the release you have unless you need a specific safety fix.

For private/internal deployments from the upstream source repository, update via the source clone and
then refresh consumer repositories:

```bash
cd /path/to/memory-system
git pull --ff-only
./install.sh

cd /path/to/consumer-repo
wv init-repo --agent=all --update
wv load
wv bootstrap --json
```

Use `--agent=claude`, `--agent=codex`, or `--agent=copilot` instead of `--agent=all` when a consumer
repo should receive only one host surface.

## Archive Direction

The public repository may move to an archival posture once the private replacement path is proven.
That decision should happen after the trusted evidence gates and internal SSH-machine distribution
path are stable.
