//! host_row — spindrift's fifteen row words, as STUBS, in one place.
//!
//! ## Why they exist at all
//!
//! rill is the library the hosts embed. It is public, it builds standalone,
//! and `tests.zig`'s NORTHSTAR banner refuses to teach it what a kernel is —
//! so rill core does not know `spawn`, `near`, `push` or `deposit`, and it
//! must not. But 21 of the 47 `.rill` programs Christian actually has use
//! those words, and both of rill's own tools have to read them:
//!
//!   - `rill-roundtrip` measures the printer against that corpus.
//!   - `rill check --json --host-row` tells an editor whether a kernel
//!     parses, and `rill fmt --host-row` formats one.
//!
//! `--host-row` on either one registers this list and nothing else changes.
//!
//! ## Why ONE file rather than a copy per tool
//!
//! The SHAPES are load-bearing and the behaviour is not — nothing here is
//! ever evaluated. A stub whose arity or static-kind differs from the host's
//! word parses the same file DIFFERENTLY, so two copies that drift make
//! `check` and `roundtrip` disagree about what is a legal program, and the
//! one that is wrong is whichever was edited second. That failure is silent:
//! both tools stay green, on two different languages. One definition, two
//! importers, and a shape change is one edit.
//!
//! Kept OUT of `src/` on purpose. Exporting a host's private vocabulary from
//! `rill.zig` would make spindrift's word list part of rill's public API and
//! ship a stale copy of it into every consumer — matryoshka would link a
//! `spawn` it already defines. This is tooling vocabulary; it lives with the
//! tools.
//!
//! Refresh it rather than trust it — the list in `CLAUDE.md` went stale once,
//! reading seven while there were fifteen:
//!
//!     grep -n '^        .name = ' ../spindrift/src/words.zig

const rill = @import("rill");

const Tag = rill.Tag;

fn planeRefuse(_: *rill.EvalCtx) rill.registry.EvalError!rill.Emit {
    return error.BadValue;
}
fn rowStub(_: *rill.row.Ctx) rill.row.Error!void {}

fn rowOnly() rill.row.Row {
    return .{ .exact = true, .only = true, .eval = rowStub };
}

/// spindrift's fifteen, by shape — eleven through `words.register` and the
/// tracer four through `words.registerTracer`. Both doors take names out of
/// the one namespace, so all fifteen are spoken for and a stub is needed for
/// each.
pub const stubs = [_]rill.OpDef{
    .{ .name = "spawn", .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "gravity", .inputs = &.{.{ .name = "g", .ty = Tag.number }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "perish", .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "relax", .inputs = &.{
        .{ .name = "in", .ty = Tag.number },
        .{ .name = "target", .ty = Tag.number },
        .{ .name = "rate", .ty = Tag.number },
    }, .outputs = &.{.{ .name = "step", .ty = Tag.number }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "near", .inputs = &.{.{ .name = "radius", .ty = Tag.number }}, .outputs = &.{.{ .name = "count", .ty = Tag.number }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "push", .inputs = &.{.{ .name = "k", .ty = Tag.number }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "align", .inputs = &.{.{ .name = "k", .ty = Tag.number }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "sync", .statics = &.{.{ .name = "field", .kind = .path }}, .inputs = &.{
        .{ .name = "drift", .ty = Tag.number },
        .{ .name = "couple", .ty = Tag.number },
    }, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "infect", .statics = &.{.{ .name = "field", .kind = .path }}, .inputs = &.{.{ .name = "rate", .ty = Tag.number }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "deposit", .statics = &.{.{ .name = "channel", .kind = .channel }}, .inputs = &.{.{ .name = "amount", .ty = Tag.number }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "hear", .statics = &.{
        .{ .name = "channel", .kind = .channel },
        .{ .name = "grad", .kind = .word, .flag = true, .optional = true },
    }, .inputs = &.{.{ .name = "at", .ty = Tag.any, .kw = true }}, .outputs = &.{.{ .name = "out", .ty = Tag.any }}, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    // the tracer four
    .{ .name = "collide", .outputs = &.{
        .{ .name = "at", .ty = Tag.any },
        .{ .name = "normal", .ty = Tag.any },
        .{ .name = "t", .ty = Tag.number },
        .{ .name = "material", .ty = Tag.number },
    }, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "ground", .outputs = &.{
        .{ .name = "distance", .ty = Tag.number },
        .{ .name = "normal", .ty = Tag.any },
    }, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "slide", .publishes = &.{"contact"}, .inputs = &.{ .{ .name = "at", .ty = Tag.any }, .{ .name = "normal", .ty = Tag.any } }, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
    .{ .name = "stick", .publishes = &.{"contact"}, .inputs = &.{ .{ .name = "at", .ty = Tag.any }, .{ .name = "normal", .ty = Tag.any } }, .help = "stub", .routes = .anywhere, .row = rowOnly(), .eval = planeRefuse },
};

/// Register all fifteen. `Registry.register` refuses a duplicate name, so a
/// core word that ever collides with one of these fails LOUDLY here rather
/// than shadowing the host's — which is exactly what happened to `over` on
/// 2026-09-02 and is the behaviour worth keeping.
pub fn register(reg: *rill.Registry) !void {
    for (stubs) |def| _ = try reg.register(def);
}
