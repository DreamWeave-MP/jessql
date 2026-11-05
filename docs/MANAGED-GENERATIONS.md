# Managed generations (experimental, sync-only)

The `sql.managed.open` API adds a **single-table**, synchronous generation
lifecycle to the existing immutable JQLP2 page store and WAL-backed hybrid.
It is deliberately separate from `sql.open` (a standalone WAL) and
`sql.hybrid.open` (operator-managed immutable snapshots). The original
`sql.open(..., { durability = 'sync' }):checkpoint()` remains prohibited:
it cannot safely replace its WAL without the manifest protocol below.

```luau
local sql = require('@jessql')

-- Existing parent directory is mandatory; only synchronized WALs are used.
local db = sql.managed.open('data/events', {
  tableName = 'events', columns = { 'id', 'room', 'body' }, primaryKey = 'id',
  readMode = 'positional', rowLayout = 'packed', cachePages = 8,
})

db:transaction(function(tx)
  tx:insert({ id = 1, room = 'lobby', body = 'hello' })
end)
assert(db:checkpoint() == 2) -- returns the new durable generation number
assert(db:get(1).body == 'hello')
db:close()

-- The existing manifest supplies the schema for later opens.
local reopened = sql.managed.open('data/events')
assert(reopened:get(1).body == 'hello')
reopened:close()
```

The managed API provides `get`, `insert`, `upsert`, `update`, `delete`,
`transaction`, `query`, `prepare`, `stats`, `flush`, `checkpoint`,
`maintenanceStatus`, and `close` with the same one-table semantics as
`sql.hybrid.open`. `stats()` additionally reports `epoch` and `generations`. On first open `tableName`, ordered `columns`, and `primaryKey` are
required; on later opens they may be omitted or supplied for validation.
The parent directory must exist before first open. Only one managed owner
may open a base path at a time; the parent is canonicalized before taking the
nonblocking OS advisory lock.

## On-disk layout

For a base path `data/events`:

```text
data/events.jql-lock                  # stable managed-process lock
data/events.jql-manifest              # checksum-framed JQLM1 current manifest
data/events.g00000001.rows            # immutable first full generation
data/events.g00000002.rows            # immutable sorted WAL delta
data/events.g00000002.deleted         # snapshot-bound tombstone sidecar
data/events.g00000003.rows            # another immutable generation
data/events.g00000003.deleted         # tombstones for this generation
data/events.g00000003.wal             # only active synchronized JQLW1 journal
data/events.g00000003.wal.lock        # lower-level journal lock
```

The version-1 manifest records the epoch, table/schema, and immutable
snapshot identity. Version 2 adds an ordered list of up to eight immutable
generations, per-generation deletion-sidecar flags, and a composite identity
which binds all referenced generations to one WAL. The new code reads v1
manifests without migrating them until the first `flush()`. Filenames come
from the epoch numbers, not arbitrary paths stored in a manifest. The WAL
contains the complete cold-set identity and cannot be silently rebound. A missing,
corrupt, uninitialized, or incorrectly bound active WAL fails closed. An
unreadable or mismatched snapshot or manifest also fails closed.

Use `sql.managed.open()` only to operate on these files; do not simultaneously
open a managed snapshot/WAL with the unmanaged APIs or mutate files by hand.
Do not move only one file out of a generation or put the generation files on
separate volumes. Backups must preserve one consistent published manifest,
its referenced snapshot and WAL, and the ability to replay the WAL; do not
copy active files individually while commits are ongoing.

## Commit and checkpoint barriers

A managed transaction is written to the retained WAL append writer and
synchronized with `syncData()` before being acknowledged. A checkpoint is
**synchronous** and fences all writes during publication; no other managed
operation can interleave its export or cutover:

1. Keep the active WAL open and authoritative while merging its hot overlay
   into a **new, exclusive** JQLP2 full snapshot. Delete shadows and upserts
   are resolved by `exportSnapshot`.
2. Call `syncAll()` on the completed new snapshot and synchronize its parent.
   Read its directory and record the exact snapshot identity.
3. Bootstrap and synchronize an independent WAL bound to that identity;
   reopen the snapshot/WAL candidate and validate it. The previous WAL and
   snapshot remain untouched.
4. Create and synchronize a versioned/checksummed manifest candidate via
   `createDurable`. Use `replace()` to atomically publish it, then call
   `syncDirectory()` on the parent to fence the new name.
5. Switch the in-process hybrid handle, close the old WAL and readers, and
   retire the old generation **only after** durable publication. Retirement
   is best effort: leftover files are harmless orphans, not recovery inputs.

An error **before** attempting `replace` leaves the original WAL authoritative
and the handle reusable. An error **during or after** replacement is an
uncertain outcome: the handle is poisoned, `close()` is required, and only a
fresh `sql.managed.open()` may determine the authoritative generation. Neither
a failed `replace()` nor a failed `syncDirectory()` authorizes retirement.
Recovery first checks the manifest and its WAL binding, then synchronizes
the parent directory before permitting writes. Under the managed lock, it
best-effort removes every known unreferenced `.gNNNNNNNN` managed file in
the parent directory, including abandoned candidate files. It never removes
referenced generations or active WAL files. No other filename is touched.
If cleanup fails, stale files may remain; the verified manifest and WAL
still determine the authoritative state.

`checkpoint()` invalidates plans held by the previous hybrid generation;
reprepare queries after a cutover. External clients must not mutate the
underlying WAL or remove a managed lock path while handles are live.

## Delta flushes and bounded generation count

`flush()` publishes only the current WAL's hot rows and tombstones as two
new immutable files (`.rows` and `.deleted`). It synchronizes both files,
opens the complete generation set, starts an independent WAL bound to the
composite identity, and durably replaces the manifest. The prior WAL remains
authoritative until publication; on success it is retired, while all
referenced cold generations remain. No-op `flush()` does not advance the epoch.

```luau
local db = sql.managed.open('data/events', {
  tableName = 'events', columns = { 'id', 'room', 'body' }, primaryKey = 'id',
  maxHotRows = 10000, maxGenerations = 6,
  runRows = 4096, mergeFanIn = 4,
})
-- Each committed insert/transaction can trigger a synchronous delta flush.
db:insert({ id = 42, room = 'lobby', body = 'hello' })
-- Manual flush is always available, including when auto-flushing is off.
local epoch = db:flush()
print(epoch, db:stats().generations)
-- Full logical compaction collapses the generation list to one file.
db:checkpoint()
print(db:stats().generations) -- 1
db:close()
```

`maxHotRows` is optional (default: **disabled**). The threshold counts the
current hot rows **plus** tombstones, and is inspected after each committed
managed mutation or transaction. When crossed, maintenance runs synchronously
at the request boundary. It is **not** a hard memory cap: a single large
transaction can exceed it, and rows vary in memory cost. If automatic
maintenance fails **after the user transaction committed**, the write still
returns successfully; `db:maintenanceStatus()` reports `lastError` and whether
the handle is poisoned. A poisoned handle must be closed and reopened. An
operator should monitor/report maintenance errors so repeated failures cannot
allow the hot overlay to grow without bound. A successful manual flush clears
an earlier maintenance error.

`maxGenerations` defaults to 8 (allowed: 2–8). Automatic maintenance uses a
delta flush while a slot is available and falls back to a **full snapshot
checkpoint** at the generation limit. This is a conservative full-rewrite
fallback, not an optimized size-tiered or leveled compaction policy. Explicit
`flush()` at the limit fails with an error; use `checkpoint()` instead. Any
successful cutover invalidates plans bound to the previous hybrid reader.

`runRows` and `mergeFanIn` configure the bounded external sorter used only for
delta output (default 8192 rows and fan-in 8); `pageBytes` applies to new
immutable snapshots. These parameters do not cap the memory of the live WAL
index, and older cold directory metadata is still resident. The number of
active generations is bounded but total database size is not.

## Not yet implemented or verified

- No background flush/compaction worker, smart compaction planner, group
  commits, cross-VM zero-copy page processing, or guaranteed p99 latency.
- No hard total memory-byte budget, no partial hot-state eviction, and no
  disk-quota-enforced operation. A transaction can exceed `maxHotRows` until
  it finishes; a persistent I/O failure can prevent automatic maintenance.
- The manifest and page identities are integrity checks for metadata and
  page directories. They do not eagerly verify the payload of every cold
  data page when reopening a large database.
- No live online migration from standalone `sql.open` or operator-owned
  `sql.hybrid` stores. Do not rename those files into managed paths.
- No physical power-cut validation or native Windows/macOS durability
  certification. The filesystem primitives are called synchronously, but
  their platform-specific guarantees still need fault/power testing.
- The manifest CRC is not an authentication or tamper-resistance mechanism.
  Do not expose the managed directory to untrusted local writers.

Tests exercise pre-publication and post-publication fault hooks, retained
commits, torn-tail recovery, missing/replaced WALs, stale candidates, and
successful source plus JPK reopening. The `testHook(stage)` option exists to
inject deterministic faults at `candidate-sealed`, `wal-ready`,
`before-replace`, `after-replace`, `after-directory-sync`, and `before-retire`;
**do not** supply this option in normal applications.

Try `jess run --trusted --package . bench/managed.jsl 2000 50` for the
full checkpoint baseline. Run `jess run --trusted --package .
bench/managed-delta.jsl flush 2000 4 50` and repeat with `checkpoint` to
compare the same write/update workload. These are CPU timings, not wall-clock
p99 latencies, and depend on the machine and storage. They are not a
substitute for real crash or power-failure validation.
