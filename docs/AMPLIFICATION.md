# Measuring amplification

`@jessql/meter` wraps a storage backend and counts what the store asks of it. Open a database on
the wrapped backend and read the counters:

```luau
local meter = require('@jessql/meter')
local metered = meter.wrap(disk.backend)      -- any backend: memfs, or vfs.native()
local db = sql.managed.create(path, { ..., storage = metered.backend })
-- ... the workload ...
local counters = metered.counters()
```

## What is counted

By class of file (`wal`, `rows`, `deleted`, `manifest`, `scratch`, `lock`, `other`, from the names
the managed store gives its files):

| Counter | Meaning |
|---|---|
| `written` | bytes the backend accepted |
| `read` | bytes the backend returned |
| `removed`, `removedBytes` | files removed and the bytes they held: written once, now obsolete |
| `syncs` | `syncData` and `syncAll` calls |

and overall: `directorySyncs`, `replaces`, and `files` (bytes written to each path still there).

`meter.amplification(counters, userBytes, liveBytes, physicalBytes, returnedBytes?)` gives:

- **write** = bytes written to storage / bytes the user supplied;
- **space** = bytes on storage / bytes of live user data;
- **read** = bytes read from storage / bytes returned to the user.

The caller says how it measured the user's side; the meter only divides. `meter.header()` and
`meter.row(label, counters)` write samples as comma-separated values for a sustained run.

## What holds it to the truth (`tests/meter.jsl`)

- **Per file:** for every file left on the disk, bytes written through the meter equal the
  file's size.
- **Per class:** for `wal`, `rows` and `deleted`, bytes written equal bytes still held plus bytes
  removed. No scratch is left, and all of it was counted going.
- **No effect:** a database built with the meter and one built without it leave the same files,
  byte for byte.
- A write the backend refused is not counted.

## One measured run (a fixture, not a benchmark)

12 rounds of 40 upserts over 60 keys of 104 user bytes each, a flush after each round and a
selective compaction every fourth, on the in-memory disk, then a full scan after reopening:

| write | space | read |
|---|---|---|
| 4.19 | 7.08 | 7.55 |

This is a tiny dataset where page and directory overhead dominate and several generations still
hold superseded rows; it shows the meter working, and says nothing about a real workload.

## Cost when not used

None: no storage module refers to the meter. A database opened without it runs the same code as
before. The cost when it is used (a table lookup and an addition per call) was not measured.

## Not done

- Stalls and generation age. Cold-read fan-out (how many generations a read touched).
- Counters inside the store's own observability events; this is outside the store.
- Sustained-run dashboards; only the CSV lines.
- A run on a real filesystem at scale, with raw runs and uncertainty: no benchmark is claimed.
- The meter's own overhead.
