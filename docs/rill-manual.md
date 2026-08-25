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
| `ramp <over>` | tween linearly to each new target over `over` |
| `hold <for>` | take a value, then ignore changes for `for` |
| `diff` | rate of change per second |
| `integrate max <m>` | running sum over fed time, clamped to ±m |

```rill
plane.sensors.hearth.heat | ease 400ms | set plane.lights.hearth.level
plane.render.grade.exposure_target | ramp 2s | set plane.render.grade.exposure
plane.sensors.gate.nearest_distance | diff | dropped_below -2 | notify plane.signals.charge
plane.field.rumble | abs | ease 20ms down 400ms | set plane.ui.vu
```

The last one is the envelope follower — fast to rise, slow to fall — and
it is why `up`/`down` exist.

**They stop.** A register re-evaluates every frame *while it is
converging* and then goes quiet: `ease` settles a hair short of its
target (an exponential never quite arrives, and snapping would put a
visible step on the last frame), `ramp` lands its target exactly at the
end, `diff` goes to zero when nothing is moving, `integrate` pins at its
clamp. That clamp is required, not optional — a register's state is
saved with the program, and an unbounded accumulator is a corpse that
gets copied.

**Movement costs every frame, and the cost is visible.** Anything
downstream of `clock`, `frame` or `lfo` re-evaluates every tick, and a
converging register does too until it stops. The console shows a cell
that ticks, with the node's live evaluation count beside it — the badge
says what could cost, the counter says what did.

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
