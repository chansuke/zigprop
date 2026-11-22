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
const fingerprint = @import("fingerprint.zig");
pub const Fingerprint = fingerprint.Fingerprint;
pub const FingerprintMismatch = fingerprint.Mismatch;
const Choice = source.Choice;
const GenContext = source.GenContext;
const Limits = source.Limits;
const Source = source.Source;
const DrawEntry = source.DrawEntry;

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
    /// Added in v0.3 (design §4.4). null for entries written before
    /// v0.3 and for hand-written entries: such an entry is replayed
    /// and, when it passes, counted as `unverified`.
    fingerprint: ?Fingerprint = null,
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
    /// Read by the `*OrError` wrappers only (design v0.3 §4.6, Q2):
    /// when true, any stale entry makes them return
    /// `error.StaleRegression` (a property failure takes precedence).
    /// Stale entries are always recorded in the Report and printed by
    /// the wrappers.
    fail_on_stale: bool = false,
};

/// Why a regression entry was not counted as passed (design v0.3
/// §4.5).
pub const StaleReason = enum {
    /// Recorded by another generator version: not replayed.
    gen_version_mismatch,
    /// The stored fingerprint differs from the current one: not
    /// replayed. `StaleEntry.mismatch` says which fields differ.
    fingerprint_mismatch,
    /// The replay was discarded (including exhaustion).
    discarded,
    /// The replay passed without consuming the whole entry.
    unconsumed_suffix,
};

pub const StaleEntry = struct {
    /// Index into `Config.regressions`.
    index: usize,
    reason: StaleReason,
    /// For `fingerprint_mismatch`: the differing fields.
    mismatch: FingerprintMismatch = .{},
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
        /// The fingerprint of this run (type, relevant limits,
        /// generator kind), printed with the regression entry.
        fingerprint: Fingerprint,
        /// Displays regenerated from `choices` / `shrunk_choices`
        /// without calling the property (result-owned).
        original_value: []u8,
        shrunk_value: []u8,
        shrink_evaluations: usize,
        shrink_outcome: ShrinkOutcome,
        regressions: RegressionSummary,
        /// The values the property drew itself, in draw order, rebuilt
        /// from the choices without calling the property (design v0.4
        /// D46, D47; result-owned). Empty when the property drew
        /// nothing.
        original_draws: []Drawn = &.{},
        shrunk_draws: []Drawn = &.{},
        /// Non-null only when the property drew values on the shrunk
        /// sequence: whether one more replay of that sequence, under
        /// the regression phase's conditions, failed the same way and
        /// consumed it all (D48).
        reproduced: ?bool = null,

        /// One drawn value: the step of `Case.steps` it was drawn in
        /// (null outside any step) and its display.
        pub const Drawn = struct { step: ?usize, text: []u8 };

        /// One line to paste into `tests/regressions.zon`'s `.entries`:
        /// `.{ .id = "…", .gen_version = …, .fingerprint = .{ … },
        /// .choices = .{ … } },` with the shrunk choice values. The
        /// tuple is printed the way `zig fmt` writes it (`.{}`, `.{7}`,
        /// `.{ 3, 268435456 }`), so a pasted entry keeps the file
        /// fmt-clean. Owned by the caller.
        pub fn regressionEntry(self: *const Failed, allocator: Allocator, id: []const u8) ![]u8 {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            const w = &out.writer;
            const fp = self.fingerprint;
            try w.print(".{{ .id = \"{f}\", .gen_version = {d}, .fingerprint = .{{ .type_hash = 0x{x:0>16}, .max_len = {d}, .max_depth = {d}, .custom_generator = {}{s} }}, .choices = .{{", .{
                std.zig.fmtString(id),                                     gen.generator_version, fp.type_hash, fp.max_len, fp.max_depth, fp.custom_generator,
                if (fp.property_draws) ", .property_draws = true" else "",
            });
            const multi = self.shrunk_choices.len > 1;
            for (self.shrunk_choices, 0..) |c, i| {
                try w.print("{s}{d}", .{ if (i == 0) (if (multi) " " else "") else ", ", c.value });
            }
            try w.writeAll(if (multi) " } }," else "} },");
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
                freeDraws(f.allocator, f.original_draws);
                freeDraws(f.allocator, f.shrunk_draws);
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

/// The only printing in zigprop (design v0.3 D26, §4.6, §5.2 format).
/// Stale entries are always printed. Precedence of the returned error:
/// a property failure, then giving up, then (only with
/// `fail_on_stale`) stale entries.
fn finish(report: *Report, config: Config) error{ PropertyFailed, GaveUp, StaleRegression }!void {
    defer report.deinit();
    const summary = switch (report.*) {
        .passed => |p| p.regressions,
        .gave_up => |g| g.regressions,
        .failed => |f| f.regressions,
    };
    printStale(summary, config);
    switch (report.*) {
        .passed => {},
        .gave_up => return error.GaveUp,
        .failed => |*f| {
            printFailure(f, config);
            return error.PropertyFailed;
        },
    }
    if (config.fail_on_stale and summary.stale.len > 0) return error.StaleRegression;
}

fn printStale(summary: RegressionSummary, config: Config) void {
    const print = std.debug.print;
    for (summary.stale) |s| {
        const entry = config.regressions[s.index];
        print("zigprop: stale regression #{d} \"{f}\": {s}", .{ s.index, std.zig.fmtString(entry.id), @tagName(s.reason) });
        switch (s.reason) {
            .gen_version_mismatch => print(" (entry {d}, current {d}); not replayed", .{ entry.gen_version, gen.generator_version }),
            .fingerprint_mismatch => {
                print(" (differs:", .{});
                inline for (@typeInfo(FingerprintMismatch).@"struct".field_names) |name| {
                    if (@field(s.mismatch, name)) print(" {s}", .{name});
                }
                print("); not replayed", .{});
            },
            .discarded => print("; the replay was discarded", .{}),
            .unconsumed_suffix => print("; the replay passed without consuming the whole entry", .{}),
        }
        print(". Re-run and paste the newly printed entry.\n", .{});
    }
}

fn printFailure(f: *const Report.Failed, config: Config) void {
    const print = std.debug.print;
    switch (f.origin) {
        .random => |r| print("zigprop: property failed (seed {d}, attempt {d})\n", .{ r.seed, r.attempt_index }),
        .regression => |r| {
            print("zigprop: property failed (regression #{d} \"{f}\")\n", .{ r.index, std.zig.fmtString(config.regressions[r.index].id) });
            if (r.stale) |reason| print("  note: the entry is also stale ({s})\n", .{@tagName(reason)});
        },
    }
    switch (f.failure) {
        .returned_false => print("  failure: returned false\n", .{}),
        .returned_error => |err| print("  failure: returned error.{s}\n", .{@errorName(err)}),
    }
    print("  original: {s}\n", .{f.original_value});
    print("  shrunk:   {s} ({s}, {d} evaluations)\n", .{ f.shrunk_value, @tagName(f.shrink_outcome), f.shrink_evaluations });
    var drawn: std.Io.Writer.Allocating = .init(f.allocator);
    defer drawn.deinit();
    if (writeDrawn(&drawn.writer, f.shrunk_draws)) |_| {
        print("{s}", .{drawn.written()});
    } else |err| {
        print("  drawn: (unavailable: error.{s})\n", .{@errorName(err)});
    }
    const id = config.regression_id orelse "<set Config.regression_id>";
    print("  regression entry (paste into regressions.zon .entries):\n", .{});
    if (f.regressionEntry(f.allocator, id)) |entry| {
        defer f.allocator.free(entry);
        print("    {s}\n", .{entry});
    } else |err| {
        print("    (unavailable: error.{s})\n", .{@errorName(err)});
    }
}

/// The `drawn:` section (design v0.4 D47): consecutive draws of one
/// step on one line, the last step marked as where the property failed.
/// Nothing when the property drew nothing.
pub fn writeDrawn(out: *std.Io.Writer, draws: []const Report.Failed.Drawn) !void {
    if (draws.len == 0) return;
    var last_stepped: ?usize = null;
    for (draws, 0..) |d, i| {
        if (d.step != null) last_stepped = i;
    }
    try out.print("  drawn:\n", .{});
    var i: usize = 0;
    while (i < draws.len) {
        const step = draws[i].step;
        if (step) |s| try out.print("    step {d}: ", .{s}) else try out.print("    ", .{});
        var j = i;
        while (j < draws.len and std.meta.eql(draws[j].step, step)) : (j += 1) {
            try out.print("{s}{s}", .{ if (j == i) "" else ", ", draws[j].text });
        }
        const failed_here = if (last_stepped) |l| i <= l and l < j else false;
        try out.print("{s}\n", .{if (failed_here) "   <- failed here" else ""});
        i = j;
    }
}

fn freeDraws(allocator: Allocator, draws: []Report.Failed.Drawn) void {
    for (draws) |d| allocator.free(d.text);
    allocator.free(draws);
}

// ---------------------------------------------------------------------
// The core
// ---------------------------------------------------------------------

/// Rebuilds the display of a draw log from the choices it indexes
/// (design v0.4 D46): `Case.generate` values are regenerated from their
/// own positions, indices and tags are written out, and step markers
/// only delimit steps. Result-owned; nothing points into an arena.
fn renderDraws(allocator: Allocator, limits: Limits, choices: []const Choice, log: []const DrawEntry) ![]Report.Failed.Drawn {
    var out: std.ArrayList(Report.Failed.Drawn) = .empty;
    errdefer {
        for (out.items) |d| allocator.free(d.text);
        out.deinit(allocator);
    }
    for (log) |e| {
        const text = switch (e.shown) {
            .step_marker => continue,
            .regenerate => |regen| try regen(allocator, limits, choices[e.start..e.end]),
            .index => |k| try std.fmt.allocPrint(allocator, "{d}", .{k}),
            .tag => |name| try std.fmt.allocPrint(allocator, ".{s}", .{name}),
        };
        out.append(allocator, .{ .step = e.step, .text = text }) catch |err| {
            allocator.free(text);
            return err;
        };
    }
    return out.toOwnedSlice(allocator);
}

/// The reproduction check (design v0.4 D48): replays `choices` once
/// under the regression phase's conditions (bound-0 values, exhaustion
/// is a discard) and reports whether it failed with `failure` and
/// consumed the whole sequence. Not counted in the shrink budget.
fn reproduces(
    allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    property: PropertyWith(Ctx, T),
    limits: Limits,
    failure: Failure,
    choices: []const Choice,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const replay = try aa.alloc(Choice, choices.len);
    for (choices, replay) |c, *r| r.* = .{ .bound = 0, .value = c.value };
    var src = Source.initReplay(aa, replay, limits.max_draws);
    const result = try shrink_mod.evaluateAttempt(aa, T, Ctx, ctx, generator, property, &src, aa, limits, true);
    return switch (result) {
        .fail => |f| f.failure.eql(failure) and src.pos == choices.len,
        .pass, .discard => false,
    };
}

/// Regenerates the value of `choices` in a fresh arena and formats it
/// (design v0.3 §5.5, D30): `{f}` when T declares `format`, `{any}`
/// otherwise (`shrink.formatValue`, shared with the draw log). The
/// property is not called. The result is owned by `allocator`; nothing
/// points into the arena.
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
    return shrink_mod.formatValue(allocator, value);
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
    fp: Fingerprint,
    fail: @FieldType(shrink_mod.AttemptResult, "fail"),
    summary: RegressionSummaryDraft,
) !Report {
    // Ownership moves step by step, so the error paths free explicitly
    // (an errdefer on a value that later moves into the report would
    // double-free).
    const sr = shrink_mod.shrinkWith(allocator, T, Ctx, ctx, generator, property, fail.failure, config.limits, config.shrink_budget, fail.choices, fail.keys, fail.skips, fail.spans, fail.draws, .{}) catch |err| {
        allocator.free(fail.choices);
        allocator.free(fail.keys);
        allocator.free(fail.skips);
        allocator.free(fail.spans);
        allocator.free(fail.draws);
        return err;
    };
    allocator.free(fail.keys);
    allocator.free(fail.skips);
    allocator.free(fail.spans);
    var parts: FailedParts = .{
        .allocator = allocator,
        .choices = fail.choices,
        .shrunk_choices = sr.choices,
        .original_log = fail.draws,
        .shrunk_log = sr.draws,
    };
    // Reproduction check (D48): only when the shrunk sequence drew, so
    // a property that draws nothing runs exactly as in v0.3.
    const reproduced: ?bool = if (sr.draws.len == 0) null else reproduces(allocator, T, Ctx, ctx, generator, property, config.limits, fail.failure, sr.choices) catch |err| {
        parts.free();
        return err;
    };
    parts.original_draws = renderDraws(allocator, config.limits, fail.choices, fail.draws) catch |err| {
        parts.free();
        return err;
    };
    parts.shrunk_draws = renderDraws(allocator, config.limits, sr.choices, sr.draws) catch |err| {
        parts.free();
        return err;
    };
    parts.original_value = renderValue(allocator, T, Ctx, ctx, generator, config.limits, fail.choices) catch |err| {
        parts.free();
        return err;
    };
    parts.shrunk_value = renderValue(allocator, T, Ctx, ctx, generator, config.limits, sr.choices) catch |err| {
        parts.free();
        return err;
    };
    const regressions = summary.finish(allocator) catch |err| {
        parts.free();
        return err;
    };
    // A property that drew values keeps every limit in its fingerprint
    // (D51): a draw inside it may reach any type.
    const report_fp = if (fail.draws.len == 0) fp else fingerprint.ofPropertyDraws(T, config.limits, generator != null);
    allocator.free(fail.draws);
    allocator.free(sr.draws);
    return .{ .failed = .{
        .allocator = allocator,
        .origin = origin,
        .failure = fail.failure,
        .choices = fail.choices,
        .shrunk_choices = sr.choices,
        .fingerprint = report_fp,
        .original_value = parts.original_value,
        .shrunk_value = parts.shrunk_value,
        .shrink_evaluations = sr.evaluations,
        .shrink_outcome = sr.outcome,
        .regressions = regressions,
        .original_draws = parts.original_draws,
        .shrunk_draws = parts.shrunk_draws,
        .reproduced = reproduced,
    } };
}

/// What `makeFailed` owns until the report takes it over, freed in one
/// place on an error path (no errdefer: the values move into the report).
const FailedParts = struct {
    allocator: Allocator,
    choices: []Choice,
    shrunk_choices: []Choice,
    original_log: []DrawEntry,
    shrunk_log: []DrawEntry,
    original_draws: []Report.Failed.Drawn = &.{},
    shrunk_draws: []Report.Failed.Drawn = &.{},
    original_value: []u8 = &.{},
    shrunk_value: []u8 = &.{},

    fn free(self: *const FailedParts) void {
        self.allocator.free(self.choices);
        self.allocator.free(self.shrunk_choices);
        self.allocator.free(self.original_log);
        self.allocator.free(self.shrunk_log);
        freeDraws(self.allocator, self.original_draws);
        freeDraws(self.allocator, self.shrunk_draws);
        self.allocator.free(self.original_value);
        self.allocator.free(self.shrunk_value);
    }
};

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

    // The fingerprint of this run (design v0.3 §4.2-§4.3).
    const fp = fingerprint.of(T, config.limits, generator != null);

    var regressions_passed: usize = 0;
    var unverified: usize = 0;
    var stale: std.ArrayList(StaleEntry) = .empty;
    defer stale.deinit(allocator);

    // Phase A: replay matching regression entries first (design §7),
    // classified by the v0.3 §4.5 decision table. Stale is an enum
    // value here, never an error name (§4.5, §5.3).
    if (config.regression_id) |rid| {
        for (config.regressions, 0..) |entry, idx| {
            if (!std.mem.eql(u8, entry.id, rid)) continue;
            // Row 1: another generator version -> not replayed.
            if (entry.gen_version != gen.generator_version) {
                try stale.append(allocator, .{ .index = idx, .reason = .gen_version_mismatch });
                continue;
            }
            // Row 2: a stored fingerprint that differs -> not replayed.
            if (entry.fingerprint) |stored| {
                // An entry from a property that drew values is compared
                // with every limit kept, the way it was recorded (D51).
                const current = if (stored.property_draws) fingerprint.ofPropertyDraws(T, config.limits, generator != null) else fp;
                const mismatch = fingerprint.compare(stored, current);
                if (mismatch.any()) {
                    try stale.append(allocator, .{ .index = idx, .reason = .fingerprint_mismatch, .mismatch = mismatch });
                    continue;
                }
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
            const suffix = src.pos < entry.choices.len;
            switch (result) {
                // Rows 5-7.
                .pass => if (suffix) {
                    try stale.append(allocator, .{ .index = idx, .reason = .unconsumed_suffix });
                } else {
                    regressions_passed += 1;
                    if (entry.fingerprint == null) unverified += 1;
                },
                // Row 4.
                .discard => try stale.append(allocator, .{ .index = idx, .reason = .discarded }),
                // Row 3: a real failure is always reported; a suffix is
                // noted on the origin.
                .fail => |f| return makeFailed(allocator, T, Ctx, ctx, generator, property, config, .{ .regression = .{
                    .index = idx,
                    .stale = if (suffix) .unconsumed_suffix else null,
                } }, fp, f, .{
                    .passed = regressions_passed,
                    .unverified = unverified,
                    .stale = stale.items,
                }),
            }
        }
    }
    const summary: RegressionSummaryDraft = .{ .passed = regressions_passed, .unverified = unverified, .stale = stale.items };

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
            .fail => |f| return makeFailed(allocator, T, Ctx, ctx, generator, property, config, .{ .random = .{ .seed = config.seed, .attempt_index = attempt } }, fp, f, summary),
        }
        attempt += 1;
    }
}
