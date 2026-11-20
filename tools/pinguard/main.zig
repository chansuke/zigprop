//! zigprop-pinguard: classifies golden-pin diffs between two revisions
//! (verification pipeline plan §2-4 (a)).
//!
//! Usage: zigprop-pinguard --base-label <s> --head-label <s>
//!          --base-gen <file> --head-gen <file> --base-doc <file> --head-doc <file>
//!          (--pins <path> <base file> <head file>)...
//!
//! `zig build pin-guard -Dpin-base=<rev> [-Dpin-head=<rev>]` supplies the
//! files (`git show <rev>:<path>`, or the working tree for the head).
//!
//! Pins: in a pin file, every `const name = [_]ReplayPin(T){ ... }` or
//! `RandomPin(T)` table entry (named `name#index`), and every
//! `test "golden..."` block that builds a Source itself (initRandom: a
//! random pin; initReplay: a replay pin; named by the test name).
//!
//! Classes of a changed pin:
//!   bound-only      a replay pin where only numbers after `.bound =` changed: allowed
//!   seed            a random pin changed: allowed only if docs/verification.md changed
//!   replay-meaning  any other replay-pin change: allowed only if generator_version grew

const std = @import("std");
const Token = std.zig.Token;
const Allocator = std.mem.Allocator;

pub const Kind = enum { replay, random };

const Tok = struct { tag: Token.Tag, text: []const u8 };

const Field = struct { name: []const u8, toks: []const Tok };

pub const Pin = struct {
    name: []const u8,
    kind: Kind,
    line: usize,
    fields: []const Field,

    fn field(p: Pin, name: []const u8) ?Field {
        for (p.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
};

pub const Class = enum { @"bound-only", seed, @"replay-meaning", added };

pub const Change = struct {
    path: []const u8,
    pin: []const u8,
    class: Class,
    line: usize,
    /// The changed fields (`removed` when the pin is gone).
    fields: []const []const u8,
};

/// Old bound -> new bound, counted over every bound token that changed.
pub const BoundDelta = struct { old: []const u8, new: []const u8, count: usize };

fn tokenize(arena: Allocator, src: [:0]const u8) ![]const Tok {
    var out: std.ArrayList(Tok) = .empty;
    var tz = std.zig.Tokenizer.init(src);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) continue;
        try out.append(arena, .{ .tag = t.tag, .text = src[t.loc.start..t.loc.end] });
    }
    return out.items;
}

/// Token positions as lines, for messages.
fn tokenLines(arena: Allocator, src: [:0]const u8) ![]const usize {
    var out: std.ArrayList(usize) = .empty;
    var tz = std.zig.Tokenizer.init(src);
    var line: usize = 1;
    var last: usize = 0;
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) continue;
        line += std.mem.count(u8, src[last..t.loc.start], "\n");
        last = t.loc.start;
        try out.append(arena, line);
    }
    return out.items;
}

fn closing(toks: []const Tok, open: usize) usize {
    const o = toks[open].tag;
    const c: Token.Tag = switch (o) {
        .l_brace => .r_brace,
        .l_paren => .r_paren,
        .l_bracket => .r_bracket,
        else => unreachable,
    };
    var depth: usize = 0;
    for (toks[open..], open..) |t, i| {
        if (t.tag == o) depth += 1;
        if (t.tag == c) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return toks.len - 1;
}

fn isOpen(tag: Token.Tag) bool {
    return tag == .l_brace or tag == .l_paren or tag == .l_bracket;
}

/// `.name = expr, ...` inside an anonymous struct literal `[open, close]`.
fn splitFields(arena: Allocator, toks: []const Tok, open: usize, close: usize) ![]const Field {
    var out: std.ArrayList(Field) = .empty;
    var i = open + 1;
    while (i + 2 < close) {
        if (toks[i].tag != .period or toks[i + 1].tag != .identifier or toks[i + 2].tag != .equal) {
            i += 1;
            continue;
        }
        const start = i + 3;
        var j = start;
        while (j < close and toks[j].tag != .comma) : (j += 1) {
            if (isOpen(toks[j].tag)) j = closing(toks, j);
        }
        try out.append(arena, .{ .name = toks[i + 1].text, .toks = toks[start..j] });
        i = j + 1;
    }
    return out.items;
}

/// The pins of one file, in source order.
pub fn extractPins(arena: Allocator, src: [:0]const u8) ![]const Pin {
    const toks = try tokenize(arena, src);
    const lines = try tokenLines(arena, src);
    var pins: std.ArrayList(Pin) = .empty;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        // const name = [_]ReplayPin(T){ .{...}, ... };
        if (toks[i].tag == .keyword_const and i + 7 < toks.len and toks[i + 1].tag == .identifier and
            toks[i + 2].tag == .equal and toks[i + 3].tag == .l_bracket and std.mem.eql(u8, toks[i + 4].text, "_") and
            toks[i + 5].tag == .r_bracket and toks[i + 6].tag == .identifier and toks[i + 7].tag == .l_paren)
        {
            const kind: Kind = if (std.mem.eql(u8, toks[i + 6].text, "ReplayPin"))
                .replay
            else if (std.mem.eql(u8, toks[i + 6].text, "RandomPin"))
                .random
            else
                continue;
            const open = closing(toks, i + 7) + 1;
            if (open >= toks.len or toks[open].tag != .l_brace) continue;
            const close = closing(toks, open);
            var index: usize = 0;
            var k = open + 1;
            while (k < close) : (k += 1) {
                if (toks[k].tag != .period or toks[k + 1].tag != .l_brace) continue;
                const entry_close = closing(toks, k + 1);
                try pins.append(arena, .{
                    .name = try std.fmt.allocPrint(arena, "{s}#{d}", .{ toks[i + 1].text, index }),
                    .kind = kind,
                    .line = lines[k],
                    .fields = try splitFields(arena, toks, k + 1, entry_close),
                });
                index += 1;
                k = entry_close;
            }
            i = close;
            continue;
        }
        // test "golden..." { ... initRandom / initReplay ... }
        if (toks[i].tag == .keyword_test and i + 2 < toks.len and toks[i + 1].tag == .string_literal and
            std.mem.startsWith(u8, toks[i + 1].text, "\"golden") and toks[i + 2].tag == .l_brace)
        {
            const close = closing(toks, i + 2);
            const body = toks[i + 3 .. close];
            var random = false;
            var replay = false;
            for (body) |t| {
                if (t.tag != .identifier) continue;
                if (std.mem.eql(u8, t.text, "initRandom")) random = true;
                if (std.mem.eql(u8, t.text, "initReplay")) replay = true;
            }
            if (random or replay) {
                const fields = try arena.alloc(Field, 1);
                fields[0] = .{ .name = "body", .toks = body };
                try pins.append(arena, .{
                    .name = toks[i + 1].text,
                    .kind = if (random) .random else .replay,
                    .line = lines[i],
                    .fields = fields,
                });
            }
            i = close;
        }
    }
    return pins.items;
}

fn sameToks(a: []const Tok, b: []const Tok) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.tag != y.tag or !std.mem.eql(u8, x.text, y.text)) return false;
    return true;
}

/// Token j is the number in `.bound = <n>`.
fn isBoundNumber(toks: []const Tok, j: usize) bool {
    return toks[j].tag == .number_literal and j >= 3 and toks[j - 1].tag == .equal and
        toks[j - 2].tag == .identifier and std.mem.eql(u8, toks[j - 2].text, "bound") and toks[j - 3].tag == .period;
}

fn recordBound(arena: Allocator, bounds: *std.ArrayList(BoundDelta), old: []const u8, new: []const u8) !void {
    for (bounds.items) |*d| {
        if (std.mem.eql(u8, d.old, old) and std.mem.eql(u8, d.new, new)) {
            d.count += 1;
            return;
        }
    }
    try bounds.append(arena, .{ .old = old, .new = new, .count = 1 });
}

/// Classifies every changed pin of one file.
pub fn comparePins(arena: Allocator, path: []const u8, base: []const Pin, head: []const Pin, changes: *std.ArrayList(Change), bounds: *std.ArrayList(BoundDelta)) !void {
    for (head) |h| {
        const b = for (base) |p| {
            if (std.mem.eql(u8, p.name, h.name)) break p;
        } else {
            try changes.append(arena, .{ .path = path, .pin = h.name, .class = .added, .line = h.line, .fields = &.{} });
            continue;
        };
        var changed: std.ArrayList([]const u8) = .empty;
        var meaning = false;
        var pin_bounds: std.ArrayList(BoundDelta) = .empty;
        for (h.fields) |hf| {
            const bf = b.field(hf.name) orelse {
                try changed.append(arena, hf.name);
                meaning = true;
                continue;
            };
            if (sameToks(bf.toks, hf.toks)) continue;
            try changed.append(arena, hf.name);
            if (bf.toks.len != hf.toks.len) {
                meaning = true;
                continue;
            }
            for (bf.toks, hf.toks, 0..) |x, y, j| {
                if (x.tag == y.tag and std.mem.eql(u8, x.text, y.text)) continue;
                if (isBoundNumber(bf.toks, j) and isBoundNumber(hf.toks, j)) {
                    try recordBound(arena, &pin_bounds, x.text, y.text);
                } else meaning = true;
            }
        }
        for (b.fields) |bf| if (h.field(bf.name) == null) {
            try changed.append(arena, bf.name);
            meaning = true;
        };
        if (changed.items.len == 0) continue;
        const class: Class = switch (h.kind) {
            .random => .seed,
            .replay => if (meaning) .@"replay-meaning" else .@"bound-only",
        };
        if (class == .@"bound-only") for (pin_bounds.items) |d| {
            for (0..d.count) |_| try recordBound(arena, bounds, d.old, d.new);
        };
        try changes.append(arena, .{ .path = path, .pin = h.name, .class = class, .line = h.line, .fields = changed.items });
    }
    for (base) |b| {
        const kept = for (head) |h| {
            if (std.mem.eql(u8, h.name, b.name)) break true;
        } else false;
        if (kept) continue;
        try changes.append(arena, .{
            .path = path,
            .pin = b.name,
            .class = if (b.kind == .random) .seed else .@"replay-meaning",
            .line = b.line,
            .fields = &.{"removed"},
        });
    }
}

/// `pub const generator_version: u32 = N;` in src/gen.zig.
pub fn generatorVersion(arena: Allocator, src: [:0]const u8) !u64 {
    const toks = try tokenize(arena, src);
    for (toks, 0..) |t, i| {
        if (t.tag != .identifier or !std.mem.eql(u8, t.text, "generator_version")) continue;
        if (i == 0 or toks[i - 1].tag != .keyword_const) continue;
        var j = i + 1;
        while (j < toks.len and toks[j].tag != .equal) : (j += 1) {}
        if (j + 1 < toks.len and toks[j + 1].tag == .number_literal)
            return std.fmt.parseInt(u64, toks[j + 1].text, 0);
    }
    return error.NoGeneratorVersion;
}

/// Which classes are allowed, given the version bump and the doc change.
pub fn allowed(class: Class, version_bumped: bool, doc_changed: bool) bool {
    return switch (class) {
        .@"bound-only", .added => true,
        .seed => doc_changed,
        .@"replay-meaning" => version_bumped,
    };
}

fn printChange(c: Change) void {
    std.debug.print("  {s}:{d} {s} (", .{ c.path, c.line, c.pin });
    for (c.fields, 0..) |f, i| std.debug.print("{s}{s}", .{ if (i > 0) ", " else "", f });
    std.debug.print(")\n", .{});
}

fn printViolation(c: Change, base_v: u64, head_v: u64) void {
    var fields_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&fields_buf);
    for (c.fields, 0..) |f, i| w.print("{s}`{s}`", .{ if (i > 0) ", " else "", f }) catch break;
    const fields = w.buffered();
    switch (c.class) {
        .@"replay-meaning" => std.debug.print(
            \\[zigprop-pinguard/replay-meaning] {s}:{d}
            \\violation: replay pin `{s}` changed in {s} without a generator_version bump (base {d}, head {d}).
            \\reason:    A changed replay meaning must bump `generator_version` (design v0.3 §7.1, D16); a distribution-only change may touch bounds only (Amendment A1).
            \\fix:       If the replay meaning changed on purpose, bump generator_version in src/gen.zig and record it in docs/verification.md; otherwise restore the pin and fix the generator.
            \\example:   src/gen.zig: `pub const generator_version: u32 = {d};`
            \\allow:     none: pin-guard has no allow comment; the version bump is the record.
            \\
            \\
        , .{ c.path, c.line, c.pin, fields, base_v, head_v, base_v + 1 }),
        .seed => std.debug.print(
            \\[zigprop-pinguard/seed] {s}:{d}
            \\violation: random pin `{s}` changed in {s}, but docs/verification.md did not change.
            \\reason:    Seed compatibility is not promised across versions (design v0.3 D16), so a re-record is allowed, but only with a record of it; an unrecorded re-record hides a generation change (verification pipeline plan §2-4 (a)).
            \\fix:       Review the diff and record the re-recorded pins (which, and why) in docs/verification.md in the same change.
            \\example:   docs/verification.md: "re-recorded the (S) pins of tests/meta10.zig (13) after the M6 distribution change"
            \\allow:     none: pin-guard has no allow comment; the verification.md record is the record.
            \\
            \\
        , .{ c.path, c.line, c.pin, fields }),
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var base_label: []const u8 = "base";
    var head_label: []const u8 = "head";
    var gen_files: [2][]const u8 = .{ "", "" };
    var doc_files: [2][]const u8 = .{ "", "" };
    const PinFiles = struct { path: []const u8, base: []const u8, head: []const u8 };
    var pin_files: std.ArrayList(PinFiles) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--pins") and i + 3 < args.len) {
            try pin_files.append(arena, .{ .path = args[i + 1], .base = args[i + 2], .head = args[i + 3] });
            i += 3;
            continue;
        }
        if (i + 1 >= args.len) return error.BadArguments;
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--base-label")) base_label = v else if (std.mem.eql(u8, a, "--head-label")) head_label = v else if (std.mem.eql(u8, a, "--base-gen")) gen_files[0] = v else if (std.mem.eql(u8, a, "--head-gen")) gen_files[1] = v else if (std.mem.eql(u8, a, "--base-doc")) doc_files[0] = v else if (std.mem.eql(u8, a, "--head-doc")) doc_files[1] = v else return error.BadArguments;
    }
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(1 << 26);
    const base_v = try generatorVersion(arena, try cwd.readFileAllocOptions(io, gen_files[0], arena, limit, .of(u8), 0));
    const head_v = try generatorVersion(arena, try cwd.readFileAllocOptions(io, gen_files[1], arena, limit, .of(u8), 0));
    const doc_changed = !std.mem.eql(
        u8,
        try cwd.readFileAlloc(io, doc_files[0], arena, limit),
        try cwd.readFileAlloc(io, doc_files[1], arena, limit),
    );
    const bumped = head_v > base_v;

    var changes: std.ArrayList(Change) = .empty;
    var bounds: std.ArrayList(BoundDelta) = .empty;
    for (pin_files.items) |pf| {
        const base = try extractPins(arena, try cwd.readFileAllocOptions(io, pf.base, arena, limit, .of(u8), 0));
        const head = try extractPins(arena, try cwd.readFileAllocOptions(io, pf.head, arena, limit, .of(u8), 0));
        std.debug.print("pin-guard: {s}: {d} pins at base, {d} at head\n", .{ pf.path, base.len, head.len });
        try comparePins(arena, pf.path, base, head, &changes, &bounds);
    }

    std.debug.print("pin-guard: base {s} (generator_version {d}), head {s} (generator_version {d}); docs/verification.md {s}\n", .{
        base_label, base_v, head_label, head_v, if (doc_changed) "changed" else "unchanged",
    });
    var errors: usize = 0;
    for (std.enums.values(Class)) |class| {
        var n: usize = 0;
        for (changes.items) |c| if (c.class == class) {
            n += 1;
        };
        if (n == 0) continue;
        const ok = allowed(class, bumped, doc_changed);
        std.debug.print("{s}: {d} pin(s), {s}\n", .{ @tagName(class), n, if (ok) "allowed" else "NOT allowed" });
        for (changes.items) |c| if (c.class == class) printChange(c);
        if (class == .@"bound-only") for (bounds.items) |d| std.debug.print("  bound {s} -> {s}: {d} choice(s)\n", .{ d.old, d.new, d.count });
        if (!ok) errors += n;
    }
    std.debug.print("\n", .{});
    for (changes.items) |c| if (!allowed(c.class, bumped, doc_changed)) printViolation(c, base_v, head_v);
    std.debug.print("pin-guard: {d} changed pin(s), {d} error(s)\n", .{ changes.items.len, errors });
    if (errors > 0) std.process.exit(1);
}

// ---------------------------------------------------------------------
// Tests: one per class, on small pin files.

const pin_base =
    \\const replay_u8 = [_]ReplayPin(u8){
    \\    .{ .values = &.{ 2, 7 }, .value = 7, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 7 } }, .keys = &.{ 7, 7 }, .skips = &.{ false, true }, .consumed = 2 },
    \\};
    \\const random_u8 = [_]RandomPin(u8){
    \\    .{ .seed = 1, .value = 9, .choices = &.{.{ .bound = 4, .value = 0 }}, .keys = &.{9}, .skips = &.{false} },
    \\};
    \\test "golden: u8 at seed 1" {
    \\    var src = Source.initRandom(a, deriveSeed(1, 0), 100);
    \\    try expectEqual(9, v);
    \\}
;

fn changesOf(arena: Allocator, base_src: [:0]const u8, head_src: [:0]const u8) ![]const Change {
    var changes: std.ArrayList(Change) = .empty;
    var bounds: std.ArrayList(BoundDelta) = .empty;
    try comparePins(arena, "t.zig", try extractPins(arena, base_src), try extractPins(arena, head_src), &changes, &bounds);
    return changes.items;
}

fn expectClasses(expected: []const Class, head_src: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cs = try changesOf(arena.allocator(), pin_base, head_src);
    errdefer for (cs) |c| std.debug.print("{s} {s}\n", .{ c.pin, @tagName(c.class) });
    try std.testing.expectEqual(expected.len, cs.len);
    for (expected, cs) |e, c| try std.testing.expectEqual(e, c.class);
}

test "pins: tables and golden test blocks are extracted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pins = try extractPins(arena.allocator(), pin_base);
    try std.testing.expectEqual(@as(usize, 3), pins.len);
    try std.testing.expectEqualStrings("replay_u8#0", pins[0].name);
    try std.testing.expectEqual(Kind.replay, pins[0].kind);
    try std.testing.expectEqual(@as(usize, 6), pins[0].fields.len);
    try std.testing.expectEqualStrings("random_u8#0", pins[1].name);
    try std.testing.expectEqual(Kind.random, pins[1].kind);
    try std.testing.expectEqualStrings("\"golden: u8 at seed 1\"", pins[2].name);
    try std.testing.expectEqual(Kind.random, pins[2].kind);
    try std.testing.expectEqual(@as(usize, 7), pins[2].line);
}

test "pins: an unchanged file has no changes" {
    try expectClasses(&.{}, pin_base);
}

test "pins: only a bound changed is bound-only" {
    try expectClasses(&.{.@"bound-only"},
        \\const replay_u8 = [_]ReplayPin(u8){
        \\    .{ .values = &.{ 2, 7 }, .value = 7, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 4294967296, .value = 7 } }, .keys = &.{ 7, 7 }, .skips = &.{ false, true }, .consumed = 2 },
        \\};
        \\const random_u8 = [_]RandomPin(u8){
        \\    .{ .seed = 1, .value = 9, .choices = &.{.{ .bound = 4, .value = 0 }}, .keys = &.{9}, .skips = &.{false} },
        \\};
        \\test "golden: u8 at seed 1" {
        \\    var src = Source.initRandom(a, deriveSeed(1, 0), 100);
        \\    try expectEqual(9, v);
        \\}
    );
}

test "pins: a changed key or a choice value is a replay-meaning change" {
    try expectClasses(&.{.@"replay-meaning"},
        \\const replay_u8 = [_]ReplayPin(u8){
        \\    .{ .values = &.{ 2, 7 }, .value = 7, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 7 } }, .keys = &.{ 8, 7 }, .skips = &.{ false, true }, .consumed = 2 },
        \\};
        \\const random_u8 = [_]RandomPin(u8){
        \\    .{ .seed = 1, .value = 9, .choices = &.{.{ .bound = 4, .value = 0 }}, .keys = &.{9}, .skips = &.{false} },
        \\};
        \\test "golden: u8 at seed 1" {
        \\    var src = Source.initRandom(a, deriveSeed(1, 0), 100);
        \\    try expectEqual(9, v);
        \\}
    );
    try expectClasses(&.{.@"replay-meaning"},
        \\const replay_u8 = [_]ReplayPin(u8){
        \\    .{ .values = &.{ 2, 7 }, .value = 7, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 8 } }, .keys = &.{ 7, 7 }, .skips = &.{ false, true }, .consumed = 2 },
        \\};
        \\const random_u8 = [_]RandomPin(u8){
        \\    .{ .seed = 1, .value = 9, .choices = &.{.{ .bound = 4, .value = 0 }}, .keys = &.{9}, .skips = &.{false} },
        \\};
        \\test "golden: u8 at seed 1" {
        \\    var src = Source.initRandom(a, deriveSeed(1, 0), 100);
        \\    try expectEqual(9, v);
        \\}
    );
}

test "pins: random pins and seeded golden tests are seed changes; new pins are additions" {
    try expectClasses(&.{ .seed, .added, .seed },
        \\const replay_u8 = [_]ReplayPin(u8){
        \\    .{ .values = &.{ 2, 7 }, .value = 7, .choices = &.{ .{ .bound = 4, .value = 2 }, .{ .bound = 65536, .value = 7 } }, .keys = &.{ 7, 7 }, .skips = &.{ false, true }, .consumed = 2 },
        \\};
        \\const random_u8 = [_]RandomPin(u8){
        \\    .{ .seed = 1, .value = 10, .choices = &.{.{ .bound = 4, .value = 0 }}, .keys = &.{10}, .skips = &.{false} },
        \\    .{ .seed = 2, .value = 3, .choices = &.{.{ .bound = 4, .value = 0 }}, .keys = &.{3}, .skips = &.{false} },
        \\};
        \\test "golden: u8 at seed 1" {
        \\    var src = Source.initRandom(a, deriveSeed(1, 0), 100);
        \\    try expectEqual(10, v);
        \\}
    );
}

test "pins: a removed replay pin is a replay-meaning change" {
    try expectClasses(&.{.@"replay-meaning"},
        \\const random_u8 = [_]RandomPin(u8){
        \\    .{ .seed = 1, .value = 9, .choices = &.{.{ .bound = 4, .value = 0 }}, .keys = &.{9}, .skips = &.{false} },
        \\};
        \\test "golden: u8 at seed 1" {
        \\    var src = Source.initRandom(a, deriveSeed(1, 0), 100);
        \\    try expectEqual(9, v);
        \\}
    );
}

test "verdict: replay-meaning needs a version bump, seed needs a verification.md change" {
    try std.testing.expect(allowed(.@"bound-only", false, false));
    try std.testing.expect(allowed(.added, false, false));
    try std.testing.expect(!allowed(.@"replay-meaning", false, true));
    try std.testing.expect(allowed(.@"replay-meaning", true, false));
    try std.testing.expect(!allowed(.seed, true, false));
    try std.testing.expect(allowed(.seed, false, true));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u64, 2), try generatorVersion(arena.allocator(), "pub const generator_version: u32 = 2;"));
}
