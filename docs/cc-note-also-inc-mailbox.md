# Note for CC — rulings from the garrison conversation (2026-08-24)

Context you don't have: after your §3 report, Chris and Claude Chat worked
through the collaborative-agents scenario (two watchers, one attacker) and it
produced one corrected ruling, one new write kind, and one new piece of
syntax. All three are Chris-stamped. This note is the full record; nothing
else changed.

---

## 1. Ruling correction — mailbox paths never suppress (supersedes earlier phrasing)

The earlier pin ("writes to a mailbox path follow the mailbox's policy") was
incomplete. The full rule:

> **Mailbox paths carry occurrences — writes always append, always deliver,
> never suppress, same bytes or not. Value paths coalesce and suppress. The
> policy declaration is what switches a path's kind.**

Two corollaries, both load-bearing:

- **Subscribers to a mailbox path see each occurrence appended that tick, in
  append order** — per-tick coalescing explicitly does not apply there. This
  is the one place it doesn't, and it's the difference between "three enemies
  arrived" and "an enemy arrived." (Your multi-round sweep proposal is the
  implementation of exactly this; the go was given with three pins — see §4.)
- **`notify <mailbox-path> <record>` is approved** — as an alias for `set`
  aimed at a mailbox path, landing in the same beat as the occurrence-round
  work, since the semantics that make it truthful land there. It is intent on
  the sleeve, not new machinery. The *declaration* surface (how a path
  acquires mailbox policy beyond engine-declared `errors`) and the consumer
  cursor stay deferred to their first real customer, as you proposed.

## 2. New write kind — `inc` (accumulate), reserve the Delta variant now

Chris raised his original Substrate's atomic add/inc. Post-reshape the store
is single-writer, so the point isn't atomicity — it's a **third coalescing
rule**. The write-kind taxonomy on the plane becomes:

| kind | coalesce rule | suppress? |
|---|---|---|
| set (value) | last-write-wins per tick | same-bytes silenced |
| occurrence (mailbox) | never — append all, in order | never |
| **inc (accumulate)** | **sum deltas per tick, apply once** | net-zero tick silenced |

Why it's not sugar: **counters are currently inexpressible** —
`plane.x | add 1 | set plane.x` reads a path it writes and the cycle check
rightly refuses it. `inc plane.defense.sightings 1` is a blind delta: no
read, commutative, order-independent, so it passes the cycle ban
legitimately (the writes-list treats it as a write that implies no read).
Determinism improves over read-modify-write since arrival order stops
mattering.

Pins: numeric slots only; **rejected loudly on a mailbox path** (append and
accumulate are different kinds; a path is one kind); delta on the wire as
`{path, +n}`.

Action now: when you add the Delta `kind` for occurrences, **reserve the
third variant** so this lands without a second refactor. Building `inc`
itself can ride the beat after the rounds land.

## 3. New syntax — the `also` block (Chris-stamped, parser-only)

```
s.gate.enemy_count | rose_above 0
  | also { inc defense/sightings }
  | also { notify defense/alerts { from: "gate" } }
  | trigger attack
```

**`also { … }` is pure parse-time desugaring to fan-out with an anonymous
branch** — no new node kind, no evaluator change, no passthrough
classification:

```
x | also { S } | rest        ⇒        x as ⟨anon⟩
                                      ⟨anon⟩ | S
                                      ⟨anon⟩ | rest
```

The block's implicit source is the in-flowing value; the main wire continues
from the same slot untouched — identity on the stream holds **by
construction** (the downstream edge IS the upstream slot), which is why no
op-level "passthrough" class is needed. Occurrence semantics fall out free:
N rousings run the block N times, because it's ordinary fan-out.

Rules (all parse-time, all cheap):

- No `as` escapes the block — anonymous scope, same enforcement shape as
  def's close-over-nothing.
- The block's writes join the program's write list at flatten; cycle check
  and (future) capability union see straight through it.
- Multi-statement blocks desugar to more branches off the same anon name.
- If the block's final node produces a value nobody consumes: **warn** —
  "also-block discards a value; end with a sink or drop the tail."
- Doc line to include: *"`also` runs a side branch and passes the value
  along unchanged"* — one sentence so nobody reads it as conditional or
  optional.

Naming for the record (so the bikeshed stays shed): `pass` was Chris's
original instinct, rejected for the Python squatter ("do nothing" is the
worst collision for a block that does something). `effect` rejected for the
in-house collision with OpClass `.effect` — one word, two registry meanings.
`tee` rejected as plumbing jargon; `aside` was runner-up. **`also` won the
read-aloud test**: "health drops below 20, also play the heartbeat, trigger
the warning" — states both halves of the contract (something else happens;
the main clause continues) in one English word.

## 4. Restating the three pins on the occurrence-rounds go (unchanged, for one place)

1. **Time is constant across rounds** — all rounds of a tick share the
   tick's `{frame, time_ns}`; a cooldown must not open mid-tick.
2. **Bound named in the ledger** — rounds are bounded by per-frame
   production (engine mailboxes cap structurally at keep-latest-N); the
   error/bus budget is the guard if a producer runs away. No mechanism, one
   sentence.
3. **§4.1 amended in the spec in the same commit as the code** — "one sweep
   suffices" becomes: one sweep per round; one round per queued occurrence
   per path; values coalesce across the whole tick; occurrences never
   coalesce. The skipped garrison test un-skips as the gate; your
   same-script-twice determinism gate rides alongside.

## 5. Suggested landing order

1. Occurrence rounds + §4.1 amendment + un-skip + determinism gate
   (already go'd), with the Delta kind enum carrying the reserved `inc`
   variant.
2. `notify` alias in the same beat.
3. `also` block — parser + desugar + gates (escape-ban, write-list
   visibility, N-rousings-runs-N-times, discard warning). Independent of 1–2;
   sequence at your convenience.
4. `inc` end-to-end (sink verb, sum-coalesce, net-zero suppression,
   mailbox-path rejection) — its gate extends the garrison test: gate and
   tower each `inc` in one tick, tally rises by 2.

The garrison program is the through-line test for all of it: three agents,
one mailbox, one counter, one `also`, and every ruling above exercised in
about eight lines.
