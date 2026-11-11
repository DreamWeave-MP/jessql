# The storage seam and the in-memory disk

JessQL reaches the filesystem through one module, `@jessql/vfs`, and a database is given its
backend when it is opened:

```luau
local memfs = require('@jessql/memfs')
local sql = require('@jessql')

local disk = memfs.new()
local db = sql.managed.create('/memory/events', { tableName = 'events', columns = { 'id' },
  primaryKey = 'id', storage = disk.backend })
-- runs entirely in memory, with no filesystem capability
```

Without `storage`, a database gets the VM default, which is `@dream/fs` unless a test installed
another with `vfs.use(backend)` (it returns the function that restores what was there).

## Scope, stated plainly

- **Per database.** The backend is resolved once, when a database is opened, created, verified,
  inspected or copied, and held by that database for as long as it is open. Two databases in one
  VM can sit on two backends. Where it goes: `storage` in the options of `sql.open`,
  `sql.managed.*`, `sql.hybrid.open`, `sql.paged.*`, `sql.segments.*`, `sql.delta.create`,
  `sql.secondary.*` and `sql.tiers.compact`; the last argument of `sql.managed.inspect`; and
  `{ storage, destinationStorage }` for `sql.managed.backup`, which may cross from one backend to
  another.
- **What a database writes goes where the database is.** Exports, sidecars, compaction scratch,
  manifests and retirements use the database's backend whatever options the call was given.
- **The VM default is read at open and never again.** `vfs.use` may be called while databases are
  open; it changes nothing for them. This replaces the earlier per-VM seam and its lock-count
  guard (`vfs.busy`, `vfs.abandon`), which refused the swap instead: there is no longer a swap
  that could move a database. Installations nest and are undone innermost first; restoring out of
  order raises, and each restore works once.
- **How this is held:** no storage module calls the default. Their file operations go through a
  local resolved on entry, internal helpers take the backend as a required argument, and
  `tests/storage-ownership.jsl` runs a managed database through create, flush, compaction,
  checkpoint, reopen, inspect, verify and backup, and a hybrid database through its exports, with
  the VM default set to a backend that raises on any call.
- **Not covered:** one database spread over two backends (hot on one, cold on another), and a
  backend chosen by path. Both are possible on this shape; neither is built.
- It changes no file format and no durability step. Existing calls behave as before; the
  additions to the public API are the optional parameters above.
- It does not provide multi-table transactions or off-loop commits.

## What the in-memory disk models

The one thing a real disk does that a table of strings does not: what was written and what would
survive are different.

| Operation | Visible at once | Survives `disk.crash()` |
|---|---|---|
| `writer:write` | no (buffered until `flush`, a sync or `close`) | no |
| `writer:flush`, `writer:close` | yes | no |
| `writer:syncData`, `writer:syncAll` | yes | the file's bytes, yes; its name only if the directory was synchronized or the file was made by `createDurable` |
| `createDurable` | yes | bytes and name |
| `writeFile` | yes | no (`atomic = true`: the bytes, not the name) |
| `rename`, `replace`, `remove` | yes | only after `syncDirectory` of the parent |
| `lock` | yes | released; a handle from before the crash is dead |

`disk.crash()` discards everything not synchronized, releases every lock and invalidates every
open handle. This is the **adversarial reading** of what `@dream/fs` documents: a real disk often
keeps more than it promised, so a store that recovers correctly here has relied on nothing it was
not promised.

**It is a model, not a power cut.** It says nothing about torn sectors, writes reordered inside
one file, a device that acknowledges a sync it did not perform, or any platform's actual
behaviour. Passing on it is necessary for crash safety, not proof of it.

## Fault injection

```luau
disk.inject(function(step, path, occurrence)
  if step == 'syncData' and occurrence == 2 then return { message = 'disk full', kind = 'other' } end
  return nil
end)
```

The injector runs before every operation, named as the function or handle method
(`createDurable`, `openWrite`, `write`, `flush`, `syncData`, `syncAll`, `truncate`, `close`,
`replace`, `rename`, `remove`, `syncDirectory`, `lock`, `open`, `openPositional`, `readAt`,
`readFileString`, `stat`, `list`, `writeFile`). Returning a fault makes that operation answer
`nil, message, kind`; a writer that fails is poisoned, as a real one is. Calling `disk.crash()`
inside the injector crashes at that point. `disk.steps()` is the ordered record of every
operation, so a test can first learn the steps of a commit and then fail each in turn.

`disk.visible()` and `disk.surviving()` return the bytes by path as they are now and as a crash
would leave them.

## How it was validated

- Every existing storage suite (19 files: journal, pages, hybrid, secondary indexes, segments,
  delta, tiers, durability, managed generations, compaction, group commit, publication,
  verification, backup, …) runs **a second time, unchanged, on the in-memory disk**
  (`tests/memory/*.jsl`). They pass. That is the evidence the disk behaves like `@dream/fs` for
  everything JessQL does with it.
- `tests/memory-storage.jsl` covers the crash model itself, fault injection, and a sweep: one
  synchronized commit takes two storage steps (`write`, `syncData`); with a fault injected at
  each in turn, the commit is refused, and after a crash the previously acknowledged row is
  present, the refused one is absent, and the database accepts and keeps a new commit.

Not validated: handle methods and options JessQL does not use (`walk`, links, `copy`,
authenticated reads, shared locks, `writeThrough`); they are absent or minimal here.
