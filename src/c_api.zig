//! c_api — rill behind a C ABI, so it can be a **seam**.
//!
//! Why this exists (2026-08-25). Zig compiles a whole *module* as one unit and
//! has no incremental path through LLVM, so a source-module dependency is
//! recompiled into every consumer on every edit. Measured on Matryoshka: a
//! one-line change cost **406 s** in ReleaseFast — essentially the full cold
//! build — and editing rill invalidated all of it.
//!
//! Three build shapes were measured before this was written:
//!
//!   - a separate `addImport` MODULE  → consumer rebuilds in full (no boundary)
//!   - a static library              → consumer rebuilds in full when the lib changes
//!   - a **shared** library          → rebuild the .so alone, and the EXISTING
//!                                     consumer binary runs the new code
//!
//! Only the third is a real seam, and it needs a C ABI: Zig's own ABI is not
//! guaranteed across separate compilations, so everything that crosses is
//! `callconv(.c)` over opaque handles and byte spans.
//!
//! **This is the iteration shape, not the retail shape.** Consumers keep
//! importing rill as a Zig module for release builds (full inlining, no
//! handles); the seam exists so that a one-line edit costs seconds instead of
//! minutes while working. One source tree, two link shapes.
//!
//! Ownership: every `*_create`/`parse` hands back a handle the caller must
//! release with the matching `*_destroy`. Byte spans handed OUT point into
//! rill-owned memory and are valid until the next call on that handle.

const std = @import("std");
const rill = @import("rill.zig");

// ---------------------------------------------------------------------------
// Handles. Opaque on the far side; a struct with an allocator on this one, so
// the seam owns its own allocations and never hands a Zig allocator across.
// ---------------------------------------------------------------------------

const gpa_impl = struct {
    var state: std.heap.GeneralPurposeAllocator(.{}) = .init;
};

fn gpa() std.mem.Allocator {
    return gpa_impl.state.allocator();
}

pub const Status = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    parse_error = 2,
    bad_handle = 3,
    cycle = 4,
    time_regression = 5,
    plane_error = 6,
    not_found = 7,
};

const RegistryBox = struct { reg: rill.Registry };
const ProgramBox = struct { prog: rill.Program };
const RuntimeBox = struct {
    rt: rill.Runtime,
    plane_impl: PlaneImpl,
};

/// The last diagnostic, per registry — a parse failure's message, line and
/// column, kept on this side so the caller reads it with an accessor instead
/// of receiving a Zig struct.
const Diag = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    line: u32 = 0,
    col: u32 = 0,
};
var last_diag: Diag = .{};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

export fn rill_registry_create() callconv(.c) ?*anyopaque {
    const box = gpa().create(RegistryBox) catch return null;
    box.reg = rill.Registry.init(gpa()) catch {
        gpa().destroy(box);
        return null;
    };
    return @ptrCast(box);
}

export fn rill_registry_destroy(h: ?*anyopaque) callconv(.c) void {
    const box: *RegistryBox = @ptrCast(@alignCast(h orelse return));
    box.reg.deinit();
    gpa().destroy(box);
}

export fn rill_register_core(h: ?*anyopaque) callconv(.c) Status {
    const box: *RegistryBox = @ptrCast(@alignCast(h orelse return .bad_handle));
    rill.registerCore(&box.reg) catch return .out_of_memory;
    return .ok;
}

/// Number of registered operators — the cheapest possible liveness check
/// across the seam, and what the hot-swap demo watches.
export fn rill_registry_op_count(h: ?*anyopaque) callconv(.c) usize {
    const box: *RegistryBox = @ptrCast(@alignCast(h orelse return 0));
    return box.reg.ops.items.len;
}

/// The name of operator `i`, as a pointer+length into registry-owned memory.
export fn rill_registry_op_name(h: ?*anyopaque, i: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const box: *RegistryBox = @ptrCast(@alignCast(h orelse return null));
    if (i >= box.reg.ops.items.len) return null;
    const name = box.reg.ops.items[i].name;
    out_len.* = name.len;
    return name.ptr;
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

export fn rill_parse(
    reg_h: ?*anyopaque,
    name_ptr: [*]const u8,
    name_len: usize,
    src_ptr: [*]const u8,
    src_len: usize,
) callconv(.c) ?*anyopaque {
    const rbox: *RegistryBox = @ptrCast(@alignCast(reg_h orelse return null));
    var diag = rill.Diag{};
    const prog = rill.parse(gpa(), &rbox.reg, name_ptr[0..name_len], src_ptr[0..src_len], &diag) catch {
        const msg = diag.msg();
        last_diag.len = @min(msg.len, last_diag.buf.len);
        @memcpy(last_diag.buf[0..last_diag.len], msg[0..last_diag.len]);
        last_diag.line = diag.line;
        last_diag.col = diag.col;
        return null;
    };
    const box = gpa().create(ProgramBox) catch return null;
    box.prog = prog;
    return @ptrCast(box);
}

export fn rill_program_destroy(h: ?*anyopaque) callconv(.c) void {
    const box: *ProgramBox = @ptrCast(@alignCast(h orelse return));
    box.prog.deinit();
    gpa().destroy(box);
}

export fn rill_program_node_count(h: ?*anyopaque) callconv(.c) usize {
    const box: *ProgramBox = @ptrCast(@alignCast(h orelse return 0));
    return box.prog.nodeCount();
}

export fn rill_last_error(out_len: *usize, out_line: *u32, out_col: *u32) callconv(.c) [*]const u8 {
    out_len.* = last_diag.len;
    out_line.* = last_diag.line;
    out_col.* = last_diag.col;
    return &last_diag.buf;
}

// ---------------------------------------------------------------------------
// Registering a HOST operator through the seam — the other direction.
//
// A consumer (Matryoshka) registers ~141 console verbs as rill operators, each
// with a Zig function pointer for `eval`. Across a C ABI that becomes a C
// callback plus a user pointer, and rill needs a plain fn-pointer to store in
// the OpDef — so one trampoline stands in for all of them and finds the right
// callback from `EvalCtx.op`.
//
// Keyed by NAME, deliberately: `reg.ops` is an ArrayList that reallocates as
// operators register, so any map keyed on an `*OpDef` would dangle the moment
// the table grew. Names are unique (the registry enforces it) and stable.
// ---------------------------------------------------------------------------

pub const CStr = extern struct { ptr: [*]const u8, len: usize };

pub const CPort = extern struct {
    name: [*]const u8,
    name_len: usize,
    ty: u16 = 0,
    /// 0 = value, 1 = occurrence
    kind: u8 = 0,
    optional: bool = false,
    kw: bool = false,
    tail: bool = false,
    tail_all: bool = false,
    /// Closed value set for a string port, checked at parse.
    one_of: ?[*]const CStr = null,
    one_of_len: usize = 0,
};

pub const COpDef = extern struct {
    name: [*]const u8,
    name_len: usize,
    help: [*]const u8,
    help_len: usize,
    /// 0 = pure, 1 = reads, 2 = effect
    class: u8 = 0,
    /// 0 = anywhere, 1 = main
    routes: u8 = 0,
    ticks: bool = false,
    variadic: bool = false,
    inputs: ?[*]const CPort = null,
    inputs_len: usize = 0,
    outputs: ?[*]const CPort = null,
    outputs_len: usize = 0,
};

/// Returns the emit mask (bit i = output port i), or a negative value to
/// refuse — call `rill_ctx_refuse` first so the refusal says why.
pub const CEval = *const fn (ctx: ?*anyopaque, user: ?*anyopaque) callconv(.c) i64;

const HostOp = struct { eval: CEval, user: ?*anyopaque };
var host_ops: std.StringHashMapUnmanaged(HostOp) = .empty;

fn hostTrampoline(ctx: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
    const entry = host_ops.get(ctx.op.name) orelse
        return ctx.refuse("{s}: the seam has no handler registered for this operator", .{ctx.op.name});
    const r = entry.eval(@ptrCast(ctx), entry.user);
    if (r < 0) return error.BadValue; // the callback refused; its reason is already recorded
    return rill.Emit{ .mask = @truncate(@as(u64, @bitCast(r))) };
}

/// Copy a C port array into seam-owned memory. The registry BORROWS port
/// slices from the registrant, so they must outlive the caller's buffers.
fn ownPorts(src: ?[*]const CPort, n: usize) ![]rill.Port {
    const out = try gpa().alloc(rill.Port, n);
    errdefer gpa().free(out);
    if (n == 0) return out;
    const in = src.?;
    for (0..n) |i| {
        const p = in[i];
        var vals: []const []const u8 = &.{};
        if (p.one_of_len > 0) {
            const owned = try gpa().alloc([]const u8, p.one_of_len);
            for (0..p.one_of_len) |j| {
                const cs = p.one_of.?[j];
                owned[j] = try gpa().dupe(u8, cs.ptr[0..cs.len]);
            }
            vals = owned;
        }
        out[i] = .{
            .name = try gpa().dupe(u8, p.name[0..p.name_len]),
            .ty = p.ty,
            .kind = if (p.kind == 1) .occurrence else .value,
            .optional = p.optional,
            .kw = p.kw,
            .tail = p.tail,
            .tail_all = p.tail_all,
            .one_of = vals,
        };
    }
    return out;
}

export fn rill_register_op(reg_h: ?*anyopaque, def: *const COpDef, eval: CEval, user: ?*anyopaque) callconv(.c) Status {
    const rbox: *RegistryBox = @ptrCast(@alignCast(reg_h orelse return .bad_handle));
    const name = gpa().dupe(u8, def.name[0..def.name_len]) catch return .out_of_memory;
    const help = gpa().dupe(u8, def.help[0..def.help_len]) catch return .out_of_memory;
    const inputs = ownPorts(def.inputs, def.inputs_len) catch return .out_of_memory;
    const outputs = ownPorts(def.outputs, def.outputs_len) catch return .out_of_memory;

    host_ops.put(gpa(), name, .{ .eval = eval, .user = user }) catch return .out_of_memory;
    _ = rbox.reg.register(.{
        .name = name,
        .inputs = inputs,
        .outputs = outputs,
        .help = help,
        .class = switch (def.class) {
            2 => .effect,
            1 => .reads,
            else => .pure,
        },
        .routes = if (def.routes == 1) .main else .anywhere,
        .ticks = def.ticks,
        .variadic = def.variadic,
        .eval = hostTrampoline,
    }) catch return .bad_handle;
    return .ok;
}

/// Intern a host type name (`mesh`, `points`) and get its id for a port.
export fn rill_type_intern(reg_h: ?*anyopaque, name: [*]const u8, name_len: usize) callconv(.c) u16 {
    const rbox: *RegistryBox = @ptrCast(@alignCast(reg_h orelse return 0));
    return rbox.reg.types.intern(name[0..name_len]) catch 0;
}

/// -1 when the operator is not registered.
export fn rill_registry_find(reg_h: ?*anyopaque, name: [*]const u8, name_len: usize) callconv(.c) i64 {
    const rbox: *RegistryBox = @ptrCast(@alignCast(reg_h orelse return -1));
    const id = rbox.reg.find(name[0..name_len]) orelse return -1;
    return @intCast(id);
}

/// The routing column, so a host can derive "does this program touch main?"
/// across the seam exactly as it does in-process.
export fn rill_op_routes(reg_h: ?*anyopaque, id: u32) callconv(.c) u8 {
    const rbox: *RegistryBox = @ptrCast(@alignCast(reg_h orelse return 0));
    if (id >= rbox.reg.ops.items.len) return 0;
    return if (rbox.reg.get(id).routes == .main) 1 else 0;
}

/// Which operator each node of a program uses — the other half of the same
/// derivation, without handing the graph across.
export fn rill_program_node_op(prog_h: ?*anyopaque, node: usize) callconv(.c) i64 {
    const pbox: *ProgramBox = @ptrCast(@alignCast(prog_h orelse return -1));
    if (node >= pbox.prog.nodes.items.len) return -1;
    return @intCast(pbox.prog.nodes.items[node].op);
}

// ── what a host operator sees when it runs ──────────────────────────────────
// Matryoshka's thunks use exactly two things — the host pointer and the input
// values — because each converts to its own context immediately. The rest is
// here because an operator that cannot say why it refused is the thing the
// refusals gate exists to forbid.

export fn rill_ctx_host(ctx_h: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return null));
    return ctx.host;
}

export fn rill_ctx_input_count(ctx_h: ?*anyopaque) callconv(.c) usize {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return 0));
    return ctx.in.len;
}

/// Input `i`'s current value, or null when nothing has arrived on it.
export fn rill_ctx_input(ctx_h: ?*anyopaque, i: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return null));
    if (i >= ctx.in.len) return null;
    const v = ctx.in[i] orelse return null;
    out_len.* = v.len;
    return v.ptr;
}

export fn rill_ctx_input_fresh(ctx_h: ?*anyopaque, i: usize) callconv(.c) bool {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return false));
    if (i >= ctx.in_fresh.len) return false;
    return ctx.in_fresh[i];
}

export fn rill_ctx_emit(ctx_h: ?*anyopaque, port: usize, bytes: [*]const u8, len: usize) callconv(.c) Status {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return .bad_handle));
    if (port >= ctx.out.len) return .bad_handle;
    ctx.out[port].appendRaw(bytes[0..len]) catch return .out_of_memory;
    return .ok;
}

export fn rill_ctx_emit_number(ctx_h: ?*anyopaque, port: usize, v: f64) callconv(.c) Status {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return .bad_handle));
    if (port >= ctx.out.len) return .bad_handle;
    ctx.out[port].appendF64(v) catch return .out_of_memory;
    return .ok;
}

/// Record WHY this operator is refusing. The caller then returns a negative
/// emit mask. `@errorName` alone says "BadValue", which names the category and
/// not the fact — and the fact is what a reader needs.
export fn rill_ctx_refuse(ctx_h: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return));
    ctx.detail.set("{s}", .{msg[0..len]});
}

export fn rill_ctx_now_ns(ctx_h: ?*anyopaque) callconv(.c) u64 {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return 0));
    return ctx.now_ns;
}

export fn rill_ctx_now_frame(ctx_h: ?*anyopaque) callconv(.c) u64 {
    const ctx: *rill.EvalCtx = @ptrCast(@alignCast(ctx_h orelse return 0));
    return ctx.now_frame;
}

// ---------------------------------------------------------------------------
// The plane, as C callbacks. The host owns the data; rill borrows it — the
// same contract as the Zig `Plane`, expressed without Zig types.
// ---------------------------------------------------------------------------

pub const CPlane = extern struct {
    ctx: ?*anyopaque,
    subscribe: *const fn (ctx: ?*anyopaque, path: [*]const u8, path_len: usize, sub: u32) callconv(.c) c_int,
    unsubscribe: *const fn (ctx: ?*anyopaque, sub: u32) callconv(.c) void,
    /// Writes the value for `path` through `sink`; returns 0 on success,
    /// non-zero for not-found.
    read: *const fn (ctx: ?*anyopaque, path: [*]const u8, path_len: usize, sink: ?*anyopaque, emit: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void) callconv(.c) c_int,
    write: *const fn (ctx: ?*anyopaque, path: [*]const u8, path_len: usize, val: [*]const u8, val_len: usize, kind: u8) callconv(.c) c_int,
};

const PlaneImpl = struct {
    c: CPlane,

    fn subscribeThunk(ctx: *anyopaque, path: []const u8, sub: rill.plane.SubId) rill.plane.PlaneError!void {
        const self: *PlaneImpl = @ptrCast(@alignCast(ctx));
        if (self.c.subscribe(self.c.ctx, path.ptr, path.len, @intCast(sub)) != 0) return error.Denied;
    }
    fn unsubscribeThunk(ctx: *anyopaque, sub: rill.plane.SubId) void {
        const self: *PlaneImpl = @ptrCast(@alignCast(ctx));
        self.c.unsubscribe(self.c.ctx, @intCast(sub));
    }
    fn emitThunk(sink: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
        const pk: *@import("struple").Packer = @ptrCast(@alignCast(sink.?));
        pk.appendRaw(ptr[0..len]) catch {};
    }
    fn readThunk(ctx: *anyopaque, path: []const u8, out: *@import("struple").Packer) rill.plane.PlaneError!void {
        const self: *PlaneImpl = @ptrCast(@alignCast(ctx));
        if (self.c.read(self.c.ctx, path.ptr, path.len, out, emitThunk) != 0) return error.NotFound;
    }
    fn writeThunk(ctx: *anyopaque, path: []const u8, val: []const u8, kind: rill.DeltaKind) rill.plane.PlaneError!void {
        const self: *PlaneImpl = @ptrCast(@alignCast(ctx));
        if (self.c.write(self.c.ctx, path.ptr, path.len, val.ptr, val.len, @intFromEnum(kind)) != 0) return error.Denied;
    }

    fn asPlane(self: *PlaneImpl) rill.Plane {
        return .{
            .ctx = self,
            .subscribeFn = subscribeThunk,
            .unsubscribeFn = unsubscribeThunk,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

export fn rill_mount(prog_h: ?*anyopaque, cplane: *const CPlane, now_ns: u64, frame: u64) callconv(.c) ?*anyopaque {
    return rill_mount_with_host(prog_h, cplane, now_ns, frame, null);
}

/// Mount with the opaque host world every registered operator will see as
/// `rill_ctx_host` — Matryoshka's `CmdHost`, in practice.
export fn rill_mount_with_host(prog_h: ?*anyopaque, cplane: *const CPlane, now_ns: u64, frame: u64, host: ?*anyopaque) callconv(.c) ?*anyopaque {
    const pbox: *ProgramBox = @ptrCast(@alignCast(prog_h orelse return null));
    const box = gpa().create(RuntimeBox) catch return null;
    box.plane_impl = .{ .c = cplane.* };
    box.rt = rill.Runtime.mount(gpa(), &pbox.prog, box.plane_impl.asPlane(), .{
        .now = .{ .time_ns = now_ns, .frame = frame },
        .host_ctx = host,
    }) catch {
        gpa().destroy(box);
        return null;
    };
    return @ptrCast(box);
}

export fn rill_runtime_destroy(h: ?*anyopaque) callconv(.c) void {
    const box: *RuntimeBox = @ptrCast(@alignCast(h orelse return));
    box.rt.deinit();
    gpa().destroy(box);
}

export fn rill_feed(h: ?*anyopaque, path: [*]const u8, path_len: usize, val: [*]const u8, val_len: usize, kind: u8) callconv(.c) Status {
    const box: *RuntimeBox = @ptrCast(@alignCast(h orelse return .bad_handle));
    box.rt.feed(.{
        .path = path[0..path_len],
        .value = val[0..val_len],
        .kind = @enumFromInt(kind),
    }) catch return .plane_error;
    return .ok;
}

export fn rill_tick(h: ?*anyopaque, now_ns: u64, frame: u64) callconv(.c) Status {
    const box: *RuntimeBox = @ptrCast(@alignCast(h orelse return .bad_handle));
    box.rt.tick(.{ .time_ns = now_ns, .frame = frame }) catch |err| return switch (err) {
        error.TimeRegression => .time_regression,
        error.OutOfMemory => .out_of_memory,
        else => .plane_error,
    };
    return .ok;
}

/// Read a live wire by its published slot path. Points into runtime-owned
/// memory, valid until the next tick.
export fn rill_read_slot(h: ?*anyopaque, path: [*]const u8, path_len: usize, out_len: *usize) callconv(.c) ?[*]const u8 {
    const box: *RuntimeBox = @ptrCast(@alignCast(h orelse return null));
    const v = box.rt.readSlot(path[0..path_len]) orelse return null;
    out_len.* = v.len;
    return v.ptr;
}

/// A slot's value decoded as a number — the common case, and it saves the
/// consumer from having to link a struple decoder just to read a knob.
/// Returns false when the slot is absent or is not a number.
export fn rill_read_slot_number(h: ?*anyopaque, path: [*]const u8, path_len: usize, out: *f64) callconv(.c) bool {
    const box: *RuntimeBox = @ptrCast(@alignCast(h orelse return false));
    const v = box.rt.readSlot(path[0..path_len]) orelse return false;
    out.* = rill.types.asNumber(v) orelse return false;
    return true;
}

/// The seam's own version marker. The hot-swap demo prints this to prove the
/// running binary picked up a REBUILT library without being relinked.
export fn rill_abi_version() callconv(.c) u32 {
    return 1;
}
