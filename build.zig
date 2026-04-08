const std = @import("std");

/// labelle-fsm — comptime state-machine library, zero dependencies
/// beyond the Zig standard library. Exposes a single module that
/// game projects (or any Zig package) can import as `labelle-fsm`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public module. Game projects depend on this via plugin
    // resolution: the labelle-cli generator hardlinks the package into
    // `.labelle/<backend>_<platform>/deps/labelle-fsm/` and exposes it
    // to the build as `@import("labelle-fsm")`.
    _ = b.addModule("labelle-fsm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library tests — exercise advance, dispatch, on_enter / on_exit,
    // first-match semantics, the debug-mode multi-match assertion, and
    // overlap_allowed suppression. Run with `zig build test`.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run labelle-fsm library tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
