//! v0.3 meta tests: spans (M2), the new shrink passes (M3) and the
//! cut scope (M7). Design: docs/design-v0.3.md §1.7, §3.9.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const Span = zigprop.Span;

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
    var src = zigprop.Source.initReplay(arena, buf, 100_000);
    var ctx = zigprop.GenContext{ .src = &src, .allocator = arena, .limits = limits };
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
        var src = zigprop.Source.initRandom(a, zigprop.deriveSeed(seed, 0), 100_000);
        var ctx = zigprop.GenContext{ .src = &src, .allocator = a, .limits = .{ .max_len = 4, .max_depth = 3 } };
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
