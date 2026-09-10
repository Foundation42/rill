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

    var items = std.ArrayListUnmanaged(script.Item).empty;
    try items.appendSlice(arena, sc.top);

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

    var out = sc.*;
    out.top = try items.toOwnedSlice(arena);
    return out;
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
