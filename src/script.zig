//! script — the authored structure of a program, retained through the parse.
//!
//! `parse` flattens. A `def` body is spliced into the graph with a name
//! prefix and the template is dropped; a `using … as :k` fold is expanded and
//! forgotten; a `describe` block becomes prose on `Program.exports` and only
//! for an EXPORTED def; comments are dropped in the tokenizer. All of that is
//! correct for an evaluator — the graph is what runs — and all of it is fatal
//! for an EDITOR, which has to hand the file back afterwards.
//!
//! So this is the other half of the parse: the same text, kept as it was
//! written. It is purely additive — nothing in `eval.zig`, `row.zig`,
//! `serialize.zig` or the mount path reads it, and a host that does not want
//! it can ignore `Program.script` entirely.
//!
//! ## The tunnel
//!
//! `Def.body` is a `Block`, exactly as `Script.top` is. That is the whole of
//! graph tunneling: a definition is its own editable graph, drilled into and
//! back out of, and the editor needs no second representation to do it. This
//! shape was designed in rather than retrofitted because Christian's ruling
//! (2026-09-09) is that a tunnel added later never gets added: the parse
//! already built the mini-graph (`parser.Template`) and threw it away, so
//! keeping it is retention, not invention.
//!
//! ## What "as written" means here
//!
//! Every leaf holds the text the AUTHOR typed, re-rendered from that leaf's
//! own tokens with canonical spacing — not the parser's resolved value. The
//! difference is the point:
//!
//!   - `:k.tight` stays `:k.tight`, never `plane.drift.@self.k.tight`.
//!   - `boolean subtract` stays two words.
//!   - `at: 5` and `at 5` stay apart.
//!   - a def's `rate = 60 (0..500)` stays `60` and `0..500`, not struple bytes.
//!
//! A leaf is TEXT rather than a nested tree on purpose: a record literal, an
//! array and a predicate section are already nodes in the graph, so the
//! editor has structure for them there, and duplicating it here would be two
//! representations to keep in step. What the script owes is the spelling.
//!
//! ## Comments are load-bearing
//!
//! `matryoshka/kernels/roaches.rill` is the project's documented exemplar and
//! is roughly four-fifths prose: the numbers, the traps and the reasoning all
//! live in `//` lines. An editor that eats them on save is dead on arrival —
//! it would silently delete the only documentation of the thing it edits. So
//! comments and blank runs are retained per item (`lead`, `blank_before`) and
//! `print` puts them back where they were.

const std = @import("std");

/// One `//` line that leads an item, and the blank lines above it.
///
/// Attached to the item it LEADS rather than kept in a flat list, because
/// that is what survives an edit: move a statement in the editor and its
/// explanation moves with it. A comment nobody leads (the run at the end of a
/// file) lands on `Script.tail`.
pub const Comment = struct {
    /// Blank source lines between whatever came before and this comment.
    blank_before: u32 = 0,
    /// The comment as written, `//` included, trailing whitespace trimmed.
    text: []const u8,
};

/// One argument of one call, as authored.
pub const Arg = struct {
    pub const Kind = enum {
        /// `60`, `0.15`, `"add"`, `5s`, `true`
        literal,
        /// a bare word: a flag, a keyword, an operator mode (`hold`, `add`)
        word,
        /// `plane.…` / `row.…` / `slate.…` — a subscription
        path,
        /// a local `as` name, with any `.field` projections
        stream,
        /// `(> 0)`, `(.pos.x)` — a predicate or a body section
        section,
        /// `{l: 0.28, a: -0.02}`
        record,
        /// `[0, 0.5, 1]`
        array,
        /// the rest of the line, verbatim (§3.11)
        tail,
    };
    kind: Kind,
    /// The argument as authored. This is what `print` emits; every other
    /// field is metadata for whoever is editing it.
    text: []const u8,
    /// Non-empty when the argument was introduced by a keyword — `at 5`
    /// binds `5` to `at`. The word is NOT part of `text`.
    kw: []const u8 = "",
    /// `at: 5` rather than `at 5`. Two spellings of one binding, and the file
    /// keeps the one it had.
    kw_colon: bool = false,
    line: u32 = 0,
    col: u32 = 0,
};

/// One operator call, as authored.
pub const Call = struct {
    /// The spelling ACTUALLY USED, so a two-word host verb prints back as two
    /// words. `parseOpcall` tries the two-word lookup first, and the name it
    /// settles on is the name that was typed.
    op: []const u8,
    /// A shape literal (`{id: string} exact`), which is parsed before the
    /// arguments because it is its own grammar. Empty when the op has none.
    shape: []const u8 = "",
    args: []const Arg = &.{},
    /// Non-empty when the call is SUGAR the parser rewrote: `$wind at
    /// row.pos` becomes a `hear` call in the graph, and printing `hear` back
    /// would be correct-but-not-what-was-written. When set, `print` emits
    /// this verbatim and ignores `op`/`args`.
    sugar: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
};

/// One `| …` step of a chain.
pub const Stage = union(enum) {
    /// `| add 1`
    call: Call,
    /// `| .pos.x` — the field-read sugar, kept as sugar.
    project: []const u8,
    /// `also { … }`, and the head-block form of the same rule.
    fan: Fan,
};

/// Fan-out spelled inline. `spelled_also` is false for the head-block form
/// (`every 1f { cast … }`), true for the mid-chain `| also { … }` — the same
/// desugaring, two positions, one spelling each, so the file keeps its own.
pub const Fan = struct {
    spelled_also: bool,
    branches: []const Branch = &.{},
};

/// One branch of a fan-out: a chain whose head is always an operator.
pub const Branch = struct {
    lead: []const Comment = &.{},
    blank_before: u32 = 0,
    head: Call,
    stages: []const Stage = &.{},
    /// A `// …` on the same line as this branch, `//` included.
    trail: []const u8 = "",
};

/// A statement's first term: an operator call, or a value.
pub const Head = union(enum) {
    call: Call,
    /// `plane.x`, `t.pos`, `0.1`, `{x: 1}`, `[1, 2]` — as authored.
    value: []const u8,
};

pub const Stmt = struct {
    lead: []const Comment = &.{},
    blank_before: u32 = 0,
    head: Head,
    stages: []const Stage = &.{},
    /// `as a, b`
    names: []const []const u8 = &.{},
    /// A `// …` written at the END of the statement's own line, `//`
    /// included. Distinct from `lead`, and it has to be: `plane.hp | clamp 0
    /// 100 // what's flowing` is the manual's spelling, and attaching it to
    /// the NEXT statement moves it a line down on every save.
    trail: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
};

/// One declared port of a `def`, with its parameter pack as WRITTEN. The
/// values are text, not struple bytes: `graph.DefPort` already holds the
/// bytes for a host that wants to read the number, and a printer needs the
/// spelling (`0.5` and `0.50` are the same number and not the same file).
pub const Port = struct {
    name: []const u8,
    /// `: number`'s type word. Empty when undeclared.
    ty: []const u8 = "",
    /// `= 60`. Empty when the port is required.
    default: []const u8 = "",
    /// `(0..500)`. Both empty when there is no range.
    min: []const u8 = "",
    max: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
};

/// A definition, kept rather than dropped — and `body` is the tunnel.
pub const Def = struct {
    name: []const u8,
    exported: bool = false,
    ports: []const Port = &.{},
    /// `on row` / `on plane`'s plane word, as written. Empty when undeclared
    /// (which means the world plane, and is not the same as having written
    /// `on plane`).
    on: []const u8 = "",
    /// The definition's own graph. Drill in, edit, drill out.
    body: []const Item = &.{},
    /// `def double(x) = x | mul 2` — the body sat on the signature line.
    inline_body: bool = false,
    lead: []const Comment = &.{},
    blank_before: u32 = 0,
    /// A `// …` on the signature's own line.
    trail: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
};

/// `using <tokens…> as :name` — the binding as written, never as expanded.
pub const Using = struct {
    /// The fold name, colon included: `:k`.
    name: []const u8,
    /// The folded tokens, re-rendered.
    body: []const u8,
    lead: []const Comment = &.{},
    blank_before: u32 = 0,
    trail: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
};

/// One line of an annex: an optional key, then its values, each as authored.
///
/// A `describe` line is `rate "…"` — key `rate`, one value, the string with
/// its quotes still on. The leading bare string of the block is a line with
/// no key. Values are kept as RENDERED TEXT rather than decoded, so the
/// printer is a join and no annex kind has to teach it how to re-escape.
pub const AnnexLine = struct {
    key: []const u8 = "",
    values: []const []const u8 = &.{},
};

/// A block that the parser reads, the runtime elides, and the document keeps.
///
/// `describe` is the first one and today the only one. It is modelled as an
/// INSTANCE of a kind rather than as itself because Christian ruled on
/// 2026-09-09 that the editor's node positions land the same way — a real
/// rill block, not comments and not a sidecar file, naming `describe` as the
/// precedent — keyed by the instance names `autoName` already mints:
///
///     layout roaches
///       near1  240 120
///       push1  400 120
///
/// That block is NOT built here and the parser does not accept it. What is
/// built here is the shape it will land in: adding it means a reader in the
/// parser and one more `keyword`, and the printer does not move at all. The
/// governing principle is Christian's — "everything should be round-trippable
/// from the document" — and a bespoke `describe` threaded through the printer
/// would make the second such block cost five call sites instead of one.
///
/// Named `Annex` after reading the alternatives aloud. Rejected: `Block`
/// (a `{…}` fan-out is already called a block in this language), `Section`
/// (a predicate section is), `Body` (a def has one), `Sidecar` (Christian
/// explicitly ruled OUT a sidecar file, so the word would mislead), `Note`
/// (collides with `noteProvenance`, and understates `layout`), `Gloss`
/// (right for prose, wrong for coordinates).
pub const Annex = struct {
    /// The word that opens the block: `describe` today.
    keyword: []const u8,
    /// What the block is about — a def's name, or the program's.
    subject: []const u8,
    lines: []const AnnexLine = &.{},
    lead: []const Comment = &.{},
    blank_before: u32 = 0,
    /// A `// …` on the block's LAST line. A trailing comment on an earlier
    /// line of the block is claimed by whatever comes next — nothing in the
    /// corpus writes one, so it stays a consequence rather than a mechanism.
    trail: []const u8 = "",
    line: u32 = 0,
    col: u32 = 0,
};

/// One top-level thing, in source order. Order is retained rather than
/// bucketed by kind because the file's order IS its schedule — local names
/// are single-assignment and must be defined before use, so parse order is
/// topological order, and a printer that regrouped would emit a program that
/// no longer parses. (`parser.zig`'s header states this; it is the one
/// constraint the editor cannot design around.)
pub const Item = union(enum) {
    stmt: Stmt,
    /// An index into `Script.defs` — the tunnel's door.
    def: u32,
    using: Using,
    annex: Annex,
};

/// Which definition instance produced a flattened node.
///
/// A REAL field rather than a name derivation. The instance prefix is already
/// in `Node.name` (`roaches1.mul2`), so deriving it would have worked — but a
/// derivation is a second parser for a name format nothing else pins, and it
/// answers the wrong question for a nested def: the name carries the whole
/// chain and this says which DEFINITION the editor should tunnel into.
pub const Origin = struct {
    /// Index into `Script.defs`.
    def: u32,
    /// The instance name the parser minted for this splice (`roaches1`).
    instance: []const u8,
};

pub const Script = struct {
    /// The program's top level.
    top: []const Item = &.{},
    /// Every definition in the file, in source order.
    defs: []const Def = &.{},
    /// One entry per node id of the finished program: which def instance
    /// produced it, or null for a node the top level wrote directly. Nodes
    /// from a def that calls a def name the OUTERMOST instance; `Node.name`
    /// carries the rest of the chain.
    origins: []const ?Origin = &.{},
    /// Comments after the last item, and the blank run before them.
    tail: []const Comment = &.{},

    /// The definition called `name`, or null.
    pub fn def(self: *const Script, name: []const u8) ?*const Def {
        for (self.defs) |*d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// The printer
// ---------------------------------------------------------------------------

/// One indent, in spaces, for everything nested: a def body, a `describe`
/// block's lines, a fan-out's branches.
///
/// **Four, and RULED rather than inherited.** Christian, 2026-09-09, asked
/// first about def bodies — *"honestly I'd prefer 4, to match most tabs"* —
/// and then about the fan-out case, and answered it wider than it was asked:
/// **"four everywhere."**
///
/// One constant and not several that agree. A previous pass had two, and two
/// names for one value is an invitation to drift apart and re-open a question
/// that is now closed.
///
/// The measurement that started it is worth keeping, because it is why this
/// needed a ruling at all rather than a majority: the corpus was split, and
/// split between two sets of Christian's own files. `kernels/roaches.rill` —
/// the one of the 47 `.rill` files with a multi-line def body — writes 4,
/// while all six def bodies printed in `rill-manual.md` and
/// `rill-for-agents.md` write 2, and every `describe` block everywhere writes
/// 2. An interim pass RETAINED what was written so that neither set moved; he
/// asked for one canon instead. rill's own docs were restretched to match in
/// the same commit, because a document that teaches an indent the printer
/// does not emit is wrong the first time anyone round-trips it.
///
/// The `.rill` corpus is deliberately NOT normalised here — that is the
/// formatter's first real job, one commit per sibling repo, and it is not
/// this beat's to do.
const indent_canon: u32 = 4;

/// The canon, chosen to read like the corpus Christian reads daily:
///
///   - one statement, one line; a chain never wraps. (The corpus wraps in
///     four ironwood rills, always with the `|` in the left margin. That is a
///     nice shape and it is NOT recoverable from the structure — the parser
///     skips the newline — so a printer that guessed would churn the file
///     differently every time. One line is the stable answer.)
///   - everything nested indents by four — a def body, a `describe` block's
///     lines, a fan-out's branches. Christian's ruling; see `indent_canon`.
///   - a `describe` block also pads its keys into a column so the values line
///     up. `kernels/roaches.rill` hand-aligns eleven ports, and at that width
///     the column is what makes the block readable, not decoration.
///   - blank runs preserved exactly as written. Preserving beats normalising
///     here: normalising would rewrite every file in the corpus on its first
///     save, which is the thing that makes a git history useless.
///   - a trailing newline, always.
pub fn print(gpa: std.mem.Allocator, s: *const Script) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    var p = Printer{ .gpa = gpa, .out = &out, .script = s };
    for (s.top) |item| try p.item(item, 0);
    for (s.tail) |c| {
        try p.blanks(c.blank_before);
        try p.line(0, c.text);
    }
    return out.toOwnedSlice(gpa);
}

/// Mutual recursion (a fan-out holds branches which hold stages which hold
/// fan-outs) means the error set cannot be inferred; it is only ever the
/// allocator's.
const Oom = std.mem.Allocator.Error;

const Printer = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    script: *const Script,

    fn w(self: *Printer, text: []const u8) Oom!void {
        try self.out.appendSlice(self.gpa, text);
    }

    fn blanks(self: *Printer, n: u32) Oom!void {
        var i: u32 = 0;
        while (i < n) : (i += 1) try self.w("\n");
    }

    /// `col` is a count of SPACES, not a nesting level: a def body may be
    /// indented by whatever it was written with, which a level cannot say.
    fn indent(self: *Printer, col: u32) Oom!void {
        var i: u32 = 0;
        while (i < col) : (i += 1) try self.w(" ");
    }

    fn line(self: *Printer, col: u32, text: []const u8) Oom!void {
        try self.indent(col);
        try self.w(text);
        try self.w("\n");
    }

    /// Two spaces before a `// …` at the end of a line. A canon, and one the
    /// corpus keeps loosely (three spaces, or a column) — normalising it is
    /// what makes the second print equal the first.
    fn trail(self: *Printer, text: []const u8) Oom!void {
        if (text.len == 0) return;
        try self.w("  ");
        try self.w(text);
    }

    fn lead(self: *Printer, comments: []const Comment, col: u32) Oom!void {
        for (comments) |c| {
            try self.blanks(c.blank_before);
            try self.line(col, c.text);
        }
    }

    fn item(self: *Printer, it: Item, col: u32) Oom!void {
        switch (it) {
            .stmt => |st| {
                try self.lead(st.lead, col);
                try self.blanks(st.blank_before);
                try self.indent(col);
                try self.stmt(st, col);
                try self.trail(st.trail);
                try self.w("\n");
            },
            .def => |idx| try self.def(&self.script.defs[idx], col),
            .using => |u| {
                try self.lead(u.lead, col);
                try self.blanks(u.blank_before);
                try self.indent(col);
                try self.w("using ");
                try self.w(u.body);
                try self.w(" as ");
                try self.w(u.name);
                try self.trail(u.trail);
                try self.w("\n");
            },
            // One arm for every runtime-elided block there will ever be: the
            // keyword is data, so `layout` costs a reader in the parser and
            // nothing here (see `Annex`).
            .annex => |an| {
                try self.lead(an.lead, col);
                try self.blanks(an.blank_before);
                try self.indent(col);
                try self.w(an.keyword);
                try self.w(" ");
                try self.w(an.subject);
                try self.w("\n");
                // Pad every key to the longest in the block, so the values
                // line up. Not decoration: `describe roaches` runs to eleven
                // ports and Christian hand-aligned it, because a column is
                // what makes a block that size readable. Deterministic, so
                // idempotence is untouched — and gated at BYTE level, which
                // is the half that sees whitespace.
                var key_w: usize = 0;
                for (an.lines) |al| key_w = @max(key_w, al.key.len);
                for (an.lines, 0..) |al, i| {
                    try self.indent(col + indent_canon);
                    if (al.key.len > 0) {
                        try self.w(al.key);
                        if (al.values.len > 0) {
                            // A keyless line — the leading bare string — is
                            // not padded: it is not in the column.
                            try self.indent(@intCast(key_w - al.key.len + 1));
                        }
                    }
                    for (al.values, 0..) |v, j| {
                        if (j > 0) try self.w(" ");
                        try self.w(v);
                    }
                    if (i + 1 == an.lines.len) try self.trail(an.trail);
                    try self.w("\n");
                }
            },
        }
    }

    fn def(self: *Printer, d: *const Def, col: u32) Oom!void {
        try self.lead(d.lead, col);
        try self.blanks(d.blank_before);
        try self.indent(col);
        if (d.exported) try self.w("export ");
        try self.w("def ");
        try self.w(d.name);
        try self.w("(");
        for (d.ports, 0..) |port, i| {
            if (i > 0) try self.w(", ");
            try self.w(port.name);
            if (port.ty.len > 0) {
                try self.w(": ");
                try self.w(port.ty);
            }
            if (port.default.len > 0) {
                try self.w(" = ");
                try self.w(port.default);
            }
            if (port.min.len > 0) {
                try self.w(" (");
                try self.w(port.min);
                try self.w("..");
                try self.w(port.max);
                try self.w(")");
            }
        }
        try self.w(")");
        if (d.on.len > 0) {
            try self.w(" on ");
            try self.w(d.on);
        }
        try self.w(" =");
        if (d.inline_body and d.body.len == 1 and d.body[0] == .stmt) {
            try self.w(" ");
            try self.stmt(d.body[0].stmt, col);
            try self.trail(if (d.trail.len > 0) d.trail else d.body[0].stmt.trail);
            try self.w("\n");
            return;
        }
        try self.trail(d.trail);
        try self.w("\n");
        for (d.body) |b| try self.item(b, col + indent_canon);
    }

    fn stmt(self: *Printer, st: Stmt, col: u32) Oom!void {
        switch (st.head) {
            .call => |c| try self.call(c),
            .value => |v| try self.w(v),
        }
        try self.stages(st.stages, col);
        for (st.names, 0..) |n, i| {
            try self.w(if (i == 0) " as " else ", ");
            try self.w(n);
        }
    }

    fn stages(self: *Printer, list: []const Stage, col: u32) Oom!void {
        for (list) |sg| switch (sg) {
            .call => |c| {
                try self.w(" | ");
                try self.call(c);
            },
            .project => |f| {
                try self.w(" | ");
                try self.w(f);
            },
            .fan => |f| {
                // The head-block form has no `also`: the head IS the source.
                try self.w(if (f.spelled_also) " | also {" else " {");
                if (f.branches.len == 1 and f.branches[0].lead.len == 0) {
                    try self.w(" ");
                    try self.branch(f.branches[0], col);
                    try self.w(" }");
                    continue;
                }
                try self.w("\n");
                for (f.branches) |b| {
                    try self.lead(b.lead, col + indent_canon);
                    try self.blanks(b.blank_before);
                    try self.indent(col + indent_canon);
                    try self.branch(b, col + indent_canon);
                    try self.trail(b.trail);
                    try self.w("\n");
                }
                try self.indent(col);
                try self.w("}");
            },
        };
    }

    fn branch(self: *Printer, b: Branch, col: u32) Oom!void {
        try self.call(b.head);
        try self.stages(b.stages, col);
    }

    fn call(self: *Printer, c: Call) Oom!void {
        if (c.sugar.len > 0) return self.w(c.sugar);
        try self.w(c.op);
        if (c.shape.len > 0) {
            try self.w(" ");
            try self.w(c.shape);
        }
        for (c.args) |arg| {
            try self.w(" ");
            if (arg.kw.len > 0) {
                try self.w(arg.kw);
                try self.w(if (arg.kw_colon) ": " else " ");
            }
            try self.w(arg.text);
        }
    }

};

test "script: an empty script prints an empty file" {
    const s = Script{};
    const text = try print(std.testing.allocator, &s);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}
