//! registry — the one registration path for operators.
//!
//! Built-in, host-injected, and def-minted operators are indistinguishable
//! once registered: same `OpDef`, same graph box, same `help`, same
//! tab-complete source. The host seeds this table at startup (in Matryoshka,
//! from the console `Cmd` inventory); rill's core set registers through the
//! exact same call.
//!
//! `OpDef.eval` is a plain function pointer over `EvalCtx` — no closures, no
//! per-op vtables. An operator decides whether the wave continues downstream
//! by which output bits it sets in the returned `Emit` mask; mask 0 lets the
//! wave die at this node (`where` eating a value is exactly that).

const std = @import("std");
const struple = @import("struple");
const types = @import("types.zig");
const plane = @import("plane.zig");

pub const TypeId = types.TypeId;

/// The one type bit that matters (§4.2): `value` streams compare-and-suppress
/// (same bytes = silence), `occurrence` streams always propagate when emitted.
pub const PortKind = enum(u1) { value, occurrence };

pub const Port = struct {
    name: []const u8,
    ty: TypeId = types.Tag.any,
    kind: PortKind = .value,
    optional: bool = false,
    /// §3.11: the parser captures the rest of the line verbatim as a string
    /// literal bound here. Last input port only — `register` enforces the
    /// closed shape. A locator is freeform text, not structure.
    tail: bool = false,
    /// The tail captures the rest of the INPUT, not the line — newlines,
    /// comments and all, verbatim to EOF (2026-08-25; rillbook's first
    /// drive found `rill remount`'s multi-line contract had never crossed
    /// the console: the line-tail stopped at the first newline and a
    /// comment-led source left it empty). Only meaningful with `tail`;
    /// `register` enforces the pairing. A tail_all statement is necessarily
    /// the program's last.
    tail_all: bool = false,
    /// Non-empty on a string port: the closed value set a bound literal must
    /// belong to, checked at parse ("wire time"). This is the console's enum
    /// argument made enforceable — the same list the browser tab-completes
    /// from. Streams bound to the port are not (cannot be) checked at parse.
    one_of: []const []const u8 = &.{},
    /// Keyword-introduced (`cast … at s.gate.pos decay 2s`): in source text the
    /// port is bound by writing its name before the value, never positionally.
    /// The word is what disambiguates — `cast $alarm 30` cannot say whether 30
    /// is the payload or the radius, and a grammar that guesses is worse than
    /// one that asks. The colon-kwarg spelling (`at: …`) still works too.
    kw: bool = false,
};

/// Static (non-stream) parameters an operator consumes at parse time:
/// `set plane.x` takes a `path` target, `tap hp` a `word` label, `const 5`
/// a `literal`. Statics are configuration, not subscriptions — a `path`
/// static is a write target, never an upstream edge.
///
/// `channel` is a field-channel name wearing its `$` sigil (`cast $alarm …`).
/// It is deliberately NOT a `path`: a path static lands in the program's
/// write list and the cycle check reads that list, but a field has no read
/// side inside rill (readings come from a standpoint — a sensor), so a cast
/// can never close a loop the checker would need to see.
/// `subject` and `condition` are the membership pair (`tag @tom #garrison`,
/// ironwood R6 T3), each wearing its sigil. Neither is a `path`, but for the
/// OPPOSITE reason to `channel`: a membership write DOES have a read side —
/// the member key `plane.tags.<tag>.<@subject>` — so the pair composes into
/// exactly one write-list entry (`Program.registerWrites`), which is how the
/// cycle check sees a set-subscription collide while `joined`/`count`
/// subscriptions stay legitimate siblings (member keys wear `@`, service
/// leaves are bare words — disjoint by construction).
/// `shape` is a struple-encoded SHAPE LITERAL (`{id: string, distance: number}`),
/// built by the parser and stored whole: `{exact: bool, shape: <s>}`, where a
/// shape is a type-word string (`number`/`boolean`/`string`/`any`), a
/// one-element array `[<s>]` for an array-of, or a map whose keys are field
/// names — an optional field's key wears the `?` it was written with. Encoded
/// at parse so the check never re-parses text, and a struple so the shape is
/// inspectable through the same protocol as every other value.
pub const StaticKind = enum { path, word, literal, channel, subject, condition, shape };

pub const StaticDecl = struct {
    name: []const u8,
    kind: StaticKind,
    /// Keyword-introduced in source text (`radius 12`), same rule as Port.kw.
    kw: bool = false,
    /// Unbound is legal: the static fills with its kind's EMPTY value
    /// (`""`), which every consumer must treat as "absent". First customer:
    /// `cast … [to #tag]` — an uncoupled cast is the common case, and a
    /// grammar that demanded `to` on every cast would make the coupling
    /// mandatory to say nothing.
    optional: bool = false,
};

pub const StaticVal = union(StaticKind) {
    path: []const u8,
    word: []const u8,
    literal: []const u8, // struple-encoded element
    channel: []const u8, // `$`-sigil field-channel name, sigil included
    subject: []const u8, // `@`-sigil entity name, sigil included
    condition: []const u8, // `#`-sigil tag name, sigil included
    shape: []const u8, // struple-encoded shape literal (see StaticKind)
};

/// Which outputs emitted this tick. Bit i = output port i.
pub const Emit = packed struct {
    mask: u32 = 0,

    pub const none = Emit{ .mask = 0 };
    pub const first = Emit{ .mask = 1 };

    pub fn bit(i: u5) Emit {
        return .{ .mask = @as(u32, 1) << i };
    }

    pub fn with(self: Emit, i: u5) Emit {
        return .{ .mask = self.mask | (@as(u32, 1) << i) };
    }

    pub fn has(self: Emit, i: u5) bool {
        return (self.mask >> i) & 1 == 1;
    }
};

pub const EvalError = error{ BadValue, PlaneWrite } || std.mem.Allocator.Error;

/// Why an operator refused, in words, for the failure the op is about to
/// return. `@errorName` says `BadValue`, which names the category and not the
/// fact — and the fact is the whole point of "mismatches name both sides".
///
/// Fixed buffer, no allocator: this is the error path, and an error path that
/// can itself fail is a second failure mode. A message that would overflow is
/// truncated rather than lost. The runtime clears it before every eval and
/// carries whatever the op wrote into the `ErrorEvent`, so an op that says
/// nothing costs nothing and reads exactly as it did before.
pub const Detail = struct {
    buf: [320]u8 = undefined,
    len: usize = 0,

    pub fn clear(self: *Detail) void {
        self.len = 0;
    }

    pub fn text(self: *const Detail) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Detail, comptime fmt: []const u8, args: anytype) void {
        const w = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            // Truncation is the honest failure here: half a message that
            // names the op beats no message at all.
            break :blk self.buf[0..self.buf.len];
        };
        self.len = w.len;
    }
};

/// An absolute point on one of the two fed-time lanes (never a relative
/// offset — absolute is the honest form: it serializes, and a program
/// restored mid-window stays exactly as far from its deadline as it was).
pub const Deadline = union(enum) {
    ns: u64, // fed real time, nanoseconds
    frame: u64, // fed frame index
};

/// What an operator sees when it evaluates. Input values are struple-encoded
/// element streams borrowed from the slot arena (valid only for the call);
/// outputs are written through per-port packers backed by the tick arena.
pub const EvalCtx = struct {
    /// Per-tick scratch arena. Anything allocated here dies at end of tick.
    arena: std.mem.Allocator,
    /// Current value per input port; null = no value has ever arrived.
    in: []const ?[]const u8,
    /// Which inputs are fresh this tick — a value input that actually changed,
    /// or an occurrence input that fired. Gates key off this.
    in_fresh: []const bool,
    /// One packer per output port. Set the matching Emit bit for what you wrote.
    out: []struple.Packer,
    /// Resolved static arguments, in declaration order.
    statics: []const StaticVal,
    /// Persistent per-node state (struple bytes), survives across ticks and is
    /// part of the program dump. Threshold/edge operators keep their previous
    /// side here.
    state: *std.ArrayListUnmanaged(u8),
    state_gpa: std.mem.Allocator,
    /// Effect channel: queue a plane write, flushed in order at end of tick.
    write_fn: *const fn (ctx: *anyopaque, path: []const u8, val: []const u8, kind: plane.DeltaKind) EvalError!void,
    write_ctx: *anyopaque,
    /// Field-cast channel (`cast`): a deposit into the caster's owned space,
    /// dispatched AT EVAL — not queued to the flush — so a host refusal
    /// (unknown channel, bad position) lands on the node that cast it,
    /// counted and §6-reported. (This used to say "flushed with the tick's
    /// other effects"; that stopped being true when the flush was found to
    /// lose the node association, turning one refused cast into a failed
    /// mount.) Null when the host has no field store — same loud path.
    cast_fn: ?*const fn (ctx: *anyopaque, c: plane.Cast) EvalError!void = null,
    cast_ctx: ?*anyopaque = null,
    /// Membership channel (`tag`/`untag`): dispatched AT EVAL like a cast,
    /// and for the same reason — the host's stale-binding refusal (the
    /// subject's mount-bound id has died, or its name was re-registered)
    /// must land on the node that wrote, counted and §6-reported, ending
    /// that program's authority over the subject loudly rather than in a
    /// failed flush. Null when the host keeps no tag row — same loud path.
    tag_fn: ?*const fn (ctx: *anyopaque, t: plane.TagWrite) EvalError!void = null,
    tag_ctx: ?*anyopaque = null,
    /// The operator being evaluated. Carried so that a refusal can name
    /// ITSELF and its ports without every helper threading a string: the
    /// refusals gate found 21 of 54 refusal paths said nothing at all, and
    /// they all ran through the same four accessors. Registration completes
    /// before mount, so this pointer into the registry is stable.
    op: *const OpDef,
    /// Where an operator writes WHY it is about to refuse (see `Detail`).
    /// Cleared by the runtime before every eval, so an op never inherits a
    /// neighbour's excuse.
    detail: *Detail,
    /// Debug/log bus for `tap`; null when the host wired none.
    log_fn: ?*const fn (ctx: ?*anyopaque, label: []const u8, val: []const u8) void = null,
    log_ctx: ?*anyopaque = null,
    /// Opaque host world, passed at mount (`MountOpts.host_ctx`) and live
    /// from tick 0. Host-seeded operators downcast this to reach what the
    /// write/log channels can't express — the engine plane, correlation ids,
    /// a reply slot. Core operators never touch it.
    host: ?*anyopaque = null,
    /// Ambient fed time — what the host passed to `tick(now)`. Read, never
    /// subscribed: nothing in the graph depends on time as a stream, so a
    /// quiet program stays quiet while the clock runs. Temporal operators
    /// consume these and the wheel; everything else ignores them.
    now_ns: u64 = 0,
    now_frame: u64 = 0,
    /// Timer wheel arm: ask the runtime to re-evaluate this node once fed
    /// time reaches `deadline` (a deadline at or before the current tick
    /// fires on the *next* tick — arming never re-enters the sweep). Null
    /// when the host mounted no wheel; `wake` then fails loud.
    wake_fn: ?*const fn (ctx: *anyopaque, deadline: Deadline) EvalError!void = null,
    wake_ctx: ?*anyopaque = null,
    /// Drives this node's section body — see `call`. Null on every node that
    /// declares no body.
    call_fn: ?*const fn (ctx: *anyopaque, args: []const []const u8, out: *struple.Packer) EvalError!bool = null,
    call_ctx: ?*anyopaque = null,

    pub fn write(self: *EvalCtx, path: []const u8, val: []const u8) EvalError!void {
        return self.write_fn(self.write_ctx, path, val, .value);
    }

    /// Add `val` to whatever is at `path` — a blind delta: no read, so no
    /// subscription, so nothing for the cycle check (§4.4) to refuse. Being
    /// commutative it is also MORE deterministic than read-modify-write,
    /// because arrival order stops mattering.
    pub fn writeDelta(self: *EvalCtx, path: []const u8, val: []const u8) EvalError!void {
        return self.write_fn(self.write_ctx, path, val, .accumulate);
    }

    pub fn log(self: *EvalCtx, label: []const u8, val: []const u8) void {
        if (self.log_fn) |f| f(self.log_ctx, label, val);
    }

    pub fn cast(self: *EvalCtx, c: plane.Cast) EvalError!void {
        const f = self.cast_fn orelse return error.PlaneWrite;
        return f(self.cast_ctx.?, c);
    }

    pub fn tagWrite(self: *EvalCtx, t: plane.TagWrite) EvalError!void {
        const f = self.tag_fn orelse return error.PlaneWrite;
        return f(self.tag_ctx.?, t);
    }

    /// Refuse, in words. `return ctx.refuse("…", .{…})` is the whole idiom:
    /// it records the reason and hands back the error in one move, so a
    /// refusal cannot record a reason and then forget to fail.
    /// The declared name of input port `i`, for messages. Falls back to the
    /// index when a variadic op has no declared ports.
    pub fn portName(self: *const EvalCtx, i: usize) []const u8 {
        if (i < self.op.inputs.len) return self.op.inputs[i].name;
        return "?";
    }

    pub fn refuse(self: *EvalCtx, comptime fmt: []const u8, args: anytype) EvalError {
        self.detail.set(fmt, args);
        return error.BadValue;
    }

    pub fn setState(self: *EvalCtx, bytes: []const u8) !void {
        self.state.clearRetainingCapacity();
        try self.state.appendSlice(self.state_gpa, bytes);
    }

    /// The current time on `deadline`'s lane — the comparison temporal
    /// operators make against their stored absolute deadlines.
    pub fn nowOn(self: *const EvalCtx, frames: bool) u64 {
        return if (frames) self.now_frame else self.now_ns;
    }

    pub fn wake(self: *EvalCtx, deadline: Deadline) EvalError!void {
        const f = self.wake_fn orelse return error.BadValue;
        return f(self.wake_ctx.?, deadline);
    }

    /// Run this operator's section body once, with `args` filling its open
    /// ports in order, and append its output to `out`. Returns false when the
    /// body emitted nothing (a body may eat a value, same as any operator).
    ///
    /// The body is a node the sweep skips; this is the only thing that drives
    /// it, and it is driven N times per tick where N is however many elements
    /// the consumer has. Bodies close over nothing and hold no state that
    /// survives the call, so "N times in a fixed order" is the whole contract.
    pub fn call(self: *EvalCtx, args: []const []const u8, out: *struple.Packer) EvalError!bool {
        const f = self.call_fn orelse return self.refuse("{s}: no section body is attached", .{self.op.name});
        return f(self.call_ctx.?, args, out);
    }
};

/// What an operator's evaluation touches. Three states, because two conflated
/// two independent facts: "may the evaluator cache this" and "does this write
/// the plane". A host op that *reads* the world (a pose, a histogram, a report)
/// is neither — not cacheable, not a writer — and calling it `pure` licenses a
/// future cache pass to be wrong. `reads` is that third honest answer.
///
/// **The operative definition of `reads` is "not a writer, not skippable."**
/// `reads` names the motivating case, but the audit of 2026-08-24 found the
/// class is bigger than host-world-readers, and for one shared reason: an op
/// is unskippable whenever its output depends on anything besides the input
/// VALUES in front of it. In the core set that is three shapes —
///
///   - **arrival-dependent** (`where`, `partition`, `changed`, `latch`): the
///     op asks `in_fresh`, so identical bytes mean emit-or-be-silent depending
///     on which port arrived. A byte-keyed cache would replay an emission that
///     should have been silence.
///   - **stateful** (the threshold/edge adapters, the gates): the answer is a
///     function of history, which no cache key can see.
///   - **fed time** (`sample`, `debounce`, `throttle`, `cooldown`, `window`,
///     `delay`): ambient, and by §4.6's ruling never an input.
///
/// — plus `tap`, whose whole purpose is the side effect, and which was the
/// `pure` that gave the audit away. If a rename ever feels right, the contract
/// above is the thing to preserve; the word is the negotiable part.
pub const OpClass = enum {
    pure, // output depends only on the input VALUES; evaluator may cache/skip
    reads, // not a writer, not skippable: host world, own state, or fed time
    effect, // writes the world through the plane (set/notify/inc)

    /// Writers register their `path` statics in the program's write list, which
    /// is what the cycle check reads. The two call sites (parser bind, dump
    /// restore) ask this question, never `== .pure`, so a `reads` op that ever
    /// grows a path static still can't slip out of the check silently.
    pub fn writes(self: OpClass) bool {
        return self == .effect;
    }
};

/// Where an op's evaluation may run, DECLARED at registration — no default,
/// so every op answers at birth (ruled 2026-08-25, the fourth time a
/// predicate over this registry turned out to be a coverage surface: when it
/// is one, the registry carries the answer and the predicate is derived).
/// `.main` = the eval crosses into host state that lives on the host's
/// serial thread (cast reads the channel rows; tag/untag read the entity
/// registry and the tag row) — a host dispatching off-thread must route the
/// whole program there. `.anywhere` = pure dataflow, or effects that reach
/// the host through its own safe channel (`set` lands in a main-drained
/// inbox).
pub const Routing = enum { anywhere, main };

/// May this operator re-arm itself and evaluate again without any input
/// changing? Declared at registration, `false` by default and audited
/// exhaustively (the `class` pattern, not the `routes` one — this is a
/// display fact, not a safety fact: getting it wrong shows a wrong badge,
/// not a wrong answer).
///
/// The flag says **may tick**, never **is ticking**. A register only ticks
/// while it is converging and stops at its cutoff; `clock` ticks as long as
/// time is fed. So the flag alone would over-report, and it is deliberately
/// only half the answer: the host lights the ticks-every-frame badge from
/// this flag (a program contains a ticking node, or a node downstream of
/// one — §8 of the tier-2 draft), and shows the node's LIVE eval counter
/// beside it as the proof. The static flag says what could cost; the
/// counter says what did. Ruled 2026-08-25.
/// The badge is a per-program question — "does this cell cost every frame?"
/// — and parse order is topological, so *contains* a ticking node already
/// covers *downstream of* one: whatever the ticker emits re-evaluates the
/// rest. The host derives it with the same one-line loop it uses for
/// routing (Matryoshka's `routesToMain`), which is why there is a field
/// here and no predicate.

pub const OpDef = struct {
    name: []const u8,
    inputs: []const Port = &.{},
    outputs: []const Port = &.{},
    statics: []const StaticDecl = &.{},
    help: []const u8,
    class: OpClass = .pure,
    routes: Routing,
    /// May re-arm itself and evaluate with no input change — see `ticks`
    /// above. Default false; the audit in tests.zig is exhaustive both ways.
    ticks: bool = false,
    /// A refusal from this operator **during mount's tick 0 fails the mount**
    /// rather than merely killing its wave. One customer, and it is the whole
    /// reason the field exists: `expect` promises to assert AT MOUNT and never
    /// to degrade into a runtime check (`rill-tier2-draft.md` §2.13), and an
    /// assertion that only logs is not an assertion. Structural rather than
    /// disciplinary — the registry carries the answer and `evalNode` derives
    /// the behaviour, so an op cannot acquire mount-fatality by being special-
    /// cased somewhere in the runtime. Default false; audited exhaustively.
    ///
    /// It says *fails the mount*, not *fails the tick*: after mount, this
    /// operator's refusals are ordinary refusals like everyone else's.
    fails_mount: bool = false,
    /// **Consumer-declared section arity** (tier 2 beat 3, ruled 2026-08-25).
    /// Non-zero means this operator takes a section body — `map (clamp 0 1)`,
    /// `reduce (add)` — with exactly this many open ports, and the operator
    /// drives it per element through `EvalCtx.call` rather than the sweep
    /// evaluating it. `map` declares 1, `reduce` declares 2.
    ///
    /// The consumer declares the arity because the consumer is what knows it:
    /// a section is an operator with ports left open, and only the thing about
    /// to fill them knows how many it will supply. A mismatch is refused by
    /// name, with both counts.
    ///
    /// Zero is the tier-1 predicate section (`where (> 0)`), which is a
    /// different mechanism entirely: it mirrors the consumer's own STREAM into
    /// the section's open port at parse time and the sweep evaluates it once
    /// per tick like any other node. Both spellings are `( )`; what decides is
    /// the consumer's declaration, never a lookahead.
    body: u8 = 0,
    /// Variadic operators (record construction) take their port list from the
    /// call site; `inputs` is ignored and one `word` static names each field.
    variadic: bool = false,
    eval: *const fn (ctx: *EvalCtx) EvalError!Emit,
};

pub const OpId = u32;

pub const RegistryError = error{ DuplicateOp, BadTailPort, BadEnumPort, BadStatic, ReservedName } || std.mem.Allocator.Error;

/// Words the *syntax* claims, which therefore may not name an operator or an
/// `as`/`use` binding. The list lives here because the registry owns the
/// operator namespace, and the only useful thing to say about a reserved word
/// is that the namespace may not contain it: the parser recognises these
/// before it ever asks `find`, so a host row named `also` or `as` would
/// register cleanly and then be permanently unreachable. Registration is the
/// last moment that can be said out loud.
pub fn isReservedWord(s: []const u8) bool {
    const words = [_][]const u8{ "plane", "use", "def", "as", "also", "true", "false" };
    for (words) |w| {
        if (std.mem.eql(u8, s, w)) return true;
    }
    return false;
}

/// The operator table. Owns nothing but its own arrays: `OpDef` port/static
/// slices are borrowed from the registrant (comptime tables for built-ins;
/// the host keeps its own alive).
pub const Registry = struct {
    gpa: std.mem.Allocator,
    types: types.TypeTable,
    ops: std.ArrayListUnmanaged(OpDef) = .empty,
    by_name: std.StringHashMapUnmanaged(OpId) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Registry {
        return .{ .gpa = gpa, .types = try types.TypeTable.init(gpa) };
    }

    pub fn deinit(self: *Registry) void {
        self.ops.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.types.deinit();
    }

    pub fn register(self: *Registry, def: OpDef) RegistryError!OpId {
        if (self.by_name.contains(def.name)) return error.DuplicateOp;
        // A two-word host op (`boolean subtract`) is reserved only if a whole
        // word of it is — the parser's two-word lookup never sees the halves.
        var words = std.mem.splitScalar(u8, def.name, ' ');
        while (words.next()) |w| {
            if (isReservedWord(w)) return error.ReservedName;
        }
        // The four sigils name rows of the store (`@` instance, `^` archetype,
        // `#` condition, `$` field), never operators. Refused at registration
        // for the same reason reserved words are: a `$`-led op would be
        // permanently shadowed by the channel grammar.
        if (def.name.len > 0 and std.mem.indexOfScalar(u8, "@^#$", def.name[0]) != null) {
            return error.ReservedName;
        }
        // Tails are a closed grammar (§3.11): last input only, string-typed,
        // never variadic — and every port before the tail is required, because
        // "fixed prefix, then rest of line" has no room for maybe-there args.
        if (def.inputs.len > 0) {
            const last = def.inputs[def.inputs.len - 1];
            if (last.tail and (last.ty != types.Tag.string or def.variadic)) return error.BadTailPort;
            if (last.tail_all and !last.tail) return error.BadTailPort;
            for (def.inputs[0 .. def.inputs.len - 1]) |p| {
                if (p.tail or p.tail_all) return error.BadTailPort;
                if (last.tail and p.optional) return error.BadTailPort;
            }
        }
        // `one_of` is a string-port contract — a value set on any other type
        // could never be satisfied by a literal and would gate nothing.
        for (def.inputs) |p| {
            if (p.one_of.len > 0 and p.ty != types.Tag.string) return error.BadEnumPort;
        }
        // An optional static must be keyword-introduced: a positional
        // maybe-there argument binds greedily, and every static after it
        // would shift by whether it was said.
        for (def.statics) |sd| {
            if (sd.optional and !sd.kw) return error.BadStatic;
        }
        const id: OpId = @intCast(self.ops.items.len);
        try self.ops.append(self.gpa, def);
        errdefer _ = self.ops.pop();
        try self.by_name.put(self.gpa, def.name, id);
        return id;
    }

    pub fn find(self: *const Registry, op_name: []const u8) ?OpId {
        return self.by_name.get(op_name);
    }

    pub fn get(self: *const Registry, id: OpId) *const OpDef {
        return &self.ops.items[id];
    }
};

test "registry: tail ports keep their closed shape — last only, string, required prefix" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const noopEval = struct {
        fn f(_: *EvalCtx) EvalError!Emit {
            return Emit.none;
        }
    }.f;
    const str = types.Tag.string;
    const good = [_]Port{ .{ .name = "gain", .ty = types.Tag.number }, .{ .name = "locator", .ty = str, .tail = true } };
    _ = try reg.register(.{ .name = "ok", .inputs = &good, .help = "", .routes = .anywhere, .eval = noopEval });

    const not_last = [_]Port{ .{ .name = "locator", .ty = str, .tail = true }, .{ .name = "gain", .ty = types.Tag.number } };
    try std.testing.expectError(error.BadTailPort, reg.register(.{ .name = "a", .inputs = &not_last, .help = "", .routes = .anywhere, .eval = noopEval }));

    const not_string = [_]Port{.{ .name = "locator", .ty = types.Tag.number, .tail = true }};
    try std.testing.expectError(error.BadTailPort, reg.register(.{ .name = "b", .inputs = &not_string, .help = "", .routes = .anywhere, .eval = noopEval }));

    const optional_prefix = [_]Port{ .{ .name = "gain", .ty = types.Tag.number, .optional = true }, .{ .name = "locator", .ty = str, .tail = true } };
    try std.testing.expectError(error.BadTailPort, reg.register(.{ .name = "c", .inputs = &optional_prefix, .help = "", .routes = .anywhere, .eval = noopEval }));
}

test "registry: register/find, duplicate rejected" {
    var reg = try Registry.init(std.testing.allocator);
    defer reg.deinit();
    const noopEval = struct {
        fn f(_: *EvalCtx) EvalError!Emit {
            return Emit.none;
        }
    }.f;
    const id = try reg.register(.{ .name = "noop", .help = "does nothing", .routes = .anywhere, .eval = noopEval });
    try std.testing.expectEqual(id, reg.find("noop").?);
    try std.testing.expectError(error.DuplicateOp, reg.register(.{ .name = "noop", .help = "", .routes = .anywhere, .eval = noopEval }));
}
