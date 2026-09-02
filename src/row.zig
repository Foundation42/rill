//! row — a rill mounted on a spray: the row is the plane.
//!
//! Ruled 2026-09-01 (spindrift beat 1): a kernel is a rill program whose
//! plane is the row. You mount a rill; a kernel is a rill mounted on a
//! spray rather than on the world. The file is a fan-out of independent
//! flows over the row — no def body, no section, no new grammar. Row fields
//! are `row.pos`, `row.vel`, `row.age` …, sigil mandatory like `plane.`, bare
//! names a parse error. Writes into row fields use the write verb with its
//! mode word. `plane.…` reads inside a kernel are broadcasts: one value per
//! tick, the same for every row.
//!
//! **Row-legality is a COLUMN, not a Routing value.** Routing says which
//! thread; the column says whether an op can be evaluated per row. They are
//! orthogonal, and the C seam stays a boolean. The column carries the user
//! channels an op's per-row state needs and an exactness bit — and the bit is
//! EARNED, not declared: an op is exact when its result is defined by integer
//! arithmetic only. The four arithmetic ops have it outright; a transcendental
//! earns it by getting an integer kernel, and that kernel is then the
//! definition for rows — the float path retires for rows. v1's row-legal set
//! is the exact set.
//!
//! The number is Q16.16 (`Fixed`), the same format spindrift's population
//! carries, so a row value crosses into a kernel and back with no conversion
//! and the whole per-row evaluation is integer. That is what makes a
//! population dump byte-identical across runs (G0) and what makes a second
//! evaluator of the same text a bit-identity question (G7).
//!
//! What this file owns: the value type, the column type, the row plane
//! interface a host implements, the kernels for the exact core set, and the
//! runtime that evaluates a parsed `Program` once per row. What it does not:
//! the population (the host's), the words that only mean something on a row
//! (`spawn`, `gravity`, `perish` — spindrift's, registered through the same
//! `Registry.register` as everything else), and the chunking (the host's,
//! over `common/jobs.zig`; `evalRow` is pure per row and thread-safe given a
//! `Scratch` per thread).

const std = @import("std");
const registry = @import("registry.zig");
const graph = @import("graph.zig");
const types = @import("types.zig");
const struple = @import("struple");

pub const Fixed = i32;
pub const FRAC_BITS: u5 = 16;
pub const ONE: Fixed = 1 << FRAC_BITS;
pub const HALF: Fixed = ONE / 2;
const FRAC_MASK: Fixed = ONE - 1;

/// Floor of the product — arithmetic shift, so rounding is toward −∞ on both
/// signs. One rule, so a GPU twin can match it.
pub fn mul(a: Fixed, b: Fixed) Fixed {
    const p: i64 = @as(i64, a) * @as(i64, b);
    return @intCast(p >> FRAC_BITS);
}

/// A value on a row. Scalars and 3-vectors are Q16.16; booleans are what
/// comparisons emit and `select` consumes. An ARRAY is a literal's shape
/// only — the first stateless array on the row (spindrift beat 3): it is
/// converted once at mount, owned by the runtime, shared read-only by
/// every row, and no op emits one. `over`'s curve is the customer.
pub const Val = union(enum) {
    scalar: Fixed,
    vec3: [3]Fixed,
    boolean: bool,
    array: []const Val,

    pub fn eql(a: Val, b: Val) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .scalar => |x| x == b.scalar,
            .vec3 => |v| std.mem.eql(Fixed, &v, &b.vec3),
            .boolean => |x| x == b.boolean,
            .array => |xs| blk: {
                if (xs.len != b.array.len) break :blk false;
                for (xs, b.array) |x, y| {
                    if (!x.eql(y)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    pub fn kindName(self: Val) []const u8 {
        return switch (self) {
            .scalar => "a number",
            .vec3 => "a vec3",
            .boolean => "a boolean",
            .array => "an array",
        };
    }
};

pub const FieldKind = enum { scalar, vec3 };

/// One field of the host's row. `writable` false refuses `write row.<name>`
/// at mount — `age`, `life`, `seed` are the spray's, a kernel reads them.
pub const Field = struct {
    name: []const u8,
    kind: FieldKind,
    writable: bool = true,
};

/// The host's population format, as the runtime sees it.
pub const Schema = []const Field;

pub const Error = error{BadValue};

/// The column on `OpDef`.
pub const Row = struct {
    /// User channels this op's per-row state needs (Q16.16 each). Zero for
    /// a pure op. Allocated from the row's user channels at mount; a kernel
    /// whose words need more than the row has is refused by name.
    channels: u3 = 0,
    /// EARNED: the result is defined by integer arithmetic only. v1's
    /// row-legal set is exactly the exact set.
    exact: bool = false,
    /// A row word — meaningful only on a spray. The PARSER refuses it in a
    /// plane program by name (`parse` vs `parseKernel`); its plane `eval`
    /// is a truthful slot-filler nothing reaches through the parser.
    only: bool = false,
    /// The integer kernel. Null = the op has no row evaluation at all.
    eval: ?*const fn (ctx: *Ctx) Error!void = null,

    pub fn legal(self: Row) bool {
        return self.eval != null and self.exact;
    }
};

/// Shorthand for the core table: an exact kernel, no state.
pub fn exact(f: *const fn (ctx: *Ctx) Error!void) Row {
    return .{ .exact = true, .eval = f };
}

pub const WriteMode = enum { replace, add };

/// Which field, and which axis of it when the field is a vec3 and the path
/// named one (`row.vel.y`).
pub const FieldRef = struct { field: u16, axis: ?u2 = null };

pub const WriteRef = struct { ref: FieldRef, mode: WriteMode };

/// The row plane — how the runtime reaches a population. Same fn-pointer
/// discipline as `Plane`: an opaque ctx and the pointers are the contract.
/// Everything crossing is `Val`, so the host's storage is its own business.
pub const Plane = struct {
    ctx: *anyopaque,
    schema: Schema,
    /// The whole field, whatever its kind.
    readFn: *const fn (ctx: *anyopaque, r: u32, field: u16) Val,
    /// The whole field. Axis writes are composed by the runtime from a read.
    writeFn: *const fn (ctx: *anyopaque, r: u32, field: u16, val: Val) void,
    /// Mark the row for retirement. The host reaps in its own serial phase —
    /// a kill inside the parallel row sweep is the freelist race G0 forbids.
    retireFn: *const fn (ctx: *anyopaque, r: u32) void,
    /// The row's user channels, for per-row op state.
    userFn: *const fn (ctx: *anyopaque, r: u32) []Fixed,

    pub fn read(self: Plane, r: u32, field: u16) Val {
        return self.readFn(self.ctx, r, field);
    }
    pub fn write(self: Plane, r: u32, field: u16, val: Val) void {
        self.writeFn(self.ctx, r, field, val);
    }
    pub fn retire(self: Plane, r: u32) void {
        self.retireFn(self.ctx, r);
    }
    pub fn user(self: Plane, r: u32) []Fixed {
        return self.userFn(self.ctx, r);
    }
};

const MAX_IN = 16;
const MAX_OUT = 4;

/// What a row kernel sees. Inputs and outputs are `Val`s, not struple; state
/// is this node's slice of the row's user channels; `dt` is the fed delta.
pub const Ctx = struct {
    in: []const ?Val,
    out: []?Val,
    statics: []const registry.StaticVal,
    state: []Fixed,
    dt: Fixed,
    row_index: u32,
    plane: *const Plane,
    /// Opaque host (the spray), for words that need it. Core kernels never
    /// touch it.
    host: ?*anyopaque = null,
    op: *const registry.OpDef,
    detail: *registry.Detail,
    /// Pre-resolved by mount for `write` nodes; null everywhere else.
    write_ref: ?WriteRef = null,
    scratch: *Scratch,

    pub fn refuse(self: *Ctx, comptime fmt: []const u8, args: anytype) Error {
        self.detail.set(fmt, args);
        return error.BadValue;
    }

    pub fn portName(self: *const Ctx, i: usize) []const u8 {
        if (i < self.op.inputs.len) return self.op.inputs[i].name;
        return "?";
    }

    pub fn val(self: *Ctx, i: usize) Error!Val {
        return self.in[i] orelse self.refuse("{s}: port '{s}' has no value", .{ self.op.name, self.portName(i) });
    }

    pub fn scalar(self: *Ctx, i: usize) Error!Fixed {
        const v = try self.val(i);
        return switch (v) {
            .scalar => |x| x,
            else => self.refuse("{s}: port '{s}' wants a number, got {s}", .{ self.op.name, self.portName(i), v.kindName() }),
        };
    }

    pub fn vec3(self: *Ctx, i: usize) Error![3]Fixed {
        const v = try self.val(i);
        return switch (v) {
            .vec3 => |x| x,
            else => self.refuse("{s}: port '{s}' wants a vec3, got {s}", .{ self.op.name, self.portName(i), v.kindName() }),
        };
    }

    /// A literal array — homogeneous numbers or vec3s, never empty.
    pub fn array(self: *Ctx, i: usize) Error![]const Val {
        const v = try self.val(i);
        return switch (v) {
            .array => |xs| xs,
            else => self.refuse("{s}: port '{s}' wants an array, got {s}", .{ self.op.name, self.portName(i), v.kindName() }),
        };
    }

    pub fn boolean(self: *Ctx, i: usize) Error!bool {
        return switch (try self.val(i)) {
            .boolean => |b| b,
            else => self.refuse("{s}: port '{s}' wants a boolean", .{ self.op.name, self.portName(i) }),
        };
    }

    /// Queue a row write; applied after the sweep, in node order, so every
    /// node in a row's sweep reads the tick's snapshot (rill's own rule).
    pub fn write(self: *Ctx, ref: FieldRef, mode: WriteMode, v: Val) Error!void {
        self.scratch.queueWrite(.{ .ref = ref, .mode = mode, .val = v }) catch
            return self.refuse("{s}: too many writes in one kernel sweep", .{self.op.name});
    }

    pub fn retire(self: *Ctx) void {
        self.scratch.retire = true;
    }
};

const QueuedWrite = struct { ref: FieldRef, mode: WriteMode, val: Val };

/// Per-thread evaluation scratch. One per worker; `evalRow` touches nothing
/// else that is mutable, which is the thread-safety contract.
pub const Scratch = struct {
    gpa: std.mem.Allocator,
    slots: []?Val,
    writes: []QueuedWrite,
    n_writes: usize = 0,
    retire: bool = false,
    /// Refusals this scratch saw, and the first one's words — merged by the
    /// host after its join, so the count is exact and the sum is in one order.
    refusals: u64 = 0,
    first_node: ?graph.NodeId = null,
    first: registry.Detail = .{},

    fn queueWrite(self: *Scratch, w: QueuedWrite) error{Full}!void {
        if (self.n_writes >= self.writes.len) return error.Full;
        self.writes[self.n_writes] = w;
        self.n_writes += 1;
    }

    pub fn deinit(self: *Scratch) void {
        self.gpa.free(self.slots);
        self.gpa.free(self.writes);
    }
};

pub const MountError = error{
    NotRowLegal,
    UnknownField,
    ReadOnlyField,
    BadAxis,
    BadLiteral,
    BadWriteTarget,
    BadWriteMode,
    ChannelsExceeded,
    TooManyPorts,
} || std.mem.Allocator.Error;

const NodeState = struct { off: u8 = 0, len: u8 = 0 };

/// A parsed program mounted on a row plane. Immutable after mount except for
/// the broadcast values, which the host sets between sweeps.
pub const Runtime = struct {
    gpa: std.mem.Allocator,
    prog: *const graph.Program,
    plane: Plane,
    /// Per `prog.subs` index: the row field it reads, or null for a plane
    /// broadcast the host supplies.
    sub_refs: []?FieldRef,
    /// Per `prog.subs` index: the broadcast value, host-set each tick. Null
    /// means "no value yet" and the nodes downstream stay quiet.
    broadcast: []?Val,
    /// Per slot: the converted literal, if the slot is literal-sourced.
    literals: []?Val,
    /// Per node: the resolved write target for `write` nodes.
    node_write: []?WriteRef,
    /// Per node: its slice of the row's user channels.
    node_state: []NodeState,
    channels_used: u8,
    n_sinks: usize,
    /// The literal arrays, converted once at mount and shared by every row.
    literal_arrays: std.ArrayListUnmanaged([]Val) = .empty,
    /// Per node: folded at mount into a literal and skipped by the sweep —
    /// an `array` construction whose every element is a literal. The parser
    /// builds `[1, 0.5, 0]` as a node (§2.10, a live tuple); on the row it
    /// is the first STATELESS array: one value, converted once, shared by
    /// every row, and a live element (`[row.age, 1]`) is refused by name.
    folded: []bool,

    /// Mount, or refuse with the words in `diag`. Every refusal names the
    /// node and what it asked for; the error names the category.
    pub fn mount(gpa: std.mem.Allocator, prog: *const graph.Program, plane: Plane, diag: *registry.Detail) MountError!Runtime {
        var rt = Runtime{
            .gpa = gpa,
            .prog = prog,
            .plane = plane,
            .sub_refs = try gpa.alloc(?FieldRef, prog.subs.items.len),
            .broadcast = try gpa.alloc(?Val, prog.subs.items.len),
            .literals = try gpa.alloc(?Val, prog.slotCount()),
            .node_write = try gpa.alloc(?WriteRef, prog.nodeCount()),
            .node_state = try gpa.alloc(NodeState, prog.nodeCount()),
            .folded = try gpa.alloc(bool, prog.nodeCount()),
            .channels_used = 0,
            .n_sinks = 0,
        };
        errdefer rt.deinit();
        @memset(rt.broadcast, null);
        @memset(rt.literals, null);
        @memset(rt.node_write, null);
        @memset(rt.node_state, .{});
        @memset(rt.folded, false);

        // Array literals fold first, so the legality walk below never sees
        // the `array` node they were parsed as.
        for (prog.nodes.items) |*n| {
            const def = prog.reg.get(n.op);
            if (!std.mem.eql(u8, def.name, "array")) continue;
            try rt.foldArray(n, diag);
        }

        // Every op must have an exact kernel. Refused by name, with the
        // column's own words, before anything else is looked at.
        var channels: u32 = 0;
        for (prog.nodes.items) |*n| {
            if (rt.folded[n.id]) continue;
            const def = prog.reg.get(n.op);
            if (!def.row.legal()) {
                if (def.row.eval == null) {
                    diag.set("{s}: '{s}' is not row-legal — it has no row kernel (rill's row column)", .{ n.name, def.name });
                } else {
                    diag.set("{s}: '{s}' is not row-legal — its kernel is not exact, and v1's row-legal set is the exact set", .{ n.name, def.name });
                }
                return error.NotRowLegal;
            }
            if (n.inputs.len > MAX_IN or n.outputs.len > MAX_OUT) {
                diag.set("{s}: '{s}' has more ports than a row kernel carries ({d} in, {d} out)", .{ n.name, def.name, n.inputs.len, n.outputs.len });
                return error.TooManyPorts;
            }
            if (def.row.channels > 0) {
                const need: u32 = def.row.channels;
                const have: u32 = @intCast(userChannelCount(plane.schema));
                if (channels + need > have) {
                    diag.set("{s}: '{s}' needs {d} user channel(s) and the row has {d}, {d} already spoken for", .{ n.name, def.name, need, have, channels });
                    return error.ChannelsExceeded;
                }
                rt.node_state[n.id] = .{ .off = @intCast(channels), .len = @intCast(need) };
                channels += need;
            }
            // `write` resolves its target now, once: the row field, its axis,
            // and the mode — or the refusal, with the field list. Keyed on the
            // path static, not on `.effect`: a row word that writes the row
            // through its kernel (`gravity`) has no path and no plane effect.
            if (n.statics.len > 0 and n.statics[0] == .path) {
                rt.n_sinks += 1;
                rt.node_write[n.id] = try resolveWrite(plane.schema, n, def, diag);
            }
        }
        rt.channels_used = @intCast(channels);

        // Subscriptions: `row.…` resolves to a field; anything else is a
        // broadcast the host feeds.
        for (prog.subs.items, 0..) |s, i| {
            if (std.mem.startsWith(u8, s.path, "row.")) {
                rt.sub_refs[i] = try resolveField(plane.schema, s.path, diag);
            } else {
                rt.sub_refs[i] = null;
            }
        }

        // Literals convert once, here, at the one boundary where a float may
        // appear: a number floors to Q16.16, a `{x, y, z}` record is a vec3,
        // a boolean is itself. Anything else is refused by name.
        for (prog.slots.items) |*s| {
            switch (s.source) {
                .literal => |bytes| {
                    // An array node's inputs were folded above; their slots
                    // are element literals that no sweep reads.
                    if (rt.folded[s.node] and s.dir == .in) continue;
                    rt.literals[s.id] = convertScalarish(gpa, bytes) orelse {
                        const n = prog.node(s.node);
                        diag.set("{s}: literal on port '{s}' is not a row value — a kernel literal is a number, a {{x, y, z}} record, or a boolean", .{ n.name, s.name });
                        return error.BadLiteral;
                    };
                },
                else => {},
            }
        }
        return rt;
    }

    /// `[a, b, c]` with every element a literal becomes one shared array
    /// value on the node's output and every input it feeds; the node itself
    /// is skipped by the sweep. Homogeneous numbers or vec3s, never empty,
    /// never nested, no booleans — refused at mount by name otherwise.
    fn foldArray(self: *Runtime, n: *const graph.Node, diag: *registry.Detail) MountError!void {
        const prog = self.prog;
        if (n.inputs.len == 0) {
            diag.set("{s}: an array on the row is never empty", .{n.name});
            return error.BadLiteral;
        }
        var items = try self.gpa.alloc(Val, n.inputs.len);
        errdefer self.gpa.free(items);
        for (n.inputs, 0..) |sid, i| {
            const sl = prog.slot(sid);
            const v: Val = switch (sl.source) {
                .literal => |b| convertScalarish(self.gpa, b) orelse {
                    diag.set("{s}: element {d} is not a row value — a kernel literal is a number, a {{x, y, z}} record, or a boolean", .{ n.name, i });
                    return error.BadLiteral;
                },
                // `[{l: 1, a: 0, b: 0}, …]`: the parser builds each record
                // element as a `record` node with literal fields. Fold it
                // too, as a vec3, and skip it in the sweep.
                .wire => |up| try self.foldRecordVec3(prog.slot(up).node, n, i, diag),
                else => {
                    diag.set("{s}: an array on the row is a literal — every element is a number or a {{x, y, z}} record, and element {d} is not", .{ n.name, i });
                    return error.BadLiteral;
                },
            };
            if (v == .boolean) {
                diag.set("{s}: an array on the row holds numbers or vec3s, not booleans", .{n.name});
                return error.BadLiteral;
            }
            if (i > 0 and std.meta.activeTag(items[0]) != std.meta.activeTag(v)) {
                diag.set("{s}: an array on the row is all numbers or all vec3s — element {d} differs", .{ n.name, i });
                return error.BadLiteral;
            }
            items[i] = v;
        }
        try self.literal_arrays.append(self.gpa, items);
        const arr = Val{ .array = items };
        for (n.outputs) |sid| {
            self.literals[sid] = arr;
            for (prog.downstream[sid]) |down| self.literals[down] = arr;
        }
        self.folded[n.id] = true;
    }

    /// A `record` node with literal fields named x, y, z (or l, a, b) is a
    /// vec3 literal; anything else in an array is a live element, refused.
    fn foldRecordVec3(self: *Runtime, node_id: graph.NodeId, array_node: *const graph.Node, elem: usize, diag: *registry.Detail) MountError!Val {
        const prog = self.prog;
        const rn = prog.node(node_id);
        const rdef = prog.reg.get(rn.op);
        if (!std.mem.eql(u8, rdef.name, "record") or rn.inputs.len != 3) {
            diag.set("{s}: an array on the row is a literal — every element is a number or a {{x, y, z}} record, and element {d} is not", .{ array_node.name, elem });
            return error.BadLiteral;
        }
        var out: [3]Fixed = undefined;
        var seen: u8 = 0;
        for (rn.inputs, 0..) |sid, k| {
            const sl = prog.slot(sid);
            const bytes = switch (sl.source) {
                .literal => |b| b,
                else => {
                    diag.set("{s}: element {d} is a record with a live field — an array on the row is a literal", .{ array_node.name, elem });
                    return error.BadLiteral;
                },
            };
            const key = rn.statics[k].word;
            const axis: usize = if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "l")) 0 else if (std.mem.eql(u8, key, "y") or std.mem.eql(u8, key, "a")) 1 else if (std.mem.eql(u8, key, "z") or std.mem.eql(u8, key, "b")) 2 else {
                diag.set("{s}: element {d} names a field '{s}' — a row vec3 is x, y, z or l, a, b", .{ array_node.name, elem, key });
                return error.BadLiteral;
            };
            const f = types.asNumber(bytes) orelse {
                diag.set("{s}: element {d}'s field '{s}' is not a number", .{ array_node.name, elem, key });
                return error.BadLiteral;
            };
            out[axis] = fixedFromF64(f) orelse {
                diag.set("{s}: element {d}'s field '{s}' does not fit Q16.16", .{ array_node.name, elem, key });
                return error.BadLiteral;
            };
            seen |= @as(u8, 1) << @intCast(axis);
        }
        if (seen != 0b111) {
            diag.set("{s}: element {d} names each of x, y, z (or l, a, b) once", .{ array_node.name, elem });
            return error.BadLiteral;
        }
        self.folded[node_id] = true;
        return .{ .vec3 = out };
    }

    pub fn deinit(self: *Runtime) void {
        for (self.literal_arrays.items) |arr| self.gpa.free(arr);
        self.literal_arrays.deinit(self.gpa);
        self.gpa.free(self.folded);
        self.gpa.free(self.sub_refs);
        self.gpa.free(self.broadcast);
        self.gpa.free(self.literals);
        self.gpa.free(self.node_write);
        self.gpa.free(self.node_state);
    }

    /// Is subscription `i` a plane broadcast the host must feed?
    pub fn isBroadcast(self: *const Runtime, i: usize) bool {
        return self.sub_refs[i] == null;
    }

    pub fn setBroadcast(self: *Runtime, i: usize, v: ?Val) void {
        self.broadcast[i] = v;
    }

    /// The write queue holds one write per NODE, not per `write` node: a
    /// row word writes the row through its kernel with no path static
    /// (`gravity`, `spawn`), and a queue sized to the sinks alone refused
    /// every one of them as "too many writes" — while G0 passed on a
    /// population that never moved (spindrift beat 1, ledger). One write per
    /// node per row is the contract; a kernel that wants two writes says
    /// two lines.
    pub fn newScratch(self: *const Runtime, gpa: std.mem.Allocator) !Scratch {
        const slots = try gpa.alloc(?Val, self.prog.slotCount());
        errdefer gpa.free(slots);
        const writes = try gpa.alloc(QueuedWrite, self.prog.nodeCount());
        return .{ .gpa = gpa, .slots = slots, .writes = writes };
    }

    /// Evaluate the whole program once over row `r`. Pure per row: reads the
    /// row and the broadcasts, writes the row at the end. Refusals are
    /// counted in the scratch and the row's sweep continues past them — the
    /// wave dies at that node for this row, and only this row.
    pub fn evalRow(self: *const Runtime, sc: *Scratch, r: u32, dt: Fixed, host: ?*anyopaque) void {
        const prog = self.prog;
        // Seed: literals, then subscriptions (row fields and broadcasts).
        @memcpy(sc.slots, self.literals);
        for (prog.subs.items, 0..) |s, i| {
            const v: ?Val = if (self.sub_refs[i]) |ref| self.readRef(r, ref) else self.broadcast[i];
            for (s.targets.items) |sid| sc.slots[sid] = v;
        }
        sc.n_writes = 0;
        sc.retire = false;

        var in_buf: [MAX_IN]?Val = undefined;
        var out_buf: [MAX_OUT]?Val = undefined;
        var detail = registry.Detail{};

        for (prog.nodes.items) |*n| {
            if (self.folded[n.id]) continue;
            const def = prog.reg.get(n.op);
            // All required inputs must have a value; otherwise this node is
            // quiet for this row (an unbound optional reads as null).
            var ready = true;
            for (n.inputs, 0..) |sid, i| {
                in_buf[i] = sc.slots[sid];
                if (in_buf[i] == null) {
                    const s = prog.slot(sid);
                    if (s.source == .none) continue;
                    if (s.port < def.inputs.len and def.inputs[s.port].optional) continue;
                    ready = false;
                }
            }
            if (!ready) continue;
            for (0..n.outputs.len) |i| out_buf[i] = null;
            const st = self.node_state[n.id];
            detail.clear();
            var ctx = Ctx{
                .in = in_buf[0..n.inputs.len],
                .out = out_buf[0..n.outputs.len],
                .statics = n.statics,
                .state = self.plane.user(r)[st.off .. st.off + st.len],
                .dt = dt,
                .row_index = r,
                .plane = &self.plane,
                .host = host,
                .op = def,
                .detail = &detail,
                .write_ref = self.node_write[n.id],
                .scratch = sc,
            };
            def.row.eval.?(&ctx) catch {
                sc.refusals += 1;
                if (sc.first_node == null) {
                    sc.first_node = n.id;
                    sc.first.set("{s}", .{detail.text()});
                }
                continue;
            };
            for (n.outputs, 0..) |sid, i| {
                const v = out_buf[i] orelse continue;
                sc.slots[sid] = v;
                for (prog.downstream[sid]) |down| sc.slots[down] = v;
            }
        }

        // Writes land after the sweep, in node order.
        for (sc.writes[0..sc.n_writes]) |w| self.applyWrite(r, w);
        if (sc.retire) self.plane.retire(r);
    }

    fn readRef(self: *const Runtime, r: u32, ref: FieldRef) Val {
        const whole = self.plane.read(r, ref.field);
        const axis = ref.axis orelse return whole;
        return switch (whole) {
            .vec3 => |v| .{ .scalar = v[axis] },
            else => whole,
        };
    }

    fn applyWrite(self: *const Runtime, r: u32, w: QueuedWrite) void {
        const cur = self.plane.read(r, w.ref.field);
        var next = cur;
        if (w.ref.axis) |axis| {
            // An axis write composes with the rest of the vector.
            const s: Fixed = switch (w.val) {
                .scalar => |x| x,
                else => return, // refused at eval; cannot reach here with a vec3
            };
            switch (next) {
                .vec3 => |*v| v[axis] = switch (w.mode) {
                    .replace => s,
                    .add => v[axis] +% s,
                },
                else => return,
            }
        } else {
            next = switch (w.mode) {
                .replace => w.val,
                .add => addVal(cur, w.val) orelse return,
            };
        }
        self.plane.write(r, w.ref.field, next);
    }
};

fn addVal(a: Val, b: Val) ?Val {
    return switch (a) {
        .scalar => |x| switch (b) {
            .scalar => |y| .{ .scalar = x +% y },
            else => null,
        },
        .vec3 => |v| switch (b) {
            .vec3 => |w| .{ .vec3 = .{ v[0] +% w[0], v[1] +% w[1], v[2] +% w[2] } },
            .scalar => |y| .{ .vec3 = .{ v[0] +% y, v[1] +% y, v[2] +% y } },
            else => null,
        },
        .boolean, .array => null,
    };
}

fn userChannelCount(schema: Schema) usize {
    var n: usize = 0;
    for (schema) |f| {
        if (f.name.len == 2 and f.name[0] == 'u' and f.name[1] >= '0' and f.name[1] <= '9') n += 1;
    }
    return n;
}

fn findField(schema: Schema, name: []const u8) ?u16 {
    for (schema, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

fn fieldList(schema: Schema, buf: []u8) []const u8 {
    var w = std.io.fixedBufferStream(buf);
    for (schema, 0..) |f, i| {
        if (i > 0) w.writer().writeAll(", ") catch break;
        w.writer().writeAll(f.name) catch break;
    }
    return w.getWritten();
}

/// `row.<field>` or `row.<field>.<x|y|z>`.
fn resolveField(schema: Schema, path: []const u8, diag: *registry.Detail) MountError!FieldRef {
    var list_buf: [256]u8 = undefined;
    const rest = path["row.".len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    const field_name = if (dot) |d| rest[0..d] else rest;
    const field = findField(schema, field_name) orelse {
        diag.set("'{s}' is not a row field — the rows have {s}", .{ path, fieldList(schema, &list_buf) });
        return error.UnknownField;
    };
    if (dot == null) return .{ .field = field };
    const axis_name = rest[dot.? + 1 ..];
    if (schema[field].kind != .vec3) {
        diag.set("'{s}': row.{s} is a number and has no axis", .{ path, field_name });
        return error.BadAxis;
    }
    const axis: u2 = if (std.mem.eql(u8, axis_name, "x")) 0 else if (std.mem.eql(u8, axis_name, "y")) 1 else if (std.mem.eql(u8, axis_name, "z")) 2 else {
        diag.set("'{s}': a vec3 axis is x, y or z", .{path});
        return error.BadAxis;
    };
    return .{ .field = field, .axis = axis };
}

/// A `write` node's target: the path static, and the mode flags exactly as
/// `evalSink` reads them — `replace` bare, `add` for the blind delta, and
/// the lane modes refused because a row has no lanes.
fn resolveWrite(schema: Schema, n: *const graph.Node, def: *const registry.OpDef, diag: *registry.Detail) MountError!WriteRef {
    if (n.statics.len == 0 or n.statics[0] != .path) {
        diag.set("{s}: '{s}' is an effect with no row target — a kernel's only sink is `write row.<field>`", .{ n.name, def.name });
        return error.BadWriteTarget;
    }
    const path = n.statics[0].path;
    if (!std.mem.startsWith(u8, path, "row.")) {
        diag.set("{s}: `write {s}` — a kernel writes rows; the plane is read-only from a spray", .{ n.name, path });
        return error.BadWriteTarget;
    }
    const ref = try resolveField(schema, path, diag);
    if (!schema[ref.field].writable) {
        diag.set("{s}: row.{s} is the spray's — a kernel reads it and never writes it", .{ n.name, schema[ref.field].name });
        return error.ReadOnlyField;
    }
    var mode: WriteMode = .replace;
    if (n.statics.len > 1) {
        const names = [_][]const u8{ "hold", "add", "mul", "stops", "clear" };
        for (names, 1..) |name, i| {
            if (i >= n.statics.len) break;
            if (n.statics[i] != .word or n.statics[i].word.len == 0) continue;
            if (std.mem.eql(u8, name, "add")) {
                mode = .add;
            } else {
                diag.set("{s}: `write … {s}` — a row has no lanes; a kernel writes bare (replace) or `add`", .{ n.name, name });
                return error.BadWriteMode;
            }
        }
    }
    return .{ .ref = ref, .mode = mode };
}

/// Struple → row value. Numbers floor to Q16.16; a record with exactly x, y,
/// z — or l, a, b, the Oklab spelling a colour curve wants — is a vec3; a
/// boolean is itself. Used by hosts for BROADCASTS each tick — the one
/// boundary where a float may appear. An array is not converted here: a
/// host that broadcasts one (a curve the Spray applet edits) converts it
/// with `arrayFromStruple` once when its bytes change, owns the storage,
/// and hands the runtime a `.array` — once per tick per spray at most,
/// never per row, which keeps the row's arrays stateless.
pub fn fromStruple(gpa: std.mem.Allocator, bytes: []const u8) ?Val {
    return convertScalarish(gpa, bytes);
}

/// A struple array of numbers, or of x/y/z (l/a/b) records, as the owned
/// `[]Val` a broadcast may carry. Homogeneous, never empty, never nested,
/// no booleans — the same rules a literal array takes at mount. Null when
/// the bytes are not such an array; the caller frees the slice.
pub fn arrayFromStruple(gpa: std.mem.Allocator, bytes: []const u8) !?[]Val {
    var r = struple.reader(bytes);
    const e = (r.next() catch return null) orelse return null;
    if (e != .array) return null;
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const inner = (struple.view(bytes).containedItems(a) catch return null) orelse return null;
    // `defer`, not `errdefer`: a malformed element returns null part-way,
    // and the list must go with it (the first draft leaked exactly there).
    // `toOwnedSlice` empties the list, so the defer frees nothing on success.
    var items: std.ArrayListUnmanaged(Val) = .empty;
    defer items.deinit(gpa);
    var ir = struple.reader(inner);
    while (ir.nextView() catch return null) |elem| {
        const v = convertScalarish(gpa, elem) orelse return null;
        if (v == .boolean) return null;
        if (items.items.len > 0 and std.meta.activeTag(items.items[0]) != std.meta.activeTag(v)) return null;
        try items.append(gpa, v);
    }
    if (items.items.len == 0) return null;
    return try items.toOwnedSlice(gpa);
}

fn convertScalarish(gpa: std.mem.Allocator, bytes: []const u8) ?Val {
    var r = struple.reader(bytes);
    const e = (r.next() catch return null) orelse return null;
    return switch (e) {
        .int => |i| .{ .scalar = fixedFromInt(i) orelse return null },
        .float64 => |f| .{ .scalar = fixedFromF64(f) orelse return null },
        .float32 => |f| .{ .scalar = fixedFromF64(f) orelse return null },
        .boolean => |b| .{ .boolean = b },
        .map => blk: {
            var arena_impl = std.heap.ArenaAllocator.init(gpa);
            defer arena_impl.deinit();
            const a = arena_impl.allocator();
            const inner = (struple.view(bytes).containedItems(a) catch return null) orelse return null;
            const m = struple.MapView.init(inner);
            var out: [3]Fixed = undefined;
            var seen: u8 = 0;
            var it = m.iterator();
            while (it.next() catch return null) |entry| {
                const key = types.asString(entry.key) orelse return null;
                const axis: usize = if (std.mem.eql(u8, key, "x") or std.mem.eql(u8, key, "l")) 0 else if (std.mem.eql(u8, key, "y") or std.mem.eql(u8, key, "a")) 1 else if (std.mem.eql(u8, key, "z") or std.mem.eql(u8, key, "b")) 2 else return null;
                const f = types.asNumber(entry.value) orelse return null;
                out[axis] = fixedFromF64(f) orelse return null;
                seen |= @as(u8, 1) << @intCast(axis);
            }
            if (seen != 0b111) return null;
            break :blk .{ .vec3 = out };
        },
        else => null,
    };
}

fn fixedFromInt(i: i128) ?Fixed {
    if (i > 32767 or i < -32768) return null;
    return @as(Fixed, @intCast(i)) * ONE;
}

fn fixedFromF64(f: f64) ?Fixed {
    const scaled = @floor(f * @as(f64, @floatFromInt(ONE)));
    if (!std.math.isFinite(scaled) or scaled > std.math.maxInt(Fixed) or scaled < std.math.minInt(Fixed)) return null;
    return @intFromFloat(scaled);
}

// ---------------------------------------------------------------------------
// The exact kernels for the core set. Broadcast follows the plane's rule —
// an elementwise op takes a vec3 where it takes a number — restated for two
// shapes: scalar ⊕ scalar, vec3 ⊕ vec3, and vec3 ⊕ scalar either way round.
// ---------------------------------------------------------------------------

pub const kernels = struct {
    const BinFn = *const fn (ctx: *Ctx, a: Fixed, b: Fixed) Error!Fixed;
    const UnFn = *const fn (ctx: *Ctx, a: Fixed) Error!Fixed;

    fn binary(ctx: *Ctx, f: BinFn) Error!void {
        const a = try ctx.val(0);
        const b = try ctx.val(1);
        ctx.out[0] = switch (a) {
            .scalar => |x| switch (b) {
                .scalar => |y| .{ .scalar = try f(ctx, x, y) },
                .vec3 => |w| .{ .vec3 = .{ try f(ctx, x, w[0]), try f(ctx, x, w[1]), try f(ctx, x, w[2]) } },
                else => return ctx.refuse("{s}: port '{s}' wants a number, got {s}", .{ ctx.op.name, ctx.portName(1), b.kindName() }),
            },
            .vec3 => |v| switch (b) {
                .scalar => |y| .{ .vec3 = .{ try f(ctx, v[0], y), try f(ctx, v[1], y), try f(ctx, v[2], y) } },
                .vec3 => |w| .{ .vec3 = .{ try f(ctx, v[0], w[0]), try f(ctx, v[1], w[1]), try f(ctx, v[2], w[2]) } },
                else => return ctx.refuse("{s}: port '{s}' wants a number, got {s}", .{ ctx.op.name, ctx.portName(1), b.kindName() }),
            },
            else => return ctx.refuse("{s}: port '{s}' wants a number, got {s}", .{ ctx.op.name, ctx.portName(0), a.kindName() }),
        };
    }

    fn unary(ctx: *Ctx, f: UnFn) Error!void {
        const a = try ctx.val(0);
        ctx.out[0] = switch (a) {
            .scalar => |x| .{ .scalar = try f(ctx, x) },
            .vec3 => |v| .{ .vec3 = .{ try f(ctx, v[0]), try f(ctx, v[1]), try f(ctx, v[2]) } },
            else => return ctx.refuse("{s}: port '{s}' wants a number, got {s}", .{ ctx.op.name, ctx.portName(0), a.kindName() }),
        };
    }

    fn checked(ctx: *Ctx, wide: i64) Error!Fixed {
        if (wide > std.math.maxInt(Fixed) or wide < std.math.minInt(Fixed)) {
            return ctx.refuse("{s}: overflow — the result does not fit Q16.16 (±32768)", .{ctx.op.name});
        }
        return @intCast(wide);
    }

    fn fAdd(ctx: *Ctx, a: Fixed, b: Fixed) Error!Fixed {
        return checked(ctx, @as(i64, a) + b);
    }
    fn fSub(ctx: *Ctx, a: Fixed, b: Fixed) Error!Fixed {
        return checked(ctx, @as(i64, a) - b);
    }
    fn fMul(ctx: *Ctx, a: Fixed, b: Fixed) Error!Fixed {
        return checked(ctx, (@as(i64, a) * b) >> FRAC_BITS);
    }
    /// Floored, like `mul`: one rounding rule for the four. Zero refuses —
    /// integers have no ±inf to hand back, and a row whose divisor is zero
    /// is a row whose kernel has a question to answer.
    fn fDiv(ctx: *Ctx, a: Fixed, b: Fixed) Error!Fixed {
        if (b == 0) return ctx.refuse("{s}: division by zero", .{ctx.op.name});
        return checked(ctx, @divFloor(@as(i64, a) << FRAC_BITS, b));
    }
    fn fMin(_: *Ctx, a: Fixed, b: Fixed) Error!Fixed {
        return @min(a, b);
    }
    fn fMax(_: *Ctx, a: Fixed, b: Fixed) Error!Fixed {
        return @max(a, b);
    }
    /// Floored modulo, sign of the divisor — `-90 | mod 360` is 270 here as
    /// on the plane. Exact on the raw representation.
    fn fMod(ctx: *Ctx, a: Fixed, b: Fixed) Error!Fixed {
        if (b == 0) return ctx.refuse("{s}: modulo by zero", .{ctx.op.name});
        return @mod(a, b);
    }
    fn fAbs(ctx: *Ctx, a: Fixed) Error!Fixed {
        if (a == std.math.minInt(Fixed)) return ctx.refuse("{s}: overflow", .{ctx.op.name});
        return @intCast(@abs(a));
    }
    fn fFloor(_: *Ctx, a: Fixed) Error!Fixed {
        return a & ~FRAC_MASK;
    }
    fn fCeil(ctx: *Ctx, a: Fixed) Error!Fixed {
        if (a & FRAC_MASK == 0) return a;
        return checked(ctx, @as(i64, a & ~FRAC_MASK) + ONE);
    }
    fn fRound(ctx: *Ctx, a: Fixed) Error!Fixed {
        return checked(ctx, (@as(i64, a) + HALF) & ~@as(i64, FRAC_MASK));
    }
    fn fSign(_: *Ctx, a: Fixed) Error!Fixed {
        return if (a > 0) ONE else if (a < 0) -ONE else 0;
    }
    fn fFract(_: *Ctx, a: Fixed) Error!Fixed {
        return a & FRAC_MASK;
    }

    pub fn add(ctx: *Ctx) Error!void {
        return binary(ctx, fAdd);
    }
    pub fn sub(ctx: *Ctx) Error!void {
        return binary(ctx, fSub);
    }
    pub fn mulK(ctx: *Ctx) Error!void {
        return binary(ctx, fMul);
    }
    pub fn div(ctx: *Ctx) Error!void {
        return binary(ctx, fDiv);
    }
    pub fn min(ctx: *Ctx) Error!void {
        return binary(ctx, fMin);
    }
    pub fn max(ctx: *Ctx) Error!void {
        return binary(ctx, fMax);
    }
    pub fn mod(ctx: *Ctx) Error!void {
        return binary(ctx, fMod);
    }
    pub fn abs(ctx: *Ctx) Error!void {
        return unary(ctx, fAbs);
    }
    pub fn floor(ctx: *Ctx) Error!void {
        return unary(ctx, fFloor);
    }
    pub fn ceil(ctx: *Ctx) Error!void {
        return unary(ctx, fCeil);
    }
    pub fn round(ctx: *Ctx) Error!void {
        return unary(ctx, fRound);
    }
    pub fn sign(ctx: *Ctx) Error!void {
        return unary(ctx, fSign);
    }
    pub fn fract(ctx: *Ctx) Error!void {
        return unary(ctx, fFract);
    }

    pub fn clamp(ctx: *Ctx) Error!void {
        const x = try ctx.scalar(0);
        const lo = try ctx.scalar(1);
        const hi = try ctx.scalar(2);
        ctx.out[0] = .{ .scalar = @min(@max(x, lo), hi) };
    }

    /// a + (b − a)·t, t piped. a and b may be vec3 (a curve through space).
    pub fn lerp(ctx: *Ctx) Error!void {
        const t = try ctx.scalar(0);
        const a = try ctx.val(1);
        const b = try ctx.val(2);
        ctx.out[0] = try lerpVal(ctx, t, a, b);
    }

    /// Exposed for `over` below, and for any host word that interpolates.
    pub fn lerpVal(ctx: *Ctx, t: Fixed, a: Val, b: Val) Error!Val {
        return switch (a) {
            .scalar => |x| switch (b) {
                .scalar => |y| .{ .scalar = try checked(ctx, @as(i64, x) + mul(y -% x, t)) },
                else => ctx.refuse("{s}: a and b must both be numbers or both be vec3", .{ctx.op.name}),
            },
            .vec3 => |v| switch (b) {
                .vec3 => |w| .{ .vec3 = .{
                    try checked(ctx, @as(i64, v[0]) + mul(w[0] -% v[0], t)),
                    try checked(ctx, @as(i64, v[1]) + mul(w[1] -% v[1], t)),
                    try checked(ctx, @as(i64, v[2]) + mul(w[2] -% v[2], t)),
                } },
                else => ctx.refuse("{s}: a and b must both be numbers or both be vec3", .{ctx.op.name}),
            },
            else => ctx.refuse("{s}: port '{s}' wants a number or a vec3, got {s}", .{ ctx.op.name, ctx.portName(1), a.kindName() }),
        };
    }

    /// 0..1 onto lo..hi, clamping outside it.
    pub fn range(ctx: *Ctx) Error!void {
        const t = @min(@max(try ctx.scalar(0), 0), ONE);
        const lo = try ctx.val(1);
        const hi = try ctx.val(2);
        ctx.out[0] = try lerpVal(ctx, t, lo, hi);
    }

    /// `t | over span [k0, k1, …]` — the curve sampler, and the array
    /// literal's first consumer.
    ///
    /// `range` is the two-knot case with the knots spelled out; this is the
    /// same arithmetic over as many as you like. `row.age | over row.life
    /// [1, 0.7, 0]` is an ember that starts full size, is at 0.7 halfway
    /// through its life and reaches nothing as it dies.
    ///
    /// **A zero span refuses on BOTH evaluators**, which is a deliberate
    /// departure from `div` — the plane's `div` yields ±inf because IEEE
    /// says so, and rows have no inf at all. A sampler that disagreed with
    /// itself across the two evaluators would break the bit-identity
    /// question (G7) for a case nobody meant to write: a curve with no
    /// width to sample across is an authoring mistake, not a value.
    pub fn over(ctx: *Ctx) Error!void {
        const t = try ctx.scalar(0);
        const span = try ctx.scalar(1);
        const xs = try ctx.array(2);
        if (span == 0) return ctx.refuse("{s}: port '{s}' is zero — a curve with no width has nothing to sample across", .{ ctx.op.name, ctx.portName(1) });
        // The clamp is LOAD-BEARING, not a nicety: `sampleCurve` turns `u`
        // into an array index, and a row read one frame past its life gives
        // a negative one. Removing this clamp does not merely return the
        // wrong knot — it panics on the cast, which the clamp gate below
        // catches by feeding it an age of −1.
        const u = @min(@max(try fDiv(ctx, t, span), 0), ONE);
        ctx.out[0] = try sampleCurve(ctx, u, xs);
    }

    /// Sample `xs` at `u` ∈ [0, 1]: knots EVENLY spaced, linear between
    /// them. `u` is assumed clamped — `over` is the only caller and clamps
    /// before the divide's result can leave the interval.
    ///
    /// Exact, which is what earns `over` its place on the row-legal roster:
    /// the segment index is a shift, the position within it is a mask, and
    /// the interpolation is `lerpVal`'s product and sum. No float appears.
    pub fn sampleCurve(ctx: *Ctx, u: Fixed, xs: []const Val) Error!Val {
        // One knot is a constant, not a degenerate segment — `xs.len - 1`
        // below would be a zero-length span and the index arithmetic would
        // have nothing to divide the interval into.
        if (xs.len == 1) return xs[0];
        const segs: i64 = @intCast(xs.len - 1);
        // u ≤ ONE and segs is an array length, so the product cannot leave
        // i64 and cannot go negative.
        const f: i64 = @as(i64, u) * segs;
        const i: usize = @intCast(f >> FRAC_BITS);
        // u == 1 lands exactly on the last knot, where there is no i+1 to
        // interpolate toward. Returning it directly also makes the end of
        // the curve exact rather than a lerp by a zero fraction.
        if (i >= xs.len - 1) return xs[xs.len - 1];
        const frac: Fixed = @intCast(f & FRAC_MASK);
        return lerpVal(ctx, frac, xs[i], xs[i + 1]);
    }

    pub fn select(ctx: *Ctx) Error!void {
        const cond = try ctx.boolean(0);
        ctx.out[0] = if (cond) try ctx.val(1) else try ctx.val(2);
    }

    pub fn andK(ctx: *Ctx) Error!void {
        ctx.out[0] = .{ .boolean = (try ctx.boolean(0)) and (try ctx.boolean(1)) };
    }
    pub fn orK(ctx: *Ctx) Error!void {
        ctx.out[0] = .{ .boolean = (try ctx.boolean(0)) or (try ctx.boolean(1)) };
    }
    pub fn not(ctx: *Ctx) Error!void {
        ctx.out[0] = .{ .boolean = !(try ctx.boolean(0)) };
    }

    pub fn eq(ctx: *Ctx) Error!void {
        ctx.out[0] = .{ .boolean = (try ctx.val(0)).eql(try ctx.val(1)) };
    }
    pub fn ne(ctx: *Ctx) Error!void {
        ctx.out[0] = .{ .boolean = !(try ctx.val(0)).eql(try ctx.val(1)) };
    }
    fn compare(ctx: *Ctx, comptime f: fn (a: Fixed, b: Fixed) bool) Error!void {
        const a = try ctx.scalar(0);
        const b = try ctx.scalar(1);
        ctx.out[0] = .{ .boolean = f(a, b) };
    }
    fn cLt(a: Fixed, b: Fixed) bool {
        return a < b;
    }
    fn cLe(a: Fixed, b: Fixed) bool {
        return a <= b;
    }
    fn cGt(a: Fixed, b: Fixed) bool {
        return a > b;
    }
    fn cGe(a: Fixed, b: Fixed) bool {
        return a >= b;
    }
    pub fn lt(ctx: *Ctx) Error!void {
        return compare(ctx, cLt);
    }
    pub fn le(ctx: *Ctx) Error!void {
        return compare(ctx, cLe);
    }
    pub fn gt(ctx: *Ctx) Error!void {
        return compare(ctx, cGt);
    }
    pub fn ge(ctx: *Ctx) Error!void {
        return compare(ctx, cGe);
    }

    /// `.x` / `.y` / `.z` on a vec3.
    pub fn project(ctx: *Ctx) Error!void {
        const v = try ctx.vec3(0);
        const field = ctx.statics[0].word;
        const axis: usize = if (std.mem.eql(u8, field, "x")) 0 else if (std.mem.eql(u8, field, "y")) 1 else if (std.mem.eql(u8, field, "z")) 2 else {
            return ctx.refuse("{s}: a vec3 has x, y and z — not '{s}'", .{ ctx.op.name, field });
        };
        ctx.out[0] = .{ .scalar = v[axis] };
    }

    /// `{x: …, y: …, z: …}` from live scalars — exactly those three names.
    pub fn record(ctx: *Ctx) Error!void {
        if (ctx.in.len != 3) return ctx.refuse("{s}: a row record is a vec3 — exactly x, y and z", .{ctx.op.name});
        var out: [3]Fixed = undefined;
        var seen: u8 = 0;
        for (0..3) |i| {
            const name = ctx.statics[i].word;
            const axis: usize = if (std.mem.eql(u8, name, "x")) 0 else if (std.mem.eql(u8, name, "y")) 1 else if (std.mem.eql(u8, name, "z")) 2 else {
                return ctx.refuse("{s}: a row record is a vec3 — exactly x, y and z, not '{s}'", .{ ctx.op.name, name });
            };
            out[axis] = try ctx.scalar(i);
            seen |= @as(u8, 1) << @intCast(axis);
        }
        if (seen != 0b111) return ctx.refuse("{s}: a row record names each of x, y and z once", .{ctx.op.name});
        ctx.out[0] = .{ .vec3 = out };
    }

    /// The sink. Piped, the input is the rousing and `value` is what gets
    /// written; on a row every tick is a rousing.
    pub fn write(ctx: *Ctx) Error!void {
        const ref = ctx.write_ref orelse return ctx.refuse("{s}: no row target resolved", .{ctx.op.name});
        const v = ctx.in[1] orelse try ctx.val(0);
        if (v == .array) return ctx.refuse("{s}: a row field is never an array", .{ctx.op.name});
        if (ref.ref.axis != null and v != .scalar) {
            return ctx.refuse("{s}: an axis takes a number", .{ctx.op.name});
        }
        try ctx.write(ref.ref, ref.mode, v);
    }
};

// ---------------------------------------------------------------------------
// Tests: the kernels against exact expectations, and a small row plane.
// ---------------------------------------------------------------------------

const TestRows = struct {
    pos: [4][3]Fixed = .{.{ 0, 0, 0 }} ** 4,
    vel: [4][3]Fixed = .{.{ 0, 0, 0 }} ** 4,
    age: [4]Fixed = .{0} ** 4,
    size: [4]Fixed = .{ONE} ** 4,
    u: [4][4]Fixed = .{.{ 0, 0, 0, 0 }} ** 4,
    retired: [4]bool = .{false} ** 4,

    const schema = [_]Field{
        .{ .name = "pos", .kind = .vec3 },
        .{ .name = "vel", .kind = .vec3 },
        .{ .name = "age", .kind = .scalar, .writable = false },
        .{ .name = "size", .kind = .scalar },
        .{ .name = "u0", .kind = .scalar },
        .{ .name = "u1", .kind = .scalar },
        .{ .name = "u2", .kind = .scalar },
        .{ .name = "u3", .kind = .scalar },
    };

    fn asPlane(self: *TestRows) Plane {
        return .{ .ctx = self, .schema = &schema, .readFn = readThunk, .writeFn = writeThunk, .retireFn = retireThunk, .userFn = userThunk };
    }
    fn readThunk(ctx: *anyopaque, r: u32, field: u16) Val {
        const self: *TestRows = @ptrCast(@alignCast(ctx));
        return switch (field) {
            0 => .{ .vec3 = self.pos[r] },
            1 => .{ .vec3 = self.vel[r] },
            2 => .{ .scalar = self.age[r] },
            3 => .{ .scalar = self.size[r] },
            else => .{ .scalar = self.u[r][field - 4] },
        };
    }
    fn writeThunk(ctx: *anyopaque, r: u32, field: u16, val: Val) void {
        const self: *TestRows = @ptrCast(@alignCast(ctx));
        switch (field) {
            0 => self.pos[r] = val.vec3,
            1 => self.vel[r] = val.vec3,
            2 => self.age[r] = val.scalar,
            3 => self.size[r] = val.scalar,
            else => self.u[r][field - 4] = val.scalar,
        }
    }
    fn retireThunk(ctx: *anyopaque, r: u32) void {
        const self: *TestRows = @ptrCast(@alignCast(ctx));
        self.retired[r] = true;
    }
    fn userThunk(ctx: *anyopaque, r: u32) []Fixed {
        const self: *TestRows = @ptrCast(@alignCast(ctx));
        return &self.u[r];
    }
};

const parser = @import("parser.zig");
const ops = @import("ops.zig");

fn mountText(gpa: std.mem.Allocator, reg: *registry.Registry, rows: *TestRows, src: []const u8, prog_out: *graph.Program, diag: *registry.Detail) !Runtime {
    var pdiag = parser.Diag{};
    prog_out.* = parser.parse(gpa, reg, "k", src, &pdiag) catch |err| {
        std.debug.print("parse: {s}\n", .{pdiag.msg()});
        return err;
    };
    return Runtime.mount(gpa, prog_out, rows.asPlane(), diag) catch |err| {
        std.debug.print("mount: {s}\n", .{diag.text()});
        prog_out.deinit();
        return err;
    };
}

test "row: a kernel reads the row, computes in Q16.16, and writes the row after the sweep" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    rows.vel[1] = .{ ONE, 2 * ONE, 3 * ONE };
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.vel | mul 2 | write row.pos
        \\row.vel.y | add 0.5 | write row.size
        \\row.pos.x | add 1 | write row.pos.x add
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 1, ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc.refusals);
    // pos ← vel × 2, then pos.x += (old pos.x + 1) = 0 + 1: writes see the
    // tick's snapshot, and land in node order.
    try std.testing.expectEqual([3]Fixed{ 2 * ONE + ONE, 4 * ONE, 6 * ONE }, rows.pos[1]);
    try std.testing.expectEqual(2 * ONE + HALF, rows.size[1]);
    // Row 0 was not touched.
    try std.testing.expectEqual([3]Fixed{ 0, 0, 0 }, rows.pos[0]);
}

test "row: reading and writing one field is the integration step, not a cycle — and stays a cycle on the plane" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var pdiag = parser.Diag{};
    var prog = try parser.parse(gpa, &reg, "k", "row.vel | add {x: 0, y: -1, z: 0} | write row.vel", &pdiag);
    prog.deinit();
    // Mutation: drop the `row.` exemption in `findCycle`; this parse refuses.
    try std.testing.expectError(error.Parse, parser.parse(gpa, &reg, "p", "plane.vel | add 1 | write plane.vel", &pdiag));
    try std.testing.expect(std.mem.indexOf(u8, pdiag.msg(), "cycle") != null);
}

test "row: mount refuses by name — a non-row-legal op, an unknown field, a read-only write, a lane mode, a plane write" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    const Case = struct { src: []const u8, err: MountError, words: []const u8 };
    const cases = [_]Case{
        .{ .src = "row.age | window 2s | write row.size", .err = error.NotRowLegal, .words = "'window' is not row-legal" },
        .{ .src = "row.mass | write row.size", .err = error.UnknownField, .words = "'row.mass' is not a row field — the rows have pos, vel, age" },
        .{ .src = "row.size | write row.age", .err = error.ReadOnlyField, .words = "row.age is the spray's" },
        .{ .src = "row.size | write row.size hold", .err = error.BadWriteMode, .words = "a row has no lanes" },
        .{ .src = "row.size | write plane.ui.x", .err = error.BadWriteTarget, .words = "a kernel writes rows" },
        .{ .src = "row.age.x | write row.size", .err = error.BadAxis, .words = "has no axis" },
        .{ .src = "row.pos.w | write row.size", .err = error.BadAxis, .words = "x, y or z" },
        .{ .src = "row.age | > 1 | select \"a\" \"b\" | write row.size", .err = error.BadLiteral, .words = "not a row value" },
    };
    for (cases) |c| {
        var pdiag = parser.Diag{};
        var prog = try parser.parse(gpa, &reg, "k", c.src, &pdiag);
        defer prog.deinit();
        var diag = registry.Detail{};
        try std.testing.expectError(c.err, Runtime.mount(gpa, &prog, rows.asPlane(), &diag));
        if (std.mem.indexOf(u8, diag.text(), c.words) == null) {
            std.debug.print("for '{s}' expected words '{s}', got '{s}'\n", .{ c.src, c.words, diag.text() });
            return error.TestUnexpectedResult;
        }
    }
}

test "row: the exact kernels, against integer expectations" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    rows.size[0] = -ONE - HALF; // -1.5
    rows.vel[0] = .{ 3 * ONE, -ONE, HALF };
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.size | floor | write row.u0
        \\row.size | ceil | write row.u1
        \\row.size | fract | write row.u2
        \\row.size | mod 1 | write row.u3
        \\row.vel | div 2 | write row.pos
        \\row.size | abs | mul row.size | write row.size
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 0, ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc.refusals);
    try std.testing.expectEqual(-2 * ONE, rows.u[0][0]); // floor(-1.5) = -2
    try std.testing.expectEqual(-ONE, rows.u[0][1]); // ceil(-1.5) = -1
    try std.testing.expectEqual(HALF, rows.u[0][2]); // fract(-1.5) = 0.5
    try std.testing.expectEqual(HALF, rows.u[0][3]); // -1.5 mod 1 = 0.5, sign of the divisor
    try std.testing.expectEqual([3]Fixed{ ONE + HALF, -HALF, ONE / 4 }, rows.pos[0]);
    try std.testing.expectEqual(-2 * ONE - ONE / 4, rows.size[0]); // |−1.5| × −1.5 = −2.25
}

test "row: a refusal is per row and counted, and the sweep continues for that row" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    rows.size[0] = 0;
    rows.size[1] = 2 * ONE;
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\1 | div row.size | write row.u0
        \\row.size | add 1 | write row.u1
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 0, ONE, null);
    rt.evalRow(&sc, 1, ONE, null);
    try std.testing.expectEqual(@as(u64, 1), sc.refusals);
    try std.testing.expectEqual(@as(?graph.NodeId, 0), sc.first_node); // div1 is node 0
    try std.testing.expect(std.mem.indexOf(u8, sc.first.text(), "division by zero") != null);
    // Row 0's second flow still ran; row 1's division did.
    try std.testing.expectEqual(ONE, rows.u[0][1]);
    try std.testing.expectEqual(HALF, rows.u[1][0]);
}

test "row: broadcasts are the same value for every row, and no value keeps the flow quiet" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    // The field starts NON-zero, and the write is a replace: silence and a
    // written zero must be distinguishable, or a runtime that reads an
    // absent broadcast as 0 passes this gate (mutation R6 survived the
    // first draft, which used `add` on a zero field — A equalled B).
    rows.vel[0][1] = 5 * ONE;
    rows.vel[2][1] = 5 * ONE;
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\plane.drift.@self.gravity | write row.vel.y
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    try std.testing.expectEqual(@as(usize, 1), prog.subs.items.len);
    try std.testing.expect(rt.isBroadcast(0));
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 0, ONE, null);
    try std.testing.expectEqual(5 * ONE, rows.vel[0][1]); // no value yet: quiet, not zero
    rt.setBroadcast(0, .{ .scalar = -3 * ONE });
    rt.evalRow(&sc, 0, ONE, null);
    rt.evalRow(&sc, 2, ONE, null);
    try std.testing.expectEqual(-3 * ONE, rows.vel[0][1]);
    try std.testing.expectEqual(-3 * ONE, rows.vel[2][1]);
    try std.testing.expectEqual(@as(Fixed, 0), rows.vel[1][1]); // row 1 was never swept
}

test "row: a literal record is a vec3, and select/compare/record/project compose" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    rows.age[0] = 3 * ONE;
    rows.age[1] = ONE;
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.age | > 2 as old
        \\old | select {x: 1, y: 2, z: 3} {x: 0, y: 0, z: 0} | write row.pos
        \\row.pos.z | add 1 as w
        \\{x: w, y: w, z: w} | .y | write row.size
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 0, ONE, null);
    rt.evalRow(&sc, 1, ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc.refusals);
    try std.testing.expectEqual([3]Fixed{ ONE, 2 * ONE, 3 * ONE }, rows.pos[0]);
    try std.testing.expectEqual([3]Fixed{ 0, 0, 0 }, rows.pos[1]);
    // size ← (old pos.z + 1) — the snapshot's pos.z, which was 0.
    try std.testing.expectEqual(ONE, rows.size[0]);
}

test "row: a pipe carries a producer's other outputs to the consumer's like-named open ports — explicit wins, an unnamed port stays unbound" {
    // The rule (spindrift beat 5, ruling 24): `collide | stick` hands the hit
    // point down the pipe and the normal to `stick`'s `normal` port. Before
    // it, no second output of any rill word had a spelling that reached it.
    // Mutation: carried outputs bound by POSITION — `k` lands where `b`
    // should; the sum differs. Mutation: the carry dropped — `twoout | takeb`
    // refuses "port 'b' of 'takeb' is not bound".
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    const stub = struct {
        fn f(_: *registry.EvalCtx) registry.EvalError!registry.Emit {
            return registry.Emit.none;
        }
        fn pair(ctx: *Ctx) Error!void {
            const x = try ctx.scalar(0);
            ctx.out[0] = .{ .scalar = x }; // a — down the pipe
            ctx.out[1] = .{ .scalar = x * 2 }; // b — carried by name
            ctx.out[2] = .{ .scalar = x * 3 }; // k — carried by name, if anyone asks
        }
        fn take(ctx: *Ctx) Error!void {
            const a = try ctx.scalar(0);
            const b = try ctx.scalar(1);
            ctx.out[0] = .{ .scalar = a * 10 + b };
        }
    };
    _ = try reg.register(.{
        .name = "twoout",
        .inputs = &.{.{ .name = "in", .ty = types.Tag.number }},
        .outputs = &.{ .{ .name = "a", .ty = types.Tag.number }, .{ .name = "b", .ty = types.Tag.number }, .{ .name = "k", .ty = types.Tag.number } },
        .help = "stub",
        .routes = .anywhere,
        .row = .{ .exact = true, .eval = stub.pair },
        .eval = stub.f,
    });
    _ = try reg.register(.{
        .name = "takeb",
        .inputs = &.{ .{ .name = "in", .ty = types.Tag.number }, .{ .name = "b", .ty = types.Tag.number } },
        .outputs = &.{.{ .name = "out", .ty = types.Tag.number }},
        .help = "stub",
        .routes = .anywhere,
        .row = .{ .exact = true, .eval = stub.take },
        .eval = stub.f,
    });
    _ = try reg.register(.{
        .name = "takec",
        .inputs = &.{ .{ .name = "in", .ty = types.Tag.number }, .{ .name = "c", .ty = types.Tag.number } },
        .outputs = &.{.{ .name = "out", .ty = types.Tag.number }},
        .help = "stub",
        .routes = .anywhere,
        .row = .{ .exact = true, .eval = stub.take },
        .eval = stub.f,
    });
    var rows = TestRows{};
    rows.size[1] = 7;
    {
        var prog: graph.Program = undefined;
        var diag = registry.Detail{};
        var rt = try mountText(gpa, &reg, &rows,
            \\row.size | twoout | takeb | write row.u0
            \\row.size | twoout | takeb 5 | write row.u1
        , &prog, &diag);
        defer prog.deinit();
        defer rt.deinit();
        var sc = try rt.newScratch(gpa);
        defer sc.deinit();
        rt.evalRow(&sc, 1, ONE, null);
        try std.testing.expectEqual(@as(u64, 0), sc.refusals);
        // u0: a = 7 down the pipe, b = 14 carried by name → 84. Bound by
        // position, k = 21 would land there: 91.
        try std.testing.expectEqual(@as(Fixed, 84), rows.u[1][0]);
        // u1: the explicit 5 wins over the carried b → 70 + 5·ONE.
        try std.testing.expectEqual(@as(Fixed, 70 + 5 * ONE), rows.u[1][1]);
    }
    {
        // A port spelled like none of the producer's outputs is unbound, as
        // it always was — by name, so the author knows which.
        var pdiag = parser.Diag{};
        try std.testing.expectError(error.Parse, parser.parse(gpa, &reg, "k", "row.size | twoout | takec | write row.u0\n", &pdiag));
        try std.testing.expect(std.mem.indexOf(u8, pdiag.msg(), "port 'c' of 'takec' is not bound") != null);
    }
}

test "row: an array literal is the first stateless array on the row — converted once, shared, never written" {
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    // A stub consumer with an array port, the shape `over` takes.
    const stub = struct {
        fn f(_: *registry.EvalCtx) registry.EvalError!registry.Emit {
            return registry.Emit.none;
        }
        fn k(ctx: *Ctx) Error!void {
            const xs = try ctx.array(1);
            ctx.out[0] = xs[xs.len - 1];
        }
    };
    _ = try reg.register(.{
        .name = "lastof",
        .inputs = &.{ .{ .name = "in", .ty = types.Tag.number }, .{ .name = "curve", .ty = types.Tag.array } },
        .outputs = &.{.{ .name = "out", .ty = types.Tag.any }},
        .help = "stub",
        .routes = .anywhere,
        .row = .{ .exact = true, .eval = stub.k },
        .eval = stub.f,
    });
    var rows = TestRows{};
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.age | lastof [1, 0.5, 0.25] | write row.u0
        \\row.age | lastof [{l: 1, a: 0, b: 0}, {x: 0.5, y: 0, z: 0}] | write row.pos
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    try std.testing.expectEqual(@as(usize, 2), rt.literal_arrays.items.len);
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 0, ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc.refusals);
    try std.testing.expectEqual(ONE / 4, rows.u[0][0]);
    try std.testing.expectEqual([3]Fixed{ HALF, 0, 0 }, rows.pos[0]);

    // A mixed array, an empty one, a nested one, a boolean inside: refused at mount by name.
    const bad = [_][]const u8{
        "row.age | lastof [1, {x: 0, y: 0, z: 0}] | write row.u0",
        "row.age | lastof [] | write row.u0",
        "row.age | lastof [[1]] | write row.u0",
        "row.age | lastof [true] | write row.u0",
    };
    for (bad) |src| {
        var pdiag = parser.Diag{};
        var p2 = try parser.parse(gpa, &reg, "k", src, &pdiag);
        defer p2.deinit();
        var d2 = registry.Detail{};
        try std.testing.expectError(error.BadLiteral, Runtime.mount(gpa, &p2, rows.asPlane(), &d2));
    }
    // An array is never a row field.
    var pdiag = parser.Diag{};
    var p3 = try parser.parse(gpa, &reg, "k", "[1, 2] | write row.pos", &pdiag);
    defer p3.deinit();
    var d3 = registry.Detail{};
    var rt3 = try Runtime.mount(gpa, &p3, rows.asPlane(), &d3);
    defer rt3.deinit();
    var sc3 = try rt3.newScratch(gpa);
    defer sc3.deinit();
    rt3.evalRow(&sc3, 1, ONE, null);
    try std.testing.expectEqual(@as(u64, 1), sc3.refusals);
    try std.testing.expect(std.mem.indexOf(u8, sc3.first.text(), "never an array") != null);
    // A broadcast converts an array through its own door, once, host-owned:
    // `fromStruple` says nothing of it, `arrayFromStruple` hands it over.
    var pk = struple.Packer.init(gpa);
    defer pk.deinit();
    var inner = struple.Packer.init(gpa);
    defer inner.deinit();
    try inner.appendInt(1);
    try inner.appendF64(0.5);
    try pk.appendArray(inner.bytes());
    try std.testing.expectEqual(@as(?Val, null), fromStruple(gpa, pk.bytes()));
    const arr = (try arrayFromStruple(gpa, pk.bytes())).?;
    defer gpa.free(arr);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqual(HALF, arr[1].scalar);
    // …and a broadcast slot carrying it reaches a kernel like a literal does.
    var pdiag4 = parser.Diag{};
    var p4 = try parser.parse(gpa, &reg, "k", "row.age | lastof plane.drift.@self.curve | write row.u1", &pdiag4);
    defer p4.deinit();
    var d4 = registry.Detail{};
    var rt4 = try Runtime.mount(gpa, &p4, rows.asPlane(), &d4);
    defer rt4.deinit();
    // `row.age` is subscription 0; the curve is the broadcast — ask, don't assume.
    for (0..p4.subs.items.len) |i| {
        if (rt4.isBroadcast(i)) rt4.setBroadcast(i, .{ .array = arr });
    }
    var sc4 = try rt4.newScratch(gpa);
    defer sc4.deinit();
    rt4.evalRow(&sc4, 2, ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc4.refusals);
    try std.testing.expectEqual(HALF, rows.u[2][1]);
    // A malformed one is null, not a partial array.
    var bad_inner = struple.Packer.init(gpa);
    defer bad_inner.deinit();
    try bad_inner.appendInt(1);
    try bad_inner.appendBool(true);
    var bad_arr = struple.Packer.init(gpa);
    defer bad_arr.deinit();
    try bad_arr.appendArray(bad_inner.bytes());
    try std.testing.expectEqual(@as(?[]Val, null), try arrayFromStruple(gpa, bad_arr.bytes()));
}

test "row: `over` samples a curve of evenly-spaced knots — an ember's size across its life" {
    // The line the spindrift campaign was written around, and the one the
    // `:::curve` editor authors: three knots, evenly spaced over the row's
    // life — born, halfway, gone.
    //
    // Four rows at four ages in one sweep, because a population is exactly
    // that: the same kernel over rows at different points of the same curve.
    //
    // The expectations are EXACT Q16.16, worked by hand rather than read off
    // a run, because "it printed this" is not a check. `fixedFromF64` floors,
    // so the literal 0.7 is 45875 (0.7 × 65536 = 45875.2). At age ¼ the
    // segment is 0 and the position within it is ½, so the answer is
    // 65536 + ((−19661 × 32768) >> 16) = 65536 − 9831 = 55705 — the shift
    // floors toward −∞ on a negative, which is where the odd 1 comes from.
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    for (0..4) |i| rows.u[i][0] = ONE; // u0 is `life`
    rows.age[0] = 0;
    rows.age[1] = ONE / 4;
    rows.age[2] = HALF;
    rows.age[3] = ONE;
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.age | over row.u0 [1, 0.7, 0] | write row.size
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    for (0..4) |i| rt.evalRow(&sc, @intCast(i), ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc.refusals);

    // Both ends land on their knot EXACTLY — no lerp by a zero fraction, no
    // 0.99998 where the author wrote 1. An ember that never quite reaches
    // nothing is a visible bug at the end of every particle's life.
    try std.testing.expectEqual(ONE, rows.size[0]);
    try std.testing.expectEqual(@as(Fixed, 0), rows.size[3]);
    // The middle knot is exact too: with three knots, u = ½ is the knot
    // itself and not a point between two of them.
    try std.testing.expectEqual(@as(Fixed, 45875), rows.size[2]);
    // …and the interpolated one, which is the segment arithmetic itself.
    try std.testing.expectEqual(@as(Fixed, 55705), rows.size[1]);
}

test "row: `over` clamps outside the span, and one knot is a constant" {
    // Same ruling as `range` and `along`: outside the interval, clamp. A
    // particle a frame past its life must read as dead rather than wrap to
    // the top of the curve, and the row runs before the host reaps it.
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    for (0..4) |i| rows.u[i][0] = ONE;
    rows.age[0] = -ONE; // before the start
    rows.age[1] = 2 * ONE; // past the end
    rows.age[2] = HALF;
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.age | over row.u0 [1, 0.7, 0] | write row.size
        \\row.age | over row.u0 [0.25] | write row.u1
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    for (0..3) |i| rt.evalRow(&sc, @intCast(i), ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc.refusals);
    try std.testing.expectEqual(ONE, rows.size[0]); // clamped to the first knot
    try std.testing.expectEqual(@as(Fixed, 0), rows.size[1]); // …and to the last
    // A single knot has no segment to divide the interval into; it is a
    // constant at every age, including the two that clamped.
    try std.testing.expectEqual(ONE / 4, rows.u[0][1]);
    try std.testing.expectEqual(ONE / 4, rows.u[1][1]);
    try std.testing.expectEqual(ONE / 4, rows.u[2][1]);
}

test "row: a record ramp is a colour ramp — `over` interpolates componentwise" {
    // `[white, orange, dark]` in the campaign doc. A knot may be a record,
    // and `lerpVal` already carries vec3, so the curve sampler gets colour
    // for free — this gate is what says so out loud, because a sampler that
    // silently refused records would send the whole idea back to three
    // parallel scalar curves.
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    rows.u[0][0] = ONE;
    rows.age[0] = HALF;
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.age | over row.u0 [{x: 1, y: 0, z: 0}, {x: 0, y: 0, z: 1}] | write row.pos
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 0, ONE, null);
    try std.testing.expectEqual(@as(u64, 0), sc.refusals);
    // Halfway between two knots one segment apart: each axis moves half way.
    try std.testing.expectEqual([3]Fixed{ HALF, 0, HALF }, rows.pos[0]);
}

test "row: `over` refuses a zero span rather than inventing an end to the curve" {
    // A row has no ±inf to divide into, and a curve with no width has no
    // sample point — so this refuses, is COUNTED, and the row's other flow
    // still runs. The plane half refuses the same way on purpose, which is
    // the one place `over` departs from `div`'s IEEE stance: a sampler that
    // disagreed with itself across the two evaluators would be a worse
    // surprise than the departure.
    const gpa = std.testing.allocator;
    var reg = try registry.Registry.init(gpa);
    defer reg.deinit();
    try ops.registerCore(&reg);
    var rows = TestRows{};
    rows.u[0][0] = 0; // life of zero
    rows.age[0] = HALF;
    var prog: graph.Program = undefined;
    var diag = registry.Detail{};
    var rt = try mountText(gpa, &reg, &rows,
        \\row.age | over row.u0 [1, 0] | write row.size
        \\row.age | add 1 | write row.u1
    , &prog, &diag);
    defer prog.deinit();
    defer rt.deinit();
    var sc = try rt.newScratch(gpa);
    defer sc.deinit();
    rt.evalRow(&sc, 0, ONE, null);
    try std.testing.expectEqual(@as(u64, 1), sc.refusals);
    try std.testing.expect(std.mem.indexOf(u8, sc.first.text(), "nothing to sample across") != null);
    // The flow that refused wrote nothing; the sibling flow still ran.
    try std.testing.expectEqual(ONE, rows.size[0]); // untouched default
    try std.testing.expectEqual(ONE + HALF, rows.u[0][1]);
}
