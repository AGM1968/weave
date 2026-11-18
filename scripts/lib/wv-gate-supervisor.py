#!/usr/bin/env python3
"""Bound one gate command and clean up its owned processes (wv-759e9a).

Linux subreaping retains ownership across daemonization and nested supervisors.
Snapshots are diagnostic only: cleanup signals direct, unreaped children, whose
identities cannot be reused, then drains children adopted when those exit.
macOS instead signals a private process group, keeping its leader unreaped to
pin its identity. Descendants that leave that group are outside that boundary.
This is process lifecycle containment, not a sandbox against hostile code.

Shared slots (wv-428a92): when WV_GATE_SLOTS names a directory of slot files
and WV_GATE_SLOT_STAMP names where to report, the command launches only once
this process holds an exclusive flock on one of those files. Every candidate
lane's suites draw from the same directory, so the gate as a whole runs at
most as many suites as there are files, and a slot one lane frees goes to a
suite waiting in any lane. The lock lives on a close-on-exec descriptor of
this process: the command does not inherit it, and the kernel releases it
when this process exits for any reason, a SIGKILL included. While waiting,
WV_GATE_SLOT_STOP appearing means the pool has its verdict: exit 125 without
launching. None of the three reaches the command, so a gate the command runs
starts a budget of its own rather than waiting on this one.

Elapsed time (wv-b17a85): when WV_GATE_ELAPSED names a file, the supervisor
writes "<ms> monotonic" there once the command ends: the command's run time on
the monotonic clock, which stops while the host is suspended, so a hibernation
inside a suite or lane is not counted as its cost. The deadline uses the same
clock. Like the slot settings, the variable never reaches the command. A report
it cannot write is a warning, never a change to the command's status; the
caller then has no monotonic reading and says so.
"""

import argparse
from collections.abc import Callable
import ctypes
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from types import FrameType


def children() -> list[int]:
    """Read this single-threaded supervisor's current direct children."""
    return [
        int(pid)
        for pid in Path("/proc/thread-self/children")
        .read_text(encoding="utf-8")
        .split()
    ]


def reap(root: int) -> tuple[bool, int | None]:
    """Reap all exited children; distinguish an empty ownership set."""
    status = None
    while True:
        try:
            pid, raw = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return True, status
        if pid == 0:
            return False, status
        if pid == root:
            code = os.waitstatus_to_exitcode(raw)
            status = code if code >= 0 else 128 - code


def drain(root: int) -> None:
    """TERM, then KILL and reap until no descendants remain, even if detached.

    A new child adopted during shutdown receives the current signal too.
    SIGKILL cannot bound an uninterruptible kernel wait; do not report cleanup
    complete while any owned process still exists.
    """
    grace = time.monotonic() + 2
    while True:
        empty, _ = reap(root)
        if empty:
            return
        sig = signal.SIGTERM if time.monotonic() < grace else signal.SIGKILL
        for pid in children():
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(0.05)


def diagnose(label: str, elapsed: float, bound: int) -> None:
    """Report observed commands, wait channels and lock records before signals."""
    print(
        f"TIMEOUT {label}: elapsed={elapsed:.2f}s deadline={bound}s (exit 124)",
        file=sys.stderr,
        flush=True,
    )
    records: dict[int, tuple[int, str]] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            fields = (
                (entry / "stat").read_text(encoding="utf-8").rsplit(")", 1)[1].split()
            )
            cmd = (
                (entry / "cmdline")
                .read_bytes()
                .replace(b"\0", b" ")
                .decode(errors="replace")
            )
            wait = (entry / "wchan").read_text(encoding="utf-8").strip()
            records[int(entry.name)] = (
                int(fields[1]),
                f"{entry.name} {fields[1]} {fields[2]} {fields[0]} {wait} {cmd}",
            )
        except (OSError, ValueError, IndexError):
            continue  # The snapshot is best-effort; ownership does not use it.
    owned = {os.getpid()}
    while True:
        expanded = owned | {
            pid for pid, (parent, _) in records.items() if parent in owned
        }
        if expanded == owned:
            break
        owned = expanded
    print(
        "  PID PPID PGID STATE WCHAN COMMAND (observed waits, not inferred causes)",
        file=sys.stderr,
    )
    for pid in sorted(owned - {os.getpid()}):
        print(f"  {records[pid][1]}", file=sys.stderr)
    print("  Kernel lock records (empty means none observed):", file=sys.stderr)
    try:
        for line in Path("/proc/locks").read_text(encoding="utf-8").splitlines():
            fields = line.split()
            owner = fields[5] if fields[1] == "->" else fields[4]
            if int(owner) in owned:
                print(f"  {line}", file=sys.stderr)
    except (OSError, ValueError, IndexError) as exc:
        print(f"  unavailable: {exc}", file=sys.stderr)
    sys.stderr.flush()


def process_table() -> list[list[str]]:
    """Read BSD-compatible ps columns without relying on procfs."""
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat=,etime=,wchan=,command="],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise OSError(
            f"ps process snapshot (status {result.returncode}): {result.stderr.strip()}"
        )
    return [
        row
        for line in result.stdout.splitlines()
        if len(row := line.split(None, 6)) == 7
    ]


def signal_group(root: int, sig: signal.Signals) -> None:
    """The unreaped direct child pins both signal targets until final waitpid."""
    try:
        os.killpg(root, sig)
    except ProcessLookupError:
        # Cancellation can arrive before the child establishes its session.
        os.kill(root, sig)


def watch_group(root: int, label: str, bound: int, cancelled: Callable[[], int]) -> int:
    """macOS backend: observe exit without reaping, then drain the private group.

    Never signal cached descendant PIDs. ps is a diagnostic snapshot, not a
    race-free ownership oracle for processes that detach into another group.
    """
    start = time.monotonic()
    status = None
    try:
        while True:
            rows = process_table()
            if cancelled():
                status = 128 + cancelled()
                break
            if any(int(row[0]) == root and row[3].startswith("Z") for row in rows):
                break
            elapsed = time.monotonic() - start
            if elapsed >= bound:
                status = 124
                print(
                    f"TIMEOUT {label}: elapsed={elapsed:.2f}s deadline={bound}s (exit 124)",
                    file=sys.stderr,
                )
                print(
                    "  macOS containment: private process group; detached descendants are not owned\n"
                    "  PID PPID PGID STATE ELAPSED WCHAN COMMAND (observed waits, not inferred causes)",
                    file=sys.stderr,
                )
                owned = {root}
                while True:
                    expanded = owned | {
                        int(row[0]) for row in rows if int(row[1]) in owned
                    }
                    if expanded == owned:
                        break
                    owned = expanded
                for row in rows:
                    if int(row[0]) in owned or int(row[2]) == root:
                        print("  " + " ".join(row), file=sys.stderr)
                print(
                    "  Kernel lock records: unavailable on this backend",
                    file=sys.stderr,
                    flush=True,
                )
                break
            time.sleep(0.05)
    finally:
        grace = time.monotonic() + 2
        try:
            while True:
                signal_group(
                    root, signal.SIGTERM if time.monotonic() < grace else signal.SIGKILL
                )
                rows = process_table()
                if not any(
                    (int(row[0]) == root or int(row[2]) == root)
                    and not row[3].startswith("Z")
                    for row in rows
                ):
                    break
                time.sleep(0.05)
        finally:
            # Even a failed snapshot must not bypass the final group signal.
            signal_group(root, signal.SIGKILL)
            _, raw = os.waitpid(root, 0)
    code = os.waitstatus_to_exitcode(raw)
    return status if status is not None else (code if code >= 0 else 128 - code)


NOT_STARTED = 125  # stopped while waiting for a slot; the command never ran
SLOT_POLL_S = 0.05


def acquire_slot(
    slots: Path, stamp: Path, stop: Path | None, cancelled: Callable[[], int]
) -> int | None:
    """Hold one free slot file; return its descriptor, or None if told to stop.

    The descriptor is close-on-exec (PEP 446) and is never closed here: the
    slot is held until this process exits. Polls rather than blocking on one
    file so that whichever slot frees first is taken. The stamp records the
    slot and the epoch-ns moment it was taken, so the worker measures the
    suite from then, not from when it started waiting.
    """
    paths = sorted(p for p in slots.iterdir() if p.is_file())
    if not paths:
        raise OSError(f"slot directory {slots} holds no slot files")
    while True:
        if cancelled():
            return None
        if stop is not None and stop.exists():
            return None
        for path in paths:
            fd = os.open(path, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                continue
            tmp = stamp.with_name(stamp.name + ".tmp")
            tmp.write_text(f"{path.name} {time.time_ns()}\n", encoding="utf-8")
            tmp.replace(stamp)
            return fd
        time.sleep(SLOT_POLL_S)


def report_elapsed(path: str, start: float) -> None:
    """Write the command's monotonic run time in ms for the caller's record."""
    if not path:
        return
    target = Path(path)
    tmp = target.with_name(target.name + ".tmp")
    try:
        tmp.write_text(f"{int((time.monotonic() - start) * 1000)} monotonic\n", encoding="utf-8")
        tmp.replace(target)
    except OSError as exc:
        print(f"gate supervisor: report elapsed to {path}: {exc} (no monotonic reading)", file=sys.stderr)


def ownership_ready() -> bool:
    """Establish this platform's process ownership before launch, or say why not."""
    if sys.platform == "linux":
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            print(
                f"gate supervisor: enable subreaper (errno {ctypes.get_errno()}, status 2)",
                file=sys.stderr,
            )
            return False
        children()  # Refuse before launch if procfs ownership is unavailable.
        return True
    if sys.platform == "darwin":
        process_table()  # Validate the portable snapshot before launching.
        return True
    print(
        f"gate supervisor: unsupported platform {sys.platform} (status 2); refusing before launch",
        file=sys.stderr,
    )
    return False


def run(label: str, bound: int, command: list[str]) -> int:
    """Launch only after ownership is available; return after fully draining."""
    slots = os.environ.pop("WV_GATE_SLOTS", "")
    stamp = os.environ.pop("WV_GATE_SLOT_STAMP", "")
    stop = os.environ.pop("WV_GATE_SLOT_STOP", "")
    elapsed_path = os.environ.pop("WV_GATE_ELAPSED", "")
    if not ownership_ready():
        return 2
    cancelled = 0

    def cancel(signum: int, _frame: FrameType | None) -> None:
        nonlocal cancelled
        cancelled = signum

    signal.signal(signal.SIGCHLD, signal.SIG_DFL)  # Retain the direct child's exit status/PID.
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, cancel)
    if slots and stamp:
        held = acquire_slot(
            Path(slots), Path(stamp), Path(stop) if stop else None, lambda: cancelled
        )
        if held is None:
            return 128 + cancelled if cancelled else NOT_STARTED
    # The deadline bounds the command, so it starts once a slot is held.
    start = time.monotonic()
    root = os.fork()
    if root == 0:
        try:
            os.setsid()
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, signal.SIG_DFL)
            os.execvp(command[0], command)
        except OSError as exc:
            print(
                f"gate supervisor: execute {command[0]}: {exc} (status 127)",
                file=sys.stderr,
            )
        os._exit(127)
    if sys.platform == "darwin":
        try:
            return watch_group(root, label, bound, lambda: cancelled)
        finally:
            report_elapsed(elapsed_path, start)
    try:
        while True:
            _, status = reap(root)
            if cancelled:
                return 128 + cancelled
            if status is not None:
                return status
            elapsed = time.monotonic() - start
            if elapsed >= bound:
                diagnose(label, elapsed, bound)
                return 124
            time.sleep(0.05)
    finally:
        # Measured when the command ends, before draining what it left behind.
        report_elapsed(elapsed_path, start)
        drain(root)


def main() -> int:
    """CLI shared by suite workers and candidate-lane workers."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("seconds", type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.seconds <= 0 or not args.command:
        parser.error("a positive deadline and command are required")
    try:
        return run(args.label, args.seconds, args.command)
    except OSError as exc:
        print(
            f"gate supervisor: ownership/launch failed: {exc} (status 2)",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    sys.exit(main())
