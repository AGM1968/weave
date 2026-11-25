#!/usr/bin/env bash
# wv-clock.sh — durations on a clock that stops while the host is suspended
# (wv-b17a85, owner ruling (b) on wv-562ed6, 2026-11-15).
#
# A duration is the difference of two readings of one clock. The wall clock
# (date +%s%N) steps back on an NTP correction and runs on through a
# hibernation, so a gate the host slept through was recorded as hours long and
# its suites' medians drifted. Every reading here says which clock it came
# from, and a duration is only ever taken between two readings of the same one:
#
#   monotonic  CLOCK_MONOTONIC (python3 time.monotonic: Linux and macOS). Stops
#              while the host is suspended. The only kind cost estimates read.
#   boottime   /proc/uptime. Never steps back, but counts a suspend.
#   wall       date. Steps back and counts a suspend; durations are clamped
#              at 0.
#
# The monotonic reading costs one python3 process (about 14 ms), so it is
# taken where a gate starts and ends, never on a per-call hot path; scripts/wv
# times each call on /proc/uptime and declares it boottime.
#
# Readings are milliseconds. Ids and timestamps are not durations: they stay on
# the wall clock and do not use this file.
#
# Test seam: under WV_TEST_SUITE=1, WV_CLOCK_TEST_FILE names a file of
# "<ms> <kind>" lines; each reading takes the first line and removes it, so a
# test can make two clocks diverge mid-interval or step one back.

# Wall-clock readings come from wv_now in the resolver, beside this file
# (BSD date prints %N literally, wv-99f296); it has no side effects on source.
if ! declare -F wv_now >/dev/null; then
    # shellcheck source=scripts/lib/wv-resolve-runtime.sh
    . "${BASH_SOURCE[0]%/*}/wv-resolve-runtime.sh"
fi

# wv_clock_ms <ms-var> <kind-var> — one reading of the best clock available.
wv_clock_ms() {
    local _wc_v="" _wc_k="" _wc_u _wc_rest
    if [ "${WV_TEST_SUITE:-}" = 1 ] && [ -n "${WV_CLOCK_TEST_FILE:-}" ]; then
        if read -r _wc_v _wc_k < "$WV_CLOCK_TEST_FILE" 2>/dev/null; then
            _wc_rest=$(tail -n +2 "$WV_CLOCK_TEST_FILE")
            printf '%s\n' "$_wc_rest" | sed '/^$/d' > "$WV_CLOCK_TEST_FILE"
        fi
    else
        _wc_v=$(python3 -I -S -c 'import time; print(time.monotonic_ns() // 1000000)' 2>/dev/null) \
            && _wc_k=monotonic
        if ! [[ "$_wc_v" =~ ^[0-9]+$ ]]; then
            _wc_v="" _wc_k=""
            if read -r _wc_u _ 2>/dev/null < /proc/uptime && [[ "$_wc_u" =~ ^([0-9]+)\.([0-9]{2})$ ]]; then
                _wc_v=$(( 10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]} * 10 ))
                _wc_k=boottime
            else
                _wc_v=$(wv_now ms 2>/dev/null)
                _wc_k=wall
            fi
        fi
    fi
    case "$_wc_k" in monotonic|boottime|wall) ;; *) _wc_k=unknown ;; esac
    [[ "$_wc_v" =~ ^[0-9]+$ ]] || { _wc_v=0; _wc_k=unknown; }
    printf -v "$1" '%s' "$_wc_v"
    printf -v "$2" '%s' "$_wc_k"
}

# wv_clock_since <ms-var> <kind-var> <start-ms> <start-kind> — the time since
# a wv_clock_ms reading, on the same clock, never negative. A start that is
# missing, or a reading on another clock than the start's, has no duration:
# 0 and kind "unknown", which no estimate reads.
wv_clock_since() {
    local _ws_now _ws_kind _ws_d=0
    wv_clock_ms _ws_now _ws_kind
    if [ "$_ws_kind" = unknown ] || [ "$_ws_kind" != "$4" ] || ! [[ "$3" =~ ^[0-9]+$ ]] || [ "$3" = 0 ]; then
        _ws_kind=unknown
    else
        _ws_d=$(( _ws_now - $3 ))
        [ "$_ws_d" -ge 0 ] || _ws_d=0
    fi
    printf -v "$1" '%s' "$_ws_d"
    printf -v "$2" '%s' "$_ws_kind"
}

# hook_duration_ms <start_nanos> — wall-clock milliseconds since a
# `date +%s%N` reading, for the few places that hold only that reading (a
# suite or lane the supervisor did not time). 0 where nanosecond date is
# unavailable (BSD prints a literal N) or the start is the 0 sentinel, and
# never negative. A caller recording the result labels it wall. A definition
# the caller already made (a test's stub) is kept.
if ! declare -F hook_duration_ms >/dev/null; then
    hook_duration_ms() {
        local _t0="$1" _t1 _d
        _t1=$(wv_now ns 2>/dev/null || echo 0)
        case "$_t0" in ''|*[!0-9]*) echo 0; return 0 ;; esac
        case "$_t1" in ''|*[!0-9]*) echo 0; return 0 ;; esac
        [ "$_t0" = "0" ] && { echo 0; return 0; }
        _d=$(( (_t1 - _t0) / 1000000 ))
        [ "$_d" -lt 0 ] && _d=0
        echo "$_d"
    }
fi
