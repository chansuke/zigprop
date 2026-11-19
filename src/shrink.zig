//! Shrinking (design §6) and the shared attempt evaluator (§5, MF5).
//!
//! The predicate is P(C) = "replaying the choice sequence C fails
//! with the same Failure kind as the original" (design v0.3 §5.4,
//! D27; for a bool property the kind is always `returned_false`).
//! A candidate is accepted only when the key sequence of its
//! *re-recorded consumed* sequence is strictly shortlex-smaller
//! than the stored best (MF2, v2.1: keys are canonical — an integer
//! pair contributes its value's rank, so acceptance compares value
//! simplicity rather than class encodings). P4 (re-expression)
//! additionally accepts a key-equal lateral move that rewrites an
//! integer pair into the full-domain class so P3 can descend it.
//!
//! v0.3 round (design v0.3 §3.2, D22): P6 subtree promotion → P5
//! element deletion → P1 chunk deletion → P4 → P2 zero → P3
//! decrease; when that round changed nothing and budget remains,
//! P1b (chunk sizes 7, 6, 5, 3) runs as the expensive pass. P5 and
//! P6 build candidates from span annotations, but every new pass
//! replaces the best only through `tryAccept` (ordinary acceptance),
//! so a wrong or stale span cannot break soundness (§3.4).
//! Passes repeat until a full round, P1b included, changes nothing
//! (`fixed_point`) or the evaluation budget runs out
//! (`budget_exhausted`). After exhaustion every pass loop exits at
//! its head instead of building further candidates (§3.2 item 6).
//! Infrastructure errors abort the shrink and propagate.

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

/// The shrink passes (design §6 and v0.3 §3.2).
pub const ShrinkPass = enum { p1_chunks, p1b_chunks, p2_zero, p3_decrease, p4_reexpress, p5_delete, p6_promote };

/// Internal pass mask for ablation measurements (design v0.3 §8.2
/// T6/T7). Not part of the public API; the runner always uses the
/// full mask.
pub const ShrinkPassMask = struct {
    p1: bool = true,
    p1b: bool = true,
    p2: bool = true,
    p3: bool = true,
    p4: bool = true,
    p5: bool = true,
    p6: bool = true,
};

/// One acceptance, reported to the internal hook before the best is
/// replaced (design v0.3 §3.9). `lateral` marks P4's key-equal move;
/// every other acceptance must be strictly shortlex-smaller.
pub const AcceptEvent = struct {
    pass: ShrinkPass,
    lateral: bool,
    before_keys: []const u64,
    before_skips: []const bool,
    after_keys: []const u64,
    after_skips: []const bool,
    /// The failure kind of the accepted candidate (design v0.3 §5.4:
    /// always equal to the original failure's kind).
    failure: Failure,
};

// ---------------------------------------------------------------------
// Properties, cases and failure kinds (design v0.3 §5.2-§5.4, D27)
// ---------------------------------------------------------------------

/// Per-attempt information handed to a property. Passed by pointer so
/// later versions can add fields without changing the signature.
pub const Case = struct {
    /// The attempt arena (same lifetime as the generated value); use it
    /// for the system under test's scratch memory.
    allocator: Allocator,
};

/// The kind of a failure. Shrinking keeps it (D27): a candidate is
/// accepted only when it fails with an equal Failure.
pub const Failure = union(enum) {
    returned_false,
    /// Any error the property returned, whatever its name (§5.3).
    returned_error: anyerror,

    pub fn eql(a: Failure, b: Failure) bool {
        return switch (a) {
            .returned_false => b == .returned_false,
            .returned_error => |ea| switch (b) {
                .returned_error => |eb| ea == eb,
                .returned_false => false,
            },
        };
    }
};

pub fn Generator(comptime T: type) type {
    return *const fn (gen: *GenContext) anyerror!T;
}

pub fn GeneratorWith(comptime Ctx: type, comptime T: type) type {
    return *const fn (ctx: Ctx, gen: *GenContext) anyerror!T;
}

pub fn PropertyWith(comptime Ctx: type, comptime T: type) type {
    return *const fn (ctx: Ctx, case: *Case, value: T) anyerror!bool;
}

/// Adapts a plain `fn (T) bool` property to the general form; the
/// context is the property itself (design v0.3 §5.2).
pub fn BoolProperty(comptime T: type) type {
    return struct {
        pub const Ctx = *const fn (T) bool;
        pub fn property(p: Ctx, _: *Case, value: T) anyerror!bool {
            return p(value);
        }
    };
}

/// Adapts `checkCustom`'s pair (generator, plain property) to the
/// general form; the context carries both function pointers.
pub fn CustomProperty(comptime T: type) type {
    return struct {
        pub const Ctx = struct { property: *const fn (T) bool, generator: Generator(T) };
        pub fn property(c: Ctx, _: *Case, value: T) anyerror!bool {
            return c.property(value);
        }
        pub fn generator(c: Ctx, g: *GenContext) anyerror!T {
            return c.generator(g);
        }
    };
}

pub const AcceptHook = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, event: AcceptEvent) void,
};

/// Internal shrink options: the pass mask and the acceptance hook.
pub const ShrinkOptions = struct {
    passes: ShrinkPassMask = .{},
    on_accept: ?AcceptHook = null,
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
        /// The failure kind (design v0.3 §5.4).
        failure: Failure,
    },
};

/// Runs one generation + property evaluation against a prepared
/// Source and classifies the outcome (design §5, MF5). On a
/// confirmed failure the consumed sequence is copied into
/// result-owned storage before the attempt arena dies (MF9). No
/// display is formatted here: the runner regenerates it from the
/// final sequences (design v0.3 §5.5). A property error is a failure
/// (`returned_error`) whatever its name; it never propagates (§5.3).
pub fn evaluateAttempt(
    result_allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    property: PropertyWith(Ctx, T),
    src: *Source,
    attempt_allocator: Allocator,
    limits: Limits,
    exhaustion_is_discard: bool,
) !AttemptResult {
    var state: source.GenState = undefined;
    var gctx = source.genContextForTest(&state, src, attempt_allocator, limits);
    const value = (if (generator) |g| g(ctx, &gctx) else gen.generate(T, &gctx)) catch |err| {
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
    var case: Case = .{ .allocator = attempt_allocator };
    const failure: Failure = blk: {
        const ok = property(ctx, &case, value) catch |err| break :blk .{ .returned_error = err };
        if (ok) return .pass;
        break :blk .returned_false;
    };
    const choices = try result_allocator.dupe(Choice, src.recorded.items);
    errdefer result_allocator.free(choices);
    const keys = try result_allocator.dupe(u64, src.recorded_keys.items);
    errdefer result_allocator.free(keys);
    const skips = try result_allocator.dupe(bool, src.recorded_skip.items);
    errdefer result_allocator.free(skips);
    const spans = try result_allocator.dupe(Span, src.recorded_spans.items);
    return .{ .fail = .{ .choices = choices, .keys = keys, .skips = skips, .spans = spans, .failure = failure } };
}

pub const ShrinkResult = struct {
    /// The shrunk consumed sequence, owned by the result allocator.
    choices: []Choice,
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

/// Shrinks a `returned_false` failure of a plain `fn (T) bool`
/// property, starting without spans (internal convenience form).
pub fn shrink(
    result_allocator: Allocator,
    comptime T: type,
    generator: ?Generator(T),
    property: *const fn (T) bool,
    limits: Limits,
    budget: usize,
    initial: []const Choice,
    initial_keys: []const u64,
    initial_skips: []const bool,
) !ShrinkResult {
    return shrinkSpanned(result_allocator, T, generator, property, limits, budget, initial, initial_keys, initial_skips, &.{}, .{});
}

/// `shrink` with the initial sequence's span annotations (design
/// v0.3 §3.2) and the internal options (pass mask, acceptance hook).
pub fn shrinkSpanned(
    result_allocator: Allocator,
    comptime T: type,
    generator: ?Generator(T),
    property: *const fn (T) bool,
    limits: Limits,
    budget: usize,
    initial: []const Choice,
    initial_keys: []const u64,
    initial_skips: []const bool,
    initial_spans: []const Span,
    options: ShrinkOptions,
) !ShrinkResult {
    if (generator) |g| {
        const C = CustomProperty(T);
        return shrinkWith(result_allocator, T, C.Ctx, .{ .property = property, .generator = g }, C.generator, C.property, .returned_false, limits, budget, initial, initial_keys, initial_skips, initial_spans, options);
    }
    const B = BoolProperty(T);
    return shrinkWith(result_allocator, T, B.Ctx, property, null, B.property, .returned_false, limits, budget, initial, initial_keys, initial_skips, initial_spans, options);
}

/// The general shrinker (design §6, v0.3 §3): P(C) = "replaying C
/// fails with a Failure equal to `failure`" (D27). The runner uses
/// this form with default options; spans are metadata and never
/// affect acceptance.
pub fn shrinkWith(
    result_allocator: Allocator,
    comptime T: type,
    comptime Ctx: type,
    ctx: Ctx,
    generator: ?GeneratorWith(Ctx, T),
    property: PropertyWith(Ctx, T),
    failure: Failure,
    limits: Limits,
    budget: usize,
    initial: []const Choice,
    initial_keys: []const u64,
    initial_skips: []const bool,
    initial_spans: []const Span,
    options: ShrinkOptions,
) !ShrinkResult {
    const Inner = struct {
        allocator: Allocator,
        ctx: Ctx,
        generator: ?GeneratorWith(Ctx, T),
        property: PropertyWith(Ctx, T),
        /// The original failure kind every acceptance must keep.
        failure: Failure,
        limits: Limits,
        budget: usize,
        options: ShrinkOptions,
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
            const result = try evaluateAttempt(self.allocator, T, Ctx, self.ctx, self.generator, self.property, &src, aa, self.limits, false);
            switch (result) {
                .fail => |f| {
                    // P(C) is "fails with the same kind" (design v0.3
                    // §5.4, D27). Checking it here covers every
                    // acceptance path, P4's lateral move included.
                    if (!f.failure.eql(self.failure)) {
                        self.freeFail(f);
                        return null;
                    }
                    return f;
                },
                else => return null,
            }
        }

        fn freeFail(self: *@This(), f: Fail) void {
            self.allocator.free(f.choices);
            self.allocator.free(f.keys);
            self.allocator.free(f.skips);
            self.allocator.free(f.spans);
        }

        fn replaceBest(self: *@This(), f: Fail) void {
            self.allocator.free(self.best);
            self.allocator.free(self.best_keys);
            self.allocator.free(self.best_skips);
            self.allocator.free(self.best_spans);
            self.best = f.choices;
            self.best_keys = f.keys;
            self.best_skips = f.skips;
            self.best_spans = f.spans;
        }

        /// Tries one candidate value sequence; on acceptance the
        /// stored best is replaced by the re-recorded consumed
        /// sequence. Acceptance requires the candidate's key
        /// sequence to be strictly shortlex-smaller (design §6,
        /// v2.1). Returns whether the best changed. This is the only
        /// acceptance path of every pass except P4's lateral move
        /// (design v0.3 §3.3): P5, P6 and P1b use it unchanged.
        fn tryAccept(self: *@This(), values: []const u64, pass: ShrinkPass) !bool {
            if (self.exhausted) return false;
            const f = (try self.evalCandidate(values)) orelse return false;
            if (!keyShortlexLess(f.keys, f.skips, self.best_keys, self.best_skips)) {
                self.freeFail(f);
                return false;
            }
            self.notify(pass, false, f);
            self.replaceBest(f);
            return true;
        }

        /// Reports an acceptance to the internal hook (design v0.3
        /// §3.9) before the best is replaced.
        fn notify(self: *@This(), pass: ShrinkPass, lateral: bool, f: Fail) void {
            const hook = self.options.on_accept orelse return;
            hook.call(hook.context, .{
                .pass = pass,
                .lateral = lateral,
                .before_keys = self.best_keys,
                .before_skips = self.best_skips,
                .after_keys = f.keys,
                .after_skips = f.skips,
                .failure = f.failure,
            });
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
            self.notify(.p4_reexpress, true, f);
            self.replaceBest(f);
            return true;
        }

        fn candidateValues(self: *@This()) !std.ArrayList(u64) {
            var list: std.ArrayList(u64) = .empty;
            errdefer list.deinit(self.allocator);
            for (self.best) |c| try list.append(self.allocator, c.value);
            return list;
        }

        /// Deletes the chunk [i, i + size) at every start position,
        /// rescanning the new sequence at the same size after each
        /// acceptance (design §6).
        fn chunkSize(self: *@This(), size: usize, pass: ShrinkPass) !bool {
            var changed_any = false;
            var i: usize = 0;
            while (i + size <= self.best.len) {
                if (self.exhausted) break;
                var cand: std.ArrayList(u64) = .empty;
                defer cand.deinit(self.allocator);
                for (self.best[0..i]) |c| try cand.append(self.allocator, c.value);
                for (self.best[i + size ..]) |c| try cand.append(self.allocator, c.value);
                if (try self.tryAccept(cand.items, pass)) {
                    changed_any = true;
                    i = 0; // rescan the new sequence at this size
                } else {
                    i += 1; // every start position, not just aligned ones (§6)
                }
            }
            return changed_any;
        }

        /// P1: chunk deletion. Chunk sizes start at half of the
        /// largest power of two ≤ len and halve down to 1 (design §6).
        fn passChunks(self: *@This()) !bool {
            var changed_any = false;
            if (self.best.len == 0) return false;
            var chunk: usize = @max(1, highestPow2(@intCast(self.best.len)) / 2);
            while (true) {
                if (self.exhausted) break;
                if (try self.chunkSize(chunk, .p1_chunks)) changed_any = true;
                if (chunk == 1) break;
                chunk /= 2;
            }
            return changed_any;
        }

        /// P1b, the expensive pass (design v0.3 §3.2 item 4, D17):
        /// chunk deletion with the non-power-of-two sizes {3, 5, 6, 7}
        /// not above len, largest first like P1. Runs only when a
        /// round changed nothing.
        fn passChunksExtra(self: *@This()) !bool {
            var changed_any = false;
            for ([_]usize{ 7, 6, 5, 3 }) |size| {
                if (self.exhausted) break;
                if (size > self.best.len) continue;
                if (try self.chunkSize(size, .p1b_chunks)) changed_any = true;
            }
            return changed_any;
        }

        /// P2: zero each non-zero element in turn.
        fn passZero(self: *@This()) !bool {
            var changed_any = false;
            var i: usize = 0;
            while (i < self.best.len) : (i += 1) {
                if (self.exhausted) break;
                if (self.best[i].value == 0) continue;
                var cand = try self.candidateValues();
                defer cand.deinit(self.allocator);
                cand.items[i] = 0;
                if (try self.tryAccept(cand.items, .p2_zero)) changed_any = true;
            }
            return changed_any;
        }

        /// P3: for each element, greedily subtract powers of two,
        /// restarting the delta scan after every acceptance.
        fn passDecrease(self: *@This()) !bool {
            var changed_any = false;
            var i: usize = 0;
            while (i < self.best.len) {
                if (self.exhausted) break;
                if (self.best[i].value == 0) {
                    i += 1;
                    continue;
                }
                var improved = true;
                while (improved and i < self.best.len and self.best[i].value != 0) {
                    improved = false;
                    var delta = highestPow2(self.best[i].value);
                    while (true) {
                        if (self.exhausted) break;
                        var cand = try self.candidateValues();
                        defer cand.deinit(self.allocator);
                        cand.items[i] = self.best[i].value - delta;
                        if (try self.tryAccept(cand.items, .p3_decrease)) {
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
                if (self.exhausted) break;
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

        /// P6: subtree promotion (design v0.3 §3.2 item 3, D20). For
        /// each occurrence span X (pre-order) and each nearest
        /// same-type occurrence Y inside X (no same-type occurrence
        /// between them), try `values[0..X.start] ++ values[Y] ++
        /// values[X.end..]`. One level per acceptance; after an
        /// acceptance the same X position is retried against the new
        /// best (the prefix before X.start is unchanged, so the span
        /// index of X is too).
        fn passPromote(self: *@This()) !bool {
            var changed_any = false;
            var i: usize = 0;
            while (i < self.best_spans.len) {
                if (self.exhausted) break;
                const x = self.best_spans[i];
                const x_id = switch (x.info) {
                    .occurrence => |o| o.type_id,
                    .element => {
                        i += 1;
                        continue;
                    },
                };
                var accepted = false;
                // Positions below `inside_until` belong to a nearest Y
                // already tried; deeper same-type occurrences there
                // are not nearest to X.
                var inside_until: usize = 0;
                var j = i + 1;
                while (j < self.best_spans.len and self.best_spans[j].start < x.end) : (j += 1) {
                    if (self.exhausted) break;
                    const y = self.best_spans[j];
                    if (y.start < inside_until) continue;
                    const y_id = switch (y.info) {
                        .occurrence => |o| o.type_id,
                        .element => continue,
                    };
                    if (y_id != x_id or y.end > x.end) continue;
                    inside_until = y.end;
                    if (y.end - y.start == x.end - x.start) continue; // same extent: no change
                    var cand: std.ArrayList(u64) = .empty;
                    defer cand.deinit(self.allocator);
                    for (self.best[0..x.start]) |c| try cand.append(self.allocator, c.value);
                    for (self.best[y.start..y.end]) |c| try cand.append(self.allocator, c.value);
                    for (self.best[x.end..]) |c| try cand.append(self.allocator, c.value);
                    if (try self.tryAccept(cand.items, .p6_promote)) {
                        changed_any = true;
                        accepted = true;
                        break;
                    }
                }
                if (!accepted) i += 1;
            }
            return changed_any;
        }

        /// The element spans of the slice whose length draw is at
        /// `length_pos`, counted, or the k-th of them (in order).
        fn elementCount(self: *@This(), length_pos: usize) usize {
            var count: usize = 0;
            for (self.best_spans) |sp| switch (sp.info) {
                .element => |el| if (el.length_pos == length_pos) {
                    count += 1;
                },
                .occurrence => {},
            };
            return count;
        }

        fn elementAt(self: *@This(), length_pos: usize, k: usize) ?Span {
            var seen: usize = 0;
            for (self.best_spans) |sp| switch (sp.info) {
                .element => |el| if (el.length_pos == length_pos) {
                    if (seen == k) return sp;
                    seen += 1;
                },
                .occurrence => {},
            };
            return null;
        }

        /// P5: element deletion paired with the length draw (design
        /// v0.3 §3.2 item 2, D19). For each slice (by ascending length
        /// draw position ℓ) with length v ≥ 1, try each element span
        /// [s, e) from the last to the first: set position ℓ to v − 1
        /// and remove [s, e). After an acceptance the same slice is
        /// rescanned from its last element with the new best's spans
        /// (the prefix up to ℓ is unchanged, so ℓ still names it).
        fn passDelete(self: *@This()) !bool {
            var changed_any = false;
            var next_pos: usize = 0;
            outer: while (true) {
                if (self.exhausted) break;
                var found: ?usize = null;
                for (self.best_spans) |sp| switch (sp.info) {
                    .element => |el| if (el.length_pos >= next_pos and (found == null or el.length_pos < found.?)) {
                        found = el.length_pos;
                    },
                    .occurrence => {},
                };
                const lp = found orelse break;
                next_pos = lp + 1;
                var k = self.elementCount(lp);
                while (k > 0) {
                    if (self.exhausted) break :outer;
                    if (lp >= self.best.len or self.best[lp].value == 0) break;
                    const sp = self.elementAt(lp, k - 1) orelse break;
                    var cand: std.ArrayList(u64) = .empty;
                    defer cand.deinit(self.allocator);
                    for (self.best[0..sp.start], 0..) |c, pos| {
                        try cand.append(self.allocator, if (pos == lp) c.value - 1 else c.value);
                    }
                    for (self.best[sp.end..]) |c| try cand.append(self.allocator, c.value);
                    if (try self.tryAccept(cand.items, .p5_delete)) {
                        changed_any = true;
                        k = self.elementCount(lp);
                    } else {
                        k -= 1;
                    }
                }
            }
            return changed_any;
        }

        /// One round (design v0.3 §3.2 item 5, D22): P6 → P5 → P1 →
        /// P4 → P2 → P3; P1b only when that changed nothing and budget
        /// remains. Masked-off passes are skipped (ablation only).
        fn round(self: *@This()) !bool {
            var changed = false;
            const m = self.options.passes;
            if (m.p6 and try self.passPromote()) changed = true;
            if (m.p5 and try self.passDelete()) changed = true;
            if (m.p1 and try self.passChunks()) changed = true;
            if (m.p4 and try self.passReexpress()) changed = true;
            if (m.p2 and try self.passZero()) changed = true;
            if (m.p3 and try self.passDecrease()) changed = true;
            if (!changed and !self.exhausted and m.p1b) {
                if (try self.passChunksExtra()) changed = true;
            }
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
    const best_spans_copy = result_allocator.dupe(Span, initial_spans) catch |err| {
        result_allocator.free(best_copy);
        result_allocator.free(best_keys_copy);
        result_allocator.free(best_skips_copy);
        return err;
    };
    var inner = Inner{
        .allocator = result_allocator,
        .ctx = ctx,
        .generator = generator,
        .property = property,
        .failure = failure,
        .limits = limits,
        .budget = budget,
        .options = options,
        .best = best_copy,
        .best_keys = best_keys_copy,
        .best_skips = best_skips_copy,
        .best_spans = best_spans_copy,
    };
    const outcome: ShrinkOutcome = blk: {
        while (true) {
            const changed = inner.round() catch |err| {
                result_allocator.free(inner.best);
                result_allocator.free(inner.best_keys);
                result_allocator.free(inner.best_skips);
                result_allocator.free(inner.best_spans);
                return err;
            };
            // Budget exhaustion outranks fixed_point: a round only
            // counts as complete when every candidate was actually
            // evaluated (the TLA+ model's priority rule).
            if (inner.exhausted) break :blk .budget_exhausted;
            if (!changed) break :blk .fixed_point;
        }
    };
    // Keys, skips and spans are shrink-internal (design §6, v2.1); the
    // result carries only the choice sequence. The display is
    // regenerated by the runner (design v0.3 §5.5).
    result_allocator.free(inner.best_keys);
    result_allocator.free(inner.best_skips);
    result_allocator.free(inner.best_spans);
    return .{
        .choices = inner.best,
        .evaluations = inner.evaluations,
        .outcome = outcome,
    };
}
