# Bounded hot-delta export (experimental)

JessQL's immutable cold generations already support newer-row precedence, binary
composite sidecars and snapshot-bound deletion sidecars. This revision supplies a
**manual candidate flush** from the current hot transactional WAL, avoiding a
full logical-table snapshot for every flush.

```luau
local sql = require('@jessql')
local db = sql.hybrid.open('events.hot.wal', 'events.gen1', 'events', {
  rowLayout = 'packed', cachePages = 2,
})
local metrics = db:exportDelta('events.gen2', 'events.gen2.deleted', {
  runRows = 8192, mergeFanIn = 8, pageBytes = 32768,
})
print(metrics.rows.rows, metrics.rows.maxBufferedRows, metrics.rows.mergePasses)
db:close()
```

`exportDelta` captures **only committed hot rows** and WAL deletion markers.
The new rows file is an ordinary, sorted, checksummed JQLP2 snapshot, and the
second file is a deletion sidecar with the snapshot-identity marker expected by
`sql.segments.open()`. An empty rows snapshot and a deletion-only generation
are valid. Both outputs must be new and distinct. On a caught failure after
building the rows candidate, the API removes that candidate so it does not
leave a misleading rows-only pair. An abrupt process or machine failure may
still leave incomplete, unadopted files; **never infer publication from their
mere existence**.

The resulting candidate can be validated against the original generations:

```luau
local view = sql.segments.open({ 'events.gen1', 'events.gen2' }, {
  deletePaths = { [2] = 'events.gen2.deleted' },
})
-- This view reflects the rows and deletions captured at export time.
view:close()
```

For a database that already has multiple cold generations, append the candidate
path to the ordered list and map its deletion sidecar to the matching number.
The current implementation permits at most eight generations; compact older
ones explicitly before exceeding that limit. Candidate row files can also
receive a compact secondary index via `sql.secondary.create`.

**No generation switch occurs.** The original hot WAL remains authoritative and
bound to its original snapshot identity. A separate fresh WAL can be opened
against the new generation list for previewing. Reusing the *old* WAL against
that list is deliberately rejected. There is no automatic WAL rotation, old-file
deletion, metadata publication or acknowledged power-loss guarantee. Those
require the forthcoming durable-filesystem runtime and a separately verified
cross-platform recovery protocol. Do not use these candidate APIs as an
operational cutover procedure yet.

## Memory and failure properties

- `storage.Store:iterateRows(table)` visits committed rows without materializing
  a SQL result array, including packed resident rows. It returns independent
  row objects; after a committed mutation or checkpoint, the old cursor throws.
- `sql.delta.create(path, columns, primaryKey, nextRow, options)` sorts arbitrary
  input order with at most `runRows` unsorted rows in memory (default 8192).
  Runs spill to checksummed files, then merge with `mergeFanIn` readers (default
  8) across as many levels as necessary. Normal completion and caught errors
  clean up temporary runs. Use optional `maxRows` for an explicit input limit.
- `pageBytes` sets the JQLP2 page target. The format and WAL record layout are
  unchanged. The output path is exclusive and existing files are never replaced.
- There is **no constant-RSS guarantee**: the committed hot tier remains
  memory-resident, and sparse page directories plus merge-reader metadata grow
  with page count and merge fan-in. Temporary *sort input* memory is bounded.
- A failure while exporting candidates does not commit new database changes.
  Callers should discard unadopted output files and investigate filesystem
  failures before retrying.

## Representative performance: 2026-11-04

Jess 0.3.0, Linux x64, 80,000 immutable cold rows, 10,000 committed hot inserts,
500 cold deletions. Reopen the same WAL in a fresh process for each mode, and
run the identical SQL `COUNT(*)` as a sanity check:

| Export mode | Median CPU, three alternating runs | Peak process RSS (median) |
| --- | ---: | ---: |
| Full merged snapshot (89,500 logical rows) | 0.894 s | 51,596 KiB |
| Bounded delta (10,000 rows + 501 marker/deletion records, 1,024-row runs) | 0.289 s | 48,936 KiB |

The delta is about **3.1x faster to construct** on this workload, chiefly
because it does not rewrite 79,500 unchanged cold rows. The RSS difference is
small: most resident memory comes from the already-open hot WAL. Neither mode
uses a synchronized durability barrier in this runtime.

Run-size tradeoff (one illustrative run each, same data, not confidence bounds):

| `runRows` | Export CPU | Peak RSS | Spill runs |
| ---: | ---: | ---: | ---: |
| 512 | 0.305 s | 47,608 KiB | 20 |
| 1,024 | 0.236 s | 48,780 KiB | 10 |
| 4,096 | 0.148 s | 49,388 KiB | 3 |
| 16,384 | 0.069 s | 49,060 KiB | 0 |

Larger buffers reduce temporary file traffic on small deltas; smaller buffers
bound sort allocations more tightly. None of these measurements establishes a
performance win over an external database. For that, benchmark equivalent
schemas, indexes, commit durability, read/write mix, RSS, disk I/O, and tail
latency under the same machine and storage settings.

Reproduce:

```bash
jess run --package . --trusted bench/delta-flush.jsl prepare 80000 10000
jess run --package . --trusted bench/delta-flush.jsl delta 80000 10000
jess run --package . --trusted bench/delta-flush.jsl full 80000 10000
jess run --package . --trusted bench/delta-flush.jsl cleanup
```
