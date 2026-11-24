------------------------------- MODULE DropTx -------------------------------
\* One drop transaction (drop.txasync) over a set of keys, from the moment its
\* tx record exists. Covers src/tx.luau and the tx functions in src/store.luau.
\*
\* One step of this model is one attempt of one datastore call. Roblox runs an
\* UpdateAsync transform against the stored value atomically, and a server
\* does nothing else between issuing a call and seeing its result that the
\* other steps here cannot interleave with.
\*
\* Every write goes through src/rbxapi.luau, which tries twice. An attempt
\*   - lands and returns,
\*   - fails without writing             (only when Fails), or
\*   - lands but reports an error        (only at the call sites in LostAt).
\* A transform that returns nil is a successful call that returns nil.
EXTENDS FiniteSets, Naturals

CONSTANTS
    Keys,      \* the participants of the transaction
    Fails,     \* BOOLEAN: a datastore call can fail without writing
    LostAt,    \* the call sites where a write can land and still report an error
    Crashes,   \* BOOLEAN: the coordinating server can stop at any step
    Declines,  \* BOOLEAN: an update function can return nil
    Impatient, \* BOOLEAN: a resolver can abort while the coordinator still runs
    Mutant     \* "none", or the name of a deliberately broken variant

VARIABLES
    status,     \* tx record: "pending" | "committed" | "aborted" | "removed"
    adoptedby,  \* tx record: participants recorded by tx.adoptasync
    adopted,    \* tx record: the legacy adoption counter
    prepared,   \* per key: whether the record holds this tx's marker, record.tx
    data,       \* per key: record.data, "old" or "new"
    seen,       \* per key: whether any server has read the key with the marker
    phase,      \* where the coordinating server is in txphase1 and txphase2
    prep,       \* per key: the prepare task spawned by txprepareasync
    fin,        \* per key: the task spawned by txcommitasync or txabortasync
    adoptq,     \* tx.adoptasync calls in flight
    res,        \* per key: a resolvetxasync call on some other server
    reply,      \* what drop.txasync told its caller
    attempted   \* whether commitasync's transform ever returned "committed"

vars == <<status, adoptedby, adopted, prepared, data, seen, phase, prep, fin,
          adoptq, res, reply, attempted>>

\* The call sites, named after the function that makes the call.
Sites == {"prepare", "commit", "settle", "finish", "adopt", "resolve", "expire"}
Lost(site) == site \in LostAt

Trying == {"try1", "try2"}
Finished == {"ok", "skipped", "failed"}

\* rbxapi.luau: the second failure is final.
Retry(t) == IF t = "try1" THEN "try2" ELSE "failed"

Marked(k) == prepared[k]
Alive == phase # "crashed"

Init ==
    /\ status = "pending"
    /\ adoptedby = {}
    /\ adopted = 0
    /\ prepared = [k \in Keys |-> FALSE]
    /\ data = [k \in Keys |-> "old"]
    /\ seen = [k \in Keys |-> FALSE]
    /\ phase = "prepare"
    /\ prep = [k \in Keys |-> "try1"]
    /\ fin = [k \in Keys |-> "idle"]
    /\ adoptq = {}
    /\ res = [k \in Keys |-> "idle"]
    /\ reply = "none"
    /\ attempted = FALSE

-----------------------------------------------------------------------------
\* Phase 1. txprepareasync, src/store.luau. Each key has its own task, and the
\* task keeps running after the coordinator has moved on.

PrepareFails(k) ==
    /\ Alive /\ Fails /\ prep[k] \in Trying
    /\ prep' = [prep EXCEPT ![k] = Retry(@)]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   fin, adoptq, res, reply, attempted>>

\* `if record.tx then return nil end`
PrepareBlocked(k) ==
    /\ Alive /\ prep[k] \in Trying /\ Marked(k)
    /\ prep' = [prep EXCEPT ![k] = "failed"]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   fin, adoptq, res, reply, attempted>>

\* The update function returns nil, or errors.
PrepareDeclines(k) ==
    /\ Alive /\ Declines /\ prep[k] \in Trying /\ ~Marked(k)
    /\ prep' = [prep EXCEPT ![k] = "failed"]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   fin, adoptq, res, reply, attempted>>

PrepareWrite(k) ==
    /\ Alive /\ prep[k] \in Trying /\ ~Marked(k)
    /\ prepared' = [prepared EXCEPT ![k] = TRUE]
    /\ seen' = [seen EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<status, adoptedby, adopted, data, phase, fin, adoptq, res,
                   reply, attempted>>

PrepareLands(k) ==
    /\ PrepareWrite(k)
    /\ prep' = [prep EXCEPT ![k] = "ok"]

PrepareLandsButErrors(k) ==
    /\ Lost("prepare") /\ PrepareWrite(k)
    /\ prep' = [prep EXCEPT ![k] = Retry(@)]

StartFinish == fin' = [k \in Keys |-> "try1"]

\* txprepareasync returns false on the first failed key. txphase1 then starts
\* txabortasync and resumes the caller with an error.
CoordPrepareFailed ==
    /\ phase = "prepare" /\ \E k \in Keys : prep[k] = "failed"
    /\ phase' = "aborting" /\ StartFinish /\ reply' = "error"
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep,
                   adoptq, res, attempted>>

CoordAllPrepared ==
    /\ phase = "prepare" /\ \A k \in Keys : prep[k] = "ok"
    /\ phase' = "commit1"
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep, fin,
                   adoptq, res, reply, attempted>>

-----------------------------------------------------------------------------
\* Phase 2. tx.commitasync, src/tx.luau, then txphase2, src/store.luau.

AfterCommitError == IF phase = "commit1" THEN "commit2" ELSE "settle1"

\* `if record.status == "pending" then record.status = "committed"`
CanCommit ==
    \/ status = "pending"
    \/ Mutant = "commit-ignores-status" /\ status = "aborted"

\* A call that fails can still have run the transform, so it counts as an
\* attempt to commit.
CommitFails ==
    /\ Fails /\ phase \in {"commit1", "commit2"}
    /\ phase' = AfterCommitError
    /\ attempted' = (attempted \/ CanCommit)
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep, fin,
                   adoptq, res, reply>>

CommitLands ==
    /\ phase \in {"commit1", "commit2"} /\ CanCommit
    /\ status' = "committed"
    /\ attempted' = TRUE
    /\ phase' = "applying" /\ StartFinish
    /\ UNCHANGED <<adoptedby, adopted, prepared, data, seen, prep, adoptq, res,
                   reply>>

CommitLandsButErrors ==
    /\ Lost("commit") /\ phase \in {"commit1", "commit2"} /\ CanCommit
    /\ status' = "committed"
    /\ attempted' = TRUE
    /\ phase' = AfterCommitError
    /\ UNCHANGED <<adoptedby, adopted, prepared, data, seen, prep, fin, adoptq,
                   res, reply>>

\* The transform returned nil: the record is missing or no longer pending.
CommitSkipped ==
    /\ phase \in {"commit1", "commit2"} /\ ~CanCommit
    /\ phase' = "settle1"
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep, fin,
                   adoptq, res, reply, attempted>>

\* commitasync could not confirm the commit, so it settles the record: it
\* switches a pending record to aborted and returns the status it finds. The
\* code makes several rounds of this call. The model makes two attempts, which
\* reach the same states.
Settling == phase \in {"settle1", "settle2"}

StartAbort == phase' = "aborting" /\ StartFinish /\ reply' = "error"

\* commitasync returns "unknown". txphase2 leaves every key prepared and
\* raises an error that says the outcome is unknown. The broken variant rolls
\* back instead, as the code did before.
GiveUp ==
    IF Mutant = "rollback-on-unknown"
      THEN StartAbort
      ELSE phase' = "unknown" /\ reply' = "unknown" /\ UNCHANGED fin

AfterSettleError ==
    IF phase = "settle1"
      THEN phase' = "settle2" /\ UNCHANGED <<fin, reply>>
      ELSE GiveUp

SettleFails ==
    /\ Fails /\ Settling
    /\ AfterSettleError
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep,
                   adoptq, res, attempted>>

SettleAborts ==
    /\ Settling /\ status = "pending"
    /\ status' = "aborted"
    /\ StartAbort
    /\ UNCHANGED <<adoptedby, adopted, prepared, data, seen, prep, adoptq, res,
                   attempted>>

SettleAbortsButErrors ==
    /\ Lost("settle") /\ Settling /\ status = "pending"
    /\ status' = "aborted"
    /\ AfterSettleError
    /\ UNCHANGED <<adoptedby, adopted, prepared, data, seen, prep, adoptq, res,
                   attempted>>

\* The record is settled or gone. A missing record was removed after every
\* key adopted it. If this server never tried to write "committed", nobody
\* did, so the transaction was aborted. Otherwise the outcome is unknown.
SettleReads ==
    /\ Settling /\ status # "pending"
    /\ IF status = "committed"
         THEN phase' = "applying" /\ StartFinish /\ UNCHANGED reply
         ELSE IF status = "aborted" \/ ~attempted
           THEN StartAbort
           ELSE GiveUp
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep,
                   adoptq, res, attempted>>

-----------------------------------------------------------------------------
\* txcommitasync and txabortasync, src/store.luau. One task per key.

FinishFails(k) ==
    /\ Alive /\ Fails /\ phase \in {"applying", "aborting"} /\ fin[k] \in Trying
    /\ fin' = [fin EXCEPT ![k] = Retry(@)]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, adoptq, res, reply, attempted>>

\* `record.data = record.tx.data; record.tx = nil`
ApplyWrite(k) ==
    /\ Marked(k)
    /\ data' = [data EXCEPT ![k] = "new"]
    /\ prepared' = [prepared EXCEPT ![k] = FALSE]
    /\ UNCHANGED seen

\* `record.tx = nil`
RollbackWrite(k) ==
    /\ Marked(k)
    /\ prepared' = [prepared EXCEPT ![k] = FALSE]
    /\ UNCHANGED <<data, seen>>

ApplyLands(k) ==
    /\ Alive /\ phase = "applying" /\ fin[k] \in Trying
    /\ ApplyWrite(k)
    /\ fin' = [fin EXCEPT ![k] = "ok"]
    /\ UNCHANGED <<status, adoptedby, adopted, phase, prep, adoptq, res, reply, attempted>>

ApplyLandsButErrors(k) ==
    /\ Alive /\ Lost("finish") /\ phase = "applying" /\ fin[k] \in Trying
    /\ ApplyWrite(k)
    /\ fin' = [fin EXCEPT ![k] = Retry(@)]
    /\ UNCHANGED <<status, adoptedby, adopted, phase, prep, adoptq, res, reply, attempted>>

\* No marker for this tx: another call already applied it. The transform
\* returns nil.
ApplySkipped(k) ==
    /\ Alive /\ phase = "applying" /\ fin[k] \in Trying /\ ~Marked(k)
    /\ fin' = [fin EXCEPT ![k] = "skipped"]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, adoptq, res, reply, attempted>>

AbortLands(k) ==
    /\ Alive /\ phase = "aborting" /\ fin[k] \in Trying
    /\ RollbackWrite(k)
    /\ fin' = [fin EXCEPT ![k] = "ok"]
    /\ UNCHANGED <<status, adoptedby, adopted, phase, prep, adoptq, res, reply, attempted>>

AbortLandsButErrors(k) ==
    /\ Alive /\ Lost("finish") /\ phase = "aborting" /\ fin[k] \in Trying
    /\ RollbackWrite(k)
    /\ fin' = [fin EXCEPT ![k] = Retry(@)]
    /\ UNCHANGED <<status, adoptedby, adopted, phase, prep, adoptq, res, reply, attempted>>

\* No marker for this tx: the transform returns nil.
AbortSkipped(k) ==
    /\ Alive /\ phase = "aborting" /\ fin[k] \in Trying /\ ~Marked(k)
    /\ fin' = [fin EXCEPT ![k] = "skipped"]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, adoptq, res, reply, attempted>>

AdoptCall(who, ks) ==
    IF ks = {} THEN {} ELSE {[who |-> who, keys |-> ks, stage |-> "try1"]}

\* A key is adopted once a call has seen it without this tx's marker. The
\* broken variant adopts only the keys whose marker the call itself cleared,
\* as the code did before.
AdoptsSkipped == Mutant # "adopt-only-cleared"
Settles == IF AdoptsSkipped THEN {"ok", "skipped"} ELSE {"ok"}

\* Every key task has reported. The coordinator adopts the settled keys, and
\* txcommitasync resumes the caller without an error.
CoordFinished ==
    /\ phase \in {"applying", "aborting"} /\ \A k \in Keys : fin[k] \in Finished
    /\ adoptq' = adoptq \union AdoptCall("coord", {k \in Keys : fin[k] \in Settles})
    /\ reply' = IF phase = "applying" THEN "ok" ELSE reply
    /\ phase' = "done"
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep, fin,
                   res, attempted>>

-----------------------------------------------------------------------------
\* tx.adoptasync, src/tx.luau.

AdoptCalls ==
    [who : {"coord", "resolver"}, keys : SUBSET Keys \ {{}},
     stage : {"try1", "try2", "remove"}]

Without(t) == adoptq \ {t}
Moved(t, stage) == Without(t) \union {[t EXCEPT !.stage = stage]}

AdoptFails(t) ==
    /\ t \in adoptq /\ Fails /\ t.stage \in Trying
    /\ adoptq' = IF t.stage = "try1" THEN Moved(t, "try2") ELSE Without(t)
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, res, reply, attempted>>

\* `if record == nil then return nil end`
AdoptMissing(t) ==
    /\ t \in adoptq /\ t.stage \in Trying /\ status = "removed"
    /\ adoptq' = Without(t)
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, res, reply, attempted>>

CountsAdoptions == Mutant = "count-adoptions"

\* The record is removed once every participant has adopted. The broken
\* variant reads the counter, as the code did before 745c3cd.
AllAdopted ==
    IF CountsAdoptions
      THEN adopted' = Cardinality(Keys)
      ELSE adoptedby' = Keys

AdoptWrite(t) ==
    /\ t \in adoptq /\ t.stage \in Trying /\ status # "removed"
    /\ CountsAdoptions \/ ~(t.keys \subseteq adoptedby)
    /\ adoptedby' = adoptedby \union t.keys
    /\ adopted' = adopted + Cardinality(t.keys)

AdoptLands(t) ==
    /\ AdoptWrite(t)
    /\ adoptq' = IF AllAdopted THEN Moved(t, "remove") ELSE Without(t)
    /\ UNCHANGED <<status, prepared, data, seen, phase, prep, fin, res, reply, attempted>>

AdoptLandsButErrors(t) ==
    /\ Lost("adopt") /\ AdoptWrite(t)
    /\ adoptq' = IF t.stage = "try1" THEN Moved(t, "try2") ELSE Without(t)
    /\ UNCHANGED <<status, prepared, data, seen, phase, prep, fin, res, reply, attempted>>

\* `if not changed then return nil end`: a successful call, so the count runs.
AdoptUnchanged(t) ==
    /\ ~CountsAdoptions
    /\ t \in adoptq /\ t.stage \in Trying /\ status # "removed"
    /\ t.keys \subseteq adoptedby
    /\ adoptq' = IF adoptedby = Keys THEN Moved(t, "remove") ELSE Without(t)
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, res, reply, attempted>>

RemoveLands(t) ==
    /\ t \in adoptq /\ t.stage = "remove"
    /\ status' = "removed"
    /\ adoptq' = Without(t)
    /\ UNCHANGED <<adoptedby, adopted, prepared, data, seen, phase, prep, fin,
                   res, reply, attempted>>

RemoveFails(t) ==
    /\ t \in adoptq /\ Fails /\ t.stage = "remove"
    /\ adoptq' = Without(t)
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, res, reply, attempted>>

-----------------------------------------------------------------------------
\* resolvetxasync, src/store.luau, and tx.resolveasync, src/tx.luau. Any other
\* server that has read a key holding this tx's marker can run it.
\*
\* tx.resolveasync aborts a tx that has been pending for more than 60 seconds.
\* The model has no clock. With Impatient, a resolver may abort a pending tx at
\* any time, which covers a coordinator that takes longer than 60 seconds.
\* Without it, a resolver aborts only after the coordinator has replied or
\* stopped.

SawMarker(k) == seen[k]
CanAbortStale ==
    status = "pending" /\ (Impatient \/ phase \in {"done", "crashed", "unknown"})

ResolverSeesCommitted(k) ==
    /\ res[k] = "idle" /\ SawMarker(k) /\ status = "committed"
    /\ res' = [res EXCEPT ![k] = "commit1"]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, adoptq, reply, attempted>>

ResolverSeesAborted(k) ==
    /\ res[k] = "idle" /\ SawMarker(k) /\ status = "aborted"
    /\ res' = [res EXCEPT ![k] = "abort1"]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, adoptq, reply, attempted>>

\* `if record == nil then return "aborted"`: a record is removed only after
\* every key adopted it, so a marker that outlives it was written by a prepare
\* that landed late. The broken variant answers "pending", as the code did
\* before, and the key can never be resolved.
MissingIsAborted == Mutant # "missing-record-is-pending"

ResolverSeesRemoved(k) ==
    /\ MissingIsAborted
    /\ res[k] = "idle" /\ SawMarker(k) /\ status = "removed"
    /\ res' = [res EXCEPT ![k] = "abort1"]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, adoptq, reply, attempted>>

ResolverAbortsStale(k) ==
    /\ res[k] = "idle" /\ SawMarker(k) /\ CanAbortStale
    /\ status' = "aborted"
    /\ res' = [res EXCEPT ![k] = "abort1"]
    /\ UNCHANGED <<adoptedby, adopted, prepared, data, seen, phase, prep, fin,
                   adoptq, reply, attempted>>

ResolverAbortsStaleButErrors(k) ==
    /\ Lost("expire") /\ res[k] = "idle" /\ SawMarker(k) /\ CanAbortStale
    /\ status' = "aborted"
    /\ UNCHANGED <<adoptedby, adopted, prepared, data, seen, phase, prep, fin,
                   adoptq, res, reply, attempted>>

Resolving(k) == res[k] # "idle"
ResolverCommits(k) == res[k] \in {"commit1", "commit2"}
ResolverRetry(k) == IF res[k] = "commit1" THEN "commit2"
                    ELSE IF res[k] = "abort1" THEN "abort2" ELSE "idle"

ResolverWriteFails(k) ==
    /\ Fails /\ Resolving(k)
    /\ res' = [res EXCEPT ![k] = ResolverRetry(k)]
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, adoptq, reply, attempted>>

ResolverWrite(k) ==
    /\ Resolving(k)
    /\ IF ResolverCommits(k) THEN ApplyWrite(k) ELSE RollbackWrite(k)

ResolverLands(k) ==
    /\ ResolverWrite(k)
    /\ res' = [res EXCEPT ![k] = "idle"]
    /\ adoptq' = adoptq \union AdoptCall("resolver", {k})
    /\ UNCHANGED <<status, adoptedby, adopted, phase, prep, fin, reply, attempted>>

ResolverLandsButErrors(k) ==
    /\ Lost("resolve") /\ ResolverWrite(k)
    /\ res' = [res EXCEPT ![k] = ResolverRetry(k)]
    /\ UNCHANGED <<status, adoptedby, adopted, phase, prep, fin, adoptq, reply, attempted>>

\* The marker is gone: the transform returns nil.
ResolverSkipped(k) ==
    /\ Resolving(k) /\ ~Marked(k)
    /\ res' = [res EXCEPT ![k] = "idle"]
    /\ adoptq' = IF AdoptsSkipped
                   THEN adoptq \union AdoptCall("resolver", {k})
                   ELSE adoptq
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, phase,
                   prep, fin, reply, attempted>>

-----------------------------------------------------------------------------
\* The coordinating server stops. Its tasks and its adoptasync calls stop too.
Crash ==
    /\ Crashes /\ Alive
    /\ phase' = "crashed"
    /\ adoptq' = {t \in adoptq : t.who # "coord"}
    /\ UNCHANGED <<status, adoptedby, adopted, prepared, data, seen, prep, fin,
                   res, reply, attempted>>

Step ==
    \/ \E k \in Keys :
        \/ PrepareFails(k) \/ PrepareBlocked(k) \/ PrepareDeclines(k)
        \/ PrepareLands(k) \/ PrepareLandsButErrors(k)
        \/ FinishFails(k)
        \/ ApplyLands(k) \/ ApplyLandsButErrors(k) \/ ApplySkipped(k)
        \/ AbortLands(k) \/ AbortLandsButErrors(k) \/ AbortSkipped(k)
        \/ ResolverSeesCommitted(k) \/ ResolverSeesAborted(k)
        \/ ResolverSeesRemoved(k)
        \/ ResolverAbortsStale(k) \/ ResolverAbortsStaleButErrors(k)
        \/ ResolverWriteFails(k) \/ ResolverLands(k)
        \/ ResolverLandsButErrors(k) \/ ResolverSkipped(k)
    \/ \E t \in AdoptCalls :
        \/ AdoptFails(t) \/ AdoptMissing(t) \/ AdoptLands(t)
        \/ AdoptLandsButErrors(t) \/ AdoptUnchanged(t)
        \/ RemoveLands(t) \/ RemoveFails(t)
    \/ CoordPrepareFailed \/ CoordAllPrepared
    \/ CommitFails \/ CommitLands \/ CommitLandsButErrors \/ CommitSkipped
    \/ SettleFails \/ SettleAborts \/ SettleAbortsButErrors \/ SettleReads
    \/ CoordFinished
    \/ Crash

\* Nothing left to do. Present so that an end state is not a deadlock.
Done == ~ENABLED Step /\ UNCHANGED vars

Next == Step \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* The rules.

\* A reader never sees one key with the transaction's update and another key
\* settled without it.
Atomic ==
    ~\E a, b \in Keys : data[a] = "new" /\ data[b] = "old" /\ ~Marked(b)

\* drop.txasync returns normally only for a transaction that is applied or
\* still will be, and reports a failure only for a transaction that is not
\* applied. When it cannot tell, it says so.
TruthfulReply ==
    /\ reply = "ok" => \A k \in Keys : data[k] = "new" \/ Marked(k)
    /\ reply = "error" => \A k \in Keys : data[k] = "old"

\* A key that holds the transaction's marker can always be settled. A pending
\* record is aborted once it is stale, and a committed or aborted record says
\* what to do. That leaves a marker whose record is gone: resolvers must
\* treat it as aborted, or the key never saves again.
Resolvable == \A k \in Keys : Marked(k) /\ status = "removed" => MissingIsAborted

\* Once no key holds the marker and no call is in flight, nothing will touch
\* the tx record again, so it must be gone.
Settled ==
    /\ phase \in {"done", "crashed", "unknown"}
    /\ phase # "crashed" => \A k \in Keys : prep[k] \notin Trying
    /\ adoptq = {}
    /\ \A k \in Keys : res[k] = "idle" /\ ~Marked(k)

Cleanup == Settled => status = "removed"

=============================================================================
