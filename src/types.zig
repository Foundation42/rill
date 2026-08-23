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
};

const builtin_names = [_][]const u8{ "any", "number", "boolean", "string", "record", "bytes", "array" };

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
pub fn accepts(port_ty: TypeId, value_ty: TypeId) bool {
    return port_ty == Tag.any or value_ty == Tag.any or port_ty == value_ty;
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
