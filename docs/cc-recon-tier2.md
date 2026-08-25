# Recon — the tier-2 campaign (CC, 2026-08-25)

*Read against `docs/rill-tier2-draft.md` and `docs/cc-brief-tier2.md`.
Baseline verified before anything was claimed: `zig build test` is
140/140 in Debug and 140/140 in ReleaseFast at `d812ee6`. §7 item 1 was
already landed by the previous session (verified, §1). One thing is
built with this note and nothing else is: the idioms-book gate (§3a,
§9), because it is a gate and beat 1 cannot close without one. Rulings
marked **fork** are Chris's; everything else is a gate or a mechanism
and is mine unless he says otherwise.*

---

## 0. The foundation — op-internal state is legal, and it is the mechanism

The brief's first item, confirmed structurally rather than asserted.

**§4.4's cycle check is a cross product over two lists of plane paths and
nothing else.** `Program.findCycle` (`src/graph.zig:228`) walks
`self.writes` × `self.subs` and asks `pathsOverlap`. `writes` is
populated only by `registerWrites` (`src/graph.zig:207`) from `path`
statics and the composed membership key; `subs` is populated only by
plane subscriptions. **Op-internal state appears in neither list, and
there is no third list.** A register cannot close a cycle because the
checker's universe is paths and its state is not a path.

That is reinforced twice more, both structurally:

- `OpClass.writes()` (`src/registry.zig:264`) returns true for `.effect`
  alone, and both call sites (parser bind, dump restore) ask *that*
  question rather than `== .pure` — so an op that grows a path static
  can never slip out of the check quietly.
- State is a first-class runtime field, not a smuggled global:
  `EvalCtx.state` (`src/registry.zig:145`) is per-node bytes,
  allocated per node at mount (`eval.zig:235`), serialized with the dump
  and restored verbatim (`serialize.zig`, fmt v2).

**Twelve of the forty-nine core operators already hold state**:
`dropped_below`, `rose_above`, `edge`, `arm`, `disarm` (history);
`sample`, `debounce`, `throttle`, `cooldown`, `window`, `delay`, `every`
(absolute deadlines). The register family is not a new capability. It is
the thirteenth through eighteenth customers of a mechanism that has been
gated since v0 and survives dump/restore under G8.

**The corollary the register family inherits, and must pay:** op state
rides in every dump, so *unbounded state is a corpse that gets copied*.
`integrate` requires its clamp because the dump requires it, not merely
because the ledger says so. Every register in beat 1 lands with a bound
or a cutoff, and its gate asserts the bound.

**One thing the confirmation does not license.** Legal ≠ free. A
register that re-arms per frame keeps its node dirty every tick forever
unless it stops. The ε cutoff is not an optimisation; it is what keeps
"op-internal state" from becoming "the plane's cycle ban routed around
via the wheel." Every register's gate must watch it **stop** — §6 below
makes that a per-beat gate, not a per-op reminder.

---

## 1. §7 item 1 has landed

- `lerp` takes `t` piped — `ops.zig:779`, with the reason at the site
  and a gate at `tests.zig:2915` ("the piped value is t").
- `and` / `or` / `not` — `ops.zig:780–782`, classed `.pure`, in the
  class audit.
- Both are in the agent manual's operator table (`rill-for-agents.md:145`).

The corpus sweep the brief warned about cost nothing: the flip landed
while `lerp` had zero callers, which is why it was scheduled first. No
wrong→right row is outstanding.

---

## 2. What exists vs what the doc assumes

### Present, and better than the doc assumes

| the doc needs | what is actually there |
|---|---|
| op-internal state | `EvalCtx.state`, per node, dumped and restored (§0) |
| a way to tick per frame | the timer wheel, both lanes, `arm`/`expireWheel` (`eval.zig:354`, `:368`), serialized in fmt v2 — a self-re-arming op survives dump/restore |
| fed time | ambient `now_ns`/`now_frame` on every `EvalCtx`; monotonic by contract, loud `TimeRegression` |
| a mount epoch | `MountOpts.now`, and tick 0 evaluates **every** node (`eval.zig:205`) — so a zero-input source fires at mount, as `every`/`const` already do |
| arrays as a value kind | `Tag.array` since v0; `window` emits, `stats` consumes |
| bodies that aren't blocks | predicate sections parse, mint ordinary nodes, and mirror the consumer's primary input (`parser.zig:1467`) |
| keyword-only optionals | `Port.kw` and `StaticDecl.kw`, refused positionally by the registry — `cast`'s pattern is reusable verbatim |
| a routing answer at birth | `OpDef.routes` has **no default**; Matryoshka derives `routesToMain` from it (`commands.zig:1975`) |
| determinism | no `@setFloatMode` anywhere in either repo, so f32/f64 are IEEE-strict and bit-identical across machines already; G2 has a frozen-reference hash |
| a front-door gate | every ```rill block in both manuals parses, counted **both ways** (`tests.zig:2589`) |

Beat 1 needs **no new engine primitive**. That is the recon's main
practical finding: `clock`, `lfo`, `ease`, `ramp`, `hold`, `diff`,
`integrate` are all expressible with `EvalCtx.state` + `ctx.wake` +
`ctx.nowOn`, exactly as `every` already is (`ops.zig:455` is the
template).

### Absent, and the doc assumes it

| assumed | reality | lands in |
|---|---|---|
| `[a, b, c]` | `[` and `]` lex as `.raw` — legal only inside a tail. Two new `TokKind`s; the tail slices raw source by byte offset, so tails are unaffected (verify with a gate) | beat 2 |
| sections with two open ports | `bindSectionPrimary` fills exactly **one** (`parser.zig:1469`). `reduce (add)` needs two | beat 3 |
| broadcast, and the mismatch check | neither exists; all math is scalar `f64` through `binMath`/`unMath` (`ops.zig:493`) | see §6 |
| `.field` over an array of records | `project` requires `Tag.record` | beat 2 (with broadcast) |
| shape literals `{id: string}` | the record literal parses values, not type words | beat 2 |
| the ticks-every-frame badge | nothing in the registry can answer "does this tick?" | see §7 |
| f32 anywhere | every numeric emit is `appendF64` (`ops.zig:59`) | beat 4 (noise) |
| **the idioms book, and its gate** | **does not exist** — see §3(a) | **before beat 1 closes** |

---

## 3. Findings from reading — five holes and three notes

### (a) The idioms book has no document and no gate. Beat 1 cannot close today.

Brief §6 clause 2 makes "every new op has its before/after pair in the
idioms book, the after cell gated by parse" part of every beat's
definition of done. The rillbook **machinery** is live — `rillbook
save|load`, the browser app, the v1 document format (`rillbook-spec.md`
§5), a round-trip test at `matryoshka/src/casting.zig:1116`. The
**book** is not: no `.rillbook` file exists in either repo, and nothing
parses one in a test.

So the clause is currently unmeetable, and it is the clause that turns
§4's simple-things list from prose into a gate. This is a gate, not a
ruling, so I took it — **built and landing with this note**:

- `docs/idioms.rillbook` — a rillbook v1 document (`rillbook-spec.md`
  §5), one page per §4 ask. **37 cells, 12 of them rill.** An ask that
  can be said today carries its *before* cell; an ask that cannot
  carries a markdown cell naming the beat that fills it in. The
  founding example's before is reconstructed there in full, since it
  was described in the draft but written down nowhere: `every 1f | inc
  …` in one program, six lines of phase arithmetic in another, and a
  triangle rather than a sine because with no `sin` and no `wave`
  there is no sine to be had.
- The gate, in `src/tests.zig`, the manual gate's shape exactly: embed
  as an anonymous import, parse every non-markdown cell's `source`,
  and assert **both** counts so a book that stopped being collected
  fails loudly rather than vacuously.

Three mutations, all bitten (`tools/mutcheck.sh`): an unknown word in a
cell (caught by name, with line and column); a cell silently deleted
(`expected 12, found 11`); and the collector short-circuited so nothing
is collected at all (`expected 12, found 0`) — that last one is the
vacuous pass the manual gate's "both ways" comment warns about, and it
is now watched here too.

141/141 in Debug and ReleaseFast; Matryoshka's suite green against the
unchanged boundary.

If the book belongs somewhere other than `docs/idioms.rillbook`, that is
a `git mv` and one path string.

### (b) `wave` is a forty-fourth word the budget does not count

§6 pins "`lfo` is sugar over `clock | wave`. Both exist." `wave` appears
in no table in §2, so it is not among the 43. The honest count entering
beat 1 is **44 proposed against ~30**. Not a problem — it is one line in
the count and §7's cut list already covers more than the gap — but the
budget should start from the true number.

### (c) `clock` and `frame` have no customer on the §4 list

Admission rule 1 is "it has a customer on the simple-things list. No
operator on spec." Neither `clock` nor `frame` has a row; every row that
would need them names `lfo`, `once`, or `ramp` instead. They are
admitted by the §6 pin ("both") rather than by the rule.

I am not arguing against the pin — `clock` is the honest decomposition
and `lfo` without it is a magic box. I am recording that **the pin and
rule 1 disagree, and the pin wins by fiat rather than by customer**,
because that is exactly the kind of thing the brief says not to bury.
The cheap fix, if Chris wants the rule to keep its teeth: add the row
that actually wants raw time — *"drive an effect from elapsed time
without a waveform"* — or mark `clock`/`frame` as admitted-as-substrate
in §4, which is an honest second category and costs nothing.

### (d) "night falls → lights on" is scored ✓ and it chatters

§4 scores that row 1 line today, ✓, no operator needed. §2.6 then argues
`above` on the grounds that "strict crossings chatter at dusk" — which
is a description of *that row*, failing. Both are in the same document.

The row is ✓ for line count and wrong for behaviour: `rose_above` fires
on every crossing, and a light level wobbling across the threshold at
dusk turns the lights on and off repeatedly. **`above` has a customer,
and the customer is a row currently marked ✓.** Re-score the row at
beat-4 close: *today — 1 line, chatters; target — 1 line, hysteretic;
needs `above`.*

This is the §4 list doing its job in reverse, and worth saying out loud:
a ✓ in the "today" column means *expressible*, not *correct*. Two other
rows may be hiding the same thing (`dim the lamp as the fire dies`,
`rate-limit a noisy sensor into a knob` — both scored ✓ against noisy
inputs). I have not probed them; flagging, not claiming.

### (e) `diff` and `integrate` have real customers that are not on the list

§2.3 argues `diff` from the keep — the probe reviewer invented a
`raider_velocity` sensor field because nothing derived it — and it is a
good argument. It is just not a §4 row, so by rule 1 `diff` is *listed,
not admitted*. Same for `integrate` ("charge while held").

Both deserve rows rather than an exemption, and both write themselves:

| ask | today | target | needs |
|---|---|---|---|
| alarm when a raider is closing fast, not merely near | invented sensor field | 1 | `diff` |
| charge a mechanism while a lever is held, capped | 2 programs (`inc` + reader) | 1 | `integrate` |

Proposed as doc amendments riding beat 1, not as an argument to relax
the rule.

### (f) Note — `slew`'s only row is already ✓

"rate-limit a noisy sensor into a knob" is scored 1 line today and its
"needs" column says `✓ (sample, slew)` — i.e. it is already met by
`sample`. §7 lists `slew` as a cut candidate on the grounds that `ease`
approximates it. Both are right, and together they mean the read-aloud
question the §6 pin left open ("the name stands unless the recon turns
up a better one") **does not need answering**: don't admit the word.
If a customer appears later, the name is worth reopening then — `slew`
reads as jargon to anyone outside audio, which is rule 4's exact test.

### (g) Note — `OpClass` has a default, `Routing` does not

`routes: Routing` is comptime-required; `class: OpClass = .pure` is
defaulted (`registry.zig:287–288`). The brief's ledger says a new op
needs both "at registration — comptime-required, not remembered."

In practice this is covered: the class audit (`tests.zig:1977`) is
exhaustive **both ways** and fails on an unclassified op, and the
structural half ("an op that emits occurrences is never cacheable")
catches the biggest family mechanically. So the answer is *required*,
just at test time rather than compile time. Tier 2 adds ~20 ops of which
nearly all are `.reads`, so the audit table is about to do real work.

Not proposing a change — removing the default would touch every host
registration in Matryoshka for a check the suite already makes. Recorded
so that nobody later reads "comptime-required" and believes it of both.

### (h) Note — `clock`'s epoch must be op state, not a runtime field

The tempting implementation is a `mount_ns` on `Runtime`, surfaced on
`EvalCtx`. It is wrong, and restore is why: `Runtime.restore`
(`eval.zig:216`) rebuilds from a dump and does **not** tick, taking its
`now` from `MountOpts`. A runtime-held epoch would be re-seeded at
restore and `clock` would jump — a program restored at t=90s would
report 0.

Baselining in the op's own state on first eval is exact (tick 0
evaluates every node, so first-eval and mount coincide), rides the dump
like every other register, and needs no new `EvalCtx` surface. It is
also the idiom already in the tree: `dropped_below` baselines silently on
first observation, `window` baselines against the mount moment.

---

## 4. The word budget, scored by customer

44 proposed. Scored against §4 as it stands today, plus the two rows
proposed in §3(e). **Admitted = has a live row. Listed = argued but no
row. Cut = §7's named candidates, confirmed by this scoring.**

| family | admitted | listed (no row) | cut |
|---|---|---|---|
| time (2) | — | `clock`, `frame` *(pinned; see §3c)* | — |
| modulation (2) | `lfo`, `pulse` | — | — |
| registers (6) | `ease`, `ramp`, `hold`, `diff`†, `integrate`† | — | `slew` |
| shaping (5) | `range`, `shape` | `remap`, `wrap` | `norm` |
| waveform (1) | `wave` *(substrate for `lfo`)* | — | — |
| events (6) | `once`, `toggle`, `tally`, `above` | — | `rate`, `either` |
| spatial (3) | `distance`, `within` | — | `toward` |
| noise (2) | `noise`, `rand` | — | — |
| curves (2) | `along`, `smooth` | — | — |
| arrays (5) | `first`, `choose` | `nth` | `len`, `last` |
| over arrays (4) | `sort`, `take` | `map`, `reduce` | — |
| records (4) | — | `transpose`‡, `shuffle` | `without` |
| contracts (2) | `expect`, `match` | — | — |

† admitted on the rows proposed in §3(e).
‡ `zip`+`unzip` collapse to one word — see §5.

**Count: 24 admitted, 10 listed, 9 cut, and `zip`/`unzip`→`transpose`
returns one.** Landing only the admitted set puts tier 2 at **24 new
words** against a ~30 budget, with 10 in reserve that admit themselves
the day a row appears. The budget is not tight; it is comfortable, *if
rule 1 is actually applied.* The only way it blows is admitting the
listed ten on the strength of the prose that argues them — which is
precisely what rule 1 exists to prevent.

Two of the "listed" are worth watching: `map` and `reduce` have
excellent customers in §2.11's own bullet list (any-of over a set, the
loudest recent reading) that simply never made it onto §4. Beat 3 should
either add those rows or drop the words; it should not land them on the
prose.

---

## 5. The bikeshed names — two proposals, with the read-aloud

Both §2.11 and §2.12 asked the same question in different clothes:
**when is dispatching one word by input kind honest, and when is it a
guess?** I think there is a rule, and it decides both:

> Dispatch by kind is honest when the decision has **one axis** and the
> kinds are **disjoint**. It is a guess the moment there are two axes,
> because then some input satisfies both readings and the language has
> to pick — and "never pick a rule" is already the ledger's line on
> `zip` lengths.

### §2.11 — `where` filtering an array: propose **`keep`**, a second word

`where` today gates a stream: boolean stream in, arrivals pass or die.
Array-`where` would take a *section* and filter *elements*. That is two
axes — is the input an array, and is the argument a section or a stream
— and the crossing case is real and legitimate:

```
window 10s | where plane.gate.open        // the window, while the gate is open
window 10s | where (> 0)                  // the readings above zero
```

The first is a stream gate on an array-valued stream and must keep
working. The second is a filter. One word cannot serve both without
guessing on the argument, and refusing the crossing case is not
available — the first line is something people will write.

Read-aloud for the filter:

```
plane.sensors.gate.contacts | keep (.armed) | sort by (.distance) | first
window 5s | keep (> 0) | reduce (max)
```

"the contacts, keep the armed ones" · "the window, keep above zero."

**Rejected, with reasons.** `filter` — no collision and perfectly
clear, but it says *that* you are selecting and not *which side
survives*; `keep` says both in the same syllable count, and its mirror
`drop` is there if a customer ever wants it. `only` — reads as an
adverb, and `only (> 0)` wants a verb in front of it. `where` overloaded
— the two-axis guess above. `select` — taken, and by a different idea.

Cost: one word, which the §4 scoring has room for (24 of ~30).

### §2.12 — `zip`/`unzip` as transpose: propose **`transpose`**, one word

Here the dispatch is **one axis** — record of arrays, or array of
records — and the kinds are disjoint, so one word is honest. And the
operation is self-inverse, so one word is also *sufficient*:

```
plane.player.{health, mana} | window 10s | transpose | .health | stats
transpose {a: xs, b: ys}                    // "two arrays into pairs", same op
```

**Rejected, with reasons.** `zip`/`unzip` — this is rule 4's jargon
collision, not an escape from it. Every language a reader arrives from
(Python, JS, Haskell, Rust) defines `zip` as "two sequences into pairs."
Redefining it as AoS↔SoA means the word teaches something false to
everyone who already knows it, and costs **two** words to express one
self-inverse operation. The doc's own defence — "it's what people mean
when they reach for the word" — is true of the *shape* and false of the
*word*. `pivot` — spreadsheet jargon, and it implies aggregation.
`flip` — too vague; flips what? `transpose` is a technical word, but it
is *the* word: it is what the operation is called in every domain that
has it, it has no competing meaning, and a reader who does not know it
learns one true thing rather than un-learning one false thing.

Net: `zip`, `unzip` → `transpose`. **One word saved, and the collision
avoided.**

---

## 6. Beat order — §7 confirmed, with one amendment

§7's order is right and the dependencies hold: registers need nothing
new; arrays need a grammar change that is additive; the section arity
extension gates beat 3; noise needs only f32 discipline. I am arguing
one change, and it is about *re-entry*, not about scope.

### The amendment: split beat 1, and put broadcast in its second half

The problem: §7 puts the math completions (`sin cos pow mod sqrt …`) in
beat 1 and the broadcast pin in beat 2. Every one of those ops is minted
by one comptime helper — `binMath` / `unMath` (`ops.zig:493`) — and
broadcast is a change to *that helper*, not to the ops. Landing the math
words scalar in beat 1 and broadcasting in beat 2 means beat 2 re-opens
every beat-1 math gate to re-score it against records. Landing them the
other way round means each word is born broadcasting and no site is
touched twice.

It also moves a §4 row a beat earlier at no cost: *follow — keep a light
2m above the player* needs record math and nothing else.

Proposed:

- **Beat 1a — time and registers.** `clock`, `frame`, `wave`, `lfo`,
  `ease` (with `up`/`down`), `ramp`, `hold`, `diff`, `integrate`,
  `range`, `shape`. **Closes on the founding example being one line.**
- **Beat 1b — math, broadcasting.** The math completions, `pi`/`tau`,
  and the §2.5 pin: elementwise over records and arrays, **with** the
  loud both-sides-named mismatch check. Born broadcasting; `binMath` is
  touched once, ever.
- Beats 2–4 unchanged, minus broadcast (now in 1b) and minus the
  mismatch check, which rides with it. `expect`/`match` stay in beat 2 —
  they are the author-side tools and are independent of the engine
  check.

Same total work, ordered so nothing is built twice. If Chris prefers §7
as written, the cost is real but bounded — it is one re-score of one
helper's gates, not a redesign. **Fork, stated in §8.**

### What each beat's gates must include, beyond "it works"

The ledger items that bite this campaign specifically, as per-beat gates
rather than per-op good intentions:

1. **Every beat, every mode.** Debug and ReleaseFast, mutations bitten
   via `tools/mutcheck.sh`, counted in the report.
2. **Beat 1a — a register must be gated *stopping*.** Not "it converges"
   — a gate that feeds time past convergence and asserts the node's
   `eval_count` **stops rising**. Without it, ε is decoration. This is
   the single most important new gate in the campaign; it is what keeps
   §0's confirmation from becoming a licence.
3. **Beat 1a — replay.** `clock`/`lfo` mounted, fed a scripted time
   sequence twice, dumps bit-identical per tick (G2's shape). And
   dump→restore mid-animation→continue, asserting no jump (§3h's hazard,
   gated rather than remembered).
4. **Beat 1b — the mismatch check is gated on the message**, not just on
   the refusal: both sides named, on the node that refused it. A gate
   that only asserts "it errored" is the ICE failure re-shipped.
5. **Beat 2 — the tail is unbroken.** Adding `[`/`]` tokens must not
   change any tail capture; gate a tail containing brackets before and
   after.
6. **Beat 3 — wrong section arity is a mount-time refusal naming the
   op**, gated as a refusal with its message.
7. **Beat 4 — noise pins f32 bit patterns, not values**, and the oracle
   runs the same arithmetic in the same order. A float64 oracle here is
   the ledger's named failure, and noise is where it would be committed.
8. **Every beat — the idioms book grows and the count moves**, both
   ways, in the same commit (§3a).
9. **Every beat — Matryoshka's suite green** against the new boundary,
   with its own commit hash in the report.

---

## 7. Pins I propose — mechanism, not language

These are decided by how the engine already works. Recorded so they are
rulings on paper rather than accidents in code; each is reversible.

1. **Per-frame re-arm is `wake(nowOnOwnLane + 1)`.** No new primitive.
   The op's period picks the lane exactly as `every` already does via
   `deadlineAt` — `lfo sine 4s` arms ns, `every 1f` arms frames — and a
   tick where the lane did not advance simply does not fire the entry,
   which stays queued (`expireWheel` consumes only what is due). That
   makes a missed wake self-healing and free: the node re-fires the
   first tick that actually moved, which is also the first tick on which
   its output could differ.

2. **A source's epoch lives in its own state, baselined on first eval.**
   §3(h). Applies to `clock`, `frame`, `lfo`, `noise`, `tally`.

3. **`lfo` and `wave` share one shape function.** `lfo` is a registered
   op, not a parser desugar — defs are program-scoped and inlined
   (`parser.zig:400`), so there is no registry-level def to make `lfo`
   sugar in the literal sense. The "one write path" the ledger cares
   about is the *arithmetic*: one comptime `shape(kind, phase)` called
   by both, so `lfo sine 4s` and `clock | wave sine 4s` cannot drift.
   Gate: the two forms produce bit-identical output over a fed sequence.

4. **The ticks-every-frame badge derives from a registry field.** §8 of
   the draft wants the badge; nothing in the registry can answer it. It
   is the same shape as `routes` — a predicate over the registry that
   turns out to be a coverage surface — and the ledger's answer is to
   make the registry carry it. Propose `OpDef.ticks: bool`, declared at
   registration, true for `clock`/`frame`/`lfo`/`noise`/`pulse` and for
   the registers *while converging*; the badge is then "this program
   contains a ticking node, or a node downstream of one," derived, and
   the rillbook renders it. **Fork on whether it is comptime-required
   like `routes` or defaulted-plus-audited like `class`** — my lean is
   defaulted `false` plus an exhaustive audit row, matching `class`,
   because it is a display fact rather than a safety fact.

5. **Noise computes in f32 and widens exactly.** Every emit is
   `appendF64`; f32→f64 widening is exact, so an f32 internal pipeline
   reaches the wire losslessly and the frozen gate can pin the f32 bit
   patterns the pin asks for. Nothing else in the language needs f32,
   and nothing else should get it.

6. **ε is a stop, not a snap.** A register below ε emits nothing further
   *and stops re-arming*; it does not jump to the target. Gate 2 in §6
   is what enforces it. (Snapping would make the last frame of every
   fade a visible step.)

---

## 8. Forks — stated as forks, with my lean

1. **Beat 1a/1b split, broadcast moved into 1b.** §6. *Lean: split.*
   Cost of not splitting is one re-score of `binMath`'s gates; cost of
   splitting is one more beat boundary. I lean split because the ledger
   is explicit that a beat closes rather than reopens.

2. **`keep` as a second word for array filtering** rather than `where`
   dispatched by kind. §5. *Lean: `keep`.* This is the one place I would
   most like to be overruled if the two-axis argument doesn't land for
   you — it costs a word.

3. **`transpose` replacing `zip`/`unzip`.** §5. *Lean: `transpose`,
   strongly.* Saves a word and avoids teaching a false meaning of `zip`.

4. **`clock`/`frame` admitted by pin against rule 1.** §3(c). *Lean:
   keep the pin, and add a §4 category for admitted-as-substrate* so the
   rule keeps its teeth rather than acquiring a silent exception.

5. **The two new §4 rows for `diff` and `integrate`.** §3(e). *Lean:
   add them* — the customers are real, they are just unwritten.

6. **`OpDef.ticks` comptime-required or defaulted-plus-audited.** §7(4).
   *Lean: defaulted plus audited.*

7. **Where the idioms book lives.** I am building the gate at
   `docs/idioms.rillbook` because beat 1 cannot close without one
   (§3a). *Lean: keep it in the rill repo* — the ops are rill's, the
   manual gate is the precedent, and Matryoshka's suite already stays
   green by construction. Moving it later is a path string.

---

## 9. Where this leaves the board

**Built:** the idioms-book document and its gate (§3a). 141/141 Debug
and ReleaseFast, three mutations bitten, Matryoshka green.

**Not built, and deliberately:** everything else. Beat 1a is ready to
start — it needs no new engine primitive (§2) and its foundation is
confirmed (§0) — but three of the seven forks in §8 change what gets
built rather than how, so I stop here. The split decides whether
`binMath` is touched once or twice; `keep` and `transpose` decide two
words that go into the manuals, the spec, and the book in the same
commit as the code, and a word landed and then renamed is the corpus
sweep the campaign was sequenced to avoid.

The brief's rule is that when I am unsure whether something is mine to
decide, it isn't. These aren't.
