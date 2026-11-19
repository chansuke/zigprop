//! v0.2.1: path-independent comptime unfolding (review C1) and cut
//! forms for void / zero-length-array payloads (review I1).
//!
//! The recursive types below reach themselves along more than one
//! route. Under the old path-tuple keying each route produced its
//! own instantiations and compilation did not finish; this file
//! compiling quickly IS the C1 regression check. Keep max_cases
//! small so the suite stays fast.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const GenContext = zigprop.GenContext;

// JSON-like: two routes back to Json (list, and obj -> Pair.v).
const Json = union(enum) {
    int: i64,
    str: []const u8,
    list: []const Json,
    obj: []const Pair,
};
const Pair = struct { k: []const u8, v: Json };

// AST-like: two routes back to E (add, and let -> body).
const E = union(enum) {
    lit: i64,
    add: []const E,
    let: struct { name: []const u8, body: []const E },
};

// Two slice channels to itself.
const Bin = struct { v: i64, a: []const Bin, b: []const Bin };

// I1: void and zero-length-array payloads have cut forms.
const List = union(enum) { nil, cons: []const List };
const Color = union(enum) { red, black };
const Node = struct { c: Color, kids: []const Node };
const ZU = union(enum) { e: [0]u8, v: u8 };
const ZNode = struct { f: ZU, kids: []const ZNode };
const Unit = union(enum) { a };
const ZU2 = union(enum) { e: [0]Unit, v: u8 };
const ZNode2 = struct { f: ZU2, kids: []const ZNode2 };

fn genReplay(comptime T: type, arena: *std.heap.ArenaAllocator, values: []const u64, limits: zigprop.Limits, consumed: *usize) !T {
    var buf: [64]Choice = undefined;
    for (values, 0..) |v, i| buf[i] = .{ .bound = 0, .value = v };
    var src = zigprop.internal.Source.initReplay(std.testing.allocator, buf[0..values.len], 100_000);
    defer src.deinit();
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena.allocator(), limits);
    const v = try zigprop.generate(T, &ctx);
    consumed.* = src.pos;
    return v;
}

fn genRandom(comptime T: type, arena: *std.heap.ArenaAllocator, seed: u64, limits: zigprop.Limits) !T {
    // Recursive generation may discard (element budget); walk
    // attempts until one succeeds.
    for (0..64) |attempt| {
        var src = zigprop.internal.Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(seed, attempt), 100_000);
        defer src.deinit();
        var ctx_state: zigprop.internal.GenState = undefined;
        var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena.allocator(), limits);
        return zigprop.generate(T, &ctx) catch |err| switch (err) {
            error.InvalidGeneration => continue,
            else => return err,
        };
    }
    return error.InvalidGeneration;
}

fn alwaysTrue(comptime T: type) fn (T) bool {
    return struct {
        fn p(_: T) bool {
            return true;
        }
    }.p;
}

// ---------------------------------------------------------------------
// C1: multi-path recursive types
// ---------------------------------------------------------------------

/// Every Json below the root must be the cut form: the first variant
/// with a cut form is .int, so list and obj are never taken.
fn expectAllNestedCut(v: Json) !void {
    switch (v) {
        .int, .str => {},
        .list => |xs| for (xs) |x| try std.testing.expect(std.meta.activeTag(x) == .int),
        .obj => |ps| for (ps) |p| try std.testing.expect(std.meta.activeTag(p.v) == .int),
    }
}

test "multi-path: a JSON-like type compiles, checks and generates" {
    var report = try zigprop.check(std.testing.allocator, Json, alwaysTrue(Json), .{
        .seed = 0,
        .max_cases = 10,
        .limits = .{ .max_len = 3, .max_depth = 3 },
    });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .passed);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..5) |seed| {
        _ = try genRandom(Json, &arena, seed, .{ .max_len = 3, .max_depth = 3 });
    }
}

test "multi-path: JSON at max_depth = 0 cuts every nested value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var saw_nested = false;
    for (0..10) |seed| {
        const v = try genRandom(Json, &arena, seed, .{ .max_len = 3, .max_depth = 0 });
        try expectAllNestedCut(v);
        switch (v) {
            .list => |xs| saw_nested = saw_nested or xs.len > 0,
            .obj => |ps| saw_nested = saw_nested or ps.len > 0,
            else => {},
        }
    }
    try std.testing.expect(saw_nested);

    // Pinned by replay: root .obj with one pair; the pair's key is
    // generated normally (length 1, one u8 pair), its value is the
    // cut form .int whose integer still draws.
    var consumed: usize = 0;
    const v = try genReplay(Json, &arena, &.{ 3, 1, 1, 0, 120, 0, 5 }, .{ .max_depth = 0 }, &consumed);
    try std.testing.expect(std.meta.activeTag(v) == .obj);
    try std.testing.expectEqual(@as(usize, 1), v.obj.len);
    try std.testing.expectEqualStrings("x", v.obj[0].k);
    try std.testing.expect(std.meta.activeTag(v.obj[0].v) == .int);
    try std.testing.expectEqual(@as(i64, -3), v.obj[0].v.int);
    try std.testing.expectEqual(@as(usize, 7), consumed);
}

test "multi-path: an AST-like union generates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..5) |seed| {
        _ = try genRandom(E, &arena, seed, .{ .max_len = 2, .max_depth = 4 });
    }
    var report = try zigprop.check(std.testing.allocator, E, alwaysTrue(E), .{
        .seed = 0,
        .max_cases = 10,
        .limits = .{ .max_len = 2, .max_depth = 4 },
    });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .passed);
}

fn binDepth(t: Bin) usize {
    var d: usize = 0;
    for (t.a) |k| d = @max(d, 1 + binDepth(k));
    for (t.b) |k| d = @max(d, 1 + binDepth(k));
    return d;
}

test "multi-path: a struct with two slice channels to itself stays depth-bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..5) |seed| {
        const t = try genRandom(Bin, &arena, seed, .{ .max_len = 2, .max_depth = 3 });
        // Root, max_depth normal levels, one cut level.
        try std.testing.expect(binDepth(t) <= 4);
    }
}

// ---------------------------------------------------------------------
// I1: void and zero-length-array payloads have cut forms
// ---------------------------------------------------------------------

test "cut: a void variant is the cut form and consumes no draws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var consumed: usize = 0;
    const v = try genReplay(List, &arena, &.{ 1, 1 }, .{ .max_depth = 0, .max_len = 4 }, &consumed);
    try std.testing.expect(std.meta.activeTag(v) == .cons);
    try std.testing.expectEqual(@as(usize, 1), v.cons.len);
    try std.testing.expect(std.meta.activeTag(v.cons[0]) == .nil);
    // tag draw + length draw; the cut element draws nothing.
    try std.testing.expectEqual(@as(usize, 2), consumed);
}

test "cut: an all-void union field no longer makes the cut fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..10) |seed| {
        var src = zigprop.internal.Source.initRandom(std.testing.allocator, zigprop.internal.deriveSeed(seed, 0), 100_000);
        defer src.deinit();
        var ctx_state: zigprop.internal.GenState = undefined;
        var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena.allocator(), .{ .max_depth = 0, .max_len = 4 });
        const n = try zigprop.generate(Node, &ctx);
        for (n.kids) |k| {
            try std.testing.expect(std.meta.activeTag(k.c) == .red);
            try std.testing.expectEqual(@as(usize, 0), k.kids.len);
        }
    }
}

test "cut: a zero-length-array variant is a cut form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Root f = .v (tag 1, u8 pair 0/5), kids length 1; the kid is
    // cut: f = .e with no draws, kids empty.
    var consumed: usize = 0;
    const z = try genReplay(ZNode, &arena, &.{ 1, 0, 5, 1 }, .{ .max_depth = 0, .max_len = 4 }, &consumed);
    try std.testing.expect(std.meta.activeTag(z.f) == .v);
    try std.testing.expectEqual(@as(usize, 1), z.kids.len);
    try std.testing.expect(std.meta.activeTag(z.kids[0].f) == .e);
    try std.testing.expectEqual(@as(usize, 0), z.kids[0].kids.len);
    try std.testing.expectEqual(@as(usize, 4), consumed);

    // Same shape with an element type that had no cut form before
    // the fix ([0]Unit used to fall through to .v and draw).
    const z2 = try genReplay(ZNode2, &arena, &.{ 1, 0, 5, 1 }, .{ .max_depth = 0, .max_len = 4 }, &consumed);
    try std.testing.expect(std.meta.activeTag(z2.kids[0].f) == .e);
    try std.testing.expectEqual(@as(usize, 4), consumed);
}
