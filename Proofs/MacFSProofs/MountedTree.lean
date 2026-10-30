/-!
# `MountedTree` (Packages/FSCore/Sources/MountKit/MountedTree.swift)

Identifiers: the reader's root becomes 2, every other identifier passes through. The Swift code
refuses (`checkedMountID`) a non-root identifier at or below 2. Cookies: 0 starts, 2 resumes at `..`,
and a reader cookie `c` becomes `c + 3`; cookie 1 is refused.

Proved: under the refusal, the identifier map is injective and inverted by `readerID`; the cookie map
never produces a reserved cookie and is inverted by the decoding the Swift code uses.
-/

namespace MountedTree

def mountID (root r : Nat) : Nat := if r = root then 2 else r
def readerID (root m : Nat) : Nat := if m = 2 then root else m

/-- What `checkedMountID` accepts. -/
def accepted (root r : Nat) : Prop := r = root ∨ 2 < r

theorem round_trip (root r : Nat) (h : accepted root r) : readerID root (mountID root r) = r := by
  unfold accepted at h
  unfold readerID mountID
  by_cases hr : r = root
  · simp [hr]
  · have : 2 < r := by omega
    simp [hr]
    omega

theorem injective (root r s : Nat) (hr : accepted root r) (hs : accepted root s)
    (h : mountID root r = mountID root s) : r = s := by
  have := congrArg (readerID root) h
  rwa [round_trip root r hr, round_trip root s hs] at this

theorem root_is_two (root : Nat) : mountID root root = 2 := by simp [mountID]

def encodeCookie (c : Nat) : Nat := c + 3
def decodeCookie (k : Nat) : Nat := if k < 3 then 0 else k - 3

theorem cookie_round_trip (c : Nat) : decodeCookie (encodeCookie c) = c := by
  unfold decodeCookie encodeCookie
  split <;> omega

theorem cookie_not_reserved (c : Nat) : encodeCookie c ≠ 0 ∧ encodeCookie c ≠ 1 ∧ encodeCookie c ≠ 2 := by
  unfold encodeCookie
  omega

/-- A listing that advances (the reader's `nextCookie` grows) yields mount cookies that grow too, so
the resume position never moves backwards. -/
theorem cookies_monotone (c d : Nat) (h : c < d) : encodeCookie c < encodeCookie d := by
  unfold encodeCookie
  omega

end MountedTree
