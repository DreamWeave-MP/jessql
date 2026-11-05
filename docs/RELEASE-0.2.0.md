# JessQL 0.2.0 — native persistence release and deployment guide

**Package:** `org.dreamweave.jessql` · **Module:** `@jessql` · **License:**
`MIT OR Apache-2.0` ([MIT](../LICENSE-MIT), [Apache-2.0](../LICENSE-APACHE)).

This release promotes the `feat/native-persistence` work to the normal JessQL
package surface. **No experimental enablement flag, alternative JPK, server,
SQLite binding, or extra Rust extension is required.** It remains a single-
writer, single-table managed persistence engine, not a replicated or globally
serializable database. The `.jpk` is activated by Jess like any other package;
applications must grant the ordinary filesystem capabilities appropriate for
the paths they choose.

The release has been tested on **Linux x64** using **Jess 0.3.0 / Luau 0.745**.
No native Windows/macOS or physical power-cut certification is claimed.

## What's new in the 0.2.0 package

- Synchronized append-only WAL, fail-closed commit/uncertain outcome semantics,
  independent CRC-framed transaction batching, and recovery.
- Immutable paged generations, delta flush, tombstones, selective compaction,
  durable manifest publication, and optional hot-row/byte/WAL watermarks.
- A managed single-writer lifecycle with explicit create/open-existing APIs and
  scoped handle helpers.
- Cold-index and provider execution improvements, SQL query caching, and
  packed-memory options; see [benchmarks](../BENCHMARKS.md) for workload limits.
- Offline structural and optional semantic verification, reports with stable
  issue codes, non-overwriting offline backup/restore, and v1 observability.
- Entire shipped JSL package checks with `--!strict`, no diagnostic allowances.

The existing `sql.new()` in-memory and provider APIs remain available. Existing
raw `sql.open(path)` applications also remain supported as APIs, but their
**buffered mode is not equivalent to the managed synchronized protocol**.
For a new persistence integration, prefer the managed API and don't mix
raw WAL files with managed database basenames.

## Deploying as a normal JPK

In an application's `jess.toml`, after the 0.2.0 release is actually published:

```toml
[dependencies]
"org.dreamweave.jessql" = "0.2"
```

Run `jess workspace sync` in the consuming workspace to lock the published
package. Until the 0.2.0 tag/release is published through StroggForge, that
version is a **PR candidate**, not yet resolvable as a published package.

**First-time provisioning** (create the parent directory first):

```luau
--!strict
local sql = require('@jessql')
local options: sql.ManagedOptions = {
    tableName = 'events',
    columns = { 'id', 'room', 'body' },
    primaryKey = 'id',
    maxHotRows = 10000,
    maxWalBytes = 64 * 1024 * 1024,
    maxGenerations = 6,
}
local db = sql.managed.create('data/events', options)
db:close()
```

**Ordinary application startup**:

```luau
--!strict
local sql = require('@jessql')
local db = sql.managed.openExisting('data/events')
db:transaction(function(tx)
    tx:upsert({ id = 1, room = 'general', body = 'hello' })
end)
local row = db:get(1)
db:close()
```

The application host activates the `jessql.core` JPK layer normally. The package
manifest currently declares no extra layer capabilities; filesystem operations
still require the corresponding Jess host permissions. This is **not** an
independent deployment toggle. For precise transaction, recovery and event
semantics see the [application guide](APPLICATION-GUIDE.md).

## Upgrade and persistence compatibility

- The package version changes from `0.1.6` to `0.2.0`. There is **no implicit
  database migration triggered by the package version bump**. The 0.1.6
  release's in-memory provider/SQL APIs remain available in 0.2.0.
- Disk metadata formats have independent version markers; the version of a
  JPK is not a disk-format compatibility declaration. Back up before upgrading
  a database, and explicitly test reopening and semantic queries with the
  runtime/package version to be deployed.
- `managed.open()` remains a compatible open-or-create API, but
  `managed.openExisting()` is safer on routine application restart.
- Do not edit manifests, discard WALs, or mix generations by hand.
  Uncertain acknowledgments require reconciliation, **not** blind retries.
- The website's `content/home/mod.toml` is the **source release catalog**.
  The `0.2.0` `[[releases]]` entry must be committed **before** pushing the
  `jessql-0.2.0` tag. The tag must point to a commit containing matching
  `jess.toml` and `content/home/mod.toml` versions.
- `content/home/mod.lock` is a **separate, CI-generated publication ledger**
  containing artifact names and digests. Do not edit it by hand: the release
  job updates it after publishing the tag.

## Operator limitations and minimum deployment checklist

1. Single managed writer and a cooperative filesystem lock; no remote writer,
   distributed consensus, MVCC, or online backup.
2. Soft hot-memory and WAL watermarks are **not** hard RAM or disk limits.
   Compaction and large WAL semantic verification can require more memory.
3. Synchronized commit and publication failure tests do not constitute
   physical power-failure validation. Verify filesystem `replace`, file sync,
   and directory sync on the deployment OS.
4. Build and test the **same** packaged JPK that the application activates.
   Run the zero-error strict checker and both source and packaged tests.
5. Stop the writer for offline backup/restore; perform and test a restore into
   a fresh namespace and verify application-level data.
6. Document the runtime build, package digest, schema, filesystem location,
   WAL size/compaction metrics, and recovery plan before serving real users.

For incident procedures, see the [operator runbook](OPERATIONS.md),
[offline verification and backup](OFFLINE-VERIFICATION-AND-BACKUP.md),
[durable publication](PUBLICATION-PROTOCOL.md), and the
[adversarial architecture audit](ADVERSARIAL-ARCHITECTURE-REVIEW.md).

## Release gates and PR status

The PR must report the actual `jess package check`, `jess package test`, and
`git diff --check` results; never infer success from an earlier commit.
The existing site workflow delegates validation to StroggForge; this PR does
not independently establish that the hosted job enforces the local strict
script. Confirm that separately at PR time. A maintainer should also verify
code provenance and authority to distribute the current source under both
licenses before publishing `jessql-0.2.0`.

## StroggForge / Mod Template release sequence

**The site release catalog is an input to publishing, not its output.** Keep the
three version identities aligned *before* the release tag is pushed:

| Identity | Required 0.2.0 value | Owner |
| --- | --- | --- |
| `jess.toml` `[package].version` | `0.2.0` | Source commit |
| `content/home/mod.toml` `[[releases]].version` | `0.2.0` with date, summary and notes | Source commit |
| Git tag | `jessql-0.2.0`, pointing at that same source commit | Releaser |
| `content/home/mod.lock` | Recorded artifact metadata after tag publication | **CI only** |

Execute from the repository root before tagging:

```sh
jess run --trusted scripts/check_release_metadata.jsl
jess run --trusted scripts/check_strict.jsl
jess package test .
git diff --check
```

The first check rejects an absent or duplicated matching release entry,
misaligned JPK identity, malformed release date, and mismatched explicit tag.
It reads manifests only; it **does not** create releases, update `mod.lock`,
or prove that GitHub Actions will publish successfully. Review the
`0.2.0` entry's human-readable notes before tagging.

Once the source and site validation are green on the default branch, create
and push `jessql-0.2.0` from that exact commit. Let StroggForge record the
archive and digest in `content/home/mod.lock`. Verify the GitHub release,
site manifest, and `jess workspace sync` resolution after the tagged run.
Never move an already published tag without explicitly handling the existing
release and its consumers.

**Why this gate exists:** the first 0.2.0 PR preparation updated
`jess.toml` but failed to declare 0.2.0 in `content/home/mod.toml`. The older
runbook incorrectly said to wait until after publication. This mismatch is a
release-pipeline bug, not an intentional experimental-deployment restriction.
