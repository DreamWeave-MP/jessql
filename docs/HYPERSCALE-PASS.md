# JessQL pre-runtime hyperscale pass

This is an **experimental, fully JSL** feature/performance pass built against
Jess 0.3.0, continuing the existing `feat/native-persistence` branch. There is
no SQLite dependency and no requirement for new L3i filesystem bindings.

## 1. Indexed hybrid reads no longer scan the entire hot tier

When an immutable `(partition, order)` sidecar can satisfy a query, JessQL now:

- Retrieves only hot rows in the requested partition using a persisted hot
  equality index, created after verifying the WAL's cold-snapshot identity.
- For each cold indexed candidate, checks only that candidate's hot primary
  key and deletion marker before emitting it.
- Preserves the unindexed fallback when indexed-value types are inconsistent
  or a query is not supported by the accelerated path.
- Uses bound SQL parameters rather than injecting filter values into SQL.
- Preserves transaction read-your-writes and cold/hot shadow precedence.

The general, unindexed hybrid scan still materializes hot records. That path
remains a scaling target rather than being advertised as bounded-RSS.

### A/B benchmark: 12,000 cold + 12,000 hot records

250 partitioned ordered queries, 64 rooms, packed WAL, one compact cold index.
Three fresh-process alternating runs of each revision, identical checksum
`229503516` and 4,000 returned rows in every run:

| Revision | Median query CPU | Median peak RSS |
| --- | ---: | ---: |
| Previous | 5.176 s | 67,620 KiB |
| Optimized | 0.353 s | 41,760 KiB |

**14.6x lower query CPU** and **38% lower process RSS** for this particular
workload. Hot-index construction is accounted separately in open time; median
open CPU remained around 0.11 seconds. This is not a universal benchmark.

To reproduce: `jess run --package . --trusted bench/hot-shadow.jsl prepare
12000 12000 250`, then use `read` in a separate process. `cleanup` removes
fixture files.

## 2. Complete indexed delta candidates

`hybrid:exportIndexedDelta(rowsPath, deletePath, indexPath, partition, order,
 deltaOptions?, indexOptions?)` creates a row snapshot, its matching deletion
sidecar, and a snapshot-bound secondary index, returning independent build
metrics. It checks the index by reopening it against the produced snapshot.

If any step fails, the unpublished candidate files are discarded. Existing
candidate filenames are rejected. The original hot WAL remains open and
unchanged. **This method does not publish a new generation, retire a WAL,
rotate a journal, or make buffered writes power-loss durable.**

## 3. O(1) LRU page eviction

Immutable page readers use an intrusive doubly-linked LRU chain keyed by page
number. Cache hits and victim selection are O(1), rather than scanning every
cached page to find the smallest age. Page-count budgets and CRC verification
are unchanged; the on-disk `JQLP2` format is unchanged.

At 12,000 one-record pages, 6,000 cold misses, `cachePages=512`, all six runs
had identical checksum `36027000`, page reads `6000`, and cache residency
`512`. Alternating-run median CPU was **0.181 s -> 0.150 s**, approximately
**1.21x faster**. Peak RSS was noisy and did not consistently improve.
Reproduce using `bench/paged-cache.jsl` with `prepare`, `read`, `cleanup`.

## 4. Tiered compaction with tombstone propagation

`sql.tiers.compact(outputRows, outputDeletes?, paths, {
  fanIn = 4, cachePages = 1, deletePaths = { [generation] = path },
})`

accepts an ordered list of immutable generations (oldest first) beyond the
previous eight-file per-view limit. It compacts groups of at most `fanIn` into
exclusive temporary JQLP2 snapshots, repeats the process through as many
levels as needed, and emits a new **unpublished** candidate generation.

It merges immutable deletion sidecars as sorted streams. A deletion is retained
only when the resulting compacted group does not contain a live reintroduced
row. This prevents compaction of one tier from resurrecting an older row in a
different tier. For deletion-bearing inputs an output deletion path is required;
refusing it is safer than silently dropping tombstones.

All original generation files remain untouched. Scratch files are cleared on
successful completion and caught failures. A final output path is never
unlinked by cleanup unless this invocation successfully created it. An
exclusive scratch owner file prevents concurrent builders from sharing names.
The disk format and read-time generation limit (`segments.open` max eight) are
unchanged; `tiers.compact` is for reducing *candidate* generation fan-in, not
for automatically activating unlimited live generations.

### Benchmark: 20 generations, 5,000 physical rows each

100,000 physical rows, 88,125 logical rows after overwrite reconciliation,
checksum `3883983125`, identical for fan-in four/eight. Three runs each:

| Fan-in | Median CPU | Median peak RSS | Merge passes | Groups |
| --- | ---: | ---: | ---: | ---: |
| 4 | 1.717 s | 37,360 KiB | 2 | 7 |
| 8 | 1.244 s | 37,944 KiB | 1 | 4 |

These measurements include buffered file output, but **not** durable sync.
Run `bench/tiers.jsl` with `prepare`, `compact`, `verify` and `cleanup`.

## Remaining requirements before production

- Replace buffered write acknowledgment with Terra's cross-platform sync
  barriers and a tested recoverable manifest/generation publication protocol.
- Make active hot-tier WAL retirement and snapshot cutover explicit and
  recoverable; the candidate API is not a completed automatic rotation system.
- Reduce general unindexed hot-scan materialization and sparse-directory RSS.
- Stress full applications against established implementations with equivalent
  schema, index, durability, hardware and p95/p99 latency settings. The
  improvements above compare JessQL revisions, **not JessQL with SQLite or
  another database**.
- Cross-platform filesystem and failure-injection testing remains required;
  this implementation was exercised with the provided Linux Jess 0.3.0 binary.
