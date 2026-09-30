---
id: live-db-file-operation
violation_type: code:live-db-file-operation
summary: A file-level operation on a live SQLite database bypasses its WAL and can corrupt it.
---

## Why

A SQLite database in WAL mode is three files, and open connections hold state about all of them.
Removing or replacing the main file with `rm`, `mv` or `cp` while any process has it open leaves
that process writing WAL frames that belong to the old file. The next checkpoint applies them to
the new one, and the result reads as corruption with no torn write to explain it. Copying the main
file alone copies it without the committed pages still sitting in the WAL.

## Corrective move

Change a live database only through SQLite. Replace its contents with `.restore` from a prepared
file, and take a copy with `.backup` or `VACUUM INTO`. Both run under SQLite's locking: a
concurrent writer either waits or fails visibly. Keep file operations for a database no connection
can hold: a fresh path that nothing has opened yet, a file already proven corrupt by `quick_check`
that has to be replaced outright, or an explicit reinitialisation. Record those as dispositioned
findings with the reason, not as a silent exception.

## Expected outcome

The live database changes only through SQLite, and each remaining file operation on it has a
recorded reason that holds while other processes are running.

## Avoid

Deleting the `-wal` and `-shm` files alongside the main file and treating the operation as safe.
That removes the evidence while the other process keeps its handle. Closing this process's
connection first does not help either: the hazard comes from connections you do not own, such as
another agent, a hook or the MCP server.
