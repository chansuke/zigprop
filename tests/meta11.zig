//! v0.3 M5: structural fingerprints and stale regression detection
//! (design v0.3 §4, D23-D25). The golden hashes below pin the hash
//! definition itself: changing it makes every recorded entry stale.

const std = @import("std");
const zigprop = @import("zigprop");
const fp = zigprop.internal.fingerprint;
const GenContext = zigprop.GenContext;

const Tree = struct { value: i64, kids: []const Tree };
const Json = union(enum) { int: i64, str: []const u8, list: []const Json, obj: []const Pair };
const Pair = struct { k: []const u8, v: Json };
const Value = union(enum) { int: i64, str: []const u8, list: []const Value };
const Color = enum(u8) { red = 1, green = 2, blue = 4 };
const Point = struct { comptime tag: u8 = 3, x: u32, y: bool };

// ---------------------------------------------------------------------
// The structural hash (§4.3)
// ---------------------------------------------------------------------

test "fingerprint: golden hashes" {
    const Golden = struct { hash: u64, ser: []const u8 };
    const cases = .{
        .{ u32, Golden{ .hash = 0x4d40aac905fa7c87, .ser = "iu32;" } },
        .{ i64, Golden{ .hash = 0x2b0077fbad2ab544, .ser = "is64;" } },
        .{ f32, Golden{ .hash = 0x9ff6997a0baae6cd, .ser = "f32;" } },
        .{ bool, Golden{ .hash = 0x08a60d07b54d8f7a, .ser = "b;" } },
        .{ []const u8, Golden{ .hash = 0x41b9f44ed9a69bc5, .ser = "siu8;" } },
        .{ ?u16, Golden{ .hash = 0x55b225c2a76feafc, .ser = "oiu16;" } },
        .{ [3]u8, Golden{ .hash = 0xa371af6fa5208606, .ser = "a3iu8;" } },
        .{ Color, Golden{ .hash = 0xa9739b7b1b9f0ce3, .ser = "e3:1,2,4,;" } },
        .{ Point, Golden{ .hash = 0x4258487f7253dfa2, .ser = "S2:iu32;b;;" } },
        .{ Tree, Golden{ .hash = 0x5bca9f5bb949368a, .ser = "S2:is64;sr0;;" } },
        .{ Json, Golden{ .hash = 0x83aecab483b056f0, .ser = "Ut4:is64;siu8;sr0;sS2:siu8;r0;;;" } },
        .{ Value, Golden{ .hash = 0xf95d45be7869c2bb, .ser = "Ut3:is64;siu8;sr0;;" } },
    };
    inline for (cases) |c| {
        try std.testing.expectEqualStrings(c[1].ser, fp.serialization(c[0]));
        try std.testing.expectEqual(c[1].hash, fp.typeHash(c[0]));
    }
}

const TreeRenamed = struct { value: i64, kids: []const TreeRenamed };
const TreeFieldsRenamed = struct { val: i64, children: []const TreeFieldsRenamed };
const TreeReordered = struct { kids: []const TreeReordered, value: i64 };
const TreeWider = struct { value: i128, kids: []const TreeWider };
const TreeNarrower = struct { value: i32, kids: []const TreeNarrower };
const ValueMore = union(enum) { int: i64, str: []const u8, list: []const ValueMore, flag: bool };
const ValueSwapped = union(enum) { str: []const u8, int: i64, list: []const ValueSwapped };
const ColorRevalued = enum(u8) { red = 1, green = 2, blue = 8 };
const PointOtherComptime = struct { comptime tag: u8 = 9, x: u32, y: bool };

test "fingerprint: renames do not change the hash, shape changes do" {
    // Invariant: type rename, field rename, comptime field values.
    try std.testing.expectEqual(fp.typeHash(Tree), fp.typeHash(TreeRenamed));
    try std.testing.expectEqual(fp.typeHash(Tree), fp.typeHash(TreeFieldsRenamed));
    try std.testing.expectEqual(fp.typeHash(Point), fp.typeHash(PointOtherComptime));
    // Sensitive: field order, integer width, added or swapped
    // variants, enum values.
    try std.testing.expect(fp.typeHash(Tree) != fp.typeHash(TreeReordered));
    try std.testing.expect(fp.typeHash(Tree) != fp.typeHash(TreeNarrower));
    try std.testing.expect(fp.typeHash(u32) != fp.typeHash(u64));
    try std.testing.expect(fp.typeHash(Value) != fp.typeHash(ValueMore));
    try std.testing.expect(fp.typeHash(Value) != fp.typeHash(ValueSwapped));
    try std.testing.expect(fp.typeHash(Color) != fp.typeHash(ColorRevalued));
    _ = TreeWider; // i128 is not generated; the hash would still differ.
}

// ---------------------------------------------------------------------
// Relevant limits (§4.2)
// ---------------------------------------------------------------------

const Flat = struct { a: u8, b: ?i16, c: [2]bool };

test "fingerprint: max_len and max_depth are kept only when they can matter" {
    const l1: zigprop.Limits = .{ .max_len = 32, .max_depth = 8 };
    const l2: zigprop.Limits = .{ .max_len = 5, .max_depth = 2 };
    // No slice, not recursive: both normalized to 0.
    try std.testing.expectEqualDeep(fp.of(u32, l1, false), fp.of(u32, l2, false));
    try std.testing.expectEqualDeep(fp.of(Flat, l1, false), fp.of(Flat, l2, false));
    try std.testing.expectEqual(@as(u64, 0), fp.of(Flat, l1, false).max_len);
    // A slice: max_len kept, max_depth normalized.
    const s = fp.of([]const u8, l1, false);
    try std.testing.expectEqual(@as(u64, 32), s.max_len);
    try std.testing.expectEqual(@as(u8, 0), s.max_depth);
    try std.testing.expect(!std.meta.eql(s, fp.of([]const u8, l2, false)));
    // Recursive (through a slice): both kept.
    const t = fp.of(Tree, l1, false);
    try std.testing.expectEqual(@as(u64, 32), t.max_len);
    try std.testing.expectEqual(@as(u8, 8), t.max_depth);
    // A custom generator keeps both, whatever the type.
    const c = fp.of(u32, l2, true);
    try std.testing.expectEqual(@as(u64, 5), c.max_len);
    try std.testing.expectEqual(@as(u8, 2), c.max_depth);
    try std.testing.expect(c.custom_generator);
}

test "fingerprint: reachability predicates" {
    try std.testing.expect(fp.reachesSlice([]const u8));
    try std.testing.expect(fp.reachesSlice(?[]const u8));
    try std.testing.expect(fp.reachesSlice(Pair));
    try std.testing.expect(!fp.reachesSlice(Flat));
    try std.testing.expect(!fp.reachesSlice([0][]const u8)); // [0]X has no edge
    try std.testing.expect(fp.isRecursive(Tree));
    try std.testing.expect(fp.isRecursive(Json));
    try std.testing.expect(fp.isRecursive(Pair)); // Pair -> Json -> Pair
    try std.testing.expect(fp.isRecursive(struct { t: Tree }));
    try std.testing.expect(!fp.isRecursive(Flat));
    try std.testing.expect(!fp.isRecursive([]const []const u8));
    try std.testing.expect(fp.reaches(Pair, Json));
    try std.testing.expect(!fp.reaches(Flat, Flat));
}

// ---------------------------------------------------------------------
// The stale decision table (§4.5)
// ---------------------------------------------------------------------

fn singleDraw(ctx: *GenContext) anyerror!u32 {
    return @intCast(ctx.range(1 << 32));
}

fn smallOnly(x: u32) bool {
    return x < 10;
}

fn alwaysTrue(_: u32) bool {
    return true;
}

/// The fingerprint a checkCustom(u32, singleDraw) run records.
fn customFp() zigprop.Fingerprint {
    return fp.of(u32, .{}, true);
}

test "stale: unconsumed suffix is not counted as passed" {
    const entries = [_]zigprop.Regression{.{ .id = "s", .gen_version = zigprop.generator_version, .fingerprint = customFp(), .choices = &.{ 5, 99 } }};
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "s", .max_cases = 1 });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.passed.regressions.passed);
    try std.testing.expectEqual(@as(usize, 1), r.passed.regressions.stale.len);
    try std.testing.expectEqual(zigprop.StaleReason.unconsumed_suffix, r.passed.regressions.stale[0].reason);
}

test "stale: a failing replay with a suffix is still reported as a failure" {
    const entries = [_]zigprop.Regression{.{ .id = "s", .gen_version = zigprop.generator_version, .fingerprint = customFp(), .choices = &.{ 25, 99 } }};
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{ .regressions = &entries, .regression_id = "s" });
    defer r.deinit();
    try std.testing.expect(r == .failed);
    try std.testing.expectEqual(@as(usize, 0), r.failed.origin.regression.index);
    try std.testing.expectEqual(@as(?zigprop.StaleReason, .unconsumed_suffix), r.failed.origin.regression.stale);
    try std.testing.expectEqual(@as(u64, 10), r.failed.shrunk_choices[0].value);
}

test "stale: a fingerprint mismatch is not replayed and names the fields" {
    var other = customFp();
    other.max_len = 7;
    other.type_hash ^= 1;
    // The entry would fail if replayed (25 >= 10): it must not be.
    const entries = [_]zigprop.Regression{.{ .id = "f", .gen_version = zigprop.generator_version, .fingerprint = other, .choices = &.{25} }};
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "f", .max_cases = 1 });
    defer r.deinit();
    const s = r.passed.regressions.stale;
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqual(zigprop.StaleReason.fingerprint_mismatch, s[0].reason);
    try std.testing.expect(s[0].mismatch.type_hash and s[0].mismatch.max_len);
    try std.testing.expect(!s[0].mismatch.max_depth and !s[0].mismatch.custom_generator);

    var r2 = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{ .regressions = &entries, .regression_id = "f", .seed = 4 });
    defer r2.deinit();
    // The failure comes from random search, not from the stale entry.
    try std.testing.expect(r2.failed.origin == .random);
}

test "stale: built-in vs custom generation is a fingerprint difference" {
    const entries = [_]zigprop.Regression{.{ .id = "g", .gen_version = zigprop.generator_version, .fingerprint = customFp(), .choices = &.{ 0, 5 } }};
    var r = try zigprop.check(std.testing.allocator, u32, alwaysTrue, .{ .regressions = &entries, .regression_id = "g", .max_cases = 1 });
    defer r.deinit();
    const s = r.passed.regressions.stale;
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expect(s[0].mismatch.custom_generator);
}

test "stale: an entry without a fingerprint passes as unverified" {
    const entries = [_]zigprop.Regression{
        .{ .id = "u", .gen_version = zigprop.generator_version, .choices = &.{5} },
        .{ .id = "u", .gen_version = zigprop.generator_version, .fingerprint = customFp(), .choices = &.{6} },
    };
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "u", .max_cases = 1 });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.passed.regressions.passed);
    try std.testing.expectEqual(@as(usize, 1), r.passed.regressions.unverified);
    try std.testing.expectEqual(@as(usize, 0), r.passed.regressions.stale.len);
}

fn discardAll(_: *GenContext) anyerror!u32 {
    return error.InvalidGeneration;
}

test "stale: a discarded or exhausted replay is stale" {
    // Exhaustion: a built-in u32 needs two values, the entry has one.
    const short = [_]zigprop.Regression{.{ .id = "x", .gen_version = zigprop.generator_version, .choices = &.{0} }};
    var r = try zigprop.check(std.testing.allocator, u32, alwaysTrue, .{ .regressions = &short, .regression_id = "x", .max_cases = 1 });
    defer r.deinit();
    try std.testing.expectEqual(zigprop.StaleReason.discarded, r.passed.regressions.stale[0].reason);
    try std.testing.expectEqual(@as(usize, 0), r.passed.regressions.passed);
}

test "stale: a gen_version mismatch is not replayed" {
    const entries = [_]zigprop.Regression{.{ .id = "v", .gen_version = zigprop.generator_version + 1, .choices = &.{25} }};
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "v", .max_cases = 1 });
    defer r.deinit();
    try std.testing.expectEqual(zigprop.StaleReason.gen_version_mismatch, r.passed.regressions.stale[0].reason);
}

test "stale: fail_on_stale is honored by the OrError wrappers only" {
    const entries = [_]zigprop.Regression{.{ .id = "v", .gen_version = zigprop.generator_version + 1, .choices = &.{25} }};
    // Default (Q2): reported and printed, not an error.
    try zigprop.checkCustomOrError(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "v", .max_cases = 1 });
    // Opted in: error.StaleRegression.
    try std.testing.expectError(error.StaleRegression, zigprop.checkCustomOrError(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "v", .max_cases = 1, .fail_on_stale = true }));
    // A property failure takes precedence.
    try std.testing.expectError(error.PropertyFailed, zigprop.checkCustomOrError(std.testing.allocator, u32, singleDraw, smallOnly, .{ .regressions = &entries, .regression_id = "v", .fail_on_stale = true }));
    // The core never fails on stale: check returns a report.
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "v", .max_cases = 1, .fail_on_stale = true });
    defer r.deinit();
    try std.testing.expect(r == .passed);
}

fn genShifted(ctx: *GenContext) anyerror!u32 {
    // The same draw shape as singleDraw with a different mapping.
    return @as(u32, @intCast(ctx.range(1 << 32))) ^ 0x5555;
}

test "stale: KNOWN MISS — a custom generator's mapping change is not detected" {
    // Design v0.3 §4.3 / T8 (j): the fingerprint covers the type, the
    // limits and the generator kind, not the generator's code. An
    // entry recorded with singleDraw replays under genShifted without
    // being stale. This pins the limitation; it is documented.
    const entries = [_]zigprop.Regression{.{ .id = "k", .gen_version = zigprop.generator_version, .fingerprint = customFp(), .choices = &.{25} }};
    var r = try zigprop.checkCustom(std.testing.allocator, u32, genShifted, alwaysTrue, .{ .regressions = &entries, .regression_id = "k", .max_cases = 1 });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.passed.regressions.stale.len);
    try std.testing.expectEqual(@as(usize, 1), r.passed.regressions.passed);
}

// ---------------------------------------------------------------------
// ZON (§4.4)
// ---------------------------------------------------------------------

test "zon: a version-1 file without fingerprints imports" {
    const file: zigprop.RegressionFile = @import("meta11_v1.zon");
    try std.testing.expectEqual(@as(u32, 1), file.version);
    try std.testing.expectEqual(@as(usize, 3), file.entries.len);
    try std.testing.expectEqual(@as(?zigprop.Fingerprint, null), file.entries[0].fingerprint);
    try std.testing.expectEqual(@as(?zigprop.Fingerprint, null), file.entries[1].fingerprint);
    // A mixed file: the third entry carries a fingerprint.
    try std.testing.expectEqual(@as(u64, 0x4d40aac905fa7c87), file.entries[2].fingerprint.?.type_hash);
    // The entries were recorded with generator_version 1: since v0.3 M7
    // (generator_version 2) they are stale as gen_version_mismatch and
    // are not replayed (design v0.3 §7.3). Before M7 the same file
    // replayed as 3 passed, 2 of them unverified.
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = file.entries, .regression_id = "v1", .max_cases = 1 });
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.passed.regressions.passed);
    try std.testing.expectEqual(@as(usize, 3), r.passed.regressions.stale.len);
    for (r.passed.regressions.stale) |s| try std.testing.expectEqual(zigprop.StaleReason.gen_version_mismatch, s.reason);
}

test "stale: a v1-recorded entry is stale under generator_version 2" {
    // Design v0.3 §7.3, D34: no best-effort replay, no migration. The
    // entry would fail if replayed (25 >= 10); it must not be.
    try std.testing.expectEqual(@as(u32, 2), zigprop.generator_version);
    const entries = [_]zigprop.Regression{.{ .id = "old", .gen_version = 1, .fingerprint = customFp(), .choices = &.{25} }};
    var r = try zigprop.checkCustom(std.testing.allocator, u32, singleDraw, smallOnly, .{ .regressions = &entries, .regression_id = "old", .seed = 4 });
    defer r.deinit();
    try std.testing.expect(r.failed.origin == .random);
    try std.testing.expectEqual(@as(usize, 1), r.failed.regressions.stale.len);
    try std.testing.expectEqual(zigprop.StaleReason.gen_version_mismatch, r.failed.regressions.stale[0].reason);
    // With fail_on_stale the wrapper reports it as an error once the
    // property passes.
    try std.testing.expectError(error.StaleRegression, zigprop.checkCustomOrError(std.testing.allocator, u32, singleDraw, alwaysTrue, .{ .regressions = &entries, .regression_id = "old", .max_cases = 1, .fail_on_stale = true }));
}

test "zon: tests/regressions.zon imports as a RegressionFile" {
    const file: zigprop.RegressionFile = @import("regressions.zon");
    try std.testing.expectEqual(@as(u32, 1), file.version);
}
