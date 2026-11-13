# Reading a result a row or a page at a time

`plan.run(params)` computes a whole result. `plan.open(params)` returns a cursor over the same
result:

```luau
local cursor = db:prepare('SELECT id, body FROM events WHERE room = ?').open({ 'north' })
while true do
  local page = cursor.page(500)     -- or cursor.next() for one row
  if #page == 0 then break end
  send(page)
end
-- or, to stop early:
cursor.close()
```

| | |
|---|---|
| `columns` | the result columns, in SELECT order |
| `next()` | the next row, or nil at the end |
| `page(n)` | up to `n` rows; fewer at the end; an empty list after it |
| `done()` | whether the cursor is finished: read to the end, closed, or failed |
| `close()` | stops the query where it is; harmless to repeat |
| `streaming()` | whether rows are produced as they are asked for |

## When it streams

A cursor streams when nothing is left to do but filter and project: one source, no aggregate, no
grouping, and no sort the source has not already done. Then each row is built when it is asked
for, and the source is asked for no more once the consumer closes the cursor or the LIMIT is met.

For every other query (a sort, a GROUP BY, an aggregate, a join) the result is computed when the
first row is asked for and handed out in pieces. The rows and their order are the same as
`run`'s either way; `streaming()` says which happened, so nothing has to be guessed. `LIMIT 0`
never reaches a source and reports not streaming.

## What it promises

- **Same answer:** the rows of `run`, in the same order.
- **Early stop:** closing a streaming cursor, or meeting its LIMIT, stops the source. With a
  source of 100,000 rows, three reads and a close ask the source for at most four.
- **Errors surface where they happen:** what the source raises is raised by the read that met
  it; the cursor is then finished.
- **A write while paused is an error, not a mixture:** over a hybrid database, reading on after
  the database was written raises (the store invalidates its cursor) rather than return rows of
  two states. Open a new cursor.
- **Parameters are checked at `open`.**

## Memory

Heap growth sampled after every page of 500 rows (`gcinfo()`, three runs):

| Read | Rows | Heap growth |
|---|---|---|
| through a cursor | 90,000 | at most 2.8 MB |
| through a cursor | 1,080,000 | at most 1.9 MB |
| `run` | 180,000 | about 86 MB |

Flat across twelve times the rows. This is allocation observed through `gcinfo()` in one VM, not
resident set size, and the source is one that generates rows on demand. Measured after an eager
query in the same VM the cursor's figures are several times higher, because a heap that has been
large is collected less eagerly; the test measures the cursor first for that reason.

## Not done

- Backpressure is the consumer simply not asking; there is no bounded output framing for a
  service transport, and no worker.
- Sorts, groups and joins are not streamed and no tempfile is involved; their memory is `run`'s.
- A source has no `close` of its own (the provider interface is v1), so "releasing" a source
  means no longer calling it. The paged cold reader holds no pin between calls.
- Worker-death simulation.
