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
campaign's rulings are in `docs/rill-tier2.md` §6.

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

## Tier 2, beat 2a — the array literal, `nth`, `choose` (2026-08-25)

Built: `[a, b, c]` as a grammar form, the variadic `array` op behind it,
and the two readers. Broadcast over arrays was already there (beat 1b),
so this beat is the *literal* and its indexing, nothing more.

- **Additive by construction, not by promise.** `[` and `]` lexed as
  `.raw` before this — the token kind that is legal only inside a tail —
  so no existing program could hold a bracket outside a tail without
  already failing loud. That is what makes the grammar change safe to
  assert rather than hope. The tail is the one place brackets already
  worked, and it still works for a structural reason: `parseTailArgs`
  slices the RAW SOURCE between token offsets and never reads a token's
  kind. There is a gate driving both tail shapes (no fixed prefix, and a
  static-plus-port prefix) with brackets in the captured text.

- **`array` is `record` with positions instead of names.** Same variadic
  machinery, same live-wire property: `makeNode` names a variadic port
  from `statics[i].word`, so the array's statics are the element indices
  as words and a port called `2` is what a positional field is. The eval
  ignores them — order IS the meaning, and a gate asserts the elements
  come back unsorted (a record sorts its keys canonically; an array must
  not sort anything, and `[0.2, 1, 0.6, 0.05]` sorted would still pass a
  "four numbers" check).

- **`[]` is legal where `{}` is not.** The empty record is refused
  because `{` also opens a fan-out block and an empty one is far more
  likely a slip than a value. `[` opens nothing else, and the empty array
  is a value the language already prints (`describe` says `[]`).

- **`nth` and `choose` are one eval, minted twice** — `indexEval(0, 1)`
  and `indexEval(1, 0)`. They differ only in which port is hot, which is
  the language's own distinction (port 0 is the rousing), so it is two
  words rather than one word with a mode. Gated as an identity: they must
  agree at every index, the way `lfo` ≡ `clock | wave` is gated.

- **`struple.view` reads an element STREAM, not a container.** The first
  draft called `view(av).count()` on the array value and got 1, always —
  every index but 0 was "out of range" and index 0 was the whole array.
  The elements live in the container body, which is what `innerOf`
  unpacks; the same shape as beat 1b's `MapView.Entry.key` lesson (the
  key is the *encoded* element, not the string). Found by a gate on the
  first run, which is why the gate existed.

- **Out of range and fractional indices refuse.** Not a clamp, not a
  round, not a silent nothing. Both gates are built to the "A rather than
  B" rule: each drives an index where clamping/rounding would produce a
  *different* answer (3 into a 3-element array; 1.5 into the same), and
  each asserts the wave died rather than emitting that answer. A clamping
  implementation cannot pass them.

- **What did not land, and why it is not an omission.** The recon
  admitted `first` and `choose`, listed `nth`, cut `len`/`last`. `nth`
  landed **as substrate** — §4's existing category for `clock`/`frame`,
  and the recon's own for `wave` under `lfo` — because `choose` is
  defined as `nth` with the index piped and shipping the derived spelling
  while hiding the primitive is the magic-box shape that category exists
  to refuse. `first` did not land: its only §4 row is `sort by | first`,
  a **beat 3** row, and it admits itself there beside `sort`. `len` stays
  cut, and the draft's stated reason was corrected — §7 justified cutting
  `rate` with "`window | len`" and then cut `len` two items later, which
  cannot both be true. The conclusion holds on rule 1 alone (`rate`'s row
  already scores ✓ with `sample`), so no word was spent to save it.

- **Gates: 14 new (180 → 194), Debug and ReleaseFast. Mutations: 6/6
  bitten** — sorting the elements (6 tests), clamping the index (2),
  rounding a fractional index (1), giving `choose` `nth`'s ports (1),
  reverting the bracket tokens (10), and indexing the element stream
  instead of the container body (1).

## Tier 2, beat 2b — contracts: `expect` and `match` (2026-08-25)

Built: one shape literal, two operators, and one new registry field.

- **A shape is not a record literal, and is not parsed as one.**
  `{id: string}` down `parseArgValue` builds a record node whose `string`
  field is an unresolvable name. The dispatch is the operator's
  declaration — a new `StaticKind.shape`, parsed straight from the tokens
  before the arguments, the same way a `tail` port is dispatched by its
  port declaration. No lookahead guess, so `braceOpensRecord`'s heuristic
  never has to grow a second job.

- **The shape is encoded at parse, as a struple.** `{exact: bool, shape:
  <s>}`, where `<s>` is a type-word string, a one-element array for an
  array-of, or a map whose keys are field names carrying the `?` they were
  written with. Three consequences worth having: the check never
  re-parses text, the shape rides the dump like any other static (kind 6,
  as BYTES not text — a gate round-trips a nested `exact` shape and
  re-refuses with it), and the shape is inspectable through the same
  protocol as every other value.

- **`?` costs no token kind.** It was already a `raw` token, and a shape
  is the only place it means anything.

- **Type words are beat 1b's vocabulary, not a second one.** `number`,
  `boolean`, `string`, plus `any`. `describeShape` renders a shape in the
  same spelling `describe` renders a value, so a refusal's two sides read
  as one language: `match: '.pos.z' is string, not number`. `any` was
  added because `?` says "absent is fine" and there was otherwise no way
  to say "present, kind unconstrained".

- **`exact` is consumed by the shape's own grammar**, not by an optional
  positional static — optionals are keyword-only and that rule stands. It
  closes every record in the shape, recursively: the word closes THE
  SHAPE, and a closed outside with open insides is a promise nobody asked
  for.

- **The hole: §2.13's `expect` depends on a schema surface rill does not
  have.** "The upstream shape must be provable from declared schema" —
  but `Plane` is subscribe/read/write/cast/tag, and rill's own static
  types are port-level (`any` after any `plane.…` path). Read literally,
  `expect` refuses every mount and says "use `match`", i.e. does nothing.
  What was built instead: **`expect` checks the value present AT MOUNT,
  once, and never again.** The ledger already guarantees that value exists
  ("mount runs tick 0"), so it is the strongest evidence available and
  needs no new host dependency. Both promises survive exactly — costs
  nothing at runtime, never degrades into a runtime check — and a gate
  asserts the second one by feeding a violating value *after* mount and
  requiring it through untouched. A schema surface on the `Plane` is
  recorded as a host dependency, not built.

- **`OpDef.fails_mount` — new registry surface, one declarer.** An op's
  eval error is otherwise reported to `error_fn` and swallowed; the wave
  dies and the program lives. `expect`'s ratified promise is that the
  MOUNT is refused, and an assertion that only logs is not an assertion.
  Rather than special-case `expect` inside `evalNode`, the registry
  carries the answer and the runtime derives the behaviour — the same
  structural rule `class`, `ticks` and `routes` follow. `Runtime.mounting`
  is set only around mount's tick 0, so the field says *fails the mount*
  and not *fails the tick*: afterwards `expect` refuses like anyone else.
  `MountError`/`TickError` gain `Refused`. The ack fires **before** the
  mount unwinds — ack first, then free, again — so the host has the words
  and the node while they are still in hand.

- **Gates: 16 new (194 → 210), Debug and ReleaseFast. Mutations: 9/9
  bitten** — `expect` checking every value, `exact` stopping at the
  outermost record, `?` ignored, `exact` ignored, `fails_mount` turned
  off, a missing required field passing, an array shape checking only
  element 0, the shape dumped as text, and `any` refusing. The
  fails_mount audit is exhaustive both ways beside the class and ticks
  audits.

## Tier 2, beat 3a — bodies: `map`, `keep`, `reduce` (2026-08-25)

The structural half of beat 3. A section stops being *a node wired to the
consumer's stream* and becomes a **body the consumer drives per element**.

- **Consumer-declared arity** (Chris's pin). `OpDef.body` says how many
  arguments this operator supplies to its section — `map` 1, `reduce` 2 —
  and the *consumer* declares it because only the thing about to fill the
  open ports knows how many it will fill. A mismatch names the operator
  and both counts. It refuses at **parse**: a section's arity is knowable
  from the text, parse precedes mount, and "loud earlier is always
  allowed" is already the ledger's line. The pin said "at mount"; parse is
  strictly stronger, and the difference is recorded rather than assumed.

- **Two mechanisms, one bracket, and the consumer decides.** `def.body ==
  0` is the tier-1 predicate section (`where (> 0)`): its one open port is
  wired at parse to the consumer's own stream and the sweep evaluates it
  like any node. `def.body > 0` is a body: no port, never swept, driven
  through `EvalCtx.call`. Nothing looks at the section's text to decide —
  the declaration does — which is the same discipline the shape literal
  uses (`StaticKind.shape` dispatches, not `braceOpensRecord`).

- **Open ≠ absent.** Inside a section an unbound *required* port is OPEN;
  an unbound *optional* port is absent and is not counted. Both the
  parser's arity check and `linkBodies`' `body_open` derive this from the
  same registry, so a parsed program and a restored one cannot disagree.
  Two mutations, one per site, and both bite.

- **`callBody` is `evalNode` with the two ends replaced.** Inputs come
  from the caller instead of the slots; the output goes to the caller
  instead of propagating. Everything between — the op's own state, arena,
  refusal detail — is identical, so a body refuses in exactly the words it
  would use anywhere else (gated: `map (nth 0)` refuses as *`nth`*, not as
  `map`).

- **A body is not a closure, but it may hold bound ports.** `keep (>
  plane.threshold)` is legal and live. A value arriving there must rouse
  the **consumer**, because the body has no output anyone reads —
  `markNode` redirects through `Node.body_of`.

- **A dead guard, found by mutation and deleted.** `evalNode` also carried
  `if (n.is_body) return;`. Removing it SURVIVED the whole suite: with
  `markNode` the only writer of `dirty`, a body is never marked, so that
  branch could not run. Per the ledger — *a mutation that survives and is
  right is a finding about the code* — it was deleted with the reason at
  the site, and `Node.is_body` went with it (`body_of != null` is the same
  fact and is the load-bearing one). Belt-and-braces was the tempting
  call; a check nothing can reach is a check nobody can trust.

- **A body is ONE operator.** `(.field)` is a section too — `project` with
  its port left open. A `def` as a body, and a chained `(.pos.x)`, would
  need the caller to drive a node *range*, i.e. re-entrant evaluation of
  the normal slot machinery; deferred, and **refused by name** rather than
  mis-parsed. Every customer in draft §2.11 is a single-operator body.

- **One number on the wire.** Only `Node.body` is serialized; `body_of`
  and `body_open` are derived by `Program.linkBodies`, called at the end of
  a parse and at the end of a load. Four mutually-consistent fields in a
  dump is four chances to disagree.

- **Three §4 rows were added BEFORE the words landed.** §7 said `map` and
  `reduce` had customers in §2.11's prose that never reached §4, and that
  beat 3 must add the rows or drop the words. The rows went in first. That
  order is the whole difference between admission rule 1 having teeth and
  having a loophole.

- **Gates: 17 new (210 → 227), Debug and ReleaseFast. Mutations: 10/10
  bitten** after the dead-guard deletion (9/10 before it, the survivor
  being the finding above) — right-folding `reduce`, dropping the arity
  check, dropping the `markNode` redirect, reversing `body_open`, `map`
  dropping empty results, `keep` emitting the verdict instead of the
  element, an empty `reduce` going silent, the body link unserialized, and
  both open-vs-optional sites.

## Tier 2, beat 3b — order and shape (2026-08-25)

Built: `sort`, `first`, `take`, `transpose`, `shuffle`, `along`.

- **Two mechanisms, each reusing a ratified rule.** `OpDef.body_kw` makes
  a section body keyword-introduced (`sort by (…)`) and therefore
  optional — the ratified "optionals are keyword-only" rule kept, with
  `by` as the keyword. `StaticDecl.flag` is a bare-word flag (`desc`),
  the same shape `exact` took inside the shape literal, generalised once
  so the next flag costs nothing. The registry's optional-static check now
  reads `if (sd.flag and !sd.optional) … if (sd.optional and !sd.kw and
  !sd.flag) …`: a flag carries no value, so the ambiguity that rule exists
  to prevent (`cast $alarm 30` — payload or radius?) cannot arise.

- **Sorting uses the store's own total order, by value.** Chris's
  suggestion to use the radix store as the sorting medium is banked by
  struple directly — its encoding is `memcmp`-orderable, which is how the
  store sorts. One caveat decided it: in raw `memcmp` order the TYPE BYTE
  dominates, so every integer files before every float. rill has one
  `number` type and no way to see the difference, so `sort` uses
  `semanticOrder` — the same cross-type sequence (nil < bool < number <
  string < array < map), numbers compared by exact value. Gated:
  `[2.5, 2, 1.5]` sorts to `[1.5, 2, 2.5]`, and a memcmp sort puts `2`
  first.

- **Stability is ours, not the library's.** `keyedLess` carries each
  element's original index as its tie-break, so ties keep input order
  whichever algorithm runs. Errors are surfaced once, before the sort, in
  a pass that compares every key against key 0 — a comparator returns
  `bool` and cannot refuse, so it must not be where a malformed key is
  first discovered.

- **A gate that passed because of the library underneath.** The first
  stability gate used four elements and three ties, and the mutation
  removing the tie-break SURVIVED it: `std.sort.pdq` falls back to
  insertion sort below a size threshold, and insertion sort is stable by
  accident. Rewritten with forty elements and two keys, past the
  fallback; the mutation now bites. **New ledger line: a gate that passes
  because of the library underneath is watching nothing** — the same
  shape as "prose approves plausible semantics", one layer down.

- **`take` forgives and `nth` refuses, and the asymmetry is the point.**
  `take 5` promises *at most five*; two is a satisfiable answer. `nth 5`
  promises *the sixth element*; if there isn't one the program asked for
  something that does not exist. A count can be satisfied, a value cannot
  be invented. `from` past the end is the same shape: empty, not an error.
  Gated as a pair, on one input, so the claim is the difference.

- **`along` blends four knots elementwise**, recursing over records and
  arrays with beat 1b's vocabulary — a curve through positions is a curve
  through each axis. Uniform Catmull-Rom, tension ½, so every knot is
  passed through exactly; ends duplicate the terminal knot; `t` outside
  0..1 clamps, because a path has ends. Fewer than two knots refuses, and
  because mount runs tick 0 that lands at mount for every mounted program.

- **`transpose` refuses ragged input in both directions**, naming both
  sides. The array→record direction reports the two field sets in the
  type-word vocabulary (`record{a, b}` vs `record{a}`).

- **`shuffle` is xoshiro256++ over Fisher–Yates**, integer-only, seed
  defaulting to 0 — bit-identical across machines, and the same
  permutation every tick, which is what determinism in fed time requires
  of an operator that re-runs on every change.

- **A finding the row-scoring surfaced, now RULED: `| .field` is the
  taught spelling.** "Nearest hostile" landed at two lines because a field
  read named a standpoint (`near.id`) and a chain had neither a name nor a
  path. Ruled 2026-08-25: `| .field` is sugar for `project`, and `project`
  stays registered as **substrate** — reachable, never taught, the
  standing `wave` has under `lfo`. It reuses `parseProjections`, so
  `| .pos.x` in a chain means exactly what `near.pos.x` means off a name;
  one code path, one answer. The row is one line and re-scored. The
  deferral that remains is a different thing: `(.pos.x)` as a SECTION
  needs a body to be several nodes, and is still refused by name.

- **Gates: 18 new (227 → 245), Debug and ReleaseFast. Mutations: 12/12
  bitten** after the stability gate was rewritten (11/12 before, the
  survivor being the finding above) — the tie-break, desc reversing ties,
  memcmp ordering, `take` erroring short, `transpose` picking shortest,
  the default seed, `along` extrapolating, `along` accepting one knot, the
  Catmull-Rom basis, `first` going silent, flags unrecognised, and `sort`
  accepting a positional section.

## Tier 2, beat 4 — events, levels, noise, space (2026-08-25)

Built: `pulse`, `once`, `toggle`, `tally`, `above` (4a); `noise`, `rand`,
`distance`, `within` (4b). Closes the campaign.

- **Levels emit at tick 0; crossings baseline silently** (Chris's pin,
  and the line that shapes the whole family). `above` publishes its
  hysteresis state at mount, `toggle` its initial `false`, `tally` its
  `0`. `dropped_below`/`rose_above`/`edge` keep their silent first
  observation. The two rules are complementary, not inconsistent: what an
  operator publishes decides which it follows.

- **One node, one kind.** `pulse` is a VALUE source, `every` the
  occurrence source. Asserted **from the registry** rather than through
  behaviour, so a later edit to either declaration fails in rill instead
  of in a host a quarter later.

- **`once` needed no new rule, and §3.8 is why.** Unpiped at a statement
  head, `once 1` binds the literal to port 0 — rousing and payload
  together, exactly as `cast` does — so it is written at mount, fires at
  tick 0, and nothing ever marks the node again. Piped, it passes the
  first arrival. The `fired` bit in state is what makes "never again"
  true even when something downstream drags the node along.

- **The fade-in row never needed `once` at all.** `clock | div 2 |
  range 0 1` is one line and correct, because `range` clamps. What it
  costs is a frame forever, which is precisely what the ticks badge
  exists to show. The stopping spelling — `once 1 | ramp 2s` — does NOT
  work: `ramp` baselines at its first target, so it jumps to 1 rather
  than fading to it. Pinned by a gate as a fact, and raised as a fork
  (`ramp … from 0`) rather than papered over.

- **`above` closed the correctness column's founding row.** "Night falls
  → lights on" scored ✓ at one line *and* chattered at dusk, which is
  what put the column on §4 in the first place. The gate drives the exact
  oscillation where a strict comparator and a hysteresis band disagree
  and counts flips on both: six against zero.

- **One PRNG family, not three.** `rand` and `shuffle` draw from
  xoshiro256++; `noise` is a lattice hash. A generator produces a
  sequence; a hash answers "what is the value AT this coordinate" and
  must answer the same way forever. `rand` folds its draw counter into
  the seed rather than carrying 32 bytes of generator state across ticks,
  so a restore lands on the number the live program would have produced.

- **`noise` is f32 in a fixed order, widened exactly, pinned by BIT
  PATTERN.** Fifteen f32 words across three declarations and five fed
  times. The mutation that computes in f64 and widens back is
  indistinguishable by value at most points and dies instantly against
  the patterns — which is the ledger's "a float64 oracle for f32 code is
  prose in numeric clothing", made operational.

- **A gate found a design bug in the noise, not just an implementation
  one.** The textbook 1D Perlin gradient is ±1, which gives a lattice
  cell four possible shapes — so two seeds produce an *identical* cell
  one time in four, and `seed` stops being the decorrelator §2.8
  promises. The gate that counts how often three seeds disagree said 32
  of 109. Gradients now come continuously from the hash's top 24 bits
  (the width an f32 mantissa holds exactly, so the division is lossless
  and identical everywhere): 108 of 109, and the one that matches is fed
  time zero, a lattice point where 1D gradient noise is zero for every
  seed by construction. **A range check and a smoothness check both
  passed the broken version.** What caught it was a gate on the property
  the docs actually claimed.

- **A second finding, scored not hidden: a record field cannot be an
  operator call.** `{x: noise 40ms seed 1, …}` does not parse — a field
  takes a literal, path, name, record or array. So the camera-shake row
  costs four lines against a target of 2–3, three of them `as` bindings.
  Raised as a fork; CC's lean is to leave it, because making it work
  needs the comma to become significant inside an argument list.

- **The two re-probe rows held.** With `noise` built they could finally be
  driven by real noise. *Dim the lamp* holds at 2 lines **and only at 2**
  — the naked reading jitters, the smoothing line is what makes the ✓
  true, and the gate asserts the difference rather than "it works".
  *Rate-limit a noisy sensor* holds at 1: ten changes over ten periods
  while the sensor moved on all 126 frames.

- **Gates: 31 new (245 → 276), Debug and ReleaseFast. Mutations: 14/14
  bitten** — `pulse` as an occurrence, its width default, `once` passing
  everything, `toggle` eating the mount value, `tally` silent at mount,
  `above` losing hysteresis, `above` silent at mount, ±1 gradients, f64
  arithmetic, no fade curve, `rand` not advancing, `rand` ignoring its
  seed, `distance` never looking for z, and `within` comparing backwards.

## Tier 2 close — the amendment, two forks ruled, and a parity gate (2026-08-25)

- **Seeds offset the LATTICE, not only the gradients** (Chris's
  amendment). See the ledger addendum under "Gate discipline": the t = 0
  match the first gate found was a family, not a corner, and the gate's
  own sampling grid was what hid it.

- **`ramp … from <v>` — ruled.** An optional keyword port giving the
  FIRST tween a start. `once 1 | ramp 2s from 0` is the mount fade in one
  line **that stops**, where `clock | div 2 | range 0 1` is one line that
  ticks forever. Gated on the eval counter going flat, not on the value:
  a value that stays put looks identical to one being recomputed. Without
  `from`, the old baseline-at-first-target behaviour is unchanged and
  separately gated, because `from` was added beside it, not instead.

- **The paren form — ruled.** A record field or array element may hold a
  **complete operator call**: `{x: (noise 40ms seed 1), …}`. Chris's
  framing was the whole solution — `( … )` is already an argument form
  and parens already delimit, so no comma rule was needed. The two
  readings never collide because they live in different positions: a
  field position takes no section (nothing there consumes an open port,
  so the section reading would be a guess — and would bind `40ms` to
  `octaves`), and `map`/`keep`/`where`/`sort by` always do. Gated in one
  program. The camera-shake row went from four lines to one, under its
  2–3 target.

- **The manual-parity gate.** Both manuals drifted behind the language
  twice during this campaign, and both times a person found it by
  reading. Reading is not a coverage surface. Now: every registered core
  operator must be NAMED in a code span of the agent manual, or be on the
  `untaught_substrate` list on purpose — exhaustive both ways, beside the
  class, ticks and fails_mount audits. The human manual is gated the
  other way, by every printed example being parsed.

  Its first draft reported thirty operators missing that were sitting in
  the table: it paired backticks across the whole document, so a
  ```-fence put the whole scan out of phase. Scanning line by line with
  fences skipped is the fix, and it is worth recording that a
  *coverage* gate can fail by over-reporting as easily as under — the
  first is merely noisy, the second is the dangerous one.

## The ergonomics re-probe — what a no-priors reader found (2026-08-25)

The last close-out item: hand the human manual and the §4 asks *in prose*
to a reader who has never seen rill, and compare their line counts with
ours. They wrote 29 of 31 asks in one line, which is the campaign's
claim holding up. They also found three things nobody inside had.

- **The flagship threshold recipe was INVERTED.** `plane.world.light |
  above 0.3 0.2 | set plane.lights.street.on` turns the street lights on
  **in daylight**. It shipped in §6f, in §11 captioned "a noisy reading
  into a switch", and in the idioms book — and the beat-4 gate *passed*
  it, because the gate drove the chatter property (six flips against
  zero, correctly) while naming its output slot `plane.lights.street.on`
  and asserting it TRUE at 0.9. The hysteresis was right and the sense
  was upside down, in four places at once. Fixed with `| not`; the gate
  now asserts the row's actual claim — lights OFF in daylight, ON past
  the release, still on inside the band, off past the trip.

  **New ledger line: a gate that watches the operator is not watching the
  row.** "Does `above` hold its state across the band" and "do the street
  lights come on at night" are different questions, and the beat gate
  only asked the first. The row is the customer; the operator is the
  implementation.

- **The gate could not have caught it, and now can.** The manual gate
  proves every printed example PARSES, which was never the problem here.
  So the gate for a recipe whose *correctness* matters now drives the
  manual's own text (`manualRecipe(heading)`) instead of its own copy —
  edit the recipe back and the gate fails. Mutation U3 survived until
  this landed and bites now. This is applied where sense matters, not
  everywhere: a general "mount every example" gate needs a plausible
  seed per subscribed path, and seeding them all with a number produced
  eight false refusals against one true one.

- **A manual example that parsed and could never run.** `[{…}, {…}] |
  choose plane.stage.leg` pipes the ARRAY into `choose`'s index port. The
  root cause was ours, not the example's: **beat 1b widened
  `types.accepts` GLOBALLY** so `mul {x: 1}` would wire — and that
  removed wire-time typing from *every* number and boolean port in the
  language. `choose`'s index, `take`'s count, `above`'s thresholds,
  `within`'s radius, `noise`'s octaves and seed all silently accepted an
  array and refused at runtime instead.

  Fixed structurally: `Port.broadcasts` is opt-in, set by the 27 rows
  whose eval is minted by `binMath`/`unMath`/`cmpOp`/`boolOp`/`unBool`,
  and `types.acceptsPort` consults it. The bad example now fails at
  parse — and it failed in the idioms book too, on the first run after
  the change, which is the wire gate doing the job it was built for.

- **`and`/`or`/`not` were in the agent manual and nowhere in the human
  one.** The parity gate covers the agent manual (it is a reference and
  promises to list the vocabulary); the human manual is prose and is
  gated the other way. That leaves exactly this gap, and it is why the
  reader could not turn the threshold over: they went looking for
  `below`, `not`, `invert`, `!` and found none of them.

**Findings recorded, not built** (each is real, none is a bug in
something that shipped): there is no way to kick an envelope from an
event — `pulse` is periodic, `ease` follows its input, and `ramp … from`
seeds only the first tween, so "flash on hit" costs two programs and an
invented gate path; `first` errors on empty and §11's nearest-threat
recipe walks into it every time the gate is quiet; `select`'s branch
order is inferable only from a variable name in §10; `stats` on an empty
array is unspecified where `reduce` is settled; and the human manual has
no alphabetical operator index, so a reader builds one by reading prose.

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

**Addendum, 2026-08-25 (tier-2 close): a gate that watches the operator
is not watching the row.** The beat-4 street-light gate drove the exact
oscillation where a hysteresis band and a strict comparator disagree, and
counted flips correctly — while asserting that the street lights were ON
at light level 0.9. "Does `above` hold its state across the band" and "do
the lights come on at night" are different questions, and only the second
one is the customer. Where a recipe's *sense* is the claim, drive the
manual's own text so the gate and the documentation cannot drift apart.

**Addendum, 2026-08-25 (beat 4), ratified: gate the property the doc
claims, not the implementation's incidental ones.** `noise` promised that
"same seed and period ⇒ the same stream" and, by contraposition, that
different seeds are different streams. The range gate passed the broken
version. The smoothness gate passed it. What caught it was a gate on
*decorrelation itself* — how often three seeds disagree — which is the
sentence §2.8 actually wrote down. Incidental properties (it's in 0..1,
it's continuous) are cheap to check and cheap to satisfy; the claimed
property is neither.

And the amendment, which is the sharper half: **the first version of that
gate sampled at 37 ms over a 300 ms period and so never once landed on a
lattice boundary.** Gradient noise is zero at every lattice point for
every seed, and seeds sharing a period share a lattice — so
gradient-only seeding made every stream pass through 0.5 in lockstep at
each period boundary, octaves included. A *family* of coincidences, and
the gate's sampling grid stepped over all of them. Seeds now offset the
lattice phase too, and decorrelation is re-gated at t = period exactly.
Corollary worth keeping: **when a property has a period, sample on the
period, not near it.**

**Addendum, 2026-08-25 (beat 3b), ratified: gate past the library's
fallbacks, or the library is the thing under test.** `sort`'s stability gate used
four elements; the mutation removing the stability tie-break survived it,
because `std.sort.pdq` falls back to insertion sort on small inputs and
insertion sort is stable by accident. The gate was measuring the standard
library, not the code under it. Rewritten at forty elements, past the
fallback. Same family as "prose approves plausible semantics, execution
approves actual semantics" — one layer further down, and the tell is the
same: the check passed without the code having to do anything. It
generalises past sorting — any stdlib with a small-input fast path
(hash maps, allocators, formatters) will happily satisfy a gate that
never leaves it.

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

**Both directions are built.** The boundary is bidirectional — a host does not
merely call rill, it registers operators *into* it and rill calls back — so the
seam carries:

- *into rill*: registry, `parse`, `mount`, `feed`, `tick`, slot reads, type
  interning, and the routing column (`rill_op_routes` + `rill_program_node_op`,
  so a host derives "does this program touch main?" across the seam exactly as
  it does in-process);
- *out of rill*: the plane's four callbacks (`CPlane`), and **host operators**
  — `rill_register_op` takes a `COpDef` plus a C callback and a user pointer.

One trampoline stands in for every host operator and finds its callback from
`EvalCtx.op`, keyed by **name**: `reg.ops` is an ArrayList that reallocates as
operators register, so a map keyed on an `*OpDef` would dangle the moment the
table grew. (`EvalCtx.op` exists because beat 1b's refusals gate needed every
refusal to name itself; it paid for itself twice.)

Port slices are **copied** into seam-owned memory at registration, because the
registry borrows them from the registrant and a C caller's buffers do not
outlive the call.

Verified with both directions live: a demo registers a host verb across the
seam, mounts `lfo sine 4s | range 0.5 1.5 | also { lamp set } | set …`, and the
host operator is called back 18 times with its own world in hand. Then —
without rebuilding the consumer — changing `sine` in rill's core and running
`zig build seam` (1 s) moves the reported peak from 0.646447 to 0.573223 in a
binary whose md5 is unchanged.

**What Matryoshka still needs**, and it is the consumer's side rather than the
seam's: its 141 verbs are registered by a comptime `inline for` over the `Cmd`
table, so seam mode needs that loop to emit `COpDef` values and C callbacks
instead of Zig `OpDef`s — under the same `-Dseams` switch that picks the link
shape.

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

## The typing gate and the operator index (2026-08-26)

The first two items of the envelopes campaign, and both are structural:
they exist because of what the tier-2 re-probe found, not because of
anything the language was missing. Chris fixed their order — the typing
gate must land *before* the new words, so their ports are covered by it
from the first commit rather than added to it afterwards.

**(1) The typing gate** (`tests.zig`, "the typing gate: …", three tests).
Beat 1b widened `types.accepts` globally so `mul {x: 1}` would wire, and
in the same stroke removed wire-time typing from every `number` port in
the language. Nothing in the suite noticed for a whole campaign. The fix
had already landed at tier-2 close (`Port.broadcasts`, opt-in); what
landed here is the coverage surface that stops it recurring:

- the accept set is stated as a **table** — port type × `broadcasts` →
  the value types that reach it, sixteen rows — and walked against
  `types.acceptsPort` for all eight built-ins. Stated as a table on
  purpose: an expectation shaped like the implementation's `if`s would
  have been widened in the same edit that widened them.
- every elementwise port is **named** — 27 operators, 41 ports — and the
  registry is walked both ways against that roster. Opt-in dies quietly
  the moment a default flips, and `p.bc` is four characters from `p.in`.
- two structural halves that need no table: `broadcasts` only ever sits
  on a `number` or `boolean` port, and never on an output (the flag says
  what may *arrive*, and nothing arrives at an output).

The limitation is written down at the gate rather than papered over: a
port bound from a **pipe** is `any` at wire time, because a path has no
declared type. Wire typing bites on literals and typed wires; a piped
path is still the eval-time mismatch check's business. That is exactly
why the roster matters — the literal is all the wire gate ever gets.

Four mutations, all bitten: restoring the global widening (caught twice
over, by the table and by the three end-to-end parse checks); `p.bc` →
`p.in` on `mul`'s `b`; `p.in` → `p.bc` on `above`'s trip threshold; and
the flag appearing on a `duration` port.

**(2) The operator index** — `rill-manual.md` §12, 95 rows. Asked for by
name at the re-probe: *"an alphabetical operator index with arity and
port order. The tables are scattered across §6b, §6c, §6d, §6f and §7 and
cover maybe half the operators actually used in examples."* They were
being generous. When §12 was written, **twenty-two registered operators
appeared nowhere in the human manual at all** — `changed`, `latch`,
`merge`, `min`, `mod`, `atan2`, `pow`, `pi`, `<=`, `>=`, `const`, `tap`
and every trig function among them.

What the index claims is **arity and port order**, and that is what is
gated — not surface syntax. Statics are written where their own section
shows them (`set plane.a 1`, `cast $alarm radius 30 at <ref>`) and are
listed after the ports so the arity reads at a glance; the legend says
so. Gate the property the doc claims.

Four gates, and between them the index cannot drift:

- every registered operator appears exactly once, or is on the same
  `untaught_substrate` list the agent manual's parity gate keeps — and
  no row invents an operator. (A manual describing a word that was never
  built is precisely what the re-probe caught, twice.)
- the printed signature is **parsed** and compared slot by slot against
  the declaration: port order, optionality, keywords, bare-word flags,
  section bodies, variadics.
- byte-order alphabetical, so the six punctuation operators sort ahead
  of the words and stay together.
- every `§` pointer in the third column names a heading that exists.

Two findings came out of building it, and both are ledger shapes:

- **The signature parser met `< <a> <b>` and read the comparator as an
  unterminated slot.** Six operators are spelled in the punctuation the
  slot syntax uses. The operator name is now taken whole, as the first
  whitespace-delimited token, before any scanning starts.
- **The slot comparison was inline in the loop, and dropping its keyword
  clause SURVIVED.** The corpus is the thing that agrees, so no row in
  the manual ever differs on any one axis — "A rather than B" was never
  running anywhere A ≠ B. Extracted as `sameItem` and witnessed one axis
  at a time in the parser's own test; all four clauses now bite. The
  ledger line held again, in a gate written by someone who had just
  re-read it.

Nine mutations across the two items after those fixes, all bitten: a
renamed port, a deleted row, a swapped pair, an arity that drops an
optional port, an optional printed as required, a parser that swallows
what it does not understand, each of the four `sameItem` clauses, a
pointer to a section that does not exist, and the pointers going away.

## `below` — the hysteresis pair (2026-08-26, envelopes item 4)

Chris's ruling, and it is a ruling about *reading*, not about behaviour:
**the first number trips and the second releases, for both words.**
`above 0.3 0.2` is "above 0.3, until below 0.2"; `below 0.2 0.3` is
"below 0.2, until above 0.3". That is the entire reason `below` is a word
rather than `above` with its arguments swapped — `above <off> <on>` would
have been the same computation and would have asked every reader to work
out which of the two numbers was the larger before knowing what the line
did.

So each word **refuses the other's order at mount**, naming both numbers:
`above` needs its release below its trip, `below` above it. The check
lives in `eval`, and mount runs tick 0, so it lands at mount — the
`along` precedent. Equal numbers are a zero-width band and stay legal in
both words: that is a comparator, and the language has one.

One shared body (`hysteresis(comptime falling: bool)`) rather than two
functions that rhyme. The failure mode of two is one of them growing a
fix the other never gets.

**The flagship recipe is now on its third spelling**, and the sequence is
the argument for the whole item:

1. `above 0.3 0.2 | set …` — shipped, and it lights the street at noon.
2. `above 0.3 0.2 | not | set …` — right, the long way round.
3. `below 0.2 0.3 | set …` — the sentence you would say out loud.

It also improved the gate for free. The gate compares the band against
the strict comparator it replaces (`< 0.3`), and those two now point the
**same way**: they agree on every reading except the ones the band exists
to swallow. A sense error in either now shows as a disagreement rather
than as two mirrors both flipped, which is exactly the failure the
inversion survived for a whole campaign.

**Five mutations, all bitten — but only after a finding about a gate,
again, and it is the same ledger line for the third time.** The first
draft of "the first number trips" fed each operator a value sitting
exactly ON its first number: 0.3 to `above 0.3 0.2`, 0.2 to `below 0.2
0.3`. An implementation tripping on its SECOND number passes that,
because 0.2 ≤ 0.2 and 0.2 ≤ 0.3 are both true — A and B agree there, and
the mutation walked straight through. The discriminating value is
*inside* the band: at 0.25 neither word has tripped, and trip-on-second
makes both read true. One gate, both words, nowhere to hide.

The other four: `below` accepting a backwards order; the level not
published at mount; the refusal dropping its numbers; and `above` itself
trip-swapped, which the same pair gate catches.

## `first`/`last` on empty, and `len` (2026-08-26, envelopes item 5)

Chris's ruling, and it reverses one of beat 3b's. `first` refused an
empty array because it *promises one value* — right about the promise,
wrong about the shape of the failure. A contact list is empty most of the
time, so §11's flagship list recipe walked into §9's error budget every
quiet second and eventually unmounted the program whole. **No contacts at
the gate is the ordinary state of the world, and the ordinary state of
the world should not spend an error budget.**

So `first` and `last` **end the wave silently** on an empty array — the
`where` precedent, because a value cannot be invented — and `nth` keeps
refusing. That asymmetry is the same one `take` already carried from the
other side, read from the other end:

- `nth 3` names a **position**, which is a claim that the position
  exists. An empty list makes the claim false, so it refuses.
- `first`/`last` name an **end**. An empty list simply has none.
- `take 3` bounds a **count**, and a count of two satisfies it.

A claim can be false; a count and an end cannot.

**`len` was admitted by this ruling, not alongside it.** Once `first`
goes quiet there has to be something that says *nothing was there*, and
the honest something is the count — so the recipe is two statements:

```
contacts | sort by (.distance) | first | .id | set plane.ui.nearest
contacts | len | set plane.ui.contacts
```

The first goes quiet and its sink holds its last answer, which is correct
(a value stream holds); the second says `0`, which is what a reader
actually branches on. **Absence is said by the count, never by a
sentinel.** Reaching for `stats | .n` to learn a length is the magic-box
shape — a statistics package consulted about arithmetic anyone can do —
and Chris's correction to the recon's cut reason said so: `len` was cut
because `window | len` existed, and `len` was cut two items later. A
circular cut is not a reason.

**`last` is compulsory rather than merely admitted**, and its own
customer is "the most recent reading" — `window 5s | last`. `window` is a
rolling buffer and its newest entry is what people want from it. The
re-probe asked for it by name; the manual had been describing it.

Neither is substrate. **Substrate is a primitive a *taught* word is
defined over** (`wave` under `lfo`, `project` under `| .field`, `nth`
under `choose`). Both of these are taught.

One shared body again — `endEval(comptime tail: bool)` — for the reason
`hysteresis` has one.

Four mutations, all bitten: the two ends swapped (caught by three gates,
including beat 3b's own nearest-hostile row); the empty array refusing
again; `len` off by one; and `nth`'s range check loosened, which collapses
the asymmetry the whole ruling is about and is caught in the same gate
that asserts the silence.

The other half of the re-probe's finding is still open and is recorded as
such in `rill-tier2.md` §8: the forgiving spelling `take 1 | map (.id)`
publishes `[]` or `["id"]`, a different *shape*, so every consumer
changes too. Nothing here changes a published shape.

## `kick` — the envelope, and the name read aloud (2026-08-26, item 6)

The register family's missing half. `ease` and `ramp` chase a target that
something else supplies; an envelope is a **shape an event sets off**,
and rill had no way to say that. The tier-2 re-probe's biggest finding:
producing "flash on hit" cost them **two programs, a path invented on the
plane to hold a gate, and a 60 ms magic number whose only job was giving
`ease` something to fall from**. Two programs because a rill may not
write a path it also subscribes to — the workaround's shape, not a
transcription quirk, and the idioms book now carries it as two cells for
exactly that reason.

**The name, read aloud before it was built**, as Chris asked. `kick`
stays. The rejects and their reasons, recorded either way (the
`pass`/`effect`/`tee` → `also` precedent):

- **`strike`** — the closest rival, and a struck bell has precisely this
  envelope. It loses because it is also a *noun for the event*:
  `plane.events.hit | strike 20ms 400ms` reads as two events in a row.
- **`flash`**, **`thump`** — each names one customer and misreads for the
  other. The shake row is why the word cannot be visual.
- **`burst`** — reads well, but suggests repetition, which is `pulse`.
- **`ping`** — the right shape, spoken for by networking.
- **`env`/`envelope`** — cannot name one envelope while `adsr` is another.

`kick` is percussive, is a verb applied to the stream, and sits in the
vocabulary `adsr` came from.

**Design decisions, each with its reason:**

- **Ports, not statics**, same as the `adsr` ruling: durations, and rill
  has no duration static kind.
- **Linear segments, `ramp`'s reading of a duration** — how long the
  segment takes, whatever level it starts from. So `kick 20ms 400ms` is
  twenty milliseconds up and four hundred down and reads as what it says.
  Curves compose on top (`| shape out`): one word for one job, rather
  than a curve knob on every envelope in the language.
- **`span` is captured in state at each segment's start**, which is the
  family pin (a parameter change applies to the next segment and never
  retimes the one in flight).
- **The next segment starts when the last one ENDED**, not when we
  noticed. A slow frame must not stretch the envelope.
- **Both durations on one lane**, refused naming both ports. Two
  consecutive stretches of one timeline cannot be in different units.
  `ease`'s `up`/`down` are exempt because they never run together — that
  asymmetry is written down at `sameLane` rather than left to be argued.

**Chris's brief said "stops at ε"; it stops exactly**, and that is a
deviation worth recording rather than a liberty. ε is what an
*exponential* approach needs, because it never arrives. A linear segment
has an end, so `kick` lands on exactly 0 and goes quiet — the same
ruling `ramp` got at tier-2 close, for the same reason: a fade that
stopped one ε short of home would be a visible band.

**Six mutations. Five bitten, one SURVIVED and became a gate.** Turning
the segment walk from a `while` into an `if` produced the right *value* —
a frame long enough to skip both segments clamps at the decay's target,
which is 0 either way. What differed was whether the envelope was
*over*: with an `if` it sits in its decay phase one more frame and arms
one more tick. The value could not tell them apart, so the new gate asks
the eval counter. "A rather than B" for the fourth time this campaign,
and the fourth time it has been the discriminating *input* that was
missing rather than the assertion.

Also removed while building: a "publish 0 at rest" branch that could
never run. An idle envelope has span 0 and `from == to == 0`, so the
ordinary path already answers 0. That is the `is_body` mistake — a guard
that reads as a decision and is a decoration — and the ledger says delete
it with the reason at the site.

## `adsr` — the held envelope (2026-08-26, item 7)

`kick` fires and is over; `adsr` watches a **gate** and does what the gate
does. Four positional PORTS in the conventional a-d-s-r order — **that
order is a cultural constant and rill does not get a vote** — with
`a`/`d`/`r` durations and `s` a level.

**Ports, not statics: CC's lean, ruled by Chris as the deviation from his
first wording.** Three of the four are durations and rill has no duration
static kind; and a live release is worth having. That last point paid for
itself immediately — the pin below is only *gateable* because the release
can come from a path.

**The pin (Chris, 2026-08-26): a parameter change applies to the NEXT
segment and never retimes the one in flight.** The same rule `step`'s
live array follows when it carries its index. Implemented by capturing a
segment's span in state when it starts, never re-reading it.

**The one place the seam shows, and it is gated rather than left as a
surprise:** `sustain` is a *hold*, not a segment, so it follows its port
live. Move it during the decay and the decay finishes at the target it
was given, then the hold picks up the new value — a step at that boundary,
exactly one, and only if someone moved a parameter mid-decay. The
alternative (freezing the sustain at decay's end) makes a live sustain
impossible, which is most of what ports bought.

**A held sustain arms no wake.** The sustain and idle phases are *rests*,
not segments: they have no end to reach, so the segment walk stops on
them and nothing is scheduled. An envelope holding a note costs what a
constant costs. Gated on the eval counter, because a value that stays put
looks identical to one being recomputed — and gated in both directions in
one test, since a flat counter otherwise proves only that the node never
ran.

**Five mutations. Four bitten, one SURVIVED, and it was a claim with no
gate at all:** freezing the sustain level. The docs said it was live and
nothing tested it — the exact shape the re-probe kept finding. The gate
added for it now covers both halves of the claim in one program (the
decay that must not swerve, the hold that must follow) and bites both.

The `in` port is a **boolean**, not a number: a gate is held or it is not,
and `| > 0` is one word away for a path that carries a level.

## `step` — the sequencer (2026-08-26, item 8)

A rousing in, the **next** element out. `nth` and `choose` pick; nothing
walked.

**The modes COMPOSE rather than being five alternatives, and this is a
recorded deviation from Chris's wording.** He wrote: *"Modes as bare-word
flags: default runs once and the wave ends; `loop`, `bounce`, `reverse`,
`random seed <s>` (with replacement), `shuffle seed <s>` (a fresh
permutation per pass, no repeats within one)."* His own description of
`shuffle` is what argues against the flat reading: **a fresh permutation
per *pass*** — and passes are what `loop` means, so `shuffle` and `loop`
have to be sayable together or `shuffle` can only ever describe one pass.
Once two of them compose the flat list is already gone, and `loop
reverse` — a camera cycling backwards forever — is something a reader
wants on their first afternoon.

So: two independent choices and one modifier.

    ORDER   sequential (default) · `random` (with replacement) · `shuffle`
    END     once, and the wave ends (default) · `loop` · `bounce`
    `reverse` — sequential only: start at the end and walk down

The combinations that cannot mean anything **refuse at mount, naming both
words**: two orders, two ends, `reverse` or `bounce` on a random order
(bounce turns round inside a fixed order, and a random one has none), and
a `seed` with nothing to seed. That last is not pedantry — `step [1, 2]
seed 7` is someone who meant to write a mode, and a knob that silently
does nothing is how a language loses trust.

**`shuffle`'s permutation is DERIVED, not stored.** State is a pass number
and a position; the permutation is Fisher–Yates over `seed +% pass *%
golden` recomputed per emission. A stored table would be stale the moment
the live array changed length, and a dump would carry a table describing
nothing. `random` re-seeds from the emission counter exactly as `rand`
already does — one PRNG family (beat 4's pin) is kept: `rand`, `shuffle`
and both of these draw from xoshiro256++.

**The array is live and the cursor carries**, clamped to the new length,
never restarted (Chris's pin). And cursor, direction, pass and emission
count are node state, so the sequence **rides the dump**: a sequencer
that started over on restore would be a different instrument.

**A found bug, and it had been sitting there since beat 3a.** `arrayIn`
read **port 0** and always had, because every array consumer until now
took its array as its primary input. `step`'s port 0 is the *rousing*, so
it refused every program with "'in' is boolean, not an array" — a real
refusal, about the right node, saying the wrong thing, and invisible
under `mountFixture` because a refusal there is silent. Split into
`arrayInAt(ctx, port)` with the assumption named at the site.

**Six mutations, four bitten and two findings — one about the gate, one
about the mutations.**

- **The gate could not tell silence from repetition.** A value stream
  holds its last, so "the sequence ended" and "the sequence re-emits its
  last element forever" leave the same bytes in the slot; identical
  output is suppressed, so not even a `tally` downstream can separate
  them. The **live array** is what separates them: once ended, change the
  list under the cursor and an ended sequence stays silent while a
  stepping-in-place one emits whatever now sits at its index. The gate
  now does that, and the mutation bites.
- **Two of the six mutations were no-ops I had to catch myself** — one
  wrote a variable that the line below overwrote, one left the `return`
  in place under the lines it replaced. `mutcheck` reports SURVIVED for a
  no-op exactly as it does for an unwatched gate, and the polarity that
  makes it safe against harness failures does not make it safe against a
  mutation that does not mutate. Read the diff, not just the verdict.

**The output is a VALUE**, matching `nth`, `choose` and `rand`. The
consequence is stated in the manual rather than hidden: two identical
elements in a row are one write, so `random` drawing the same element
twice looks like one draw downstream. An occurrence-output twin is the
fix if the MIDI stack ever needs it; recorded in `rill-tier2.md` §8 with
that trigger rather than guessed at now.

## The identity gate — the manual is the source (2026-08-26)

Ruled by Chris after the book-runs recon: **the manual is the source; the
book cites it. Evidence cites the claim, never the reverse.** So when the
two disagree the manual is right, the book cell is what gets fixed, and
the failure message says which file to open.

It exists because of a measurement rather than a hunch. The recon counted
**29 rill statements written byte-identically into both `rill-manual.md`
and `idioms.rillbook`**, with nothing checking that they still agree. That
is the mechanism the inverted flagship used, in numbers: `above 0.3 0.2`
was one sentence copied into §6f, into §11, into the book and into a gate,
and each copy was separately wrong. Parsing every copy proved every copy
compiled.

**Both ways, and Chris named the second direction as a requirement:**

1. every listed row is still in both files, byte for byte;
2. **the list covers every statement the two files share.** Without this
   a *new* shared program drifts while the gate stays green — the
   hollow-filter shape, where coverage is whatever happened to be true on
   the day the list was written.

Plus a guard that neither extractor may go quiet (a renamed fence or a
JSON drift empties one side, and an empty side makes every check above
vacuously true).

Statements are compared **trimmed**, joining continuation lines: the
manual indents a continued pipeline under its head and the book does not,
and they are still the same program. Indentation is layout.

Four mutations, all bitten: the manual's copy of the flagship edited, the
book's copy edited, a new program added to both files and left off the
list, and the manual extractor fed an empty document.

One near-miss worth recording, because it is the lesson from `step`
arriving one commit later: the first attempt at mutation 1 asserted three
occurrences of the flagship line in the manual and there were two, so the
edit never applied and `mutcheck` dutifully reported SURVIVED on a clean
tree. The assertion caught it. **Read the diff, not just the verdict** —
a no-op mutation and an unwatched gate look identical from the outside.

## Driving the book's own text (2026-08-26, recon phase 2)

Chris's build order after the recon: **identity gate → after-cell
correctness → before cells.** This is the middle one, and it is the
inverted flagship's actual lesson rather than its symptom.

`bookCell(name)` is `manualRecipe(heading)` one file over: a gate that
drives it cannot be asserting something the book does not say. The
existing shape it replaces is the problem in miniature —

```zig
"[{armed: false}, {armed: true}] | map (.armed) | reduce (or) | set plane.any"
```

— which proves `reduce` folds, and says nothing about whether the book's
page called *"is any contact armed"* uses `or` or `and`. Swap them and
the cell still parses.

**Scope, and why it is not all forty after-cells.** The identity gate
pins 29 statements byte-identical between the manual and the book, so a
gate driving the manual's text is already driving the book's — that
result fell out of phase 1 and shrank phase 2 before it started. What is
left is the cells with no behaviour gate anywhere, and among those the
ones whose claim is a **sense**: a direction, an ordering, a which-one.
Sense is what parsing cannot see and what the flagship got wrong.

Seven gates, one assertion each, in the row's own words:

- **`nth 0` is the oldest reading and `last` is the newest** — the two
  cells sit a page apart and swapping them leaves both parsing. Driven
  *together*, over one window, so the gate cannot agree with a swap.
- **the loudest recent reading is the `max`** — 11 among 4 and 6, so
  neither "hold the newest" nor "hold the oldest" passes it either.
- **any-armed is `or`** — one armed contact among unarmed ones.
- **`range` clamps** — the page exists to say `range` is not `lerp`; the
  gate drives the shaped source right round and asserts it never leaves
  the interval named in the cell.
- **the charge rises and stops at its cap** — both halves of "capped".
- **the eased target moves toward it and settles.**
- **the camera cycle returns to its first position** — `loop` is the
  claim, and a cell that ran once would look identical for three presses.

Six mutations, all bitten, and the layering showed itself: editing the
book's `array-oldest` cell was caught by the **identity gate first**,
because that row is shared with the manual. Swapping it in *both* files
so identity holds leaves only the behaviour gate — and that bites too.
Two layers, and the outer one fails earlier with a better message.

## The before cells, gated on their badness (2026-08-26, recon phase 3)

Chris: *"An argument nothing runs is prose."* The before cells are the
campaign's whole case for admitting a word — *this is what the ask cost
without it* — and they were the last part of the book that was pure
assertion. A before cell that quietly stopped being bad would mean the
row no longer needed its word, and nobody would know.

Narrowed on his instruction, and the narrowing is what made the pass
affordable: **one assertion each, of the badness the row itself claims,
in the row's own words, and no timeline longer than it takes to show the
claim.** Not a faithful reproduction of every awkwardness — the claim,
executed. The recon had costed this as 17 full reproductions; it is four
short gates.

- **night-falls fires on every crossing.** The row says *"a light level
  wobbling either side of the threshold at dusk switches the lights on
  and off repeatedly"*, so the gate counts the writes over the same dusk
  wobble the after cell is driven through: **three, against the after
  cell's zero**.
- **the flash rises and never comes down** (below).
- **the arpeggio counter grows, unbounded, on the plane** — three hundred
  beats, three hundred and counting, no wrap and no cap. This is
  `integrate`'s required clamp argued from the other side: an accumulator
  living on the plane has nothing to make it stop, and it is saved with
  the program, so it is a corpse that gets copied.
- **the held note goes to full — there is no sustain.** One register
  chases one target; a sustain is a second one. Held, the before sits at
  1 where the after sits at its 0.7.

**The pass paid for itself before it was written: two of the book's own
notes claimed a badness that is not there.** Both said `ease` *"never
quite reaches zero, so it costs a frame forever"*. `ease` **stops** —
`converged()` at ε, no further wake — and beat 1a has gated exactly that
since the register family landed. Two wrong sentences, in the file whose
job is evidence, written by someone who had gated the opposite.

Both corrected in place, with the correction visible rather than
laundered. And what replaced the first one is considerably worse than
what it claimed: **nothing ever lowers `hit_gate`.** A rill may not write
a path it also subscribes to, which is why the workaround is two
programs — and the second program has no way to put the gate back down.
So `ease` chases a 1 that never leaves and the flash stays on for good.
The workaround the re-probe reached for does not merely cost two
programs; as written it does not turn off.

Three mutations, all bitten: a before cell quietly "fixed" to use
`below`, a before cell edited to reach the sustain after all, and — as
corroboration for the correction — `ease` made to stop converging, which
beat 1a's own register gates catch immediately.
