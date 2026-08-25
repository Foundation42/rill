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

pub fn main() !void {
    std.debug.print("seam abi version : {d}\n", .{rill_abi_version()});

    const reg = rill_registry_create() orelse return error.NoRegistry;
    defer rill_registry_destroy(reg);
    if (rill_register_core(reg) != 0) return error.RegisterFailed;
    // The number the hot-swap demo watches: add an operator to rill's core and
    // this changes, in a binary that was never rebuilt.
    std.debug.print("core operators   : {d}\n", .{rill_registry_op_count(reg)});

    const src = "lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure";
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
    const rt = rill_mount(prog, &plane, 0, 0) orelse return error.MountFailed;
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
}
