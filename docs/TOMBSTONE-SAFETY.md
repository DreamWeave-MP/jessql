# Tombstone safety

A deleted key stays deleted until it is written again. This states what that depends on in the
managed store as it is, and what checks it.

## Invariants

1. **Newer wins.** For a key, the newest generation that mentions it decides: a row there is the
   value; a deletion marker there means absent. The hot overlay (the WAL) is newer than every
   immutable generation.
2. **A marker outlives what it hides.** A deletion marker for key K may be dropped only by a
   merge whose inputs include every older generation that can still hold a row for K. A
   selective compaction of the newest generations therefore carries its markers forward into
   its output; only a merge down to the oldest generation may drop them.
3. **A row written after a deletion supersedes it.** Within one merge, a row for K newer than a
   marker for K is kept and the marker is not carried past it.
4. **Retirement follows publication.** A generation's files are removed only after a manifest
   that no longer lists it has been replaced and its directory synchronized. A failed or
   uncertain publication retires nothing.
5. **The manifest is the only reference.** Today nothing else holds a generation: there are no
   reader pins, backup leases or replication cursors. A backup takes the namespace lock instead.

## What checks them

`tests/tombstone-histories.jsl`: 40 seeded histories of 160 steps over 24 keys, so the same key is
written, deleted and written again across generations. Steps are upserts, deletions, flushes,
selective compactions (fan-in 2, at most 4 generations), checkpoints, generation transitions
made to fail at each of six stages before and after the manifest is replaced, reopens, and crashes
of the in-memory disk with the database open. After every step every key is read back by `get`
and by a scan and compared with a model that is a plain table; at the end the offline scan with
semantic WAL replay must pass and a further reopen must read the same.

Across the 40 histories: more than 1000 deletions, more than 1000 transitions, more than 100
failed publications and more than 100 crashes, with at least 3 generations live at once. The
same seed gives the same history.

That the check can fail was shown once by hand: with the deletion sidecars left out of the
compaction's inputs in a scratch copy of `managed.jsl`, seed 1 reports a resurrected key at step
61. That mutation is not kept as a test.

## What this does not cover

- **Reader pins, backup or snapshot leases, replication cursors** (invariant 5 says there are
  none). When P5-04 adds them, retirement must count them and these histories need slow readers.
- **Policy-driven compaction selection** (P3-02): only the current selection is exercised.
- Faults in the middle of a storage step: those are `docs/FAULT-LAB.md`, with insert-only commits.
- A crash here loses what was not synchronized; nothing synchronized is corrupted.
