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
INSERT INTO nodes VALUES('wv-7b1fe0','release: v1.41.0 public weave repo','todo',replace('{\n  "done_criteria": [\n    "commit, tag, push, GH release"\n  ],\n  "risks": [],\n  "risk_level": "low"\n}','\n',char(10)),NULL,'2026-04-18 18:25:10','2026-04-18 18:25:10');
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
