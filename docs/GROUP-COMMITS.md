# Synchronized transaction batching (experimental)

JessQL exposes `transactionBatch` on the native WAL store (`sql.open`), hybrid table
(`sql.hybrid.open`), and managed table (`sql.managed.open`). This **is not** a worker
or concurrent admission service. It executes 1–256 callbacks, in order, within one
exclusive owning VM. Every successful callback with mutations produces its **own
sequenced, CRC-framed WAL record**, in the existing `JQLW1` format. After all
callbacks finish, a **single `syncData()`** publishes the whole successful suffix
before any results return. A read-only successful callback does not write a frame.

Use this when a caller already has several independent committed requests ready to
submit; unlike one `db:transaction()` containing many row mutations, failures of
one callback do not cancel prior or later successful transactions.

```luau
local results = db:transactionBatch({
  function(tx) tx:insert({ id = 101, body = 'one' }) end,
  function(tx) tx:insert({ id = 102, body = 'two' }) end,
})
for index, result in results do
  if result.ok then
    print('durable request', index)
  else
    print('rejected before commit', index, result.error)
  end
end
```

When using a raw `sql.open()` store, use `tx:insert('tableName', row)` instead.
The batch API is available **only with `durability = 'sync'`**; managed databases
always use synchronized WAL writes. The hybrid wrapper requires an underlying
synchronized WAL. `BatchResult` includes `{ ok: boolean, error: string? }`.

## Correctness and failure boundaries

- Each callback sees successful preceding callbacks in its own transaction view.
  Its staged mutations are private until that callback completes. It may use
  `tx:get`, `tx:query`, and mutation methods. **Do not access the outer database
  handle inside a batch callback:** the raw, hybrid, and managed wrappers deny
  reentrant reads and managed generation transitions or close operations until
  the synchronization barrier has completed.
- A callback exception or aborted SQL DML rejects **only that callback**. Its
  staging is discarded, no frame is appended for it, and the batch continues.
  Each later callback can still commit. This is **not** an all-or-nothing batch.
- No successful result is returned before `syncData()` succeeds. A failed append,
  failed synchronization, or unexpected post-append error poisons the handle.
  `transactionBatch` throws rather than returning a partial success list, and
  the caller must **close and reopen** to discover which frames recovered.
  Transactions might have become durable even when no acknowledgment was
  returned; blind retry risks duplicate effects. Use idempotency keys or query
  the recovered state before deciding to retry.
- The existing WAL parser can replay a prefix of valid frames and repair a torn
  trailing record under its configured recovery policy. Complete CRC errors
  and invalid sequences continue to fail closed. Neither a process-kill test
  nor an injected exception proves protection from physical power-loss.
- Managed auto-maintenance executes **after** the entire successful batch is
  synchronized. If maintenance fails, already-acknowledged transactions remain
  committed and byte-watermark backpressure applies just as for single commits.
- A batch is bounded to **256 callbacks**; it is not a 256-entry concurrent
  queue, a byte limit on per-request allocations, or a general RSS cap.
  There is no automatic latency-based batching, worker scheduling, or p99 SLA.

For deterministic fault testing, raw `sql.open` accepts `batchTestHook(stage)`.
The recognized stages are `after-append`, `before-sync`, and `after-sync`.
A thrown hook forces the same fail-closed, reopen-required path as an uncertain
write. Never configure that hook in production.

## Benchmarks

`bench/group-commit.jsl` produces identical `JQLW1` WAL sizes for `solo` and
`batch` modes and validates the row count both before and after reopening.
Run with the supplied Jess runtime:

```bash
jess run --trusted --package . bench/group-commit.jsl solo 960 32
jess run --trusted --package . bench/group-commit.jsl batch 960 32
```

Seven alternating Linux x64 runs with **960 distinct transactions**, each
inserting one row, yielded **262.527 ms median `os.clock()`** for sequential
`transaction()` and **28.304 ms** for `transactionBatch` with groups of 32,
approximately **9.3x lower measured CPU time**. End-to-end process wall time
(median, including startup) was **0.42 s** versus **0.18 s**. Both wrote exactly
**186,158 bytes** of WAL. Additional 3-run batch-size sweeps were about
257.7, 56.4, 33.4, 20.8, 18.2 ms median CPU for group sizes 1, 8, 32, 128,
256 respectively. Raw CSVs ship in the replay archive's `validation/` folder.

These timings are workload- and hardware-specific, not request latency percentiles,
concurrent throughput, cross-platform verification, or a comparison with SQLite,
PostgreSQL, or RocksDB. The larger sizes optimize total synchronization overhead
at the expense of a potentially larger single-batch acknowledgment delay.

## Next integration step

A dedicated Jess single-writer actor can accept bounded messages from multiple
callers and collect them until a size/deadline threshold. That requires a proper
response channel, per-request idempotency and cancellation states, worker-failure
handling, and measured end-to-end queuing latency. Do not mistake this explicit
synchronous API for that service.
