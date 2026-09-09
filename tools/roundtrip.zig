//! rill-roundtrip — parse a `.rill` file, print its script back, and check
//! the two parses are the same program.
//!
//! Why a TOOL and not only a gate. The corpus this beat was measured against
//! lives in the sibling repos — 47 `.rill` files across matryoshka and
//! spindrift — and rill must not depend on either: it is the library they
//! embed, it is public and standalone, and a `b.path("../spindrift/…")` in
//! `build.zig` would make rill unbuildable on its own. Worse, 21 of the 47
//! use HOST words (`spawn`, `near`, `push`, …) that rill core does not have
//! and must not have; embedding them would teach rill what a kernel is, which
//! `tests.zig`'s NORTHSTAR banner already refuses.
//!
//! So the gates live in `src/tests.zig` over programs rill owns — every
//! ```rill fence in the manuals, every rillbook cell, and the fixture set —
//! and the sibling corpus is measured HERE, on demand, by pointing this at
//! it. Same three checks, same oracle, run by a person or an agent:
//!
//!     zig build roundtrip -- ../matryoshka/src/rills/*.rill
//!     zig build roundtrip -- --host-row ../spindrift/kernels/*.rill
//!
//! `--host-row` registers stubs for spindrift's fifteen row words. They live
//! in `tools/host_row.zig` — ONE definition, shared with `rill check
//! --host-row`, because a stub whose arity differs parses the file
//! differently and two copies that drift make the two tools disagree about
//! what a legal program is, silently and in whichever was edited second.
//!
//! The oracle is `Runtime.restore` + `serialize.dump`, not `mount`: restore
//! subscribes and does NOT tick, so the dump is the program's STRUCTURE with
//! no live state and no tick-0 refusal — which is the comparison the printer
//! owes. Two programs whose dumps are byte-identical have the same nodes, the
//! same wires, the same statics and the same order.

const std = @import("std");
const rill = @import("rill");

const host_row = @import("host_row");

fn makeRegistry(gpa: std.mem.Allocator, host: bool) !rill.Registry {
    var reg = try rill.Registry.init(gpa);
    errdefer reg.deinit();
    try rill.registerCore(&reg);
    try rill.registerRbf(&reg);
    if (host) try host_row.register(&reg);
    return reg;
}

/// The structural dump of a parsed program: restore (no tick) and serialize.
fn structure(gpa: std.mem.Allocator, prog: *rill.Program) ![]u8 {
    var mock = rill.MockPlane.init(gpa);
    defer mock.deinit();
    var rt = try rill.Runtime.restore(gpa, prog, mock.asPlane(), .{});
    defer rt.deinit();
    return rill.dump(&rt, gpa);
}

const Outcome = enum { world, kernel, unparsed, drift, unstable, lost_comment };

/// `--emit <dir>` writes both prints side by side, so an instability is one
/// `diff` away rather than a guess.
var emit_dir: ?[]const u8 = null;

fn emit(gpa: std.mem.Allocator, path: []const u8, suffix: []const u8, text: []const u8) !void {
    const dir = emit_dir orelse return;
    const name = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, std.fs.path.basename(path), suffix });
    defer gpa.free(name);
    var f = try std.fs.cwd().createFile(name, .{});
    defer f.close();
    try f.writeAll(text);
}

fn countComments(src: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trimLeft(u8, ln, " \t");
        if (std.mem.startsWith(u8, t, "//")) n += 1;
    }
    return n;
}

fn run(gpa: std.mem.Allocator, path: []const u8, host: bool) !Outcome {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const src = try f.readToEndAlloc(gpa, 8 << 20);
    defer gpa.free(src);

    var reg = try makeRegistry(gpa, host);
    defer reg.deinit();

    var diag = rill.Diag{};
    var kind: Outcome = .world;
    var prog = rill.parse(gpa, &reg, "p", src, &diag) catch blk: {
        var d2 = rill.Diag{};
        kind = .kernel;
        break :blk rill.parseKernel(gpa, &reg, "p", src, &d2) catch {
            std.debug.print("  UNPARSED  {s} — {s} (line {d}, col {d})\n", .{ path, diag.msg(), diag.line, diag.col });
            return .unparsed;
        };
    };
    defer prog.deinit();

    const once = try rill.printScript(gpa, prog.script.?);
    defer gpa.free(once);

    var diag2 = rill.Diag{};
    var prog2 = (if (kind == .kernel)
        rill.parseKernel(gpa, &reg, "p", once, &diag2)
    else
        rill.parse(gpa, &reg, "p", once, &diag2)) catch {
        std.debug.print("  REPARSE   {s} — printed text does not parse: {s} (line {d}, col {d})\n", .{ path, diag2.msg(), diag2.line, diag2.col });
        return .drift;
    };
    defer prog2.deinit();

    // G-roundtrip: same program.
    const a = try structure(gpa, &prog);
    defer gpa.free(a);
    const b = try structure(gpa, &prog2);
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("  DRIFT     {s} — the reprint is a different program\n", .{path});
        return .drift;
    }

    // G-idempotent: same text.
    const twice = try rill.printScript(gpa, prog2.script.?);
    defer gpa.free(twice);
    try emit(gpa, path, ".1", once);
    try emit(gpa, path, ".2", twice);
    if (!std.mem.eql(u8, once, twice)) {
        std.debug.print("  UNSTABLE  {s} — printing twice moved the file\n", .{path});
        return .unstable;
    }

    // G-comments: every `//` line survives.
    const before = countComments(src);
    const after = countComments(once);
    if (before != after) {
        std.debug.print("  COMMENTS  {s} — {d} in, {d} out\n", .{ path, before, after });
        return .lost_comment;
    }
    return kind;
}

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var host = false;
    var want_dir = false;
    var counts = std.EnumArray(Outcome, usize).initFill(0);
    var files: usize = 0;
    for (args[1..]) |arg| {
        if (want_dir) {
            emit_dir = arg;
            want_dir = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--host-row")) {
            host = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--emit")) {
            want_dir = true;
            continue;
        }
        files += 1;
        const out = run(gpa, arg, host) catch |e| {
            std.debug.print("  ERROR     {s} — {s}\n", .{ arg, @errorName(e) });
            continue;
        };
        counts.set(out, counts.get(out) + 1);
    }
    const ok = counts.get(.world) + counts.get(.kernel);
    std.debug.print(
        "\n{d}/{d} round-trip ({d} world, {d} kernel) — unparsed {d}, drift {d}, unstable {d}, comments lost {d}\n",
        .{
            ok,                    files,
            counts.get(.world),    counts.get(.kernel),
            counts.get(.unparsed), counts.get(.drift),
            counts.get(.unstable), counts.get(.lost_comment),
        },
    );
    if (ok != files) std.process.exit(1);
}
