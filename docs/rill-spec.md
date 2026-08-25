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
8. **Silence must be spoken to be heard** (2026-08-24). Propagation is push-based, so it can
   only report what *happened* — never what stopped being. A dataflow evaluator therefore
   cannot subscribe to a thing that is not there: **absence is unobservable by construction.**
   Every absence a program cares about must be *reified as a presence* — a death is a
   `despawned` occurrence, not a path that quietly stops existing; a timeout is a message, not
   a reply that failed to arrive; an empty program list is `"programs": []`, not an omitted
   key. The failure mode is always the same and always quiet: a rill watching a despawned
   entity holds its last reading forever, so `dropped_below 20` sits armed on a corpse's final
   number, indistinguishable from a man standing very still.

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
chain       := expr ( "|" (opcall | alsoblock) )* ( "as" namelist )?
expr        := opcall | path | literal | record | array | name
alsoblock   := "also" "{" branch (NEWLINE branch)* "}"
branch      := opcall ( "|" (opcall | alsoblock) )*
opcall      := opname arg*
arg         := literal | path | name | record | array | kwarg
kwarg       := portname ":" ( literal | path | name )
record      := "{" ( field ("," | NEWLINE) )* "}"
field       := fieldname ":" ( literal | path | name | record | array )
array       := "[" ( element ("," | NEWLINE) )* "]"
element     := literal | path | name | record | array
path        := "plane" "." segment ("." segment)*
             | "plane" "." segment ".{" fieldname ("," fieldname)* "}"
namelist    := name ("," name)*
defstmt     := "def" opname "(" portdecl ("," portdecl)* ")" "=" chain+
portdecl    := portname (":" typename)?
```

- Statements are newline-separated; a chain may wrap **after** a `|`, and a line that
  *begins* with `|` continues the statement above it. No statement can start with a pipe,
  so a leading `|` has only ever had the one meaning.
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

**Console words (v0.1, agreed 2026-08-23):** a bare word that is *not* a bound name, alias, or
operator becomes a **string literal** when — and only when — it binds a string-typed port:
`volume set v1 0.5 2 1` is the entire console grammar, and entity names are strings. The port
type keeps the coercion narrow; an unknown word anywhere else stays a loud parse error, and
bound names always shadow (quote the text if a name collides). A string port may declare a
closed `one_of` value set — the same list the console tab-completes from — and a bound literal
is checked against it at parse: tab-complete metadata, finally enforced. `/` is a name-interior
character (rill has no `/` operator; division is `div`), so store-spelled knob paths like
`render/grade/exposure` are single words and ride the same coercion.

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

### 3.6a Array literals (v0.3, tier 2 beat 2a, 2026-08-25)

```
[0.2, 1, 0.6, 0.05]
[{x: 0, y: 3, z: 0}, {x: 2, y: 3, z: 1}]
[plane.a, plane.b]
```

The record literal's positional twin, and **live for the same reason**: each element is a
wire into one variadic node, so an element that is a path or a name re-evaluates the array.
Arrays were already a value kind — `window` emits one, `stats` consumes one — so the literal
is the missing half of something that existed. Additive by construction: `[` and `]` lexed as
inert `raw` characters before this, legal only inside a tail, so no existing program can
change meaning. Tails are unaffected (a tail slices the raw source between token offsets and
never reads a token's kind).

An array is **not a buffer**: values are immutable per tick, so there is no element
assignment, no append, and no loop over one. `[]` is legal, unlike `{}` — the empty record is
refused because `{` also opens a fan-out block, while `[` opens nothing else.

`[0, 2, 0]` does not coerce to a position. One thing, one spelling.

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

**The sink shape is `<verb> <path> [value]`** (v0.2, ratified 2026-08-24), shared by `set`
and `notify`. Port 0 is always the **rousing** — it decides *when* — and the optional `value`
port, when bound, decides *what*:

> **Piped value: write what's flowing. Bound value: write this, because something flowed.**

```
plane.hp | clamp 0 100 | set plane.ui.bar                      // what's flowing
plane.signals.horn | set plane.gate.drawbridge_target 1        // this, because something flowed
plane.enemies | rose_above 0 | notify plane.signals.horn { kind: "approach" }
```

Unpiped, the value binds port 0 and is both rousing and payload, so the console's whole
`set <path> <value>` grammar is untouched. A change in `value` alone is not a write — the
payload says *what*, the rousing says *when*, the same rule `inc` applies to `by`.

Without that port, "on a rousing, write a constant" has no spelling: the pipe takes the only
port, so the constant has to be held in a `latch` and sampled — three nodes to say one word.
`notify` hit that wall first (the canonical sentinel carries a record), `set` hit it one
scenario later ("at the sound of the alarm, raise the drawbridge"), and the second time made
it the sink *shape* rather than one op's exception. `notify` is otherwise exactly `set`: same
ports, same write, same eval. What distinguishes it is intent — `notify signals/horn` says
"this is a sighting" where `set` would read as "this is the state" — and the path's own
mailbox policy, not the verb, still decides whether the write appends.

**`inc <path> <by>`** adds instead of replacing (v0.2, ratified 2026-08-24). It is the one
sink whose port 0 is a **rousing rather than a payload** — an increment takes nothing from
the stream, so the in-flowing value says *when*, and `by` says *how much*:

```
plane.gate.enemy_count | rose_above 0 | inc plane.defense.sightings 1
```

Counters were otherwise inexpressible: `plane.x | add 1 | set plane.x` reads a path it
writes and the cycle check (§4.4) rightly refuses it. A blind delta reads nothing, so it
passes legitimately — and being commutative it is *more* deterministic than
read-modify-write, because arrival order stops mattering. Numeric slots only; `by` is
required (unpiped, `inc p 5` would otherwise bind 5 to the rousing port and silently
default the amount); a change in `by` alone is not a rousing; and the host refuses an
accumulate write to a mailbox path, because append and accumulate are different kinds and
a path is one kind.

**`cast <$channel> [value] radius <r> at <pos> [decay <d>]`** (v0.3, grammar stamped
2026-08-25 — rill-casts.md) deposits into a field channel: `inc`'s kin in the accumulate
family, wearing the sink shape unchanged. Port 0 is the rousing; a bound `value` is the
payload; channel and radius are statics. `at` and `decay` are **keyword ports** — the word
introduces the value (`radius 12 at s.gate.pos decay 2s`), because positionally
`cast $alarm 30` cannot say whether 30 is the payload or the radius, and a grammar that
guesses is worse than one that asks. Keyword-declared arguments never bind positionally;
the colon spelling (`at: …`) works too.

```
every 1f { cast $torchlight 0.8 radius 12 at s.brazier.pos decay 4s }

s.gate.enemy_count | rose_above 0
  | also { cast $alarm 1.0 radius 30 at s.gate.pos decay 2s }
  | also { cast $alarm 1.0 radius 30 at s.tower.pos decay 2s }
```

`at` takes a value bound or live — dot-form is a live reference, so a moving caster's
position updates without re-rousing (a change in `at` alone is not a cast, the same §3.8
rule every sink port obeys). Casting in several places from one rousing is two `also`
branches, not a list argument. `decay` is this deposit's leak time-constant, defaulting
from the channel declaration. **Unpiped, the intensity binds port 0 and is both rousing
and payload, so a bare `cast $torchlight 0.8 radius 12 at …` deposits once, at tick 0,
then leaks away** — a standing caster puts a per-tick rousing in front (`every 1f`, §3.12).
This will surprise the first person who writes a brazier, which is why it is said here.

A cast is an effect but **not a path write**: the channel static never enters the write
list, and correctly so — a field has no read side inside rill (readings come from a
standpoint, rill-casts.md §9), so there is no loop for the cycle check to see. Because
the channel is a static, a host can check its existence at MOUNT — Matryoshka refuses an
undeclared channel there, at the same moment capabilities are checked, naming the node —
while eval-time refusals remain for what only eval can know (a non-finite position, a
channel deleted under a standing caster). The deposit
crosses the plane boundary on its own vtable arm (`castFn`), commits through the host's
main-thread drain for deterministic ordering, and per rill-casts.md §11 **stays out of the
log** — fields replay by re-derivation. `to #tag` (coupling) parses when the tag store
exists, not before.

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

### 3.10 `use` — plane aliasing (v0.1, agreed 2026-08-23)

```
use plane.player as p
p.health | dropped_below 20 | play heartbeat
```

Resolved entirely at parse: `p.` expands to `plane.player.` before graph construction. The
alias is *declared* plane-side, so everything that depends on plane refs being syntactically
distinguishable survives intact — unknown bare names stay loud parse errors, `as` bindings can
never silently recapture a path, the def close-over-nothing rule remains parse-enforceable
(`use` is banned inside def bodies for the same reason `plane.` is), and a program's full I/O
contract is still auditable from the text. Bare dotted names falling through to the plane is
**rejected** as a design: silent recapture and typo-subscriptions are the failure modes.
REPL-only affordance permitted: at the interactive prompt, an unresolved dotted expression may
*offer* plane completion — never in a `.rill` file.

### 3.11 Tail ports (v0.1, agreed 2026-08-23)

```
sound play /tmp/loop.wav
sample load pack:horns#audio.stem
```

An operator may mark its **last** input port `tail`. The parser binds the fixed prefix —
statics, then any non-tail ports the pipe didn't feed, positionally — and captures the rest
of the line **verbatim** as a string literal on the tail port. This is the honest shape of a
locator: freeform text, not structure. Console grammars with a `rest` argument map onto it
directly, which is what lets lines like the above parse unchanged (G1) without teaching the
tokenizer about `/`, `#`, or `:`. (Comments are `//`, ruled 2026-08-25 — `#` is the tag
sigil and cannot also be the comment lead. `//` opens a comment only at a token boundary,
which is structural: a name-interior `/` must join two name characters, so a slash-form
path like `render/grade/exposure` can never put two slashes adjacent inside a token.)

- Closed shape, enforced at registration: last input only, string-typed, never variadic,
  and every port before the tail is required — a fixed prefix has no room for maybe-there
  arguments. Kwargs don't exist on a tail operator for the same reason.
- **The tail ends the chain.** Everything to end-of-line is text: neither `//` nor `#`
  starts a comment there (the tail takes the raw line), and `as` does not bind. Piping *into* an operator whose only port is the
  tail is an error — the tail is parse-time text, never a stream.
- **Footgun closed at parse:** an unquoted tail containing `|` is an error — *"tail port
  consumed a pipe — quote the locator or restructure"* — so composing after a tail verb
  fails loud instead of silently swallowing the pipe into the string. A fully-quoted tail
  (`say "a | b"`) unwraps, applies escapes, and may contain anything.

### 3.12 Duration literals (v0.2, ratified 2026-08-23)

```
p.gpu.traversal_ms | window 10s | stats as t
plane.hp | changed | debounce 250ms | tap calm
plane.v | sample 3f as v_lite
```

A number glued to a unit suffix is a **duration** — a distinct struple-typed literal
(`[lane, count]` on the wire), never a bare number. The unit set is closed: `s`, `ms`, `m`
(minutes) on the real-time lane (counted in nanoseconds), `f` on the frame lane, for
engine-side rills where frames are the honest unit. The two lanes never convert — `3f` is
three actual frames, not a faked 50 ms.

- `sample 5` is a **wire-time type error** with the fix named ("write it with a unit: 5s,
  250ms, 3f"); `5x` is an unknown unit, not a number and a name; durations are non-negative;
  frame durations are whole frames. Fractional real-time (`2.5s`) is fine.
- The suffix must be glued: `5 s` is a number and (probably unknown) name, as before. A
  side effect of the gluing rule, ruled acceptable: `2m` was previously two tokens (`2`,
  local `m`) — an accident of lexing, not a promised spelling. Spaced forms still work.

**`every <period>`** (v0.3, stamped 2026-08-25 — rill-casts.md note §5) is the metronome:
a wheel-driven occurrence **source**, the first operator that emits without being roused.
It takes no stream input, consumes fed time like the rest of this section, and is
unskippable (it is an occurrence-emitter). It fires at mount — leading edge, like
`sample` — then re-arms one period ahead of **each actual firing**: after a gap in fed
time it fires once and resumes, never bursting to "catch up", because a brazier fed by
`every 1f` should return to steady state after a pause rather than spike above it with
deposits the pause never earned. Replay feeds the same time sequence, so determinism is
untouched either way; this rule is the honest physics. A zero period is refused at the
node — a metronome with no interval is a storm wearing a duration.

### 3.13 Optional sugar (later, not v0)

Faust-style symmetric split/merge for the tidy cases only; names handle everything irregular:

```
noise <: lowpass 200, highpass 2000 :> mix
```

Pattern-match sugar compiling to `select` over a table:

```
match plane.player.state { idle: idleAnim, running: runAnim }
```

### 3.14 `also` — a side branch, inline (v0.2, ratified 2026-08-24)

```
use plane.defense as d

plane.gate.enemy_count | rose_above 0
  | also { inc d.sightings 1 }
  | notify d.alerts
```

(This exact program is parsed by a gate test — a spec example that does not
parse is the failure mode the demo's two silent days already taught us.)

**`also { … }` runs a side branch and passes the value along unchanged.** It is pure
parse-time desugaring to fan-out off an anonymous branch:

```
x | also { S } | rest        ⇒        x as ⟨anon⟩
                                      ⟨anon⟩ | S
                                      ⟨anon⟩ | rest
```

No new node kind, no evaluator change, no op-level "passthrough" class. The parser does not
even need the anonymous name: the in-flowing value is already a `Source`, so the branch and
the main wire are handed the same one — **identity on the stream holds by construction,
because the downstream edge *is* the upstream slot.** Occurrence semantics fall out free:
N rousings run the block N times, because it is ordinary fan-out and §4.1's rounds cannot
tell a side branch from a main one.

Rules, all parse-time:

- **A branch begins with an operator.** Its implicit source is the in-flowing value, bound
  to port 0 exactly as a pipe would. A head that names a value instead (a plane path, a
  `use` alias, a local stream, a literal, a record) is refused: nothing would wire the
  source into it, so it would parse, sit in the graph, and never once run.
- **No `as` escapes the block** — anonymous scope, the same enforcement shape as def's
  close-over-nothing. Bind the stream before the block instead.
- **The block's writes join the program's write list** at the ordinary bind site, so the
  cycle check (§4.4) and any future capability union see straight through it.
- **Multi-branch blocks are more branches off the same slot**, newline-separated.
- **A branch that ends still holding a value warns** — "also-block discards a value; end
  with a sink or drop the tail". Not fatal: every sink declares no outputs, so "ends with a
  sink" and "ends with no outputs" are the same sentence, and an effect that hands a value
  back has discarded nothing. This is rill's first non-fatal diagnostic (`Program.warnings`).
- **A tail operator (§3.11) takes the rest of the line, brace included** — so inside a
  one-line block it eats the block's own `}`, and says so with the fix named. Give it its
  own line.

`also` won the read-aloud test — "health drops below 20, **also** play the heartbeat,
trigger the warning" states both halves of the contract in one English word. It is a
reserved word, and the registry refuses to register an operator named with one, because
the parser recognises `also` before it ever asks `find`: a host row named `also` would
otherwise register cleanly and then be permanently unreachable.

**The block rule, generalised (v0.3, stamped 2026-08-25 — rill-casts.md note §5).** A
statement head followed by `{ … }` is the same fan-out with the head as every branch's
source — `also` was always "a name with a block whose implicit source is that name", and
the same desugar now applies to any source:

```
every 1f { S }        ⇒        every 1f as ⟨anon⟩
                               ⟨anon⟩ | S
```

Multi-statement blocks are more branches off the same slot; every `also` rule above
carries over unchanged (operator heads, no `as` escapes, writes join the write list, the
discard warning, the tail-eats-brace fix). The explicit pipe form `every 1f | cast …`
stays legal — the block is sugar, the pipe is the truth, exactly as with `also`. **Head
position only**: mid-chain side branches keep the `also` spelling, one spelling per
position, and the parser names the fix when a mid-chain `{` appears. Disambiguation from
record arguments is one token of lookahead — `{name:` opens a record, anything else is a
block, and no block branch can begin `name:` because a branch head is an operator.

And unlearn #6, for every reader (rill-casts.md §0): **a block is a fan-out, not a
body.** `every 1f { … }` is the most loop-shaped thing rill has, and statements in it are
branches — no order between them, each ends in a sink or produces a consumed value. If
you need sequence inside an `every`, you wanted a pipeline, and the pipeline is the
spelling.

---

## 4. Semantics

### 4.1 The tick

1. **Collect** plane deltas since last tick (host decides tick cadence; Matryoshka ties it to
   the frame). The tick call carries the fed time pair `{frame, time_ns}` (§4.6).
2. **Coalesce** VALUE deltas per path: at most one new value per subscribed path per tick. A
   node sees a consistent snapshot of all its value inputs as of the tick. **Occurrence deltas
   never coalesce** — they queue, in arrival order (§4.2).
3. **Mark** dirty bits on the slots subscribed to changed paths — and on nodes whose timer
   wheel deadlines the fed time has passed (§4.6).
4. **Evaluate** dirty nodes in topological order. An operator that emits marks its downstream
   slots dirty; one that doesn't emit lets the wave die there.
5. **Repeat 3–4 as a ROUND** while any path still has a queued occurrence: each round delivers
   one occurrence per path and sweeps once. Value deltas and wheel expiries are delivered in
   the first round only — they are the tick's state, not one of its rousings.
6. **Flush** `set` writes through the plane's write path, **once**, in evaluation order across
   every round: a tick's effects reach the world as one batch.

No node evaluates twice **in a round**. If health and stamina both move in one frame,
downstream of `playerStats` evaluates once with the new record. But three sightings on one
occurrence path in one frame rouse their node three times, which is the difference between
"an enemy arrived" and "three enemies arrived".

**All rounds share the tick's `{frame, time_ns}`.** One tick, one time, N rousings — a
cooldown that opened because round 3 "happened later" would be a wall clock smuggled in
through the back door (§4.6).

Rounds are bounded by what producers fed that frame. A plane mailbox bounds itself structurally
(keep-latest-N), and a runaway producer is the error/bus budget's problem (agents §6.3), not
the tick's.

### 4.2 Values vs occurrences (the one type bit that matters)

Every stream is either:

- **value** — a continuous quantity. Value slots **compare-and-suppress**: a write of the same
  bytes does not propagate (20→20 is silence; storms die naturally; idempotent by default).
- **occurrence** — a discrete event. Occurrences **always propagate**, same payload or not
  (a trigger pulled twice is two pulls). `where`, `changed`, `dropped_below` etc. emit
  occurrences.

A third kind is **accumulate** (v0.2, ratified 2026-08-24): `inc` writes a blind delta, and
the plane sums the deltas for a path within a tick and applies the sum once, silencing a
net-zero tick. A fourth, **membership** (`tag`), is **reserved, not built** — see
`ironwood.md` R6. The four coalescing rules:

| kind | coalesce rule | suppress? | idempotent? |
|---|---|---|---|
| set (value) | last-write-wins per tick | same-bytes | n/a |
| occurrence | append all, in order | never | no — twice is twice |
| accumulate (`inc`) | sum per tick, apply once | net-zero tick | no — twice is double |
| membership (`tag`, reserved) | union adds minus removes per tick | net-no-change | **yes — twice is once** |

**Idempotence is what separates membership from accumulate**: a soldier cannot be in the
shield wall one and a half times. It is reserved ahead of its implementation for the reason
the third kind was — widening this enum later is precisely the second refactor a reservation
prevents — and because every switch over it is exhaustive, so the compiler names each arm
that has to answer for a new kind. Both reserved kinds are *refused*, never quietly treated
as values: a wrong coalescing rule is the quiet kind of wrong the taxonomy exists to stop.

The taxonomy runs **both ways across the boundary**, which is the point: an inbound delta
carries a kind and so does an outbound write, because what a write *means* is what decides
how it coalesces. rill tags and does not sum — the write queue's promise is one batch in
evaluation order, and two `+1`s applied in order are the same `+2`.

This bit is not confined to wires inside a program: it crosses the plane boundary too. A plane
path declared an occurrence **mailbox** delivers every write to its subscribers — never
coalesced within a tick, never suppressed for identical bytes — while an ordinary value path
coalesces and suppresses. The plane ends up with the same two kinds as the ports, which is
the same rule stated at rest rather than a second mechanism.

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
to mount, the engine never spins. **Path-level analysis, connected or not**: a program that
both writes and subscribes to one path (exactly, or by segment prefix) is refused, even when
the writing branch never feeds the reading one — self-rousing through the plane is the
hazard, and the conservative check keeps the plane out of the reachability question. The fix
is always the split into two programs. Recorded, not built: a graph-level refinement that
refuses only when the write actually reaches the read, if a scene ever earns it. Deliberate
feedback later via an explicit one-tick-delay operator.

### 4.5 Determinism

- Topological order is stable (tie-break by node id, node ids assigned in parse order).
- Coalescing is per-tick and last-write-wins per path within the tick, in plane-delta order.
- Given the same mounted program and the same delta sequence, slot states are bit-identical
  every tick. This is a hard acceptance gate (see §8).

### 4.6 Time (v0.2, ratified 2026-08-23 — fed, ambient, wheel-delivered)

**Temporal operators consume time as data. They never read a wall clock.** The host feeds
`tick(now)` the pair `{frame, time_ns}`; tests feed a script; a transcript replays the
recorded values — so a replayed session's watchdog fires at the identical tick and G2
survives the fourth dimension.

Time is **ambient, not subscribable**. The tempting design — a `time.now` path fed like any
other delta — has a hidden storm in it: every temporal node would subscribe to time, time
changes every tick, so every temporal node goes dirty every tick, and the wave-dies-upstream
property is dead for exactly the operators that exist to create quiet. Instead, the **timer
wheel is the only subscription to time**: an operator arms an absolute deadline through its
eval ctx; the runtime marks the node dirty on the first tick whose fed time reaches it. A
thousand mounted watchdogs mid-window cost zero evaluations per tick. Operators tolerate a
stale wake (their real deadline moved since arming) by re-arming — the wheel stays a dumb
multiset and every op is self-healing across restore.

Rules, all load-bearing:

- **Monotonic by contract.** Fed time is non-decreasing on both lanes; a regression is a loud
  `error.TimeRegression`, never a clamp — a clamped regression would replay differently than
  it ran. Equal times on consecutive ticks are fine.
- **Absolute deadlines.** Temporal state stores absolute lane values and the wheel serializes
  them with the dump (G8 extends to cover both): a program restored mid-window stays exactly
  as far from its deadline as it was — `cooldown 30s` saved 12 s in is still 18 s from
  re-arming. Relative-remaining encoding would drift; absolute is the honest form.
- **Mount time matters.** `mount` takes the current fed time so tick 0 baselines windows at
  the mount moment, not zero — the one-shot console dispatch exercises this on every line.
- **Deadlines never re-enter the sweep.** An entry armed during a tick — even one already
  due — fires on the next tick at the soonest.

### 4.7 Budget behaviour (later, designed-for now)

The tick is Sponge-shaped: only touch what changed, in priority order. A future increment lets
the host hand rill a budget; expensive programs coarsen (skip ticks / batch coalescing windows)
under pressure like everything else in the engine. Nothing in v0 depends on this, but the tick
loop should not preclude it (keep per-node cost counters from day one — they're nearly free and
they feed both the budget hook and the debug view).

---

### 4.9 Broadcast, and the mismatch check (v0.3, tier 2 beat 1b, 2026-08-25)

**Arithmetic, comparison and boolean logic are elementwise over records and
arrays.** A scalar broadcasts to every element; containers combine positionally
by field or index; nesting recurses. `@player.pos | add {x: 0, y: 2, z: 0}` is
one line, `window 10s | mul 2` IS map, and `[1, -2, 3] | > 0` is
`[true, false, true]`.

Broadcast and its mismatch check land together, and the check **refuses rather
than guesses**:

- **record ⊗ record requires the same field set.** No implicit intersection: an
  intersection computes over the fields that happen to agree, which is a wrong
  answer wearing a right one's clothes.
- **array ⊗ array requires equal length**, and the refusal names both lengths.
  Grasshopper picks a matching rule implicitly (longest, shortest,
  cross-reference) and it is the most-complained-about behaviour in the tool.
- **A record and an array have no elementwise meaning.** Any pairing rule would
  be invented, so there isn't one.
- **A non-numeric leaf under arithmetic refuses, named by its path**
  (`mul: the left side is string, not a number at .inner.name`).

Every refusal names the operator, **both sides**, and where — in the type-word
vocabulary `number` · `boolean` · `string` · `record{x, y}` · `[number]`, which
has one renderer and is the vocabulary §2.13's shape literal reuses.

**`=` and `!=` do not broadcast.** `<` has no meaning on a whole record — there
is no total order on records — so elementwise is its only reading; `=` already
has an exact whole-value meaning and broadcasting would replace a good answer
with a different one. Ternary operators (`clamp`, `lerp`, `range`, `select`)
stay scalar: recorded, not built, awaiting a customer.

**Two consequences worth stating.** A `number` or `boolean` port accepts a
record or an array at wire time (§6's type rule), because otherwise the feature
is unsayable; and an elementwise operator declares its output type as `any`,
because its output KIND follows its input and no static id can say that. The
eval-time check is the authority on kinds in both directions.

### 4.8 Op-internal state and self-arming (v0.3, tier 2 beat 1a, 2026-08-25)

**State inside an operator is legal, and it is the sanctioned mechanism.** §4.4's cycle check
is a cross product over two lists of *plane paths* — the program's write list and its
subscription list — and there is no third list, so an operator's own state cannot close a
cycle by construction. This was already true of `window`, `debounce`, the gates and the
threshold adapters; the register family (`ease`, `ramp`, `hold`, `diff`, `integrate`) is the
next set of customers, not a new capability. A rill still may not chase a target *through the
plane*; it chases it *inside the operator*.

Three rules keep that from becoming the cycle ban wearing a hat:

- **Every self-arming operator stops.** `ease` stops inside ε of its target *without snapping
  to it* (an exponential never arrives, and a snap would put a visible step on the last
  frame); `ramp` stops at its end, emitting the target **exactly**; `diff` stops when the rate
  reaches zero; `integrate` stops at its clamp. ε is a per-op default, relative above 1 and
  absolute below (1e-4), never a user knob. Every one is gated on the node's eval counter going
  **flat** — an ε nothing watches is decoration.
- **Unbounded state is refused, not discouraged.** Op state is serialized with the program, so
  an unbounded accumulator is a corpse that gets *copied*. `integrate`'s clamp is a required
  keyword port for that reason, and the bound doubles as the cutoff.
- **The re-arm is `now + 1` on the operator's own lane** — the lane its duration named, as
  `every` already picks it. No new primitive: a tick where that lane did not advance simply
  does not fire the entry, so a missed wake is free and self-healing.

**Epochs are per-program and live in op state.** `clock` and `frame` count from *mount*, which
keeps them program-relative (two cells started a second apart do not share a phase) and
replay-clean. The epoch is baselined on the operator's first eval — which is tick 0, since
mount evaluates every node — and rides the dump, because `restore` rebuilds without ticking
and takes its `now` from the caller: an epoch held on the runtime would re-seed and `clock`
would report zero on a program restored at t=90s.

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
| flow | `select`, `lerp`, `and`/`or`/`not`, `where`, `partition`, `changed`, `latch` |
| events | `dropped_below`, `rose_above`, `edge` (value→occurrence adapters; each strict on its own comparison — see below) |
| temporal | `sample`, `debounce`, `throttle`, `cooldown`, `window`, `stats`, `delay`, `every`, `arm`, `disarm` (§4.6; durations §3.12) |
| movement | `clock`, `frame` (fed time as a value, since mount), `lfo`, `wave` (0..1 waveforms) — tier 2 beat 1a, §4.8 |
| registers | `ease`, `ramp`, `hold`, `diff`, `integrate` (op-internal state chasing a target; §4.8) |
| shaping | `range` (0..1 → interval, clamping), `shape` (0..1 → 0..1 easing curves) |
| math | `add sub mul div min max clamp abs floor round ceil`, `sin cos tan atan2 sqrt pow exp log mod sign fract`, `pi`/`tau`, comparators — all elementwise (§4.9) |
| record | record construction `{…}`, projection `.field`, `merge` |
| array | array construction `[…]` (§3.6a), `nth <i>` (0-based), `choose <i> <array>` (`nth` with the index piped) — tier 2 beat 2a |
| plane | `set <path>`, `notify <path>`, `inc <path> <by>` (sinks), path read (implicit source) |
| field | `cast <$chan> [value] radius <r> at <pos> [decay <d>]` (sink — the fourth write, into the caster's owned space; rill-casts.md) |
| util | `const`, `tap` (debug passthrough → log bus) |

**Operator class (audited 2026-08-24).** Every core op declares `pure` / `reads` / `effect`,
and the load-bearing meaning of `reads` is **"not a writer, not skippable"** — `pure` is a
*cache licence*, so it belongs only to ops whose output depends on the input values alone.
The audit found three unskippable shapes besides host-world-readers: **arrival-dependent**
(`where`, `partition`, `changed`, `latch` ask `in_fresh`, so identical bytes mean emit-or-be-
silent), **stateful** (the threshold/edge adapters and the gates), and **fed time** (`sample`,
`debounce`, `throttle`, `cooldown`, `window`, `delay`, `every` — ambient by §4.6, never an input).
Plus `tap`, whose entire purpose is the side effect and which was the `pure` that gave the
audit away: a skipped tap is a debug instrument that lies. The classification is pinned by an
exhaustive gate test, so a new op cannot inherit `pure` from the field default unnoticed.

**Operator ticking (added 2026-08-25, tier 2).** Every core op also declares `ticks`: may it
re-arm itself and evaluate again with *no input change*? `clock`, `frame` and `lfo` do for as
long as time is fed; `ease`, `ramp`, `diff` and `integrate` do while converging; `hold`,
`every` and everything pure do not (`every` re-arms on its *period*, which is not per-frame
cost). It is defaulted `false` and audited exhaustively both ways rather than
comptime-required like `routes`, because a wrong answer here shows a wrong badge rather than
computing a wrong value. The flag says **may tick**, never **is ticking**: the host lights the
ticks-every-frame badge from it and shows the node's live eval counter beside it as the proof.
A structural gate also refuses `ticks` on a `pure` op — an operator that produces a new answer
from no new input is exactly what `pure` says it cannot do.

**Threshold boundaries (corrected 2026-08-24).** `dropped_below t` fires crossing from ≥t to
<t; `rose_above t` fires crossing from ≤t to >t. Each is strict on the comparison it names,
so the two mirror and neither fires on merely *arriving* at the threshold. They previously
shared one `v < t` test, which made `rose_above t` mean "reached t" — `rose_above 0` on an
enemy count fired when the count fell back to 0, when the last attacker LEFT, and never once
when one arrived. The first observation still baselines silently, on either side.

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
