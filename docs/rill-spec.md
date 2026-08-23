# rill — reactive dataflow evaluator for Substrate-backed applications

**Status:** Design spec v0.1 · 2026-08-23
**Repo shape:** standalone Zig library (`rill`), house style alongside `radix` / `struple` / `loom`. Consumed by Matryoshka; usable by any Substrate-backed host.

---

## 1. What rill is

rill is a small, live, reactive dataflow evaluator. A rill program is a flat graph of typed
operators connected by streams of struple values. Programs are **mounted, not run** — they sit
on the host's data plane, subscribe to paths, and re-evaluate incrementally when inputs change.
There is no run button and no execution wires: **propagation is the only control flow**, and
operators are the valves that decide whether a change continues downstream.

The text form and the visual graph form are two views of one AST. Everything expressible in one
is expressible in the other, and they round-trip.

### Design principles (normative)

1. **The pipe is the 90% case.** A one-line pipe chain must remain exactly as convenient as the
   existing console. Every current console one-liner must parse and behave unchanged.
2. **Names only at the joints.** Syntax complexity is paid only where the graph stops being a
   chain (fan-out, fan-in, multiple outputs).
3. **No execution pins.** There is no `if` statement and no exec wire. Selection and gating are
   ordinary operators over data.
4. **Everything is a struple.** Slot values, program serialization, the wire protocol to the
   plane — all struple. The program's own state is inspectable through the same protocol as
   everything else.
5. **The library borrows a plane, it does not own one.** rill is handed a plane interface
   (subscribe/read/write). Matryoshka hands it the real data plane; tests hand it a mock.
6. **Deterministic.** Same delta sequence in ⇒ bit-identical slot states out, every tick.
   This is the frozen-reference discipline applied to programs.
7. **defs are archetypes.** A user-defined operator is indistinguishable from a built-in or a
   host-injected one. Its instances are addressable; its internals expose knob paths.

### Non-goals (v0)

- Not a general-purpose language. No user-visible closures, recursion, or looping constructs.
- No feedback cycles in v0 (detected and rejected with a pointed error). A deliberate
  one-tick-delay feedback operator (`~`-style) may come later.
- No lazy/pull evaluation semantics exposed to users. (The evaluator may skip work internally,
  but the *semantics* are "all live branches exist".)
- Visual graph editor is a separate client. rill only guarantees the AST round-trips.

---

## 2. Layering

```
┌───────────────────────────────────────────────┐
│ host (Matryoshka)                             │
│  · injects domain operators (bevel, play, …)  │
│  · hands rill its Plane implementation        │
│  · mounts/unmounts programs                   │
├───────────────────────────────────────────────┤
│ rill (this library)                           │
│  · parser  → flat graph                       │
│  · slot arena (struple values, dirty bits)    │
│  · topo tick: coalesce → mark → evaluate      │
│  · core operator set (select, where, math, …) │
│  · operator registry (built-in = injected     │
│    = def-minted; one registration path)       │
│  · serialization (whole program = one struple │
│    dump: nodes, wires, types, current values) │
├───────────────────────────────────────────────┤
│ Plane interface (borrowed, not owned)         │
│  · subscribe(path) → deltas                   │
│  · read(path) → struple                       │
│  · write(path, struple)                       │
└───────────────────────────────────────────────┘
```

The Plane interface is deliberately minimal. Matryoshka backs it with the Substrate data plane
over the existing main-thread drain (rill writes ride the same inbox as knob writes; rill never
touches the store off-thread). The test suite backs it with an in-memory struple store plus a
scripted delta feed.

---

## 3. Syntax

### 3.1 Grammar sketch (informal EBNF)

```
program     := statement*
statement   := chain | defstmt
chain       := expr ( "|" opcall )* ( "as" namelist )?
expr        := opcall | path | literal | record | name
opcall      := opname arg*
arg         := literal | path | name | record | kwarg
kwarg       := portname ":" ( literal | path | name )
record      := "{" ( field ("," | NEWLINE) )* "}"
field       := fieldname ":" ( literal | path | name )
path        := "plane" "." segment ("." segment)*
             | "plane" "." segment ".{" fieldname ("," fieldname)* "}"
namelist    := name ("," name)*
defstmt     := "def" opname "(" portdecl ("," portdecl)* ")" "=" chain+
portdecl    := portname (":" typename)?
```

- Statements are newline-separated; a chain may wrap after a `|`.
- `name` is a local stream name bound by `as`. `path` is a plane path. `literal` is a struple
  literal (number, string, bool, color, vec…, per the struple type set).
- Positional args bind to an operator's declared ports in order; `port: value` binds by name.
  Positional-for-the-common-case, keyword-always-available.

### 3.2 The pipe (90% case — unchanged)

```
cube 2 | bevel 0.1 | rot 45
```

Left operand of `|` feeds the first (primary) port of the right operator. This is today's
console, verbatim.

### 3.3 `as` — naming an edge (fan-out)

```
cube 2 | bevel 0.1 as base
base | shell 0.05 | rot 45 as lid
```

`as` binds the value at that point in the chain to a local name. A name may be consumed by any
later statement in the same program. Names are single-assignment.

### 3.4 Names as arguments (fan-in)

```
boolean subtract base lid
lerp base lid t: 0.3
```

A bare name in argument position pulls that stream in. With declared ports, `b: lid` is always
available when positional order is unclear.

### 3.5 Multiple outputs

```
split base as inner, outer
inner | color red
outer | color blue
```

An operator may declare several output ports; `as a, b` binds them in declared order.
(Keyworded output binding `as pass: p, fail: f` is reserved for later if needed.)

### 3.6 Records (live tuples)

```
{ health:  plane.player.health
  stamina: plane.player.stamina
  mana:    plane.player.mana } as playerStats
```

A record constructor whose fields happen to be live. Named fields, not positional — downstream
reads `playerStats.mana`. Sugar:

```
plane.player.{health, stamina, mana} as playerStats
```

### 3.7 Plane paths are subscriptions (everywhere)

Any `plane.…` path in any argument position is a live reference. There is no special subscribe
form. `bevel 0.1` and `bevel plane.settings.bevelRadius` differ only in that the second has an
upstream edge.

Field access on a record stream (`playerStats.mana`) is projection, an implicit operator.

### 3.8 Sinks

```
playerStats.health | over 100 | clamp 0 100 | set plane.ui.healthbar.value
```

`set <path>` writes its input to the plane (through the host's write path — in Matryoshka,
the main-thread drain, so rill writes are ordered with everything else and appear in the
command log / undo machinery like any other authored change, subject to the host's
mutating/affects_output classification).

### 3.9 `def` — subgraph operators

```
def rivet(m: mesh, n: int) =
  m | scatter n as pts
  pts | instance bolt
```

- Ports in, streams out; a def **closes over nothing** — no reaching into ambient scene state.
  This keeps defs reusable across Projects and keeps dirty-propagation tractable.
- The last statement's value is the (primary) output; multi-output defs name outputs with a
  final `as`.
- A def registers an operator through the exact same registry path as built-ins and host
  operators, and gets the same graph box, the same `help`, the same tab-complete.
- **defs are archetypes.** Instances are flattened into the graph with a name prefix; internal
  `as` names become knob paths under the instance: if `panel` is a `rivet` instance whose
  internals bevel, `panel.rivet1.bevel.radius` is addressable, gradeable, animatable from
  outside without `rivet` declaring it — sparse overrides, exactly as chips/archetypes work.
- defs live in the rig/Project like everything else: cut, mounted, provenance-tracked. A pack
  can ship operators, not just assets.

### 3.10 Optional sugar (later, not v0)

Faust-style symmetric split/merge for the tidy cases only; names handle everything irregular:

```
noise <: lowpass 200, highpass 2000 :> mix
```

Pattern-match sugar compiling to `select` over a table:

```
match plane.player.state { idle: idleAnim, running: runAnim }
```

---

## 4. Semantics

### 4.1 The tick

1. **Collect** plane deltas since last tick (host decides tick cadence; Matryoshka ties it to
   the frame).
2. **Coalesce** per path: at most one new value per subscribed path per tick. A node sees a
   consistent snapshot of all its inputs as of the tick.
3. **Mark** dirty bits on the slots subscribed to changed paths.
4. **Evaluate** dirty nodes in topological order. An operator that emits marks its downstream
   slots dirty; one that doesn't emit lets the wave die there.
5. **Flush** `set` writes through the plane's write path.

No node evaluates twice in a tick. If health and stamina both move in one frame, downstream of
`playerStats` evaluates once with the new record.

### 4.2 Values vs occurrences (the one type bit that matters)

Every stream is either:

- **value** — a continuous quantity. Value slots **compare-and-suppress**: a write of the same
  bytes does not propagate (20→20 is silence; storms die naturally; idempotent by default).
- **occurrence** — a discrete event. Occurrences **always propagate**, same payload or not
  (a trigger pulled twice is two pulls). `where`, `changed`, `dropped_below` etc. emit
  occurrences.

This is one bit of type information on the stream; users never think about it and both worlds
behave correctly. Operators declare the kind of each port and output.

### 4.3 Conditionals are operators, not syntax

Two different things hide under "if"; they get different operators.

**Selection** — choosing between values. All branches exist as live data; one is chosen (or
blended) per tick:

```
select plane.player.underwater blueGrade normalGrade | set plane.grade.active
lerp   dayGrade nightGrade t: plane.sky.duskAmount    | set plane.grade.active
```

`select` is the hard-edged degenerate case of `lerp`/`smoothstep`; in a differentiable-fields
engine the blend is usually the honest answer. Nothing is "not executed" — the evaluator may
lazily skip an unchosen expensive branch as an *optimization*, but semantics stay "both exist".

**Gating** — conditionally doing. Occurrence streams and filters:

```
plane.player.health | dropped_below 20 | play heartbeat
plane.enemy.count   | where (= 0)      | trigger doorOpen
```

An untriggered gate is silence; there is no else-wire. Where the else is wanted:

```
partition (< 20) hp as low, ok
low | play heartbeat
ok  | stop heartbeat
```

Kernel: `select`, `lerp`, `where`, `partition` (+ `changed`, comparators). **Do not build an
`if` statement.** No exec pins, ever — everything is data; "control flow" is which streams
carry values this tick.

### 4.4 Cycles

v0: static cycle detection at mount time. Error message points at the loop
(`programs.hud: cycle — node set(plane.x) feeds node read(plane.x) via …`), the program refuses
to mount, the engine never spins. Path-level analysis: a program that writes a path it also
subscribes to (directly or through the graph) is cyclic. Deliberate feedback later via an
explicit one-tick-delay operator.

### 4.5 Determinism

- Topological order is stable (tie-break by node id, node ids assigned in parse order).
- Coalescing is per-tick and last-write-wins per path within the tick, in plane-delta order.
- Given the same mounted program and the same delta sequence, slot states are bit-identical
  every tick. This is a hard acceptance gate (see §8).

### 4.6 Budget behaviour (later, designed-for now)

The tick is Sponge-shaped: only touch what changed, in priority order. A future increment lets
the host hand rill a budget; expensive programs coarsen (skip ticks / batch coalescing windows)
under pressure like everything else in the engine. Nothing in v0 depends on this, but the tick
loop should not preclude it (keep per-node cost counters from day one — they're nearly free and
they feed both the budget hook and the debug view).

---

## 5. The flat graph

- One arena of nodes; one arena of slots. No nesting, no call stack, no scopes.
- A def instance is **flattened at mount**: its nodes are copied into the same arena with the
  instance-name prefix. The topo sort does not know defs exist. The knob-path-under-instance
  property falls out of the prefixing.
- **Slots are struples.** Every slot has: struple type, current value, dirty bit,
  value/occurrence kind, and a stable path. Suggested addressing:
  `programs.<program>.<node>.<in|out>.<port>` — so any wire is watchable by the console with
  the machinery that already exists (scope a slot like the histogram, log it, graph it). The
  wire-lighting debug view is *a subscription to the program's own struples*, not a feature.
- Wire-time type checking is table lookup: ports declare struple types; the parser rejects
  `mesh → number` with a decent message. No separate type system.
- **Serialization is trivial and total:** the whole program — nodes, wires, slot types,
  current values — is one struple dump. Rig save, Project cut, diff, and import/provenance
  all work on programs with zero new code. A mounted game rule and a mounted light rig are the
  same kind of object.

---

## 6. Operator registry

One registration path for all three origins (built-in / host-injected / def-minted):

```zig
pub const PortKind = enum { value, occurrence };

pub const Port = struct {
    name:  []const u8,
    ty:    struple.TypeTag,     // struple-typed
    kind:  PortKind = .value,
    optional: bool = false,
};

pub const OpDef = struct {
    name:     []const u8,
    inputs:   []const Port,
    outputs:  []const Port,
    help:     []const u8,
    // pure = output depends only on inputs (evaluator may cache/skip);
    // effect = touches the world through the plane (set/play/trigger)
    class:    enum { pure, effect },
    eval:     *const fn (ctx: *EvalCtx, in: []const struple.View, out: []struple.Builder) EvalError!Emit,
};

pub const Emit = packed struct { mask: u32 }; // which outputs emitted this tick

pub fn register(reg: *Registry, def: OpDef) !void;
```

- `Emit.mask` is how an operator "decides the wave continues": `where` returns mask 0 to eat a
  value.
- Host injection is just `register` calls at startup. **Seed Matryoshka's registry from the
  existing ~90 console verbs** so day one is "the existing console, now composable" — the
  CommandDef inventory (verb/subop/args/mutating/affects_output/replay_safe) maps onto OpDef
  nearly field-for-field; args with kinds become typed ports. Compatibility of every current
  one-liner is the first test case (§8, gate G1).
- `def` compiles to a subgraph template + an OpDef whose eval is "flatten me at mount".

### Core operator set (rill built-ins, v0)

| group | ops |
|---|---|
| flow | `select`, `lerp`, `where`, `partition`, `changed`, `latch` |
| events | `dropped_below`, `rose_above`, `edge` (value→occurrence adapters) |
| math | `add sub mul div min max clamp abs floor round`, comparators |
| record | record construction `{…}`, projection `.field`, `merge` |
| plane | `set <path>` (sink), path read (implicit source) |
| util | `const`, `tap` (debug passthrough → log bus) |

Everything domain-flavoured (`bevel`, `scatter`, `play`, `trigger`, `camera`, …) is host-injected.

---

## 7. Plane interface (borrowed)

```zig
pub const Plane = struct {
    ctx: *anyopaque,
    subscribe:   *const fn (ctx: *anyopaque, path: []const u8, sub: SubId) PlaneError!void,
    unsubscribe: *const fn (ctx: *anyopaque, sub: SubId) void,
    read:        *const fn (ctx: *anyopaque, path: []const u8, out: *struple.Builder) PlaneError!void,
    write:       *const fn (ctx: *anyopaque, path: []const u8, val: struple.View) PlaneError!void,
    // host pushes deltas into the evaluator between ticks:
    //   rill.feed(delta: {path, value, seq})
};
```

Same fn-pointer discipline as PackResolver / the audio blob resolver: rill never learns
Substrate/radix internals; Matryoshka never leaks them. The mock plane for tests is a struple
map plus a scripted delta feed — no engine required.

In Matryoshka specifically: writes ride the main-thread inbox (single-writer store discipline
holds); the tick runs on the main thread at frame cadence; subscriptions ride pubsub.

---

## 8. Acceptance gates (pre-registered, house style)

- **G1 compatibility:** every existing console one-liner in the verb inventory parses to a
  single-node (or chain) rill program and produces the identical dispatch. Table-driven over
  the CommandDef registry.
- **G2 determinism:** golden delta-sequence tests — same feed in, bit-identical slot-state
  dump out, N ticks, across ReleaseFast/Debug. (Frozen references for programs.)
- **G3 coalescing:** two writes to one path in a tick ⇒ downstream evaluates once with the
  last value. Health+stamina in one tick ⇒ record downstream evaluates once.
- **G4 suppression:** value 20→20 does not propagate; occurrence with identical payload does.
- **G5 gates:** `where` false ⇒ nothing downstream evaluates (assert via eval counters);
  `partition` routes every input to exactly one side.
- **G6 cycles:** the read-your-own-write program is rejected at mount with the loop named.
- **G7 def flattening:** a def instance's internal knob path is settable from outside and the
  override round-trips through serialize/mount.
- **G8 serialization:** mount → dump → unmount → mount-from-dump → dump is byte-identical.
- **G9 no-leak / ReleaseFast clean**, as everywhere in the house.

Perf is measured, not gated, in v0 — but per-node eval counters and per-tick µs land in the
first build so the numbers exist before anyone argues about them.

---

## 9. Build order

1. **Parser → flat graph** (chains, `as`, kwargs, records, paths). G1 shape against a stub
   registry.
2. **Slot arena + tick** (coalesce, mark, topo evaluate, suppression, occurrence bit). G2–G5.
3. **Core operators** (§6 table) + cycle detection at mount. G6.
4. **Plane interface + mock plane**; `set` sink; golden delta tests end-to-end.
5. **Serialization** (one struple dump). G8.
6. **`def`** (template + flatten + knob-path prefixing). G7.
7. **Matryoshka adoption:** Plane impl over the drain/pubsub, registry seeded from CommandDef,
   `mount`/`unmount`/`programs` console verbs, slots on the plane at `programs.…`.
8. **Console niceties:** tab-complete from OpDef ports, `help <op>`, `tap` → log bus,
   wire-lighting in the web console (a client feature — subscribe to `programs.…` slots).

Steps 1–6 need no engine at all and land as pure library work with the mock plane.

---

## 10. Deferred (explicitly parked, with the reason)

- **Feedback (`~` + one-tick delay):** wants its own semantics note; nothing in v0 needs it.
- **`<:` / `:>` split-merge sugar:** cosmetic; names cover it. Revisit after real programs exist.
- **`match` sugar:** compiles to `select` over a table; add when a real program wants it.
- **Budget/coarsening hook:** designed-for (cost counters from day one), wired when the host
  has a second paying customer for it (particles behaviour fields are the likely one).
- **Time patterns (Tidal-style `every 4 (rev)`):** the behaviour-fields conversation; belongs
  with particles/animation, not the core.
- **Lazy skip of unchosen `select` branches:** an optimization behind unchanged semantics;
  do it when a branch is measurably expensive.

---

## 11. Vocabulary

A program is a **rill**. You **mount** a rill. Files are `.rill`. "There's a rill watching
player health." Small streams, joining and splitting — that's the whole system in one word.
