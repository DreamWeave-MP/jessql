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

## In a worker, under real concurrency

`bench/writer-worker` is a small application package (a worker needs a script domain, which
`jess run` and a package's tests do not have). The database and the writer live in a worker;
the application sends requests by the clock at a set rate, whatever the worker is doing, and
keeps one `flush` outstanding at a time. The protocol is four messages: `open`, `submit` (which
answers only a refusal), `flush` (which drains once and answers every outcome) and `close`.

20,000 requests at each rate, 256-byte body, btrfs, one machine, one run, 2026-11-11:

| Arrivals/s | Committed | Refused | Log syncs | Syncs a commit | p50 ms | p99 ms | max ms | Commits/s |
|---|---|---|---|---|---|---|---|---|
| 500 | 20,000 | 0 | 19,830 | 0.9915 | 0.90 | 3.28 | 22.4 | 500 |
| 2,000 | 20,000 | 0 | 10,468 | 0.5234 | 0.92 | 9.22 | 39.7 | 2,000 |
| 8,000 | 20,000 | 0 | 1,301 | 0.0650 | 1.87 | 17.58 | 22.4 | 7,979 |
| 32,000 | 12,592 | 7,408 | 53 | 0.0042 | 35.00 | 43.49 | 44.9 | 19,329 |

- **Coalescing is real and nobody asks for it**: what arrives while the log is being
  synchronized is committed behind the next synchronization. At 8,000 arrivals a second that is
  15 requests a synchronization; p50 stays under 2 ms.
- **Past what the disk takes** (about 19,000 commits a second here) the sender's bound refuses
  the rest at once and latency stays bounded by that bound: p99 43 ms. The worker's mailbox
  holds 1,024 messages and raises on one more, so the application bounds what is unanswered at
  768 and refuses beyond it; the writer's own `queue-full` is never reached in this arrangement.
- **p99 at light load is worse than a plain commit's** (3.3 ms against 1.4 ms): a request waits
  for the application's next look at the worker, up to a millisecond, and for a flush already
  in flight.

**A worker that dies.** In a last run the worker is made to fail under load at 8,000 arrivals a
second. The application then opens the database itself: 6,673 requests had been acknowledged
as committed and **all 6,673 were present**, none missing. No row was present that had not been
acknowledged, in this run: the death here falls just after an acknowledgement, which is the
easy moment. A death between the synchronization and the reply is not forced by that tool; it
is forced in `tests/writer-service.jsl` through a stand-in worker (six requests synchronized,
the worker gone before its reply): the client reports all six `unknown`, a new worker is opened
over the same database, all six are sent again blind with the ledger on, and each is refused
as already committed. Seven rows for thirteen requests sent.

## Several tenants, one writer: `@jessql/writer_fair`

A client admits until `maxOutstanding` are unanswered and then refuses everyone alike, so the
caller that submits fastest holds the whole queue. `fair.new({ submit, poll, capacity })` sits
in front of a client or a supervisor and shares the queue out between named tenants:

- a tenant alone may use all of `capacity`: nothing is held back for tenants who are absent;
- among the tenants that hold requests or were refused for want of room, each has a share,
  `capacity` divided by their number; one at its share is refused with `fair-share`;
- a tenant under its share that finds no room is refused with `backpressure` and counted as
  waiting for `waitSeconds` (default 5): the tenants over their share are then refused and the
  next places freed are left for it. One that does not come back is forgotten.

Nothing waits or is queued inside it; a refusal is the caller's to retry. In
`tests/writer-fair.jsl`, on a virtual clock with a stand-in writer that frees two places a
round: two tenants asking ten times a round and one asking once, 600 rounds, queue of 12. The
slow tenant is admitted at least 350 times and never waits more than 6 rounds; the same
writer with no front admits it **0** times. What is not there: weights or priorities (every
tenant's share is equal), fairness by bytes or by time in the writer rather than by requests,
and any measurement against a real worker.

## As a library: `@jessql/writer_service`

The protocol and both of its ends, without the spawning: `service.host()` is the worker's
message handler, `service.source` is what an application gives `jess.worker.spawn`, and
`service.client(lane, options)` talks to a worker's handle, or to anything with `send` and
`receive`, which is how it is tested without a script domain.

- `submit` answers at once: admitted to the wire, or refused with `backpressure` (more than
  `maxOutstanding` unanswered, default 768, at most 960, under the mailbox's 1,024),
  `duplicate-id`, `closed`, `stopped` or `transport`.
- `poll(seconds)` keeps one flush outstanding and returns every outcome learnt: `committed`,
  `rejected` (a refusal by the writer arrives as this, with its reason) or `unknown`.
- A worker that fails, or a flush unanswered for `flushTimeoutSeconds` (default 30), **stops the
  client**: every unanswered request is `unknown`, exactly once, and nothing more is admitted.
  The client never calls such a request rejected: it may be in the worker's mailbox and commit
  later, and a test shows exactly that.
- `close(seconds)` flushes, closes the database in the worker and returns the last outcomes;
  what a worker never answered for is `unknown`.
- The host answers every malformed or untimely message and never raises for one. A failed
  `open` leaves no database open behind it (a test found that it did, and it was fixed).

On a real worker (`bench/writer-worker`, three runs of 20,000 requests a rate, btrfs): the
library client commits as fast as the hand-written protocol at 8,000 and 32,000 arrivals a
second (7,992 and 19,438 commits a second in the first run; p99 17.5 and 40.5 ms). **At 2,000
arrivals a second its p99 was 271, 75 and 18 ms across the three runs** against 13 to 15 ms for
the hand-written protocol, with the same median (1.1 ms). Each library run follows the heaviest
run of the other protocol on the same disk, which may be all there is to it; it is not
explained, and it is recorded.

## What became of an `unknown` request: `@jessql/ledger` (#33)

Give the writer `ledger = { table = 'requests', scope = 'tenant-a' }` and put
`ledger.table('requests')` among the database's tables. Each request's id is then written as a
row **in the request's own frame**, so the id is in the database exactly when the request's
changes are, whatever moment a crash chooses, and there is no second store to disagree with.

- A request whose id is already there is `rejected` with `ledger: already committed`
  (`ledger.wasCommitted(ack.error)`) and changes nothing. That is the answer to a retry.
- `ledger.lookup(db, options, ids)` answers `committed` or `absent` for each id, from the
  database as it is: what a caller or an operator asks after a reopen.
- The scope is part of the key, length-framed: the same id under two scopes is two requests.
- `ledger.prune(db, options, before, limit)` removes entries older than a time, a bounded number
  a call. **After an id is pruned a retry of that request is applied again**: retries must stop
  before retention does. Nothing prunes by itself.

Tested: a duplicate in the same batch and in a later one; a request that failed leaves no id
and can be sent again; after an injected failure of the log's synchronization and a crash, each
id is present exactly when its effect is, and a blind retry of all three applies each once; two
scopes with the same id; pruning ten at a time.

This is exactly-once **application** of a request to one database. It is not exactly-once
delivery, and it does not span databases.

## A worker that is replaced: `service.supervisor`

`service.supervisor(spawn, { path, tables, writer = { ledger = ... } })` is a client that
replaces its worker. `spawn` starts a worker and answers its handle; it is called again each
time the worker fails or goes silent, up to `maxRestarts` (default 3). Every request still
unanswered is then sent to the new worker as it was. One that had in fact committed is refused
there by the ledger and reported to the caller as what it is, `committed`; one that had not,
commits. The caller sees `unknown` only when the restarts are used up or no worker can be
started or opened.

It **requires a ledger** and will not be made without one: retrying a request whose outcome is
unknown is only safe when a committed request cannot be applied twice. A refusal that is not a
retry stays a refusal: an id the caller itself sends twice is `rejected`, as is a row that is
really already there.

Tested through stand-in workers: five requests synchronized and the worker dead before its
reply (reported `committed` after one restart, applied once); three requests in the mailbox of
a worker that dies (they commit in the next); workers that die every time (`unknown` after two
restarts, and the test shows they had in fact committed: unknown is honest); no ledger, no
supervisor; a worker that cannot be started.

## Not there

- The supervisor holds a copy of every unanswered request, at most `maxOutstanding` of them.
  Over real workers it has been run once (`bench/writer-worker`, btrfs): 6,000 requests at
  8,000 a second, the worker killed after 2,000 commits; one restart, 4,666 reported committed
  and exactly 4,666 rows and ledger entries on reopen, 1,334 refused at once while the new
  worker opened, none unknown.
- Between one replacement and the next the supervisor waits (`restartBackoffSeconds`, default
  1, doubling up to 30); the first replacement is immediate. While it waits nothing is admitted
  (`backpressure`) and the unanswered requests stay held. Tested on an injected clock only.
- A ledger entry does not record the request's content: a different request reusing an id is
  refused as already committed, not detected as a conflict.
- **Fairness** between several clients: one client owns one worker, first in, first out.
- The spawning itself is the application's: a worker needs a script domain.
- Death of a worker between the synchronization and its reply: the caller reconciles by id (a
  row keyed by the request's id in the same request makes a retry a duplicate-key rejection).
  A durable idempotency ledger is #33.
- Fairness between clients: the queue is first in, first out across all of them.
- Ownership and capability rules for a database service: #31.
