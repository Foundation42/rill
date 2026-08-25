//! types — rill's semantic type table.
//!
//! Ports and slots carry a `TypeId`, not a struple wire kind. The distinction
//! is load-bearing: struple's `Kind` says how bytes decode (int, map, string);
//! a rill type says what a stream *means* — and the host gets to mint meanings
//! (`mesh`, `points`, `grade`) that no wire-format enum can know about. A small
//! set of built-in ids covers the struple-representable values; everything else
//! is interned by name at registration time, so wire-time type checking stays a
//! table lookup with no separate type system.
//!
//! Values themselves are always struple-encoded element streams (one element
//! per slot). Canonical encoding is what makes compare-and-suppress a memcmp.

const std = @import("std");
const struple = @import("struple");

pub const TypeId = u16;

/// Built-in type ids. `any` matches everything on both sides of a wire.
pub const Tag = struct {
    pub const any: TypeId = 0;
    pub const number: TypeId = 1; // int or float on the wire; math promotes to f64
    pub const boolean: TypeId = 2;
    pub const string: TypeId = 3;
    pub const record: TypeId = 4; // struple map, canonical (key-sorted)
    pub const bytes: TypeId = 5;
    pub const array: TypeId = 6;
    pub const duration: TypeId = 7; // [lane, count] — see Duration below
};

const builtin_names = [_][]const u8{ "any", "number", "boolean", "string", "record", "bytes", "array", "duration" };

/// Spelling aliases accepted in `def` port declarations and host registrations.
const aliases = [_]struct { []const u8, TypeId }{
    .{ "int", Tag.number },
    .{ "float", Tag.number },
    .{ "bool", Tag.boolean },
    .{ "str", Tag.string },
    .{ "map", Tag.record },
};

/// Name ⇄ id table. Host types are interned on first sight and keep their id
/// for the table's lifetime; ids are dense so they can index side arrays.
pub const TypeTable = struct {
    gpa: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    by_name: std.StringHashMapUnmanaged(TypeId) = .empty,

    pub fn init(gpa: std.mem.Allocator) !TypeTable {
        var t = TypeTable{ .gpa = gpa };
        errdefer t.deinit();
        for (builtin_names) |n| _ = try t.intern(n);
        for (aliases) |a| try t.by_name.put(gpa, a[0], a[1]);
        return t;
    }

    pub fn deinit(self: *TypeTable) void {
        for (self.names.items) |n| self.gpa.free(n);
        self.names.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
    }

    /// Get-or-register. Unknown names mint a new id — a `def` may declare a
    /// `mesh` port before the host has injected any mesh operator.
    pub fn intern(self: *TypeTable, type_name: []const u8) !TypeId {
        if (self.by_name.get(type_name)) |id| return id;
        const id: TypeId = @intCast(self.names.items.len);
        const owned = try self.gpa.dupe(u8, type_name);
        errdefer self.gpa.free(owned);
        try self.names.append(self.gpa, owned);
        try self.by_name.put(self.gpa, owned, id);
        return id;
    }

    pub fn find(self: *const TypeTable, type_name: []const u8) ?TypeId {
        return self.by_name.get(type_name);
    }

    pub fn name(self: *const TypeTable, id: TypeId) []const u8 {
        return self.names.items[id];
    }
};

/// The wire-time compatibility rule: `any` is a wildcard on either side;
/// everything else must match exactly. `mesh → number` fails here.
///
/// **One exception, and it is broadcast's** (beat 1b, 2026-08-25): a `number`
/// or `boolean` port also accepts a **record or an array**, because arithmetic
/// and comparison are elementwise over containers — `@player.pos | add {x: 0,
/// y: 2, z: 0}` is the whole point, and a wire rule that refused it would make
/// the feature unsayable. What the container *contains* is not knowable at
/// wire time, so the eval-time mismatch check is the authority there; it names
/// both sides and the offending field, which is louder than anything this
/// function could say.
///
/// The cost, stated: a container literal now reaches every `number` port,
/// including ones with no elementwise meaning (`inc`'s `by`, `integrate`'s
/// `max`, a threshold). Those refuse at eval instead of at parse — later, but
/// not quieter. `expect`/`match` (beat 2) are the author's way back to a
/// mount-time answer.
pub fn accepts(port_ty: TypeId, value_ty: TypeId) bool {
    if (port_ty == Tag.any or value_ty == Tag.any or port_ty == value_ty) return true;
    if (port_ty == Tag.number or port_ty == Tag.boolean) {
        return value_ty == Tag.record or value_ty == Tag.array;
    }
    return false;
}

/// Classify a struple-encoded literal into a built-in TypeId.
pub fn typeOfValue(encoded: []const u8) TypeId {
    if (encoded.len == 0) return Tag.any;
    const t = encoded[0];
    const tc = struple.tc;
    if (t >= tc.int_neg_big and t <= tc.int_pos_big) return Tag.number;
    if (t == tc.float32 or t == tc.float64 or t == tc.decimal) return Tag.number;
    if (t == tc.bool_false or t == tc.bool_true) return Tag.boolean;
    if (t == tc.string) return Tag.string;
    if (t == tc.map) return Tag.record;
    if (t == tc.bytes) return Tag.bytes;
    if (t == tc.array) return Tag.array;
    return Tag.any;
}

/// A duration value (§2.2 of the agents/time doc). Two lanes, never mixed:
/// real time counts nanoseconds, frame time counts engine frames — `3f` is
/// three honest frames, not a faked 50ms. On the wire a duration is a
/// two-int struple array `[lane, count]` (lane 0 = ns, 1 = frames), so the
/// unit rides with the value and a bare number arriving at a duration port
/// is a BadValue, not a guess.
pub const Duration = struct {
    frames: bool,
    count: u64,
};

/// Strict decode of a duration element: exactly one array of exactly two
/// non-negative ints, lane 0 or 1. Anything else is null — temporal operators
/// turn that into BadValue (the wave dies, counted).
pub fn asDuration(encoded: []const u8) ?Duration {
    var r = struple.reader(encoded);
    const elem = (r.next() catch return null) orelse return null;
    if (elem != .array) return null;
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const v = struple.view(encoded);
    const inner = ((v.containedItems(fba.allocator()) catch return null) orelse return null);
    var ir = struple.reader(inner);
    const lane_e = (ir.next() catch return null) orelse return null;
    const count_e = (ir.next() catch return null) orelse return null;
    if ((ir.next() catch return null) != null) return null;
    if (lane_e != .int or count_e != .int) return null;
    const lane = lane_e.int;
    if (lane != 0 and lane != 1) return null;
    if (count_e.int < 0) return null;
    return .{ .frames = lane == 1, .count = @intCast(count_e.int) };
}

/// Encode a duration in its canonical wire shape (see Duration).
pub fn appendDuration(pk: *struple.Packer, scratch: std.mem.Allocator, d: Duration) !void {
    var inner = struple.Packer.init(scratch);
    try inner.appendInt(if (d.frames) 1 else 0);
    try inner.appendInt(@intCast(d.count));
    try pk.appendArray(inner.bytes());
}

/// Decode a single-element number (int or float) as f64. Math operators
/// promote to f64 uniformly so the output encoding is canonical per operator.
pub fn asNumber(encoded: []const u8) ?f64 {
    var r = struple.reader(encoded);
    const elem = (r.next() catch return null) orelse return null;
    return switch (elem) {
        .int => |v| @floatFromInt(v),
        .float32 => |v| v,
        .float64 => |v| v,
        else => null,
    };
}

/// Decode a single-element string. The slice borrows from `encoded`.
pub fn asString(encoded: []const u8) ?[]const u8 {
    var r = struple.reader(encoded);
    const elem = (r.next() catch return null) orelse return null;
    return switch (elem) {
        .string => |s| s,
        else => null,
    };
}

pub fn asBool(encoded: []const u8) ?bool {
    var r = struple.reader(encoded);
    const elem = (r.next() catch return null) orelse return null;
    return switch (elem) {
        .boolean => |b| b,
        else => null,
    };
}

test "durations: canonical encode/decode, strict shape, both lanes" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var pk = struple.Packer.init(a);
    try appendDuration(&pk, a, .{ .frames = false, .count = 5_000_000_000 });
    const d = asDuration(pk.bytes()).?;
    try std.testing.expect(!d.frames);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), d.count);

    var pf = struple.Packer.init(a);
    try appendDuration(&pf, a, .{ .frames = true, .count = 3 });
    const f = asDuration(pf.bytes()).?;
    try std.testing.expect(f.frames);
    try std.testing.expectEqual(@as(u64, 3), f.count);

    // not durations: a bare number, a wrong-lane array, a three-element array
    var pn = struple.Packer.init(a);
    try pn.appendInt(5);
    try std.testing.expect(asDuration(pn.bytes()) == null);
    var pw = struple.Packer.init(a);
    var inner = struple.Packer.init(a);
    try inner.appendInt(2);
    try inner.appendInt(5);
    try pw.appendArray(inner.bytes());
    try std.testing.expect(asDuration(pw.bytes()) == null);
    var p3 = struple.Packer.init(a);
    var inner3 = struple.Packer.init(a);
    try inner3.appendInt(0);
    try inner3.appendInt(5);
    try inner3.appendInt(5);
    try p3.appendArray(inner3.bytes());
    try std.testing.expect(asDuration(p3.bytes()) == null);
}

test "type table: builtins, aliases, interning" {
    var t = try TypeTable.init(std.testing.allocator);
    defer t.deinit();
    try std.testing.expectEqual(Tag.number, t.find("number").?);
    try std.testing.expectEqual(Tag.number, t.find("int").?);
    try std.testing.expectEqual(Tag.record, t.find("map").?);
    const mesh = try t.intern("mesh");
    try std.testing.expectEqual(mesh, try t.intern("mesh"));
    try std.testing.expect(mesh >= builtin_names.len);
    try std.testing.expectEqualStrings("mesh", t.name(mesh));
    try std.testing.expect(accepts(Tag.any, mesh));
    try std.testing.expect(accepts(mesh, mesh));
    try std.testing.expect(!accepts(Tag.number, mesh));
}
