//! v0.2 milestone 3: recursive types (design v0.2 §3).
//!
//! This file is also the compile-time prerequisite of §3.2/§3.4:
//! the fact that it compiles at all proves that self-recursion,
//! mutual recursion and union-mediated recursion terminate at
//! comptime under the unfolding cap. The tests then pin the depth
//! semantics of §3.4: max_depth = 0 cuts every recursive
//! occurrence, depth is restored across siblings and on error
//! paths, and the cut form consumes no length/tag draws.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

const Tree = struct { value: i64, kids: []const Tree };

const MA = struct { tag: u8, bs: []const MB };
const MB = struct { back: []const MA, leaf: bool };

const Value = union(enum) { int: i64, str: []const u8, list: []const Value };

fn genReplay(comptime T: type, arena: *std.heap.ArenaAllocator, values: []const u64, limits: zigprop.Limits, consumed: *usize) !T {
    var buf: [64]Choice = undefined;
    for (values, 0..) |v, i| buf[i] = .{ .bound = 0, .value = v };
    var src = zigprop.Source.initReplay(std.testing.allocator, buf[0..values.len], 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = arena.allocator(), .limits = limits };
    const v = try zigprop.generate(T, &ctx);
    consumed.* = src.pos;
    return v;
}

fn genRandom(comptime T: type, arena: *std.heap.ArenaAllocator, seed: u64, limits: zigprop.Limits) !T {
    // Generation of a recursive type may discard (element budget);
    // walk attempts until one succeeds.
    for (0..64) |attempt| {
        var src = zigprop.Source.initRandom(std.testing.allocator, zigprop.deriveSeed(seed, attempt), 100_000);
        defer src.deinit();
        var ctx = GenContext{ .src = &src, .allocator = arena.allocator(), .limits = limits };
        return zigprop.generate(T, &ctx) catch |err| switch (err) {
            error.InvalidGeneration => continue,
            else => return err,
        };
    }
    return error.InvalidGeneration;
}

test "recursion: self-recursive trees generate and stay depth-bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try genRandom(Tree, &arena, 11, .{ .max_len = 3 });
    var max_depth_seen: usize = 0;
    const S = struct {
        fn walk(tr: Tree, d: usize, maxd: *usize) void {
            if (d > maxd.*) maxd.* = d;
            for (tr.kids) |k| walk(k, d + 1, maxd);
        }
    };
    S.walk(t, 0, &max_depth_seen);
    // Root, plus max_depth (8) normally generated recursive
    // levels, plus one cut level: the occurrence at the limit
    // still exists as a value, with its recursive channels cut.
    try std.testing.expect(max_depth_seen <= 9);
}

test "recursion: max_depth = 0 cuts every recursive occurrence, with no length draw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var consumed: usize = 0;
    const t = try genReplay(Tree, &arena, &.{ 0, 0, 2, 0, 0, 0, 0 }, .{ .max_depth = 0, .max_len = 4 }, &consumed);
    try std.testing.expectEqual(@as(i64, 0), t.value);
    try std.testing.expectEqual(@as(usize, 2), t.kids.len);
    for (t.kids) |k| {
        try std.testing.expectEqual(@as(usize, 0), k.kids.len);
    }
    // root pair (2) + length (1) + one value pair per cut kid (2+2);
    // the cut form consumes no length draw for its empty slices.
    try std.testing.expectEqual(@as(usize, 7), consumed);
}

test "recursion: depth is restored across siblings" {
    // max_depth = 1: each side of the pair may use its own level.
    // Per side: value pair, kids len 1, kid value pair, kid's kids
    // len 1, cut element value pair (its kids are cut: no draws).
    const Pair = struct { l: Tree, r: Tree };
    const side = [_]u64{ 0, 0, 1, 0, 0, 1, 0, 0 };
    var values: [16]u64 = undefined;
    @memcpy(values[0..8], &side);
    @memcpy(values[8..16], &side);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var consumed: usize = 0;
    const p = try genReplay(Pair, &arena, &values, .{ .max_depth = 1, .max_len = 4 }, &consumed);
    try std.testing.expectEqual(@as(usize, 1), p.l.kids.len);
    try std.testing.expectEqual(@as(usize, 1), p.l.kids[0].kids.len);
    try std.testing.expectEqual(@as(usize, 0), p.l.kids[0].kids[0].kids.len);
    try std.testing.expectEqual(@as(usize, 1), p.r.kids.len);
    try std.testing.expectEqual(@as(usize, 1), p.r.kids[0].kids.len);
    try std.testing.expectEqual(@as(usize, 16), consumed);
}

test "recursion: depth is restored on the error path" {
    // max_total_elements = 2 makes generation fail inside the
    // first kid's subtree (element 3 overall), while depth = 1.
    var buf: [16]Choice = undefined;
    const values = [_]u64{ 0, 0, 1, 0, 0, 2, 0, 0, 0 };
    for (values, 0..) |v, i| buf[i] = .{ .bound = 0, .value = v };
    var src = zigprop.Source.initReplay(std.testing.allocator, buf[0..values.len], 100_000);
    defer src.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = GenContext{ .src = &src, .allocator = arena.allocator(), .limits = .{ .max_total_elements = 2, .max_len = 4 } };
    try std.testing.expectError(error.InvalidGeneration, zigprop.generate(Tree, &ctx));
    try std.testing.expectEqual(@as(usize, 0), ctx.depth);
}

test "recursion: mutually recursive types generate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try genRandom(MA, &arena, 7, .{ .max_len = 2 });
    _ = a;
    const b = try genRandom(MB, &arena, 8, .{ .max_len = 2 });
    _ = b;
}

test "recursion: union-mediated recursion builds nested values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var consumed: usize = 0;
    const v = try genReplay(Value, &arena, &.{ 2, 2, 0, 0, 0, 2, 1, 0, 0, 0 }, .{}, &consumed);
    try std.testing.expect(std.meta.activeTag(v) == .list);
    try std.testing.expectEqual(@as(usize, 2), v.list.len);
    try std.testing.expect(std.meta.activeTag(v.list[0]) == .int);
    try std.testing.expectEqual(@as(i64, 0), v.list[0].int);
    try std.testing.expect(std.meta.activeTag(v.list[1]) == .list);
    try std.testing.expectEqual(@as(usize, 1), v.list[1].list.len);
    try std.testing.expectEqual(@as(i64, 0), v.list[1].list[0].int);
    try std.testing.expectEqual(@as(usize, 10), consumed);
}

fn hasSeven(t: Tree) bool {
    if (t.value == 7) return true;
    for (t.kids) |k| {
        if (hasSeven(k)) return true;
    }
    return false;
}

fn noSeven(t: Tree) bool {
    return !hasSeven(t);
}

test "recursion: shrinking a tree failure promotes the failing subtree" {
    // root 3 with one kid 7 with one kid 9. v0.2 pinned the
    // non-minimal {0, [{7, []}]} (keys [0, 1, 14, 0]): without subtree
    // promotion the 7 stayed in place. That expectation is retracted
    // (design v0.3 §3.6): P6 promotes the kid, and the unique
    // key-order minimum is Tree{ .value = 7, .kids = &.{} }, keys
    // [14, 0].
    const entries = [_]zigprop.Regression{.{ .id = "r", .gen_version = zigprop.generator_version, .choices = &.{ 0, 6, 1, 0, 14, 1, 0, 18, 0 } }};
    var report = try zigprop.check(std.testing.allocator, Tree, noSeven, .{
        .seed = 0,
        .regressions = &entries,
        .regression_id = "r",
    });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .failed);
    try std.testing.expect(report.failed.regression_index != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var consumed: usize = 0;
    const t = try genReplay(Tree, &arena, blk: {
        var vals: [16]u64 = undefined;
        for (report.failed.shrunk_choices, 0..) |c, i| vals[i] = c.value;
        break :blk vals[0..report.failed.shrunk_choices.len];
    }, .{}, &consumed);
    try std.testing.expectEqual(@as(i64, 7), t.value);
    try std.testing.expectEqual(@as(usize, 0), t.kids.len);
    // The key sequence is [14, 0]: one integer pair (key 14, the
    // second position skipped) and the length draw 0.
    var src = zigprop.Source.initReplay(std.testing.allocator, report.failed.shrunk_choices, 100_000);
    defer src.deinit();
    var ctx = GenContext{ .src = &src, .allocator = arena.allocator(), .limits = .{} };
    _ = try zigprop.generate(Tree, &ctx);
    var keys: std.ArrayList(u64) = .empty;
    defer keys.deinit(std.testing.allocator);
    for (src.recorded_keys.items, src.recorded_skip.items) |k, s| {
        if (!s) try keys.append(std.testing.allocator, k);
    }
    try std.testing.expectEqualSlices(u64, &.{ 14, 0 }, keys.items);
}

test "recursion: max_depth above the comptime cap is InvalidConfig" {
    const prop = struct {
        fn p(_: Tree) bool {
            return true;
        }
    }.p;
    try std.testing.expectError(error.InvalidConfig, zigprop.check(std.testing.allocator, Tree, prop, .{
        .limits = .{ .max_depth = zigprop.max_depth_cap + 1 },
    }));
}
