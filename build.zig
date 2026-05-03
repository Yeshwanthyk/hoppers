const std = @import("std");
const ziglint = @import("ziglint");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vaxis", vaxis_dep.module("vaxis"));

    const exe = b.addExecutable(.{
        .name = "hoppers",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run hoppers");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    const tests = b.addTest(.{ .root_module = test_mod });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } }).step);

    const ziglint_dep = b.dependency("ziglint", .{ .optimize = .ReleaseFast });
    const lint_step = ziglint.addLint(b, ziglint_dep, &.{ b.path("src"), b.path("build.zig") });
    b.step("lint", "Run ziglint").dependOn(lint_step);
    test_step.dependOn(lint_step);
}
