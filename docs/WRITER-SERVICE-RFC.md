# RFC: the single-owner database service, protocol version 1 (#31)

Status: **draft for review**. Sections marked *built* describe code in this repository with
tests named beside them. Sections marked *proposed* describe nothing that exists. Where this
page and the code disagree, the code is right and this page is wrong.

## What it is

One worker owns one managed database: its write-ahead log, its manifest, its lock. Everything
else in the application reaches that database by sending the worker messages. Nothing but the
owner writes a file of it. The pieces: `@jessql/writer` (admit, drain, acknowledge),
`@jessql/writer_service` (the protocol and both ends of it, and a supervisor that replaces a
dead worker), `@jessql/ledger` (a record of which requests committed, kept in the same
transaction as their effects), `@jessql/writer_fair` (shares between tenants).

## Who is trusted with what

| Party | Trusted to | Not trusted to |
|---|---|---|
| The owner (the worker) | hold the lock; decide what is durable; answer truthfully | stay alive, or answer in time |
| A client in the same application | send well-formed or malformed messages at any rate | choose a path (when the host is confined); be believed about an outcome; stop sending |
| Whoever can write the database's directory | everything | nothing here defends against them: offline verification (`OFFLINE-VERIFICATION-AND-BACKUP.md`) detects, it does not prevent |

There is **no authentication**. A lane is a worker's handle inside one process; whoever holds
the handle is the client. Principals and scoped grants are *proposed*, below. A network
listener in front of this protocol would need its own authentication and is not part of it.

## Threats, and what answers each

| Threat | Answer | Built? | Shown by |
|---|---|---|---|
| A client names a file outside the service's directory (`../`, an absolute path, a separator, a NUL) | A host with a `root` takes a *name*: `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`. Anything else is `failed: not a database name` and nothing is created | built | `tests/writer-confinement.jsl` (21 attempts) |
| A host with no `root` | Opens any path it is sent. That is the unconfined mode tests and single-purpose tools use; **an application with more than one author of messages should set a root** | built, as a documented hazard | the same file |
| A timeout reported as a rollback after the log was synchronized | A worker that fails, or a flush unanswered past `flushTimeoutSeconds`, yields `unknown` for every unanswered request, once. `rejected` is only ever something the owner said | built | `tests/writer-service.jsl` (a worker that dies after its work was done) |
| A request committed twice because its answer was lost | The ledger: a request id recorded in the transaction that applies it; a retry of a committed id is refused, having changed nothing, and the record says what became of a request nobody saw answered. **Entries are pruned**: after that a retry of the same id is applied again, so the guard holds for as long as the ledger is kept and no longer | built | `tests/ledger.jsl` |
| A flood filling the owner's mailbox (1,024 messages; one more raises) | The client refuses with `backpressure` past `maxOutstanding` (768 by default, 960 at most) and never waits | built | `tests/writer-service.jsl` |
| One tenant holding the whole queue | `@jessql/writer_fair`: equal shares among tenants holding or waiting | built | `tests/writer-fair.jsl` |
| A worker that dies again and again | The supervisor replaces it, the first time at once and then after a doubling wait up to 30 s, admitting nothing while it waits | built | `tests/writer-service.jsl` (the supervisor cases) |
| A query that holds unbounded memory in the owner | Per-operator budgets through `queryLimits` | built for reads through a catalog; **not** carried in this protocol | `tests/operator-budgets.jsl` |
| A message of another protocol version | `open` carries `version`; a host refuses any but its own with `failed: unsupported protocol version`, before it opens anything | built | `tests/writer-confinement.jsl` |
| A malformed message | The host answers `failed` or `refused` and never raises for a message it does not understand | built | `tests/writer-service.jsl` |

## The messages (*built*)

All plain data. `version` is 1.

| From the client | Answer |
|---|---|
| `open { version?, path, tables, options? }` | `opened { version }` or `failed { reason }`. Under a confined host `path` is a name |
| `submit { request = { id, operations } }` | nothing when admitted; `refused { id, reason }` otherwise |
| `flush { serial }` | `acks { serial, acks = [{ id, outcome, error? }], queued }` |
| `close {}` | `closed { acks, status }` |

An `open` with no `version` is taken as version 1: that is what clients sent before the field
existed. Any other value, of any type, is refused.

## The four outcomes

The issue asks for committed, aborted, rejected and outcome-unknown. Three exist:

| Outcome | Means | Who may say it |
|---|---|---|
| `committed` | the request's transaction is in the log and the log was synchronized | only the owner |
| `rejected` | the request changed nothing: refused at admission, or its transaction raised and was rolled back whole | the owner; or the client, for a request it never sent (`backpressure`, `duplicate-id`, `closed`, `stopped`, `transport`) |
| `unknown` | the request may or may not be durable | the owner, when a synchronization failed; the client, when the owner died or went silent |

There is no separate `aborted`: a transaction that raised is `rejected` with the error as its
reason, because for the caller the two are the same fact (nothing changed) and a fourth word
would invite code that treats them differently. If review wants the distinction (refused
before running against rolled back after running), it is a field on `rejected`, not a state.

**The rule that must hold in every version:** nothing is `committed` that the owner did not
say was synchronized, and nothing is `rejected` that might be durable. A caller who gets
`unknown` finds out by reopening the database or by retrying with the same id against the
ledger.

## Proposed, not built

Each of these is named in the issue and absent from the code. None should be read as planned
for a date.

- **Sessions and principals.** An opaque session opened under a principal, with grants scoped
  to tables and operations, checked by the owner on every request. Today every holder of the
  lane may do everything.
- **Deadlines.** A request carrying the latest time it may start. Today a request admitted is
  run whenever its turn comes.
- **Cancellation.** A `cancel { id }` honoured only before the request's batch begins; after
  that the answer is the batch's. Today nothing can be withdrawn.
- **Bound parameters and reads.** The protocol carries writes as operations. Queries, with
  bound parameters and `queryLimits`, are not in it: reads go through a catalog opened by the
  reader.
- **Isolation and durability requests.** Every request is one transaction, synchronized
  before it is acknowledged. A request cannot ask for less (or for a snapshot to read at).
- **Version negotiation.** A host speaks one version. A range, and a client that picks, wait
  for a second version to exist.

## Compatibility

A client from before the `version` field works against this host. A client from this build
sends `version = 1`, which a host from before the field ignores. The `opened` reply gained a
`version` field that older clients do not read.
