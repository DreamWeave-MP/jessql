# Immutable cold generations (experimental)

`@jessql/segments` composes up to eight existing JQLP2 row snapshots into a
single read-only view, without materializing the entire database in memory.
**Paths are ordered oldest to newest.** A newer row shadows an older row with
an equal primary key. Queries and explicit compaction yield each visible key
once, in primary-key order. The original snapshots are never modified.

```lua
local sql = require('@jessql')

local cold = sql.segments.open({ 'events.0001', 'events.0002' }, {
  cachePages = 1,
})
local db = sql.new()
db:register('events', cold:provider())
local rows = db:query('SELECT id FROM events WHERE id > ? ORDER BY id LIMIT 100', { 900 })
cold:close()

-- The mutable WAL remains authoritative for hot writes and tombstones.
local hybrid = sql.hybrid.open('events.wal', { 'events.0001', 'events.0002' }, 'events')
hybrid:delete(42)
hybrid:upsert({ id = 9001, body = 'updated', room = 'main' })
hybrid:close()

-- Explicit compacting writes a NEW checksummed JQLP2 snapshot.
sql.segments.compact('events.compacted', { 'events.0001', 'events.0002' }, {
  pageBytes = 32768,
  cachePages = 1,
})
```

All snapshots must declare identical ordered columns and primary keys. Opening
incompatible, duplicate or excessive source lists fails, releasing opened
handles. Up to eight page readers are active at once, using a configurable
bounded *decoded-page cache per reader*, and only one pending decoded row per
reader while merging. Sparse per-file directories remain memory-resident and
grow with the **number of pages**, so total RSS is not strictly constant with
database size. Indexes remain optional; currently, a composite secondary
sidecar can only bind a **single** immutable snapshot. A multi-generation
hybrid opener explicitly rejects `secondaryIndexPath`, rather than silently
using an incomplete sidecar.

The `Snapshot.count` property (and `hybrid:stats().coldRows`) counts **physical
cold rows** across all inputs, including shadowed rows. SQL `COUNT(*)` returns
*logical* visible rows; the segment provider deliberately does not advertise a
precomputed count. Consumers wanting the exact logical count should issue SQL
`COUNT(*)` or stream visible rows. `snapshot:stats()` reports the summed page
cache and read counters.

## Operational safety contract

- The order and identities of all cold generations are encoded into the WAL
  binding. An existing WAL **cannot** be reopened against a modified,
  reordered or compacted generation list. Use a newly initialized WAL after
  a separately validated cutover; never hand-edit the identity record.
- The current immutable row format contains **no deletion markers**. Absence
  from a younger snapshot is *not* deletion of an older row. Deletes must
  remain in the hot WAL tombstone table until an export of the complete merged
  state has safely replaced the old generations and the WAL has been rotated.
  Do **not** flush only newly inserted rows into a new segment and discard
  tombstones: doing so could resurrect deleted records.
- `segments.compact()` is an explicit, read-only-source **candidate build**.
  It neither switches the live generation list nor removes old files, rotates
  WALs, or automatically rebuilds secondary indexes. The output path must not
  already exist. It uses `paged.create` checksumming and cleanup on ordinary
  exceptions, but creation/publication still uses buffered runtime I/O.
- No automatic generation publication, online compaction, garbage collection,
  crash-consistent manifest update, or power-loss durability is claimed.
  Those require a carefully tested higher-level recovery protocol and Terra's
  new durable filesystem interfaces once integrated into Jess.
- A source identity is based on the existing JQLP2 directory checksum and
  file size, which detect accidental changes but are not cryptographically
  collision-resistant or an adversarial authentication mechanism.

Future work: tombstone-bearing immutable delta segments, a bounded fan-in
compaction planner for more than eight input generations, compact per-page
sparse directories, segment-aware composite secondary indexes, and a
cross-platform durable generation manifest.
