//! **Structural edits to a retained `Script`** — the half of the visual
//! editor that changes a program rather than looking at one.
//!
//! Everything here takes a `Script` and returns a NEW one, arena-allocated,
//! leaving the input untouched. Not because immutability is a virtue in
//! itself, but because the caller is a host holding a working copy it may
//! have to throw away: an edit that half-applied and then refused would leave
//! a document nobody can print, and the alternative to copying is a rollback
//! path with its own bugs. A script is a few thousand pointers into an arena;
//! copying one is cheaper than being careful.
//!
//! **The printer is still the wire format.** Nothing here writes text. The
//! caller prints the returned script with `script.print`, which is what keeps
//! one representation and makes `rill fmt` a no-op on the result — the
//! property the whole corpus is held to.
//!
//! ## Why this is not in `script.zig`
//!
//! `script.zig` imports `std` and nothing else, deliberately: it is the
//! authored shape of a file and the printer for it, and it knows no operators.
//! Every edit here needs the REGISTRY — what ports an operator has, which of
//! them must be bound, which are spelled with their name. Putting that in
//! `script.zig` would drag the registry into the printer's import graph for
//! the sake of a function the printer never calls.
//!
//! ## Read aloud
//!
//! `edit.zig`, and the functions are verbs a reader of the canvas would use:
//! `addCall`. Rejected: `mutate.zig` (biology, and it collides head-on with
//! the mutation-testing vocabulary these repos run on — "a mutation" already
//! means something here); `transform.zig` (matrices); `surgery.zig` (cute
//! once, tiresome twice); `rewrite.zig` (what `fmt` does, and the one thing
//! this must not be confused with — a rewrite preserves meaning).

const std = @import("std");
const script = @import("script.zig");
const registry = @import("registry.zig");

pub const Error = std.mem.Allocator.Error || error{
    /// No operator of that name is registered. Loud, and it lands on the
    /// name: a palette offering something the registry does not have is a
    /// palette out of date with its host, which is worth saying.
    UnknownOperator,
    /// The operator is not something a statement may call at all — a variadic
    /// (`array`, `record`) that exists only as the parser's assembly of `[…]`
    /// and `{…}`. A palette should not list it.
    NotCallable,
    /// The operator takes something this cannot leave open — a section body, a
    /// tail, or a required static such as `write`'s target path. See
    /// `addCall`, which lists all three and says what each would take.
    CannotLeaveOpen,
    /// No call begins at that line and column in this script. A stale canvas,
    /// or a `graph.CallSite` of `{0, 0}` — sugar with no call of its own.
    NoSuchCall,
    /// The call has no such port. The canvas drew a pin the registry does not
    /// declare, which means the two are out of step.
    NoSuchPort,
    /// The wire lands on a port fed by the PIPE, mid-chain — see `link`.
    NeedsSplit,
    /// The call is inside a `def` body. Editing it would change every call of
    /// that definition, which is a different act from moving one wire and
    /// wants to be asked for by name.
    InsideDefinition,
    /// The call is inside a `fan` branch (`also { … }`). Not handled in this
    /// cut, and refused rather than half-applied.
    InsideFan,
    /// The producer's statement does not come before the consumer's, and
    /// rill's parse order IS its dependency order. See `link`.
    NeedsReorder,
};

/// **One end of a wire**, addressed the way the canvas can address it.
///
/// The line and column are `graph.Node.site` — the call site of the operator
/// token that wrote the node, which is exact because two calls cannot begin at
/// the same place. The port is a DECLARED index: inputs for a `to`, outputs
/// for a `from`, which is what `hud_graph`'s `i{d}`/`o{d}` pin ids already are.
pub const Pin = struct {
    line: u32,
    col: u32,
    port: u8,
};

/// **Drop an operator on the canvas**: append a call to `op_name` with every
/// input that must be bound left as a declared HOLE.
///
/// This is what §3.15's shaped holes were built for, and the comment on
/// `graph.Source.hole` says so in as many words: *"an editor that drags an
/// operator onto a canvas had nowhere to put it."* rill's text cannot
/// otherwise say "this operator is here and its input is unbound", because
/// parse order is dependency order and an orphan has no place in the
/// statement list.
///
/// What lands in the file, for `push` (one required `number` input `k`):
///
///     using ?number as :push_k
///
///     push :push_k
///
/// **The `using` sits with its statement, not with the file's other
/// `using` lines.** Both are legal — an item may appear anywhere before its
/// use — and this is the one that survives being undone: an add and a later
/// delete take an adjacent pair away together, where hoisting to the top
/// leaves orphan declarations drifting above a file the reader never edited
/// there. It also puts a node's whole story in one place for someone reading
/// the diff.
///
/// **Which ports get a hole.** Only the ones that must be bound: `optional`
/// ports are simply not written, and the node draws them as unwired pins,
/// which is the truth. A `kw` port is spelled with its name, because the
/// parser refuses it positionally and would refuse the file this produced.
///
/// **What is refused.** An operator whose input is a section body or a tail
/// (`keep (> 0)`, a console verb's line-tail) cannot have that argument left
/// open — a hole is a VALUE and neither of those is one. `CannotLeaveOpen`,
/// by name, rather than emitting a file that will not parse.
///
/// Hole names are `:<op>_<port>`, and `_2`, `_3` on collision. Read aloud in
/// the file it produces: `:push_k` says what it is for at the point of use,
/// where `:k` says nothing and collides with the fold `roaches.rill` already
/// has, and `:hole1` says nothing anywhere.
pub fn addCall(
    arena: std.mem.Allocator,
    sc: *const script.Script,
    reg: *const registry.Registry,
    op_name: []const u8,
) Error!script.Script {
    const op_id = reg.find(op_name) orelse return error.UnknownOperator;
    const def = reg.get(op_id);

    // **Insert before the file's trailing annexes, not at the very end.**
    // An annex is a BLOCK about the program — `layout <stem>` is written last
    // by `hud save` and `describe` sits with its def — and a statement landing
    // after one reads as an afterthought bolted onto the document's footer.
    // It parses either way; rill has no ordering rule for annexes. It looks
    // wrong, and the file is the thing a person reads.
    //
    // Found by driving the verb: the second `hud add` on a file that already
    // had a `layout` block put its statement below it.
    var cut = sc.top.len;
    while (cut > 0 and sc.top[cut - 1] == .annex) cut -= 1;

    var items = std.ArrayListUnmanaged(script.Item).empty;
    try items.appendSlice(arena, sc.top[0..cut]);

    // An operator that needs a SECTION BODY (`keep (> 0)`, `map (…)`) cannot
    // be dropped bare: the body is a sub-graph, not a value, and there is no
    // hole spelling for one. The parser refuses `keep` without it by name, so
    // emitting it would produce a file that will not load — which is the one
    // outcome worse than refusing here.
    // A VARIADIC operator is sugar the parser assembles, never a call: `array`
    // and `record` come from `[…]` and `{…}` and `parseOpcall` refuses them by
    // name ("cannot be called directly"). There is nothing to drop.
    //
    // Found by the audit, second run, after the first found `=`. Two in a row
    // is the argument for the exhaustive gate over a chosen fixture, written
    // out: neither of these is a case anybody sits down and thinks of.
    if (def.variadic) return error.NotCallable;
    if (def.body > 0) return error.CannotLeaveOpen;

    // **A required STATIC has no hole either, and this is the case that
    // matters most.** `write row.u3`'s target is not a slot — it is
    // `Node.statics[0]`, a `.path` — and §3.15's holes are values on SLOTS.
    // There is no text that says "this operator is here and its target is not
    // chosen yet", so `write`, `notify`, `cast` and every other statically
    // addressed operator cannot be dropped bare.
    //
    // That is a real hole in the palette rather than a technicality, and it is
    // stated here rather than worked around: the answer is a menu that asks
    // for the path when the reader picks one of these, which is a beat of its
    // own (the host has the plane and can complete against it; rill cannot).
    // Refusing by name is what makes that beat findable instead of producing a
    // file that will not load.
    for (def.statics) |st| {
        if (st.optional or st.flag) continue;
        return error.CannotLeaveOpen;
    }

    var args = std.ArrayListUnmanaged(script.Arg).empty;
    for (def.inputs) |port| {
        if (port.optional) continue;
        // A tail captures the rest of the line, or the rest of the FILE. Both
        // are text, neither is a value, and a hole is a value.
        if (port.tail or port.tail_all) return error.CannotLeaveOpen;

        const name = try mintHole(arena, sc, items.items, def.name, port.name);
        try items.append(arena, .{ .using = .{
            .name = name,
            // The shape, when rill has a word for it. `any` is spelled as a
            // bare `?`: `using ?any as :x` would be a type name the reader
            // has to learn means "no constraint", and §3.15 already gives the
            // unshaped hole its own spelling.
            .body = if (port.ty == 0)
                "?"
            else
                try std.fmt.allocPrint(arena, "?{s}", .{reg.types.name(port.ty)}),
            .blank_before = 1,
        } });
        try args.append(arena, .{
            .kind = .hole,
            .text = name,
            .kw = if (port.kw) port.name else "",
        });
    }

    try items.append(arena, .{ .stmt = .{
        .head = .{ .call = .{
            .op = try arena.dupe(u8, def.name),
            .args = try args.toOwnedSlice(arena),
        } },
    } });
    try items.appendSlice(arena, sc.top[cut..]);

    var out = sc.*;
    out.top = try items.toOwnedSlice(arena);
    return out;
}


// ── wires ────────────────────────────────────────────────────────────────
//
// `addCall` puts an operator on the canvas. These two move the wires between
// them, and they are the consumer of `script.Arg.port`: having found the call
// with `graph.CallSite`, an editor then has to find the ARGUMENT, and `args`
// is in authored order where ports are in declared order.
//
// **What a wire IS in rill text, and why that shapes the refusals.** rill has
// no wire syntax. A wire is either the PIPE between two terms of one chain
// (`collide | slide`) or a name (`… as t1`, then `t1` read somewhere else).
// So moving a wire is never one edit in one place, and the three cases below
// are not an implementation's convenience — they are the grammar.
//
//   * an argument that is a literal, a hole, a path or a stream name: a LOCAL
//     edit, one `Arg` replaced;
//   * a chain HEAD that is a value (`plane.a | mul 2`, rewiring `mul`'s port
//     0): also local, the head value replaced;
//   * a port fed by the pipe MID-CHAIN: the statement would have to be cut in
//     two. Refused by name.
//
// **Why the cut is refused and not performed.** It is mechanical — `A | B | C`
// becomes `A | B as t1` and `t1 | C`, and both halves parse — so the reason is
// not difficulty. It is that a statement carries the reader's prose:
// `Stmt.lead` is the paragraph above it and `Stmt.trail` the note at its end,
// and in the exemplar every statement has one. Cutting a statement in half
// orphans that paragraph from half of what it describes, and nothing in a
// wire-drag says which half the author meant it for. A refusal that names the
// case leaves that decision with the person; a silent split moves their
// writing.

/// Where a call sits in the top-level item list.
const Loc = struct {
    item: usize,
    /// Null for the statement's HEAD call; otherwise the index into `stages`.
    stage: ?usize,
};

fn sameSite(c: script.Call, line: u32, col: u32) bool {
    return c.line == line and c.col == col;
}

fn fanHasSite(f: script.Fan, line: u32, col: u32) bool {
    for (f.branches) |b| {
        if (sameSite(b.head, line, col)) return true;
        for (b.stages) |sg| switch (sg) {
            .call => |c| if (sameSite(c, line, col)) return true,
            .fan => |inner| if (fanHasSite(inner, line, col)) return true,
            .project => {},
        };
    }
    return false;
}

fn itemsHaveSite(items: []const script.Item, line: u32, col: u32) bool {
    for (items) |it| switch (it) {
        .stmt => |st| {
            switch (st.head) {
                .call => |c| if (sameSite(c, line, col)) return true,
                .value => {},
            }
            for (st.stages) |sg| switch (sg) {
                .call => |c| if (sameSite(c, line, col)) return true,
                .fan => |f| if (fanHasSite(f, line, col)) return true,
                .project => {},
            };
        },
        else => {},
    };
    return false;
}

/// The top-level statement holding the call at this site.
///
/// The two REFUSALS are found here rather than reported as "no such call",
/// because they are different facts and lead somewhere different: a node in a
/// def body is editable, just not by this gesture, and a node in a fan branch
/// is a beat nobody has done yet. Answering `NoSuchCall` for either would send
/// a reader looking for a stale canvas.
fn locate(sc: *const script.Script, line: u32, col: u32) Error!Loc {
    if (line == 0) return error.NoSuchCall;
    for (sc.top, 0..) |*it, i| {
        const st = switch (it.*) {
            .stmt => |*s| s,
            else => continue,
        };
        switch (st.head) {
            .call => |c| if (sameSite(c, line, col)) return .{ .item = i, .stage = null },
            .value => {},
        }
        for (st.stages, 0..) |sg, j| switch (sg) {
            .call => |c| if (sameSite(c, line, col)) return .{ .item = i, .stage = j },
            .fan => |f| if (fanHasSite(f, line, col)) return error.InsideFan,
            .project => {},
        };
    }
    for (sc.defs) |d| {
        if (itemsHaveSite(d.body, line, col)) return error.InsideDefinition;
    }
    return error.NoSuchCall;
}

fn callOf(st: *const script.Stmt, stage: ?usize) *const script.Call {
    const si = stage orelse return &st.head.call;
    return &st.stages[si].call;
}

/// What a port is called, whether it may simply be dropped, and its type word
/// — from the registry for an operator, and from the script's own `defs` for a
/// def call, because a def call is a call and its arguments are editable the
/// same way.
const PortFacts = struct { name: []const u8, optional: bool, ty: []const u8 };

fn portFacts(
    arena: std.mem.Allocator,
    sc: *const script.Script,
    reg: *const registry.Registry,
    op: []const u8,
    port: u8,
) Error!PortFacts {
    if (reg.find(op)) |id| {
        const def = reg.get(id);
        if (port >= def.inputs.len) return error.NoSuchPort;
        const p = def.inputs[port];
        return .{
            .name = p.name,
            .optional = p.optional,
            .ty = if (p.ty == 0) "" else try arena.dupe(u8, reg.types.name(p.ty)),
        };
    }
    for (sc.defs) |d| {
        if (!std.mem.eql(u8, d.name, op)) continue;
        if (port >= d.ports.len) return error.NoSuchPort;
        const p = d.ports[port];
        // A def port with a DEFAULT is optional at the call site — the
        // parser splices the declared literal in exactly as if the caller
        // had typed it — so dropping the argument is legal and leaves a
        // program that still runs.
        return .{ .name = p.name, .optional = p.default.len > 0, .ty = p.ty };
    }
    return error.UnknownOperator;
}

/// The index in `args` of the argument bound to `port`, or null when no
/// authored argument binds it — the pipe filled it, or it is simply unbound.
fn argForPort(call: *const script.Call, port: u8) ?usize {
    for (call.args, 0..) |a, i| {
        const p = a.port orelse continue;
        if (p == port) return i;
    }
    return null;
}

/// Is this call's port 0 fed by the term before it in the chain?
///
/// A HEAD call has nothing before it, so its port 0 is an ordinary argument.
/// A STAGE always does: the head value, or the previous stage's output.
fn port0IsPiped(loc: Loc) bool {
    return loc.stage != null;
}

/// Rebuild one statement's call with a new argument list.
fn withArgs(arena: std.mem.Allocator, st: script.Stmt, stage: ?usize, args: []const script.Arg) Error!script.Stmt {
    var out = st;
    if (stage) |si| {
        const stages = try arena.dupe(script.Stage, st.stages);
        var c = stages[si].call;
        c.args = args;
        stages[si] = .{ .call = c };
        out.stages = stages;
    } else {
        var c = st.head.call;
        c.args = args;
        out.head = .{ .call = c };
    }
    return out;
}

/// Replace the whole top-level item list with one item changed.
fn withItem(arena: std.mem.Allocator, sc: *const script.Script, at: usize, item: script.Item) Error!script.Script {
    const items = try arena.dupe(script.Item, sc.top);
    items[at] = item;
    var out = sc.*;
    out.top = items;
    return out;
}


/// Where a new argument goes so the call still reads in declared order.
///
/// Not the end of the list: a `write`'s target is a positional STATIC the
/// parser consumes before any port (`port == null`) and it must stay first,
/// and a TAIL captures the rest of the line so nothing may follow it. Both of
/// those are how an argument list can be legal and un-appendable.
fn insertionIndex(call: *const script.Call, port: u8) usize {
    for (call.args, 0..) |a, i| {
        if (a.kind == .tail) return i;
        if (a.port) |p| {
            if (p > port) return i;
        }
    }
    return call.args.len;
}

/// An `as` name nothing else in the file has taken.
fn streamNameTaken(sc: *const script.Script, extra: []const []const u8, name: []const u8) bool {
    for (extra) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return itemsHaveName(sc.top, name) or for (sc.defs) |d| {
        if (itemsHaveName(d.body, name)) break true;
    } else false;
}

fn itemsHaveName(items: []const script.Item, name: []const u8) bool {
    for (items) |it| switch (it) {
        .stmt => |st| for (st.names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        },
        else => {},
    };
    return false;
}

/// `collide_normal`, `mul_out`, and `_2` on collision.
///
/// The OPERATOR plus the PORT, not the node's instance name: `mul1` lives in
/// the graph and never in the text, so a name built from it would be a name
/// the file cannot explain. `wordify` for `addCall`'s reason — a two-word or
/// symbolic operator is not a name.
fn mintStream(
    arena: std.mem.Allocator,
    sc: *const script.Script,
    reg: *const registry.Registry,
    extra: []const []const u8,
    op: []const u8,
    port: u8,
) Error![]const u8 {
    const stem = try wordify(arena, op);
    const leaf: []const u8 = blk: {
        if (reg.find(op)) |id| {
            const def = reg.get(id);
            if (port < def.outputs.len) break :blk try wordify(arena, def.outputs[port].name);
        }
        break :blk try std.fmt.allocPrint(arena, "out{d}", .{port});
    };
    var n: u32 = 1;
    while (true) : (n += 1) {
        const name = if (n == 1)
            try std.fmt.allocPrint(arena, "{s}_{s}", .{ stem, leaf })
        else
            try std.fmt.allocPrint(arena, "{s}_{s}_{d}", .{ stem, leaf, n });
        if (!streamNameTaken(sc, extra, name)) return name;
    }
}

/// **Break the wire into a port**, leaving an open socket rather than a gap.
///
/// A REQUIRED port becomes a declared hole — `using ?number as :mul_b` and the
/// argument spelled `:mul_b`. That is §3.15's whole purpose and `addCall`
/// already mints them: an editor needs text that says "this operator is here
/// and this input is not chosen yet", and rill's only such text is a hole.
/// An OPTIONAL port simply loses its argument, because an optional port with
/// nothing written IS the unbound state and a hole there would be noise.
///
/// The `using` is inserted before the statement rather than woven into it.
/// That puts it above the statement's own lead comments, which is where a
/// declaration reads best: the paragraph a person wrote is about the
/// statement, and interrupting it to declare a socket would edit their prose.
pub fn unlink(
    arena: std.mem.Allocator,
    sc: *const script.Script,
    reg: *const registry.Registry,
    to: Pin,
) Error!script.Script {
    const loc = try locate(sc, to.line, to.col);
    const st = sc.top[loc.item].stmt;
    const call = callOf(&st, loc.stage);
    const facts = try portFacts(arena, sc, reg, call.op, to.port);

    const ai = argForPort(call, to.port) orelse {
        // Nothing authored holds this port. Either the pipe fills it, or it
        // was never bound at all — and an unbound port has no wire to break,
        // so answering "done" is the truth rather than a shrug.
        if (to.port != 0 or !port0IsPiped(loc)) return sc.*;
        // The pipe. If this is the FIRST stage the head value is the wire, and
        // taking it down is local: the head becomes a hole. Anywhere else, the
        // wire is a `|` between two calls and there is no text to replace.
        if (loc.stage.? != 0 or st.head != .value) return error.NeedsSplit;
        if (facts.optional) return error.NeedsSplit;
        const name = try mintHole(arena, sc, sc.top, call.op, facts.name);
        var out_st = st;
        out_st.head = .{ .value = name };
        return withUsing(arena, sc, loc.item, name, facts.ty, out_st);
    };

    var args = std.ArrayListUnmanaged(script.Arg).empty;
    try args.appendSlice(arena, call.args);
    if (facts.optional) {
        _ = args.orderedRemove(ai);
        const st2 = try withArgs(arena, st, loc.stage, try args.toOwnedSlice(arena));
        return withItem(arena, sc, loc.item, .{ .stmt = st2 });
    }
    const name = try mintHole(arena, sc, sc.top, call.op, facts.name);
    args.items[ai] = .{
        .kind = .hole,
        .text = name,
        // The keyword spelling is the author's and survives the edit: a port
        // declared `kw` REFUSES the positional form, so dropping the word here
        // would produce a file that does not parse.
        .kw = call.args[ai].kw,
        .kw_colon = call.args[ai].kw_colon,
        .port = to.port,
    };
    const st2 = try withArgs(arena, st, loc.stage, try args.toOwnedSlice(arena));
    return withUsing(arena, sc, loc.item, name, facts.ty, st2);
}

/// Replace item `at` with `st`, and declare a hole just above it.
fn withUsing(
    arena: std.mem.Allocator,
    sc: *const script.Script,
    at: usize,
    name: []const u8,
    ty: []const u8,
    st: script.Stmt,
) Error!script.Script {
    var items = std.ArrayListUnmanaged(script.Item).empty;
    try items.appendSlice(arena, sc.top[0..at]);
    try items.append(arena, .{ .using = .{
        .name = name,
        // `addCall`'s spelling, and its reason: `?any` would be a type word a
        // reader has to be told means "no constraint", and §3.15 already gives
        // the unshaped hole a spelling of its own.
        .body = if (ty.len == 0) "?" else try std.fmt.allocPrint(arena, "?{s}", .{ty}),
        .blank_before = 1,
    } });
    try items.append(arena, .{ .stmt = st });
    try items.appendSlice(arena, sc.top[at + 1 ..]);
    var out = sc.*;
    out.top = try items.toOwnedSlice(arena);
    return out;
}

/// **Join one call's output to another call's input.**
///
/// rill has no wire syntax, so this writes the one thing that IS a wire
/// between two statements: a NAME. The producer's statement gains `as <name>`
/// if that output has none, and the consumer's argument becomes that name.
/// Fan-out is then free — a name may be read by any number of consumers, which
/// is why nothing here has to ask how many wires already leave that output.
///
/// **Three refusals, and each is the grammar rather than a gap.**
///
/// `NeedsSplit` when the producer is not the last term of its chain: `as`
/// names the chain's FINAL outputs, so `A | B | C as t` names C's, and there
/// is no spelling for B's without cutting the statement. Also when the
/// consumer's port 0 is fed by a `|` mid-chain, for the same reason in the
/// other direction.
///
/// `NeedsReorder` when the producer's statement does not come before the
/// consumer's. rill's parse order IS its dependency order — `parser.zig` has
/// said since the spring that a visual editor must emit statements in it — so
/// a name read above where it is written is a file that will not load. Moving
/// the statement is the obvious fix and is not done here: a statement carries
/// the reader's prose and may be depended on by others, so which one moves is
/// a judgement, not an arithmetic.
pub fn link(
    arena: std.mem.Allocator,
    sc: *const script.Script,
    reg: *const registry.Registry,
    from: Pin,
    to: Pin,
) Error!script.Script {
    const fl = try locate(sc, from.line, from.col);
    const tl = try locate(sc, to.line, to.col);
    // **Same statement is a SPLIT, not a reorder.** Both endpoints in one
    // chain means the wire between them is the `|` itself, and reordering
    // nothing would fix that — answering `NeedsReorder` would tell a reader to
    // move a statement above itself. Found by driving the two against
    // `roaches.rill`, where `row.seed | mul 0.025 | add 0.03` is one statement
    // and the obvious drag lands inside it.
    if (fl.item == tl.item) return error.NeedsSplit;
    if (fl.item > tl.item) return error.NeedsReorder;

    const fst = sc.top[fl.item].stmt;
    // `as` names the LAST term's outputs. A producer anywhere else in its
    // chain has no name to give.
    const tail_stage: ?usize = if (fst.stages.len == 0) null else fst.stages.len - 1;
    if (!sameStage(fl.stage, tail_stage)) return error.NeedsSplit;

    const tst = sc.top[tl.item].stmt;
    const tcall = callOf(&tst, tl.stage);
    _ = try portFacts(arena, sc, reg, tcall.op, to.port); // the port must exist

    // ── name the producer's output ───────────────────────────────────────
    //
    // `as a, b` names outputs IN ORDER, so naming output 2 means naming 0 and
    // 1 as well. The filler names are real names a person can read and reuse,
    // not placeholders: there is no spelling for "skip this one".
    var names = std.ArrayListUnmanaged([]const u8).empty;
    try names.appendSlice(arena, fst.names);
    const fcall = callOf(&fst, fl.stage);
    while (names.items.len <= from.port) {
        const idx: u8 = @intCast(names.items.len);
        try names.append(arena, try mintStream(arena, sc, reg, names.items, fcall.op, idx));
    }
    const wire = names.items[from.port];

    var producer = fst;
    producer.names = try names.toOwnedSlice(arena);

    // ── point the consumer at it ─────────────────────────────────────────
    var consumer = tst;
    if (argForPort(tcall, to.port)) |ai| {
        var args = try arena.dupe(script.Arg, tcall.args);
        args[ai] = .{
            .kind = .stream,
            .text = wire,
            .kw = tcall.args[ai].kw,
            .kw_colon = tcall.args[ai].kw_colon,
            .port = to.port,
        };
        consumer = try withArgs(arena, tst, tl.stage, args);
    } else if (to.port == 0 and port0IsPiped(tl)) {
        // The pipe holds it. Local only when the head VALUE is the wire —
        // `plane.a | mul 2`, rewiring `mul`'s port 0 — which is one string.
        if (tl.stage.? != 0 or tst.head != .value) return error.NeedsSplit;
        consumer.head = .{ .value = wire };
    } else {
        // An unbound port: write the argument that was never there.
        var args = std.ArrayListUnmanaged(script.Arg).empty;
        try args.appendSlice(arena, tcall.args);
        try args.insert(arena, insertionIndex(tcall, to.port), .{
            .kind = .stream,
            .text = wire,
            .port = to.port,
        });
        consumer = try withArgs(arena, tst, tl.stage, try args.toOwnedSlice(arena));
    }

    const items = try arena.dupe(script.Item, sc.top);
    items[fl.item] = .{ .stmt = producer };
    items[tl.item] = .{ .stmt = consumer };
    var out = sc.*;
    out.top = items;
    return out;
}

fn sameStage(a: ?usize, b: ?usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// A hole name nothing else in the file has taken.
///
/// It has to consider the items being BUILT and not just the ones that were
/// there, because a single `addCall` may mint several — an operator with two
/// required inputs would otherwise name both of them `:op_a` and produce a
/// file whose second declaration silently shadows the first.
fn mintHole(
    arena: std.mem.Allocator,
    sc: *const script.Script,
    building: []const script.Item,
    op: []const u8,
    port: []const u8,
) Error![]const u8 {
    const stem = try wordify(arena, op);
    var n: u32 = 1;
    while (true) : (n += 1) {
        const name = if (n == 1)
            try std.fmt.allocPrint(arena, ":{s}_{s}", .{ stem, port })
        else
            try std.fmt.allocPrint(arena, ":{s}_{s}_{d}", .{ stem, port, n });
        if (!nameTaken(sc, building, name)) return name;
    }
}

/// An operator's name as it can appear INSIDE a fold name.
///
/// Two kinds of operator name are not words. A **two-word** one (`rbf sample`,
/// and every host verb-plus-subop `matryoshka` registers) has a space in it; a
/// **symbolic** one (`=`, `>`, `+`) is punctuation. Either lands in
/// `using ? as :<name>` as something the tokenizer will not read as a name,
/// and the file does not load.
///
/// Found by the exhaustive audit on its first run, on `=` — which is exactly
/// why that gate walks the whole registry instead of two operators somebody
/// chose. Anything outside `[A-Za-z0-9_]` becomes `_`, and a name that starts
/// with a digit or is empty afterwards gets a leading `h`, because a fold name
/// is lexed as a name and a name does not start with a digit.
fn wordify(arena: std.mem.Allocator, op: []const u8) Error![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    for (op) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_';
        try out.append(arena, if (ok) ch else '_');
    }
    if (out.items.len == 0 or (out.items[0] >= '0' and out.items[0] <= '9')) {
        try out.insert(arena, 0, 'h');
    }
    return out.toOwnedSlice(arena);
}

fn nameTaken(sc: *const script.Script, building: []const script.Item, name: []const u8) bool {
    if (itemsHave(building, name)) return true;
    for (sc.defs) |d| {
        if (itemsHave(d.body, name)) return true;
    }
    return false;
}

fn itemsHave(items: []const script.Item, name: []const u8) bool {
    for (items) |it| {
        switch (it) {
            .using => |u| if (std.mem.eql(u8, u.name, name)) return true,
            else => {},
        }
    }
    return false;
}
