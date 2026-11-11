# The fault laboratory

`@jessql/faultlab` stops a storage operation at every step it takes and checks what a restart
finds. It runs on the in-memory disk (`@jessql/memfs`, see `STORAGE-SEAM.md`), so it needs no
filesystem capability and is deterministic.

## What a scenario is

```luau
local scenario: lab.Scenario = {
  name = 'managed flush',
  prepare = function(disk, ledger) ... end,   -- the starting state; no fault here
  exercise = function(disk, ledger) ... end,  -- the operation under test
  recover = function(disk) ... end,           -- reopen, read back rows by commit id, close
}
local report = lab.run(scenario, { crashRecovery = true })
```

A scenario calls `ledger.begin(id, rows)` before it attempts a commit and `ledger.acknowledge(id)`
when the commit call has returned. `recover` returns how many rows of each commit it found, and
raises if the database cannot be opened or fails its own verification.

## What a run does

1. **Baseline.** The operation runs with no fault. Its storage steps, in order, are the fault
   schedule. The result must recover as left, and again after a crash.
2. **One run per step and mode**, on a fresh disk each time:
   - `crash`: the process dies at that step. Everything not synchronized is lost, and every
     later step that process's code attempts fails.
   - `fail`: that step fails once, as a full disk would; the operation continues or gives up as
     it chooses; then the process dies.
   - `fail-live`: that step fails once and nothing dies; the next open is by the same process.
3. **Optionally, one run per step of the recovery** that follows each crash, crashing the
   recovery too (`crashRecovery`).
4. After each, the scenario recovers and the **durable-sequence oracle** judges:
   an acknowledged commit is there, whole; a commit begun and not acknowledged is there whole or
   not at all; a commit never begun is not there; recovery succeeds. Then what recovery left is
   crashed and recovered once more.

A violation is returned as an artifact: scenario, mode, the step it stopped at, the recovery step
if any, the acknowledged and uncertain commits, what was observed, the last 16 storage steps, and
the size and SHA-256 of every file a restart would find. `lab.describe` renders one as text.
`maxRuns` bounds a run; reaching it sets `truncated`, never silently.

A run with a different step at the same ordinal is reported as `schedule-diverged`. An operation
that names scratch files at random gives the scenario a `stable` function to canonicalize them.

## What is covered (`tests/fault-lab.jsl`)

| Scenario | Steps | Runs | Violations |
|---|---|---|---|
| WAL commits, recovery crashed too | 8 | 57 | 0 |
| managed flush (seal, manifest replace, directory sync, retirement) | 81 | 244 | 0 |
| managed flush, crash only, recovery crashed at each of up to 44 steps | 81 | 2956 | 0 |
| managed checkpoint | 58 | 175 | 0 |
| managed selective compaction | 125 | 376 | 0 |
| managed backup (source untouched; a published copy is whole) | 70 | 211 | 0 |

The laboratory is first run on stores that are wrong on purpose, and must report each: an
acknowledgment before a sync (`acknowledged-lost`), a commit made durable in two halves
(`uncertain-torn`), a row nobody wrote (`phantom`), a recovery that raises (`recovery-failed`).

## What this is not

- **Not a power-loss certification.** The disk is a model: it loses what was not synchronized. It
  says nothing about torn sectors, writes reordered inside a file, or a device that acknowledges
  a sync it did not perform.
- **No real process kill.** A crash is simulated in one VM; a killed operating-system process
  with a real filesystem is not tested here.
- **No checksum-valid semantic corruption or bit flips.** The offline scan with semantic replay
  runs in every managed recovery, but nothing here corrupts bytes that were synchronized.
- **One fault per run** (plus one in recovery). Persistent disk-full, where every later write also
  fails, is not swept.
- **Commits are inserts of distinct rows.** Updates and deletions are in the prepared state of
  other suites, not in the oracle.
- Compaction scratch names are random, so two runs of that scenario are equivalent, not identical.
