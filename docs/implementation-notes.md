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
