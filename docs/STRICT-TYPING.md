# JessQL strict typing and release contract

JessQL is a Jess JPK with one type-checking policy: **every shipped JSL file
must declare `--!strict` and the native package checker must report zero
diagnostics**. There are no exception files, warning budgets, suppressed
modules or baseline allowances.

## Run the release checks

From the JessQL repository root, using the Jess runtime corresponding to the
package's pinned API:

```sh
jess package check . --format json
python3 scripts/check-strict.py /path/to/jess
jess package test .
```

The first command is the underlying Jess compiler/type checker. The gate
script verifies that *all* shipped JSL paths under `src/`, `tests/`, and
`bench/` begin with `--!strict`, checks that the native package checker visited
all of them, and fails on **any** diagnostic or nonzero checker exit status.
The last command runs source and packaged-JPK behavioral tests, including the
repository style suite; static checks are not a substitute for executing code.

At the time of this pass, the package includes **78 JSL files** and the
behavioral suite includes **274 tests in each of source and packaged mode**.
These counts are observations, not hard-coded limits: newly added files must be
covered automatically.

## Fixing types without weakening the contract

- Model SQL's dynamic values at the evaluator boundary as `unknown`, narrowing
  to concrete primitive types only where operators or provider contracts need it.
- Give query plans, joins, grouping/aggregate state, provider envelopes and
  result materialization explicit internal types. Keep public provider methods
  and SQL observable behavior compatible.
- Use an assertion or explicit narrowing when a test *requires* a non-null
  result; don't replace assertions with permissive types that hide a missing row.
- Pay attention to Luau multi-return calls at argument boundaries. Explicit
  parentheses around filesystem calls can prevent extra return values from
  leaking into positional arguments.
- Avoid using `any`, `--!nocheck`, or `--!nonstrict` to clear diagnostics.
  The aim is to describe the runtime's real contracts, not to silence the
  checker.

Some refinements necessarily use casts from `unknown` to SQL runtime value
shapes. These are not runtime validators. Keep adversarial SQL semantics tests
and provider-contract tests alongside static checks, especially when editing
aggregate finalization, nullable joins, or binary comparisons.

## CI policy and limitations

Run both strict checking and package tests on **every** proposed change,
not merely on storage-specific modifications. Before advertising this as an
automated merge gate, connect the commands to the pinned Jess runtime in the
project's StroggForge CI pipeline and verify enforcement on a failing test
branch. This repository does not yet claim that the hosted pipeline enforces
this new script.

Successful `!strict` checking does **not** establish query correctness,
physical power-loss durability, cross-platform behavior, or performance
non-regression. Those require separate test and measurement gates.
