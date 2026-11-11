# shellcheck shell=bash
# errexit-report.sh — name where errexit ended a suite (wv-f03855).
#
# run-all.sh runs each suite with BASH_ENV pointing here, so bash sources this
# file before the suite's first line. A suite under `set -e` whose setup sends a
# command's output to /dev/null ends without a word when that command fails: the
# rc.16 publish's first verify stopped on Graph Commands with nothing but "no
# test count". The trap prints the suite file, line, exit code and command.
#
# Only the suite's own shell gets it. BASH_ENV is unset at once, so wv and every
# other bash script the suite starts run without it. The trap reports only while
# errexit is on and only in the top-level shell, which is exactly when errexit is
# about to end the suite: a suite without `set -e`, a command whose failure is
# tested, and a failure inside $(...) stay silent. A suite that sets its own ERR
# trap replaces this one.
#
# No `set -E` (wv-b1b61e). It would carry the trap into every subshell, and bash
# does not exec a subshell's last command while a trap is set: `( ...; sleep N ) &`
# then forks the sleep, `kill $!` ends only the subshell, and the orphaned sleep
# keeps the subshell's file descriptors (a held flock, a $(...) pipe). The rc.17
# dry run's zone-lock suite failed that way in the aggregate and passed alone.
# The cost: a failure inside a shell function ends the suite unreported.
unset BASH_ENV
# One line, arguments expanded at the failure: a multi-line trap body shifts
# $LINENO by its own line count.
_wv_errexit_report() {
    [[ $- == *e* ]] && [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
    printf 'Error: %s stopped at line %s (exit %s): %s\n' \
        "${BASH_SOURCE[1]##*/}" "$2" "$1" "$3" >&2
}
trap '_wv_errexit_report "$?" "$LINENO" "$BASH_COMMAND"' ERR
