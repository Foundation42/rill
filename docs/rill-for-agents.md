# rill, for agents

*A reference for language models and other agents writing rill. The
human manual is `rill-manual.md`; the normative spec is `rill-spec.md`.
Every ` ```rill ` block here is parsed by a test.*

You were trained on imperative languages. rill is not one, and the
probe that shaped this document showed exactly where a fluent reader's
intuition invents the wrong language. Read the unlearns first; they are
not style advice, they are the places you will otherwise write programs
that parse in your head and not in the parser — or worse, parse in both
and mean nothing.

Here is a real program, mounted in the engine right now, that dims a
lamp as a fire dies:

```rill
every 1f { cast $torchlight 0.8 radius 2.5 at plane.sensors.hearth.pos decay 4s }
```

```rill
plane.sensors.hearth.$torchlight | mul 0.5 | add 0.5 | set plane.render.grade.exposure
```

Two statements, two programs. The first deposits warmth into a field
every frame; each deposit leaks away with a four-second time constant.
The second reads the field at a standpoint and follows it into an
exposure knob. Unmount the first and the lamp dims over four seconds —
nothing decays it, nothing animates it, nothing polls it. The arithmetic
of the field *is* the behavior. Every unlearn below is visible in those
two lines; refer back to them.

---

## 0. The unlearns

1. **No `if`.** There are no exec-pins and no imperative blocks.
   Conditions flow: `where`, `select`, `partition`, thresholds. The
   lamp has no `if brazier_lit` — the reading is the condition.
2. **No revocation.** Capabilities are static — checked once at mount.
   A gate stays shut under alarm because a rill flows 0 to the winch,
   not because anyone's write licence was stripped mid-raid.
3. **No lingering state standing in for events.** Absence is said.
   Death is an occurrence carrying its own record; the corpse is
   removed. A path that stops updating is indistinguishable from a
   value standing still — if you care about an absence, something must
   *publish* it.
4. **No arrows.** There is no `->`, no `=>`, no trigger-fires-command.
   A threshold is a value that flows onward. Effects are sinks reached
   by flow.
5. **Effects don't ride the stream.** A `set`/`notify`/`inc`/`cast` is
   a sink: the wave ends there, nothing flows through it.
   `x | set p | tap t` does not parse. Side effects branch off with
   `also { … }`; the main stream carries values only — and **the last
   effect is the main stream's sink**: a chain of side-branches whose
   tail just hangs has over-learned this lesson.

<!-- candidate unlearn #7 (recorded, not promoted — awaits the
     re-probe): a block has no sources of its own. A branch cannot
     open a subscription; it is fed the block's source and nothing
     else. Promote if the residue survives the correction round. -->
6. **A block is a fan-out, not a body.** `every 1f { … }` is not a
   loop body. Statements in a block are parallel branches with no
   order between them, each fed the same source. Sequence is spelled
   as a pipeline or not at all.

All six point one direction: away from mutable shared state and
imperative control flow. The distance between your first guess and the
actual spelling *is* the design.

---

## 1. The mental model, one page

- A program is a **flat graph** of operators, **mounted** on a plane
  of named values. Mounting runs tick 0 immediately, effects included.
  Remount = restart, never resume.
- Any `plane.…` path anywhere is a **subscription**. Reads are
  subscriptions; there is no polling and no imperative read.
- Each tick: fed deltas mark subscribed slots fresh → dirty nodes
  evaluate once, in order → writes land through the host's drain
  (casts dispatch at eval, straight into the host's cast inbox).
  **Parse order is topological order**: names are single-assignment,
  defined-before-use.
- **Values** compare-and-suppress (same bytes = silence). **Occurrences**
  always propagate (twice is twice). Threshold ops convert value → 
  occurrence on the crossing, strictly, and baseline silently on first
  observation.
- **Time is fed**, never read: durations are `5s/250ms/2m` (real lane)
  or `3f` (frame lane), never converted. Temporal ops wake through a
  timer wheel. Replay = same feed, bit-identical results.
- **Determinism is structural.** No wall clocks, no randomness, stable
  order. If you need randomness or now(), the host must feed it as
  data.
- A runtime operator error kills that wave, counts against the node,
  publishes at `programs/<name>/errors`. Budget exhausted (8 per 10s
  fed, default) ⇒ the program is unmounted whole, and the unmount is
  said on `rills/unmounted`.

---

## 2. Grammar, terse

```
program   := statement*
statement := chain | "def" … | "use" plane-path "as" name
chain     := expr block* ( "|" (opcall | "also" "{" branch* "}") )* ( "as" name ("," name)* )?
branch    := opcall ( "|" opcall | alsoblock )*        // head MUST be an operator
expr      := opcall | plane-path | literal | record | name
opcall    := opname arg*
arg       := literal | plane-path | name(.field)* | record | (op …) | kwarg
kwarg     := portname ":" value          // and keyword ports: `radius 12 at <ref>`
record    := "{" field ":" value ("," …)* "}"
```

Word rules: `_` and alphanumerics are name characters; `/` and `-` are
name-interior when they **join two name characters**
(`render/grade/exposure` and `key-light` are one word each); `//` is
always a comment (to end of line); `$name` is one token (a field
channel, sigil included). A bare word binding a *string-typed* port
becomes a string literal (console entity names); anywhere else an
unknown word is a loud error. `"…"` quotes strings; `#`, `@`, `^` are
reserved sigils not yet in the grammar.

A line beginning with `|` continues the statement above. A statement
head followed by `{ … }` fans out into the block's branches (the
`also` desugar, at the head). Predicate sections — `where (> 0)` —
mirror the consumer's primary input into a comparison.

**No array/vec literals.** A position is read from a path (dot-form is
live: a moving `at` re-aims without re-rousing).

---

## 3. The operator table

| family | operators |
|---|---|
| flow | `select cond a b` · `lerp a b t` · `where in pred` · `partition in pred` → pass/fail · `changed` · `latch in trigger` |
| events | `dropped_below in t` · `rose_above in t` (strict crossings, silent first baseline) · `edge` (false→true) |
| temporal | `sample in period` · `debounce in quiet` · `throttle in w` · `cooldown in w` · `window in span` → array · `stats` → record · `delay in by` · `every period` (source; fires at mount then per period; skip-forward after gaps) · `arm`/`disarm in off on` |
| math | `add sub mul div min max` · `clamp in lo hi` · `abs floor round` · `= != < <= > >=` |
| records | `{f: x, …}` · `.field` projection · `merge a b` |
| sinks | `set <path> [value]` · `notify <path> [value]` · `inc <path> <by>` · `cast <$chan> [value] radius <r> at <pos> [decay <d>]` |
| util | `const <lit>` · `tap <label>` (log passthrough) |

The sink shape: **port 0 is the rousing** (when); a bound value is the
payload (what). Piped = write what's flowing; bound = write this,
because something flowed. A change in a non-rousing port alone is
never a write. `inc`'s rousing carries no payload (`by` is required
and is the amount). `cast`'s `at`/`decay` are **keyword ports** — the
word introduces the value — and `radius` is a keyword static; none of
the three bind positionally.

Hosts inject their own verbs (in Matryoshka, the whole console: 
`volume set`, `light place`, `camera path`, …). Two-word verbs resolve
first, so `sound play` is one operator.

---

## 4. Fields, in agent terms

- **Channel** (`$name`): declared world-side before any caster mounts
  (`chanarche set $alarm <epsilon> <decay_ms> [clamp_lo clamp_hi]`).
  A mounted program whose `cast` names an undeclared channel is
  **refused at mount**, node named.
- **`cast`** deposits `{pos, amplitude, radius, decay}` into *your*
  bag. Amplitude is signed (negative casts are how reversal works —
  fields add; there is no dispel). Unpiped, the amplitude is both
  rousing and payload ⇒ **one deposit at tick 0** — a standing caster
  needs `every 1f` in front. Your bag dies with your unmount.
- **Reading names its standpoint.** `$alarm` alone is a parse error
  (the message tells you the spelling). Read an ear's published value:
  `plane.sensors.<post>.$alarm`, with `….$alarm.grad` and
  `….$alarm.scan_ns` beside it and `….pos` for where the post stands —
  sibling segments, so "one channel, several readings" is visible in
  the spelling and nothing lexes like a castable channel. Ears publish zero at
  binding, so your `rose_above` baselines correctly.
- Deposits and readings are deterministic in fed time and stay out of
  the log; replay re-derives them.

---

## 5. Wrong spelling → right spelling

| you will want to write | why it's wrong | write instead |
|---|---|---|
| `if plane.hp < 20 { … }` | no `if`; conditions flow | `plane.hp \| dropped_below 20 \| …` |
| `plane.hp < 20 -> notify …` | no arrows | `plane.hp \| dropped_below 20 \| notify …` |
| `x \| set plane.a \| tap t` | effects end waves | `x \| also { set plane.a } \| tap t` |
| `x \| untag #a \| tag #b \| follow` | effect pipeline = imperative sequencing | one branch per effect, `also { }` each |
| `every 1f { step1; step2 }` expecting order | a block is fan-out | pipeline the sequence, or accept parallel branches |
| `plane.x \| add 1 \| set plane.x` | reads what it writes — cycle, refused | `<rousing> \| inc plane.x 1` |
| one file, three commented "sections" | one file is ONE program; a section writing a path another subscribes to refuses the whole file | three programs (a program may not both write and subscribe to one path, even unconnected) |
| `also { plane.y \| … }` | a branch can't open a source — it is fed the block's source and nothing else | name the condition as a stream, gate with `where` (the conjunction idiom, §5a) |
| `dropped_below t` as "is below t" | a crossing is an event, not a state — it fires once, on the way through | `< t` (a comparator is the state) |
| `inc plane.n` (no `by`) | the amount would default silently | `inc plane.n 1` |
| `$alarm \| rose_above 0.5 \| …` | a field read names its standpoint | `plane.sensors.gate.$alarm \| rose_above 0.5 \| …` |
| `cast $alarm 30` for radius 30 | payload-or-radius is ambiguous | `cast $alarm radius 30 at <ref>` |
| `sample 5` | durations carry units | `sample 5s` (or `5f` if you mean frames) |
| `x \| mul 2 { set plane.a }` | blocks live at the head; mid-chain is `also` | `x \| mul 2 \| also { set plane.a }` |
| `as $x` / `def $f(…)` | sigils name store rows, never streams/ops | pick an unsigiled name |
| waiting for a path to vanish | absence is unobservable | subscribe to the occurrence that says so |

---

## 5a. The conjunction idiom

"When X, and Y holds" — name the condition as a stream, gate with
`where`. A block cannot open a source, and a crossing cannot stand in
for a state (the braziers below would otherwise only light if dusk
fell *after* the sighting):

```rill
plane.environment.ambient_light | < 0.25 as dark
plane.sensors.watchtower.visible_enemies | rose_above 0 as sighting
sighting | cast $alarm 1.0 radius 500 at plane.sensors.watchtower.pos decay 10s
sighting | where dark | set plane.keep.braziers.lit 1
```

Every non-trivial program needs this shape.

**Actions are pending (R3).** Things that take time and complete —
muster, loose, winch — get a vocabulary of actions with completion
occurrences in R3. Until then a `delay` standing in for one should be
labelled as the stand-in it is.

---

## 6. Verifying your program

- **Parse errors are loud and located** (line, col, and usually the
  fix). If the host accepted your mount, the graph is real.
- **Warnings** mean "well-formed and probably not what you meant" —
  today: a block branch that discards a value.
- `tap <label>` logs values to the console bus; rate-limit it
  yourself (`x | sample 1s | tap x`) — a debug instrument that
  secretly drops can't be trusted, so `tap` never does.
- `probe <path>` (console) reads any live wire —
  `programs/<name>/<node>/out/out` addresses every internal edge.
- `programs[]` in the schema carries per-node eval/error counters and
  provenance; `programs/<name>/errors` is the error mailbox;
  `rills/unmounted` is the death certificate channel.
- Expect **one frame of latency** across the plane: your write lands
  this frame; a program reading it rouses next frame. Instruments
  (sensors, ears) add their declared cadence on top.

When a value surprises you, suspect the instrument first — cadence,
dwell, clamp, standpoint — before the field, and the field before the
evaluator.
