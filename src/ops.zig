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

    const dt = elapsed(st.frames, st.at, now);
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
        st = .{ .frames = d.frames, .at = now, .a = target, .b = target, .started = true };
        try st.write(ctx);
        return emitF64(ctx, target);
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
    const dt = elapsed(false, st.at, now);
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
/// `along` outside 0..1 — clamp, and `wrap 0 1` first if you meant to.
fn evalRange(ctx: *EvalCtx) EvalError!Emit {
    const t = std.math.clamp(try num(ctx, 0), 0, 1);
    const lo = try num(ctx, 1);
    const hi = try num(ctx, 2);
    return emitF64(ctx, lo + (hi - lo) * t);
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
        op,       if (left) "the left side" else "the right side",
        describeTop(ctx, bad), whereIn(ctx, path),
        describeTop(ctx, a),   describeTop(ctx, b),
    });
}

fn notBoolean(ctx: *EvalCtx, op: []const u8, path: []const u8, a: []const u8, b: []const u8, left: bool) EvalError {
    const bad = if (left) a else b;
    return ctx.refuse("{s}: {s} is {s}, not a boolean{s} — {s} and {s}", .{
        op,       if (left) "the left side" else "the right side",
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
        op, describeTop(ctx, a), describeTop(ctx, b), whereIn(ctx, path),
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
    /// A closed-value-set string port: a bare word coerces and its membership
    /// is checked at PARSE, so `lfo sqare 4s` is a wire-time error naming the
    /// list, not a BadValue three seconds into the animation.
    fn oneOf(n: []const u8, vals: []const []const u8) registry.Port {
        return .{ .name = n, .ty = types.Tag.string, .one_of = vals };
    }
};

const CORE = [_]registry.OpDef{
    // flow
    .{ .name = "select", .inputs = &.{ p.in("cond", Tag.boolean), p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "cond ? a : b — all branches exist; one is chosen per tick.", .eval = evalSelect },
    .{ .name = "lerp", .inputs = &.{ p.in("t", Tag.number), p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "a + (b - a) * t, t PIPED — `s | lerp 0.5 1.5` is s, lerped between 0.5 and 1.5.", .eval = evalLerp },
    .{ .name = "and", .inputs = &.{ p.in("a", Tag.boolean), p.in("b", Tag.boolean) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Boolean and — the conjunction idiom's other half: `dark | and calm | …`.", .eval = boolOp(fAnd) },
    .{ .name = "or", .inputs = &.{ p.in("a", Tag.boolean), p.in("b", Tag.boolean) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Boolean or.", .eval = boolOp(fOr) },
    .{ .name = "not", .inputs = &.{p.in("a", Tag.boolean)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Boolean not.", .eval = unBool() },
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
    .{ .name = "arm", .inputs = &.{ p.optOcc("in", Tag.any), p.optOcc("off", Tag.any), p.optOcc("on", Tag.any) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Latch gate, initially open: pass occurrences while armed; `off` closes, `on` re-opens (on wins a tie).", .class = .reads, .eval = gateEval(true) },
    .{ .name = "disarm", .inputs = &.{ p.optOcc("in", Tag.any), p.optOcc("off", Tag.any), p.optOcc("on", Tag.any) }, .outputs = &.{p.occ("out", Tag.any)}, .routes = .anywhere, .help = "Latch gate, initially closed: silent until `on` arms it; `off` closes again (on wins a tie).", .class = .reads, .eval = gateEval(false) },
    // tier 2, beat 1a — time as a value, waveforms, registers, shaping.
    // `ticks` is declared on every one that may re-arm itself; the badge is
    // derived from it and the live eval counter is shown beside it as proof.
    .{ .name = "clock", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Fed real time in seconds since mount, as a value. Re-evaluates every tick — anything downstream does too.", .class = .reads, .ticks = true, .eval = timeSource(false) },
    .{ .name = "frame", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Fed frame count since mount, as a value. Re-evaluates every frame — anything downstream does too.", .class = .reads, .ticks = true, .eval = timeSource(true) },
    .{ .name = "wave", .inputs = &.{ p.in("t", Tag.number), p.oneOf("shape", &WAVE_SHAPES), p.in("period", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Shape piped time into 0..1 — `clock | wave sine 4s`; shapes: sine, tri, saw, square. Pure: same t, same answer.", .eval = evalWave },
    .{ .name = "lfo", .inputs = &.{ p.oneOf("shape", &WAVE_SHAPES), p.in("period", Tag.duration), p.kwOpt("phase", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Modulation source in 0..1 — `lfo sine 4s [phase 0.25]`. The same waveform as `clock | wave`, in one node.", .class = .reads, .ticks = true, .eval = evalLfo },
    .{ .name = "ease", .inputs = &.{ p.in("in", Tag.number), p.in("tau", Tag.duration), p.kwOpt("up", Tag.duration), p.kwOpt("down", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Chase the input with time constant `tau`; `up`/`down` make it asymmetric. Stops inside epsilon of the target — it never snaps.", .class = .reads, .ticks = true, .eval = evalEase },
    .{ .name = "ramp", .inputs = &.{ p.in("in", Tag.number), p.in("over", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Tween linearly to each new target over `over`; retargeting starts from where it is. The last frame emits the target exactly.", .class = .reads, .ticks = true, .eval = evalRamp },
    .{ .name = "hold", .inputs = &.{ p.in("in", Tag.number), p.in("for", Tag.duration) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Sample-and-hold: take a value, then ignore changes for `for`. Does not tick — ignored values are gone.", .class = .reads, .eval = evalHold },
    .{ .name = "diff", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Rate of change per second from the previous sample. First observation baselines silently; ticks while moving, stops at zero.", .class = .reads, .ticks = true, .eval = evalDiff },
    .{ .name = "integrate", .inputs = &.{ p.in("in", Tag.number), p.kwIn("max", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Running sum over fed time, clamped to +/-max. The clamp is required — unbounded state is a corpse that rides every dump.", .class = .reads, .ticks = true, .eval = evalIntegrate },
    .{ .name = "range", .inputs = &.{ p.in("t", Tag.number), p.in("lo", Tag.number), p.in("hi", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Map 0..1 onto lo..hi, CLAMPING outside it — the exit from the unit interval. `lerp` is the same arithmetic that extrapolates.", .eval = evalRange },
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
    .{ .name = "add", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a + b.", .eval = binMath(fAdd) },
    .{ .name = "sub", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a - b.", .eval = binMath(fSub) },
    .{ .name = "mul", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a * b.", .eval = binMath(fMul) },
    .{ .name = "div", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a / b (IEEE; division by zero yields ±inf).", .eval = binMath(fDiv) },
    .{ .name = "min", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The smaller of a and b.", .eval = binMath(fMin) },
    .{ .name = "max", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The larger of a and b.", .eval = binMath(fMax) },
    .{ .name = "clamp", .inputs = &.{ p.in("in", Tag.number), p.in("lo", Tag.number), p.in("hi", Tag.number) }, .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "Clamp `in` to [lo, hi].", .eval = evalClamp },
    .{ .name = "abs", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Absolute value.", .eval = unMath(fAbs) },
    .{ .name = "floor", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Round toward −inf.", .eval = unMath(fFloor) },
    .{ .name = "round", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Round to nearest.", .eval = unMath(fRound) },
    // math completions (beat 1b) — every one broadcasts, being minted by the
    // same helpers as `add`.
    .{ .name = "sin", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Sine, radians.", .eval = unMath(fSin) },
    .{ .name = "cos", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Cosine, radians.", .eval = unMath(fCos) },
    .{ .name = "tan", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Tangent, radians.", .eval = unMath(fTan) },
    .{ .name = "sqrt", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Square root (IEEE; a negative yields nan).", .eval = unMath(fSqrt) },
    .{ .name = "exp", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "e to the input.", .eval = unMath(fExp) },
    .{ .name = "log", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Natural log (IEEE; zero yields -inf, a negative yields nan).", .eval = unMath(fLog) },
    .{ .name = "ceil", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Round toward +inf — `floor`'s missing mirror.", .eval = unMath(fCeil) },
    .{ .name = "sign", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "-1, 0 or 1 (nan stays nan).", .eval = unMath(fSign) },
    .{ .name = "fract", .inputs = &.{p.in("in", Tag.number)}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Fractional part, always in [0, 1) — `fract -0.25` is 0.75.", .eval = unMath(fFract) },
    .{ .name = "pow", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a to the power b — `x | pow 2` is x squared.", .eval = binMath(fPow) },
    .{ .name = "mod", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Floored modulo: the sign follows the divisor, so `-90 | mod 360` is 270.", .eval = binMath(fMod) },
    .{ .name = "atan2", .inputs = &.{ p.in("y", Tag.number), p.in("x", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Angle of (x, y) in radians, y PIPED — `dy | atan2 dx`.", .eval = binMath(fAtan2) },
    .{ .name = "pi", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "3.14159… — emitted once at mount.", .eval = constant(std.math.pi) },
    .{ .name = "tau", .outputs = &.{p.val("out", Tag.number)}, .routes = .anywhere, .help = "2*pi — a whole turn, emitted once at mount.", .eval = constant(std.math.tau) },
    // comparators
    .{ .name = "=", .inputs = &.{ p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .help = "Equality (numeric across int/float; byte-wise otherwise).", .eval = evalEq },
    .{ .name = "!=", .inputs = &.{ p.in("a", Tag.any), p.in("b", Tag.any) }, .outputs = &.{p.val("out", Tag.boolean)}, .routes = .anywhere, .help = "Inequality.", .eval = evalNe },
    .{ .name = "<", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a < b.", .eval = cmpOp(fLt) },
    .{ .name = "<=", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a <= b.", .eval = cmpOp(fLe) },
    .{ .name = ">", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a > b.", .eval = cmpOp(fGt) },
    .{ .name = ">=", .inputs = &.{ p.in("a", Tag.number), p.in("b", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "a >= b.", .eval = cmpOp(fGe) },
    // tier 2, beat 2 — arrays. The literal is the missing half of a value kind
    // that already existed: `window` emits an array and `stats` consumes one.
    .{ .name = "array", .variadic = true, .outputs = &.{p.val("out", Tag.array)}, .routes = .anywhere, .help = "Array construction [ a, b, c ] — a live tuple with positions instead of names.", .eval = evalArray },
    .{ .name = "nth", .inputs = &.{ p.in("in", Tag.array), p.in("i", Tag.number) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "The i-th element, 0-based — `window 5s | nth 0`. Out of range is an error, never a clamp.", .eval = indexEval(0, 1) },
    .{ .name = "choose", .inputs = &.{ p.in("i", Tag.number), p.in("of", Tag.array) }, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "`nth` with the index piped — `plane.time.band | choose [0.2, 1, 0.6, 0.05]`. Pick one of these.", .eval = indexEval(1, 0) },
    // records
    .{ .name = "record", .variadic = true, .outputs = &.{p.val("out", Tag.record)}, .routes = .anywhere, .help = "Record construction { field: stream, … } — a live tuple with named fields.", .eval = evalRecord },
    .{ .name = "project", .inputs = &.{p.in("in", Tag.record)}, .statics = &.{.{ .name = "field", .kind = .word }}, .outputs = &.{p.val("out", Tag.any)}, .routes = .anywhere, .help = "Field access on a record stream (`stats.mana`).", .eval = evalProject },
    .{ .name = "merge", .inputs = &.{ p.in("a", Tag.record), p.in("b", Tag.record) }, .outputs = &.{p.val("out", Tag.record)}, .routes = .anywhere, .help = "Merge two records; b's fields win.", .eval = evalMerge },
    // plane / util
    .{ .name = "set", .inputs = &.{ p.in("in", Tag.any), p.opt("value", Tag.any) }, .statics = &.{.{ .name = "path", .kind = .path }}, .routes = .anywhere, .help = "Write to a plane path — `set <path> [value]`; piped, the input is the rousing and `value` is what gets written.", .class = .effect, .eval = evalSink },
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
    // The third write kind. `plane.x | add 1 | set plane.x` reads a path it
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
