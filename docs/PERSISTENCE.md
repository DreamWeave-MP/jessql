# Native JessQL persistence — experimental branch

This is a JSL storage engine: **no SQLite dependency, no native database driver, and no
new Rust extension**. It is deliberately *not* yet a production durability guarantee.

## API

```luau
local sql = require('@jessql')
local db = sql.open('data/matrix.wal')

db:createTable('events', { 'event_id', 'room_id', 'content' }, 'event_id')
db:createIndex('events', 'room_id')

db:transaction(function(tx)
  tx:insert('events', { event_id = '$one', room_id = '!room', content = '{"body":"hi"}' })
  tx:upsert('events', { event_id = '$two', room_id = '!room', content = '{"body":"bye"}' })
  assert(tx:get('events', '$one').room_id == '!room')
end)

local query = db:prepare('SELECT content FROM events WHERE room_id = ? ORDER BY event_id')
for _, row in query.run({ '!room' }).rows do print(row.content) end

db:checkpoint() -- optional compact rewrite of the append log
db:close()      -- release the exclusive writer lock
```

`sql.new()` and existing virtual providers are unchanged. `sql.open(path, options?)`
returns a separate store backed by JessQL's existing SQL SELECT planner/executor.
Its mutations are `createTable`, `createIndex`, `addColumn`, `insert` (fail if duplicate),
`upsert`, `update` and `delete` (returns whether the key existed). `get` reads by primary
key and returns a defensive row copy. `transaction(fn)` groups these operations
into one log record, and `tx:get` observes staged writes and deletes.

`addColumn(table, column)` is an atomic, metadata-only migration that adds a
nullable column (existing rows read as NULL); it works inside transactions and
survives journal replay and checkpoint. `update(table, key, changes, unset?)`
changes only listed columns of an existing row and returns `false` when absent.
`unset` is an optional array of column names to set to NULL; primary keys cannot
be changed or unset. New column definitions are not retroactive defaults. Build
fresh prepared queries after schema changes.

SQL `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, and `CREATE INDEX` syntax are
**not yet parsed**; use the typed mutation API. SQL reads within an in-progress
transaction see committed state, not the staged overlay; use `tx:get` to read
your pending writes. Transactions must not yield. There is no MVCC, schema
migration, foreign-key enforcement, composite key, query cancellation or online
index rebuild. Prepared queries should be recreated after DDL/index changes.

Persistent columns are nullable UTF-8 strings, booleans, or finite Luau numbers.
`nil` is SQL `NULL` and is absent from a returned row. Values are copied and
validated before append. Tables, nested values, functions, NaN, infinities and
invalid UTF-8 are rejected. Primary keys must be non-NULL scalar values. Luau
numbers are IEEE-754 doubles; arbitrary precision 64-bit integers and opaque
byte blobs will need dedicated value types. Persisted column names are normalized
to lowercase, and each table requires an explicit primary key.

Options: `maxFrameBytes` defaults to 16 MiB (1 KiB–256 MiB), controlling the
maximum individual transaction and checkpoint frame; `recoverTail` defaults
to `true`. Frame limits must be consistent across reopen. `recoverTail = false`
rejects even incomplete trailing bytes without truncation.

## Format and recovery

The file starts with the ASCII magic `JQLW1\n`, followed by transaction frames:

```
u32le payload_length | u32le CRC32(payload) | JSON payload
```

Each frame includes a monotonically increasing transaction sequence and a list
of operations. One append contains the entire logical transaction; replay
validates *all* operations before applying a frame. An incomplete trailing
frame is never applied, and on recovery its bytes are truncated before a
subsequent append. A complete frame with an invalid checksum, invalid schema,
or nonconsecutive sequence fails closed instead of silently losing data.
CRC32 detects accidental damage; it is **not** authentication.

A database-wide exclusive `@dream/fs.lock` protects writers across processes.
The in-memory rows are stored in a primary-key hash map. Secondary hash indexes
maintain posting lists on insert, update and delete; the JessQL provider uses
indexed equality constraints to narrow scans, and exposes indexed lookup for
joins. Other SQL predicates and joins continue through JessQL's existing
planner. `COUNT(*)` without predicates uses exact stored cardinality. Indexed equality
counts (`WHERE indexed_column = ?`) use direct posting-list cardinality, avoiding
materializing or scanning the matching rows. Conjunctions of equalities can use
the smallest index and verify remaining predicates. Unsupported filters fall
back to normal query execution; this remains optional for other providers.

`checkpoint()` streams a compact logical snapshot into a sibling `.checkpoint.tmp`
file, bounded by the frame size, and renames it over the previous log only
after writing and closing. It then purges deleted row slots and stale index
postings from memory. Hot tables also compact stale slots incrementally when
tombstones exceed a bounded threshold, so long-running update/delete churn
does not grow the in-memory hash posting lists without bound. `db:stats()`
reports per-table live row counts, total key slots, and live/allocated secondary
index postings; it is an O(index-size) diagnostic snapshot, not a cheap query
metric. An interrupted pre-rename checkpoint leaves the original log intact. The engine does not automatically checkpoint yet.

## Durability boundary (important)

**Jess 0.3.0 does not expose a documented `fsync`/`fdatasync` or directory sync
primitive in `@dream/fs`.** `writeFile` and `Writer:close()` are not a substitute
for a durable sync barrier. This implementation supports recovery from process
termination and torn trailing appends, but **cannot promise acknowledged commits
survive a power outage or sudden host reset**, nor does an atomic rename prove
its contents reached stable storage. Do not deploy this for Matrix or financial
state with power-loss durability requirements until Jess exposes and tests a
true file+directory sync contract. Until then this is a prototype engine and
its benchmarks measure buffered writes only.

Additional limits: one exclusive writer at a time; all rows and indexes are
in memory; first reopen replays the log (so checkpoint regularly); no automatic
retention or background cleanup; no protection from a hostile process that
modifies the database files outside the advisory lock; no disk quota controls;
no group commit across independent transactions. Errors during uncertain
appends poison the handle and require closing/reopening.

## Testing and benchmark

```bash
jess package test .
jess check src/storage.jsl --package .
jess run --trusted --package . bench/storage.jsl 50000 64
jess run --trusted --package . bench/churn.jsl 20000
```

The integration suite runs against the source provider and the packed JPK,
covering reopening, rollback, duplicate prevention, lock exclusion,
truncated tails, checksum corruption, checkpoint/replay, mixed indexed joins,
index maintenance after deletes/updates, model-based transaction parity, and
invalid values. Work still needed: OS fault injection around *every* syscall,
large-scale fuzzing, page-oriented disk indexes, buffered streaming cursors,
file+directory sync, and cross-platform power-loss testing.
