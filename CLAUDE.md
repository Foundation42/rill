# Working in rill

## Running tests — the default is to run NOTHING

Pick a gate because the change can break the thing it watches, never to
feel reassured. Chris has asked for this twice; a suite run per edit
makes the harness the activity rather than the work.

    zig build test        # 371, and quick — this is the cheap one

371 tests with no GPU in the loop, so the calculus here is gentler than
in matryoshka: run it when you have changed code, not after every edit,
and once before a commit. There is no `-Dtest-filter` wired in this
repo's `build.zig`; if iterating ever gets slow enough to matter, adding
one is the fix rather than skipping the suite.

**What is NOT cheap is downstream.** matryoshka embeds rill and gates it
with a nineteen-section GPU sweep plus reference captures. Touching the
C-ABI seam (`zig build seam`) or anything a host reads means those become
part of the blast radius — see `matryoshka/CLAUDE.md` for the table. A
change to a pure-rill internal does not.

**A new CORE WORD's blast radius is every host registry.** `register`
refuses a duplicate name, so a core word that collides with a host's word
does not shadow it or lose a race — it fails that host's registry init
outright, and every program in it. Hosts and their words, as of
2026-09-08 — spindrift is still the only host that registers OPERATORS:

    spindrift, words.register       (11)
        spawn · gravity · perish · relax · near · push ·
        align · sync · infect · deposit · hear

    spindrift, words.registerTracer  (4)
        collide · ground · slide · stick

Two doors, deliberately: a host with no world to trace calls `register`
alone, and a kernel naming a tracer word on such a host is refused at
mount rather than at parse. Both doors still take names out of the ONE
namespace, so all fifteen are spoken for.

This list has gone stale once already (it read seven words, dated
2026-09-02, while there were fifteen). Refresh it rather than trust it:

    grep -n '^        .name = ' ../spindrift/src/words.zig

`over` landed in core on 2026-09-02 and collided with spindrift's, which
had been its fifth word since beat 3; matryoshka registers both, so it
stopped building until the host's was deleted. Grep the list before
naming a core word, and read the host's version if the name is taken —
its edges had six days of real kernels behind them and were right twice
where the core draft was wrong.

Rules that hold whatever you picked:

- A gate that passed stays passed until the code changes.
- One GPU gate at a time, when a sibling repo's are involved.

## House style

Write the reasoning into the code. A gate's comment should name the bug
it was paid for. A gate that cannot fail is decoration: check it fails
against the old behaviour before believing it.
