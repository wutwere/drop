---
name: verify-tx
description: "Model-check drop's transaction protocol (drop.txasync) with TLA+. Use before and after any change to src/tx.luau, to the tx functions in src/store.luau (txphase0 to txphase2, txprepareasync, txcommitasync, txabortasync, resolvetxasync), or to the retries in src/rbxapi.luau, and when asked whether a transaction can split, wedge a key, or leak its record."
---

# Verify the transaction protocol

`bin/verify` checks a TLA+ model of one `drop.txasync` call against every order of steps and every allowed datastore failure. Tests cover the orders someone wrote down. This covers all of them, inside the bounds listed under "What a pass means".

The model is hand-written. It does not read the Luau. It is only worth its result while it matches the code, so keeping it matched is part of every change to the covered code.

## The rules

| Rule | In plain words | Harm when it breaks |
|---|---|---|
| `Atomic` | No reader sees one key with the transaction's update and another key settled without it. | A trade gives an item to one player and never takes it from the other. |
| `TruthfulReply` | `drop.txasync` returns normally only for a transaction that is applied or still will be, and reports a failure only for one that is not applied. When it cannot tell, it raises "outcome unknown". | The caller retries or refunds a trade that went through. |
| `Resolvable` | A key that holds the transaction's marker (`record.tx`) can always be settled, also when the tx record is gone. | `tx.resolveasync` answers "pending" forever. The key never saves again on any server. |
| `Cleanup` | Once no key holds the marker and no call is in flight, the tx record is removed. Checked without datastore failures only. | Records pile up in the `droptxs` datastore. |

## Run it

```sh
bin/verify
```

It needs Java, which `mise install` provides. The first run downloads TLC 1.7.4 into `.cache/verify` and checks its hash. A run takes about two minutes.

Each line is one row of `verify/checks.tsv`: a set of allowed failures, one rule, and the result the row expects.

- `ok` means the result matched. A `mutant-` row runs a deliberately broken variant of the model and is `ok` when the rule **breaks**, which shows the rule can fail. Most mutants are the behaviour of a fixed issue in `ISSUES.md`. A `finding-` row is `ok` when the rule breaks because the current code is known to break it. There are none right now.
- `UNEXPECTED ... breaks, expected holds` means the model found an order of steps that breaks the rule. Treat it as a bug until you have shown otherwise.
- `UNEXPECTED ... holds, expected breaks` on a `finding-` row means the finding is fixed in the model. On a `mutant-` row it means the rule lost its teeth.
- `error` means TLC could not run the model. The last lines of its output follow.

`VERIFY PASS` and exit code 0 mean every row matched.

To see the steps that break a rule:

```sh
bin/verify --trace mutant-missing-record-is-pending-Resolvable
```

Read every result with the pstack `/statechart` skill. Give it `verify/DropTx.tla` and a config with the row's constants. It tells each broken rule as its shortest path in plain words, and draws the states when nothing breaks.

## Does your change touch it?

```sh
git diff f82c449..HEAD --stat -- src/tx.luau src/store.luau src/rbxapi.luau
```

The sync commit is the last commit at which someone confirmed that the model describes the code. If the diff shows a change inside a function below, the model needs another look before its result means anything.

| Model actions | Code |
|---|---|
| `Prepare*`, `CoordPrepareFailed`, `CoordAllPrepared` | `txprepareasync`, `txphase1` in `src/store.luau` |
| `Commit*`, `Settle*`, `GiveUp` | `commitasync` in `src/tx.luau`, `txphase2` in `src/store.luau` |
| `Apply*`, `Abort*`, `FinishFails`, `CoordFinished` | `txcommitasync`, `txabortasync` in `src/store.luau` |
| `Adopt*`, `Remove*` | `adoptasync` in `src/tx.luau` |
| `Resolver*` | `resolvetxasync` in `src/store.luau`, `resolveasync` in `src/tx.luau` |
| `Retry`, every `...Fails` and `...LandsButErrors` action | the two attempts in `src/rbxapi.luau` |
| `Crash` | the server that called `drop.txasync` shutting down |

One step of the model is one attempt of one datastore call. An `UpdateAsync` transform is one step because Roblox runs it against the stored value atomically.

## When you change the covered code

1. Run `bin/verify` first. It must print `VERIFY PASS`, or you are starting from a broken state.
2. Make the same change in `verify/DropTx.tla`. Each action carries the Luau line it stands for as a comment. A changed transform changes the action's guard or its writes. A new datastore call is a new action, added to `Step`.
3. Run `bin/verify` again.
4. If a `holds` row now breaks, read the trace and decide which it is.
   - **A real bug.** Each step of the trace is something the code does. Confirm it on the real code with a test that replays the trace through `mockdatastoreservice` hooks. An "after" hook that raises is a write that landed and reported an error. `test/specs/issues.luau` has examples: "a prepare retried after the abort does not wedge the key" replays a trace this model found. Run it with `bin/test-cloud`. Then fix the code, not the rule.
   - **A modeling error.** Some step of the trace is something the code cannot do. Fix that action, and say in the commit which line of code rules the step out.
5. If you fixed a finding, its `finding-` row now reports `holds, expected breaks`. Keep the old behaviour as a `Mutant` in `DropTx.tla` and turn the row into a `mutant-` row, so the fix stays guarded. Make sure a `holds` row covers the rule under the failures that used to break it. Update `ISSUES.md`.
6. Never weaken a rule, remove a failure mode, or flip a row to `breaks` to get `VERIFY PASS`. A new way to break a rule is a finding. Add a `finding-` row for it, describe it in `ISSUES.md`, and tell the user.
7. Move the sync commit in this file to the new commit only after you have read the changed code against the model and confirmed they agree.

When you add a rule, add a `mutant-` row that breaks it. A rule that has never failed proves nothing.

## What a pass means

A pass covers the model, at these bounds:

- One transaction, with two keys. The three-key rows allow fewer kinds of failure, because every failure with three keys is too large to check quickly.
- Other servers may resolve any key at any time, one resolver per key at a time.
- A call lands, fails without writing, or lands and reports an error. A write that reports an error and lands later is not modeled.
- `commitasync` makes three rounds of two attempts to settle a commit it could not confirm. The model makes two attempts.
- There is no clock. The 60 second stale rule in `resolveasync` is modeled as "a resolver may abort a pending tx", at any time when `impatient` is set.

It does not cover:

- Sessions, `drop.update`, `drop.updateasync`, and the per-key lock in `store.lock`.
- Two transactions on the same key. A second transaction's prepare sees the first one's marker and acts as a resolver, which the model covers only as "some resolver".
- `tx.createasync` failing.
- Migrations.
- Whether the Luau matches the model. That is step 2 and step 7 above.

## Known findings

None. `ISSUES.md` lists the issues this model found or reproduced, all fixed. Their old behaviour lives on as these mutants:

| Mutant | Rule it breaks | Issue |
|---|---|---|
| `rollback-on-unknown` | `Atomic`, `TruthfulReply` | 2, 9 |
| `count-adoptions` | `Atomic` | 3 |
| `adopt-only-cleared` | `Cleanup` | 5 |
| `missing-record-is-pending` | `Resolvable` | 8 |
