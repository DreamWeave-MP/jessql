# JessQL adversarial architecture review — November 2026

Status: **experimental; not production-durability-certified**. This review uses
`feat/native-persistence` after the explicit synchronized group-commit work.
Source and packaged JPK suites are exercised on the supplied Jess 0.3.0 /
Luau 0.745 Linux x64 runtime. A passing test does **not** prove power-cut
survival, cross-platform crash consistency, isolation, or competitive speed.

## Demonstrated findings and corrections

| Severity | Finding | Evidence | Status |
| --- | --- | --- | --- |
| P0 | Missing `.jql-manifest` could be mistaken for first initialization. The old bootstrap cleared an existing generation-one WAL and acknowledged rows disappeared. | Create, commit, close, remove manifest, reopen, check lost row and replaced WAL. | **Fixed:** absent manifest with any recognized generation artifacts or manifest candidate fails closed; clean initial namespaces still initialize. |
| P1 | A live-row/payload watermark did not bound the WAL under repeated overwrites or insert/delete churn. | 4,000 tiny updates of one key left 1 live row, 7 payload bytes, ~440 KiB WAL. | **Fixed when opted in:** `maxWalBytes` triggers synchronized delta retirement, including a logically empty overlay. |
| P1 | A failed row-threshold maintenance attempt allowed subsequent writes; restart could drop the in-memory failure flag. | Inject failure after a committed write crosses `maxHotRows`. | **Fixed:** write admission fences and recovery checks row pressure as with payload and WAL budgets. |
| P2 | The outer database handle exposes a committed-state view during an ordinary transaction, while `tx:get` / `tx:query` expose staged changes. | Existing `tests/storage.jsl` explicitly expects the old row through `db:get` inside a transaction. | **Preserved deliberately:** changing this would break an intentional contract; documented explicitly. The transaction view is required for read-your-writes. Batches already reject outer-handle reads. |

For a missing manifest, JessQL cannot automatically infer which manifest to
restore. **Restore it from a verified backup or explicitly remove the entire
old namespace after independent verification; never auto-reinitialize over
unknown database artifacts.** This is a fail-closed safety improvement, not a
manifest reconstruction or backup/restore feature.

`maxWalBytes` is an **optional soft watermark** from 1024 through
1,000,000,000,000 bytes. When enabled, JessQL calls `@dream/fs.stat` after an
acknowledged transaction to monitor the active WAL's *physical* file size. It
rotates the WAL via the existing manifest-backed delta transition; if the hot
overlay has no surviving rows, an empty delta is still publishable. On failure,
the acknowledged transaction remains acknowledged and later writes are
blocked until manual maintenance succeeds. After reopen, a WAL already over
the configured budget starts in backpressure. `stats().walBytes` is available
when the budget is enabled and `nil` otherwise.

This is **not** a pre-admission size cap: one transaction can overshoot it.
It is **not** a hard disk-space quota, RSS quota, or total storage cap. A
failed filesystem operation may also retain obsolete candidate files. The
budget is an open-time operator policy, not persisted in the manifest: callers
must supply it on every restart. That makes the contract weaker than a
centralized, immutable resource policy.

`maxHotRows` and `maxHotBytes` remain *logical live-state* measurements and
likewise can be exceeded by an already committed operation. Their failure
handling is consistent with WAL budget when the same options are supplied
on recovery.

## What is actually good

- The database components are all JSL and packageable as a Jess JPK, without
  delegating transactional storage to SQLite. The in-memory query engine and
  `engine.Provider` abstraction already support alternate backing providers.
- Managed WAL commits use retained fail-closed writers with `syncData()`
  before success; generation publication uses sealed files, durable manifest
  replacement, directory synchronization, and identity-bound WAL reopening.
- Immutable deltas, tombstone-safe merge, bounded fan-in sorting, and selected
  newest-generation compaction avoid frequent full-database rewrites.
- Ordinary source and packaged tests, deterministic restarts, CRC framing,
  fault injection, and strict checking of changed files are useful gates.
- `transactionBatch` preserves independent WAL frames, a single final sync,
  failed-callback isolation, and uncertain-outcome poisoning. It is **not** a
  concurrent writer, queuing system, or proof of p99 improvement.

## Architecture liabilities and proposed boundaries

**Managed lifecycle (`src/managed.jsl`):** manifest validation/encoding,
namespace initialization, directory I/O, generation sealing, maintenance
policy, WAL binding, retirement, and user API are packed into one module.
That makes critical invariants harder to audit. Break it into small private
modules as changes require them: a *pure manifest codec and validator*, a
*durable publisher* responsible for barrier ordering, a *generation catalog*
for retirement/recovery, and a *maintenance policy* that decides flush versus
compaction without performing I/O. Keep the durable publisher non-pluggable.
Do not create public extension points that allow mods to weaken sync barriers.

**Storage and hybrid (`src/storage.jsl`, `src/hybrid.jsl`):** both mix
transaction state, query planner/provider wiring, index maintenance, and
recovery behavior. The long-term split should separate a WAL-framed
transaction engine, hot-store/index implementations, and provider adapters.
Avoid a rewrite merely for file-size aesthetics; extract around tests and
stable interfaces, not abstract class hierarchies.

**Query engine (`src/engine.jsl`):** the existing `Provider` interface is a
valuable, real seam. Maintain it as the single query-side provider contract;
version capabilities (ordering, projection, indexed ranges, statistics)
before exposing third-party providers. `explain()` should indicate why an
index/scan was chosen and whether it falls back to materialization.

**Extension points:** preferred safe and bounded hooks are *pure maintenance
policy*, *query provider*, *custom read-only virtual table*, and *metrics /
observation*. Do not make WAL checksums, ordering, manifest publication, or
recovery semantics overrideable by mods. Version any public interfaces and
make default behavior deterministic when a plugin is missing.

## Jess interfaces, events, and workers

We are exploiting the lower-level Jess filesystem, JPK packaging, Luau native
annotations and data/buffer operations. We are **not yet composing the
high-level application interfaces/events** in JessQL. That is partly
intentional and technically correct:

- `@jess/events` is an **application ScriptDomain queue**, not a general
  synchronous callback bus. It is unavailable in standalone CLI/test/worker
  contexts. A publication attempt during WAL sync must not make a durable
  transaction fail or silently drop the only record of a committed change.
- `@jess/interfaces` resolves managed-module overlays in application domains;
  it is not a universal service locator callable inside arbitrary workers.
- Build an **optional Jess application adapter**, not a hard `@jess/events`
  dependency in the storage core. Expose read-only status and maintenance
  requests through a versioned interface. Emit bounded, best-effort
  notifications *after* acknowledgment; for a guaranteed changefeed, use a
  persisted WAL-derived cursor/outbox with replay and consumer offsets.
- Background workers and immutable shared buffers are plausible for
  compaction and partitioned scans, but require sealed input lifetimes,
  bounded queues, cancellation, and benchmarks that include message overhead.
  Do not force single-VM point queries through workers without evidence.

## Durability and correctness gaps that still block production claims

1. **Crash testing:** injected Luau exceptions are not SIGKILL, kernel panic,
   disk-full, torn write, lost-directory-sync, or power cut. Need process-level
   kill-point testing, block-device fault injection, and per-platform
   persistence tests (Linux, Windows, macOS) on actual storage.
2. **Recovery tooling:** no supported backup/restore, manifest recovery,
   verified offline checker, schema migration, or format upgrader. Unknown
   artifacts now cause a deliberate startup refusal, not automatic repair.
3. **Identity strength:** manifest/WAL/snapshot CRC-based identities detect
   common accidents but are not cryptographic integrity guarantees or
   substitutes for verifying all cold pages. Page validation is partially
   demand-driven; corruption of untouched pages can stay latent.
4. **Resource bounds:** logical payload, active-WAL size and hot-row budgets
   are soft policies. Resident Luau tables, packed-column arenas, caches,
   scratch exports, compaction working sets, and aggregate disk usage still
   lack a common hard bound. File-format offset limits and eight-generation
   cap matter for large installations.
5. **Transaction semantics:** only a single managed table and one writer; not
   full relational MVCC/snapshot isolation or a generalized multi-table
   transactional managed database. Uncertain acknowledgments require an
   application-level idempotency policy before blindly retrying.
6. **Operational visibility:** expose WAL bytes, generation sizes, write and
   sync latency histograms, compaction backlog, last durable epoch, recovery
   outcome, poison/maintenance status, and bounded error categories. Durable
   commit telemetry must be defined independently of optional Jess events.
7. **Static-check debt (historical finding):** At the time of this audit,
   the repository-wide strict checker reported 482 diagnostics. **This finding
   has since been resolved.** The current zero-tolerance release gate checks
   source, tests, and benchmarks; see [STRICT-TYPING.md](STRICT-TYPING.md).

## Benchmarks: interpretation over slogans

The grouped-commit result (960 commits: about 262.5 ms individual vs about
28.3 ms in groups of 32 on one Linux setup) is evidence that batching
synchronization is valuable *in that workload*. It is not measured p99
latency, concurrent throughput, steady-state compaction performance or
proof against SQLite/RocksDB/PostgreSQL.

The new WAL-budget benchmark (`bench/wal-pressure.jsl`) runs 1,500
synchronized overwrites under a high, non-triggering `maxWalBytes` versus no
WAL budget. Ten unpaired alternating measurements on the supplied Linux
runtime had median CPU times near **423 ms (on)** and **437 ms (off)**, with
large run-to-run overlap. They do **not** establish a speedup or reliable
negligible overhead; host caching and scheduling are confounders. The
benchmark file and raw samples are shipped so this can be repeated on a
controlled host.

Performance claims going forward need reproducible seeded data, equal schema
and indexes, equal durability promises, matching batching behavior, warm and
cold tests, end-to-end p50/p95/p99 latencies, peak RSS, compaction/write
amplification, and sustained workloads. Do not combine CPU time and wall
latency or call software-fault injection a physical power-cut test.

## Recommended release gates before a worker actor

**First:** require complete fail-closed namespace initialization (corrected
here), run fault recovery for every publication boundary, and maintain
strict no-regression checks. **Second:** define one versioned storage
operation/outcome interface, report ambiguous outcomes explicitly, and add
idempotent request handling above WAL sync. **Third:** add an offline
verification/backup story and harden schema/migration contracts. **Fourth:**
measure sustained ingestion, compaction interference, memory amplification,
and the opt-in WAL-stat cost on controlled hardware. **Only then:** prototype
a bounded writer queue with proper request cancellation, per-request
acknowledgment, admission backpressure, and p99 latency gates.

The credible aspiration is a high-performance database with demonstrable
safety properties, not the unqualified "fastest and safest" label.
