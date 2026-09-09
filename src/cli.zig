//! `rill` — the front door for a TOOL, as `rill-run` is the front door for a
//! person.
//!
//! Three subcommands, and all of them are a thin skin over machinery that
//! already existed: `fmt` is `parse` + `script.print` (the printer landed
//! 2026-09-09), `check` is `parse` and the `Diag` it fills, `ops` is the
//! REGISTRY, read out. Nothing here decides anything about the language; what
//! it decides is how a failure reaches a program that is not a person.
//!
//!     rill fmt   [--host-row] [-]      program on stdin  → program on stdout
//!     rill check --json [--host-row] [-]                 → one JSON object
//!     rill ops   [--host-row] [--tag <t>]… [--name <s>] [--json]
//!
//! `ops` is the odd one out and says so: it reads NO stdin, because its input
//! is the registry the binary was built with. Running it at a terminal must
//! answer, not sit waiting for a program nobody is going to type.
//!
//! ## Exit codes are the interface
//!
//! sysexits, because the caller is `editors/vscode/src/rillcli.js` and it
//! branches on them:
//!
//!   0   it worked
//!   64  EX_USAGE — the COMMAND LINE was not understood. The editor reads
//!       this as "this binary does not have the feature", says so once, and
//!       goes quiet.
//!   65  EX_DATAERR — the PROGRAM was not understood. The editor reads this
//!       as "his file does not parse", which is not the formatter's news to
//!       break: the squiggle already said it, in the place it happened.
//!   70  EX_SOFTWARE — we broke. The editor leaves existing squiggles alone
//!       rather than clearing them on a guess.
//!
//! 64 and 65 have to be TOLD APART, and that is why they are the two gates
//! with the sharpest mutations: collapse them and a half-typed buffer turns
//! formatting off for the session, or a missing subcommand reports as a
//! syntax error in a file that is fine.
//!
//! ## The one rule that protects a file
//!
//! **Nothing reaches stdout until the whole program has been formatted.**
//! `fmt` writes into a buffer and copies it out on the last line of the happy
//! path; a refusal returns 65 having written NOTHING. A formatter that
//! streams as it goes hands a truncated program to an editor that is about to
//! replace the whole document with it, and the file is gone. `F5` is that
//! gate and its mutation is to emit the partial buffer anyway.
//!
//! ## Why every `fmt` and `check` tries the parse twice
//!
//! A `.rill` file does not say which plane it is for, and a spray kernel's
//! top-level statements use row words that refuse on the world plane. So
//! `parse` is tried first and `parseKernel` second — the same order and for
//! the same reason as `tools/roundtrip.zig`. A file that fails BOTH reports
//! the diagnostic that reached further into it: see `further`.

const std = @import("std");
const rill = @import("rill");
const host_row = @import("host_row");

/// sysexits(3), the subset this binary speaks. Mirrored in `rillcli.js` as
/// EX_USAGE / EX_DATAERR, and in the extension README's contract table.
pub const EX_OK: u8 = 0;
pub const EX_USAGE: u8 = 64;
pub const EX_DATAERR: u8 = 65;
pub const EX_SOFTWARE: u8 = 70;

const usage_text =
    \\rill — the dataflow language's command line.
    \\
    \\  rill fmt [--host-row] [-]
    \\        Format the program on stdin. The formatted program goes to
    \\        stdout and nothing else does. Comments are retained.
    \\
    \\  rill check --json [--host-row] [-]
    \\        Parse the program on stdin and print one JSON object:
    \\        {"ok": bool, "diagnostics": [{line, col, severity, code, message}]}
    \\
    \\  rill ops [--host-row] [--tag <name>]... [--name <substring>] [--json]
    \\        Print the operator vocabulary, each word with its help, filed
    \\        under its HOME tag. Reads no stdin: the input is the registry
    \\        this binary was built with. Tags sorted, words sorted inside a
    \\        tag. `--tag` may be repeated and ANDs.
    \\
    \\  rill help | --help        this
    \\  rill version | --version  the library version
    \\
    \\Flags
    \\  --host-row  Register spindrift's fifteen row words as stubs, so a
    \\              spray kernel parses. rill core does not know `spawn`,
    \\              `near` or `push` and must not: the registry is the
    \\              HOST's. Without this, 21 of the 47 corpus programs
    \\              report unknown operators — all of them correct files.
    \\              On `ops`, it is how you see a host's words listed.
    \\  --tag       `ops` only, repeatable, AND: operators carrying every
    \\              tag named. An unknown tag is refused BY NAME with the
    \\              list — an empty page cannot say "no such tag" apart
    \\              from "nothing matches".
    \\  --name      `ops` only: operators whose name contains this,
    \\              case-insensitively. ANDs with --tag.
    \\  --json      On `check` it is required (the only reply shape there
    \\              is); on `ops` it is optional — the plain listing is for
    \\              a person, the JSON carries ports and statics too.
    \\  -           Read stdin. The only input there is; a file path is
    \\              refused rather than half-supported. `ops` takes none.
    \\
    \\Exit  0 ok · 64 command line not understood · 65 program did not parse
    \\      · 70 internal
    \\
;

/// Bumped with the library, not with this file. A tool that reports its own
/// version tells you nothing about the parser you are talking to.
const version_text = "rill 0.1.0\n";

// ---------------------------------------------------------------------------
// The command line
// ---------------------------------------------------------------------------

const Opts = struct {
    host_row: bool = false,
};

/// `ops` carries more knobs than `fmt`/`check`, so it gets its own struct
/// rather than growing theirs: a `--tag` on `fmt` would be a flag that means
/// nothing, accepted.
const MAX_TAGS: usize = 8;
const OpsOpts = struct {
    host_row: bool = false,
    json: bool = false,
    /// The tags asked for, **AND semantics** — an operator must carry every
    /// one. Union would answer a question nobody asks: two tags are how you
    /// narrow, and `--tag time --tag gate` means "the rate gates", not
    /// "everything temporal plus everything that can swallow a value".
    tags: [MAX_TAGS][]const u8 = undefined,
    n_tags: usize = 0,
    /// Case-insensitive substring over the operator NAME. Combines with the
    /// tags by AND, like everything else here.
    name: []const u8 = "",

    fn wants(self: *const OpsOpts, def: *const rill.OpDef) bool {
        for (self.tags[0..self.n_tags]) |t| {
            if (!def.tagged(t)) return false;
        }
        if (self.name.len > 0 and !containsIgnoreCase(def.name, self.name)) return false;
        return true;
    }
};

/// ASCII case-insensitive substring. `--name Add` must find `add`: a reader
/// hunting for a word does not know how it is cased, and every operator in
/// the table is lower-case, so a case-sensitive match would only ever
/// surprise.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, haystack[i .. i + needle.len]) |n, h| {
            if (std.ascii.toLower(n) != std.ascii.toLower(h)) continue :outer;
        }
        return true;
    }
    return false;
}

pub const Cmd = union(enum) {
    fmt: Opts,
    check: Opts,
    ops: OpsOpts,
    help,
    version,
};

pub const UsageError = error{Usage};

/// argv WITHOUT argv[0].
///
/// Dispatch is a switch on one word and the flags are parsed per subcommand,
/// so a third subcommand is a case and a struct, not a rewrite. That shape is
/// the whole reason this is a function rather than an if-ladder in `main`.
pub fn parseArgs(argv: []const []const u8, why: *[]const u8) UsageError!Cmd {
    if (argv.len == 0) {
        why.* = "no subcommand — try `rill help`";
        return error.Usage;
    }
    const sub = argv[0];
    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h"))
        return .help;
    if (std.mem.eql(u8, sub, "version") or std.mem.eql(u8, sub, "--version"))
        return .version;

    // `ops` first, because its flag set is its own: it takes a VALUE flag
    // (`--tag <name>`, repeatable) and no `-`, and folding it into the loop
    // below would make `fmt --tag math` legal and meaningless.
    if (std.mem.eql(u8, sub, "ops")) {
        var o = OpsOpts{};
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (std.mem.eql(u8, arg, "--host-row")) {
                o.host_row = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                o.json = true;
            } else if (std.mem.eql(u8, arg, "--tag") or std.mem.eql(u8, arg, "--name")) {
                const is_tag = std.mem.eql(u8, arg, "--tag");
                i += 1;
                if (i == argv.len) {
                    why.* = if (is_tag)
                        "`--tag` wants a name — `rill ops` prints the tags"
                    else
                        "`--name` wants a substring";
                    return error.Usage;
                }
                if (is_tag) {
                    if (o.n_tags == MAX_TAGS) {
                        why.* = "too many --tag filters";
                        return error.Usage;
                    }
                    o.tags[o.n_tags] = argv[i];
                    o.n_tags += 1;
                } else {
                    o.name = argv[i];
                }
            } else if (std.mem.startsWith(u8, arg, "--tag=") or std.mem.startsWith(u8, arg, "--name=")) {
                const is_tag = std.mem.startsWith(u8, arg, "--tag=");
                const v = if (is_tag) arg["--tag=".len..] else arg["--name=".len..];
                if (v.len == 0) {
                    why.* = "`--tag=` and `--name=` want a value";
                    return error.Usage;
                }
                if (is_tag) {
                    if (o.n_tags == MAX_TAGS) {
                        why.* = "too many --tag filters";
                        return error.Usage;
                    }
                    o.tags[o.n_tags] = v;
                    o.n_tags += 1;
                } else {
                    o.name = v;
                }
            } else if (std.mem.eql(u8, arg, "-")) {
                // Named rather than lumped in with an unknown flag: `-` is the
                // right instinct after `fmt -` and `check -`, and "unknown
                // operand" would read as a typo rather than as a fact about
                // this subcommand.
                why.* = "`ops` reads no program — its input is the registry, not stdin";
                return error.Usage;
            } else {
                why.* = "unknown flag or operand — `ops` takes --host-row, --tag <name>, --name <substring> and --json";
                return error.Usage;
            }
        }
        return .{ .ops = o };
    }

    const is_fmt = std.mem.eql(u8, sub, "fmt");
    const is_check = std.mem.eql(u8, sub, "check");
    if (!is_fmt and !is_check) {
        why.* = "unknown subcommand — `fmt`, `check` and `ops` are what there is";
        return error.Usage;
    }

    var opts = Opts{};
    var json = false;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--host-row")) {
            opts.host_row = true;
        } else if (is_check and std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            // stdin, which is the only input. Accepted rather than required
            // so `rill fmt` at a shell behaves like `cat`.
        } else {
            // A FILE PATH lands here too, and that is deliberate: half a file
            // interface — read it but never write it back — is worse than
            // none, and `<` is one character.
            why.* = "unknown flag or operand — only `-` (stdin) is read";
            return error.Usage;
        }
    }
    if (is_check and !json) {
        // The only consumer is a program, and a second human-readable output
        // shape invented with no reader is a second thing to keep in step
        // with the first. Refused LOUDLY, naming the fix.
        why.* = "`check` needs --json — it is the only reply shape there is";
        return error.Usage;
    }
    return if (is_fmt) .{ .fmt = opts } else .{ .check = opts };
}

// ---------------------------------------------------------------------------
// The parse, twice
// ---------------------------------------------------------------------------

fn makeRegistry(gpa: std.mem.Allocator, opts: Opts) !rill.Registry {
    var reg = try rill.Registry.init(gpa);
    errdefer reg.deinit();
    try rill.registerCore(&reg);
    try rill.registerRbf(&reg);
    if (opts.host_row) try host_row.register(&reg);
    return reg;
}

/// Which of two failed parses to report.
///
/// The one that reached FURTHER into the file understood more of it. A spray
/// kernel with a real mistake on line 30 fails the WORLD parse at its first
/// row word on line 4 — a line that is perfectly correct — and fails the
/// KERNEL parse where the mistake is. Reporting the world parse would put the
/// squiggle on a good line and call a kernel a mistake; reporting the further
/// one puts it where the author has to look. When both stop in the same place
/// (an ordinary world program with an ordinary syntax error) they hold the
/// same message and the choice does not arise.
fn further(a: rill.Diag, b: rill.Diag) rill.Diag {
    if (b.line > a.line) return b;
    if (b.line == a.line and b.col > a.col) return b;
    return a;
}

const Parsed = union(enum) {
    ok: rill.Program,
    refused: rill.Diag,
};

fn parseEither(gpa: std.mem.Allocator, reg: *rill.Registry, src: []const u8) !Parsed {
    var world = rill.Diag{};
    if (rill.parse(gpa, reg, "stdin", src, &world)) |prog| {
        return .{ .ok = prog };
    } else |err| switch (err) {
        error.Parse => {},
        else => |e| return e,
    }
    var kernel = rill.Diag{};
    if (rill.parseKernel(gpa, reg, "stdin", src, &kernel)) |prog| {
        return .{ .ok = prog };
    } else |err| switch (err) {
        error.Parse => return .{ .refused = further(world, kernel) },
        else => |e| return e,
    }
}

// ---------------------------------------------------------------------------
// fmt
// ---------------------------------------------------------------------------

fn doFmt(
    gpa: std.mem.Allocator,
    opts: Opts,
    src: []const u8,
    out: *std.ArrayList(u8),
    err: *std.ArrayList(u8),
) !u8 {
    var reg = try makeRegistry(gpa, opts);
    defer reg.deinit();

    var parsed = try parseEither(gpa, &reg, src);
    switch (parsed) {
        .refused => |d| {
            try err.writer().print("{d}:{d}: {s}\n", .{ d.line, d.col, d.msg() });
            // NOTHING on stdout. The caller replaces a whole document with
            // what comes back here.
            return EX_DATAERR;
        },
        .ok => {},
    }
    defer parsed.ok.deinit();

    const s = parsed.ok.script orelse {
        try err.writer().print("internal: the parse kept no script\n", .{});
        return EX_SOFTWARE;
    };
    const text = try rill.printScript(gpa, s);
    defer gpa.free(text);
    // The one write, on the last line of the happy path.
    try out.appendSlice(text);
    return EX_OK;
}

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

/// JSON string body, escaped. Written out rather than borrowed because a
/// diagnostic message is arbitrary text — `set` became `write` carries
/// backticks and parentheses, and a shape literal can carry a quote — and a
/// reply the client cannot `JSON.parse` reads as "the checker crashed", which
/// leaves stale squiggles on screen.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn doCheck(
    gpa: std.mem.Allocator,
    opts: Opts,
    src: []const u8,
    out: *std.ArrayList(u8),
) !u8 {
    var reg = try makeRegistry(gpa, opts);
    defer reg.deinit();

    var parsed = try parseEither(gpa, &reg, src);
    const w = out.writer();
    switch (parsed) {
        .ok => |*prog| {
            defer prog.deinit();
            // Warnings ride the SAME envelope as a refusal, with
            // `"severity":"warning"` — built 2026-09-09 on the trigger this
            // site recorded for itself (*"a second `warn` site in the
            // parser"*), which `layout` fired with two. `ok` stays TRUE: the
            // program parsed, the formatter may still run, and the editor's
            // `checkSource` reads a non-empty diagnostics list on exit 0
            // exactly as it reads one on 65.
            //
            // A warning that never reaches a client is a gate over a field
            // nobody reads. `layout`'s whole reason for warning rather than
            // refusing is that a stale coordinate must be VISIBLE and not
            // fatal — invisible and not fatal is just silent.
            try w.writeAll("{\"ok\":true,\"diagnostics\":[");
            for (prog.warnings.items, 0..) |wa, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"line\":{d},\"col\":{d},\"severity\":\"warning\",\"code\":", .{ wa.line, wa.col });
                try writeJsonString(w, wa.code.name());
                try w.writeAll(",\"message\":");
                try writeJsonString(w, wa.msg);
                try w.writeAll("}");
            }
            try w.writeAll("]}\n");
            return EX_OK;
        },
        .refused => |d| {
            try w.writeAll("{\"ok\":false,\"diagnostics\":[{\"line\":");
            try w.print("{d},\"col\":{d}", .{ d.line, d.col });
            // No `end_line`/`end_col`. `Diag` has no end, and the client
            // derives a better one than a token length would be: it widens
            // the caret over the whole dotted run, so a refusal on
            // `plane.drift.@self` underlines all twenty characters instead of
            // the five that are `plane`. The contract makes both optional for
            // exactly this reason (`rillcli.js` / `spanFor`, gate E7).
            try w.writeAll(",\"severity\":\"error\",\"code\":");
            try writeJsonString(w, d.code.name());
            try w.writeAll(",\"message\":");
            try writeJsonString(w, d.msg());
            try w.writeAll("}]}\n");
            return EX_DATAERR;
        },
    }
}

// ---------------------------------------------------------------------------
// ops — the registry, read out by group
//
// The customer for `OpDef.group` on the day it landed: a field with no reader
// is a declaration, and a palette does not exist yet. This does — and it is
// also the natural source for the LLM-facing vocabulary document, which is why
// `--json` carries ports and statics and not only the help line.
//
// **Deterministic, so the output can be gated byte-exactly**: headings sorted,
// operators sorted under them, and the name column padded to the widest name
// IN THAT HEADING rather than in the whole listing — so `--tag record` prints
// the same bytes whether or not a host registered something long.
// ---------------------------------------------------------------------------

/// Home tag first, then name — a total order, because names are unique in a
/// registry (`register` refuses a duplicate).
fn opBefore(_: void, a: *const rill.OpDef, b: *const rill.OpDef) bool {
    if (!std.mem.eql(u8, a.home(), b.home())) return std.mem.lessThan(u8, a.home(), b.home());
    return std.mem.lessThan(u8, a.name, b.name);
}

fn writeJsonPorts(w: anytype, reg: *const rill.Registry, ports: []const rill.Port) !void {
    try w.writeAll("[");
    for (ports, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, p.name);
        try w.writeAll(",\"type\":");
        try writeJsonString(w, reg.types.name(p.ty));
        try w.writeAll(",\"kind\":");
        try writeJsonString(w, @tagName(p.kind));
        try w.print(",\"optional\":{},\"kw\":{},\"tail\":{},\"broadcasts\":{}", .{ p.optional, p.kw, p.tail, p.broadcasts });
        try w.writeAll(",\"one_of\":[");
        for (p.one_of, 0..) |v, j| {
            if (j > 0) try w.writeAll(",");
            try writeJsonString(w, v);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

/// Every tag any registered operator carries, sorted, once each. What an
/// unknown-tag refusal prints, and what `--json`'s `tags` block lists.
fn allTags(gpa: std.mem.Allocator, reg: *const rill.Registry) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).init(gpa);
    errdefer out.deinit();
    for (reg.ops.items) |*def| {
        for (def.tags) |t| {
            const seen = for (out.items) |u| {
                if (std.mem.eql(u8, u, t)) break true;
            } else false;
            if (!seen) try out.append(t);
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

fn doOps(gpa: std.mem.Allocator, o: OpsOpts, out: *std.ArrayList(u8), err: *std.ArrayList(u8)) !u8 {
    var reg = try makeRegistry(gpa, .{ .host_row = o.host_row });
    defer reg.deinit();

    var tags = try allTags(gpa, &reg);
    defer tags.deinit();

    // An unknown tag is a COMMAND LINE that was not understood, so 64 — and
    // this matters MORE under a filter model than it did under a tree: an
    // empty result cannot say "no such tag" apart from "nothing carries all
    // of these", and only one of those is the reader's mistake. Checked
    // before any filtering, so the message names the typo and not the
    // intersection.
    for (o.tags[0..o.n_tags]) |want| {
        const known = for (tags.items) |t| {
            if (std.mem.eql(u8, t, want)) break true;
        } else false;
        if (!known) {
            try err.writer().print("rill: no tag named '{s}'. There is:", .{want});
            for (tags.items) |t| try err.writer().print(" {s}", .{t});
            try err.writer().writeAll("\n");
            return EX_USAGE;
        }
    }

    var list = std.ArrayList(*const rill.OpDef).init(gpa);
    defer list.deinit();
    for (reg.ops.items) |*def| {
        if (o.wants(def)) try list.append(def);
    }

    // Every named tag exists and nothing carries all of them. That is an
    // honest answer to a well-formed question, so exit 0 — but NOT in
    // silence, and not on stdout, which a caller is piping.
    if (list.items.len == 0) {
        try err.writer().writeAll("rill: nothing matches");
        for (o.tags[0..o.n_tags]) |t| try err.writer().print(" --tag {s}", .{t});
        if (o.name.len > 0) try err.writer().print(" --name {s}", .{o.name});
        try err.writer().writeAll("\n");
        return EX_OK;
    }

    std.mem.sort(*const rill.OpDef, list.items, {}, opBefore);
    const w = out.writer();

    if (o.json) {
        try w.writeAll("{\"tags\":[");
        for (tags.items, 0..) |t, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try writeJsonString(w, t);
            try w.writeAll(",\"doc\":");
            try writeJsonString(w, reg.tagDoc(t) orelse "");
            try w.writeAll("}");
        }
        try w.writeAll("],\"groups\":[");
        var i: usize = 0;
        var first_group = true;
        while (i < list.items.len) {
            var j = i;
            while (j < list.items.len and std.mem.eql(u8, list.items[j].home(), list.items[i].home())) j += 1;
            if (!first_group) try w.writeAll(",");
            first_group = false;
            try w.writeAll("{\"name\":");
            try writeJsonString(w, list.items[i].home());
            // Always present, `""` when nobody wrote one — a consumer reading
            // a fixed shape beats one branching on a missing key.
            try w.writeAll(",\"doc\":");
            try writeJsonString(w, reg.tagDoc(list.items[i].home()) orelse "");
            try w.writeAll(",\"ops\":[");
            for (list.items[i..j], 0..) |def, k| {
                if (k > 0) try w.writeAll(",");
                try w.writeAll("{\"name\":");
                try writeJsonString(w, def.name);
                try w.writeAll(",\"home\":");
                try writeJsonString(w, def.home());
                try w.writeAll(",\"tags\":[");
                for (def.tags, 0..) |t, ti| {
                    if (ti > 0) try w.writeAll(",");
                    try writeJsonString(w, t);
                }
                try w.writeAll("],\"help\":");
                try writeJsonString(w, def.help);
                try w.writeAll(",\"class\":");
                try writeJsonString(w, @tagName(def.class));
                try w.writeAll(",\"routes\":");
                try writeJsonString(w, @tagName(def.routes));
                try w.print(",\"ticks\":{},\"fails_mount\":{},\"variadic\":{},\"body\":{d}", .{ def.ticks, def.fails_mount, def.variadic, def.body });
                try w.writeAll(",\"body_kw\":");
                try writeJsonString(w, def.body_kw);
                // The enforced columns ride BESIDE the tags and are never
                // folded into them — see `OpDef.tags`. A palette wanting
                // "row-legal AND tagged `space`" reads both here.
                try w.print(",\"row\":{{\"legal\":{},\"exact\":{},\"only\":{},\"channels\":{d}}}", .{ def.row.legal(), def.row.exact, def.row.only, def.row.channels });
                try w.writeAll(",\"inputs\":");
                try writeJsonPorts(w, &reg, def.inputs);
                try w.writeAll(",\"outputs\":");
                try writeJsonPorts(w, &reg, def.outputs);
                try w.writeAll(",\"statics\":[");
                for (def.statics, 0..) |sd, si| {
                    if (si > 0) try w.writeAll(",");
                    try w.writeAll("{\"name\":");
                    try writeJsonString(w, sd.name);
                    try w.writeAll(",\"kind\":");
                    try writeJsonString(w, @tagName(sd.kind));
                    try w.print(",\"kw\":{},\"optional\":{},\"flag\":{}}}", .{ sd.kw, sd.optional, sd.flag });
                }
                try w.writeAll("]}");
            }
            try w.writeAll("]}");
            i = j;
        }
        try w.writeAll("]}\n");
        return EX_OK;
    }

    var i: usize = 0;
    var first_group = true;
    while (i < list.items.len) {
        var j = i;
        var width: usize = 0;
        while (j < list.items.len and std.mem.eql(u8, list.items[j].home(), list.items[i].home())) : (j += 1) {
            if (list.items[j].name.len > width) width = list.items[j].name.len;
        }
        if (!first_group) try w.writeAll("\n");
        first_group = false;
        // `name (n) — sentence`, and the dash appears only when there is a
        // sentence: a heading trailing an em dash and nothing else reads as a
        // bug rather than as a gap, which is why `describeTag` refuses an
        // empty doc outright and why this still handles the absent one.
        if (reg.tagDoc(list.items[i].home())) |d| {
            try w.print("{s} ({d}) — {s}\n", .{ list.items[i].home(), j - i, d });
        } else {
            try w.print("{s} ({d})\n", .{ list.items[i].home(), j - i });
        }
        for (list.items[i..j]) |def| {
            try w.writeAll("  ");
            try w.writeAll(def.name);
            for (def.name.len..width) |_| try w.writeByte(' ');
            try w.print("  {s}\n", .{def.help});
            // The OTHER tags, indented under the word — the filter model made
            // visible. Omitted when there are none, so the common case (an
            // operator at home and nowhere else) stays one line.
            if (def.tags.len > 1) {
                try w.writeAll("  ");
                for (0..width) |_| try w.writeByte(' ');
                try w.writeAll("  also:");
                for (def.tags[1..]) |t| try w.print(" {s}", .{t});
                try w.writeAll("\n");
            }
        }
        i = j;
    }
    return EX_OK;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// The whole binary as a function over buffers, so a gate can execute the
/// CONTRACT — the exit code, and what is on stdout when it is 65 — rather
/// than a helper the contract is assembled from. `main` is the four lines
/// below that give it real file descriptors.
pub fn execute(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    src: []const u8,
    out: *std.ArrayList(u8),
    err: *std.ArrayList(u8),
) !u8 {
    var why: []const u8 = "";
    const cmd = parseArgs(argv, &why) catch {
        try err.writer().print("rill: {s}\n\n{s}", .{ why, usage_text });
        return EX_USAGE;
    };
    return switch (cmd) {
        .help => blk: {
            try out.appendSlice(usage_text);
            break :blk EX_OK;
        },
        .version => blk: {
            try out.appendSlice(version_text);
            break :blk EX_OK;
        },
        .fmt => |o| try doFmt(gpa, o, src, out, err),
        .check => |o| try doCheck(gpa, o, src, out),
        .ops => |o| try doOps(gpa, o, out, err),
    };
}

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // The command line is read BEFORE stdin, so `rill --nope` at a terminal
    // answers instead of waiting for a program nobody is going to type.
    var why: []const u8 = "";
    const cmd = parseArgs(args[1..], &why) catch {
        try std.io.getStdErr().writer().print("rill: {s}\n\n{s}", .{ why, usage_text });
        std.process.exit(EX_USAGE);
    };
    // `ops` joins `help` and `version` here, and it is not a detail: its input
    // is the registry, so a build that read stdin for it would sit at a
    // terminal waiting for a program nobody is going to type. Gated as `F14`.
    const src = switch (cmd) {
        .help, .version, .ops => "",
        else => try std.io.getStdIn().reader().readAllAlloc(gpa, 64 << 20),
    };
    defer if (src.len > 0) gpa.free(src);

    var out = std.ArrayList(u8).init(gpa);
    defer out.deinit();
    var err = std.ArrayList(u8).init(gpa);
    defer err.deinit();

    const code = execute(gpa, args[1..], src, &out, &err) catch |e| {
        try std.io.getStdErr().writer().print("rill: internal failure: {s}\n", .{@errorName(e)});
        std.process.exit(EX_SOFTWARE);
    };
    if (err.items.len > 0) try std.io.getStdErr().writeAll(err.items);
    if (out.items.len > 0) try std.io.getStdOut().writeAll(out.items);
    std.process.exit(code);
}

// ===========================================================================
// Gates — F, the front door.
//
// Every one names the mutation it was paid for and every mutation was RUN.
// The trap they are written against is the one that has bitten this repo all
// day: a mutation the code routes around has tested nothing. So the codes are
// read off `Diag.code` and never off the message text, and `fmt`'s refusal
// path is asserted on the BYTES of stdout rather than only on the exit code.
// ===========================================================================

const testing = std.testing;

const Result = struct {
    code: u8,
    out: []const u8,
    err: []const u8,
    fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.err);
    }
};

fn runCli(gpa: std.mem.Allocator, argv: []const []const u8, src: []const u8) !Result {
    var out = std.ArrayList(u8).init(gpa);
    errdefer out.deinit();
    var err = std.ArrayList(u8).init(gpa);
    errdefer err.deinit();
    const code = try execute(gpa, argv, src, &out, &err);
    return .{
        .code = code,
        .out = try out.toOwnedSlice(),
        .err = try err.toOwnedSlice(),
    };
}

/// A canonical world program: four-space bodies, one space either side of a
/// pipe, a comment block and a blank run. Written to the canon of 2026-09-09
/// so `fmt` must not move a byte of it.
const canon =
    \\// ══ THE ROOM ══
    \\
    \\// what the plane says about the player, and what we do about it
    \\plane.player.health | dropped_below 20 | write plane.audio.heartbeat
    \\
    \\def soften(x, rate = 0.25 (0..1)) =
    \\    x | lerp rate 1
    \\
    \\plane.player.stamina | soften 0.5 as eased
    \\eased | write plane.hud.stamina
    \\
;

/// A spray kernel: the top-level statements are row words, so this parses
/// only as a KERNEL and only with `--host-row`. Both halves matter — it is
/// the fixture for the flag gate and for the fallback.
const kernel_canon =
    \\// a spray kernel: row words at the top level
    \\near 0.5 as crowd
    \\crowd | write row.u3
    \\push 0.02
    \\perish
    \\
;

test "F1 G-canon: fmt hands a canonical program back byte for byte" {
    // THE claim format-on-save rests on. If a canonical file moves under
    // `fmt`, every save is a diff and the corpus is not canonical after all.
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "fmt", "-" }, canon);
    defer r.deinit(gpa);
    try testing.expectEqual(EX_OK, r.code);
    try testing.expectEqualStrings(canon, r.out);
}
// MUTATION: in `doFmt`, `try out.appendSlice(text)` → `try out.writer().print("// formatted\n{s}", .{text})`
// — the shape of a tool that says hello on stdout, which the contract's
// fourth requirement forbids because stdout is written into the file.
// OBSERVED: red, "// formatted" on the first line.

test "F2 G-idempotent: fmt of fmt is fmt" {
    // Format-on-save runs on EVERY save. A printer that moves the file a
    // second time makes every save a diff against the last one.
    const gpa = testing.allocator;
    var once = try runCli(gpa, &.{ "fmt", "-" }, "plane.a|add 1|write plane.b\n");
    defer once.deinit(gpa);
    try testing.expectEqual(EX_OK, once.code);
    var twice = try runCli(gpa, &.{ "fmt", "-" }, once.out);
    defer twice.deinit(gpa);
    try testing.expectEqualStrings(once.out, twice.out);
    // …and it really did reformat, or this gate is comparing a no-op to
    // itself and would survive anything.
    try testing.expect(!std.mem.eql(u8, "plane.a|add 1|write plane.b\n", once.out));
}

test "F3 G-comments: the prose comes back, blank runs and all" {
    // `matryoshka/kernels/roaches.rill` is four-fifths `//` lines and they
    // are the only documentation of the numbers in it.
    const gpa = testing.allocator;
    const src =
        \\// the room
        \\
        \\// two lines, and the blank above them is part of the shape
        \\plane.a | write plane.b
        \\
    ;
    var r = try runCli(gpa, &.{ "fmt", "-" }, src);
    defer r.deinit(gpa);
    try testing.expectEqual(EX_OK, r.code);
    try testing.expectEqualStrings(src, r.out);
}

test "F4 G-empty: empty in, empty out, exit 0 — and a comment-only file survives" {
    // A program with no statements is a program, and the extension PROBES
    // with one: it sends `// rill vscode probe\n` and formats nothing unless
    // that comment comes back. A binary that fails this half has formatting
    // switched off for the session.
    const gpa = testing.allocator;
    var empty = try runCli(gpa, &.{ "fmt", "-" }, "");
    defer empty.deinit(gpa);
    try testing.expectEqual(EX_OK, empty.code);
    try testing.expectEqualStrings("", empty.out);

    var probe = try runCli(gpa, &.{ "fmt", "-" }, "// rill vscode probe\n");
    defer probe.deinit(gpa);
    try testing.expectEqual(EX_OK, probe.code);
    try testing.expectEqualStrings("// rill vscode probe\n", probe.out);
}

test "F5 G-refuse: a program that does not parse exits 65 with EMPTY stdout" {
    // THE gate that protects his files. The client replaces the WHOLE
    // document with whatever a successful format returns, so a formatter that
    // emits what it managed before it gave up truncates the file it was asked
    // to tidy.
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "fmt", "-" }, "plane.a | | write plane.b\n");
    defer r.deinit(gpa);
    try testing.expectEqual(EX_DATAERR, r.code);
    try testing.expectEqualStrings("", r.out);
    try testing.expect(r.err.len > 0); // it said why, on the right stream
}
// MUTATION: in `doFmt`'s `.refused` arm, write the partial program to stdout
// before returning — `try out.appendSlice(src[0..src.len / 2]);`. Exit stays
// 65, so a gate that only read the exit code would stay green.
// OBSERVED: red on `expectEqualStrings("", r.out)`.

test "F6 G-usage: an unknown subcommand and an unknown flag exit 64, not 65" {
    // 64 and 65 mean opposite things to the editor. 64 says "this binary does
    // not have the feature" — it says so once and goes quiet. 65 says "your
    // file is wrong". Collapse them and a half-typed buffer turns formatting
    // off for the session.
    const gpa = testing.allocator;
    var sub = try runCli(gpa, &.{ "lint", "-" }, canon);
    defer sub.deinit(gpa);
    try testing.expectEqual(EX_USAGE, sub.code);
    try testing.expectEqualStrings("", sub.out);

    var flag = try runCli(gpa, &.{ "fmt", "--tabs", "-" }, canon);
    defer flag.deinit(gpa);
    try testing.expectEqual(EX_USAGE, flag.code);

    var none = try runCli(gpa, &.{}, "");
    defer none.deinit(gpa);
    try testing.expectEqual(EX_USAGE, none.code);

    // `check` without `--json` is a command line with no reply shape.
    var bare = try runCli(gpa, &.{ "check", "-" }, canon);
    defer bare.deinit(gpa);
    try testing.expectEqual(EX_USAGE, bare.code);
}
// MUTATION: in `parseArgs`, return `.{ .fmt = opts }` for an unknown
// subcommand instead of `error.Usage`. `rill lint -` then formats, exits 0,
// and the editor believes a feature it does not have.
// OBSERVED: red, code 0 where 64 was expected.

test "F7 G-json: check emits one parseable object, positions as Diag has them" {
    const gpa = testing.allocator;
    var ok = try runCli(gpa, &.{ "check", "--json", "-" }, canon);
    defer ok.deinit(gpa);
    try testing.expectEqual(EX_OK, ok.code);
    try testing.expectEqualStrings("{\"ok\":true,\"diagnostics\":[]}\n", ok.out);

    // The refusal is on line 3, column 20: `fooo` after the second pipe.
    const bad =
        \\// a comment
        \\
        \\plane.a | add 1 | fooo | write plane.b
        \\
    ;
    var r = try runCli(gpa, &.{ "check", "--json", "-" }, bad);
    defer r.deinit(gpa);
    try testing.expectEqual(EX_DATAERR, r.code);

    // Parsed as JSON rather than string-matched: the claim is that a program
    // can read it, and only a parser can say that.
    var tree = try std.json.parseFromSlice(std.json.Value, gpa, r.out, .{});
    defer tree.deinit();
    const root = tree.value.object;
    try testing.expectEqual(false, root.get("ok").?.bool);
    const list = root.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 1), list.items.len);
    const d = list.items[0].object;
    try testing.expectEqual(@as(i64, 3), d.get("line").?.integer);
    try testing.expectEqual(@as(i64, 19), d.get("col").?.integer);
    try testing.expectEqualStrings("error", d.get("severity").?.string);
    try testing.expectEqualStrings("unknown operator or name 'fooo'", d.get("message").?.string);
}
// MUTATION: in `doCheck`, print `d.line + 1` — the 0-based reading. Every
// squiggle lands one line below the fault, which is the classic off-by-one
// nobody notices until the file is long.
// OBSERVED: red, line 4 where 3 was expected.

test "F8 G-code: an unknown word codes unknown_operator; a syntax error codes parse" {
    // The mapping the whole feature hangs on. rill core does not know
    // `spawn`; the client downgrades `unknown_operator` to a warning so a
    // kernel does not come back red. Read off `Diag.code` — never off the
    // message text, which is the derivation that breaks the first time
    // someone improves a sentence.
    const gpa = testing.allocator;

    var unknown = try runCli(gpa, &.{ "check", "--json", "-" }, "plane.a | fooo | write plane.b\n");
    defer unknown.deinit(gpa);
    try testing.expectEqual(EX_DATAERR, unknown.code);
    try testing.expect(std.mem.indexOf(u8, unknown.out, "\"code\":\"unknown_operator\"") != null);

    // A syntax error: two pipes in a row is not a name at all, so `find` is
    // never asked and the code must NOT be unknown_operator.
    var syntax = try runCli(gpa, &.{ "check", "--json", "-" }, "plane.a | | write plane.b\n");
    defer syntax.deinit(gpa);
    try testing.expectEqual(EX_DATAERR, syntax.code);
    try testing.expect(std.mem.indexOf(u8, syntax.out, "\"code\":\"parse\"") != null);

    // …and a word rill core knows and is refusing ON PURPOSE is a `parse`,
    // not an unknown name. `set` became `write`; the door that says so is
    // one line above the coded refusal and must not have taken its code.
    var renamed = try runCli(gpa, &.{ "check", "--json", "-" }, "plane.a | set plane.b\n");
    defer renamed.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, renamed.out, "\"code\":\"parse\"") != null);
}
// MUTATION: in `parser.zig`, change the coded refusal back to
// `self.fail(op_tok, "unknown operator or name '{s}'", .{op_name})`. Every
// diagnostic codes `parse`, the client stops distinguishing a host's word
// from a mistake, and the honest default becomes diagnostics OFF.
// OBSERVED: red on the first `unknown_operator` assertion.

test "F9 G-hostrow: --host-row changes the answer, and the kernel formats" {
    // The flag's whole job, measured both ways on ONE file: without it the
    // row words are unknown names; with it the file is clean. A gate that
    // only checked the `with` half would pass against a binary that ignored
    // the flag and knew `near` all along.
    const gpa = testing.allocator;

    var without = try runCli(gpa, &.{ "check", "--json", "-" }, kernel_canon);
    defer without.deinit(gpa);
    try testing.expectEqual(EX_DATAERR, without.code);
    try testing.expect(std.mem.indexOf(u8, without.out, "\"code\":\"unknown_operator\"") != null);
    try testing.expect(std.mem.indexOf(u8, without.out, "'near'") != null);

    var with = try runCli(gpa, &.{ "check", "--json", "--host-row", "-" }, kernel_canon);
    defer with.deinit(gpa);
    try testing.expectEqual(EX_OK, with.code);
    try testing.expectEqualStrings("{\"ok\":true,\"diagnostics\":[]}\n", with.out);

    // And `fmt` takes it too, or the 21 kernels in the corpus cannot be
    // formatted at all — which is where the feature is most wanted.
    var f = try runCli(gpa, &.{ "fmt", "--host-row", "-" }, kernel_canon);
    defer f.deinit(gpa);
    try testing.expectEqual(EX_OK, f.code);
    try testing.expectEqualStrings(kernel_canon, f.out);
}
// MUTATION: in `makeRegistry`, drop the `if (opts.host_row)` guard so the
// stubs are ALWAYS registered. The `without` half goes green-into-red: the
// file parses with no flag, the flag stops meaning anything, and rill core
// has quietly grown fifteen host words.
// OBSERVED: red, exit 0 where 65 was expected.

test "F10 G-further: a broken kernel reports the kernel's fault, not the row word" {
    // `parseEither` tries the world parse first, so a kernel fails it at line
    // 2 — a line that is CORRECT. Reporting that would point the squiggle at
    // good code and tell the author their kernel is not a kernel.
    const gpa = testing.allocator;
    const broken =
        \\// a kernel with a real mistake, four lines below a row word
        \\near 0.5 as crowd
        \\crowd | write row.u3
        \\crowd | fooo 1
        \\
    ;
    var r = try runCli(gpa, &.{ "check", "--json", "--host-row", "-" }, broken);
    defer r.deinit(gpa);
    try testing.expectEqual(EX_DATAERR, r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "'fooo'") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "\"line\":4") != null);
}
// MUTATION: `fn further(a, b) { return a; }` — always the world parse. The
// diagnostic becomes "'near' is a row word…" on line 2, and the author is
// sent to fix a line that is right.
// OBSERVED: red, line 2 and no 'fooo'.

test "F11 G-escape: a message with a quote in it stays parseable JSON" {
    // A reply the client cannot `JSON.parse` reads as "the checker crashed",
    // which leaves stale squiggles on screen rather than clearing them — so
    // an escaping bug is not a cosmetic bug, it is a wrong answer.
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "check", "--json", "-" }, "plane.a | write \"unterminated\n");
    defer r.deinit(gpa);
    try testing.expectEqual(EX_DATAERR, r.code);
    var tree = try std.json.parseFromSlice(std.json.Value, gpa, r.out, .{});
    defer tree.deinit();
    try testing.expectEqual(false, tree.value.object.get("ok").?.bool);

    // And the escaper itself, on the characters a diagnostic can actually
    // carry: `set` became `write` quotes the old spelling with backticks, and
    // a shape literal can hold a `"`.
    var buf = std.ArrayList(u8).init(gpa);
    defer buf.deinit();
    try writeJsonString(buf.writer(), "a \"b\" \\ c\n");
    try testing.expectEqualStrings("\"a \\\"b\\\" \\\\ c\\n\"", buf.items);
}
// MUTATION: in `writeJsonString`, drop the `'"' => …` arm so a quote is
// emitted raw. The second half goes red immediately; the first half is what
// the client would actually hit.

// ===========================================================================
// F12..F18 — `ops`, the third subcommand (2026-09-09).
//
// The customer for `OpDef.tags` on the day it landed. Same trap as above and
// it is worth restating: a mutation the code routes around has tested
// nothing, so the ORDER gates read the emitted bytes rather than the sorted
// list, the AND gate uses two tags whose union differs from their
// intersection, and the home gate uses an operator whose home is NOT its
// alphabetically-first tag.
// ===========================================================================

/// `rill ops --tag record`, byte for byte. Three operators whose names sort
/// differently from their declaration order (`record`, `project`, `merge` in
/// the table; `merge`, `project`, `record` here), so the sort is doing visible
/// work and a golden that dropped it would not match. None of the three
/// carries a second tag, so there is no `also:` line — which is itself the
/// claim that the line is omitted when there is nothing to say.
///
/// A small tag on purpose: the name column is padded per HEADING, so these
/// bytes do not move when a host registers something long, and the fixture
/// does not have to be re-typed every time a help line is improved elsewhere.
const ops_record =
    \\record (3) — named fields: build one, read one, merge two
    \\  merge    Merge two records; b's fields win.
    \\  project  Field access on a record stream (`stats.mana`).
    \\  record   Record construction { field: stream, … } — a live tuple with named fields.
    \\
;

test "F12 G-ops-tag: one tag, byte for byte, sorted and padded" {
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "ops", "--tag", "record" }, "");
    defer r.deinit(gpa);
    try testing.expectEqual(EX_OK, r.code);
    try testing.expectEqualStrings(ops_record, r.out);
    try testing.expectEqualStrings("", r.err);

    // …and the `--tag=name` spelling reaches the same bytes, because a reader
    // who types it should not get "unknown flag or operand".
    var eq = try runCli(gpa, &.{ "ops", "--tag=record" }, "");
    defer eq.deinit(gpa);
    try testing.expectEqual(EX_OK, eq.code);
    try testing.expectEqualStrings(ops_record, eq.out);
}
// MUTATION: in `doOps`, delete the `std.mem.sort(…, opBefore)` before the
// text render. The listing then comes out in REGISTRATION order — inside
// `record` that is `record`, `project`, `merge` — so a diff of two runs is
// only stable while nobody touches the table, which is exactly the promise
// this output makes.
// OBSERVED: red, `record` first where `merge` was expected.

test "F13 G-ops-order: headings sorted, operators sorted under them, over the WHOLE listing" {
    // F12 is one tag and could be satisfied by a sort that only ever sees one
    // heading. This reads the emitted bytes of the full listing and checks the
    // order claim end to end. Read off the OUTPUT, never off the list the
    // renderer sorted, or the gate is checking the sort against itself.
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "ops", "--host-row" }, "");
    defer r.deinit(gpa);
    try testing.expectEqual(EX_OK, r.code);

    var groups: usize = 0;
    var ops: usize = 0;
    var last_group: []const u8 = "";
    var last_op: []const u8 = "";
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "  ")) {
            const rest = std.mem.trimLeft(u8, line, " ");
            // The continuation line, not an operator.
            if (std.mem.startsWith(u8, rest, "also:")) continue;
            // `  <name><padding>  <help>` — the name ends at the first run of
            // two spaces, which is why the padding is at least that wide.
            const end = std.mem.indexOf(u8, rest, "  ") orelse rest.len;
            const name = rest[0..end];
            if (last_op.len > 0 and !std.mem.lessThan(u8, last_op, name)) {
                std.debug.print("out of order under '{s}': '{s}' then '{s}'\n", .{ last_group, last_op, name });
                return error.TestUnexpectedResult;
            }
            last_op = name;
            ops += 1;
        } else {
            const end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const name = line[0..end];
            if (last_group.len > 0 and !std.mem.lessThan(u8, last_group, name)) {
                std.debug.print("headings out of order: '{s}' then '{s}'\n", .{ last_group, name });
                return error.TestUnexpectedResult;
            }
            last_group = name;
            last_op = ""; // a new heading restarts the name order
            groups += 1;
        }
    }
    // The counts, so a renderer that emitted nothing could not pass the two
    // order checks vacuously. 13 core homes + `rbf` + `untagged` (the fifteen
    // row stubs `--host-row` brings, which declare no tags and have no first
    // word — the fallback, visible). `constant`, `gate`, `oscillator` and
    // `random` are cross-cuts and nobody's home, so they are NOT headings.
    try testing.expectEqual(@as(usize, 15), groups);
    try testing.expectEqual(@as(usize, 109 + 2 + 15), ops);
    try testing.expect(std.mem.indexOf(u8, r.out, "\nuntagged (15) — nobody said") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "\ngate (") == null);
}
// MUTATION: `opBefore` compares names only, ignoring the home — the headings
// then interleave and every one is wrong. A cheaper one: `return
// std.mem.lessThan(u8, b.name, a.name)` for descending names.
// OBSERVED: red on the heading-order check.

test "F14 G-ops-home: the FIRST tag is the home, and it is declaration order" {
    // The rule a palette's default view rests on, measured on the operator
    // that would move if the resolution sorted: `noise` declares `source`
    // then `random`, and `random` sorts FIRST. A `std.mem.sort` over the tag
    // list — the obvious tidying edit — would file the noise source under
    // `random`, where nobody looking for one would think to look.
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "ops", "--name", "noise" }, "");
    defer r.deinit(gpa);
    try testing.expectEqual(EX_OK, r.code);
    try testing.expect(std.mem.startsWith(u8, r.out, "source (1) —"));
    // …and it is still FOUND by the tag it is not at home under, which is the
    // filter model's whole point.
    var byrandom = try runCli(gpa, &.{ "ops", "--tag", "random" }, "");
    defer byrandom.deinit(gpa);
    try testing.expectEqual(EX_OK, byrandom.code);
    try testing.expect(std.mem.indexOf(u8, byrandom.out, "\n  noise ") != null);
    try testing.expect(std.mem.indexOf(u8, byrandom.out, "\n  shuffle ") != null);
    // …filed under two DIFFERENT headings in that one listing, because a tag
    // cuts across homes and the listing still groups by home.
    try testing.expect(std.mem.startsWith(u8, byrandom.out, "array (1) —"));
    try testing.expect(std.mem.indexOf(u8, byrandom.out, "\nsource (2) —") != null);
}
// MUTATION: in `register`, `std.mem.sort([]const u8, buf, {}, lessThan)` over
// the resolved tag list — the tidying edit that looks harmless. `noise` moves
// home from `source` to `random`, and every two-word host op loses its verb
// as a home the moment it declares one descriptive tag that sorts earlier.
// OBSERVED: red, output starts `random (1)` where `source (1)` was expected.

test "F15 G-ops-and: two tags INTERSECT, they do not union" {
    // `--tag time --tag gate` means "the rate gates", not "everything
    // temporal plus everything that can swallow a value". The fixture is
    // chosen so the two answers differ loudly: `time` carries 19 words and
    // `gate` 9, their union is 23 and their intersection 5.
    const gpa = testing.allocator;
    var both = try runCli(gpa, &.{ "ops", "--tag", "time", "--tag", "gate" }, "");
    defer both.deinit(gpa);
    try testing.expectEqual(EX_OK, both.code);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, both.out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "  ") and std.mem.indexOf(u8, line, "also:") == null) n += 1;
    }
    try testing.expectEqual(@as(usize, 5), n);
    // In it: carries both. Out of it: carries exactly one of the two, from
    // each side — so a union would drag them in and this would catch it
    // whichever way round the bug went.
    try testing.expect(std.mem.indexOf(u8, both.out, "\n  sample ") != null); // time + gate
    try testing.expect(std.mem.indexOf(u8, both.out, "\n  window ") == null); // time only
    try testing.expect(std.mem.indexOf(u8, both.out, "\n  where ") == null); // gate only
}
// MUTATION: in `OpsOpts.wants`, `if (def.tagged(t)) return true;` … `return
// self.n_tags == 0;` — a union. The listing goes to 23 words and every
// two-tag query stops narrowing anything.
// OBSERVED: red, 23 where 5 was expected.

test "F16 G-ops-stdin: `ops` reads no program — garbage on stdin changes nothing" {
    // Its input is the registry, not a file. `main` puts `.ops` in the same
    // arm as `help` and `version` so it never blocks on a terminal; `execute`
    // is handed whatever `main` read, and must ignore it. Both halves matter
    // and only this one is reachable from a unit test — the other is one arm
    // of `main`'s switch, gated as X6 in `editors/vscode/test/e2e.test.mjs`,
    // the only harness in the repo that runs the binary as a PROCESS and so
    // the only place a blocking read can be observed.
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "ops", "--tag", "record" }, "plane.a | | not a program\n");
    defer r.deinit(gpa);
    try testing.expectEqual(EX_OK, r.code);
    try testing.expectEqualStrings(ops_record, r.out);
}
// MUTATION: give `.ops` `doFmt`'s treatment in `execute` — parse `src` first
// and return EX_DATAERR when it refuses. `rill ops` then reports the
// vocabulary as a syntax error in whatever happened to be on stdin.
// OBSERVED: red, code 65 where 0 was expected.

test "F17 G-ops-unknown: an unknown tag is refused BY NAME; a query that matches nothing is not" {
    // The two must be told apart, and under a FILTER model that matters more
    // than it did under a tree: an empty page cannot say "no such tag" apart
    // from "nothing carries all of these", and only one of those is the
    // reader's mistake.
    const gpa = testing.allocator;

    // A typo: 64, named, with the list.
    var bad = try runCli(gpa, &.{ "ops", "--tag", "maths" }, "");
    defer bad.deinit(gpa);
    try testing.expectEqual(EX_USAGE, bad.code);
    try testing.expectEqualStrings("", bad.out); // no half-page
    try testing.expect(std.mem.indexOf(u8, bad.err, "'maths'") != null);
    try testing.expect(std.mem.indexOf(u8, bad.err, "math") != null); // the list
    try testing.expect(std.mem.indexOf(u8, bad.err, "oscillator") != null);
    // The list is the tags, once each — not one entry per operator.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bad.err, " math"));
    // …and a mis-typed tag is caught even when a GOOD one is beside it, or a
    // reader narrowing a working query would get a silent empty page.
    var mixed = try runCli(gpa, &.{ "ops", "--tag", "math", "--tag", "maths" }, "");
    defer mixed.deinit(gpa);
    try testing.expectEqual(EX_USAGE, mixed.code);

    // Two real tags that nothing carries together: exit 0 — the command line
    // was understood and the honest answer is "none" — but SAID, on stderr,
    // never as a silent empty stdout that a caller is piping.
    var none = try runCli(gpa, &.{ "ops", "--tag", "math", "--tag", "space" }, "");
    defer none.deinit(gpa);
    try testing.expectEqual(EX_OK, none.code);
    try testing.expectEqualStrings("", none.out);
    try testing.expect(std.mem.indexOf(u8, none.err, "nothing matches") != null);
    try testing.expect(std.mem.indexOf(u8, none.err, "--tag math --tag space") != null);
}
// MUTATION: in `doOps`, drop the known-tag loop and let the filter answer an
// empty page. `--tag maths` exits 0 saying nothing, and a palette asking for
// a tag it mis-spelled draws an empty tray and reports that the language has
// no such words.
// OBSERVED: red, code 0 where 64 was expected and empty stderr.

test "F18 G-ops-json: one parseable object, headings with their sentence, ops with their tags and ports" {
    // `--json` is what a palette and the vocabulary document read, so the
    // claim is that a PROGRAM can read it — which only a parser can say.
    const gpa = testing.allocator;
    var r = try runCli(gpa, &.{ "ops", "--tag", "record", "--json" }, "");
    defer r.deinit(gpa);
    try testing.expectEqual(EX_OK, r.code);

    var tree = try std.json.parseFromSlice(std.json.Value, gpa, r.out, .{});
    defer tree.deinit();
    const root = tree.value.object;

    // The tag dictionary rides whole, even when the LISTING is filtered: a
    // palette builds its filter bar from this and would otherwise only ever
    // learn about the tags it had already asked for.
    const dict = root.get("tags").?.array;
    try testing.expect(dict.items.len >= 17);
    var found_gate = false;
    for (dict.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "gate")) {
            found_gate = true;
            try testing.expectEqualStrings("may swallow an arrival: the wave can die here", t.object.get("doc").?.string);
        }
    }
    try testing.expect(found_gate);

    const groups = root.get("groups").?.array;
    try testing.expectEqual(@as(usize, 1), groups.items.len);
    const g = groups.items[0].object;
    try testing.expectEqualStrings("record", g.get("name").?.string);
    try testing.expectEqualStrings("named fields: build one, read one, merge two", g.get("doc").?.string);

    const list = g.get("ops").?.array;
    try testing.expectEqual(@as(usize, 3), list.items.len);
    const merge = list.items[0].object;
    try testing.expectEqualStrings("merge", merge.get("name").?.string);
    try testing.expectEqualStrings("record", merge.get("home").?.string);
    try testing.expectEqualStrings("pure", merge.get("class").?.string);
    try testing.expectEqualStrings("anywhere", merge.get("routes").?.string);
    // Ports, by NAME AND TYPE — a palette draws a box from these, and a
    // listing that carried only the help line would make it guess.
    const ins = merge.get("inputs").?.array;
    try testing.expectEqual(@as(usize, 2), ins.items.len);
    try testing.expectEqualStrings("a", ins.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("record", ins.items[0].object.get("type").?.string);
    try testing.expectEqualStrings("value", ins.items[0].object.get("kind").?.string);

    // …and a statics-carrying op keeps them, on a word whose whole grammar is
    // statics. `project`'s `field` is what `stats.mana` compiles to. Its
    // `row` column rides BESIDE its tags and is not folded into them — an
    // enforced property must never become a label.
    const project = list.items[1].object;
    const st = project.get("statics").?.array;
    try testing.expectEqual(@as(usize, 1), st.items.len);
    try testing.expectEqualStrings("field", st.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("word", st.items[0].object.get("kind").?.string);
    try testing.expectEqual(true, project.get("row").?.object.get("legal").?.bool);
    try testing.expectEqual(@as(usize, 1), project.get("tags").?.array.items.len);

    // A multi-tagged op carries ALL of them, in resolution order.
    var multi = try runCli(gpa, &.{ "ops", "--name", "lfo", "--json" }, "");
    defer multi.deinit(gpa);
    var mt = try std.json.parseFromSlice(std.json.Value, gpa, multi.out, .{});
    defer mt.deinit();
    const lfo = mt.value.object.get("groups").?.array.items[0].object.get("ops").?.array.items[0].object;
    const lt = lfo.get("tags").?.array;
    try testing.expectEqual(@as(usize, 3), lt.items.len);
    try testing.expectEqualStrings("source", lt.items[0].string);
    try testing.expectEqualStrings("oscillator", lt.items[1].string);
    try testing.expectEqualStrings("time", lt.items[2].string);

    // …and the WHOLE listing parses, host words included. This half is not
    // decoration: `record`'s three help lines carry no `"`, so a filtered
    // gate is satisfied by an emitter that never escapes anything. `above`
    // and `below` quote their own idiom (`"above 0.3, until below 0.2"`),
    // `transpose` carries braces and arrows, and every one of the 126 rides
    // through here. Found by running the escaping mutation and watching it
    // SURVIVE the filtered half.
    var all = try runCli(gpa, &.{ "ops", "--host-row", "--json" }, "");
    defer all.deinit(gpa);
    try testing.expectEqual(EX_OK, all.code);
    var whole = try std.json.parseFromSlice(std.json.Value, gpa, all.out, .{});
    defer whole.deinit();
    var n: usize = 0;
    for (whole.value.object.get("groups").?.array.items) |g2| {
        n += g2.object.get("ops").?.array.items.len;
    }
    try testing.expectEqual(@as(usize, 109 + 2 + 15), n);
}
// MUTATION: in `doOps`'s JSON arm, write `def.help` through
// `w.print(",\"help\":\"{s}\"", …)` instead of `writeJsonString`. Every help
// line carrying a `"` breaks the object, and a palette reading it decides the
// binary crashed.
// OBSERVED: SURVIVED the `--tag record` half — those three helps have no
// quote in them — and red on the whole-listing half, which is why that half
// is there. `parseFromSlice` fails with `SyntaxError`.

test "F19 G-ops-usage: the exit codes are `fmt`'s and `check`'s, and 64 is the only refusal `ops` can make" {
    // `ops` never parses a program, so 65 is unreachable from it; every way
    // of getting it wrong is the COMMAND LINE, which is 64 — the same code
    // the editor reads as "this binary does not have the feature".
    const gpa = testing.allocator;

    var ok = try runCli(gpa, &.{"ops"}, "");
    defer ok.deinit(gpa);
    try testing.expectEqual(EX_OK, ok.code);
    try testing.expect(ok.out.len > 0);

    // `--tag` and `--name` with nothing after them. The classic: they must not
    // swallow the end of argv and quietly list everything.
    for ([_][]const u8{ "--tag", "--name" }) |flag| {
        var bare = try runCli(gpa, &.{ "ops", flag }, "");
        defer bare.deinit(gpa);
        try testing.expectEqual(EX_USAGE, bare.code);
        try testing.expectEqualStrings("", bare.out);
    }

    var empty_eq = try runCli(gpa, &.{ "ops", "--tag=" }, "");
    defer empty_eq.deinit(gpa);
    try testing.expectEqual(EX_USAGE, empty_eq.code);

    // A flag that belongs to another subcommand.
    var wrong = try runCli(gpa, &.{ "ops", "--tabs" }, "");
    defer wrong.deinit(gpa);
    try testing.expectEqual(EX_USAGE, wrong.code);

    // `-` is the right instinct after `fmt -` and `check -`, and it is
    // refused by NAME rather than as an unknown operand.
    var dash = try runCli(gpa, &.{ "ops", "-" }, "");
    defer dash.deinit(gpa);
    try testing.expectEqual(EX_USAGE, dash.code);
    try testing.expect(std.mem.indexOf(u8, dash.err, "reads no program") != null);

    // …and `--tag` is `ops`'s alone: on `fmt` it stays an unknown flag rather
    // than being quietly accepted and ignored.
    var on_fmt = try runCli(gpa, &.{ "fmt", "--tag", "math", "-" }, canon);
    defer on_fmt.deinit(gpa);
    try testing.expectEqual(EX_USAGE, on_fmt.code);
}
// MUTATION: in `parseArgs`'s `ops` arm, drop the `i == argv.len` check's
// `return` so a missing name silently means "every tag".
// OBSERVED: red, code 0 where 64 was expected.
