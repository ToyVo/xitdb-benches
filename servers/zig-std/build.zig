const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xitdb_mod = b.createModule(.{
        .root_source_file = b.path("vendor/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // libc: std.c.getenv/clock_gettime need it spelled out on Linux
    // (macOS links it implicitly, which is why this only bites CI).
    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_root.addImport("xitdb", xitdb_mod);
    exe_root.link_libc = true;
    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = exe_root,
    });
    b.installArtifact(exe);

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root.addImport("xitdb", xitdb_mod);
    test_root.link_libc = true;
    const unit_tests = b.addTest(.{
        .root_module = test_root,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
