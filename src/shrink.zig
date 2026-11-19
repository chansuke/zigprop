//! Shrinking (design §6) and the shared attempt evaluator (§5, MF5).
//!
//! The predicate is P(C) = "replaying the choice sequence C fails".
//! A candidate is accepted only when its *re-recorded consumed*
//! sequence is strictly shortlex-smaller than the stored best
//! (MF2), so the stored state strictly decreases with every
//! acceptance and cannot cycle. Passes P1 (chunk deletion), P2
//! (zeroing) and P3 (power-of-two decrease) repeat until a full
//! round changes nothing (`fixed_point`) or the evaluation budget
//! runs out (`budget_exhausted`). Infrastructure errors abort the
//! shrink and propagate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const gen = @import("gen.zig");
const Choice = source.Choice;
const GenContext = source.GenContext;
const Limits = source.Limits;
const Source = source.Source;

pub const ShrinkOutcome = enum {
    fixed_point,
    budget_exhausted,
};

pub const AttemptResult = union(enum) {
    pass,
    discard,
    fail: struct {
        /// The consumed choice sequence, owned by the result allocator.
        choices: []Choice,
        /// Display snapshot of the failing value, result-owned.
        value_display: []u8,
    },
};

/// Runs one generation + property evaluation against a prepared
/// Source and classifies the outcome (design §5, MF5). On a
/// confirmed failure the consumed sequence and a display snapshot
/// are copied into result-owned storage before the attempt arena
/// dies (MF9).
pub fn evaluateAttempt(
    result_allocator: Allocator,
    comptime T: type,
    generator: ?*const fn (*GenContext) anyerror!T,
    property: *const fn (T) bool,
    src: *Source,
    attempt_allocator: Allocator,
    limits: Limits,
) !AttemptResult {
    var ctx = GenContext{ .src = src, .allocator = attempt_allocator, .limits = limits };
    const value = (if (generator) |g| g(&ctx) else gen.generate(T, &ctx)) catch |err| {
        if (err == error.InvalidGeneration) return .discard;
        return err; // infrastructure error: propagate (MF5)
    };
    if (src.sticky_error) |err| return err;
    if (src.limit_exceeded) return .discard;
    if (src.exhausted) return .discard; // replay no longer matches the generator
    if (property(value)) return .pass;
    const choices = try result_allocator.dupe(Choice, src.recorded.items);
    errdefer result_allocator.free(choices);
    const display = try std.fmt.allocPrint(result_allocator, "{any}", .{value});
    return .{ .fail = .{ .choices = choices, .value_display = display } };
}

pub const ShrinkResult = struct {
    /// The shrunk consumed sequence, owned by the result allocator.
    choices: []Choice,
    /// Display snapshot of the shrunk value, result-owned.
    value_display: []u8,
    evaluations: usize,
    outcome: ShrinkOutcome,
};

/// Strict shortlex order on the *value* sequences of two consumed
/// choice lists: shorter first, then lexicographic (design §6, MF2).
pub fn shortlexLess(a: []const Choice, b: []const Choice) bool {
    if (a.len != b.len) return a.len < b.len;
    for (a, b) |x, y| {
        if (x.value != y.value) return x.value < y.value;
    }
    return false;
}

fn highestPow2(v: u64) u64 {
    std.debug.assert(v > 0);
    return @as(u64, 1) << @intCast(63 - @clz(v));
}

pub fn shrink(
    result_allocator: Allocator,
    comptime T: type,
    generator: ?*const fn (*GenContext) anyerror!T,
    property: *const fn (T) bool,
    limits: Limits,
    budget: usize,
    initial: []const Choice,
    initial_display: []const u8,
) !ShrinkResult {
    const Inner = struct {
        allocator: Allocator,
        generator: ?*const fn (*GenContext) anyerror!T,
        property: *const fn (T) bool,
        limits: Limits,
        budget: usize,
        evaluations: usize = 0,
        best: []Choice,
        best_display: []u8,

        const Fail = @FieldType(AttemptResult, "fail");

        fn evalCandidate(self: *@This(), values: []const u64) !?Fail {
            if (self.evaluations >= self.budget) return error.ShrinkBudgetExhausted;
            self.evaluations += 1;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            const replay = try aa.alloc(Choice, values.len);
            for (values, replay) |v, *c| c.* = .{ .bound = 0, .value = v };
            var src = Source.initReplay(aa, replay, self.limits.max_draws);
            defer src.deinit();
            const result = try evaluateAttempt(self.allocator, T, self.generator, self.property, &src, aa, self.limits);
            return switch (result) {
                .fail => |f| f,
                else => null,
            };
        }

        /// Tries one candidate value sequence; on acceptance the
        /// stored best is replaced by the re-recorded consumed
        /// sequence. Returns whether the best changed.
        fn tryAccept(self: *@This(), values: []const u64) !bool {
            const f = (try self.evalCandidate(values)) orelse return false;
            if (!shortlexLess(f.choices, self.best)) {
                self.allocator.free(f.choices);
                self.allocator.free(f.value_display);
                return false;
            }
            self.allocator.free(self.best);
            self.allocator.free(self.best_display);
            self.best = f.choices;
            self.best_display = f.value_display;
            return true;
        }

        fn candidateValues(self: *@This()) !std.ArrayList(u64) {
            var list: std.ArrayList(u64) = .empty;
            errdefer list.deinit(self.allocator);
            for (self.best) |c| try list.append(self.allocator, c.value);
            return list;
        }

        /// P1: chunk deletion. Chunk sizes start at half of the
        /// largest power of two ≤ len and halve down to 1 (design §6).
        fn passChunks(self: *@This()) !bool {
            var changed_any = false;
            if (self.best.len == 0) return false;
            var chunk: usize = @max(1, highestPow2(@intCast(self.best.len)) / 2);
            while (true) {
                var i: usize = 0;
                while (i + chunk <= self.best.len) {
                    var cand: std.ArrayList(u64) = .empty;
                    defer cand.deinit(self.allocator);
                    for (self.best[0..i]) |c| try cand.append(self.allocator, c.value);
                    for (self.best[i + chunk ..]) |c| try cand.append(self.allocator, c.value);
                    if (try self.tryAccept(cand.items)) {
                        changed_any = true;
                        i = 0; // rescan the new sequence at this size
                    } else {
                        i += chunk;
                    }
                }
                if (chunk == 1) break;
                chunk /= 2;
            }
            return changed_any;
        }

        /// P2: zero each non-zero element in turn.
        fn passZero(self: *@This()) !bool {
            var changed_any = false;
            var i: usize = 0;
            while (i < self.best.len) : (i += 1) {
                if (self.best[i].value == 0) continue;
                var cand = try self.candidateValues();
                defer cand.deinit(self.allocator);
                cand.items[i] = 0;
                if (try self.tryAccept(cand.items)) changed_any = true;
            }
            return changed_any;
        }

        /// P3: for each element, greedily subtract powers of two,
        /// restarting the delta scan after every acceptance.
        fn passDecrease(self: *@This()) !bool {
            var changed_any = false;
            var i: usize = 0;
            while (i < self.best.len) {
                if (self.best[i].value == 0) {
                    i += 1;
                    continue;
                }
                var improved = true;
                while (improved and i < self.best.len and self.best[i].value != 0) {
                    improved = false;
                    var delta = highestPow2(self.best[i].value);
                    while (true) {
                        var cand = try self.candidateValues();
                        defer cand.deinit(self.allocator);
                        cand.items[i] = self.best[i].value - delta;
                        if (try self.tryAccept(cand.items)) {
                            changed_any = true;
                            improved = true;
                            break;
                        }
                        if (delta == 1) break;
                        delta /= 2;
                    }
                }
                i += 1;
            }
            return changed_any;
        }

        fn round(self: *@This()) !bool {
            var changed = false;
            if (try self.passChunks()) changed = true;
            if (try self.passZero()) changed = true;
            if (try self.passDecrease()) changed = true;
            return changed;
        }
    };

    var inner = Inner{
        .allocator = result_allocator,
        .generator = generator,
        .property = property,
        .limits = limits,
        .budget = budget,
        .best = try result_allocator.dupe(Choice, initial),
        .best_display = try result_allocator.dupe(u8, initial_display),
    };
    const outcome: ShrinkOutcome = blk: {
        while (true) {
            const changed = inner.round() catch |err| {
                if (err == error.ShrinkBudgetExhausted) break :blk .budget_exhausted;
                result_allocator.free(inner.best);
                result_allocator.free(inner.best_display);
                return err;
            };
            if (!changed) break :blk .fixed_point;
        }
    };
    return .{
        .choices = inner.best,
        .value_display = inner.best_display,
        .evaluations = inner.evaluations,
        .outcome = outcome,
    };
}
