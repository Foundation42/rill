//! parser — text → flat graph.
//!
//! The pipe is the 90% case and parses exactly as the console does today:
//! `cube 2 | bevel 0.1 | rot 45`. Syntax complexity is paid only at the
//! joints: `as` names an edge (fan-out), a bare name in argument position
//! pulls a stream in (fan-in), `{…}` builds a live record, and any `plane.…`
//! path in any argument position is a subscription — there is no special
//! subscribe form. `using plane.player as :p` (§3.10) binds a FOLD — a
//! sequence of tokens captured verbatim — and `:p` splices them back in
//! wherever a token may appear, so `:p.health` is `plane.player.health`
//! before the graph exists, unknown bare names stay loud errors, and nothing
//! downstream of the parser knows folds exist.
//!
//! Structural consequences the rest of the library leans on:
//!
//! - Local names are single-assignment and must be defined before use, so
//!   **parse order is topological order**. The evaluator never sorts. The
//!   accepted consequence is that the text is the schedule: a client that
//!   serialises a graph back to text (the visual editor) must emit
//!   statements in dependency order, not box-creation order.
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
//! - A statement head followed by `{ … }` is the SAME fan-out with the head
//!   as the source — the `also` rule generalised to any source (`every 1f
//!   { cast … }`, rill-casts.md note §5). A `{` in argument position opens a
//!   record only when it opens like one (`{name:`); otherwise it ends the
//!   argument list and belongs to the statement. Head position only:
//!   mid-chain side branches keep the `also` spelling.
//! - `$name` is a field-channel name, sigil included, one token. It appears
//!   as `cast`'s channel static and inside plane-path segments
//!   (`sensors.gate.$alarm`); a BARE `$name` stream is refused with the v1
//!   ruling in the message (fields are read at a standpoint), and no local
//!   name, alias, def, port, or operator may wear the sigil.
//! - `also { … }` is fan-out spelled inline, and it is **pure desugaring**:
//!   `x | also { S } | rest` is `x as ⟨anon⟩` + `⟨anon⟩ | S` + `⟨anon⟩ | rest`.
//!   The parser does not even need the anonymous name — the in-flowing value
//!   is already a `Source`, so the block's branch and the main wire are handed
//!   the same one and `current` is never reassigned. Identity on the stream
//!   therefore holds *by construction*, not by an op-level passthrough class,
//!   and N occurrences run the block N times because it is ordinary fan-out.
//!   No new node kind, no evaluator change.
//! - A bare word bound to a *string-typed* port becomes a string literal at
//!   the bind moment — the console's entity names (`volume set v1 …`) are
//!   strings, and the port type keeps the coercion narrow: local names
//!   resolve first, and an unknown word anywhere else stays a loud error. A
//!   `one_of` port additionally checks a bound literal's membership at parse.
//! - `using <tokens…> as :name` is a parse-time MACRO (§3.10, 2026-09-08,
//!   replacing `use`): the tokens between `using` and the trailing `as` are
//!   captured unparsed, and `:name` splices them into the stream wherever a
//!   token may appear — argument position included, which is the thing `def`
//!   structurally cannot do (`instantiate` is only reachable from opcall
//!   position). Substitution composes with what follows (`:k.flock`), two
//!   splices of one fold build two independent node sets (same as `def`'s
//!   flattening), and expansion is recursive. The cost is error LOCALITY: a
//!   refusal can land on a token nobody typed, so every spliced token carries
//!   its expansion chain and `fail` appends it.
//! - A `tail` port (last input only, §3.11) binds the rest of the line
//!   *verbatim from the raw source* as a string literal — locators like
//!   `/tmp/loop.wav` and `pack:horns#audio.stem` are text, not structure.
//!   The tokenizer therefore rejects no character: unknown bytes become inert
//!   `raw` tokens that only error when a non-tail position consumes one.
//! - A def port carries a PARAMETER PACK (§3.9, 2026-09-08): an optional
//!   default (`rate = 60`) that makes the port optional at the call site, an
//!   advisory range (`(0..500)`) that nothing enforces, and — through a
//!   separate `describe` block — one sentence per port. `export def` marks a
//!   definition visible to the HOST; rill has no imports and no cross-file
//!   reference, so that is all visibility can mean here, and the pack of an
//!   exported def is the ONE thing that survives the parse that flattens its
//!   body away (`Program.exports`). For an exported def the descriptions are
//!   mandatory, checked both ways: no port may be undescribed, and no
//!   describe line may name a port that does not exist. A local def is not
//!   enumerable, needs no prose, and vanishes exactly as it always did.
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
    duration, // number glued to a unit suffix: 5s, 250ms, 2m, 3f
    string, // raw span between quotes (escapes not yet applied)
    sym, // = != < <= > >=
    pipe,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    colon,
    /// `:name` — a fold reference (§3.10), sigil included, one token, exactly
    /// as `$chan` is. `colonOpensFold` says when a `:` spells one.
    fold,
    comma,
    dot,
    /// `..` — the range separator, and nowhere else in the language
    /// (`def f(rate = 60 (0..500))`, §3.9). Additive by construction: two
    /// adjacent dots have never been legal anywhere a token is read — a
    /// number could swallow them (`0..500` lexed as one number and died as
    /// "bad number"), and outside a number they lexed as two `.dot`s and died
    /// as a projection with no field name.
    dotdot,
    newline,
    raw, // a character with no token of its own; legal only inside a tail
    eof,
};

const Token = struct {
    kind: TokKind,
    text: []const u8,
    line: u32,
    col: u32,
    /// Byte offset of the token's first character (a string's opening quote
    /// included) — tail capture slices the raw source between offsets.
    off: usize,
    /// Provenance: 0 when the author typed this token; otherwise 1 + an index
    /// into `Parser.fold_sites` — the expansion that spliced it in. This is
    /// what pays for the one thing `using` costs that `use` did not: a
    /// refusal on a token nobody wrote can still say whose it is.
    fold: u32 = 0,
};

/// The syntax's own words. Owned by the registry (which gates registration on
/// them) so there is exactly one list and an op can never be shadowed silently.
const isReservedWord = registry.isReservedWord;

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Name-interior characters, before the joining rules: `/` and `-` are
/// handled in the tokenizer loop, because both are name-interior only when
/// they JOIN two name characters. For `/` (never a name start — rill has no
/// `/` operator, division is the `div` word) the joining rule is what makes
/// `//`-comments sound: `render/grade/exposure` is one word, but a name can
/// never hold two adjacent slashes, so every `//` sits at a token boundary.
fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isSigil(c: u8) bool {
    return c == '$' or c == '@' or c == '#' or c == '^';
}

/// Does the `:` at `i` open a FOLD reference (`:flock`) rather than one of
/// the four colons rill already had?
///
/// `:` was live in four places before `using` existed — a def port type
/// (`def f(x: number)`), a record literal (`{l: 0.28}`), a shape literal, and
/// the colon-kwarg spelling (`cast $chan at: row.pos`) — and all four glue
/// the colon to the name BEFORE it. A fold reference glues it to the name
/// AFTER. So **adjacency decides, not position**, and the rule is a
/// whitelist: a fold colon is preceded by start-of-input, whitespace, or an
/// opener (`( [ { , |`), and followed immediately by a name (or a sigil, so
/// `:$x` reaches the parser and is refused *by name* rather than lexing into
/// two tokens and getting "unexpected ':'").
///
/// Position alone would NOT have been enough. `parseArgs` decides a kwarg on
/// a `.name`-then-`.colon` lookahead, so `radius 12 at :flock` would have
/// read `at:` as the kwarg and `flock` as its value — the keyword pairing
/// silently eating the fold. Adjacency separates the two spellings before the
/// parser ever looks.
fn colonOpensFold(src: []const u8, i: usize) bool {
    if (i + 1 >= src.len) return false;
    const nx = src[i + 1];
    const opens_name = isNameStart(nx) or
        (isSigil(nx) and i + 2 < src.len and isNameStart(src[i + 2]));
    if (!opens_name) return false;
    if (i == 0) return true;
    return switch (src[i - 1]) {
        ' ', '\t', '\r', '\n', '(', '[', '{', ',', '|' => true,
        else => false,
    };
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
        const to = i;
        if (c == '\n') {
            try toks.append(a, .{ .kind = .newline, .text = src[i .. i + 1], .line = tl, .col = tc, .off = to });
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
        // `//` opens a comment, to end of line (ruled 2026-08-25: `#` is the
        // tag sigil and cannot also be the comment lead; `//` matches the
        // house language and collides with none of the four sigils). The
        // token-boundary pin is structural, not positional: a name-interior
        // `/` must JOIN two name characters (below, same license `-` has), so
        // no slash-form path literal can hold two adjacent slashes inside a
        // token — `render/grade/exposure` never trips this, and any `//` the
        // tokenizer meets sits at a boundary by construction. Inside a tail
        // it is still text: the tail slices the raw source to end of line,
        // and the skipped tokens were never going to be consumed.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') : (i += 1) col += 1;
            continue;
        }
        // `-` opens a name when it does NOT open a negative number — the
        // console's unbind sentinel (`light arche l1 -`) is a word, and
        // rill has no infix minus (subtraction is the `sub` word).
        // All four sigils open a name when a name follows: `$alarm`, `@tom`,
        // `#garrison`, `^raider` are one token each, sigil included
        // (rill-casts.md §3, ironwood R6; `#` since T3, `^` since T5 — the
        // derive grammar names a population archetype, and the console rides
        // this tokenizer). Sigils are name-LEAD only — a lone sigil stays an
        // inert raw token.
        if (isNameStart(c) or
            ((c == '$' or c == '@' or c == '#' or c == '^') and i + 1 < src.len and isNameStart(src[i + 1])) or
            (c == '-' and (i + 1 >= src.len or !std.ascii.isDigit(src[i + 1]))))
        {
            const start = i;
            i += 1;
            col += 1;
            // `-` and `/` are name-INTERIOR when they join two name
            // characters: `key-light` is one entity name, `render/grade/
            // exposure` is one knob path. A lone `-` is still the unbind
            // sentinel, `-5` is still a negative number, and `//` is always
            // a comment, because all three fail the "joins two name
            // characters" test — and rill has no infix minus or slash
            // (subtraction is `sub`, division is `div`), so nothing else
            // wants these spellings. Without the `-` rule every hyphenated
            // name an authoring tool produces is unsayable: `light move
            // key-light 1 2 3` arrives as five arguments for a four-port row.
            while (i < src.len and (isNameChar(src[i]) or
                ((src[i] == '-' or src[i] == '/') and i + 1 < src.len and isNameChar(src[i + 1])))) : (i += 1) col += 1;
            try toks.append(a, .{ .kind = .name, .text = src[start..i], .line = tl, .col = tc, .off = to });
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
                // A `..` belongs to the RANGE, not to the number: without
                // this, `0..500` is one `.number` token whose text no
                // `parseFloat` accepts, and the range spelling is unsayable.
                // The number is what has to yield, because `0.` is a number
                // and `.` is a token, so only the number lexer can see both
                // dots at once.
                if (src[i] == '.' and i + 1 < src.len and src[i + 1] == '.') break;
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
            // A unit suffix glued to the number is a duration literal
            // (§3.13): 5s, 250ms, 2m, 3f. Only the *shape* is spotted here —
            // the parser validates the unit, so `5x` errors loud instead of
            // splitting into a number and a name. Alphabetic only: `1/2`
            // stays number-raw-number and keeps its own loud error.
            if (i < src.len and std.ascii.isAlphabetic(src[i])) {
                while (i < src.len and std.ascii.isAlphabetic(src[i])) : (i += 1) col += 1;
                try toks.append(a, .{ .kind = .duration, .text = src[start..i], .line = tl, .col = tc, .off = to });
                continue;
            }
            try toks.append(a, .{ .kind = .number, .text = src[start..end], .line = tl, .col = tc, .off = to });
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
            try toks.append(a, .{ .kind = .string, .text = src[start..i], .line = tl, .col = tc, .off = to });
            i += 1;
            col += 1;
            continue;
        }
        // `:name` — one token, colon included, the way `$chan` is one token
        // sigil included. Additive by construction: every other `:` in the
        // language glues to the name on its LEFT (see `colonOpensFold`), and
        // a leading `:` in value or operator position was a parse error in
        // every program that could ever have been written.
        if (c == ':' and colonOpensFold(src, i)) {
            const start = i;
            var j = i + 1;
            if (isSigil(src[j])) j += 1; // refused in the parser, by name
            j += 1; // the name's first character — `colonOpensFold` checked it
            while (j < src.len and (isNameChar(src[j]) or
                ((src[j] == '-' or src[j] == '/') and j + 1 < src.len and isNameChar(src[j + 1])))) : (j += 1)
            {}
            col += @intCast(j - i);
            try toks.append(a, .{ .kind = .fold, .text = src[start..j], .line = tl, .col = tc, .off = to });
            i = j;
            continue;
        }
        const two = if (i + 1 < src.len) src[i .. i + 2] else src[i .. i + 1];
        if (std.mem.eql(u8, two, "!=") or std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, ">=")) {
            try toks.append(a, .{ .kind = .sym, .text = two, .line = tl, .col = tc, .off = to });
            i += 2;
            col += 2;
            continue;
        }
        // `..` before `.`, so a range separator never lexes as two
        // projections. (The number lexer already stopped short of it.)
        if (std.mem.eql(u8, two, "..")) {
            try toks.append(a, .{ .kind = .dotdot, .text = two, .line = tl, .col = tc, .off = to });
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
            // Beat 2: `[` and `]` become tokens of their own. Until now they
            // were `.raw` — legal only inside a tail — so this is additive by
            // construction: no existing program could hold a bracket outside
            // a tail without already failing loud. Tails are unaffected, and
            // gated so: a tail slices the RAW SOURCE between token offsets
            // and never reads a token's kind, so `[a, b]` inside one is still
            // captured verbatim, brackets and all.
            '[' => .lbracket,
            ']' => .rbracket,
            ':' => .colon,
            ',' => .comma,
            '.' => .dot,
            '=', '<', '>' => .sym,
            // No character is rejected here: a `/` or `'` may be tail text
            // (§3.11), and the tokenizer cannot know. It errors at the parser
            // instead, when a non-tail position actually consumes it.
            else => .raw,
        };
        try toks.append(a, .{ .kind = kind, .text = src[i .. i + 1], .line = tl, .col = tc, .off = to });
        i += 1;
        col += 1;
    }
    try toks.append(a, .{ .kind = .eof, .text = "", .line = line, .col = col, .off = src.len });
    return toks.items;
}

// ---------------------------------------------------------------------------
// Def templates
// ---------------------------------------------------------------------------

/// One declared port of a `def`, and — since 2026-09-08 — its parameter pack:
/// a default that makes the port optional at the call site, an advisory range,
/// and the line of prose a `describe` block gave it. Blade3D's
/// `[OperatorParameter(Description=…, DefaultValue=…, MinValue=…, MaxValue=…)]`,
/// which is where the idea comes from: one declaration is the signature, the
/// widget, the documentation and the validation at once.
///
/// `default`, `min` and `max` hold struple-encoded literals, allocated in the
/// program arena, so a default is spliced into a call as an ordinary
/// `.literal` Source and needs no new node kind, no new Source case, and
/// nothing in the evaluator.
const PortDecl = struct {
    name: []const u8,
    ty: types.TypeId,
    default: ?[]const u8 = null,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
    /// Filled by a later `describe` block, never at the signature. Prose does
    /// nothing at runtime, so it lives where it reads best; a default is
    /// behaviour and stays inline where it cannot drift (Christian's ruling,
    /// carried over from SPL).
    doc: []const u8 = "",
    /// Where the port name was written — the caret for a parity refusal.
    tok: Token,
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
    /// `export def` — visible to the HOST (rill has no imports and no
    /// cross-file reference, so there is nothing else for visibility to mean).
    /// The one thing it changes here: descriptions become mandatory, and the
    /// pack survives the parse on `Program.exports`.
    exported: bool = false,
    /// The definition's own description, from the leading bare string of its
    /// `describe` block.
    doc: []const u8 = "",
    /// Whether a `describe` block was seen at all — distinct from `doc.len`,
    /// because a block may describe every port and skip the leading string.
    described: bool = false,
    /// The name token, so the end-of-parse parity refusal has a caret.
    name_tok: Token,
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

/// A bound fold: tokens, unparsed, plus where the binding was written so a
/// refusal on one of them can point back at it.
const Fold = struct {
    body: []const Token,
    def_line: u32,
};

/// One splice. `via` is the site of the expansion that produced the `:name`
/// token being expanded here (0 when the author wrote it), which makes the
/// chain both the provenance trail and the recursion stack.
const FoldSite = struct {
    name: []const u8,
    def_line: u32,
    via: u32,
};

/// How deep a chain of folds may nest before the parser calls it a runaway.
/// A true cycle is caught by name below and reported as one; this is the
/// backstop for a chain that is merely absurd.
const max_fold_depth: u32 = 32;

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

/// A producer's non-first output riding a pipe, by name (see the pipe site).
const Carried = struct { name: []const u8, src: Source };

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
    return parseWith(gpa, reg, program_name, source, diag, false);
}

/// Parse a KERNEL — a rill mounted on a spray (spec §3.16). Same grammar,
/// one difference: row words bind. A host mounts the result with
/// `row.Runtime.mount`, which is where non-row-legal ops are refused.
pub fn parseKernel(
    gpa: std.mem.Allocator,
    reg: *registry.Registry,
    program_name: []const u8,
    source: []const u8,
    diag: *Diag,
) ParseError!Program {
    return parseWith(gpa, reg, program_name, source, diag, true);
}

fn parseWith(
    gpa: std.mem.Allocator,
    reg: *registry.Registry,
    program_name: []const u8,
    source: []const u8,
    diag: *Diag,
    rows: bool,
) ParseError!Program {
    var prog = try Program.init(gpa, reg, program_name);
    errdefer prog.deinit();

    var p = Parser{
        .prog = &prog,
        .reg = reg,
        .diag = diag,
        .src = source,
        .toks = try tokenize(prog.a(), source, diag),
        .rows = rows,
    };
    p.program_target = .{ .nodes = &prog.nodes, .slots = &prog.slots };
    try p.parseProgram();

    // Publish `as` names on the program (sources that are wires only — the
    // console watches slots, and literal/plane sources have no slot).
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
    /// The raw source — tail ports (§3.11) slice their text from here, not
    /// from tokens, so `#` and `//` are text in a tail and `/` needs no
    /// token.
    src: []const u8,
    toks: []Token,
    pos: usize = 0,
    program_target: Target = undefined,
    defs: std.StringArrayHashMapUnmanaged(*Template) = .empty,
    /// Bound folds (§3.10): the sigil-bearing name (`:flock`, the SAME string
    /// at both ends of the binding) → the tokens captured verbatim between
    /// `using` and its trailing `as`. Resolved entirely at parse — folds are
    /// surface syntax and never reach the graph, the dump, or the evaluator.
    folds: std.StringArrayHashMapUnmanaged(Fold) = .empty,
    /// One entry per EXPANSION, not per binding: `via` chains a splice back
    /// through the folds it came through, so a refusal deep inside expanded
    /// tokens can name every fold between the author's text and the token
    /// that actually refused.
    fold_sites: std.ArrayListUnmanaged(FoldSite) = .empty,
    op_counters: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// How many `also { … }` blocks enclose the cursor. Two rules read it: a
    /// `}` closes an argument list only inside a block, and a tail port's
    /// end-of-line capture would otherwise swallow the block's own brace.
    block_depth: u32 = 0,
    /// True when parsing a KERNEL — a rill mounted on a spray (spec §3.16).
    /// The one thing it changes: a row word (`OpDef.row.only`) binds only
    /// here, and refuses by name anywhere else. Structural rather than
    /// runtime, because `fails_mount` only fires if the node evaluates at
    /// tick 0, and `plane.x | gravity` with an unfed `plane.x` never does —
    /// it mounted cleanly (spindrift beat 1, ledger). The parser is the
    /// place that knows what kind of program it is reading.
    rows: bool = false,

    fn a(self: *Parser) std.mem.Allocator {
        return self.prog.a();
    }

    /// Record a non-fatal diagnostic. Never aborts the parse: the text is
    /// well-formed, it just probably doesn't mean what it says.
    fn warn(self: *Parser, tok: Token, comptime fmt: []const u8, args: anytype) !void {
        try self.prog.warnings.append(self.a(), .{
            .line = tok.line,
            .col = tok.col,
            .msg = try std.fmt.allocPrint(self.a(), fmt, args),
        });
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
        // Error locality is the one real cost of a general fold. `use` could
        // validate at the definition, because the only thing it could bind
        // was a plane path; `using` binds arbitrary tokens, so a refusal on
        // spliced text lands on something the author never wrote. Every such
        // refusal therefore ends by naming the fold and where it was bound —
        // otherwise "defs close over nothing" points at a `plane` the author
        // cannot find.
        if (tok.fold != 0) self.noteProvenance(tok.fold);
        return error.Parse;
    }

    /// Append the expansion chain to the diagnostic already in the buffer,
    /// innermost fold first. Truncates rather than fails: a message that ran
    /// out of room is still better than no message.
    fn noteProvenance(self: *Parser, site: u32) void {
        var s = site;
        var first = true;
        while (s != 0) {
            const f = self.fold_sites.items[s - 1];
            const rest = self.diag.buf[self.diag.len..];
            const w = (if (first)
                std.fmt.bufPrint(rest, " — expanded from {s}, bound at line {d}", .{ f.name, f.def_line })
            else
                std.fmt.bufPrint(rest, ", spliced via {s} (line {d})", .{ f.name, f.def_line })) catch return;
            self.diag.len += w.len;
            first = false;
            s = f.via;
        }
    }

    fn skipNewlines(self: *Parser) void {
        while (self.peek().kind == .newline) _ = self.next();
    }

    /// Does the next non-blank line begin with `|`? Lookahead only.
    fn continuesWithPipe(self: *Parser) bool {
        var i = self.pos;
        while (i < self.toks.len and self.toks[i].kind == .newline) : (i += 1) {}
        return i < self.toks.len and self.toks[i].kind == .pipe;
    }

    /// At a `{` in argument position: does it open a RECORD (`{name:`) rather
    /// than a fan-out block? Lookahead only — records must open with a field,
    /// and no block branch can start `name:` (a branch head is an operator),
    /// so one token pair decides.
    fn braceOpensRecord(self: *Parser) bool {
        var i = self.pos + 1; // past the '{'
        while (i < self.toks.len and self.toks[i].kind == .newline) : (i += 1) {}
        return i + 1 < self.toks.len and
            self.toks[i].kind == .name and self.toks[i + 1].kind == .colon;
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
            .{ "=", "eq" },  .{ "!=", "ne" }, .{ "<", "lt" },
            .{ "<=", "le" }, .{ ">", "gt" },  .{ ">=", "ge" },
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
                try self.parseDef(null);
            } else if (t.kind == .name and std.mem.eql(u8, t.text, "export")) {
                // `export def name(…)` — visibility, and only visibility. It
                // is a PREFIX rather than a sigil on the name because those
                // are two different questions: `^` says how a mounted
                // archetype is ADDRESSED on the plane, `export` says who can
                // see this definition, and a spelling that did both would
                // conflate them (ruled 2026-09-08, replacing `def ^roaches`).
                const ex = self.next();
                const d = self.peek();
                if (d.kind != .name or !std.mem.eql(u8, d.text, "def")) {
                    return self.fail(d, "`export` marks a DEFINITION visible to the host — write `export def <name>(…)`; there is nothing else to export", .{});
                }
                try self.parseDef(ex);
            } else if (t.kind == .name and std.mem.eql(u8, t.text, "describe")) {
                try self.parseDescribe();
            } else if (t.kind == .name and std.mem.eql(u8, t.text, "using")) {
                try self.parseUsing();
            } else {
                // No `use` arm. A first draft had one, and deleting it changed
                // nothing any gate could see: `use` at statement head already
                // falls through here to `parseExpr`, which points at `using`,
                // and mid-chain it reaches the op-lookup door beside
                // `set` → `write`. A third path was dead code that only looked
                // like a check — found by the mutation surviving, 2026-09-08.
                _ = try self.parseStatement(&self.program_target);
            }
        }
        try self.checkExportsDescribed();
        try self.publishExports();
        if (self.prog.findCycle()) |cyc| {
            const n = self.prog.node(cyc.write.node);
            return self.fail(self.toks[self.toks.len - 1], "cycle — node {s} writes {s}, which the program also subscribes to (via {s})", .{ n.name, cyc.write.path, cyc.sub_path });
        }
    }

    /// The parity gate, half two — run at the END of the program because a
    /// `describe` block follows the `def` it describes (parse order is
    /// topological order here as everywhere else, so the definition must
    /// exist before anything names it). The other half — a describe line
    /// naming a port the definition does not have — runs at the block, where
    /// the offending word is.
    ///
    /// It is deliberately BOTH directions. One direction catches orphans and
    /// lets everybody skip writing prose, which is the exact failure the
    /// feature exists to prevent: the burden belongs on whoever writes the
    /// definition, at the moment they write it.
    ///
    /// Exported only. A `def` is also just a private helper, and taxing every
    /// two-line helper with a description block would be tax rather than
    /// discipline (Christian's ruling). What is exported is what a HUD
    /// renders, what `schema` emits and what an agent reads — the surface
    /// where laziness costs somebody else.
    fn checkExportsDescribed(self: *Parser) ParseError!void {
        for (self.defs.values()) |tmpl| {
            if (!tmpl.exported) continue;
            if (!tmpl.described) {
                return self.fail(tmpl.name_tok, "exported def '{s}' has no `describe` block — an exported definition documents itself (add `describe {s}` with one line per port: {s})", .{ tmpl.name, tmpl.name, try self.portList(tmpl) });
            }
            // The definition's own sentence is required too, not just the
            // ports'. It is the first thing a generated panel shows and the
            // first thing an agent reads; a pack that says what every knob
            // does and never says what the THING is has skipped the useful
            // half.
            if (tmpl.doc.len == 0) {
                return self.fail(tmpl.name_tok, "exported def '{s}': its `describe` block has no leading description — the first line of the block is a bare string saying what '{s}' does", .{ tmpl.name, tmpl.name });
            }
            for (tmpl.ports) |pd| {
                if (pd.doc.len > 0) continue;
                return self.fail(pd.tok, "exported def '{s}': port '{s}' has no description — add a line `{s} \"…\"` to `describe {s}`", .{ tmpl.name, pd.name, pd.name, tmpl.name });
            }
        }
    }

    /// Copy every exported def's pack onto the Program, where a host can read
    /// it. This is the whole of what `export` DOES in this beat: a def body
    /// still flattens per instance and the graph still does not know defs
    /// exist, so without this table `export` would be inert — rill has no
    /// imports and no cross-file reference, and "visible" can only mean
    /// "visible to the host". A local def is not copied and vanishes exactly
    /// as it always did.
    fn publishExports(self: *Parser) ParseError!void {
        for (self.defs.values()) |tmpl| {
            if (!tmpl.exported) continue;
            const ports = try self.a().alloc(graph.DefPort, tmpl.ports.len);
            for (tmpl.ports, ports) |src, *dst| {
                dst.* = .{
                    .name = src.name,
                    .ty = src.ty,
                    .default = src.default,
                    .min = src.min,
                    .max = src.max,
                    .doc = src.doc,
                };
            }
            try self.prog.exports.append(self.a(), .{
                .name = tmpl.name,
                .doc = tmpl.doc,
                .ports = ports,
            });
        }
    }

    /// A literal in a def signature — a default, a range end. `parseLiteral`
    /// does the work; this exists for the refusal, which must name the def,
    /// the port and which of the three slots the author was filling. "expected
    /// a literal, got 'plane'" would leave them hunting.
    fn parseDefLiteral(self: *Parser, def_name: []const u8, port_name: []const u8, role: []const u8) ParseError!ParsedLit {
        const t = self.peek();
        const is_lit = switch (t.kind) {
            .number, .duration, .string => true,
            .name => std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false"),
            else => false,
        };
        if (!is_lit) {
            // A fold colon is decided by ADJACENCY (`colonOpensFold`, the
            // previous beat): it must be preceded by whitespace, the start of
            // input, or an opener. `..` and `=` are neither, so `(0..:ceiling)`
            // and `x =:fast` lex the colon as the four-year-old `.colon` and
            // arrive here as a bare `:`. That rule is load-bearing and stays
            // untouched — widening the whitelist to earn one marginal spelling
            // would trade a gated rule for a convenience — so the refusal
            // points at the space instead of shrugging "must be a literal".
            if (t.kind == .colon and self.toks[self.pos + 1].kind == .name) {
                return self.fail(t, "def '{s}' port '{s}': a fold reference needs a space before its colon here — write ': {s}' as ' :{s}'", .{ def_name, port_name, self.toks[self.pos + 1].text, self.toks[self.pos + 1].text });
            }
            return self.fail(t, "def '{s}' port '{s}': the {s} must be a literal, got '{s}' — a def closes over nothing, so a default cannot read a stream or a plane path", .{ def_name, port_name, role, t.text });
        }
        return self.parseLiteral(&self.program_target);
    }

    /// A template's port names, comma-separated — what a refusal reads out so
    /// the author is never left guessing which ones exist.
    fn portList(self: *Parser, tmpl: *Template) ![]const u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        for (tmpl.ports, 0..) |pd, i| {
            if (i > 0) try out.appendSlice(self.a(), ", ");
            try out.appendSlice(self.a(), pd.name);
        }
        if (out.items.len == 0) try out.appendSlice(self.a(), "(none)");
        return out.items;
    }

    /// defstmt := ["export"] "def" name "(" port* ")" "=" body
    /// port    := name [":" type] ["=" literal] ["(" literal ".." literal ")"]
    ///
    /// The pack (2026-09-08) is Blade3D's, transposed: a default makes the
    /// port optional at the call site, and a range is a SANE RANGE for a
    /// generated widget and for a reader — advice, never a constraint.
    fn parseDef(self: *Parser, export_tok: ?Token) ParseError!void {
        const kw_tok = self.next(); // "def"
        // The dedent that ends the body is measured from the STATEMENT HEAD,
        // which is `export` when there is one — not from `def`. Measuring from
        // `def` puts the anchor at column 8 for every exported definition, and
        // a body indented two spaces reads as a dedent: the whole def parses
        // as empty. (Found by writing the first exported def with a two-line
        // body; the mutation that reverts it is `def_tok = kw_tok`.)
        const def_tok = export_tok orelse kw_tok;
        const exported = export_tok != null;
        const name_tok = self.next();
        if (name_tok.kind != .name) return self.fail(name_tok, "expected operator name after 'def'", .{});
        if (name_tok.text[0] == '$' or name_tok.text[0] == '@' or name_tok.text[0] == '#' or name_tok.text[0] == '^') return self.fail(name_tok, "'{s}': a sigil names a store row (`$` field, `@` entity, `#` condition, `^` archetype) — an operator cannot wear it", .{name_tok.text});
        if (self.defs.contains(name_tok.text) or self.reg.find(name_tok.text) != null) {
            return self.fail(name_tok, "'{s}' is already defined", .{name_tok.text});
        }

        if (self.next().kind != .lparen) return self.fail(self.toks[self.pos - 1], "expected '(' after def name", .{});
        var ports = std.ArrayListUnmanaged(PortDecl).empty;
        while (true) {
            const pt = self.next();
            if (pt.kind == .rparen) break;
            if (pt.kind != .name) return self.fail(pt, "expected port name in def signature", .{});
            if (pt.text[0] == '$' or pt.text[0] == '@' or pt.text[0] == '#' or pt.text[0] == '^') return self.fail(pt, "'{s}': a sigil names a store row (`$` field, `@` entity, `#` condition, `^` archetype) — a port cannot wear it", .{pt.text});
            var ty: types.TypeId = types.Tag.any;
            if (self.peek().kind == .colon) {
                _ = self.next();
                const tt = self.next();
                if (tt.kind != .name) return self.fail(tt, "expected type name after ':'", .{});
                ty = self.reg.types.intern(tt.text) catch return error.OutOfMemory;
            }
            var decl = PortDecl{ .name = try self.a().dupe(u8, pt.text), .ty = ty, .tok = pt };
            // `= <literal>` — the default. A literal and nothing else: a def
            // closes over nothing, so a default cannot be a plane path or a
            // stream, and a constant is the only thing that could be spliced
            // into every call site anyway. A fold IS allowed to supply it
            // (`expandIfFold` runs first): this is a value position like any
            // other, and the tokens it splices are judged by the same rule.
            if (self.peek().kind == .sym and std.mem.eql(u8, self.peek().text, "=")) {
                _ = self.next();
                try self.expandIfFold();
                const lit = try self.parseDefLiteral(name_tok.text, pt.text, "default");
                if (!types.accepts(ty, lit.ty)) {
                    return self.fail(self.toks[self.pos - 1], "def '{s}' port '{s}': the default is {s}, but the port is declared {s}", .{ name_tok.text, pt.text, self.reg.types.name(lit.ty), self.reg.types.name(ty) });
                }
                decl.default = lit.source.literal;
            }
            // `(<lo>..<hi>)` — the advisory range. Contextual: parens claim
            // nothing, and inside a signature a `(` can only ever open one.
            if (self.peek().kind == .lparen) {
                _ = self.next();
                try self.expandIfFold();
                const lo = try self.parseDefLiteral(name_tok.text, pt.text, "range minimum");
                const dd = self.next();
                if (dd.kind != .dotdot) {
                    return self.fail(dd, "def '{s}' port '{s}': a range is written '(<min>..<max>)' — expected '..', got '{s}'", .{ name_tok.text, pt.text, dd.text });
                }
                try self.expandIfFold();
                const hi = try self.parseDefLiteral(name_tok.text, pt.text, "range maximum");
                const close = self.next();
                if (close.kind != .rparen) {
                    return self.fail(close, "def '{s}' port '{s}': expected ')' to close the range", .{ name_tok.text, pt.text });
                }
                const lo_n = types.asNumber(lo.source.literal);
                const hi_n = types.asNumber(hi.source.literal);
                if (lo_n == null or hi_n == null) {
                    return self.fail(close, "def '{s}' port '{s}': a range is two numbers — a widget cannot draw a slider between anything else", .{ name_tok.text, pt.text });
                }
                // Backwards is a typo with one reading, so say the reading.
                if (lo_n.? > hi_n.?) {
                    return self.fail(close, "def '{s}' port '{s}': the range runs backwards ({d}..{d}) — write it low to high", .{ name_tok.text, pt.text, lo_n.?, hi_n.? });
                }
                decl.min = lo.source.literal;
                decl.max = hi.source.literal;
            }
            // A required port may not follow a defaulted one. This is rill's
            // own `AmbiguousOptionals` rule (registry.zig — "a word marks an
            // argument that could otherwise be mistaken for another"), applied
            // where a def port has no word to mark it with: positional fill is
            // strictly left-to-right, so `f 5` would silently land on the
            // OPTIONAL port and leave the required one unbound — the `arm
            // gate_closed` bug, one level up. Forcing the defaults to the tail
            // is also what makes two ADJACENT defaults safe here, where the
            // registry has to refuse them: nothing after them can shift.
            if (decl.default == null and ports.items.len > 0) {
                if (ports.items[ports.items.len - 1].default != null) {
                    const before = ports.items[ports.items.len - 1].name;
                    return self.fail(pt, "def '{s}': port '{s}' has no default but follows '{s}', which does — an argument would fill '{s}' and leave '{s}' unbound. Give '{s}' a default, or declare it before '{s}'", .{ name_tok.text, pt.text, before, before, pt.text, pt.text, before });
                }
            }
            try ports.append(self.a(), decl);
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
        tmpl.* = .{
            .name = try self.a().dupe(u8, name_tok.text),
            .ports = ports.items,
            .exported = exported,
            .name_tok = name_tok,
        };

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
                // This reads a token the AUTHOR wrote, always: a fold body
                // holds no newline, so a splice cannot straddle two
                // statements, and by the time one expands the statement has
                // already begun. (A first draft claimed the splice's
                // line/col rewrite was needed HERE; the mutation that
                // dropped it survived, which is how the claim was found to
                // be wrong. What the rewrite is for is the diagnostic
                // position — see `expandIfFold`.)
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

    /// describestmt := "describe" name NEWLINE (INDENT (string | name string))+
    ///
    /// Prose lives in its own block, not inline in the signature (Christian's
    /// ruling, carried over from SPL, and settled — three reasons):
    ///
    /// 1. A number does not clutter a signature; a sentence does. Defaults and
    ///    ranges are BEHAVIOUR and stay inline where they cannot drift from
    ///    the thing they describe. Prose changes nothing at runtime and can
    ///    live where it reads best.
    /// 2. It is a **safe surface for a local model to write**. Generated prose
    ///    landing in a describe block cannot break a definition — the worst it
    ///    can do is describe the wrong port, and the parity gate catches that
    ///    by name.
    /// 3. It can be added to existing code without touching the code.
    ///
    /// A leading BARE STRING describes the definition itself (Blade3D's
    /// `[Operator(Description = …)]`); every other line is `<port> "…"`.
    ///
    /// The block must FOLLOW its definition, like everything else in a
    /// language where parse order is topological order — and the refusal says
    /// so rather than shrugging, because "unknown name" would send the author
    /// hunting for a typo that is not there.
    fn parseDescribe(self: *Parser) ParseError!void {
        const kw = self.next(); // "describe"
        const name_tok = self.next();
        if (name_tok.kind != .name) {
            return self.fail(name_tok, "expected the name of a def after 'describe' — `describe <name>`", .{});
        }
        const tmpl = self.defs.get(name_tok.text) orelse {
            if (self.reg.find(name_tok.text) != null) {
                return self.fail(name_tok, "'{s}' is a registered operator, not a def — `describe` documents a definition in this program, and an operator's help lives in its registration", .{name_tok.text});
            }
            return self.fail(name_tok, "'{s}' is not a def in this program — a `describe` block follows the `def` it describes (parse order is definition order here)", .{name_tok.text});
        };
        if (tmpl.described) {
            return self.fail(name_tok, "'{s}' already has a `describe` block — one block per definition, so there is one place to read", .{name_tok.text});
        }
        tmpl.described = true;

        var any_line = false;
        while (true) {
            self.skipNewlines();
            const t = self.peek();
            if (t.kind == .eof) break;
            if (t.col <= kw.col) break; // dedent ends the block
            // A describe block splices NOTHING. It is prose, read verbatim
            // into the pack, and the one surface the design intends a local
            // model to write into: a fold in the port-NAME position could
            // rename what the parity gate then checks, and a fold in the
            // string position buys indirection where the whole point is that
            // the sentence sits where a reader finds it. Refused by name
            // rather than by "unexpected token".
            if (t.kind == .fold) {
                return self.fail(t, "a `describe` block is prose and is read verbatim — '{s}' is not spliced here; write the text out", .{t.text});
            }
            if (t.kind == .string) {
                _ = self.next();
                if (any_line) {
                    return self.fail(t, "describe '{s}': a bare string describes the DEFINITION and comes first — a port's line is `<port> \"…\"`", .{tmpl.name});
                }
                if (t.text.len == 0) {
                    return self.fail(t, "describe '{s}': the definition's description is empty — say what it does, or leave the line out", .{tmpl.name});
                }
                tmpl.doc = try self.unescape(t.text);
                any_line = true;
                continue;
            }
            if (t.kind != .name) {
                return self.fail(t, "describe '{s}': expected a port name or a leading description string, got '{s}'", .{ tmpl.name, t.text });
            }
            _ = self.next();
            const st = self.next();
            if (st.kind != .string) {
                return self.fail(st, "describe '{s}': port '{s}' needs a quoted description — `{s} \"what it means\"`", .{ tmpl.name, t.text, t.text });
            }
            // An empty string is not a description, and letting one through
            // would make the parity gate say "port has no description" about a
            // line that is visibly right there.
            if (st.text.len == 0) {
                return self.fail(st, "describe '{s}': port '{s}' has an empty description — say what it means", .{ tmpl.name, t.text });
            }
            // Direction two of the parity gate, and it runs for a LOCAL def
            // too: a describe block that names a port the definition does not
            // have is wrong whoever wrote it, and the fix is the list.
            const pd = for (tmpl.ports) |*p| {
                if (std.mem.eql(u8, p.name, t.text)) break p;
            } else {
                return self.fail(t, "describe '{s}': '{s}' is not a port of '{s}' — it has: {s}", .{ tmpl.name, t.text, tmpl.name, try self.portList(tmpl) });
            };
            if (pd.doc.len > 0) {
                return self.fail(t, "describe '{s}': port '{s}' is described twice", .{ tmpl.name, t.text });
            }
            pd.doc = try self.unescape(st.text);
            any_line = true;
        }
        if (!any_line) {
            return self.fail(kw, "describe '{s}' says nothing — put the description on the next line, indented", .{tmpl.name});
        }
    }

    /// usingstmt := "using" token+ "as" foldname — a parse-time MACRO
    /// (§3.10, 2026-09-08; it replaced `use`). Everything between `using` and
    /// the trailing `as` is captured **verbatim as tokens** and is not parsed
    /// here: the statement ends at the newline, and its last two tokens are
    /// `as` and the name.
    ///
    /// The name wears its sigil at BOTH ends — `as :flock`, referenced
    /// `:flock` — so the binding and the reference are literally the same
    /// string, and the map is keyed on it. That is rill's existing convention
    /// (a `$chan` is one token, sigil included) rather than a new one, and it
    /// is why `using` needs none of `use`'s five shadow checks: a fold cannot
    /// collide with an operator, a stream name, or a def, because none of
    /// those can wear a colon. Three rules survive: not a store sigil, not a
    /// reserved word, not already bound.
    fn parseUsing(self: *Parser) ParseError!void {
        const kw = self.next(); // "using"
        const start = self.pos;
        while (self.peek().kind != .newline and self.peek().kind != .eof) _ = self.next();
        const span = self.toks[start..self.pos];

        if (span.len < 3) {
            return self.fail(kw, "`using` binds tokens to a name: `using <tokens…> as :<name>`", .{});
        }
        const as_tok = span[span.len - 2];
        if (as_tok.kind != .name or !std.mem.eql(u8, as_tok.text, "as")) {
            return self.fail(as_tok, "`using` ends with `as :<name>` — the last two tokens of the line name the fold", .{});
        }
        const name_tok = span[span.len - 1];
        // The bare form is an obvious slip, not a mystery: say the fix.
        if (name_tok.kind == .name) {
            return self.fail(name_tok, "a fold wears its sigil at both ends — bind it `as :{s}`, and the reference is `:{s}`", .{ name_tok.text, name_tok.text });
        }
        if (name_tok.kind != .fold) {
            return self.fail(name_tok, "expected a fold name after 'as' — `using <tokens…> as :<name>`", .{});
        }
        const bare = name_tok.text[1..];
        if (isSigil(bare[0])) {
            return self.fail(name_tok, "'{s}': a sigil names a store row (`$` field, `@` entity, `#` condition, `^` archetype) — a fold cannot wear it", .{name_tok.text});
        }
        if (isReservedWord(bare)) return self.fail(name_tok, "'{s}' is reserved", .{bare});
        if (self.folds.contains(name_tok.text)) return self.fail(name_tok, "fold '{s}' is already bound", .{name_tok.text});

        const body = span[0 .. span.len - 2];
        if (body.len == 0) {
            return self.fail(kw, "`using` has nothing to fold — put the tokens between `using` and `as {s}`", .{name_tok.text});
        }
        try self.folds.put(self.a(), try self.a().dupe(u8, name_tok.text), .{
            .body = body,
            .def_line = kw.line,
        });
    }

    /// At a `:name`: splice the fold's tokens into the stream in its place and
    /// carry on parsing them. Called wherever a value or an operator may
    /// begin — nowhere else, which is what keeps a `:name` inside a tail port
    /// the verbatim text a tail promises.
    ///
    /// The splice rebuilds `self.toks` rather than pushing a cursor, so every
    /// existing lookahead (`toks[pos+1]` for the kwarg colon,
    /// `braceOpensRecord`, `continuesWithPipe`) keeps reading a flat array and
    /// needs no change. Spliced tokens take the SPLICE SITE's line and column,
    /// so the caret lands on the `:name` the author wrote rather than on the
    /// binding line the tokens were captured from, and they carry the
    /// expansion site so `fail` can name the fold that supplied them.
    ///
    /// Two splices of one fold produce two independent node sets. That is not
    /// a compromise: it is exactly what `def` already does, flattening its
    /// body per instance.
    fn expandIfFold(self: *Parser) ParseError!void {
        while (self.toks[self.pos].kind == .fold) {
            const tok = self.toks[self.pos];
            if (isSigil(tok.text[1])) {
                return self.fail(tok, "'{s}': a sigil names a store row (`$` field, `@` entity, `#` condition, `^` archetype) — a fold cannot wear it", .{tok.text});
            }
            const f = self.folds.get(tok.text) orelse {
                return self.fail(tok, "'{s}' is not a bound fold — bind it first with `using <tokens…> as {s}`", .{ tok.text, tok.text });
            };
            // The provenance chain IS the recursion stack: a fold that
            // expands, directly or through others, back to itself would
            // splice forever, and the name is already sitting in the chain.
            // Reported as a cycle with every fold it runs through, because
            // "expansion too deep" names nobody.
            {
                var via = tok.fold;
                var depth: u32 = 0;
                while (via != 0) : (via = self.fold_sites.items[via - 1].via) {
                    depth += 1;
                    if (std.mem.eql(u8, self.fold_sites.items[via - 1].name, tok.text)) {
                        return self.fail(tok, "fold cycle: {s} expands through itself ({s})", .{ tok.text, try self.chainText(tok) });
                    }
                    if (depth > max_fold_depth) {
                        return self.fail(tok, "folds nest more than {d} deep at {s} ({s})", .{ max_fold_depth, tok.text, try self.chainText(tok) });
                    }
                }
            }

            const site: u32 = @intCast(self.fold_sites.items.len + 1);
            try self.fold_sites.append(self.a(), .{ .name = tok.text, .def_line = f.def_line, .via = tok.fold });

            const out = try self.a().alloc(Token, self.toks.len - 1 + f.body.len);
            @memcpy(out[0..self.pos], self.toks[0..self.pos]);
            for (f.body, 0..) |bt, k| {
                var spliced = bt;
                spliced.line = tok.line;
                spliced.col = tok.col;
                spliced.fold = site;
                out[self.pos + k] = spliced;
            }
            @memcpy(out[self.pos + f.body.len ..], self.toks[self.pos + 1 ..]);
            self.toks = out;
        }
    }

    /// The expansion chain, outermost fold first, ending at `tok` — the text
    /// a cycle refusal reads out.
    fn chainText(self: *Parser, tok: Token) ![]const u8 {
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var via = tok.fold;
        while (via != 0) : (via = self.fold_sites.items[via - 1].via) {
            try names.append(self.a(), self.fold_sites.items[via - 1].name);
        }
        var buf = std.ArrayListUnmanaged(u8).empty;
        var i = names.items.len;
        while (i > 0) {
            i -= 1;
            try buf.appendSlice(self.a(), names.items[i]);
            try buf.appendSlice(self.a(), " → ");
        }
        try buf.appendSlice(self.a(), tok.text);
        return buf.items;
    }

    /// `use` became `using` on 2026-09-08. Same precedent as `set` → `write`:
    /// a keyword that every rill ever written used must not die as "unknown
    /// operator or name", it must point.
    fn failRetiredUse(self: *Parser, tok: Token) ParseError {
        return self.fail(tok, "`use` became `using` — same shape and more general: `using plane.player as :p` binds the TOKENS, and the reference wears the sigil too (`:p.health`)", .{});
    }

    /// chain := expr block* ( "|" (opcall | alsoblock) )* ( "as" namelist )?
    ///
    /// `block*` is the generalised `also` rule (rill-casts.md note §5): a
    /// statement head followed by `{ … }` fans out into the block's branches,
    /// with the head as every branch's source — `every 1f { S }` desugars to
    /// `every 1f as ⟨anon⟩` + `⟨anon⟩ | S`, except no anonymous name is ever
    /// built (the head's Source is handed to each branch directly, same trick
    /// as `also`). Head position only: mid-chain side branches ride
    /// `also { … }`, one spelling per position.
    fn parseStatement(self: *Parser, target: *Target) ParseError!OpResult {
        const head_tok = self.peek();
        var current = try self.parseExpr(target);
        while (self.peek().kind == .lbrace) {
            if (current.outputs.len == 0) {
                return self.fail(self.peek(), "nothing to fan out — the statement head has no output", .{});
            }
            try self.parseAlsoBlock(target, current.outputs[0], head_tok);
        }
        try self.parseChain(target, &current);

        // as namelist
        if (self.peek().kind == .name and std.mem.eql(u8, self.peek().text, "as")) {
            if (self.block_depth > 0) {
                return self.fail(self.peek(), "no name escapes a block — bind the stream before the block, or end the branch with a sink", .{});
            }
            _ = self.next();
            var bound_names = std.ArrayListUnmanaged([]const u8).empty;
            while (true) {
                const nt = self.next();
                if (nt.kind != .name) return self.fail(nt, "expected name after 'as'", .{});
                if (isReservedWord(nt.text)) return self.fail(nt, "'{s}' is reserved", .{nt.text});
                if (nt.text[0] == '$' or nt.text[0] == '@' or nt.text[0] == '#' or nt.text[0] == '^') return self.fail(nt, "'{s}': a sigil names a store row (`$` field, `@` entity, `#` condition, `^` archetype) — a stream cannot wear it", .{nt.text});
                if (target.names.contains(nt.text)) return self.fail(nt, "name '{s}' is already bound (names are single-assignment)", .{nt.text});
                // No fold check here, and that is the point: a fold wears a
                // colon, a stream name cannot, so the two namespaces cannot
                // touch. `use` needed five shadow checks; `using` needs none.
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

        // §3.7: any plane path is a subscription — including a statement that
        // IS one (`plane.x`, or `plane.x as v` before anything consumes v).
        // Slots register their own subs; a node-less statement has no slot,
        // so without this a bare-path line had no subscription at all and
        // the one-shot echo had nothing to read (rillbook's second drive).
        // Statement-level on purpose: a `set` target is a STATIC, not a
        // value, and eager-subscribing at the ref made every write
        // self-cyclic (the first draft's five minutes of life).
        if (current.node == null and current.outputs.len == 1) {
            switch (current.outputs[0]) {
                .plane => |p_| {
                    _ = self.prog.subFor(p_) catch return error.OutOfMemory;
                },
                else => {},
            }
        }
        // The program's RESULT: the last top-level statement's value, whatever
        // its shape — a wire, a bare path, a bare literal (`0.1` echoes 0.1,
        // rillbook's third drive). A sink statement has no outputs and sets
        // null: effects echo nothing.
        if (target.template == null) {
            self.prog.result = if (current.outputs.len > 0) current.outputs[0] else null;
        }

        const end = self.peek();
        if (end.kind != .newline and end.kind != .eof and
            !(end.kind == .rbrace and self.block_depth > 0))
        {
            if (end.kind == .lbrace) {
                return self.fail(end, "a '{{…}}' block hangs off the statement head; mid-chain side branches ride 'also {{ … }}' (a record argument is '{{field: value}}')", .{});
            }
            return self.fail(end, "unexpected '{s}' — expected end of statement", .{end.text});
        }
        return current;
    }

    /// The `| …` tail shared by top-level statements and `also` branches.
    /// `current` is advanced in place, which is the whole trick: an `also`
    /// block simply *doesn't* advance it, so the main wire continues from the
    /// same slot the block branched off.
    fn parseChain(self: *Parser, target: *Target, current: *OpResult) ParseError!void {
        while (true) {
            // A line that *starts* with `|` continues the statement above it.
            // There is no ambiguity to weigh: no statement can begin with a
            // pipe, so a leading `|` has never had a second meaning. It exists
            // for the shape `also` wants — one branch per line, every pipe in
            // the left margin where the eye finds it.
            if (self.peek().kind == .newline and self.continuesWithPipe()) self.skipNewlines();
            if (self.peek().kind != .pipe) break;
            _ = self.next();
            self.skipNewlines(); // a chain may wrap after a '|'
            // `| .field` is the taught spelling for a field read mid-chain
            // (ruled 2026-08-25). It is sugar for the `project` operator,
            // which stays registered as SUBSTRATE — reachable, never taught,
            // the same standing `wave` has under `lfo`. Before this, a row
            // ending in a field read cost a second line, because `.field`
            // read from a name or a path and a chain had neither.
            //
            // It reuses `parseProjections`, so `| .pos.x` in a chain means
            // exactly what `near.pos.x` off a name means — one code path, one
            // answer. (The deferral is elsewhere: `(.pos.x)` as a SECTION
            // needs a body to be several nodes, and is still refused by name.)
            if (self.peek().kind == .dot) {
                if (current.outputs.len == 0) return self.fail(self.peek(), "nothing to pipe — upstream operator has no output", .{});
                const projected = try self.parseProjections(target, current.outputs[0]);
                current.* = .{ .outputs = try self.oneSource(projected) };
                continue;
            }
            try self.expandIfFold(); // `| :op …` — a fold in operator position
            const op_tok = self.next();
            if (op_tok.kind != .name and op_tok.kind != .sym) {
                return self.fail(op_tok, "expected operator after '|'", .{});
            }
            if (current.outputs.len == 0) return self.fail(op_tok, "nothing to pipe — upstream operator has no output", .{});
            if (op_tok.kind == .name and std.mem.eql(u8, op_tok.text, "also")) {
                try self.parseAlsoBlock(target, current.outputs[0], op_tok);
                continue; // `current` untouched — the identity, in one line
            }
            // A path after a pipe is the most-forgotten spelling in live use
            // (Chris, twice in one morning): a pipe feeds an OPERATOR, and
            // writing what's flowing to a path is `set`. Name the fix.
            if (op_tok.kind == .name and isPathHead(op_tok.text)) {
                return self.fail(op_tok, "'{s}…' is a path, and a pipe feeds an operator — did you forget `set`? (… | write {s}.…)", .{ op_tok.text, op_tok.text });
            }
            // The pipe carries the producer's FIRST output to the consumer's
            // first port (the 90% case, unchanged). Its OTHER outputs ride
            // along by NAME: a consumer port left open that is spelled like
            // one of them binds to it. `collide | stick` hands the hit point
            // down the pipe and the normal to `stick`'s `normal` port — the
            // first time any second output of a rill word had a spelling
            // that reached it (spindrift beat 5, ruling 24: the resting
            // offset needs the normal at `stick`). An explicit argument
            // always wins; a port with no like-named output is unbound as
            // before; nothing binds by position.
            const carried = try self.carriedOutputs(target, current.*);
            current.* = try self.parseOpcallCarrying(target, op_tok, current.outputs[0], false, carried);
        }
    }

    /// What rides a pipe besides the first output: the producer's other
    /// outputs, each with the name its operator declares (or the `as` name
    /// bound to it). Empty for anything that is not an opcall node.
    fn carriedOutputs(self: *Parser, target: *Target, from: OpResult) ![]const Carried {
        const node_id = from.node orelse return &.{};
        if (from.outputs.len < 2) return &.{};
        const def = self.reg.get(target.nodes.items[node_id].op);
        const n = @min(from.outputs.len, def.outputs.len);
        if (n < 2) return &.{};
        const out = try self.a().alloc(Carried, n - 1);
        for (1..n) |i| {
            const name = if (i < from.out_names.len) from.out_names[i] else def.outputs[i].name;
            out[i - 1] = .{ .name = name, .src = from.outputs[i] };
        }
        return out;
    }

    /// alsoblock := "also" "{" branch ( newline branch )* "}"
    ///
    /// Each branch is an ordinary chain fed by `src`, built straight into the
    /// same target — so the block's nodes are indistinguishable from
    /// hand-written fan-out by the time anything downstream looks. Its writes
    /// land in the program's write list through the usual path in
    /// `parseOpcall`, which is why the cycle check sees through the block for
    /// free.
    fn parseAlsoBlock(self: *Parser, target: *Target, src: Source, also_tok: Token) ParseError!void {
        const open = self.next();
        if (open.kind != .lbrace) return self.fail(open, "expected '{{' after 'also'", .{});

        self.block_depth += 1;
        defer self.block_depth -= 1;

        var branches: usize = 0;
        while (true) {
            self.skipNewlines();
            const t = self.peek();
            if (t.kind == .rbrace) break;
            if (t.kind == .eof) return self.fail(also_tok, "unclosed block — expected '}}'", .{});
            try self.parseBranch(target, src);
            branches += 1;
        }
        _ = self.next(); // }
        if (branches == 0) {
            return self.fail(also_tok, "empty block — it would pass the value along and do nothing", .{});
        }
    }

    /// One branch of an `also` block: a chain whose head is always the
    /// in-flowing value. The head is therefore an *operator*, never an
    /// expression — a branch that started from something else would not be
    /// wired to `src`, so it could never rouse, and a side branch that can
    /// never run is exactly the silent failure this syntax exists to avoid.
    fn parseBranch(self: *Parser, target: *Target, src: Source) ParseError!void {
        // A `:fold` branch head expands first, and then the rule below judges
        // what it expanded TO — a fold of an operator is a legal branch head,
        // a fold of a path is not, and neither needs a rule of its own.
        try self.expandIfFold();
        const head = self.peek();
        if (head.kind == .name and std.mem.eql(u8, head.text, "also")) {
            return self.fail(head, "'also' needs a value to pass along — write it after a '|'", .{});
        }
        // Every head that names a *value* rather than an operator — a plane
        // path, a local stream, a literal, a record — would build a branch
        // nothing wires `src` into. It would parse, sit in the graph, and
        // never once run.
        const is_expr_head = switch (head.kind) {
            .name => isPathHead(head.text) or
                std.mem.eql(u8, head.text, "true") or
                std.mem.eql(u8, head.text, "false") or
                target.names.contains(head.text),
            .sym => false,
            else => true,
        };
        if (is_expr_head) {
            return self.fail(head, "a block's branches begin with an operator — the in-flowing value is the block's source", .{});
        }
        _ = self.next();
        var current = try self.parseOpcall(target, head, src, false);
        try self.parseChain(target, &current);

        if (self.peek().kind == .name and std.mem.eql(u8, self.peek().text, "as")) {
            return self.fail(self.peek(), "no name escapes a block — bind the stream before the block, or end the branch with a sink", .{});
        }
        const end = self.peek();
        if (end.kind != .newline and end.kind != .eof and end.kind != .rbrace) {
            return self.fail(end, "unexpected '{s}' — expected end of statement", .{end.text});
        }

        // A branch whose last node still holds a value has computed something
        // nobody will ever read: every sink (`set`, `notify`, and every host
        // effect verb) declares no outputs, so "ends with a sink" and "ends
        // with no outputs" are the same sentence. Not fatal — `also { tap x }`
        // is legal and occasionally meant — so it warns and parses on.
        if (current.outputs.len > 0) {
            const writes = if (current.node) |n| self.reg.get(target.nodes.items[n].op).class.writes() else false;
            if (!writes) try self.warn(head, "block discards a value; end with a sink or drop the tail", .{});
        }
    }

    /// expr := opcall | path | literal | record | name
    fn parseExpr(self: *Parser, target: *Target) ParseError!OpResult {
        try self.expandIfFold();
        const t = self.peek();
        switch (t.kind) {
            .lbrace => {
                const rec = try self.parseRecord(target);
                return .{ .node = rec, .outputs = try self.outsOf(target, rec) };
            },
            .lbracket => {
                const arr = try self.parseArray(target);
                return .{ .node = arr, .outputs = try self.outsOf(target, arr) };
            },
            .number, .string => {
                const lit = try self.parseLiteral(target);
                return .{ .outputs = try self.oneSource(lit.source) };
            },
            .name => {
                // No `use` / `using` arms here either. A bare keyword in
                // expression position falls straight through to `parseOpcall`,
                // whose op-lookup miss is where `set` → `write` already
                // points — one door, one message, for every position. Two
                // earlier drafts put a copy here and in `parseProgram`; both
                // mutations SURVIVED the suite, which is how they were found
                // to be unreachable (2026-09-08).
                if (std.mem.eql(u8, t.text, "also")) {
                    return self.fail(t, "'also' needs a value to pass along — write it after a '|'", .{});
                }
                if (std.mem.eql(u8, t.text, "true") or std.mem.eql(u8, t.text, "false")) {
                    const lit = try self.parseLiteral(target);
                    return .{ .outputs = try self.oneSource(lit.source) };
                }
                if (isPathHead(t.text)) {
                    const arg = try self.parsePlaneRef(target);
                    return .{ .outputs = try self.oneSource(arg.source) };
                }
                if (target.names.get(t.text)) |src| {
                    _ = self.next();
                    const projected = try self.parseProjections(target, src);
                    return .{ .outputs = try self.oneSource(projected) };
                }
                if (t.text[0] == '@') {
                    // An `@name.field` read is folded to its id-keyed plane
                    // path BEFORE the parse (mount-time binding, ironwood R6
                    // T2 pin ③) — so an `@` that reaches the parser is either
                    // unregistered (the host refuses the mount and says so)
                    // or a bare subject, which only `tag`/`untag` take.
                    return self.fail(t, "'{s}' is an entity reference — read a field ('{s}.pos'), or make it a tag subject: 'X | tag {s} #garrison'", .{ t.text, t.text, t.text });
                }
                if (t.text[0] == '^') {
                    // Archetypes are engine-owned and read-only (R6): the
                    // sigil is sayable so the console's derive grammar can
                    // name a population, but no rill expression reads one.
                    return self.fail(t, "'{s}' names an archetype — engine-owned, read-only; today only `derive set` takes one", .{t.text});
                }
                if (t.text[0] == '#') {
                    // A condition is written through the membership sinks and
                    // read at its service leaves — the sigil form is never an
                    // expression (same shape as the bare-`$` refusal below).
                    return self.fail(t, "'{s}' is a condition — write membership with 'tag <@subject> {s}', read it at plane.tags.{s}.count (or .joined / .left)", .{ t.text, t.text, t.text[1..] });
                }
                if (t.text[0] == '$') {
                    // Stamped 2026-08-25: a field read always names its
                    // standpoint — cast names where it deposits, a read names
                    // where it samples, and neither has an implicit "here".
                    // The error states the spelling, not just the refusal.
                    // (This is also what keeps the cycle checker out of the
                    // field store.)
                    //
                    // In a KERNEL (spindrift beat 2, ruled 2026-09-01) the
                    // standpoint is the spray's own lattice and `at` names
                    // where within it: `$wind at row.pos` (or `$wind grad at
                    // row.pos`) desugars to `hear $wind [grad] at row.pos` —
                    // `hear` being the host's word, registered by whoever
                    // owns a lattice, never core. Pure desugaring: the `$`
                    // token is not consumed; it binds to `hear`'s channel
                    // static exactly as it binds to `cast`'s. A BARE `$chan`
                    // in a kernel stays the same refusal with the kernel's
                    // own spelling in the message.
                    if (self.rows) {
                        const after = if (self.pos + 1 < self.toks.len) self.toks[self.pos + 1] else t;
                        const reads = after.kind == .name and (std.mem.eql(u8, after.text, "at") or std.mem.eql(u8, after.text, "grad"));
                        if (reads) {
                            if (self.reg.find("hear") == null) {
                                return self.fail(t, "'{s} at …' is a field read, and no host word `hear` is registered — a spray hears its own lattice; the world plane reads fields at plane.sensors.<post>.{s}", .{ t.text, t.text });
                            }
                            var hear_tok = t;
                            hear_tok.text = "hear";
                            return self.parseOpcall(target, hear_tok, null, false);
                        }
                        return self.fail(t, "'{s}' is a field channel, and a field read names its standpoint: in a kernel, '{s} at row.pos' (or '{s} grad at row.pos') — a bare channel has no implicit 'here'", .{ t.text, t.text, t.text });
                    }
                    return self.fail(t, "'{s}' is a field channel, and a field read names its standpoint: plane.sensors.<post>.{s}, or @tom.{s} through an entity-bound ear — a bare channel has no implicit 'here'. To deposit, 'cast {s} …'", .{ t.text, t.text, t.text, t.text });
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
        var ty_override: ?types.TypeId = null;
        switch (t.kind) {
            .duration => {
                // number + unit, one token. The unit set is closed (ratified
                // 2026-08-23): s / ms / m / f — frames only where frames are
                // the honest unit, and always whole.
                var split = t.text.len;
                while (split > 0 and std.ascii.isAlphabetic(t.text[split - 1])) split -= 1;
                const num_part = t.text[0..split];
                const unit = t.text[split..];
                if (num_part.len == 0 or num_part[0] == '-') {
                    return self.fail(t, "a duration cannot be negative: '{s}'", .{t.text});
                }
                const frames = std.mem.eql(u8, unit, "f");
                const factor: u64 = if (frames)
                    1
                else if (std.mem.eql(u8, unit, "ms"))
                    std.time.ns_per_ms
                else if (std.mem.eql(u8, unit, "s"))
                    std.time.ns_per_s
                else if (std.mem.eql(u8, unit, "m"))
                    std.time.ns_per_min
                else
                    return self.fail(t, "unknown duration unit '{s}' in '{s}' (s, ms, m, f)", .{ unit, t.text });
                var count: u64 = 0;
                if (std.mem.indexOfAny(u8, num_part, ".eE") != null) {
                    if (frames) return self.fail(t, "frame durations are whole frames: '{s}'", .{t.text});
                    const v = std.fmt.parseFloat(f64, num_part) catch return self.fail(t, "bad number '{s}'", .{num_part});
                    const scaled = @round(v * @as(f64, @floatFromInt(factor)));
                    if (!(scaled >= 0) or scaled >= 9.22e18) return self.fail(t, "duration out of range: '{s}'", .{t.text});
                    count = @intFromFloat(scaled);
                } else {
                    const v = std.fmt.parseInt(u64, num_part, 10) catch return self.fail(t, "bad number '{s}'", .{num_part});
                    count = std.math.mul(u64, v, factor) catch return self.fail(t, "duration out of range: '{s}'", .{t.text});
                }
                types.appendDuration(&pk, self.a(), .{ .frames = frames, .count = count }) catch return error.OutOfMemory;
                ty_override = types.Tag.duration;
            },
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
        return .{ .source = .{ .literal = bytes }, .ty = ty_override orelse types.typeOfValue(bytes) };
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

    /// The three path heads. `plane` is the world; `row` is the row a kernel
    /// is mounted on (spindrift beat 1, ruled 2026-09-01: a kernel is a rill
    /// whose plane is the row); `slate` is the within-tick side channel one
    /// operator says something on and another reads, wiped per row
    /// (2026-09-07, and `row.zig`'s `SLATE`). All three are subscriptions in
    /// the graph; which store answers is the mount's business — a `row.…`
    /// path in a program mounted on the world plane is a path nobody serves,
    /// loud at the same place a mistyped knob path is, and a `slate.…` name
    /// nobody says is loud at the same place again.
    ///
    /// `slate` is a head and not an operator name for the same reason `row`
    /// is: it is a place, and the grammar that reaches a place is a path.
    fn isPathHead(text: []const u8) bool {
        return std.mem.eql(u8, text, "plane") or std.mem.eql(u8, text, "row") or std.mem.eql(u8, text, "slate");
    }

    /// `plane` `.` segment… — returns either a plain path ref or, for the
    /// record sugar `plane.a.{x, y}`, a record node's wire. A fold whose
    /// tokens are a path arrives here as ordinary path tokens: `using` splices
    /// before this function ever runs, so there is no alias case any more —
    /// which is also why a fold of a LEAF path (`using plane.env.light as
    /// :dusk`, then `:dusk | < 0.15`) simply works, where a `use` alias could
    /// only ever be a prefix.
    fn parsePlaneRef(self: *Parser, target: *Target) ParseError!Arg {
        const head = self.next(); // "plane" / "row" / "slate"
        if (target.template != null) {
            // Reached by a fold too, and then `fail` names the fold: this is
            // Christian's ruling that `:name` needs NO rule of its own inside
            // a def body — substitution happens, and the check that was
            // already there judges what came out.
            return self.fail(head, "defs close over nothing — pass plane streams in through a port", .{});
        }
        var path = std.ArrayListUnmanaged(u8).empty;
        try path.appendSlice(self.a(), head.text);
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
            // A segment is a word OR a plain integer — id-keyed rows
            // (`plane.ents.1.pos`, the @ registry's mirrors) are legitimate
            // store shapes, and the tokenizer's trailing-dot rule already
            // splits `1.pos` into `1` `.` `pos`.
            const seg_ok = seg.kind == .name or (seg.kind == .number and blk: {
                for (seg.text) |ch| {
                    if (!std.ascii.isDigit(ch)) break :blk false;
                }
                break :blk true;
            });
            if (!seg_ok) return self.fail(seg, "expected path segment after '.'", .{});
            _ = self.next();
            try path.append(self.a(), '.');
            try path.appendSlice(self.a(), seg.text);
        }
        if (path.items.len == head.text.len) {
            return self.fail(head, "expected '.' after '{s}'", .{head.text});
        }
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
            const arg = try self.parseFieldValue(target);
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

    // -- arrays ---------------------------------------------------------------

    /// `[ value (,|newline value)* ]` — the record literal's positional twin
    /// (§2.10). Elements are literals, paths, names, records, or arrays, and
    /// an array holding a name or a path is **live** exactly as a record is:
    /// it re-evaluates when an element changes, because each element is a
    /// wire into one variadic node. An array is not a buffer — no element
    /// assignment, no append, no loop.
    ///
    /// `[]` is legal, unlike `{}`. The empty record is refused because `{`
    /// also opens a fan-out block and an empty one is far more likely a
    /// mistake than a value; `[` opens nothing else, and the empty array is
    /// a value the language already prints (`describe` says `[]`).
    fn parseArray(self: *Parser, target: *Target) ParseError!NodeId {
        const open = self.next(); // [
        var sources = std.ArrayListUnmanaged(Source).empty;
        self.skipNewlines();
        while (self.peek().kind != .rbracket) {
            const arg = try self.parseFieldValue(target);
            try sources.append(self.a(), arg.source);
            if (self.peek().kind == .comma) _ = self.next();
            self.skipNewlines();
        }
        _ = self.next(); // ]
        return self.makeArrayNode(target, sources.items, open);
    }

    /// The variadic `array` node. Its statics are the element INDICES as
    /// words, for the same reason `record`'s are the field names: `makeNode`
    /// names a variadic port from `statics[i].word`, and a port called `2`
    /// is what a positional field is.
    fn makeArrayNode(self: *Parser, target: *Target, sources: []const Source, tok: Token) ParseError!NodeId {
        const op_id = self.reg.find("array") orelse return self.fail(tok, "core operator 'array' is not registered", .{});
        const statics = try self.a().alloc(registry.StaticVal, sources.len);
        for (0..sources.len) |i| statics[i] = .{ .word = try std.fmt.allocPrint(self.a(), "{d}", .{i}) };
        return self.makeNode(target, op_id, sources, statics, tok);
    }

    fn makeRecordNode(self: *Parser, target: *Target, fields: []const []const u8, sources: []const Source, tok: Token) ParseError!NodeId {
        const op_id = self.reg.find("record") orelse return self.fail(tok, "core operator 'record' is not registered", .{});
        const statics = try self.a().alloc(registry.StaticVal, fields.len);
        for (fields, 0..) |f, i| statics[i] = .{ .word = f };
        return self.makeNode(target, op_id, sources, statics, tok);
    }

    // -- shape literals -------------------------------------------------------

    /// The type words a shape leaf may be. Deliberately the same vocabulary
    /// the mismatch messages print (beat 1b), so what a refusal says and what
    /// an author writes are one language. `any` says "present, kind
    /// unconstrained" — without it there is no way to require a field without
    /// also deciding its type, and `?` says the opposite thing (absent is
    /// fine).
    const SHAPE_WORDS = [_][]const u8{ "number", "boolean", "string", "any" };

    /// `shape := stype ["exact"]`, stored as `{exact: bool, shape: <s>}`.
    /// `exact` closes every record in the shape, not only the outermost: the
    /// word closes THE SHAPE, and a closed outside with open insides is a
    /// promise nobody asked for.
    fn parseShapeLiteral(self: *Parser, op_name: []const u8) ParseError!registry.StaticVal {
        const open = self.peek();
        if (open.kind != .lbrace and open.kind != .lbracket) {
            return self.fail(open, "'{s}' expects a shape — '{{field: type, …}}', or '[type]' for an array of", .{op_name});
        }
        const inner = try self.parseShapeType(op_name);
        var exact = false;
        if (self.peek().kind == .name and std.mem.eql(u8, self.peek().text, "exact")) {
            _ = self.next();
            exact = true;
        }
        var kx = struple.Packer.init(self.a());
        kx.appendString("exact") catch return error.OutOfMemory;
        var vx = struple.Packer.init(self.a());
        vx.appendBool(exact) catch return error.OutOfMemory;
        var ks = struple.Packer.init(self.a());
        ks.appendString("shape") catch return error.OutOfMemory;
        var pk = struple.Packer.init(self.a());
        pk.appendMap(&.{ .{ kx.bytes(), vx.bytes() }, .{ ks.bytes(), inner } }) catch return error.OutOfMemory;
        return .{ .shape = pk.toOwnedSlice() catch return error.OutOfMemory };
    }

    /// `stype := typeword | "{" sfield … "}" | "[" stype "]"`.
    fn parseShapeType(self: *Parser, op_name: []const u8) ParseError![]const u8 {
        const t = self.peek();
        switch (t.kind) {
            .lbrace => return self.parseShapeRecord(op_name),
            .lbracket => {
                _ = self.next();
                const elem = try self.parseShapeType(op_name);
                const close = self.next();
                if (close.kind != .rbracket) return self.fail(close, "'{s}': expected ']' to close an array shape", .{op_name});
                var pk = struple.Packer.init(self.a());
                pk.appendArray(elem) catch return error.OutOfMemory;
                return pk.toOwnedSlice() catch return error.OutOfMemory;
            },
            .name => {
                for (SHAPE_WORDS) |w| {
                    if (!std.mem.eql(u8, w, t.text)) continue;
                    _ = self.next();
                    var pk = struple.Packer.init(self.a());
                    pk.appendString(w) catch return error.OutOfMemory;
                    return pk.toOwnedSlice() catch return error.OutOfMemory;
                }
                return self.fail(t, "'{s}': '{s}' is not a type — expected one of: number, boolean, string, any, a nested '{{…}}', or '[…]'", .{ op_name, t.text });
            },
            else => return self.fail(t, "'{s}': expected a type, got '{s}'", .{ op_name, t.text }),
        }
    }

    /// `"{" (name ["?"] ":" stype) (("," | NEWLINE) …)* "}"`. The `?` is the
    /// `raw` token it has always been — a shape is the only place it means
    /// anything, so it costs no token kind.
    fn parseShapeRecord(self: *Parser, op_name: []const u8) ParseError![]const u8 {
        const open = self.next(); // {
        var entries = std.ArrayListUnmanaged([2][]const u8).empty;
        self.skipNewlines();
        while (self.peek().kind != .rbrace) {
            const ft = self.next();
            if (ft.kind != .name) return self.fail(ft, "'{s}': expected a field name in the shape", .{op_name});
            var key = ft.text;
            if (self.peek().kind == .raw and self.peek().text.len == 1 and self.peek().text[0] == '?') {
                _ = self.next();
                key = try std.fmt.allocPrint(self.a(), "{s}?", .{ft.text});
            }
            const ct = self.next();
            if (ct.kind != .colon) return self.fail(ct, "'{s}': expected ':' after '{s}' in the shape", .{ op_name, ft.text });
            const v = try self.parseShapeType(op_name);
            var kp = struple.Packer.init(self.a());
            kp.appendString(key) catch return error.OutOfMemory;
            try entries.append(self.a(), .{ kp.bytes(), v });
            if (self.peek().kind == .comma) _ = self.next();
            self.skipNewlines();
        }
        _ = self.next(); // }
        if (entries.items.len == 0) return self.fail(open, "'{s}': an empty shape promises nothing — name a field, or drop the check", .{op_name});
        var pk = struple.Packer.init(self.a());
        pk.appendMap(entries.items) catch return error.OutOfMemory;
        return pk.toOwnedSlice() catch return error.OutOfMemory;
    }

    // -- opcalls ------------------------------------------------------------

    /// Parse `opname arg*` with `primary` (the piped-in stream) bound to the
    /// first input port. Handles two-word host ops, def instantiation,
    /// statics, kwargs, and predicate sections. `reserved_primary` is set when
    /// parsing a section body: port 0 is held open for the mirrored stream, so
    /// `(< 20)` binds 20 to port b and computes `x < 20`, exactly as piping
    /// would.
    fn parseOpcall(self: *Parser, target: *Target, op_tok: Token, primary: ?Source, reserved_primary: bool) ParseError!OpResult {
        return self.parseOpcallCarrying(target, op_tok, primary, reserved_primary, &.{});
    }

    fn parseOpcallCarrying(self: *Parser, target: *Target, op_tok: Token, primary: ?Source, reserved_primary: bool, carried: []const Carried) ParseError!OpResult {
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

        const op_id = self.reg.find(op_name) orelse {
            // The renamed front door (write-verbs, 2026-08-29): `set` must
            // not die as a shrug when every rill ever written used it.
            if (std.mem.eql(u8, op_name, "set"))
                return self.fail(op_tok, "`set` became `write` — same shape, bare means the old durable replace (`x | write plane.foo`); say a mode (hold/add/mul/stops/clear) only if you mean one", .{});
            // Same door, for the same reason: `use` and `using` are statement
            // keywords, so mid-chain they reach op lookup and would shrug.
            if (std.mem.eql(u8, op_name, "use")) return self.failRetiredUse(op_tok);
            if (std.mem.eql(u8, op_name, "using"))
                return self.fail(op_tok, "'using' binds at the top level of a program — a fold is file-scoped, and a `:name` reference is what goes here", .{});
            // Same door, same reason (2026-09-08). Both are reserved, so
            // `find` can never answer for them, and a def body or a mid-chain
            // position would otherwise shrug "unknown operator" at a keyword
            // the author spelled correctly. ONE door: the previous beat proved
            // the copies in `parseProgram` and `parseExpr` were dead code by
            // mutating them and watching the suite stay green.
            if (std.mem.eql(u8, op_name, "export") or std.mem.eql(u8, op_name, "describe"))
                return self.fail(op_tok, "'{s}' is a statement keyword and stands at the top level of a program — it cannot appear in a chain or inside a def body", .{op_name});
            return self.fail(op_tok, "unknown operator or name '{s}'", .{op_name});
        };
        const def = self.reg.get(op_id);
        if (def.row.only and !self.rows) {
            return self.fail(op_tok, "'{s}' is a row word — it means something on a spray, not on the plane; mount it in a kernel", .{def.name});
        }
        if (def.variadic) return self.fail(op_tok, "'{s}' cannot be called directly", .{op_name});
        const has_tail = def.inputs.len > 0 and def.inputs[def.inputs.len - 1].tail;

        // A shape literal is parsed BEFORE the arguments, from the tokens
        // directly — it is its own grammar (type words where a record has
        // values), and `parseArgValue` would build a record node whose
        // `string` field is an unresolvable name. Same shape as the tail:
        // the port's declaration is what dispatches, not a lookahead guess.
        var shape_static: ?registry.StaticVal = null;
        if (opHasShape(def)) shape_static = try self.parseShapeLiteral(op_name);

        var args = std.ArrayListUnmanaged(Arg).empty;
        if (has_tail) {
            if (reserved_primary) return self.fail(op_tok, "'{s}' has a tail port and cannot be a predicate section", .{op_name});
            try self.parseTailArgs(target, def, &args, op_tok, primary != null);
        } else {
            try self.parseArgs(target, &args);
        }

        // Keyword pairing (rill-casts.md note §1): where the op declares
        // keyword-introduced statics/ports, a bare word naming one binds the
        // NEXT argument to it — `radius 12 at s.gate.pos decay 2s`. Scoped to
        // declaring ops only: made global, `add a b` would read as a=b. The
        // colon spelling (`at: …`) rides the existing kwarg path unchanged.
        if (opHasKeywords(def)) {
            var j: usize = 0;
            while (j < args.items.len) {
                const ag = args.items[j];
                if (ag.kind == .word and ag.kw.len == 0 and keywordOf(def, ag.text) != null) {
                    if (j + 1 >= args.items.len) {
                        return self.fail(ag.tok, "'{s}' expects a value after '{s}'", .{ op_name, ag.text });
                    }
                    if (args.items[j + 1].kw.len > 0) {
                        return self.fail(ag.tok, "'{s}': '{s}' has no value — the next argument is already '{s}'s", .{ op_name, ag.text, args.items[j + 1].kw });
                    }
                    args.items[j + 1].kw = ag.text;
                    _ = args.orderedRemove(j);
                    j += 1; // past the value just claimed
                } else j += 1;
            }
        }

        // ONE tag per call (ironwood R6 fork B): a second `#`-condition has
        // nowhere honest to bind, and "too many arguments" would mislabel a
        // ruling as an arity accident — refuse it by name.
        {
            var conds: usize = 0;
            var declared: usize = 0;
            for (args.items) |ag| {
                if (ag.kind == .word and ag.text.len > 1 and ag.text[0] == '#') conds += 1;
            }
            for (def.statics) |sd| {
                if (sd.kind == .condition) declared += 1;
            }
            if (declared > 0 and conds > declared) {
                return self.fail(op_tok, "'{s}': ONE per call — a second tag is a second statement", .{op_name});
            }
        }

        // Statics are configuration, not streams: keyword-declared ones bind
        // by name, the rest are consumed from the leading positional args in
        // declaration order.
        var statics = try self.a().alloc(registry.StaticVal, def.statics.len);
        const consumed = try self.a().alloc(bool, args.items.len);
        @memset(consumed, false);
        var pos_cursor: usize = 0;
        for (def.statics, 0..) |sd, i| {
            if (sd.kind == .shape) {
                statics[i] = shape_static.?;
                continue;
            }
            // A bare-word flag: present iff the word itself was written.
            if (sd.flag) {
                statics[i] = emptyStatic(sd.kind);
                for (args.items, 0..) |ag, j| {
                    if (consumed[j] or ag.kw.len > 0) continue;
                    if (ag.kind != .word or !std.mem.eql(u8, ag.text, sd.name)) continue;
                    statics[i] = .{ .word = try self.a().dupe(u8, sd.name) };
                    consumed[j] = true;
                    break;
                }
                continue;
            }
            var picked: ?Arg = null;
            if (sd.kw) {
                for (args.items, 0..) |ag, j| {
                    if (!consumed[j] and std.mem.eql(u8, ag.kw, sd.name)) {
                        picked = ag;
                        consumed[j] = true;
                        break;
                    }
                }
                if (picked == null) {
                    // An optional kw static unbound is legal: it fills with
                    // its kind's EMPTY value, which every consumer treats as
                    // absent (`cast` with no `to` is the uncoupled cast).
                    if (sd.optional) {
                        statics[i] = emptyStatic(sd.kind);
                        continue;
                    }
                    return self.fail(op_tok, "'{s}' needs '{s} <value>'", .{ op_name, sd.name });
                }
            } else {
                while (pos_cursor < args.items.len and (consumed[pos_cursor] or args.items[pos_cursor].kw.len > 0)) pos_cursor += 1;
                if (pos_cursor >= args.items.len) return self.fail(op_tok, "'{s}' needs a {s} argument '{s}'", .{ op_name, @tagName(sd.kind), sd.name });
                picked = args.items[pos_cursor];
                consumed[pos_cursor] = true;
            }
            const arg = picked.?;
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
                .channel => blk: {
                    if (arg.kind != .word or arg.text.len < 2 or arg.text[0] != '$') {
                        return self.fail(arg.tok, "'{s}' expects a channel for '{s}' — a '$'-sigil name: {s} $alarm …", .{ op_name, sd.name, op_name });
                    }
                    break :blk .{ .channel = try self.a().dupe(u8, arg.text) };
                },
                .subject => blk: {
                    if (arg.kind != .word or arg.text.len < 2 or arg.text[0] != '@') {
                        return self.fail(arg.tok, "'{s}' expects a subject for '{s}' — an '@'-sigil name: {s} @tom #…", .{ op_name, sd.name, op_name });
                    }
                    break :blk .{ .subject = try self.a().dupe(u8, arg.text) };
                },
                .condition => blk: {
                    if (arg.kind != .word or arg.text.len < 2 or arg.text[0] != '#') {
                        return self.fail(arg.tok, "'{s}' expects a tag for '{s}' — a '#'-sigil name (#garrison)", .{ op_name, sd.name });
                    }
                    break :blk .{ .condition = try self.a().dupe(u8, arg.text) };
                },
                // Handled above, before the arguments: a shape literal is its
                // own grammar and cannot survive `parseArgValue` (`{id:
                // string}` would build a record node whose `string` field is
                // an unresolvable name).
                .shape => unreachable,
            };
        }
        var stream_list = std.ArrayListUnmanaged(Arg).empty;
        for (args.items, 0..) |ag, j| {
            if (!consumed[j]) try stream_list.append(self.a(), ag);
        }
        const stream_args = stream_list.items;

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
            // A keyword-introduced BODY (`sort by (…)`) binds to no port —
            // the section loop below claims it.
            if (arg.kind == .section and def.body > 0) continue;
            const pi = portIndex(ports, arg.kw) orelse return self.fail(arg.tok, "'{s}' has no port '{s}'", .{ op_name, arg.kw });
            if (bound[pi] != null) return self.fail(arg.tok, "port '{s}' of '{s}' bound twice", .{ arg.kw, op_name });
            bound[pi] = try self.bindArg(arg, ports[pi], op_name, def, primary != null);
        }
        // Sections. Two mechanisms, and the CONSUMER's declaration decides
        // which — never a lookahead at the section's own text.
        //
        //   `def.body > 0`  the section is a BODY the operator drives per
        //                   element (`map`, `keep`, `reduce`). It binds to no
        //                   port and the sweep never evaluates it.
        //   `def.body == 0` the tier-1 predicate section (`where (> 0)`),
        //                   which mirrors the consumer's stream into its one
        //                   open port and rides the sweep like any node.
        //
        // Both check arity against what the consumer says it supplies, and a
        // predicate says 1 by construction.
        var body_node: ?NodeId = null;
        for (stream_args) |arg| {
            if (arg.kind != .section) continue;
            if (def.body > 0 and def.body_kw.len > 0 and !std.mem.eql(u8, arg.kw, def.body_kw)) {
                return self.fail(arg.tok, "'{s}' takes its section after '{s}' — write '{s} {s} (…)'", .{ op_name, def.body_kw, op_name, def.body_kw });
            }
            const want: usize = if (def.body > 0) def.body else 1;
            const open = self.openPorts(target, arg.section_node);
            if (open != want) {
                return self.fail(arg.tok, "'{s}' supplies {d} argument{s} to its section, and this section leaves {d} port{s} open", .{
                    op_name, want, if (want == 1) "" else "s", open, if (open == 1) "" else "s",
                });
            }
            if (def.body > 0) {
                if (body_node != null) return self.fail(arg.tok, "'{s}' drives one section body, and two were given", .{op_name});
                body_node = arg.section_node;
                continue;
            }
            if (arg.kw.len > 0) continue; // a keyword-bound predicate binds below
            const pi = for (ports, 0..) |port, i| {
                if (bound[i] == null and port.ty == types.Tag.boolean) break i;
            } else return self.fail(arg.tok, "'{s}' has no free boolean port for a predicate", .{op_name});
            bound[pi] = arg;
        }
        for (stream_args) |arg| {
            if (arg.kw.len > 0 or arg.kind == .section) continue;
            // Keyword-declared ports never fill positionally — the word is
            // what disambiguates them, so a stray positional must not land
            // there silently.
            const pi = for (ports, 0..) |port, i| {
                if (bound[i] == null and !port.kw) break i;
            } else return self.fail(arg.tok, "too many arguments for '{s}' ({d} port(s))", .{ op_name, ports.len });
            bound[pi] = try self.bindArg(arg, ports[pi], op_name, def, primary != null);
        }

        // A membership sink with nothing rousing it fires ONCE, at tick 0:
        // the parser binds a literal rousing rather than the eval guessing
        // whether silence means "unpiped" or "piped and quiet". The console
        // one-shot (`tag @wall #garrison`) is the customer — cast's unpiped
        // deposit-once story, built from machinery literals already have.
        if (ports.len > 0 and bound[0] == null and !reserved_primary) {
            const is_membership = for (def.statics) |sd| {
                if (sd.kind == .condition) break true;
            } else false;
            if (is_membership) {
                var pk = struple.Packer.init(self.a());
                pk.appendBool(true) catch return error.OutOfMemory;
                bound[0] = .{ .kind = .literal, .source = .{ .literal = pk.bytes() }, .ty = types.Tag.boolean, .tok = op_tok };
            }
        }

        // The pipe's other outputs, by name, into ports still open. After the
        // explicit bindings — an argument the author wrote always wins — and
        // never port 0, which the pipe itself fills.
        for (carried) |c| {
            const pi = portIndex(ports, c.name) orelse continue;
            if (pi == 0 or bound[pi] != null) continue;
            bound[pi] = .{ .kind = .stream, .source = c.src, .ty = self.sourceTy(target, c.src), .tok = op_tok };
        }

        // Type check + collect sources.
        const sources = try self.a().alloc(Source, ports.len);
        for (ports, 0..) |port, i| {
            const arg = bound[i] orelse {
                if (port.optional) {
                    sources[i] = .none;
                    continue;
                }
                // Inside a section, a required port the author did not fill is
                // not missing — it is OPEN, and open ports are what a section
                // IS. `(add)` leaves two; `(clamp 0 1)` leaves one. How many
                // are allowed is the consumer's declaration, checked where the
                // consumer binds it, because only the consumer knows.
                if (reserved_primary) {
                    sources[i] = .none;
                    continue;
                }
                return self.fail(op_tok, "port '{s}' of '{s}' is not bound", .{ port.name, op_name });
            };
            const val_ty = if (arg.kind == .section) self.sourceTy(target, arg.source) else arg.ty;
            if (!types.acceptsPort(port.ty, val_ty, port.broadcasts)) {
                if (port.ty == types.Tag.duration and val_ty == types.Tag.number) {
                    // §2.2: `sample 5` is a wire-time type error, with the fix named.
                    return self.fail(arg.tok, "'{s}' port '{s}' takes a duration — write it with a unit: 5s, 250ms, 3f", .{ op_name, port.name });
                }
                return self.fail(arg.tok, "'{s}' port '{s}': expected {s}, got {s}", .{
                    op_name, port.name, self.reg.types.name(port.ty), self.reg.types.name(val_ty),
                });
            }
            sources[i] = arg.source;
        }

        if (def.body > 0 and def.body_kw.len == 0 and body_node == null) {
            return self.fail(op_tok, "'{s}' needs a section body with {d} open port{s} — '{s} (…)'", .{
                op_name, def.body, if (def.body == 1) "" else "s", op_name,
            });
        }

        const node_id = try self.makeNode(target, op_id, sources, statics, op_tok);
        target.nodes.items[node_id].body = body_node;

        // Predicate sections mirror the consumer's primary input. A BODY does
        // not: its open ports are filled per element, at eval, by the operator
        // that declared it — wiring them to a stream is exactly the thing a
        // body is not.
        for (stream_args) |arg| {
            if (arg.kind != .section or def.body > 0) continue;
            if (ports.len == 0 or sources.len == 0) return self.fail(arg.tok, "'{s}' has no primary input for the predicate to read", .{op_name});
            const mirror = sources[0];
            switch (mirror) {
                .none => return self.fail(arg.tok, "'{s}' has no primary input for the predicate to read", .{op_name}),
                else => {},
            }
            try self.bindSectionPrimary(target, arg.section_node, mirror, arg.tok);
        }

        // Effect ops register their write targets — path statics directly,
        // the membership pair as its composed member key — for the cycle
        // check (program level only; a def's nodes register at instantiate).
        if (def.class.writes() and target.template == null) {
            self.prog.registerWrites(statics, node_id) catch return error.OutOfMemory;
        }

        return .{ .node = node_id, .outputs = try self.outsOf(target, node_id) };
    }

    /// The bind moment for one positional/kwarg argument, where the port's
    /// declaration decides two console-shaped rules (D5): a bare word in a
    /// *string-typed* port position is a string literal — `volume set v1 …`
    /// is the entire console grammar, and the type gate keeps the coercion
    /// narrow: anywhere else an unknown word stays a loud error. And a
    /// `one_of` port checks a bound string literal's membership here, at
    /// wire time — the browser's tab-complete list, finally enforced.
    /// How an operator's arguments are written, in the manual's §12 notation:
    /// `<name>` is positional, `name <name>` is introduced by that word, and
    /// `[…]` is optional. Rendered from the registry so a refusal and the
    /// operator index cannot disagree about the same operator.
    fn argSpelling(self: *Parser, def: *const registry.OpDef, skip_primary: bool) ParseError![]const u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        for (def.inputs, 0..) |pt, i| {
            if (i == 0 and skip_primary) continue;
            out.appendSlice(self.a(), " ") catch return error.OutOfMemory;
            const w = out.writer(self.a());
            if (pt.optional and pt.kw) {
                std.fmt.format(w, "[{s} <{s}>]", .{ pt.name, pt.name }) catch return error.OutOfMemory;
            } else if (pt.optional) {
                std.fmt.format(w, "[<{s}>]", .{pt.name}) catch return error.OutOfMemory;
            } else if (pt.kw) {
                std.fmt.format(w, "{s} <{s}>", .{ pt.name, pt.name }) catch return error.OutOfMemory;
            } else {
                std.fmt.format(w, "<{s}>", .{pt.name}) catch return error.OutOfMemory;
            }
        }
        for (def.statics) |sd| {
            out.appendSlice(self.a(), " ") catch return error.OutOfMemory;
            if (sd.flag) {
                std.fmt.format(out.writer(self.a()), "[{s}]", .{sd.name}) catch return error.OutOfMemory;
            } else if (sd.kw and sd.optional) {
                std.fmt.format(out.writer(self.a()), "[{s} <{s}>]", .{ sd.name, sd.name }) catch return error.OutOfMemory;
            } else if (sd.kw) {
                std.fmt.format(out.writer(self.a()), "{s} <{s}>", .{ sd.name, sd.name }) catch return error.OutOfMemory;
            } else {
                std.fmt.format(out.writer(self.a()), "<{s}>", .{sd.name}) catch return error.OutOfMemory;
            }
        }
        return out.items;
    }

    /// The arguments this operator DOES take by name, comma-separated, or the
    /// empty string. The reader's confusion is binary — does this one carry a
    /// word? — so the refusal answers exactly that, per operator, from the
    /// declaration rather than from a rule that has exceptions.
    fn keywordArgs(self: *Parser, def: *const registry.OpDef) ParseError![]const u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        for (def.inputs) |pt| {
            if (!pt.kw) continue;
            if (out.items.len > 0) out.appendSlice(self.a(), ", ") catch return error.OutOfMemory;
            out.appendSlice(self.a(), pt.name) catch return error.OutOfMemory;
        }
        for (def.statics) |sd| {
            if (!sd.kw) continue;
            if (out.items.len > 0) out.appendSlice(self.a(), ", ") catch return error.OutOfMemory;
            out.appendSlice(self.a(), sd.name) catch return error.OutOfMemory;
        }
        return out.items;
    }

    /// Does `word` name an argument of `def` that is written WITHOUT its name?
    fn positionalNamed(def: *const registry.OpDef, word: []const u8) bool {
        for (def.inputs) |pt| {
            if (std.mem.eql(u8, pt.name, word)) return !pt.kw;
        }
        for (def.statics) |sd| {
            if (std.mem.eql(u8, sd.name, word)) return !sd.kw and !sd.flag;
        }
        return false;
    }

    fn bindArg(self: *Parser, arg: Arg, port: registry.Port, op_name: []const u8, def: ?*const registry.OpDef, piped: bool) ParseError!Arg {
        var out = arg;
        if (arg.kind == .word) {
            // A sigil-led word reaching a non-string port is a mistake with
            // a specific correction, not an "unknown name". (A STRING port
            // still coerces it like any word — `entity bind @wall prim wall`
            // is the console grammar, and `@wall` there is text.) For `#`,
            // the common case is a second tag on a membership sink (one tag
            // per call, fork B); for `@`, a subject somewhere only tag/untag
            // could take one.
            if (port.ty != types.Tag.string) {
                if (arg.text.len > 1 and arg.text[0] == '#') {
                    return self.fail(arg.tok, "'{s}': a '#'-condition binds only a tag static, ONE per call — a second tag is a second statement; a read is plane.tags.{s}.count (or .joined / .left)", .{ arg.text, arg.text[1..] });
                }
                if (arg.text.len > 1 and arg.text[0] == '@') {
                    return self.fail(arg.tok, "'{s}' is an entity subject — only tag/untag take one; a field read is '{s}.pos' (folded at mount)", .{ arg.text, arg.text });
                }
                if (arg.text.len > 1 and arg.text[0] == '^') {
                    return self.fail(arg.tok, "'{s}' names an archetype — engine-owned; today only `derive set` takes one", .{arg.text});
                }
                // A bare word that NAMES A PORT of the operator being called
                // is not an unknown name — it is the reader writing a
                // positional argument as a keyword, and "unknown name" sends
                // them hunting for a missing `as`. Found 2026-08-26 by a
                // no-priors reader who made this mistake FOUR TIMES in one
                // program: `kick attack 100ms decay 4s`, `ease tau 2s`, `hold
                // for 30s`, `step of […]`. They were not guessing — `cast …
                // radius <r> at <pos> decay <d>`, `take 3 from 1` and
                // `integrate max 100` all do carry words, and nothing they
                // read said which do and which do not. Same shape as `sample
                // 5` → "write it with a unit": name the mistake, give the
                // spelling. The spelling comes from the registry, in the
                // manual §12 notation, so the two cannot drift.
                if (def) |d| {
                    if (positionalNamed(d, arg.text)) {
                        const spelling = try self.argSpelling(d, piped);
                        const kws = try self.keywordArgs(d);
                        if (kws.len > 0) {
                            return self.fail(arg.tok, "'{s}' is an argument of '{s}' that is written WITHOUT its name — drop the word: '{s}{s}'. The ones '{s}' does take by name: {s}", .{ arg.text, op_name, op_name, spelling, op_name, kws });
                        }
                        return self.fail(arg.tok, "'{s}' is an argument of '{s}' that is written WITHOUT its name — drop the word: '{s}{s}'. '{s}' takes no argument by name", .{ arg.text, op_name, op_name, spelling, op_name });
                    }
                }
                return self.fail(arg.tok, "unknown name '{s}'", .{arg.text});
            }
            var pk = struple.Packer.init(self.a());
            pk.appendString(arg.text) catch return error.OutOfMemory;
            const bytes = pk.toOwnedSlice() catch return error.OutOfMemory;
            out = .{ .kind = .literal, .source = .{ .literal = bytes }, .ty = types.Tag.string, .text = arg.text, .kw = arg.kw, .tok = arg.tok };
        }
        if (port.one_of.len > 0 and out.kind == .literal) {
            if (types.asString(out.source.literal)) |s| {
                const ok = for (port.one_of) |v| {
                    if (std.mem.eql(u8, s, v)) break true;
                } else false;
                // Name the SET, not just the port. A closed value set whose
                // refusal doesn't say what is in it makes the author guess,
                // which is the one thing "loud, never a guess" forbids — and
                // the list is right here, already the thing tab-complete
                // offers. (Found 2026-08-25 by a tier-2 gate asserting the
                // message; the check itself was correct and silent about the
                // only fact that helps.)
                if (!ok) {
                    var buf: [192]u8 = undefined;
                    var n: usize = 0;
                    for (port.one_of, 0..) |v, i| {
                        const sep = if (i == 0) "" else ", ";
                        const piece = std.fmt.bufPrint(buf[n..], "{s}{s}", .{ sep, v }) catch break;
                        n += piece.len;
                    }
                    return self.fail(arg.tok, "'{s}' is not an allowed value for '{s}' port '{s}' — expected one of: {s}", .{ s, op_name, port.name, buf[0..n] });
                }
            }
        }
        return out;
    }

    fn portIndex(ports: []const registry.Port, name: []const u8) ?usize {
        for (ports, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) return i;
        }
        return null;
    }

    fn emptyStatic(kind: registry.StaticKind) registry.StaticVal {
        return switch (kind) {
            .path => .{ .path = "" },
            .word => .{ .word = "" },
            .literal => .{ .literal = "" },
            .channel => .{ .channel = "" },
            .subject => .{ .subject = "" },
            .condition => .{ .condition = "" },
            .shape => .{ .shape = "" },
        };
    }

    fn opHasShape(def: *const registry.OpDef) bool {
        for (def.statics) |sd| {
            if (sd.kind == .shape) return true;
        }
        return false;
    }

    fn opHasKeywords(def: *const registry.OpDef) bool {
        if (def.body_kw.len > 0) return true;
        for (def.statics) |sd| {
            if (sd.kw) return true;
        }
        for (def.inputs) |port| {
            if (port.kw) return true;
        }
        return false;
    }

    /// The keyword name if `word` introduces a kw-declared static or port.
    fn keywordOf(def: *const registry.OpDef, word: []const u8) ?[]const u8 {
        if (def.body_kw.len > 0 and std.mem.eql(u8, def.body_kw, word)) return def.body_kw;
        for (def.statics) |sd| {
            if (sd.kw and std.mem.eql(u8, sd.name, word)) return sd.name;
        }
        for (def.inputs) |port| {
            if (port.kw and std.mem.eql(u8, port.name, word)) return port.name;
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

    /// How many ports a section leaves OPEN: required inputs with no source.
    /// An unbound *optional* port is not open — it is absent, which is a
    /// different thing and must not be counted as a slot the consumer fills.
    fn openPorts(self: *Parser, target: *Target, section_node: NodeId) usize {
        const n = &target.nodes.items[section_node];
        const def = self.reg.get(n.op);
        var open: usize = 0;
        for (n.inputs) |sid| {
            const s = &target.slots.items[sid];
            if (s.source != .none) continue;
            if (s.port < def.inputs.len and def.inputs[s.port].optional) continue;
            open += 1;
        }
        return open;
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
                // A `}` ends the argument list only inside an `also` block —
                // a record argument consumed its own closer long before we get
                // here, so an unmatched `}` anywhere else is still the loud
                // error it always was, one frame later at the statement end.
                .rbrace => if (self.block_depth > 0) return else try args.append(self.a(), try self.parseArgValue(target)),
                // A `{` is a record argument only when it opens like one
                // (`{name:`). Anything else is a fan-out block, which belongs
                // to the statement, not the argument list — this is what lets
                // `every 1f { cast … }` end `every`'s arguments at the brace.
                .lbrace => {
                    if (!self.braceOpensRecord()) return;
                    try args.append(self.a(), try self.parseArgValue(target));
                },
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

    /// Arguments for a tail operator (§3.11). The grammar is closed: a fixed
    /// prefix — one positional value per static, then one per non-tail port
    /// the pipe didn't feed — and then *the rest of the line, verbatim*, as a
    /// string literal on the tail port. Kwargs don't exist here, `//` and
    /// `#` are text (a comment cannot follow a tail — the tail takes the raw
    /// line), and `as` after the tail is captured
    /// as text too: the tail ends the chain. An unquoted `|` anywhere in the
    /// tail fails loud; a fully-quoted tail is the escape hatch and may
    /// contain anything.
    fn parseTailArgs(self: *Parser, target: *Target, def: *const registry.OpDef, args: *std.ArrayListUnmanaged(Arg), op_tok: Token, primary_bound: bool) ParseError!void {
        if (primary_bound and def.inputs.len == 1) {
            return self.fail(op_tok, "'{s}' takes no stream input — its only port is the tail", .{def.name});
        }
        const n_fixed = def.statics.len + (def.inputs.len - 1) - @intFromBool(primary_bound);
        var i: usize = 0;
        while (i < n_fixed) : (i += 1) {
            const t = self.peek();
            if (t.kind == .newline or t.kind == .eof) break; // binding reports what's missing
            try args.append(self.a(), try self.parseArgValue(target));
        }

        const tail_port = def.inputs[def.inputs.len - 1];

        // tail_all: the rest of the INPUT, verbatim to EOF — newlines and
        // comments included, because the text is somebody else's whole
        // program (`rill remount`, a notebook document). Capture starts at
        // the character after the last consumed token, NOT at the next
        // token's offset: a source whose first line is a comment has no
        // token before its newline, and slicing from the newline is exactly
        // what made a comment-led cell unmountable (rillbook's first drive).
        if (tail_port.tail_all) {
            var from: usize = self.src.len;
            if (self.pos > 0) {
                const prev = self.toks[self.pos - 1];
                // A tail slices the RAW SOURCE, and a spliced token's offset
                // points into the `using` line it was captured from — so the
                // slice would silently start in the wrong place. Refuse
                // instead of guessing (and `fail` names the fold).
                if (prev.fold != 0) {
                    return self.fail(prev, "'{s}' takes its tail from the raw source, so a fold cannot supply the token before it — write the value out", .{def.name});
                }
                // A string token's off sits on its opening quote and its text
                // is the raw span between quotes: raw end = off + 1 + len + 1.
                from = prev.off + prev.text.len + @as(usize, if (self.src.len > prev.off and self.src[prev.off] == '"') 2 else 0);
            }
            while (self.peek().kind != .eof) _ = self.next(); // the tail owns everything
            const text_all = std.mem.trim(u8, self.src[@min(from, self.src.len)..], " \t\r\n");
            if (text_all.len == 0) {
                if (tail_port.optional) return;
                return self.fail(op_tok, "'{s}' expects text for its tail port '{s}'", .{ def.name, tail_port.name });
            }
            var pk_all = struple.Packer.init(self.a());
            pk_all.appendString(text_all) catch return error.OutOfMemory;
            const bytes_all = pk_all.toOwnedSlice() catch return error.OutOfMemory;
            try args.append(self.a(), .{ .kind = .literal, .source = .{ .literal = bytes_all }, .ty = types.Tag.string, .tok = op_tok });
            return;
        }

        // A tail is VERBATIM SOURCE, so nothing here expands: a `:name` inside
        // a tail is text, exactly as `//` and `#` are text there. The one case
        // that cannot be text is a fold that expanded INTO the tail's first
        // token — then the offsets belong to the `using` line and the slice
        // would be nonsense — so that refuses by name.
        const start_tok = self.peek();
        if (start_tok.fold != 0) {
            return self.fail(start_tok, "'{s}' takes the rest of the line verbatim from the source — a fold cannot supply its tail", .{def.name});
        }
        var text: []const u8 = "";
        if (start_tok.kind != .newline and start_tok.kind != .eof) {
            while (self.peek().kind != .newline and self.peek().kind != .eof) _ = self.next();
            text = std.mem.trim(u8, self.src[start_tok.off..self.peek().off], " \t\r");
        }

        if (text.len == 0) {
            if (tail_port.optional) return; // unbound ⇒ .none, the op sees null
            return self.fail(op_tok, "'{s}' expects text for its tail port '{s}'", .{ def.name, tail_port.name });
        }
        var final_text = text;
        if (quotedSpan(text)) |inner| {
            final_text = try self.unescape(inner);
        } else if (self.block_depth > 0 and std.mem.indexOfScalar(u8, text, '}') != null) {
            // Same shape as the pipe rule, and checked before it: a tail takes
            // the rest of the LINE, so a one-line `also { … }` hands it the
            // block's own closer — and then everything after the block too,
            // which is where the pipe rule would fire with the later cause.
            return self.fail(start_tok, "tail port consumed the block's '}}' — put the tail operator on its own line, or quote the text", .{});
        } else if (std.mem.indexOfScalar(u8, text, '|') != null) {
            return self.fail(start_tok, "tail port consumed a pipe — quote the locator or restructure", .{});
        }
        var pk = struple.Packer.init(self.a());
        pk.appendString(final_text) catch return error.OutOfMemory;
        const bytes = pk.toOwnedSlice() catch return error.OutOfMemory;
        try args.append(self.a(), .{ .kind = .literal, .source = .{ .literal = bytes }, .ty = types.Tag.string, .tok = start_tok });
    }

    /// arg := literal | path | name(.field)* | record | "(" opcall ")"
    /// A value in a position that can never take a section — a record field or
    /// an array element. There, `(op …)` is a **complete operator call**, not a
    /// partial application (ratified 2026-08-25): nothing at a field position
    /// consumes an open port, so the section reading would be a guess, and a
    /// guess that binds `40ms` to `octaves` at that.
    ///
    /// This is what lets a record be built from computed streams —
    /// `{x: (noise 40ms seed 1), y: (noise 40ms seed 2)}` — without the comma
    /// becoming significant inside an argument list. The parens already
    /// delimit; they just had to mean the other thing here.
    fn parseFieldValue(self: *Parser, target: *Target) ParseError!Arg {
        if (self.peek().kind != .lparen) return self.parseArgValue(target);
        const open = self.next();
        try self.expandIfFold(); // `{x: (:op 2)}`
        const op_tok = self.next();
        if (op_tok.kind != .name and op_tok.kind != .sym) {
            return self.fail(op_tok, "expected an operator inside '(…)'", .{});
        }
        const res = try self.parseOpcall(target, op_tok, null, false);
        const close = self.next();
        if (close.kind != .rparen) return self.fail(close, "expected ')' to close '{s}'", .{op_tok.text});
        if (res.outputs.len == 0) return self.fail(op_tok, "'{s}' has no output to put in a field", .{op_tok.text});
        _ = open;
        return .{ .kind = .stream, .source = res.outputs[0], .ty = self.sourceTy(target, res.outputs[0]), .tok = op_tok };
    }

    fn parseArgValue(self: *Parser, target: *Target) ParseError!Arg {
        // Argument position is the reason `using` exists rather than a
        // namespace import: `push :flock` splices a whole expression where a
        // def could never go, because `instantiate` is only reachable from
        // opcall position.
        try self.expandIfFold();
        const t = self.peek();
        switch (t.kind) {
            .number, .duration, .string => {
                const lit = try self.parseLiteral(target);
                return .{ .kind = .literal, .source = lit.source, .ty = lit.ty, .tok = t };
            },
            .lbrace => {
                const rec = try self.parseRecord(target);
                const outs = target.nodes.items[rec].outputs;
                return .{ .kind = .stream, .source = .{ .wire = outs[0] }, .ty = types.Tag.record, .tok = t };
            },
            .lbracket => {
                const arr = try self.parseArray(target);
                const outs = target.nodes.items[arr].outputs;
                return .{ .kind = .stream, .source = .{ .wire = outs[0] }, .ty = types.Tag.array, .tok = t };
            },
            .lparen => {
                _ = self.next();
                // `(.field)` — a projection section, which is what `sort by`
                // and `map` mostly want. It is the `project` operator with its
                // one port left open, exactly like every other section; the
                // spelling just skips the operator's name because a field read
                // already has one.
                if (self.peek().kind == .dot) {
                    _ = self.next();
                    const ft = self.next();
                    if (ft.kind != .name) return self.fail(ft, "expected a field name after '.' in a section", .{});
                    if (self.peek().kind == .dot) {
                        return self.fail(self.peek(), "a section body is ONE operator — '(.{s}.…)' is two steps; name it with a 'def'", .{ft.text});
                    }
                    const proj_id = self.reg.find("project") orelse return self.fail(ft, "core operator 'project' is not registered", .{});
                    const st = try self.a().alloc(registry.StaticVal, 1);
                    st[0] = .{ .word = try self.a().dupe(u8, ft.text) };
                    const srcs = try self.a().alloc(Source, 1);
                    srcs[0] = .none;
                    const pnode = try self.makeNode(target, proj_id, srcs, st, ft);
                    const pclose = self.next();
                    if (pclose.kind != .rparen) return self.fail(pclose, "expected ')' after '.{s}'", .{ft.text});
                    const pouts = target.nodes.items[pnode].outputs;
                    return .{ .kind = .section, .source = .{ .wire = pouts[0] }, .section_node = pnode, .tok = ft };
                }
                try self.expandIfFold(); // `where (:pred)`
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
                if (isPathHead(t.text)) {
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
            bound[pi] = try self.bindArg(arg, .{ .name = tmpl.ports[pi].name, .ty = tmpl.ports[pi].ty }, tmpl.name, null, false);
        }
        for (args.items) |arg| {
            if (arg.kw.len > 0) continue;
            if (arg.kind == .section) return self.fail(arg.tok, "predicates cannot bind to def ports (v0)", .{});
            const pi = for (tmpl.ports, 0..) |_, i| {
                if (bound[i] == null) break i;
            } else return self.fail(arg.tok, "too many arguments for '{s}' ({d} port(s))", .{ tmpl.name, tmpl.ports.len });
            bound[pi] = try self.bindArg(arg, .{ .name = tmpl.ports[pi].name, .ty = tmpl.ports[pi].ty }, tmpl.name, null, false);
        }
        const port_sources = try self.a().alloc(Source, tmpl.ports.len);
        for (tmpl.ports, 0..) |pd, i| {
            const arg = bound[i] orelse {
                // A port with a default is OPTIONAL at the call site: the
                // declared literal is spliced in exactly as if the caller had
                // typed it. Same bytes, same `.literal` Source, so the node it
                // feeds is indistinguishable from one built by a written
                // argument — and its knob path is settable from outside like
                // any other (G7). The signature ban on a required port after a
                // defaulted one is what makes this fill unambiguous.
                if (pd.default) |bytes| {
                    port_sources[i] = .{ .literal = bytes };
                    continue;
                }
                return self.fail(op_tok, "port '{s}' of '{s}' is not bound", .{ pd.name, tmpl.name });
            };
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
            // A def body may hold a membership sink (templates ban `path`
            // statics, but `@subject`/`#tag` pairs are legal there) — its
            // composed member write must land in the write list HERE, or an
            // instantiated `tag` slips past the cycle check unseen.
            if (target.template == null and self.reg.get(tn.op).class.writes()) {
                self.prog.registerWrites(statics, new_id) catch return error.OutOfMemory;
            }
        }

        const outs = try self.a().alloc(Source, tmpl.outputs.len);
        for (tmpl.outputs, 0..) |to, i| {
            outs[i] = substSource(to.source, slot_base, port_sources);
        }
        return .{ .node = null, .outputs = outs };
    }
};

/// If `text` is exactly one quoted string — `"…"` with nothing after the
/// close — return the span inside the quotes (escapes honored, not applied).
/// Anything else, a partial quote included, is verbatim tail text.
fn quotedSpan(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[0] != '"') return null;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == '"') return if (i == text.len - 1) text[1..i] else null;
    }
    return null;
}

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
