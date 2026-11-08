# Known issues

These issues came out of comparing drop with [Ledger](https://github.com/XoifaiI/Ledger) and [dataforge](https://github.com/PepeElToro41/dataforge). Ledger's docs describe 1–3 for upstream drop, and all three still apply to this fork. Line numbers refer to this branch.

Many of these depend on the same Roblox behavior: **an `UpdateAsync` can error even though its write landed.** It's rare, but it tends to happen in bursts when the datastore service is struggling, and drop treats every error as "didn't happen".

| # | Issue | Severity | Status |
|---|---|---|---|
| 1 | Retried writes can apply twice | High | Open |
| 2 | An unknown commit outcome is rolled back as an abort, which can split a trade | High | Open |
| 3 | A retried adoption deletes the tx record early and wedges a key permanently | High | **Fixed** in 745c3cd |
| 4 | Errors while loading kill the session loop | High during deploys | Open |
| 5 | Tx records leak | Low | Open |
| 6 | Session polling uses a large share of the request budget | Low | Open |
| 7 | Smaller gaps | Low | Open |

## 1. Retried writes can apply twice

**Where:** `src/rbxapi.luau:81`. This affects `updateasync`, session flushes (`src/store.luau:297`), and the developer-product example in `README.md`.

`rbxapi.updateasync` retries a failed `UpdateAsync` immediately. Nothing in the record says the change already landed, so if the first attempt went through and then errored, the retry applies it again.
- **Session flushes:** if both attempts fail but the first landed, the queue is kept and replayed on the next tick. That applies it twice even without the retry.
- **The README's purchase example** can grant 2,000 coins instead of 1,000: once through the retry, and again because `NotProcessedYet` makes Roblox call `ProcessReceipt` again.

**Fix sketch:**
- Tag every write with a per-server id and sequence number.
- Store `jobid → last applied sequence` in the record, and have the transform skip a write it has already applied.
- For receipts, store `PurchaseId`s in the data and check them inside the update. Fix the README example to do the same.

## 2. An unknown commit outcome is rolled back as an abort, which can split a trade

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

**Where:**
- `src/store.luau:492` (`txabortasync`)
- `src/store.luau:456`

A key is only adopted once its `tx` marker is cleared, so the record stays in `droptxs` forever when:
- **A key was never prepared.** When a tx aborts because one key's update returned `nil` or errored, or because the key held another tx, that key is never adopted. That includes every trade cancelled by returning `nil`.
- **A commit write landed but errored.** The retry hits the `"unreachable"` assert, and the key is never adopted.

The leftover records are small, but they count toward the experience's datastore storage.

**Fix sketch:** have the abort transform count a key with no marker for this txid as settled. That is only safe if a prepare write can't land after the abort; issue 1's write ids would make that checkable.

## 6. Session polling uses a large share of the request budget

**Where:** `src/store.luau:9` (`DEFAULT_SESSION_TIME = 6`) and `rtasync`.

Each tick does a `GetAsync`, or an `UpdateAsync` (which counts against both the read and the write budget), per key per store, even when nothing changed. That's about 10 requests a minute per player per store, against a per-server budget of 60 + 40 × players per minute. Four stores use the whole per-player share.

**Fix sketch:**
- Poll less often while idle.
- Back off when `GetRequestBudgetForRequestType` is low.

## 7. Smaller gaps

- **No 4 MB size check.** An oversized record fails every flush forever. A tx prepare roughly doubles the record, since it holds both `data` and `tx.data`.
- **No `UserIds` on writes and no way to remove a key.** This matters for GDPR erasure requests.
- **`observe` can't be disconnected** (`src/store.luau:733`).
- **Session updates can be dropped silently.** An update that returns `nil` or errors when replayed during a flush is dropped without telling the caller (`src/store.luau:101`).
- **`rbxapi` retries with no backoff.**
