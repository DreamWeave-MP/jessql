# One commit over several tables: what holds today, and the gap (#40.1)

## What holds

The persistent store (`sql.open`) has many tables and one write-ahead log. A transaction that
touches several tables is one CRC-framed log record with one synchronization, so it is durable
whole or not at all. `tests/multi-table-atomicity.jsl` holds it to that with the fault
laboratory: a service step that reserves a side effect, marks an event handled, appends to a
conversation, moves an outbox row and charges a counter (five tables) is stopped at every storage
step, in three modes, and the recovery after each crash is crashed again at each of its steps.
After every one of them the tables agree with each other: the counter equals the newest step
present, the outbox holds exactly that step, no step is missing below it, every acknowledged
step is there, and an unacknowledged one is whole or absent. The callbacks of a
`transactionBatch` are each whole or absent on their own. A callback that raises after touching
every table leaves none of them changed.

## The gap

Two facts, both pinned by the same test file, are why this is not yet what #40 asks for:

1. **A managed database is one table.** Generations, manifests, flush, compaction, verification
   and backup are all built around `Options.tableName`.
2. **A synchronized persistent store could not shorten its log.** `checkpoint()` was refused
   under `durability = 'sync'`, because the legacy checkpoint replaced the log with a bare
   rename. Option A below removes this one (see "Option A, as prototyped").

With only the first fact left, a service can have several tables in one atomic commit with a
bounded log, as long as every row of those tables fits in memory.

## Two ways to close it (for the maintainer to choose)

**A. A durable checkpoint for the multi-table store.** Give `sql.open` the publication protocol
the managed store already has for its log: write the compacted log as a new epoch, seal it,
publish a manifest that names it, synchronize the directory, retire the old one. All rows stay
resident, as they are now; nothing is tiered to cold storage.
- Reuses the manifest and publication kernels and the fault laboratory unchanged in kind.
- No new cold format. One new manifest record version (a log epoch with no generations).
- Fits record sets that are small and hot: reservations, handled-marks, counters, outboxes.
- Does not fit a table that outgrows memory.

**B. Several tables in one managed database.** One log, per-table generations, one manifest
epoch covering all of them, flush and compaction per table under a single publication.
- What #40 literally asks for, and the only option for large tables.
- Touches every managed module: the hybrid overlay (per-table tombstones and identity), the
  manifest format, verification, backup, selection and budgets. A new manifest version and a
  migration.
- Considerably larger; wants P5-01's ownership rules settled first.

They are not exclusive: A is a subset of the publication B needs, and could come first.

## Option A, as prototyped

A synchronized `checkpoint()` now publishes the compacted log instead of refusing:

1. the compacted log is written beside the live one and synchronized (`syncAll`);
2. it takes the log's name by an atomic replacement;
3. the directory is synchronized, which makes the name durable;
4. the append handle is reopened on the new log.

No manifest is needed, and none was added: the log has one fixed name, both logs hold exactly
the committed rows (no commit can interleave), so whichever a crash leaves is correct. What is
not safe is a commit appended to a log whose name is not yet durable. So any failure between
steps 2 and 4 poisons the store, which then accepts no commit; and opening a synchronized store
now synchronizes the log's directory before anything is appended, and removes a compacted log
that never took the name.

Checked by `tests/multi-table-atomicity.jsl`: the five-table service step with a checkpoint
between commits, stopped at each of 20 storage steps in three modes, with crashed recoveries
crashed again (161 stopped runs, no violation); the log really is shorter and a crash finds the
shorter one; a checkpoint whose directory synchronization fails refuses the next commit until the
store is reopened; a stale compacted log is dropped at open.

Costs and limits: every open of a synchronized store, managed databases included, now makes one
more directory synchronization. A checkpoint rewrites every row and holds the store for that
long. All rows are resident. The unsynchronized checkpoint is unchanged and still promises
nothing. This was verified on the model disk only.

Whether this ships, and whether option B follows, is the maintainer's decision; the prototype is
a draft so the choice can be made on something that runs.
