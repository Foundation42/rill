//! rill-run — mount a `.rill` file on the mock plane, feed it a scripted
//! timeline, and print what comes out.
//!
//! Why this exists. `zig build run` runs ONE hardcoded program, so trying a
//! spelling meant editing a string literal and rebuilding, and watching a
//! register converge meant reading eval.zig. Neither is a way to iterate. This
//! takes any file and any input schedule from the command line.
//!
//! What it is not: a host. There is no engine here, so a path is only ever a
//! name — `plane.camera.roll` and `plane.nonsense.wobble` are equally valid to
//! the mock plane, and a typo shows up as a write nobody reads rather than an
//! error. That is the same bargain the real host makes (a mistyped knob path
//! becomes a dynamic path), so what you see here is what a host would see.
//!
//! Usage:
//!   rill-run <file.rill> [options]
//!
//!   --seed <path>=<v>          set a path before mount (repeatable)
//!   --tick <p=v[,p=v...]>      one frame of deltas (repeatable, one per tick)
//!   --ramp <path>=<a>..<b>@<n> append n frames sweeping path from a to b
//!   --ticks <n>                n frames fed nothing, at this point in the script
//!   --dt <ms>                  milliseconds per frame (default 16)
//!   --watch <slot>             print this wire every frame (repeatable)
//!
//! Values: `12` is an int, `1.5` a float, `true`/`false` a bool, anything else
//! a string. Ramps are always floats — a ramp between two integers is still a
//! sweep, and rounding it would hide the very motion you asked to see.

const std = @import("std");
const rill = @import("rill");
const struple = @import("struple");

const MAX_FRAMES = 100_000;

const Feed = struct { path: []const u8, value: Value };

const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,

    fn parse(text: []const u8) Value {
        if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
        // An integer only when it is written as one: `1` and `1.0` are
        // different asks, and a program that types its port `number` will take
        // either while one that wants a count will not.
        if (std.mem.indexOfAny(u8, text, ".eE") == null) {
            if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .int = i } else |_| {}
        }
        if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
        return .{ .string = text };
    }

    fn pack(self: Value, pk: *struple.Packer) !void {
        pk.reset();
        switch (self) {
            .int => |v| try pk.appendInt(v),
            .float => |v| try pk.appendF64(v),
            .boolean => |v| try pk.appendBool(v),
            .string => |v| try pk.appendString(v),
        }
    }

    fn print(self: Value, w: anytype) !void {
        switch (self) {
            .int => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .boolean => |v| try w.print("{}", .{v}),
            .string => |v| try w.print("\"{s}\"", .{v}),
        }
    }
};

var fmt_buf: [256]u8 = undefined;

/// Render a struple-encoded value for the log. Single scalars are the common
/// case and get spelled plainly; anything richer is named by its shape rather
/// than half-decoded, because a half-decoded record reads like a bug.
fn fmtValue(encoded: []const u8) []const u8 {
    var r = struple.reader(encoded);
    const first = (r.next() catch return "?") orelse return "(empty)";
    const more = (r.next() catch null) != null;
    if (more) return std.fmt.bufPrint(&fmt_buf, "[{d} elements]", .{countElems(encoded)}) catch "?";
    return switch (first) {
        .int => |v| std.fmt.bufPrint(&fmt_buf, "{d}", .{v}) catch "?",
        .float64 => |v| std.fmt.bufPrint(&fmt_buf, "{d:.6}", .{v}) catch "?",
        .float32 => |v| std.fmt.bufPrint(&fmt_buf, "{d:.6}", .{v}) catch "?",
        .boolean => |b| if (b) "true" else "false",
        .string => |s| std.fmt.bufPrint(&fmt_buf, "\"{s}\"", .{s}) catch "?",
        .map => "{…}",
        else => "?",
    };
}

fn countElems(encoded: []const u8) usize {
    var r = struple.reader(encoded);
    var n: usize = 0;
    while ((r.next() catch return n) != null) n += 1;
    return n;
}

fn logThunk(_: ?*anyopaque, label: []const u8, val: []const u8) void {
    std.debug.print("     ~ tap {s} = {s}\n", .{ label, fmtValue(val) });
}

/// An operator refusing is the single most useful thing this runner can tell
/// you, and it told you NOTHING until now: the chain simply went dead, with the
/// downstream writes missing and no reason given.
///
/// Found using it (2026-08-26). `select`'s condition port is a boolean and an
/// input control is a NUMBER, so `plane.input.kbd.space | select a b` refuses
/// every tick — and the symptom was a program that mounted cleanly, reported
/// its node count, and quietly wrote nothing. Diagnosing that meant splitting
/// the chain and writing each stage to its own path to find where it stopped,
/// which is exactly the work this tool exists to save.
///
/// `detail` is the operator's own words and `err` is the category; both are
/// printed, because the category alone ("BadValue") does not say which port of
/// which node minded.
fn errorThunk(_: ?*anyopaque, ev: rill.eval.ErrorEvent) void {
    if (ev.detail.len > 0) {
        std.debug.print("     ! {s} ({s}) refused: {s}\n", .{ ev.node, ev.op, ev.detail });
    } else {
        std.debug.print("     ! {s} ({s}) refused: {s}\n", .{ ev.node, ev.op, ev.err });
    }
}

fn usage() void {
    std.debug.print(
        \\rill-run — mount a .rill file on the mock plane and watch it run.
        \\
        \\  rill-run <file.rill> [options]
        \\
        \\  --seed <path>=<v>           set a path before mount (repeatable)
        \\  --tick <p=v[,p=v...]>       one frame of deltas (repeatable)
        \\  --ramp <path>=<a>..<b>@<n>  n frames sweeping path from a to b
        \\  --ticks <n>                 n frames fed nothing, here in the script
        \\  --dt <ms>                   milliseconds per frame (default 16)
        \\  --watch <slot>              print this wire every frame (repeatable)
        \\
        \\Example — watch a 400ms ease chase a step, then settle:
        \\  rill-run tilt.rill --seed plane.in=0 --tick plane.in=1 --ticks 40
        \\
    , .{});
}

pub fn main() !u8 {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        usage();
        return if (args.len < 2) 2 else 0;
    }

    const file_path = args[1];

    var seeds: std.ArrayListUnmanaged(Feed) = .empty;
    defer seeds.deinit(gpa);
    // The timeline: one entry per frame, each a list of deltas fed that frame.
    var frames: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Feed)) = .empty;
    defer {
        for (frames.items) |*f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    var watches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer watches.deinit(gpa);
    var dt_ms: u64 = 16;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--seed") and i + 1 < args.len) {
            i += 1;
            try appendPairs(gpa, &seeds, args[i]);
        } else if (std.mem.eql(u8, a, "--tick") and i + 1 < args.len) {
            i += 1;
            var frame: std.ArrayListUnmanaged(Feed) = .empty;
            try appendPairs(gpa, &frame, args[i]);
            try frames.append(gpa, frame);
        } else if (std.mem.eql(u8, a, "--ramp") and i + 1 < args.len) {
            i += 1;
            appendRamp(gpa, &frames, args[i]) catch {
                std.debug.print("--ramp wants <path>=<from>..<to>@<frames>, got '{s}'\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--ticks") and i + 1 < args.len) {
            i += 1;
            const n = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("--ticks wants a count, got '{s}'\n", .{args[i]});
                return 2;
            };
            // POSITIONAL: n frames fed nothing, right here in the timeline —
            // not n extra frames at the end. It was written the other way first
            // and the difference is invisible in the output: a step, a settle,
            // and a step back all ran back-to-back and looked like a program
            // that reacted instantly. A flag that reads as "wait here" must
            // wait here.
            for (0..n) |_| try frames.append(gpa, .empty);
        } else if (std.mem.eql(u8, a, "--dt") and i + 1 < args.len) {
            i += 1;
            dt_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("--dt wants milliseconds, got '{s}'\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--watch") and i + 1 < args.len) {
            i += 1;
            try watches.append(gpa, args[i]);
        } else {
            std.debug.print("unknown option '{s}'\n\n", .{a});
            usage();
            return 2;
        }
    }

    if (frames.items.len > MAX_FRAMES) {
        std.debug.print("that is {d} frames; the cap is {d}\n", .{ frames.items.len, MAX_FRAMES });
        return 2;
    }

    const source = std.fs.cwd().readFileAlloc(gpa, file_path, 1 << 20) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ file_path, @errorName(err) });
        return 2;
    };
    defer gpa.free(source);

    const name = std.fs.path.stem(file_path);

    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    var mock = rill.MockPlane.init(gpa);
    defer mock.deinit();

    var pk = struple.Packer.init(gpa);
    defer pk.deinit();

    // Seeds land BEFORE mount, which is the only way to exercise what a program
    // sees at tick 0 — `expect` asserts against the value present at mount, and
    // a register baselines on its first target.
    for (seeds.items) |s| {
        try s.value.pack(&pk);
        try mock.put(s.path, pk.bytes());
    }

    var diag = rill.Diag{};
    var prog = rill.parse(gpa, &reg, name, source, &diag) catch |err| {
        std.debug.print("{s}:{d}:{d}: {s}\n", .{ file_path, diag.line, diag.col, diag.msg() });
        std.debug.print("(parse refused: {s})\n", .{@errorName(err)});
        return 1;
    };
    defer prog.deinit();

    var rt = rill.Runtime.mount(gpa, &prog, mock.asPlane(), .{}) catch |err| {
        // A mount refusal is a finding, not a crash: cycles, undeclared
        // channels and self-subscription all land here, and the name is the
        // whole message.
        std.debug.print("mount refused: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer rt.deinit();
    rt.log_fn = logThunk;
    rt.error_fn = errorThunk;

    std.debug.print("mounted '{s}': {d} nodes, {d} slots, {d} subscriptions, {d} writes declared\n", .{
        name, prog.nodeCount(), prog.slotCount(), prog.subs.items.len, prog.writes.items.len,
    });

    var seen = Seen{};
    report(&mock, &seen, 0);
    printWatches(&rt, watches.items);

    const total = frames.items.len;
    var frame_no: usize = 1;
    while (frame_no <= total) : (frame_no += 1) {
        std.debug.print("tick {d}  t={d}ms\n", .{ frame_no, frame_no * dt_ms });
        {
            for (frames.items[frame_no - 1].items) |d| {
                std.debug.print("   -> {s} = ", .{d.path});
                const w = std.io.getStdErr().writer();
                d.value.print(w) catch {};
                std.debug.print("\n", .{});
                try d.value.pack(&pk);
                try rt.feed(.{ .path = d.path, .value = pk.bytes() });
            }
        }
        try rt.tick(.{ .frame = frame_no, .time_ns = frame_no * dt_ms * std.time.ns_per_ms });
        report(&mock, &seen, frame_no);
        printWatches(&rt, watches.items);
    }

    return 0;
}

/// Everything already reported, so each tick prints only what is new. The mock
/// keeps its logs forever; without a high-water mark every tick would reprint
/// the whole history and the interesting line would be the one you scroll past.
const Seen = struct { writes: usize = 0, casts: usize = 0, tags: usize = 0 };

fn report(mock: *rill.MockPlane, seen: *Seen, tick_no: usize) void {
    _ = tick_no;
    var quiet = true;
    for (mock.writes.items[seen.writes..]) |w| {
        quiet = false;
        // Occurrences and values are different things and a reader of this log
        // needs to tell them apart — an occurrence that looks like a value is
        // how a repeated element becomes one write (tier-2 §8's open fork).
        const mark = if (w.kind == .occurrence) "!" else " ";
        std.debug.print("   <-{s}{s} = {s}\n", .{ mark, w.path, fmtValue(w.value) });
    }
    seen.writes = mock.writes.items.len;

    for (mock.casts.items[seen.casts..]) |c| {
        quiet = false;
        std.debug.print("   ~~ cast {s} amp={d} radius={d}\n", .{ c.channel, c.amplitude, c.radius });
    }
    seen.casts = mock.casts.items.len;

    for (mock.tag_writes.items[seen.tags..]) |t| {
        quiet = false;
        std.debug.print("   ## {s} {s} {s}\n", .{ if (t.adding) "tag" else "untag", t.subject, t.tag });
    }
    seen.tags = mock.tag_writes.items.len;

    // Said out loud, because silence is a RESULT here: a suppressed value, a
    // closed gate and a wave that died upstream all look like nothing at all,
    // and "nothing happened" is usually the thing being checked.
    if (quiet) std.debug.print("   (nothing — no write, no cast, no tag)\n", .{});
}

fn printWatches(rt: *rill.Runtime, watches: []const []const u8) void {
    for (watches) |w| {
        if (rt.readSlot(w)) |v| {
            std.debug.print("   ?  {s} = {s}\n", .{ w, fmtValue(v) });
        } else {
            std.debug.print("   ?  {s} = (no such wire)\n", .{w});
        }
    }
}

fn appendPairs(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Feed), spec: []const u8) !void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            std.debug.print("expected <path>=<value>, got '{s}'\n", .{trimmed});
            return error.BadSpec;
        };
        try out.append(gpa, .{
            .path = std.mem.trim(u8, trimmed[0..eq], " \t"),
            .value = Value.parse(std.mem.trim(u8, trimmed[eq + 1 ..], " \t")),
        });
    }
}

/// `<path>=<from>..<to>@<n>` appends n frames. Frames are APPENDED, never
/// merged into what is already scheduled: two ramps run one after the other,
/// not together. Merging would be the more powerful rule and a worse one —
/// which frame a value lands on is the thing you are reading off this log, and
/// it should be countable from the command line without a merge rule in mind.
/// Hold a second input still by seeding it; a written value persists.
fn appendRamp(gpa: std.mem.Allocator, frames: *std.ArrayListUnmanaged(std.ArrayListUnmanaged(Feed)), spec: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadSpec;
    const at = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return error.BadSpec;
    if (at < eq) return error.BadSpec;
    const path = spec[0..eq];
    const range = spec[eq + 1 .. at];
    const dots = std.mem.indexOf(u8, range, "..") orelse return error.BadSpec;
    const from = try std.fmt.parseFloat(f64, range[0..dots]);
    const to = try std.fmt.parseFloat(f64, range[dots + 2 ..]);
    const n = try std.fmt.parseInt(usize, spec[at + 1 ..], 10);
    if (n == 0) return error.BadSpec;

    for (0..n) |k| {
        // The last frame lands ON `to`. A ramp that stops just short of its
        // destination makes every convergence check off by one step, and the
        // step is invisible in the log.
        const u: f64 = if (n == 1) 1.0 else @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
        var frame: std.ArrayListUnmanaged(Feed) = .empty;
        try frame.append(gpa, .{ .path = path, .value = .{ .float = from + (to - from) * u } });
        try frames.append(gpa, frame);
    }
}
