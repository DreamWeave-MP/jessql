# jessql

A Luau relational query engine packaged as a Jess JPK. It is deliberately a query engine, not a
storage engine: in-memory tables and arbitrary Jess/JPK objects can be exposed as relational
providers without copying their domain semantics into JessQL.

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

No persistent page store, WAL, transactions, mutations, subqueries/CTEs, set operators, or window
functions are implemented yet.

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
