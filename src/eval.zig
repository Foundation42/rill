//! eval — mount, feed, tick.
//!
//! A program is mounted, not run: the runtime subscribes the program's plane
//! paths, seeds literals, evaluates the whole graph once (tick 0 — the
//! program is live from the moment it mounts, effects included), and then
//! sits on the data plane re-evaluating incrementally as deltas arrive.
//!
//! The tick (§4.1): deltas fed since the last tick are already coalesced per
//! path (last write wins, in feed order); marking freshens the subscribed
//! slots; evaluation sweeps dirty nodes in ascending id order — parse order
//! is topological order, so no node evaluates twice and a node always sees a
//! consistent snapshot of all its inputs. `set` writes queue during the sweep
//! and flush through the plane at the end, in evaluation order.
//!
//! Suppression is a memcmp: value slots drop same-bytes writes (20→20 is
//! silence; storms die naturally), occurrence slots always propagate. Both
//! input and output slots hold their own copy of the current value, so every
//! wire is watchable and dumpable at any moment.
//!
//! Determinism (§4.5) is structural: stable order, canonical bytes, no clocks
//! in the data path. Same mounted program + same delta sequence ⇒
//! bit-identical slot states, every tick. Per-node eval/error counters and
//! per-tick µs are kept from day one (they are nearly free) — counters are
//! deterministic and belong to the dump; timings are measured and do not.
//!
//! Time is fed, ambient, and never subscribable. `tick(now)` carries the pair
//! {frame, time_ns}; temporal operators read it through EvalCtx when they
//! fire and arm the per-runtime timer wheel for their deadlines. The wheel is
//! the *only* subscription to time: nothing goes dirty because the clock
//! moved — only nodes whose deadlines have passed. A thousand mounted
//! watchdogs mid-window cost zero evaluations per tick. Fed time is
//! contractually non-decreasing on both lanes; a regression is a loud
//! error.TimeRegression, never a clamp — a clamped regression would replay
//! differently than it ran.

const std = @import("std");
const struple = @import("struple");
const types = @import("types.zig");
const registry = @import("registry.zig");
const graph = @import("graph.zig");
const plane_mod = @import("plane.zig");

const Program = graph.Program;
const SlotId = graph.SlotId;
const NodeId = graph.NodeId;
const Plane = plane_mod.Plane;
const Delta = plane_mod.Delta;
const DeltaKind = plane_mod.DeltaKind;

pub const MountError = error{Cycle} || plane_mod.PlaneError || std.mem.Allocator.Error;
pub const TickError = error{TimeRegression} || plane_mod.PlaneError || std.mem.Allocator.Error;

/// The fed time pair. Real time and frame count ride together because both
/// duration lanes are honest units (`5s` needs time_ns, `3f` needs frame) —
/// deriving one from the other would fake it. The host feeds engine time;
/// tests feed a script; nobody reads a wall clock.
pub const Now = struct {
    frame: u64 = 0,
    time_ns: u64 = 0,
};

const WheelEntry = struct { deadline: u64, node: NodeId };

const ValueBuf = std.ArrayListUnmanaged(u8);

const QueuedWrite = struct {
    path: []const u8, // program-arena-owned (a `set` static)
    value: []const u8, // tick-arena-owned
    kind: DeltaKind, // what the write MEANS, which decides how it coalesces
};

pub const LogFn = *const fn (ctx: ?*anyopaque, label: []const u8, val: []const u8) void;

/// Called once per freshened slot at the end of each tick, before the fresh
/// flags clear — the host's hook for mirroring live wires onto its plane
/// (`programs.<p>.<node>.<in|out>.<port>` becomes readable store state, §5).
/// Bytes are borrowed for the call.
pub const PublishFn = *const fn (ctx: ?*anyopaque, path: []const u8, value: []const u8) void;

/// One operator failure, for the host to publish as an error occurrence
/// (agents doc §6.2). The wave dies at the node either way — this is the
/// reporting seam, not a recovery hook, and a host that ignores it gets the
/// same evaluation it always did.
///
/// The sketch asked for `{node, port, tick, error, input_digest}`. `port` is
/// not carried: an `EvalError` names no port, so the runtime does not know
/// which input offended and would have to emit an empty field forever. `op` is
/// carried instead, which IS known and is what a reader actually wants next.
/// `input_digest` hashes the node's input bytes, so "the same failure with the
/// same inputs" is recognisable across ticks without storing the inputs.
pub const ErrorEvent = struct {
    node: []const u8,
    op: []const u8,
    frame: u64,
    time_ns: u64,
    err: []const u8,
    input_digest: u64,
};

pub const ErrorFn = *const fn (ctx: ?*anyopaque, ev: ErrorEvent) void;

/// Everything a host can hand the runtime at mount/restore time. The hooks
/// are also plain Runtime fields a host may set later; `host_ctx` is not —
/// mount runs tick 0, and a one-shot command program fires its effects right
/// there, so the host world must be in hand before the first eval.
pub const MountOpts = struct {
    /// Surfaced to every eval as `EvalCtx.host`; core operators ignore it.
    host_ctx: ?*anyopaque = null,
    log_fn: ?LogFn = null,
    log_ctx: ?*anyopaque = null,
    error_fn: ?ErrorFn = null,
    error_ctx: ?*anyopaque = null,
    publish_fn: ?PublishFn = null,
    publish_ctx: ?*anyopaque = null,
    /// The fed time tick 0 runs at. A rill mounted mid-session must baseline
    /// its windows against the *current* frame time, not zero — the one-shot
    /// console dispatch exercises this on every line. Zero is a legitimate
    /// epoch for hosts with no clock; it is still fed data, still monotonic.
    now: Now = .{},
};

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    prog: *const Program,
    plane: Plane,

    // slot state
    values: []ValueBuf,
    has: []bool,
    fresh: []bool,

    // node state
    node_state: []ValueBuf,
    dirty: []bool,
    eval_count: []u64,
    error_count: []u64,

    // per-tick machinery
    pending: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// Queued OCCURRENCE deltas, per path, in arrival order. Values coalesce
    /// (one per path per tick, last wins); occurrences never do, because
    /// collapsing two sightings into one is the difference between "an enemy
    /// arrived" and "three enemies arrived".
    pending_occ: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]u8)) = .empty,
    touched_slots: std.ArrayListUnmanaged(SlotId) = .empty,
    touched_nodes: std.ArrayListUnmanaged(NodeId) = .empty,
    write_queue: std.ArrayListUnmanaged(QueuedWrite) = .empty,

    // path → slot, for watch/override addressing
    slot_by_path: std.StringHashMapUnmanaged(SlotId) = .empty,

    // The timer wheel: two lanes of (absolute deadline, node), sorted by
    // deadline. Expiry marks nodes dirty at the top of the tick; entries are
    // consumed on firing — a stale wake (the op's real deadline moved) is
    // answered by the op re-arming, so each armed node keeps ~one live entry.
    wheel_ns: std.ArrayListUnmanaged(WheelEntry) = .empty,
    wheel_frame: std.ArrayListUnmanaged(WheelEntry) = .empty,
    /// Last fed time (dump-serialized: the monotonicity contract and every
    /// stored deadline are relative to *fed* history, which restore resumes).
    now: Now = .{},

    tick_index: u64 = 0,
    last_tick_ns: u64 = 0, // measured, never serialized
    log_fn: ?LogFn = null,
    log_ctx: ?*anyopaque = null,
    error_fn: ?ErrorFn = null,
    error_ctx: ?*anyopaque = null,
    publish_fn: ?PublishFn = null,
    publish_ctx: ?*anyopaque = null,
    host_ctx: ?*anyopaque = null,

    /// Mount a parsed program on a plane: subscribe, seed, and run tick 0 so
    /// the program is live (effects included) before this returns — with
    /// `opts` hooks and host context already attached, so tick 0 is a full
    /// citizen (effects see the host, freshened wires publish).
    pub fn mount(gpa: std.mem.Allocator, prog: *const Program, pl: Plane, opts: MountOpts) MountError!Runtime {
        var rt = try init(gpa, prog, pl, opts);
        errdefer rt.deinit();

        // Subscribe every deduplicated path; SubId is the index into prog.subs.
        for (prog.subs.items, 0..) |s, i| {
            try pl.subscribe(s.path, @intCast(i));
        }

        // Seed: initial plane reads (absent paths stay empty) and literals.
        var read_buf = struple.Packer.init(gpa);
        defer read_buf.deinit();
        for (prog.subs.items) |s| {
            read_buf.reset();
            pl.read(s.path, &read_buf) catch |err| switch (err) {
                error.NotFound => continue,
                else => return err,
            };
            for (s.targets.items) |sid| try rt.writeSlot(sid, read_buf.bytes());
        }
        for (prog.slots.items) |*s| {
            switch (s.source) {
                .literal => |b| try rt.writeSlot(s.id, b),
                else => {},
            }
        }

        // Tick 0: everything evaluates once, in topo order, at the mount
        // moment's fed time — window baselines are real from the first eval.
        for (0..prog.nodeCount()) |n| try rt.markNode(@intCast(n));
        rt.tick(opts.now) catch |err| switch (err) {
            error.TimeRegression => unreachable, // now starts at zero
            else => |e| return e,
        };
        return rt;
    }

    /// Rebuild a runtime from serialized state (see serialize.zig): subscribe,
    /// restore slot/node state verbatim, and do NOT tick — the dump already
    /// contains a live snapshot.
    pub fn restore(gpa: std.mem.Allocator, prog: *const Program, pl: Plane, opts: MountOpts) MountError!Runtime {
        var rt = try init(gpa, prog, pl, opts);
        errdefer rt.deinit();
        for (prog.subs.items, 0..) |s, i| {
            try pl.subscribe(s.path, @intCast(i));
        }
        return rt;
    }

    fn init(gpa: std.mem.Allocator, prog: *const Program, pl: Plane, opts: MountOpts) MountError!Runtime {
        const n_slots = prog.slotCount();
        const n_nodes = prog.nodeCount();
        var rt = Runtime{
            .gpa = gpa,
            .prog = prog,
            .plane = pl,
            .values = try gpa.alloc(ValueBuf, n_slots),
            .has = try gpa.alloc(bool, n_slots),
            .fresh = try gpa.alloc(bool, n_slots),
            .node_state = try gpa.alloc(ValueBuf, n_nodes),
            .dirty = try gpa.alloc(bool, n_nodes),
            .eval_count = try gpa.alloc(u64, n_nodes),
            .error_count = try gpa.alloc(u64, n_nodes),
            .log_fn = opts.log_fn,
            .log_ctx = opts.log_ctx,
            .error_fn = opts.error_fn,
            .error_ctx = opts.error_ctx,
            .publish_fn = opts.publish_fn,
            .publish_ctx = opts.publish_ctx,
            .host_ctx = opts.host_ctx,
        };
        for (rt.values) |*v| v.* = .empty;
        @memset(rt.has, false);
        @memset(rt.fresh, false);
        for (rt.node_state) |*v| v.* = .empty;
        @memset(rt.dirty, false);
        @memset(rt.eval_count, 0);
        @memset(rt.error_count, 0);
        for (prog.slots.items) |*s| {
            if (s.path.len > 0) try rt.slot_by_path.put(gpa, s.path, s.id);
        }
        return rt;
    }

    pub fn deinit(self: *Runtime) void {
        for (self.prog.subs.items, 0..) |_, i| self.plane.unsubscribe(@intCast(i));
        for (self.values) |*v| v.deinit(self.gpa);
        self.gpa.free(self.values);
        self.gpa.free(self.has);
        self.gpa.free(self.fresh);
        for (self.node_state) |*v| v.deinit(self.gpa);
        self.gpa.free(self.node_state);
        self.gpa.free(self.dirty);
        self.gpa.free(self.eval_count);
        self.gpa.free(self.error_count);
        for (self.pending.values()) |v| self.gpa.free(v);
        self.pending.deinit(self.gpa);
        for (self.pending_occ.values()) |*q| {
            for (q.items) |v| self.gpa.free(v);
            q.deinit(self.gpa);
        }
        self.pending_occ.deinit(self.gpa);
        self.touched_slots.deinit(self.gpa);
        self.touched_nodes.deinit(self.gpa);
        for (self.write_queue.items) |w| self.gpa.free(w.value);
        self.write_queue.deinit(self.gpa);
        self.slot_by_path.deinit(self.gpa);
        self.wheel_ns.deinit(self.gpa);
        self.wheel_frame.deinit(self.gpa);
    }

    // -- feeding ------------------------------------------------------------

    /// Push one plane delta. Coalescing is per path: within a tick the last
    /// fed value wins. Deltas for paths this program does not subscribe to
    /// are dropped (the host may broadcast).
    pub fn feed(self: *Runtime, delta: Delta) !void {
        const sub = for (self.prog.subs.items) |*s| {
            if (std.mem.eql(u8, s.path, delta.path)) break s;
        } else return;
        switch (delta.kind) {
            .value => {},
            .occurrence => {
                const oq = try self.pending_occ.getOrPut(self.gpa, sub.path);
                if (!oq.found_existing) oq.value_ptr.* = .empty;
                try oq.value_ptr.append(self.gpa, try self.gpa.dupe(u8, delta.value));
                return;
            },
            // INBOUND accumulate and membership are both still reserved. `inc`
            // produces an accumulate WRITE (rill → plane), but nothing feeds
            // one back the other way: the plane publishes the resulting value,
            // not the delta, so a subscriber sees a value delta like any other.
            // If that ever changes, the sum-per-tick rule goes here — and the
            // union-adds-minus-removes rule beside it. Refused rather than
            // silently treated as a value, because a wrong coalescing rule is
            // the quiet kind of wrong this taxonomy exists to prevent.
            .accumulate, .membership => return error.UnsupportedDeltaKind,
        }
        const gop = try self.pending.getOrPut(self.gpa, sub.path);
        if (gop.found_existing) self.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = try self.gpa.dupe(u8, delta.value);
    }

    /// Override an input slot's value from outside — the sparse-override path
    /// that makes def internals gradeable (`programs.p.rivet1.bevel1.in.r`).
    /// Only literal-bound or unbound inputs are overridable; wires and
    /// subscriptions have owners.
    pub fn setInput(self: *Runtime, path: []const u8, value: []const u8) error{ NotFound, NotOverridable, OutOfMemory }!void {
        const sid = self.slot_by_path.get(path) orelse return error.NotFound;
        const s = self.prog.slot(sid);
        if (s.dir != .in) return error.NotOverridable;
        switch (s.source) {
            .literal, .none => {},
            else => return error.NotOverridable,
        }
        try self.writeSlot(sid, value);
    }

    /// Read a slot's current value by path (null = no value yet). The console
    /// watches wires through exactly this.
    pub fn readSlot(self: *const Runtime, path: []const u8) ?[]const u8 {
        const sid = self.slot_by_path.get(path) orelse return null;
        return self.readSlotId(sid);
    }

    /// Read a slot by id — the path-free half of `readSlot`, for a caller that
    /// already holds the id (`Program.resultSlot`, notably). Null while the
    /// slot has never carried a value.
    pub fn readSlotId(self: *const Runtime, sid: graph.SlotId) ?[]const u8 {
        if (sid >= self.has.len or !self.has[sid]) return null;
        return self.values[sid].items;
    }

    // -- the timer wheel ----------------------------------------------------

    /// Arm a wheel entry: `node` goes dirty at the first tick whose fed time
    /// reaches `deadline`. Sorted insert, stable on ties; an exact duplicate
    /// (same node, same deadline) is dropped so re-arming is free.
    pub fn arm(self: *Runtime, deadline: registry.Deadline, node: NodeId) !void {
        const list, const at = switch (deadline) {
            .ns => |v| .{ &self.wheel_ns, v },
            .frame => |v| .{ &self.wheel_frame, v },
        };
        var i = list.items.len;
        while (i > 0 and list.items[i - 1].deadline > at) i -= 1;
        var j = i;
        while (j > 0 and list.items[j - 1].deadline == at) : (j -= 1) {
            if (list.items[j - 1].node == node) return;
        }
        try list.insert(self.gpa, i, .{ .deadline = at, .node = node });
    }

    fn expireWheel(self: *Runtime, list: *std.ArrayListUnmanaged(WheelEntry), now_val: u64) TickError!void {
        var k: usize = 0;
        while (k < list.items.len and list.items[k].deadline <= now_val) : (k += 1) {
            try self.markNode(list.items[k].node);
        }
        // Shrinking replaceRange never allocates.
        if (k > 0) list.replaceRange(self.gpa, 0, k, &.{}) catch unreachable;
    }

    // -- the tick -----------------------------------------------------------

    pub fn tick(self: *Runtime, now: Now) TickError!void {
        // Fed time is non-decreasing on both lanes, by contract. Loud, not
        // clamped: a clamp would replay differently than it ran.
        if (now.time_ns < self.now.time_ns or now.frame < self.now.frame) {
            return error.TimeRegression;
        }
        self.now = now;

        var timer: ?std.time.Timer = std.time.Timer.start() catch null;

        var arena_impl = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();

        // A tick runs one ROUND per queued occurrence per path: values coalesce
        // across the whole tick, occurrences never coalesce, and each round is
        // one sweep. Every round shares the tick's {frame, time_ns} — one tick,
        // one time, N rousings — because a cooldown that opened because round 3
        // "happened later" would be a wall clock smuggled in the back door.
        var rounds: usize = 1;
        for (self.pending_occ.values()) |q| rounds = @max(rounds, q.items.len);

        var round: usize = 0;
        while (round < rounds) : (round += 1) {
            // Mark: coalesced value deltas, once — they are the tick's state,
            // not one of its rousings. Same for the wheel: a deadline passes
            // once per tick, however many occurrences arrive beside it.
            if (round == 0) {
                for (self.pending.keys(), self.pending.values()) |path, val| {
                    const sub = for (self.prog.subs.items) |*s| {
                        if (std.mem.eql(u8, s.path, path)) break s;
                    } else unreachable;
                    for (sub.targets.items) |sid| try self.writeSlot(sid, val);
                }
                for (self.pending.values()) |v| self.gpa.free(v);
                self.pending.clearRetainingCapacity();

                // Entries armed *during* this tick's sweep land behind the
                // expiry scan and fire next tick at soonest.
                try self.expireWheel(&self.wheel_ns, now.time_ns);
                try self.expireWheel(&self.wheel_frame, now.frame);
            }

            // Mark: this round's occurrence for each path that still has one,
            // forced past suppression. Identical bytes are the NORMAL case for
            // a trigger — an enemy at the gate, then an enemy at the gate.
            for (self.pending_occ.keys(), self.pending_occ.values()) |path, q| {
                if (round >= q.items.len) continue;
                const sub = for (self.prog.subs.items) |*s| {
                    if (std.mem.eql(u8, s.path, path)) break s;
                } else unreachable;
                for (sub.targets.items) |sid| try self.writeSlotOccurrence(sid, q.items[round]);
            }

            // Evaluate: ascending node id = topological order. Propagation only
            // marks forward, so one sweep per round suffices and no node runs
            // twice within a round.
            var node_id: usize = 0;
            while (node_id < self.dirty.len) : (node_id += 1) {
                if (!self.dirty[node_id]) continue;
                try self.evalNode(@intCast(node_id), arena);
            }

            // Publish this round's freshened wires, then sweep the flags — per
            // ROUND, because the next round's marking needs a clean slate.
            if (self.publish_fn) |publish| {
                for (self.touched_slots.items) |sid| {
                    const s = self.prog.slot(sid);
                    if (s.path.len > 0) publish(self.publish_ctx, s.path, self.values[sid].items);
                }
            }
            for (self.touched_slots.items) |sid| self.fresh[sid] = false;
            self.touched_slots.clearRetainingCapacity();
            for (self.touched_nodes.items) |nid| self.dirty[nid] = false;
            self.touched_nodes.clearRetainingCapacity();
        }

        for (self.pending_occ.values()) |*q| {
            for (q.items) |v| self.gpa.free(v);
            q.deinit(self.gpa);
        }
        self.pending_occ.clearRetainingCapacity();

        // Flush queued plane writes ONCE, in evaluation order across every
        // round: a tick's effects reach the world as one batch, whatever it
        // took to produce them. (Casts are NOT here: they dispatch at eval,
        // where a refusal — unknown channel, bad position — can still land on
        // the NODE that cast it, §6-counted, instead of failing a flush that
        // no longer knows whose deposit it was holding. Batching is the
        // host's: its cast inbox drains once per frame either way.)
        defer {
            for (self.write_queue.items) |w| self.gpa.free(w.value);
            self.write_queue.clearRetainingCapacity();
        }
        for (self.write_queue.items) |w| {
            try self.plane.write(w.path, w.value, w.kind);
        }

        self.tick_index += 1;
        if (timer) |*t| self.last_tick_ns = t.read();
    }

    fn evalNode(self: *Runtime, node_id: NodeId, arena: std.mem.Allocator) TickError!void {
        const n = self.prog.node(node_id);
        const def = self.prog.reg.get(n.op);

        // All required inputs must have a value; otherwise stay quiet until
        // the graph fills in (startup, absent plane paths). An *optional*
        // port bound to a stream that hasn't produced yet reads as null —
        // same as unbound — instead of blocking the node: the gates' `off`/
        // `on` controls may sit on paths that fire rarely or never.
        for (n.inputs) |sid| {
            const s = self.prog.slot(sid);
            if (s.source == .none or self.has[sid]) continue;
            if (s.port < def.inputs.len and def.inputs[s.port].optional) continue;
            return;
        }

        const in = try arena.alloc(?[]const u8, n.inputs.len);
        const in_fresh = try arena.alloc(bool, n.inputs.len);
        for (n.inputs, 0..) |sid, i| {
            in[i] = if (self.has[sid]) self.values[sid].items else null;
            in_fresh[i] = self.fresh[sid];
        }
        const out = try arena.alloc(struple.Packer, n.outputs.len);
        for (out) |*o| o.* = struple.Packer.init(arena);

        var wake_thunk = WakeThunk{ .rt = self, .node = node_id };
        var ctx = registry.EvalCtx{
            .arena = arena,
            .in = in,
            .in_fresh = in_fresh,
            .out = out,
            .statics = n.statics,
            .state = &self.node_state[node_id],
            .state_gpa = self.gpa,
            .write_fn = queueWriteThunk,
            .write_ctx = self,
            .cast_fn = castThunk,
            .cast_ctx = self,
            .tag_fn = tagThunk,
            .tag_ctx = self,
            .log_fn = self.log_fn,
            .log_ctx = self.log_ctx,
            .host = self.host_ctx,
            .now_ns = self.now.time_ns,
            .now_frame = self.now.frame,
            .wake_fn = WakeThunk.wake,
            .wake_ctx = &wake_thunk,
        };

        self.eval_count[node_id] += 1;
        const emit = def.eval(&ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.error_count[node_id] += 1;
                // Report before returning: the wave still dies here, but a host
                // that wants to publish the occurrence (agents §6.2) needs the
                // node, the op and the inputs that produced it while they are
                // still in hand.
                if (self.error_fn) |f| {
                    var h = std.hash.Wyhash.init(0);
                    for (in) |maybe| {
                        if (maybe) |bytes| h.update(bytes) else h.update("\x00");
                    }
                    f(self.error_ctx, .{
                        .node = n.name,
                        .op = def.name,
                        .frame = self.now.frame,
                        .time_ns = self.now.time_ns,
                        .err = @errorName(err),
                        .input_digest = h.final(),
                    });
                }
                return; // the wave dies here; deterministic and non-fatal
            },
        };

        for (n.outputs, 0..) |sid, i| {
            if (!emit.has(@intCast(i))) continue;
            try self.emitSlot(sid, out[i].bytes());
        }
    }

    /// Store a freshly produced value into an output slot (with value-kind
    /// suppression) and propagate to downstream input slots.
    fn emitSlot(self: *Runtime, sid: SlotId, bytes: []const u8) TickError!void {
        const s = self.prog.slot(sid);
        if (s.kind == .value and self.has[sid] and std.mem.eql(u8, self.values[sid].items, bytes)) {
            return; // 20→20 is silence
        }
        try self.storeSlot(sid, bytes);
        for (self.prog.downstream[sid]) |down| {
            try self.storeSlot(down, bytes);
            try self.markNode(self.prog.slot(down).node);
        }
    }

    /// Store into a slot (input or subscribed), with value-kind suppression,
    /// freshening and dirty-marking its node.
    fn writeSlot(self: *Runtime, sid: SlotId, bytes: []const u8) !void {
        const s = self.prog.slot(sid);
        if (s.kind == .value and self.has[sid] and std.mem.eql(u8, self.values[sid].items, bytes)) {
            return;
        }
        try self.storeSlot(sid, bytes);
        try self.markNode(s.node);
    }

    /// Deliver an occurrence to a slot: store and mark, with no memcmp. The
    /// suppression in `writeSlot` is a VALUE rule — 20 to 20 is silence — and
    /// an occurrence is not a value.
    fn writeSlotOccurrence(self: *Runtime, sid: SlotId, bytes: []const u8) !void {
        const s = self.prog.slot(sid);
        try self.storeSlot(sid, bytes);
        try self.markNode(s.node);
    }

    fn storeSlot(self: *Runtime, sid: SlotId, bytes: []const u8) !void {
        const buf = &self.values[sid];
        buf.clearRetainingCapacity();
        try buf.appendSlice(self.gpa, bytes);
        self.has[sid] = true;
        if (!self.fresh[sid]) {
            self.fresh[sid] = true;
            try self.touched_slots.append(self.gpa, sid);
        }
    }

    fn markNode(self: *Runtime, nid: NodeId) !void {
        if (self.dirty[nid]) return;
        self.dirty[nid] = true;
        try self.touched_nodes.append(self.gpa, nid);
    }

    const WakeThunk = struct {
        rt: *Runtime,
        node: NodeId,

        fn wake(ctx: *anyopaque, deadline: registry.Deadline) registry.EvalError!void {
            const self: *WakeThunk = @ptrCast(@alignCast(ctx));
            self.rt.arm(deadline, self.node) catch return error.OutOfMemory;
        }
    };

    fn castThunk(ctx: *anyopaque, c: plane_mod.Cast) registry.EvalError!void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        // Dispatched at EVAL so a refusal lands on the node that cast it —
        // counted, §6-reported, wave dies there — instead of failing an
        // end-of-tick flush that no longer knows whose deposit it held. A
        // host with no field store refuses through the same door
        // (`Plane.cast` on a null castFn is Denied). The host is expected to
        // say WHY on its own channel before erroring; rill only counts.
        self.plane.cast(c) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.PlaneWrite,
        };
    }

    fn tagThunk(ctx: *anyopaque, t: plane_mod.TagWrite) registry.EvalError!void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        // Same door as a cast, same reason: a stale-binding refusal (the
        // subject died, or its name was re-registered under a new id) lands
        // on the node that wrote — counted, §6-reported, wave dies there —
        // and the host says WHY on its own channel before erroring.
        self.plane.tag(t) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.PlaneWrite,
        };
    }

    fn queueWriteThunk(ctx: *anyopaque, path: []const u8, val: []const u8, kind: DeltaKind) registry.EvalError!void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        // Copy the value with the runtime's own allocator: the caller's bytes
        // may live in the tick arena, but the queue outlives nothing — it is
        // flushed and cleared within the same tick, so gpa + explicit free
        // keeps ownership obvious.
        const copy = self.gpa.dupe(u8, val) catch return error.OutOfMemory;
        self.write_queue.append(self.gpa, .{ .path = path, .value = copy, .kind = kind }) catch {
            self.gpa.free(copy);
            return error.OutOfMemory;
        };
        return;
    }
};
