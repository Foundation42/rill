# rill agents & time — temporal operators, clock boundaries, capabilities, failure

**Status:** Design spec v0.1 · 2026-08-23 · companion to `rill-spec.md` (the language)
and `matryoshka/docs/rill-adoption.md` (the engine reshape).
**Scope:** everything a mounted rill needs to talk to consumers on *other clocks* —
AI agents, web clients, remote peers, slow devices — plus the guard rails
(capabilities, failure semantics, provenance) that must exist before the first
agent mounts its first rill.

Reading order for a fresh session: rill-spec §4 (tick semantics, value/occurrence)
first; this doc builds directly on that split and adds nothing that contradicts it.

---

## 1. The problem, stated once

Different consumers run at different clocks with different cost/spend budgets.
The frame loop ticks at 80–120 Hz; a perf-watchdog agent wants to think every
five seconds *or when something odd happens*; a web client wants ~30 Hz; a
remote peer wants whatever the wire allows. None of them should see the
firehose, and an expensive consumer must not be re-triggered while it is
already acting.

**The ruling: the boundary between two clocks is itself a rill.** You never
schedule the slow thing; you mount a cheap sentinel at frame rate whose job is
to decide when the slow thing hears anything at all. What crosses the boundary
is a single occurrence carrying a digest, landed in a mailbox on the plane.
The plane is the buffer between clocks — it already was (the 30 Hz histogram
stream), this names the pattern.

Canonical sentinel:

```
use plane.perf as p
p.gpu.traversal_ms | window 10s | stats as t
t.max | rose_above 6.0 | cooldown 30s
      | notify agent.perfwatch { stats: t, scene: plane.scene.name }
```

Watch cheap, wake rarely, and (§6) reconstruct perfectly.

---

## 2. Temporal operators — the missing quarter of the core set

All are ordinary operators (valves, per spec §4.3). Each declares its ports'
value/occurrence kinds like any other op.

| op | in → out | semantics |
|---|---|---|
| `sample <dur>` | value → value | emit at most once per period (data-driven cron) |
| `debounce <dur>` | occ → occ | pass only after a quiet period; storms collapse to their last edge |
| `throttle <dur>` | occ → occ | first passes, rest eaten for the window |
| `window <dur>` | value → value | rolling buffer; feeds `stats` |
| `stats` | value(window) → value | record {mean, min, max, stddev, n} |
| `cooldown <dur>` | occ → occ | pass one, then deaf for the window ("triggered, now get out of the way") |
| `arm` / `disarm` | occ + control → occ | explicit latch gate — a mitigation can re-arm its own watchdog on unmount |
| `delay <dur>` | occ → occ | emit N later (implemented via the same timer wheel) |

### 2.1 The determinism constraint (normative)

**Temporal operators consume time as data. They never read a wall clock.**
Tick timestamps ride in with the delta feed (and are logged in the transcript
like every other input); `window`/`debounce`/`cooldown` compute against the
fed time. Consequences, all load-bearing:

- G2 survives: a replayed session's watchdog fires at the identical tick.
- Temporal state is slot state: it serializes with the program (G8 extends to
  cover it), and a mounted watchdog survives save/load mid-window.
- The engine feeds time; the mock plane feeds *scripted* time — temporal
  operator tests are table-driven with fake clocks, no sleeps anywhere in the
  suite.

Implementation note: one timer wheel per runtime keyed on fed time; `sample`
and window expiry are wheel entries, not per-tick scans.

### 2.2 Durations in the grammar

`5s`, `250ms`, `2m` as duration literals (a distinct struple-typed literal,
not a bare number — `sample 5` is a wire-time type error). Frame-count
durations (`3f`) permitted for engine-side rills where frames are the honest
unit.

---

## 3. Mailboxes — crossing the boundary

`notify <mailbox-path> <record>` is sugar for a `set` to a mailbox path with
occurrence semantics. Mailboxes are plane state with a declared policy:

- **Value paths need no mailbox.** A slow consumer reading a value path gets
  the current coalesced state — late, never wrong. This falls out of spec
  §4.2 and costs nothing.
- **Occurrence mailboxes are bounded, keep-latest-N, with a visible drop
  count.** A consumer busy for a minute returns to "3 anomalies, here's the
  worst, 12 dropped" — not a 4,000-event replay, not silence. The drop count
  is itself a watchable value path; lossy is acceptable *because it is
  visible*.
- Consumer acknowledgement is a write (clear/advance a cursor path), so the
  mailbox is inspectable end-to-end from the console like everything else.

**Policy correspondence (binding, see §8):** this is 6564 Q6's ruling
restated at the language level. Load-bearing records that exist nowhere else
must never silently vanish; re-derivable notifications drop-and-count.
Occurrence mailboxes are the drop-and-count half; anything load-bearing
belongs in the transcript, which never drops (§6).

---

## 4. Capabilities — bind at mount, to the program, as data

A capability grant is a struple:

```
{ read:  ["plane.perf.*", "plane.scene.name"],
  write: ["plane.render.grade.*", "agent.*"],
  ops:   ["core", "temporal"],           // op groups or explicit names
  budget: { nodes: 64, subs: 32, writes_per_tick: 16 } }
```

Rules:

- The grant attaches to the **mount**, not the source or session. It lives on
  the plane (auditable, watchable, versioned like everything else).
- **Checking is static, at mount.** The flattened graph exposes every path
  and every operator; a program exceeding its grant refuses to mount with the
  violation named — exactly like the cycle error. No per-tick enforcement
  cost, no runtime surprise.
- A def's capability cost is the union of what its body touches, computed at
  flatten. `rill inspect <op>` shows what granting it costs *before* anything
  mounts. Capabilities compose bottom-up through the graph — that is the
  whole model.
- The Substrate capability-view machinery is the enforcement twin: the
  agent's plane *is* a view scoped to its grant. Per the checked-twice
  principle (§8): the mount check moves the reject earlier; the view is the
  runtime twin; neither alone is the design.

Budget notes: `nodes`/`subs` are static counts; `writes_per_tick` is the one
dynamic ceiling (cheap counter, per program, breach = error occurrence per
§6, not silent clamp).

---

## 5. Identity, provenance, discoverability

### 5.1 Naming (decide now, impossible later)

Mount names are namespaced, and the namespace is **derived from the
capability grant**, never chosen: `user/hud`, `agent/perfwatch-1`,
`pack/org.foundation42.horns/duck-bubbles`, `system/…`. A program cannot
masquerade; `rill list agent/*` is the audit view.

**Two identity questions, kept orthogonal (ruling, 2026-08-23).** The trust
prefix answers *"what may this program do here?"* — trust class, derived
from the grant, local to this engine, unforgeable by construction, and a
closed set so the audit grammar stays one glob. Reverse-DNS-style identity
(`org.foundation42.horns`) answers *"who in the world made this, and how do
names avoid colliding globally?"* — authorship and distribution identity,
which lives in the **pack name and provenance record** (§5.2), backed by the
licence/provenance machinery rather than the honour system. One string must
never answer both: a typeable prefix as a trust signal is forgeable
(anyone can write `org.foundation42.`), and a world-identity as a trust
class needs policing. Java itself is the precedent — package names never
became a security mechanism there either; when identity had to be
load-bearing they added jar signing, because the name never was. So a
pack-shipped rill reads trust-class first, world-identity second, program
name last: `pack/<reverse-dns-pack-id>/<name>`.

### 5.2 Provenance (one struple field, day one)

Every mount records `{source, author, created_at_revision, derived_from}` —
same idea as `imported-from: project@vid`, applied to programs. "Which of
these did the agent write" must be answerable from `rill list` without
archaeology.

`author` and pack identity use the reverse-DNS form
(`org.foundation42.horns`) — this is where the world-scale naming instinct
lands. It rides the pack record and the provenance stamp, so it is asserted
by the machinery that already tracks licence and origin, not by whoever
typed the mount command.

### 5.3 The agent-grade query surface

Three verbs complete the "how do I do X here" loop with zero out-of-band
docs:

- `rill ops [filter]` — registry listing, filterable by port type
  ("what accepts a mesh").
- `rill schema <path-pattern>` — what lives at `plane.perf.*`: types, doc
  strings (from KnobDef), read/write class.
- `rill examples <op>` — example programs **exported from the gate-test
  corpus**. Docs executed in CI don't lie; there is no second example source.

The general principle (why agents find rill easy, worth stating in the doc
because it is the design's contract, not an accident): every capability is
**enumerable** (typed registry), every effect is **observable** (slots +
deltas), every action is **reversible** (writes ride the log/undo). An agent
verifies its own work by reading back the wires it created.

---

## 6. Failure semantics (normative — needed before Phase C retypes handlers)

What happens when a mounted rill's operator errors at tick 47 (`div` meets a
live zero):

1. **The wave dies at the failing node.** An error is a valve that jams shut
   — consistent with §4.3. Sibling branches and other programs are untouched;
   the tick completes.
2. **An error occurrence lands on `programs.<name>.errors`** carrying
   `{node, port, tick, error, input_digest}`. Errors are watchable streams
   like everything else — a sentinel rill watching `programs.*/errors` is the
   system supervising its own machines.
3. **A knob-settable per-program error budget** (count per window, using §2
   machinery) unmounts the program loudly when exceeded — unmount lands on
   the log bus with the tally. Budget exhausted = watchdog trip; the remedy
   is remount (restart, not resume).
4. Handler contract for Phase C: a retyped handler that fails returns an
   error; the runtime does 1–3. Handlers never half-apply — validate, then
   mutate (the loadProject decode-then-swap discipline, per handler).

Explicitly rejected: silent skip (invisible failure), and tick-aborting
(one bad program must not stall the frame's dataflow).

---

## 7. Format versioning (one integer now, a compat layer later)

- `.rill` source files: `#! rill 1` header line (comment-shaped, mandatory,
  parser-enforced).
- Serialized dumps: version integer as the first element of the struple.
- OpDefs are ABI: a pack shipping defs records the registry surface
  (op name + port shapes) it was compiled against; mount refuses on mismatch
  with the diff named. Port changes to shipped operators are additions-only
  (new optional ports), never mutations.
- **Qualified operator identity (noted, not designed):** when two packs both
  ship a `rivet`, the registry needs world-qualified operator names —
  `org.foundation42.mesh/rivet` — with short names resolved per-program via
  a `use`-style import at the top of the `.rill` file. Same orthogonality as
  §5.1: qualification is identity, never trust. Designed when the second
  `rivet` exists.

---

## 8. What this earns — use cases and applications

The mechanisms above are scattered through the doc by necessity; this
section collects what they buy, so the keep is visible in one place. Each
entry names the machinery it stands on.

**Game rules as mounted programs.** `plane.player.health | dropped_below 1
| trigger respawn` — triggers, HUD logic, door conditions, music ducking:
the behaviour layer of the before-Christmas goal, with no scripting VM. Every
rule is auditable text, undoable (the mount is the undoable act), carried in
the Project pack, replayed deterministically. *(spec core + adoption D4/
Surface-gate serialization.)*

**The perf watchdog.** §1's canonical sentinel: watch cheap at frame rate,
wake an agent rarely with a digest, `cooldown` while the mitigation settles,
re-`arm` on unmount. *(temporal ops + mailboxes + failure semantics.)*

**Agents that leave behavioural residue.** "Watch my health and duck the
music when I'm in danger" is not a task an agent performs — it is a rill the
agent writes, mounts, and walks away from. The agent's output is standing
behaviour: inspectable in the graph view, editable afterwards, shippable in
a pack. Because defs are archetypes, an agent's good ideas accrete into the
operator vocabulary. The agent verifies its own work by reading back the
wires it created — enumerable registry, observable slots, reversible writes.
*(§5.3's contract + capabilities.)*

**The proposal loop.** An agent watching the perf plane *proposes* a
mitigation rill — "traversal spikes in this corridor; here's a rill that
pre-drops resolution at the doorway; mount it?" Proposal is text, text is
auditable, mount is logged, undo is one command: self-improving
infrastructure with the human verdict function at the only gate that
matters. *(§9 — no machinery beyond this doc.)*

**The flight recorder.** The digest says *when*; the transcript says
*everything else* — the agent replays or reads the log around that revision
and reconstructs exactly what the store did leading in, deterministically.
Since mount events carry program source, a `.log` is self-contained years
later. No other engine offers "the watcher didn't have to be listening."
*(G2/AE=0 discipline + adoption Phase B.)*

**Per-volume budget authoring.** The budget controller's targets are plane
paths; a rill can retarget them by grade volume — "in this corridor spend on
resolution, in the plaza spend on framerate" — making the endorsed authoring
idea a three-line program instead of an engine feature. *(spec core +
budget controller knobs.)*

**Behaviour fields for particles.** When LEAF_PARTICLES lands, emitter
behaviour ("attract to the duck when close, else drift") is a rill sampling
fields and writing population parameters — the particles-as-data design
gets its programmable layer without a particle-specific VM. *(spec core;
Tidal-style time patterns deferred in §9 land here.)*

**Every slow consumer, one pattern.** Web clients at 30 Hz, remote peers,
future sound-engine consumers, a joe actor on the fabric: sentinel on the
fast side, mailbox on the plane, digest across. The histogram stream was
this pattern before it had a name. *(§1–3.)*

**The system supervising itself.** A sentinel watching `programs.*/errors`
is a supervision tree over the mounted machines; the watchdog pattern
applies to the watchdogs. *(§6 + temporal ops.)*

---

## 9. Correspondence — rill ↔ joe/6564 (transcription, not coincidence)

The failure/time/capability semantics above are not a fresh design space.
They transcribe rulings already measured in the 6564/joe programme. CC should
treat divergence from this table as a smell to raise, not a freedom:

| rill (this doc) | 6564/joe (spec v2.5/v2.6 + amendments) |
|---|---|
| error budget unmounts a program | watchdog burst budget; trip = restart, not resume |
| `programs.<n>.errors` watchable | exit links — supervision as subscription |
| sentinel watching `programs.*/errors` | supervision tree |
| mailbox keep-latest-N + visible drop count | Q6: re-derivable verdicts drop-and-count |
| transcript never drops | Q6: load-bearing records fault rather than vanish |
| `cooldown` / `arm` | AUTO_REARM |
| time as fed data, never wall clock | §6.3 fabric-as-clock (timer = message; replayable) |
| static capability check at mount + view as runtime twin | RBC + §2.3 checked-twice ("a compiler never extends trust, it only moves a reject earlier in time"; a static check with no runtime twin is a smell) |
| grant attaches to mount, namespace derived from grant | PTT rights live in the capability, not the claimant |
| per-tick slot state; cross-boundary state must be declared (`latch`, `window`) | `let` dies at any park; surviving state is declared |

One sentence for the record: **a mounted rill is an actor whose behaviour is
a dataflow graph instead of a serve ladder** — joe and rill are two source
dialects over one semantics (sequential-with-parks vs propagation), agreeing
on failure, time, capability, and replay. The physical meeting point already
exists: the substrate/store actor is a §7 peripheral with radix as polyfill,
and the plane is radix — a rill's mailbox path and a struple key in the store
device are the same object. A slow-clock consumer behind `notify` can be a
browser agent today and a joe actor on the fabric later, sentinel none the
wiser (§7.5: silicon is an optimization, never an interface).

## 10. Deferred, with reasons

- **Distributed rill** (sentinels here, mailboxes there, 6564/AgentStream
  shape): the seam is already right — everything crosses as plane writes,
  which replicate. Nothing in rill core assumes locality. One paragraph, door
  open, no design today.
- **rill-on-6564** (slots in near page, deltas as TXR, tick as burst):
  noted as an existence proof that the semantics are host-independent.
  For later — it has, of course, already crossed the right mind.
- **Agent proposal loop** (agent watches perf, *proposes* a mitigation rill,
  human mounts): no machinery needed beyond this doc — proposal is text,
  text is auditable, mount is logged, undo is one command. The human verdict
  function sits at the only gate that matters. Record as the intended
  workflow, build nothing.
- **Wall-clock bridge** for genuinely calendar-shaped triggers ("at 9am"):
  a host-fed time path (`plane.clock.*`) written by the engine like any other
  sensor — time enters as data through the front door, determinism intact.
  Add when something wants it.

## 11. Ratified (Chris, 2026-08-23)

All five open items signed off as proposed; recorded here so CC treats them
as rulings, not suggestions:

1. **Duration grammar:** `5s` / `250ms` / `3f` literals as specified;
   frame-count durations permitted engine-side.
2. **Mailboxes:** keep-latest-8 default; "read-and-clear" suffices for v1,
   ack-cursors when a consumer needs them.
3. **Capability op groups:** group taxonomy = registry family names, with
   explicit per-op names always available.
4. **Error budget default:** 8 errors / 10s window, knob-settable per
   program.
5. **Namespace set:** `user/ agent/ pack/ system/` — closed until a real
   fifth class arrives.
