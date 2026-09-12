//! tests — the acceptance gates (§8), pre-registered in the spec before any
//! code existed. G9 (no-leak) is implicit: everything runs under
//! std.testing.allocator, which fails the test on a leak.

const std = @import("std");
const testing = std.testing;
const struple = @import("struple");
const rill = @import("rill.zig");

const types = rill.types;
const registry = rill.registry;
const graph = rill.graph;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A throwaway mesh-flavoured eval: emits an i64 counter so chains propagate.
fn stubEval(ctx: *rill.EvalCtx) registry.EvalError!registry.Emit {
    try ctx.out[0].appendInt(1);
    return registry.Emit.first;
}

/// Echoes the tail port (always the last input) so tests can read exactly
/// what the parser captured; "<none>" marks an absent optional tail.
fn echoTailEval(ctx: *rill.EvalCtx) registry.EvalError!registry.Emit {
    if (ctx.in[ctx.in.len - 1]) |v| {
        ctx.out[0].appendRaw(v) catch return error.BadValue;
    } else {
        ctx.out[0].appendString("<none>") catch return error.OutOfMemory;
    }
    return registry.Emit.first;
}

/// Registry with the core set plus a few console-shaped host verbs.
fn hostRegistry(gpa: std.mem.Allocator) !rill.Registry {
    var reg = try rill.Registry.init(gpa);
    errdefer reg.deinit();
    try rill.registerCore(&reg);
    // The RBF pack rides into every fixture, which puts its two words under
    // every exhaustive audit in this file — routing, ticks, class, the help
    // formatter, the row column, the driver synthesizer. A pack that skipped
    // those would be a second class of operator, and there is only one.
    try rill.registerRbf(&reg);
    const mesh = try reg.types.intern("mesh");
    const host = struct {
        var ports_cube = [_]registry.Port{.{ .name = "size", .ty = types.Tag.number }};
        var ports_mesh_num: [2]registry.Port = undefined;
        var ports_mesh_mesh: [2]registry.Port = undefined;
        var out_mesh: [1]registry.Port = undefined;
        // tail-shaped console verbs (§3.11)
        var ports_tail = [_]registry.Port{.{ .name = "locator", .ty = types.Tag.string, .tail = true }};
        var ports_gain_tail = [_]registry.Port{ .{ .name = "gain", .ty = types.Tag.number }, .{ .name = "locator", .ty = types.Tag.string, .tail = true } };
        var ports_tail_opt = [_]registry.Port{.{ .name = "text", .ty = types.Tag.string, .tail = true, .optional = true }};
        var statics_emitter = [_]registry.StaticDecl{.{ .name = "name", .kind = .word }};
        var out_str = [_]registry.Port{.{ .name = "out", .ty = types.Tag.string }};
        // console-shaped string/enum ports (word coercion + one_of, D5)
        var mode_vals = [_][]const u8{ "ambient", "loop", "once", "shot" };
        var ports_vol_set = [_]registry.Port{
            .{ .name = "name", .ty = types.Tag.string },
            .{ .name = "inner", .ty = types.Tag.number },
            .{ .name = "falloff", .ty = types.Tag.number },
            .{ .name = "weight", .ty = types.Tag.number },
        };
        var ports_emitter_mode: [2]registry.Port = undefined;
    };
    host.ports_emitter_mode = .{
        .{ .name = "name", .ty = types.Tag.string },
        .{ .name = "mode", .ty = types.Tag.string, .one_of = &host.mode_vals },
    };
    host.out_mesh = .{.{ .name = "out", .ty = mesh }};
    host.ports_mesh_num = .{ .{ .name = "m", .ty = mesh }, .{ .name = "amount", .ty = types.Tag.number } };
    host.ports_mesh_mesh = .{ .{ .name = "a", .ty = mesh }, .{ .name = "b", .ty = mesh } };
    _ = try reg.register(.{ .name = "cube", .inputs = &host.ports_cube, .outputs = &host.out_mesh, .help = "stub", .routes = .anywhere, .eval = stubEval });
    _ = try reg.register(.{ .name = "bevel", .inputs = &host.ports_mesh_num, .outputs = &host.out_mesh, .help = "stub", .routes = .anywhere, .eval = stubEval });
    _ = try reg.register(.{ .name = "rot", .inputs = &host.ports_mesh_num, .outputs = &host.out_mesh, .help = "stub", .routes = .anywhere, .eval = stubEval });
    _ = try reg.register(.{ .name = "shell", .inputs = &host.ports_mesh_num, .outputs = &host.out_mesh, .help = "stub", .routes = .anywhere, .eval = stubEval });
    _ = try reg.register(.{ .name = "boolean subtract", .inputs = &host.ports_mesh_mesh, .outputs = &host.out_mesh, .help = "stub", .routes = .anywhere, .eval = stubEval });
    _ = try reg.register(.{ .name = "sound play", .inputs = &host.ports_tail, .outputs = &host.out_str, .help = "stub", .routes = .anywhere, .eval = echoTailEval });
    _ = try reg.register(.{ .name = "emitter drop", .inputs = &host.ports_gain_tail, .statics = &host.statics_emitter, .outputs = &host.out_str, .help = "stub", .routes = .anywhere, .eval = echoTailEval });
    _ = try reg.register(.{ .name = "say", .inputs = &host.ports_tail_opt, .outputs = &host.out_str, .help = "stub", .routes = .anywhere, .eval = echoTailEval });
    _ = try reg.register(.{ .name = "volume set", .inputs = &host.ports_vol_set, .outputs = &host.out_str, .help = "stub", .class = .effect, .routes = .anywhere, .eval = stubEval });
    _ = try reg.register(.{ .name = "emitter mode", .inputs = &host.ports_emitter_mode, .outputs = &host.out_str, .help = "stub", .class = .effect, .routes = .anywhere, .eval = stubEval });
    return reg;
}

fn nodeIdOf(prog: *const rill.Program, name: []const u8) ?graph.NodeId {
    for (prog.nodes.items) |*n| {
        if (std.mem.eql(u8, n.name, name)) return n.id;
    }
    return null;
}

fn packOne(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var p = struple.Packer.init(gpa);
    defer p.deinit();
    try p.append(value);
    return p.toOwnedSlice();
}

fn feedValue(rt: *rill.Runtime, gpa: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const enc = try packOne(gpa, value);
    defer gpa.free(enc);
    try rt.feed(.{ .path = path, .value = enc });
}

/// Feed an array of whole numbers. `packOne` dispatches on struple's scalar
/// `append`, which is scalars only; the containers go through `appendArray`
/// like every other array literal in the language.
fn feedInts(rt: *rill.Runtime, gpa: std.mem.Allocator, path: []const u8, values: []const i64) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var inner = struple.Packer.init(a);
    for (values) |v| try inner.appendInt(v);
    var outer = struple.Packer.init(a);
    try outer.appendArray(inner.bytes());
    try rt.feed(.{ .path = path, .value = outer.bytes() });
}

/// A duration on the wire is `[lane, count]` and nothing else (§2.2), so a
/// path can carry one — which is what makes `adsr`'s release live, and what
/// the "next segment, never the one in flight" pin needs to be gated at all.
fn feedDuration(rt: *rill.Runtime, gpa: std.mem.Allocator, path: []const u8, d: types.Duration) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var p = struple.Packer.init(arena_state.allocator());
    try types.appendDuration(&p, arena_state.allocator(), d);
    try rt.feed(.{ .path = path, .value = p.bytes() });
}

/// Feed an OCCURRENCE — the kind that always propagates, identical bytes and
/// all. A trigger pulled twice is two pulls.
fn feedOcc(rt: *rill.Runtime, gpa: std.mem.Allocator, path: []const u8) !void {
    const enc = try packOne(gpa, true);
    defer gpa.free(enc);
    try rt.feed(.{ .path = path, .value = enc, .kind = .occurrence });
}

const Fixture = struct {
    reg: rill.Registry,
    mock: rill.MockPlane,
    prog: rill.Program,
    rt: rill.Runtime,

    fn deinit(self: *Fixture) void {
        self.rt.deinit();
        self.prog.deinit();
        self.mock.deinit();
        self.reg.deinit();
    }
};

/// Parse + mount `source` over a mock plane pre-seeded by `seed`. Constructs
/// in place: the Runtime keeps pointers into `fx`, so `fx` must already sit
/// at its final address.
fn mountFixture(gpa: std.mem.Allocator, fx: *Fixture, source: []const u8, seed: anytype) !void {
    fx.reg = try hostRegistry(gpa);
    errdefer fx.reg.deinit();
    fx.mock = rill.MockPlane.init(gpa);
    errdefer fx.mock.deinit();
    inline for (seed) |kv| try fx.mock.putValue(kv[0], kv[1]);
    var diag = rill.Diag{};
    fx.prog = rill.parse(gpa, &fx.reg, "p", source, &diag) catch |err| {
        if (err == error.Parse) std.debug.print("parse: {s} (line {d}, col {d})\n", .{ diag.msg(), diag.line, diag.col });
        return err;
    };
    errdefer fx.prog.deinit();
    fx.rt = try rill.Runtime.mount(gpa, &fx.prog, fx.mock.asPlane(), .{});
}

/// Parse `src`, print it back, and compare BYTE for byte — whitespace is
/// exactly the half `expectRoundTrip`'s three checks are blind to.
fn expectPrinted(reg: *rill.Registry, src: []const u8, want: []const u8) !void {
    var diag = rill.Diag{};
    var prog = rill.parse(testing.allocator, reg, "p", src, &diag) catch |err| {
        if (err == error.Parse) std.debug.print("source does not parse — {s} (line {d}, col {d})\n{s}\n", .{ diag.msg(), diag.line, diag.col, src });
        return err;
    };
    defer prog.deinit();
    const out = try rill.printScript(testing.allocator, prog.script.?);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(want, out);
}

/// The same, plus the fixed point: printing what was printed must not move
/// it. A canon that reflowed a file once per save would be worse than the
/// long lines it replaced, and every R3 gate asserts it rather than one of
/// them asserting it for all.
fn expectPrintedStable(reg: *rill.Registry, src: []const u8, want: []const u8) !void {
    try expectPrinted(reg, src, want);
    try expectPrinted(reg, want, want);
}

fn expectParseError(source: []const u8, needle: []const u8) !void {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    const result = rill.parse(testing.allocator, &reg, "p", source, &diag);
    try testing.expectError(error.Parse, result);
    if (std.mem.indexOf(u8, diag.msg(), needle) == null) {
        std.debug.print("diagnostic \"{s}\" does not mention \"{s}\"\n", .{ diag.msg(), needle });
        return error.TestUnexpectedResult;
    }
}

/// Same, plus WHERE the caret lands. Only worth asserting where the position
/// is itself the claim — which, since `using`, it is: a refusal on spliced
/// tokens must point at the splice the author wrote, not at the `using` line
/// the tokens were captured from.
fn expectParseErrorAt(source: []const u8, needle: []const u8, line: u32, col: u32) !void {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    const result = rill.parse(testing.allocator, &reg, "p", source, &diag);
    try testing.expectError(error.Parse, result);
    if (std.mem.indexOf(u8, diag.msg(), needle) == null) {
        std.debug.print("diagnostic \"{s}\" does not mention \"{s}\"\n", .{ diag.msg(), needle });
        return error.TestUnexpectedResult;
    }
    if (diag.line != line or diag.col != col) {
        std.debug.print("diagnostic \"{s}\" landed at {d}:{d}, wanted {d}:{d}\n", .{ diag.msg(), diag.line, diag.col, line, col });
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// G1 — compatibility *shape*: console-shaped one-liners parse to a chain and
// bind as dispatched today, table-driven over stub verbs. The substantive G1
// receipt — the real 85-row Cmd inventory through a seeded registry — lands
// with Matryoshka adoption (build order step 7), not here.
// ---------------------------------------------------------------------------

test "G1: one-liners parse to single chains with literal bindings" {
    const cases = [_]struct {
        src: []const u8,
        nodes: []const []const u8, // expected node names, in id order
    }{
        .{ .src = "cube 2", .nodes = &.{"cube1"} },
        .{ .src = "cube 2 | bevel 0.1", .nodes = &.{ "cube1", "bevel1" } },
        .{ .src = "cube 2 | bevel 0.1 | rot 45", .nodes = &.{ "cube1", "bevel1", "rot1" } },
        .{ .src = "cube 2 | bevel amount: 0.1", .nodes = &.{ "cube1", "bevel1" } },
    };
    for (cases) |case| {
        var reg = try hostRegistry(testing.allocator);
        defer reg.deinit();
        var diag = rill.Diag{};
        var prog = try rill.parse(testing.allocator, &reg, "p", case.src, &diag);
        defer prog.deinit();
        try testing.expectEqual(case.nodes.len, prog.nodeCount());
        for (case.nodes, 0..) |expected, i| {
            try testing.expectEqualStrings(expected, prog.node(@intCast(i)).name);
        }
        // each pipe stage feeds the next node's primary port
        for (1..case.nodes.len) |i| {
            const n = prog.node(@intCast(i));
            const first_in = prog.slot(n.inputs[0]);
            const upstream = prog.node(@intCast(i - 1));
            try testing.expectEqual(upstream.outputs[0], first_in.source.wire);
        }
    }
}

test "G1: fan-out via as, fan-in via names, two-word host verbs" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = rill.parse(testing.allocator, &reg, "p",
        \\cube 2 | bevel 0.1 as base
        \\base | shell 0.05 | rot 45 as lid
        \\boolean subtract base lid
    , &diag) catch |err| {
        std.debug.print("parse: {s}\n", .{diag.msg()});
        return err;
    };
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 5), prog.nodeCount());
    const sub_id = nodeIdOf(&prog, "boolean subtract1").?;
    const sub = prog.node(sub_id);
    const a_src = prog.slot(sub.inputs[0]).source.wire;
    const b_src = prog.slot(sub.inputs[1]).source.wire;
    try testing.expectEqual(prog.node(nodeIdOf(&prog, "bevel1").?).outputs[0], a_src);
    try testing.expectEqual(prog.node(nodeIdOf(&prog, "rot1").?).outputs[0], b_src);
}

test "G1: wire-time type check rejects mesh → number with a pointed message" {
    try expectParseError("cube 2 | add 3", "expected number, got mesh");
}

// ---------------------------------------------------------------------------
// G2 — determinism: same delta feed ⇒ bit-identical dumps, every tick.
// ---------------------------------------------------------------------------

const g2_source =
    \\plane.player.{health, stamina} as vitals
    \\vitals.health | clamp 0 100 | div 100 | write plane.ui.healthbar
    \\select plane.player.underwater 1 0 | mul 0.5 as tint
    \\plane.player.health | dropped_below 20 | tap low
;

fn g2Run(gpa: std.mem.Allocator, dumps: *std.ArrayListUnmanaged([]u8)) !void {
    var fx: Fixture = undefined;
    try mountFixture(gpa, &fx, g2_source, .{
        .{ "plane.player.health", @as(i64, 80) },
        .{ "plane.player.stamina", @as(i64, 50) },
        .{ "plane.player.underwater", false },
    });
    defer fx.deinit();
    const feeds = [_]struct { []const u8, i64 }{
        .{ "plane.player.health", 40 },
        .{ "plane.player.stamina", 45 },
        .{ "plane.player.health", 15 },
        .{ "plane.player.health", 15 },
        .{ "plane.player.health", 90 },
    };
    for (feeds) |f| {
        try feedValue(&fx.rt, gpa, f[0], f[1]);
        try fx.rt.tick(.{});
        try dumps.append(gpa, try rill.dump(&fx.rt, gpa));
    }
}

test "G2: two runs over the same feed produce bit-identical dumps per tick" {
    var dumps_a = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (dumps_a.items) |d| testing.allocator.free(d);
        dumps_a.deinit(testing.allocator);
    }
    var dumps_b = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (dumps_b.items) |d| testing.allocator.free(d);
        dumps_b.deinit(testing.allocator);
    }
    try g2Run(testing.allocator, &dumps_a);
    try g2Run(testing.allocator, &dumps_b);
    try testing.expectEqual(dumps_a.items.len, dumps_b.items.len);
    for (dumps_a.items, dumps_b.items) |da, db| {
        try testing.expectEqualSlices(u8, da, db);
    }
}

// ---------------------------------------------------------------------------
// G3 — coalescing: at most one value per path per tick; a record downstream
// of two changed fields evaluates once.
// ---------------------------------------------------------------------------

test "G3: two writes to one path in a tick evaluate downstream once, with the last value" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hp | add 0 | write plane.out
    , .{});
    defer fx.deinit();
    const add_id = nodeIdOf(&fx.prog, "add1").?;
    const before = fx.rt.eval_count[add_id];
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 10));
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 30));
    try fx.rt.tick(.{});
    try testing.expectEqual(before + 1, fx.rt.eval_count[add_id]);
    // the flushed write carries the coalesced (last) value: 30 + 0 = 30.0
    const last = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    try testing.expectEqual(@as(f64, 30.0), types.asNumber(last.value).?);
}

test "G3: health+stamina in one tick ⇒ the record evaluates once" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.player.{health, stamina} as vitals
    , .{ .{ "plane.player.health", @as(i64, 100) }, .{ "plane.player.stamina", @as(i64, 100) } });
    defer fx.deinit();
    const rec_id = nodeIdOf(&fx.prog, "record1").?;
    const before = fx.rt.eval_count[rec_id];
    try feedValue(&fx.rt, testing.allocator, "plane.player.health", @as(i64, 55));
    try feedValue(&fx.rt, testing.allocator, "plane.player.stamina", @as(i64, 66));
    try fx.rt.tick(.{});
    try testing.expectEqual(before + 1, fx.rt.eval_count[rec_id]);
}

// ---------------------------------------------------------------------------
// G4 — suppression: a same-bytes value write does not propagate; an
// occurrence with an identical payload does.
// ---------------------------------------------------------------------------

test "G4: value 20→20 is silence" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hp | add 0 as h
    , .{.{ "plane.hp", @as(i64, 20) }});
    defer fx.deinit();
    const add_id = nodeIdOf(&fx.prog, "add1").?;
    const before = fx.rt.eval_count[add_id];
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 20));
    try fx.rt.tick(.{});
    try testing.expectEqual(before, fx.rt.eval_count[add_id]);
}

test "G4: occurrences with identical payloads both propagate" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.b | edge | tap fired
    , .{.{ "plane.b", false }});
    defer fx.deinit();
    const tap_id = nodeIdOf(&fx.prog, "tap1").?;
    const before = fx.rt.eval_count[tap_id];
    const wave = [_]bool{ true, false, true };
    for (wave) |v| {
        try feedValue(&fx.rt, testing.allocator, "plane.b", v);
        try fx.rt.tick(.{});
    }
    // two rising edges → two identical `true` occurrences → tap ran twice
    try testing.expectEqual(before + 2, fx.rt.eval_count[tap_id]);
}

// ---------------------------------------------------------------------------
// G5 — gates: `where` false lets nothing downstream evaluate; `partition`
// routes every input to exactly one side.
// ---------------------------------------------------------------------------

test "G5: where false ⇒ downstream never evaluates" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.n | where (< 0) | tap neg
    , .{.{ "plane.n", @as(i64, 5) }});
    defer fx.deinit();
    const tap_id = nodeIdOf(&fx.prog, "tap1").?;
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, 7));
    try fx.rt.tick(.{});
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, 9));
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(u64, 0), fx.rt.eval_count[tap_id]);
    // and the gate opens when the predicate holds
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, -3));
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(u64, 1), fx.rt.eval_count[tap_id]);
}

test "G5: partition routes every input to exactly one side" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hp as hp
        \\partition (< 20) hp as low, ok
        \\low | tap l
        \\ok | tap o
    , .{.{ "plane.hp", @as(i64, 50) }});
    defer fx.deinit();
    const tap_low = nodeIdOf(&fx.prog, "tap1").?;
    const tap_ok = nodeIdOf(&fx.prog, "tap2").?;
    const feeds = [_]i64{ 15, 25, 10, 90, 3 }; // 3 low, 2 ok (+1 ok at mount)
    for (feeds) |v| {
        try feedValue(&fx.rt, testing.allocator, "plane.hp", v);
        try fx.rt.tick(.{});
    }
    const total_inputs: u64 = feeds.len + 1; // + the mount-time value (50 → ok)
    try testing.expectEqual(@as(u64, 3), fx.rt.eval_count[tap_low]);
    try testing.expectEqual(total_inputs - 3, fx.rt.eval_count[tap_ok]);
}

// ---------------------------------------------------------------------------
// G6 — cycles: the read-your-own-write program is rejected at parse with the
// loop named.
// ---------------------------------------------------------------------------

test "G6: read-your-own-write is rejected with the loop named" {
    try expectParseError("plane.x | add 1 | write plane.x", "cycle");
    // segment-prefix overlap counts too, either direction
    try expectParseError("plane.a.b | add 1 | write plane.a", "cycle");
    try expectParseError("plane.a | add 1 | write plane.a.b", "cycle");
}

// ---------------------------------------------------------------------------
// G7 — def flattening: internal knob paths are settable from outside, and
// the override round-trips through serialize / mount.
// ---------------------------------------------------------------------------

test "G7: def internals are addressable, overridable, and the override survives serialize" {
    const src =
        \\def scaled(x: number) =
        \\  x | mul 2 as doubled
        \\  doubled | add 100
        \\
        \\plane.v | scaled | write plane.out
    ;
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, src, .{.{ "plane.v", @as(i64, 10) }});
    defer fx.deinit();
    // mount: 10 * 2 + 100 = 120
    const w0 = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    try testing.expectEqual(@as(f64, 120.0), types.asNumber(w0.value).?);

    // the def's internal literal is an addressable knob under the instance
    const knob = "programs.p.scaled1.mul1.in.b";
    const three = try packOne(testing.allocator, @as(i64, 3));
    defer testing.allocator.free(three);
    try fx.rt.setInput(knob, three);
    try fx.rt.tick(.{});
    const w1 = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    try testing.expectEqual(@as(f64, 130.0), types.asNumber(w1.value).?);

    // the override round-trips through serialize → restore
    const bytes = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(bytes);
    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, bytes);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.restoreState(&rt2, bytes);
    try testing.expectEqual(@as(f64, 3.0), types.asNumber(rt2.readSlot(knob).?).?);

    // and the restored graph keeps computing with the override
    try feedValue(&rt2, testing.allocator, "plane.v", @as(i64, 20));
    try rt2.tick(.{});
    const w2 = mock2.writes.items[mock2.writes.items.len - 1];
    try testing.expectEqual(@as(f64, 160.0), types.asNumber(w2.value).?);
}

// ---------------------------------------------------------------------------
// G8 — serialization: mount → dump → unmount → mount-from-dump → dump is
// byte-identical.
// ---------------------------------------------------------------------------

test "G8: dump → load → dump is byte-identical" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, g2_source, .{
        .{ "plane.player.health", @as(i64, 80) },
        .{ "plane.player.stamina", @as(i64, 50) },
        .{ "plane.player.underwater", true },
    });
    defer fx.deinit();
    try feedValue(&fx.rt, testing.allocator, "plane.player.health", @as(i64, 30));
    try fx.rt.tick(.{});

    const dump1 = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(dump1);

    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, dump1);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.restoreState(&rt2, dump1);

    const dump2 = try rill.dump(&rt2, testing.allocator);
    defer testing.allocator.free(dump2);
    try testing.expectEqualSlices(u8, dump1, dump2);
}

// ---------------------------------------------------------------------------
// Semantics beyond the gates: mount liveness, projection, def isolation.
// ---------------------------------------------------------------------------

test "mount runs tick 0: the program is live before the first delta" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hp | clamp 0 100 | div 100 | write plane.ui.bar
    , .{.{ "plane.hp", @as(i64, 250) }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 1), fx.mock.writes.items.len);
    try testing.expectEqual(@as(f64, 1.0), types.asNumber(fx.mock.writes.items[0].value).?);
}

test "records: projection follows field changes; wire slots are watchable" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.player.{health, mana} as vitals
        \\vitals.mana | add 0 as m
    , .{ .{ "plane.player.health", @as(i64, 100) }, .{ "plane.player.mana", @as(i64, 30) } });
    defer fx.deinit();
    const add_out = "programs.p.add1.out.out";
    try testing.expectEqual(@as(f64, 30.0), types.asNumber(fx.rt.readSlot(add_out).?).?);
    try feedValue(&fx.rt, testing.allocator, "plane.player.mana", @as(i64, 75));
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(f64, 75.0), types.asNumber(fx.rt.readSlot(add_out).?).?);
}

test "defs close over nothing: plane paths inside a def body are rejected" {
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add plane.offset
        \\
        \\plane.v | bad | tap t
    , "close over nothing");
}

test "select chooses per tick without an if statement" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\select plane.under 10 20 | write plane.grade
    , .{.{ "plane.under", false }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 20), types.asNumber(fx.mock.writes.items[0].value).?);
    try feedValue(&fx.rt, testing.allocator, "plane.under", true);
    try fx.rt.tick(.{});
    const last = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    try testing.expectEqual(@as(f64, 10), types.asNumber(last.value).?);
}

test "G2: frozen reference — the canonical dump hashes to a committed value" {
    var dumps = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (dumps.items) |d| testing.allocator.free(d);
        dumps.deinit(testing.allocator);
    }
    try g2Run(testing.allocator, &dumps);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(dumps.items[dumps.items.len - 1], &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    // Frozen 2026-08-23. If this fails, the change altered mounted-program
    // semantics or the dump format — either bump fmt_version with intent, or
    // find the accident.
    // Re-frozen 2026-08-23 (same day, deliberate, twice over): fmt v2 added
    // the "now"/"wheel" sections for temporal operators, and the fixture's
    // local renamed stats → vitals because `stats` became a core operator
    // (the shadow ban firing on our own test was the rename's receipt).
    // Re-frozen 2026-08-24, deliberate: `set` gained its optional `value`
    // port, so every `set` node carries a second (here unbound) input slot.
    // The fixture holds exactly one `set` and no `notify`, so that is the
    // whole of the difference — and the test below pins the CAUSE, so a
    // future move of this hash cannot be waved through with the same excuse.
    // Re-frozen 2026-08-25 (tier 2, beat 1b), deliberate: broadcast makes an
    // elementwise operator's output KIND follow its input, so every one of
    // them now declares `out` as `any` instead of a `number`/`boolean` it
    // cannot promise. The dump carries each slot's type NAME
    // (serialize.zig), so the fixture's `div 100` and `mul 0.5` output slots
    // moved from "number" to "any". No mounted-program SEMANTICS changed —
    // the values and the propagation are identical, which the test below
    // pins directly rather than asserting here.
    // Hash moved 2026-08-29: `set` became `write` (write-verbs beat 1), and
    // the op NAME rides the canonical dump. Structural, not a value drift —
    // the same class of move as the slot-type test beside this one.
    //
    // Hash moved 2026-09-08, deliberate: an effect returns its input, so the
    // fixture's one `write` node gained an output PORT and therefore an
    // output slot. The move was not accepted on that sentence — both dumps
    // were decoded (struple's Python port) and diffed field by field before
    // this constant was touched. The WHOLE difference, exhaustively:
    //
    //   · `write1`'s "out" array: `[]` → `[14]`
    //   · one new slot, id 14: dir=out, node=4, port 0, pname "out",
    //     ty "any", kind value, src `.none`, val 0.9 — the value it wrote
    //   · every later slot id shifts by one (14…25 → 15…26), and the three
    //     places that reference one shift with it (`names.tint` 20→21, and
    //     the two `.wire` sources 17→18 and 23→24)
    //
    // Nothing else. `nodes` is still nine entries; `counts` (the per-node
    // eval counters) is byte-identical, which is the receipt that scheduling
    // did not move — the new slot has no downstream, so it is stored and
    // rouses nobody. `state`, `errs`, `tick`, `now` and `wheel` are identical
    // too, and `div1.out` still holds the same 0.9 it always did. A
    // structural move with no semantic one, exactly like the 2026-08-24
    // entry above — and the gate below pins the cause directly.
    try testing.expectEqualStrings("649b964914a83edadb22179128431479a14982183b5a7b2f4f89cf3cfd7a258e", &hex);
}

test "G2's hash moved because the slot TYPE moved, not because a value did" {
    // The receipt for the re-freeze above. Two independent claims: the
    // elementwise operators declare `any` (the cause), and the fixture's
    // computed values are exactly what they always were (the non-cause).
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    for ([_][]const u8{ "div", "mul", "add", ">", "and" }) |name| {
        const def = reg.get(reg.find(name).?);
        if (def.outputs[0].ty != types.Tag.any) {
            std.debug.print("'{s}' declares a static output type again — broadcast makes it input-dependent\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, g2_source, .{
        .{ "plane.player.health", @as(i64, 80) },
        .{ "plane.player.stamina", @as(i64, 50) },
        .{ "plane.player.underwater", false },
    });
    defer fx.deinit();
    // 80 clamped to 0..100, divided by 100 — the same 0.8 as before the beat.
    try testing.expectEqual(@as(f64, 0.8), slotNum(&fx, "programs.p.div1.out.out").?);
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.mul1.out.out").?);
    try testing.expectEqual(@as(usize, 1), fx.mock.writes.items.len);
    try testing.expectEqual(@as(f64, 0.8), types.asNumber(fx.mock.writes.items[0].value).?);
}

test "G2's hash moved AGAIN because the sink gained an output slot, not because a value did" {
    // The receipt for the 2026-09-08 re-freeze, in the same two-claim shape
    // as the gate above: the cause (all six effect ops declare one output)
    // and the non-cause (the fixture computes and writes exactly what it
    // always did). The diff behind the hash is spelled out beside the
    // constant in the G2 gate itself.
    //
    // Mutations that bite: drop `.outputs` from any one of the six (the sweep
    // names it); make `evalSink` return `Emit.none` again (the new slot is
    // there but empty, and the last assert goes down).
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    for ([_][]const u8{ "write", "notify", "inc", "cast", "tag", "untag" }) |name| {
        const def = reg.get(reg.find(name).?);
        if (def.outputs.len != 1 or def.outputs[0].ty != types.Tag.any) {
            std.debug.print("'{s}' does not declare one `any` output — an effect returns its input\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, g2_source, .{
        .{ "plane.player.health", @as(i64, 80) },
        .{ "plane.player.stamina", @as(i64, 50) },
        .{ "plane.player.underwater", false },
    });
    defer fx.deinit();
    // Unmoved: the same 0.8 through the same nodes, and the same single write.
    try testing.expectEqual(@as(f64, 0.8), slotNum(&fx, "programs.p.div1.out.out").?);
    try testing.expectEqual(@as(usize, 1), fx.mock.writes.items.len);
    try testing.expectEqual(@as(f64, 0.8), types.asNumber(fx.mock.writes.items[0].value).?);
    // Moved: the sink's own out slot now exists, and holds what it wrote.
    const passed = slotNum(&fx, "programs.p.write1.out.out") orelse {
        std.debug.print("the sink's out slot holds nothing — the effect emitted no value\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(f64, 0.8), passed);
}

// ---------------------------------------------------------------------------
// using — the parse-time fold (§3.10, 2026-09-08; it replaced `use`).
//
// `using <tokens…> as :name` captures tokens VERBATIM; `:name` splices them
// back wherever a token may appear. Resolved entirely at parse: folds are
// surface syntax and never reach the graph, the dump, or the evaluator. The
// eleven gates below are the ones the design was ruled against — each names
// the mutation that had to bite before it was believed.
// ---------------------------------------------------------------------------

test "using: a fold of a plane path splices, composes, and resolves" {
    // The `use` gate this replaces, kept whole: chains, record sugar, argument
    // position, and a nested fold, with every subscription fully expanded — no
    // fold residue anywhere. Mutation that bites: splice one token short
    // (`f.body[0 .. f.body.len - 1]`) — `:p.health` loses `player` and the
    // gate goes down on the subscription list, loudly.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\using plane.player as :p
        \\using :p.vitals as :v
        \\:p.health | clamp 0 100 | div 100 | write plane.ui.hp
        \\:v.{mana, stamina} as pools
        \\select :p.underwater 1 0 as tint
    , .{ .{ "plane.player.health", @as(i64, 50) }, .{ "plane.player.underwater", false } });
    defer fx.deinit();
    const expected_subs = [_][]const u8{
        "plane.player.health",
        "plane.player.vitals.mana",
        "plane.player.vitals.stamina",
        "plane.player.underwater",
    };
    try testing.expectEqual(expected_subs.len, fx.prog.subs.items.len);
    for (expected_subs, fx.prog.subs.items) |want, sub| {
        try testing.expectEqualStrings(want, sub.path);
    }
    try testing.expectEqualStrings("plane.ui.hp", fx.mock.writes.items[0].path);
    try testing.expectEqual(@as(f64, 0.5), types.asNumber(fx.mock.writes.items[0].value).?);
}

test "using: substitution composes with the segment that follows it" {
    // This is what subsumes `use`'s whole reason to exist: the fold is a
    // PREFIX only because splicing leaves the following tokens where they
    // were. Mutation that bites: delete the `expandIfFold` at the head of
    // `parseExpr` — the statement head stops expanding and `:k.flock` refuses
    // as "expected an expression". (Also bitten by shortening the captured
    // body by one token, which is the composition claim from the other side.)
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using plane.drift.k as :k
        \\:k.flock | write plane.out
    );
    defer prog.deinit();
    try testing.expectEqualStrings("plane.drift.k.flock", prog.subs.items[0].path);

    // …and a fold of a LEAF is a stream, which a `use` alias could never be:
    // `use plane.environment.ambient_light as dusk` then `dusk | …` was a
    // dedicated refusal ("an alias is a path PREFIX"), found by a no-priors
    // reader on 2026-08-26. The fold has no prefix rule to violate.
    var leaf = try parseOk(testing.allocator, &reg,
        \\using plane.environment.ambient_light as :dusk
        \\:dusk | < 0.15 | write plane.dark
    );
    defer leaf.deinit();
    try testing.expectEqualStrings("plane.environment.ambient_light", leaf.subs.items[0].path);
}

test "using: a fold splices in ARGUMENT position — what a def cannot do" {
    // The whole argument for a token fold over a namespace import or a def:
    // `instantiate` is only reachable from opcall position, so no `def` can
    // ever stand where `1` and `0` stand here. Mutation that bites: drop the
    // `expandIfFold` at the head of `parseArgValue` — `select :wet 1 0` then
    // refuses with "unexpected ':wet' in arguments".
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\using plane.player.underwater as :wet
        \\select :wet 1 0 | write plane.grade
    , .{.{ "plane.player.underwater", true }});
    defer fx.deinit();
    try testing.expectEqualStrings("plane.player.underwater", fx.prog.subs.items[0].path);
    try testing.expectEqualStrings("plane.grade", fx.mock.writes.items[0].path);
    try testing.expectEqual(@as(f64, 1), types.asNumber(fx.mock.writes.items[0].value).?);
}

test "using: a fold spliced twice builds TWO node sets, not one" {
    // Intended, and the same thing `def` already does — a def body is
    // flattened per instance with an instance-name prefix, so two calls are
    // two node sets. A fold that were shared would make the second `clamp`
    // read the first's state. Mutation that bites: `_ = self.folds.swapRemove
    // (tok.text);` after a splice (a plausible "consume it" bug) — the second
    // `:cl` then refuses as an unbound fold.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using clamp 0 100 as :cl
        \\plane.a | :cl | write plane.x
        \\plane.b | :cl | write plane.y
    );
    defer prog.deinit();
    try testing.expect(nodeIdOf(&prog, "clamp1") != null);
    try testing.expect(nodeIdOf(&prog, "clamp2") != null);
    try testing.expect(nodeIdOf(&prog, "clamp1").? != nodeIdOf(&prog, "clamp2").?);

    // A fold may hold a TWO-WORD operator, which is the claim `namespaces.md`
    // makes for `using` as a namespacing lever: a program can abbreviate a
    // registered family locally, and it costs the global operator table
    // nothing. Gated here because namespaces.md is prose, not a ```rill fence
    // the manual-parse gate reads. Mutation that bites: delete the
    // `expandIfFold` that runs after a `|` in `parseChain` — the fold never
    // becomes an operator token and the two-word lookup is never reached.
    var fam = try parseOk(testing.allocator, &reg,
        \\using rbf through as :through
        \\plane.coat | :through plane.flame | write plane.out
    );
    defer fam.deinit();
    try testing.expect(nodeIdOf(&fam, "rbf through1") != null);
}

test "using: expansion is recursive — a fold may reference an earlier fold" {
    // Defined-before-use, the same rule the whole language runs on (parse
    // order is topological order). Mutation that bites: `while` → `if` in
    // `expandIfFold` (expand once, not to fixpoint) — `:f` then leaves a `:d`
    // token where a path head belongs.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using plane.drift as :d
        \\using :d.flock as :f
        \\:f.radius | write plane.out
    );
    defer prog.deinit();
    try testing.expectEqualStrings("plane.drift.flock.radius", prog.subs.items[0].path);
}

test "using: a fold cycle is refused, naming every fold in it" {
    // A fold body is captured unparsed, so a self-reference binds cleanly and
    // only bites at the splice. The provenance chain a splice already carries
    // IS the recursion stack, which is why the message can read the folds out
    // rather than saying "too deep". Mutation that bites: drop the name
    // comparison in the `via` walk and keep only the depth cap — the parse
    // still refuses, but "expands through itself (:a → :b → :a)" is gone and
    // the second assertion fails.
    try expectParseError(
        \\using :a as :a
        \\:a | write plane.x
    , "fold cycle");
    try expectParseError(
        \\using :b as :a
        \\using :a as :b
        \\:a | write plane.x
    , ":a → :b → :a");
    // Indirect recursion through a TAIL position, not a head: `:a` expands to
    // `mul 2 :a`, whose second `:a` is reached from argument position on the
    // next call into `expandIfFold`. A cycle check that only looked at the
    // head of one expansion would loop forever here.
    try expectParseError(
        \\using mul 2 :a as :a
        \\plane.b | :a | write plane.x
    , "fold cycle");
}

test "using: an undefined :name is refused, naming it" {
    // Mutation that bites: `orelse return` instead of `orelse fail` in
    // `expandIfFold` — the unknown fold token then falls through to
    // "expected an expression, got ':nope'", which names the token but not
    // the thing to bind.
    try expectParseError(":nope | write plane.x", "':nope' is not a bound fold");
    try expectParseError("plane.a | mul :nope | write plane.x", "':nope' is not a bound fold");
    // …and it says what to do about it, in the spelling that works.
    try expectParseError(":nope | write plane.x", "using <tokens…> as :nope");
}

test "using: inside a def body the EXISTING checks run on the expanded tokens" {
    // Christian's ruling, 2026-09-08: `:name` is allowed inside a def body and
    // gets NO rule of its own. A fold of pure operators works; a fold that
    // expands to a plane path is refused by the "defs close over nothing"
    // check that was already there — which preserves def's portability
    // guarantee without `using` needing to know defs exist.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using mul 2 as :dbl
        \\def scale(x: number) =
        \\  x | :dbl
        \\
        \\plane.a | scale | write plane.b
    );
    defer prog.deinit();
    try testing.expect(nodeIdOf(&prog, "scale1.mul1") != null);

    // The refusal carries PROVENANCE. Without it this reads as "defs close
    // over nothing" pointing at a `plane` token the author never typed — the
    // exact failure the error-locality requirement exists to prevent.
    // Mutation that bites: drop the `if (tok.fold != 0)` call in `fail` — the
    // first assertion still passes and the second stops.
    try expectParseError(
        \\using plane.player.offset as :po
        \\def bad(x: number) =
        \\  x | add :po
        \\
        \\plane.v | bad | write plane.b
    , "close over nothing");
    try expectParseError(
        \\using plane.player.offset as :po
        \\def bad(x: number) =
        \\  x | add :po
        \\
        \\plane.v | bad | write plane.b
    , "expanded from :po, bound at line 1");

    // A fold reference is an ordinary statement inside a body, and the body
    // does not end at it. (The dedent rule reads the token at STATEMENT
    // START, which is always one the author wrote — a fold body holds no
    // newline, so a splice can never straddle two statements. That is why the
    // `spliced.col` rewrite is gated on the DIAGNOSTIC position instead, in
    // the provenance gate below, and not here: the mutation that dropped it
    // survived this gate, and the survival is what said where it mattered.)
    var indented = try parseOk(testing.allocator, &reg,
        \\using mul 3 as :tri
        \\def scale3(x: number) =
        \\  x | add 1
        \\  x | :tri
        \\
        \\plane.a | scale3 | write plane.b
    );
    defer indented.deinit();
    try testing.expect(nodeIdOf(&indented, "scale31.mul1") != null);
}

test "using: a parse error inside expanded tokens names the fold and its line" {
    // The one real cost of a general fold: `use` could validate at the
    // definition, because a use path was always plane-side. A fold of
    // arbitrary tokens cannot, so the error lands at the splice, on tokens the
    // author did not literally write — and every such refusal must say whose
    // they are. Mutation that bites: have `noteProvenance` stop after the
    // innermost site (drop `s = f.via`) — the nested case loses "spliced via".
    try expectParseError(
        \\using mul nonsense as :bad
        \\plane.a | :bad | write plane.b
    , "unknown name 'nonsense'");
    try expectParseError(
        \\using mul nonsense as :bad
        \\plane.a | :bad | write plane.b
    , "expanded from :bad, bound at line 1");
    // Nested: the innermost fold first, then what it was spliced through.
    try expectParseError(
        \\using mul nonsense as :inner
        \\using :inner as :outer
        \\plane.a | :outer | write plane.b
    , "expanded from :inner, bound at line 1, spliced via :outer (line 2)");

    // …and the CARET lands on the splice the author wrote, not on the `using`
    // line the tokens were captured from. A spliced token therefore takes the
    // splice site's line and column; only its provenance points back.
    //
    // This gate exists because the first draft asserted the message and not
    // the position, and a mutation that stopped rewriting `spliced.col`
    // SURVIVED it — the def-body dedent rule reads a column, but it reads the
    // token at STATEMENT START, which is always one the author wrote, so
    // nothing in the suite could tell. The position was the load-bearing part
    // all along. Mutation that bites: drop `spliced.line = tok.line;` (caret
    // goes to line 1) or `spliced.col = tok.col;` (caret goes to column 7,
    // where `nonsense` sits on the binding line).
    // (The reference sits at column 19 and the offending token at column 11 of
    // the binding line ON PURPOSE: the first draft put both at 11 by accident
    // and the `spliced.col` mutation survived on the coincidence.)
    try expectParseErrorAt(
        \\using mul nonsense as :bad
        \\plane.a | mul 1 | :bad | write plane.b
    , "unknown name 'nonsense'", 2, 19);
}

test "using: all four existing colon spellings still parse" {
    // The implementation hazard: `:` was already live in four places, and all
    // four are used heavily in real kernels in the sibling repos. The lexer
    // rule is ADJACENCY — a fold colon glues to the name AFTER it, every
    // existing colon glues to the name BEFORE it.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\def half(x: number) = x | div 2
        \\plane.a | half | write plane.b
        \\{l: 0.28, r: 1} | write plane.rec
        \\plane.c | match {id: string, distance: number} | write plane.m
        \\plane.lvl | cast $blight radius: 12 at: plane.origin
    );
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "cast1").?);
    try testing.expectEqual(@as(f64, 12), types.asNumber(n.statics[1].literal).?);
    try testing.expectEqualStrings("plane.origin", prog.slot(n.inputs[2]).source.plane);

    // …and the SAME four written with no space after the colon, which is what
    // makes the preceding-character whitelist load-bearing. The first draft of
    // this gate used only the spaced forms above, and a mutation that deleted
    // the whitelist entirely SURVIVED it: with a space after the colon the
    // next character is not a name start, so the fold rule never fires and the
    // spaced spellings are safe either way. It is `x:number`, `{a:b}`,
    // `{id:string}` and `at:plane.origin` — colon glued on BOTH sides — that
    // the whitelist is the only thing standing between and a fold token.
    // Mutation that bites: `colonOpensFold` returns true whenever a name
    // follows, ignoring what precedes.
    var tight = try parseOk(testing.allocator, &reg,
        \\def third(x:number) = x | div 3
        \\plane.a | third | write plane.b
        \\{l:0.28, r:plane.rr} | write plane.rec
        \\plane.c | match {id:string, distance:number} | write plane.m
        \\plane.lvl | cast $blight radius:12 at:plane.origin
    );
    defer tight.deinit();
    const n2 = tight.node(nodeIdOf(&tight, "cast1").?);
    try testing.expectEqual(@as(f64, 12), types.asNumber(n2.statics[1].literal).?);
    try testing.expectEqualStrings("plane.origin", tight.slot(n2.inputs[2]).source.plane);

    // The kwarg case is the one that needed adjacency and not position: a
    // keyword followed by a fold must stay a keyword. `parseArgs` decides a
    // kwarg on a `.name`-then-`.colon` lookahead, so with a position-only rule
    // `at :origin` would read `at:` as the kwarg and eat the fold's name.
    var kw = try parseOk(testing.allocator, &reg,
        \\using plane.origin as :here
        \\plane.lvl | cast $blight radius 12 at :here
    );
    defer kw.deinit();
    const c2 = kw.node(nodeIdOf(&kw, "cast1").?);
    try testing.expectEqualStrings("plane.origin", kw.slot(c2.inputs[2]).source.plane);
}

test "using: the binding form refuses what it must, and points" {
    // The name wears its sigil at BOTH ends (Christian, 2026-09-08): it is
    // more explicit, it visually ties the two ends of the string together, and
    // it matches rill's existing convention that a sigil is part of the token
    // (`$chan` is one token, sigil included). The bare form `as flock` was the
    // rejected spelling, so it gets a POINTING error, not "expected ':'".
    // Mutation that bites: `return self.fail(name_tok, "expected a fold name")`
    // for the `.name` case — the refusal still happens, and stops naming the
    // fix.
    try expectParseError("using plane.a as flock", "bind it `as :flock`");
    // The sigil rule applies to what comes AFTER the colon.
    try expectParseError("using plane.a as :$s", "cannot wear");
    try expectParseError("using plane.a as :#s", "cannot wear");
    // Redefining a bound fold is an error; a reserved word is not a fold name.
    try expectParseError(
        \\using plane.a as :p
        \\using plane.b as :p
    , "fold ':p' is already bound");
    try expectParseError("using plane.a as :as", "reserved");
    // Shape errors in the statement itself.
    try expectParseError("using plane.a :p", "ends with `as :<name>`");
    try expectParseError("using as :p", "binds tokens to a name");
    // `using` is a top-level binding; the reference is what goes mid-chain.
    try expectParseError("plane.a | using plane.b as :p", "top level");
}

test "using: the loud-error properties survive folding" {
    // Ported from `use`. Bare dotted names still never fall through to the
    // plane, and the cycle check still sees through a fold, because a fold is
    // gone before the graph exists.
    try expectParseError("q.health | tap t", "unknown operator or name 'q'");
    try expectParseError(
        \\using plane.a as :pa
        \\:pa.x | add 1 | write :pa.x
    , "cycle");
    // What `using` DELETED: `use` needed five shadow checks (reserved, sigil,
    // already-bound, collides-with-a-stream-name, shadows-an-operator) because
    // an alias and a bare name lived in one namespace. A fold wears a colon,
    // so the last two cannot happen — a fold named `:add` and the operator
    // `add` are different strings, and both work in the same program.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using plane.k as :add
        \\plane.a | add :add.x | write plane.b
        \\plane.c | add 1 as add_out
    );
    defer prog.deinit();
    try testing.expectEqualStrings("plane.k.x", prog.subs.items[1].path);
}

test "using: a tail port takes the line verbatim — a fold there is text" {
    // A tail slices the RAW SOURCE between token offsets (§3.11), and a
    // spliced token's offset points into the `using` line it was captured
    // from. So nothing expands inside a tail — `:name` is text there, exactly
    // as `//` and `#` are — and the one case that cannot be text, a fold
    // landing ON the tail's first token, refuses by name instead of slicing
    // somewhere absurd. Mutation that bites: delete the `start_tok.fold != 0`
    // guard — the second case then parses and binds a locator built from the
    // bytes between the two lines.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using plane.a as :flock
        \\sound play :flock.wav
    );
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "sound play1").?);
    try testing.expectEqualStrings(":flock.wav", types.asString(prog.slot(n.inputs[0]).source.literal).?);

    // The case that cannot be text: a fold expanded at the FIXED positional
    // before the tail, whose remaining tokens land on the tail's first token.
    // `emitter drop` takes one static word and then the tail, so a two-token
    // fold runs one token into the tail — and the slice would start back on
    // the `using` line.
    try expectParseError(
        \\using boom 2 as :f
        \\plane.x | emitter drop :f /tmp/a.wav
    , "verbatim from the source");
}

test "use: the retired keyword points at `using`" {
    // Same precedent as `set` → `write` (2026-08-29): a keyword every rill
    // ever written used must not die as "unknown operator or name". Zero
    // `.rill` files across the six sibling repos held a `use … as` statement,
    // which is why removing it cost nothing — but the pointer is what makes
    // that true for anyone reading an old doc. Mutation that bites: delete the
    // `use` arm from `parseProgram`'s dispatch — the statement then fails as
    // "unknown operator or name 'use'" and says nothing about `using`.
    try expectParseError("use plane.player as p", "`use` became `using`");
    try expectParseError("plane.a | add 1\nuse plane.b as q", "`use` became `using`");
    // …including where it used to be refused for a different reason.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add 1
        \\  use plane.q as z
        \\
        \\plane.v | bad | tap t
    , "`use` became `using`");
}

// ---------------------------------------------------------------------------
// The parameter pack — `export def`, defaults, ranges and `describe`
// (§3.9, 2026-09-08). Blade3D's `[OperatorParameter]`, transposed: one
// declaration is the call signature, the widget's range, the documentation and
// the validation. Christian spent a morning unable to work out what a particle
// demo's positional numbers meant; this is the fix, and the parity gate is the
// point of it — it puts the burden on whoever writes the definition.
//
// Every gate below names the mutation that had to bite before it was believed.
// ---------------------------------------------------------------------------

test "pack: a default fills an omitted argument, and a written one overrides it" {
    // The feature's whole first claim. Mutation that bites: delete the
    // `if (pd.default) |bytes|` arm in `instantiate` — every call that omits
    // an argument dies as "port 'k' of 'scale' is not bound".
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\def scale(x: number, k: number = 3) =
        \\  x | mul k
        \\
        \\plane.v | scale | write plane.defaulted
        \\plane.v | scale 10 | write plane.overridden
    , .{.{ "plane.v", @as(i64, 7) }});
    defer fx.deinit();
    var got_default: ?f64 = null;
    var got_override: ?f64 = null;
    for (fx.mock.writes.items) |w| {
        if (std.mem.eql(u8, w.path, "plane.defaulted")) got_default = types.asNumber(w.value);
        if (std.mem.eql(u8, w.path, "plane.overridden")) got_override = types.asNumber(w.value);
    }
    try testing.expectEqual(@as(f64, 21), got_default.?);
    try testing.expectEqual(@as(f64, 70), got_override.?);
}

test "pack: a default is an ordinary literal — the knob under the instance is settable" {
    // The default must not be a second kind of thing. It is spliced as the
    // same `.literal` Source a written argument produces, so G7's claim (a
    // def's internals are addressable from outside) holds over it unchanged.
    // Mutation that bites: give the default its own Source case — `setInput`
    // then has no slot to write and the second tick still reads 21.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\def scale(x: number, k: number = 3) =
        \\  x | mul k
        \\
        \\plane.v | scale | write plane.out
    , .{.{ "plane.v", @as(i64, 7) }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 21), types.asNumber(fx.mock.writes.items[0].value).?);
    const knob = "programs.p.scale1.mul1.in.b";
    const five = try packOne(testing.allocator, @as(i64, 5));
    defer testing.allocator.free(five);
    try fx.rt.setInput(knob, five);
    try fx.rt.tick(.{});
    const last = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    try testing.expectEqual(@as(f64, 35), types.asNumber(last.value).?);
}

test "pack: an exported def survives the parse, with defaults, ranges and prose intact" {
    // `def` bodies flatten and the graph does not know defs exist — so
    // without a retained table `export` would be inert. This is the surface a
    // host reads: `schema`'s source, the HUD's panel, the agent's answer to
    // "what does `spread` mean". Mutations that bite: drop the `min`/`max`
    // assignment in `parseDef` (both nulls); drop `publishExports` (no
    // exports at all); copy the pack for local defs too (the sibling gate
    // below).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\export def roaches(rate: number = 60 (0..500), speed = 0.15 (0..5), spread = 0.35 (0..3)) =
        \\  rate | mul speed | mul spread
        \\
        \\describe roaches
        \\    "Cockroaches milling on a floor, scattering and regrouping."
        \\    rate   "how many rows are born each second"
        \\    speed  "metres per second along the spray's aim at birth"
        \\    spread "± metres per second of random jitter added at birth"
        \\
        \\roaches | write plane.out
    );
    defer prog.deinit();

    try testing.expectEqual(@as(usize, 1), prog.exports.items.len);
    const e = prog.exported("roaches").?;
    try testing.expectEqualStrings("Cockroaches milling on a floor, scattering and regrouping.", e.doc);
    try testing.expectEqual(@as(usize, 3), e.ports.len);

    try testing.expectEqualStrings("rate", e.ports[0].name);
    try testing.expectEqual(types.Tag.number, e.ports[0].ty);
    try testing.expectEqual(@as(f64, 60), types.asNumber(e.ports[0].default.?).?);
    try testing.expectEqual(@as(f64, 0), types.asNumber(e.ports[0].min.?).?);
    try testing.expectEqual(@as(f64, 500), types.asNumber(e.ports[0].max.?).?);
    try testing.expectEqualStrings("how many rows are born each second", e.ports[0].doc);

    // An untyped port keeps `any` and still carries its pack — the type
    // annotation and the default are independent declarations.
    try testing.expectEqualStrings("speed", e.ports[1].name);
    try testing.expectEqual(types.Tag.any, e.ports[1].ty);
    try testing.expectEqual(@as(f64, 0.15), types.asNumber(e.ports[1].default.?).?);
    try testing.expectEqual(@as(f64, 5), types.asNumber(e.ports[1].max.?).?);
    try testing.expectEqualStrings("spread", e.ports[2].name);
    try testing.expectEqual(@as(f64, 3), types.asNumber(e.ports[2].max.?).?);
    try testing.expectEqualStrings("± metres per second of random jitter added at birth", e.ports[2].doc);

    try testing.expect(prog.nodeCount() > 0);
}

test "pack: a LOCAL def is not enumerable — it vanishes as it always did" {
    // The other half of the visibility claim, and the reason it is a claim at
    // all: if every def were published, `export` would say nothing. Mutation
    // that bites: drop the `if (!tmpl.exported) continue;` in `publishExports`.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\def helper(x: number, k: number = 2) = x | mul k
        \\plane.v | helper | write plane.out
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 0), prog.exports.items.len);
    try testing.expect(prog.exported("helper") == null);
}

test "pack: the range spelling does not disturb any existing signature" {
    // The contextual spelling reserves nothing, so nothing that parsed before
    // may parse differently now. The typed-port colon is the one at real risk
    // (`def f(x: number)` was the only punctuation in a signature until this
    // beat), and the `..` token is the other — it made the NUMBER lexer yield.
    // Mutation that bites: drop the `..` break from the number lexer — `0..500`
    // lexes as one number token and dies as "bad number '0..500'".
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const cases = [_][]const u8{
        // the old spellings, unchanged
        "def a(x) = x | mul 2\nplane.v | a | tap t",
        "def b(x: number) = x | mul 2\nplane.v | b | tap t",
        "def c(x: number, y: number) = x | add y\nplane.v | c 1 | tap t",
        // …and each new one beside it
        "def d(x: number = 1) = x | mul 2\nd | tap t",
        "def e(x: number = 1 (0..10)) = x | mul 2\ne | tap t",
        "def f(x (0..10)) = x | mul 2\nplane.v | f | tap t",
        // a float range, a negative floor, a range whose ends are the same
        "def g(x = 0.5 (-1.5..1.5)) = x | mul 2\ng | tap t",
        "def h(x = 0 (0..0)) = x | mul 2\nh | tap t",
        // and a kwarg call site: `rate: 120` is the colon that glues LEFT
        "def i(x = 1, rate = 2) = x | mul rate\ni rate: 120 | tap t",
    };
    for (cases) |src| {
        var prog = parseOk(testing.allocator, &reg, src) catch |err| {
            std.debug.print("signature no longer parses: {s}\n", .{src});
            return err;
        };
        prog.deinit();
    }
    // `..` outside a range is still the loud error it always was — the token
    // exists, it just has nowhere else to go.
    try expectParseError("plane.a | tap t\nplane.b..c | tap u", "expected");
}

test "pack: the range is stored as advice — nothing clamps and nothing refuses" {
    // Blade3D's reading, kept deliberately (a spawn position with min -10 does
    // not forbid spawning at 20). Enforcing would be trivial here and is
    // switched OFF: a range is for the reader and for the widget. Mutation
    // that bites: clamp the default into [min, max] at parse, or refuse an
    // out-of-range argument at the call — either kills one of the two
    // assertions below.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\export def wide(rate = 900 (0..500)) = rate | mul 1
        \\describe wide
        \\    "a rate whose default sits outside its own advisory range"
        \\    rate "rows per second"
        \\
        \\wide 4000 | write plane.out
    );
    defer prog.deinit();
    const e = prog.exported("wide").?;
    try testing.expectEqual(@as(f64, 900), types.asNumber(e.ports[0].default.?).?);
    try testing.expectEqual(@as(f64, 500), types.asNumber(e.ports[0].max.?).?);
    // and 4000 went in unmolested
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    try testing.expectEqual(@as(f64, 4000), types.asNumber(mock.writes.items[0].value).?);
}

test "pack: an exported def with an undescribed port is refused, naming the port" {
    // Direction one of the parity gate. One-directional parity catches
    // orphans and lets everybody skip writing prose, which is the exact
    // failure the feature exists to prevent. Mutation that bites: drop the
    // `pd.doc.len > 0` loop in `checkExportsDescribed` — the program parses
    // green with `spread` undocumented.
    try expectParseError(
        \\export def roaches(rate = 60, speed = 0.15, spread = 0.35) =
        \\  rate | mul speed | mul spread
        \\
        \\describe roaches
        \\    "roaches on a floor"
        \\    rate  "how many rows are born each second"
        \\    speed "metres per second at birth"
        \\
        \\roaches | tap t
    , "port 'spread' has no description");
    // …and it says where to put it.
    try expectParseError(
        \\export def roaches(rate = 60, spread = 0.35) =
        \\  rate | mul spread
        \\
        \\describe roaches
        \\    "roaches on a floor"
        \\    rate  "how many rows are born each second"
        \\
        \\roaches | tap t
    , "add a line `spread \"…\"` to `describe roaches`");
}

test "pack: a describe line naming an unknown port is refused, and lists the real ones" {
    // Direction two. Mutation that bites: replace the port lookup's `else`
    // branch with a `continue` — the stray line is silently dropped and a
    // typo'd parameter name documents nothing for ever.
    try expectParseError(
        \\export def roaches(rate = 60, speed = 0.15) =
        \\  rate | mul speed
        \\
        \\describe roaches
        \\    "roaches on a floor"
        \\    rate  "born per second"
        \\    speed "metres per second"
        \\    sped  "a typo nobody would ever spot"
        \\
        \\roaches | tap t
    , "'sped' is not a port of 'roaches' — it has: rate, speed");
}

test "pack: a LOCAL def needs no describe block, but a wrong one is still refused" {
    // Christian's ruling, both halves. A `def` is also just a private helper,
    // and taxing every two-line helper with a description block would be tax
    // rather than discipline — but a describe block that lies is wrong
    // whoever wrote it. Mutations that bite: make `checkExportsDescribed`
    // ignore `tmpl.exported` (the first case is refused); move the
    // unknown-port check out of `parseDescribe` into the exported-only sweep
    // (the third case parses green).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\def helper(x, k = 2) = x | mul k
        \\plane.v | helper | write plane.out
    );
    prog.deinit();
    // …and one WITH a block, still local, still fine — prose costs nothing.
    var prog2 = try parseOk(testing.allocator, &reg,
        \\def helper2(x, k = 2) = x | mul k
        \\describe helper2
        \\    k "the multiplier"
        \\
        \\plane.v | helper2 | write plane.out
    );
    prog2.deinit();
    // …but a local block may not name a port that does not exist.
    try expectParseError(
        \\def helper3(x, k = 2) = x | mul k
        \\describe helper3
        \\    kk "the multiplier, misspelled"
        \\
        \\plane.v | helper3 | tap t
    , "'kk' is not a port of 'helper3' — it has: x, k");
}

test "pack: an exported def with no describe block at all is refused" {
    // The third refusal, decided rather than inherited: an export with no
    // block is the same laziness as an export with an undescribed port, and
    // catching only the second would make "leave the block out" the way to
    // skip the gate. Mutation that bites: drop the `!tmpl.described` arm — a
    // block-less export parses green and enumerates with empty docs.
    try expectParseError(
        \\export def roaches(rate = 60, speed = 0.15) =
        \\  rate | mul speed
        \\
        \\roaches | tap t
    , "has no `describe` block");
    // A block that describes every port but never says what the THING is is
    // the same gap one level up — it is the first line of a generated panel.
    try expectParseError(
        \\export def roaches(rate = 60) = rate | mul 1
        \\describe roaches
        \\    rate "born per second"
        \\
        \\roaches | tap t
    , "no leading description");
}

test "pack: `export` marks visibility, and the sigils are all still refused on a def" {
    // The spelling ruling of 2026-09-08. `def ^roaches` was the first draft
    // and is REJECTED: `^` is an ADDRESSING sigil — what a mounted archetype
    // is called on the plane — and making it carry visibility as well would
    // conflate two different questions in one character. `export` says
    // visibility and nothing else, so `parseDef`'s blanket sigil refusal keeps
    // exactly the shape it had. Mutation that bites: allow `^` through that
    // refusal — the fourth case below stops failing.
    try expectParseError("def $x(a) = a | mul 2", "a sigil names a store row");
    try expectParseError("def @x(a) = a | mul 2", "a sigil names a store row");
    try expectParseError("def #x(a) = a | mul 2", "a sigil names a store row");
    try expectParseError("def ^x(a) = a | mul 2", "a sigil names a store row");
    // …and a port cannot wear one either, exported or not.
    try expectParseError("export def x(^a) = ^a | mul 2", "a sigil names a store row");
    // `export` alone is not a statement, and the refusal says what it marks.
    try expectParseError("export plane.a", "`export` marks a DEFINITION");
    // …and both keywords POINT anywhere they cannot stand, rather than dying
    // as "unknown operator or name" at the op-lookup door, which is where a
    // reserved word always lands. One door, the way `set` → `write` and
    // `use` → `using` do — the previous beat proved the other two positions
    // were dead code. Mutation that bites: delete the pointer beside them.
    try expectParseError("plane.a | describe f", "is a statement keyword");
    try expectParseError(
        \\def f(x) =
        \\  x | mul 2
        \\  export def g(y) = y | mul 3
    , "is a statement keyword");
    // `export` and `describe` are reserved, so no host can register either
    // name and then find it permanently shadowed by the grammar.
    try testing.expect(rill.registry.isReservedWord("export"));
    try testing.expect(rill.registry.isReservedWord("describe"));
}

test "pack: an exported def's indented body is its body" {
    // The dedent that ends a def body is measured from the STATEMENT HEAD.
    // Measured from `def`, every exported definition anchors at column 8 and a
    // two-space-indented body reads as a dedent — the def parses as empty.
    // Mutation that bites: `const def_tok = kw_tok;` — "def 'two' has an empty
    // body".
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\export def two(x: number, k: number = 3) =
        \\  x | mul k as scaled
        \\  scaled | add 1
        \\
        \\describe two
        \\    "scale and offset"
        \\    x "the value"
        \\    k "the multiplier"
        \\
        \\plane.v | two | write plane.out
    , .{.{ "plane.v", @as(i64, 5) }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 16), types.asNumber(fx.mock.writes.items[0].value).?);
}

test "pack: a required port may not follow a defaulted one" {
    // rill's own `AmbiguousOptionals` rule (registry.zig), applied where a def
    // port has no word to mark it with. Positional fill is strictly
    // left-to-right, so `f 5` would land on the OPTIONAL port and leave the
    // required one unbound — `arm gate_closed`, one level up. Mutation that
    // bites: drop the check — the first case parses, and `f 5` then fails far
    // away with "port 'b' of 'f' is not bound", pointing at the CALL.
    try expectParseError("def f(a = 1, b) = a | add b\nf 5 | tap t", "has no default but follows 'a'");
    try expectParseError("def f(a, b = 1, c) = a | add c\nplane.v | f | tap t", "has no default but follows 'b'");
    // Refused at the DEFINITION, where the fix is, and the message says both.
    try expectParseError("def f(a = 1, b) = a | add b\nf 5 | tap t", "declare it before 'a'");
    // Two ADJACENT defaults are fine here, where the registry has to refuse
    // them: forcing defaults to the tail means nothing after them can shift.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "def f(a = 1, b = 2) = a | add b\nf 5 | tap t");
    prog.deinit();
}

test "pack: a default must be a literal, and must match the port's declared type" {
    // A def closes over nothing, so a default cannot read a stream or a plane
    // path — and a `number` port whose default is a string is a mistake worth
    // catching where it is written, not at the first call. Mutations that
    // bite: drop the literal check in `parseDefLiteral` (the plane path binds
    // and the def silently closes over the world); drop the `types.accepts`
    // check (the string default reaches `mul` at eval).
    try expectParseError("def f(x = plane.k) = x | mul 2\nf | tap t", "must be a literal");
    try expectParseError("def f(x: number = \"fast\") = x | mul 2\nf | tap t", "the default is string, but the port is declared number");
    // A range is two NUMBERS — a slider cannot be drawn between anything else.
    try expectParseError("def f(x = 1 (\"lo\"..\"hi\")) = x | mul 2\nf | tap t", "a range is two numbers");
    // …written low to high, because backwards has exactly one reading.
    try expectParseError("def f(x = 1 (10..0)) = x | mul 2\nf | tap t", "runs backwards");
    // …and the `..` is not optional inside the parens.
    try expectParseError("def f(x = 1 (0 10)) = x | mul 2\nf | tap t", "expected '..'");
}

test "pack: a describe block must follow a def that exists, once" {
    // "Loud, never a guess": each of these is a specific mistake with a
    // specific fix, and none of them may shrug. Mutation that bites: replace
    // the `defs.get` refusal with a silent `return` — a describe block for a
    // misspelled def documents nothing and says nothing.
    try expectParseError("describe nobody\n  \"hi\"", "is not a def in this program");
    // …including a describe block written ABOVE its def, which is the
    // plausible mistake — parse order is definition order here.
    try expectParseError(
        \\describe early
        \\    "written before its def"
        \\
        \\def early(x) = x | mul 2
    , "a `describe` block follows the `def` it describes");
    // …and an operator is not a def: its help lives in its registration.
    try expectParseError("describe mul\n  \"multiply\"", "is a registered operator, not a def");
    // One block per definition, so there is one place to read.
    try expectParseError(
        \\def f(x) = x | mul 2
        \\describe f
        \\    x "the value"
        \\describe f
        \\    "a second opinion"
    , "already has a `describe` block");
    // An empty block is a slip, not a statement.
    try expectParseError("def f(x) = x | mul 2\ndescribe f\nplane.v | f | tap t", "says nothing");
    // A port described twice has two answers and no way to pick.
    try expectParseError(
        \\def f(x) = x | mul 2
        \\describe f
        \\    x "the value"
        \\    x "no, THIS value"
    , "described twice");
    // An EMPTY description is not a description. This one is here because the
    // mutation SURVIVED the first draft of this gate: with the check removed
    // the suite stayed green, and an exported def could satisfy the parity
    // gate with `rate ""` — the one spelling that is worse than leaving the
    // line out, because then the refusal would have said "port has no
    // description" about a line visibly sitting right there. Mutations that
    // bite: drop either `st.text.len == 0` or `t.text.len == 0` guard.
    try expectParseError(
        \\export def f(x = 1) = x | mul 2
        \\describe f
        \\    "a thing"
        \\    x ""
    , "port 'x' has an empty description");
    try expectParseError(
        \\def f(x) = x | mul 2
        \\describe f
        \\    ""
        \\    x "the value"
    , "the definition's description is empty");
}

test "pack: a fold supplies a default, and a describe block splices nothing" {
    // The interaction with the previous beat (`using`, 2026-09-08). A default
    // is a VALUE POSITION like every other, so `expandIfFold` runs there and
    // the tokens are judged by the same rules — including the fold's
    // provenance chain when they are wrong. A describe block is the opposite
    // case on purpose: it is prose, read verbatim, and the one surface the
    // design intends a local model to write into — a fold in the port-NAME
    // position could rename what the parity gate then checks. Mutations that
    // bite: drop `expandIfFold` before the default (`:fast` dies as "must be a
    // literal"); drop the `.fold` refusal in `parseDescribe` (the block fails
    // as "expected a port name" and says nothing about folds).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using 60 as :fast
        \\using 0 as :floor
        \\using 500 as :ceiling
        \\export def roaches(rate = :fast (:floor.. :ceiling)) = rate | mul 1
        \\describe roaches
        \\    "roaches, whose default, floor and ceiling all came from folds"
        \\    rate "born per second"
        \\
        \\roaches | write plane.out
    );
    defer prog.deinit();
    const e = prog.exported("roaches").?;
    try testing.expectEqual(@as(f64, 60), types.asNumber(e.ports[0].default.?).?);
    try testing.expectEqual(@as(f64, 0), types.asNumber(e.ports[0].min.?).?);
    try testing.expectEqual(@as(f64, 500), types.asNumber(e.ports[0].max.?).?);

    // The space in `:floor.. :ceiling` is not decoration. A fold colon is
    // decided by ADJACENCY (the previous beat), and `..` is not in its
    // whitelist — so a glued `(0..:ceiling)` lexes the colon as the four
    // -year-old `.colon` and would arrive as "must be a literal, got ':'".
    // That rule stays untouched and the refusal POINTS instead. Mutation that
    // bites: delete the pointing arm in `parseDefLiteral` — the author is told
    // the wrong thing about a spelling that is one space from correct.
    try expectParseError(
        \\using 500 as :ceiling
        \\def f(x = 1 (0..:ceiling)) = x | mul 2
        \\f | tap t
    , "needs a space before its colon");

    // A fold that expands to something that is not a literal is refused where
    // it was spliced, and the chain names the fold — the previous beat's
    // provenance, paying for itself in a position that did not exist then.
    try expectParseError(
        \\using plane.k as :k
        \\def f(x = :k) = x | mul 2
        \\f | tap t
    , "expanded from :k");
    // A describe block splices nothing, and says so by name.
    try expectParseError(
        \\using rate as :p
        \\def f(rate) = rate | mul 2
        \\describe f
        \\    :p "the rate"
    , "read verbatim");
}

test "publish hook: freshened wires reach the host each tick, then go quiet" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hp | clamp 0 100 | div 100 as frac
    , .{.{ "plane.hp", @as(i64, 50) }});
    defer fx.deinit();

    const Collector = struct {
        var paths: std.ArrayListUnmanaged([]u8) = .empty;
        var gpa: std.mem.Allocator = undefined;
        fn publish(_: ?*anyopaque, path: []const u8, _: []const u8) void {
            paths.append(gpa, gpa.dupe(u8, path) catch return) catch {};
        }
        fn reset() void {
            for (paths.items) |p| gpa.free(p);
            paths.clearRetainingCapacity();
        }
    };
    Collector.gpa = testing.allocator;
    defer {
        Collector.reset();
        Collector.paths.deinit(testing.allocator);
    }
    fx.rt.publish_fn = Collector.publish;

    // a change publishes every touched slot on the chain, by stable path
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 80));
    try fx.rt.tick(.{});
    var saw_div_out = false;
    for (Collector.paths.items) |p| {
        if (std.mem.eql(u8, p, "programs.p.div1.out.out")) saw_div_out = true;
    }
    try testing.expect(saw_div_out);
    try testing.expect(Collector.paths.items.len >= 4); // clamp in/out, div in/out at least

    // suppression means silence: same value again publishes nothing
    Collector.reset();
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 80));
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(usize, 0), Collector.paths.items.len);
}

// ---------------------------------------------------------------------------
// §3.11 tail ports — the console's `rest` grammar, landed in core before any
// Matryoshka handler leans on it (adoption doc D6).
// ---------------------------------------------------------------------------

/// Mounts `source` over an empty plane and asserts the named slot holds
/// exactly the struple string `expected` after tick 0.
fn expectTailEcho(source: []const u8, slot_path: []const u8, expected: []const u8) !void {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, source, .{});
    defer fx.deinit();
    const bytes = fx.rt.readSlot(slot_path) orelse return error.TestUnexpectedResult;
    const want = blk: {
        var pk = struple.Packer.init(testing.allocator);
        defer pk.deinit();
        try pk.appendString(expected);
        break :blk try pk.toOwnedSlice();
    };
    defer testing.allocator.free(want);
    try testing.expectEqualSlices(u8, want, bytes);
}

test "tail: rest of line is captured verbatim — slashes, colons, hashes are text" {
    try expectTailEcho("sound play /tmp/loop.wav", "programs.p.sound play1.out.out", "/tmp/loop.wav");
    try expectTailEcho("sound play pack:horns#audio.stem", "programs.p.sound play1.out.out", "pack:horns#audio.stem");
    try expectTailEcho("sound play --gain 0.5 it's freeform", "programs.p.sound play1.out.out", "--gain 0.5 it's freeform");
}

test "tail: the fixed prefix binds positionally, piped or not" {
    // statics then ports, then the rest: `emitter drop <name> <gain> <locator…>`
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "emitter drop e1 0.5 /tmp/a.wav", .{});
    defer fx.deinit();
    const n = fx.prog.node(0);
    try testing.expectEqualStrings("e1", n.statics[0].word);
    try testing.expectEqual(@as(f64, 0.5), types.asNumber(fx.prog.slot(n.inputs[0]).source.literal).?);
    try testing.expectEqualStrings("/tmp/a.wav", types.asString(fx.prog.slot(n.inputs[1]).source.literal).?);

    // the pipe feeds port 0, so the prefix shrinks by one
    var fx2: Fixture = undefined;
    try mountFixture(testing.allocator, &fx2, "0.5 | emitter drop e2 /tmp/b.wav", .{});
    defer fx2.deinit();
    const n2 = fx2.prog.node(0);
    try testing.expectEqualStrings("e2", n2.statics[0].word);
    try testing.expectEqualStrings("/tmp/b.wav", types.asString(fx2.prog.slot(n2.inputs[1]).source.literal).?);
}

test "tail: a pipe in the tail fails loud, spaced or not" {
    try expectParseError("sound play boom.wav | tap t", "tail port consumed a pipe");
    try expectParseError("sound play boom.wav|tap t", "tail port consumed a pipe");
}

test "tail: a fully-quoted tail is the escape hatch — unwrap, unescape, pipes welcome" {
    try expectTailEcho(
        \\sound play "weird | name.wav"
    , "programs.p.sound play1.out.out", "weird | name.wav");
    try expectTailEcho(
        \\sound play "line one\nline two"
    , "programs.p.sound play1.out.out", "line one\nline two");
    // a *partial* quote is not the escape hatch: verbatim, quotes included
    try expectTailEcho(
        \\sound play "half quoted" rest
    , "programs.p.sound play1.out.out", "\"half quoted\" rest");
}

test "tail: required tail missing errors; optional tail absent is null" {
    try expectParseError("sound play", "expects text for its tail port");
    try expectTailEcho("say", "programs.p.say1.out.out", "<none>");
    try expectTailEcho("say something nice", "programs.p.say1.out.out", "something nice");
}

test "tail: the tail ends the chain — as is text, not a binding" {
    try expectTailEcho("sound play boom.wav as s", "programs.p.sound play1.out.out", "boom.wav as s");
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    const result = rill.parse(testing.allocator, &reg, "p",
        \\sound play boom.wav as s
        \\s | tap t
    , &diag);
    try testing.expectError(error.Parse, result); // `s` never became a name
}

test "tail: closed at the joints — no sections, no piping into a tail-only op" {
    try expectParseError("cube 2 | where (sound play x)", "cannot be a predicate section");
    try expectParseError("plane.hp | sound play boom.wav", "its only port is the tail");
}

test "tail: raw characters outside a tail still fail loud" {
    // a leading '/' is no word start — still a loud raw character
    try expectParseError("cube 2 | bevel /tmp/x", "unexpected '/' in arguments");
    // slash-in-word tokenizes as one word, but a number port still refuses it
    try expectParseError("cube 2 | bevel render/grade", "unknown name 'render/grade'");
}

test "console words: knob-path arguments ride the slash-in-word coercion" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "emitter mode render/grade/exposure loop", &diag);
    defer prog.deinit();
    try testing.expectEqualStrings("render/grade/exposure", types.asString(prog.slot(prog.node(0).inputs[0]).source.literal).?);
}

test "console words: '/' never makes a division-shaped surprise" {
    // after a number, '/' is a raw byte — `1/2` is not a word and not a
    // quotient, it is a loud error
    try expectParseError("add 1/2", "unexpected '/' in arguments");
    // after a name-start, the slash glues into one word — which a number
    // port then refuses by name, loudly
    try expectParseError("add x/2", "unknown name 'x/2'");
}

test "console words: a number-typed local at a string port is a type error, never a coercion" {
    // `v1` is a live number stream; `volume set` wants a string name at
    // port 0. The local wins resolution and fails the type check — the
    // word→string coercion must never paper over a name collision.
    try expectParseError(
        \\cube 2 | bevel 0.1 as v1
        \\volume set v1 0.5 2 1
    , "expected string, got mesh");
}

test "console words: the '-' unbind sentinel is a word; negative numbers survive" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "volume set - -1.5 2 1", &diag);
    defer prog.deinit();
    const n = prog.node(0);
    try testing.expectEqualStrings("-", types.asString(prog.slot(n.inputs[0]).source.literal).?);
    try testing.expectEqual(@as(f64, -1.5), types.asNumber(prog.slot(n.inputs[1]).source.literal).?);
}

// ---------------------------------------------------------------------------
// Console words (D5): bare words bind string ports as string literals; the
// port type keeps the coercion narrow. `one_of` enforces enum args at parse.
// ---------------------------------------------------------------------------

test "console words: a bare word binds a string-typed port as a string literal" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "volume set v1 0.5 2 1", &diag);
    defer prog.deinit();
    const n = prog.node(0);
    try testing.expectEqualStrings("v1", types.asString(prog.slot(n.inputs[0]).source.literal).?);
    try testing.expectEqual(@as(f64, 0.5), types.asNumber(prog.slot(n.inputs[1]).source.literal).?);
    // kwarg spelling coerces identically
    var prog2 = try rill.parse(testing.allocator, &reg, "p", "volume set name: v2 0.5 2 1", &diag);
    defer prog2.deinit();
    try testing.expectEqualStrings("v2", types.asString(prog2.slot(prog2.node(0).inputs[0]).source.literal).?);
}

test "console words: unknown words stay loud everywhere else" {
    // a word aimed at a number port is not a string in disguise
    try expectParseError("cube 2 | bevel soft", "unknown name 'soft'");
    // bound names still shadow the coercion: v1 resolves to its binding
    // ("hello"), not to the text "v1" the coercion would have produced
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\"hello" as v1
        \\volume set v1 0.5 2 1
    , &diag);
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "volume set1").?);
    try testing.expectEqualStrings("hello", types.asString(prog.slot(n.inputs[0]).source.literal).?);
}

test "one_of: enum args are enforced at parse, quoted or bare" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "emitter mode e1 loop", &diag);
    defer prog.deinit();
    try testing.expectEqualStrings("loop", types.asString(prog.slot(prog.node(0).inputs[1]).source.literal).?);
    try expectParseError("emitter mode e1 wobble", "not an allowed value");
    try expectParseError(
        \\emitter mode e1 "wobble"
    , "not an allowed value");
}

test "host context is live at tick 0 — one-shot command programs depend on it" {
    // A host-seeded effect op that counts its evals through EvalCtx.host.
    // Mount runs tick 0, so the count must be 1 before any explicit tick —
    // this is the exact contract one-shot console dispatch (mount → effects
    // → unmount) stands on.
    const pokeEval = struct {
        fn f(ctx: *rill.EvalCtx) registry.EvalError!registry.Emit {
            const count: *usize = @ptrCast(@alignCast(ctx.host orelse return error.BadValue));
            count.* += 1;
            return registry.Emit.none;
        }
    }.f;
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const in_num = [_]registry.Port{.{ .name = "v", .ty = types.Tag.number }};
    _ = try reg.register(.{ .name = "poke", .inputs = &in_num, .help = "stub", .class = .effect, .routes = .anywhere, .eval = pokeEval });

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "poke 7", &diag);
    defer prog.deinit();

    var count: usize = 0;
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .host_ctx = &count });
    defer rt.deinit();
    try testing.expectEqual(@as(usize, 1), count);
}

test "tail: dump → load → dump survives a tail literal byte-identically" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "sound play pack:horns#audio.stem", .{});
    defer fx.deinit();
    const dump1 = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(dump1);
    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, dump1);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.restoreState(&rt2, dump1);
    const dump2 = try rill.dump(&rt2, testing.allocator);
    defer testing.allocator.free(dump2);
    try testing.expectEqualSlices(u8, dump1, dump2);
}

// ---------------------------------------------------------------------------
// Temporal operators (agents doc §2) — time is fed, ambient, wheel-delivered.
// Every clock in this section is a script; the suite contains no sleeps.
// ---------------------------------------------------------------------------

const ms = std.time.ns_per_ms;

fn tickAt(fx: *Fixture, ns: u64) !void {
    try fx.rt.tick(.{ .time_ns = ns });
}

fn slotNum(fx: *Fixture, path: []const u8) ?f64 {
    const v = fx.rt.readSlot(path) orelse return null;
    return types.asNumber(v);
}

/// What the mock plane holds at `path`, as a number — failing with words
/// rather than a null-unwrap panic. A panic aborts the whole test BINARY, so
/// a gate that panics under a mutation hides every gate after it; that is a
/// bad property for a suite whose job is to say WHICH gates a mutation bit.
fn planeNum(fx: *Fixture, path: []const u8) !f64 {
    const bytes = fx.mock.store.get(path) orelse {
        std.debug.print("nothing reached '{s}'\n", .{path});
        return error.TestUnexpectedResult;
    };
    return types.asNumber(bytes) orelse {
        std.debug.print("'{s}' holds something that is not a number\n", .{path});
        return error.TestUnexpectedResult;
    };
}

test "durations: literals encode lane and count canonically" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.a | sample 5s as d1
        \\plane.a | sample 250ms as d2
        \\plane.a | sample 2m as d3
        \\plane.a | sample 3f as d4
        \\plane.a | sample 2.5s as d5
    , &diag);
    defer prog.deinit();
    const expect = [_]struct { []const u8, bool, u64 }{
        .{ "sample1", false, 5_000_000_000 },
        .{ "sample2", false, 250_000_000 },
        .{ "sample3", false, 120_000_000_000 },
        .{ "sample4", true, 3 },
        .{ "sample5", false, 2_500_000_000 },
    };
    for (expect) |e| {
        const n = prog.node(nodeIdOf(&prog, e[0]).?);
        const lit = prog.slot(n.inputs[1]).source.literal;
        const d = types.asDuration(lit).?;
        try testing.expectEqual(e[1], d.frames);
        try testing.expectEqual(e[2], d.count);
    }
}

test "durations: bad spellings are loud, each with its own message" {
    try expectParseError("plane.a | sample 5", "takes a duration");
    try expectParseError("add 5s 1", "expected number, got duration");
    try expectParseError("plane.a | sample 5x", "unknown duration unit 'x'");
    try expectParseError("plane.a | sample 2.5f", "whole frames");
    try expectParseError("plane.a | sample -5s", "cannot be negative");
}

test "sample: leading edge immediate, trailing edge via the wheel, quiet is free" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.v | sample 100ms as s
    , .{.{ "plane.v", @as(i64, 1) }});
    defer fx.deinit();
    const out = "programs.p.sample1.out.out";
    const sid = nodeIdOf(&fx.prog, "sample1").?;
    // mount (t=0): leading edge passes
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);

    // changes inside the window coalesce to the latest, nothing emits yet
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(i64, 2));
    try tickAt(&fx, 10 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(i64, 3));
    try tickAt(&fx, 50 * ms);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);

    // mid-window quiet ticks cost zero evaluations — the wheel is the only
    // subscription to time
    const evals = fx.rt.eval_count[sid];
    try tickAt(&fx, 60 * ms);
    try tickAt(&fx, 99 * ms);
    try testing.expectEqual(evals, fx.rt.eval_count[sid]);

    // the period boundary delivers the trailing edge
    try tickAt(&fx, 100 * ms);
    try testing.expectEqual(@as(f64, 3), slotNum(&fx, out).?);
}

test "debounce: a storm collapses to its last edge, emitted once after quiet" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.e | debounce 50ms | tap t
    , .{});
    defer fx.deinit();
    const out = "programs.p.tap1.out.out";
    const tap = nodeIdOf(&fx.prog, "tap1").?;
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 1));
    try tickAt(&fx, 1 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 2));
    try tickAt(&fx, 2 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 3));
    try tickAt(&fx, 3 * ms);
    try testing.expect(fx.rt.readSlot(out) == null); // storm still raging
    // superseded wheel entries stale-fire into silence and re-arm the truth
    try tickAt(&fx, 51 * ms);
    try tickAt(&fx, 52 * ms);
    try testing.expect(fx.rt.readSlot(out) == null);
    try tickAt(&fx, 53 * ms);
    try testing.expectEqual(@as(f64, 3), slotNum(&fx, out).?);
    try testing.expectEqual(@as(u64, 1), fx.rt.eval_count[tap]); // once, not thrice
}

test "throttle: first passes, the window eats the rest" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.e | throttle 50ms | tap t
    , .{});
    defer fx.deinit();
    const out = "programs.p.tap1.out.out";
    const tap = nodeIdOf(&fx.prog, "tap1").?;
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 1));
    try tickAt(&fx, 1 * ms);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 2));
    try tickAt(&fx, 10 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 3));
    try tickAt(&fx, 40 * ms);
    try testing.expectEqual(@as(u64, 1), fx.rt.eval_count[tap]); // both eaten
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 4));
    try tickAt(&fx, 60 * ms);
    try testing.expectEqual(@as(f64, 4), slotNum(&fx, out).?);
    try testing.expectEqual(@as(u64, 2), fx.rt.eval_count[tap]);
}

test "window + stats: a spike decays on schedule with no input at all" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.n | window 100ms | stats as t
    , .{});
    defer fx.deinit();
    const out = "programs.p.stats1.out.out";
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, 5));
    try tickAt(&fx, 0);
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, 9));
    try tickAt(&fx, 10 * ms);

    const rec1 = fx.rt.readSlot(out).?;
    const inner1 = try (struple.view(rec1).containedItems(testing.allocator));
    defer testing.allocator.free(inner1.?);
    const m1 = struple.MapView.init(inner1.?);
    var kp = struple.Packer.init(testing.allocator);
    defer kp.deinit();
    try kp.appendString("max");
    try testing.expectEqual(@as(f64, 9), types.asNumber((try m1.get(kp.bytes())).?).?);
    kp.reset();
    try kp.appendString("mean");
    try testing.expectEqual(@as(f64, 7), types.asNumber((try m1.get(kp.bytes())).?).?);
    kp.reset();
    try kp.appendString("n");
    try testing.expectEqual(@as(f64, 2), types.asNumber((try m1.get(kp.bytes())).?).?);

    // t=105ms: the 5 (stamped t=0) aged out through the wheel; the 9 remains
    try tickAt(&fx, 105 * ms);
    const rec2 = fx.rt.readSlot(out).?;
    const inner2 = try (struple.view(rec2).containedItems(testing.allocator));
    defer testing.allocator.free(inner2.?);
    const m2 = struple.MapView.init(inner2.?);
    kp.reset();
    try kp.appendString("mean");
    try testing.expectEqual(@as(f64, 9), types.asNumber((try m2.get(kp.bytes())).?).?);

    // t=115ms: empty window — zeros with n = 0, so a crossing detector re-arms
    try tickAt(&fx, 115 * ms);
    const rec3 = fx.rt.readSlot(out).?;
    const inner3 = try (struple.view(rec3).containedItems(testing.allocator));
    defer testing.allocator.free(inner3.?);
    const m3 = struple.MapView.init(inner3.?);
    kp.reset();
    try kp.appendString("max");
    try testing.expectEqual(@as(f64, 0), types.asNumber((try m3.get(kp.bytes())).?).?);
    kp.reset();
    try kp.appendString("n");
    try testing.expectEqual(@as(f64, 0), types.asNumber((try m3.get(kp.bytes())).?).?);
}

test "delay: occurrences arrive late; same-tick maturities collapse to the newest" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.e | delay 30ms | tap t
    , .{});
    defer fx.deinit();
    const out = "programs.p.tap1.out.out";
    const tap = nodeIdOf(&fx.prog, "tap1").?;

    // separated maturities deliver separately
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 1));
    try tickAt(&fx, 1 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 2));
    try tickAt(&fx, 5 * ms);
    try testing.expect(fx.rt.readSlot(out) == null);
    try tickAt(&fx, 31 * ms);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
    try tickAt(&fx, 35 * ms);
    try testing.expectEqual(@as(f64, 2), slotNum(&fx, out).?);
    try testing.expectEqual(@as(u64, 2), fx.rt.eval_count[tap]);

    // a late tick that matures both delivers only the newest
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 3));
    try tickAt(&fx, 40 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 4));
    try tickAt(&fx, 45 * ms);
    try tickAt(&fx, 200 * ms);
    try testing.expectEqual(@as(f64, 4), slotNum(&fx, out).?);
    try testing.expectEqual(@as(u64, 3), fx.rt.eval_count[tap]);
}

test "arm/disarm: the latch gates occurrences; controls latch ahead of the stream; on wins a tie" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.e | arm off: plane.stop on: plane.go | tap t
    , .{});
    defer fx.deinit();
    const out = "programs.p.tap1.out.out";
    const tap = nodeIdOf(&fx.prog, "tap1").?;

    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 1));
    try tickAt(&fx, 1 * ms);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);

    // off and the occurrence in the same tick: controls apply first
    try feedValue(&fx.rt, testing.allocator, "plane.stop", @as(i64, 1));
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 2));
    try tickAt(&fx, 2 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 3));
    try tickAt(&fx, 3 * ms);
    try testing.expectEqual(@as(u64, 1), fx.rt.eval_count[tap]);

    try feedValue(&fx.rt, testing.allocator, "plane.go", @as(i64, 1));
    try tickAt(&fx, 4 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 4));
    try tickAt(&fx, 5 * ms);
    try testing.expectEqual(@as(f64, 4), slotNum(&fx, out).?);

    // tie: both controls fire with the occurrence — on wins (fail-safe armed)
    try feedValue(&fx.rt, testing.allocator, "plane.stop", @as(i64, 2));
    try feedValue(&fx.rt, testing.allocator, "plane.go", @as(i64, 2));
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 5));
    try tickAt(&fx, 6 * ms);
    try testing.expectEqual(@as(f64, 5), slotNum(&fx, out).?);
}

test "disarm starts closed; a control ahead of the first occurrence is not lost" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.e | disarm on: plane.go | tap t
    , .{});
    defer fx.deinit();
    const out = "programs.p.tap1.out.out";
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 1));
    try tickAt(&fx, 1 * ms);
    try testing.expect(fx.rt.readSlot(out) == null);
    // `on` arrives while the stream is quiet — the latch must keep it
    try feedValue(&fx.rt, testing.allocator, "plane.go", @as(i64, 1));
    try tickAt(&fx, 2 * ms);
    try feedValue(&fx.rt, testing.allocator, "plane.e", @as(i64, 2));
    try tickAt(&fx, 3 * ms);
    try testing.expectEqual(@as(f64, 2), slotNum(&fx, out).?);
}

test "frame durations run on the frame lane; the ns clock may stand still" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.v | sample 3f as s
    , .{.{ "plane.v", @as(i64, 1) }});
    defer fx.deinit();
    const out = "programs.p.sample1.out.out";
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(i64, 2));
    try fx.rt.tick(.{ .frame = 1 });
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
    try fx.rt.tick(.{ .frame = 3 }); // time_ns still 0 — frames are the unit
    try testing.expectEqual(@as(f64, 2), slotNum(&fx, out).?);
}

test "fed time is a contract: a regression on either lane errors loud, never clamps" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.v | add 0 as a
    , .{.{ "plane.v", @as(i64, 1) }});
    defer fx.deinit();
    try fx.rt.tick(.{ .frame = 5, .time_ns = 100 });
    try testing.expectError(error.TimeRegression, fx.rt.tick(.{ .frame = 5, .time_ns = 50 }));
    try testing.expectError(error.TimeRegression, fx.rt.tick(.{ .frame = 4, .time_ns = 200 }));
    try fx.rt.tick(.{ .frame = 5, .time_ns = 100 }); // equal is fine: non-decreasing
}

test "G8 extends to time: a program restored mid-window stays the same distance from its deadline" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.v | sample 100ms as s
        \\plane.e | cooldown 100ms | tap c
    , .{ .{ "plane.v", @as(i64, 1) }, .{ "plane.e", @as(i64, 1) } });
    defer fx.deinit();
    // t=40ms: sample holds a pending 2, wheel armed for t=100ms; the
    // cooldown that fired at mount is deaf until t=100ms
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(i64, 2));
    try tickAt(&fx, 40 * ms);

    const dump1 = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(dump1);
    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, dump1);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.restoreState(&rt2, dump1);

    // the dump is bit-stable through the round trip (now + wheel included)
    const dump2 = try rill.dump(&rt2, testing.allocator);
    defer testing.allocator.free(dump2);
    try testing.expectEqualSlices(u8, dump1, dump2);

    // 60ms out from the save, both runtimes fire their trailing edge on the
    // same tick — and an occurrence inside the remaining cooldown is eaten
    // by both
    const s_out = "programs.p.sample1.out.out";
    try feedValue(&rt2, testing.allocator, "plane.e", @as(i64, 2));
    try rt2.tick(.{ .time_ns = 70 * ms });
    try testing.expectEqual(@as(u64, 1), rt2.eval_count[nodeIdOf(&prog2, "tap1").?]);
    try rt2.tick(.{ .time_ns = 100 * ms });
    try testing.expectEqual(@as(f64, 2), types.asNumber(rt2.readSlot(s_out).?).?);
    try tickAt(&fx, 100 * ms);
    try testing.expectEqual(@as(f64, 2), slotNum(&fx, s_out).?);
    try testing.expectEqualSlices(u8, fx.rt.readSlot(s_out).?, rt2.readSlot(s_out).?);
}

test "a rill mounted mid-session baselines at the mount moment, not zero" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.v", @as(i64, 1));
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.v | sample 100ms as s
    , &diag);
    defer prog.deinit();
    const t0: u64 = 1000 * std.time.ns_per_s;
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .now = .{ .time_ns = t0 } });
    defer rt.deinit();
    const out = "programs.p.sample1.out.out";
    try testing.expectEqual(@as(f64, 1), types.asNumber(rt.readSlot(out).?).?);
    // 50ms after mount is mid-window — a zero baseline would emit here
    const enc = try packOne(testing.allocator, @as(i64, 2));
    defer testing.allocator.free(enc);
    try rt.feed(.{ .path = "plane.v", .value = enc });
    try rt.tick(.{ .time_ns = t0 + 50 * ms });
    try testing.expectEqual(@as(f64, 1), types.asNumber(rt.readSlot(out).?).?);
    try rt.tick(.{ .time_ns = t0 + 100 * ms });
    try testing.expectEqual(@as(f64, 2), types.asNumber(rt.readSlot(out).?).?);
}

test "the guard's other half: a required port still blocks until its stream arrives" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.a | add plane.b as x
    , .{.{ "plane.a", @as(i64, 1) }});
    defer fx.deinit();
    const out = "programs.p.add1.out.out";
    const add_id = nodeIdOf(&fx.prog, "add1").?;
    // plane.b has never produced: the node waits — no eval, no half-fed output
    // (the optional-ports-read-null ruling must not have widened into this)
    try testing.expectEqual(@as(u64, 0), fx.rt.eval_count[add_id]);
    try testing.expect(fx.rt.readSlot(out) == null);
    try feedValue(&fx.rt, testing.allocator, "plane.b", @as(i64, 2));
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(f64, 3), slotNum(&fx, out).?);
}

// ---------------------------------------------------------------------------
// OpClass.reads — the third state. A host op that reads the world through a
// path static is not a writer, so it must stay out of the program's write
// list; the same shape declared `.effect` still trips the cycle check. Both
// sides, because the write list IS what the cycle check reads and a silent
// exit from it is the failure mode this codebase doesn't accept.
// ---------------------------------------------------------------------------

test "OpClass: a reads op with a path static is not a writer; effect is" {
    const nop = struct {
        fn f(_: *rill.EvalCtx) registry.EvalError!registry.Emit {
            return registry.Emit.none;
        }
    }.f;
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const in_num = [_]registry.Port{.{ .name = "v", .ty = types.Tag.number }};
    const path_static = [_]registry.StaticDecl{.{ .name = "path", .kind = .path }};
    _ = try reg.register(.{ .name = "probeat", .inputs = &in_num, .statics = &path_static, .help = "stub", .class = .reads, .routes = .anywhere, .eval = nop });
    _ = try reg.register(.{ .name = "pokeat", .inputs = &in_num, .statics = &path_static, .help = "stub", .class = .effect, .routes = .anywhere, .eval = nop });

    // the reader names the very path the program subscribes to: no write, no cycle
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "plane.x | probeat plane.x", &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 0), prog.writes.items.len);

    // the same shape declared `.effect` is a writer, and the cycle check sees it
    var diag2 = rill.Diag{};
    try testing.expectError(error.Parse, rill.parse(testing.allocator, &reg, "p", "plane.x | pokeat plane.x", &diag2));
    try testing.expect(std.mem.indexOf(u8, diag2.msg(), "cycle") != null);
}

// ---------------------------------------------------------------------------
// The program's result slot — what a one-shot console line echoes when its
// last statement is an expression rather than a sink (rillbook §2). A core
// effect line echoes the value that flowed into its sink, since 2026-09-08 —
// see "a sink-terminated line now HAS a result" at the end of this file. A
// HOST verb that declares no outputs still echoes nothing, and its
// acknowledgement stands alone rather than a fabricated value.
// ---------------------------------------------------------------------------

test "resultSlot: an expression line has a value; an effect line has none" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.a | add 1 | mul 3
    , .{.{ "plane.a", @as(i64, 4) }});
    defer fx.deinit();
    const sid = fx.prog.resultSlot() orelse return error.TestUnexpectedResult;
    // the LAST node's output, not the first: (4 + 1) * 3
    try testing.expectEqual(@as(f64, 15), types.asNumber(fx.rt.readSlotId(sid).?).?);

    // a sink-terminated line: `set` produces nothing, so the result is the
    // expression feeding it — never the write itself
    var fx2: Fixture = undefined;
    try mountFixture(testing.allocator, &fx2,
        \\plane.a | add 1 | write plane.out
    , .{.{ "plane.a", @as(i64, 4) }});
    defer fx2.deinit();
    const sid2 = fx2.prog.resultSlot() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f64, 5), types.asNumber(fx2.rt.readSlotId(sid2).?).?);
}

// ---------------------------------------------------------------------------
// Hyphens in names. Found 2026-08-24 by Chris dragging a light in the web
// scene view: nothing moved, and (because a bare verb acked nowhere) nothing
// said why. `key-light` was arriving as three tokens, so every hyphenated
// entity an authoring tool produces was unsayable from the console.
// ---------------------------------------------------------------------------

test "hyphen is name-interior, and the lone `-` sentinel survives it" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};

    // one word: a four-port row takes it as ONE argument, not three
    var prog = try rill.parse(testing.allocator, &reg, "p", "volume set key-light 1 2 3", &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.nodeCount());

    // interior digits are fine too (`cam-2` is a name, not arithmetic — rill
    // has no infix minus, so there is nothing for it to collide with)
    var diag2 = rill.Diag{};
    var prog2 = try rill.parse(testing.allocator, &reg, "p", "volume set cam-2 1 2 3", &diag2);
    defer prog2.deinit();
    try testing.expectEqual(@as(usize, 1), prog2.nodeCount());

    // the sentinel is untouched: a lone `-` is still its own word
    var diag3 = rill.Diag{};
    var prog3 = try rill.parse(testing.allocator, &reg, "p", "volume set - 1 2 3", &diag3);
    defer prog3.deinit();
    try testing.expectEqual(@as(usize, 1), prog3.nodeCount());

    // and a negative number is still a number, not a name
    var diag4 = rill.Diag{};
    var prog4 = try rill.parse(testing.allocator, &reg, "p", "volume set v1 -1.5 2 3", &diag4);
    defer prog4.deinit();
    try testing.expectEqual(@as(usize, 1), prog4.nodeCount());

    // a TRAILING hyphen still separates: `v1-` is the name then the sentinel,
    // so an unbind written tight against a name keeps meaning unbind
    var diag5 = rill.Diag{};
    try testing.expectError(error.Parse, rill.parse(testing.allocator, &reg, "p", "volume set v1- 1 2 3", &diag5));
}

// ---------------------------------------------------------------------------
// §6.2 — an operator failure is REPORTABLE, not just counted. The wave still
// dies at the node; this is the seam a host publishes an occurrence from.
// ---------------------------------------------------------------------------

const ErrSink = struct {
    var hits: usize = 0;
    var last: rill.eval.ErrorEvent = undefined;
    fn on(_: ?*anyopaque, ev: rill.eval.ErrorEvent) void {
        hits += 1;
        last = ev;
    }
};

test "error hook: a failing op reports node, op, tick and a stable input digest" {
    const boom = struct {
        fn f(_: *rill.EvalCtx) registry.EvalError!registry.Emit {
            return error.BadValue;
        }
    }.f;
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const in_num = [_]registry.Port{.{ .name = "v", .ty = types.Tag.number }};
    _ = try reg.register(.{ .name = "boom", .inputs = &in_num, .help = "stub", .class = .effect, .routes = .anywhere, .eval = boom });

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "plane.v | boom", &diag);
    defer prog.deinit();

    ErrSink.hits = 0;
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{
        .error_fn = ErrSink.on,
        .now = .{ .frame = 7 },
    });
    defer rt.deinit();

    // plane.v has never produced, so tick 0 evaluates nothing and nothing failed
    try testing.expectEqual(@as(usize, 0), ErrSink.hits);

    try feedValue(&rt, testing.allocator, "plane.v", @as(i64, 3));
    try rt.tick(.{ .frame = 8 });
    try testing.expectEqual(@as(usize, 1), ErrSink.hits);
    try testing.expectEqualStrings("boom1", ErrSink.last.node);
    try testing.expectEqualStrings("boom", ErrSink.last.op);
    try testing.expectEqualStrings("BadValue", ErrSink.last.err);
    try testing.expectEqual(@as(u64, 8), ErrSink.last.frame);
    const digest_of_3 = ErrSink.last.input_digest;

    // the SAME inputs digest the same — "this failed again the same way" is
    // answerable without keeping the inputs
    try feedValue(&rt, testing.allocator, "plane.v", @as(i64, 4));
    try rt.tick(.{ .frame = 9 });
    try testing.expectEqual(@as(usize, 2), ErrSink.hits);
    try testing.expect(ErrSink.last.input_digest != digest_of_3);
    try feedValue(&rt, testing.allocator, "plane.v", @as(i64, 3));
    try rt.tick(.{ .frame = 10 });
    try testing.expectEqual(digest_of_3, ErrSink.last.input_digest);

    // and the counter kept counting either way — the hook reports, it does not replace
    const bid = nodeIdOf(&prog, "boom1").?;
    try testing.expectEqual(@as(u64, 3), rt.error_count[bid]);
}

// ---------------------------------------------------------------------------
// Occurrence rounds (§4.1 as amended). A tick runs one round per queued
// occurrence per path: values coalesce across the tick, occurrences never do.
// Three enemies must reach the attacker as three.
// ---------------------------------------------------------------------------

fn garrisonRun(gpa: std.mem.Allocator, mock: *rill.MockPlane, prog: *rill.Program, out_evals: *u64) ![]u8 {
    var rt = try rill.Runtime.mount(gpa, prog, mock.asPlane(), .{});
    defer rt.deinit();
    // three identical sightings, all inside ONE tick
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const enc = try packOne(gpa, @as(i64, 1));
        defer gpa.free(enc);
        try rt.feed(.{ .path = "plane.alerts", .value = enc, .kind = .occurrence });
    }
    try rt.tick(.{ .frame = 1, .time_ns = 1000 });
    const tap_id = nodeIdOf(prog, "tap1").?;
    out_evals.* = rt.eval_count[tap_id];
    return rill.dump(&rt, gpa);
}

test "occurrence rounds: three sightings in one tick rouse the node three times" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "garrison", "plane.alerts | tap attack", &diag);
    defer prog.deinit();

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var evals_a: u64 = 0;
    const dump_a = try garrisonRun(testing.allocator, &mock, &prog, &evals_a);
    defer testing.allocator.free(dump_a);

    // Identical bytes, three times, one tick: three rousings. Under the old
    // rule the feed coalesced them to one and suppression silenced that one.
    try testing.expectEqual(@as(u64, 3), evals_a);

    // THE DETERMINISM TWIN: the same script fed twice produces bit-identical
    // state. Extra rounds must not be a place divergence can hide — round
    // order and queue order are both arrival order, and this is what says so.
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var evals_b: u64 = 0;
    const dump_b = try garrisonRun(testing.allocator, &mock2, &prog, &evals_b);
    defer testing.allocator.free(dump_b);
    try testing.expectEqual(evals_a, evals_b);
    try testing.expectEqualSlices(u8, dump_a, dump_b);
}

test "occurrence rounds: values still coalesce across the whole tick" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "plane.v | tap seen", &diag);
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    // three VALUE deltas in one tick: the tick's state is the last one, and the
    // node is roused once. The other half of the amended rule.
    for ([_]i64{ 1, 2, 3 }) |n| {
        const enc = try packOne(testing.allocator, n);
        defer testing.allocator.free(enc);
        try rt.feed(.{ .path = "plane.v", .value = enc });
    }
    try rt.tick(.{ .frame = 1 });
    const tap_id = nodeIdOf(&prog, "tap1").?;
    try testing.expectEqual(@as(u64, 1), rt.eval_count[tap_id]);
    try testing.expectEqual(@as(f64, 3), types.asNumber(rt.readSlot("programs.p.tap1.out.out").?).?);
}

// ---------------------------------------------------------------------------
// §3.14 — `also { … }`: fan-out spelled inline. Every gate below is a parse-
// time property; the evaluator was not told this syntax exists.
// ---------------------------------------------------------------------------

/// Parse expecting success, printing the diagnostic if it isn't.
fn parseOk(gpa: std.mem.Allocator, reg: *rill.Registry, source: []const u8) !rill.Program {
    var diag = rill.Diag{};
    return rill.parse(gpa, reg, "p", source, &diag) catch |err| {
        if (err == error.Parse) std.debug.print("parse: {s} (line {d}, col {d})\n", .{ diag.msg(), diag.line, diag.col });
        return err;
    };
}

test "also: the branch leaves from the very slot the main wire continues from" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | rose_above 0 | also { write plane.log } | tap seen");
    defer prog.deinit();

    const upstream = prog.node(nodeIdOf(&prog, "rose_above1").?).outputs[0];
    const set_in = prog.slot(prog.node(nodeIdOf(&prog, "write1").?).inputs[0]);
    const tap_in = prog.slot(prog.node(nodeIdOf(&prog, "tap1").?).inputs[0]);

    // Identity on the stream is not an op that promises to return its input —
    // it is the same SlotId on both edges. There is nothing to get wrong.
    try testing.expectEqual(upstream, set_in.source.wire);
    try testing.expectEqual(upstream, tap_in.source.wire);
    try testing.expectEqual(@as(usize, 0), prog.warnings.items.len);

    // And the block really is downstream: one slot, two readers.
    try testing.expectEqual(@as(usize, 2), prog.downstream[upstream].len);
}

test "also: N occurrences run the block N times" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.alerts | also { write plane.log } | tap attack");
    defer prog.deinit();

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const enc = try packOne(testing.allocator, @as(i64, 1));
        defer testing.allocator.free(enc);
        try rt.feed(.{ .path = "plane.alerts", .value = enc, .kind = .occurrence });
    }
    try rt.tick(.{ .frame = 1, .time_ns = 1000 });

    // The side branch is roused exactly as often as the main wire, because
    // the rounds machinery cannot tell them apart — which is the point.
    try testing.expectEqual(@as(u64, 3), rt.eval_count[nodeIdOf(&prog, "write1").?]);
    try testing.expectEqual(@as(u64, 3), rt.eval_count[nodeIdOf(&prog, "tap1").?]);
    try testing.expectEqual(@as(usize, 3), mock.writes.items.len);
}

test "also: a multi-statement block is more branches off the same slot" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.hp | rose_above 0
        \\  | also {
        \\      write plane.a
        \\      write plane.b
        \\    }
        \\  | tap seen
    );
    defer prog.deinit();

    const upstream = prog.node(nodeIdOf(&prog, "rose_above1").?).outputs[0];
    try testing.expectEqual(upstream, prog.slot(prog.node(nodeIdOf(&prog, "write1").?).inputs[0]).source.wire);
    try testing.expectEqual(upstream, prog.slot(prog.node(nodeIdOf(&prog, "write2").?).inputs[0]).source.wire);
    try testing.expectEqual(@as(usize, 3), prog.downstream[upstream].len);
}

test "also: the block's writes join the write list — the cycle check sees through it" {
    try expectParseError("plane.x | rose_above 0 | also { write plane.x } | tap t", "cycle");
}

test "also: no name escapes the block" {
    try expectParseError("plane.hp | also { mul 2 as doubled } | tap t", "no name escapes");
    // …including where a branch on its own line makes `as` look terminal.
    try expectParseError(
        \\plane.hp | also {
        \\    mul 2 as doubled
        \\  } | tap t
    , "no name escapes");
}

test "also: a branch that ends holding a value warns, and parses on" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | also { mul 2 } | tap seen");
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, prog.warnings.items[0].msg, "discards a value") != null);
    try testing.expectEqual(@as(u32, 1), prog.warnings.items[0].line);
}

test "also: a branch ending in an effect never warns, value or no value" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    // `set` yields nothing; `emitter mode` is an effect that still hands a
    // value back. Neither discarded anything — both wrote.
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.hp | also { write plane.a } | tap seen
        \\plane.hp | also { emitter mode ambient } | tap heard
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 0), prog.warnings.items.len);
}

test "also: the shapes that cannot mean anything are refused" {
    // A block with no branch passes the value along and does nothing.
    try expectParseError("plane.hp | also { } | tap t", "empty block");
    // Nothing to branch off.
    try expectParseError("also { write plane.a }", "needs a value to pass along");
    try expectParseError("plane.hp | also { also { write plane.a } }", "needs a value to pass along");
    // A branch head that isn't an operator was never wired to the source, so
    // it could never rouse — the silent failure this syntax exists to avoid.
    try expectParseError("plane.hp | also { plane.other | write plane.a } | tap t", "begin with an operator");
    try expectParseError("plane.hp | also { 42 | write plane.a } | tap t", "begin with an operator");
    try expectParseError("plane.hp | also { write plane.a", "unclosed block");
    // `also` is the syntax's word, so it cannot also be a stream's.
    try expectParseError("plane.hp | mul 2 as also", "reserved");
}

test "also: a tail operator on one line would eat the closing brace" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    const bad = rill.parse(testing.allocator, &reg, "p", "plane.hp | also { emitter drop em1 /tmp/a.wav } | tap t", &diag);
    try testing.expectError(error.Parse, bad);
    try testing.expect(std.mem.indexOf(u8, diag.msg(), "own line") != null);

    // The named fix: the tail gets its own line, and takes the rest of it.
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.hp | also {
        \\    emitter drop em1 /tmp/a.wav
        \\  } | tap t
    );
    defer prog.deinit();
    try testing.expect(nodeIdOf(&prog, "emitter drop1") != null);
}

test "also: a record argument still closes its own brace" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | also { latch trigger: plane.tick | write plane.a } | tap t");
    defer prog.deinit();
    try testing.expect(nodeIdOf(&prog, "latch1") != null);
}

test "registry: a reserved word cannot name an operator" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    const noop = struct {
        fn eval(ctx: *rill.EvalCtx) registry.EvalError!registry.Emit {
            _ = ctx;
            return registry.Emit.none;
        }
    }.eval;
    try testing.expectError(error.ReservedName, reg.register(.{ .name = "also", .help = "", .routes = .anywhere, .eval = noop }));
    try testing.expectError(error.ReservedName, reg.register(.{ .name = "as", .help = "", .routes = .anywhere, .eval = noop }));
    // Whole words only: a two-word host row is checked word by word, because
    // the parser's two-word lookup never sees the halves on their own.
    try testing.expectError(error.ReservedName, reg.register(.{ .name = "light as", .help = "", .routes = .anywhere, .eval = noop }));
    _ = try reg.register(.{ .name = "alsorun", .help = "", .routes = .anywhere, .eval = noop });
}

// ---------------------------------------------------------------------------
// `inc` — the third write kind. Counters were inexpressible: `plane.x | add 1
// | write plane.x` reads a path it writes and §4.4 rightly refuses it.
// ---------------------------------------------------------------------------

test "inc: each rousing adds `by`, and the amount is never the in-flowing value" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.sighting | inc plane.tally 1");
    defer prog.deinit();

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    // The rousing carries 99. The tally must rise by 1, not by 99 — port 0 is
    // the rousing, port 1 is the amount, and that is the whole design.
    const enc = try packOne(testing.allocator, @as(i64, 99));
    defer testing.allocator.free(enc);
    try rt.feed(.{ .path = "plane.sighting", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 1 });
    try testing.expectEqual(@as(f64, 1), types.asNumber(mock.store.get("plane.tally").?).?);
    try testing.expectEqual(rill.DeltaKind.accumulate, mock.writes.items[0].kind);

    try rt.feed(.{ .path = "plane.sighting", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 2 });
    try testing.expectEqual(@as(f64, 2), types.asNumber(mock.store.get("plane.tally").?).?);
}

test "inc: three occurrences in one tick add three times" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.sighting | inc plane.tally 1");
    defer prog.deinit();

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const enc = try packOne(testing.allocator, @as(i64, 1));
        defer testing.allocator.free(enc);
        try rt.feed(.{ .path = "plane.sighting", .value = enc, .kind = .occurrence });
    }
    try rt.tick(.{ .frame = 1 });
    // Three rounds, three blind deltas, one batch at the end of the tick.
    try testing.expectEqual(@as(usize, 3), mock.writes.items.len);
    try testing.expectEqual(@as(f64, 3), types.asNumber(mock.store.get("plane.tally").?).?);
}

test "inc: a change in the amount alone is not a rousing" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.pulse | inc plane.tally plane.amount");
    defer prog.deinit();

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.amount", @as(i64, 5));
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    try feedValue(&rt, testing.allocator, "plane.amount", @as(i64, 5));
    const enc = try packOne(testing.allocator, @as(i64, 1));
    defer testing.allocator.free(enc);
    try rt.feed(.{ .path = "plane.pulse", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 1 });
    try testing.expectEqual(@as(f64, 5), types.asNumber(mock.store.get("plane.tally").?).?);

    // The amount moves; nothing rouses. A counter that ticked whenever its
    // step size was edited would be a very quiet kind of wrong.
    try feedValue(&rt, testing.allocator, "plane.amount", @as(i64, 7));
    try rt.tick(.{ .frame = 2 });
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try testing.expectEqual(@as(f64, 5), types.asNumber(mock.store.get("plane.tally").?).?);
}

test "inc: the amount is required, and numeric" {
    // Unpiped, `5` would bind the ROUSING port and the amount would silently
    // default. Requiring `by` is what turns that into a sentence.
    try expectParseError("inc plane.tally 5", "not bound");
    try expectParseError("plane.sighting | inc plane.tally hello", "unknown name");
    try expectParseError("plane.sighting | inc plane.tally \"5\"", "expected number");
}

test "inc: a blind delta reads nothing, so it passes the cycle ban" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    // Writes plane.tally, subscribes plane.sighting. No read, no cycle.
    var prog = try parseOk(testing.allocator, &reg, "plane.sighting | inc plane.tally 1");
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.writes.items.len);
    // But reading the path you increment is still a cycle — reading is what
    // makes it order-dependent, and that is what §4.4 refuses.
    try expectParseError("plane.tally | changed | inc plane.tally 1", "cycle");
}

// ---------------------------------------------------------------------------
// The garrison — the through-line. Two watchers, one shared tally, one shared
// mailbox, one frame. Every ruling of 2026-08-24 exercised in eight lines.
// ---------------------------------------------------------------------------

test "the garrison: two watchers see one attacker, and the tally rises by two" {
    const gpa = testing.allocator;
    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    var mock = rill.MockPlane.init(gpa);
    defer mock.deinit();
    try mock.putValue("plane.gate.enemy_count", @as(i64, 0));
    try mock.putValue("plane.tower.enemy_count", @as(i64, 0));

    // One watcher program, mounted once per post. `also` runs the counter
    // branch; the main wire carries on to the mailbox unchanged.
    var progs: [2]rill.Program = undefined;
    var rts: [2]rill.Runtime = undefined;
    var mounted: usize = 0;
    defer {
        var i = mounted;
        while (i > 0) {
            i -= 1;
            rts[i].deinit();
            progs[i].deinit();
        }
    }
    for ([_][]const u8{ "gate", "tower" }, 0..) |post, i| {
        const src = try std.fmt.allocPrint(gpa,
            \\using plane.defense as :d
            \\plane.{s}.enemy_count | rose_above 0
            \\  | also {{ inc :d.sightings 1 }}
            \\  | notify :d.alerts
        , .{post});
        defer gpa.free(src);
        progs[i] = try parseOk(gpa, &reg, src);
        rts[i] = try rill.Runtime.mount(gpa, &progs[i], mock.asPlane(), .{});
        mounted = i + 1;
        try testing.expectEqual(@as(usize, 0), progs[i].warnings.items.len);
    }

    // ONE attacker arrives. Both posts see it, in the same frame.
    for (&rts, [_][]const u8{ "plane.gate.enemy_count", "plane.tower.enemy_count" }) |*rt, path| {
        try feedValue(rt, gpa, path, @as(i64, 1));
        try rt.tick(.{ .frame = 1, .time_ns = 1000 });
    }

    // The counter: two posts, two blind deltas, one tally. This is the ruling
    // that `inc` exists for — read-modify-write could not have got here.
    try testing.expectEqual(@as(f64, 2), types.asNumber(mock.store.get("plane.defense.sightings").?).?);

    // The mailbox: two sightings, both delivered. Neither watcher's notify
    // suppressed the other's, and `also` did not eat the value on its way
    // through — the main wire reached `notify` intact from both posts.
    var alerts: usize = 0;
    for (mock.writes.items) |w| {
        if (std.mem.eql(u8, w.path, "plane.defense.alerts")) alerts += 1;
    }
    try testing.expectEqual(@as(usize, 2), alerts);
}

test "thresholds: each op is strict on its own comparison, and they mirror" {
    const Case = struct {
        src: []const u8,
        seed: i64,
        steps: []const i64,
        fires: []const f64, // the values the op emitted, in order
    };
    const cases = [_]Case{
        // The garrison's own line: a count going 0 → 1 IS an enemy arriving.
        .{ .src = "plane.n | rose_above 0 | tap f", .seed = 0, .steps = &.{ 1, 2, 0, 3 }, .fires = &.{ 1, 3 } },
        // Arriving at the threshold is not crossing it, on either side.
        .{ .src = "plane.n | rose_above 20 | tap f", .seed = 0, .steps = &.{ 20, 21 }, .fires = &.{21} },
        .{ .src = "plane.n | dropped_below 20 | tap f", .seed = 40, .steps = &.{ 20, 19 }, .fires = &.{19} },
        // First observation baselines silently, whichever side it lands on.
        .{ .src = "plane.n | rose_above 0 | tap f", .seed = 5, .steps = &.{6}, .fires = &.{} },
    };
    for (cases) |c| {
        var reg = try rill.Registry.init(testing.allocator);
        defer reg.deinit();
        try rill.registerCore(&reg);
        var prog = try parseOk(testing.allocator, &reg, c.src);
        defer prog.deinit();
        var mock = rill.MockPlane.init(testing.allocator);
        defer mock.deinit();
        try mock.putValue("plane.n", c.seed);
        var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
        defer rt.deinit();

        var seen = std.ArrayListUnmanaged(f64).empty;
        defer seen.deinit(testing.allocator);
        const tap = nodeIdOf(&prog, "tap1").?;
        for (c.steps, 0..) |n, i| {
            const before = rt.eval_count[tap];
            try feedValue(&rt, testing.allocator, "plane.n", n);
            try rt.tick(.{ .frame = @intCast(i + 1) });
            if (rt.eval_count[tap] > before) {
                try seen.append(testing.allocator, types.asNumber(rt.readSlot("programs.p.tap1.out.out").?).?);
            }
        }
        testing.expectEqualSlices(f64, c.fires, seen.items) catch |err| {
            std.debug.print("case: {s}\n", .{c.src});
            return err;
        };
    }
}

test "the spec's §3.14 example parses, verbatim" {
    // Copied character for character out of docs/rill-spec.md. An example a
    // doc ships and nothing executes is an example that goes stale silently —
    // the demo's `as stats` sat broken for two days on exactly that.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg,
        \\using plane.defense as :d
        \\
        \\plane.gate.enemy_count | rose_above 0
        \\  | also { inc :d.sightings 1 }
        \\  | notify :d.alerts
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 0), prog.warnings.items.len);
}

test "notify: piped, the input is the rousing and the record is the payload" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    // Ironwood's canonical sentinel (docs/ironwood.md §2), which needs the
    // record to survive being piped into.
    var prog = try parseOk(testing.allocator, &reg, "plane.sensors.tower.visible_enemies | rose_above 0 | notify plane.signals.horn { kind: \"approach\", from: \"tower\" }");
    defer prog.deinit();

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.sensors.tower.visible_enemies", @as(i64, 0));
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    try feedValue(&rt, testing.allocator, "plane.sensors.tower.visible_enemies", @as(i64, 3));
    try rt.tick(.{ .frame = 1 });

    // The horn carries the signal vocabulary, not the enemy count.
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try testing.expectEqualStrings("plane.signals.horn", mock.writes.items[0].path);
    const rec = mock.writes.items[0].value;
    try testing.expectEqual(types.Tag.record, types.typeOfValue(rec));
}

test "notify: the other two forms are unchanged" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    // Unbound record: the in-flowing value IS the payload, as before.
    var prog = try parseOk(testing.allocator, &reg, "plane.alerts | notify plane.signals.horn");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    const enc = try packOne(testing.allocator, @as(i64, 7));
    defer testing.allocator.free(enc);
    try rt.feed(.{ .path = "plane.alerts", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 1 });
    try testing.expectEqual(@as(f64, 7), types.asNumber(mock.writes.items[0].value).?);

    // Unpiped: the record binds port 0 and is both rousing and payload.
    var prog2 = try parseOk(testing.allocator, &reg, "notify plane.signals.horn { kind: \"imminent\" }");
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.mount(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try testing.expectEqual(@as(usize, 1), mock2.writes.items.len);
    try testing.expectEqual(types.Tag.record, types.typeOfValue(mock2.writes.items[0].value));
}

// ---------------------------------------------------------------------------
// The class audit (Chris's ruling, 2026-08-24). `tap` declared `.pure`, which
// is a CACHE LICENCE, while its whole purpose is a side effect on the log bus.
// One word wrong is one word; a table seeded optimistically is a trap, so the
// classification is pinned here exhaustively — a new core op fails this test
// until someone classifies it on purpose.
// ---------------------------------------------------------------------------

test "every core op declares its class deliberately" {
    const Expect = struct { name: []const u8, class: registry.OpClass };
    // `.reads` is "not a writer, not skippable". Three shapes reach it:
    // arrival-dependent (asks in_fresh), stateful, or fed-time — plus `tap`,
    // whose output nobody caches because its point is the side effect.
    const table = [_]Expect{
        .{ .name = "select", .class = .pure },
        .{ .name = "lerp", .class = .pure },
        .{ .name = "and", .class = .pure },
        .{ .name = "or", .class = .pure },
        .{ .name = "not", .class = .pure },
        .{ .name = "where", .class = .reads }, // arrival
        .{ .name = "partition", .class = .reads }, // arrival
        .{ .name = "changed", .class = .reads }, // arrival
        .{ .name = "latch", .class = .reads }, // arrival
        .{ .name = "dropped_below", .class = .reads }, // state
        .{ .name = "rose_above", .class = .reads }, // state
        .{ .name = "edge", .class = .reads }, // state
        .{ .name = "sample", .class = .reads }, // time
        .{ .name = "debounce", .class = .reads }, // time
        .{ .name = "throttle", .class = .reads }, // time
        .{ .name = "cooldown", .class = .reads }, // time
        .{ .name = "window", .class = .reads }, // time
        .{ .name = "stats", .class = .pure },
        .{ .name = "delay", .class = .reads }, // time
        .{ .name = "every", .class = .reads }, // time — the metronome; occurrence source, never skippable
        .{ .name = "arm", .class = .reads }, // state
        .{ .name = "disarm", .class = .reads }, // state
        // tier 2, beat 1a
        .{ .name = "clock", .class = .reads }, // fed time
        .{ .name = "frame", .class = .reads }, // fed time
        .{ .name = "wave", .class = .pure }, // same t, same shape, same answer
        .{ .name = "lfo", .class = .reads }, // fed time + its own epoch
        .{ .name = "ease", .class = .reads }, // state
        .{ .name = "ramp", .class = .reads }, // state
        .{ .name = "hold", .class = .reads }, // state
        .{ .name = "diff", .class = .reads }, // state
        .{ .name = "integrate", .class = .reads }, // state
        .{ .name = "range", .class = .pure },
        .{ .name = "over", .class = .pure }, // samples a literal curve; carries nothing
        .{ .name = "shape", .class = .pure },
        .{ .name = "add", .class = .pure },
        .{ .name = "sub", .class = .pure },
        .{ .name = "mul", .class = .pure },
        .{ .name = "div", .class = .pure },
        .{ .name = "min", .class = .pure },
        .{ .name = "max", .class = .pure },
        .{ .name = "clamp", .class = .pure },
        .{ .name = "abs", .class = .pure },
        .{ .name = "floor", .class = .pure },
        .{ .name = "round", .class = .pure },
        // beat 1b — the math completions, all pure, all broadcasting
        .{ .name = "sin", .class = .pure },
        .{ .name = "cos", .class = .pure },
        .{ .name = "tan", .class = .pure },
        .{ .name = "sqrt", .class = .pure },
        .{ .name = "exp", .class = .pure },
        .{ .name = "log", .class = .pure },
        .{ .name = "ceil", .class = .pure },
        .{ .name = "sign", .class = .pure },
        .{ .name = "fract", .class = .pure },
        .{ .name = "pow", .class = .pure },
        .{ .name = "mod", .class = .pure },
        .{ .name = "atan2", .class = .pure },
        .{ .name = "pi", .class = .pure },
        .{ .name = "tau", .class = .pure },
        .{ .name = "=", .class = .pure },
        .{ .name = "!=", .class = .pure },
        .{ .name = "<", .class = .pure },
        .{ .name = "<=", .class = .pure },
        .{ .name = ">", .class = .pure },
        .{ .name = ">=", .class = .pure },
        .{ .name = "expect", .class = .reads }, // op-internal state: checked once, at mount
        .{ .name = "match", .class = .pure },
        .{ .name = "record", .class = .pure },
        .{ .name = "array", .class = .pure },
        .{ .name = "nth", .class = .pure },
        .{ .name = "map", .class = .reads }, // drives a body that may hold bound ports
        .{ .name = "keep", .class = .reads },
        .{ .name = "reduce", .class = .reads },
        .{ .name = "sort", .class = .reads }, // optional key body, same reason
        .{ .name = "first", .class = .pure },
        .{ .name = "last", .class = .pure },
        .{ .name = "len", .class = .pure },
        .{ .name = "take", .class = .pure },
        .{ .name = "transpose", .class = .pure },
        .{ .name = "shuffle", .class = .pure }, // seeded: same in, same out
        .{ .name = "along", .class = .pure },
        .{ .name = "step", .class = .reads }, // a cursor is state
        .{ .name = "pulse", .class = .reads }, // fed time
        .{ .name = "once", .class = .reads }, // own state: fired or not
        .{ .name = "toggle", .class = .reads },
        .{ .name = "tally", .class = .reads },
        .{ .name = "above", .class = .reads }, // hysteresis is state
        .{ .name = "kick", .class = .reads }, // envelope in flight is state
        .{ .name = "adsr", .class = .reads }, // …and its four-segment cousin
        .{ .name = "below", .class = .reads }, // …and its mirror
        .{ .name = "noise", .class = .reads }, // fed time
        .{ .name = "rand", .class = .reads }, // own draw counter
        .{ .name = "distance", .class = .pure },
        .{ .name = "dot", .class = .pure },
        .{ .name = "nearest", .class = .pure }, // a search, but a pure one: same p, same knots, same t
        .{ .name = "within", .class = .pure },
        .{ .name = "angle", .class = .pure },
        .{ .name = "inside", .class = .pure },
        .{ .name = "cross", .class = .pure },
        .{ .name = "choose", .class = .pure },
        .{ .name = "project", .class = .pure },
        .{ .name = "merge", .class = .pure },
        .{ .name = "write", .class = .effect },
        .{ .name = "notify", .class = .effect },
        .{ .name = "inc", .class = .effect },
        .{ .name = "cast", .class = .effect }, // writes the world — through the field store, not a path
        .{ .name = "tag", .class = .effect }, // membership write — through the tag row, member key composed
        .{ .name = "untag", .class = .effect }, // membership write, leave direction
        .{ .name = "const", .class = .pure },
        .{ .name = "tap", .class = .reads }, // the one that gave the audit away
    };

    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    for (table) |e| {
        const id = reg.find(e.name) orelse {
            std.debug.print("core op '{s}' is gone — update the class table\n", .{e.name});
            return error.TestUnexpectedResult;
        };
        const got = reg.get(id).class;
        if (got != e.class) {
            std.debug.print("'{s}': declared .{s}, audit says .{s}\n", .{ e.name, @tagName(got), @tagName(e.class) });
            return error.TestUnexpectedResult;
        }
    }
    // Exhaustive both ways: a new op must be classified on purpose, not
    // inherit `.pure` from the field default and slip past unnoticed.
    if (reg.ops.items.len != table.len) {
        std.debug.print("core set has {d} ops, the class table has {d} — classify the new one\n", .{ reg.ops.items.len, table.len });
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// The ticks audit (ruled 2026-08-25, tier-2 recon §7). `OpDef.ticks` says an
// operator MAY re-arm itself and evaluate again with no input change. The host
// lights the ticks-every-frame badge from it and shows the node's live eval
// counter beside it as the proof — the flag says what could cost, the counter
// says what did.
//
// Defaulted plus audited, like `class` and unlike `routes`, because a wrong
// answer here shows a wrong badge rather than computing a wrong value. Both
// ways, so a new self-arming op cannot inherit `false` and hide its cost.
// ---------------------------------------------------------------------------

test "every core op declares whether it may tick" {
    const Expect = struct { name: []const u8, ticks: bool };
    const table = [_]Expect{
        .{ .name = "clock", .ticks = true }, // as long as time is fed
        .{ .name = "frame", .ticks = true },
        .{ .name = "lfo", .ticks = true },
        .{ .name = "ease", .ticks = true }, // while converging
        .{ .name = "ramp", .ticks = true }, // while tweening
        .{ .name = "diff", .ticks = true }, // while moving
        .{ .name = "integrate", .ticks = true }, // while the rate is non-zero
        // `every` re-arms too, but on its PERIOD, not per tick — the badge is
        // about per-frame cost, and a metronome at 30s is not that. It is the
        // boundary case, so it is pinned here rather than left to be argued.
        .{ .name = "every", .ticks = false },
        // `hold` needs no wake at all: nothing happens at the end of its
        // window, the next arrival simply finds it expired.
        .{ .name = "hold", .ticks = false },
        .{ .name = "pulse", .ticks = true }, // a value source on fed time
        .{ .name = "kick", .ticks = true }, // while the envelope is in flight, and not after
        .{ .name = "adsr", .ticks = true }, // …while a SEGMENT is in flight; a held sustain costs nothing
        .{ .name = "noise", .ticks = true }, // as long as time is fed
        .{ .name = "wave", .ticks = false }, // pure shaper; ticks if its t does
        .{ .name = "range", .ticks = false },
        .{ .name = "over", .ticks = false }, // pure shaper, like the two either side
        .{ .name = "shape", .ticks = false },
    };

    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    for (table) |e| {
        const id = reg.find(e.name) orelse return error.TestUnexpectedResult;
        if (reg.get(id).ticks != e.ticks) {
            std.debug.print("'{s}': declared ticks={}, audit says {}\n", .{ e.name, reg.get(id).ticks, e.ticks });
            return error.TestUnexpectedResult;
        }
    }
    // Exhaustive the other way: every op the registry says ticks is on the
    // table above. A new self-arming op fails here until someone says so.
    for (reg.ops.items) |def| {
        if (!def.ticks) continue;
        const listed = for (table) |e| {
            if (std.mem.eql(u8, e.name, def.name)) break true;
        } else false;
        if (!listed) {
            std.debug.print("'{s}' declares ticks=true and is not in the audit\n", .{def.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "a ticking op is never pure" {
    // The structural half, needing no table: an op that re-arms itself
    // produces a new answer with no new input, which is precisely what `pure`
    // says it cannot do. Catches the contradiction mechanically.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    for (reg.ops.items) |def| {
        if (def.ticks and def.class == .pure) {
            std.debug.print("'{s}' may tick but declares .pure\n", .{def.name});
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// The tag audit (2026-09-09, on Christian's *"We are going to need a palette…
// With functional groups"*, then his reframe: *"I guess we could view them as
// filters huh. So an operator could exist in multiple groups. Think of them as
// #tags."*). `OpDef.tags` says what an operator is FOR; the FIRST tag is its
// home, and a grouped listing files it there.
//
// Defaulted plus audited, like `ticks` and unlike `routes`: a wrong tag shows
// a wrong tray, not a wrong answer, so the registry resolves at least one for
// every op and this holds RILL'S OWN table to a closed set. The registry may
// not close it — a host interns its own vocabulary — so the closure lives
// here, where rill's table is the only thing in scope.
//
// **Over every tag on every op, not just the home**, and both ways. Free-form
// strings with several per operator is precisely how Blade3D ended up with
// `Contraints` sitting unnoticed for years — Christian's own reaction to it
// was *"that's fast finger typing at work"* — and a typo on a SECOND tag is
// even quieter than one on a first, because the operator still files
// correctly and only its findability is gone.
// ---------------------------------------------------------------------------

/// The seventeen. Thirteen are somebody's home; `constant`, `gate`,
/// `oscillator` and `random` are pure cross-cuts, and `time` is both. Read
/// aloud before naming; the rejected names and the ops that sat awkwardly are
/// in `docs/implementation-notes.md`.
const core_tags = [_][]const u8{
    "array", // over many values at once
    "constant", // a value that never changes
    "contract", // a shape, promised
    "curve", // given t, give me a value along a shape
    "envelope", // a value in motion, over fed time
    "event", // noticing that something happened, and counting it
    "flow", // which way does this value go, and does it go at all
    "gate", // may swallow an arrival
    "logic", // comparison, and the booleans that combine it
    "math", // arithmetic and the elementary functions
    "oscillator", // goes up and down on its own
    "random", // variation you did not author
    "record", // named fields
    "sink", // where a value leaves the program
    "source", // makes a value out of the clock, a seed, or nothing
    "space", // positions and directions
    "time", // fed time, in every form
};

test "every core op carries tags, and only these seventeen exist" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    // One way: every registered op has at least one tag, none of them fell
    // through to the host fallback, and EVERY tag it carries is on the roster.
    for (reg.ops.items) |def| {
        if (def.tags.len == 0) {
            std.debug.print("'{s}' carries no tags — `register` must never leave an op bare\n", .{def.name});
            return error.TestUnexpectedResult;
        }
        for (def.tags) |t| {
            if (std.mem.eql(u8, t, rill.registry.UNTAGGED)) {
                std.debug.print("'{s}' is untagged — rill's own table declares, it does not fall back\n", .{def.name});
                return error.TestUnexpectedResult;
            }
            const listed = for (core_tags) |g| {
                if (std.mem.eql(u8, g, t)) break true;
            } else false;
            if (!listed) {
                std.debug.print("'{s}' carries tag '{s}', which is not one of the seventeen\n", .{ def.name, t });
                return error.TestUnexpectedResult;
            }
        }
    }

    // The other way: every tag on the roster is carried by at least one op. A
    // tag emptied by a re-tagging is a heading `rill ops` would never print
    // and a filter a palette would offer that finds nothing.
    for (core_tags) |g| {
        var n: usize = 0;
        for (reg.ops.items) |def| {
            if (def.tagged(g)) n += 1;
        }
        if (n == 0) {
            std.debug.print("tag '{s}' is on the roster and nothing carries it\n", .{g});
            return error.TestUnexpectedResult;
        }
    }

    // …and the roster is sorted, because `rill ops` prints tags in sorted
    // order and a reader comparing the two should not have to re-sort one.
    for (core_tags[0 .. core_tags.len - 1], core_tags[1..]) |a, b| {
        if (!std.mem.lessThan(u8, a, b)) {
            std.debug.print("the tag roster is out of order at '{s}' / '{s}'\n", .{ a, b });
            return error.TestUnexpectedResult;
        }
    }
}

test "the cross-cutting tags cut across, and the home is declaration order" {
    // The filter model's own claim, which the roster audit above cannot make:
    // a tag that only ever appears on operators sharing a home is a sub-name
    // for that home, not a cross-cut, and it should have been prose in the
    // home's sentence instead. Each of these is checked to span at least two
    // homes — measured, not asserted from the table it is auditing.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    for ([_][]const u8{ "gate", "oscillator", "random", "time" }) |cross| {
        var homes: usize = 0;
        var seen: [8][]const u8 = undefined;
        for (reg.ops.items) |def| {
            if (!def.tagged(cross)) continue;
            const known = for (seen[0..homes]) |h| {
                if (std.mem.eql(u8, h, def.home())) break true;
            } else false;
            if (!known and homes < seen.len) {
                seen[homes] = def.home();
                homes += 1;
            }
        }
        if (homes < 2) {
            std.debug.print("'{s}' is carried only by operators at home in one place — it is a sub-name, not a cross-cut\n", .{cross});
            return error.TestUnexpectedResult;
        }
    }

    // `constant` is the deliberate exception and is pinned as one: all three
    // of `const`, `pi` and `tau` are at home in `source`. It earns its place
    // by answering a question `source` cannot — `source` also holds `clock`,
    // `lfo` and `noise`, which are anything but constant — so it is a
    // NARROWING, not a cross-cut, and the loop above must not be relaxed to
    // let it through.
    var homes: usize = 0;
    for (reg.ops.items) |def| {
        if (def.tagged("constant") and !std.mem.eql(u8, def.home(), "source")) homes += 1;
    }
    try testing.expectEqual(@as(usize, 0), homes);

    // The home is DECLARATION order and never alphabetical: `noise` declares
    // `source` then `random`, and a resolution that sorted would file it
    // under `random` — where a reader looking for a noise source would not
    // think to look. The sharpest single fixture for the ordering rule.
    const noise = reg.get(reg.find("noise").?);
    try testing.expectEqualStrings("source", noise.home());
    try testing.expect(noise.tagged("random"));
    try testing.expect(std.mem.lessThan(u8, "random", "source")); // …and it WOULD have moved

    // …and an operator is found by every tag it carries, which is the whole
    // model: `lfo` answers to `source`, to `oscillator` and to `time`.
    const lfo = reg.get(reg.find("lfo").?);
    try testing.expect(lfo.tagged("source") and lfo.tagged("oscillator") and lfo.tagged("time"));
    try testing.expectEqualStrings("source", lfo.home());
}

test "every tag rill declares has a sentence, and the two tables agree" {
    // The `{name, doc}` half, and the evidence it was paid for is Christian's
    // own: Blade3D's `OperatorGroup` list, free-form and unaudited for years,
    // ended up with `Physics` declared twice, `Constraints` misspelled
    // `Contraints`, and several groups carrying a Description with no
    // DisplayName. Every one of those is a drift this gate refuses.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    // Every tag an operator CARRIES has a sentence — a filter with no tooltip
    // is the failure the pair exists to prevent.
    for (reg.ops.items) |def| {
        for (def.tags) |t| {
            const doc = reg.tagDoc(t) orelse {
                std.debug.print("tag '{s}' (from '{s}') has no sentence\n", .{ t, def.name });
                return error.TestUnexpectedResult;
            };
            if (doc.len == 0) {
                std.debug.print("tag '{s}' has an EMPTY sentence\n", .{t});
                return error.TestUnexpectedResult;
            }
        }
    }

    // …and the two tables in `ops.zig` name the same seventeen. The roster
    // above is what the audit closes over; `ops.TAGS` is what the registry is
    // told. Two lists that could disagree are a `Contraints` waiting to
    // happen, so they are checked against each other, both ways.
    try testing.expectEqual(core_tags.len, rill.ops.TAGS.len);
    for (core_tags) |g| {
        const listed = for (rill.ops.TAGS) |gd| {
            if (std.mem.eql(u8, gd.name, g)) break true;
        } else false;
        if (!listed) {
            std.debug.print("tag '{s}' is on the audit roster and `ops.TAGS` does not describe it\n", .{g});
            return error.TestUnexpectedResult;
        }
    }
    for (rill.ops.TAGS) |gd| {
        const listed = for (core_tags) |g| {
            if (std.mem.eql(u8, gd.name, g)) break true;
        } else false;
        if (!listed) {
            std.debug.print("`ops.TAGS` describes '{s}', which is not on the audit roster\n", .{gd.name});
            return error.TestUnexpectedResult;
        }
    }

    // A second sentence for one tag means the palette shows whichever it read
    // last — Blade3D's two `Physics` groups, exactly. Refused at the door, so
    // a copy-pasted entry cannot land quietly.
    try testing.expectError(error.DuplicateTagDoc, reg.describeTag(.{ .name = "math", .doc = "something else" }));
    // …and a half-filled pair is refused too, in both directions.
    try testing.expectError(error.BadTagName, reg.describeTag(.{ .name = "brandnew", .doc = "" }));
    try testing.expectError(error.BadTagName, reg.describeTag(.{ .name = "", .doc = "a sentence" }));
    try testing.expectError(error.BadTagName, reg.describeTag(.{ .name = "two words", .doc = "a sentence" }));
}

test "the rbf pack tags itself: two words, nothing declared" {
    // The prepend earning its keep on the only pack in the repo with a
    // two-word name. `registerRbf` declares NO tags; both words must still be
    // at home under `rbf`, because that is the property that makes
    // matryoshka's whole `(verb, subop)` console vocabulary organise itself
    // with no change over there. Checked against the PACK rather than a
    // fixture, so a `.tags` added to `ops_rbf.zig` would route around the
    // derivation and this gate would stop watching it — see the note there.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    try rill.registerRbf(&reg);
    for ([_][]const u8{ "rbf through", "rbf bump" }) |name| {
        const id = reg.find(name) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("rbf", reg.get(id).home());
        try testing.expectEqual(@as(usize, 1), reg.get(id).tags.len);
    }
    // …and `rbf` is deliberately NOT one of the seventeen: the audit above
    // covers `registerCore` only, and a pack is a separate registration call
    // for a host that wants it. If this ever fails, the pack has been folded
    // into the core table and the audit needs to say so.
    for (core_tags) |g| try testing.expect(!std.mem.eql(u8, g, "rbf"));
}

test "an op that emits occurrences is never cacheable" {
    // The structural half of the audit, which needs no table: emitting an
    // occurrence means the answer depends on arrival or history, and neither
    // is visible to a cache key. This catches the biggest family mechanically.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    for (reg.ops.items) |def| {
        for (def.outputs) |out| {
            if (out.kind == .occurrence and def.class == .pure) {
                std.debug.print("'{s}' emits an occurrence but declares .pure\n", .{def.name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "reserved delta kinds are refused, never quietly treated as values" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.v | tap seen");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    const enc = try packOne(testing.allocator, @as(i64, 1));
    defer testing.allocator.free(enc);
    for ([_]rill.DeltaKind{ .accumulate, .membership }) |k| {
        try testing.expectError(error.UnsupportedDeltaKind, rt.feed(.{ .path = "plane.v", .value = enc, .kind = k }));
    }
    // A membership WRITE is refused at the plane too, for the same reason: a
    // tag stored as a value would silently lose idempotence, which is the one
    // property that distinguishes it from accumulate.
    try testing.expectError(error.Denied, mock.asPlane().write("plane.tags", enc, .membership, .base, 0));
}

// ---------------------------------------------------------------------------
// The sink shape: `<verb> <path> [value]`, shared by `set` and `notify`.
// Piped value: write what's flowing. Bound value: write this, because
// something flowed.
// ---------------------------------------------------------------------------

test "latch: the same payload twice is two events, not one" {
    // **An occurrence is not a value, and `latch` produces occurrences.** Its
    // own help says so — *"emit the current `in` when `trigger` fires"* — but
    // its output port was declared `p.val`, so `emitSlot`'s value rule
    // ("20→20 is silence") swallowed every firing after the first whenever the
    // sampled payload did not change.
    //
    // Found in matryoshka, 2026-09-12. `select.rill` ends:
    //
    //     "main" | latch clear_click | where replacing | select clear
    //
    // — click empty space to drop your selection. The latch samples the same
    // string every time, so the FIRST click cleared and every one after it was
    // silence. Chris: *"I can't unselect it clicking anywhere."* The policy was
    // right, its gates were right, and the wire ate the event.
    //
    // Mutation: declare the output `p.val` again. The second tick writes
    // nothing and this goes red on the count — which is the whole bug, in one
    // number.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "\"main\" | latch plane.trig | write plane.out");
    defer prog.deinit();

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    const enc = try packOne(testing.allocator, @as(i64, 1));
    defer testing.allocator.free(enc);

    try rt.feed(.{ .path = "plane.trig", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 1 });
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);

    // The SAME payload, a second time. A person clicking empty space twice has
    // performed two gestures, and the second one is not less of one for
    // resembling the first.
    try rt.feed(.{ .path = "plane.trig", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 2 });
    try testing.expectEqual(@as(usize, 2), mock.writes.items.len);

    // …and a third, because "it works twice" is what a stale-by-one bug looks
    // like.
    try rt.feed(.{ .path = "plane.trig", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 3 });
    try testing.expectEqual(@as(usize, 3), mock.writes.items.len);
}

test "set: a rousing writes a constant, in one node" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    // Ironwood's gate.rill: "at the sound of the alarm, drop the portcullis."
    // Before the `value` port this took three nodes to say one word — hold the
    // constant in a latch, sample it on the rousing, pipe it to the sink.
    var prog = try parseOk(testing.allocator, &reg, "plane.signals.horn | write plane.gate.portcullis 1");
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.nodeCount());

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    // Nothing has flowed, so nothing has been written — a constant is not a
    // reason to write, a rousing is.
    try testing.expectEqual(@as(usize, 0), mock.writes.items.len);

    const enc = try packOne(testing.allocator, @as(i64, 7));
    defer testing.allocator.free(enc);
    try rt.feed(.{ .path = "plane.signals.horn", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 1 });
    // The horn carried 7. The portcullis is 1.
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try testing.expectEqual(@as(f64, 1), types.asNumber(mock.writes.items[0].value).?);

    // Two blasts, two writes: the sink is roused, not level-triggered.
    try rt.feed(.{ .path = "plane.signals.horn", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 2 });
    try testing.expectEqual(@as(usize, 2), mock.writes.items.len);
}

test "set: the older forms are unchanged" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    // Piped, value unbound: write what's flowing.
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | clamp 0 100 | write plane.ui.bar");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.hp", @as(i64, 40));
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    try testing.expectEqual(@as(f64, 40), types.asNumber(mock.writes.items[0].value).?);

    // Unpiped: the value binds port 0 and is both rousing and payload — the
    // console's entire `set <path> <value>` grammar, untouched.
    var prog2 = try parseOk(testing.allocator, &reg, "write plane.ui.bar 0.5");
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.mount(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try testing.expectEqual(@as(usize, 1), mock2.writes.items.len);
    try testing.expectEqual(@as(f64, 0.5), types.asNumber(mock2.writes.items[0].value).?);
}

test "set: a change in the value alone is not a write" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.pulse | write plane.out plane.amount");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.amount", @as(i64, 5));
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();

    const enc = try packOne(testing.allocator, @as(i64, 1));
    defer testing.allocator.free(enc);
    try rt.feed(.{ .path = "plane.pulse", .value = enc, .kind = .occurrence });
    try rt.tick(.{ .frame = 1 });
    try testing.expectEqual(@as(f64, 5), types.asNumber(mock.writes.items[0].value).?);

    // The payload moves; nothing rouses. The payload says what, the rousing
    // says when — the same rule `inc` applies to `by`.
    try feedValue(&rt, testing.allocator, "plane.amount", @as(i64, 9));
    try rt.tick(.{ .frame = 2 });
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
}

test "write: the mode rides the call, and a value beside it binds its own slot" {
    // The campaign's core claim (write-verbs beat 1, ruled 2026-08-29): the
    // blend intent is chosen at the CALL SITE and arrives at the host as
    // data — never inferred from the target's class. One case per mode, each
    // with a value in the adjacent slot, which is also the disambiguation
    // gate: `write plane.k 1 hold` must bind 1 as the payload and hold as
    // the mode, or the whole one-row grammar is a bug factory.
    const Case = struct { src: []const u8, mode: rill.WriteMode };
    for ([_]Case{
        .{ .src = "write plane.k 1", .mode = .base },
        .{ .src = "write plane.k 1 hold", .mode = .hold },
        .{ .src = "write plane.k 1 add", .mode = .add },
        .{ .src = "write plane.k 1 mul", .mode = .mul },
        .{ .src = "write plane.k 1 stops", .mode = .stops },
    }) |case| {
        var reg = try rill.Registry.init(testing.allocator);
        defer reg.deinit();
        try rill.registerCore(&reg);
        var prog = try parseOk(testing.allocator, &reg, case.src);
        defer prog.deinit();
        var mock = rill.MockPlane.init(testing.allocator);
        defer mock.deinit();
        var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
        defer rt.deinit();
        try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
        try testing.expectEqual(case.mode, mock.writes.items[0].mode);
        try testing.expectEqual(@as(f64, 1), types.asNumber(mock.writes.items[0].value).?);
    }
}

test "write … clear rides the pipe, carries nothing, and refuses a value" {
    const Seen = struct {
        var n: usize = 0;
        var detail: [160]u8 = undefined;
        var detail_len: usize = 0;
        fn hook(_: ?*anyopaque, ev: rill.eval.ErrorEvent) void {
            n += 1;
            detail_len = @min(ev.detail.len, detail.len);
            @memcpy(detail[0..detail_len], ev.detail[0..detail_len]);
        }
    };
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    // The withdrawing form: roused by the pipe, no payload — the value slot
    // empty ON PURPOSE, and the write that reaches the host says .clear with
    // zero bytes.
    var prog = try parseOk(testing.allocator, &reg, "plane.t | write plane.k clear");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    try feedValue(&rt, testing.allocator, "plane.t", @as(i64, 1));
    try rt.tick(.{});
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try testing.expectEqual(rill.WriteMode.clear, mock.writes.items[0].mode);
    try testing.expectEqual(@as(usize, 0), mock.writes.items[0].value.len);

    // A value beside clear is a category error, refused in words — binding
    // it silently would let "clear 0.5" read as writing a half.
    Seen.n = 0;
    var prog2 = try parseOk(testing.allocator, &reg, "plane.t | write plane.k 5 clear");
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.mount(testing.allocator, &prog2, mock2.asPlane(), .{ .error_fn = Seen.hook });
    defer rt2.deinit();
    try feedValue(&rt2, testing.allocator, "plane.t", @as(i64, 1));
    try rt2.tick(.{});
    try testing.expectEqual(@as(usize, 0), mock2.writes.items.len);
    try testing.expect(Seen.n > 0);
    try testing.expect(std.mem.indexOf(u8, Seen.detail[0..Seen.detail_len], "takes no value") != null);
}

test "write: one mode only — two flags refuse in words" {
    const Seen = struct {
        var n: usize = 0;
        var detail: [160]u8 = undefined;
        var detail_len: usize = 0;
        fn hook(_: ?*anyopaque, ev: rill.eval.ErrorEvent) void {
            n += 1;
            detail_len = @min(ev.detail.len, detail.len);
            @memcpy(detail[0..detail_len], ev.detail[0..detail_len]);
        }
    };
    Seen.n = 0;
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "write plane.k 1 hold add");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .error_fn = Seen.hook });
    defer rt.deinit();
    try testing.expectEqual(@as(usize, 0), mock.writes.items.len);
    try testing.expect(Seen.n > 0);
    try testing.expect(std.mem.indexOf(u8, Seen.detail[0..Seen.detail_len], "one mode only") != null);
}

test "write: the mode words are a closed set — a stray word refuses" {
    // The closed enum is what keeps `write knob 5 bogus` from quietly
    // binding somewhere; the refusal names the stray.
    try expectParseError("write plane.k 1 bogus", "bogus");
}

test "the renamed front door: `set` refuses by naming `write`" {
    // The README lesson pre-paid: every rill ever written says `set`, and
    // the refusal must hand the author the new word, not a shrug.
    try expectParseError("plane.a | set plane.k", "became `write`");
}

test "write: statement identity rides the call, distinct per statement" {
    // Per-statement LEVELS (ruled 2026-08-29) fold by (owner, stmt) — so two
    // statements in one file must reach the host as two identities, or beat
    // 2 rebuilds the replace-vs-sum bug with better paperwork.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.a | write plane.x
        \\plane.a | write plane.y
    );
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    try feedValue(&rt, testing.allocator, "plane.a", @as(i64, 3));
    try rt.tick(.{});
    try testing.expectEqual(@as(usize, 2), mock.writes.items.len);
    try testing.expect(mock.writes.items[0].stmt != mock.writes.items[1].stmt);
}

test "notify stays base: an occurrence has no lane to join" {
    // notify shares write's eval with ONE static — the guard this pins was
    // found by an index panic, and without it the next statics reshuffle
    // finds it again the hard way.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var prog = try parseOk(testing.allocator, &reg, "plane.a | notify plane.k");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    try feedValue(&rt, testing.allocator, "plane.a", @as(i64, 1));
    try rt.tick(.{});
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try testing.expectEqual(rill.WriteMode.base, mock.writes.items[0].mode);
}

test "write and notify share the sink PORT shape; the mode statics are write's alone" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const wr = reg.get(reg.find("write").?);
    const notify = reg.get(reg.find("notify").?);
    // They diverged for exactly one day — notify grew the payload port first,
    // because the pipe took its only port and the sentinel was unsayable, and
    // `set` met the identical wall one scenario later. The port is the sink
    // SHAPE now, not one op's exception. What is left is intent — and since
    // write-verbs (2026-08-29) `write` carries that intent as five flag
    // statics that notify deliberately does not have: an occurrence has no
    // lane to join.
    try testing.expectEqual(wr.inputs.len, notify.inputs.len);
    for (wr.inputs, notify.inputs) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqual(a.optional, b.optional);
    }
    try testing.expectEqual(wr.class, notify.class);
    // The OUT side is shared too, and has been since 2026-09-08: an effect
    // returns its input, so both declare exactly one `any` output. It was
    // `0` here until that beat, and the change is the second reason G2's
    // frozen hash has moved for this pair of ops.
    try testing.expectEqual(@as(usize, 1), wr.outputs.len);
    try testing.expectEqual(wr.outputs.len, notify.outputs.len);
    try testing.expectEqual(types.Tag.any, wr.outputs[0].ty);
    // This is the slot the G2 hash moved for in 2026-08-24: unbound, present.
    try testing.expect(wr.inputs[1].optional);
    // The statics split: path + five mode flags vs path alone.
    try testing.expectEqual(@as(usize, 6), wr.statics.len);
    try testing.expectEqual(@as(usize, 1), notify.statics.len);
}

// ---------------------------------------------------------------------------
// rill-casts.md, beat 1 — the `$` sigil, `cast`, `every`, and the block rule
// generalised. Grammar per the stamped note (cc-note-casts.md §1/§5); the
// field store itself is the engine's (beat 2) — everything rill core promises
// is pinned here: what was deposited, when, and what refuses to parse.
// ---------------------------------------------------------------------------

test "cast: the stamped grammar parses, and every piece lands where declared" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.gate.enemies | rose_above 0 | cast $alarm 1.0 radius 30 at plane.gate.pos decay 2s");
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "cast1").?);
    try testing.expectEqualStrings("$alarm", n.statics[0].channel);
    try testing.expectEqual(@as(f64, 30), types.asNumber(n.statics[1].literal).?);
    // value port bound to the constant, `at` a live plane reference, `decay`
    // a duration — and port 0 is the piped rousing.
    try testing.expectEqual(@as(f64, 1.0), types.asNumber(prog.slot(n.inputs[1]).source.literal).?);
    try testing.expectEqualStrings("plane.gate.pos", prog.slot(n.inputs[2]).source.plane);
    const d = types.asDuration(prog.slot(n.inputs[3]).source.literal).?;
    try testing.expectEqual(false, d.frames);
    try testing.expectEqual(@as(u64, 2_000_000_000), d.count);
    // A cast is not a path write: nothing for the write list, and therefore
    // nothing the cycle check could ever trip over — by construction, not by
    // exemption. That is what `.channel`-not-`.path` bought.
    try testing.expectEqual(@as(usize, 0), prog.writes.items.len);
}

test "cast: the colon-kwarg spelling binds the same ports" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.lvl | cast $blight radius: 12 at: plane.origin");
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "cast1").?);
    try testing.expectEqual(@as(f64, 12), types.asNumber(n.statics[1].literal).?);
    try testing.expectEqualStrings("plane.origin", prog.slot(n.inputs[2]).source.plane);
}

test "cast: what refuses to parse, refuses loudly" {
    // The keyword is what disambiguates; nothing keyword-declared binds
    // positionally, and nothing positional slips into `at`.
    try expectParseError("plane.x | cast $f 1 at plane.p", "needs 'radius <value>'");
    try expectParseError("plane.x | cast $f 1 radius 2", "'at' of 'cast' is not bound");
    try expectParseError("plane.x | cast $f 1 radius", "expects a value after 'radius'");
    try expectParseError("plane.x | cast $f 1 5 radius 2 at plane.p", "too many arguments");
    // A channel wears its sigil, always.
    try expectParseError("plane.x | cast alarm 1 radius 2 at plane.p", "'$'-sigil");
    // A keyword typo never binds positionally — the missing keyword is what
    // gets named, which is where the eye needs to land.
    try expectParseError("plane.x | cast $f 1 radiu 2 at plane.p", "needs 'radius <value>'");
    // No bare channel read in v1: a field is read at a standpoint.
    try expectParseError("$alarm | mul 2 | write plane.x", "standpoint");
    // The sigil belongs to channels alone.
    try expectParseError("plane.x | mul 2 as $x", "cannot wear");
    try expectParseError("plane.x | mul 2 as @x", "cannot wear");
    try expectParseError("@tom | mul 2 | write plane.x", "entity reference");
    try expectParseError("using plane.a as :$s", "cannot wear");
    try expectParseError("def $d(x) = x | mul 2", "cannot wear");
}

test "cast: a channel name is a legal plane-path segment" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.sensors.gate.$alarm | rose_above 0.5 | write plane.ui.alert");
    defer prog.deinit();
    try testing.expectEqualStrings("plane.sensors.gate.$alarm", prog.subs.items[0].path);
}

test "cast: piped, it deposits what flows — and only when the rousing flows" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.lvl | cast $blight radius 12 at plane.origin", .{
        .{ "plane.lvl", @as(f64, 0.8) },
        .{ "plane.origin", @as(i64, 7) },
    });
    defer fx.deinit();
    // Tick 0: the seeded value is fresh, so the caster deposits once.
    try testing.expectEqual(@as(usize, 1), fx.mock.casts.items.len);
    const c0 = fx.mock.casts.items[0];
    try testing.expectEqualStrings("$blight", c0.channel);
    try testing.expectEqual(@as(f64, 0.8), c0.amplitude);
    try testing.expectEqual(@as(f64, 12), c0.radius);
    try testing.expect(c0.decay == null);
    try testing.expectEqual(@as(f64, 7), types.asNumber(c0.pos).?);

    // A change in `at` ALONE is not a cast (§3.8: the payload says what, the
    // rousing says when). Mutation that bites: rouse on any fresh input and
    // this counts 2.
    var pk = struple.Packer.init(testing.allocator);
    defer pk.deinit();
    try pk.appendInt(9);
    try fx.rt.feed(.{ .path = "plane.origin", .value = pk.bytes() });
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(usize, 1), fx.mock.casts.items.len);

    // …but the moved position IS what the next rousing casts at: the dot-form
    // reference is live, a moving caster re-aims without re-rousing.
    var pv = struple.Packer.init(testing.allocator);
    defer pv.deinit();
    try pv.appendF64(0.5);
    try fx.rt.feed(.{ .path = "plane.lvl", .value = pv.bytes() });
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(usize, 2), fx.mock.casts.items.len);
    try testing.expectEqual(@as(f64, 0.5), fx.mock.casts.items[1].amplitude);
    try testing.expectEqual(@as(f64, 9), types.asNumber(fx.mock.casts.items[1].pos).?);
}

test "cast: unpiped, the intensity is both rousing and payload — one deposit, at tick 0" {
    // The documented surprise (note §1): a bare cast deposits once and leaks
    // away. A standing caster needs `every` in front of it.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "cast $torchlight 0.8 radius 12 at plane.brazier decay 4s", .{
        .{ "plane.brazier", @as(i64, 3) },
    });
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 1), fx.mock.casts.items.len);
    try testing.expectEqual(@as(f64, 0.8), fx.mock.casts.items[0].amplitude);
    const d = fx.mock.casts.items[0].decay.?;
    try testing.expectEqual(@as(u64, 4_000_000_000), d.count);
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(usize, 1), fx.mock.casts.items.len);
}

test "cast: two rousings in one tick are two deposits — occurrences never coalesce" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.horn | cast $alarm 1.0 radius 30 at plane.gate", .{
        .{ "plane.gate", @as(i64, 1) },
    });
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), fx.mock.casts.items.len); // no horn yet
    var pk = struple.Packer.init(testing.allocator);
    defer pk.deinit();
    try pk.appendBool(true);
    try fx.rt.feed(.{ .path = "plane.horn", .value = pk.bytes(), .kind = .occurrence });
    try fx.rt.feed(.{ .path = "plane.horn", .value = pk.bytes(), .kind = .occurrence });
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(usize, 2), fx.mock.casts.items.len);
    for (fx.mock.casts.items) |c| try testing.expectEqual(@as(f64, 1.0), c.amplitude);
}

test "cast: a host with no field store fails the node, counted — never a silent drop" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.p", @as(i64, 1));
    var prog = try parseOk(testing.allocator, &reg, "cast $f 1 radius 2 at plane.p");
    defer prog.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlaneWithoutFields(), .{});
    defer rt.deinit();
    try testing.expectEqual(@as(usize, 0), mock.casts.items.len);
    try testing.expectEqual(@as(u64, 1), rt.error_count[nodeIdOf(&prog, "cast1").?]);
}

test "every: fires at mount, then on cadence — and a gap earns ONE firing, not a burst" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "every 2f | inc plane.n 1", .{});
    defer fx.deinit();
    const n = struct {
        fn of(f: *Fixture) f64 {
            return types.asNumber(f.mock.store.get("plane.n").?).?;
        }
    }.of;
    try testing.expectEqual(@as(f64, 1), n(&fx)); // leading edge at mount
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(f64, 1), n(&fx));
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(f64, 2), n(&fx));
    try fx.rt.tick(.{ .frame = 3, .time_ns = 3 });
    try testing.expectEqual(@as(f64, 2), n(&fx));
    try fx.rt.tick(.{ .frame = 4, .time_ns = 4 });
    try testing.expectEqual(@as(f64, 3), n(&fx));
    // The pause: cadence anchors to the last actual firing. A brazier fed by
    // catch-up bursts would spike ABOVE steady state after every hitch —
    // deposits the pause never earned. due-plus-period would fire at 11 too;
    // this pins that it does not.
    try fx.rt.tick(.{ .frame = 10, .time_ns = 10 });
    try testing.expectEqual(@as(f64, 4), n(&fx));
    try fx.rt.tick(.{ .frame = 11, .time_ns = 11 });
    try testing.expectEqual(@as(f64, 4), n(&fx));
    try fx.rt.tick(.{ .frame = 12, .time_ns = 12 });
    try testing.expectEqual(@as(f64, 5), n(&fx));
}

test "every: the ns lane keeps the same contract" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "every 5s | inc plane.n 1", .{});
    defer fx.deinit();
    try tickAt(&fx, 4_999 * ms);
    try testing.expectEqual(@as(f64, 1), types.asNumber(fx.mock.store.get("plane.n").?).?);
    try tickAt(&fx, 5_000 * ms);
    try testing.expectEqual(@as(f64, 2), types.asNumber(fx.mock.store.get("plane.n").?).?);
}

test "every: a zero period is a storm wearing a duration — refused at the node" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "every 0s | inc plane.n 1", .{});
    defer fx.deinit();
    try testing.expectEqual(@as(u64, 1), fx.rt.error_count[nodeIdOf(&fx.prog, "every1").?]);
    try testing.expect(fx.mock.store.get("plane.n") == null);
}

test "block rule: `every 1f { … }` is the pipe form — same wiring, same behaviour" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "every 1f { inc plane.n 1 }", .{});
    defer fx.deinit();
    // Structure: the branch leaves from every's own output slot.
    const src = fx.prog.node(nodeIdOf(&fx.prog, "every1").?).outputs[0];
    try testing.expectEqual(src, fx.prog.slot(fx.prog.node(nodeIdOf(&fx.prog, "inc1").?).inputs[0]).source.wire);
    // Behaviour: the standing-caster idiom stands.
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(f64, 3), types.asNumber(fx.mock.store.get("plane.n").?).?);
}

test "block rule: the brazier — every driving a standing cast, three lines of no Zig" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "every 1f { cast $torchlight 0.8 radius 12 at plane.brazier decay 4s }", .{
        .{ "plane.brazier", @as(i64, 3) },
    });
    defer fx.deinit();
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(usize, 3), fx.mock.casts.items.len);
    for (fx.mock.casts.items) |c| {
        try testing.expectEqualStrings("$torchlight", c.channel);
        try testing.expectEqual(@as(f64, 0.8), c.amplitude);
    }
}

test "block rule: any source takes a block, and branches are branches" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.hp {
        \\    write plane.a
        \\    write plane.b
        \\}
    );
    defer prog.deinit();
    const s1 = prog.slot(prog.node(nodeIdOf(&prog, "write1").?).inputs[0]).source;
    const s2 = prog.slot(prog.node(nodeIdOf(&prog, "write2").?).inputs[0]).source;
    try testing.expectEqualStrings("plane.hp", s1.plane);
    try testing.expectEqualStrings("plane.hp", s2.plane);
}

test "block rule: the also guards carry over, and mid-chain blocks name their spelling" {
    // A block is a fan-out, not a body — every also-rule holds at the head.
    try expectParseError("every 1f { }", "empty block");
    try expectParseError("every 1f { tap t as x }", "no name escapes");
    try expectParseError("every 1f { plane.x | write plane.a }", "begin with an operator");
    // Mid-chain, the word is `also` — one spelling per position.
    try expectParseError("plane.x | mul 2 { write plane.a }", "ride 'also");
}

test "block rule: a serialized caster survives the round trip, cadence intact" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.brazier", @as(i64, 3));
    var prog = try parseOk(testing.allocator, &reg, "every 2f { cast $torchlight 0.8 radius 12 at plane.brazier }");
    defer prog.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    const d1 = try rill.serialize.dump(&rt, testing.allocator);
    defer testing.allocator.free(d1);

    var prog2 = try rill.serialize.loadProgram(testing.allocator, &reg, d1);
    defer prog2.deinit();
    try testing.expectEqualStrings("$torchlight", prog2.node(nodeIdOf(&prog2, "cast1").?).statics[0].channel);
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    try mock2.putValue("plane.brazier", @as(i64, 3));
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.serialize.restoreState(&rt2, d1);
    const d2 = try rill.serialize.dump(&rt2, testing.allocator);
    defer testing.allocator.free(d2);
    try testing.expectEqualSlices(u8, d1, d2); // G8 holds with the new static kind

    // The restored metronome still knows when it is due: mount fired at
    // frame 0, so frame 2 is the next firing — restore does not re-fire
    // tick 0 (a dump is a live snapshot, not a birth certificate).
    try rt2.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(usize, 0), mock2.casts.items.len);
    try rt2.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(usize, 1), mock2.casts.items.len);
}

test "cast: in an also branch it is an effect — no discard warning" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | also { cast $dread 0.5 radius 8 at plane.here } | tap seen");
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 0), prog.warnings.items.len);
}

// ---------------------------------------------------------------------------
// The comment move (ruled 2026-08-25): `#` is the tag sigil and cannot also
// be the comment lead, so comments are `//`. The token-boundary pin is
// structural — a name-interior `/` must join two name characters, so no
// slash-form path literal can put two slashes adjacent inside a token.
// ---------------------------------------------------------------------------

test "comments: `//` to end of line, full-line and trailing, either side of a name" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\// a full-line comment
        \\plane.hp | mul 2 // after a number token
        \\  | write plane.out// flush against a name: the name cannot eat the slashes
    , .{.{ "plane.hp", @as(i64, 4) }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 8), types.asNumber(fx.mock.store.get("plane.out").?).?);
}

test "comments: slash-form path literals never trip the comment rule" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    // `render/grade/exposure` is one word (single slashes join name chars);
    // the `//` after it is a comment.
    var prog = try parseOk(testing.allocator, &reg, "plane.v | tap render/grade/exposure // knob path survives");
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "tap1").?);
    try testing.expectEqualStrings("render/grade/exposure", n.statics[0].word);
}

test "comments: `#` no longer comments — it is an inert sigil awaiting the tag beat" {
    try expectParseError("# this used to be a comment", "expected an expression");
}

test "comments: a tail keeps `//` and `#` as text — the tail takes the raw line" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "sound play pack:horns#audio.stem//v2", .{});
    defer fx.deinit();
    const echoed = fx.rt.readSlot("programs.p.sound play1.out.out").?;
    try testing.expectEqualStrings("pack:horns#audio.stem//v2", types.asString(echoed).?);
}

// ---------------------------------------------------------------------------
// The manuals are front doors, and a front door needs a gate (the demo-exe
// lesson: `as stats` sat broken for a quarter because building never parsed
// it). Every ```rill block in both manuals parses here — if it's printed,
// it compiles. Blocks that are deliberately console-side (chanarche lines)
// are fenced ```console and not collected.
// ---------------------------------------------------------------------------

fn parseManual(doc: []const u8, reg: *rill.Registry, doc_name: []const u8) !usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, doc, pos, "```rill\n")) |start| {
        const body_start = start + "```rill\n".len;
        const end = std.mem.indexOfPos(u8, doc, body_start, "```") orelse {
            std.debug.print("{s}: unterminated ```rill fence\n", .{doc_name});
            return error.TestUnexpectedResult;
        };
        const src = doc[body_start..end];
        var diag = rill.Diag{};
        var prog = rill.parse(testing.allocator, reg, "manual", src, &diag) catch |err| {
            if (err == error.Parse) {
                std.debug.print("{s}: example failed to parse — {s} (line {d}, col {d}):\n{s}\n", .{ doc_name, diag.msg(), diag.line, diag.col, src });
            }
            return err;
        };
        prog.deinit();
        count += 1;
        pos = end;
    }
    return count;
}

test "the manuals parse: every printed example compiles" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const human = try parseManual(@embedFile("rill-manual.md"), &reg, "rill-manual.md");
    const agent = try parseManual(@embedFile("rill-for-agents.md"), &reg, "rill-for-agents.md");
    // The README too, and for a sharper reason than the manuals: it is the
    // FRONT DOOR, and the example on it did not parse. `play heartbeat` named
    // an operator that has never existed and `#` opened a comment in a
    // language whose comment is `//` (`#` is the tag sigil), so the first
    // fourteen lines anyone read were fiction. Found 2026-08-27, while adding
    // a sentence claiming these blocks were gated — they were not, and the
    // sentence is what made it worth checking.
    const readme = try parseManual(@embedFile("README.md"), &reg, "README.md");
    try testing.expect(readme >= 4);
    // The RBF pack's words doc, gated the same way and registered into the
    // same `hostRegistry` — its three examples are the only printed record of
    // how `rbf bump` and `rbf through` are spelled. Counted both ways, like
    // the manuals: a doc whose examples silently stopped being collected
    // would pass vacuously.
    const rbf_doc = try parseManual(@embedFile("rbf-words.md"), &reg, "rbf-words.md");
    try testing.expectEqual(@as(usize, 3), rbf_doc);
    // Both ways, like the class table: a manual whose examples silently
    // stopped being collected would pass vacuously. Update on purpose when
    // examples are added or removed.
    // 28 → 30 (2026-08-25): the tags-campaign parity pass added the
    // membership muster and the coupled cast to the human manual's §7.
    // 30 → 32, 3 → 4 (2026-08-25): tier-2 beat 1a added §6b (movement) to
    // the human manual — the waveform trio and the register examples — and
    // the register line to the agent manual's temporal row.
    // 32 → 33 (beat 1b): the human manual's §6b gained the broadcast trio.
    // 33 → 34 (beat 2a): the human manual gained §6c (arrays).
    // 34 → 35 (beat 2b): the human manual gained §6d (contracts). The shape
    // literal block in that section is deliberately NOT tagged ```rill — a
    // shape is not a program, and tagging it would ask the parser to mount a
    // type.
    // 35 → 37 (beat 3a): the human manual gained §6d (over arrays) — the body
    // trio and the keep-vs-where crossing pair.
    // 37 → 38 (beat 3b): the human manual's §6d gained the order-and-shape
    // quartet.
    // 38 → 39 (beat 4): the human manual gained §6f (events, levels, noise
    // and space).
    // 39 → 45 (tier-2 close, the manuals parity pass): §11 gains six recipes
    // — the breathing exposure, the fade that stops, the threshold that does
    // not chatter, the nearest threat, the boundary contract, the camera
    // shake. The campaign's whole vocabulary, in the section a person reads
    // when they want to copy something that works.
    // 45 → 46 (envelopes, `first`-on-empty): §6d gains the two-line pair that
    // IS the ruling — the pick that goes quiet, and the count that speaks.
    // 46 → 48 (envelopes, `kick`): §6b gains the envelope trio — the flash,
    // the shake, and the same flash curved by `shape` — and §11 gains the
    // flash as a recipe, because it is the re-probe's biggest finding and §11
    // is where a person goes to copy something that works.
    // `adsr` adds no BLOCK: it lands in the same §6b listing, because `kick`
    // and `adsr` are one family and printing them apart would teach them so.
    // 48 → 49 (envelopes, `step`): §6c gains the sequencer trio — camera
    // positions on a key, an arpeggio, and a hint picked at random.
    // 49 → 50 (elementwise kinds): §2 gains the line that carries the ruling —
    // an occurrence scaled on its way into an envelope. §2 already claimed
    // "most operators pass the kind through" while `mul` did not, so the
    // documentation was right and the code was wrong; the example is there so
    // the claim is now something this gate parses rather than prose.
    // 50 → 51 (`using`, 2026-09-08): §10 gains the argument-position example,
    // which is the one thing a fold does that a `def` structurally cannot —
    // and the section's other two blocks moved from `use` to `using`.
    // 51 → 53 (the parameter pack, 2026-09-08): §10 gains the defaults-and-
    // range trio and the exported-and-described `roaches`. Both are fenced
    // ```rill so this gate parses the claims rather than the reader trusting
    // them — which matters more here than usual, since the second block is
    // the whole parity gate written out.
    // 53 → 54 (an effect returns its input, 2026-09-08): §4 gains the
    // mid-chain tap, which is the whole ruling in one line and the only place
    // the manual shows a chain continuing past a sink.
    // 54 → 55 (`@self` in a def body, 2026-09-08): §10 gains the def that
    // drives its own instance's knob. Fenced ```rill on purpose — that it
    // parses at all is the whole beat, so this gate reads the claim.
    // 55 → 56 (the plane declaration, 2026-09-08): §10 gains "Which plane a
    // def runs on" and its `on row` def. Fenced ```rill for the same reason
    // the `@self` driver is: that a row def parses inside a WORLD program is
    // half the ruling, and this gate parses with `rill.parse`.
    // 56 → 57 (the `layout` block, 2026-09-09): §10a. Fenced ```rill because
    // the block is rill, not prose about rill — the gate two thousand lines
    // below then holds its COLUMNS to the canon, which is the half a parse
    // gate cannot see.
    // 57 → 58 (shaped holes, 2026-09-09): §10's `using` section gains the
    // hole. Fenced because "it parses" IS the claim — a statement whose
    // argument is bound to nothing is the thing the language could not say.
    try testing.expectEqual(@as(usize, 58), human);
    // 4 → 5 (`using`, 2026-09-08): §2 gains the fold, and the block is a
    // ```rill fence so this gate reads it rather than the reader trusting it.
    // 5 → 6 (the parameter pack, same day): §2 gains `export def roaches`.
    // 6 → 7 (`@self` in a def body, same day): §2 gains the relative driver.
    // 7 → 8 (the plane declaration, 2026-09-08): §2 gains the exported row
    // def. It parses under `rill.parse` — a row def inside a world program —
    // which is itself half of what the beat ruled.
    try testing.expectEqual(@as(usize, 8), agent);
}

// ---------------------------------------------------------------------------
// The refusals gate (ruled 2026-08-25, after beat 1a segfaulted Matryoshka).
//
// The bug was a use-after-free in a refusal MESSAGE — code that had never been
// executed by a test, because every gate in both repos drove the accepting
// path. The wire gate covers accepts. This covers the other half.
//
// Structural, not a list: it WALKS THE REGISTRY and builds a driver for each
// op from its own port and static declarations, so a new operator is covered
// the moment it registers. An op that cannot be driven into a refusal has to
// say so on the `accepts_anything` list below, on purpose — exhaustive both
// ways, like the class and ticks audits.
//
// What it asserts, for every op: the refusal ARRIVES, and its message FORMATS
// — node, op and detail printed into a buffer under the testing allocator, so
// a slice into freed memory is caught here rather than in a host a quarter
// later. Ack first, then free, everywhere.
// ---------------------------------------------------------------------------

/// Ops that accept a string on port 0 and are right to. Each is a fact worth
/// pinning rather than an exemption: a sink writes whatever flows, `tap`
/// passes anything through by definition, and a source has no input to
/// poison.
const accepts_anything = [_][]const u8{
    // sources — no input port to feed
    "clock",    "frame",    "pi",        "tau",    "const", // sinks and passthroughs — any value is a legal payload
    "write",    "notify",   "tap",       "record",
    // value-agnostic flow: these move bytes without reading them
    "latch",
    "changed",  "where",    "partition", "sample", "debounce",
    "throttle", "cooldown", "delay",     "window", "arm",
    "disarm",   "=",        "!=",        "tag",    "untag",
    // `once` and `toggle` and `tally` move or count arrivals without reading
    // them: any value is a legal thing to pass, flip on, or count.
    "once",     "toggle",   "tally",
    // `rand` reads only WHETHER it was roused, never what with.
        "rand",
    // `kick` is roused, not read: an envelope fires on the ARRIVAL, and what
    // the occurrence happens to be carrying is none of its business.
      "kick",
    // `array` packs its ports without reading them, exactly as `record` does:
    // every value is a legal element, and there is nothing left to refuse.
    "array",
};

/// Ops whose generated driver needs a hand — a `tail` port swallows the rest
/// of the line, membership sinks need a host, and `project` needs a record.
const driver_overrides = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "tag", .source = "plane.bad | tag @e #t" },
    .{ .name = "untag", .source = "plane.bad | untag @e #t" },
    .{ .name = "inc", .source = "plane.bad | inc plane.out plane.bad" },
    .{ .name = "project", .source = "plane.bad | project f | write plane.out" },
    .{ .name = "stats", .source = "plane.bad | stats | write plane.out" },
};

/// A syntactically valid filler for a port, from its declared type — so the
/// driver exercises the port under test and nothing else.
fn fillerFor(port: registry.Port) []const u8 {
    if (port.one_of.len > 0) return port.one_of[0];
    return switch (port.ty) {
        types.Tag.number => "1",
        types.Tag.boolean => "true",
        types.Tag.string => "\"x\"",
        types.Tag.duration => "1s",
        types.Tag.record => "{a: 1}",
        types.Tag.array => "[1]",
        else => "1",
    };
}

fn staticFiller(kind: registry.StaticKind) []const u8 {
    return switch (kind) {
        .path => "plane.out",
        .word => "w",
        .literal => "1",
        .channel => "$c",
        .subject => "@e",
        .condition => "#t",
        .shape => "{a: number}",
    };
}

/// Build `plane.bad | <op> <fillers…> | write plane.out` from the definition.
/// Returns null when the shape can't be driven generically (a tail port takes
/// the rest of the line; a variadic op has no declared ports).
fn driverFor(gpa: std.mem.Allocator, def: registry.OpDef) !?[]u8 {
    if (def.variadic) return null;
    for (def.inputs) |p| if (p.tail) return null;

    var src = std.ArrayListUnmanaged(u8).empty;
    errdefer src.deinit(gpa);
    try src.appendSlice(gpa, "plane.bad | ");
    try src.appendSlice(gpa, def.name);
    // Statics come first in source order for the ops that have them.
    for (def.statics) |st| {
        try src.append(gpa, ' ');
        if (st.kw) {
            try src.appendSlice(gpa, st.name);
            try src.append(gpa, ' ');
        }
        try src.appendSlice(gpa, staticFiller(st.kind));
    }
    // Port 0 is the piped one under test; the rest get fillers.
    for (def.inputs, 0..) |p, i| {
        if (i == 0 or p.optional) continue;
        try src.append(gpa, ' ');
        if (p.kw) {
            try src.appendSlice(gpa, p.name);
            try src.append(gpa, ' ');
        }
        try src.appendSlice(gpa, fillerFor(p));
    }
    if (def.outputs.len > 0 and !def.class.writes()) {
        try src.appendSlice(gpa, " | write plane.out");
    }
    return try src.toOwnedSlice(gpa);
}

test "every operator's refusal path runs, and its message formats" {
    const gpa = testing.allocator;
    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    var covered: usize = 0;
    var accepted: usize = 0;

    for (reg.ops.items) |def| {
        const on_list = for (accepts_anything) |n| {
            if (std.mem.eql(u8, n, def.name)) break true;
        } else false;

        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        var source: []const u8 = undefined;
        const override = for (driver_overrides) |o| {
            if (std.mem.eql(u8, o.name, def.name)) break o.source;
        } else null;
        if (override) |o| {
            source = o;
        } else {
            owned = try driverFor(gpa, def);
            if (owned == null) {
                // Variadic or tail-shaped: no generic driver exists. It has to
                // be on the list on purpose, and it still counts toward
                // coverage so the totals stay honest.
                if (!on_list) {
                    std.debug.print("'{s}': cannot be driven generically and is not on a list — add a driver override or say it accepts anything\n", .{def.name});
                    return error.TestUnexpectedResult;
                }
                accepted += 1;
                continue;
            }
            source = owned.?;
        }

        // A parse-time refusal is a refusal, and its message must format too.
        var diag = rill.Diag{};
        var prog = rill.parse(gpa, &reg, "p", source, &diag) catch |err| {
            if (err != error.Parse) return err;
            if (diag.msg().len == 0) {
                std.debug.print("'{s}': refused at parse with an empty message\n", .{def.name});
                return error.TestUnexpectedResult;
            }
            try formatsCleanly(&.{ diag.msg(), def.name });
            covered += 1;
            continue;
        };
        defer prog.deinit();

        var mock = rill.MockPlane.init(gpa);
        defer mock.deinit();
        // A string where the op wants a number or a boolean — the one poison
        // that every typed port shares.
        try mock.putValue("plane.bad", "not-a-number");
        Refusal.reset();
        var rt = rill.Runtime.mount(gpa, &prog, mock.asPlane(), .{ .error_fn = Refusal.on }) catch |err| {
            // `Refused` is a `fails_mount` op turning the mount down at tick 0
            // (`expect`). That IS its refusal path, and the ack fired before
            // the mount unwound — so the message is still checkable, and it
            // gets checked exactly like every other one.
            if (err == error.Refused) {
                if (Refusal.hits == 0) {
                    std.debug.print("'{s}': failed the mount without an ack — the words must reach error_fn first\n", .{def.name});
                    return error.TestUnexpectedResult;
                }
                try formatsCleanly(&.{ Refusal.opName(), Refusal.text(), def.name });
                if (std.mem.indexOf(u8, Refusal.text(), def.name) == null) {
                    std.debug.print("'{s}': mount refusal \"{s}\" does not name the operator\n", .{ def.name, Refusal.text() });
                    return error.TestUnexpectedResult;
                }
                covered += 1;
                continue;
            }
            if (err != error.Cycle) return err;
            covered += 1;
            continue;
        };
        defer rt.deinit();

        if (Refusal.hits == 0) {
            if (!on_list) {
                std.debug.print("'{s}': took a string without complaint and is not on the accepts-anything list\n  driver: {s}\n", .{ def.name, source });
                return error.TestUnexpectedResult;
            }
            accepted += 1;
            continue;
        }
        if (on_list) {
            std.debug.print("'{s}': is on the accepts-anything list but refused — take it off\n", .{def.name});
            return error.TestUnexpectedResult;
        }
        // The message formats. This is the assertion the segfault would have
        // failed: printing a refusal must not read memory the refusal freed.
        // The message FORMATS — this is the assertion the segfault would have
        // failed: printing a refusal must not read memory the refusal freed.
        try formatsCleanly(&.{ Refusal.opName(), Refusal.text(), def.name });
        // …and it SAYS SOMETHING. `@errorName` gives "BadValue", which names
        // the category and not the fact, and the fact is what a reader needs.
        // This gate found 21 of 54 refusal paths silent; fixing the four
        // shared accessors fixed all but five of them, which is the argument
        // for the accessors being where refusals belong.
        if (Refusal.text().len == 0) {
            std.debug.print("'{s}': refused without saying why — `ctx.refuse` instead of a bare BadValue\n  driver: {s}\n", .{ def.name, source });
            return error.TestUnexpectedResult;
        }
        // A refusal names the op that refused, so an ack can land on the node
        // by name without the host guessing.
        if (std.mem.indexOf(u8, Refusal.text(), def.name) == null) {
            std.debug.print("'{s}': refusal \"{s}\" does not name the operator\n", .{ def.name, Refusal.text() });
            return error.TestUnexpectedResult;
        }
        covered += 1;
    }

    // Both ways. The counts move when the operator set does, on purpose.
    if (covered + accepted != reg.ops.items.len) {
        std.debug.print("{d} ops, {d} refused, {d} accepted — someone is uncovered\n", .{ reg.ops.items.len, covered, accepted });
        return error.TestUnexpectedResult;
    }
    try testing.expect(covered > 0);
}

/// Print the pieces into a buffer. Under the testing allocator a slice into
/// freed memory faults or reads poison here, at the gate, instead of in a
/// host's console log a quarter later.
fn formatsCleanly(pieces: []const []const u8) !void {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    for (pieces) |p| {
        const w = std.fmt.bufPrint(buf[n..], "[{s}]", .{p}) catch break;
        n += w.len;
    }
    if (n == 0) return error.TestUnexpectedResult;
}

// -- container readers, for the broadcast gates ------------------------------

/// The inner element stream of a container, caller-owned.
fn innerOf(gpa: std.mem.Allocator, encoded: []const u8) ![]u8 {
    return (try struple.view(encoded).containedItems(gpa)) orelse error.TestUnexpectedResult;
}

/// A field name is OWNED, not borrowed: the name lives in the un-escaped
/// inner buffer, which this helper frees before returning. (Borrowing it read
/// as garbage — the same shape as the Matryoshka use-after-free this campaign
/// already fixed once, which is a fair argument for "ack first, then free"
/// being a rule rather than a habit. The first fix copied into a fixed
/// `[24]u8` initialised `undefined`, which passed in Debug and produced
/// garbage in ReleaseFast — so there is no undefined memory here at all now.)
const Field = struct { k: []u8, v: f64 };

fn freeFields(gpa: std.mem.Allocator, fields: []Field) void {
    for (fields) |f| gpa.free(f.k);
    gpa.free(fields);
}

fn fieldName(f: Field) []const u8 {
    return f.k;
}

/// A record's fields as {name, number}, in canonical (sorted) key order.
fn recordFields(gpa: std.mem.Allocator, encoded: []const u8) ![]Field {
    const inner = try innerOf(gpa, encoded);
    defer gpa.free(inner);
    var out = std.ArrayListUnmanaged(Field).empty;
    errdefer {
        for (out.items) |f| gpa.free(f.k);
        out.deinit(gpa);
    }
    var it = struple.MapView.init(inner).iterator();
    while (try it.next()) |e| {
        // MapView yields the ENCODED key element; decode it, then own it.
        const name = types.asString(e.key) orelse "?";
        try out.append(gpa, .{
            .k = try gpa.dupe(u8, name),
            .v = types.asNumber(e.value) orelse std.math.nan(f64),
        });
    }
    return out.toOwnedSlice(gpa);
}

/// One field of a record, copied out (the value borrows the un-escaped inner
/// buffer, which this frees). Keys are looked up by their ENCODED element,
/// which is what `MapView.get` wants.
fn fieldValue(gpa: std.mem.Allocator, encoded: []const u8, name: []const u8) ![]u8 {
    const inner = try innerOf(gpa, encoded);
    defer gpa.free(inner);
    var kp = struple.Packer.init(gpa);
    defer kp.deinit();
    try kp.appendString(name);
    const v = (try struple.MapView.init(inner).get(kp.bytes())) orelse return error.TestUnexpectedResult;
    return gpa.dupe(u8, v);
}

fn arrayNums(gpa: std.mem.Allocator, encoded: []const u8) ![]f64 {
    const inner = try innerOf(gpa, encoded);
    defer gpa.free(inner);
    var out = std.ArrayListUnmanaged(f64).empty;
    errdefer out.deinit(gpa);
    var r = struple.reader(inner);
    while (try r.nextView()) |e| try out.append(gpa, types.asNumber(e) orelse std.math.nan(f64));
    return out.toOwnedSlice(gpa);
}

fn arrayBools(gpa: std.mem.Allocator, encoded: []const u8) ![]bool {
    const inner = try innerOf(gpa, encoded);
    defer gpa.free(inner);
    var out = std.ArrayListUnmanaged(bool).empty;
    errdefer out.deinit(gpa);
    var r = struple.reader(inner);
    while (try r.nextView()) |e| try out.append(gpa, types.asBool(e) orelse false);
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tier 2, beat 1b — broadcast, and the mismatch check that pays for it.
//
// They land together (ratified). The gates come in pairs to match: for every
// shape that broadcasts, one that refuses — and each refusal is asserted on
// its MESSAGE, not just on the fact of failing. A gate that only asserts "it
// errored" is the ICE failure re-shipped: ICE had broadcast and reported
// mismatches without naming the contexts, and that error was the one every
// user learned to dread.
// ---------------------------------------------------------------------------

/// Mount `source`, feed nothing, and return the refusal detail for the first
/// node that failed. The message is the thing under test, so this returns it
/// rather than a bool.
const Refusal = struct {
    var hits: usize = 0;
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    var op: [64]u8 = undefined;
    var op_len: usize = 0;

    fn on(_: ?*anyopaque, ev: rill.eval.ErrorEvent) void {
        hits += 1;
        len = @min(ev.detail.len, buf.len);
        @memcpy(buf[0..len], ev.detail[0..len]);
        op_len = @min(ev.op.len, op.len);
        @memcpy(op[0..op_len], ev.op[0..op_len]);
    }

    fn text() []const u8 {
        return buf[0..len];
    }

    fn opName() []const u8 {
        return op[0..op_len];
    }

    fn reset() void {
        hits = 0;
        len = 0;
        op_len = 0;
    }
};

/// Mount `source` over a seeded plane with the refusal sink attached, tick
/// once, and hand back the fixture. Callers assert on `Refusal`.
fn mountWatched(gpa: std.mem.Allocator, fx: *Fixture, source: []const u8, seed: anytype) !void {
    Refusal.reset();
    fx.reg = try hostRegistry(gpa);
    errdefer fx.reg.deinit();
    fx.mock = rill.MockPlane.init(gpa);
    errdefer fx.mock.deinit();
    inline for (seed) |kv| try fx.mock.putValue(kv[0], kv[1]);
    var diag = rill.Diag{};
    fx.prog = rill.parse(gpa, &fx.reg, "p", source, &diag) catch |err| {
        if (err == error.Parse) std.debug.print("parse: {s} (line {d}, col {d})\n", .{ diag.msg(), diag.line, diag.col });
        return err;
    };
    errdefer fx.prog.deinit();
    fx.rt = try rill.Runtime.mount(gpa, &fx.prog, fx.mock.asPlane(), .{ .error_fn = Refusal.on });
}

/// Assert the refusal names every one of `needles`. "Both sides and the
/// offending field" is a checkable claim, so it gets checked.
fn expectRefusalNames(needles: []const []const u8) !void {
    if (Refusal.hits == 0) {
        std.debug.print("expected a refusal, none arrived\n", .{});
        return error.TestUnexpectedResult;
    }
    for (needles) |n| {
        if (std.mem.indexOf(u8, Refusal.text(), n) == null) {
            std.debug.print("refusal \"{s}\" does not mention \"{s}\"\n", .{ Refusal.text(), n });
            return error.TestUnexpectedResult;
        }
    }
}

test "beat 1b: a scalar broadcasts over a record — the follow row, one line" {
    // §4's "keep a light 2m above the player", which was ~3 lines and a
    // rebuilt record. Now it is the sentence.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.entities.player.pos | add {x: 0, y: 2, z: 0} | write plane.lights.follow.pos", .{.{ "plane.entities.player.pos", .{ .x = @as(f64, 1), .y = @as(f64, 5), .z = @as(f64, -3) } }});
    defer fx.deinit();

    const r = try recordFields(testing.allocator, fx.rt.readSlot("programs.p.add1.out.out").?);
    defer freeFields(testing.allocator, r);
    // Canonical key order, and only the field that was asked for has moved.
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqualStrings("x", fieldName(r[0]));
    try testing.expectEqual(@as(f64, 1), r[0].v);
    try testing.expectEqualStrings("y", fieldName(r[1]));
    try testing.expectEqual(@as(f64, 7), r[1].v);
    try testing.expectEqualStrings("z", fieldName(r[2]));
    try testing.expectEqual(@as(f64, -3), r[2].v);

    // And it reached the plane as a record, not as three writes.
    try testing.expectEqual(@as(usize, 1), fx.mock.writes.items.len);
    try testing.expectEqual(types.Tag.record, types.typeOfValue(fx.mock.writes.items[0].value));
}

test "beat 1b: scalar over record, record over scalar, and both orders agree" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.p | mul 2 | write plane.a
        \\plane.p | sub 1 | write plane.b
    , .{.{ "plane.p", .{ .x = @as(f64, 3), .y = @as(f64, 4) } }});
    defer fx.deinit();
    const a = try recordFields(testing.allocator, fx.rt.readSlot("programs.p.mul1.out.out").?);
    defer freeFields(testing.allocator, a);
    try testing.expectEqual(@as(f64, 6), a[0].v); // x
    try testing.expectEqual(@as(f64, 8), a[1].v); // y
    const b = try recordFields(testing.allocator, fx.rt.readSlot("programs.p.sub1.out.out").?);
    defer freeFields(testing.allocator, b);
    try testing.expectEqual(@as(f64, 2), b[0].v);
    try testing.expectEqual(@as(f64, 3), b[1].v);
}

test "beat 1b: record ⊗ record is elementwise on the same field set" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.a | add plane.b | write plane.o", .{
        .{ "plane.a", .{ .x = @as(f64, 1), .y = @as(f64, 2) } },
        .{ "plane.b", .{ .x = @as(f64, 10), .y = @as(f64, 20) } },
    });
    defer fx.deinit();
    const r = try recordFields(testing.allocator, fx.rt.readSlot("programs.p.add1.out.out").?);
    defer freeFields(testing.allocator, r);
    try testing.expectEqual(@as(f64, 11), r[0].v);
    try testing.expectEqual(@as(f64, 22), r[1].v);
}

test "beat 1b: record ⊗ record with a different field set REFUSES, naming the field" {
    // No implicit intersection. An intersection quietly computes over the
    // fields that happen to agree, which is a wrong answer wearing a right
    // one's clothes — and it is exactly what ICE users learned to dread.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx, "plane.a | add plane.b | write plane.o", .{
        .{ "plane.a", .{ .x = @as(f64, 1), .y = @as(f64, 2), .z = @as(f64, 3) } },
        .{ "plane.b", .{ .x = @as(f64, 10), .y = @as(f64, 20) } },
    });
    defer fx.deinit();
    // Both sides named, the offending field named, and which side lacks it.
    try expectRefusalNames(&.{ "add", "record{x, y, z}", "record{x, y}", "'z'", "right" });
    // …and the wave died: nothing was written from a mismatch.
    try testing.expectEqual(@as(usize, 0), fx.mock.writes.items.len);
}

test "beat 1b: the missing field is named on whichever side lacks it" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx, "plane.a | add plane.b | write plane.o", .{
        .{ "plane.a", .{ .x = @as(f64, 1) } },
        .{ "plane.b", .{ .x = @as(f64, 1), .w = @as(f64, 2) } },
    });
    defer fx.deinit();
    try expectRefusalNames(&.{ "'w'", "left" });
}

test "beat 1b: array ⊗ array is elementwise, and unequal lengths refuse with both" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | window 10s | mul 2 | write plane.o", .{.{ "plane.v", @as(f64, 3) }});
    defer fx.deinit();
    // `window 10s | mul 2` IS map — the draft's own claim, executed.
    const arr = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.mul1.out.out").?);
    defer testing.allocator.free(arr);
    try testing.expectEqual(@as(usize, 1), arr.len);
    try testing.expectEqual(@as(f64, 6), arr[0]);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2, "plane.a | add plane.b | write plane.o", .{
        .{ "plane.a", [_]f64{ 1, 2, 3 } },
        .{ "plane.b", [_]f64{ 10, 20 } },
    });
    defer fx2.deinit();
    // Both LENGTHS named. Grasshopper picks a matching rule implicitly and it
    // is the most-complained-about behaviour in the tool.
    try expectRefusalNames(&.{ "add", "of 3", "of 2", "same length" });
}

test "beat 1b: a record and an array have no elementwise meaning" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx, "plane.a | add plane.b | write plane.o", .{
        .{ "plane.a", .{ .x = @as(f64, 1), .y = @as(f64, 2) } },
        .{ "plane.b", [_]f64{ 1, 2 } },
    });
    defer fx.deinit();
    try expectRefusalNames(&.{ "record{x, y}", "[number]", "no elementwise meaning" });
}

test "beat 1b: nesting recurses, and a non-numeric leaf is named where it lives" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.a | mul 2 | write plane.o", .{.{ "plane.a", .{ .inner = .{ .x = @as(f64, 3) } } }});
    defer fx.deinit();
    const nested = try fieldValue(testing.allocator, fx.rt.readSlot("programs.p.mul1.out.out").?, "inner");
    defer testing.allocator.free(nested);
    const leaf = try recordFields(testing.allocator, nested);
    defer freeFields(testing.allocator, leaf);
    try testing.expectEqualStrings("x", fieldName(leaf[0]));
    try testing.expectEqual(@as(f64, 6), leaf[0].v);

    // A string two levels down is named by its PATH, not merely reported.
    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2, "plane.a | mul 2 | write plane.o", .{.{ "plane.a", .{ .inner = .{ .name = "tom" } } }});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "mul", "string", "not a number", ".inner.name" });
}

test "beat 1b: comparators broadcast — beat 3's keep depends on it" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.a | > 0 | write plane.o", .{.{ "plane.a", [_]f64{ 1, -2, 3 } }});
    defer fx.deinit();
    const bits = try arrayBools(testing.allocator, fx.rt.readSlot("programs.p.gt1.out.out").?);
    defer testing.allocator.free(bits);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, bits);
}

test "beat 1b: and/or/not broadcast over containers too" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.flags | not | write plane.a
        \\plane.flags | and true | write plane.b
    , .{.{ "plane.flags", [_]bool{ true, false } }});
    defer fx.deinit();
    const n = try arrayBools(testing.allocator, fx.rt.readSlot("programs.p.not1.out.out").?);
    defer testing.allocator.free(n);
    try testing.expectEqualSlices(bool, &.{ false, true }, n);
    const a = try arrayBools(testing.allocator, fx.rt.readSlot("programs.p.and1.out.out").?);
    defer testing.allocator.free(a);
    try testing.expectEqualSlices(bool, &.{ true, false }, a);
}

test "beat 1b: `=` does NOT broadcast, deliberately" {
    // The line, and the reason for it: `<` has no meaning on a whole record —
    // there is no total order on records — so elementwise is the ONLY reading.
    // `=` has an exact meaning on a whole record, so broadcasting would
    // REPLACE a good answer with a different one. Whole-value equality stays.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.a | = plane.b | write plane.same
        \\plane.a | = plane.c | write plane.other
    , .{
        .{ "plane.a", .{ .x = @as(f64, 1), .y = @as(f64, 2) } },
        .{ "plane.b", .{ .x = @as(f64, 1), .y = @as(f64, 2) } },
        .{ "plane.c", .{ .x = @as(f64, 1), .y = @as(f64, 9) } },
    });
    defer fx.deinit();
    // The inequality first: these inputs are two-field records, so a
    // broadcasting `=` would produce a RECORD of two booleans and a
    // whole-value `=` produces one boolean. The two answers differ in kind,
    // which is what makes the assertion below mean anything.
    const eq_out = fx.rt.readSlot("programs.p.eq1.out.out").?;
    try testing.expect(types.typeOfValue(eq_out) != types.Tag.record);
    try testing.expectEqual(types.Tag.boolean, types.typeOfValue(eq_out));
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.eq1.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.eq2.out.out").?).?);
}

test "beat 1b: the tier-1 math words are re-scored against containers" {
    // Chris's condition on the split: binMath is touched THIS beat and never
    // again, so every word minted by it is scored here against a record and an
    // array — not just the two that happened to have a customer.
    const Case = struct { src: []const u8, node: []const u8, want: [2]f64 };
    const cases = [_]Case{
        .{ .src = "plane.v | add 1 | write plane.o", .node = "add1", .want = .{ 4, -1 } },
        .{ .src = "plane.v | sub 1 | write plane.o", .node = "sub1", .want = .{ 2, -3 } },
        .{ .src = "plane.v | mul 3 | write plane.o", .node = "mul1", .want = .{ 9, -6 } },
        .{ .src = "plane.v | div 2 | write plane.o", .node = "div1", .want = .{ 1.5, -1 } },
        .{ .src = "plane.v | min 0 | write plane.o", .node = "min1", .want = .{ 0, -2 } },
        .{ .src = "plane.v | max 0 | write plane.o", .node = "max1", .want = .{ 3, 0 } },
        .{ .src = "plane.v | abs | write plane.o", .node = "abs1", .want = .{ 3, 2 } },
        .{ .src = "plane.v | floor | write plane.o", .node = "floor1", .want = .{ 3, -2 } },
        .{ .src = "plane.v | ceil | write plane.o", .node = "ceil1", .want = .{ 3, -2 } },
        .{ .src = "plane.v | round | write plane.o", .node = "round1", .want = .{ 3, -2 } },
        .{ .src = "plane.v | sign | write plane.o", .node = "sign1", .want = .{ 1, -1 } },
        .{ .src = "plane.v | pow 2 | write plane.o", .node = "pow1", .want = .{ 9, 4 } },
        .{ .src = "plane.v | mod 4 | write plane.o", .node = "mod1", .want = .{ 3, 2 } },
        .{ .src = "plane.v | sqrt | write plane.o", .node = "sqrt1", .want = .{ 1.7320508075688772, std.math.nan(f64) } },
    };
    inline for (cases) |c| {
        // as a record…
        var fx: Fixture = undefined;
        try mountFixture(testing.allocator, &fx, c.src, .{.{ "plane.v", .{ .a = @as(f64, 3), .b = @as(f64, -2) } }});
        defer fx.deinit();
        const path = "programs.p." ++ c.node ++ ".out.out";
        const r = try recordFields(testing.allocator, fx.rt.readSlot(path).?);
        defer freeFields(testing.allocator, r);
        try expectSameFloat(c.want[0], r[0].v, c.node);
        try expectSameFloat(c.want[1], r[1].v, c.node);

        // …and as an array, which must agree element for element.
        var fx2: Fixture = undefined;
        try mountFixture(testing.allocator, &fx2, c.src, .{.{ "plane.v", [_]f64{ 3, -2 } }});
        defer fx2.deinit();
        const arr = try arrayNums(testing.allocator, fx2.rt.readSlot(path).?);
        defer testing.allocator.free(arr);
        try expectSameFloat(c.want[0], arr[0], c.node);
        try expectSameFloat(c.want[1], arr[1], c.node);
    }
}

fn expectSameFloat(want: f64, got: f64, who: []const u8) !void {
    if (std.math.isNan(want)) {
        if (std.math.isNan(got)) return;
    } else if (want == got) return;
    std.debug.print("{s}: expected {d}, got {d}\n", .{ who, want, got });
    return error.TestUnexpectedResult;
}

test "beat 1b: a scalar program is bit-identical to what it was before broadcast" {
    // The regression that matters most: broadcast must be invisible to every
    // program that never uses it. Same arithmetic, same encoding, same bytes.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | add 1 | mul 2 | > 5 | write plane.o", .{.{ "plane.v", @as(f64, 3) }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 4), slotNum(&fx, "programs.p.add1.out.out").?);
    try testing.expectEqual(@as(f64, 8), slotNum(&fx, "programs.p.mul1.out.out").?);
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.gt1.out.out").?).?);
}

test "beat 1b: the math completions" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\pi as half_turn
        \\half_turn | write plane.pi
        \\tau | write plane.tau
        \\plane.v | mul half_turn | sin | write plane.s
        \\plane.v | atan2 0 | write plane.at
        \\plane.v | fract | write plane.fr
    , .{.{ "plane.v", @as(f64, 1) }});
    defer fx.deinit();
    try testing.expectEqual(std.math.pi, slotNum(&fx, "programs.p.pi1.out.out").?);
    try testing.expectEqual(std.math.tau, slotNum(&fx, "programs.p.tau1.out.out").?);
    try testing.expectApproxEqAbs(@as(f64, 0), slotNum(&fx, "programs.p.sin1.out.out").?, 1e-15);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, slotNum(&fx, "programs.p.atan21.out.out").?, 1e-15);
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.fract1.out.out").?);
}

test "beat 1b: `mod` and `fract` follow the divisor, which is what angles need" {
    // Truncated remainder gets these wrong on exactly the half of the circle
    // people forget to test.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.a | mod 360 | write plane.m
        \\plane.a | fract | write plane.f
    , .{.{ "plane.a", @as(f64, -90.25) }});
    defer fx.deinit();
    try testing.expectApproxEqAbs(@as(f64, 269.75), slotNum(&fx, "programs.p.mod1.out.out").?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.75), slotNum(&fx, "programs.p.fract1.out.out").?, 1e-12);
}

// ---------------------------------------------------------------------------
// Tier 2, beat 1a — time as a value, waveforms, registers, shaping.
//
// The beat closes on ONE line doing what took two programs, a seeded counter
// and seven lines of arithmetic. That gate is first. The two Chris named as
// conditions of the close — the stop gate and the restore-no-jump gate —
// follow it, because they are what keep "op-internal state is legal" (recon
// §0) from quietly becoming "the cycle ban, routed around via the wheel."
// ---------------------------------------------------------------------------

const sec = std.time.ns_per_s;

/// Drive a mounted program across `n` frames of `dt` nanoseconds, starting one
/// step in (mount already ran tick 0 at t=0). Both lanes advance, because a
/// host feeds both and a register that only works when one moves is a register
/// with a hidden dependency.
fn run(fx: *Fixture, dt: u64, n: usize) !void {
    // Cumulative from wherever the runtime already is: fed time is
    // non-decreasing by contract, so a helper that restarted at zero would
    // be a TimeRegression, not a shorter test.
    for (0..n) |_| {
        try fx.rt.tick(.{ .time_ns = fx.rt.now.time_ns + dt, .frame = fx.rt.now.frame + 1 });
    }
}

test "beat 1a: the breathing exposure is one line" {
    // The founding example (tier-2 draft §0). Before: two programs, because a
    // phase counter reads a path it writes and §4.4 refuses that; a seed,
    // because tick 0 evaluates everything; and a triangle, because with no
    // `sin` and no `wave` there was no sine to be had.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "lfo sine 4s | range 0.5 1.5 | write plane.render.grade.exposure", .{});
    defer fx.deinit();

    // One line, three nodes, one program, no seed: nothing is read from the
    // plane at all, so there is nothing to exist before mount.
    try testing.expectEqual(@as(usize, 3), fx.prog.nodeCount());

    const out = "programs.p.range1.out.out";
    // A sine that starts at its trough: phase 0 is 0, so the exposure opens
    // at `lo` and the first breath is an inhale.
    try testing.expectApproxEqAbs(@as(f64, 0.5), slotNum(&fx, out).?, 1e-9);

    // Quarter cycle in: halfway up.
    try run(&fx, sec, 1);
    try testing.expectApproxEqAbs(@as(f64, 1.0), slotNum(&fx, out).?, 1e-9);
    // Half cycle: the top.
    try run(&fx, sec, 1);
    try testing.expectApproxEqAbs(@as(f64, 1.5), slotNum(&fx, out).?, 1e-9);
    // Three quarters: back down through the middle.
    try run(&fx, sec, 1);
    try testing.expectApproxEqAbs(@as(f64, 1.0), slotNum(&fx, out).?, 1e-9);
    // Full cycle: home, and the plane saw every step of it.
    try run(&fx, sec, 1);
    try testing.expectApproxEqAbs(@as(f64, 0.5), slotNum(&fx, out).?, 1e-9);
    try testing.expectEqual(@as(f64, 0.5), types.asNumber(fx.mock.writes.items[fx.mock.writes.items.len - 1].value).?);

    // And it never leaves the interval it was asked for.
    for (fx.mock.writes.items) |w| {
        const v = types.asNumber(w.value).?;
        try testing.expect(v >= 0.5 and v <= 1.5);
    }
}

test "beat 1a: a register STOPS — the eval counter goes flat inside epsilon" {
    // The gate that makes the ε cutoff real. An `ease` that converged but kept
    // re-arming would be a node dirty every frame forever — legal under §4.4
    // and a corpse anyway. So: converge, then assert the counter does not move
    // across a hundred more frames.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.target | ease 100ms | write plane.out", .{.{ "plane.target", @as(f64, 1.0) }});
    defer fx.deinit();

    const node = nodeIdOf(&fx.prog, "ease1").?;
    // Baselined at the input on mount: no swing from zero, no transient.
    try testing.expectApproxEqAbs(@as(f64, 1.0), slotNum(&fx, "programs.p.ease1.out.out").?, 1e-12);

    try feedValue(&fx.rt, testing.allocator, "plane.target", @as(f64, 2.0));
    try run(&fx, 16 * ms, 120); // ~2s at 60fps: twenty time constants
    const settled = slotNum(&fx, "programs.p.ease1.out.out").?;
    try testing.expect(@abs(2.0 - settled) <= 1e-4 * 2.0);

    const before = fx.rt.eval_count[node];
    try run(&fx, 16 * ms, 100);
    try testing.expectEqual(before, fx.rt.eval_count[node]);

    // Stopped, not deaf: a new target wakes it and it converges again.
    try feedValue(&fx.rt, testing.allocator, "plane.target", @as(f64, 0.0));
    try run(&fx, 16 * ms, 120);
    try testing.expect(fx.rt.eval_count[node] > before);
    try testing.expect(@abs(slotNum(&fx, "programs.p.ease1.out.out").?) <= 1e-4);
}

test "beat 1a: every self-arming register stops, not just ease" {
    // The same property across the family, because "it stops" is the
    // campaign's load-bearing claim and one op proving it is one op.
    const Case = struct { src: []const u8, node: []const u8, seed: f64, then: f64 };
    const cases = [_]Case{
        .{ .src = "plane.v | ease 50ms | write plane.o", .node = "ease1", .seed = 0, .then = 1 },
        .{ .src = "plane.v | ramp 200ms | write plane.o", .node = "ramp1", .seed = 0, .then = 1 },
        // diff stops when the rate reaches zero: a value that stopped moving
        // has velocity zero, and reporting the last velocity forever is the
        // bug this op exists to avoid.
        .{ .src = "plane.v | diff | write plane.o", .node = "diff1", .seed = 0, .then = 5 },
        // integrate stops at its clamp — the bound is also the cutoff.
        .{ .src = "plane.v | integrate max 1 | write plane.o", .node = "integrate1", .seed = 0, .then = 100 },
    };
    inline for (cases) |c| {
        var fx: Fixture = undefined;
        try mountFixture(testing.allocator, &fx, c.src, .{.{ "plane.v", c.seed }});
        defer fx.deinit();
        const node = nodeIdOf(&fx.prog, c.node).?;
        try feedValue(&fx.rt, testing.allocator, "plane.v", c.then);
        try run(&fx, 16 * ms, 200);
        const before = fx.rt.eval_count[node];
        try run(&fx, 16 * ms, 100);
        if (before != fx.rt.eval_count[node]) {
            std.debug.print("'{s}' never stopped: {d} → {d} evals over 100 idle frames\n", .{ c.node, before, fx.rt.eval_count[node] });
            return error.TestUnexpectedResult;
        }
    }
}

test "beat 1a: restore mid-animation does not jump" {
    // The hazard the recon found by reading (§3h): `restore` rebuilds from a
    // dump WITHOUT ticking and takes `now` from MountOpts, so an epoch held on
    // the Runtime would be re-seeded and `clock` would report zero at t=90s.
    // The epoch lives in op state instead, and this is what says so.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\clock | write plane.ui.elapsed
        \\lfo sine 4s | range 0.5 1.5 | write plane.render.grade.exposure
    , .{});
    defer fx.deinit();

    try run(&fx, sec / 4, 10); // 2.5s in: mid-breath, past the peak
    const elapsed_before = slotNum(&fx, "programs.p.clock1.out.out").?;
    const wave_before = slotNum(&fx, "programs.p.range1.out.out").?;
    try testing.expectApproxEqAbs(@as(f64, 2.5), elapsed_before, 1e-9);

    const saved = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(saved);
    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, saved);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.restoreState(&rt2, saved);

    // Restored, the wires read exactly what they read when saved.
    try testing.expectApproxEqAbs(elapsed_before, types.asNumber(rt2.readSlot("programs.p.clock1.out.out").?).?, 1e-12);
    try testing.expectApproxEqAbs(wave_before, types.asNumber(rt2.readSlot("programs.p.range1.out.out").?).?, 1e-12);

    // And it CONTINUES rather than restarting: one more quarter-second on
    // both runtimes lands on the same value, still counting from the original
    // mount. A runtime-held epoch would read 0.25 here instead of 2.75.
    try rt2.tick(.{ .time_ns = sec * 11 / 4, .frame = 11 });
    try run(&fx, sec / 4, 1);
    try testing.expectApproxEqAbs(@as(f64, 2.75), types.asNumber(rt2.readSlot("programs.p.clock1.out.out").?).?, 1e-9);
    try testing.expectEqualSlices(u8, fx.rt.readSlot("programs.p.range1.out.out").?, rt2.readSlot("programs.p.range1.out.out").?);
}

test "beat 1a: an animation replays bit-identically" {
    // G2's shape, extended to a program that re-arms itself. Time is fed, so
    // two runs over the same fed sequence must agree byte for byte — the
    // wheel is the only subscription to time and it is in the dump.
    var a: Fixture = undefined;
    var b: Fixture = undefined;
    const src =
        \\lfo tri 1s | range 0 10 | write plane.a
        \\plane.v | ease 40ms | write plane.b
    ;
    try mountFixture(testing.allocator, &a, src, .{.{ "plane.v", @as(f64, 0) }});
    defer a.deinit();
    try mountFixture(testing.allocator, &b, src, .{.{ "plane.v", @as(f64, 0) }});
    defer b.deinit();

    for (1..60) |i| {
        if (i == 20) {
            try feedValue(&a.rt, testing.allocator, "plane.v", @as(f64, 3));
            try feedValue(&b.rt, testing.allocator, "plane.v", @as(f64, 3));
        }
        try a.rt.tick(.{ .time_ns = 16 * ms * i, .frame = @intCast(i) });
        try b.rt.tick(.{ .time_ns = 16 * ms * i, .frame = @intCast(i) });
        const da = try rill.dump(&a.rt, testing.allocator);
        defer testing.allocator.free(da);
        const db = try rill.dump(&b.rt, testing.allocator);
        defer testing.allocator.free(db);
        try testing.expectEqualSlices(u8, da, db);
    }
}

test "beat 1a: `lfo` and `clock | wave` are the same waveform, bit for bit" {
    // The pin that keeps `lfo` honest as sugar. It is its own op (a source
    // that owns its epoch is one node, not two) but it calls the SAME
    // `waveAt`, so the two spellings cannot drift. Bit-identical, not
    // approximately equal — an epsilon here would hide exactly the drift the
    // gate exists to catch.
    inline for (.{ "sine", "tri", "saw", "square" }) |shape| {
        var fx: Fixture = undefined;
        try mountFixture(testing.allocator, &fx, "lfo " ++ shape ++ " 3s | write plane.a\nclock | wave " ++ shape ++ " 3s | write plane.b", .{});
        defer fx.deinit();
        for (1..40) |i| {
            try fx.rt.tick(.{ .time_ns = 100 * ms * i, .frame = @intCast(i) });
            const x = fx.rt.readSlot("programs.p.lfo1.out.out").?;
            const y = fx.rt.readSlot("programs.p.wave1.out.out").?;
            try testing.expectEqualSlices(u8, x, y);
        }
    }
}

test "beat 1a: the waveforms are the waveforms" {
    // Pinned at the phases everyone can check by hand, on the frame lane so
    // the arithmetic is exact: a quarter of 4f is 1f.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\lfo sine 4f | write plane.sine
        \\lfo tri 4f | write plane.tri
        \\lfo saw 4f | write plane.saw
        \\lfo square 4f | write plane.square
    , .{});
    defer fx.deinit();
    const at = struct {
        fn v(f: *Fixture, n: []const u8) f64 {
            return slotNum(f, n).?;
        }
    };
    const s = "programs.p.lfo1.out.out";
    const t = "programs.p.lfo2.out.out";
    const w = "programs.p.lfo3.out.out";
    const q = "programs.p.lfo4.out.out";
    // phase 0
    try testing.expectApproxEqAbs(@as(f64, 0), at.v(&fx, s), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), at.v(&fx, t), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), at.v(&fx, w), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), at.v(&fx, q), 1e-12);
    try run(&fx, 16 * ms, 1); // phase 1/4
    try testing.expectApproxEqAbs(@as(f64, 0.5), at.v(&fx, s), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), at.v(&fx, t), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), at.v(&fx, w), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), at.v(&fx, q), 1e-12);
    try run(&fx, 16 * ms, 1); // phase 1/2 — every shape at its own half-way
    try testing.expectApproxEqAbs(@as(f64, 1), at.v(&fx, s), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), at.v(&fx, t), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), at.v(&fx, w), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), at.v(&fx, q), 1e-12);
    try run(&fx, 16 * ms, 2); // phase 1 == phase 0: modular, and exactly so
    try testing.expectApproxEqAbs(@as(f64, 0), at.v(&fx, s), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), at.v(&fx, w), 1e-12);
}

test "beat 1a: `ramp` lands its target exactly, and retargets from where it is" {
    // Chris's amendment to the ε pin: ε is `ease`'s rule. `ramp` has an END,
    // so its last frame emits the target EXACTLY — a fade that stopped one ε
    // short of full would be a visible band.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | ramp 100ms | write plane.o", .{.{ "plane.v", @as(f64, 0) }});
    defer fx.deinit();
    const out = "programs.p.ramp1.out.out";

    // The tween starts on the tick the new target ARRIVES (t=10ms here, not
    // t=0) and that tick emits where it already is.
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 1));
    try run(&fx, 10 * ms, 1);
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, out).?);
    try run(&fx, 10 * ms, 5); // t=60ms: half of the span
    try testing.expectApproxEqAbs(@as(f64, 0.5), slotNum(&fx, out).?, 1e-9);
    try run(&fx, 10 * ms, 5); // t=110ms: the end
    try testing.expectEqual(@as(f64, 1.0), slotNum(&fx, out).?); // exactly, not 1.0 ± ε

    // It stays there and stops: a landed ramp is not still tweening.
    const node = nodeIdOf(&fx.prog, "ramp1").?;
    const landed = fx.rt.eval_count[node];
    try run(&fx, 10 * ms, 20);
    try testing.expectEqual(landed, fx.rt.eval_count[node]);
    try testing.expectEqual(@as(f64, 1.0), slotNum(&fx, out).?);
}

test "beat 1a: `ramp` interrupted mid-tween resumes from where it is" {
    // The gate the first draft got wrong: it retargeted AFTER the tween had
    // finished, where "where it is" and "the old target" are the same number,
    // so it asserted nothing — a mutation swapping one for the other survived.
    // Interrupting mid-flight is the case that distinguishes them.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | ramp 100ms | write plane.o", .{.{ "plane.v", @as(f64, 0) }});
    defer fx.deinit();
    const out = "programs.p.ramp1.out.out";

    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 1));
    try run(&fx, 10 * ms, 6); // t=60ms: half-way up, still climbing
    try testing.expectApproxEqAbs(@as(f64, 0.5), slotNum(&fx, out).?, 1e-9);

    // Reverse it. The retarget tick has itself advanced 10ms, so the ramp is
    // at 0.6 when it turns around — and 0.6 is what it must emit. A ramp that
    // restarted from its OLD TARGET would jump to 1.0 here, which is the
    // visible flick this gate exists to forbid.
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 0));
    try run(&fx, 10 * ms, 1);
    try testing.expectApproxEqAbs(@as(f64, 0.6), slotNum(&fx, out).?, 1e-9);

    // From 0.6, half a span later, it is 0.6 - 0.3. (From 1.0 it would read
    // 0.5 — the mutation's answer, and a tenth of a unit of visible lie.)
    try run(&fx, 10 * ms, 5);
    try testing.expectApproxEqAbs(@as(f64, 0.3), slotNum(&fx, out).?, 1e-9);
    try run(&fx, 10 * ms, 5);
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, out).?);
}

test "beat 1a: `ease` stops inside epsilon and never snaps" {
    // The other half of the amendment: an exponential never arrives, so the
    // honest end is "close enough, and quiet". If it snapped, the last frame
    // of every fade would be a step.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | ease 20ms | write plane.o", .{.{ "plane.v", @as(f64, 0) }});
    defer fx.deinit();
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 1));
    try run(&fx, 8 * ms, 60);
    const settled = slotNum(&fx, "programs.p.ease1.out.out").?;
    try testing.expect(settled < 1.0); // never actually arrives…
    try testing.expect(1.0 - settled <= 1e-4); // …but stops indistinguishably close
}

test "beat 1a: `ease up down` is the envelope follower" {
    // `abs | ease 20ms down 400ms` — fast attack, slow release, which is three
    // CHOPs and Max's `slide` in two keyword ports. Asserting the ASYMMETRY is
    // the point: rise and fall over the same interval must not match.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | abs | ease 20ms down 400ms | write plane.o", .{.{ "plane.v", @as(f64, 0) }});
    defer fx.deinit();
    const out = "programs.p.ease1.out.out";

    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 1));
    try run(&fx, 16 * ms, 4); // 64ms of attack at tau=20ms: nearly there
    const attacked = slotNum(&fx, out).?;
    try testing.expect(attacked > 0.9);

    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 0));
    try run(&fx, 16 * ms, 4); // the same 64ms of release at tau=400ms
    const released = slotNum(&fx, out).?;
    try testing.expect(released > 0.8); // barely moved — that is the follower
}

test "beat 1a: `hold` ignores the storm, and does not tick" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | hold 100ms | write plane.o", .{.{ "plane.v", @as(f64, 1) }});
    defer fx.deinit();
    const out = "programs.p.hold1.out.out";
    const node = nodeIdOf(&fx.prog, "hold1").?;
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);

    // Inside the window every change is ignored — and gone.
    for (1..5) |i| {
        try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, @floatFromInt(i + 1)));
        try fx.rt.tick(.{ .time_ns = 20 * ms * i, .frame = @intCast(i) });
        try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
    }
    // Past it, the next arrival takes.
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 9));
    try run(&fx, 200 * ms, 1);
    try testing.expectEqual(@as(f64, 9), slotNum(&fx, out).?);

    // It never armed the wheel: idle frames cost it nothing.
    const before = fx.rt.eval_count[node];
    try run(&fx, 16 * ms, 50);
    try testing.expectEqual(before, fx.rt.eval_count[node]);
}

test "beat 1a: `diff` baselines silently, then reports the rate" {
    // The op the keep wanted: `nearest_distance | diff` is velocity, and the
    // probe reviewer invented a sensor field because nothing derived it.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.d | diff | write plane.o", .{.{ "plane.d", @as(f64, 100) }});
    defer fx.deinit();
    const out = "programs.p.diff1.out.out";

    // First observation: no rate exists yet, and dt is zero — the arithmetic
    // forces the silence the idiom already wanted.
    try testing.expect(fx.rt.readSlot(out) == null);

    // 10 metres closer over half a second: -20 m/s.
    try feedValue(&fx.rt, testing.allocator, "plane.d", @as(f64, 90));
    try run(&fx, sec / 2, 1);
    try testing.expectApproxEqAbs(@as(f64, -20), slotNum(&fx, out).?, 1e-9);

    // Stopped: the rate goes to zero rather than holding the last velocity.
    try run(&fx, sec / 2, 2);
    try testing.expectApproxEqAbs(@as(f64, 0), slotNum(&fx, out).?, 1e-9);
}

test "beat 1a: `integrate` needs its clamp, and honours it" {
    // The clamp is REQUIRED, not optional: op state rides in every dump, so an
    // unbounded accumulator is a corpse that gets copied.
    try expectParseError("plane.v | integrate | write plane.o", "max");

    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | integrate max 2 | write plane.o", .{.{ "plane.v", @as(f64, 1) }});
    defer fx.deinit();
    const out = "programs.p.integrate1.out.out";
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, out).?);

    try run(&fx, sec, 1); // one unit per second, one second
    try testing.expectApproxEqAbs(@as(f64, 1), slotNum(&fx, out).?, 1e-9);
    try run(&fx, sec, 5); // and then it pins at the bound rather than running away
    try testing.expectEqual(@as(f64, 2), slotNum(&fx, out).?);

    // The bound is symmetric: a negative rate drains it and pins at -2.
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, -1));
    try run(&fx, sec, 10);
    try testing.expectEqual(@as(f64, -2), slotNum(&fx, out).?);
}

test "integrate does not bill its sleep: one press is one tick, not eighty seconds" {
    // Chris's rail camera, 2026-08-29 — the first bug the flight recorder
    // caught. The camera parked on the spline for eighty seconds (the W
    // branch quiet, so the integrate node slept with its clock frozen), then
    // one press of W made `rate * dt` integrate the new rate across the
    // whole silence: t slammed from 0.5 to the pin in a single frame (one
    // CSV row), the target teleported half a track, and the spring cut a
    // chord through the middle of the loop — "aimed toward the COG", exactly
    // as reported.
    //
    // The ruling: a register's billable window FLOORS at the wheel's
    // previous tick. Sleep is not process time; what arrives on a tick is
    // treated as having stood through that one tick and no further.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | integrate max 0.5 | write plane.o", .{.{ "plane.v", @as(f64, 0) }});
    defer fx.deinit();
    const out = "programs.p.integrate1.out.out";

    try run(&fx, sec, 80); // parked: the branch is silent for eighty seconds
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, out).?);

    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 1)); // the W press
    try run(&fx, 16 * ms, 2); // the delta's own eval, then one armed tick
    const after_press = slotNum(&fx, out).?;
    // The old code pinned this at 0.5 in one tick. One frame of rate 1 is
    // 0.016 — assert BOTH sides, because "it moved a little" and "it did not
    // slam" are different claims and the second is the bug.
    try testing.expect(after_press > 0.001);
    try testing.expect(after_press < 0.1);

    // And the totals still arrive: a full second of held input is one unit's
    // worth (clamped here), through the same ticks as ever.
    try run(&fx, 16 * ms, 60);
    try testing.expectEqual(@as(f64, 0.5), slotNum(&fx, out).?);
}

test "ease glides out of a long sleep instead of snapping" {
    // Integrate's ruling, caught by inspection while fixing it: a converged
    // ease stops arming ticks and sleeps, and a retarget after a quiet
    // minute computed k = 1 - exp(-60s/tau) ≈ 1 — the glide it exists to
    // provide, skipped exactly when someone was looking at it. With the
    // billable window floored at the previous tick, the retarget bills one
    // tick's worth and the fade takes its stated time from the wake.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.v | ease 2s | write plane.o", .{.{ "plane.v", @as(f64, 0) }});
    defer fx.deinit();
    const out = "programs.p.ease1.out.out";

    try run(&fx, sec, 60); // converged at 0, asleep
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 10));
    try run(&fx, 16 * ms, 1);
    const woke = slotNum(&fx, out).?;
    // Old: ≈ 10 (the snap). New: one frame into a 2s glide — barely moving.
    try testing.expect(woke < 1.0);

    // The glide still completes; nothing was lost, only deferred to where a
    // fade belongs.
    try run(&fx, sec, 20);
    try testing.expectApproxEqAbs(@as(f64, 10), slotNum(&fx, out).?, 0.01);
}

test "beat 1a: `range` clamps where `lerp` extrapolates" {
    // The one difference between them, and the reason `range` is a word:
    // `lerp` blends two things, `range` is the EXIT from the unit interval
    // and stays inside the interval it was given. Same ruling as `along`.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.t | range 0.5 1.5 | write plane.ranged
        \\plane.t | lerp 0.5 1.5 | write plane.lerped
    , .{.{ "plane.t", @as(f64, 2.0) }});
    defer fx.deinit();
    // The inequality FIRST (the ledger rule from beat 1a's retarget survivor:
    // a gate asserting "A rather than B" must run where A differs from B, and
    // must assert that difference before anything else — otherwise it passes
    // for both and asserts nothing).
    const ranged = slotNum(&fx, "programs.p.range1.out.out").?;
    const lerped = slotNum(&fx, "programs.p.lerp1.out.out").?;
    try testing.expect(ranged != lerped);
    try testing.expectEqual(@as(f64, 1.5), ranged);
    try testing.expectEqual(@as(f64, 2.5), lerped);

    try feedValue(&fx.rt, testing.allocator, "plane.t", @as(f64, -1.0));
    try run(&fx, 16 * ms, 1);
    const r_lo = slotNum(&fx, "programs.p.range1.out.out").?;
    const l_lo = slotNum(&fx, "programs.p.lerp1.out.out").?;
    try testing.expect(r_lo != l_lo);
    try testing.expectEqual(@as(f64, 0.5), r_lo);
    try testing.expectEqual(@as(f64, -0.5), l_lo);
}

test "beat 1a: `shape` eases the unit interval" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.t | shape smooth | write plane.a
        \\plane.t | shape in | write plane.b
        \\plane.t | shape out | write plane.c
        \\plane.t | shape linear | write plane.d
    , .{.{ "plane.t", @as(f64, 0.5) }});
    defer fx.deinit();
    // Every curve passes through the midpoint of the ends it was given…
    try testing.expectApproxEqAbs(@as(f64, 0.5), slotNum(&fx, "programs.p.shape1.out.out").?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), slotNum(&fx, "programs.p.shape2.out.out").?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.75), slotNum(&fx, "programs.p.shape3.out.out").?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), slotNum(&fx, "programs.p.shape4.out.out").?, 1e-12);
    // …and every one of them clamps, unit in, unit out.
    try feedValue(&fx.rt, testing.allocator, "plane.t", @as(f64, 4.0));
    try run(&fx, 16 * ms, 1);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, "programs.p.shape1.out.out").?);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, "programs.p.shape2.out.out").?);
}

test "beat 1a: an unknown shape is refused at parse, naming the list" {
    // `one_of` on a string port, checked at wire time — so a typo is caught
    // when the program is written, not three seconds into the animation.
    try expectParseError("lfo sqare 4s | write plane.o", "sine");
    try expectParseError("plane.t | shape bouncy | write plane.o", "smooth");
}

test "beat 1a: `clock` and `frame` count from mount, not from zero" {
    // Program-relative, so two cells mounted a second apart do not share a
    // phase and a replay lands on the same numbers.
    var fx: Fixture = undefined;
    fx.reg = try hostRegistry(testing.allocator);
    defer fx.reg.deinit();
    fx.mock = rill.MockPlane.init(testing.allocator);
    defer fx.mock.deinit();
    var diag = rill.Diag{};
    fx.prog = try rill.parse(testing.allocator, &fx.reg, "p", "clock | write plane.secs\nframe | write plane.frames", &diag);
    defer fx.prog.deinit();
    // Mounted mid-session, at t=90s / frame 5400 — the one-shot console
    // dispatch does this on every line.
    fx.rt = try rill.Runtime.mount(testing.allocator, &fx.prog, fx.mock.asPlane(), .{
        .now = .{ .time_ns = 90 * sec, .frame = 5400 },
    });
    defer fx.rt.deinit();
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.clock1.out.out").?);
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.frame1.out.out").?);

    try fx.rt.tick(.{ .time_ns = 92 * sec, .frame = 5460 });
    try testing.expectApproxEqAbs(@as(f64, 2), slotNum(&fx, "programs.p.clock1.out.out").?, 1e-9);
    try testing.expectEqual(@as(f64, 60), slotNum(&fx, "programs.p.frame1.out.out").?);
}

test "beat 1a: an op-internal register is not a cycle, and the plane one still is" {
    // §0's confirmation, executed rather than asserted. The register chases a
    // target inside the operator and mounts cleanly; the same idea routed
    // through the plane is refused, as it was before this beat.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.target | ease 100ms | write plane.smoothed", .{.{ "plane.target", @as(f64, 1) }});
    defer fx.deinit();
    try testing.expect(fx.prog.findCycle() == null);

    // …and the same idea routed through the plane is still refused, at PARSE,
    // naming both the write and the subscription. A register does not buy a
    // way around §4.4; it makes going around it unnecessary.
    try expectParseError("plane.smoothed | ease 100ms | write plane.smoothed", "cycle");
    try expectParseError("plane.smoothed | ease 100ms | write plane.smoothed", "plane.smoothed");
}

// ---------------------------------------------------------------------------
// The idioms book (tier-2 recon §3a, 2026-08-25). The campaign's definition of
// done says every new operator lands a before/after pair in the book with the
// after cell gated by parse — and the book had neither a document nor a gate,
// which made the clause unmeetable and the §4 simple-things list prose again.
//
// Same shape as the manual gate above, and for the same reason: the book is
// the evidence that an ask got cheaper, and evidence that never runs is a
// paragraph. Markdown cells are commentary and are not parsed; every other
// cell is a rill program and must compile. Counted BOTH ways, so a book that
// stopped being collected — a renamed field, a JSON shape drift — fails
// loudly instead of passing vacuously.
// ---------------------------------------------------------------------------

const BookCell = struct {
    name: []const u8,
    source: []const u8 = "",
    markdown: bool = false,
};

const BookDoc = struct {
    rillbook: u32,
    cells: []const BookCell,
};

/// Parse every non-markdown cell. Returns {rill cells parsed, total cells}.
fn parseBook(gpa: std.mem.Allocator, doc_src: []const u8, reg: *rill.Registry, doc_name: []const u8) !struct { usize, usize } {
    const parsed = std.json.parseFromSlice(BookDoc, gpa, doc_src, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("{s}: not valid JSON — {s}\n", .{ doc_name, @errorName(err) });
        return err;
    };
    defer parsed.deinit();
    const doc = parsed.value;
    // 1 and 2 are both readable — the shape did not change. What version 2
    // adds is a GUARANTEE about the writer: it preserves keys it does not
    // recognise. A v1 document may have been through the serialiser that
    // dropped them and cannot be trusted to still hold what was put in it.
    if (doc.rillbook != 1 and doc.rillbook != 2) {
        std.debug.print("{s}: format version {d}, expected 1 or 2\n", .{ doc_name, doc.rillbook });
        return error.TestUnexpectedResult;
    }

    var count: usize = 0;
    for (doc.cells) |cell| {
        if (cell.markdown) continue;
        if (cell.source.len == 0) {
            std.debug.print("{s}: cell '{s}' is a rill cell with no source\n", .{ doc_name, cell.name });
            return error.TestUnexpectedResult;
        }
        var diag = rill.Diag{};
        var prog = rill.parse(gpa, reg, cell.name, cell.source, &diag) catch |err| {
            if (err == error.Parse) {
                std.debug.print("{s}: cell '{s}' failed to parse — {s} (line {d}, col {d}):\n{s}\n", .{ doc_name, cell.name, diag.msg(), diag.line, diag.col, cell.source });
            }
            return err;
        };
        prog.deinit();
        count += 1;
    }
    return .{ count, doc.cells.len };
}

test "the idioms book parses: every cell compiles, and the count is deliberate" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const rill_cells, const total = try parseBook(testing.allocator, @embedFile("idioms.rillbook"), &reg, "idioms.rillbook");

    // THIS book is version 2 on purpose, and the version is a claim rather
    // than a number: format 2 says the writer preserves fields it does not
    // recognise. That guarantee is what lets a cell carry a fed-time script
    // beside its program without the next browser save deleting it, and it is
    // gated on the other side of the seam — `rbdoc.test.mjs` in matryoshka,
    // on that repo's `zig build test`. Pinned here so this book cannot be
    // written back down to a version whose writer is allowed to lose things.
    const parsed = try std.json.parseFromSlice(BookDoc, testing.allocator, @embedFile("idioms.rillbook"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 2), parsed.value.rillbook);
    // Both numbers move on purpose. `rill_cells` rises as a beat turns a
    // markdown "after" into a program; `total` rises as asks are added.
    // Opening count (recon, before beat 1a): 12 before-cells, 37 cells.
    // 12 → 21, 37 → 53 (beat 1a): nine after-cells — the founding example,
    // the VU meter, the eased target, closing-fast, the swing, the two rows
    // beat 1a both added and cleared, the partial fade, and the ticking
    // demonstration — plus the pages that record what the family costs.
    // 21 → 25, 53 → 60 (beat 1b): the follow row's after-cell, the two
    // idioms broadcast replaced (window|mul is map; a comparator over an
    // array is beat 3's predicate), and the range-or-lerp page.
    // 25 → 28, 60 → 66 (beat 2a): the time-of-day row's after-cell, the
    // three-points row's PARTIAL cell (the literal lands, `along` does not),
    // `nth` over a window, and the arrays page.
    // 28 → 30, 66 → 70 (beat 2b): the two contract rows' after-cells — one
    // `match`, one `expect`, because the two promises are the point — and the
    // shapes page.
    // 30 → 33, 70 → 75 (beat 3a): the three rows §2.11 argued and §4 never
    // listed — written down first, then landed — plus the bodies page.
    // 33 → 36, 75 → 81 (beat 3b): the nearest-hostile after-cell (two lines,
    // and the note says why), top-three, and the three-points row finished.
    // 36 → 45, 81 → 92 (beat 4): after-cells for the flash, the toggle, the
    // kill count, night-falls, the torch, the drift, the idle pick, the
    // camera shake (four lines, and the note says why), the mount fade-in —
    // and the levels page.
    // 92 → 93 (tier-2 close): the closing page. The rill-cell count does not
    // move — the close ratified two spellings and rewrote the cells that used
    // them, rather than adding programs.
    // 93 → 94 (envelopes, `below`): the note on the flagship's third and last
    // spelling. `below`'s customer IS that row, so it re-spells a program
    // rather than adding one — the rill-cell count stays at 45.
    // 45 → 47, 94 → 99 (envelopes, `first`-on-empty): the two-line pair that
    // IS the ruling — the pick that goes quiet and the count that speaks —
    // and `last`'s own customer, the newest entry of a rolling window. Both
    // asks have no BEFORE cell to mount, and for the same reason in each
    // case: the before was a refusal and an operator that did not exist.
    // 47 → 51, 99 → 106 (envelopes, `kick`): flash-on-hit gets a real BEFORE —
    // the invented-gate-path, magic-number version the re-probe actually
    // wrote — and it is TWO cells because it has to be two programs, which is
    // the shape of the workaround rather than a quirk of transcribing it.
    // Plus shake-on-impact, the after that shows why the word is not `flash`.
    // 51 → 53, 106 → 110 (envelopes, `adsr`): the held note, with a real
    // before — one register chasing one target, which cannot say "decay to a
    // sustain and stay there" however many words you spend on it.
    // 53 → 57, 110 → 117 (envelopes, `step`): the arpeggio, whose BEFORE is
    // again two programs — a counter through the plane, which is also a corpse
    // that rides every dump — and the camera cycle, which is the row that
    // argues for the modes composing.
    // 57 → 60, 117 → 125 (the spatial words): where-am-I-on-the-route and its
    // wrong-way warning, which is the row that argues for `nearest` handing
    // back the PARAMETER — a position could not be `diff`ed into a direction —
    // and the cone of vision, which is what one `dot` buys over six nodes.
    try testing.expectEqual(@as(usize, 60), rill_cells);
    try testing.expectEqual(@as(usize, 125), total);
}

// ---------------------------------------------------------------------------
// tail_all (2026-08-25): the rest of the INPUT, verbatim — found by
// rillbook's first drive. The line-tail stopped at the first newline, so a
// multi-line `rill remount` source lost every line past its first (they
// parsed as stray statements of the WRAPPER), and a source whose first line
// was a comment left the tail empty. The engine's own remount tests never
// saw it: they enqueue the source directly, bypassing the console parse —
// the wire-format lesson, again.
// ---------------------------------------------------------------------------

fn tailAllRegistry(gpa: std.mem.Allocator) !rill.Registry {
    var reg = try rill.Registry.init(gpa);
    errdefer reg.deinit();
    try rill.registerCore(&reg);
    const host = struct {
        var ports = [_]registry.Port{
            .{ .name = "name", .ty = types.Tag.string },
            .{ .name = "source", .ty = types.Tag.string, .tail = true, .tail_all = true },
        };
        var outs = [_]registry.Port{.{ .name = "out", .ty = types.Tag.string }};
    };
    _ = try reg.register(.{ .name = "remount", .inputs = &host.ports, .outputs = &host.outs, .help = "stub", .routes = .anywhere, .eval = echoTailEval });
    return reg;
}

test "tail_all: the whole rest of the input, comments and newlines and pipes included" {
    var reg = try tailAllRegistry(testing.allocator);
    defer reg.deinit();
    // The screenshot, as a gate: a comment-led multi-line source after the
    // fixed prefix. The tail carries all of it, verbatim.
    const src =
        \\remount cell-1 // a cell is one rill program
        \\// a second comment line
        \\plane.render.grade.exposure | mul 2
    ;
    var prog = try parseOk(testing.allocator, &reg, src);
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "remount1").?);
    const captured = types.asString(prog.slot(n.inputs[1]).source.literal).?;
    try testing.expect(std.mem.startsWith(u8, captured, "// a cell is one rill program"));
    try testing.expect(std.mem.indexOf(u8, captured, "\n// a second comment line\n") != null);
    try testing.expect(std.mem.endsWith(u8, captured, "plane.render.grade.exposure | mul 2"));
    // ONE node: nothing after the prefix leaked into the wrapper program.
    try testing.expectEqual(@as(usize, 1), prog.nodes.items.len);
}

test "tail_all: a quoted fixed-prefix arg keeps its quotes out of the capture" {
    var reg = try tailAllRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "remount \"keep defence\" plane.a | mul 2");
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "remount1").?);
    try testing.expectEqualStrings("keep defence", types.asString(prog.slot(n.inputs[0]).source.literal).?);
    try testing.expectEqualStrings("plane.a | mul 2", types.asString(prog.slot(n.inputs[1]).source.literal).?);
}

test "tail_all: registration keeps the closed shape — tail_all implies tail, last input only" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    const nop = struct {
        fn f(_: *rill.EvalCtx) registry.EvalError!registry.Emit {
            return registry.Emit.none;
        }
    }.f;
    const no_tail = [_]registry.Port{.{ .name = "s", .ty = types.Tag.string, .tail_all = true }};
    try testing.expectError(error.BadTailPort, reg.register(.{ .name = "a", .inputs = &no_tail, .help = "", .routes = .anywhere, .eval = nop }));
    const not_last = [_]registry.Port{ .{ .name = "s", .ty = types.Tag.string, .tail = true, .tail_all = true }, .{ .name = "b", .ty = types.Tag.number } };
    try testing.expectError(error.BadTailPort, reg.register(.{ .name = "b", .inputs = &not_last, .help = "", .routes = .anywhere, .eval = nop }));
}

test "diagnostics: a path after a pipe names the forgotten `set`" {
    // The most-forgotten spelling in live use (twice in one morning): the
    // intent is a write, the spelling is `set`, and the error says so.
    try expectParseError("plane.render.grade.exposure | plane.render.grade.highlights", "did you forget `set`?");
    try expectParseError(
        \\using plane.render.grade as :g
        \\plane.hp | :g.exposure
    , "did you forget `set`?");
}

test "paths: integer segments are legitimate — id-keyed rows parse" {
    // The @ registry's mirrors are id-keyed (`plane.ents.1.pos`), and the
    // tokenizer's trailing-dot rule already splits `1.pos` correctly.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.ents.1.pos | write plane.debug.tom");
    defer prog.deinit();
    try testing.expectEqualStrings("plane.ents.1.pos", prog.subs.items[0].path);
}

// ---------------------------------------------------------------------------
// tag / untag — the membership sinks (ironwood R6 T3)
// ---------------------------------------------------------------------------

test "tag: the stamped grammar parses, and the member write enters the write list" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.sighting | rose_above 0 | tag @tom #garrison");
    defer prog.deinit();
    const n = prog.node(nodeIdOf(&prog, "tag1").?);
    try testing.expectEqualStrings("@tom", n.statics[0].subject);
    try testing.expectEqualStrings("#garrison", n.statics[1].condition);
    // The composed member key wears the `@` — the cycle pin's spelling.
    var found = false;
    for (prog.writes.items) |w| {
        if (std.mem.eql(u8, w.path, "plane.tags.garrison.@tom")) found = true;
    }
    try testing.expect(found);
}

test "tag: piped, the rousing drives — and each occurrence is its own write" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.horn | tag @tom #garrison", .{});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), fx.mock.tag_writes.items.len); // no horn yet
    var pk = struple.Packer.init(testing.allocator);
    defer pk.deinit();
    try pk.appendBool(true);
    try fx.rt.feed(.{ .path = "plane.horn", .value = pk.bytes(), .kind = .occurrence });
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(usize, 1), fx.mock.tag_writes.items.len);
    const t0 = fx.mock.tag_writes.items[0];
    try testing.expectEqualStrings("@tom", t0.subject);
    try testing.expectEqualStrings("#garrison", t0.tag);
    try testing.expect(t0.adding);
    // Idempotence lives HOST-side: rill says each write; twice-is-once is
    // the row's physics. Two rousings are two dispatches.
    try fx.rt.feed(.{ .path = "plane.horn", .value = pk.bytes(), .kind = .occurrence });
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(usize, 2), fx.mock.tag_writes.items.len);
}

test "untag: same shape, leave direction" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.stood_down | untag @tom #garrison", .{});
    defer fx.deinit();
    var pk = struple.Packer.init(testing.allocator);
    defer pk.deinit();
    try pk.appendBool(true);
    try fx.rt.feed(.{ .path = "plane.stood_down", .value = pk.bytes(), .kind = .occurrence });
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(usize, 1), fx.mock.tag_writes.items.len);
    try testing.expect(!fx.mock.tag_writes.items[0].adding);
}

test "tag: unpiped, it fires ONCE at tick 0 — the console one-shot's shape" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "tag @wall #garrison", .{});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 1), fx.mock.tag_writes.items.len);
    try testing.expect(fx.mock.tag_writes.items[0].adding);
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(usize, 1), fx.mock.tag_writes.items.len);
}

test "tag: a set-subscription on the tag is a cycle; the service leaves are siblings" {
    // The cycle pin (ironwood R6, pre-T1): member keys wear `@`, service
    // leaves are bare words — disjoint by construction. So subscribing the
    // tag row you write is refused through the ordinary prefix rule, and
    // subscribing `joined`/`count` is not special-cased into legality: it
    // simply never overlaps.
    try expectParseError(
        \\plane.tags.garrison | write plane.hud.n
        \\plane.x | tag @tom #garrison
    , "cycle");
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.tags.garrison.joined | write plane.hud.last_join
        \\plane.tags.garrison.count | write plane.hud.n
        \\plane.x | tag @tom #garrison
    );
    defer prog.deinit();
}

test "tag: what refuses to parse, refuses loudly" {
    // One tag per call (fork B): a second `#` has nowhere honest to bind.
    try expectParseError("plane.x | tag @tom #a #b", "ONE per call");
    // Each half wears its sigil.
    try expectParseError("plane.x | tag tom #garrison", "'@'-sigil");
    try expectParseError("plane.x | tag @tom garrison", "'#'-sigil");
    try expectParseError("plane.x | tag @tom", "needs a condition argument");
    // A bare condition is not an expression — the read spelling is named.
    try expectParseError("#garrison | write plane.x", "plane.tags.garrison.count");
    // The sigil guards hold for `#` as they do for `$` and `@`.
    try expectParseError("plane.x | mul 2 as #x", "cannot wear");
    try expectParseError("using plane.a as :#s", "cannot wear");
    try expectParseError("def #d(x) = x | mul 2", "cannot wear");
}

test "tag: a def body's membership write still reaches the cycle check" {
    // Templates ban `path` statics, but a subject/condition pair is legal in
    // a def — its composed member write must register at INSTANTIATE, or the
    // def is a hole in §4.4. (The sink rides an `also` branch: a def must
    // produce an output, so it cannot END in a sink.) Mutation that bites:
    // drop registerWrites from instantiate and this parses.
    try expectParseError(
        \\def enlist(x) = x | also { tag @tom #garrison }
        \\plane.tags.garrison | enlist | write plane.y
    , "cycle");
}

test "tag: dump/load round-trips the pair, and the restored write list agrees" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.horn | tag @tom #garrison", .{});
    defer fx.deinit();
    const bytes = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(bytes);
    var reg2 = try hostRegistry(testing.allocator);
    defer reg2.deinit();
    var prog2 = try rill.loadProgram(testing.allocator, &reg2, bytes);
    defer prog2.deinit();
    const n = prog2.node(nodeIdOf(&prog2, "tag1").?);
    try testing.expectEqualStrings("@tom", n.statics[0].subject);
    try testing.expectEqualStrings("#garrison", n.statics[1].condition);
    var found = false;
    for (prog2.writes.items) |w| {
        if (std.mem.eql(u8, w.path, "plane.tags.garrison.@tom")) found = true;
    }
    try testing.expect(found);
}

test "tag: a host with no tag row fails the node, counted — never a silent drop" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var prog = try parseOk(testing.allocator, &reg, "tag @tom #garrison");
    defer prog.deinit();
    var pl = mock.asPlane();
    pl.tagFn = null;
    var rt = try rill.Runtime.mount(testing.allocator, &prog, pl, .{});
    defer rt.deinit();
    try testing.expectEqual(@as(usize, 0), mock.tag_writes.items.len);
    try testing.expectEqual(@as(u64, 1), rt.error_count[nodeIdOf(&prog, "tag1").?]);
}

// ---------------------------------------------------------------------------
// T4 — cast coupling (`to #tag`) and the cast list
// ---------------------------------------------------------------------------

test "cast: `to #tag` rides the deposit; unbound it is empty — the uncoupled cast" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\cast $dread 0.6 radius 9 at plane.p to #garrison
        \\cast $torch 0.8 radius 12 at plane.p
    , .{
        .{ "plane.p", @as(i64, 1) },
    });
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 2), fx.mock.casts.items.len);
    try testing.expectEqualStrings("#garrison", fx.mock.casts.items[0].to);
    try testing.expectEqualStrings("", fx.mock.casts.items[1].to);
}

test "cast: the program's cast list names every channel — the grant policy's other half" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.x | cast $alarm 1 radius 5 at plane.p
        \\plane.y | cast $dread 1 radius 5 at plane.p to #hostile
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 2), prog.casts.items.len);
    try testing.expectEqualStrings("$alarm", prog.casts.items[0].channel);
    try testing.expectEqualStrings("$dread", prog.casts.items[1].channel);
    // …and none of them leaked into the WRITE list: a field has no read
    // side, so the cycle check must stay blind to casts.
    try testing.expectEqual(@as(usize, 0), prog.writes.items.len);
}

test "cast: the cast list survives dump/load — restore composes it the same way" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.x | cast $alarm 1 radius 5 at plane.p to #hostile", .{});
    defer fx.deinit();
    const bytes = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(bytes);
    var reg2 = try hostRegistry(testing.allocator);
    defer reg2.deinit();
    var prog2 = try rill.loadProgram(testing.allocator, &reg2, bytes);
    defer prog2.deinit();
    try testing.expectEqual(@as(usize, 1), prog2.casts.items.len);
    try testing.expectEqualStrings("$alarm", prog2.casts.items[0].channel);
    const n = prog2.node(nodeIdOf(&prog2, "cast1").?);
    try testing.expectEqualStrings("#hostile", n.statics[2].condition);
}

test "cast: `to` refuses a sigil-less word, and an optional static must be kw" {
    try expectParseError("plane.x | cast $f 1 radius 2 at plane.p to garrison", "'#'-sigil");
    // The registry refuses a positional optional static at registration —
    // a maybe-there positional would shift every static after it.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    const noopEval = struct {
        fn f(_: *rill.registry.EvalCtx) rill.registry.EvalError!rill.registry.Emit {
            return rill.registry.Emit.none;
        }
    }.f;
    try testing.expectError(error.BadStatic, reg.register(.{
        .name = "badopt",
        .statics = &.{.{ .name = "maybe", .kind = .word, .optional = true }},
        .help = "",
        .routes = .anywhere,
        .eval = noopEval,
    }));
}

test "lerp: the piped value is t — `s | lerp 0.5 1.5` reads as the sentence says" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.s | lerp 0.5 1.5 | write plane.out", .{
        .{ "plane.s", @as(f64, 0.25) },
    });
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 0.75), types.asNumber(fx.mock.store.get("plane.out").?).?);
}

test "and/or/not: the conjunction idiom's missing words" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.dark | and plane.calm | write plane.both
        \\plane.dark | or plane.calm | write plane.either
        \\plane.dark | not | write plane.lit
    , .{
        .{ "plane.dark", true },
        .{ "plane.calm", false },
    });
    defer fx.deinit();
    try testing.expectEqual(false, types.asBool(fx.mock.store.get("plane.both").?).?);
    try testing.expectEqual(true, types.asBool(fx.mock.store.get("plane.either").?).?);
    try testing.expectEqual(false, types.asBool(fx.mock.store.get("plane.lit").?).?);
}

test "^: the archetype sigil lexes one token, guarded — engine-owned, never an expression" {
    try expectParseError("^raider | write plane.x", "engine-owned");
    try expectParseError("plane.x | mul 2 as ^x", "cannot wear");
    try expectParseError("def ^d(x) = x | mul 2", "cannot wear");
}

test "MockPlane.putValue: containers encode as containers, strings stay strings" {
    // The trap this closes: a string is a pointer, so the container branch
    // would have iterated it into a sequence of byte-ints. Nothing in the
    // suite seeded a string through putValue when the branch was added, so
    // nothing would have caught it until something did.
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.s", "hello");
    try mock.putValue("plane.r", .{ .x = @as(f64, 1), .y = @as(f64, 2) });
    try mock.putValue("plane.a", [_]f64{ 1, 2, 3 });
    try mock.putValue("plane.n", @as(f64, 7));

    var buf = struple.Packer.init(testing.allocator);
    defer buf.deinit();
    const read = struct {
        fn go(m: *rill.MockPlane, b: *struple.Packer, path: []const u8) ![]const u8 {
            b.reset();
            try m.asPlane().read(path, b);
            return b.bytes();
        }
    }.go;
    try testing.expectEqualStrings("hello", types.asString(try read(&mock, &buf, "plane.s")).?);
    const rec = try read(&mock, &buf, "plane.r");
    try testing.expectEqual(types.Tag.record, types.typeOfValue(rec));
    // …and it is ITERABLE, which a record whose keys were written as raw
    // bytes rather than encoded string elements is not. The first draft of
    // this helper wrote raw keys and every container gate reported a
    // malformed record; the type tag alone would not have caught it.
    const fields = try recordFields(testing.allocator, rec);
    defer freeFields(testing.allocator, fields);
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("x", fieldName(fields[0]));
    try testing.expectEqual(@as(f64, 1), fields[0].v);
    try testing.expectEqual(types.Tag.array, types.typeOfValue(try read(&mock, &buf, "plane.a")));
    try testing.expectEqual(types.Tag.number, types.typeOfValue(try read(&mock, &buf, "plane.n")));
}

// ---------------------------------------------------------------------------
// Beat 2a — arrays: the literal, `nth`, `choose`.
//
// The literal is the missing half of a value kind rill already had — `window`
// emits an array and `stats` consumes one — so these gates check the two
// halves meet: what the literal builds is what the array readers read.
// ---------------------------------------------------------------------------

test "beat 2a: the array literal is a value, in order" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[0.2, 1, 0.6, 0.05] | write plane.out
    , .{});
    defer fx.deinit();

    const out = fx.rt.readSlot("programs.p.array1.out.out") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(types.Tag.array, types.typeOfValue(out));
    const nums = try arrayNums(testing.allocator, out);
    defer testing.allocator.free(nums);
    // Order IS the meaning: a record sorts its keys canonically, an array
    // must not sort anything. 0.05 sorting to the front would still pass a
    // "four numbers" check and would still be wrong.
    try testing.expectEqualSlices(f64, &.{ 0.2, 1, 0.6, 0.05 }, nums);
}

test "beat 2a: an array holding a path is LIVE, like a record" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[plane.a, plane.b] | nth 1 | write plane.out
    , .{ .{ "plane.a", @as(f64, 1) }, .{ "plane.b", @as(f64, 2) } });
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 2), slotNum(&fx, "programs.p.nth1.out.out").?);
    try feedValue(&fx.rt, testing.allocator, "plane.b", @as(f64, 7));
    try fx.rt.tick(.{});
    // An array is a bundle of wires, not a snapshot: the element changed, so
    // the array changed, so what reads it changed.
    try testing.expectEqual(@as(f64, 7), slotNum(&fx, "programs.p.nth1.out.out").?);
}

test "beat 2a: `choose` — pick an exposure by time-of-day band, one line" {
    // §4's "pick an exposure by time-of-day band", which was a `select` chain.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.time.band | choose [0.2, 1, 0.6, 0.05] | write plane.render.grade.exposure
    , .{.{ "plane.time.band", @as(f64, 0) }});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 0.2), slotNum(&fx, "programs.p.choose1.out.out").?);
    for ([_][2]f64{ .{ 1, 1 }, .{ 2, 0.6 }, .{ 3, 0.05 }, .{ 0, 0.2 } }) |c| {
        try feedValue(&fx.rt, testing.allocator, "plane.time.band", c[0]);
        try fx.rt.tick(.{});
        try testing.expectEqual(c[1], slotNum(&fx, "programs.p.choose1.out.out").?);
    }
}

test "beat 2a: `nth` and `choose` are one computation with the hot port swapped" {
    // The `lfo` ≡ `clock | wave` precedent: two words exist because the
    // language distinguishes which port is the rousing, not because the
    // arithmetic differs. If they ever disagree, one of them is a bug.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[10, 20, 30] | nth plane.i | write plane.byList
        \\plane.i | choose [10, 20, 30] | write plane.byIndex
    , .{.{ "plane.i", @as(f64, 0) }});
    defer fx.deinit();

    for ([_]f64{ 0, 1, 2, 0 }) |i| {
        try feedValue(&fx.rt, testing.allocator, "plane.i", i);
        try fx.rt.tick(.{});
        const a = slotNum(&fx, "programs.p.nth1.out.out").?;
        const b = slotNum(&fx, "programs.p.choose1.out.out").?;
        try testing.expectEqual(a, b);
        try testing.expectEqual(@as(f64, 10) * (i + 1), a);
    }
}

test "beat 2a: `nth` reads what `window` wrote — one array kind, not two" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hp | window 5s | nth 0 | write plane.out
    , .{.{ "plane.hp", @as(f64, 100) }});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 100), slotNum(&fx, "programs.p.nth1.out.out").?);
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(f64, 90));
    try fx.rt.tick(.{ .time_ns = 1_000_000_000 });
    // The window's oldest entry is still the first reading.
    try testing.expectEqual(@as(f64, 100), slotNum(&fx, "programs.p.nth1.out.out").?);
}

test "beat 2a: an out-of-range index refuses and names the length — never a clamp" {
    // The ledger's "A rather than B" rule: this gate runs where clamping and
    // refusing give DIFFERENT answers, and asserts that difference first.
    // Index 3 into a 3-element array would clamp to 30; the gate asserts the
    // wave died instead, so a clamping implementation cannot pass it.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.i | choose [10, 20, 30] | write plane.out
    , .{.{ "plane.i", @as(f64, 3) }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "choose", "out of range", "3 elements" });
    try testing.expectEqualStrings("choose", Refusal.opName());
    // A clamp would have emitted 30 here. Nothing was emitted at all.
    try testing.expect(fx.rt.readSlot("programs.p.choose1.out.out") == null);
}

test "beat 2a: a fractional index refuses rather than rounding" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.i | choose [10, 20, 30] | write plane.out
    , .{.{ "plane.i", @as(f64, 1.5) }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "choose", "not a whole number" });
    // Rounding either way would have emitted 20 or 10. Neither happened.
    try testing.expect(fx.rt.readSlot("programs.p.choose1.out.out") == null);
}

test "beat 2a: indexing a non-array names the type word, both sides" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.rec | nth 0 | write plane.out
    , .{.{ "plane.rec", .{ .x = @as(f64, 1), .y = @as(f64, 2) } }});
    defer fx.deinit();

    // Beat 1b's type-word vocabulary, reused verbatim — one vocabulary for
    // every shape complaint the language makes.
    try expectRefusalNames(&.{ "nth", "'in'", "record{x, y}", "not an array" });
}

test "beat 2a: the empty array is a value, and indexing it says so" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[] | nth 0 | write plane.out
    , .{});
    defer fx.deinit();

    const arr = fx.rt.readSlot("programs.p.array1.out.out") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(types.Tag.array, types.typeOfValue(arr));
    const nums = try arrayNums(testing.allocator, arr);
    defer testing.allocator.free(nums);
    try testing.expectEqual(@as(usize, 0), nums.len);
    // Plural agreement, because the message is read by a person: "0 elements"
    // is right and "0 element" is not.
    try expectRefusalNames(&.{ "nth", "0 elements" });
}

test "beat 2a: arrays nest, and hold records" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[[1, 2], [3, 4]] | nth 1 | nth 0 | write plane.out
        \\[{x: 1, y: 2}, {x: 3, y: 4}] | nth 1 as second
        \\second.x | write plane.fx
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 3), slotNum(&fx, "programs.p.nth2.out.out").?);
    try testing.expectEqual(@as(f64, 3), slotNum(&fx, "programs.p.project1.out.out").?);
}

test "beat 2a: beat 1b's broadcast reaches an array literal unchanged" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 2, 3] | mul 2 | write plane.out
    , .{});
    defer fx.deinit();

    const out = fx.rt.readSlot("programs.p.mul1.out.out") orelse return error.TestUnexpectedResult;
    const nums = try arrayNums(testing.allocator, out);
    defer testing.allocator.free(nums);
    try testing.expectEqualSlices(f64, &.{ 2, 4, 6 }, nums);
}

test "beat 2a: brackets became tokens and the tail still captures them verbatim" {
    // The hazard this beat was warned about: `[` and `]` used to lex as `.raw`
    // — legal only inside a tail — and a tail captures the RAW SOURCE between
    // token offsets. If the tail ever started reading token kinds instead,
    // this is where it would show. Both tail shapes are driven: no fixed
    // prefix, and a prefix of a static plus a port.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\sound play cue/[intro]/take 2, loud
        \\emitter drop e1 0.5 rig/[main]/nozzle
    , .{});
    defer fx.deinit();

    const s1 = fx.rt.readSlot("programs.p.sound play1.out.out") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("cue/[intro]/take 2, loud", types.asString(s1).?);
    const s2 = fx.rt.readSlot("programs.p.emitter drop1.out.out") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("rig/[main]/nozzle", types.asString(s2).?);
}

test "beat 2a: an unmatched bracket is a loud parse error, not an inert raw token" {
    try expectParseError("plane.a | mul [1, 2 | write plane.out", "|");
    try expectParseError("plane.a | mul 2] | write plane.out", "]");
}

test "beat 2a: the time-of-day row is CORRECT, not merely one line" {
    // §4's correctness column (ruled 2026-08-25): a ✓ means expressible; the
    // gate is what says it is right. This is the idioms book's after-cell,
    // driven against the four-line `select` chain it replaced — same answer
    // at every hour, including the band edges where an off-by-one would live.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.world.hour | div 6 | floor | choose [0.2, 1, 1, 0.4] | write plane.render.grade.exposure
        \\plane.world.hour | < 6 as night
        \\plane.world.hour | < 18 as day
        \\night | select 0.2 1.0 as lit
        \\day | select lit 0.4 | write plane.before.exposure
    , .{.{ "plane.world.hour", @as(f64, 0) }});
    defer fx.deinit();

    for ([_]f64{ 0, 5, 6, 11, 12, 17, 18, 23 }) |hour| {
        try feedValue(&fx.rt, testing.allocator, "plane.world.hour", hour);
        try fx.rt.tick(.{});
        const after = slotNum(&fx, "programs.p.choose1.out.out").?;
        const before = slotNum(&fx, "programs.p.select2.out.out").?;
        if (after != before) {
            std.debug.print("hour {d}: one line says {d}, the chain says {d}\n", .{ hour, after, before });
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// Beat 2b — contracts: `expect` and `match`, one shape literal, two promises.
//
// The pair only earns two words if the two promises stay different, so most
// of what follows is about the DIFFERENCE: `expect` fails the mount and then
// costs nothing; `match` costs on every value and never becomes a guarantee.
// ---------------------------------------------------------------------------

// `OpDef.fails_mount` audit — exhaustive both ways, like `class` and `ticks`.
// A refusal that unwinds the mount is a much bigger promise than a refusal
// that kills a wave, and it must never be acquired by inheriting a default.
test "every op that can fail a mount says so, and no other does" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    const fatal = [_][]const u8{"expect"};
    for (fatal) |name| {
        const id = reg.find(name) orelse {
            std.debug.print("'{s}' is gone — update the fails_mount audit\n", .{name});
            return error.TestUnexpectedResult;
        };
        if (!reg.get(id).fails_mount) {
            std.debug.print("'{s}': the audit says it fails the mount and it does not declare it\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    for (reg.ops.items) |def| {
        if (!def.fails_mount) continue;
        const listed = for (fatal) |n| {
            if (std.mem.eql(u8, n, def.name)) break true;
        } else false;
        if (!listed) {
            std.debug.print("'{s}' declares fails_mount and is not in the audit\n", .{def.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "beat 2b: `match` refuses a malformed contact list, naming the field and both sides" {
    // §4's "refuse a malformed contact list at the boundary", which was
    // *silent* — a shape mismatch was discovered downstream, or not at all.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.sensors.gate.nearest | match {id: string, distance: number} | write plane.ui.threat
    , .{.{ "plane.sensors.gate.nearest", .{ .id = "raider-3", .distance = "close" } }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "match", "'.distance'", "string", "not number" });
    try testing.expect(fx.rt.readSlot("programs.p.match1.out.out") == null);
}

test "beat 2b: `match` passes what fits, unchanged" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.sensors.gate.nearest | match {id: string, distance: number} | write plane.ui.threat
    , .{.{ "plane.sensors.gate.nearest", .{ .id = "raider-3", .distance = @as(f64, 8) } }});
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    const out = fx.rt.readSlot("programs.p.match1.out.out") orelse return error.TestUnexpectedResult;
    const fields = try recordFields(testing.allocator, out);
    defer freeFields(testing.allocator, fields);
    try testing.expectEqual(@as(usize, 2), fields.len);
}

test "beat 2b: shapes are OPEN by default and `exact` closes them" {
    // "A rather than B": the same value against the same shape, differing only
    // in the word `exact` — so a shape that quietly closed itself, or an
    // `exact` that did nothing, both fail here.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {id: string} | write plane.open_out
    , .{.{ "plane.c", .{ .id = "x", .extra = @as(f64, 1) } }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expect(fx.rt.readSlot("programs.p.match1.out.out") != null);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\plane.c | match {id: string} exact | write plane.exact_out
    , .{.{ "plane.c", .{ .id = "x", .extra = @as(f64, 1) } }});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "match", "extra", "not in the shape", "exact" });
    try testing.expect(fx2.rt.readSlot("programs.p.match1.out.out") == null);
}

test "beat 2b: `exact` closes every record in the shape, not only the outermost" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {pos: {x: number, y: number}} exact | write plane.out
    , .{.{ "plane.c", .{ .pos = .{ .x = @as(f64, 1), .y = @as(f64, 2), .z = @as(f64, 3) } } }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "match", ".pos.z", "not in the shape" });
}

test "beat 2b: shapes nest, and the refusal names the path it took" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {pos: {x: number, y: number, z: number}, kind: string} | write plane.out
    , .{.{ "plane.c", .{ .kind = "raider", .pos = .{ .x = @as(f64, 1), .y = @as(f64, 2), .z = "deep" } } }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "match", "'.pos.z'", "string", "not number" });
}

test "beat 2b: `[number]` checks every element, and names the index" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 2, 3] | match [number] | write plane.good
    , .{});
    defer fx.deinit();
    try testing.expect(fx.rt.readSlot("programs.p.match1.out.out") != null);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\[1, "two", 3] | match [number] | write plane.bad
    , .{});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "match", "'[1]'", "string", "not number" });
}

test "beat 2b: a missing field is named, and `?` makes it optional" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {id: string, distance: number} | write plane.out
    , .{.{ "plane.c", .{ .id = "x" } }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "match", "'.distance'", "missing" });

    // Same value, same shape, one `?` — and it passes. That is the assertion:
    // `?` must be the only difference.
    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\plane.c | match {id: string, distance?: number} | write plane.out
    , .{.{ "plane.c", .{ .id = "x" } }});
    defer fx2.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expect(fx2.rt.readSlot("programs.p.match1.out.out") != null);
}

test "beat 2b: `any` requires presence and nothing else" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {id: any} | write plane.out
    , .{.{ "plane.c", .{ .id = @as(f64, 7) } }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\plane.c | match {id: any} | write plane.out
    , .{.{ "plane.c", .{ .other = @as(f64, 7) } }});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "match", "'.id'", "missing" });
}

test "beat 2b: `expect` REFUSES THE MOUNT — the mount returns an error, not a log line" {
    // The whole difference between the two words. A `match` mismatch kills a
    // wave and the program stays up; an `expect` mismatch means the program
    // never mounts at all.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.c", .{ .id = @as(f64, 3) });
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.c | expect {id: string} | write plane.out
    , &diag);
    defer prog.deinit();

    Refusal.reset();
    const result = rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .error_fn = Refusal.on });
    try testing.expectError(error.Refused, result);
    // …and the words reached the ack BEFORE the mount unwound, so the host
    // can say which node and why. Ack first, then free.
    try expectRefusalNames(&.{ "expect", "'.id'", "number", "not string" });
}

test "beat 2b: `expect` mounts what fits, and passes it through" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | expect {id: string, distance: number} | write plane.out
    , .{.{ "plane.c", .{ .id = "raider-3", .distance = @as(f64, 8) } }});
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expect(fx.rt.readSlot("programs.p.expect1.out.out") != null);
}

test "beat 2b: `expect` NEVER falls back to a runtime check" {
    // The promise that makes `expect` free: it asserts once, at mount, and
    // after that it costs nothing — which means a value that arrives later and
    // violates the shape passes straight through. That is not a bug, it is the
    // contract, and it is why `match` exists as a separate word.
    //
    // "A rather than B": this gate runs where the two words DISAGREE — the
    // mount-time value fits and the later one does not — and asserts the
    // `expect` reading. A fallback-to-runtime implementation cannot pass it.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | expect {id: string} | write plane.out
    , .{.{ "plane.c", .{ .id = "raider-3" } }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);

    // A bare number where the shape says record — as loud a violation as
    // there is, and `expect` lets it through because it is no longer looking.
    try feedValue(&fx.rt, testing.allocator, "plane.c", @as(f64, 3));
    try fx.rt.tick(.{});

    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    const out = fx.rt.readSlot("programs.p.expect1.out.out") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f64, 3), types.asNumber(out).?);
}

test "beat 2b: `expect` on a path with nothing at mount refuses the mount" {
    // Nothing to assert against is a failed assertion, not a deferral. The
    // message states that and stops: which operator to reach for instead is a
    // judgement about the path, and it lives in the manual (ruled 2026-08-25).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.absent | expect {id: string} | write plane.out
    , &diag);
    defer prog.deinit();

    Refusal.reset();
    const result = rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .error_fn = Refusal.on });
    try testing.expectError(error.Refused, result);
    try expectRefusalNames(&.{ "expect", "nothing here at mount", "no shape to assert" });
}

test "beat 2b: a `match` refusal after mount does NOT bring the program down" {
    // The mirror of the gate above, and the reason `fails_mount` is a per-op
    // declaration rather than a runtime mode.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {id: string} | write plane.out
    , .{.{ "plane.c", .{ .id = "ok" } }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);

    try feedValue(&fx.rt, testing.allocator, "plane.c", @as(f64, 3));
    try fx.rt.tick(.{}); // does not error: the wave dies, the program lives
    try expectRefusalNames(&.{ "match", "the value", "number", "not record{id}" });
}

test "beat 2b: the shape literal refuses what it cannot mean" {
    try expectParseError("plane.c | match {id: str}", "not a type");
    try expectParseError("plane.c | match {}", "empty shape");
    try expectParseError("plane.c | match {id string}", "expected ':'");
    try expectParseError("plane.c | match id", "expects a shape");
    try expectParseError("plane.c | match [number", "expected ']'");
}

test "beat 2b: a shape survives dump and restore" {
    // The shape is a static, and statics ride the dump. It is stored as BYTES
    // (kind 6), not as text, so this is where a re-encoding layer would show.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.c | match {id: string, pos: {x: number}} exact | write plane.out
    , .{.{ "plane.c", .{ .id = "x", .pos = .{ .x = @as(f64, 1) } } }});
    defer fx.deinit();

    const dumped = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(dumped);
    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, dumped);
    defer prog2.deinit();

    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    // The reloaded shape must still refuse the extra field: if `exact` or the
    // nesting had been lost in the round trip, this value would sail through.
    try mock2.putValue("plane.c", .{ .id = "x", .pos = .{ .x = @as(f64, 1) }, .extra = @as(f64, 2) });
    Refusal.reset();
    var rt2 = try rill.Runtime.mount(testing.allocator, &prog2, mock2.asPlane(), .{ .error_fn = Refusal.on });
    defer rt2.deinit();
    try expectRefusalNames(&.{ "match", "extra", "not in the shape" });
}

// ---------------------------------------------------------------------------
// Beat 3a — bodies: `map`, `keep`, `reduce`.
//
// The structural half of beat 3. A section stops being "a node wired to the
// consumer's stream" and becomes a BODY the consumer drives per element — so
// most of what follows is about that mechanism holding: arity declared by the
// consumer, the body skipped by the sweep, a body's own bound ports still
// live, and a body's refusal still landing in its own words.
// ---------------------------------------------------------------------------

test "beat 3a: `map` runs the body once per element, in order" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[-1, 0.5, 3] | map (clamp 0 1) | write plane.out
    , .{});
    defer fx.deinit();

    const out = fx.rt.readSlot("programs.p.map1.out.out") orelse return error.TestUnexpectedResult;
    const nums = try arrayNums(testing.allocator, out);
    defer testing.allocator.free(nums);
    // In order, and the same length: a map that reordered or shortened would
    // still produce "three numbers".
    try testing.expectEqualSlices(f64, &.{ 0, 0.5, 1 }, nums);
}

test "beat 3a: `keep` filters ELEMENTS and `where` gates the STREAM — the crossing case" {
    // The one-axis rule, executed. `keep` takes a section and filters
    // elements; `where` takes a boolean stream and gates arrivals. Both apply
    // to an array-valued stream, which is precisely why one word dispatched by
    // kind would have had to guess.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[-2, 5, 0, 7] | keep (> 0) | write plane.kept
        \\[-2, 5, 0, 7] | where plane.gate.open | write plane.gated
    , .{.{ "plane.gate.open", true }});
    defer fx.deinit();

    const kept = fx.rt.readSlot("programs.p.keep1.out.out") orelse return error.TestUnexpectedResult;
    const nums = try arrayNums(testing.allocator, kept);
    defer testing.allocator.free(nums);
    try testing.expectEqualSlices(f64, &.{ 5, 7 }, nums);

    // `where` passed the WHOLE array through, untouched — it gated, it did not
    // filter. Four elements, not two.
    const gated = fx.rt.readSlot("programs.p.where1.out.out") orelse return error.TestUnexpectedResult;
    const all = try arrayNums(testing.allocator, gated);
    defer testing.allocator.free(all);
    try testing.expectEqualSlices(f64, &.{ -2, 5, 0, 7 }, all);
}

test "beat 3a: `reduce` is a LEFT fold — and the gate runs where left and right differ" {
    // "A rather than B": `(10 - 3) - 2` is 5 and `10 - (3 - 2)` is 9, so this
    // array is chosen because the two folds disagree. A right fold cannot pass.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[10, 3, 2] | reduce (sub) | write plane.out
    , .{});
    defer fx.deinit();

    try testing.expect(@as(f64, 5) != @as(f64, 9)); // the inequality, asserted first
    try testing.expectEqual(@as(f64, 5), slotNum(&fx, "programs.p.reduce1.out.out").?);
}

test "beat 3a: with no `init` the first element seeds; `init` seeds instead" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 2, 3] | reduce (add) | write plane.plain
        \\[1, 2, 3] | reduce (add) init 100 | write plane.seeded
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 6), slotNum(&fx, "programs.p.reduce1.out.out").?);
    try testing.expectEqual(@as(f64, 106), slotNum(&fx, "programs.p.reduce2.out.out").?);
}

test "beat 3a: an empty array with no `init` is an error naming the operator" {
    // There is no honest value to invent: 0 is right for `add` and wrong for
    // `mul`, and picking one is picking a rule.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[] | reduce (add) | write plane.out
    , .{});
    defer fx.deinit();

    try expectRefusalNames(&.{ "reduce", "empty", "init" });
    try testing.expect(fx.rt.readSlot("programs.p.reduce1.out.out") == null);
    try testing.expectEqualStrings("reduce", Refusal.opName());
}

test "beat 3a: an empty array WITH `init` folds to the init" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[] | reduce (add) init 42 | write plane.out
    , .{});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expectEqual(@as(f64, 42), slotNum(&fx, "programs.p.reduce1.out.out").?);
}

test "beat 3a: the consumer declares section arity, and a mismatch names both counts" {
    // Chris's pin, both directions. The message must name the operator and
    // both numbers — "wrong arity" alone tells an author nothing about which
    // way to fix it.
    try expectParseError("[1, 2] | map (add) | write plane.out", "supplies 1 argument");
    try expectParseError("[1, 2] | map (add) | write plane.out", "leaves 2 ports open");
    try expectParseError("[1, 2] | reduce (clamp 0 1) | write plane.out", "supplies 2 arguments");
    try expectParseError("[1, 2] | reduce (clamp 0 1) | write plane.out", "leaves 1 port open");
    // …and the operator is named in both.
    try expectParseError("[1, 2] | map (add) | write plane.out", "map");
    try expectParseError("[1, 2] | reduce (clamp 0 1) | write plane.out", "reduce");
}

test "beat 3a: a body-driving operator with no body refuses at parse" {
    // Earlier than mount, which is strictly louder: an operator whose whole
    // job is running a body cannot be given none.
    try expectParseError("[1, 2] | map | write plane.out", "needs a section body");
    try expectParseError("[1, 2] | reduce | write plane.out", "2 open ports");
}

test "beat 3a: `(.field)` is a section — the projection body" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{id: 1, distance: 8}, {id: 2, distance: 3}] | map (.distance) | write plane.out
    , .{});
    defer fx.deinit();

    const out = fx.rt.readSlot("programs.p.map1.out.out") orelse return error.TestUnexpectedResult;
    const nums = try arrayNums(testing.allocator, out);
    defer testing.allocator.free(nums);
    try testing.expectEqualSlices(f64, &.{ 8, 3 }, nums);
}

test "beat 3a: any-of over a set — `map (.armed) | reduce (or)`" {
    // §2.11's loudest customer, in one line.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{armed: false}, {armed: true}] | map (.armed) | reduce (or) | write plane.any
        \\[{armed: false}, {armed: false}] | map (.armed) | reduce (or) | write plane.none
    , .{});
    defer fx.deinit();

    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.reduce1.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.reduce2.out.out").?).?);
}

test "beat 3a: a body's own BOUND port is live" {
    // A body is not a closure, but it may hold ports of its own that the
    // program feeds. A value arriving there must rouse the CONSUMER — the body
    // has no output anyone reads and the sweep skips it — which is the one
    // thing about this mechanism that has no local symptom when it is wrong.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 5, 9] | keep (> plane.threshold) | write plane.out
    , .{.{ "plane.threshold", @as(f64, 0) }});
    defer fx.deinit();

    {
        const out = fx.rt.readSlot("programs.p.keep1.out.out") orelse return error.TestUnexpectedResult;
        const nums = try arrayNums(testing.allocator, out);
        defer testing.allocator.free(nums);
        try testing.expectEqualSlices(f64, &.{ 1, 5, 9 }, nums);
    }
    try feedValue(&fx.rt, testing.allocator, "plane.threshold", @as(f64, 6));
    try fx.rt.tick(.{});
    {
        const out = fx.rt.readSlot("programs.p.keep1.out.out") orelse return error.TestUnexpectedResult;
        const nums = try arrayNums(testing.allocator, out);
        defer testing.allocator.free(nums);
        try testing.expectEqualSlices(f64, &.{9}, nums);
    }
}

test "beat 3a: a body node is not evaluated by the sweep" {
    // The body's open port has no source, so a swept body would refuse every
    // tick — silently, since nothing reads its output. What keeps it out of
    // the sweep is `markNode`'s redirect (a body is never marked dirty), not a
    // skip in `evalNode`: a guard there survived its mutation, because nothing
    // could reach it. See the note on `Runtime.markNode`.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[1, 2, 3] | map (clamp 0 1) | write plane.out
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    // The body's own output slot never carries a value: nothing propagates
    // from a body, because the only reader is the operator that called it.
    try testing.expect(fx.rt.readSlot("programs.p.clamp1.out.out") == null);
}

test "beat 3a: a body's refusal arrives in the BODY's words" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[1, 2] | map (nth 0) | write plane.out
    , .{});
    defer fx.deinit();

    // `nth` refused, not `map` — the words are the body's, so an author is
    // told which step went wrong rather than which step was driving.
    try expectRefusalNames(&.{ "nth", "not an array" });
}

test "beat 3a: `map` keeps the length — a body that emits nothing is refused" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[1, 2, 3] | map (where false) | write plane.out
    , .{});
    defer fx.deinit();

    try expectRefusalNames(&.{ "map", "emitted nothing", "keep" });
}

test "beat 3a: `keep` refuses a predicate that does not answer a boolean" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[1, 2, 3] | keep (add 1) | write plane.out
    , .{});
    defer fx.deinit();

    try expectRefusalNames(&.{ "keep", "not a boolean" });
}

test "beat 3a: a body survives dump and restore" {
    // `Node.body` is the only body link that is serialized; the other three
    // are derived by `linkBodies` at the end of a parse AND at the end of a
    // load, so this is where those two paths would disagree.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.xs | keep (> plane.threshold) | reduce (add) | write plane.out
    , .{ .{ "plane.xs", [_]f64{ 1, 5, 9 } }, .{ "plane.threshold", @as(f64, 4) } });
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 14), slotNum(&fx, "programs.p.reduce1.out.out").?);

    const dumped = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(dumped);
    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, dumped);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    try mock2.putValue("plane.xs", [_]f64{ 1, 5, 9 });
    try mock2.putValue("plane.threshold", @as(f64, 4));
    Refusal.reset();
    var rt2 = try rill.Runtime.mount(testing.allocator, &prog2, mock2.asPlane(), .{ .error_fn = Refusal.on });
    defer rt2.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expectEqual(@as(f64, 14), types.asNumber(rt2.readSlot("programs.p.reduce1.out.out").?).?);
}

test "beat 3a: an unbound OPTIONAL port is absent, not open" {
    // Arity counts the ports a section left open, and an optional port nobody
    // bound is a different thing: `ease`'s `up`/`down` are absent, not slots
    // waiting for the consumer. Counting them would make every section over an
    // op with optionals unusable.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = rill.parse(testing.allocator, &reg, "p",
        \\[1, 2] | map (ease 100ms) | write plane.out
    , &diag) catch |err| {
        if (err == error.Parse) std.debug.print("parse: {s}\n", .{diag.msg()});
        return err;
    };
    defer prog.deinit();

    const map_id = nodeIdOf(&prog, "map1") orelse return error.TestUnexpectedResult;
    const body_id = prog.nodes.items[map_id].body orelse return error.TestUnexpectedResult;
    // One open port — the input — and not three.
    try testing.expectEqual(@as(usize, 1), prog.nodes.items[body_id].body_open.len);
    try testing.expectEqual(map_id, prog.nodes.items[body_id].body_of.?);
}

// ---------------------------------------------------------------------------
// Beat 3b — order and shape: `sort`, `first`, `take`, `transpose`, `shuffle`,
// `along`.
// ---------------------------------------------------------------------------

test "beat 3b: nearest hostile from the contact list, one line" {
    // §4's row, which was an invented sensor field. One line since the
    // `| .field` ruling (2026-08-25) — before it, a row ending in a field read
    // cost a second line because `.field` read from a name or a path.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{id: 7, distance: 8}, {id: 4, distance: 3}, {id: 9, distance: 5}] | sort by (.distance) | first | .distance | write plane.ui.nearest
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 3), slotNum(&fx, "programs.p.project2.out.out").?);
}

test "the taught spelling: `| .field` mid-chain is `project`, and chains" {
    // Sugar for the `project` operator, which stays registered as substrate.
    // `| .a.b` means exactly what `name.a.b` means, because it IS the same
    // code path — so there is one answer to "what does a dotted read do",
    // not two.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.rig | .pos.x | write plane.out
        \\plane.rig as r
        \\r.pos.x | write plane.same
    , .{.{ "plane.rig", .{ .pos = .{ .x = @as(f64, 4), .y = @as(f64, 9) } } }});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 4), slotNum(&fx, "programs.p.project2.out.out").?);
    try testing.expectEqual(@as(f64, 4), slotNum(&fx, "programs.p.project4.out.out").?);
}

test "the taught spelling: a bare `| .` still says what is missing" {
    try expectParseError("plane.a | . | write plane.out", "field name after");
}

test "beat 3b: `sort` orders by the key body, and `desc` reverses it" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{id: 1, d: 8}, {id: 2, d: 3}, {id: 3, d: 5}] | sort by (.d) | map (.id) | write plane.asc
        \\[{id: 1, d: 8}, {id: 2, d: 3}, {id: 3, d: 5}] | sort by (.d) desc | map (.id) | write plane.desc
    , .{});
    defer fx.deinit();

    const asc = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.map1.out.out").?);
    defer testing.allocator.free(asc);
    try testing.expectEqualSlices(f64, &.{ 2, 3, 1 }, asc);

    const desc = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.map2.out.out").?);
    defer testing.allocator.free(desc);
    try testing.expectEqualSlices(f64, &.{ 1, 3, 2 }, desc);
}

test "beat 3b: `sort` is STABLE — enough ties to make an unstable sort show" {
    // Chris's pin, on the SECOND attempt. The first version of this gate used
    // four elements and three ties, and a mutation removing the stability
    // tie-break SURVIVED it: `std.sort.pdq` falls back to insertion sort below
    // a size threshold, and insertion sort is stable by accident. A gate that
    // passes because of the algorithm underneath is watching nothing.
    //
    // So: 40 elements, two keys, ties everywhere, which is well past the
    // fallback and forces the partitioning that reorders equal keys. What
    // makes this pass is the index tie-break in `keyedLess`, and removing it
    // now bites.
    const gpa = testing.allocator;
    var src = std.ArrayListUnmanaged(u8).empty;
    defer src.deinit(gpa);
    var buf: [64]u8 = undefined;
    try src.appendSlice(gpa, "[");
    for (0..40) |i| {
        if (i > 0) try src.appendSlice(gpa, ", ");
        try src.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{{id: {d}, d: {d}}}", .{ i, i % 2 }));
    }
    try src.appendSlice(gpa, "] | sort by (.d) | map (.id) | write plane.asc");

    var fx: Fixture = undefined;
    try mountFixture(gpa, &fx, src.items, .{});
    defer fx.deinit();

    const got = try arrayNums(gpa, fx.rt.readSlot("programs.p.map1.out.out").?);
    defer gpa.free(got);
    try testing.expectEqual(@as(usize, 40), got.len);
    // Every d=0 first, then every d=1 — and WITHIN each group, input order.
    for (0..20) |i| try testing.expectEqual(@as(f64, @floatFromInt(i * 2)), got[i]);
    for (0..20) |i| try testing.expectEqual(@as(f64, @floatFromInt(i * 2 + 1)), got[20 + i]);
}

test "beat 3b: `desc` reverses the KEYS and not the ties" {
    // A "sort ascending, then reverse the array" would give 4, 2, 1, 3 here.
    // Descending is a different comparison, not a post-pass.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{id: 1, d: 5}, {id: 2, d: 5}, {id: 3, d: 1}, {id: 4, d: 5}] | sort by (.d) | map (.id) | write plane.asc
        \\[{id: 1, d: 5}, {id: 2, d: 5}, {id: 3, d: 1}, {id: 4, d: 5}] | sort by (.d) desc | map (.id) | write plane.desc
    , .{});
    defer fx.deinit();

    const asc = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.map1.out.out").?);
    defer testing.allocator.free(asc);
    try testing.expectEqualSlices(f64, &.{ 3, 1, 2, 4 }, asc);

    const desc = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.map2.out.out").?);
    defer testing.allocator.free(desc);
    try testing.expectEqualSlices(f64, &.{ 1, 2, 4, 3 }, desc);
}

test "beat 3b: `sort` with no `by` uses the elements as their own keys" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[3, 1, 2] | sort | write plane.out
    , .{});
    defer fx.deinit();
    const out = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.sort1.out.out").?);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, out);
}

test "beat 3b: sorting compares numbers by VALUE, not by encoding" {
    // struple's raw bytes are memcmp-orderable and that is the store's order —
    // but there the type byte dominates, so every integer would file before
    // every float. In rill both are `number`, so a memcmp sort would be a
    // wrong picture nobody is told about. `2` is an int literal and `1.5` and
    // `2.5` are floats: a memcmp sort puts 2 first.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[2.5, 2, 1.5] | sort | write plane.out
    , .{});
    defer fx.deinit();
    const out = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.sort1.out.out").?);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(f64, &.{ 1.5, 2, 2.5 }, out);
}

test "beat 3b: `sort` needs its section after `by`" {
    try expectParseError("[1, 2] | sort (.d) | write plane.out", "after 'by'");
}

test "beat 3b: top three threats, one line" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{id: 1, t: 2}, {id: 2, t: 9}, {id: 3, t: 5}, {id: 4, t: 7}] | sort by (.t) desc | take 3 | map (.id) | write plane.ui.threats
    , .{});
    defer fx.deinit();
    const out = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.map1.out.out").?);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(f64, &.{ 2, 4, 3 }, out);
}

test "beat 3b: `take` forgives a short array and `nth` does not — the asymmetry" {
    // Chris's pin, gated as the pair it is. `take 5` promises AT MOST five and
    // two is a satisfiable answer; `nth 5` promises THE SIXTH and there isn't
    // one. Same array, same number, opposite outcomes — which is the whole
    // claim, so both halves run against the same input.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[1, 2] | take 5 | write plane.taken
        \\[1, 2] | nth 5 | write plane.picked
    , .{});
    defer fx.deinit();

    const out = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.take1.out.out").?);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(f64, &.{ 1, 2 }, out);

    try expectRefusalNames(&.{ "nth", "out of range" });
    try testing.expect(fx.rt.readSlot("programs.p.nth1.out.out") == null);
}

test "beat 3b: `take … from` slices, and past the end is empty rather than an error" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[1, 2, 3, 4, 5] | take 2 from 1 | write plane.mid
        \\[1, 2] | take 3 from 9 | write plane.past
    , .{});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);

    const mid = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.take1.out.out").?);
    defer testing.allocator.free(mid);
    try testing.expectEqualSlices(f64, &.{ 2, 3 }, mid);

    const past = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.take2.out.out").?);
    defer testing.allocator.free(past);
    try testing.expectEqual(@as(usize, 0), past.len);
}

test "`first`/`last` on an empty array END THE WAVE — and `nth` still errors" {
    // Ruled 2026-08-26, replacing beat 3b's refusal. The `where` precedent: a
    // value cannot be invented, and an operator with nothing to say says
    // nothing. "No contacts" is the ordinary state of a sensor, and the
    // ordinary state of the world should not spend a program's error budget.
    //
    // Gated as the ASYMMETRY, because that is the ruling: `first` and `last`
    // go quiet on the same array where `nth 0` refuses. Two operators reading
    // the same empty list, one silence and one refusal, in one program.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[] | first | write plane.a
        \\[] | last | write plane.b
    , .{});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    // Nothing reached the sinks, and nothing was said about it.
    try testing.expect(fx.rt.readSlot("programs.p.first1.out.out") == null);
    try testing.expect(fx.rt.readSlot("programs.p.last1.out.out") == null);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\[] | nth 0 | write plane.c
    , .{});
    defer fx2.deinit();
    // `nth 0` names a position, which is a claim that the position exists.
    try expectRefusalNames(&.{ "nth", "out of range", "0 elements" });
}

test "`last` is the most recent reading, and `len` is how many there are" {
    // `last`'s customer, and `len`'s: a rolling window says both what it last
    // saw and how much it has seen, without either being reached for through
    // `stats`.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[3, 1, 4, 1, 5] | last | write plane.recent
        \\[3, 1, 4, 1, 5] | len | write plane.n
        \\[] | len | write plane.none
    , .{});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 5), types.asNumber(fx.rt.readSlot("programs.p.last1.out.out").?).?);
    try testing.expectEqual(@as(f64, 5), types.asNumber(fx.rt.readSlot("programs.p.len1.out.out").?).?);
    // The whole reason `len` was admitted: absence is SAID, by the count. An
    // empty array is where `first` goes quiet and `len` does not.
    try testing.expectEqual(@as(f64, 0), types.asNumber(fx.rt.readSlot("programs.p.len2.out.out").?).?);
}

test "`last` reads the END of the array, not the start" {
    // "A rather than B", where A ≠ B: a one-element array cannot tell these
    // apart, and neither can a palindrome. Five elements, first ≠ last.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[3, 1, 4, 1, 5] | first | write plane.a
        \\[3, 1, 4, 1, 5] | last | write plane.b
    , .{});
    defer fx.deinit();
    const a = types.asNumber(fx.rt.readSlot("programs.p.first1.out.out").?).?;
    const b = types.asNumber(fx.rt.readSlot("programs.p.last1.out.out").?).?;
    try testing.expect(a != b);
    try testing.expectEqual(@as(f64, 3), a);
    try testing.expectEqual(@as(f64, 5), b);
}

test "beat 3b: `transpose` is self-inverse, both directions" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{a: [1, 2], b: [3, 4]} | transpose | write plane.aos
        \\{a: [1, 2], b: [3, 4]} | transpose | transpose | write plane.round
    , .{});
    defer fx.deinit();

    // Record of arrays → array of records.
    const aos = fx.rt.readSlot("programs.p.transpose1.out.out").?;
    try testing.expectEqual(types.Tag.array, types.typeOfValue(aos));
    const inner = try innerOf(testing.allocator, aos);
    defer testing.allocator.free(inner);
    var r = struple.reader(inner);
    const row0 = (try r.nextView()).?;
    const f0 = try recordFields(testing.allocator, row0);
    defer freeFields(testing.allocator, f0);
    try testing.expectEqual(@as(usize, 2), f0.len);
    try testing.expectEqualStrings("a", fieldName(f0[0]));
    try testing.expectEqual(@as(f64, 1), f0[0].v);
    try testing.expectEqual(@as(f64, 3), f0[1].v);

    // …and back again, unchanged.
    const round = fx.rt.readSlot("programs.p.transpose3.out.out").?;
    try testing.expectEqual(types.Tag.record, types.typeOfValue(round));
    const rf = try recordFields(testing.allocator, round);
    defer freeFields(testing.allocator, rf);
    try testing.expectEqual(@as(usize, 2), rf.len);
}

test "beat 3b: `transpose` refuses ragged input in BOTH directions, both sides named" {
    // Chris's pin. Grasshopper picks a matching rule implicitly and it is the
    // most-complained-about behaviour in the tool.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\{a: [1, 2], b: [3]} | transpose | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "transpose", "'a'", "'b'", "2 elements", "1" });

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\[{a: 1, b: 2}, {a: 3}] | transpose | write plane.out
    , .{});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "transpose", "record{a, b}", "record{a}" });
}

test "beat 3b: `shuffle` is seeded, defaults to 0, and replays identically" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 2, 3, 4, 5, 6, 7, 8] | shuffle | write plane.a
        \\[1, 2, 3, 4, 5, 6, 7, 8] | shuffle seed 0 | write plane.b
        \\[1, 2, 3, 4, 5, 6, 7, 8] | shuffle seed 7 | write plane.c
    , .{});
    defer fx.deinit();

    const a = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.shuffle1.out.out").?);
    defer testing.allocator.free(a);
    const b = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.shuffle2.out.out").?);
    defer testing.allocator.free(b);
    const c = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.shuffle3.out.out").?);
    defer testing.allocator.free(c);

    // Seed 0 is the default: saying it and not saying it are the same program.
    try testing.expectEqualSlices(f64, a, b);
    // A different seed is a different permutation — otherwise the seed is
    // decoration.
    try testing.expect(!std.mem.eql(f64, a, c));
    // It IS a permutation: same multiset, eight elements, nothing invented.
    try testing.expectEqual(@as(usize, 8), a.len);
    var sum: f64 = 0;
    for (a) |v| sum += v;
    try testing.expectEqual(@as(f64, 36), sum);
    // …and it actually moved something.
    try testing.expect(!std.mem.eql(f64, a, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }));
}

test "beat 3b: `along` passes through its knots and clamps outside 0..1" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.t | along [0, 10, 20] | write plane.out
    , .{.{ "plane.t", @as(f64, 0) }});
    defer fx.deinit();

    const at = struct {
        fn go(f: *Fixture, t: f64) !f64 {
            try feedValue(&f.rt, testing.allocator, "plane.t", t);
            try f.rt.tick(.{});
            return slotNum(f, "programs.p.along1.out.out").?;
        }
    }.go;

    // Catmull-Rom passes through every knot exactly.
    try testing.expectEqual(@as(f64, 0), try at(&fx, 0));
    try testing.expectEqual(@as(f64, 10), try at(&fx, 0.5));
    try testing.expectEqual(@as(f64, 20), try at(&fx, 1));
    // A path has ends: outside 0..1 clamps rather than extrapolating.
    try testing.expectEqual(@as(f64, 0), try at(&fx, -3));
    try testing.expectEqual(@as(f64, 20), try at(&fx, 4));
}

test "beat 3b: move a light through three points typed into a cell — the row, finished" {
    // §4's three-points row, whose other half landed in beat 2a. The knots are
    // records, so the curve runs through each axis.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.door.openness | along [{x: 0, y: 3, z: 0}, {x: 2, y: 3, z: 1}, {x: 4, y: 3, z: 0}] | write plane.lights.key.pos
    , .{.{ "plane.door.openness", @as(f64, 0.5) }});
    defer fx.deinit();

    const out = fx.rt.readSlot("programs.p.along1.out.out").?;
    const f = try recordFields(testing.allocator, out);
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expectEqualStrings("x", fieldName(f[0]));
    try testing.expectEqual(@as(f64, 2), f[0].v); // the middle knot, exactly
    try testing.expectEqual(@as(f64, 3), f[1].v); // y never moves
    try testing.expectEqual(@as(f64, 1), f[2].v);
}

test "beat 3b: `along` refuses fewer than two knots, at mount" {
    // Chris's pin. Mount runs tick 0, so a mounted program hears this at
    // mount — one knot is not a path.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.t | along [5] | write plane.out
    , .{.{ "plane.t", @as(f64, 0.5) }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "along", "1 knot", "at least two" });
    try testing.expect(fx.rt.readSlot("programs.p.along1.out.out") == null);
}

test "beat 3b: `along` refuses knots of different shapes, naming the field" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.t | along [{x: 0, y: 0}, {x: 1, z: 1}] | write plane.out
    , .{.{ "plane.t", @as(f64, 0.5) }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "along", "same shape" });
}

// ---------------------------------------------------------------------------
// Beat 4 — events, levels, noise, randomness, space.
//
// The shaping pin: LEVELS EMIT AT TICK 0, CROSSINGS BASELINE SILENTLY. A
// program that reads a level must have one to read on its first evaluation;
// a crossing nobody crossed is not an event.
// ---------------------------------------------------------------------------

test "beat 4a: `pulse` is a VALUE source and `every` is the occurrence source" {
    // One node, one kind. An operator that both fired an occurrence AND held a
    // value would be two operators sharing a name, and nothing downstream
    // could tell which one it was talking to. Asserted from the registry, so a
    // later edit to either declaration fails here rather than in a host.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    const pulse = reg.get(reg.find("pulse").?);
    const every = reg.get(reg.find("every").?);
    try testing.expectEqual(registry.PortKind.value, pulse.outputs[0].kind);
    try testing.expectEqual(registry.PortKind.occurrence, every.outputs[0].kind);
}

test "beat 4a: `pulse` is 1 for its width and 0 for the rest of the period" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\pulse 1s width 100ms | write plane.out
    , .{});
    defer fx.deinit();

    const at = struct {
        fn go(f: *Fixture, ns: u64) !f64 {
            try f.rt.tick(.{ .time_ns = ns });
            return slotNum(f, "programs.p.pulse1.out.out").?;
        }
    }.go;

    try testing.expectEqual(@as(f64, 1), try at(&fx, 0));
    try testing.expectEqual(@as(f64, 1), try at(&fx, 50_000_000));
    try testing.expectEqual(@as(f64, 0), try at(&fx, 100_000_000));
    try testing.expectEqual(@as(f64, 0), try at(&fx, 900_000_000));
    try testing.expectEqual(@as(f64, 1), try at(&fx, 1_000_000_000)); // next period
    try testing.expectEqual(@as(f64, 0), try at(&fx, 1_200_000_000));
}

test "beat 4a: `pulse` width defaults to a tenth of the period" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\pulse 1s | write plane.a
        \\pulse 1s width 100ms | write plane.b
    , .{});
    defer fx.deinit();

    // Same programs, tick for tick — which is what "defaults to a tenth" means.
    for ([_]u64{ 0, 50_000_000, 99_000_000, 100_000_000, 500_000_000, 1_050_000_000 }) |ns| {
        try fx.rt.tick(.{ .time_ns = ns });
        try testing.expectEqual(
            slotNum(&fx, "programs.p.pulse2.out.out").?,
            slotNum(&fx, "programs.p.pulse1.out.out").?,
        );
    }
}

test "beat 4a: `pulse` refuses a width on the other lane" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\pulse 1s width 3f | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "pulse", "different lanes" });
}

test "beat 4a: unpiped, `once` fires at tick 0 by §3.8 and never again" {
    // Unpiped at the head, the value binds port 0 and is both rousing and
    // payload — §3.8's rule, no new one. `tally` downstream counts how many
    // times it actually fired, which is the only way to see "never again"
    // rather than "emitted the same thing twice".
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\once 1 | tally | write plane.fires
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.tally1.out.out").?);
    for ([_]u64{ 1_000_000_000, 2_000_000_000, 5_000_000_000 }) |ns| {
        try fx.rt.tick(.{ .time_ns = ns });
    }
    // Still zero further arrivals: the literal was written once, at mount, and
    // nothing ever marked the node again.
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.tally1.out.out").?);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, "programs.p.once1.out.out").?);
}

test "beat 4a: fade the exposure in over 2s on mount — one line, and it ticks" {
    // §4's row, which read "can't (no `once`)". It turns out not to need
    // `once` at all: `range` CLAMPS, so a clock scaled into 0..1 is a fade
    // that finishes and stays finished.
    //
    // The cost is real and is why the row carries a note: this chain
    // re-evaluates every frame forever, because `clock` does. The stopping
    // spelling would be `once 1 | ramp 2s`, and it does not work — `ramp`
    // baselines at its FIRST target, so it starts at 1 rather than fading to
    // it. That gap is a fork (`ramp from`), not a thing to fake here.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\clock | div 2 | range 0 1 | write plane.render.grade.exposure
    , .{});
    defer fx.deinit();

    const out = "programs.p.range1.out.out";
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, out).?);
    try fx.rt.tick(.{ .time_ns = 1_000_000_000 });
    try testing.expectEqual(@as(f64, 0.5), slotNum(&fx, out).?);
    try fx.rt.tick(.{ .time_ns = 2_000_000_000 });
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
    // Clamped, not extrapolating — the fade is over and stays over.
    try fx.rt.tick(.{ .time_ns = 9_000_000_000 });
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
}

test "beat 4a: the finding — `ramp` cannot start a mount fade, and says so by doing" {
    // Pinned as a fact rather than left as a comment: `ramp` baselines at its
    // first target, so `once 1 | ramp 2s` is a jump. If someone gives `ramp` a
    // `from` port, this gate is where the change announces itself.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\once 1 | ramp 2s | write plane.render.grade.exposure
    , .{});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, "programs.p.ramp1.out.out").?);
}

test "beat 4a: piped, `once` passes the FIRST arrival and then goes deaf" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.trigger | once | write plane.out
    , .{.{ "plane.trigger", @as(f64, 11) }});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 11), slotNum(&fx, "programs.p.once1.out.out").?);
    try feedValue(&fx.rt, testing.allocator, "plane.trigger", @as(f64, 22));
    try fx.rt.tick(.{});
    // Still the first one. A `once` that passed the latest would read 22 here,
    // which is the only way this gate can fail.
    try testing.expectEqual(@as(f64, 11), slotNum(&fx, "programs.p.once1.out.out").?);
}

test "beat 4a: toggle a light on a keypress — the row, one line" {
    // §4's row, which was ~3 lines. Emits its initial `false` at mount (the
    // level pin) and flips from the NEXT arrival on, so the value present at
    // mount is not silently eaten as the first press.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.input.key_l | toggle | write plane.lights.key.on
    , .{.{ "plane.input.key_l", true }});
    defer fx.deinit();

    const out = "programs.p.toggle1.out.out";
    try testing.expect(!types.asBool(fx.rt.readSlot(out).?).?);
    for ([_]bool{ true, false, true }) |expect_on| {
        try feedOcc(&fx.rt, testing.allocator, "plane.input.key_l");
        try fx.rt.tick(.{});
        try testing.expectEqual(expect_on, types.asBool(fx.rt.readSlot(out).?).?);
    }
}

test "beat 4a: count kills — the row, one line, and it starts at 0" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.events.kill | tally | write plane.ui.kills
    , .{.{ "plane.events.kill", true }});
    defer fx.deinit();

    const out = "programs.p.tally1.out.out";
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, out).?);
    for ([_]f64{ 1, 2, 3 }) |n| {
        try feedOcc(&fx.rt, testing.allocator, "plane.events.kill");
        try fx.rt.tick(.{});
        try testing.expectEqual(n, slotNum(&fx, out).?);
    }
}

test "beat 4a: `tally` survives RESTORE and not REMOUNT" {
    // The pin, and the distinction it rests on: restoring is resuming a
    // program, remounting is starting one. The count lives in node state, so
    // both answers fall out rather than being enforced anywhere.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.events.kill | tally | write plane.ui.kills
    , .{.{ "plane.events.kill", true }});
    defer fx.deinit();
    for (0..3) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.events.kill");
        try fx.rt.tick(.{});
    }
    try testing.expectEqual(@as(f64, 3), slotNum(&fx, "programs.p.tally1.out.out").?);

    const dumped = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(dumped);

    // Restore: resumed, so the count came with it.
    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, dumped);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.restoreState(&rt2, dumped);
    try testing.expectEqual(@as(f64, 3), types.asNumber(rt2.readSlot("programs.p.tally1.out.out").?).?);

    // Remount: restarted, so it is 0 again.
    var fx3: Fixture = undefined;
    try mountFixture(testing.allocator, &fx3,
        \\plane.events.kill | tally | write plane.ui.kills
    , .{.{ "plane.events.kill", true }});
    defer fx3.deinit();
    try testing.expectEqual(@as(f64, 0), slotNum(&fx3, "programs.p.tally1.out.out").?);
}

/// The ```rill block that follows `heading` in a manual. Gates that assert a
/// recipe's CORRECTNESS drive the manual's own text through this, rather than
/// their own copy of it — because the manual gate only ever proved the
/// examples PARSE, and a recipe can parse and still be backwards. It was, for
/// the flagship threshold recipe, until a reader trying to use it said so.
fn manualRecipe(heading: []const u8) []const u8 {
    const doc = @embedFile("rill-manual.md");
    const at = std.mem.indexOf(u8, doc, heading) orelse @panic("manual heading not found");
    const rest = doc[at..];
    const open = std.mem.indexOf(u8, rest, "```rill\n") orelse @panic("no rill block after the heading");
    const body = rest[open + "```rill\n".len ..];
    const close = std.mem.indexOf(u8, body, "```") orelse @panic("unterminated block after the heading");
    return body[0..close];
}

// ---------------------------------------------------------------------------
// Driving the BOOK's own text (envelopes item 3 phase 2, ruled 2026-08-26).
//
// Chris's order: identity gate → after-cell correctness → before cells. This
// is the middle one, and it is *the inverted flagship's actual lesson*: a gate
// that watches the operator is not watching the row. `[{armed: false},
// {armed: true}] | map (.armed) | reduce (or)` proves `reduce` folds. It does
// not prove that the book's page called "is any contact armed" says `or` and
// not `and` — and swapping those leaves the cell parsing perfectly.
//
// So these gates take the book's OWN source by name and assert what the ROW
// claims. One assertion each, in the row's words, and no timeline longer than
// it takes to show the claim.
//
// Scope, and why it is not all forty after-cells: the identity gate above
// pins 29 statements identical between the manual and the book, so a gate
// driving the manual's text is already driving the book's. What is left is
// the cells with no behaviour gate anywhere, and among those the ones whose
// claim is a SENSE — a direction, an ordering, a which-one — because sense is
// what parsing cannot see and what the flagship got wrong.
// ---------------------------------------------------------------------------

/// The book's own text for a named cell. `manualRecipe(heading)`, one file
/// over: a gate that drives this cannot be asserting something the book does
/// not say. Slices live as long as `arena`.
fn bookCell(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(BookDoc, arena, @embedFile("idioms.rillbook"), .{ .ignore_unknown_fields = true });
    for (parsed.value.cells) |c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        if (c.markdown) {
            std.debug.print("book cell '{s}' is markdown — there is no program to drive\n", .{name});
            return error.TestUnexpectedResult;
        }
        return c.source;
    }
    std.debug.print("there is no book cell named '{s}'\n", .{name});
    return error.TestUnexpectedResult;
}

test "the book's own text: `nth 0` is the OLDEST reading, `last` is the newest" {
    // The perfect pair for this lesson: two cells a page apart, and swapping
    // them leaves both parsing. Driven together over ONE window so the gate
    // cannot agree with a swap — they must disagree, in the right direction.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = try std.fmt.allocPrint(arena, "{s}\n{s}", .{
        try bookCell(arena, "array-oldest"),
        try bookCell(arena, "most-recent-after"),
    });

    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, src, .{.{ "plane.gpu.traversal_ms", @as(f64, 7) }});
    defer fx.deinit();
    for ([_]f64{ 3, 9 }, [_]u64{ 1, 2 }) |v, t| {
        try feedValue(&fx.rt, testing.allocator, "plane.gpu.traversal_ms", v);
        try fx.rt.tick(.{ .time_ns = t * sec });
    }
    const oldest = types.asNumber(fx.rt.readSlot("programs.p.nth1.out.out").?).?;
    const newest = types.asNumber(fx.rt.readSlot("programs.p.last1.out.out").?).?;
    try testing.expect(oldest != newest); // "A rather than B", where A ≠ B
    try testing.expectEqual(@as(f64, 7), oldest);
    try testing.expectEqual(@as(f64, 9), newest);
}

test "the book's own text: the loudest recent reading is the MAX, and any-armed is OR" {
    // Two folds whose row is a superlative. `reduce (min)` and `reduce (and)`
    // both parse and both fold; only the row says which way round.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "loudest-recent"), .{.{ "plane.gpu.traversal_ms", @as(f64, 4) }});
    defer fx.deinit();
    for ([_]f64{ 11, 6 }, [_]u64{ 1, 2 }) |v, t| {
        try feedValue(&fx.rt, testing.allocator, "plane.gpu.traversal_ms", v);
        try fx.rt.tick(.{ .time_ns = t * sec });
    }
    // The peak is 11 — and it is neither the last reading nor the first, so
    // neither "hold the newest" nor "hold the oldest" passes this.
    try testing.expectEqual(@as(f64, 11), types.asNumber(fx.rt.readSlot("programs.p.reduce1.out.out").?).?);

    // `any armed` over one armed contact among unarmed ones: `or` says true,
    // `and` says false, and the row is called "is ANY contact armed".
    var fx2: Fixture = undefined;
    try mountFixture(testing.allocator, &fx2, try bookCell(arena, "any-armed"), .{.{
        "plane.sensors.gate.contacts",
        [_]struct { armed: bool }{ .{ .armed = false }, .{ .armed = true }, .{ .armed = false } },
    }});
    defer fx2.deinit();
    try testing.expect(types.asBool(fx2.rt.readSlot("programs.p.reduce1.out.out").?).?);
}

test "the book's own text: `range` CLAMPS, which is the whole point of that page" {
    // The cell exists to say `range` is not `lerp`. Its own note says the
    // modulation chain stays inside the interval you named — so the gate
    // drives the shaped source past 1 and asserts the exposure did not leave
    // 0.5..1.5. Nothing about this is visible to a parser.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "range-exit"), .{});
    defer fx.deinit();
    var t: u64 = 0;
    while (t <= 8 * sec) : (t += sec / 8) {
        try fx.rt.tick(.{ .time_ns = t });
        const v = types.asNumber(fx.rt.readSlot("programs.p.range1.out.out").?).?;
        try testing.expect(v >= 0.5 and v <= 1.5);
    }
}

test "the book's own text: the charge rises while held and STOPS at its clamp" {
    // The row is "charge a mechanism while a lever is held, CAPPED". Both
    // halves, and the cap is the half a parser cannot see.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "charge-after"), .{.{ "plane.keep.lever.held", @as(f64, 1) }});
    defer fx.deinit();
    const out = "programs.p.integrate1.out.out";

    try fx.rt.tick(.{ .time_ns = 10 * sec });
    const mid = types.asNumber(fx.rt.readSlot(out).?).?;
    try testing.expect(mid > 0 and mid < 100); // it is rising, and not there yet
    try fx.rt.tick(.{ .time_ns = 500 * sec });
    try testing.expectEqual(@as(f64, 100), types.asNumber(fx.rt.readSlot(out).?).?); // capped, exactly
}

test "the book's own text: the eased target MOVES TOWARD it, and settles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "ease-toward-after"), .{.{ "plane.render.grade.exposure_target", @as(f64, 1) }});
    defer fx.deinit();
    const out = "programs.p.ease1.out.out";
    try testing.expectEqual(@as(f64, 1), types.asNumber(fx.rt.readSlot(out).?).?); // mounts AT the reading

    try feedValue(&fx.rt, testing.allocator, "plane.render.grade.exposure_target", @as(f64, 2));
    try fx.rt.tick(.{ .time_ns = 100 * ms });
    const part = types.asNumber(fx.rt.readSlot(out).?).?;
    try testing.expect(part > 1 and part < 2); // toward, and not yet arrived
    try fx.rt.tick(.{ .time_ns = 5 * sec });
    try testing.expectApproxEqAbs(@as(f64, 2), types.asNumber(fx.rt.readSlot(out).?).?, 1e-3);
}

test "the book's own text: the camera cycle RETURNS to its first position" {
    // The row that argues for the modes composing. `loop` is the claim, and a
    // cell that ran once and stopped would look identical for three presses.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "camera-cycle-after"), .{.{ "plane.input.key_up", true }});
    defer fx.deinit();
    const out = "programs.p.step1.out.out";

    const first = try fieldValue(testing.allocator, fx.rt.readSlot(out).?, "x");
    defer testing.allocator.free(first);
    try testing.expectEqual(@as(f64, 0), types.asNumber(first).?);
    for (0..3) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.input.key_up");
        try fx.rt.tick(.{});
    }
    // Three presses over three positions is back at the start.
    const again = try fieldValue(testing.allocator, fx.rt.readSlot(out).?, "x");
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(f64, 0), types.asNumber(again).?);
}

test "the book's own text: the leg picks ITS point, not the first one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "three-points-partial"), .{.{ "plane.stage.leg", @as(f64, 1) }});
    defer fx.deinit();
    const x = try fieldValue(testing.allocator, fx.rt.readSlot("programs.p.choose1.out.out").?, "x");
    defer testing.allocator.free(x);
    try testing.expectEqual(@as(f64, 2), types.asNumber(x).?);
}

// ---------------------------------------------------------------------------
// The BEFORE cells, gated on their badness (recon phase 3, ruled 2026-08-26).
//
// Chris: *"An argument nothing runs is prose."* The before cells are the
// campaign's whole case for admitting a word — this is what the ask cost
// without it — and until now they were the only part of the book that was
// pure assertion. A before cell that quietly stopped being bad would mean the
// row no longer needs its word, and nobody would know.
//
// And the bill is narrowed, on his instruction: **one assertion each, of the
// badness the row itself claims, in the row's own words, and no timeline
// longer than it takes to show the claim.** Not a faithful reproduction of
// every awkwardness — the claim, executed.
//
// The pass paid for itself before it was written: two of the book's notes
// claimed a badness that is not there. Both said `ease` "never quite reaches
// zero, so it costs a frame forever". `ease` STOPS — `converged()` at ε, and
// it does not arm another tick. Corrected in the book, and what replaced one
// of them is considerably worse than what it claimed.
// ---------------------------------------------------------------------------

/// How many writes the program has made to `path`.
fn writesTo(fx: *Fixture, path: []const u8) usize {
    var n: usize = 0;
    for (fx.mock.writes.items) |w| {
        if (std.mem.eql(u8, w.path, path)) n += 1;
    }
    return n;
}

test "the book's BEFORE: night-falls fires on every crossing — it chatters" {
    // The row's own claim: *"a light level wobbling either side of the
    // threshold at dusk switches the lights on and off repeatedly."* Counted,
    // over the same dusk wobble the after cell is driven through.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "night-falls-before"), .{.{ "plane.sensors.sky.light", @as(f64, 0.5) }});
    defer fx.deinit();

    const before_wobble = writesTo(&fx, "plane.lights.court.on");
    for ([_]f64{ 0.29, 0.31, 0.28, 0.32, 0.27, 0.31 }) |v| {
        try feedValue(&fx.rt, testing.allocator, "plane.sensors.sky.light", v);
        try fx.rt.tick(.{});
    }
    // Three downward crossings, three writes. The after cell holds still.
    try testing.expectEqual(@as(usize, 3), writesTo(&fx, "plane.lights.court.on") - before_wobble);
}

test "the book's BEFORE: the flash rises and NEVER COMES DOWN" {
    // What this cell's note used to claim was a tail that costs a frame
    // forever. It is worse than that. Nothing ever lowers `hit_gate` — a rill
    // may not write a path it also subscribes to, which is why the workaround
    // is two programs, and the second program has no way to put the gate back
    // down. So `ease` chases a 1 that never leaves, and the light stays on.
    //
    // One assertion: a long time after the hit, the flash is still at full.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "flash-on-hit-before-2"), .{.{ "plane.ui.hit_gate", @as(f64, 1) }});
    defer fx.deinit();
    try fx.rt.tick(.{ .time_ns = 30 * sec });
    try testing.expectApproxEqAbs(@as(f64, 1), types.asNumber(fx.rt.readSlot("programs.p.ease1.out.out").?).?, 1e-3);
}

test "the book's BEFORE: the arpeggio counter GROWS, unbounded, on the plane" {
    // Chris named this one: *"arpeggio asserts the plane path grows."* It is
    // `integrate`'s required clamp argued from the other side — an
    // accumulator living on the plane has nothing to make it stop, and it is
    // saved with the program, so it is a corpse that gets copied.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "arpeggio-before-1"), .{.{ "plane.music.beat", true }});
    defer fx.deinit();

    for (0..300) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.music.beat");
        try fx.rt.tick(.{});
    }
    // Three hundred beats, three hundred and counting — no wrap, no cap. The
    // `after` cell holds the same cursor inside the operator, where it is
    // bounded by the array and rides the dump as four small numbers.
    const held = fx.mock.store.get("plane.music.arp_i") orelse return error.TestUnexpectedResult;
    try testing.expect(types.asNumber(held).? >= 300);
}

test "the book's BEFORE: the held note goes to FULL — there is no sustain" {
    // The row's claim: one register chases one target, so "decay to a sustain
    // and then stay there" is unsayable however many words you spend. Held,
    // this cell sits at 1; the after cell sits at its 0.7.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, try bookCell(arena, "held-note-before"), .{.{ "plane.input.key_c", true }});
    defer fx.deinit();
    try fx.rt.tick(.{ .time_ns = 5 * sec });
    try testing.expectApproxEqAbs(@as(f64, 1), types.asNumber(fx.rt.readSlot("programs.p.ease1.out.out").?).?, 1e-3);
}

test "beat 4a: night falls → LIGHTS ON, and it does not chatter at dusk" {
    // The row that put a correctness column on §4, gated on BOTH of its
    // claims. The first version of this gate watched only the second one — it
    // drove the oscillation, counted flips, and named the output slot
    // `plane.lights.street.on` while asserting it was TRUE in daylight. The
    // hysteresis was right and the sense was upside down, in the manual, in
    // the recipe, in the idioms book and here. A reader trying to use the
    // recipe found it; the gate could not, because it never asked what the
    // row actually says. The row says NIGHT falls, so the lights come ON.
    // Driven from the MANUAL'S OWN TEXT, not a copy of it. Editing the recipe
    // back to its inverted form fails here, which is the whole point: the
    // manual gate proves an example parses, and parsing was never the problem.
    //
    // 2026-08-26: the recipe is now `below 0.2 0.3` and the `| not` is gone —
    // which puts the band and the strict comparator it is compared against the
    // same way up. That is worth more than the tidiness: the two streams below
    // now agree on every reading except the ones the band exists to swallow,
    // so a sense error in either would show as a disagreement rather than as
    // two mirrors both flipped.
    const recipe = manualRecipe("**The threshold that does not chatter**");
    const src = try std.fmt.allocPrint(testing.allocator, "{s}plane.world.light | < 0.3 | write plane.strict\n", .{recipe});
    defer testing.allocator.free(src);
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, src, .{.{ "plane.world.light", @as(f64, 0.5) }});
    defer fx.deinit();

    const hyst = "programs.p.below1.out.out";
    const strict = "programs.p.lt1.out.out";
    // Broad daylight: the street lights are OFF. This is the assertion the
    // first version of this gate had backwards.
    try testing.expect(!types.asBool(fx.rt.readSlot(hyst).?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot(strict).?).?);

    // Dusk, wobbling either side of 0.3 — the sensor noise that caused this.
    var flips_strict: usize = 0;
    var flips_hyst: usize = 0;
    var last_s = types.asBool(fx.rt.readSlot(strict).?).?;
    var last_h = types.asBool(fx.rt.readSlot(hyst).?).?;
    for ([_]f64{ 0.29, 0.31, 0.28, 0.32, 0.27, 0.31 }) |v| {
        try feedValue(&fx.rt, testing.allocator, "plane.world.light", v);
        try fx.rt.tick(.{});
        const s = types.asBool(fx.rt.readSlot(strict).?).?;
        const h = types.asBool(fx.rt.readSlot(hyst).?).?;
        if (s != last_s) flips_strict += 1;
        if (h != last_h) flips_hyst += 1;
        last_s = s;
        last_h = h;
    }
    // The strict comparator chattered; the hysteresis band did not move at all,
    // because nothing ever got below 0.2.
    try testing.expectEqual(@as(usize, 6), flips_strict);
    try testing.expectEqual(@as(usize, 0), flips_hyst);

    // …and night actually falling turns them ON.
    try feedValue(&fx.rt, testing.allocator, "plane.world.light", @as(f64, 0.15));
    try fx.rt.tick(.{});
    try testing.expect(types.asBool(fx.rt.readSlot(hyst).?).?);
    // …and dawn turns them off again, past the trip and not before.
    try feedValue(&fx.rt, testing.allocator, "plane.world.light", @as(f64, 0.25));
    try fx.rt.tick(.{});
    try testing.expect(types.asBool(fx.rt.readSlot(hyst).?).?); // still night, inside the band
    try feedValue(&fx.rt, testing.allocator, "plane.world.light", @as(f64, 0.35));
    try fx.rt.tick(.{});
    try testing.expect(!types.asBool(fx.rt.readSlot(hyst).?).?);
}

// ---------------------------------------------------------------------------
// Two refusals of the `sample 5` → "write it with a unit: 5s" shape, both
// found on 2026-08-26 by a reviewer with no priors writing one program from
// the agent manual. Neither was a bug in the language: both were the parser
// declining to say the thing it already knew.
// ---------------------------------------------------------------------------

test "a positional argument written as a keyword names itself, and gives the spelling" {
    // The reviewer made this mistake FOUR TIMES in one program — `kick attack
    // 100ms decay 4s`, `ease tau 2s`, `hold for 30s`, `step of […]` — and got
    // "unknown name 'attack'" every time, which sends a reader hunting for a
    // missing `as` binding.
    //
    // They were not guessing. `cast … radius <r> at <pos> decay <d>`, `take 3
    // from 1`, `integrate max 100` and `sort by (…)` all DO carry words, and
    // on adjacent lines they wrote `decay 4s` correctly (a keyword port of
    // `cast`) and `decay 4s` wrongly (a positional port of `kick`). Same word,
    // two spellings, one program. The inconsistency is the language's; the
    // silence was the parser's.
    try expectParseError("plane.a | kick attack 100ms decay 4s | write plane.b", "'attack' is an argument of 'kick'");
    try expectParseError("plane.a | kick attack 100ms decay 4s | write plane.b", "kick <attack> <decay>");
    try expectParseError("plane.a | hold for 30s | write plane.b", "'hold' takes no argument by name");

    // …and where the operator DOES take some by name, it says which — because
    // the reader's question is binary and per-operator, not a rule with
    // exceptions.
    try expectParseError("plane.a | ease tau 2s | write plane.b", "ease <tau> [up <up>] [down <down>]");
    try expectParseError("plane.a | ease tau 2s | write plane.b", "does take by name: up, down");
    try expectParseError("plane.a | take n 3 | write plane.b", "does take by name: from");

    // The spelling is rendered from the REGISTRY in §12's notation, so a
    // refusal and the operator index cannot disagree about the same operator.
    try expectParseError("noise period 40ms | write plane.b", "noise <period> [octaves <octaves>] [seed <seed>]");

    // A REQUIRED argument that DOES carry a word must show the word in the
    // spelling. Without a case here, dropping the word from that branch
    // changed nothing — `ease`'s `up`/`down` are optional and take a different
    // branch, so every example above agreed with a spelling that had stopped
    // saying which arguments are keyword. `integrate`'s clamp is the only
    // required-and-worded argument outside `cast`.
    try expectParseError("integrate in 5 | write plane.b", "max <max>");

    // …and it does not over-fire, in either direction. A word that is not one
    // of this operator's arguments is still an unknown name, which is what it
    // is — and a word that IS one but is written WITH its name must not be
    // told to drop it. Both had to be gated: "does this word name a
    // positional argument" is the whole claim, and a check that answered yes
    // for keyword arguments too passed every case above.
    try expectParseError("plane.a | mul nonsense | write plane.b", "unknown name 'nonsense'");
    try expectParseError("plane.a | mul tau | write plane.b", "unknown name 'tau'"); // `tau` is `ease`'s, not `mul`'s
    // …and a word naming an argument this operator DOES take by name is not
    // told to drop it: here `octaves` has been written as `seed`'s value, and
    // "drop the word" would be wrong advice. Gated because a check that
    // answered yes for keyword arguments too passed every other case above.
    try expectParseError("noise 40ms seed octaves | write plane.b", "unknown name 'octaves'");
}

test "the leaf-alias refusal is GONE, because a fold has no prefix rule" {
    // What this gate used to watch: `use plane.environment.ambient_light as
    // dusk` then `dusk | …` said "expected '.' after 'dusk'", because a `use`
    // alias was a path PREFIX and aliasing a LEAF produced a name that could
    // never be used. It took a dedicated refusal naming the alias and spelling
    // out the fix (found by a no-priors reader, 2026-08-26).
    //
    // `using` deletes the class rather than the message: a fold is tokens, and
    // tokens that happen to be a whole path are a whole path. The gate is now
    // that both spellings WORK — leaf and namespace, same rule, no rule.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\using plane.environment.ambient_light as :dusk
        \\using plane.environment as :env
        \\:dusk | < 0.15 | write plane.dark
        \\:env.ambient_light | < 0.05 | write plane.pitch
    , .{.{ "plane.environment.ambient_light", @as(f64, 0.1) }});
    defer fx.deinit();
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.lt1.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.lt2.out.out").?).?);

    // …and `plane` itself keeps the plain message, which is now the ONLY
    // message this site emits: there is no alias case left to disambiguate.
    try expectParseError("plane | write plane.b", "expected '.' after 'plane'");
}

test "the wire gate: a container only reaches a port that says it broadcasts" {
    // Beat 1b widened `accepts` globally so `mul {x: 1}` would wire, and that
    // quietly removed wire-time typing from EVERY number port in the language.
    // A manual example shipped piping an array into `choose`'s index; it
    // parsed, and refused three seconds into the animation instead. Opt-in per
    // port puts the error back where the wire gate can see it.
    try expectParseError("[1, 2] | choose plane.i | write plane.out", "expected number, got array");
    try expectParseError("plane.v | above [1] 0.2 | write plane.out", "expected number, got array");
    try expectParseError("plane.xs | take [3] | write plane.out", "expected number, got array");

    // …and the elementwise operators are unchanged: that is the whole reason
    // the widening existed, so both halves run here.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 2, 3] | mul 2 | write plane.a
        \\plane.pos | add {x: 0, y: 2, z: 0} | write plane.b
        \\[true, false] | not | write plane.c
    , .{.{ "plane.pos", .{ .x = @as(f64, 1), .y = @as(f64, 1), .z = @as(f64, 1) } }});
    defer fx.deinit();
    const c = try arrayBools(testing.allocator, fx.rt.readSlot("programs.p.not1.out.out").?);
    defer testing.allocator.free(c);
    try testing.expectEqualSlices(bool, &.{ false, true }, c);
}

// ---------------------------------------------------------------------------
// The typing gate (envelopes campaign item 1, ruled 2026-08-26).
//
// The wire gate above is three examples. This is the coverage surface behind
// them. Beat 1b widened `types.accepts` GLOBALLY so `mul {x: 1}` would wire,
// and in doing so removed wire-time typing from every `number` port in the
// language — `choose`'s index, `take`'s count, `above`'s thresholds, `within`'s
// radius all began taking an array and refusing three seconds into the
// animation instead. No test noticed. What noticed was a reader with no priors
// working through a printed example that parsed and could never run.
//
// So: every port of every core operator, and what its declaration says reaches
// it. Both halves, both ways, like the class/ticks/fails_mount audits:
//
//   (a) the accept set is stated below as a TABLE — for each declared port
//       type, the value types that reach it — and NOT as an algorithm. This is
//       the point of the whole gate. A test that restates the implementation's
//       branches in the implementation's order agrees with a wrong
//       implementation for exactly the reason it was wrong; beat 1b's widening
//       was one `if`, and an `if`-shaped expectation would have been widened
//       with it in the same edit.
//   (b) every port that broadcasts is NAMED, and every port named broadcasts.
//       Opt-in is the ruling, and opt-in dies quietly the moment a default
//       flips. 27 operators, 41 ports, all of them elementwise arithmetic.
//
// The limitation, written down rather than papered over: a port bound from a
// **pipe** is `any` at wire time, because a path has no declared type. Wire
// typing therefore bites on literals and on typed wires, and a piped path is
// still the eval-time mismatch check's business. That is *why* (b) matters —
// the literal is all the wire gate ever gets, and the literal is what beat 1b
// took away.
// ---------------------------------------------------------------------------

/// Every core port that is elementwise. Named, so that `broadcasts` cannot
/// spread by a helper being reached for: `p.bc` is four characters more than
/// `p.in` and nothing but this list makes the difference visible.
const broadcasting_ports = [_]struct { op: []const u8, ports: []const []const u8 }{
    // booleans — the conjunction idiom broadcasts over a record of flags
    .{ .op = "and", .ports = &.{ "a", "b" } },
    .{ .op = "or", .ports = &.{ "a", "b" } },
    .{ .op = "not", .ports = &.{"a"} },
    // binary arithmetic — `@player.pos | add {x: 0, y: 2, z: 0}`
    .{ .op = "add", .ports = &.{ "a", "b" } },
    .{ .op = "sub", .ports = &.{ "a", "b" } },
    .{ .op = "mul", .ports = &.{ "a", "b" } },
    .{ .op = "div", .ports = &.{ "a", "b" } },
    .{ .op = "min", .ports = &.{ "a", "b" } },
    .{ .op = "max", .ports = &.{ "a", "b" } },
    .{ .op = "pow", .ports = &.{ "a", "b" } },
    .{ .op = "mod", .ports = &.{ "a", "b" } },
    // unary arithmetic
    .{ .op = "abs", .ports = &.{"in"} },
    .{ .op = "floor", .ports = &.{"in"} },
    .{ .op = "ceil", .ports = &.{"in"} },
    .{ .op = "round", .ports = &.{"in"} },
    .{ .op = "sign", .ports = &.{"in"} },
    .{ .op = "fract", .ports = &.{"in"} },
    .{ .op = "sqrt", .ports = &.{"in"} },
    .{ .op = "exp", .ports = &.{"in"} },
    .{ .op = "log", .ports = &.{"in"} },
    .{ .op = "sin", .ports = &.{"in"} },
    .{ .op = "cos", .ports = &.{"in"} },
    .{ .op = "tan", .ports = &.{"in"} },
    // comparators. `=` and `!=` are NOT here and that is deliberate: they take
    // `any` on both sides and compare whole encoded values, so a record
    // reaches them by the wildcard and is compared, not broadcast over.
    .{ .op = "<", .ports = &.{ "a", "b" } },
    .{ .op = "<=", .ports = &.{ "a", "b" } },
    .{ .op = ">", .ports = &.{ "a", "b" } },
    .{ .op = ">=", .ports = &.{ "a", "b" } },
};

// ---------------------------------------------------------------------------
// The wordless-optional roster (ruled 2026-08-26, after the keyword audit).
//
// **The rule: a word marks an argument that could otherwise be mistaken for
// another.** Ambiguity is the subject; optionality is only its usual cause.
// Three situations, all named, none of them exceptions any more:
//
//   • `set plane.a 1` — one optional slot, and a path token is not a literal,
//     so there is nothing to mistake it for and no word is needed.
//   • `cast … radius <r> at <pos>` and `integrate … max <m>` — three numbers
//     in a row, and a bare clamp that would read as a rate. Both carry words
//     because both COULD be mistaken, required or not.
//   • `arm <in> <off> <on>` — three wordless optionals, where `arm gate_closed`
//     bound `in` and nothing announced it. That was a BUG, not an exception,
//     and it is now `arm [<in>] [off <off>] [on <on>]`.
//
// `Registry.register` refuses two adjacent wordless optionals outright, so the
// next `arm` cannot be registered — by this repo or by a host. This roster is
// the other half: the population that remains, named, both ways.
//
// The ledger line the audit bought (Chris, 2026-08-26): **a search for
// exceptions to a rule finds the operators that half-follow it, not the ones
// that ignore it entirely — audit the whole population, not the mixed cases.**
// `arm` and `disarm` were never among the twelve "mixed" operators the probe
// pointed at, because they have no keyword argument at all.
// ---------------------------------------------------------------------------

/// Every core port that is optional and carries NO word. Each is here because
/// its operator has exactly one, so nothing can be mistaken for anything.
const wordless_optionals = [_]struct { op: []const u8, port: []const u8, why: []const u8 }{
    .{ .op = "write", .port = "value", .why = "the sink payload — one slot, and the path is a path; the mode words are flags, which the rule exempts" },
    .{ .op = "notify", .port = "value", .why = "same shape as `set`" },
    .{ .op = "cast", .port = "value", .why = "same shape; `cast`'s numbers all carry words" },
    .{ .op = "arm", .port = "in", .why = "the piped stream; the two controls now carry words" },
    .{ .op = "disarm", .port = "in", .why = "the piped stream; the two controls now carry words" },
    .{ .op = "expect", .port = "in", .why = "the piped stream, and the shape is a static" },
};

/// At most ONE wordless optional port per operator. `register` refuses two
/// ADJACENT ones; this is the half that catches `op [<a>] <b> [<c>]`, where a
/// required port sits between them and they are ambiguous all the same —
/// `op 1 2` cannot say whether it filled a and b or b and c.
fn atMostOneWordlessOptional(def: *const registry.OpDef) !usize {
    var wordless: usize = 0;
    for (def.inputs) |pt| {
        if (pt.optional and !pt.kw) wordless += 1;
    }
    if (wordless > 1) {
        std.debug.print("'{s}' has {d} wordless optional ports — one of them could be mistaken for another\n", .{ def.name, wordless });
        return error.TestUnexpectedResult;
    }
    return wordless;
}

test "the ambiguity rule: every wordless optional port is named, and only those are" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    var found: usize = 0;
    for (reg.ops.items) |def| {
        found += try atMostOneWordlessOptional(&def);
        for (def.inputs) |pt| {
            if (!pt.optional or pt.kw) continue;
            const listed = for (wordless_optionals) |e| {
                if (std.mem.eql(u8, e.op, def.name) and std.mem.eql(u8, e.port, pt.name)) break true;
            } else false;
            if (!listed) {
                std.debug.print("'{s}' port '{s}' is optional and carries no word, and is not on the roster\n", .{ def.name, pt.name });
                return error.TestUnexpectedResult;
            }
        }
    }

    // …and the at-most-one check is WITNESSED where it differs, because the
    // corpus can no longer differ: after the respelling no operator has two,
    // so loosening the check changed nothing and the mutation survived. The
    // discriminating case is the one `register` deliberately lets through —
    // two wordless optionals with a required port between them.
    const separated = registry.OpDef{
        .name = "separated",
        .inputs = &.{
            .{ .name = "a", .optional = true },
            .{ .name = "b" },
            .{ .name = "c", .optional = true },
        },
        .outputs = &.{.{ .name = "out" }},
        .routes = .anywhere,
        .help = "adjacent-free, ambiguous anyway",
        .eval = undefined,
    };
    _ = try reg.register(separated); // `register` allows it: they are not adjacent
    try testing.expectError(error.TestUnexpectedResult, atMostOneWordlessOptional(&separated));
    try testing.expectEqual(@as(usize, 1), try atMostOneWordlessOptional(reg.get(reg.find("write").?)));
    // Both ways: the audit counted seven wordless optionals excluding the
    // piped port 0, three of which were sink payloads. The prediction was that
    // the other four were exactly `arm`/`disarm`'s controls. This is the walk
    // saying so rather than the count implying it.
    try testing.expectEqual(wordless_optionals.len, found);
    for (wordless_optionals) |e| {
        const id = reg.find(e.op) orelse {
            std.debug.print("'{s}' is on the wordless-optional roster and is not registered\n", .{e.op});
            return error.TestUnexpectedResult;
        };
        _ = id;
    }
}

test "the ambiguity rule is STRUCTURAL: two adjacent wordless optionals are refused" {
    // Not watched for — refused, at registration, so a host cannot do it
    // either. This is the mechanical form of "could be mistaken for another".
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    const bad = registry.OpDef{
        .name = "gate_like_arm",
        .inputs = &.{
            .{ .name = "in", .optional = true },
            .{ .name = "off", .optional = true },
            .{ .name = "on", .optional = true },
        },
        .outputs = &.{.{ .name = "out" }},
        .routes = .anywhere,
        .help = "the shape `arm` used to have",
        .eval = undefined,
    };
    try testing.expectError(error.AmbiguousOptionals, reg.register(bad));

    // …and the fix registers cleanly: a word on each control.
    const good = registry.OpDef{
        .name = "gate_like_arm",
        .inputs = &.{
            .{ .name = "in", .optional = true },
            .{ .name = "off", .optional = true, .kw = true },
            .{ .name = "on", .optional = true, .kw = true },
        },
        .outputs = &.{.{ .name = "out" }},
        .routes = .anywhere,
        .help = "the shape `arm` has now",
        .eval = undefined,
    };
    _ = try reg.register(good);

    // One wordless optional is fine — that is `set plane.a 1`, and the rule
    // is about ambiguity, not about optionality. "A rather than B", where the
    // two differ by exactly the thing the rule names.
    const sink_like = registry.OpDef{
        .name = "sink_like_set",
        .inputs = &.{ .{ .name = "in" }, .{ .name = "value", .optional = true } },
        .outputs = &.{},
        .routes = .main,
        .help = "the shape `set` has",
        .eval = undefined,
    };
    _ = try reg.register(sink_like);
}

test "`arm`'s controls carry their words, and either may be given alone" {
    // The respelling, driven. Before this, `arm plane.stop` bound `in`.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.e | arm off plane.stop | tap only_off
        \\plane.e | arm on plane.go | tap only_on
        \\plane.e | arm off: plane.stop on: plane.go | tap both
    , .{ .{ "plane.e", true }, .{ "plane.stop", true }, .{ "plane.go", true } });
    defer fx.deinit();
    try testing.expect(nodeIdOf(&fx.prog, "arm1") != null);
    try testing.expect(nodeIdOf(&fx.prog, "arm3") != null);

    // …and the old wordless spelling no longer binds a control by accident.
    try expectParseError("plane.e | arm plane.stop plane.go | tap t", "too many arguments");
}

test "the typing gate: the accept set of a port is its declared type's, stated" {
    const T = types.Tag;
    // Every type a wire can carry that is not a host type.
    const universe = [_]types.TypeId{ T.any, T.number, T.boolean, T.string, T.record, T.bytes, T.array, T.duration };

    const Row = struct { port: types.TypeId, broadcasts: bool, takes: []const types.TypeId };
    const table = [_]Row{
        // `any` is the wildcard on the port side; broadcast must not touch it.
        .{ .port = T.any, .broadcasts = false, .takes = &.{ T.any, T.number, T.boolean, T.string, T.record, T.bytes, T.array, T.duration } },
        .{ .port = T.any, .broadcasts = true, .takes = &.{ T.any, T.number, T.boolean, T.string, T.record, T.bytes, T.array, T.duration } },
        // the two elementwise types: containers reach them ONLY when declared
        .{ .port = T.number, .broadcasts = false, .takes = &.{ T.any, T.number } },
        .{ .port = T.number, .broadcasts = true, .takes = &.{ T.any, T.number, T.record, T.array } },
        .{ .port = T.boolean, .broadcasts = false, .takes = &.{ T.any, T.boolean } },
        .{ .port = T.boolean, .broadcasts = true, .takes = &.{ T.any, T.boolean, T.record, T.array } },
        // …and nothing else broadcasts, whatever the flag says. A `string`
        // port that somehow acquired the flag still takes a string, because
        // there is no elementwise meaning to give it.
        .{ .port = T.string, .broadcasts = false, .takes = &.{ T.any, T.string } },
        .{ .port = T.string, .broadcasts = true, .takes = &.{ T.any, T.string } },
        .{ .port = T.record, .broadcasts = false, .takes = &.{ T.any, T.record } },
        .{ .port = T.record, .broadcasts = true, .takes = &.{ T.any, T.record } },
        .{ .port = T.bytes, .broadcasts = false, .takes = &.{ T.any, T.bytes } },
        .{ .port = T.bytes, .broadcasts = true, .takes = &.{ T.any, T.bytes } },
        .{ .port = T.array, .broadcasts = false, .takes = &.{ T.any, T.array } },
        .{ .port = T.array, .broadcasts = true, .takes = &.{ T.any, T.array } },
        .{ .port = T.duration, .broadcasts = false, .takes = &.{ T.any, T.duration } },
        .{ .port = T.duration, .broadcasts = true, .takes = &.{ T.any, T.duration } },
    };
    // Exhaustive on the port side too: a new built-in type must be given its
    // row here, in both flavours, before it can be declared on a port.
    try testing.expectEqual(universe.len * 2, table.len);

    for (table) |row| {
        for (universe) |val| {
            const want = for (row.takes) |t| {
                if (t == val) break true;
            } else false;
            const got = types.acceptsPort(row.port, val, row.broadcasts);
            if (got != want) {
                std.debug.print("port {s}{s}: value {s} — the table says {}, acceptsPort says {}\n", .{
                    typeName(row.port), if (row.broadcasts) " (broadcasts)" else "", typeName(val), want, got,
                });
                return error.TestUnexpectedResult;
            }
        }
    }

    // A HOST type is not in the universe and cannot be: the table is minted at
    // registration. It reaches `any` and itself, and broadcast never invents a
    // meaning for it — `mesh` is not a container, whatever the port says.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    const mesh = try reg.types.intern("mesh");
    try testing.expect(types.acceptsPort(T.any, mesh, false));
    try testing.expect(types.acceptsPort(mesh, mesh, false));
    try testing.expect(!types.acceptsPort(T.number, mesh, false));
    try testing.expect(!types.acceptsPort(T.number, mesh, true));
    try testing.expect(!types.acceptsPort(mesh, T.array, true));
}

/// Names for the eight built-ins, spelled here rather than read from a live
/// `TypeTable`, so the failure message of a typing gate does not depend on the
/// thing being typed.
fn typeName(id: types.TypeId) []const u8 {
    return switch (id) {
        types.Tag.any => "any",
        types.Tag.number => "number",
        types.Tag.boolean => "boolean",
        types.Tag.string => "string",
        types.Tag.record => "record",
        types.Tag.bytes => "bytes",
        types.Tag.array => "array",
        types.Tag.duration => "duration",
        else => "host",
    };
}

test "the typing gate: every elementwise port is named, and only those are" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    var listed_ports: usize = 0;
    var declared_ports: usize = 0;

    for (reg.ops.items) |def| {
        const row: ?[]const []const u8 = for (broadcasting_ports) |e| {
            if (std.mem.eql(u8, e.op, def.name)) break e.ports;
        } else null;
        if (row) |names| listed_ports += names.len;

        for (def.inputs) |port| {
            const listed = if (row) |names| for (names) |n| {
                if (std.mem.eql(u8, n, port.name)) break true;
            } else false else false;
            if (port.broadcasts) declared_ports += 1;
            if (port.broadcasts != listed) {
                std.debug.print("'{s}' port '{s}': declares broadcasts={}, the roster says {}\n", .{ def.name, port.name, port.broadcasts, listed });
                return error.TestUnexpectedResult;
            }
            // Structural, needing no roster: broadcast means "elementwise over
            // a container", and only `number` and `boolean` have an
            // elementwise meaning. A flag anywhere else is a typo that would
            // otherwise do nothing and look deliberate.
            if (port.broadcasts and port.ty != types.Tag.number and port.ty != types.Tag.boolean) {
                std.debug.print("'{s}' port '{s}' broadcasts and is {s}\n", .{ def.name, port.name, typeName(port.ty) });
                return error.TestUnexpectedResult;
            }
        }
        // An OUTPUT never broadcasts: the flag is a statement about what may
        // arrive, and nothing arrives at an output.
        for (def.outputs) |port| {
            if (port.broadcasts) {
                std.debug.print("'{s}' output '{s}' declares broadcasts\n", .{ def.name, port.name });
                return error.TestUnexpectedResult;
            }
        }
    }

    // Both ways: every name on the roster found a port. A renamed port would
    // otherwise take its own entry out of service and leave the entry looking
    // like coverage.
    if (listed_ports != declared_ports) {
        std.debug.print("the roster names {d} elementwise ports, the registry declares {d}\n", .{ listed_ports, declared_ports });
        return error.TestUnexpectedResult;
    }
    for (broadcasting_ports) |e| {
        if (reg.find(e.op) == null) {
            std.debug.print("'{s}' is on the elementwise roster and is not registered\n", .{e.op});
            return error.TestUnexpectedResult;
        }
    }
}

test "the typing gate: every core port is typed from the built-in table" {
    // Core ops mint no host types — a `mesh` port is the host's to declare.
    // Said out loud because the accept-set table above is exhaustive over the
    // built-ins, and it is only exhaustive over the core registry while this
    // holds.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    for (reg.ops.items) |def| {
        for (def.inputs) |port| {
            if (port.ty > types.Tag.duration) {
                std.debug.print("'{s}' port '{s}' is a host type\n", .{ def.name, port.name });
                return error.TestUnexpectedResult;
            }
        }
        for (def.outputs) |port| {
            if (port.ty > types.Tag.duration) {
                std.debug.print("'{s}' output '{s}' is a host type\n", .{ def.name, port.name });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "beat 4a: `above` emits its LEVEL at mount, both ways" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hi | above 0.3 0.2 | write plane.a
        \\plane.lo | above 0.3 0.2 | write plane.b
    , .{ .{ "plane.hi", @as(f64, 0.9) }, .{ "plane.lo", @as(f64, 0.1) } });
    defer fx.deinit();

    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.above1.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.above2.out.out").?).?);
}

// ---------------------------------------------------------------------------
// Envelopes — `kick` (envelopes campaign item 6, 2026-08-26)
// ---------------------------------------------------------------------------

/// Read the envelope's level after advancing fed time to `ns`.
fn kickAt(fx: *Fixture, ns: u64, slot: []const u8) !f64 {
    try fx.rt.tick(.{ .time_ns = ns });
    return types.asNumber(fx.rt.readSlot(slot).?).?;
}

test "`kick`: an occurrence in, a one-shot out — up over attack, down over decay, stopped" {
    // The re-probe's biggest finding, and it cost them two programs, an
    // invented gate path on the plane and a 60ms magic number whose only job
    // was giving `ease` something to fall from.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.events.hit | kick 100ms 400ms | write plane.ui.flash
    , .{.{ "plane.events.hit", true }});
    defer fx.deinit();
    const out = "programs.p.kick1.out.out";

    // The seeded path is an arrival at mount, so the attack starts at t = 0 —
    // and its first sample is therefore the rest level, 0. A level publishes
    // on its first evaluation (beat 4's pin).
    try testing.expectEqual(@as(f64, 0), types.asNumber(fx.rt.readSlot(out).?).?);

    // Rising: halfway up the attack is halfway up.
    try testing.expectApproxEqAbs(@as(f64, 0.5), try kickAt(&fx, 50_000_000, out), 1e-9);
    // The peak is exactly 1 at the end of the attack, not near it.
    try testing.expectEqual(@as(f64, 1), try kickAt(&fx, 100_000_000, out));
    // Falling: a quarter through the decay is three quarters of the way up.
    try testing.expectApproxEqAbs(@as(f64, 0.75), try kickAt(&fx, 200_000_000, out), 1e-9);
    // …and it lands on exactly 0 and STOPS. `ramp`'s ruling: a fade that
    // stopped one ε short of home would be a visible band.
    try testing.expectEqual(@as(f64, 0), try kickAt(&fx, 500_000_000, out));

    // Stopped means stopped: no wake was armed, so the node does not evaluate
    // again on its own. The flag says what could cost; the counter says what
    // did, and this is the counter.
    const kid = nodeIdOf(&fx.prog, "kick1").?;
    const before = fx.rt.eval_count[kid];
    try fx.rt.tick(.{ .time_ns = 900_000_000 });
    try fx.rt.tick(.{ .time_ns = 1_500_000_000 });
    try testing.expectEqual(before, fx.rt.eval_count[kid]);
}

test "`kick`: a retrigger restarts from the CURRENT level, never from zero" {
    // Chris's pin, and the reason it is a pin: hits arriving during the fall
    // are the normal case, not the edge case. An envelope that snapped to zero
    // first would put a black frame in the middle of the flash — which is the
    // one thing the whole family exists to avoid.
    //
    // Gated where the two readings differ, which needs a partial fall: the
    // second hit lands at level 0.75, and the assertion is that the level
    // never drops below it afterwards. Restart-from-zero fails on the very
    // next tick; so does restart-from-the-peak, in the other direction.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.events.hit | kick 100ms 400ms | write plane.ui.flash
    , .{.{ "plane.events.hit", true }});
    defer fx.deinit();
    const out = "programs.p.kick1.out.out";

    _ = try kickAt(&fx, 100_000_000, out); // the peak
    const at_hit = try kickAt(&fx, 200_000_000, out); // a quarter down
    try testing.expectApproxEqAbs(@as(f64, 0.75), at_hit, 1e-9);

    try feedOcc(&fx.rt, testing.allocator, "plane.events.hit");
    try fx.rt.tick(.{ .time_ns = 200_000_001 });

    // From 0.75, over the full attack, to 1 — and never below 0.75 on the way.
    var t: u64 = 205_000_000;
    while (t <= 300_000_000) : (t += 5_000_000) {
        const v = try kickAt(&fx, t, out);
        try testing.expect(v >= at_hit - 1e-9);
    }
    try testing.expectEqual(@as(f64, 1), try kickAt(&fx, 300_000_001, out));
}

test "`kick`: a slow frame does not stretch the envelope" {
    // One tick can cross a whole short attack, and the decay then has to start
    // when the attack ENDED rather than when we noticed. Otherwise a dropped
    // frame lengthens the flash — the classic wall-clock-vs-lane bug, and the
    // reason segment starts are carried in state rather than taken from `now`.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.events.hit | kick 10ms 100ms | write plane.ui.flash
    , .{.{ "plane.events.hit", true }});
    defer fx.deinit();
    const out = "programs.p.kick1.out.out";

    // Nothing until 60ms — one very slow frame straight past the whole attack
    // and half the decay. The attack ended at 10ms, so 60ms is 50/100 through
    // the decay: exactly half.
    try testing.expectApproxEqAbs(@as(f64, 0.5), try kickAt(&fx, 60_000_000, out), 1e-9);
}

test "`kick`: one tick may cross the WHOLE envelope, and it is then finished" {
    // The segment walk is a loop, not an `if`, and this is the gate that says
    // so — added because turning it into an `if` SURVIVED. A frame long enough
    // to skip both segments produces the right VALUE either way, because a
    // finished segment clamps at its target and the decay's target is 0. What
    // differs is whether the envelope is over: with an `if` it is still in its
    // decay phase, so it arms another tick and shuts down one frame late.
    //
    // "A rather than B" again — the value cannot tell them apart, so the gate
    // asks the eval counter instead.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.events.hit | kick 10ms 100ms | write plane.ui.flash
    , .{.{ "plane.events.hit", true }});
    defer fx.deinit();
    const out = "programs.p.kick1.out.out";
    const kid = nodeIdOf(&fx.prog, "kick1").?;

    try testing.expectEqual(@as(f64, 0), try kickAt(&fx, 5_000_000_000, out));
    const after = fx.rt.eval_count[kid];
    try fx.rt.tick(.{ .time_ns = 6_000_000_000 });
    try fx.rt.tick(.{ .time_ns = 7_000_000_000 });
    try testing.expectEqual(after, fx.rt.eval_count[kid]);
}

test "`kick` refuses two time lanes, naming both ports" {
    // An envelope is two consecutive stretches of ONE timeline. `ease`'s
    // up/down are alternatives that never run together, so it does not have
    // this problem; a kick does.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.events.hit | kick 20ms 3f | write plane.ui.flash
    , .{.{ "plane.events.hit", true }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "kick", "attack", "decay", "time lanes" });
}

test "`adsr`: rise, decay to sustain, hold, release" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.input.key | adsr 100ms 200ms 0.5 400ms | write plane.audio.gain
    , .{.{ "plane.input.key", false }});
    defer fx.deinit();
    const out = "programs.p.adsr1.out.out";

    // Gate low at mount: a level publishes on its first evaluation, at rest.
    try testing.expectEqual(@as(f64, 0), types.asNumber(fx.rt.readSlot(out).?).?);

    try feedValue(&fx.rt, testing.allocator, "plane.input.key", true);
    try fx.rt.tick(.{ .time_ns = 0 });

    try testing.expectApproxEqAbs(@as(f64, 0.5), try kickAt(&fx, 50_000_000, out), 1e-9); // mid-attack
    try testing.expectEqual(@as(f64, 1), try kickAt(&fx, 100_000_000, out)); // the peak, exactly
    try testing.expectApproxEqAbs(@as(f64, 0.75), try kickAt(&fx, 200_000_000, out), 1e-9); // mid-decay
    try testing.expectEqual(@as(f64, 0.5), try kickAt(&fx, 300_000_000, out)); // the sustain, exactly

    // Held: still 0.5 a long time later.
    try testing.expectEqual(@as(f64, 0.5), try kickAt(&fx, 5_000_000_000, out));

    // …and the release runs from the sustain, not from 1.
    try feedValue(&fx.rt, testing.allocator, "plane.input.key", false);
    try fx.rt.tick(.{ .time_ns = 5_000_000_001 });
    try testing.expectApproxEqAbs(@as(f64, 0.25), try kickAt(&fx, 5_200_000_000, out), 1e-8);
    try testing.expectEqual(@as(f64, 0), try kickAt(&fx, 5_400_000_001, out));
}

test "`adsr`: a HELD SUSTAIN costs nothing — the eval counter goes flat" {
    // Chris's pin, and it is gated the only way it can be: a value that stays
    // put looks identical to one being recomputed every frame, so the
    // assertion has to be about the WORK, not the answer. The badge says what
    // could cost; the counter says what did.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.input.key | adsr 10ms 20ms 0.5 400ms | write plane.audio.gain
    , .{.{ "plane.input.key", true }});
    defer fx.deinit();
    const out = "programs.p.adsr1.out.out";
    const aid = nodeIdOf(&fx.prog, "adsr1").?;

    // Reach the sustain…
    try testing.expectEqual(@as(f64, 0.5), try kickAt(&fx, 50_000_000, out));
    const settled = fx.rt.eval_count[aid];

    // …and then a second of fed time, in frames, costs not one evaluation.
    var t: u64 = 100_000_000;
    while (t <= 1_000_000_000) : (t += 16_000_000) try fx.rt.tick(.{ .time_ns = t });
    try testing.expectEqual(settled, fx.rt.eval_count[aid]);

    // The transitions DO cost — otherwise a flat counter would prove nothing
    // more than a node that never ran. "A rather than B", where A ≠ B: the
    // SAME ticks, at the same cadence, over the same span of fed time.
    try feedValue(&fx.rt, testing.allocator, "plane.input.key", false);
    t = 1_016_000_000;
    while (t <= 1_400_000_000) : (t += 16_000_000) try fx.rt.tick(.{ .time_ns = t });
    try testing.expect(fx.rt.eval_count[aid] > settled + 20);
    try testing.expectEqual(@as(f64, 0), try kickAt(&fx, 1_420_000_001, out));
}

test "`adsr`: a release mid-attack starts from where it is, never from the peak" {
    // The family's reason for existing: no jumps. Letting go halfway up must
    // fall from halfway, not from 1 and not from the sustain.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.input.key | adsr 100ms 200ms 0.5 100ms | write plane.audio.gain
    , .{.{ "plane.input.key", true }});
    defer fx.deinit();
    const out = "programs.p.adsr1.out.out";

    const at_release = try kickAt(&fx, 40_000_000, out);
    try testing.expectApproxEqAbs(@as(f64, 0.4), at_release, 1e-9);
    try feedValue(&fx.rt, testing.allocator, "plane.input.key", false);
    try fx.rt.tick(.{ .time_ns = 40_000_001 });

    // Halfway down a 100ms release from 0.4 is 0.2 — and it never rises.
    try testing.expectApproxEqAbs(@as(f64, 0.2), try kickAt(&fx, 90_000_000, out), 1e-6);
    try testing.expectEqual(@as(f64, 0), try kickAt(&fx, 140_000_001, out));
}

test "`adsr`: a live parameter applies to the NEXT segment, never to the one in flight" {
    // Chris's pin, 2026-08-26 — the same rule `step`'s live array follows when
    // it carries its index. A release that shortened mid-fall would jump, and
    // a jump is the thing this whole family exists to avoid.
    //
    // Gated where the two readings differ: the release is 400ms, and 200ms in
    // (level 0.25) the port is changed to 40ms. Retimed, the envelope would be
    // long finished by 240ms; carried, it is exactly half way.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.input.key | adsr 10ms 10ms 0.5 plane.cfg.release | write plane.audio.gain
    , .{ .{ "plane.input.key", true }, .{ "plane.cfg.release", [2]i64{ 0, 400_000_000 } } });
    defer fx.deinit();
    const out = "programs.p.adsr1.out.out";

    try testing.expectEqual(@as(f64, 0.5), try kickAt(&fx, 30_000_000, out)); // sustained
    try feedValue(&fx.rt, testing.allocator, "plane.input.key", false);
    try fx.rt.tick(.{ .time_ns = 30_000_001 });
    try testing.expectApproxEqAbs(@as(f64, 0.25), try kickAt(&fx, 230_000_000, out), 1e-6); // half way down

    // Shorten the release to a tenth, mid-fall. The segment in flight keeps
    // the length it was given.
    try feedDuration(&fx.rt, testing.allocator, "plane.cfg.release", .{ .frames = false, .count = 40_000_000 });
    try fx.rt.tick(.{ .time_ns = 230_000_001 });
    try testing.expectApproxEqAbs(@as(f64, 0.125), try kickAt(&fx, 330_000_000, out), 1e-6);
    try testing.expect(try kickAt(&fx, 420_000_000, out) > 0);
    try testing.expectEqual(@as(f64, 0), try kickAt(&fx, 430_000_001, out));
}

test "`adsr`: the sustain LEVEL is live, and the decay in flight keeps its target" {
    // Two halves of one claim, and the second is the pin drawing its own line.
    // A live release was the argument for ports over statics; a live sustain
    // is the same argument, and it went ungated until the mutation that
    // froze it survived.
    //
    // Where they differ: `sustain` is moved twice, once during the DECAY
    // (which must not swerve — the segment in flight keeps the target it was
    // given) and once during the HOLD (which must follow, because a hold is
    // not a segment).
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.input.key | adsr 100ms 400ms plane.cfg.sustain 100ms | write plane.audio.gain
    , .{ .{ "plane.input.key", true }, .{ "plane.cfg.sustain", @as(f64, 0.5) } });
    defer fx.deinit();
    const out = "programs.p.adsr1.out.out";

    // Half way down a 400ms decay from 1 to 0.5 is 0.75.
    try testing.expectApproxEqAbs(@as(f64, 0.75), try kickAt(&fx, 300_000_000, out), 1e-9);

    // Move the target mid-decay: the segment in flight does not swerve, so at
    // three quarters it is still 0.625 and not somewhere between.
    try feedValue(&fx.rt, testing.allocator, "plane.cfg.sustain", @as(f64, 0.1));
    try fx.rt.tick(.{ .time_ns = 300_000_001 });
    try testing.expectApproxEqAbs(@as(f64, 0.625), try kickAt(&fx, 400_000_000, out), 1e-6);

    // …and at the decay's END the hold takes over and reads the port, so the
    // level steps from the target the segment was given to the one that is
    // there now. That step is the pin read literally and it is the ONLY place
    // the two readings differ: the segment in flight is never redirected, and
    // what follows it is never stale. Gated, rather than left as a surprise.
    try testing.expectEqual(@as(f64, 0.1), try kickAt(&fx, 500_000_000, out));

    // A hold follows its port for as long as it is held.
    try feedValue(&fx.rt, testing.allocator, "plane.cfg.sustain", @as(f64, 0.2));
    try fx.rt.tick(.{ .time_ns = 500_000_001 });

    try testing.expectEqual(@as(f64, 0.2), types.asNumber(fx.rt.readSlot(out).?).?);
    try testing.expectEqual(@as(f64, 0.2), try kickAt(&fx, 900_000_000, out));

    // …and the release then falls from where it actually is, 0.2.
    try feedValue(&fx.rt, testing.allocator, "plane.input.key", false);
    try fx.rt.tick(.{ .time_ns = 900_000_001 });
    try testing.expectApproxEqAbs(@as(f64, 0.1), try kickAt(&fx, 950_000_000, out), 1e-6);
}

test "`adsr` refuses two time lanes, and a gate that is not a boolean" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.input.key | adsr 10ms 20ms 0.5 3f | write plane.audio.gain
    , .{.{ "plane.input.key", true }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "adsr", "attack", "release", "time lanes" });

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\plane.input.key | adsr 10ms 20ms 0.5 400ms | write plane.audio.gain
    , .{.{ "plane.input.key", @as(f64, 1) }});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "adsr", "'in'", "not a boolean" });
}

// ---------------------------------------------------------------------------
// `step` — the sequencer (envelopes campaign item 8, 2026-08-26)
// ---------------------------------------------------------------------------

/// Rouse `path` once and read the sequencer's output slot.
fn stepOnce(fx: *Fixture, path: []const u8, slot: []const u8) !f64 {
    try feedOcc(&fx.rt, testing.allocator, path);
    try fx.rt.tick(.{});
    return types.asNumber(fx.rt.readSlot(slot).?).?;
}

test "`step`: each rousing emits the next element, and by default it ENDS" {
    // The end is the hard half to gate, and the first version of this test did
    // not: a value stream holds its last, so "the sequence ended" and "the
    // sequence keeps re-emitting its last element" leave the SAME bytes in the
    // slot — identical output is suppressed, so even a `tally` downstream
    // cannot tell them apart. The mutation that repeats the last element
    // survived, and it deserved to.
    //
    // The live array is what separates them. Once the sequence has ended,
    // change the list under the cursor: an ended sequence is silent whatever
    // the list now says, and one that is still stepping-in-place emits the new
    // element sitting at its index.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.input.key | step plane.seq | write plane.out
    , .{ .{ "plane.input.key", true }, .{ "plane.seq", [3]i64{ 10, 20, 30 } } });
    defer fx.deinit();
    const out = "programs.p.step1.out.out";

    // Mount is a rousing (the seeded path arrived), so the first element is
    // already out.
    try testing.expectEqual(@as(f64, 10), types.asNumber(fx.rt.readSlot(out).?).?);
    try testing.expectEqual(@as(f64, 20), try stepOnce(&fx, "plane.input.key", out));
    try testing.expectEqual(@as(f64, 30), try stepOnce(&fx, "plane.input.key", out));
    try testing.expectEqual(@as(f64, 30), try stepOnce(&fx, "plane.input.key", out));

    // Ended is ended. Three more rousings over a completely different list say
    // nothing at all, and the sink still holds the 30 it was left with.
    try feedInts(&fx.rt, testing.allocator, "plane.seq", &.{ 70, 80, 90 });
    try fx.rt.tick(.{});
    for (0..3) |_| try testing.expectEqual(@as(f64, 30), try stepOnce(&fx, "plane.input.key", out));
}

test "`step`: `loop` wraps, `bounce` turns round, `reverse` starts at the end" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.k | step [10, 20, 30] loop | write plane.a
        \\plane.k | step [10, 20, 30] bounce | write plane.b
        \\plane.k | step [10, 20, 30] reverse | write plane.c
    , .{.{ "plane.k", true }});
    defer fx.deinit();
    const lp = "programs.p.step1.out.out";
    const bo = "programs.p.step2.out.out";
    const rv = "programs.p.step3.out.out";

    var loop_seen = std.ArrayListUnmanaged(f64).empty;
    defer loop_seen.deinit(testing.allocator);
    var bounce_seen = std.ArrayListUnmanaged(f64).empty;
    defer bounce_seen.deinit(testing.allocator);
    var rev_seen = std.ArrayListUnmanaged(f64).empty;
    defer rev_seen.deinit(testing.allocator);

    try loop_seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(lp).?).?);
    try bounce_seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(bo).?).?);
    try rev_seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(rv).?).?);
    for (0..5) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.k");
        try fx.rt.tick(.{});
        try loop_seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(lp).?).?);
        try bounce_seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(bo).?).?);
        try rev_seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(rv).?).?);
    }
    try testing.expectEqualSlices(f64, &.{ 10, 20, 30, 10, 20, 30 }, loop_seen.items);
    try testing.expectEqualSlices(f64, &.{ 10, 20, 30, 20, 10, 20 }, bounce_seen.items);
    // `reverse` runs once, downward, and then holds its last — 10 four times
    // over is the wave having ended, not the sequence repeating.
    try testing.expectEqualSlices(f64, &.{ 30, 20, 10, 10, 10, 10 }, rev_seen.items);
}

test "`step`: the array is LIVE — the cursor carries and clamps, it does not restart" {
    // Chris's pin. A sequence a person is listening to must not jump back to
    // the top because a list got shorter.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.k | step plane.seq loop | write plane.out
    , .{ .{ "plane.k", true }, .{ "plane.seq", [5]i64{ 10, 20, 30, 40, 50 } } });
    defer fx.deinit();
    const out = "programs.p.step1.out.out";

    try testing.expectEqual(@as(f64, 10), types.asNumber(fx.rt.readSlot(out).?).?);
    for (0..3) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.k");
        try fx.rt.tick(.{});
    }
    try testing.expectEqual(@as(f64, 40), types.asNumber(fx.rt.readSlot(out).?).?); // index 3

    // The list shrinks to two under the cursor. The index clamps to the new
    // end and CARRIES — the next rousing wraps from there, rather than the
    // sequence starting over.
    try feedInts(&fx.rt, testing.allocator, "plane.seq", &.{ 70, 80 });
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(f64, 40), types.asNumber(fx.rt.readSlot(out).?).?); // a change is not a rousing
    try feedOcc(&fx.rt, testing.allocator, "plane.k");
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(f64, 70), types.asNumber(fx.rt.readSlot(out).?).?); // clamped to 1, wrapped to 0
}

test "`step shuffle`: a fresh permutation per pass, no repeats within one" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.k | step [1, 2, 3, 4, 5, 6] shuffle loop seed 7 | write plane.out
    , .{.{ "plane.k", true }});
    defer fx.deinit();
    const out = "programs.p.step1.out.out";

    var pass1: [6]f64 = undefined;
    var pass2: [6]f64 = undefined;
    pass1[0] = types.asNumber(fx.rt.readSlot(out).?).?;
    for (1..12) |i| {
        try feedOcc(&fx.rt, testing.allocator, "plane.k");
        try fx.rt.tick(.{});
        const v = types.asNumber(fx.rt.readSlot(out).?).?;
        if (i < 6) pass1[i] = v else pass2[i - 6] = v;
    }
    // No repeats within a pass: each of the six appears exactly once.
    for ([_][6]f64{ pass1, pass2 }) |pass| {
        var seen = [_]bool{false} ** 7;
        for (pass) |v| {
            const k: usize = @intFromFloat(v);
            try testing.expect(!seen[k]);
            seen[k] = true;
        }
    }
    // …and the second pass is a FRESH permutation, not the first one again.
    try testing.expect(!std.mem.eql(f64, &pass1, &pass2));
}

test "`step random`: draws with replacement, seeded, and the seed decorrelates" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.k | step [1, 2, 3, 4, 5, 6, 7, 8] random seed 1 | write plane.a
        \\plane.k | step [1, 2, 3, 4, 5, 6, 7, 8] random seed 2 | write plane.b
        \\plane.k | step [1, 2, 3, 4, 5, 6, 7, 8] random seed 1 | write plane.c
    , .{.{ "plane.k", true }});
    defer fx.deinit();

    var differed = false;
    for (0..24) |_| {
        const a = types.asNumber(fx.rt.readSlot("programs.p.step1.out.out").?).?;
        const b = types.asNumber(fx.rt.readSlot("programs.p.step2.out.out").?).?;
        const c = types.asNumber(fx.rt.readSlot("programs.p.step3.out.out").?).?;
        // Same seed, same stream — bit for bit, in a different node.
        try testing.expectEqual(a, c);
        if (a != b) differed = true;
        try feedOcc(&fx.rt, testing.allocator, "plane.k");
        try fx.rt.tick(.{});
    }
    // …and a different seed is a different stream. `random` never ends on its
    // own, so 24 draws that all agreed would mean the seed did nothing.
    try testing.expect(differed);
}

test "`step`: `max` caps the emissions, whatever the mode says" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.k | step [10, 20, 30] loop max 4 | write plane.out
    , .{.{ "plane.k", true }});
    defer fx.deinit();
    const out = "programs.p.step1.out.out";
    var seen = std.ArrayListUnmanaged(f64).empty;
    defer seen.deinit(testing.allocator);
    try seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(out).?).?);
    for (0..6) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.k");
        try fx.rt.tick(.{});
        try seen.append(testing.allocator, types.asNumber(fx.rt.readSlot(out).?).?);
    }
    // Four emissions, then silence — and a value stream holds its last, so the
    // tail is 10 repeated rather than the loop continuing.
    try testing.expectEqualSlices(f64, &.{ 10, 20, 30, 10, 10, 10, 10 }, seen.items);
}

test "`step`: an empty array is silence, not a refusal and not the end" {
    // The `first` precedent: a value cannot be invented. And NOT `done` —
    // the array is live and may yet have something in it.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.k | step plane.seq loop | write plane.out
    , .{ .{ "plane.k", true }, .{ "plane.seq", [0]i64{} } });
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expect(fx.rt.readSlot("programs.p.step1.out.out") == null);

    try feedInts(&fx.rt, testing.allocator, "plane.seq", &.{ 11, 22 });
    try feedOcc(&fx.rt, testing.allocator, "plane.k");
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(f64, 11), types.asNumber(fx.rt.readSlot("programs.p.step1.out.out").?).?);
}

test "`step`: the combinations that cannot mean anything refuse, naming both words" {
    const cases = [_]struct { src: []const u8, names: []const []const u8 }{
        .{ .src = "plane.k | step [1, 2] random shuffle | write plane.out", .names = &.{ "random", "shuffle", "pick one" } },
        .{ .src = "plane.k | step [1, 2] loop bounce | write plane.out", .names = &.{ "loop", "bounce", "pick one" } },
        .{ .src = "plane.k | step [1, 2] reverse random seed 1 | write plane.out", .names = &.{ "reverse", "random", "no direction" } },
        .{ .src = "plane.k | step [1, 2] bounce shuffle seed 1 | write plane.out", .names = &.{ "bounce", "shuffle", "fixed order" } },
        .{ .src = "plane.k | step [1, 2] seed 7 | write plane.out", .names = &.{ "seed", "nothing to seed" } },
    };
    for (cases) |c| {
        var fx: Fixture = undefined;
        try mountWatched(testing.allocator, &fx, c.src, .{.{ "plane.k", true }});
        defer fx.deinit();
        try expectRefusalNames(c.names);
    }
}

test "`below`: the FIRST number trips, for both words — the pair's whole claim" {
    // The ruling (2026-08-26) that made `below` a word instead of `above` with
    // its numbers swapped: in `above <on> <off>` and `below <on> <off>` alike,
    // the first number is the trip and the second is the release. A reader
    // never has to work out which of the two is the bigger one.
    //
    // Gated where the two readings DISAGREE, which is the ledger's first line
    // and which this gate got wrong on its first draft: it fed each operator a
    // value sitting exactly ON its first number (0.3 to `above 0.3 0.2`, 0.2
    // to `below 0.2 0.3`) and asserted both were true. An implementation that
    // trips on its SECOND number passes that, because 0.2 ≤ 0.2 and 0.2 ≤ 0.3
    // are both true — A and B agree there. The mutation walked straight
    // through it.
    //
    // The discriminating value is INSIDE the band. At 0.25 neither word has
    // tripped: `above` wants ≥ 0.3 and `below` wants ≤ 0.2. Trip on the second
    // number instead and both read true — one gate, both words, no agreement
    // to hide in.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.a | above 0.3 0.2 | write plane.x
        \\plane.b | below 0.2 0.3 | write plane.y
    , .{ .{ "plane.a", @as(f64, 0.25) }, .{ "plane.b", @as(f64, 0.25) } });
    defer fx.deinit();
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.above1.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.below1.out.out").?).?);

    // …and the trip itself is inclusive at the first number, both words.
    try feedValue(&fx.rt, testing.allocator, "plane.a", @as(f64, 0.3));
    try feedValue(&fx.rt, testing.allocator, "plane.b", @as(f64, 0.2));
    try fx.rt.tick(.{});
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.above1.out.out").?).?);
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.below1.out.out").?).?);
}

test "`below`: emits its LEVEL at mount, both ways" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.dark | below 0.2 0.3 | write plane.a
        \\plane.bright | below 0.2 0.3 | write plane.b
    , .{ .{ "plane.dark", @as(f64, 0.1) }, .{ "plane.bright", @as(f64, 0.9) } });
    defer fx.deinit();
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.below1.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.below2.out.out").?).?);
}

test "`below`: the band holds falling, and releases only past the second number" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.v | below 0.2 0.3 | write plane.out
    , .{.{ "plane.v", @as(f64, 0.5) }});
    defer fx.deinit();
    const out = "programs.p.below1.out.out";
    try testing.expect(!types.asBool(fx.rt.readSlot(out).?).?);

    // Down through the trip, then wobbling in the band: it stays put.
    for ([_]f64{ 0.19, 0.21, 0.25, 0.29, 0.22 }) |v| {
        try feedValue(&fx.rt, testing.allocator, "plane.v", v);
        try fx.rt.tick(.{});
        try testing.expect(types.asBool(fx.rt.readSlot(out).?).?);
    }
    // …and releases at the release, not before it.
    try feedValue(&fx.rt, testing.allocator, "plane.v", @as(f64, 0.3));
    try fx.rt.tick(.{});
    try testing.expect(!types.asBool(fx.rt.readSlot(out).?).?);
}

test "`below` refuses a release BELOW the trip, and names both numbers" {
    // The mirror of `above`'s refusal, and the mirror is the point: each word
    // refuses the other's order. `below 0.3 0.2` is not a program that quietly
    // behaves like something.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.v | below 0.3 0.2 | write plane.out
    , .{.{ "plane.v", @as(f64, 0.5) }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "below", "hysteresis", "above the trip", "0.2", "0.3" });
}

test "beat 4a: `above` refuses a release above the trip" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.v | above 0.2 0.3 | write plane.out
    , .{.{ "plane.v", @as(f64, 0.5) }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "above", "hysteresis", "below the trip" });
}

/// An f32 bit pattern, for pinning noise. Values would let a different
/// arithmetic order pass; bit patterns will not. `@floatCast` f64→f32 is exact
/// here because the operator computed in f32 and widened exactly.
fn bits32(v: f64) u32 {
    return @bitCast(@as(f32, @floatCast(v)));
}

test "beat 4b: `noise` is pinned to its BIT PATTERNS, not to values" {
    // The ledger's hardest line lands here: an expectation is faithful to the
    // implementation's arithmetic or it is not an expectation. A float64
    // oracle for f32 code is prose in numeric clothing, so this pins the
    // exact f32 words the operator produced — which is also what makes
    // "bit-identical across machines" a checkable claim rather than a hope.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 1s | write plane.n
        \\noise 1s seed 7 | write plane.n7
        \\noise 1s octaves 3 | write plane.n3
    , .{});
    defer fx.deinit();

    const Case = struct { ns: u64, n: u32, n7: u32, n3: u32 };
    for ([_]Case{
        .{ .ns = 0, .n = 0x3EF91800, .n7 = 0x3F056ABE, .n3 = 0x3EF4B2E6 },
        .{ .ns = 250_000_000, .n = 0x3F149BA0, .n7 = 0x3F018651, .n3 = 0x3F0FCC5A },
        .{ .ns = 500_000_000, .n = 0x3F1DDE7D, .n7 = 0x3EF5480F, .n3 = 0x3F188C65 },
        .{ .ns = 1_500_000_000, .n = 0x3F1799A8, .n7 = 0x3F0858D6, .n3 = 0x3F19F52B },
        .{ .ns = 3_700_000_000, .n = 0x3F2B93C2, .n7 = 0x3ED42F1F, .n3 = 0x3F19E449 },
    }) |c| {
        try fx.rt.tick(.{ .time_ns = c.ns });
        try testing.expectEqual(c.n, bits32(slotNum(&fx, "programs.p.noise1.out.out").?));
        try testing.expectEqual(c.n7, bits32(slotNum(&fx, "programs.p.noise2.out.out").?));
        try testing.expectEqual(c.n3, bits32(slotNum(&fx, "programs.p.noise3.out.out").?));
    }
}

test "beat 4b: `noise` stays inside 0..1, and the seed decorrelates" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 300ms | write plane.a
        \\noise 300ms seed 1 | write plane.b
        \\noise 300ms seed 2 | write plane.c
    , .{});
    defer fx.deinit();

    var differed: usize = 0;
    var samples: usize = 0;
    var ns: u64 = 0;
    while (ns < 4_000_000_000) : (ns += 37_000_000) {
        try fx.rt.tick(.{ .time_ns = ns });
        samples += 1;
        const a = slotNum(&fx, "programs.p.noise1.out.out").?;
        const b = slotNum(&fx, "programs.p.noise2.out.out").?;
        const c = slotNum(&fx, "programs.p.noise3.out.out").?;
        for ([_]f64{ a, b, c }) |v| {
            try testing.expect(v >= 0 and v <= 1);
        }
        if (a != b and b != c and a != c) differed += 1;
    }
    // Three seeds are three independent streams — the whole reason `seed` is
    // "the decorrelator". Not EVERY sample differs: 1D gradient noise is zero
    // at every lattice point, so all seeds meet at 0.5 there whatever their
    // gradients. What matters is that they are apart nearly everywhere else.
    try testing.expect(differed == samples);
}

test "beat 4b: seeds offset the LATTICE, not only the gradients" {
    // Chris's amendment, and the gate that would have caught it: the first
    // decorrelation gate sampled at 37ms over a 300ms period and so never once
    // landed on a lattice boundary. Gradient noise is zero at every lattice
    // point FOR EVERY SEED, and seeds sharing a period share a lattice — so
    // without a per-seed lattice phase, every torch on a different seed passes
    // through 0.5 in lockstep at each period boundary. A family, not a corner.
    //
    // So this samples exactly ON the boundaries, which is where the bug lived.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 300ms | write plane.a
        \\noise 300ms seed 1 | write plane.b
        \\noise 300ms seed 2 | write plane.c
        \\noise 300ms octaves 3 seed 3 | write plane.d
    , .{});
    defer fx.deinit();

    var ns: u64 = 0;
    while (ns <= 3_000_000_000) : (ns += 300_000_000) { // every period boundary
        try fx.rt.tick(.{ .time_ns = ns });
        const v = [_]f64{
            slotNum(&fx, "programs.p.noise1.out.out").?,
            slotNum(&fx, "programs.p.noise2.out.out").?,
            slotNum(&fx, "programs.p.noise3.out.out").?,
            slotNum(&fx, "programs.p.noise4.out.out").?,
        };
        for (v) |x| {
            // Nobody sits at the lattice zero any more — that was the tell.
            try testing.expect(x != 0.5);
        }
        for (v, 0..) |x, i| {
            for (v[i + 1 ..]) |y| try testing.expect(x != y);
        }
    }
}

test "beat 4b: `noise` is SMOOTH — that is what separates it from `rand`" {
    // Gradient noise, not white: consecutive samples a fraction of a period
    // apart must be close. A hash-per-tick would pass a 0..1 range check and
    // fail this.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 1s | write plane.out
    , .{});
    defer fx.deinit();

    var prev: ?f64 = null;
    var ns: u64 = 0;
    while (ns < 3_000_000_000) : (ns += 10_000_000) { // 1/100th of a period
        try fx.rt.tick(.{ .time_ns = ns });
        const v = slotNum(&fx, "programs.p.noise1.out.out").?;
        if (prev) |p| try testing.expect(@abs(v - p) < 0.05);
        prev = v;
    }
}

test "beat 4b: `noise` is stateless — the same fed time gives the same value" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 1s | write plane.a
        \\noise 1s | write plane.b
    , .{});
    defer fx.deinit();

    // Two nodes, same declaration, same fed time — and no state to diverge.
    var ns: u64 = 0;
    while (ns < 2_000_000_000) : (ns += 130_000_000) {
        try fx.rt.tick(.{ .time_ns = ns });
        try testing.expectEqual(
            slotNum(&fx, "programs.p.noise1.out.out").?,
            slotNum(&fx, "programs.p.noise2.out.out").?,
        );
    }
}

test "beat 4b: `noise` refuses an octave count it cannot mean" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\noise 1s octaves 0 | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "noise", "octaves", "1 to 8" });
}

test "beat 4b: pick a random idle animation per trigger — the row, one line" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.events.idle | rand | mul 4 | floor | choose ["a", "b", "c", "d"] | write plane.anim.idle
    , .{.{ "plane.events.idle", true }});
    defer fx.deinit();

    var seen = [_]bool{ false, false, false, false };
    for (0..40) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.events.idle");
        try fx.rt.tick(.{});
        const pick = types.asString(fx.rt.readSlot("programs.p.choose1.out.out").?).?;
        seen[pick[0] - 'a'] = true;
    }
    // Every branch reachable — a `rand` that returned a constant would pass a
    // range check and fail this.
    for (seen) |s| try testing.expect(s);
}

test "beat 4b: `rand` draws a fresh value per rousing and replays identically" {
    const draw = struct {
        fn go(out: *[6]f64) !void {
            var fx: Fixture = undefined;
            try mountFixture(testing.allocator, &fx,
                \\plane.trigger | rand | write plane.out
            , .{.{ "plane.trigger", true }});
            defer fx.deinit();
            for (out) |*slot| {
                try feedOcc(&fx.rt, testing.allocator, "plane.trigger");
                try fx.rt.tick(.{});
                slot.* = slotNum(&fx, "programs.p.rand1.out.out").?;
            }
        }
    }.go;

    var a: [6]f64 = undefined;
    var b: [6]f64 = undefined;
    try draw(&a);
    try draw(&b);
    // Deterministic: the same arrivals give the same sequence, which is what
    // "replay is bit-identical" requires of a random source.
    try testing.expectEqualSlices(f64, &a, &b);
    // …and it is a SEQUENCE, not one number repeated.
    for (a) |v| try testing.expect(v >= 0 and v < 1);
    try testing.expect(a[0] != a[1] and a[1] != a[2]);
}

test "beat 4b: `rand` seeds decorrelate, and 0 is the default" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.trigger | rand | write plane.a
        \\plane.trigger | rand seed 0 | write plane.b
        \\plane.trigger | rand seed 9 | write plane.c
    , .{.{ "plane.trigger", true }});
    defer fx.deinit();

    var same_as_default: usize = 0;
    var differed: usize = 0;
    for (0..8) |_| {
        try feedOcc(&fx.rt, testing.allocator, "plane.trigger");
        try fx.rt.tick(.{});
        const a = slotNum(&fx, "programs.p.rand1.out.out").?;
        const b = slotNum(&fx, "programs.p.rand2.out.out").?;
        const c = slotNum(&fx, "programs.p.rand3.out.out").?;
        if (a == b) same_as_default += 1;
        if (a != c) differed += 1;
    }
    try testing.expectEqual(@as(usize, 8), same_as_default); // seed 0 IS the default
    try testing.expectEqual(@as(usize, 8), differed);
}

test "beat 4b: alarm when a raider is within 10m of the gate — the row, one line" {
    // §4's row, which "needs `distance`". `within` is the question people
    // actually ask, and it keeps the comparison from being written backwards.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.entities.raider.pos | within plane.gate.pos 10 | write plane.signals.alarm
    , .{
        .{ "plane.entities.raider.pos", .{ .x = @as(f64, 0), .y = @as(f64, 0), .z = @as(f64, 30) } },
        .{ "plane.gate.pos", .{ .x = @as(f64, 0), .y = @as(f64, 0), .z = @as(f64, 0) } },
    });
    defer fx.deinit();

    const out = "programs.p.within1.out.out";
    try testing.expect(!types.asBool(fx.rt.readSlot(out).?).?);

    // The raider closes to 5m.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pk = struple.Packer.init(a);
    try pk.appendMap(&.{
        .{ try packOne(a, "x"), try packOne(a, @as(f64, 3)) },
        .{ try packOne(a, "y"), try packOne(a, @as(f64, 0)) },
        .{ try packOne(a, "z"), try packOne(a, @as(f64, 4)) },
    });
    try fx.rt.feed(.{ .path = "plane.entities.raider.pos", .value = pk.bytes() });
    try fx.rt.tick(.{});
    try testing.expect(types.asBool(fx.rt.readSlot(out).?).?);
}

test "`dot`: the scalar product, and what it is for" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{x: 3, y: 0, z: 4} | dot {x: 3, y: 0, z: 4} | write plane.self
        \\{x: 1, y: 0, z: 0} | dot {x: 0, y: 1, z: 0} | write plane.side
        \\{x: 1, y: 0, z: 0} | dot {x: -1, y: 0, z: 0} | write plane.behind
        \\{x: 2, y: 3, z: 4} | dot {x: 5, y: 6, z: 7} | write plane.mixed
    , .{});
    defer fx.deinit();

    // With itself it is the squared length — 3-4-5, so 25.
    try testing.expectEqual(@as(f64, 25), slotNum(&fx, "programs.p.dot1.out.out").?);
    // The three facings that make it useful: side on is 0, behind is negative,
    // and (below) dead ahead is positive. That trio is the whole of `dot` as an
    // author meets it.
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.dot2.out.out").?);
    try testing.expectEqual(@as(f64, -1), slotNum(&fx, "programs.p.dot3.out.out").?);
    // 2·5 + 3·6 + 4·7
    try testing.expectEqual(@as(f64, 56), slotNum(&fx, "programs.p.dot4.out.out").?);
}

test "`dot` refuses a non-position, naming the axis it wanted" {
    // Same contract as `distance`/`within`, and the same words: the spatial
    // family does not guess at 2D (ruled 2026-08-25).
    var fx: Fixture = undefined;
    const bad = mountFixture(testing.allocator, &fx,
        \\{x: 1, y: 2} | dot {x: 1, y: 2, z: 3} | write plane.out
    , .{});
    if (bad) |_| {
        defer fx.deinit();
        try fx.rt.tick(.{});
        // The wave dies at the node rather than inventing z = 0.
        try testing.expect(fx.rt.readSlot("programs.p.dot1.out.out") == null);
    } else |_| {}
}

test "`nearest` is the inverse of `along` — including when you are ON the curve" {
    // The property the word claims, round-tripped through the REAL `along`, so
    // the two cannot drift onto different curves.
    //
    // Standing on the curve is the case Blade3D got wrong: its search stopped
    // when its two probes were equidistant, which is true at the first step for
    // any point on the curve (or on a perpendicular bisector), and it returned
    // t≈0.25 for everything. This asks at five places along the curve.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[0, 0.25, 0.5, 0.75, 1] | map (along [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 20, y: 5, z: 0}, {x: 30, y: 0, z: 0}]) as pts
        \\pts | map (nearest [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 20, y: 5, z: 0}, {x: 30, y: 0, z: 0}]) | write plane.ts
    , .{});
    defer fx.deinit();

    const got = fx.rt.readSlot("programs.p.map2.out.out").?;
    const inner = try innerOf(testing.allocator, got);
    defer testing.allocator.free(inner);
    const view = struple.view(inner);
    const want = [_]f64{ 0, 0.25, 0.5, 0.75, 1 };
    for (want, 0..) |w, i| {
        const cell = (try view.at(i)).?;
        try testing.expectApproxEqAbs(w, types.asNumber(cell).?, 1e-4);
    }
}

test "`nearest`: a point off the curve lands on the nearest part of it" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        // A straight run along x. A point hovering above the middle of it must
        // come back at the middle, not at an end.
        \\{x: 15, y: 40, z: 0} | nearest [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 20, y: 0, z: 0}, {x: 30, y: 0, z: 0}] | write plane.mid
        // ...and one past the far end clamps to 1 rather than running off.
        \\{x: 900, y: 0, z: 0} | nearest [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 20, y: 0, z: 0}, {x: 30, y: 0, z: 0}] | write plane.past
        \\{x: -900, y: 0, z: 0} | nearest [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 20, y: 0, z: 0}, {x: 30, y: 0, z: 0}] | write plane.before
    , .{});
    defer fx.deinit();

    try testing.expectApproxEqAbs(@as(f64, 0.5), slotNum(&fx, "programs.p.nearest1.out.out").?, 1e-3);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, "programs.p.nearest2.out.out").?);
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.nearest3.out.out").?);
}

test "`nearest` refuses what `along` refuses, in the same words" {
    var fx: Fixture = undefined;
    const one_knot = mountFixture(testing.allocator, &fx,
        \\{x: 0, y: 0, z: 0} | nearest [{x: 1, y: 1, z: 1}] | write plane.out
    , .{});
    if (one_knot) |_| {
        defer fx.deinit();
        try fx.rt.tick(.{});
        try testing.expect(fx.rt.readSlot("programs.p.nearest1.out.out") == null);
    } else |_| {}
}

// ---------------------------------------------------------------------------
// `loop` — the closed curve (ruled 2026-08-29, the seam-kink cure).
//
// `along ks loop` closes the curve back to its first knot and wraps t;
// `nearest ks loop` searches that same closed curve. The gates below hold the
// three claims the words make: the seam is not special (t=1 IS t=0, and
// rotating the knot list only re-phases t), the tangent is continuous across
// it (measured against the padded-knot workaround, which shows the kink in
// the same breath — rule 1: run where A ≠ B and assert the inequality), and
// `nearest … loop` stays `along … loop`'s inverse even when the search
// bracket straddles the seam.
// ---------------------------------------------------------------------------

/// The x/y/z of a record slot, for the curve gates below.
fn slotVec3(fx: *Fixture, slot: []const u8) ![3]f64 {
    const out = fx.rt.readSlot(slot) orelse return error.NoSlot;
    const f = try recordFields(testing.allocator, out);
    defer freeFields(testing.allocator, f);
    if (f.len != 3) return error.NotAVec3;
    return .{ f[0].v, f[1].v, f[2].v };
}

/// The angle between two directions, for the seam-tangent gate.
fn angleBetween(a: [3]f64, b: [3]f64) f64 {
    var dot: f64 = 0;
    var la: f64 = 0;
    var lb: f64 = 0;
    for (0..3) |c| {
        dot += a[c] * b[c];
        la += a[c] * a[c];
        lb += b[c] * b[c];
    }
    const cosv = dot / (@sqrt(la) * @sqrt(lb));
    return std.math.acos(@min(1.0, @max(-1.0, cosv)));
}

/// Distance between two parameters ON THE CIRCLE, because on a loop the seam
/// is one point wearing two numbers: 0.99999 and 0 are 1e-5 apart, not one.
fn circleDist(a: f64, b: f64) f64 {
    const d = @abs(a - b);
    return @min(d, 1 - d);
}

test "`along … loop`: t=1 IS t=0, and t wraps instead of clamping" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 10, y: 10, z: 0}, {x: 0, y: 10, z: 0}] as track
        \\plane.t | along track loop | write plane.a
        \\plane.t | add 1 | along track loop | write plane.b
        \\plane.t | sub 1 | along track loop | write plane.c
    , .{.{ "plane.t", @as(f64, 0.25) }});
    defer fx.deinit();

    // One lap forward and one lap back are the same place, bit for bit.
    const a = fx.rt.readSlot("programs.p.along1.out.out").?;
    const b = fx.rt.readSlot("programs.p.along2.out.out").?;
    const c = fx.rt.readSlot("programs.p.along3.out.out").?;
    try testing.expect(std.mem.eql(u8, a, b));
    try testing.expect(std.mem.eql(u8, a, c));

    // And the seam is one point wearing two numbers: t=1 lands where t=0 does.
    try feedValue(&fx.rt, testing.allocator, "plane.t", 1);
    try fx.rt.tick(.{});
    const at_one = try testing.allocator.dupe(u8, fx.rt.readSlot("programs.p.along1.out.out").?);
    defer testing.allocator.free(at_one);
    try feedValue(&fx.rt, testing.allocator, "plane.t", 0);
    try fx.rt.tick(.{});
    try testing.expect(std.mem.eql(u8, at_one, fx.rt.readSlot("programs.p.along1.out.out").?));
}

test "`along … loop`: the tangent is continuous across the seam — and the padded-knot workaround's is not" {
    // The kink this word exists to remove, measured. The padded curve is the
    // OLD closed-track spelling (rail.rill's original): first knot repeated as
    // the last, t wrapped by `mod` outside. Its two one-sided tangents at the
    // seam differ by a corner (the end tangents are clamped); the loop's two
    // differ by O(h) of ordinary curvature. Same knots, same h, both angles
    // asserted — the gate runs where A ≠ B.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 10, y: 10, z: 0}, {x: 0, y: 10, z: 0}] as track
        \\[{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 10, y: 10, z: 0}, {x: 0, y: 10, z: 0}, {x: 0, y: 0, z: 0}] as padded
        \\0.9995 | along padded | write plane.p_in
        \\0.0005 | along padded | write plane.p_out
        \\0.9995 | along track loop | write plane.q_in
        \\0.0005 | along track loop | write plane.q_out
    , .{});
    defer fx.deinit();

    const p_in = try slotVec3(&fx, "programs.p.along1.out.out");
    const p_out = try slotVec3(&fx, "programs.p.along2.out.out");
    const q_in = try slotVec3(&fx, "programs.p.along3.out.out");
    const q_out = try slotVec3(&fx, "programs.p.along4.out.out");
    const seam = [3]f64{ 0, 0, 0 }; // both curves pass through the first knot at the seam

    const kink = angleBetween(
        .{ seam[0] - p_in[0], seam[1] - p_in[1], seam[2] - p_in[2] },
        .{ p_out[0] - seam[0], p_out[1] - seam[1], p_out[2] - seam[2] },
    );
    const smooth = angleBetween(
        .{ seam[0] - q_in[0], seam[1] - q_in[1], seam[2] - q_in[2] },
        .{ q_out[0] - seam[0], q_out[1] - seam[1], q_out[2] - seam[2] },
    );
    // The workaround corners (~90° on this track); the loop does not.
    try testing.expect(kink > 0.5);
    try testing.expect(smooth < 0.05);
    try testing.expect(smooth < kink / 10.0);
}

test "`along … loop`: rotating the knot list only re-phases t — no seam anywhere" {
    // The structural form of "the seam is not special": a closed curve through
    // rotated knots is the SAME curve, one segment out of phase. A clamped end
    // tangent would pin a corner to wherever the list happens to start, and
    // rotating the list would move it — this gate would see the two curves
    // disagree hardest exactly there.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 10, y: 10, z: 0}, {x: 0, y: 10, z: 0}] as track
        \\[{x: 10, y: 0, z: 0}, {x: 10, y: 10, z: 0}, {x: 0, y: 10, z: 0}, {x: 0, y: 0, z: 0}] as turned
        \\plane.t | along track loop | write plane.a
        \\plane.t | sub 0.25 | along turned loop | write plane.b
    , .{.{ "plane.t", @as(f64, 0.99) }});
    defer fx.deinit();

    // 0.99 and 0.01 sit a hair either side of track's seam — where a pinned
    // corner would disagree most; 0.30 and 0.625 are ordinary mid-curve.
    for ([_]f64{ 0.99, 0.01, 0.30, 0.625 }) |t| {
        try feedValue(&fx.rt, testing.allocator, "plane.t", t);
        try fx.rt.tick(.{});
        const a = try slotVec3(&fx, "programs.p.along1.out.out");
        const b = try slotVec3(&fx, "programs.p.along2.out.out");
        for (0..3) |c| try testing.expectApproxEqAbs(a[c], b[c], 1e-9);
    }
}

test "`along` refuses a two-knot loop, at mount" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.t | along [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}] loop | write plane.out
    , .{.{ "plane.t", @as(f64, 0.5) }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "along", "2 knots", "at least three" });
    try testing.expect(fx.rt.readSlot("programs.p.along1.out.out") == null);
}

test "`nearest` refuses a two-knot loop, in the same words" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\{x: 0, y: 0, z: 0} | nearest [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}] loop | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "nearest", "2 knots", "at least three" });
    try testing.expect(fx.rt.readSlot("programs.p.nearest1.out.out") == null);
}

test "`along … loop` refuses the duplicated closing knot — the open-curve idiom it replaces" {
    // [a, b, c, a] closed a track before `loop` existed. Under `loop` the
    // closing segment already exists, so the duplicate would be a zero-length
    // segment with a cusp exactly where the seam kink used to be. Refusing at
    // mount names the migration mistake the moment it is made.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.t | along [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 5, y: 8, z: 0}, {x: 0, y: 0, z: 0}] loop | write plane.out
    , .{.{ "plane.t", @as(f64, 0.5) }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "along", "same point", "drop the duplicate" });
    try testing.expect(fx.rt.readSlot("programs.p.along1.out.out") == null);
}

test "`nearest … loop` refuses the duplicated closing knot, in the same words" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\{x: 1, y: 1, z: 0} | nearest [{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 5, y: 8, z: 0}, {x: 0, y: 0, z: 0}] loop | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "nearest", "same point", "drop the duplicate" });
    try testing.expect(fx.rt.readSlot("programs.p.nearest1.out.out") == null);
}

test "`nearest … loop` is the inverse of `along … loop` — across the seam included" {
    // Round-tripped through the REAL `along … loop`, like the open-curve gate
    // above, so the two words cannot drift onto different closed curves.
    //
    // 0.995 is load-bearing: its curve point sits closer to the seam than to
    // any coarse sample, so the coarse winner is the seam itself and the
    // narrowing bracket must straddle it — the case where an open-curve
    // bracket, clamped at the ends, would converge to 0 and answer a full
    // half-percent of a lap wrong.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 10, y: 10, z: 0}, {x: 0, y: 10, z: 0}] as track
        \\[0, 0.01, 0.25, 0.5, 0.75, 0.99, 0.995] | map (along track loop) as pts
        \\pts | map (nearest track loop) | write plane.ts
    , .{});
    defer fx.deinit();

    const got = fx.rt.readSlot("programs.p.map2.out.out").?;
    const inner = try innerOf(testing.allocator, got);
    defer testing.allocator.free(inner);
    const view = struple.view(inner);
    const want = [_]f64{ 0, 0.01, 0.25, 0.5, 0.75, 0.99, 0.995 };
    for (want, 0..) |w, i| {
        const cell = (try view.at(i)).?;
        const t_back = types.asNumber(cell).?;
        try testing.expect(circleDist(w, t_back) < 1e-4);
        // …and CANONICALLY: in [0, 1), never −ε or 1+ε. circleDist cannot see
        // this (−0.005 and 0.995 are the same circle point), so it is asserted
        // on its own — the 0.995 case is the one whose search settles at a
        // negative parameter and relies on the emit to wrap it.
        try testing.expect(t_back >= 0.0 and t_back < 1.0);
    }
}

test "`nearest … loop`: points off the curve near the seam land near the seam, not at t≈0.25" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        // The track's seam knot is the {0,0,0} corner; travel arrives along −y
        // and leaves along +x. One point flanks the arriving edge, one the
        // leaving edge, one sits square outside the corner itself.
        \\[{x: 0, y: 0, z: 0}, {x: 10, y: 0, z: 0}, {x: 10, y: 10, z: 0}, {x: 0, y: 10, z: 0}] as track
        \\{x: -3, y: 2, z: 0} | nearest track loop | write plane.arriving
        \\{x: 2, y: -3, z: 0} | nearest track loop | write plane.leaving
        \\{x: -3, y: -3, z: 0} | nearest track loop | write plane.corner
    , .{});
    defer fx.deinit();

    const arriving = slotNum(&fx, "programs.p.nearest1.out.out").?;
    const leaving = slotNum(&fx, "programs.p.nearest2.out.out").?;
    const corner = slotNum(&fx, "programs.p.nearest3.out.out").?;
    try testing.expect(arriving > 0.8 and arriving < 1.0);
    try testing.expect(leaving > 0.0 and leaving < 0.2);
    try testing.expect(circleDist(corner, 0) < 0.02);
    // The answer is CANONICAL: in [0, 1), never −ε or 1+ε — circleDist would
    // forgive an unwrapped emit here, so the range is asserted on its own.
    try testing.expect(corner >= 0.0 and corner < 1.0);
}

// ---------------------------------------------------------------------------
// angle / inside / cross — the Blade3D audit's last three words (2026-08-29).
//
// Each gate watches the property the word CLAIMS, per the discipline: angle's
// exactness at the ends and its symmetry, inside's boundary behaviour exactly
// as documented (the wall counts; an inverted box answers, never refuses),
// cross's handedness and its perpendicularity — the last one proved IN the
// language, `cross | dot`, because feeding the family back into itself is the
// reason the output is a record.
// ---------------------------------------------------------------------------

test "`angle`: exact at the answers people test for — 0 aligned, π/2 square on, π opposed" {
    // atan2(|a×b|, a·b), so the extremes are exact by construction: square on
    // is atan2(+, 0) which IS π/2, aligned is atan2(0, +) = 0, opposed is
    // atan2(0, −) = π. The acos spelling would need a clamp and would wobble
    // exactly here. Deliberately non-unit vectors throughout: no
    // normalisation is part of the claim.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{x: 3, y: 0, z: 0} | angle {x: 7, y: 0, z: 0} | write plane.aligned
        \\{x: 2, y: 0, z: 0} | angle {x: 0, y: 5, z: 0} | write plane.square
        \\{x: 1, y: 0, z: 0} | angle {x: -4, y: 0, z: 0} | write plane.opposed
        \\{x: 1, y: 1, z: 0} | angle {x: 0, y: 3, z: 0} | write plane.diagonal
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.angle1.out.out").?);
    try testing.expectEqual(std.math.pi / 2.0, slotNum(&fx, "programs.p.angle2.out.out").?);
    try testing.expectEqual(std.math.pi, slotNum(&fx, "programs.p.angle3.out.out").?);
    try testing.expectApproxEqAbs(std.math.pi / 4.0, slotNum(&fx, "programs.p.angle4.out.out").?, 1e-12);
}

test "`angle` is symmetric, bit for bit" {
    // The word claims AN angle between two directions, not an angle FROM one
    // TO the other — so the two orders must agree exactly, which they do by
    // construction: the cross length loses its sign and every product is
    // computed in the same order either way.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{x: 0.3, y: -1.7, z: 2.2} | angle {x: 5.1, y: 0.4, z: -0.9} | write plane.ab
        \\{x: 5.1, y: 0.4, z: -0.9} | angle {x: 0.3, y: -1.7, z: 2.2} | write plane.ba
    , .{});
    defer fx.deinit();

    const ab = fx.rt.readSlot("programs.p.angle1.out.out").?;
    const ba = fx.rt.readSlot("programs.p.angle2.out.out").?;
    try testing.expect(std.mem.eql(u8, ab, ba));
}

test "`angle` refuses a zero-length vector, naming the port — 'a'" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\{x: 0, y: 0, z: 0} | angle {x: 1, y: 0, z: 0} | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "angle", "'a'", "no direction" });
    try testing.expect(fx.rt.readSlot("programs.p.angle1.out.out") == null);
}

test "`angle` refuses a zero-length vector, naming the port — 'b'" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\{x: 1, y: 0, z: 0} | angle {x: 0, y: 0, z: 0} | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "angle", "'b'", "no direction" });
    try testing.expect(fx.rt.readSlot("programs.p.angle1.out.out") == null);
}

test "`inside`: the wall counts, every axis is tested, and an inverted box answers false" {
    // The boundary rows run where inclusive and exclusive DIFFER — points
    // exactly ON a face and ON a corner (rule 1). The three outside rows each
    // fail on exactly ONE axis, so a dropped axis test has a row that notices
    // it alone. The inverted row asserts an ANSWER (false), not a refusal —
    // the slot must exist.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{x: 5, y: 5, z: 5} | inside {x: 0, y: 0, z: 0} {x: 10, y: 10, z: 10} | write plane.center
        \\{x: 10, y: 5, z: 5} | inside {x: 0, y: 0, z: 0} {x: 10, y: 10, z: 10} | write plane.on_face
        \\{x: 0, y: 0, z: 0} | inside {x: 0, y: 0, z: 0} {x: 10, y: 10, z: 10} | write plane.on_corner
        \\{x: 11, y: 5, z: 5} | inside {x: 0, y: 0, z: 0} {x: 10, y: 10, z: 10} | write plane.past_x
        \\{x: 5, y: -1, z: 5} | inside {x: 0, y: 0, z: 0} {x: 10, y: 10, z: 10} | write plane.under_y
        \\{x: 5, y: 5, z: 99} | inside {x: 0, y: 0, z: 0} {x: 10, y: 10, z: 10} | write plane.past_z
        \\{x: 5, y: 5, z: 5} | inside {x: 0, y: 0, z: 10} {x: 10, y: 10, z: 0} | write plane.inverted
    , .{});
    defer fx.deinit();

    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.inside1.out.out").?).?);
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.inside2.out.out").?).?);
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.inside3.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.inside4.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.inside5.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.inside6.out.out").?).?);
    // Inverted on z: EMPTY, so false — and it answered rather than refused.
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.inside7.out.out").?).?);
}

test "`cross` is right-handed, ordered x-y-z, and perpendicular to both inputs — proved in the language" {
    // x × y = z and y × x = −z is the handedness claim, asserted exactly. The
    // perpendicularity rows chain `cross | dot` IN rill with integer-valued
    // vectors, so the zeros are exact — and the chain existing at all is the
    // point: the output record feeds the family it came from.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{x: 1, y: 0, z: 0} | cross {x: 0, y: 1, z: 0} | write plane.z_axis
        \\{x: 0, y: 1, z: 0} | cross {x: 1, y: 0, z: 0} | write plane.minus_z
        \\{x: 1, y: 2, z: 3} | cross {x: 4, y: 5, z: 6} as c
        \\c | dot {x: 1, y: 2, z: 3} | write plane.perp_a
        \\c | dot {x: 4, y: 5, z: 6} | write plane.perp_b
    , .{});
    defer fx.deinit();

    const z = try recordFields(testing.allocator, fx.rt.readSlot("programs.p.cross1.out.out").?);
    defer freeFields(testing.allocator, z);
    try testing.expectEqual(@as(usize, 3), z.len);
    try testing.expectEqualStrings("x", fieldName(z[0]));
    try testing.expectEqualStrings("y", fieldName(z[1]));
    try testing.expectEqualStrings("z", fieldName(z[2]));
    try testing.expectEqual(@as(f64, 0), z[0].v);
    try testing.expectEqual(@as(f64, 0), z[1].v);
    try testing.expectEqual(@as(f64, 1), z[2].v);

    const mz = try slotVec3(&fx, "programs.p.cross2.out.out");
    try testing.expectEqual([3]f64{ 0, 0, -1 }, mz);

    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.dot1.out.out").?);
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, "programs.p.dot2.out.out").?);
}

test "beat 4b: `distance` is euclidean over record{x, y, z}" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{x: 3, y: 0, z: 4} | distance {x: 0, y: 0, z: 0} | write plane.d
        \\{x: 1, y: 2, z: 2} | within {x: 0, y: 0, z: 0} 3 | write plane.near
        \\{x: 1, y: 2, z: 2} | within {x: 0, y: 0, z: 0} 2 | write plane.far
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 5), slotNum(&fx, "programs.p.distance1.out.out").?);
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.within1.out.out").?).?);
    try testing.expect(!types.asBool(fx.rt.readSlot("programs.p.within2.out.out").?).?);
}

test "beat 4b: the spatial pair names the missing axis, on either side" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\{x: 1, y: 2} | distance {x: 0, y: 0, z: 0} | write plane.out
    , .{});
    defer fx.deinit();
    try expectRefusalNames(&.{ "distance", "'a'", "no 'z'", "record{x, y, z}" });

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\{x: 1, y: 2, z: 3} | distance {x: 0, z: 0} | write plane.out
    , .{});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "distance", "'b'", "no 'y'" });

    var fx3: Fixture = undefined;
    try mountWatched(testing.allocator, &fx3,
        \\plane.n | distance {x: 0, y: 0, z: 0} | write plane.out
    , .{.{ "plane.n", @as(f64, 4) }});
    defer fx3.deinit();
    try expectRefusalNames(&.{ "distance", "number", "not record{x, y, z}" });
}

test "beat 4b: one PRNG family — `rand` and `shuffle` draw from the same generator" {
    // Not three generators (ruled 2026-08-25). `noise` is a hash of lattice
    // coordinates, which is a different job: a generator produces a sequence,
    // a hash answers "what is the value AT this coordinate" and must answer
    // the same way forever. Two mechanisms, two questions, no third.
    //
    // Asserted by construction: `rand`'s first draw on seed s must equal what
    // xoshiro256++ seeded the same way produces, which is exactly what
    // `shuffle` steps.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.trigger | rand seed 5 | write plane.out
    , .{.{ "plane.trigger", true }});
    defer fx.deinit();

    var prng = std.Random.DefaultPrng.init(5);
    try testing.expectEqual(prng.random().float(f64), slotNum(&fx, "programs.p.rand1.out.out").?);
}

// ---------------------------------------------------------------------------
// Beat 4 close — the two ✓ rows §4 marked "re-probe at beat-4 close against a
// noisy input". A ✓ means expressible; whether the one line is RIGHT is what
// these assert. Now that `noise` exists, the noisy input can be the real
// thing rather than a hand-written wobble.
// ---------------------------------------------------------------------------

test "beat 4 close: re-probe — dim the lamp as the fire dies, against noise" {
    // The row scores ✓ at two lines. Driven by a real noisy reading, the naked
    // version jitters and the smoothed version does not — so the ✓ holds only
    // WITH the smoothing, which is what the second line is for. Asserted as
    // the difference, not as "it works".
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 120ms as heat
        \\heat | range 0.1 1 | write plane.raw
        \\heat | ease 400ms | range 0.1 1 | write plane.lights.hearth.level
    , .{});
    defer fx.deinit();

    var raw_swing: f64 = 0;
    var eased_swing: f64 = 0;
    var last_raw: ?f64 = null;
    var last_eased: ?f64 = null;
    var ns: u64 = 0;
    while (ns < 3_000_000_000) : (ns += 16_000_000) { // ~60 fps
        try fx.rt.tick(.{ .time_ns = ns });
        const r = slotNum(&fx, "programs.p.range1.out.out").?;
        const e = slotNum(&fx, "programs.p.range2.out.out").?;
        if (last_raw) |p| raw_swing += @abs(r - p);
        if (last_eased) |p| eased_swing += @abs(e - p);
        last_raw = r;
        last_eased = e;
    }
    // (The noise is a local name rather than a plane round-trip: a program may
    // not write and subscribe to one path, and the cycle check says so. What
    // is under test is noise rejection, not the plane.)
    // The smoothed lamp travels a fraction of the distance the raw one does.
    try testing.expect(raw_swing > 0.2); // there really was noise to reject
    try testing.expect(eased_swing * 2 < raw_swing);
}

test "beat 4 close: re-probe — rate-limit a noisy sensor into a knob, against noise" {
    // The row scores ✓ at one line with `sample`. What it promises is a WRITE
    // RATE, not smoothness, so that is what gets measured: at most one change
    // per period however fast the sensor moves.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 80ms as reading
        \\reading | sample 200ms | write plane.ui.knob
    , .{});
    defer fx.deinit();

    var changes: usize = 0;
    var last: ?f64 = null;
    var ns: u64 = 0;
    while (ns <= 2_000_000_000) : (ns += 16_000_000) {
        try fx.rt.tick(.{ .time_ns = ns });
        const v = slotNum(&fx, "programs.p.sample1.out.out").?;
        if (last) |p| {
            if (v != p) changes += 1;
        }
        last = v;
    }
    // 2s at 200ms is ten periods; the sensor moved on all 126 frames.
    try testing.expect(changes <= 11);
    try testing.expect(changes >= 8); // …and it did keep up, rather than sticking
}

test "beat 4: the rest of §4's noise rows, each one line" {
    // flicker a torch · let the grade drift over a minute · shake the camera
    // on impact · flash a light on an event · fly the camera along the intro
    // path. Each was "can't" before this beat.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\noise 80ms | range 0.6 1 | write plane.lights.torch.level
        \\noise 20s | range 0.9 1.1 | write plane.render.grade.exposure
        \\{x: (noise 40ms seed 1), y: (noise 40ms seed 2), z: (noise 40ms seed 3)} | sub {x: 0.5, y: 0.5, z: 0.5} | mul 0.2 | write plane.camera.shake
        \\pulse 2s width 60ms | ease 10ms down 300ms | write plane.lights.strobe.level
        \\clock | div 8 | range 0 1 | along [{x: 0, y: 2, z: 0}, {x: 5, y: 2, z: 1}, {x: 9, y: 3, z: 0}] | write plane.camera.pos
    , .{});
    defer fx.deinit();

    try fx.rt.tick(.{ .time_ns = 500_000_000 });

    // The torch flickers inside the band it was given.
    const torch = slotNum(&fx, "programs.p.range1.out.out").?;
    try testing.expect(torch >= 0.6 and torch <= 1);

    // Three seeds make three independent shake axes — one seed would shake
    // the camera along a diagonal, which is the bug this row is about.
    //
    // ONE line, since the paren form was ratified: a record field may hold a
    // complete operator call. It first landed at four, three of them `as`
    // bindings, which is what raised the fork.
    const shake = fx.rt.readSlot("programs.p.mul1.out.out").?;
    const f = try recordFields(testing.allocator, shake);
    defer freeFields(testing.allocator, f);
    try testing.expectEqual(@as(usize, 3), f.len);
    try testing.expect(f[0].v != f[1].v and f[1].v != f[2].v);
    for (f) |axis| try testing.expect(@abs(axis.v) <= 0.1);

    // The strobe is an envelope, not a rectangle: `pulse` makes the event and
    // `ease up down` gives it an attack and a decay.
    const strobe = slotNum(&fx, "programs.p.ease1.out.out").?;
    try testing.expect(strobe > 0 and strobe < 1);

    // The camera is somewhere along its path, as a position.
    const pos = fx.rt.readSlot("programs.p.along1.out.out").?;
    try testing.expectEqual(types.Tag.record, types.typeOfValue(pos));
}

test "the paren form: a record field may hold a complete operator call" {
    // Ratified 2026-08-25. `( … )` in a field position is a COMPLETE call, not
    // a section — nothing at a field position consumes an open port, so the
    // section reading would be a guess (and would bind `40ms` to `octaves`).
    // Array elements take it too, for the same reason.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{x: (add 1 2), y: (mul 3 4)} | write plane.rec
        \\[(add 1 2), (mul 3 4)] | write plane.arr
    , .{});
    defer fx.deinit();

    const rec = try recordFields(testing.allocator, fx.rt.readSlot("programs.p.record1.out.out").?);
    defer freeFields(testing.allocator, rec);
    try testing.expectEqual(@as(f64, 3), rec[0].v);
    try testing.expectEqual(@as(f64, 12), rec[1].v);

    const arr = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.array1.out.out").?);
    defer testing.allocator.free(arr);
    try testing.expectEqualSlices(f64, &.{ 3, 12 }, arr);
}

test "the paren form: a field is live when its call is" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\{v: (mul plane.a 10)} | .v | write plane.out
    , .{.{ "plane.a", @as(f64, 2) }});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 20), slotNum(&fx, "programs.p.project1.out.out").?);
    try feedValue(&fx.rt, testing.allocator, "plane.a", @as(f64, 5));
    try fx.rt.tick(.{});
    try testing.expectEqual(@as(f64, 50), slotNum(&fx, "programs.p.project1.out.out").?);
}

test "the paren form: sections still mean sections where a consumer takes one" {
    // The two readings do not collide, because they live in different
    // positions: a field never takes a section, and `map`/`keep`/`where`
    // always do. Both in one program.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[{v: (add 1 1)}, {v: (add 1 2)}] | map (.v) | keep (> 2) | write plane.out
    , .{});
    defer fx.deinit();

    const out = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.keep1.out.out").?);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(f64, &.{3}, out);
}

test "beat 4: `ramp … from` — the mount fade in one line THAT STOPS" {
    // The ratified fork. `clock | div 2 | range 0 1` is also one line and also
    // correct, and it re-evaluates every frame forever; this one lands and
    // goes quiet, which is the register family's whole argument.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\once 1 | ramp 2s from 0 | write plane.render.grade.exposure
    , .{});
    defer fx.deinit();

    const out = "programs.p.ramp1.out.out";
    try testing.expectEqual(@as(f64, 0), slotNum(&fx, out).?);
    try fx.rt.tick(.{ .time_ns = 1_000_000_000 });
    try testing.expectEqual(@as(f64, 0.5), slotNum(&fx, out).?);
    try fx.rt.tick(.{ .time_ns = 2_000_000_000 });
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);

    // …and then it STOPS. The eval counter is the proof, not the value:
    // a value that stays put looks identical to one being recomputed.
    const node = nodeIdOf(&fx.prog, "ramp1").?;
    const settled = fx.rt.eval_count[node];
    for ([_]u64{ 3_000_000_000, 4_000_000_000, 9_000_000_000 }) |ns| {
        try fx.rt.tick(.{ .time_ns = ns });
    }
    try testing.expectEqual(settled, fx.rt.eval_count[node]);
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, out).?);
}

test "beat 4: without `from`, `ramp` still baselines at its first target" {
    // The behaviour `from` was added BESIDE, not instead of: a ramp with
    // nowhere to start from must not animate out of nothing.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\once 1 | ramp 2s | write plane.a
    , .{});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 1), slotNum(&fx, "programs.p.ramp1.out.out").?);
}

// ---------------------------------------------------------------------------
// The manual-parity gate (tier 2 close, 2026-08-25).
//
// Two manuals drifted behind the language twice during this campaign, and both
// times a person found it by reading. Reading is not a coverage surface. This
// is: every registered core operator must be NAMED in the agent manual's
// operator tables, or be on the substrate list on purpose — exhaustive both
// ways, like the class, ticks and fails_mount audits.
//
// It checks the agent manual because that one is a reference: it promises to
// list the vocabulary. The human manual is prose and is gated the other way,
// by every printed example being parsed.
// ---------------------------------------------------------------------------

/// Registered and reachable, but deliberately NOT taught. Each is a fact worth
/// pinning rather than an exemption: a reader who meets these meets them
/// through the spelling that replaced them.
const untaught_substrate = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "project", .why = "the taught spelling is `.field` / `| .field`" },
    .{ .name = "array", .why = "the taught spelling is the `[…]` literal" },
};

/// Is `name` a whole token inside some inline-code span of `doc`? Code spans
/// only, because prose says "record" about a type word and a table cell says
/// `record` about the operator, and only one of those is the manual doing its
/// job. Whole tokens only, because `add` inside "address" is not a mention —
/// and because the tables list families in one span (`add sub mul div min
/// max`), which IS a mention of each.
fn namedInCode(doc: []const u8, name: []const u8) bool {
    const isTok = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_' or c == '=' or c == '!' or c == '<' or c == '>';
        }
    }.f;
    // Line by line, and fenced blocks skipped: a ```-fence is three backticks
    // and pairing them off against inline spans puts the whole scan out of
    // phase — which is exactly what the first draft of this did, and it
    // reported thirty operators missing that were sitting in the table.
    var lines = std.mem.splitScalar(u8, doc, '\n');
    var fenced = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "```")) {
            fenced = !fenced;
            continue;
        }
        if (fenced) continue;
        var in_span = false;
        var span_start: usize = 0;
        for (line, 0..) |c, i| {
            if (c != '`') continue;
            if (!in_span) {
                in_span = true;
                span_start = i + 1;
                continue;
            }
            in_span = false;
            const span = line[span_start..i];
            var j: usize = 0;
            while (j < span.len) {
                if (!isTok(span[j])) {
                    j += 1;
                    continue;
                }
                var k = j;
                while (k < span.len and isTok(span[k])) k += 1;
                if (std.mem.eql(u8, span[j..k], name)) return true;
                j = k;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// The agent manual's operator table writes arguments in §12's notation
// (ruled 2026-08-26, after a no-priors reader made the same mistake four
// times in one program).
//
// The rule the table now states above itself: **arguments are positional
// unless a word is shown; don't add a word, don't drop one that's there.**
// This gate holds the table to it in the direction that can be checked
// mechanically — no operator name may be followed by a BARE word that names
// one of its own positional arguments. `ease in tau` fails; `ease <in> <tau>`
// passes; `integrate <in> max <max>` passes, because `max` really is written
// with its word.
//
// Scoped to §3's table. §5 shows WRONG spellings on purpose (`lerp a b t`
// with all three bound), and gating those would forbid the manual from
// showing a mistake — which is most of what that section is for.
// ---------------------------------------------------------------------------

/// Is `word` an argument of `def` introduced by its own name?
fn keywordArgName(def: *const registry.OpDef, word: []const u8) bool {
    for (def.inputs) |pt| {
        if (std.mem.eql(u8, pt.name, word)) return pt.kw;
    }
    for (def.statics) |sd| {
        if (std.mem.eql(u8, sd.name, word)) return sd.kw;
    }
    return false;
}

/// Is `word` an argument of `def` written WITHOUT its name?
fn positionalArgName(def: *const registry.OpDef, word: []const u8) bool {
    for (def.inputs) |pt| {
        if (std.mem.eql(u8, pt.name, word)) return !pt.kw;
    }
    for (def.statics) |sd| {
        if (std.mem.eql(u8, sd.name, word)) return !sd.kw and !sd.flag;
    }
    return false;
}

test "the agent manual's table writes arguments in the operator index's notation" {
    const gpa = testing.allocator;
    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    const doc = @embedFile("rill-for-agents.md");
    const start = std.mem.indexOf(u8, doc, "## 3. The operator table") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, doc, start, "\n## ") orelse doc.len;
    const table = doc[start..end];

    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| ") or std.mem.startsWith(u8, line, "|---")) continue;
        rows += 1;
        // Walk each inline-code span, token by token. A token is a bracketed
        // slot (`<name>`), a bare word, or one punctuation character.
        var in_span = false;
        var span_start: usize = 0;
        for (line, 0..) |c, i| {
            if (c != '`') continue;
            if (!in_span) {
                in_span = true;
                span_start = i + 1;
                continue;
            }
            in_span = false;
            const span = line[span_start..i];
            var prev_op: ?*const registry.OpDef = null;
            var span_op: ?*const registry.OpDef = null;
            var prev_word: []const u8 = "";
            var first_token = true;
            var j: usize = 0;
            while (j < span.len) {
                if (span[j] == '<') {
                    // A slot. The OTHER half of the rule lives here: an
                    // argument that IS written with a word must show it, and
                    // `integrate <in> <max>` — bracketed, but with the word
                    // dropped — passed every check until this was added.
                    const close = std.mem.indexOfScalarPos(u8, span, j, '>') orelse span.len - 1;
                    const slot = std.mem.trim(u8, span[j + 1 .. close], "$@#");
                    if (span_op) |def| {
                        if (keywordArgName(def, slot) and !std.mem.eql(u8, prev_word, slot)) {
                            std.debug.print(
                                \\rill-for-agents.md §3 writes `{s}` — '{s}' is an argument of
                                \\'{s}' that IS introduced by its own word, and the table has
                                \\dropped it. Write `{s} <{s}>`. Don't add a word that is not
                                \\there; don't drop one that is.
                                \\
                            , .{ span, slot, def.name, slot, slot });
                            return error.TestUnexpectedResult;
                        }
                    }
                    prev_op = null;
                    prev_word = "";
                    j = close + 1;
                    continue;
                }
                if (!std.ascii.isAlphanumeric(span[j]) and span[j] != '_') {
                    j += 1;
                    continue;
                }
                var k = j;
                while (k < span.len and (std.ascii.isAlphanumeric(span[k]) or span[k] == '_')) k += 1;
                const word = span[j..k];
                if (first_token) {
                    span_op = if (reg.find(word)) |id| reg.get(id) else null;
                    first_token = false;
                }
                prev_word = word;
                if (prev_op) |def| {
                    if (positionalArgName(def, word)) {
                        std.debug.print(
                            \\rill-for-agents.md §3 writes `{s} {s}` — '{s}' is an argument of
                            \\'{s}' that is written WITHOUT its name, so the table must show it
                            \\bracketed: `{s} <{s}> …`. Arguments are positional unless a word
                            \\is shown; a bare name here reads as a keyword and is the mistake a
                            \\reviewer made four times in one program.
                            \\  in: `{s}`
                            \\
                        , .{ def.name, word, word, def.name, def.name, word, span });
                        return error.TestUnexpectedResult;
                    }
                }
                prev_op = if (reg.find(word)) |id| reg.get(id) else null;
                j = k;
            }
        }
    }
    // The table cannot quietly stop being scanned: an empty or renamed section
    // would make every check above vacuously true.
    if (rows < 15) {
        std.debug.print("§3's table has {d} rows — the scan found almost nothing\n", .{rows});
        return error.TestUnexpectedResult;
    }

    // The rule itself is stated, not just obeyed. A notation nobody explains
    // is how the reader got here.
    for ([_][]const u8{
        "Arguments are positional unless a word is shown",
        "do not drop one",
        "what it takes and",
    }) |needle| {
        if (std.mem.indexOf(u8, table, needle) == null) {
            std.debug.print("§3 no longer states: \"{s}\"\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
}

test "manual parity: every core operator is named in the agent manual, or is substrate on purpose" {
    const gpa = testing.allocator;
    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const doc = @embedFile("rill-for-agents.md");

    var missing: usize = 0;
    for (reg.ops.items) |def| {
        const substrate = for (untaught_substrate) |u| {
            if (std.mem.eql(u8, u.name, def.name)) break true;
        } else false;

        const named = namedInCode(doc, def.name);

        if (named and substrate) {
            std.debug.print("'{s}' is on the untaught-substrate list and IS taught — take it off\n", .{def.name});
            return error.TestUnexpectedResult;
        }
        if (!named and !substrate) {
            std.debug.print("'{s}' is registered and appears nowhere in rill-for-agents.md\n", .{def.name});
            missing += 1;
        }
    }
    if (missing > 0) {
        std.debug.print("{d} operator(s) missing from the agent manual\n", .{missing});
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// The identity gate (envelopes item 3 phase 1, ruled 2026-08-26).
//
// **The manual is the source; the book cites it.** Evidence cites the claim,
// never the reverse — so when these two disagree, the manual is right and the
// book cell is what gets fixed, and the failure message says so.
//
// This exists because of a measurement, not a hunch: 29 rill statements are
// written down **byte-identically in both files**, and nothing noticed. That
// is the mechanism the inverted flagship used. `above 0.3 0.2` was one
// sentence copied into the manual's §6f, the manual's §11, this book and a
// gate, and each copy was separately wrong. Parsing every copy proved every
// copy compiled.
//
// **Both ways**, and the second direction is the one Chris required: every
// listed row must still be in both files, AND the list must cover every
// statement the two files share. Without that second half a NEW shared
// program drifts while the gate stays green — the hollow-filter shape, where
// coverage is whatever was true the day the list was written.
// ---------------------------------------------------------------------------

/// Every rill statement that appears in `rill-manual.md` and in
/// `idioms.rillbook`. Adding a row here is not busywork: it is the moment
/// somebody decides these two files are saying the same thing on purpose.
const shared_rows = [_][]const u8{
    "clock | write plane.ui.elapsed",
    "lfo sine 4s | range 0.5 1.5 | write plane.render.grade.exposure",
    "lfo tri 8s | shape smooth | range 0 90 | write plane.lights.sweep.angle",
    "noise 80ms | range 0.6 1 | write plane.lights.torch.level",
    "once 1 | ramp 2s from 0 | write plane.render.grade.exposure",
    "plane.door.openness | along [{x: 0, y: 3, z: 0}, {x: 2, y: 3, z: 1}, {x: 4, y: 3, z: 0}] | write plane.lights.key.pos",
    "plane.entities.player.pos | add {x: 0, y: 2, z: 0} | write plane.lights.follow.pos",
    "plane.events.hit | kick 20ms 400ms | write plane.ui.hit_flash",
    "plane.events.impact | kick 10ms 300ms | mul 0.4 | write plane.camera.shake_amount",
    "plane.events.kill | tally | write plane.ui.kills",
    "plane.field.rumble | abs | ease 20ms down 400ms | write plane.ui.vu",
    "plane.gpu.traversal_ms | window 10s | mul 2 | stats | write plane.ui.load",
    "plane.gpu.traversal_ms | window 10s | nth 0 | write plane.ui.oldest_sample",
    "plane.gpu.traversal_ms | window 5s | reduce (max) | write plane.ui.peak",
    "plane.input.key_c | adsr 10ms 80ms 0.7 400ms | write plane.audio.voice.gain",
    "plane.input.key_l | toggle | write plane.lights.key.on",
    "plane.music.beat | step [60, 64, 67, 72] loop | notify plane.audio.note",
    "plane.render.grade | expect {exposure: number, contrast: number} | write plane.ui.grade",
    "plane.render.grade.exposure_target | ramp 2s | write plane.render.grade.exposure",
    "plane.sensors.gate.contacts | > 0 | write plane.ui.any_contact",
    "plane.sensors.gate.contacts | keep (.armed) | write plane.ui.threats",
    "plane.sensors.gate.contacts | len | write plane.ui.contacts",
    "plane.sensors.gate.contacts | sort by (.distance) | first | .id | write plane.ui.nearest",
    "plane.sensors.gate.contacts | sort by (.threat) desc | take 3 | write plane.ui.threats",
    "plane.sensors.gate.nearest | match {id: string, distance: number} | write plane.ui.threat",
    "plane.sensors.gate.nearest_distance | diff | dropped_below -2 | notify plane.signals.charge",
    "plane.world.hour | div 6 | floor | choose [0.2, 1, 1, 0.4] | write plane.render.grade.exposure",
    "plane.world.light | below 0.2 0.3 | write plane.lights.street.on",
    "{x: (noise 40ms seed 1), y: (noise 40ms seed 2), z: (noise 40ms seed 3)} | sub {x: 0.5, y: 0.5, z: 0.5} | mul 0.2 | write plane.camera.shake",
};

/// Split rill source into STATEMENTS — a line plus any continuation lines
/// (`| …` at the head), blanks and comments dropped, every line trimmed, and
/// the continuations JOINED BACK ONTO ONE LINE.
///
/// Layout is not identity. Indentation was the first half of that: the manual
/// indents a continued pipeline under its head and the book does not, and
/// they are still the same program. The WIDTH CANON (2026-09-09) made the
/// line break the second half — the printer breaks a statement past 88
/// columns and leaves it alone under, so the same program is one line here
/// and four there depending on how long its paths happen to be. Joining with
/// a space rebuilds the flat spelling exactly, because a continuation always
/// begins `| ` and the canon puts one space either side of a pipe.
///
/// (Before this, a `\n` was kept and `shared_rows` held flat one-liners — so
/// bringing the manual to the canon would have "drifted" every wrapped row
/// away from a book cell that had not changed at all.)
fn addStatements(arena: std.mem.Allocator, src: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    var have = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (line[0] == '|' and have) {
            try cur.append(arena, ' ');
            try cur.appendSlice(arena, line);
            continue;
        }
        if (have) try out.append(arena, try arena.dupe(u8, cur.items));
        cur = .empty;
        have = true;
        try cur.appendSlice(arena, line);
    }
    if (have) try out.append(arena, try arena.dupe(u8, cur.items));
}

/// Every statement printed in a ```rill block of `doc`.
fn manualStatements(arena: std.mem.Allocator, doc: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, doc, pos, "```rill\n")) |start| {
        const body = start + "```rill\n".len;
        const end = std.mem.indexOfPos(u8, doc, body, "```") orelse return error.TestUnexpectedResult;
        try addStatements(arena, doc[body..end], out);
        pos = end;
    }
}

/// Every statement of every program cell in the book.
fn bookStatements(arena: std.mem.Allocator, doc_src: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const parsed = try std.json.parseFromSlice(BookDoc, arena, doc_src, .{ .ignore_unknown_fields = true });
    for (parsed.value.cells) |cell| {
        if (cell.markdown) continue;
        try addStatements(arena, cell.source, out);
    }
}

fn containsStatement(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

test "the manual is the source and the book cites it: shared programs are identical" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var man: std.ArrayListUnmanaged([]const u8) = .empty;
    var book: std.ArrayListUnmanaged([]const u8) = .empty;
    try manualStatements(arena, @embedFile("rill-manual.md"), &man);
    try bookStatements(arena, @embedFile("idioms.rillbook"), &book);

    // Neither extractor may go quiet. A fence rename or a JSON drift would
    // empty one side, and an empty side makes every check below vacuously
    // true — which is exactly how a gate stops watching without saying so.
    try testing.expect(man.items.len > 50);
    try testing.expect(book.items.len > 50);

    // (1) Every listed row is still in both files, byte for byte.
    for (shared_rows) |row| {
        const in_manual = containsStatement(man.items, row);
        const in_book = containsStatement(book.items, row);
        if (in_manual and in_book) continue;
        if (in_book) {
            std.debug.print(
                \\the manual and the book have DRIFTED on a shared program:
                \\  {s}
                \\It is in idioms.rillbook and no longer in rill-manual.md.
                \\The manual is the source. If the manual changed on purpose,
                \\update the book cell to cite it; if this row is no longer
                \\shared, take it off `shared_rows`.
                \\
            , .{row});
        } else if (in_manual) {
            std.debug.print(
                \\the manual and the book have DRIFTED on a shared program:
                \\  {s}
                \\It is in rill-manual.md and no longer in idioms.rillbook.
                \\The manual is the source, so the book cell is what to fix.
                \\
            , .{row});
        } else {
            std.debug.print("'{s}' is on `shared_rows` and is in neither file\n", .{row});
        }
        return error.TestUnexpectedResult;
    }

    // (2) …and the list COVERS every statement the two files share. Chris's
    // requirement, and the half that keeps the list from being a snapshot of
    // whatever was true the day it was written.
    for (book.items) |stmt| {
        if (!containsStatement(man.items, stmt)) continue;
        if (containsStatement(&shared_rows, stmt)) continue;
        std.debug.print(
            \\rill-manual.md and idioms.rillbook now share a program that
            \\`shared_rows` does not name:
            \\  {s}
            \\Add it, so the two copies cannot drift apart unnoticed.
            \\
        , .{stmt});
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// The operator index gate (envelopes campaign item 2, 2026-08-26).
//
// Asked for by name at the tier-2 re-probe: *"an alphabetical operator index
// with arity and port order. The tables are scattered across §6b, §6c, §6d,
// §6f and §7 and cover maybe half the operators actually used in examples."*
// They were being generous — when §12 was written, twenty-two registered
// operators appeared NOWHERE in the human manual, `changed`, `latch`, `merge`,
// `mod`, `atan2` and every trig function among them.
//
// The agent manual is gated by `manual parity` because it promises to list the
// vocabulary. §12 makes the human manual promise the same thing, so it is
// gated the same way — both directions — plus the part that is new here: the
// index prints an ARITY, and an arity that drifts is worse than no arity,
// because it reads like a fact. So the middle column is parsed and checked
// against the registry declaration slot by slot: port order, optionality,
// keywords, flags, section bodies, variadics.
//
// What §12 claims, and therefore what is gated, is arity and port order — NOT
// surface syntax. Statics are written where their own section shows them
// (`set plane.a 1`, `cast $alarm radius 30 at <ref>`) and are listed after the
// ports so the arity reads at a glance. Gate the property the doc claims.
// ---------------------------------------------------------------------------

/// One argument slot as the index prints it.
const SigKind = enum { slot, flag, body, variadic };
const SigItem = struct {
    kind: SigKind,
    name: []const u8 = "", // slot: the name inside `<…>`, sigil included; flag: the word
    optional: bool = false, // written inside `[…]`
    kw: []const u8 = "", // the keyword written before it, if any
};

/// Parse a printed signature — `ease <in> <tau> [up <up>] [down <down>]` — into
/// its ordered items. Returns the op name through `name_out`.
fn parseSignature(gpa: std.mem.Allocator, sig: []const u8, name_out: *[]const u8) ![]SigItem {
    var items: std.ArrayListUnmanaged(SigItem) = .empty;
    errdefer items.deinit(gpa);
    var depth: usize = 0;
    var pending_kw: []const u8 = "";

    // The operator name is the first whitespace-delimited token and is taken
    // whole, before any scanning: six operators are spelled in the same
    // punctuation the slot syntax uses (`<`, `<=`, `>=`, `!=`), and a scanner
    // that met `< <a> <b>` character by character read the comparator as an
    // unterminated slot and reported the arity of nothing.
    const head = std.mem.indexOfScalar(u8, sig, ' ') orelse sig.len;
    name_out.* = sig[0..head];
    if (name_out.*.len == 0) return error.StrayWord;

    var i: usize = head;
    while (i < sig.len) {
        const c = sig[i];
        switch (c) {
            ' ' => i += 1,
            '[' => {
                depth += 1;
                i += 1;
            },
            ']' => {
                if (depth == 0) return error.UnbalancedBracket;
                depth -= 1;
                i += 1;
            },
            '<' => {
                const j = std.mem.indexOfScalarPos(u8, sig, i, '>') orelse return error.UnclosedSlot;
                try items.append(gpa, .{ .kind = .slot, .name = sig[i + 1 .. j], .optional = depth > 0, .kw = pending_kw });
                pending_kw = "";
                i = j + 1;
            },
            '(' => {
                const j = std.mem.indexOfScalarPos(u8, sig, i, ')') orelse return error.UnclosedSlot;
                try items.append(gpa, .{ .kind = .body, .optional = depth > 0, .kw = pending_kw });
                pending_kw = "";
                i = j + 1;
            },
            else => {
                // `…` is the variadic marker; anything else is a word, and a
                // word is either the op name, a keyword introducing the next
                // slot, or — alone inside brackets — a bare-word flag.
                if (std.mem.startsWith(u8, sig[i..], "…")) {
                    try items.append(gpa, .{ .kind = .variadic });
                    i += 3;
                    continue;
                }
                var k = i;
                while (k < sig.len and sig[k] != ' ' and sig[k] != '[' and sig[k] != ']' and sig[k] != '<' and sig[k] != '(') k += 1;
                const word = sig[i..k];
                // Lookahead decides which of the two a word is, and there is
                // no third: a keyword is followed by what it introduces.
                var m = k;
                while (m < sig.len and sig[m] == ' ') m += 1;
                if (m < sig.len and (sig[m] == '<' or sig[m] == '(')) {
                    pending_kw = word;
                } else if (depth > 0 and m < sig.len and sig[m] == ']') {
                    try items.append(gpa, .{ .kind = .flag, .name = word, .optional = true });
                } else {
                    return error.StrayWord;
                }
                i = k;
            },
        }
    }
    if (depth != 0) return error.UnbalancedBracket;
    return items.toOwnedSlice(gpa);
}

/// The items the registry says an operator has, in the order §12 prints them:
/// ports, then statics, then the body, then the variadic marker.
fn declaredItems(gpa: std.mem.Allocator, def: *const registry.OpDef) ![]SigItem {
    var items: std.ArrayListUnmanaged(SigItem) = .empty;
    errdefer items.deinit(gpa);
    for (def.inputs) |pt| {
        try items.append(gpa, .{ .kind = .slot, .name = pt.name, .optional = pt.optional, .kw = if (pt.kw) pt.name else "" });
    }
    for (def.statics) |s| {
        if (s.flag) {
            try items.append(gpa, .{ .kind = .flag, .name = s.name, .optional = true });
            continue;
        }
        const sigil: []const u8 = switch (s.kind) {
            .channel => "$",
            .subject => "@",
            .condition => "#",
            else => "",
        };
        try items.append(gpa, .{
            .kind = .slot,
            .name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ sigil, s.name }),
            .optional = s.optional,
            .kw = if (s.kw) s.name else "",
        });
    }
    if (def.body > 0) try items.append(gpa, .{ .kind = .body, .optional = def.body_kw.len > 0, .kw = def.body_kw });
    if (def.variadic) try items.append(gpa, .{ .kind = .variadic });
    return items.toOwnedSlice(gpa);
}

/// Two slots — one printed, one declared — are the same slot.
///
/// Named rather than written inline in the loop below, because the ledger's
/// first line applies to it: a gate asserting "A rather than B" must RUN
/// somewhere A ≠ B. The corpus never differs (the corpus is the thing that
/// agrees), so dropping a clause from this comparison changed nothing and the
/// mutation survived. Extracted, it is witnessed one axis at a time in the
/// parser's own test.
fn sameItem(a: SigItem, b: SigItem) bool {
    return a.kind == b.kind and std.mem.eql(u8, a.name, b.name) and
        a.optional == b.optional and std.mem.eql(u8, a.kw, b.kw);
}

/// The rows of §12, in printed order, with the backticks stripped.
const IndexRow = struct { name: []const u8, sig: []const u8 };

fn indexRows(gpa: std.mem.Allocator, doc: []const u8) ![]IndexRow {
    var rows: std.ArrayListUnmanaged(IndexRow) = .empty;
    errdefer rows.deinit(gpa);

    const heading = "## 12. The operator index";
    const start = std.mem.indexOf(u8, doc, heading) orelse return error.NoIndex;
    var lines = std.mem.splitScalar(u8, doc[start..], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        var cells = std.mem.splitScalar(u8, line[1..], '|');
        const c0 = std.mem.trim(u8, cells.next() orelse continue, " ");
        const c1 = std.mem.trim(u8, cells.next() orelse continue, " ");
        if (c0.len < 3 or c1.len < 3) continue;
        try rows.append(gpa, .{ .name = std.mem.trim(u8, c0, "`"), .sig = std.mem.trim(u8, c1, "`") });
    }
    return rows.toOwnedSlice(gpa);
}

test "the operator index: every operator is listed once, alphabetically, and nothing else is" {
    const gpa = testing.allocator;
    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    const rows = try indexRows(gpa, @embedFile("rill-manual.md"));
    defer gpa.free(rows);

    // Every registered operator appears, unless it is untaught substrate —
    // the same list the agent manual's parity gate keeps, so the two manuals
    // cannot disagree about what a reader is meant to be able to write.
    for (reg.ops.items) |def| {
        const substrate = for (untaught_substrate) |u| {
            if (std.mem.eql(u8, u.name, def.name)) break true;
        } else false;
        var seen: usize = 0;
        for (rows) |r| {
            if (std.mem.eql(u8, r.name, def.name)) seen += 1;
        }
        if (substrate and seen != 0) {
            std.debug.print("'{s}' is untaught substrate and is in the index\n", .{def.name});
            return error.TestUnexpectedResult;
        }
        if (!substrate and seen != 1) {
            std.debug.print("'{s}' appears {d} time(s) in the operator index, want 1\n", .{ def.name, seen });
            return error.TestUnexpectedResult;
        }
    }
    // …and the other way: no row invents an operator. A word that used to
    // exist is the worst kind of index entry — the re-probe found a manual
    // describing `last`, which had never been built.
    for (rows) |r| {
        if (reg.find(r.name) == null) {
            std.debug.print("the operator index lists '{s}', which is not registered\n", .{r.name});
            return error.TestUnexpectedResult;
        }
    }
    // Alphabetical is the index's only navigational promise. Byte order, so
    // the comparators sort ahead of the words and stay together.
    var prev: []const u8 = "";
    for (rows) |r| {
        if (prev.len > 0 and !std.mem.lessThan(u8, prev, r.name)) {
            std.debug.print("the index is out of order: '{s}' follows '{s}'\n", .{ r.name, prev });
            return error.TestUnexpectedResult;
        }
        prev = r.name;
    }
}

test "the operator index: every section it points at exists" {
    // The third column sends the reader somewhere. §5a was in the first draft
    // of this index and there is no §5a — the conjunction idiom is taught in
    // §6a, and the wrong pointer was written from memory of the AGENT manual,
    // which numbers its sections differently. A cross-reference is a claim.
    const doc = @embedFile("rill-manual.md");
    const start = std.mem.indexOf(u8, doc, "## 12. The operator index").?;
    var seen: usize = 0;
    var i = start;
    while (std.mem.indexOfPos(u8, doc, i, "§")) |at| {
        var k = at + 2; // `§` is two bytes
        while (k < doc.len and (std.ascii.isAlphanumeric(doc[k]))) k += 1;
        const ref = doc[at + 2 .. k];
        var buf: [32]u8 = undefined;
        const heading = try std.fmt.bufPrint(&buf, "\n## {s}. ", .{ref});
        if (std.mem.indexOf(u8, doc, heading) == null) {
            std.debug.print("the index points at §{s}, which is not a heading\n", .{ref});
            return error.TestUnexpectedResult;
        }
        seen += 1;
        i = k;
    }
    // The pointers are the reason the column is worth reading; an index that
    // quietly stopped carrying them would pass every check above.
    if (seen < 40) {
        std.debug.print("§12 carries only {d} section pointers\n", .{seen});
        return error.TestUnexpectedResult;
    }
}

test "the operator index: every printed arity is the declared one, slot by slot" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    const rows = try indexRows(gpa, @embedFile("rill-manual.md"));
    defer gpa.free(rows);

    for (rows) |r| {
        const def = reg.get(reg.find(r.name).?);
        var printed_name: []const u8 = "";
        const printed = parseSignature(arena, r.sig, &printed_name) catch |e| {
            std.debug.print("'{s}': signature `{s}` does not parse ({s})\n", .{ r.name, r.sig, @errorName(e) });
            return error.TestUnexpectedResult;
        };
        const want = try declaredItems(arena, def);

        if (!std.mem.eql(u8, printed_name, def.name)) {
            std.debug.print("'{s}': the signature opens with '{s}'\n", .{ r.name, printed_name });
            return error.TestUnexpectedResult;
        }
        if (printed.len != want.len) {
            std.debug.print("'{s}': the index prints {d} slot(s), the registry declares {d}\n", .{ r.name, printed.len, want.len });
            return error.TestUnexpectedResult;
        }
        for (printed, want, 0..) |got, exp, i| {
            if (!sameItem(got, exp)) {
                std.debug.print("'{s}' slot {d}: index says {s} '{s}'{s}{s}{s}, registry says {s} '{s}'{s}{s}{s}\n", .{
                    r.name,                                i,
                    @tagName(got.kind),                    got.name,
                    if (got.optional) " optional" else "", if (got.kw.len > 0) " kw " else "",
                    got.kw,                                @tagName(exp.kind),
                    exp.name,                              if (exp.optional) " optional" else "",
                    if (exp.kw.len > 0) " kw " else "",    exp.kw,
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the operator index: the signature parser reads what the index writes" {
    // The gate above is only as good as this parser, and a parser that
    // silently drops what it does not understand would report a perfect index
    // forever. So: the four shapes it must read, and the three it must refuse.
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var name: []const u8 = "";

    const items = try parseSignature(arena, "sort <in> [desc] [by (…)]", &name);
    try testing.expectEqualStrings("sort", name);
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("in", items[0].name);
    try testing.expect(!items[0].optional);
    try testing.expectEqualStrings("desc", items[1].name);
    try testing.expect(items[1].optional);
    try testing.expectEqual(SigKind.body, items[2].kind);
    try testing.expectEqualStrings("by", items[2].kw);

    const kw = try parseSignature(arena, "ease <in> <tau> [up <up>]", &name);
    try testing.expectEqualStrings("up", kw[2].kw);
    try testing.expect(kw[2].optional);
    try testing.expectEqualStrings("", kw[1].kw);

    // …and the comparison the gate is built on, one axis at a time. Every one
    // of these differs; none of them can differ in the manual, which is why
    // they are here and not there.
    const slot = SigItem{ .kind = .slot, .name = "n" };
    try testing.expect(sameItem(slot, slot));
    try testing.expect(!sameItem(slot, .{ .kind = .flag, .name = "n" }));
    try testing.expect(!sameItem(slot, .{ .kind = .slot, .name = "m" }));
    try testing.expect(!sameItem(slot, .{ .kind = .slot, .name = "n", .optional = true }));
    try testing.expect(!sameItem(slot, .{ .kind = .slot, .name = "n", .kw = "from" }));

    try testing.expectError(error.UnbalancedBracket, parseSignature(arena, "x [<a>", &name));
    try testing.expectError(error.UnclosedSlot, parseSignature(arena, "x <a", &name));
    try testing.expectError(error.StrayWord, parseSignature(arena, "x <a> nonsense", &name));
}

// ── §6a: the intent table, gated on the DECISION rather than on coverage ────
//
// The gap this closes, stated plainly: `kick`, `adsr`, `step` and `below`
// landed in the envelopes campaign with §12 index rows, worked examples and
// gates — and not one of them reached §6a, the "when you think… / write…"
// table a reader meets first. The fork that CAUSED that campaign had said so
// itself ("§6a has a row for *make it breathe* and none for *kick this and let
// it fall*"), and the row still went missing.
//
// §12 is gated on exhaustiveness because it PROMISES to list the vocabulary.
// §6a promises nothing of the kind — it is curated, its unit is an intent
// rather than an operator, and several of its rows name no operator at all.
// Exhaustiveness here would be the wrong assertion: it would force a row for
// `sqrt`.
//
// So this gates the moment of CHOOSING instead. Every taught operator either
// appears in §6a, or is named below with the reason it does not. Adding a word
// fails the build until one of those is true — which is the one moment the
// question is live.
//
// The honest objection, recorded rather than argued away: a list like this
// invites rubber-stamping, and nothing here can tell a considered exemption
// from a lazy one. True. The pass condition is only "somebody typed this word
// in one of two places" — weak, but not vacuous, and strictly better than what
// four words actually got. Ruled 2026-08-26.

/// Taught operators that §6a deliberately does not carry a row for. Grouped by
/// the reason, because the reason is the thing being asserted.
const intent_exempt = [_][]const u8{
    // The MATH family. §6a teaches the family in one row — "math is elementwise
    // over records and arrays; there is no vector family to learn" — and a
    // reader reaching for `sqrt` is reaching for a function, not for an idiom.
    // A row each would drown the table's 35 intents in 20 arithmetic entries.
    "abs",   "ceil",   "cos",    "div",    "exp",        "floor",     "fract",    "log",    "min",    "mod",
    "pow",   "round",  "sign",   "sin",    "sqrt",       "sub",       "tan",      "atan2",  "pi",     "tau",

    // The COMPARATOR family. "is it dark?" vs "did it get dark?" teaches the
    // whole family and the state/event distinction that is the actual lesson;
    // `above`/`below` earned their own row only because hysteresis is a
    // separate idea a comparator cannot express.
    "!=",    "<=",     "=",      ">",      ">=",

    // Collection SHAPING. §6a's array rows teach the two things that surprise
    // — broadcasting is map, and an array literal is live and immutable — and
    // the rest read off their own names. Candidates for promotion if a reader
    // ever reaches for them and misses: `keep`, `map`, `sort`, `reduce`.
            "first",     "last",     "len",    "take",   "keep",
    "map",   "sort",   "reduce", "stats",  "partition",  "transpose", "shuffle",  "sample", "record",

    // SPATIAL helpers. Ordinary functions of positions and directions; nothing
    // about reaching for them needs unlearning, which is what §6a is for.
    // (`dot` and `nearest` are NOT here — each carries an intent row, because
    // each replaced a wrong instinct: projection spelled longhand, and a
    // position where a parameter was wanted.) `angle`, `inside` and `cross`
    // joined 2026-08-29 by the same test: a reader reaching for them is
    // reaching for a function they already know the name of.
    "distance",
    "along", "within", "angle",  "inside", "cross",

    // Time, rate and LATCHING. `cooldown`, `throttle` and `hold` are named for
    // what they do to a stream; `arm`/`disarm`/`toggle`/`latch` are the state
    // family §7 teaches together, and splitting one out would teach it worse.
         "cooldown",  "throttle", "hold",   "edge",   "changed",
    "latch", "toggle", "arm",    "disarm", "rose_above", "frame",     "wave",

    // CONTRACTS and instruments. `expect`/`match` are author-side assertions
    // and `tap`/`tally` are for looking at a running program — none of them is
    // a way of thinking about a problem, which is the table's whole subject.
        "expect", "match",  "tap",
    "tally", "const",

    // CONDITIONALS whose row points elsewhere ON PURPOSE. "when X, and Y holds"
    // answers with "the conjunction idiom, below" rather than a spelling,
    // because the idiom is several lines and compressing it into a cell taught
    // it wrong — `where` is spelled out in full there. `select` is covered by
    // "conditions flow; the threshold IS the if". `pulse` is the periodic
    // sibling the `kick` row names as the WRONG answer, and `every` carries the
    // metronome it belongs beside.
     "where",  "select", "pulse",

    // The rest, individually: `untag` is the other half of the `tag` row;
    // `clamp` is named in the `range` row's reason; `shape` and `merge` are
    // plumbing between shapes; `rand` sits under the `choose` row.
         "untag",     "clamp",    "shape",  "merge",  "rand",
};

/// Every operator name that appears inside a backticked span in §6a's table.
/// Backticks only, on purpose: the table's third column is prose ABOUT the
/// operators ("broadcasting over an array IS map"), and a word discussed in
/// passing is not a row. A spelling a reader can copy lives in backticks.
fn intentTableWords(gpa: std.mem.Allocator, doc: []const u8) !std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, doc, '\n');
    var in_table = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "| when you think")) {
            in_table = true;
            continue;
        }
        if (!in_table) continue;
        if (line.len == 0 or line[0] != '|') break; // the table ended
        if (std.mem.indexOf(u8, line, "|---") != null) continue;

        // The MIDDLE column only — the one that says what to write. Splitting
        // the row into cells on unescaped pipes, because the third column is
        // prose ABOUT operators and name-drops them in backticks: the `kick`
        // row's reason mentions `pulse` and `ease`, and an earlier draft of
        // this parser scanned the whole row and therefore counted `pulse` as
        // taught by a sentence explaining why it is the WRONG answer. The
        // comment above said middle-column; the code did not, and only removing
        // the kick row to check the gate bit revealed it — it reported `pulse`.
        var cells: [8][]const u8 = undefined;
        var ncells: usize = 0;
        var cell_start: usize = 0;
        var k: usize = 0;
        while (k < line.len) : (k += 1) {
            // += 1 here AND in the loop's continue expression: two characters,
            // the backslash and the pipe it escapes. Skipping only one left the
            // escaped pipe to be read as a cell separator, which truncated every
            // cell containing a `\|` — the middle column of most rows.
            if (line[k] == '\\') {
                k += 1;
                continue;
            }
            if (line[k] != '|') continue;
            if (ncells < cells.len) {
                cells[ncells] = line[cell_start..k];
                ncells += 1;
            }
            cell_start = k + 1;
        }
        if (ncells < 3) continue; // cells[0] is the empty piece before the leading '|'
        const line_cell = cells[2];

        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line_cell, i, '`')) |open| {
            const close = std.mem.indexOfScalarPos(u8, line_cell, open + 1, '`') orelse break;
            const span = line_cell[open + 1 .. close];
            // `\|` is an escaped pipe inside a cell, and it is also the pipe an
            // author copies. Treat it as a separator like any other.
            var t: usize = 0;
            while (t < span.len) {
                while (t < span.len and (std.mem.indexOfScalar(u8, " \t\\|(){}[],", span[t]) != null)) t += 1;
                const start = t;
                while (t < span.len and std.mem.indexOfScalar(u8, " \t\\|(){}[],", span[t]) == null) t += 1;
                if (t > start) try out.put(gpa, span[start..t], {});
            }
            i = close + 1;
        }
    }
    return out;
}

test "§6a: every taught operator is in the intent table, or is named as not belonging there" {
    const gpa = testing.allocator;
    var reg = try rill.Registry.init(gpa);
    defer reg.deinit();
    try rill.registerCore(&reg);

    var words = try intentTableWords(gpa, @embedFile("rill-manual.md"));
    defer words.deinit(gpa);

    // Rule 1: the table must have been FOUND. A parser that silently matched
    // nothing would make every operator "not covered", the exempt list would
    // then be wrong for 36 words, and the failure would look like a doc problem
    // rather than a parser one. Assert the precondition before the claim.
    try testing.expect(words.count() > 20);

    for (reg.ops.items) |def| {
        const substrate = for (untaught_substrate) |u| {
            if (std.mem.eql(u8, u.name, def.name)) break true;
        } else false;
        if (substrate) continue; // never taught, so never an intent

        const covered = words.contains(def.name);
        var exempt = false;
        for (intent_exempt) |e| {
            if (std.mem.eql(u8, e, def.name)) exempt = true;
        }

        if (!covered and !exempt) {
            std.debug.print(
                \\'{s}' is taught, and §6a's table neither carries it nor excuses it.
                \\
                \\Decide which, in `docs/rill-manual.md` §6a or in `intent_exempt`:
                \\  - a reader who wants '{s}' arrives KNOWING WHAT THEY WANT and not
                \\    what to write ⇒ it wants a row: the intent, the spelling, and
                \\    the thing that has to be unlearned;
                \\  - or it reads off its own name, or its family already has a row
                \\    ⇒ add it to the group in `intent_exempt` whose reason fits.
                \\
            , .{ def.name, def.name });
            return error.TestUnexpectedResult;
        }
        if (covered and exempt) {
            std.debug.print("'{s}' is in §6a AND in intent_exempt — the list has gone stale\n", .{def.name});
            return error.TestUnexpectedResult;
        }
    }

    // The list cannot outlive its words either. An exemption for an operator
    // that no longer exists is a decision about nothing, and it is exactly what
    // a rubber-stamped list rots into.
    for (intent_exempt) |e| {
        if (reg.find(e) == null) {
            std.debug.print("intent_exempt names '{s}', which is not a registered operator\n", .{e});
            return error.TestUnexpectedResult;
        }
    }
}

// ── an elementwise operator carries the kind it is piped ───────────────────

/// The slot kind of a node's first output, by node name.
fn outKind(prog: *const rill.Program, node: []const u8) registry.PortKind {
    const n = prog.node(nodeIdOf(prog, node).?);
    return prog.slot(n.outputs[0]).kind;
}

test "elementwise: an occurrence through `mul` is still an occurrence" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.in | rose_above 0.5 | mul 2 | kick 15ms 150ms | write plane.out
    , &diag);
    defer prog.deinit();

    // Rule 1: the two kinds must genuinely differ here, or this passes on an
    // implementation that makes every slot an occurrence.
    try testing.expectEqual(registry.PortKind.occurrence, outKind(&prog, "rose_above1"));
    try testing.expectEqual(registry.PortKind.occurrence, outKind(&prog, "mul1"));
    const declared = reg.get(reg.find("mul").?).outputs[0].kind;
    try testing.expectEqual(registry.PortKind.value, declared);
}

test "elementwise: a value through `mul` stays a value" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.hp | clamp 0 100 as hp
        \\hp | mul 2 | write plane.out
    , &diag);
    defer prog.deinit();
    // Carrying the kind must not INVENT one: a value chain is still a value
    // chain, and `emitSlot`'s "20 to 20 is silence" must still hold for it.
    try testing.expectEqual(registry.PortKind.value, outKind(&prog, "mul1"));
    try testing.expectEqual(registry.PortKind.value, outKind(&prog, "clamp1"));
}

test "elementwise: the kind carries down a CHAIN, not just one hop" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.in | rose_above 0.5 | mul 2 | add 1 | abs | write plane.out
    , &diag);
    defer prog.deinit();
    // Node ids are topological, so one forward pass reaches the end. If it did
    // not, `abs` would be the value that swallows the repeat instead of `mul`.
    try testing.expectEqual(registry.PortKind.occurrence, outKind(&prog, "mul1"));
    try testing.expectEqual(registry.PortKind.occurrence, outKind(&prog, "add1"));
    try testing.expectEqual(registry.PortKind.occurrence, outKind(&prog, "abs1"));
}

test "elementwise: a LITERAL-fed operator stays a value" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\const 3 | mul 2 | write plane.out
    , &diag);
    defer prog.deinit();
    try testing.expectEqual(registry.PortKind.value, outKind(&prog, "mul1"));
}

test "elementwise: the repeat SURVIVES — the flash fires every press, not once" {
    // The gate this whole ruling was bought with. Chris bound a muzzle flash to
    // a mouse button, then made the obvious edit — "I wanted the flash
    // brighter" — and it fired exactly once per mount thereafter, silently.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.in", @as(i64, 0));
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.in | rose_above 0.5 | mul 2 | kick 15ms 150ms as env
    , &diag);
    defer prog.deinit();
    const t0: u64 = 1000 * std.time.ns_per_s;
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .now = .{ .time_ns = t0 } });
    defer rt.deinit();
    const out = "programs.p.kick1.out.out";

    var t = t0;
    var peaks: [3]f64 = .{ 0, 0, 0 };
    for (&peaks) |*peak| {
        try feedValue(&rt, testing.allocator, "plane.in", @as(i64, 1));
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            t += 16 * ms;
            try rt.tick(.{ .time_ns = t });
            peak.* = @max(peak.*, types.asNumber(rt.readSlot(out) orelse "") orelse 0);
        }
        try feedValue(&rt, testing.allocator, "plane.in", @as(i64, 0));
        i = 0;
        while (i < 18) : (i += 1) {
            t += 16 * ms;
            try rt.tick(.{ .time_ns = t });
            peak.* = @max(peak.*, types.asNumber(rt.readSlot(out) orelse "") orelse 0);
        }
    }
    // Rule 1: the first must fire, or "every press" is vacuous. The ones after
    // it are the actual claim — before the ruling they were all zero.
    try testing.expect(peaks[0] > 0.5);
    try testing.expect(peaks[1] > 0.5);
    try testing.expect(peaks[2] > 0.5);
    // ...and to the same height, so these are three flashes rather than one
    // that never ended.
    try testing.expectApproxEqAbs(peaks[0], peaks[1], 1e-9);
    try testing.expectApproxEqAbs(peaks[0], peaks[2], 1e-9);
}

test "elementwise: a dumped program carries the same kinds when it is loaded" {
    // `finalize` runs on BOTH paths — parse and load — so a restored program
    // must not quietly become a value chain again. The kind is DERIVED rather
    // than serialised, which is why this is worth asserting.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    const src = "plane.in | rose_above 0.5 | mul 2 | kick 15ms 150ms | write plane.out";
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    try testing.expectEqual(registry.PortKind.occurrence, outKind(&prog, "mul1"));

    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    const dumped = try rill.serialize.dump(&rt, testing.allocator);
    defer testing.allocator.free(dumped);
    var loaded = try rill.serialize.loadProgram(testing.allocator, &reg, dumped);
    defer loaded.deinit();
    try testing.expectEqual(registry.PortKind.occurrence, outKind(&loaded, "mul1"));
}

test "a refusal reaches the error hook with the PORT that minded, in words" {
    // What `rill-run` prints, and what makes a dead chain diagnosable. A
    // control on the plane is a NUMBER and `select`'s condition is a boolean,
    // so this refuses every tick — and the symptom is a program that mounts
    // cleanly, reports its node count, and quietly writes nothing.
    //
    // The words are the gate. "BadValue" names a category; a person needs the
    // PORT and the operator, which is what turns ten minutes of splitting a
    // chain apart into reading one line.
    const Seen = struct {
        var n: usize = 0;
        var node: [64]u8 = undefined;
        var node_len: usize = 0;
        var detail: [160]u8 = undefined;
        var detail_len: usize = 0;
        fn hook(_: ?*anyopaque, ev: rill.eval.ErrorEvent) void {
            n += 1;
            node_len = @min(ev.node.len, node.len);
            @memcpy(node[0..node_len], ev.node[0..node_len]);
            detail_len = @min(ev.detail.len, detail.len);
            @memcpy(detail[0..detail_len], ev.detail[0..detail_len]);
        }
    };
    Seen.n = 0;

    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.n", @as(i64, 1));
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.n | select 5 9 | write plane.out
    , &diag);
    defer prog.deinit();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .error_fn = Seen.hook });
    defer rt.deinit();
    try feedValue(&rt, testing.allocator, "plane.n", @as(i64, 2));
    try rt.tick(.{});

    try testing.expect(Seen.n > 0);
    try testing.expectEqualStrings("select1", Seen.node[0..Seen.node_len]);
    // Names the port, not just the category — that is the whole value.
    const d = Seen.detail[0..Seen.detail_len];
    try testing.expect(std.mem.indexOf(u8, d, "cond") != null);
    try testing.expect(std.mem.indexOf(u8, d, "boolean") != null);
}

// ---------------------------------------------------------------------------
// The row-column audit (spindrift beat 1, ruled 2026-09-01). `OpDef.row` says
// whether an op can be evaluated once per row of a population, and its
// exactness bit is EARNED — the result is defined by integer arithmetic only.
// Exhaustive both ways, like the class, ticks and fails_mount audits: every
// row-legal core op is on this list, every listed op is row-legal, and every
// legal one is exact — because v1's row-legal set IS the exact set, and a
// kernel that was legal without being exact would make G7 a tolerance gate.
// ---------------------------------------------------------------------------

const row_legal_core = [_][]const u8{
    // the four, outright
    "add",    "sub",  "mul",     "div",
    // integer-defined arithmetic
    "min",    "max",  "clamp",   "abs",
    "floor",  "ceil", "round",   "sign",
    "fract",  "mod",
    // fixed-point interpolation — a product and a sum
     "lerp",    "range",
    // the curve sampler: a shift for the segment, a mask for the position
    // within it, and `range`'s arithmetic between two knots
    "over",
    // logic and comparison
    "select", "and",  "or",      "not",
    "=",      "!=",   "<",       "<=",
    ">",      ">=",
    // the vec3 shape, and the sink
      "project", "record",
    "write",
};

test "the row column: every row-legal core op is listed, every listed op is row-legal, and legal means exact" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);

    for (row_legal_core) |name| {
        const id = reg.find(name) orelse {
            std.debug.print("'{s}' is on the row-legal roster and is not registered\n", .{name});
            return error.TestUnexpectedResult;
        };
        const def = reg.get(id);
        if (!def.row.legal()) {
            std.debug.print("'{s}' is on the row-legal roster and its column says no\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    var legal: usize = 0;
    for (reg.ops.items) |def| {
        if (def.row.eval == null) {
            // No kernel, no legality — and no half-answer: an op with no
            // kernel must not claim exactness or channels either.
            if (def.row.exact or def.row.channels != 0) {
                std.debug.print("'{s}' has no row kernel and still declares exact/channels\n", .{def.name});
                return error.TestUnexpectedResult;
            }
            continue;
        }
        legal += 1;
        if (!def.row.exact) {
            std.debug.print("'{s}' has a row kernel that is not exact — v1's row-legal set is the exact set\n", .{def.name});
            return error.TestUnexpectedResult;
        }
        if (def.row.only) {
            std.debug.print("'{s}' is core and declares row-only — core words mean something on the plane\n", .{def.name});
            return error.TestUnexpectedResult;
        }
        const listed = for (row_legal_core) |name| {
            if (std.mem.eql(u8, name, def.name)) break true;
        } else false;
        if (!listed) {
            std.debug.print("'{s}' is row-legal and not on the roster — add it, with its reason\n", .{def.name});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(row_legal_core.len, legal);
}

test "the row head: `row.x` is a subscription like `plane.x`, `row` is reserved, and a bare field is a loud unknown" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "k", "row.vel | mul 2 | write row.pos", &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.subs.items.len);
    try testing.expectEqualStrings("row.vel", prog.subs.items[0].path);
    try testing.expectEqual(@as(usize, 1), prog.writes.items.len);
    try testing.expectEqualStrings("row.pos", prog.writes.items[0].path);
    // Bare names are a parse error — the sigil is mandatory.
    try testing.expectError(error.Parse, rill.parse(testing.allocator, &reg, "k", "vel | mul 2 | write row.pos", &diag));
    // …and `row` cannot name an operator, for `plane`'s reason.
    const noop = struct {
        fn f(_: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
            return rill.Emit.none;
        }
    }.f;
    try testing.expectError(error.ReservedName, reg.register(.{ .name = "row", .help = "", .routes = .anywhere, .eval = noop }));
    try testing.expectError(error.ReservedName, reg.register(.{ .name = "row count", .help = "", .routes = .anywhere, .eval = noop }));
}

test "the row head: a row-only word is refused at parse in a plane program, and binds in a kernel" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const noop = struct {
        fn f(_: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
            return rill.Emit.none;
        }
        fn k(_: *rill.row.Ctx) rill.row.Error!void {}
    };
    _ = try reg.register(.{ .name = "gravity_like", .inputs = &.{.{ .name = "g", .ty = rill.Tag.number }}, .help = "", .routes = .anywhere, .row = .{ .exact = true, .only = true, .eval = noop.k }, .eval = noop.f });
    var diag = rill.Diag{};
    // An unfed input would keep a mount-time refusal from ever firing; the
    // parser does not care what is fed.
    try testing.expectError(error.Parse, rill.parse(testing.allocator, &reg, "p", "plane.x | gravity_like", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.msg(), "'gravity_like' is a row word") != null);
    var prog = try rill.parseKernel(testing.allocator, &reg, "k", "plane.x | gravity_like", &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.nodeCount());
}

test "the field read in a kernel: `$wind at row.pos` desugars to the host's `hear`; bare stays a standpoint error; the plane spelling is untouched" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    var diag = rill.Diag{};
    // No host word yet: the read says what is missing.
    try testing.expectError(error.Parse, rill.parseKernel(testing.allocator, &reg, "k", "$wind at row.pos | write row.u0", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.msg(), "no host word `hear`") != null);
    // A host registers `hear` with cast's channel static, a grad flag and a keyword `at`.
    const stub = struct {
        fn f(_: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
            return rill.Emit.none;
        }
        fn k(_: *rill.row.Ctx) rill.row.Error!void {}
    };
    _ = try reg.register(.{
        .name = "hear",
        .statics = &.{ .{ .name = "channel", .kind = .channel }, .{ .name = "grad", .kind = .word, .flag = true, .optional = true } },
        .inputs = &.{.{ .name = "at", .ty = rill.Tag.any, .kw = true }},
        .outputs = &.{.{ .name = "out", .ty = rill.Tag.any }},
        .help = "stub",
        .routes = .anywhere,
        .row = .{ .exact = true, .only = true, .eval = stub.k },
        .eval = stub.f,
    });
    var prog = try rill.parseKernel(testing.allocator, &reg, "k", "$wind grad at row.pos | mul 2 | write row.vel add", &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 3), prog.nodeCount());
    const hear = prog.node(0);
    try testing.expectEqualStrings("hear", reg.get(hear.op).name);
    try testing.expectEqualStrings("$wind", hear.statics[0].channel);
    try testing.expectEqualStrings("grad", hear.statics[1].word);
    try testing.expectEqualStrings("row.pos", prog.subs.items[0].path);
    // Bare in a kernel: the kernel's spelling, in the refusal.
    try testing.expectError(error.Parse, rill.parseKernel(testing.allocator, &reg, "k", "$wind | write row.u0", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.msg(), "'$wind at row.pos'") != null);
    // On the plane: the standpoint ruling as it was, `hear` or no `hear`.
    try testing.expectError(error.Parse, rill.parse(testing.allocator, &reg, "p", "$wind at plane.x | write plane.y", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.msg(), "plane.sensors.<post>.$wind") != null);
}

test "over on the plane: the same knots and the same clamping as a row, and a record ramp" {
    // `over` is core, so it has a plane half as well as a row kernel, and
    // the two must not drift into different pictures of the same curve.
    // Exactness differs by construction — the row is Q16.16 and the plane is
    // IEEE — so what this pins is the STRUCTURE they share: which knots a
    // given t picks, that both ends are exact, and that outside the span
    // both clamp.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.t | over 1 [1, 0.7, 0] | write plane.size
    , .{.{ "plane.t", @as(f64, 0) }});
    defer fx.deinit();

    const at = struct {
        fn f(x: *Fixture, t: f64) !f64 {
            try feedValue(&x.rt, testing.allocator, "plane.t", t);
            try x.rt.tick(.{});
            return types.asNumber(x.mock.writes.items[x.mock.writes.items.len - 1].value).?;
        }
    }.f;

    // t = 0 lands on the first knot exactly.
    try testing.expectEqual(@as(f64, 1), types.asNumber(fx.mock.writes.items[0].value).?);
    // A quarter of the way is halfway along the FIRST of two segments —
    // the segment arithmetic, which is where an off-by-one would show.
    try testing.expectApproxEqAbs(@as(f64, 0.85), try at(&fx, 0.25), 1e-12);
    // Halfway is the middle knot itself, not a point between two.
    try testing.expectEqual(@as(f64, 0.7), try at(&fx, 0.5));
    // …and the far end is exact, as it is on a row.
    try testing.expectEqual(@as(f64, 0), try at(&fx, 1));
    // Outside the span, both directions clamp.
    try testing.expectEqual(@as(f64, 0), try at(&fx, 5));
    try testing.expectEqual(@as(f64, 1), try at(&fx, -2));
}

test "over on the plane: a knot may be a record, and a zero span refuses as it does on a row" {
    // The record half is why the plane's interpolation is three `broadcast2`
    // calls instead of one arithmetic line: `a + (b - a) * frac` written with
    // `num()` would refuse a colour ramp, which is half of what the curve
    // editor exists to author.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.t | over 1 [{x: 1, y: 0, z: 0}, {x: 0, y: 0, z: 1}] | write plane.col
    , .{.{ "plane.t", @as(f64, 0.5) }});
    defer fx.deinit();
    const w = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    const fields = try recordFields(testing.allocator, w.value);
    defer {
        for (fields) |f| testing.allocator.free(f.k);
        testing.allocator.free(fields);
    }
    try testing.expectEqual(@as(usize, 3), fields.len);
    // Canonical (sorted) key order: x, y, z. Each axis moves half way.
    try testing.expectEqualStrings("x", fields[0].k);
    try testing.expectApproxEqAbs(@as(f64, 0.5), fields[0].v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), fields[1].v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), fields[2].v, 1e-12);

    // A zero span refuses rather than dividing to ±inf and clamping the nan
    // that follows — the one place `over` departs from `div`'s IEEE stance,
    // so that a row and the plane cannot disagree about the same curve.
    var fz: Fixture = undefined;
    try mountFixture(testing.allocator, &fz,
        \\plane.t | over 0 [1, 0] | write plane.size
    , .{.{ "plane.t", @as(f64, 0.5) }});
    defer fz.deinit();
    try testing.expectEqual(@as(usize, 0), fz.mock.writes.items.len);
}

// ---------------------------------------------------------------------------
// The RBF pack — `rbf through`, `rbf bump`, and the model underneath them.
//
// The claim these gates exist to hold: **rill's evaluator and loam's are one
// model with two implementations, and they agree to the BIT.** Not to an
// epsilon. An epsilon-gate lets two copies drift in the last places until a
// host that swaps one for the other renders something else and nobody is
// told, which is exactly the failure `spindrift/src/fields.zig` records for
// its own transcribed copy of matryoshka's field model.
// ---------------------------------------------------------------------------

const rbf = rill.rbf;

/// The four kernels of the frozen table, in rill's packing (μ, then L, then w
/// per kernel, laid end to end). They are loam's `Kernel` values term for
/// term:
///
///   0 — isotropic at the origin, nine distinct weights
///   1 — an axis-aligned ellipsoid, off the origin
///   2 — FULLY anisotropic: every off-diagonal of L non-zero and distinct, so
///       a transposed `lIndex` or a swapped term moves the answer
///   3 — the CUTOFF's kernel: isotropic, six units out, weights of 4096 so
///       what it contributes on either side of the test is visible in f32. At
///       q = (0,0,0) its r2 is 36 and it is cut; at q = (0.4,0,0) its r2 is
///       31.36 and it is not. One kernel, both sides of the test — a kernel
///       merely parked far away would have pinned nothing, because exp of a
///       large negative underflows to zero by itself and the cutoff could
///       then be deleted without moving a bit.
const FROZEN_K = [_]f32{
    0,    0,     0,    2.5,  0,     2.5,  0,    0,    2.5, 0.9,  0.81,  0.42,  0.13,  0.77, 0.05,  3.5,   1.25,  0.4,
    0.6,  -0.25, 0.4,  1.25, 0,     3.75, 0,    0,    0.8, 0.55, 0.2,   0.21,  0.24,  0.6,  0.02,  0.15,  0.1,   0.09,
    -0.4, 0.7,   -0.2, 1.7,  -0.65, 2.2,  0.35, -1.1, 3.1, 0.31, 0.66,  0.12,  0.9,   0.28, 0.71,  0.04,  0.5,   0.33,
    6,    0,     0,    1,    0,     1,    0,    0,    1,   4096, -4096, 4096,  -4096, 4096, -4096, 4096,  -4096, 4096,
};

const FrozenRow = struct { q: [3]f32, y: [9]u32 };

/// Generated by running `loam.rbf.Set.eval` over `FROZEN_K` (2026-09-07). The
/// same table lives in `loam/src/rbf.zig`'s own gate. Neither repo depends on
/// the other and neither should — rill is under loam, not beside it — so one
/// table on both sides, failing together, is the only pin available that does
/// not invert the layering to carry a test.
const FROZEN = [_]FrozenRow{
    .{ .q = .{ 0, 0, 0 }, .y = .{ 0x3f9719bb, 0x3f755afc, 0x3f06f871, 0x3ea270b0, 0x3f8917a6, 0x3df4b0ab, 0x4064a756, 0x3fab584d, 0x3ef06de6 } },
    .{ .q = .{ 0.5, 0.5, 0.5 }, .y = .{ 0x3dccb723, 0x3daf4011, 0x3d3c9359, 0x3cbb3ec2, 0x3db4a5f5, 0x3c1d4061, 0x3eae057e, 0x3dff68fb, 0x3d31ccbb } },
    .{ .q = .{ -0.4, 0.7, -0.2 }, .y = .{ 0x3ed44356, 0x3f410015, 0x3e2cd1bd, 0x3f6a4be2, 0x3ebd376b, 0x3f373ed0, 0x3ee3f95a, 0x3f250f9e, 0x3ec0b348 } },
    .{ .q = .{ 0.61, -0.24, 0.39 }, .y = .{ 0x3f3290b5, 0x3ea8c626, 0x3e8f478e, 0x3e84be6a, 0x3f39f37a, 0x3cd8729f, 0x3f384840, 0x3e9a2b7b, 0x3e207eb6 } },
    .{ .q = .{ 1.3, -0.9, 0.15 }, .y = .{ 0x3d7f42f5, 0xbd135878, 0x3d4ecbb2, 0xbd0ec80f, 0x3d830a1d, 0xbd2dc917, 0x3d4b21cc, 0xbd20b3cf, 0x3d3debc2 } },
    .{ .q = .{ 0.4, 0, 0 }, .y = .{ 0x3f61cfa7, 0x3f21009a, 0x3ec460aa, 0x3e7d4456, 0x3f54fe49, 0x3d8041bd, 0x400dad0e, 0x3f54ea78, 0x3e9ce624 } },
    .{ .q = .{ -2, 2, -2 }, .y = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
};

test "rbf: the evaluator is loam's, to the bit" {
    const set = rbf.Set{ .d = 3, .m = 9, .k = &FROZEN_K };
    try testing.expectEqual(@as(usize, 4), set.count());
    for (FROZEN, 0..) |row, r| {
        var y: [9]f32 = undefined;
        rbf.eval(set, &row.q, &y);
        for (y, row.y, 0..) |got, want, c| {
            const bits: u32 = @bitCast(got);
            if (bits != want) {
                std.debug.print("row {d} channel {d}: got 0x{x:0>8} ({d}), loam says 0x{x:0>8}\n", .{ r, c, bits, got, want });
                return error.TestUnexpectedResult;
            }
        }
    }
    // The last row is every kernel beyond the cutoff, and it is exactly +0 —
    // not a denormal residue, not a −0. The shader skips by the same rule and
    // a read out there must be the entry material EXACTLY (loam's own note: "a
    // denormal exp once left 1e-42 of gold on the matrix").
    var far: [9]f32 = undefined;
    rbf.eval(set, &.{ -2, 2, -2 }, &far);
    for (far) |v| try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(v)));
}

test "rbf: a set survives the wire — encode, decode, and the same bits out" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var pk = struple.Packer.init(a);
    try rbf.encode(&pk, a, .{ .d = 3, .m = 9, .k = &FROZEN_K });

    var buf = std.ArrayListUnmanaged(f32).empty;
    var fault: rbf.Fault = .malformed;
    const back = try rbf.decode(a, pk.bytes(), &buf, &fault);
    try testing.expectEqual(@as(u8, 3), back.d);
    try testing.expectEqual(@as(u8, 9), back.m);
    try testing.expectEqualSlices(f32, &FROZEN_K, back.k);

    // …and it evaluates to the frozen bits after the round trip. The wire is
    // f32 both ways, so a set that has been through here once is canonical
    // and compare-and-suppress works on it.
    var y: [9]f32 = undefined;
    rbf.eval(back, &FROZEN[3].q, &y);
    for (y, FROZEN[3].y) |got, want| try testing.expectEqual(want, @as(u32, @bitCast(got)));
}

test "rbf: the word reads what the evaluator reads — the frozen bits through a mounted program" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[plane.s.a, plane.s.b, plane.s.c] | rbf through plane.fire.coat | write plane.fire.y
    , .{
        .{ "plane.fire.coat", .{ .d = @as(i64, 3), .m = @as(i64, 9), .k = FROZEN_K } },
        .{ "plane.s.a", @as(f64, 0.61) },
        .{ "plane.s.b", @as(f64, -0.24) },
        .{ "plane.s.c", @as(f64, 0.39) },
    });
    defer fx.deinit();
    // The seeds are f64 and the query narrows to f32 on the way in, which is
    // what makes 0.61 the same 0.61 the frozen table was generated from.
    const w = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    const inner = try innerOf(testing.allocator, w.value);
    defer testing.allocator.free(inner);
    var r = struple.reader(inner);
    var c: usize = 0;
    while (try r.next()) |e| : (c += 1) {
        try testing.expectEqual(FROZEN[3].y[c], @as(u32, @bitCast(e.float32)));
    }
    try testing.expectEqual(@as(usize, 9), c);
}

test "rbf: kernels authored on the plane, read back through them, and a knob edit moves the answer with no remount" {
    // Christian's stated payoff, as a scene. Two bumps make an appearance
    // manifold — a flame at the origin of (cooled, sooted, thinned) and soot
    // at the far corner — a row's state reads through it, and then the set's
    // own numbers are KNOBS: feeding new ones changes what the row looks like
    // without re-parsing, re-registering or rebuilding anything.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\rbf bump at [0, 0, 0] width plane.knob.hot value [1.0, plane.knob.green, 0.35]
        \\  | rbf bump at [1, 1, 1] width 0.5 value [0.05, 0.05, 0.06] as coat
        \\[plane.s.cooled, plane.s.sooted, plane.s.thinned] | rbf through coat | write plane.look
    , .{
        .{ "plane.knob.hot", @as(f64, 0.4) },
        .{ "plane.knob.green", @as(f64, 0.85) },
        .{ "plane.s.cooled", @as(f64, 0.1) },
        .{ "plane.s.sooted", @as(f64, 0.1) },
        .{ "plane.s.thinned", @as(f64, 0.1) },
    });
    defer fx.deinit();

    const hot = try arrayNums(testing.allocator, fx.mock.writes.items[fx.mock.writes.items.len - 1].value);
    defer testing.allocator.free(hot);
    try testing.expectEqual(@as(usize, 3), hot.len);
    // Near the flame's kernel and far from the soot's: red, and much more red
    // than blue. If `bump` put the width where 1/width belongs, the kernel is
    // 6.25× narrower than asked and this reads near zero instead.
    try testing.expect(hot[0] > 0.9);
    try testing.expect(hot[0] > hot[2] * 2);

    // The row moves through the manifold: the same set, a state at the soot
    // end, a different look. Nothing was remounted.
    try feedValue(&fx.rt, testing.allocator, "plane.s.cooled", @as(f64, 0.95));
    try feedValue(&fx.rt, testing.allocator, "plane.s.sooted", @as(f64, 0.95));
    try feedValue(&fx.rt, testing.allocator, "plane.s.thinned", @as(f64, 0.95));
    try fx.rt.tick(.{});
    const cold = try arrayNums(testing.allocator, fx.mock.writes.items[fx.mock.writes.items.len - 1].value);
    defer testing.allocator.free(cold);
    try testing.expect(cold[0] < 0.1);
    try testing.expect(cold[2] > cold[0]);

    // …and the KNOB. Back to the middle, then widen the flame's kernel: the
    // same query, the same program, a different set, because a number on the
    // plane changed.
    try feedValue(&fx.rt, testing.allocator, "plane.s.cooled", @as(f64, 0.55));
    try feedValue(&fx.rt, testing.allocator, "plane.s.sooted", @as(f64, 0.55));
    try feedValue(&fx.rt, testing.allocator, "plane.s.thinned", @as(f64, 0.55));
    try fx.rt.tick(.{});
    const narrow = try arrayNums(testing.allocator, fx.mock.writes.items[fx.mock.writes.items.len - 1].value);
    defer testing.allocator.free(narrow);

    try feedValue(&fx.rt, testing.allocator, "plane.knob.hot", @as(f64, 1.2));
    try fx.rt.tick(.{});
    const wide = try arrayNums(testing.allocator, fx.mock.writes.items[fx.mock.writes.items.len - 1].value);
    defer testing.allocator.free(wide);
    // Wider kernel, same distance: strictly more of the flame reaches here.
    try testing.expect(wide[0] > narrow[0] * 1.5);

    // And the edit that only FRESHNESS can catch. `rbf through` keeps its
    // decoded kernels in scratch and reuses them while its set port has not
    // changed; a byte-length guard sits beside that check, and the guard alone
    // would have caught every edit above BY ACCIDENT — struple escapes a 0x00
    // inside a container body, so 1/0.4 (0x40200000, three zero bytes) and
    // 1/1.2 (0x3f555555, none) do not even encode to the same length, and the
    // width knob was never testing what it looked like it was testing.
    //
    // 0.85 and 0.35 do encode to the same length: 0x3f59999a and 0x3eb33333,
    // four non-zero bytes each. This set changes without changing size by one
    // byte, so the only thing that can notice is `in_fresh`. The numbers are
    // chosen for that and for nothing else.
    try feedValue(&fx.rt, testing.allocator, "plane.knob.green", @as(f64, 0.35));
    try fx.rt.tick(.{});
    const dimmed = try arrayNums(testing.allocator, fx.mock.writes.items[fx.mock.writes.items.len - 1].value);
    defer testing.allocator.free(dimmed);
    try testing.expect(dimmed[1] < wide[1] * 0.6);
}

test "rbf: the decoded set is a CACHE — it lives in scratch, never in state, and a restore answers the same" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[plane.s.a, plane.s.b, plane.s.c] | rbf through plane.fire.coat | write plane.fire.y
    , .{
        .{ "plane.fire.coat", .{ .d = @as(i64, 3), .m = @as(i64, 9), .k = FROZEN_K } },
        .{ "plane.s.a", @as(f64, 0.5) },
        .{ "plane.s.b", @as(f64, 0.5) },
        .{ "plane.s.c", @as(f64, 0.5) },
    });
    defer fx.deinit();

    const node = nodeIdOf(&fx.prog, "rbf through1").?;
    // The kernels are cached — four kernels of eighteen numbers, plus the
    // six-byte header.
    try testing.expectEqual(@as(usize, 6 + 4 * 18 * 4), fx.rt.node_scratch[node].items.len);
    // …and the node holds NO state. `rbf through` has no history; in
    // `node_state` these bytes would ride every dump of every program that
    // reads a set, which for a fitted 256-kernel set is 18 KB per node of
    // something the inputs already say.
    try testing.expectEqual(@as(usize, 0), fx.rt.node_state[node].items.len);

    const dump1 = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(dump1);

    var prog2 = try rill.loadProgram(testing.allocator, &fx.reg, dump1);
    defer prog2.deinit();
    var mock2 = rill.MockPlane.init(testing.allocator);
    defer mock2.deinit();
    try mock2.putValue("plane.fire.coat", .{ .d = @as(i64, 3), .m = @as(i64, 9), .k = FROZEN_K });
    var rt2 = try rill.Runtime.restore(testing.allocator, &prog2, mock2.asPlane(), .{});
    defer rt2.deinit();
    try rill.restoreState(&rt2, dump1);
    // The restored program comes back with an EMPTY scratch — that is the
    // contract the buffer is under, and the proof it holds nothing the inputs
    // do not already determine.
    try testing.expectEqual(@as(usize, 0), rt2.node_scratch[node].items.len);

    // Drive it: the same set, a new query, and the answer is still loam's.
    try feedValue(&rt2, testing.allocator, "plane.s.a", @as(f64, 0.61));
    try feedValue(&rt2, testing.allocator, "plane.s.b", @as(f64, -0.24));
    try feedValue(&rt2, testing.allocator, "plane.s.c", @as(f64, 0.39));
    try rt2.tick(.{});
    const w = mock2.writes.items[mock2.writes.items.len - 1];
    const inner = try innerOf(testing.allocator, w.value);
    defer testing.allocator.free(inner);
    var r = struple.reader(inner);
    var c: usize = 0;
    while (try r.next()) |e| : (c += 1) {
        try testing.expectEqual(FROZEN[3].y[c], @as(u32, @bitCast(e.float32)));
    }
    try testing.expectEqual(@as(usize, 9), c);
}

test "rbf: every refusal lands on the node that refused, naming the port and the number" {
    // A width of zero. 1/0 is an infinite precision and every read comes back
    // NaN; a clamp to some small number would leave a kernel that looks like
    // a kernel and reads like a needle.
    {
        var fx: Fixture = undefined;
        try mountWatched(testing.allocator, &fx,
            \\rbf bump at [0, 0] width 0 value [1] | write plane.coat
        , .{});
        defer fx.deinit();
        try expectRefusalNames(&.{ "rbf bump", "width" });
        try testing.expectEqualStrings("rbf bump", Refusal.opName());
    }
    // A query with the wrong number of axes — both counts, by name. Padding
    // it with a zero would read somewhere real and wrong.
    {
        var fx: Fixture = undefined;
        try mountWatched(testing.allocator, &fx,
            \\[plane.s.a, plane.s.b] | rbf through plane.fire.coat | write plane.fire.y
        , .{
            .{ "plane.fire.coat", .{ .d = @as(i64, 3), .m = @as(i64, 9), .k = FROZEN_K } },
            .{ "plane.s.a", @as(f64, 0) },
            .{ "plane.s.b", @as(f64, 0) },
        });
        defer fx.deinit();
        try expectRefusalNames(&.{ "rbf through", "2 numbers", "3 axes" });
    }
    // A second bump that disagrees with the set it is joining. `k` would
    // still divide evenly by the first shape's stride, so nothing downstream
    // could ever notice — which is why it is refused here and not there.
    {
        var fx: Fixture = undefined;
        try mountWatched(testing.allocator, &fx,
            \\rbf bump at [0, 0, 0] width 0.4 value [1, 1, 1] | rbf bump at [0, 0] width 0.4 value [1, 1, 1] | write plane.coat
        , .{});
        defer fx.deinit();
        try expectRefusalNames(&.{ "rbf bump", "3 axes", "2 and 3" });
    }
    // A set that is not a set. Reading zeros off a mistyped path looks
    // exactly like reading a set whose kernels are all far away.
    {
        var fx: Fixture = undefined;
        try mountWatched(testing.allocator, &fx,
            \\[plane.s.a] | rbf through plane.fire.coat | write plane.fire.y
        , .{
            .{ "plane.fire.coat", .{ .d = @as(i64, 3), .m = @as(i64, 9) } },
            .{ "plane.s.a", @as(f64, 0) },
        });
        defer fx.deinit();
        try expectRefusalNames(&.{ "rbf through", "'k'" });
    }
    // A kernel array that is not a whole number of kernels.
    {
        var fx: Fixture = undefined;
        try mountWatched(testing.allocator, &fx,
            \\[plane.s.a] | rbf through plane.fire.coat | write plane.fire.y
        , .{
            .{ "plane.fire.coat", .{ .d = @as(i64, 1), .m = @as(i64, 1), .k = [_]f32{ 1, 2, 3, 4 } } },
            .{ "plane.s.a", @as(f64, 0) },
        });
        defer fx.deinit();
        try expectRefusalNames(&.{ "rbf through", "4 numbers", "3-number kernels" });
    }
    // An infinite weight. Refused because an infinity has no value anywhere —
    // and because `eval`'s cutoff skip is loam's arithmetic only while `w · 0`
    // is a signed zero rather than a NaN.
    {
        var fx: Fixture = undefined;
        try mountWatched(testing.allocator, &fx,
            \\[plane.s.a] | rbf through plane.fire.coat | write plane.fire.y
        , .{
            .{ "plane.fire.coat", .{ .d = @as(i64, 1), .m = @as(i64, 1), .k = [_]f32{ 0, 1, std.math.inf(f32) } } },
            .{ "plane.s.a", @as(f64, 0) },
        });
        defer fx.deinit();
        try expectRefusalNames(&.{ "rbf through", "finite" });
    }
}

// ---------------------------------------------------------------------------
// An effect returns its input (2026-09-08).
//
// The six effect ops — `write`, `notify`, `inc`, `cast`, `tag`, `untag` — now
// each emit their `in` port, so a chain continues through one:
//
//     x | write plane.debug | mul 2 | write plane.out
//
// What the effect DOES is untouched: same write, same value, same mode, same
// timing. The motivating discovery was elsewhere — `parseDef` refuses a def
// whose last statement has no value, and a def that WRITES does something
// useful and yielded nothing, so the rule misfired on a legitimate definition.
// The rule is not wrong; `write` being a dead end is what made it misfire, and
// the fix belongs at the source rather than in an exception carved into `def`
// (Christian's framing, and his ruling). Hence all six and never a subset: if
// `write` composed and `cast` did not, a reader would have to memorise which
// effects are dead ends.
//
// Pass-through is the LINEAR spelling; `also { … }` is the branching one. Both
// stay — see the fan-out gate at the end of this block.
// ---------------------------------------------------------------------------

/// Feed a NUMBER as an occurrence — the shape `inc`/`tag`/`untag` want, since
/// their port 0 is a rousing that carries a payload nothing reads. The value
/// is what the pass-through must hand on, so it has to be distinguishable
/// from every payload in the table below.
fn feedNumOcc(rt: *rill.Runtime, gpa: std.mem.Allocator, path: []const u8, v: f64) !void {
    const enc = try packOne(gpa, v);
    defer gpa.free(enc);
    try rt.feed(.{ .path = path, .value = enc, .kind = .occurrence });
}

test "effect: each of the six emits its INPUT — never its payload" {
    // Gate 1. One rule for all six, and the payloads are deliberately
    // different from the rousing so "returns its input" is separable from
    // "returns what it landed": the rousing is 99, every payload is 5 or 7,
    // and the answer must be 99 six times.
    //
    // Mutations that bite: `passThru` returns `Emit.none` (all six go quiet);
    // `passThru` splices `raw(ctx, 1)` instead of `raw(ctx, 0)` (write,
    // notify, inc and cast hand on their payload); dropping `.outputs` from
    // any one registration (that op's slot does not exist and readSlot
    // answers null).
    const Case = struct { src: []const u8, node: []const u8 };
    const cases = [_]Case{
        .{ .src = "plane.x | write plane.a 5", .node = "write1" },
        .{ .src = "plane.x | notify plane.a 5", .node = "notify1" },
        .{ .src = "plane.x | inc plane.a 7", .node = "inc1" },
        .{ .src = "plane.x | cast $c 5 radius 3 at plane.origin", .node = "cast1" },
        .{ .src = "plane.x | tag @tom #garrison", .node = "tag1" },
        .{ .src = "plane.x | untag @tom #garrison", .node = "untag1" },
    };
    for (cases) |case| {
        var fx: Fixture = undefined;
        try mountFixture(testing.allocator, &fx, case.src, .{.{ "plane.origin", @as(i64, 0) }});
        defer fx.deinit();
        try feedNumOcc(&fx.rt, testing.allocator, "plane.x", 99);
        try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "programs.p.{s}.out.out", .{case.node});
        const got = slotNum(&fx, path) orelse {
            std.debug.print("'{s}': the effect emitted nothing\n", .{case.src});
            return error.TestUnexpectedResult;
        };
        if (got != 99) {
            std.debug.print("'{s}': emitted {d}, wanted the rousing (99)\n", .{ case.src, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "effect: the write still lands — every mode, every value, mid-chain" {
    // Gate 2. The whole point of the beat is that nothing about what reaches
    // the plane may change, so all five modes plus the bare replace run in
    // ONE chain, each one now carrying the value on to the next. `clear`
    // takes no value and still returns its input, which is what lets it sit
    // in the middle of the chain at all.
    //
    // Mutations that bite: land every write as `.base` (the mode column goes
    // flat); delete the `mode == .clear` early return (clear lands a value it
    // must not have); write `try raw(ctx, 0)` instead of the payload
    // preference (the payload row goes wrong).
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.x
        \\  | write plane.a hold
        \\  | write plane.b add
        \\  | write plane.c mul
        \\  | write plane.d stops
        \\  | write plane.e clear
        \\  | write plane.f 5
        \\  | write plane.g
    , .{});
    defer fx.deinit();
    try feedValue(&fx.rt, testing.allocator, "plane.x", @as(i64, 42));
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });

    const Want = struct { path: []const u8, mode: rill.WriteMode, value: ?f64 };
    const wants = [_]Want{
        .{ .path = "plane.a", .mode = .hold, .value = 42 },
        .{ .path = "plane.b", .mode = .add, .value = 42 },
        .{ .path = "plane.c", .mode = .mul, .value = 42 },
        .{ .path = "plane.d", .mode = .stops, .value = 42 },
        .{ .path = "plane.e", .mode = .clear, .value = null }, // a withdrawal carries nothing
        .{ .path = "plane.f", .mode = .base, .value = 5 }, // the payload, not the rousing
        .{ .path = "plane.g", .mode = .base, .value = 42 },
    };
    try testing.expectEqual(wants.len, fx.mock.writes.items.len);
    for (wants, fx.mock.writes.items) |want, got| {
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqual(want.mode, got.mode);
        if (want.value) |v| {
            try testing.expectEqual(v, types.asNumber(got.value).?);
        } else {
            try testing.expectEqual(@as(usize, 0), got.value.len);
        }
    }
}

test "effect: chained writes both land, with the same value" {
    // Gate 3. The shape from the ruling: `x | write plane.a | write plane.b`.
    // Mutation that bites: `passThru` returns `Emit.none` — the second sink
    // never receives an input, so it never evaluates and only one write
    // reaches the plane.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.x | write plane.a | write plane.b", .{});
    defer fx.deinit();
    try feedValue(&fx.rt, testing.allocator, "plane.x", @as(i64, 8));
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(usize, 2), fx.mock.writes.items.len);
    try testing.expectEqualStrings("plane.a", fx.mock.writes.items[0].path);
    try testing.expectEqualStrings("plane.b", fx.mock.writes.items[1].path);
    try testing.expectEqual(@as(f64, 8), types.asNumber(fx.mock.writes.items[0].value).?);
    try testing.expectEqual(@as(f64, 8), types.asNumber(fx.mock.writes.items[1].value).?);
}

test "effect: a mid-chain tap sees x while the tail sees 2x" {
    // Gate 4. The motivating spelling — a debug tap that costs no branch —
    // and the second statement pins that a tap with its OWN payload still
    // hands the ROUSING down: `plane.tapped` gets 100 and `plane.out2` gets
    // 2 × 6, never 200.
    //
    // Mutation that bites: splice `ctx.in[1] orelse try raw(ctx, 0)` — the
    // landed value rather than the input. The first statement cannot see it
    // (no payload, so the two are the same value), which is exactly why the
    // second one is here.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.x | write plane.dbg | mul 2 | write plane.out
        \\plane.x | write plane.tapped 100 | mul 2 | write plane.out2
    , .{});
    defer fx.deinit();
    try feedValue(&fx.rt, testing.allocator, "plane.x", @as(i64, 6));
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(f64, 6), try planeNum(&fx, "plane.dbg"));
    try testing.expectEqual(@as(f64, 12), try planeNum(&fx, "plane.out"));
    try testing.expectEqual(@as(f64, 100), try planeNum(&fx, "plane.tapped"));
    try testing.expectEqual(@as(f64, 12), try planeNum(&fx, "plane.out2"));
}

test "effect: a def whose last statement is an effect is legal, with parseDef untouched" {
    // Gate 5, and the reason the beat exists. `parseDef` refuses a def whose
    // last statement has no value — a rule that was misfiring on a def that
    // does something useful and yielded nothing. Not one line of `parseDef`
    // moved: the effect grew an output and the existing rule started
    // answering correctly. Both of these were `def 'f' produces no output`
    // before this beat, verified by running the gate against the old
    // evaluators.
    //
    // NOT `write` — see the gate below. `cast` and `tag`/`untag` are the
    // effects a def body can hold, because their targets are a `$channel`,
    // an `@subject` and a `#tag` rather than a plane path.
    //
    // Mutation that bites: drop `.outputs` from `cast`'s (or `tag`'s)
    // registration — the parse fails with "produces no output", which is the
    // exact misfire.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\def spark(x, pos) =
        \\  x | cast $glow 1 radius 3 at pos
        \\
        \\def enlist(x) =
        \\  x | tag @tom #garrison
        \\
        \\plane.v | spark pos: plane.origin | enlist | write plane.out
    , .{.{ "plane.origin", @as(i64, 0) }});
    defer fx.deinit();
    try feedNumOcc(&fx.rt, testing.allocator, "plane.v", 3);
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    // Both effects happened AND the value came out the far end: each def's
    // output is its last statement's pass-through.
    try testing.expectEqual(@as(usize, 1), fx.mock.casts.items.len);
    try testing.expectEqual(@as(usize, 1), fx.mock.tag_writes.items.len);
    try testing.expectEqual(@as(f64, 3), try planeNum(&fx, "plane.out"));
}

test "effect: `write` in a def body is still refused — by the OTHER rule" {
    // The boundary this beat did NOT move, pinned so a later reader does not
    // mistake it for an oversight. `parseDef`'s "produces no output" was one
    // of two rules standing between a def and a sink; the other is **defs
    // close over nothing** (parser.zig's header: "a `plane.…` path, read or
    // write, inside a def body is a parse error"), which predates this beat,
    // has its own gate, and refuses the WRITE TARGET rather than the missing
    // value. `write`, `notify` and `inc` all take a `.path` static, and a
    // path is plane-headed by construction — so those three remain unsayable
    // inside a def for a reason that has nothing to do with their outputs.
    //
    // Widening that is a separate ruling and a separate beat. What matters
    // here is that the refusal is the CLOSE-OVER one, in those words: if this
    // beat had regressed, the message would be "produces no output".
    //
    // Mutation that bites: let a template through `parsePlaneRef` — the def
    // parses, and this gate goes down naming the wrong refusal.
    try expectParseError(
        \\def stamp(x) =
        \\  x | write plane.log
        \\
        \\plane.v | stamp | write plane.out
    , "close over nothing");
}

test "effect: the def rule still refuses a def that genuinely yields nothing" {
    // The negative control for the gate above. Fixing the misfire must not
    // disarm the rule — a HOST effect verb may still declare no outputs, and
    // a def ending in one is still the thing the rule was written for.
    //
    // Mutation that bites: delete the `else` arm in `parseDef` that raises
    // "produces no output" (which is the shortcut this beat refused to take).
    const nop = struct {
        fn f(_: *rill.EvalCtx) registry.EvalError!registry.Emit {
            return registry.Emit.none;
        }
    }.f;
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const in_num = [_]registry.Port{.{ .name = "v", .ty = types.Tag.number }};
    _ = try reg.register(.{ .name = "poke", .inputs = &in_num, .help = "stub", .class = .effect, .routes = .anywhere, .eval = nop });
    var diag = rill.Diag{};
    const result = rill.parse(testing.allocator, &reg, "p",
        \\def bad(x) =
        \\  x | poke
        \\
        \\plane.v | bad | write plane.out
    , &diag);
    try testing.expectError(error.Parse, result);
    try testing.expect(std.mem.indexOf(u8, diag.msg(), "produces no output") != null);
}

test "effect: an export def may end in an effect, describe block and pack intact" {
    // Gate 6. The parameter pack's beat left this open on purpose — "an
    // exported def is still held to 'a def must produce an output', which is
    // the later beat's business if the mount ever wants a def that only has
    // effects." This is that beat, and the answer is that it needed no
    // exception: the effect yields, so the export is ordinary and every
    // export rule (the describe block, the port parity, the pack on
    // `Program.exports`) applies to it unchanged.
    //
    // Mutations that bite: drop `.outputs` from `cast` (the parse fails with
    // "produces no output"); `publishExports` does nothing (the pack is
    // gone); drop the `pd.doc.len > 0` sweep (the undescribed-port refusal
    // stops firing, which the second half of this gate catches).
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\export def spark(x, pos, amp: number = 4 (0..10)) =
        \\  x | cast $glow amp radius 3 at pos
        \\
        \\describe spark
        \\    "Deposits amp into the glow field and hands x on."
        \\    x   "the rousing"
        \\    pos "where the deposit lands"
        \\    amp "how much goes in"
        \\
        \\plane.v | spark pos: plane.origin | write plane.out
    , .{.{ "plane.origin", @as(i64, 0) }});
    defer fx.deinit();
    const e = fx.prog.exported("spark") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Deposits amp into the glow field and hands x on.", e.doc);
    try testing.expectEqual(@as(usize, 3), e.ports.len);
    try testing.expectEqualStrings("amp", e.ports[2].name);
    try testing.expectEqualStrings("how much goes in", e.ports[2].doc);
    try testing.expectEqual(@as(f64, 4), types.asNumber(e.ports[2].default.?).?);
    try testing.expectEqual(@as(f64, 10), types.asNumber(e.ports[2].max.?).?);
    try feedNumOcc(&fx.rt, testing.allocator, "plane.v", 3);
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(usize, 1), fx.mock.casts.items.len);
    try testing.expectEqual(@as(f64, 4), fx.mock.casts.items[0].amplitude);
    try testing.expectEqual(@as(f64, 3), try planeNum(&fx, "plane.out"));

    // The parity gate still holds over an effect-terminated export: leaving a
    // port undescribed is refused by name, exactly as for any other export.
    try expectParseError(
        \\export def spark(x, pos) =
        \\  x | cast $glow 1 radius 3 at pos
        \\
        \\describe spark
        \\    "Deposits into the glow field."
        \\    x "the rousing"
        \\
        \\plane.v | spark pos: plane.origin | write plane.out
    , "port 'pos' has no description");
}

test "effect: the cycle check is unmoved — a write of a path it reads still refuses" {
    // Gate 8. `findCycle` walks write paths against subscription paths and
    // has nothing to do with ports, so pass-through cannot loosen it — which
    // is a claim, and this is the executed version of it. The chained form is
    // the one worth pinning: the cycle now sits at the END of a chain that
    // passes through an innocent sink, and it is refused just the same.
    //
    // Mutation that bites: `findCycle` returns null (both refusals go away);
    // or skip a write whose node has outputs, which is the plausible wrong
    // "fix" this beat invites.
    try expectParseError("plane.a | write plane.a", "cycle");
    try expectParseError("plane.a | write plane.b | write plane.a", "cycle");
    try expectParseError("plane.a | write plane.b | notify plane.a", "cycle");
    // …and a chain that writes two paths it does not read is still fine.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.a | write plane.b | write plane.c");
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 2), prog.writes.items.len);
}

test "effect: `also` and the head block are unchanged — two spellings, both live" {
    // Gate 9. Pass-through is the LINEAR spelling and `also { … }` is the
    // BRANCHING one; the branch is still the only way to send the same value
    // two different ways. The second claim is the one the beat could have
    // broken quietly: `parseAlsoBlock` warns when a branch ends holding a
    // value, and exempts a branch that ends in a writer — an exemption that
    // was previously indistinguishable from "a sink has no outputs" and now
    // has to do real work.
    //
    // Mutation that bites: drop the `class.writes()` guard in
    // `parseAlsoBlock` — every `also { write … }` in every program in the
    // sibling repos starts warning.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.x | also { write plane.side } | mul 2 | write plane.main
        \\every 1f { write plane.tick }
    , .{});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), fx.prog.warnings.items.len);
    try feedValue(&fx.rt, testing.allocator, "plane.x", @as(i64, 7));
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(f64, 7), try planeNum(&fx, "plane.side"));
    try testing.expectEqual(@as(f64, 14), try planeNum(&fx, "plane.main"));
    // The branch really is a branch: the main wire carries 7 past it, not 7
    // and then whatever the branch made of it.
    try testing.expect(fx.mock.store.get("plane.tick") != null);
}

test "effect: a sink-terminated line now HAS a result, and it is the input" {
    // The one visible consequence outside the graph: `Program.result` is what
    // a one-shot console line echoes, and a sink statement used to set it
    // null on the reasoning that "effects echo nothing". A sink now has an
    // output, so the line has a value — the one that flowed in — and
    // `resultSlot` (which reads the last node that produces one) and
    // `result` finally agree instead of disagreeing by a node.
    //
    // Recorded as a deliberate change rather than discovered later: the
    // mutation that bites is restoring `Emit.none` in `evalSink`.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.a | add 1 | write plane.out", .{.{ "plane.a", @as(i64, 4) }});
    defer fx.deinit();
    const src = fx.prog.result orelse return error.TestUnexpectedResult;
    const wire = switch (src) {
        .wire => |sid| sid,
        else => return error.TestUnexpectedResult,
    };
    const sink = fx.prog.node(nodeIdOf(&fx.prog, "write1") orelse return error.TestUnexpectedResult);
    if (sink.outputs.len == 0) return error.TestUnexpectedResult;
    try testing.expectEqual(sink.outputs[0], wire);
    const echoed = fx.rt.readSlotId(wire) orelse {
        std.debug.print("the sink's out slot holds nothing — an effect line would echo nothing\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(f64, 5), types.asNumber(echoed).?);
    // `resultSlot` answers the same slot now, where it used to answer `add1`.
    try testing.expectEqual(wire, fx.prog.resultSlot() orelse return error.TestUnexpectedResult);
}

test "effect: a rousing's KIND survives the pass-through — two occurrences are two" {
    // The wrinkle a mutation found, not reasoning: an emission lands in the
    // sink's out slot through `emitSlot`, which suppresses identical bytes on
    // a VALUE slot ("20 → 20 is silence"). With the pass-through declared as a
    // value port, `plane.horn | tag @tom #g | inc plane.n 1` tagged twice and
    // counted ONCE — the second rousing dying silently one node downstream of
    // the effect that did fire for it.
    //
    // The fix is one rule and no special case: an effect's out port carries
    // the KIND its port 0 declares. `inc`/`tag`/`untag` take an occurrence, so
    // they emit one; `write`/`notify`/`cast` take a value, so they emit one.
    //
    // Mutation that bites: `p.occ("out", …)` → `p.val("out", …)` on any of
    // the three — the second rousing is swallowed and the count is 1.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, "plane.horn | tag @tom #g | inc plane.n 1", .{});
    defer fx.deinit();
    try feedNumOcc(&fx.rt, testing.allocator, "plane.horn", 1);
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try feedNumOcc(&fx.rt, testing.allocator, "plane.horn", 1); // the SAME bytes
    try fx.rt.tick(.{ .frame = 2, .time_ns = 2 });
    try testing.expectEqual(@as(usize, 2), fx.mock.tag_writes.items.len);
    try testing.expectEqual(@as(f64, 2), try planeNum(&fx, "plane.n"));

    // The declaration itself, so the rule is readable without running a
    // program: the out kind mirrors the in kind, op by op.
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    for ([_][]const u8{ "write", "notify", "inc", "cast", "tag", "untag" }) |name| {
        const def = reg.get(reg.find(name).?);
        if (def.outputs[0].kind != def.inputs[0].kind) {
            std.debug.print("'{s}': in is .{s} and out is .{s} — an effect returns its input, kind included\n", .{ name, @tagName(def.inputs[0].kind), @tagName(def.outputs[0].kind) });
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// `@self` in a def body (2026-09-08) — defs close over nothing, EXCEPT
// relatively. Ruled by Christian: *"`@self` is relative, so it stays portable.
// That's quite powerful but still keeps it sealed."* The old rule was not
// wrong, it was too blunt: it was written when every plane path was absolute
// and never considered `@self`, which resolves at MOUNT, per instance, and so
// travels with the def. rill permits the SPELLING and resolves nothing.
// ---------------------------------------------------------------------------

/// The subscription record for `path`, or null — what the gates below use to
/// say "the def's own path was subscribed, verbatim, at splice time".
fn subFor(prog: *const rill.Program, path: []const u8) ?*const graph.Sub {
    for (prog.subs.items) |*s| {
        if (std.mem.eql(u8, s.path, path)) return s;
    }
    return null;
}

test "@self: a def body may READ a relative plane path, and the value arrives" {
    // Mutations that bite: drop the `.relative => {}` arm in `checkDefReach`
    // (the def refuses); `substSource`'s `.plane` arm returns `.none` (the
    // path is dropped at splice and `mul` gets no second operand); delete the
    // `subFor` registration in `instantiate` (nothing ever feeds the slot, so
    // the value stays at its mount-time read and the second assertion fails).
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\def scare(x: number) =
        \\  x | mul plane.drift.@self.k.flock
        \\
        \\plane.v | scare | write plane.out
    , .{ .{ "plane.drift.@self.k.flock", @as(i64, 3) }, .{ "plane.v", @as(i64, 4) } });
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 12), try planeNum(&fx, "plane.out"));

    // The path is subscribed VERBATIM — rill does not resolve `@self`, the
    // host does, at mount. If this string ever arrives rewritten, rill has
    // taken a decision that belongs to spindrift.
    const sub = subFor(&fx.prog, "plane.drift.@self.k.flock") orelse {
        std.debug.print("nothing subscribes 'plane.drift.@self.k.flock'\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 1), sub.targets.items.len);
    // …and the slot it points at is a slot of the PROGRAM, not a leftover
    // template id. This is the assertion that the registration moved to
    // splice time rather than staying in `makeNode`.
    try testing.expect(sub.targets.items[0] < fx.prog.slots.items.len);
    try testing.expectEqualStrings("scare1.mul1", fx.prog.node(fx.prog.slot(sub.targets.items[0]).node).name);

    // The knob really is live, not just read once at mount.
    try feedValue(&fx.rt, testing.allocator, "plane.drift.@self.k.flock", @as(i64, 10));
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(f64, 40), try planeNum(&fx, "plane.out"));
}

test "@self: two instances of one def share the subscription and get two slots" {
    // A def is an archetype: two instances are two node sets (the parameter
    // pack's gate says so), but ONE path is one subscription — `subFor`
    // deduplicates by path and appends a target. Both instances must be fed.
    //
    // Mutation that bites: `if (sub.targets.items.len == 0)` around the
    // append in `instantiate` — one target instead of two, and the second
    // copy never updates (expected 2, found 1).
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\def scare(x: number) =
        \\  x | mul plane.drift.@self.k.flock
        \\
        \\plane.v | scare | write plane.a
        \\plane.v | scare | write plane.b
    , .{ .{ "plane.drift.@self.k.flock", @as(i64, 3) }, .{ "plane.v", @as(i64, 4) } });
    defer fx.deinit();
    const sub = subFor(&fx.prog, "plane.drift.@self.k.flock") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), sub.targets.items.len);
    try feedValue(&fx.rt, testing.allocator, "plane.drift.@self.k.flock", @as(i64, 10));
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(f64, 40), try planeNum(&fx, "plane.a"));
    try testing.expectEqual(@as(f64, 40), try planeNum(&fx, "plane.b"));
}

test "@self: a def body may WRITE a relative plane path" {
    // The write TARGET is a `.path` static, not a source — which is why
    // `write` in a def was refused by the close-over rule and not by "produces
    // no output" (2026-09-08, the effect beat). A relative target is now
    // sayable, and this is the shape the whole ruling exists for: a def that
    // drives its own instance's knob.
    //
    // Mutation that bites: drop the `.relative => {}` arm in `checkDefReach`
    // — the def refuses and the write never happens. (The mutation that says
    // the check must live in `parsePlaneRef` rather than in `makeNode` is on
    // the absolute gate below, because it is the ABSOLUTE write that slips.)
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\def driver(x: number) =
        \\  x | mul 0.05 | write plane.drift.@self.k.flock
        \\
        \\plane.v | driver
    , .{.{ "plane.v", @as(i64, 4) }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 0.2), try planeNum(&fx, "plane.drift.@self.k.flock"));
}

test "@self: a def that reads and writes one relative path is still a cycle" {
    // The composed write list must see a def's `@self` write, or an
    // instantiated feedback loop slips past §4.4's check — the same hazard the
    // membership sinks had, one rule up. `registerWrites` at splice time is
    // what pays for it, and until this beat it could only ever see a
    // `@subject`/`#tag` pair, because templates banned `path` statics whole.
    //
    // Mutation that bites: drop the `class.writes()` arm in `instantiate`'s
    // splice loop — the def parses and the loop is live in the graph.
    try expectParseError(
        \\def spin(x: number) =
        \\  plane.drift.@self.k.flock | add x | write plane.drift.@self.k.flock
        \\
        \\plane.v | spin
    , "cycle");
}

test "@self: an ABSOLUTE plane path in a def body is still refused, and says why" {
    // The rule this beat did NOT relax, with the message that now teaches the
    // difference — someone who hits it should learn the rule here rather than
    // from the spec.
    //
    // Mutations that bite: `checkDefReach`'s `.absolute` arm returns instead
    // of failing (every assertion here goes down, and three older gates with
    // them); or the check is moved from `parsePlaneRef` into `makeNode`'s
    // `.plane` arm, which is where a first draft of this beat nearly put it —
    // the READ assertions survive that and the WRITE one below does not,
    // because a write target is a `.path` STATIC and no static ever becomes a
    // node's source. One door, and it has to be the one every path goes
    // through.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add plane.defense.alerts
        \\
        \\plane.v | bad | write plane.out
    , "defs close over nothing");
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add plane.defense.alerts
        \\
        \\plane.v | bad | write plane.out
    , "name it relatively with `@self`");
    // It names the path it judged, and the def it judged it for.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add plane.defense.alerts
        \\
        \\plane.v | bad | write plane.out
    , "'plane.defense.alerts'");
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add plane.defense.alerts
        \\
        \\plane.v | bad | write plane.out
    , "mounts 'bad'");
    // A WRITE target is the same rule and the same message.
    try expectParseError(
        \\def stamp(x) =
        \\  x | write plane.log
        \\
        \\plane.v | stamp | write plane.out
    , "name it relatively with `@self`");
}

test "@self: a DIFFERENT entity is refused — it names one instance" {
    // The decision this brief left to the beat, and the reason: an entity
    // other than `@self` names one specific instance and is exactly as
    // unportable as an absolute path. The message says that rather than
    // reusing the absolute wording, because the fix is different (`@self`,
    // not "a port").
    //
    // Mutation that bites: drop the `std.mem.eql(seg, "@self")` comparison in
    // `reachOf` and let any `@` segment count as relative — `@roaches` parses.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | mul plane.drift.@roaches.k.flock
        \\
        \\plane.v | bad | write plane.out
    , "names one specific instance");
    try expectParseError(
        \\def bad(x: number) =
        \\  x | mul plane.drift.@roaches.k.flock
        \\
        \\plane.v | bad | write plane.out
    , "`@roaches`");
    // A named instance DOMINATES a `@self` in the same path: the moment one
    // instance is named the path stops travelling, whatever else is in it.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | mul plane.drift.@self.peers.@roaches.k.flock
        \\
        \\plane.v | bad | write plane.out
    , "names one specific instance");
    // `@selfish` is a different entity, not a misspelling of the exemption:
    // the test is on the whole SEGMENT, never a substring. (spindrift's mount
    // rewrite searches for the substring `@self`, so a segment-loose rule here
    // would have handed it `@<name>ish` to resolve.)
    try expectParseError(
        \\def bad(x: number) =
        \\  x | mul plane.drift.@selfish.k.flock
        \\
        \\plane.v | bad | write plane.out
    , "`@selfish`");
    // And an unsigiled `self` is not an entity segment at all — it is one
    // room's name, so it is the ABSOLUTE refusal, not this one.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | mul plane.drift.self.k.flock
        \\
        \\plane.v | bad | write plane.out
    , "name it relatively with `@self`");
}

test "@self: position is not checked, because rill cannot know it" {
    // Decided in this beat and recorded rather than left implicit. Where a
    // host's entity room sits in its path shape is the HOST's business — only
    // spindrift knows `@self` is segment 2 of `plane.drift.@self.k.gravity`.
    // rill judges the SIGIL: a segment wearing `@` is an entity segment
    // wherever it sits, so a tail `@self` parses here and is refused, loudly,
    // by whichever mount does not serve it — the same place a mistyped knob
    // path is refused today.
    //
    // Mutation that bites: make `reachOf` require the `@self` segment at a
    // fixed index (say 2) — this parse refuses.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\def odd(x: number) =
        \\  x | mul plane.drift.k.@self
        \\
        \\plane.v | odd | write plane.out
    );
    defer prog.deinit();
    try testing.expect(subFor(&prog, "plane.drift.k.@self") != null);
}

test "@self: `row.` and `slate.` in a WORLD def stay refused, and the advice now names the fix" {
    // This gate belongs to the `@self` beat and was RE-AIMED by the plane
    // beat the same day, which is the honest record: `row.` and `slate.` are
    // still refused here, but the reason is no longer "the exemption is the
    // `plane` head's alone" — it is that this def did not declare `on row`.
    // The message therefore has to carry the fix, and asserting the fix is
    // what stops the refusal decaying back into "no".
    //
    // (`docs/cc-recon-def-plane.md` is the recon that moved it: a def that
    // wants `row.pos` is asking to declare its PLANE, and that ruling was
    // taken.)
    //
    // Mutations that bite: drop the `target.plane == .row` early return in
    // `checkDefReach` and this gate still passes but the row gates fall over
    // — so the mutation aimed HERE is the inverse: make `checkDefReach`
    // return unconditionally for a non-`plane` head (all three refusals
    // vanish). Deleting the `on row` clause from the message bites the third
    // assertion alone.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add row.age
        \\
        \\plane.v | bad | write plane.out
    , "relative only on the row plane");
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add slate.contact
        \\
        \\plane.v | bad | write plane.out
    , "relative only on the row plane");
    // The fix is IN the refusal, spelled out for this def by name.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add row.age
        \\
        \\plane.v | bad | write plane.out
    , "`def bad(…) on row = …`");
    // A sigil does not buy a world def its way in either: the head test runs
    // before `reachOf` ever sees the path.
    try expectParseError(
        \\def bad(x: number) =
        \\  x | add row.@self.age
        \\
        \\plane.v | bad | write plane.out
    , "defs close over nothing");
}

test "@self: the record sugar is judged on its prefix, not skipped" {
    // `plane.a.{x, y}` returns EARLY from `parsePlaneRef` — before the loop
    // that builds the rest of the path — so a check written only after the
    // loop leaves the sugar as a hole in the rule.
    //
    // Mutation that bites: delete the `checkDefReach` call in the `lbrace`
    // arm — `plane.player.{health, mana}` walks straight into a def body.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\def pair(x: number) =
        \\  plane.drift.@self.k.{lo, hi} as r
        \\  r.lo | add x
        \\
        \\plane.v | pair | write plane.out
    );
    defer prog.deinit();
    try testing.expect(subFor(&prog, "plane.drift.@self.k.lo") != null);
    try testing.expect(subFor(&prog, "plane.drift.@self.k.hi") != null);

    try expectParseError(
        \\def pair(x: number) =
        \\  plane.player.{health, mana} as r
        \\  r.health | add x
        \\
        \\plane.v | pair | write plane.out
    , "name it relatively with `@self`");
}

test "@self: a fold expanding to a relative path is allowed; an absolute one still refuses" {
    // The `using` beat's ruling holds unchanged: `:name` gets NO rule of its
    // own inside a def body — substitution happens and the check that is there
    // judges what came out. What changed is the answer for one shape.
    //
    // Mutations that bite: drop the `.relative` arm (the first parse refuses);
    // drop the `if (tok.fold != 0)` call in `fail` (the provenance half of the
    // second assertion stops, and the refusal points at a `plane` token the
    // author never typed).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\using plane.drift.@self.k as :k
        \\def scare(x: number) =
        \\  x | mul :k.flock
        \\
        \\plane.v | scare | write plane.out
    );
    defer prog.deinit();
    try testing.expect(subFor(&prog, "plane.drift.@self.k.flock") != null);

    try expectParseError(
        \\using plane.player.offset as :po
        \\def bad(x: number) =
        \\  x | add :po
        \\
        \\plane.v | bad | write plane.b
    , "name it relatively with `@self`");
    try expectParseError(
        \\using plane.player.offset as :po
        \\def bad(x: number) =
        \\  x | add :po
        \\
        \\plane.v | bad | write plane.b
    , "expanded from :po, bound at line 1");
}

test "@self: an export def may drive its own knob, pack and all" {
    // The shape the ruling was asked for: one definition that declares its
    // parameters, documents them, and drives the instance's own knob — legal
    // even though its last statement is an effect (2026-09-08, an effect
    // returns its input).
    //
    // Mutations that bite: drop the `.relative` arm (the body refuses);
    // `publishExports` does nothing ("'flock' is not on Program.exports").
    // That the last statement may BE the effect is the effect beat's gate,
    // one file up — what is new here is that its target may be a plane path
    // at all.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\export def flock(gain: number = 0.05 (0..1)) =
        \\  lfo sine 7s | mul gain | write plane.drift.@self.k.flock
        \\
        \\describe flock
        \\    "Drives this spray's own flocking knob from a slow sine."
        \\    gain "how far the knob swings"
        \\
        \\flock
    );
    defer prog.deinit();
    const pack = prog.exported("flock") orelse {
        std.debug.print("'flock' is not on Program.exports\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 1), pack.ports.len);
    try testing.expectEqualStrings("gain", pack.ports[0].name);
    try testing.expectEqual(@as(f64, 0.05), types.asNumber(pack.ports[0].default.?).?);
    try testing.expectEqual(@as(f64, 1), types.asNumber(pack.ports[0].max.?).?);
    try testing.expectEqualStrings("how far the knob swings", pack.ports[0].doc);
    // and the body really did land on the relative path
    try testing.expect(nodeIdOf(&prog, "flock1.write1") != null);
}

test "@self: a def calling a def, where the INNER one names the relative path" {
    // The nested case, which is where the splice-time registration earns its
    // guard: the inner def is spliced into the OUTER TEMPLATE, whose slot ids
    // are template-local. Registering there would file a subscription against
    // a slot the program does not have; the outer's own splice files it once,
    // later, against the real one.
    //
    // Mutation that bites: drop the `target.template == null` guard in
    // `instantiate`'s plane-source arm — the inner splice files a second
    // target, a TEMPLATE slot id, against the program's subscription list
    // (expected 1, found 2), and whatever program slot happens to wear that
    // id gets fed the knob.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\def inner(x: number) =
        \\  x | mul plane.drift.@self.k.flock
        \\
        \\def outer(y: number) =
        \\  y | inner | add 1
        \\
        \\plane.v | outer | write plane.out
    , .{ .{ "plane.drift.@self.k.flock", @as(i64, 3) }, .{ "plane.v", @as(i64, 4) } });
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 13), try planeNum(&fx, "plane.out"));
    const sub = subFor(&fx.prog, "plane.drift.@self.k.flock") orelse {
        std.debug.print("nothing subscribes the inner def's path\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 1), sub.targets.items.len);
    try testing.expectEqualStrings("outer1.inner1.mul1", fx.prog.node(fx.prog.slot(sub.targets.items[0]).node).name);
    try feedValue(&fx.rt, testing.allocator, "plane.drift.@self.k.flock", @as(i64, 10));
    try fx.rt.tick(.{ .frame = 1, .time_ns = 1 });
    try testing.expectEqual(@as(f64, 41), try planeNum(&fx, "plane.out"));
}

// ---------------------------------------------------------------------------
// A definition declares its plane (2026-09-08, `docs/cc-recon-def-plane.md`
// Option A, ruled by Christian: *"take the recommendation"*).
//
// `def spin(x) on row = …` — contextual after the signature, reserving no
// word, undeclared meaning the world plane. And the ruling it is coupled to,
// without which it would buy almost nothing: **`row.…` and `slate.…` become
// sayable inside a `row`-declared def**. That is not a new hole in the
// close-over rule, it is the SAME rule — the `@self` beat allowed
// `plane.drift.@self.k.flock` because `@self` is relative, and `row.age` is
// relative in exactly that way: it resolves to whichever row is being swept,
// so a def carrying one still travels. One principle, three relative stores.
// ---------------------------------------------------------------------------

/// Core plus one row-only host word with an output, so a def body can end in
/// it. `hostRegistry` deliberately has no row word — every exhaustive audit in
/// this file walks it — so the plane gates build their own.
fn rowWordRegistry(gpa: std.mem.Allocator) !rill.Registry {
    var reg = try rill.Registry.init(gpa);
    errdefer reg.deinit();
    try rill.registerCore(&reg);
    const stub = struct {
        fn f(_: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
            return rill.Emit.none;
        }
        fn k(_: *rill.row.Ctx) rill.row.Error!void {}
    };
    _ = try reg.register(.{
        .name = "gravity_like",
        .inputs = &.{.{ .name = "g", .ty = rill.Tag.number }},
        .outputs = &.{.{ .name = "out", .ty = rill.Tag.any }},
        .help = "stub row word",
        .routes = .anywhere,
        .row = .{ .exact = true, .only = true, .eval = stub.k },
        .eval = stub.f,
    });
    return reg;
}

fn parseKernelOk(gpa: std.mem.Allocator, reg: *rill.Registry, source: []const u8) !rill.Program {
    var diag = rill.Diag{};
    return rill.parseKernel(gpa, reg, "p", source, &diag) catch |err| {
        if (err == error.Parse) std.debug.print("parseKernel: {s} (line {d}, col {d})\n", .{ diag.msg(), diag.line, diag.col });
        return err;
    };
}

/// A parse refusal against a registry that HAS a row word, either entry point.
fn expectPlaneError(kernel: bool, source: []const u8, needle: []const u8) !void {
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    const result = if (kernel)
        rill.parseKernel(testing.allocator, &reg, "p", source, &diag)
    else
        rill.parse(testing.allocator, &reg, "p", source, &diag);
    try testing.expectError(error.Parse, result);
    if (std.mem.indexOf(u8, diag.msg(), needle) == null) {
        std.debug.print("diagnostic \"{s}\" does not mention \"{s}\"\n", .{ diag.msg(), needle });
        return error.TestUnexpectedResult;
    }
}

fn hasSub(prog: *const rill.Program, path: []const u8) bool {
    for (prog.subs.items) |s| {
        if (std.mem.eql(u8, s.path, path)) return true;
    }
    return false;
}

fn hasWrite(prog: *const rill.Program, path: []const u8) bool {
    for (prog.writes.items) |w| {
        if (std.mem.eql(u8, w.path, path)) return true;
    }
    return false;
}

test "plane: `on row` parses after the signature and composes with `export`, reserving no word" {
    // The spelling, and the whole spelling argument: `on` is CONTEXTUAL — the
    // parser is at a known point (after the `)`, before the `=`) — so nothing
    // is reserved and an operator or a stream may still be called `on`. The
    // plane words cost nothing either: `plane` and `row` were already
    // reserved.
    //
    // Mutations that bite: delete the `on` arm in `parseDef` ("expected '='
    // after def signature"); add "on" to `registry.isReservedWord` (the last
    // two assertions).
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseKernelOk(testing.allocator, &reg,
        \\def spin(x: number) on row =
        \\  x | add row.age
        \\
        \\export def scuttle(rate = 60 (0..500)) on row =
        \\  rate | mul 0.5 | add row.age
        \\
        \\describe scuttle
        \\    "One row's scuttle."
        \\    rate "rows per second"
        \\
        \\row.vel | spin | write row.pos
        \\scuttle | write row.size
    );
    defer prog.deinit();
    try testing.expect(hasSub(&prog, "row.age"));
    try testing.expect(hasWrite(&prog, "row.pos"));
    const pack = prog.exported("scuttle") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), pack.ports.len);
    try testing.expectEqual(@as(f64, 60), types.asNumber(pack.ports[0].default.?).?);
    try testing.expectEqual(@as(f64, 500), types.asNumber(pack.ports[0].max.?).?);

    // `on` reserves nothing: it is still a legal operator name and a legal
    // stream name, because the parser only looks for it in one position.
    try testing.expect(!registry.isReservedWord("on"));
    const noop = struct {
        fn f(_: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
            return rill.Emit.none;
        }
    }.f;
    var reg2 = try hostRegistry(testing.allocator);
    defer reg2.deinit();
    _ = try reg2.register(.{ .name = "on", .inputs = &.{.{ .name = "in", .ty = rill.Tag.number }}, .outputs = &.{.{ .name = "out", .ty = rill.Tag.any }}, .help = "stub", .routes = .anywhere, .eval = noop });
    var p2 = try parseOk(testing.allocator, &reg2, "plane.v | on | write plane.out");
    defer p2.deinit();

    // `on plane` is sayable too — the world plane spells itself the way every
    // path spells it. In a KERNEL file it is the declaration that MATTERS:
    // the def is not a kernel, so its row word does not bind. (Mutation:
    // delete the `"plane"` arm and `on plane` dies as "is not a plane".)
    var pw = try parseKernelOk(testing.allocator, &reg,
        \\def helper(x: number) on plane =
        \\  x | mul 2
        \\
        \\row.vel | helper | write row.pos
    );
    defer pw.deinit();
    try expectPlaneError(true,
        \\def helper(x: number) on plane =
        \\  x | gravity_like
        \\
        \\row.vel | helper | write row.pos
    , "is a row word");
}

test "plane: an UNDECLARED def is a world def — in a kernel file too" {
    // The default, gated as the ruling (recon §3, option (ii)). The two
    // readings that lost: (i) INHERIT the caller's flag re-imports the ambient
    // decision the declaration exists to remove; (iii) plane-AGNOSTIC is not a
    // template, because both readers run while the body is parsed and a body
    // is parsed once — that is what `using` already is.
    //
    // Mutation that bites: seed `parseDef`'s `plane` from
    // `self.program_target.plane` instead of `.world` (option (i)) — the row
    // word then binds inside the undeclared def and the first refusal below
    // goes green.
    try expectPlaneError(true,
        \\def bad(x: number) =
        \\  x | gravity_like
        \\
        \\row.vel | bad | write row.pos
    , "is a row word");
    // …and the refusal names THIS def's fix, not the file's.
    try expectPlaneError(true,
        \\def bad(x: number) =
        \\  x | gravity_like
        \\
        \\row.vel | bad | write row.pos
    , "`def bad(…) on row = …`");
    // A `row.` path in an undeclared def, inside a kernel file, is refused for
    // the same reason.
    try expectPlaneError(true,
        \\def bad(x: number) =
        \\  x | add row.age
        \\
        \\row.vel | bad | write row.pos
    , "relative only on the row plane");
    // The negative control, in rill's own words: the TOP-LEVEL refusal is
    // byte-for-byte the one it always was. spindrift's G2 asserts its leading
    // clause on three programs (`plane.x | gravity`, `spawn`, `every 1s |
    // also { perish }`), so a beat that reworded it there would break another
    // repo's gates. Only the DEF case gained a second wording.
    try expectPlaneError(false, "plane.x | gravity_like", "mount it in a kernel");
    // The world default is what a plain helper gets, and a plain helper still
    // works in a kernel exactly as it always has (recon §2 measured it).
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseKernelOk(testing.allocator, &reg,
        \\def dbl(x: number) =
        \\  x | mul 2
        \\
        \\row.vel | dbl | write row.pos
    );
    defer prog.deinit();
    try testing.expect(hasSub(&prog, "row.vel"));
    try testing.expect(hasWrite(&prog, "row.pos"));
}

test "plane: a `row` def reaches the row — `row.…` reads and writes, and the path survives the splice" {
    // The coupled ruling. Before it, *"a row def was a def that cannot reach
    // the row"* (recon §2) and the declaration would have bought almost
    // nothing: a def could call `gravity` and read `@self` broadcasts and
    // still not read `row.age`.
    //
    // Mutation that bites: drop the `target.plane == .row` early return in
    // `checkDefReach` — the def refuses outright.
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseKernelOk(testing.allocator, &reg,
        \\def drift(k: number) on row =
        \\  row.vel | mul k | add row.age | write row.pos
        \\
        \\0.5 | drift
    );
    defer prog.deinit();
    // The paths survive the splice verbatim and land on the PROGRAM's
    // subscription list, at real program slots — the same claim the `@self`
    // gate makes, on the other relative store.
    try testing.expect(hasSub(&prog, "row.vel"));
    try testing.expect(hasSub(&prog, "row.age"));
    try testing.expect(hasWrite(&prog, "row.pos"));
    const sub = subFor(&prog, "row.vel") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), sub.targets.items.len);
    try testing.expect(sub.targets.items[0] < prog.slots.items.len);
    try testing.expectEqualStrings("drift1.mul1", prog.node(prog.slot(sub.targets.items[0]).node).name);
    // Two instances are two node sets and one subscription with two targets.
    var prog2 = try parseKernelOk(testing.allocator, &reg,
        \\def drift(k: number) on row =
        \\  row.vel | mul k
        \\
        \\0.5 | drift | write row.pos
        \\2 | drift | write row.size
    );
    defer prog2.deinit();
    const sub2 = subFor(&prog2, "row.vel") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), sub2.targets.items.len);
}

test "plane: `slate.…` is sayable in a row def — the deliberate half of the ruling" {
    // Decided, not swept along. The slate lives ENTIRELY on the row plane
    // (`row.zig`'s SLATE; the world evaluator has no slate at all), it is
    // per-row and per-tick, and it pins a def to no Project — as relative as
    // `row.` and `@self`. The one thing that could go wrong, a name nobody
    // says or one said too late, is refused LOUDLY by name at mount
    // (`error.SlateUnsaid` / `error.SlateOutOfOrder`, gated in `row.zig`), in
    // the same place a mistyped row field dies. So the reasoning carries.
    //
    // Mutation that bites: restrict `checkDefReach`'s row-plane early return
    // to the `row` head only — `slate.contact` refuses again.
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseKernelOk(testing.allocator, &reg,
        \\def settle(x: number) on row =
        \\  x | add slate.contact | write row.pos
        \\
        \\row.vel | settle
    );
    defer prog.deinit();
    try testing.expect(hasSub(&prog, "slate.contact"));
    // And it is NOT sayable in a world def — with the same one message, since
    // it is the same rule.
    try expectPlaneError(false,
        \\def bad(x: number) =
        \\  x | add slate.contact
        \\
        \\plane.v | bad | write plane.out
    , "relative only on the row plane");
}

test "plane: `@self` still works on BOTH planes — the ruling widened, it did not move" {
    // The negative control for the previous beat: a relative `plane.` path is
    // still legal in a world def (which the `@self` gates cover) and is still
    // legal in a ROW def, which is the shape every real kernel wants — a
    // driver reading its own instance's knob while sweeping rows.
    //
    // Mutation that bites: make `checkDefReach`'s row-plane early return
    // swallow the `plane` head too (`if (target.plane == .row) return;` moved
    // above the head test) — then the ABSOLUTE assertion below goes green,
    // because a row def would close over one Project's plane.
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseKernelOk(testing.allocator, &reg,
        \\def drift(x: number) on row =
        \\  x | mul plane.drift.@self.k.flock | add row.age | write row.pos
        \\
        \\row.vel | drift
    );
    defer prog.deinit();
    try testing.expect(hasSub(&prog, "plane.drift.@self.k.flock"));
    try testing.expect(hasSub(&prog, "row.age"));
    // An ABSOLUTE plane path is refused in a row def exactly as in a world
    // one: the plane declaration says which mount, never which Project.
    try expectPlaneError(true,
        \\def bad(x: number) on row =
        \\  x | mul plane.defense.alerts | write row.pos
        \\
        \\row.vel | bad
    , "defs close over nothing");
    // …and a NAMED instance still dominates, on the row plane too.
    try expectPlaneError(true,
        \\def bad(x: number) on row =
        \\  x | mul plane.drift.@roaches.k.flock | write row.pos
        \\
        \\row.vel | bad
    , "names one specific instance");
}

test "plane: a row def called from a world statement is refused at the CALL SITE, naming both" {
    // Recon §6's hazard, answered where it said it had to be. A row body may
    // hold row words and `row.` paths; flattened into a world program they
    // become nodes that are neither, and the plane runtime reaches a RUNTIME
    // refusal — the exact leak `parseKernel` was invented to plug, because a
    // node that never evaluates never refuses.
    //
    // Mutation that bites: delete the `tmpl.plane == .row and target.plane !=
    // .row` arm at the head of `instantiate` — the row def splices into a
    // world program and both refusals below go green.
    try expectPlaneError(false,
        \\def spin(x: number) on row =
        \\  x | add row.age
        \\
        \\plane.v | spin | write plane.out
    , "'spin' is declared `on row` and this is a world-plane statement");
    // Nested: the caller is a world DEF, and the refusal names it rather than
    // shrugging about "a statement".
    try expectPlaneError(false,
        \\def spin(x: number) on row =
        \\  x | add row.age
        \\
        \\def outer(y: number) =
        \\  y | spin
        \\
        \\plane.v | outer | write plane.out
    , "this is def 'outer', which runs on the world plane");
}

test "plane: a WORLD def travels to the row — the asymmetry is the ruling" {
    // The other direction is allowed, and deliberately. A world def closes
    // over nothing but a relative `@self` path, which resolves at mount on
    // either plane, so it TRAVELS — that is what closing over nothing buys
    // it. Refusing it would make `on row` compulsory boilerplate on every
    // kernel helper, and would buy no loudness: a world def holding something
    // a kernel cannot run is refused BY NAME at `row.Runtime.mount`, in the
    // same place the same op written inline would die.
    //
    // Mutation that bites: make the cross-plane check symmetric
    // (`tmpl.plane != target.plane`) — the nested program below refuses.
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseKernelOk(testing.allocator, &reg,
        \\def dbl(x: number) =
        \\  x | mul 2
        \\
        \\def spin(y: number) on row =
        \\  y | dbl | add row.age | write row.pos
        \\
        \\row.vel | spin
    );
    defer prog.deinit();
    try testing.expect(nodeIdOf(&prog, "spin1.dbl1.mul1") != null);
    try testing.expect(hasSub(&prog, "row.age"));
}

test "plane: the caller's flag governs the TOP LEVEL only — one file, both planes" {
    // Recon §3 point 4: `parseWith`'s flag stops meaning "the file's plane"
    // and comes to mean "the plane of the top-level statements". A smaller
    // and more honest claim, and the reason not one existing caller had to
    // change. Gated in both directions in ONE file each.
    //
    // Mutation that bites: read the two plane-sensitive sites off the program
    // target rather than the statement's target (`self.program_target.plane`
    // in place of `target.plane` at the row-word bind) — the world def in the
    // kernel file below stops refusing, and the row def in the world file
    // below stops binding.
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    // A kernel at top level, with a world def beside it. The def is NOT a
    // kernel: its row word refuses.
    var k = try parseKernelOk(testing.allocator, &reg,
        \\def helper(x: number) =
        \\  x | mul 2
        \\
        \\row.vel | gravity_like | helper | write row.pos
    );
    defer k.deinit();
    try testing.expectEqual(graph.EvalPlane.row, k.plane);
    // A world program at top level, with a ROW def beside it. The def parses
    // — row word, row path and all — it simply cannot be called from here.
    var w = try parseOk(testing.allocator, &reg,
        \\def spin(x: number) on row =
        \\  x | gravity_like | add row.age | write row.pos
        \\
        \\plane.v | mul 2 | write plane.out
    );
    defer w.deinit();
    try testing.expectEqual(graph.EvalPlane.world, w.plane);
    // The def flattened away with nothing to instantiate it, so the world
    // program carries no row node at all — the mixed FILE is not a mixed
    // GRAPH, which is the whole of recon §6's answer.
    try testing.expect(!hasSub(&w, "row.age"));
    try testing.expectEqual(@as(usize, 2), w.nodeCount());
}

test "plane: the `$chan at` desugar reads the DEF's plane, not the file's" {
    // The second of the two sites the flag was ever read at (recon §1.2), and
    // the one a per-def plane would otherwise have left behind: in a row
    // context `$wind at row.pos` rewrites to the host's `hear`, and on the
    // world plane the same tokens are the standpoint refusal.
    //
    // Mutation that bites: revert that site to a parser-wide flag — the first
    // half then refuses (a world FILE) and the second half desugars (a kernel
    // FILE), which is precisely backwards.
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    const stub = struct {
        fn f(_: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
            return rill.Emit.none;
        }
        fn k(_: *rill.row.Ctx) rill.row.Error!void {}
    };
    _ = try reg.register(.{
        .name = "hear",
        .statics = &.{.{ .name = "channel", .kind = .channel }},
        .inputs = &.{.{ .name = "at", .ty = rill.Tag.any, .kw = true }},
        .outputs = &.{.{ .name = "out", .ty = rill.Tag.any }},
        .help = "stub",
        .routes = .anywhere,
        .row = .{ .exact = true, .only = true, .eval = stub.k },
        .eval = stub.f,
    });
    // A row def inside a WORLD file: the desugar fires.
    var prog = try parseOk(testing.allocator, &reg,
        \\def sniff() on row =
        \\  $wind at row.pos | mul 2 | write row.vel
        \\
        \\plane.v | mul 2 | write plane.out
    );
    defer prog.deinit();
    // Nothing instantiated it, so read the refusal-free parse as the claim
    // and pin the desugar by instantiating it in a kernel instead.
    var kern = try parseKernelOk(testing.allocator, &reg,
        \\def sniff() on row =
        \\  $wind at row.pos | mul 2 | write row.vel
        \\
        \\sniff
    );
    defer kern.deinit();
    const hear_id = nodeIdOf(&kern, "sniff1.hear1") orelse {
        std.debug.print("the `$wind at row.pos` desugar did not build a `hear` node\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("$wind", kern.node(hear_id).statics[0].channel);
    // A WORLD def inside a KERNEL file: the same tokens take the plane
    // spelling of the refusal, because the def is not a kernel.
    try expectPlaneError(true,
        \\def sniff() =
        \\  $wind at row.pos | mul 2
        \\
        \\row.vel | mul 2 | write row.pos
    , "plane.sensors.<post>.$wind");
}

test "plane: a fold splicing `row.…` works in a row def and refuses in a world def, with provenance" {
    // Christian's `using` ruling holds unchanged: `:name` gets NO rule of its
    // own inside a def body — substitution happens and then the EXISTING
    // checks run on the expanded tokens. This beat changes what those checks
    // say, and the fold's provenance chain must still ride the refusal, on a
    // rule that did not exist when the chain was built.
    //
    // Mutation that bites: drop `if (tok.fold != 0) self.noteProvenance(…)`
    // from `fail` — the refusal names a `row.age` the author cannot find.
    var reg = try rowWordRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseKernelOk(testing.allocator, &reg,
        \\using row.age as :age
        \\
        \\def spin(x: number) on row =
        \\  x | add :age | write row.pos
        \\
        \\row.vel | spin
    );
    defer prog.deinit();
    try testing.expect(hasSub(&prog, "row.age"));
    try expectPlaneError(false,
        \\using row.age as :age
        \\
        \\def bad(x: number) =
        \\  x | add :age
        \\
        \\plane.v | bad | write plane.out
    , "expanded from :age, bound at line 1");
}

test "plane: a plane word that is not a plane refuses, and so does a missing `on`" {
    // Loud, never a guess, and the refusal lands on the thing that refused
    // with the fix in it. `slate` gets its own message because someone who
    // writes `on slate` has a real question — "where does `slate.x` live
    // then?" — that deserves the real answer.
    //
    // Mutations that bite: replace the unknown-plane arm with a silent
    // `plane = .world` (the first two assertions); delete the missing-`on`
    // pointer (the last one falls back to "expected '='").
    try expectPlaneError(false,
        \\def spin(x: number) on spray =
        \\  x | mul 2
        \\
        \\plane.v | spin | write plane.out
    , "'spray' is not a plane");
    try expectPlaneError(false,
        \\def spin(x: number) on slate =
        \\  x | mul 2
        \\
        \\plane.v | spin | write plane.out
    , "`slate` is not a plane");
    try expectPlaneError(false,
        \\def spin(x: number) row =
        \\  x | mul 2
        \\
        \\plane.v | spin | write plane.out
    , "a plane declaration is introduced by `on`");
}

test "plane: the program's plane is recorded on the Program, and is NOT in the dump" {
    // Recon D1, and the ruling on its open question: it does not serialize.
    // A dump is of a MOUNTED graph, the plane is a property of the parse, and
    // putting it on the wire would bump `fmt_version`, move G2's frozen hash
    // and drag struple's Python reader in — for nothing a host cannot ask the
    // parse for.
    //
    // Mutations that bite: default `Program.plane` to `.row` (the first two
    // assertions); write the plane into `serialize.dump` (the third).
    const src = "plane.a | mul 2 | write plane.b";
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();

    var diag = rill.Diag{};
    var prog_w = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog_w.deinit();
    var prog_r = try rill.parseKernel(testing.allocator, &reg, "p", src, &diag);
    defer prog_r.deinit();
    try testing.expectEqual(graph.EvalPlane.world, prog_w.plane);
    try testing.expectEqual(graph.EvalPlane.row, prog_r.plane);
    // …and the two spell themselves for a refusal that has to print one.
    try testing.expectEqualStrings("plane", prog_w.plane.spelling());
    try testing.expectEqualStrings("row", prog_r.plane.spelling());

    // Two programs that differ ONLY in their plane dump byte-identically.
    var mock_w = rill.MockPlane.init(testing.allocator);
    defer mock_w.deinit();
    try mock_w.putValue("plane.a", @as(i64, 3));
    var rt_w = try rill.Runtime.mount(testing.allocator, &prog_w, mock_w.asPlane(), .{});
    defer rt_w.deinit();
    try rt_w.tick(.{});
    const dump_w = try rill.dump(&rt_w, testing.allocator);
    defer testing.allocator.free(dump_w);

    var mock_r = rill.MockPlane.init(testing.allocator);
    defer mock_r.deinit();
    try mock_r.putValue("plane.a", @as(i64, 3));
    var rt_r = try rill.Runtime.mount(testing.allocator, &prog_r, mock_r.asPlane(), .{});
    defer rt_r.deinit();
    try rt_r.tick(.{});
    const dump_r = try rill.dump(&rt_r, testing.allocator);
    defer testing.allocator.free(dump_r);

    try testing.expectEqualSlices(u8, dump_w, dump_r);

    // The honest consequence of not serializing it, gated so it is a decision
    // and not a surprise: a RESTORED program cannot know what it was parsed
    // as. `loadProgram` gives every dump the default, and a host that needs
    // the plane after a restore has to remember it — which is the same thing
    // it already does for `exports` and `warnings`.
    var restored = try rill.loadProgram(testing.allocator, &reg, dump_r);
    defer restored.deinit();
    try testing.expectEqual(graph.EvalPlane.world, restored.plane);
}

// ---------------------------------------------------------------------------
// THE NORTHSTAR — one `.rill` file as a self-contained package.
//
// This is what all five beats of the run were for, and it is the gate to read
// first. Every piece landed in a different beat and this asserts they survive
// TOGETHER, in one file, in one parse:
//
//   · `using … as :k`          — the fold (beat 1)
//   · `export def` + defaults + ranges + `describe`  — the pack (beat 2)
//   · a def ending in `write`  — the effect pass-through (beat 3)
//   · `plane.…@self.…` in a def body — relative close-over (beat 4)
//   · `on row` and `row.…`     — the plane declaration (this beat)
//
// It is deliberately NOT a working spindrift kernel: there is no `spawn` and
// no row word, because those are HOST words and rill core does not have them.
// What it proves is that the SHAPES compose. rill does not know what a kernel
// is and this gate must not teach it.
// ---------------------------------------------------------------------------

const northstar_package =
    \\using plane.drift.@self.k as :k
    \\
    \\export def roaches(rate = 60 (0..500), flock = -0.03 (-0.1..0.1)) =
    \\    lfo sine 7s | mul 0.05 | sub 0.03 | write :k.flock
    \\
    \\describe roaches
    \\    "Cockroaches milling on a floor, scattering and regrouping."
    \\    rate  "how many rows are born each second"
    \\    flock "cohesion: negative gathers, positive scatters"
    \\
    \\export def scuttle() on row =
    \\    row.seed | mul 0.025 | add 0.03 | write row.size
    \\
    \\describe scuttle
    \\    "Each row's size settles from the seed it was born with."
    \\
;

test "NORTHSTAR: one file carries a fold, a described pack, an @self driver and a row def" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();

    // --- it parses, as a WORLD program, and the pack survives whole --------
    var prog = try parseOk(testing.allocator, &reg, northstar_package ++ "\nroaches\n");
    defer prog.deinit();
    try testing.expectEqual(graph.EvalPlane.world, prog.plane);
    try testing.expectEqual(@as(usize, 2), prog.exports.items.len);

    const r = prog.exported("roaches") orelse {
        std.debug.print("'roaches' is not on Program.exports\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("Cockroaches milling on a floor, scattering and regrouping.", r.doc);
    try testing.expectEqual(@as(usize, 2), r.ports.len);
    try testing.expectEqualStrings("rate", r.ports[0].name);
    try testing.expectEqual(@as(f64, 60), types.asNumber(r.ports[0].default.?).?);
    try testing.expectEqual(@as(f64, 0), types.asNumber(r.ports[0].min.?).?);
    try testing.expectEqual(@as(f64, 500), types.asNumber(r.ports[0].max.?).?);
    try testing.expectEqualStrings("how many rows are born each second", r.ports[0].doc);
    try testing.expectEqualStrings("flock", r.ports[1].name);
    try testing.expectEqual(@as(f64, -0.03), types.asNumber(r.ports[1].default.?).?);
    try testing.expectEqual(@as(f64, -0.1), types.asNumber(r.ports[1].min.?).?);
    try testing.expectEqualStrings("cohesion: negative gathers, positive scatters", r.ports[1].doc);

    // --- the planes are recorded, and they are DISTINCT -------------------
    const s = prog.exported("scuttle") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(graph.EvalPlane.world, r.plane);
    try testing.expectEqual(graph.EvalPlane.row, s.plane);
    try testing.expectEqual(@as(usize, 0), s.ports.len);
    try testing.expectEqualStrings("Each row's size settles from the seed it was born with.", s.doc);

    // --- the @self fold folded, and the world-plane driver drives ---------
    // `:k` spliced `plane.drift.@self.k`, `.flock` continued it, and the
    // whole path landed on `write`'s target static inside a def body — three
    // beats' rules stacked on one line.
    try testing.expect(hasWrite(&prog, "plane.drift.@self.k.flock"));
    try testing.expect(nodeIdOf(&prog, "roaches1.write1") != null);

    // --- and the row def reaches the row, when a row statement calls it ---
    var kern = try parseKernelOk(testing.allocator, &reg, northstar_package ++ "\nscuttle\n");
    defer kern.deinit();
    try testing.expectEqual(graph.EvalPlane.row, kern.plane);
    try testing.expect(hasSub(&kern, "row.seed"));
    try testing.expect(hasWrite(&kern, "row.size"));
    // (`mul2`, not `mul1`: the op counter is program-wide and `roaches`
    // already spent `mul1` — which is itself the receipt that both defs were
    // parsed out of one file.)
    try testing.expect(nodeIdOf(&kern, "scuttle1.mul2") != null);
    // The exports are the same two, whichever door the file came through.
    try testing.expectEqual(@as(usize, 2), kern.exports.items.len);
    try testing.expectEqual(graph.EvalPlane.row, (kern.exported("scuttle") orelse return error.TestUnexpectedResult).plane);

    // --- the row def cannot be called from the world half of the file -----
    var diag = rill.Diag{};
    try testing.expectError(error.Parse, rill.parse(testing.allocator, &reg, "p", northstar_package ++ "\nscuttle\n", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.msg(), "declared `on row`") != null);

    // --- and the parity gate is still armed over the pack -----------------
    // An undescribed port is refused by name, `on row` or not — visibility is
    // a different question from reach, and the plane declaration did not
    // quietly disarm the burden the parameter-pack beat put on the author.
    try expectParseError(
        \\export def roaches(rate = 60 (0..500), flock = -0.03) on row =
        \\  rate | mul flock | write row.size
        \\
        \\describe roaches
        \\    "Cockroaches milling on a floor."
        \\    rate "how many rows are born each second"
    , "port 'flock' has no description");
}

// ---------------------------------------------------------------------------
// The script and the printer (R1/R2, 2026-09-09) — `src/script.zig`.
//
// The parse flattens: a def body is spliced away, a fold is expanded, a
// comment is dropped in the tokenizer. That is right for an evaluator and
// fatal for an EDITOR, which has to hand the file back. `Program.script` is
// the other half — the same text, as written — and `script.print` puts it
// back.
//
// The printer is NOT byte-faithful to arbitrary input and does not claim to
// be. It is *semantically* faithful and *stable*, and the three gates below
// say exactly that: the same program comes back, the second print is the
// same bytes as the first, and no comment is lost on the way. Everything
// else is a canon (one statement one line UNTIL it runs past 88 columns and
// then it breaks; four-space bodies; blank runs kept as written), and a canon
// is only worth having if it does not move.
//
// The 47-file sibling corpus is measured by `zig build roundtrip` rather than
// here: rill must stay buildable without matryoshka and spindrift, and 21 of
// those files use host words rill core must not have. All 47 pass, 19 of them
// byte-identically — 39 before the width canon (R3) landed, and the 20 that
// left the count are the 20 whose lines were over 88. See
// `tools/roundtrip.zig`.
//
// Every gate below names the mutation that had to bite before it was believed.
// ---------------------------------------------------------------------------

/// A parsed program's STRUCTURE as bytes — the round-trip oracle, built from
/// `serialize.zig` rather than from a new comparator.
///
/// `restore`, not `mount`: restore subscribes and does NOT tick, so what the
/// dump holds is nodes, wires, statics and order with no live state and no
/// tick-0 refusal. Two programs whose dumps are equal have the same graph in
/// the same order, which is the whole of what the printer owes.
fn structureOf(prog: *rill.Program) ![]u8 {
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var rt = try rill.Runtime.restore(testing.allocator, prog, mock.asPlane(), .{});
    defer rt.deinit();
    return rill.dump(&rt, testing.allocator);
}

fn countCommentLines(src: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |ln| {
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, ln, " \t"), "//")) n += 1;
    }
    return n;
}

/// Every comment the parse retained, counted off the script itself.
///
/// The text count above cannot see a TRAILING comment — `plane.hp | clamp 0
/// 100 // what's flowing` is not a comment LINE — so on its own it would have
/// let the printer drop every one of them silently. It did, until the
/// manual's §7 examples said so.
fn countScriptComments(s: *const rill.script.Script) usize {
    var n: usize = s.tail.len;
    for (s.top) |it| n += itemComments(s, it);
    return n;
}

fn itemComments(s: *const rill.script.Script, it: rill.script.Item) usize {
    return switch (it) {
        .stmt => |st| st.lead.len + @intFromBool(st.trail.len > 0) + stagesComments(st.stages),
        .using => |u| u.lead.len + @intFromBool(u.trail.len > 0),
        .annex => |a| a.lead.len + @intFromBool(a.trail.len > 0),
        .def => |i| blk: {
            const d = s.defs[i];
            var n = d.lead.len + @intFromBool(d.trail.len > 0);
            for (d.body) |b| n += itemComments(s, b);
            break :blk n;
        },
    };
}

fn stagesComments(list: []const rill.script.Stage) usize {
    var n: usize = 0;
    for (list) |sg| switch (sg) {
        .fan => |f| for (f.branches) |b| {
            n += b.lead.len + @intFromBool(b.trail.len > 0) + stagesComments(b.stages);
        },
        else => {},
    };
    return n;
}

/// G-roundtrip + G-idempotent + G-comments over one program. Every caller
/// below runs all three, because they fail in different ways: a printer can
/// emit a different program (drift), the same program spelled differently
/// every time (churn), or the right program with the prose deleted.
fn expectRoundTrip(reg: *rill.Registry, src: []const u8, where: []const u8) !void {
    var diag = rill.Diag{};
    var prog = rill.parse(testing.allocator, reg, "rt", src, &diag) catch |err| {
        if (err == error.Parse) std.debug.print("{s}: source does not parse — {s} (line {d}, col {d})\n{s}\n", .{ where, diag.msg(), diag.line, diag.col, src });
        return err;
    };
    defer prog.deinit();

    const once = try rill.printScript(testing.allocator, prog.script orelse return error.TestUnexpectedResult);
    defer testing.allocator.free(once);

    var diag2 = rill.Diag{};
    var prog2 = rill.parse(testing.allocator, reg, "rt", once, &diag2) catch |err| {
        if (err == error.Parse) std.debug.print("{s}: the PRINT does not parse — {s} (line {d}, col {d})\n--- printed ---\n{s}\n--- source ---\n{s}\n", .{ where, diag2.msg(), diag2.line, diag2.col, once, src });
        return err;
    };
    defer prog2.deinit();

    // G-roundtrip.
    const a = try structureOf(&prog);
    defer testing.allocator.free(a);
    const b = try structureOf(&prog2);
    defer testing.allocator.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print("{s}: reprint is a DIFFERENT program\n--- source ---\n{s}\n--- printed ---\n{s}\n", .{ where, src, once });
        return error.TestUnexpectedResult;
    }

    // G-idempotent.
    const twice = try rill.printScript(testing.allocator, prog2.script orelse return error.TestUnexpectedResult);
    defer testing.allocator.free(twice);
    if (!std.mem.eql(u8, once, twice)) {
        std.debug.print("{s}: printing twice MOVED the file\n--- once ---\n{s}\n--- twice ---\n{s}\n", .{ where, once, twice });
        return error.TestUnexpectedResult;
    }

    // G-comments, both ways: the text count catches a whole block going
    // missing, and the script count catches a trailing comment being eaten —
    // which the text count cannot see, because it is not a comment LINE.
    const before = countCommentLines(src);
    const after = countCommentLines(once);
    if (before != after) {
        std.debug.print("{s}: {d} comment lines in, {d} out\n--- printed ---\n{s}\n", .{ where, before, after, once });
        return error.TestUnexpectedResult;
    }
    const kept = countScriptComments(prog.script.?);
    const rekept = countScriptComments(prog2.script.?);
    if (kept != rekept) {
        std.debug.print("{s}: {d} comments retained, {d} after the round trip\n--- printed ---\n{s}\n", .{ where, kept, rekept, once });
        return error.TestUnexpectedResult;
    }
}

/// The fixture corpus: one program per syntactic shape the printer has to
/// know about. The manuals and the rillbook (below) cover breadth — 130-odd
/// real programs — and these cover the shapes a doc example never writes:
/// comment blocks, blank runs, folds, defs with packs, fan-out, tails.
const script_fixtures = [_][]const u8{
    // a bare chain, and the two-word host verb
    \\cube 2 | bevel 0.1 | rot 45 as body
    \\body | shell 0.2 | tap out
    ,
    // comments leading, between, and at the end of the file — the shape
    // `kernels/roaches.rill` is made of
    \\// The gate guard, standing order 2.
    \\//
    \\// "At the sound of the alarm, drop the portcullis."
    \\plane.signals.horn | write plane.gate.portcullis 1
    \\
    \\
    \\// Two blank lines above this one, on purpose.
    \\plane.signals.horn | write plane.gate.drawbridge 1
    \\
    \\// And a trailing block nothing leads.
    ,
    // a fold, spliced into an argument and composed with a projection
    \\using plane.drift.@self.k as :k
    \\
    \\plane.a | mul :k.gain | write plane.out
    \\:k.tight | add 1 | tap t
    ,
    // a def with a full parameter pack, an export, a describe block, and a
    // call that leans on the defaults
    \\export def scatter(rate: number = 60 (0..500), speed = 0.15 (0..5)) =
    \\    rate | mul speed
    \\
    \\describe scatter
    \\    "Rows thrown outward from a point."
    \\    rate "How many a second."
    \\    speed "How fast, in metres a second."
    \\
    \\scatter | write plane.drift.rate
    \\scatter 120 0.3 | write plane.drift.fast
    ,
    // a local def with a multi-statement body — the tunnel, two levels
    \\def driver(x: number) =
    \\    // a comment inside a def body
    \\    x | mul 0.05 as g
    \\    g | add 1
    \\
    \\plane.a | driver | write plane.out
    ,
    // records, arrays, projections, and the `| .field` sugar
    \\[{x: 0, y: 6, z: 0}, {x: 40, y: 6, z: -30}] as track
    \\plane.t | along track loop as here
    \\here | .x | write plane.out
    \\track | write plane.draw.knots
    ,
    // fan-out both ways: the head block and the mid-chain `also`
    \\plane.a | rose_above 0.5 | also { write plane.b 1 } | write plane.c 2
    \\every 1s {
    \\    write plane.d 1
    \\    write plane.e 2
    \\}
    ,
    // predicate sections, keyword arguments in both spellings, durations
    \\plane.xs | keep (> 0) | tap kept
    \\plane.ys | sort by (.x) | tap sorted
    \\once 1 | cast $tilt 1.0 radius 25 at {x: -12, y: 3, z: 0}
    \\once 1 | cast $wind 2.0 radius 5 at: {x: 1, y: 0, z: 0}
    ,
    // a tail port: the rest of the line is text, slashes and colons included
    \\sound play /tmp/loop.wav
    \\say the tail takes everything: slashes/and/colons
    \\plane.x | emitter drop pop /tmp/a.wav
    ,
    // effect modes and flag words, which ride as bare-word arguments
    \\plane.a | write plane.b hold
    \\plane.c | write plane.d add
    ,
    // trailing comments, which are NOT comment lines — the manual's own
    // spelling, and the one the first draft of this printer walked a line
    // down the file on every save
    \\// a lead
    \\plane.hp | clamp 0 100 | write plane.ui.bar  // what's flowing
    \\plane.a | write plane.b 1  // this, because something flowed
    ,
    // R3, the width canon: every shape that BREAKS, written already broken,
    // so the three checks above cover the wrapped forms as well as the flat
    // ones. A printer that could produce a shape its own parser refuses, or
    // that reflowed it differently on the second save, would be caught here
    // rather than by a person reading a diff.
    \\def spin(
    \\    rate = 60 (0..500),
    \\    speed = 0.15 (0..5),
    \\    spread = 0.35 (0..3),
    \\    life = 14000 (16..60000)
    \\) on row =
    \\    rate | mul speed | mul spread | mul life
    \\
    \\plane.input.kbd.d
    \\    | sub plane.input.kbd.a
    \\    | mul 0.12
    \\    | write plane.camera.thrust.right add
    \\
    \\plane.t
    \\    | over plane.life [
    \\        {l: 1.5, a: 0.08, b: 0.14},
    \\        {l: 1.3, a: 0.12, b: 0.12},
    \\        {l: 0.95, a: 0.14, b: 0.08}
    \\    ]
    \\    | write plane.colour
    ,
};

test "R2 G-roundtrip: parse → print → parse is the same program" {
    // Mutations that bite, all four executed and watched:
    //
    //   · in `script.print`, walk `s.top` in reverse — local names are
    //     single-assignment and must be defined before use, so parse order IS
    //     topological order (`parser.zig`'s header), and any other order
    //     writes a file that binds differently or does not parse. Fixture 0
    //     refuses with "unknown operator or name 'body'".
    //   · delete `arg.syn = …` in `parseArgValue` — every argument prints
    //     empty and the reprint refuses.
    //   · delete the `self.closeLine()` above `const syn_trail` in `parseDef`
    //     — the body's first statement measures its blank run from before the
    //     signature, and fixture 3 grows by that much per print (idempotence).
    //   · delete the `self.closeLine()` after the `{` in `parseAlsoBlock` —
    //     same shape, fixture 6.
    //
    // What this gate is BLIND to, on purpose, and why the byte-level gates
    // below exist: losing a blank line is semantically identical AND stable,
    // so all three checks pass. `closeLine` reading `self.peek()` instead of
    // the last consumed token eats the blank line under a `describe` block
    // and this gate never notices — G-pack and G-annex do.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    for (script_fixtures, 0..) |src, i| {
        var buf: [64]u8 = undefined;
        try expectRoundTrip(&reg, src, try std.fmt.bufPrint(&buf, "fixture {d}", .{i}));
    }
}

test "R2 G-roundtrip: the manuals and the idioms book round-trip too" {
    // Breadth, for free: every ```rill fence in the two manuals, the README
    // and the RBF words doc, plus every cell of `idioms.rillbook` — around
    // 130 real programs that are already gated as parseable. A printer only a
    // hand-written fixture set has seen is a printer that has seen what its
    // author thought of.
    //
    // Mutations that bite: in `renderTokens`, return `t.text` for a `.string`
    // token without re-quoting (every program holding a string literal
    // reprints as a bare word and refuses); make `takeTrail` always return ""
    // (a trailing `// …` falls through to the NEXT statement's lead and
    // prints a line lower — which is how trailing comments were found to
    // exist at all: the manual's §7 writes `plane.hp | clamp 0 100 // what's
    // flowing`, and the first draft of this printer walked it down the file
    // on every save).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var n: usize = 0;
    inline for (.{ "rill-manual.md", "rill-for-agents.md", "README.md", "rbf-words.md" }) |doc| {
        n += try roundTripManual(@embedFile(doc), &reg, doc);
    }
    n += try roundTripBook(@embedFile("idioms.rillbook"), &reg, "idioms.rillbook");
    // Both ways, like the parse gate beside it: a corpus that silently
    // stopped being collected would pass vacuously.
    try testing.expect(n >= 120);
}

fn roundTripManual(doc: []const u8, reg: *rill.Registry, doc_name: []const u8) !usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, doc, pos, "```rill\n")) |start| {
        const body_start = start + "```rill\n".len;
        const end = std.mem.indexOfPos(u8, doc, body_start, "```") orelse return error.TestUnexpectedResult;
        try expectRoundTrip(reg, doc[body_start..end], doc_name);
        count += 1;
        pos = end;
    }
    return count;
}

fn roundTripBook(doc_src: []const u8, reg: *rill.Registry, doc_name: []const u8) !usize {
    const parsed = try std.json.parseFromSlice(BookDoc, testing.allocator, doc_src, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var count: usize = 0;
    for (parsed.value.cells) |cell| {
        if (cell.markdown) continue;
        try expectRoundTrip(reg, cell.source, doc_name);
        count += 1;
    }
    return count;
}

test "R2 G-comments: a comment block survives with its blank runs" {
    // The gate the editor lives or dies on. `kernels/roaches.rill` is the
    // project's documented exemplar and is roughly four-fifths prose; a
    // round trip that eats it has deleted the only documentation of the thing
    // it just edited.
    //
    // Mutation that bites: delete the `try self.lead(st.lead, depth)` call in
    // `Printer.item` — the leading comment block vanishes and the counts
    // below go 5 → 0. (The blank-run assertions bite a second mutation:
    // print `blank_before` as a constant 1.)
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\// one
        \\// two
        \\plane.a | write plane.b 1
        \\
        \\
        \\// three, under two blank lines
        \\plane.c | write plane.d 2
        \\
        \\// four, leading nothing
        \\// five
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const out = try rill.printScript(testing.allocator, prog.script.?);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
    try testing.expectEqual(@as(usize, 5), countCommentLines(out));
    // The trailing pair leads nothing and lands on `Script.tail`, which is
    // the only place it can go and still be printed.
    try testing.expectEqual(@as(usize, 2), prog.script.?.tail.len);
}

test "R2 G-fold: a fold prints as the reference, never as its expansion" {
    // Its own gate, and this is exactly why: an expansion is SEMANTICALLY
    // IDENTICAL, so G-roundtrip sees nothing wrong with it — the graph is the
    // same graph either way. What is lost is the file: `:k.tight` becoming
    // `plane.drift.@self.k.tight` everywhere unbinds the fold from its uses,
    // and the next edit to the room has to be made in nine places.
    //
    // Mutation that bites: in `renderTokens`, delete the `t.fold != 0` branch
    // so spliced tokens render as themselves. `using` still prints, and every
    // `:k` in the body comes back expanded — this gate goes red and
    // G-roundtrip stays green.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\using plane.drift.@self.k as :k
        \\
        \\plane.a | mul :k.tight | write plane.out
        \\:k.wide | tap w
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const out = try rill.printScript(testing.allocator, prog.script.?);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
    try testing.expect(std.mem.indexOf(u8, out, ":k.tight") != null);
    try testing.expect(std.mem.indexOf(u8, out, ":k.wide") != null);
    try testing.expect(std.mem.indexOf(u8, out, "plane.drift.@self.k.tight") == null);
    // …and the graph still holds the expansion, because that is the half the
    // evaluator needs. Both truths, one parse.
    try testing.expect(hasSub(&prog, "plane.drift.@self.k.tight"));
}

test "R1 G-tunnel: a def is its own nested graph, and prints as a def" {
    // The hard requirement of the beat: drill in, edit, drill out. A def body
    // that is not separately addressable is not a tunnel, and a printer that
    // flattens a def into its call site has thrown the definition away — the
    // graph would still be right and the FILE would have lost a concept.
    //
    // Mutations that bite: (1) drop the `program_target.items.append(.{ .def
    // = … })` in `parseDef` — the definition vanishes from the print and the
    // reprint refuses with "unknown operator or name 'driver'". (2) point
    // `script.Def.body` at `&.{}` instead of `target.items.items` — the def
    // prints with an empty body and the reprint refuses with "has an empty
    // body". Either one takes the last assertion here with it.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\def driver(x: number) =
        \\    // the body's own comment
        \\    x | mul 0.05 as g
        \\    g | add 1
        \\
        \\plane.a | driver | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const s = prog.script.?;

    // The tunnel: one definition, and its body is a block of its own with the
    // two statements the author wrote — not a flattened fragment of the top
    // level, and not text.
    try testing.expectEqual(@as(usize, 1), s.defs.len);
    try testing.expectEqualStrings("driver", s.defs[0].name);
    try testing.expectEqual(@as(usize, 2), s.defs[0].body.len);
    try testing.expectEqualStrings("x", s.defs[0].ports[0].name);
    try testing.expectEqualStrings("number", s.defs[0].ports[0].ty);
    // The top level holds the DOOR, not the body: a `.def` item and the one
    // statement that calls it.
    try testing.expectEqual(@as(usize, 2), s.top.len);
    try testing.expect(s.top[0] == .def);
    try testing.expectEqual(@as(u32, 0), s.top[0].def);

    const out = try rill.printScript(testing.allocator, s);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "R1 G-origin: a flattened node names the definition that produced it" {
    // `def` bodies are spliced into the graph with an instance-name prefix and
    // the graph does not know defs exist — so an editor looking at a node has
    // no way to ask "which definition should I tunnel into?" unless the parse
    // records it. The name (`driver1.mul1`) would have answered, and a
    // derivation is a second parser for a format nothing else pins.
    //
    // Mutation that bites: delete the `origin_spans.append` in `instantiate`
    // — every origin comes back null and the two assertions below fail.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\def driver(x: number) = x | mul 0.05
        \\plane.a | driver | write plane.out
        \\plane.b | mul 2 | tap t
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const s = prog.script.?;
    try testing.expectEqual(prog.nodes.items.len, s.origins.len);

    var from_def: usize = 0;
    var free_standing: usize = 0;
    for (prog.nodes.items, s.origins) |n, o| {
        if (o) |org| {
            from_def += 1;
            try testing.expectEqualStrings("driver", s.defs[org.def].name);
            // The instance prefix the parser minted is on both, and they agree.
            try testing.expect(std.mem.startsWith(u8, n.name, org.instance));
        } else free_standing += 1;
    }
    try testing.expect(from_def >= 1);
    try testing.expect(free_standing >= 1);
}

test "R2 G-pack: a port's default and its range survive as written" {
    // A pack that loses its default changes what the file MEANS — a port with
    // no default is required, so `scatter` with no arguments stops parsing.
    // A pack that loses its range loses only the widget's advice, which
    // nothing at runtime reads and no dump records: G-roundtrip is blind to
    // it, so it is asserted here by name.
    //
    // Mutations that bite: delete `syn_port.default = …` in `parseDef` (the
    // reprint refuses with "port 'rate' of 'scatter' is not bound"); delete
    // `syn_port.min = …` (the range vanishes from the print and the two
    // `indexOf` assertions fail while everything else stays green).
    //
    // And a third, which lives here because nothing else catches it: make
    // `closeLine` read `self.peek().line` instead of the last consumed
    // token's. A `describe` block ends at a dedent, so the cursor is already
    // on the NEXT item several lines down, and the blank line under the block
    // is eaten. G-roundtrip is blind to that — a lost blank is semantically
    // identical and perfectly stable — so it takes a byte comparison over a
    // program with a `describe` block in it, which is this one.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\export def scatter(rate: number = 60 (0..500), speed = 0.15 (0..5)) =
        \\    rate | mul speed
        \\
        \\describe scatter
        \\    "Rows thrown outward from a point."
        \\    rate  "How many a second."
        \\    speed "How fast."
        \\
        \\scatter | write plane.drift.rate
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const out = try rill.printScript(testing.allocator, prog.script.?);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
    try testing.expect(std.mem.indexOf(u8, out, "rate: number = 60 (0..500)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "speed = 0.15 (0..5)") != null);
}

test "R2 G-kw: a keyword argument keeps its name AND its spelling" {
    // Two claims, and they fail differently. Dropping the NAME is not
    // equivalent: a keyword-declared port never fills positionally (the `arm
    // gate_closed` rule), so `cast $t 1.0 radius 25 {…}` refuses outright and
    // G-roundtrip catches it. Dropping the COLON *is* equivalent — `at 5` and
    // `at: 5` are one binding — which is precisely why the spelling needs a
    // gate of its own: nothing downstream can tell, and the file would drift
    // on every save.
    //
    // Mutations that bite: in `Printer.call`, print `arg.text` without
    // `arg.kw` (G-roundtrip red, this gate red); ignore `arg.kw_colon` and
    // always emit a space (only this gate red).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\once 1 | cast $tilt 1.0 radius 25 at {x: -12, y: 3, z: 0}
        \\once 1 | cast $wind 2.0 radius 5 at: {x: 1, y: 0, z: 0}
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const out = try rill.printScript(testing.allocator, prog.script.?);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "R2 G-annex: a describe block survives with every line" {
    // `describe` is retained as an ANNEX — one instance of "a block the
    // parser reads, the runtime elides and the document keeps" — because
    // Christian ruled on 2026-09-09 that the editor's node positions land the
    // same way (`layout roaches` keyed by instance name, naming `describe` as
    // the precedent). The generality is the point: a second such block must
    // cost a reader in the parser and nothing in the printer.
    //
    // Mutation that bites: drop the last `lines.append` in `parseDescribe` —
    // the printed block loses a port's line and the reprint refuses at the
    // parity gate with "port 'speed' has no description". A local def would
    // hide that, so the fixture is exported on purpose. (This gate is
    // G-pack's twin for the `closeLine` mutation too — see the note there.)
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\export def scatter(rate = 60, speed = 0.15) =
        \\    rate | mul speed
        \\
        \\describe scatter
        \\    "Rows thrown outward from a point."
        \\    rate  "How many a second."
        \\    speed "How fast, with a \"quoted\" word in it."
        \\
        \\scatter | tap s
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const s = prog.script.?;
    // The annex is generic: a keyword, a subject, and lines of key + values.
    const an = for (s.top) |it| {
        if (it == .annex) break it.annex;
    } else return error.TestUnexpectedResult;
    try testing.expectEqualStrings("describe", an.keyword);
    try testing.expectEqualStrings("scatter", an.subject);
    try testing.expectEqual(@as(usize, 3), an.lines.len);
    try testing.expectEqualStrings("", an.lines[0].key); // the leading bare string
    try testing.expectEqualStrings("rate", an.lines[1].key);

    const out = try rill.printScript(testing.allocator, s);
    defer testing.allocator.free(out);
    // The escape survives verbatim: the annex keeps the SPELLING, and the
    // pack keeps the decoded sentence.
    try testing.expectEqualStrings(src, out);
    try testing.expectEqualStrings(
        "How fast, with a \"quoted\" word in it.",
        (prog.exported("scatter") orelse return error.TestUnexpectedResult).ports[1].doc,
    );
}

test "R1: retaining the script changes nothing the runtime can see" {
    // The beat's own claim, asserted rather than assumed: R1 is purely
    // additive. A program parsed today has the same nodes, the same slots and
    // the same DUMP it had before `Program.script` existed — the script is
    // not serialized and nothing below the parser reads it.
    //
    // Mutation that bites: add `script` to `serialize.dump`'s entry list —
    // the frozen G2 hash moves, this gate's dump-length claim survives, and
    // that is the point of pinning the hash rather than the shape. (The
    // ACTUAL guard is G2's frozen reference two thousand lines above; this
    // gate states the intent beside the feature so a reader meets it here.)
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx, g2_source, .{
        .{ "plane.player.health", @as(i64, 80) },
        .{ "plane.player.stamina", @as(i64, 50) },
        .{ "plane.player.underwater", true },
    });
    defer fx.deinit();
    try testing.expect(fx.prog.script != null);
    const d = try rill.dump(&fx.rt, testing.allocator);
    defer testing.allocator.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "script") == null);
}

test "R2 G-column: an annex aligns its values, and a def body indents by four" {
    // Two whitespace claims, both byte-level, because whitespace is the half
    // G-roundtrip is blind to (see the note on that gate).
    //
    // ALIGNMENT is not decoration. `describe roaches` runs to eleven ports
    // and Christian hand-aligned the column, which is what makes a block that
    // size readable; an editor that collapses it degrades the file's
    // documentation a little on every save, and roaches.rill is the file the
    // project points people at. Padding to the longest key is deterministic,
    // so idempotence is untouched.
    //
    // THE INDENT is four, everywhere and unconditionally — Christian's
    // ruling, 2026-09-09. Asked first about def bodies ("honestly I'd prefer
    // 4, to match most tabs") and then about a fan-out's branches, he
    // answered wider than the question: "four everywhere." So a def body, a
    // `describe` block's lines and a fan-out's branches share ONE constant —
    // not several that happen to agree, which is an invitation to drift and
    // to re-open a closed question.
    //
    // An interim pass RETAINED whatever was written, because the measurement
    // found the corpus split between `kernels/roaches.rill` at 4 and the six
    // def bodies printed in the manuals at 2. The second block below is what
    // proves the ruling replaced it: a body WRITTEN at two comes back at
    // four, which is the one assertion retention could never have made.
    //
    // Mutations that bite: in `Printer.item`'s annex arm, write a single
    // space instead of `key_w - al.key.len + 1` (the column collapses and the
    // first block goes red); set `indent_canon` to 2 (both blocks go red);
    // apply `indent_canon` to the def body but not to the annex lines (the
    // first block goes red on its `describe` lines alone, which is the gate
    // saying the ONE constant reaches all three places).
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();

    // A wide column, the shape roaches.rill has: the longest key sets it and
    // the leading bare string is NOT in it.
    const aligned =
        \\export def scatter(rate = 60, speed = 0.15, capacity = 100) =
        \\    rate | mul speed | mul capacity
        \\
        \\describe scatter
        \\    "Rows thrown outward from a point."
        \\    rate     "How many a second."
        \\    speed    "How fast."
        \\    capacity "How many seats the hall has."
        \\
        \\scatter | tap s
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", aligned, &diag);
    defer prog.deinit();
    const out = try rill.printScript(testing.allocator, prog.script.?);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(aligned, out);

    // A body WRITTEN at two comes back at four: the canon is applied, not
    // echoed. This is the assertion retention could never have made.
    const twospace =
        \\def driver(x: number) =
        \\  x | mul 0.05 | add 1
        \\
        \\plane.a | driver | write plane.out
        \\
    ;
    const restretched =
        \\def driver(x: number) =
        \\    x | mul 0.05 | add 1
        \\
        \\plane.a | driver | write plane.out
        \\
    ;
    var diag2 = rill.Diag{};
    var prog2 = try rill.parse(testing.allocator, &reg, "p", twospace, &diag2);
    defer prog2.deinit();
    const out2 = try rill.printScript(testing.allocator, prog2.script.?);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings(restretched, out2);
    // …and the restretched form is a fixed point, so the second save does
    // nothing. A canon that moved a file once per save would be worse than
    // the split it replaced.
    var diag3 = rill.Diag{};
    var prog3 = try rill.parse(testing.allocator, &reg, "p", restretched, &diag3);
    defer prog3.deinit();
    const out3 = try rill.printScript(testing.allocator, prog3.script.?);
    defer testing.allocator.free(out3);
    try testing.expectEqualStrings(restretched, out3);
}

// ---------------------------------------------------------------------------
// R3 — the width canon (2026-09-09). `script.zig`'s `width_canon`.
//
// Christian, reading two of his own lines: *"We still need to do something
// about these long lines… These are not human friendly."* The two were
// `kernels/roaches.rill`'s 234-column signature and a 128-column colour ramp.
// Three things had to move together, and they are one beat because a
// formatter that disagrees with the parser is a bug and a formatter that
// disagrees with the EDITOR is a cursor that jumps on every save:
//
//   1. the parser now accepts a newline inside a def signature's parens —
//      the one place in the language that still said no;
//   2. the printer breaks a line that runs past 88 columns, outermost first;
//   3. `editors/vscode` learned the same shapes (its own gates, its own
//      mutation runner).
//
// The gates below are the printer's. Each names the mutation that was
// executed against it and watched go red; the fixtures were chosen by
// measuring the corpus first, because a width mutation tested on input that
// takes an early return proves nothing.
// ---------------------------------------------------------------------------

test "R3 G-wrap: a chain over the width breaks, one stage per line" {
    // BOTH HALVES, and they need each other: "always break" passes the first
    // and fails the second, "never break" the other way round. The two
    // fixtures are `src/rills/camera.rill`'s two thrust lines, which is where
    // the 88 was measured — one is 90 columns and one is 78.
    //
    // Mutations, both executed:
    //   · in `Printer.pipe`, drop the `lay` test and always write `" | "` —
    //     the chain never breaks and the first block goes red.
    //   · in `Printer.item`'s stmt arm, initialise `best` to `.broken` and
    //     skip the loop — every chain breaks and the second block goes red.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const over =
        \\plane.input.kbd.d | sub plane.input.kbd.a | mul 0.12 | write plane.camera.thrust.right add
        \\
    ;
    const broken =
        \\plane.input.kbd.d
        \\    | sub plane.input.kbd.a
        \\    | mul 0.12
        \\    | write plane.camera.thrust.right add
        \\
    ;
    // …and the broken form is a fixed point: the second save does nothing.
    try expectPrintedStable(&reg, over, broken);

    // 78 columns. Under the width, so it stays the one line it was — the
    // printer breaks because a line is too long, never because it can.
    const under =
        \\plane.input.kbd.w | sub plane.input.kbd.s | mul 3 | write plane.camera.fwd add
        \\
    ;
    try expectPrinted(&reg, under, under);
}

test "R3 G-ports: a def signature over the width breaks, one port per line" {
    // The line that started the beat, shortened to four ports: 109 columns.
    // The second def in the fixture is 41 and stays inline, which is the half
    // that refuses "always break" — a two-port signature spread over four
    // lines would be worse than the thing being fixed.
    //
    // Mutations, both executed:
    //   · in `Printer.defSignature`, drop the `lay == .broken` arm and always
    //     write `", "` — the long signature stays on one line, red.
    //   · in `Printer.def`, replace the whole cascade with
    //     `best = .{ .sig = .broken, .body = .flat }` — `driver` breaks too,
    //     red on the second def.
    //
    // The `describe` block is in the fixture on purpose: its lines are the
    // one thing the width does not touch (a key and one string, and eleven of
    // roaches's twelve run past 88), and a printer that measured them would
    // have nothing to do but truncate prose.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\export def scatter(rate = 60 (0..500), speed = 0.15 (0..5), spread = 0.35 (0..3), life = 14000 (16..60000)) =
        \\    rate | mul speed | mul spread | mul life
        \\
        \\describe scatter
        \\    "Rows thrown outward from a point."
        \\    rate   "How many a second."
        \\    speed  "How fast."
        \\    spread "How wide."
        \\    life   "How long."
        \\
        \\def driver(x: number = 1 (0..9), y = 2) =
        \\    x | mul y
        \\
        \\scatter | write plane.a
        \\
    ;
    const want =
        \\export def scatter(
        \\    rate = 60 (0..500),
        \\    speed = 0.15 (0..5),
        \\    spread = 0.35 (0..3),
        \\    life = 14000 (16..60000)
        \\) =
        \\    rate | mul speed | mul spread | mul life
        \\
        \\describe scatter
        \\    "Rows thrown outward from a point."
        \\    rate   "How many a second."
        \\    speed  "How fast."
        \\    spread "How wide."
        \\    life   "How long."
        \\
        \\def driver(x: number = 1 (0..9), y = 2) =
        \\    x | mul y
        \\
        \\scatter | write plane.a
        \\
    ;
    try expectPrintedStable(&reg, src, want);
}

test "R3 G-half: a def breaks the half that does not fit, not the outer one" {
    // The signature and an inline body are SIBLINGS on one line, so
    // outermost-first has nothing to say about them and the printer measures
    // instead. `wobble` is 93 columns over a 23-column signature: breaking
    // the one port across three lines would make room for a chain it never
    // touched, and would be churn dressed as a policy.
    //
    // Mutation that bites: in `Printer.def`, use the `sig_over` order
    // unconditionally (`if (true)` in place of `if (sig_over)`). The
    // signature-first order wins, `x: number` lands on a line of its own, and
    // this goes red while every other R3 gate stays green — which is what
    // makes it a gate about the ORDER rather than about the width.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\def wobble(x: number) = x | mul 0.05 | add 1 | clamp 0 100 | mul 2 | div 3 | add 0.25 | mul 7
        \\plane.a | wobble | write plane.b
        \\
    ;
    const want =
        \\def wobble(x: number) = x
        \\    | mul 0.05
        \\    | add 1
        \\    | clamp 0 100
        \\    | mul 2
        \\    | div 3
        \\    | add 0.25
        \\    | mul 7
        \\plane.a | wobble | write plane.b
        \\
    ;
    try expectPrintedStable(&reg, src, want);
}

test "R3 G-nest: the chain breaks first, and the span only if the line is still long" {
    // OUTERMOST FIRST, and it takes two fixtures or the policy is untested:
    // one where breaking the chain is enough, and one where it is not. Both
    // are `over` with a colour ramp, which is the shape the corpus actually
    // has — nine of the 47 files carry one.
    //
    //   · 112 columns, and the ramp is short enough that the stage line lands
    //     at 80. The chain breaks; the span does NOT.
    //   · 132 columns, and the same stage line would be 107. The chain
    //     breaks, and then the span breaks too.
    //
    // Mutations, both executed:
    //   · in `Printer.fitCall`, always take the rollback branch (drop the
    //     width test) — the first fixture's ramp breaks as well, red there
    //     and green on the second, which is the gate saying "not eagerly".
    //   · in `Printer.call`, delete the `breakSpan` branch — the second
    //     fixture's stage line stays at 107, red there and green on the
    //     first.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();

    const chain_only =
        \\plane.t | over plane.life [{l: 1.5, a: 0.08}, {l: 1.3, a: 0.12}, {l: 0.95, a: 0.14}] | write plane.render.colour
        \\
    ;
    const chain_only_want =
        \\plane.t
        \\    | over plane.life [{l: 1.5, a: 0.08}, {l: 1.3, a: 0.12}, {l: 0.95, a: 0.14}]
        \\    | write plane.render.colour
        \\
    ;
    try expectPrintedStable(&reg, chain_only, chain_only_want);

    const and_span =
        \\plane.t | over plane.life [{l: 1.5, a: 0.08, b: 0.14}, {l: 1.3, a: 0.12, b: 0.12}, {l: 0.95, a: 0.14, b: 0.08}] | write plane.colour
        \\
    ;
    const and_span_want =
        \\plane.t
        \\    | over plane.life [
        \\        {l: 1.5, a: 0.08, b: 0.14},
        \\        {l: 1.3, a: 0.12, b: 0.12},
        \\        {l: 0.95, a: 0.14, b: 0.08}
        \\    ]
        \\    | write plane.colour
        \\
    ;
    try expectPrintedStable(&reg, and_span, and_span_want);
}

test "R3 G-span: a statement that is one long span breaks the span itself" {
    // `rills/follow.rill:19` — an array of knots bound with `as track`, 96
    // columns, and NO stages at all, so there is no chain to break and the
    // span is the only thing there is. It is also the fixture that found a
    // real bug: the array alone is 87 columns, so a first draft measured it
    // as fitting and left the line at 96. What it forgot was the ` as track`
    // that follows on the same line — hence `Printer.suffix`.
    //
    // Mutation that bites: in `Printer.fitValue`, drop the `+ reserve` from
    // the width test. The line comes back flat at 96 and this goes red, while
    // G-nest and G-wrap stay green — which is the bug, reproduced.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\[{x: 0, y: 6, z: 0}, {x: 40, y: 6, z: -30}, {x: 80, y: 14, z: 0}, {x: 40, y: 6, z: 30}] as track
        \\plane.t | along track loop | write plane.here
        \\
    ;
    const want =
        \\[
        \\    {x: 0, y: 6, z: 0},
        \\    {x: 40, y: 6, z: -30},
        \\    {x: 80, y: 14, z: 0},
        \\    {x: 40, y: 6, z: 30}
        \\] as track
        \\plane.t | along track loop | write plane.here
        \\
    ;
    try expectPrintedStable(&reg, src, want);

    // A BRACKET INSIDE A STRING IS NOT A BRACKET. `SpanIter` is a scan over
    // text the parser rendered, not a parse, so this is the one thing it can
    // get wrong.
    //
    // The fixture took two goes and the first one was the trap this repo
    // keeps hitting: `{a: "x, y"}` does NOT reach the string branch, because
    // the record's own braces already hold that comma at depth 1 and the
    // separator is found correctly by accident. Nor does `"p]q"`, whose stray
    // `]` is absorbed by the saturating `-|=`. The mutation SURVIVED both,
    // which is how the fixture below was found: an unbalanced OPENER inside a
    // string (`"x{y"`) leaves the scan one deep, the comma after it stops
    // being a separator, and two elements print on one line.
    //
    // Mutation that bites: delete the `if (in_string) { … }` branch from
    // `SpanIter.next`. `{a: "x{y"}` and `{a: "p]q"}` come back on one line and
    // this goes red — a byte comparison, because the program is the same one
    // either way and G-roundtrip cannot see it.
    const strings =
        \\plane.t | over plane.life [{a: "x{y"}, {a: "p]q"}, {a: "one"}, {a: "two"}, {a: "three"}, {a: "f"}] | write plane.o
        \\
    ;
    const strings_want =
        \\plane.t
        \\    | over plane.life [
        \\        {a: "x{y"},
        \\        {a: "p]q"},
        \\        {a: "one"},
        \\        {a: "two"},
        \\        {a: "three"},
        \\        {a: "f"}
        \\    ]
        \\    | write plane.o
        \\
    ;
    try expectPrintedStable(&reg, strings, strings_want);
}

test "R3 G-multiline: a wrapped signature is the same program as its one-liner" {
    // The PARSER's half of the beat, and the oracle is the one the round-trip
    // gate already uses: two programs whose structural dumps are equal have
    // the same nodes, the same wires, the same statics and the same order. A
    // gate that only checked "it parses" would have missed a newline landing
    // in a port's pack.
    //
    // The third spelling carries a TRAILING COMMA, which the language accepts
    // — the loop's own shape does it — and which earns its keep now that the
    // canon puts one port on each line: adding a port is a one-line diff that
    // never touches the line above. The printer does not emit one, so the
    // three spellings print identically, which is the second assertion.
    //
    // Mutation that bites: delete the `self.skipNewlines()` at the top of
    // `parseDef`'s port loop. The multi-line source refuses with "expected
    // port name in def signature" and this goes red on the parse. (Deleting
    // the SECOND one, before the separator, refuses the trailing-comma
    // spelling at the `)` — same gate, other line.)
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const one_line =
        \\def spin(rate = 60 (0..500), speed = 0.15 (0..5)) on row =
        \\    rate | mul speed
        \\
    ;
    const wrapped =
        \\def spin(
        \\    rate = 60 (0..500),
        \\    speed = 0.15 (0..5)
        \\) on row =
        \\    rate | mul speed
        \\
    ;
    const trailing_comma =
        \\def spin(
        \\    rate = 60 (0..500),
        \\    speed = 0.15 (0..5),
        \\) on row =
        \\    rate | mul speed
        \\
    ;
    var diag = rill.Diag{};
    var a = try rill.parse(testing.allocator, &reg, "p", one_line, &diag);
    defer a.deinit();
    var b = try rill.parse(testing.allocator, &reg, "p", wrapped, &diag);
    defer b.deinit();
    var c = try rill.parse(testing.allocator, &reg, "p", trailing_comma, &diag);
    defer c.deinit();

    const da = try structureOf(&a);
    defer testing.allocator.free(da);
    const db = try structureOf(&b);
    defer testing.allocator.free(db);
    const dc = try structureOf(&c);
    defer testing.allocator.free(dc);
    try testing.expectEqualStrings(da, db);
    try testing.expectEqualStrings(da, dc);

    // …and all three print as the one-liner, because 57 columns fits.
    try expectPrinted(&reg, one_line, one_line);
    try expectPrinted(&reg, wrapped, one_line);
    try expectPrinted(&reg, trailing_comma, one_line);
}

test "R3 G-refuse: a signature wraps between ports, and says so when it does not" {
    // A refusal must not get WORSE because a spelling got wider. Three of
    // them, and the position matters as much as the words: before this beat
    // every malformed multi-line signature refused at line 1, col 20, which
    // reads as if the port list itself were the problem.
    //
    //   · a missing comma lands on the port that followed the break, not on
    //     the `def` — the parser skips newlines but never INVENTS a
    //     separator;
    //   · a port broken across two lines is named as such, rather than
    //     quoting a literal newline into the middle of the message (which is
    //     what the general "must be a literal" arm did);
    //   · a `(` after the break is still "expected ',' or ')'".
    //
    // Mutation that bites: delete the `t.kind == .newline` arm in
    // `parseDefLiteral`. The second block's message becomes "the default must
    // be a literal, got '<newline>'" and this goes red.
    try expectParseErrorAt(
        \\def r(
        \\    rate = 60
        \\    speed = 2
        \\) = rate | add speed
    , "expected ',' or ')'", 3, 5);

    try expectParseErrorAt(
        \\def r(
        \\    rate =
        \\    60
        \\) = rate
    , "a signature may wrap between ports, but a port stays on one line", 2, 11);

    try expectParseErrorAt(
        \\def r(
        \\    rate = 60
        \\    (0..500)
        \\) = rate
    , "expected ',' or ')'", 3, 5);
}

test "R3 G-stack: eight elements stay stacked, nine pack" {
    // THE THRESHOLD, and both halves of it, because either alone survives a
    // one-sided policy: "always stack" passes the first block and fails the
    // second, "always pack" the other way round.
    //
    // Eight is Christian's *"five you wouldn't"* with headroom. The two
    // fixtures are the same numbers to the same width, one element apart, so
    // nothing but the COUNT can be what decides — which is the claim.
    //
    // Mutations, both executed:
    //   · `span_stack_max = 0` — the eight pack, first block red.
    //   · `span_stack_max = 1000` — the nine stack, second block red.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const stack8 =
        \\[0.0000000000, 0.1250000000, 0.2500000000, 0.3750000000, 0.5000000000, 0.6250000000, 0.7500000000, 0.8750000000] as curve
        \\
    ;
    const stack8_want =
        \\[
        \\    0.0000000000,
        \\    0.1250000000,
        \\    0.2500000000,
        \\    0.3750000000,
        \\    0.5000000000,
        \\    0.6250000000,
        \\    0.7500000000,
        \\    0.8750000000
        \\] as curve
        \\
    ;
    const pack9 =
        \\[0.0000000000, 0.1111111111, 0.2222222222, 0.3333333333, 0.4444444444, 0.5555555556, 0.6666666667, 0.7777777778, 0.8888888889] as curve
        \\
    ;
    const pack9_want =
        \\[
        \\    0.0000000000, 0.1111111111, 0.2222222222,
        \\    0.3333333333, 0.4444444444, 0.5555555556,
        \\    0.6666666667, 0.7777777778, 0.8888888889
        \\] as curve
        \\
    ;
    try expectPrintedStable(&reg, stack8, stack8_want);
    try expectPrintedStable(&reg, pack9, pack9_want);
}

test "R3 G-grid: the shape follows the count — a square, then a divisor, then a fill" {
    // Christian, 2026-09-09: *"A hundred records you'd want to pack, five you
    // wouldn't, and maybe if we know the denominator, we can be smart about
    // how many per row. a series of 16 looks good as 4x4, or 9 look good as
    // 3x3."* So the axis is the COUNT, and the three branches are tried in
    // that order — a square beats a fill because 16 IS 4×4, not because four
    // is the most that happened to fit.
    //
    // Every fixture is chosen so the branch under test actually decides. At
    // this width sixteen six-wide numbers fit TEN to a row, so 4×4 is a real
    // choice over the fill and not the same answer twice; twelve seven-wide
    // fit nine to a row, so 6×2 is a real choice over 9+3. A grid mutation
    // tested on a count that takes the ragged path proves nothing.
    //
    // Mutations, three, all executed:
    //   · delete the perfect-square branch from `gridFor` — 16 comes back
    //     ten to a row and the first block goes red.
    //   · delete the divisor loop — 12 comes back nine-and-three, ragged, and
    //     the third block goes red.
    //   · ignore `Grid.pad` in `breakSpan` — the varying-width block loses
    //     its column and the last block goes red.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();

    // A PERFECT SQUARE: 16 → 4×4, 9 → 3×3. His two examples, both of them.
    const square16 =
        \\[0.0000, 0.0625, 0.1250, 0.1875, 0.2500, 0.3125, 0.3750, 0.4375, 0.5000, 0.5625, 0.6250, 0.6875, 0.7500, 0.8125, 0.8750, 0.9375] as curve
        \\
    ;
    const square16_want =
        \\[
        \\    0.0000, 0.0625, 0.1250, 0.1875,
        \\    0.2500, 0.3125, 0.3750, 0.4375,
        \\    0.5000, 0.5625, 0.6250, 0.6875,
        \\    0.7500, 0.8125, 0.8750, 0.9375
        \\] as curve
        \\
    ;
    const square9 =
        \\[0.000000, 0.111111, 0.222222, 0.333333, 0.444444, 0.555556, 0.666667, 0.777778, 0.888889] as curve
        \\
    ;
    const square9_want =
        \\[
        \\    0.000000, 0.111111, 0.222222,
        \\    0.333333, 0.444444, 0.555556,
        \\    0.666667, 0.777778, 0.888889
        \\] as curve
        \\
    ;
    try expectPrintedStable(&reg, square16, square16_want);
    try expectPrintedStable(&reg, square9, square9_want);

    // NOT SQUARE: the largest exact divisor that fits, so the block closes
    // square with no ragged tail. Twelve fit nine to a row; six is the
    // largest divisor under that, and 6×2 is what a reader can count.
    const divisor12 =
        \\[0.00000, 0.08333, 0.16667, 0.25000, 0.33333, 0.41667, 0.50000, 0.58333, 0.66667, 0.75000, 0.83333, 0.91667] as curve
        \\
    ;
    const divisor12_want =
        \\[
        \\    0.00000, 0.08333, 0.16667, 0.25000, 0.33333, 0.41667,
        \\    0.50000, 0.58333, 0.66667, 0.75000, 0.83333, 0.91667
        \\] as curve
        \\
    ;
    try expectPrintedStable(&reg, divisor12, divisor12_want);

    // PRIME: nothing divides it, so it fills as far as it fits — and NOT to
    // one per line, which is the absurd answer a divisor-only rule gives (13
    // is prime, so its only divisors are 1 and 13).
    const prime13 =
        \\[0.00000, 0.07692, 0.15385, 0.23077, 0.30769, 0.38462, 0.46154, 0.53846, 0.61538, 0.69231, 0.76923, 0.84615, 0.92308] as curve
        \\
    ;
    const prime13_want =
        \\[
        \\    0.00000, 0.07692, 0.15385, 0.23077, 0.30769, 0.38462, 0.46154, 0.53846, 0.61538,
        \\    0.69231, 0.76923, 0.84615, 0.92308
        \\] as curve
        \\
    ;
    try expectPrintedStable(&reg, prime13, prime13_want);
    try testing.expect(std.mem.indexOf(u8, prime13_want, "0.00000, 0.07692") != null);

    // PADDING is what makes a grid a grid, and it is RIGHT-aligned: a ramp's
    // numbers line up on the digit that says how big they are, and the comma
    // stays glued to the value it closes. Padding on the right would put
    // `0.5      ,` in the file — a column of commas nobody asked for.
    //
    // Nothing in the 47-file corpus reaches this: its three ramps are all 121
    // elements, whose only divisors are 11 and 121, and eleven columns do not
    // fit — so all three take the ragged path and would leave this branch
    // untested. Hence a fixture with twelve elements of eight different
    // widths.
    const varying =
        \\[0.500000, 0.2500000, 0.12500000, 0.062500, 0.03125, 0.015625, 0.0078125, 0.00390625, 0.5, 0.25, 0.125, 0.0625] as curve
        \\
    ;
    const varying_want =
        \\[
        \\      0.500000,  0.2500000, 0.12500000,   0.062500,    0.03125,   0.015625,
        \\     0.0078125, 0.00390625,        0.5,       0.25,      0.125,     0.0625
        \\] as curve
        \\
    ;
    try expectPrintedStable(&reg, varying, varying_want);
}

// ---------------------------------------------------------------------------
// R3 G-doc — every printed example is a fixed point of the printer.
//
// The manuals already PARSE (see "the manuals parse", above). That gate says
// an example compiles; this one says it is written the way `rill fmt` writes
// it — parse it, print it, get the same bytes back.
//
// The argument is the one that restretched these files to four-space bodies a
// beat ago, and the width canon re-opened it: a reader who copies an example
// into a file and saves it must not watch it move. A doc that teaches a shape
// the printer will not emit is wrong the first time anyone round-trips it.
// ---------------------------------------------------------------------------

/// A fence that is deliberately NOT a canonical program, and why.
///
/// Named, never silent: a skipped example is an example nobody is checking,
/// and the whole point of this gate is that "I looked at it" is not a gate.
/// `needle` must appear in exactly one fence of `doc`.
const DocFragment = struct {
    doc: []const u8,
    needle: []const u8,
    why: []const u8,
};

const doc_fragments = [_]DocFragment{};

fn expectDocCanon(doc: []const u8, reg: *rill.Registry, doc_name: []const u8) !usize {
    var count: usize = 0;
    var bad: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, doc, pos, "```rill\n")) |start| {
        const body_start = start + "```rill\n".len;
        const end = std.mem.indexOfPos(u8, doc, body_start, "```") orelse return error.TestUnexpectedResult;
        const src = doc[body_start..end];
        pos = end;

        var exempt = false;
        for (doc_fragments) |f| {
            if (!std.mem.eql(u8, f.doc, doc_name)) continue;
            if (std.mem.indexOf(u8, src, f.needle) != null) exempt = true;
        }
        if (exempt) continue;
        count += 1;

        var diag = rill.Diag{};
        var prog = rill.parse(testing.allocator, reg, "doc", src, &diag) catch |err| {
            std.debug.print("{s}: example does not parse — {s} ({d}:{d})\n{s}\n", .{ doc_name, diag.msg(), diag.line, diag.col, src });
            return err;
        };
        defer prog.deinit();
        const out = try rill.printScript(testing.allocator, prog.script.?);
        defer testing.allocator.free(out);
        if (!std.mem.eql(u8, src, out)) {
            bad += 1;
            // Line number of the fence, so the fix is one jump away.
            var line: usize = 1;
            for (doc[0..start]) |c| {
                if (c == '\n') line += 1;
            }
            std.debug.print("\n--- {s}:{d} is not what the printer writes ---\n{s}--- printed ---\n{s}", .{ doc_name, line, src, out });
        }
    }
    if (bad > 0) {
        std.debug.print("\n{s}: {d} of {d} fences are not fixed points\n", .{ doc_name, bad, count });
        return error.TestUnexpectedResult;
    }
    return count;
}

test "R3 G-doc: every printed example is written the way the printer writes it" {
    // Mutation that bites: put a 90-column chain back into `rill-manual.md`'s
    // §6 — any of the ones this beat shortened. It parses, so the older gate
    // stays green; this one reports the fence and its line and goes red.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const human = try expectDocCanon(@embedFile("rill-manual.md"), &reg, "rill-manual.md");
    const agent = try expectDocCanon(@embedFile("rill-for-agents.md"), &reg, "rill-for-agents.md");
    const readme = try expectDocCanon(@embedFile("README.md"), &reg, "README.md");
    const rbf_doc = try expectDocCanon(@embedFile("rbf-words.md"), &reg, "rbf-words.md");
    // Counted, both ways, for the reason the parse gate counts: a fence
    // rename would make this pass vacuously. The same four numbers the parse
    // gate pins, and deliberately the same four docs — those are the ones a
    // reader copies from. `docs/rill-spec.md`, `namespaces.md`, `slate.md`
    // and the campaign notes hold sixteen more fences between them and are
    // NOT gated: they are not embedded in the build, and they are records of
    // decisions rather than teaching material.
    try testing.expectEqual(@as(usize, 58), human);
    try testing.expectEqual(@as(usize, 8), agent);
    try testing.expectEqual(@as(usize, 4), readme);
    try testing.expectEqual(@as(usize, 3), rbf_doc);
    // NOTHING is exempt. `doc_fragments` is empty and that is a measurement:
    // all 73 fences in the four docs are whole programs, so not one of them
    // needed the escape hatch.
    try testing.expectEqual(@as(usize, 0), doc_fragments.len);
}

// ---------------------------------------------------------------------------
// R4 — what a canvas needs that the language could not say (2026-09-09).
// `layout` puts the picture in the document: node positions, in a block the
// parser reads, the runtime elides and the document keeps.
// ---------------------------------------------------------------------------

test "R4 G-layout: a layout block is retained, printed back, and changes NOTHING" {
    // The claim the whole feature rests on: `layout` is runtime-elided. The
    // same program with and without the block must produce the same nodes,
    // the same slots and — the gate that actually watches it — the same DUMP,
    // byte for byte.
    //
    // MUTATION that bites: make the block reach the graph. Appending
    // `try self.program_target.items.append(self.a(), .{ .stmt = … })`, or
    // simply parsing a layout line as a statement, gives the program a node
    // and the dump lengths diverge. Executed 2026-09-09: replacing the annex
    // append in `parseLayout` with a `parseStatement` call over the same
    // tokens makes `mul1 240 120` an operator call and the gate goes red on
    // the node count before it ever reaches the dump.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const bare =
        \\plane.a | mul 2 | write plane.out
        \\plane.b | add 1 | write plane.other
        \\
    ;
    const laid =
        \\plane.a | mul 2 | write plane.out
        \\plane.b | add 1 | write plane.other
        \\
        \\layout demo
        \\    mul1   240 120
        \\    write1 400 120
        \\    add1   240 260
        \\    write2 400 260
        \\
    ;
    var d1 = rill.Diag{};
    var p1 = try rill.parse(testing.allocator, &reg, "p", bare, &d1);
    defer p1.deinit();
    var d2 = rill.Diag{};
    var p2 = try rill.parse(testing.allocator, &reg, "p", laid, &d2);
    defer p2.deinit();

    try testing.expectEqual(p1.nodes.items.len, p2.nodes.items.len);
    try testing.expectEqual(p1.slots.items.len, p2.slots.items.len);
    try testing.expectEqual(p1.subs.items.len, p2.subs.items.len);
    try testing.expectEqual(@as(usize, 0), p2.warnings.items.len);

    var m1 = rill.MockPlane.init(testing.allocator);
    defer m1.deinit();
    try m1.putValue("plane.a", @as(i64, 3));
    try m1.putValue("plane.b", @as(i64, 4));
    var r1 = try rill.Runtime.mount(testing.allocator, &p1, m1.asPlane(), .{});
    defer r1.deinit();
    var m2 = rill.MockPlane.init(testing.allocator);
    defer m2.deinit();
    try m2.putValue("plane.a", @as(i64, 3));
    try m2.putValue("plane.b", @as(i64, 4));
    var r2 = try rill.Runtime.mount(testing.allocator, &p2, m2.asPlane(), .{});
    defer r2.deinit();
    const dump1 = try rill.dump(&r1, testing.allocator);
    defer testing.allocator.free(dump1);
    const dump2 = try rill.dump(&r2, testing.allocator);
    defer testing.allocator.free(dump2);
    try testing.expectEqualSlices(u8, dump1, dump2);

    // And it is RETAINED: same annex shape `describe` uses, keyword and all,
    // which is why the printer did not have to move for it.
    const an = for (p2.script.?.top) |it| {
        if (it == .annex and std.mem.eql(u8, it.annex.keyword, "layout")) break it.annex;
    } else return error.TestUnexpectedResult;
    try testing.expectEqualStrings("demo", an.subject);
    try testing.expectEqual(@as(usize, 4), an.lines.len);
    try testing.expectEqualStrings("mul1", an.lines[0].key);
    try testing.expectEqual(@as(usize, 2), an.lines[0].values.len);
    try testing.expectEqualStrings("240", an.lines[0].values[0]);

    // Printed back, byte for byte, and a fixed point — the columns included:
    // `write1` is the longest key, so every value lines up under it.
    try expectPrintedStable(&reg, laid, laid);
}

test "R4 G-layout-stale: a line naming a node that is gone WARNS, and the file still parses" {
    // Christian's rule for a machine-written, cosmetic block: loud, never
    // fatal. `describe` is hard-refused in both directions because prose is
    // the author's burden and an undescribed port is a gap in the pack; a
    // stale coordinate is a node the canvas places by default, and a hand
    // rename must not make the file stop parsing.
    //
    // MUTATION 1 that bites: turn the `warn` in `checkLayoutKeys` into a
    // `fail`. Executed 2026-09-09 — the parse returns error.Parse and this
    // gate dies at the `try`, one line in.
    //
    // MUTATION 2 that bites, and it is the one worth having: DELETE the
    // check. Executed 2026-09-09 — the program parses exactly as it does now
    // and only the warning count goes to zero, which is why the count and the
    // message are asserted and not just "it parsed".
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\plane.a | mul 2 | write plane.out
        \\
        \\layout demo
        \\    mul1 240 120
        \\    sin4 400 120
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.warnings.items.len);
    try testing.expectEqual(rill.Warning.Code.layout_unknown_node, prog.warnings.items[0].code);
    try testing.expectEqual(@as(u32, 5), prog.warnings.items[0].line);
    try testing.expect(std.mem.indexOf(u8, prog.warnings.items[0].msg, "'sin4'") != null);
    // The stale line is KEPT. Dropping it would be the editor deleting an
    // author's work to tidy up after itself.
    try expectPrintedStable(&reg, src, src);

    // The same shape, twice over one node — one position per node or the
    // canvas has two answers.
    const twice =
        \\plane.a | mul 2 | write plane.out
        \\
        \\layout demo
        \\    mul1 240 120
        \\    mul1 400 120
        \\
    ;
    var d2 = rill.Diag{};
    var p2 = try rill.parse(testing.allocator, &reg, "p", twice, &d2);
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 1), p2.warnings.items.len);
    try testing.expectEqual(rill.Warning.Code.layout_duplicate, p2.warnings.items[0].code);
}

test "R4 G-layout-loud: what a layout block may NOT hold" {
    // The half that is still a refusal. Everything a layout line can hold is
    // inert — a name and numbers — which is the property that makes "eliding
    // the block" a safe claim: nothing in here can be a path, a call or a
    // fold, so eliding it can never elide a subscription.
    //
    // MUTATION that bites: drop the `v.kind != .number` test. Executed
    // 2026-09-09 — `mul1 plane.x` then parses, the block silently holds a
    // path, and the first assertion below goes red.
    try expectParseError(
        \\plane.a | mul 2 | write plane.out
        \\
        \\layout demo
        \\    mul1 plane.x 120
        \\
    , "coordinates are numbers");
    // A fold in here would let a runtime-elided block reach the fold table,
    // and a fold in the KEY position could rename the node the end-of-parse
    // check then looks for.
    try expectParseError(
        \\using mul1 as :n
        \\plane.a | mul 2 | write plane.out
        \\
        \\layout demo
        \\    :n 240 120
        \\
    , "read verbatim");
    // One block per document — the same ruling `describe` has, for the same
    // reason: one place a canvas reads and writes.
    try expectParseError(
        \\plane.a | mul 2 | write plane.out
        \\
        \\layout demo
        \\    mul1 240 120
        \\
        \\layout demo
        \\    mul1 400 120
        \\
    , "already has a `layout` block");
    // A subject is required. It is never RESOLVED — see `parseLayout` — but
    // a block with nothing after the keyword is a block about nothing.
    try expectParseError(
        \\layout
        \\    mul1 240 120
        \\
    , "expected a name after 'layout'");
    // And `layout` is a statement keyword, so it may not be an operator.
    try expectParseError(
        \\plane.a | layout 2 | write plane.out
        \\
    , "statement keyword");
}

// ---------------------------------------------------------------------------
// R4 — shaped holes (§3.15). Drag an operator onto a canvas and it lands
// UNWIRED; rill's text could not say that, because parse order is dependency
// order and an orphan has no place in the statement list. `using ?number as
// :tight` is a `using` bound to NOTHING, carrying a shape — Christian's
// spelling, and DECLARED on purpose, so an unknown `:name` stays the loud
// refusal it has always been.
// ---------------------------------------------------------------------------

/// What the mount SAID, captured. A hole is announced by name, and a gate that
/// read `prog.holes` alone would be reading the parser's answer twice — this
/// reads the runtime's.
const HoleLog = struct {
    var buf: [8][64]u8 = undefined;
    var lens: [8]usize = .{0} ** 8;
    var count: usize = 0;

    fn reset() void {
        count = 0;
    }

    fn sink(ctx: ?*anyopaque, label: []const u8, val: []const u8) void {
        _ = ctx;
        if (!std.mem.eql(u8, label, "rill.hole")) return;
        if (count >= buf.len) return;
        const n = @min(val.len, buf[count].len);
        @memcpy(buf[count][0..n], val[0..n]);
        lens[count] = n;
        count += 1;
    }

    fn at(i: usize) []const u8 {
        return buf[i][0..lens[i]];
    }
};

test "R4 G-hole: a DECLARED hole parses, and an UNDECLARED :name still refuses" {
    // Both directions, and the second is the whole reason the spelling is
    // `using` rather than a bare `?` at the use site. If an unknown fold
    // quietly became a hole, `:kk` for `:k` would stop being a refusal and
    // start being a silently dead statement — in files that are live in a
    // running sim.
    //
    // MUTATION that bites: in `expandIfFold`, make the `folds.get` miss
    // return a hole instead of refusing (`orelse { … return .{ .hole = … }; }`).
    // Executed 2026-09-09 — the second half goes red: `:nope` parses.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\using ?number as :tight
        \\
        \\plane.a | add :tight | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.holes.len);
    try testing.expectEqualStrings(":tight", prog.holes[0].name);
    try testing.expectEqual(types.Tag.number, prog.holes[0].ty);
    // The node EXISTS — that is the representation's whole point. `add1` is
    // in the graph with an open input, rather than the statement vanishing.
    try testing.expect(nodeIdOf(&prog, "add1") != null);

    // …and an unbound name is what it always was.
    try expectParseError(
        \\plane.a | add :nope | write plane.out
    , "is not a bound fold");
    // Including the near-miss that motivated the spelling.
    try expectParseError(
        \\using ?number as :tight
        \\plane.a | add :tigth | write plane.out
    , "is not a bound fold");
}

test "R4 G-hole-any: a bare `?` is `?any` — one feature with a default, not two" {
    // `?` alone reaches every port, because `any` is a wildcard on either
    // side of a wire and always has been. That is what "an unshaped hole
    // poisons everything downstream" means concretely: no shape, no check.
    //
    // MUTATION that bites: make a bare `?` refuse ("a hole needs a shape").
    // Executed 2026-09-09 — every assertion below dies at the parse. The
    // OPEN RULING (2026-09-09, unresolved) is whether that mutation is
    // actually the right behaviour: `describe`'s principle — the burden is on
    // the writer — argues the shape should be mandatory, and `any` being a
    // real port type a def may declare argues it should not. Built optional.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\using ? as :k
        \\
        \\plane.a | add :k | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.holes.len);
    try testing.expectEqual(types.Tag.any, prog.holes[0].ty);
    // The same `?` reaches a boolean port and a mesh port too — `any` is not
    // a fourth kind of hole, it is the absence of a claim.
    try expectPrintedStable(&reg,
        \\using ? as :k
        \\
        \\plane.a | where :k | write plane.out
        \\
    ,
        \\using ? as :k
        \\
        \\plane.a | where :k | write plane.out
        \\
    );
    try expectPrintedStable(&reg,
        \\using ? as :k
        \\
        \\:k | bevel 0.2 | tap m
        \\
    ,
        \\using ? as :k
        \\
        \\:k | bevel 0.2 | tap m
        \\
    );
}

test "R4 G-hole-shape: the shape reaches the port, and a mismatch is refused NAMING BOTH" {
    // THE refusal a shaped hole buys, and the feature's main justification —
    // without it a shaped hole is just a comment. A `number` hole spliced
    // into a boolean port is wrong before anything runs, and the message
    // names the hole the author declared AND the port it was dropped on.
    //
    // MUTATION that bites: delete the `arg.kind == .hole` arm in
    // `parseOpcall`'s bind loop. Executed 2026-09-09 — the refusal still
    // happens (the generic type check catches it) but says "'where' port
    // 'pred': expected boolean, got number", which names the port and NOT the
    // hole. The needle below is `hole ':t' is number`, so it goes red.
    //
    // MUTATION 2, the one that removes the feature: make `sourceTy` answer
    // `types.Tag.any` for a `.hole`. Executed 2026-09-09 — the shape stops
    // flowing, every hole reaches every port, and both refusals below go
    // green-that-should-be-red (`expectParseError` reports "expected
    // error.Parse, found Program").
    try expectParseError(
        \\using ?number as :t
        \\plane.a | where :t | write plane.out
    , "hole ':t' is number, and 'where' port 'pred' takes boolean");
    try expectParseError(
        \\using ?boolean as :b
        \\plane.a | mul :b | write plane.out
    , "hole ':b' is boolean, and 'mul' port 'b' takes number");
    // A HOST-interned type works as a shape, and works both ways. `mesh` is
    // this fixture's host type (`hostRegistry`), registered on an op's port
    // and never mentioned in `types.zig`.
    //
    // MUTATION that bites: hard-code the built-in list in `parseUsing` —
    // resolve the shape by scanning `number boolean string record bytes array
    // duration any` and refusing anything else. Executed 2026-09-09 — `?mesh`
    // stops parsing and the accepting half below goes red at the `try`.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    try expectPrintedStable(&reg,
        \\using ?mesh as :m
        \\
        \\:m | bevel 0.2 | tap out
        \\
    ,
        \\using ?mesh as :m
        \\
        \\:m | bevel 0.2 | tap out
        \\
    );
    try expectParseError(
        \\using ?mesh as :m
        \\plane.a | mul :m | write plane.out
    , "hole ':m' is mesh, and 'mul' port 'b' takes number");
    // …and the shape is interned BY NAME, so a type no host has ever
    // registered is still a shape and is still not `any`.
    try expectParseError(
        \\using ?light as :l
        \\plane.a | mul :l | write plane.out
    , "hole ':l' is light");
}

test "R4 G-hole-mount: everything else mounts and RUNS, and the mount names the open holes" {
    // The rule that matters most: a hole may never break what is already
    // running. One statement is held open by name; the other computes and
    // writes exactly as it would in a file with no hole in it.
    //
    // MUTATION 1 that bites: fail the whole mount on a hole — `if
    // (prog.holes.len > 0) return error.Refused;` in `Runtime.mount`, which
    // is the plausible wrong reading ("a half-built program is not
    // mountable"). Executed 2026-09-09 — the mount errors and the gate dies
    // at `Runtime.mount`.
    //
    // MUTATION 2 that bites, and it is the quiet one: skip the announcement —
    // delete the `prog.holes` loop in `mount`. Executed 2026-09-09 — the
    // program still runs, `plane.out` is still 6, and only the two `HoleLog`
    // assertions go red. Which is why they are here: "everything else runs"
    // is half the claim and "and it SAYS SO, by name" is the other half.
    //
    // MUTATION 3 that bites: delete `if (s.source == .hole) return;` from
    // `markNode`, so a hole falls through to the two skips below it. It takes
    // an OPTIONAL port to see it — a hole on a required port stays quiet
    // either way, which is exactly why the second half of this gate exists
    // and why the first half alone would have been decoration. Executed
    // 2026-09-09: with the line gone, `step` fires with a null `max` and the
    // second half's write count goes from 0 to 1. That is the whole reason a
    // hole is not `.none`, and the reason it is tested on the port where the
    // difference shows.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\using ?number as :tight
        \\
        \\plane.a | mul 2 | write plane.out
        \\plane.b | add :tight | write plane.other
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.a", @as(i64, 3));
    try mock.putValue("plane.b", @as(i64, 4));

    HoleLog.reset();
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{
        .log_fn = HoleLog.sink,
    });
    defer rt.deinit();

    // The other statement ran. One write, and it is the right one.
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);
    try testing.expectEqualStrings("plane.out", mock.writes.items[0].path);
    try testing.expectEqual(@as(f64, 6), types.asNumber(mock.writes.items[0].value).?);

    // The mount said which name is open. BY NAME — not by count, because the
    // author or the editor chose the name and "one input is open" sends
    // whoever reads it hunting.
    try testing.expectEqual(@as(usize, 1), HoleLog.count);
    try testing.expectEqualStrings(":tight", HoleLog.at(0));

    // …and it stays quiet across ticks, not just at mount.
    try feedValue(&rt, testing.allocator, "plane.b", @as(i64, 9));
    try rt.tick(.{ .frame = 1, .time_ns = 16_000_000 });
    try testing.expectEqual(@as(usize, 1), mock.writes.items.len);

    // THE OPTIONAL PORT, which is where the readiness rule is load-bearing.
    // `step`'s `max` is `kwOpt` — an unbound optional port reads as null and
    // does NOT hold the node back, by design (the gates' `off`/`on` controls
    // sit on paths that may never fire). A hole on one must still hold it,
    // because the author declared that input open rather than absent.
    var m2 = rill.MockPlane.init(testing.allocator);
    defer m2.deinit();
    try m2.putValue("plane.beat", @as(i64, 1));
    var d3 = rill.Diag{};
    var p3 = try rill.parse(testing.allocator, &reg, "p",
        \\using ?number as :cap
        \\
        \\plane.beat | step [60, 64] max :cap | write plane.note
        \\
    , &d3);
    defer p3.deinit();
    var rt3 = try rill.Runtime.mount(testing.allocator, &p3, m2.asPlane(), .{});
    defer rt3.deinit();
    try testing.expectEqual(@as(usize, 0), m2.writes.items.len);

    // One hole spliced twice is ONE open hole with two consequences — a
    // second reading of the name is a count wearing a name's clothes.
    const twice =
        \\using ?number as :tight
        \\
        \\plane.a | add :tight | write plane.out
        \\plane.b | mul :tight | write plane.other
        \\
    ;
    var d2 = rill.Diag{};
    var p2 = try rill.parse(testing.allocator, &reg, "p", twice, &d2);
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 1), p2.holes.len);
}

test "R4 G-hole-print: a hole survives print → parse → print, and a dump → load" {
    // Byte-stable, both features, and a hole is retained as the SPELLING the
    // author wrote: `:tight`, never the shape it was bound to.
    //
    // MUTATION that bites: map a hole's `syn_kind` to `.stream` instead of
    // `.hole`. Executed 2026-09-09 — the file still prints back byte for
    // byte, and only the retained ARGUMENT's kind goes red. Which is the
    // point of asserting it: an editor draws a wire and an open socket
    // differently, and "it round-trips" does not tell it which this is.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\// a canvas dropped two operators and wired neither
        \\using ?number as :tight
        \\using ? as :anything
        \\
        \\plane.a | mul 2 | write plane.out
        \\plane.b | add :tight | write plane.other
        \\:anything | tap loose
        \\
        \\layout demo
        \\    mul1 240 120
        \\    add1 240 260
        \\
    ;
    try expectPrintedStable(&reg, src, src);

    // The retained argument knows it is a hole and not a stream, because an
    // editor draws the two differently: an open socket, not a wire.
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const st = for (prog.script.?.top) |it| {
        if (it == .stmt and it.stmt.stages.len > 0 and it.stmt.stages[0] == .call and
            std.mem.eql(u8, it.stmt.stages[0].call.op, "add")) break it.stmt;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(rill.script.Arg.Kind.hole, st.stages[0].call.args[0].kind);
    try testing.expectEqualStrings(":tight", st.stages[0].call.args[0].text);

    // A hole is a GRAPH fact, so it survives a DUMP — unlike `warnings`,
    // `exports`, `plane` and `script`, which describe the source. A restored
    // program whose holey node suddenly evaluated would be a different
    // program.
    //
    // MUTATION that bites: serialize a `.hole` slot as `.none` (tag 0).
    // Executed 2026-09-09 — the round trip loads, `holes` comes back empty
    // and the last two assertions go red; and worse than red, the restored
    // `add1` would evaluate, because `.none` is SKIPPED by the readiness
    // test.
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.a", @as(i64, 3));
    try mock.putValue("plane.b", @as(i64, 4));
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    const d = try rill.dump(&rt, testing.allocator);
    defer testing.allocator.free(d);
    var back = try rill.loadProgram(testing.allocator, &reg, d);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.holes.len);
    try testing.expectEqualStrings(":tight", back.holes[0].name);
    try testing.expectEqual(types.Tag.number, back.holes[0].ty);
    try testing.expectEqualStrings(":anything", back.holes[1].name);
    try testing.expectEqual(types.Tag.any, back.holes[1].ty);
}

test "R4 G-hole-place: a hole stands where a VALUE stands, and nowhere else" {
    // The trap `parser.zig`'s header documents: two splices of one fold build
    // two INDEPENDENT node sets, so `using` must never become how a
    // node-to-node wire is spelled — a fan-out written that way would
    // silently duplicate the upstream subgraph. Wires stay `as` and the pipe.
    //
    // A hole cannot make that spelling attractive, because a hole is bound to
    // NOTHING: there is no upstream subgraph to duplicate. What the refusals
    // below keep is the other half — a hole is a value, so it may not stand
    // in operator position, as a branch head, or projected as though it had
    // fields it cannot have.
    //
    // MUTATION that bites: delete the `if (f.hole) |ty|` arm in
    // `expandIfFold`. Executed 2026-09-09 — a hole in operator position is
    // no longer refused by name; it falls through to "expected operator
    // after '|'", and the first needle goes red.
    try expectParseError(
        \\using ?number as :t
        \\plane.a | :t 2 | write plane.out
    , "is an open hole (?number) — a hole stands where a VALUE stands");
    try expectParseError(
        \\using ? as :k
        \\plane.a | also { :k } | write plane.out
    , "is an open hole");
    // No fields until something is bound to it.
    try expectParseError(
        \\using ?record as :r
        \\plane.a | add :r.x | write plane.out
    , "no fields until something is bound to it");
    // And a hole binding is a hole and nothing else: `using ?number plus as
    // :t` is a fold whose body happens to start with a `?`, which is a slip,
    // not a feature.
    try expectParseError(
        \\using ?number extra as :t
        \\plane.a | add :t
    , "a hole stands alone");
}

// ---------------------------------------------------------------------------
// R5 — the bridge back to the text. `graph.CallSite` + `Script.callAt`.
//
// An editor that moves a node needs nothing from the source; an editor that
// changes a WIRE has to find the `Call` that wrote it and edit that. Until
// this pair there was no way across: `Program.script` hands out the file as
// written, the graph hands out the picture, and the only bridge was that
// parse order is dependency order and `autoName` mints `near1`, `near2` in it
// — so the Nth `near` call is `nearN`. True, and a re-derivation of something
// the parser knew for certain and discarded, which is a second answer able to
// drift from the first.
// ---------------------------------------------------------------------------

test "R5: every operator node names the Call that wrote it, and the Call agrees" {
    // The claim in one line: for every node the parser made from a `Call`,
    // `Script.callAt(node.site)` returns THAT call — spelled the same, and
    // exactly one of them.
    //
    // MUTATION that bites: in `makeNodeAt`, use the token's line with column
    // 1 (`.{ .line = t.line, .col = 1 }`). Red — three calls share line 2, so
    // the lookup returns the first of them for all three and the op spellings
    // disagree.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    // The third line is a FAN-OUT, and it is here on purpose: without a
    // branch anywhere in the fixture, `findCallInStages`' `.fan` arm is code
    // no gate executes — deleting it wholesale left every gate green, which
    // is how it got into this fixture.
    const src =
        \\plane.a | clamp 0 1 | write plane.lit
        \\plane.seed | mul 0.025 | add 0.03 | write plane.size
        \\plane.hp | also { write plane.log } | write plane.hp2
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();
    const sc = prog.script.?;

    var matched: usize = 0;
    for (prog.nodes.items) |n| {
        if (!n.site.known()) continue;
        const call = sc.callAt(n.site.line, n.site.col) orelse {
            std.debug.print("\nno call at {d}:{d} for '{s}'\n", .{ n.site.line, n.site.col, n.name });
            return error.NoCallForNode;
        };
        // The op SPELLING, not the id: `Call.op` is what was typed and a node
        // carries the resolved definition, so this is the assertion that the
        // two sides are looking at the same statement rather than at two
        // statements that happen to share a position.
        try testing.expectEqualStrings(reg.get(n.op).name, call.op);
        matched += 1;
    }
    // clamp, write, mul, add, write, and the two the fan-out line wrote —
    // seven. A gate that matched NONE would sail through the loop above,
    // which is why the count is asserted and not just the agreement.
    try testing.expectEqual(@as(usize, 7), matched);
}

test "R5: sugar with no Call of its own says so, rather than pointing at a neighbour" {
    // A record literal's assembly node and a projection node are minted
    // without an operator token. Giving them a plausible-looking site would be
    // worse than giving them none: an editor would follow it to whichever call
    // was nearest and rewrite a statement the reader never touched.
    //
    // MUTATION that bites: make `makeNodeAt`'s `site` non-optional and pass
    // the record's opening brace token through `parseRecord`. Red — `record1`
    // reports a known site, and there is no `Call` there at all, so an editor
    // asking "what wrote this" gets a confident wrong answer instead of none.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg,
        "p", "{x: 1, y: 2} | write plane.out\n", &diag);
    defer prog.deinit();

    var sugar: usize = 0;
    for (prog.nodes.items) |n| {
        if (std.mem.eql(u8, reg.get(n.op).name, "record")) {
            try testing.expect(!n.site.known());
            try testing.expect(prog.script.?.callAt(n.site.line, n.site.col) == null);
            sugar += 1;
        }
    }
    try testing.expect(sugar > 0);
}

test "R5: a call inside a def body is found, because that is where its text is" {
    // A def's nodes are FLATTENED into the program with prefixed names
    // (`double1.mul1`), and the call that wrote them is in the def's body and
    // nowhere else. `findCallIn` recurses into `Script.defs` for exactly this.
    //
    // MUTATION that bites: drop the `.def` arm from `findCallIn`. Red — the
    // spliced node's site is known and resolves to nothing, which is the
    // shape that would make drill-in editing silently do nothing.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\def double(x) =
        \\    x | mul 2
        \\
        \\plane.a | double | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();

    var found_inside = false;
    for (prog.nodes.items) |n| {
        if (!std.mem.eql(u8, reg.get(n.op).name, "mul")) continue;
        try testing.expect(n.site.known());
        const call = prog.script.?.callAt(n.site.line, n.site.col) orelse return error.NoCallForNode;
        try testing.expectEqualStrings("mul", call.op);
        // …and it is the one in the BODY: line 2, not the splice on line 4.
        try testing.expectEqual(@as(u32, 2), call.line);
        found_inside = true;
    }
    try testing.expect(found_inside);
}

// ---------------------------------------------------------------------------
// R6 — `edit.addCall`: an operator dropped on a canvas.
//
// §3.15's shaped holes were built for this exact moment and `graph.Source.hole`
// says so: *"an editor that drags an operator onto a canvas had nowhere to put
// it."* This is the customer.
// ---------------------------------------------------------------------------

/// Print a script and parse the result, which is the only assertion that
/// matters about an edit: what it produced is a file rill can read.
fn addAndReparse(
    gpa: std.mem.Allocator,
    reg: *rill.Registry,
    src: []const u8,
    op: []const u8,
    out_text: *[]u8,
) !rill.Program {
    var diag = rill.Diag{};
    var before = try rill.parse(gpa, reg, "p", src, &diag);
    defer before.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const edited = try rill.edit.addCall(arena.allocator(), before.script.?, reg, op);

    out_text.* = try rill.script.print(gpa, &edited);

    var d2 = rill.Diag{};
    return rill.parse(gpa, reg, "p", out_text.*, &d2) catch |e| {
        std.debug.print("\nedited source will not parse: {d}:{d} {s}\n---\n{s}---\n", .{
            d2.line, d2.col, d2.msg(), out_text.*,
        });
        return e;
    };
}

test "R6: a dropped operator lands as a statement with an open socket" {
    // The whole claim, and it is end to end on purpose: build the edit, PRINT
    // it, and parse the printed text. An edit that produces a `Script` the
    // printer emits and the parser then refuses is worse than no edit at all,
    // because the host has already thrown the old one away.
    //
    // MUTATION that bites: drop the `items.append(.using …)` so only the
    // statement is written. Red at the re-parse — `:add_b` is an undeclared
    // fold, which is the loud refusal §3.15 exists to preserve.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var text: []u8 = undefined;
    var prog = try addAndReparse(testing.allocator, &reg,
        "plane.a | write plane.out\n", "clamp", &text);
    defer testing.allocator.free(text);
    defer prog.deinit();

    // The node EXISTS in the graph — that is the representation's point.
    try testing.expect(nodeIdOf(&prog, "clamp1") != null);
    // …and its declared inputs are holes, not bound values and not `.none`.
    const n = prog.node(nodeIdOf(&prog, "clamp1").?);
    var holes: usize = 0;
    for (n.inputs) |sid| {
        if (prog.slot(sid).source == .hole) holes += 1;
    }
    try testing.expect(holes > 0);
    // The hole is named for the operator and the port, so the file says what
    // the socket is for at the point of use.
    try testing.expect(std.mem.indexOf(u8, text, ":clamp_") != null);
}

test "R6: what an edit prints is already canonical" {
    // The property the whole 47-file corpus is held to, applied to generated
    // text: `rill fmt` over an edited file must change nothing. If an edit
    // emitted something the printer would re-flow, then format-on-save would
    // silently rewrite the file the instant the reader touched it, and the
    // diff of their next real change would carry the difference.
    //
    // MUTATION that bites: give the appended statement `blank_before = 0` and
    // the `using` items `blank_before = 3`. The first parse-print is stable
    // either way — the printer emits what the script says — so the mutation
    // that actually bites is the one that makes the SCRIPT disagree with the
    // canon: set the `using` body to `? number` (a space), which the printer
    // emits verbatim and the parser then reads as a bare `?` followed by a
    // type word. Red at the re-parse.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var text: []u8 = undefined;
    var prog = try addAndReparse(testing.allocator, &reg,
        "plane.a | write plane.out\n", "clamp", &text);
    defer testing.allocator.free(text);
    defer prog.deinit();

    const again = try rill.script.print(testing.allocator, prog.script.?);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(text, again);
}

test "R6: two drops of the same operator do not name one socket twice" {
    // A single `addCall` may mint several holes and a second call mints more.
    // Both would happily produce `:clamp_lo` twice, and the second `using`
    // silently shadows the first — a file that parses, runs, and is wrong.
    //
    // MUTATION that bites: have `mintHole` consider only `sc.top` and not the
    // items being built. Red — the second drop reuses the first's names.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var t1: []u8 = undefined;
    var p1 = try addAndReparse(testing.allocator, &reg,
        "plane.a | write plane.out\n", "clamp", &t1);
    defer testing.allocator.free(t1);
    p1.deinit();

    var t2: []u8 = undefined;
    var p2 = try addAndReparse(testing.allocator, &reg, t1, "clamp", &t2);
    defer testing.allocator.free(t2);
    defer p2.deinit();

    try testing.expect(nodeIdOf(&p2, "clamp1") != null);
    try testing.expect(nodeIdOf(&p2, "clamp2") != null);
    // Every hole in the twice-edited file is distinct — asserted on the
    // PROGRAM's hole table rather than by counting substrings, so a name that
    // differs only in a way the parser ignores still fails.
    for (p2.holes, 0..) |h, i| {
        for (p2.holes[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, h.name, other.name));
        }
    }
    try testing.expect(p2.holes.len >= 2);
}

test "R6: an operator whose argument cannot be a value is refused by name" {
    // A hole is a VALUE. A section body (`keep (> 0)`) and a line-tail are
    // neither, so there is no text that leaves one open — and emitting a file
    // that will not parse is the one outcome worse than refusing.
    //
    // MUTATION that bites: delete the `port.kind == .section or port.tail`
    // check. Red — the call returns a script whose printed form the parser
    // refuses, which the gate catches as a parse error rather than the named
    // refusal it asked for.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", "plane.a | write plane.out\n", &diag);
    defer prog.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The named refusal this gate is actually about. `keep` declares
    // `body = 1`: its argument is a sub-graph, and there is no hole spelling
    // for one.
    try testing.expectError(
        error.CannotLeaveOpen,
        rill.edit.addCall(arena.allocator(), prog.script.?, &reg, "keep"),
    );
    // And the other refusal, because a palette out of date with its host is
    // worth saying rather than crashing on.
    try testing.expectError(
        error.UnknownOperator,
        rill.edit.addCall(arena.allocator(), prog.script.?, &reg, "no_such_operator"),
    );
}

test "R6 AUDIT: every registered operator either drops cleanly or refuses by name" {
    // **Exhaustive, because picking two operators picks two that agree with
    // you.** Two mutations survived a hand-chosen fixture — `clamp` has no
    // optional port and no keyword port, so the rules covering both were
    // untested and the gate could not have known. This walks the whole
    // vocabulary instead: for every registered operator, `addCall` must either
    // produce text rill parses, or refuse by NAME. Never a third thing, and
    // never a file that will not load.
    //
    // It is also the honest count of what a palette can offer today, printed
    // rather than asserted, so a beat that widens `addCall` shows up as the
    // number moving.
    //
    // MUTATIONS that bite: drop `if (port.optional) continue;` — an optional
    // port gets a hole it does not need, and several operators then emit a
    // required-looking socket for something the parser never expected. Drop
    // the `port.kw` spelling — a keyword port written positionally is refused
    // by the parser with "written WITHOUT its name", which lands here as a
    // parse failure on generated text.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();

    var diag = rill.Diag{};
    var base = try rill.parse(testing.allocator, &reg, "p", "plane.a | write plane.out\n", &diag);
    defer base.deinit();

    var dropped: usize = 0;
    var refused: usize = 0;
    var i: registry.OpId = 0;
    while (i < reg.ops.items.len) : (i += 1) {
        const name = reg.get(i).name;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const edited = rill.edit.addCall(arena.allocator(), base.script.?, &reg, name) catch |e| {
            // The only legal refusals, and both are named. Anything else — an
            // OOM aside — is a bug wearing an error.
            switch (e) {
                error.CannotLeaveOpen, error.NotCallable => {},
                else => return e,
            }
            refused += 1;
            continue;
        };

        const text = try rill.script.print(testing.allocator, &edited);
        defer testing.allocator.free(text);
        var d2 = rill.Diag{};
        var prog = rill.parse(testing.allocator, &reg, "p", text, &d2) catch |e| {
            std.debug.print("\n'{s}' dropped to text rill refuses: {d}:{d} {s}\n---\n{s}---\n", .{
                name, d2.line, d2.col, d2.msg(), text,
            });
            return e;
        };
        defer prog.deinit();
        // …and the node is really there, which is the point of the whole
        // representation. A drop that parsed but put no node in the graph
        // would be an operator the reader cannot see or wire.
        try testing.expect(prog.nodes.items.len > base.nodes.items.len);

        // **Required ports get a HOLE; optional ports get NOTHING**, and the
        // difference is not cosmetic. `eval.markNode` SKIPS a `.none` input
        // when deciding whether a node is ready, and a `.hole` does the
        // opposite — it holds the node quiet, which is the whole reason
        // §3.15 gave holes their own variant instead of reusing `.none`. So
        // an optional port bound to a hole is an operator that never fires
        // again, however carefully the reader wires the rest of it.
        //
        // Only checkable here: a hole on an optional port PARSES perfectly
        // well, so the round-trip above cannot see it. The mutation that
        // deletes `if (port.optional) continue;` survived every other gate in
        // this file.
        const added = prog.nodes.items[prog.nodes.items.len - 1];
        try testing.expectEqual(i, added.op);
        for (added.inputs) |sid| {
            const slot = prog.slot(sid);
            if (slot.port >= reg.get(i).inputs.len) continue;
            const want_hole = !reg.get(i).inputs[slot.port].optional;
            const is_hole = slot.source == .hole;
            if (want_hole != is_hole) {
                std.debug.print("\n'{s}' port '{s}': optional={}, source={s}\n", .{
                    name, slot.name, !want_hole, @tagName(slot.source),
                });
                return error.WrongOpenness;
            }
        }
        dropped += 1;
    }

    std.debug.print(
        "\n[palette] {d} of {d} operators drop bare; {d} need something first\n",
        .{ dropped, dropped + refused, refused },
    );
    // A gate that refused everything would pass every assertion above.
    try testing.expect(dropped > 20);
}

// ---------------------------------------------------------------------------
// R6b — `script.Arg.port`: the binding the parser knew and used to throw away.
// ---------------------------------------------------------------------------

test "script: an authored argument knows which PORT it bound to" {
    // `graph.CallSite` exists because an editor changing a wire has to find
    // the `Call` that wrote it. This exists because, having found the call, it
    // then has to find the ARGUMENT — and `args` is in AUTHORED order where
    // ports are in DECLARED order. The two differ the moment anything is
    // piped, optional, keyword-bound, a section, or a static.
    //
    // MUTATION A: delete the stamp loop after the bindings. Every port reads
    // null, and an editor asking "which argument is port 1" gets no answer at
    // all — `edit.unlink` would have nothing to replace.
    // MUTATION B: stamp the AUTHORED index instead (`port = si`). This is
    // precisely the re-derivation the field exists to prevent, and it is the
    // plausible-looking one: it is right for a bare call and wrong for every
    // piped one. `mul`'s `2` is authored arg 0 and port 1, and it goes red
    // here.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    const src =
        \\plane.a | mul 2 | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p", src, &diag);
    defer prog.deinit();

    const sc = prog.script.?;

    var saw_mul = false;
    var saw_write = false;
    for (prog.nodes.items) |n| {
        const call = sc.callAt(n.site.line, n.site.col) orelse continue;
        if (std.mem.eql(u8, call.op, "mul")) {
            saw_mul = true;
            // ONE authored argument, and it is port ONE: port 0 is the pipe,
            // which nobody wrote and which therefore has no `Arg` at all.
            try testing.expectEqual(@as(usize, 1), call.args.len);
            try testing.expectEqualStrings("2", call.args[0].text);
            try testing.expectEqual(@as(?u8, 1), call.args[0].port);
        }
        if (std.mem.eql(u8, call.op, "write")) {
            saw_write = true;
            // **A static is not a port**, and this is the arm a naive index
            // mapping gets confidently wrong. `write`'s target is
            // `Node.statics[0]`, so the one authored argument binds no input
            // port and says so — the same `null` `addCall` refuses a hole for.
            try testing.expectEqual(@as(usize, 1), call.args.len);
            try testing.expectEqualStrings("plane.out", call.args[0].text);
            try testing.expectEqual(@as(?u8, null), call.args[0].port);
        }
    }
    try testing.expect(saw_mul);
    try testing.expect(saw_write);
}

// ---------------------------------------------------------------------------
// R6c — `edit.link` / `edit.unlink`: the wire, moved.
//
// rill has no wire syntax. A wire is the PIPE between two terms of one chain,
// or a NAME (`… as t`, read somewhere below). So every assertion here is about
// what the printed file says AND about what re-parsing it produces — the text
// is the wire format and the graph is the claim.
// ---------------------------------------------------------------------------

/// Print an edited script and parse the result. The only assertion that
/// matters about a structural edit is that what it produced is a file rill can
/// read, so every gate below goes through here.
fn reparse(gpa: std.mem.Allocator, reg: *rill.Registry, edited: *const rill.script.Script, out_text: *[]u8) !rill.Program {
    out_text.* = try rill.script.print(gpa, edited);
    errdefer gpa.free(out_text.*);
    var diag = rill.Diag{};
    return rill.parse(gpa, reg, "p", out_text.*, &diag) catch |e| {
        std.debug.print("edited program did not parse: {s}\n{s}\n", .{ @errorName(e), out_text.* });
        return e;
    };
}

/// The call site of the Nth node whose operator is `op`.
fn siteOf(prog: *const rill.Program, reg: *const rill.Registry, op: []const u8, nth: usize) !rill.graph.CallSite {
    var seen: usize = 0;
    for (prog.nodes.items) |n| {
        if (!std.mem.eql(u8, reg.get(n.op).name, op)) continue;
        if (seen == nth) return n.site;
        seen += 1;
    }
    return error.NoSuchNode;
}

test "edit: unlink a required port leaves a declared HOLE, and the file still parses" {
    // An editor needs text that says "this operator is here and this input is
    // not chosen yet", and rill's only such text is §3.15's hole — which is
    // exactly what `addCall` mints for the same reason.
    //
    // MUTATION A: drop the argument instead of replacing it with a hole. The
    // file prints `plane.a | mul` and does not parse: a required port with
    // nothing bound is a parse error, so unlinking anything would destroy the
    // program rather than open a socket.
    // MUTATION B: emit the hole argument but not the `using`. `:mul_b` is then
    // an undeclared name and the file does not load either — which is why the
    // two are written by one function and not by a caller who might forget.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    var diag = rill.Diag{};
    var before = try rill.parse(gpa, &reg, "p", "plane.a | mul 2 | write plane.out\n", &diag);
    defer before.deinit();
    const site = try siteOf(&before, &reg, "mul", 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const edited = try rill.edit.unlink(arena.allocator(), before.script.?, &reg, .{
        .line = site.line,
        .col = site.col,
        .port = 1,
    });

    var text: []u8 = undefined;
    var after = try reparse(gpa, &reg, &edited, &text);
    defer gpa.free(text);
    defer after.deinit();

    // The declaration and the use, both present and agreeing.
    try testing.expect(std.mem.indexOf(u8, text, "using ?number as :mul_b") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mul :mul_b") != null);
    // …and the literal it replaced is gone.
    try testing.expect(std.mem.indexOf(u8, text, "mul 2") == null);

    // The GRAPH says the same thing: that port is a hole now, not a literal.
    for (after.nodes.items) |n| {
        if (!std.mem.eql(u8, reg.get(n.op).name, "mul")) continue;
        try testing.expect(after.slot(n.inputs[1]).source == .hole);
    }
}

test "edit: link names the producer's output and the consumer reads it" {
    // The whole of what a wire is between two statements. Fan-out comes free:
    // a name may be read by any number of consumers, which is why nothing in
    // `link` asks how many wires already leave that output.
    //
    // MUTATION A: skip the `as` and point the consumer at the producer's
    // OPERATOR name. `mul` is an unknown name at that position and the file
    // does not load.
    // MUTATION B: name the output but leave the consumer's argument alone.
    // The file parses — it is a valid program — and the wire the reader
    // dragged is simply not there, which is the failure a gate over text
    // alone would miss. The graph assertion below is what catches it.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    const src =
        \\plane.a | mul 2
        \\
        \\plane.b | add 3 | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var before = try rill.parse(gpa, &reg, "p", src, &diag);
    defer before.deinit();
    const producer = try siteOf(&before, &reg, "mul", 0);
    const consumer = try siteOf(&before, &reg, "add", 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const edited = try rill.edit.link(
        arena.allocator(),
        before.script.?,
        &reg,
        .{ .line = producer.line, .col = producer.col, .port = 0 },
        .{ .line = consumer.line, .col = consumer.col, .port = 1 },
    );

    var text: []u8 = undefined;
    var after = try reparse(gpa, &reg, &edited, &text);
    defer gpa.free(text);
    defer after.deinit();

    try testing.expect(std.mem.indexOf(u8, text, " as ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add 3") == null);

    // **The wire, in the graph.** `add`'s port 1 is fed by a wire whose
    // producer is the `mul` node — not a literal, and not some other node.
    var checked = false;
    for (after.nodes.items) |n| {
        if (!std.mem.eql(u8, reg.get(n.op).name, "add")) continue;
        const s = after.slot(n.inputs[1]);
        const up = switch (s.source) {
            .wire => |u| u,
            else => return error.NotAWire,
        };
        const feeder = after.nodes.items[after.slot(up).node];
        try testing.expectEqualStrings("mul", reg.get(feeder.op).name);
        checked = true;
    }
    try testing.expect(checked);
}

test "edit: the three refusals are the GRAMMAR, and each one is named" {
    // Not an implementation's convenience. rill spells a wire as a pipe or a
    // name, and each refusal below is a place where neither spelling reaches.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // ── NeedsSplit: the producer is not its chain's last term ────────────
    // `as` names the FINAL outputs of a chain, so `A | B | C as t` names C's.
    // There is no spelling for B's without cutting the statement in two —
    // which would move the reader's paragraph, so it is refused instead.
    {
        var diag = rill.Diag{};
        var p = try rill.parse(gpa, &reg, "p", "plane.a | mul 2 | write plane.out\n\nplane.b | add 3\n", &diag);
        defer p.deinit();
        const mid = try siteOf(&p, &reg, "mul", 0); // mid-chain: `write` follows
        const cons = try siteOf(&p, &reg, "add", 0);
        try testing.expectError(error.NeedsSplit, rill.edit.link(
            a,
            p.script.?,
            &reg,
            .{ .line = mid.line, .col = mid.col, .port = 0 },
            .{ .line = cons.line, .col = cons.col, .port = 1 },
        ));
    }

    // ── NeedsReorder: a name read above where it is written ──────────────
    // rill's parse order IS its dependency order, so this is not a style
    // preference — the file would not load.
    {
        var diag = rill.Diag{};
        var p = try rill.parse(gpa, &reg, "p", "plane.a | mul 2\n\nplane.b | add 3\n", &diag);
        defer p.deinit();
        const later = try siteOf(&p, &reg, "add", 0);
        const earlier = try siteOf(&p, &reg, "mul", 0);
        try testing.expectError(error.NeedsReorder, rill.edit.link(
            a,
            p.script.?,
            &reg,
            .{ .line = later.line, .col = later.col, .port = 0 },
            .{ .line = earlier.line, .col = earlier.col, .port = 1 },
        ));
    }

    // ── InsideDefinition: editable, but not by this gesture ──────────────
    // A def body is shared by every call of it, so moving one wire there
    // moves it for all of them. Told apart from `NoSuchCall` deliberately:
    // the two send a reader looking in completely different places.
    {
        var diag = rill.Diag{};
        var p = try rill.parse(gpa, &reg, "p", "def double(x) =\n    x | mul 2\n\nplane.a | double | write plane.out\n", &diag);
        defer p.deinit();
        const inner = try siteOf(&p, &reg, "mul", 0);
        try testing.expectError(error.InsideDefinition, rill.edit.unlink(
            a,
            p.script.?,
            &reg,
            .{ .line = inner.line, .col = inner.col, .port = 1 },
        ));
    }

    // ── NoSuchCall: a stale canvas, and sugar with no call of its own ────
    {
        var diag = rill.Diag{};
        var p = try rill.parse(gpa, &reg, "p", "plane.a | mul 2\n", &diag);
        defer p.deinit();
        try testing.expectError(error.NoSuchCall, rill.edit.unlink(a, p.script.?, &reg, .{ .line = 999, .col = 1, .port = 0 }));
        // A `{0, 0}` site is sugar with no call of its own — a projection, a
        // record's assembly — and it answers the same way rather than
        // walking the whole file to discover there is nothing at line zero.
        try testing.expectError(error.NoSuchCall, rill.edit.unlink(a, p.script.?, &reg, .{ .line = 0, .col = 0, .port = 0 }));
    }
}

// ---------------------------------------------------------------------------
// R6d — `edit.removeCall`: a node taken out.
// ---------------------------------------------------------------------------

test "edit: a node in the middle of a chain goes, and the pipe closes over it" {
    // What a reader watching the wire snap shut expects, and what every other
    // editor does: `A | B | C` minus B is `A | C`.
    //
    // MUTATION: remove the stage AND everything after it. The file still
    // parses — it is a shorter program — and half the reader's statement is
    // gone with the node they clicked. The `write` assertion below is what
    // catches it.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    var diag = rill.Diag{};
    var before = try rill.parse(gpa, &reg, "p", "plane.a | mul 2 | add 3 | write plane.out\n", &diag);
    defer before.deinit();
    const site = try siteOf(&before, &reg, "add", 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const edited = try rill.edit.removeCall(arena.allocator(), before.script.?, &reg, site.line, site.col);

    var text: []u8 = undefined;
    var after = try reparse(gpa, &reg, &edited, &text);
    defer gpa.free(text);
    defer after.deinit();

    try testing.expectEqualStrings("plane.a | mul 2 | write plane.out\n", text);
}

test "edit: removing a chain's HEAD leaves the next one an open socket" {
    // The first stage has nothing feeding it once the head is gone, and a
    // declared hole is what "not chosen yet" IS in rill text — the same
    // answer `unlink` gives, from the same machinery.
    //
    // MUTATION: promote the first stage to the head instead. `mul 2` with
    // nothing piped in binds `2` to port 0, so the program still parses and
    // quietly computes something else — the worst kind of edit.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    var diag = rill.Diag{};
    var before = try rill.parse(gpa, &reg, "p", "mul 2 3 | add 1 | write plane.out\n", &diag);
    defer before.deinit();
    const site = try siteOf(&before, &reg, "mul", 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const edited = try rill.edit.removeCall(arena.allocator(), before.script.?, &reg, site.line, site.col);

    var text: []u8 = undefined;
    var after = try reparse(gpa, &reg, &edited, &text);
    defer gpa.free(text);
    defer after.deinit();

    try testing.expect(std.mem.indexOf(u8, text, "mul") == null);
    try testing.expect(std.mem.indexOf(u8, text, "using ?") != null);
    // The socket feeds `add`, and `add`'s own `1` is untouched.
    try testing.expect(std.mem.indexOf(u8, text, "| add 1 | write plane.out") != null);
    for (after.nodes.items) |n| {
        if (!std.mem.eql(u8, reg.get(n.op).name, "add")) continue;
        try testing.expect(after.slot(n.inputs[0]).source == .hole);
    }
}

test "edit: an add and a later delete take the adjacent pair away together" {
    // `addCall`'s header wrote this contract a beat before there was anything
    // to honour it: the `using` sits WITH its statement rather than hoisted to
    // the top because that is *"the one that survives being undone"*. Add an
    // operator, delete it, and the file is the one you started with.
    //
    // MUTATION: skip the `drop` list and remove only the statement. The
    // program is right and the file is not — an orphan `using ?number as
    // :push_k` drifts above a statement nobody wrote there, and it accumulates
    // one per add-then-delete for the life of the file.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    const src = "plane.a | mul 2 | write plane.out\n";
    var diag = rill.Diag{};
    var before = try rill.parse(gpa, &reg, "p", src, &diag);
    defer before.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const added = try rill.edit.addCall(a, before.script.?, &reg, "clamp");
    const with_add = try rill.script.print(a, &added);
    try testing.expect(std.mem.indexOf(u8, with_add, "using ?number as :clamp_") != null);

    var mid = try rill.parse(gpa, &reg, "p", with_add, &diag);
    defer mid.deinit();
    const site = try siteOf(&mid, &reg, "clamp", 0);
    const removed = try rill.edit.removeCall(a, mid.script.?, &reg, site.line, site.col);
    const back = try rill.script.print(a, &removed);

    try testing.expectEqualStrings(src, back);
}

test "edit: a node whose name is still READ is refused, and one nobody reads is not" {
    // The refusal is about MEANING, not breakage: removing the statement takes
    // the name away and a reader below is broken — but removing a chain's last
    // term silently REPOINTS the name at a different producer, which is worse,
    // and looks like nothing at all in a diff.
    //
    // MUTATION: check `nameRead` only when the whole statement goes. The
    // second arm below stops refusing, and `t1` quietly comes to mean `mul`'s
    // output instead of `add`'s.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Whole statement, name read below.
    {
        var diag = rill.Diag{};
        var p = try rill.parse(gpa, &reg, "p", "plane.a | mul 2 as t1\n\nt1 | add 3 | write plane.out\n", &diag);
        defer p.deinit();
        const site = try siteOf(&p, &reg, "mul", 0);
        try testing.expectError(error.StillRead, rill.edit.removeCall(a, p.script.?, &reg, site.line, site.col));
    }

    // Chain TAIL, name read below: the name would move rather than vanish.
    {
        var diag = rill.Diag{};
        var p = try rill.parse(gpa, &reg, "p", "plane.a | mul 2 | add 3 as t1\n\nt1 | write plane.out\n", &diag);
        defer p.deinit();
        const site = try siteOf(&p, &reg, "add", 0);
        try testing.expectError(error.StillRead, rill.edit.removeCall(a, p.script.?, &reg, site.line, site.col));
    }

    // A name NOBODY reads is not worth a refusal — it is dropped with the term
    // it named, and the statement keeps working.
    {
        var diag = rill.Diag{};
        var p = try rill.parse(gpa, &reg, "p", "plane.a | mul 2 | add 3 as unread\n", &diag);
        defer p.deinit();
        const site = try siteOf(&p, &reg, "add", 0);
        const edited = try rill.edit.removeCall(a, p.script.?, &reg, site.line, site.col);
        const text = try rill.script.print(a, &edited);
        try testing.expectEqualStrings("plane.a | mul 2\n", text);
    }
}

test "using: a BRACKETED body may span lines, and prints back as one canonical shape" {
    // Christian, 2026-09-12, looking at the colour table buried mid-chain in
    // `roaches.rill`: *"maybe we should hoist that constant record up to a
    // using … I just think it's more idiomatic."* It is — and it worked on
    // ONE line and only on one line, so a four-stop Oklab table came to 135
    // characters against a canon of 88, in a file that is 230 lines of
    // 88-column prose.
    //
    // Two halves, and each has its own mutation:
    //
    // MUTATION A (parser): restore `while (peek != .newline)`. The multi-line
    // spelling fails at the `using` itself with "binds tokens to a name",
    // because the span it captured was a lone `[`.
    // MUTATION B (printer): `self.w(u.body)` instead of `fitValue`. It parses,
    // and `fmt` collapses it straight back onto one line — so format-on-save
    // undoes the hoist the moment the reader writes it, which is worse than
    // refusing it. The second assertion is the one that catches this.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    const wrapped =
        \\using [
        \\    {l: 0.28, a: -0.02, b: -0.08},
        \\    {l: 0.55, a: 0.02, b: 0.02},
        \\    {l: 1.10, a: 0.10, b: 0.10},
        \\    {l: 2.00, a: 0.14, b: 0.15}
        \\] as :stops
        \\
        \\plane.a | mul 2 | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(gpa, &reg, "p", wrapped, &diag);
    defer prog.deinit();

    // It prints back as EXACTLY what was written — the shape is canonical, so
    // format-on-save leaves a reader's hoist alone.
    const printed = try rill.script.print(gpa, prog.script.?);
    defer gpa.free(printed);
    try testing.expectEqualStrings(wrapped, printed);

    // …and printing twice changes nothing, which is the property the whole
    // corpus is held to.
    var d2 = rill.Diag{};
    var again = try rill.parse(gpa, &reg, "p", printed, &d2);
    defer again.deinit();
    const twice = try rill.script.print(gpa, again.script.?);
    defer gpa.free(twice);
    try testing.expectEqualStrings(printed, twice);

    // **One canonical form, two spellings in.** The same binding written on
    // one long line normalises to the wrapped shape, so the file does not
    // print two ways depending on how it was typed.
    const oneline =
        \\using [{l: 0.28, a: -0.02, b: -0.08}, {l: 0.55, a: 0.02, b: 0.02}, {l: 1.10, a: 0.10, b: 0.10}, {l: 2.00, a: 0.14, b: 0.15}] as :stops
        \\
        \\plane.a | mul 2 | write plane.out
        \\
    ;
    var d3 = rill.Diag{};
    var flat = try rill.parse(gpa, &reg, "p", oneline, &d3);
    defer flat.deinit();
    const from_flat = try rill.script.print(gpa, flat.script.?);
    defer gpa.free(from_flat);
    try testing.expectEqualStrings(wrapped, from_flat);
}

test "using: a SHORT body stays on its line, and an unclosed section still ends at the newline" {
    // Two things the new freedom must not have taken away.
    //
    // MUTATION A: drop the width test in `fitValue` — every `using` in the
    // corpus explodes onto four lines, including `using plane.drift.@self.k
    // as :k`, which is the idiom this whole feature is imitating.
    // MUTATION B: count `(`/`)` in the depth as well. A `using` whose body is
    // an unclosed SECTION then swallows the rest of the file looking for its
    // closer, and the refusal lands hundreds of lines from the mistake. A
    // section is a sub-graph, not a value; only `[` and `{` may wrap.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    const short =
        \\using plane.player as :p
        \\
        \\:p.health | clamp 0 100 | write plane.ui.hp
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(gpa, &reg, "p", short, &diag);
    defer prog.deinit();
    const printed = try rill.script.print(gpa, prog.script.?);
    defer gpa.free(printed);
    try testing.expectEqualStrings(short, printed);

    // An unclosed `(` still ENDS AT THE NEWLINE, so the statement below it is
    // still a statement. (The body itself is not checked here — a `using`
    // nobody references is never expanded, which is why the first four probes
    // of this feature all looked like they passed and none of them did.)
    //
    // Mutation B lands here: count `(` in the depth and this `using` runs to
    // EOF hunting a closer, swallowing `plane.a | mul 2` with it. One node
    // becomes none.
    var d2 = rill.Diag{};
    var open = try rill.parse(gpa, &reg, "p",
        \\using (> 0 as :pred
        \\
        \\plane.a | mul 2
        \\
    , &d2);
    defer open.deinit();
    try testing.expectEqual(@as(usize, 1), open.nodes.items.len);
    try testing.expectEqualStrings("mul", reg.get(open.nodes.items[0].op).name);
}

// ---------------------------------------------------------------------------
// R6e — `Node.fold` and `edit.setFoldField`: "how do we edit record3?"
// ---------------------------------------------------------------------------

test "graph: a node spliced by a fold says WHICH fold, and where it was bound" {
    // Christian, 2026-09-12, right-clicking a record literal on the canvas:
    // *"how do we edit record3?"* A `{…}` has no `Call`, so `CallSite` has
    // nothing to say about it — but once it is hoisted to a `using` it has a
    // NAME, and a name is something an editor can act on.
    //
    // MUTATION A: `foldOriginOf` returns `.{}` always. Every sugar node
    // becomes anonymous again and the only honest answer to "edit this" goes
    // back to "you cannot".
    // MUTATION B: use `tok.fold` directly instead of `outermostSite`. Through
    // a chain of folds it names the INNER one — a name that is not in the
    // file, so an editor sends the reader looking for a `using` nobody wrote.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    const hoisted =
        \\using [{l: 0.28, a: -0.02, b: -0.08}, {l: 1.10, a: 0.10, b: 0.10}] as :stops
        \\
        \\:stops | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var prog = try rill.parse(gpa, &reg, "p", hoisted, &diag);
    defer prog.deinit();

    var records: usize = 0;
    for (prog.nodes.items) |n| {
        const op = reg.get(n.op).name;
        if (!std.mem.eql(u8, op, "record") and !std.mem.eql(u8, op, "array")) continue;
        records += 1;
        try testing.expect(n.fold.known());
        try testing.expectEqualStrings(":stops", n.fold.name);
        try testing.expectEqual(@as(u32, 1), n.fold.line);
        // …and it is still NOT a call, which is the other half of the answer.
        try testing.expect(prog.script.?.callAt(n.site.line, n.site.col) == null);
    }
    try testing.expectEqual(@as(usize, 3), records); // two records + the array

    // The node the AUTHOR wrote carries no fold — or every node in every file
    // would claim to come from somewhere it does not.
    for (prog.nodes.items) |n| {
        if (!std.mem.eql(u8, reg.get(n.op).name, "write")) continue;
        try testing.expect(!n.fold.known());
    }

    // An INLINE literal has no fold, and keeps the `{0, 0}` CALL site that
    // `R5: sugar with no Call of its own says so` insists on. The two facts
    // are separate on purpose: `site` answers "is there a call here" and
    // `fold` answers "does this have a name I can reach". A literal nobody
    // hoisted has neither, and saying so is the honest end of this road.
    var d2 = rill.Diag{};
    var inl = try rill.parse(gpa, &reg, "p", "[{l: 0.28, a: 0.0, b: 0.0}] | write plane.out\n", &d2);
    defer inl.deinit();
    for (inl.nodes.items) |n| {
        if (!std.mem.eql(u8, reg.get(n.op).name, "record")) continue;
        try testing.expect(!n.fold.known());
        try testing.expect(!n.site.known());
    }
}

test "edit: one field of one element of a fold, and the rest untouched" {
    // The answer to "how do we edit record3", end to end: hoist it, and the
    // literal has a name the editor can reach.
    //
    // MUTATION A: write `value` into every field rather than the named one.
    // The gate's `a` and `b` assertions go red — and in a file this would look
    // like a working edit until somebody read the diff.
    // MUTATION B: rejoin elements with "," instead of ", ". It still parses,
    // and `rill fmt` is no longer a no-op on the result: the corpus canon
    // breaks the moment the editor touches a file.
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();

    const src =
        \\using [{l: 0.28, a: -0.02, b: -0.08}, {l: 0.55, a: 0.02, b: 0.02}, {l: 1.10, a: 0.10, b: 0.10}] as :stops
        \\
        \\:stops | write plane.out
        \\
    ;
    var diag = rill.Diag{};
    var before = try rill.parse(gpa, &reg, "p", src, &diag);
    defer before.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const edited = try rill.edit.setFoldField(arena.allocator(), before.script.?, ":stops", 2, "l", "1.5");

    var text: []u8 = undefined;
    var after = try reparse(gpa, &reg, &edited, &text);
    defer gpa.free(text);
    defer after.deinit();

    // The one value moved…
    try testing.expect(std.mem.indexOf(u8, text, "{l: 1.5, a: 0.10, b: 0.10}") != null);
    // …and its neighbours did not, spelling included: `-0.02` is not `-0.020`.
    try testing.expect(std.mem.indexOf(u8, text, "{l: 0.28, a: -0.02, b: -0.08}") != null);
    try testing.expect(std.mem.indexOf(u8, text, "{l: 0.55, a: 0.02, b: 0.02}") != null);

    // And it is still canonical — printing what this produced changes nothing,
    // which is the property the whole corpus is held to.
    const twice = try rill.script.print(gpa, after.script.?);
    defer gpa.free(twice);
    try testing.expectEqualStrings(text, twice);
}

test "edit: a fold this cannot reach into is refused by name, never half-edited" {
    const gpa = testing.allocator;
    var reg = try hostRegistry(gpa);
    defer reg.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var diag = rill.Diag{};
    var p = try rill.parse(gpa, &reg, "p",
        \\using [{l: 0.28, a: 0.0, b: 0.0}] as :stops
        \\using [[1, 2], [3, 4]] as :pairs
        \\
        \\:stops | write plane.out
        \\
    , &diag);
    defer p.deinit();
    const sc = p.script.?;

    try testing.expectError(error.NoSuchFold, rill.edit.setFoldField(a, sc, ":nope", 0, "l", "1"));
    try testing.expectError(error.NoSuchField, rill.edit.setFoldField(a, sc, ":stops", 0, "zz", "1"));
    try testing.expectError(error.NoSuchElement, rill.edit.setFoldField(a, sc, ":stops", 9, "l", "1"));
    // An array of arrays: there is no field to name, and saying so is better
    // than inventing a meaning for it.
    try testing.expectError(error.NoSuchField, rill.edit.setFoldField(a, sc, ":pairs", 0, "l", "1"));
}
