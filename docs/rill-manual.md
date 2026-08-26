# The rill Manual

*For people. The agent edition is `rill-for-agents.md`; the normative
spec is `rill-spec.md`. Every ` ```rill ` example in this manual is
parsed by a test — if it's printed here, it compiles.*

rill is a small reactive dataflow language. A rill program is **mounted,
not run**: it sits on a world of named values (the *plane*), subscribes
to the paths it cares about, and re-evaluates incrementally when they
change. There is no run button, no main loop, no `if` statement.
**Propagation is the only control flow** — values flow through
operators, and operators are the valves that decide whether a change
continues downstream.

If you have used a spreadsheet, you already know the feel: cells that
watch other cells, updating when their inputs do, holding still when
nothing moves. rill is that, with a world instead of a grid.

---

## 1. Your first rill

```rill
plane.player.health | clamp 0 100 | div 100 | set plane.ui.healthbar
```

Read it aloud: *the player's health, clamped to 0–100, divided by 100,
written to the healthbar.* Mount it once and it is true forever — when
health changes, the healthbar follows, and when health is quiet, the
program does no work at all.

Three things to notice:

- `plane.player.health` is a **subscription**. Any `plane.…` path in
  any position subscribes; there is no special subscribe form.
- `|` feeds the left value into the right operator's first port —
  exactly like a shell pipe, and it is deliberately the 90% case.
- `set` is a **sink**: the wave of change ends there, in the world.

Mounting and unmounting belong to the host (in Matryoshka:
`rill mount healthbar <the text>`, `rill unmount healthbar`,
`rill list`, `rill dump`). Mounting runs *tick 0* immediately — the
program is live, effects included, from the moment it mounts. And a
remount is a **restart, not a resume**: the program begins again with
no memory of its predecessor.

Comments run to end of line with `//`:

```rill
// the healthbar, normalised
plane.player.health | clamp 0 100 | div 100 | set plane.ui.healthbar
```

---

## 2. Values and occurrences — the one distinction that matters

Every wire carries one of two kinds of stream:

- A **value** is *state*: last write wins, and writing the same bytes
  twice is silence. `health = 20` followed by `health = 20` propagates
  once. Ask a value any time; it holds still between changes.
- An **occurrence** is *an event*: it always propagates, and twice is
  twice. An enemy at the gate, then an enemy at the gate again, is two
  enemies — collapsing them would change what happened.

Most operators pass the kind through. A few convert values into
occurrences on purpose:

```rill
plane.player.health | dropped_below 20 | notify plane.signals.heartbeat
```

`dropped_below 20` fires **on the crossing** — strictly from ≥ 20 to
< 20 — and carries the value that crossed. Its mirror is `rose_above`.
Both **baseline silently on their first observation**: a program
mounted while health is already 15 has not *dropped* below 20; it
arrived there before you were watching. This is a feature, and it has
one sharp consequence covered in §8: whoever publishes a value should
publish its starting point.

---

## 3. Names, fan-out, fan-in

`as` names the stream at that point in the chain. Names are
single-assignment and must be defined before use:

```rill
plane.stats.mana | clamp 0 100 as mana
mana | div 100 | set plane.ui.manabar
mana | dropped_below 10 | notify plane.signals.low_mana
```

A bare name in argument position pulls that stream in (fan-in), and
`{ field: stream, … }` builds a live record:

```rill
plane.player.health as hp
plane.player.mana as mp
{ health: hp, mana: mp } | set plane.ui.vitals
```

Records project with `.field` — `vitals.health` — and the sugar
`plane.player.{health, mana}` builds the same record from sibling
paths in one stroke.

---

## 4. Sinks — how a program touches the world

Every effect is a **sink**: the wave ends there. Nothing flows onward
through a `set` — a pipeline that "does something and continues" is
imperative thinking wearing pipes (see §5 for the honest spelling).

All sinks share one shape: **`<verb> <path> [value]`**, where port 0 is
always the *rousing* — it decides **when** — and the optional bound
value decides **what**:

> **Piped value: write what's flowing. Bound value: write this,
> because something flowed.**

```rill
plane.hp | clamp 0 100 | set plane.ui.bar                // what's flowing
plane.signals.horn | set plane.gate.drawbridge_target 1  // this, because something flowed
```

```rill
plane.enemies | rose_above 0 | notify plane.signals.horn { kind: "approach" }
```

(Two blocks = two programs, and the rule is worth learning right here:
**a program may not both write and subscribe to one path — even in
unconnected branches.** The check is path-level (spec §4.4) and
deliberately conservative: self-rousing through the plane is the
hazard, the check does not trace whether your write actually reaches
your read, and the split is cheap — so it refuses the pairing
outright. A supervisor that notifies an alert mailbox and also watches
it is not a bug; it is two programs. Recorded, not built: a
graph-level cycle check that refuses only when the write reaches the
read, if a scene ever earns it.)

The verbs:

- **`set <path> [value]`** — write a value: this is the state.
- **`notify <path> [value]`** — the same write, stating the intent:
  this is an *event*. If the path is an occurrence mailbox, the write
  appends instead of replacing — the path's policy decides, not the
  verb.
- **`inc <path> <by>`** — add `by` to the path. A blind delta: it
  reads nothing, so the cycle check (§9) has nothing to refuse, and
  being commutative it doesn't care what order deltas arrive in.
  `by` is required, and the in-flowing value is the rousing, not the
  amount — `also { inc plane.sightings 1 }` counts sightings, not
  enemies-per-sighting.
- **`cast <$channel> [value] radius <r> at <pos> [decay <d>]`** —
  deposit into a *field* (§7).

A change in a bound `value` (or `by`, or `at`) alone is **not** a
write. The payload says what; the rousing says when.

---

## 5. Blocks — side branches and standing sources

To do a side effect *and* continue, branch with `also { … }`:

```rill
use plane.defense as d

plane.gate.enemy_count | rose_above 0
  | also { inc d.sightings 1 }
  | notify d.alerts
```

The block's branches are fed the in-flowing value; the main stream
continues unchanged past the block. Rules worth knowing before they
find you:

- **A branch begins with an operator** — its implicit source is the
  in-flowing value. A branch that started with a path or a literal
  would never be wired to anything and could never run, so it refuses.
- **A block has no sources of its own.** A branch cannot open a new
  subscription — it is fed the block's source and nothing else. "When
  X, and Y holds" is not a block-within-a-block; it is the conjunction
  idiom (§6a below).
- **No `as` escapes a block.** Bind the stream before the block.
- A branch that ends still holding a value gets a warning — end a
  branch with a sink, or drop the tail.
- **The last effect is the main stream's sink.** "Effects branch off"
  does not mean the main stream may never carry one — a chain of
  side-branches whose tail just hangs has over-learned the lesson.
  Branch the extras; end the stream in its sink.

The same block can hang off a **statement head** — the source feeds
every branch:

```rill
every 1f { cast $torchlight 0.8 radius 2.5 at plane.sensors.hearth.pos decay 4s }
```

**A block is a fan-out, not a body.** That line is the most loop-shaped
thing rill has, and it is not a loop: statements in a block are
parallel branches with no order between them. If you want sequence,
you want a pipeline, and the pipeline is the spelling.

`every <period>` is the metronome — an occurrence source that fires at
mount and then once per period of *fed time* (§6). It is how a standing
effect stands: the brazier above deposits every frame, forever, and two
lines of console can put it out (`rill unmount brazier`).

---

## 6a. Thinking in rill

A rill is a **standing order, not a procedure**. You don't run it; you
post it, and it holds until unmounted. Ask three questions of any line:
**what rouses it** (when), **what flows** (what), **where does the wave
end** (the sink). If you can't answer all three, you are still thinking
in steps.

| when you think… | write… | because… |
|---|---|---|
| "if X, do A" | `X \| <crossing or comparator> \| A` | conditions flow; the threshold *is* the if |
| "if X and Y" / "if not X" | `\| and`, `\| or`, `\| not` | boolean algebra is three ordinary operators, and they broadcast like the rest of the math |
| "when X, and Y holds" | the conjunction idiom, below | name the condition as a stream, gate with `where`; a block can't open a source |
| "is it dark?" vs "did it get dark?" | `< 0.25` vs `dropped_below 0.25` | a comparator is a state; a crossing is an event, fired once on the way through |
| "do A, then continue to B" | `X \| also { A } \| B` | side effects branch; the last effect is the main sink |
| "do A then B" (ordered) | one pipeline, or two branches if independent | a block is fan-out; sequence is a pipe |
| "count how many times" | `X \| inc plane.n 1` | a blind delta reads nothing, so it's the one write that can't cycle |
| "remember that X happened" | subscribe to the occurrence that says so | a flag is lingering state standing in for an event; if the state is real, its owner publishes it |
| "wait until X finishes" | the action's completion occurrence (R3); until then a labelled `delay` | rills express intent; the engine resolves the doing and *says* when it's done |
| "every N seconds…" | `every Ns { … }` | the metronome; fires at mount, never bursts after a hitch |
| "make it breathe / swing / pulse" | `lfo <shape> <period> \| range lo hi` | a waveform is a source, not a loop; `range` is the exit from 0..1 |
| "how long has this been running?" | `clock` | time is a value you read, not a counter you keep |
| "smooth this jittery reading" | `\| ease <tau>` | a rill can't chase a target through the plane; a register chases it inside the operator |
| "fade to the new value" | `\| ramp <over>` | `ease` never quite arrives (and shouldn't); `ramp` has an end and lands on it |
| "how fast is it changing?" | `\| diff` | derive it; don't ask the host to publish a velocity field |
| "count up while this is held" | `\| integrate max <m>` | op-internal state, so no `inc` dance — and the cap is required |
| "map 0..1 onto a real range" | `\| range lo hi`, not `lerp` | `range` clamps and `lerp` extrapolates; a modulation chain wants the interval it named |
| "add 2 metres to a position" | `\| add {x: 0, y: 2, z: 0}` | math is elementwise over records and arrays; there is no vector family to learn |
| "double every reading in the window" | `window 10s \| mul 2` | broadcasting over an array IS map |
| "pick one of these" | `\| choose [a, b, c]` | a table of choices is a *value*, not a chain of `select`s — read it left to right, edit it in place |
| "the i-th one" | `\| nth <i>` | `nth` and `choose` are one computation; the difference is which port rouses it |
| "read a field mid-chain" | `\| .field` | a field read used to need a name to hang off; now the chain is the standpoint |
| "three points typed into a cell" | `[{x: 0, …}, {x: 2, …}, …]` | an array literal is live, immutable, and not a buffer — `[0, 2, 0]` is not a position |
| "a record built from three computed streams" | `{x: (noise 40ms seed 1), …}` | a field may hold a whole operator call in parens; `( … )` only means a *section* where a consumer asks for one |
| "fade in on mount, then cost nothing" | `once 1 \| ramp 2s from 0` | `from` gives the first tween a start; without it the ramp simply is its target |
| "nothing has happened for 5s" | `plane.heartbeat \| debounce 5s \| notify plane.signals.stale` | absence is unobservable; `debounce` fires once, 5s after the last heartbeat — silence given a voice |
| "read the field here" | `plane.sensors.<post>.$chan` | a read names where it samples; a rill has no *here* |
| "cast from where I am" | `cast … at <a position you can read>` | a cast names where it deposits; a rill has no *here* |
| "make the gate close" | `set plane.keep.gate.drawbridge_target 1` | intent to an actuator target; physics is the engine's |
| "this program does three things" | three programs, or one with named streams — never one file with sections | a program may not both write and subscribe to one path |
| "override the derived tag for @tom" | a DIFFERENT tag (`tag @tom #alert-manual`), gated beside the derived one | a derived tag on its population is owned by its rule; a hand tag below the band is withdrawn next frame and `left` says so — if you want an override, you want a different tag |

(The table's middle column shows *shapes*; every fenced block in this
manual is a parsed program, and the shapes' real spellings appear in
the idiom below and the recipes.)

**The conjunction idiom** — "when the watch sees someone, *and* it's
dark, light the braziers." The block-shaped intuition (open a second
subscription inside `also { }`) refuses at the branch head, and folded
inside it is a second mistake: `dropped_below 0.25` as "is it dark" —
a crossing standing in for a state, so the braziers would only light
if dusk fell *after* the sighting. Name the condition as a stream;
gate with `where`:

```rill
plane.environment.ambient_light | < 0.25 as dark
plane.sensors.watchtower.visible_enemies | rose_above 0 as sighting
sighting | cast $alarm 1.0 radius 500 at plane.sensors.watchtower.pos decay 10s
sighting | where dark | set plane.keep.braziers.lit 1
```

Every rill program past the trivial needs this shape.

**One file is one program.** Sections are comments, not boundaries: a
file whose "section 3" writes a path its "section 1" subscribes to is
refused whole, with the pair named (§4's rule). Three things = three
programs, or one program with named streams.

**Actions are pending.** The muster, the loose, the winch — things
that take time and complete — get their vocabulary in R3 (an action
with a completion occurrence). Until then a `delay` is a stand-in and
should be labelled as one, as the worked example below does.

---

## 6. Time — fed, never read

rill never reads a clock. The host *feeds* time into each tick — a
frame index and elapsed nanoseconds — and duration literals pick their
lane by unit: `5s`, `250ms`, `2m` on the real-time lane; `3f` counts
honest frames. The two never convert.

```rill
plane.gpu.traversal_ms | window 10s | stats as t
plane.hp | changed | debounce 250ms | tap calm
plane.button | throttle 1s | notify plane.signals.click
```

The temporal set: `sample` (at most one per period, latest wins),
`debounce` (pass after quiet), `throttle`/`cooldown` (pass one, deaf
for the window), `window` (rolling buffer → array), `stats`
({max, mean, min, n, stddev}), `delay` (later), `arm`/`disarm`
(latch gates with `on`/`off` controls), and `every` (the metronome).

Because time is fed, **replay is free**: record the inputs, feed them
again, and every temporal operator re-fires on the identical tick. It
also means a quiet program costs nothing while the clock runs — nothing
goes dirty because time passed, only because a deadline arrived.

One behavior to know: after a *gap* in fed time (a hitch, a pause),
`every` fires **once** and resumes — it never bursts to catch up. A
brazier returns to steady state after a hitch; it does not spike above
it with deposits the pause never earned.

---

## 6b. Movement — time as a value, and the registers

Everything above treats time as something that *arrives*. To animate,
you need it as something you can *read*, and you need values that chase
other values. Both are operators.

**Time as a value.** `clock` is fed seconds since this program mounted;
`frame` is fed frames. Since **mount**, so two cells started a second
apart don't share a phase and a replay lands on the same numbers.

**Waveforms.** `lfo <shape> <period>` is a source in 0..1 — `sine`,
`tri`, `saw`, `square`. `wave` is the same waveform with `t` piped in,
for when the phase comes from somewhere other than a clock. `range lo hi`
takes 0..1 back out to a real scale, and `shape <curve>` eases it on the
way (`linear`, `smooth`, `in`, `out`, `inout`).

**`range` is the exit from the unit interval, and that is why it is not
`lerp`.** The arithmetic is the same — `lo + (hi − lo) · t` — but `range`
**clamps** its input to 0..1 and `lerp` **extrapolates** past its ends.
So a modulation chain uses `range`: everything upstream of it (`lfo`,
`wave`, `shape`) leaves 0..1 by construction, and if something ever
strays, the exposure stays inside the interval you named instead of
going dark or blowing out. Reach for `lerp` when you are genuinely
blending two things and want to be able to overshoot.

```rill
lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure
clock | set plane.ui.elapsed
lfo tri 8s | shape smooth | range 0 90 | set plane.lights.sweep.angle
```

The first line is the whole point of the family: *breathe the exposure
between 0.5 and 1.5 over four seconds*, one sentence, one line. It used
to be two programs and seven lines of arithmetic.

**Math is elementwise over records and arrays.** A scalar broadcasts to
every element, so there is no vector family to learn and no separate
"map":

```rill
plane.entities.player.pos | add {x: 0, y: 2, z: 0} | set plane.lights.follow.pos
plane.gpu.traversal_ms | window 10s | mul 2 | stats | set plane.ui.load
plane.sensors.gate.contacts | > 0 | set plane.ui.any_contact
```

`and`, `or` and `not` are ordinary operators too, and they broadcast the
same way — so `not` turns a condition over wherever you need the other
sense, and `[true, false] | not` is `[false, true]`.

Mismatches **refuse** rather than guess. Two records must have the same
field set; two arrays must be the same length; a record and an array
together have no elementwise meaning. Each refusal names both sides, the
offending field, and which side lacks it. `=` and `!=` stay whole-value
— a record already compares as a record, and breaking that up would
replace a good answer with a different one.

**Registers** chase a target *inside* the operator. They can, where a
program can't: a rill may not write a path it also reads, but an
operator's own state is not a path.

| op | does |
|---|---|
| `ease <tau> [up <t>] [down <t>]` | follow the input with time constant `tau`; `up`/`down` make it asymmetric |
| `ramp <over> [from <v>]` | tween linearly to each new target over `over`; `from` gives the FIRST tween a start |
| `hold <for>` | take a value, then ignore changes for `for` |
| `diff` | rate of change per second |
| `integrate max <m>` | running sum over fed time, clamped to ±m |

```rill
plane.sensors.hearth.heat | ease 400ms | set plane.lights.hearth.level
plane.render.grade.exposure_target | ramp 2s | set plane.render.grade.exposure
once 1 | ramp 2s from 0 | set plane.render.grade.exposure
plane.sensors.gate.nearest_distance | diff | dropped_below -2 | notify plane.signals.charge
plane.field.rumble | abs | ease 20ms down 400ms | set plane.ui.vu
```

The last one is the envelope follower — fast to rise, slow to fall — and
it is why `up`/`down` exist. The second is the mount fade: without
`from`, a ramp has nowhere to start and simply *is* its first target,
which is right everywhere except at mount.

**They stop.** A register re-evaluates every frame *while it is
converging* and then goes quiet: `ease` settles a hair short of its
target (an exponential never quite arrives, and snapping would put a
visible step on the last frame), `ramp` lands its target exactly at the
end, `diff` goes to zero when nothing is moving, `integrate` pins at its
clamp. That clamp is required, not optional — a register's state is
saved with the program, and an unbounded accumulator is a corpse that
gets copied.

**Envelopes** are the other half of the family: a register chases a
target something else supplies, an envelope is a *shape an event sets
off*. Before them, "flash on hit" meant inventing a path on the plane to
hold a gate and a magic number for `ease` to fall from — two programs and
a number whose only job was being fallen from.

| op | does |
|---|---|
| `kick <attack> <decay>` | an **occurrence** in: rise to 1 over `attack`, fall to 0 over `decay`, stop |
| `adsr <a> <d> <s> <r>` | a **gate** in: rise, decay to `s` while it holds, release when it drops |

```rill
plane.events.hit | kick 20ms 400ms | set plane.ui.hit_flash
plane.events.impact | kick 10ms 300ms | mul 0.4 | set plane.camera.shake_amount
plane.events.hit | kick 20ms 400ms | shape out | set plane.ui.hit_flash
plane.input.key_c | adsr 10ms 80ms 0.7 400ms | set plane.audio.voice.gain
plane.sensors.gate.contacts | len | > 0 | adsr 200ms 400ms 0.6 2s | set plane.lights.alert.level
```

**A retrigger restarts from where it is, never from zero.** Hits arriving
during the fall are the normal case, not the edge case: a second hit
should brighten the flash, and an envelope that snapped to zero first
would put a black frame in the middle of it.

**The segments are straight lines, and a duration is how long the segment
takes** — `kick 20ms 400ms` is twenty milliseconds up and four hundred
down, whatever level it started from. Curve it with `shape`, as the third
line does: one word for one job, rather than a curve knob on every
envelope in the language.

**Both durations must be on one lane.** `kick 20ms 3f` is two consecutive
stretches of the same timeline measured in different units, and it is
refused, naming both ports. (`ease`'s `up` and `down` are alternatives
that never run together, so they do not have this problem.)

**`adsr` is the held one.** `kick` fires and is over; `adsr` watches a
**gate** — a boolean — and does what the gate does. It rises while the
gate is held, decays to `sustain`, stays there for as long as you like,
and releases when the gate drops. Four numbers in the order everyone
already knows: attack, decay, sustain, release. That order is a cultural
constant and rill does not get a vote.

**A held sustain costs nothing.** Nothing has to happen while a note is
held, so nothing is scheduled: the console's evaluation counter sits
still until the gate moves. An envelope holding for a minute is as cheap
as a constant.

**Letting go starts from where it is.** Release mid-attack and it falls
from halfway, not from the peak and not from the sustain — the same rule
as `kick`'s retrigger, and the same reason.

**A parameter change applies to the next segment; it never retimes the
one in flight.** Shorten `release` while a note is already falling and
*that* fall keeps the length it was given; the next one is short. A
release that retimed itself mid-fall would jump, and a jump is the thing
this whole family exists to avoid. The one place you can see the seam is
`sustain`, which is a *hold* rather than a segment and so follows its
port: move it during the decay and the decay finishes where it was told
to, then the hold picks up the new value.

**Movement costs every frame, and the cost is visible.** Anything
downstream of `clock`, `frame` or `lfo` re-evaluates every tick, and a
converging register does too until it stops. The console shows a cell
that ticks, with the node's live evaluation count beside it — the badge
says what could cost, the counter says what did.

---

## 6c. Arrays — several parts, one value

`[a, b, c]` — commas, matching records, because that is what a
no-priors reader writes. Arrays were already a value kind: `window`
emits one and `stats` consumes one, so the literal is the missing half
of something that existed rather than a new thing.

```rill
plane.world.hour | div 6 | floor | choose [0.2, 1, 1, 0.4] | set plane.render.grade.exposure
plane.stage.leg | choose [{x: 0, y: 3, z: 0}, {x: 2, y: 3, z: 1}] | set plane.lights.key.pos
plane.gpu.traversal_ms | window 10s | nth 0 | set plane.ui.oldest_sample
```

The first line is the point of the family. Written as control flow it
is four lines — two thresholds, two named streams, and a nested
`select` you read inside-out to learn that dusk is 0.4. Written as a
value, the bands are *in the value*: left to right, editable in place.

**An array is live**, exactly as a record is. An element that is a path
or a name is a wire, so a change to any element is a change to the
array.

**An array is not a buffer.** Values are immutable per tick: no element
assignment, no append, no loop over one. It is a value that happens to
have several parts.

| op | does |
|---|---|
| `nth <i>` | the i-th element, 0-based — the array rouses it |
| `choose <i> <array>` | the same, with the index piped — the index rouses it |
| `stats` | {max, mean, min, n, stddev} over a numeric array |
| `len` | how many elements — this is how you say *none* |

`nth` and `choose` are one computation with the hot port swapped, the
way `lfo` is `clock | wave` in one node. Which port is the rousing is a
real difference and it earns the second word.

**Out of range is an error.** Not a clamp, not a silent nothing — the
mistake is in the program, and a clamped index is a wrong picture
nobody is told about. So is a fractional index: rounding is a guess.
Both refusals name the index and the length.

Positions stay records: `[0, 2, 0]` does not coerce to `{x, y, z}`.
One thing, one spelling.

**Stepping through one, over time.** `nth` and `choose` pick; `step`
*walks*. Each rousing emits the next element:

```rill
plane.input.key_up | step [{x: 0, y: 3, z: 0}, {x: 2, y: 3, z: 1}] loop | set plane.lights.key.pos
plane.music.beat | step [60, 64, 67, 72] loop | notify plane.audio.note
plane.events.idle | step plane.ui.hints random seed 3 max 5 | set plane.ui.hint
```

There are two independent choices and one modifier, and they are written
as bare words:

| word | says |
|---|---|
| *(nothing)* | run through once, and the wave ends |
| `loop` | wrap round and keep going |
| `bounce` | turn round at each end |
| `reverse` | start at the end and walk down |
| `random seed <s>` | draw an element each time, **with replacement** |
| `shuffle seed <s>` | a fresh permutation each pass, no repeats within one |
| `max <n>` | stop after `n` emissions, whatever the rest says |

Order (`random`, `shuffle`, or in sequence) and end-behaviour (`loop`,
`bounce`, or stop) are separate, so `shuffle loop` is a fresh permutation
every pass and `loop reverse` cycles backwards forever. The combinations
that cannot mean anything **refuse at mount, naming both words** — two
orders, two end-behaviours, `reverse` or `bounce` on a random order, and
a `seed` with nothing to seed.

**The array is live, and the cursor carries.** If the list changes
mid-sequence the index stays where it is and clamps to the new length: it
does not restart. A sequence somebody is listening to should not jump
back to the top because a list got shorter.

**The cursor rides the dump**, so a restored program resumes its
sequence. A sequencer that started over on restore would be a different
instrument.

**An ended sequence is ended** — later rousings say nothing, even if the
list changes underneath. And because the output is a *value*, two
identical elements in a row are one write; `random` drawing the same
element twice looks like one draw downstream.

---

## 6d. Over arrays — bodies

Three operators take a **body**: a section, which is an operator with
ports left open.

```rill
plane.sensors.gate.contacts | keep (.armed) | set plane.ui.threats
plane.gpu.traversal_ms | window 5s | reduce (max) | set plane.ui.peak
plane.sensors.gate.contacts | map (.distance) | stats | set plane.ui.spread
```

| op | does | fills |
|---|---|---|
| `map <body>` | the body once per element, in order | 1 — the element |
| `keep <pred>` | the elements the predicate says true for | 1 — the element |
| `reduce <body> [init <v>]` | a left fold to one value | 2 — accumulator, then element |

**There is no new syntax.** `(clamp 0 1)` is the `clamp` operator with
its input left open; `(add)` leaves two open; `(.distance)` is the field
read with its input left open. A body closes over nothing — it is not a
lambda, and `{ }` is still a fan-out.

**The consumer says how many arguments it supplies**, so a section with
the wrong number of open ports is refused when you write it, naming the
operator and both counts:

> `'map' supplies 1 argument to its section, and this section leaves 2 ports open`

**`reduce` folds left.** The accumulator fills the first open port and
the element the second, so `[10, 3, 2] | reduce (sub)` is `(10−3)−2`.
With no `init` the first element seeds it; an empty array with no `init`
is an error, because there is no honest value to invent — zero is right
for `add` and wrong for `mul`.

**Most map is free.** Math already broadcasts elementwise, so
`window 10s | mul 2` *is* map. Reach for `map` when the body needs an
argument or is a field read.

**`keep` filters elements; `where` gates the stream.** Both apply to an
array-valued stream and they mean different things:

```rill
plane.gpu.traversal_ms | window 10s | where plane.debug.on   // the window, while debug is on
plane.gpu.traversal_ms | window 10s | keep (> 0)             // the readings above zero
```

That is why there are two words: one word dispatched by input kind would
have to guess between two independent questions.

**Order and shape.**

```rill
plane.sensors.gate.contacts | sort by (.distance) | first | .id | set plane.ui.nearest
plane.sensors.gate.contacts | sort by (.threat) desc | take 3 | set plane.ui.threats
plane.player.{health, mana} | window 10s | transpose | set plane.ui.vitals
plane.door.openness | along [{x: 0, y: 3, z: 0}, {x: 2, y: 3, z: 1}, {x: 4, y: 3, z: 0}] | set plane.lights.key.pos
```

| op | does |
|---|---|
| `sort [by <body>] [desc]` | **stable** — ties keep their input order. Without `by`, the elements are their own keys |
| `first` · `last` | the leading and trailing element; an empty array is **silence** |
| `take <n> [from <i>]` | at most `n` elements; a short array is **forgiven** |
| `transpose` | record of arrays ↔ array of records, self-inverse |
| `shuffle [seed <s>]` | seeded Fisher–Yates; seed defaults to 0, identical on every machine |
| `along <knots>` | travel a Catmull-Rom curve through the knots as `t` goes 0..1 |

**`take` forgives and `nth` does not**, and the difference is what each
one promises. `take 5` promises *at most five* — asking for the top three
of a list of two is sensible, and the answer is those two. `nth 5`
promises *the sixth element* — if there isn't one, the program asked for
something that does not exist. A count can be satisfied; a value cannot
be invented.

**`first` and `last` go quiet on an empty array**, and that is the same
rule from the other end. They name an *end*, not a position, and an empty
list simply has none — so the wave ends there, the way `where` ends one
it does not pass. No contacts at the gate is the ordinary state of a
sensor, and the ordinary state of the world should not spend a program's
error budget. `nth 0` on the same empty array still refuses, because
naming position zero is a claim that there is one.

**So absence is said by the count.** Nothing is invented and no sentinel
is smuggled in: if a downstream reader needs to know there were none, ask
`len` and say so.

```rill
plane.sensors.gate.contacts | sort by (.distance) | first | .id | set plane.ui.nearest
plane.sensors.gate.contacts | len | set plane.ui.contacts
```

Two lines, two questions. The first goes quiet when the gate is clear and
`plane.ui.nearest` holds its last answer; the second says `0`, which is
what the reader actually wants to branch on. `len` over `stats | .n` for
a length is the difference between asking a question and opening a
magic box.

**`along` passes through every knot** and clamps outside 0..1, because a
path has ends. Fewer than two knots is refused: one knot is not a path.
Knots may be records, and the curve then runs through each field.

**Ragged input is refused, never matched.** `transpose` names both sides
and both lengths rather than picking longest, shortest, or
cross-reference — the implicit matching rule is the most-complained-about
behaviour in every tool that has one.

---

## 6e. Contracts — `expect` and `match`

A shape on the wire, and the value either fits it or does not pass. An
assertion, not a branch. Two words, because there are two different
promises and you should say which one you are buying.

```rill
plane.sensors.gate.nearest | match {id: string, distance: number} | set plane.ui.threat
plane.render.grade | expect {exposure: number, contrast: number} | set plane.ui.grade
plane.window.samples | match [number] | stats | set plane.ui.load
```

| op | when it checks | on failure |
|---|---|---|
| `match <shape> [exact]` | **every value** | the wave dies, named: `match: '.distance' is string, not number` |
| `expect <shape> [exact]` | **once, at mount** | the mount is refused — the program does not come up |

`expect` costs nothing after mount, and the price of that is exact: it
is **not looking any more**. A value that arrives later and violates the
shape passes straight through. That is the contract, not a bug, and it
is why `match` is a separate word rather than a flag. `expect` never
degrades into a runtime check, and `match` never promotes into a
guarantee.

**Which one to reach for.** `expect` at the boundary with the plane,
where the value is there at mount and you want the mount to fail loudly
if the world isn't what you think. **A path whose shape can change wants
`match`** — that is a judgement about the path, and the operator will
not make it for you. If there is nothing at the path when the program
mounts, `expect` refuses the mount: there is no shape there to assert.

**The shape literal** is the record literal with type words as values:

```
{id: string, distance: number}
{pos: {x: number, y: number, z: number}, kind?: string}
[number]
```

The words are `number`, `boolean`, `string` and `any` — the same
vocabulary a mismatch prints, so what the language says back to you and
what you write are one language. `[T]` is an array of `T`, `?` marks a
field that may be absent, and `any` marks one that must be present but
may be anything.

**Shapes are open by default.** Extra fields pass. `exact` closes them —
and closes *every* record in the shape, not only the outermost.

Between them these are the author's half of the mismatch check: the
engine catches what you didn't anticipate; `expect` and `match` are
where you write down what you did.

---

## 6f. Events, levels, noise and space

```rill
plane.input.key_l | toggle | set plane.lights.key.on
plane.events.kill | tally | set plane.ui.kills
plane.world.light | below 0.2 0.3 | set plane.lights.street.on
noise 80ms | range 0.6 1 | set plane.lights.torch.level
plane.entities.raider.pos | within plane.gate.pos 10 | set plane.signals.alarm
```

| op | does |
|---|---|
| `pulse <period> [width <w>]` | a **value**: 1 for `width`, else 0, once per period. `width` defaults to a tenth |
| `once` | pass the first value, then deaf until remount |
| `toggle` | flip a boolean on each arrival |
| `tally` | running count of arrivals, as a value |
| `above <on> <off>` · `below <on> <off>` | boolean with **hysteresis**: the first number trips, the second releases |
| `noise <period> [octaves <n>] [seed <s>]` | smooth noise in 0..1 over fed time |
| `rand [seed <s>]` | a fresh value in 0..1 per rousing |
| `distance <a> <b>` · `within <a> <b> <r>` | over `record{x, y, z}` on both sides |

**Levels emit at mount; crossings do not.** `above`/`below` publish their level
straight away, `toggle` its initial `false`, `tally` its `0` — a program
that reads a level must have one to read on its first evaluation.
`dropped_below`, `rose_above` and `edge` do the opposite and stay silent
on their first observation, because a crossing nobody crossed is not an
event.

**Hysteresis is what stops a threshold chattering.** `above 0.3 0.2`
reads as "above 0.3, until below 0.2"; `below 0.2 0.3` as "below 0.2,
until above 0.3". A plain `< 0.3` on a noisy dusk reading switches the
lights on and off every frame; the band does not.

**The first number trips and the second releases — in both words.**
That is the whole reason `below` exists as its own word rather than as
`above` with the numbers swapped: neither spelling asks you to work out
which of its two numbers is the bigger one. Each word refuses the
other's order at mount, naming both numbers, so `below 0.3 0.2` does not
run and quietly behave like something.

**Which is why street lights want `below`.** They come on when it gets
*dark*, so the reading has to fall: `plane.world.light | below 0.2 0.3`.
This recipe was printed here as `above 0.3 0.2` with no `| not` — a
perfectly good hysteresis band that lights the street at noon — until a
reader trying to use it said so. `above 0.3 0.2 | not` is the same
answer the long way round; `below` is the sentence you meant.

**`pulse` is a value and `every` is an occurrence.** One node, one kind.
`pulse` is the rectangle you shape (`pulse 2s width 60ms | ease 10ms
down 300ms` is a flash with an attack and a decay); `every` is the
metronome you hang effects off.

**Noise is seeded, and the seed is the decorrelator.** Same seed and
period means the same stream, in every program and every replay — so two
torches on one seed flicker together, and three shake axes on seeds 1, 2
and 3 are independent. The default is 0, so the naive program is already
deterministic. `noise 80ms` flickers; `noise 20s` drifts.

A seed moves the *lattice* as well as the gradients on it. Without that,
every seed would pass through 0.5 together at each period boundary —
smooth noise is zero at its lattice points whatever its gradients are,
and seeds sharing a period would share those points.

**`rand` and `shuffle` share one generator; `noise` is a hash.** That is
two mechanisms for two questions: a generator produces a *sequence*, and
a hash answers "what is the value at this coordinate" the same way
forever.

---

## 7. Fields and the sigils

Four sigils name four rows of the world:

| sigil | question               | example      |
|-------|------------------------|--------------|
| `@`   | which one              | `@tom`       |
| `^`   | what kind              | `^soldier`   |
| `#`   | what's true of it now  | `#garrison`  |
| `$`   | what's in the air here | `$torchlight`|

All four are live (the tags campaign, 2026-08-25). `$` is the field
sigil below; the other three, in brief:

**`@` — which one.** `entity bind @tom prim tom` registers a placed
instance as an addressable entity (the ack says which id it became), and
`@tom.pos` is then a live path. The binding happens **at mount**: an
`@`-reference folds to its id-keyed row when your program mounts, and a
`@tom` registered *after* that — even under the same name — does not
reattach; remount to bind anew. Death is loud: `entity free` (or the
instance's deletion) publishes a certificate on `entities/despawned` —
who, what kind, where they last stood, why, and when — and the corpse's
tags are cleaned, each departure said. A dead binding's writes refuse on
the node, carrying the certificate's reason and frame.

**`#` — what's true of it now.** Membership is written with the `tag` /
`untag` sinks — one subject, **one tag per call** — and it is a *set*:
twice is once, and only an actual transition speaks. Every tag carries
three service leaves: `plane.tags.<name>.count` (live member count),
`.joined` and `.left` (occurrence mailboxes). Subscribe those freely;
subscribing the tag row itself while writing members is a cycle and is
refused. The muster at Ironwood is the canonical shape — thirty soldiers
joining a set that cannot drift, and a wall that counts members instead
of trusting a counter:

```rill
plane.signals.horn | tag @tom #in-courtyard
plane.tags.in-courtyard.count | rose_above 29 | notify plane.signals.wall_formed { n: 30 }
```

Unpiped, `tag @tom #garrison` fires once at tick 0 — the console
one-shot's shape. A tag can also be **derived**: `derive set #alert
^raider $alarm 0.5 0.4` (console) declares a maintainer — entities of
that kind carry the tag while the field at their position sits at or
above the ON level, and leave when it falls below OFF. The band between
is hysteresis: a signal held at the line joins once and never chatters.
One maintainer per tag, and it owns the tag over its population — a hand
tag below the band is withdrawn next frame and `left` says so; if you
want an override, you want a different tag (§6a has the row).

**`^` — what kind.** Engine-owned and read-only: today only `derive set`
takes one, naming the population.

A **field** is a scalar over space. A **cast** deposits into it:

```rill
plane.gate.enemy_count | rose_above 0
  | also { cast $alarm 1.0 radius 30 at plane.sensors.gate.pos decay 2s }
  | notify plane.defense.alerts
```

The model, in three sentences. Every caster owns a bag of deposits;
each deposit leaks away exponentially with its `decay` time constant
(defaulting from the channel), and unmounting the caster takes its
whole bag with it — *a scream dies with the screamer*. The value at any
point is the sum over everyone's deposits — so a relic casting
**negative** blight holds a blight field to zero along a moving contour
with no dispel mechanism at all: fields add. Nothing carries an
addressee — a cast is a shout, not a phone call, and whoever is there
to absorb it, absorbs it.

Channels are declared before anyone casts (in Matryoshka:
`chanarche set $alarm 0.01 2000 0` — epsilon, default decay in ms,
optional clamp). Mounting a caster whose channel doesn't exist refuses
the mount and names the node — and so does a coupling to an undeclared
tag, because a cast can be **coupled**: `to #tag` scopes who absorbs it.

```rill
plane.sighting | cast $dread 1.0 radius 30 at plane.sensors.gate.pos to #garrison
```

Coupling governs *entity* perception: an ear bound to an entity hears a
coupled deposit only while its entity carries the tag — and **tags are a
level, one frame wide**: gain the tag at tick n, hear from n+1; untag
and the reading drops next tick. A *post* (a placed ear) is the
operator's instrument and hears everything. A declared-but-empty tag
reaches no one, and that is not an error. Since a **derived** tag reads
each entity with its own ears too, a cast `to #alert` can feed `#alert`'s
own derivation — authored feedback, one step per frame.

**Reading a field always names a standpoint.** There is no bare
`$alarm` stream — *a cast names where it deposits; a read names where
it samples; neither has an implicit "here."* A standpoint is an **ear**:
a placed post reading through a declared *sampler* (point or area,
gradient on or off, a cadence, a clamp), publishing at
`sensors/<post>/$alarm`. An ear can instead be **bound to an entity**
(`ear bind tom-ear @tom war-ear`): the standpoint then *follows* the
entity — its registry mirror is the position — and the readings publish
at the entity's own surface, so `@tom.$alarm` reads what Tom hears. If
Tom despawns, the ear dangles (reads nothing, holds its last word); the
walk in §12's demo is exactly a camera-bound ear crossing a brazier's
glow. The plain placed form:

```rill
plane.sensors.hearth.$torchlight | mul 0.5 | add 0.5 | set plane.render.grade.exposure
```

That is the lamplighter: the lamp literally dims as the fire dies. Two
ears with different samplers may read the same field to different
numbers — that is instrument choice, not a second truth, the same way
two thermometers with different time constants disagree honestly.

---

## 8. Silence must be spoken

rill's propagation is push-based, so it can only report what
*happened* — never what stopped being. **Absence is unobservable by
construction.** Every absence you care about must be reified as a
presence:

- A death is a `despawned` occurrence carrying its own record — the
  corpse is removed, not cached. A program watching a dead thing's
  path would hold its last reading forever.
- A timeout is a message, not a reply that failed to arrive.
- **A sensor that has seen nothing says zero.** This is the sharp edge
  of §2's baselining: `rose_above 0` arms on its *first* observation,
  so an instrument whose first published value is `1` has silently
  eaten the very event it was mounted to catch. Every instrument in
  Matryoshka publishes its zero at declaration for exactly this
  reason. If you build a value path, publish its starting point.

---

## 9. What the parser refuses, and why

- **Cycles.** A program that writes a path it also subscribes to
  (exactly, or by segment prefix) is refused at mount, with the pair
  named — **even when the branches are unconnected**: the check is
  path-level, not graph-level, on purpose (§4 has the rule and the
  fix: split into two programs). Counters are why `inc` exists — a
  blind delta reads nothing, so it passes legitimately.
- **Self-feeding.** A program subscribing to its own published wires
  would re-trigger itself every frame; refused.
- **Unknown names.** A bare word is only ever a string literal when it
  binds a string-typed port (that is how console entity names work);
  anywhere else it is a loud error, never a guess.
- **Shape mismatches under broadcast.** Adding two records with
  different fields, or two arrays of different lengths, is refused at
  the node — with both sides named in the type-word vocabulary
  (`record{x, y, z}` and `record{x, y}`), the offending field named, and
  which side lacks it. There is no implicit intersection and no
  zip-to-the-shorter: picking a rule quietly is how a wrong answer
  learns to look like a right one.
- **`sample 5`.** Durations need units — the error names the fix.
- **`inc p 5` unpiped** would bind 5 as the rousing and silently
  default the amount; `by` is required so it can't.
- **Words:** `/` and `-` are name-interior when they join name
  characters (`render/grade/exposure`, `key-light` — one word each);
  `//` is always a comment because no word can contain two adjacent
  slashes.

Runtime failures are loud too: an operator error kills that wave,
counts against the node, and is published as an error occurrence at
`programs/<name>/errors` — watchable, so a supervisor rill can watch
the machines. A program exceeding its error budget (default 8 in 10s
of fed time) is unmounted whole, with a tally, and its death is said
on `rills/unmounted`. One deliberate non-error: `div` by zero is IEEE
±inf, because that is what division means.

---

## 10. `def` and `use`

`def` mints a reusable operator from a subgraph. Instances flatten at
parse — the graph never knows defs exist — and their internals stay
addressable for live tuning:

```rill
def healthbar(hp: number) = hp | clamp 0 100 | div 100
plane.player.health | healthbar | set plane.ui.hp
```

defs close over nothing: a `plane.…` path inside a def body is a parse
error — pass streams in through ports. That is what keeps a def
reusable across worlds.

`use` declares a plane-side alias, resolved entirely at parse:

```rill
use plane.render.grade as g
plane.hour | select plane.night_exposure plane.day_exposure | set g.exposure
```

Wait — `select` takes a *condition* first:

```rill
use plane.render.grade as g
plane.is_night | select plane.night_exposure plane.day_exposure | set g.exposure
```

Both versions above parse; only the second means what it says.
Selection is an operator, not syntax: **all branches exist as live
data, and one is chosen per tick.** Gating is `where`/`partition` over
streams, with predicate sections for the common case:

```rill
plane.damage | where (> 0) | inc plane.stats.hits 1
```

---

## 11. Recipes

**The sentinel** — sound the horn when the watch sees anyone:

```rill
plane.sensors.tower.visible_enemies | rose_above 0 | notify plane.signals.horn { kind: "approach" }
```

**The tally** — count events without reading what you write:

```rill
plane.signals.horn | inc plane.defense.alarms 1
```

**The cooldown guard** — act at most once per window, however often
you're told:

```rill
plane.orders.sally | cooldown 30s | notify plane.gate.open_order
```

**The brazier and the lamplighter** — a standing field, and a knob
that follows it (unmount the brazier and the lamp dims over four
seconds):

```rill
every 1f { cast $torchlight 0.8 radius 2.5 at plane.sensors.hearth.pos decay 4s }
```

```rill
plane.sensors.hearth.$torchlight | mul 0.5 | add 0.5 | set plane.render.grade.exposure
```

**The breathing exposure** — the founding example of tier 2, and the
sentence it started as:

```rill
lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure
```

**The fade that stops** — animate once at mount, then cost nothing:

```rill
once 1 | ramp 2s from 0 | set plane.render.grade.exposure
```

**The threshold that does not chatter** — a noisy reading into a switch:

```rill
plane.world.light | below 0.2 0.3 | set plane.lights.street.on
```

**The nearest threat** — a list into one answer, and the count that says
when there is none:

```rill
plane.sensors.gate.contacts | sort by (.distance) | first | .id | set plane.ui.nearest
plane.sensors.gate.contacts | len | set plane.ui.contacts
```

**The boundary contract** — refuse a malformed list where it arrives,
and pin what a program reads:

```rill
plane.sensors.gate.contacts | match [{id: string, distance: number}] | set plane.ui.threats
```

**Flash on hit** — an event into a shape, with nothing invented in
between:

```rill
plane.events.hit | kick 20ms 400ms | set plane.ui.hit_flash
```

**The camera shake** — three independent axes from one seed each:

```rill
{x: (noise 40ms seed 1), y: (noise 40ms seed 2), z: (noise 40ms seed 3)} | sub {x: 0.5, y: 0.5, z: 0.5} | mul 0.2 | set plane.camera.shake
```

**The supervisor** — a rill watching the machines:

```rill
plane.programs.gate-guard.errors | inc plane.ops.gate_guard_errors 1
```

**The vitals HUD** — one record, live:

```rill
plane.player.{health, mana} | set plane.ui.vitals
```

**The keep, in four programs** — the conjunction idiom, the terminal
sink, the split rule, the seed rule, the R3 stand-in, and every sigil
that exists, in thirteen lines. Four programs, not one file with
sections; sensor names per `ironwood.md`; the sally program reads what
the muster writes, so the value must be seeded (0) before it mounts.

```rill
// watchtower
plane.environment.ambient_light | < 0.25 as dark
plane.sensors.watchtower.visible_enemies | rose_above 0 as sighting
sighting | cast $alarm 1.0 radius 500 at plane.sensors.watchtower.pos decay 10s
sighting | where dark | set plane.keep.braziers.lit 1
```

```rill
// gatehouse
plane.sensors.gate.$alarm | rose_above 0.2
  | also { set plane.keep.gate.portcullis_target 0 }
  | set plane.keep.gate.drawbridge_target 1
plane.sensors.gate.nearest_distance | dropped_below 50 | notify plane.keep.archers.loose
```

```rill
// muster — `delay` stands in for the muster action until R3
plane.sensors.courtyard.$alarm | rose_above 0.2 | delay 90s | set plane.keep.garrison.formed 1
```

```rill
// sally port — its own program: it reads what muster writes
// (seed plane.keep.garrison.formed 0 before mounting)
plane.keep.garrison.formed | > 0.5 as wall_up
plane.sensors.gate.nearest_velocity | dropped_below 0.1 | where wall_up | set plane.keep.sally_port.open_target 1
```

## 12. The operator index

Every operator in the language, alphabetically. The other tables in this
manual teach; this one is for looking things up.

**Reading a line.** The middle column is the operator's **arity and port
order** — its ports in order, then its statics. `<name>` is an argument
slot; `[…]` means optional; a word before a slot is the keyword you write
with it (`ease 0.3 up 0.1`); `(…)` is a section body; `…` is variadic.
**The first port is what a pipe fills** — `plane.hp | above 0.3 0.2` binds
`in` from the pipe and writes only `on` and `off`. That is why so many
lines look longer than what you type.

It is arity, not surface syntax: a static is written where its own
section shows it (`set plane.a 1`, `cast $alarm radius 30 at <ref>`),
and it is listed after the ports here so the arity reads at a glance.

| operator | arity and port order | what it does |
| --- | --- | --- |
| `!=` | `!= <a> <b>` | Inequality. |
| `<` | `< <a> <b>` | Less than. |
| `<=` | `<= <a> <b>` | Less than or equal. |
| `=` | `= <a> <b>` | Equality — numeric across int/float, byte-wise otherwise. |
| `>` | `> <a> <b>` | Greater than. |
| `>=` | `>= <a> <b>` | Greater than or equal. |
| `above` | `above <in> <on> <off>` | Boolean with hysteresis: above `on`, until below `off`. Emits its level at mount. §6f |
| `abs` | `abs <in>` | Absolute value. |
| `add` | `add <a> <b>` | a + b. Broadcasts over a record or an array. |
| `adsr` | `adsr <in> <attack> <decay> <sustain> <release>` | Gate in, envelope out: rise, decay to `sustain` while the gate holds, release when it drops. A held sustain costs nothing. §6b |
| `along` | `along <t> <knots>` | Travel a smooth curve through the knots as t goes 0..1. Clamps outside; fewer than two knots refuses. §6d |
| `and` | `and <a> <b>` | Boolean and — the conjunction idiom's other half. §6a |
| `arm` | `arm [<in>] [<off>] [<on>]` | Latch gate, initially **open**: `off` closes it, `on` re-opens (`on` wins a tie). |
| `atan2` | `atan2 <y> <x>` | Angle of (x, y) in radians; `y` is the piped one — `dy \| atan2 dx`. |
| `below` | `below <in> <on> <off>` | Boolean with hysteresis, falling: below `on`, until above `off`. Emits its level at mount. §6f |
| `cast` | `cast <in> [<value>] at <at> [decay <decay>] <$channel> radius <radius> [to <#to>]` | Deposit into a field channel. `to` couples delivery to a tag's members. §7 |
| `ceil` | `ceil <in>` | Round toward +inf. |
| `changed` | `changed <in>` | An occurrence whenever the value actually changes. |
| `choose` | `choose <i> <of>` | `nth` with the index piped — `plane.time.band \| choose [0.2, 1, 0.6]`. §6c |
| `clamp` | `clamp <in> <lo> <hi>` | Clamp `in` to lo..hi. |
| `clock` | `clock` | Fed real seconds since mount, as a value. Source. §6b |
| `const` | `const <value>` | Emit a constant, once, at mount. |
| `cooldown` | `cooldown <in> <window>` | Pass one, then deaf for the window. §6 |
| `cos` | `cos <in>` | Cosine, radians. |
| `debounce` | `debounce <in> <quiet>` | Pass only after a quiet period; storms collapse to their last edge. §6 |
| `delay` | `delay <in> <by>` | Emit each occurrence `by` later. §6 |
| `diff` | `diff <in>` | Rate of change per second. Baselines silently; stops ticking at zero. §6b |
| `disarm` | `disarm [<in>] [<off>] [<on>]` | Latch gate, initially **closed**: silent until `on` arms it. |
| `distance` | `distance <a> <b>` | Distance between two positions; both `record{x, y, z}`. §6f |
| `div` | `div <a> <b>` | a / b (IEEE: division by zero yields ±inf). |
| `dropped_below` | `dropped_below <in> <threshold>` | Fires, with the value, on the way through. First observation baselines silently. §2 |
| `ease` | `ease <in> <tau> [up <up>] [down <down>]` | Chase the input with time constant `tau`; `up`/`down` make it asymmetric. Never snaps. §6b |
| `edge` | `edge <in>` | Fire on the false→true transition. §6f |
| `every` | `every <period>` | Occurrence source on a cadence: mount, then once per period. §6 |
| `exp` | `exp <in>` | e to the input. |
| `expect` | `expect [<in>] <shape>` | Assert a shape **once, at mount**; a mismatch refuses the mount. §6e |
| `first` | `first <in>` | The leading element. An empty array ends the wave silently. §6d |
| `floor` | `floor <in>` | Round toward −inf. |
| `fract` | `fract <in>` | Fractional part, always in 0..1 — `fract -0.25` is 0.75. |
| `frame` | `frame` | Fed frame count since mount, as a value. Source. §6b |
| `hold` | `hold <in> <for>` | Take a value, then ignore changes for `for`. §6b |
| `inc` | `inc <in> <by> <path>` | Add `by` to a plane path on each rousing — a blind delta, no read. §4 |
| `integrate` | `integrate <in> max <max>` | Running sum over fed time, clamped to ±max. The clamp is required. §6b |
| `keep` | `keep <in> (…)` | The elements a predicate says true for. Filters **elements**; `where` gates the stream. §6d |
| `kick` | `kick <in> <attack> <decay>` | One-shot envelope from an occurrence — rises to 1 over `attack`, falls to 0 over `decay`, stops. Retriggers from the current level. §6b |
| `last` | `last <in>` | The trailing element — `window 5s \| last` is the most recent reading. An empty array is silence. §6d |
| `latch` | `latch <in> <trigger>` | Sample-and-hold: emit the current `in` when `trigger` fires. |
| `len` | `len <in>` | How many elements. This is how absence is said once `first` goes quiet. §6c |
| `lerp` | `lerp <t> <a> <b>` | a + (b − a)·t; `t` is the piped one. Extrapolates where `range` clamps. §6b |
| `lfo` | `lfo <shape> <period> [phase <phase>]` | Modulation source in 0..1 — `lfo sine 4s`. Shapes: `sine tri saw square`. §6b |
| `log` | `log <in>` | Natural log (IEEE: zero yields −inf, a negative nan). |
| `map` | `map <in> (…)` | The body once per element, in order. Keeps the length. §6d |
| `match` | `match <in> <shape>` | Assert a shape on **every** value; a mismatch kills the wave. §6e |
| `max` | `max <a> <b>` | The larger of a and b. |
| `merge` | `merge <a> <b>` | Merge two records; b's fields win. |
| `min` | `min <a> <b>` | The smaller of a and b. |
| `mod` | `mod <a> <b>` | Floored modulo — the sign follows the divisor, so `-90 \| mod 360` is 270. |
| `mul` | `mul <a> <b>` | a × b. Broadcasts over a record or an array. |
| `noise` | `noise <period> [octaves <octaves>] [seed <seed>]` | Smooth noise in 0..1 over fed time. Stateless, seeded, bit-identical across machines. §6f |
| `not` | `not <a>` | Boolean not. |
| `notify` | `notify <in> [<value>] <path>` | Write an occurrence to a plane path — the same write as `set`, stating the intent. §4 |
| `nth` | `nth <in> <i>` | The i-th element, 0-based. Out of range is an **error**, never a clamp. §6c |
| `once` | `once <in>` | The first value, then deaf until remount. §6f |
| `or` | `or <a> <b>` | Boolean or. |
| `partition` | `partition <in> <pred>` | Route every arrival to exactly one of two outputs. §10 |
| `pi` | `pi` | 3.14159…, emitted once at mount. |
| `pow` | `pow <a> <b>` | a to the power b — `x \| pow 2` is x squared. |
| `pulse` | `pulse <period> [width <width>]` | **Value** source: 1 for `width`, else 0, once per period. `every` is the occurrence source. §6f |
| `ramp` | `ramp <in> <over> [from <from>]` | Tween linearly to each new target over `over`. `from` gives the first tween a start — the mount fade, and it stops. §6b |
| `rand` | `rand <in> [seed <seed>]` | A fresh value in 0..1 per rousing. §6f |
| `range` | `range <t> <lo> <hi>` | Map 0..1 onto lo..hi, **clamping** outside it. §6b |
| `record` | `record …` | Record construction — the taught spelling is `{field: stream, …}`. §7 |
| `reduce` | `reduce <in> [init <init>] (…)` | Left fold: accumulator into the body's first open port, element into the second. §6d |
| `rose_above` | `rose_above <in> <threshold>` | Fires, with the value, on the way through. First observation baselines silently. §2 |
| `round` | `round <in>` | Round to nearest. |
| `sample` | `sample <in> <period>` | At most one emission per period; the latest value wins. §6 |
| `select` | `select <cond> <a> <b>` | cond ? a : b — all branches exist, one is chosen per tick. §6a |
| `set` | `set <in> [<value>] <path>` | Write to a plane path. Piped, the input is the rousing and `value` is what is written. §4 |
| `shape` | `shape <t> <curve>` | Ease a 0..1 value into 0..1. Curves: `linear smooth in out inout`. §6b |
| `shuffle` | `shuffle <in> [seed <seed>]` | Seeded Fisher–Yates; `shuffle \| take 3` is three at random. §6d |
| `sign` | `sign <in>` | −1, 0 or 1 (nan stays nan). |
| `sin` | `sin <in>` | Sine, radians. |
| `sort` | `sort <in> [desc] [by (…)]` | **Stable** sort; ties keep input order. Without `by`, elements are their own keys. §6d |
| `sqrt` | `sqrt <in>` | Square root (IEEE: a negative yields nan). |
| `stats` | `stats <in>` | `{max, mean, min, n, stddev}` over a numeric array. §6c |
| `step` | `step <in> <of> [seed <seed>] [max <max>] [loop] [bounce] [reverse] [random] [shuffle]` | Step sequencer: each rousing emits the next element. Runs once unless told otherwise. §6c |
| `sub` | `sub <a> <b>` | a − b. Broadcasts over a record or an array. |
| `tag` | `tag <in> <@subject> <#tag>` | Add a subject to a tag. Idempotent; one tag per call. §7 |
| `take` | `take <in> <n> [from <from>]` | At most `n` elements. A short array is **forgiven** — `nth` past the end is not. §6d |
| `tally` | `tally <in>` | Running count of arrivals, as a value. Emits 0 at mount. §6f |
| `tan` | `tan <in>` | Tangent, radians. |
| `tap` | `tap <in> <label>` | Debug passthrough: log the value to the host's log bus. |
| `tau` | `tau` | 2π, a whole turn, emitted once at mount. |
| `throttle` | `throttle <in> <window>` | First occurrence passes, the rest are eaten for the window. §6 |
| `toggle` | `toggle <in>` | Flip a boolean on each arrival. Emits its initial `false` at mount. §6f |
| `transpose` | `transpose <in>` | Record-of-arrays ↔ array-of-records, self-inverse. Ragged input refuses. §6d |
| `untag` | `untag <in> <@subject> <#tag>` | Remove a subject from a tag. Idempotent; one tag per call. §7 |
| `wave` | `wave <t> <shape> <period>` | Shape piped time into 0..1 — `clock \| wave sine 4s`. Pure. §6b |
| `where` | `where <in> <pred>` | Pass arrivals while the predicate is true; otherwise silence. §6a |
| `window` | `window <in> <span>` | Rolling buffer over fed time, emitted as an array. §6c |
| `within` | `within <a> <b> <r>` | Is a within r of b? Both `record{x, y, z}`. §6f |

Two operators are registered and are not in this list, because you never
write them: `array` is what `[a, b, c]` builds, and `project` is what
`.field` reads. They are the substrate under a spelling you already have.
