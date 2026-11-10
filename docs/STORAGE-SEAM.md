# The storage seam and the in-memory disk

JessQL reaches the filesystem through one module, `@jessql/vfs`. With nothing installed it is
`@dream/fs`. A test can install another backend:

```luau
local memfs = require('@jessql/memfs')
local vfs = require('@jessql/vfs')

local disk = memfs.new()
local restore = vfs.use(disk.backend)
-- sql.open, sql.managed.create, ... now run entirely in memory, with no filesystem capability
restore()
```

## Scope, stated plainly

- **Per VM, not per database.** One runtime has one storage backend at a time. A Jess test file
  runs in its own VM, so this is what offline tests need; it is not a per-handle
  `Options.storage` adapter, and two databases in one VM cannot use different backends.
- It changes no file format, no durability step and no public database API.
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
