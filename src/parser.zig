//! parser — text → flat graph.
//!
//! The pipe is the 90% case and parses exactly as the console does today:
//! `cube 2 | bevel 0.1 | rot 45`. Syntax complexity is paid only at the
//! joints: `as` names an edge (fan-out), a bare name in argument position
//! pulls a stream in (fan-in), `{…}` builds a live record, and any `plane.…`
//! path in any argument position is a subscription — there is no special
//! subscribe form.
//!
//! Structural consequences the rest of the library leans on:
//!
//! - Local names are single-assignment and must be defined before use, so
//!   **parse order is topological order**. The evaluator never sorts.
//! - `def` bodies are flattened at parse into the same arena with an
//!   instance-name prefix; the graph does not know defs exist.
//! - defs close over nothing: a `plane.…` path (read or write) inside a def
//!   body is a parse error — pass streams in through ports. This keeps defs
//!   reusable across Projects and dirty-propagation tractable.
//! - A parenthesized opcall in argument position — `where (= 0)`,
//!   `partition (< 20) hp` — is a predicate *section*: it becomes an ordinary
//!   node whose primary input mirrors the consumer's primary input, and its
//!   output binds to the consumer's first boolean port. No closures involved.
//! - Operator lookup tries the two-word form first (`boolean subtract`), so a
//!   host registry seeded from (verb, subop) command pairs maps one row to
//!   one operator.
//!
//! There is no `if` statement and no exec wire, by design (§4.3). Selection
//! and gating are ordinary operators over data.

const std = @import("std");
const struple = @import("struple");
const types = @import("types.zig");
const registry = @import("registry.zig");
const graph = @import("graph.zig");

const Program = graph.Program;
const Source = graph.Source;
const SlotId = graph.SlotId;
const NodeId = graph.NodeId;

pub const ParseError = error{Parse} || std.mem.Allocator.Error;

/// Structured diagnostic, filled on error.Parse. The message buffer is owned
/// by the caller so it survives the failed Program's teardown.
pub const Diag = struct {
    line: u32 = 0,
    col: u32 = 0,
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn msg(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

const TokKind = enum {
    name, // identifier or keyword
    number,
    string, // raw span between quotes (escapes not yet applied)
    sym, // = != < <= > >=
    pipe,
    lbrace,
    rbrace,
    lparen,
    rparen,
    colon,
    comma,
    dot,
    newline,
    eof,
};

const Token = struct {
    kind: TokKind,
    text: []const u8,
    line: u32,
    col: u32,
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn tokenize(a: std.mem.Allocator, src: []const u8, diag: *Diag) ParseError![]Token {
    var toks = std.ArrayListUnmanaged(Token).empty;
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        const tl = line;
        const tc = col;
        if (c == '\n') {
            try toks.append(a, .{ .kind = .newline, .text = src[i .. i + 1], .line = tl, .col = tc });
            line += 1;
            col = 1;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            col += 1;
            continue;
        }
        if (c == '#') { // comment to end of line
            while (i < src.len and src[i] != '\n') : (i += 1) col += 1;
            continue;
        }
        if (isNameStart(c)) {
            const start = i;
            while (i < src.len and isNameChar(src[i])) : (i += 1) col += 1;
            try toks.append(a, .{ .kind = .name, .text = src[start..i], .line = tl, .col = tc });
            continue;
        }
        if (std.ascii.isDigit(c) or (c == '-' and i + 1 < src.len and std.ascii.isDigit(src[i + 1]))) {
            const start = i;
            if (c == '-') {
                i += 1;
                col += 1;
            }
            while (i < src.len and (std.ascii.isDigit(src[i]) or src[i] == '.' or src[i] == 'e' or src[i] == 'E' or
                ((src[i] == '-' or src[i] == '+') and (src[i - 1] == 'e' or src[i - 1] == 'E')))) : (i += 1)
            {
                col += 1;
            }
            // A trailing '.' belongs to the next token (record sugar never
            // follows a number, but be conservative).
            var end = i;
            if (src[end - 1] == '.') {
                end -= 1;
                i -= 1;
                col -= 1;
            }
            try toks.append(a, .{ .kind = .number, .text = src[start..end], .line = tl, .col = tc });
            continue;
        }
        if (c == '"') {
            i += 1;
            col += 1;
            const start = i;
            while (i < src.len and src[i] != '"') {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1;
                    col += 1;
                }
                if (src[i] == '\n') {
                    diag.* = .{ .line = tl, .col = tc };
                    diag.len = (std.fmt.bufPrint(&diag.buf, "unterminated string", .{}) catch "").len;
                    return error.Parse;
                }
                i += 1;
                col += 1;
            }
            if (i >= src.len) {
                diag.* = .{ .line = tl, .col = tc };
                diag.len = (std.fmt.bufPrint(&diag.buf, "unterminated string", .{}) catch "").len;
                return error.Parse;
            }
            try toks.append(a, .{ .kind = .string, .text = src[start..i], .line = tl, .col = tc });
            i += 1;
            col += 1;
            continue;
        }
        const two = if (i + 1 < src.len) src[i .. i + 2] else src[i .. i + 1];
        if (std.mem.eql(u8, two, "!=") or std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, ">=")) {
            try toks.append(a, .{ .kind = .sym, .text = two, .line = tl, .col = tc });
            i += 2;
            col += 2;
            continue;
        }
        const kind: TokKind = switch (c) {
            '|' => .pipe,
            '{' => .lbrace,
            '}' => .rbrace,
            '(' => .lparen,
            ')' => .rparen,
            ':' => .colon,
            ',' => .comma,
            '.' => .dot,
            '=', '<', '>' => .sym,
            else => {
                diag.* = .{ .line = tl, .col = tc };
                diag.len = (std.fmt.bufPrint(&diag.buf, "unexpected character '{c}'", .{c}) catch "").len;
                return error.Parse;
            },
        };
        try toks.append(a, .{ .kind = kind, .text = src[i .. i + 1], .line = tl, .col = tc });
        i += 1;
        col += 1;
    }
    try toks.append(a, .{ .kind = .eof, .text = "", .line = line, .col = col });
    return toks.items;
}

// ---------------------------------------------------------------------------
// Def templates
// ---------------------------------------------------------------------------

const PortDecl = struct {
    name: []const u8,
    ty: types.TypeId,
};

const TemplateOut = struct {
    name: []const u8,
    source: Source,
};

/// A parsed def body: a mini-graph whose input-slot sources may be `.port`.
/// Instanced by splicing into the consuming graph with a name prefix.
const Template = struct {
    name: []const u8,
    ports: []PortDecl,
    nodes: std.ArrayListUnmanaged(graph.Node) = .empty,
    slots: std.ArrayListUnmanaged(graph.Slot) = .empty,
    outputs: []TemplateOut = &.{},
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Where statements land: the program graph, or a def template under
/// construction. Templates ban plane paths and remember `.port` name bindings.
const Target = struct {
    nodes: *std.ArrayListUnmanaged(graph.Node),
    slots: *std.ArrayListUnmanaged(graph.Slot),
    names: std.StringArrayHashMapUnmanaged(Source) = .empty,
    template: ?*Template = null, // null = the program itself
};

const ArgKind = enum { literal, stream, plane_path, section, word };

const Arg = struct {
    kind: ArgKind,
    source: Source = .none,
    ty: types.TypeId = types.Tag.any,
    text: []const u8 = "", // path text / bare word
    kw: []const u8 = "", // non-empty: bind to this port by name
    section_node: NodeId = 0, // valid when kind == .section
    tok: Token,
};

const OpResult = struct {
    node: ?NodeId = null,
    /// One source per output port (wires), or the bare ref for non-opcall exprs.
    outputs: []const Source = &.{},
    out_names: []const []const u8 = &.{},
};

pub fn parse(
    gpa: std.mem.Allocator,
    reg: *registry.Registry,
    program_name: []const u8,
    source: []const u8,
    diag: *Diag,
) ParseError!Program {
    var prog = try Program.init(gpa, reg, program_name);
    errdefer prog.deinit();

    var p = Parser{
        .prog = &prog,
        .reg = reg,
        .diag = diag,
        .toks = try tokenize(prog.a(), source, diag),
    };
    p.program_target = .{ .nodes = &prog.nodes, .slots = &prog.slots };
    try p.parseProgram();

    // Publish `as` names on the program (sources that are wires only — the
    // console watches slots, and literal/plane aliases have no slot).
    var it = p.program_target.names.iterator();
    while (it.next()) |e| {
        switch (e.value_ptr.*) {
            .wire => |s| try prog.names.put(prog.a(), e.key_ptr.*, s),
            else => {},
        }
    }

    try prog.finalize();
    return prog;
}

const Parser = struct {
    prog: *Program,
    reg: *registry.Registry,
    diag: *Diag,
    toks: []Token,
    pos: usize = 0,
    program_target: Target = undefined,
    defs: std.StringArrayHashMapUnmanaged(*Template) = .empty,
    op_counters: std.StringArrayHashMapUnmanaged(u32) = .empty,

    fn a(self: *Parser) std.mem.Allocator {
        return self.prog.a();
    }

    fn peek(self: *Parser) Token {
        return self.toks[self.pos];
    }

    fn next(self: *Parser) Token {
        const t = self.toks[self.pos];
        if (t.kind != .eof) self.pos += 1;
        return t;
    }

    fn fail(self: *Parser, tok: Token, comptime fmt: []const u8, args: anytype) ParseError {
        self.diag.line = tok.line;
        self.diag.col = tok.col;
        const written = std.fmt.bufPrint(&self.diag.buf, fmt, args) catch &self.diag.buf;
        self.diag.len = written.len;
        return error.Parse;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peek().kind == .newline) _ = self.next();
    }

    fn autoName(self: *Parser, op_name: []const u8) ![]const u8 {
        const gop = try self.op_counters.getOrPut(self.a(), op_name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        // Symbolic names ("<", "=") become words so slot paths stay path-safe.
        const stem = symWord(op_name);
        return std.fmt.allocPrint(self.a(), "{s}{d}", .{ stem, gop.value_ptr.* });
    }

    fn symWord(op_name: []const u8) []const u8 {
        const map = [_]struct { []const u8, []const u8 }{
            .{ "=", "eq" },   .{ "!=", "ne" }, .{ "<", "lt" },
            .{ "<=", "le" },  .{ ">", "gt" },  .{ ">=", "ge" },
        };
        for (map) |m| {
            if (std.mem.eql(u8, op_name, m[0])) return m[1];
        }
        return op_name;
    }

    // -- program / statements ----------------------------------------------

    fn parseProgram(self: *Parser) ParseError!void {
        while (true) {
            self.skipNewlines();
            const t = self.peek();
            if (t.kind == .eof) break;
            if (t.kind == .name and std.mem.eql(u8, t.text, "def")) {
                try self.parseDef();
            } else {
                _ = try self.parseStatement(&self.program_target);
            }
        }
        if (self.prog.findCycle()) |cyc| {
            const n = self.prog.node(cyc.write.node);
            return self.fail(self.toks[self.toks.len - 1], "cycle — node {s} writes {s}, which the program also subscribes to (via {s})", .{ n.name, cyc.write.path, cyc.sub_path });
        }
    }

    fn parseDef(self: *Parser) ParseError!void {
        const def_tok = self.next(); // "def"
        const name_tok = self.next();
        if (name_tok.kind != .name) return self.fail(name_tok, "expected operator name after 'def'", .{});
        if (self.defs.contains(name_tok.text) or self.reg.find(name_tok.text) != null) {
            return self.fail(name_tok, "'{s}' is already defined", .{name_tok.text});
        }

        if (self.next().kind != .lparen) return self.fail(self.toks[self.pos - 1], "expected '(' after def name", .{});
        var ports = std.ArrayListUnmanaged(PortDecl).empty;
        while (true) {
            const pt = self.next();
            if (pt.kind == .rparen) break;
            if (pt.kind != .name) return self.fail(pt, "expected port name in def signature", .{});
            var ty: types.TypeId = types.Tag.any;
            if (self.peek().kind == .colon) {
                _ = self.next();
                const tt = self.next();
                if (tt.kind != .name) return self.fail(tt, "expected type name after ':'", .{});
                ty = self.reg.types.intern(tt.text) catch return error.OutOfMemory;
            }
            try ports.append(self.a(), .{ .name = try self.a().dupe(u8, pt.text), .ty = ty });
            const sep = self.peek();
            if (sep.kind == .comma) {
                _ = self.next();
            } else if (sep.kind != .rparen) {
                return self.fail(sep, "expected ',' or ')' in def signature", .{});
            }
        }
        const eq = self.next();
        if (eq.kind != .sym or !std.mem.eql(u8, eq.text, "=")) return self.fail(eq, "expected '=' after def signature", .{});

        const tmpl = try self.a().create(Template);
        tmpl.* = .{ .name = try self.a().dupe(u8, name_tok.text), .ports = ports.items };

        var target = Target{ .nodes = &tmpl.nodes, .slots = &tmpl.slots, .template = tmpl };
        for (tmpl.ports, 0..) |pd, i| {
            try target.names.put(self.a(), pd.name, .{ .port = @intCast(i) });
        }

        var last: OpResult = .{};
        var last_names: []const []const u8 = &.{};
        if (self.peek().kind != .newline and self.peek().kind != .eof) {
            // single-line body: def double(x) = x | mul 2
            last = try self.parseStatement(&target);
            last_names = last.out_names;
        } else {
            var any_stmt = false;
            while (true) {
                self.skipNewlines();
                const t = self.peek();
                if (t.kind == .eof) break;
                if (t.col <= def_tok.col) break; // dedent ends the body
                last = try self.parseStatement(&target);
                last_names = last.out_names;
                any_stmt = true;
            }
            if (!any_stmt) return self.fail(def_tok, "def '{s}' has an empty body", .{name_tok.text});
        }

        // The last statement's value is the primary output; a final `as`
        // names multi-output defs.
        var outs = std.ArrayListUnmanaged(TemplateOut).empty;
        if (last_names.len > 0) {
            for (last_names, 0..) |n, i| {
                try outs.append(self.a(), .{ .name = n, .source = last.outputs[i] });
            }
        } else if (last.outputs.len > 0) {
            try outs.append(self.a(), .{ .name = "out", .source = last.outputs[0] });
        } else {
            return self.fail(def_tok, "def '{s}' produces no output (its last statement has no value)", .{name_tok.text});
        }
        tmpl.outputs = outs.items;

        try self.defs.put(self.a(), tmpl.name, tmpl);
    }

    /// chain := expr ( "|" opcall )* ( "as" namelist )?
    fn parseStatement(self: *Parser, target: *Target) ParseError!OpResult {
        var current = try self.parseExpr(target);

        while (self.peek().kind == .pipe) {
            _ = self.next();
            self.skipNewlines(); // a chain may wrap after a '|'
            const op_tok = self.next();
            if (op_tok.kind != .name and op_tok.kind != .sym) {
                return self.fail(op_tok, "expected operator after '|'", .{});
            }
            if (current.outputs.len == 0) return self.fail(op_tok, "nothing to pipe — upstream operator has no output", .{});
            current = try self.parseOpcall(target, op_tok, current.outputs[0], false);
        }

        // as namelist
        if (self.peek().kind == .name and std.mem.eql(u8, self.peek().text, "as")) {
            _ = self.next();
            var bound_names = std.ArrayListUnmanaged([]const u8).empty;
            while (true) {
                const nt = self.next();
                if (nt.kind != .name) return self.fail(nt, "expected name after 'as'", .{});
                if (target.names.contains(nt.text)) return self.fail(nt, "name '{s}' is already bound (names are single-assignment)", .{nt.text});
                if (self.reg.find(nt.text) != null or self.defs.contains(nt.text)) {
                    return self.fail(nt, "name '{s}' shadows an operator", .{nt.text});
                }
                const idx = bound_names.items.len;
                if (idx >= current.outputs.len) {
                    return self.fail(nt, "'as' names {d} streams but the operator has {d} output(s)", .{ idx + 1, current.outputs.len });
                }
                const owned = try self.a().dupe(u8, nt.text);
                try target.names.put(self.a(), owned, current.outputs[idx]);
                try bound_names.append(self.a(), owned);
                if (self.peek().kind == .comma) {
                    _ = self.next();
                } else break;
            }
            current.out_names = bound_names.items;
        }

        const end = self.peek();
        if (end.kind != .newline and end.kind != .eof) {
            return self.fail(end, "unexpected '{s}' — expected end of statement", .{end.text});
        }
        return current;
    }

    /// expr := opcall | path | literal | record | name
    fn parseExpr(self: *Parser, target: *Target) ParseError!OpResult {
        const t = self.peek();
        switch (t.kind) {
            .lbrace => {
                const rec = try self.parseRecord(target);
                return .{ .node = rec, .outputs = try self.outsOf(target, rec) };
            },
            .number, .string => {
                const lit = try self.parseLiteral(target);
                return .{ .outputs = try self.oneSource(lit.source) };
            },
            .name => {
                if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false")) {
                    const lit = try self.parseLiteral(target);
                    return .{ .outputs = try self.oneSource(lit.source) };
                }
                if (std.mem.eql(u8, t.text, "plane")) {
                    const arg = try self.parsePlaneRef(target);
                    return .{ .outputs = try self.oneSource(arg.source) };
                }
                if (target.names.get(t.text)) |src| {
                    _ = self.next();
                    const projected = try self.parseProjections(target, src);
                    return .{ .outputs = try self.oneSource(projected) };
                }
                const op_tok = self.next();
                return self.parseOpcall(target, op_tok, null, false);
            },
            .sym => {
                const op_tok = self.next();
                return self.parseOpcall(target, op_tok, null, false);
            },
            else => return self.fail(t, "expected an expression, got '{s}'", .{t.text}),
        }
    }

    fn oneSource(self: *Parser, src: Source) ![]const Source {
        const arr = try self.a().alloc(Source, 1);
        arr[0] = src;
        return arr;
    }

    fn outsOf(self: *Parser, target: *Target, node_id: NodeId) ![]const Source {
        const n = &target.nodes.items[node_id];
        const arr = try self.a().alloc(Source, n.outputs.len);
        for (n.outputs, 0..) |s, i| arr[i] = .{ .wire = s };
        return arr;
    }

    // -- values -------------------------------------------------------------

    const ParsedLit = struct { source: Source, ty: types.TypeId };

    fn parseLiteral(self: *Parser, target: *Target) ParseError!ParsedLit {
        _ = target;
        const t = self.next();
        var pk = struple.Packer.init(self.a());
        switch (t.kind) {
            .number => {
                if (std.mem.indexOfAny(u8, t.text, ".eE") != null) {
                    const v = std.fmt.parseFloat(f64, t.text) catch return self.fail(t, "bad number '{s}'", .{t.text});
                    pk.appendF64(v) catch return error.OutOfMemory;
                } else {
                    const v = std.fmt.parseInt(i64, t.text, 10) catch return self.fail(t, "bad number '{s}'", .{t.text});
                    pk.appendInt(v) catch return error.OutOfMemory;
                }
            },
            .string => {
                const unescaped = try self.unescape(t.text);
                pk.appendString(unescaped) catch return error.OutOfMemory;
            },
            .name => {
                if (std.mem.eql(u8, t.text, "true")) {
                    pk.appendBool(true) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, t.text, "false")) {
                    pk.appendBool(false) catch return error.OutOfMemory;
                } else return self.fail(t, "expected a literal, got '{s}'", .{t.text});
            },
            else => return self.fail(t, "expected a literal, got '{s}'", .{t.text}),
        }
        const bytes = pk.toOwnedSlice() catch return error.OutOfMemory;
        return .{ .source = .{ .literal = bytes }, .ty = types.typeOfValue(bytes) };
    }

    fn unescape(self: *Parser, raw: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var out = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                try out.append(self.a(), switch (raw[i]) {
                    'n' => '\n',
                    't' => '\t',
                    else => raw[i],
                });
            } else try out.append(self.a(), raw[i]);
        }
        return out.items;
    }

    /// `plane` `.` segment… — returns either a plain path ref or, for the
    /// record sugar `plane.a.{x, y}`, a record node's wire.
    fn parsePlaneRef(self: *Parser, target: *Target) ParseError!Arg {
        const head = self.next(); // "plane"
        if (target.template != null) {
            return self.fail(head, "defs close over nothing — pass plane streams in through a port", .{});
        }
        var path = std.ArrayListUnmanaged(u8).empty;
        try path.appendSlice(self.a(), "plane");
        while (self.peek().kind == .dot) {
            _ = self.next();
            const seg = self.peek();
            if (seg.kind == .lbrace) {
                // record sugar: plane.a.{x, y} — one record node, one field
                // per name, each subscribed at path.name.
                _ = self.next();
                var fields = std.ArrayListUnmanaged([]const u8).empty;
                var sources = std.ArrayListUnmanaged(Source).empty;
                while (true) {
                    const ft = self.next();
                    if (ft.kind != .name) return self.fail(ft, "expected field name in '.{{…}}'", .{});
                    const sub_path = try std.fmt.allocPrint(self.a(), "{s}.{s}", .{ path.items, ft.text });
                    try fields.append(self.a(), try self.a().dupe(u8, ft.text));
                    try sources.append(self.a(), .{ .plane = sub_path });
                    const sep = self.next();
                    if (sep.kind == .comma) continue;
                    if (sep.kind == .rbrace) break;
                    return self.fail(sep, "expected ',' or '}}' in '.{{…}}'", .{});
                }
                const rec = try self.makeRecordNode(target, fields.items, sources.items, head);
                const outs = &target.nodes.items[rec].outputs;
                return .{ .kind = .stream, .source = .{ .wire = outs.*[0] }, .ty = types.Tag.record, .tok = head };
            }
            if (seg.kind != .name) return self.fail(seg, "expected path segment after '.'", .{});
            _ = self.next();
            try path.append(self.a(), '.');
            try path.appendSlice(self.a(), seg.text);
        }
        if (path.items.len == "plane".len) return self.fail(head, "expected '.' after 'plane'", .{});
        return .{ .kind = .plane_path, .source = .{ .plane = path.items }, .ty = types.Tag.any, .text = path.items, .tok = head };
    }

    /// name(.field)* — each `.field` becomes a projection node.
    fn parseProjections(self: *Parser, target: *Target, base: Source) ParseError!Source {
        var src = base;
        while (self.peek().kind == .dot) {
            _ = self.next();
            const ft = self.next();
            if (ft.kind != .name) return self.fail(ft, "expected field name after '.'", .{});
            const op_id = self.reg.find("project") orelse return self.fail(ft, "core operator 'project' is not registered", .{});
            const statics = try self.a().alloc(registry.StaticVal, 1);
            statics[0] = .{ .word = try self.a().dupe(u8, ft.text) };
            const node_id = try self.makeNode(target, op_id, &.{src}, statics, ft);
            src = .{ .wire = target.nodes.items[node_id].outputs[0] };
        }
        return src;
    }

    // -- records ------------------------------------------------------------

    /// `{ field: value (,|newline field: value)* }`
    fn parseRecord(self: *Parser, target: *Target) ParseError!NodeId {
        const open = self.next(); // {
        var fields = std.ArrayListUnmanaged([]const u8).empty;
        var sources = std.ArrayListUnmanaged(Source).empty;
        self.skipNewlines();
        while (self.peek().kind != .rbrace) {
            const ft = self.next();
            if (ft.kind != .name) return self.fail(ft, "expected field name in record", .{});
            const ct = self.next();
            if (ct.kind != .colon) return self.fail(ct, "expected ':' after field '{s}'", .{ft.text});
            const arg = try self.parseArgValue(target);
            try fields.append(self.a(), try self.a().dupe(u8, ft.text));
            try sources.append(self.a(), arg.source);
            // separators: comma or newline(s)
            if (self.peek().kind == .comma) _ = self.next();
            self.skipNewlines();
        }
        _ = self.next(); // }
        if (fields.items.len == 0) return self.fail(open, "empty record", .{});
        return self.makeRecordNode(target, fields.items, sources.items, open);
    }

    fn makeRecordNode(self: *Parser, target: *Target, fields: []const []const u8, sources: []const Source, tok: Token) ParseError!NodeId {
        const op_id = self.reg.find("record") orelse return self.fail(tok, "core operator 'record' is not registered", .{});
        const statics = try self.a().alloc(registry.StaticVal, fields.len);
        for (fields, 0..) |f, i| statics[i] = .{ .word = f };
        return self.makeNode(target, op_id, sources, statics, tok);
    }

    // -- opcalls ------------------------------------------------------------

    /// Parse `opname arg*` with `primary` (the piped-in stream) bound to the
    /// first input port. Handles two-word host ops, def instantiation,
    /// statics, kwargs, and predicate sections. `reserved_primary` is set when
    /// parsing a section body: port 0 is held open for the mirrored stream, so
    /// `(< 20)` binds 20 to port b and computes `x < 20`, exactly as piping
    /// would.
    fn parseOpcall(self: *Parser, target: *Target, op_tok: Token, primary: ?Source, reserved_primary: bool) ParseError!OpResult {
        var op_name = op_tok.text;

        // defs shadow nothing and are single-word
        if (op_tok.kind == .name) {
            if (self.defs.get(op_name)) |tmpl| {
                return self.instantiate(target, tmpl, op_tok, primary);
            }
            // two-word lookup first, so (verb, subop) pairs are one operator
            const t2 = self.peek();
            if (t2.kind == .name and !std.mem.eql(u8, t2.text, "as")) {
                const two = try std.fmt.allocPrint(self.a(), "{s} {s}", .{ op_name, t2.text });
                if (self.reg.find(two) != null) {
                    op_name = two;
                    _ = self.next();
                }
            }
        }

        const op_id = self.reg.find(op_name) orelse
            return self.fail(op_tok, "unknown operator or name '{s}'", .{op_name});
        const def = self.reg.get(op_id);
        if (def.variadic) return self.fail(op_tok, "'{s}' cannot be called directly", .{op_name});

        var args = std.ArrayListUnmanaged(Arg).empty;
        try self.parseArgs(target, &args);

        // Statics are consumed from the leading positional args, in
        // declaration order — they are configuration, not streams.
        var statics = try self.a().alloc(registry.StaticVal, def.statics.len);
        var arg_idx: usize = 0;
        for (def.statics, 0..) |sd, i| {
            if (arg_idx >= args.items.len) return self.fail(op_tok, "'{s}' needs a {s} argument '{s}'", .{ op_name, @tagName(sd.kind), sd.name });
            const arg = args.items[arg_idx];
            arg_idx += 1;
            statics[i] = switch (sd.kind) {
                .path => blk: {
                    if (arg.kind != .plane_path) return self.fail(arg.tok, "'{s}' expects a plane path for '{s}'", .{ op_name, sd.name });
                    break :blk .{ .path = arg.text };
                },
                .word => blk: {
                    if (arg.kind != .word and arg.kind != .literal) return self.fail(arg.tok, "'{s}' expects a word for '{s}'", .{ op_name, sd.name });
                    break :blk .{ .word = try self.a().dupe(u8, if (arg.kind == .word) arg.text else arg.tok.text) };
                },
                .literal => blk: {
                    if (arg.kind != .literal) return self.fail(arg.tok, "'{s}' expects a literal for '{s}'", .{ op_name, sd.name });
                    break :blk .{ .literal = arg.source.literal };
                },
            };
        }
        const stream_args = args.items[arg_idx..];

        // Bind ports: primary → port 0; kwargs by name; sections → first free
        // boolean port; remaining positionals in declared order.
        const ports = def.inputs;
        const bound = try self.a().alloc(?Arg, ports.len);
        @memset(bound, null);

        if (primary) |src| {
            if (ports.len == 0) return self.fail(op_tok, "'{s}' takes no stream input", .{op_name});
            bound[0] = .{ .kind = .stream, .source = src, .ty = self.sourceTy(target, src), .tok = op_tok };
        } else if (reserved_primary and ports.len > 0) {
            // placeholder; the consumer patches the real source in afterwards
            bound[0] = .{ .kind = .stream, .source = .none, .tok = op_tok };
        }
        for (stream_args) |arg| {
            if (arg.kw.len == 0) continue;
            const pi = portIndex(ports, arg.kw) orelse return self.fail(arg.tok, "'{s}' has no port '{s}'", .{ op_name, arg.kw });
            if (bound[pi] != null) return self.fail(arg.tok, "port '{s}' of '{s}' bound twice", .{ arg.kw, op_name });
            bound[pi] = arg;
        }
        for (stream_args) |arg| {
            if (arg.kw.len > 0 or arg.kind != .section) continue;
            const pi = for (ports, 0..) |port, i| {
                if (bound[i] == null and port.ty == types.Tag.boolean) break i;
            } else return self.fail(arg.tok, "'{s}' has no free boolean port for a predicate", .{op_name});
            bound[pi] = arg;
        }
        for (stream_args) |arg| {
            if (arg.kw.len > 0 or arg.kind == .section) continue;
            if (arg.kind == .word) return self.fail(arg.tok, "unknown name '{s}'", .{arg.text});
            const pi = for (ports, 0..) |_, i| {
                if (bound[i] == null) break i;
            } else return self.fail(arg.tok, "too many arguments for '{s}' ({d} port(s))", .{ op_name, ports.len });
            bound[pi] = arg;
        }

        // Type check + collect sources.
        const sources = try self.a().alloc(Source, ports.len);
        for (ports, 0..) |port, i| {
            const arg = bound[i] orelse {
                if (port.optional) {
                    sources[i] = .none;
                    continue;
                }
                return self.fail(op_tok, "port '{s}' of '{s}' is not bound", .{ port.name, op_name });
            };
            const val_ty = if (arg.kind == .section) self.sourceTy(target, arg.source) else arg.ty;
            if (!types.accepts(port.ty, val_ty)) {
                return self.fail(arg.tok, "'{s}' port '{s}': expected {s}, got {s}", .{
                    op_name, port.name, self.reg.types.name(port.ty), self.reg.types.name(val_ty),
                });
            }
            sources[i] = arg.source;
        }

        const node_id = try self.makeNode(target, op_id, sources, statics, op_tok);

        // Sections mirror the consumer's primary input.
        for (stream_args) |arg| {
            if (arg.kind != .section) continue;
            if (ports.len == 0 or sources.len == 0) return self.fail(arg.tok, "'{s}' has no primary input for the predicate to read", .{op_name});
            const mirror = sources[0];
            switch (mirror) {
                .none => return self.fail(arg.tok, "'{s}' has no primary input for the predicate to read", .{op_name}),
                else => {},
            }
            try self.bindSectionPrimary(target, arg.section_node, mirror, arg.tok);
        }

        // Effect ops with a path static are plane writers — remember for the
        // cycle check (program level only; templates ban paths already).
        if (def.class == .effect and target.template == null) {
            for (statics) |sv| switch (sv) {
                .path => |wp| try self.prog.writes.append(self.a(), .{ .path = wp, .node = node_id }),
                else => {},
            };
        }

        return .{ .node = node_id, .outputs = try self.outsOf(target, node_id) };
    }

    fn portIndex(ports: []const registry.Port, name: []const u8) ?usize {
        for (ports, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) return i;
        }
        return null;
    }

    fn sourceTy(self: *Parser, target: *Target, src: Source) types.TypeId {
        _ = self;
        return switch (src) {
            .wire => |s| target.slots.items[s].ty,
            .literal => |b| types.typeOfValue(b),
            .plane => types.Tag.any,
            .port => |i| if (target.template) |t| t.ports[i].ty else types.Tag.any,
            .none => types.Tag.any,
        };
    }

    /// The section's first unbound input mirrors `mirror`. Plane mirrors also
    /// register the new subscription target.
    fn bindSectionPrimary(self: *Parser, target: *Target, section_node: NodeId, mirror: Source, tok: Token) ParseError!void {
        const n = &target.nodes.items[section_node];
        for (n.inputs) |sid| {
            const s = &target.slots.items[sid];
            if (s.source == .none) {
                s.source = mirror;
                if (mirror == .plane) {
                    const sub = self.prog.subFor(mirror.plane) catch return error.OutOfMemory;
                    try sub.targets.append(self.a(), sid);
                }
                return;
            }
        }
        return self.fail(tok, "predicate has no free input port", .{});
    }

    fn parseArgs(self: *Parser, target: *Target, args: *std.ArrayListUnmanaged(Arg)) ParseError!void {
        while (true) {
            const t = self.peek();
            switch (t.kind) {
                .newline, .eof, .pipe, .rparen => return,
                .name => {
                    if (std.mem.eql(u8, t.text, "as")) return;
                    // kwarg? name ':' value
                    if (self.toks[self.pos + 1].kind == .colon) {
                        _ = self.next();
                        _ = self.next(); // ':'
                        var arg = try self.parseArgValue(target);
                        arg.kw = t.text;
                        try args.append(self.a(), arg);
                        continue;
                    }
                    try args.append(self.a(), try self.parseArgValue(target));
                },
                else => try args.append(self.a(), try self.parseArgValue(target)),
            }
        }
    }

    /// arg := literal | path | name(.field)* | record | "(" opcall ")"
    fn parseArgValue(self: *Parser, target: *Target) ParseError!Arg {
        const t = self.peek();
        switch (t.kind) {
            .number, .string => {
                const lit = try self.parseLiteral(target);
                return .{ .kind = .literal, .source = lit.source, .ty = lit.ty, .tok = t };
            },
            .lbrace => {
                const rec = try self.parseRecord(target);
                const outs = target.nodes.items[rec].outputs;
                return .{ .kind = .stream, .source = .{ .wire = outs[0] }, .ty = types.Tag.record, .tok = t };
            },
            .lparen => {
                _ = self.next();
                const op_tok = self.next();
                if (op_tok.kind != .name and op_tok.kind != .sym) return self.fail(op_tok, "expected operator inside '(…)'", .{});
                const res = try self.parseOpcall(target, op_tok, null, true);
                const close = self.next();
                if (close.kind != .rparen) return self.fail(close, "expected ')'", .{});
                const node_id = res.node orelse return self.fail(op_tok, "expected an operator call inside '(…)'", .{});
                if (res.outputs.len == 0) return self.fail(op_tok, "predicate operator has no output", .{});
                return .{ .kind = .section, .source = res.outputs[0], .section_node = node_id, .tok = op_tok };
            },
            .name => {
                if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false")) {
                    const lit = try self.parseLiteral(target);
                    return .{ .kind = .literal, .source = lit.source, .ty = lit.ty, .tok = t };
                }
                if (std.mem.eql(u8, t.text, "plane")) {
                    return self.parsePlaneRef(target);
                }
                if (target.names.get(t.text)) |src| {
                    _ = self.next();
                    const projected = try self.parseProjections(target, src);
                    return .{ .kind = .stream, .source = projected, .ty = self.sourceTy(target, projected), .tok = t };
                }
                // a bare word: static word (label) or an error at bind time
                _ = self.next();
                return .{ .kind = .word, .text = t.text, .tok = t };
            },
            else => return self.fail(t, "unexpected '{s}' in arguments", .{t.text}),
        }
    }

    // -- node construction --------------------------------------------------

    /// Create a node + its slots in `target`. `sources` supplies one Source
    /// per input port (variadic ops derive their ports from it).
    fn makeNode(self: *Parser, target: *Target, op_id: registry.OpId, sources: []const Source, statics: []registry.StaticVal, tok: Token) ParseError!NodeId {
        const def = self.reg.get(op_id);
        const node_id: NodeId = @intCast(target.nodes.items.len);
        const node_name = try self.autoName(def.name);

        const n_in = sources.len;
        const inputs = try self.a().alloc(SlotId, n_in);
        const outputs = try self.a().alloc(SlotId, def.outputs.len);

        for (sources, 0..) |src, i| {
            const slot_id: SlotId = @intCast(target.slots.items.len);
            const port: registry.Port = if (def.variadic)
                .{ .name = statics[i].word, .ty = types.Tag.any }
            else
                def.inputs[i];
            try target.slots.append(self.a(), .{
                .id = slot_id,
                .node = node_id,
                .dir = .in,
                .port = @intCast(i),
                .name = port.name,
                .ty = port.ty,
                .kind = port.kind,
                .source = src,
                .path = try self.slotPath(target, node_name, .in, port.name),
            });
            inputs[i] = slot_id;
            if (src == .plane) {
                if (target.template != null) return self.fail(tok, "defs close over nothing — pass plane streams in through a port", .{});
                const sub = self.prog.subFor(src.plane) catch return error.OutOfMemory;
                try sub.targets.append(self.a(), slot_id);
            }
        }
        for (def.outputs, 0..) |port, i| {
            const slot_id: SlotId = @intCast(target.slots.items.len);
            try target.slots.append(self.a(), .{
                .id = slot_id,
                .node = node_id,
                .dir = .out,
                .port = @intCast(i),
                .name = port.name,
                .ty = port.ty,
                .kind = port.kind,
                .path = try self.slotPath(target, node_name, .out, port.name),
            });
            outputs[i] = slot_id;
        }

        try target.nodes.append(self.a(), .{
            .id = node_id,
            .op = op_id,
            .name = node_name,
            .inputs = inputs,
            .outputs = outputs,
            .statics = statics,
        });
        return node_id;
    }

    fn slotPath(self: *Parser, target: *Target, node_name: []const u8, dir: graph.Dir, port_name: []const u8) ![]const u8 {
        if (target.template != null) return ""; // built at splice time
        return std.fmt.allocPrint(self.a(), "programs.{s}.{s}.{s}.{s}", .{
            self.prog.name, node_name, @tagName(dir), port_name,
        });
    }

    // -- def instantiation --------------------------------------------------

    /// Flatten a def instance into `target`: copy the template's nodes with
    /// the instance-name prefix, remap wires, and substitute `.port` sources
    /// with the caller's bindings. Internal `as` names become addressable
    /// slot paths under the instance for free.
    fn instantiate(self: *Parser, target: *Target, tmpl: *Template, op_tok: Token, primary: ?Source) ParseError!OpResult {
        var args = std.ArrayListUnmanaged(Arg).empty;
        try self.parseArgs(target, &args);

        // Bind caller args to def ports (same rules as opcalls, no statics).
        const bound = try self.a().alloc(?Arg, tmpl.ports.len);
        @memset(bound, null);
        if (primary) |src| {
            if (tmpl.ports.len == 0) return self.fail(op_tok, "'{s}' takes no stream input", .{tmpl.name});
            bound[0] = .{ .kind = .stream, .source = src, .ty = self.sourceTy(target, src), .tok = op_tok };
        }
        for (args.items) |arg| {
            if (arg.kw.len == 0) continue;
            const pi = for (tmpl.ports, 0..) |pd, i| {
                if (std.mem.eql(u8, pd.name, arg.kw)) break i;
            } else return self.fail(arg.tok, "'{s}' has no port '{s}'", .{ tmpl.name, arg.kw });
            if (bound[pi] != null) return self.fail(arg.tok, "port '{s}' of '{s}' bound twice", .{ arg.kw, tmpl.name });
            bound[pi] = arg;
        }
        for (args.items) |arg| {
            if (arg.kw.len > 0) continue;
            if (arg.kind == .word) return self.fail(arg.tok, "unknown name '{s}'", .{arg.text});
            if (arg.kind == .section) return self.fail(arg.tok, "predicates cannot bind to def ports (v0)", .{});
            const pi = for (tmpl.ports, 0..) |_, i| {
                if (bound[i] == null) break i;
            } else return self.fail(arg.tok, "too many arguments for '{s}' ({d} port(s))", .{ tmpl.name, tmpl.ports.len });
            bound[pi] = arg;
        }
        const port_sources = try self.a().alloc(Source, tmpl.ports.len);
        for (tmpl.ports, 0..) |pd, i| {
            const arg = bound[i] orelse return self.fail(op_tok, "port '{s}' of '{s}' is not bound", .{ pd.name, tmpl.name });
            if (!types.accepts(pd.ty, arg.ty)) {
                return self.fail(arg.tok, "'{s}' port '{s}': expected {s}, got {s}", .{
                    tmpl.name, pd.name, self.reg.types.name(pd.ty), self.reg.types.name(arg.ty),
                });
            }
            port_sources[i] = arg.source;
        }

        const inst_name = try self.autoName(tmpl.name);

        // Splice, remapping slot ids and substituting sources.
        const slot_base: SlotId = @intCast(target.slots.items.len);
        const node_base: NodeId = @intCast(target.nodes.items.len);
        for (tmpl.nodes.items) |tn| {
            const new_name = try std.fmt.allocPrint(self.a(), "{s}.{s}", .{ inst_name, tn.name });
            const inputs = try self.a().alloc(SlotId, tn.inputs.len);
            const outputs = try self.a().alloc(SlotId, tn.outputs.len);
            const new_id: NodeId = node_base + tn.id;
            for (tn.inputs, 0..) |tsid, i| {
                const ts = tmpl.slots.items[tsid];
                const src = substSource(ts.source, slot_base, port_sources);
                const slot_id: SlotId = @intCast(target.slots.items.len);
                try target.slots.append(self.a(), .{
                    .id = slot_id,
                    .node = new_id,
                    .dir = .in,
                    .port = ts.port,
                    .name = ts.name,
                    .ty = ts.ty,
                    .kind = ts.kind,
                    .source = src,
                    .path = try self.slotPath(target, new_name, .in, ts.name),
                });
                inputs[i] = slot_id;
                if (src == .plane) {
                    const sub = self.prog.subFor(src.plane) catch return error.OutOfMemory;
                    try sub.targets.append(self.a(), slot_id);
                }
            }
            for (tn.outputs, 0..) |tsid, i| {
                const ts = tmpl.slots.items[tsid];
                const slot_id: SlotId = @intCast(target.slots.items.len);
                try target.slots.append(self.a(), .{
                    .id = slot_id,
                    .node = new_id,
                    .dir = .out,
                    .port = ts.port,
                    .name = ts.name,
                    .ty = ts.ty,
                    .kind = ts.kind,
                    .path = try self.slotPath(target, new_name, .out, ts.name),
                });
                outputs[i] = slot_id;
            }
            const statics = try self.a().alloc(registry.StaticVal, tn.statics.len);
            @memcpy(statics, tn.statics);
            try target.nodes.append(self.a(), .{
                .id = new_id,
                .op = tn.op,
                .name = new_name,
                .inputs = inputs,
                .outputs = outputs,
                .statics = statics,
            });
        }

        const outs = try self.a().alloc(Source, tmpl.outputs.len);
        for (tmpl.outputs, 0..) |to, i| {
            outs[i] = substSource(to.source, slot_base, port_sources);
        }
        return .{ .node = null, .outputs = outs };
    }
};

/// Remap a template source into the instance: wires shift by `slot_base`
/// (slot ids are dense and the splice loop appends every template slot exactly
/// once, in the same per-node order the template created them, so template
/// slot i lands at slot_base + i).
fn substSource(src: Source, slot_base: SlotId, port_sources: []const Source) Source {
    return switch (src) {
        .none => .none,
        .wire => |s| .{ .wire = slot_base + s },
        .literal => |b| .{ .literal = b }, // arena-shared, immutable
        .plane => unreachable, // banned in templates at parse
        .port => |i| port_sources[i],
    };
}
