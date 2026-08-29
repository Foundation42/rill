# Write verbs: intent at the call site

Campaign note, DRAFT — Chris's idea, drafted by CC, 2026-08-29. Bound for a
second pair of eyes (Claude Chat), then back for rulings. Nothing below is
ruled unless it says so; §5 is the list of decisions the design needs.

This note is self-contained on purpose: the reviewer has no codebase access,
so the standing machinery it touches is described inline.

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
something, if that is what you want. It's a matter of intent.** Right now
`set` is overloaded to carry every intent, and it shows.

**The ruling being proposed: the blend mode moves into the verb.** The
program says what it means — assign, add, scale, stops — and the target
declares what it accepts, instead of deciding on the writer's behalf.

## 2. One week's evidence

Three real bites from the current campaign week, each dissolved by verbs:

**The additive-path table.** `camera/thrust/*` summing across programs is
implemented as a hardcoded list (`ADDITIVE_PATHS`) in the engine. Whether
your write sums or replaces depends on membership in a table you cannot see
from the rill. With an additive verb, "whoever writes additively joins a
sum" — the table stops existing.

**The replace-vs-sum surprise.** Intent sums are keyed by *program* id: two
programs writing torque compose, but two *statements* in one program share
an id, so the second silently replaces the first. rail.rill v1's mouse-look
line (writing zero with the button up) erased its own aim line this way —
the camera never turned, and the rule had to be learned from a trace.
Verbs make the composition rule statable per-verb instead of emergent.

**The camera seat hack.** rail.rill v2 needed to *own* the camera (hard
rail: position assigned outright). There was no way to say that, so it got a
bespoke seam (`camera/pose/pos|look`) — and because plain dynamic writes
outlive their writer, a bespoke line in unmount that vacates the seat, with
a stated edge case (any unmount vacates, even an unrelated program's). If
program-assignment is a *verb* with ownership semantics — "assigned while I
am mounted, retracted when I go" — that lifecycle falls out of the
semantics, per writer, no special cases.

Also worth noticing: the verb taxonomy already quietly began. `set`, `inc`
(accumulate: add *to* a stored number as a delta kind), and `cast` (deposit
into a spatial field) are already three write verbs with three delta
semantics. This campaign finishes the thought.

## 3. The proposed design

### 3.1 The verb families

Four write intents (names are open — see §5.1; placeholders used here):

- **`set`** — *assign*. "This value, because I say so." Last-owner-wins
  while held; **retracts when the writer unmounts**. The owner's verb.
- **`nudge`** — *additive*. Joins a sum with every other additive writer.
  Rests at 0; a contribution retracts on unmount.
- **`scale`** — *multiplicative*. Folds into a product. Rests at 1.
- **`stops`** — *exposure algebra*. Photographic stops: the aggregate `s`
  applies as `× 2^clamp(s, −8, +8)`. Rests at 0.

### 3.2 One machinery: everything is a lane

Today a routed knob has at most one lane, in the registry's one mode, and
the value read by the frame is `authored ∘ lane`. The generalization: a
target may carry **one lane per mode simultaneously**, and the combine order
is fixed:

```
value = ( (assigned  if an assign-lane is held, else authored)
          + Σ nudge-contributions )
        × Π scale-contributions
        × 2^clamp(Σ stops, −8, +8)
```

Assignment is then not a special case but a fourth lane mode — a "replace
lane" whose fold is last-owner-wins. **The authored value survives
underneath every mode, including assign**: no program verb ever writes the
store, so unmounting everything always reveals the person's number again.
(This is the standing "three views" contract: a bare read is authored,
`mod/<path>` is the lane, `live/<path>` is what the frame used. Verbs extend
the middle view; the outer two are untouched.)

Standing invariants that carry over unchanged, because they are load-bearing
for replay and frozen-reference bit-identity:

- contributions fold in **owner order** (mount order, never allocation
  address) — float addition is not associative;
- lanes are **main-thread-only**, debug-asserted;
- a non-finite aggregate is **ignored, loudly** (the current lane rule);
- an empty lane costs nothing; an unmodulated frame is bit-identical.

### 3.3 The registry column becomes an acceptance policy

Today `KnobDef.modulation` *chooses* the one mode. Under verbs it becomes a
*mask* of accepted modes ("exposure accepts nudge and stops; tonemap-mode
accepts nothing; camera pose accepts assign"). A write in an unaccepted mode
is a **refusal that names the accepted modes** — the loud-refusal house
style.

### 3.4 Dynamic paths and the console

Non-knob dynamic paths take the same verbs: `set` is today's replace (plus
retract-on-unmount ownership — see §5.2 for the compat question), `nudge`
on any numeric path generalizes the intent-sum machinery, and
`camera/thrust/*` becomes nothing but a path people happen to `nudge`.

The console speaks the same verbs as programs — one vocabulary, two mouths.
(Console `set` on a knob keeps writing authored: the console is the person.)

## 4. What this is not

- Not a change to reads, probe, replay format, or the three-views contract.
- Not a scheduling change: drain, slew, and publish points stay put.
- Not Bitwig: modulators stay modulators. This *adds* the owner's verb
  beside them and makes each one say which it is.

## 5. Open rulings (the reviewer should poke at these)

1. **Names.** `add` and `mul` are unavailable — they are elementwise
   *operators*, and a path in argument position is a live reference, so
   `| add plane.x` is already arithmetic today. Candidates: `nudge` /
   `offset` / `sum` for additive; `scale` / `gain` for multiplicative;
   `stops` reads well as itself. `set` stays the assign verb.
2. **Program `set` on a routed knob** — refused (today's rule) or admitted
   as the assign-lane? Draft recommends: admitted. It is the camera-seat
   need, generalized, and authored survives underneath. Also: does plain
   dynamic-path `set` gain retract-on-unmount, and is that a compat break
   anything relies on (e.g. `draw/*` overlays currently outliving their
   writer — arguably a bug, but a visible one)?
3. **Sum granularity.** Additive contributions keyed per *statement* (each
   line is a contributor — kills the rail-v1 bite outright) or per
   *program* (today's rule: within a file, composing is the author's job)?
   Per-statement needs stable statement identity for replay's fold order —
   statement index within the file is stable across remounts of identical
   text; is that stable enough?
4. **Combine order.** Is `(assign|authored + nudges) × scales × 2^stops`
   the right fixed order, and is assign-beats-authored-plus-nudges right —
   or should assign suppress the *other* lanes too? (Draft recommends:
   assign replaces only the base; modulation still applies on top. A kick
   should still shake a railed camera.)
5. **Acceptance defaults.** Which knobs accept which modes out of the box?
   Cheapest honest default: current `modulation` column maps to "accepts
   exactly that mode", assign accepted nowhere until ruled per-namespace.
6. **`inc` and `cast`.** Fold `inc` into the additive family, or leave both
   as-is (they are delta *kinds*, not lane modes)? Draft recommends: leave,
   note the kinship in docs.
7. **Migration.** Shipped rills all say `set`. Rewrite them honestly
   (camera.rill thrust → additive verb; rail.rill pose stays `set` and
   *gains* proper seat semantics; ADDITIVE_PATHS deleted) rather than
   compat-shim? The codebase is young; draft recommends yes.

## 6. Sizing sketch (for orientation, not ruling)

- **rill repo:** four terminal verbs in the grammar (same shape as `set`),
  registry rows, refusal messages. Small.
- **engine:** lane storage keyed (target, mode) instead of one-per-knob;
  intent-sum machinery merges into it; unmount retraction already exists
  (`laneDropOwner`) and extends to the assign mode. Medium — this is the
  campaign's center of mass.
- **gates:** every ruling above paid in the usual coin, plus the standing
  frozen-reference sweep (unmodulated frames bit-identical before/after).

---

*Fate of the note: like `modulation-lanes-campaign.md`, this becomes a CC
brief once ruled, and the brief tracks what lands.*
