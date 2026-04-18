UPDATE nodes SET status='active',metadata='{"done_criteria":["commit, tag, push, GH release"],"risks":[],"risk_level":"low","claimed_by":"debian-alistair"}',updated_at='2026-04-18 18:25:17' WHERE id='wv-7b1fe0';
UPDATE nodes SET metadata='{
  "done_criteria": [
    "commit, tag, push, GH release"
  ],
  "risks": [],
  "risk_level": "low",
  "claimed_by": "debian-alistair",
  "decision": "split commit into 2 (initial wv-state + full bundle) due to wv work auto-sync clobbering staged state; both pushed cleanly. pattern: build-release.sh outputs to public repo; commit/tag/push/release in that working dir not memory-system. pitfall: pre-action hook checks active node in cwd, not source — must claim a node in the public repo too."
}',updated_at='2026-04-18 18:26:53' WHERE id='wv-7b1fe0';
UPDATE nodes SET metadata='{
  "done_criteria": [
    "commit, tag, push, GH release"
  ],
  "risks": [],
  "risk_level": "low",
  "claimed_by": "debian-alistair",
  "decision": "split commit into 2 (initial wv-state + full bundle) due to wv work auto-sync clobbering staged state; both pushed cleanly. pattern: build-release.sh outputs to public repo; commit/tag/push/release in that working dir not memory-system. pitfall: pre-action hook checks active node in cwd, not source — must claim a node in the public repo too.",
  "learning_hygiene": 4
}',updated_at='2026-04-18 18:26:53' WHERE id='wv-7b1fe0';
UPDATE nodes SET status='done',metadata='{"done_criteria":["commit, tag, push, GH release"],"risks":[],"risk_level":"low","decision":"split commit into 2 (initial wv-state + full bundle) due to wv work auto-sync clobbering staged state; both pushed cleanly. pattern: build-release.sh outputs to public repo; commit/tag/push/release in that working dir not memory-system. pitfall: pre-action hook checks active node in cwd, not source — must claim a node in the public repo too.","learning_hygiene":4}',updated_at='2026-04-18 18:26:53' WHERE id='wv-7b1fe0';
