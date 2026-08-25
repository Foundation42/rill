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
    /// Field casts (rill-casts.md). Not a `writeFn` kind on purpose: a cast is
    /// not addressed at a path — it is a deposit into the CASTER's owned
    /// space, keyed by who is casting, and the receiver-side sum is the only
    /// read surface. Null = the host has no field store; a mounted `cast`
    /// then fails loud at the node instead of writing into nowhere.
    castFn: ?*const fn (ctx: *anyopaque, c: Cast) PlaneError!void = null,
    /// Membership writes (`tag`/`untag`, ironwood R6 T3). Not a `writeFn`
    /// kind on purpose, for the cast's reason turned around: the host needs
    /// the SUBJECT and the TAG as names, not a pre-composed path — the
    /// subject was bound to an entity id at mount, and the host must refuse
    /// a write whose binding has gone stale (the bound id died or the name
    /// was re-registered) ON THE NODE, budget-counted, which a flush-time
    /// path write cannot do. Null = the host keeps no tag row; a mounted
    /// `tag` then fails loud at the node.
    tagFn: ?*const fn (ctx: *anyopaque, t: TagWrite) PlaneError!void = null,

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
    pub fn cast(self: Plane, c: Cast) PlaneError!void {
        const f = self.castFn orelse return error.Denied;
        return f(self.ctx, c);
    }
    pub fn tag(self: Plane, t: TagWrite) PlaneError!void {
        const f = self.tagFn orelse return error.Denied;
        return f(self.ctx, t);
    }
};

/// One membership write crossing the plane boundary (ironwood R6 T3).
/// Sigils ride whole on both names — they are the names' first characters
/// on every surface, never surface syntax to be stripped. The host owns
/// idempotence (twice is once), the joined/left mailboxes, and the count;
/// rill only says who, which tag, and which direction.
pub const TagWrite = struct {
    subject: []const u8, // `@`-sigil entity name (`@tom`)
    tag: []const u8, // `#`-sigil condition name (`#garrison`)
    adding: bool, // true = tag (join), false = untag (leave)
};

/// One field deposit crossing the plane boundary (rill-casts.md §2/§4.1).
/// The caster's owned space is a bag of these; the host applies its channel's
/// physics (kernel, clamp, occlusion) and leaks each deposit in fed time.
/// Anonymity is structural: no caster identity rides here — the host keys the
/// bag by which program's queue delivered it, and identity reaches a receiver
/// only if the caster put it in a payload somewhere else.
pub const Cast = struct {
    /// Channel name, `$` sigil included (`$alarm`) — the sigil is the name's
    /// first character on every surface, not surface syntax to be stripped.
    channel: []const u8,
    amplitude: f64, // signed: a relic casts negative blight
    /// Where the deposit lands — struple-encoded, decoded by the host (the
    /// engine expects a position; a mock just records it). Borrowed for the
    /// call.
    pos: []const u8,
    radius: f64,
    /// Time constant for this deposit's leak; null = the channel's declared
    /// default. Per-deposit runtime physics (the §5 reversal): a decay RILL
    /// would read the path it writes, and §4.4 refuses exactly that.
    decay: ?types.Duration,
    /// Coupling (`to #tag`, ironwood R6 T4): empty = uncoupled, absorbed by
    /// whoever is there. Non-empty scopes ENTITY perception — an entity-bound
    /// ear hears this deposit only while its entity carries the tag — while a
    /// POST hears everything: coupling governs entities, not the operator's
    /// instruments. Sigil included, like every name that crosses here.
    to: []const u8 = "",
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
/// Third kind, ACCUMULATE (`inc`): sums its deltas within a tick and applies
/// the sum once, silencing a net-zero tick. Not sugar for `x | add 1 | set x`
/// — that reads a path it writes and the cycle check rightly refuses it. A
/// blind delta reads nothing, so it passes legitimately, and being commutative
/// it is MORE deterministic than read-modify-write: arrival order stops
/// mattering.
///
/// Fourth kind, MEMBERSHIP (`tag`): reserved, not built (ironwood.md R6). It
/// unions adds minus removes within a tick and suppresses a net-no-change
/// tick. **Idempotence is what separates it from accumulate** — twice is
/// double for a counter, twice is once for a set. A soldier cannot be in the
/// shield wall one and a half times, which is also why the assembly tally
/// eventually wants membership rather than a blind `inc`: a set cannot drift
/// the way a counter can.
///
/// Both reservations are here before their implementations for the same
/// reason: widening this enum later is precisely the second refactor a
/// reservation exists to prevent, and every switch over it is exhaustive, so
/// the compiler points at each arm that has to answer for a new kind. The
/// taxonomy is the point — four coalescing rules, one per kind, chosen by what
/// a write MEANS rather than by which function the caller happened to reach
/// for. `enum(u2)` holds all four, so the fourth cost nothing but the arms.
pub const DeltaKind = enum(u2) { value, occurrence, accumulate, membership };

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
    /// Field deposits, in flush order — the mock's whole field store is this
    /// log. Summing kernels is the engine's job (beat 2); tests here assert
    /// what was deposited, which is everything rill core promises.
    casts: std.ArrayListUnmanaged(CastRec) = .empty,
    /// Membership writes, in dispatch order. The mock records direction and
    /// names; idempotence, mailboxes and counts are the host's physics.
    tag_writes: std.ArrayListUnmanaged(TagRec) = .empty,

    pub const Write = struct { path: []u8, value: []u8, kind: DeltaKind = .value };
    pub const CastRec = struct { channel: []u8, amplitude: f64, pos: []u8, radius: f64, decay: ?types.Duration, to: []u8 = &.{} };
    pub const TagRec = struct { subject: []u8, tag: []u8, adding: bool };

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
        for (self.casts.items) |c| {
            self.gpa.free(c.channel);
            self.gpa.free(c.pos);
            if (c.to.len > 0) self.gpa.free(c.to);
        }
        self.casts.deinit(self.gpa);
        for (self.tag_writes.items) |t| {
            self.gpa.free(t.subject);
            self.gpa.free(t.tag);
        }
        self.tag_writes.deinit(self.gpa);
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
    /// Seed a path from a Zig value. Structs become records and arrays/slices
    /// become arrays (struple's `append` covers scalars only), so a test can
    /// seed `.{ .x = 1, .y = 2 }` and `[_]f64{ 1, 2, 3 }` directly — which is
    /// what broadcast's gates need and what every container gate after them
    /// will need too.
    pub fn putValue(self: *MockPlane, path: []const u8, value: anytype) !void {
        var p = struple.Packer.init(self.gpa);
        defer p.deinit();
        try packAny(self.gpa, &p, value);
        try self.put(path, p.bytes());
    }

    fn packAny(gpa: std.mem.Allocator, p: *struple.Packer, value: anytype) !void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        switch (info) {
            .@"struct" => |st| {
                if (st.is_tuple) return error.Unsupported;
                var entries: [st.fields.len][2][]const u8 = undefined;
                var keys: [st.fields.len]struple.Packer = undefined;
                var vals: [st.fields.len]struple.Packer = undefined;
                inline for (st.fields, 0..) |f, i| {
                    // A map key is an ENCODED string element, not raw bytes —
                    // `appendMap` splices what it is given. Handing it
                    // `f.name` builds a record nothing can iterate.
                    keys[i] = struple.Packer.init(gpa);
                    try keys[i].appendString(f.name);
                    vals[i] = struple.Packer.init(gpa);
                    try packAny(gpa, &vals[i], @field(value, f.name));
                    entries[i] = .{ keys[i].bytes(), vals[i].bytes() };
                }
                defer for (&keys) |*b| b.deinit();
                defer for (&vals) |*b| b.deinit();
                try p.appendMap(&entries);
            },
            // A string is a pointer too, and iterating it would encode a
            // sequence of byte-ints instead of a string — a trap that costs
            // nothing to close now and would be baffling later.
            .array, .pointer => {
                if (comptime isStringy(T)) return p.append(value);
                var inner = struple.Packer.init(gpa);
                defer inner.deinit();
                for (value) |v| try packAny(gpa, &inner, v);
                try p.appendArray(inner.bytes());
            },
            else => try p.append(value),
        }
    }

    fn isStringy(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .pointer => |ptr| switch (ptr.size) {
                .one => switch (@typeInfo(ptr.child)) {
                    .array => |arr| arr.child == u8,
                    else => false,
                },
                .slice, .many => ptr.child == u8,
                else => false,
            },
            .array => |arr| arr.child == u8,
            else => false,
        };
    }

    pub fn asPlane(self: *MockPlane) Plane {
        return .{
            .ctx = self,
            .subscribeFn = subscribeThunk,
            .unsubscribeFn = unsubscribeThunk,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .castFn = castThunk,
            .tagFn = tagThunk,
        };
    }

    /// The same plane with no field store — for pinning that `cast` fails
    /// loud (counted at the node) rather than writing into nowhere.
    pub fn asPlaneWithoutFields(self: *MockPlane) Plane {
        var p = self.asPlane();
        p.castFn = null;
        return p;
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

    fn castThunk(ctx: *anyopaque, c: Cast) PlaneError!void {
        const self: *MockPlane = @ptrCast(@alignCast(ctx));
        const channel = try self.gpa.dupe(u8, c.channel);
        errdefer self.gpa.free(channel);
        const pos = try self.gpa.dupe(u8, c.pos);
        errdefer self.gpa.free(pos);
        const to: []u8 = if (c.to.len > 0) try self.gpa.dupe(u8, c.to) else &.{};
        errdefer if (to.len > 0) self.gpa.free(to);
        try self.casts.append(self.gpa, .{
            .channel = channel,
            .amplitude = c.amplitude,
            .pos = pos,
            .radius = c.radius,
            .decay = c.decay,
            .to = to,
        });
    }

    fn tagThunk(ctx: *anyopaque, t: TagWrite) PlaneError!void {
        const self: *MockPlane = @ptrCast(@alignCast(ctx));
        const subject = try self.gpa.dupe(u8, t.subject);
        errdefer self.gpa.free(subject);
        const tag_name = try self.gpa.dupe(u8, t.tag);
        errdefer self.gpa.free(tag_name);
        try self.tag_writes.append(self.gpa, .{ .subject = subject, .tag = tag_name, .adding = t.adding });
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
            // Reserved (ironwood.md R6). A mock that quietly stored a tag write
            // as a value would let the first `tag` test pass while proving
            // nothing — the same trap `applyDelta` exists to avoid.
            .membership => return error.Denied,
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
