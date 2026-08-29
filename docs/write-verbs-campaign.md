# The write verb: intent at the call site

Campaign note, REVISION 3 — Chris's idea 2026-08-29, drafted by CC, reviewed
by Claude Chat, revised again on Chris's grep observation the same day. §5 is
the short list that needs Chris's voice; §6 is proposed-and-seconded,
proceeding unless overruled; §7 is the ledger of rejects.

Changed in revision 3 (Chris): **one base verb, mode as a modifier.** The
distinct-verbs form (rev 2) lost the one thing `set` had always given for
free — a single greppable token finding every mutation site. Unified under
`write` with a trailing mode word, both greps exist (`write plane` = every
mutation; `write .* hold` = every seat) — and as a bonus the naming problem
largely dissolves: mode words live in *argument* position, which does not
collide with the operator table, so `add`, `mul` and `stops` return to being
their own obvious names. Rev 2's six-verb table is now a §7 reject.

Changed in revision 2 (review round): the **hold split** — blend mode and
lifetime are orthogonal; durable replace keeps its old meaning from every
mouth and the seat's retraction is in its own word. Additive contributions
pinned as per-statement LEVELS. Rulings added for clamp placement, glide
interaction, per-lane non-finite, mount-time acceptance, the `mod/` write
spelling, console retraction, and the order-permute gate.

---

## 1. The itch

rill programs mutate the engine through one verb, `set`. What `set` actually
*does* depends on what the target path turns out to be:

| target | what `set` means there |
|---|---|
| a routed knob, from the console | write the **authored** value (the person's number) |
| a routed knob, from a program | contribute to the knob's **modulation lane**, in a blend mode the *registry* chose (`add`, `mul`, or `stops` — one per knob, fixed at compile time) |
| one of a hardcoded list of "additive intent" paths (`camera/thrust/*`, `camera/torque/*`) | join a **sum** across programs, keyed by program id |
| an input control (`input/kbd/w`) | queue a **drive** on the device bridge |
| anything else in the dynamic namespace | **replace** the stored value |

Five semantics, one spelling. The writer's intent is invisible at the write
site; you have to know the path's class — and in the lane case, go read a
registry column — to know what your own line does. This is precisely the
"rule you cannot see at the call site" shape this codebase keeps evicting
elsewhere.

Chris's framing (2026-08-29): the system is not Bitwig. Bitwig-style
modulators orbit an authored value and never own it — that's our lanes, and
lanes are *right* for modulation. But **it is perfectly fine to set
something, if that is what you want. It's a matter of intent.**

**The ruling being proposed: the blend mode moves to the call site.** The
program says what it means, in one verb whose modifier carries the mode —
and the *lifetime* of what it said rides the modifier too.

A named design goal, from the same conversation: **mutation call sites stay
findable with one grep.** `set` always gave that for free; the design must
not lose it.

## 2. One week's evidence

Three real bites from the current campaign week, each dissolved:

**The additive-path table.** `camera/thrust/*` summing across programs is a
hardcoded engine list (`ADDITIVE_PATHS`). Whether your write sums or
replaces depends on membership in a table you cannot see from the rill.
With the mode at the call site, "whoever writes additively joins a sum" —
the table stops existing.

**The replace-vs-sum surprise.** Intent sums are keyed by *program* id: two
programs writing torque compose, but two *statements* in one program share
an id, so the second silently replaces the first. rail.rill v1's mouse-look
line (writing zero with the button up) erased its own aim line this way.
Under per-statement levels (§3.4) that line becomes *correct behavior*.

**The camera seat hack.** rail.rill v2 needed to *own* the camera. There was
no way to say that, so it got a bespoke seam (`camera/pose/pos|look`) and a
bespoke unmount line that vacates it, with a stated edge (any unmount
vacates, even an unrelated program's). Under `hold` (§3.1) the lifecycle is
in the word and the special case is deleted.

The write taxonomy already quietly began: `set`, `inc` (accumulate delta),
and `cast` (field deposit) are three write forms with three semantics. This
campaign finishes the thought. The docs kinship line, per the review:
*`inc` changes the number; `write … add` leans on it.*

## 3. The design

### 3.1 One verb, five modes

```
x | write plane.foo             replace, durable — exactly today's `set`
x | write plane.foo hold        the seat: this value while I stand here —
                                retracts on unmount (a hold that persists
                                after you leave isn't a hold)
x | write plane.foo add         a LEVEL into the sum lane (rests at 0)
x | write plane.foo mul         fold into the product lane (rests at 1)
x | write plane.foo stops       stops lane: × 2^clamp(s, −8, +8) (rests at 0)
    write plane.foo clear       withdraw MY contribution, whatever its mode
```

- The path sits where `set` put it; the mode word is always last; bare
  `write` is the durable replace. Migration of the common case is a rename.
- Mode words are *arguments*, not operators — `| add plane.x` (arithmetic
  on a live reference) and `write plane.x add` coexist without collision.
  This is what lets the modes keep the registry's own names.
- All modulation modes (`hold`, `add`, `mul`, `stops`) retract on unmount;
  bare `write` is durable and outlives its writer, exactly as today.
- Greps: `write plane` — every mutation site; `write .* hold` — every
  seat; `write .* stops` — every exposure toucher. One grammar row instead
  of six verb rows.

The hold split (review round, seconded by CC, now a modifier): blend mode
and lifetime were bundled in the first draft's "program set = assign".
Split, the table is clean:

- console `write knob v` → authored (today's console set, renamed)
- program `write knob v` → **refused at mount, and the refusal names
  `hold`** (authored is the person's; authored-survives is non-negotiable)
- program `write knob v hold` → the assign lane (the camera seat,
  generalized)
- program `write path v` → durable replace (`draw/*` overlays keep
  working; no audit needed)
- program `write path v hold` → replace-with-retraction, for every site
  where outliving the writer *was* the bug

### 3.2 One machinery: everything is a lane

A target may carry **one lane per mode simultaneously**; the combine order
is fixed:

```
base  = held value (last holder in owner order)  |  else authored
live  = clamp_knob_range( (base + Σ adds) × Π muls × 2^clamp(Σ stops, −8, +8) )
```

- **`hold` replaces only the base.** Modulation rides on top: a kick still
  shakes a railed camera. The Bitwig story survives — a hold just swaps
  whose value the modulators orbit.
- **The knob's range clamp applies to the final live value**, after the
  whole fold.
- **`hold` bypasses the glide.** `live` is `glided ∘ lanes`; a held base
  does not ease in — "position assigned outright" was the entire point of
  the hard rail, and *easing is spellable in the language*: a program that
  wants a soft seat handoff writes `| ease 300ms` before its hold. The
  engine seam stays hard; softness is the author's sentence, not the
  engine's habit.
- **Non-finite is per-lane, loudly.** A NaN aggregate in the mul lane makes
  that lane its identity and says so; the other lanes still apply.
- Standing invariants carried over unchanged, load-bearing for replay and
  frozen-reference bit-identity: **owner-order folds** (never allocation
  address), **main-thread lanes, debug-asserted**, empty lanes cost
  nothing, an unmodulated frame is bit-identical.

### 3.3 Acceptance is a mount-time contract

The registry's `modulation` column becomes a **mask of accepted modes**. A
write in an unaccepted mode is refused **at mount**, naming the accepted
modes — write targets are static paths and the mode word is static, so the
wire gate walks this the way it walks types; nothing refuses at runtime.
Default mask: today's column maps to "accepts exactly that mode"; `hold`
accepted nowhere until ruled per-namespace (`camera/pose/*` migrates
first).

### 3.4 Additive contributions are per-statement LEVELS

Keyed per **statement**, and a contribution is **a level the statement
maintains, not a delta per firing** — latest value per statement wins,
statements sum across each other. Both halves matter: level semantics is
what makes rail-v1's mouse-look line (writing 0 with the button up)
*correct* rather than hazardous, keeps `write … add` cleanly distinct from
`inc`, and matches the cross-tick coalesce ruling on casts. Without that
sentence someone implements per-firing accumulation and the bug returns in
a new costume.

Statement identity = index within the file: stable for replay (replay
re-derives from identical text), and an edited remount rebuilds all
contributions anyway since they retract at unmount. Fold order becomes
(owner order, then statement order), both deterministic.

### 3.5 The `mod/` write spelling is deleted; the read view grows

The mode word now carries what the `mod/<knob>` *write* seam carried, so
that spelling is the evicted overload reborn — deleted in the migration
pass. The `mod/` *read* view stays and grows: `probe` shows per-mode
aggregates and contributor counts. Three views unchanged as a read
contract: bare = authored, `mod/` = the lanes, `live/` = what the frame
used.

### 3.6 The console speaks the same verb

One vocabulary, two mouths. Console `write knob v` writes authored (the
console is the person — under the hold split that is not a special case, it
is just what bare `write` means on a knob from the mouth that owns
authored). Console modulation modes contribute under the console's own id;
the person withdraws with `clear`, which exists precisely so nobody needs
to know a mode's identity value to leave a lane. Console `hold` is legal
and released by `clear` — useful for pinning a value while investigating.
`set` retires from both mouths in the same honest-migration pass; keeping
it as an alias would be two spellings for one act.

## 4. What this is not

- Not a change to reads, probe's reply shape, replay format, or the
  three-views read contract.
- Not a scheduling change: drain, slew, and publish points stay put.
- Not Bitwig: modulators stay modulators. This adds the owner's mode beside
  them and makes every write say which it is.

## 5. Open rulings — what needs Chris's voice

1. **The base verb's name**: `write` (CC's pick — neutral about *how*,
   where `set` carries replace-flavour and `set … add` reads as a
   contradiction; `mutate` is a biology lecture) — or `mutate`, or another
   word. Mode words proposed: `hold`, `add`, `mul`, `stops`, `clear` — the
   registry's own vocabulary, available now that they sit in argument
   position. (`stops` as a trailing word reads fine: "write exposure,
   stops"; the verb-position objection from rev 2 no longer applies.)
2. **Confirm the hold split** (§3.1) — argued by the review, seconded by
   CC, but it is a shape change from the idea as first spoken.
3. **Confirm `hold` bypasses the glide** (§3.2) — CC's recommendation; the
   alternative is per-mode easing in the engine.
4. **Confirm per-statement levels** (§3.4) — changes within-file
   composition from "composing is the author's job" to "every statement is
   a contributor".
5. **`hold` acceptance map** — which namespaces admit a seat first.
   Proposed: `camera/pose/*` (migrating the bespoke seam), nothing else
   until asked for.

## 6. Proposed and seconded — proceeding unless overruled

Mount-time acceptance refusals (§3.3) · per-lane non-finite (§3.2) · the
`mod/` write deletion (§3.5) · `clear` and console vocabulary (§3.6) ·
range clamp after the full fold (§3.2) · honest migration, no compat
shims: every `set` becomes `write` (mechanical), camera.rill thrust →
`write … add`, rail.rill pose → `write … hold` (its bespoke unmount line
deleted), `ADDITIVE_PATHS` deleted, `draw/*` untouched · `inc`/`cast` stay
as they are, kinship documented.

## 7. Ledger of rejects

- **Six distinct verbs** (rev 2's shape) — lost `set`'s free property, one
  grep finding every mutation site, and forced a naming bikeshed by
  claiming six operator-namespace words. The base-verb-plus-modifier form
  keeps both greps and returns the modes to their obvious names (Chris,
  2026-08-29).
- `add`/`mul` as *verb* names — operator collision. (As mode *words* in
  argument position they are fine, which is half the reason rev 3 exists.)
- One verb carrying both assign-blend and retract-lifetime — orthogonal
  axes; bundling recreated the two-mouths overload and forced a compat
  audit of every durable write (review round).
- Per-firing additive accumulation — resurrects the replace-vs-sum bug in
  a new costume; levels or nothing.
- Whole-read non-finite fallback — larger blast radius than per-lane, and
  punishes three well-behaved lanes for one rogue writer.
- Runtime acceptance refusals — mount-time is house style and statically
  checkable here.
- Keeping `set` as an alias of `write` — two spellings for one act.

## 8. Sizing sketch (orientation, not ruling)

- **rill repo:** ONE grammar row (`write <path> [mode]`, mode an enum word
  like `shape`'s curves), mount-time acceptance in the wire gate, refusal
  messages, the `set` → `write` migration. Small.
- **engine:** lane storage keyed (target, mode); intent-sum machinery
  merges into it; `laneDropOwner` retraction extends to `hold` and
  per-statement keys; `camera/pose/*` migrates onto the seat. Medium — the
  campaign's center of mass.
- **gates:** every ruling paid in the usual coin, and specifically an
  **order-permute gate**: construct a target where
  `(base + Σ) × Π × 2^s` differs numerically from other orderings and
  assert the documented one. A gate that passes because the lanes are
  empty is watching nothing. Plus the standing frozen-reference sweep.

---

*Fate of the note: becomes a CC brief once §5 is ruled; the brief tracks
what lands.*
