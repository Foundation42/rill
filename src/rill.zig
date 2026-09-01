//! rill — a small, live, reactive dataflow evaluator for Substrate-backed
//! applications.
//!
//! A rill program is a flat graph of typed operators connected by streams of
//! struple values. Programs are **mounted, not run** — they sit on the host's
//! data plane, subscribe to paths, and re-evaluate incrementally when inputs
//! change. There is no run button and no execution wires: propagation is the
//! only control flow, and operators are the valves that decide whether a
//! change continues downstream.
//!
//! The library borrows a plane, it does not own one (`Plane` is a fn-pointer
//! interface; Matryoshka hands rill the real data plane, tests hand it
//! `MockPlane`). Everything is a struple: slot values, program serialization,
//! the wire protocol — the program's own state is inspectable through the
//! same protocol as everything else.
//!
//!     var reg = try rill.Registry.init(gpa);
//!     defer reg.deinit();
//!     try rill.registerCore(&reg);
//!     // …host injects its own operators through the same reg.register…
//!
//!     var diag = rill.Diag{};
//!     var prog = try rill.parse(gpa, &reg, "hud",
//!         \\plane.player.health | dropped_below 20 | write plane.audio.heartbeat
//!     , &diag);
//!     defer prog.deinit();
//!
//!     var rt = try rill.Runtime.mount(gpa, &prog, plane);
//!     defer rt.deinit();
//!     // per frame: rt.feed(delta)…; rt.tick(.{ .frame = f, .time_ns = t });
//!
//! A program is a *rill*. You *mount* a rill. Files are `.rill`.

const std = @import("std");

pub const types = @import("types.zig");
pub const registry = @import("registry.zig");
pub const graph = @import("graph.zig");
pub const parser = @import("parser.zig");
pub const ops = @import("ops.zig");
pub const plane = @import("plane.zig");
pub const eval = @import("eval.zig");
pub const serialize = @import("serialize.zig");
pub const row = @import("row.zig");

// The working surface, re-exported flat.
pub const TypeId = types.TypeId;
pub const Tag = types.Tag;
pub const Registry = registry.Registry;
pub const OpDef = registry.OpDef;
pub const Port = registry.Port;
pub const PortKind = registry.PortKind;
pub const Emit = registry.Emit;
pub const EvalCtx = registry.EvalCtx;
pub const registerCore = ops.registerCore;
pub const Program = graph.Program;
pub const parse = parser.parse;
pub const parseKernel = parser.parseKernel;
pub const Diag = parser.Diag;
pub const ParseError = parser.ParseError;
pub const Plane = plane.Plane;
pub const MockPlane = plane.MockPlane;
pub const Delta = plane.Delta;
pub const DeltaKind = plane.DeltaKind;
pub const WriteMode = plane.WriteMode;
pub const Runtime = eval.Runtime;
pub const MountOpts = eval.MountOpts;
pub const Now = eval.Now;
pub const Deadline = registry.Deadline;
pub const dump = serialize.dump;
pub const loadProgram = serialize.loadProgram;
pub const restoreState = serialize.restoreState;

test {
    _ = @import("types.zig"); // type table, accepts, literal classification
    _ = @import("registry.zig"); // one registration path
    _ = @import("graph.zig"); // flat graph, path overlap
    _ = @import("parser.zig"); // text → flat graph
    _ = @import("ops.zig"); // core operator set
    _ = @import("plane.zig"); // borrowed plane + mock
    _ = @import("eval.zig"); // mount / feed / tick
    _ = @import("serialize.zig"); // one-struple dump
    _ = @import("row.zig"); // a rill mounted on a spray: the row plane
    _ = @import("tests.zig"); // acceptance gates G1–G9
}
