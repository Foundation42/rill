//! serialize — the whole program is one struple.
//!
//! Nodes, wires, slot types, current values, per-node state and counters —
//! one canonical map element. Rig save, Project cut, diff, and provenance
//! all work on programs with zero new code, because a mounted game rule and
//! a mounted light rig are the same kind of object: a struple dump.
//!
//! Deterministic by construction: arrays are in id order, maps are canonical
//! (struple sorts keys), and nothing time-based is included (per-tick µs
//! lives on the Runtime, not in the dump; eval counters are deterministic
//! and are included). G8: mount → dump → unmount → mount-from-dump → dump is
//! byte-identical.
//!
//! Subscriptions and write targets are *derived* data — rebuilt from slot
//! sources and effect statics at load — so the dump cannot disagree with
//! itself.
//!
//! Load is two-phase, symmetric with the text path:
//!   text:  parse()        → Program;  Runtime.mount(&prog, plane)
//!   bytes: loadProgram()  → Program;  Runtime.restore(&prog, plane)
//!          + restoreState(&rt, bytes) — restore never ticks; the dump is a
//!          live snapshot, not a birth certificate.

const std = @import("std");
const struple = @import("struple");
const types = @import("types.zig");
const registry = @import("registry.zig");
const graph = @import("graph.zig");
const eval = @import("eval.zig");

pub const LoadError = error{ Malformed, UnknownOp, UnknownType, UnsupportedFormat } || std.mem.Allocator.Error;

/// v2 (2026-08-23): added "now" (last fed time pair) and "wheel" (armed
/// timer deadlines, absolute) for the temporal operators. v1 dumps load with
/// the defined default — zero epoch, nothing armed — which is exactly what a
/// pre-temporal program meant. Anything newer is refused loud.
const fmt_version: i64 = 2;

// ---------------------------------------------------------------------------
// Dump
// ---------------------------------------------------------------------------

/// Serialize a mounted runtime (structure + live state) into one struple
/// element. Caller owns the returned bytes.
pub fn dump(rt: *const eval.Runtime, gpa: std.mem.Allocator) ![]u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const prog = rt.prog;

    var entries = std.ArrayListUnmanaged([2][]const u8).empty;

    try putEntry(&entries, a, "fmt", try packInt(a, fmt_version));
    try putEntry(&entries, a, "name", try packStr(a, prog.name));

    // nodes
    {
        var stream = struple.Packer.init(a);
        for (prog.nodes.items) |*n| {
            var ne = std.ArrayListUnmanaged([2][]const u8).empty;
            try putEntry(&ne, a, "op", try packStr(a, prog.reg.get(n.op).name));
            try putEntry(&ne, a, "name", try packStr(a, n.name));
            try putEntry(&ne, a, "in", try packIdArray(a, n.inputs));
            try putEntry(&ne, a, "out", try packIdArray(a, n.outputs));
            var st = struple.Packer.init(a);
            for (n.statics) |sv| {
                var one = struple.Packer.init(a);
                switch (sv) {
                    .path => |v| {
                        try one.appendInt(0);
                        try one.appendString(v);
                    },
                    .word => |v| {
                        try one.appendInt(1);
                        try one.appendString(v);
                    },
                    .literal => |v| {
                        try one.appendInt(2);
                        try one.appendBytes(v);
                    },
                    .channel => |v| {
                        try one.appendInt(3);
                        try one.appendString(v);
                    },
                    .subject => |v| {
                        try one.appendInt(4);
                        try one.appendString(v);
                    },
                    .condition => |v| {
                        try one.appendInt(5);
                        try one.appendString(v);
                    },
                }
                try st.appendArray(one.bytes());
            }
            var st_arr = struple.Packer.init(a);
            try st_arr.appendArray(st.bytes());
            try putEntry(&ne, a, "statics", st_arr.bytes());
            var nm = struple.Packer.init(a);
            try nm.appendMap(ne.items);
            try stream.appendRaw(nm.bytes());
        }
        try putEntry(&entries, a, "nodes", try packArrayOf(a, stream.bytes()));
    }

    // slots
    {
        var stream = struple.Packer.init(a);
        for (prog.slots.items) |*s| {
            var se = std.ArrayListUnmanaged([2][]const u8).empty;
            try putEntry(&se, a, "node", try packInt(a, s.node));
            try putEntry(&se, a, "dir", try packInt(a, @intFromEnum(s.dir)));
            try putEntry(&se, a, "port", try packInt(a, s.port));
            try putEntry(&se, a, "pname", try packStr(a, s.name));
            try putEntry(&se, a, "ty", try packStr(a, prog.reg.types.name(s.ty)));
            try putEntry(&se, a, "kind", try packInt(a, @intFromEnum(s.kind)));
            try putEntry(&se, a, "path", try packStr(a, s.path));
            var src = struple.Packer.init(a);
            switch (s.source) {
                .none => try src.appendInt(0),
                .wire => |w| {
                    try src.appendInt(1);
                    try src.appendInt(w);
                },
                .literal => |b| {
                    try src.appendInt(2);
                    try src.appendBytes(b);
                },
                .plane => |p| {
                    try src.appendInt(3);
                    try src.appendString(p);
                },
                .port => unreachable, // never survives flattening
            }
            try putEntry(&se, a, "src", try packArrayOf(a, src.bytes()));
            try putEntry(&se, a, "has", try packBool(a, rt.has[s.id]));
            try putEntry(&se, a, "val", try packBytes(a, if (rt.has[s.id]) rt.values[s.id].items else ""));
            var sm = struple.Packer.init(a);
            try sm.appendMap(se.items);
            try stream.appendRaw(sm.bytes());
        }
        try putEntry(&entries, a, "slots", try packArrayOf(a, stream.bytes()));
    }

    // as-names
    {
        var ne = std.ArrayListUnmanaged([2][]const u8).empty;
        var it = prog.names.iterator();
        while (it.next()) |e| {
            try putEntry(&ne, a, e.key_ptr.*, try packInt(a, e.value_ptr.*));
        }
        var nm = struple.Packer.init(a);
        try nm.appendMap(ne.items);
        try putEntry(&entries, a, "names", nm.bytes());
    }

    // per-node state and counters
    {
        var stream = struple.Packer.init(a);
        for (rt.node_state) |*buf| try stream.appendBytes(buf.items);
        try putEntry(&entries, a, "state", try packArrayOf(a, stream.bytes()));
    }
    {
        var stream = struple.Packer.init(a);
        for (rt.eval_count) |c| try stream.appendUint(c);
        try putEntry(&entries, a, "counts", try packArrayOf(a, stream.bytes()));
    }
    {
        var stream = struple.Packer.init(a);
        for (rt.error_count) |c| try stream.appendUint(c);
        try putEntry(&entries, a, "errs", try packArrayOf(a, stream.bytes()));
    }
    try putEntry(&entries, a, "tick", try packInt(a, @intCast(rt.tick_index)));

    // fed time + armed wheel (fmt v2). Both are fed data: deadlines are
    // absolute lane values, so a program restored mid-window stays exactly
    // as far from firing as it was. Lane lists dump in wheel order (sorted
    // by deadline, FIFO on ties) and restore through the same insert.
    {
        var stream = struple.Packer.init(a);
        try stream.appendUint(rt.now.frame);
        try stream.appendUint(rt.now.time_ns);
        try putEntry(&entries, a, "now", try packArrayOf(a, stream.bytes()));
    }
    {
        var stream = struple.Packer.init(a);
        for (rt.wheel_ns.items) |e| {
            try stream.appendUint(0);
            try stream.appendUint(e.deadline);
            try stream.appendUint(e.node);
        }
        for (rt.wheel_frame.items) |e| {
            try stream.appendUint(1);
            try stream.appendUint(e.deadline);
            try stream.appendUint(e.node);
        }
        try putEntry(&entries, a, "wheel", try packArrayOf(a, stream.bytes()));
    }

    var top = struple.Packer.init(gpa);
    defer top.deinit();
    try top.appendMap(entries.items);
    return gpa.dupe(u8, top.bytes());
}

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

/// Rebuild the Program (structure only) from a dump. Operators are resolved
/// by name in `reg` — the same registry contents must be present (the host
/// seeds its registry before loading rigs, same as before parsing them).
pub fn loadProgram(gpa: std.mem.Allocator, reg: *registry.Registry, bytes: []const u8) LoadError!graph.Program {
    var scratch_impl = std.heap.ArenaAllocator.init(gpa);
    defer scratch_impl.deinit();
    const scratch = scratch_impl.allocator();

    const top = try mapOf(scratch, bytes);
    const fmt = try asInt((try mapGet(top, scratch, "fmt")) orelse return error.Malformed);
    if (fmt != 1 and fmt != 2) return error.UnsupportedFormat;
    const name_enc = (try mapGet(top, scratch, "name")) orelse return error.Malformed;

    var prog = try graph.Program.init(gpa, reg, try asStr(scratch, name_enc));
    errdefer prog.deinit();
    const a = prog.a();

    // nodes
    const nodes_inner = try arrayItems(scratch, (try mapGet(top, scratch, "nodes")) orelse return error.Malformed);
    var nr = struple.reader(nodes_inner);
    var node_id: graph.NodeId = 0;
    while (nr.nextView() catch return error.Malformed) |ne| : (node_id += 1) {
        const nm = try mapOf(scratch, ne);
        const op_name = try asStr(scratch, (try mapGet(nm, scratch, "op")) orelse return error.Malformed);
        const op_id = reg.find(op_name) orelse return error.UnknownOp;
        const statics_inner = try arrayItems(scratch, (try mapGet(nm, scratch, "statics")) orelse return error.Malformed);
        var statics = std.ArrayListUnmanaged(registry.StaticVal).empty;
        var sr = struple.reader(statics_inner);
        while (sr.nextView() catch return error.Malformed) |se| {
            const pair = try arrayItems(scratch, se);
            var pr = struple.reader(pair);
            const kind = try asInt(pr.nextView() catch null orelse return error.Malformed);
            const payload = pr.nextView() catch null orelse return error.Malformed;
            try statics.append(a, switch (kind) {
                0 => .{ .path = try asStrIn(a, payload) },
                1 => .{ .word = try asStrIn(a, payload) },
                2 => .{ .literal = try asBytesIn(a, payload) },
                3 => .{ .channel = try asStrIn(a, payload) },
                4 => .{ .subject = try asStrIn(a, payload) },
                5 => .{ .condition = try asStrIn(a, payload) },
                else => return error.Malformed,
            });
        }
        try prog.nodes.append(a, .{
            .id = node_id,
            .op = op_id,
            .name = try asStrIn(a, (try mapGet(nm, scratch, "name")) orelse return error.Malformed),
            .inputs = try loadIdArray(a, scratch, (try mapGet(nm, scratch, "in")) orelse return error.Malformed),
            .outputs = try loadIdArray(a, scratch, (try mapGet(nm, scratch, "out")) orelse return error.Malformed),
            .statics = statics.items,
        });
    }

    // slots
    const slots_inner = try arrayItems(scratch, (try mapGet(top, scratch, "slots")) orelse return error.Malformed);
    var slr = struple.reader(slots_inner);
    var slot_id: graph.SlotId = 0;
    while (slr.nextView() catch return error.Malformed) |se| : (slot_id += 1) {
        const sm = try mapOf(scratch, se);
        const ty_name = try asStr(scratch, (try mapGet(sm, scratch, "ty")) orelse return error.Malformed);
        const src_pair = try arrayItems(scratch, (try mapGet(sm, scratch, "src")) orelse return error.Malformed);
        var pr = struple.reader(src_pair);
        const src_tag = try asInt(pr.nextView() catch null orelse return error.Malformed);
        const source: graph.Source = switch (src_tag) {
            0 => .none,
            1 => .{ .wire = @intCast(try asInt(pr.nextView() catch null orelse return error.Malformed)) },
            2 => .{ .literal = try asBytesIn(a, pr.nextView() catch null orelse return error.Malformed) },
            3 => .{ .plane = try asStrIn(a, pr.nextView() catch null orelse return error.Malformed) },
            else => return error.Malformed,
        };
        const sid: graph.SlotId = slot_id;
        try prog.slots.append(a, .{
            .id = sid,
            .node = @intCast(try asInt((try mapGet(sm, scratch, "node")) orelse return error.Malformed)),
            .dir = @enumFromInt(try asInt((try mapGet(sm, scratch, "dir")) orelse return error.Malformed)),
            .port = @intCast(try asInt((try mapGet(sm, scratch, "port")) orelse return error.Malformed)),
            .name = try asStrIn(a, (try mapGet(sm, scratch, "pname")) orelse return error.Malformed),
            .ty = reg.types.intern(ty_name) catch return error.OutOfMemory,
            .kind = @enumFromInt(try asInt((try mapGet(sm, scratch, "kind")) orelse return error.Malformed)),
            .source = source,
            .path = try asStrIn(a, (try mapGet(sm, scratch, "path")) orelse return error.Malformed),
        });
        if (source == .plane) {
            const sub = try prog.subFor(source.plane);
            try sub.targets.append(a, sid);
        }
    }

    // as-names
    if (try mapGet(top, scratch, "names")) |names_enc| {
        const inner = try innerOf(scratch, names_enc);
        var it = struple.MapView.init(inner).iterator();
        while (it.next() catch return error.Malformed) |e| {
            try prog.names.put(a, try asStrIn(a, e.key), @intCast(try asInt(e.value)));
        }
    }

    // derived: write targets (for the cycle check on future edits) — the
    // same composition the parser used, so the dump cannot disagree.
    for (prog.nodes.items) |*n| {
        if (!reg.get(n.op).class.writes()) continue;
        try prog.registerWrites(n.statics, n.id);
    }

    try prog.finalize();
    return prog;
}

/// Restore live state (slot values, node state, counters, tick index) into a
/// `Runtime.restore`d runtime. Never ticks.
pub fn restoreState(rt: *eval.Runtime, bytes: []const u8) LoadError!void {
    var scratch_impl = std.heap.ArenaAllocator.init(rt.gpa);
    defer scratch_impl.deinit();
    const scratch = scratch_impl.allocator();

    const top = try mapOf(scratch, bytes);

    const slots_inner = try arrayItems(scratch, (try mapGet(top, scratch, "slots")) orelse return error.Malformed);
    var slr = struple.reader(slots_inner);
    var sid: graph.SlotId = 0;
    while (slr.nextView() catch return error.Malformed) |se| : (sid += 1) {
        if (sid >= rt.values.len) return error.Malformed;
        const sm = try mapOf(scratch, se);
        const has = try asBoolEnc((try mapGet(sm, scratch, "has")) orelse return error.Malformed);
        if (!has) continue;
        const val = try asBytes(scratch, (try mapGet(sm, scratch, "val")) orelse return error.Malformed);
        rt.values[sid].clearRetainingCapacity();
        try rt.values[sid].appendSlice(rt.gpa, val);
        rt.has[sid] = true;
    }

    const state_inner = try arrayItems(scratch, (try mapGet(top, scratch, "state")) orelse return error.Malformed);
    var str = struple.reader(state_inner);
    var nid: usize = 0;
    while (str.nextView() catch return error.Malformed) |se| : (nid += 1) {
        if (nid >= rt.node_state.len) return error.Malformed;
        const b = try asBytes(scratch, se);
        rt.node_state[nid].clearRetainingCapacity();
        try rt.node_state[nid].appendSlice(rt.gpa, b);
    }

    try loadCounts(scratch, top, "counts", rt.eval_count);
    try loadCounts(scratch, top, "errs", rt.error_count);

    const tick_enc = (try mapGet(top, scratch, "tick")) orelse return error.Malformed;
    rt.tick_index = @intCast(try asInt(tick_enc));

    // Fed time + wheel (absent in v1 dumps: zero epoch, nothing armed — the
    // defined default; no temporal op could have been mounted under v1).
    if (try mapGet(top, scratch, "now")) |now_enc| {
        const inner = try arrayItems(scratch, now_enc);
        var r = struple.reader(inner);
        const frame = try asInt(r.nextView() catch null orelse return error.Malformed);
        const t_ns = try asInt(r.nextView() catch null orelse return error.Malformed);
        rt.now = .{ .frame = @intCast(frame), .time_ns = @intCast(t_ns) };
    }
    if (try mapGet(top, scratch, "wheel")) |wheel_enc| {
        const inner = try arrayItems(scratch, wheel_enc);
        var r = struple.reader(inner);
        while (r.nextView() catch return error.Malformed) |lane_enc| {
            const lane = try asInt(lane_enc);
            const deadline: u64 = @intCast(try asInt(r.nextView() catch null orelse return error.Malformed));
            const node = try asInt(r.nextView() catch null orelse return error.Malformed);
            if (node < 0 or node >= rt.node_state.len) return error.Malformed;
            const dl: registry.Deadline = switch (lane) {
                0 => .{ .ns = deadline },
                1 => .{ .frame = deadline },
                else => return error.Malformed,
            };
            try rt.arm(dl, @intCast(node));
        }
    }
}

fn loadCounts(scratch: std.mem.Allocator, top: struple.MapView, key: []const u8, out: []u64) LoadError!void {
    const inner = try arrayItems(scratch, (try mapGet(top, scratch, key)) orelse return error.Malformed);
    var r = struple.reader(inner);
    var i: usize = 0;
    while (r.nextView() catch return error.Malformed) |e| : (i += 1) {
        if (i >= out.len) return error.Malformed;
        out[i] = @intCast(try asInt(e));
    }
}

// ---------------------------------------------------------------------------
// struple helpers
// ---------------------------------------------------------------------------

fn putEntry(entries: *std.ArrayListUnmanaged([2][]const u8), a: std.mem.Allocator, key: []const u8, value_enc: []const u8) !void {
    var kp = struple.Packer.init(a);
    try kp.appendString(key);
    try entries.append(a, .{ kp.bytes(), value_enc });
}

fn packInt(a: std.mem.Allocator, v: i64) ![]const u8 {
    var pk = struple.Packer.init(a);
    try pk.appendInt(v);
    return pk.bytes();
}

fn packStr(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var pk = struple.Packer.init(a);
    try pk.appendString(s);
    return pk.bytes();
}

fn packBool(a: std.mem.Allocator, b: bool) ![]const u8 {
    var pk = struple.Packer.init(a);
    try pk.appendBool(b);
    return pk.bytes();
}

fn packBytes(a: std.mem.Allocator, b: []const u8) ![]const u8 {
    var pk = struple.Packer.init(a);
    try pk.appendBytes(b);
    return pk.bytes();
}

fn packIdArray(a: std.mem.Allocator, ids: []const u32) ![]const u8 {
    var stream = struple.Packer.init(a);
    for (ids) |id| try stream.appendUint(id);
    return packArrayOf(a, stream.bytes());
}

fn packArrayOf(a: std.mem.Allocator, child_stream: []const u8) ![]const u8 {
    var pk = struple.Packer.init(a);
    try pk.appendArray(child_stream);
    return pk.bytes();
}

fn innerOf(a: std.mem.Allocator, enc: []const u8) LoadError![]const u8 {
    const v = struple.view(enc);
    return (v.containedItems(a) catch return error.Malformed) orelse return error.Malformed;
}

fn mapOf(a: std.mem.Allocator, enc: []const u8) LoadError!struple.MapView {
    return struple.MapView.init(try innerOf(a, enc));
}

fn mapGet(m: struple.MapView, a: std.mem.Allocator, key: []const u8) LoadError!?[]const u8 {
    var kp = struple.Packer.init(a);
    try kp.appendString(key);
    return m.get(kp.bytes()) catch error.Malformed;
}

fn arrayItems(a: std.mem.Allocator, enc: []const u8) LoadError![]const u8 {
    return innerOf(a, enc);
}

fn elemOf(enc: []const u8) LoadError!struple.Element {
    var r = struple.reader(enc);
    return (r.next() catch return error.Malformed) orelse return error.Malformed;
}

fn asInt(enc: ?[]const u8) LoadError!i64 {
    const e = try elemOf(enc orelse return error.Malformed);
    return switch (e) {
        .int => |v| @intCast(v),
        else => error.Malformed,
    };
}

fn asBoolEnc(enc: []const u8) LoadError!bool {
    const e = try elemOf(enc);
    return switch (e) {
        .boolean => |b| b,
        else => error.Malformed,
    };
}

/// Decode a string element into scratch memory (unescaping if needed).
fn asStr(a: std.mem.Allocator, enc: []const u8) LoadError![]const u8 {
    const e = try elemOf(enc);
    return switch (e) {
        .string => |framed| if (struple.hasEscapes(framed))
            struple.unescapeAlloc(a, framed) catch return error.OutOfMemory
        else
            framed,
        else => error.Malformed,
    };
}

fn asStrIn(a: std.mem.Allocator, enc: []const u8) LoadError![]const u8 {
    return a.dupe(u8, try asStr(a, enc)) catch error.OutOfMemory;
}

fn asBytes(a: std.mem.Allocator, enc: []const u8) LoadError![]const u8 {
    const e = try elemOf(enc);
    return switch (e) {
        .bytes => |framed| if (struple.hasEscapes(framed))
            struple.unescapeAlloc(a, framed) catch return error.OutOfMemory
        else
            framed,
        else => error.Malformed,
    };
}

fn asBytesIn(a: std.mem.Allocator, enc: []const u8) LoadError![]const u8 {
    return a.dupe(u8, try asBytes(a, enc)) catch error.OutOfMemory;
}

fn loadIdArray(a: std.mem.Allocator, scratch: std.mem.Allocator, enc: []const u8) LoadError![]u32 {
    const inner = try arrayItems(scratch, enc);
    var list = std.ArrayListUnmanaged(u32).empty;
    var r = struple.reader(inner);
    while (r.nextView() catch return error.Malformed) |e| {
        try list.append(a, @intCast(try asInt(e)));
    }
    return list.items;
}
