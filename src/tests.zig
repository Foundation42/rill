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
    _ = try reg.register(.{ .name = "cube", .inputs = &host.ports_cube, .outputs = &host.out_mesh, .help = "stub", .eval = stubEval });
    _ = try reg.register(.{ .name = "bevel", .inputs = &host.ports_mesh_num, .outputs = &host.out_mesh, .help = "stub", .eval = stubEval });
    _ = try reg.register(.{ .name = "rot", .inputs = &host.ports_mesh_num, .outputs = &host.out_mesh, .help = "stub", .eval = stubEval });
    _ = try reg.register(.{ .name = "shell", .inputs = &host.ports_mesh_num, .outputs = &host.out_mesh, .help = "stub", .eval = stubEval });
    _ = try reg.register(.{ .name = "boolean subtract", .inputs = &host.ports_mesh_mesh, .outputs = &host.out_mesh, .help = "stub", .eval = stubEval });
    _ = try reg.register(.{ .name = "sound play", .inputs = &host.ports_tail, .outputs = &host.out_str, .help = "stub", .eval = echoTailEval });
    _ = try reg.register(.{ .name = "emitter drop", .inputs = &host.ports_gain_tail, .statics = &host.statics_emitter, .outputs = &host.out_str, .help = "stub", .eval = echoTailEval });
    _ = try reg.register(.{ .name = "say", .inputs = &host.ports_tail_opt, .outputs = &host.out_str, .help = "stub", .eval = echoTailEval });
    _ = try reg.register(.{ .name = "volume set", .inputs = &host.ports_vol_set, .outputs = &host.out_str, .help = "stub", .class = .effect, .eval = stubEval });
    _ = try reg.register(.{ .name = "emitter mode", .inputs = &host.ports_emitter_mode, .outputs = &host.out_str, .help = "stub", .class = .effect, .eval = stubEval });
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
    \\plane.player.{health, stamina} as stats
    \\stats.health | clamp 0 100 | div 100 | set plane.ui.healthbar
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
        try fx.rt.tick();
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
        \\plane.hp | add 0 | set plane.out
    , .{});
    defer fx.deinit();
    const add_id = nodeIdOf(&fx.prog, "add1").?;
    const before = fx.rt.eval_count[add_id];
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 10));
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 30));
    try fx.rt.tick();
    try testing.expectEqual(before + 1, fx.rt.eval_count[add_id]);
    // the flushed write carries the coalesced (last) value: 30 + 0 = 30.0
    const last = fx.mock.writes.items[fx.mock.writes.items.len - 1];
    try testing.expectEqual(@as(f64, 30.0), types.asNumber(last.value).?);
}

test "G3: health+stamina in one tick ⇒ the record evaluates once" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.player.{health, stamina} as stats
    , .{ .{ "plane.player.health", @as(i64, 100) }, .{ "plane.player.stamina", @as(i64, 100) } });
    defer fx.deinit();
    const rec_id = nodeIdOf(&fx.prog, "record1").?;
    const before = fx.rt.eval_count[rec_id];
    try feedValue(&fx.rt, testing.allocator, "plane.player.health", @as(i64, 55));
    try feedValue(&fx.rt, testing.allocator, "plane.player.stamina", @as(i64, 66));
    try fx.rt.tick();
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
    , .{ .{ "plane.hp", @as(i64, 20) } });
    defer fx.deinit();
    const add_id = nodeIdOf(&fx.prog, "add1").?;
    const before = fx.rt.eval_count[add_id];
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 20));
    try fx.rt.tick();
    try testing.expectEqual(before, fx.rt.eval_count[add_id]);
}

test "G4: occurrences with identical payloads both propagate" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.b | edge | tap fired
    , .{ .{ "plane.b", false } });
    defer fx.deinit();
    const tap_id = nodeIdOf(&fx.prog, "tap1").?;
    const before = fx.rt.eval_count[tap_id];
    const wave = [_]bool{ true, false, true };
    for (wave) |v| {
        try feedValue(&fx.rt, testing.allocator, "plane.b", v);
        try fx.rt.tick();
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
    , .{ .{ "plane.n", @as(i64, 5) } });
    defer fx.deinit();
    const tap_id = nodeIdOf(&fx.prog, "tap1").?;
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, 7));
    try fx.rt.tick();
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, 9));
    try fx.rt.tick();
    try testing.expectEqual(@as(u64, 0), fx.rt.eval_count[tap_id]);
    // and the gate opens when the predicate holds
    try feedValue(&fx.rt, testing.allocator, "plane.n", @as(i64, -3));
    try fx.rt.tick();
    try testing.expectEqual(@as(u64, 1), fx.rt.eval_count[tap_id]);
}

test "G5: partition routes every input to exactly one side" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.hp as hp
        \\partition (< 20) hp as low, ok
        \\low | tap l
        \\ok | tap o
    , .{ .{ "plane.hp", @as(i64, 50) } });
    defer fx.deinit();
    const tap_low = nodeIdOf(&fx.prog, "tap1").?;
    const tap_ok = nodeIdOf(&fx.prog, "tap2").?;
    const feeds = [_]i64{ 15, 25, 10, 90, 3 }; // 3 low, 2 ok (+1 ok at mount)
    for (feeds) |v| {
        try feedValue(&fx.rt, testing.allocator, "plane.hp", v);
        try fx.rt.tick();
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
    try expectParseError("plane.x | add 1 | set plane.x", "cycle");
    // segment-prefix overlap counts too, either direction
    try expectParseError("plane.a.b | add 1 | set plane.a", "cycle");
    try expectParseError("plane.a | add 1 | set plane.a.b", "cycle");
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
        \\plane.v | scaled | set plane.out
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
    try fx.rt.tick();
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
    try testing.expectEqual(@as(f64, 3.0), types.asNumber(rt2.readSlot(knob).?).? );

    // and the restored graph keeps computing with the override
    try feedValue(&rt2, testing.allocator, "plane.v", @as(i64, 20));
    try rt2.tick();
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
    try fx.rt.tick();

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
        \\plane.hp | clamp 0 100 | div 100 | set plane.ui.bar
    , .{.{ "plane.hp", @as(i64, 250) }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 1), fx.mock.writes.items.len);
    try testing.expectEqual(@as(f64, 1.0), types.asNumber(fx.mock.writes.items[0].value).?);
}

test "records: projection follows field changes; wire slots are watchable" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.player.{health, mana} as stats
        \\stats.mana | add 0 as m
    , .{ .{ "plane.player.health", @as(i64, 100) }, .{ "plane.player.mana", @as(i64, 30) } });
    defer fx.deinit();
    const add_out = "programs.p.add1.out.out";
    try testing.expectEqual(@as(f64, 30.0), types.asNumber(fx.rt.readSlot(add_out).?).?);
    try feedValue(&fx.rt, testing.allocator, "plane.player.mana", @as(i64, 75));
    try fx.rt.tick();
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
        \\select plane.under 10 20 | set plane.grade
    , .{.{ "plane.under", false }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 20), types.asNumber(fx.mock.writes.items[0].value).?);
    try feedValue(&fx.rt, testing.allocator, "plane.under", true);
    try fx.rt.tick();
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
    try testing.expectEqualStrings("462382bf2da08de4b62f3c7fbf7a6ac02f62d04602d2221c758422a465164beb", &hex);
}

// ---------------------------------------------------------------------------
// use — plane aliasing (§3.10): resolved entirely at parse; aliases are
// surface syntax and never reach the graph, the dump, or the evaluator.
// ---------------------------------------------------------------------------

test "use: aliases expand in chains, args, record sugar, and sinks" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\use plane.player as p
        \\use p.vitals as v
        \\p.health | clamp 0 100 | div 100 | set plane.ui.hp
        \\v.{mana, stamina} as pools
        \\select p.underwater 1 0 as tint
    , .{ .{ "plane.player.health", @as(i64, 50) }, .{ "plane.player.underwater", false } });
    defer fx.deinit();
    // every subscription is fully expanded — no alias residue anywhere
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

test "use: cycle detection sees through aliases" {
    try expectParseError(
        \\use plane.a as pa
        \\pa.x | add 1 | set pa.x
    , "cycle");
}

test "use: the loud-error properties survive aliasing" {
    // bare dotted names never fall through to the plane
    try expectParseError("q.health | tap t", "unknown operator or name 'q'");
    // aliases are plane-side declarations only
    try expectParseError("use q.health as h", "plane-side");
    // single-assignment holds across aliases and stream names, both ways
    try expectParseError(
        \\use plane.a as p
        \\use plane.b as p
    , "already bound");
    try expectParseError(
        \\use plane.a as p
        \\plane.b | add 0 as p
    , "shadows a use alias");
    // defs close over nothing — neither use statements nor alias references
    try expectParseError(
        \\use plane.player as p
        \\def bad(x: number) =
        \\  x | add 1
        \\  use p.q as z
        \\
        \\plane.v | bad | tap t
    , "close over nothing");
    try expectParseError(
        \\use plane.player as p
        \\def bad(x: number) =
        \\  x | add p.offset
        \\
        \\plane.v | bad | tap t
    , "close over nothing");
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
    try fx.rt.tick();
    var saw_div_out = false;
    for (Collector.paths.items) |p| {
        if (std.mem.eql(u8, p, "programs.p.div1.out.out")) saw_div_out = true;
    }
    try testing.expect(saw_div_out);
    try testing.expect(Collector.paths.items.len >= 4); // clamp in/out, div in/out at least

    // suppression means silence: same value again publishes nothing
    Collector.reset();
    try feedValue(&fx.rt, testing.allocator, "plane.hp", @as(i64, 80));
    try fx.rt.tick();
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
    _ = try reg.register(.{ .name = "poke", .inputs = &in_num, .help = "stub", .class = .effect, .eval = pokeEval });

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
