# Persistent formats

What JessQL writes to disk, and which versions this build reads and writes. The list a program
can consult is `@jessql/formats`; this page is the same list with its rules.

| id | Magic | Written as | Reads | Writes | Module |
|---|---|---|---|---|---|
| `wal` | `JQLW1\n` | `<base>.g<epoch>.wal`, or the path given to `sql.open` | record version 1 | 1 | `@jessql/storage` |
| `rows` | `JQLP2\n` | `.rows`, `.deleted`, legacy secondary indexes, exports | 2 | 2 | `@jessql/paged` |
| `compact-index` | `JQLS1\n` | a caller-named sidecar (`format = 'compact'`) | 1 | 1 | `@jessql/compactsecondary` |
| `manifest` | `JQLM1\n` | `<base>.jql-manifest` | record versions 1 and 2 | 1 (one generation), 2 (a list) | `@jessql/managed_manifest` |
| `log-mark` | `JQLC1\n` | `<log>.committed`, beside a synchronized log | 1 | 1 | `@jessql/walmark` |

Lock files (`.jql-lock`, `.wal.lock`) are empty and carry no format.

## Rules

1. **A file is what its first six bytes say.** `formats.identify` knows the magics above and
   nothing else: a later version (`JQLP3\n`) is unknown, not "probably readable".
2. **An unknown version is refused, in words, at open.** It is never read as empty and never
   repaired. The offline scan reports it rather than passing.
3. **A registered version stays readable** until a release says otherwise in this table (`Reads`).
   Dropping read support is a breaking change with a migration path, not a cleanup.
4. **A format change is a new version**: a new magic or record version, a new row here and in
   `@jessql/formats`, and a new golden fixture. The old fixture is never edited.
5. **No downgrade promise.** A file written by a newer build is unknown to an older one (rule 2).

## What holds this to the code (`tests/formats.jsl`)

- `tests/fixtures/formats-v1.jsl` holds the bytes 0.2.0 wrote for a small managed database (three
  generations, a deletion, a live WAL), a snapshot, and both kinds of secondary index.
- Those files open, read back exactly, pass the offline scan with semantic replay, and accept
  new writes and a checkpoint.
- Today's writers produce those bytes exactly. A difference fails the test: that is how a format
  change is noticed before it ships.
- Every golden file identifies in the registry, under the name the store wrote it; every
  registered format has a golden file.
- Each file with its magic moved to the next version is refused at open, and by the offline scan.

## Not covered

- Fixtures from releases before 0.2.0: none are pinned, so nothing is claimed about them.
- Read-only opening of an old version while refusing writes: every registered version is both
  read and written today, so there is no such window to test yet.
- Corruption inside a known version (bad CRC, truncated page): the verification and durability
  suites, not this one.
- Byte order and platform differences: the fixtures were written and read on one platform.

## Damage inside a known version (`tests/format-fuzz.jsl`)

Each golden file is changed, one seeded mutation at a time (a flipped byte, a zeroed run, a
truncation, appended bytes), and the database or snapshot is opened and read on the result. The
acceptable outcomes are a refusal or exactly the rows that were written; a point read must agree
with the scan. 400 mutations per file:

| File | Refused | Read intact | Read as an earlier state |
|---|---|---|---|
| manifest | 400 | 0 | - |
| row generations (three files) | 400 each | 0 | - |
| deletion sidecars (two files) | 400 each | 0 | - |
| snapshot, compact index, legacy index | 400 each | 0 | - |
| write-ahead log | 370 | 11 | 19 |

**The immutable formats and the manifest refuse every mutation tried.** No mutation of any file
produced rows that were never committed.

**The write-ahead log, without a mark, is different.** A log that stops short, or whose last frame
fails its checksum, is what a crash during the last write leaves, and is read as that: in 19 of 400
mutations of a log with no mark beside it (as 0.2.0 wrote it), damage to the tail cost a
transaction that had been acknowledged, without a refusal.

**With its committed-length mark, it no longer is.** A synchronized store now records beside the
log (`<log>.committed`, format `JQLC1`, module `@jessql/walmark`) how long the log was and how many
transactions it held, after each commit is synchronized. A log found shorter than its mark is
refused at open, and the offline scan reports `WAL_SHORTER_THAN_COMMITTED`. Over 400 mutations of
the same log with its mark present, every one is read as the written rows or refused; none is
read as an earlier state (`tests/wal-committed-length.jsl`).

What the mark promises exactly: it is written only after the log's own synchronization, so a
crash can never make a sound log look damaged; it is made durable when the store is closed and
before a checkpoint shortens the log, not with every commit (that would double a commit's cost).
So after a clean close every commit is covered, and after a crash every commit up to the mark
that had reached storage. A log restored from an older copy is refused too; removing the mark is
how that loss is knowingly accepted. A log written before marks existed has none until its next
commit. A store that is not synchronized keeps none.

Not covered: more than one mutation at a time, mutations chosen by knowledge of the format
(a valid checksum over changed content), endianness, and candidate formats that do not exist
yet. This is random damage on small files, not a proof.
