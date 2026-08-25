# Implementation notes — where the spec met the code

**Status:** v0 library, steps 1–6 of the spec's build order (§9) complete.
2026-08-23.

Everything here is a decision made while implementing
[rill-spec.md](rill-spec.md), recorded so the next session doesn't re-derive
it. Spec section numbers in parentheses.

## Deviations from the spec's sketches

- **`struple.TypeTag` / `struple.Builder` don't exist** — struple's real API
  is `Kind` / `Packer` / `View`. rill defines its own `TypeId` + `TypeTable`
  (types.zig): a semantic type table, not a wire-kind enum, because host
  types (`mesh`, `grade`, …) are interned by name and no wire format can know
  them. Built-ins: `any number boolean string record bytes array`, with
  spelling aliases (`int`/`float` → number, `bool`, `map`). `any` is a
  wildcard on either side of a wire; everything else must match exactly.
- **struple gained `Packer.appendRaw`** (splice pre-encoded elements) — the
  passthrough operators (`where`, `select`, `tap`, `latch`, `partition`)
  emit already-encoded views. Review scrutiny (validate or trust?) landed
  here: appendRaw **validates structure** — input must parse as complete
  elements or the call fails with the stream untouched — so garbage cannot
  enter a struple through rill. Canonicality beyond structure stays the
  producer's contract, the same one `appendArray`/`appendMap`/`appendSet`
  children always had. Note where rill's determinism boundary actually is:
  foreign bytes enter through `feed()`/`read()` (host-supplied plane
  values), which is why math ops emit f64 uniformly (representational
  consistency per producer) and `=` compares numbers semantically.
  Suppression remains representational by design — a host that flips a
  path between int 20 and float 20.0 will see re-fires; keep producers
  type-consistent.
- **Statics** (registry.zig): the spec's grammar has `set <path>` and
  `tap label` taking non-stream arguments. These are declared per-OpDef as
  `statics` (path | word | literal) and consumed from the leading positional
  args at parse. A `path` static is a write target, never a subscription.

## Decisions the spec left open

- **Parse order is topological order** (§4.5's tie-break falls out for free):
  names are single-assignment and must be defined before use, so upstream
  node ids are always smaller. The evaluator is one ascending sweep; there is
  no sort anywhere. **Accepted consequence: the text is the schedule.** Any
  client that serialises a graph back to text — the visual editor, when it
  arrives — must emit statements in dependency order, not box-creation
  order: topologically sort, name every fan-out edge with `as`, then print.
  The round-trip guarantee (§1) is on the AST, not on statement order; many
  valid orders exist and the serialiser must pick one deterministically.
  This is a constraint on a client that doesn't exist yet — written down
  here so it's a design input, not a discovery.
- **Predicate sections** — `where (= 0)`, `partition (< 20) hp` (§4.3): a
  parenthesized opcall in argument position becomes an ordinary node whose
  *primary port is reserved* (positional args fill from port 1, exactly as if
  piped, so `(< 20)` computes `x < 20`), whose output binds to the consumer's
  first free boolean port, and whose reserved input mirrors the consumer's
  primary input source. No closures, no higher-order anything.
- **`use` aliasing (§3.10, spec v0.1)** is implemented exactly as specced:
  pure parse-time prefix expansion, invisible to the graph, the dump, and
  the evaluator (the frozen G2 hash did not move). Resolution precedence
  for a bare name: locals (`as` bindings / def ports) → `use` aliases →
  operators; collisions are loud in every direction and alias heads may be
  earlier aliases. `use` is top-level only — inside a def body it gets the
  close-over-nothing error, like the `plane.` paths it stands for. Small
  hardening that rode along: `as` can no longer bind reserved words
  (`plane use def as true false`).
- **Tail ports (§3.11, spec v0.1)** — the console's `rest` grammar, landed
  ahead of Matryoshka's Phase C so the handler migration stands on tested
  ground. Decisions inside the ruling's envelope:
  - **The tokenizer no longer rejects any character.** It can't — whether `/`
    is an error or a locator depends on the operator, which tokenization
    doesn't know. Unknown bytes become inert `raw` tokens that fail only when
    a non-tail position consumes one ("unexpected '/' in arguments" — same
    loudness, better position, and the tail slices the *raw source* by byte
    offset so `#` is text there, not a comment).
  - **Any unquoted `|` in a tail errors**, not just the spaced ` | ` from the
    ruling: `a|b` is valid pipe syntax everywhere else in the language, so a
    tail that swallowed it silently would be the exact footgun the ruling
    closes. The escape hatch is the one the error message names: a *fully*
    quoted tail (`say "a | b"`) unwraps and unescapes; a partial quote is
    verbatim text, quotes included.
  - The fixed prefix (statics, then non-tail ports minus a piped primary) is
    strictly positional — no kwargs, and the registry rejects optional
    non-tail ports on a tail op (`error.BadTailPort`), because "fixed prefix
    then rest" has no room for maybe-there arguments. Registration also
    enforces last-input-only, string-typed, never variadic.
  - `as` after a tail is captured as text — the tail ends the chain, pinned
    by test. Piping into an op whose *only* port is the tail is refused
    (the tail is parse-time text, never a stream). Tail ops can't be
    predicate sections.
  - Known edge, accepted: a lone unmatched `"` inside a tail is still an
    "unterminated string" at tokenize time (the tokenizer must pair quotes
    before the parser knows a tail is coming). Quote the whole tail.
- **Console words + `one_of` (§3.4, spec v0.1)** — the second console-grammar
  shim, landed with tail ports ahead of Matryoshka's Phase C. A bare word
  coerces to a string literal at the *bind moment*, decided by the port's
  declared type (resolution stays locals → aliases → operators → coercion, so
  bound names shadow and the property "unknown words fail loud" survives
  everywhere a string port isn't). Applies to positionals, kwargs, def ports,
  and the fixed prefix of a tail op. `one_of` membership is checked at parse
  for literals (words included); a *stream* bound to a `one_of` port can't be
  checked until eval, and isn't — the handler stays the authority there. The
  registry rejects `one_of` on non-string ports (`error.BadEnumPort`).
  `/` became a name-interior character in the same push (never a name start
  — a leading `/` is still a loud raw byte): rill has no slash operator, so
  `render/grade/exposure` is one word and knob-path *arguments* need no
  special case. Filesystem paths (leading `/`, may contain spaces) belong on
  tail ports instead.

  **The two path spellings, pinned** (so it's read here, not rediscovered):
  `render/grade/exposure` and `plane.render.grade.exposure` can both appear
  in rill source, and they are different *types*, not synonyms. Slash-form
  is a **string literal that names a path** — data, an argument, bound to a
  string port; the operator it reaches decides what the name means (which
  knob to override, which field to revert). Dot-form is a **live reference**
  — a subscription edge in the graph, with dirty-propagation semantics.
  Nothing converts between them in the language: an operator that wants a
  value subscribes (dot), an operator that wants to *talk about* a path
  takes a string (slash), and the D1 lexical map at the engine boundary is
  the only place the spellings meet. Both can even reach the same string
  port without ambiguity: `volume override v1 render/grade/exposure 0.5`
  names the path directly, while a dot-form ref in that position would be a
  *subscription* whose current **value** names the path — "this path"
  versus "the path named by what's flowing here". The spellings never
  coerce into each other. Tokenizer edges pinned by test: `1/2` is
  number-raw-number (a loud error, never a quotient, never a word), and
  only a name-start character opens a slash-absorbing word.
  `EvalCtx.host` + `MountOpts` rode the same push: host context is attached
  at mount because one-shot command programs fire effects at tick 0.
- **Two-word operator lookup**: `boolean subtract` resolves before `boolean`,
  so a host registry seeded from Matryoshka's `(verb, subop)` `Cmd` rows can
  map one row → one OpDef with no renaming. **Note the tense: G1 is passed
  in shape, not in substance.** The gate ran against a stub registry with
  console-shaped verbs; "every existing one-liner parses and dispatches
  unchanged" is a prediction until step 7 seeds the real registry and runs
  the actual 85-row verb inventory through it, table-driven. Hold that claim
  until the receipt exists.
- **defs close over nothing — enforced**: a `plane.…` path anywhere inside a
  def body (read *or* write) is a parse error; pass streams in through ports.
  Consequence: templates contain no subscriptions, flattening is a pure
  splice. Revisit if a def legitimately wants to be a sink.
- **defs are program-local in v0.** The spec wants defs registered through
  the registry so packs can ship operators; that needs lifetime/provenance
  machinery that belongs to the host-adoption step. The instance-flattening
  and knob-path properties (G7) hold regardless.
- **Mount runs tick 0.** A mounted program is live immediately — initial
  plane reads and literals seed the graph, everything evaluates once in topo
  order, effects included (a grade rill drives its grade the moment it
  mounts). Threshold/edge adapters baseline silently on first observation
  (health already at 15 has not *dropped* below 20). `restore` (from a dump)
  never ticks — a dump is a live snapshot, not a birth certificate.
- **Evaluation gating**: a node evaluates only when at least one input is
  fresh *and* every non-optional input has a value — partially-seeded graphs
  stay quiet until the plane fills in.
- **Runtime type errors are counted, not fatal** (`error_count` per node):
  the plane is dynamically typed by nature; a string arriving where a number
  was expected kills the wave at that node, deterministically.
- **Math emits f64 always** (int in, float out), so each operator's output
  encoding is canonical and suppression stays a memcmp. `=` compares
  numerically when both sides are numbers (20 == 20.0), byte-wise otherwise.
- **Kinds are not wire-checked in v0.** A slot's value/occurrence bit comes
  from the *producing* output port; feeding an occurrence into a value port
  just means it re-fires per event. Declared input kinds are documentation +
  used by kind-aware ops (`latch.trigger`). Revisit if a real program is
  bitten.
- **Cycle detection is path-level and segment-prefix-aware** (§4.4):
  `set plane.a` collides with a subscription to `plane.a.b` and vice versa.
  Checked at end of parse; the diagnostic names the node, the written path,
  and the subscription.

## Temporal operators (2026-08-23, spec §3.12/§4.6, agents doc §2)

- **Ambient time, never a path.** `tick(now)` takes `{frame, time_ns}`; ops
  read it from EvalCtx when they fire; the wheel is the only subscription to
  time. Feeding `time.now` as a delta would dirty every temporal node every
  tick — the storm the operators exist to prevent. (Chris's ruling, verbatim
  reasoning in spec §4.6.)
- **The wheel is a dumb multiset**, two sorted lanes of absolute
  `(deadline, node)`; exact duplicates dedup at insert so re-arming is free.
  Ops tolerate stale wakes (deadline moved since arming) by re-arming the
  truth — one live entry per armed node in steady state, self-healing across
  restore, no per-tick scans. Entries armed during a sweep fire next tick.
- **Monotonicity is `error.TimeRegression`**, checked before anything else in
  the tick. Never clamped: a clamped regression replays differently than it
  ran. Equal is fine (a zero-clock test suite ticks at {0,0} forever).
- **Dump fmt v2**: `now` (fed pair) + `wheel` (lane, deadline, node — in
  wheel order, ties FIFO) sections. v1 dumps load with the defined default —
  zero epoch, nothing armed (no temporal op existed under v1). Unknown fmt
  refuses with `error.UnsupportedFormat`. The frozen G2 hash was re-frozen
  for the format change, deliberately, comment says why.
- **Duration encoding** is a two-int struple array `[lane, count]` (0=ns,
  1=frames), decoded strictly (`types.asDuration`); a plain number at a
  duration port is BadValue at runtime and a pointed type error at parse.
  `typeOfValue` cannot spot a duration (it looks like an array) — the parser
  carries `Tag.duration` on the literal instead; acceptable until a real
  program is bitten.
- **Temporal node state is opaque little-endian bytes**, not struple — same
  license the threshold ops took for their side byte. Payloads inside stay
  struple elements and are re-validated by appendRaw on the way out.
- **Semantics choices**: `sample` = leading edge + coalesced trailing edge at
  the boundary (a value stream may be late, never wrong — the last change
  must not vanish because the input went quiet). `throttle`/`cooldown` are
  one eval with two names — mechanism identical, intent documented. `window`
  ages out through the wheel so a spike decays on schedule with no input;
  `stats` over an empty window is zeros with `n: 0` (n is the honesty
  marker; decaying to zero is what re-arms a crossing detector). `delay`
  maturities landing on one tick collapse to the newest (one value per slot
  per tick; keep-latest is the mailbox policy transcribed). Gates: controls
  apply before the passthrough; `on` beats `off` on a tie (fail-safe toward
  armed); `in` is *optional* so controls latch even before the stream first
  flows.
- **Eval guard refinement**: a bound-but-quiet input now blocks a node only
  if the port is *required*; optional ports read null. Without this the
  gates' rarely-firing control paths would gag the stream they gate.
- **Core namespace grew**: `sample debounce throttle cooldown window stats
  delay arm disarm` are operator words now; `as stats` in older text errors
  loud under the shadow ban (our own G2 fixture was the first casualty —
  renamed to `vitals`, hash re-frozen).
- **`2m` lexes as a duration**, where it used to be number-then-name. Ruled
  a lexing accident, not a promised spelling; spaced `2 m` still means two
  tokens.

## OpClass gained a third state (2026-08-24)

`OpClass` was `{pure, effect}`, and `pure`'s docstring promised two unrelated
things: "output depends only on inputs" *and* "evaluator may cache/skip". A
host operator that **reads** the world — a camera pose, a histogram, a BVH
report — is neither of those and not a writer either, so both available
answers were lies. Declaring it `pure` licenses a future cache pass to serve
a stale pose; declaring it `effect` puts a non-writer in the write list.

Now `{pure, reads, effect}`:

- `pure` — input-only, genuinely cacheable (the whole §6 math core).
- `reads` — reads world state through the host, writes nothing, never
  cacheable.
- `effect` — writes the world; the only class that registers `path` statics
  in the program's write list.

The write list is what the cycle check reads, so that question now goes
through one predicate, `OpClass.writes()`, at both call sites (parser bind,
dump restore) instead of two hand-written `== .effect` comparisons. A `reads`
op that grows a path static therefore *cannot* slip out of the cycle check
silently — the failure mode that prompted this. Pinned from both sides by a
test: the same op shape, declared `reads`, names the very path its program
subscribes to and parses clean with an empty write list; declared `effect`,
it fails with `cycle`.

Found while auditing Matryoshka's `Cmd` table, where the engine was deriving
this class from the *reply shape* of a console verb — five structured-reply
rows seeded as `pure`. Harmless the day it was found (none of the five
declares any argument, so none carries a path static, and no cache pass
exists yet), which is exactly why it was worth fixing before it wasn't.

## Tier 2, beat 1a — time as a value, and the registers (2026-08-25)

Built: `clock`, `frame`, `wave`, `lfo`, `ease`, `ramp`, `hold`, `diff`,
`integrate`, `range`, `shape`. Recon in `docs/cc-recon-tier2.md`; the
campaign's rulings are in `docs/rill-tier2-draft.md` §6.

- **Op-internal state is the sanctioned mechanism, confirmed
  structurally.** `Program.findCycle` is a cross product over `writes` ×
  `subs` — two lists of *plane paths* — and there is no third list, so a
  register cannot close a cycle. Twelve of the forty-nine pre-existing
  core ops already held state; these are the next customers, not a new
  capability. Gated by executing both halves: the register mounts, the
  same idea through the plane is still refused at parse naming both
  sides.

- **A source's epoch lives in its own state, baselined on first eval.**
  Not on the Runtime. `restore` rebuilds from a dump *without* ticking
  and takes `now` from `MountOpts`, so a runtime-held epoch would
  re-seed and `clock` would report 0 at t=90s. Tick 0 evaluates every
  node, so first-eval and mount coincide and the baseline is exact. The
  restore-no-jump gate is Chris's named condition for the beat close.

- **Per-frame re-arm is `wake(now + 1)` on the op's own lane** — the lane
  its duration named, exactly as `every` picks it. No new primitive. A
  tick where that lane didn't advance simply doesn't fire the entry
  (`expireWheel` consumes only what is due), so a missed wake is free and
  self-healing: the node fires on the first tick that actually moved,
  which is the first tick its output could differ on.

- **Every ticker stops, and the gate watches the eval counter go flat.**
  `ease` stops inside ε; `ramp` at its end, emitting the target exactly;
  `diff` when the rate reaches zero; `integrate` at its clamp — the bound
  that keeps the state from being a corpse is also the cutoff. ε is
  relative above 1 and absolute below (1e-4 either way) so a register on
  metres, one on an exposure, and one on a value in the millions all
  stop. **ε is a stop, not a snap** (ruled): an exponential never
  arrives, and snapping would make the last frame of every fade a step.

- **`ease` uses `1 − exp(−dt/τ)`, not a per-tick constant**, so the same
  fade takes the same time at any frame rate — the answer must not depend
  on how often the wheel happened to wake it.

- **`lfo` is its own op, and shares `waveAt` with `wave`.** The §6 pin
  says `lfo` is sugar over `clock | wave`; defs are program-local and
  inlined, so there is no registry-level def to make that literally true.
  The "one write path" that matters here is the *arithmetic*: one
  function, called by both, gated bit-identical over a fed sequence for
  every shape.

- **`range` clamps; `lerp` extrapolates.** They are otherwise the same
  arithmetic, which nearly made `range` a second mechanism for one
  effect. The role that earns the word: `lfo`, `wave` and `shape` all
  leave the unit interval and `range` is the *exit* from it, so it stays
  inside the interval it was given. Same ruling as `along` outside 0..1.

- **`diff` ticks while moving and stops at zero.** An op that only spoke
  when its input spoke would report the last velocity of a raider who has
  stopped, forever — the value slot suppresses identical bytes, so "no
  arrival" and "not moving" are the same event upstream and must not be
  the same answer here.

- **`hold` does not tick at all.** Nothing needs to happen at the end of
  its window; the next arrival simply finds it expired. It is the one
  register with no wheel entry, and the ticks audit pins that.

- **`integrate`'s clamp is a required keyword port**, not an option. Op
  state rides in every dump, so an unbounded accumulator is a corpse that
  gets *copied*. The bound is symmetric (±max).

- **Shape and curve words are `one_of` string ports**, checked at parse.
  A typo is a wire-time error, not a `BadValue` three seconds into an
  animation.

- **Named deviation — `shape bezier` is not in this beat.** The five
  named curves (`linear`, `smooth`, `in`, `out`, `inout`) land; the
  four-handle CSS form has a different arity and belongs with §2.9's
  curves work. Its §4 row is unmoved and says so.

- **Found by a gate, fixed here: a `one_of` refusal never named the
  set.** The message said which port refused and not what it would have
  accepted, which makes the author guess — the one thing "loud, never a
  guess" forbids, and the list was already right there. It now reads
  `… — expected one of: sine, tri, saw, square`. Pre-existing, from the
  console-words push; a tier-2 gate asserting the message text is what
  surfaced it.

## Tier 2, beat 1b — broadcast, and the mismatch check (2026-08-25)

Built: elementwise math over records and arrays, the loud mismatch check,
and the completions (`sin cos tan atan2 sqrt pow exp log mod ceil sign
fract`, `pi`/`tau`). The beat existed as its own half so that `binMath`
would be touched **once** — every math word is born broadcasting.

- **One site, as promised.** `binMath` / `unMath` / `cmpOp` / `boolOp`
  mint every arithmetic word, every comparator and the boolean trio.
  Broadcast is a property of those four helpers, so the fourteen new
  words inherited it without a line of per-op work, and the tier-1
  fourteen are re-scored against a record AND an array in one table.

- **The rules refuse rather than guess.** Scalar ⊗ container is
  elementwise; record ⊗ record needs the same field set (no implicit
  intersection — an intersection quietly computes over the fields that
  happen to agree); array ⊗ array needs equal length, both named;
  record ⊗ array has no elementwise meaning; nesting recurses; a
  non-numeric leaf is named by its path.

- **`=` and `!=` do not broadcast, and the line is principled.** `<` has
  no meaning on a whole record — there is no total order on records — so
  elementwise is its only reading. `=` already has an exact whole-value
  meaning, so broadcasting it would REPLACE a good answer with a
  different one.

- **The type-word vocabulary** (`number`, `boolean`, `string`,
  `record{x, y}`, `[number]`, `[]`, `[mixed]`) has one renderer,
  depth-capped at two containers. Beat 2's shape literal reuses it, so a
  mismatch message and a shape can never describe the same value two
  different ways.

- **`accepts` gained one exception**: a `number` or `boolean` port also
  accepts a record or an array, because otherwise `add {x: 0, y: 2, z: 0}`
  is unsayable. The cost, stated: a container literal now reaches ports
  with no elementwise meaning (`inc`'s `by`, a threshold), which refuse
  at eval instead of at parse. `expect`/`match` are the way back.

- **Named deviation — the broadcasting ops declare `out` as `any`.** An
  elementwise operator's output KIND follows its input, and a static
  `TypeId` cannot say "same as whatever arrives". Declaring `number`
  would be false exactly when broadcast is working, and the manual gate
  proved it: `window 10s | mul 2 | stats` refused at wire time because
  `mul` claimed to emit a number. `any` means "not statically known".
  This moved G2's frozen hash (the dump carries slot type names); the
  re-freeze carries a test pinning the cause and the unchanged values.

- **Named deviation — ternary ops do not broadcast.** `clamp`, `lerp`,
  `range` and `select` stay scalar. The pin was written in binary terms,
  `map (clamp 0 1)` covers the case in beat 3, and a three-way shape
  agreement rule is a design question nobody has asked yet.

- **Refusals gained a message channel.** `EvalCtx.detail` is a fixed
  buffer (no allocator on an error path) that the runtime clears before
  every eval and carries into `ErrorEvent.detail`. `ctx.refuse(fmt, …)`
  records the reason and returns the error in one move, so a refusal
  cannot record a reason and forget to fail.

## The refusals gate (2026-08-25)

Ruled after beat 1a segfaulted Matryoshka in a refusal message that no
test had ever executed. **The wire gate covers accepts; this covers the
other half.**

It WALKS THE REGISTRY and builds a driver for each op out of its own
port and static declarations — so a new operator is covered the moment
it registers, and an op that cannot be driven into a refusal must say so
on a list, on purpose. Exhaustive both ways, like the class and ticks
audits. For every op it asserts the refusal **arrives**, its message
**formats** (printed under the testing allocator, so a slice into freed
memory faults at the gate), it **says why**, and it **names the operator
that refused**.

What it found on its first run: **21 of 54 refusal paths said nothing at
all** — `@errorName` gives "BadValue", which names the category and not
the fact. All 21 ran through the same four accessors (`num`, `boolean`,
`raw`, `dur`), so the fix belongs there and not in the operators: the
context now carries the `OpDef`, and one change made every one of them
name itself and its port. Five stragglers with their own decode paths
were fixed by hand. A mutation restoring the silent `BadValue` is bitten
by the gate.

**The ordering rule this comes from, everywhere: ack first, then free.**
A refusal message is built from the thing being refused, so the message
must be formatted while that thing is still alive.

## Gate discipline — asserting "A rather than B" (2026-08-25)

From beat 1a's surviving mutation, and it generalises:

> **A gate asserting "A rather than B" must run in a case where A ≠ B,
> and must assert that inequality FIRST.** Otherwise it passes for both
> implementations and asserts nothing.

Beat 1a's `ramp` gate claimed "retargets from where it is, not from the
old target" while retargeting *after* the tween had finished — where
"where it is" and "the old target" are the same number. The mutation
swapping one for the other survived, because there was nothing to see.
The fix was not a better assertion but a better *case*: interrupt
mid-flight, where the two answers differ by a tenth of a unit.

Applied in beat 1b to the `range`-vs-`lerp` gate (assert `ranged !=
lerped` before either value) and to the `=`-does-not-broadcast gate
(assert the output is not a record before asserting it is a boolean).

## The seam — rill behind a C ABI (2026-08-25)

**The problem, measured.** Zig compiles a whole *module* as one unit and has
no incremental path through LLVM, so a source-module dependency is recompiled
into every consumer on every edit. On Matryoshka a **one-line change cost
406 s** in ReleaseFast against 413 s cold — essentially nothing is reused —
and every edit to rill invalidated all of it.

**Three link shapes were measured before anything was written**, because the
answer decides the design and two of the three are dead ends:

| what changed | `build-lib` | `build-exe` |
|---|---|---|
| nothing | cached 2 ms | cached 2 ms |
| a separate `addImport` **module** | — | **full rebuild** |
| a **static** library | 16 ms | **full rebuild (8 m)** |
| the exe, static library | **cached 2 ms** | full rebuild |
| a **shared** library, `zig build seam` | **50 ms** | **never ran** |

So: `addImport` is namespacing, not a compilation boundary — splitting a tree
into more modules buys exactly zero. A static library is a real boundary in
one direction only: the library is safe from consumer edits, but any library
change re-optimises the consumer in full, so it pays only if the consumer is
thin. **Only a shared library is a boundary in both directions**, and it needs
a C ABI: Zig's own ABI is not guaranteed across separate compilations.

**What is built** (`src/c_api.zig`, `zig build seam`): fifteen `callconv(.c)`
entry points over opaque handles — registry, parse, mount, feed, tick, read —
plus a `CPlane` of four callbacks for the host's data plane. `tools/seam_demo.zig`
is a consumer that links the shared library and never imports rill as a Zig
module; `zig build seam-demo` builds it.

**The demonstration, end to end.** With the demo built and its binary hashed:
change `range` in rill's *core*, run `zig build seam` — **1 second** — and run
the *same, unmodified* binary (md5 identical). It reports the new arithmetic.
The consumer was neither recompiled nor relinked.

**This is the iteration shape, not the retail shape.** Consumers keep importing
rill as a Zig module for release builds — full inlining, no handles, no ABI
surface. The seam exists so a one-line edit costs a second instead of seven
minutes while working. One source tree, two link shapes, chosen by the build.

**What the seam costs, stated.** Only extern-compatible types cross, so Zig
types go over as opaque handles and anything richer needs an accessor
(`rill_read_slot_number` is the first). Each shared object links its own copy
of any globals in the modules it includes, so shared state must live on one
side of the seam. And a seam binary does not inline across the boundary, so
profiling work still wants a monolithic build.

**Not yet done:** the op-registration direction. Matryoshka registers ~141
console verbs into rill with Zig function pointers and implements rill's Plane
vtable, so the full boundary is bidirectional. The plane half is built
(`CPlane`); the `register`-an-op half is the next piece, and it is what
Matryoshka needs before it can consume rill through the seam.

## Naming rules that are structural (2026-08-25)

The ledger already holds one meta-rule — *when a predicate over a
registry turns out to be a coverage surface, the registry carries the
answer as a field and the predicate is derived* (`routes`, `class`,
`ticks`). This is the second, and it decides words rather than fields:

> **Dispatching one word by input kind is honest when the decision has
> ONE AXIS and the kinds are DISJOINT. It is a guess the moment there
> are two axes** — because then some input satisfies both readings and
> the language has to pick, and "never pick a rule" is already the
> ledger's line on mismatched lengths.

It decided both of the tier-2 bikesheds at once, in opposite directions,
which is the reason to keep it:

- **`where` filtering an array: refused, `keep` admitted instead.** Two
  axes (is the input an array; is the argument a section or a stream),
  and the crossing case `window 10s | where plane.gate.open` — a stream
  gate on an array-valued stream — is legitimate and must keep working.
  One word can't serve both without guessing at the argument.
- **`transpose` replacing `zip`/`unzip`: admitted.** One axis (record of
  arrays, or array of records), disjoint kinds. And the operation is
  self-inverse, so one word is not just honest but sufficient — two words
  for one self-inverse operation is the waste the rule exposes.

The corollary worth saying separately: a word that is already correct in
every language your readers arrive from (`zip` = pairs) cannot be
redefined cheaply. Redefinition teaches something false to everyone who
already knows it, which is worse than teaching a technical word
(`transpose`) to those who don't.

## Shape of the code

| file | what |
|---|---|
| types.zig | TypeId/TypeTable, accepts(), literal classification, number/bool decode |
| registry.zig | Port, StaticDecl, OpDef, Emit, EvalCtx, Registry — the one registration path |
| parser.zig | tokenizer + parser → flat graph; sections, records, defs, two-word ops |
| graph.zig | Node/Slot/Source, Program (one arena), downstream adjacency, cycle check |
| ops.zig | the §6 core set, one comptime table |
| eval.zig | Runtime: mount/feed/tick(now)/setInput/readSlot; suppression; write flush; timer wheel |
| serialize.zig | dump (one struple map) / loadProgram / restoreState |
| plane.zig | Plane vtable (borrowed) + MockPlane |
| tests.zig | acceptance gates G1–G9 + frozen-reference hash |

Slot addressing: `programs.<program>.<node>.<in|out>.<port>`; node names are
`<op><n>` (`bevel1`), def instances prefix their internals
(`rivet1.bevel1`). `Runtime.readSlot(path)` / `setInput(path, bytes)` are the
watch/override surface; only literal-bound or unbound inputs are overridable.

## Parked for the next steps (§9 steps 7–8, §10)

- Matryoshka adoption: Plane impl over the drain/pubsub, registry seeded from
  the `Cmd` table (`src/control/commands.zig` — 85 rows), `mount`/`unmount`/
  `programs` console verbs, slots on the plane at `programs.…`.
- Console niceties: tab-complete from OpDef ports, `help <op>`, `tap` → log
  bus, wire-lighting in the web console.
- Explicitly parked with reasons in the spec (§10): feedback `~`, `<:`/`:>`
  sugar, `match`, budget/coarsening (per-node counters already exist),
  Tidal-style time patterns, lazy select branches.
