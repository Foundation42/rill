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

/// Emit pre-encoded bytes on output port `i`. appendRaw validates structure;
/// foreign bytes that fail it surface as BadValue against this node (counted,
/// wave dies — same policy as any runtime type mismatch).
fn splice(ctx: *EvalCtx, i: usize, encoded: []const u8) EvalError!void {
    ctx.out[i].appendRaw(encoded) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadValue,
    };
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
    try splice(ctx, 0, try raw(ctx, if (cond) 1 else 2));
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
    try splice(ctx, 0, try raw(ctx, 0));
    return Emit.first;
}

fn evalPartition(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none;
    const input = try raw(ctx, 0);
    const side: u5 = if (try boolean(ctx, 1)) 0 else 1;
    try splice(ctx, side, input);
    return Emit.bit(side);
}

fn evalChanged(ctx: *EvalCtx) EvalError!Emit {
    // value slots already compare-and-suppress upstream, so fresh == changed
    if (!ctx.in_fresh[0]) return Emit.none;
    try splice(ctx, 0, try raw(ctx, 0));
    return Emit.first;
}

fn evalLatch(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[1]) return Emit.none; // sample-and-hold on trigger
    try splice(ctx, 0, try raw(ctx, 0));
    return Emit.first;
}

// ---------------------------------------------------------------------------
// Events (value → occurrence adapters)
// ---------------------------------------------------------------------------

const side_unset: u8 = 0;

/// Each threshold op is **strict on its own comparison**, and the two are
/// mirror images: `dropped_below 20` fires crossing from ≥20 to <20,
/// `rose_above 20` from ≤20 to >20. Both sides of a crossing therefore agree
/// about where the boundary is, and neither fires on merely *arriving* at it.
///
/// The two used to share one `v < t` test, which made `rose_above t` mean
/// "reached t": `rose_above 0` on an enemy count fired when the count fell
/// back to 0 — when the last attacker LEFT — and never once when one arrived.
fn evalThreshold(ctx: *EvalCtx, comptime fire_when_below: bool) EvalError!Emit {
    const v = try num(ctx, 0);
    const t = try num(ctx, 1);
    const armed: u8 = 1; // the far side: the crossing has not happened
    const fired: u8 = 2; // past the threshold, strictly
    const side: u8 = if (if (fire_when_below) v < t else v > t) fired else armed;
    const prev: u8 = if (ctx.state.items.len > 0) ctx.state.items[0] else side_unset;
    try ctx.setState(&.{side});
    if (prev == armed and side == fired) {
        try splice(ctx, 0, try raw(ctx, 0));
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
// Temporal — time as fed data (agents doc §2). Nothing here reads a clock:
// `now` is ambient in the ctx, deadlines are absolute values on one of the
// two fed lanes (ns / frames), and future work arrives through the wheel.
// Every op tolerates a stale wake (its real deadline moved) by re-arming —
// that keeps the wheel a dumb multiset and the ops self-healing across
// restore. Node state is opaque little-endian bytes (same license the
// threshold ops already took); payloads inside stay struple elements.
// ---------------------------------------------------------------------------

fn dur(ctx: *EvalCtx, i: usize) EvalError!types.Duration {
    const v = ctx.in[i] orelse return error.BadValue;
    return types.asDuration(v) orelse error.BadValue;
}

fn deadlineAt(d: types.Duration, at: u64) registry.Deadline {
    return if (d.frames) .{ .frame = at } else .{ .ns = at };
}

/// State shape shared by sample/debounce/throttle/cooldown:
/// [lane u8][deadline u64 LE][pending bytes…] (pending may be empty).
const PendState = struct { until: u64, pending: []const u8 };

fn readPendState(ctx: *EvalCtx) PendState {
    const st = ctx.state.items;
    if (st.len < 9) return .{ .until = 0, .pending = "" };
    return .{ .until = std.mem.readInt(u64, st[1..9], .little), .pending = st[9..] };
}

fn writePendState(ctx: *EvalCtx, frames: bool, until: u64, pending: []const u8) EvalError!void {
    const buf = try ctx.arena.alloc(u8, 9 + pending.len);
    buf[0] = @intFromBool(frames);
    std.mem.writeInt(u64, buf[1..9], until, .little);
    @memcpy(buf[9..], pending);
    try ctx.setState(buf);
}

/// `sample <period>` — at most one emission per period, latest value wins.
/// Leading edge passes immediately; changes inside the window coalesce into
/// `pending` and the wheel delivers the trailing edge at the period boundary,
/// so a value stream is late but never wrong (a suppressed final change may
/// not go missing just because the input went quiet).
fn evalSample(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 1);
    const now = ctx.nowOn(d.frames);
    const st = readPendState(ctx);
    var until = st.until;
    var emit = Emit.none;
    var pending: []const u8 = "";
    if (ctx.in_fresh[0]) {
        const v = try raw(ctx, 0);
        if (now >= until) {
            try splice(ctx, 0, v);
            emit = Emit.first;
            until = now + d.count;
        } else {
            pending = try ctx.arena.dupe(u8, v);
            try ctx.wake(deadlineAt(d, until));
        }
    } else if (st.pending.len > 0) {
        if (now >= until) {
            try splice(ctx, 0, st.pending);
            emit = Emit.first;
            until = now + d.count;
        } else {
            pending = try ctx.arena.dupe(u8, st.pending);
            try ctx.wake(deadlineAt(d, until)); // stale wake: re-arm the truth
        }
    }
    try writePendState(ctx, d.frames, until, pending);
    return emit;
}

/// `debounce <quiet>` — pass only after a quiet period; a storm collapses to
/// its last edge. Every arrival restarts the quiet window and re-arms (the
/// wheel dedups exact repeats; a superseded entry stale-fires into silence).
fn evalDebounce(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 1);
    const now = ctx.nowOn(d.frames);
    const st = readPendState(ctx);
    var due = st.until;
    var emit = Emit.none;
    var pending: []const u8 = "";
    if (ctx.in_fresh[0]) {
        pending = try ctx.arena.dupe(u8, try raw(ctx, 0));
        due = now + d.count;
        try ctx.wake(deadlineAt(d, due));
    } else if (st.pending.len > 0) {
        if (now >= due) {
            try splice(ctx, 0, st.pending);
            emit = Emit.first;
        } else {
            pending = try ctx.arena.dupe(u8, st.pending);
            try ctx.wake(deadlineAt(d, due));
        }
    }
    try writePendState(ctx, d.frames, due, pending);
    return emit;
}

/// `throttle <window>` / `cooldown <window>` — one mechanism, two intents:
/// pass when the window has elapsed, then be deaf until it elapses again.
/// throttle rate-limits a stream; cooldown is "triggered, now get out of the
/// way". Eaten occurrences are gone (that is the point) — no wheel needed.
fn evalRateGate(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none;
    const d = try dur(ctx, 1);
    const now = ctx.nowOn(d.frames);
    const st = readPendState(ctx);
    if (now < st.until) return Emit.none;
    try splice(ctx, 0, try raw(ctx, 0));
    try writePendState(ctx, d.frames, now + d.count, "");
    return Emit.first;
}

/// Variable-length entry stream shared by window/delay:
/// [lane u8] then per entry [stamp u64 LE][len u32 LE][bytes].
const Stamped = struct { at: u64, v: []const u8 };

fn readStamped(ctx: *EvalCtx) EvalError!std.ArrayListUnmanaged(Stamped) {
    var list = std.ArrayListUnmanaged(Stamped).empty;
    const st = ctx.state.items;
    if (st.len < 1) return list;
    var i: usize = 1;
    while (i + 12 <= st.len) {
        const at = std.mem.readInt(u64, st[i..][0..8], .little);
        const len = std.mem.readInt(u32, st[i + 8 ..][0..4], .little);
        i += 12;
        if (i + len > st.len) return error.BadValue;
        try list.append(ctx.arena, .{ .at = at, .v = st[i .. i + len] });
        i += len;
    }
    if (i != st.len) return error.BadValue;
    return list;
}

fn writeStamped(ctx: *EvalCtx, frames: bool, entries: []const Stamped) EvalError!void {
    var size: usize = 1;
    for (entries) |e| size += 12 + e.v.len;
    const buf = try ctx.arena.alloc(u8, size);
    buf[0] = @intFromBool(frames);
    var i: usize = 1;
    for (entries) |e| {
        std.mem.writeInt(u64, buf[i..][0..8], e.at, .little);
        std.mem.writeInt(u32, buf[i + 8 ..][0..4], @intCast(e.v.len), .little);
        i += 12;
        @memcpy(buf[i .. i + e.v.len], e.v);
        i += e.v.len;
    }
    try ctx.setState(buf);
}

/// `window <span>` — rolling buffer over fed time, emitted as an array (feeds
/// `stats`). Entries age out through the wheel, so a spike decays on schedule
/// even if the input goes quiet; an emptied window emits the empty array.
fn evalWindow(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 1);
    const now = ctx.nowOn(d.frames);
    const old = try readStamped(ctx);
    var kept = std.ArrayListUnmanaged(Stamped).empty;
    for (old.items) |e| {
        if (e.at + d.count > now) try kept.append(ctx.arena, e);
    }
    if (ctx.in_fresh[0]) {
        try kept.append(ctx.arena, .{ .at = now, .v = try ctx.arena.dupe(u8, try raw(ctx, 0)) });
    }
    var inner = struple.Packer.init(ctx.arena);
    for (kept.items) |e| inner.appendRaw(e.v) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadValue,
    };
    try ctx.out[0].appendArray(inner.bytes());
    if (kept.items.len > 0) try ctx.wake(deadlineAt(d, kept.items[0].at + d.count));
    try writeStamped(ctx, d.frames, kept.items);
    return Emit.first;
}

/// `stats` — {max, mean, min, n, stddev} over a numeric array (population
/// stddev). An empty window is all zeros with n = 0 — n is the honesty
/// marker, and decaying to zero is what lets a crossing detector re-arm.
fn evalStats(ctx: *EvalCtx) EvalError!Emit {
    const inner = try innerOf(ctx, try raw(ctx, 0));
    var vals = std.ArrayListUnmanaged(f64).empty;
    var r = struple.reader(inner);
    while (r.nextView() catch return error.BadValue) |e| {
        try vals.append(ctx.arena, types.asNumber(e) orelse return error.BadValue);
    }
    var sum: f64 = 0;
    var lo: f64 = 0;
    var hi: f64 = 0;
    for (vals.items, 0..) |v, i| {
        sum += v;
        if (i == 0) {
            lo = v;
            hi = v;
        } else {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
    }
    const n = vals.items.len;
    const mean: f64 = if (n > 0) sum / @as(f64, @floatFromInt(n)) else 0;
    var varsum: f64 = 0;
    for (vals.items) |v| varsum += (v - mean) * (v - mean);
    const stddev: f64 = if (n > 0) @sqrt(varsum / @as(f64, @floatFromInt(n))) else 0;

    const fields = [_]struct { []const u8, f64 }{
        .{ "max", hi }, .{ "mean", mean }, .{ "min", lo }, .{ "stddev", stddev },
    };
    var entries = std.ArrayListUnmanaged([2][]const u8).empty;
    for (fields) |f| {
        var kp = struple.Packer.init(ctx.arena);
        try kp.appendString(f[0]);
        var vp = struple.Packer.init(ctx.arena);
        try vp.appendF64(f[1]);
        try entries.append(ctx.arena, .{ kp.bytes(), vp.bytes() });
    }
    var kn = struple.Packer.init(ctx.arena);
    try kn.appendString("n");
    var vn = struple.Packer.init(ctx.arena);
    try vn.appendInt(@intCast(n));
    try entries.append(ctx.arena, .{ kn.bytes(), vn.bytes() });
    try ctx.out[0].appendMap(entries.items); // sorts keys → canonical
    return Emit.first;
}

/// `delay <by>` — emit each occurrence `by` later. Maturities landing on the
/// same tick collapse to the newest (an occurrence slot holds one value per
/// tick; keep-latest is the house policy for re-derivable notifications).
fn evalDelay(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 1);
    const now = ctx.nowOn(d.frames);
    const old = try readStamped(ctx);
    var queue = std.ArrayListUnmanaged(Stamped).empty;
    try queue.appendSlice(ctx.arena, old.items);
    if (ctx.in_fresh[0]) {
        const due = now + d.count;
        try queue.append(ctx.arena, .{ .at = due, .v = try ctx.arena.dupe(u8, try raw(ctx, 0)) });
        try ctx.wake(deadlineAt(d, due));
    }
    var ripe: ?Stamped = null;
    var left = std.ArrayListUnmanaged(Stamped).empty;
    for (queue.items) |e| {
        if (e.at <= now) {
            if (ripe == null or e.at >= ripe.?.at) ripe = e; // latest due wins, later insert breaks ties
        } else {
            try left.append(ctx.arena, e);
        }
    }
    var emit = Emit.none;
    if (ripe) |e| {
        try splice(ctx, 0, e.v);
        emit = Emit.first;
    }
    if (left.items.len > 0) {
        var soonest = left.items[0].at;
        for (left.items[1..]) |e| soonest = @min(soonest, e.at);
        try ctx.wake(deadlineAt(d, soonest));
    }
    try writeStamped(ctx, d.frames, left.items);
    return emit;
}

/// `every <period>` — the metronome: a wheel-driven occurrence source, the
/// first op that emits without being roused. Fires at mount (leading edge,
/// like `sample`), then re-arms one period ahead of each firing. Cadence is
/// anchored to the last actual firing, not to an ideal grid: after a gap in
/// fed time it fires ONCE and resumes, rather than bursting to "catch up" —
/// a brazier fed by `every 1f` should return to steady state after a pause,
/// not spike above it delivering deposits the pause never earned. (Replay
/// feeds the same time sequence, so either rule is deterministic; this one
/// is the honest physics.) A zero period is refused: a metronome with no
/// interval is a storm wearing a duration.
fn evalEvery(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 0);
    if (d.count == 0) return error.BadValue;
    const now = ctx.nowOn(d.frames);
    const st = readPendState(ctx); // until = next due; empty state reads 0 = due now
    if (now >= st.until) {
        const due = now + d.count;
        try ctx.wake(deadlineAt(d, due));
        try writePendState(ctx, d.frames, due, "");
        return emitBool(ctx, true);
    }
    try ctx.wake(deadlineAt(d, st.until)); // stale wake: re-arm the truth
    return Emit.none;
}

/// `arm` / `disarm` — the explicit latch gate. Pass occurrences while open;
/// `off` closes, `on` opens (`arm` starts open, `disarm` starts closed).
/// Controls apply before the passthrough, and `on` beats `off` on a
/// same-tick tie — fail-safe toward armed: a watchdog left off is the quiet
/// failure.
fn gateEval(comptime initially_open: bool) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            var open = if (ctx.state.items.len > 0) ctx.state.items[0] == 1 else initially_open;
            if (ctx.in_fresh[1]) open = false;
            if (ctx.in_fresh[2]) open = true;
            try ctx.setState(&.{@intFromBool(open)});
            if (!ctx.in_fresh[0] or !open) return Emit.none;
            try splice(ctx, 0, try raw(ctx, 0));
            return Emit.first;
        }
    }.eval;
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
    try splice(ctx, 0, val);
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

/// The sink shape, shared by `set` and `notify`: `<verb> <path> [value]`.
///
/// **Piped value: write what's flowing. Bound value: write this, because
/// something flowed.** Port 0 is always the rousing — it decides *when* — and
/// when `value` is bound it decides *what*, which is the only spelling for
/// "on a rousing, write a constant":
///
///     signals/horn | set gate/drawbridge.target 1
///     visible_enemies | rose_above 0 | notify signals/horn { kind: "approach" }
///
/// Without it that sentence takes three nodes to say one word — hold the
/// constant in a `latch`, sample it on the rousing, pipe it to the sink —
/// which is what Ironwood's gate.rill did until this port existed.
///
/// Unpiped, the value binds port 0 and is both rousing and payload, so
/// `set p 3` is unchanged. Unbound, the in-flowing value is written, so
/// `x | set p` is unchanged. A change in `value` alone is not a write: the
/// payload says what, the rousing says when — the same rule `inc` applies to
/// `by`, for the same reason.
fn evalSink(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none;
    try ctx.write(ctx.statics[0].path, ctx.in[1] orelse try raw(ctx, 0));
    return Emit.none;
}

/// `inc` is a SINK WITH NO PAYLOAD: port 0 is the rousing, not the amount.
/// That is why it does not read like `set`, and it is the honest signature —
/// an increment takes nothing from the stream, so binding the in-flowing value
/// as the amount would make `also { inc … }` count enemies-per-sighting
/// instead of sightings. `by` is required for the same reason `also` refuses a
/// branch that cannot rouse: `inc p 5` unpiped would otherwise bind 5 to the
/// rousing port, silently default the amount to 1, and be wrong in a way
/// nothing could see.
fn evalInc(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none; // a change in `by` alone is not a rousing
    _ = try num(ctx, 1); // numeric slots only — the gate, stated once
    try ctx.writeDelta(ctx.statics[0].path, try raw(ctx, 1));
    return Emit.none;
}

/// `cast <$channel> [value] radius <r> at <pos> [decay <d>]` — the field
/// sink (rill-casts.md §6): deposit a scalar into the caster's owned space,
/// absorbed by whatever is there to absorb it. The sink shape holds — port 0
/// is the rousing, a bound `value` is the payload — and the two keyword ports
/// follow the sink rule too: a change in `at` or `decay` alone is not a cast
/// (a moving caster's position updates live without re-rousing). Unpiped, the
/// intensity binds port 0 and is both rousing and payload, so a bare
/// `cast $torchlight 0.8 radius 12 at …` deposits ONCE, at tick 0, then
/// leaks away — a standing caster puts `every 1f` in front.
fn evalCast(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none;
    const amp_bytes = ctx.in[1] orelse try raw(ctx, 0);
    const amplitude = types.asNumber(amp_bytes) orelse return error.BadValue;
    const pos = try raw(ctx, 2); // `at` — required; a cast lands somewhere
    const decay: ?types.Duration = if (ctx.in[3]) |b|
        (types.asDuration(b) orelse return error.BadValue)
    else
        null;
    const radius = types.asNumber(ctx.statics[1].literal) orelse return error.BadValue;
    if (!(radius > 0)) return error.BadValue;
    try ctx.cast(.{
        .channel = ctx.statics[0].channel,
        .amplitude = amplitude,
        .pos = pos,
        .radius = radius,
        .decay = decay,
    });
    return Emit.none;
}

fn evalConst(ctx: *EvalCtx) EvalError!Emit {
    try splice(ctx, 0, ctx.statics[0].literal);
    return Emit.first;
}

fn evalTap(ctx: *EvalCtx) EvalError!Emit {
    const v = try raw(ctx, 0);
    ctx.log(ctx.statics[0].word, v);
    try splice(ctx, 0, v);
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
    fn optOcc(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .kind = .occurrence, .optional = true };
    }
    fn opt(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .optional = true };
    }
    fn kwIn(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .kw = true };
    }
    fn kwOpt(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .optional = true, .kw = true };
    }
};

const CORE = [_]registry.OpDef{
    // flow
    .{ .name = "select", .inputs = &.{ p.in("cond", Tag.boolean), p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .help = "cond ? a : b — all branches exist; one is chosen per tick.", .eval = evalSelect },
    .{ .name = "lerp", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number), p.in("t", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .help = "a + (b - a) * t — the honest blend between select's hard edges.", .eval = evalLerp },
    .{ .name = "where", .inputs = &.{ p.in("in", Tag.any), p.in("pred", Tag.boolean) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "Pass arrivals of `in` while pred is true; otherwise silence.", .class = .reads, .eval = evalWhere },
    .{ .name = "partition", .inputs = &.{ p.in("in", Tag.any), p.in("pred", Tag.boolean) }, .outputs = &.{ p.val("pass", Tag.any), p.val("fail", Tag.any) }, .help = "Route every arrival of `in` to exactly one side by pred.", .class = .reads, .eval = evalPartition },
    .{ .name = "changed", .inputs = &.{p.in("in", Tag.any)}, .outputs = &.{p.occ("out", Tag.any)}, .help = "Emit an occurrence whenever the value actually changes.", .class = .reads, .eval = evalChanged },
    .{ .name = "latch", .inputs = &.{ p.in("in", Tag.any), p.occ("trigger", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .help = "Sample-and-hold: emit the current `in` when `trigger` fires.", .class = .reads, .eval = evalLatch },
    // events
    .{ .name = "dropped_below", .inputs = &.{ p.in("in", Tag.number), p.in("threshold", Tag.number) }, .outputs = &.{p.occ("out", Tag.number)}, .help = "Fire (with the value) when `in` crosses below threshold. First observation baselines silently.", .class = .reads, .eval = evalDroppedBelow },
    .{ .name = "rose_above", .inputs = &.{ p.in("in", Tag.number), p.in("threshold", Tag.number) }, .outputs = &.{p.occ("out", Tag.number)}, .help = "Fire (with the value) when `in` crosses above threshold. First observation baselines silently.", .class = .reads, .eval = evalRoseAbove },
    .{ .name = "edge", .inputs = &.{p.in("in", Tag.boolean)}, .outputs = &.{p.occ("out", Tag.boolean)}, .help = "Fire on the false→true transition.", .class = .reads, .eval = evalEdge },
    // temporal — durations are 5s / 250ms / 2m / 3f literals; time is fed, never read
    .{ .name = "sample", .inputs = &.{ p.in("in", Tag.any), p.in("period", Tag.duration) }, .outputs = &.{p.val("out", Tag.any)}, .help = "At most one emission per period, latest value wins — leading edge immediate, trailing edge via the wheel.", .class = .reads, .eval = evalSample },
    .{ .name = "debounce", .inputs = &.{ p.occ("in", Tag.any), p.in("quiet", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "Pass only after a quiet period; storms collapse to their last edge.", .class = .reads, .eval = evalDebounce },
    .{ .name = "throttle", .inputs = &.{ p.occ("in", Tag.any), p.in("window", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "First occurrence passes, the rest are eaten for the window.", .class = .reads, .eval = evalRateGate },
    .{ .name = "cooldown", .inputs = &.{ p.occ("in", Tag.any), p.in("window", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "Pass one, then deaf for the window — triggered, now get out of the way.", .class = .reads, .eval = evalRateGate },
    .{ .name = "window", .inputs = &.{ p.in("in", Tag.any), p.in("span", Tag.duration) }, .outputs = &.{p.val("out", Tag.array)}, .help = "Rolling buffer over fed time, emitted as an array; entries age out on schedule even when the input is quiet.", .class = .reads, .eval = evalWindow },
    .{ .name = "stats", .inputs = &.{p.in("in", Tag.array)}, .outputs = &.{p.val("out", Tag.record)}, .help = "{max, mean, min, n, stddev} over a numeric array; empty in ⇒ zeros with n = 0.", .eval = evalStats },
    .{ .name = "delay", .inputs = &.{ p.occ("in", Tag.any), p.in("by", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "Emit each occurrence `by` later; same-tick maturities collapse to the newest.", .class = .reads, .eval = evalDelay },
    .{ .name = "every", .inputs = &.{p.in("period", Tag.duration)}, .outputs = &.{p.occ("out", Tag.boolean)}, .help = "Occurrence source on a cadence: fires at mount, then once per period of fed time. `every 1f { cast … }` is the standing-caster idiom.", .class = .reads, .eval = evalEvery },
    // `in` is optional on the gates: controls must latch even before the
    // stream first flows — a required port would silently discard an `off`
    // that fired ahead of the first occurrence (the all-inputs guard skips
    // nodes with a missing required input).
    .{ .name = "arm", .inputs = &.{ p.optOcc("in", Tag.any), p.optOcc("off", Tag.any), p.optOcc("on", Tag.any) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "Latch gate, initially open: pass occurrences while armed; `off` closes, `on` re-opens (on wins a tie).", .class = .reads, .eval = gateEval(true) },
    .{ .name = "disarm", .inputs = &.{ p.optOcc("in", Tag.any), p.optOcc("off", Tag.any), p.optOcc("on", Tag.any) }, .outputs = &.{p.occ("out", Tag.any)}, .help = "Latch gate, initially closed: silent until `on` arms it; `off` closes again (on wins a tie).", .class = .reads, .eval = gateEval(false) },
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
    .{ .name = "set", .inputs = &.{ p.in("in", Tag.any), p.opt("value", Tag.any) }, .statics = &.{.{ .name = "path", .kind = .path }}, .help = "Write to a plane path — `set <path> [value]`; piped, the input is the rousing and `value` is what gets written.", .class = .effect, .eval = evalSink },
    // `notify` IS `set` — same ports, same write, same eval — and it is worth
    // saying that they diverged for exactly one day and came back. `notify`
    // grew the optional payload port first, because the pipe took its only
    // port and the canonical sentinel was unsayable; `set` met the identical
    // wall one scenario later ("on the alarm, raise the drawbridge" is a
    // constant on a rousing), so the port became the sink SHAPE rather than
    // one op's exception.
    //
    // What remains is intent, which is the whole reason `notify` exists: a
    // write to a mailbox path already follows the mailbox's policy (append,
    // count, deliver every one), so `notify defense/alerts` says "this is a
    // sighting" where `set` would read as "this is the state".
    .{ .name = "notify", .inputs = &.{ p.in("in", Tag.any), p.opt("value", Tag.any) }, .statics = &.{.{ .name = "path", .kind = .path }}, .help = "Write an occurrence to a plane path — `notify <path> [value]`; same write as `set`, states the intent.", .class = .effect, .eval = evalSink },
    // The third write kind. `plane.x | add 1 | set plane.x` reads a path it
    // writes, so the cycle check rightly refuses it — which leaves counters
    // inexpressible. A blind delta reads nothing and passes legitimately.
    .{ .name = "inc", .inputs = &.{ p.occ("in", Tag.any), p.in("by", Tag.number) }, .statics = &.{.{ .name = "path", .kind = .path }}, .help = "Add `by` to a plane path each time the input rouses — a blind delta: no read, commutative, order-independent.", .class = .effect, .eval = evalInc },
    // The field sink. `channel` is a `.channel` static, not a `.path`, so a
    // cast never enters the write list — correctly: fields have no read side
    // inside rill (readings come from a standpoint, §9), so there is no loop
    // for the cycle check to miss. `at`/`decay` are keyword ports: the word
    // disambiguates what a positional grammar cannot (`cast $alarm 30` —
    // payload or radius?).
    .{ .name = "cast", .inputs = &.{ p.in("in", Tag.any), p.opt("value", Tag.any), p.kwIn("at", Tag.any), p.kwOpt("decay", Tag.duration) }, .statics = &.{ .{ .name = "channel", .kind = .channel }, .{ .name = "radius", .kind = .literal, .kw = true } }, .help = "Deposit into a field channel — `cast $chan [value] radius <r> at <pos> [decay <d>]`; piped, the input is the rousing.", .class = .effect, .eval = evalCast },
    .{ .name = "const", .statics = &.{.{ .name = "value", .kind = .literal }}, .outputs = &.{p.val("out", Tag.any)}, .help = "Emit a constant once at mount.", .eval = evalConst },
    .{ .name = "tap", .inputs = &.{p.in("in", Tag.any)}, .statics = &.{.{ .name = "label", .kind = .word }}, .outputs = &.{p.val("out", Tag.any)}, .help = "Debug passthrough: log the value to the host's log bus.", .class = .reads, .eval = evalTap },
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
