# The RBF words

Two words, in a pack a host opts into (`rill.registerRbf`, beside
`rill.registerCore` — see [namespaces.md](namespaces.md) for why a family
registers apart and wears its family's name).

An **RBF set** is a packed sum of anisotropic Gaussians. Each kernel has a
centre μ in D dimensions, a shape — the lower-triangular factor L of its
precision, so its iso-surfaces are ellipsoids — and M weights. Reading the set
at a query point q sums every kernel:

    y[c] = Σ  w[c] · exp(−½ |Lᵀ(q − μ)|²)

That is all it is, and the important thing about it is what it is *not* about.
loam fits such a set by gradient descent to a baked volume and reads it at a
POSITION to get a marble's material. spindrift's `fire.rill` reads the same
evaluator at a particle's STATE — cooled, sooted, thinned — and gets an
appearance out of it. Nothing in the arithmetic noticed the difference. The
general shape is **State → Field → Properties**, and a thing that interpolates
M properties over a D-dimensional state is an interpolation primitive, which
is why the model lives in rill core next to `along`'s Catmull-Rom and
`noise`'s hash rather than in the repo that thought of it.

**A set is one value at one path.** Not a subtree of kernels: a plane read of
an interior path is `NotFound` in every plane this house has (matryoshka's
`readDynamic` is an exact key lookup; rill's own `MockPlane` is the same), so
kernels stored at their own paths would never compose back into a set. The
wire form is a record:

    {d: <axes>, m: <channels>, k: [<number> …]}

with `k` holding the kernels end to end — `μ[d]`, then `L[d(d+1)/2]`, then
`w[m]` — and every number visible on the wire as a number, readable by
anything that reads struple including the Python port. It is flat and one
container deep because that was measured: a nested record-of-arrays costs 2×
to decode, since every container level is escaped on the wire and reading it
un-escapes the whole body into a fresh allocation.

## Authoring

```rill
rbf bump at [0, 0, 0] width 0.30 value [1.00, 0.85, 0.35]
    | rbf bump at [1, 0, 0] width 0.45 value [0.20, 0.20, 0.22]
    | rbf bump at [1, 1, 1] width 0.60 value [0.05, 0.05, 0.06]
    | write plane.fire.coat
```

Three kernels of a flame's appearance manifold, placed by hand down the page.
The pipe carries the set from one bump to the next, which is what a pipe is
for; the first bump has nothing piped into it, so its own arguments fix the
set's shape and every later one must agree with it.

Hand-authoring is a real use — spindrift's fire manifold was ten kernels
placed by eye, no descent — but it is not the only one. A set fitted by
`loam-run --rbf` arrives on a plane path as the same record and reads the
same way.

## Reading

```rill
[plane.ember.cooled, plane.ember.sooted, plane.ember.thinned]
    | rbf through plane.fire.coat as look
look | nth 0 | write plane.look.r
look | nth 1 | write plane.look.g
look | nth 2 | write plane.look.b
```

Both words are **plane-side**: neither has a row column, so neither can be
said inside a kernel. The state above is a manifold coordinate that reached
the plane from somewhere — a spray's dump, a sensor, another program — and the
row-legality question has its own row in the table at the bottom, with what
would have to change and why nothing has asked yet.

The query is an **array**, one number per axis, and never a record. A record's
fields arrive in their keys' sort order, which is alphabetical and not the
manifold's axis order, so `{cooled, sooted, thinned}` and `{a, b, c}` would
read at different points of the same set while both looking right. `distance`
and `within` take `record{x, y, z}` because a position *has* named axes; a
manifold coordinate does not.

The answer is one array of the set's channels, picked apart with `nth`. Not
nine named outputs: naming them would put loam's (blend, albedo, roughness,
metallic, emissive) schema inside rill, where it means nothing, and would make
the word useless for the four-channel set somebody authors next week.

**And the kernels are numbers on a plane, so they are knobs.**

```rill
rbf bump at [0, 0, 0] width plane.knob.hot value [1.0, plane.knob.green, 0.35]
    | write plane.fire.coat
```

Feed `plane.knob.hot` a new number and the manifold changes shape while the
program runs. No remount, no reparse, no recompile.

## The words

| word | reads | writes | what |
|---|---|---|---|
| `rbf bump` | `set` (optional, piped), `at`, `width`, `value` | a set | `[<set>] \| rbf bump at <centre> width <w> value <channels>` — one more Gaussian on the set flowing through, or a new set when nothing is piped in. Read-aloud: "rbf bump at the origin, width a third, value white-hot". A compactly-supported Gaussian is called a bump function, so the word names the thing rather than describing it. `at` is an array of D numbers; `value` an array of M. `width` is σ, the same width `loam.rbf.Kernel.isotropic` takes, so a kernel authored here and one fitted there mean the same thing by the same number — one number is a sphere, an array of D an axis-aligned ellipsoid. A width that is zero, negative or not finite refuses by name: L is 1/σ, so a zero width is an infinite precision and every read after it is NaN, and a clamp there would leave a kernel that looks like a kernel and reads like a needle. A bump whose shape disagrees with the set it is joining refuses with both shapes, because `k` would still divide evenly by the first shape's stride and nothing downstream could ever notice. |
| `rbf through` | `q` (piped), `set` | an array of M numbers | `<q> \| rbf through <set>` — the query point through the field. Read-aloud: "the row's state, rbf through the flame's coat"; a set is what you pass a point THROUGH, which is the same arrow as State → Field → Properties, and not a function you call or a table you index. A query whose length disagrees with the set's axes refuses with both counts — padding it with a zero would read somewhere real and wrong. A set that will not decode refuses by name and says which part of it: reading zeros off a mistyped path looks exactly like reading a set whose kernels are all far away, and the two must never be confusable. |

**Composition is the pipe, because rill has no `concat`.** An array of kernels
could be built but never assembled from separately-computed parts: rill's
array set has no append, and a variadic operator cannot be called by name
(`array` and `record` reach theirs through `[…]` and `{…}` syntax only). The
fold-as-a-pipeline needs neither, and it reads better than either would. The
cost, stated: each bump re-encodes the whole set, so authoring N kernels is
O(N²) bytes. For the ten a hand places that is nothing; nobody hand-places
256, they fit them and load the set through a path.

Rejected at read-aloud. For the read: `rbf read` (vague, and "read" is what a
plane does); `rbf sample` (`sample` is rill's own temporal operator — a near
name for a different thing is worse than a far one); `rbf eval` (a
programmer's word, not a sentence); `rbf of` ("rbf of the coat" names the set,
not the query, so the sentence points the wrong way); bare `through` (a good
general English word, and spending it on one family is exactly the concern the
pack exists to answer). For the author: `kernel` — spindrift's word for a
whole rill program mounted on a row, and a collision of the worst kind;
`gauss`/`gaussian` (names the mathematics, not the operation, and a set is a
sum of them); `place` (says where, not what); `blob`, which says nothing.

## Not built, with triggers

| what | trigger |
|---|---|
| A **gradient** — `rbf through … grad`, the derivative of the field at q | a customer that steers by it. loam does not need one (a hit reads a material, not a slope) and the appearance manifold does not either. |
| A **rotated kernel** authored by hand — the off-diagonal terms of L | a customer who wants one. Descent is what produces rotated ellipsoids, and a fitted set arrives with its L already in it; `rbf bump`'s axis-aligned `width` covers everything a hand has asked for. Then `bump` grows a `toward`, or the L arrives whole. |
| The **fit** — Adam descent against a sampled target | nothing. It is a host command and it already exists as one (`loam-run --rbf`): 2000 iterations over a pool of 32768 points is not a dataflow operator, and putting it behind a word would make a rill statement that takes a minute. |
| **File load and save** | nothing. A plane path is the rill-shaped way to hand a program an asset; a word that opens a file would be rill's first, and the reason it has none is not an oversight. |
| **Row-legality** — `rbf through` inside a kernel, per row | a customer whose ROW needs the field, rather than whose renderer does. Two things are in the way and both are real: a row number is Q16.16, whose resolution is 1.5e-5, while the cutoff is exp(−16) ≈ 1.1e-7 — a fixed-point Gaussian's support goes compactly zero at r2 ≈ 22 where loam's goes at 32, so the two would disagree in the tail *by construction* and the exactness bit could not be earned. And spindrift already has the shape for a row that needs a field: the spray bakes it onto a Q16.16 lattice and `hear` samples that with integer arithmetic. The motivating case does not want it — the row produces the coordinate and the renderer consumes it. |
| **`concat` / `push` on arrays** | an operator that needs to assemble an array from parts. It is a *core* gap, not an RBF one — `rbf bump` routed around it with a pipeline and the next word may not be able to. Recorded here because this is where it was noticed. |
