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
    /// The section body this node drives, per element (`map`, `keep`,
    /// `reduce` — tier 2 beat 3). The ONLY link that is serialized; the three
    /// below are derived from it by `linkBodies`, at the end of a parse and at
    /// the end of a load, so a dump carries one number instead of four
    /// mutually-consistent ones.
    body: ?NodeId = null,
    /// Set on the BODY node: who drives it — and, being non-null, the fact
    /// that this node IS a body. A value arriving on one of the body's *bound*
    /// inputs (`keep (> plane.threshold)`) must rouse the consumer, not the
    /// body; `Runtime.markNode` is the single place that happens, which is why
    /// there is no second "skip bodies" flag (see the note there).
    body_of: ?NodeId = null,
    /// Set on the BODY node: its open input slots, in port order. These are
    /// what `args` fills.
    body_open: []SlotId = &.{},
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

/// One cast's channel, remembered per node (T4 / fork C extension): casts
/// never enter the write list — a field has no read side, so the cycle
/// check must not see them — but they ARE effects, and the host's grant
/// policy needs to see every effect a program will have at mount. A
/// separate list keeps both truths.
pub const CastTarget = struct {
    channel: []const u8,
    node: NodeId,
};

/// A non-fatal parse diagnostic. rill errors loudly by default — a warning is
/// reserved for text that is *well-formed and probably not what was meant*,
/// where refusing it would be the parser overruling the author. The first one
/// is the `also`-block discard (§3.14).
///
/// Warnings describe the source, not the graph, so they are deliberately not
/// serialised: a restored Program carries none, and that is correct — the text
/// they point into is gone. Hosts print them at mount and move on.
pub const Warning = struct {
    line: u32,
    col: u32,
    msg: []const u8,
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
    /// Channels this program casts into, per node — the grant policy's
    /// other half (see `CastTarget`). Populated by `registerWrites`.
    casts: std.ArrayListUnmanaged(CastTarget) = .empty,
    /// Non-fatal parse diagnostics, in source order. Arena-owned like the rest.
    warnings: std.ArrayListUnmanaged(Warning) = .empty,
    /// The LAST top-level statement's value, if it has one — what a one-shot
    /// echoes (rillbook §2). Broader than `resultSlot` on purpose: a bare
    /// `plane.x` line has no node, a bare `0.1` has no node AND no
    /// subscription, yet "what does this print" still has an answer — the
    /// path's current value, the literal itself. A statement ending in a
    /// sink sets this null (effects echo nothing). Not serialized: dumps are
    /// for mounted programs, and the echo is the one-shot's concern.
    result: ?Source = null,
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

    /// The program's RESULT: the first output of the last node that produces
    /// one. A one-shot host uses this to echo the value of a line whose final
    /// statement is an expression rather than a sink — "what does this print"
    /// having no answer is a console defect, not a language property. Null when
    /// nothing in the program produces a value (every effect op — `set`, and
    /// every seeded console verb — declares no outputs, so a pure effect line
    /// echoes nothing and its acknowledgement stands alone).
    pub fn resultSlot(self: *const Program) ?SlotId {
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const n = self.nodes.items[i];
            if (n.outputs.len > 0) return n.outputs[0];
        }
        return null;
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
        self.carryKinds();
        try self.linkBodies();
    }

    /// An elementwise operator CARRIES the kind of what is piped into it: an
    /// occurrence through `mul 2` is still an occurrence.
    ///
    /// Ruled 2026-08-26, after Chris bound a muzzle flash to a mouse button and
    /// then made the obvious edit — "I wanted the flash brighter":
    ///
    ///     lmb | rose_above 0.5 | mul 2 | kick 15ms 150ms | write …
    ///                           ^^^^^
    ///
    /// It fired once and never again. `rose_above` emits an occurrence, but
    /// `mul`'s output slot was declared a VALUE, so `emitSlot`'s "20 to 20 is
    /// silence" suppressed the second press at the source and the envelope
    /// downstream never heard it. Every press after the first produced the same
    /// number, and the same number is not an arrival.
    ///
    /// Silence was the wrong answer twice over: the spelling reads correctly,
    /// and nothing in the language said otherwise. `kick`'s own comment already
    /// says "an occurrence that repeats is two occurrences" — this makes that
    /// true through arithmetic as well.
    ///
    /// Port 0 is the piped one and `broadcasts` is already how a port declares
    /// its operator elementwise (beat 1b), so this needs no new marker: the
    /// same flag that makes the output TYPE follow the input now makes the
    /// output KIND follow it too. One forward pass suffices because node ids
    /// are topological, so `occ | mul 2 | add 1 | kick` carries the whole way.
    ///
    /// Only a WIRED input carries. A plane subscription's kind is decided per
    /// delta by the host (a mailbox path delivers occurrences), which a static
    /// slot cannot know — so `plane.events | mul 2 | kick` still collapses, and
    /// that is worth its own ruling rather than a guess here.
    fn carryKinds(self: *Program) void {
        for (self.nodes.items) |*n| {
            if (n.inputs.len == 0 or n.outputs.len == 0) continue;
            const def = self.reg.get(n.op);
            if (def.inputs.len == 0 or !def.inputs[0].broadcasts) continue;
            const piped = self.slot(n.inputs[0]);
            const up = switch (piped.source) {
                .wire => |sid| sid,
                else => continue, // a literal or an unwired port stays a value
            };
            if (self.slots.items[up].kind != .occurrence) continue;
            for (n.outputs) |sid| self.slots.items[sid].kind = .occurrence;
        }
    }

    /// Derive every body link from the one that is serialized (`Node.body`).
    /// Called at the end of a parse and at the end of a load, so a parsed
    /// program and a restored one cannot disagree — the dump carries one
    /// number and this rebuilds the other three from it.
    pub fn linkBodies(self: *Program) !void {
        for (self.nodes.items) |*n| {
            n.body_of = null;
            n.body_open = &.{};
        }
        for (self.nodes.items) |*n| {
            const body_id = n.body orelse continue;
            const b = &self.nodes.items[body_id];
            b.body_of = n.id;
            const bdef = self.reg.get(b.op);
            var open = std.ArrayListUnmanaged(SlotId).empty;
            for (b.inputs) |sid| {
                const sl = &self.slots.items[sid];
                if (sl.source != .none) continue;
                // An unbound OPTIONAL port is absent, not open — it must not
                // become a slot the consumer fills. Same rule the parser's
                // arity check applies, derived from the same registry so a
                // restored program cannot disagree with a parsed one.
                if (sl.port < bdef.inputs.len and bdef.inputs[sl.port].optional) continue;
                try open.append(self.a(), sid);
            }
            b.body_open = open.items;
        }
    }

    /// Register one effect node's write targets from its statics — the ONE
    /// composition both call sites (parser bind, dump restore) share, so the
    /// dump cannot disagree with the parse. `path` statics land directly;
    /// a `subject`/`condition` pair (the membership sinks, ironwood R6 T3)
    /// composes the member key `plane.tags.<tag>.<@subject>` — member keys
    /// wear `@`, service leaves (`joined`/`left`/`count`) are bare words, so
    /// a set-subscription overlaps and a service read never does.
    pub fn registerWrites(self: *Program, statics: []const registry.StaticVal, node_id: NodeId) !void {
        var subject: ?[]const u8 = null;
        var condition: ?[]const u8 = null;
        for (statics) |sv| switch (sv) {
            .path => |wp| try self.writes.append(self.a(), .{ .path = wp, .node = node_id }),
            .subject => |s| subject = s,
            // An optional condition fills empty when unbound (`cast` with no
            // `to`) — empty is absent, never a member key.
            .condition => |c| condition = if (c.len > 0) c else null,
            .channel => |ch| try self.casts.append(self.a(), .{ .channel = ch, .node = node_id }),
            else => {},
        };
        if (subject != null and condition != null) {
            const member = try std.fmt.allocPrint(self.a(), "plane.tags.{s}.{s}", .{ condition.?[1..], subject.? });
            try self.writes.append(self.a(), .{ .path = member, .node = node_id });
        }
    }

    /// Path-level cycle detection (§4.4): a program that writes a path it also
    /// subscribes to — exactly, or through a segment prefix either way — is
    /// cyclic. Returns the offending pair for the error message.
    pub fn findCycle(self: *const Program) ?struct { write: WriteTarget, sub_path: []const u8 } {
        for (self.writes.items) |w| {
            // A `row.` write against a `row.` read is NOT a cycle (spindrift
            // beat 1, ruled 2026-09-01: a kernel is a rill whose plane is
            // the row). §4.4 refuses a plane feedback loop because the write
            // comes back as a delta and re-dirties the reader — a storm. The
            // row plane has no dirty propagation: every field is read once
            // as the sweep's snapshot and written once after it, so `row.vel
            // | add g | write row.vel` is the integration step `x ← f(x)`,
            // once per tick, and nothing can re-fire. A `row.` write can
            // never overlap a `plane.` read (different heads), so the only
            // pair this exempts is the one the row evaluator was built for.
            if (std.mem.startsWith(u8, w.path, "row.")) continue;
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
