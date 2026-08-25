# rill tier 2 — stock operators, and how to find the next ones

*DRAFT — unratified. Exploratory: this is the possibility space, not the
spec. Everything here is imagined from typical use, not yet probed. The
method section (§5) is how it gets probed.*

---

## 0. What "tier 2" means

**Tier 1** is the ratified core: flow, events, temporal, math, records,
sinks, util — the operators the language needs to be a language.

**Tier 2** is what a person needs so that *typical* asks are one line.
Rill-side (in core, present in every host), stock (nobody installs
them), and admitted by a customer: an operator enters tier 2 when a
listed simple ask can't be one line without it.

The breathing exposure is the founding example. The ask is one sentence
— *breathe the exposure between 0.5 and 1.5 over four seconds* — and
today it is two programs, a seeded counter, and seven lines of arithmetic
with an unpiped `lerp`. All of it correct. None of it acceptable. The
target:

```
lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure
```

## 1. Admission rules

An operator gets into tier 2 if all of these hold:

1. **It has a customer** on the simple-things list (§4). No operator on
   spec.
2. **It is pure, or its state is op-internal.** State *inside* an
   operator is fine — `window`, `debounce`, `stats` already hold state.
   State *through the plane* is a cycle. This is the register rule and
   it is what makes smoothing legal.
3. **Deterministic in fed time.** No wall clock, no unseeded randomness.
   Replay is bit-identical.
4. **Passes read-aloud.** One English word, no jargon collisions with the
   registry (the `pass`/`effect`/`tee` lesson), and the piped value is the
   thing a sentence would put first.
5. **Doesn't duplicate a host verb.** If Matryoshka already has it as a
   console verb, the question is whether it belongs in core, not whether
   to add it twice.
6. **Has a gate a mutation can bite.**
7. **Fits the budget.** Every word is a row an agent must learn. Tier 2
   stays under ~30 words and the operator table stays readable on one
   screen; past that, a new word must retire or subsume an old idiom.
   Optional parameters are keyword ports (`octaves`, `seed`, `width`,
   `phase`) on the `cast` pattern, never new words.

## 2. The families

### 2.1 Time as a value

Today time is fed but never a value, so anyone who needs it builds a
counter and seeds it. Two sources beside `every`:

| op | emits | lane |
|---|---|---|
| `clock` | fed real time in seconds since mount | real |
| `frame` | fed frame count since mount | frame |

"Since mount" keeps them program-relative and replay-clean. Both change
every tick, so anything downstream re-evaluates every tick — that is the
cost of animation and it should be visible.

### 2.2 Modulation sources

| op | emits | notes |
|---|---|---|
| `lfo <shape> <period> [phase <p>]` | 0..1 | shapes: `sine`, `tri`, `saw`, `square`, `noise` |
| `pulse <period> [width <w>]` | occurrence, then value 1 for `w` | the strobe / heartbeat |

`noise` is a seeded, deterministic shape — the host feeds the seed as
data, or the program pins one. `lfo` is a source (it reads fed time
internally) rather than something you feed a clock into, because "an LFO
at four seconds" is how people say it.

### 2.3 Registers — smoothing and easing

The design-significant family. A rill can't chase a target through the
plane; these chase it inside the operator.

| op | behaviour | notes |
|---|---|---|
| `ease <tau>` | output follows input with time constant τ | leaky integrator; the smoother rill lacked |
| `ramp <duration>` | on input change, tween linearly from current output to the new value | the "fade to" |
| `slew <rate>` | output moves toward input at most `rate` units per second | rate limit; name is jargon, alternatives welcome |
| `hold <duration>` | on input change, hold the new value for `duration`, ignoring further changes | sample-and-hold |
| `diff` | rate of change per second, from the previous sample | velocity from position; a derived quantity people otherwise invent as a sensor field |
| `integrate [max <m>]` | running sum over fed time, clamped | "charge while held"; the clamp is required, not optional — unbounded state is a corpse |

`diff` earns its place on the keep alone: the probe reviewer invented a
`raider_velocity` sensor field because nothing derived it.
`plane.sensors.gate.nearest_distance | diff | dropped_below 0.1` is the
honest spelling, and it's one word.

All four re-arm per frame while converging and stop when |in − out| < ε
(the same cull rule as field deposits — a converging op should not tick
forever). ε is per-op with a sane default; not a user knob in v1.

`spring <frequency> <damping>` belongs here eventually. Deferred until a
scene wants overshoot.

### 2.4 Shaping and mapping

| op | maps | notes |
|---|---|---|
| `range <lo> <hi>` | 0..1 → lo..hi | the common lerp |
| `norm <lo> <hi>` | lo..hi → 0..1 | its inverse |
| `remap <in_lo> <in_hi> <out_lo> <out_hi>` | interval → interval | when both ends aren't unit |
| `wrap <lo> <hi>` | modular fold into an interval | angles, phases |
| `shape <curve>` | 0..1 → 0..1 | `smooth`, `in`, `out`, `inout`, `linear` |

**`lerp` port order flips**: piped value is `t`. "s, lerped between 0.5
and 1.5" is `s | lerp 0.5 1.5`. The current order (`a b t`) forced the
breathing program to bind all three unpiped. Two days old, flip it now.

### 2.5 Math

`sin cos tan atan2 sqrt pow exp log mod sign fract`, and `pi` / `tau` as
constants. Nothing to argue about; they are missing.

Also missing and hit on day one: **`and or not`**. The conjunction idiom
is `where <bool>`, and the first program with two conditions needs
`and`.

One pin rather than a family: **math ops broadcast over records.**
`add` on two `{x, y, z}` records is elementwise; a scalar broadcasts.
That makes "keep the light 2m above the player" one line —
`@player.pos | add {x: 0, y: 2, z: 0} | set …` — without a separate
vector family, and it's what every graphics person expects anyway.

### 2.6 Event shaping

| op | behaviour | customer |
|---|---|---|
| `once` | pass the first occurrence, then deaf until remount | "fade in on mount" |
| `toggle` | flip a boolean on each occurrence | the light switch |
| `tally` | running count of occurrences, as a value | "count the kills" — op-internal, so no `inc` dance |
| `rate <window>` | occurrences per second over a window | "how hot is the mailbox" |
| `either <a> <b>` | occurrences from both streams, in tick order | "gate or tower sounds" |
| `above <on> <off>` | bool with hysteresis: true once input rises past `on`, false once it drops past `off` | any noisy signal into a switch; strict crossings chatter at dusk |

`above 0.3 0.2` reads as "above 0.3, until below 0.2." Its mirror
`below <on> <off>` is the same op with the sense flipped; whether it
earns a second word is a read-aloud question.

`tally` rather than `count` so it never reads like the `tags/<t>/count`
path. `once` is `arm` with no rearm; it earns a word because "once" is
what people say.

### 2.7 Spatial helpers

With `@camera.pos` and `@tom.pos` arriving, the first three spatial
questions everyone asks:

| op | result |
|---|---|
| `distance <a> <b>` | scalar between two position records |
| `within <a> <b> <r>` | bool |
| `toward <a> <b>` | unit direction record a→b |

Tier 2 stops here. Anything that queries the world (nearest, visible,
inside a volume) is an instrument — sensor, ear — never an operator.

### 2.8 Noise

Two words, not one per algorithm. The split that matters to a user is
*smooth* vs *white*, not Perlin vs simplex.

| op | emits | notes |
|---|---|---|
| `noise <period> [octaves <n>] [seed <s>]` | smooth noise in 0..1 over fed time | gradient noise (Perlin-class); `octaves` makes it fBm |
| `rand [seed <s>]` | white: a fresh value in 0..1 per rousing | dice, jitter, "pick one" |

`noise` is stateless — a hash of lattice coordinates and seed, evaluated
at fed time since mount — so it isn't even a register; it's a pure
function of (seed, t). `period` is the feature length: one lattice cell
per period, so `noise 80ms` flickers and `noise 20s` drifts. `octaves`
stacks halved periods at halved amplitude (gain 0.5, lacunarity 2, not
knobs in v1). `lfo noise` from §2.2 is dropped in favour of this.

**Seed is the decorrelator.** Same seed and period ⇒ the same stream,
across programs and across replays. That's a feature: two torches on one
seed flicker together; three shake axes on seeds 1, 2, 3 are
independent. Default seed is 0, so the naive program is deterministic
and everyone who wants independence says so.

Spatial noise — sampling a 3D noise at a position, `noise3 <pos>
<scale>` — is pure and would be legal here, but has no customer yet:
"what varies over space" is a field's job, and per-instance variation is
`seed` derived from a position. Deferred until something asks.

Random walk (brown noise) is stateful and unbounded; not tier 2. Low
`octaves` with a long period covers "drift."

### 2.9 Curves and tracks

Splines split three ways by what the user is doing, and each lands in a
family that already exists rather than as a "spline" op.

**Easing** — a 1D curve shaping 0..1 → 0..1 — extends `shape` (§2.4):

| op | notes |
|---|---|
| `shape bezier <x1> <y1> <x2> <y2>` | the CSS cubic-bezier form; every easing anyone has ever wanted |

**Evaluating a path** — a track of knots in space or in any value —
is one operator with `t` piped, and the *kind* of spline lives on the
track, not on the op:

| op | emits | notes |
|---|---|---|
| `along <track>` | the track evaluated at piped `t` in 0..1 | Catmull-Rom by default (passes through its knots — what people expect); Bezier when the author wants handles; linear when they want corners |

Tracks are host data, not rill literals — rill has no array literals
and shouldn't grow them for this. Matryoshka already authors camera
paths; a track is that machinery generalised into a spine tenant
(`track set intro catmull p0 p1 p2 …`, serialised in packs, kind and
optional arc-length parameterisation as properties of the track). `along`
is the bridge: any knob can follow any track.

The reason `along` takes `t` from the pipe rather than owning a clock is
composition, and it's the best argument in this section:

```
lfo saw 8s | along plane.tracks.intro | set plane.camera.target       // loop
lfo tri 8s | along plane.tracks.intro | set plane.camera.target       // ping-pong
once | ramp 8s | along plane.tracks.intro | set plane.camera.target   // play once
plane.door.open | along plane.tracks.rail | set plane.lights.rail.pos // driven by state, not time
```

The last line is the one to keep: a light slides along its rail *as the
door opens*, and no clock is involved. `t` is any value in 0..1;
`along` clamps outside it — wrap first with `wrap 0 1` if you mean to.

**Reconstruction** — Lanczos is not a path evaluator, it's an
interpolation kernel — lands in the register family (§2.3) as the FIR
partner to `ease`'s IIR:

| op | behaviour | notes |
|---|---|---|
| `smooth <kernel> [width <w>]` | output reconstructed from an op-internal window of recent samples | kernels: `lanczos`, `gauss`, `box` |

`ease` has no delay and lag-shaped distortion; `smooth` has half a
window of delay and none. The customer is an instrument at low cadence
feeding a per-frame knob — a 10 Hz ear into the exposure — where `ease`
would smear the shape and `smooth lanczos` reconstructs it.

## 3. Not tier 2

Strings and formatting; arrays beyond `window`; anything that touches
IO; set algebra over tags (`&`, `|` over `#` — R6's job); spatial
queries (instruments); host verbs (`light place`, `camera path`); anything
whose honest implementation needs the plane as state.

## 4. The simple-things list

The ergonomic gate. Each ask must be expressible in **at most two lines**
that the manual gate parses. Line count today vs. target; an operator's
customer is named in the last column.

| ask | today | target | needs |
|---|---|---|---|
| breathe the exposure between 0.5 and 1.5 over 4s | 9 lines, 2 programs, a seed | 1 | `lfo`, `range` |
| flash a light on an event, 200ms | ~4 | 1 | `pulse` or `hold` |
| fade the exposure in over 2s on mount | can't (no register) | 1 | `once`, `ramp` |
| ease the camera exposure toward a target | can't | 1 | `ease` |
| dim the lamp as the fire dies | 2 | 2 | ✓ (fields) |
| pulse a light with a beat | ~4 | 1 | `lfo square`, `pulse` |
| toggle a light on a keypress | ~3 | 1 | `toggle` |
| count kills | 2 programs (`inc` + reader) | 1 | `tally` |
| alarm when a raider is within 10m of the gate | needs `distance` | 1 | `within` |
| night falls → lights on | 1 | 1 | ✓ |
| cooldown-guarded order | 1 | 1 | ✓ |
| swing a light back and forth | ~8 | 1 | `lfo tri`, `range` |
| follow: keep a light 2m above the player | ~3 | 1–2 | record math |
| rate-limit a noisy sensor into a knob | 1 | 1 | ✓ (`sample`, `slew`) |
| flicker a torch | can't (no noise) | 1 | `noise`, `range` |
| shake the camera on impact, 300ms | can't | 2–3 | `noise` ×3 seeds, `hold`, record math |
| let the grade drift slowly over a minute | can't | 1 | `noise 20s`, `range` |
| pick a random idle animation per trigger | can't | 1 | `rand`, `floor` |
| fly the camera along the intro path over 8s, once | host verb only | 1 | `once`, `ramp`, `along` |
| slide a light along its rail as the door opens | can't | 1 | `along` (driven by state) |
| ease the exposure in with a custom curve | can't | 1 | `shape bezier` |
| reconstruct a 10 Hz ear into a per-frame knob without smear | `ease` (smears) | 1 | `smooth lanczos` |

The list is a rillbook page — the idioms book — one cell per ask, every
cell mounted against the tiltyard. When a new ask fails the two-line
test, the language is missing support and the list says where.

## 5. How to find pain points

Notes on method, so this stays a practice rather than a one-off.

1. **Try to write the simple thing.** Not the scenario — the scenario
   probe tests comprehension. The *simple* thing tests ergonomics. Pick
   an ask a person would say in one sentence and count the lines. The
   breathing exposure was seven lines of correct arithmetic; correctness
   is not the signal, line count is.

2. **Two probes, two laws.** The no-priors probe finds where intuition
   fights the paradigm and where the spec is silent. The write-it probe
   finds where the language is missing support. Keep them separate: a
   confabulation is a manual fix, a seven-line breath is an operator.

3. **Keep the before cell.** When an operator lands, the old cell stays
   in the idioms book as the before picture. The diff is the argument,
   and the before is the regression test for the next person who
   proposes removing the op.

4. **Unpiped port-juggling is a smell.** If a program binds three ports
   by position to avoid a pipe, the port order is wrong for the common
   case. Flip it while it's cheap.

5. **A seed step is a smell.** If a program only works after a console
   `set` to create a slot, something that should be a source is being
   built out of a counter.

6. **Two programs for one idea is a smell.** Legitimate when the idea is
   two ideas (the horn and the drawbridge). A smell when the split exists
   only to get around write-then-read — that is the register family
   asking to exist.

7. **Read-aloud before naming.** Write the target line first, say it,
   then name the operator from the sentence. `once`, `toggle`, `ease`
   came out that way. `slew` didn't, which is why it's marked.

8. **Admit by customer, never by symmetry.** "We have `range`, so we
   should have `norm`" is only true if something on the list needs
   `norm`. Symmetry is a reason to check the list, not a reason to build.

9. **Every op gets its before/after pair as a gate**, and the mutation
   is deleting the op: the after cell must fail to parse without it.

## 6. Open pins (for Chris)

- `lfo` as a source vs. `clock | wave sine 4s`. Source wins read-aloud;
  the pipe form is more composable (phase from elsewhere). Could be
  both, with `lfo` as sugar.
- `ease` cost model: per-frame ticking while converging, cut off at ε.
  Same rule as fields. Is ε a per-op default or a channel-style
  declaration? Lean: per-op default, not a knob.
- `slew` naming.
- Noise must be bit-identical across machines, not just across replays
  on one machine: integer hashing (no `sin`-based hashes) and f32
  arithmetic in a fixed order, so a `.rillbook` flickers the same on
  every host. The oracle rule applies — its gate asserts the
  implementation's arithmetic, not a float64 reference.
- Seed default 0 vs. host-fed: lean default 0 (the naive program is
  deterministic and reproducible), with a host-fed seed available as
  data for the cases that want a fresh world each run.
- Gradient noise implementation: Perlin (axis bias, simplest) or simplex
  (no bias, more code). 1D over time barely shows the bias; lean Perlin
  until spatial noise has a customer.
- Whether `tally` should survive remount. Lean: no — remount is restart,
  never resume, and a persistent count is `inc`'s job.
- Tracks as a spine tenant. `along` needs authored knots to read; the
  existing `camera path` machinery generalised into `track` (kind,
  knots, optional arc-length) is the lean, and it's engine work, not
  rill work. Sequence it with the D beat (writable `@` fields), since
  "follow a track" is mostly a write-routing customer.
- `along` outside 0..1: clamp (lean) vs. wrap vs. extrapolate. Clamp is
  the safe default and `wrap 0 1` before it is one word.
- Bezier as a track kind needs handles per knot; Catmull-Rom needs only
  knots. Author both, default Catmull-Rom.

## 7. For CC

This is input to a recon, not a build order. Expected response is the
same shape as the casts and tags openers: what exists vs what this
assumes, a beat order with gates, pins, forks. It sequences **after T5
closes** — don't interleave it with the tags beat.

Two exceptions that get more expensive every day the corpus grows, and
should land now, in one small commit:

- the `lerp` port flip (`t` piped), with a wrong→right row;
- `and or not`.

Everything else waits. When the recon comes, the first thing it should
settle is §2.3's premise — that op-internal state is legal under §4.4 —
because most of the "can't" rows on the list depend on it.
