# Jess runtime integration: synchronized WAL and positional cold I/O

This revision targets the supplied Jess Linux x64 binary with the L3i Luau 0.745
update and native filesystem safety primitives. It introduces no SQLite, Rust,
or additional package dependencies. Existing database and sidecar formats do not
change.

## Synchronized commit mode (experimental)

```luau
local sql = require('@jessql')
local db = sql.open('events.wal', { durability = 'sync', rowLayout = 'packed' })
db:transaction(function(tx)
  tx:insert('events', { id = 1, body = 'hello' })
  tx:insert('events', { id = 2, body = 'world' })
end)
db:close()
```

This example assumes `events` was created in an earlier transaction.

The default `durability = 'buffered'` keeps the existing buffered append path.
`durability = 'sync'` does the following:

- Creates a new WAL with `fs.createDurable()` and does not silently fall back
  when the platform/filesystem refuses it. Unlike buffered mode, parents must
  already exist for durable creation.
- Keeps one append writer open for the database lifetime. Before a transaction
  is acknowledged, writes its complete CRC-framed log record and calls
  `writer:syncData()` successfully. Application state is updated only after
  this synchronization returns success.
- On a write or synchronization failure, poisons the database handle. An
  uncertain outcome requires close/reopen and journal replay; applications must
  use idempotency keys when retrying uncertain commits.
- After recovery trims a torn trailing record, calls `syncAll()` before it
  allows further appends.
- Closes the retained writer before releasing the database lock.

**Checkpoint safety:** The original `db:checkpoint()` writes a new WAL and
replaces the active path with a rename. It is **rejected** in sync mode until
JessQL implements a generation-aware publication and retirement protocol that
can reconcile the platform's namespace persistence guarantees. Buffered-mode
checkpoints retain their existing behavior. Syncing WAL commits is **not** a
claim that snapshot publication, storage controllers, and every filesystem
configuration are proven power-loss safe.

The same durability option is available in `sql.hybrid.open(..., { durability =
'sync' })`, where it applies only to the mutable WAL. Immutable snapshots and
secondary sidecars remain explicit, unpublished candidates.

## Positional cold-page I/O

`sql.paged.open`, `sql.secondary.open`, and `sql.hybrid.open` now accept
`readMode = 'mapped' | 'positional'`. The default remains `mapped` for backwards
compatibility. The new path uses `fs.openPositional()` and retains one unmapped
file handle per snapshot/sidecar rather than creating an OS mapping. It is
propagated through multi-segment hybrid reads and compact index sidecars.

```luau
local db = sql.hybrid.open('events.wal', 'events.cold', 'events', {
  readMode = 'positional',
  durability = 'sync',
  cachePages = 8,
})
```

`positional` avoids the memory-mapping fault hazard when a different process
truncates the same inode; it still requires proper immutable-file ownership and
atomic generation publication by the application. Both I/O modes verify
checksums before serving rows. Neither changes the JQLP2/JQLS1 layouts.

## Measured performance (Linux x64, supplied new Jess runtime)

`bench/runtime-io.jsl` is reproducible with `jess run --trusted --package .`.
The raw alternating measurements are included in `bench/NEW-RUNTIME-RESULTS.csv`.
Four separate runs per configuration, medians:

| Workload | Buffered/mapped | Synchronized/positional |
| --- | ---: | ---: |
| 3,000 random cold reads from 30K rows: CPU | 0.5864 s | 0.5971 s |
| Cold-read process RSS | 36,118 KiB | 33,436 KiB |
| 480 single-row commits: CPU | 0.0114 s | 0.1621 s |
| 480 rows in batches of 32: CPU | 0.0039 s | 0.0110 s |

Synchronized commits cost more and are not comparable with buffered commits for
persistence guarantees. These are CPU times, not p99 latency, and do not measure
power-cut resilience. Benchmark file-system caching and storage hardware matter.

## Future worker-buffer integration

The runtime now exposes immutable `@jess/sharedBuffer` objects and worker
message transport. These should be measured for *cross-VM* page processing,
index building, and independent read workers. Do not convert every ordinary
paged read to a shared buffer by default: sealing/copying can increase both
CPU and resident memory when there is no worker boundary to amortize it over.
The present revision intentionally leaves SQL's single-VM read path unchanged.
