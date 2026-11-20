//! Repository-level rules (verification pipeline plan §2-2 rule C, §2-5 ①):
//! `formal-drift` compares the token hash of the implementation functions
//! listed in formal/manifest.zon; `evidence-integrity` checks that tests are
//! wired into build.zig (check 1), that docs/verification.md cites paths and
//! test names that exist (check 2), and that regression-driven tests assert
//! the regression path (check 3). Every function here is pure: main.zig reads
//! the files and passes them in a `Repo`.

const std = @import("std");
const lint = @import("main.zig");
const Token = std.zig.Token;
const Allocator = std.mem.Allocator;
const Violation = lint.Violation;

pub const Impl = struct { file: []const u8, func: []const u8 };
pub const ManifestItem = struct { artifact: []const u8, impl: []const Impl, hash: u64, checked_against: []const u8 };

pub const SourceFile = struct { path: []const u8, src: [:0]const u8 };

pub const Repo = struct {
    build_zig: [:0]const u8,
    verification_md: []const u8,
    manifest_text: []const u8,
    manifest: []const ManifestItem,
    src_files: []const SourceFile,
    /// Every .zig file under tests/, at any depth (`tests/x.zig`, `tests/consumer/build.zig`).
    test_files: []const SourceFile,
    /// Every file and directory under src, tests, formal, bench and docs, repo-relative.
    paths: []const []const u8,
};

pub const Located = struct {
    path: []const u8,
    v: Violation,
    /// A manifest entry that cannot be checked at all (an ambiguous function
    /// name). It fails `zig build lint` whatever the rule's stage.
    config_error: bool = false,
};

pub const Check = enum(u2) { wiring = 1, citation = 2, @"path-evidence" = 3 };

// ---------------------------------------------------------------------
// formal-drift

const drift_reason = "A formal artifact says something certain about the implementation only while the code it was written against is unchanged; the Lean/TLA+ artifacts already predate v2.1 and were not re-checked (docs/verification.md, known gaps), and formal/manifest.zon records which functions each artifact models so that further drift is not silent.";
const drift_fix = "Either (a) update the formal artifact and re-verify it, then update the hash and `checked_against`; or (b) add one line to the known gaps in docs/verification.md saying the formal side does not reflect this change, and update only the hash.";
const drift_example = "formal/manifest.zon: `.hash = 0x...` (print the current hashes with `zig build lint -Dlint-print-hashes`)";

pub const Fn = struct { start: usize, end: usize, toks: []const Token };

fn tokenize(arena: Allocator, src: [:0]const u8) ![]const Token {
    var toks: std.ArrayList(Token) = .empty;
    var tz = std.zig.Tokenizer.init(src);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        try toks.append(arena, t);
    }
    return toks.items;
}

fn matchingClose(toks: []const Token, open: usize, open_tag: Token.Tag, close_tag: Token.Tag) usize {
    var depth: usize = 0;
    var i = open;
    while (i < toks.len) : (i += 1) {
        if (toks[i].tag == open_tag) depth += 1;
        if (toks[i].tag == close_tag) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return toks.len - 1;
}

fn isTypeKeyword(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_error, .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => true,
        else => false,
    };
}

/// The tokens of every `fn <name>(...) ... { ... }` with a body, from the
/// `fn` keyword to the body's closing brace.
pub fn findFns(arena: Allocator, src: [:0]const u8, name: []const u8) ![]const Fn {
    const toks = try tokenize(arena, src);
    var out: std.ArrayList(Fn) = .empty;
    for (toks, 0..) |t, i| {
        if (t.tag != .keyword_fn or i + 2 >= toks.len) continue;
        if (toks[i + 1].tag != .identifier or toks[i + 2].tag != .l_paren) continue;
        if (!std.mem.eql(u8, src[toks[i + 1].loc.start..toks[i + 1].loc.end], name)) continue;
        var k = matchingClose(toks, i + 2, .l_paren, .r_paren) + 1;
        var parens: usize = 0;
        while (k < toks.len) : (k += 1) {
            switch (toks[k].tag) {
                .l_paren => parens += 1,
                .r_paren => parens -|= 1,
                .semicolon => if (parens == 0) break,
                .l_brace => if (parens == 0) {
                    // A brace right after a type keyword (or after `union(enum)`)
                    // opens a return type's body, not the function body.
                    const prev = toks[k - 1].tag;
                    const type_body = isTypeKeyword(prev) or (prev == .r_paren and k >= 4 and isTypeKeyword(toks[k - 4].tag));
                    if (type_body) {
                        k = matchingClose(toks, k, .l_brace, .r_brace);
                        continue;
                    }
                    const close = matchingClose(toks, k, .l_brace, .r_brace);
                    try out.append(arena, .{ .start = i, .end = close, .toks = toks });
                    break;
                },
                else => {},
            }
        }
    }
    return out.items;
}

/// FNV-1a 64 over the function's token texts, each followed by a 0 byte.
/// Comments, doc comments and whitespace are excluded, so only a change to
/// the code itself moves the hash.
pub fn hashFn(hasher: *std.hash.Fnv1a_64, src: []const u8, f: Fn) void {
    for (f.toks[f.start .. f.end + 1]) |t| {
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) continue;
        hasher.update(src[t.loc.start..t.loc.end]);
        hasher.update(&.{0});
    }
}

fn findSource(files: []const SourceFile, path: []const u8) ?SourceFile {
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

pub const Hashed = union(enum) {
    hash: u64,
    /// The file or function is gone (formal-drift).
    missing: []const u8,
    /// More than one function has the name (a manifest error).
    ambiguous: []const u8,
};

pub fn hashItem(arena: Allocator, files: []const SourceFile, item: ManifestItem) !Hashed {
    var hasher = std.hash.Fnv1a_64.init();
    for (item.impl) |impl| {
        const file = findSource(files, impl.file) orelse
            return .{ .missing = try std.fmt.allocPrint(arena, "{s} does not exist", .{impl.file}) };
        const fns = try findFns(arena, file.src, impl.func);
        if (fns.len == 0) return .{ .missing = try std.fmt.allocPrint(arena, "{s} has no `fn {s}`", .{ impl.file, impl.func }) };
        if (fns.len > 1) return .{ .ambiguous = try std.fmt.allocPrint(arena, "{s} declares `fn {s}` {d} times", .{ impl.file, impl.func, fns.len }) };
        hashFn(&hasher, file.src, fns[0]);
    }
    return .{ .hash = hasher.final() };
}

fn implList(arena: Allocator, item: ManifestItem) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (item.impl, 0..) |impl, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.print(arena, "{s} {s}", .{ impl.file, impl.func });
    }
    return buf.items;
}

const LineCol = struct { line: usize, col: usize };

fn lineCol(text: []const u8, offset: usize) LineCol {
    var line: usize = 1;
    var start: usize = 0;
    for (text[0..offset], 0..) |c, i| {
        if (c != '\n') continue;
        line += 1;
        start = i + 1;
    }
    return .{ .line = line, .col = offset - start + 1 };
}

fn manifestPos(repo: Repo, item: ManifestItem) LineCol {
    const at = std.mem.indexOf(u8, repo.manifest_text, item.artifact) orelse 0;
    return lineCol(repo.manifest_text, at);
}

pub fn checkFormalDrift(arena: Allocator, repo: Repo, out: *std.ArrayList(Located)) !void {
    for (repo.manifest) |item| {
        const pos = manifestPos(repo, item);
        const what: []const u8, const config_error = switch (try hashItem(arena, repo.src_files, item)) {
            .hash => |h| if (h == item.hash) continue else .{ try std.fmt.allocPrint(arena, "the implementation of {s} ({s}) changed: token hash 0x{x:0>16}, manifest 0x{x:0>16} (checked_against: \"{s}\").", .{ item.artifact, try implList(arena, item), h, item.hash, item.checked_against }), false },
            .missing => |m| .{ try std.fmt.allocPrint(arena, "the implementation of {s} cannot be found: {s}.", .{ item.artifact, m }), false },
            .ambiguous => |m| .{ try std.fmt.allocPrint(arena, "manifest error for {s}: {s}, so the entry names no single function (this fails whatever the stage).", .{ item.artifact, m }), true },
        };
        try out.append(arena, .{ .path = "formal/manifest.zon", .config_error = config_error, .v = .{
            .rule = .@"formal-drift",
            .line = pos.line,
            .col = pos.col,
            .what = what,
            .reason = drift_reason,
            .fix = if (config_error) "Rename one of the functions, or list a function whose name is unique in its file." else drift_fix,
            .example = drift_example,
        } });
    }
}

// ---------------------------------------------------------------------
// evidence-integrity

const wiring_reason = "A test file that no build.zig list names is never compiled or run, so its tests are evidence in name only (015ce66: tests/meta5.zig was silently unwired because a build.zig edit did not match).";
const citation_reason = "docs/verification.md is the map from claims to evidence; a cited path or test name that does not exist is a claim with no evidence behind it (aa71b5a, c007748). Test-name rule, applied as written: on a table row (a line starting with `|`) that cites at least one existing tests/ .zig file, every straight double-quoted span without an ellipsis (`…` or `...`) is read as a test name and must equal the name of a `test \"...\"` declaration in one of the .zig files that row cites under tests/.";
const path_reason = "A regression-driven test can pass while the regression path never ran (a non-failing or stale entry falls back to random search); the block must read the report's path evidence to show which path was taken (c007748, I3; improvement log case 3). Plan §2-2 rule C check 3 amendment (2026-11-20, director): the evidence identifiers are read as v0.3's origin union and regressions summary. Rule: a `test` block that contains both `.regressions =` and a call whose name starts with `check` must read `.origin` (`r.failed.origin.regression.index`, `f.origin == .regression`, `switch (r.failed.origin)`) or a report variant's `.regressions` summary (`r.passed.regressions.passed`, `p.regressions.stale`). Evidence is a read of a field chain through `.origin` or `.regressions`: the token before `.` is an identifier, `)` or `]`, and the chain (`.name`, `.?`, `.*`, `[...]`) does not end as the target of `=` or a compound assignment, so `.{ .regressions = ... }`, `r.failed.origin.regression.index = 0` and `x.regressions.len -= 1` never count. This is a syntactic search for a report-like field-chain read: it does not establish that the receiver is the report returned by the block's `check*` call, nor that the read is asserted. Allow (director, 2026-11-20): a comment line inside the test block that starts with `// zigprop-lint: allow path-evidence` and continues with a reason removes the block from the count; the summary reports it as allowed. A marker with no reason is not an allow, and the block still fires. The reason states why a report field read cannot or need not show the path: the evidence is outside the report, or the claim does not depend on which path ran.";

fn hasPath(paths: []const []const u8, p: []const u8) bool {
    for (paths) |q| if (std.mem.eql(u8, q, p)) return true;
    return false;
}

fn isTopLevelTest(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "tests/") or !std.mem.endsWith(u8, path, ".zig")) return false;
    return std.mem.indexOfScalar(u8, path["tests/".len..], '/') == null;
}

fn checkTag(arena: Allocator, check: Check, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "[check {d} {s}] " ++ fmt, .{ @backingInt(check), @tagName(check) } ++ args);
}

/// Check 1: every tests/*.zig (top level only) is a string literal in
/// build.zig, and every `tests/....zig` literal in build.zig exists.
pub fn checkWiring(arena: Allocator, repo: Repo, out: *std.ArrayList(Located)) !void {
    const toks = try tokenize(arena, repo.build_zig);
    var literals: std.ArrayList([]const u8) = .empty;
    for (toks) |t| {
        if (t.tag != .string_literal) continue;
        const lit = repo.build_zig[t.loc.start + 1 .. t.loc.end - 1];
        try literals.append(arena, lit);
        if (std.mem.startsWith(u8, lit, "tests/") and std.mem.endsWith(u8, lit, ".zig") and !hasPath(repo.paths, lit)) {
            const pos = lineCol(repo.build_zig, t.loc.start);
            try out.append(arena, .{ .path = "build.zig", .v = .{
                .rule = .@"evidence-integrity",
                .line = pos.line,
                .col = pos.col,
                .what = try checkTag(arena, .wiring, "build.zig names \"{s}\", which does not exist.", .{lit}),
                .reason = wiring_reason,
                .fix = "Remove the entry, or restore or rename the file so the entry and the file agree.",
                .example = "build.zig: `for ([_][]const u8{ \"tests/meta2.zig\", ... })`",
            } });
        }
    }
    for (repo.test_files) |f| {
        if (!isTopLevelTest(f.path)) continue;
        const wired = for (literals.items) |lit| {
            if (std.mem.eql(u8, lit, f.path)) break true;
        } else false;
        if (wired) continue;
        try out.append(arena, .{ .path = f.path, .v = .{
            .rule = .@"evidence-integrity",
            .line = 1,
            .col = 1,
            .what = try checkTag(arena, .wiring, "{s} is not named by any string literal in build.zig.", .{f.path}),
            .reason = wiring_reason,
            .fix = try std.fmt.allocPrint(arena, "Add \"{s}\" to the test list in build.zig (the `for ([_][]const u8{{ ... }})` loop over extra tests); a test file that is not in that list is never compiled or run.", .{f.path}),
            .example = "build.zig: `for ([_][]const u8{ \"tests/meta2.zig\", ..., \"tests/meta13.zig\" }) |path|`",
        } });
    }
}

const cited_prefixes = [_][]const u8{ "tests/", "src/", "formal/", "bench/" };

fn isPathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '-';
}

const Citation = struct { offset: usize, path: []const u8, elided: bool };

/// Paths cited on one line: a cited prefix not preceded by a path character,
/// extended over path characters, with trailing `.` and `/` dropped. A path
/// followed by `*` or `…` is elided (a pattern, not a file).
fn citations(arena: Allocator, line: []const u8) ![]const Citation {
    var out: std.ArrayList(Citation) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (i > 0 and isPathChar(line[i - 1])) continue;
        const prefix = for (cited_prefixes) |p| {
            if (std.mem.startsWith(u8, line[i..], p)) break p;
        } else continue;
        var end = i + prefix.len;
        while (end < line.len and isPathChar(line[end])) end += 1;
        var trimmed = end;
        while (trimmed > i + prefix.len and (line[trimmed - 1] == '.' or line[trimmed - 1] == '/')) trimmed -= 1;
        if (trimmed == i + prefix.len) {
            i = end;
            continue;
        }
        const elided = end < line.len and (line[end] == '*' or std.mem.startsWith(u8, line[end..], "…"));
        try out.append(arena, .{ .offset = i, .path = line[i..trimmed], .elided = elided });
        i = end;
    }
    return out.items;
}

fn declaresTest(arena: Allocator, src: [:0]const u8, name: []const u8) !bool {
    const toks = try tokenize(arena, src);
    for (toks, 0..) |t, i| {
        if (t.tag != .keyword_test or i + 1 >= toks.len or toks[i + 1].tag != .string_literal) continue;
        const lit = src[toks[i + 1].loc.start + 1 .. toks[i + 1].loc.end - 1];
        if (std.mem.eql(u8, lit, name)) return true;
    }
    return false;
}

/// Check 2: cited paths exist, and quoted test names on a table row are
/// `test` declarations in the row's cited test files (rule in citation_reason).
pub fn checkCitations(arena: Allocator, repo: Repo, out: *std.ArrayList(Located)) !void {
    const doc = repo.verification_md;
    var line_start: usize = 0;
    while (line_start < doc.len) {
        const line_end = std.mem.indexOfScalarPos(u8, doc, line_start, '\n') orelse doc.len;
        const line = doc[line_start..line_end];
        const cites = try citations(arena, line);
        var row_tests: std.ArrayList(SourceFile) = .empty;
        for (cites) |c| {
            if (c.elided) continue;
            if (!hasPath(repo.paths, c.path)) {
                const pos = lineCol(doc, line_start + c.offset);
                try out.append(arena, .{ .path = "docs/verification.md", .v = .{
                    .rule = .@"evidence-integrity",
                    .line = pos.line,
                    .col = pos.col,
                    .what = try checkTag(arena, .citation, "`{s}` is cited but does not exist.", .{c.path}),
                    .reason = citation_reason,
                    .fix = "Correct the path, or remove the claim that rests on it.",
                    .example = "docs/verification.md: `(tests/meta9.zig)`",
                } });
                continue;
            }
            if (std.mem.startsWith(u8, c.path, "tests/") and std.mem.endsWith(u8, c.path, ".zig")) {
                if (findSource(repo.test_files, c.path)) |f| try row_tests.append(arena, f);
            }
        }
        if (std.mem.startsWith(u8, line, "|") and row_tests.items.len > 0) {
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, line, i, '"')) |open| {
                const close = std.mem.indexOfScalarPos(u8, line, open + 1, '"') orelse break;
                i = close + 1;
                const name = line[open + 1 .. close];
                if (std.mem.indexOf(u8, name, "…") != null or std.mem.indexOf(u8, name, "...") != null) continue;
                const found = for (row_tests.items) |f| {
                    if (try declaresTest(arena, f.src, name)) break true;
                } else false;
                if (found) continue;
                const pos = lineCol(doc, line_start + open);
                try out.append(arena, .{ .path = "docs/verification.md", .v = .{
                    .rule = .@"evidence-integrity",
                    .line = pos.line,
                    .col = pos.col,
                    .what = try checkTag(arena, .citation, "\"{s}\" is read as a test name, but no tests/ file cited on this row declares `test \"{s}\"`.", .{ name, name }),
                    .reason = citation_reason,
                    .fix = "Quote the exact test name and cite its file on the same row; for a quotation that is not a test name, use other quotation marks or elide it with `…`.",
                    .example = "`tests/meta9.zig` \"cut: a single admissible variant (m = 1) draws no tag\"",
                } });
            }
        }
        line_start = line_end + 1;
    }
}

/// Whether the field chain continuing at `start` (`.name`, `.?`, `.*`,
/// `[...]`) ends as the target of `=` or a compound assignment.
fn chainIsAssigned(toks: []const Token, start: usize) bool {
    var j = start;
    while (j < toks.len) {
        switch (toks[j].tag) {
            .period => if (j + 1 < toks.len and (toks[j + 1].tag == .identifier or toks[j + 1].tag == .question_mark)) {
                j += 2;
            } else return false,
            .period_asterisk => j += 1,
            .l_bracket => j = matchingClose(toks, j, .l_bracket, .r_bracket) + 1,
            else => break,
        }
    }
    if (j >= toks.len) return false;
    const op = toks[j].tag.lexeme() orelse return false;
    if (op[op.len - 1] != '=') return false;
    for ([_][]const u8{ "==", "!=", "<=", ">=" }) |cmp| {
        if (std.mem.eql(u8, op, cmp)) return false;
    }
    return true;
}

const path_allow_marker = "// zigprop-lint: allow path-evidence";

/// The reason of a path-evidence allow line in `block`: null without a
/// marker, "" when every marker lacks a reason.
fn pathAllow(block: []const u8) ?[]const u8 {
    var bare = false;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, path_allow_marker)) continue;
        const rest = trimmed[path_allow_marker.len..];
        if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') continue;
        const reason = std.mem.trim(u8, rest, " \t");
        if (reason.len > 0) return reason;
        bare = true;
    }
    return if (bare) "" else null;
}

/// Check 3: a `test` block that sets `.regressions =` and calls a `check*`
/// function reads the report's `.origin` or a variant's `.regressions`
/// summary, or carries an allow with a reason (rule in path_reason).
pub fn checkPathEvidence(arena: Allocator, repo: Repo, out: *std.ArrayList(Located), allowed: *usize) !void {
    for (repo.test_files) |f| {
        const toks = try tokenize(arena, f.src);
        for (toks, 0..) |t, i| {
            if (t.tag != .keyword_test) continue;
            var open = i + 1;
            while (open < toks.len and toks[open].tag != .l_brace) open += 1;
            if (open >= toks.len) break;
            const close = matchingClose(toks, open, .l_brace, .r_brace);
            var regressions = false;
            var calls_check = false;
            var evidence = false;
            for (open..close) |k| {
                const text = f.src[toks[k].loc.start..toks[k].loc.end];
                if (toks[k].tag != .identifier) continue;
                const field = k > 0 and toks[k - 1].tag == .period;
                const assigned = k + 1 < toks.len and toks[k + 1].tag == .equal;
                const read = field and !chainIsAssigned(toks, k + 1) and k > 1 and switch (toks[k - 2].tag) {
                    .identifier, .r_paren, .r_bracket => true,
                    else => false,
                };
                if (std.mem.eql(u8, text, "regressions") and field and assigned) regressions = true;
                if (read and (std.mem.eql(u8, text, "origin") or std.mem.eql(u8, text, "regressions"))) evidence = true;
                if (std.mem.startsWith(u8, text, "check") and k + 1 < toks.len and toks[k + 1].tag == .l_paren) calls_check = true;
            }
            if (!regressions or !calls_check or evidence) continue;
            const allow = pathAllow(f.src[toks[open].loc.start..toks[close].loc.end]);
            if (allow) |reason| if (reason.len > 0) {
                allowed.* += 1;
                continue;
            };
            const pos = lineCol(f.src, t.loc.start);
            const name = if (i + 1 < toks.len and toks[i + 1].tag == .string_literal) f.src[toks[i + 1].loc.start..toks[i + 1].loc.end] else "(unnamed)";
            const bare = if (allow != null) " Its `zigprop-lint: allow path-evidence` marker has no reason, so it is not an allow." else "";
            try out.append(arena, .{ .path = f.path, .v = .{
                .rule = .@"evidence-integrity",
                .line = pos.line,
                .col = pos.col,
                .what = try checkTag(arena, .@"path-evidence", "test {s} runs regressions but never reads the report's `.origin` or `.regressions` summary.{s}", .{ name, bare }),
                .reason = path_reason,
                .fix = "In the same test block, assert the path the run took: a failure's `.origin` (`.regression` and its entry index), or for a non-failing report its `.regressions` summary (passed count, stale entries).",
                .example = "try std.testing.expectEqual(@as(usize, 0), report.failed.origin.regression.index);",
            } });
        }
    }
}

/// Violations, and per evidence-integrity check the sites an allow removed.
pub const Result = struct { violations: []const Located, allowed: std.EnumArray(Check, usize) };

pub fn lintRepo(arena: Allocator, repo: Repo) !Result {
    var out: std.ArrayList(Located) = .empty;
    var allowed = std.EnumArray(Check, usize).initFill(0);
    try checkFormalDrift(arena, repo, &out);
    try checkWiring(arena, repo, &out);
    try checkCitations(arena, repo, &out);
    try checkPathEvidence(arena, repo, &out, allowed.getPtr(.@"path-evidence"));
    return .{ .violations = out.items, .allowed = allowed };
}

/// The check number of an evidence-integrity violation (from its message).
pub fn checkOf(v: Violation) ?Check {
    if (v.rule != .@"evidence-integrity") return null;
    for (std.enums.values(Check)) |c| {
        var buf: [64]u8 = undefined;
        const tag = std.fmt.bufPrint(&buf, "[check {d} {s}]", .{ @backingInt(c), @tagName(c) }) catch unreachable;
        if (std.mem.startsWith(u8, v.what, tag)) return c;
    }
    return null;
}

// ---------------------------------------------------------------------
// Tests

const empty_repo: Repo = .{
    .build_zig = "",
    .verification_md = "",
    .manifest_text = "",
    .manifest = &.{},
    .src_files = &.{},
    .test_files = &.{},
    .paths = &.{},
};

fn run(arena: Allocator, repo: Repo) ![]const Located {
    return (try lintRepo(arena, repo)).violations;
}

fn expectChecks(expected: []const ?Check, got: []const Located) !void {
    errdefer for (got) |l| std.debug.print("{s}:{d}:{d} {s} {s}\n", .{ l.path, l.v.line, l.v.col, @tagName(l.v.rule), l.v.what });
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, l| {
        if (e) |c| {
            try std.testing.expectEqual(lint.Rule.@"evidence-integrity", l.v.rule);
            try std.testing.expectEqual(c, checkOf(l.v).?);
        } else try std.testing.expectEqual(lint.Rule.@"formal-drift", l.v.rule);
    }
}

const shrink_src: [:0]const u8 =
    \\/// Doc.
    \\fn tryAccept(self: *@This(), values: []const u64) !bool {
    \\    // a comment
    \\    return values.len < 3;
    \\}
    \\fn pair() struct { a: u8, b: u8 } {
    \\    return .{ .a = 1, .b = 2 };
    \\}
    \\fn range() u8 { return 1; }
    \\const S = struct { fn range() u8 { return 2; } };
;

fn driftRepo(arena: Allocator, src: [:0]const u8, func: []const u8, hash: u64) !Repo {
    var repo = empty_repo;
    const items = try arena.alloc(ManifestItem, 1);
    const impls = try arena.alloc(Impl, 1);
    impls[0] = .{ .file = "src/shrink.zig", .func = func };
    items[0] = .{ .artifact = "formal/lean/X.lean", .impl = impls, .hash = hash, .checked_against = "test" };
    const files = try arena.alloc(SourceFile, 1);
    files[0] = .{ .path = "src/shrink.zig", .src = src };
    repo.manifest = items;
    repo.src_files = files;
    return repo;
}

fn currentHash(arena: Allocator, src: [:0]const u8, func: []const u8) !u64 {
    const repo = try driftRepo(arena, src, func, 0);
    return (try hashItem(arena, repo.src_files, repo.manifest[0])).hash;
}

test "formal-drift: a token change is detected; comments, doc comments and whitespace are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = try currentHash(arena, shrink_src, "tryAccept");
    try expectChecks(&.{}, try run(arena, try driftRepo(arena, shrink_src, "tryAccept", h)));
    const recommented: [:0]const u8 =
        \\/// Another doc line.
        \\fn tryAccept(self: *@This(),
        \\    values: []const u64) !bool {
        \\    return values.len < 3; // moved comment
        \\}
    ;
    try expectChecks(&.{}, try run(arena, try driftRepo(arena, recommented, "tryAccept", h)));
    const changed: [:0]const u8 =
        \\fn tryAccept(self: *@This(), values: []const u64) !bool {
        \\    return values.len < 4;
        \\}
    ;
    try expectChecks(&.{null}, try run(arena, try driftRepo(arena, changed, "tryAccept", h)));
    // Doc comments inside the range (a nested container's fields, as in
    // shrinkWith's Inner) are excluded too.
    const nested_a: [:0]const u8 = "fn outer() void { const S = struct { /// one\n x: u8 }; _ = S; }";
    const nested_b: [:0]const u8 = "fn outer() void { const S = struct { /// two\n x: u8 }; _ = S; }";
    try std.testing.expectEqual(try currentHash(arena, nested_a, "outer"), try currentHash(arena, nested_b, "outer"));
    // A return type with a body: the hash covers the function body too.
    const hp = try currentHash(arena, shrink_src, "pair");
    try std.testing.expect(hp != try currentHash(arena, "fn pair() struct { a: u8, b: u8 } { return .{ .a = 1, .b = 3 }; }", "pair"));
}

test "formal-drift: a missing function is drift; an ambiguous name is a manifest error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const missing = try run(arena, try driftRepo(arena, shrink_src, "tryRatchet", 0));
    try expectChecks(&.{null}, missing);
    try std.testing.expect(!missing[0].config_error);
    const ambiguous = try run(arena, try driftRepo(arena, shrink_src, "range", 0));
    try expectChecks(&.{null}, ambiguous);
    try std.testing.expect(ambiguous[0].config_error);
}

test "evidence-integrity check 1: unwired test files and dangling build.zig entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var repo = empty_repo;
    repo.build_zig =
        \\const list = .{ "tests/a.zig", "tests/gone.zig" };
        \\const p = b.path("tests/c.zig");
    ;
    repo.test_files = &.{
        .{ .path = "tests/a.zig", .src = "" },
        .{ .path = "tests/b.zig", .src = "" },
        .{ .path = "tests/c.zig", .src = "" },
        .{ .path = "tests/consumer/build.zig", .src = "" },
    };
    repo.paths = &.{ "tests/a.zig", "tests/b.zig", "tests/c.zig", "tests/consumer", "tests/consumer/build.zig" };
    const got = try run(arena, repo);
    try expectChecks(&.{ .wiring, .wiring }, got);
    try std.testing.expectEqualStrings("build.zig", got[0].path);
    try std.testing.expectEqualStrings("tests/b.zig", got[1].path);
}

test "evidence-integrity check 2: missing paths and unknown quoted test names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var repo = empty_repo;
    repo.verification_md =
        \\Prose cites `src/a.zig` and formal/lean, and src/gone.zig.
        \\| 1 | x | `tests/t.zig` "real name", "spans: …", "made up" |
        \\| 2 | x | no test file here "made up" and tests/meta*.zig |
    ;
    repo.build_zig = "const t = \"tests/t.zig\";";
    repo.test_files = &.{.{ .path = "tests/t.zig", .src = "test \"real name\" {}" }};
    repo.paths = &.{ "src/a.zig", "formal/lean", "tests/t.zig" };
    const got = try run(arena, repo);
    try expectChecks(&.{ .citation, .citation }, got);
    try std.testing.expectEqual(@as(usize, 1), got[0].v.line);
    try std.testing.expect(std.mem.indexOf(u8, got[0].v.what, "src/gone.zig") != null);
    try std.testing.expectEqual(@as(usize, 2), got[1].v.line);
    try std.testing.expect(std.mem.indexOf(u8, got[1].v.what, "made up") != null);
}

test "evidence-integrity check 3: regression tests must read .origin or the regressions summary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var repo = empty_repo;
    repo.build_zig = "const t = \"tests/t.zig\";";
    repo.paths = &.{"tests/t.zig"};
    repo.test_files = &.{.{ .path = "tests/t.zig", .src =
        \\test "bare" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    _ = r;
        \\}
        \\test "origin index" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    try expectEqual(0, r.failed.origin.regression.index);
        \\}
        \\test "origin tag" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    try expect(r.failed.origin == .random);
        \\}
        \\test "origin switch" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    switch (r.failed.origin) { .regression => {}, .random => unreachable }
        \\}
        \\test "summary read" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    try expectEqual(1, r.passed.regressions.passed);
        \\}
        \\test "captured summary read" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    switch (r) { .passed => |s| try expectEqual(0, s.regressions.stale.len), else => unreachable }
        \\}
        \\test "a nonexistent identifier is not evidence" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    try expect(r.failed.regression_index != null);
        \\}
        \\test "setting fields is not evidence" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    const o: Origin = .{ .origin = undefined };
        \\    _ = .{ r, o };
        \\}
        \\test "an assigned origin chain is not evidence" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    r.failed.origin.regression.index = 0;
        \\}
        \\test "an assigned regressions chain is not evidence" {
        \\    config.regressions = &e;
        \\    config.regressions.len = 0;
        \\    var r = try zigprop.check(a, u32, p, config);
        \\    _ = r;
        \\}
        \\test "a compound assignment is not evidence" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    r.passed.regressions.stale[0].seed -= 1;
        \\}
        \\test "a compared chain is evidence" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    try expect(r.failed.origin.regression.index <= 0);
        \\}
        \\test "no regressions" {
        \\    var r = try zigprop.check(a, u32, p, .{ .seed = 1 });
        \\    _ = r;
        \\}
        \\test "allowed with a reason" {
        \\    // zigprop-lint: allow path-evidence the claim holds on either path.
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    _ = r;
        \\}
        \\test "a marker without a reason" {
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    // zigprop-lint: allow path-evidence
        \\    _ = r;
        \\}
        \\test "a longer word is not the marker" {
        \\    // zigprop-lint: allow path-evidences the claim holds on either path.
        \\    var r = try zigprop.check(a, u32, p, .{ .regressions = &e });
        \\    _ = r;
        \\}
    }};
    const result = try lintRepo(arena, repo);
    const got = result.violations;
    const fired = [_][]const u8{ "bare", "a nonexistent identifier", "setting fields", "an assigned origin chain", "an assigned regressions chain", "a compound assignment", "a marker without a reason", "a longer word" };
    const expected: [fired.len]?Check = @splat(.@"path-evidence");
    try expectChecks(&expected, got);
    try std.testing.expectEqual(@as(usize, 1), got[0].v.line);
    for (fired, got) |name, l| try std.testing.expect(std.mem.indexOf(u8, l.v.what, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, got[6].v.what, "has no reason") != null);
    try std.testing.expect(std.mem.indexOf(u8, got[7].v.what, "has no reason") == null);
    try std.testing.expectEqual(@as(usize, 1), result.allowed.get(.@"path-evidence"));
}
