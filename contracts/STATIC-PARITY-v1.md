# Static v1 Parity Matrix

| Review requirement | Enforcing artifact |
| --- | --- |
| Known operation and selected request/result schema | `validateRequest` / `validateResponse` in `tests/validate-ipc-contract.mjs` |
| Response correlation | Response `operation` and `request_id`; correlated fixture pairs |
| Repository, revision, durability, and bounds rules | Correlated validator plus negative repository/durability/bounds fixtures |
| Concrete read/policy shapes | `operation-payloads-v1.schema.json` and correlated fixtures |
| One handshake capability representation | `handshake_request` / `handshake_result` use protocol capability objects |
| Policy denial is a verdict, not an error | `operations-v1.json` policy error sets and `policy-v1.schema.json` |
| Hook event/revision/evidence correlation | Hook request/response fixtures and validator assertions |
| Authoritative error policy | `errors-v1.schema.json` wire shape plus `error-catalog-v1.json` |
| Registry/map structure and exact v1 operation count | `operations-v1.schema.json`, `cli-compat-v1.schema.json`, strict validator |
| Correct static CLI templates | `cli-compat-v1.json` and `tests/test-ipc-contract.sh` help assertions |

This matrix covers static contract mechanics only. Live Bash differential output capture and
fresh-clone/crash-recovery/stale-delta durability scenarios remain separate exit gates.
