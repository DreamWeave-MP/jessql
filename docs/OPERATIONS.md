# Managed JessQL: operations, inventory, and recovery

**Audience:** application owners and operators of experimental, single-writer
managed databases. This is a fail-closed runbook, not an automated repair tool.
For invariants and module boundaries see [lifecycle architecture](LIFECYCLE-ARCHITECTURE.md).

## Start and inspect

```luau
local sql = require('@jessql')
local db = sql.managed.open('data/events', {
  tableName = 'events', columns = { 'id', 'room', 'body' }, primaryKey = 'id',
  maxHotRows = 10000, maxWalBytes = 64 * 1024 * 1024,
  maxGenerations = 6, compactionFanIn = 3,
})

db:transaction(function(tx)
  tx:upsert({ id = 1, room = 'lobby', body = 'hello' })
end)
print(db:stats().epoch)
db:close()

-- Run only when the managed writer is closed. An exclusive advisory lock is
-- acquired for the duration; the lock file may remain as a harmless artifact.
local inventory = sql.managed.inspect('data/events')
print(inventory.epoch, inventory.walBytes, #inventory.generations)
for _, generation in inventory.generations do
  print(generation.epoch, generation.rowsBytes, generation.deletedBytes)
end
assert(not inventory.walIdentityChecked) -- deliberately NOT a recovery verdict
```

`inspect` is a **metadata inventory**. It validates the manifest framing and
schema, opens the referenced cold generation metadata and verifies its composite
identity, and stats every referenced row file, deletion sidecar, and active WAL.
It **does not** scan all cold payload pages, replay/verify the WAL, certify
transaction correctness, or attempt recovery. An apparently plausible inventory
can coexist with corrupt WAL frames or unreadable rows deeper in a page. It
never initializes a missing database or publishes or retires any generation.
It cannot inspect a managed writer that holds the database lock.

The returned record contains `version`, `epoch`, `tableName`, `primaryKey`,
`columns`, `coldIdentity`, `walBytes`, `walIdentityChecked = false`, and an
ordered `generations` list of `{ epoch, deleted, rowsBytes, deletedBytes? }`.
Byte counts are physical file sizes at inspection time, not net logical
row counts. Inventory includes only files referenced by the manifest (not
scratch files or obsolete orphans).

## The durable-publisher boundary

Manifest publication is a short, lock-owned filesystem operation implemented
in the internal `managed_publication` module. It is **not** a user-replaceable
backend, mod callback, or event subscription point. A failed `flush`, `compact`,
or `checkpoint` before manifest replacement leaves the old WAL authoritative.
Once replacement has been attempted, the caller cannot know which manifest
survived until it closes and reopens the database. Never remove candidate
files or replay transactions based only on the name of the thrown exception.

The test-only publication hook can inject errors at `before-replace`,
`after-replace`, and `after-directory-sync`; it is **not** a power-loss
simulator. See [publication failure boundaries](LIFECYCLE-ARCHITECTURE.md#publication-failure-boundaries)
for the decision table and [test cases](../tests/publication.jsl).

## Acknowledgements and uncertainty

| Symptom | Interpretation | Safe next action |
|---|---|---|
| `transaction` returns normally | Its WAL commit was synchronized; separate auto-maintenance may have failed | Check `maintenanceStatus()`; do not replay the committed operation |
| Post-ack maintenance error in `maintenanceStatus()` | Current budget may fence later writes | Run `flush()` or `checkpoint()` on the original handle; diagnose filesystem space/perms first |
| `uncertain publication` / poisoned handle | Manifest replacement might or might not have happened | Stop writes, `close()`, reopen and compare authoritative state; do not assume rollback |
| `manifest missing but artifacts remain` | Existing namespace might have lost metadata | Stop; preserve all artifacts, restore **a verified matching manifest** or a complete offline backup |
| Checksum/identity mismatch | Disk-format corruption or inconsistent set | Stop; preserve evidence and restore known-good complete backup; **never** guess a generation list |
| Exclusive lock unavailable | Another writer/inspection may be active | Verify process ownership; do not remove a live lock or bypass it |
| `inspect()` succeeds | Published cold-set metadata is internally consistent | **Not** proof of WAL recoverability or power-loss durability |

`maintenanceStatus()` is in-memory and may be inaccessible after close or
poisoning; it is not a persistent issue log. If a synchronized commit's
acknowledgement is lost due to a transport/process failure, applications need
idempotent operation identifiers or a read-after-recovery reconciliation step.
Blind retry can duplicate business actions.

## Backups: only a conservative offline procedure is supported

**There is no online point-in-time backup API.** Copying a live WAL alongside a
manifest and generations can produce an impossible combination. For a backup:

1. Stop accepting writes and wait for outstanding transactions/batches to finish.
2. Close the managed handle cleanly and ensure no other process can open it.
3. Copy the **entire namespace** (manifest, all referenced `.gNNNNNNNN` files,
   and the matching active `.wal`) into a separate directory or volume while
   writers are stopped. Keep names unchanged. Include enough metadata to
   reconstruct the directory layout and the schema. Preserving extra orphan
   files is safer than accidentally omitting a referenced generation.
4. On a *separate scratch copy*, call `sql.managed.inspect()` and then
   `sql.managed.open()` to verify that recovery works and expected data can
   actually be queried. `inspect` alone is insufficient.
5. Store the verified complete backup atomically according to your backup
   system's retention controls. Repeat restoration drills periodically.

These steps are not a guarantee against latent page corruption or power loss
while copying. Filesystem snapshots can be useful only with an independently
validated freeze/snapshot protocol; none is supplied here yet.

## Recovery: protect evidence before touching files

1. Quiesce the application. Record exact errors, platform/runtime version,
   database base path, active epoch if known, and whether an acknowledgement
   was returned to clients.
2. Make a **complete offline copy** of the namespace before attempting
   corrective actions. Preserve candidate manifests and orphaned generations
   as evidence; do not delete files to make the database open.
3. With the database closed, run `inspect()` on the copy. It will refuse an
   invalid/missing manifest or missing/mismatched cold metadata.
4. Try `sql.managed.open()` **on the copy**, which validates the WAL binding
   and replays it. Compare independent application-level counts/IDs.
5. For a missing manifest, restore a **matching manifest from a verified
   backup** or restore the whole verified backup. Never create an empty
   manifest around existing generations or copy a manifest from another epoch.
6. If WAL replay or a page read fails, do not automatically truncate, rebuild
   or rewrite files. Escalate with preserved artifacts and a reproducible test.
7. Only after verified recovery, return the application to service. Keep the
   original evidence until the resolution has been reviewed.

There is currently **no supported manifest reconstruction, arbitrary page
repair, online backup, or forced-open mode**. Design work for those features
must establish explicit evidence-preservation and idempotency guarantees.

## Pre-deployment gates

- Pin the Jess runtime and JessQL package revision. Reproduce
  `jess package test .` (source and packaged-JPK modes).
- Strict-check changed modules and retain known repository-wide debt visibility.
- Restore a test backup. Exercise missing-manifest, corrupted-WAL, disk-full,
  and interrupted-publication paths in a disposable environment.
- Verify exact filesystem replacement and directory sync semantics on each
  target platform; Linux testing alone does not cover Windows/macOS behavior.
- Establish monitoring for WAL/generation sizes, errors, repeated maintenance,
  backups, and disk free space at the application layer; the built-in
  watermarks are not hard quotas or resident-memory accounting.
- Do not describe this engine as production-grade, crash-proof, or faster
  than established databases without representative comparative evidence.

## Error-reporting and instrumentation boundaries

The current API does not expose full structured error codes or a persisted
operator event stream. An application integration can presently poll
`db:stats()` for the active epoch, generation count and configured metered
values, and `db:maintenanceStatus()` for the last maintenance error/poisoning.
Neither is safe to call while an explicit synchronized batch is executing.
Errors include descriptive messages but are not yet a stable typed taxonomy.

For a future Jess ScriptDomain adapter, prefer an **optional** interface that
reads this state and emits best-effort notifications after acknowledgment.
These events must never sit on the durability path and must never become the
sole record of a committed mutation. Durable changefeeds require WAL-derived
sequence positions and replayable subscriber offsets.

## Offline integrity verification (experimental)

After stopping all managed writers, use `sql.managed.verify(base)` or
`sql.managed.diagnose(base)` for a lock-protected, non-repairing full scan of
physical cold pages and the WAL frame stream. An issue contains a stable code
and recovery guidance. The result does **not** validate full semantic replay
or determine uncertain transaction acknowledgments. See
[verification and extension protocol](VERIFICATION-AND-EXTENSIONS.md) for
examples, report fields, limitations and the incident workflow.
