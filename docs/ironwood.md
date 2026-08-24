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

**The ontology (Chris, 2026-08-24): `@` for archetypes, `#` for semantic
grouping.** `@soldier` names a *kind* — immutable, singular, a thing is one
archetype forever. `#garrison` names a *condition* — mutable, plural, gained
and lost per tick. The sigil is the grammar enforcing the split: `@` answers
"what is it," `#` answers "what's true of it now," and the reader learns the
type system from the glyph (the social-media intuition transfers: @ mentions
an identity, # joins a conversation).

```
spawn @soldier as tom | tag tom #garrison #off-duty
#garrison!count | rose_above 29 | notify signals/wall_formed
sensors/gate/nearest #raiders | dropped_below 50 | notify signals/horn { kind: "imminent" }
tag tom -#off-duty +#in-courtyard
```

Same sentence position, different question, no context needed:
`@raider` in a sensor argument means "things of this kind"; `#raiders` means
"things currently in this set." Query algebra follows — `#garrison &
#in-courtyard` is set algebra over conditions; `@soldier & #wounded` is
kind-filtered-by-state.

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
  test: still `@raider` (kind), no longer `#hostile` (state).
- **The store mirrors the grammar.** `archetypes/<kind>/instances/*` is
  engine-maintained, read-only to rills — kind is not writable; nothing can
  be `tag`ged into being a soldier. `tags/**` is the membership write kind,
  capability-granted by subtree (`write: tags/squad-a/*` — "the commander
  may reassign squads but not factions" is a grant, extending I4's pattern).
- **Kind, condition, behaviour are three systems on one entity:**
  `@soldier` stamps the entity, `def soldier(n)` mounts the behaviour,
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
are `@raider` stamped `#hostile` at spawn, and the v2 growth path's
"pacified" outcome is a tag removal, not a despawn.

## 4. The Ironwood gate (pre-registered)

Harness: a scripted raider timeline fed as deltas (positions per tick,
crossing sensor ranges on a fixed schedule), dusk time-of-day preset, all
keep rills mounted from `.rill` sources in the test corpus (which thereby
become `rill examples` material — no second example source). Assertions:

- **I1 horn latency:** the horn occurrence lands within N ticks of the first
  sighting occurrence (N pinned when R1 lands; the *assertion shape* is
  pinned now).
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
