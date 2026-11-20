//! v0.3 meta tests: spans (M2), the new shrink passes (M3) and the
//! cut scope (M7). Design: docs/design-v0.3.md §1.7, §3.9.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const Span = zigprop.internal.Span;
const GenState = zigprop.internal.GenState;

const Tree = struct { value: i64, kids: []const Tree };
const U = union(enum) { a: u8, b: void, c: []const u8 };

fn typeId(comptime T: type) u64 {
    return std.hash.Fnv1a_64.hash(@typeName(T));
}

fn elem(start: usize, end: usize, length_pos: usize) Span {
    return .{ .start = start, .end = end, .info = .{ .element = .{ .length_pos = length_pos } } };
}

fn occ(comptime T: type, start: usize, end: usize) Span {
    return .{ .start = start, .end = end, .info = .{ .occurrence = .{ .type_id = typeId(T) } } };
}

/// Replays `values` for T and returns the recorded spans (arena-owned)
/// together with the recorded choice count.
fn spansOf(comptime T: type, arena: std.mem.Allocator, values: []const u64, limits: zigprop.Limits) !struct { spans: []const Span, len: usize } {
    const buf = try arena.alloc(Choice, values.len);
    for (values, buf) |v, *c| c.* = .{ .bound = 0, .value = v };
    var src = zigprop.internal.Source.initReplay(arena, buf, 100_000);
    var ctx_state: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena, limits);
    _ = try zigprop.generate(T, &ctx);
    try std.testing.expect(!src.exhausted);
    try std.testing.expectEqual(@as(?anyerror, null), src.sticky_error);
    return .{ .spans = try arena.dupe(Span, src.recorded_spans.items), .len = src.recorded.items.len };
}

fn expectSpans(expected: []const Span, actual: []const Span) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectEqualDeep(e, a);
}

test "spans: slice elements and occurrences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // []const u8 of length 3: one length draw at 0, then one
    // (class, value) pair per element. No container occurrences.
    const s = try spansOf([]const u8, a, &.{ 3, 0, 1, 0, 2, 0, 3 }, .{});
    try std.testing.expectEqual(@as(usize, 7), s.len);
    try expectSpans(&.{ elem(1, 3, 0), elem(3, 5, 0), elem(5, 7, 0) }, s.spans);

    // An empty slice has no element spans.
    const e = try spansOf([]const u8, a, &.{0}, .{});
    try expectSpans(&.{}, e.spans);

    // Tree{3, [Tree{7, []}]}: root pair 0-1, kids length 2, kid pair
    // 3-4, kid's kids length 5. Pre-order by start: the root
    // occurrence, the kid's element span, the kid's occurrence.
    const t = try spansOf(Tree, a, &.{ 0, 6, 1, 0, 14, 0 }, .{});
    try std.testing.expectEqual(@as(usize, 6), t.len);
    try expectSpans(&.{ occ(Tree, 0, 6), elem(3, 6, 2), occ(Tree, 3, 6) }, t.spans);

    // Nesting two levels: Tree{0, [Tree{0, [Tree{0, []}]}, Tree{0, []}]}.
    const n = try spansOf(Tree, a, &.{ 0, 0, 2, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, .{});
    try std.testing.expectEqual(@as(usize, 12), n.len);
    try expectSpans(&.{
        occ(Tree, 0, 12),
        elem(3, 9, 2),
        occ(Tree, 3, 9),
        elem(6, 9, 5),
        occ(Tree, 6, 9),
        elem(9, 12, 2),
        occ(Tree, 9, 12),
    }, n.spans);
}

test "spans: a cut occurrence is still an occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // max_depth = 0: the root's kids are generated, each kid is cut
    // (value draw only, empty kids, no length draw).
    const t = try spansOf(Tree, arena.allocator(), &.{ 0, 6, 1, 0, 14 }, .{ .max_depth = 0 });
    try std.testing.expectEqual(@as(usize, 5), t.len);
    try expectSpans(&.{ occ(Tree, 0, 5), elem(3, 5, 2), occ(Tree, 3, 5) }, t.spans);
}

test "spans: union occurrences cover the tag draw and the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // .a = 5: tag 0, then the u8 pair.
    const ua = try spansOf(U, a, &.{ 0, 0, 5 }, .{});
    try expectSpans(&.{occ(U, 0, 3)}, ua.spans);
    // .b: the tag draw only.
    const ub = try spansOf(U, a, &.{1}, .{});
    try expectSpans(&.{occ(U, 0, 1)}, ub.spans);
    // .c = {9}: tag, length, one element pair.
    const uc = try spansOf(U, a, &.{ 2, 1, 0, 9 }, .{});
    try expectSpans(&.{ occ(U, 0, 4), elem(2, 4, 1) }, uc.spans);
}

test "spans: type ids distinguish container types and are stable per type" {
    const S = struct { x: u8 };
    try std.testing.expect(typeId(Tree) != typeId(U));
    try std.testing.expect(typeId(Tree) != typeId(S));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try spansOf(S, arena.allocator(), &.{ 0, 4 }, .{});
    try expectSpans(&.{occ(S, 0, 2)}, s.spans);
}

test "spans: random generation records well-formed spans" {
    // Every span lies inside the recorded sequence, element spans
    // follow their length draw, and starts are non-decreasing
    // (pre-order).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..50) |seed| {
        var src = zigprop.internal.Source.initRandom(a, zigprop.internal.deriveSeed(seed, 0), 100_000);
        var ctx_state: GenState = undefined;
        var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, a, .{ .max_len = 4, .max_depth = 3 });
        _ = try zigprop.generate(Tree, &ctx);
        var prev_start: usize = 0;
        for (src.recorded_spans.items) |sp| {
            try std.testing.expect(sp.start <= sp.end);
            try std.testing.expect(sp.end <= src.recorded.items.len);
            try std.testing.expect(sp.start >= prev_start);
            prev_start = sp.start;
            switch (sp.info) {
                .element => |el| try std.testing.expect(el.length_pos < sp.start),
                .occurrence => |o| try std.testing.expectEqual(typeId(Tree), o.type_id),
            }
        }
    }
}

// ---------------------------------------------------------------------
// M3: the new shrink passes (design v0.3 §3, §3.9)
// ---------------------------------------------------------------------

const GenContext = zigprop.GenContext;

fn hasSevenTree(t: Tree) bool {
    if (t.value == 7) return true;
    for (t.kids) |k| {
        if (hasSevenTree(k)) return true;
    }
    return false;
}

fn noSevenTree(t: Tree) bool {
    return !hasSevenTree(t);
}

fn noSevenBytes(xs: []const u8) bool {
    for (xs) |x| {
        if (x == 7) return false;
    }
    return true;
}

/// Records every acceptance reported by the internal hook.
const Monitor = struct {
    accepts: usize = 0,
    /// Non-lateral acceptances whose keys were not strictly smaller,
    /// and lateral (P4) ones whose keys changed.
    violations: usize = 0,
    /// P4 lateral moves seen, and those that did not lower the number
    /// of pairs outside class 3 or changed a position outside one pair.
    laterals: usize = 0,
    lateral_count_violations: usize = 0,
    lateral_position_violations: usize = 0,
    by_pass: [@typeInfo(zigprop.internal.ShrinkPass).@"enum".field_names.len]usize = @splat(0),

    fn hook(self: *Monitor) zigprop.internal.AcceptHook {
        return .{ .context = self, .call = call };
    }

    fn call(context: *anyopaque, e: zigprop.internal.AcceptEvent) void {
        const self: *Monitor = @ptrCast(@alignCast(context));
        self.accepts += 1;
        self.by_pass[@backingInt(e.pass)] += 1;
        const smaller = filteredLess(e.after_keys, e.after_skips, e.before_keys, e.before_skips);
        const larger = filteredLess(e.before_keys, e.before_skips, e.after_keys, e.after_skips);
        if (e.lateral) {
            if (smaller or larger) self.violations += 1;
            self.laterals += 1;
            if (nonCanonicalPairs(e.after_choices, e.after_skips) >= nonCanonicalPairs(e.before_choices, e.before_skips))
                self.lateral_count_violations += 1;
            if (!changesOnePair(e.before_choices, e.after_choices, e.before_skips)) self.lateral_position_violations += 1;
        } else if (!smaller) {
            self.violations += 1;
        }
    }

    fn count(self: *const Monitor, pass: zigprop.internal.ShrinkPass) usize {
        return self.by_pass[@backingInt(pass)];
    }
};

/// Pairs outside class 3, counted independently of the shrinker: a pair
/// is a non-skip position followed by a skip position (design v2.1
/// §4.1), and its class is the value at the first position.
fn nonCanonicalPairs(choices: []const Choice, skips: []const bool) usize {
    var n: usize = 0;
    for (0..choices.len -| 1) |i| {
        if (!skips[i] and skips[i + 1] and choices[i].value != 3) n += 1;
    }
    return n;
}

/// Whether `after` has the length of `before` and differs from it only
/// at one pair's two positions (i, i + 1).
fn changesOnePair(before: []const Choice, after: []const Choice, skips: []const bool) bool {
    if (before.len != after.len) return false;
    var first: ?usize = null;
    for (before, after, 0..) |b, a, k| {
        if (b.value == a.value) continue;
        const start = first orelse blk: {
            first = k;
            break :blk k;
        };
        if (k != start and k != start + 1) return false;
    }
    const i = first orelse return false;
    return i + 1 < skips.len and !skips[i] and skips[i + 1];
}

/// Independent shortlex check over the filtered key sequences (the
/// test does not reuse the shrinker's comparison).
fn filteredLess(a: []const u64, a_skip: []const bool, b: []const u64, b_skip: []const bool) bool {
    var fa: [4096]u64 = undefined;
    var fb: [4096]u64 = undefined;
    var la: usize = 0;
    var lb: usize = 0;
    for (a, a_skip) |k, s| {
        if (!s) {
            fa[la] = k;
            la += 1;
        }
    }
    for (b, b_skip) |k, s| {
        if (!s) {
            fb[lb] = k;
            lb += 1;
        }
    }
    if (la != lb) return la < lb;
    for (fa[0..la], fb[0..lb]) |x, y| {
        if (x != y) return x < y;
    }
    return false;
}

const Shrunk = struct {
    choices: []Choice,
    keys: []u64,
    evaluations: usize,
    outcome: zigprop.ShrinkOutcome,
};

/// Replays `values` (the initial failing sequence), then shrinks it
/// with the given internal options. Result slices are arena-owned.
fn shrinkFrom(comptime T: type, arena: std.mem.Allocator, property: *const fn (T) bool, limits: zigprop.Limits, values: []const u64, options: zigprop.internal.ShrinkOptions) !Shrunk {
    const buf = try arena.alloc(Choice, values.len);
    for (values, buf) |v, *c| c.* = .{ .bound = 0, .value = v };
    var src = zigprop.internal.Source.initReplay(arena, buf, 100_000);
    var ctx_state: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena, limits);
    const v = try zigprop.generate(T, &ctx);
    try std.testing.expect(!property(v));
    const r = try zigprop.internal.shrinkSpanned(std.testing.allocator, T, null, property, limits, 2000, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, options);
    defer std.testing.allocator.free(r.choices);
    var rep = zigprop.internal.Source.initReplay(arena, r.choices, 100_000);
    var rctx_state: GenState = undefined;
    var rctx = zigprop.internal.genContextForTest(&rctx_state, &rep, arena, limits);
    _ = try zigprop.generate(T, &rctx);
    var keys: std.ArrayList(u64) = .empty;
    for (rep.recorded_keys.items, rep.recorded_skip.items) |k, s| {
        if (!s) try keys.append(arena, k);
    }
    return .{ .choices = try arena.dupe(Choice, r.choices), .keys = keys.items, .evaluations = r.evaluations, .outcome = r.outcome };
}

test "shrink: element deletion removes a leading element with its length" {
    // [1, 7, 3] as []const u8: length 3, then (class 0, value) pairs.
    // v0.2 could not delete the 1 together with its length draw; P5
    // reaches the unique minimum [7], keys [1, 7] (design v0.3 §3.6).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mon: Monitor = .{};
    const s = try shrinkFrom([]const u8, arena.allocator(), noSevenBytes, .{}, &.{ 3, 0, 1, 0, 7, 0, 3 }, .{ .on_accept = mon.hook() });
    try std.testing.expectEqualSlices(u64, &.{ 1, 7 }, s.keys);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, s.outcome);
    try std.testing.expect(mon.count(.p5_delete) >= 1);
    try std.testing.expectEqual(@as(usize, 0), mon.violations);
}

test "shrink: subtree promotion lifts a deeply nested failing node" {
    // Tree{1, [Tree{2, [Tree{3, [Tree{7, [Tree{9, []}]}]}]}]}.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mon: Monitor = .{};
    const s = try shrinkFrom(Tree, arena.allocator(), noSevenTree, .{}, &.{ 0, 2, 1, 0, 4, 1, 0, 6, 1, 0, 14, 1, 0, 18, 0 }, .{ .on_accept = mon.hook() });
    try std.testing.expectEqualSlices(u64, &.{ 14, 0 }, s.keys);
    try std.testing.expect(mon.count(.p6_promote) >= 1);
    try std.testing.expectEqual(@as(usize, 0), mon.violations);
}

fn tripleGen(ctx: *GenContext) anyerror![]const [3]u8 {
    var list: std.ArrayList([3]u8) = .empty;
    while (true) {
        const v: u8 = @intCast(ctx.range(256));
        if (v == 0) break;
        try list.append(ctx.allocator, .{ v, @intCast(ctx.range(256)), @intCast(ctx.range(256)) });
    }
    return list.toOwnedSlice(ctx.allocator);
}

fn noTripleSeven(xs: []const [3]u8) bool {
    for (xs) |t| {
        if (t[0] == 7 and t[1] == 7 and t[2] == 7) return false;
    }
    return true;
}

test "shrink: P1b deletes a size-3 chunk at the fixed point" {
    // Custom generator (no spans): triples until a 0. From
    // {1,1,1, 7,7,7, 0}, P2 reaches {1,0,0, 7,7,7, 0}, where no
    // power-of-two chunk deletion keeps the (7,7,7) triple aligned.
    // Only P1b's size-3 deletion reaches {7,7,7, 0}.
    const entries = [_]zigprop.Regression{.{ .id = "t", .gen_version = zigprop.generator_version, .choices = &.{ 1, 1, 1, 7, 7, 7, 0 } }};
    var report = try zigprop.checkCustom(std.testing.allocator, []const [3]u8, tripleGen, noTripleSeven, .{
        .regressions = &entries,
        .regression_id = "t",
    });
    defer report.deinit();
    const f = report.failed;
    try std.testing.expect(f.origin == .regression);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, f.shrink_outcome);
    var vals: [4]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 4), f.shrunk_choices.len);
    for (f.shrunk_choices, 0..) |c, i| vals[i] = c.value;
    try std.testing.expectEqualSlices(u64, &.{ 7, 7, 7, 0 }, &vals);
}

const t6_limits: zigprop.Limits = .{ .max_len = 4, .max_depth = 3 };

fn monitorSeeds(comptime T: type, property: *const fn (T) bool, limits: zigprop.Limits, total: *Monitor) !void {
    for (0..10) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var report = try zigprop.check(std.testing.allocator, T, property, .{ .seed = seed, .max_cases = 200, .shrink_budget = 0, .limits = limits });
        defer report.deinit();
        if (report != .failed) continue;
        const vals = try a.alloc(u64, report.failed.choices.len);
        for (report.failed.choices, vals) |c, *v| v.* = c.value;
        var mon: Monitor = .{};
        _ = try shrinkFrom(T, a, property, limits, vals, .{ .on_accept = mon.hook() });
        try std.testing.expectEqual(@as(usize, 0), mon.violations);
        total.accepts += mon.accepts;
        total.laterals += mon.laterals;
        total.lateral_count_violations += mon.lateral_count_violations;
        total.lateral_position_violations += mon.lateral_position_violations;
        for (&total.by_pass, mon.by_pass) |*x, y| x.* += y;
    }
}

fn below1000(x: u32) bool {
    return x < 1000;
}

test "shrink: P4's lateral move keeps the keys, lowers the pairs outside class 3, and changes one pair" {
    // The accept hook over the T6/T7 shapes and a u32 bound, seeds
    // 0..9. Every P4 acceptance must be key-equal, have fewer pairs
    // outside class 3 than before (counted here, not by the shrinker),
    // and differ from the stored sequence only at one pair (i, i + 1).
    var total = Monitor{};
    try monitorSeeds(Tree, noSevenTree, t6_limits, &total);
    try monitorSeeds([]const u8, noSevenBytes, .{}, &total);
    try monitorSeeds(u32, below1000, .{}, &total);
    try std.testing.expectEqual(@as(usize, 0), total.lateral_count_violations);
    try std.testing.expectEqual(@as(usize, 0), total.lateral_position_violations);
    // Path evidence: P4 accepted at least once, so the checks above ran.
    try std.testing.expect(total.laterals > 0);
    try std.testing.expectEqual(total.laterals, total.count(.p4_reexpress));
}

test "shrink: new passes never accept a non-smaller candidate" {
    // The acceptance-monotonicity hook (design v0.3 §3.9) over the
    // T6/T7 shapes, seeds 0..9: every ordinary acceptance is strictly
    // shortlex-smaller and every P4 lateral move is key-equal.
    var total = Monitor{};
    try monitorSeeds(Tree, noSevenTree, t6_limits, &total);
    try monitorSeeds([]const u8, noSevenBytes, .{}, &total);
    // The hook saw the new passes accept at least once.
    try std.testing.expect(total.count(.p5_delete) > 0);
    try std.testing.expect(total.count(.p6_promote) > 0);
}

test "shrink: the internal pass mask disables passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = [_]u64{ 3, 0, 1, 0, 7, 0, 3 };
    const tree = [_]u64{ 0, 6, 1, 0, 14, 1, 0, 18, 0 };

    // P5 off: no P5 acceptance on the slice.
    var m5: Monitor = .{};
    _ = try shrinkFrom([]const u8, a, noSevenBytes, .{}, &bytes, .{ .passes = .{ .p5 = false }, .on_accept = m5.hook() });
    try std.testing.expectEqual(@as(usize, 0), m5.count(.p5_delete));

    // P6 off: no P6 acceptance. (P1b's size-3 chunk, the root pair
    // plus its length draw, can still lift this one-kid root.)
    var m6: Monitor = .{};
    _ = try shrinkFrom(Tree, a, noSevenTree, .{}, &tree, .{ .passes = .{ .p6 = false }, .on_accept = m6.hook() });
    try std.testing.expectEqual(@as(usize, 0), m6.count(.p6_promote));

    // P6 and P1b off: the v0.2 neighbourhood, so the 7 stays below
    // the root ({0, [{7, []}]}, four keys).
    const s61 = try shrinkFrom(Tree, a, noSevenTree, .{}, &tree, .{ .passes = .{ .p6 = false, .p1b = false } });
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 14, 0 }, s61.keys);

    // Everything off: no candidate is evaluated, the input is a fixed point.
    const off: zigprop.internal.ShrinkPassMask = .{ .p1 = false, .p1b = false, .p2 = false, .p3 = false, .p4 = false, .p5 = false, .p6 = false };
    const s0 = try shrinkFrom(Tree, a, noSevenTree, .{}, &tree, .{ .passes = off });
    try std.testing.expectEqual(@as(usize, 0), s0.evaluations);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, s0.outcome);
}

test "shrink: budget exhaustion stops the new passes early" {
    // With a budget of 1 on a slice, exactly one candidate is
    // evaluated and the outcome is budget_exhausted.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = try a.alloc(Choice, 7);
    for ([_]u64{ 3, 0, 1, 0, 7, 0, 3 }, buf) |v, *c| c.* = .{ .bound = 0, .value = v };
    var src = zigprop.internal.Source.initReplay(a, buf, 100_000);
    var ctx_state: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, a, .{});
    _ = try zigprop.generate([]const u8, &ctx);
    const r = try zigprop.internal.shrinkSpanned(std.testing.allocator, []const u8, null, noSevenBytes, .{}, 1, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, .{});
    defer std.testing.allocator.free(r.choices);
    try std.testing.expectEqual(@as(usize, 1), r.evaluations);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.budget_exhausted, r.outcome);
}

// ---------------------------------------------------------------------
// M7: the cut scope (design v0.3 §1.3, §1.7, D12, D13)
// ---------------------------------------------------------------------

const cut = zigprop.internal.cut;

// The meta7 / meta8 zoo, plus the §1.7 types.
const MA = struct { tag: u8, bs: []const MB };
const MB = struct { back: []const MA, leaf: bool };
const Json = union(enum) { int: i64, str: []const u8, list: []const Json, obj: []const Pair };
const Pair = struct { k: []const u8, v: Json };
const E = union(enum) { lit: i64, add: []const E, let: struct { name: []const u8, body: []const E } };
const Bin = struct { v: i64, a: []const Bin, b: []const Bin };
const List = union(enum) { nil, cons: []const List };
const Color = union(enum) { red, black };
const Node = struct { c: Color, kids: []const Node };
const ZU = union(enum) { e: [0]u8, v: u8 };
const ZNode = struct { f: ZU, kids: []const ZNode };
const Unit = union(enum) { a };
const ZU2 = union(enum) { e: [0]Unit, v: u8 };
const ZNode2 = struct { f: ZU2, kids: []const ZNode2 };
const Tree2 = struct { name: []const u8, extra: ?u32, kids: []const Tree2 };
const Other = struct { next: []const Other };
const Tree3 = struct { meta: ?Other, kids: []const Tree3 };
const Value = union(enum) { int: i64, str: []const u8, list: []const Value };
const Opt = struct { x: u8, child: ?*const u8 = null }; // not generated; type-level only
const ArrRec = struct { pair: [2]?ArrRecBox, v: u8 };
const ArrRecBox = struct { inner: []const ArrRec };
// A single-variant union on the recursive channel: at a cut m = 1.
const OneNode = struct { v: u8, c: union(enum) { kids: []const OneNode } };

const cut_zoo = .{ Tree, MA, MB, Json, Pair, E, Bin, List, Node, ZNode, ZNode2, Tree2, Other, Tree3, Value, ArrRec, ArrRecBox, OneNode };

fn zeroReplayCut(comptime R: type) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zeros: [64]Choice = @splat(.{ .bound = 0, .value = 0 });
    var src = zigprop.internal.Source.initReplay(a, &zeros, 100_000);
    var st: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&st, &src, a, .{});
    _ = cut.generateCut(R, &ctx) catch |err| {
        // Widened: a cut form without unions cannot fail this way, so
        // its inferred error set lacks InvalidGeneration.
        const e: anyerror = err;
        if (e == error.InvalidGeneration) return false;
        return e;
    };
    return true;
}

test "cut: cutExists agrees with generateCut on every listed type" {
    // Table-driven agreement (design v0.3 §1.7): the all-zero replay of
    // R's cut form fails with InvalidGeneration exactly when
    // !cutExistsRel(R, R). (For legal Zig types every route back to R
    // passes a slice or an optional, so every listed type has a cut
    // form; M0-a found no constructible m = 0 union.)
    inline for (cut_zoo) |R| {
        errdefer std.debug.print("cut agreement differs for {s}\n", .{@typeName(R)});
        try std.testing.expectEqual(cut.cutExistsRel(R, R), try zeroReplayCut(R));
    }
    // The admissible sets of the zoo's unions (one function, D13).
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, cut.admissible(Json, Json));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, cut.admissible(List, List));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, cut.admissible(E, E));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, cut.admissible(Value, Value));
    try std.testing.expectEqualSlices(usize, &.{0}, cut.admissible(@FieldType(OneNode, "c"), OneNode));
    // Reachability (§1.3 edges).
    try std.testing.expect(cut.reaches(Pair, Json) and cut.reaches(Json, Pair));
    try std.testing.expect(!cut.reaches(Color, Node));
    try std.testing.expect(!cut.reaches(ZU, ZNode));
    try std.testing.expect(!cut.reaches(?Other, Tree3));
    try std.testing.expect(cut.reaches(MA, MB) and cut.reaches(MB, MA));
    try std.testing.expect(cut.reaches([2]?ArrRecBox, ArrRec));
    try std.testing.expect(!cut.reaches([0]Unit, Unit));
    _ = Opt;
}

test "cut: non-recursive fields are generated at the cut" {
    // Tree2 at max_depth 0: the cut kid draws its name (length 2, "BC")
    // and its extra (present, 7); only kids, which reaches Tree2, is
    // cut. (v1: name = "" and extra = null with no draws.)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]u64{ 1, 0, 65, 1, 0, 9, 1, 2, 0, 66, 0, 67, 1, 0, 7 };
    const buf = try a.alloc(Choice, values.len);
    for (values, buf) |v, *c| c.* = .{ .bound = 0, .value = v };
    var src = zigprop.internal.Source.initReplay(a, buf, 100_000);
    var st: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&st, &src, a, .{ .max_depth = 0, .max_len = 4 });
    const t = try zigprop.generate(Tree2, &ctx);
    try std.testing.expect(!src.exhausted);
    try std.testing.expectEqual(@as(usize, 15), src.pos);
    try std.testing.expectEqualStrings("A", t.name);
    try std.testing.expectEqual(@as(?u32, 9), t.extra);
    try std.testing.expectEqual(@as(usize, 1), t.kids.len);
    try std.testing.expectEqualStrings("BC", t.kids[0].name);
    try std.testing.expectEqual(@as(?u32, 7), t.kids[0].extra);
    try std.testing.expectEqual(@as(usize, 0), t.kids[0].kids.len);
    // The cut kid's name has a length draw (position 7, value 2).
    try std.testing.expectEqual(Choice{ .bound = 5, .value = 2 }, src.recorded.items[7]);
    try std.testing.expectEqualSlices(u64, &.{ 1, 65, 65, 1, 9, 9, 1, 2, 66, 66, 67, 67, 1, 7, 7 }, src.recorded_keys.items);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true, false, false, true, false, false, false, true, false, true, false, false, true }, src.recorded_skip.items);
}

test "cut: Json at the limit draws among admissible variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pinned: a cut .str under a root .list ([2, 1] then tag 1, length
    // 1, one u8 pair).
    const values = [_]u64{ 2, 1, 1, 1, 0, 88 };
    const buf = try a.alloc(Choice, values.len);
    for (values, buf) |v, *c| c.* = .{ .bound = 0, .value = v };
    var src = zigprop.internal.Source.initReplay(a, buf, 100_000);
    var st: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&st, &src, a, .{ .max_depth = 0 });
    const v = try zigprop.generate(Json, &ctx);
    try std.testing.expectEqual(@as(usize, 6), src.pos);
    try std.testing.expectEqualStrings("X", v.list[0].str);
    try std.testing.expectEqual(Choice{ .bound = 4, .value = 1 }, src.recorded.items[2]); // the cut tag draw, m = 4

    // Seeds 0..9: .str and an empty .list both occur at the cut.
    var saw_str = false;
    var saw_empty_list = false;
    for (0..10) |seed| {
        for (0..20) |attempt| {
            var rs = zigprop.internal.Source.initRandom(a, zigprop.internal.deriveSeed(seed, attempt), 100_000);
            var rst: GenState = undefined;
            var rctx = zigprop.internal.genContextForTest(&rst, &rs, a, .{ .max_depth = 0, .max_len = 4 });
            const j = zigprop.generate(Json, &rctx) catch continue;
            const nested: []const Json = switch (j) {
                .list => |xs| xs,
                else => &.{},
            };
            for (nested) |x| switch (x) {
                .str => saw_str = true,
                .list => |l| {
                    try std.testing.expectEqual(@as(usize, 0), l.len);
                    saw_empty_list = true;
                },
                else => {},
            };
        }
    }
    try std.testing.expect(saw_str and saw_empty_list);
}

/// The choices recorded by an all-zero replay of a lone u8.
fn zeroU8Choices(a: std.mem.Allocator) ![]const Choice {
    const zeros: [64]Choice = @splat(.{ .bound = 0, .value = 0 });
    var src = zigprop.internal.Source.initReplay(a, &zeros, 100_000);
    var st: GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&st, &src, a, .{});
    _ = try zigprop.generate(u8, &ctx);
    return src.recorded.items;
}

fn expectNoIndexOne(choices: []const Choice) !void {
    for (choices) |c| try std.testing.expect(c.bound != 1);
}

test "cut: a single admissible variant (m = 1) draws no tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u8_draws = try zeroU8Choices(a);

    // OneNode's cut form from all zeros at max_depth 0: the u8 field's
    // draws and nothing else; the m = 1 union records no tag draw.
    {
        const zeros: [64]Choice = @splat(.{ .bound = 0, .value = 0 });
        var src = zigprop.internal.Source.initReplay(a, &zeros, 100_000);
        var st: GenState = undefined;
        var ctx = zigprop.internal.genContextForTest(&st, &src, a, .{ .max_depth = 0 });
        const n = try cut.generateCut(OneNode, &ctx);
        try std.testing.expectEqual(@as(u8, 0), n.v);
        try std.testing.expectEqual(@as(usize, 0), n.c.kids.len);
        try std.testing.expectEqual(u8_draws.len, src.pos);
        try std.testing.expectEqualSlices(Choice, u8_draws, src.recorded.items);
        // Path evidence: no index(1) draw was recorded.
        try expectNoIndexOne(src.recorded.items);
    }

    // Through generate at max_depth 0: the root's union is generated
    // normally (an index(1) tag draw), its one kid is cut and records
    // only its u8 draws.
    {
        var values: [64]Choice = @splat(.{ .bound = 0, .value = 0 });
        values[u8_draws.len + 1].value = 1; // the root's kids length
        var src = zigprop.internal.Source.initReplay(a, &values, 100_000);
        var st: GenState = undefined;
        var ctx = zigprop.internal.genContextForTest(&st, &src, a, .{ .max_depth = 0 });
        const n = try zigprop.generate(OneNode, &ctx);
        try std.testing.expectEqual(@as(usize, 1), n.c.kids.len);
        try std.testing.expectEqual(@as(usize, 0), n.c.kids[0].c.kids.len);
        try std.testing.expectEqual(2 * u8_draws.len + 2, src.pos);
        const rec = src.recorded.items;
        try std.testing.expectEqual(@as(u64, 1), rec[u8_draws.len].bound); // the root's tag draw
        const kid = rec[u8_draws.len + 2 ..];
        try std.testing.expectEqualSlices(Choice, u8_draws, kid);
        try expectNoIndexOne(kid);
    }
}

/// The unions reachable from R (through fields, payloads, slices,
/// optionals and arrays) that themselves reach R, i.e. the unions a cut
/// of R can meet.
fn unionsCutWithin(comptime R: type) []const type {
    comptime {
        @setEvalBranchQuota(100_000);
        var seen: []const type = &.{};
        var todo: []const type = &.{R};
        var out: []const type = &.{};
        while (todo.len > 0) {
            const T = todo[0];
            todo = todo[1..];
            const known = for (seen) |S| {
                if (S == T) break true;
            } else false;
            if (known) continue;
            seen = seen ++ &[_]type{T};
            switch (@typeInfo(T)) {
                .@"struct" => |st| todo = todo ++ st.field_types,
                .@"union" => |un| {
                    if (cut.reaches(T, R)) out = out ++ &[_]type{T};
                    todo = todo ++ un.field_types;
                },
                .optional => |o| todo = todo ++ &[_]type{o.child},
                .array => |arr| todo = todo ++ &[_]type{arr.child},
                .pointer => |p| todo = todo ++ &[_]type{p.child},
                else => {},
            }
        }
        return out;
    }
}

test "cut: every union a cut of a listed type meets has an admissible variant (m = 0 unreachable)" {
    // M0-a believed m = 0 unreachable; this pins it for the listed types.
    comptime var pairs: usize = 0;
    inline for (cut_zoo) |R| {
        inline for (comptime unionsCutWithin(R)) |Un| {
            if (comptime cut.admissible(Un, R).len == 0)
                @compileError("m = 0 at a cut of " ++ @typeName(R) ++ ": " ++ @typeName(Un));
            pairs += 1;
        }
    }
    // Not vacuous: Json, Pair, E, List, Value and OneNode each meet one.
    try std.testing.expect(pairs >= 6);
}

fn otherDepth(o: Other) usize {
    var d: usize = 0;
    for (o.next) |n| d = @max(d, 1 + otherDepth(n));
    return d;
}

test "cut: an independent recursive type below the cut stays bounded" {
    // Tree3 at max_depth 0: the cut kid's meta (?Other) does not reach
    // Tree3, so it is generated post-limit (Set = ∅, n = cap): Other's
    // first entry is generated normally and any re-entry of Other is
    // cut at once, so Other nests at most one level below a cut.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var saw_meta = false;
    for (0..10) |seed| {
        for (0..20) |attempt| {
            var src = zigprop.internal.Source.initRandom(a, zigprop.internal.deriveSeed(seed, attempt), 100_000);
            var st: GenState = undefined;
            var ctx = zigprop.internal.genContextForTest(&st, &src, a, .{ .max_depth = 0, .max_len = 3 });
            const t = zigprop.generate(Tree3, &ctx) catch continue;
            for (t.kids) |k| {
                try std.testing.expectEqual(@as(usize, 0), k.kids.len);
                if (k.meta) |m| {
                    saw_meta = true;
                    try std.testing.expect(otherDepth(m) <= 1);
                }
            }
        }
    }
    try std.testing.expect(saw_meta);
}

fn genViaContext(ctx: *GenContext) anyerror!Tree {
    // A custom generator calling back into built-in generation starts a
    // fresh comptime state (n = 0) but shares the runtime depth (the
    // H1 invariant depth >= n of design v0.3 §1.3).
    return ctx.generate(Tree);
}

test "cut: custom generators calling generate stay bounded under every max_depth" {
    for (0..4) |d| {
        var r = try zigprop.checkCustom(std.testing.allocator, Tree, genViaContext, struct {
            fn p(_: Tree) bool {
                return true;
            }
        }.p, .{ .max_cases = 30, .limits = .{ .max_len = 3, .max_depth = d } });
        defer r.deinit();
        try std.testing.expect(r == .passed);
    }
}
