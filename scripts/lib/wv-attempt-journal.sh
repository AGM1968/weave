#!/bin/bash
# wv-attempt-journal.sh — durable attempt journal (append-only JSONL)
#
# Sourced by: wv entry point (after wv-config.sh and the capability projection)
# Contract:   contracts/attempt-journal-v1.schema.json
#
# NOT the ops journal (wv-journal.sh). That one records multi-step intentions in
# the hot zone so an interrupted operation can be resumed; it is about recovery.
# This one records what was attempted, under which contract, against which causal
# state, and how it ended. It is about evidence, and its readers are E1 and the
# adjudication overlay rather than wv recover.
#
# ONE EMITTER. Every event goes through wv_attempt_emit, which builds the common
# envelope from context set once per call and refuses an event missing a field
# its type requires. Call sites pass only what they alone know. The first version
# of this file let each call site assemble its own JSON, and the gate that did so
# emitted a verdict with no envelope at all -- every classification and identity
# field null -- which is precisely the shape a reader cannot use.
#
# FAIL CLOSED IS THE EMITTER'S JOB, NOT THE CALLER'S. Under WV_EVIDENCE_MODE=1 a
# write that cannot be made ends the call from here. A caller cannot opt out by
# discarding the return value, because the first version's gate did exactly that
# (`2>/dev/null || true`) and would have lost the decisive event of the call.
#
# CRASH SEMANTICS. call_started is written before dispatch and says
# disposition=incomplete. A process killed mid-call therefore leaves an explicit
# incomplete attempt rather than no record: absence of call_completed is the
# signal, and it cannot be confused with "no attempt was made".
#
# TWO MODES.
#   analytics (default)  journaling happens when WV_ATTEMPT_JOURNAL names a path;
#                        a write failure is swallowed, exactly like the call log.
#   evidence             WV_EVIDENCE_MODE=1 makes journaling mandatory: the path
#                        must resolve and every write must succeed, or the call
#                        fails closed. Evidence that may silently not be written
#                        is not evidence.

[ -n "${_WV_ATTEMPT_JOURNAL_LOADED:-}" ] && return 0
_WV_ATTEMPT_JOURNAL_LOADED=1

WV_ATTEMPT_JOURNAL_FORMAT="weave.attempt-journal.v1"

# Envelope fields, in emission order. Set by wv_attempt_context before dispatch.
_WV_ATTEMPT_CALL_ID=""
_WV_ATTEMPT_WORKFLOW_ID=""
_WV_ATTEMPT_TRACE_ID=""
_WV_ATTEMPT_SOURCE=""
_WV_ATTEMPT_REPO_ROOT=""
_WV_ATTEMPT_OPERATION=""
_WV_ATTEMPT_SUBOPERATION=""
_WV_ATTEMPT_EVIDENCE_CLASS=""
_WV_ATTEMPT_TARGETS="[]"
_WV_ATTEMPT_REGISTRY_IDENTITY=""
_WV_ATTEMPT_REGISTRY_SCHEMA=""
_WV_ATTEMPT_CAUSAL_BEFORE=""
_WV_ATTEMPT_PARENT_CALL_ID=""

wv_json_escape() {
    local value="${1:-}" result="" char escaped index code
    for ((index = 0; index < ${#value}; index++)); do
        char="${value:index:1}"
        case "$char" in
            \\) result+='\\' ;;
            '"') result+='\"' ;;
            $'\b') result+='\b' ;;
            $'\f') result+='\f' ;;
            $'\n') result+='\n' ;;
            $'\r') result+='\r' ;;
            $'\t') result+='\t' ;;
            *)
                printf -v code '%d' "'$char"
                if [ "$code" -lt 32 ]; then
                    printf -v escaped '\\u%04x' "$code"
                    result+="$escaped"
                else
                    result+="$char"
                fi
                ;;
        esac
    done
    printf '%s' "$result"
}

# Evidence mode has no default path on purpose: falling back to a shared default
# would let two repositories interleave attempts into one file and call it a
# ledger.
wv_attempt_journal_path() {
    [ -n "${WV_ATTEMPT_JOURNAL:-}" ] || return 1
    printf '%s' "$WV_ATTEMPT_JOURNAL"
}

wv_attempt_journal_enabled() {
    [ -n "${WV_ATTEMPT_JOURNAL:-}" ] || [ "${WV_EVIDENCE_MODE:-0}" = "1" ]
}

wv_attempt_evidence_mode() {
    [ "${WV_EVIDENCE_MODE:-0}" = "1" ]
}

# Marker file, not a shell variable: a gate that runs inside a command
# substitution increments a counter its parent never sees, and "no verdict" is
# the one answer this must never get wrong.
_wv_attempt_verdict_marker() {
    printf '%s/attempt-verdicts/%s' "${WV_HOT_ZONE:-${TMPDIR:-/tmp}}" "${_WV_ATTEMPT_CALL_ID:-unknown}"
}

wv_attempt_verdict_count() {
    local marker
    marker=$(_wv_attempt_verdict_marker)
    [ -f "$marker" ] || { printf 0; return 0; }
    wc -l < "$marker" | tr -d ' '
}

wv_attempt_verdicts_reset() {
    rm -f "$(_wv_attempt_verdict_marker)" 2>/dev/null || true
}

wv_attempt_context() {
    _WV_ATTEMPT_CALL_ID="$1"
    _WV_ATTEMPT_WORKFLOW_ID="$2"
    _WV_ATTEMPT_TRACE_ID="$3"
    _WV_ATTEMPT_SOURCE="$4"
    _WV_ATTEMPT_REPO_ROOT="$5"
    _WV_ATTEMPT_OPERATION="$6"
    _WV_ATTEMPT_SUBOPERATION="$7"
    _WV_ATTEMPT_EVIDENCE_CLASS="$8"
    _WV_ATTEMPT_TARGETS="$9"
    _WV_ATTEMPT_REGISTRY_IDENTITY="${10}"
    _WV_ATTEMPT_REGISTRY_SCHEMA="${11}"
    _WV_ATTEMPT_CAUSAL_BEFORE="${12}"
    # Empty for a root call, the enclosing call's id for a nested one. Nullable
    # rather than optional: a reader must be able to tell "this call had no
    # parent" from "this writer did not record parents", which is the difference
    # between a complete tree and an unknown one.
    _WV_ATTEMPT_PARENT_CALL_ID="${13:-}"
    export _WV_ATTEMPT_CALL_ID
}

# Fields each event type must supply beyond the envelope. Kept here and in
# contracts/attempt-journal-v1.schema.json, and the suite requires the two to
# agree: the schema is what a reader validates against, this is what stops a bad
# event being written in the first place.
_wv_attempt_required_fields() {
    case "$1" in
        call_started) printf 'argv disposition' ;;
        policy_verdict) printf 'decision rule would_violate_invariant' ;;
        mutation_disposition) printf 'causal_identity_after disposition exit_status' ;;
        call_completed) printf 'causal_identity_after disposition elapsed_ms exit_status policy' ;;
        *) return 1 ;;
    esac
}

_wv_attempt_fail() {
    local message="$1"
    if wv_attempt_evidence_mode; then
        _WV_JOURNAL_BROKEN=1
        echo "wv: $message" >&2
        echo "wv: evidence mode requires every attempt-journal write to succeed; failing the call closed" >&2
        exit 1
    fi
    return 1
}

# wv_attempt_emit <event> [key=string | key:=raw-json]...
#
# The envelope is added here. A caller passing an unknown event, or omitting a
# field that event requires, is a defect in the caller and is treated as one.
wv_attempt_emit() {
    local event="$1"; shift
    local required field pair key value body="" path line
    wv_attempt_journal_enabled || return 0
    [ -n "${_WV_JOURNAL_BROKEN:-}" ] && return 1

    if ! required=$(_wv_attempt_required_fields "$event"); then
        _wv_attempt_fail "attempt journal received unknown event '$event'"
        return 1
    fi
    if [ -z "${_WV_ATTEMPT_CALL_ID:-}" ]; then
        _wv_attempt_fail "attempt journal event '$event' emitted before the call context was set"
        return 1
    fi

    for pair in "$@"; do
        case "$pair" in
            *:=*)
                key="${pair%%:=*}"; value="${pair#*:=}"
                body+=",\"$key\":$value"
                ;;
            *=*)
                key="${pair%%=*}"; value="${pair#*=}"
                body+=",\"$key\":\"$(wv_json_escape "$value")\""
                ;;
            *)
                _wv_attempt_fail "attempt journal field '$pair' is neither key=value nor key:=json"
                return 1
                ;;
        esac
    done
    for field in $required; do
        case "$body" in
            *"\"$field\":"*) ;;
            *)
                _wv_attempt_fail "attempt journal event '$event' is missing required field '$field'"
                return 1
                ;;
        esac
    done

    if ! path=$(wv_attempt_journal_path); then
        _wv_attempt_fail "evidence mode requires WV_ATTEMPT_JOURNAL to name a journal path"
        return 1
    fi

    local parent_json="null"
    [ -n "${_WV_ATTEMPT_PARENT_CALL_ID:-}" ] &&
        parent_json="\"$(wv_json_escape "$_WV_ATTEMPT_PARENT_CALL_ID")\""

    line=$(printf '{"format":"%s","event":"%s","ts":"%s","call_id":"%s","parent_call_id":%s,"workflow_id":"%s","trace_id":"%s","source":"%s","repo_root":"%s","operation":"%s","suboperation":"%s","evidence_class":"%s","mutation_targets":%s,"registry_identity":"%s","registry_schema":"%s","causal_identity_before":%s%s}' \
        "$WV_ATTEMPT_JOURNAL_FORMAT" "$event" "$(date +%s.%6N)" \
        "$(wv_json_escape "$_WV_ATTEMPT_CALL_ID")" "$parent_json" "$(wv_json_escape "$_WV_ATTEMPT_WORKFLOW_ID")" \
        "$(wv_json_escape "$_WV_ATTEMPT_TRACE_ID")" "$(wv_json_escape "$_WV_ATTEMPT_SOURCE")" \
        "$(wv_json_escape "$_WV_ATTEMPT_REPO_ROOT")" "$(wv_json_escape "$_WV_ATTEMPT_OPERATION")" \
        "$(wv_json_escape "$_WV_ATTEMPT_SUBOPERATION")" "$(wv_json_escape "$_WV_ATTEMPT_EVIDENCE_CLASS")" \
        "${_WV_ATTEMPT_TARGETS:-[]}" "$(wv_json_escape "$_WV_ATTEMPT_REGISTRY_IDENTITY")" \
        "$(wv_json_escape "$_WV_ATTEMPT_REGISTRY_SCHEMA")" "${_WV_ATTEMPT_CAUSAL_BEFORE:-null}" "$body")

    if ! { mkdir -p "$(dirname "$path")" && printf '%s\n' "$line" >> "$path"; } 2>/dev/null; then
        _wv_attempt_fail "attempt journal write failed at $path"
        return 1
    fi
    if [ "$event" = "policy_verdict" ]; then
        local marker
        marker=$(_wv_attempt_verdict_marker)
        { mkdir -p "$(dirname "$marker")" && printf '%s\n' "$event" >> "$marker"; } 2>/dev/null || true
    fi
    return 0
}
