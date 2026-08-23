# rill

**A small, live, reactive dataflow evaluator.** A rill program is a flat graph
of typed operators connected by streams of [struple](../struple) values.
Programs are **mounted, not run** — they sit on the host's data plane,
subscribe to paths, and re-evaluate incrementally when inputs change. There is
no run button and no execution wires: propagation is the only control flow,
and operators are the valves that decide whether a change continues
downstream.

```
use plane.player as p

# player vitals, live as one record
p.{health, stamina} as stats

# healthbar: clamp, normalise, write back
stats.health | clamp 0 100 | div 100 | set plane.ui.healthbar

# heartbeat: an occurrence when health crosses below 20
p.health | dropped_below 20 | play heartbeat
```

The pipe is the 90% case and is exactly the console you already have. Names
appear only at the joints (`as` for fan-out, a bare name for fan-in). Any
`plane.…` path in any argument position is a live subscription — there is no
special subscribe form. There is no `if` statement and no exec pins, ever:
selection is `select`/`lerp` over live branches, gating is `where`/`partition`
over occurrence streams.

Design spec: [docs/rill-spec.md](docs/rill-spec.md) ·
Implementation notes: [docs/implementation-notes.md](docs/implementation-notes.md)

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

`zig build test` (acceptance gates G1–G9) · `zig build run` (mounts a HUD
rill on the mock plane and narrates four ticks) · Zig 0.14.1, sibling of
`struple` / `radix` / `matryoshka`.

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
