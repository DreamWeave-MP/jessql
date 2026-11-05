# Durable generation publication: developer contract

**Status:** experimental internal protocol. Verified by deterministic fault tests
on the supplied Jess 0.3.0 Linux x64 runtime; not certified for physical
power loss or all platform filesystem semantics.

JessQL uses a single lock-owned synchronous coordinator and a small internal
publication mechanism. The mechanism does **not** own the transaction/WAL
semantics, choose which generations to retain, or expose an application event.
This separation is deliberate: policy and application integrations may change,
but the durable-publication order must not become user-configurable.

## Module responsibilities

| Module | Owns | Does not own |
|---|---|---|
| `managed_manifest` | Schema, identity metadata, CRC-framed serialization | Disk I/O, locks, WAL frames |
| `managed_policy` | Deterministic watermarks and flush/compact decision | Persistence, asynchronous work |
| `managed_publication` | `seal`, known-path removal, durable manifest replace + directory barrier | Lock acquisition, epoch selection, validation of candidate, WAL swap |
| `managed` | Namespace lock, build/verify candidate generations and WAL, handle fencing, activate and retire | Reimplement manifest codec, decide filesystem barrier order |
| `hybrid` / `storage` | Bound WAL identity, synchronization of transaction frames, recovery | Generation manifest activation |

A successful publication is not a transaction acknowledgment. User
transactions are separately acknowledged after WAL synchronization. A
publication can fail after an earlier user transaction was acknowledged:
**that transaction must not be reported as rolled back.**

## Sequence and failure semantics

```text
acquire exclusive namespace lock (managed)
  old WAL and old manifest remain authoritative
  construct immutable generation candidates
  seal candidate rows and deletion sidecar with syncAll + syncDirectory
  open/validate candidate hybrid WAL with exact cold identity
  createDurable(<base>.jql-manifest.tmp, encoded new manifest)
  optional test-only hook: before-replace
  mark publishState.started = true
  replace(tmp, authoritative manifest)
  optional test-only hook: after-replace
  syncDirectory(parent)
  optional test-only hook: after-directory-sync
  coordinator installs the new hybrid and retires only unreferenced files
release exclusive namespace lock (on close)
```

The `started` flag is intentionally one-way: it records the *attempt* to
replace the manifest, never a guarantee that the replace succeeded. Do not
reset it on errors. Do not handle `after-replace` as a safe rollback.

Before replacement is attempted, cleanup may discard **only** unpublished
candidate files. Once it has been attempted, failure poisons the live handle.
Leave old and new storage in place; close and reopen. Recovery verifies the
selected manifest's cold identity and bound WAL, performs a directory-sync
barrier, then may collect unreferenced generations. Failed retirement is
allowed to leak orphans; it must never affect committed visibility.

## Test matrix

`tests/publication.jsl` exercises the internal publisher independently from
the public managed database API:

- `seal()` retains the exact candidate bytes; nonexistent candidate fails.
- Successful publication produces the requested epoch and the documented
  `before-replace, after-replace, after-directory-sync` event order.
- A thrown `before-replace` hook leaves the original manifest authoritative
  and `started = false`, with only a disposable candidate temp file.
- A thrown `after-replace` hook observes `started = true`, with the newly
  replaced manifest visible in the current process.
- A thrown `after-directory-sync` hook still returns an uncertain error,
  not an implicit success.

These tests complement the existing `tests/managed.jsl` restart and generation
cutover tests, including interrupted publication and bound-WAL mismatch.
**Neither test family simulates a torn filesystem replacement under power loss.**
A production release requires independently validated semantics for each
supported operating system/filesystem combination.

## Do not extend at this boundary

No mod callback, Jess `@jess/events` emission, mutable worker message, network
RPC, or user-defined policy may be executed between the new manifest's durable
creation, replacement and parent-directory sync. A failure or callback here
would expand the uncertain-publication window and make correctness depend on
external code. Application events can be generated **after** transactions are
acknowledged, from a separate optional integration layer; they cannot replace
a durable changefeed.

New public extension surfaces should be versioned separately (query providers,
read-only instrumentation, validated maintenance configuration). Internal
`@jessql/managed_publication` must not be advertised as a supported mod API.

## Performance and verification

This extraction adds no per-row hooks and does not touch the synchronized
transaction fast path. Five alternating Linux x64 runs of
`bench/wal-pressure.jsl` at **500 updates**, using the same Jess runtime:

| Configuration | Previous median CPU | Extracted median CPU |
|---|---:|---:|
| No WAL-byte watermark | 147.490 ms | 145.475 ms |
| WAL-byte watermark enabled (not tripped) | 134.374 ms | 137.754 ms |

The runs were noisy (approximately 116–189 ms across the unmetered samples).
These are only regression observations, **not** a speedup or p99 latency
claim; raw CSV samples accompany the replay archive. The changed source and new tests passed strict checking at the time of this
historical publication refactor. **Current JessQL releases require zero strict
errors across the entire package**; see [STRICT-TYPING.md](STRICT-TYPING.md).

## Still outstanding

- Native crash/process-kill and power-fault testing, plus Windows/macOS runs.
- A validated offline whole-page/WAL verification and backup/restore utility.
- Stable structured error codes distinguishing corrupt metadata, missing
  files, invalid WAL identities, and uncertain commits.
- A hard disk-space policy and resident-memory accounting beyond soft
  watermarks; maintenance can still be synchronous and block foreground work.
- A carefully bounded application service/event adapter and a separately
  proven concurrent group-commit writer.
