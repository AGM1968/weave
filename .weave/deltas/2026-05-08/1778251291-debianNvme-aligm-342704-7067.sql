UPDATE nodes SET alias=NULL WHERE alias='public-multi-dev-docs' AND id!='wv-689191';
INSERT INTO nodes(id,text,status,metadata,alias,created_at,updated_at) VALUES('wv-689191','docs: sync public multi-developer status wording with source repo','todo','{
  "done_criteria": [
    "public README and changelog reflect shipped delta merge, CAS claim enforcement, and unlink support"
  ],
  "risks": [],
  "risk_level": "low"
}','public-multi-dev-docs','2026-05-08 14:41:26','2026-05-08 14:41:26') ON CONFLICT(id) DO UPDATE SET text=excluded.text, status=excluded.status, metadata=excluded.metadata, alias=excluded.alias, updated_at=excluded.updated_at;
UPDATE nodes SET metadata='{
  "done_criteria": [
    "public README and changelog reflect shipped delta merge, CAS claim enforcement, and unlink support"
  ],
  "risks": [],
  "risk_level": "low",
  "gh_issue": 2
}',updated_at='2026-05-08 14:41:26' WHERE id='wv-689191';
