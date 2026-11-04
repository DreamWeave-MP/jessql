# Experimental hybrid storage: immutable pages + transactional overlay

This revision restores a **self-contained immutable page provider** and adds an
**explicit, single-table hybrid** built entirely in JSL. Neither uses SQLite,
Rust bindings, or L3i facilities newer than the bundled Jess 0.3.0 runtime.

## Quick start

```luau
local sql = require('@jessql')
local nextId = 0

-- The callback must emit rows in strictly ascending primary-key order.
-- This is an immutable file: use a NEW path for each exported generation.
sql.paged.create('events.gen1', { 'id', 'room', 'body' }, 'id', function()
    nextId += 1
    if nextId > 10000 then return nil end
    return { id = nextId, room = 'main', body = 'event-' .. nextId }
end, { pageBytes = 32768 })

local db = sql.hybrid.open('events.hot.wal', 'events.gen1', 'events', {
    cachePages = 8,
    rowLayout = 'packed',
})

-- A cold row is shadowed by an ordinary WAL mutation.
db:update(10, { body = 'edited' })
db:delete(12) -- WAL tombstone suppresses the cold copy

db:transaction(function(tx)
    tx:insert({ id = 10001, room = 'main', body = 'new' })
    assert(tx:get(10001).body == 'new')
    assert(tx:query('SELECT body FROM events WHERE id = ?', { 10001 }).rows[1].body == 'new')
end)

local results = db:query('SELECT id, body FROM events WHERE id > ? ORDER BY id LIMIT 20', { 9900 })

-- Export a new immutable generation without changing the live database.
db:exportSnapshot('events.gen2')
db:close()
```

### Correctness and query behavior

- The WAL is authoritative for hot replacements and deletions. A hot primary key
  masks exactly one cold key; tombstones persist in the WAL. Transactional
  reads include staged mutations and do not expose rolled-back changes.
- A WAL stores the cold snapshot identity and table name. Reopening the same WAL
  against a different exported generation is rejected. The fingerprint uses the
  checksummed directory and file size; it prevents accidental mismatch, **not
  maliciously crafted hash collisions**.
- Primary-key equality uses one cold page lookup. Single-primary-key
  ascending/descending ORDER BY requests use a merge iterator; supported
  numeric/string range bounds seek straight into the sparse page directory.
  The SQL executor retains control of residual predicates and LIMIT semantics.
- Other ORDER BY expressions and unsupported or mixed-type key layouts fall
  back to the SQL executor's ordinary sorting path. Secondary indexes are not
  yet persisted in the cold format.
- `paged.create` requires sorted, unique scalar keys and validates scalar row
  values. Each loaded page is CRC32 checked before decoding and checks its row
  directory; the sparse directory is CRC32 checked on open. Damage in a page
  not yet read may be detected only when that page is accessed.
- The on-disk page format is versioned independently of the unchanged JQLW1
  WAL. It is presently limited to files below 4 GiB, rows below 4 MiB,
  256 columns, and at most a 16 MiB sparse directory.

### Memory and operational limits

The page cache is bounded by `cachePages`, but **total RSS is not bounded**:
the sparse directory, the mutable hot table, WAL tombstones, and SQL result
materialization still consume memory. General scans materialize the hot rows
and tombstone keys once for masking, then stream cold rows. Snapshot export
sorts only the resident hot portion, merges it with a cold cursor, and writes a
new immutable file; its memory is proportional to the overlay and page
metadata, not to all cold rows.

This is **not** an automatic LSM engine: there is no automatic flush threshold,
background compaction, safe generational cutover, obsolete-file reclamation,
or multi-table hybrid transaction facility. To use a newly exported generation,
close the old database, provision a **fresh WAL**, validate the export, and
perform the external cutover. Do not delete an active cold file.

Hybrid mutations currently use the typed `insert`, `upsert`, `update`, `delete`
and `transaction` APIs; SQL `INSERT`/`UPDATE`/`DELETE` on the hybrid logical
view are deliberately not exposed. The underlying resident store still has
its separate SQL DML support.

`db:exportSnapshot(path)` may not be called from its transaction callback. It
writes a new exclusive file; it does **not** durably publish it, replace the
active generation, or retire a WAL. Checkpoint adoption and WAL truncation must
wait for a verified publication/recovery protocol.

### Durability and filesystem limits

This implementation runs on Jess 0.3.0 with existing buffered file I/O.
It survives the process-crash/reopen scenarios exercised in tests, but **does
not guarantee acknowledged writes or exported snapshots survive sudden power
loss**. Snapshot creation and WAL writes require the future durable L3i/Jess
file-sync barriers before production-grade power-loss guarantees can be claimed.
New files use exclusive creation, and page reads retain a read handle; snapshot
files are immutable while open. Per-platform filesystem semantics still need
native Windows and macOS validation for this new path.

### Benchmark interpretation

`bench/hybrid-compare.jsl` constructs two databases with the same logical
100,000 rows, 500 changed cold rows, 500 tombstones, and 500 hot inserts. The
resident baseline has a **real ordered primary-key index**, so its range scans
are not penalized by a missing index. It runs three queries of 20 keys near the
tail, 300 random reads, and a full COUNT. These are separate-process numbers
on the supplied Jess 0.3.0 Linux x64 runtime, not production SLOs.

The hybrid format wins restart cost and overall RSS, while the resident engine
is dramatically faster for random reads and ordered hot scans. Full COUNT and
mixed secondary-key queries still scan cold storage; this is the next obvious
optimization frontier. Full measurements: `BENCHMARKS.md`.
