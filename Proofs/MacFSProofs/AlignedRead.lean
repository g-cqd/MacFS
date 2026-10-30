/-!
# `AlignedReader` (Packages/FSCore/Sources/FSCore/AlignedReader.swift)

A read of `count` bytes at `offset` on a device of `size` bytes is widened to
`[first, last)` with `first = offset / a * a` and `last = min(⌈(offset + count) / a⌉ * a, size)`.
The Swift code computes `first` with `offset & ~(a - 1)`, which equals `offset / a * a` when `a` is a
power of two; the proofs use the division form, which holds for every `a > 0`.

Proved: the transfer covers the request, stays on the device, starts on a boundary, and, on a device
whose size is a multiple of `a`, ends on one.
-/

namespace AlignedRead

def first (a offset : Nat) : Nat := offset / a * a

def last (a size offset count : Nat) : Nat := min ((offset + count + a - 1) / a * a) size

theorem first_le_offset (a offset : Nat) : first a offset ≤ offset := by
  unfold first
  exact Nat.div_mul_le_self offset a

theorem first_aligned (a offset : Nat) : first a offset % a = 0 := by
  unfold first
  exact Nat.mul_mod_left _ _

theorem covers_end (a size offset count : Nat) (ha : 0 < a) (hin : offset + count ≤ size) :
    offset + count ≤ last a size offset count := by
  unfold last
  have hup : offset + count ≤ (offset + count + a - 1) / a * a := by
    have h := Nat.lt_div_mul_add (a := offset + count + a - 1) ha
    have : (offset + count + a - 1) % a < a := Nat.mod_lt _ ha
    have hdm := Nat.div_add_mod (offset + count + a - 1) a
    rw [Nat.mul_comm] at hdm
    omega
  exact Nat.le_min.mpr ⟨hup, hin⟩

theorem within_device (a size offset count : Nat) : last a size offset count ≤ size := by
  unfold last
  exact Nat.min_le_right _ _

theorem last_aligned (a size offset count : Nat) (hsize : size % a = 0) :
    last a size offset count % a = 0 := by
  unfold last
  rcases Nat.le_total ((offset + count + a - 1) / a * a) size with h | h
  · rw [Nat.min_eq_left h]; exact Nat.mul_mod_left _ _
  · rw [Nat.min_eq_right h]; exact hsize

/-- The bytes handed back are exactly the requested ones: they start `offset - first` into the
transfer and end inside it. -/
theorem trim_in_range (a size offset count : Nat) (ha : 0 < a) (hin : offset + count ≤ size) :
    (offset - first a offset) + count ≤ last a size offset count - first a offset := by
  have h1 := first_le_offset a offset
  have h2 := covers_end a size offset count ha hin
  omega

end AlignedRead
