# jessql benchmarks

`bench/bench.luau` times the engine through its public API: a table of 100,000 rows (two joined
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
  target/l3i2/jess run --package jpk/jessql --package-path jpk jpk/jessql/bench/bench.luau
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

`bench/join.luau`, `bench/run.luau` and `bench/topk.luau` are the older one-shot scripts; they
print their own times and are not part of the table.
