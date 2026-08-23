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

## Shape of the code

| file | what |
|---|---|
| types.zig | TypeId/TypeTable, accepts(), literal classification, number/bool decode |
| registry.zig | Port, StaticDecl, OpDef, Emit, EvalCtx, Registry — the one registration path |
| parser.zig | tokenizer + parser → flat graph; sections, records, defs, two-word ops |
| graph.zig | Node/Slot/Source, Program (one arena), downstream adjacency, cycle check |
| ops.zig | the §6 core set, one comptime table |
| eval.zig | Runtime: mount/feed/tick/setInput/readSlot; suppression; write flush |
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
