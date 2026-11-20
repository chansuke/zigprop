//! Compile budget (verification pipeline plan §2-4 (b); review C1, fixed
//! in c007748). Each type below reaches itself along several routes, or
//! through several types, or through many variants. When the comptime
//! unfolding keyed instantiations by the path, such types did not finish
//! compiling in 240 s. `zig build compile-budget` compiles this file with
//! a fresh cache under a 120 s limit; finishing is the gate, the time is
//! only measured (bench/COMPILE_BASELINE.md).
//!
//! Uses only API that exists since v0.2.0 (`check`, `Config`, `Limits`),
//! so the same file compiles against the pre-C1 tree.

const std = @import("std");
const zigprop = @import("zigprop");

// meta8's multi-path types: two routes back to the root each.
const Json = union(enum) {
    int: i64,
    str: []const u8,
    list: []const Json,
    obj: []const Pair,
};
const Pair = struct { k: []const u8, v: Json };

const E = union(enum) {
    lit: i64,
    add: []const E,
    let: struct { name: []const u8, body: []const E },
};

const Bin = struct { v: i64, a: []const Bin, b: []const Bin };

// Three and four routes back to the root.
const Three = union(enum) {
    leaf: u8,
    a: []const Three,
    b: struct { x: []const Three },
    c: []const Wrap3,
};
const Wrap3 = struct { t: Three };

const Four = struct {
    v: u8,
    a: []const Four,
    b: []const Four,
    c: ?[]const Four,
    d: []const struct { f: Four },
};

// Four mutually recursive types, with a cross edge.
const MA = struct { v: u8, b: []const MB, d: []const MD };
const MB = struct { v: u8, c: []const MC };
const MC = struct { v: u8, d: []const MD, a: []const MA };
const MD = union(enum) { leaf: u8, a: []const MA, b: []const MB };

// A 16-variant union, every variant recursive.
const U16 = union(enum) {
    v0: []const U16,
    v1: []const U16,
    v2: []const U16,
    v3: []const U16,
    v4: []const U16,
    v5: []const U16,
    v6: []const U16,
    v7: []const U16,
    v8: []const U16,
    v9: []const U16,
    v10: []const U16,
    v11: []const U16,
    v12: []const U16,
    v13: []const U16,
    v14: []const U16,
    v15: struct { x: u8, kids: []const U16 },
};

fn alwaysTrue(comptime T: type) fn (T) bool {
    return struct {
        fn p(_: T) bool {
            return true;
        }
    }.p;
}

fn checkOnce(comptime T: type, max_depth: usize) !void {
    var report = try zigprop.check(std.testing.allocator, T, alwaysTrue(T), .{
        .seed = 0,
        .max_cases = 1,
        .limits = .{ .max_len = 2, .max_depth = max_depth },
    });
    defer report.deinit();
    try std.testing.expect(std.meta.activeTag(report) == .passed);
}

test "compile budget: multi-path, mutually recursive and wide recursive types" {
    inline for (.{ Json, E, Bin, Three, Four, MA, MB, MC, MD, U16 }) |T| try checkOnce(T, 3);
}

test "compile budget: recursive types at max_depth_cap" {
    inline for (.{ Json, Bin, MA }) |T| try checkOnce(T, zigprop.max_depth_cap);
}
