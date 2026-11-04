# Cold composite secondary indexes (experimental)

JessQL's immutable `JQLP2` snapshots are sorted by the primary key. The
separate `@jessql/secondary` module builds a **snapshot-bound, read-only**
sidecar for `(equality-column, ordered-column, primary-key)` queries.

```lua
local sql = require('@jessql')
local snapshotPath = 'events.cold'
local indexPath = 'events.room-stream.index'

sql.secondary.create(indexPath, snapshotPath, 'room_id', 'stream_id')

local db = sql.hybrid.open('events.hot.wal', snapshotPath, 'events', {
  cachePages = 8,
  rowLayout = 'packed',
  secondaryIndexPath = indexPath,
})
local result = db:query([[
  SELECT event_id, stream_id FROM events
  WHERE room_id = ? AND stream_id > ?
  ORDER BY stream_id LIMIT 100
]], { '!room:example.org', 200 })
db:close()
```

The sidecar uses the existing checksummed JQLP2 pages, storing encoded ordered
triples and their original primary keys. Its metadata includes the source
snapshot identity, source row count, index columns, sort-value kind, and whether
all rows are indexed. It **refuses to attach** to a different snapshot identity
and validates each returned key against the authoritative cold row. A corrupt
page raises an error; it does not silently produce SQL rows.

A hybrid scan uses the sidecar only when the query asks for a single indexed
ORDER BY column, includes equality on the partition column, and the index has
complete homogeneous sort values. Otherwise the original scan is used. The
sidecar does not overwrite the existing primary-key index and cannot replace
SQL residual-predicate evaluation. Hot overlay changes are merged into the
ordered stream; hot primary keys and WAL tombstones shadow cold entries.

## Limitations

- Only one optional sidecar can be mounted through `secondaryIndexPath` in this
  revision. The sidecar must be regenerated for a new cold snapshot generation.
- Index creation currently collects and sorts **all composite keys in memory**;
  it is not a bounded-memory external merge sort. The *reader* uses the existing
  bounded page cache. Build memory and sidecar disk size must be budgeted.
- The sidecar stores encoded keys and may exceed the cold data file in size for
  very short rows. Cold lookups also fetch the primary-key page and can incur
  random I/O. Performance depends strongly on query selectivity.
- Rows with NULL partition or ordered value are omitted from the sidecar; its
  `complete` flag then prevents the hybrid ORDER BY fast path. Mixed sort types
  also disable the fast path. Neither situation changes SQL correctness.
- These are checksums for accidental corruption, **not** authenticated content
  hashes. Snapshot identity binds by existing JQLP2 CRC/size, not a cryptographic
  digest. No in-place updates or safe automatic generation publication yet.
- Snapshot and sidecar writes are buffered. This revision makes **no power-loss
  durability promise** and requires no new Jess/L3i runtime.

## Benchmark

Use the bundled Jess 0.3.0 runtime to reproduce the comparison:

```sh
jess run --trusted --package . bench/secondary.jsl prepare 24000 40
jess run --trusted --package . bench/secondary.jsl baseline 24000 40
jess run --trusted --package . bench/secondary.jsl indexed 24000 40
```

With 24,000 cold rows across 48 rooms, 40 bounded room-stream queries, a small
hot overlay, and identical checksums, six alternating runs (three per mode)
measured median query CPU times of approximately **4.89 seconds without** the
sidecar and **0.0508 seconds with** it (~96x on this scan-heavy workload).
Post-query RSS ranged **32.9–34.4 MiB** baseline and **37.3–37.6 MiB** indexed.
On this dataset the original cold snapshot was about 1.9 MiB and the index
sidecar about 3.3 MiB. A one-time 24K-row sidecar build took ~0.44 seconds.

These measurements are not a general JessQL speedup, a durability benchmark, or
an apples-to-apples comparison against another indexed database. They mainly
measure replacing a cold full scan with a selective persisted index range.
