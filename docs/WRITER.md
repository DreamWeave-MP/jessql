# The bounded writer: what it is, what it costs, what is not there (#32)

`@jessql/writer` is the core of a writer actor for a multi-table managed database
(`sql.catalog`). It has no worker in it and starts none: a worker's loop would be receive,
`submit`, `drain`, send. Where this page and the code disagree, the code is right.

## Contract

- A request is plain data: an id and a list of operations (`insert`, `upsert`, `update`,
  `delete`). It is copied and frozen at admission; nothing the caller does to its tables
  afterwards reaches the queue.
- `submit` admits or refuses at once: `queue-full`, `duplicate-id`, `invalid: ...`, `stopped`.
  A refusal is the backpressure; nothing waits inside the writer.
- `drain` commits the oldest requests, each as its own frame, behind **one** synchronization of
  the log, and answers each: `committed`, `rejected` (it changed nothing), or `unknown` (the
  batch failed at or after the append; the writer then stops, and the database must be reopened
  to learn which requests are durable).
- First in, first out. One request's failure does not fail another's.

| Bound | Default | Most |
|---|---|---|
| requests waiting | 1,024 | 65,536 |
| requests behind one synchronization | 64 | 256 |
| operations in one request | 256 | 4,096 |

## Measured

`bench/writer-admission.jsl`, 6,000 requests of one inserted row (256-byte body) and one counter
raised, synchronized durability, on btrfs on one machine, one run, 2026-11-11. Synchronizations
are counted by `@jessql/meter`, not inferred. Latency is from handing a request over to knowing
it is durable. The load is a model: `arrivals` requests are submitted, then the writer drains
once, which is what a worker sees when that many arrive during one synchronization.

| Path | Committed | Refused | Log syncs | Syncs a commit | p50 ms | p99 ms | max ms | Commits/s |
|---|---|---|---|---|---|---|---|---|
| one commit a request | 6,000 | 0 | 6,000 | 1.0000 | 0.77 | 1.37 | 14.2 | 1,236 |
| explicit batches of 16 | 6,000 | 0 | 375 | 0.0625 | 1.37 | 2.03 | 3.1 | 11,410 |
| explicit batches of 64 | 6,000 | 0 | 94 | 0.0157 | 3.21 | 4.80 | 4.8 | 19,365 |
| explicit batches of 256 | 6,000 | 0 | 24 | 0.0040 | 10.61 | 12.88 | 12.9 | 23,744 |
| writer, 1 arrival a sync | 6,000 | 0 | 6,000 | 1.0000 | 0.77 | 1.20 | 58.1 | 1,217 |
| writer, 8 arrivals a sync | 6,000 | 0 | 750 | 0.1250 | 1.07 | 1.54 | 8.9 | 7,119 |
| writer, 64 arrivals a sync | 6,000 | 0 | 94 | 0.0157 | 3.32 | 10.99 | 11.4 | 17,914 |
| writer, 256 arrivals a sync | 6,000 | 0 | 24 | 0.0040 | 10.94 | 15.45 | 15.6 | 21,867 |
| writer, 320 arrivals a sync | 5,616 | 384 | 22 | 0.0039 | 34.44 | 49.40 | 49.6 | 21,990 |

What it shows:

- With one request at a time the writer costs what a plain commit costs (1,217 against 1,236
  commits a second): the queue and the copy are not what is paid for; the synchronization is.
- Under load the writer does what an explicit batch does without the caller forming batches: at
  64 arrivals, 94 synchronizations for 6,000 commits, and about 8% fewer commits a second than
  hand-made batches of 64 (the copy and validation of each request).
- Past what a batch holds (320 arrivals against batches of 256) the queue fills, **384 requests
  are refused with `queue-full`**, and latency is bounded by the queue: p99 49 ms, not
  unbounded. Nothing admitted went unanswered; every run counts its rows afterwards.
- A request waits for its whole batch: p50 grows with the batch. That is the trade.

One run; the max column is the device's outliers. No uncertainty is claimed.

## Not there

- **A worker.** Nothing here runs concurrently; admission while a synchronization is in flight
  is modelled, not measured.
- Death of a worker between the synchronization and its reply: the caller reconciles by id (a
  row keyed by the request's id in the same request makes a retry a duplicate-key rejection).
  A durable idempotency ledger is #33.
- Fairness between clients: the queue is first in, first out across all of them.
- Ownership and capability rules for a database service: #31.
