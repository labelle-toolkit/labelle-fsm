const std = @import("std");

/// labelle-fsm — comptime state-machine library, plus a minimal plugin
/// Controller (RFC-plugin-controllers §1/§2). Exposes a single module
/// that game projects (or any Zig package) can import as `labelle-fsm`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // labelle-core dependency — needed at Controller module level for
    // the `SavePolicy` enum used on `LabelleFsmState`'s `save_policy`
    // declaration. The assembler `overrideImport`s a matching
    // `labelle-core` module into the plugin's build graph at game-
    // build time; this standalone dependency keeps `zig build test`
    // self-contained. Pinned v1.4 for test isolation (pre-SavePolicy)
    // — see `tests/controller_test.zig` for the version-skew policy
    // mirroring `libs/needs_machine` and `libs/production`.
    const labelle_core_dep = b.dependency("labelle-core", .{
        .target = target,
        .optimize = optimize,
    });
    const labelle_core_mod = labelle_core_dep.module("labelle-core");

    // The public module. Game projects depend on this via plugin
    // resolution: labelle-cli's deps_linker hardlinks the package into
    // `.labelle/<backend>_<platform>/deps/labelle-fsm/`, and the
    // generated build.zig calls `plugin_fsm_dep.module("labelle_fsm")`
    // to fetch the module. Game source then imports it by the plugin's
    // short name, `@import("fsm")`, which labelle-cli wires up in the
    // generated `addImport(.name = "fsm", ...)` call.
    //
    // Module name must be `labelle_fsm` (underscore) to match the
    // generator's lookup. The shorter `@import("fsm")` in game code is
    // a separate alias set by the CLI.
    const fsm_mod = b.addModule("labelle_fsm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fsm_mod.addImport("labelle-core", labelle_core_mod);

    // Library tests — exercise advance, dispatch, on_enter / on_exit,
    // first-match semantics, the debug-mode multi-match assertion, and
    // overlap_allowed suppression (all inline in `src/root.zig`). Run
    // with `zig build test`.
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = labelle_core_mod },
            },
        }),
    });

    // Controller export-shape tests — assert the plugin Controller's
    // public-API surface (presence of `Controller`, `LabelleFsmState`,
    // `Result`, `Reason`, expected decls on `Controller`) at comptime.
    // Split into their own file so the shape contract is visible
    // next to the Controller itself rather than buried among the
    // state-machine behavior tests.
    const controller_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    controller_tests_mod.addImport("labelle_fsm", fsm_mod);

    const controller_tests = b.addTest(.{ .root_module = controller_tests_mod });

    const test_step = b.step("test", "Run labelle-fsm library tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(controller_tests).step);
}
