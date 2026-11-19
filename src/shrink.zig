//! Shrinking (design §6) and the shared attempt evaluator (§5, MF5).
//!
//! The predicate is P(C) = "replaying the choice sequence C fails".
//! A candidate is accepted only when the key sequence of its
//! *re-recorded consumed* sequence is strictly shortlex-smaller
//! than the stored best (MF2, v2.1: keys are canonical — an integer
//! pair contributes its value's rank, so acceptance compares value
//! simplicity rather than class encodings). P4 (re-expression)
//! additionally accepts a key-equal lateral move that rewrites an
//! integer pair into the full-domain class so P3 can descend it.
//! Passes repeat until a full round changes nothing
//! (`fixed_point`) or the evaluation budget runs out
//! (`budget_exhausted`). Infrastructure errors abort the shrink
//! and propagate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const gen = @import("gen.zig");
const Choice = source.Choice;
const GenContext = source.GenContext;
const Limits = source.Limits;
const Source = source.Source;
const Span = source.Span;

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
        /// Canonical key per choice, result-owned (design §4.1, v2.1).
        keys: []u64,
        /// Key-comparison skip flags, result-owned.
        skips: []bool,
        /// Span annotations of the consumed sequence, result-owned
        /// (design v0.3 §3.2, D18). Metadata only.
        spans: []Span,
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
    exhaustion_is_discard: bool,
) !AttemptResult {
    var ctx = GenContext{ .src = src, .allocator = attempt_allocator, .limits = limits };
    const value = (if (generator) |g| g(&ctx) else gen.generate(T, &ctx)) catch |err| {
        // A sticky error (recording failure) outranks the generator's
        // own error: it is an infrastructure error (MF5, §3).
        if (src.sticky_error) |serr| return serr;
        if (err == error.InvalidGeneration) return .discard;
        return err; // infrastructure error: propagate (MF5)
    };
    if (src.sticky_error) |err| return err;
    if (src.limit_exceeded) return .discard;
    // In the runner, an exhausted replay means the stored sequence no
    // longer matches the generator (stale regression) -> discard. In
    // the shrinker, a candidate is evaluated with zero padding and
    // its re-recorded consumed sequence (padding included) is what
    // the acceptance rule compares (§6).
    if (src.exhausted and exhaustion_is_discard) return .discard;
    if (property(value)) return .pass;
    const choices = try result_allocator.dupe(Choice, src.recorded.items);
    errdefer result_allocator.free(choices);
    const keys = try result_allocator.dupe(u64, src.recorded_keys.items);
    errdefer result_allocator.free(keys);
    const skips = try result_allocator.dupe(bool, src.recorded_skip.items);
    errdefer result_allocator.free(skips);
    const spans = try result_allocator.dupe(Span, src.recorded_spans.items);
    errdefer result_allocator.free(spans);
    const display = try std.fmt.allocPrint(result_allocator, "{any}", .{value});
    return .{ .fail = .{ .choices = choices, .keys = keys, .skips = skips, .spans = spans, .value_display = display } };
}

pub const ShrinkResult = struct {
    /// The shrunk consumed sequence, owned by the result allocator.
    choices: []Choice,
    /// Display snapshot of the shrunk value, result-owned.
    value_display: []u8,
    evaluations: usize,
    outcome: ShrinkOutcome,
};

fn filteredLen(skip: []const bool) usize {
    var n: usize = 0;
    for (skip) |s| {
        if (!s) n += 1;
    }
    return n;
}

/// Strict shortlex order on two key sequences (design §6, v2.1):
/// positions whose skip flag is set are excluded; compare the
/// filtered length first, then lexicographically. With no
/// annotations this is exactly shortlex on the value sequence.
pub fn keyShortlexLess(a_keys: []const u64, a_skip: []const bool, b_keys: []const u64, b_skip: []const bool) bool {
    const la = filteredLen(a_skip);
    const lb = filteredLen(b_skip);
    if (la != lb) return la < lb;
    var ia: usize = 0;
    var ib: usize = 0;
    while (true) {
        while (ia < a_keys.len and a_skip[ia]) ia += 1;
        while (ib < b_keys.len and b_skip[ib]) ib += 1;
        if (ia >= a_keys.len) return false;
        if (a_keys[ia] != b_keys[ib]) return a_keys[ia] < b_keys[ib];
        ia += 1;
        ib += 1;
    }
}

fn keysEqual(a_keys: []const u64, a_skip: []const bool, b_keys: []const u64, b_skip: []const bool) bool {
    return !keyShortlexLess(a_keys, a_skip, b_keys, b_skip) and
        !keyShortlexLess(b_keys, b_skip, a_keys, a_skip);
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
    initial_keys: []const u64,
    initial_skips: []const bool,
    initial_display: []const u8,
) !ShrinkResult {
    return shrinkSpanned(result_allocator, T, generator, property, limits, budget, initial, initial_keys, initial_skips, &.{}, initial_display);
}

/// `shrink` with the initial sequence's span annotations (design
/// v0.3 §3.2). The runner uses this form; spans are metadata and
/// never affect acceptance.
pub fn shrinkSpanned(
    result_allocator: Allocator,
    comptime T: type,
    generator: ?*const fn (*GenContext) anyerror!T,
    property: *const fn (T) bool,
    limits: Limits,
    budget: usize,
    initial: []const Choice,
    initial_keys: []const u64,
    initial_skips: []const bool,
    initial_spans: []const Span,
    initial_display: []const u8,
) !ShrinkResult {
    const Inner = struct {
        allocator: Allocator,
        generator: ?*const fn (*GenContext) anyerror!T,
        property: *const fn (T) bool,
        limits: Limits,
        budget: usize,
        evaluations: usize = 0,
        /// Set when an evaluation was requested beyond the budget.
        /// Control flow uses this flag, never an error name: Zig
        /// errors are interned by name globally, so a generator could
        /// return the same error and be mistaken for budget control.
        exhausted: bool = false,
        best: []Choice,
        best_keys: []u64,
        best_skips: []bool,
        /// Spans of the best sequence (design v0.3 §3.2); replaced
        /// together with it on every acceptance.
        best_spans: []Span,
        best_display: []u8,

        const Fail = @FieldType(AttemptResult, "fail");

        fn evalCandidate(self: *@This(), values: []const u64) !?Fail {
            if (self.evaluations >= self.budget) {
                self.exhausted = true;
                return null;
            }
            self.evaluations += 1;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            const replay = try aa.alloc(Choice, values.len);
            for (values, replay) |v, *c| c.* = .{ .bound = 0, .value = v };
            var src = Source.initReplay(aa, replay, self.limits.max_draws);
            defer src.deinit();
            const result = try evaluateAttempt(self.allocator, T, self.generator, self.property, &src, aa, self.limits, false);
            return switch (result) {
                .fail => |f| f,
                else => null,
            };
        }

        fn freeFail(self: *@This(), f: Fail) void {
            self.allocator.free(f.choices);
            self.allocator.free(f.keys);
            self.allocator.free(f.skips);
            self.allocator.free(f.spans);
            self.allocator.free(f.value_display);
        }

        fn replaceBest(self: *@This(), f: Fail) void {
            self.allocator.free(self.best);
            self.allocator.free(self.best_keys);
            self.allocator.free(self.best_skips);
            self.allocator.free(self.best_spans);
            self.allocator.free(self.best_display);
            self.best = f.choices;
            self.best_keys = f.keys;
            self.best_skips = f.skips;
            self.best_spans = f.spans;
            self.best_display = f.value_display;
        }

        /// Tries one candidate value sequence; on acceptance the
        /// stored best is replaced by the re-recorded consumed
        /// sequence. Acceptance requires the candidate's key
        /// sequence to be strictly shortlex-smaller (design §6,
        /// v2.1). Returns whether the best changed.
        fn tryAccept(self: *@This(), values: []const u64) !bool {
            if (self.exhausted) return false;
            const f = (try self.evalCandidate(values)) orelse return false;
            if (!keyShortlexLess(f.keys, f.skips, self.best_keys, self.best_skips)) {
                self.freeFail(f);
                return false;
            }
            self.replaceBest(f);
            return true;
        }

        /// P4 acceptance (design §6, v2.1): a lateral move that keeps
        /// the generated value (key sequence equal) while rewriting
        /// the integer pair starting at `pair_start` into the
        /// full-domain class, so P3 can descend its rank. One-way:
        /// the pair must not already be in class 3, and the
        /// re-recorded pair must still be a pair in class 3.
        fn tryRatchet(self: *@This(), values: []const u64, pair_start: usize) !bool {
            if (self.exhausted) return false;
            const f = (try self.evalCandidate(values)) orelse return false;
            const ok = f.choices.len == self.best.len and
                pair_start + 1 < f.choices.len and
                f.skips[pair_start + 1] and
                f.choices[pair_start].value == 3 and
                keysEqual(f.keys, f.skips, self.best_keys, self.best_skips);
            if (!ok) {
                self.freeFail(f);
                return false;
            }
            self.replaceBest(f);
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
                        i += 1; // every start position, not just aligned ones (§6)
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

        /// P4: re-expression (design §6, v2.1). An integer pair is a
        /// non-skip position immediately followed by a skip position
        /// (the annotation layout of §4.1). For each pair not already
        /// in the full-domain class, try rewriting it as
        /// (class 3, current rank): the generated value is unchanged,
        /// but its rank becomes reachable by P3 descent.
        fn passReexpress(self: *@This()) !bool {
            var changed_any = false;
            var i: usize = 0;
            while (i + 1 < self.best.len) : (i += 1) {
                if (self.best_skips[i] or !self.best_skips[i + 1]) continue;
                if (self.best[i].value == 3) continue;
                var cand = try self.candidateValues();
                defer cand.deinit(self.allocator);
                cand.items[i] = 3;
                cand.items[i + 1] = self.best_keys[i];
                if (try self.tryRatchet(cand.items, i)) changed_any = true;
            }
            return changed_any;
        }

        fn round(self: *@This()) !bool {
            var changed = false;
            if (try self.passChunks()) changed = true;
            if (try self.passReexpress()) changed = true;
            if (try self.passZero()) changed = true;
            if (try self.passDecrease()) changed = true;
            return changed;
        }
    };

    // Copies are made sequentially with explicit frees on the error
    // paths: an errdefer on a value whose ownership later moves into
    // `inner` would double-free (the M3 review lesson).
    const best_copy = try result_allocator.dupe(Choice, initial);
    const best_keys_copy = result_allocator.dupe(u64, initial_keys) catch |err| {
        result_allocator.free(best_copy);
        return err;
    };
    const best_skips_copy = result_allocator.dupe(bool, initial_skips) catch |err| {
        result_allocator.free(best_copy);
        result_allocator.free(best_keys_copy);
        return err;
    };
    const best_display_copy = result_allocator.dupe(u8, initial_display) catch |err| {
        result_allocator.free(best_copy);
        result_allocator.free(best_keys_copy);
        result_allocator.free(best_skips_copy);
        return err;
    };
    const best_spans_copy = result_allocator.dupe(Span, initial_spans) catch |err| {
        result_allocator.free(best_copy);
        result_allocator.free(best_keys_copy);
        result_allocator.free(best_skips_copy);
        result_allocator.free(best_display_copy);
        return err;
    };
    var inner = Inner{
        .allocator = result_allocator,
        .generator = generator,
        .property = property,
        .limits = limits,
        .budget = budget,
        .best = best_copy,
        .best_keys = best_keys_copy,
        .best_skips = best_skips_copy,
        .best_spans = best_spans_copy,
        .best_display = best_display_copy,
    };
    const outcome: ShrinkOutcome = blk: {
        while (true) {
            const changed = inner.round() catch |err| {
                result_allocator.free(inner.best);
                result_allocator.free(inner.best_keys);
                result_allocator.free(inner.best_skips);
                result_allocator.free(inner.best_spans);
                result_allocator.free(inner.best_display);
                return err;
            };
            // Budget exhaustion outranks fixed_point: a round only
            // counts as complete when every candidate was actually
            // evaluated (the TLA+ model's priority rule).
            if (inner.exhausted) break :blk .budget_exhausted;
            if (!changed) break :blk .fixed_point;
        }
    };
    // Keys and skips are shrink-internal (design §6, v2.1); the
    // result carries only the choice sequence and the display.
    result_allocator.free(inner.best_keys);
    result_allocator.free(inner.best_skips);
    result_allocator.free(inner.best_spans);
    return .{
        .choices = inner.best,
        .value_display = inner.best_display,
        .evaluations = inner.evaluations,
        .outcome = outcome,
    };
}
