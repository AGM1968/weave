PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE nodes (
    id TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    status TEXT DEFAULT 'todo',
    metadata JSON DEFAULT '{}',
    alias TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    -- Virtual columns for O(1) metadata filtering (Tier 1)
    priority INTEGER GENERATED ALWAYS AS (json_extract(metadata, '$.priority')) VIRTUAL,
    type TEXT GENERATED ALWAYS AS (json_extract(metadata, '$.type')) VIRTUAL
);
INSERT INTO nodes VALUES('wv-7b1fe0','release: v1.41.0 public weave repo','done','{"done_criteria":["commit, tag, push, GH release"],"risks":[],"risk_level":"low","decision":"split commit into 2 (initial wv-state + full bundle) due to wv work auto-sync clobbering staged state; both pushed cleanly. pattern: build-release.sh outputs to public repo; commit/tag/push/release in that working dir not memory-system. pitfall: pre-action hook checks active node in cwd, not source — must claim a node in the public repo too.","learning_hygiene":4}',NULL,'2026-04-18 18:25:10','2026-04-18 18:26:53');
COMMIT;
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE edges (
    source TEXT NOT NULL,
    target TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('blocks', 'relates_to', 'implements', 'contradicts', 'supersedes', 'references', 'obsoletes', 'addresses', 'resolves')),
    weight REAL DEFAULT 1.0,
    context JSON DEFAULT '{}',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(source, target, type),
    FOREIGN KEY(source) REFERENCES nodes(id),
    FOREIGN KEY(target) REFERENCES nodes(id)
);
COMMIT;
