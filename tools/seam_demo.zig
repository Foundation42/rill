//! seam_demo — a consumer of rill's C-ABI seam, and the proof that the seam
//! is a real compilation boundary.
//!
//! It links `librill_seam.so` and never imports rill as a Zig module. Run it,
//! change rill's core, run `zig build seam` (which rebuilds ONLY the shared
//! library), and run THIS SAME BINARY again: it reports the new behaviour
//! without having been recompiled or relinked.
//!
//! That is the whole point. A Zig source-module dependency is recompiled into
//! every consumer on every edit — measured at 406 s for a one-line change in
//! Matryoshka's ReleaseFast build. A shared seam costs the library alone.

const std = @import("std");

// ── the seam's C ABI ────────────────────────────────────────────────────────
extern fn rill_abi_version() u32;
extern fn rill_registry_create() ?*anyopaque;
extern fn rill_registry_destroy(h: ?*anyopaque) void;
extern fn rill_register_core(h: ?*anyopaque) c_int;
extern fn rill_registry_op_count(h: ?*anyopaque) usize;
extern fn rill_parse(reg: ?*anyopaque, name: [*]const u8, name_len: usize, src: [*]const u8, src_len: usize) ?*anyopaque;
extern fn rill_program_destroy(h: ?*anyopaque) void;
extern fn rill_program_node_count(h: ?*anyopaque) usize;
extern fn rill_last_error(out_len: *usize, line: *u32, col: *u32) [*]const u8;
extern fn rill_mount(prog: ?*anyopaque, plane: *const CPlane, now_ns: u64, frame: u64) ?*anyopaque;
extern fn rill_runtime_destroy(h: ?*anyopaque) void;
extern fn rill_tick(h: ?*anyopaque, now_ns: u64, frame: u64) c_int;
extern fn rill_read_slot(h: ?*anyopaque, path: [*]const u8, path_len: usize, out_len: *usize) ?[*]const u8;
extern fn rill_read_slot_number(h: ?*anyopaque, path: [*]const u8, path_len: usize, out: *f64) bool;

const CStr = extern struct { ptr: [*]const u8, len: usize };
const CPort = extern struct {
    name: [*]const u8,
    name_len: usize,
    ty: u16 = 0,
    kind: u8 = 0,
    optional: bool = false,
    kw: bool = false,
    tail: bool = false,
    tail_all: bool = false,
    one_of: ?[*]const CStr = null,
    one_of_len: usize = 0,
};
const COpDef = extern struct {
    name: [*]const u8,
    name_len: usize,
    help: [*]const u8,
    help_len: usize,
    class: u8 = 0,
    routes: u8 = 0,
    ticks: bool = false,
    variadic: bool = false,
    inputs: ?[*]const CPort = null,
    inputs_len: usize = 0,
    outputs: ?[*]const CPort = null,
    outputs_len: usize = 0,
};
extern fn rill_register_op(reg: ?*anyopaque, def: *const COpDef, eval: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) i64, user: ?*anyopaque) c_int;
extern fn rill_mount_with_host(prog: ?*anyopaque, plane: *const CPlane, now_ns: u64, frame: u64, host: ?*anyopaque) ?*anyopaque;
extern fn rill_ctx_host(ctx: ?*anyopaque) ?*anyopaque;
extern fn rill_ctx_input(ctx: ?*anyopaque, i: usize, out_len: *usize) ?[*]const u8;
extern fn rill_ctx_input_count(ctx: ?*anyopaque) usize;

const CErrorEvent = extern struct {
    node: [*]const u8, node_len: usize,
    op: [*]const u8, op_len: usize,
    err: [*]const u8, err_len: usize,
    detail: [*]const u8, detail_len: usize,
    frame: u64, time_ns: u64, input_digest: u64,
};
const CHooks = extern struct {
    ctx: ?*anyopaque = null,
    log: ?*const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize) callconv(.c) void = null,
    err: ?*const fn (?*anyopaque, *const CErrorEvent) callconv(.c) void = null,
    publish: ?*const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize) callconv(.c) void = null,
};
extern fn rill_mount_full(prog: ?*anyopaque, plane: *const CPlane, hooks: ?*const CHooks, now_ns: u64, frame: u64, host: ?*anyopaque) ?*anyopaque;

const CPlane = extern struct {
    ctx: ?*anyopaque,
    subscribe: *const fn (?*anyopaque, [*]const u8, usize, u32) callconv(.c) c_int,
    unsubscribe: *const fn (?*anyopaque, u32) callconv(.c) void,
    read: *const fn (?*anyopaque, [*]const u8, usize, ?*anyopaque, *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void) callconv(.c) c_int,
    write: *const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize, u8) callconv(.c) c_int,
};

// ── a minimal host plane: writes are printed, reads find nothing ────────────
var writes: usize = 0;

fn subscribe(_: ?*anyopaque, _: [*]const u8, _: usize, _: u32) callconv(.c) c_int {
    return 0;
}
fn unsubscribe(_: ?*anyopaque, _: u32) callconv(.c) void {}
fn read(_: ?*anyopaque, _: [*]const u8, _: usize, _: ?*anyopaque, _: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void) callconv(.c) c_int {
    return 1; // NotFound — this demo drives everything from `lfo`, not the plane
}
fn write(_: ?*anyopaque, path: [*]const u8, path_len: usize, val: [*]const u8, val_len: usize, _: u8) callconv(.c) c_int {
    _ = val;
    writes += 1;
    if (writes <= 3) {
        std.debug.print("    write -> {s} ({d} bytes)\n", .{ path[0..path_len], val_len });
    }
    return 0;
}

// A host operator, living entirely on THIS side of the seam. rill parses a
// program that names it, mounts it, and calls back in here — which is the
// direction Matryoshka needs for its ~141 console verbs.
const HostWorld = struct { fired: usize = 0, last: f64 = 0 };
var world = HostWorld{};

fn lampEval(ctx: ?*anyopaque, user: ?*anyopaque) callconv(.c) i64 {
    _ = user;
    const w: *HostWorld = @ptrCast(@alignCast(rill_ctx_host(ctx).?));
    w.fired += 1;
    var len: usize = 0;
    if (rill_ctx_input(ctx, 0, &len)) |_| {
        // The value arrived; a real host would decode it. Counting is enough
        // to prove the callback ran with the host world in hand.
        w.last = @floatFromInt(len);
    }
    return 0; // Emit.none — a console verb is an effect, it emits nothing
}

pub fn main() !void {
    std.debug.print("seam abi version : {d}\n", .{rill_abi_version()});

    const reg = rill_registry_create() orelse return error.NoRegistry;
    defer rill_registry_destroy(reg);
    if (rill_register_core(reg) != 0) return error.RegisterFailed;
    // The number the hot-swap demo watches: add an operator to rill's core and
    // this changes, in a binary that was never rebuilt.
    std.debug.print("core operators   : {d}\n", .{rill_registry_op_count(reg)});

    // Register a HOST operator across the seam, then use it in a program.
    var lamp_ports = [_]CPort{.{ .name = "level", .name_len = 5, .ty = 1 }};
    const lamp = COpDef{
        .name = "lamp set",
        .name_len = 8,
        .help = "demo host verb",
        .help_len = 14,
        .class = 2, // effect
        .routes = 1, // main
        .inputs = &lamp_ports,
        .inputs_len = 1,
    };
    if (rill_register_op(reg, &lamp, lampEval, null) != 0) return error.RegisterOpFailed;
    std.debug.print("after host op    : {d} operators\n", .{rill_registry_op_count(reg)});

    const src = "lfo sine 4s | range 0.5 1.5 | also { lamp set } | set plane.render.grade.exposure";
    const prog = rill_parse(reg, "demo", 4, src.ptr, src.len) orelse {
        var n: usize = 0;
        var line: u32 = 0;
        var col: u32 = 0;
        const msg = rill_last_error(&n, &line, &col);
        std.debug.print("parse failed     : {s} (line {d}, col {d})\n", .{ msg[0..n], line, col });
        return error.ParseFailed;
    };
    defer rill_program_destroy(prog);
    std.debug.print("program nodes    : {d}\n", .{rill_program_node_count(prog)});

    var plane = CPlane{
        .ctx = null,
        .subscribe = subscribe,
        .unsubscribe = unsubscribe,
        .read = read,
        .write = write,
    };
    const rt = rill_mount_with_host(prog, &plane, 0, 0, &world) orelse return error.MountFailed;
    defer rill_runtime_destroy(rt);

    // A full breath: four seconds of a 4s sine, a quarter-second at a time.
    const slot = "programs.demo.range1.out.out";
    var i: u64 = 1;
    while (i <= 16) : (i += 1) {
        if (rill_tick(rt, i * 250_000_000, i) != 0) return error.TickFailed;
    }
    var exposure: f64 = 0;
    if (rill_read_slot_number(rt, slot.ptr, slot.len, &exposure)) {
        std.debug.print("exposure         : {d:.6}  (after one full breath)\n", .{exposure});
    }
    // …and at the peak of the breath, which is the number the hot-swap changes.
    _ = rill_tick(rt, 18 * 250_000_000, 18);
    if (rill_read_slot_number(rt, slot.ptr, slot.len, &exposure)) {
        std.debug.print("exposure at peak : {d:.6}\n", .{exposure});
    }
    std.debug.print("plane writes     : {d}\n", .{writes});
    std.debug.print("host op fired    : {d} times (called back across the seam)\n", .{world.fired});

    // …and the refusal REASON crosses too. `@errorName` would say "BadValue";
    // what a reader needs is which operator refused and why.
    try refusalCrossesTheSeam(reg, &plane);
}

var refusal_seen: bool = false;

fn onError(_: ?*anyopaque, ev: *const CErrorEvent) callconv(.c) void {
    refusal_seen = true;
    std.debug.print("refusal          : {s}\n", .{ev.detail[0..ev.detail_len]});
    std.debug.print("  on node        : {s} (op '{s}', {s})\n", .{
        ev.node[0..ev.node_len], ev.op[0..ev.op_len], ev.err[0..ev.err_len],
    });
}

/// Two records with different field sets under `add` — beat 1b's mismatch
/// check — driven through the seam so the message crosses a C ABI intact.
fn refusalCrossesTheSeam(reg: ?*anyopaque, plane: *const CPlane) !void {
    const src = "{x: 1, y: 2, z: 3} | add {x: 1, y: 2} | set plane.out";
    const prog = rill_parse(reg, "bad", 3, src.ptr, src.len) orelse return error.ParseFailed;
    defer rill_program_destroy(prog);
    var hooks = CHooks{ .err = onError };
    const rt = rill_mount_full(prog, plane, &hooks, 0, 0, null) orelse return error.MountFailed;
    defer rill_runtime_destroy(rt);
    if (!refusal_seen) std.debug.print("refusal          : (none — expected one)\n", .{});
}
