# Managed hot-byte maintenance (experimental)

JessQL can trigger synchronous generation maintenance using a **logical hot
scalar-payload watermark** rather than just a row/tombstone count. This is
opt-in and preserves the previous unmetered write path by default.

```luau
local sql = require('@jessql')
local db = sql.managed.open('data/events', {
  tableName = 'events', columns = { 'id', 'room', 'body' }, primaryKey = 'id',
  maxHotBytes = 8 * 1024 * 1024,
  maxHotRows = 10000,
  maxGenerations = 6, compactionFanIn = 3,
})

db:transaction(function(tx)
  tx:upsert({ id = 17, room = 'general', body = 'committed' })
end)
local status = db:stats()
print(status.hotRows, status.tombstones, status.hotPayloadBytes)
print(db:maintenanceStatus().lastError)
db:close()
```

## What is measured

`hotPayloadBytes` is the sum of **live scalar values** in the mutable data
and deletion-marker tables: UTF-8 bytes of strings, 8 bytes per number, and
1 byte per boolean. Nulls do not contribute. Primary-key values count once as
ordinary columns; the tombstone table's encoded key strings also count.

This is **not an RSS, allocated-heap, disk-space, query-cache, or physical
memory limit**. It excludes Luau table overhead, indexed keys and postings,
column buffers and their dead capacity, WAL frame allocations, immutable page
cache and export/compaction scratch memory. For large strings, even a single
transaction may exceed the watermark before maintenance can run. The WAL frame
limit provides a separate upper bound on an individual encoded transaction,
not a universal RAM budget. Do not describe `maxHotBytes` as a hard memory cap.

The counters update while applying committed operations, and are reconstructed
by normal WAL replay after restart. Upsert replacement subtracts the previous
row, delete subtracts its live row, and aborted transactions never contribute.
The replay path does not trust serialized counters. The default unmetered
configuration does not track these bytes: `stats().hotPayloadBytes` is `nil`.
Standalone WAL stores can opt in with `sql.open(path, { trackPayloadBytes = true })`
and inspect `db:tableFootprint(table).payloadBytes`.

## When maintenance fires

After an acknowledged synchronized commit, JessQL checks the optional
`maxHotRows`, `maxHotBytes`, and `maxWalBytes` thresholds independently.
Any threshold triggers maintenance. `maxWalBytes` monitors the *physical active
WAL file size* via a `stat()` call after each acknowledged transaction; it is
optional (integer 1024 through 1,000,000,000,000) and disabled by default.
A WAL can grow rapidly under updates or insert/delete churn even when there
are no surviving hot rows. When WAL pressure is reached, an empty delta
can rotate the active WAL without rewriting old immutable generations. If below `maxGenerations`, it calls the existing durable
`flush()`; at the generation budget, it selects the existing newest-tier
`compact()` operation. These operations remain **foreground, synchronous,
and mutually exclusive** with writes and generation transitions.

If maintenance fails *before* publication, the just-acknowledged WAL commit is
still successful. JessQL reports the failure through
`db:maintenanceStatus().lastError`. With any configured maintenance budget,
subsequent writes fail before mutation until an explicit successful `db:flush()`,
`db:compact()`, or `db:checkpoint()` clears the condition. Reads remain
available unless the underlying handle is poisoned by an uncertain
publication. If a manifest replacement has begun, the handle is poisoned and
must be closed and reopened, as in the existing managed protocol.

An over-budget hot overlay or WAL reopened after a process crash starts with
**write backpressure still in force**, even when its earlier in-memory error message
has been lost. Use explicit maintenance to clear it; reopening is not a
backpressure bypass. This is a conservative availability tradeoff meant to
prevent repeated silent growth after a maintenance failure.

`maxHotBytes` must be an integer from 1 through 1,000,000,000,000 inclusive;
invalid options fail before locking. Byte accounting adds some work per
mutation and is disabled unless requested. It is not safe to assume that
successful cutovers imply physical power-loss durability on untested
filesystems or platforms.

## Reproduce the tests and comparisons

```bash
jess package test .
jess check --package . src/storage.jsl src/hybrid.jsl src/managed.jsl tests/hot-budget.jsl
jess run --trusted --package . bench/hot-budget.jsl stats 3000 500
jess run --trusted --package . bench/hot-budget.jsl churn 3000 500
jess run --trusted --package . bench/hot-budget.jsl churn 3000 500 metered
```

The test suite exercises packed and ordinary row layouts, repeated upserts
within one transaction, rollbacks, multi-restart deterministic mutation
models, large transactions, automatic compaction, failed publication, restart
backpressure, cold tombstones and WAL recovery. These simulated failures
cannot replace physical power-loss and cross-platform filesystem tests.

Performance methodology and measured medians are in `BENCHMARKS.md` and the
replay archive's `benchmark-final.csv`. Do **not** infer a general performance
improvement from the small, noisy comparative workload. Further work should
address explicit admission control before oversized transactions, resident
heap/arena accounting, and asynchronous maintenance with latency isolation. See
[the adversarial architecture review](ADVERSARIAL-ARCHITECTURE-REVIEW.md) for
outstanding durability and resource-limit concerns.
