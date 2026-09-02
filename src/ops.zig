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
const plane = @import("plane.zig");
const rowk = @import("row.zig");

const EvalCtx = registry.EvalCtx;
const EvalError = registry.EvalError;
const Emit = registry.Emit;
const Tag = types.Tag;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// The four accessors every operator reaches for. They refuse IN WORDS,
// naming the op and the port — which is why 21 refusal paths that used to be
// a bare `BadValue` now say something without any of them being touched.
// (The refusals gate is what found them; the accessors are where the fix
// belongs, because a per-op fix would have been 21 chances to forget.)
fn num(ctx: *EvalCtx, i: usize) EvalError!f64 {
    const v = ctx.in[i] orelse return ctx.refuse("{s}: port '{s}' has no value yet", .{ ctx.op.name, ctx.portName(i) });
    return types.asNumber(v) orelse ctx.refuse("{s}: port '{s}' is {s}, not a number", .{ ctx.op.name, ctx.portName(i), describeTop(ctx, v) });
}

fn boolean(ctx: *EvalCtx, i: usize) EvalError!bool {
    const v = ctx.in[i] orelse return ctx.refuse("{s}: port '{s}' has no value yet", .{ ctx.op.name, ctx.portName(i) });
    return types.asBool(v) orelse ctx.refuse("{s}: port '{s}' is {s}, not a boolean", .{ ctx.op.name, ctx.portName(i), describeTop(ctx, v) });
}

fn raw(ctx: *EvalCtx, i: usize) EvalError![]const u8 {
    return ctx.in[i] orelse ctx.refuse("{s}: port '{s}' has no value yet", .{ ctx.op.name, ctx.portName(i) });
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
    return (v.containedItems(ctx.arena) catch null) orelse
        ctx.refuse("{s}: expected a record or an array, got {s}", .{ ctx.op.name, describeTop(ctx, encoded) });
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
    // The PIPED value is `t` (tier-2 §2.4, flipped while the corpus held
    // zero callers): "s, lerped between 0.5 and 1.5" is `s | lerp 0.5 1.5`.
    // The old order (a b t) forced every piped use to bind all three.
    const t = try num(ctx, 0);
    const a = try num(ctx, 1);
    const b = try num(ctx, 2);
    return emitF64(ctx, a + (b - a) * t);
}

fn fAnd(a: bool, b: bool) bool {
    return a and b;
}
fn fOr(a: bool, b: bool) bool {
    return a or b;
}
fn fNot(a: bool) bool {
    return !a;
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
    const v = ctx.in[i] orelse return ctx.refuse("{s}: port '{s}' has no value yet", .{ ctx.op.name, ctx.portName(i) });
    return types.asDuration(v) orelse ctx.refuse("{s}: port '{s}' is {s}, not a duration — durations carry a unit (5s, 250ms, 3f)", .{ ctx.op.name, ctx.portName(i), describeTop(ctx, v) });
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
    var idx: usize = 0;
    while (r.nextView() catch return ctx.refuse("stats: the input is a malformed array", .{})) |e| : (idx += 1) {
        try vals.append(ctx.arena, types.asNumber(e) orelse
            return ctx.refuse("stats: element [{d}] is {s}, not a number", .{ idx, describeTop(ctx, e) }));
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
    if (d.count == 0) return ctx.refuse("every: the period is zero — a metronome with no interval would fire forever", .{});
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
// Tier 2, beat 1a — time as a value, and the registers.
//
// The family confirmed by the recon (§0): state INSIDE an operator is legal
// under §4.4 because the cycle check is a cross product over two lists of
// plane paths and op state is not a path. `window`, `debounce` and the gates
// have held state since v0; these are the next customers, not a new
// mechanism.
//
// What is new is that these operators re-arm THEMSELVES: a register with a
// target it has not reached asks the wheel to wake it on the next tick of its
// own lane, so it converges without anything upstream moving. Three rules
// keep that from being a cycle wearing a hat:
//
//   1. **Every ticker stops.** `ease` stops inside ε of its target, `ramp`
//      stops at its end, `diff` stops when the rate is zero, `integrate`
//      stops at its clamp. A gate per op watches the eval counter STOP
//      rising — ε is not decoration.
//   2. **The re-arm is `now + 1` on the op's own lane** (the lane its
//      duration named, exactly as `every` picks it). A tick where that lane
//      did not advance simply doesn't fire the entry — `expireWheel`
//      consumes only what is due — so a missed wake is free and
//      self-healing: the node fires on the first tick that actually moved,
//      which is the first tick its output could differ on.
//   3. **The epoch lives in op state, baselined on first eval.** Not on the
//      Runtime: `restore` rebuilds from a dump without ticking and takes
//      `now` from MountOpts, so a runtime-held epoch would re-seed and
//      `clock` would jump. Tick 0 evaluates every node, so first-eval and
//      mount coincide and the baseline is exact.
// ---------------------------------------------------------------------------

/// Register state: [lane u8][epoch u64 LE][a f64 LE][b f64 LE][flags u8].
/// One shape for the whole family — `a`/`b` mean different things per op
/// (ease: last output, unused; ramp: from, to; diff: last value, last rate;
/// integrate: accumulator, unused) and `epoch` is the op's own zero. Opaque
/// little-endian like the temporal ops' state, for the same reason: it is
/// dumped and restored verbatim and never read by anything but its op.
const RegState = struct {
    frames: bool = false,
    at: u64 = 0, // last-eval time on the lane (or the epoch, for sources)
    a: f64 = 0,
    b: f64 = 0,
    started: bool = false,

    const size = 1 + 8 + 8 + 8 + 1;

    fn read(ctx: *EvalCtx) RegState {
        const st = ctx.state.items;
        if (st.len < size) return .{};
        return .{
            .frames = st[0] == 1,
            .at = std.mem.readInt(u64, st[1..9], .little),
            .a = @bitCast(std.mem.readInt(u64, st[9..17], .little)),
            .b = @bitCast(std.mem.readInt(u64, st[17..25], .little)),
            .started = st[25] == 1,
        };
    }

    fn write(self: RegState, ctx: *EvalCtx) EvalError!void {
        var buf: [size]u8 = undefined;
        buf[0] = @intFromBool(self.frames);
        std.mem.writeInt(u64, buf[1..9], self.at, .little);
        std.mem.writeInt(u64, buf[9..17], @as(u64, @bitCast(self.a)), .little);
        std.mem.writeInt(u64, buf[17..25], @as(u64, @bitCast(self.b)), .little);
        buf[25] = @intFromBool(self.started);
        try ctx.setState(&buf);
    }
};

/// Wake on the next tick of `lane`. See rule 2 above.
fn armNextTick(ctx: *EvalCtx, frames: bool) EvalError!void {
    try ctx.wake(if (frames) .{ .frame = ctx.now_frame + 1 } else .{ .ns = ctx.now_ns + 1 });
}

/// Seconds between two stamps on a lane. The frame lane has no seconds, so a
/// frame-lane register measures in frames and says so in its help — mixing
/// the two would be the faked `3f`≈50ms the duration grammar exists to
/// refuse.
fn elapsed(frames: bool, from: u64, to: u64) f64 {
    const d: f64 = @floatFromInt(to -| from);
    return if (frames) d else d / 1_000_000_000.0;
}

/// The convergence cutoff, shared by `ease` and `diff` (ruled: per-op
/// default, not a knob). Relative above 1 and absolute below it, so a
/// register on metres and a register on an exposure both stop, and one on a
/// value in the millions still stops rather than ticking forever.
const EPS: f64 = 1e-4;

fn converged(target: f64, current: f64) bool {
    const scale = @max(1.0, @abs(target));
    return @abs(target - current) <= EPS * scale;
}

// -- sources ----------------------------------------------------------------

/// `clock` / `frame` — fed time as a value, since mount. Program-relative
/// (so replay is clean and two programs mounted a second apart do not share
/// a phase) and epoch-in-state (so restore does not jump).
fn timeSource(comptime frames: bool) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            const now = ctx.nowOn(frames);
            var st = RegState.read(ctx);
            if (!st.started) st = .{ .frames = frames, .at = now, .started = true };
            try st.write(ctx);
            try armNextTick(ctx, frames);
            return emitF64(ctx, elapsed(frames, st.at, now));
        }
    }.eval;
}

// -- waveforms --------------------------------------------------------------

const WAVE_SHAPES = [_][]const u8{ "sine", "tri", "saw", "square" };

/// The one waveform function. `lfo` and `wave` both call it and cannot drift:
/// `lfo` computes phase from its own epoch, `wave` from the piped seconds,
/// and a gate asserts the two forms are bit-identical over a fed sequence.
/// Phase in, 0..1 out — every shape leaves the unit interval, which is what
/// makes `| range lo hi` the universal exit.
fn waveAt(ctx: *EvalCtx, shape: []const u8, phase_in: f64) EvalError!f64 {
    const ph = phase_in - @floor(phase_in); // fract: phase is modular
    if (std.mem.eql(u8, shape, "sine")) return 0.5 - 0.5 * @cos(ph * std.math.tau);
    if (std.mem.eql(u8, shape, "tri")) return 1.0 - @abs(2.0 * ph - 1.0);
    if (std.mem.eql(u8, shape, "saw")) return ph;
    if (std.mem.eql(u8, shape, "square")) return if (ph < 0.5) 0.0 else 1.0;
    // Parse checks `one_of` for a literal; a STREAM bound here can only be
    // caught now, and it says what it would have accepted.
    return ctx.refuse("{s}: '{s}' is not a waveform — expected one of: sine, tri, saw, square", .{ ctx.op.name, shape });
}

/// Seconds (or frames) per cycle, from a duration on either lane. A frame
/// duration on `wave`'s period means the piped `t` is counted in frames —
/// `frame | wave saw 120f` is a two-second cycle at 60fps and says so.
fn periodOf(d: types.Duration) EvalError!f64 {
    if (d.count == 0) return error.BadValue; // caller refuses in words
    const c: f64 = @floatFromInt(d.count);
    return if (d.frames) c else c / 1_000_000_000.0;
}

/// `wave <shape> <period>` — piped t (seconds on the real lane, frames on the
/// frame lane) shaped into 0..1. Pure: same t, same answer, no state, no
/// wheel. This is the half of `lfo` that composes — anything that produces a
/// number can drive it.
fn evalWave(ctx: *EvalCtx) EvalError!Emit {
    const t = try num(ctx, 0);
    const shape = types.asString(try raw(ctx, 1)) orelse
        return ctx.refuse("wave: port 'shape' is {s}, not a waveform name", .{describeTop(ctx, try raw(ctx, 1))});
    const period = try periodOf(try dur(ctx, 2));
    return emitF64(ctx, try waveAt(ctx, shape, t / period));
}

/// `lfo <shape> <period> [phase <p>]` — the source. Sugar over `clock | wave`
/// in the sense that matters: the SAME `waveAt`, so the two spellings cannot
/// diverge. It exists as its own op because "an LFO at four seconds" is how
/// people say it, and because a source that owns its epoch is one node
/// instead of two.
fn evalLfo(ctx: *EvalCtx) EvalError!Emit {
    const shape = types.asString(try raw(ctx, 0)) orelse
        return ctx.refuse("lfo: port 'shape' is {s}, not a waveform name", .{describeTop(ctx, try raw(ctx, 0))});
    const d = try dur(ctx, 1);
    const period = try periodOf(d);
    const phase: f64 = if (ctx.in[2] != null) try num(ctx, 2) else 0;
    const now = ctx.nowOn(d.frames);
    var st = RegState.read(ctx);
    if (!st.started) st = .{ .frames = d.frames, .at = now, .started = true };
    try st.write(ctx);
    try armNextTick(ctx, d.frames);
    return emitF64(ctx, try waveAt(ctx, shape, elapsed(d.frames, st.at, now) / period + phase));
}

// -- registers --------------------------------------------------------------

/// `ease <tau> [up <t>] [down <t>]` — the leaky integrator, and the smoother
/// rill lacked. Output chases input with time constant τ; `up`/`down` make it
/// asymmetric, which is the envelope follower (`abs | ease 20ms down 400ms`)
/// and the trigger envelope in two keyword ports.
///
/// It STOPS inside ε and does not snap (ruled 2026-08-25): an exponential
/// never arrives, so the honest end is "close enough, and quiet", not a step
/// on the last frame. `ramp` is the op with an end, and it lands its target
/// exactly.
fn evalEase(ctx: *EvalCtx) EvalError!Emit {
    const target = try num(ctx, 0);
    const tau_d = try dur(ctx, 1);
    const now = ctx.nowOn(tau_d.frames);
    var st = RegState.read(ctx);
    if (!st.started) {
        // Baseline AT the input: a register that started at zero would swing
        // from zero to the current reading on mount, which is a transient
        // nobody asked for.
        st = .{ .frames = tau_d.frames, .at = now, .a = target, .started = true };
        try st.write(ctx);
        return emitF64(ctx, target);
    }

    // Direction picks the constant; `tau` is the default for both sides.
    const rising = target > st.a;
    const chosen = if (rising and ctx.in[2] != null) try dur(ctx, 2) else if (!rising and ctx.in[3] != null) try dur(ctx, 3) else tau_d;
    const tau = try periodOf(chosen);

    // The billable window floors at the wheel's previous tick — integrate's
    // ruling (2026-08-29), and the same failure in a prettier dress: a
    // converged ease stops arming and sleeps, and a retarget after a quiet
    // minute computed k = 1 - exp(-60s/tau) ≈ 1 and SNAPPED — the glide it
    // exists to provide, skipped exactly when someone was looking at it.
    const start = @max(st.at, ctx.prevOn(st.frames));
    const dt = elapsed(st.frames, start, now);
    // 1 - exp(-dt/tau): the exact leak over dt, so the answer does not depend
    // on how often the wheel happened to wake us. A per-tick constant would
    // make the same fade take different times at different frame rates.
    const k = 1.0 - @exp(-dt / tau);
    const next = st.a + (target - st.a) * k;

    st.at = now;
    st.a = next;
    try st.write(ctx);
    if (!converged(target, next)) try armNextTick(ctx, st.frames);
    return emitF64(ctx, next);
}

/// `ramp <duration>` — on a new target, tween linearly to it over `duration`.
/// The "fade to". Unlike `ease` it has an end, so its last frame emits the
/// target EXACTLY and then it goes quiet (ruled 2026-08-25) — a fade that
/// stopped one ε short of full would be a visible band.
fn evalRamp(ctx: *EvalCtx) EvalError!Emit {
    const target = try num(ctx, 0);
    const d = try dur(ctx, 1);
    const span = try periodOf(d);
    const now = ctx.nowOn(d.frames);
    var st = RegState.read(ctx);

    if (!st.started) {
        // With no `from`, the first target is where we ARE: a ramp with
        // nowhere to start from must not animate out of nothing.
        //
        // With `from` (ratified 2026-08-25), it starts there and tweens to the
        // first target — which is the mount fade, and unlike `clock | div 2 |
        // range 0 1` it STOPS when it lands. That was the whole argument for
        // the register family and this was the one row where it was
        // unavailable.
        const start = if (ctx.in[2] == null) target else try num(ctx, 2);
        st = .{ .frames = d.frames, .at = now, .a = start, .b = target, .started = true };
        try st.write(ctx);
        if (start == target) return emitF64(ctx, target);
        try armNextTick(ctx, d.frames);
        return emitF64(ctx, start);
    }
    // A new target restarts the tween FROM WHERE WE ARE, not from the old
    // target: retargeting mid-fade must not jump.
    if (ctx.in_fresh[0] and target != st.b) {
        st.a = currentRamp(st, now, span);
        st.b = target;
        st.at = now;
    }
    const t = if (span <= 0) 1.0 else elapsed(st.frames, st.at, now) / span;
    if (t >= 1.0) {
        st.a = st.b;
        try st.write(ctx);
        return emitF64(ctx, st.b); // exactly the target, then quiet
    }
    try st.write(ctx);
    try armNextTick(ctx, st.frames);
    return emitF64(ctx, st.a + (st.b - st.a) * t);
}

fn currentRamp(st: RegState, now: u64, span: f64) f64 {
    const t = if (span <= 0) 1.0 else @min(1.0, elapsed(st.frames, st.at, now) / span);
    return st.a + (st.b - st.a) * t;
}

// ---------------------------------------------------------------------------
// Envelopes — `kick` and `adsr` (envelopes campaign, 2026-08-26)
//
// The register family's missing half. `ease` and `ramp` chase a target that
// something else supplies; an envelope is a shape an EVENT sets off, and
// before these two the only way to get one was to invent a gate path on the
// plane and a magic number for `ease` to fall from. That cost the tier-2
// re-probe two programs and was the biggest finding they made.
//
// Both are built out of straight segments with captured spans, which is where
// the family's one shared pin lives (Chris, 2026-08-26): **a parameter change
// applies to the NEXT segment and never retimes the one in flight.** A release
// that shortened mid-fall would jump, and a jump is what this whole family
// exists to avoid. So a segment's length is read from its port ONCE, when the
// segment starts, and lives in state until it ends.
//
// The segments are LINEAR, the `ramp` reading rather than the `ease` one: a
// duration names how long the segment takes, whatever level it starts from, so
// `kick 20ms 400ms` is twenty milliseconds up and four hundred down and reads
// as what it says. Curves compose on top — `kick 20ms 400ms | shape out` — and
// that is one word for one job rather than a curve knob on every envelope.
// ---------------------------------------------------------------------------

/// A segment in flight: where it started, where it is going, and how long it
/// was told to take. `span` is captured at the segment's start and never
/// re-read, which IS the pin above.
const EnvState = struct {
    frames: bool = false,
    at: u64 = 0, // segment start, lane units
    span: u64 = 0, // segment length, lane units — captured, never re-read
    from: f64 = 0,
    to: f64 = 0,
    phase: Phase = .idle,

    /// `sustain` and `release` are `adsr`'s only; `kick` uses attack and decay
    /// and stops. One enum for both so the shared arithmetic below has one
    /// thing to switch on.
    const Phase = enum(u8) { idle = 0, attack = 1, decay = 2, sustain = 3, release = 4 };

    const size = 1 + 8 + 8 + 8 + 8 + 1;

    fn read(ctx: *EvalCtx) EnvState {
        const st = ctx.state.items;
        if (st.len < size) return .{};
        return .{
            .frames = st[0] == 1,
            .at = std.mem.readInt(u64, st[1..9], .little),
            .span = std.mem.readInt(u64, st[9..17], .little),
            .from = @bitCast(std.mem.readInt(u64, st[17..25], .little)),
            .to = @bitCast(std.mem.readInt(u64, st[25..33], .little)),
            .phase = std.meta.intToEnum(Phase, st[33]) catch .idle,
        };
    }

    fn write(self: EnvState, ctx: *EvalCtx) EvalError!void {
        var buf: [size]u8 = undefined;
        buf[0] = @intFromBool(self.frames);
        std.mem.writeInt(u64, buf[1..9], self.at, .little);
        std.mem.writeInt(u64, buf[9..17], self.span, .little);
        std.mem.writeInt(u64, buf[17..25], @as(u64, @bitCast(self.from)), .little);
        std.mem.writeInt(u64, buf[25..33], @as(u64, @bitCast(self.to)), .little);
        buf[33] = @intFromEnum(self.phase);
        try ctx.setState(&buf);
    }

    /// How far through the segment `now` is, 0..1. A zero span is already done
    /// — `kick 0s 400ms` is a legal instant attack, not a division by zero.
    fn progress(self: EnvState, now: u64) f64 {
        if (self.span == 0) return 1.0;
        const d: f64 = @floatFromInt(now -| self.at);
        return @min(1.0, d / @as(f64, @floatFromInt(self.span)));
    }

    fn level(self: EnvState, now: u64) f64 {
        return self.from + (self.to - self.from) * self.progress(now);
    }

    /// Start a new segment at `at`, from wherever the envelope currently is.
    fn begin(self: *EnvState, phase: Phase, at: u64, from: f64, to: f64, span: u64) void {
        self.* = .{ .frames = self.frames, .at = at, .span = span, .from = from, .to = to, .phase = phase };
    }
};

/// Both durations of an envelope segment pair must be on ONE LANE. `kick 20ms
/// 3f` is two consecutive stretches of the same timeline measured in different
/// units, which is the contradiction the duration grammar exists to refuse —
/// unlike `ease`'s `up`/`down`, which are alternatives that never run together.
fn sameLane(ctx: *EvalCtx, a: types.Duration, ai: usize, b: types.Duration, bi: usize) EvalError!void {
    if (a.frames == b.frames) return;
    return ctx.refuse("{s}: '{s}' and '{s}' are on different time lanes — an envelope runs on one clock, so use seconds for both or frames for both", .{
        ctx.op.name, ctx.portName(ai), ctx.portName(bi),
    });
}

/// `kick <attack> <decay>` — an occurrence in, a one-shot envelope out. Rises
/// to 1 over `attack`, falls to 0 over `decay`, and stops.
///
/// **A retrigger restarts from the current level, never from zero** (Chris,
/// 2026-08-26). Hits arriving during the fall are the normal case, not the
/// edge case — a light being hit twice should brighten, and an envelope that
/// snapped to zero first would put a black frame in the middle of the flash.
///
/// The name was read aloud before it was built, as Chris asked. `strike` is
/// the closest rival and loses because it is also a noun for the event
/// (`plane.events.hit | strike …` reads as two events in a row); `flash` and
/// `thump` each name one customer and misread for the other; `burst` suggests
/// repetition; `ping` is spoken for; `env` cannot name one envelope when
/// `adsr` is another. `kick` is percussive, is a verb applied to the stream,
/// and sits in the same vocabulary `adsr` came from.
fn evalKick(ctx: *EvalCtx) EvalError!Emit {
    const attack = try dur(ctx, 1);
    const decay = try dur(ctx, 2);
    try sameLane(ctx, attack, 1, decay, 2);
    const now = ctx.nowOn(attack.frames);
    var st = EnvState.read(ctx);
    st.frames = attack.frames;

    // A rousing starts the attack from wherever we are. `in_fresh` is the
    // ARRIVAL, not the value: an occurrence that repeats is two occurrences.
    //
    // There is no separate "publish 0 at rest" branch, and there was one until
    // a gate showed it could not be reached: an idle envelope has span 0 and
    // `from == to == 0`, so the ordinary path below already answers 0. A guard
    // that cannot run is the `is_body` mistake again — it reads as a decision
    // and is a decoration.
    if (ctx.in_fresh[0]) {
        _ = try raw(ctx, 0); // require the rousing to carry something
        st.begin(.attack, now, st.level(now), 1.0, attack.count);
    }

    // Walk finished segments in order — one tick can cross a whole short
    // attack, and the next segment starts when the last one ENDED rather than
    // when we noticed, so a slow frame does not stretch the envelope.
    while (st.phase != .idle and st.progress(now) >= 1.0) {
        const ended = st.at +| st.span;
        switch (st.phase) {
            .attack => st.begin(.decay, ended, 1.0, 0.0, decay.count),
            .decay => st.begin(.idle, ended, 0, 0, 0),
            else => unreachable, // `kick` has two segments and a rest
        }
    }

    const v = st.level(now);
    try st.write(ctx);
    if (st.phase != .idle) try armNextTick(ctx, st.frames);
    return emitF64(ctx, v);
}

/// `adsr <attack> <decay> <sustain> <release>` — a LEVEL in, an envelope out.
/// Rise while the gate is held, decay to `sustain`, hold there, release when
/// the gate drops.
///
/// **Ports, not statics** (ruled 2026-08-26, CC's lean recorded as the
/// deviation from Chris's first wording): `attack`/`decay`/`release` are
/// durations and rill has no duration static kind, so they are ports in the
/// conventional a-d-s-r order — **and that order is a cultural constant**, not
/// a choice this language gets to make. A live release is worth having.
///
/// **A held sustain costs nothing.** The sustain phase arms no wake, so an
/// envelope holding a note is as cheap as a constant. The eval counter is what
/// says so, and it is what the gate reads: a value that stays put looks
/// identical to one being recomputed.
///
/// The `sustain` LEVEL is live — it is a hold, not a segment, so it follows
/// its port. A change during the decay lands at the decay's end, because the
/// segment in flight keeps the target it was given; that is the pin read
/// literally, and it is the only place the two readings differ.
fn evalAdsr(ctx: *EvalCtx) EvalError!Emit {
    const gate = try boolean(ctx, 0);
    const attack = try dur(ctx, 1);
    const decay = try dur(ctx, 2);
    const sustain = try num(ctx, 3);
    const release = try dur(ctx, 4);
    try sameLane(ctx, attack, 1, decay, 2);
    try sameLane(ctx, attack, 1, release, 4);

    const now = ctx.nowOn(attack.frames);
    var st = EnvState.read(ctx);
    st.frames = attack.frames;
    // The sustain level is live, so the held phase carries whatever the port
    // says now — which keeps `st.level` the single answer to "where is it".
    if (st.phase == .sustain) {
        st.from = sustain;
        st.to = sustain;
    }

    // The gate's edges, derived from the phase rather than stored beside it:
    // the envelope is held in exactly the three phases that follow a rise.
    const held = switch (st.phase) {
        .attack, .decay, .sustain => true,
        .idle, .release => false,
    };
    if (gate != held) {
        const from = st.level(now);
        if (gate) {
            st.begin(.attack, now, from, 1.0, attack.count);
        } else {
            // Release from wherever it is — mid-attack, mid-decay, or held.
            st.begin(.release, now, from, 0.0, release.count);
        }
    }

    while (st.progress(now) >= 1.0) {
        const ended = st.at +| st.span;
        switch (st.phase) {
            .attack => st.begin(.decay, ended, 1.0, sustain, decay.count),
            .decay => st.begin(.sustain, ended, sustain, sustain, 0),
            .release => st.begin(.idle, ended, 0, 0, 0),
            // `sustain` and `idle` are RESTS, not segments: they have no end
            // to reach, so the walk stops on them. Without this the loop over
            // a zero span would never terminate.
            .sustain, .idle => break,
        }
    }

    const v = st.level(now);
    try st.write(ctx);
    switch (st.phase) {
        .attack, .decay, .release => try armNextTick(ctx, st.frames),
        .sustain, .idle => {}, // a held note is as cheap as a constant
    }
    return emitF64(ctx, v);
}

/// `hold <duration>` — take a new value, then ignore further changes for
/// `duration`. Sample-and-hold. It does NOT tick: nothing needs to happen at
/// the end of the window, so there is no wake — the next arrival simply finds
/// the window expired. Ignored values are gone, which is the point.
fn evalHold(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 1);
    const now = ctx.nowOn(d.frames);
    var st = RegState.read(ctx);
    if (st.started and now < st.at + d.count) return emitF64(ctx, st.a);
    const v = try num(ctx, 0);
    st = .{ .frames = d.frames, .at = now, .a = v, .started = true };
    try st.write(ctx);
    return emitF64(ctx, v);
}

/// `diff` — rate of change per second, from the previous sample. Velocity
/// from position: the derived quantity people otherwise invent as a sensor
/// field (`plane.sensors.gate.nearest_distance | diff | dropped_below -2`).
///
/// It ticks WHILE MOVING and stops when the rate reaches zero, which is the
/// only honest reading: a value that stops changing has a rate of zero, and
/// an op that only spoke when its input spoke would report the last velocity
/// of a raider who has stopped, forever.
///
/// The first observation baselines silently (`dropped_below`'s idiom) — and
/// here the arithmetic forces it: dt is zero on the first eval and a rate
/// needs two samples.
fn evalDiff(ctx: *EvalCtx) EvalError!Emit {
    const v = try num(ctx, 0);
    const now = ctx.now_ns;
    var st = RegState.read(ctx);
    if (!st.started) {
        st = .{ .frames = false, .at = now, .a = v, .b = 0, .started = true };
        try st.write(ctx);
        return Emit.none; // no rate exists yet; the wave dies here, once
    }
    const dt = elapsed(false, st.at, now);
    if (dt <= 0) return Emit.none; // same tick again: no new information
    const rate = (v - st.a) / dt;
    st.at = now;
    st.a = v;
    st.b = rate;
    try st.write(ctx);
    if (rate != 0) try armNextTick(ctx, false); // still moving: ask again
    return emitF64(ctx, rate);
}

/// `integrate max <m>` — running sum over fed time, clamped to ±m. "Charge
/// while held." The clamp is a REQUIRED keyword port, not an option: op state
/// rides in every dump, so an unbounded accumulator is a corpse that gets
/// copied. It is also what lets the op stop — pinned at the bound, the value
/// no longer changes, so it stops re-arming.
fn evalIntegrate(ctx: *EvalCtx) EvalError!Emit {
    const rate = try num(ctx, 0);
    const cap = @abs(try num(ctx, 1));
    const now = ctx.now_ns;
    var st = RegState.read(ctx);
    if (!st.started) {
        st = .{ .frames = false, .at = now, .a = 0, .started = true };
        try st.write(ctx);
        try armNextTick(ctx, false);
        return emitF64(ctx, 0);
    }
    // The billable window FLOORS at the wheel's previous tick (ruled
    // 2026-08-29). Pinned or fed a zero rate, this op stops arming and
    // sleeps with `st.at` frozen; without the floor, the delta that finally
    // woke it billed the NEW rate across the whole sleep — Chris parked the
    // rail camera, pressed W once, and t slammed from 0.5 to the pin in a
    // single frame (one row of the flight recorder's CSV). The camera then
    // chased a target half a track away, straight through the middle of the
    // loop. What arrives on a tick stood through that one tick, no further.
    const start = @max(st.at, ctx.prevOn(false));
    const dt = elapsed(false, start, now);
    const next = std.math.clamp(st.a + rate * dt, -cap, cap);
    const moving = rate != 0 and next != st.a;
    st.at = now;
    st.a = next;
    try st.write(ctx);
    if (moving) try armNextTick(ctx, false);
    return emitF64(ctx, next);
}

// -- shaping ----------------------------------------------------------------

/// `range <lo> <hi>` — the exit from the unit interval. `lfo`, `wave` and
/// `shape` all leave 0..1, and this is what puts that back on a real scale.
///
/// It CLAMPS its input to 0..1 first, which is the whole difference from
/// `lerp` (`range 0.5 1.5` and `lerp 0.5 1.5` are otherwise the same
/// arithmetic): `lerp` blends and extrapolates past its ends, `range` maps a
/// unit-domain source onto an interval and stays inside it. Same ruling as
/// `along` outside 0..1 — clamp, and `| mod 1` first if you meant to
/// (there is no `wrap` word; floored `mod` IS the wrap).
fn evalRange(ctx: *EvalCtx) EvalError!Emit {
    const t = std.math.clamp(try num(ctx, 0), 0, 1);
    const lo = try num(ctx, 1);
    const hi = try num(ctx, 2);
    return emitF64(ctx, lo + (hi - lo) * t);
}

/// `t | over span [k0, k1, …]` — sample a curve of evenly-spaced knots.
///
/// The plane half of `row.kernels.over`; read that one's comment for the
/// semantics, which are the same on both sides by construction. What is
/// worth saying HERE is why the interpolation is spelled as three
/// `broadcast2` calls rather than one arithmetic line like `evalRange`
/// above: a knot may be a record. `[{r:1,g:1,b:1}, {r:1,g:.5,b:0}]` is a
/// colour ramp, and `a + (b - a) * frac` written with `num()` would refuse
/// it. Decomposing into subtract, multiply and add lets the audited
/// broadcast recursion carry records — and arrays, and nested records —
/// for free, and every refusal it raises already names both sides and the
/// field where they diverged.
///
/// A zero span refuses here as it does on a row. See the row kernel for
/// why this one op departs from `div`'s IEEE stance.
fn evalOver(ctx: *EvalCtx) EvalError!Emit {
    const t = try num(ctx, 0);
    const span = try num(ctx, 1);
    // `<= 0` and not `== 0`, and NaN refuses with them: the comparison is
    // written as "not positive" so a NaN span falls into the refusal rather
    // than through it. See the row kernel for why a negative span is an
    // authoring mistake rather than a curve running backwards.
    if (!(span > 0)) {
        return ctx.refuse("over: '{s}' is not positive — a curve with no width has nothing to sample across", .{ctx.portName(1)});
    }

    var elems = std.ArrayListUnmanaged([]const u8).empty;
    var r = struple.reader(try arrayInAt(ctx, 2));
    while (r.nextView() catch return ctx.refuse("over: '{s}' is a malformed array", .{ctx.portName(2)})) |e| {
        try elems.append(ctx.arena, e);
    }
    // The row side gets this refusal at MOUNT, where an empty literal is
    // rejected before a frame runs. The plane's array can arrive at eval
    // time from anywhere, so it is checked here.
    if (elems.items.len == 0) return ctx.refuse("over: '{s}' is empty — a curve needs at least one knot", .{ctx.portName(2)});

    const u = std.math.clamp(t / span, 0, 1);
    const n = elems.items.len;
    if (n == 1) {
        ctx.out[0].appendRaw(elems.items[0]) catch return ctx.refuse("over: the curve's only knot is unencodable", .{});
        return Emit.first;
    }
    const segs: f64 = @floatFromInt(n - 1);
    const f = u * segs;
    const i: usize = @intFromFloat(@floor(f));
    if (i >= n - 1) {
        ctx.out[0].appendRaw(elems.items[n - 1]) catch return ctx.refuse("over: the curve's last knot is unencodable", .{});
        return Emit.first;
    }
    const a = elems.items[i];
    const b = elems.items[i + 1];
    const frac = f - @floor(f);

    var diff = struple.Packer.init(ctx.arena);
    try broadcast2(ctx, "over", &diff, "", b, a, leafNum(fSub));
    var fr = struple.Packer.init(ctx.arena);
    try fr.appendF64(frac);
    var scaled = struple.Packer.init(ctx.arena);
    try broadcast2(ctx, "over", &scaled, "", diff.bytes(), fr.bytes(), leafNum(fMul));
    try broadcast2(ctx, "over", &ctx.out[0], "", a, scaled.bytes(), leafNum(fAdd));
    return Emit.first;
}

const SHAPE_CURVES = [_][]const u8{ "linear", "smooth", "in", "out", "inout" };

/// `shape <curve>` — 0..1 → 0..1, the easing curve as a value transform.
/// Input clamps (unit in, unit out). `bezier` with four handles is deferred
/// to the curves beat; these five are the ones every ask so far wanted.
fn evalShape(ctx: *EvalCtx) EvalError!Emit {
    const t = std.math.clamp(try num(ctx, 0), 0, 1);
    const curve = types.asString(try raw(ctx, 1)) orelse
        return ctx.refuse("shape: port 'curve' is {s}, not a curve name", .{describeTop(ctx, try raw(ctx, 1))});
    const v = if (std.mem.eql(u8, curve, "linear"))
        t
    else if (std.mem.eql(u8, curve, "smooth"))
        t * t * (3.0 - 2.0 * t) // smoothstep
    else if (std.mem.eql(u8, curve, "in"))
        t * t
    else if (std.mem.eql(u8, curve, "out"))
        t * (2.0 - t)
    else if (std.mem.eql(u8, curve, "inout"))
        (if (t < 0.5) 2.0 * t * t else 1.0 - 2.0 * (1.0 - t) * (1.0 - t))
    else
        return ctx.refuse("shape: '{s}' is not a curve — expected one of: linear, smooth, in, out, inout", .{curve});
    return emitF64(ctx, v);
}

// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Tier 2, beat 1b — broadcast, and the mismatch check that pays for it.
//
// They land together or not at all (ratified). ICE had broadcast and reported
// mismatches without naming the contexts, and that error was the one every ICE
// user learned to dread. So: every refusal names BOTH SIDES and the offending
// field, in a type-word vocabulary defined once here and reused by beat 2's
// shape literal.
//
// The rules, ratified 2026-08-25:
//   - scalar ⊗ record/array is elementwise (the scalar broadcasts);
//   - record ⊗ record requires the SAME FIELD SET — no implicit intersection,
//     because an intersection silently computes something nobody asked for;
//   - array ⊗ array requires EQUAL LENGTH, both named on refusal;
//   - nested containers recurse;
//   - a non-numeric leaf under arithmetic refuses, naming the field.
// Refuse, never guess.
// ---------------------------------------------------------------------------

/// The type-word vocabulary: `number`, `boolean`, `string`, `record{x, y}`,
/// `[number]`, `[]`. One renderer, so a mismatch message and (beat 2) a shape
/// literal cannot describe the same value two different ways.
///
/// Depth-capped at two containers: a message is for reading, and a fully
/// expanded description of a deep record is a wall. Below the cap the word is
/// the bare container (`record{…}`, `[…]`).
fn describe(ctx: *EvalCtx, encoded: []const u8, depth: u8) []const u8 {
    const t = types.typeOfValue(encoded);
    if (t == Tag.record) {
        if (depth == 0) return "record{…}";
        const inner = innerOf(ctx, encoded) catch return "record{?}";
        var out = std.ArrayListUnmanaged(u8).empty;
        out.appendSlice(ctx.arena, "record{") catch return "record{?}";
        var it = struple.MapView.init(inner).iterator();
        var first = true;
        while (it.next() catch return "record{?}") |e| {
            if (!first) out.appendSlice(ctx.arena, ", ") catch return "record{?}";
            first = false;
            // `MapView.Entry.key` is the ENCODED key element, not the string:
            // appending it raw would put a type tag and a length into the
            // message. Decode it.
            out.appendSlice(ctx.arena, types.asString(e.key) orelse "?") catch return "record{?}";
        }
        out.appendSlice(ctx.arena, "}") catch return "record{?}";
        return out.items;
    }
    if (t == Tag.array) {
        if (depth == 0) return "[…]";
        const inner = innerOf(ctx, encoded) catch return "[?]";
        var r = struple.reader(inner);
        const first = (r.nextView() catch return "[?]") orelse return "[]";
        const elem = describe(ctx, first, depth - 1);
        // Heterogeneous arrays say so rather than lying about the first
        // element — `[mixed]` is a true statement and `[number]` would not be.
        while (r.nextView() catch return "[?]") |e| {
            if (!std.mem.eql(u8, describe(ctx, e, depth - 1), elem)) return "[mixed]";
        }
        return std.fmt.allocPrint(ctx.arena, "[{s}]", .{elem}) catch "[?]";
    }
    return switch (t) {
        Tag.number => "number",
        Tag.boolean => "boolean",
        Tag.string => "string",
        Tag.bytes => "bytes",
        else => "value",
    };
}

fn describeTop(ctx: *EvalCtx, encoded: []const u8) []const u8 {
    return describe(ctx, encoded, 2);
}

/// Where in a nested value the trouble is: `""` at the top, then `.x`, `[2]`,
/// `.pos.y`. Appended to as the recursion descends, arena-owned.
/// `key` arrives as an encoded key ELEMENT (that is what `MapView` yields),
/// so every message path decodes it before printing.
fn keyName(key: []const u8) []const u8 {
    return types.asString(key) orelse "?";
}

fn pathField(ctx: *EvalCtx, path: []const u8, key: []const u8) []const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, keyName(key) }) catch path;
}

fn pathIndex(ctx: *EvalCtx, path: []const u8, i: usize) []const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}[{d}]", .{ path, i }) catch path;
}

/// "at <where>" or "" at the top — so a top-level refusal doesn't read
/// "at  " and a nested one says exactly which field.
fn whereIn(ctx: *EvalCtx, path: []const u8) []const u8 {
    if (path.len == 0) return "";
    return std.fmt.allocPrint(ctx.arena, " at {s}", .{path}) catch "";
}

/// The leaf: what a binary op actually does to two scalars, once the
/// containers have been peeled. One per family — arithmetic, comparison,
/// boolean — so the recursion below is written once and never per operator.
const LeafFn = *const fn (ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8, b: []const u8) EvalError!void;

fn leafNum(comptime f: fn (f64, f64) f64) LeafFn {
    return struct {
        fn leaf(ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8, b: []const u8) EvalError!void {
            const x = types.asNumber(a) orelse return notNumber(ctx, op, path, a, b, true);
            const y = types.asNumber(b) orelse return notNumber(ctx, op, path, a, b, false);
            try pk.appendF64(f(x, y));
        }
    }.leaf;
}

fn leafCmp(comptime f: fn (f64, f64) bool) LeafFn {
    return struct {
        fn leaf(ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8, b: []const u8) EvalError!void {
            const x = types.asNumber(a) orelse return notNumber(ctx, op, path, a, b, true);
            const y = types.asNumber(b) orelse return notNumber(ctx, op, path, a, b, false);
            try pk.appendBool(f(x, y));
        }
    }.leaf;
}

fn leafBool(comptime f: fn (bool, bool) bool) LeafFn {
    return struct {
        fn leaf(ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8, b: []const u8) EvalError!void {
            const x = types.asBool(a) orelse return notBoolean(ctx, op, path, a, b, true);
            const y = types.asBool(b) orelse return notBoolean(ctx, op, path, a, b, false);
            try pk.appendBool(f(x, y));
        }
    }.leaf;
}

fn notNumber(ctx: *EvalCtx, op: []const u8, path: []const u8, a: []const u8, b: []const u8, left: bool) EvalError {
    const bad = if (left) a else b;
    return ctx.refuse("{s}: {s} is {s}, not a number{s} — {s} and {s}", .{
        op,                    if (left) "the left side" else "the right side",
        describeTop(ctx, bad), whereIn(ctx, path),
        describeTop(ctx, a),   describeTop(ctx, b),
    });
}

fn notBoolean(ctx: *EvalCtx, op: []const u8, path: []const u8, a: []const u8, b: []const u8, left: bool) EvalError {
    const bad = if (left) a else b;
    return ctx.refuse("{s}: {s} is {s}, not a boolean{s} — {s} and {s}", .{
        op,                    if (left) "the left side" else "the right side",
        describeTop(ctx, bad), whereIn(ctx, path),
        describeTop(ctx, a),   describeTop(ctx, b),
    });
}

/// `innerOf` that says which op and where when it can't decode. Silent
/// `BadValue` is exactly what this beat exists to stop.
fn innerRefusing(ctx: *EvalCtx, op: []const u8, path: []const u8, encoded: []const u8) EvalError![]const u8 {
    const v = struple.view(encoded);
    const got = (v.containedItems(ctx.arena) catch null) orelse
        return ctx.refuse("{s}: cannot read {s} as a container{s}", .{ op, describeTop(ctx, encoded), whereIn(ctx, path) });
    return got;
}

/// The recursion. Peels one container level per call; the leaf handles what is
/// left. Every refusal below names both sides and where.
fn broadcast2(ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8, b: []const u8, leaf: LeafFn) EvalError!void {
    const ka = types.typeOfValue(a);
    const kb = types.typeOfValue(b);
    const a_rec = ka == Tag.record;
    const b_rec = kb == Tag.record;
    const a_arr = ka == Tag.array;
    const b_arr = kb == Tag.array;

    // A record and an array have no elementwise reading. Any rule we picked
    // (by position? by field order?) would be invented, so there isn't one.
    if ((a_rec and b_arr) or (a_arr and b_rec)) {
        return ctx.refuse("{s}: {s} and {s}{s} — a record and an array have no elementwise meaning", .{
            op, describeTop(ctx, a), describeTop(ctx, b), whereIn(ctx, path),
        });
    }

    if (a_rec or b_rec) {
        var entries = std.ArrayListUnmanaged([2][]const u8).empty;
        if (a_rec and b_rec) {
            // Same field set required. Keys are canonical (sorted), so a
            // lockstep walk finds the first divergence and can say which side
            // is missing it — no intersection, ever: an intersection quietly
            // computes over the fields that happen to agree, which is a wrong
            // answer wearing a right one's clothes.
            var ia = struple.MapView.init(try innerRefusing(ctx, op, path, a)).iterator();
            var ib = struple.MapView.init(try innerRefusing(ctx, op, path, b)).iterator();
            var ea = ia.next() catch return ctx.refuse("{s}: the left side is a malformed record{s}", .{ op, whereIn(ctx, path) });
            var eb = ib.next() catch return ctx.refuse("{s}: the right side is a malformed record{s}", .{ op, whereIn(ctx, path) });
            while (ea != null or eb != null) {
                if (ea == null or (eb != null and std.mem.order(u8, ea.?.key, eb.?.key) == .gt)) {
                    return missingField(ctx, op, path, a, b, eb.?.key, true);
                }
                if (eb == null or std.mem.order(u8, ea.?.key, eb.?.key) == .lt) {
                    return missingField(ctx, op, path, a, b, ea.?.key, false);
                }
                var sub = struple.Packer.init(ctx.arena);
                try broadcast2(ctx, op, &sub, pathField(ctx, path, ea.?.key), ea.?.value, eb.?.value, leaf);
                try entries.append(ctx.arena, .{ ea.?.key, sub.bytes() });
                ea = ia.next() catch return ctx.refuse("{s}: the left side is a malformed record{s}", .{ op, whereIn(ctx, path) });
                eb = ib.next() catch return ctx.refuse("{s}: the right side is a malformed record{s}", .{ op, whereIn(ctx, path) });
            }
        } else {
            // Scalar on one side broadcasts to every field of the other.
            const rec = if (a_rec) a else b;
            var it = struple.MapView.init(try innerRefusing(ctx, op, path, rec)).iterator();
            while (it.next() catch return ctx.refuse("{s}: a malformed record{s}", .{ op, whereIn(ctx, path) })) |e| {
                var sub = struple.Packer.init(ctx.arena);
                const l = if (a_rec) e.value else a;
                const r = if (a_rec) b else e.value;
                try broadcast2(ctx, op, &sub, pathField(ctx, path, e.key), l, r, leaf);
                try entries.append(ctx.arena, .{ e.key, sub.bytes() });
            }
        }
        // `appendMap`'s only failure is allocation, which is not a mismatch:
        // `try`, never a catch that would report a shape problem that isn't
        // there.
        try pk.appendMap(entries.items);
        return;
    }

    if (a_arr or b_arr) {
        var elems = struple.Packer.init(ctx.arena);
        if (a_arr and b_arr) {
            const na = try arrayLen(ctx, op, path, a);
            const nb = try arrayLen(ctx, op, path, b);
            if (na != nb) {
                // Both lengths named. Grasshopper picks a matching rule
                // implicitly and it is the most-complained-about behaviour in
                // the tool; never pick a rule.
                return ctx.refuse("{s}: {s} of {d} and {s} of {d}{s} — arrays must be the same length", .{
                    op, describeTop(ctx, a), na, describeTop(ctx, b), nb, whereIn(ctx, path),
                });
            }
            var ra = struple.reader(try innerRefusing(ctx, op, path, a));
            var rb = struple.reader(try innerRefusing(ctx, op, path, b));
            var i: usize = 0;
            while (true) : (i += 1) {
                const va = (ra.nextView() catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) })) orelse break;
                const vb = (rb.nextView() catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) })) orelse break;
                var sub = struple.Packer.init(ctx.arena);
                try broadcast2(ctx, op, &sub, pathIndex(ctx, path, i), va, vb, leaf);
                elems.appendRaw(sub.bytes()) catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) });
            }
        } else {
            const arr = if (a_arr) a else b;
            var r = struple.reader(try innerRefusing(ctx, op, path, arr));
            var i: usize = 0;
            while (true) : (i += 1) {
                const v = (r.nextView() catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) })) orelse break;
                var sub = struple.Packer.init(ctx.arena);
                const l = if (a_arr) v else a;
                const rr = if (a_arr) b else v;
                try broadcast2(ctx, op, &sub, pathIndex(ctx, path, i), l, rr, leaf);
                elems.appendRaw(sub.bytes()) catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) });
            }
        }
        pk.appendArray(elems.bytes()) catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) });
        return;
    }

    return leaf(ctx, op, pk, path, a, b);
}

fn missingField(ctx: *EvalCtx, op: []const u8, path: []const u8, a: []const u8, b: []const u8, key: []const u8, on_left: bool) EvalError {
    return ctx.refuse("{s}: {s} and {s}{s} — field '{s}' is missing on the {s}", .{
        op,           describeTop(ctx, a),              describeTop(ctx, b), whereIn(ctx, path),
        keyName(key), if (on_left) "left" else "right",
    });
}

fn arrayLen(ctx: *EvalCtx, op: []const u8, path: []const u8, encoded: []const u8) EvalError!usize {
    var r = struple.reader(try innerRefusing(ctx, op, path, encoded));
    var n: usize = 0;
    while ((r.nextView() catch return ctx.refuse("{s}: cannot decode an array{s}", .{ op, whereIn(ctx, path) })) != null) n += 1;
    return n;
}

/// The unary half: one container walk, one leaf. `abs` on a position is a
/// position; `not` on an array of flags is an array of flags.
const Leaf1 = *const fn (ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8) EvalError!void;

fn broadcast1(ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8, leaf: Leaf1) EvalError!void {
    const k = types.typeOfValue(a);
    if (k == Tag.record) {
        var entries = std.ArrayListUnmanaged([2][]const u8).empty;
        var it = struple.MapView.init(try innerRefusing(ctx, op, path, a)).iterator();
        while (it.next() catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) })) |e| {
            var sub = struple.Packer.init(ctx.arena);
            try broadcast1(ctx, op, &sub, pathField(ctx, path, e.key), e.value, leaf);
            try entries.append(ctx.arena, .{ e.key, sub.bytes() });
        }
        pk.appendMap(entries.items) catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) });
        return;
    }
    if (k == Tag.array) {
        var elems = struple.Packer.init(ctx.arena);
        var r = struple.reader(try innerRefusing(ctx, op, path, a));
        var i: usize = 0;
        while (true) : (i += 1) {
            const v = (r.nextView() catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) })) orelse break;
            var sub = struple.Packer.init(ctx.arena);
            try broadcast1(ctx, op, &sub, pathIndex(ctx, path, i), v, leaf);
            elems.appendRaw(sub.bytes()) catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) });
        }
        pk.appendArray(elems.bytes()) catch return ctx.refuse("{s}: a malformed array{s}", .{ op, whereIn(ctx, path) });
        return;
    }
    return leaf(ctx, op, pk, path, a);
}

fn leaf1Num(comptime f: fn (f64) f64) Leaf1 {
    return struct {
        fn leaf(ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8) EvalError!void {
            const x = types.asNumber(a) orelse return ctx.refuse("{s}: {s} is {s}, not a number{s}", .{ op, "the input", describeTop(ctx, a), whereIn(ctx, path) });
            try pk.appendF64(f(x));
        }
    }.leaf;
}

fn unBool() fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            try broadcast1(ctx, ctx.op.name, &ctx.out[0], "", try raw(ctx, 0), leaf1Bool(fNot));
            return Emit.first;
        }
    }.eval;
}

fn leaf1Bool(comptime f: fn (bool) bool) Leaf1 {
    return struct {
        fn leaf(ctx: *EvalCtx, op: []const u8, pk: *struple.Packer, path: []const u8, a: []const u8) EvalError!void {
            const x = types.asBool(a) orelse return ctx.refuse("{s}: {s} is {s}, not a boolean{s}", .{ op, "the input", describeTop(ctx, a), whereIn(ctx, path) });
            try pk.appendBool(f(x));
        }
    }.leaf;
}

// ---------------------------------------------------------------------------
// The math operators. THIS IS THE ONE SITE (beat 1b, 2026-08-25): every
// arithmetic word, every comparator and the boolean trio are minted by these
// four helpers, so broadcast is a property of the helper and not of the words.
// Beat 1a's split existed exactly so this could land before the math
// completions did — nothing here is scored twice.
// ---------------------------------------------------------------------------

/// `<name>` for messages: the op's own word, from the node's op definition
/// would be ideal, but eval doesn't carry it — so each generated eval closes
/// over its name at comptime. One string per op, no runtime cost.
fn binMath(comptime f: fn (f64, f64) f64) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            try broadcast2(ctx, ctx.op.name, &ctx.out[0], "", try raw(ctx, 0), try raw(ctx, 1), leafNum(f));
            return Emit.first;
        }
    }.eval;
}

fn unMath(comptime f: fn (f64) f64) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            try broadcast1(ctx, ctx.op.name, &ctx.out[0], "", try raw(ctx, 0), leaf1Num(f));
            return Emit.first;
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

// The completions (beat 1b). Nothing to argue about; they were missing. Each
// one is minted by the same helper as `add`, so each is born broadcasting over
// records and arrays — which is the whole reason the beat was split.
fn fSin(v: f64) f64 {
    return @sin(v);
}
fn fCos(v: f64) f64 {
    return @cos(v);
}
fn fTan(v: f64) f64 {
    return @tan(v);
}
fn fSqrt(v: f64) f64 {
    return @sqrt(v);
}
fn fExp(v: f64) f64 {
    return @exp(v);
}
/// Natural log, as every language a reader arrives from spells it. `log 0` is
/// -inf and a negative is nan — IEEE, like `div` by zero, never a refusal:
/// arithmetic that has an answer gives it.
fn fLog(v: f64) f64 {
    return @log(v);
}
fn fCeil(v: f64) f64 {
    return @ceil(v);
}
/// -1, 0, or 1. NaN stays NaN rather than being called zero.
fn fSign(v: f64) f64 {
    if (std.math.isNan(v)) return v;
    return if (v > 0) 1 else if (v < 0) @as(f64, -1) else 0;
}
/// The fractional part, always in [0, 1) — `@mod`-shaped, not truncation, so
/// `fract -0.25` is 0.75 and a phase never goes backwards over zero.
fn fFract(v: f64) f64 {
    return v - @floor(v);
}
fn fPow(a: f64, b: f64) f64 {
    return std.math.pow(f64, a, b);
}
/// Floored modulo: the sign follows the DIVISOR, so `-90 | mod 360` is 270.
/// Angles and phases are what asks for this op, and truncated remainder gets
/// them wrong on exactly the half of the circle people forget to test.
fn fMod(a: f64, b: f64) f64 {
    if (b == 0) return std.math.nan(f64);
    return a - b * @floor(a / b);
}
fn fAtan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}

/// `pi` / `tau` — sources with no input, emitting once at mount. They are
/// operators rather than lexer-known names because the registry is the one
/// namespace: a name the parser knew and `rill ops` didn't would be a word
/// with no home.
fn constant(comptime v: f64) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            return emitF64(ctx, v);
        }
    }.eval;
}

fn evalClamp(ctx: *EvalCtx) EvalError!Emit {
    const v = try num(ctx, 0);
    const lo = try num(ctx, 1);
    const hi = try num(ctx, 2);
    return emitF64(ctx, std.math.clamp(v, lo, hi));
}

/// Comparators broadcast too — `[1, -2, 3] > 0` is `[true, false, true]`,
/// which is what beat 3's `keep (> 0)` evaluates before it filters.
fn cmpOp(comptime f: fn (f64, f64) bool) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            try broadcast2(ctx, ctx.op.name, &ctx.out[0], "", try raw(ctx, 0), try raw(ctx, 1), leafCmp(f));
            return Emit.first;
        }
    }.eval;
}

/// …and so do the boolean trio, for the same customer.
fn boolOp(comptime f: fn (bool, bool) bool) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn eval(ctx: *EvalCtx) EvalError!Emit {
            try broadcast2(ctx, ctx.op.name, &ctx.out[0], "", try raw(ctx, 0), try raw(ctx, 1), leafBool(f));
            return Emit.first;
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

/// `array` — the positional twin of `record` (§2.10). Statics are the element
/// indices (see `Parser.makeArrayNode`); the eval ignores them, because order
/// IS the meaning: it packs the ports in port order and nothing else.
fn evalArray(ctx: *EvalCtx) EvalError!Emit {
    var inner = struple.Packer.init(ctx.arena);
    for (0..ctx.in.len) |i| {
        inner.appendRaw(try raw(ctx, i)) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadValue,
        };
    }
    try ctx.out[0].appendArray(inner.bytes());
    return Emit.first;
}

/// Indexing, minted twice. `nth` and `choose` are the same computation and
/// differ only in WHICH PORT IS HOT — the language's own distinction (port 0
/// is the rousing, a bound port is the payload), so the two spellings are two
/// words rather than one word with a mode:
///
///     contacts | nth 2                 // the list rouses; the index is fixed
///     plane.time.band | choose [ … ]   // the index rouses; the list is fixed
///
/// Out of range is an error, not a clamp and not an empty emission: the
/// mistake is in the program, and a silently-clamped index is a wrong picture
/// nobody is told about.
fn indexEval(comptime arr_port: usize, comptime idx_port: usize) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn e(ctx: *EvalCtx) EvalError!Emit {
            const av = try raw(ctx, arr_port);
            if (types.typeOfValue(av) != Tag.array) {
                return ctx.refuse("{s}: '{s}' is {s}, not an array", .{ ctx.op.name, ctx.portName(arr_port), describeTop(ctx, av) });
            }
            const iv = try raw(ctx, idx_port);
            const f = types.asNumber(iv) orelse
                return ctx.refuse("{s}: '{s}' is {s}, not a number — an index is a whole number from 0", .{ ctx.op.name, ctx.portName(idx_port), describeTop(ctx, iv) });
            if (f != @floor(f) or !std.math.isFinite(f)) {
                return ctx.refuse("{s}: index {d} is not a whole number", .{ ctx.op.name, f });
            }
            // `struple.view` reads an element STREAM, and `av` is one array
            // element — so counting it directly says 1, always. The elements
            // live in the container body, which is what `innerOf` unpacks.
            const view = struple.view(try innerOf(ctx, av));
            const n = view.count() catch return ctx.refuse("{s}: '{s}' is a malformed array", .{ ctx.op.name, ctx.portName(arr_port) });
            if (f < 0 or f >= @as(f64, @floatFromInt(n))) {
                return ctx.refuse("{s}: index {d} is out of range — the array has {d} element{s}", .{ ctx.op.name, f, n, if (n == 1) "" else "s" });
            }
            const elem = (view.at(@intFromFloat(f)) catch null) orelse
                return ctx.refuse("{s}: '{s}' is a malformed array", .{ ctx.op.name, ctx.portName(arr_port) });
            try splice(ctx, 0, elem);
            return Emit.first;
        }
    }.e;
}

// ---------------------------------------------------------------------------
// Noise, randomness, space (tier 2, beat 4b)
//
// **One PRNG family, not three** (ruled 2026-08-25). `rand` and `shuffle`
// both draw from xoshiro256++; `noise` is a hash of lattice coordinates, which
// is a different job — a generator produces a *sequence*, a hash answers "what
// is the value AT this coordinate" and must answer the same way forever. Two
// mechanisms because there are two questions, and no third.
// ---------------------------------------------------------------------------

/// The integer lattice hash. No `sin`-based hashes, ever: they are
/// float-precision-dependent and differ between machines and optimisation
/// levels, which is exactly the property noise must not have. This is
/// splitmix64's finaliser over the mixed coordinate — integer in, integer
/// out, bit-identical everywhere.
fn latticeHash(cell: i64, seed: u64) u64 {
    var x: u64 = @bitCast(cell);
    x = x *% 0x9E3779B97F4A7C15;
    x ^= seed *% 0xBF58476D1CE4E5B9;
    x ^= x >> 30;
    x = x *% 0xBF58476D1CE4E5B9;
    x ^= x >> 27;
    x = x *% 0x94D049BB133111EB;
    x ^= x >> 31;
    return x;
}

/// A lattice gradient in [-1, 1), from the hash's top 24 bits — the width an
/// f32 mantissa holds exactly, so the division is lossless and the same
/// everywhere.
///
/// Continuous, not ±1. The two-valued form is the textbook 1D gradient and it
/// is wrong here: with two gradients a cell has only four possible shapes, so
/// two seeds produce an *identical* cell one time in four and `seed` stops
/// being the decorrelator §2.8 promises. Found by the gate that counts how
/// often three seeds disagree — 32 samples in 109, where it should be nearly
/// all of them.
fn latticeGradient(cell: i64, seed: u64) f32 {
    const h = latticeHash(cell, seed);
    const unit: f32 = @as(f32, @floatFromInt(h >> 40)) / 16777216.0;
    return unit * 2.0 - 1.0;
}

/// Perlin's quintic fade, 6t⁵ − 15t⁴ + 10t³ — zero first AND second derivative
/// at both ends, which is what keeps the lattice invisible.
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Where this seed's LATTICE starts, in cells (Chris's amendment,
/// 2026-08-25).
///
/// Offsetting the gradients is not enough. Gradient noise is zero at every
/// lattice point *for every seed*, and seeds sharing a period share a lattice
/// — so without this, every torch on a different seed passes through 0.5 in
/// lockstep at each period boundary, octaves included. That is a family of
/// coincidences, not the single corner at t = 0 that the first gate found.
/// A seed must move the lattice as well as the gradients on it.
fn latticePhase(seed: u64) f32 {
    const h = latticeHash(0x5EED, seed);
    return @as(f32, @floatFromInt(h >> 40)) / 16777216.0;
}

/// One octave of 1D gradient noise at `t` lattice units, in [-0.5, 0.5].
/// Each octave carries its own seed, so each gets its own lattice phase too.
fn perlin1(t_raw: f32, seed: u64) f32 {
    const t = t_raw + latticePhase(seed);
    const fl = @floor(t);
    const i: i64 = @intFromFloat(fl);
    const u = t - fl;
    const g0 = latticeGradient(i, seed);
    const g1 = latticeGradient(i + 1, seed);
    const f = fade(u);
    return (1.0 - f) * (g0 * u) + f * (g1 * (u - 1.0));
}

/// `noise <period> [octaves <n>] [seed <s>]` — smooth noise in 0..1 over fed
/// time. Stateless: a pure function of (seed, period, octaves, t), so it is
/// not a register and it replays for free.
///
/// **All arithmetic is f32 in a fixed order, then widened exactly.** The
/// ledger's line — an expectation is faithful to the implementation's
/// arithmetic or it is not an expectation — bites hardest here, so the gates
/// pin f32 BIT PATTERNS rather than values. `@floatCast` from f32 to f64 is
/// exact, so the widening adds nothing to check.
///
/// **The normalisation is fixed, not a knob.** One octave lands in
/// [-0.5, 0.5]; `octaves` stacks halved periods at halved amplitude (gain ½,
/// lacunarity 2), so the sum lands in ±½·Σgainᵏ. Dividing by 2·Σgainᵏ and
/// adding ½ is the whole of it, and the divisor is decided by `octaves` alone.
fn evalNoise(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 0);
    const period = try periodOf(d);
    const octaves: u32 = if (ctx.in[1] == null) 1 else blk: {
        const f = try num(ctx, 1);
        if (!std.math.isFinite(f) or f != @floor(f) or f < 1 or f > 8) {
            return ctx.refuse("noise: 'octaves' is {d} — a whole number from 1 to 8", .{f});
        }
        break :blk @intFromFloat(f);
    };
    const seed: u64 = if (ctx.in[2] == null) 0 else blk: {
        const f = try num(ctx, 2);
        if (!std.math.isFinite(f) or f != @floor(f) or f < 0) {
            return ctx.refuse("noise: 'seed' is {d} — a seed is a whole number from 0", .{f});
        }
        break :blk @intFromFloat(f);
    };
    const now = ctx.nowOn(d.frames);
    var st = RegState.read(ctx);
    if (!st.started) st = .{ .frames = d.frames, .at = now, .started = true };
    try st.write(ctx);
    try armNextTick(ctx, d.frames);

    const t: f32 = @floatCast(elapsed(d.frames, st.at, now) / period);
    var sum: f32 = 0;
    var amp: f32 = 1;
    var total: f32 = 0;
    var freq: f32 = 1;
    var k: u32 = 0;
    while (k < octaves) : (k += 1) {
        sum += amp * perlin1(t * freq, seed +% k);
        total += amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    const unit: f32 = 0.5 + sum / (2.0 * total);
    // f32 → f64 is exact; the clamp is a guard on the arithmetic above, not a
    // second opinion about the range.
    return emitF64(ctx, @min(1.0, @max(0.0, @as(f64, @floatCast(unit)))));
}

/// `rand [seed <s>]` — white noise: a fresh value in 0..1 on every rousing.
/// Same generator as `shuffle` (xoshiro256++), advanced by a draw counter in
/// node state, so a replay of the same arrivals gives the same sequence.
fn evalRand(ctx: *EvalCtx) EvalError!Emit {
    _ = try raw(ctx, 0);
    const seed: u64 = if (ctx.in[1] == null) 0 else blk: {
        const f = try num(ctx, 1);
        if (!std.math.isFinite(f) or f != @floor(f) or f < 0) {
            return ctx.refuse("rand: 'seed' is {d} — a seed is a whole number from 0", .{f});
        }
        break :blk @intFromFloat(f);
    };
    const st = ctx.state.items;
    const drawn: u64 = if (st.len >= 8) std.mem.readInt(u64, st[0..8], .little) else 0;
    if (st.len >= 8 and !ctx.in_fresh[0]) return Emit.none;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, drawn + 1, .little);
    try ctx.setState(&buf);
    // The draw counter is folded into the seed rather than the generator being
    // carried across ticks: a PRNG's internal state is 32 bytes and a counter
    // is 8, and re-seeding per draw makes a restore land on the same number
    // the live program would have produced.
    var prng = std.Random.DefaultPrng.init(seed +% drawn *% 0x9E3779B97F4A7C15);
    return emitF64(ctx, prng.random().float(f64));
}

/// One axis of a position record, refusing by name. `record{x, y, z}` on both
/// sides is the contract (ruled 2026-08-25) — the spatial pair does not guess
/// at 2D, and a missing axis says which one.
fn axis(ctx: *EvalCtx, port: usize, which: []const u8) EvalError![3]f64 {
    return axisOf(ctx, try raw(ctx, port), which);
}

/// `axis` for a value that did not arrive on a port — an element of a knot
/// array, say. Same contract and the same refusals, because a knot is a
/// position and there is no second spelling for one.
fn axisOf(ctx: *EvalCtx, v: []const u8, which: []const u8) EvalError![3]f64 {
    if (types.typeOfValue(v) != Tag.record) {
        return ctx.refuse("{s}: '{s}' is {s}, not record{{x, y, z}}", .{ ctx.op.name, which, describeTop(ctx, v) });
    }
    const m = struple.MapView.init(try innerOf(ctx, v));
    var out: [3]f64 = undefined;
    inline for (.{ "x", "y", "z" }, 0..) |name, i| {
        var kp = struple.Packer.init(ctx.arena);
        try kp.appendString(name);
        const cell = (m.get(kp.bytes()) catch null) orelse
            return ctx.refuse("{s}: '{s}' is {s} and has no '{s}' — a position is record{{x, y, z}}", .{ ctx.op.name, which, describeTop(ctx, v), name });
        out[i] = types.asNumber(cell) orelse
            return ctx.refuse("{s}: '{s}.{s}' is {s}, not a number", .{ ctx.op.name, which, name, describeTop(ctx, cell) });
    }
    return out;
}

fn separation(ctx: *EvalCtx) EvalError!f64 {
    const a = try axis(ctx, 0, ctx.portName(0));
    const b = try axis(ctx, 1, ctx.portName(1));
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

fn evalDistance(ctx: *EvalCtx) EvalError!Emit {
    return emitF64(ctx, try separation(ctx));
}

/// `dot <a> <b>` — the scalar product of two positions-or-directions.
///
/// Writable today as `mul` plus two field reads plus two `add`s, which is six
/// nodes to say one thing; and the thing it says — *how much of a is along b* —
/// is the whole of projection, so it earns a word. Same `record{x, y, z}`
/// contract as `distance`/`within`: the spatial family does not guess at 2D.
fn evalDot(ctx: *EvalCtx) EvalError!Emit {
    const a = try axis(ctx, 0, ctx.portName(0));
    const b = try axis(ctx, 1, ctx.portName(1));
    return emitF64(ctx, a[0] * b[0] + a[1] * b[1] + a[2] * b[2]);
}

/// `within <b> <r>` — the question people actually ask, and the one that keeps
/// a `distance | < r` chain from being written with the comparison backwards.
fn evalWithin(ctx: *EvalCtx) EvalError!Emit {
    const d = try separation(ctx);
    const r = try num(ctx, 2);
    try ctx.out[0].appendBool(d <= r);
    return Emit.first;
}

/// The raw vector product, shared by `cross` (which packs it) and `angle`
/// (which measures it) so the two cannot disagree about handedness.
fn crossOf(a: [3]f64, b: [3]f64) [3]f64 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

/// `angle <a> <b>` — the angle between two directions, in RADIANS, 0..π.
///
/// Blade3D never had this word: a graph chained Dot, two Normalizes and an
/// Acos — the same six-nodes shape that earned `dot` its place. Radians and
/// no degree twin, because the audit already ruled conversion is sayable in
/// words that exist.
///
/// Computed as atan2(|a×b|, a·b), not acos of the normalised dot. The acos
/// spelling loses its precision exactly at the answers people test for — 0
/// and π, "aligned" and "opposed" — where its argument grazes ±1 and needs a
/// clamp to stay legal at all; atan2 is exact at both ends and clamps
/// nothing. It also makes the extremes EXACT: orthogonal is atan2(len, 0),
/// which is π/2 by definition, aligned is atan2(0, +) = 0, opposed is
/// atan2(0, −) = π.
///
/// A zero-length vector REFUSES: it has no direction, so "its angle" is a
/// claim about nothing — and answering 0 would make a dead sensor read as
/// dead ahead. Same family voice as the missing axis: name the port.
fn evalAngle(ctx: *EvalCtx) EvalError!Emit {
    const a = try axis(ctx, 0, ctx.portName(0));
    const b = try axis(ctx, 1, ctx.portName(1));
    inline for (.{ a, b }, 0..) |v, i| {
        if (v[0] == 0 and v[1] == 0 and v[2] == 0) {
            return ctx.refuse("angle: '{s}' is {{x: 0, y: 0, z: 0}} — a zero-length vector has no direction, so there is no angle to measure", .{ctx.portName(i)});
        }
    }
    const c = crossOf(a, b);
    const sin_part = @sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]);
    const cos_part = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    return emitF64(ctx, std.math.atan2(sin_part, cos_part));
}

/// `inside <p> <min> <max>` — is p inside the axis-aligned box? The AABB
/// companion to `within`'s sphere, and Blade3D's "Point In AABB" reborn: the
/// original took min/max corners too (an XNA BoundingBox IS Min and Max), so
/// two corner records is the shape the pattern has always had, not a rill
/// invention. Three mandatory positional ports, unmarked — `adsr`'s
/// precedent for order-meaningful same-typed arguments.
///
/// Bounds are INCLUSIVE, exactly as Blade3D's were: a point ON the wall is
/// inside, the same way `within` keeps a point ON the sphere (`d <= r`). The
/// two words must agree about their boundary or "at the edge" would flicker
/// by primitive.
///
/// An inverted box (min above max on an axis) is an EMPTY box and answers
/// FALSE — it does not refuse. A box computed from live data can legitimately
/// invert for a frame (two corners crossing), and `within` already answers
/// false to a negative radius rather than killing the wave; an empty region
/// contains nothing, and that is an answer, not an error.
fn evalInside(ctx: *EvalCtx) EvalError!Emit {
    const point = try axis(ctx, 0, ctx.portName(0));
    const lo = try axis(ctx, 1, ctx.portName(1));
    const hi = try axis(ctx, 2, ctx.portName(2));
    var in = true;
    inline for (0..3) |i| {
        if (point[i] < lo[i] or point[i] > hi[i]) in = false;
    }
    try ctx.out[0].appendBool(in);
    return Emit.first;
}

/// `cross <a> <b>` — the vector product, record{x, y, z} out, RIGHT-HANDED:
/// x × y = z. The word the engine keeps re-deriving (gizmos carries its own
/// copy), and the same six-nodes argument that seated `dot`: sayable today as
/// six field reads, six `mul`s and three `sub`s, and nobody should. The
/// output is a record in the spatial contract's own field order — x, y, z —
/// so it feeds straight back into `dot`, `angle`, `distance` and a knot list.
fn evalCross(ctx: *EvalCtx) EvalError!Emit {
    const a = try axis(ctx, 0, ctx.portName(0));
    const b = try axis(ctx, 1, ctx.portName(1));
    const c = crossOf(a, b);
    var entries = std.ArrayListUnmanaged([2][]const u8).empty;
    inline for (.{ "x", "y", "z" }, 0..) |name, i| {
        var kp = struple.Packer.init(ctx.arena);
        try kp.appendString(name);
        var vp = struple.Packer.init(ctx.arena);
        try vp.appendF64(c[i]);
        try entries.append(ctx.arena, .{ kp.bytes(), vp.bytes() });
    }
    try ctx.out[0].appendMap(entries.items);
    return Emit.first;
}

// ---------------------------------------------------------------------------
// Events and levels (tier 2, beat 4a)
//
// The pin that shapes this family: **levels emit at tick 0, crossings baseline
// silently.** `above` publishes its level at mount, `toggle` its initial
// `false`, `tally` its `0` — because a program that reads a level must have
// one to read on its first evaluation, and "nothing yet" is not a level. The
// crossing detectors (`dropped_below`, `rose_above`, `edge`) do the opposite
// and stay silent on their first observation, because a crossing that nobody
// crossed is not an event.
// ---------------------------------------------------------------------------

/// `pulse <period> [width <w>]` — a VALUE source: 1 while inside the pulse,
/// 0 otherwise, once per period (ruled 2026-08-25). `every` remains the
/// occurrence source. One node, one kind: an operator that emitted an
/// occurrence AND held a value would be two operators sharing a name, and
/// nothing downstream could tell which one it was talking to.
///
/// `width` defaults to a tenth of the period — a flash, not a square wave
/// (`lfo square` is the square wave). Fixed, like `octaves`' gain and
/// lacunarity: a default that is a number rather than a knob.
fn evalPulse(ctx: *EvalCtx) EvalError!Emit {
    const d = try dur(ctx, 0);
    const period = try periodOf(d);
    const width = if (ctx.in[1] == null) period / 10.0 else blk: {
        const w = try dur(ctx, 1);
        if (w.frames != d.frames) {
            return ctx.refuse("pulse: 'period' and 'width' are on different lanes — a frame width cannot measure a real-time period", .{});
        }
        break :blk try periodOf(w);
    };
    const now = ctx.nowOn(d.frames);
    var st = RegState.read(ctx);
    if (!st.started) st = .{ .frames = d.frames, .at = now, .started = true };
    try st.write(ctx);
    try armNextTick(ctx, d.frames);
    const t = elapsed(d.frames, st.at, now);
    const phase = t - @floor(t / period) * period;
    return emitF64(ctx, if (phase < width) 1 else 0);
}

/// `once` — pass the first value and then go deaf until remount.
///
/// Unpiped at the head of a statement it is **§3.8's rule and no new one**:
/// the value binds port 0 and is both rousing and payload, so `once 1 | ramp
/// 2s` fires at tick 0 and never again — a literal source is written at mount
/// and nothing ever marks the node afterwards. Piped, it passes the first
/// arrival. The state is what makes "never again" true even when something
/// downstream ticks and drags the node along.
fn evalOnce(ctx: *EvalCtx) EvalError!Emit {
    if (ctx.state.items.len > 0 and ctx.state.items[0] == 1) return Emit.none;
    try ctx.setState(&.{1});
    try splice(ctx, 0, try raw(ctx, 0));
    return Emit.first;
}

/// `toggle` — flip a boolean on each arrival. Emits its initial `false` at
/// tick 0 (the level pin) and flips from the NEXT arrival on, so the value at
/// mount is not silently consumed as the first press.
fn evalToggle(ctx: *EvalCtx) EvalError!Emit {
    _ = try raw(ctx, 0); // require an input; a toggle with no switch is nothing
    const st = ctx.state.items;
    if (st.len == 0) {
        try ctx.setState(&.{0});
        try ctx.out[0].appendBool(false);
        return Emit.first;
    }
    if (!ctx.in_fresh[0]) return Emit.none;
    const next = st[0] == 0;
    try ctx.setState(&.{@intFromBool(next)});
    try ctx.out[0].appendBool(next);
    return Emit.first;
}

/// `tally` — running count of arrivals, as a value. Emits `0` at tick 0 (the
/// level pin) and counts from the next arrival on.
///
/// It does NOT survive remount, and that falls out rather than being enforced:
/// the count lives in node state, and a remount is a fresh parse and a fresh
/// mount with no state to inherit. A dump/restore DOES carry it, which is the
/// difference between restarting a program and resuming one.
fn evalTally(ctx: *EvalCtx) EvalError!Emit {
    _ = try raw(ctx, 0);
    const st = ctx.state.items;
    if (st.len < 8) {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, 0, .little);
        try ctx.setState(&buf);
        return emitF64(ctx, 0);
    }
    if (!ctx.in_fresh[0]) return Emit.none;
    const n = std.mem.readInt(u64, st[0..8], .little) + 1;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, n, .little);
    try ctx.setState(&buf);
    return emitF64(ctx, @floatFromInt(n));
}

/// `above <on> <off>` — a boolean with hysteresis: true once the input rises
/// past `on`, false once it drops past `off`. `above 0.3 0.2` reads as "above
/// 0.3, until below 0.2".
///
/// This is the operator §4's "night falls → lights on" row needed. A strict
/// comparator scored ✓ at one line *and chattered at dusk* — the light
/// switching on and off across the threshold every frame — which is the
/// finding that put a correctness column on the list.
///
/// It emits its LEVEL at mount: `in >= on` is true, anything else false. A
/// level with no value on its first evaluation is not a level, and the
/// threshold band makes the mount answer a real choice rather than a
/// crossing's silent baseline.
/// The hysteresis pair, one body (`below` admitted 2026-08-26). `falling` is
/// the whole difference: `above` trips going up and releases going down,
/// `below` trips going down and releases going up.
///
/// **The first number trips and the second releases, for BOTH words** — the
/// ruling that makes the pair readable. `above 0.3 0.2` is "above 0.3, until
/// below 0.2"; `below 0.2 0.3` is "below 0.2, until above 0.3". Neither word
/// asks the reader to remember which of its numbers is the big one, which is
/// exactly what a mirror spelled `above <off> <on>` would have asked.
///
/// So the ORDER CHECK mirrors too, and each word refuses the other's order:
/// `above` needs its release below its trip, `below` needs it above. Both
/// numbers are named. The check runs at eval, and mount runs tick 0, so it is
/// a mount-time refusal — the `along` precedent.
///
/// One shared body rather than two, because the failure mode of two is one of
/// them growing a fix the other never gets; the pair is a mirror or it is two
/// operators that happen to rhyme.
fn hysteresis(comptime falling: bool) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn e(ctx: *EvalCtx) EvalError!Emit {
            const v = try num(ctx, 0);
            const on = try num(ctx, 1);
            const off = try num(ctx, 2);
            if (if (falling) off < on else off > on) {
                return ctx.refuse("{s}: 'off' ({d}) is {s} 'on' ({d}) — hysteresis needs the release {s} the trip", .{
                    ctx.op.name,
                    off,
                    if (falling) "below" else "above",
                    on,
                    if (falling) "above" else "below",
                });
            }
            const st = ctx.state.items;
            const was = st.len > 0 and st[0] == 1;
            const trips = if (falling) v <= on else v >= on;
            const holds = if (falling) v < off else v > off;
            const now = if (st.len == 0) trips else if (was) holds else trips;
            if (st.len > 0 and now == was) return Emit.none;
            try ctx.setState(&.{@intFromBool(now)});
            try ctx.out[0].appendBool(now);
            return Emit.first;
        }
    }.e;
}

// ---------------------------------------------------------------------------
// Over arrays — `map`, `keep`, `reduce` (tier 2, beat 3a)
//
// All three drive a SECTION BODY: an operator with ports left open, called
// once per element with the element in an open port. There is no new syntax —
// rill already had sections — and no closure: a body closes over nothing, so
// "called N times in a fixed order" is the entire contract.
//
// Most map is free (`window 10s | mul 2` IS map, since beat 1b). These are for
// the cases broadcast cannot reach: a body with an argument, a predicate, and
// a fold.
// ---------------------------------------------------------------------------

/// The array on port 0, unpacked, or a refusal naming the type word.
fn arrayIn(ctx: *EvalCtx) EvalError![]const u8 {
    return arrayInAt(ctx, 0);
}

/// …and on any port. `step` is the first array consumer whose array is not
/// its primary input — its port 0 is the ROUSING — and the port-0 assumption
/// hid inside `arrayIn` until then: the refusal it produced was a real
/// refusal, about the right node, saying the wrong thing.
fn arrayInAt(ctx: *EvalCtx, port: usize) EvalError![]const u8 {
    const av = try raw(ctx, port);
    if (types.typeOfValue(av) != Tag.array) {
        return ctx.refuse("{s}: '{s}' is {s}, not an array", .{ ctx.op.name, ctx.portName(port), describeTop(ctx, av) });
    }
    return innerOf(ctx, av);
}

/// `map <body>` — the body once per element, in order. A body that emits
/// nothing is refused rather than dropping the element: `map` preserves
/// length, and a map that silently shortened its array is exactly the kind of
/// wrong picture nobody is told about. Dropping elements is `keep`.
fn evalMap(ctx: *EvalCtx) EvalError!Emit {
    var inner = struple.Packer.init(ctx.arena);
    var r = struple.reader(try arrayIn(ctx));
    var i: usize = 0;
    while (r.nextView() catch return ctx.refuse("map: '{s}' is a malformed array", .{ctx.portName(0)})) |e| : (i += 1) {
        var sub = struple.Packer.init(ctx.arena);
        if (!try ctx.call(&.{e}, &sub)) {
            return ctx.refuse("map: the body emitted nothing for element [{d}] — a map keeps the length; use 'keep' to drop elements", .{i});
        }
        inner.appendRaw(sub.bytes()) catch return ctx.refuse("map: the body produced something unencodable at [{d}]", .{i});
    }
    try ctx.out[0].appendArray(inner.bytes());
    return Emit.first;
}

/// `keep <pred>` — the elements the predicate says true for, unchanged. A
/// second word rather than `where` dispatched by kind: `where` gates a STREAM
/// by a boolean stream, `keep` filters ELEMENTS by a section, and the crossing
/// case (`window 10s | where plane.gate.open`) is real and must keep working.
/// Two axes, so one word would have to guess — see the one-axis rule.
fn evalKeep(ctx: *EvalCtx) EvalError!Emit {
    var inner = struple.Packer.init(ctx.arena);
    var r = struple.reader(try arrayIn(ctx));
    var i: usize = 0;
    while (r.nextView() catch return ctx.refuse("keep: '{s}' is a malformed array", .{ctx.portName(0)})) |e| : (i += 1) {
        var sub = struple.Packer.init(ctx.arena);
        if (!try ctx.call(&.{e}, &sub)) {
            return ctx.refuse("keep: the predicate emitted nothing for element [{d}] — a predicate answers true or false", .{i});
        }
        const verdict = types.asBool(sub.bytes()) orelse
            return ctx.refuse("keep: the predicate answered {s} for element [{d}], not a boolean", .{ describeTop(ctx, sub.bytes()), i });
        if (verdict) inner.appendRaw(e) catch return ctx.refuse("keep: element [{d}] is unencodable", .{i});
    }
    try ctx.out[0].appendArray(inner.bytes());
    return Emit.first;
}

/// `reduce <body> [init <v>]` — a LEFT fold (ruled 2026-08-25). The
/// accumulator fills the body's first open port and the element the second, so
/// `reduce (sub)` reads as the subtraction a reader expects. With no `init`
/// the first element seeds; an empty array with no `init` is an error naming
/// the operator, because there is no honest value to invent — zero is right
/// for `add` and wrong for `mul`, and picking one is picking a rule.
///
/// Recomputed from the array every tick, in fixed order. An incremental
/// running sum drifts in f32 and a recompute does not, and the ledger's line
/// is that an expectation must be faithful to the implementation's arithmetic
/// — so the implementation is the simple one and the gates can assert it.
fn evalReduce(ctx: *EvalCtx) EvalError!Emit {
    var r = struple.reader(try arrayIn(ctx));
    var acc: ?[]const u8 = ctx.in[1]; // the `init` port, absent when unbound
    var i: usize = 0;
    while (r.nextView() catch return ctx.refuse("reduce: '{s}' is a malformed array", .{ctx.portName(0)})) |e| : (i += 1) {
        if (acc == null) {
            acc = e;
            continue;
        }
        var sub = struple.Packer.init(ctx.arena);
        if (!try ctx.call(&.{ acc.?, e }, &sub)) {
            return ctx.refuse("reduce: the body emitted nothing at element [{d}] — a fold needs an answer every step", .{i});
        }
        acc = try ctx.arena.dupe(u8, sub.bytes());
    }
    const final = acc orelse return ctx.refuse("reduce: the array is empty and no 'init' was given — there is no answer to fold to", .{});
    try splice(ctx, 0, final);
    return Emit.first;
}

// ---------------------------------------------------------------------------
// Order — `sort`, `first`, `take` (tier 2, beat 3b)
// ---------------------------------------------------------------------------

/// One element and its sort key, plus where it started. The index is not a
/// tie-break of last resort — it is what makes the sort STABLE regardless of
/// which algorithm runs underneath, so stability is a property of this code
/// and not a property the standard library happens to have today.
const Keyed = struct { key: []const u8, elem: []const u8, i: usize };

fn keyedLess(desc: bool, a: Keyed, b: Keyed) bool {
    // `semanticOrder` compares by VALUE across the numeric encodings — an int
    // 5 and a float 5.0 are equal — where raw `memcmp` would let the type byte
    // dominate and file every int before every float. That distinction is
    // invisible in rill, where both are `number`, so a memcmp sort would be a
    // wrong picture nobody is told about. The cross-type sequence is otherwise
    // the store's own: nil < bool < number < string < array < map.
    //
    // Every key was compared once before the sort (see `evalSort`), so a
    // decode error here cannot be new; `.eq` then defers to the index and the
    // order stays total and deterministic.
    const ord = struple.semanticOrder(std.heap.page_allocator, a.key, b.key) catch std.math.Order.eq;
    return switch (ord) {
        .lt => !desc,
        .gt => desc,
        .eq => a.i < b.i,
    };
}

fn lessAsc(_: void, a: Keyed, b: Keyed) bool {
    return keyedLess(false, a, b);
}

fn lessDesc(_: void, a: Keyed, b: Keyed) bool {
    return keyedLess(true, a, b);
}

/// `sort [by <body>] [desc]` — stable, ascending by default. Without `by` the
/// elements are their own keys; with it, the body computes each key once.
fn evalSort(ctx: *EvalCtx) EvalError!Emit {
    const desc = ctx.statics[0].word.len > 0;
    var rows = std.ArrayListUnmanaged(Keyed).empty;
    var r = struple.reader(try arrayIn(ctx));
    var i: usize = 0;
    while (r.nextView() catch return ctx.refuse("sort: '{s}' is a malformed array", .{ctx.portName(0)})) |e| : (i += 1) {
        var key: []const u8 = e;
        if (ctx.call_fn != null) {
            var sub = struple.Packer.init(ctx.arena);
            if (!try ctx.call(&.{e}, &sub)) {
                return ctx.refuse("sort: the key body emitted nothing for element [{d}] — every element needs a key", .{i});
            }
            key = try ctx.arena.dupe(u8, sub.bytes());
        }
        try rows.append(ctx.arena, .{ .key = key, .elem = e, .i = i });
    }
    // Surface any decode failure ONCE, here, where it can still be a refusal:
    // the comparator cannot fail loudly (it returns bool), so it must not be
    // where a malformed key is first discovered.
    for (rows.items) |row| {
        _ = struple.semanticOrder(ctx.arena, row.key, rows.items[0].key) catch
            return ctx.refuse("sort: element [{d}] has a key that cannot be ordered", .{row.i});
    }
    if (desc) {
        std.sort.pdq(Keyed, rows.items, {}, lessDesc);
    } else {
        std.sort.pdq(Keyed, rows.items, {}, lessAsc);
    }
    var inner = struple.Packer.init(ctx.arena);
    for (rows.items) |row| {
        inner.appendRaw(row.elem) catch return ctx.refuse("sort: element [{d}] is unencodable", .{row.i});
    }
    try ctx.out[0].appendArray(inner.bytes());
    return Emit.first;
}

/// `first` — the leading element. Errors on empty, like `nth`: it promises ONE
/// value and there isn't one. (See the asymmetry note on `take`.)
/// `first` / `last` — the leading and trailing element.
///
/// **An empty array ENDS THE WAVE, silently** (ruled 2026-08-26, replacing
/// beat 3b's refusal). The `where` precedent: a value cannot be invented, and
/// an operator with nothing to say says nothing. A refusal here was the wrong
/// shape — "no contacts" is the ordinary state of a sensor, and the ordinary
/// state of the world should not spend a program's error budget.
///
/// **`nth` keeps erroring**, and the asymmetry is the point twice over. `nth 3`
/// names a position, which is a *claim* that the position exists; `first` names
/// an end, and an empty list simply has none. Same shape as `take`'s
/// forgiveness: a count is satisfiable, a claim is not.
///
/// Absence is then said by the COUNT — `contacts | len | write plane.ui.contacts`
/// — never by a sentinel. That is what `len` was admitted for.
fn endEval(comptime tail: bool) fn (*EvalCtx) EvalError!Emit {
    return struct {
        fn e(ctx: *EvalCtx) EvalError!Emit {
            const items = try arrayIn(ctx);
            var r = struple.reader(items);
            var found: ?[]const u8 = null;
            while (r.nextView() catch return ctx.refuse("{s}: '{s}' is a malformed array", .{ ctx.op.name, ctx.portName(0) })) |v| {
                found = v;
                if (!tail) break;
            }
            const e_ = found orelse return Emit.none; // the empty array is silence
            try splice(ctx, 0, e_);
            return Emit.first;
        }
    }.e;
}

/// `len` — how many elements. Admitted 2026-08-26 with the `first`-on-empty
/// ruling, and by it: once `first` goes quiet there has to be something that
/// says *nothing was there*, and the honest something is the count. Reaching
/// for `stats | .n` to learn a length is the magic-box shape — a statistics
/// package consulted about arithmetic everybody can do.
fn evalLen(ctx: *EvalCtx) EvalError!Emit {
    const view = struple.view(try arrayIn(ctx));
    const n = view.count() catch return ctx.refuse("len: '{s}' is a malformed array", .{ctx.portName(0)});
    try ctx.out[0].appendInt(@intCast(n));
    return Emit.first;
}

/// `take <n> [from <i>]` — up to `n` elements, and **a short array is
/// forgiven**: `[1, 2] | take 5` is `[1, 2]`, not an error.
///
/// The asymmetry with `nth` is deliberate and worth saying out loud. `nth 5`
/// promises *the sixth element* — if there isn't one, the program asked for
/// something that does not exist and the honest answer is a refusal. `take 5`
/// promises *at most five* — "the top three threats" is a sensible thing to
/// ask of a list of two, and the answer is those two. One promises a value,
/// the other bounds a count; the count is satisfiable and the value is not.
/// `from` past the end is the same shape: an empty array, not an error.
fn evalTake(ctx: *EvalCtx) EvalError!Emit {
    const n = try wholeCount(ctx, 1, "n");
    const from = if (ctx.in[2] == null) 0 else try wholeCount(ctx, 2, "from");
    var inner = struple.Packer.init(ctx.arena);
    var r = struple.reader(try arrayIn(ctx));
    var i: usize = 0;
    var taken: usize = 0;
    while (taken < n) : (i += 1) {
        const e = (r.nextView() catch return ctx.refuse("take: '{s}' is a malformed array", .{ctx.portName(0)})) orelse break;
        if (i < from) continue;
        inner.appendRaw(e) catch return ctx.refuse("take: element [{d}] is unencodable", .{i});
        taken += 1;
    }
    try ctx.out[0].appendArray(inner.bytes());
    return Emit.first;
}

/// A whole non-negative count on port `i`. A fractional or negative count is
/// refused rather than rounded or clamped — the same rule `nth` applies to an
/// index, because both are counts and rounding one is a guess.
fn wholeCount(ctx: *EvalCtx, i: usize, what: []const u8) EvalError!usize {
    const v = try raw(ctx, i);
    const f = types.asNumber(v) orelse
        return ctx.refuse("{s}: '{s}' is {s}, not a number", .{ ctx.op.name, what, describeTop(ctx, v) });
    if (!std.math.isFinite(f) or f != @floor(f) or f < 0) {
        return ctx.refuse("{s}: '{s}' is {d} — a count is a whole number from 0", .{ ctx.op.name, what, f });
    }
    return @intFromFloat(f);
}

// ---------------------------------------------------------------------------
// Shape and curve — `transpose`, `shuffle`, `along` (tier 2, beat 3b)
// ---------------------------------------------------------------------------

/// `transpose` — AoS ↔ SoA, one word because the operation is self-inverse.
/// The dispatch is honest by the one-axis rule: one question (record or
/// array?), disjoint kinds.
///
/// **Ragged input refuses, in both directions, with both sides named.**
/// Grasshopper picks a matching rule implicitly — longest, shortest,
/// cross-reference — and it is the most-complained-about behaviour in the
/// tool. Never pick a rule.
fn evalTranspose(ctx: *EvalCtx) EvalError!Emit {
    const v = try raw(ctx, 0);
    return switch (types.typeOfValue(v)) {
        Tag.record => transposeRecord(ctx, v),
        Tag.array => transposeArray(ctx, v),
        else => ctx.refuse("transpose: '{s}' is {s} — it takes a record of arrays or an array of records", .{ ctx.portName(0), describeTop(ctx, v) }),
    };
}

/// {a: [1, 2], b: [3, 4]} → [{a: 1, b: 3}, {a: 2, b: 4}]
fn transposeRecord(ctx: *EvalCtx, v: []const u8) EvalError!Emit {
    var names = std.ArrayListUnmanaged([]const u8).empty; // encoded keys
    var cols = std.ArrayListUnmanaged([]const u8).empty; // encoded array values
    var it = struple.MapView.init(try innerOf(ctx, v)).iterator();
    var n: ?usize = null;
    var n_of: []const u8 = "";
    while (it.next() catch return ctx.refuse("transpose: '{s}' is a malformed record", .{ctx.portName(0)})) |e| {
        const field = types.asString(e.key) orelse "?";
        if (types.typeOfValue(e.value) != Tag.array) {
            return ctx.refuse("transpose: field '{s}' is {s}, not an array — a record of arrays needs every field to be one", .{ field, describeTop(ctx, e.value) });
        }
        const len = struple.view(try innerOf(ctx, e.value)).count() catch
            return ctx.refuse("transpose: field '{s}' is a malformed array", .{field});
        if (n) |have| {
            if (len != have) {
                return ctx.refuse("transpose: field '{s}' has {d} element{s} and '{s}' has {d} — a transpose needs them equal", .{ n_of, have, if (have == 1) "" else "s", field, len });
            }
        } else {
            n = len;
            n_of = field;
        }
        try names.append(ctx.arena, e.key);
        try cols.append(ctx.arena, e.value);
    }
    var rows = struple.Packer.init(ctx.arena);
    var row: usize = 0;
    while (row < (n orelse 0)) : (row += 1) {
        var entries = std.ArrayListUnmanaged([2][]const u8).empty;
        for (names.items, cols.items) |k, col| {
            const cell = (struple.view(try innerOf(ctx, col)).at(row) catch null) orelse
                return ctx.refuse("transpose: a column is a malformed array", .{});
            try entries.append(ctx.arena, .{ k, cell });
        }
        var one = struple.Packer.init(ctx.arena);
        one.appendMap(entries.items) catch return ctx.refuse("transpose: row [{d}] is unencodable", .{row});
        rows.appendRaw(one.bytes()) catch return ctx.refuse("transpose: row [{d}] is unencodable", .{row});
    }
    try ctx.out[0].appendArray(rows.bytes());
    return Emit.first;
}

/// [{a: 1, b: 3}, {a: 2, b: 4}] → {a: [1, 2], b: [3, 4]}
fn transposeArray(ctx: *EvalCtx, v: []const u8) EvalError!Emit {
    var names = std.ArrayListUnmanaged([]const u8).empty; // encoded keys, from row 0
    var cols = std.ArrayListUnmanaged(struple.Packer).empty;
    var r = struple.reader(try innerOf(ctx, v));
    var row: usize = 0;
    while (r.nextView() catch return ctx.refuse("transpose: '{s}' is a malformed array", .{ctx.portName(0)})) |e| : (row += 1) {
        if (types.typeOfValue(e) != Tag.record) {
            return ctx.refuse("transpose: element [{d}] is {s}, not a record — an array of records needs every element to be one", .{ row, describeTop(ctx, e) });
        }
        const m = struple.MapView.init(try innerOf(ctx, e));
        if (row == 0) {
            var it = m.iterator();
            while (it.next() catch return ctx.refuse("transpose: element [0] is a malformed record", .{})) |en| {
                try names.append(ctx.arena, en.key);
                try cols.append(ctx.arena, struple.Packer.init(ctx.arena));
            }
        }
        const count = m.count() catch return ctx.refuse("transpose: element [{d}] is a malformed record", .{row});
        if (count != names.items.len) {
            return ctx.refuse("transpose: element [0] is {s} and element [{d}] is {s} — a transpose needs the same field set", .{ describeTop(ctx, try structOf(ctx, v, 0)), row, describeTop(ctx, e) });
        }
        for (names.items, 0..) |k, ci| {
            const cell = (m.get(k) catch null) orelse
                return ctx.refuse("transpose: element [{d}] has no field '{s}', which element [0] has", .{ row, keyName(k) });
            cols.items[ci].appendRaw(cell) catch return ctx.refuse("transpose: element [{d}] is unencodable", .{row});
        }
    }
    var entries = std.ArrayListUnmanaged([2][]const u8).empty;
    for (names.items, 0..) |k, ci| {
        var col = struple.Packer.init(ctx.arena);
        col.appendArray(cols.items[ci].bytes()) catch return ctx.refuse("transpose: a column is unencodable", .{});
        try entries.append(ctx.arena, .{ k, col.bytes() });
    }
    try ctx.out[0].appendMap(entries.items);
    return Emit.first;
}

fn structOf(ctx: *EvalCtx, arr: []const u8, i: usize) EvalError![]const u8 {
    return (struple.view(try innerOf(ctx, arr)).at(i) catch null) orelse "";
}

/// `shuffle [seed <s>]` — Fisher–Yates over a xoshiro256++ stream. Integer
/// hashing only, so the permutation is bit-identical across machines, and the
/// seed defaults to 0 so a program that says nothing still replays. Same seed,
/// same array, same answer, every tick — which is what "deterministic in fed
/// time" requires of an operator that re-runs on every change.
fn evalShuffle(ctx: *EvalCtx) EvalError!Emit {
    const seed: u64 = if (ctx.in[1] == null) 0 else blk: {
        const f = try num(ctx, 1);
        if (!std.math.isFinite(f) or f != @floor(f) or f < 0) {
            return ctx.refuse("shuffle: 'seed' is {d} — a seed is a whole number from 0", .{f});
        }
        break :blk @intFromFloat(f);
    };
    var items = std.ArrayListUnmanaged([]const u8).empty;
    var r = struple.reader(try arrayIn(ctx));
    while (r.nextView() catch return ctx.refuse("shuffle: '{s}' is a malformed array", .{ctx.portName(0)})) |e| {
        try items.append(ctx.arena, e);
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var i = items.items.len;
    while (i > 1) {
        i -= 1;
        const j = rand.uintLessThan(usize, i + 1);
        const tmp = items.items[i];
        items.items[i] = items.items[j];
        items.items[j] = tmp;
    }
    var inner = struple.Packer.init(ctx.arena);
    for (items.items) |e| {
        inner.appendRaw(e) catch return ctx.refuse("shuffle: an element is unencodable", .{});
    }
    try ctx.out[0].appendArray(inner.bytes());
    return Emit.first;
}

/// The uniform Catmull-Rom basis at `u`, tension ½. At u=0 it is (0,1,0,0) and
/// at u=1 it is (0,0,1,0), so a knot is passed through exactly.
fn catmullWeights(u: f64) [4]f64 {
    const uu = u * u;
    const uuu = uu * u;
    return .{
        0.5 * (-u + 2 * uu - uuu),
        0.5 * (2 - 5 * uu + 3 * uuu),
        0.5 * (u + 4 * uu - 3 * uuu),
        0.5 * (-uu + uuu),
    };
}

/// Blend four knots elementwise. Numbers blend; records and arrays recurse,
/// with the SAME shape rules and the same vocabulary as beat 1b's broadcast —
/// a curve through positions is a curve through each axis.
fn blend4(ctx: *EvalCtx, pk: *struple.Packer, w: [4]f64, k: [4][]const u8, path: []const u8) EvalError!void {
    const kind = types.typeOfValue(k[1]);
    if (kind == Tag.record) {
        var entries = std.ArrayListUnmanaged([2][]const u8).empty;
        var it = struple.MapView.init(try innerRefusing(ctx, "along", path, k[1])).iterator();
        while (it.next() catch return ctx.refuse("along: a malformed knot{s}", .{whereIn(ctx, path)})) |e| {
            var sub: [4][]const u8 = undefined;
            for (k, 0..) |kn, i| {
                const m = struple.MapView.init(try innerRefusing(ctx, "along", path, kn));
                sub[i] = (m.get(e.key) catch null) orelse
                    return ctx.refuse("along: one knot has '{s}' and another does not — every knot needs the same shape", .{keyName(e.key)});
            }
            var one = struple.Packer.init(ctx.arena);
            try blend4(ctx, &one, w, sub, pathField(ctx, path, e.key));
            try entries.append(ctx.arena, .{ e.key, one.bytes() });
        }
        pk.appendMap(entries.items) catch return ctx.refuse("along: a knot is unencodable{s}", .{whereIn(ctx, path)});
        return;
    }
    if (kind == Tag.array) {
        const n = struple.view(try innerRefusing(ctx, "along", path, k[1])).count() catch
            return ctx.refuse("along: a malformed knot{s}", .{whereIn(ctx, path)});
        var elems = struple.Packer.init(ctx.arena);
        var idx: usize = 0;
        while (idx < n) : (idx += 1) {
            var sub: [4][]const u8 = undefined;
            for (k, 0..) |kn, i| {
                sub[i] = (struple.view(try innerRefusing(ctx, "along", path, kn)).at(idx) catch null) orelse
                    return ctx.refuse("along: the knots are arrays of different lengths — every knot needs the same shape", .{});
            }
            var one = struple.Packer.init(ctx.arena);
            try blend4(ctx, &one, w, sub, pathIndex(ctx, path, idx));
            elems.appendRaw(one.bytes()) catch return ctx.refuse("along: a knot is unencodable{s}", .{whereIn(ctx, path)});
        }
        pk.appendArray(elems.bytes()) catch return ctx.refuse("along: a knot is unencodable{s}", .{whereIn(ctx, path)});
        return;
    }
    var acc: f64 = 0;
    for (k, 0..) |kn, i| {
        acc += w[i] * (types.asNumber(kn) orelse
            return ctx.refuse("along: a knot is {s}, not a number{s}", .{ describeTop(ctx, kn), whereIn(ctx, path) }));
    }
    try pk.appendF64(acc);
}

// ---------------------------------------------------------------------------
// `step` — a step sequencer, modelled on an arpeggiator (envelopes item 8)
//
// A rousing in, the NEXT element out. The array is a value like any other, so
// `step` is what turns a value with several parts into a sequence through
// them, one rousing at a time.
//
// **The modes compose rather than being five alternatives**, and that is a
// recorded deviation from Chris's wording ("modes as bare-word flags:
// default runs once and the wave ends; loop, bounce, reverse, random seed <s>,
// shuffle seed <s>"). His own description of `shuffle` is what argues it: *a
// fresh permutation per PASS, no repeats within one* — passes are what `loop`
// means, so `shuffle` and `loop` have to be sayable together or `shuffle` can
// only ever mean one pass. Once two of them compose, the flat reading is
// already gone, and `loop reverse` (a camera cycling backwards forever) is a
// thing a person will want on their first afternoon.
//
// So there are two independent choices and one modifier:
//
//   ORDER   sequential (default) · `random` (with replacement) · `shuffle`
//   REPEAT  once (default, and the wave ends) · `loop` · `bounce`
//   `reverse` — sequential only: start at the end and walk down
//
// The combinations that cannot mean anything are REFUSED at mount, naming both
// words: `random shuffle`, `loop bounce`, `reverse` with either random order,
// `bounce` with either random order, and a `seed` with no random order to seed.
// A knob that does nothing is a lie, and `step [1, 2] seed 7` is someone who
// meant to write a mode.
// ---------------------------------------------------------------------------

const StepOrder = enum { sequential, random, shuffle };
const StepRepeat = enum { once, loop, bounce };

/// The cursor, and it rides the dump — a sequencer that restarted on restore
/// would be a different instrument.
const StepState = struct {
    pos: i64 = 0, // sequential: the index. shuffle: the position in the pass.
    dir: i8 = 1, // +1 or -1; only `bounce` ever turns it round
    pass: u64 = 0, // completed passes — `shuffle`'s permutation salt
    emitted: u64 = 0, // total emissions — `max`'s counter and `random`'s draw
    started: bool = false,
    done: bool = false,

    const size = 8 + 1 + 8 + 8 + 1 + 1;

    fn read(ctx: *EvalCtx) StepState {
        const st = ctx.state.items;
        if (st.len < size) return .{};
        return .{
            .pos = @bitCast(std.mem.readInt(u64, st[0..8], .little)),
            .dir = @bitCast(st[8]),
            .pass = std.mem.readInt(u64, st[9..17], .little),
            .emitted = std.mem.readInt(u64, st[17..25], .little),
            .started = st[25] == 1,
            .done = st[26] == 1,
        };
    }

    fn write(self: StepState, ctx: *EvalCtx) EvalError!void {
        var buf: [size]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], @as(u64, @bitCast(self.pos)), .little);
        buf[8] = @bitCast(self.dir);
        std.mem.writeInt(u64, buf[9..17], self.pass, .little);
        std.mem.writeInt(u64, buf[17..25], self.emitted, .little);
        buf[25] = @intFromBool(self.started);
        buf[26] = @intFromBool(self.done);
        try ctx.setState(&buf);
    }
};

/// A whole non-negative number off an optional port, or a refusal naming it.
fn wholeOpt(ctx: *EvalCtx, port: usize) EvalError!?u64 {
    if (ctx.in[port] == null) return null;
    const f = try num(ctx, port);
    if (!std.math.isFinite(f) or f != @floor(f) or f < 0) {
        return ctx.refuse("{s}: '{s}' is {d} — a whole number from 0", .{ ctx.op.name, ctx.portName(port), f });
    }
    return @intFromFloat(f);
}

/// The permutation for one pass, derived rather than stored: `shuffle`'s state
/// is a pass number and a position, never an N-element table. The array is
/// LIVE, so a stored permutation would be stale the moment it changed length —
/// and a dump would carry a table that no longer described anything.
///
/// Fisher–Yates on `std.Random.DefaultPrng` (xoshiro256++), which is the one
/// PRNG family (beat 4's pin): `rand`, `shuffle` and this all draw from it,
/// re-seeded from a counter the way `rand` already does.
fn passOrder(ctx: *EvalCtx, seed: u64, pass: u64, n: usize) EvalError![]usize {
    const idx = try ctx.arena.alloc(usize, n);
    for (idx, 0..) |*v, i| v.* = i;
    var prng = std.Random.DefaultPrng.init(seed +% pass *% 0x9E3779B97F4A7C15);
    const rnd = prng.random();
    var i = n;
    while (i > 1) {
        i -= 1;
        const j = rnd.uintLessThan(usize, i + 1);
        std.mem.swap(usize, &idx[i], &idx[j]);
    }
    return idx;
}

fn evalStep(ctx: *EvalCtx) EvalError!Emit {
    const has_loop = ctx.statics[0].word.len > 0;
    const has_bounce = ctx.statics[1].word.len > 0;
    const has_reverse = ctx.statics[2].word.len > 0;
    const has_random = ctx.statics[3].word.len > 0;
    const has_shuffle = ctx.statics[4].word.len > 0;

    // The refusals, before anything else and therefore at mount: a program
    // that cannot mean anything should not run for a while first.
    if (has_random and has_shuffle) {
        return ctx.refuse("step: 'random' and 'shuffle' are both orders — random draws with replacement, shuffle is a permutation; pick one", .{});
    }
    if (has_loop and has_bounce) {
        return ctx.refuse("step: 'loop' and 'bounce' both say what happens at the end — loop wraps, bounce turns round; pick one", .{});
    }
    const randomish = has_random or has_shuffle;
    const order: StepOrder = if (has_random) .random else if (has_shuffle) .shuffle else .sequential;
    if (has_reverse and randomish) {
        return ctx.refuse("step: 'reverse' and '{s}' cannot go together — a random order has no direction to reverse", .{if (has_random) "random" else "shuffle"});
    }
    if (has_bounce and randomish) {
        // `bounce` turns round inside a fixed order. `random` has no ends to
        // turn round at, and `shuffle` re-draws its order every pass — so
        // there is nothing stable to walk back through either way.
        return ctx.refuse("step: 'bounce' and '{s}' cannot go together — bounce turns round inside a fixed order, and a random one has none", .{if (has_random) "random" else "shuffle"});
    }
    const repeat: StepRepeat = if (has_loop) .loop else if (has_bounce) .bounce else .once;
    if (ctx.in[2] != null and !randomish) {
        return ctx.refuse("step: 'seed' has nothing to seed — a seed only means something with 'random' or 'shuffle'", .{});
    }

    const seed = (try wholeOpt(ctx, 2)) orelse 0;
    const max = try wholeOpt(ctx, 3);

    var st = StepState.read(ctx);
    if (st.done) return Emit.none;
    // The sequence advances on ROUSINGS. A change to the array is not one:
    // the array is live, and living is not stepping.
    if (!ctx.in_fresh[0]) return Emit.none;
    _ = try raw(ctx, 0);

    const items = try arrayInAt(ctx, 1);
    var view = struple.view(items);
    const n = view.count() catch return ctx.refuse("step: '{s}' is a malformed array", .{ctx.portName(1)});
    // An empty array has nothing to step through, and a value cannot be
    // invented — the `first` precedent. Silence, not a refusal, and not `done`
    // either: the array is live and may yet have something in it.
    if (n == 0) return Emit.none;

    if (max) |m| {
        if (st.emitted >= m) {
            st.done = true;
            try st.write(ctx);
            return Emit.none;
        }
    }

    // The array is LIVE: a cursor into an array that shrank carries and CLAMPS
    // to the new length. It does not restart — the sequence a person is
    // listening to should not jump back to the top because a list got shorter.
    const last: i64 = @intCast(n - 1);
    if (st.pos > last) st.pos = last;
    if (st.pos < 0) st.pos = 0;

    const index: usize = switch (order) {
        .random => blk: {
            var prng = std.Random.DefaultPrng.init(seed +% st.emitted *% 0x9E3779B97F4A7C15);
            break :blk prng.random().uintLessThan(usize, n);
        },
        .sequential, .shuffle => blk: {
            if (!st.started) {
                st.started = true;
                st.dir = if (has_reverse) -1 else 1;
                st.pos = if (has_reverse) last else 0;
            } else {
                var next = st.pos + st.dir;
                if (next > last or next < 0) {
                    switch (repeat) {
                        .once => {
                            st.done = true;
                            try st.write(ctx);
                            return Emit.none;
                        },
                        .loop => {
                            next = if (st.dir > 0) 0 else last;
                            st.pass +%= 1; // a new permutation, for `shuffle`
                        },
                        .bounce => {
                            st.dir = -st.dir;
                            next = st.pos + st.dir;
                            if (next > last or next < 0) next = st.pos; // n == 1
                            st.pass +%= 1;
                        },
                    }
                }
                st.pos = next;
            }
            if (order == .shuffle) {
                const perm = try passOrder(ctx, seed, st.pass, n);
                break :blk perm[@intCast(st.pos)];
            }
            break :blk @intCast(st.pos);
        },
    };

    const elem = (view.at(index) catch null) orelse
        return ctx.refuse("step: '{s}' is a malformed array", .{ctx.portName(1)});
    st.emitted +%= 1;
    try st.write(ctx);
    try splice(ctx, 0, elem);
    return Emit.first;
}

/// `along <knots>` — travel a curve through the knots as `t` goes 0..1.
/// Catmull-Rom, so the curve passes through every knot; ends are clamped by
/// duplicating the terminal knot, and `t` outside 0..1 clamps rather than
/// extrapolating (a path has ends).
///
/// **Fewer than two knots refuses**, and because mount runs tick 0 that lands
/// at mount for every mounted program. One knot is not a path.
/// The curve `along` draws, in plain numbers — same segment split, same
/// duplicated endpoints, same basis. `at` is the GLOBAL parameter in
/// `[0, n-1]`, which is what `along` computes from `t` before it blends.
///
/// It exists separately from `blend4` because `nearest` evaluates the curve
/// hundreds of times per tick and `blend4` packs a struple value each time. The
/// two must not drift: `nearest` claims to be `along`'s inverse, and an inverse
/// of a different curve is a lie. The gate below holds them together by
/// round-tripping through the real `along` — in both modes.
///
/// Under `loop` there are n segments, not n−1: the closing segment from the
/// last knot back to the first is a segment like any other, and the tangent
/// neighbours wrap with it. `at` wraps too (floored, like the `mod` word), so
/// any real parameter lands on the circuit — which is what lets `nearest`'s
/// narrowing straddle the seam without noticing it.
fn curveAt(knots: []const [3]f64, at: f64, loop: bool) [3]f64 {
    const n = knots.len;
    var seg: usize = undefined;
    var u: f64 = undefined;
    var k: [4][3]f64 = undefined;
    if (loop) {
        const span: f64 = @floatFromInt(n);
        const a = @mod(at, span);
        seg = @intFromFloat(@floor(a));
        if (seg > n - 1) seg = n - 1; // @mod may graze span from below
        u = a - @as(f64, @floatFromInt(seg));
        k = .{
            knots[(seg + n - 1) % n],
            knots[seg],
            knots[(seg + 1) % n],
            knots[(seg + 2) % n],
        };
    } else {
        seg = @intFromFloat(@floor(at));
        if (seg > n - 2) seg = n - 2;
        u = at - @as(f64, @floatFromInt(seg));
        k = .{
            knots[if (seg == 0) 0 else seg - 1],
            knots[seg],
            knots[seg + 1],
            knots[if (seg + 2 > n - 1) n - 1 else seg + 2],
        };
    }
    const w = catmullWeights(u);
    var out: [3]f64 = .{ 0, 0, 0 };
    for (0..3) |c| {
        out[c] = w[0] * k[0][c] + w[1] * k[1][c] + w[2] * k[2][c] + w[3] * k[3][c];
    }
    return out;
}

/// What `loop` refuses, shared verbatim by `along` and `nearest` so the two
/// words cannot drift on what a loop is. Three knots is the smallest closed
/// circuit — through two, the wrapped basis degenerates to a straight
/// there-and-back, which an open curve already says. And a first knot
/// repeated as the last is the OPEN-curve closing idiom (rail.rill's
/// original spelling): under `loop` the closing segment already exists, so
/// the duplicate would add a zero-length segment with a cusp exactly where
/// the seam kink used to be — the thing `loop` exists to remove.
fn refuseOpenLoop(ctx: *EvalCtx, comptime word: []const u8, view: anytype, n: usize) EvalError!void {
    if (n < 3) {
        return ctx.refuse(word ++ ": {d} knots is not a loop — a loop needs at least three", .{n});
    }
    const first = (view.at(0) catch null) orelse
        return ctx.refuse(word ++ ": '{s}' is a malformed array", .{ctx.portName(1)});
    const last = (view.at(n - 1) catch null) orelse
        return ctx.refuse(word ++ ": '{s}' is a malformed array", .{ctx.portName(1)});
    if (std.mem.eql(u8, first, last)) {
        return ctx.refuse(word ++ ": the first knot and the last are the same point — a loop closes itself; drop the duplicate", .{});
    }
}

fn sqDist(a: [3]f64, b: [3]f64) f64 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}

/// Coarse samples per segment for `nearest`'s first pass. Enough that a bracket
/// of two steps contains one minimum for any curve a person would author, and
/// cheap enough to run every tick: this is 24 multiply-adds per segment, not 24
/// allocations.
const NEAREST_SAMPLES = 24;
/// Ternary-narrowing rounds after the coarse pass. Each keeps 2/3 of the
/// bracket, so 60 rounds take it to ~1e-11 of a segment — past f32 print
/// precision, and a FIXED count, because a rill program that took a different
/// number of iterations on Tuesday would not replay.
const NEAREST_ROUNDS = 60;

/// `nearest <p> <knots>` — where on the curve you are, as `t` in 0..1.
///
/// The exact inverse of `along`, and it emits the PARAMETER rather than the
/// point on purpose. `nearest … | along …` recovers the point in one more word,
/// while `t` on its own is progress round a circuit, lap detection, and — via
/// `diff` — which way you are facing along it. A word that returned the point
/// would throw all of that away.
///
/// Chris hit exactly this in Blade3D twenty years ago: `GetClosestPoint`
/// returned a position and no caller could recover the parameter, so the
/// follower could not use it and the source carries a comment wishing it could.
///
/// The search is a coarse scan then a ternary narrowing, and it **terminates on
/// bracket width**. Blade3D's terminated when the two probes were equidistant,
/// which is true at the first step whenever the query point sits ON the curve —
/// the one case a follower is in almost always — and it bailed out at t≈0.25.
/// The gate below stands on the curve and asks.
fn evalNearest(ctx: *EvalCtx) EvalError!Emit {
    const pos = try axis(ctx, 0, ctx.portName(0));
    const kv = try raw(ctx, 1);
    if (types.typeOfValue(kv) != Tag.array) {
        return ctx.refuse("nearest: '{s}' is {s}, not an array of knots", .{ ctx.portName(1), describeTop(ctx, kv) });
    }
    const view = struple.view(try innerOf(ctx, kv));
    const n = view.count() catch return ctx.refuse("nearest: '{s}' is a malformed array", .{ctx.portName(1)});
    if (n < 2) {
        return ctx.refuse("nearest: {d} knot{s} is not a path — `nearest` needs at least two", .{ n, if (n == 1) "" else "s" });
    }
    const loop = ctx.statics[0].word.len > 0;
    if (loop) try refuseOpenLoop(ctx, "nearest", view, n);

    const knots = ctx.arena.alloc([3]f64, n) catch return ctx.refuse("nearest: out of memory", .{});
    for (0..n) |i| {
        const kn = (view.at(i) catch null) orelse
            return ctx.refuse("nearest: '{s}' is a malformed array", .{ctx.portName(1)});
        knots[i] = try axisOf(ctx, kn, ctx.portName(1));
    }

    // A loop has one more segment than the open curve: the closing one.
    const segs = if (loop) n else n - 1;
    const span: f64 = @floatFromInt(segs);
    const samples = segs * NEAREST_SAMPLES;
    const step = span / @as(f64, @floatFromInt(samples));

    // Coarse pass over the WHOLE curve. Blade3D scanned only the knots and then
    // searched one segment, so a long segment whose interior was nearest but
    // whose endpoints were far returned the wrong point.
    var best_at: f64 = 0;
    var best_d2 = sqDist(pos, curveAt(knots, 0, loop));
    var i: usize = 1;
    while (i <= samples) : (i += 1) {
        const at = @min(span, @as(f64, @floatFromInt(i)) * step);
        const d2 = sqDist(pos, curveAt(knots, at, loop));
        if (d2 < best_d2) {
            best_d2 = d2;
            best_at = at;
        }
    }

    // Narrow the bracket the coarse winner sits in. Fixed rounds, width
    // termination — never a "the probes agree" test. On a loop the bracket may
    // straddle the seam — `lo` below 0 or `hi` past the span — and `curveAt`
    // wraps, so the narrowing never notices the seam; an open curve pins the
    // bracket inside its ends instead.
    var lo = if (loop) best_at - step else @max(0.0, best_at - step);
    var hi = if (loop) best_at + step else @min(span, best_at + step);
    var round: usize = 0;
    while (round < NEAREST_ROUNDS) : (round += 1) {
        const third = (hi - lo) / 3.0;
        const m1 = lo + third;
        const m2 = hi - third;
        if (sqDist(pos, curveAt(knots, m1, loop)) < sqDist(pos, curveAt(knots, m2, loop))) hi = m2 else lo = m1;
    }
    // Pick the best of the bracket's ends and its middle, rather than trusting
    // the middle. When the minimum sits AT an end of the curve the narrowing
    // creeps toward that end without ever arriving — `hi` stays exactly `span`
    // while `lo` climbs — so the midpoint answers 0.9999999999998 where the
    // true answer is 1. Comparing the ends costs two evaluations and makes
    // `nearest | along` land exactly on the last knot instead of near it.
    // (A loop has no ends, but the comparison stays: it is two evaluations,
    // and the bracket's best is the bracket's best either way.)
    const mid = (lo + hi) * 0.5;
    var at = mid;
    var d2 = sqDist(pos, curveAt(knots, mid, loop));
    for ([_]f64{ lo, hi }) |cand| {
        const cd2 = sqDist(pos, curveAt(knots, cand, loop));
        if (cd2 < d2) {
            d2 = cd2;
            at = cand;
        }
    }
    // On a loop the seam is one point wearing two numbers; emit it canonically
    // in [0, 1) — the floored `@mod` sends `span` to 0.
    return emitF64(ctx, if (loop) @mod(at, span) / span else at / span);
}

fn evalAlong(ctx: *EvalCtx) EvalError!Emit {
    const t = try num(ctx, 0);
    const kv = try raw(ctx, 1);
    if (types.typeOfValue(kv) != Tag.array) {
        return ctx.refuse("along: '{s}' is {s}, not an array of knots", .{ ctx.portName(1), describeTop(ctx, kv) });
    }
    const view = struple.view(try innerOf(ctx, kv));
    const n = view.count() catch return ctx.refuse("along: '{s}' is a malformed array", .{ctx.portName(1)});
    if (n < 2) {
        return ctx.refuse("along: {d} knot{s} is not a path — `along` needs at least two", .{ n, if (n == 1) "" else "s" });
    }
    const loop = ctx.statics[0].word.len > 0;
    var seg: usize = undefined;
    var u: f64 = undefined;
    var idx: [4]usize = undefined;
    if (loop) {
        try refuseOpenLoop(ctx, "along", view, n);
        // A loop has no ends, so t WRAPS where the open curve clamps —
        // floored like the `mod` word, so t=1 IS t=0 and −0.25 is 0.75. The
        // closing segment from the last knot back to the first is a segment
        // like any other, and the tangent neighbours wrap with it: entering
        // the seam and leaving it read the same four knots, which is the
        // whole cure for the once-per-lap kink.
        const at = @mod(t, 1.0) * @as(f64, @floatFromInt(n));
        seg = @intFromFloat(@floor(at));
        if (seg > n - 1) seg = n - 1; // @mod may graze 1 from below
        u = at - @as(f64, @floatFromInt(seg));
        idx = .{ (seg + n - 1) % n, seg, (seg + 1) % n, (seg + 2) % n };
    } else {
        const at = @min(1.0, @max(0.0, t)) * @as(f64, @floatFromInt(n - 1));
        seg = @intFromFloat(@floor(at));
        if (seg > n - 2) seg = n - 2; // t == 1 lands on the last segment's end
        u = at - @as(f64, @floatFromInt(seg));
        idx = .{
            if (seg == 0) 0 else seg - 1,
            seg,
            seg + 1,
            if (seg + 2 > n - 1) n - 1 else seg + 2,
        };
    }
    var k: [4][]const u8 = undefined;
    for (idx, 0..) |ix, i| {
        k[i] = (view.at(ix) catch null) orelse return ctx.refuse("along: '{s}' is a malformed array", .{ctx.portName(1)});
    }
    try blend4(ctx, &ctx.out[0], catmullWeights(u), k, "");
    return Emit.first;
}

// ---------------------------------------------------------------------------
// Contracts — `expect` and `match` (tier 2, beat 2b)
//
// One shape literal, two promises. `expect` asserts ONCE, at mount, and its
// refusal fails the mount (`OpDef.fails_mount`); `match` asserts every value
// and its refusal kills that wave. Neither degrades into the other: `expect`
// never becomes a runtime check (that would hide cost) and `match` never
// becomes a guarantee.
//
// Both are passthroughs. A contract is documentation ON THE WIRE, so it sits
// mid-chain and the value continues.
// ---------------------------------------------------------------------------

const Shape = struct { exact: bool, body: []const u8 };

/// Unwrap the `{exact: bool, shape: <s>}` the parser encoded.
fn shapeStatic(ctx: *EvalCtx) EvalError!Shape {
    const enc = ctx.statics[0].shape;
    const m = struple.MapView.init(try innerOf(ctx, enc));
    var kp = struple.Packer.init(ctx.arena);
    try kp.appendString("exact");
    const ex = (m.get(kp.bytes()) catch null) orelse return ctx.refuse("{s}: the shape is malformed", .{ctx.op.name});
    var ks = struple.Packer.init(ctx.arena);
    try ks.appendString("shape");
    const body = (m.get(ks.bytes()) catch null) orelse return ctx.refuse("{s}: the shape is malformed", .{ctx.op.name});
    return .{ .exact = types.asBool(ex) orelse false, .body = body };
}

/// A shape rendered in the SAME vocabulary `describe` prints values in, so a
/// refusal's two sides are one language: `number`, `[number]`,
/// `record{id, distance}`. Optional fields keep their `?` — what the author
/// wrote is what the message shows back.
fn describeShape(ctx: *EvalCtx, shape: []const u8) []const u8 {
    const t = types.typeOfValue(shape);
    if (t == Tag.string) return types.asString(shape) orelse "?";
    if (t == Tag.array) {
        const inner = innerOf(ctx, shape) catch return "[?]";
        var r = struple.reader(inner);
        const first = (r.nextView() catch return "[?]") orelse return "[]";
        return std.fmt.allocPrint(ctx.arena, "[{s}]", .{describeShape(ctx, first)}) catch "[?]";
    }
    if (t == Tag.record) {
        var out = std.ArrayListUnmanaged(u8).empty;
        out.appendSlice(ctx.arena, "record{") catch return "record{?}";
        var it = struple.MapView.init(innerOf(ctx, shape) catch return "record{?}").iterator();
        var first = true;
        while (it.next() catch return "record{?}") |e| {
            if (!first) out.appendSlice(ctx.arena, ", ") catch return "record{?}";
            first = false;
            out.appendSlice(ctx.arena, types.asString(e.key) orelse "?") catch return "record{?}";
        }
        out.appendSlice(ctx.arena, "}") catch return "record{?}";
        return out.items;
    }
    return "?";
}

/// "the value" at the top, "'<path>'" once inside — so a top-level complaint
/// doesn't read "'' is string".
fn shapeWhere(ctx: *EvalCtx, path: []const u8) []const u8 {
    if (path.len == 0) return "the value";
    return std.fmt.allocPrint(ctx.arena, "'{s}'", .{path}) catch "the value";
}

fn shapeMismatch(ctx: *EvalCtx, path: []const u8, value: []const u8, shape: []const u8) EvalError {
    return ctx.refuse("{s}: {s} is {s}, not {s}", .{
        ctx.op.name, shapeWhere(ctx, path), describeTop(ctx, value), describeShape(ctx, shape),
    });
}

/// The whole check, recursive. Refuses on the FIRST mismatch and names the
/// field: a list of everything wrong reads as a compiler, and the first one is
/// almost always the cause of the rest.
fn shapeCheck(ctx: *EvalCtx, exact: bool, shape: []const u8, value: []const u8, path: []const u8) EvalError!void {
    switch (types.typeOfValue(shape)) {
        Tag.string => {
            const word = types.asString(shape) orelse return ctx.refuse("{s}: the shape is malformed", .{ctx.op.name});
            if (std.mem.eql(u8, word, "any")) return; // present is the whole promise
            const want: types.TypeId = if (std.mem.eql(u8, word, "number"))
                Tag.number
            else if (std.mem.eql(u8, word, "boolean"))
                Tag.boolean
            else
                Tag.string;
            if (types.typeOfValue(value) != want) return shapeMismatch(ctx, path, value, shape);
        },
        Tag.array => {
            if (types.typeOfValue(value) != Tag.array) return shapeMismatch(ctx, path, value, shape);
            const elem_shape = blk: {
                var r = struple.reader(try innerOf(ctx, shape));
                break :blk (r.nextView() catch null) orelse return ctx.refuse("{s}: the shape is malformed", .{ctx.op.name});
            };
            var r = struple.reader(try innerOf(ctx, value));
            var i: usize = 0;
            while (r.nextView() catch return ctx.refuse("{s}: {s} is a malformed array", .{ ctx.op.name, shapeWhere(ctx, path) })) |e| : (i += 1) {
                try shapeCheck(ctx, exact, elem_shape, e, pathIndex(ctx, path, i));
            }
        },
        Tag.record => {
            if (types.typeOfValue(value) != Tag.record) return shapeMismatch(ctx, path, value, shape);
            const vm = struple.MapView.init(try innerOf(ctx, value));
            var it = struple.MapView.init(try innerOf(ctx, shape)).iterator();
            while (it.next() catch return ctx.refuse("{s}: the shape is malformed", .{ctx.op.name})) |e| {
                const written = types.asString(e.key) orelse return ctx.refuse("{s}: the shape is malformed", .{ctx.op.name});
                const optional = written.len > 0 and written[written.len - 1] == '?';
                const name = if (optional) written[0 .. written.len - 1] else written;
                var kp = struple.Packer.init(ctx.arena);
                try kp.appendString(name);
                const at = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, name }) catch path;
                const got = (vm.get(kp.bytes()) catch return ctx.refuse("{s}: {s} is a malformed record", .{ ctx.op.name, shapeWhere(ctx, path) })) orelse {
                    if (optional) continue;
                    return ctx.refuse("{s}: '{s}' is missing — the shape requires it", .{ ctx.op.name, at });
                };
                try shapeCheck(ctx, exact, e.value, got, at);
            }
            if (!exact) return;
            // `exact` closes every record in the shape, not only the
            // outermost: the word closes THE SHAPE, and a closed outside with
            // open insides is a promise nobody asked for.
            var vit = vm.iterator();
            while (vit.next() catch return ctx.refuse("{s}: {s} is a malformed record", .{ ctx.op.name, shapeWhere(ctx, path) })) |e| {
                const key = types.asString(e.key) orelse continue;
                var sit = struple.MapView.init(try innerOf(ctx, shape)).iterator();
                const known = while (sit.next() catch null) |se| {
                    const w = types.asString(se.key) orelse continue;
                    const n = if (w.len > 0 and w[w.len - 1] == '?') w[0 .. w.len - 1] else w;
                    if (std.mem.eql(u8, n, key)) break true;
                } else false;
                if (!known) {
                    return ctx.refuse("{s}: '{s}.{s}' is not in the shape, and the shape is exact", .{ ctx.op.name, path, key });
                }
            }
        },
        else => return ctx.refuse("{s}: the shape is malformed", .{ctx.op.name}),
    }
}

/// `match <shape> [exact]` — every value, at runtime. A mismatch kills the
/// wave and counts against the budget, like any refusal.
fn evalMatch(ctx: *EvalCtx) EvalError!Emit {
    const v = try raw(ctx, 0);
    const sp = try shapeStatic(ctx);
    try shapeCheck(ctx, sp.exact, sp.body, v, "");
    try splice(ctx, 0, v);
    return Emit.first;
}

/// `expect <shape> [exact]` — once, at mount, and never again. The port is
/// OPTIONAL so the node still evaluates when there is nothing on the wire:
/// "the path has no value at mount" is the case `expect` most needs to catch,
/// and a required port would skip the node and let the mount succeed silently.
fn evalExpect(ctx: *EvalCtx) EvalError!Emit {
    const checked = ctx.state.items.len > 0 and ctx.state.items[0] == 1;
    if (!checked) {
        try ctx.setState(&.{1});
        // States the fact and stops. Which operator to reach for instead is a
        // judgement about the path — one whose shape can change wants `match`
        // — and that belongs in the manual, not in an error message (ruled
        // 2026-08-25, retiring the "refuse and say use match" clause).
        const v = ctx.in[0] orelse return ctx.refuse(
            "expect: there is nothing here at mount, so there is no shape to assert",
            .{},
        );
        const sp = try shapeStatic(ctx);
        try shapeCheck(ctx, sp.exact, sp.body, v, "");
    }
    const v = ctx.in[0] orelse return Emit.none;
    try splice(ctx, 0, v);
    return Emit.first;
}

fn evalProject(ctx: *EvalCtx) EvalError!Emit {
    const inner = try innerOf(ctx, try raw(ctx, 0));
    var kp = struple.Packer.init(ctx.arena);
    try kp.appendString(ctx.statics[0].word);
    const m = struple.MapView.init(inner);
    const val = (m.get(kp.bytes()) catch return ctx.refuse("project: the input is a malformed record", .{})) orelse return Emit.none;
    try splice(ctx, 0, val);
    return Emit.first;
}

fn evalMerge(ctx: *EvalCtx) EvalError!Emit {
    var entries = std.ArrayListUnmanaged([2][]const u8).empty;
    inline for (0..2) |i| {
        const inner = try innerOf(ctx, try raw(ctx, i));
        var it = struple.MapView.init(inner).iterator();
        while (it.next() catch return ctx.refuse("merge: port '{s}' is a malformed record", .{ctx.portName(i)})) |e| {
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
///     signals/horn | write gate/drawbridge.target 1
///     visible_enemies | rose_above 0 | notify signals/horn { kind: "approach" }
///
/// Without it that sentence takes three nodes to say one word — hold the
/// constant in a `latch`, sample it on the rousing, pipe it to the sink —
/// which is what Ironwood's gate.rill did until this port existed.
///
/// Unpiped, the value binds port 0 and is both rousing and payload, so
/// `set p 3` is unchanged. Unbound, the in-flowing value is written, so
/// `x | write p` is unchanged. A change in `value` alone is not a write: the
/// payload says what, the rousing says when — the same rule `inc` applies to
/// `by`, for the same reason.
fn evalSink(ctx: *EvalCtx) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none;
    // Statics 1..5 are the mode flags — a CLOSED set of bare words, at most
    // one written. The mode is the writer's stated intent (write-verbs,
    // ruled 2026-08-29): bare `write` is the durable replace `set` always
    // was; the lane modes retract with their writer; `clear` withdraws.
    var mode: plane.WriteMode = .base;
    var n_modes: u32 = 0;
    // `notify` shares this eval with only the path static — its statics stop
    // at 1 and its mode is always .base. Found by an index panic, kept as a
    // guard rather than a second eval: one sink, two rows.
    if (ctx.statics.len > 1) {
        const MODES = [_]plane.WriteMode{ .hold, .add, .mul, .stops, .clear };
        for (MODES, 1..) |m, i| {
            if (ctx.statics[i].word.len != 0) {
                mode = m;
                n_modes += 1;
            }
        }
    }
    if (n_modes > 1) return ctx.refuse("write: one mode only — hold, add, mul, stops or clear", .{});
    if (mode == .clear) {
        // Withdrawal has no payload: a value here is a category error, and
        // binding one silently would let "clear 0.5" read as writing a half.
        if (ctx.in[1] != null) return ctx.refuse("write … clear takes no value — it withdraws this writer's contributions, it does not write", .{});
        try ctx.write(ctx.statics[0].path, &.{}, .clear);
        return Emit.none;
    }
    try ctx.write(ctx.statics[0].path, ctx.in[1] orelse try raw(ctx, 0), mode);
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
    const amplitude = types.asNumber(amp_bytes) orelse
        return ctx.refuse("cast: the amplitude is {s}, not a number", .{describeTop(ctx, amp_bytes)});
    const pos = try raw(ctx, 2); // `at` — required; a cast lands somewhere
    const decay: ?types.Duration = if (ctx.in[3]) |b|
        (types.asDuration(b) orelse return ctx.refuse("cast: 'decay' is {s}, not a duration — durations carry a unit (4s, 250ms)", .{describeTop(ctx, b)}))
    else
        null;
    const radius = types.asNumber(ctx.statics[1].literal) orelse
        return ctx.refuse("cast: 'radius' is not a number", .{});
    if (!(radius > 0)) return ctx.refuse("cast: 'radius' is {d}, and a deposit with no extent reaches nothing", .{radius});
    try ctx.cast(.{
        .channel = ctx.statics[0].channel,
        .amplitude = amplitude,
        .pos = pos,
        .radius = radius,
        .decay = decay,
        // Coupling (T4): empty = uncoupled. A `to #tag` scopes ENTITY
        // perception host-side; posts hear everything regardless.
        .to = ctx.statics[2].condition,
    });
    return Emit.none;
}

/// `tag <@subject> <#tag>` / `untag <@subject> <#tag>` — the membership
/// sinks (ironwood R6 T3). One subject, ONE tag per call (a second tag is a
/// second statement); the write is a set operation, so the host applies it
/// idempotently — twice is once — and speaks `joined`/`left` only on actual
/// transitions. Port 0 is the rousing, per the sink rule. Unpiped there is
/// no rousing to wait for, so the parser binds a literal one and the
/// statement fires ONCE, at tick 0 — the console one-shot
/// (`tag @wall #garrison`) is the customer, mirroring cast's unpiped
/// deposit-once story. The subject's name was bound to an entity id at
/// MOUNT (ironwood T2 pin ③); the host refuses a write whose binding has
/// gone stale, here at the node, ending the program's authority over a
/// rebound name loudly.
fn evalTag(ctx: *EvalCtx) EvalError!Emit {
    return evalMembership(ctx, true);
}

fn evalUntag(ctx: *EvalCtx) EvalError!Emit {
    return evalMembership(ctx, false);
}

fn evalMembership(ctx: *EvalCtx, adding: bool) EvalError!Emit {
    if (!ctx.in_fresh[0]) return Emit.none;
    try ctx.tagWrite(.{
        .subject = ctx.statics[0].subject,
        .tag = ctx.statics[1].condition,
        .adding = adding,
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
    /// An optional, keyword-introduced OCCURRENCE port — `arm`'s controls.
    fn kwOptOcc(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .kind = .occurrence, .optional = true, .kw = true };
    }
    /// A **broadcasting** number/boolean port: it accepts a record or an array
    /// as well, because the operator it belongs to is elementwise (beat 1b).
    ///
    /// This is opt-in per port, and that is the point (found at tier-2 close
    /// by a no-priors reviewer). Beat 1b widened `accepts` GLOBALLY so that
    /// `mul {x: 1}` would wire, which quietly removed wire-time typing from
    /// every number port in the language — `choose`'s index, `take`'s count,
    /// `above`'s thresholds, `within`'s radius all began accepting an array
    /// and refusing at runtime instead. A manual example shipped with exactly
    /// that mistake and the manual gate could not see it, because it parsed.
    fn bc(n: []const u8, ty: types.TypeId) registry.Port {
        return .{ .name = n, .ty = ty, .broadcasts = true };
    }
    /// A closed-value-set string port: a bare word coerces and its membership
    /// is checked at PARSE, so `lfo sqare 4s` is a wire-time error naming the
    /// list, not a BadValue three seconds into the animation.
    fn oneOf(n: []const u8, vals: []const []const u8) registry.Port {
        return .{ .name = n, .ty = types.Tag.string, .one_of = vals };
    }
};

const CORE = [_]registry.OpDef{
    // flow
    .{ .name = "select", .row = rowk.exact(rowk.kernels.select), .inputs = &.{ p.in("cond", Tag.boolean), p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "cond ? a : b — all branches exist; one is chosen per tick.", .eval = evalSelect },
    .{ .name = "lerp", .row = rowk.exact(rowk.kernels.lerp), .inputs = &.{ p.in("t", Tag.number), p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "a + (b - a) * t, t PIPED — `s | lerp 0.5 1.5` is s, lerped between 0.5 and 1.5.", .eval = evalLerp },
    .{ .name = "and", .row = rowk.exact(rowk.kernels.andK), .inputs = &.{ p.bc("a", Tag.boolean), p.bc("b", Tag.boolean) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Boolean and — the conjunction idiom's other half: `dark | and calm | …`.", .eval = boolOp(fAnd) },
    .{ .name = "or", .row = rowk.exact(rowk.kernels.orK), .inputs = &.{ p.bc("a", Tag.boolean), p.bc("b", Tag.boolean) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Boolean or.", .eval = boolOp(fOr) },
    .{ .name = "not", .row = rowk.exact(rowk.kernels.not), .inputs = &.{p.bc("a", Tag.boolean)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Boolean not.", .eval = unBool() },
    .{ .name = "where", .inputs = &.{ p.in("in", Tag.any), p.in("pred", Tag.boolean) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Pass arrivals of `in` while pred is true; otherwise silence.", .class = .reads, .eval = evalWhere },
    .{ .name = "partition", .inputs = &.{ p.in("in", Tag.any), p.in("pred", Tag.boolean) }, .outputs = &.{ p.val("pass", Tag.any), p.val("fail", Tag.any) }, .routes = .anywhere, .help = "Route every arrival of `in` to exactly one side by pred.", .class = .reads, .eval = evalPartition },
    .{ .name = "changed", .inputs = &.{p.in("in", Tag.any)}, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Emit an occurrence whenever the value actually changes.", .class = .reads, .eval = evalChanged },
    .{ .name = "latch", .inputs = &.{ p.in("in", Tag.any), p.occ("trigger", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Sample-and-hold: emit the current `in` when `trigger` fires.", .class = .reads, .eval = evalLatch },
    // events
    .{ .name = "dropped_below", .inputs = &.{ p.in("in", Tag.number), p.in("threshold", Tag.number) }, .outputs = &.{p.occ("out", Tag.number)}, .routes = .anywhere, .help = "Fire (with the value) when `in` crosses below threshold. First observation baselines silently.", .class = .reads, .eval = evalDroppedBelow },
    .{ .name = "rose_above", .inputs = &.{ p.in("in", Tag.number), p.in("threshold", Tag.number) }, .outputs = &.{p.occ("out", Tag.number)}, .routes = .anywhere, .help = "Fire (with the value) when `in` crosses above threshold. First observation baselines silently.", .class = .reads, .eval = evalRoseAbove },
    .{ .name = "edge", .inputs = &.{p.in("in", Tag.boolean)}, .outputs = &.{p.occ("out", Tag.boolean)}, .routes = .anywhere, .help = "Fire on the false→true transition.", .class = .reads, .eval = evalEdge },
    // temporal — durations are 5s / 250ms / 2m / 3f literals; time is fed, never read
    .{ .name = "sample", .inputs = &.{ p.in("in", Tag.any), p.in("period", Tag.duration) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "At most one emission per period, latest value wins — leading edge immediate, trailing edge via the wheel.", .class = .reads, .eval = evalSample },
    .{ .name = "debounce", .inputs = &.{ p.occ("in", Tag.any), p.in("quiet", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Pass only after a quiet period; storms collapse to their last edge.", .class = .reads, .eval = evalDebounce },
    .{ .name = "throttle", .inputs = &.{ p.occ("in", Tag.any), p.in("window", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "First occurrence passes, the rest are eaten for the window.", .class = .reads, .eval = evalRateGate },
    .{ .name = "cooldown", .inputs = &.{ p.occ("in", Tag.any), p.in("window", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Pass one, then deaf for the window — triggered, now get out of the way.", .class = .reads, .eval = evalRateGate },
    .{ .name = "window", .inputs = &.{ p.in("in", Tag.any), p.in("span", Tag.duration) }, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .help = "Rolling buffer over fed time, emitted as an array; entries age out on schedule even when the input is quiet.", .class = .reads, .eval = evalWindow },
    .{ .name = "stats", .inputs = &.{p.in("in", Tag.array)}, .outputs = &.{p.val("out", Tag.record)}, .routes = .anywhere, .help = "{max, mean, min, n, stddev} over a numeric array; empty in ⇒ zeros with n = 0.", .eval = evalStats },
    .{ .name = "delay", .inputs = &.{ p.occ("in", Tag.any), p.in("by", Tag.duration) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Emit each occurrence `by` later; same-tick maturities collapse to the newest.", .class = .reads, .eval = evalDelay },
    .{ .name = "every", .inputs = &.{p.in("period", Tag.duration)}, .outputs = &.{p.occ("out", Tag.boolean)}, .routes = .anywhere, .help = "Occurrence source on a cadence: fires at mount, then once per period of fed time. `every 1f { cast … }` is the standing-caster idiom.", .class = .reads, .eval = evalEvery },
    // `in` is optional on the gates: controls must latch even before the
    // stream first flows — a required port would silently discard an `off`
    // that fired ahead of the first occurrence (the all-inputs guard skips
    // nodes with a missing required input).
    .{ .name = "arm", .inputs = &.{ p.optOcc("in", Tag.any), p.kwOptOcc("off", Tag.any), p.kwOptOcc("on", Tag.any) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Latch gate, initially open: pass occurrences while armed; `off` closes, `on` re-opens (on wins a tie).", .class = .reads, .eval = gateEval(true) },
    .{ .name = "disarm", .inputs = &.{ p.optOcc("in", Tag.any), p.kwOptOcc("off", Tag.any), p.kwOptOcc("on", Tag.any) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Latch gate, initially closed: silent until `on` arms it; `off` closes again (on wins a tie).", .class = .reads, .eval = gateEval(false) },
    // tier 2, beat 1a — time as a value, waveforms, registers, shaping.
    // `ticks` is declared on every one that may re-arm itself; the badge is
    // derived from it and the live eval counter is shown beside it as proof.
    .{ .name = "clock", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Fed real time in seconds since mount, as a value. Re-evaluates every tick — anything downstream does too.", .class = .reads, .ticks = true, .eval = timeSource(false) },
    .{ .name = "frame", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Fed frame count since mount, as a value. Re-evaluates every frame — anything downstream does too.", .class = .reads, .ticks = true, .eval = timeSource(true) },
    .{ .name = "wave", .inputs = &.{ p.in("t", Tag.number), p.oneOf("shape", &WAVE_SHAPES), p.in("period", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Shape piped time into 0..1 — `clock | wave sine 4s`; shapes: sine, tri, saw, square. Pure: same t, same answer.", .eval = evalWave },
    .{ .name = "lfo", .inputs = &.{ p.oneOf("shape", &WAVE_SHAPES), p.in("period", Tag.duration), p.kwOpt("phase", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Modulation source in 0..1 — `lfo sine 4s [phase 0.25]`. The same waveform as `clock | wave`, in one node.", .class = .reads, .ticks = true, .eval = evalLfo },
    .{ .name = "ease", .inputs = &.{ p.in("in", Tag.number), p.in("tau", Tag.duration), p.kwOpt("up", Tag.duration), p.kwOpt("down", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Chase the input with time constant `tau`; `up`/`down` make it asymmetric. Stops inside epsilon of the target — it never snaps.", .class = .reads, .ticks = true, .eval = evalEase },
    .{ .name = "ramp", .inputs = &.{ p.in("in", Tag.number), p.in("over", Tag.duration), p.kwOpt("from", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Tween linearly to each new target over `over`; retargeting starts from where it is. `from` gives the FIRST tween a start, which is the mount fade — `once 1 | ramp 2s from 0`. The last frame emits the target exactly.", .class = .reads, .ticks = true, .eval = evalRamp },
    .{ .name = "hold", .inputs = &.{ p.in("in", Tag.number), p.in("for", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Sample-and-hold: take a value, then ignore changes for `for`. Does not tick — ignored values are gone.", .class = .reads, .eval = evalHold },
    .{ .name = "diff", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Rate of change per second from the previous sample. First observation baselines silently; ticks while moving, stops at zero.", .class = .reads, .ticks = true, .eval = evalDiff },
    .{ .name = "integrate", .inputs = &.{ p.in("in", Tag.number), p.kwIn("max", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Running sum over fed time, clamped to +/-max. The clamp is required — unbounded state is a corpse that rides every dump.", .class = .reads, .ticks = true, .eval = evalIntegrate },
    .{ .name = "range", .row = rowk.exact(rowk.kernels.range), .inputs = &.{ p.in("t", Tag.number), p.in("lo", Tag.number), p.in("hi", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Map 0..1 onto lo..hi, CLAMPING outside it — the exit from the unit interval. `lerp` is the same arithmetic that extrapolates.", .eval = evalRange },
    .{ .name = "over", .row = rowk.exact(rowk.kernels.over), .inputs = &.{ p.in("t", Tag.number), p.in("span", Tag.number), p.in("curve", Tag.array) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Sample a curve of EVENLY-SPACED knots at t/span, clamped to the ends — `row.age | over row.life [1, 0.7, 0]` is full size at birth, 0.7 halfway, nothing at death. `range` is the two-knot case. Knots may be numbers or records (a record ramp is a colour ramp); one knot is a constant. A zero span refuses.", .eval = evalOver },
    .{ .name = "shape", .inputs = &.{ p.in("t", Tag.number), p.oneOf("curve", &SHAPE_CURVES) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Ease a 0..1 value into 0..1 — curves: linear, smooth, in, out, inout. Input clamps.", .eval = evalShape },
    // math — and a note on why every one of these declares `out` as `any`.
    //
    // Broadcast makes an elementwise operator's OUTPUT KIND follow its input:
    // `mul 2` on a number gives a number, on an array gives an array, on a
    // record gives a record. A static `TypeId` cannot say "same as whatever
    // arrives", so declaring `number` would be a statement that is false
    // exactly when broadcast is doing its job — and the manual gate caught it
    // saying so (`window 10s | mul 2 | stats` refused at wire time because
    // `mul` claimed to emit a number).
    //
    // `any` is the honest word here: not statically known. The eval-time
    // mismatch check is the authority on kinds either way, and beat 2's
    // `expect`/`match` are how an author pins a shape at a boundary.
    // math
    .{ .name = "add", .row = rowk.exact(rowk.kernels.add), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a + b.", .eval = binMath(fAdd) },
    .{ .name = "sub", .row = rowk.exact(rowk.kernels.sub), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a - b.", .eval = binMath(fSub) },
    .{ .name = "mul", .row = rowk.exact(rowk.kernels.mulK), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a * b.", .eval = binMath(fMul) },
    .{ .name = "div", .row = rowk.exact(rowk.kernels.div), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a / b (IEEE; division by zero yields ±inf).", .eval = binMath(fDiv) },
    .{ .name = "min", .row = rowk.exact(rowk.kernels.min), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The smaller of a and b.", .eval = binMath(fMin) },
    .{ .name = "max", .row = rowk.exact(rowk.kernels.max), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The larger of a and b.", .eval = binMath(fMax) },
    .{ .name = "clamp", .row = rowk.exact(rowk.kernels.clamp), .inputs = &.{ p.in("in", Tag.number), p.in("lo", Tag.number), p.in("hi", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Clamp `in` to [lo, hi].", .eval = evalClamp },
    .{ .name = "abs", .row = rowk.exact(rowk.kernels.abs), .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Absolute value.", .eval = unMath(fAbs) },
    .{ .name = "floor", .row = rowk.exact(rowk.kernels.floor), .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Round toward −inf.", .eval = unMath(fFloor) },
    .{ .name = "round", .row = rowk.exact(rowk.kernels.round), .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Round to nearest.", .eval = unMath(fRound) },
    // math completions (beat 1b) — every one broadcasts, being minted by the
    // same helpers as `add`.
    .{ .name = "sin", .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Sine, radians.", .eval = unMath(fSin) },
    .{ .name = "cos", .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Cosine, radians.", .eval = unMath(fCos) },
    .{ .name = "tan", .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Tangent, radians.", .eval = unMath(fTan) },
    .{ .name = "sqrt", .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Square root (IEEE; a negative yields nan).", .eval = unMath(fSqrt) },
    .{ .name = "exp", .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "e to the input.", .eval = unMath(fExp) },
    .{ .name = "log", .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Natural log (IEEE; zero yields -inf, a negative yields nan).", .eval = unMath(fLog) },
    .{ .name = "ceil", .row = rowk.exact(rowk.kernels.ceil), .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Round toward +inf — `floor`'s missing mirror.", .eval = unMath(fCeil) },
    .{ .name = "sign", .row = rowk.exact(rowk.kernels.sign), .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "-1, 0 or 1 (nan stays nan).", .eval = unMath(fSign) },
    .{ .name = "fract", .row = rowk.exact(rowk.kernels.fract), .inputs = &.{p.bc("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Fractional part, always in [0, 1) — `fract -0.25` is 0.75.", .eval = unMath(fFract) },
    .{ .name = "pow", .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a to the power b — `x | pow 2` is x squared.", .eval = binMath(fPow) },
    .{ .name = "mod", .row = rowk.exact(rowk.kernels.mod), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Floored modulo: the sign follows the divisor, so `-90 | mod 360` is 270.", .eval = binMath(fMod) },
    .{ .name = "atan2", .inputs = &.{ p.in("y", Tag.number), p.in("x", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Angle of (x, y) in radians, y PIPED — `dy | atan2 dx`.", .eval = binMath(fAtan2) },
    .{ .name = "pi", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "3.14159… — emitted once at mount.", .eval = constant(std.math.pi) },
    .{ .name = "tau", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "2*pi — a whole turn, emitted once at mount.", .eval = constant(std.math.tau) },
    // comparators
    .{ .name = "=", .row = rowk.exact(rowk.kernels.eq), .inputs = &.{ p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .help = "Equality (numeric across int/float; byte-wise otherwise).", .eval = evalEq },
    .{ .name = "!=", .row = rowk.exact(rowk.kernels.ne), .inputs = &.{ p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .help = "Inequality.", .eval = evalNe },
    .{ .name = "<", .row = rowk.exact(rowk.kernels.lt), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a < b.", .eval = cmpOp(fLt) },
    .{ .name = "<=", .row = rowk.exact(rowk.kernels.le), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a <= b.", .eval = cmpOp(fLe) },
    .{ .name = ">", .row = rowk.exact(rowk.kernels.gt), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a > b.", .eval = cmpOp(fGt) },
    .{ .name = ">=", .row = rowk.exact(rowk.kernels.ge), .inputs = &.{ p.bc("a", Tag.number), p.bc("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a >= b.", .eval = cmpOp(fGe) },
    // tier 2, beat 2 — arrays. The literal is the missing half of a value kind
    // that already existed: `window` emits an array and `stats` consumes one.
    .{ .name = "array", .variadic = true, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .help = "Array construction [ a, b, c ] — a live tuple with positions instead of names.", .eval = evalArray },
    .{ .name = "nth", .inputs = &.{ p.in("in", Tag.array), p.in("i", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The i-th element, 0-based — `window 5s | nth 0`. Out of range is an error, never a clamp.", .eval = indexEval(0, 1) },
    .{ .name = "choose", .inputs = &.{ p.in("i", Tag.number), p.in("of", Tag.array) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "`nth` with the index piped — `plane.time.band | choose [0.2, 1, 0.6, 0.05]`. Pick one of these.", .eval = indexEval(1, 0) },
    // tier 2, beat 4b — noise, randomness, space.
    .{ .name = "noise", .inputs = &.{ p.in("period", Tag.duration), p.kwOpt("octaves", Tag.number), p.kwOpt("seed", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .class = .reads, .ticks = true, .help = "Smooth noise in 0..1 over fed time — `noise 80ms` flickers, `noise 20s` drifts. Stateless, seeded (default 0), bit-identical across machines.", .eval = evalNoise },
    .{ .name = "rand", .inputs = &.{ p.occ("in", Tag.any), p.kwOpt("seed", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .class = .reads, .help = "White: a fresh value in 0..1 per rousing — `plane.trigger | rand | mul 4 | floor`. Same generator as `shuffle`; seed defaults to 0.", .eval = evalRand },
    .{ .name = "distance", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Distance between two positions — both record{x, y, z}; a missing axis is named.", .eval = evalDistance },
    .{ .name = "dot", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Scalar product of two positions or directions — both record{x, y, z}. How much of a lies along b.", .eval = evalDot },
    .{ .name = "within", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record), p.in("r", Tag.number) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .help = "Is a within r of b? Both record{x, y, z}.", .eval = evalWithin },
    .{ .name = "angle", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Angle between two directions, radians 0..π — both record{x, y, z}. A zero-length vector refuses: no direction, no angle.", .eval = evalAngle },
    .{ .name = "inside", .inputs = &.{ p.in("p", Tag.record), p.in("min", Tag.record), p.in("max", Tag.record) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .help = "Is p inside the axis-aligned box from min to max? Bounds inclusive — the wall counts, like `within`'s sphere. An inverted box is empty and answers false.", .eval = evalInside },
    .{ .name = "cross", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record) }, .outputs = &.{p.val("out", Tag.record)}, .routes = .anywhere, .help = "Vector product of two directions — record{x, y, z} out, right-handed: x cross y is z.", .eval = evalCross },
    // tier 2, beat 4a — events and levels.
    .{ .name = "pulse", .inputs = &.{ p.in("period", Tag.duration), p.kwOpt("width", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .class = .reads, .ticks = true, .help = "Value source: 1 for `width`, else 0, once per period — `pulse 1s [width 100ms]`. Width defaults to a tenth of the period. `every` is the occurrence source.", .eval = evalPulse },
    .{ .name = "once", .inputs = &.{p.occ("in", Tag.any)}, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .class = .reads, .help = "Pass the first value, then deaf until remount — `once 1 | ramp 2s` fires at mount; piped, it passes the first arrival.", .eval = evalOnce },
    .{ .name = "toggle", .inputs = &.{p.occ("in", Tag.any)}, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .class = .reads, .help = "Flip a boolean on each arrival. Emits its initial false at mount and flips from the next arrival on.", .eval = evalToggle },
    .{ .name = "tally", .inputs = &.{p.occ("in", Tag.any)}, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .class = .reads, .help = "Running count of arrivals, as a value. Emits 0 at mount; does not survive remount (remount is restart).", .eval = evalTally },
    // envelopes campaign, 2026-08-26 — the register family's missing half
    .{ .name = "kick", .inputs = &.{ p.occ("in", Tag.any), p.in("attack", Tag.duration), p.in("decay", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .class = .reads, .ticks = true, .help = "One-shot envelope from an occurrence — `plane.events.hit | kick 20ms 400ms`. Rises to 1 over `attack`, falls to 0 over `decay`, stops. A retrigger restarts from the CURRENT level, never from zero.", .eval = evalKick },
    .{ .name = "adsr", .inputs = &.{ p.in("in", Tag.boolean), p.in("attack", Tag.duration), p.in("decay", Tag.duration), p.in("sustain", Tag.number), p.in("release", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .class = .reads, .ticks = true, .help = "Gate in, envelope out — `plane.input.key | adsr 10ms 80ms 0.7 400ms`. Rise, decay to `sustain` while the gate holds, release when it drops. A held sustain costs nothing.", .eval = evalAdsr },
    .{ .name = "above", .inputs = &.{ p.in("in", Tag.number), p.in("on", Tag.number), p.in("off", Tag.number) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .class = .reads, .help = "Boolean with hysteresis — `above 0.3 0.2` is \"above 0.3, until below 0.2\". Emits its level at mount; this is what stops a threshold chattering.", .eval = hysteresis(false) },
    .{ .name = "below", .inputs = &.{ p.in("in", Tag.number), p.in("on", Tag.number), p.in("off", Tag.number) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .class = .reads, .help = "Boolean with hysteresis, falling — `below 0.2 0.3` is \"below 0.2, until above 0.3\". The first number trips and the second releases, same as `above`. Emits its level at mount.", .eval = hysteresis(true) },
    // tier 2, beat 3a — over arrays, driving a section body per element.
    // `.reads` rather than `.pure`: a body may hold BOUND ports of its own
    // (`keep (> plane.threshold)`), so the answer is not a function of this
    // node's own ports alone — which is exactly what `pure` licences.
    .{ .name = "map", .inputs = &.{p.in("in", Tag.array)}, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .class = .reads, .body = 1, .help = "The body once per element, in order — `map (clamp 0 1)`. Keeps the length; use `keep` to drop.", .eval = evalMap },
    .{ .name = "keep", .inputs = &.{p.in("in", Tag.array)}, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .class = .reads, .body = 1, .help = "The elements a predicate says true for — `keep (> 0)`. Filters ELEMENTS; `where` gates the stream.", .eval = evalKeep },
    .{ .name = "reduce", .inputs = &.{ p.in("in", Tag.array), p.kwOpt("init", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .class = .reads, .body = 2, .help = "Left fold — `reduce (add) [init 0]`. Accumulator fills the body's first open port, element the second; no init means the first element seeds.", .eval = evalReduce },
    // tier 2, beat 3b — order. `sort`'s body rides the `by` keyword, which is
    // what makes it optional without breaking "optionals are keyword-only".
    .{ .name = "sort", .inputs = &.{p.in("in", Tag.array)}, .statics = &.{.{ .name = "desc", .kind = .word, .flag = true, .optional = true }}, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .class = .reads, .body = 1, .body_kw = "by", .help = "Stable sort — `sort by (.distance) [desc]`. Without `by`, the elements are their own keys. Ties keep their input order.", .eval = evalSort },
    .{ .name = "first", .inputs = &.{p.in("in", Tag.array)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The leading element — `sort by (.distance) | first`. An empty array ends the wave silently; say absence with `len`.", .eval = endEval(false) },
    .{ .name = "last", .inputs = &.{p.in("in", Tag.array)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The trailing element — `window 5s | last` is the most recent reading. An empty array ends the wave silently.", .eval = endEval(true) },
    .{ .name = "len", .inputs = &.{p.in("in", Tag.array)}, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "How many elements — `contacts | len | write plane.ui.contacts`. This is how absence is said once `first` goes quiet.", .eval = evalLen },
    .{ .name = "take", .inputs = &.{ p.in("in", Tag.array), p.in("n", Tag.number), p.kwOpt("from", Tag.number) }, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .help = "At most `n` elements, from `from` — `take 3`. A short array is forgiven; `nth` past the end is not.", .eval = evalTake },
    .{ .name = "transpose", .inputs = &.{p.in("in", Tag.any)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "AoS ↔ SoA, self-inverse — `{a: [1,2], b: [3,4]}` ↔ `[{a:1,b:3},{a:2,b:4}]`. Ragged input refuses, both sides named.", .eval = evalTranspose },
    .{ .name = "shuffle", .inputs = &.{ p.in("in", Tag.array), p.kwOpt("seed", Tag.number) }, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .help = "Seeded Fisher–Yates — `shuffle [seed 7] | take 3` is three at random, no repeats. Seed defaults to 0; bit-identical across machines.", .eval = evalShuffle },
    .{ .name = "step", .inputs = &.{ p.occ("in", Tag.any), p.in("of", Tag.array), p.kwOpt("seed", Tag.number), p.kwOpt("max", Tag.number) }, .statics = &.{ .{ .name = "loop", .kind = .word, .flag = true, .optional = true }, .{ .name = "bounce", .kind = .word, .flag = true, .optional = true }, .{ .name = "reverse", .kind = .word, .flag = true, .optional = true }, .{ .name = "random", .kind = .word, .flag = true, .optional = true }, .{ .name = "shuffle", .kind = .word, .flag = true, .optional = true } }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .class = .reads, .help = "Step sequencer — `plane.beat | step [60, 64, 67] loop`. Each rousing emits the NEXT element; by default it runs once and the wave ends. Order: sequential (`reverse` walks down) or `random`/`shuffle`; end: `loop`, `bounce`, or stop. `max n` caps emissions.", .eval = evalStep },
    .{ .name = "nearest", .inputs = &.{ p.in("p", Tag.record), p.in("knots", Tag.array) }, .statics = &.{.{ .name = "loop", .kind = .word, .flag = true, .optional = true }}, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Where p is on the curve through the knots, as t in 0..1 — the inverse of `along`. `loop` searches the closed curve, seam included, and answers in 0..1 with the seam at 0. Fewer than two knots refuses; a loop needs three.", .eval = evalNearest },
    .{ .name = "along", .inputs = &.{ p.in("t", Tag.number), p.in("knots", Tag.array) }, .statics = &.{.{ .name = "loop", .kind = .word, .flag = true, .optional = true }}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Travel a Catmull-Rom curve through the knots as t goes 0..1 — `along [a, b, c]`. Clamps outside 0..1. `loop` closes the curve back to the first knot and wraps t instead — a loop has no ends, and do not repeat the first knot as the last. Fewer than two knots refuses; a loop needs three.", .eval = evalAlong },
    // tier 2, beat 2b — contracts. One shape literal, two promises.
    .{ .name = "expect", .inputs = &.{p.opt("in", Tag.any)}, .statics = &.{.{ .name = "shape", .kind = .shape }}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .class = .reads, .fails_mount = true, .help = "Assert a shape ONCE, at mount — `expect {id: string, distance: number} [exact]`. A mismatch refuses the mount. Costs nothing afterwards; never falls back to a runtime check.", .eval = evalExpect },
    .{ .name = "match", .inputs = &.{p.in("in", Tag.any)}, .statics = &.{.{ .name = "shape", .kind = .shape }}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Assert a shape on EVERY value — `match {id: string} [exact]`. A mismatch kills the wave and names the field and both sides.", .eval = evalMatch },
    // records
    .{ .name = "record", .row = rowk.exact(rowk.kernels.record), .variadic = true, .outputs = &.{p.val("out", Tag.record)}, .routes = .anywhere, .help = "Record construction { field: stream, … } — a live tuple with named fields.", .eval = evalRecord },
    .{ .name = "project", .row = rowk.exact(rowk.kernels.project), .inputs = &.{p.in("in", Tag.record)}, .statics = &.{.{ .name = "field", .kind = .word }}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Field access on a record stream (`stats.mana`).", .eval = evalProject },
    .{ .name = "merge", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record) }, .outputs = &.{p.val("out", Tag.record)}, .routes = .anywhere, .help = "Merge two records; b's fields win.", .eval = evalMerge },
    // plane / util
    .{
        .name = "write",
        .row = rowk.exact(rowk.kernels.write),
        .inputs = &.{ p.in("in", Tag.any), p.opt("value", Tag.any) },
        .statics = &.{
            .{ .name = "path", .kind = .path },
            // The mode flags — a closed set of bare words, one at most. In
            // ARGUMENT position they cannot collide with the operators of the
            // same names, which is why the modes get the registry's own
            // vocabulary instead of a bikeshed (write-verbs rev 3).
            .{ .name = "hold", .kind = .word, .flag = true, .optional = true },
            .{ .name = "add", .kind = .word, .flag = true, .optional = true },
            .{ .name = "mul", .kind = .word, .flag = true, .optional = true },
            .{ .name = "stops", .kind = .word, .flag = true, .optional = true },
            .{ .name = "clear", .kind = .word, .flag = true, .optional = true },
        },
        .routes = .anywhere,
        .help = "Write to a plane path — `write <path> [value] [mode]`. Bare is the durable replace (the old `set`); `hold` is the seat (retracts on unmount), `add`/`mul`/`stops` are lane levels (likewise), `clear` withdraws this writer's contributions and takes no value. Piped, the input is the rousing and `value` is what gets written.",
        .class = .effect,
        .eval = evalSink,
    },
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
    .{ .name = "notify", .inputs = &.{ p.in("in", Tag.any), p.opt("value", Tag.any) }, .statics = &.{.{ .name = "path", .kind = .path }}, .routes = .anywhere, .help = "Write an occurrence to a plane path — `notify <path> [value]`; same write as `set`, states the intent.", .class = .effect, .eval = evalSink },
    // The third write kind. `plane.x | add 1 | write plane.x` reads a path it
    // writes, so the cycle check rightly refuses it — which leaves counters
    // inexpressible. A blind delta reads nothing and passes legitimately.
    .{ .name = "inc", .inputs = &.{ p.occ("in", Tag.any), p.in("by", Tag.number) }, .statics = &.{.{ .name = "path", .kind = .path }}, .routes = .anywhere, .help = "Add `by` to a plane path each time the input rouses — a blind delta: no read, commutative, order-independent.", .class = .effect, .eval = evalInc },
    // The field sink. `channel` is a `.channel` static, not a `.path`, so a
    // cast never enters the write list — correctly: fields have no read side
    // inside rill (readings come from a standpoint, §9), so there is no loop
    // for the cycle check to miss. `at`/`decay` are keyword ports: the word
    // disambiguates what a positional grammar cannot (`cast $alarm 30` —
    // payload or radius?).
    .{ .name = "cast", .inputs = &.{ p.in("in", Tag.any), p.opt("value", Tag.any), p.kwIn("at", Tag.any), p.kwOpt("decay", Tag.duration) }, .statics = &.{ .{ .name = "channel", .kind = .channel }, .{ .name = "radius", .kind = .literal, .kw = true }, .{ .name = "to", .kind = .condition, .kw = true, .optional = true } }, .routes = .main, .help = "Deposit into a field channel — `cast $chan [value] radius <r> at <pos> [decay <d>] [to <#tag>]`; piped, the input is the rousing; `to` couples delivery to a tag's members (posts hear everything).", .class = .effect, .eval = evalCast },
    // The membership sinks share `inc`'s port shape — the rousing carries no
    // payload (a set operation takes nothing from the stream) — and compose
    // their one write-list entry from the subject/condition pair
    // (`Program.registerWrites`), which is how the cycle check refuses a
    // set-subscription while `joined`/`count` reads stay siblings.
    .{ .name = "tag", .inputs = &.{p.occ("in", Tag.any)}, .statics = &.{ .{ .name = "subject", .kind = .subject }, .{ .name = "tag", .kind = .condition } }, .routes = .main, .help = "Add `@subject` to a tag — `tag @tom #garrison`; idempotent (twice is once), one tag per call. Piped, the input is the rousing; unpiped it fires once at mount.", .class = .effect, .eval = evalTag },
    .{ .name = "untag", .inputs = &.{p.occ("in", Tag.any)}, .statics = &.{ .{ .name = "subject", .kind = .subject }, .{ .name = "tag", .kind = .condition } }, .routes = .main, .help = "Remove `@subject` from a tag — `untag @tom #garrison`; idempotent, one tag per call. Piped, the input is the rousing; unpiped it fires once at mount.", .class = .effect, .eval = evalUntag },
    .{ .name = "const", .statics = &.{.{ .name = "value", .kind = .literal }}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Emit a constant once at mount.", .eval = evalConst },
    .{ .name = "tap", .inputs = &.{p.in("in", Tag.any)}, .statics = &.{.{ .name = "label", .kind = .word }}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Debug passthrough: log the value to the host's log bus.", .class = .reads, .eval = evalTap },
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
