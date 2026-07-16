import Ajv2020 from "../mcp/node_modules/ajv/dist/2020.js";
import addFormats from "../mcp/node_modules/ajv-formats/dist/index.js";
import fs from "node:fs";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { createHash } from "node:crypto";

const root = path.resolve(import.meta.dirname, "..");
const contracts = path.join(root, "contracts");
const fixtures = path.join(root, "tests/fixtures/ipc/v1");
const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const sha256 = text => createHash("sha256").update(text, "utf8").digest("hex");
const sha256File = file => createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const hasLoneSurrogate = value => {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) return true;
  }
  return false;
};
const canonicalize = value => {
  if (value === null) return "null";
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
  if (typeof value === "object") return `{${Object.keys(value).sort().map(key => {
    assert(!hasLoneSurrogate(key), "canonical JSON v1 rejects lone Unicode surrogates in object keys");
    return `${JSON.stringify(key)}:${canonicalize(value[key])}`;
  }).join(",")}}`;
  if (typeof value === "number") {
    assert(Number.isSafeInteger(value), "canonical JSON v1 only permits safe integers");
    assert(!Object.is(value, -0), "canonical JSON v1 rejects negative zero");
    return String(value);
  }
  if (typeof value === "string") {
    assert(!hasLoneSurrogate(value), "canonical JSON v1 rejects lone Unicode surrogates");
    return JSON.stringify(value);
  }
  if (typeof value === "boolean") return JSON.stringify(value);
  throw new Error(`unsupported canonical JSON value type ${typeof value}`);
};
const ajv = new Ajv2020({ strict: true, allErrors: true });
addFormats(ajv);
for (const name of fs.readdirSync(contracts).filter(name => name.endsWith(".schema.json"))) ajv.addSchema(read(path.join(contracts, name)));
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const canonicalJsonV1 = read(path.join(contracts, "canonical-json-v1.json"));
assert(canonicalJsonV1.standard === "RFC8785", "canonical JSON v1 must name RFC8785");
for (const vector of canonicalJsonV1.vectors) {
  assert(canonicalize(vector.value) === vector.canonical_utf8, "canonical JSON vector bytes mismatch");
  assert(sha256(vector.canonical_utf8) === vector.sha256, "canonical JSON vector hash mismatch");
}
for (const vector of canonicalJsonV1.invalid_vectors) {
  let rejected = false;
  let value;
  if (vector.input_json !== undefined) {
    try { value = JSON.parse(vector.input_json); } catch { rejected = true; }
  } else if (vector.construct === "lone_high_surrogate") value = String.fromCharCode(0xd800);
  else if (vector.construct === "negative_zero") value = -0;
  else throw new Error(`unknown invalid vector constructor ${vector.construct}`);
  if (!rejected) try { canonicalize(value); } catch { rejected = true; }
  assert(rejected, `canonical JSON invalid vector must reject ${vector.reason}`);
}
const validate = (schema, value, label) => { const fn = ajv.getSchema(schema); assert(fn, `missing schema ${schema}`); assert(fn(value), `${label}: ${ajv.errorsText(fn.errors)}`); };
const deltaOperationV2Schema = read(path.join(contracts, "delta-operation-v2.schema.json"));
const nodeFieldRegistry = read(path.join(contracts, "node-field-registry-v1.json"));
assert(nodeFieldRegistry.format === "weave.node-fields.v1", "node field registry format mismatch");
const registryFields = Object.keys(nodeFieldRegistry.fields).sort();
const deltaPatchFields = Object.keys(deltaOperationV2Schema.properties.payload.properties.mutation.properties.fields.properties).sort();
assert(isDeepStrictEqual(registryFields, deltaPatchFields), "Delta v2 patch fields must match node field registry");
assert(isDeepStrictEqual(nodeFieldRegistry.fields.status.value.enum, deltaOperationV2Schema.$defs.status_value.enum), "status registry/schema enum mismatch");
assert(isDeepStrictEqual(nodeFieldRegistry.fields.risk_level.value.enum, deltaOperationV2Schema.$defs.risk_level_value.enum), "risk_level registry/schema enum mismatch");
assert(isDeepStrictEqual(nodeFieldRegistry.fields.claimed_by.value.type, ["string", "null"]), "claimed_by registry type mismatch");
assert(nodeFieldRegistry.fields.risk_level.absent === "default:none", "risk_level absent value must normalize to none");
assert(deltaOperationV2Schema.$defs.claimed_by_value.oneOf.some(value => value.type === "string" && value.minLength === 1), "claimed_by schema must permit non-empty strings");
assert(deltaOperationV2Schema.$defs.claimed_by_value.oneOf.some(value => value.type === "null"), "claimed_by schema must permit null");
const validateDeltaOperationV2 = (value, label) => {
  validate("https://weave.dev/contracts/delta-operation-v2.schema.json", value, label);
  assert(value.canonicalization === "weave.canonical-json.v1", `${label}: unsupported canonicalization`);
  const hashPreimage = structuredClone(value);
  delete hashPreimage.operation_sha256;
  assert(value.operation_sha256 === sha256(canonicalize(hashPreimage)), `${label}: operation hash mismatch`);
};
const verifyCheckpointBundle = () => {
  const durability = path.join(fixtures, "durability");
  const bundle = path.join(durability, "checkpoint-bundle");
  const manifest = read(path.join(durability, "checkpoint-manifest.json"));
  const catalog = read(path.join(durability, "legacy-delta-catalog.json"));
  const bundleCatalog = read(path.join(bundle, "legacy-deltas/v1/catalog.json"));
  const generation = read(path.join(durability, "checkpoint-generation.json"));
  const current = read(path.join(durability, "checkpoint-current.json"));
  const stage = read(path.join(durability, "checkpoint-stage.json"));
  const bundleGeneration = read(path.join(bundle, "generation.json"));
  const bundleStage = read(path.join(bundle, "journal.json"));
  const bundleManifest = read(path.join(bundle, generation.manifest_path));
  const collectBundleFiles = directory => fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const absolute = path.join(directory, entry.name);
    const relative = path.relative(bundle, absolute);
    const stat = fs.lstatSync(absolute);
    assert(!stat.isSymbolicLink(), `checkpoint bundle contains symlink ${relative}`);
    if (stat.isDirectory()) return collectBundleFiles(absolute);
    assert(stat.isFile(), `checkpoint bundle contains non-regular entry ${relative}`);
    return [relative.split(path.sep).join("/")];
  });
  const expectedBundleFiles = [
    "generation.json",
    "journal.json",
    "legacy-deltas/v1/2026-07-16/100-legacy.sql",
    "legacy-deltas/v1/catalog.json",
    "manifest.json",
    "state.sql"
  ].sort();
  assert(isDeepStrictEqual(collectBundleFiles(bundle).sort(), expectedBundleFiles), "checkpoint bundle must contain exactly the generated artifacts");
  assert(isDeepStrictEqual(bundleManifest, manifest), "checkpoint bundle manifest must equal manifest fixture");
  assert(isDeepStrictEqual(bundleCatalog, catalog), "checkpoint bundle catalog must equal legacy catalog fixture");
  assert(isDeepStrictEqual(bundleGeneration, generation), "checkpoint bundle generation must equal generation fixture");
  assert(isDeepStrictEqual(bundleStage, stage), "checkpoint bundle journal must equal stage fixture");
  assert(generation.generation === manifest.generation, "generation/manifest id mismatch");
  assert(current.generation === manifest.generation, "current/manifest generation mismatch");
  assert(stage.generation === manifest.generation, "stage/manifest generation mismatch");
  assert(catalog.checkpoint_generation === manifest.generation, "catalog/manifest generation mismatch");
  assert(generation.state_sha256 === manifest.state_sha256, "generation/manifest state hash mismatch");
  assert(stage.state_sha256 === manifest.state_sha256, "stage/manifest state hash mismatch");
  assert(generation.manifest_sha256 === stage.manifest_sha256, "generation/stage manifest hash mismatch");
  assert(sha256File(path.join(bundle, generation.state_path)) === manifest.state_sha256, "checkpoint state hash mismatch");
  assert(sha256File(path.join(bundle, generation.manifest_path)) === generation.manifest_sha256, "checkpoint manifest hash mismatch");
  const archiveRoot = fs.realpathSync(path.join(bundle, "legacy-deltas/v1"));
  const catalogOriginalPaths = new Set();
  const catalogArchivedPaths = new Set();
  const catalogEntries = new Map();
  for (const entry of catalog.entries) {
    assert(!catalogOriginalPaths.has(entry.original_path), `duplicate catalog original_path ${entry.original_path}`);
    assert(!catalogArchivedPaths.has(entry.archived_path), `duplicate catalog archived_path ${entry.archived_path}`);
    catalogOriginalPaths.add(entry.original_path);
    catalogArchivedPaths.add(entry.archived_path);
    catalogEntries.set(entry.original_path, entry);
  }
  const manifestOriginalPaths = new Set();
  const manifestArchivedPaths = new Set();
  for (const [key, entry] of Object.entries(manifest.incorporated_legacy_deltas)) {
    assert(key === entry.original_path.replace(/^deltas\//, ""), `manifest key must match source-relative path for ${key}`);
    assert(!manifestOriginalPaths.has(entry.original_path), `duplicate manifest original_path ${entry.original_path}`);
    assert(!manifestArchivedPaths.has(entry.archived_path), `duplicate manifest archived_path ${entry.archived_path}`);
    manifestOriginalPaths.add(entry.original_path);
    manifestArchivedPaths.add(entry.archived_path);
    const catalogEntry = catalogEntries.get(entry.original_path);
    assert(catalogEntry, `manifest entry ${key} missing from legacy catalog`);
    assert(isDeepStrictEqual(catalogEntry, entry), `manifest/catalog entry mismatch for ${key}`);
    const archivedPath = path.resolve(bundle, entry.archived_path);
    const archivedStat = fs.lstatSync(archivedPath);
    assert(archivedStat.isFile() && !archivedStat.isSymbolicLink(), `archived delta must be a regular file for ${key}`);
    const archivedRealPath = fs.realpathSync(archivedPath);
    assert(archivedRealPath.startsWith(`${archiveRoot}${path.sep}`), `archived delta escapes archive root for ${key}`);
    assert(sha256File(archivedRealPath) === entry.raw_sha256, `archived delta hash mismatch for ${key}`);
  }
  assert(catalog.entries.length === Object.keys(manifest.incorporated_legacy_deltas).length, "legacy catalog has entries outside manifest coverage");
};

const errorPolicy = ajv.getSchema("https://weave.dev/contracts/errors-v1.schema.json#/$defs/error_policy");
assert(errorPolicy, "missing error policy schema");
const catalog = read(path.join(contracts, "error-catalog-v1.json"));
for (const entry of catalog.errors) assert(errorPolicy(entry), `catalog ${entry.code}: ${ajv.errorsText(errorPolicy.errors)}`);
for (const entry of catalog.errors) {
  const detail = ajv.getSchema(`https://weave.dev/contracts/errors-v1.schema.json#/$defs/${entry.detail_schema}`);
  assert(detail, `catalog ${entry.code}: missing detail schema ${entry.detail_schema}`);
  assert(detail({}), `catalog ${entry.code}: empty v1 detail must validate`);
}
const codes = new Set(catalog.errors.map(entry => entry.code));
assert(codes.size === 14, "error catalog must define every stable code exactly once");
const registry = read(path.join(contracts, "operations-v1.json"));
validate("https://weave.dev/contracts/operations-v1.schema.json", registry, "operation registry");
const names = new Set(registry.operations.map(operation => operation.name));
assert(names.size === registry.operations.length, "operation names must be unique");
const capabilities = new Set(registry.operations.map(operation => operation.capability));
assert(capabilities.size === registry.operations.length, "operation capabilities must be unique");
assert(registry.operations.every(operation => operation.pure === true), "v1 operations must be pure");
const payloads = ajv.getSchema("https://weave.dev/contracts/operation-payloads-v1.schema.json");
for (const operation of registry.operations) {
  assert(payloads.schema.$defs[operation.request_schema], `${operation.name} has missing request schema`);
  assert(payloads.schema.$defs[operation.result_schema], `${operation.name} has missing result schema`);
  assert(["none", "snapshot", "exact_revision"].includes(operation.consistency), `${operation.name} has invalid consistency`);
  assert(["none", "bounded", "required"].includes(operation.bounds), `${operation.name} has invalid bounds`);
  assert((operation.bounds === "none") === (operation.counted_result_field === undefined), `${operation.name}: counted result field must match bounds policy`);
  assert(operation.repository_required || operation.durability === "not_applicable", `${operation.name} cannot report repository durability`);
}
const validateRequest = (request, label) => {
  validate("https://weave.dev/contracts/protocol-v1.schema.json", request, `${label} envelope`);
  const operation = registry.operations.find(candidate => candidate.name === request.operation);
  assert(operation, `${label}: unsupported operation ${request.operation}`);
  assert(!operation.repository_required || request.repository, `${label}: repository required`);
  assert(operation.repository_required || !request.repository, `${label}: repository forbidden`);
  if (operation.consistency === "exact_revision") assert(request.expected_graph_revision !== null && request.expected_graph_revision !== undefined, `${label}: exact_revision requires expected_graph_revision`);
  const check = ajv.compile({ $ref: `https://weave.dev/contracts/operation-payloads-v1.schema.json#/$defs/${operation.request_schema}` });
  assert(check(request.payload), `${label}: ${ajv.errorsText(check.errors)}`);
  return operation;
};
const validateResponse = (request, response, label) => {
  validate("https://weave.dev/contracts/protocol-v1.schema.json", response, `${label} envelope`);
  const operation = validateRequest(request, label);
  assert(response.operation === request.operation && response.request_id === request.request_id, `${label}: response correlation mismatch`);
  if (response.result !== undefined) {
    const check = ajv.compile({ $ref: `https://weave.dev/contracts/operation-payloads-v1.schema.json#/$defs/${operation.result_schema}` });
    assert(check(response.result), `${label}: ${ajv.errorsText(check.errors)}`);
  } else assert(operation.errors.includes(response.error.code), `${label}: error not declared by operation`);
  const success = response.result !== undefined;
  if (success && operation.repository_required) assert(response.graph_revision === response.durability.graph_revision, `${label}: response/durability revision mismatch`);
  if (operation.name === "evaluate_hook_policy" && response.result !== undefined) {
    assert(response.result.event_id === request.payload.event.event_id, `${label}: verdict event mismatch`);
    assert(response.result.graph_revision === request.payload.event.graph_revision, `${label}: verdict graph revision mismatch`);
    assert(response.result.policy_revision === request.payload.event.policy_revision, `${label}: verdict policy revision mismatch`);
    assert(request.expected_graph_revision === request.payload.event.graph_revision, `${label}: expected/event revision mismatch`);
    assert(response.graph_revision === request.payload.event.graph_revision, `${label}: response/event revision mismatch`);
    const supplied = new Set(request.payload.evidence.map(evidence => evidence.evidence_id));
    assert(response.result.evidence_ids.every(id => supplied.has(id)), `${label}: verdict uses unknown evidence`);
    assert(isDeepStrictEqual(request.repository, request.payload.event.repository), `${label}: envelope/event repository mismatch`);
    assert(isDeepStrictEqual(request.actor, request.payload.event.actor), `${label}: envelope/event actor mismatch`);
    assert(request.session_id === request.payload.event.session_id, `${label}: envelope/event session mismatch`);
    assert(request.payload.event.evidence_ids.length === request.payload.evidence.length && request.payload.event.evidence_ids.every(id => supplied.has(id)), `${label}: event evidence mismatch`);
    assert(request.payload.evidence.every(evidence => isDeepStrictEqual(evidence.repository, request.repository)), `${label}: evidence repository mismatch`);
    assert(request.payload.evidence.every(evidence => evidence.policy_fingerprint === request.payload.event.policy_revision), `${label}: evidence policy fingerprint mismatch`);
  }
  if (operation.name === "durability_status" && success) assert(response.result.graph_revision === response.graph_revision, `${label}: durability result revision mismatch`);
  if (success) assert(operation.repository_required ? response.durability !== null && response.durability !== undefined : response.durability == null, `${label}: durability mismatch`);
  else {
    assert(response.bounds === undefined, `${label}: errors must not carry bounds`);
    if (response.error.code === "repository_mismatch") assert(response.durability == null && response.graph_revision == null, `${label}: repository mismatch must not report durability`);
    else assert((response.durability == null && response.graph_revision == null) || (response.durability != null && response.graph_revision === response.durability.graph_revision), `${label}: error durability/revision mismatch`);
  }
  if (success && (operation.bounds === "required" || operation.bounds === "bounded")) {
    assert(response.bounds, `${label}: bounds required`);
    assert(response.bounds.limit === request.payload.limit, `${label}: response/request limit mismatch`);
    assert(response.result[operation.counted_result_field].length === response.bounds.returned, `${label}: returned count mismatch`);
    assert(response.bounds.returned <= response.bounds.limit, `${label}: returned exceeds limit`);
    assert(response.bounds.total_known >= response.bounds.returned, `${label}: total known smaller than returned`);
  } else if (success) assert(response.bounds === undefined, `${label}: bounds forbidden`);
};
for (const required of ["handshake", "ping", "status", "bootstrap", "query_active_node", "query_nodes", "show", "context", "preflight", "evaluate_hook_policy", "graph_health", "durability_status"]) assert(names.has(required), `missing v1 operation ${required}`);
for (const operation of registry.operations) for (const code of operation.errors) assert(codes.has(code), `${operation.name} references unknown error ${code}`);
const observations = read(path.join(fixtures, "normalized/cli-observations.json")).observations;
for (const observation of observations) assert(names.has(observation.operation), `Bash observation maps unknown operation ${observation.operation}`);
const cli = read(path.join(contracts, "cli-compat-v1.json")).mappings;
validate("https://weave.dev/contracts/cli-compat-v1.schema.json", read(path.join(contracts, "cli-compat-v1.json")), "CLI compatibility map");
for (const mapping of cli) assert(names.has(mapping.operation) && Array.isArray(mapping.argv_template), `invalid CLI compatibility mapping ${mapping.operation}`);
assert(new Set(cli.map(mapping => mapping.operation)).size === cli.length, "CLI mappings must be unique");
assert(new Set(observations.map(observation => observation.operation)).size === observations.length, "CLI observations must be unique");
const mapped = registry.operations.filter(operation => operation.cli_mapping === "mapped").map(operation => operation.name);
assert(mapped.length === cli.length, "every mapped operation must have one CLI mapping");
assert(new Set(mapped).size === cli.length && mapped.every(operation => cli.some(mapping => mapping.operation === operation)), "CLI map must equal registry mapped set");
assert(new Set(cli.map(mapping => mapping.operation)).size === observations.length && observations.every(observation => cli.some(mapping => mapping.operation === observation.operation)), "CLI observations must equal CLI map");
for (const observation of observations) {
  const mapping = cli.find(candidate => candidate.operation === observation.operation);
  assert(isDeepStrictEqual(mapping.argv_template.slice(1), observation.argv), `${observation.operation}: CLI argv mismatch`);
}
validate("https://weave.dev/contracts/protocol-v1.schema.json", read(path.join(fixtures, "valid/handshake-request.json")), "valid handshake request");
const handshakeRequest = read(path.join(fixtures, "valid/handshake-request.json"));
validateRequest(handshakeRequest, "valid handshake request");
validateResponse(handshakeRequest, read(path.join(fixtures, "valid/handshake-response.json")), "handshake response");
validateResponse(read(path.join(fixtures, "valid/ping-request.json")), read(path.join(fixtures, "valid/ping-response.json")), "ping response");
validateResponse(read(path.join(fixtures, "valid/health-request.json")), read(path.join(fixtures, "valid/health-response.json")), "health response");
for (const name of ["unknown-operation-request.json", "status-without-repository.json"]) {
  let rejected = false;
  try { validateRequest(read(path.join(fixtures, "invalid", name)), name); } catch { rejected = true; }
  assert(rejected, `${name} must be rejected`);
}
validate("https://weave.dev/contracts/protocol-v1.schema.json", read(path.join(fixtures, "valid/unsupported-response.json")), "valid unsupported response");
assert(codes.has(read(path.join(fixtures, "valid/unsupported-response.json")).error.code), "wire error must resolve in authoritative catalog");
validateResponse(handshakeRequest, read(path.join(fixtures, "valid/unsupported-response.json"), "unsupported response"));
const statusRequest = read(path.join(fixtures, "valid/status-request.json"));
const statusResponse = read(path.join(fixtures, "valid/status-response.json"));
validate("https://weave.dev/contracts/protocol-v1.schema.json", statusRequest, "status request");
validate("https://weave.dev/contracts/protocol-v1.schema.json", statusResponse, "status response");
validateResponse(statusRequest, statusResponse, "status response");
validateResponse(statusRequest, read(path.join(fixtures, "valid/repository-mismatch-response.json")), "repository mismatch error response");
let missingDurability = false;
try { validateResponse(statusRequest, read(path.join(fixtures, "invalid/status-response-without-durability.json")), "missing durability"); } catch { missingDurability = true; }
assert(missingDurability, "repository response without durability must be rejected");
let missingBounds = false;
try { validateResponse(read(path.join(fixtures, "valid/context-request.json")), read(path.join(fixtures, "invalid/bounded-response-without-bounds.json")), "missing bounds"); } catch { missingBounds = true; }
assert(missingBounds, "bounded response without bounds must be rejected");
for (const [name, mutate] of [
  ["limit mismatch", value => { value.bounds.limit = 11; }],
  ["returned cardinality mismatch", value => { value.bounds.returned = 0; }],
  ["total smaller than returned", value => { value.bounds.total_known = 0; }],
  ["continuation without truncation", value => { value.bounds.continuation = "next"; }]
]) {
  const invalid = structuredClone(read(path.join(fixtures, "valid/query-nodes-response.json")));
  mutate(invalid);
  let rejected = false;
  try { validateResponse(read(path.join(fixtures, "valid/query-nodes-request.json")), invalid, name); } catch { rejected = true; }
  assert(rejected, `${name} must be rejected`);
}
const showRequest = read(path.join(fixtures, "valid/show-request.json"));
const showResponse = read(path.join(fixtures, "valid/show-response.json"));
validateResponse(showRequest, showResponse, "show response");
validateResponse(read(path.join(fixtures, "valid/bootstrap-request.json")), read(path.join(fixtures, "valid/bootstrap-response.json")), "bootstrap response");
validateResponse(read(path.join(fixtures, "valid/context-request.json")), read(path.join(fixtures, "valid/context-response.json")), "context response");
validateResponse(read(path.join(fixtures, "valid/preflight-request.json")), read(path.join(fixtures, "valid/preflight-response.json")), "preflight response");
const hookRequest = read(path.join(fixtures, "valid/hook-request.json"));
validateResponse(hookRequest, read(path.join(fixtures, "valid/hook-response.json")), "hook response");
const reorderedHookRequest = structuredClone(hookRequest);
reorderedHookRequest.payload.event.repository = read(path.join(fixtures, "valid/reordered-repository.json"));
validateResponse(reorderedHookRequest, read(path.join(fixtures, "valid/hook-response.json")), "hook reordered repository");
for (const name of ["hook-actor-mismatch.json", "hook-session-mismatch.json"]) {
  const mismatchRequest = structuredClone(hookRequest);
  Object.assign(mismatchRequest.payload.event, read(path.join(fixtures, "invalid", name)));
  let rejected = false;
  try { validateResponse(mismatchRequest, read(path.join(fixtures, "valid/hook-response.json")), name); } catch { rejected = true; }
  assert(rejected, `${name} must be rejected`);
}
validateResponse(read(path.join(fixtures, "valid/query-active-request.json")), read(path.join(fixtures, "valid/query-active-response.json")), "active-node response");
validateResponse(read(path.join(fixtures, "valid/query-nodes-request.json")), read(path.join(fixtures, "valid/query-nodes-response.json")), "node-query response");
validateResponse(read(path.join(fixtures, "valid/durability-request.json")), read(path.join(fixtures, "valid/durability-response.json")), "durability response");
let unknownHookEvidence = false;
try { validateResponse(hookRequest, read(path.join(fixtures, "invalid/hook-response-unknown-evidence.json")), "hook unknown evidence"); } catch { unknownHookEvidence = true; }
assert(unknownHookEvidence, "hook verdict evidence must be supplied by request");
const wireError = ajv.getSchema("https://weave.dev/contracts/errors-v1.schema.json#/$defs/wire_error");
assert(!wireError(read(path.join(fixtures, "invalid/wire-error-with-policy-fields.json"))), "wire errors must not duplicate catalog policy");
const bad = ajv.getSchema("https://weave.dev/contracts/protocol-v1.schema.json");
assert(!bad(read(path.join(fixtures, "invalid/response-with-result-and-error.json"))), "invalid response must be rejected");
validate("https://weave.dev/contracts/policy-v1.schema.json#/$defs/verdict", read(path.join(fixtures, "verdicts/deny-missing-evidence.json")), "verdict fixture");
validate("https://weave.dev/contracts/policy-v1.schema.json#/$defs/verdict", read(path.join(fixtures, "verdicts/allow-fresh-evidence.json")), "allow verdict fixture");
validate("https://weave.dev/contracts/policy-v1.schema.json#/$defs/verdict", read(path.join(fixtures, "verdicts/advisory-stale-evidence.json")), "advisory verdict fixture");
const verdict = ajv.getSchema("https://weave.dev/contracts/policy-v1.schema.json#/$defs/verdict");
assert(!verdict(read(path.join(fixtures, "invalid/verdict-unknown-reason-code.json"))), "unknown policy reason code must be rejected");
assert(!wireError(read(path.join(fixtures, "invalid/stale-revision-detail-opaque.json"))), "error detail must satisfy its code-specific schema");
validate("https://weave.dev/contracts/evidence-v1.schema.json", read(path.join(fixtures, "valid/evidence-unavailable.json")), "unavailable evidence fixture");
validate("https://weave.dev/contracts/durability-v1.schema.json#/$defs/durability_status", read(path.join(fixtures, "durability/serialized-local-only.json")), "durability fixture");
const durability = ajv.getSchema("https://weave.dev/contracts/durability-v1.schema.json#/$defs/durability_status");
assert(!durability(read(path.join(fixtures, "invalid/upstream-without-local-commit.json"))), "upstream confirmation without a matching local commit must be rejected");
const checkpointManifest = "https://weave.dev/contracts/checkpoint-manifest-v1.schema.json";
const legacyCatalog = "https://weave.dev/contracts/legacy-delta-catalog-v1.schema.json";
validate(checkpointManifest, read(path.join(fixtures, "durability/checkpoint-manifest.json")), "checkpoint manifest fixture");
validate(legacyCatalog, read(path.join(fixtures, "durability/legacy-delta-catalog.json")), "legacy delta catalog fixture");
const deltaOperationV2 = read(path.join(fixtures, "durability/delta-operation-v2.json"));
validateDeltaOperationV2(deltaOperationV2, "delta v2 fixture");
const deltaSchema = ajv.getSchema("https://weave.dev/contracts/delta-operation-v2.schema.json");
assert(!deltaSchema(read(path.join(fixtures, "invalid/delta-v2-bad-uuid.json"))), "Delta v2 must reject invalid UUIDs");
assert(!deltaSchema(read(path.join(fixtures, "invalid/delta-v2-bad-field.json"))), "Delta v2 must reject invalid typed field values");
const deltaBadHash = structuredClone(deltaOperationV2);
deltaBadHash.operation_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
let deltaHashRejected = false;
try { validateDeltaOperationV2(deltaBadHash, "delta bad payload hash"); } catch { deltaHashRejected = true; }
assert(deltaHashRejected, "Delta v2 hash must match canonical operation preimage");
for (const [field, mutate] of [
  ["operation_id", value => { value.operation_id = "018f0000-0000-7000-8000-000000000099"; }],
  ["actor_id", value => { value.actor_id = "replica-b"; }],
  ["actor_sequence", value => { value.actor_sequence = 43; }]
]) {
  const tampered = structuredClone(deltaOperationV2);
  mutate(tampered);
  let rejected = false;
  try { validateDeltaOperationV2(tampered, `delta tampered ${field}`); } catch { rejected = true; }
  assert(rejected, `Delta v2 hash must bind ${field}`);
}
validate("https://weave.dev/contracts/checkpoint-generation-v1.schema.json", read(path.join(fixtures, "durability/checkpoint-generation.json")), "checkpoint generation fixture");
validate("https://weave.dev/contracts/checkpoint-current-v1.schema.json", read(path.join(fixtures, "durability/checkpoint-current.json")), "checkpoint current fixture");
validate("https://weave.dev/contracts/checkpoint-stage-v1.schema.json", read(path.join(fixtures, "durability/checkpoint-stage.json")), "checkpoint stage fixture");
verifyCheckpointBundle();
const invalidCheckpoint = ajv.getSchema(checkpointManifest);
assert(!invalidCheckpoint(read(path.join(fixtures, "invalid/checkpoint-manifest-non-archived.json"))), "covered legacy SQL must be archived outside executable deltas");
const checkpointTraversal = structuredClone(read(path.join(fixtures, "durability/checkpoint-manifest.json")));
checkpointTraversal.generation = "..";
assert(!invalidCheckpoint(checkpointTraversal), "checkpoint generation must reject traversal-like names");
checkpointTraversal.generation = "0001";
checkpointTraversal.incorporated_legacy_deltas["2026-07-16/100-legacy.sql"].archived_path = "legacy-deltas/v1/../../state.sql";
assert(!invalidCheckpoint(checkpointTraversal), "checkpoint archive path must reject traversal");
console.log("IPC contract validation passed");
