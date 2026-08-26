# Brief for a fresh context — the envelopes campaign

*For the Claude Code session that builds this. You are starting cold.
Read `docs/cc-brief-tier2.md` §3–§5 first for the ratified language rules
and the ledger — they still hold, all of them. This file is only what is
NEW. Chris is the verdict function: rulings are his, gates are yours.*

**Stamped by Chris 2026-08-26, immediately after the tier-2 campaign
closed and its ergonomics re-probe was stamped.** Nothing here is a
proposal; the rulings below are rulings, and the two questions this brief
opened were both answered before it was banked — there is nothing left
waiting on Chris. What is yours is the building and the gates.

---

## 0. Where you are standing

Tier 2 is **closed and ratified** (`docs/rill-tier2.md`). 284 gates,
registry at 97 core operators, 24 admitted words exactly as the recon
predicted. Branch `tier2-recon`, pushed. Matryoshka 907/907.

The last close-out item was an **ergonomics re-probe**: a reader who had
never seen rill was given the human manual and the §4 asks in prose. They
wrote 29 of 31 in one line — the campaign's claim, confirmed from
outside. They also found three things nobody inside had, all now fixed
(see `implementation-notes.md`, "The ergonomics re-probe"):

- the flagship threshold recipe was **inverted** — and the beat gate
  passed it, because the gate watched the *operator* and not the *row*;
- a printed example **parsed and could never run**, tracing to beat 1b
  having widened `types.accepts` globally (now opt-in per port);
- `and`/`or`/`not` were taught in the agent manual and nowhere in the
  human one.

**This campaign is the reviewer's two unfixed findings, plus the
structural work that would have caught all three.**

## 1. The order Chris set

> **1–2, then 4–5, then 6–8, then the book-runs recon.**

Do not reorder. The typing gate (1) must exist before the new words land
so their ports are covered by it from the first commit.

## 2. Structural — no ruling needed, build them

**(1) A registry-walk typing gate.** Every port's accept set asserted
from its declaration, so a non-broadcast number port refusing an array
*at parse* is a standing assertion. **The beat-1b widening must not be
able to recur silently.**

Notes from the close: `Port.broadcasts` is already opt-in, set on the 27
rows whose eval is minted by `binMath`/`unMath`/`cmpOp`/`boolOp`/
`unBool`; `types.acceptsPort(port_ty, value_ty, broadcasts)` consults it.
Two end-to-end parse checks exist ("the wire gate: a container only
reaches a port that says it broadcasts"). What does NOT exist is the
exhaustive walk. Make the test state the rule *independently* of the
implementation and require them to agree — the both-ways discipline the
class/ticks/fails_mount audits use. A gate that derives its expectation
from the code under test is a tautology.

Known limitation worth writing down rather than papering over: a port
bound from a **pipe** is `any` at wire time (a path has no declared
type), so wire-time typing bites on literals and on typed wires, not on
piped paths.

**(2) An operator index in the human manual**, gated against the registry
**both ways** — the way the agent manual's table already is (see the
`manual parity` test and `untaught_substrate`). The reviewer asked for
this by name: *"an alphabetical operator index with arity and port order.
The tables are scattered across §6b, §6c, §6d, §6f and §7 and cover maybe
half the operators actually used in examples."*

**(3) A recon for the idioms book RUNNING** — recon first, not a
drive-by. Each cell carries a fed-time script and an asserted outcome,
and the gate drives **the cell's own text** against the row's claim.
*The inverted flagship is the argument*: the book cell, the manual recipe
and the gate all said the same wrong thing, because each was a separate
copy. There is a precedent to build on — `manualRecipe(heading)` in
`tests.zig` already drives the manual's own text for the one recipe whose
sense is the claim.

## 3. Rulings — build to these

**`below <on> <off>` — admitted.** The mirror of `above`.

- **First number trips, second releases, for BOTH words.** `above 0.3
  0.2` trips at 0.3 and releases at 0.2; `below 0.2 0.3` trips at 0.2 and
  releases at 0.3.
- **Mount-time refusal if the order is backwards for the word** —
  `above` needs trip > release, `below` the reverse — **both numbers
  named**. (`above` already refuses `off > on`; mirror it. Mount runs
  tick 0, so an eval refusal lands at mount; that is the `along`
  precedent Chris stamped.)
- The flagship recipe becomes
  `plane.world.light | below 0.2 0.3 | set plane.lights.street.on`
  **with no `| not`**. Customer: the flagship row.
- Levels emit at tick 0 (beat 4's pin): `below` publishes `v <= on` at
  mount.

**`first`/`last` on an empty array end the wave SILENTLY** — the `where`
precedent; a value cannot be invented. **`nth` keeps erroring**: it names
a position, which is a claim. The nearest-threat recipe gains
`contacts | len | set plane.ui.contacts`, so **absence is said by the
count, never a sentinel**. The manual says why.

⚠️ **Today `first` refuses on empty and is gated for it** ("beat 3b:
`first` errors on empty — it promises one value"). That gate and its
manual paragraph both invert with this ruling.

**`len` and `last` do not exist yet and are ADMITTED (2026-08-26), not
substrate.** Both were cut at the recon on a reason that was not one —
"cheap but still words". Corrected in `rill-tier2.md`, reason and all:

- **`len`'s customer is the `first`-on-empty ruling itself.** Absence has
  to be said by something once `first` goes quiet, and it is said by the
  count. `stats | .n` for a length is the magic-box shape.
- **`last`'s customer is "the most recent reading"** — `window 5s | last`.
  `window` is a rolling buffer; its newest entry is what people want from
  it. The re-probe asked for it by name.
- **`last` is compulsory, not merely admitted**: the empty rule above is
  stated for the *pair*, and a manual describing a word that does not
  exist is exactly what the re-probe just caught.

**Neither is substrate.** Substrate is a primitive a *taught* word is
defined over (`wave` under `lfo`, `project` under `.field`, `nth` under
`choose`). Both of these are taught.

## 4. The words — six, every one with a named customer

Two of them (`len`, `last`) are §3's ruling made sayable; the other four
are below. `below` is in §3. `kick`, `adsr` and `step` are the register
family.

**`kick <attack> <decay>`** — occurrence in, one-shot envelope out.
Rises over `attack`, falls over `decay`, **stops at ε**. **Retrigger
restarts from the current level, never from zero.** Customers: *flash on
hit*, *shake on impact* — the reviewer's biggest finding, which cost them
two programs, an invented gate path and a 60 ms magic number whose only
job was giving `ease` something to fall from.

> Chris: *"Name is the reader's; read-aloud it if you have a better
> one."* So: read it aloud before you build it, and record the rejected
> names either way (the `pass`/`effect`/`tee` → `also` precedent).

**`adsr <a> <d> <s> <r>`** — level in, envelope out: rise, decay to
sustain while the level holds, release when it drops. **Four positional
statics in the conventional order — that order is a cultural constant.**
**Ticks only during transitions; a held sustain costs nothing** (gate it
on the eval counter going flat, the way `ramp … from` is gated — a value
that stays put looks identical to one being recomputed).

**RULED 2026-08-26: `adsr` takes PORTS, not statics** — CC's lean,
recorded as the deviation from Chris's first wording. `a`/`d`/`r` are
durations and rill has no duration static kind, ports are positional in
the same conventional order, and **a live release is worth having**.

**Pin that came with it: a parameter change applies to the NEXT segment
and never retimes the one in flight** — the same rule as `step`'s live
array carrying its index. A release that shortens mid-fall would jump,
and a jump is the thing this whole family exists to avoid.

**`step <array>`** — a step sequencer modelled on an arpeggiator.
Rousing is an **occurrence**; each rousing emits the **next** element.

- Modes as **bare-word flags** (`StaticDecl.flag` exists — beat 3b built
  it for `sort … desc`): default **runs once and the wave ends**; `loop`,
  `bounce`, `reverse`, `random seed <s>` (with replacement), `shuffle
  seed <s>` (a fresh permutation per pass, no repeats within one).
- `max <n>` keyword optional caps emissions.
- **State is index, direction, PRNG — and it rides the dump.**
- **The array is LIVE**: if it changes mid-sequence the index carries and
  clamps to the new length; **it does not restart**.
- Customers: arpeggios and step sequences from the MIDI stack, cycling
  camera positions on a key, palettes, idle animations on random.

One PRNG family still holds (beat 4's pin): `random`/`shuffle` draw from
xoshiro256++ like `rand` and `shuffle`, not a third generator.

## 5. Word count

**RULED 2026-08-26: 29 → 35.** Six words — `below`, `len`, `last`,
`kick`, `adsr`, `step` — **every one with a named customer, none on
prose.**

Chris's first pass said 33 for four words; the `first`/`last` ruling
requires `len` verbatim in its recipe and states the empty rule for the
pair, so `len` and `last` come with it. Chris: *"the second is my error —
I wrote a recipe against two words that don't exist."*

**The ~30 was a discipline against prose-admitted words, not a cliff, and
it has not let anything through that had a customer.** Record it that way
— the budget's job was never the number.

## 6. What "done" means — unchanged from tier 2

Per `cc-brief-tier2.md` §6, plus one added at close:

1. gates hold in Debug **and** ReleaseFast, mutations bitten and counted;
2. every new op has its **before/after pair** in `docs/idioms.rillbook`;
3. §4 of `docs/rill-tier2.md` is re-scored, correctness column included;
4. the manuals and spec change in the **same commit** — and the parity
   gate will tell you if the agent manual drifts;
5. Matryoshka's suite is still green (`~/dev/matryoshka`, `zig build
   test`, 907/907);
6. **the typing gate covers the new ports** (Chris, explicitly).

## 7. The ledger lines this campaign was bought by

All four are in `implementation-notes.md` under "Gate discipline". They
are here because each was paid for by a mutation that *survived*:

- a gate asserting "A rather than B" must run where A ≠ B, and assert
  that inequality first;
- **gate past the library's fallbacks**, or the library is the thing
  under test;
- **gate the property the doc claims**, not the implementation's
  incidental ones — and when a property has a period, sample **on** the
  period;
- **a gate that watches the operator is not watching the row.** This one
  is the newest and it is why item (3) exists.

## 8. Forks still open (tier-2 doc §8)

Not this campaign's work, but do not lose them: `first` on empty is being
settled here, but §11's nearest-threat recipe walking into the error
budget was only half the finding — the other half is that a forgiving
`take 1 | map (.id)` changes the published *shape*, so every consumer
changes too. And `stats` on an empty array is still unspecified where
`reduce` is settled.
