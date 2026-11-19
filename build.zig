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
    const bench_step = b.step("bench", "Run benchmarks");
    const run_bench = b.addRunArtifact(bench_exe);
    const smoke = b.option(bool, "smoke", "Run benchmarks in smoke mode (CI)") orelse false;
    if (smoke) run_bench.addArg("--smoke");
    bench_step.dependOn(&run_bench.step);

    const bench_bin_step = b.step("bench-bin", "Install the benchmark binary");
    bench_bin_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
}
