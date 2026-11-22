//! Allocation failure at every point (verification pipeline plan §2-4
//! (d)). Each case runs once without failures (the baseline), then once
//! per allocation index twice: with `std.testing.FailingAllocator` failing
//! that allocation and every later one, and with `OneFailure` failing it
//! alone. Every run must either return `error.OutOfMemory` or give the
//! baseline's result (`Outcome.eql`: variant, origin, choices, shrunk
//! choices, `Failure` by `Failure.eql`, evaluations, shrink outcome). Any
//! other result means an allocation failure was swallowed and turned into
//! a different outcome (a discard, `passed`, `gave_up`, a different
//! counterexample or error). `std.testing.allocator` reports leaks at the
//! end of each test.
//!
//! Injection surface: only `alloc` calls fail. `OneFailure` passes
//! `resize` and `remap` through to its child, and FailingAllocator's
//! `resize_fail_index` stays at its default `maxInt(usize)`, so a code
//! path taken only when a resize or remap fails is not exercised.
//!
//! `zig build test` runs four cases (`oom_options.full = false`);
//! `zig build oom-full` runs every case below.

const std = @import("std");
const zigprop = @import("zigprop");
const options = @import("oom_options");

const Tag = std.meta.Tag(zigprop.Report);

/// What a run produced, copied out of the Report into `std.testing.allocator`.
/// For a failure: where it came from (attempt or regression index), the
/// confirmed and the shrunk choices, the failure kind, and the shrink's
/// evaluation count and outcome. A swallowed allocation failure during
/// search moves the attempt; during shrinking it rejects a candidate and
/// changes the path, even when the shrunk minimum is the same.
const Outcome = struct {
    tag: Tag,
    origin: u64 = 0,
    from_regression: bool = false,
    original: []u64 = &.{},
    shrunk: []u64 = &.{},
    failure: ?zigprop.Failure = null,
    evaluations: usize = 0,
    outcome: ?zigprop.ShrinkOutcome = null,

    fn values(choices: []const zigprop.Choice) ![]u64 {
        const out = try std.testing.allocator.alloc(u64, choices.len);
        for (choices, out) |c, *v| v.* = c.value;
        return out;
    }

    fn of(report: zigprop.Report) !Outcome {
        return switch (report) {
            .failed => |f| blk: {
                const original = try values(f.choices);
                errdefer std.testing.allocator.free(original);
                break :blk .{
                    .tag = .failed,
                    .origin = switch (f.origin) {
                        .random => |r| r.attempt_index,
                        .regression => |r| r.index,
                    },
                    .from_regression = f.origin == .regression,
                    .original = original,
                    .shrunk = try values(f.shrunk_choices),
                    .failure = f.failure,
                    .evaluations = f.shrink_evaluations,
                    .outcome = f.shrink_outcome,
                };
            },
            else => .{ .tag = std.meta.activeTag(report) },
        };
    }

    fn deinit(o: Outcome) void {
        std.testing.allocator.free(o.original);
        std.testing.allocator.free(o.shrunk);
    }

    fn eql(a: Outcome, b: Outcome) bool {
        return a.tag == b.tag and a.origin == b.origin and a.from_regression == b.from_regression and
            std.mem.eql(u64, a.original, b.original) and std.mem.eql(u64, a.shrunk, b.shrunk) and
            sameFailure(a.failure, b.failure) and a.evaluations == b.evaluations and a.outcome == b.outcome;
    }

    fn sameFailure(a: ?zigprop.Failure, b: ?zigprop.Failure) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.eql(b.?);
    }
};

const Run = *const fn (std.mem.Allocator) anyerror!Outcome;

/// Fails exactly one allocation, the one at `fail_index`, and lets every
/// later one succeed. `std.testing.FailingAllocator` keeps failing after
/// its index, so a swallowed failure is always followed by one that
/// propagates and the swallow stays invisible; with one transient
/// failure, a swallowed one shows up as a different Report.
const OneFailure = struct {
    child: std.mem.Allocator,
    fail_index: usize,
    index: usize = 0,
    induced: bool = false,

    fn allocator(self: *OneFailure) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        defer self.index += 1;
        if (self.index == self.fail_index) {
            self.induced = true;
            return null;
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const Mode = enum { from_index_on, only_index };

/// Runs `run` once per allocation index in `mode`; returns how many
/// indices were covered.
fn sweep(name: []const u8, run: Run, baseline: Outcome, mode: Mode) !usize {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var sticky = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var one: OneFailure = .{ .child = std.testing.allocator, .fail_index = fail_index };
        const a = switch (mode) {
            .from_index_on => sticky.allocator(),
            .only_index => one.allocator(),
        };
        const induced = struct {
            fn f(m: Mode, s: *std.testing.FailingAllocator, o: *OneFailure) bool {
                return switch (m) {
                    .from_index_on => s.has_induced_failure,
                    .only_index => o.induced,
                };
            }
        }.f;
        const got = run(a) catch |err| {
            if (err == error.OutOfMemory and induced(mode, &sticky, &one)) continue;
            std.debug.print("{s} ({s}): allocation {d}: unexpected error {s}\n", .{ name, @tagName(mode), fail_index, @errorName(err) });
            return err;
        };
        defer got.deinit();
        if (!got.eql(baseline)) {
            std.debug.print("{s} ({s}): allocation failure {d} was swallowed: got {s} origin {d} shrunk {any} evals {d}, expected {s} origin {d} shrunk {any} evals {d}\n", .{ name, @tagName(mode), fail_index, @tagName(got.tag), got.origin, got.shrunk, got.evaluations, @tagName(baseline.tag), baseline.origin, baseline.shrunk, baseline.evaluations });
            return error.TestUnexpectedResult;
        }
        // Past the last allocation: every failure point was covered.
        if (!induced(mode, &sticky, &one)) return fail_index;
    }
}

fn expectOomSafe(name: []const u8, run: Run) !void {
    const baseline = try run(std.testing.allocator);
    defer baseline.deinit();
    const points = try sweep(name, run, baseline, .from_index_on);
    _ = try sweep(name, run, baseline, .only_index);
    // Path evidence: the baseline is a failure, so shrinking ran under
    // every failure point, and at least one allocation was failed.
    try std.testing.expectEqual(Tag.failed, baseline.tag);
    try std.testing.expect(points > 0);
}

// ---------------------------------------------------------------------
// Types and properties

const Tree = struct { value: u8, kids: []const Tree };
const tree_limits: zigprop.Limits = .{ .max_len = 3, .max_depth = 2 };

const Json = union(enum) {
    null,
    int: i16,
    list: []const Json,
};
const json_limits: zigprop.Limits = .{ .max_len = 3, .max_depth = 2 };

fn shortSlice(xs: []const u8) bool {
    return xs.len < 3;
}

fn leafOnly(t: Tree) bool {
    return t.kids.len == 0;
}

fn small(x: u32) bool {
    return x < 1000;
}

fn notList(j: Json) bool {
    return j != .list;
}

const Ctx = struct { limit: usize };

fn shortSliceWith(ctx: *const Ctx, _: *zigprop.Case, xs: []const u8) anyerror!bool {
    return xs.len < ctx.limit;
}

/// Fails with an error whose name depends on the first byte, so a
/// changed path can surface as a different error, not only as different
/// choices.
fn shortSliceOrErrorWith(ctx: *const Ctx, _: *zigprop.Case, xs: []const u8) anyerror!bool {
    if (xs.len < ctx.limit) return true;
    return if (xs[0] % 2 == 0) error.EvenHead else error.OddHead;
}

fn leafOnlyWith(_: *const Ctx, _: *zigprop.Case, t: Tree) anyerror!bool {
    return t.kids.len == 0;
}

/// Draws inside the property (design v0.4 §2): a slice, an index and a
/// choice, each logged in the draw log, which every failing evaluation
/// copies into the result allocator.
fn drawsInProperty(ctx: *const Ctx, case: *zigprop.Case, _: void) anyerror!bool {
    const xs = try case.generate([]const u8);
    const k = try case.index(4);
    var en: std.EnumSet(enum { a, b }) = .full;
    if (k == 0) en.remove(.b);
    _ = try case.choose(@TypeOf(en).Key, en);
    return xs.len < ctx.limit;
}

const ctx3: Ctx = .{ .limit = 3 };
const budget = 40;

// ---------------------------------------------------------------------
// Runs: one per entry point and path

fn runCheckSlice(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.check(a, []const u8, shortSlice, .{ .seed = 1, .max_cases = 20, .shrink_budget = budget });
    defer r.deinit();
    return Outcome.of(r);
}

fn runCheckWithTree(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.checkWith(a, Tree, *const Ctx, &ctx3, null, leafOnlyWith, .{ .seed = 1, .max_cases = 20, .shrink_budget = budget, .limits = tree_limits });
    defer r.deinit();
    return Outcome.of(r);
}

fn runCheckTree(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.check(a, Tree, leafOnly, .{ .seed = 2, .max_cases = 20, .shrink_budget = budget, .limits = tree_limits });
    defer r.deinit();
    return Outcome.of(r);
}

fn runCheckU32(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.check(a, u32, small, .{ .seed = 1, .max_cases = 20, .shrink_budget = budget });
    defer r.deinit();
    return Outcome.of(r);
}

fn runCheckJson(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.check(a, Json, notList, .{ .seed = 1, .max_cases = 20, .shrink_budget = budget, .limits = json_limits });
    defer r.deinit();
    return Outcome.of(r);
}

fn runCheckWithSlice(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.checkWith(a, []const u8, *const Ctx, &ctx3, null, shortSliceWith, .{ .seed = 3, .max_cases = 20, .shrink_budget = budget });
    defer r.deinit();
    return Outcome.of(r);
}

fn runCheckWithSliceError(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.checkWith(a, []const u8, *const Ctx, &ctx3, null, shortSliceOrErrorWith, .{ .seed = 3, .max_cases = 20, .shrink_budget = budget });
    defer r.deinit();
    if (r == .failed) try std.testing.expect(r.failed.failure == .returned_error);
    return Outcome.of(r);
}

fn runCheckWithDraws(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.checkWith(a, void, *const Ctx, &ctx3, null, drawsInProperty, .{ .seed = 3, .max_cases = 20, .shrink_budget = budget });
    defer r.deinit();
    return Outcome.of(r);
}

/// The OrError wrapper: only the error is observable, so the outcome
/// is the variant it maps to (`error.PropertyFailed` for a failure).
fn runCheckWithOrErrorTree(a: std.mem.Allocator) anyerror!Outcome {
    zigprop.checkWithOrError(a, Tree, *const Ctx, &ctx3, null, leafOnlyWith, .{ .seed = 1, .max_cases = 20, .shrink_budget = budget, .limits = tree_limits }) catch |err| {
        if (err == error.PropertyFailed) return .{ .tag = .failed };
        return err;
    };
    return .{ .tag = .passed };
}

/// The regression replay path: the entry fails, so shrinking starts
/// from it before any random case.
const slice_entry = [_]zigprop.Regression{.{ .id = "oom", .gen_version = zigprop.generator_version, .choices = &.{ 4, 0, 9, 0, 9, 0, 9, 0, 9 } }};

fn runRegressionSlice(a: std.mem.Allocator) anyerror!Outcome {
    var r = try zigprop.check(a, []const u8, shortSlice, .{ .max_cases = 5, .shrink_budget = budget, .regressions = &slice_entry, .regression_id = "oom" });
    defer r.deinit();
    if (r == .failed) try std.testing.expect(r.failed.origin == .regression);
    return Outcome.of(r);
}

// ---------------------------------------------------------------------

test "oom: check over []const u8 survives every allocation failure" {
    try expectOomSafe("check []const u8", runCheckSlice);
}

test "oom: checkWith over a recursive type survives every allocation failure" {
    try expectOomSafe("checkWith Tree", runCheckWithTree);
}

test "oom: a property error survives every allocation failure with the same error" {
    try expectOomSafe("checkWith []const u8 returning errors", runCheckWithSliceError);
}

test "oom: a property that draws survives every allocation failure" {
    try expectOomSafe("checkWith void drawing in the property", runCheckWithDraws);
}

test "oom: outcomes that differ only in the property's error are not equal" {
    const even: Outcome = .{ .tag = .failed, .failure = .{ .returned_error = error.EvenHead } };
    const odd: Outcome = .{ .tag = .failed, .failure = .{ .returned_error = error.OddHead } };
    const falsy: Outcome = .{ .tag = .failed, .failure = .returned_false };
    try std.testing.expect(even.eql(even));
    try std.testing.expect(!even.eql(odd));
    try std.testing.expect(!even.eql(falsy));
    try std.testing.expect(!even.eql(.{ .tag = .failed }));
}

test "oom (full): every entry point, the regression path and small max_depth recursive types" {
    if (!options.full) return error.SkipZigTest;
    try expectOomSafe("check Tree", runCheckTree);
    try expectOomSafe("check u32", runCheckU32);
    try expectOomSafe("check Json", runCheckJson);
    try expectOomSafe("checkWith []const u8", runCheckWithSlice);
    try expectOomSafe("checkWithOrError Tree", runCheckWithOrErrorTree);
    try expectOomSafe("check []const u8 regression replay", runRegressionSlice);
}
