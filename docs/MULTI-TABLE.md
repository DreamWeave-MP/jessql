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
2. **A synchronized persistent store cannot shorten its log.** `checkpoint()` is refused under
   `durability = 'sync'` (`synced checkpoint requires durable generation publication`): the
   legacy checkpoint replaces the log with a rename and no manifest, which is not a durability
   contract anyone should rely on, so the store declines to offer it. The log therefore grows
   with every commit, including rewrites of the same row, and every open replays all of it.

So today a service can have several tables in one atomic commit, or bounded storage with
durable generation publication, and not both.

## Two ways to close it (for the maintainer to choose; neither is built)

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

## What a service can do meanwhile

Nothing safe that is also bounded. Keeping small bookkeeping tables in a synchronized
`sql.open` store is atomic and crash-safe as shown above, at the cost of a log that grows until
the store is rebuilt offline. That is a statement of the present limit, not a recommendation.
