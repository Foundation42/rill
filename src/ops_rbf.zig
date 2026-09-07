//! ops_rbf — the RBF pack: two words, registered by a host that wants them.
//!
//! ## Why this is a PACK and not two more entries in `ops.CORE`
//!
//! The core set is 114 operators and the namespace is flat. Christian, on
//! seeing this campaign's words proposed: *"I'm starting to get a little
//! concerned about the rill namespace filling up with verbs. maybe we should
//! think about scoping them."* He is right, and the answer has two halves
//! that are easy to confuse:
//!
//!   - **Where a word comes from** is a REGISTRATION question. `registerCore`
//!     is one call; this is a second. A host that has no use for radial basis
//!     functions never calls it, and for that host the language has 114 words,
//!     not 116. spindrift's `registerTracer` is the existing precedent for
//!     conditional registration, and the seam is already exactly right —
//!     built-in, host-injected and def-minted operators are indistinguishable
//!     once registered, so a pack costs the runtime nothing.
//!
//!   - **What a word is CALLED** is a spelling question, and the registry
//!     already answers it: a two-word name (`rbf through`) is one operator.
//!     The parser tries the two-word form first (`parser.zig`'s
//!     `parseOpcallCarrying`), `register` splits on the space to check
//!     reserved words, and nothing else in the language has to learn
//!     anything. No new grammar, no dotted names for the tokenizer to
//!     disambiguate against `plane.` and `row.` paths, no underscore prefix
//!     that reads aloud as punctuation.
//!
//! `docs/namespaces.md` is the full argument, including what it would mean
//! for the words already registered (short version: nothing, deliberately —
//! a scheme that cannot be adopted one family at a time is not adoptable, and
//! this one is opt-in per family, forever).
//!
//! The two words, and why exactly two. `rbf through` reads a set; `rbf bump`
//! authors one. Everything else about a set is ordinary record and array
//! arithmetic on an inspectable value, which is the point of the wire form.
//! Deliberately NOT here: the fit (2000 Adam iterations against a sampled
//! target is a host command, not a dataflow operator — it belongs where
//! `loam-run --rbf` already is), file load and save (a plane path is the
//! rill-shaped way to hand a program an asset), a gradient (no customer), and
//! anything nine-channel-flavoured.

const std = @import("std");
const struple = @import("struple");
const registry = @import("registry.zig");
const types = @import("types.zig");
const rbf = @import("rbf.zig");

const EvalCtx = registry.EvalCtx;
const EvalError = registry.EvalError;
const Emit = registry.Emit;
const Tag = types.Tag;

// ── small local helpers ───────────────────────────────────────────────────

fn raw(ctx: *EvalCtx, i: usize) EvalError![]const u8 {
    return ctx.in[i] orelse ctx.refuse("{s}: port '{s}' has no value yet", .{ ctx.op.name, ctx.portName(i) });
}

/// The type word for a message, in the vocabulary `ops.describe` uses. Kept
/// shallow on purpose: every refusal below already names the port and the
/// number that offended, and a fully expanded record adds a wall.
fn kindWord(encoded: []const u8) []const u8 {
    return switch (types.typeOfValue(encoded)) {
        Tag.number => "a number",
        Tag.boolean => "a boolean",
        Tag.string => "a string",
        Tag.record => "a record",
        Tag.bytes => "bytes",
        Tag.array => "an array",
        else => "nothing",
    };
}

/// Read an array port as f32s into `out`, refusing by name on anything that
/// is not an array of numbers. Returns how many landed.
fn numbersIn(ctx: *EvalCtx, port: usize, out: []f32) EvalError!usize {
    const v = try raw(ctx, port);
    if (types.typeOfValue(v) != Tag.array) {
        return ctx.refuse("{s}: '{s}' is {s}, not an array of numbers", .{ ctx.op.name, ctx.portName(port), kindWord(v) });
    }
    const inner = (struple.view(v).containedItems(ctx.arena) catch null) orelse
        return ctx.refuse("{s}: '{s}' is a malformed array", .{ ctx.op.name, ctx.portName(port) });
    var r = struple.reader(inner);
    var n: usize = 0;
    while (r.next() catch return ctx.refuse("{s}: '{s}' is a malformed array", .{ ctx.op.name, ctx.portName(port) })) |e| {
        if (n == out.len) return ctx.refuse("{s}: '{s}' has more than {d} numbers", .{ ctx.op.name, ctx.portName(port), out.len });
        out[n] = switch (e) {
            .float32 => |x| x,
            .float64 => |x| @floatCast(x),
            .int => |x| @floatFromInt(x),
            else => return ctx.refuse("{s}: '{s}'[{d}] is not a number", .{ ctx.op.name, ctx.portName(port), n }),
        };
        if (!std.math.isFinite(out[n])) {
            return ctx.refuse("{s}: '{s}'[{d}] is not a finite number", .{ ctx.op.name, ctx.portName(port), n });
        }
        n += 1;
    }
    if (n == 0) return ctx.refuse("{s}: '{s}' is empty", .{ ctx.op.name, ctx.portName(port) });
    return n;
}

/// Turn a decode `Fault` into the refusal the node hands back. Every branch
/// names the set's port and what was wrong with it — a program that read
/// zeros off a mistyped path would look exactly like one whose kernels are
/// all far away, and the two must never be confusable.
fn refuseFault(ctx: *EvalCtx, port: usize, fault: rbf.Fault) EvalError {
    const pn = ctx.portName(port);
    return switch (fault) {
        .not_a_record => ctx.refuse("{s}: '{s}' is {s}, not an rbf set — a set is {{d, m, k}}", .{ ctx.op.name, pn, kindWord(ctx.in[port] orelse "") }),
        .missing_key => |k| ctx.refuse("{s}: '{s}' has no '{s}' — a set is {{d: <axes>, m: <channels>, k: [numbers]}}", .{ ctx.op.name, pn, k }),
        .key_not_an_int => |k| ctx.refuse("{s}: '{s}.{s}' is not a whole number", .{ ctx.op.name, pn, k }),
        .key_out_of_range => |r| ctx.refuse("{s}: '{s}.{s}' is {d} — it must be 1..{d}", .{ ctx.op.name, pn, r.key, r.got, r.max }),
        .kernels_not_an_array => ctx.refuse("{s}: '{s}.k' is not an array", .{ ctx.op.name, pn }),
        .malformed => ctx.refuse("{s}: '{s}' is a malformed set", .{ ctx.op.name, pn }),
        .element_not_a_number => |i| ctx.refuse("{s}: '{s}.k[{d}]' is not a number", .{ ctx.op.name, pn, i }),
        .element_not_finite => |i| ctx.refuse("{s}: '{s}.k[{d}]' is not finite — an infinite weight has no value anywhere and a NaN centre puts every read at NaN", .{ ctx.op.name, pn, i }),
        .ragged => |r| ctx.refuse("{s}: '{s}.k' has {d} numbers, which is not a whole number of {d}-number kernels", .{ ctx.op.name, pn, r.len, r.stride }),
    };
}

// ── the cache ─────────────────────────────────────────────────────────────
//
// Measured before it was built (the ledger carries the table): decoding a
// 256-kernel set off the wire costs 62 µs and reading it costs 0.25 µs — 250
// to 1. A `through` node is handed a fresh query every tick and a set that
// changed once, at mount, so re-decoding per tick is the whole cost of the
// operator and none of its work.
//
// So the decoded kernels live in `ctx.scratch`, which survives ticks and is
// absent from the dump. What licenses reusing them is the runtime's own
// contract, not a hopeful guess: a node whose input changed is dirty and
// evaluates, so `in_fresh[set]` false means the bytes at that port are the
// same bytes as last tick. That is an arrival-dependent question, which is
// why this operator declares `.reads` and not `.pure` — `reads` is defined in
// `registry.OpClass` as exactly "the op asks `in_fresh`", and it is what
// forbids a future cache pass from skipping the eval that would have
// refreshed us.
//
// The recorded byte length is a second belt: a cache built for a set of one
// length is never handed to a set of another.

const CACHE_HEADER = 6; // u32 source length, u8 d, u8 m

fn cachedSet(ctx: *EvalCtx, port: usize, bytes: []const u8) EvalError!rbf.Set {
    const sc = ctx.scratch;
    const stale = ctx.in_fresh[port] or sc.items.len < CACHE_HEADER or
        std.mem.readInt(u32, sc.items[0..4], .little) != @as(u32, @intCast(bytes.len));
    if (!stale) {
        const d = sc.items[4];
        const m = sc.items[5];
        const n = (sc.items.len - CACHE_HEADER) / 4;
        const k = try ctx.arena.alloc(f32, n);
        for (k, 0..) |*x, i| x.* = @bitCast(std.mem.readInt(u32, sc.items[CACHE_HEADER + i * 4 ..][0..4], .little));
        return .{ .d = d, .m = m, .k = k };
    }

    var buf = std.ArrayListUnmanaged(f32).empty;
    var fault: rbf.Fault = .malformed;
    const set = rbf.decode(ctx.arena, bytes, &buf, &fault) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadSet => return refuseFault(ctx, port, fault),
    };

    sc.clearRetainingCapacity();
    try sc.ensureTotalCapacity(ctx.state_gpa, CACHE_HEADER + set.k.len * 4);
    var head: [CACHE_HEADER]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(bytes.len), .little);
    head[4] = set.d;
    head[5] = set.m;
    sc.appendSliceAssumeCapacity(&head);
    for (set.k) |x| {
        var w: [4]u8 = undefined;
        std.mem.writeInt(u32, &w, @bitCast(x), .little);
        sc.appendSliceAssumeCapacity(&w);
    }
    return set;
}

// ── rbf through ───────────────────────────────────────────────────────────

/// `q | rbf through <set>` — the query point through the field, M numbers out.
///
/// Read-aloud: "the row's state, rbf through the flame's coat". The set is
/// what you pass a point THROUGH, which is the same arrow as
/// `State → Field → Properties`; a set is not a function you call and not a
/// table you index.
///
/// The query is an ARRAY and never a record, and the refusal says so. A
/// record's fields arrive in their keys' sort order, which is alphabetical
/// and not the manifold's axis order, so `{cooled, sooted, thinned}` and
/// `{a, b, c}` would read at different points of the same set while both
/// looking right. `distance` and `within` take `record{x, y, z}` because a
/// position HAS named axes; a manifold coordinate does not.
///
/// The answer is one array of M numbers, picked apart with `nth`. Not nine
/// named outputs: naming them would put loam's (blend, albedo, roughness,
/// metallic, emissive) schema inside rill, where it means nothing, and would
/// make the word useless for the four-channel set somebody authors next week.
fn evalThrough(ctx: *EvalCtx) EvalError!Emit {
    const set = try cachedSet(ctx, 1, try raw(ctx, 1));

    var q: [rbf.MAX_D]f32 = undefined;
    const n = try numbersIn(ctx, 0, &q);
    if (n != set.d) {
        return ctx.refuse("rbf through: '{s}' has {d} numbers and the set has {d} axes", .{ ctx.portName(0), n, set.d });
    }

    var y: [rbf.MAX_M]f32 = undefined;
    rbf.eval(set, q[0..set.d], y[0..set.m]);

    // f32 out, not f64: these numbers were computed in f32 and are the same
    // f32s loam's evaluator and the shader produce, so widening them here
    // would print seventeen digits of a number that only has seven and make
    // the byte-comparison gate read as an approximation.
    var inner = struple.Packer.init(ctx.arena);
    for (y[0..set.m]) |v| try inner.appendF32(v);
    try ctx.out[0].appendArray(inner.bytes());
    return Emit.first;
}

// ── rbf bump ──────────────────────────────────────────────────────────────

/// `[<set>] | rbf bump at <centre> width <w> value <channels>` — one more
/// Gaussian on the set flowing through, or a new set when nothing is piped in.
///
/// Read-aloud: "rbf bump at the origin, width a third, value white-hot". A
/// compactly-supported Gaussian is called a bump function, so the word names
/// the thing rather than describing it, and it is a verb in the position the
/// grammar wants one.
///
/// **Why the set is the PIPED input rather than a set-of-kernels literal.**
/// rill has no `concat` on arrays and no way to call a variadic operator by
/// name (`array` and `record` reach theirs through `[…]` and `{…}` syntax
/// only), so an array of kernels could be built but never assembled from
/// separately-computed parts. A fold expressed as a pipeline needs neither:
///
///     rbf bump at [0, 0, 0] width 0.30 value [1.0, 0.85, 0.35]
///       | rbf bump at [1, 0, 0] width 0.45 value [0.2, 0.2, 0.22]
///       | write plane.fire.coat
///
/// reads down the page as the kernels being placed, one after another, and
/// the pipe is doing what a pipe does. The cost, stated: each bump re-encodes
/// the whole set, so authoring N kernels is O(N²) bytes. For the ten a hand
/// places that is nothing; nobody hand-places 256, they fit them and load the
/// set through a plane path.
///
/// `width` is σ — the same width `loam.rbf.Kernel.isotropic` takes, so a
/// kernel authored here and one fitted there mean the same thing by the same
/// number. One number is a sphere; an array of D is an axis-aligned
/// ellipsoid. A rotated one needs the off-diagonal terms of L and nothing has
/// asked for one by hand (see `rbf.axisAligned`).
fn evalBump(ctx: *EvalCtx) EvalError!Emit {
    var mu: [rbf.MAX_D]f32 = undefined;
    const d = try numbersIn(ctx, 1, &mu);

    var widths: [rbf.MAX_D]f32 = undefined;
    const wv = try raw(ctx, 2);
    if (types.typeOfValue(wv) == Tag.array) {
        const nw = try numbersIn(ctx, 2, &widths);
        if (nw != d) {
            return ctx.refuse("rbf bump: 'width' has {d} numbers and 'at' has {d} axes", .{ nw, d });
        }
    } else {
        const w = types.asNumber(wv) orelse
            return ctx.refuse("rbf bump: 'width' is {s}, not a number or an array of them", .{kindWord(wv)});
        for (0..d) |i| widths[i] = @floatCast(w);
    }
    for (widths[0..d], 0..) |w, i| {
        // A zero or negative width is not a very small kernel: L = 1/σ makes
        // it an infinite or inverted precision, and every read comes back NaN
        // or reads the kernel inside out. Loud, on the node that said it.
        if (!(w > 0) or !std.math.isFinite(w)) {
            return ctx.refuse("rbf bump: 'width'[{d}] is {d} — a width is a positive number of units, and 1/width is what goes in the kernel", .{ i, w });
        }
    }

    var value: [rbf.MAX_M]f32 = undefined;
    const m = try numbersIn(ctx, 3, &value);

    const st = rbf.stride(d, m);
    var k = std.ArrayListUnmanaged(f32).empty;

    // The set flowing in, if any. A first bump with nothing piped mints the
    // shape from its own arguments; every later one must agree with the set
    // it is adding to, and a mismatch names both shapes — a 3-axis kernel
    // silently appended to a 4-axis set would leave a `k` that still divides
    // evenly and reads as garbage.
    if (ctx.in[0]) |prev| {
        const set = try cachedSet(ctx, 0, prev);
        if (set.d != d or set.m != m) {
            return ctx.refuse("rbf bump: the set has {d} axes and {d} channels; this bump has {d} and {d}", .{ set.d, set.m, d, m });
        }
        try k.appendSlice(ctx.arena, set.k);
    }

    try k.ensureUnusedCapacity(ctx.arena, st);
    k.appendSliceAssumeCapacity(mu[0..d]);
    const l_at = k.items.len;
    k.appendNTimesAssumeCapacity(0, d * (d + 1) / 2);
    rbf.axisAligned(k.items[l_at..], widths[0..d]);
    k.appendSliceAssumeCapacity(value[0..m]);

    try rbf.encode(&ctx.out[0], ctx.arena, .{ .d = @intCast(d), .m = @intCast(m), .k = k.items });
    return Emit.first;
}

// ── registration ──────────────────────────────────────────────────────────

const PACK = [_]registry.OpDef{
    .{
        .name = "rbf through",
        .inputs = &.{ .{ .name = "q", .ty = Tag.array }, .{ .name = "set", .ty = Tag.record } },
        .outputs = &.{.{ .name = "out", .ty = Tag.array }},
        .routes = .anywhere,
        // `.reads` and not `.pure`: this op asks `in_fresh` to decide whether
        // its decoded set is still good, which is `OpClass`'s own definition
        // of arrival-dependent. The answer is a pure function of the inputs;
        // the SKIPPABILITY is not, and that is what the class is licensing.
        .class = .reads,
        .help = "Read an rbf set at a query point — `[row.u0, row.u1, row.u2] | rbf through plane.fire.coat | nth 1`. The query is an array with one number per axis of the set; the answer is an array of the set's channels. A set is {d, m, k} (see `rbf bump`).",
        .eval = evalThrough,
    },
    .{
        .name = "rbf bump",
        .inputs = &.{
            .{ .name = "set", .ty = Tag.record, .optional = true },
            .{ .name = "at", .ty = Tag.array, .kw = true },
            .{ .name = "width", .ty = Tag.any, .kw = true },
            .{ .name = "value", .ty = Tag.array, .kw = true },
        },
        .outputs = &.{.{ .name = "out", .ty = Tag.record }},
        .routes = .anywhere,
        .help = "Add one Gaussian to an rbf set — `rbf bump at [0, 0, 0] width 0.3 value [1, 0.85, 0.35] | rbf bump at [1, 0, 0] width 0.45 value [0.2, 0.2, 0.22]`. Unpiped it starts a set and its arguments fix the shape; piped it appends and must agree. `width` is σ: one number is a sphere, an array of them an axis-aligned ellipsoid.",
        .eval = evalBump,
    },
};

/// Register the RBF pack. A host that has no use for radial basis functions
/// simply never calls this, and for that host the language does not have
/// these words at all — which is the point (see the header).
pub fn register(reg: *registry.Registry) !void {
    for (PACK) |def| _ = try reg.register(def);
}
