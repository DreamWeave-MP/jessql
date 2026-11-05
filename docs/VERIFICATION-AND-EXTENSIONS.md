# Offline verification, recovery diagnostics and versioned integrations

**Status:** experimental interfaces for `feat/native-persistence`. This guide
is an implementation contract, not a physical power-loss certification. All
examples use the source package `@jessql` on Jess 0.3.0 / Luau 0.745.

## Three different operator tools

| Operation | Requires exclusive managed lock | Scans WAL frames | Reads every cold page | Repairs data |
|---|---:|---:|---:|---:|
| `managed.inspect(path)` | yes | no | no | no |
| `managed.verify(path)` | yes | yes | yes | **never** |
| `managed.diagnose(path)` | yes | yes | yes | **never** |
| `managed.open(path)` | yes | replays | on demand | may truncate a recoverable WAL tail |

`verify` and `diagnose` are identical, full offline scans. Neither opens a
writable WAL, removes orphans, creates generations, nor replaces the manifest.
The lock acquisition may create the **advisory `.jql-lock` file**; it does not
change database contents. Stop the writer and ensure the filesystem supports
exclusive locks before attempting verification.

```luau
local sql = require('@jessql')
local report = sql.managed.verify('data/events')
print(report.version, report.disposition, report.epoch)
print(report.coldRowsScanned, report.walFrames, report.walBytes)
for _, issue in report.issues do
  print(issue.stage, issue.code, issue.message, issue.recovery)
end
if not report.ok then error('database requires operator investigation') end
```

### Report v1

- `version = 1`; `disposition = 'structurally-verified'` or
  `'requires-operator-review'`; `ok` is **structural** status only.
- `epoch`, `manifestVersion` are absent when decoding the authoritative
  manifest fails. No alternate or orphan manifest is silently selected.
- `coldPagesChecked` confirms full traversal of **every physical generation**
  and tombstone sidecar, including rows hidden by newer generations.
  `coldRowsScanned` includes sidecar records and shadowed physical rows.
- `walFramesChecked` indicates that the WAL scan reached its end with
  continuous sequence numbers, size bounds and valid frame checksums.
- `walIdentityChecked` indicates presence of an identity binding to the exact
  active cold generation set and table name.
- `walSemanticReplayChecked` is **always false in v1**. An intact, syntactically
  plausible transaction can still fail when semantically replayed by the
  storage engine. `verify().ok` is *not* sufficient to declare `open()` safe.
- `issues[]` contains stable `stage`, `code`, `message`, `recovery` fields.
  Codes include `MANIFEST_INVALID`, `MANIFEST_UNREADABLE`, `COLD_INVALID`,
  `WAL_TORN_TAIL`, `WAL_CHECKSUM_MISMATCH`, `WAL_SEQUENCE_INVALID`,
  `WAL_IDENTITY_MISMATCH`, `WAL_IDENTITY_MISSING`,
  `WAL_OPERATION_INVALID`, `WAL_FRAME_LENGTH_INVALID`, and
  `WAL_DECODE_OR_IO_FAILED`. Diagnostics can evolve by adding new codes.

### Incident handling

1. Stop every writer and retain the complete database directory intact.
2. Run `inspect` for a quick inventory, then `verify` for the more expensive
   read-only scan. Save the report and original manifest; never overwrite them
   in the course of diagnosis.
3. For a torn WAL tail, preserve the original bytes **before** allowing a
   normal `open()` to perform its documented tail recovery. This report does
   not say which pending transactions were acknowledged externally.
4. A missing/corrupt manifest or identity mismatch is a hard stop, not
   permission to reset the namespace. Restore from a consistent backup.
5. A structurally clean report does not replace full replay testing, cold
   semantic validation, transaction reconciliation or physical fault testing.

No repair, online backup, replication, snapshot-consistency or salvage API is
introduced here. Never use this verifier as a write authorization protocol.
It may perform large, multi-hour linear scans on sufficiently big databases;
run it during an explicit offline maintenance window.

## Observability contract v1

`db:observe()` returns **a copy** of the current in-process management state:

```luau
local current = db:observe()
print(current.version, current.epoch, current.generations)
print(current.poisoned, current.maintenanceError)
print(current.limits.maxHotRows, current.limits.maxWalBytes)

local batch = db:events(0)
print(batch.version, batch.cursor, batch.dropped)
for _, event in batch.events do
  print(event.sequence, event.kind, event.epoch, event.detail)
end
```

The event ring retains at most **64** events per handle, with monotonically
increasing sequence numbers. `db:events(after)` returns copies and a new
cursor, plus `dropped` if the requested position fell outside the ring.
`after` must be a valid cursor from that handle; cursors and events do **not**
survive close/reopen. Reopen starts at a new sequence space.

Current event kinds: `opened`, `recovery-budget-pressure`,
`generation-published`, `maintenance-failed`, `publication-aborted`, and
`publication-uncertain`. Observers may read a poisoned handle (but cannot
write through it) until it is closed. Normal per-transaction writes do not
emit events, keeping the synchronized hot path free of observer work.

This is **best-effort operational telemetry**, not durable change-data capture,
transaction notification, event sourcing, an exactly-once feed, or a stable
transaction sequence. Consumers must handle event loss, duplicates when
retrying delivery, and future event-kind additions.

## Versioned extension adapter v1

`sql.managed.extensions.v1.relay(batch, callback)` is invoked **explicitly**
by the application/mod host, after the database method has returned:

```luau
local cursor = 0
local batch = db:events(cursor)
if batch.dropped ~= 0 then
  -- Reconcile externally: some ephemeral observations are gone.
end
local result = sql.managed.extensions.v1.relay(batch, function(event)
  -- The host may forward to @jess/events when an application domain exists.
  -- This callback is not called from a WAL commit or generation publication.
  print(event.kind, event.epoch)
end)
if result.ok then cursor = result.cursor
else cursor = result.cursor  -- retry from the first undelivered event
end
```

`relay` copies each event into the listener, catches listener failures,
returns `version=1`, `ok`, `cursor`, and `error`, and does not affect database
transactions. The delivery cursor advances only past successfully delivered
observations. It does not guarantee external side effects were atomic;
receivers must tolerate at-least-once redelivery.

There is deliberately **no** dependency on `@jess/events`,
`@jess/interfaces`, application-domain lifecycle, worker threads, or mod
loader APIs inside the durability kernel. A Jess application may adapt the
versioned feed to those interfaces, with capability grants and domain
lifecycle decisions made by the host. The storage module must never call an
untrusted mod between WAL append and synchronization, or before a manifest
publication fence.

The separately supported query extension boundary remains
`engine.Provider` / `_jessqlIter = 'v1'`. Internal manifest/publisher/WAL
functions are **not** extensibility points and must remain inaccessible to
application observers. Any future pluggable compaction-policy API must have
separate deterministic contracts, limits and adversarial tests before it can
participate in database scheduling.

## Strict type-checking policy

The lexer and parser now pass Jess strict checks; the existing type errors
are all in `src/engine.jsl`. Rather than hiding them with `any` or disabling
strict mode, the repository has a reproducible non-regression gate:

```sh
jess package test .
python3 scripts/check-strict.py /path/to/jess
```

`scripts/check-strict.py` checks **every** `src/*.jsl` file and the two new
test modules, permits at most **453** existing `engine.jsl` errors, and permits
**zero** errors in every other source file. This is a ceiling to decrease,
never a license to add new errors. The remaining engine debt is a merge
blocker for claiming entire-repository strict cleanliness; a later focused
refactor should address the checker issues by typed AST/value operations,
not by suppressions. No current GitHub workflow is asserted to execute this
script automatically; wire it into the appropriate pinned Jess/StroggForge
CI gate before treating enforcement as continuous.

## Security, scope and performance

- Verification uses reader handles and a single-page cache per opened cold
  file; WAL frames are processed one at a time (bounded at 16 MiB each).
  Runtime/page directory memory and oversized external metadata remain
  separate limitations.
- The offline scan is **O(total physical cold rows + WAL bytes)**; it is not
  invoked during commits, startup, or ordinary queries.
- Observability allocates only on lifecycle events and explicit reads; no
  user callback, network operation or durable event write is added to commits.
- Reported checks do not simulate kernel crashes, fsync lies, dropped caches,
  disk controller failures, multi-process misuse, or Windows/macOS semantics.
- A version number is an API-format marker, not permission to reinterpret
  WAL contents, change durable manifest schema or skip compatibility checks.

## Semantic WAL audit and offline copies

`managed.verify(path, { semantic = true })` now validates WAL operations by
replaying them in transient storage state. The default remains structural for
compatibility. `managed.backup` and `managed.restore` copy only closed, verified
namespaces to unused destinations. See [the v1 offline copy contract](OFFLINE-VERIFICATION-AND-BACKUP.md).
