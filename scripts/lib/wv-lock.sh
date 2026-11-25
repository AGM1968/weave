#!/usr/bin/env bash
# wv-lock.sh -- one file-lock helper for every shell lock site (wv-7faa60).
#
# flock(1) is util-linux and absent on macOS, and the zone write lock, the
# schema lock and the attribution lock took no lock at all without it, while
# the maintenance lock and compact --pre-cutover refused outright. Both
# mechanisms here lock the open file description behind a shell fd with
# flock(2): flock(1) where it exists, else python3's fcntl.flock on the same
# inherited fd, which keeps holding after python exits (the lock belongs to
# the description the shell still has open) and interlocks with flock(1) in
# shared and exclusive modes (canary 2026-11-19, macOS probe). Closing the fd
# releases the lock either way. With neither mechanism the helper refuses: a
# graph lock never proceeds unlocked.
#
# Sourced by: scripts/wv, scripts/lib/wv-db.sh, scripts/lib/wv-attribution.sh,
# scripts/cmd/wv-cmd-data.sh, scripts/lib/wv-compact-pre-cutover.sh,
# scripts/hooks/pre-commit-weave.sh (wv_lock_run). No side effects on source.

[ -n "${_WV_LOCK_LOADED:-}" ] && return 0
_WV_LOCK_LOADED=1

# wv_lock_mechanism -- print flock, python or none. WV_TEST_LOCK_MECH forces
# one (WV_TEST_MODE=1 only) so Linux can exercise the python path and refusal.
wv_lock_mechanism() {
    if [ "${WV_TEST_MODE:-}" = 1 ] && [ -n "${WV_TEST_LOCK_MECH:-}" ]; then
        printf '%s\n' "$WV_TEST_LOCK_MECH"
    elif command -v flock >/dev/null 2>&1; then
        echo flock
    elif command -v python3 >/dev/null 2>&1; then
        echo python
    else
        echo none
    fi
}

# wv_lock_fd <fd> <-s|-x> <wait-seconds> -- lock the open fd shared or
# exclusive, waiting up to <wait> seconds (0: do not wait). Returns 0 when
# held, 1 when another holder kept it past the wait, 2 when no mechanism
# exists (after saying so on stderr).
wv_lock_fd() {
    local fd="$1" mode="$2" wait="$3"
    case "$(wv_lock_mechanism)" in
        flock)
            if [ "$wait" = 0 ]; then flock "$mode" -n "$fd"; else flock "$mode" -w "$wait" "$fd"; fi
            ;;
        python) _wv_lock_python "$fd" "$mode" "$wait" ;;
        *)
            echo "wv: no file-lock mechanism (neither flock(1) nor python3); refusing to proceed unlocked" >&2
            return 2
            ;;
    esac
}

# wv_unlock_fd <fd> -- release the fd's lock early; closing the fd also does.
wv_unlock_fd() {
    case "$(wv_lock_mechanism)" in
        flock) flock -u "$1" 2>/dev/null ;;
        python) _wv_lock_python "$1" -u 0 ;;
    esac
    return 0
}

# wv_lock_run <file> <-s|-x> <wait-seconds> <command> [args...] -- run the
# command holding a lock on <file>, as `flock <file> <command>` does, through
# wv_lock_fd, so a host without flock(1) locks too (wv-7bd071). The command's
# status, or 1 with the reason on stderr when the lock is not taken within the
# wait (or the file cannot be opened); 2 when no mechanism exists. The command
# inherits the lock's fd, as under flock(1); the lock ends with the last holder.
wv_lock_run() {
    local file="$1" mode="$2" wait="$3" fd rc
    shift 3
    case "$wait" in
        ''|*[!0-9]*) echo "wv: lock wait must be whole seconds, got '$wait'" >&2; return 1 ;;
    esac
    # Braces scope the 2>/dev/null to the open: on a bare exec it would
    # redirect the calling shell's stderr for good.
    { exec {fd}>>"$file"; } 2>/dev/null || { echo "wv: cannot open the lock file $file" >&2; return 1; }
    wv_lock_fd "$fd" "$mode" "$wait"; rc=$?
    if [ "$rc" -ne 0 ]; then
        exec {fd}>&-
        [ "$rc" -eq 2 ] || echo "wv: the lock $file was held past ${wait}s" >&2
        return "$rc"
    fi
    "$@"; rc=$?
    exec {fd}>&-
    return "$rc"
}

# _wv_lock_python <fd> <-s|-x|-u> <wait> -- flock(2) through python3 on the
# inherited fd, polling a non-blocking attempt until the deadline.
_wv_lock_python() {
    python3 -I -c '
import errno, fcntl, sys, time
fd, mode, wait = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])
if mode == "-u":
    fcntl.flock(fd, fcntl.LOCK_UN)
    sys.exit(0)
op = (fcntl.LOCK_SH if mode == "-s" else fcntl.LOCK_EX) | fcntl.LOCK_NB
end, delay = time.monotonic() + wait, 0.01
while True:
    try:
        fcntl.flock(fd, op)
        sys.exit(0)
    except OSError as e:
        if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
            print("wv: lock on fd %d failed: %s" % (fd, e), file=sys.stderr)
            sys.exit(2)
    left = end - time.monotonic()
    if left <= 0:
        sys.exit(1)
    time.sleep(min(delay, left))
    delay = min(delay * 2, 0.2)
' "$1" "$2" "$3"
}
