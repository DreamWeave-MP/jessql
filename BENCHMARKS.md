# jessql benchmarks

`bench/bench.luau` times the engine through its public API: a table of 100,000 rows (two joined
tables of 50,000, one of 400 for the nested loop), the same rows behind a streaming provider that
reuses one row, and a provider that is only looked up. Every workload returns a checksum of its
result that is compared with one worked out from the fixture by a plain loop, before the timing
and after it. A workload is warmed up, then timed as the median of seven batches of about a tenth
of a second each, with a full collection between batches.

## Moving onto l3i 2.0: before and after

- Machine: Intel(R) Core(TM) i7-10870H CPU @ 2.20GHz, 15 GB, with other agents' test runs on it.
- Date: 2026-10-12, at the end of the run that began on 2026-10-11.
- Binary: `target/l3i2/jess`, the verified release build of Jess on l3i 2.0.0 (Luau 0.742), for
  both columns: the binary is held fixed, so what Luau 0.742 itself changed cancels out.
- Before: commit `7f81bcf` (the engine as it was, with this bench). After: commit `eefdc49`.
- Protocol: the two trees alternately, before/after/before/after, three runs of each inside one
  lock on the machine's benchmark slot. Each cell is the median of its three runs. A difference
  under about 5 percent is noise here and is given as "no change".

```sh
flock $HOME/.cache/agents-bench.lock systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
  target/l3i2/jess run --package jpk/jessql --package-path jpk jpk/jessql/bench/bench.luau
```

| Workload | Before | After | |
|---|---:|---:|---|
| order by a number, 100k rows | 246.2 ms | 67.0 ms | 3.7x |
| order by a number descending, 100k rows | 239.4 ms | 59.9 ms | 4.0x |
| order by a number with ties, 100k rows | 265.9 ms | 169.6 ms | 1.6x |
| order by two numbers, 100k rows | 222.4 ms | 56.6 ms | 3.9x |
| order by a nullable number, 100k rows | 255.4 ms | 58.5 ms | 4.4x |
| order by a string, 100k rows | 176.1 ms | 136.3 ms | 1.3x |
| filter then order by a number, 100k rows | 171.1 ms | 43.2 ms | 4.0x |
| top 20 of 100k by a number | 11.8 ms | 10.5 ms | 1.13x |
| top 20 of 100k by two numbers | 34.4 ms | 14.3 ms | 2.4x |
| 50 rows after 5,000 of 100k by a number | 24.8 ms | 23.3 ms | 1.06x |
| filter on two numbers, 100k rows | 22.2 ms | 19.0 ms | 1.17x |
| filter on a nullable number, 100k rows | 8.99 ms | 7.25 ms | 1.24x |
| filter on a string, 100k rows | 10.8 ms | 8.78 ms | 1.23x |
| filter on a LIKE prefix, 100k rows | 12.3 ms | 12.4 ms | no change |
| filter on an expression, 100k rows | 19.6 ms | 18.3 ms | 1.08x |
| project three columns, 100k rows | 46.0 ms | 35.4 ms | 1.30x |
| count the rows a filter keeps, 100k rows | 10.7 ms | 8.13 ms | 1.31x |
| six aggregates over a filter, 100k rows | 24.5 ms | 13.9 ms | 1.8x |
| two aggregates over a streamed filter, 100k rows | 31.7 ms | 27.6 ms | 1.15x |
| group by two columns, 100k rows | 24.2 ms | 20.5 ms | 1.18x |
| group by one column, 100k rows | 14.2 ms | 14.3 ms | no change |
| group by one column, 100k streamed rows | 33.1 ms | 31.5 ms | no change |
| top 20 of 100k streamed rows by a number | 25.3 ms | 23.5 ms | 1.07x |
| hash join 50k to 50k, filtered, top 10 | 8.97 ms | 6.82 ms | 1.32x |
| hash join 50k to 50k, filtered, every row | 21.0 ms | 19.3 ms | 1.09x |
| left join 50k to 50k, grouped | 17.5 ms | 16.0 ms | 1.09x |
| nested-loop join 400 to 400, counted | 23.8 ms | 24.1 ms | no change |
| indexed join from a streamed driver, 50k rows | 22.8 ms | 22.9 ms | no change |
| prepare a statement of every clause | 0.079 ms | 0.080 ms | no change |
| parse a statement of every clause | 0.039 ms | 0.039 ms | no change |

What moved, and why. The large numbers are ORDER BY without LIMIT: keys that are numbers or NULL
go into one f64 column per key and are ordered by `data.argsort`, a stable pass per key, in place
of `table.sort` calling a Luau comparator about seventeen times a row. That is used only where it
gives the comparator's own order, which is when no two rows have every key equal; the bench's
"with ties" row and its string row are still sorted by the comparator, and are faster only
because a single key now sits on its unit instead of in a table of keys. What is left of the
ordered rows' time is reading 100,000 row tables and building 100,000 result rows, not sorting.
ORDER BY with LIMIT still keeps its rows on the heap it always did, so that rows with equal keys
come back as they always have; several keys got faster because a row's keys are now read into one
scratch table and the row becomes a unit only if it enters the heap. Filters gained what one
function call for `column op literal` saves over three; aggregates without GROUP BY read each
column once a row into a chunk that a typed `@dream/data` receiver reduces; and a result row
starts as a copy of a row that already has every column, which is all of what the projection row
gained. The dialect's comprehensions, `any`, `all` and `sum` replaced loops throughout and moved
nothing that this bench can see.

What did not pay, measured and taken back out: answering a WHERE of numeric comparisons a column
at a time (`data.compare` into selections, intersected, then `indices`). Rows arrive as Luau
tables, one per row, and reaching a row costs about 30 ns of cache misses however little is read
from it, so a pass that only fills columns costs as much as the predicates it replaces and the
rows are then visited again: 1.1x to 2.0x on filters and counts that keep few rows, 0.83x on the
top-20 query, whose filter keeps nearly all of them, in two-run comparisons made along the way. The same holds for ORDER BY with LIMIT through
bounded sorted columns, which was 2.3x faster on large offsets but returned rows with equal keys
in a different order from the heap's, which a dependent package's suite pins.

`bench/join.luau`, `bench/run.luau` and `bench/topk.luau` are the older one-shot scripts; they
print their own times and are not part of the table.
