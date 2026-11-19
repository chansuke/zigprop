//! v0.3 M1: golden pins for the recursive-cut group (design v0.3 §7.4,
//! D35), recorded from v0.2.1 (generator_version 1).
//!
//! This file is kept apart from tests/meta10.zig on purpose: M7 (cut
//! scope, generator_version 2) changes what is generated at a cut, so
//! it rewrites the (R) pins here deliberately (keeping these v1 values
//! as comments) and re-records the (S) pins. Every other (R) pin must
//! survive M7 unchanged.
//!
//! (R) replay pins: values -> value, re-recorded choices (bounds
//! included), keys, skips, consumed count. (S) random pins: seed
//! (attempt 0) -> recording and value. Display strings are not pinned.
//!
//! All expected values are literals captured from a v0.2.1 run.

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
            break :blk zigprop.Source.initReplay(arena, buf, 100_000);
        },
        .seed => |seed| zigprop.Source.initRandom(arena, zigprop.deriveSeed(seed, 0), 100_000),
    };
    var ctx = zigprop.GenContext{ .src = &src, .allocator = arena, .limits = limits };
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
    // v1: every cut Json is .int (first variant with a cut form, no
    // tag draw); the pair key is generated normally.
    try checkReplay(Json, &replay_json_depth0);
}

test "golden rec (R): List, Node, ZNode and Tree2 cuts" {
    // v1: List's cut is .nil with no tag draw; Node's cut Color is
    // .red with no draw; ZNode's cut ZU is .e ([0]u8, no draw);
    // Tree2's cut kid has name = "" and extra = null (non-recursive
    // channels are cut too).
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

const replay_json_depth0 = [_]ReplayPin(Json){
    .{ .values = &.{ 3, 1, 1, 0, 120, 0, 5 }, .limits = .{ .max_depth = 0 }, .value = .{ .obj = &.{.{ .k = &.{120}, .v = .{ .int = -3 } }} }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 33, .value = 1 }, .{ .bound = 33, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 120 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 } }, .keys = &.{ 3, 1, 1, 120, 120, 5, 5 }, .skips = &.{ false, false, false, false, true, false, true }, .consumed = 7 },
    .{ .values = &.{ 2, 2, 0, 7, 0, 9 }, .limits = .{ .max_depth = 0 }, .value = .{ .list = &.{ .{ .int = -4 }, .{ .int = -5 } } }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 33, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 7 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 9 } }, .keys = &.{ 2, 2, 7, 7, 9, 9 }, .skips = &.{ false, false, false, true, false, true }, .consumed = 6 },
};

const replay_list = [_]ReplayPin(List){
    .{ .values = &.{ 1, 2 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .cons = &.{ .{ .nil = {} }, .{ .nil = {} } } }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 5, .value = 2 } }, .keys = &.{ 1, 2 }, .skips = &.{ false, false }, .consumed = 2 },
};

const replay_node = [_]ReplayPin(Node){
    .{ .values = &.{ 1, 2 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .c = .{ .black = {} }, .kids = &.{ .{ .c = .{ .red = {} }, .kids = &.{} }, .{ .c = .{ .red = {} }, .kids = &.{} } } }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 5, .value = 2 } }, .keys = &.{ 1, 2 }, .skips = &.{ false, false }, .consumed = 2 },
};

const replay_znode = [_]ReplayPin(ZNode){
    .{ .values = &.{ 1, 0, 5, 1 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .f = .{ .v = 5 }, .kids = &.{.{ .f = .{ .e = .{} }, .kids = &.{} }} }, .choices = &.{ .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 5 }, .{ .bound = 5, .value = 1 } }, .keys = &.{ 1, 5, 5, 1 }, .skips = &.{ false, false, true, false }, .consumed = 4 },
};

const replay_tree2 = [_]ReplayPin(Tree2){
    .{ .values = &.{ 1, 0, 65, 1, 0, 9, 1 }, .limits = .{ .max_len = 4, .max_depth = 0 }, .value = .{ .name = &.{65}, .extra = 9, .kids = &.{.{ .name = &.{}, .extra = null, .kids = &.{} }} }, .choices = &.{ .{ .bound = 5, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 65 }, .{ .bound = 2, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 9 }, .{ .bound = 5, .value = 1 } }, .keys = &.{ 1, 65, 65, 1, 9, 9, 1 }, .skips = &.{ false, false, true, false, false, true, false }, .consumed = 7 },
};

const random_tree = [_]RandomPin(Tree){
    .{ .seed = 12, .limits = .{ .max_len = 2, .max_depth = 2 }, .value = .{ .value = -15540, .kids = &.{.{ .value = 14719, .kids = &.{} }} }, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 31079 }, .{ .bound = 3, .value = 1 }, .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 29438 }, .{ .bound = 3, .value = 0 } }, .keys = &.{ 31079, 31079, 1, 29438, 29438, 0 }, .skips = &.{ false, true, false, false, true, false } },
    .{ .seed = 32, .limits = .{ .max_len = 2, .max_depth = 0 }, .value = .{ .value = -1372428507354947170, .kids = &.{ .{ .value = 8893012934323066582, .kids = &.{} }, .{ .value = -7632470952706420841, .kids = &.{} } } }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 2744857014709894339 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 17786025868646133164 }, .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 15264941905412841681 } }, .keys = &.{ 2744857014709894339, 2744857014709894339, 2, 17786025868646133164, 17786025868646133164, 15264941905412841681, 15264941905412841681 }, .skips = &.{ false, true, false, false, true, false, true } },
};

const random_json = [_]RandomPin(Json){
    .{ .seed = 13, .limits = .{ .max_len = 2, .max_depth = 1 }, .value = .{ .int = 9223372036854775806 }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 3 } }, .keys = &.{ 0, 18446744073709551612, 3 }, .skips = &.{ false, false, true } },
    .{ .seed = 23, .limits = .{ .max_len = 2, .max_depth = 1 }, .value = .{ .obj = &.{ .{ .k = &.{}, .v = .{ .obj = &.{.{ .k = &.{}, .v = .{ .int = 121 } }} } }, .{ .k = &.{ 216, 49 }, .v = .{ .int = 3859985773175310200 } } } }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 2 }, .{ .bound = 3, .value = 0 }, .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 242 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 216 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 49 }, .{ .bound = 4, .value = 0 }, .{ .bound = 4, .value = 3 }, .{ .bound = 0, .value = 7719971546350620400 } }, .keys = &.{ 3, 2, 0, 3, 1, 242, 242, 2, 216, 216, 49, 49, 0, 7719971546350620400, 7719971546350620400 }, .skips = &.{ false, false, false, false, false, false, true, false, false, true, false, true, false, false, true } },
    .{ .seed = 33, .limits = .{ .max_len = 2, .max_depth = 0 }, .value = .{ .int = -99 }, .choices = &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 197 } }, .keys = &.{ 0, 197, 197 }, .skips = &.{ false, false, true } },
    .{ .seed = 43, .limits = .{ .max_len = 2, .max_depth = 0 }, .value = .{ .obj = &.{ .{ .k = &.{ 10, 1 }, .v = .{ .int = 9223372036854775807 } }, .{ .k = &.{254}, .v = .{ .int = 568 } } } }, .choices = &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 3, .value = 2 }, .{ .bound = 3, .value = 2 }, .{ .bound = 4, .value = 2 }, .{ .bound = 256, .value = 10 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 7, .value = 5 }, .{ .bound = 3, .value = 1 }, .{ .bound = 4, .value = 1 }, .{ .bound = 4, .value = 2 }, .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 1136 } }, .keys = &.{ 3, 2, 2, 10, 10, 1, 1, 18446744073709551614, 5, 1, 254, 2, 1136, 1136 }, .skips = &.{ false, false, false, false, true, false, true, false, true, false, false, true, false, true } },
};

const random_list = [_]RandomPin(List){
    .{ .seed = 14, .limits = .{ .max_len = 3, .max_depth = 1 }, .value = .{ .nil = {} }, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false} },
    .{ .seed = 24, .limits = .{ .max_len = 3, .max_depth = 1 }, .value = .{ .nil = {} }, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false} },
    .{ .seed = 34, .limits = .{ .max_len = 3, .max_depth = 0 }, .value = .{ .nil = {} }, .choices = &.{.{ .bound = 2, .value = 0 }}, .keys = &.{0}, .skips = &.{false} },
};
