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
    // self-contained. Pinned to the labelle-core Zig 0.16 migration
    // branch until a released tag is available — see
    // `tests/controller_test.zig` for the shape-only test policy.
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

    // ── v2 prototypes (src_v2/, tests/v2/) ────────────────────────────────
    // Stateless-flavored declarative FSM (variant_d) and the phone
    // component / spec built against it. Wired into the same `test`
    // step so `zig build test` exercises everything.
    const variant_d_mod = b.createModule(.{
        .root_source_file = b.path("src_v2/variant_d.zig"),
        .target = target,
        .optimize = optimize,
    });
    const variant_d_tests = b.addTest(.{ .root_module = variant_d_mod });

    const phone_component_mod = b.createModule(.{
        .root_source_file = b.path("tests/v2/phone_component.zig"),
        .target = target,
        .optimize = optimize,
    });
    phone_component_mod.addImport("variant_d", variant_d_mod);
    phone_component_mod.addImport("labelle-core", labelle_core_mod);

    const phone_spec_mod = b.createModule(.{
        .root_source_file = b.path("tests/v2/specs/phone_component_spec.zig"),
        .target = target,
        .optimize = optimize,
    });
    phone_spec_mod.addImport("variant_d", variant_d_mod);
    phone_spec_mod.addImport("phone_component", phone_component_mod);
    phone_spec_mod.addImport("labelle-core", labelle_core_mod);

    const phone_spec_tests = b.addTest(.{ .root_module = phone_spec_mod });

    // Semaphore — external pattern: behavior in a sibling file, pulled
    // in via a relative @import inside the component. No separate
    // module needed for the behavior file because it shares the
    // component module's source tree.
    const semaphore_component_mod = b.createModule(.{
        .root_source_file = b.path("tests/v2/semaphore_component.zig"),
        .target = target,
        .optimize = optimize,
    });
    semaphore_component_mod.addImport("variant_d", variant_d_mod);
    semaphore_component_mod.addImport("labelle-core", labelle_core_mod);

    const semaphore_spec_mod = b.createModule(.{
        .root_source_file = b.path("tests/v2/specs/semaphore_component_spec.zig"),
        .target = target,
        .optimize = optimize,
    });
    semaphore_spec_mod.addImport("semaphore_component", semaphore_component_mod);
    semaphore_spec_mod.addImport("labelle-core", labelle_core_mod);

    const semaphore_spec_tests = b.addTest(.{ .root_module = semaphore_spec_mod });

    const test_step = b.step("test", "Run labelle-fsm library tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(controller_tests).step);
    test_step.dependOn(&b.addRunArtifact(variant_d_tests).step);
    test_step.dependOn(&b.addRunArtifact(phone_spec_tests).step);
    test_step.dependOn(&b.addRunArtifact(semaphore_spec_tests).step);
}
