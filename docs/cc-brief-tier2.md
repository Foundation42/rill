# Brief for a fresh context — the rill tier-2 campaign

*For the Claude Code session that builds tier 2. You are starting cold.
Everything below is what the previous sessions learned the hard way;
read it before the code, then read `docs/rill-tier2.md` §7 before
anything else in that file. Chris is the verdict function: rulings are
his, gates are yours, and nothing lands without both.*

---

## 1. What you are walking into

**rill** is a small reactive dataflow language — a Zig library in this
repo, consumed by **Matryoshka** (a compute-only software ray tracer
whose console's native tongue is now rill). Programs are *mounted*, not
run: they sit on a plane of named values, subscribe, and re-evaluate on
change. Propagation is the only control flow. Two manuals
(`rill-manual.md` for people, `rill-for-agents.md` for agents) are
gated — every ```rill block in them is parsed by a test.

As of this brief: the casts/fields campaign is RATIFIED and built
(channels, ears, `cast … at … decay …`, `every`); the tags campaign
T1–T4 is landed and T5 (derived tags) is closing; rillbook v1 is live
in the web console. Tier 2 is the next campaign and it is yours.

**Tier 2** is the stock operator set a person needs so that *typical*
asks are one line. The founding example: breathing the exposure between
0.5 and 1.5 over four seconds took two programs, a seeded counter, and
seven lines of arithmetic. All correct; none acceptable. The target is
`lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure`.

## 2. Your first move

A **recon, not code** — the same shape the casts and tags campaigns
opened with: what exists vs what the doc assumes, a beat order with
gates, pins you propose, forks for Chris. The doc's §7 gives the beat
order; your recon confirms or argues it. Its first item is to *confirm*
(not reopen) the premise everything else sits on: **state inside an
operator is legal under spec §4.4** — the cycle ban is about state
through the plane. `window`, `debounce`, and `stats` already hold state.
Write that down as the foundation and build from it.

Check before the recon whether §7 item 1 already landed: the `lerp` port
flip (`t` piped) and `and or not`. If not, it's your first small commit.

## 3. Ratified — do not reopen

These are settled. Build to them; if one seems wrong in the code, say so
as a fork, don't route around it.

**Language**
- Port 0 is the rousing; a bound port is the payload; a change on a
  bound port alone is never a write (Max/MSP's hot/cold inlets).
- Sinks end waves. Side effects branch with `also { }`. A block is a
  fan-out, never a body; `{ }` is never a lambda.
- Bodies are sections `( )` — partial applications — and `def`s. The
  consumer fills a section's open ports positionally.
- Optionals are **keyword-only** (`radius 12 at … decay 4s`). A
  positional optional is refused by the registry.
- Comments are `//`. `#` is a sigil. Sigil on every surface.
- A field read always names its standpoint. A cast names where it
  deposits. Nothing has an implicit "here".
- Path-level cycle check stays (a program may not write and subscribe
  to one path, connected or not); the spelling is "split it".
- Time is fed, never read. Durations carry units. Replay is
  bit-identical.
- **Arrays are a value kind** (Chris's reversal — `window` already
  emits them). Literal `[a, b, c]` with commas, live like records,
  immutable, never a buffer. `[0, 2, 0]` does not coerce to a position.

**Tier-2 pins (all ratified by Chris; §6 of the doc)**
- `lfo` is sugar over `clock | wave`. Both exist.
- Registers (`ease`/`ramp`/`hold`/`diff`/`integrate`) tick per frame
  while converging and stop below ε; ε is a per-op default, not a knob.
- Noise is bit-identical **across machines**: integer hashing, f32 in a
  fixed order. Seed default 0; host-fed seed available as data. Perlin.
- `tally` does not survive remount (remount is restart).
- `along` clamps outside 0..1; Catmull-Rom default; tracks are a spine
  tenant sequenced with the D beat, not yours.
- `expect <shape>` asserts at **mount** and never falls back; `match
  <shape>` checks at runtime and refuses at mount only when a mismatch
  is provable. Shape literal `{id: string, distance: number}`, nested,
  `[number]`, `?` optional, open by default, `exact` closes.
- Broadcast (math over records and arrays) lands **with** the mismatch
  check: a kind or shape mismatch is loud with both sides named.
- `zip` with mismatched lengths refuses with both lengths named.

**Deliberately unsettled — yours to propose, with read-aloud reasoning**
- The words in doc §2.11 and §2.12 (`where` dispatched by kind or a new
  word; `zip` as transpose vs `transpose`). Shapes are ratified; names
  are not. Propose, don't decide silently.
- The budget: 43 words proposed against ~30. Mark each word's customer
  on the §4 list; words without one stay listed, not admitted. Cut
  candidates are named in §7.

## 4. The ledger — the discipline you inherit

Each of these was paid for. Most were paid for twice.

- **Prose approves plausible semantics; execution approves actual
  semantics.** A gate is an executed program, never a paragraph.
- **A mutation must bite.** `tools/mutcheck.sh` refuses to classify a
  mutant that didn't compile (a build error is a harness failure, not
  "0 failures"); a panicking test counts as a bite. A mutation that
  *survives and is right* — the check was dead code — is a finding:
  delete the code with the reason at the site.
- **An expectation is faithful to the implementation's arithmetic or it
  is not an expectation.** A float64 oracle for f32 code is prose in
  numeric clothing. For f32 gates, the oracle runs the same arithmetic
  in the same order, or the gate asserts a property. This bites tier 2
  directly: noise hashing, `reduce`, `stats`, `smooth`.
- **Structural, not discipline.** When a predicate over a registry
  turns out to be a coverage surface, the registry carries the answer
  as a field and the predicate is derived. Precedents: the wire gate
  (every console verb round-trips through the real wire parser), the
  test step depending on compiling the executable, mutcheck, routing.
  A new op you add needs its OpClass and its routing answer *at
  registration* — comptime-required, not remembered.
- **A refusal lands on the node that refused it**, in the ack, by name.
- **Loud, never a guess.** Unknown words error. Mismatches name both
  sides. Missing units error and name the fix.
- **Mount runs tick 0.** Everything a program touches in its first
  evaluation must exist before mount. `clock`/`lfo`/`noise` fire at
  mount; anything downstream of them re-evaluates every frame — that is
  the cost of animation and it must be visible (see §8 of the doc: the
  ticks-every-frame badge).
- **Unbounded state is a corpse.** Every register has a bound or a
  cutoff. `integrate` requires its clamp.
- **One write path.** Never a second mechanism for the same effect.
- **Read-aloud before naming.** Write the target line first, say it,
  name the operator from the sentence. Record the rejected names and
  why (the `pass`/`effect`/`tee` → `also` precedent).
- **Recorded-not-built** is a line in the doc, never a silent omission.
- **Docs ride the same commit as the code.** Operator table, the
  "Thinking in rill" rows, the wrong→right table, and the spec section
  all change in the commit that changes the language. Beat 2 retires
  the agent manual's "no array/vec literals" line.

## 5. Where to read

- `docs/rill-tier2.md` — §7 first (sequencing), then §1
  (admission rules), then the families. §4 is the simple-things list:
  your ergonomics gate. §5 is the method. §8 is what isn't language.
- `rill-spec.md` — §3.8 (sinks, port shape), §3.12 (temporal ops),
  §4.4 (cycles), the duration grammar.
- `rill-casts.md` — RATIFIED; the keyword-port pattern, the
  ownership/corpse rulings, the sampler doctrine.
- `rill-manual.md`, `rill-for-agents.md` — gated; the seven unlearns
  (#7 is a candidate awaiting a re-probe). Read the "Thinking in rill"
  section — your operators add rows to it.
- `docs/implementation-notes.md` — deviations, the DeltaKind arms, what
  the registry refuses.
- Matryoshka `ironwood.md` R6 "T-campaign rulings" — how the last
  campaign recorded rulings; copy the shape.
- `tools/mutcheck.sh`, the wire gate, the build graph — run them before
  you believe anything.

## 6. The beats and what "done" means

Per doc §7: recon → **beat 1** registers and time (`clock`, `frame`,
`lfo`/`wave`, `ease` with `up`/`down`, `ramp`, `hold`, `diff`,
`integrate`, `range`, `remap`, `shape`, math completions) → **beat 2**
arrays (literal, `nth`/`len`/`first`/`last`/`choose`/`take`, broadcast
with the mismatch check, `expect`/`match`) → **beat 3** over arrays and
records (`map`/`reduce`/`sort`/`take`, `without`/`zip`/`unzip`/`shuffle`,
`along` with inline knots) → **beat 4** noise, events, spatial.
Deferred to their own beats: tracks, `beat`, `walk`, `spring`, `smooth`,
`group by`.

A beat is done when:
1. its gates hold in Debug and ReleaseFast, mutations bitten and
   counted;
2. every new op has its **before/after pair** in the idioms book
   (rillbook), the after cell gated by parse, the mutation being
   deleting the op;
3. the §4 simple-things list is re-scored and the doc updated;
4. the manuals and spec changed in the same commit;
5. Matryoshka's suite is still green against the new boundary.

Beat 1 alone should turn the breathing exposure into one line. If it
doesn't, something in the beat is wrong.

## 7. Hazards specific to this campaign

- The `lerp` flip is a **breaking** change; sweep the corpus and gate
  the wrong→right row.
- `ease`/`ramp` re-arm per frame: they need the wheel, an ε cutoff, and
  a gate that watches them *stop*.
- `clock`/`frame` are "since mount", program-relative, replay-clean.
- Noise: no `sin`-based hashes, ever. Gate cross-machine identity by
  pinning expected f32 bit patterns, not values.
- Sections as bodies: `map (clamp 0 1)` fills one open port, `reduce
  (add)` fills two. Wrong arity is a mount-time refusal naming the op.
- `expect` after a path with no declared schema **refuses the mount**
  and says "use `match`". It never degrades.
- Broadcast without the mismatch check is a regression, not a feature.
  They land together or not at all.
- Don't drive-by into the tags/ironwood beats or into host verticals
  (that's a separate doc, not yet written). If tier 2 needs something
  from the host (tempo on the plane, tracks), record it as a
  dependency and defer the word.

## 8. How to report

The shape Chris reads: *rulings honoured first* (each one, as it
landed), then *the beat* (what was built, the gate counts, the
mutations), then *two things worth his eye* (findings, holes you found
by reading, anything you decided by mechanics that should have been a
ruling), then *the board* (what's next, forks stated as forks). Commit
hashes and test counts for both repos. Never bury a hole; say "T3
shipped a hole, and reading found it before a gate did" and what you did.

When you are unsure whether something is yours to decide, it isn't.
State it as a fork with your lean and why.
