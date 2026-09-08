# Namespacing the operator table

*2026-09-07, written while adding the RBF pack. Christian, on seeing two more
words proposed: "I'm starting to get a little concerned about the rill
namespace filling up with verbs. maybe we should think about scoping them.
even if it is just prefixes like `rbf_xyz`. But will leave it to you guys to
figure out what makes sense."*

The recommendation is at the bottom and it is short, because the interesting
part is that **the scheme already exists and is already the house's dominant
convention — rill core is the only registrant that has never used it.**

## What is actually in the table

Counted, not estimated (`Registry.ops.items.len` after each registrant, and a
census of the names):

| registrant | operators | one-word | two-word | `_` or `.` in a name |
|---|---|---|---|---|
| rill core (`ops.registerCore`) | 109 | 109 | 0 | 2 (`dropped_below`, `rose_above`) |
| matryoshka (`control.commands.seedRegistry`) | 179 | 12 | **167** | 0 |
| spindrift (`words.register`) | 5 | 5 | 0 | 0 |
| spindrift (`words.registerTracer`, opt-in) | 4 | 4 | 0 | 0 |
| **a running matryoshka** | **297** | 130 | 167 | 2 |

So the number to reason about is not 109. It is **297**, and it has been that
for a while without becoming unusable — because 167 of those 297 are already
scoped. matryoshka's console verbs are `spray add`, `light set`, `rill mount`,
`hud toggle`: 45 distinct group words over 167 operators, with no underscores,
no dots and no sigils anywhere.

Two-word names are not a proposal. They are `registry.zig`'s documented
behaviour (`register` splits on the space so only a *whole* word can be
reserved) and `parser.zig`'s documented behaviour (`parseOpcallCarrying` tries
the two-word form first, "so (verb, subop) pairs are one operator"), they are
exercised on every console line matryoshka serves, and rill core simply never
reached for them because it grew from a flat set of 40-odd primitives that
genuinely have no family.

## The options, and what each costs

### A. Leave it flat, add a convention

Zero machinery. The cost is the one Christian named: every new family spends
general English words on itself. `through` and `bump` are good names for
reading and writing an RBF set and terrible words to have taken from the
language for it — the next family that wants `through` cannot have it.

### B. Underscore prefixes — `rbf_through`

Zero parser cost, and there is a weak precedent (`dropped_below`,
`rose_above`). But those two are *phrases*, not namespaces: the underscore
joins a verb to its preposition. Read aloud, `rbf_through` is "r b f
underscore through", and read-aloud-before-naming is the house rule that
decides names here. It also invents a second separator for a job the space
already does.

### C. Dotted names — `rbf.through`

**Refused on a concrete ambiguity, not on taste** — and the ambiguity has
since moved, so this section is worth reading twice.

*As written (2026-09-07):* `use plane.defense as d` bound `d` as a *path
prefix*, so `d.alerts` was a legal dotted path whose head is not `plane` or
`row`. A dotted operator name was therefore lexically indistinguishable from a
path under an alias, and `use plane.rbf as rbf` would have put an alias and an
operator family in one spelling.

*Since `using` (2026-09-08):* that half is gone. A fold wears a colon at both
ends — `using plane.defense as :d`, referenced `:d.alerts` — so no bare dotted
name can have a bound head any more, and `plane` / `row` / `slate` are again
the only path heads there are.

**C stays refused, on the narrower half that survives.** `name.field` is a
*projection* (`parseProjections`), so a stream bound `as rbf` makes `rbf.through`
a field read of `rbf`, and an operator by that name would be indistinguishable
from it. That is still a precedence question the parser would have to answer by
guessing, and whichever way it guessed would silently shadow something — but it
is now one ambiguity rather than two, and it is worth saying out loud that the
reason recorded here is no longer the reason that applies.

### D. Two-word names — `rbf through`

What matryoshka does 167 times. No new grammar, no new separator, no new
reserved word, and the group word reads aloud as part of the sentence: "the
row's state, rbf through the flame's coat".

Costs, stated:

- **The group word becomes ambiguous in argument position after itself.** If
  `rbf` were also a bare operator and `rbf through` existed, `rbf through`
  would always parse as the pair — the two-word lookup wins. matryoshka lives
  with exactly this (`mount` and `rill mount` coexist) and it has not bitten,
  because the group word is chosen to be a noun nobody passes as an argument.
- **A two-word name cannot be a `def`.** defs are single-word by construction
  (`parseOpcallCarrying` checks `self.defs` before the two-word lookup), so a
  family cannot be extended by a def. That is arguably correct: a def is a
  user's abbreviation, not a member of a registered family.
- **The lookup is one token of lookahead on every `.name` head.** It already
  runs on every operator call in the language; a new family adds nothing.

### E. Packs — a registration boundary, not a spelling

Orthogonal to A–D and the half that actually bounds the table. `registerCore`
is one call; `registerRbf` is a second; spindrift's `registerTracer` is the
existing precedent (its four world-words exist only on a host that owns a
`World` to answer them, and on a host without one a kernel naming `collide` is
refused at mount as an unknown word — which is the right answer, and better
than a word that exists and cannot work).

A pack answers "the namespace is filling up" literally: for a host that has no
use for radial basis functions the language does not have those words at all.
It also gives `help` and tab-complete a grouping to hang off, and it gives the
registry a place to record where a word came from if that is ever wanted.

## Recommendation

**D + E: a two-word name per family, registered in an opt-in pack.** Adopted
here for `rbf through` and `rbf bump`, which is the whole of the change.

**What it means for the 109 already registered: nothing, deliberately.** A
scheme that cannot be adopted one family at a time is not adoptable, and a
mass rename would break every rill ever written for a cosmetic gain. The 109
core operators are the language's primitives — `add`, `clamp`, `where`,
`window` — and primitives are exactly the words that should not wear a group
name. They are not a family; they are the vocabulary families are built from.

The migration path, if a family is ever found among them:

1. Register the new two-word name beside the old one, pointing at the same
   `OpDef.eval`. Both work. Nothing breaks.
2. Move the manual, the idioms book and the rillbook cells to the new
   spelling. The manual-parse gate keeps both honest.
3. When the old spelling stops appearing in any gated document, drop it — or
   keep it forever, at the cost of one table row. `set` → `write` (2026-08-29)
   already showed the shape: the old name survives as a *named refusal* that
   tells the reader what happened, which is better than either silence or a
   permanent alias.

The candidates, if anyone wants them later, are the array family (`nth`,
`take`, `first`, `last`, `len`, `sort`, `map`, `keep`, `reduce`, `shuffle`,
`transpose`) and the temporal one (`sample`, `debounce`, `throttle`,
`cooldown`, `window`, `delay`, `every`). Both are cohesive enough to name.
Neither is urgent, and neither is worth doing until a *collision* forces it —
a rename with no forcing function is churn wearing a tidy hat.

**The rule going forward, in one line:** a word that is a primitive of the
language keeps a bare name; a word that belongs to a family wears the family's
name and registers in the family's pack.

## Postscript: `using` gives the reader a lever the registry does not

*2026-09-08.* `using <tokens…> as :name` (§3.10) binds a fold of tokens, and
one of the things a fold can hold is an operator call:

```rill
using rbf through as :through
plane.coat | :through plane.flame | write plane.out
```

That is a **program-local abbreviation of a two-word family**, and it costs the
global operator table nothing: the fold lives in one file, wears a colon so it
can never collide with a word, and is gone before the graph exists. It is not
an answer to "the namespace is filling up" — the table is still 297 rows — but
it does answer the ergonomic half of the complaint, which is that a two-word
family is verbose at the point of use. A host tenant with fifteen row words
(spindrift) can now be abbreviated by the *program that uses them*, rather than
by the registry that owns them, which is the right place for a preference to
live.

It is also the reason D's second stated cost — "a two-word name cannot be a
`def`" — matters less than it did: a `def` cannot abbreviate a family, but a
fold can, and unlike a def it can stand in argument position.

## Postscript 2: the range spelling paid this document's rent

*2026-09-08, the parameter pack.* A def port grew an advisory range, and the
spelling that read best was `rate in 0..500`. It was **rejected on this
document's own argument**, one section up: reserving `in` for the whole
language to spell a range in one place is exactly the trade §C refuses —
*"Dotted operator names would give that up for the whole language to scope one
family."* A reserved word is a permanent narrowing of every name any host can
ever register, and rill's reserved list is short on purpose — `plane row slate
use using def export describe as also true false` — each entry earning its
place by being a statement keyword or a path head.

The shipped spelling is **contextual and reserves nothing**: `rate = 60
(0..500)`, where a `(` inside a def signature can only ever open a range. The
two words that DID join the list this beat — `export` and `describe` — are
statement keywords in the same sense `def` is, which is the bar. "It would read
nicely" is not.

## Postscript 3: the plane declaration paid it again, the same day

*2026-09-08, `def <name>(…) on row = …`.* A definition grew a declaration of
which evaluation plane it runs on, and the spelling problem was §C's a third
time: `on` reads best as a keyword and reserving it would narrow every name any
host can ever register, forever, to spell one thing in one position.

It reserves nothing. The parser looks for `on` at exactly one point — after the
signature's `)`, before the `=` — so `on` is still a legal operator name, a
legal stream name and a legal port name everywhere else, and a gate pins that
by registering an operator called `on` and piping into it. The two plane words
cost nothing either: `plane` and `row` were already on the reserved list, as
path heads, which is the bar this document keeps.

The prefix spelling `row def spin(x) = …` was cheaper still — no new position
to parse at all — and lost on COMPOSITION rather than on namespace: `export row
def` and `row export def` are two orders for one thing, and `export` had
already been ruled to sit at the statement head. The reserved list is unchanged
this beat: `plane row slate use using def export describe as also true false`.
