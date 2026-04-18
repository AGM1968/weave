INSERT INTO nodes(id,text,status,metadata,alias,created_at,updated_at) VALUES('wv-7b1fe0','release: v1.41.0 public weave repo','todo','{
  "done_criteria": [
    "commit, tag, push, GH release"
  ],
  "risks": [],
  "risk_level": "low"
}',NULL,'2026-04-18 18:25:10','2026-04-18 18:25:10') ON CONFLICT(id) DO UPDATE SET text=excluded.text, status=excluded.status, metadata=excluded.metadata, alias=excluded.alias, updated_at=excluded.updated_at;
