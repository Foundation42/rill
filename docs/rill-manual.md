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

(Two blocks, not one, and the parse gate is why: as a single program the
second line would *subscribe* to the horn the third line *notifies* —
the cycle check refuses exactly that. The gatekeeper caught the manual's
own first draft doing it, which is the kind of proofreading a manual
about a refusing parser deserves.)

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
- **No `as` escapes a block.** Bind the stream before the block.
- A branch that ends still holding a value gets a warning — end a
  branch with a sink, or drop the tail.

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

## 7. Fields and the sigils

Four sigils name four rows of the world:

| sigil | question               | example      |
|-------|------------------------|--------------|
| `@`   | which one              | `@tom`       |
| `^`   | what kind              | `^soldier`   |
| `#`   | what's true of it now  | `#garrison`  |
| `$`   | what's in the air here | `$torchlight`|

(`@`, `^`, `#` arrive with the entity registry and tag store; `$` is
live today.)

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
the mount and names the node.

**Reading a field always names a standpoint.** There is no bare
`$alarm` stream — *a cast names where it deposits; a read names where
it samples; neither has an implicit "here."* A standpoint is an **ear**:
a placed post reading through a declared *sampler* (point or area,
gradient on or off, a cadence, a clamp), publishing at
`sensors/<post>/$alarm`:

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
  (exactly, or by prefix) is refused at mount, with the loop named.
  Counters are why `inc` exists — a blind delta reads nothing, so it
  passes legitimately.
- **Self-feeding.** A program subscribing to its own published wires
  would re-trigger itself every frame; refused.
- **Unknown names.** A bare word is only ever a string literal when it
  binds a string-typed port (that is how console entity names work);
  anywhere else it is a loud error, never a guess.
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
