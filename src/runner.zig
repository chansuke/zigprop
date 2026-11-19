//! `check` / `checkCustom` / `checkOrError`, `Config` and `Report`
//! (design §5 and §7).
//!
//! Each attempt is classified as pass / fail / discard / infrastructure
//! error (MF5). Only a confirmed fail is snapshotted into result-owned
//! storage (MF9); infrastructure errors propagate out of `check`
//! immediately. A confirmed failure — from random search or from a
//! regression entry — goes through the §6 shrinker before the report
//! is built.

const std = @import("std");
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const gen = @import("gen.zig");
const shrink_mod = @import("shrink.zig");
const Choice = source.Choice;
const GenContext = source.GenContext;
const Limits = source.Limits;
const Source = source.Source;

/// One stored regression entry (design §7). `choices` holds the
/// normalized consumed *values* only; bounds are re-derived by the
/// generator during replay.
pub const Regression = struct {
    id: []const u8,
    gen_version: u32,
    choices: []const u64,
};

pub const Config = struct {
    seed: u64 = 0,
    /// Valid cases to find before reporting `passed`.
    max_cases: usize = 100,
    /// Discards tolerated; exceeding this ends the search as gave_up.
    max_discards: usize = 1000,
    /// Shrink evaluation budget (used from milestone 3).
    shrink_budget: usize = 2000,
    limits: Limits = .{},
    regressions: []const Regression = &.{},
    /// Only regression entries with this id are replayed.
    regression_id: ?[]const u8 = null,
};

pub const ShrinkOutcome = shrink_mod.ShrinkOutcome;

pub const Report = union(enum) {
    passed: struct {
        cases: usize,
        discards: usize,
        regressions_passed: usize,
        stale_regressions: usize,
    },
    failed: struct {
        allocator: Allocator,
        seed: u64,
        attempt_index: usize,
        /// Set when the failure came from a regression entry.
        regression_index: ?usize,
        /// The confirmed failing choice sequence (result-owned).
        choices: []Choice,
        shrunk_choices: []Choice,
        /// Display snapshot of the failing value (result-owned).
        original_value: []u8,
        shrunk_value: []u8,
        shrink_evaluations: usize,
        shrink_outcome: ShrinkOutcome,
    },
    gave_up: struct {
        cases: usize,
        discards: usize,
        regressions_passed: usize,
        stale_regressions: usize,
    },

    pub fn deinit(self: *Report) void {
        switch (self.*) {
            .failed => |*f| {
                f.allocator.free(f.choices);
                f.allocator.free(f.shrunk_choices);
                f.allocator.free(f.original_value);
                f.allocator.free(f.shrunk_value);
            },
            else => {},
        }
        self.* = undefined;
    }
};

pub fn check(
    allocator: Allocator,
    comptime T: type,
    property: *const fn (T) bool,
    config: Config,
) !Report {
    return run(allocator, T, null, property, config);
}

pub fn checkCustom(
    allocator: Allocator,
    comptime T: type,
    generator: *const fn (*GenContext) anyerror!T,
    property: *const fn (T) bool,
    config: Config,
) !Report {
    return run(allocator, T, generator, property, config);
}

/// Thin wrapper for test blocks (design §5): prints the failure and
/// returns `error.PropertyFailed`, or `error.GaveUp` when the discard
/// budget ran out — an unverified case never turns a test green.
pub fn checkOrError(
    allocator: Allocator,
    comptime T: type,
    property: *const fn (T) bool,
    config: Config,
) !void {
    var report = try check(allocator, T, property, config);
    defer report.deinit();
    switch (report) {
        .passed => {},
        .gave_up => return error.GaveUp,
        .failed => |f| {
            std.debug.print("zigprop: property failed (seed {d}, attempt {d})\n", .{ f.seed, f.attempt_index });
            std.debug.print("  value: {s}\n", .{f.original_value});
            std.debug.print("  shrunk value: {s} (shrink: {s}, {d} evaluations)\n", .{ f.shrunk_value, @tagName(f.shrink_outcome), f.shrink_evaluations });
            std.debug.print("  shrunk choice values:", .{});
            for (f.shrunk_choices) |c| std.debug.print(" {d}", .{c.value});
            std.debug.print("\n", .{});
            return error.PropertyFailed;
        },
    }
}

fn makeFailed(
    allocator: Allocator,
    comptime T: type,
    generator: ?*const fn (*GenContext) anyerror!T,
    property: *const fn (T) bool,
    config: Config,
    attempt_index: usize,
    regression_index: ?usize,
    fail: @FieldType(shrink_mod.AttemptResult, "fail"),
) !Report {
    const sr = shrink_mod.shrink(allocator, T, generator, property, config.limits, config.shrink_budget, fail.choices, fail.keys, fail.skips, fail.value_display) catch |err| {
        allocator.free(fail.choices);
        allocator.free(fail.keys);
        allocator.free(fail.skips);
        allocator.free(fail.value_display);
        return err;
    };
    allocator.free(fail.keys);
    allocator.free(fail.skips);
    return .{ .failed = .{
        .allocator = allocator,
        .seed = config.seed,
        .attempt_index = attempt_index,
        .regression_index = regression_index,
        .choices = fail.choices,
        .shrunk_choices = sr.choices,
        .original_value = fail.value_display,
        .shrunk_value = sr.value_display,
        .shrink_evaluations = sr.evaluations,
        .shrink_outcome = sr.outcome,
    } };
}

fn run(
    allocator: Allocator,
    comptime T: type,
    generator: ?*const fn (*GenContext) anyerror!T,
    property: *const fn (T) bool,
    config: Config,
) !Report {
    // Config validation (design §3).
    if (config.limits.max_len == std.math.maxInt(usize)) return error.InvalidConfig;
    if (config.limits.max_total_elements == 0 or config.limits.max_draws == 0) {
        return error.InvalidConfig;
    }
    if (config.limits.max_depth > gen.max_depth_cap) {
        return error.InvalidConfig;
    }

    var regressions_passed: usize = 0;
    var stale_regressions: usize = 0;

    // Phase A: replay matching regression entries first (design §7).
    if (config.regression_id) |rid| {
        for (config.regressions, 0..) |entry, idx| {
            if (!std.mem.eql(u8, entry.id, rid)) continue;
            if (entry.gen_version != gen.generator_version) {
                stale_regressions += 1;
                std.debug.print("zigprop: stale regression '{s}' (gen_version {d}, current {d}); skipped\n", .{ entry.id, entry.gen_version, gen.generator_version });
                continue;
            }
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            const replay_choices = try aa.alloc(Choice, entry.choices.len);
            for (entry.choices, replay_choices) |v, *c| {
                c.* = .{ .bound = 0, .value = v };
            }
            var src = Source.initReplay(aa, replay_choices, config.limits.max_draws);
            defer src.deinit();
            const result = try shrink_mod.evaluateAttempt(allocator, T, generator, property, &src, aa, config.limits, true);
            switch (result) {
                .pass => regressions_passed += 1,
                .discard => {
                    stale_regressions += 1;
                    std.debug.print("zigprop: regression '{s}' no longer reproduces (discarded on replay); treating as stale\n", .{entry.id});
                },
                .fail => |f| return makeFailed(allocator, T, generator, property, config, 0, idx, f),
            }
        }
    }

    // Phase B: random search. The attempt index advances on discards
    // too, so a case is never retried under the same derived seed.
    var cases: usize = 0;
    var discards: usize = 0;
    var attempt: usize = 0;
    while (true) {
        if (cases >= config.max_cases) {
            return .{ .passed = .{
                .cases = cases,
                .discards = discards,
                .regressions_passed = regressions_passed,
                .stale_regressions = stale_regressions,
            } };
        }
        if (discards > config.max_discards) {
            return .{ .gave_up = .{
                .cases = cases,
                .discards = discards,
                .regressions_passed = regressions_passed,
                .stale_regressions = stale_regressions,
            } };
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var src = Source.initRandom(aa, source.deriveSeed(config.seed, @intCast(attempt)), config.limits.max_draws);
        defer src.deinit();
        const result = try shrink_mod.evaluateAttempt(allocator, T, generator, property, &src, aa, config.limits, true);
        switch (result) {
            .pass => cases += 1,
            .discard => discards += 1,
            .fail => |f| return makeFailed(allocator, T, generator, property, config, attempt, null, f),
        }
        attempt += 1;
    }
}
