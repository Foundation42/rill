//! ops — rill's built-in operator set (§6).
//!
//! Everything here goes through the same `Registry.register` path the host
//! uses; nothing is privileged. The kernel deliberately does not contain an
//! `if`: selection is `select`/`lerp` (all branches exist as live data, one
//! is chosen or blended per tick) and gating is `where`/`partition` over
//! occurrence streams (an untriggered gate is silence — there is no
//! else-wire, `partition` is the else when one is wanted).
//!
//! Conventions:
//! - Math promotes to f64 and emits f64, so each operator's output encoding
//!   is canonical and compare-and-suppress stays a memcmp.
//! - Threshold/edge adapters baseline silently: the first value observed sets
//!   state without firing — a program mounted with health already at 15 has
//!   not *dropped* below 20.
//! - A runtime type mismatch (the plane sent a string where a number was
//!   expected) returns error.BadValue; the evaluator counts it against the
//!   node and lets the wave die there. Wire-time checking catches what it
//!   can; the plane is dynamically typed by nature.

const std = @import("std");
const struple = @import("struple");
const types = @import("types.zig");
const registry = @import("registry.zig");

const EvalCtx = registry.EvalCtx;
const EvalError = registry.EvalError;
const Emit = registry.Emit;
const Tag = types.Tag;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn num(ctx: *EvalCtx, i: usize) EvalError!f64 {
    const v = ctx.in[i] orelse return error.BadValue;
    return types.asNumber(v) orelse error.BadValue;
}

fn boolean(ctx: *EvalCtx, i: usize) EvalError!bool {
    const v = ctx.in[i] orelse return error.BadValue;
    return types.asBool(v) orelse error.BadValue;
}

fn raw(ctx: *EvalCtx, i: usize) EvalError![]const u8 {
    return ctx.in[i] orelse error.BadValue;
}

fn emitF64(ctx: *EvalCtx, v: f64) EvalError!Emit {
    try ctx.out[0].appendF64(v);
    return Emit.first;
}

fn emitBool(ctx: *EvalCtx, v: bool) EvalError!Emit {
    try ctx.out[0].appendBool(v);
    return Emit.first;
}

/// Un-escape a container element's framed payload and return the inner
/// element stream (arena-owned).
fn innerOf(ctx: *EvalCtx, encoded: []const u8) EvalError![]const u8 {
    const v = struple.view(encoded);
    return (v.containedItems(ctx.arena) catch return error.BadValue) orelse error.BadValue;
}

// ---------------------------------------------------------------------------
// Flow
// ---------------------------------------------------------------------------

fn evalSelect(ctx: *EvalCtx) EvalError!Emit {
    const cond = try boolean(ctx, 0);
    try ctx.out[0].appendRaw(try raw(ctx, if (cond) 1 else 2));
    return Emit.first;
}

fn evalLerp(ctx: *EvalCtx) EvalError!Emit {
    const a = try num(ctx, 0);
    const b = try num(ctx, 1);
    const t = try num(ctx, 2);
    return emitF64(ctx, a + (b - a) * t);
}

fn evalWhere(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none; // gates pass arrivals, not re-reads
    if (!(try boolean(ctx, 1))) return Emit.none;
    try ctx.out[0].appendRaw(try raw(ctx, 0));
    return Emit.first;
}

fn evalPartition(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none;
    const input = try raw(ctx, 0);
    const side: u5 = if (try boolean(ctx, 1)) 0 else 1;
    try ctx.out[side].appendRaw(input);
    return Emit.bit(side);
}

fn evalChanged(ctx: *EvalCtx) EvalError!Emit {
    // value slots already compare-and-suppress upstream, so fresh == changed
    if (!ctx.in_fresh[0]) return Emit.none;
    try ctx.out[0].appendRaw(try raw(ctx, 0));
    return Emit.first;
}

fn evalLatch(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[1]) return Emit.none; // sample-and-hold on trigger
    try ctx.out[0].appendRaw(try raw(ctx, 0));
    return Emit.first;
}

// ---------------------------------------------------------------------------
// Events (value → occurrence adapters)
// ---------------------------------------------------------------------------

const side_unset: u8 = 0;

fn evalThreshold(ctx: *EvalCtx, comptime fire_when_below: bool) EvalError!Emit {
    const v = try num(ctx, 0);
    const t = try num(ctx, 1);
    const below: u8 = if (v < t) 2 else 1;
    const prev: u8 = if (ctx.state.items.len > 0) ctx.state.items[0] else side_unset;
    try ctx.setState(&.{below});
    const fire_side: u8 = if (fire_when_below) 2 else 1;
    if (prev != side_unset and prev != fire_side and below == fire_side) {
        try ctx.out[0].appendRaw(try raw(ctx, 0));
        return Emit.first;
    }
    return Emit.none;
}

fn evalDroppedBelow(ctx: *EvalCtx) EvalError!Emit {
    return evalThreshold(ctx, true);
}

fn evalRoseAbove(ctx: *EvalCtx) EvalError!Emit {
    return evalThreshold(ctx, false);
}

fn evalEdge(ctx: *EvalCtx) EvalError!Emit {
    const v = try boolean(ctx, 0);
    const now: u8 = if (v) 2 else 1;
    const prev: u8 = if (ctx.state.items.len > 0) ctx.state.items[0] else side_unset;
    try ctx.setState(&.{now});
    if (prev == 1 and now == 2) return emitBool(ctx, true);
    return Emit.none;
}

// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

fn binMath(comptime f: fn (f64, f64) f64) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            return emitF64(ctx, f(try num(ctx, 0), try num(ctx, 1)));
        }
    }.eval;
}

fn unMath(comptime f: fn (f64) f64) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            return emitF64(ctx, f(try num(ctx, 0)));
        }
    }.eval;
}

fn fAdd(a: f64, b: f64) f64 {
    return a + b;
}
fn fSub(a: f64, b: f64) f64 {
    return a - b;
}
fn fMul(a: f64, b: f64) f64 {
    return a * b;
}
fn fDiv(a: f64, b: f64) f64 {
    return a / b;
}
fn fMin(a: f64, b: f64) f64 {
    return @min(a, b);
}
fn fMax(a: f64, b: f64) f64 {
    return @max(a, b);
}
fn fAbs(v: f64) f64 {
    return @abs(v);
}
fn fFloor(v: f64) f64 {
    return @floor(v);
}
fn fRound(v: f64) f64 {
    return @round(v);
}

fn evalClamp(ctx: *EvalCtx) EvalError!Emit {
    const v = try num(ctx, 0);
    const lo = try num(ctx, 1);
    const hi = try num(ctx, 2);
    return emitF64(ctx, std.math.clamp(v, lo, hi));
}

fn cmpOp(comptime f: fn (f64, f64) bool) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            return emitBool(ctx, f(try num(ctx, 0), try num(ctx, 1)));
        }
    }.eval;
}

fn fLt(a: f64, b: f64) bool {
    return a < b;
}
fn fLe(a: f64, b: f64) bool {
    return a <= b;
}
fn fGt(a: f64, b: f64) bool {
    return a > b;
}
fn fGe(a: f64, b: f64) bool {
    return a >= b;
}

/// `=` / `!=` compare numerically when both sides are numbers (20 == 20.0),
/// byte-wise otherwise (canonical encoding makes that semantic equality
/// within a type class).
fn valuesEqual(a: []const u8, b: []const u8) bool {
    if (types.asNumber(a)) |na| {
        if (types.asNumber(b)) |nb| return na == nb;
    }
    return std.mem.eql(u8, a, b);
}

fn evalEq(ctx: *EvalCtx) EvalError!Emit {
    return emitBool(ctx, valuesEqual(try raw(ctx, 0), try raw(ctx, 1)));
}

fn evalNe(ctx: *EvalCtx) EvalError!Emit {
    return emitBool(ctx, !valuesEqual(try raw(ctx, 0), try raw(ctx, 1)));
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

fn evalRecord(ctx: *EvalCtx) EvalError!Emit {
    const n = ctx.in.len;
    const entries = try ctx.arena.alloc([2][]const u8, n);
    for (0..n) |i| {
        var kp = struple.Packer.init(ctx.arena);
        try kp.appendString(ctx.statics[i].word);
        entries[i] = .{ kp.bytes(), try raw(ctx, i) };
    }
    try ctx.out[0].appendMap(entries); // sorts by encoded key → canonical
    return Emit.first;
}

fn evalProject(ctx: *EvalCtx) EvalError!Emit {
    const inner = try innerOf(ctx, try raw(ctx, 0));
    var kp = struple.Packer.init(ctx.arena);
    try kp.appendString(ctx.statics[0].word);
    const m = struple.MapView.init(inner);
    const val = (m.get(kp.bytes()) catch return error.BadValue) orelse return Emit.none;
    try ctx.out[0].appendRaw(val);
    return Emit.first;
}

fn evalMerge(ctx: *EvalCtx) EvalError!Emit {
    var entries = std.ArrayListUnmanaged([2][]const u8).empty;
    inline for (0..2) |i| {
        const inner = try innerOf(ctx, try raw(ctx, i));
        var it = struple.MapView.init(inner).iterator();
        while (it.next() catch return error.BadValue) |e| {
            const found = for (entries.items) |*ex| {
                if (std.mem.eql(u8, ex[0], e.key)) break ex;
            } else null;
            if (found) |ex| {
                ex[1] = e.value; // right side wins
            } else {
                try entries.append(ctx.arena, .{ e.key, e.value });
            }
        }
    }
    try ctx.out[0].appendMap(entries.items);
    return Emit.first;
}

// ---------------------------------------------------------------------------
// Plane / util
// ---------------------------------------------------------------------------

fn evalSet(ctx: *EvalCtx) EvalError!Emit {
    try ctx.write(ctx.statics[0].path, try raw(ctx, 0));
    return Emit.none;
}

fn evalConst(ctx: *EvalCtx) EvalError!Emit {
    try ctx.out[0].appendRaw(ctx.statics[0].literal);
    return Emit.first;
}

fn evalTap(ctx: *EvalCtx) EvalError!Emit {
    const v = try raw(ctx, 0);
    ctx.log(ctx.statics[0].word, v);
    try ctx.out[0].appendRaw(v);
    return Emit.first;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

const p = struct {
    fn in(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty };
    }
    fn val(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .kind = .value };
    }
    fn occ(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .kind = .occurrence };
    }
};

const CORE = [_]registry.OpDef{
    // flow
    .{ .name = "select", .inputs = &.{ p.in("cond", Tag.boolean), p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .help = "cond ? a : b — all branches exist; one is chosen per tick.", .eval = evalSelect },
    .{ .name = "lerp", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number), p.in("t", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "a + (b - a) * t — the honest blend between select's hard edges.", .eval = evalLerp },
    .{ .name = "where", .inputs = &.{ p.in("in", Tag.any), p.in("pred", Tag.boolean) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "Pass arrivals of `in` while pred is true; otherwise silence.", .eval = evalWhere },
    .{ .name = "partition", .inputs = &.{ p.in("in", Tag.any), p.in("pred", Tag.boolean) }, .outputs = &.{ p.val("pass", Tag.any), p.val("fail", Tag.any) }, .help = "Route every arrival of `in` to exactly one side by pred.", .eval = evalPartition },
    .{ .name = "changed", .inputs = &.{p.in("in", Tag.any)}, .outputs = &.{p.occ("out", Tag.any)}, .help = "Emit an occurrence whenever the value actually changes.", .eval = evalChanged },
    .{ .name = "latch", .inputs = &.{ p.in("in", Tag.any), p.occ("trigger", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .help = "Sample-and-hold: emit the current `in` when `trigger` fires.", .eval = evalLatch },
    // events
    .{ .name = "dropped_below", .inputs = &.{ p.in("in", Tag.number), p.in("threshold", Tag.number) }, .outputs = &.{p.occ("out", Tag.number)}, .help = "Fire (with the value) when `in` crosses below threshold. First observation baselines silently.", .eval = evalDroppedBelow },
    .{ .name = "rose_above", .inputs = &.{ p.in("in", Tag.number), p.in("threshold", Tag.number) }, .outputs = &.{p.occ("out", Tag.number)}, .help = "Fire (with the value) when `in` crosses above threshold. First observation baselines silently.", .eval = evalRoseAbove },
    .{ .name = "edge", .inputs = &.{p.in("in", Tag.boolean)}, .outputs = &.{p.occ("out", Tag.boolean)}, .help = "Fire on the false→true transition.", .eval = evalEdge },
    // math
    .{ .name = "add", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "a + b.", .eval = binMath(fAdd) },
    .{ .name = "sub", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "a - b.", .eval = binMath(fSub) },
    .{ .name = "mul", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "a * b.", .eval = binMath(fMul) },
    .{ .name = "div", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "a / b (IEEE; division by zero yields ±inf).", .eval = binMath(fDiv) },
    .{ .name = "min", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "The smaller of a and b.", .eval = binMath(fMin) },
    .{ .name = "max", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "The larger of a and b.", .eval = binMath(fMax) },
    .{ .name = "clamp", .inputs = &.{ p.in("in", Tag.number), p.in("lo", Tag.number), p.in("hi", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "Clamp `in` to [lo, hi].", .eval = evalClamp },
    .{ .name = "abs", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.number)}, .help = "Absolute value.", .eval = unMath(fAbs) },
    .{ .name = "floor", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.number)}, .help = "Round toward −inf.", .eval = unMath(fFloor) },
    .{ .name = "round", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.number)}, .help = "Round to nearest.", .eval = unMath(fRound) },
    // comparators
    .{ .name = "=", .inputs = &.{ p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.boolean)}, .help = "Equality (numeric across int/float; byte-wise otherwise).", .eval = evalEq },
    .{ .name = "!=", .inputs = &.{ p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.boolean)}, .help = "Inequality.", .eval = evalNe },
    .{ .name = "<", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.boolean)}, .help = "a < b.", .eval = cmpOp(fLt) },
    .{ .name = "<=", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.boolean)}, .help = "a <= b.", .eval = cmpOp(fLe) },
    .{ .name = ">", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.boolean)}, .help = "a > b.", .eval = cmpOp(fGt) },
    .{ .name = ">=", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.boolean)}, .help = "a >= b.", .eval = cmpOp(fGe) },
    // records
    .{ .name = "record", .variadic = true, .outputs = &.{p.val("out", Tag.record)}, .help = "Record construction { field: stream, … } — a live tuple with named fields.", .eval = evalRecord },
    .{ .name = "project", .inputs = &.{p.in("in", Tag.record)}, .statics = &.{.{ .name = "field", .kind = .word }}, .outputs = &.{p.val("out", Tag.any)}, .help = "Field access on a record stream (`stats.mana`).", .eval = evalProject },
    .{ .name = "merge", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record) }, .outputs = &.{p.val("out", Tag.record)}, .help = "Merge two records; b's fields win.", .eval = evalMerge },
    // plane / util
    .{ .name = "set", .inputs = &.{p.in("in", Tag.any)}, .statics = &.{.{ .name = "path", .kind = .path }}, .help = "Write the input to a plane path, through the host's write path.", .class = .effect, .eval = evalSet },
    .{ .name = "const", .statics = &.{.{ .name = "value", .kind = .literal }}, .outputs = &.{p.val("out", Tag.any)}, .help = "Emit a constant once at mount.", .eval = evalConst },
    .{ .name = "tap", .inputs = &.{p.in("in", Tag.any)}, .statics = &.{.{ .name = "label", .kind = .word }}, .outputs = &.{p.val("out", Tag.any)}, .help = "Debug passthrough: log the value to the host's log bus.", .eval = evalTap },
};

/// Register the core set. Call once per registry, before parsing anything —
/// the parser itself leans on `record` and `project`.
pub fn registerCore(reg: *registry.Registry) !void {
    for (CORE) |def| _ = try reg.register(def);
}

test "core ops register cleanly" {
    var reg = try registry.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try registerCore(&reg);
    try std.testing.expect(reg.find("select") != null);
    try std.testing.expect(reg.find("dropped_below") != null);
    try std.testing.expect(reg.find("<=") != null);
    try std.testing.expect(reg.find("record") != null);
}
