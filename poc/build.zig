const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ecs_dep = b.dependency("zig_ecs", .{ .target = target, .optimize = optimize });
    const ecs_mod = ecs_dep.module("zig-ecs");

    // Runnable example — demonstrates the FSM library driving a zig-ecs
    // component machine through several "frames" of polled + event-driven
    // transitions, printing what happens.
    const exe = b.addExecutable(.{
        .name = "fsm_poc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs", .module = ecs_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the POC example");
    run_step.dependOn(&run.step);

    // Unit tests — covers advance, dispatch, first-match, overlap_allowed,
    // and the debug-mode multi-match assertion. The library lives in
    // src/lib/fsm.zig and is imported by everything else in the POC.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/fsm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run FSM library tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
