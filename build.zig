const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const struple_dep = b.dependency("struple", .{ .target = target, .optimize = optimize });
    const struple_mod = struple_dep.module("struple");

    // The public library module — depend on this as `rill`.
    const rill_mod = b.addModule("rill", .{
        .root_source_file = b.path("src/rill.zig"),
        .target = target,
        .optimize = optimize,
    });
    rill_mod.addImport("struple", struple_mod);
    // The manuals ride into the test build as anonymous imports so the
    // manual-parse gate can @embedFile them from outside src/ — a program
    // the repo ships as its front door needs a gate, and the manuals are
    // the front door.
    rill_mod.addAnonymousImport("rill-manual.md", .{ .root_source_file = b.path("docs/rill-manual.md") });
    rill_mod.addAnonymousImport("rill-for-agents.md", .{ .root_source_file = b.path("docs/rill-for-agents.md") });
    // The idioms book rides in the same way and for the same reason. It is the
    // tier-2 campaign's evidence — one before/after pair per ask on the
    // simple-things list — and evidence that never runs is prose.
    rill_mod.addAnonymousImport("idioms.rillbook", .{ .root_source_file = b.path("docs/idioms.rillbook") });

    // Static library artifact (handy for C / FFI / WASM consumers later).
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "rill",
        .root_module = rill_mod,
    });
    b.installArtifact(lib);

    // ── the seam ────────────────────────────────────────────────────────────
    // rill behind a C ABI as a SHARED library, so a consumer can rebuild this
    // alone and keep running its existing binary. Measured on Matryoshka: a
    // one-line edit costs 406 s in ReleaseFast because a Zig source module is
    // recompiled into every consumer; only a shared library is a real
    // compilation boundary (a separate `addImport` module is not, and a static
    // library still forces the consumer to re-optimise in full).
    //
    // `zig build seam` rebuilds ONLY this. Retail builds keep importing rill
    // as a Zig module for full inlining — one source tree, two link shapes.
    const seam_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    seam_mod.addImport("struple", struple_mod);
    const seam = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "rill_seam",
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .root_module = seam_mod,
    });
    const seam_install = b.addInstallArtifact(seam, .{});
    b.step("seam", "Rebuild ONLY the C-ABI shared seam").dependOn(&seam_install.step);

    // A consumer that links the seam and never imports rill as a Zig module —
    // the proof that the boundary is real. `zig build seam-demo` builds it;
    // after that, `zig build seam` alone is enough to change its behaviour.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("tools/seam_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const demo = b.addExecutable(.{ .name = "seam-demo", .root_module = demo_mod });
    demo.linkLibrary(seam);
    demo.linkLibC();
    const demo_install = b.addInstallArtifact(demo, .{});
    const demo_step = b.step("seam-demo", "Build the seam consumer");
    demo_step.dependOn(&demo_install.step);
    // The consumer runs against the INSTALLED library, so installing the exe
    // must install the seam beside it — otherwise the demo links a fresh
    // library and loads a stale one, which is a confusing way to learn how
    // dynamic linking works.
    demo_step.dependOn(&seam_install.step);

    // Demo executable: parses a small program, mounts it on the mock plane,
    // feeds a scripted delta sequence, and prints the slot table each tick.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("rill", rill_mod);
    exe_mod.addImport("struple", struple_mod);
    const exe = b.addExecutable(.{ .name = "rill-demo", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    // rill-run: mount ANY .rill file on the mock plane and drive it from the
    // command line. The demo above is one hardcoded program; this is the one
    // you reach for when iterating on a spelling or watching a register settle.
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    runner_mod.addImport("rill", rill_mod);
    runner_mod.addImport("struple", struple_mod);
    const runner = b.addExecutable(.{ .name = "rill-run", .root_module = runner_mod });
    b.installArtifact(runner);

    const runner_cmd = b.addRunArtifact(runner);
    runner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| runner_cmd.addArgs(args);
    const runner_step = b.step("run-file", "Run a .rill file: zig build run-file -- <file> [opts]");
    runner_step.dependOn(&runner_cmd.step);

    // Tests: src/rill.zig pulls in the acceptance-gate suite from src/tests.zig.
    const tests = b.addTest(.{ .root_module = rill_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    // …and the demo's own module, whose program source is a STRING: building
    // the executable never parses it, so only running the demo used to catch a
    // program that had stopped being valid. `zig build test` parses it now.
    const demo_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(demo_tests).step);
}
