# Known issues

These issues came out of comparing drop with [Ledger](https://github.com/XoifaiI/Ledger) and [dataforge](https://github.com/PepeElToro41/dataforge). Ledger's docs describe 1–3 for upstream drop. Issues 8 and 9 came out of the TLA+ model that `bin/verify` checks, and issues 10 to 12 came up in review of those fixes. Line numbers under "Where" refer to b4d43cb, before the fixes, for issue 10 to 9c09fc5, and for issues 11 and 12 to 9e6d4ce.

Many of these depend on the same Roblox behavior: **an `UpdateAsync` can error even though its write landed.** It's rare, but it tends to happen in bursts when the datastore service is struggling, and drop treats every error as "didn't happen".

| # | Issue | Severity | Status |
|---|---|---|---|
| 1 | Retried writes can apply twice | High | **Fixed** |
| 2 | An unknown commit outcome is rolled back as an abort, which can split a trade | High | **Fixed** |
| 3 | A retried adoption deletes the tx record early and wedges a key permanently | High | **Fixed** in 745c3cd |
| 4 | Errors while loading kill the session loop | High during deploys | **Fixed** |
| 5 | Tx records leak | Low | **Fixed** without datastore failures |
| 6 | Session polling uses a large share of the request budget | Low | **Fixed** |
| 7 | Smaller gaps | Low | **Fixed** |
| 8 | A prepare retried after the abort wedges a key permanently | High | **Fixed** |
| 9 | `txasync` errors for a transaction that other servers committed | High | **Fixed** |
| 10 | A session stopped during a save that fails loses the save's updates | High | **Fixed** |
| 11 | A stop returns while the stopped session's loop is still saving | High | **Fixed** |
| 12 | A `drop.callbacks` function that errors ends a session loop or leaves a key locked | Medium | **Fixed** |

Every fix has a regression test in `test/specs/issues.luau`. Each test failed on b4d43cb, on 9c09fc5 for issue 10, or on 9e6d4ce for issues 11 and 12, and passes now.

`test/specs/schedules.luau` runs random schedules of session calls on two servers against a mock datastore that is slow and fails in bursts. It fails on the code from before the fixes for issues 10 and 11, and on a session save that ignores its sequence number.

`bin/verify` model-checks the transaction protocol (issues 2, 3, 5, 8, 9). The old behaviour of each is kept in the model as a `mutant-` row in `verify/checks.tsv`, which must break its rule on every run. See `.claude/skills/verify-tx/SKILL.md`.

## What is still open

- **Upgrading from a version before 745c3cd can split an old trade.** Those versions could remove the tx record of a committed transaction while a key was still prepared (issue 3). Such a key was stuck. It now resolves as aborted and is rolled back, while the other keys of that trade keep the update. The same happens while servers from before 745c3cd still run next to new ones. Finish the rollout of 745c3cd or later before relying on transactions.
- **A double apply is still possible in one narrow case.** A record remembers the newest write of its last 16 writers. If 16 other servers write a key between a write that landed with an error and its retry, the retry applies again.
- **Servers on an older version drop the `writes` field** when they save a record, so writes are only applied once after every server runs this version.
- **`drop.txasync` can raise "outcome unknown".** The caller must not retry or refund on that error. See the README.
- **A commit that cannot be confirmed blocks its keys for up to 60 seconds.** The keys stay prepared until a resolver aborts the stale record, and sessions on them cannot save meanwhile. Before, they were rolled back at once, which was the bug in issue 2.
- **A `drop.callbacks` function that yields holds up the call that reported to it.** That call can hold a key's lock, so a callback that calls `drop.stopsessionasync` or `drop.updateasync` for the same key never returns.
- **Tx records still leak when datastore calls fail** at the wrong moment, for example when an adoption fails on both attempts.
- **The README's receipt example needs `PurchaseId`s in the data.** drop cannot know that two `ProcessReceipt` calls are the same purchase.

## 1. Retried writes can apply twice

**Status:** fixed. Every store has a writer id for its session saves and one for its other writes, and every write has a sequence number. The record keeps the newest sequence number per writer in `writes`, and a transform skips a write the record already holds. Session updates carry one number each, so a failed save can be replayed together with newer updates. `drop.updateasync` holds the key's lock for its whole call, so its number stays the newest. Tests: "updateasync applies once when its write lands but errors" and "a session save that lands but errors is not replayed".

**Where:** `src/rbxapi.luau:81`. This affects `updateasync`, session flushes (`src/store.luau:297`), and the developer-product example in `README.md`.

`rbxapi.updateasync` retries a failed `UpdateAsync` immediately. Nothing in the record says the change already landed, so if the first attempt went through and then errored, the retry applies it again.
- **Session flushes:** if both attempts fail but the first landed, the queue is kept and replayed on the next tick. That applies it twice even without the retry.
- **The README's purchase example** can grant 2,000 coins instead of 1,000: once through the retry, and again because `NotProcessedYet` makes Roblox call `ProcessReceipt` again.

**Fix sketch:**
- Tag every write with a per-server id and sequence number.
- Store `jobid → last applied sequence` in the record, and have the transform skip a write it has already applied.
- For receipts, store `PurchaseId`s in the data and check them inside the update. Fix the README example to do the same.

## 2. An unknown commit outcome is rolled back as an abort, which can split a trade

**Status:** fixed. `commitasync` no longer reads the record back. When it cannot confirm the commit it switches a pending record to aborted and returns the status it finds, in up to three rounds. If that fails too it returns `"unknown"`, and `txphase2` leaves every key prepared and raises "txphase2 outcome unknown". Whoever loads a key next resolves it from the tx record. Test: "a commit that lands but errors is never rolled back". Model: `mutant-rollback-on-unknown-*`.

**Where:**
- `src/tx.luau:61-82` (`commitasync`)
- `src/store.luau:547-557` (`txphase2`)

If the commit write and the read-back both fail, `commitasync` returns `"aborted"` without writing it (`tx.luau:82`). The comment above it says this is safe because only the coordinator can commit, but that's not true if the commit write actually landed. `txphase2` then rolls back every key it reaches. Any key the rollback misses is later resolved as **committed** from the tx record, so some keys roll back and others commit.

The same happens if the read-back returns `"pending"` (`tx.luau:80`). The record is never marked aborted, so a write that lands late can still commit it.

**Fix sketch:**
- Only roll back once the tx record is durably `aborted`: retry the switch from pending to aborted until it is confirmed.
- If that can't be confirmed, leave the keys prepared and error with "outcome unknown". Resolvers will settle the keys from the record, and abort it after 60s if it's still pending.

## 3. A retried adoption deletes the tx record early and wedges a key permanently

**Status:** fixed in 745c3cd. Regression test: "a retried adoption does not remove the tx record before every key settles" in `test/specs/hardening.luau`.

**How it happened:**
1. A commit-phase write fails on both attempts, so that key stays prepared.
2. The coordinator records adoptions for the keys that did commit. That write lands, but the response is lost.
3. The retry counts those keys a second time. The counter reaches `total`, and the tx record is deleted.
4. `resolveasync` reads a missing record as `"pending"` forever, so the prepared key can never resolve.

For the player who owns that key:
- **On every server, nothing saves.** Their session loads and shows progress, but every flush is blocked by the leftover `tx`.
- **On the server they left,** `stopsessionasync` never finishes, and `startsession` there errors with "still stopping".
- **No warning is logged.**

**Fix:** `adoptasync` (`src/tx.luau:98`) records adoptions as a set of participant ids, so a retried adoption changes nothing. The legacy `adopted` counter is still written for older servers but is no longer read. During a mixed-version rollout, a record adopted partly by old servers and partly by new ones is never removed. That's a storage leak, not a correctness problem.

## 4. Errors while loading kill the session loop

**Status:** fixed. `migraterecord` returns a failure instead of raising, and no transform writes a record it cannot migrate. A session that hits one ends: waiters are woken with an error, unsaved updates are discarded, and `callbacks.externerror` reports both. Tests: "a record from a newer schema fails the session instead of hanging it" and "a migration that errors fails the session instead of hanging it".

**Where:**
- `src/store.luau:68`: the assert on the record version
- `src/store.luau:285-289`: a migration error during load
- `src/store.luau:352-354`: `rtasync`, which has no pcall

**Trigger 1, a newer record version.** During a rolling update, a new server migrates a player's record, and the player then joins an old server. The old server hits `assert(record.version <= #schema.migrations)`.
- If that happens while the session is starting, the loop thread dies. The session stays `"starting"` and `waitforsession` never returns.
- If the session is already active, it depends on the queue. With queued updates, every flush fails and the queue is never saved. With an empty queue, the next load kills the loop, and updates queued after that are never saved. Either way, `stopsessionasync` and `closeasync` then retry until the server shuts down.

**Trigger 2, a migration that errors on one player's data.** `loadrecordasync` raises "migration failed" and the loop dies, so that player's `waitforsession` never returns and the game can't kick or notify them.

**Fix sketch:**
- Run the loop body in a pcall.
- Treat a newer version as an "outdated" error: stop the session, wake waiters with that error, and never write.

## 5. Tx records leak

**Status:** fixed when no datastore call fails. A key is adopted once a write has seen it without the transaction's marker, whether or not that write cleared it. The commit transform returns `nil` for a missing marker instead of asserting. This relies on the fix for issue 8. Test: "a cancelled transaction removes its tx record". Model: `no-failures-Cleanup` and `mutant-adopt-only-cleared-Cleanup`.

**Where:**
- `src/store.luau:492` (`txabortasync`)
- `src/store.luau:456`

A key is only adopted once its `tx` marker is cleared, so the record stays in `droptxs` forever when:
- **A key was never prepared.** When a tx aborts because one key's update returned `nil` or errored, or because the key held another tx, that key is never adopted. That includes every trade cancelled by returning `nil`.
- **A commit write landed but errored.** The retry hits the `"unreachable"` assert, and the key is never adopted.

The leftover records are small, but they count toward the experience's datastore storage.

**Fix sketch:** have the abort transform count a key with no marker for this txid as settled. That is only safe if a prepare write can't land after the abort; issue 1's write ids would make that checkable.

## 6. Session polling uses a large share of the request budget

**Status:** fixed. A session with nothing to save doubles the time between its loads, up to the store's `idletime` (five times `sessiontime` by default), and skips idle loads while the server has fewer than 10 read requests left. Saving resets the interval. Changes made by other servers can now take up to `idletime` to show up in an idle session. Test: "an idle session polls less often and still saves promptly".

**Where:** `src/store.luau:9` (`DEFAULT_SESSION_TIME = 6`) and `rtasync`.

Each tick does a `GetAsync`, or an `UpdateAsync` (which counts against both the read and the write budget), per key per store, even when nothing changed. That's about 10 requests a minute per player per store, against a per-server budget of 60 + 40 × players per minute. Four stores use the whole per-player share.

**Fix sketch:**
- Poll less often while idle.
- Back off when `GetRequestBudgetForRequestType` is low.

## 7. Smaller gaps

**Status:** fixed.
- **Size.** A write whose record is over 4,000,000 characters of JSON is refused. `drop.updateasync` errors, a transaction fails to prepare, and a session discards its queued updates and reports that through `callbacks.externerror`. The check costs one JSON encode per write.
- **`UserIds`.** A store takes a `userids` function from key to user ids, passed on every write to that key. `drop.removeasync` removes a key.
- **`observe`** returns a function that stops the observer.
- **Dropped session updates** are reported through `callbacks.updatedropped`.
- **Retries** wait for the store's `retrydelay`, give or take half. It defaults to 0.5 seconds on Roblox's datastores and to 0 on any other datastore service.

- **No 4 MB size check.** An oversized record fails every flush forever. A tx prepare roughly doubles the record, since it holds both `data` and `tx.data`.
- **No `UserIds` on writes and no way to remove a key.** This matters for GDPR erasure requests.
- **`observe` can't be disconnected** (`src/store.luau:733`).
- **Session updates can be dropped silently.** An update that returns `nil` or errors when replayed during a flush is dropped without telling the caller (`src/store.luau:101`).
- **`rbxapi` retries with no backoff.**

## 8. A prepare retried after the abort wedges a key permanently

**Status:** fixed. `tx.resolveasync` resolves a missing tx record as `"aborted"`. A record is removed only after every key has adopted it, and a transaction only commits once every prepare has reported back, so a marker that outlives its record was written by a late prepare of an aborted transaction. Any server that loads the key now rolls the marker back. Test: "a prepare retried after the abort does not wedge the key". Model: `mutant-missing-record-is-pending-Resolvable`.

The cost: if a tx record is deleted by hand while a committed transaction still has a prepared key, that key is rolled back. Before, it was stuck.

**Where:** `txprepareasync` and `txabortasync` in `src/store.luau`.

`txprepareasync` returns as soon as one key fails, while the prepare writes for the other keys can still be retrying. The abort then clears a marker that a later retry writes again, after the key has already been adopted.

**How it happened,** with keys `a` and `b`:
1. `a`'s prepare lands but errors. The retry sees `a`'s own marker, returns `nil`, and `a` counts as failed.
2. `b`'s prepare lands but its error has not come back yet.
3. The abort clears both markers and adopts `a` and `b`.
4. `b`'s error comes back. rbxapi retries the prepare, finds no marker, and writes it again.
5. Both keys are adopted, so `adoptasync` removes the tx record.

`b` then held a marker for a record that no longer existed, and `resolveasync` answered `"pending"` for it forever.

## 9. `txasync` errors for a transaction that other servers committed

**Status:** fixed. When the tx record is gone after this server tried to commit it, `commitasync` returns `"unknown"` and `drop.txasync` raises "txphase2 outcome unknown" instead of "txphase2 failed to commit". If this server never tried to write the commit, a missing record still means aborted. Test: "txasync does not report a failure for a transaction other servers committed".

**Where:** `commitasync` in `src/tx.luau`.

This is issue 2 without any failed call. If the commit write lands but errors, other servers can resolve every key as committed, adopt them, and remove the tx record before the retry runs. The retry found no record, the read-back found none either, and `commitasync` returned `"aborted"`. Every key held the transaction's update while `drop.txasync` reported a failure.

## 10. A session stopped during a save that fails loses the save's updates

**Status:** fixed. `stopsessionasync` waits for a write of the key that is in flight before it looks at the queue, and returns once the session's updates are saved. `closeasync` stops each session through it. Tests: "stopsessionasync during a save that fails keeps the save's updates" and "closeasync during a save that fails keeps the save's updates".

**Where:** `src/store.luau:867` (`stopsessionasync`).

A session save moves the key's queue into `store.lock[key]` while its `UpdateAsync` runs, and puts it back in the queue if both attempts fail. `stopsessionasync` only saved `store.session.queue[key]`, so with nothing else queued it returned at once. When the save in flight then failed:
- **Its updates were lost.** The session loop that would have saved them again had ended.
- **The key refused a new session on that server,** with "still stopping", because its queue was never emptied.
- **`closeasync` waited on that queue** until the server shut down.

b4d43cb has the same bug. The retry delay from issue 7 makes a failing save take longer, so a stop is more likely to land during one.

## 11. A stop returns while the stopped session's loop is still saving

**Status:** fixed. `stopsessionasync` returns only when no write of the key is in flight and the queue is empty at the same moment. It waits for the key's lock before every look at the queue, not only the first. Test: "stopsessionasync waits for a save that the stopped session's loop starts".

**Where:** `src/store.luau:869-878` (`stopsessionasync`) and `src/store.luau:402` (`flushasync`).

This is issue 10 with the save started after the stop. A session loop that is already waiting for the key's lock inside `flushasync` does not check that its session still runs when the lock frees, so it can take the queue after the stop.

**How it happened:**
1. A `drop.updateasync` holds the key's lock. The session loop has an update queued and waits for the lock.
2. The `drop.updateasync` returns and the same thread calls `stopsessionasync`. Its save takes the queue, fails, and puts the queue back. The stop waits 0.15 to 0.25 seconds before it tries again.
3. The session loop takes the queue and starts its own save.
4. The stop wakes, finds no queue and returns.
5. The loop's save fails and puts the queue back. Nothing saves it.

The symptoms are those of issue 10: the updates are lost, the key refuses a new session with "still stopping", and `closeasync` waits until the server shuts down.

## 12. A `drop.callbacks` function that errors ends a session loop or leaves a key locked

**Status:** fixed. drop calls every `drop.callbacks` function through `src/report.luau`, which catches an error and warns about it. Tests: "an apierror callback that errors does not leave the key locked" and "an updatedropped callback that errors does not end the session's saves".

**Where:** `src/rbxapi.luau:35` (`apierror`), and `src/store.luau:130`, `459` and `481`.

The callbacks ran unprotected, so an error in one went up through drop's own code:
- **`apierror`** runs between the two attempts of a datastore call, while `drop.updateasync`, a session save or a transaction holds the key's lock. The error skipped the retry and the release. Every later write of the key on that server then waited forever, and since issue 10's fix so did `stopsessionasync`.
- **`updatedropped`, `externerror` and `migrationerror`** can run in the session loop, after a save or during a load. The error ended the loop while the session still looked active, so its later updates were never saved. Inside a datastore write, the same error only failed that write.
