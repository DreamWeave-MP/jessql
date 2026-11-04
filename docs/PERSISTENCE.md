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
be changed or unset. New column definitions are not retroactive defaults.
A prepared plan validates the store schema generation and rejects execution or
explanation after `createTable`, `addColumn`, or `createIndex`. Re-prepare queries
after schema changes. Plans also reject use after database close.

SQL `INSERT`, `UPDATE`, and `DELETE` support the intentionally restricted
parameterized DML grammar described below. SQL `CREATE TABLE` and `CREATE INDEX`
are not parsed; use the typed schema API. SQL reads within an in-progress
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

## Ordered range indexes and bounded reads

`db:createOrderedIndex(table, column)` (or `tx:createOrderedIndex`) adds an
ordered AVL index alongside the existing hash-index API. Each distinct non-NULL
number/string value is stored in a balanced tree; duplicate values reuse a
posting list. Insert/remove and range seek take O(log distinct values); reads
stream matching rows without allocating a full table scan. One-column indexed
`ORDER BY` (ascending or descending) and single-column bounds (`<`, `<=`, `>`,
`>=`) can use the cursor. Nullable rows participate in ORDER BY with the same
NULL ordering as JessQL's executor. Mixed incomparable types or unsupported
ordering fall back to the existing evaluator.

Exact `COUNT(*)` on fully-covered, single-column bounded ranges can use AVL
subtree cardinalities in O(log distinct values), including duplicate values.
The tree and count metadata are rebuilt on reopen/checkpoint from durable log
records; schema mutations invalidate prepared SQL plans. The tree and its
posting lists are still entirely in memory, *not* a disk B-tree. Composite `(room_id, stream_id)` indexes are available as described below. The implementation never
claims to have fully evaluated a residual SQL WHERE condition that it did not.

## Parameterized SQL mutations

`db:exec(sql, params?) -> affectedRows` and `db:prepareExec(sql)` execute a
**restricted, single-statement DML grammar** against the same native JSL
transaction log. `tx:exec(sql, params?)` works inside an atomic batch.

```luau
local insert = db:prepareExec('INSERT INTO events (id, room_id, body) VALUES (?, ?, ?)')
db:transaction(function(tx)
  insert.inTransaction(tx, { '$1', '!room', 'hello' })
  tx:exec('UPDATE events SET body = ? WHERE id = ?', { 'edited', '$1' })
end)
local changed = db:exec('DELETE FROM events WHERE id = ?', { '$1' })
```

Supported: explicit-column `INSERT INTO ... VALUES (...)`, `UPDATE ... SET
column = literal_or_? [, ...] WHERE primary_key = literal_or_?`, and `DELETE
FROM ... WHERE primary_key = literal_or_?`; literal strings, finite numeric
literals, booleans, `NULL`, and positional `?` parameters. Optional trailing
semicolon. `sql.NULL` is the explicit binding sentinel: Luau array holes are
rejected rather than silently interpreted as NULL. DML returns an affected-row
count, and prepared mutation plans reject schema changes or closed handles.

Intentionally unsupported: `INSERT ... SELECT`, arbitrary expressions,
`RETURNING`, `ON CONFLICT`, multi-row VALUES, partial WHERE expressions,
UPDATE/DELETE without a primary-key equality, multiple SQL statements, and SQL
DDL. Use the typed schema methods for DDL and the typed transaction methods
for broader application logic. No SQL text is constructed from bound parameters.

The restriction is intentional: we do not yet have statement-level predicate
snapshots, row-level constraints, or multi-row mutation limits. A failed DML
statement inside a transaction throws; if the caller does not catch it, the
whole callback rolls back without appending the journal frame.

## Composite ordered indexes for scoped streams

`db:createCompositeIndex(table, equalityColumn, orderedColumn)` (also available
on `tx`) creates a two-column in-memory index. Its first column is an exact
partition key; each partition maintains its own AVL tree over the second
column. For example:

```luau
db:createCompositeIndex('events', 'room_id', 'stream_id')
local page = db:prepare([[
  SELECT event_id, stream_id FROM events
  WHERE room_id = ? AND stream_id > ?
  ORDER BY stream_id LIMIT 100
]])
local rows = page.run({ '!room', lastStreamId }).rows
```

`ORDER BY` can be ascending or descending. Exact prefix-equality and suffix
range predicates (`<`, `<=`, `>`, `>=`) can seek within one partition, rather
than iterating through events belonging to other rooms. Fully covered
`COUNT(*)` queries of the same shape can use subtree cardinalities. Two-column
equality lookups (`prefix = ? AND suffix = ?`) can also seek the exact posting
list; additional equalities are verified against matching rows. The SQL
executor retains responsibility for all residual filters and SQL type
semantics. NULL-prefix records do not match prefix equality; NULL suffixes
follow the same sort order as the existing ordered provider. Heterogeneous
suffix types that are not safely comparable fall back to normal evaluation.

Both columns must exist and differ. Duplicate composite definitions are
rejected; the schema operation is journaled atomically and survives checkpoint
and reopen. Updates/deletes maintain both the index and bounded posting lists;
empty partitions are reclaimed. `db:stats()` reports `compositePartitions`
for diagnostics. All partitions and rows are still memory-resident. Only a
**two-column** equality-prefix/ordered-suffix index is currently supported;
this is not a general multi-column B-tree or a disk index.

Benchmark with `jess run --trusted --package . bench/composite.jsl 25000 150`.

## Bounded query-plan reuse

`db:query(sql, params?)` now caches prepared SELECT plans in an LRU with a
default capacity of **64 distinct SQL texts**, avoiding repeated lexing,
parsing, and planning in hot services. `sql.open(path, { queryCacheEntries = N })`
sets the capacity (integer 0–1024); `0` disables the cache. SQL texts longer
than 8192 bytes are deliberately never cached. Parameter values are **not**
part of the cache key: a prepared plan is reused with fresh bound parameters,
and **query results are never cached**. Subsequent queries see committed writes.

Adding a table, column, or index changes the schema generation; the next query
invalidates the entire plan cache. This includes composite index creation.
`db:cacheStats()` returns `entries`, `capacity`, `hits`, `misses`, `evictions`
so deployments can measure cache effectiveness. The maximum eviction scan
cost is O(N), where N is the configured capacity (at most 1024), and a hot
cache hit is a hash lookup. Plans prepared through `db:prepare()` remain
explicitly owned by the caller and keep their existing invalidation rules.

The cache is intentionally per-open-database and in memory only; it does not
persist SQL text or share plans across worker instances. It is not a SQL
injection defense: callers must continue to bind untrusted values with `?`.
Benchmark with `jess run --trusted --package . bench/query-cache.jsl 3000`.
