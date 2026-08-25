# Casts, Fields, and the `$` Sigil

**Status:** draft for ratification — Chris + Claude, 2026-08-26.
**Amended 2026-08-25** with the build-time rulings from
`cc-note-casts.md` (Chris + Claude Chat): §6 grammar pinned, §5
reversed to per-deposit runtime physics, §4.1 gains the
bag-of-deposits model, §0 gains unlearn #6, §13 F3 restated. Beat 1
(`$` sigil, `cast`, `every`, the generalised block rule) is BUILT in
rill core, same commit as these amendments. **Beats 2–3 BUILT
2026-08-25** (matryoshka): `fields.zig` (bag of deposits, receiver-side
sum, decay/cull in fed time), `casting.zig` (the bridge + the EarBank
sampler runtime), `chanarche` = the spine's 8th tenant (its first
archetype-only one), `eararche`/`ear` = the 9th (sampler doctrine — no
override mask, binding required); gates F1/F2/F3/F6/F7 all held with
biting mutations; F4/F5 await the tags beat. THE LOOP runs photonless:
cast → field → ear → rill → knob, every line console-sayable.
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

**Round three converged.** The arrow disappeared even where it hid
(`threshold | set` now flows to a sink); per-entity sensors gone; the
F7 walkthrough correctly extended the gate into the fiction. Two
residues persisted across rounds and were promoted accordingly:
effects-riding-the-stream became unlearn #5, and the thrice-repeated
"engine as maintainer" misreading earned §10 its
maintainer-is-authored clarification. A confabulation that survives
correction is not a reader error — it is the spec under-explaining,
and its persistence is the promotion criterion.

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
5. **Effects don't ride the stream.** A `tag`, `set`, `notify`, or
   `cast` is a sink — a wave ends there; nothing flows onward
   through an effect. A pipeline that "does something and
   continues" (`... | untag #off-duty | tag #active | follow ...`)
   is imperative sequencing wearing pipes. The branch to an effect
   rides `also { }`; the main stream carries values only. This
   survived two rounds of probe correction before earning its
   number — readers will write effect-pipelines until told in bold.
6. **A block is a fan-out, not a body** (added 2026-08-25, note §5).
   `every 1f { … }` is the most loop-shaped thing rill has, and
   readers will put ordered steps in it. Statements in a block are
   branches: no order between them, each ends in a sink or produces
   a consumed value. If someone needs sequence inside an `every`,
   they wanted a pipeline, and the pipeline is the spelling.

All five misses point the same direction — toward mutable shared
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

### 4.1 Ownership and the receiver-side sum (ruled)

**The cast volume is owned by the caster** — the rill (or prefab
group, if that becomes a thing) that casts it. Two rills casting
`$blight` each own their own space. There is no global accumulator
per channel.

Why this matters: a global accumulator has a corpse problem —
contributions merge irreversibly, so a deleted rill's blight lingers
with no owner to withdraw it. Dead Tom in field form. Ownership
follows lifetime instead: **unmount the caster and its space goes
with it.** Restart-not-resume for atmosphere — a remounted blight
rill does not inherit its corpse's miasma. Principle 8 arrives by
construction on this path: no certificate is needed for a vanished
contribution, because the receiver sums live casters, so the field
itself says the absence by dropping on the next sample.

The model, in engine terms: **a caster is an emitter; absorption is
shading.** Each light is an owned object; the shading point
integrates contributions from live emitters at sample time — nobody
maintains a merged accumulator that lights deposit into. The
receiver-side sum is the solver's Point→Emitters arm wearing a
channel instead of radiance, and occlusion-aware propagation
(`material_attenuation`, §12) slots in per-caster exactly as NEE does
per-light.

The leaky integrator (§4) relocates rather than dissolves: it lives
*inside each owned space* — a caster's volume integrates that
caster's deposits and leaks — and the **canonical value at a point is
the receiver-side sum over live spaces**. Pulse and sustain still
unify; F1/F2 still hold (they assert values at sample points, which
was receiver-side all along).

**An owned space is a bag of deposits (stamped 2026-08-25, note §2).**
Once a cast carries a position (§6's `at` port), a caster's space is
no longer one kernel at the caster's position: it is a bag of
`{pos, amplitude, radius, decay, born}`, and the receiver sums the
live deposits in range. Two things fall out. A brazier depositing per
tick at a fixed position coalesces into one growing bump, reaching
steady state where feed equals leak; a screaming raider running
through the courtyard leaves a trail of bumps that leak
independently — **a scream lingers where it was screamed.** Pins:

- **Coalescing:** within a tick, deposits from one caster with
  identical `(pos, radius, decay)` sum their amplitude — the
  accumulate rule; otherwise they are distinct deposits. Net-zero
  silenced, as for `inc`.
- **Summation order** (refining pin 1 below): the receiver sums
  casters in stable caster-id order, caster-id derived from mount
  order — not allocation — and deposits within a caster in `born`
  order. Replay bit-identity depends on it.
- **Bound named in the ledger, no mechanism:** a bag is bounded by
  deposit rate × decay time; deposits below the channel's epsilon
  are culled. If a scene runs away, the error budget is the guard —
  same sentence as the rounds bound.

**Combination is channel physics; sampling is instrument choice.**
The canonical value at a point is fixed — sum, per §3 — one truth,
no per-receiver realities. What varies by receiver is the
*instrument*: point sample, area average, gradient estimate, a march
along a path for field navigation. Same field, different ways of
reading it — two sensors with different cadences reading the same
geometry. This is what keeps "different sampling policies" from
being misread as "different receivers get different truths."

**The housework (open work, named now so it is scheduled rather than
discovered):**

- **Notifications compute on the aggregate.** A threshold occurrence
  ("$alarm rose above 0.5 here") is a fact about the canonical sum,
  never about any single caster's contribution. A caster-local
  threshold would fire on a contribution the receiver-side sum
  contradicts.
- **Deletion runs the same housework.** Unmounting a caster moves
  the aggregate, and a moved aggregate can cross thresholds — so the
  same notification path must run on caster removal as on any other
  change. A rill delete that silently drops the sum below a
  threshold without the occurrence firing is the arm-on-first-
  observation bug's sibling: a transition nobody said. *(Built
  2026-08-25: met BY CONSTRUCTION — the ear reads the canonical
  aggregate, a removal moves it, the ear publishes the change, and
  thresholds fire from it like from any other change. There is no
  separate delete-path notifier to forget; F7's gate and its named
  mutation hold it.)*

Three pins:

1. **Deterministic summation order.** Float addition is not
   associative; the receiver sums in stable caster-id order, or
   replay's bit-identity dies in the last decimal place.
2. **Ownership generalises to every caster kind** — rill, prefab
   group, instance-via-action, volume. Lifetime is mount/spawn
   lifetime in all cases.
3. **A scream dies with the screamer.** Tom despawns mid-scream, his
   contribution vanishes that tick. Acceptable for v1; if a scene
   wants sound to outlive its source, that is authorable — the death
   machinery can cast a final pulse from a longer-lived owner.
   Recorded as a choice, not discovered as a surprise.

---

## 5. Decay: per-deposit runtime physics (re-ruled 2026-08-25)

**This section originally ruled "decay is authored as a rill first,
promoted to channel physics only if patterns recur." That ruling is
reversed** (stamped, note §3), because the rill version cannot be
built as written — the sketch

```
$blight | mul -0.1 | cast $blight
```

reads a path it writes, and §4.4 refuses exactly that. The sentence
"legal for the same reason counters are" was wrong: `inc` passes the
cycle ban because it is *blind* — no read — and this rill reads. The
delay operator that would license deliberate feedback does not exist,
and even with it, an exponential never reaches zero, so a decay rill
would re-rouse every tick on every caster forever.

**Ruling:** decay lives on the deposit — §6's `decay` port, defaulting
from the channel declaration (§7). The runtime leaks each bump in fed
time and culls below the channel's epsilon. This is §7's "eventually
intrinsic decay" arriving before the rill version was ever built — a
reversal made because the cycle ban forced it, recorded here rather
than swapped quietly.

**Corollary (advised in the note, built as v1's rule):** with decay in
the runtime, no rill has a reason to read its own space, so **the bare
`$channel` read inside a rill is not built in v1** — the parser
refuses it with the ruling in the message. Every reading comes from a
standpoint (`@tom.$dread`, `sensors/gate/$alarm`), exactly as §9
already rules, and the cycle checker stays out of the field store
entirely.

---

## 6. Writes: contribute-only (ruled)

Field writes are the **accumulate family** (`inc`'s kin). Nobody
`set`s a field; everyone *contributes* to it, positive or negative,
and the sum is the truth. Contributions commute per tick — no
ordering fights, mergeable by construction. The read-your-own-write
ban survives unchanged.

`cast` is the verb, available to instances and to rills alike (a rill
can be a caster). **Grammar pinned 2026-08-25 (stamped, note §1),
built in rill core the same day:**

```
cast <$channel> [value] radius <r> at <pos> [decay <d>]

every 1f { cast $torchlight 0.8 radius 12 at s.brazier.pos decay 4s }

s.gate.enemy_count | rose_above 0
  | also { cast $alarm 1.0 radius 30 at s.gate.pos decay 2s }
  | also { cast $alarm 1.0 radius 30 at s.tower.pos decay 2s }
```

The §3.8 sink shape, unchanged: port 0 is the rousing, a bound
`value` is the payload. Channel and radius are statics; `at` and
`decay` are **keyword ports** (the word introduces the value —
positionally, `cast $alarm 30` cannot say whether 30 is payload or
radius, and a grammar that guesses is worse than one that asks):

- **`at <pos>` is a port, bound or live.** A body-bound caster reads
  its own instance position; a supervisor casts at any position it
  can read. Dot-form is a live reference, so a moving caster's
  position updates without re-rousing (a change in payload alone is
  not a write). Casting in several places from one rousing is two
  `also` branches — no list argument.
- **`decay <duration>`**, optional, in the ratified duration grammar
  (`5s` / `250ms` / `3f`): this deposit's leak time-constant,
  defaulting from the channel declaration (§7). See §5 for why decay
  is on the cast at all.
- **Unpiped, the intensity binds port 0 and is both rousing and
  payload**, so a bare `cast $torchlight 0.8 radius 12 at …`
  deposits **once, at tick 0**, then leaks away. A standing caster
  needs a per-tick rousing in front — `every 1f`. This will surprise
  the first person who writes a brazier; it is said wherever the
  grammar is introduced.
- `to #tag` (coupling, §8) parses when the tag store exists — its
  beat, not this one.

The deposit crosses the plane boundary on its own vtable arm
(`castFn`), not a `DeltaKind`: a cast is not addressed at a path — it
is keyed by who is casting, and the receiver-side sum is the only
read surface. It commits through the main-thread drain so
program-write ordering is deterministic, but per §11 **fields stay
out of the log** — drain yes, log no.

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

**The symmetry, stamped 2026-08-25: a cast names where it deposits
(`at`); a read names where it samples (its standpoint path); neither
has an implicit "here."** The parser enforces the read half — a bare
`$chan` is refused with the spelling stated
(`plane.sensors.<post>.$chan`, or `@id.$chan` when the registry
lands), not just the refusal.

Two things recorded here, not built:

- **`@self.$chan` sugar** inside an instance-bound def, when R4
  arrives — under the `use` precedent: parse-time expansion, dumps
  store the expanded path, nothing downstream of the parser knows
  the sugar exists.
- **A positioned read for a supervisor is an ear with a `position`
  port declared on the spine** — never a rill-side query. If a
  supervisor needs the field "over there", it declares an ear there;
  the standpoint stays a declared object.

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

**The maintainer is authored, not ambient.** Three probe rounds
running, a fluent reader made "the engine" the maintainer of derived
tags. It is not. The derivation rule is a thing in the Project —
authored, mounted, and unmounted like a rill — and *it* is the
maintainer. This is what makes derived tags authorable and deletable
rather than world physics: unmount the rule and its tags go with it,
by the same lifetime logic as §4.1's caster-owned spaces. An ambient
engine-maintainer would be a maintainer nothing can unmount.

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
- **Hard lifetime `for <duration>`** — a step rather than a leak:
  a pulse that holds full-strength and drops. Deferred until a scene
  wants one; the `decay` port's shape is where it would sit. (Replaces
  the old "decay promoted to channel physics" entry — that promotion
  happened at birth, §5.)
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
- **F3 — decay** (restated 2026-08-25 per §5's reversal): an un-fed
  deposit drops below the channel epsilon within the declared time
  constant and is culled; a deposit fed by `every 1f` reaches steady
  state. Deterministic in fed time; replay byte-identical. The
  mutation: skip the cull and watch the bag grow.
- **F4 — coupling** *(awaits the tags beat — the `#` row is its
  prerequisite, deferred per the note's §6 sequencing)*: a coupled
  cast reads as zero to an entity without the receptor tag and
  non-zero with it; granting the tag mid-run changes the reading on
  the next tick.
- **F5 — derived tags** *(awaits the tags beat, with F4)*: an entity
  crossing a field threshold gains
  the tag within one tick and loses it within one tick of leaving
  (plus hysteresis if declared); the maintainer's removal is the only
  removal.
- **F6 — gradient:** published gradient at a sample point matches the
  analytic derivative of the kernel sum (hand-computed expectation,
  per the S3.5 practice — derived on paper, not read off the code).
- **F7 — deletion housework:** two casters hold `$alarm` above
  threshold at a sample point; unmounting one drops the aggregate
  below it, and the threshold occurrence fires on that tick — from
  the removal, with no other change in the scene. The mutation:
  suppress the housework on the delete path and watch a transition
  happen that nobody said.

Each gate ships with a mutation that trips it, message in the
fiction's language, per house practice. A mutation that does not bite
is a finding about the gate.

**Status 2026-08-25: F1/F2/F3/F6 held at the instrument (fields.zig)
and F1/F7 through the plane (casting.zig), every expected number
derived on paper, every mutation watched biting — including F7's named
one (suppress the drop on the delete path) and two the practice caught
in the gates themselves: a two-caster order gate that could never see
summation order (IEEE addition is commutative, only non-associative),
and its replacement whose off-line expectation was computed in float64
when the implementation sums in f32. An expectation is faithful to the
implementation's arithmetic, or it is not an expectation.**
