//! plane — the borrowed data-plane interface.
//!
//! rill is handed a plane, it never owns one. Same fn-pointer discipline as
//! Matryoshka's PackResolver: the ctx is opaque, the pointers are the whole
//! contract, and rill never learns Substrate/radix internals. Matryoshka backs
//! this with the real data plane over the main-thread drain; the test suite
//! backs it with `MockPlane` — a struple map plus whatever deltas the test
//! scripts through `Runtime.feed`. No engine required.
//!
//! Values crossing this boundary are struple-encoded element streams
//! (`[]const u8`), borrowed and valid only for the call.

const std = @import("std");
const struple = @import("struple");
const types = @import("types.zig");

pub const SubId = u32;

pub const PlaneError = error{ NotFound, Denied, Backend } || std.mem.Allocator.Error;

pub const Plane = struct {
    ctx: *anyopaque,
    subscribeFn: *const fn (ctx: *anyopaque, path: []const u8, sub: SubId) PlaneError!void,
    unsubscribeFn: *const fn (ctx: *anyopaque, sub: SubId) void,
    /// Read the current value at `path` into `out` (appended as one element).
    readFn: *const fn (ctx: *anyopaque, path: []const u8, out: *struple.Packer) PlaneError!void,
    /// Writes carry the same three-kind taxonomy the inbound deltas do, and
    /// for the same reason: what a write MEANS decides how it coalesces. A
    /// `.value` write replaces, an `.occurrence` write appends, an
    /// `.accumulate` write adds. rill tags; the plane applies. Note rill does
    /// not sum accumulate writes itself — the queue's promise is one batch in
    /// evaluation order, and two `+1`s applied in order are the same `+2`.
    writeFn: *const fn (ctx: *anyopaque, path: []const u8, val: []const u8, kind: DeltaKind) PlaneError!void,

    pub fn subscribe(self: Plane, path: []const u8, sub: SubId) PlaneError!void {
        return self.subscribeFn(self.ctx, path, sub);
    }
    pub fn unsubscribe(self: Plane, sub: SubId) void {
        self.unsubscribeFn(self.ctx, sub);
    }
    pub fn read(self: Plane, path: []const u8, out: *struple.Packer) PlaneError!void {
        return self.readFn(self.ctx, path, out);
    }
    pub fn write(self: Plane, path: []const u8, val: []const u8, kind: DeltaKind) PlaneError!void {
        return self.writeFn(self.ctx, path, val, kind);
    }
};

/// A delta the host pushes into the evaluator between ticks. `seq` is the
/// host's ordering stamp; within a tick the last write per path wins, in
/// feed order.
/// What kind of change a delta is — the same two-kind taxonomy rill's ports
/// already draw, now crossing the plane boundary. A VALUE delta coalesces
/// across a tick and is suppressed when its bytes are unchanged: late, never
/// wrong. An OCCURRENCE delta does neither. A trigger pulled twice is two
/// pulls, and identical bytes are the normal case for a trigger — an enemy at
/// the gate, then an enemy at the gate again.
/// Reserved third kind: `inc` sums its deltas within a tick and applies the
/// sum once, silencing a net-zero tick. It is here now, unimplemented, because
/// widening this enum later would be the second refactor this reservation
/// exists to avoid — and because the taxonomy is the point: three coalescing
/// rules, one per kind, chosen by the path's policy rather than by the caller.
///
/// Why it is not sugar for `x | add 1 | set x`: that reads a path it writes,
/// and the cycle check rightly refuses it. A blind delta reads nothing, so it
/// passes legitimately — and being commutative, it is MORE deterministic than
/// read-modify-write, since arrival order stops mattering.
pub const DeltaKind = enum(u2) { value, occurrence, accumulate };

pub const Delta = struct {
    path: []const u8,
    value: []const u8,
    seq: u64 = 0,
    kind: DeltaKind = .value,
};

/// In-memory plane for tests and the demo: a path→value struple map, a record
/// of every write (so tests can assert flush order), and a subscription set.
pub const MockPlane = struct {
    gpa: std.mem.Allocator,
    store: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    subs: std.AutoArrayHashMapUnmanaged(SubId, []u8) = .empty,
    writes: std.ArrayListUnmanaged(Write) = .empty,

    pub const Write = struct { path: []u8, value: []u8, kind: DeltaKind = .value };

    pub fn init(gpa: std.mem.Allocator) MockPlane {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MockPlane) void {
        var it = self.store.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.store.deinit(self.gpa);
        for (self.subs.values()) |p| self.gpa.free(p);
        self.subs.deinit(self.gpa);
        for (self.writes.items) |w| {
            self.gpa.free(w.path);
            self.gpa.free(w.value);
        }
        self.writes.deinit(self.gpa);
    }

    /// Seed or update a stored value (does not generate a delta — tests feed
    /// deltas explicitly through the runtime, mirroring the host contract).
    pub fn put(self: *MockPlane, path: []const u8, value: []const u8) !void {
        const gop = try self.store.getOrPut(self.gpa, path);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, path);
        }
        gop.value_ptr.* = try self.gpa.dupe(u8, value);
    }

    /// Convenience: seed a single scalar via struple's comptime dispatch.
    pub fn putValue(self: *MockPlane, path: []const u8, value: anytype) !void {
        var p = struple.Packer.init(self.gpa);
        defer p.deinit();
        try p.append(value);
        try self.put(path, p.bytes());
    }

    pub fn asPlane(self: *MockPlane) Plane {
        return .{
            .ctx = self,
            .subscribeFn = subscribeThunk,
            .unsubscribeFn = unsubscribeThunk,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    fn subscribeThunk(ctx: *anyopaque, path: []const u8, sub: SubId) PlaneError!void {
        const self: *MockPlane = @ptrCast(@alignCast(ctx));
        // A SubId is PROGRAM-local — every Runtime numbers its subscriptions
        // from zero — so a plane serving two mounted programs sees the same id
        // twice. Deltas are addressed by path (`Runtime.feed`), never by id, so
        // for the mock this map is bookkeeping and the collision is harmless;
        // what is not harmless is dropping the old string on the floor.
        const dup = try self.gpa.dupe(u8, path);
        const gop = self.subs.getOrPut(self.gpa, sub) catch |err| {
            self.gpa.free(dup);
            return err;
        };
        if (gop.found_existing) self.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = dup;
    }

    fn unsubscribeThunk(ctx: *anyopaque, sub: SubId) void {
        const self: *MockPlane = @ptrCast(@alignCast(ctx));
        if (self.subs.fetchSwapRemove(sub)) |kv| self.gpa.free(kv.value);
    }

    fn readThunk(ctx: *anyopaque, path: []const u8, out: *struple.Packer) PlaneError!void {
        const self: *MockPlane = @ptrCast(@alignCast(ctx));
        const v = self.store.get(path) orelse return error.NotFound;
        out.appendRaw(v) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Backend, // a corrupt store value is the backend's fault
        };
    }

    fn writeThunk(ctx: *anyopaque, path: []const u8, val: []const u8, kind: DeltaKind) PlaneError!void {
        const self: *MockPlane = @ptrCast(@alignCast(ctx));
        try self.writes.append(self.gpa, .{
            .path = try self.gpa.dupe(u8, path),
            .value = try self.gpa.dupe(u8, val),
            .kind = kind,
        });
        // Writes land in the store too, like a real plane — and an accumulate
        // write is an ADD, which is the whole difference. A mock that stored
        // the delta instead of applying it would let every `inc` test pass
        // while saying nothing.
        switch (kind) {
            .value, .occurrence => try self.put(path, val),
            .accumulate => try self.applyDelta(path, val),
        }
    }

    /// `+n` onto the stored number, 0 if the path is empty. Integer-preserving:
    /// a whole count stays a count, so a tally reads back as `3`, not `3.0`.
    fn applyDelta(self: *MockPlane, path: []const u8, val: []const u8) PlaneError!void {
        const by = types.asNumber(val) orelse return error.Denied;
        const prev: f64 = if (self.store.get(path)) |cur| (types.asNumber(cur) orelse return error.Denied) else 0;
        const sum = prev + by;
        var pk = struple.Packer.init(self.gpa);
        defer pk.deinit();
        if (@trunc(sum) == sum and @abs(sum) < 9.0e15) {
            try pk.appendInt(@intFromFloat(sum));
        } else {
            try pk.appendF64(sum);
        }
        try self.put(path, pk.bytes());
    }
};

test "mock plane: seed, subscribe, read, write log" {
    var mock = MockPlane.init(std.testing.allocator);
    defer mock.deinit();
    const plane = mock.asPlane();

    try mock.putValue("plane.player.health", @as(i64, 80));
    try plane.subscribe("plane.player.health", 0);

    var out = struple.Packer.init(std.testing.allocator);
    defer out.deinit();
    try plane.read("plane.player.health", &out);
    var r = struple.reader(out.bytes());
    try std.testing.expectEqual(@as(i128, 80), (try r.next()).?.int);
    try std.testing.expectError(error.NotFound, plane.read("plane.missing", &out));

    try plane.write("plane.ui.value", out.bytes(), .value);
    try std.testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try std.testing.expectEqualStrings("plane.ui.value", mock.writes.items[0].path);
}

test "mock plane: an accumulate write adds, and starts from nothing at zero" {
    var mock = MockPlane.init(std.testing.allocator);
    defer mock.deinit();
    const plane = mock.asPlane();

    var pk = struple.Packer.init(std.testing.allocator);
    defer pk.deinit();
    try pk.appendInt(2);

    try plane.write("plane.tally", pk.bytes(), .accumulate); // 0 + 2
    try plane.write("plane.tally", pk.bytes(), .accumulate); // 2 + 2
    try std.testing.expectEqual(@as(f64, 4), types.asNumber(mock.store.get("plane.tally").?).?);
    // The log keeps the deltas, not the totals — it is a record of writes.
    try std.testing.expectEqual(@as(f64, 2), types.asNumber(mock.writes.items[1].value).?);
    try std.testing.expectEqual(DeltaKind.accumulate, mock.writes.items[1].kind);
}
