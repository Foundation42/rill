# CC brief: the write verb

Campaign note: `write-verbs-campaign.md` rev 3.1 (Chris + two Claude Chat
review rounds, 2026-08-29). Ruled by Chris the same day: **base verb =
`write`; the hold split, the glide bypass, per-statement levels, and the
`camera/pose/*`-only hold map all stand.** This brief is the buildable form —
what the code actually looks like, what the recon changed, each beat marked
as it lands.

The shape being built:

```
x | write plane.foo             replace, durable — exactly today's `set`
x | write plane.foo hold        the seat — retracts on unmount
x | write plane.foo add         a LEVEL into the sum lane (rests 0)
x | write plane.foo mul         product lane (rests 1)
x | write plane.foo stops       stops lane: × 2^clamp(s,−8,8) (rests 0)
    write plane.foo clear       withdraw MY contributions, all modes
```

```
base = held value (last (owner, stmt) in order) | else authored/stored
live = clamp_range( (base + Σadd) × Πmul × 2^clamp(Σstops, −8, 8) )
```

## What the recon changed

Seven findings, from reading both repos before writing this:

1. **`set` is a registry row, not parser magic** (`ops.zig:3440` —
   `.statics = {path}`, `evalSink` → `ctx.write`). So `write` is one new row
   whose mode is a **second static**: a compile-time word, which is exactly
   what makes mount-time acceptance walkable. The statics table needs a
   closed-word kind beside `.path` (the `step` bare-flag discipline, moved
   to static position).

2. **The mode cannot ride `DeltaKind`** — it is `enum(u2)` and all four
   slots are taken (value/occurrence/accumulate/membership). So the host
   vtable's `writeFn` **widens**: `(ctx, path, val, kind)` →
   `(ctx, path, val, kind, mode, stmt)`. Both repos are path-dependencies
   of each other's build; they move in one step, and every existing caller
   says `.base, 0` explicitly rather than defaulting — a write site that
   does not say its mode is the overload being evicted.

3. **Statement identity does not exist at the seam.** The host attributes
   writes to `current_caster_id`; the runtime knows the evaluating node but
   never says. The widened call carries the sink node's id — parse-order
   stable, which is all replay needs (an edited remount retracts and
   rebuilds everything anyway). Fold order = (owner, stmt), both
   deterministic.

4. **`IntentSum` IS the machinery, already built** (`intentWrite`:
   owner-sorted contributions, fold-at-write, aggregate published into the
   dyn entry). Generalized to tables keyed **(store path, mode)** with
   entries `(owner, stmt, value)`, it becomes the dynamic-path lane store —
   and because the aggregate is *published into the DynEntry*, every reader
   (`readDynamic`, `readPoseCommand`, camera intents) keeps working with
   **zero read-path changes**. Knob lanes keep their indexed fast path
   under `live_mutex` and grow per-mode columns.

5. **`hold` must carry BLOBS.** The first customer holds a pos record
   (`camera/pose/pos`). So: `hold` is whole-bytes replace (any shape);
   `add`/`mul`/`stops` stay scalar-only and refuse otherwise — the same
   split `decodeScalar` already draws for `mod/` writes today.

6. **The `Verb` log enum keeps `.set`.** `Verb = enum(u8) { set, reset }`
   is a replay-log discriminator, not a surface word. The console verb
   renames; the log format does not — old recordings stay replayable.
   Lane-mode writes are live-only and unlogged, exactly as program lane
   writes are today.

7. **A pleasant consequence, stated so it becomes a gate**: the glide keeps
   running on authored *underneath* a hold (the hold swaps the base after
   the ease, per the bypass ruling) — so **releasing a hold reveals the
   glided authored value, warm**, not a snap from wherever the hold stood.
   Seat handoff back to the person is smooth for free.

## The rulings (all Chris, 2026-08-29)

1. Base verb `write`; modes `hold add mul stops clear` — registry's own
   vocabulary, legal in argument position.
2. Hold split: bare `write` is durable and outlives its writer; every mode
   retracts on unmount.
3. Hold bypasses the glide; softness is spelled `| ease` by the author.
4. Additive contributions are per-statement LEVELS — *a level the
   statement maintains, not a delta per firing* (verbatim, load-bearing).
5. Hold acceptance: **grammar-legal everywhere, host-refused at mount
   outside `camera/pose/*`** — a seat wants a declared conflict story per
   namespace, and the second namespace will be begged for by its first
   customer.

Plus the seconded set (campaign note §6): mount-time acceptance refusals
naming the accepted modes · per-lane non-finite, loudly · `mod/` write
spelling deleted, read view grows per-mode aggregates · `clear` per
(writer, path) across all modes, the one valueless mode · range clamp after
the full fold · device paths: bare `write` queues a drive (the bridge's
replace), modes refused · honest migration, `set` retired from both mouths.

## Beats

### Beat 1 — rill: the verb (small)

- [x] `write` registry row: `.statics = {path, mode?}`, mode a closed-word
      static (`hold|add|mul|stops|clear`); `evalSink` grows mode+stmt
      plumbing; `clear` valueless (refuse a piped value loudly).
- [x] Vtable widen (`plane.zig` writeFn + `registry.zig` write_fn +
      `EvalCtx.write`): every caller states `.base, 0`.
- [x] `set` row deleted. The parse error for `set` **names `write`** — the
      README front-door lesson, pre-paid.
- [x] Migration sweep: 364 sink sites in tests.zig (mechanical), manual
      (69 refs), README (5), rill-for-agents, rillbook cells.
- [x] Gates: all six forms parse; mode words are a closed enum
      (`write knob 5 hold` binds 5 as value, `write knob 5 bogus` refuses
      at parse); `clear` refuses a value; `set` refuses naming `write`.
      Mutations: mode static dropped → red; enum opened → red.

### Beat 2 — engine: one lane machinery (the center of mass)

- [x] `Contribution {owner, stmt, value|bytes}` tables keyed (path, mode);
      `IntentSum` absorbed; `ADDITIVE_PATHS` + `isAdditivePath` deleted;
      `mod/` write branch in `writeThunk` deleted (its refusal text now
      names `write <path> add`).
- [x] Knob fold in `applyLanes`: per-mode lanes, combine order
      `(base + Σadd) × Πmul × 2^Σstops`, knob-range clamp after, per-lane
      non-finite ignore-loudly, hold base swapping in AFTER the glide
      (release reveals glided authored — recon §7).
- [x] Dynamic-path fold at write/retract, aggregate published into the
      DynEntry (readers untouched); hold-bytes stack, retraction reveals
      prior stored value or honest absence.
- [x] Retraction: `laneDropOwner`/`intentDropOwner` unify over (owner) for
      unmount and (owner, path) for `clear`.
- [x] Mount-time acceptance in the rills mount path: knob masks from the
      registry column, hold map = `camera/pose/*`, device paths modes-off,
      `live/` all-off (message updated — it still says `mod/`).
- [x] Gates: the **order-permute gate** (a target where the documented
      order differs numerically from every other; empty lanes watch
      nothing); level-not-delta (two writes from one statement in one tick
      = latest, not sum); statements sum across each other (the rail-v1
      resurrection test: an aim statement + a zero-writing mouse statement
      both stand); retract-on-unmount refolds; clear leaves entirely;
      per-lane NaN isolates; hold-release reveals warm glided authored;
      mount refusals name modes. Mutations for each, cross-repo where the
      claim spans the seam.

### Beat 3 — migration and the seat (visible)

*(Scope shrank at beat 2's landing: the machinery and its first customers
could not be separated without breaking the tree between commits, so the
rill rewrites — camera/follow thrust `add`, desat `add`, flash `stops`,
rail's pose `hold` — and the seat-hack deletion landed WITH beat 2. What
remains here is surface: console, probe, docs, refs.)*

- [x] `camera/pose/*` onto `hold`: rail.rill says `write … hold`, the
      bespoke `removeDynamicPrefix("camera/pose/")` unmount line and its
      stated edge are DELETED (the campaign's promised payoff).
- [x] Shipped rills rewritten (31 sites / 7 files): camera.rill thrust →
      `write … add` (composes with rail by construction), desat + flash
      lose their `mod.` spelling, rail/rider/follow mechanical.
- [ ] Console: Cmd row `set` → `write <path> [value] [mode]`; `clear` from
      the console mouth; `Verb.set` kept as the log discriminator; help +
      panel strings.
- [ ] `probe`'s `mod/` view: per-mode aggregates + contributor counts.
- [ ] The frozen-reference sweep: unmodulated frames bit-identical
      before/after the whole campaign (ReleaseFast refs run at the end).
- [ ] Docs: manual's write section, the kinship line (*`inc` changes the
      number; `write … add` leans on it*), ledger updates.

## Sizing honesty

Beat 1 small, beat 2 the real work (lane storage + fold + acceptance +
gates), beat 3 wide but mechanical. The one place to expect surprises is
the knob fast path under `live_mutex` — the lanes copy in `slew` is priced
against ~74 f32s and per-mode columns must not turn a quiet frame
expensive; the existing "empty lane costs nothing" invariant is the gate.

## Landed

**Beat 2 — 2026-08-29.** One lane machinery, live. `PathLanes` rows keyed by
path with per-mode columns — holds (whole bytes, a stack in (owner, stmt)
order), adds, muls, stops — folding at write into
`(base + Σadd) × Πmul × 2^clamp(Σstops, ±8)` and publishing the aggregate
into the DynEntry, so no reader changed. The base is captured when a path's
first lane arrives and is what retraction reveals; with no base, the entry
is removed — absence said, never invented. `IntentSum`, `ADDITIVE_PATHS`
and the `mod/` write branch are deleted; the acceptance walk refuses
unwelcome modes at MOUNT naming the accepted spelling, and program bare
writes on knobs refuse the same way — authored is the person's now, which
also emptied the log of per-frame program rows (the B-series tests flipped
their claims and kept their numbers). Knob lanes went per-statement in the
same stroke. The rill rewrites that could not be separated from the
machinery landed with it: thrust/torque say `add`, desat says `add`, flash
says `stops`, and rail's pose says `hold` — the bespoke camera-seat unmount
hack is DELETED, its gate now watching the retraction machinery it was
always meant to be.

Sixteen new-or-flipped gates; ten mutations, ten kills — one survivor on
the first pass (clear sparing holds; nothing asserted a hold-clear) fixed
by extending the gate, per discipline. Deferred, stated: knob masks admit
one mode each today, so multi-mode knob folds and the hold-on-knob
glide-bypass (recon §7's warm release) have no live customer — the
machinery exists on the dynamic side where multi-mode is real, and the
knob side joins when a mask first widens.

**Beat 1 — 2026-08-29.** The verb is real end to end: `write` with five flag
statics (rill `ops.zig`), the vtable widened with (mode, stmt) through
runtime queue, mock, C ABI (which REFUSES non-base rather than dropping it),
and both matryoshka hosts (`writeThunk`, `oneShotWrite`) — non-base modes
refuse loudly there until beat 2 wires the lanes. `set` is gone; the parse
refusal names `write`. The console FOLD emits `write plane.…` for both the
`set` and `write` surface spellings, so muscle memory keeps working while
every write that runs says what it is. Migrated: 365 rill-test sites, both
manuals + README + the idioms book (all gated by parseManual), 7 shipped
rills + 4 scenario fixtures + inline sources in matryoshka, and the G2
canonical-dump hash (structural move, op name rides the dump — recorded at
the hash). Seven new gates, six mutations, six kills (the seventh gate,
mode-word closure, is killed by the same mode-scan mutation). Two findings:
`notify` shares `evalSink` with one static — found by an index panic, now a
guarded and gated case; and a standalone `clear` has no rousing (nothing
fresh, the node never evaluates), so clear is pipe-roused in programs and
the console's valueless form is beat 3's Cmd-row concern, as §3.1 hints.
