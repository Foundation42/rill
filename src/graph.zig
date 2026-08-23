//! graph — the flat program graph.
//!
//! One arena of nodes, one arena of slots. No nesting, no call stack, no
//! scopes: `def` instances were flattened at parse with a name prefix, so
//! nothing downstream of the parser knows defs exist. Node ids are assigned
//! in parse order, and because local names are single-assignment and must be
//! defined before use, **parse order is topological order** — the evaluator
//! walks ids ascending and never needs a sort. (The tie-break rule of §4.5
//! falls out for free.)
//!
//! Every slot is a struple: it has a type, a value/occurrence kind, a stable
//! path (`programs.<program>.<node>.<in|out>.<port>`), and — once mounted — a
//! current value. Any wire is watchable by subscribing to its slot's path;
//! the wire-lighting debug view is a subscription, not a feature.

const std = @import("std");
const registry = @import("registry.zig");
const types = @import("types.zig");

pub const NodeId = u32;
pub const SlotId = u32;

pub const Dir = enum(u1) { in, out };

/// Where an input slot's value comes from. Output slots and unbound optional
/// inputs are `.none`. `.port` appears only inside def templates and never
/// survives flattening.
pub const Source = union(enum) {
    none,
    wire: SlotId, // an upstream node's output slot
    literal: []const u8, // struple-encoded constant (program-arena-owned)
    plane: []const u8, // live plane path — a subscription
    port: u8, // def template: the def's own input port
};

pub const Slot = struct {
    id: SlotId,
    node: NodeId,
    dir: Dir,
    port: u8,
    name: []const u8, // port name
    ty: types.TypeId,
    kind: registry.PortKind,
    source: Source = .none,
    /// Stable address: programs.<program>.<node>.<in|out>.<port>.
    path: []const u8 = "",
};

pub const Node = struct {
    id: NodeId,
    op: registry.OpId,
    /// Instance name: "bevel1", or "rivet1.scatter1" inside a flattened def.
    name: []const u8,
    inputs: []SlotId,
    outputs: []SlotId,
    statics: []registry.StaticVal,
};

/// One deduplicated plane subscription and the input slots it feeds.
pub const Sub = struct {
    path: []const u8,
    targets: std.ArrayListUnmanaged(SlotId) = .empty,
};

/// A `set`-style write target, kept for the mount-time cycle check and for
/// the error message that names the loop.
pub const WriteTarget = struct {
    path: []const u8,
    node: NodeId,
};

/// A parsed program: pure structure, no live values (those belong to the
/// Runtime that mounts it). Everything inside is owned by one arena; deinit
/// is a single arena teardown.
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    reg: *const registry.Registry,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    /// `as`-bound local names → the output slot they alias.
    names: std.StringArrayHashMapUnmanaged(SlotId) = .empty,
    subs: std.ArrayListUnmanaged(Sub) = .empty,
    writes: std.ArrayListUnmanaged(WriteTarget) = .empty,
    /// Downstream adjacency, built by `finalize`: for each slot, the input
    /// slots its value propagates to (non-empty only for output slots).
    downstream: []const []const SlotId = &.{},

    pub fn init(gpa: std.mem.Allocator, reg: *const registry.Registry, program_name: []const u8) !Program {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const name = try arena.allocator().dupe(u8, program_name);
        return .{ .arena = arena, .name = name, .reg = reg };
    }

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }

    pub fn a(self: *Program) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn node(self: *const Program, id: NodeId) *const Node {
        return &self.nodes.items[id];
    }

    pub fn slot(self: *const Program, id: SlotId) *const Slot {
        return &self.slots.items[id];
    }

    pub fn slotCount(self: *const Program) usize {
        return self.slots.items.len;
    }

    pub fn nodeCount(self: *const Program) usize {
        return self.nodes.items.len;
    }

    /// Find (or create) the deduplicated subscription record for `path`.
    pub fn subFor(self: *Program, path: []const u8) !*Sub {
        for (self.subs.items) |*s| {
            if (std.mem.eql(u8, s.path, path)) return s;
        }
        try self.subs.append(self.a(), .{ .path = try self.a().dupe(u8, path) });
        return &self.subs.items[self.subs.items.len - 1];
    }

    /// Build the downstream adjacency lists. Called once by the parser after
    /// the graph is complete.
    pub fn finalize(self: *Program) !void {
        const alloc = self.a();
        const lists = try alloc.alloc(std.ArrayListUnmanaged(SlotId), self.slots.items.len);
        for (lists) |*l| l.* = .empty;
        for (self.slots.items) |*s| {
            switch (s.source) {
                .wire => |up| try lists[up].append(alloc, s.id),
                else => {},
            }
        }
        const out = try alloc.alloc([]const SlotId, lists.len);
        for (lists, out) |*l, *o| o.* = l.items;
        self.downstream = out;
    }

    /// Path-level cycle detection (§4.4): a program that writes a path it also
    /// subscribes to — exactly, or through a segment prefix either way — is
    /// cyclic. Returns the offending pair for the error message.
    pub fn findCycle(self: *const Program) ?struct { write: WriteTarget, sub_path: []const u8 } {
        for (self.writes.items) |w| {
            for (self.subs.items) |s| {
                if (pathsOverlap(w.path, s.path)) return .{ .write = w, .sub_path = s.path };
            }
        }
        return null;
    }
};

/// `plane.x` overlaps `plane.x` and `plane.x.y` (either direction), but not
/// `plane.xy`. Segment-aware prefix test.
pub fn pathsOverlap(a_path: []const u8, b_path: []const u8) bool {
    const shorter = if (a_path.len <= b_path.len) a_path else b_path;
    const longer = if (a_path.len <= b_path.len) b_path else a_path;
    if (!std.mem.startsWith(u8, longer, shorter)) return false;
    return longer.len == shorter.len or longer[shorter.len] == '.';
}

test "pathsOverlap: exact, segment prefix, non-overlap" {
    try std.testing.expect(pathsOverlap("plane.x", "plane.x"));
    try std.testing.expect(pathsOverlap("plane.x", "plane.x.y"));
    try std.testing.expect(pathsOverlap("plane.x.y", "plane.x"));
    try std.testing.expect(!pathsOverlap("plane.x", "plane.xy"));
    try std.testing.expect(!pathsOverlap("plane.a", "plane.b"));
}
