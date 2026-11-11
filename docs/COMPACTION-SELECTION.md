# Compaction selection

Which generations a selective compaction merges is decided by `@jessql/compaction_plan`, a pure
function of the published generations' sizes. It does no I/O. Sealing, manifest publication,
directory synchronization and retirement are unchanged, whatever it selects.

## The candidates

A manifest lists generations oldest first, and a merge replaces a run of them with one
generation at the end of the list. Only the newest run can be replaced that way, so the
candidates are "the newest k generations" for k from 2 to `compactionFanIn`. Every candidate
keeps deletion markers safe: all older generations stay below the output
(`TOMBSTONE-SAFETY.md`).

## Policies (`compactionPolicy`)

| Policy | Chooses | Effect |
|---|---|---|
| `widest` (default) | the most generations the fan-in allows | fewest generations afterwards; may rewrite a large old generation to absorb a small one. What the store has always done. |
| `cheapest` | the candidate with the fewest bytes rewritten per generation removed; ties to the wider | leaves a large generation alone until the newer ones have grown enough to be worth merging with it |

A decision carries every candidate with its bytes and cost, and a one-line reason that the
managed store records in its maintenance journal as `compaction-selected`, for example:

    cheapest: newest 2 of 4 generations, 1262 bytes (1262 per generation removed, against 24541 for the newest 3)

The same input always gives the same decision. Fewer than two generations, a fan-in outside 2..8,
a size that is not a whole number of bytes, or an unknown policy is an error.

## What was checked (`tests/compaction-plan.jsl`, `tests/tombstone-histories.jsl`)

- The pure function: both policies on skewed and equal sizes, ties, bounds for every fan-in and
  generation count from 2 to 8, determinism, refusals.
- In the store, on one large generation and two small ones: `widest` merges all three,
  `cheapest` only the two small ones and writes less than a tenth of the row bytes; the rows read
  back are identical; deletions made in the small generations stay hidden; the result verifies
  offline and reopens.
- No policy given behaves exactly as `widest`; the rest of the suite, including the byte-exact
  golden format files, passes unchanged.
- 25 seeded tombstone histories of 160 steps under `cheapest` with fan-in 3: no resurrection.
- One sustained skewed fixture (a 400-row generation, then 24 rounds of 4 upserts with a flush
  each and a compaction whenever three generations exist), row bytes written:

  | `widest` | `cheapest` |
  |---|---|
  | 597792 | 93458 |

  A fixture chosen to show the difference, on the in-memory disk: not a benchmark, and the
  opposite workload (equal generations) gives no difference at all.

## Not done

- Leveled and read-amplification-aware policies. With newest-run candidates only, "fewest
  generations afterwards" is `widest`; a leveled layout needs merges that are not the newest run,
  which the manifest's ordering does not allow today.
- Scheduling: when to compact is still the generation budget, unchanged.
- p99 stalls, and sustained runs on a real filesystem with raw runs and uncertainty.
- Read amplification per policy: `cheapest` keeps more generations for longer, which costs reads;
  that cost was not measured here.
