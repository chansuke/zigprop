//! `check` / `checkCustom` / `checkWith`, their `*OrError` wrappers,
//! `Config` and `Report` (design §5 and §7; v0.3 §5).
//!
//! Each attempt is classified as pass / fail / discard / infrastructure
//! error (MF5). Only a confirmed fail is snapshotted into result-owned
//! storage (MF9); infrastructure errors propagate out of `check`
//! immediately. A property error is a failure, never an infrastructure
//! error (v0.3 §5.3). A confirmed failure — from random search or from
//! a regression entry — goes through the shrinker before the report is
//! built; both displays are then regenerated from the final choice
//! sequences without calling the property (v0.3 §5.5).
//!
//! The core never prints (v0.3 D26); only the `*OrError` wrappers use
//! `std.debug.print`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const gen = @import("gen.zig");
const shrink_mod = @import("shrink.zig");
const Choice = source.Choice;
const GenContext = source.GenContext;
const Limits = source.Limits;
const Source = source.Source;

pub const Case = shrink_mod.Case;
pub const Failure = shrink_mod.Failure;
pub const Generator = shrink_mod.Generator;
pub const GeneratorWith = shrink_mod.GeneratorWith;
pub const PropertyWith = shrink_mod.PropertyWith;
pub const ShrinkOutcome = shrink_mod.ShrinkOutcome;

/// One stored regression entry (design §7). `choices` holds the
/// normalized consumed *values* only; bounds are re-derived by the
/// generator during replay.
pub const Regression = struct {
    id: []const u8,
    gen_version: u32,
    choices: []const u64,
};

/// The type of `tests/regressions.zon` (design v0.3 §4.4, D31): the
/// version-1 file schema, imported at comptime with
/// `const file: zigprop.RegressionFile = @import("regressions.zon");`.
pub const RegressionFile = struct {
    version: u32,
    entries: []const Regression,
};

pub const Config = struct {
    seed: u64 = 0,
    /// Valid cases to find before reporting `passed`.
    max_cases: usize = 100,
    /// Discards tolerated; exceeding this ends the search as gave_up.
    max_discards: usize = 1000,
    /// Shrink evaluation budget.
    shrink_budget: usize = 2000,
    limits: Limits = .{},
    regressions: []const Regression = &.{},
    /// Only regression entries with this id are replayed.
    regression_id: ?[]const u8 = null,
};

/// Why a regression entry was not counted as passed (design v0.3
/// §4.5). `fingerprint_mismatch` and `unconsumed_suffix` are decided
/// from milestone M5 on.
pub const StaleReason = enum { gen_version_mismatch, fingerprint_mismatch, discarded, unconsumed_suffix };

pub const StaleEntry = struct {
    /// Index into `Config.regressions`.
    index: usize,
    reason: StaleReason,
};

pub const RegressionSummary = struct {
    passed: usize = 0,
    /// Entries without a fingerprint that passed (also in `passed`).
    unverified: usize = 0,
    /// Owned by the report's allocator.
    stale: []StaleEntry = &.{},
};

/// Where a failure came from (design v0.3 §5.2, D29).
pub const Origin = union(enum) {
    random: struct { seed: u64, attempt_index: usize },
    regression: struct { index: usize, stale: ?StaleReason },
};

/// The report of one run. The variant set (`passed`, `failed`,
/// `gave_up`) is frozen in v0.3 (§7.5): adding a variant would break
/// exhaustive switches. Every variant owns memory: always `deinit`.
pub const Report = union(enum) {
    passed: Passed,
    failed: Failed,
    gave_up: GaveUp,

    pub const Passed = struct {
        allocator: Allocator,
        cases: usize,
        discards: usize,
        regressions: RegressionSummary,
    };

    pub const GaveUp = struct {
        allocator: Allocator,
        cases: usize,
        discards: usize,
        regressions: RegressionSummary,
    };

    pub const Failed = struct {
        allocator: Allocator,
        origin: Origin,
        failure: Failure,
        /// The confirmed failing choice sequence (result-owned).
        choices: []Choice,
        shrunk_choices: []Choice,
        /// Displays regenerated from `choices` / `shrunk_choices`
        /// without calling the property (result-owned).
        original_value: []u8,
        shrunk_value: []u8,
        shrink_evaluations: usize,
        shrink_outcome: ShrinkOutcome,
        regressions: RegressionSummary,

        /// One line to paste into `tests/regressions.zon`'s `.entries`:
        /// `.{ .id = "…", .gen_version = …, .choices = .{ … } },` with
        /// the shrunk choice values. Owned by the caller.
        pub fn regressionEntry(self: *const Failed, allocator: Allocator, id: []const u8) ![]u8 {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print(".{{ .id = \"{f}\", .gen_version = {d}, .choices = .{{", .{ std.zig.fmtString(id), gen.generator_version });
            for (self.shrunk_choices, 0..) |c, i| {
                try w.print("{s}{d}", .{ if (i == 0) " " else ", ", c.value });
            }
            try w.writeAll(if (self.shrunk_choices.len == 0) "} }," else " } },");
            return out.toOwnedSlice();
        }
    };

    pub fn deinit(self: *Report) void {
        switch (self.*) {
            .passed => |*p| p.allocator.free(p.regressions.stale),
            .gave_up => |*g| g.allocator.free(g.regressions.stale),
            .failed => |*f| {
                f.allocator.free(f.choices);
                f.allocator.free(f.shrunk_choices);
                f.allocator.free(f.original_value);
                f.allocator.free(f.shrunk_value);
                f.allocator.free(f.regressions.stale);
            },
        }
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------
// Entry points. The simple forms are adapters onto checkWith, so the
// core has a single execution path (design v0.3 §5.2).
// ---------------------------------------------------------------------

pub fn check(
    allocator: Allocator,
    comptime T: type,
    property: *const fn (T) bool,
    config: Config,
) !Report {
    const B = shrink_mod.BoolProperty(T);
    return checkWith(allocator, T, B.Ctx, property, null, B.property, config);
}

pub fn checkCustom(
    allocator: Allocator,
    comptime T: type,
    generator: Generator(T),
    property: *const fn (T) bool,
    config: Config,
) !Report {
    const C = shrink_mod.CustomProperty(T);
    return checkWith(allocator, T, C.Ctx, .{ .property = property, .generator = generator }, C.generator, C.property, config);
}

/// The general entry point (design v0.3 §5.2, D27): a context handed
/// to the property (and to an optional custom generator), a per-case
/// allocator, and properties that may return errors.
pub fn checkWith(
    allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    property: PropertyWith(Ctx, T),
    config: Config,
) !Report {
    return run(allocator, T, Ctx, ctx, generator, property, config);
}

/// Thin wrapper for test blocks (design §5): prints the failure and a
/// pasteable regression entry and returns `error.PropertyFailed`, or
/// `error.GaveUp` when the discard budget ran out — an unverified case
/// never turns a test green.
pub fn checkOrError(
    allocator: Allocator,
    comptime T: type,
    property: *const fn (T) bool,
    config: Config,
) !void {
    var report = try check(allocator, T, property, config);
    return finish(&report, config);
}

pub fn checkCustomOrError(
    allocator: Allocator,
    comptime T: type,
    generator: Generator(T),
    property: *const fn (T) bool,
    config: Config,
) !void {
    var report = try checkCustom(allocator, T, generator, property, config);
    return finish(&report, config);
}

pub fn checkWithOrError(
    allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    property: PropertyWith(Ctx, T),
    config: Config,
) !void {
    var report = try checkWith(allocator, T, Ctx, ctx, generator, property, config);
    return finish(&report, config);
}

/// The only printing in zigprop (design v0.3 D26, §5.2 format).
fn finish(report: *Report, config: Config) error{ PropertyFailed, GaveUp }!void {
    defer report.deinit();
    switch (report.*) {
        .passed => {},
        .gave_up => return error.GaveUp,
        .failed => |*f| {
            printFailure(f, config);
            return error.PropertyFailed;
        },
    }
}

fn printFailure(f: *const Report.Failed, config: Config) void {
    const print = std.debug.print;
    switch (f.origin) {
        .random => |r| print("zigprop: property failed (seed {d}, attempt {d})\n", .{ r.seed, r.attempt_index }),
        .regression => |r| print("zigprop: property failed (regression #{d} \"{f}\")\n", .{ r.index, std.zig.fmtString(config.regressions[r.index].id) }),
    }
    switch (f.failure) {
        .returned_false => print("  failure: returned false\n", .{}),
        .returned_error => |err| print("  failure: returned error.{s}\n", .{@errorName(err)}),
    }
    print("  original: {s}\n", .{f.original_value});
    print("  shrunk:   {s} ({s}, {d} evaluations)\n", .{ f.shrunk_value, @tagName(f.shrink_outcome), f.shrink_evaluations });
    const id = config.regression_id orelse "<set Config.regression_id>";
    print("  regression entry (paste into regressions.zon .entries):\n", .{});
    if (f.regressionEntry(f.allocator, id)) |entry| {
        defer f.allocator.free(entry);
        print("    {s}\n", .{entry});
    } else |err| {
        print("    (unavailable: error.{s})\n", .{@errorName(err)});
    }
}

// ---------------------------------------------------------------------
// The core
// ---------------------------------------------------------------------

fn hasCustomFormat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "format"),
        else => false,
    };
}

/// Regenerates the value of `choices` in a fresh arena and formats it
/// (design v0.3 §5.5, D30): `{f}` when T declares `format`, `{any}`
/// otherwise. The property is not called. The result is owned by
/// `allocator`; nothing points into the arena.
fn renderValue(
    allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    limits: Limits,
    choices: []const Choice,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var src = Source.initReplay(aa, choices, limits.max_draws);
    var state: source.GenState = undefined;
    var gctx = source.genContextForTest(&state, &src, aa, limits);
    const value = try (if (generator) |g| g(ctx, &gctx) else gen.generate(T, &gctx));
    if (comptime hasCustomFormat(T)) {
        return std.fmt.allocPrint(allocator, "{f}", .{value});
    }
    return std.fmt.allocPrint(allocator, "{any}", .{value});
}

fn makeFailed(
    allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    property: PropertyWith(Ctx, T),
    config: Config,
    origin: Origin,
    fail: @FieldType(shrink_mod.AttemptResult, "fail"),
    summary: RegressionSummaryDraft,
) !Report {
    // Ownership moves step by step, so the error paths free explicitly
    // (an errdefer on a value that later moves into the report would
    // double-free).
    const sr = shrink_mod.shrinkWith(allocator, T, Ctx, ctx, generator, property, fail.failure, config.limits, config.shrink_budget, fail.choices, fail.keys, fail.skips, fail.spans, .{}) catch |err| {
        allocator.free(fail.choices);
        allocator.free(fail.keys);
        allocator.free(fail.skips);
        allocator.free(fail.spans);
        return err;
    };
    allocator.free(fail.keys);
    allocator.free(fail.skips);
    allocator.free(fail.spans);
    const original = renderValue(allocator, T, Ctx, ctx, generator, config.limits, fail.choices) catch |err| {
        allocator.free(fail.choices);
        allocator.free(sr.choices);
        return err;
    };
    const shrunk = renderValue(allocator, T, Ctx, ctx, generator, config.limits, sr.choices) catch |err| {
        allocator.free(fail.choices);
        allocator.free(sr.choices);
        allocator.free(original);
        return err;
    };
    const regressions = summary.finish(allocator) catch |err| {
        allocator.free(fail.choices);
        allocator.free(sr.choices);
        allocator.free(original);
        allocator.free(shrunk);
        return err;
    };
    return .{ .failed = .{
        .allocator = allocator,
        .origin = origin,
        .failure = fail.failure,
        .choices = fail.choices,
        .shrunk_choices = sr.choices,
        .original_value = original,
        .shrunk_value = shrunk,
        .shrink_evaluations = sr.evaluations,
        .shrink_outcome = sr.outcome,
        .regressions = regressions,
    } };
}

/// The regression phase's counts while the run is in progress; the
/// stale list is borrowed until `finish` copies it into the report.
const RegressionSummaryDraft = struct {
    passed: usize,
    unverified: usize,
    stale: []const StaleEntry,

    fn finish(self: RegressionSummaryDraft, allocator: Allocator) !RegressionSummary {
        return .{
            .passed = self.passed,
            .unverified = self.unverified,
            .stale = try allocator.dupe(StaleEntry, self.stale),
        };
    }
};

fn run(
    allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    property: PropertyWith(Ctx, T),
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
    // Zero cases would report a vacuous `.passed` without testing
    // anything.
    if (config.max_cases == 0) return error.InvalidConfig;

    var regressions_passed: usize = 0;
    var stale: std.ArrayList(StaleEntry) = .empty;
    defer stale.deinit(allocator);

    // Phase A: replay matching regression entries first (design §7).
    if (config.regression_id) |rid| {
        for (config.regressions, 0..) |entry, idx| {
            if (!std.mem.eql(u8, entry.id, rid)) continue;
            if (entry.gen_version != gen.generator_version) {
                try stale.append(allocator, .{ .index = idx, .reason = .gen_version_mismatch });
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
            const result = try shrink_mod.evaluateAttempt(allocator, T, Ctx, ctx, generator, property, &src, aa, config.limits, true);
            switch (result) {
                .pass => regressions_passed += 1,
                .discard => try stale.append(allocator, .{ .index = idx, .reason = .discarded }),
                .fail => |f| return makeFailed(allocator, T, Ctx, ctx, generator, property, config, .{ .regression = .{ .index = idx, .stale = null } }, f, .{
                    .passed = regressions_passed,
                    .unverified = 0,
                    .stale = stale.items,
                }),
            }
        }
    }
    const summary: RegressionSummaryDraft = .{ .passed = regressions_passed, .unverified = 0, .stale = stale.items };

    // Phase B: random search. The attempt index advances on discards
    // too, so a case is never retried under the same derived seed.
    var cases: usize = 0;
    var discards: usize = 0;
    var attempt: usize = 0;
    while (true) {
        if (cases >= config.max_cases) {
            return .{ .passed = .{
                .allocator = allocator,
                .cases = cases,
                .discards = discards,
                .regressions = try summary.finish(allocator),
            } };
        }
        if (discards > config.max_discards) {
            return .{ .gave_up = .{
                .allocator = allocator,
                .cases = cases,
                .discards = discards,
                .regressions = try summary.finish(allocator),
            } };
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var src = Source.initRandom(aa, source.deriveSeed(config.seed, @intCast(attempt)), config.limits.max_draws);
        defer src.deinit();
        const result = try shrink_mod.evaluateAttempt(allocator, T, Ctx, ctx, generator, property, &src, aa, config.limits, true);
        switch (result) {
            .pass => cases += 1,
            .discard => discards += 1,
            .fail => |f| return makeFailed(allocator, T, Ctx, ctx, generator, property, config, .{ .random = .{ .seed = config.seed, .attempt_index = attempt } }, f, summary),
        }
        attempt += 1;
    }
}
