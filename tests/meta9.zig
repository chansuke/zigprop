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
        } else if (!smaller) {
            self.violations += 1;
        }
    }

    fn count(self: *const Monitor, pass: zigprop.internal.ShrinkPass) usize {
        return self.by_pass[@backingInt(pass)];
    }
};

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
    const r = try zigprop.internal.shrinkSpanned(std.testing.allocator, T, null, property, limits, 2000, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, "", options);
    defer std.testing.allocator.free(r.value_display);
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
    try std.testing.expect(f.regression_index != null);
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
        for (&total.by_pass, mon.by_pass) |*x, y| x.* += y;
    }
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
    const r = try zigprop.internal.shrinkSpanned(std.testing.allocator, []const u8, null, noSevenBytes, .{}, 1, src.recorded.items, src.recorded_keys.items, src.recorded_skip.items, src.recorded_spans.items, "", .{});
    defer std.testing.allocator.free(r.value_display);
    defer std.testing.allocator.free(r.choices);
    try std.testing.expectEqual(@as(usize, 1), r.evaluations);
    try std.testing.expectEqual(zigprop.ShrinkOutcome.budget_exhausted, r.outcome);
}
