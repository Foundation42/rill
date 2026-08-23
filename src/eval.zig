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

pub const MountError = error{Cycle} || plane_mod.PlaneError || std.mem.Allocator.Error;
pub const TickError = plane_mod.PlaneError || std.mem.Allocator.Error;

const ValueBuf = std.ArrayListUnmanaged(u8);

const QueuedWrite = struct {
    path: []const u8, // program-arena-owned (a `set` static)
    value: []const u8, // tick-arena-owned
};

pub const LogFn = *const fn (ctx: ?*anyopaque, label: []const u8, val: []const u8) void;

/// Called once per freshened slot at the end of each tick, before the fresh
/// flags clear — the host's hook for mirroring live wires onto its plane
/// (`programs.<p>.<node>.<in|out>.<port>` becomes readable store state, §5).
/// Bytes are borrowed for the call.
pub const PublishFn = *const fn (ctx: ?*anyopaque, path: []const u8, value: []const u8) void;

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
    touched_slots: std.ArrayListUnmanaged(SlotId) = .empty,
    touched_nodes: std.ArrayListUnmanaged(NodeId) = .empty,
    write_queue: std.ArrayListUnmanaged(QueuedWrite) = .empty,

    // path → slot, for watch/override addressing
    slot_by_path: std.StringHashMapUnmanaged(SlotId) = .empty,

    tick_index: u64 = 0,
    last_tick_ns: u64 = 0, // measured, never serialized
    log_fn: ?LogFn = null,
    log_ctx: ?*anyopaque = null,
    publish_fn: ?PublishFn = null,
    publish_ctx: ?*anyopaque = null,

    /// Mount a parsed program on a plane: subscribe, seed, and run tick 0 so
    /// the program is live (effects included) before this returns.
    pub fn mount(gpa: std.mem.Allocator, prog: *const Program, pl: Plane) MountError!Runtime {
        var rt = try init(gpa, prog, pl);
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

        // Tick 0: everything evaluates once, in topo order.
        for (0..prog.nodeCount()) |n| try rt.markNode(@intCast(n));
        try rt.tick();
        return rt;
    }

    /// Rebuild a runtime from serialized state (see serialize.zig): subscribe,
    /// restore slot/node state verbatim, and do NOT tick — the dump already
    /// contains a live snapshot.
    pub fn restore(gpa: std.mem.Allocator, prog: *const Program, pl: Plane) MountError!Runtime {
        var rt = try init(gpa, prog, pl);
        errdefer rt.deinit();
        for (prog.subs.items, 0..) |s, i| {
            try pl.subscribe(s.path, @intCast(i));
        }
        return rt;
    }

    fn init(gpa: std.mem.Allocator, prog: *const Program, pl: Plane) MountError!Runtime {
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
        self.touched_slots.deinit(self.gpa);
        self.touched_nodes.deinit(self.gpa);
        for (self.write_queue.items) |w| self.gpa.free(w.value);
        self.write_queue.deinit(self.gpa);
        self.slot_by_path.deinit(self.gpa);
    }

    // -- feeding ------------------------------------------------------------

    /// Push one plane delta. Coalescing is per path: within a tick the last
    /// fed value wins. Deltas for paths this program does not subscribe to
    /// are dropped (the host may broadcast).
    pub fn feed(self: *Runtime, delta: Delta) !void {
        const sub = for (self.prog.subs.items) |*s| {
            if (std.mem.eql(u8, s.path, delta.path)) break s;
        } else return;
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
        if (!self.has[sid]) return null;
        return self.values[sid].items;
    }

    // -- the tick -----------------------------------------------------------

    pub fn tick(self: *Runtime) TickError!void {
        var timer: ?std.time.Timer = std.time.Timer.start() catch null;

        var arena_impl = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();

        // Mark: apply coalesced deltas to subscribed slots.
        for (self.pending.keys(), self.pending.values()) |path, val| {
            const sub = for (self.prog.subs.items) |*s| {
                if (std.mem.eql(u8, s.path, path)) break s;
            } else unreachable;
            for (sub.targets.items) |sid| try self.writeSlot(sid, val);
        }
        for (self.pending.values()) |v| self.gpa.free(v);
        self.pending.clearRetainingCapacity();

        // Evaluate: ascending node id = topological order. Propagation only
        // marks forward, so one sweep suffices and no node runs twice.
        var node_id: usize = 0;
        while (node_id < self.dirty.len) : (node_id += 1) {
            if (!self.dirty[node_id]) continue;
            try self.evalNode(@intCast(node_id), arena);
        }

        // Flush queued plane writes, in evaluation order.
        defer {
            for (self.write_queue.items) |w| self.gpa.free(w.value);
            self.write_queue.clearRetainingCapacity();
        }
        for (self.write_queue.items) |w| {
            try self.plane.write(w.path, w.value);
        }

        // Publish freshened wires to the host, then sweep flags.
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

        self.tick_index += 1;
        if (timer) |*t| self.last_tick_ns = t.read();
    }

    fn evalNode(self: *Runtime, node_id: NodeId, arena: std.mem.Allocator) TickError!void {
        const n = self.prog.node(node_id);
        const def = self.prog.reg.get(n.op);

        // All non-optional inputs must have a value; otherwise stay quiet
        // until the graph fills in (startup, absent plane paths).
        for (n.inputs) |sid| {
            const s = self.prog.slot(sid);
            if (s.source != .none and !self.has[sid]) return;
        }

        const in = try arena.alloc(?[]const u8, n.inputs.len);
        const in_fresh = try arena.alloc(bool, n.inputs.len);
        for (n.inputs, 0..) |sid, i| {
            in[i] = if (self.has[sid]) self.values[sid].items else null;
            in_fresh[i] = self.fresh[sid];
        }
        const out = try arena.alloc(struple.Packer, n.outputs.len);
        for (out) |*o| o.* = struple.Packer.init(arena);

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
            .log_fn = self.log_fn,
            .log_ctx = self.log_ctx,
        };

        self.eval_count[node_id] += 1;
        const emit = def.eval(&ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.error_count[node_id] += 1;
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

    fn queueWriteThunk(ctx: *anyopaque, path: []const u8, val: []const u8) registry.EvalError!void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        // Copy the value with the runtime's own allocator: the caller's bytes
        // may live in the tick arena, but the queue outlives nothing — it is
        // flushed and cleared within the same tick, so gpa + explicit free
        // keeps ownership obvious.
        const copy = self.gpa.dupe(u8, val) catch return error.OutOfMemory;
        self.write_queue.append(self.gpa, .{ .path = path, .value = copy }) catch {
            self.gpa.free(copy);
            return error.OutOfMemory;
        };
        return;
    }
};
