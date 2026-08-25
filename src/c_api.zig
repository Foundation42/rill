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
    const pbox: *ProgramBox = @ptrCast(@alignCast(prog_h orelse return null));
    const box = gpa().create(RuntimeBox) catch return null;
    box.plane_impl = .{ .c = cplane.* };
    box.rt = rill.Runtime.mount(gpa(), &pbox.prog, box.plane_impl.asPlane(), .{
        .now = .{ .time_ns = now_ns, .frame = frame },
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
