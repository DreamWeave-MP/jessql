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

## Option B, as built (`sql.catalog`)

The maintainer chose B (2026-11-10): a database must never be assumed small enough to stay in
memory, so several tables live inside one managed database. Option A above stays a prototype.

```luau
local db = sql.catalog.create('/data/service', { tables = {
  { tableName = 'reservations', columns = { 'id', 'effect' }, primaryKey = 'id' },
  { tableName = 'handled', columns = { 'id' }, primaryKey = 'id' },
} })
db:transaction(function(tx)
  tx:insert('reservations', { id = 7, effect = 'send-7' })
  tx:insert('handled', { id = 7 })
end)            -- one frame, one synchronization: both rows or neither
db:flush()      -- every table with anything hot gets a cold generation; one manifest replacement
```

What it is on disk:

- `<base>.jql-manifest`: record version 3 (`@jessql/catalog_manifest`), every table with its list of
  generations, under one epoch;
- `<base>.g<epoch>.wal`: the one log of that epoch, shared by every table, with its committed-length
  mark;
- `<base>.t.<table>.g<epoch>.rows` and `.deleted`: a table's cold generations.

How it holds together:

- A transaction is one frame of the shared log, so it is whole or absent in every table at once.
- A flush or a compaction writes and seals a generation for **every** table that has anything in
  the log, opens a new log bound to the identity of the whole new cold set, and replaces the
  manifest once. The old log is retired only after that. A table with nothing hot keeps the
  generations it had.
- The log is bound to the cold set by a SHA-256 over every table's name and cold identity. A
  generation swapped between tables, a log from another epoch, or a missing log is refused at
  open; a log is never adopted and never rebuilt.
- A single-table database and a catalog refuse each other's manifest.
- Reads go through the same provider as the single-table hybrid, one for each table, registered in
  one engine: a statement can join tables of the database, hot and cold on both sides.

Checked by `tests/catalog.jsl` with the fault laboratory: the five-table service step over cold
and hot rows, a flush between commits and a compaction between commits, each stopped at every
storage step (42, 204 and 294 of them) in three modes, the first two with every crashed recovery
crashed again: 10,411 stopped runs, no violation.

Budgets are over the whole database, because the log is: `maxHotRows` (rows and tombstones of
every table together), `maxHotBytes` (their payload), `maxWalBytes` (the log's size) and
`maxGenerations` (2 to 8 for any one table, default 8). A commit that crosses one publishes a
flush after it has been acknowledged, or a compaction when some table is at its limit of
generations. A log that churn filled while leaving nothing hot is replaced on its own: the epoch
moves and no table gains a generation. Maintenance that fails never fails the commit before it;
it is kept in `maintenanceStatus().lastError` and the next write is refused until a flush or a
compaction succeeds. A budget already crossed when the database is opened is remembered the same
way, and nothing is published during an open.

Checked by the same file: 120 service steps under `maxHotRows = 12, maxGenerations = 3` never held
12 hot rows, more than 3 generations or a log of 16 KiB; 200 rounds of churn under
`maxWalBytes = 4096` never held a log of 8 KiB; and nine commits that set off three publications,
a compaction among them, were stopped at each of 649 storage steps in three modes (1,948 stopped
runs, no violation).

Not built yet, and so limits today:

- The hot rows of every table are resident until a flush, as in the single-table store. Budgets
  bound them (below); without one the caller flushes and compacts.
- `sql.catalog.verify(path)` reads every page of every generation of every table under the
  database's lock, checks the set against the manifest's identity, and reports damage by stage
  and table without changing a file. It does not check the log's frames (opening the database
  does) and says so in its report. No offline `backup` or `restore` for a catalog yet, and no
  secondary indexes.
- At most 32 tables and 8 generations a table; the tables are fixed at creation.
- Verified on the model disk only, like everything the fault laboratory holds.
