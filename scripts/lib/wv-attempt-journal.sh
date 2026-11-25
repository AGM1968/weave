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

# Journal and marker directories are created through the hot-zone base guard
# (wv-80be32). wv loads the resolver first; a caller sourcing this file alone
# gets it from beside this file (it has no side effects on source).
if ! declare -F hot_zone_ensure >/dev/null; then
    # shellcheck source=/dev/null
    . "${BASH_SOURCE[0]%/*}/wv-resolve-runtime.sh"
fi

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
_WV_ATTEMPT_POLICY_IDENTITY=""
_WV_ATTEMPT_POLICY_SCHEMA=""

wv_json_escape() {
    local value="${1:-}" result="" char escaped index code
    # Nothing to escape: no backslash, no quote, no control character (every
    # code below 32 is [:cntrl:] in every locale). The loop below would copy
    # such a value unchanged one character at a time (wv-2ddb44).
    case "$value" in
        *[\\\"[:cntrl:]]*) ;;
        *) printf '%s' "$value"; return 0 ;;
    esac
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
# the one answer this must never get wrong. One line per verdict, naming its rule.
_wv_attempt_verdict_marker() {
    printf '%s/attempt-verdicts/%s' "${WV_HOT_ZONE:-${TMPDIR:-/tmp}}" "${_WV_ATTEMPT_CALL_ID:-unknown}"
}

wv_attempt_verdict_count() {
    local marker
    marker=$(_wv_attempt_verdict_marker)
    [ -f "$marker" ] || { printf 0; return 0; }
    wc -l < "$marker" | tr -d ' '
}

# The rules this call recorded a verdict for, sorted and unique, one per line.
wv_attempt_evaluated_rules() {
    local marker
    marker=$(_wv_attempt_verdict_marker)
    [ -f "$marker" ] || return 0
    sort -u "$marker"
}

# wv_attempt_verdicts_claim — take the marker for this call_id, exclusively.
#
# The marker is keyed only by call_id, so two calls sharing an id -- a harness
# pinning WV_CALL_ID for concurrent calls, or a crashed call's id reused -- would
# otherwise append to one file and each report the other's verdicts as its own.
# Creating it with O_EXCL makes the second claimant fail instead of merging. In
# evidence mode that ends the call; in analytics mode journaling is suppressed
# for this call, since an event under a shared id is worse than no event.
wv_attempt_verdicts_claim() {
    local marker
    wv_attempt_journal_enabled || return 0
    marker=$(_wv_attempt_verdict_marker)
    if { hot_zone_ensure "${marker%/*}" && (set -o noclobber; : > "$marker"); } 2>/dev/null; then
        return 0
    fi
    if [ -e "$marker" ]; then
        _WV_JOURNAL_SUPPRESSED=1
        _wv_attempt_fail "call_id $_WV_ATTEMPT_CALL_ID is already held by another call; refusing to merge its verdict evidence"
    else
        _wv_attempt_fail "attempt verdict marker could not be created at $marker"
    fi
    return 1
}

_wv_attempt_rules_json() {
    local rule first=1
    printf '['
    for rule in $1; do
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '"%s"' "$(wv_json_escape "$rule")"
    done
    printf ']'
}

# Rules the journal itself holds a policy_verdict for under this call_id.
_wv_attempt_journaled_rules() {
    local path
    path=$(wv_attempt_journal_path) || return 0
    [ -f "$path" ] || return 0
    grep -F "\"call_id\":\"$_WV_ATTEMPT_CALL_ID\"" "$path" | grep -F '"event":"policy_verdict"' |
        sed -n 's/.*"rule":"\([a-z0-9_]*\)".*/\1/p' | sort -u
}

# wv_attempt_policy_json — the call's policy provenance, for call_completed.
#
# A call with no verdict is NOT an allow. applicable_rules is what the policy
# contract says can decide inside this operation (the generated
# _wv_policy_applicable); evaluated_rules is what this call recorded a verdict
# for. The call is countable only when the two are equal, the journal itself
# holds a verdict for every evaluated rule -- derived from the journal, not
# taken from the marker's word -- and it ran in evidence mode, where no write
# that failed can have been swallowed.
wv_attempt_policy_json() {
    local verdicts applicable evaluated journaled extra missing state reason countable=false
    verdicts=$(wv_attempt_verdict_count)
    evaluated=$(wv_attempt_evaluated_rules)
    journaled=$(_wv_attempt_journaled_rules)
    if declare -F _wv_policy_applicable >/dev/null; then
        applicable=$(_wv_policy_applicable "$_WV_ATTEMPT_OPERATION" "$_WV_ATTEMPT_SUBOPERATION" |
            tr ' ' '\n' | sed '/^$/d' | sort -u)
        extra=$(comm -13 <(printf '%s\n' "$applicable" | sed '/^$/d') <(printf '%s\n' "$evaluated" | sed '/^$/d'))
        missing=$(comm -23 <(printf '%s\n' "$applicable" | sed '/^$/d') <(printf '%s\n' "$evaluated" | sed '/^$/d'))
    else
        applicable="" extra="" missing=""
        state="inconsistent"
        reason="no policy projection was loaded, so the applicable rule set is unknown"
    fi
    if [ -n "${state:-}" ]; then
        :
    elif [ -n "$extra" ]; then
        state="inconsistent"
        reason="verdicts were recorded for rules the policy contract does not apply to this operation: ${extra//$'\n'/ }"
    elif [ "$journaled" != "$evaluated" ]; then
        state="inconsistent"
        reason="the verdict marker and the journal disagree about which rules this call evaluated"
    elif [ -n "$missing" ] && [ "${verdicts:-0}" -eq 0 ]; then
        state="unavailable"
        reason="no applicable rule recorded a verdict for this call, so silence is not an allow: ${missing//$'\n'/ }"
    elif [ -n "$missing" ]; then
        state="partial"
        reason="applicable rules left no verdict for this call: ${missing//$'\n'/ }"
    else
        state="complete"
        if ! wv_attempt_evidence_mode; then
            reason="every applicable rule recorded a verdict, but outside evidence mode a failed write is swallowed, so the call is not countable"
        elif [ -n "$applicable" ]; then
            countable=true
            reason="every rule the policy contract applies to this operation recorded a durable verdict"
        else
            countable=true
            reason="the policy contract (policy_identity) applies no in-call rule to this operation"
        fi
    fi
    printf '{"state":"%s","countable":%s,"verdicts":%s,"applicable_rules":%s,"evaluated_rules":%s,"reason":"%s"}' \
        "$state" "$countable" "${verdicts:-0}" "$(_wv_attempt_rules_json "$applicable")" \
        "$(_wv_attempt_rules_json "$evaluated")" "$(wv_json_escape "$reason")"
}

# wv_attempt_verdicts_reset — release this call's marker. A marker that cannot be
# removed is reported, not ignored: it would block the id rather than leak into
# the next call (the claim is exclusive), but it is still a write that failed.
wv_attempt_verdicts_reset() {
    local marker
    wv_attempt_journal_enabled || return 0
    [ -n "${_WV_JOURNAL_SUPPRESSED:-}" ] && return 0
    marker=$(_wv_attempt_verdict_marker)
    rm -f "$marker" 2>/dev/null
    if [ -e "$marker" ]; then
        _wv_attempt_fail "attempt verdict marker could not be removed at $marker"
        return 1
    fi
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
    # The policy contract binds separately from the capability registry: one says
    # what an operation touches, the other what may refuse it, and a reader must
    # be able to tell which of the two changed between calls.
    _WV_ATTEMPT_POLICY_IDENTITY="${14:-}"
    _WV_ATTEMPT_POLICY_SCHEMA="${15:-}"
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
        non_policy_refusal) printf 'category detail' ;;
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
    local required field pair key value body="" path line rule=""
    wv_attempt_journal_enabled || return 0
    [ -n "${_WV_JOURNAL_SUPPRESSED:-}" ] && return 0
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
                [ "$key" = "rule" ] && rule="$value"
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

    line=$(printf '{"format":"%s","event":"%s","ts":"%s","call_id":"%s","parent_call_id":%s,"workflow_id":"%s","trace_id":"%s","source":"%s","repo_root":"%s","operation":"%s","suboperation":"%s","evidence_class":"%s","mutation_targets":%s,"registry_identity":"%s","registry_schema":"%s","policy_identity":"%s","policy_schema":"%s","causal_identity_before":%s%s}' \
        "$WV_ATTEMPT_JOURNAL_FORMAT" "$event" "$(wv_now us)" \
        "$(wv_json_escape "$_WV_ATTEMPT_CALL_ID")" "$parent_json" "$(wv_json_escape "$_WV_ATTEMPT_WORKFLOW_ID")" \
        "$(wv_json_escape "$_WV_ATTEMPT_TRACE_ID")" "$(wv_json_escape "$_WV_ATTEMPT_SOURCE")" \
        "$(wv_json_escape "$_WV_ATTEMPT_REPO_ROOT")" "$(wv_json_escape "$_WV_ATTEMPT_OPERATION")" \
        "$(wv_json_escape "$_WV_ATTEMPT_SUBOPERATION")" "$(wv_json_escape "$_WV_ATTEMPT_EVIDENCE_CLASS")" \
        "${_WV_ATTEMPT_TARGETS:-[]}" "$(wv_json_escape "$_WV_ATTEMPT_REGISTRY_IDENTITY")" \
        "$(wv_json_escape "$_WV_ATTEMPT_REGISTRY_SCHEMA")" "$(wv_json_escape "$_WV_ATTEMPT_POLICY_IDENTITY")" \
        "$(wv_json_escape "$_WV_ATTEMPT_POLICY_SCHEMA")" "${_WV_ATTEMPT_CAUSAL_BEFORE:-null}" "$body")

    if ! { hot_zone_ensure "${path%/*}" && printf '%s\n' "$line" >> "$path"; } 2>/dev/null; then
        _wv_attempt_fail "attempt journal write failed at $path"
        return 1
    fi
    # The marker follows the durable journal line, never precedes it, so a rule
    # it names is one the journal already holds. A marker that cannot be written
    # would under-report the evaluated set, so it fails like the journal write.
    if [ "$event" = "policy_verdict" ]; then
        local marker
        marker=$(_wv_attempt_verdict_marker)
        if ! printf '%s\n' "$rule" >> "$marker" 2>/dev/null; then
            _wv_attempt_fail "attempt verdict marker write failed at $marker"
            return 1
        fi
    fi
    return 0
}

# wv_policy_verdict <rule_id> <decision> <would_violate_invariant> [bypass] [detail] [clause-json]
#
# What a gate records when it decides. rule_id is a contracts/policy-rules-v1.json
# rule, never a function name or a message, and scripts/weave_policy.py requires
# every command-gate rule to reach this at its declared site. A bypassed gate
# records the decision it made (allow) with the flag or knob that caused it, so
# an override is evidence rather than silence. clause is the typed values a
# SQLite-owned rule decided on, copied from the close receipt. The result is
# returned, never discarded: in evidence mode the emitter fails the call closed.
wv_policy_verdict() {
    local rule="$1" decision="$2" invariant="$3" bypass="${4:-}" detail="${5:-}" clause="${6:-}"
    local fields=("rule=$rule" "decision=$decision" "would_violate_invariant=$invariant")
    [ -n "$bypass" ] && fields+=("bypass=$bypass")
    [ -n "$detail" ] && fields+=("detail=$detail")
    [ -n "$clause" ] && fields+=("clause:=$clause")
    wv_attempt_emit policy_verdict "${fields[@]}"
}

# wv_policy_refusal <category> <detail>
#
# A refusal that is not a policy decision: input_validation, expected_conflict
# or infrastructure_failure (contracts/policy-rules-v1.json non_policy_categories).
# Recording it is what keeps a malformed argument or a lost race from being
# counted as a counterweight event, or from vanishing.
wv_policy_refusal() {
    wv_attempt_emit non_policy_refusal "category=$1" "detail=$2"
}
