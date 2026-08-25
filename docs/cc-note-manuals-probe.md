# Note for CC — probe round on the manuals (2026-08-25)

Context you don't have: Chris ran `ironwood.md` and `rill-for-agents.md`
past a third-party reviewer with no priors and asked them to write the
rill for the scenario. The output was roughly 80% right on a first
attempt, which says the agent manual works. The remaining 20% is one
finding that appeared twice, two smaller residues, and two confabulations
in regions the spec is silent on. Nothing here touches the parser or the
runtime — it is all manual work, plus one new section Chris wants. All of
it is Chris-stamped unless marked.

---

## 1. What transferred (leave alone)

`//` comments; standpoint reads (`plane.sensors.gate.$alarm` — the
unlearn landed); the full `cast` grammar including keyword ports and
`decay`; no `if`; no arrows; effects as sinks; crossings as events;
`notify` for orders. The reviewer asked about `chanarche` rather than
inventing a declaration, so "declared world-side" transferred too.

## 2. The finding — block-as-scope survived block-as-fan-out

Twice, to express a conjunction, the reviewer opened a **new subscription
inside a block**:

```
plane.sensors.watchtower.threat_visual | rose_above 0.0
  | also {
      plane.environment.ambient_light
      | dropped_below 0.25
      | set plane.keep.braziers.lit 1.0
    }
```

("when the threat rises, and it's dark" — and again for "wall formed, and
raiders stalled"). Refused at the branch head, correctly: a branch begins
with an operator and is fed the in-flowing value; it has no sources of its
own. Unlearn #6 told them a block isn't *ordered*; they heard that and
still treated `{ }` as a scope that can open inputs. Folded inside it is
a second mistake: `dropped_below 0.25` as "is it dark" — a crossing used
as a state test. Even if the branch could open a source, the braziers
would only light if dusk fell *after* the sighting.

The honest spelling names the condition as a stream and gates with
`where`:

```rill
plane.environment.ambient_light | < 0.25 as dark
plane.sensors.watchtower.visible_enemies | rose_above 0 as sighting
sighting | cast $alarm 1.0 radius 500 at plane.sensors.watchtower.pos decay 10s
sighting | where dark | set plane.keep.braziers.lit 1
```

That is **the conjunction idiom**, and neither manual has it. Every rill
program past the trivial needs it.

**Candidate unlearn #7 — a block has no sources of its own.** Recorded,
not promoted: by the promotion criterion this needs to survive a
correction round. Land the recipe and the table rows below, re-probe, and
promote if the residue persists.

## 3. Two smaller residues

- **All-`also`, no terminal sink.** Every effect rode `also { }` and no
  main stream ended in a sink — the tails all hang. Legal, but it is the
  "effects branch off" lesson over-learned into "the main stream must
  never carry an effect." The manual's own example ends in `notify`; the
  reviewer didn't take it. One line in the `also` section: *the last
  effect is the main stream's sink.*
- **One file, one program.** The reviewer wrote three commented
  "sections" in one file. Section 3 writes `shield_wall_formed` and then
  subscribes to it, so as one program the path-level check refuses the
  whole file with the loop named. The "split it into two programs" rule
  we sent you this afternoon has its first customer before it has landed.
  Say explicitly: a file is one program; sections are comments, not
  boundaries.

## 4. Where the spec is silent (confabulated in the unpinned region)

- **The muster.** "Within 90s–2m" became `delay 90s | set
  shield_wall_formed 1.0` — a timer and a flag standing in for what R2
  says is an *action* with duration and a completion occurrence. The
  reviewer had no action vocabulary because the manuals have none yet.
  That is the R3 convention pass; this is a clean data point for what it
  must say. Until R3, both manuals get one pointer line: *actions
  (muster, loose, winch) with completion occurrences are pending; a
  `delay` is a stand-in and should be labelled as one.*
- **Sensor field names.** `threat_visual`, `raider_range`,
  `raider_velocity` are invented where `ironwood.md` says
  `visible_enemies` / `nearest_distance`. Normal — names get pinned in R3.
  Not a manual fix, but the worked example in §6 below should use the
  doc's names so they start propagating.

## 5. New section for the human manual — "Thinking in rill" (Chris's ask)

Chris wants an idiomatic section in `rill-manual.md`: how to think in
rill, as *when you think this → write this* examples. It sits after
sinks/blocks and before recipes. Suggested opener, then the table; every
right-hand cell is a ```rill block so the gate parses it.

> A rill is a standing order, not a procedure. You don't run it; you post
> it, and it holds until unmounted. Three questions of any line: **what
> rouses it** (when), **what flows** (what), **where does the wave end**
> (the sink). If you can't answer all three, you are still thinking in
> steps.

| when you think… | write… | because… |
|---|---|---|
| "if X, do A" | `X \| <crossing or comparator> \| A` | conditions flow; the threshold *is* the if |
| "when X, and Y holds" | `Y \| < t as y_ok` … `X \| rose_above 0 \| where y_ok \| A` | name the condition as a stream, gate with `where`; a block can't open a source |
| "is it dark?" vs "did it get dark?" | `< 0.25` vs `dropped_below 0.25` | a comparator is a state; a crossing is an event, fired once on the way through |
| "do A, then continue to B" | `X \| also { A } \| B` | side effects branch; the last effect is the main sink |
| "do A then B" (ordered) | `X \| A' \| B'` as one pipeline, or two branches if independent | a block is fan-out; sequence is a pipe |
| "count how many times" | `X \| inc plane.n 1` | a blind delta reads nothing, so it's the one write that can't cycle |
| "remember that X happened" | subscribe to the occurrence that says so | a flag is lingering state standing in for an event; if the state is real, the thing that owns it publishes it |
| "wait until X finishes" | the action's completion occurrence (R3); until then a labelled `delay` | rills express intent; the engine resolves the doing and *says* when it's done |
| "every N seconds…" | `every Ns { … }` | the metronome; fires at mount, never bursts after a hitch |
| "nothing has happened for 5s" | `plane.heartbeat \| debounce 5s \| notify plane.signals.stale` | absence is unobservable; a temporal op gives silence a voice |
| "read the field here" | an ear at a standpoint: `plane.sensors.<post>.$chan` | a read names where it samples; a rill has no here |
| "cast from where I am" | `cast … at <a position you can read>` | a cast names where it deposits; a rill has no here |
| "make the gate close" | `set plane.keep.gate.drawbridge_target 1` | intent to an actuator target; physics is the engine's |
| "this program does three things" | three programs, or one with named streams — never one file with sections | a program may not both write and subscribe to one path, even in unconnected branches |

(Check the `debounce` row against the actual op semantics before it
ships — the intent is "fire once, 5s after the last heartbeat"; if
`debounce` isn't that, pick the op that is.)

## 6. Worked example — the keep in four programs

Add to the recipes, gated. Sensor names per `ironwood.md`; the muster's
`delay` is labelled as the R3 stand-in it is. Note the seed: the sally
program reads `formed` from tick 0, so the value must exist before mount.

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
// seed plane.keep.garrison.formed 0 before mounting
plane.keep.garrison.formed | > 0.5 as wall_up
plane.sensors.gate.nearest_velocity | dropped_below 0.1 | where wall_up | set plane.keep.sally_port.open_target 1
```

One thing this example needs from the engine, not the manual: the
watchtower casts `at plane.sensors.watchtower.pos`, and today only ears
publish `pos`. Sight posts should publish it too — where a reading is
from is part of the reading, for sight as much as sound. Small, and it
unblocks the example being real.

## 7. Agent manual changes

- The conjunction recipe (§2's four lines) as a named recipe.
- Two rows for the wrong → right table:
  - `also { plane.x \| … }` — a branch can't open a source → name the
    stream, gate with `where`.
  - `dropped_below t` as "is below t" — a crossing is not a state →
    `< t`.
- The terminal-sink line beside unlearn #5.
- "One file is one program" beside the cycle rule.
- The R3 pointer line from §4.
- Unlearn #7 recorded as a candidate in a comment, not numbered, until
  the re-probe.

## 8. Landing order

1. Human manual: the "Thinking in rill" section (§5), the worked example
   (§6), the `also` terminal-sink line, one-file-one-program.
2. Agent manual: §7.
3. Sight posts publish `pos` (engine, small).
4. Re-probe with the same reviewer; promote #7 or drop it on the result.

The keep-in-four-programs is the through-line: it exercises the
conjunction idiom, the terminal sink, the split rule, the seed rule, the
R3 stand-in, and every sigil that exists — in thirteen lines.
