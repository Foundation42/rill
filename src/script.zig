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
        /// `:tight` where `:tight` is a declared HOLE (§3.15) — an argument
        /// deliberately left unbound. Told apart from `stream` because an
        /// editor draws it differently: an open socket, not a wire.
        hole,
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
    /// **Which declared input port this argument binds to**, or null for one
    /// that binds none — a section BODY, an argument the parser consumed into
    /// a static, or a def-call argument in a script that was loaded rather
    /// than parsed.
    ///
    /// `graph.CallSite`'s argument, one level finer, and for the same
    /// customer. That field exists because an editor changing a wire has to
    /// find the `Call` that wrote it; this exists because having found the
    /// call, it then has to find the ARGUMENT — and `args` is the authored
    /// order, where ports are the declared one. The two differ whenever
    /// anything is piped, optional, keyword-bound or a section, which is to
    /// say almost always.
    ///
    /// The parser knows this for certain: `bound[]` IS the mapping, built
    /// from the primary pipe, the kwargs by name, the sections and the
    /// remaining positionals in declared order. Re-deriving those four rules
    /// in `edit.zig` would be a second answer able to drift from the first,
    /// which is the mistake `CallSite`'s own note describes being made once
    /// already.
    port: ?u8 = null,
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

    /// **The `Call` a graph node came from** — the other half of
    /// `graph.CallSite`, and the bridge an editor crosses to change a
    /// program's text.
    ///
    /// A node knows the line and column of the operator token that wrote it;
    /// this finds the `Call` that carries the same pair. The match is exact
    /// rather than approximate because both numbers come from the SAME token,
    /// read twice inside `parseOpcall` — so this is a lookup, not a search
    /// with a tolerance.
    ///
    /// Everywhere a `Call` can hide is walked: the top level, every stage of
    /// every chain, every branch of a fan-out, and every def body (which is a
    /// `Block` exactly as `top` is, which is what makes the recursion three
    /// lines instead of a second traversal). A def's body is walked even
    /// though its nodes are FLATTENED with prefixed names, because the call
    /// that wrote them is in there and nowhere else.
    ///
    /// Null for a site of `{0, 0}` — sugar with no call of its own — and null
    /// for a script that did not come from this program. Both are the same
    /// answer to the caller: there is no text to edit here.
    ///
    /// Takes the two numbers rather than a `graph.CallSite`, because `graph`
    /// imports THIS file and the reverse would be a cycle. `graph.CallSite`
    /// carries the pair; `Node.site.line, Node.site.col` is the call.
    pub fn callAt(self: *const Script, line: u32, col: u32) ?*const Call {
        if (line == 0) return null;
        return findCallIn(self, self.top, .{ .line = line, .col = col });
    }
};

fn findCallIn(sc: *const Script, items: []const Item, site: anytype) ?*const Call {
    for (items) |*it| {
        switch (it.*) {
            .stmt => |*st| {
                if (findCallInStmt(st.head, st.stages, site)) |c| return c;
            },
            .def => |di| {
                if (di < sc.defs.len) {
                    if (findCallIn(sc, sc.defs[di].body, site)) |c| return c;
                }
            },
            .using, .annex => {},
        }
    }
    return null;
}

fn findCallInStmt(head: Head, stages: []const Stage, site: anytype) ?*const Call {
    switch (head) {
        .call => |*c| if (c.line == site.line and c.col == site.col) return c,
        .value => {},
    }
    return findCallInStages(stages, site);
}

fn findCallInStages(stages: []const Stage, site: anytype) ?*const Call {
    for (stages) |*sg| {
        switch (sg.*) {
            .call => |*c| if (c.line == site.line and c.col == site.col) return c,
            .project => {},
            .fan => |*f| for (f.branches) |*b| {
                if (b.head.line == site.line and b.head.col == site.col) return &b.head;
                if (findCallInStages(b.stages, site)) |c| return c;
            },
        }
    }
    return null;
}

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

/// The column a printed line may reach before the printer breaks it.
///
/// **88, and RULED** — Christian, 2026-09-09, reading two of his own lines
/// aloud: *"We still need to do something about these long lines… These are
/// not human friendly."* The two were `roaches`'s 234-character signature and
/// a 128-character colour ramp.
///
/// The number is measured, not borrowed. `kernels/roaches.rill` is the
/// project's exemplar and is four-fifths prose; its `//` lines sit at ~74
/// columns because that is where Christian's hand stops. 88 leaves a stage's
/// arguments room above that without breaking a line that reads fine today —
/// at 80 the corpus loses six lines that nobody has ever complained about,
/// and at 100 `beacon.rill`'s 97-character ramp stays as it is.
///
/// Rejected: 80 (a punched card, and it cuts lines the author is happy with),
/// 100 and 120 (they leave the two lines that started this beat exactly where
/// they were), and "the editor's viewport" (not a property of the file, so
/// two machines would format it two ways).
///
/// Counted in BYTES. Everything a printed line can hold outside a string
/// literal is ASCII, and a string is never broken — so the one thing a
/// multi-byte character can do is make a `describe` sentence look wider than
/// it is, on a line the printer would not have touched anyway.
const width_canon: usize = 88;

/// How far a construct is allowed to break to fit `width_canon`.
///
/// Two values and not a number of levels: every construct here breaks exactly
/// one way (one stage per line, one port per line, one element per line), so
/// the only question is whether it broke.
const Lay = enum { flat, broken };

/// A def's head has two things on it that can break — its signature and, when
/// the body sat on the signature line, the body's chain — so its layout is a
/// pair.
///
/// Those two are SIBLINGS on one line, not one nested in the other, so
/// outermost-first has nothing to say about them: what decides is which half
/// does not fit, measured. `def wobble(x: number) = x | mul 0.05 | … | mul 7`
/// is 93 columns over a 23-column signature, and a first draft that tried the
/// signature first broke that one port across three lines to make room for a
/// chain it then left alone. See `Printer.def` for the order.
const DefLay = struct { sig: Lay, body: Lay };

/// The canon, chosen to read like the corpus Christian reads daily:
///
///   - one statement, one line — **until the line runs past `width_canon`**,
///     and then it breaks, one stage per line with the `|` in the
///     continuation's left margin. That is the shape the four ironwood rills
///     were already hand-writing; what it was NOT, before this beat, was
///     recoverable — so the printer stopped guessing and started DECIDING.
///     The width is the whole of the decision, and the file's own wrapping is
///     normalised away exactly as its indentation is (Christian's ruling on
///     indentation, applied to the same question: the printer decides).
///   - the break is OUTERMOST FIRST. A statement breaks its chain; a stage
///     breaks its `[…]`/`{…}` argument only if the line it landed on is
///     STILL too long; a def breaks the half of its head that does not fit.
///     Nothing breaks eagerly, and a construct that would gain nothing by
///     breaking (no stages, no span) is left flat rather than churned.
///   - a span that does break is laid out by its COUNT, not by its contents
///     — a few stack one per line, many pack into a grid, and a perfect
///     square packs into a square. See `gridFor`; Christian ruled it.
///   - everything nested indents by four — a def body, a `describe` block's
///     lines, a fan-out's branches, and every continuation above.
///     Christian's ruling; see `indent_canon`.
///   - a `describe` block also pads its keys into a column so the values line
///     up. `kernels/roaches.rill` hand-aligns eleven ports, and at that width
///     the column is what makes the block readable, not decoration. Its lines
///     are the one thing the width does NOT touch: a `describe` line is a key
///     and one string, eleven of roaches's twelve run past 88 columns, and a
///     string cannot be broken without changing the value it holds.
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

    /// The widest line written since `mark`, in bytes. `mark` is always taken
    /// at the start of a line, and the tail with no newline after it counts —
    /// it is the line still being built.
    fn widestSince(self: *Printer, mark: usize) usize {
        const s = self.out.items[mark..];
        var widest: usize = 0;
        var start: usize = 0;
        for (s, 0..) |c, i| {
            if (c != '\n') continue;
            widest = @max(widest, i - start);
            start = i + 1;
        }
        return @max(widest, s.len - start);
    }

    /// Where the line currently being written began.
    fn lineStart(self: *Printer) usize {
        const s = self.out.items;
        var i = s.len;
        while (i > 0) : (i -= 1) {
            if (s[i - 1] == '\n') return i;
        }
        return 0;
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
                // Render it flat, and if that runs past the width render it
                // again with the chain broken; keep the first that fits, and
                // if neither does keep the NARROWER — the earlier of equals,
                // so a statement with nothing to break (no stages, no span)
                // stays on the one line it was on rather than being churned
                // into an identical shape for no gain.
                const mark = self.out.items.len;
                var best: Lay = .flat;
                var best_w: usize = std.math.maxInt(usize);
                for ([_]Lay{ .flat, .broken }) |lay| {
                    try self.indent(col);
                    try self.stmt(st, col, lay);
                    try self.trail(st.trail);
                    const wide = self.widestSince(mark);
                    self.out.shrinkRetainingCapacity(mark);
                    if (wide <= width_canon) {
                        best = lay;
                        break;
                    }
                    if (wide < best_w) {
                        best = lay;
                        best_w = wide;
                    }
                }
                try self.indent(col);
                try self.stmt(st, col, best);
                try self.trail(st.trail);
                try self.w("\n");
            },
            .def => |idx| try self.def(&self.script.defs[idx], col),
            .using => |u| {
                try self.lead(u.lead, col);
                try self.blanks(u.blank_before);
                try self.indent(col);
                try self.w("using ");
                // **A `using` body is a span like any other.** Christian,
                // 2026-09-12, hoisting a colour table out of a chain: *"maybe
                // we should hoist that constant record up to a using — I just
                // think it's more idiomatic."* It is, and the parser now lets
                // one span lines — but until this line `fmt` collapsed it
                // straight back onto one, so format-on-save undid the hoist
                // the moment it was written.
                //
                // `fitValue` and not a layout of its own: `over 16 […]` in
                // `roaches.rill` is the same four records breaking the same
                // way, and two layouts for one construct is how a file starts
                // printing two ways. The reserve is what still has to fit
                // after the span closes.
                try self.fitValue(u.body, col, " as ".len + u.name.len);
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
        const inlined = d.inline_body and d.body.len == 1 and d.body[0] == .stmt;
        const mark = self.out.items.len;

        var best = DefLay{ .sig = .flat, .body = .flat };
        try self.defHead(d, col, inlined, best);
        var best_w = self.widestSince(mark);
        self.out.shrinkRetainingCapacity(mark);

        if (best_w > width_canon) {
            // WHICH HALF does not fit decides which one breaks first — see
            // `DefLay`. Measure the signature alone, up to the `=`: if that
            // is over the width the signature is the problem, and otherwise
            // the body is. Breaking BOTH is the second guess either way, and
            // the other half alone is the last, for the case where the half
            // that looked innocent turns out to have the columns.
            try self.defSignature(d, col, .flat);
            const sig_over = self.widestSince(mark) > width_canon;
            self.out.shrinkRetainingCapacity(mark);
            const order: [3]DefLay = if (sig_over) .{
                .{ .sig = .broken, .body = .flat },
                .{ .sig = .broken, .body = .broken },
                .{ .sig = .flat, .body = .broken },
            } else .{
                .{ .sig = .flat, .body = .broken },
                .{ .sig = .broken, .body = .broken },
                .{ .sig = .broken, .body = .flat },
            };
            for (order) |cand| {
                try self.defHead(d, col, inlined, cand);
                const wide = self.widestSince(mark);
                self.out.shrinkRetainingCapacity(mark);
                if (wide <= width_canon) {
                    best = cand;
                    break;
                }
                // Nothing fits: keep the narrowest, and the flat form when
                // breaking would gain nothing — a def with one port and a
                // body that cannot be shortened stays the line it was.
                if (wide < best_w) {
                    best = cand;
                    best_w = wide;
                }
            }
        }
        try self.defHead(d, col, inlined, best);
        try self.w("\n");
        if (inlined) return;
        for (d.body) |b| try self.item(b, col + indent_canon);
    }

    /// A definition's first line: the signature, the plane, the `=`, and the
    /// body when the body sat on it. Everything up to but not including the
    /// newline, so the caller can render it twice and keep one.
    fn defHead(self: *Printer, d: *const Def, col: u32, inlined: bool, lay: DefLay) Oom!void {
        try self.defSignature(d, col, lay.sig);
        if (inlined) {
            try self.w(" ");
            try self.stmt(d.body[0].stmt, col, lay.body);
            try self.trail(if (d.trail.len > 0) d.trail else d.body[0].stmt.trail);
            return;
        }
        try self.trail(d.trail);
    }

    /// `[export ]def name(ports…)[ on plane] =` — everything before the body,
    /// which is the half whose width decides whether the SIGNATURE is what
    /// does not fit.
    fn defSignature(self: *Printer, d: *const Def, col: u32, lay: Lay) Oom!void {
        try self.indent(col);
        if (d.exported) try self.w("export ");
        try self.w("def ");
        try self.w(d.name);
        try self.w("(");
        for (d.ports, 0..) |port, i| {
            if (lay == .broken) {
                // The comma closes the port BEFORE the break, and the `)`
                // takes the last one's place — so no trailing comma. The
                // parser accepts one (see `parseDef`); the printer writes the
                // one canon, and it is the same canon an array keeps.
                if (i > 0) try self.w(",");
                try self.w("\n");
                try self.indent(col + indent_canon);
            } else if (i > 0) try self.w(", ");
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
        // A broken signature closes in the left margin, where the `)` and the
        // `= body` after it read as the end of the head rather than as a
        // twelfth port. With no ports at all there is nothing to break, and
        // the two layouts are the same bytes.
        if (lay == .broken and d.ports.len > 0) {
            try self.w("\n");
            try self.indent(col);
        }
        try self.w(")");
        if (d.on.len > 0) {
            try self.w(" on ");
            try self.w(d.on);
        }
        try self.w(" =");
    }

    fn stmt(self: *Printer, st: Stmt, col: u32, lay: Lay) Oom!void {
        const tail = suffix(st);
        switch (st.head) {
            // A head with stages after it ends its line where they break, so
            // it reserves nothing; a head that is the WHOLE statement carries
            // the `as` names and the trailing comment on its own line.
            .call => |c| if (lay == .broken)
                try self.fitCall(c, col, if (st.stages.len == 0) tail else 0)
            else
                try self.call(c, col, .flat),
            .value => |v| if (lay == .broken)
                try self.fitValue(v, col, if (st.stages.len == 0) tail else 0)
            else
                try self.w(v),
        }
        try self.stages(st.stages, col, lay, tail);
        // `as` names ride the LAST line rather than getting one of their own:
        // that is where they sit in the flat spelling and where the parser
        // reads them, and a lone `as fade` under a chain reads like a stage.
        for (st.names, 0..) |n, i| {
            try self.w(if (i == 0) " as " else ", ");
            try self.w(n);
        }
    }

    /// What the caller will still append to the last line of a statement: the
    /// `as` names, and a trailing `// …` with the two spaces before it.
    ///
    /// A span is broken a construct at a time, BEFORE those are written, so a
    /// decision that ignored them measures the wrong line. It did: the first
    /// draft left `rills/follow.rill:19` alone at 96 columns, because the
    /// array on it is 87 and ` as track` is the other nine.
    fn suffix(st: Stmt) usize {
        var n: usize = 0;
        for (st.names, 0..) |name, i| n += @as(usize, if (i == 0) 4 else 2) + name.len;
        if (st.trail.len > 0) n += 2 + st.trail.len;
        return n;
    }

    /// The separator before a stage: ` | ` flat, and a break to the canon
    /// indent with the `|` in that continuation's left margin when broken.
    /// No statement can begin with a pipe, so a leading `|` has never had a
    /// second meaning — `parser.continuesWithPipe` is the other half of this.
    fn pipe(self: *Printer, lay: Lay, scol: u32) Oom!void {
        if (lay == .flat) return self.w(" | ");
        try self.w("\n");
        try self.indent(scol);
        try self.w("| ");
    }

    fn stages(self: *Printer, list: []const Stage, col: u32, lay: Lay, tail: usize) Oom!void {
        const scol = if (lay == .broken) col + indent_canon else col;
        for (list, 0..) |sg, i| {
            // Only the last stage shares its line with what follows the chain.
            const reserve = if (i + 1 == list.len) tail else 0;
            switch (sg) {
            .call => |c| {
                try self.pipe(lay, scol);
                if (lay == .broken) try self.fitCall(c, scol, reserve) else try self.call(c, scol, .flat);
            },
            .project => |f| {
                try self.pipe(lay, scol);
                try self.w(f);
            },
            .fan => |f| {
                // The head-block form has no `also`: the head IS the source,
                // so its `{` stays glued to the head's line and its branches
                // measure from the head's column, not from a continuation's.
                const own: u32 = if (f.spelled_also) scol else col;
                if (f.spelled_also) {
                    try self.pipe(lay, scol);
                    try self.w("also {");
                } else try self.w(" {");
                if (f.branches.len == 1 and f.branches[0].lead.len == 0) {
                    try self.w(" ");
                    try self.branch(f.branches[0], own, .flat, 0);
                    try self.w(" }");
                    continue;
                }
                try self.w("\n");
                for (f.branches) |b| {
                    try self.lead(b.lead, own + indent_canon);
                    try self.blanks(b.blank_before);
                    try self.fitBranch(b, own + indent_canon);
                    try self.w("\n");
                }
                try self.indent(own);
                try self.w("}");
            },
            }
        }
    }

    /// One branch of a fan-out block, on its own line, with the statement's
    /// own cascade over it — a branch IS a chain, and a long one wraps the
    /// same way a top-level one does.
    fn fitBranch(self: *Printer, b: Branch, col: u32) Oom!void {
        const mark = self.out.items.len;
        const tail: usize = if (b.trail.len > 0) 2 + b.trail.len else 0;
        var best: Lay = .flat;
        var best_w: usize = std.math.maxInt(usize);
        for ([_]Lay{ .flat, .broken }) |lay| {
            try self.indent(col);
            try self.branch(b, col, lay, tail);
            try self.trail(b.trail);
            const wide = self.widestSince(mark);
            self.out.shrinkRetainingCapacity(mark);
            if (wide <= width_canon) {
                best = lay;
                break;
            }
            if (wide < best_w) {
                best = lay;
                best_w = wide;
            }
        }
        try self.indent(col);
        try self.branch(b, col, best, tail);
        try self.trail(b.trail);
    }

    fn branch(self: *Printer, b: Branch, col: u32, lay: Lay, tail: usize) Oom!void {
        if (lay == .broken)
            try self.fitCall(b.head, col, if (b.stages.len == 0) tail else 0)
        else
            try self.call(b.head, col, .flat);
        try self.stages(b.stages, col, lay, tail);
    }

    /// Emit one call, and if the line it landed on is STILL over the width,
    /// throw it away and emit it again with its spans broken.
    ///
    /// This is outermost-first doing its work, and it is deliberately LOCAL:
    /// by the time this runs the chain has already been broken, so a span is
    /// only ever broken because the one line it is on is too long by itself.
    /// Reached only from `.broken` layouts for the same reason.
    fn fitCall(self: *Printer, c: Call, col: u32, reserve: usize) Oom!void {
        const mark = self.out.items.len;
        const start = self.lineStart();
        try self.call(c, col, .flat);
        if (self.out.items.len - start + reserve > width_canon) {
            self.out.shrinkRetainingCapacity(mark);
            try self.call(c, col, .broken);
        }
    }

    /// The same, for a statement head that is a value rather than a call —
    /// `[{x: 0, …}, …] as track` is a whole statement with no stages to
    /// break, so the span is the only thing there is.
    fn fitValue(self: *Printer, v: []const u8, col: u32, reserve: usize) Oom!void {
        const start = self.lineStart();
        if (self.out.items.len - start + v.len + reserve > width_canon) {
            if (try self.breakSpan(v, col)) return;
        }
        try self.w(v);
    }

    fn call(self: *Printer, c: Call, col: u32, lay: Lay) Oom!void {
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
            // EVERY span argument on an over-width line breaks, not the
            // longest one: which of two arguments is "the long one" is a
            // judgement, and a judgement here would print one file two ways
            // depending on what else was on the line. Almost every call in
            // the corpus has at most one.
            if (lay == .broken and (arg.kind == .array or arg.kind == .record)) {
                if (try self.breakSpan(arg.text, col)) continue;
            }
            try self.w(arg.text);
        }
    }

    /// `[a, b, c]` → a broken span, laid out by `gridFor`, with the closer
    /// back in `col`. Returns false, having written nothing, when `text` is
    /// not a span this can split — a path, a number, a `(…)` section, an
    /// empty `[]`.
    ///
    /// A SCAN and not a parse: `text` is what `renderTokens` produced, so the
    /// spacing is already canonical and the only things that can hide a comma
    /// are a nested span and a string literal. The elements come back trimmed
    /// and are re-joined with the printer's own commas, which is what makes a
    /// hand-written trailing comma normalise away and the second print equal
    /// the first.
    ///
    /// Two passes: one to count the elements and find the widest, one to lay
    /// them out. Both are scans over text the printer already has, and the
    /// layout is a pure function of it — which is what keeps the second print
    /// equal to the first.
    fn breakSpan(self: *Printer, text: []const u8, col: u32) Oom!bool {
        if (text.len < 2) return false;
        const close: u8 = switch (text[0]) {
            '[' => ']',
            '{' => '}',
            else => return false,
        };
        if (text[text.len - 1] != close) return false;
        const inner = text[1 .. text.len - 1];
        if (std.mem.trim(u8, inner, " ").len == 0) return false;

        var count: usize = 0;
        var widest: usize = 0;
        var scan = SpanIter{ .text = inner };
        while (scan.next()) |piece| {
            if (piece.len == 0) continue;
            count += 1;
            widest = @max(widest, piece.len);
        }
        if (count == 0) return false;

        const at = col + indent_canon;
        const grid = gridFor(count, widest, if (width_canon > at) width_canon - at else 0);

        try self.w(text[0..1]);
        var it = SpanIter{ .text = inner };
        var i: usize = 0;
        while (it.next()) |piece| {
            if (piece.len == 0) continue;
            if (i > 0) try self.w(",");
            if (i % grid.cols == 0) {
                try self.w("\n");
                try self.indent(at);
            } else {
                try self.w(" ");
            }
            // RIGHT-ALIGNED, when there is a column to align in. Two reasons
            // and the second is the one that decided it: a ramp's numbers
            // line up on the digit that says how big they are, and the comma
            // stays glued to the value it closes. Padding on the right puts
            // `0      ,` in the file, which is a column of commas nobody
            // asked for.
            if (grid.pad and piece.len < widest) try self.indent(@intCast(widest - piece.len));
            try self.w(piece);
            i += 1;
        }
        try self.w("\n");
        try self.indent(col);
        try self.w(text[text.len - 1 ..]);
        return true;
    }
};

/// The most elements a broken span keeps stacked one to a line.
///
/// Eight — Christian's *"five you wouldn't"* with headroom. It is not a
/// guess about taste: every record array in the 47-file corpus is three to
/// seven elements and every one of them reads better stacked, while the
/// arrays that want packing are the three generated ramps at 121. Nothing in
/// the corpus sits between 8 and 121, so the threshold is a wide gap rather
/// than a line drawn through the evidence.
const span_stack_max: usize = 8;

/// How a span that must break is laid out.
const Grid = struct {
    /// Elements to a line. `1` is "one per line" — not a special case here,
    /// just what this returns for a few elements or for wide ones.
    cols: usize,
    /// Pad each element into a column. False for a ragged fill, where the
    /// last row is short and there is no column to line up with.
    pad: bool,
};

/// Christian's ruling, 2026-09-09:
///
/// > *"I'd lean towards smart wrapping. A hundred records you'd want to pack,
/// > five you wouldn't, and maybe if we know the denominator, we can be smart
/// > about how many per row. a series of 16 looks good as 4x4, or 9 look good
/// > as 3x3."*
///
/// So the axis is COUNT AND SHAPE, never what the elements are. `room` is the
/// columns left on a continuation line after its indent.
///
/// A SQUARE BEATS A FILL. 16 reads as 4×4 because that is what 16 is, not
/// because four is the most that happened to fit — which is why the perfect
/// square is tried before the divisor and the divisor before the fill.
fn gridFor(n: usize, widest: usize, room: usize) Grid {
    if (n <= span_stack_max) return .{ .cols = 1, .pad = false };
    var fit: usize = 1;
    while (fitsRow(fit + 1, widest, room)) fit += 1;
    // Wide elements fall out here rather than needing a branch of their own:
    // if two will not sit side by side, one per line is the answer again.
    if (fit <= 1) return .{ .cols = 1, .pad = false };

    const root = std.math.sqrt(n);
    if (root * root == n and root <= fit) return .{ .cols = root, .pad = true };

    // …then the largest exact divisor that fits, so the block closes square
    // with no ragged tail: 120 numbers twelve wide is a clean 12×10.
    var d = fit;
    while (d >= 2) : (d -= 1) {
        if (n % d == 0) return .{ .cols = d, .pad = true };
    }

    // …and a prime or otherwise awkward count fills as far as it fits,
    // UNPADDED — the last row is short, so there is no column to keep.
    return .{ .cols = fit, .pad = false };
}

/// Does a row of `cols` padded elements fit in `room`? The elements, the
/// two-character separators between them, and the comma that closes the row.
fn fitsRow(cols: usize, widest: usize, room: usize) bool {
    return cols * widest + (cols - 1) * 2 + 1 <= room;
}

/// The top-level elements of a rendered span's interior.
///
/// Depth over the three bracket pairs, and a string's interior skipped: a
/// `,` inside `"a, b"` is not a separator and a `\"` does not close the
/// string. Nothing else can hide one, because the text this walks was
/// rendered by the parser's own `renderTokens`.
/// **The top-level elements of a rendered span's interior**, comma-separated,
/// nesting and strings respected.
///
/// `pub` since 2026-09-12: `edit.setFoldField` walks a `using` body with it.
/// That is the same job from the other side — the printer scans a rendered
/// span to lay it out, and an editor scans the same text to change one piece
/// of it — and a second scanner would be a second answer to "where does this
/// element end", which is exactly the sort of pair that drifts.
pub const SpanIter = struct {
    text: []const u8,
    at: usize = 0,

    pub fn next(self: *SpanIter) ?[]const u8 {
        if (self.at >= self.text.len) return null;
        const start = self.at;
        var depth: usize = 0;
        var in_string = false;
        while (self.at < self.text.len) : (self.at += 1) {
            const c = self.text[self.at];
            if (in_string) {
                if (c == '\\') self.at += 1 else if (c == '"') in_string = false;
                continue;
            }
            switch (c) {
                '"' => in_string = true,
                '[', '{', '(' => depth += 1,
                ']', '}', ')' => depth -|= 1,
                ',' => if (depth == 0) {
                    const piece = self.text[start..self.at];
                    self.at += 1;
                    return std.mem.trim(u8, piece, " ");
                },
                else => {},
            }
        }
        return std.mem.trim(u8, self.text[start..self.at], " ");
    }
};

test "script: an empty script prints an empty file" {
    const s = Script{};
    const text = try print(std.testing.allocator, &s);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}
