#!/usr/bin/env bash
# bounded <seconds> <command> [args...] -- run a command with a time limit, as
# GNU timeout does: its exit status, or 124 when the limit ends it (TERM, then
# KILL a second later), 128+N when a signal N ends it, 127 when it cannot start.
# stdin, stdout and stderr pass through. macOS has no timeout(1) without GNU
# coreutils, so a suite calling timeout there exits 127 without running the
# command, and `|| true` hides it (wv-f8e26d). perl ships on macOS and Debian.
bounded() {
    local secs="$1"; shift
    [[ "$secs" =~ ^[0-9]+$ ]] && [ "$#" -gt 0 ] || { echo "usage: bounded <seconds> <command> [args...]" >&2; return 2; }
    perl -e '
        my $secs = shift;
        my $pid = fork();
        die "bounded: fork: $!\n" unless defined $pid;
        if ($pid == 0) { exec { $ARGV[0] } @ARGV; exit 127; }
        local $SIG{ALRM} = sub {
            kill "TERM", $pid;
            for (1 .. 10) { exit 124 if waitpid($pid, 1) == $pid; select(undef, undef, undef, 0.1); }
            kill "KILL", $pid; waitpid($pid, 0); exit 124;
        };
        alarm $secs;
        waitpid($pid, 0);
        my $st = $?;
        exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@"
}
