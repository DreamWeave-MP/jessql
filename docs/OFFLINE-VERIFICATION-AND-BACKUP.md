# JessQL offline verification, backup, and restore (v1)

The managed namespace is still **one writer, one table**, and uses advisory locks.
This interface performs **offline** work only. It is not a snapshot API for a
running database. Neither structural nor semantic verification establishes
power-loss correctness, disk-controller integrity, or cross-platform guarantees.

## Verification modes

```luau
local sql = require('@jessql')

-- Always close the writer first. The verifier acquires the managed lock.
local structural = sql.managed.verify('data/events')
assert(structural.ok and structural.walFramesChecked)
assert(not structural.walSemanticReplayChecked)

-- Explicit, slower audit. The WAL is decoded and replayed into *temporary*
-- in-memory state through the storage engine's transaction validators.
local deep = sql.managed.verify('data/events', { semantic = true })
assert(deep.ok and deep.walSemanticReplayChecked)
print(deep.disposition) -- 'semantically-verified'
```

Both modes scan all physical cold generation rows and deletion sidecars,
including rows currently shadowed by a later generation. Both validate WAL
frame lengths, CRCs, sequence continuity, and cold-set identity. The semantic
mode additionally replays every WAL transaction using the same schema,
uniqueness, and scalar validation as normal database recovery. This catches
CRC-correct but logically invalid operations, not merely damaged framing.

Semantically verifying a large WAL can use **memory proportional to replayed
live WAL state**. It does not provide a bounded-memory audit; use maintenance
and a controlled maintenance window before attempting it. `verify()` retains
structural mode as the default for compatibility with existing callers.
`diagnose()` accepts the same options.

A failed scan returns a version-1 report with `ok = false`, an issue code and
operator-oriented recovery guidance. The verifier never truncates, repairs,
initializes, or publishes any data. Existing lock artifacts may remain.

## Offline backup and restore

```luau
-- Writer must be closed, destination parent must already exist, and the
-- destination database namespace must be completely unused.
local result = sql.managed.backup('data/events', 'backups/events-2026-11-05')
assert(result.version == 1 and result.semanticVerified)
print(result.epoch, result.files, result.bytes)

-- Restore into a NEW, empty namespace. No overwrite/merge is supported.
sql.managed.restore('backups/events-2026-11-05', 'data/recovered-events')
local recovered = sql.managed.open('data/recovered-events')
-- Application-specific checks should happen here.
recovered:close()
```

The backup/restore APIs share the same implementation. The source and
Destination namespace locks are acquired in a deterministic path order to
avoid deadlocks. The source is fully verified **before copying**. Every
referenced immutable generation, deletion sidecar, and the active WAL is copied
in bounded 256-KiB chunks. Individual output files are synchronized; the
manifest is created and synchronized **last**. The destination is then
semantically verified under its lock before the copy reports success.

A destination is **never overwritten**. Any preexisting manifest, pending
manifest, or generation-named artifact causes refusal. A failed copy may leave
partial files behind; those artifacts intentionally block reuse until an
operator inspects and explicitly cleans that destination. Do not blindly
retry over incomplete output. The source is never modified.

The copy contains only manifest-referenced files, not orphaned generations,
publication candidates, or diagnostic evidence. For forensic preservation,
make a separate byte-for-byte namespace copy using an appropriate operational
procedure before running repair attempts. Backups are not automatically
retained, checksummed in an external catalog, encrypted, transmitted to another
machine, or protected against simultaneous third-party filesystem modification.

## Failure domains and deployment rules

- `fs.lock()` is advisory and requires all JessQL writers to cooperate.
  External filesystem modification bypasses the lock and invalidates guarantees.
- The source must not be used concurrently by another application process or
  opened writable while a copy is in progress.
- A restore must target a *different* empty database basename. To replace a
  broken database, retain the broken namespace and restore to a new name, then
  switch applications to that new path after validating application invariants.
- A returned success means JessQL synchronized the copied files and directory
  and validated the destination using the supplied runtime. Hardware power
  failure, disk firmware lies, Windows/macOS semantics, and storage-device
  durability require separate testing.
- A backup is not an application consistency assertion: validate expected
  schema, counts, IDs, business events, and retention independently.
- `verify({semantic=true})` doesn't certify that the cold and WAL combination
  satisfies every higher-level query invariant. Do a read-only query audit on
  a restored copy and keep at least one older known-good backup.

No extension or event listener runs inside these operations. The publication
kernel, storage validation, and synchronization barriers remain non-moddable.
