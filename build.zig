const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("fp-compression", "src/gorilla.zig");
    lib.setBuildMode(mode);
    lib.install();

    const gorilla_tests = b.addTest("src/gorilla.zig");
    gorilla_tests.setBuildMode(mode);

    const entropy_test = b.addTest("src/entropy.zig");
    entropy_test.setBuildMode(mode);

    const workspace_test = b.addTest("src/bit-workspace.zig");
    workspace_test.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&gorilla_tests.step);
    test_step.dependOn(&entropy_test.step);
    test_step.dependOn(&workspace_test.step);
}
