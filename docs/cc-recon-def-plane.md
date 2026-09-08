# Recon — should a definition declare the plane it runs on?

*Asked 2026-09-08, alongside the `@self` beat and deliberately separate from
it. No implementation: the recon is the deliverable, and the owner rules
before anything is built.*

**Status:** recon only. Seven measurements, four options weighed, one
recommendation with the strongest argument against it at §9. Two spellings
were pre-ruled-out before the recon started and are recorded at §10 rather
than re-proposed. Five open questions for the owner at §13.

---

## 0. The question, framed as a language question

> Should a definition declare the plane it runs on, rather than the host
> deciding for a whole file?

rill has two evaluation planes. One is the world — a store of paths, a dirty
set, one value per path per tick. The other is a **row plane**: the same
grammar evaluated once per row of a population, with an integer-only kernel
column (`src/row.zig`). A program is mounted on one or the other.

The framing matters. This is not "should rill know about particle systems".
It is: **a language with more than one evaluation plane has to say somewhere
which plane a piece of code is for, and rill currently says it in the least
visible place available — a boolean argument passed by the caller.**

---

## 1. What is measured

### 1.1 Row-ness is a whole-program boolean, chosen outside the source

```
src/parser.zig:531   pub fn parse(gpa, reg, program_name, source, diag)        → parseWith(…, false)  (:538)
src/parser.zig:544   pub fn parseKernel(gpa, reg, program_name, source, diag)  → parseWith(…, true)   (:551)
src/parser.zig:554   fn parseWith(gpa, reg, program_name, source, diag, rows: bool)
src/parser.zig:560     the parameter
src/parser.zig:571     `.rows = rows` — copied once, into the Parser
src/parser.zig:624     `rows: bool = false` — the field, on **Parser**
```

Re-exported unchanged at `src/rill.zig:68` and `:69`. There is no third entry
point. `parseKernel`'s own doc comment (`src/parser.zig:541`) states the
entire difference: *"Same grammar, one difference: row words bind."*

### 1.2 It is read in exactly two places

```
src/parser.zig:1621  if (self.rows) — the `$chan at <pos>` desugar. In a kernel,
                     `$wind at row.pos` rewrites to the host word `hear` (:1628);
                     a missing `hear` registration refuses at :1626. It also swaps
                     the WORDING of the bare-`$chan` refusal: kernel spelling at
                     :1632, plane spelling at :1634.
src/parser.zig:2150  if (def.row.only and !self.rows) — "'{s}' is a row word — it
                     means something on a spray, not on the plane; mount it in a
                     kernel".
```

Two reads, one field, one caller decision. Both sites **already hold a
`*Target`** (`parseExpr` and `parseOpcallCarrying` each take one), which is
the single most important fact in this document for Option A's cost.

`Target` is `src/parser.zig:481` and carries `nodes`, `slots`, `names`,
`template` — **no plane**. `Template` (`:454`) carries none either. So there
is today no per-definition place to hang one, and no representation for "the
program's own plane" distinct from the parser's.

### 1.3 The flag is not recorded anywhere afterwards

`graph.Program` (`src/graph.zig:160`) carries nodes, slots, names, subs,
writes, casts, warnings, exports, result and downstream. **It does not carry
the plane it was parsed for.** A host handed a `Program` cannot ask which one
it is; it can only *infer*, by scanning `prog.subs` for the `row.` prefix —
which is exactly what `src/row.zig:501` does at mount.

The dump carries nothing either (`src/serialize.zig:37` is `fmt_version`,
`:45` is `dump`; the word "row" does not occur in the file).

The C ABI is narrower still: `src/c_api.zig:120` exports `rill_parse`, which
calls `rill.parse` at `:129`. **There is no `rill_parse_kernel`.** A host on
the seam cannot parse a row program at all — and matryoshka's dormant shim
(`matryoshka/src/rill_seam_impl.zig:46`, `:190`) has no kernel wrapper for the
same reason.

### 1.4 The parse-time check is NOT a courtesy — it is the only thing that catches this

This is the fact that a first draft of this recon got wrong, and it is
decisive.

`row.Row` is `src/row.zig:117`. `only` (`:128`) is what the parser reads;
`legal()` (`:132`, `eval != null and exact`) is what
`row.Runtime.mount` enforces (`src/row.zig:420`, the refusal at `:468`),
together with the write-target rules (`:1017`, `:1022`).

But that mount check runs in the **row** direction only: it refuses a
plane-only op inside a kernel. The other direction — a **row word in a plane
program** — has no mount-time answer at all, and the ledger records the
attempt that proved it (`docs/implementation-notes.md`, the row-plane entry):

> *"A row word refuses at PARSE in a plane program. The first draft used
> `fails_mount` on the word and it leaked: `fails_mount` fires only if the
> node evaluates at tick 0, and `plane.x | gravity` with an unfed `plane.x`
> never evaluates — it mounted cleanly (found by spindrift's G2, which
> asserted the refusal). `parseKernel` is `parse` with `rows` set; the op-bind
> site refuses `row.only` words when it is not. Structural: the parser is the
> one place that knows what kind of program it reads."*

The runtime fallback is `planeRefuse` (`spindrift/src/words.zig:36`) — a
truthful evaluator nothing should reach. It is a *runtime* refusal, so a node
that never fires never refuses. **`parseKernel` exists because the mount leaks
here.** Any option that weakens the parse-time stage re-opens a bug that has
already been found once, by a gate, in a sibling repo.

### 1.5 The flag governs WORDS, not paths — and the asymmetry is already gated

`isPathHead` (`src/parser.zig:1762`) accepts `plane`, `row` and `slate`
unconditionally, whatever the flag says. `src/tests.zig:10874` pins the
consequence deliberately: a plain `rill.parse` of
`"row.vel | mul 2 | write row.pos"` **succeeds**, yielding one sub on
`row.vel` and one write to `row.pos`. The plane runtime then subscribes those
paths where nobody serves them, and reads return `error.NotFound` and are
skipped (`src/eval.zig:226`).

So today's answer to "what plane is this for" is enforced for host *words* and
not for row *paths*. That is a coherent position — the ledger states it, *"a
`row.…` path in a program mounted on the world plane is a path nobody serves —
loud at the same place a mistyped knob path is"* — but it means the flag is
half a type check, and any option here inherits that shape.

### 1.6 `row.only` has no core users, by gate

`grep "only = true"` across `rill/src/` finds it **only in `src/tests.zig`**
(`:10906`, `:10939`, both stubs), and `src/tests.zig:10854` *fails the suite*
if a core op ever declares it: *"'{s}' is core and declares row-only — core
words mean something on the plane"*.

Every real instance is a host word. spindrift has **15**, all through one
helper (`spindrift/src/words.zig:41`, `.{ .exact = true, .only = true, .eval =
k }`): `collide`, `ground`, `slide`, `stick`, `spawn`, `gravity`, `perish`,
`relax`, `near`, `push`, `align`, `sync`, `infect`, `deposit`, `hear`.
(`rill/CLAUDE.md`'s host-word list, dated 2026-09-02, names seven of them and
is stale.)

### 1.7 The corpus: 47 files, two clean halves, zero defs

| | count |
|---|---|
| `.rill` files under a `kernels/` directory — row programs | 21 |
| every other `.rill` file — plane programs | 26 |
| files that are ambiguous by content | 0 |
| files containing **any** `def`, `export def` or `describe` | **0** |

All 21 kernels name `row.` fields and/or row words; several also read
`plane.drift.@self.k.*` broadcasts, which is legal in a kernel today. Of the
26 plane files, exactly one matches `grep row\.` and it is a **comment** about
a document row (`matryoshka/demos/hud-lab/fold.rill:28`). rill itself ships no
`.rill` files.

Two conclusions that pull in opposite directions:

- **A reader genuinely cannot tell from the source.** The only signal is the
  directory, which is a convention of two hosts and not a fact about the
  language. `matryoshka/demos/particles/run.sh:54` says so out loud: the
  `kernels/` vs `rills/` split *is* the de-facto type system, and the console
  has two different verbs for the two cases (`rill mount <name> <file>` vs
  `drift spawn … kernel <stem>`).
- **Nothing is broken by that today.** The corpus is cleanly split and there
  is not one `def` in it. `def` has **zero file-level customers**, exactly as
  `use` had zero customers before the `using` beat deleted it. Whatever is
  ruled here is being ruled ahead of its first user.

---

## 2. What a def can and cannot do on each plane, measured

Run against the current tree:

| | result |
|---|---|
| `def dbl(x) = x \| mul 2` in a kernel, called from a row statement | **parses**, flattens to 2 nodes |
| a `row.…` path inside a def body, either plane | refused — close-over-nothing |
| an absolute `plane.…` path inside a def body, either plane | refused — close-over-nothing |
| a `@self` broadcast inside a def body, in a kernel | **parses** (the `@self` beat, same day) |
| a `using`-fold of `row.age`, spliced in a kernel | **works** |

And read from the code rather than run: a **row word** inside a def body in a
kernel binds, because `src/parser.zig:2150` reads `self.rows`, which is set
once for the whole parse and cannot tell a def body from a top-level
statement.

So the shape is odd. A def in a kernel today may call row words and read
`@self` broadcasts, but may not touch a single `row.…` field — which is most
of what a kernel does. **A row def is currently a def that cannot reach the
row.** That is not the plane granularity's doing; it is the close-over rule,
and §8 returns to it.

Note the last line: `using` is **already** a plane-agnostic definition
mechanism. A fold is tokens, re-parsed at each splice under whatever rules
hold there, so one fold works on both planes with no declaration at all.

---

## 3. Option A — a definition declares its plane

### The spelling

Read aloud:

- **`def spin(x) on row = …`** — the plane between the signature and the `=`.
  **Recommended if this option is taken.** Contextual: the parser is at a
  known point (after `)`, before `=`), so `on` reserves nothing globally —
  the same trade the parameter pack took for `(0..500)`, and the trade
  `namespaces.md` §C's argument refuses for a globally reserved `in`.
- **`row def spin(x) = …`** — a prefix like `export`. Costs no new reserved
  word at all (`row` is already reserved, `src/registry.zig:550`), which is
  cheaper. It loses on **composition**: `export row def` and `row export def`
  are two orders for one thing, and the parameter-pack beat already had to
  rule that `export` sits at the statement head.
- **`def row.spin(x) = …`** — rejected. `namespaces.md` §C refuses dotted
  operator names outright, and this is one.
- **`def spin(x): row = …`** — rejected. The colon has four meanings already,
  the `using` beat's adjacency rule exists to keep them apart, and the
  port-type colon lives inside those very parens.

### What it costs in the parser

Smaller than it looks:

1. `rows` moves from `Parser` (`:624`) to `Target` (`:481`). Both readers
   already hold a `*Target`: a rename plus one field.
2. `parseDef` reads an optional plane after the signature and sets it on the
   template's `Target`; the program's own `Target` (`src/parser.zig:572`) is
   seeded from the caller's flag, unchanged.
3. `Template` grows a plane; `instantiate` refuses a cross-plane call by name.
4. `parseWith`'s `rows` parameter stays exactly as it is and stops meaning
   "the file's plane". It comes to mean **"the plane of the TOP-LEVEL
   statements"** — a smaller and more honest claim, and the reason this option
   can be taken without touching a single existing caller.

### What breaks

Nothing in the corpus, because no `.rill` file has a def (§1.7). Every
existing call site keeps working: a file whose defs declare nothing behaves
exactly as today.

### The default — the one real decision inside this option

- **(i) Inherit the caller's flag.** Zero churn, but it re-imports the ambient
  decision the option exists to remove: an undeclared def is still whatever
  the host said.
- **(ii) Default to the world plane; a row def must say so.** Loud, no
  ambiguity, nothing in the corpus to break. Costs one line in every future
  kernel that grows a helper.
- **(iii) Undeclared means plane-AGNOSTIC**, resolved where it is spliced.
  The most rill-ish reading — a def is flattened into the caller's graph, so
  why should it have an opinion? — and **not implementable as a template**,
  because both `rows` reads happen while the BODY is parsed and a body is
  parsed once. A def would have to keep its tokens and re-parse per splice.
  That is `using`. (iii) already exists, spelled differently; building it into
  `def` would be building a second one.

Recommendation inside the option: **(ii)**, with (iii) named in the manual as
"that is what a fold is for".

### Gates it would need

- a `row`-declared def parses in a program parsed with `rows = false`, and its
  row words bind;
- the same def called from a plane statement is refused, naming both planes;
- a plane-declared def in a kernel file parses and its row words do NOT bind;
- an undeclared def is a plane def — the default, gated as the ruling;
- `export def … on row` composes, pack intact;
- a def calling a def of the other plane is refused at the call site;
- `parseWith`'s flag governs top-level statements only: one file, a row
  program at top level and a plane def, both parsing;
- **and the negative control**: spindrift's three existing refusals
  (`spindrift/src/tests.zig:526–529`) stay green — a row word in a bare
  `rill.parse` program still refuses, which default (ii) preserves exactly.

---

## 4. Option B — infer the plane from usage

*A def that touches `row.…`, or calls a `row.only` op, is a row def.*

"Loud, never a guess" says this loses. The concrete reasons are stronger than
the maxim:

1. **It cannot be done in one pass, and rill is one pass.** The `$chan`
   desugar (`src/parser.zig:1621`) fires *at the moment the token is parsed* —
   `$wind at row.pos` either becomes a `hear` node or becomes a refusal, right
   there, and the three possible messages (`:1626`, `:1632`, `:1634`) are
   asserted verbatim by tests (`src/tests.zig:10920`, `:10947`, `:10951`).
   Inference needs the rest of the body, which has not been read yet. Either
   the parser gains a pre-scan or defs gain deferred parsing; both cost more
   than Option A entire.
2. **Most defs give it nothing to infer from.** `def dbl(x) = x | mul 2`
   touches no row path and calls no row word. Inference must fall back on a
   default for the common case — Option A's default question with the
   declaration removed: the hard part kept, the easy part lost.
3. **An unrelated edit silently changes a def's plane.** Delete the last
   `row.age` read while refactoring and the def becomes a plane def; the error
   surfaces at a call site or at a mount, in another file, far from the edit.
   That is the failure shape the inverted-threshold entry named — *a gate that
   watches the operator is not watching the row* — one level up.
4. **There is nowhere to put the refusal.** A wrong inference produces a
   *working* parse of the wrong thing. A rule with no place to be loud is the
   mechanical form of a guess.

Rejected, on 1 and 3.

---

## 5. Option C — the status quo

Keep the caller's flag; a file stays single-plane.

**Genuinely lost:**

- A `.rill` file cannot say what it is; a reader, human or agent, must know
  the host's directory convention.
- A one-file package is impossible: a parameter pack, its `describe` block, a
  per-instance driver and a row program cannot coexist, because the file has
  one plane and the driver and the program want different ones.
- A host on the C ABI cannot mount a row program at all
  (`src/c_api.zig:120`), so the seam quietly has half the language.
- `Program` carries no plane (`src/graph.zig:160`), so nothing downstream — a
  dump, a tool, a supervisor rill — can ask what it was parsed as. Mounting a
  `parse`d program on a row plane is a silent category error that surfaces
  only as a pile of per-node refusals.

**Genuinely kept, and more than it first looks:**

- One concept, one flag, two readers.
- Zero churn across two hosts and 47 files.
- No new way for a file to be wrong — see §6, which is a long list.

**This is a defensible answer** and the recon says so plainly. If the one-file
package is not being built, the flag costs nothing today.

---

## 6. What a mixed file would break, if one were allowed

Not an option, a **cost sheet** — every one of these assumes today that a
`Program` has exactly one plane.

- **Defs flatten away.** `publishExports` (`src/parser.zig:833`) and the
  parser header both state it: the graph does not know defs exist. A row def
  inlined into a plane program's node list yields a `Program` that is
  *neither*, with row-only nodes the plane runtime will happily try to
  evaluate — reaching `planeRefuse`, which is a **runtime** refusal, which is
  exactly the leak `parseKernel` was invented to plug (§1.4). **This is the
  hazard that makes a mixed file a language question rather than a plumbing
  one.**
- **`row.Runtime.mount` walks every node** (`src/row.zig:465`) and refuses the
  first non-row-legal one by name (`:468`) — a message spindrift asserts
  (`spindrift/src/tests.zig:590`). Its subscription split (`:501`) classifies
  every non-`row.` sub as a host-fed broadcast, which is how kernels read
  their knobs — so a mixed file's genuine plane subscriptions would be
  silently reinterpreted.
- **The spray's own per-node walks** assume the whole program is the kernel:
  the `hear` channel check (`spindrift/src/spray.zig:812`), the `.k.`
  knob-room check over `prog.subs` (`:836`), the `near`/single-`deposit` check
  (`:856`). In a mixed file the knob-room refusal at `:851` would fire on a
  plane statement.
- **One cycle analysis, two halves.** `findCycle` (`src/graph.zig:381`) runs
  once over the whole program and exempts `row.` writes (`:393`) on the
  argument that heads cannot overlap — which survives a mixed file. But a row
  def's flattened writes land in the same `prog.writes`, so the plane half's
  cycle report could name a node the author cannot see.
- **Two audits become statements about the wrong thing.**
  `src/tests.zig:10854` (core may never be `row.only`) and
  `spindrift/src/words.zig:737` + `spindrift/src/tests.zig:511` (every
  spindrift word must be `row.only`) both treat row-ness as a property of the
  op alone. Per-definition planes make it a property of op × scope.
- **The hosts have no verb for it.** matryoshka resolves a kernel by file stem
  under `kernels/` (`matryoshka/src/spray_bridge.zig:1135`) and a plane
  program by path (`matryoshka/src/control/rills.zig:621`), with two different
  console verbs. A file holding both has no home in that layout.
- **Hot reload replays the whole file.** Everything funnels through
  `mountFromSourceProv` (`matryoshka/src/control/rills.zig:704`, parse at
  `:724`) and the log stores the original text with no plane annotation.

Option A as recommended does **not** create a mixed *graph* — a row def that
is never instantiated contributes no nodes, and one instantiated from a row
statement contributes row nodes to a row program. But it does create a mixed
*file*, and the second item above is the one that has to be answered before it
ships: **what happens when a plane statement calls a row def?** The answer has
to be a parse refusal at the call site, not a runtime one.

---

## 7. Option D — two smaller things found on the way

Neither is an alternative to A; both are separable and cheap.

### D1 — record the plane on the `Program`

One field. `parseWith` already knows it and throws it away (§1.3). It changes
no granularity and settles no language question, but it removes the
downstream half of the complaint: a host, a dump reader or a tool could ask a
`Program` what it was parsed as instead of remembering. It gives
`row.Runtime.mount` a receipt to check before it starts refusing nodes one at
a time. And matryoshka already has the right home for the question —
`matryoshka/src/rill_api.zig` is a deliberately coarse question API over
`Program` (`subCount`, `writeCount`, `nodeName`, `selfSubscription`) whose own
doc states the rule: *"rill hands over what a program declares, and the host
decides what those declarations mean."*

The open question that stops it being free: **does it serialize?** The
`exports` precedent says no — a dump is of a mounted graph. But the plane is a
property of the mount, which argues the other way. Serializing it bumps
`fmt_version` (`src/serialize.zig:37`) and moves G2's frozen hash
(`src/tests.zig:632`); not serializing it costs nothing. Wants a ruling.

### D2 — a file-level plane statement

`plane row` as a file's first statement: the file states what the caller
already passed, and disagreement is a loud refusal rather than a silent
override. Tiny, and it makes a file self-describing — but it does **not**
deliver the one-file package, because it is still one plane per file. Worth
having only if Option A is refused and the readability complaint is still
felt.

---

## 8. What the last three beats make easier, and one thing they make harder

**`using` / folds make it easier — and partly redundant.** A fold is a
plane-agnostic definition that already works (§2). Any design here has to
answer "why not a fold?", and the answer is real but narrow: a fold has no
signature, no types, no defaults, no ranges, no `describe` block, and does not
appear on `Program.exports`. **A fold is a definition without a pack.** So the
question this recon really asks is narrower than it looked: *should the
PACKAGED definition be able to say what a fold says by construction?*

**The parameter pack makes it easier.** `export def` + `describe` +
`Program.exports` is the surface a one-file package needs, and it exists. The
plane declaration is the last missing piece of the motivation at §10 — and the
pack also supplies the precedent for the recommended spelling: `(0..500)` is
contextual and reserves nothing.

**Effect pass-through makes it easier**, and the `@self` rule from the same
day makes it much easier: a def may now end in a `write` and may name its own
instance's knob, so "a def that drives something" is a shape the language
already has. Before both, the driver half of a package was unsayable.

**What makes it harder: the close-over rule, from the other side.** §2's
finding is the sharp one. A row def cannot touch `row.…` — so if Option A
ships without touching the close-over rule, a `row`-declared def can call
`gravity` and read `@self` broadcasts and still not read `row.age`. **Option A
is worth much less than it looks unless the close-over question is ruled at
the same time**, and that ruling is genuinely open:

- `row.…` inside a def body is *not* the portability hazard the close-over
  rule was written for. `row.pos` is relative by construction — *whichever row
  is being swept* — in exactly the sense `@self` is relative. On the reasoning
  the `@self` beat was ruled on, `row.…` in a **row-declared** def should be
  allowed.
- But it is only safe once the def HAS a declared plane. Today a def has none,
  so `row.age` in one would mean something at some call sites and nothing at
  others — which is why the `@self` beat left it refused and said so in the
  refusal's own words (*"`row` is the mount's own store"*, `checkDefReach`,
  `src/parser.zig:1835`).

The two rulings are coupled: **a per-def plane is what makes `row.…` in a def
body sayable**, and `row.…` in a def body is most of what makes a per-def
plane worth having.

---

## 9. Recommendation

**Take Option A, spelled `def <name>(…) on <plane> = …`, with an undeclared
def defaulting to the world plane — and rule the `row.…`-in-a-def-body
question in the same beat, allowing it inside a `row`-declared def.
Separately, take D1 without serialization.**

In order of weight:

1. **The granularity is wrong, not the feature.** rill's whole shape is that
   the source is the truth about the program — parse order is topological
   order, the text is the schedule. A plane chosen by the caller is the one
   fact about a program that is not in its text, and it is a fact a reader
   needs first.
2. **The parse-time stage is load-bearing, not cosmetic** (§1.4). It is the
   only thing standing between a row word and a plane program, and that was
   established by a leak found in a sibling repo's gate. Making it *finer*
   rather than removing it is therefore the conservative move, not the
   adventurous one.
3. **The cost is small and measured**: one field moves from `Parser` to
   `Target`, both readers already hold a `Target`, and the corpus contains
   zero defs to migrate.
4. **The caller's flag survives with an honest meaning** — the top-level's
   plane rather than the file's, which is Christian's model (*"top level rill
   just gets executed at import"*) expressed as a type rather than as a
   convention.
5. **It is the last piece of the one-file package**, and every other piece
   landed in the previous three beats.

### The strongest argument against my own recommendation

**In the one host that actually runs both planes, the flag is already dead
code — and Option A would bring it to life.**

matryoshka keeps **two registries**. The plane one
(`matryoshka/src/control/rills.zig:211`) is `rill.registerCore` and nothing
else; the spray bank's (`matryoshka/src/spray_bridge.zig:674`) adds
spindrift's words. So `src/parser.zig:2150` — the row-word refusal, half the
flag's whole purpose — **can never fire in matryoshka**, because the plane
registry contains no row word to refuse. The separation that works in the live
host is *registry partitioning*, not the flag.

A per-definition plane pushes the other way. One file with both kinds of
definition needs one registry with both word sets, which means merging those
two registries, which makes `parser.zig:2150` load-bearing in matryoshka for
the first time — and makes every core-vs-host name collision (`rill/CLAUDE.md`
already records `over` colliding once and stopping the build) a live risk
across a surface that has been safely partitioned until now. **The
recommendation trades a working separation for a declared one, and pays for it
in a place the recommendation does not touch.**

The honest counter-counter is that the partition is a host's private
arrangement and not a language guarantee: nothing stops the next host from
registering everything into one registry, and when it does, the flag is all
that is left. But the cost is real, it lands on the repo with the GPU sweep,
and it is not visible from inside rill.

**If the ruling is "not yet":** take D1 alone — one field, no language change,
no ABI change, no dump change — leave the flag where it is, and re-open this
when a second `.rill` file wants a `def` in it at all.

---

## 10. Two spellings already ruled out, recorded so they are not re-proposed

**Bare top-level statements as the row program.** Rejected by Christian before
this recon: it makes the plane a statement runs on depend on where it sits in
the file, which is inference, which "loud, never a guess" forbids. His model
instead: *"top level rill just gets executed at import"* — which is what a
mounted rill already means, and which §3 turns into `parseWith`'s flag
governing the top level and nothing else.

**A `kernel <name>` block.** Rejected: that is spindrift's vocabulary imported
into rill core. Christian: *"shouldn't the kernel be a def like everything
else? It's how it is used that's the difference... that's a different problem
to solve — in rill, not contaminated by spindrift requirements."* Option A is
that sentence taken literally: a kernel is a def, and what differs is a
declared plane rather than a new block.

---

## 11. Cross-repo blast radius, read-only

*(Every claim is a read of the sibling repos; nothing was changed there.)*

### rill

- `parse` / `parseKernel` (`src/parser.zig:531`, `:544`) keep their signatures
  under Option A. Nothing forces a break.
- `src/c_api.zig:120` exposes `rill_parse` only. Under Option A a file could
  carry row defs and still be parsed through the seam — a real gain — but the
  *top-level* plane would still be the world, so a seam host still could not
  mount a kernel without a new export. **A seam change is an ABI change and
  drags matryoshka's GPU sweep in** (`rill/CLAUDE.md`'s table). Option A does
  not require one and should not take one.
- The frozen G2 dump hash (`src/tests.zig:632`,
  `649b964914a83edadb22179128431479a14982183b5a7b2f4f89cf3cfd7a258e`, with its
  five-move history at `:590`) pins a *plane* program's bytes. Option A adds no
  node and no slot, so it does not move. **D1 moves it only if the plane is
  serialized**, which is D1's open question and the reason to answer it "no".
- The row-legal roster (`src/tests.zig:10805`) and its both-ways audit
  (`:10826`, including the core-may-not-be-row-only assertion at `:10854`)
  would need re-reading if `row.only` becomes scope-sensitive (§6).

### spindrift

- `src/spray.zig:798` `mountKernel` → `rill.parseKernel` at `:801`: the one
  place a kernel is parsed in anger. Unchanged by Option A.
- `src/run.zig:378` uses `rill.parse` for a plane rill; `:555` is the gate that
  the embedded `embers` is the shipped text.
- `src/words.zig:41` is the only real producer of `row.only` anywhere, and
  `:737` audits every word for it.
- **The tightest coupling to today's design** is `src/tests.zig:526–529`:
  three plane-parse refusals asserted by message (`plane.x | gravity`,
  `spawn`, `every 1s | also { perish }`). Option A must keep them green;
  default (ii) does.
- `zig build verify-dump` (`build.zig:76`) drives `drift-run` with a fixed
  argument vector and reads the population back with
  `tools/read_dump.py`, which pins `fmt == 4` (`src/dump.zig:22`). **The
  population dump carries no program and no row-ness**, so this gate is
  threatened only if a re-plumbing changed what `embers.rill` compiles to.
- `zig build row-legal` (`build.zig:64`) derives legality from registry fields
  and never reads `row.only`, so it survives unchanged.
- The `drift-words.md` parity gate (`src/tests.zig:552`, count at `:578`)
  trips on any word added or renamed.

### matryoshka

- Embeds rill as a **Zig module** (`build.zig:206`, `:363`, `:390`), with a
  seam-selecting shim (`src/rill_api.zig:37`) whose C path is not wired yet
  (`:39`, a `@compileError`).
- Parses **plane** programs directly (`src/control/rills.zig:724`,
  `src/control/commands.zig:3057`, `src/hud_applets_test.zig:165`) against a
  core-only registry (`src/control/rills.zig:211`).
- Mounts **row** programs only through spindrift
  (`src/spray_bridge.zig:1071`) against a second registry that adds the words
  (`:674`). **The two-registry split is the counter-argument at §9.**
- Embeds one row program as a Zig string: `EMBERS`, a verbatim copy of
  spindrift's `kernels/embers.rill` (`src/spray_bridge.zig:291`, with the
  reason at `:286` — `@embedFile` cannot cross the package boundary). Six
  ironwood plane programs are embedded the same way (`src/ironwood.zig:43`).
- **`src/casting.zig:2458` and `:2460` execute rill's own manuals as console
  scripts.** `consoleBlocks` (`:2435`) extracts ` ```console ` fences —
  *not* ` ```rill ` ones — and asserts the console accepts every line. So
  prose in `rill-manual.md` and `rill-for-agents.md` is a **matryoshka** gate
  as well as a rill one, and a keyword introduced in a `console` block there
  is parsed downstream. Anything this recon leads to that touches those two
  documents should check which fence it is writing into.
- No checked-in pixel goldens: the sweeps `cmp` two captures made in the same
  run (`demos/hud-lab/repro.sh`, `demos/camera-tilt/repro.sh`,
  `demos/input-camera/repro.sh`), so nothing on disk encodes today's kernel
  semantics.
- `demos/particles/run.sh:34` already mounts kernels by stem *and* plane rills
  by path in the same demo — a scene that spans both planes today, in two
  files.

### loam · struple · common

No `rill` dependency and no `@import("rill")` in any of the three. Outside the
radius entirely, except that struple reads dumps — so, again, only through
D1-with-serialization.

---

## 12. One correction to `rill/CLAUDE.md` found while measuring

The host-word list dated 2026-09-02 reads *"spindrift spawn · gravity ·
perish · hear · collide · ground · stick"* — seven words. There are **15**
(§1.6), and the list is what a reader greps before naming a core word. Not
changed by this recon (it is a note, not a deliverable), recorded so it is
changed on purpose.

---

## 13. Open questions the owner rules on

1. Option A, Option C, or D1-alone.
2. If A: the default for an undeclared def — (i) inherit, (ii) world, or
   (iii) agnostic-via-fold (§3). This recon recommends (ii).
3. If A: is `row.…` allowed inside a `row`-declared def body? (§8 argues yes,
   and that A is worth much less without it.)
4. D1: does the plane serialize into a dump? (`exports` says no; the plane is
   arguably a property of the mount, which says yes. §11 argues no, to keep
   G2's hash and struple's reader out of the radius.)
5. Whether a seam export for a row parse is wanted at all, given that it is an
   ABI change with a GPU sweep behind it.
