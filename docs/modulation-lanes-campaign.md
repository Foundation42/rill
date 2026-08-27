# Campaign: Modulation lanes

**Date:** 2026-08-27
**From:** Christian (verdict) via Claude Chat
**Supersedes:** the hand-written bias paths from Keys on the Plane

## Why

Three things now exist that are the same mechanism written three times: `camera/roll` (a durable knob with a bias applied on the view axis), `camera/bias/*` (dynamic paths added on top of the pilot's intent), and `render/grade/bias/exposure` (a hand-written path, decode and apply site, in stops). The fourth instance — saturation, which Chris tried to drive the way the flash drives exposure — has no path at all. Each new one costs three hand-written pieces and repeats the lesson the exposure bias already paid for (a lane resting at the wrong identity turns the screen black).

The rule, ratified this morning: **a knob's read is its authored value combined with its modulation lane.** The registry declares how. This is the Bitwig model: base value, modulators that rest at identity, evaluated value computed at read. Last-writer-wins on a shared path goes away for everything that goes through a lane.

## The rulings

1. **One new registry column.** `.modulation = .none | .add | .mul | .stops`. `add` and `stops` rest at 0, `mul` at 1. `stops` is `add` in the log2 domain: `authored × 2^lane`. A knob without the column has no lane; a write to its lane path is refused loudly at mount, naming the knob.

2. **Only commuting ops.** No blend, no slerp, no clamp as a mode. A lane of `add`/`mul`/`stops` has no last writer, so two programs on one lane cannot race. Lerp-toward-target is an additive delta computed from the authored value (`target − base | mul w`), so it needs no mode of its own. Clamp is the knob's existing range, applied once after the lane. The registry refuses anything else at comptime — this is a structural rule, not an authoring convention.

3. **Lane entries are keyed by writer.** A lane is a bag of per-program contributions. A program's entry is its last write; its lifetime is the mount. Unmount removes the entry. A mounted program that stops writing is holding, exactly like any value path — there is no "stopped" state to distinguish from "writing zero". Envelopes rest at identity anyway, so a decayed kick holds nothing. The plane already stamps program writes with `source=.program`; the writer key is that stamp.

4. **The human never writes a lane.** Sliders, console `set`, chips, Projects and undo all touch the authored value only. Lanes live in the dynamic namespace, are never durable, and never appear in a cut. This is what makes the exposure-versus-slider fight unwritable rather than avoidable.

5. **Materialise once.** The lane is combined at the one place a knob's value is produced for the frame path — not per apply site. The frame path reads the modulated value and never sees the authored one. The three existing apply sites are deleted, not kept alongside.

6. **Empty lanes cost nothing.** Keep a set of knobs with a non-empty lane, maintained on lane write and on unmount. A knob not in the set reads its authored value with no dynamic lookup. Pre-register a threshold before measuring (the Aug 11 write-path discipline: run-to-run noise ±0.08 ms/frame; a threshold you'd be happy to lose).

## Path spelling (needs Chris's verdict before build)

Proposed: `mod/<knob path>`, so a program writes `set plane.mod.render.grade.exposure`. The `bias` sub-path goes away. Alternative: keep the knob path and let the plane route by writer (a program's `set plane.render.grade.exposure` lands in the lane, a human's lands in the authored value). The second is tidier to write and worse to read — a probe can't tell which you meant. Lean: `mod/`. Read-aloud both; record the rejected one.

## What rotates

| Today | After |
|---|---|
| `render/grade/bias/exposure` (hand path, decode, apply) | `exposure` gets `.modulation = .stops`; flash writes `mod/render/grade/exposure` |
| `camera/roll` knob driven per frame (durable store write + schema rebroadcast, the last one left) | tilt rill writes `mod/camera/roll`; the knob stays authored, the lane is dynamic. Closes that open item. |
| `camera/bias/{yaw,pitch}` applied by the host on the view | see open question 1 |
| `camera/thrust/*` | **unchanged** — thrust is intent read by the plant, not a modulation of a knob. Do not route it through a lane. |
| No saturation path | `saturation` gets `.modulation = .add`; Chris's original ask works as one line |

`shake.rill`, `camera.rill`, the flash line and the tilt demo all get respelled. The shipped-file mount gate catches a stale spelling.

## Gates

- **Identity.** Every routed knob with a lane, lane empty: frozen reference AE=0 across all 7 scenes. `x × 2^0` is `x`; `x + 0` is `x`; `x × 1` is `x`. This is the one that guards the black screen.
- **Composition on one lane.** Two programs write `add` to one lane; the read is the sum; unmount one and its contribution is gone while the other's is intact; remount it and it's back. Same for `stops`. This is the gate the disjoint-surfaces rule never had, because sharing was forbidden.
- **Authored survives.** Slider sets exposure to `v`; flash fires and decays; the read returns to `v` exactly, not to the flash's last value. The grade panel shows `v` throughout.
- **Rendered before/after.** `repro-input`'s third comparison generalised: for each modulation mode, the same eight frames with and without a lane program must differ. Saturation joins exposure here — a second wired knob, so the gate is watching the mechanism and not the one path.
- **Registry refusals.** A non-commuting mode refuses the build. A lane write to a knob with `.modulation = .none` is refused at mount, message names the knob and says how to declare it. A human `set` to a `mod/` path is refused.
- **Sparse set.** Perf run with 200 lanes declared and none written, threshold pre-registered; then with three written.
- **Doc.** The knob-registry doc gains the column; `keymap.md`-style script for the new spellings runs through the real parser.

## Mutations to run

Each should bite; a survivor is a question.

- Rest `stops` at 1 instead of 0 → identity gate.
- Drop the per-writer key (last write wins across programs) → composition gate.
- Don't clear the entry on unmount → composition gate.
- Apply the lane at the old apply site as well as at materialisation (double-apply) → identity gate with a lane written, and before/after.
- Let the registry accept a `.blend` mode → refusals gate.
- Remove the sparse-set check → perf gate.
- Route `camera/thrust` through a lane → repro-input (the thrust is a level and must land immediately; a lane on it would still work, which is the point: this mutation is expected to *survive* the behaviour gates and be caught only by the registry refusing intent paths as modulation targets — if there's no such refusal, add it or record why not).

## Open questions (Chris rules)

1. **Camera orientation.** Yaw/pitch aren't registry knobs; they're plant state. Either the camera's materialised view registers as a routed read with `.add` lanes (yaw, pitch, roll all one mechanism), or `camera/bias/*` stays a host-owned special case. Lean: register it — three instances arguing for a rule was the whole reason for the campaign. But it means the plant exposes a read surface it didn't have.
2. **Spline camera: pull or rail.** A soft pull is an additive lane (`nearest(base) − base | mul w | ease …`), reading base, so no cycle. A rail you cannot leave is a constraint on the plant and belongs in the integrator, not a lane. The base position keeps flying free under a lane, so a rail-in-a-lane leaves the real position a long way from the picture. Not in this campaign; recorded so the first spline customer asks the question.
3. **Path spelling** — above.

## Not in scope

- The ~30 GLFW hotkeys, `game.zig` keyDown, and console container rendering — still open from yesterday, untouched here.
- Any demand-driven / out-of-sight evaluation. Chris raised it and parked it: rill is push, the fix when needed is distance-gated mount/unmount policy, not an evaluator change. Note the catch-up problem for clocked programs when that day comes.
