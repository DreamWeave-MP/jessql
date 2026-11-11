# Persistent formats

What JessQL writes to disk, and which versions this build reads and writes. The list a program
can consult is `@jessql/formats`; this page is the same list with its rules.

| id | Magic | Written as | Reads | Writes | Module |
|---|---|---|---|---|---|
| `wal` | `JQLW1\n` | `<base>.g<epoch>.wal`, or the path given to `sql.open` | record version 1 | 1 | `@jessql/storage` |
| `rows` | `JQLP2\n` | `.rows`, `.deleted`, legacy secondary indexes, exports | 2 | 2 | `@jessql/paged` |
| `compact-index` | `JQLS1\n` | a caller-named sidecar (`format = 'compact'`) | 1 | 1 | `@jessql/compactsecondary` |
| `manifest` | `JQLM1\n` | `<base>.jql-manifest` | record versions 1 and 2 | 1 (one generation), 2 (a list) | `@jessql/managed_manifest` |

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
