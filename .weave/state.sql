/* WARNING: Script requires that SQLITE_DBCONFIG_DEFENSIVE be disabled */
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
CREATE TABLE edges (
    source TEXT NOT NULL,
    target TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('blocks', 'relates_to', 'implements', 'contradicts', 'supersedes', 'references', 'obsoletes', 'addresses')),
    weight REAL DEFAULT 1.0,
    context JSON DEFAULT '{}',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(source, target, type),
    FOREIGN KEY(source) REFERENCES nodes(id),
    FOREIGN KEY(target) REFERENCES nodes(id)
);
PRAGMA writable_schema=ON;
INSERT INTO sqlite_schema(type,name,tbl_name,rootpage,sql)VALUES('table','nodes_fts','nodes_fts',0,'CREATE VIRTUAL TABLE nodes_fts USING fts5(
    id, text, metadata,
    content=nodes,
    content_rowid=rowid,
    tokenize=''porter unicode61''
)');
CREATE TABLE IF NOT EXISTS 'nodes_fts_data'(id INTEGER PRIMARY KEY, block BLOB);
INSERT INTO nodes_fts_data VALUES(1,X'');
INSERT INTO nodes_fts_data VALUES(10,X'00000000000000');
CREATE TABLE IF NOT EXISTS 'nodes_fts_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS 'nodes_fts_docsize'(id INTEGER PRIMARY KEY, sz BLOB);
CREATE TABLE IF NOT EXISTS 'nodes_fts_config'(k PRIMARY KEY, v) WITHOUT ROWID;
INSERT INTO nodes_fts_config VALUES('version',4);
CREATE TRIGGER nodes_ai AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_fts(rowid, id, text, metadata)
    VALUES (new.rowid, new.id, new.text, new.metadata);
END;
CREATE TRIGGER nodes_ad AFTER DELETE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata);
END;
CREATE TRIGGER nodes_au AFTER UPDATE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata);
    INSERT INTO nodes_fts(rowid, id, text, metadata)
    VALUES (new.rowid, new.id, new.text, new.metadata);
END;
CREATE INDEX idx_nodes_status ON nodes(status);
CREATE INDEX idx_nodes_priority ON nodes(priority);
CREATE INDEX idx_nodes_type ON nodes(type);
CREATE INDEX idx_nodes_type_priority ON nodes(type, priority);
CREATE UNIQUE INDEX idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL;
CREATE INDEX idx_edges_target ON edges(target);
CREATE INDEX idx_edges_type ON edges(type);
CREATE INDEX idx_edges_source_type ON edges(source, type);
CREATE INDEX idx_edges_target_type ON edges(target, type);
PRAGMA writable_schema=OFF;
COMMIT;
