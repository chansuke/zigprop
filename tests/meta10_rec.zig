//! v0.3 M1: golden pins for the recursive-cut group (design v0.3 §7.4,
//! D35), recorded from v0.2.1 (generator_version 1); rewritten for
//! generator_version 2 in M7.
//!
//! This file is kept apart from tests/meta10.zig on purpose: M7 (cut
//! scope, generator_version 2) changes what is generated at a cut, so
//! it rewrote the (R) pins here deliberately (the retired v1 values are
//! kept as comments above the tables) and re-recorded the (S) pins.
//! Tree's cut form ({value drawn, kids empty}) is the same in v1 and v2,
//! so its (R) pins are unchanged. Every (R) pin in tests/meta10.zig
//! survives M7 unchanged.
//!
//! (R) replay pins: values -> value, re-recorded choices (bounds
//! included), keys, skips, consumed count. (S) random pins: seed
//! (attempt 0) -> recording and value. Display strings are not pinned.
//!
//! All expected values are literals captured from a run (v0.2.1 for M1;
//! the M7 implementation for the rewritten pins).

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;
const Limits = zigprop.Limits;

fn ReplayPin(comptime V: type) type {
    return struct {
        values: []const u64,
        limits: Limits = .{},
        value: V,
        choices: []const Choice,
        keys: []const u64,
        skips: []const bool,
        consumed: usize,
    };
}

fn RandomPin(comptime V: type) type {
    return struct {
        seed: u64,
        limits: Limits = .{},
        value: V,
        choices: []const Choice,
        keys: []const u64,
        skips: []const bool,
    };
}

fn Generated(comptime T: type) type {
    return struct {
        value: T,
        choices: []const Choice,
        keys: []const u64,
        skips: []const bool,
        consumed: usize,
    };
}

/// The only place that touches the Source (see tests/meta10.zig).
fn generateWith(comptime T: type, arena: std.mem.Allocator, mode: union(enum) { replay: []const u64, seed: u64 }, limits: Limits) !Generated(T) {
    var src = switch (mode) {
        .replay => |values| blk: {
            const buf = try arena.alloc(Choice, values.len);
            for (values, buf) |v, *c| c.* = .{ .bound = 0, .value = v };
            break :blk zigprop.internal.Source.initReplay(arena, buf, 100_000);
        },
        .seed => |seed| zigprop.internal.Source.initRandom(arena, zigprop.internal.deriveSeed(seed, 0), 100_000),
    };
    var ctx_state: zigprop.internal.GenState = undefined;
    var ctx = zigprop.internal.genContextForTest(&ctx_state, &src, arena, limits);
    const v = try zigprop.generate(T, &ctx);
    try std.testing.expect(!src.exhausted);
    return .{
        .value = v,
        .choices = try arena.dupe(Choice, src.recorded.items),
        .keys = try arena.dupe(u64, src.recorded_keys.items),
        .skips = try arena.dupe(bool, src.recorded_skip.items),
        .consumed = src.pos,
    };
}

fn checkReplay(comptime T: type, pins: []const ReplayPin(T)) !void {
    for (pins, 0..) |p, i| {
        errdefer std.debug.print("replay pin #{d} of {s} differs (values {any})\n", .{ i, @typeName(T), p.values });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const g = try generateWith(T, arena.allocator(), .{ .replay = p.values }, p.limits);
        try std.testing.expectEqualDeep(p.value, g.value);
        try std.testing.expectEqualSlices(Choice, p.choices, g.choices);
        try std.testing.expectEqualSlices(u64, p.keys, g.keys);
        try std.testing.expectEqualSlices(bool, p.skips, g.skips);
        try std.testing.expectEqual(p.consumed, g.consumed);
    }
}

fn checkRandom(comptime T: type, pins: []const RandomPin(T)) !void {
    for (pins, 0..) |p, i| {
        errdefer std.debug.print("random pin #{d} of {s} differs (seed {d})\n", .{ i, @typeName(T), p.seed });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const g = try generateWith(T, arena.allocator(), .{ .seed = p.seed }, p.limits);
        try std.testing.expectEqualDeep(p.value, g.value);
        try std.testing.expectEqualSlices(Choice, p.choices, g.choices);
        try std.testing.expectEqualSlices(u64, p.keys, g.keys);
        try std.testing.expectEqualSlices(bool, p.skips, g.skips);
    }
}

const Tree = struct { value: i64, kids: []const Tree };
const Json = union(enum) { int: i64, str: []const u8, list: []const Json, obj: []const Pair };
const Pair = struct { k: []const u8, v: Json };
const List = union(enum) { nil, cons: []const List };
const Color = union(enum) { red, black };
const Node = struct { c: Color, kids: []const Node };
const ZU = union(enum) { e: [0]u8, v: u8 };
const ZNode = struct { f: ZU, kids: []const ZNode };
const Tree2 = struct { name: []const u8, extra: ?u32, kids: []const Tree2 };

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "golden rec (R): Tree at max_depth 0 and 1" {
    // depth 0: the root's two kids are cut (value drawn, kids empty,
    // no length draw). depth 1: one normal kid level, then a cut.
    try checkReplay(Tree, &replay_tree_depth0);
    try checkReplay(Tree, &replay_tree_depth1);
}

test "golden rec (R): Json at max_depth 0" {
    // v2 (M7): a cut Json draws its tag among the admissible variants
    // {int, str, list, obj}; .str is generated normally, .list and
    // .obj are empty. (v1: every cut Json was .int with no tag draw.)
    try checkReplay(Json, &replay_json_depth0);
}

test "golden rec (R): List, Node, ZNode and Tree2 cuts" {
    // v2 (M7): List's cut draws a tag (m = 2); Node's Color and
    // ZNode's ZU do not reach the cut type and are generated normally;
    // Tree2's cut kid generates name and extra normally and cuts only
    // kids. (v1: .nil / .red / .e with no draws; name = "", extra =
    // null.)
    try checkReplay(List, &replay_list);
    try checkReplay(Node, &replay_node);
    try checkReplay(ZNode, &replay_znode);
    try checkReplay(Tree2, &replay_tree2);
}

test "golden rec (S): recursive types by seed" {
    try checkRandom(Tree, &random_tree);
    try checkRandom(Json, &random_json);
    try checkRandom(List, &random_list);
}

// ---------------------------------------------------------------------
// Pin tables (literals recorded from v0.2.1)
// ---------------------------------------------------------------------

const replay_tree_depth0 = [_]ReplayPin(Tree){
    .{ .values = &.{ 0, 0, 2, 0, 3, 0, 5 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .value = 0, .kids = &.{ .{ .value = -2, .kids = &.{} }, .{ .value = -3, .kids = &.{} } } }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 0 }, .{ .bound = 5, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 3 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 } }, .keys = &.{ 0, 0, 2, 3, 3, 5, 5 }, .skips = &.{ false, true, false, false, true, false, true }, .consumed = 7 },
};

const replay_tree_depth1 = [_]ReplayPin(Tree){
    .{ .values = &.{ 0, 1, 1, 0, 2, 1, 0, 4 }, .limits = .{ .max_len = 4, .max_depth = 1 }, .value = .{ .value = -1, .kids = &.{.{ .value = 1, .kids = &.{.{ .value = 2, .kids = &.{} }} }} }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 1 }, .{ .bound = 5, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 2 }, .{ .bound = 5, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 4 } }, .keys = &.{ 1, 1, 1, 2, 2, 1, 4, 4 }, .skips = &.{ false, true, false, false, true, false, false, true }, .consumed = 8 },
};

// The v1 (generator_version 1) pins below were retired in M7 and are
// kept here as history (design v0.3 §7.4, D34). Under v1 a cut union
// took its first variant with a cut form without a tag draw, and every
// channel of a cut node was cut, recursive or not. Under v2 only the
// channels that reach the cut type are cut; a cut union draws among its
// admissible variants (index(m) for m >= 2), and non-recursive channels
// are generated normally. Each v1 input below is exhausted under v2, so
// the v2 pins use new inputs that extend them with the new draws.
//
// v1 replay_json_depth0:
//   .{ .values = &.{ 3, 1, 1, 0, 120, 0, 5 }, .limits = .{ .max_depth = 0 }, .value = .{ .obj = &.{.{ .k = &.{120}, .v = .{ .int = -3 } }} }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 33, .value = 1 }, .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 120 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 } }, .keys = &.{ 3, 1, 1, 120, 120, 5, 5 }, .skips = &.{ false, false, false, false, true, false, true }, .consumed = 7 },
//   .{ .values = &.{ 2, 2, 0, 7, 0, 9 }, .limits = .{ .max_depth = 0 }, .value = .{ .list = &.{ .{ .int = -4 }, .{ .int = -5 } } }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 33, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 7 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 9 } }, .keys = &.{ 2, 2, 7, 7, 9, 9 }, .skips = &.{ false, false, false, true, false, true }, .consumed = 6 },
// v1 replay_list:
//   .{ .values = &.{ 1, 2 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .cons = &.{ .{ .nil = {} }, .{ .nil = {} } } }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 5, .value = 2 } }, .keys = &.{ 1, 2 }, .skips = &.{ false, false }, .consumed = 2 },
// v1 replay_node:
//   .{ .values = &.{ 1, 2 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .c = .{ .black = {} }, .kids = &.{ .{ .c = .{ .red = {} }, .kids = &.{} }, .{ .c = .{ .red = {} }, .kids = &.{} } } }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 5, .value = 2 } }, .keys = &.{ 1, 2 }, .skips = &.{ false, false }, .consumed = 2 },
// v1 replay_znode:
//   .{ .values = &.{ 1, 0, 5, 1 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .f = .{ .v = 5 }, .kids = &.{.{ .f = .{ .e = .{} }, .kids = &.{} }} }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 }, .{ .bound = 5, .value = 1 } }, .keys = &.{ 1, 5, 5, 1 }, .skips = &.{ false, false, true, false }, .consumed = 4 },
// v1 replay_tree2:
//   .{ .values = &.{ 1, 0, 65, 1, 0, 9, 1 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .name = &.{65}, .extra = 9, .kids = &.{.{ .name = &.{}, .extra = null, .kids = &.{} }} }, .choices = &.{ .{ .bound = 5, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 65 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 9 }, .{ .bound = 5, .value = 1 } }, .keys = &.{ 1, 65, 65, 1, 9, 9, 1 }, .skips = &.{ false, false, true, false, false, true, false }, .consumed = 7 },

const replay_json_depth0 = [_]ReplayPin(Json){
    // The cut pair value draws a tag among {int, str, list, obj}: .int
    .{ .values = &.{ 3, 1, 1, 0, 120, 0, 0, 5 }, .limits = .{ .max_depth = 0 }, .value = .{ .obj = &.{.{ .k = &.{120}, .v = .{ .int = -3 } }} }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 33, .value = 1 }, .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 120 }, .{ .bound = 4, .value = 0 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 } }, .keys = &.{ 3, 1, 1, 120, 120, 0, 5, 5 }, .skips = &.{ false, false, false, false, true, false, false, true }, .consumed = 8 },
    // ... and .str, generated normally (str does not reach Json)
    .{ .values = &.{ 3, 1, 1, 0, 120, 1, 2, 0, 65, 0, 66 }, .limits = .{ .max_depth = 0 }, .value = .{ .obj = &.{.{ .k = &.{120}, .v = .{ .str = &.{ 65, 66 } } }} }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 33, .value = 1 }, .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 120 }, .{ .bound = 4, .value = 1 }, .{ .bound = 33, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 65 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 66 } }, .keys = &.{ 3, 1, 1, 120, 120, 1, 2, 65, 65, 66, 66 }, .skips = &.{ false, false, false, false, true, false, false, false, true, false, true }, .consumed = 11 },
    // Cut list elements: .int and .obj (cut: empty, no length draw)
    .{ .values = &.{ 2, 2, 0, 0, 7, 3 }, .limits = .{ .max_depth = 0 }, .value = .{ .list = &.{ .{ .int = -4 }, .{ .obj = &.{} } } }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 33, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 7 }, .{ .bound = 4, .value = 3 } }, .keys = &.{ 2, 2, 0, 7, 7, 3 }, .skips = &.{ false, false, false, false, true, false }, .consumed = 6 },
    // A cut .list is empty with no length draw
    .{ .values = &.{ 2, 1, 2 }, .limits = .{ .max_depth = 0 }, .value = .{ .list = &.{.{ .list = &.{} }} }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 2, 1, 2 }, .skips = &.{ false, false, false }, .consumed = 3 },
};

const replay_list = [_]ReplayPin(List){
    // m = 2 at the cut: one tag draw per cut element (nil, cons = &.{})
    .{ .values = &.{ 1, 2, 0, 1 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .cons = &.{ .{ .nil = {} }, .{ .cons = &.{} } } }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 5, .value = 2 }, .{ .bound = 2, .value = 0 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 2, 0, 1 }, .skips = &.{ false, false, false, false }, .consumed = 4 },
};

const replay_node = [_]ReplayPin(Node){
    // Color does not reach Node: generated normally at the cut
    .{ .values = &.{ 1, 2, 0, 1 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .c = .{ .black = {} }, .kids = &.{ .{ .c = .{ .red = {} }, .kids = &.{} }, .{ .c = .{ .black = {} }, .kids = &.{} } } }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 5, .value = 2 }, .{ .bound = 2, .value = 0 }, .{ .bound = 2, .value = 1 } }, .keys = &.{ 1, 2, 0, 1 }, .skips = &.{ false, false, false, false }, .consumed = 4 },
};

const replay_znode = [_]ReplayPin(ZNode){
    // ZU does not reach ZNode: generated normally at the cut (.v, .e)
    .{ .values = &.{ 1, 0, 5, 1, 1, 0, 9 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .f = .{ .v = 5 }, .kids = &.{.{ .f = .{ .v = 9 }, .kids = &.{} }} }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 }, .{ .bound = 5, .value = 1 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 9 } }, .keys = &.{ 1, 5, 5, 1, 1, 9, 9 }, .skips = &.{ false, false, true, false, false, false, true }, .consumed = 7 },
    .{ .values = &.{ 1, 0, 5, 1, 0 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .f = .{ .v = 5 }, .kids = &.{.{ .f = .{ .e = .{} }, .kids = &.{} }} }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 }, .{ .bound = 5, .value = 1 }, .{ .bound = 2, .value = 0 } }, .keys = &.{ 1, 5, 5, 1, 0 }, .skips = &.{ false, false, true, false, false }, .consumed = 5 },
};

const replay_tree2 = [_]ReplayPin(Tree2){
    // The cut kid's name and extra are generated normally ("BC", 7);
    // only kids (which reaches Tree2) is cut
    .{ .values = &.{ 1, 0, 65, 1, 0, 9, 1, 2, 0, 66, 0, 67, 1, 0, 7 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .name = &.{65}, .extra = 9, .kids = &.{.{ .name = &.{ 66, 67 }, .extra = 7, .kids = &.{} }} }, .choices = &.{ .{ .bound = 5, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 65 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 9 }, .{ .bound = 5, .value = 1 }, .{ .bound = 5, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 66 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 67 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 7 } }, .keys = &.{ 1, 65, 65, 1, 9, 9, 1, 2, 66, 66, 67, 67, 1, 7, 7 }, .skips = &.{ false, false, true, false, false, true, false, false, false, true, false, true, false, false, true }, .consumed = 15 },
};

const random_tree = [_]RandomPin(Tree){
    .{ .seed = 12, .limits = .{ .max_len = 2, .max_depth = 2 }, .value = .{ .value = 411322336, .kids = &.{.{ .value = 0, .kids = &.{ .{ .value = 101, .kids = &.{ .{ .value = 111, .kids = &.{} }, .{ .value = -5329942774901833690, .kids = &.{} } } }, .{ .value = -76, .kids = &.{.{ .value = 60, .kids = &.{} }} } } }} }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 0, .value = 822644672 }, .{ .bound = 3, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 0 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 202 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 222 }, .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 10659885549803667379 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 151 }, .{ .bound = 3, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 120 } }, .keys = &.{ 822644672, 822644672, 1, 0, 0, 2, 202, 202, 2, 222, 222, 10659885549803667379, 10659885549803667379, 151, 151, 1, 120, 120 }, .skips = &.{ false, true, false, false, true, false, false, true, false, false, true, false, true, false, true, false, false, true } },
    .{ .seed = 32, .limits = .{ .max_len = 2, .max_depth = 0 }, .value = .{ .value = -1372428507354947170, .kids = &.{ .{ .value = 8893012934323066582, .kids = &.{} }, .{ .value = -7632470952706420841, .kids = &.{} } } }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 2744857014709894339 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 17786025868646133164 }, .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 15264941905412841681 } }, .keys = &.{ 2744857014709894339, 2744857014709894339, 2, 17786025868646133164, 17786025868646133164, 15264941905412841681, 15264941905412841681 }, .skips = &.{ false, true, false, false, true, false, true } },
};

const random_json = [_]RandomPin(Json){
    .{ .seed = 13, .limits = .{ .max_len = 2, .max_depth = 1 }, .value = .{ .int = 9223372036854775806 }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 3 } }, .keys = &.{ 0, 18446744073709551612, 3 }, .skips = &.{ false, false, true } },
    .{ .seed = 23, .limits = .{ .max_len = 2, .max_depth = 1 }, .value = .{ .obj = &.{ .{ .k = &.{}, .v = .{ .obj = &.{.{ .k = &.{}, .v = .{ .obj = &.{} } }} } }, .{ .k = &.{ 216, 1 }, .v = .{ .obj = &.{.{ .k = &.{255}, .v = .{ .list = &.{} } }} } } } }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 2 }, .{ .bound = 3, .value = 0 }, .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 1 }, .{ .bound = 3, .value = 0 }, .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 216 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 1 }, .{ .bound = 3, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 3 }, .{ .bound = 4, .value = 2 } }, .keys = &.{ 3, 2, 0, 3, 1, 0, 3, 2, 216, 216, 1, 1, 3, 1, 1, 255, 3, 2 }, .skips = &.{ false, false, false, false, false, false, false, false, false, true, false, true, false, false, false, false, true, false } },
    .{ .seed = 33, .limits = .{ .max_len = 2, .max_depth = 0 }, .value = .{ .int = -99 }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 197 } }, .keys = &.{ 0, 197, 197 }, .skips = &.{ false, false, true } },
    .{ .seed = 43, .limits = .{ .max_len = 2, .max_depth = 0 }, .value = .{ .obj = &.{ .{ .k = &.{ 0, 1 }, .v = .{ .str = &.{ 1, 32 } } }, .{ .k = &.{ 1, 91 }, .v = .{ .str = &.{2} } } } }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 2 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 0 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 32 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 91 }, .{ .bound = 4, .value = 1 }, .{ .bound = 3, .value = 1 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 2 } }, .keys = &.{ 3, 2, 2, 0, 0, 1, 1, 1, 2, 1, 1, 32, 32, 2, 1, 1, 91, 91, 1, 1, 2, 2 }, .skips = &.{ false, false, false, false, true, false, true, false, false, false, true, false, true, false, false, true, false, true, false, false, false, true } },
};

const random_list = [_]RandomPin(List){
    .{ .seed = 14, .limits = .{ .max_len = 3, .max_depth = 1 }, .value = .{ .nil = {} }, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false} },
    .{ .seed = 24, .limits = .{ .max_len = 3, .max_depth = 1 }, .value = .{ .nil = {} }, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false} },
    .{ .seed = 34, .limits = .{ .max_len = 3, .max_depth = 0 }, .value = .{ .nil = {} }, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false} },
};
