const std = @import("std");

const packages = struct {
    const zsc = std.build.Pkg{
        .name = "zsc",
        .source = .{ .path = "lib/zsc.zig" },
        .dependencies = &[_]std.build.Pkg{},
    };
};

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const cmd = b.addExecutable("zsc", "cmd/main.zig");
    cmd.addPackage(packages.zsc);
    cmd.setBuildMode(mode);
    cmd.setTarget(target);
    cmd.install();

    const run_step = b.step("run", "Run zsc");
    run_step.dependOn(&cmd.step);

    const gorilla_tests = b.addTest("lib/gorilla.zig");
    gorilla_tests.setBuildMode(mode);

    const entropy_test = b.addTest("lib/entropy.zig");
    entropy_test.setBuildMode(mode);

    const workspace_test = b.addTest("lib/bit-workspace.zig");
    workspace_test.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&gorilla_tests.step);
    test_step.dependOn(&entropy_test.step);
    test_step.dependOn(&workspace_test.step);
}
