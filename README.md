# jessql

A Luau relational query engine packaged as a Jess JPK. Its existing in-memory and virtual-provider
query paths remain available without storage dependencies. The native persistence feature branch
also adds an **experimental, all-JSL append-only transactional store**, without SQLite or another
database dependency. It is not yet safe for power-loss-critical production workloads.


## Experimental hybrid hot/cold pages

The native persistence branch now includes a self-contained immutable page
provider and a single-table hybrid overlay:

```luau
local sql = require('@jessql')
-- First create a sorted immutable snapshot using sql.paged.create(...).
local db = sql.hybrid.open('events.hot.wal', 'events.gen1', 'events', {
    cachePages = 8, rowLayout = 'packed',
})
db:upsert({ id = 100, room = 'main', body = 'edited' })
local next = db:query('SELECT id FROM events WHERE id >= ? ORDER BY id LIMIT 20', { 95 })
db:exportSnapshot('events.gen2') -- does not activate or durably publish it
```

Hot rows and tombstones are WAL-backed and transactions see staged changes.
The snapshot is checksummed, read-only, and opened with a bounded page cache.
See [Hybrid storage details and limitations](docs/HYBRID.md) before using this
experimental API. Power-loss durability, automatic segment promotion, and
bounded total RSS are **not yet provided**.

## Package

- package: `org.dreamweave.jessql` 0.1.6
- layer: `jessql.core`
- module: `@jessql`

## Basic API

```luau
local sql = require("@jessql")
local db = sql.new()

db:table("items", {
    { id = 1, name = "iron", value = 10 },
    { id = 2, name = "ebony", value = 900 },
}, { "id", "name", "value" })

local result = db:query([[SELECT id, name, value
FROM items
WHERE value >= ?
ORDER BY value DESC
LIMIT 20]], { 500 })
```

Prepared queries expose `run(params)` and `explain()`. `explain()` reports projection-pruned scans,
join strategies, grouping, aggregate count, and parameter count.


## Experimental native persistence (feature branch)

```luau
local sql = require('@jessql')
local db = sql.open('data/app.wal')
db:createTable('events', { 'id', 'room', 'body' }, 'id')
db:createIndex('events', 'room')
db:transaction(function(tx)
  tx:insert('events', { id = '1', room = 'lobby', body = 'hello' })
end)
local rows = db:query('SELECT body FROM events WHERE room = ?', { 'lobby' }).rows
db:checkpoint()
db:close()
```

For lower resident memory use on large event tables, opt into the experimental
packed column representation with `sql.open(path, { rowLayout = 'packed' })`.
It uses f64/boolean buffers, dictionary-coded repeated strings and chunked byte
arenas for unique strings, and lazily constructs row dictionaries on reads.
The default remains `row`; both layouts reopen the **same WAL** without migration.
The ordered AVL indexes now use 20-byte native-buffer node metadata instead of
per-node Luau dictionaries for both resident layouts, with reusable node slots.
Indexed scans can use allocation-free ordered key pairs, and packed rows share
slot lookup with deleted-key history instead of keeping a second key hash map.
See [compact ordered indexes](docs/PERSISTENCE.md#compact-ordered-indexes).
See [packed resident columns](docs/PERSISTENCE.md#optional-packed-resident-columns-experimental)
and [benchmarks](BENCHMARKS.md#experimental-packed-resident-columns--hypervectors-jess-030).
A standalone `bench/hypervectors.jsl` explores approximate binary hypervector
similarity but does not participate in SQL correctness or row compression.

No SQLite bindings are involved. The engine uses Jess filesystem, bytes and JSON primitives.
**Buffered writes are not power-loss durable without a real file/directory sync primitive.**
See [docs/PERSISTENCE.md](docs/PERSISTENCE.md) for the full contract and limitations.

## Provider protocol

The required provider surface remains small:

```luau
db:register("objects", {
    columns = { "id", "name" },
    scan = function(request)
        -- request.columns       projection-pruned columns
        -- request.constraints   simple pushed predicates
        -- request.orderBy       safe provider-order request, when available
        -- request.limitHint     safe bounded-result hint, when available; direct queries only
        --                       receive it when no residual WHERE filtering is possible
        -- request.whereComplete whether pushed constraints cover WHERE
        return rows
    end,
})
```

Providers that know their exact unfiltered cardinality may also expose `count = function() -> number`.
JessQL uses it only for the exact trivial shape `SELECT COUNT(*) FROM source` with no filtering,
grouping, ordering, limit, or offset; every other aggregate follows the normal execution path.

Providers can opt into faster physical plans without changing SQL semantics:

- Return a `_jessqlScan = "v1"` result to report handled constraints/order/limits.
- Expose `indexes = { column = true }` plus `lookup(column, value, request)` for indexed equijoins.
- Expose `iterate(request)` returning a `_jessqlIter = "v1"` iterator for lazy ordered drivers.

JessQL can combine an indexed lookup side with a lazy ordered driver and stop as soon as
`OFFSET + LIMIT` accepted rows have been produced.

## SQL subset

`SELECT`, expressions and aliases, `FROM`, `INNER JOIN`, `LEFT JOIN`, `ON`, `WHERE`, `GROUP BY`,
`HAVING`, `ORDER BY`, `LIMIT`, `OFFSET`, positional `?` parameters, `NULL`, booleans, comments,
`LIKE`, arithmetic/comparison/boolean operators, `IS [NOT] NULL`, and `COUNT`, `SUM`, `AVG`,
`MIN`, `MAX`. Scalar functions include `LOWER`, `UPPER`, `LENGTH`, `ABS`, and `COALESCE`.

The in-development native store provides a checksummed append log, a transaction API, indexed
persistent providers, crash-tail recovery, and snapshot compaction. It does **not** yet have a
page store, SQL DML/DDL grammar, MVCC, subqueries/CTEs, set operators, or window functions.
See [Native persistence architecture and safety boundary](docs/PERSISTENCE.md).

## 0.1.1 execution work

The performance pass adds literal-LIKE fast paths, source-local predicate pushdown, compact hash
buckets, first-join allocation removal, bounded top-K selection, a no-allocation rejected-row path
for single-key top-K, provider-reported ordering, indexed provider joins, and lazy join drivers.

Synthetic timings on the supplied Jess binary from this work session:

- 500k-row single-key `ORDER BY ... LIMIT 20`: about **42 ms**.
- 100k x 100k generic filtered hash join + top-10 order: about **18-23 ms**.
- Provider-indexed/streamed joins can stop after the requested rows instead of materializing either
  complete side.

See `bench/` for reproducible workloads.

## 0.1.3 compact-provider work

0.1.3 adds two provider execution hints used by large packed semantic indexes:

- A direct single-source scan request sets `allowVolatileRows = true`. An iterator may then return
  `_jessqlIter = "v1", volatileRows = true` and reuse the same row table on every `next()` call.
  JessQL clones only when a row crosses a retention boundary (group representative, result unit,
  bounded top-K candidate). Filtering and aggregation can therefore consume one mutable row with
  constant row-allocation pressure.
- Indexed joins pass the remaining `LIMIT` budget to `lookup` as `request.limitHint` when there is
  no residual predicate that could reject looked-up rows. A provider can stop decoding an indexed
  posting list once the query has enough accepted rows.

Both behaviors are optional. Existing providers that allocate distinct rows continue to work
unchanged.


## 0.1.4 aggregate-memory work

0.1.4 hardens the provider path for very large packed indexes. Indexed joins can stream into
aggregates, single-column groups can keep only the group key when post-aggregate expressions do not
need permissive first-row state, aggregate `ORDER BY ... LIMIT` uses bounded top-K selection, and
aggregate state is flattened so `COUNT`/`SUM` groups do not allocate unused AVG bookkeeping. The
compact-group proof is SELECT-alias aware, so `ORDER BY n` where `n` aliases `COUNT(*)` does not
silently fall back to retaining full joined contexts.

These changes are semantic-preserving: ambiguous SQL that projects a non-grouped, non-aggregate
column still keeps JessQL's existing first-row behavior. Tests cover both the compact and permissive
paths, including indexed joins grouped by a value from the lookup side.


## 0.1.6 exact-cardinality work

0.1.6 adds the optional provider `count()` fast path for an unfiltered single-source `COUNT(*)`.
`db:table()` exposes exact cardinality automatically. The optimization is intentionally narrow so a
provider cannot accidentally claim it handled filtered/grouped SQL. This was added under MJ12/Gaia
pressure: asking how many catalog rows exist should not decode a billion stars.


### Native ordered storage and SQL writes (experimental)

The native JSL WAL store now provides ordered range indexes and strictly
parameterized SQL mutations without SQLite or any additional native driver:

```luau
local db = require('@jessql').open('events.wal')
db:createTable('events', { 'id', 'stream', 'room' }, 'id')
db:createOrderedIndex('events', 'stream')
db:exec('INSERT INTO events (id, stream, room) VALUES (?, ?, ?)', { 1, 10, '!test' })
local rows = db:query('SELECT id FROM events WHERE stream >= ? ORDER BY stream LIMIT 10', { 5 })
db:close()
```

See [the persistence documentation](docs/PERSISTENCE.md) for supported SQL,
NULL binding, transaction semantics, range index limitations and the missing
power-loss durability barrier.

### Scoped ordered indexes (native persistence branch)

An experimental two-column `db:createCompositeIndex('events', 'room_id', 'stream_id')`
keeps per-room ordered stream indexes, including bounded ascending/descending
queries and exact range counts. This is pure JSL and uses the existing WAL;
see `docs/PERSISTENCE.md` and `bench/composite.jsl` for guarantees and limits.

Repeated persistent `db:query(sql, params)` calls now reuse bounded LRU
compiled plans (`queryCacheEntries`, default 64, 0 disables), invalidating on
schema changes. The cache never retains results. Use `db:cacheStats()` and
`bench/query-cache.jsl` to assess hot-query benefits.

## Resident index memory optimizations (feature branch)

The native storage provider represents singleton equality and ordered-index postings
inline, so unique values no longer allocate a multi-table posting list. Duplicate
postings use one position map and compact tombstones, including NULL keys in
ordered indexes. Journal contents and all public query/mutation semantics remain
unchanged. See `bench/rss.jsl` and [persistence architecture](docs/PERSISTENCE.md).
This is an in-memory optimization, not an on-disk page store or a durability claim.

### Experimental cold composite indexes

Immutable snapshots can now have a separate `(partition, ordered value)`
sidecar, including correct WAL overlay merging for selected hybrid SQL queries.
See [docs/SECONDARY-INDEXES.md](docs/SECONDARY-INDEXES.md) for API use,
measured latency/RSS tradeoffs, and the unbounded build-memory limitation.

## Bounded secondary-index construction (experimental)

`sql.secondary.create(path, snapshotPath, partition, order, { runRows = 16384,
mergeFanIn = 8 })` sorts immutable cold sidecars using bounded in-memory
runs and tiered on-disk merging. It returns build diagnostics. This preserves
the existing JQLP2 sidecar and its read behavior; large index construction
requires temporary disk space and may take longer than the original
all-in-memory sort. See `docs/SECONDARY-INDEXES.md` and
`bench/secondary-build.jsl` for measured RSS/CPU tradeoffs.
