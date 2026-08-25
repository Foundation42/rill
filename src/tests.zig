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
    \\plane.player.{health, stamina} as vitals
    \\vitals.health | clamp 0 100 | div 100 | set plane.ui.healthbar
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
        \\plane.hp | add 0 | set plane.out
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
    , .{ .{ "plane.hp", @as(i64, 20) } });
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
    , .{ .{ "plane.b", false } });
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
    , .{ .{ "plane.n", @as(i64, 5) } });
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
    , .{ .{ "plane.hp", @as(i64, 50) } });
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
    try testing.expectEqual(@as(f64, 3.0), types.asNumber(rt2.readSlot(knob).?).? );

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
        \\plane.hp | clamp 0 100 | div 100 | set plane.ui.bar
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
        \\select plane.under 10 20 | set plane.grade
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
    try testing.expectEqualStrings("6fdc7346e5597174845ba80c74d119241d20cce0dcbebc1ca62f2f5dfe3d8041", &hex);
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
// last statement is an expression rather than a sink (rillbook §2). An effect
// line has no result: every effect op declares no outputs, so its
// acknowledgement stands alone rather than echoing a fabricated value.
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
        \\plane.a | add 1 | set plane.out
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
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | rose_above 0 | also { set plane.log } | tap seen");
    defer prog.deinit();

    const upstream = prog.node(nodeIdOf(&prog, "rose_above1").?).outputs[0];
    const set_in = prog.slot(prog.node(nodeIdOf(&prog, "set1").?).inputs[0]);
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
    var prog = try parseOk(testing.allocator, &reg, "plane.alerts | also { set plane.log } | tap attack");
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
    try testing.expectEqual(@as(u64, 3), rt.eval_count[nodeIdOf(&prog, "set1").?]);
    try testing.expectEqual(@as(u64, 3), rt.eval_count[nodeIdOf(&prog, "tap1").?]);
    try testing.expectEqual(@as(usize, 3), mock.writes.items.len);
}

test "also: a multi-statement block is more branches off the same slot" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.hp | rose_above 0
        \\  | also {
        \\      set plane.a
        \\      set plane.b
        \\    }
        \\  | tap seen
    );
    defer prog.deinit();

    const upstream = prog.node(nodeIdOf(&prog, "rose_above1").?).outputs[0];
    try testing.expectEqual(upstream, prog.slot(prog.node(nodeIdOf(&prog, "set1").?).inputs[0]).source.wire);
    try testing.expectEqual(upstream, prog.slot(prog.node(nodeIdOf(&prog, "set2").?).inputs[0]).source.wire);
    try testing.expectEqual(@as(usize, 3), prog.downstream[upstream].len);
}

test "also: the block's writes join the write list — the cycle check sees through it" {
    try expectParseError("plane.x | rose_above 0 | also { set plane.x } | tap t", "cycle");
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
        \\plane.hp | also { set plane.a } | tap seen
        \\plane.hp | also { emitter mode ambient } | tap heard
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 0), prog.warnings.items.len);
}

test "also: the shapes that cannot mean anything are refused" {
    // A block with no branch passes the value along and does nothing.
    try expectParseError("plane.hp | also { } | tap t", "empty block");
    // Nothing to branch off.
    try expectParseError("also { set plane.a }", "needs a value to pass along");
    try expectParseError("plane.hp | also { also { set plane.a } }", "needs a value to pass along");
    // A branch head that isn't an operator was never wired to the source, so
    // it could never rouse — the silent failure this syntax exists to avoid.
    try expectParseError("plane.hp | also { plane.other | set plane.a } | tap t", "begin with an operator");
    try expectParseError("plane.hp | also { 42 | set plane.a } | tap t", "begin with an operator");
    try expectParseError("plane.hp | also { set plane.a", "unclosed block");
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
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | also { latch trigger: plane.tick | set plane.a } | tap t");
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
// | set plane.x` reads a path it writes and §4.4 rightly refuses it.
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
            \\use plane.defense as d
            \\plane.{s}.enemy_count | rose_above 0
            \\  | also {{ inc d.sightings 1 }}
            \\  | notify d.alerts
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
        \\use plane.defense as d
        \\
        \\plane.gate.enemy_count | rose_above 0
        \\  | also { inc d.sightings 1 }
        \\  | notify d.alerts
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
    var prog = try parseOk(testing.allocator, &reg,
        "plane.sensors.tower.visible_enemies | rose_above 0 | notify plane.signals.horn { kind: \"approach\", from: \"tower\" }");
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
        .{ .name = "=", .class = .pure },
        .{ .name = "!=", .class = .pure },
        .{ .name = "<", .class = .pure },
        .{ .name = "<=", .class = .pure },
        .{ .name = ">", .class = .pure },
        .{ .name = ">=", .class = .pure },
        .{ .name = "record", .class = .pure },
        .{ .name = "project", .class = .pure },
        .{ .name = "merge", .class = .pure },
        .{ .name = "set", .class = .effect },
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
    try testing.expectError(error.Denied, mock.asPlane().write("plane.tags", enc, .membership));
}

// ---------------------------------------------------------------------------
// The sink shape: `<verb> <path> [value]`, shared by `set` and `notify`.
// Piped value: write what's flowing. Bound value: write this, because
// something flowed.
// ---------------------------------------------------------------------------

test "set: a rousing writes a constant, in one node" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    // Ironwood's gate.rill: "at the sound of the alarm, drop the portcullis."
    // Before the `value` port this took three nodes to say one word — hold the
    // constant in a latch, sample it on the rousing, pipe it to the sink.
    var prog = try parseOk(testing.allocator, &reg, "plane.signals.horn | set plane.gate.portcullis 1");
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
    var prog = try parseOk(testing.allocator, &reg, "plane.hp | clamp 0 100 | set plane.ui.bar");
    defer prog.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.hp", @as(i64, 40));
    var rt = try rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{});
    defer rt.deinit();
    try testing.expectEqual(@as(f64, 40), types.asNumber(mock.writes.items[0].value).?);

    // Unpiped: the value binds port 0 and is both rousing and payload — the
    // console's entire `set <path> <value>` grammar, untouched.
    var prog2 = try parseOk(testing.allocator, &reg, "set plane.ui.bar 0.5");
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
    var prog = try parseOk(testing.allocator, &reg, "plane.pulse | set plane.out plane.amount");
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

test "set and notify are the same shape, and that is the point" {
    var reg = try rill.Registry.init(testing.allocator);
    defer reg.deinit();
    try rill.registerCore(&reg);
    const set = reg.get(reg.find("set").?);
    const notify = reg.get(reg.find("notify").?);
    // They diverged for exactly one day — notify grew the payload port first,
    // because the pipe took its only port and the sentinel was unsayable, and
    // `set` met the identical wall one scenario later. The port is the sink
    // SHAPE now, not one op's exception. What is left is intent.
    try testing.expectEqual(set.inputs.len, notify.inputs.len);
    for (set.inputs, notify.inputs) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqual(a.optional, b.optional);
    }
    try testing.expectEqual(set.class, notify.class);
    try testing.expectEqual(@as(usize, 0), set.outputs.len);
    // This is the slot the G2 hash moved for: unbound, but present.
    try testing.expect(set.inputs[1].optional);
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
    var prog = try parseOk(testing.allocator, &reg,
        "plane.gate.enemies | rose_above 0 | cast $alarm 1.0 radius 30 at plane.gate.pos decay 2s");
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
    var prog = try parseOk(testing.allocator, &reg,
        "plane.lvl | cast $blight radius: 12 at: plane.origin");
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
    try expectParseError("$alarm | mul 2 | set plane.x", "standpoint");
    // The sigil belongs to channels alone.
    try expectParseError("plane.x | mul 2 as $x", "cannot wear");
    try expectParseError("plane.x | mul 2 as @x", "cannot wear");
    try expectParseError("@tom | mul 2 | set plane.x", "entity reference");
    try expectParseError("use plane.a as $s", "cannot wear");
    try expectParseError("def $d(x) = x | mul 2", "cannot wear");
}

test "cast: a channel name is a legal plane-path segment" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        "plane.sensors.gate.$alarm | rose_above 0.5 | set plane.ui.alert");
    defer prog.deinit();
    try testing.expectEqualStrings("plane.sensors.gate.$alarm", prog.subs.items[0].path);
}

test "cast: piped, it deposits what flows — and only when the rousing flows" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        "plane.lvl | cast $blight radius 12 at plane.origin", .{
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
    try mountFixture(testing.allocator, &fx,
        "cast $torchlight 0.8 radius 12 at plane.brazier decay 4s", .{
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
    try mountFixture(testing.allocator, &fx,
        "plane.horn | cast $alarm 1.0 radius 30 at plane.gate", .{
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
    try mountFixture(testing.allocator, &fx,
        "every 1f { cast $torchlight 0.8 radius 12 at plane.brazier decay 4s }", .{
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
        \\    set plane.a
        \\    set plane.b
        \\}
    );
    defer prog.deinit();
    const s1 = prog.slot(prog.node(nodeIdOf(&prog, "set1").?).inputs[0]).source;
    const s2 = prog.slot(prog.node(nodeIdOf(&prog, "set2").?).inputs[0]).source;
    try testing.expectEqualStrings("plane.hp", s1.plane);
    try testing.expectEqualStrings("plane.hp", s2.plane);
}

test "block rule: the also guards carry over, and mid-chain blocks name their spelling" {
    // A block is a fan-out, not a body — every also-rule holds at the head.
    try expectParseError("every 1f { }", "empty block");
    try expectParseError("every 1f { tap t as x }", "no name escapes");
    try expectParseError("every 1f { plane.x | set plane.a }", "begin with an operator");
    // Mid-chain, the word is `also` — one spelling per position.
    try expectParseError("plane.x | mul 2 { set plane.a }", "ride 'also");
}

test "block rule: a serialized caster survives the round trip, cadence intact" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    try mock.putValue("plane.brazier", @as(i64, 3));
    var prog = try parseOk(testing.allocator, &reg,
        "every 2f { cast $torchlight 0.8 radius 12 at plane.brazier }");
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
    var prog = try parseOk(testing.allocator, &reg,
        "plane.hp | also { cast $dread 0.5 radius 8 at plane.here } | tap seen");
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
        \\  | set plane.out// flush against a name: the name cannot eat the slashes
    , .{.{ "plane.hp", @as(i64, 4) }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 8), types.asNumber(fx.mock.store.get("plane.out").?).?);
}

test "comments: slash-form path literals never trip the comment rule" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    // `render/grade/exposure` is one word (single slashes join name chars);
    // the `//` after it is a comment.
    var prog = try parseOk(testing.allocator, &reg,
        "plane.v | tap render/grade/exposure // knob path survives");
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
    // Both ways, like the class table: a manual whose examples silently
    // stopped being collected would pass vacuously. Update on purpose when
    // examples are added or removed.
    // 28 → 30 (2026-08-25): the tags-campaign parity pass added the
    // membership muster and the coupled cast to the human manual's §7.
    try testing.expectEqual(@as(usize, 30), human);
    try testing.expectEqual(@as(usize, 3), agent);
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
        \\use plane.render.grade as g
        \\plane.hp | g.exposure
    , "did you forget `set`?");
}

test "paths: integer segments are legitimate — id-keyed rows parse" {
    // The @ registry's mirrors are id-keyed (`plane.ents.1.pos`), and the
    // tokenizer's trailing-dot rule already splits `1.pos` correctly.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg, "plane.ents.1.pos | set plane.debug.tom");
    defer prog.deinit();
    try testing.expectEqualStrings("plane.ents.1.pos", prog.subs.items[0].path);
}

// ---------------------------------------------------------------------------
// tag / untag — the membership sinks (ironwood R6 T3)
// ---------------------------------------------------------------------------

test "tag: the stamped grammar parses, and the member write enters the write list" {
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        "plane.sighting | rose_above 0 | tag @tom #garrison");
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
    try mountFixture(testing.allocator, &fx,
        "plane.horn | tag @tom #garrison", .{});
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
    try mountFixture(testing.allocator, &fx,
        "plane.stood_down | untag @tom #garrison", .{});
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
        \\plane.tags.garrison | set plane.hud.n
        \\plane.x | tag @tom #garrison
    , "cycle");
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var prog = try parseOk(testing.allocator, &reg,
        \\plane.tags.garrison.joined | set plane.hud.last_join
        \\plane.tags.garrison.count | set plane.hud.n
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
    try expectParseError("#garrison | set plane.x", "plane.tags.garrison.count");
    // The sigil guards hold for `#` as they do for `$` and `@`.
    try expectParseError("plane.x | mul 2 as #x", "cannot wear");
    try expectParseError("use plane.a as #s", "cannot wear");
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
        \\plane.tags.garrison | enlist | set plane.y
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
    try mountFixture(testing.allocator, &fx,
        "plane.x | cast $alarm 1 radius 5 at plane.p to #hostile", .{});
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
    try mountFixture(testing.allocator, &fx,
        "plane.s | lerp 0.5 1.5 | set plane.out", .{
        .{ "plane.s", @as(f64, 0.25) },
    });
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 0.75), types.asNumber(fx.mock.store.get("plane.out").?).?);
}

test "and/or/not: the conjunction idiom's missing words" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.dark | and plane.calm | set plane.both
        \\plane.dark | or plane.calm | set plane.either
        \\plane.dark | not | set plane.lit
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
    try expectParseError("^raider | set plane.x", "engine-owned");
    try expectParseError("plane.x | mul 2 as ^x", "cannot wear");
    try expectParseError("def ^d(x) = x | mul 2", "cannot wear");
}
