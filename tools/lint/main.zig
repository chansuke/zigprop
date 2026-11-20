//! zigprop-lint: token-level rules over src/ (verification pipeline plan §2-1 to §2-3).
//!
//! Usage: zigprop-lint [--warn] [--root <dir>]
//!   --warn        report every rule as a warning and exit 0
//!   --root <dir>  lint <dir>/src instead of ./src
//!
//! Rules and their configuration: core-is-pure, no-error-control-flow
//! (error-contract.zon) and layer-order (layers.zon). Each rule's stage is
//! in stages.zon.

const std = @import("std");
const Token = std.zig.Token;
const Allocator = std.mem.Allocator;

pub const Rule = enum { @"core-is-pure", @"no-error-control-flow", @"layer-order" };
pub const Stage = enum { warn, @"error" };

const Entry = struct { name: []const u8, ref: []const u8 };
const Contract = struct { comparable: []const Entry, returnable: []const Entry };
const Upward = struct { from: []const u8, to: []const u8, in_fn: []const u8, ref: []const u8 };
const Layers = struct { layers: []const []const u8, allowed_upward: []const Upward, external: []const []const u8 };
const Stages = struct { @"core-is-pure": Stage, @"no-error-control-flow": Stage, @"layer-order": Stage };

pub const Config = struct { contract: Contract, layers: Layers };
pub const default_config: Config = .{
    .contract = @import("error-contract.zon"),
    .layers = @import("layers.zon"),
};
const stages: Stages = @import("stages.zon");

pub const Violation = struct {
    rule: Rule,
    line: usize,
    col: usize,
    what: []const u8,
    reason: []const u8,
    fix: []const u8,
    example: []const u8,
};

const pure_reason = "The core never prints (design v0.3 §4.8, D26), and generation must be a pure function of the seed and the choice sequence; any clock, OS or second RNG breaks replay fidelity (verification rows 3-5).";
const pure_fix = "Return what you want to report inside `Report`; printing belongs in the *OrError wrappers in src/runner.zig; draw randomness through GenContext (range, index, boolean, length).";
const pure_example = "runner.zig: `pub fn checkOrError(...) { ... const print = std.debug.print; ... }`";

const error_reason = "Zig interns error names globally; a property or generator can return the same name, and this catch site cannot tell them apart (Sol M3 review, 271c891; design v0.3 §5.3).";
const error_fix = "Signal internal control flow with a flag or a tagged union, and return normally. Compare caught errors only against the `comparable` names in tools/lint/error-contract.zon; a new returnable name needs an entry there with its design section.";
const error_example = "if (self.budget == 0) { self.exhausted = true; return .stop; }";

const layer_reason = "A lower layer must not depend on a higher one (shrink's acceptance must not depend on how runner reports; fingerprint must stay independent of gen for stale detection, design v0.3 §4.5); layers are source < fingerprint < gen < shrink < runner < root (tools/lint/layers.zon).";
const layer_fix = "Pass what the lower layer needs as parameters, or move the shared type down and re-export it from the higher file. The only upward edges are the ones listed in tools/lint/layers.zon.";
const layer_example = "runner.zig: `pub const ShrinkOutcome = shrink_mod.ShrinkOutcome;`";

/// Dotted std paths src/ must not name (rule core-is-pure). A path is
/// banned when it equals an entry or extends it by more components.
const banned_paths = [_][]const u8{
    "std.debug.print",   "std.log",    "std.time",  "std.Io.Timestamp", "std.Io.Clock",
    "std.Io.File",       "std.Io.Dir", "std.posix", "std.os",           "std.process",
    "std.crypto.random", "std.Thread",
};
/// The PRNG namespace: allowed in src/source.zig only.
const random_path = "std.Random";
/// The one place src/ may name std.debug.print (same exemption as the
/// former ci.yml grep).
const print_alias_file = "src/runner.zig";
const print_alias_line = "    const print = std.debug.print;";

fn extendsPath(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '.';
}

fn contains(list: []const Entry, name: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

fn indexOfName(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

const File = struct {
    arena: Allocator,
    path: []const u8,
    src: [:0]const u8,
    toks: []const Token,
    line_starts: []const usize,
    out: std.ArrayList(Violation) = .empty,

    fn text(f: *const File, i: usize) []const u8 {
        const t = f.toks[i];
        return f.src[t.loc.start..t.loc.end];
    }

    fn tag(f: *const File, i: usize) Token.Tag {
        return if (i < f.toks.len) f.toks[i].tag else .eof;
    }

    fn lineOf(f: *const File, offset: usize) usize {
        var lo: usize = 0;
        var hi: usize = f.line_starts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (f.line_starts[mid] <= offset) lo = mid else hi = mid;
        }
        return lo + 1;
    }

    fn lineText(f: *const File, line: usize) []const u8 {
        const start = f.line_starts[line - 1];
        const end = std.mem.indexOfScalarPos(u8, f.src, start, '\n') orelse f.src.len;
        return f.src[start..end];
    }

    fn report(f: *File, rule: Rule, offset: usize, comptime fmt: []const u8, args: anytype) !void {
        const line = f.lineOf(offset);
        const what = try std.fmt.allocPrint(f.arena, fmt, args);
        const texts: [3][]const u8 = switch (rule) {
            .@"core-is-pure" => .{ pure_reason, pure_fix, pure_example },
            .@"no-error-control-flow" => .{ error_reason, error_fix, error_example },
            .@"layer-order" => .{ layer_reason, layer_fix, layer_example },
        };
        try f.out.append(f.arena, .{
            .rule = rule,
            .line = line,
            .col = offset - f.line_starts[line - 1] + 1,
            .what = what,
            .reason = texts[0],
            .fix = texts[1],
            .example = texts[2],
        });
    }

    fn hasViolationOnLine(f: *const File, rule: Rule, line: usize) bool {
        for (f.out.items) |v| if (v.rule == rule and v.line == line) return true;
        return false;
    }

    fn matchingClose(f: *const File, open: usize, open_tag: Token.Tag, close_tag: Token.Tag) usize {
        var depth: usize = 0;
        var i = open;
        while (i < f.toks.len) : (i += 1) {
            if (f.toks[i].tag == open_tag) depth += 1;
            if (f.toks[i].tag == close_tag) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return f.toks.len;
    }

    fn matchingOpenParen(f: *const File, close: usize) ?usize {
        var depth: usize = 0;
        var i = close + 1;
        while (i > 0) {
            i -= 1;
            if (f.toks[i].tag == .r_paren) depth += 1;
            if (f.toks[i].tag == .l_paren) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
    }

    /// A `{` that opens a type body (error set, struct, union, enum,
    /// opaque) rather than a block.
    fn opensTypeBody(f: *const File, brace: usize) bool {
        if (brace == 0) return false;
        switch (f.toks[brace - 1].tag) {
            .keyword_error, .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => return true,
            .r_paren => {
                const open = f.matchingOpenParen(brace - 1) orelse return false;
                if (open == 0) return false;
                return switch (f.toks[open - 1].tag) {
                    .keyword_struct, .keyword_union, .keyword_enum => true,
                    else => false,
                };
            },
            else => return false,
        }
    }

    /// For every `fn name(...) ... {`, maps the body's `{` token to `name`.
    fn functionBodies(f: *const File) ![]?[]const u8 {
        const bodies = try f.arena.alloc(?[]const u8, f.toks.len);
        @memset(bodies, null);
        for (f.toks, 0..) |t, i| {
            if (t.tag != .keyword_fn or f.tag(i + 1) != .identifier or f.tag(i + 2) != .l_paren) continue;
            var k = f.matchingClose(i + 2, .l_paren, .r_paren) + 1;
            var parens: usize = 0;
            while (k < f.toks.len) : (k += 1) {
                switch (f.toks[k].tag) {
                    .l_paren => parens += 1,
                    .r_paren => parens -|= 1,
                    .semicolon => if (parens == 0) break,
                    .l_brace => if (parens == 0) {
                        if (f.opensTypeBody(k)) {
                            k = f.matchingClose(k, .l_brace, .r_brace);
                            continue;
                        }
                        bodies[k] = f.text(i + 1);
                        break;
                    },
                    else => {},
                }
            }
        }
        return bodies;
    }

    fn checkCoreIsPure(f: *File) !void {
        const in_source = std.mem.eql(u8, f.path, "src/source.zig");
        var buf: std.ArrayList(u8) = .empty;
        for (f.toks, 0..) |t, i| {
            if (t.tag != .identifier or !std.mem.eql(u8, f.text(i), "std")) continue;
            if (i > 0 and f.toks[i - 1].tag == .period) continue;
            buf.clearRetainingCapacity();
            try buf.appendSlice(f.arena, "std");
            var j = i + 1;
            while (f.tag(j) == .period and f.tag(j + 1) == .identifier) : (j += 2) {
                try buf.append(f.arena, '.');
                try buf.appendSlice(f.arena, f.text(j + 1));
            }
            const path = buf.items;
            for (banned_paths) |banned| {
                if (!extendsPath(path, banned)) continue;
                const line = f.lineOf(t.loc.start);
                if (std.mem.eql(u8, banned, "std.debug.print") and
                    std.mem.eql(u8, f.path, print_alias_file) and
                    std.mem.eql(u8, f.lineText(line), print_alias_line)) break;
                try f.report(.@"core-is-pure", t.loc.start, "`{s}` is used in the core (forbidden: `{s}`).", .{ path, banned });
                break;
            }
            if (!in_source and extendsPath(path, random_path))
                try f.report(.@"core-is-pure", t.loc.start, "`{s}` is used outside src/source.zig; the only PRNG lives in Source.", .{path});
        }
        // The text of `std.debug.print` in a comment or a string counts too,
        // as it did for the ci.yml grep this rule replaces (only the
        // runner.zig alias line and its `//!` lines are exempt).
        var line: usize = 1;
        while (line <= f.line_starts.len) : (line += 1) {
            const lt = f.lineText(line);
            const at = std.mem.indexOf(u8, lt, "std.debug.print") orelse continue;
            if (f.hasViolationOnLine(.@"core-is-pure", line)) continue;
            if (std.mem.eql(u8, f.path, print_alias_file) and
                (std.mem.eql(u8, lt, print_alias_line) or std.mem.startsWith(u8, lt, "//!"))) continue;
            try f.report(.@"core-is-pure", f.line_starts[line - 1] + at, "`std.debug.print` appears in a comment or string in the core.", .{});
        }
    }

    fn checkErrorNames(f: *File, contract: Contract) !void {
        for (f.toks, 0..) |t, i| {
            if (t.tag != .keyword_error) continue;
            if (f.tag(i + 1) == .period and f.tag(i + 2) == .identifier) {
                const name = f.text(i + 2);
                if (!contains(contract.returnable, name) and !contains(contract.comparable, name))
                    try f.report(.@"no-error-control-flow", t.loc.start, "`error.{s}` is not in tools/lint/error-contract.zon.", .{name});
                if (f.isCompared(i) and !contains(contract.comparable, name))
                    try f.report(.@"no-error-control-flow", t.loc.start, "`error.{s}` is compared against a caught error.", .{name});
            } else if (f.tag(i + 1) == .l_brace) {
                const close = f.matchingClose(i + 1, .l_brace, .r_brace);
                for (i + 2..close) |k| {
                    if (f.toks[k].tag != .identifier) continue;
                    const name = f.text(k);
                    if (!contains(contract.returnable, name) and !contains(contract.comparable, name))
                        try f.report(.@"no-error-control-flow", f.toks[k].loc.start, "`{s}` in an error set is not in tools/lint/error-contract.zon.", .{name});
                }
            }
        }
    }

    /// `x == error.N`, `error.N != x`, or a switch prong `error.A, error.N =>`.
    fn isCompared(f: *const File, i: usize) bool {
        if (i > 0 and (f.toks[i - 1].tag == .equal_equal or f.toks[i - 1].tag == .bang_equal)) return true;
        var k = i + 3;
        switch (f.tag(k)) {
            .equal_equal, .bang_equal, .equal_angle_bracket_right => return true,
            else => {},
        }
        while (f.tag(k) == .comma) {
            if (f.tag(k + 1) == .equal_angle_bracket_right) return true;
            if (f.tag(k + 1) != .keyword_error or f.tag(k + 2) != .period or f.tag(k + 3) != .identifier) return false;
            k += 4;
        }
        return f.tag(k) == .equal_angle_bracket_right;
    }

    fn checkLayers(f: *File, layers: Layers) !void {
        const base = std.fs.path.basename(f.path);
        const from = base[0 .. base.len - ".zig".len];
        const bodies = try f.functionBodies();
        const Frame = struct { name: []const u8, depth: usize };
        var stack: std.ArrayList(Frame) = .empty;
        var depth: usize = 0;
        for (f.toks, 0..) |t, i| {
            switch (t.tag) {
                .l_brace => {
                    depth += 1;
                    if (bodies[i]) |name| try stack.append(f.arena, .{ .name = name, .depth = depth });
                },
                .r_brace => {
                    if (stack.items.len > 0 and stack.items[stack.items.len - 1].depth == depth) _ = stack.pop();
                    depth -|= 1;
                },
                .builtin => {
                    if (!std.mem.eql(u8, f.text(i), "@import")) continue;
                    if (f.tag(i + 1) != .l_paren or f.tag(i + 2) != .string_literal) continue;
                    const lit = f.text(i + 2);
                    const target = lit[1 .. lit.len - 1];
                    if (indexOfName(layers.external, target) != null) continue;
                    if (!std.mem.endsWith(u8, target, ".zig")) continue;
                    const tbase = std.fs.path.basename(target);
                    const to = tbase[0 .. tbase.len - ".zig".len];
                    const from_i = indexOfName(layers.layers, from) orelse {
                        try f.report(.@"layer-order", t.loc.start, "{s}.zig is not listed in tools/lint/layers.zon, so its import of {s} cannot be checked.", .{ from, target });
                        continue;
                    };
                    const to_i = indexOfName(layers.layers, to) orelse {
                        try f.report(.@"layer-order", t.loc.start, "{s} imports {s}, which is not listed in tools/lint/layers.zon.", .{ from, target });
                        continue;
                    };
                    if (to_i <= from_i) continue;
                    const in_fn: ?[]const u8 = if (stack.items.len > 0) stack.items[stack.items.len - 1].name else null;
                    const allowed = for (layers.allowed_upward) |up| {
                        if (std.mem.eql(u8, up.from, from) and std.mem.eql(u8, up.to, to) and
                            in_fn != null and std.mem.eql(u8, up.in_fn, in_fn.?)) break true;
                    } else false;
                    if (allowed) continue;
                    const where = if (in_fn) |name| try std.fmt.allocPrint(f.arena, "in fn {s}", .{name}) else "at container level";
                    try f.report(.@"layer-order", t.loc.start, "{s} (layer {d}) imports {s} (layer {d}) {s}.", .{ from, from_i, target, to_i, where });
                },
                else => {},
            }
        }
    }

    /// `// zigprop-lint: allow(<rule>) <reason>` on the line above a
    /// violation removes it; without a reason it is a violation itself.
    fn applyAllows(f: *File) !void {
        var kept: std.ArrayList(Violation) = .empty;
        var bare_allow_lines: std.ArrayList(usize) = .empty;
        for (f.out.items) |v| {
            const allow = if (v.line > 1) parseAllow(f.lineText(v.line - 1), v.rule) else null;
            if (allow) |reason| {
                if (reason.len > 0) continue;
                if (std.mem.indexOfScalar(usize, bare_allow_lines.items, v.line - 1) == null) {
                    try bare_allow_lines.append(f.arena, v.line - 1);
                    try kept.append(f.arena, .{
                        .rule = v.rule,
                        .line = v.line - 1,
                        .col = 1,
                        .what = try std.fmt.allocPrint(f.arena, "`allow({s})` has no reason.", .{@tagName(v.rule)}),
                        .reason = "An allow without a reason reads as permission to bypass the rule (verification pipeline plan §2-1).",
                        .fix = "State why the rule does not apply here after the closing parenthesis, or fix the code.",
                        .example = try std.fmt.allocPrint(f.arena, "// zigprop-lint: allow({s}) <why this site is an exception>", .{@tagName(v.rule)}),
                    });
                }
            }
            try kept.append(f.arena, v);
        }
        f.out = kept;
    }
};

/// The reason text of an allow comment for `rule` on `line`, or null.
fn parseAllow(line: []const u8, rule: Rule) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    const prefix = "// zigprop-lint: allow(";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const rest = trimmed[prefix.len..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    if (!std.mem.eql(u8, rest[0..close], @tagName(rule))) return null;
    return std.mem.trim(u8, rest[close + 1 ..], " \t");
}

/// Lints one src/ file. `path` is relative to the repository root
/// (`src/<name>.zig`); results are allocated in `arena`.
pub fn lintSource(arena: Allocator, path: []const u8, src: [:0]const u8, cfg: Config) ![]const Violation {
    var toks: std.ArrayList(Token) = .empty;
    var tz = std.zig.Tokenizer.init(src);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        try toks.append(arena, t);
    }
    var line_starts: std.ArrayList(usize) = .empty;
    try line_starts.append(arena, 0);
    for (src, 0..) |c, i| if (c == '\n' and i + 1 < src.len) try line_starts.append(arena, i + 1);
    var f: File = .{ .arena = arena, .path = path, .src = src, .toks = toks.items, .line_starts = line_starts.items };
    try f.checkCoreIsPure();
    try f.checkErrorNames(cfg.contract);
    try f.checkLayers(cfg.layers);
    try f.applyAllows();
    std.mem.sort(Violation, f.out.items, {}, struct {
        fn lt(_: void, a: Violation, b: Violation) bool {
            return a.line < b.line or (a.line == b.line and a.col < b.col);
        }
    }.lt);
    return f.out.items;
}

fn stageOf(rule: Rule, warn_all: bool) Stage {
    if (warn_all) return .warn;
    return switch (rule) {
        inline else => |r| @field(stages, @tagName(r)),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var warn_all = false;
    var root: []const u8 = ".";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--warn")) {
            warn_all = true;
        } else if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            i += 1;
            root = args[i];
        } else {
            std.debug.print("zigprop-lint: unknown argument `{s}`\nusage: zigprop-lint [--warn] [--root <dir>]\n", .{args[i]});
            std.process.exit(2);
        }
    }

    var src_dir = try std.Io.Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ root, "src" }), .{ .iterate = true });
    defer src_dir.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try src_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var counts = std.EnumArray(Rule, usize).initFill(0);
    var errors: usize = 0;
    for (paths.items) |rel| {
        const src = try src_dir.readFileAllocOptions(io, rel, arena, .limited(1 << 24), .of(u8), 0);
        const path = try std.fmt.allocPrint(arena, "src/{s}", .{rel});
        for (try lintSource(arena, path, src, default_config)) |v| {
            counts.getPtr(v.rule).* += 1;
            if (stageOf(v.rule, warn_all) == .@"error") errors += 1;
            std.debug.print(
                \\[zigprop-lint/{s}] {s}:{d}:{d}
                \\violation: {s}
                \\reason:    {s}
                \\fix:       {s}
                \\example:   {s}
                \\allow:     `// zigprop-lint: allow({s}) <reason>` on the line above (the reason is required; an allow without one is itself a violation).
                \\
                \\
            , .{ @tagName(v.rule), path, v.line, v.col, v.what, v.reason, v.fix, v.example, @tagName(v.rule) });
        }
    }
    std.debug.print("zigprop-lint: {d} files;", .{paths.items.len});
    for (std.enums.values(Rule)) |r| std.debug.print(" {s} {d} ({s});", .{ @tagName(r), counts.get(r), @tagName(stageOf(r, warn_all)) });
    std.debug.print(" {d} error(s)\n", .{errors});
    if (errors > 0) std.process.exit(1);
}

// ---------------------------------------------------------------------
// Tests: each rule detects its violation, passes clean code, and honours
// (or rejects) allow comments.

fn expectRules(expected: []const Rule, path: []const u8, src: [:0]const u8) !void {
    try expectRulesWith(expected, path, src, default_config);
}

fn expectRulesWith(expected: []const Rule, path: []const u8, src: [:0]const u8, cfg: Config) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vs = try lintSource(arena.allocator(), path, src, cfg);
    errdefer for (vs) |v| std.debug.print("{s}:{d}:{d} {s} {s}\n", .{ path, v.line, v.col, @tagName(v.rule), v.what });
    try std.testing.expectEqual(expected.len, vs.len);
    for (expected, vs) |r, v| try std.testing.expectEqual(r, v.rule);
}

test "core-is-pure: printing, clocks, OS and a second PRNG are detected" {
    try expectRules(&.{.@"core-is-pure"}, "src/gen.zig",
        \\fn f() void {
        \\    std.debug.print("x", .{});
        \\}
    );
    try expectRules(&.{ .@"core-is-pure", .@"core-is-pure", .@"core-is-pure" }, "src/shrink.zig",
        \\const t = std.time.nanoTimestamp();
        \\const f: std.Io.File = undefined;
        \\var p = std.Random.DefaultPrng.init(0);
    );
    try expectRules(&.{.@"core-is-pure"}, "src/gen.zig",
        \\// see std.debug.print
    );
    // std.os must not match a longer component name; std.Io.Writer is allowed.
    try expectRules(&.{}, "src/gen.zig",
        \\const w: std.Io.Writer = undefined;
        \\const x = std.osx;
    );
}

test "core-is-pure: the runner alias and source.zig's PRNG are allowed" {
    try expectRules(&.{}, "src/runner.zig",
        \\//! Printing goes through `std.debug.print`.
        \\pub fn checkOrError() void {
        \\    const print = std.debug.print;
        \\    print("x", .{});
        \\}
    );
    // Two-space indentation is not the exempt line (as with the grep).
    try expectRules(&.{.@"core-is-pure"}, "src/runner.zig",
        \\  const print = std.debug.print;
    );
    // The alias is exempt in runner.zig only.
    try expectRules(&.{.@"core-is-pure"}, "src/gen.zig",
        \\    const print = std.debug.print;
    );
    try expectRules(&.{}, "src/source.zig",
        \\random: std.Random.DefaultPrng,
    );
}

test "no-error-control-flow: comparisons and unknown names are detected" {
    try expectRules(&.{}, "src/shrink.zig",
        \\fn f() !void {
        \\    g() catch |err| {
        \\        if (err == error.InvalidGeneration) return;
        \\        return error.OutOfMemory;
        \\    };
        \\}
        \\fn h() error{InvalidGeneration}!void {}
    );
    try expectRules(&.{.@"no-error-control-flow"}, "src/shrink.zig",
        \\const b = error.OutOfMemory == err;
    );
    try expectRules(&.{ .@"no-error-control-flow", .@"no-error-control-flow" }, "src/shrink.zig",
        \\const b = err != error.ShrinkBudgetExhausted;
    );
    try expectRules(&.{ .@"no-error-control-flow", .@"no-error-control-flow" }, "src/shrink.zig",
        \\const x = switch (err) {
        \\    error.OutOfMemory, error.InvalidConfig => 1,
        \\    else => 2,
        \\};
    );
    try expectRules(&.{.@"no-error-control-flow"}, "src/gen.zig",
        \\fn h() error{ InvalidGeneration, Bogus }!void {}
    );
}

const source_like =
    \\pub const GenContext = struct {
    \\    pub fn generate(self: *GenContext, comptime T: type) anyerror!T {
    \\        return @import("gen.zig").generate(T, self);
    \\    }
    \\    pub fn countElement(self: *GenContext) error{InvalidGeneration}!void {
    \\        return @import("gen.zig").countElement(self);
    \\    }
    \\};
;

test "layer-order: upward imports are detected outside the listed functions" {
    try expectRules(&.{}, "src/source.zig", source_like);
    try expectRules(&.{.@"layer-order"}, "src/shrink.zig",
        \\const runner = @import("runner.zig");
    );
    try expectRules(&.{}, "src/runner.zig",
        \\const std = @import("std");
        \\const shrink = @import("shrink.zig");
    );
    try expectRules(&.{.@"layer-order"}, "src/source.zig",
        \\fn other() void {
        \\    _ = @import("gen.zig");
        \\}
    );
    try expectRules(&.{.@"layer-order"}, "src/gen.zig",
        \\const extra = @import("extra.zig");
    );
    // With both exceptions naming countElement, the import in generate
    // is a violation.
    var cfg = default_config;
    cfg.layers.allowed_upward = &.{
        .{ .from = "source", .to = "gen", .in_fn = "countElement", .ref = "test" },
        .{ .from = "source", .to = "gen", .in_fn = "countElement", .ref = "test" },
    };
    try expectRulesWith(&.{.@"layer-order"}, "src/source.zig", source_like, cfg);
}

test "allow: a reason silences one violation; a missing reason is a violation" {
    try expectRules(&.{}, "src/gen.zig",
        \\// zigprop-lint: allow(core-is-pure) test fixture
        \\const t = std.time.nanoTimestamp();
    );
    try expectRules(&.{ .@"core-is-pure", .@"core-is-pure" }, "src/gen.zig",
        \\// zigprop-lint: allow(core-is-pure)
        \\const t = std.time.nanoTimestamp();
    );
    // An allow names one rule.
    try expectRules(&.{.@"core-is-pure"}, "src/gen.zig",
        \\// zigprop-lint: allow(layer-order) wrong rule
        \\const t = std.time.nanoTimestamp();
    );
}
