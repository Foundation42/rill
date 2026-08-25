# rill tier 2 — stock operators, and how to find the next ones

*Design input for CC's tier-2 recon. Shapes and pins ratified by Chris
(§6); operator names in the sections marked bikeshed are the recon's to
propose. Everything here was imagined from typical use, then partly
probed by writing the breathing exposure; the method section (§5) is how
the rest gets probed. Sequencing in §7.*

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
| `beat [division]` *(candidate)* | occurrence on host-fed tempo | Houdini/TD both have it; `lfo square` is wrong the moment tempo is live, and here tempo is live. Needs the host to publish tempo |

`noise` is a seeded, deterministic shape — the host feeds the seed as
data, or the program pins one. `lfo` is a source (it reads fed time
internally) rather than something you feed a clock into, because "an LFO
at four seconds" is how people say it.

### 2.3 Registers — smoothing and easing

The design-significant family. A rill can't chase a target through the
plane; these chase it inside the operator.

| op | behaviour | notes |
|---|---|---|
| `ease <tau> [up <t>] [down <t>]` | output follows input with time constant τ; `up`/`down` set asymmetric constants | leaky integrator; the smoother rill lacked. With `up` short and `down` long it is the envelope follower (`abs \| ease 20ms down 400ms`) and the trigger envelope (`pulse 200ms \| ease 10ms down 300ms`) — three CHOPs and Max's `slide` in two keyword ports |
| `ramp <duration>` | on input change, tween linearly from current output to the new value | the "fade to" |
| `slew <rate>` | output moves toward input at most `rate` units per second | rate limit; name is jargon, alternatives welcome |
| `hold <duration>` | on input change, hold the new value for `duration`, ignoring further changes | sample-and-hold |
| `diff` | rate of change per second, from the previous sample | velocity from position; a derived quantity people otherwise invent as a sensor field |
| `integrate [max <m>]` | running sum over fed time, clamped | "charge while held"; the clamp is required, not optional — unbounded state is a corpse |
| `walk <step> range <lo> <hi>` *(candidate)* | bounded random walk, seeded | Max's `drunk`; the "wander" that `noise` at a long period only approximates. Listed, not admitted — needs a customer |

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
| `shape <curve>` | 0..1 → 0..1 | `smooth`, `in`, `out`, `inout`, `linear` — or an authored curve track (Substance's Curve node), which makes it `along` for 1D |

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

The bill for broadcast, paid up front: **a kind or shape mismatch is
loud, with both sides named.** ICE had broadcast and reported mismatches
without naming the contexts; that error was the one every ICE user
learned to dread. rill doesn't wire-check kinds in v0. When broadcast
lands, so does the check — and `expect`/`match` (§2.13) are the author's
tools for asserting shape at a boundary rather than discovering it
downstream.

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
is one operator with `t` piped:

| op | emits | notes |
|---|---|---|
| `along <knots> [kind <k>]` | the knots evaluated at piped `t` in 0..1 | `knots` is an array literal or a track path; `kind` is `catmull` (default — passes through its knots, which is what people expect), `bezier` (handles), or `linear` (corners) |

Knots come from two places, and both are wanted. An **inline array**
(§2.10) is the rillbook case — three points typed into a cell, no host
verb in the way. A **track** on the plane is the authored, shared,
serialised case: Matryoshka's `camera path` machinery generalised into a
spine tenant (`track set intro catmull p0 p1 p2 …`, in packs, with
arc-length parameterisation as a track property). For a track the kind
lives on the track and `along` reads it; for an inline array the `kind`
port says, default Catmull-Rom.

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

### 2.10 Arrays

The agent manual currently says "no array/vec literals." That line
should go. Arrays are already a value kind in rill — `window` emits one
and `stats` consumes one — so the literal is the missing half of
something that exists, not a new thing. And the use case is too big to
route through the host: knots, keyframes, gradient stops, palettes,
lookup tables, "pick one of these."

**The literal:** `[a, b, c]` — commas, matching records, because that is
what a no-priors reader writes. Elements are literals, paths, names,
records, or arrays. An array containing a name or path is **live**, the
same way `{health: hp, mana: mp}` is: it re-evaluates when an element
changes. That reuses the record machinery wholesale; positional fields
instead of named ones.

**What an array is not:** a buffer. Values are immutable per tick; there
is no element assignment, no append, no loop over one. An array is a
value that happens to have several parts. `each <def>` — apply a def
across elements — is a tier-3 question, and the answer is probably yes,
but not here.

**The ops**, deliberately few:

| op | emits |
|---|---|
| `nth <i>` | the i-th element (0-based), error out of range |
| `len` | element count |
| `first` / `last` | the ends |
| `choose <i> <array>` | `nth` with the index piped — "choose one of these" |

`stats` already covers min/max/mean over an array. Positions stay
records — `[0, 2, 0]` does not coerce to `{x, y, z}`; one thing, one
spelling. Whether a positional record shorthand for vectors is worth a
literal of its own is an open pin.

### 2.11 Over arrays — map, reduce, sort, filter *(bikeshed)*

Marked as bikeshed: the shape is clear, the words aren't settled.

**There is no new syntax.** rill already has bodies, and they are not
blocks. A predicate section `(> 0)` is a partial application — an
operator with one port left open — and a `def` is a named one. Both are
pure, both close over nothing, and both are what a map or reduce takes.
`{ }` stays a fan-out; `( )` and defs are bodies. That line is the whole
design, and it keeps unlearn #6 intact.

Rule for sections: the consumer fills the open ports positionally.
`map` supplies one (the element), `reduce` supplies two (accumulator,
element), `sort by` supplies one and expects a comparable.

**Most map is free.** With ops broadcasting elementwise over arrays
(§2.5's pin, extended), `window 10s | mul 2` *is* map. Explicit `map`
is only for a def or a multi-step body.

| op | emits | notes |
|---|---|---|
| `map <body>` | array | `map healthbar`, `map (clamp 0 1)` |
| `where <pred>` | array | same word as the stream gate, dispatched by kind — "the window, where above 0" reads right either way; discuss |
| `reduce <body> [init <v>]` | scalar | `reduce (add)`, `reduce (max)`; `stats` covers the common cases |
| `sort [by <body>] [desc]` | array | `sort by (.distance)` |
| `take <n> [from <i>]` | array | top-k after a sort, or a sub-array with `from`; `first`/`last` stay scalar |
| `group by <body>` | record of arrays | tier 3 — wait for a customer |

**"Continuous" needs nothing extra.** An array is a value; a stream of
arrays re-evaluates anything downstream when it changes. A sorted window
is continuous by construction. Whether the runtime re-sorts or
incrementally inserts/evicts is an implementation choice behind the
gate — with one caveat the ledger already holds: an incremental running
sum drifts in f32 and a recompute doesn't, so `reduce` and `stats` must
pick one and their gates must assert *that* arithmetic.

**Customers**, which is why this section exists at all:

- The contact source (T2) publishes contacts as an array. Nearest
  hostile: `plane.sensors.gate.contacts | sort by (.distance) | first | .id`.
  Today that would be a sensor field someone invents.
- Top three threats: `… | sort by (.threat) desc | take 3`.
- Loudest recent reading: `window 5s | reduce (max)`.
- Any-of over a set: `… | map (.armed) | reduce (or)`.

Each of those is one line and none needs a word the language doesn't
already have, except `map`, `reduce`, `sort`, `take`. Four words for the
whole family, against the budget.

### 2.12 Records — pick, omit, rename, spread, zip *(bikeshed)*

Most of this exists. Against the JS/TS vocabulary people arrive with
(destructuring with rename, spread, `Pick`/`Omit`):

| you want | rill today | gap |
|---|---|---|
| rename | `{hp: player.health, mp: player.mana}` — the literal plus projection | none |
| spread | `merge a b` | none |
| pick | `plane.player.{health, mana}` — the sibling sugar | **paths only**; extend the same sugar to record streams: `vitals.{health, mana}` |
| omit / rest | — | `without <fields>` |
| pluck | — | free, if `.field` projects elementwise over an array of records (the broadcast pin): `contacts \| .distance` |
| zip / unzip | — | see below |
| shuffle | — | `shuffle [seed <s>]`, seeded like everything else |

**`zip` and `unzip` are the AoS↔SoA transpose**, not "pairs from two
arrays." `zip` takes a record of arrays and gives an array of records;
`unzip` the reverse. That is what a window of records needs —
`plane.player.{health, mana} \| window 10s \| unzip \| .health \| stats` —
and it's what people mean when they reach for the word. Two arrays into
pairs is `zip {a: xs, b: ys}`, the same op.

`shuffle \| take 3` is "three at random, no repeats."

**`zip` with mismatched lengths refuses.** Grasshopper picks a matching
rule implicitly (longest, shortest, cross-reference) and it is the
most-complained-about behaviour in the tool. Never pick a rule; error
with both lengths named.

Words added: `without`, `zip`, `unzip`, `shuffle`. The sugar extension
and pluck cost none.

### 2.13 Contracts — `expect` and `match`

From SPL's `match`: a shape on the wire, and the incoming record either
fits it or does not pass. An assertion, not a branch. Two words, because
there are two different promises and the author should say which one
they're buying:

| op | when it checks | on failure |
|---|---|---|
| `expect <shape> [exact]` | **at mount.** The upstream shape must be provable from declared schema; if it can't be proven, `expect` refuses the mount and says to use `match` | refuses the mount, node named, field and both kinds in the message |
| `match <shape> [exact]` | **per value, at runtime.** If a mismatch is provable at mount, it refuses there instead — loud earlier is always allowed | operator error naming the field and both kinds; kills the wave, counts against the budget |

`expect` never silently falls back to a runtime check — that would hide
cost, and cost stays visible. `match` never silently promotes to a
guarantee. Same shape literal, same `exact`, different promise.

**The shape literal** reuses the record literal with type words as
values: `{id: string, distance: number}`, nested shapes, `[number]` for
an array of, `?` for an optional field (`{pos: {x: number, y: number,
z: number}, kind?: string}`). Shapes are **open** by default — extra
fields pass, TS-style — and `exact` closes them.

**Where each belongs.** `expect` at the boundary with the plane — after
a path whose schema the registry declares, which is most of them. It
costs nothing at runtime and it's documentation on the wire. `match`
after anything whose shape is only known on arrival: a contact list, a
record built from `window`, a host verb's result. Between them they are
the author's half of the ICE lesson (§2.5): the engine's mismatch check
catches what you didn't anticipate; `expect`/`match` is where you write
down what you did.

The filter form — drop what doesn't fit rather than error — is `where`
with a shape predicate, and can wait for a customer.

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
| flash a light on an event (attack, decay — not a rectangle) | ~4, and a rectangle | 1 | `pulse \| ease up down` |
| VU meter on a field reading | can't | 1 | `abs \| ease 20ms down 400ms` |
| fade the exposure in over 2s on mount | can't (no register) | 1 | `once`, `ramp` |
| ease the camera exposure toward a target | can't | 1 | `ease` |
| dim the lamp as the fire dies | 2 | 2 | ✓ (fields) |
| pulse a light with the beat | ~4, and wrong if tempo is live | 1 | `beat`, or `lfo square` for a fixed tempo |
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
| move a light through three points typed into a cell | host verb only | 1 | array literal, `along` |
| pick an exposure by time-of-day band | `select` chain | 1 | array literal, `choose` |
| nearest hostile from the contact list | invented sensor field | 1 | `sort by`, `first` |
| top three threats | can't | 1 | `sort by`, `take` |
| refuse a malformed contact list at the boundary | silent | 1 | `match` (runtime) |
| pin the shape a program reads from the plane | silent | 1 | `expect` (mount) |

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

10. **Diff against a prior-art set once per tier.** Done for tier 2
    against Houdini and TouchDesigner CHOPs, Max/MSP's control objects,
    ICE, and Substance's atomics: it took an hour and found four things
    (`up`/`down` on `ease`, `beat`, `from` on `take`, `walk`) that a probe
    would have taken weeks to surface. Everything else on those lists
    was already covered or belongs to the host.

## 6. Pins — ratified by Chris

All open pins closed on Chris's side. The lean in each case is the
ruling.

- **`lfo` and `clock`:** both. `lfo` is sugar over `clock | wave`.
- **`ease` cost model:** per-frame ticking while converging, cut off at
  ε. ε is a per-op default, not a knob. Same rule as field deposits.
- **`slew`:** the name stands unless the read-aloud test turns up a
  better one during the recon.
- **Noise determinism:** bit-identical across machines, not just across
  replays — integer hashing, no `sin`-based hashes, f32 in a fixed
  order. The oracle rule applies to its gate.
- **Seed:** default 0. Host-fed seed available as data for a fresh world
  each run.
- **Gradient noise:** Perlin, until spatial noise has a customer.
- **`tally` on remount:** does not survive. Remount is restart; a
  persistent count is `inc`'s job.
- **Tracks:** a spine tenant, `camera path` generalised (kind, knots,
  optional arc-length). Engine work, sequenced with the D beat.
- **`along` outside 0..1:** clamp. `wrap 0 1` before it if you mean to.
- **Track kinds:** Catmull-Rom (knots only) and Bezier (handles per
  knot); default Catmull-Rom.
- **Vector shorthand:** wait for the list to complain. The array literal
  is not the shorthand.

Still marked bikeshed, deliberately: the *words* in §2.11 and §2.12
(`where` dispatched by kind; `zip` as transpose vs `transpose`). The
shapes there are ratified; the names are the recon's to propose.

Also ratified: §2.13's split — `expect` is the mount-time assert,
`match` the runtime one — and the shape literal `{id: string, …}`.

## 7. For CC — sequencing

Everything in §2 is to be built; this section is the order, not a
shortlist. The recon comes first and has the same shape as the casts and
tags openers: what exists vs what this assumes, a beat order with gates,
pins, forks. It sequences **after T5 closes** — don't interleave it with
the tags beat.

**Priority order:**

1. **Now, one small commit, before T5** — the two things that get more
   expensive every day the corpus grows: the `lerp` port flip (`t`
   piped) with a wrong→right row, and `and or not`.
2. **Recon, after T5.** First item in it: confirm the §2.3 premise —
   op-internal state is legal under §4.4, the cycle ban being about
   state *through the plane*. This is a confirmation to write down, not
   a question to reopen; it's first because the register family and
   most of the "can't" rows in §4 sit on it, and the recon should build
   from a stated foundation.
3. **Beat 1 — registers and time.** `clock`, `frame`, `lfo`/`wave`,
   `ease` (with `up`/`down`), `ramp`, `hold`, `diff`, `integrate`,
   `range`, `remap`, `shape`, the math completions. This beat alone
   turns the breathing exposure into one line and clears the top of the
   list.
4. **Beat 2 — arrays.** The literal (a grammar change, additive: no
   existing program changes meaning), `nth`/`len`/`first`/`last`/
   `choose`/`take`, broadcast over records and arrays with the loud
   mismatch check, and `expect`/`match`. Its arrival retires the agent
   manual's "no array/vec literals" line and the grammar note beneath
   it.
5. **Beat 3 — over arrays and records.** `map`/`reduce`/`sort`/`take`,
   `without`/`zip`/`unzip`/`shuffle`, `along` with inline knots. The
   bikeshed names get settled here.
6. **Beat 4 — noise, events, spatial.** `noise`, `rand`, `pulse`,
   `once`, `toggle`, `tally`, `above`, `distance`/`within`/`toward`.
7. **Deferred to their own beats:** tracks as a tenant (with D),
   `beat` (needs tempo on the plane), `walk`, `spring`, `smooth`
   (needs the window-with-times shape), `group by`.

Each beat lands its before/after pairs in the idioms book as gates
(§5.9), and the simple-things list is re-scored at each close.

**Word count, honestly.** The sections propose 43 words (45 with the
two candidates), against a budget of ~30. Admission is by customer and
the budget applies at landing, so the recon marks each word's customer
on the §4 list; words without one stay listed, not admitted. Obvious
cut candidates if the count needs to come down: `norm` (`remap` covers
it), `either` (two lines to one sink), `rate` (`window | len`), `slew`
(`ease` approximates it), `toward` (record math once `normalize`
exists), and `len`/`last` as words that are cheap but still words.

## 8. Adjacent asks — not language, don't lose them

Things the prior-art round surfaced that belong to the rillbook, the
host, or the manual rather than the operator table:

- **Ticks-every-frame badge.** Houdini marks time-dependent nodes with a
  clock. A rillbook cell that re-evaluates every frame (`clock`, `lfo`,
  `noise`, anything downstream of them) should say so on its face — cost
  visibility, per cell.
- **Exposed ports as sliders.** A `def` port with a declared range
  renders as a slider in the rillbook (Substance's exposed parameters).
  The knob registry already has the metadata shape; this is plumbing it
  to defs.
- **Kind wire-checking** is a v0 debt that comes due with broadcast.
  `expect`/`match` are the author-side tools; the engine-side check lands
  with the broadcast pin.
- **Prior art in the manual.** One line in §4 (sinks): Max/MSP's hot and
  cold inlets are the same rule as "port 0 rouses; a change on a bound
  port alone is never a write." A reader from that world gets the rule
  for free; everyone else gets a second explanation.
- **Tempo on the plane.** `beat` needs the host to publish tempo as
  data. That's the music stack's job and it's small.
