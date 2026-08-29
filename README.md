# rill

**A small, live, reactive dataflow evaluator.** A rill program is a flat graph
of typed operators connected by streams of [struple](../struple) values.
Programs are **mounted, not run** — they sit on the host's data plane,
subscribe to paths, and re-evaluate incrementally when inputs change. There is
no run button and no execution wires: propagation is the only control flow,
and operators are the valves that decide whether a change continues
downstream.

```rill
// a healthbar, live: clamp, normalise, write back
plane.player.health | clamp 0 100 | div 100 | write plane.ui.healthbar

// a heartbeat when health crosses below 20 — an occurrence, not a state
plane.player.health | dropped_below 20 | notify plane.audio.heartbeat
```

The pipe is the 90% case and is exactly the console you already have. Names
appear only at the joints (`as` for fan-out, a bare name for fan-in). Any
`plane.…` path in any argument position is a live subscription — there is no
special subscribe form. There is no `if` statement and no exec pins, ever:
selection is `select`/`lerp` over live branches, gating is `where`/`partition`
over occurrence streams.

## What it looks like in anger

rill is load-bearing in [Matryoshka](../matryoshka), a compute-only software
ray tracer. The engine's **camera controller is a rill program**, mounted at
startup — 46 `glfwGetKey` calls left the frame loop when it arrived, and what
a key *means* stopped being a fact about the engine:

```rill
plane.input.kbd.shift | mul 2 | add 1 as boost
plane.input.kbd.w | sub plane.input.kbd.s | mul boost | write plane.camera.thrust.fwd
plane.input.mouse.rmb | mul plane.camera.sens as look
plane.input.mouse.dx | mul look | write plane.camera.torque.yaw
```

A muzzle flash is one statement. It rides the exposure knob's **modulation
lane**, so the colourist's slider is untouched and comes back — two writers on
one lane sum rather than race:

```rill
plane.input.mouse.lmb | rose_above 0.5 | kick 15ms 150ms | mul 2 | write plane.mod.render.grade.exposure
```

And a camera that tows itself back onto a spline is seven lines. `along` walks
a Catmull-Rom curve; `nearest` is its inverse, handing back the parameter so
`| diff` can tell you which way round you are going; `dot` splits a
world-space error into the camera's own axes:

```rill
[{x: 0, y: 6, z: 0}, {x: 40, y: 6, z: -30}, {x: 80, y: 14, z: 0}] as track
plane.camera.pos | nearest track as t
t | along track as target
target | sub plane.camera.pos as err
err | dot plane.camera.fwd | mul 0.06 | clamp -1 1 | write plane.camera.thrust.fwd
```

Every block above is parsed by the test suite. So is every ```rill block in
both manuals and every cell in the idioms book — a manual that drifts from the
registry fails the build.

## The documents

| | |
|---|---|
| [docs/rill-manual.md](docs/rill-manual.md) | the human manual. §6a *thinking in rill*, §12 the operator index — every operator, gated against the registry both ways |
| [docs/rill-for-agents.md](docs/rill-for-agents.md) | the same language for someone who reads faster than they explore |
| [docs/idioms.rillbook](docs/idioms.rillbook) | 60 idioms as runnable cells, each with the *before* it replaces |
| [docs/implementation-notes.md](docs/implementation-notes.md) | the ledger: every durable ruling, what bought it, and what it cost |
| [docs/rill-spec.md](docs/rill-spec.md) | the design spec |

## Quick start

```zig
const rill = @import("rill");

var reg = try rill.Registry.init(gpa);
defer reg.deinit();
try rill.registerCore(&reg);
// the host injects its own operators through the same reg.register(…)

var diag = rill.Diag{};
var prog = try rill.parse(gpa, &reg, "hud", source, &diag);
defer prog.deinit();

var rt = try rill.Runtime.mount(gpa, &prog, plane); // live from this moment
defer rt.deinit();

// per frame:
try rt.feed(.{ .path = "plane.player.health", .value = encoded });
try rt.tick();
```

The plane is borrowed, never owned: a four-pointer interface
(`subscribe`/`unsubscribe`/`read`/`write`). Matryoshka hands rill its real
data plane over the main-thread drain; the test suite hands it `MockPlane` —
no engine required.

## The load-bearing choices

- **Everything is a struple.** Slot values, the program dump, the wire
  protocol. struple's canonical encoding is what makes compare-and-suppress a
  `memcmp` and determinism a byte-equality test.
- **Values vs occurrences** — the one type bit that matters. Value streams
  suppress same-bytes writes (20→20 is silence; storms die naturally);
  occurrence streams always propagate (a trigger pulled twice is two pulls).
- **Parse order is topological order.** Names are single-assignment and
  defined before use, so the evaluator walks node ids ascending — no sort, no
  node evaluates twice, every node sees a consistent snapshot per tick.
- **defs are archetypes**, flattened at parse with an instance-name prefix.
  Internal knob paths (`programs.hud.rivet1.bevel1.in.r`) are addressable and
  overridable from outside, and the override survives serialize → mount.
- **Deterministic.** Same delta sequence in ⇒ bit-identical slot states out,
  every tick, across Debug and ReleaseFast — gated by a frozen-reference
  hash in the test suite.
- **Every wire is watchable.** Slots have stable paths; the wire-lighting
  debug view is a subscription to the program's own struples, not a feature.

## Build

`zig build test` — 347 gates · `zig build run` (mounts a HUD rill on the mock
plane and narrates four ticks) · `zig build run-file -- prog.rill` (mounts a
file, ticks it, and says "(nothing)" out loud if it writes nothing) · Zig
0.14.1, sibling of `struple` / `radix` / `matryoshka`.

## License

Dual-licensed:

- **[Apache 2.0](LICENSE-APACHE)** — open-source default. Permissive,
  patent grant included. The right pick for almost everyone.
- **[Commercial](LICENSE-COMMERCIAL.md)** — for organizations that want
  indemnification, SLA / support, no-attribution embedding, or custom
  terms. Contact [chris@foundation42.org](mailto:chris@foundation42.org).

Both licenses cover the same code — no "open core" split. See
[LICENSE](LICENSE) for the overview. Contributions are accepted under
the [CLA](CLA.md).
