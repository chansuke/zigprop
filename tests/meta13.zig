//! v0.4: draws inside the property (design v0.4 §2, D39-D45).
//!
//! The tests drive the public entry points. A regression entry fixes
//! the exact choice sequence a property sees (T = void draws nothing
//! itself, D49), so each test states which choices the property's own
//! draws consumed and how the attempt was classified.

const std = @import("std");
const zigprop = @import("zigprop");
const Choice = zigprop.Choice;

const testing = std.testing;

fn summaryOf(r: zigprop.Report) zigprop.RegressionSummary {
    return switch (r) {
        .passed => |p| p.regressions,
        .gave_up => |g| g.regressions,
        .failed => |f| f.regressions,
    };
}

/// Runs `property` with one regression entry holding `values`, then
/// `max_cases` random cases. The entry has no fingerprint, so a replay
/// that passes is counted as `unverified`.
fn withEntry(comptime Ctx: type, ctx: Ctx, property: zigprop.PropertyWith(Ctx, void), values: []const u64, config: zigprop.Config) !zigprop.Report {
    const entries = [_]zigprop.Regression{.{ .id = "m13", .gen_version = zigprop.generator_version, .choices = values }};
    var cfg = config;
    cfg.regressions = &entries;
    cfg.regression_id = "m13";
    return zigprop.checkWith(testing.allocator, void, Ctx, ctx, null, property, cfg);
}

fn expectStale(r: zigprop.Report, reason: zigprop.StaleReason) !void {
    const s = summaryOf(r);
    try testing.expectEqual(@as(usize, 1), s.stale.len);
    try testing.expectEqual(reason, s.stale[0].reason);
}

// ---------------------------------------------------------------------
// Recording (D39, D40, D43)
// ---------------------------------------------------------------------

const Seen = struct { x: u8 = 0, calls: usize = 0 };

fn propDrawU8Fails200(seen: *Seen, case: *zigprop.Case, _: void) anyerror!bool {
    seen.calls += 1;
    seen.x = try case.generate(u8);
    return seen.x != 200;
}

test "case: draws record into the attempt's Source" {
    // u8 is a pair: class (bound 4) then value (bound 256), keyed by the
    // value. The entry {0, 200} is class 0 with value 200.
    var seen: Seen = .{};
    var r = try withEntry(*Seen, &seen, propDrawU8Fails200, &.{ 0, 200 }, .{ .max_cases = 1 });
    defer r.deinit();
    try testing.expect(r == .failed);
    const f = r.failed;
    try testing.expect(f.origin == .regression);
    try testing.expect(f.failure.eql(.returned_false));
    // The property's draws are the failure's whole consumed sequence.
    try testing.expectEqualSlices(Choice, &.{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 200 } }, f.choices);
    // They shrink with it: the smallest failing value is still 200, and
    // the shrinker moves the pair to the full-domain class (P4).
    try testing.expectEqualSlices(Choice, &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 200 } }, f.shrunk_choices);
}

// ---------------------------------------------------------------------
// Post-property checks (D41)
// ---------------------------------------------------------------------

fn propDrawU8AlwaysFalse(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = try case.generate(u8);
    return false;
}

test "case: a regression replay that runs past the end is stale discarded, not a verdict" {
    // One choice only: the u8's value draw exhausts the entry. The
    // property returns false regardless, but the exhausted replay is a
    // discard (stale `discarded`), never a failure from the entry.
    var r = try withEntry(void, {}, propDrawU8AlwaysFalse, &.{0}, .{ .max_cases = 1 });
    defer r.deinit();
    try expectStale(r, .discarded);
    // The random phase still finds the (always failing) property.
    try testing.expect(r == .failed);
    try testing.expect(r.failed.origin == .random);
}

fn propDrawFourU8False(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    for (0..4) |_| _ = try case.generate(u8);
    return false;
}

test "case: exceeding max_draws inside the property is a discard" {
    // Four u8 pairs are 8 draws, over max_draws = 3: every attempt is a
    // discard although the property returns false.
    var r = try zigprop.checkWith(testing.allocator, void, void, {}, null, propDrawFourU8False, .{
        .max_cases = 5,
        .max_discards = 4,
        .limits = .{ .max_draws = 3 },
    });
    defer r.deinit();
    try testing.expect(r == .gave_up);
    try testing.expectEqual(@as(usize, 0), r.gave_up.cases);
    try testing.expectEqual(@as(usize, 5), r.gave_up.discards);
}

fn propDrawArray(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = try case.generate([]const []const u8);
    _ = try case.generate([2048]u8);
    return true;
}

fn propNoDraw(_: void, _: *zigprop.Case, _: void) anyerror!bool {
    return true;
}

/// Fails exactly one allocation (the `fail_at`-th) and lets every other
/// one through. std's FailingAllocator fails every allocation from its
/// index on, so the report's own copies would fail too and hide an OOM
/// that the property path swallowed.
const FailOnce = struct {
    child: std.mem.Allocator,
    fail_at: usize,
    count: usize = 0,

    fn allocator(self: *FailOnce) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        defer self.count += 1;
        if (self.count == self.fail_at) return null;
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

fn allocationsOf(property: zigprop.PropertyWith(void, void)) !usize {
    var counter: FailOnce = .{ .child = testing.allocator, .fail_at = std.math.maxInt(usize) };
    var r = try zigprop.checkWith(counter.allocator(), void, void, {}, null, property, .{ .max_cases = 1 });
    r.deinit();
    return counter.count;
}

test "case: out of memory while drawing in the property is an error, never a failure" {
    // Count the allocations of one passing case, then fail each one
    // alone. A recording failure or an arena OOM inside case.generate is
    // an infrastructure error (D41, D42): check returns
    // error.OutOfMemory and never reports `failed`.
    const total = try allocationsOf(propDrawArray);
    // The property's own draws reach the backing allocator, so some of
    // the failure points below are inside them.
    try testing.expect(total > try allocationsOf(propNoDraw));
    var errors: usize = 0;
    for (0..total) |i| {
        var failing: FailOnce = .{ .child = testing.allocator, .fail_at = i };
        if (zigprop.checkWith(failing.allocator(), void, void, {}, null, propDrawArray, .{ .max_cases = 1 })) |r| {
            var rr = r;
            defer rr.deinit();
            try testing.expect(rr != .failed);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            errors += 1;
        }
    }
    try testing.expectEqual(total, errors);
}

/// Fails the first allocation of at least `min_len` bytes only.
const FailFirstBig = struct {
    child: std.mem.Allocator,
    min_len: usize,
    failed: bool = false,

    fn allocator(self: *FailFirstBig) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FailFirstBig = @ptrCast(@alignCast(ctx));
        if (!self.failed and len >= self.min_len) {
            self.failed = true;
            return null;
        }
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FailFirstBig = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

fn propDrawBigSlice(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = try case.generate([]const ?[1024]u64);
    return true;
}

test "case: an arena OOM inside case.generate is an infrastructure error, not a returned_error failure" {
    // With max_len = 1, the first case whose slice has length 1 asks for
    // a buffer over 8 KiB (one null element draws twice): the run's
    // first allocation that large, and it fails. The generation returns
    // error.OutOfMemory into the property; D42 makes it the sticky
    // error, so check propagates it instead of reporting the
    // property's `try` as a returned_error failure.
    var failing: FailFirstBig = .{ .child = testing.allocator, .min_len = 8 * 1024 };
    const result = zigprop.checkWith(failing.allocator(), void, void, {}, null, propDrawBigSlice, .{
        .max_cases = 200,
        .limits = .{ .max_len = 1 },
    });
    try testing.expect(failing.failed);
    try testing.expectError(error.OutOfMemory, result);
}

fn propDrawThenError(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = try case.generate(bool);
    return error.Boom;
}

test "case: the post-property checks outrank the verdict" {
    // The empty entry is exhausted at the property's first draw (which
    // returns 0 without an error); the property then returns an error.
    // The check runs first, so the replay is a discard, not a
    // returned_error failure from the entry.
    var r = try withEntry(void, {}, propDrawThenError, &.{}, .{ .max_cases = 1 });
    defer r.deinit();
    try expectStale(r, .discarded);
    try testing.expect(r == .failed and r.failed.origin == .random);
}

// ---------------------------------------------------------------------
// Discard versus failure (D42)
// ---------------------------------------------------------------------

fn propBudgetOverflowSwallowed(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = case.generate([8]u8) catch return false;
    return true;
}

fn propOwnInvalidGeneration(_: void, _: *zigprop.Case, _: void) anyerror!bool {
    return error.InvalidGeneration;
}

test "case: an element-budget overflow inside the property is a discard, a property's own InvalidGeneration is a failure" {
    // max_total_elements = 4 < 8 elements: the generation stops with the
    // flag set, so the false that follows is not a verdict.
    var r = try zigprop.checkWith(testing.allocator, void, void, {}, null, propBudgetOverflowSwallowed, .{
        .max_cases = 3,
        .max_discards = 2,
        .limits = .{ .max_total_elements = 4 },
    });
    defer r.deinit();
    try testing.expect(r == .gave_up);
    try testing.expectEqual(@as(usize, 3), r.gave_up.discards);

    // The same error name, returned by the property itself, sets no flag:
    // it is a failure like any other error (D27).
    var r2 = try zigprop.checkWith(testing.allocator, void, void, {}, null, propOwnInvalidGeneration, .{ .max_cases = 3 });
    defer r2.deinit();
    try testing.expect(r2 == .failed);
    try testing.expect(r2.failed.failure.eql(.{ .returned_error = error.InvalidGeneration }));
}

// ---------------------------------------------------------------------
// Dynamic bounds (D44)
// ---------------------------------------------------------------------

const Op = enum { a, b, c };
/// Declaration order x, y, z; value order z, y, x.
const Rev = enum(u8) { x = 9, y = 3, z = 0 };

/// The pick of the first evaluation only: the regression replay. Shrink
/// evaluations that follow do not overwrite it.
const Picked = struct { op: ?Op = null, rev: ?Rev = null };

fn propChooseAC(p: *Picked, case: *zigprop.Case, _: void) anyerror!bool {
    var en: std.EnumSet(Op) = .empty;
    en.insert(.a);
    en.insert(.c);
    const op = try case.choose(Op, en);
    if (p.op == null) p.op = op;
    return false;
}

fn propChooseOnlyB(p: *Picked, case: *zigprop.Case, _: void) anyerror!bool {
    var en: std.EnumSet(Op) = .empty;
    en.insert(.b);
    const op = try case.choose(Op, en);
    if (p.op == null) p.op = op;
    return false;
}

fn propChooseRevXZ(p: *Picked, case: *zigprop.Case, _: void) anyerror!bool {
    var en: std.EnumSet(Rev) = .empty;
    en.insert(.z);
    en.insert(.x);
    const rev = try case.choose(Rev, en);
    if (p.rev == null) p.rev = rev;
    return false;
}

fn propChooseEmpty(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = try case.choose(Op, .empty);
    return false;
}

fn propIndex5(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = try case.index(5);
    return false;
}

fn propIndex0(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    _ = try case.index(0);
    return false;
}

test "choose: always one draw, bound = enabled count; empty set discards" {
    {
        // {a, c}: bound 2; value 1 is the second enabled tag, c.
        var p: Picked = .{};
        var r = try withEntry(*Picked, &p, propChooseAC, &.{1}, .{ .max_cases = 1 });
        defer r.deinit();
        try testing.expect(r == .failed and r.failed.origin == .regression);
        try testing.expectEqualSlices(Choice, &.{.{ .bound = 2, .value = 1 }}, r.failed.choices);
        try testing.expectEqual(Op.c, p.op.?);
    }
    {
        // A single enabled tag still draws once (bound 1, value 0); the
        // stored 7 normalizes to 0.
        var p: Picked = .{};
        var r = try withEntry(*Picked, &p, propChooseOnlyB, &.{7}, .{ .max_cases = 1 });
        defer r.deinit();
        try testing.expect(r == .failed and r.failed.origin == .regression);
        try testing.expectEqualSlices(Choice, &.{.{ .bound = 1, .value = 0 }}, r.failed.choices);
        try testing.expectEqual(Op.b, p.op.?);
    }
    {
        // Declaration order, not value order: {x, z} with index 0 is x.
        var p: Picked = .{};
        var r = try withEntry(*Picked, &p, propChooseRevXZ, &.{0}, .{ .max_cases = 1 });
        defer r.deinit();
        try testing.expect(r == .failed and r.failed.origin == .regression);
        try testing.expectEqualSlices(Choice, &.{.{ .bound = 2, .value = 0 }}, r.failed.choices);
        try testing.expectEqual(Rev.x, p.rev.?);
        var p1: Picked = .{};
        var r1 = try withEntry(*Picked, &p1, propChooseRevXZ, &.{1}, .{ .max_cases = 1 });
        defer r1.deinit();
        try testing.expectEqualSlices(Choice, &.{.{ .bound = 2, .value = 1 }}, r1.failed.choices);
        try testing.expectEqual(Rev.z, p1.rev.?);
        // The premise that makes this discriminate: EnumSet iterates by
        // value, so an iterator-based choose would pick z for index 0.
        var it = (std.EnumSet(Rev).initMany(&.{ .x, .z })).iterator();
        try testing.expectEqual(Rev.z, it.next().?);
    }
    {
        // The empty set has nothing to choose: a discard, not an error.
        var r = try withEntry(void, {}, propChooseEmpty, &.{0}, .{ .max_cases = 1, .max_discards = 2 });
        defer r.deinit();
        try expectStale(r, .discarded);
        try testing.expect(r == .gave_up);
    }
}

test "index: one draw keyed by its value; index(0) discards" {
    {
        var r = try withEntry(void, {}, propIndex5, &.{8}, .{ .max_cases = 1 });
        defer r.deinit();
        try testing.expect(r == .failed and r.failed.origin == .regression);
        // 8 % 5 = 3, and the shrinker lowers it to 0.
        try testing.expectEqualSlices(Choice, &.{.{ .bound = 5, .value = 3 }}, r.failed.choices);
        try testing.expectEqualSlices(Choice, &.{.{ .bound = 5, .value = 0 }}, r.failed.shrunk_choices);
    }
    {
        // Unlike GenContext.index(0) (a sticky InvalidBound), the empty
        // range inside a property is a discard.
        var r = try withEntry(void, {}, propIndex0, &.{}, .{ .max_cases = 1, .max_discards = 2 });
        defer r.deinit();
        try expectStale(r, .discarded);
        try testing.expect(r == .gave_up);
    }
}

// ---------------------------------------------------------------------
// Draw log (D46, internal until v0.4 M5)
// ---------------------------------------------------------------------

fn propThreeDraws(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    const x = try case.generate(u8);
    _ = try case.index(3);
    _ = try case.choose(Op, .full);
    return x < 10;
}

test "draw log: entries match the draws, are copied on failure and survive the arena" {
    // Shrink from {u8 200 (class 0), index 2, choose 1 (b)}. The initial
    // keys are larger than any candidate's and the initial log is
    // empty, so a non-empty result log can only be an accepted
    // evaluation's log, copied out of its arena (every candidate arena
    // is gone when shrinkWith returns).
    const initial = [_]Choice{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 200 }, .{ .bound = 3, .value = 2 }, .{ .bound = 3, .value = 1 } };
    const keys = [_]u64{ 1000, 1000, 1000, 1000 };
    const skips = [_]bool{ false, true, false, false };
    const r = try zigprop.internal.shrinkWith(testing.allocator, void, void, {}, null, propThreeDraws, .returned_false, .{}, 2000, &initial, &keys, &skips, &.{}, &.{}, .{});
    defer testing.allocator.free(r.choices);
    defer testing.allocator.free(r.draws);
    try testing.expectEqual(zigprop.ShrinkOutcome.fixed_point, r.outcome);
    // The shrunk sequence: u8 10 (moved to class 3 by P4), index 0,
    // choose 0 (a).
    try testing.expectEqualSlices(Choice, &.{ .{ .bound = 4, .value = 3 }, .{ .bound = 256, .value = 10 }, .{ .bound = 3, .value = 0 }, .{ .bound = 3, .value = 0 } }, r.choices);
    try testing.expectEqual(@as(usize, 3), r.draws.len);
    const d = r.draws;
    // One entry per draw, in order, covering exactly the positions each
    // consumed.
    try testing.expectEqual(@as(usize, 0), d[0].start);
    try testing.expectEqual(@as(usize, 2), d[0].end);
    try testing.expectEqual(@as(usize, 2), d[1].start);
    try testing.expectEqual(@as(usize, 3), d[1].end);
    try testing.expectEqual(@as(usize, 3), d[2].start);
    try testing.expectEqual(@as(usize, 4), d[2].end);
    for (d) |e| try testing.expectEqual(@as(?usize, null), e.step);
    try testing.expectEqual(@as(u64, 0), d[1].shown.index);
    try testing.expectEqualStrings("a", d[2].shown.tag);
    // The generate entry regenerates its value from its own positions,
    // into memory the caller owns.
    const text = try d[0].shown.regenerate(testing.allocator, .{}, r.choices[d[0].start..d[0].end]);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("10", text);
}

fn below10(x: u8) bool {
    return x < 10;
}

test "draw log: a property that draws nothing logs nothing" {
    const initial = [_]Choice{ .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 200 } };
    const keys = [_]u64{ 200, 200 };
    const skips = [_]bool{ false, true };
    const r = try zigprop.internal.shrinkSpanned(testing.allocator, u8, null, below10, .{}, 2000, &initial, &keys, &skips, &.{}, .{});
    defer testing.allocator.free(r.choices);
    defer testing.allocator.free(r.draws);
    try testing.expectEqual(@as(usize, 0), r.draws.len);
}

// ---------------------------------------------------------------------
// Steps (D45)
// ---------------------------------------------------------------------

fn propStepsUntil7(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    var s = case.steps(4);
    while (s.next()) {
        if (try case.generate(u8) == 7) return false;
    }
    return true;
}

test "steps: one length draw, one element span per step, an early return closes the open span" {
    // Three steps drawn (length 3 of [0, 4]); the second step's u8 is 7,
    // so the property returns inside step 1 and step 2 never runs.
    const values = [_]Choice{ .{ .bound = 5, .value = 3 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 7 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 2 } };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var src = zigprop.internal.Source.initReplay(arena_state.allocator(), &values, 100_000);
    const result = try zigprop.internal.evaluateAttempt(testing.allocator, void, void, {}, null, propStepsUntil7, &src, arena_state.allocator(), .{}, false);
    try testing.expect(result == .fail);
    const f = result.fail;
    defer {
        testing.allocator.free(f.choices);
        testing.allocator.free(f.keys);
        testing.allocator.free(f.skips);
        testing.allocator.free(f.spans);
        testing.allocator.free(f.draws);
    }
    // One length draw, keyed by its value, then two u8 pairs.
    try testing.expectEqualSlices(Choice, values[0..5], f.choices);
    try testing.expectEqual(@as(u64, 3), f.keys[0]);
    // One element span per step that ran, tied to the length draw. The
    // open step 1 ends where the property stopped (position 5), not
    // empty at its start.
    var elements: std.ArrayList(zigprop.internal.Span) = .empty;
    defer elements.deinit(testing.allocator);
    for (f.spans) |sp| {
        if (sp.info == .element) try elements.append(testing.allocator, sp);
    }
    try testing.expectEqual(@as(usize, 2), elements.items.len);
    for (elements.items) |sp| try testing.expectEqual(@as(usize, 0), sp.info.element.length_pos);
    try testing.expectEqual(@as(usize, 1), elements.items[0].start);
    try testing.expectEqual(@as(usize, 3), elements.items[0].end);
    try testing.expectEqual(@as(usize, 3), elements.items[1].start);
    try testing.expectEqual(@as(usize, 5), elements.items[1].end);
    // The draw log: a marker per step, then the step's draws, tagged
    // with the step number.
    try testing.expectEqual(@as(usize, 4), f.draws.len);
    try testing.expect(f.draws[0].shown == .step_marker);
    try testing.expect(f.draws[1].shown == .regenerate);
    try testing.expect(f.draws[2].shown == .step_marker);
    try testing.expect(f.draws[3].shown == .regenerate);
    for (f.draws, [_]usize{ 0, 0, 1, 1 }) |d, step| try testing.expectEqual(@as(?usize, step), d.step);
    try testing.expectEqual(@as(usize, 3), f.draws[3].start);
    try testing.expectEqual(@as(usize, 5), f.draws[3].end);
}

fn propStepsThenIndex(_: void, case: *zigprop.Case, _: void) anyerror!bool {
    var s = case.steps(4);
    while (s.next()) _ = try case.generate(u8);
    _ = try case.index(2);
    return false;
}

test "steps: a finished loop closes its last step and draws after it belong to no step" {
    const values = [_]Choice{ .{ .bound = 5, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 9 }, .{ .bound = 2, .value = 1 } };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var src = zigprop.internal.Source.initReplay(arena_state.allocator(), &values, 100_000);
    const result = try zigprop.internal.evaluateAttempt(testing.allocator, void, void, {}, null, propStepsThenIndex, &src, arena_state.allocator(), .{}, false);
    try testing.expect(result == .fail);
    const f = result.fail;
    defer {
        testing.allocator.free(f.choices);
        testing.allocator.free(f.keys);
        testing.allocator.free(f.skips);
        testing.allocator.free(f.spans);
        testing.allocator.free(f.draws);
    }
    try testing.expectEqualSlices(Choice, &values, f.choices);
    var n_elements: usize = 0;
    for (f.spans) |sp| {
        if (sp.info != .element) continue;
        n_elements += 1;
        try testing.expectEqual(@as(usize, 1), sp.start);
        try testing.expectEqual(@as(usize, 3), sp.end);
    }
    try testing.expectEqual(@as(usize, 1), n_elements);
    try testing.expectEqual(@as(usize, 3), f.draws.len);
    try testing.expectEqual(@as(?usize, null), f.draws[2].step);
    try testing.expectEqual(@as(u64, 1), f.draws[2].shown.index);
}

test "steps: running out of the element budget ends the loop and discards the attempt" {
    // Three steps drawn, but the budget allows two elements: next()
    // returns false at the third step and the attempt is a discard
    // although the property returns false.
    const values = [_]Choice{ .{ .bound = 5, .value = 3 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 1 }, .{ .bound = 4, .value = 0 }, .{ .bound = 256, .value = 2 }, .{ .bound = 2, .value = 0 } };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var src = zigprop.internal.Source.initReplay(arena_state.allocator(), &values, 100_000);
    const result = try zigprop.internal.evaluateAttempt(testing.allocator, void, void, {}, null, propStepsThenIndex, &src, arena_state.allocator(), .{ .max_total_elements = 2 }, false);
    try testing.expect(result == .discard);
}
