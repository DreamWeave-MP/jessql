# The benchmark laboratory

`@jessql/benchlab` is the part of a benchmark that should not be rewritten for each one:
datasets that can be named, key distributions with a known shape, and a harness that will not
report a number for a wrong answer. It knows nothing about a database; `bench/lab.jsl` is one
use of it.

## Datasets

`lab.dataset(spec)` gives rows `id` (1 to `rows`), `category` (one of `categories` values),
`body` (between `minBodyBytes` and `maxBodyBytes`), and for one row in `blobEvery` a `blob` of
`blobBytes`. A dataset depends only on its specification. `fingerprint()` is a SHA-256 over every
row in order: two runs with the same fingerprint measured the same data, and `lab.comparable`
refuses to compare two reports whose fingerprints differ, or that have none.

`lab.sampler('uniform' | 'zipf', keys, seed, skew?)` draws keys. Zipf gives key k the weight
1 / k^skew: with skew 1 over 1000 keys, the first key takes about 13% of draws and the first ten
about 39% (checked by the tests).

## The harness

`lab.run({ workloads, trials, operations, clock, environment, fingerprint })`:

- **Phases apart.** Each workload's `setup` and `load` are timed on their own, before any trial.
  `between` runs after each trial and `teardown` at the end, outside every timed region.
- **An oracle, or no number.** A workload gives `operation(index)`, which answers a number, and
  `expected(operations)`, the sum those answers must reach, worked out without the system under
  test. Every workload is run once untimed first: a wrong answer stops the run before anything
  is measured. A wrong answer in a timed trial stops it too. Nothing is reported for a wrong
  result.
- **Rotating order.** Each round starts one workload later than the last, so none always runs
  first or last.
- **Every raw trial is kept**, with seconds, operations, and the 50th, 95th, 99th and 99.9th
  percentile and the slowest single operation, by nearest rank (a value that was measured).
  `lab.csv(report)` writes them.
- **The clock is given, and so is the environment.** The harness does not guess a version, a
  machine or a durability setting; what it is told is recorded with the report. `os.clock` is
  processor time, not wall time, and a report should say which it used.

## One run (`bench/lab.jsl`, a managed database on the in-memory disk)

2026-11-10, one run, x86_64, 16 cores; 20,000 rows of 256 to 1024 body bytes
(fingerprint `6b3eab58...`), three trials, `os.clock`. Medians of three:

| Workload | Operations | Per second | p50 | p99 | p99.9 |
|---|---|---|---|---|---|
| point read, uniform keys | 20,000 | 15,074 | 59 us | 246 us | 416 us |
| point read, Zipf 1.1 keys | 20,000 | 21,077 | 51 us | 168 us | 393 us |
| upsert (synchronized commit each) | 20,000 | 2,809 | 306 us | 1,397 us | 1,824 us |
| filtered `COUNT(*)` over all rows | 20 | 2.7 | 367 ms | 371 ms | 371 ms |

Load (insert, a flush every 2,000 rows, compactions to stay under the generation budget) took
4.9 s and wrote 10.1 bytes to storage per user byte.

What these are: the engine on a disk that is a table in memory, timed in processor seconds, on
one machine, once. They show the laboratory working and give an order of magnitude. They are not
a comparison with anything.

## Not done

- A comparator: no other engine is run. The harness can time one; none is wired up.
- 100K, 1M and 10M rows; a real filesystem; cold-cache control; wall time; RSS and allocations.
- Pinning of Jess, l3i, CPU topology, OS and filesystem beyond what the caller writes into
  `environment`.
- JSON output; only CSV.
