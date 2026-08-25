# Note for CC — rulings from the casts conversation (2026-08-25)

Context you don't have: after your recon on `rill-casts.md`, Chris and Claude
Chat went through the campaign plan, your three pins and the fork. It produced
four rulings, two grammar pins, a sequencing decision and one retired section.
Everything marked **stamped** is Chris's; the rest is advised and says so. This
note is the full record — nothing else in the doc moved.

Beat 1 is go, conditional on the grammar in §1 and the doc amendments in §7
landing in the same commit.

---

## 1. Grammar for `cast` (stamped)

`cast` joins the sink family as `inc`'s kin (accumulate family, §6), with the
§3.8 sink shape unchanged: port 0 is the rousing; a bound `value` port is the
payload. Channel and radius are statics. Two additions:

- **`at <pos>` is a port**, bound or live. A body-bound caster reads its own
  instance position; a supervisor casts at any position it can read. Casting in
  several places from one rousing is two `also` branches — no list argument.
  Dot-form is a live reference, so a moving caster's position updates without
  re-rousing (§3.8: a change in payload alone is not a write).
- **`decay <duration>`**, optional, using the ratified duration grammar
  (`5s` / `250ms` / `3f`) as a time constant. Defaults from the channel
  declaration (§7). See §3 below for why this is on the cast at all.

```
every 1f { cast $torchlight 0.8 radius 12 at s.brazier.pos decay 4s }

s.gate.enemy_count | rose_above 0
  | also { cast $alarm 1.0 radius 30 at s.gate.pos decay 2s }
  | also { cast $alarm 1.0 radius 30 at s.tower.pos decay 2s }
```

Consequence to pin in the doc: unpiped, the intensity binds port 0 and is both
rousing and payload, so a bare `cast $torchlight 0.8 radius 12 at …` deposits
**once, at tick 0**, then leaks away. A standing caster needs a per-tick
rousing in front of it — `every 1f` (§4). This will surprise the first person
who writes a brazier; say it where the grammar is introduced.

`to #tag` (coupling, §8) parses when the tag store exists — see §6.

## 2. Ruling — an owned space is a bag of deposits (stamped)

Once a cast has a position, a caster's owned space (§4.1) is no longer one
kernel at the caster's position. It is a **bag of deposits**, each
`{pos, amplitude, radius, decay, born}`. The receiver sums the live deposits in
range. Two things fall out:

- A brazier depositing per tick at a fixed position coalesces into one growing
  bump (same `pos`, `radius`, `decay` within a tick ⇒ amplitudes sum — the
  accumulate rule), reaching steady state where feed equals leak.
- A screaming raider running through the courtyard leaves a trail of bumps
  that leak independently. A scream lingers where it was screamed.

Pins:

- **Coalescing:** within a tick, deposits from one caster with identical
  `(pos, radius, decay)` sum their amplitude; otherwise they are distinct
  deposits. Net-zero silenced, as for `inc`.
- **Summation order:** receiver sums casters in stable caster-id order
  (caster-id derived from mount order, not allocation), and deposits within a
  caster in `born` order. §4.1 pin 1 survives; replay bit-identity depends on
  it.
- **Bound named in the ledger, no mechanism:** a bag is bounded by deposit
  rate × decay time; deposits below the channel's epsilon are culled. If a
  scene runs away, the error budget is the guard — same sentence as the
  rounds bound.

## 3. Ruling — decay is per-deposit runtime physics; §5 is retired (stamped)

§5 ("decay is a rill first") cannot be built as written. Its sketch

```
$blight | mul -0.1 | cast $blight
```

reads a path it writes, and §4.4 refuses exactly that. The sentence "legal for
the same reason counters are" is wrong: `inc` passes the cycle ban because it
is *blind* — no read — and this rill reads. Your pin 1 (bare `$blight` reads
the caster's own space) had the right semantics for a leak — each caster
drains only its own deposits, so the rate doesn't scale with caster count —
but that makes the read and the write the same path, which is the cycle. The
§4.4 delay operator that would license deliberate feedback doesn't exist, and
even with it, an exponential never reaches zero, so a decay rill re-rouses
every tick on every caster forever.

**Ruling:** decay lives on the deposit (§1's `decay` port, defaulting from the
channel). The runtime leaks each bump in fed time and culls below epsilon.
This is §7's "eventually intrinsic decay" arriving before the rill version was
ever built — a reversal of the original ruling, made because the cycle ban
forced it, and the doc says so in one sentence rather than swapping quietly.

**F3 restated:** an un-fed deposit drops below the channel epsilon within the
declared time constant and is culled; a deposit fed by `every 1f` reaches
steady state. Deterministic in fed time; replay byte-identical. The mutation:
skip the cull and watch the bag grow.

Corollary (advised, stamp pending): with decay in the runtime, no rill has a
reason to read its own space. **Don't build the bare `$channel` read inside a
rill in v1.** Every reading comes from a standpoint — `@tom.$dread`,
`sensors/gate/$alarm` — exactly as §9 already rules. This keeps the cycle
checker out of the field store entirely.

## 4. Ruling — both terminations compose (stamped)

Ownership (§4.1) is the ceiling; decay works inside it. Unmount the caster and
the whole bag goes, whatever each deposit's remaining life. §4.1 pin 3 ("a
scream dies with the screamer") survives unchanged — and the case where sound
should outlive its source now has the authorable spelling the doc promised:
Tom's death occurrence reaches a longer-lived supervisor, which casts
`$dread … at <tom's last pos> decay 3s`. F7 is unchanged: unmount moves the
aggregate, the threshold occurrence fires from the removal.

## 5. Ruling — `every <duration>` and the general block rule (stamped)

Two parser items, both parse-time:

1. **`every <duration>`** is a new temporal *source* op: wheel-driven, emits
   an occurrence on cadence, takes no input, consumes fed time like the rest
   of §3.12. Unskippable (it is an occurrence-emitter).
2. **The `also` block rule generalises to any occurrence source.**
   `also { S }` was always "a name with a block whose implicit source is that
   name"; `also`'s name is the in-flowing value. The same desugar applies to a
   source:

   ```
   every 1f { S }        ⇒        every 1f as ⟨anon⟩
                                  ⟨anon⟩ | S
   ```

   Multi-statement blocks become multiple branches off the same anon name.
   The explicit pipe form `every 1f | cast …` stays legal — the block is
   sugar, the pipe is the truth, as with `also`. All `also` rules carry over
   unchanged: no `as` escapes, writes join the flatten write-list, discard
   warning on an unconsumed tail.

Add to §0 as **unlearn #6 — a block is a fan-out, not a body.** `every 1f { }`
is the most loop-shaped thing rill has, and readers will put ordered steps in
it. Statements in a block are branches: no order between them, each ends in
a sink or produces a consumed value. If someone needs sequence inside an
`every`, they wanted a pipeline, and the pipeline is the spelling.

## 6. Sequencing — the fork is a beat order, not a fork (Chris's lean; confirm before starting)

F4 (coupling) and F5 (derived tags) are the tag store's first two customers,
and R6's `@` row is the third. That is the argument for tags getting **its
own beat with its own gates** rather than riding inside the fields campaign.
So: land F1/F2/F3/F6/F7 first, record F4/F5 as deferred with a pointer (not
dropped), then the minimal `tags/**` row as the next beat — same day if it
fits, but not interleaved commits. The fields campaign stays closeable on its
own.

## 7. Your pins, resolved

- **Pin 1** (bare `$blight` reads own space) — superseded by §3's corollary;
  no read side in v1.
- **Pin 2** (`cast_fn` beside `write_fn`, not a `DeltaKind`) — accepted. One
  sentence to add: casts commit through the main-thread drain so program-write
  ordering is deterministic, but per §11 **fields stay out of the log**; rill
  writes replay by re-derivation anyway. Drain yes, log no.
- **Pin 3** (`at x y z` or archetype placement) — superseded by §1's `at`
  port. No literal coordinates in rill text; a body-bound caster reads its
  instance position, a supervisor reads whatever it casts at.

## 8. Doc amendments to land with beat 1

- §5 rewritten per §3 above, reason stated.
- §6 grammar pinned per §1 (replaces the sketch).
- §4.1 gains the bag-of-deposits model and the coalescing/order/bound pins.
- §0 gains unlearn #6.
- §12: remove "decay promoted to channel physics" (done); add "hard lifetime
  `for <duration>` — a step rather than a leak — deferred until a scene wants
  a pulse that holds and drops."
- §13: F3 restated per §3.
- `rill-spec.md`: §3.8 gains `cast`; §3.12 gains `every`; block rule stated
  once beside `also`.

## 9. Standing checks for the campaign

- Channels are spine tenants; a channel must be declared **before** any
  caster rill mounts, or tick 0 goes loud. Make that the first thing beat 2
  tests.
- F-gates are executed programs, not prose — the garrison discipline.
- When a field value surprises, suspect the instrument first.

## 10. Landing order

1. Beat 1: `$` sigil; `cast` with `at`/`decay` ports; `every`; block rule
   generalised; §7/§8 doc amendments in the same commit.
2. Beat 2: `fields.zig` (instrument, plane-free) + bridge; channels as the
   8th tenant with epsilon + default decay in the declaration; bag of
   deposits; receiver-side sum; ear sensors publishing value + gradient.
   Gates F1, F2, F3 (restated), F6.
3. Beat 3: F7 deletion housework.
4. Spec parity + ratification stamp; the two manuals; rillbook.
5. Then, as its own beat: minimal `tags/**` row, F4, F5, R6 `@` row.

The tiltyard brazier is the through-line: one `every 1f { cast … }` at a
fixed position, one relic casting negative `$blight`, and a lamp rill dimming
as the camera walks into the dark — every ruling above exercised in three
lines.
