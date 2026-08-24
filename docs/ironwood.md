# The Watch at Ironwood Keep — rill's driver scenario

**Status:** Driver doc v0.1 · 2026-08-24 · Chris's scenario, jointly analysed.
**Role:** rill's rocci-bird — a small complete scenario whose idioms force the
missing mechanisms into the open, then stays as the gated end-to-end test the
whole stack must keep passing. Companions: `rill-spec.md`, `rill-agents.md`,
the garrison gate (its eight-line ancestor), and `rill-adoption.md`.

The scenario text (standing orders + the raid narrative) is §1 verbatim; the
analysis maps it onto shipped machinery (§2), extracts the five requirements
it drives (§3, each with its acceptance gate), pins the test harness shape
(§4), and leaves one ruling open (§5).

---

## 1. The scenario (Chris, 2026-08-24, verbatim)

Ironwood Keep is a vital medieval border fort guarding a narrow mountain
pass. A sudden dusk raid by enemy raiders triggers the castle's defense
system, testing the garrison's readiness.

```
      [ THE KEEP ] (Garrison / Commander)
           ^
           | (Horn Signals / Beacons)
           v
   [ THE LOOKOUT TOWER ] ======> [ THE MAIN GATE ]
     (Sentries / Scouts)         (Gate Guards / Archers)
```

**The Watchers (Sentries & Lookouts)** — high watchtower and wall walks.
Maintain a constant scan of the tree line and pass. At the first sight of
moving steel or dust clouds, sound the alarm horn (two long blasts for an
approach, three short for an immediate threat). If at night, ignite the iron
beacon braziers immediately. Do not leave the post to fight; your eyes are
the keep's greatest weapon.

**The Gate Guard & Wall Archers** — barbican, portcullis winch room,
battlements. At the sound of the alarm, drop the portcullis and raise the
drawbridge. Hold the gatehouse at all costs; do not open it for anyone once
the alarm sounds. Loose arrows at the enemy vanguard to slow their advance.

**The Garrison (The Reaction Force)** — courtyard barracks and Great Hall.
Sleep in light gambesons with weapons within arm's reach. Upon hearing the
horn, assemble in the central courtyard within two minutes. Form a shield
wall facing the gatehouse. Await the Commander's order to open the sally
port for a surprise counter-attack.

**The raid:** dusk; Sentry Tom sees birds scatter from the forest a mile
out, then the glint of dying sunlight on chainmail. Two long blasts. The
garrison assembles — thirty men in ninety seconds. The gate guards crank the
winch; the drawbridge groans up just as the first horsemen clear the trees.
Wall arrows pin the lead rider. The attack stalls at the ditch; raiders
bunch in confusion. The Commander: "To the sally port!" The garrison slips
out the hidden door in silence and hits the exposed flank. By nightfall the
threat is broken and the keep stands.

---

## 2. What runs today (the shipped machinery, nearly verbatim)

| standing order | mechanism (shipped) |
|---|---|
| first sighting → horn | the canonical sentinel: `visible_enemies \| rose_above 0 \| notify signals/horn {kind, from}` |
| night → beacons | `select` on `plane.world.time_of_day` — the same time concept grade volumes already blend on |
| "do not open once the alarm sounds" | the latch — and **capabilities load-bearing in fiction**: the gate rill's mount grant simply lacks the open-gate write after arming; the standing order is enforced by the grant, not by trust |
| soldiers assemble, wall forms at 30 | `inc keep/assembled 1` per soldier; `rose_above 29 \| notify signals/wall_formed` — `inc`'s first genuine customer |
| two-minute deadline vs ninety-second reality | `signals/horn \| delay 2m \| …` fires the deadline; the gate reads the assembled count when it lands — temporal quarter, fed time, replayable |
| commander's sally-port order | the agent mailbox: an occurrence arriving from *outside* the mounted rills (player keypress or a Claude) — the clock-boundary pattern from rill-agents §1 |
| sightings never lost, tally visible | occurrence mailboxes (append-all, keep-latest-N, drop count), the never-suppress ruling — proven by the garrison gate this scenario grows from |
| "count it and pass it on" idioms throughout | `also { … }` blocks (next session's parser work; this scenario is its consumer) |

Every row above is exercised end-to-end by the final gate (§4), which is the
point: the scenario is not a demo of the machinery, it is the machinery's
standing regression.

## 3. What it drives — five requirements

Ordered by dependency; each carries its pre-registered gate.

### R1 — Perception publishes to the plane (the big one)

"Constant scan of the tree line" cannot be a rill doing spatial math over N
entities per tick. It is an **engine sensor**: the engine computes, publishes
digests, rills react — the same shape as the perf counters. The plane grows a
sensors row:

```
sensors/<post>/visible_enemies     (count, value path)
sensors/<post>/nearest_distance    (value path)
sensors/<post>/sighting            (occurrence mailbox: {n, bearing, confidence})
```

The birds-scatter detail suggests tiered signals worth keeping: cheap
indirect evidence at range (`confidence: low` from disturbance heuristics),
confirmed sighting close in. Sensor *placement and range* are authored like
lights — archetype/instance with gizmos — so a watch post is a scene object,
not engine code.

**Gate R1:** a scripted raider crossing a sensor's range flips
`visible_enemies` 0→n within one frame of the crossing tick, emits exactly
one sighting occurrence per new contact (not per frame), and a raider outside
all ranges is invisible on every sensor path. Deterministic under replay.

#### R1 rulings (2026-08-24, Chris + CC + CC-chat, after the engine audit)

**The engine already had the sensor.** `solver.zig` — the Online Transport
Solver — names its intended tenants in its own header as "emissive NEE, audio
propagation, **AI perception**, and tight visibility through a single API",
`Metric.euclidean` is documented "Used by NEE **+ AI LoS**", and
`Solver.shadowBlocked(a, b)` was already written, CPU-side and deterministic.
R1's narrow phase was one dispatch arm, not a subsystem. The fourth unlocked
door.

**① Sensors report geometry; rills form beliefs.** The engine answers "what is
geometrically visible from this cone, now" and stops. Memory, suspicion decay
and threat assessment are the sentry rill's job, built from `sighting`/`lost`
plus latch/cooldown/window. The line is not philosophical — it is about *what
can be replayed*: a sensor's output is a pure function of world state at a
tick, a belief is a function of history, and rills already serialise and replay
bit-identically. Keeping the engine dumb and the rills smart is what makes
sensors reusable across every game rather than casting one game's AI into
silicon.

**② The instrument may have a time constant; the observer has a memory.** The
one apparent exception to ①. A raider crossing behind a merlon, judged by a
bare geometric boolean, reads seen/lost/seen/lost at the cadence rate — a
sighting storm that floods the mailbox in under a second and makes I7's
saturation gate pass *for the wrong reason*, which is worse than one that
fails. So each sensor archetype declares `lost_after`: a contact must be
UNSEEN for that long before `lost` fires. "Not seen for N scans" is still a
statement about geometry — a debounce on the measurement, deterministic and
replayable — not a belief about where anything went. Beside FOV and range in
the archetype, not in the rill.

**③ Cadence is declared, in fed time, and never adapts.** The stronger form of
"adaptive on the record": the frame-budget controller sheds rendering quality,
it does not shed perception. Five posts against thirty raiders is ~150 dot
products surviving into tens of rays, against a shadow pass spending millions
per frame — perception is free at this scale, so buying back a rounding error
with a transcript knob and a replay-divergence surface is a bad trade. The
escape hatch (cadence stretched only through a knob that itself rides the
transcript) is designed and **deliberately unbuilt** — the Delta-enum
reservation discipline, third use. This turns I8's bit-identical raid from
something defended into something true by construction.

**④ Alpha cutout is FILLED, not worked around.** The CPU sight walk gains a
per-query alpha test, default ON for perception. The −17% that justified
omitting alpha was measured on the *shadow pass* (millions of rays/frame); a
sensor scan fires tens. Five orders of magnitude apart — the performance
argument was the pass's, not the query's. And the sensor must agree with the
**player's eye**, not with the shadow pass: a raider plainly visible through
sparse foliage being invisible to the sentry is a fiction violation in the
opposite direction. The birds-scatter tier survives this intact — dense canopy
still genuinely hides, and low-confidence indirect evidence is still the right
channel for it — it simply stops being asked to cover for a hole.

**⑤ Publication uses a `.sensor` source variant**, not `.engine`. The
`writeDynamic` source enum is exhaustively switched, so a narrow variant makes
future engine-side producers compiler-guided and keeps provenance sharp in the
transcript.

**⑥ Broad phase stays a linear scan.** A Morton-keyed entity index would be an
optimisation without a workload. The key function (`gauge_quantise.mortonKeyOf`)
exists; the container does not, and does not need to. Reserved, per the same
discipline as ③.

**Deferred fills (debt, NOT doctrine).** Recorded so nobody later mistakes them
for design decisions:

- **Physics bodies do not occlude.** Resident mesh instances *do* — a live move
  re-boxes its world-BVH leaf through `bvh.refitFromLeaf`, so raiders, the
  portcullis and a rising drawbridge all block sight correctly (which R2 needs).
  But `dynamic_bvh` objects live in a per-frame tree only the shaders walk.
  Points at the dynamic-BVH refit, which `game.zig` already calls future work.
- **Instanced mesh leaves are not ray-transformed by any CPU walk.**
  `shadow.glsl` inverse-transforms into an instanced leaf's local frame; the
  CPU walks never have, so they test un-transformed geometry. Pre-existing, and
  it affects the NEE bake today — not introduced by the sight arm. Counted by
  `solver.instanced_leaves_unmapped` so a sensor failing to see a placed raider
  cannot look identical to a sensor working correctly on an empty field.

**Build order (S1–S5), gate-first so I1 lights up before any authoring UI.**
S1–S4 landed 2026-08-24; **S5 is what remains of R1.**

| | | status |
|---|---|---|
| S1 | the atom — Point→Point/Bool, alpha-aware | ✅ |
| S2 | the instrument — cone cull, cadence, dwell | ✅ |
| S3 | the publication — values + occurrence mailboxes, `.sensor` source | ✅ |
| S3.5 | the instance transform (scheduled by a finding) | ✅ |
| S4 | the R1 gate, with its mutation | ✅ |
| S5 | the authoring — `SensorArchetype` + placed instances + cone gizmo | ✅ |

**R1 is complete (2026-08-24).** The tower looks for itself, and a designer
places the eyes.

S5 was the transcription of the `SoundArchetype`/`SoundEmitter` pair, and
sensors are the archetype spine's **fifth** tenant, after grade chips, lights,
sounds and mesh instances. What is inheritable followed the spine's own rule —
an archetype describes a KIND of instrument, an instance describes WHERE ONE
STANDS — so both time constants inherit (that is what makes two towers the same
kind of post) while position and aim never do.

**The dwell is an authored field beside the FOV**, which is ruling ② arriving
where a designer meets it: the instrument's time constant is a property of the
instrument, so it belongs on the instrument's archetype and not in a rill.

Two findings worth keeping from the beat:

- **The spine refuses a half-added tenant.** Adding `sensor` verbs failed the
  BUILD until the surface was classified, then failed a RUNTIME coverage test
  ("saveProject emitted NO record for surface .sensor") until Project
  serialisation existed. Two gates, comptime and runtime, neither satisfiable
  by intent — exactly the exhaustive check the `Source` enum turned out not to
  have when `.sensor` was added to it in S3.
- **The cone gizmo is world-space, not billboarded.** Every other gizmo faces
  the camera, correctly — a light's range is omnidirectional. A sensor's truth
  is its AIM, and a billboard hides the one property a designer is placing it
  for.

**One S5 bug, found the next day by the tenant built after it** (2026-08-24).
The Project loader never read a post's `iid` back off its record key, so every
load handed the sensors the zero identity and the next `saveProject` minted
them fresh ones. Two cuts of one Project therefore disagreed about which tower
was which, and an import's duplicate check compared zeros — the first unsaved
post it met would swallow an incoming one.

It surfaced because the `prim` tenant's arms were copied from these, so the
same omission was there to be caught, and the prim IMPORT test caught it
(2 boxes expected, 1 found). Both surfaces now read `iid` and `prov` off the
key like every other instance, pinned by a test with a plain-language contract:
**a Project re-cut from a loaded plane is byte-identical.** The bug had been in
the shipped tenant for a day with 510 tests over it, none of which ever loaded
a Project twice.

*Nothing found it by reading; a test written for a different tenant found it by
comparing.* Third time this week that the check which caught something was the
one nobody wrote for it.

Still open, and deliberately: **a live sensor loop needs a contact source.**
Nothing in the engine yet enumerates "things a post might see" — R6's `@`
instance registry is the intended answer, and the resident mesh-instance table
(placed objects with live transforms) is the obvious v1 stand-in. Until a
consumer exists, `Solver.bindInstances` has no live caller and an unbound
placed leaf is counted rather than silent.

### R2 — Actions with duration and completion

The drawbridge groans upward; it does not teleport. Effect verbs gain the
command/completion shape (precedent: the camera pose queue):

```
set gate/drawbridge.target 1        # starts the winch
gate/drawbridge.position            # value path, animates 0→1
gate/drawbridge.raised              # occurrence on completion
```

The narrative's best beat — bridge up *just as* the horsemen arrive — is
only expressible if actions take time and completion is observable. A
subsequent contradictory target mid-travel reverses honestly from the
current position (no snap).

**Gate R2:** target set at tick T; position strictly monotonic over the
travel time; exactly one `raised` occurrence at T+travel; a mid-travel
counter-order produces no `raised`, one `lowered`, and a position history
with a single turning point. Bit-identical under replay.

### R3 — Signal vocabulary is a record convention, not machinery

Two long blasts vs three short is a `kind` field on the horn occurrence;
consumers `partition` on it:

```
notify signals/horn { kind: "approach", from: "tower" }
notify signals/horn { kind: "imminent", from: "gate" }
```

Nothing to build — but written as **the convention** because every game
signal will follow it: one mailbox per channel, `kind` discriminates,
`partition` routes, and the channel's record shape is documented where the
mailbox is declared.

**Gate R3:** approach and imminent signals on one channel route to different
consumers via `partition`; an unknown kind reaches the fail branch loudly
rather than vanishing.

### R4 — `def` instantiation at scenario scale

Two watch posts and thirty soldiers are `def sentry(post)` /
`def soldier(n)` mounted per instance — the archetype system earning its
keep, surfacing whatever is rough about parameterised mounts before a real
game does (mount-name templating, per-instance knob paths under the
instance name, capability grants stamped per instance from one template).

**Gate R4:** thirty soldier instances mount from one def; each `inc`s the
assembly tally once; `programs[]` lists thirty with distinct names and
independent counters; unmounting one leaves twenty-nine mounted and the
tally machinery intact.

### R5 — The scenario is a gated test (the raid, with teeth)

The raid narrative already contains its pass/fail criteria — acceptance
gates disguised as a story. §4 pins the harness.

### R6 — Tags: membership as the fourth write kind, with sigil grammar

**The ontology (Chris, 2026-08-24, revised same day): three sigils, three
questions.** `@` names an *instance* — which one (`@tom`, addressable
individual, the social-media reading @ has always had). `^` names an
*archetype* — what kind (`^soldier`, immutable, singular; pointing up to the
type, the instance-of arrow from every object diagram). `#` names a
*condition* — what's true of it now (`#garrison`, mutable, plural, gained
and lost per tick). The revision replaced an earlier `@`-for-archetype
draft: @ everywhere means *this specific account*, so borrowing it for kinds
fought the very intuition it cited — and two sigils had quietly left
instances bare, colliding with the local-stream namespace. Three sigils,
three referents, no bare nouns:

```
spawn ^soldier as @tom | tag @tom #garrison #off-duty
@tom.health | dropped_below 20 | notify signals/medic { who: "tom" }
^soldier & #wounded          # kind filtered by state
#garrison & #in-courtyard    # pure condition algebra
count ^soldier               # how many of the kind exist at all
```

`@tom.health` as a live path is the bonus: instance-scoped subscriptions get
a natural spelling, visually disjoint from `plane.` paths, `^` kinds, `#`
sets, and bare locals — the parser needs no context, and `as @tom` makes
"this spawn is addressable" an explicit authoring choice rather than every
entity polluting a namespace.

**Mechanically, a tag is the fourth write kind**, completing the plane's
coalescing taxonomy:

| kind | coalesce rule | suppress? | idempotent? |
|---|---|---|---|
| set (value) | last-write-wins | same-bytes | n/a |
| occurrence | append all, in order | never | no — twice is twice |
| accumulate (`inc`, reserved) | sum per tick | net-zero | no — twice is double |
| **membership (`tag`)** | **union adds minus removes per tick** | **net-no-change** | **yes — twice is once** |

Idempotence is what distinguishes membership from accumulate: a soldier
cannot be in the shield wall one-and-a-half times. The Delta enum's
reservation widens from one variant to two while it is still warm.

**Storage is the happy accident:** hierarchical tags are radix's native
operation. A tag is a path — membership is key-presence at
`tags/faction/raiders/<entity>` — so "everything under `#faction`" is a
prefix enumeration, the thing the store already does. UE built a gameplay-tag
subsystem; here it is a spelling. Memcmp ordering gives stable member
iteration free.

The rill surface splits along the existing value/occurrence line, both
halves shipped machinery: `#raiders!count` and membership snapshots are
value paths the store maintains; `tags/raiders/joined` / `left` are
occurrence mailboxes per tag (the garrison machinery verbatim). The R1
discipline carries over intact: **aggregation over a group is a sensor, not
a rill loop** — "nearest #raider to the gate" is an engine-published digest
keyed by tag; tags tell the engine what to aggregate over, rills react to
the digest, and nobody per-entity-subscribes a thousand members.

**Pins made at birth:**

- **Spawn-tags keep the boundary honest.** An archetype may *grant initial*
  tags ("my instances start `#hostile`") — a stamped starting condition,
  thereafter owned by the tag system and removable like any tag. Archetype
  membership is never itself a tag. The pacified raider is the canonical
  test: still `^raider` (kind), no longer `#hostile` (state) — and still
  `@grimjaw` until the moment he isn't.
- **The store mirrors the grammar, one row per sigil.** The `^` row
  (`archetypes/<kind>/instances/*`) is engine-maintained, read-only to rills
  — kind is not writable; nothing can be `tag`ged into being a soldier. The
  `@` row is an instance registry: spawn-registered, despawn-retired, so
  "what does `@tom` mean after Tom dies" is askable — the honest answer is
  the path goes NotFound and subscriptions observe it, which is a *feature*
  for death-reactive rills, not an edge case. The `#` row (`tags/**`) is the
  membership write kind, capability-granted by subtree
  (`write: tags/squad-a/*` — "the commander may reassign squads but not
  factions" is a grant, extending I4's pattern).
- **FINDING (CC, 2026-08-24): "subscriptions observe it" is not true today,
  and absence cannot be made to mean it.** Three verified facts: the plane's
  `removeDynamicPrefix` emits *no deltas by design* ("there is no delete
  semantics on the stream; readers simply find nothing"); rill's mount treats
  `NotFound` as "leave the slot empty and carry on"; and its evaluator skips
  any node with a missing required input. So when Tom dies, a rill watching
  `@tom.health` does not go quiet and does not fire — **it keeps Tom's last
  reading forever.** A `dropped_below 20` sits armed on a corpse's final
  number, and nothing in the stack can tell that from a man standing very
  still.
  Recommended shape, for the R6 beat rather than now: **death is an
  occurrence, not an absence.** A dataflow evaluator cannot subscribe to a
  thing that is not there — absence is unobservable by construction — so the
  `@` registry should publish a despawn occurrence the way tags publish
  `joined`/`left`. That is shipped machinery (mailboxes, never-suppress,
  §4.1 rounds), it is ordered and replayable, and it makes "what does `@tom`
  mean after Tom dies" answerable *on the stream* instead of by a reader
  noticing nothing arrived.
- **RULED 2026-08-24, once for both: death is an occurrence that carries its
  own record, and the corpse is removed.** Built first for programs (the
  supervision tree had the same hole — see rill-agents §6); entities follow the
  same rule when R6 lands. This *deviates from the retain-plus-occurrence lean*
  and the reasons are worth keeping, because two of them only appeared once the
  code was written:
  - **Tombstone was never really a contender.** It is a read-path fix for a
    push-path problem: subscribers never poll, so making the store `NotFound`
    pushes nothing to them and changes nothing about the failure mode.
  - **Retaining conflicts with a ruling already made.** §6 says the remedy for
    a watchdog trip is "remount (restart, not resume)". A program's error
    mailbox lives under its own prefix, so retaining it means a remounted
    program inherits the dead one's error window — a restart that inherits the
    corpse's tally is not a restart. Removal is what keeps remount honest.
  - **The post-mortem was never in the corpse.** Every error was already
    published as an occurrence *before* the death, so whoever was watching
    holds the history. Retention would only serve someone who was not watching
    — and that program was going to be wrong under any semantics.
  - **Two sources that cannot disagree.** `programs[]` says what is alive and
    `programs/**` holds its wires; retention would let a wire outlive its
    listing, which is principle 8's failure wearing the opposite mask — a
    presence that means nothing, with nothing to say so.
  For entities the payload is the place to put whatever the corpse would have
  held: the certificate is the record, so a despawn may carry a final digest
  if the game wants one. The lead rider, pinned to the dirt, is still the test
  case — he just leaves a certificate rather than a body.
- **Kind, condition, behaviour are three systems on one entity:**
  `^soldier` stamps the entity, `def soldier(n)` mounts the behaviour,
  `#garrison` connects them — the assembly count watches the tag regardless
  of which rills animate the members. (This resolves R4's entity/program
  pairing question before it was asked.)
- **Spatial volumes write tags:** `#in-courtyard` maintained by a trigger
  volume — the grade-volume machinery with a tag write instead of a grade —
  is the bridge between space and membership every game wants on day one.

**Gate R6:** tag add twice then remove once leaves non-membership
(idempotence both ways); a prefix query over `#faction/*` enumerates exactly
the live members in stable order; `joined`/`left` occurrences deliver once
per actual transition (not per redundant write); a trigger volume maintains
`#in-courtyard` such that `#garrison & #in-courtyard` counts match scripted
entity positions at every tick; `#garrison!count` reconciles exactly with
members present (membership cannot drift the way a blind counter can); a
rill granted `tags/squads/*` is refused at mount when it writes
`tags/faction/*`, violation named. Deterministic under replay throughout.

**Ironwood upgrades that follow:** the assembly tally becomes membership
(`#in-courtyard & #garrison` — honest by construction, superseding the blind
`inc` tally in I5); the sally-port force is that same intersection; raiders
are `^raider` stamped `#hostile` at spawn, and the v2 growth path's
"pacified" outcome is a tag removal, not a despawn.

## 4. The Ironwood gate (pre-registered)

Harness: a scripted raider timeline fed as deltas (positions per tick,
crossing sensor ranges on a fixed schedule), dusk time-of-day preset, all
keep rills mounted from `.rill` sources in the test corpus (which thereby
become `rill examples` material — no second example source). Assertions:

- **I1 horn latency — LIVE (2026-08-24, N = 1).** The tower no longer has
  sightings fed to it: an engine sensor casts sight-lines through the same BVH
  the renderer walks, against a tree line the raiders clear and a standing
  stone one of them rides behind. Three clauses, checked in the order that
  makes a failure legible rather than the order this doc lists them — a lost
  cull breaks both the count and the timing, and *"the watch saw 8 men at once;
  there were only 7 in the pass"* names the defect where *"the first raider
  showed at beat 0"* names a symptom:
  1. the two who are never seen fail **different** culls (one range, one cone),
     so a sensor that lost one check cannot pass a gate that tests the other —
     and they must be absent from the **count**, not merely from the mailbox,
     because the count is what a `rose_above 0` sentinel watches;
  2. the count leaves zero on the crossing tick, horn within one frame;
  3. one sighting per NEW contact, however long he then stands in the open;
     plus the retained four being the four most recent crossings **in order**,
     which a ring that kept the first four would fail while passing every count.

  **The sentry rill did not change by one character** when the real sensor
  replaced the stub. That was the bet the stub was built on.

  **Its mutation:** delete the dwell and one man walking past one stone becomes
  a raid — seven crossings become **ten** arrivals, and the reconcile breaks.
  The count is pinned, not left as "more than seven": *more* would still pass
  if the storm shrank to a single stray and the scenario had quietly stopped
  exercising the stone. The weaver exists **because** the first draft had no
  occlusion for the dwell to absorb — seven raiders in clean lanes gave seven
  sightings with the dwell and seven without, so the mutation did not bite and
  I1 was watching nothing. Caught by writing the mutation, which is the entire
  argument for the practice.
- **I2 beacons:** lit iff time-of-day is night at horn time — run the raid
  once at dusk, once at noon; beacons differ, all else identical.
- **I3 gate committed:** portcullis-drop and drawbridge-raise targets are
  set before the scripted raiders reach the ditch tick; `raised` completes
  before the vanguard's arrival tick (the narrative's photo-finish, as an
  inequality).
- **I4 gate holds:** after the alarm, no write opens the gate — including a
  deliberately mounted traitor rill whose open-gate write is **refused at
  mount by the capability grant**, with the violation named. (Capabilities'
  first game-shaped test.)
- **I5 assembly:** tally reaches 30 before the `delay 2m` deadline
  occurrence; the wall_formed signal precedes the deadline in the log.
- **I6 sally port:** opens only after the commander's mailbox occurrence;
  the counter-attack trigger fires exactly once (cooldown proven under a
  double-order).
- **I7 nothing lost, nothing invented:** every sighting in the script
  appears in a mailbox or its drop count; totals reconcile exactly.
- **I8 determinism:** the entire raid — sensors, horn, winch, assembly,
  sally — replays bit-identically from the transcript, and the same script
  fed twice produces identical slot state. (G2 at scenario scale.)

Failure of any assertion names the standing order it violates — the test
speaks the fiction's language in its messages, because that is what makes a
failed run readable at 2am.

## 5. Open ruling — the enemy side

Raider behaviour (stalling at the ditch, bunching in confusion) is enemy AI.
Two options:

- **Scripted** (v1): the raider timeline is test data. Cheap, fully
  deterministic, sufficient for every gate above.
- **Enemy rills** (v2): the raiders are their own mounted programs with
  their own sensors and grants — "both garrisons are rills" is the more
  interesting engine claim and the harder test (two rill populations
  interacting only through the world, symmetric capability audit, and the
  first real workload for rill-LOD/island-parallelism when the armies grow).

Recommendation: v1 for the gate, v2 recorded as the scenario's growth path —
the ditch-stall then stops being scripted and becomes emergent from raider
standing orders, which is the moment Ironwood stops being a test and starts
being a game.

## 6. Sequencing

R3 is free (a convention paragraph). R1 and R2 are engine work and the real
schedule items — R1 first (nothing reacts until something perceives). R4
rides `def`'s existing roadmap with the soldier corps as its workload. R6's
delta-kind reservation is a five-line act now (widen the enum to two reserved
variants); its store row and sigil parsing land as their own beat, before R1
if convenient — sensors keyed by tag (`nearest #raiders`) want the tag row to
exist. The Ironwood gate assembles incrementally: I5/I6/I7/I8 can run against
a sensorless stub (horn fed directly) as soon as `also`/`inc` land; I1–I4
switch on as R1/R2 arrive; I5's tally upgrades from blind `inc` to
membership when R6 lands. The scenario stays green from its first partial
mounting onward — it grows teeth, it never waits toothless.

**R1's internal order, with one beat scheduled by a finding (2026-08-24):**
S1 the atom · S2 the instrument · S3 the publication · **S3.5 the instance
transform** · S4 the gate · S5 the authoring.

S3.5 is not optional and it must precede S4. `shadow.glsl` inverse-transforms
a shadow ray into an instanced mesh leaf's local frame (`leaf_data.w != 0`);
no CPU walk ever has, so every CPU sight-line tests *un-transformed* geometry
at the wrong place. Three reasons it lands before the gate rather than after:
it silently invalidates R1's own resident-occlusion ruling (a placed raider
would not occlude); it affects the NEE bake **today**, so it is a live bug and
not merely a sensor concern; and Ironwood's raiders will be placed instances,
which means S4 would otherwise inherit the bug **as a passing test** — the
vacuous-gate failure mode this doc's own mutation practice exists to prevent.
Gated by exactly the scenario that exposed it: a placed occluder blocks a
sight-line that the same geometry, unplaced, does not. Until it lands the hole
is counted, not silent (`solver.instanced_leaves_unmapped`).
