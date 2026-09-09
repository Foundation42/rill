//! `rill` — the front door for a TOOL, as `rill-run` is the front door for a
//! person.
//!
//! Two subcommands, and both of them are a thin skin over machinery that
//! already existed: `fmt` is `parse` + `script.print` (the printer landed
//! 2026-09-09), `check` is `parse` and the `Diag` it fills. Nothing here
//! decides anything about the language; what it decides is how a failure
//! reaches a program that is not a person.
//!
//!     rill fmt   [--host-row] [-]      program on stdin  → program on stdout
//!     rill check --json [--host-row] [-]                 → one JSON object
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
    \\  rill help | --help        this
    \\  rill version | --version  the library version
    \\
    \\Flags
    \\  --host-row  Register spindrift's fifteen row words as stubs, so a
    \\              spray kernel parses. rill core does not know `spawn`,
    \\              `near` or `push` and must not: the registry is the
    \\              HOST's. Without this, 21 of the 47 corpus programs
    \\              report unknown operators — all of them correct files.
    \\  -           Read stdin. The only input there is; a file path is
    \\              refused rather than half-supported.
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

pub const Cmd = union(enum) {
    fmt: Opts,
    check: Opts,
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

    const is_fmt = std.mem.eql(u8, sub, "fmt");
    const is_check = std.mem.eql(u8, sub, "check");
    if (!is_fmt and !is_check) {
        why.* = "unknown subcommand — `fmt` and `check` are what there is";
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
            prog.deinit();
            // `prog.warnings` is dropped here, and that is a decision rather
            // than an oversight: a warning has no `code`, and a client that
            // cannot name what it is looking at cannot decide what to do with
            // it — which is the exact argument that put `code` on `Diag`.
            // RECORDED, NOT BUILT. Trigger: a second `warn` site in the
            // parser, or Christian asking for the discards-a-value warning in
            // the editor. Building it means a `code` on `graph.Warning`.
            try w.writeAll("{\"ok\":true,\"diagnostics\":[]}\n");
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
    const src = switch (cmd) {
        .help, .version => "",
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
