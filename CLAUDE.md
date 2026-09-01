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

Rules that hold whatever you picked:

- A gate that passed stays passed until the code changes.
- One GPU gate at a time, when a sibling repo's are involved.

## House style

Write the reasoning into the code. A gate's comment should name the bug
it was paid for. A gate that cannot fail is decoration: check it fails
against the old behaviour before believing it.
