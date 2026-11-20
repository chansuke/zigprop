const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigprop", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit and meta tests");

    const unit_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const meta_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/meta.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigprop", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(meta_tests).step);

    for ([_][]const u8{ "tests/meta2.zig", "tests/examples.zig", "tests/meta3.zig", "tests/meta4.zig", "tests/meta5.zig", "tests/meta6.zig", "tests/meta7.zig", "tests/meta8.zig", "tests/meta9.zig", "tests/meta10.zig", "tests/meta10_rec.zig", "tests/meta11.zig", "tests/meta12.zig", "tests/api_surface.zig" }) |path| {
        const extra_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigprop", .module = mod }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(extra_tests).step);
    }

    // Benchmark / profiling harness (bench/main.zig). Both the harness
    // and the library module it measures are ReleaseFast, regardless of
    // the global -Doptimize setting.
    const mod_fast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_exe = b.addExecutable(.{
        .name = "zigprop-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zigprop", .module = mod_fast }},
        }),
    });
    // Pre-registered validation targets (design §9): `zig build validation`.
    const validation_exe = b.addExecutable(.{
        .name = "zigprop-validation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zigprop", .module = mod_fast }},
        }),
    });
    const validation_step = b.step("validation", "Run the pre-registered validation targets T1-T9e");
    validation_step.dependOn(&b.addRunArtifact(validation_exe).step);

    const bench_step = b.step("bench", "Run benchmarks");
    const run_bench = b.addRunArtifact(bench_exe);
    const smoke = b.option(bool, "smoke", "Run benchmarks in smoke mode (CI)") orelse false;
    if (smoke) run_bench.addArg("--smoke");
    bench_step.dependOn(&run_bench.step);

    const bench_bin_step = b.step("bench-bin", "Install the benchmark binary");
    bench_bin_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

    // Custom lint (tools/lint): `zig build lint [-Dlint-warn] [-Dlint-print-hashes]`.
    const lint_mod = b.createModule(.{
        .root_source_file = b.path("tools/lint/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const run_lint = b.addRunArtifact(b.addExecutable(.{ .name = "zigprop-lint", .root_module = lint_mod }));
    run_lint.setCwd(b.path("."));
    if (b.option(bool, "lint-warn", "Report lint violations without failing") orelse false)
        run_lint.addArg("--warn");
    if (b.option(bool, "lint-print-hashes", "Print the current formal/manifest.zon hashes") orelse false)
        run_lint.addArg("--print-hashes");
    if (b.option([]const u8, "lint-root", "Lint the repository at <dir> (src, tests, build.zig, docs, formal) instead of .")) |dir|
        run_lint.addArgs(&.{ "--root", dir });
    const lint_step = b.step("lint", "Run zigprop's custom lint rules (tools/lint)");
    lint_step.dependOn(&run_lint.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lint_mod })).step);

    // Golden-pin diff classifier (tools/pinguard). Not part of `verify-full`, which
    // needs no base revision: this is the one CI step outside verify-full (ci.yml).
    const pinguard_mod = b.createModule(.{
        .root_source_file = b.path("tools/pinguard/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pinguard_mod })).step);
    const pin_step = b.step("pin-guard", "Classify golden-pin changes against -Dpin-base=<rev> (head: -Dpin-head=<rev>, default the working tree)");
    const pin_base = b.option([]const u8, "pin-base", "Base revision for pin-guard");
    const pin_head = b.option([]const u8, "pin-head", "Head revision for pin-guard (default: the working tree)");
    if (pin_base) |base| {
        const run_pin = b.addRunArtifact(b.addExecutable(.{ .name = "zigprop-pinguard", .root_module = pinguard_mod }));
        run_pin.addArgs(&.{ "--base-label", base, "--head-label", pin_head orelse "working tree" });
        for ([_][2][]const u8{ .{ "--base-gen", "--head-gen" }, .{ "--base-doc", "--head-doc" } }, [_][]const u8{ "src/gen.zig", "docs/verification.md" }) |flags, path| {
            run_pin.addArg(flags[0]);
            run_pin.addFileArg(gitShow(b, base, path));
            run_pin.addArg(flags[1]);
            run_pin.addFileArg(if (pin_head) |head| gitShow(b, head, path) else b.path(path));
        }
        for ([_][]const u8{ "tests/meta10.zig", "tests/meta10_rec.zig", "tests/meta5.zig" }) |path| {
            run_pin.addArgs(&.{ "--pins", path });
            run_pin.addFileArg(gitShow(b, base, path));
            run_pin.addFileArg(if (pin_head) |head| gitShow(b, head, path) else b.path(path));
        }
        pin_step.dependOn(&run_pin.step);
    } else {
        pin_step.dependOn(&b.addFail("pin-guard needs -Dpin-base=<rev>").step);
    }

    // Compile budget (tests/compile_budget.zig): a fresh-cache compile and run
    // must finish within 120 s. The limit lives here, so local runs and CI share it.
    // The run's output directory survives between runs, so it is emptied first.
    const compile_budget = b.addSystemCommand(&.{ "sh", "-c", "rm -rf \"$0\" && exec timeout --kill-after=10 120 \"$1\" test --dep zigprop \"-Mroot=$2\" \"-Mzigprop=$3\" --cache-dir \"$0\"" });
    _ = compile_budget.addOutputDirectoryArg("cache");
    compile_budget.addArg(b.graph.zig_exe);
    compile_budget.addFileArg(b.path("tests/compile_budget.zig"));
    compile_budget.addFileArg(b.path("src/root.zig"));
    compile_budget.has_side_effects = true;
    const compile_budget_step = b.step("compile-budget", "Compile and run tests/compile_budget.zig with a fresh cache within 120 s");
    compile_budget_step.dependOn(&compile_budget.step);

    // The paths ci.yml passed to `zig fmt --check` before it called fmt-check, plus tools.
    const fmt_paths: []const std.Build.LazyPath = &.{ b.path("src"), b.path("tests"), b.path("bench"), b.path("validation"), b.path("tools"), b.path("build.zig"), b.path("build.zig.zon") };
    const fmt_check_step = b.step("fmt-check", "Check formatting (zig fmt --check); on failure run `zig build fmt`");
    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    // The step name is what a failure prints, so the remedy goes there.
    fmt_check.step.name = "zig fmt --check (to fix: run `zig build fmt`; it also rewrites deprecated builtins such as @intFromEnum -> @backingInt; do not hand-edit)";
    fmt_check_step.dependOn(&fmt_check.step);
    const fmt_step = b.step("fmt", "Format the sources in place (whitespace and deprecated builtins)");
    fmt_step.dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);

    // `verify-full` is a superset of the ubuntu job in .github/workflows/ci.yml:
    // each ci.yml step calls one of these build steps, so CI and local runs share one definition.
    // `verify` is the everyday subset: everything except compile-budget.
    const verify_step = b.step("verify", "Run the ubuntu CI job's steps except compile-budget (fmt-check, lint, test, validation, bench smoke)");
    verify_step.dependOn(fmt_check_step);
    verify_step.dependOn(lint_step);
    verify_step.dependOn(test_step);
    verify_step.dependOn(validation_step);
    const run_bench_smoke = b.addRunArtifact(bench_exe);
    run_bench_smoke.addArg("--smoke");
    verify_step.dependOn(&run_bench_smoke.step);

    // compile-budget measures a fresh cache on every run, so it never gets the
    // warm-cache speedup the rest of verify gets, and adding it would double verify's time.
    const verify_full_step = b.step("verify-full", "Run everything the ubuntu CI job runs (verify plus compile-budget)");
    verify_full_step.dependOn(verify_step);
    verify_full_step.dependOn(compile_budget_step);
}

/// `git show <rev>:<path>`, as a file.
fn gitShow(b: *std.Build, rev: []const u8, path: []const u8) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "git", "show", b.fmt("{s}:{s}", .{ rev, path }) });
    cmd.setCwd(b.path("."));
    // A revision name (HEAD, origin/main) can move between runs.
    cmd.has_side_effects = true;
    return cmd.captureStdOut(.{});
}
