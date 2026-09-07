//! rbf — a packed set of anisotropic Gaussians, as a rill VALUE.
//!
//! The model: a set is N kernels; a kernel is a centre μ in D dimensions, the
//! lower-triangular factor L of its precision (so the Mahalanobis distance is
//! |Lᵀ(q − μ)| and the shape is an ellipsoid, positive-definite by
//! construction) and M weights. A read at a query point q sums every kernel
//! and answers M numbers:
//!
//!     y[c] = Σ_i  w_i[c] · exp(−½ |Lᵀ_i (q − μ_i)|²)
//!
//! **Why this is in rill and not in loam, where it was born.** loam fits such
//! a set by descent to a baked volume and writes it as a `.lrbf` file: a
//! material field for the marble, nine channels of (blend, albedo, roughness,
//! metallic, emissive), queried at a POSITION. Then spindrift's `fire.rill`
//! read the same evaluator at a particle's STATE — cooled, sooted, thinned —
//! and got an appearance out of it. Nothing about the arithmetic noticed. The
//! general shape is `State → Field → Properties`, and a thing that
//! interpolates M properties over a D-dimensional state is not a texture
//! trick, it is an interpolation primitive: the same standing this repo gives
//! `along`'s Catmull-Rom and `noise`'s hash, which are also somebody's
//! specific idea generalised until it stopped being about them.
//!
//! So what lives here is the MODEL and nothing else. Not the nine-channel
//! schema (that is bark's), not `compose`, not `columns`, not the extent or
//! the mirror fold, not the content hash, not the `.lrbf` file, and not the
//! fit — 2000 Adam iterations is a host command, not a dataflow operator.
//! rill takes the sum of Gaussians and the D and M that make it general.
//!
//! **Two copies of one model, deliberately.** `loam/src/rbf.zig` is the
//! other, `matryoshka/shaders/dynamic_trace.glsl` (kind 3) is a third on the
//! GPU. No dependency edge exists between rill and loam in either direction
//! and neither should be created to carry a test, so the two CPU copies are
//! held together by a frozen vector table that lives in both repos' gates
//! (`tests.zig` here, `rbf.zig` there) and by `fmath.exp`, which is loam's
//! Sun `e_exp` transcribed for exactly this reason — though `fmath`'s own
//! header carries the measurement showing that on this platform `@exp` would
//! have done, and that the transcription is insurance rather than a fix. The claim is byte
//! equality in f32, not an epsilon: an epsilon lets two copies drift in the
//! last places until a host that swaps one for the other renders something
//! else, quietly. **Trigger to revisit:** if either side's kernel or cutoff
//! changes, both change in the same beat, or the pin is a gate watching
//! nothing (spindrift's `fields.zig` records the identical bargain).
//!
//! ## The wire form
//!
//! A set is ONE value at ONE path: `{d: <int>, m: <int>, k: [<f32> …]}`,
//! where `k` is the kernels laid end to end, each `μ[d] · L[d(d+1)/2] · w[m]`.
//! Flat, and one container deep, for two reasons that were measured rather
//! than argued (see the ledger): a nested record-of-arrays costs 2× to decode
//! because every container level is escaped on the wire and `containedItems`
//! un-escapes it into a fresh allocation; and the plane cannot help — a read
//! of an interior path is `NotFound`, never a subtree gathered into a record
//! (`matryoshka/src/control/command.zig`'s `readDynamic` is an exact key
//! lookup, and rill's own `MockPlane` is the same). Kernels at their own
//! paths would not compose back into a set, so the set is one value or it is
//! nothing.
//!
//! `d` and `m` ride WITH the kernels rather than being an operator's
//! argument: a set moved from one path to another, or handed between
//! programs, has to keep its own shape. That is what makes it inspectable —
//! every number is a number on the wire, readable by anything that reads
//! struple, including the Python port.

const std = @import("std");
const struple = @import("struple");

/// A kernel is nothing beyond this Mahalanobis distance squared: exp(−16),
/// a tenth of a millionth. loam's `rbf.CUTOFF` and the shader's
/// `LOAM_RBF_CUTOFF` are the same 32, and all three must move together.
pub const CUTOFF: f32 = 32;

/// The query dimension a set may have. The cap is not taste: it is what lets
/// `eval` run with no allocation, on two stack arrays of this size, on
/// whatever thread it was called from. D = 3 is loam's and spindrift's; 8
/// leaves an L of 36 numbers, which is already more shape than anything has
/// asked for.
pub const MAX_D: u8 = 8;
/// The channel count a set may have, capped for the same reason: `through`
/// accumulates into a stack array of this size rather than allocating per
/// tick. loam's schema is 9.
pub const MAX_M: u8 = 32;

/// Numbers per kernel: the centre, the lower-triangular factor, the weights.
pub fn stride(d: usize, m: usize) usize {
    return d + d * (d + 1) / 2 + m;
}

/// The lower-triangular factor packed row by row — L[j][i] for j ≥ i lands
/// at j(j+1)/2 + i. For D = 3 that is loam's (l00, l10, l11, l20, l21, l22),
/// which is what makes the two evaluators the same arithmetic and not merely
/// the same formula.
pub fn lIndex(j: usize, i: usize) usize {
    return j * (j + 1) / 2 + i;
}

/// A decoded set, borrowing its kernels. `k.len` is a whole multiple of
/// `stride(d, m)` — the decoder is what guarantees it, so `eval` has nothing
/// to check.
pub const Set = struct {
    d: u8,
    m: u8,
    k: []const f32,

    pub fn count(self: Set) usize {
        return self.k.len / stride(self.d, self.m);
    }
};

/// The read: every kernel summed at `q`, into `out`.
///
/// Term for term this is `loam.rbf.Set.eval` at D = 3, M = 9 — the same
/// products in the same order, the same accumulation order, the same cutoff,
/// the same `exp`. The one departure is the `continue`: loam computes a
/// gaussian of 0 beyond the cutoff and then still accumulates `w[c] · 0`.
/// Skipping is identical arithmetic ONLY because a non-finite weight cannot
/// get in here — `decode` refuses one by name — so `w · 0` is always a signed
/// zero and adding a signed zero to a sum that started at +0 never changes a
/// bit. Take that refusal out and this loop stops being loam's for a set with
/// an infinity in it.
///
/// Asserts rather than refuses on the shapes: `q.len == d` and `out.len == m`
/// are the caller's business, and every caller in this repo gets them from
/// the same decoded `Set`.
pub fn eval(set: Set, q: []const f32, out: []f32) void {
    std.debug.assert(q.len == set.d);
    std.debug.assert(out.len == set.m);
    const d: usize = set.d;
    const m: usize = set.m;
    const st = stride(d, m);
    @memset(out, 0);
    var base: usize = 0;
    while (base + st <= set.k.len) : (base += st) {
        const mu = set.k[base..][0..d];
        const l = set.k[base + d ..][0 .. d * (d + 1) / 2];
        const w = set.k[base + d + d * (d + 1) / 2 ..][0..m];

        var delta: [MAX_D]f32 = undefined;
        for (0..d) |a| delta[a] = q[a] - mu[a];

        // v = Lᵀ·delta. Row i of Lᵀ is column i of L, so the terms run
        // j = i…D−1 and land in loam's order for D = 3.
        var r2: f32 = 0;
        for (0..d) |i| {
            var v: f32 = 0;
            for (i..d) |j| v += l[lIndex(j, i)] * delta[j];
            r2 += v * v;
        }
        if (r2 > CUTOFF) continue;
        const g = @import("fmath.zig").expf(-0.5 * r2);
        for (0..m) |c| out[c] += w[c] * g;
    }
}

// ── the wire form ─────────────────────────────────────────────────────────

/// Why a decode refused, in enough detail for the caller to name the offender
/// on the node that read it. rbf.zig knows nothing about `EvalCtx`; the
/// operator formats these. Loud, never a guess — an unreadable set is not an
/// empty set, and a program that silently read zeros off a typo would look
/// exactly like one whose kernels are far away.
pub const Fault = union(enum) {
    not_a_record,
    missing_key: []const u8,
    key_not_an_int: []const u8,
    key_out_of_range: struct { key: []const u8, got: i64, max: u8 },
    kernels_not_an_array,
    malformed,
    element_not_a_number: usize,
    element_not_finite: usize,
    ragged: struct { len: usize, stride: usize },
};

pub const DecodeError = error{BadSet} || std.mem.Allocator.Error;

/// Decode a set, appending the kernel numbers to `out`. The set BORROWS
/// `out.items` when this returns, so `out` must outlive the `Set` and must
/// not grow again while it is alive.
///
/// Anything numeric on the wire narrows to f32: ints, f32, f64 and decimals
/// all arrive from rill literals and knobs, and f32 is the model's precision
/// — it is loam's, it is the GPU's, and it is what makes the gate a byte
/// comparison. `encode` always writes f32, so a set that has been through
/// this pair once is canonical and compare-and-suppress works on it.
pub fn decode(
    scratch: std.mem.Allocator,
    encoded: []const u8,
    out: *std.ArrayListUnmanaged(f32),
    fault: *Fault,
) DecodeError!Set {
    var tr = struple.reader(encoded);
    const top = (tr.next() catch null) orelse .nil;
    if (top != .map) {
        fault.* = .not_a_record;
        return error.BadSet;
    }
    const body = (struple.view(encoded).containedItems(scratch) catch null) orelse {
        fault.* = .not_a_record;
        return error.BadSet;
    };
    var mv = struple.MapView.init(body);

    const d = try dimension(scratch, &mv, "d", MAX_D, fault);
    const m = try dimension(scratch, &mv, "m", MAX_M, fault);

    const kv = (try lookup(scratch, &mv, "k")) orelse {
        fault.* = .{ .missing_key = "k" };
        return error.BadSet;
    };
    var kr = struple.reader(kv);
    const kt = kr.next() catch null;
    if (kt == null or kt.? != .array) {
        fault.* = .kernels_not_an_array;
        return error.BadSet;
    }
    const inner = (struple.view(kv).containedItems(scratch) catch null) orelse {
        fault.* = .malformed;
        return error.BadSet;
    };

    out.clearRetainingCapacity();
    var r = struple.reader(inner);
    var i: usize = 0;
    while (true) : (i += 1) {
        const e = (r.next() catch {
            fault.* = .malformed;
            return error.BadSet;
        }) orelse break;
        const x: f32 = switch (e) {
            .float32 => |x| x,
            .float64 => |x| @floatCast(x),
            // int / f32 / f64 and nothing else — the same vocabulary
            // `types.asNumber` accepts, so a value that is a number to the
            // rest of the language is a number here too, and one that is not
            // gets the same answer from both.
            .int => |x| @floatFromInt(x),
            else => {
                fault.* = .{ .element_not_a_number = i };
                return error.BadSet;
            },
        };
        // The refusal that licenses `eval`'s cutoff skip — see its comment.
        // It is also the honest answer on its own terms: a kernel whose
        // weight is an infinity has no value anywhere, and a NaN centre puts
        // every read at NaN with nothing said.
        if (!std.math.isFinite(x)) {
            fault.* = .{ .element_not_finite = i };
            return error.BadSet;
        }
        try out.append(scratch, x);
    }

    const st = stride(d, m);
    if (out.items.len % st != 0) {
        fault.* = .{ .ragged = .{ .len = out.items.len, .stride = st } };
        return error.BadSet;
    }
    return .{ .d = d, .m = m, .k = out.items };
}

/// `MapView.get` matches the ENCODED key element, not the string — a raw
/// `"d"` would never match and every set would look like it was missing every
/// key. Encode first, like `project` does.
fn lookup(scratch: std.mem.Allocator, mv: *struple.MapView, key: []const u8) DecodeError!?[]const u8 {
    var kp = struple.Packer.init(scratch);
    try kp.appendString(key);
    return mv.get(kp.bytes()) catch null;
}

fn dimension(scratch: std.mem.Allocator, mv: *struple.MapView, key: []const u8, max: u8, fault: *Fault) DecodeError!u8 {
    const val = (try lookup(scratch, mv, key)) orelse {
        fault.* = .{ .missing_key = key };
        return error.BadSet;
    };
    var vr = struple.reader(val);
    const e = (vr.next() catch null) orelse {
        fault.* = .{ .key_not_an_int = key };
        return error.BadSet;
    };
    const n: i64 = switch (e) {
        .int => |x| std.math.cast(i64, x) orelse {
            fault.* = .{ .key_out_of_range = .{ .key = key, .got = std.math.maxInt(i64), .max = max } };
            return error.BadSet;
        },
        else => {
            fault.* = .{ .key_not_an_int = key };
            return error.BadSet;
        },
    };
    if (n < 1 or n > max) {
        fault.* = .{ .key_out_of_range = .{ .key = key, .got = n, .max = max } };
        return error.BadSet;
    }
    return @intCast(n);
}

/// Encode a set onto `pk` in the canonical wire form. `scratch` builds the
/// map's parts and may be released as soon as this returns.
pub fn encode(pk: *struple.Packer, scratch: std.mem.Allocator, set: Set) !void {
    var kp = struple.Packer.init(scratch);
    for (set.k) |x| try kp.appendF32(x);
    var karr = struple.Packer.init(scratch);
    try karr.appendArray(kp.bytes());

    var dk = struple.Packer.init(scratch);
    try dk.appendString("d");
    var dv = struple.Packer.init(scratch);
    try dv.appendInt(set.d);
    var mk = struple.Packer.init(scratch);
    try mk.appendString("m");
    var mv = struple.Packer.init(scratch);
    try mv.appendInt(set.m);
    var kk = struple.Packer.init(scratch);
    try kk.appendString("k");

    try pk.appendMap(&.{
        .{ dk.bytes(), dv.bytes() },
        .{ kk.bytes(), karr.bytes() },
        .{ mk.bytes(), mv.bytes() },
    });
}

/// Fill the six (or d(d+1)/2) slots of L for an AXIS-ALIGNED kernel of the
/// given widths: L = diag(1/σ). This is the one thing about an RBF set that
/// ordinary rill arithmetic cannot spell — a width is not a precision, and
/// the reciprocals go into a triangle, not a diagonal — which is why `bump`
/// is a word and everything else about a set is record arithmetic.
///
/// A rotated ellipsoid needs the off-diagonal terms, and nothing has asked
/// for one by hand: descent is what produces those, and a fitted set arrives
/// through `decode` with its L already in it. **Trigger:** a customer who
/// wants to author a rotated kernel; then `bump` grows a `toward` or the L
/// arrives whole.
pub fn axisAligned(l: []f32, widths: []const f32) void {
    const d = widths.len;
    std.debug.assert(l.len == d * (d + 1) / 2);
    @memset(l, 0);
    for (0..d) |i| l[lIndex(i, i)] = 1.0 / widths[i];
}
