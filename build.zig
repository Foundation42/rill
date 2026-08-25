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

    // Static library artifact (handy for C / FFI / WASM consumers later).
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "rill",
        .root_module = rill_mod,
    });
    b.installArtifact(lib);

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
