# Write verbs: intent at the call site

Campaign note, REVISION 2 — Chris's idea 2026-08-29, drafted by CC, reviewed
by Claude Chat the same day, review folded in by CC. §5 is now the short list
that needs Chris's voice; §6 is what was proposed, seconded, and will proceed
unless overruled. §7 is the ledger of rejects.

Changed in this revision, all from the review:

- **The `hold` split** (the review's one argued-for change, seconded by CC):
  blend mode and lifetime were bundled in `set`-as-assign; they are
  orthogonal. `set` keeps today's meaning everywhere; the seat gets its own
  verb. This deletes the old §5.2 compat question outright.
- Additive contributions pinned as **per-statement LEVELS**, not deltas.
- Rulings added for clamp placement, glide interaction, per-lane non-finite,
  mount-time acceptance refusal, the `mod/` write spelling, console
  retraction (`clear`), and the order-permute gate.

---

## 1. The itch

rill programs mutate the engine through one verb, `set`. What `set` actually
*does* depends on what the target path turns out to be:

| target | what `set` means there |
|---|---|
| a routed knob, from the console | write the **authored** value (the person's number) |
| a routed knob, from a program | contribute to the knob's **modulation lane**, in a blend mode the *registry* chose (`add`, `mul`, or `stops` — one per knob, fixed at compile time) |
| one of a hardcoded list of "additive intent" paths (`camera/thrust/*`, `camera/torque/*`) | join a **sum** across programs, keyed by program id |
| an input control (`input/kbd/w`) | queue a **drive** on the device bridge |
| anything else in the dynamic namespace | **replace** the stored value |

Five semantics, one spelling. The writer's intent is invisible at the write
site; you have to know the path's class — and in the lane case, go read a
registry column — to know what your own line does. This is precisely the
"rule you cannot see at the call site" shape this codebase keeps evicting
elsewhere.

Chris's framing (2026-08-29): the system is not Bitwig. Bitwig-style
modulators orbit an authored value and never own it — that's our lanes, and
lanes are *right* for modulation. But **it is perfectly fine to set
something, if that is what you want. It's a matter of intent.**

**The ruling being proposed: the blend mode moves into the verb.** The
program says what it means — and separately, the *lifetime* of what it said
is carried by the verb too.

## 2. One week's evidence

Three real bites from the current campaign week, each dissolved by verbs:

**The additive-path table.** `camera/thrust/*` summing across programs is a
hardcoded engine list (`ADDITIVE_PATHS`). Whether your write sums or
replaces depends on membership in a table you cannot see from the rill. With
an additive verb, "whoever writes additively joins a sum" — the table stops
existing.

**The replace-vs-sum surprise.** Intent sums are keyed by *program* id: two
programs writing torque compose, but two *statements* in one program share
an id, so the second silently replaces the first. rail.rill v1's mouse-look
line (writing zero with the button up) erased its own aim line this way.
Under per-statement levels (§3.4) that line becomes *correct behavior*.

**The camera seat hack.** rail.rill v2 needed to *own* the camera. There was
no way to say that, so it got a bespoke seam (`camera/pose/pos|look`) and a
bespoke unmount line that vacates it, with a stated edge (any unmount
vacates, even an unrelated program's). Under `hold` (§3.2) the lifecycle is
in the word and the special case is deleted.

The verb taxonomy already quietly began: `set`, `inc` (accumulate delta),
and `cast` (field deposit) are three write verbs with three semantics. This
campaign finishes the thought. The docs kinship line, per the review:
*`inc` changes the number; `nudge` leans on it.*

## 3. The design

### 3.1 The verb families

Six verbs, two of them existing (final names are §5.1; additive/stops names
are placeholders):

| verb | intent | rests at | lifetime |
|---|---|---|---|
| `set` | durable replace — **exactly today's meaning, from every mouth** | — | outlives the writer |
| `hold` | *the seat*: this value while I stand here | — | **retracts on unmount** — a hold that persists after you leave isn't a hold |
| `nudge`* | join a sum | 0 | contribution retracts on unmount |
| `scale` | fold into a product | 1 | retracts on unmount |
| `stops`* | photographic stops: `× 2^clamp(s, −8, +8)` | 0 | retracts on unmount |
| `clear` | withdraw *my* contribution from this target's lane, whatever its mode | — | immediate |

The `hold` split (review's argument, seconded): the draft bundled blend mode
(*replace the base*) and lifetime (*retract on unmount*) into one verb, which
both created a compat audit for every durable `set` site and quietly made
`set` mean different things from the console and program mouths. Split, the
table is clean:

- console `set` on a knob → authored (unchanged)
- program `set` on a knob → **refused, and the refusal names `hold`**
  (authored is the person's; authored-survives is non-negotiable)
- program `hold` on a knob → the assign lane (the camera seat, generalized)
- program `set` on a dynamic path → today's durable replace (`draw/*`
  overlays keep working; no audit needed)
- program `hold` on a dynamic path → replace-with-retraction, for every site
  where outliving the writer *was* the bug

### 3.2 One machinery: everything is a lane

A target may carry **one lane per mode simultaneously**; the combine order
is fixed:

```
base  = held value (last holder in owner order)  |  else authored
live  = clamp_knob_range( (base + Σ nudges) × Π scales × 2^clamp(Σ stops, −8, +8) )
```

- **`hold` replaces only the base.** Modulation rides on top: a kick still
  shakes a railed camera. Assign just swaps whose value the modulators
  orbit — the Bitwig story survives intact.
- **The knob's range clamp applies to the final live value**, after the
  whole fold — the existing "clamp is the knob's range" ruling, said here
  because the fold grew.
- **`hold` bypasses the glide.** `live` is `glided ∘ lanes`; a held base
  does not ease in — "position assigned outright" was the entire point of
  the hard rail, and *easing is spellable in the language*: a program that
  wants a soft seat handoff writes `| ease 300ms` before its `hold`. The
  engine seam stays hard; softness is the author's sentence, not the
  engine's habit. (CC's recommendation, sharpening the review's "might need
  to be per-verb".)
- **Non-finite is per-lane, loudly.** A NaN aggregate in the scale lane
  makes that lane its identity and says so; the other lanes still apply.
  Smaller blast radius than whole-read fallback (review's recommendation,
  seconded).
- Standing invariants carried over unchanged, load-bearing for replay and
  frozen-reference bit-identity: **owner-order folds** (never allocation
  address), **main-thread lanes, debug-asserted**, empty lanes cost
  nothing, an unmodulated frame is bit-identical.

### 3.3 Acceptance is a mount-time contract

The registry's `modulation` column becomes a **mask of accepted modes**. A
write in an unaccepted mode is refused **at mount**, naming the accepted
modes — write targets are static paths in statements, so the wire gate can
walk this the way it walks types, and nothing refuses at runtime. Default
mask: today's column maps to "accepts exactly that mode"; `hold` accepted
nowhere until ruled per-namespace (`camera/pose/*` migrates first).

### 3.4 Additive contributions are per-statement LEVELS

Keyed per **statement**, and a contribution is **a level the statement
maintains, not a delta per firing** — latest value per statement wins,
statements sum across each other. Both halves matter (review's pin): level
semantics is what makes rail-v1's mouse-look line (writing 0 with the
button up) *correct* rather than hazardous, keeps `nudge` cleanly distinct
from `inc`, and matches the cross-tick coalesce ruling on casts. Without
that sentence someone implements per-firing accumulation and the bug
returns in a new costume.

Statement identity = index within the file: stable for replay (replay
re-derives from identical text), and an edited remount rebuilds all
contributions anyway since they retract at unmount. Fold order becomes
(owner order, then statement order), both deterministic.

### 3.5 The `mod/` write spelling is deleted; the read view grows

Verb + bare path now carries the mode, so the `mod/<knob>` *write* seam is
the evicted overload reborn — deleted in the migration pass. The `mod/`
*read* view stays and grows: `probe` shows per-mode aggregates and
contributor counts. Three views unchanged as a read contract: bare =
authored, `mod/` = the lanes, `live/` = what the frame used.

### 3.6 The console speaks the same verbs

One vocabulary, two mouths. Console `set` on a knob writes authored (the
console is the person — and under the `hold` split that is no longer a
special case, it is just what `set` means). Console modulation verbs
contribute under the console's own id; the person withdraws with `clear`,
which exists precisely so nobody needs to know a mode's identity value to
leave a lane. Console `hold` is legal and released by `clear` — useful for
pinning a value while investigating.

## 4. What this is not

- Not a change to reads, probe's reply shape, replay format, or the
  three-views read contract.
- Not a scheduling change: drain, slew, and publish points stay put.
- Not Bitwig: modulators stay modulators. This adds the owner's verbs
  beside them and makes every write say which it is.

## 5. Open rulings — what needs Chris's voice

1. **Names.** The grammar fact stands: `add` and `mul` are operators, and
   `| add plane.x` is already live-reference arithmetic. On the table:
   - *additive*: `nudge` (review: reads small — WASD thrust at full
     throttle isn't a nudge), `bias` (the codebase already calls this
     concept bias, but verb/path adjacency with `camera/bias/*` may
     refuse), `offset` (honest, flat), `sum`, `push`.
   - *multiplicative*: `scale` (probably safe; `gain` collides with the
     emitter field).
   - *stops*: `stops` (reads badly aloud as a verb) vs `ev` (photographic,
     reads well: `ev plane.render.grade.exposure 1`, but opaque to
     no-priors readers).
   - *seat*: `hold` (both reviewers like it). *withdraw*: `clear`.
2. **Confirm the `hold` split** (§3.1) — argued by the review, seconded by
   CC, but it is a shape change from the idea as first spoken.
3. **Confirm `hold` bypasses the glide** (§3.2) — CC's recommendation;
   the alternative is per-verb easing in the engine.
4. **Confirm per-statement levels** (§3.4) — this changes the composition
   story *within* a file from "composing is the author's job" to "every
   statement is a contributor".
5. **`hold` acceptance map** — which namespaces admit a seat first.
   Proposed: `camera/pose/*` (migrating the bespoke seam), nothing else
   until asked for.

## 6. Proposed and seconded — proceeding unless overruled

Mount-time acceptance refusals (§3.3) · per-lane non-finite (§3.2) · the
`mod/` write deletion (§3.5) · `clear` and console vocabulary (§3.6) ·
range clamp after the full fold (§3.2) · honest migration, no compat shims:
camera.rill thrust → additive verb, rail.rill pose → `hold` (its bespoke
unmount line deleted), `ADDITIVE_PATHS` deleted, `draw/*` untouched ·
`inc`/`cast` stay as they are, kinship documented.

## 7. Ledger of rejects

- `add`/`mul` as verb names — operator collision (grammar fact, not taste).
- One verb carrying both assign-blend and retract-lifetime — orthogonal
  axes; bundling recreated the two-mouths overload and forced a compat
  audit of every durable `set` (review round, 2026-08-29).
- Per-firing additive accumulation — resurrects the replace-vs-sum bug in a
  new costume; levels or nothing.
- Whole-read non-finite fallback — larger blast radius than per-lane, and
  punishes three well-behaved lanes for one rogue writer.
- Runtime acceptance refusals — mount-time is house style and statically
  checkable here.

## 8. Sizing sketch (orientation, not ruling)

- **rill repo:** the new terminal verbs in the grammar (same shape as
  `set`), registry rows, mount-time acceptance in the wire gate, refusal
  messages. Small.
- **engine:** lane storage keyed (target, mode); intent-sum machinery
  merges into it; `laneDropOwner` retraction extends to `hold` and
  per-statement keys; `camera/pose/*` migrates onto the seat. Medium — the
  campaign's center of mass.
- **gates:** every ruling paid in the usual coin, and specifically — per
  the review — an **order-permute gate**: construct a target where
  `(base + Σ) × Π × 2^s` differs numerically from other orderings and
  assert the documented one. A gate that passes because the lanes are
  empty is watching nothing. Plus the standing frozen-reference sweep.

---

*Fate of the note: becomes a CC brief once §5 is ruled; the brief tracks
what lands.*
