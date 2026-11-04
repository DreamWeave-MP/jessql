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
are not parsed; use the typed schema API. `tx:query(sql, params?)` supports
SQL SELECT with **read-your-writes** semantics over staged inserts, updates,
deletes, freshly created tables, and nullable schema additions. It can run joins
and aggregates without cloning every committed row. The normal `db:query()`
outside the transaction still sees committed state. Transaction SELECT plans
are cached within each callback (32 entries) and invalidated by schema/index
changes; they read current staged values on every execution. Transaction views
do not claim index-ordered scans because pending writes may disrupt ordering.
Transactions must not yield. There is no MVCC, schema
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

### Resident-index memory layout

Indexes avoid per-value posting-list allocations where possible. A value with
exactly one matching row is stored directly as an encoded primary-key string;
only a second matching row promotes that posting to a collection. When deletes
reduce a posting to one row, the collection contracts back to the inline form.
Duplicate postings use one dense slot array and one primary-key-to-slot map,
not multiple hash sets. Deleted slots are marked with an impossible empty key
and compacted when tombstones exceed a bounded overhead. Ordered NULL postings
follow the same compaction rule.

`db:stats()` exposes `indexSlots` and `indexKeys` for non-NULL postings, plus
`indexNullSlots` for ordered NULL postings. Slot counts include stale positions
not yet compacted, and are intended for regression tests/diagnostics; they are
not exact heap-byte measurements. `bench/rss.jsl` samples operating-system RSS
on Linux and runs the same read workload with configurable row counts. On other
platforms it skips procfs measurements rather than preventing the benchmark
from running. Existing WAL frames and schema formats are unchanged.

**These optimizations do not make the store bounded-memory**: committed row
tables, AVL nodes and every index still reside in the Luau heap. Disk-backed
pages and typed storage remain separate research work; RSS is not a substitute
for measured live-heap or page-cache accounting.

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

Supported: explicit-column single- or multi-row `INSERT INTO ... VALUES (...)`,
`ON CONFLICT (primary_key) DO NOTHING`, parameterized `UPDATE` assignments,
and bounded indexed `DELETE`. UPDATE and DELETE require a single comparison
predicate: primary-key or secondary-index equality (`=`), or an ordered-index
range (`<`, `<=`, `>`, `>=`). Ranges accept finite numbers or strings with
compatible index types; NULL comparisons match no rows. All indexed bulk
writes collect a stable set of primary keys *before* updating rows, including
staged edits, and cap matches at 10,000. Each INSERT accepts at most 1,024
VALUES tuples. Literal strings, numeric literals, booleans, `NULL`, and
positional `?` parameters are accepted. `sql.NULL` is the explicit binding
sentinel: Luau array holes are rejected. DML returns the number of affected
rows; prepared plans reject schema changes and closed handles.

Unsupported: `INSERT ... SELECT`, `RETURNING`, `ON CONFLICT DO UPDATE`,
composite WHERE conditions in DML, and range writes without a committed
ordered index. The WHERE predicate cannot be omitted. SQL CREATE/ALTER
DDL, multi-statement SQL and unrestricted expression evaluation remain
unsupported; use the typed API where necessary. Invalid or partially failed
SQL DML latches an abort on its transaction, even if the application catches
the exception; no partially executed statement can be committed.

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

## Transactional SQL expansion (after composite-index and plan-cache work)

The native JSL store now accepts **bounded multi-row INSERT** statements:

```sql
INSERT INTO events (id, room, attempts) VALUES (?, ?, ?), (?, ?, ?);
INSERT INTO events (id, room) VALUES (?, ?), (?, ?)
  ON CONFLICT (id) DO NOTHING;
```

A single statement accepts at most **1,024 VALUES tuples**. Each tuple has the
same column list, parameters stay positional, and the affected-row count omits
primary-key conflicts ignored with `ON CONFLICT DO NOTHING`. The optional
conflict target must be the table's primary key. There is no `DO UPDATE`,
`RETURNING`, or arbitrary `INSERT ... SELECT` yet.

`UPDATE` and `DELETE` now accept `WHERE indexed_column = ?`, not only primary
key equality. Create the index using `db:createIndex(table, column)` or
`db:createOrderedIndex(table, column)` first. The engine collects a stable set
of primary keys, merges staged inserts/updates/deletes, checks each candidate's
current value, and only then mutates rows. This prevents rows changed by the
statement from reentering or disappearing from its own match set. Non-PK
filters without an existing index fail instead of scanning the whole table.
At most **10,000 rows** may be targeted per statement. This is a protective
limit, not a configurable SQL `LIMIT` feature.

Bounded numeric expressions in UPDATE are available for counter workloads:

```sql
UPDATE federation_queue SET attempts = attempts + 1 WHERE destination = ?;
UPDATE federation_queue SET attempts = attempts - ? WHERE destination = ?;
```

Expressions are restricted to `existing_column + numeric_literal_or_parameter`
or subtraction. They evaluate against each row's *original* values, so
`SET a = a + 1, b = a + 1` uses the same old `a` for both. If the source or
operand is NULL, the result is NULL. Non-number operands are rejected rather
than silently coerced. Primary keys cannot be updated.

A failed SQL parse, bind, or execution through `tx:exec` or a prepared plan's
`inTransaction()` method **latches an abort** on the containing transaction:
catching the error inside the callback does not permit partial SQL mutations
to commit. A post-append in-memory apply failure also poisons the database
handle and requires a close/reopen. This is intentionally conservative.

**Performance / durability:** All changes use the existing one-frame-per-
transaction append journal. The current Jess 0.3.0 writer interface cannot
safely discard buffered bytes after an uncertain failed flush, so this pass
**does not introduce a retained buffered WAL writer** or claim that `flush()`
is a durable commit barrier. Benchmark `jess run --trusted --package .
bench/bulk-dml.jsl 4000` separately measures single-statement inserts,
prepared multi-row inserts, typed transaction batches, indexed SQL updates,
and known-PK typed update loops. Grouping 20 rows per commit is inherently
different from committing every row individually; compare both baselines.

## Transactional query hot path (experimental)

`tx:query(sql, params?)` uses a lazy overlay provider. It first streams
committed candidates through existing indexes, overrides staged replacements,
omits staged deletes, and includes newly inserted keys. A primary-key equality
seeks the relevant pending key directly, even when a transaction contains
thousands of pending rows. Each transaction caches up to 32 SELECT plans;
DDL/index mutations invalidate those plans while row mutations do not.
A transaction handle becomes unusable after the callback returns.

Run `jess run --trusted --package . bench/transaction-query.jsl` to compare
repeated prepared-plan hits with unique SQL strings (forced misses), using
4,000 staged rows and 2,500 primary-key queries. This is a CPU benchmark:
no synchronized filesystem writes, cold disk reads, or concurrency are measured.
The committed primary-key path remains preferable for read-only workloads.

The next memory frontier is that **committed rows, all indexes, and recovery
state still reside in RAM**. The overlay does not make this engine paged or
MVCC-capable. Large transactions also accumulate staged rows and operations
until commit; secondary-index lookups may still examine all staged keys. A
page cache, disk-backed indexes and bounded staging require separate work.

## Optional packed resident columns (experimental)

The new **resident layout** is independent of the WAL and of the durability
protocol. Turn it on per *database handle*:

```luau
local db = sql.open('data/matrix.wal', { rowLayout = 'packed' })
-- Default remains `row` while cross-workload benchmarks and hardening continue.
```

`rowLayout = 'packed'` replaces one Luau dictionary per committed row with a
primary-key-to-slot map and column storage. It uses available Jess 0.3.0
`buffer` primitives without a runtime update:

- Homogeneous finite numeric columns: chunked f64 slabs with NaN as an internal
  NULL marker (user NaN remains invalid).
- Boolean columns: compact byte-coded slabs with a distinct NULL state.
- Repeated strings: u32 dictionary codes with reference counts and retired-ID
  reuse, avoiding one Luau string field per repeated value.
- High-cardinality short strings: 64 KiB append-only byte arenas plus per-row
  offsets and lengths. Dead bytes trigger bounded-space arena repacking once
  their overhead becomes material. Strings over one arena chunk revert that
  column to direct storage.
- Mixed-type columns: lossless direct column vectors when a specialized
  representation can no longer encode every value.

SQL providers read only columns requested by the planner. Where JessQL's
single-table iterator explicitly allows volatile rows, packed reads reuse a
single projected table rather than allocating a new row for every scan step.
Other scans, indexed joins, `get`, and SQL result rows have ordinary stable
values and semantics. Query results and transaction rollback are unchanged.

`db:stats().table_name.resident` reports the packed slot count, free slots,
representation for each column, active dictionary entries, and live/allocated
string-arena byte counts. This is an introspection aid, not an exact heap-size
accounting system.

A WAL created in either layout may be reopened using the other layout; the
journal format, hashes and CRCs have **not changed**. Indexes and rows are
still entirely memory resident, and packed slots do **not** make database
memory usage bounded. This is experimental and opt-in; evaluate update rates,
query projections, and startup/replay time on your own workload before changing
production defaults. The existing buffered-write durability limitation is
unaltered.

Measure both modes with the same benchmark and runtime:

```bash
jess run --trusted --package . bench/packed-rss.jsl row 80000
jess run --trusted --package . bench/packed-rss.jsl packed 80000
```

`bench/hypervectors.jsl` is a separate **research-only** hyperdimensional
computing demonstration: randomized token vectors, majority bundling, 256-bit
binary signatures and Hamming comparisons. A signature is *approximate* and
cannot replace a SQL key, a journal record or an exact secondary index. The
script is not used by JessQL's query planner and does not contribute to the
packed-row RSS improvement. One possible future application is fuzzy event or
moderation similarity search; every candidate would require application-side
verification against stored data. See `BENCHMARKS.md` for measurements.

## Compact ordered indexes

The native ordered-index implementation now stores AVL node links, heights,
posting cardinalities and subtree counts in **20 bytes per node** using Luau's
native `buffer` API. Key values and encoded lookup keys remain in separate Luau
arrays; the WAL, SQL, index API and query results are unchanged. The structure
supports exact range counts, forward/reverse cursors, rebalancing, and node-slot
recycling on deletion. Capacity grows geometrically; obsolete nodes are recycled
until the index is reconstructed at checkpoint. The same structure serves both
`row` and `packed` layouts.

Each field is currently a u32: per-node weights and aggregate subtree counts
are therefore limited to 2^32−1. The engine is still memory-resident and does
not yet provide disk-backed B+ trees, bounded RSS, synchronized commits or
cross-platform physical-durability guarantees. An index build can temporarily
hold both the old and enlarged buffer during geometric growth. This is an
*internal physical index representation*, not a new on-disk format.

`bench/ordered-slabs.jsl` exercises indexed insertions, weighted range counts,
node deletion/reuse, and full ordered iteration. `bench/packed-rss.jsl` compares
end-to-end indexed SQL workloads. Both must be evaluated together: the compact
structure cuts RSS substantially, but isolated mutation-heavy index operations
can be slower due to repeated buffer accesses. Refer to `BENCHMARKS.md` for
measured tradeoffs rather than assuming a universal performance improvement.

## Compact packed key history and allocation-free ordered scans

The experimental `rowLayout = 'packed'` now shares its slot lookup and
insertion-history tracking. An in-memory negative slot marker identifies a
previously seen but currently deleted key; reads, writes, and `has()` reject
that marker as absent. Reinsertion can safely reuse a free physical slot
without duplicating the key in the table's insertion-order list. When that
list is compacted, or a checkpoint is completed, obsolete key-history entries
are removed. This reduces resident key maps, not the on-disk record size.

Ordered AVL scans in persistent query providers use an allocation-free
`iteratePairs(...)` cursor returning `(value, encodedKey)` without creating a
small Luau node table for each value. The original `iterate(...)` function is
still available for callers relying on its node-record return type. AVL
rebalancing also reuses child heights computed for the subtree refresh.

These optimizations require only the existing Luau buffer API. They preserve
SQL semantics, journal compatibility and the existing single-writer contract;
they do not introduce disk-backed paging, hardware durability, or a bounded
RSS guarantee. See `BENCHMARKS.md` for both improvements and observed
query-phase RSS/performance variance.
