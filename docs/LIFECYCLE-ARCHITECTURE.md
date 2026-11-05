# Managed lifecycle architecture and extension boundaries

**Status:** experimental; source for `feat/native-persistence`. This document
explains implementation boundaries, not a claim of power-loss-qualified storage.
For practical incident response, see [operator runbook](OPERATIONS.md).

## Dependency direction

```text
@jessql (facade)
  └─ @jessql/managed  — synchronized lifecycle coordinator / public DB API
       ├─ @jessql/managed_manifest — pure JQLM1 codec, schema invariants
       ├─ @jessql/managed_policy   — pure resource-budget decision
       ├─ @jessql/managed_publication — durable sealing + manifest cutover
       ├─ @jessql/managed_verification — offline, non-mutating integrity scan
       ├─ @jessql/managed_observability — bounded events + explicit host adapter
       ├─ @jessql/hybrid           — WAL overlay + cold provider
       ├─ @jessql/paged            — immutable page reader / snapshot writer
       ├─ @jessql/segments         — generation precedence + tombstones
       └─ @jessql/tiers            — bounded cold compaction
  └─ @jessql/engine — query planner and registered provider protocol
```

`managed_manifest` and `managed_policy` are **internal implementation
modules**, not supported extension/versioning contracts. They contain no
filesystem I/O, Jess application-domain dependency, worker API, or mutable
singleton state. The separate `managed_publication` module **does** perform
filesystem operations: it seals generated files and performs the manifest's
`createDurable` → `replace` → `syncDirectory` publication protocol.

`managed.jsl` still owns paths, namespace locks, candidate construction, WAL
binding, active-handle selection, retired-file cleanup, database operations,
and poison/failure fencing. It calls the publication module only while holding
the exclusive managed lock and **after** establishing the candidate WAL/cold
identity. The publisher has no generic callback plugin contract: the optional
`testHook` in the coordinator is for deterministic fault injection only.
Neither internal module nor its ordering/synchronization steps is a stable
modding interface. External application-domain events cannot sit between the
synchronization barriers.

## Non-negotiable invariants

1. A committed transaction is acknowledged only after the WAL sync barrier.
   `transactionBatch()` retains a separate CRC-framed transaction per accepted
   callback while sharing the sync barrier.
2. A manifest references only immutable, sealed generations. The new WAL is
   bound to the exact cold-set identity before publication.
3. Until manifest replacement is **attempted**, the old WAL remains authoritative
   and reusable after a failed candidate build. After an uncertain replacement,
   the in-process handle is poisoned and must be closed/reopened.
4. Never retire a referenced generation or the authoritative WAL. Retirement
   after durable publication can fail safely, leaving orphans for later cleanup.
5. Missing or corrupt manifests are **not** permission to create a new empty DB
   when its namespace still contains artifacts.
6. A post-acknowledgment auto-maintenance failure must never turn a committed
   user write into a reported transaction failure. With configured watermarks,
   subsequent writes are fenced until maintenance succeeds, including on reopen.
7. Callback code inside `transactionBatch()` cannot reenter the outer managed
   handle to read, publish, or close before the group is synchronized.

## Publication sequence

```text
CURRENT WAL + immutable generations
   │ snapshot/delta/compact candidate (without mutating CURRENT)
   ▼
write and seal new immutable files → syncAll → syncDirectory
   │
   ▼
open and bind new WAL to candidate generation identity
   │
   ▼
write durable manifest.tmp
   │
   ▼
replace manifest.tmp → manifest → syncDirectory
   │
   ├── uncertain outcome: poison handle; close/reopen
   ▼
activate new hybrid view → close old view → best-effort retirement
```

### Publication failure boundaries

| Boundary | `started` flag | Manifest authority | Correct coordinator action |
|---|---|---|---|
| Candidate file creation/sealing fails | false | Previous manifest | Discard only unpublished candidates, preserve old WAL |
| `createDurable` or `before-replace` fails | false | Previous manifest | Candidate temp may remain; clean it under the lock |
| Replacement attempted or `after-replace` throws | true | Uncertain until reopen | Poison handle; **do not** retire any old file |
| Directory sync or `after-directory-sync` throws | true | Uncertain to caller | Poison handle; reopen and re-fence directory |
| Publication returns normally | true | New manifest | Activate candidate; retire only unreferenced files |

`started` records the **attempt**, not proof that `replace` returned success
or that the parent directory has been synchronized. This is deliberately
conservative: recovery must read the authoritative manifest, verify cold and
WAL identity, synchronize the directory, and only then admit writes.
The publisher is deliberately synchronous, receives no worker/app-domain
context, and is tested separately in `tests/publication.jsl`. See the
[durable publication developer contract](PUBLICATION-PROTOCOL.md) for the
full state machine and extension restrictions.

The pure manifest module validates **versioned metadata**, ordered generation
numbers, the table schema, and a framed CRC. It does not provide cryptographic
integrity or verify every page. The policy module takes validated limits and
counters and returns `nil`, `flush`, or `compact`; it does not execute either.

### Resource policy

- `maxHotRows` counts live hot rows and tombstones.
- `maxHotBytes` counts logical scalar payload, not resident memory.
- `maxWalBytes` measures the **physical active WAL file** with `fs.stat`.
- `maxGenerations` is an immutable-generation count, not a file-space quota.
- All are optional **soft high-watermarks**. A single acknowledged transaction
  may exceed them. Failures can leak candidate scratch files.
- With **only** `maxWalBytes` configured, the post-commit hot-state stats query
  is skipped. With **no** watermarks, the maintenance policy is not consulted.
- The built-in compaction selection is a deterministic pure policy. We do not
  currently load executable policies from mods. User-defined policy callbacks
  must not be able to bypass safety backpressure or reorder sync barriers.

## What can be extended safely?

| Surface | Today | Rule |
|---|---|---|
| `engine.Provider` / virtual tables | Public query-side provider hooks | Verify handled predicates/order/limits; let engine retain SQL semantics |
| Indexing, page format, compaction strategy | Internal implementations | Benchmark and prove compatibility before versioned capability negotiation |
| Maintenance watermarks | Validated open options | Policy selection is pure; publication remains non-replaceable |
| Inspecting generations | `sql.managed.inspect(base)` | Offline lock, read-only metadata inventory, **not** a WAL integrity check |
| Jess app interfaces / events | **Not yet integrated** | Optional app-domain adapter, after durable acknowledgment; never required by CLI/core |
| Worker actors | **Not yet integrated** | Bound queues and lifetimes; don't move durable sequencing across unverified actors |
| Persistent changefeed | **Not yet implemented** | Requires persisted positions, replay and consumer acknowledgments; Jess events alone are insufficient |

For a query-side extension, start with the provider protocol and examples in
[README](../README.md#provider-protocol). Do not import `managed_manifest` and
modify files behind a running managed handle. Those modules are package-internal
and subject to change without a public schema/API migration commitment.

## Lifecycle contract matrix

| Operation | WAL write | Manifest publish | May leave orphans | Safe retry after error? |
|---|---|---|---|---|
| `transaction()` | Yes, synced | Auto-maintenance only | Yes, if maintenance fails | **No** when acknowledgement is uncertain; inspect/recover first |
| `transactionBatch()` | Separate synced WAL frames | Auto-maintenance only | Yes | Inspect results; uncertain batch requires reopen |
| `flush()` | New identity-bound WAL | Yes | Yes | Only when prior attempt was definitely pre-replace |
| `compact()` | New identity-bound WAL | Yes | Yes | Same publication rule |
| `checkpoint()` | New identity-bound WAL | Yes | Yes | Same publication rule |
| `inspect()` | **No** | **No** | No new data generations | Inspection failure is non-repairing; retry after diagnostics |

A stored prepared plan belongs to its generation: reprepare after a cutover.
The managed API is one table/one writer; it is not MVCC, a durable multi-table
relational transaction engine, or a general clustered storage service.

## Engineering checklist for changes

1. State which publication/transaction invariant is affected; add a failure
   test at the relevant boundary (before sync, after sync, before replacement,
   after replacement, after directory sync).
2. Run both source and packaged tests: `jess package test .`.
3. Run the **whole-package zero-error strict gate**:
   `python3 scripts/check-strict.py /path/to/jess`. Individual-file checks
   are useful during editing but do not satisfy the release requirement.
4. Cover a restart, an injected failure, and an existing-format reopen for any
   disk-format or lifecycle change. Never update active disk files in place.
5. Benchmark opt-in and default execution separately. Include process startup,
   storage mode, sync policy, dataset shape, run count, and variance.
6. Test the same package on Linux, macOS, and Windows before claiming portable
   durability. Exception injection is not a substitute for power-fault tests.

## Refactor performance guard (Linux x64, supplied Jess 0.3.0)

The manifest/policy extraction is not marketed as a speedup. We ran the
existing `bench/wal-pressure.jsl` with **700 synchronized overwrites of one
key**, five alternating runs per tree/configuration, using the same runtime
binary. CPU milliseconds were reported by `os.clock()` inside the benchmark:

| Watermark | Incoming median | Refactored median | Interpretation |
|---|---:|---:|---|
| None | 212.718 ms | 192.419 ms | Different medians, but high run-to-run variance |
| `maxWalBytes` enabled, not triggered | 215.527 ms | 214.039 ms | Essentially unchanged at this resolution |

The raw samples are included in the replay archive. This is **not** a
statistically established throughput improvement, an end-to-end p99 latency
test, or a synchronous-durability power-fault test. The opt-in WAL-only path
still avoids `live:stats()` after each commit; otherwise the refactor would
introduce avoidable query work. Keep this benchmark as a regression guard as
more providers, observers, and worker systems are introduced.

## Verified extension and diagnostic boundaries

The managed kernel offers two separately versioned, **non-durable** services:
`managed.verify` / `managed.diagnose` (read-only offline structural report v1),
and `db:events` / `db:observe` plus `managed.extensions.v1.relay`
(pull-only in-process telemetry v1). Neither exposes publication internals to
application mods. The host calls `relay` outside critical sections; no event
callbacks run on transaction commit or filesystem publication. See
[Verification and Extensions](VERIFICATION-AND-EXTENSIONS.md) for limits and
recovery contracts.
