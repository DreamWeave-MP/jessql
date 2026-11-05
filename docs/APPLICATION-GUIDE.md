# JessQL managed databases: application developer guide

**Status:** JessQL 0.2.0 managed synchronous persistence (single writer), tested on
Jess 0.3.0 / Luau 0.745 on Linux. This is a normal JPK API, not a feature-flagged
opt-in; physical power-loss and other-platform durability are **not certified**.
This guide covers the synchronous managed database, not the separate in-memory or raw WAL APIs.

## Choose an opening intent

All paths are **database basenames**, not directories. Their parent directory must exist.
A managed database owns a manifest, one WAL and zero or more immutable generation files;
never rename or delete individual members while it is open.

| API | Existing namespace | Entirely new namespace | Recommended use |
|---|---|---|---|
| `managed.create(base, options)` | Refuses | Creates | Installation and explicit provisioning |
| `managed.openExisting(base, options?)` | Reopens and recovers | Refuses | Ordinary application startup |
| `managed.open(base, options?)` | Reopens and recovers | Creates when full schema supplied | Backward-compatible open-or-create |

All three acquire the namespace lock **before** examining the manifest. A lost
manifest with surviving database artifacts is never silently bootstrapped.
`create` also refuses a namespace already in use by another JessQL writer.

```luau
local sql = require('@jessql')

local config: sql.ManagedOptions = {
  tableName = 'events',
  columns = { 'id', 'room', 'body' },
  primaryKey = 'id',
  maxHotRows = 10000,
  maxWalBytes = 8 * 1024 * 1024,
  maxGenerations = 6,
}

-- Execute once during provisioning (and do not swallow a failure):
local created = sql.managed.create('data/events', config)
created:close()

-- Normal startup thereafter:
local db: sql.ManagedDatabase = sql.managed.openExisting('data/events', config)
db:insert({ id = 1, room = 'lobby', body = 'hello' })
local row = db:get(1)
db:close()
```

For one-shot operations, prefer the scoped variants. They always attempt to
close the database and release its lock, including when application code throws.
The callback has one return value, and it must **not retain the handle** after
returning. Returning a query result or a plain value is fine; returning a
prepared plan bound to the closed database is not.

```luau
local count = sql.managed.withExisting('data/events', nil, function(db)
  local result = db:query('SELECT COUNT(*) AS n FROM events')
  return result.rows[1].n
end)

-- withNew(...) and withOpen(...) follow the same callback shape.
```

If a callback fails **after** committing a transaction, closing the database
cannot roll that transaction back. The helper propagates the callback error;
its lock cleanup is not an automatic transaction boundary. If close also fails,
the error reports both failures rather than claiming successful cleanup.

## Transactions, writes and maintenance

- `db:transaction(function(tx) ... end)` runs a synchronous transaction. Use
  the `tx` view for *read-your-writes*; `db:get()` inside the callback still
  sees the preceding committed state, not the transaction's staged writes.
- `db:transactionBatch({...})` puts **independent WAL transactions** behind
  one synchronization barrier. A callback that fails is not committed; a disk
  error during append/sync can make the batch outcome **uncertain**. Do not
  blindly retry such a request. It is not a concurrent writer queue.
- `db:flush()` publishes a hot delta; `db:compact()` merges newer generations;
  `db:checkpoint()` makes a complete immutable snapshot. These are synchronous
  maintenance operations, not background work.
- `maxHotRows`, `maxHotBytes`, and `maxWalBytes` are **soft watermarks**.
  The byte limit measures scalar hot payload, not resident memory; the WAL
  limit accounts for active journal size. Neither is a hard memory/disk quota.
- After a committed write, automatic maintenance may fail. The write remains
  acknowledged; with a configured watermark, further writes can be fenced
  until an explicit successful flush/checkpoint resolves pressure.

```luau
local status = db:maintenanceStatus()
if status.lastError then
  -- Stop accepting writes; log and inspect the error. Do not delete files.
  print('maintenance needs attention:', status.lastError)
end
```

A poisoned handle after uncertain generation publication must be **closed and
reopened**, not used for queries, maintenance, or retries.

## Observability and safe application extension

`db:observe()` is a version-1 snapshot of in-process state. `db:events(cursor)`
is a bounded, **ephemeral** lifecycle-event feed; neither is change-data capture.
Events are lost across process restarts and may be dropped when the ring fills.
Use the `dropped` count to detect incomplete telemetry, not to infer WAL loss.

```luau
local batch: sql.ManagedEventBatch = db:events(0)
if batch.dropped > 0 then print('lifecycle events were dropped', batch.dropped) end
local outcome = sql.managed.extensions.v1.relay(batch, function(event)
  -- The application host invokes the relay outside of database operations.
  print(event.kind, event.epoch)
end)
if not outcome.ok then print('extension failed:', outcome.error) end
-- Resume from outcome.cursor after a failed delivery when still on this handle.
```

The v1 relay validates the entire supplied batch **before** calling a sink;
malformed metadata, noncontiguous sequences, and invalid cursors are refused.
A failing sink leaves its undelivered events unacknowledged. Mods cannot
replace WAL synchronization, manifest publication, or recovery logic. Do not
register application-domain `@jess/events` callbacks on the commit path.

## Diagnostics, backup and recovery

Stop the writer and close the handle before offline operations:

```luau
local report = sql.managed.verify('data/events', { semantic = true })
if not report.ok then
  for _, issue in report.issues do
    print(issue.code, issue.message, issue.recovery)
  end
  error('JessQL requires operator investigation')
end
local copy = sql.managed.backup('data/events', 'backups/events-001')
print(copy.semanticVerified, copy.files, copy.bytes)
```

`inspect` is a quick inventory and does **not** verify WAL frames; `verify` and
`diagnose` read cold pages and validate WAL structure; opt into `{ semantic =
true }` to replay WAL operations through storage semantics. The offline copy
protocol refuses existing destinations, verifies the source semantically, and
publishes the destination manifest last. It requires a closed writer,
cooperative filesystem locks and a pre-existing destination parent.

For full failure modes and backup limitations, read
[operations](OPERATIONS.md), [offline verification and backup](OFFLINE-VERIFICATION-AND-BACKUP.md),
and [publication protocol](PUBLICATION-PROTOCOL.md).

## Compatibility and deployment checklist

1. Pin a tested Jess runtime, package version, and storage/schema contract.
2. Create databases explicitly; use `openExisting` on routine startup.
3. Close handles deterministically, or use scoped helpers.
4. Do not silently retry uncertain acknowledgements or corrupted recovery.
5. Back up and restore **offline** into a new namespace; verify business data.
6. Test on every deployed operating system. Current validation is primarily
   Linux; this package has no power-cut certification or multi-writer support.
7. Measure load, p99 latency, RSS, WAL growth and compaction interference
   before treating an application as production-ready.
