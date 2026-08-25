//! rill-demo — a HUD rill mounted on the mock plane.
//!
//! Runs the spec's motivating example end-to-end with no engine: a record of
//! player vitals, a healthbar written back to the plane, a heartbeat gate on
//! low health, and an underwater grade select. Feeds a scripted delta
//! sequence and narrates what propagates each tick — including what *doesn't*
//! (suppression and closed gates are the point).

const std = @import("std");
const rill = @import("rill");
const struple = @import("struple");

const program_src =
    \\// player vitals, live as one record
    \\plane.player.{health, stamina} as vitals
    \\
    \\// healthbar: clamp, normalise, write back
    \\vitals.health | clamp 0 100 | div 100 | set plane.ui.healthbar
    \\
    \\// heartbeat: an occurrence when health crosses below 20
    \\plane.player.health | dropped_below 20 | tap heartbeat | set plane.audio.heartbeat
    \\
    \\// grade: hard select on the underwater flag
    \\select plane.player.underwater 1 0 | set plane.grade.underwater
;

fn logThunk(_: ?*anyopaque, label: []const u8, val: []const u8) void {
    std.debug.print("      ~ tap {s}: {s}\n", .{ label, fmtValue(val) });
}

var fmt_buf: [128]u8 = undefined;

fn fmtValue(encoded: []const u8) []const u8 {
    var r = struple.reader(encoded);
    const elem = (r.next() catch return "?") orelse return "(empty)";
    return switch (elem) {
        .int => |v| std.fmt.bufPrint(&fmt_buf, "{d}", .{v}) catch "?",
        .float64 => |v| std.fmt.bufPrint(&fmt_buf, "{d}", .{v}) catch "?",
        .boolean => |b| if (b) "true" else "false",
        .string => |s| std.fmt.bufPrint(&fmt_buf, "\"{s}\"", .{s}) catch "?",
        .map => "{…}",
        else => "?",
    };
}

test "the demo program still parses" {
    // `zig build test` does not build this executable, and building it does not
    // PARSE this string — only running it did, so `as stats` sat broken here
    // from the moment the temporal quarter made `stats` an operator until Chris
    // ran the demo. The shadow ban was right both times; the gap was that
    // nothing checked the one program the repo ships as its front door.
    const gpa = std.testing.allocator;
    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = rill.parse(gpa, &reg, "hud", program_src, &diag) catch |err| {
        std.debug.print("demo program no longer parses (line {d}, col {d}): {s}\n", .{ diag.line, diag.col, diag.msg() });
        return err;
    };
    defer prog.deinit();
    try std.testing.expect(prog.nodeCount() > 0);
}

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    var mock = rill.MockPlane.init(gpa);
    defer mock.deinit();
    try mock.putValue("plane.player.health", @as(i64, 80));
    try mock.putValue("plane.player.stamina", @as(i64, 60));
    try mock.putValue("plane.player.underwater", false);

    var diag = rill.Diag{};
    var prog = rill.parse(gpa, &reg, "hud", program_src, &diag) catch |err| {
        std.debug.print("parse error (line {d}, col {d}): {s}\n", .{ diag.line, diag.col, diag.msg() });
        return err;
    };
    defer prog.deinit();

    std.debug.print("mounted 'hud': {d} nodes, {d} slots, {d} subscriptions\n\n", .{
        prog.nodeCount(), prog.slotCount(), prog.subs.items.len,
    });

    var rt = try rill.Runtime.mount(gpa, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    rt.log_fn = logThunk;

    var writes_seen: usize = 0;
    writes_seen = report(&mock, writes_seen, 0);

    const Feed = struct { path: []const u8, value: i64 };
    const script = [_][]const Feed{
        &.{ .{ .path = "plane.player.health", .value = 40 }, .{ .path = "plane.player.stamina", .value = 55 } },
        &.{.{ .path = "plane.player.health", .value = 40 }}, // same bytes: silence
        &.{.{ .path = "plane.player.health", .value = 12 }}, // crosses 20: heartbeat
        &.{.{ .path = "plane.player.health", .value = 95 }},
    };

    var pk = struple.Packer.init(gpa);
    defer pk.deinit();
    for (script, 1..) |deltas, tick_no| {
        std.debug.print("tick {d}:\n", .{tick_no});
        for (deltas) |d| {
            std.debug.print("   -> feed {s} = {d}\n", .{ d.path, d.value });
            pk.reset();
            try pk.appendInt(d.value);
            try rt.feed(.{ .path = d.path, .value = pk.bytes() });
        }
        try rt.tick(.{ .frame = tick_no, .time_ns = tick_no * std.time.ns_per_ms * 16 });
        writes_seen = report(&mock, writes_seen, tick_no);
    }

    std.debug.print("\nwatchable wire, read by path:\n", .{});
    const watch = "programs.hud.div1.out.out";
    std.debug.print("   {s} = {s}\n", .{ watch, fmtValue(rt.readSlot(watch).?) });

    const bytes = try rill.dump(&rt, gpa);
    defer gpa.free(bytes);
    std.debug.print("\nwhole program serialized to one struple: {d} bytes\n", .{bytes.len});
}

fn report(mock: *rill.MockPlane, from: usize, tick_no: usize) usize {
    const writes = mock.writes.items;
    if (writes.len == from) {
        std.debug.print("   (tick {d}: no plane writes — waves died upstream)\n", .{tick_no});
    }
    for (writes[from..]) |w| {
        std.debug.print("   <- plane.write {s} = {s}\n", .{ w.path, fmtValue(w.value) });
    }
    return writes.len;
}
