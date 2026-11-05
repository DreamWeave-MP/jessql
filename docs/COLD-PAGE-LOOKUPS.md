# Cold-page lookup hot path (experimental)

JessQL's immutable `JQLP2` page snapshots retain their original on-disk format,
footer identity, checksums, sparse directory and bounded page cache. This
revision targets *miss handling* in `src/paged.jsl`, not disk durability or SQL
semantics. Existing snapshot files remain readable without migration.

## Changes

1. Decode little-endian record lengths using four `string.byte` values instead
   of allocating a temporary `buffer.fromstring` for each 32-bit field.
2. Fetch the page header and body with one positional read, then validate the
   same length and CRC32 against the sparse directory before inspecting rows.
3. Keep cached keys, row offsets and row lengths in three arrays instead of a
   Luau dictionary for each page entry.
4. For numeric and string-only snapshots, validate the narrow JSON key form
   (`{"key":number}` or a plain, unescaped `{"key":"..."}`) directly. Malformed,
   escaped, and mixed-type keys still use the full JSON parser. Non-finite and
   invalid UTF-8 keys are rejected as before. Row bodies always use JSON decode
   and must match the verified key.

Checksums detect accidental corruption, not hostile tampering or power loss;
this change makes no new durability/security claims.

## Benchmark

`bench/cold-lookup.jsl` constructs 30,000-record page snapshots with 32 KiB
pages, then runs 3,000 deterministic, effectively cold primary-key lookups
with a four-page cache. The exact same generated snapshot files were queried
by the old provider and this revision in alternating *separate Jess processes*.
The benchmark ran on the supplied Jess 0.3.0 Linux x64 binary. All checksums
matched (`44971500`) and all runs performed 3,000 page loads per process.

| Key workload | Previous median CPU | New median CPU | Speedup | Previous RSS | New RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Numeric IDs | 2.297 s | 0.809 s | **2.84x** | 35,608 KiB | 34,208 KiB |
| Matrix-style event IDs | 1.802 s | 1.032 s | **1.75x** | 35,952 KiB | 35,192 KiB |

Medians of five alternating runs per version, CPU clock time as reported by
`os.clock()`, RSS from `/proc/self/status`. A slow outlier in one optimized
numeric run is preserved in the raw logs, not removed from the median. Host
load, filesystem cache and allocator behavior can affect the measurements.

This is an optimization to *cold cache misses*, not a claim that disk-backed
queries now match resident indexes. The immutable provider still decodes a
complete page directory on each miss and the hybrid overlay still retains all
hot rows and tombstones in memory. Broader stress tests, larger datasets,
secondary on-disk indexes and eventual sync barriers remain future work.

## Reproducing

```sh
jess run --package . --trusted bench/cold-lookup.jsl prepare number 30000
jess run --package . --trusted bench/cold-lookup.jsl measure number 30000 3000
jess run --package . --trusted bench/cold-lookup.jsl prepare string 30000
jess run --package . --trusted bench/cold-lookup.jsl measure string 30000 3000
```

The script creates `.jessql-cold-lookup-{number,string}.bin` under the working
directory; delete those files after benchmarking. On non-Linux hosts, the RSS
field reports `-1`; the timing and checksums remain available.
