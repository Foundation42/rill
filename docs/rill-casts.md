# Casts, Fields, and the `$` Sigil

**Status:** draft for ratification — Chris + Claude, 2026-08-26.
**Scope:** closes the two gaps found by the external review of `ironwood.md`
(relative targeting; cross-instance interaction), introduces the fourth
sigil, and pins the field model. Extends `rill-agents.md` and Ironwood
R6; feeds R2.

**Origin.** The document was reviewed externally with rill's language
surface deliberately withheld — a probe of what a competent reader's
intuition supplies when given only the ontology and the scenario. The
reviewer reconstructed the sigil grammar correctly, located one genuine
gap (relative targeting), asked one genuinely open question
(cross-instance interaction), and guessed wrong about the language in
three consistent ways. All four results are used here.

**Probe method, kept.** A second round — this draft shown to the same
reviewer — measured transfer: §0's first three lines were absorbed (no
`if` appeared; the attack correctly routed intent → engine → occurrence),
and the remaining confabulations moved to the *unpinned* regions of the
spec. Two laws worth keeping: **round one of a no-priors probe finds
where intuition fights the paradigm; round two finds where the spec is
silent**, because a fluent reader invents syntax only where no ruling
exists. Round two's inventions, triaged: the `->` exec-arrow (now
unlearn #4), engine-maintained derived tags (§10 already rules
otherwise — the maintainer is authored), tag writes inside a value
pipeline (effects are sinks; side branches ride `also { }`), and
per-entity sensors (now ruled in §9). Channel/derive declaration
syntax remains legitimately unpinned — a build-time item behind the
spine's completeness gates.

---

## 0. What to unlearn

The probe showed a sharp reader's intuition invents the wrong language
in three specific places. Any introduction to rill should say these
early, because readers will not notice they are assuming otherwise:

1. **No `if`.** There are no exec-pins and no imperative blocks.
   Conditions flow: `where`, `select`, `partition`, thresholds.
2. **No revocation.** Capabilities are static — checked once, at
   mount, granted as a struple. Authority does not change while the
   world runs. The gate stays shut under alarm because a rill reads
   the alarm and flows 0 to the winch, not because anyone's write
   licence was stripped mid-raid.
3. **No lingering state standing in for events.** Absence is said.
   Death is an occurrence carrying its own record; the corpse is
   removed, not cached.
4. **No arrows.** A threshold is a value that flows onward, not a
   trigger that fires a command. Probe round two showed the
   imperative prior surviving the `if` ban by reincarnating as
   `condition -> do_thing`; there is no `->`. Effects are sinks
   (`set`, `notify`, `tag`, `cast`) reached by flow, and side
   branches ride `also { }` — never the main stream.

All four misses point the same direction — toward mutable shared
state and imperative control flow. That is the direction the language
was designed against, and the distance between the intuitive guess and
the actual design is the design.

---

## 1. Relative targeting (ruled)

**Question:** "attack the closest raider to my position" — nearest-X
is observer-relative, and rills must not run spatial loops.

**Ruling.** Nearest-X is geometry, so it is sensor output. Every post
already publishes `nearest_distance`; the extension is publishing
`nearest` as an `@id` beside it. Per-observer relativity comes free
because sensors are already per-post: `sensors/tower/nearest` and
`sensors/gate/nearest` are different answers from different
standpoints, which is what "relative" means. A soldier's "my nearest
threat" is his own (or his squad's) sensor speaking.

**Rejected:** proxy tags (`#focused-target`). "Closest to the tower"
is a fact about the tower–raider *pair*, not about the raider. Tags
answer "what is true of it"; an observer-relative fact in the tag
store is the wrong row, fights between squads, and fills the store
with facts that are not facts about the entity.

**Pins:**
- A sensor's `nearest` field updates on the sensor's declared cadence
  like every other digest field. **It is a reading, not a lock.** A
  dead target is not the sensor's problem mid-scan; the next scan
  reports the new nearest, and the interval between is covered by the
  despawn occurrence (R6 death certificates, already ruled).
- **Observer-free aggregations** (`!count`; later any/all) may live in
  set algebra. **Observer-relative ones** (nearest, strongest,
  most-visible) must come from a sensor — they have no answer without
  a standpoint. This line stops the aggregator vocabulary from
  growing a spatial loop inside the evaluator.

---

## 2. Cross-instance interaction: the cast (ruled)

**Question:** how do two `@` instances act on each other?

**Ruling.** An instance never writes another instance's paths.
`@tom` does not `set @grimjaw.health` — that is mutable shared state,
and the capability system would have to enumerate every pairing.
Interaction is mediated, and the primary mediator is the **cast**:
properties emitted into space, absorbed by whatever is there to
absorb them. No addressee. A shout is a pressure field; you hear a
scream, not a name.

- **Signals** travel as casts (or, where a channel is overkill, as
  occurrences to a mailbox the receiver's own rills interpret).
- **Physical effects** — anything that changes a body — are R2
  *actions* the engine owns: the strike, the shove, the winch. Rills
  express intent; the engine resolves physics; occurrences report
  what happened. `@grimjaw.health` is written only by the system that
  owns bodies.
- **Anonymity is physics.** A cast carries no `@id` by construction.
  Identity travels only if the caster puts it in the payload —
  recognition is content, not envelope. Grants govern what you may
  *cast*, never whom you may reach, which deletes the pairwise
  capability matrix entirely.
- **The field carries intensity, never commands.** Meaning lives in
  the receiver: fear does not slow a soldier — the soldier's own
  rills read `$fear` and decide what it does to him. This line is
  load-bearing; without it, casts are remote `set` with extra steps.

---

## 3. The `$` sigil — the fourth row

Four sigils, four questions, four rows of the store:

| sigil | question             | row                          | mutability |
|-------|----------------------|------------------------------|------------|
| `@`   | which one            | instance registry            | spawn/despawn |
| `^`   | what kind            | archetype definitions        | immutable |
| `#`   | what's true of it    | tag store (radix prefix)     | per-tick membership |
| `$`   | what's in the air here | field store                | continuous, contributed |

`#` and `$` are the discrete and continuous halves of one idea: a tag
is a bit an entity carries; a field is a scalar the space carries.
`#in-courtyard` is membership; `$dankness 0.7` is atmosphere.

Named channels: `$blight`, `$alarm`, `$torchlight`, `$dread` — each a
scalar field over space, with multiple casters' contributions
blending by superposition.

**Reversal is arithmetic, not mechanism.** The blight caster
contributes +0.8 to `$blight`; the relic contributes −0.6 to the same
channel; contested ground reads 0.2 and the border where one holds the
other to zero is a contour line that moves when either strengthens. No
dispel verb, no effect-removal system, no priority rules. Fields add.

---

## 4. The field model: leaky integrator (ruled)

Two models were candidates:

- **Declarative:** field value = sum over currently active casters.
  Stop casting, contribution vanishes. Nothing persists; nothing
  decays.
- **Integrator:** casts are *deposits*; the field is accumulated
  state; decay drains it.

**Ruling: integrator.** Decided by the decay decision below — there
is nothing to decay in a pure sum. A field is a **leaky integrator
over space**: casts deposit, the leak is authored. This unifies pulse
and sustain with no second mechanism — a scream is one deposit, a
torch is a deposit per tick, the same leak drains both.

(The leaky integrator is already the house primitive — it is the
entire arithmetic fabric of the bitstream work. The differential
engineering does not merely support this model; it is this model.)

**Implementation at keep scale is analytic.** Field value at a point
is a sum over casters of `kernel(distance, radius, falloff)` — a
linear scan exactly like the contact cull. No grid, no rasterisation,
deterministic in fed time. Because the kernel is differentiable, the
**gradient is as cheap as the value** — which is what makes "the
garrison charges up the alarm gradient" and "flee down the fear
slope" real. Coordination without names.

---

## 5. Decay: a rill first (ruled)

**Ruling (Chris):** decay is authored as a rill initially. If patterns
recur, they may later be collapsed into runtime channel physics — the
same promotion pipeline as `def` → archetype, and the same discipline
as the sensor-budget knob (designed, recorded, not built until a
workload earns it).

Mechanical shape, for the implementer:

```
$blight | mul -0.1 | cast $blight
```

Read the sum, contribute the negative fraction — a self-loop with a
one-tick delay, i.e. discrete exponential decay, deterministic in fed
time. Legal for the same reason counters are: you read last tick's
sum and deposit into this tick's.

---

## 6. Writes: contribute-only (ruled)

Field writes are the **accumulate family** (`inc`'s kin). Nobody
`set`s a field; everyone *contributes* to it, positive or negative,
and the sum is the truth. Contributions commute per tick — no
ordering fights, mergeable by construction. The read-your-own-write
ban survives unchanged.

`cast` is the verb, available to instances and to rills alike (a rill
can be a caster). Grammar sketch, to be pinned at build time:

```
cast $blight 0.8 radius 12          # deposit: intensity + extent
cast $courage 0.5 radius 8 to #garrison    # coupled cast — see §8
```

---

## 7. Channels declared on the `^` spine (ruled)

`$blight` is declared before it is cast — default falloff, clamp
range, whether occlusion applies (a wall stops `$torchlight`; it does
not stop `$dread`), and eventually intrinsic decay if/when promoted
from rills. A channel is a *kind* of field, and kinds live on the
archetype spine — which puts channel declarations behind the spine's
comptime + runtime completeness gates, so a half-added channel is
refused the way a half-added tenant is.

The cast supplies intensity and extent; the channel supplies the
physics. Every physics question has one home.

---

## 8. Coupling: the filter lives at absorption (ruled)

The filter grammar goes symmetric. Sensors already take
`watch: ^raider & #hostile` on the intake side; casts take the same
set expression on the emission side — but the semantics are pinned as
**coupling at absorption, not addressing at emission**:

- The field is one field, really in space. The filter says who can
  *couple* to it. Resonance, not addressing.
- `cast $courage to #garrison`: garrison members have the receptor;
  others walk through the courage unwarmed.
- Anonymity survives: a *class* of receiver is not a name.
- Fiction dividend, free: a relic that grants `#attuned` does not
  create a field — it lets you perceive fields that were always
  there.

**Ruling: coupling starts binary** (tag = receptor, 0 or 1). Weighted
coupling is reserved, not built — reserve the mechanism, start with
the bit.

---

## 9. Reading: absorption is perception (ruled)

A rill never computes field values — it reads them, published for a
standpoint:

- `@tom.$dread` — the absorbed reading at Tom's position.
- `sensors/gate/$alarm` — an ear-post publishing a channel reading on
  its declared cadence, with the same digest/staleness/dwell
  machinery as sight. An "ear" is a sensor archetype whose scan
  samples channels instead of casting sight-lines; the fifth tenant
  already built is the template.

Published pair per reading: **value and gradient** — the gradient is
what movement wants. "Sensors report geometry; rills form beliefs"
survives with fields as one more thing geometry says.

**Per-entity sensors (ruled).** Probe round two assumed
`sensors/tom/nearest` — a sensor per soldier — without noticing the
assumption. The ruling: an entity has no implicit instrument. Eyes
are authored — a `^soldier-eyes` sensor archetype is legal and cheap
(the fifth-tenant machinery makes it a declaration, not a build), but
it is a choice the author makes, not a property entities carry by
existing. A soldier without authored eyes reads his squad's post.
Cost stays visible, and "who can perceive" remains part of a scene's
authored design rather than an ambient default.

---

## 10. Tag-casting and derived tags (ruled, with recorded indecision)

The trigger volume was a special case all along: a volume writing
`#in-courtyard` is a cast with binary absorption — field above
threshold ⇒ tag held, below ⇒ tag drops. Generalising buys non-box
regions, soft edges (hysteresis as two thresholds — the dwell's
spatial cousin), and overlapping regions composing by union, free.

This surfaces two tag lifetimes:

- **Edge-written** (R6 as ruled): written once, persists until
  removed. `#wounded` survives the soldier walking anywhere.
- **Level-asserted** (field-derived): held while the condition holds,
  re-derived each tick. `#in-courtyard` vanishes the moment he
  leaves.

**Ruling: one mechanism, and the maintainer owns removal.** A derived
tag is an ordinary tag whose maintainer is a field-threshold rule
instead of a rill; whoever maintains a tag is the party that removes
it. "Who removes this" becomes a property every tag answers, rather
than a question only some raise.

**Recorded indecision.** The alternative — two distinct tag kinds
with different lifetimes — was considered and not chosen. If building
reveals that two maintainers asserting the *same tag name* (a rill
writes `#alert`, a field also derives `#alert`) produces fights the
one-mechanism rule can't referee cleanly, that is the signal to
revisit. We expect to know better once it exists. Do not treat the
one-mechanism ruling as settled doctrine until it has survived a
build.

---

## 11. Replay

One sentence, already true by construction: casts originate from
transcript-visible sources (rill writes, actions, authored placements),
channel physics and decay rills run in fed time, so every field value
is re-derivable. **Fields stay out of the log entirely** — same
argument, same class, as sensor scans.

---

## 12. Deferred, with pointers

- **Weighted coupling** — reserved at §8; the binary receptor ships
  first.
- **Decay promoted to channel physics** — §5; promote only patterns
  that recur across authored scenes.
- **Occlusion-aware propagation** — the solver's
  `Metric.material_attenuation` is the committed-unimplemented arm
  ("how much of the scream survives the wall"); casts are its third
  customer after NEE and sight. Analytic kernels ship first.
- **Fields feeding the grade** — `$blight` tinting toward sickly
  green, `$torchlight` warming exposure: the Chromatope bridge. Noted
  here so the connection is on record; built when the game asks.
- **Tiltyard demo item** — a brazier casting `$torchlight`, a relic
  casting negative `$blight`, a rill dimming the lamp as the camera
  walks into the dark.

---

## 13. Proposed gates (F-series, to be pre-registered at build time)

- **F1 — superposition:** two casters on one channel; the reading
  between them equals the sum of both kernels, and removing either
  caster moves the contour accordingly.
- **F2 — reversal:** a negative caster holds a positive caster to
  zero along a contour; strengthen one, the contour moves. Asserted
  as values at three sample points, not as prose.
- **F3 — decay:** the decay rill drains an un-fed field to below
  threshold in the declared number of ticks; a fed field holds
  steady-state. Deterministic in fed time; replay byte-identical.
- **F4 — coupling:** a coupled cast reads as zero to an entity
  without the receptor tag and non-zero with it; granting the tag
  mid-run changes the reading on the next tick.
- **F5 — derived tags:** an entity crossing a field threshold gains
  the tag within one tick and loses it within one tick of leaving
  (plus hysteresis if declared); the maintainer's removal is the only
  removal.
- **F6 — gradient:** published gradient at a sample point matches the
  analytic derivative of the kernel sum (hand-computed expectation,
  per the S3.5 practice — derived on paper, not read off the code).

Each gate ships with a mutation that trips it, message in the
fiction's language, per house practice. A mutation that does not bite
is a finding about the gate.
