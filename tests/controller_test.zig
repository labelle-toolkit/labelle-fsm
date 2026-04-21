//! Export-shape tests for the labelle-fsm plugin Controller
//! (ticket flying-platform-labelle#246, scaffold landing).
//!
//! These exercise the plugin's public-API surface at comptime —
//! presence of `Controller`, `LabelleFsmState`, `Result`, `Reason`,
//! `Components` on the root module, and the expected decls on
//! `Controller`. They do NOT stand up a full ECS backend (that's
//! the assembled game's job); tests here catch regressions on the
//! plugin-authoring contract (RFC-plugin-controllers §1/§2) without
//! pulling a game-sized harness into the standalone `zig build test`.
//!
//! NOTE on `save_policy` + labelle-core version:
//! `LabelleFsmState.save_policy` is declared `.transient` in
//! `controller.zig` so the engine's serializer skips it on save — the
//! singleton is always rebuilt by `Controller.setup`. We deliberately
//! do NOT force compilation of that constant here, because standalone
//! `zig build test` uses labelle-core v1.4 from the cache (the
//! version pinned in `build.zig.zon` for lib-test isolation), which
//! predates the `SavePolicy` enum — introduced in v1.9 and overridden
//! into the plugin's build graph by the assembler at game-build time.
//! Forcing compilation of the `save_policy` constant from tests would
//! fail against v1.4 despite the game build working correctly.
//! Coverage for the `.transient` contract lives in the game-level
//! smoke test (save/load round-trip should produce a fresh
//! singleton), same as `pathfinder.ControllerState`,
//! `worker_controller.WorkerFsmState`,
//! `needs_machine.NeedsMachineState`, and
//! `production.ProductionState`.
//!
//! Matching pattern: `libs/needs_machine/tests/controller_test.zig`,
//! `libs/production/tests/root.zig`, and
//! `libs/worker_controller/tests/root.zig` all keep their Controller
//! coverage to `@hasDecl` / `@typeName` lookups so the standalone
//! build stays v1.4-safe. We follow the same policy.

const std = @import("std");
const fsm = @import("labelle_fsm");

test "plugin root exports Controller and LabelleFsmState" {
    // Compile-time assertion: the module exposes the public surface
    // the assembler's controller-discovery scans for. Accessing
    // `@hasDecl(...)` does NOT force compilation of the referenced
    // decls, so this stays v1.4-safe.
    comptime {
        std.debug.assert(@hasDecl(fsm, "Controller"));
        std.debug.assert(@hasDecl(fsm, "LabelleFsmState"));
        std.debug.assert(@hasDecl(fsm, "Result"));
        std.debug.assert(@hasDecl(fsm, "Reason"));
        std.debug.assert(@hasDecl(fsm, "Components"));
    }
}

test "Controller exports setup / deinit (lifecycle-only)" {
    // Same — `@hasDecl` is a lookup, not a compile of the decl body.
    // labelle-fsm is a pure comptime library, so the Controller is
    // lifecycle-only — no per-frame method and no public mutator.
    // Games drive `StateMachine(...).advance / .dispatch` directly.
    comptime {
        std.debug.assert(@hasDecl(fsm.Controller, "setup"));
        std.debug.assert(@hasDecl(fsm.Controller, "deinit"));
        // No `advance` / `apply` / `tick` — labelle-fsm holds no
        // per-world runtime work. Guard against drift: if a future
        // change adds one of these back it should be deliberate
        // (update the test below) not accidental.
        std.debug.assert(!@hasDecl(fsm.Controller, "advance"));
        std.debug.assert(!@hasDecl(fsm.Controller, "apply"));
        std.debug.assert(!@hasDecl(fsm.Controller, "tick"));
    }
}

test "StateMachine convention surface preserved (no behaviour change)" {
    // Ticket flying-platform-labelle#246 is scaffold-only: the
    // pre-existing `StateMachine` factory must still be exported
    // unchanged so games authoring machines via `state_machines/`
    // see no behaviour change.
    comptime {
        std.debug.assert(@hasDecl(fsm, "StateMachine"));
    }
}

test "LabelleFsmState has the unique name (no collision with sibling plugins)" {
    // zig-ecs hashes `@typeName(T)` for its type-id and uses only the
    // trailing unqualified name. If this struct's name gets changed
    // to the generic `ControllerState` it will collide with
    // pathfinder's / needs_machine's / caretaker's / production's /
    // command_buffer's / worker_controller's singletons at runtime —
    // see the landing comment in `controller.zig` + the "#243 / #239
    // Lessons" comments under #213.
    //
    // `@typeName` on a type does not force compilation of its fields,
    // so this stays v1.4-safe.
    const name = @typeName(fsm.LabelleFsmState);
    try std.testing.expect(std.mem.indexOf(u8, name, "LabelleFsmState") != null);
}

test "Result carries the four-variant plugin-Controller shape" {
    // RFC-plugin-controllers §2 mandates `accepted` + `deferred`
    // variants at minimum; `redundant` / `rejected` are added by
    // Controllers whose APIs produce those outcomes. labelle-fsm
    // exposes all four so future mutator methods can grow into
    // rejecting / redundant states without changing the union shape.
    const tag_fields = comptime std.meta.fields(fsm.Result);
    var has_accepted = false;
    var has_redundant = false;
    var has_deferred = false;
    var has_rejected = false;
    inline for (tag_fields) |f| {
        if (std.mem.eql(u8, f.name, "accepted")) has_accepted = true;
        if (std.mem.eql(u8, f.name, "redundant")) has_redundant = true;
        if (std.mem.eql(u8, f.name, "deferred")) has_deferred = true;
        if (std.mem.eql(u8, f.name, "rejected")) has_rejected = true;
    }
    try std.testing.expect(has_accepted);
    try std.testing.expect(has_redundant);
    try std.testing.expect(has_deferred);
    try std.testing.expect(has_rejected);
}

test "Reason enum carries controller_not_setup" {
    // The deferral-on-missing-setup reason is the minimum contract;
    // callers retry next tick when they see it.
    const name = @tagName(fsm.Reason.controller_not_setup);
    try std.testing.expectEqualStrings("controller_not_setup", name);
}

test "Reason enum carries invalid_transition (reserved)" {
    // Reserved for future mutator methods that reject events from
    // the current state. Keeps the `Reason` shape stable when those
    // methods land so callers don't see an enum-widening breakage.
    const name = @tagName(fsm.Reason.invalid_transition);
    try std.testing.expectEqualStrings("invalid_transition", name);
}

test "Components re-exports LabelleFsmState" {
    // The assembler auto-discovers plugin components by scanning the
    // `Components` decl on the root module. Asserting the singleton
    // appears there keeps the ECS-registration contract visible.
    comptime {
        std.debug.assert(@hasDecl(fsm.Components, "LabelleFsmState"));
    }
}

test "LabelleFsmState has a state_ptr field (type-erased storage)" {
    // The type-erased `state_ptr: usize` pattern (shared with every
    // other plugin Controller) keeps the ECS component shape free of
    // game types — the Controller owns the only `@ptrFromInt` cast.
    // Asserting the field's presence catches accidental removal
    // during future refactors.
    comptime {
        const fields = std.meta.fields(fsm.LabelleFsmState);
        var has_state_ptr = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "state_ptr")) has_state_ptr = true;
        }
        std.debug.assert(has_state_ptr);
    }
}

test "save_policy decl exists on LabelleFsmState (if core supports it)" {
    // Shape-only probe: assert the decl is declared, without forcing
    // its compilation. The `save_policy` constant references
    // `core.SavePolicy` which only exists on labelle-core v1.9+; the
    // plugin pins v1.4 for test isolation so the decl compiles at
    // game-build time (where the assembler overrides core to v1.9+)
    // but not necessarily standalone.
    //
    // `@hasDecl` is a lookup, not a compile — the decl's *name* is
    // present in the struct's declaration table regardless of
    // whether its body can be compiled under the pinned core.
    comptime {
        std.debug.assert(@hasDecl(fsm.LabelleFsmState, "save_policy"));
    }
}
