# Recon — running the idioms book

*Envelopes campaign, item 3. Chris: **"A recon for the idioms book
running: each cell carries a fed-time script and an asserted outcome, and
the gate drives the cell's own text against the row's claim. The inverted
flagship is the argument. Recon first, not a drive-by."***

**Status:** recon, 2026-08-26. Nothing here is built. Five measurements,
three designs, one recommendation, three questions for Chris at the end.

---

## 0. The argument, restated

At tier-2 close a reader with no priors found that the flagship threshold
recipe was **inverted** — `above 0.3 0.2` lights the street at noon. It
had shipped in §6f of the manual, in §11's recipes, and in this book. The
beat-4 gate passed it, because the gate watched the *operator* and not
the *row*.

Three copies of one sentence, and each was separately wrong. The ledger
line that came out of it is *a gate that watches the operator is not
watching the row*, and the fix applied then was to make one gate drive
the manual's own recipe text (`manualRecipe(heading)` in `tests.zig`).

This recon asks what it would take to do the same for the book.

## 1. What the book is today

`docs/idioms.rillbook` — 117 cells, JSON, format version 1.

| | |
|---|---|
| markdown cells (commentary) | 60 |
| rill program cells | 57 |
| …of those: `-before` cells | 17 |
| …`-after` cells | 28 |
| …`partial` cells | 2 |
| …standalone illustrations | 10 |
| distinct plane paths touched | 70 |
| cells using a time- or state-driven operator | 19 |

The gate today (`tests.zig`, "the idioms book parses") **parses** every
program cell and pins both counts, exhaustively both ways. It proves the
book is collected and that every cell compiles. It proves nothing about
what any cell *does* — which is exactly the hole the inverted flagship
went through, because that cell parsed perfectly.

## 2. The measurements that decide the design

Five, taken by mounting every cell over an empty `MockPlane`.

**F1 — the book mounts.** 56 of 57 cells mount clean with nothing fed and
**zero refusals**. The one that does not is `contracts-expect`, and it
fails *by design*: `expect` carries `fails_mount`, and a mount with no
value to assert against is precisely what it promises to refuse. So
"does it mount" is already true and is not worth a gate.

**F2 — but two thirds of the book is silent.** Only **19 of 57** cells
produce any output at all with nothing fed. The other 38 subscribe to
paths that have nothing on them, and a subscription with no value is a
program that has not started. There are 48 subscriptions over 70 distinct
paths; 10 cells subscribe to nothing at all (pure sources and literals).

> **This is the whole cost of the item.** "The book runs" is not a
> runner; it is **38 fed-time scripts**, one per cell, written by hand,
> each of which is a small claim about what the world looks like when
> that row is true.

**F3 — and "run" means fed time, not tick 0.** 19 cells use an operator
that is driven by the clock or carries state (`ease` 6, `window` 4, `lfo`
3, `noise` 3, plus `every`, `ramp`, `kick`, `step`, `adsr`, `diff`,
`integrate`, `pulse`, `sample`, `delay`, `cooldown`, `toggle`, `tally`,
`rand`). A script is a *timeline* — feed, tick to t, assert — not a set
of inputs.

**F4 — 31 of the 57 cells are verbatim copies of text in the human
manual**, and 16 appear verbatim in `tests.zig`. That is not an
observation about tidiness. **It is the mechanism the inverted flagship
used**, measured: the same program is written down in up to three places
and nothing in the suite notices when the copies stop agreeing.

**F5 — an in-file script would be deleted by the first browser save.**
The rillbook web app (`~/dev/matryoshka/web/apps/rillbook/rillbook.js`)
serialises with `toDoc()`, which rebuilds each cell from exactly five
named fields:

```js
cells: this._cells.map((c) => ({
  name: c.name, source: …, mode: …, collapsed: …, markdown: …,
}))
```

**Unknown fields are dropped, silently, on every `rillbook save`.** Any
design that puts scripts inside `idioms.rillbook` is one browser save
away from losing all of them, with no error and no diff to read until the
gate goes quiet. This is a cross-repo dependency, and it is the single
most important fact in this recon.

## 3. Three designs

### A — scripts in the cell (what the brief describes literally)

Add `drive` and `expect` to the cell JSON; bump the format version.

```json
{ "name": "night-falls-after", "mode": "mounted",
  "source": "plane.world.light | below 0.2 0.3 | set plane.lights.street.on",
  "drive": { "seed": { "plane.world.light": 0.5 },
             "steps": [ { "feed": { "plane.world.light": 0.15 } },
                        { "expect": { "plane.lights.street.on": true } } ] } }
```

- **For:** the claim sits beside the program, where a reader of the book
  sees it. It is the only design that could ever make the book *runnable
  in the browser*, which is the version with real teeth — a person
  clicking a cell and watching the assertion go green.
- **Against:** **blocked by F5** until Matryoshka's `toDoc` carries
  unknown fields through. Also the largest piece of work: a schema, a
  version bump, a JSON driver in `tests.zig`, and the app's own
  round-trip to keep honest.
- **RULED 2026-08-26: this is the destination**, reached directly from B.
  The blocker is raised as an ask (§7), not designed around.

### B — scripts in the gate, cells addressed by NAME

Add `bookCell(name)` beside the existing `manualRecipe(heading)`, and
write ordinary Zig gates that drive the book's own source text.

```zig
const src = bookCell("night-falls-after");   // the book's text, not a copy
// …mount it, feed the dusk wobble, assert the row's claim.
```

- **For:** **zero format change**, so F5 cannot touch it. It is a
  precedent already working in this repo rather than a new mechanism.
  Assertions are Zig, so they can say things a JSON schema would have to
  grow arms for (flip counts, eval-counter flatness, bit patterns). It
  can start on the next commit.
- **Against:** the claim lives in `tests.zig` and a reader of the book
  does not see it. It does not move the book toward being runnable.

### C — a sidecar, keyed by cell name

`docs/idioms.drive.json`, a map from cell name to script, gated both ways
against the book.

- **For:** scripts are data (so a browser runner could read them later),
  and F5 cannot touch them. A both-ways gate keeps the two files in step.
- **Against:** two files to keep aligned, and the claim is still not
  beside the cell for a reader.
- **RULED 2026-08-26: DEAD END — do not build.** Fixing `toDoc` makes A
  reachable, and a sidecar would be a third place for the same text to
  drift, in a recon whose central finding is that the text already lives
  in three places.

## 4. Recommendation

**RULED: B now, A when the round-trip is lossless, C never.** The ask for
the `toDoc` fix is raised (§7) rather than designed around — it is four
lines in a file nobody is otherwise touching, and it is data-loss
prevention on its own merits now that the format has two writers.

Phased, smallest useful thing first:

1. **The identity gate (do this first, it is tiny).** F4 says 31 cells
   are verbatim copies of manual text and nothing checks that they still
   agree. A both-ways gate over a named list of shared rows — the manual
   text and the book cell must be byte-identical — is perhaps 40 lines
   and it attacks the *mechanism* directly rather than the symptom. Two
   of the three copies stop being able to drift.
2. **`bookCell(name)`, and the eight flagship rows driven from it.** The
   rows whose claim is a *sense* rather than a shape: night-falls,
   flash-on-hit, the held note, the arpeggio, nearest-threat, the camera
   shake, the breathing exposure, the mount fade.
3. **The `-before` cells, gated on their BADNESS.** This is the strongest
   evidence in the book and it is currently unasserted: the night-falls
   before *chatters* (six flips against zero — already gated by hand, and
   it should be driven from the cell), the flash-on-hit before has a tail
   that never reaches zero, the arpeggio before accumulates a counter
   that rides every dump forever. A before-cell that stopped being bad
   would mean the row no longer needs the word.
4. **Sidecar or in-cell**, once there are enough scripts that a schema
   pays for itself, and once F5 is resolved.

**Assert on what the cell WROTE, never on slot names.** `MockPlane`
records every write in order (`writes: []Write`, with path, value and
kind), and a cell's writes are its own public claim. Slot paths like
`programs.p.below1.out.out` are an implementation detail — a gate keyed
on them breaks when an operator is renamed, which teaches everyone to
stop writing gates.

## 5. What this will not catch, stated rather than buried

- **The markdown cells.** 60 of the 117 cells are prose, and prose is
  what carried the *explanation* of the inverted flagship — the sentence
  saying "so the sense has to be turned over" was as wrong as the
  program. Nothing proposed here reads it.
- **A cell that is right and useless.** An assertion proves the program
  does what the cell says; it cannot say the row was worth a word.
- **Drift between the book and `tests.zig`.** F4 counts 16 cells whose
  text is duplicated into a hand-written gate. Phase 2 removes that for
  the rows it touches, and leaves the rest.
- **The third copy.** The identity gate in phase 1 ties the manual and
  the book. `rill-for-agents.md` carries the same vocabulary in a
  different form and is tied to the registry, not to either of these.

## 6. For Chris — RULED 2026-08-26

All three answered. The build order Chris set is **identity gate →
after-cell correctness → before cells**, and the notes below record what
each answer changed.

**Q3 — the manual is the source; the book cites it. BUILT.** *"Evidence
cites the claim, never the reverse, and the failure message tells you
which file to fix."* Landed on its own (`9250db0`) with Chris's added
requirement: the named list is gated **both ways** — every listed row
matches, *and* the list covers every program appearing in both files.
Without the second half a new shared program drifts while the gate stays
green, *"which is the hollow-filter shape we keep paying for."*

**Q2 — raise the Matryoshka ask now; start scripts-in-the-gate
regardless.** Chris: *"a serialiser that silently drops unrecognised
fields is data loss in a format with two writers, and rill is now the
second. Preserve unknown keys — four lines, and the next feature doesn't
hit the same wall."* Consequences, all of them settled:

- **Design C (the sidecar) is a dead end. Do not build it.** Scripts live
  in the gate until the round-trip is lossless, then move **into the
  cell** — design A is the destination, reached directly.
- The book's header now carries the warning, until the fix lands.
- **The ask, stated for whoever picks it up** (§7 below).

**Q1 — yes, the before cells get gated, as their own pass after the
after-cells.** *"An argument nothing runs is prose."* And the bill is
narrowed, which changes the estimate in §2 materially: **one assertion
each, of the badness the row itself claims, in the row's own words** —
night-falls counts flips, flash-on-hit asserts the eval counter never
flattens, arpeggio asserts the plane path grows. **No timeline longer
than it takes to show the claim.** F2's "38 hand-written scripts" was
costed as full reproductions; one assertion each is a fraction of that.

## 7. The Matryoshka ask (raised 2026-08-26)

**`web/apps/rillbook/rillbook.js`, `toDoc()` — preserve unknown cell
keys.** It currently rebuilds each cell from five named fields, so every
other key is dropped on save with no error:

```js
cells: this._cells.map((c) => ({
  name: c.name, source: …, mode: …, collapsed: …, markdown: …,
}))
```

Carry the original cell object's remaining keys through (spread the
stored cell, then overwrite the five the editor owns). Worth doing on its
own merits regardless of this campaign: the `.rillbook` format now has
**two writers** — the app and this repo — and a serialiser that silently
drops what it does not recognise is data loss between them.

**Trigger for the rest of the work:** when the round-trip is lossless,
the gate's scripts move out of `tests.zig` and into the cells, where a
reader of the book sees the claim beside the program and a browser
runner becomes possible.

## 8. The questions as originally put

1. **Should the `-before` cells be gated on their badness?** I recommend
   yes, and it is phase 3 above. It is the book's strongest evidence and
   the only part of it that is currently pure assertion — and the
   night-falls chatter gate already proves the shape works.
2. **Is a browser-runnable book the destination?** If yes, design A is
   where this ends and Matryoshka's `toDoc` should be fixed now, as a
   small standing ask, so the option stays open. If no, B and C are the
   whole story and the format never changes.
3. **When the manual and the book carry the same program, which is the
   source?** I recommend the manual — it is the taught text and the book
   cites it — with the identity gate enforcing the direction. The
   alternative (the book is the source, the manual quotes it) reads
   backwards to anyone opening the manual first.
