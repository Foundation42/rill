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
always a comment (to end of line); all four sigils lead one
token each, sigil included: `$alarm` (field channel), `@tom` (entity
subject), `#garrison` (tag), `^raider` (archetype — engine-owned; only
`derive set` takes one). A bare word binding a *string-typed* port
becomes a string literal (console entity names); anywhere else an
unknown word is a loud error with a sigil-specific correction. `"…"`
quotes strings.

**`@name.field` reads bind at MOUNT** (host-side): the reference folds
to the entity's id-keyed row when the program mounts, the ack says
which id, and a re-registered name does NOT reattach — remount to bind
anew. A stale binding's `tag`/`untag` refuses on the node, against the
error budget, carrying the despawn certificate's reason and frame.

A line beginning with `|` continues the statement above. A statement
head followed by `{ … }` fans out into the block's branches (the
`also` desugar, at the head). Predicate sections — `where (> 0)` —
mirror the consumer's primary input into a comparison.

**Array literals** are `[a, b, c]`, commas, matching records — and live
the same way: an element that is a path or a name re-evaluates the
array. Elements are literals, paths, names, records, or arrays. An
array is **not a buffer**: no element assignment, no append, no loop.
`[0, 2, 0]` does not coerce to a position — positions stay records, and
a position is still read from a path (dot-form is live: a moving `at`
re-aims without re-rousing).

**Math broadcasts.** `add sub mul div min max`, the completions, the
comparators and `and`/`or`/`not` are **elementwise over records and
arrays**; a scalar broadcasts to every element. So
`@player.pos | add {x: 0, y: 2, z: 0}` is one line, `window 10s | mul 2`
IS map, and `[1, -2, 3] | > 0` is `[true, false, true]`.

The rules, and they REFUSE rather than guess:

- record ⊗ record needs the **same field set** — no implicit
  intersection;
- array ⊗ array needs **equal length**, and the refusal names both;
- a record and an array together have no elementwise meaning;
- nesting recurses; a non-numeric leaf is named by its path
  (`mul: the left side is string, not a number at .inner.name`).

`=` and `!=` do **not** broadcast, on purpose: `<` has no meaning on a
whole record so elementwise is its only reading, while `=` already has
an exact whole-value meaning and broadcasting would replace a good
answer with a different one.

Every refusal names the operator, both sides, and where — that is a
gated property, not a hope.

**Movement ticks, and it stops.** `clock`/`frame`/`lfo` re-evaluate every
tick for as long as time is fed, so everything downstream of them does
too — that is the cost of animation and the console shows it (a badge
from `OpDef.ticks`, the node's live eval count beside it). A register
ticks only *while converging* and then goes quiet: `ease` settles inside
epsilon of its target and never snaps to it; `ramp` has an end and emits
the target exactly on its last frame; `diff` goes to zero when nothing
moves; `integrate` pins at its clamp. `hold` never ticks at all.

Epochs are per-program: "since mount" means since *this* program mounted,
and the epoch is saved with it, so a restored program continues rather
than restarting.

```rill
lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure
plane.sensors.gate.nearest_distance | diff | dropped_below -2 | notify plane.signals.charge
```

---

## 3. The operator table

| family | operators |
|---|---|
| flow | `select cond a b` · `lerp t a b` (t piped: `s \| lerp 0.5 1.5`) · `and`/`or`/`not` · `where in pred` · `partition in pred` → pass/fail · `changed` · `latch in trigger` |
| events | `dropped_below in t` · `rose_above in t` (strict crossings, silent first baseline) · `edge` (false→true) |
| temporal | `sample in period` · `debounce in quiet` · `throttle in w` · `cooldown in w` · `window in span` → array · `stats` → record · `delay in by` · `every period` (source; fires at mount then per period; skip-forward after gaps) · `arm`/`disarm in off on` |
| movement | `clock` / `frame` (sources: fed seconds / frames SINCE MOUNT) · `lfo shape period [phase p]` → 0..1 (source) · `wave t shape period` → 0..1 (t piped; same waveform, pure) · shapes `sine tri saw square` |
| registers | `ease in tau [up t] [down t]` · `ramp in over` · `hold in for` · `diff in` (per second) · `integrate in max m` (clamp REQUIRED, ±m) — all hold state INSIDE the operator, which is legal: the cycle ban is about state through the plane |
| shaping | `range t lo hi` (0..1 → lo..hi, CLAMPS) · `shape t curve` (0..1 → 0..1; `linear smooth in out inout`) · `lerp t a b` extrapolates where `range` clamps |
| math | …and the completions: `sin cos tan atan2 sqrt pow exp log mod ceil sign fract` · `pi`/`tau` (sources, once at mount). `mod` and `fract` are FLOORED — the sign follows the divisor, so `-90 \| mod 360` is 270 |
| math | `add sub mul div min max` · `clamp in lo hi` · `abs floor round` · `= != < <= > >=` |
| records | `{f: x, …}` · `.field` projection, off a name (`near.id`), a path, or MID-CHAIN (`\| .field`, chains as `\| .pos.x`) · `merge a b` |
| arrays | `[a, b, c]` (live, immutable, not a buffer) · `nth in i` (0-based) · `choose i of` (`nth` with the index piped) · `window` → array · `stats` → record. Out of range and fractional indices REFUSE — never a clamp, never a round |
| over arrays | `map <body>` · `keep <pred>` · `reduce <body> [init v]` (LEFT fold: accumulator first, element second; no init ⇒ first element seeds; empty with no init ERRORS). A body is a SECTION — an operator with ports left open — and the CONSUMER declares how many it fills (`map` 1, `reduce` 2); wrong arity is refused at parse naming both counts. `(.field)` is a section too. One operator per body (a def body is deferred). `keep` filters ELEMENTS, `where` gates the STREAM |
| order & shape | `sort [by <body>] [desc]` (STABLE; ties keep input order; no `by` ⇒ elements are their own keys; orders numbers by VALUE) · `first` (empty ERRORS) · `take n [from i]` (short array FORGIVEN — `nth` past the end errors; a count is satisfiable, a value is not) · `transpose` (record-of-arrays ↔ array-of-records, self-inverse; ragged REFUSES naming both sides) · `shuffle [seed s]` (seed default 0, cross-machine identical) · `along <knots>` (Catmull-Rom through the knots as t goes 0..1; clamps outside; <2 knots REFUSES; record knots interpolate per field) |
| contracts | `match <shape> [exact]` (EVERY value; mismatch kills the wave) · `expect <shape> [exact]` (ONCE, at mount; mismatch REFUSES THE MOUNT, and it never checks again — a later violation passes through). Shape literal: `{id: string, distance?: number}`, nested, `[number]`, words `number boolean string any`; open by default, `exact` closes every record in it |
| sinks | `set <path> [value]` · `notify <path> [value]` · `inc <path> <by>` · `cast <$chan> [value] radius <r> at <pos> [decay <d>] [to <#tag>]` · `tag <@subject> <#tag>` / `untag …` (ONE tag per call; unpiped = once at tick 0; membership is a SET — twice is once, only transitions speak) |
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
- **Coupling** (`to #tag`): scopes ENTITY perception — an entity-bound
  ear hears a coupled deposit only while its entity carries the tag,
  and **tags are a level, one frame wide** (gain at n, hear from n+1;
  untag and the reading drops next tick; no back-fill). A POST hears
  everything. `to` must name a DECLARED tag (`tag declare #x`) or the
  mount refuses, node named; declared-but-empty reaches no one and is
  not an error.
- **Tags** (`#name`): written with the `tag`/`untag` sinks, read at the
  service leaves — `plane.tags.<name>.count` (live count), `.joined` /
  `.left` (occurrence mailboxes). Subscribing the tag row itself while
  writing members is a prefix cycle, refused; the leaves are siblings
  and legal. A subject must be a REGISTERED entity or the mount
  refuses with the `entity bind` spelling.
- **Entity-bound ears** (`ear bind <name> <@subject> <arche>`): the
  standpoint follows the entity, readings publish at its surface —
  `@tom.$alarm` reads what Tom hears. Despawn dangles the ear (reads
  nothing, holds its last word).
- **Derived tags** (`derive set #alert ^raider $alarm 0.5 0.4`,
  console): a maintainer joins population entities at the ON level,
  removes below OFF, holds in the band (no chatter at the line). ONE
  maintainer per tag, owning tag ∩ population, continuously
  reconciled — a hand tag below the band is withdrawn next frame and
  `left` says so; an override is a DIFFERENT tag. Because the
  maintainer reads with each entity's own carried set, a cast
  `to #alert` can feed #alert's own derivation — authored feedback,
  one step per frame.
- Deposits and readings are deterministic in fed time and stay out of
  the log; replay re-derives them. Membership and derive writes are
  derived sources too: replay re-derives, never re-applies.

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
| `lerp a b t` with all three bound | the PIPED value is `t` (flipped 2026-08-25, before the corpus had a caller) | `s \| lerp 0.5 1.5` — s, lerped between 0.5 and 1.5 |
| `lerp` on a knob that can overshoot | `lerp` EXTRAPOLATES past its ends — a 0..1 source that strays gives you an exposure outside the interval you named | `range lo hi` — the exit from the unit interval, and it clamps |
| `x \| mul 2 { set plane.a }` | blocks live at the head; mid-chain is `also` | `x \| mul 2 \| also { set plane.a }` |
| `x \| plane.y` | a pipe feeds an OPERATOR; a path on the right is a write | `x \| set plane.y` (the error asks: did you forget `set`?) |
| `as $x` / `def $f(…)` | sigils name store rows, never streams/ops | pick an unsigiled name |
| `tag @tom #a #b` | ONE tag per call — a second `#` has nowhere honest to bind | two statements, one tag each |
| `tag tom #garrison` / `entity bind wall …` | the sigil is required on EVERY surface | `tag @tom #garrison` / `entity bind @wall …` |
| subscribing `plane.tags.garrison` while tagging into it | set-sub vs member-write is a prefix cycle | subscribe `.count` / `.joined` / `.left` — the service leaves are siblings |
| `untag @tom #alert` on a DERIVED tag | the tag is owned by its rule — withdrawn next frame, `left` says so | a different tag (`#alert-manual`), gated beside it |
| keeping a program mounted across `entity free` + re-bind of its subject | binding is MOUNT-time; a rebound name does not reattach | remount to bind anew (the refusal carries the certificate's reason and frame) |
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
