/-
Model of the body-piece loop in the NGINX attachment
(ngx_cp_io.c ngx_http_cp_body_sender, async/ngx_cp_async_sender.c
ngx_cp_async_send_single_body_chunk_nonblocking):

    offset = start;
    do {
        piece = min(size - offset, PIECE);
        is_last = last_buf && offset + piece == size;
        send(pos + offset, piece, is_last);
        offset += piece;
    } while (offset < size);

`pieces P n last off` lists the (offset, length, is_last) triples that the loop sends
for a buffer of `n` bytes, starting at byte `off` (0 for a new buffer, the saved offset
when the sender resumes after backpressure).
-/

def pieces (P : Nat) (hP : 0 < P) (n : Nat) (last : Bool) (off : Nat) : List (Nat × Nat × Bool) :=
  let k := min (n - off) P
  (off, k, last && (off + k == n)) ::
    (if _h : off + k < n then pieces P hP n last (off + k) else [])
termination_by n - off
decreasing_by omega

/-- One unfolding step, with the piece length named. -/
theorem pieces_step (P : Nat) (hP : 0 < P) (n : Nat) (last : Bool) (off : Nat) :
    pieces P hP n last off =
      (off, min (n - off) P, last && (off + min (n - off) P == n)) ::
        (if off + min (n - off) P < n then pieces P hP n last (off + min (n - off) P) else []) := by
  rw [pieces]; simp only [dite_eq_ite]

/-- Induction on the bytes left: to prove `Q off`, assume `Q` for the next offset when
    there are bytes left. -/
theorem pieces_rec (P : Nat) (hP : 0 < P) (n : Nat) (Q : Nat → Prop)
    (step : ∀ off, (off + min (n - off) P < n → Q (off + min (n - off) P)) → Q off)
    (off : Nat) : Q off :=
  step off (fun _ => pieces_rec P hP n Q step (off + min (n - off) P))
termination_by n - off
decreasing_by omega

/-- The bytes that the pieces cover, in the order they are sent. -/
def covered (l : List (Nat × Nat × Bool)) : List Nat :=
  l.flatMap (fun x => List.range' x.1 x.2.1)

theorem pieces_ne_nil (P : Nat) (hP : 0 < P) (n : Nat) (last : Bool) (off : Nat) :
    pieces P hP n last off ≠ [] := by
  rw [pieces_step]; simp

/-- No piece is larger than `P` (32768 in the module, so a length fits in uint16). -/
theorem pieces_le (P : Nat) (hP : 0 < P) (n : Nat) (last : Bool) (off : Nat) :
    ∀ x ∈ pieces P hP n last off, x.2.1 ≤ P := by
  induction off using pieces_rec P hP n with
  | step off ih =>
    intro x hx
    rw [pieces_step] at hx
    rcases List.mem_cons.mp hx with rfl | hx
    · exact Nat.min_le_right _ _
    · by_cases h : off + min (n - off) P < n
      · simp only [h, ↓reduceIte] at hx; exact ih h x hx
      · simp only [h, ↓reduceIte] at hx; simp at hx

/-- Every byte from `off` to `n - 1` is sent exactly once, in order, and nothing else. -/
theorem pieces_cover (P : Nat) (hP : 0 < P) (n : Nat) (last : Bool) (off : Nat) :
    covered (pieces P hP n last off) = List.range' off (n - off) := by
  induction off using pieces_rec P hP n with
  | step off ih =>
    rw [pieces_step]
    simp only [covered, List.flatMap_cons] at *
    by_cases h : off + min (n - off) P < n
    · simp only [h, ↓reduceIte]; rw [ih h]
      generalize min (n - off) P = k at h ⊢
      have e : n - off = k + (n - (off + k)) := by omega
      rw [e, List.range'_append_1]
    · simp only [h, ↓reduceIte]
      have : min (n - off) P = n - off := by omega
      simp [this]

/-- The flags: every piece except the final one has is_last = false; the final one has
    is_last = last_buf. So the agent sees exactly one end-of-body marker for a last buffer
    and none otherwise. -/
theorem pieces_flags (P : Nat) (hP : 0 < P) (n : Nat) (last : Bool) (off : Nat) (hoff : off ≤ n) :
    (pieces P hP n last off).map (fun x => x.2.2) =
      List.replicate ((pieces P hP n last off).length - 1) false ++ [last] := by
  induction off using pieces_rec P hP n with
  | step off ih =>
    rw [pieces_step]
    by_cases h : off + min (n - off) P < n
    · simp only [h, ↓reduceIte]
      have hne : (off + min (n - off) P == n) = false := by simp; omega
      simp only [List.map_cons, List.length_cons, hne, Bool.and_false]
      rw [ih h (by omega)]
      obtain ⟨m, hm⟩ : ∃ m, (pieces P hP n last (off + min (n - off) P)).length = m + 1 := by
        cases hp : pieces P hP n last (off + min (n - off) P) with
        | nil => exact absurd hp (pieces_ne_nil _ _ _ _ _)
        | cons a t => exact ⟨t.length, by simp⟩
      rw [hm]; simp [List.replicate_succ]
    · simp only [h, ↓reduceIte]
      have heq : (off + min (n - off) P == n) = true := by simp; omega
      simp [heq]

/-- The module's piece size leaves room for the IPC header: uint16 lengths, message cap 0xfffc. -/
theorem piece_size_fits : (32768 : Nat) + 16 ≤ 0xfffc := by decide

/-- A concrete check: a 100000-byte last buffer becomes 4 pieces with one end marker. -/
example : (pieces 32768 (by decide) 100000 true 0).map (fun x => x.2.1) = [32768, 32768, 32768, 1696] := by
  simp [pieces_step]
