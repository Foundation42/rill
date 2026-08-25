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
    // Re-frozen 2026-08-25 (tier 2, beat 1b), deliberate: broadcast makes an
    // elementwise operator's output KIND follow its input, so every one of
    // them now declares `out` as `any` instead of a `number`/`boolean` it
    // cannot promise. The dump carries each slot's type NAME
    // (serialize.zig), so the fixture's `div 100` and `mul 0.5` output slots
    // moved from "number" to "any". No mounted-program SEMANTICS changed —
    // the values and the propagation are identical, which the test below
    // pins directly rather than asserting here.
    try testing.expectEqualStrings("939db860a972a4f14e600ade2ca922a3f43549cd02391548e94a1f246477ced6", &hex);
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
        .{ .name = "choose", .class = .pure },
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
        .{ .name = "wave", .ticks = false }, // pure shaper; ticks if its t does
        .{ .name = "range", .ticks = false },
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
    // 30 → 32, 3 → 4 (2026-08-25): tier-2 beat 1a added §6b (movement) to
    // the human manual — the waveform trio and the register examples — and
    // the register line to the agent manual's temporal row.
    // 32 → 33 (beat 1b): the human manual's §6b gained the broadcast trio.
    // 33 → 34 (beat 2a): the human manual gained §6c (arrays).
    // 34 → 35 (beat 2b): the human manual gained §6d (contracts). The shape
    // literal block in that section is deliberately NOT tagged ```rill — a
    // shape is not a program, and tagging it would ask the parser to mount a
    // type.
    try testing.expectEqual(@as(usize, 35), human);
    try testing.expectEqual(@as(usize, 4), agent);
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
    "clock", "frame",  "pi",    "tau",    "const", // sinks and passthroughs — any value is a legal payload
    "set",   "notify", "tap",   "record",
    // value-agnostic flow: these move bytes without reading them
    "latch", "changed", "where", "partition", "sample",
    "debounce", "throttle", "cooldown", "delay", "window", "arm", "disarm",
    "=", "!=",
    "tag",
    "untag",
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
    .{ .name = "project", .source = "plane.bad | project f | set plane.out" },
    .{ .name = "stats", .source = "plane.bad | stats | set plane.out" },
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

/// Build `plane.bad | <op> <fillers…> | set plane.out` from the definition.
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
        try src.appendSlice(gpa, " | set plane.out");
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
    try mountFixture(testing.allocator, &fx,
        "plane.entities.player.pos | add {x: 0, y: 2, z: 0} | set plane.lights.follow.pos",
        .{.{ "plane.entities.player.pos", .{ .x = @as(f64, 1), .y = @as(f64, 5), .z = @as(f64, -3) } }});
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
        \\plane.p | mul 2 | set plane.a
        \\plane.p | sub 1 | set plane.b
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
    try mountFixture(testing.allocator, &fx,
        "plane.a | add plane.b | set plane.o", .{
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
    try mountWatched(testing.allocator, &fx,
        "plane.a | add plane.b | set plane.o", .{
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
    try mountWatched(testing.allocator, &fx,
        "plane.a | add plane.b | set plane.o", .{
        .{ "plane.a", .{ .x = @as(f64, 1) } },
        .{ "plane.b", .{ .x = @as(f64, 1), .w = @as(f64, 2) } },
    });
    defer fx.deinit();
    try expectRefusalNames(&.{ "'w'", "left" });
}

test "beat 1b: array ⊗ array is elementwise, and unequal lengths refuse with both" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        "plane.v | window 10s | mul 2 | set plane.o", .{.{ "plane.v", @as(f64, 3) }});
    defer fx.deinit();
    // `window 10s | mul 2` IS map — the draft's own claim, executed.
    const arr = try arrayNums(testing.allocator, fx.rt.readSlot("programs.p.mul1.out.out").?);
    defer testing.allocator.free(arr);
    try testing.expectEqual(@as(usize, 1), arr.len);
    try testing.expectEqual(@as(f64, 6), arr[0]);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        "plane.a | add plane.b | set plane.o", .{
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
    try mountWatched(testing.allocator, &fx,
        "plane.a | add plane.b | set plane.o", .{
        .{ "plane.a", .{ .x = @as(f64, 1), .y = @as(f64, 2) } },
        .{ "plane.b", [_]f64{ 1, 2 } },
    });
    defer fx.deinit();
    try expectRefusalNames(&.{ "record{x, y}", "[number]", "no elementwise meaning" });
}

test "beat 1b: nesting recurses, and a non-numeric leaf is named where it lives" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        "plane.a | mul 2 | set plane.o",
        .{.{ "plane.a", .{ .inner = .{ .x = @as(f64, 3) } } }});
    defer fx.deinit();
    const nested = try fieldValue(testing.allocator, fx.rt.readSlot("programs.p.mul1.out.out").?, "inner");
    defer testing.allocator.free(nested);
    const leaf = try recordFields(testing.allocator, nested);
    defer freeFields(testing.allocator, leaf);
    try testing.expectEqualStrings("x", fieldName(leaf[0]));
    try testing.expectEqual(@as(f64, 6), leaf[0].v);

    // A string two levels down is named by its PATH, not merely reported.
    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        "plane.a | mul 2 | set plane.o",
        .{.{ "plane.a", .{ .inner = .{ .name = "tom" } } }});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "mul", "string", "not a number", ".inner.name" });
}

test "beat 1b: comparators broadcast — beat 3's keep depends on it" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        "plane.a | > 0 | set plane.o", .{.{ "plane.a", [_]f64{ 1, -2, 3 } }});
    defer fx.deinit();
    const bits = try arrayBools(testing.allocator, fx.rt.readSlot("programs.p.gt1.out.out").?);
    defer testing.allocator.free(bits);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, bits);
}

test "beat 1b: and/or/not broadcast over containers too" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.flags | not | set plane.a
        \\plane.flags | and true | set plane.b
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
        \\plane.a | = plane.b | set plane.same
        \\plane.a | = plane.c | set plane.other
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
        .{ .src = "plane.v | add 1 | set plane.o", .node = "add1", .want = .{ 4, -1 } },
        .{ .src = "plane.v | sub 1 | set plane.o", .node = "sub1", .want = .{ 2, -3 } },
        .{ .src = "plane.v | mul 3 | set plane.o", .node = "mul1", .want = .{ 9, -6 } },
        .{ .src = "plane.v | div 2 | set plane.o", .node = "div1", .want = .{ 1.5, -1 } },
        .{ .src = "plane.v | min 0 | set plane.o", .node = "min1", .want = .{ 0, -2 } },
        .{ .src = "plane.v | max 0 | set plane.o", .node = "max1", .want = .{ 3, 0 } },
        .{ .src = "plane.v | abs | set plane.o", .node = "abs1", .want = .{ 3, 2 } },
        .{ .src = "plane.v | floor | set plane.o", .node = "floor1", .want = .{ 3, -2 } },
        .{ .src = "plane.v | ceil | set plane.o", .node = "ceil1", .want = .{ 3, -2 } },
        .{ .src = "plane.v | round | set plane.o", .node = "round1", .want = .{ 3, -2 } },
        .{ .src = "plane.v | sign | set plane.o", .node = "sign1", .want = .{ 1, -1 } },
        .{ .src = "plane.v | pow 2 | set plane.o", .node = "pow1", .want = .{ 9, 4 } },
        .{ .src = "plane.v | mod 4 | set plane.o", .node = "mod1", .want = .{ 3, 2 } },
        .{ .src = "plane.v | sqrt | set plane.o", .node = "sqrt1", .want = .{ 1.7320508075688772, std.math.nan(f64) } },
    };
    inline for (cases) |c| {
        // as a record…
        var fx: Fixture = undefined;
        try mountFixture(testing.allocator, &fx, c.src,
            .{.{ "plane.v", .{ .a = @as(f64, 3), .b = @as(f64, -2) } }});
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
    try mountFixture(testing.allocator, &fx,
        "plane.v | add 1 | mul 2 | > 5 | set plane.o", .{.{ "plane.v", @as(f64, 3) }});
    defer fx.deinit();
    try testing.expectEqual(@as(f64, 4), slotNum(&fx, "programs.p.add1.out.out").?);
    try testing.expectEqual(@as(f64, 8), slotNum(&fx, "programs.p.mul1.out.out").?);
    try testing.expect(types.asBool(fx.rt.readSlot("programs.p.gt1.out.out").?).?);
}

test "beat 1b: the math completions" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\pi as half_turn
        \\half_turn | set plane.pi
        \\tau | set plane.tau
        \\plane.v | mul half_turn | sin | set plane.s
        \\plane.v | atan2 0 | set plane.at
        \\plane.v | fract | set plane.fr
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
        \\plane.a | mod 360 | set plane.m
        \\plane.a | fract | set plane.f
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
    try mountFixture(testing.allocator, &fx,
        "lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure", .{});
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
    try mountFixture(testing.allocator, &fx,
        "plane.target | ease 100ms | set plane.out",
        .{.{ "plane.target", @as(f64, 1.0) }});
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
        .{ .src = "plane.v | ease 50ms | set plane.o", .node = "ease1", .seed = 0, .then = 1 },
        .{ .src = "plane.v | ramp 200ms | set plane.o", .node = "ramp1", .seed = 0, .then = 1 },
        // diff stops when the rate reaches zero: a value that stopped moving
        // has velocity zero, and reporting the last velocity forever is the
        // bug this op exists to avoid.
        .{ .src = "plane.v | diff | set plane.o", .node = "diff1", .seed = 0, .then = 5 },
        // integrate stops at its clamp — the bound is also the cutoff.
        .{ .src = "plane.v | integrate max 1 | set plane.o", .node = "integrate1", .seed = 0, .then = 100 },
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
        \\clock | set plane.ui.elapsed
        \\lfo sine 4s | range 0.5 1.5 | set plane.render.grade.exposure
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
        \\lfo tri 1s | range 0 10 | set plane.a
        \\plane.v | ease 40ms | set plane.b
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
        try mountFixture(testing.allocator, &fx,
            "lfo " ++ shape ++ " 3s | set plane.a\nclock | wave " ++ shape ++ " 3s | set plane.b", .{});
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
        \\lfo sine 4f | set plane.sine
        \\lfo tri 4f | set plane.tri
        \\lfo saw 4f | set plane.saw
        \\lfo square 4f | set plane.square
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
    try mountFixture(testing.allocator, &fx,
        "plane.v | ramp 100ms | set plane.o", .{.{ "plane.v", @as(f64, 0) }});
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
    try mountFixture(testing.allocator, &fx,
        "plane.v | ramp 100ms | set plane.o", .{.{ "plane.v", @as(f64, 0) }});
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
    try mountFixture(testing.allocator, &fx,
        "plane.v | ease 20ms | set plane.o", .{.{ "plane.v", @as(f64, 0) }});
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
    try mountFixture(testing.allocator, &fx,
        "plane.v | abs | ease 20ms down 400ms | set plane.o", .{.{ "plane.v", @as(f64, 0) }});
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
    try mountFixture(testing.allocator, &fx,
        "plane.v | hold 100ms | set plane.o", .{.{ "plane.v", @as(f64, 1) }});
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
    try mountFixture(testing.allocator, &fx,
        "plane.d | diff | set plane.o", .{.{ "plane.d", @as(f64, 100) }});
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
    try expectParseError("plane.v | integrate | set plane.o", "max");

    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        "plane.v | integrate max 2 | set plane.o", .{.{ "plane.v", @as(f64, 1) }});
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

test "beat 1a: `range` clamps where `lerp` extrapolates" {
    // The one difference between them, and the reason `range` is a word:
    // `lerp` blends two things, `range` is the EXIT from the unit interval
    // and stays inside the interval it was given. Same ruling as `along`.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.t | range 0.5 1.5 | set plane.ranged
        \\plane.t | lerp 0.5 1.5 | set plane.lerped
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
        \\plane.t | shape smooth | set plane.a
        \\plane.t | shape in | set plane.b
        \\plane.t | shape out | set plane.c
        \\plane.t | shape linear | set plane.d
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
    try expectParseError("lfo sqare 4s | set plane.o", "sine");
    try expectParseError("plane.t | shape bouncy | set plane.o", "smooth");
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
    fx.prog = try rill.parse(testing.allocator, &fx.reg, "p",
        "clock | set plane.secs\nframe | set plane.frames", &diag);
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
    try mountFixture(testing.allocator, &fx,
        "plane.target | ease 100ms | set plane.smoothed", .{.{ "plane.target", @as(f64, 1) }});
    defer fx.deinit();
    try testing.expect(fx.prog.findCycle() == null);

    // …and the same idea routed through the plane is still refused, at PARSE,
    // naming both the write and the subscription. A register does not buy a
    // way around §4.4; it makes going around it unnecessary.
    try expectParseError("plane.smoothed | ease 100ms | set plane.smoothed", "cycle");
    try expectParseError("plane.smoothed | ease 100ms | set plane.smoothed", "plane.smoothed");
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
    if (doc.rillbook != 1) {
        std.debug.print("{s}: format version {d}, expected 1\n", .{ doc_name, doc.rillbook });
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
    try testing.expectEqual(@as(usize, 30), rill_cells);
    try testing.expectEqual(@as(usize, 70), total);
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
        \\[0.2, 1, 0.6, 0.05] | set plane.out
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
        \\[plane.a, plane.b] | nth 1 | set plane.out
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
        \\plane.time.band | choose [0.2, 1, 0.6, 0.05] | set plane.render.grade.exposure
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
        \\[10, 20, 30] | nth plane.i | set plane.byList
        \\plane.i | choose [10, 20, 30] | set plane.byIndex
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
        \\plane.hp | window 5s | nth 0 | set plane.out
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
        \\plane.i | choose [10, 20, 30] | set plane.out
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
        \\plane.i | choose [10, 20, 30] | set plane.out
    , .{.{ "plane.i", @as(f64, 1.5) }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "choose", "not a whole number" });
    // Rounding either way would have emitted 20 or 10. Neither happened.
    try testing.expect(fx.rt.readSlot("programs.p.choose1.out.out") == null);
}

test "beat 2a: indexing a non-array names the type word, both sides" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.rec | nth 0 | set plane.out
    , .{.{ "plane.rec", .{ .x = @as(f64, 1), .y = @as(f64, 2) } }});
    defer fx.deinit();

    // Beat 1b's type-word vocabulary, reused verbatim — one vocabulary for
    // every shape complaint the language makes.
    try expectRefusalNames(&.{ "nth", "'in'", "record{x, y}", "not an array" });
}

test "beat 2a: the empty array is a value, and indexing it says so" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\[] | nth 0 | set plane.out
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
        \\[[1, 2], [3, 4]] | nth 1 | nth 0 | set plane.out
        \\[{x: 1, y: 2}, {x: 3, y: 4}] | nth 1 as second
        \\second.x | set plane.fx
    , .{});
    defer fx.deinit();

    try testing.expectEqual(@as(f64, 3), slotNum(&fx, "programs.p.nth2.out.out").?);
    try testing.expectEqual(@as(f64, 3), slotNum(&fx, "programs.p.project1.out.out").?);
}

test "beat 2a: beat 1b's broadcast reaches an array literal unchanged" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 2, 3] | mul 2 | set plane.out
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
    try expectParseError("plane.a | mul [1, 2 | set plane.out", "|");
    try expectParseError("plane.a | mul 2] | set plane.out", "]");
}

test "beat 2a: the time-of-day row is CORRECT, not merely one line" {
    // §4's correctness column (ruled 2026-08-25): a ✓ means expressible; the
    // gate is what says it is right. This is the idioms book's after-cell,
    // driven against the four-line `select` chain it replaced — same answer
    // at every hour, including the band edges where an off-by-one would live.
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\plane.world.hour | div 6 | floor | choose [0.2, 1, 1, 0.4] | set plane.render.grade.exposure
        \\plane.world.hour | < 6 as night
        \\plane.world.hour | < 18 as day
        \\night | select 0.2 1.0 as lit
        \\day | select lit 0.4 | set plane.before.exposure
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
        \\plane.sensors.gate.nearest | match {id: string, distance: number} | set plane.ui.threat
    , .{.{ "plane.sensors.gate.nearest", .{ .id = "raider-3", .distance = "close" } }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "match", "'.distance'", "string", "not number" });
    try testing.expect(fx.rt.readSlot("programs.p.match1.out.out") == null);
}

test "beat 2b: `match` passes what fits, unchanged" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.sensors.gate.nearest | match {id: string, distance: number} | set plane.ui.threat
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
        \\plane.c | match {id: string} | set plane.open_out
    , .{.{ "plane.c", .{ .id = "x", .extra = @as(f64, 1) } }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expect(fx.rt.readSlot("programs.p.match1.out.out") != null);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\plane.c | match {id: string} exact | set plane.exact_out
    , .{.{ "plane.c", .{ .id = "x", .extra = @as(f64, 1) } }});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "match", "extra", "not in the shape", "exact" });
    try testing.expect(fx2.rt.readSlot("programs.p.match1.out.out") == null);
}

test "beat 2b: `exact` closes every record in the shape, not only the outermost" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {pos: {x: number, y: number}} exact | set plane.out
    , .{.{ "plane.c", .{ .pos = .{ .x = @as(f64, 1), .y = @as(f64, 2), .z = @as(f64, 3) } } }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "match", ".pos.z", "not in the shape" });
}

test "beat 2b: shapes nest, and the refusal names the path it took" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {pos: {x: number, y: number, z: number}, kind: string} | set plane.out
    , .{.{ "plane.c", .{ .kind = "raider", .pos = .{ .x = @as(f64, 1), .y = @as(f64, 2), .z = "deep" } } }});
    defer fx.deinit();

    try expectRefusalNames(&.{ "match", "'.pos.z'", "string", "not number" });
}

test "beat 2b: `[number]` checks every element, and names the index" {
    var fx: Fixture = undefined;
    try mountFixture(testing.allocator, &fx,
        \\[1, 2, 3] | match [number] | set plane.good
    , .{});
    defer fx.deinit();
    try testing.expect(fx.rt.readSlot("programs.p.match1.out.out") != null);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\[1, "two", 3] | match [number] | set plane.bad
    , .{});
    defer fx2.deinit();
    try expectRefusalNames(&.{ "match", "'[1]'", "string", "not number" });
}

test "beat 2b: a missing field is named, and `?` makes it optional" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {id: string, distance: number} | set plane.out
    , .{.{ "plane.c", .{ .id = "x" } }});
    defer fx.deinit();
    try expectRefusalNames(&.{ "match", "'.distance'", "missing" });

    // Same value, same shape, one `?` — and it passes. That is the assertion:
    // `?` must be the only difference.
    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\plane.c | match {id: string, distance?: number} | set plane.out
    , .{.{ "plane.c", .{ .id = "x" } }});
    defer fx2.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);
    try testing.expect(fx2.rt.readSlot("programs.p.match1.out.out") != null);
}

test "beat 2b: `any` requires presence and nothing else" {
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {id: any} | set plane.out
    , .{.{ "plane.c", .{ .id = @as(f64, 7) } }});
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 0), Refusal.hits);

    var fx2: Fixture = undefined;
    try mountWatched(testing.allocator, &fx2,
        \\plane.c | match {id: any} | set plane.out
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
        \\plane.c | expect {id: string} | set plane.out
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
        \\plane.c | expect {id: string, distance: number} | set plane.out
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
        \\plane.c | expect {id: string} | set plane.out
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

test "beat 2b: `expect` on a path with nothing at mount refuses, and says to use `match`" {
    // The case the doc cares about most: what cannot be proven at mount is not
    // quietly deferred. The refusal names the other word, because a refusal
    // that only says no is half an error message.
    var reg = try hostRegistry(testing.allocator);
    defer reg.deinit();
    var mock = rill.MockPlane.init(testing.allocator);
    defer mock.deinit();
    var diag = rill.Diag{};
    var prog = try rill.parse(testing.allocator, &reg, "p",
        \\plane.absent | expect {id: string} | set plane.out
    , &diag);
    defer prog.deinit();

    Refusal.reset();
    const result = rill.Runtime.mount(testing.allocator, &prog, mock.asPlane(), .{ .error_fn = Refusal.on });
    try testing.expectError(error.Refused, result);
    try expectRefusalNames(&.{ "expect", "nothing here at mount", "match" });
}

test "beat 2b: a `match` refusal after mount does NOT bring the program down" {
    // The mirror of the gate above, and the reason `fails_mount` is a per-op
    // declaration rather than a runtime mode.
    var fx: Fixture = undefined;
    try mountWatched(testing.allocator, &fx,
        \\plane.c | match {id: string} | set plane.out
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
        \\plane.c | match {id: string, pos: {x: number}} exact | set plane.out
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
