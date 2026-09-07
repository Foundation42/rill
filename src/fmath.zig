//! fmath — the transcendentals an EVALUATOR needs, the same bits in every
//! binary. Today that is `exp`, and it has exactly one customer: `rbf.zig`.
//!
//! **This is a transcribed twin of `loam/src/fmath.zig`, deliberately, and it
//! is the second copy of that model in the house** (spindrift's `fields.zig`
//! is the first, and records the same bargain). The reason it exists at all:
//! `@exp` lowers to an LLVM intrinsic that becomes a call to `exp` — glibc's
//! libm when the binary links libc, compiler_rt's musl port when it does not.
//! The two differ by an ulp here and there. loam found that out the hard way
//! (its P2.1: the Python door and the CLI door disagreed on a bud's heading
//! in the last bit after agreeing on every brick) and ported a Sun `e_exp` so
//! its own numbers stop moving between builds.
//!
//! rill inherits the problem the moment it grows an evaluator that has to
//! agree with loam's to the BIT — which `rbf.eval` does, because an RBF set
//! is one model with two implementations (here and `loam/src/rbf.zig`) and a
//! gate written to an epsilon lets them drift in the last places until a host
//! that swaps one for the other quietly renders something else. So: the same
//! Sun `e_exp`, pinned below to the same frozen output bits loam pins, which
//! makes the two copies fail together or not at all with no dependency edge
//! between the repos (there is none in either direction, and adding one to
//! carry a test would invert the layering).
//!
//! **What this is worth, measured, and it is less than it looks.** Swapping
//! `expf` for `@exp` inside `rbf.eval` does NOT fail the frozen table, and
//! that is not a hole in the gate — it is a fact about this model. The
//! gaussian's argument is `−½·r2` with r2 in [0, CUTOFF], so the arguments
//! are exactly the f32s in [−16, 0], and all 1,098,907,649 of them were
//! checked against both exps (2026-09-07, x86-64, glibc 2.42, Zig 0.14.1):
//!
//!     libc linked:      11,626,851 arguments differ in f64 (1.06%), by 1 ulp
//!                       ZERO differ once narrowed to f32
//!     libc absent:      0 differ at all — compiler_rt's musl port already
//!                       agrees with the Sun exp bit for bit
//!
//! So on this platform `@exp` would have produced loam's bits too. This
//! module is INSURANCE, not a fix: "a 1-ulp f64 difference never survives the
//! narrowing" is an empirical fact about two implementations, not a theorem,
//! and rill runs wherever its host runs. The cost of the insurance is a
//! hundred lines with two gates that bite (the frozen bits, and the ulp bound
//! over the gaussian's range). **Trigger to reconsider:** a platform where
//! the f32 counts above are not zero settles it in favour of keeping this
//! permanently; a decision to drop the transcription needs the same
//! exhaustive sweep run on every platform the house ships to, which is a
//! bigger job than keeping it.
//!
//! **Why rill's `exp` WORD does not use this.** `ops.exp` is `@exp`, and it
//! stays `@exp`. Different customer: the word's output is read by a renderer
//! or a person, its numbers already went out to every consumer of this
//! library, and changing them by an ulp to buy a property nobody asked of it
//! is a silent behaviour change dressed as a cleanup. If a bit-identity claim
//! is ever made ABOUT the word — a second implementation of the language, a
//! replay gate over a float program — that is the trigger to move it here,
//! and the move is one line.
//!
//! Pure IEEE arithmetic, strict float mode: no FMA contraction, no fast-math.

const std = @import("std");

// ── exp (Sun e_exp, loam's port) ──────────────────────────────────────────

const toint = 1.5 / std.math.floatEps(f64);
const ln2hi = 6.93147180369123816490e-01;
const ln2lo = 1.90821492927058770002e-10;
const invln2 = 1.44269504088896338700e+00;
const P1 = 1.66666666666666019037e-01;
const P2 = -2.77777777770155933842e-03;
const P3 = 6.61375632143793436117e-05;
const P4 = -1.65339022054652515390e-06;
const P5 = 4.13813679705723846039e-08;

/// x · 2^k by exponent arithmetic, for the k an exp can produce.
fn scale(x: f64, k: i32) f64 {
    if (k > 1023) return scale(x * 0x1p1023, k - 1023);
    if (k < -1022) return scale(x * 0x1p-1022, k + 1022);
    const bits: u64 = @as(u64, @intCast(k + 1023)) << 52;
    return x * @as(f64, @bitCast(bits));
}

pub fn exp(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (x > 709.782712893384) return std.math.inf(f64);
    if (x < -745.1332191019412) return 0;
    if (@abs(x) < 0x1p-28) return 1.0 + x;
    // k = round(x / ln2), hi − lo = x − k·ln2 to extra precision.
    const kf = x * invln2 + toint - toint;
    const k: i32 = @intFromFloat(kf);
    const hi = x - kf * ln2hi;
    const lo = kf * ln2lo;
    const r = hi - lo;
    const t = r * r;
    const c = r - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
    const y = 1.0 - ((lo - (r * c) / (2.0 - c)) - hi);
    return scale(y, k);
}

/// f32 through f64 — loam's `expf`, and the reason `rbf.eval` can claim the
/// same bits as `loam.rbf.Set.eval` rather than the same neighbourhood.
pub fn expf(x: f32) f32 {
    return @floatCast(exp(@as(f64, x)));
}

test "exp: the bits are pinned, and they are LOAM's bits" {
    // Copied verbatim from `loam/src/fmath.zig`'s own frozen-sample test
    // (frozen there 2026-09-06, P2.1). This is the cross-repo pin: neither
    // repo depends on the other, so the only thing that can hold two copies
    // of one routine together is the same table on both sides, failing
    // together. A mutation to any polynomial coefficient bites here.
    try std.testing.expectEqual(@as(u64, 0x3ff4b050163af005), @as(u64, @bitCast(exp(0.257))));
    try std.testing.expectEqual(@as(u64, 0x3fe6ee052939ace6), @as(u64, @bitCast(exp(-0.3333))));
    try std.testing.expectEqual(@as(f64, 1), exp(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.36787945), expf(-1), 1e-7);
}

test "exp: agrees with the builtin to a couple of ulps over the gaussian's range" {
    // Accuracy is musl's; reproducibility is the point. The range checked is
    // the one a kernel actually asks for: `exp(-0.5 · r2)` with r2 in
    // [0, CUTOFF], so the argument runs [-16, 0].
    var worst: f64 = 0;
    var x: f64 = -16;
    while (x <= 0) : (x += 0.0011) {
        const a = exp(x);
        const b = @exp(x);
        if (a != b) worst = @max(worst, @abs(a - b) / (@max(@abs(a), @abs(b)) * std.math.floatEps(f64)));
    }
    try std.testing.expect(worst <= 2.0);
}
