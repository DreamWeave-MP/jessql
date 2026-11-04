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

For fast room-stream queries across generations, build an immutable index per
source snapshot. The `secondaryIndexPaths` list must have exactly the same
number of entries, in the same oldest-to-newest order as the snapshot list.
Each sidecar is separately validated against the corresponding snapshot:

```lua
local sources = { 'events.0001', 'events.0002' }
local indexes = { 'events.0001.room.idx', 'events.0002.room.idx' }
for number, path in sources do
  sql.secondary.create(indexes[number], path, 'room', 'stream', {
    format = 'compact', runRows = 16384, mergeFanIn = 8,
  })
end
local db = sql.hybrid.open('events.hot.wal', sources, 'events', {
  secondaryIndexPaths = indexes, cachePages = 2,
})
local page = db:query([[SELECT id FROM events
  WHERE room = ? AND stream > ? ORDER BY stream LIMIT 100]], { 'main', 900 })
db:close()
```

This performs an ordered fan-in merge of sidecars with **newest-generation-wins**
semantics. For every older index candidate, newer snapshots are checked for
that primary key, even if the newer row moved into another room or its sort
key changed. The hot WAL still wins over every cold generation. Each index
holds a bounded decoded-page cache; CPU is proportional to the number of
candidates returned plus shadow checks across the bounded source fan-in, not
just the number of visible rows. Missing, mismatched, or incomplete sidecars
cannot silently claim to cover all cold rows; unsupported index predicates
fall back to the general SQL path. The single-snapshot `secondaryIndexPath`
option remains supported, but is rejected for multi-snapshot open.

All snapshots must declare identical ordered columns and primary keys. Opening
incompatible, duplicate or excessive source lists fails, releasing opened
handles. Up to eight page readers are active at once, using a configurable
bounded *decoded-page cache per reader*, and only one pending decoded row per
reader while merging. Sparse per-file directories remain memory-resident and
grow with the **number of pages**, so total RSS is not strictly constant with
database size. Composite indexes remain optional; the hybrid engine uses the
ordered sidecar merge only for supported partition-equality and ordered-value
queries. Mixed/nullable order values may require fallback scans.

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
- Row snapshots remain immutable and contain **no deletion markers inside
  their row format**. A generation may now have an optional, separately
  checksummed JQLP2 deletion sidecar, opened with `deletePaths = { [generation]
  = path }`. Delete sidecars take precedence over data rows from the same or
  older generation; a newer ordinary row can reintroduce the key. Hot WAL
  tombstones and updates continue to take precedence over *all* cold data.
  `segments.compact` also accepts `deletePaths` and carries their suppression
  into the output candidate, so old records cannot reappear through compaction.
- Create a deletion sidecar with `sql.segments.createTombstones(path,
  snapshotPath, nextEncodedKey)` where the supplied iterator yields strictly
  ascending WAL-encoded key strings (`s` + string, `b0`/`b1`, or `n` +
  `string.format('%.17g', number)`). Its first record binds the sidecar to
  the corresponding immutable row snapshot. The iterator streams; callers
  must pre-sort keys or provide a sorted upstream source. Duplicates, malformed
  keys, incorrect source identities, and mismatched sidecar lists fail closed.
- **No automatic WAL retirement is safe yet.** A cold deletion sidecar is a
  representation for explicitly built future generations; it is NOT permission
  to discard the existing WAL after export. Changing `deletePaths`, appending
  a snapshot, or compacting the current list changes the generation identity
  and requires a separately validated new WAL and publication protocol.
  Never discard the only authoritative copies of unflushed transactions.
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

Future work: automatic transactional export of hot-row and delete deltas,
WAL-safe generation cutover, a bounded fan-in compaction planner for more
than eight generations, compact per-page sparse directories, and a
cross-platform durable generation manifest. Sidecars and snapshots are
rebuildable derived/candidate data until publication is durable.
