# The slate

**A named register file that lives for one row of one tick.** One operator
says something on it; operators below read it; the next row starts blank.
Christian's design, 2026-09-07 — *"just a named register file for slamming
datasets around, nothing to do with the plane"*.

```rill
collide | slide
row.u0 | relax 1 plane.drift.@self.k.plunge | mul slate.contact | write row.u0 add
```

`slide` says `contact`; the line below reads it. Both happen inside one
row's evaluation, and nothing survives it.

## Why it is not a field

A row field cannot carry this, and the reason is structural rather than a
matter of taste. `row.zig`'s `evalRow` runs the whole node loop and lands
the queued writes **after** it:

```
for (prog.nodes.items) |*n| { … }        // every node, reading the snapshot
for (sc.writes[0..sc.n_writes]) |w| { … } // then the writes land
```

So a field written at node 3 is invisible at node 7. The earliest a reader
sees it is the NEXT tick — and a value that crosses a tick boundary is
**state**: it owes a dump, a format version, and a cross-language reader.
For "am I touching something right now", all of that is the wrong price for
a fact that stops being true in sixteen milliseconds.

The slate crosses nothing, so it owes nothing.

## Why it is not the plane

The plane is the world, shared and persistent, and everything on it is
struple-encoded so that anything can read it. The slate is neither shared
nor persistent, which is precisely what lets it hold things the plane
cannot — a native handle, a decoded buffer, a pointer into something the
host owns. **A slate entry may hold anything exactly because it cannot
survive the row.**

## The three heads

`plane.` is the world. `row.` is the row a kernel is mounted on. `slate.`
is the within-tick side channel. All three are paths because all three are
places; the mount decides which store answers.

## Declaring and reading

An operator declares what it may say, in its `OpDef`, beside its ports:

```zig
.publishes = &.{"contact"},
```

and says it during eval, by index:

```zig
ctx.publish(0, .{ .scalar = fixed.ONE });
```

A reader spells it `slate.<name>` anywhere a path goes. Names are resolved
at MOUNT into the slots that read them — the same pre-resolution
`write_ref` already gets — so the cost at eval is a store per listening
slot, and nothing at all when nobody is listening.

## The two refusals

Declared rather than discovered, because **a side channel you can misspell
in silence is worse than no side channel**.

- **`slate.<name>` that nothing says** refuses at mount, by name. Without
  it a typo reads null for ever and the line it feeds is quiet on every
  row.
- **A reader on or above the line that says it** refuses at mount, by name.
  The slate is filled as the program runs, in statement order, so a reader
  must sit below its publisher. That ordering is real and implicit, so it
  is checked rather than left to be discovered.

Said and never read is fine: an operator says the same thing whether or not
anyone is listening.

## The handle lane

A slate name has two lanes. `slate.<name>` in a program is the **Val** lane
— numbers, vectors, booleans, what the language can read. Operators also
get a **handle** lane under the same name: `Handle{ ptr, len }`, a pointer
the publisher owns.

```zig
.publishes = &.{"crowd"},   // on the publisher
ctx.publishHandle(0, .{ .ptr = @ptrCast(buf.ptr), .len = n });

.consumes = &.{"crowd"},    // on the reader
const h = ctx.handle(0) orelse return;
```

The language never sees it, so a pointer cannot reach a field, a dump or a
comparison. It is safe for the same reason as everything else here: it
cannot survive the row. That is not a promise anybody keeps — it is the
`@memset` at the top of `evalRow`.

The first customer is spindrift's `near`, which has a list of row ids to
hand to `push`. A list is precisely what a row `Val` cannot hold: the row
plane's arrays are literal-only and no operator emits one.

## What it is not

Not a cache. `Runtime.node_scratch` (rill `fb2164a`) is a node's own memory
across ticks, addressed by the node itself and private to it. The slate is
addressed by NAME and shared between nodes, and dies at the row. They were
briefly assumed to be one mechanism with a lifetime parameter; they are
not — the addressing differs, not only the lifetime.

Not a queue, not a bus with delivery, not ordered by anything but the
program. One name, one value, last writer below wins.
