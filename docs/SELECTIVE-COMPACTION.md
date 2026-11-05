# Selective managed compaction (experimental)

The managed engine no longer has to rebuild the full logical database each
 time it reaches `maxGenerations`. It can synchronously replace only the
**newest** immutable generations plus committed hot WAL changes, keeping all
older generations unchanged. Publication uses the existing JQLM1 manifest
protocol and version-2 composite snapshot identity; the on-disk formats are
unchanged. The high-level API remains a single-table database.

```luau
local sql = require('@jessql')
local db = sql.managed.open('data/events', {
  tableName = 'events', columns = { 'id', 'room', 'body' }, primaryKey = 'id',
  maxHotRows = 10000, maxGenerations = 6,
  compactionFanIn = 3, runRows = 4096, mergeFanIn = 4,
})
-- Compaction is synchronous and may block writers for its duration.
if db:stats().generations >= 2 then db:compact() end
-- A full snapshot is still available when read amplification becomes high.
db:checkpoint()
db:close()
```

## Ordering and tombstone contract

The engine uses the manifest's ordered generation list for precedence. On a
selective compaction of a list `A, B, C, D, E` with `compactionFanIn = 3`:

1. Keep older `A, B` in their original files, without rewriting or renaming.
2. Merge cold generations `C, D, E` in order, and, if the WAL contains hot rows
   or tombstones, append its committed delta as the newest merge input.
3. Produce **one new JQLP2 generation** with an attached deletion sidecar.
   Tombstones for keys that may still be present in `A` or `B` must remain.
4. Sync the new immutable files, bind a new synchronized WAL to the new cold
   identity, and atomically publish the manifest `A, B, F`.
5. Retire `C, D, E` and the old WAL only after successful publication. Failed
   cleanup leaks disk space, not acknowledged commits.

The output generation receives the next epoch number, keeping the manifest's
monotonic ordering and the existing generation budget of 2–8. `compact()`
requires at least two cold generations, even if hot changes are present. The
normal hot-delta `flush()` remains available below the generation limit.
At that limit, **automatic maintenance now selectively compacts** rather
than falling back to a full snapshot.

The policy is intentionally simple: **newest-N**, not a size- or
statistics-aware LSM scheduler. It avoids repeatedly rewriting large older
sources, but repeated small compactions can still rewrite newer data and
increase read amplification. `checkpoint()` is the explicit full-rewrite
operation when reducing that amplification is more important.

## Recovery and resource boundaries

The old manifest and WAL remain authoritative until manifest replacement.
Faults before replacement leave the handle usable; failures at or after
replacement poison it until close/reopen. The recovery directory-sync fence,
WAL identity validation and lock-protected orphan collection also apply to
selective compaction. Unpublished `.gNNNNNNNN.hot-rows` and
`.gNNNNNNNN.hot-deleted` scratch files are removed after caught errors or
by best-effort cleanup on reopening. Never promote scratch files manually.

`compactionFanIn` is constrained to 2–8 (default 3). The external merge itself
uses bounded fan-in and may use intermediate scratch runs. This bounds input
merge concurrency; it **does not enforce total process RSS, a hot-byte budget,
or a disk-space quota**. The hot WAL still stays resident until a successful
cutover, and the operation is synchronous under an exclusive managed lock.
As with previous releases, acknowledged power-cut durability requires real
cross-platform power-failure validation, not merely deterministic fault hooks.

## Reproducible benchmark — Jess 0.3.0, Linux x64

The benchmark constructs an older 4,000-row immutable anchor, four 100-row
delta generations, and a hot update/deletion, then compares one synchronized
selective cutover with a full checkpoint. Both paths reopen and validate the
same logical row count and representative values. Three alternating local
runs, process CPU time measured by `os.clock()`:

| Operation | Median maintenance CPU | Cold generations after | Older anchor rewritten? |
| --- | ---: | ---: | --- |
| Selective tail compaction | 14.08 ms | 4 | No |
| Full checkpoint | 63.21 ms | 1 | Yes |

In this deliberately skewed workload, selective compaction took about 4.5x
less maintenance CPU. Reopen validation was slightly slower with four cold
generations (medians 28.3 ms vs 23.3 ms). The results **do not** demonstrate a
4.5x gain in transaction throughput, p99 latency, RSS, or general workloads.
An even distribution of data, heavy tombstones or many generations may
change the outcome substantially.

Reproduce using the supplied native Jess executable:

```bash
jess run --trusted --package . bench/managed-selective.jsl compact 4000 100
jess run --trusted --package . bench/managed-selective.jsl checkpoint 4000 100
```

Next engineering work: a measured byte-accounted hot-state budget, smarter
selection of cold tiers, and then a single-writer group-commit experiment.
