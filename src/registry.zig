//! registry — the one registration path for operators.
//!
//! Built-in, host-injected, and def-minted operators are indistinguishable
//! once registered: same `OpDef`, same graph box, same `help`, same
//! tab-complete source. The host seeds this table at startup (in Matryoshka,
//! from the console `Cmd` inventory); rill's core set registers through the
//! exact same call.
//!
//! `OpDef.eval` is a plain function pointer over `EvalCtx` — no closures, no
//! per-op vtables. An operator decides whether the wave continues downstream
//! by which output bits it sets in the returned `Emit` mask; mask 0 lets the
//! wave die at this node (`where` eating a value is exactly that).

const std = @import("std");
const struple = @import("struple");
const types = @import("types.zig");

pub const TypeId = types.TypeId;

/// The one type bit that matters (§4.2): `value` streams compare-and-suppress
/// (same bytes = silence), `occurrence` streams always propagate when emitted.
pub const PortKind = enum(u1) { value, occurrence };

pub const Port = struct {
    name: []const u8,
    ty: TypeId = types.Tag.any,
    kind: PortKind = .value,
    optional: bool = false,
    /// §3.11: the parser captures the rest of the line verbatim as a string
    /// literal bound here. Last input port only — `register` enforces the
    /// closed shape. A locator is freeform text, not structure.
    tail: bool = false,
    /// Non-empty on a string port: the closed value set a bound literal must
    /// belong to, checked at parse ("wire time"). This is the console's enum
    /// argument made enforceable — the same list the browser tab-completes
    /// from. Streams bound to the port are not (cannot be) checked at parse.
    one_of: []const []const u8 = &.{},
};

/// Static (non-stream) parameters an operator consumes at parse time:
/// `set plane.x` takes a `path` target, `tap hp` a `word` label, `const 5`
/// a `literal`. Statics are configuration, not subscriptions — a `path`
/// static is a write target, never an upstream edge.
pub const StaticKind = enum { path, word, literal };

pub const StaticDecl = struct {
    name: []const u8,
    kind: StaticKind,
};

pub const StaticVal = union(StaticKind) {
    path: []const u8,
    word: []const u8,
    literal: []const u8, // struple-encoded element
};

/// Which outputs emitted this tick. Bit i = output port i.
pub const Emit = packed struct {
    mask: u32 = 0,

    pub const none = Emit{ .mask = 0 };
    pub const first = Emit{ .mask = 1 };

    pub fn bit(i: u5) Emit {
        return .{ .mask = @as(u32, 1) << i };
    }

    pub fn with(self: Emit, i: u5) Emit {
        return .{ .mask = self.mask | (@as(u32, 1) << i) };
    }

    pub fn has(self: Emit, i: u5) bool {
        return (self.mask >> i) & 1 == 1;
    }
};

pub const EvalError = error{ BadValue, PlaneWrite } || std.mem.Allocator.Error;

/// What an operator sees when it evaluates. Input values are struple-encoded
/// element streams borrowed from the slot arena (valid only for the call);
/// outputs are written through per-port packers backed by the tick arena.
pub const EvalCtx = struct {
    /// Per-tick scratch arena. Anything allocated here dies at end of tick.
    arena: std.mem.Allocator,
    /// Current value per input port; null = no value has ever arrived.
    in: []const ?[]const u8,
    /// Which inputs are fresh this tick — a value input that actually changed,
    /// or an occurrence input that fired. Gates key off this.
    in_fresh: []const bool,
    /// One packer per output port. Set the matching Emit bit for what you wrote.
    out: []struple.Packer,
    /// Resolved static arguments, in declaration order.
    statics: []const StaticVal,
    /// Persistent per-node state (struple bytes), survives across ticks and is
    /// part of the program dump. Threshold/edge operators keep their previous
    /// side here.
    state: *std.ArrayListUnmanaged(u8),
    state_gpa: std.mem.Allocator,
    /// Effect channel: queue a plane write, flushed in order at end of tick.
    write_fn: *const fn (ctx: *anyopaque, path: []const u8, val: []const u8) EvalError!void,
    write_ctx: *anyopaque,
    /// Debug/log bus for `tap`; null when the host wired none.
    log_fn: ?*const fn (ctx: ?*anyopaque, label: []const u8, val: []const u8) void = null,
    log_ctx: ?*anyopaque = null,
    /// Opaque host world, passed at mount (`MountOpts.host_ctx`) and live
    /// from tick 0. Host-seeded operators downcast this to reach what the
    /// write/log channels can't express — the engine plane, correlation ids,
    /// a reply slot. Core operators never touch it.
    host: ?*anyopaque = null,

    pub fn write(self: *EvalCtx, path: []const u8, val: []const u8) EvalError!void {
        return self.write_fn(self.write_ctx, path, val);
    }

    pub fn log(self: *EvalCtx, label: []const u8, val: []const u8) void {
        if (self.log_fn) |f| f(self.log_ctx, label, val);
    }

    pub fn setState(self: *EvalCtx, bytes: []const u8) !void {
        self.state.clearRetainingCapacity();
        try self.state.appendSlice(self.state_gpa, bytes);
    }
};

pub const OpClass = enum {
    pure, // output depends only on inputs; evaluator may cache/skip
    effect, // touches the world through the plane (set/play/trigger)
};

pub const OpDef = struct {
    name: []const u8,
    inputs: []const Port = &.{},
    outputs: []const Port = &.{},
    statics: []const StaticDecl = &.{},
    help: []const u8,
    class: OpClass = .pure,
    /// Variadic operators (record construction) take their port list from the
    /// call site; `inputs` is ignored and one `word` static names each field.
    variadic: bool = false,
    eval: *const fn (ctx: *EvalCtx) EvalError!Emit,
};

pub const OpId = u32;

pub const RegistryError = error{ DuplicateOp, BadTailPort, BadEnumPort } || std.mem.Allocator.Error;

/// The operator table. Owns nothing but its own arrays: `OpDef` port/static
/// slices are borrowed from the registrant (comptime tables for built-ins;
/// the host keeps its own alive).
pub const Registry = struct {
    gpa: std.mem.Allocator,
    types: types.TypeTable,
    ops: std.ArrayListUnmanaged(OpDef) = .empty,
    by_name: std.StringHashMapUnmanaged(OpId) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Registry {
        return .{ .gpa = gpa, .types = try types.TypeTable.init(gpa) };
    }

    pub fn deinit(self: *Registry) void {
        self.ops.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.types.deinit();
    }

    pub fn register(self: *Registry, def: OpDef) RegistryError!OpId {
        if (self.by_name.contains(def.name)) return error.DuplicateOp;
        // Tails are a closed grammar (§3.11): last input only, string-typed,
        // never variadic — and every port before the tail is required, because
        // "fixed prefix, then rest of line" has no room for maybe-there args.
        if (def.inputs.len > 0) {
            const last = def.inputs[def.inputs.len - 1];
            if (last.tail and (last.ty != types.Tag.string or def.variadic)) return error.BadTailPort;
            for (def.inputs[0 .. def.inputs.len - 1]) |p| {
                if (p.tail) return error.BadTailPort;
                if (last.tail and p.optional) return error.BadTailPort;
            }
        }
        // `one_of` is a string-port contract — a value set on any other type
        // could never be satisfied by a literal and would gate nothing.
        for (def.inputs) |p| {
            if (p.one_of.len > 0 and p.ty != types.Tag.string) return error.BadEnumPort;
        }
        const id: OpId = @intCast(self.ops.items.len);
        try self.ops.append(self.gpa, def);
        errdefer _ = self.ops.pop();
        try self.by_name.put(self.gpa, def.name, id);
        return id;
    }

    pub fn find(self: *const Registry, op_name: []const u8) ?OpId {
        return self.by_name.get(op_name);
    }

    pub fn get(self: *const Registry, id: OpId) *const OpDef {
        return &self.ops.items[id];
    }
};

test "registry: tail ports keep their closed shape — last only, string, required prefix" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const noopEval = struct {
        fn f(_: *EvalCtx) EvalError!Emit {
            return Emit.none;
        }
    }.f;
    const str = types.Tag.string;
    const good = [_]Port{ .{ .name = "gain", .ty = types.Tag.number }, .{ .name = "locator", .ty = str, .tail = true } };
    _ = try reg.register(.{ .name = "ok", .inputs = &good, .help = "", .eval = noopEval });

    const not_last = [_]Port{ .{ .name = "locator", .ty = str, .tail = true }, .{ .name = "gain", .ty = types.Tag.number } };
    try std.testing.expectError(error.BadTailPort, reg.register(.{ .name = "a", .inputs = &not_last, .help = "", .eval = noopEval }));

    const not_string = [_]Port{.{ .name = "locator", .ty = types.Tag.number, .tail = true }};
    try std.testing.expectError(error.BadTailPort, reg.register(.{ .name = "b", .inputs = &not_string, .help = "", .eval = noopEval }));

    const optional_prefix = [_]Port{ .{ .name = "gain", .ty = types.Tag.number, .optional = true }, .{ .name = "locator", .ty = str, .tail = true } };
    try std.testing.expectError(error.BadTailPort, reg.register(.{ .name = "c", .inputs = &optional_prefix, .help = "", .eval = noopEval }));
}

test "registry: register/find, duplicate rejected" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const noopEval = struct {
        fn f(_: *EvalCtx) EvalError!Emit {
            return Emit.none;
        }
    }.f;
    const id = try reg.register(.{ .name = "noop", .help = "does nothing", .eval = noopEval });
    try std.testing.expectEqual(id, reg.find("noop").?);
    try std.testing.expectError(error.DuplicateOp, reg.register(.{ .name = "noop", .help = "", .eval = noopEval }));
}
