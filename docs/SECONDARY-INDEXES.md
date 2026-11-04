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
- Index construction now spills sorted runs once the configurable `runRows`
  budget is reached, and merges immutable checksummed runs using at most
  `mergeFanIn` simultaneously open readers. The default is 16,384 keys per
  run and a fan-in of 8; indexes smaller than one run retain the faster
  in-memory path. Intermediate sorted runs are tier-compacted and deleted
  on success or a caught failure. A hard process kill can leave temporary
  files, identified by the `<index>.sort-*` prefix, for manual cleanup.
  The cold snapshot's sparse page directory, individual key sizes, and
  the temporary disk footprint are not fixed-size; this is bounded *key
  sorting memory*, not a constant-RSS guarantee independent of everything.
- `secondary.create()` returns construction metrics including spill count,
  merge count, maximum buffered key count, and maximum concurrent readers.
  Tune `runRows` to trade build speed against peak RSS; do not assume
  external sorting is faster than a fully resident sort.
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

## Bounded-memory sidecar construction (Jess 0.3.0)

```lua
local metrics = sql.secondary.create('events.room-stream.index', 'events.cold',
  'room_id', 'stream_id', { runRows = 16384, mergeFanIn = 8 })
print(metrics.spilledRuns, metrics.maxBufferedEntries, metrics.maxOpenReaders)
```

Use `bench/secondary-build.jsl` to isolate construction from cold snapshot
creation (`prepare`), and run the same prepared snapshot using old and new
package trees in separate processes (`build`). Linux peak RSS is measured by
`/usr/bin/time`; the benchmark itself prints `/proc/self/status` RSS when
available, plus a deterministic indexed lookup checksum.

On a prepared **100,000-row** snapshot (48 room partitions), the previous
in-memory builder took 2.24 seconds of CPU and peaked at **95,644 KiB** RSS.
The external builder with 16,384-key runs took 3.08 seconds and peaked at
**64,480 KiB** in an initial matched run (**32.6% lower peak RSS**, with
approximately **38% greater build CPU**). Using 4,096-key runs reduced peak
RSS further to 57,684 KiB but increased build CPU to 4.64 seconds.
Host timing varies; do not generalize these to storage devices or workloads.

The output `.idx` sidecar was **byte-for-byte identical** to the previous
builder's sidecar for this 100K-row dataset, including its 14,394,086-byte
file size and SHA-256 digest
`40d1e6f02855ece63b462c81f0e9c591217cfe6649aea231ba70061399ccdd52`.
Query checksum also matched (`34358907`). This is a build-time RSS
optimization, not a smaller index file or a faster indexed query.

## Compact JQLS1 sidecars (opt-in)

To eliminate duplicate primary-key serialization and JSON row overhead in a
cold secondary index, pass `format = 'compact'` to `secondary.create()`:

```lua
sql.secondary.create('events.room-stream.compact', 'events.cold', 'room_id',
  'stream_id', { format = 'compact', runRows = 16384, mergeFanIn = 8 })
```

The immutable `JQLS1` format stores one sorted key per entry using a binary
record frame. Each key uses a 16-bit common-prefix length and a 32-bit
suffix length, followed by its unshared bytes. The existing reversible
`(partition, ordered value, primary key)` encoding supplies the primary key
without duplicating it in a JSON row. CRC32 protects each page and the
footer's sparse directory, including the source-snapshot identity and index
metadata. Loaded pages are checked before any row from them is returned.

`secondary.open()` automatically detects both `JQLP2` and `JQLS1`. Nothing
changes for existing sidecars. `format = 'paged'` (the default) preserves the
old format byte-for-byte. To migrate, construct a **new** sidecar from the
same immutable cold snapshot, validate it, then point the hybrid opener at its
path; do not overwrite an active sidecar. The `JQLS1` format is experimental.

External spill runs still use `JQLP2`; only the final output is compact. Its
build-time sorting budget and merge fan-in are unchanged, and the final
writer consumes sorted entries as a stream. There is no need to hold the
complete result in memory. The sparse page directory does still scale with
the number of index pages, and key reconstruction allocates strings for a
cached page. Like `JQLP2`, the current format caps total file size at 4 GiB,
individual index keys at 4 MiB, and directory metadata at 16 MiB.

This is **not compression of application records** and is not a durable commit
protocol. `JQLS1` sidecars are independently rebuildable derived data; they
must be bound to the exact source snapshot and republished through a safe
filesystem protocol before a deployment relies on power-loss persistence.
A CRC32 check detects accidental corruption; it is not cryptographic
authentication.

Benchmark: `jess run --package . --trusted bench/secondary-build.jsl build
100000 16384 8 compact`. Run the equivalent command with `paged` to measure
the original format. `prepare` generates the shared cold snapshot first.
