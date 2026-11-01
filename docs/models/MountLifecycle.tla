---- MODULE MountLifecycle ----
\* The mount seam's lifecycle (ADR-0013, roadmap 0035): MountService, its registry, the system's mount table and the proxies
\* this process serves, with a crash between any two steps, a kernel that removes a dead proxy's mount (deadtimeout), and
\* mounts that are not MacFS's appearing and going at any time. Hand-written, step for step with MountService and
\* NFSMountBackend; MountServiceTests and NFSMountBackendTests check the same steps on fakes. A sweep handles one record per
\* step, as the code walks them; it holds the service's lock, so nothing else of MacFS runs until it is done.
EXTENDS FiniteSets

CONSTANTS Ids, Points, Kinds

VARIABLES
    reg,      \* the registry: per id, none, or a record [state, point, kind]
    table,    \* the mount table: per point, none, foreign, or ours (an id and the kind that mounted it)
    serving,  \* ids whose proxy this process serves
    alive,    \* the process is running
    toSweep,  \* records the sweep after a restart has not settled yet
    pc,       \* per id, the step of an operation in flight
    bad       \* what must never happen, named

vars == <<reg, table, serving, alive, toSweep, pc, bad>>

NoRecord == [state |-> "none", point |-> "none", kind |-> "none"]
Free == <<"none">>
Foreign == <<"foreign">>
Ours(i, k) == <<"ours", i, k>>
IsOurs(e) == e[1] = "ours"

Records == {i \in Ids : reg[i].state # "none"}
Settled == alive /\ toSweep = {}

TypeOK ==
    /\ \A i \in Ids : reg[i] = NoRecord \/ (reg[i].state \in {"pending", "mounted"} /\ reg[i].point \in Points /\ reg[i].kind \in Kinds)
    /\ \A p \in Points : table[p] \in {Free, Foreign} \cup {Ours(i, k) : i \in Ids, k \in Kinds}
    /\ serving \subseteq Ids /\ toSweep \subseteq Ids
    /\ pc \in [Ids -> {"idle", "mounting", "up", "down"}]

Init ==
    /\ reg = [i \in Ids |-> NoRecord]
    /\ table = [p \in Points |-> Free]
    /\ serving = {} /\ alive = TRUE /\ toSweep = {}
    /\ pc = [i \in Ids |-> "idle"]
    /\ bad = {}

\* mount(source:kind:at:) — 1: the pending record is saved, if the point is free in the registry and the table.
Begin(i, p, k) ==
    /\ Settled /\ pc[i] = "idle" /\ reg[i] = NoRecord
    /\ table[p] = Free /\ \A j \in Records : reg[j].point # p
    /\ reg' = [reg EXCEPT ![i] = [state |-> "pending", point |-> p, kind |-> k]]
    /\ pc' = [pc EXCEPT ![i] = "mounting"]
    /\ UNCHANGED <<table, serving, alive, toSweep, bad>>

\* 2: the backend mounts (its proxy serves), or fails and the record is removed.
BackendMount(i) ==
    /\ alive /\ pc[i] = "mounting" /\ table[reg[i].point] = Free
    /\ table' = [table EXCEPT ![reg[i].point] = Ours(i, reg[i].kind)]
    /\ serving' = serving \cup {i}
    /\ pc' = [pc EXCEPT ![i] = "up"]
    /\ UNCHANGED <<reg, alive, toSweep, bad>>

BackendFail(i) ==
    /\ alive /\ pc[i] = "mounting"
    /\ reg' = [reg EXCEPT ![i] = NoRecord]
    /\ pc' = [pc EXCEPT ![i] = "idle"]
    /\ UNCHANGED <<table, serving, alive, toSweep, bad>>

\* 3: the record is saved as mounted.
SaveMounted(i) ==
    /\ alive /\ pc[i] = "up"
    /\ reg' = [reg EXCEPT ![i].state = "mounted"]
    /\ pc' = [pc EXCEPT ![i] = "idle"]
    /\ UNCHANGED <<table, serving, alive, toSweep, bad>>

\* What the backend's unmount does to the table: `umount <point>`, then `umount -f <point>` if the mount stays, only while the
\* table shows this record's mount there (without that check, TLC found: ours ejected by the user, another mount at the point,
\* then our unmount removed it).
UnmountAt(i) ==
    LET p == reg[i].point
        e == table[p]
        removed == IF e = Ours(i, reg[i].kind) THEN e ELSE Free  \* drop the guard to see TLC's trace again
    IN /\ table' = IF removed = Free THEN table ELSE [table EXCEPT ![p] = Free]
       /\ bad' = bad \cup (IF removed = Foreign THEN {"a mount that is not MacFS's was unmounted"} ELSE {})
                     \cup (IF IsOurs(removed) /\ removed[2] # i THEN {"another record's mount was unmounted"} ELSE {})
                     \cup (IF IsOurs(removed) /\ removed[3] # reg[i].kind THEN {"an unmount went to another backend"} ELSE {})
       /\ serving' = serving \ {i}

\* unmount(id:) — 1: the backend unmounts; 2: the record is removed.
Unmount(i) ==
    /\ Settled /\ pc[i] = "idle" /\ reg[i].state = "mounted"
    /\ UnmountAt(i)
    /\ pc' = [pc EXCEPT ![i] = "down"]
    /\ UNCHANGED <<reg, alive, toSweep>>

SaveRemoved(i) ==
    /\ alive /\ pc[i] = "down"
    /\ reg' = [reg EXCEPT ![i] = NoRecord]
    /\ pc' = [pc EXCEPT ![i] = "idle"]
    /\ UNCHANGED <<table, serving, alive, toSweep, bad>>

\* The process dies: its proxies with it, every operation cut where it was.
Crash ==
    /\ alive
    /\ alive' = FALSE /\ serving' = {} /\ pc' = [i \in Ids |-> "idle"]
    /\ UNCHANGED <<reg, table, toSweep, bad>>

\* A new process starts and sweeps before anything else.
Restart ==
    /\ ~alive
    /\ alive' = TRUE /\ toSweep' = Records
    /\ UNCHANGED <<reg, table, serving, pc, bad>>

\* sweep(), one record: ours if the table shows its mount (a pending one: a mount its backend claims); not ours, forgotten;
\* ours and served, kept; ours and not served, unmounted.
SweepOne(i) ==
    /\ alive /\ i \in toSweep
    /\ LET e == table[reg[i].point]
           ours == IF reg[i].state = "mounted" THEN e = Ours(i, reg[i].kind) ELSE IsOurs(e) /\ e[3] = reg[i].kind
       IN IF ~ours THEN
              /\ reg' = [reg EXCEPT ![i] = NoRecord]
              /\ UNCHANGED <<table, serving, bad>>
          ELSE IF reg[i].state = "mounted" /\ i \in serving THEN
              /\ UNCHANGED <<reg, table, serving, bad>>
          ELSE
              /\ UnmountAt(i)
              /\ reg' = [reg EXCEPT ![i] = NoRecord]
    /\ toSweep' = toSweep \ {i}
    /\ UNCHANGED <<alive, pc>>

\* The kernel unmounts a soft mount whose proxy has died (deadtimeout).
DeadTimeout(p) ==
    /\ IsOurs(table[p]) /\ table[p][2] \notin serving
    /\ table' = [table EXCEPT ![p] = Free]
    /\ UNCHANGED <<reg, serving, alive, toSweep, pc, bad>>

\* The user unmounts one of ours (`umount`, Finder's eject): the proxy goes on serving, unaware.
UserUnmount(p) ==
    /\ IsOurs(table[p])
    /\ table' = [table EXCEPT ![p] = Free]
    /\ UNCHANGED <<reg, serving, alive, toSweep, pc, bad>>

\* Someone else mounts at a free point, or unmounts theirs.
ForeignMount(p) ==
    /\ table[p] = Free
    /\ table' = [table EXCEPT ![p] = Foreign]
    /\ UNCHANGED <<reg, serving, alive, toSweep, pc, bad>>

ForeignUnmount(p) ==
    /\ table[p] = Foreign
    /\ table' = [table EXCEPT ![p] = Free]
    /\ UNCHANGED <<reg, serving, alive, toSweep, pc, bad>>

Next ==
    \/ \E i \in Ids, p \in Points, k \in Kinds : Begin(i, p, k)
    \/ \E i \in Ids : BackendMount(i) \/ BackendFail(i) \/ SaveMounted(i) \/ Unmount(i) \/ SaveRemoved(i) \/ SweepOne(i)
    \/ Crash \/ Restart
    \/ \E p \in Points : DeadTimeout(p) \/ UserUnmount(p) \/ ForeignMount(p) \/ ForeignUnmount(p)

Spec == Init /\ [][Next]_vars

\* Nothing named in `bad` ever happens: no foreign mount, no other record's mount, no other backend unmounted.
NothingBad == bad = {}

\* A point holds one record.
OnePerPoint == \A i, j \in Records : i # j => reg[i].point # reg[j].point

\* Every mount of MacFS's is on record, so a sweep can always find it.
MountsAreRecorded == \A p \in Points : IsOurs(table[p]) => reg[table[p][2]].state # "none"
====
