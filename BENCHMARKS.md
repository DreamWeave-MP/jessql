# jessql benchmarks

`bench/bench.jsl` times the engine through its public API: a table of 100,000 rows (two joined
tables of 50,000, one of 400 for the nested loop and the small aggregate), the same rows behind a
streaming provider that reuses one row, and a provider that is only looked up. Every workload
returns a checksum of its result that is compared with one worked out from the fixture by a plain
loop, before the timing and after it. A workload is warmed up, then timed as the median of seven
batches of about a tenth of a second each, with a full collection between batches.

## Moving onto l3i 2.0: before and after

- Machine: Intel(R) Core(TM) i7-10870H CPU @ 2.20GHz, 15 GB, with other agents' test runs on it.
- Date: 2026-10-12, at the end of the run that began on 2026-10-11.
- Binary: `target/l3i2/jess`, the verified release build of Jess on l3i 2.0.1 (Luau 0.742), for
  both columns: the binary is held fixed, so what Luau 0.742 itself changed cancels out.
- Before: commit `7f81bcf` (the engine as it was), run with this bench file. After: commit
  `dab8670`, the last that changes the engine.
- Protocol: the two trees alternately, before/after/before/after, three runs of each inside one
  lock on the machine's benchmark slot. Each cell is the median of its three runs. A difference
  under about 5 percent is noise here and is given as "no change", and the rows between 1.05x and
  1.15x have moved by several percent from one run of this protocol to the next.

```sh
flock $HOME/.cache/agents-bench.lock systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
  target/l3i2/jess run --package jpk/jessql --package-path jpk jpk/jessql/bench/bench.jsl
```

| Workload | Before | After | |
|---|---:|---:|---|
| order by a number, 100k rows | 249.4 ms | 68.0 ms | 3.7x |
| order by a number descending, 100k rows | 266.1 ms | 61.9 ms | 4.3x |
| order by a number with ties, 100k rows | 269.2 ms | 176.4 ms | 1.5x |
| order by two numbers, 100k rows | 227.2 ms | 57.0 ms | 4.0x |
| order by two numbers that repeat together, 100k rows | 247.7 ms | 173.1 ms | 1.4x |
| order by a nullable number, 100k rows | 254.3 ms | 59.1 ms | 4.3x |
| order by a string, 100k rows | 179.8 ms | 141.1 ms | 1.27x |
| filter then order by a number, 100k rows | 173.9 ms | 44.6 ms | 3.9x |
| top 20 of 100k by a number | 12.2 ms | 10.7 ms | 1.14x |
| top 20 of 100k by two numbers | 36.7 ms | 14.8 ms | 2.5x |
| 50 rows after 5,000 of 100k by a number | 24.9 ms | 23.8 ms | no change |
| filter on two numbers, 100k rows | 23.4 ms | 19.4 ms | 1.21x |
| filter on a nullable number, 100k rows | 9.90 ms | 7.36 ms | 1.34x |
| filter on a string, 100k rows | 11.8 ms | 9.24 ms | 1.27x |
| filter on a LIKE prefix, 100k rows | 12.7 ms | 13.3 ms | no change |
| filter on an expression, 100k rows | 20.8 ms | 18.9 ms | 1.10x |
| project three columns, 100k rows | 46.2 ms | 36.8 ms | 1.26x |
| project three columns, one NULL in every tenth row, 100k rows | 44.7 ms | 43.4 ms | no change |
| count the rows a filter keeps, 100k rows | 11.1 ms | 9.09 ms | 1.22x |
| six aggregates over a filter, 100k rows | 25.8 ms | 14.7 ms | 1.75x |
| four aggregates, 400 rows | 0.072 ms | 0.073 ms | no change |
| two aggregates over a streamed filter, 100k rows | 31.8 ms | 29.9 ms | 1.06x |
| group by two columns, 100k rows | 23.7 ms | 22.3 ms | 1.06x |
| group by one column, 100k rows | 14.6 ms | 14.9 ms | no change |
| group by one column, 100k streamed rows | 32.6 ms | 33.2 ms | no change |
| top 20 of 100k streamed rows by a number | 25.4 ms | 25.0 ms | no change |
| hash join 50k to 50k, filtered, top 10 | 9.33 ms | 7.10 ms | 1.31x |
| hash join 50k to 50k, filtered, every row | 21.6 ms | 19.7 ms | 1.10x |
| left join 50k to 50k, grouped | 17.7 ms | 16.9 ms | no change |
| nested-loop join 400 to 400, counted | 24.8 ms | 25.3 ms | no change |
| indexed join from a streamed driver, 50k rows | 23.8 ms | 22.7 ms | no change |
| prepare a statement of every clause | 0.082 ms | 0.082 ms | no change |
| parse a statement of every clause | 0.040 ms | 0.040 ms | no change |

What moved, and why. The large numbers are ORDER BY without LIMIT: keys that are numbers or NULL
go into one f64 column per key and are ordered by `data.argsort`, a stable pass per key, in place
of `table.sort` calling a Luau comparator about seventeen times a row. That order is used as it
stands only where it is the comparator's own, which is when no two rows have every key equal.
Where some do, `table.sort` still sorts the rows, because the order it leaves equal rows in is
the order callers have always been given and a dependent package's suite pins it; what it calls
is cheaper. For several keys the comparator reads each row's place in the sorted columns, one
number, and answers as the comparator over the keys does for every pair, so the sort makes the
same moves: that is the "two numbers that repeat together" row. For one key a sample of the rows
is looked at first, and when it repeats the column is not sorted at all and the comparator reads
the key from the row's unit: the "with ties" row, and the string row, whose keys no column holds.
What is left of the ordered rows' time is reading 100,000 row tables and building 100,000 result
rows, not sorting. ORDER BY with LIMIT still keeps its rows on the heap it always did, so that
rows with equal keys come back as they always have; several keys got faster because a row's keys
are now read into one scratch table and the row becomes a unit only if it enters the heap.

Filters gained what one function call for `column op literal` saves over three. Aggregates
without GROUP BY read each column once a row into a chunk that a typed `@dream/data` receiver
reduces. That pays when a query has several aggregates (the six-aggregate row), not for one: a
lone SUM over 100,000 rows measured the same either way. Making the chunks costs about what they
save over fifty rows, so a table of fewer than 512 rows is read a row at a time by the code it
always was, and so are the first 128 rows a WHERE keeps of a larger one: before that threshold
was put in, four aggregates over a 16-row table measured 0.82x. A result row starts as a copy of
a row that already has every column, which is all of what the projection row gained. A row with a
NULL cell is built key by key instead, as it always was, because a copy keeps the missing cell's
place and a caller walking the row would meet its cells in a different order; the 64 rows after
one are built that way from the start, which is why the row with NULL cells shows no change. The
dialect's comprehensions, `any`, `all` and `sum` replaced loops throughout and moved nothing that
this bench can see.

The figures in the last paragraph that are not in the table (the lone SUM, the 16-row table) were
taken by the same protocol with workloads that are not part of the committed bench.

What did not pay, measured along the way in two-run comparisons and taken back out: answering a
WHERE of numeric comparisons a column at a time (`data.compare` into selections, intersected,
then `indices`). Rows arrive as Luau tables, one per row, and reaching a row costs about 30 ns of
cache misses however little is read from it, so a pass that only fills columns costs as much as
the predicates it replaces and the rows are then visited again: 1.1x to 2.0x on filters and
counts that keep few rows, 0.83x on the top-20 query, whose filter keeps nearly all of them. The
same holds for ORDER BY with LIMIT through bounded sorted columns, which was 2.3x faster on large
offsets but returned rows with equal keys in a different order from the heap's.

`bench/join.jsl`, `bench/run.jsl` and `bench/topk.jsl` are the older one-shot scripts; they
print their own times and are not part of the table.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.42 and 1.01 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@jessql`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@jessql` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.074 s | 0.052 s |
| Final | 0.070 s | 0.070 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| order by a number, 100k rows | 62.12 | **1.546×** | 63.54 | 1.023× |
| order by a number descending, 100k rows | 56.29 | **1.519×** | 55.82 | 0.992× |
| order by a number with ties, 100k rows | 157.2 | **1.214×** | 157.9 | 1.004× |
| order by two numbers, 100k rows | 50.66 | **1.719×** | 52.12 | 1.029× |
| order by two numbers that repeat together, 100k rows | 155.1 | **1.322×** | 154.9 | 0.999× |
| order by a nullable number, 100k rows | 53.38 | **1.788×** | 54.78 | 1.026× |
| order by a string, 100k rows | 120.8 | **1.574×** | 123.1 | 1.019× |
| filter then order by a number, 100k rows | 43.33 | **1.581×** | 44.16 | 1.019× |
| top 20 of 100k by a number | 9.640 | **2.303×** | 9.651 | 1.001× |
| top 20 of 100k by two numbers | 13.19 | **1.940×** | 13.14 | 0.996× |
| 50 rows after 5,000 of 100k by a number | 21.24 | **2.588×** | 21.35 | 1.005× |
| filter on two numbers, 100k rows | 17.68 | **1.763×** | 17.72 | 1.003× |
| filter on a nullable number, 100k rows | 6.645 | **1.957×** | 6.579 | 0.990× |
| filter on a string, 100k rows | 8.178 | **1.785×** | 8.272 | 1.011× |
| filter on a LIKE prefix, 100k rows | 10.88 | **1.829×** | 10.96 | 1.007× |
| filter on an expression, 100k rows | 17.04 | **2.308×** | 16.44 | 0.965× |
| project three columns, 100k rows | 33.94 | **1.414×** | 34.30 | 1.011× |
| project three columns, one NULL in every tenth row, 100k rows | 43.11 | **1.434×** | 42.80 | 0.993× |
| count the rows a filter keeps, 100k rows | 7.481 | **2.505×** | 7.352 | 0.983× |
| six aggregates over a filter, 100k rows | 12.70 | **2.906×** | 12.77 | 1.006× |
| four aggregates, 400 rows | 0.06297 | **2.782×** | 0.06247 | 0.992× |
| two aggregates over a streamed filter, 100k rows | 35.22 | **1.426×** | 34.86 | 0.990× |
| group by two columns, 100k rows | 19.51 | **2.274×** | 19.33 | 0.991× |
| group by one column, 100k rows | 12.91 | **2.153×** | 12.92 | 1.000× |
| group by one column, 100k streamed rows | 38.40 | **1.424×** | 38.47 | 1.002× |
| top 20 of 100k streamed rows by a number | 31.60 | **1.219×** | 31.73 | 1.004× |
| hash join 50k to 50k, filtered, top 10 | 6.470 | **1.897×** | 6.376 | 0.985× |
| hash join 50k to 50k, filtered, every row | 18.58 | **1.522×** | 18.73 | 1.009× |
| left join 50k to 50k, grouped | 15.16 | **1.916×** | 15.15 | 1.000× |
| nested-loop join 400 to 400, counted | 22.15 | **1.928×** | 22.24 | 1.004× |
| indexed join from a streamed driver, 50k rows | 23.60 | **1.689×** | 23.53 | 0.997× |
| prepare a statement of every clause | 0.07432 | **1.934×** | 0.07271 | 0.978× |
| parse a statement of every clause | 0.03472 | **2.381×** | 0.03556 | 1.024× |

What carries the directive: `engine`, `lexer`, and `parser`, whole; only the 944-byte entry loads
as bytecode.

The engine's hot code is mostly the closures a query is compiled into, one per expression,
filter, and join. Marking only those the rows' profiles named saved 0.010 s a load and left the
queries 1.05x to 1.91x slower than all marked: a nested-loop join of 400 to 400 went from 23 ms
to 43 ms. Whole, every row is within 5% of all marked, at what all marked costs to require; a
database is the queries it runs, so that is the state kept.


## Native persistence prototype (unmerged feature branch)

Tested on the supplied `jess 0.3.0` Linux x64 runtime with `bench/storage.jsl`, a single
process, local filesystem, buffered writes, primary-key hash storage, and secondary equality
index. Numbers vary with hardware, filesystem and cache state; no `fsync` is performed.

| Workload | Measured time |
| --- | ---: |
| 50,000 inserts in 64-row transactions | 0.562 s (~88,972 rows/s) |
| 1,000 indexed equality COUNT queries (50k-row table) | 0.160 s |
| Streaming compact checkpoint, 50k live rows | 0.792 s |
| Reopen and replay compact checkpoint, 50k rows | 0.399 s |

These numbers are **not a claim of durable commits per second**. `@dream/fs` currently lacks a
documented stable-storage barrier, and the 50k rows are entirely resident in memory. The
benchmark is for comparing native JSL engine revisions, not production deployment estimates.

### Native JSL ordered-index ranges (new prototype)

Jess 0.3.0 Linux x64, 30,000 stored records, 500 prepared probes, identical SQL
and data within each comparison. Run with:

```
jess run --trusted --package . bench/ordered.jsl 30000 500
```

One observed run:

```
rows=30000 queries=500 result_rows=10000
hash_baseline_s=2.9937 ordered_s=0.0166 build_s=0.1231 speedup=179.91x
count_hash_s=2.5635 count_ordered_s=0.0018 count_speedup=1433.96x
```

The baseline has only the primary-key hash index and must scan/filter/sort for
range queries; the experimental version adds an in-memory AVL ordered index.
These are *workload-specific algorithmic* improvements, not comparisons with
other DBMSs, full-database throughput figures, or fsync/power-loss measurements.
Build cost is measured separately. More representative write-heavy and mixed
room workloads, disk-backed indexes, and multi-run statistical benchmarks are
still needed before performance claims in production.

Prepared primary-key UPDATE microbenchmark, 5,000 updates per mode in one
transaction, same table and statement (run `jess run --trusted --package .
bench/mutations.jsl 5000`):

```
updates_per_mode=5000 parse_each_s=0.0630 prepared_s=0.0442 speedup=1.43x
```

These are single-run observations, including row copy/index maintenance and
journal commit, not parser-only timings. A larger representative DML suite is
required to assess concurrency and long-term regressions.

## Native two-column scoped ordered indexes (Jess 0.3.0, buffered)

`jess run --trusted --package . bench/composite.jsl 25000 150` compares
standalone `stream_id` AVL + `room_id` hash indexes against the two-column
`room_id, stream_id` composite index on the **same 25,000 persisted rows in 64
rooms**. It uses identical prepared SQL on both sides and checks returned row
counts and count totals for equality.

| Workload (150 repetitions) | Separate ordered/hash indexes | Composite ordered index | Speedup |
|---|---:|---:|---:|
| `room_id = ? AND stream_id > ? ORDER BY stream_id LIMIT 20` | 0.08039 s | 0.00636 s | 12.65× |
| `room_id = ? AND stream_id >= ? AND stream_id < ?` exact count | 0.09327 s | 0.00065 s | 143.34× |
| `room_id = ? AND stream_id = ?` point SELECT | 0.00163 s | 0.00098 s | 1.67× |
| `room_id = ? AND stream_id = ?` exact count | 0.00065 s | 0.00025 s | 2.55× |

Building the composite index took 0.08586 seconds. These are one-run CPU-time
microbenchmarks, not reliable p99 measurements. Rows, indexes, and range
queries execute in memory after buffered log appends; they are **not**
fsync-protected and do not imply disk-B-tree performance.

## Reused ad-hoc SELECT plan cache (Jess 0.3.0, buffered)

`jess run --trusted --package . bench/query-cache.jsl 3000` performs 3,000
identical parameterized primary-key SELECT texts with varied bind parameters
against a 1,000-row persistent table, reopening between runs to compare
`queryCacheEntries = 0` versus 64. Checksums are compared for correctness.

| Cache configuration | 3,000 `db:query` calls |
|---|---:|
| Disabled (`0`) | 0.03745 s |
| LRU (`64`) | 0.00810 s |

This measured run shows **4.63× lower total CPU time** for the specific hot-
query microbenchmark. No disk-sync or network I/O is involved. SQL texts are
identical except for bound parameters; random diverse SQL may show little
benefit and may evict cached plans.

## Resident index RSS and query throughput (native persistence branch)

Benchmark: `jess run --trusted --package . bench/rss.jsl 80000`, Jess 0.3.0
Linux x64, fresh database per process, 256 inserts per transaction, equality
index on a unique code, duplicate-heavy room index, unique numeric ordered
index, room+numeric composite index, 5,000 equality probes and 800 bounded
room-stream range queries. The script asserts query counts/checksums. Exact
baseline tree: `5ada94d229f5e18fabcf0a2f3f0558d97d13108e`; the optimized
source changes only resident index metadata, not WAL contents. Runs alternated
baseline/optimized on the same runtime (3 each for 40k rows, 2 each for 80k).

| Rows | Metric | Baseline median | Compact postings median |
|---:|---|---:|---:|
| 40,000 | OS peak RSS | 161,344 KiB | 110,856 KiB (−31.3%) |
| 40,000 | RSS after building indexes | 143,656 KiB | 94,336 KiB (−34.3%) |
| 40,000 | End-to-end CPU time | 1.495 s | 0.998 s |
| 80,000 | OS peak RSS | 277,480 KiB | 181,178 KiB (−34.7%) |
| 80,000 | RSS after building indexes | 259,888 KiB | 163,204 KiB (−37.2%) |
| 80,000 | End-to-end CPU time | 3.135 s | 2.166 s |
| 80,000 | 5,000 indexed equality reads | 0.0974 s | 0.0832 s |
| 80,000 | 800 bounded composite reads | 0.0958 s | 0.0554 s |

The 40k and 80k runs have identical query checksums before/after. Timings and
RSS are single-host development measurements, not statistically controlled
production benchmarks. RSS includes the Jess binary, allocator arenas, and
heap objects awaiting collection. CPU timings vary materially between runs;
no universal query speedup is claimed. No fsync durability or disk paging is
measured. The independent replay archive includes machine-readable raw runs.

## Experimental packed resident columns + hypervectors (Jess 0.3.0)

Compared the ordinary `row` layout with `rowLayout = 'packed'`, on the exact
same SQL/data/query workload in `bench/packed-rss.jsl`: 80,000 rows, 256 inserts
per transaction, a unique-code equality index, room hash index, numeric AVL
index and room/stream composite index, 5,000 point probes and 800 range
queries. Same query checksum `49295`, same range result count `16000`.
Both modes use **identical buffered WAL semantics** and entirely resident
indexes. Six fresh child processes ran in alternating order, three per mode.
The medians are:

| Measurement | Ordinary rows | Packed columns | Difference |
|---|---:|---:|---:|
| RSS after inserts | 120,900 KiB | 72,660 KiB | **−39.9%** |
| RSS after index builds | 170,876 KiB | 140,000 KiB | **−18.1%** |
| Peak RSS after queries | 184,824 KiB | 149,288 KiB | **−19.2%** |
| Populate + index CPU | 2.328 s | 2.067 s | −11.2% |
| 5,000 point probes CPU | 0.0886 s | 0.0297 s | −66.4% |
| 800 range reads CPU | 0.0621 s | 0.0634 s | +2.0% |
| Total benchmark CPU | 2.399 s | 2.165 s | −9.8% |

Memory ranges were ordinary peak 184,784–189,564 KiB and packed peak
148,764–150,684 KiB. CPU times varied significantly across runs (especially
short queries), so they are **not** throughput guarantees; the exact raw runs
are in the replay archive. RSS includes Jess and the allocator; it does not
measure live Luau heap alone. These are microbenchmarks from one Linux x64 host,
not cross-platform memory results. See `docs/PERSISTENCE.md` for representation
and correctness limits. No fsync, disk-page I/O, compression ratio, or
power-loss behavior is measured.

### Hypervector sandbox

`jess run --trusted --package . bench/hypervectors.jsl` constructs 2,000
256-dimensional randomized binary token signatures (32 raw payload bytes per
signature, excluding Luau `buffer` object overhead). On one development run:

```
dimensions=256 vectors=2000 payload_bytes_per_vector=32 build_s=0.07159
pairs=200 compare_s=0.01243 near_wins=200 near_mean=48.2 unrelated_mean=129.6
```

Near matches share four of five synthetic tags. This demonstrates a similarity
signal for *this generated dataset only*, not recall guarantees, a fast ANN
index, or a lossless encoding of source text. A hypervector would **add**
resident memory if stored alongside exact SQL fields; it is not part of the
RSS optimization. To scale similarity search, we would need an explicit
candidate-retrieval index and evaluate false matches, cost and recall under
realistic distributions.

## Compact native-buffer AVL nodes (Jess 0.3.0)

Compared the unchanged packed-column/reusable-posting baseline
`1674f8c400b5ddb85c858d162ddcf044032a51ce` with AVL nodes stored as
20-byte buffer records. Each of three `packed` runs used a fresh Jess process
in alternating before/after order; two `row` runs per configuration supplement
the comparison. Same 80,000 rows, four indexes, 5,000 equality queries and 800
room-scoped bounded range queries. Both sides returned **checksum 49295** and
**16000 range results** on every run.

| 80K-row metric (median) | Baseline | Compact AVL | Change |
|---|---:|---:|---:|
| Packed peak process RSS | 153,824 KiB | 116,812 KiB | **−24.1%** |
| Packed RSS after indexes | 133,352 KiB | 114,292 KiB | −14.3% |
| Packed total benchmark CPU | 2.259 s | 2.264 s | +0.2% |
| Packed 5K equality queries | 0.0335 s | 0.0394 s | +17.7% |
| Packed 800 composite range queries | 0.0392 s | 0.0326 s | −17.0% |
| Ordinary-row peak RSS (2 runs) | 185,028 KiB | 154,994 KiB | **−16.2%** |
| Ordinary-row total CPU (2 runs) | 2.535 s | 2.563 s | +1.1% |

An isolated 80,000-node AVL benchmark additionally tests 4,000 weighted
range counts, removes half the nodes, inserts replacements and iterates the
entire tree. Its three-run medians were:

| Isolated tree measurement | Previous | Compact | Change |
|---|---:|---:|---:|
| Peak process RSS | 60,596 KiB | 49,292 KiB | −18.7% |
| 4,000 range-count probes | 0.01265 s | 0.00625 s | −50.6% |
| Delete/reinsert plus iteration | 0.15795 s | 0.20244 s | **+28.2%** |

**This is a memory/performance tradeoff.** The isolated mutation-heavy index
microbenchmark got slower. The mixed SQL workload stayed approximately level
in total CPU, but its short-query timings vary widely between runs. Do not
infer production speedups from them. RSS includes Jess VM and allocator
residency; the measured reduction depends on index cardinality and workload.
These are Linux x64 measurements with buffered writes and no fsync, cold-disk
paging, multi-worker contention or power-loss testing. Raw alternating-run
logs are included in the replay archive.

For repeatability:

```bash
jess run --trusted --package . bench/packed-rss.jsl packed 80000
jess run --trusted --package . bench/packed-rss.jsl row 80000
jess run --trusted --package . bench/ordered-slabs.jsl 80000
```

## Ordered scan and packed key-map follow-up (Jess 0.3.0)

The compact-AVL baseline (`58d1e3aaf3be45c8e4d60d5612b0badbe652eaa1`)
was compared against this revision with an unchanged Jess 0.3.0 executable
and identical data, using fresh processes in alternating baseline/revision order.
The internal ordered iterator now yields `(value, encodedKey)` pairs instead of
allocating a `{value, encoded}` table per visited distinct key. The old iterator
remains supported as a wrapper for external callers. AVL rebalancing computes
child heights once per node rather than reading them twice. The packed row
slot map also records deleted-key history using an internal negative sentinel,
removing the separate `seen` hash table without losing insertion-order identity.
Deleted-key history is purged with order compaction and checkpoint cleanup.

| 80,000 packed rows, three alternating runs each (median) | Baseline | Revised |
|---|---:|---:|
| RSS after inserts | 72,420 KiB | 64,204 KiB |
| RSS after building four indexes | 112,968 KiB | 108,140 KiB |
| Peak RSS after queries | 116,976 KiB | 120,128 KiB |
| Total CPU, including inserts/index builds and queries | 2.583 s | 2.046 s |
| 5,000 indexed equality SQL queries | 0.0322 s | 0.0842 s |
| 800 bounded composite range SQL queries | 0.0403 s | 0.0313 s |

**Interpretation:** resident storage after inserts fell 11.3%, and RSS after
index construction fell 4.3%. Peak process RSS **did not consistently improve**;
query-phase allocator and GC behavior produced overlapping ranges. Small CPU
numbers are volatile on this shared host, and the point-query result in this
batch is a regression; earlier alternating trials did not reproduce it. Do not
infer an overall SQL throughput win without a quieter, controlled workload.
All six runs returned checksum 49,295 and 16,000 range rows.

A separate 80,000-key AVL benchmark, with five alternating runs per revision,
reported these medians:

| Isolated benchmark | Before | After |
|---|---:|---:|
| AVL construction | 0.2170 s | 0.1755 s |
| 4,000 range counts | 0.0069 s | 0.0063 s |
| Delete half, reinsert and iterate 80,000 keys | 0.2152 s | 0.1635 s |
| Peak RSS | 47,768 KiB | 48,912 KiB |

The original compact-node deletion slowdown is reduced here, without reverting
to per-node Lua tables. Memory readings for this isolated benchmark are too
close to separate from allocator noise.

To isolate cursor allocation, `bench/ordered-pairs.jsl` walks 40,000 keys eight
times using the allocating compatibility cursor and the new pair cursor.
Five same-process runs reported a median of **0.0861 s vs 0.0442 s**,
respectively, with checksum 6,400,160,000 for both. This measures the iterator
itself, not end-to-end SQL performance.

The new regression tests cover mixed number/string AVL bounds and ascending/
descending parity, packed deleted-key history, reinsertion without duplicate
order slots, index counts, compaction, checkpoint and reopen. Neither the WAL
format nor the buffered-write durability contract changed.

## Experimental hybrid cold pages and hot WAL (Jess 0.3.0, Linux x64)

Reproduce with `jess run --package . --trusted bench/hybrid-compare.jsl prepare 100000`,
then separate processes for `resident 100000` and `hybrid 100000`. Six alternating
measurements (three per configuration), from the same logical data and query
checksum. The resident baseline has an ordered primary-key AVL index.

| 100K-row metric | Resident packed median | Hybrid median |
| --- | ---: | ---: |
| Reopen elapsed CPU | 1.331 s | 0.0124 s |
| RSS just after open | 76,312 KiB | 30,976 KiB |
| RSS after query workload | 76,312 KiB | 42,908 KiB |
| 300 random primary-key reads | 0.00121 s | 0.2517 s |
| Three ordered ranges, LIMIT 20 | 0.000196 s | 0.00981 s |
| Logical COUNT | 100,000 | 100,000 |
| Query checksum | 20,999,420 | 20,999,420 |

Medians from alternating runs; CPU and RSS vary with the host and GC. **Hybrid
is significantly slower for hot queries**, and only its decoded-page cache is
bounded. The massive reopen improvement comes from not reconstructing the full
resident table and index. Buffered I/O, not fsync-backed durability.

## Cold-page key lookup optimization (Jess 0.3.0)

The immutable `JQLP2` provider now coalesces page reads and decodes simple
numeric / unescaped string keys without allocating JSON objects per indexed
row. The file format and CRC checks are unchanged. For 3,000 deterministic
random misses against 30K rows and a four-page cache, median CPU from five
alternating runs improved **2.84x** with numeric keys and **1.75x** with
Matrix-style string keys. All query checksums and page-read counts matched.
See [full benchmark methodology and limitations](docs/COLD-PAGE-LOOKUPS.md).
