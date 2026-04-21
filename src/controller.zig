// Plugin-exported Controller for the labelle-fsm plugin.
//
// Per RFC-plugin-controllers §1/§2: the plugin's root module exports a
// `pub const Controller = struct { setup, deinit }` so the assembler's
// `PluginControllers` dispatcher auto-invokes `setup` on scene load and
// `deinit` on scene unload, and re-exports the API to game scripts as
// `fsm.Controller.*`.
//
// Scope of this landing (ticket flying-platform-labelle#246, referenced
// from RFC-plugin-controllers §4 "Migration" step 4, smallest sweep):
// INFRASTRUCTURE ONLY. labelle-fsm is intrinsically a pure comptime
// library — `StateMachine(State, Event, Context).advance / .dispatch`
// hold nothing at runtime, per-instance state lives on the caller's
// component as a plain enum (see `src/root.zig` design invariants).
// There is nothing per-frame for the plugin to tick and no game-side
// bridge script to delete today.
//
// What this Controller adds: a uniform lifecycle hook so the
// assembler's controller-discovery scan finds labelle-fsm the same
// way it finds every other plugin (pathfinder, worker_controller,
// command_buffer, production, needs_machine, caretaker, scheduler,
// job_machine). The `state_machines/` convention directory — already
// declared in `plugin.labelle` and scanned by labelle-cli — keeps its
// existing role unchanged. Games authoring FSM instances via
// `state_machines/<domain>_machine.zig` see no behaviour change.
//
// State storage (RFC §6 primary pattern): the Controller owns a
// singleton ECS component `LabelleFsmState` whose `state_ptr` field
// (a `usize` holding a type-erased pointer) references a heap-
// allocated `State`. `setup` creates the singleton; `deinit` frees
// it. The singleton is scaffolded even though labelle-fsm doesn't
// currently need per-world runtime bookkeeping — the indirection
// keeps the on-disk component shape stable against future fields
// (e.g. a per-world dispatch counter for diagnostics, or per-machine
// transition rings like worker_controller's `CommandLog`) without
// touching the `LabelleFsmState` component itself.
//
// Unique name / ECS type-id collision note (from #239 / #243 / #242
// "Lessons"): zig-ecs hashes `@typeName(T)` for its type-id and uses
// only the trailing unqualified name. Reusing the generic
// `ControllerState` name here would collide with every other plugin's
// singleton at runtime and setup would panic with `Invalid free`.
// Hence the unique `LabelleFsmState` — same pattern as
// `WorkerFsmState` (worker_controller), `CommandBufferState`
// (command_buffer), `NeedsMachineState` (needs_machine),
// `CaretakerState` (caretaker), `ProductionState` (production).
//
// Contrast with sibling Controllers:
//   - pathfinder        — per-frame work (`advance`) + graph state.
//   - worker_controller — purely event-driven (`apply`), no tick.
//   - command_buffer    — per-frame flush; duck-types `CommandLog`.
//   - production        — per-frame entrypoint declared; logic port
//                         deferred to follow-up.
//   - needs_machine     — event-driven + per-frame `decay`.
//   - labelle-fsm (this)— pure comptime library; no per-frame method
//                         and no public mutator method. `setup` /
//                         `deinit` only. Games use
//                         `StateMachine(...).advance / .dispatch`
//                         directly on their machine instances.

const std = @import("std");
const core = @import("labelle-core");

const zlog = std.log.scoped(.labelle_fsm_controller);

// ============================================================================
// Singleton state (RFC §6 primary pattern)
// ============================================================================

/// Singleton ECS component attaching the Controller's runtime state to
/// a world entity. `state_ptr` is a `usize` holding a type-erased
/// pointer so the component doesn't pull game types into its shape;
/// the Controller owns the only cast.
///
/// The name `LabelleFsmState` is deliberately unique (rather than the
/// generic `ControllerState`): see the `@typeName` collision note in
/// the module docs.
///
/// Marked `.transient` — the state is rebuilt on every scene load by
/// `setup`, never persisted to save files. The authoritative FSM
/// state lives on caller-owned ECS components as plain enum fields
/// (design invariant #1 in `src/root.zig`); this singleton carries
/// nothing that needs persisting.
///
/// labelle-core version skew note (from #239 / #242 "Lessons"):
/// standalone `zig build test` links against the plugin's pinned
/// labelle-core v1.4 (pre-SavePolicy is v1.4 itself — `SavePolicy` was
/// introduced in v1.9+). The assembler overrides labelle-core to the
/// game's chosen version at game-build time. Tests in
/// `tests/controller_test.zig` stay shape-only (`@hasDecl` /
/// `@typeName`) so they never force compilation of the `save_policy`
/// constant; referencing `core.SavePolicy` here compiles only when
/// the overridden core actually exports it.
pub const LabelleFsmState = struct {
    pub const save_policy: core.SavePolicy = .transient;

    state_ptr: usize = 0,
};

/// Heap-allocated runtime state. Not exported directly — callers
/// reach it through the Controller's methods, which look up the
/// singleton `LabelleFsmState` component and cast `state_ptr` back
/// to `*State`.
///
/// Today the state is empty (scaffold stage). Keeping `State` as a
/// struct rather than an empty placeholder means future diagnostic
/// fields (per-world dispatch counters, transition rings, etc.) land
/// inside `State` behind the ptr-cast without touching the
/// `LabelleFsmState` component's on-disk shape.
pub const State = struct {
    fn init() State {
        return .{};
    }
};

// ============================================================================
// Result type (RFC §2 — four-variant Result shape shared with the
// other plugin Controllers: pathfinder, worker_controller,
// command_buffer, production, needs_machine, caretaker)
// ============================================================================

pub const Reason = enum {
    /// `setup` hasn't run yet for this world (or `deinit` already
    /// fired). Callers should retry next tick.
    controller_not_setup,
    /// Placeholder — labelle-fsm has no methods that reject today,
    /// but this variant is reserved so the `Reason` shape doesn't
    /// change when future mutator methods grow rejection cases.
    invalid_transition,
};

pub const Result = union(enum) {
    /// Operation completed.
    accepted,
    /// A redundant call that matches the current state. Reserved —
    /// no current method emits this, but the four-variant contract
    /// keeps the union stable for future additions.
    redundant,
    /// Operation cannot run right now; caller can retry next tick.
    deferred: Reason,
    /// Operation cannot be resolved from this state.
    rejected: Reason,
};

// ============================================================================
// Controller
// ============================================================================

pub const Controller = struct {
    /// Allocate the singleton State and attach `LabelleFsmState` to a
    /// freshly-created entity. Called once by the assembler's
    /// generated `PluginControllers.setup` after scene load.
    ///
    /// Idempotent: if a singleton entity already exists (scene reload
    /// / re-entry), free its old State and attach the new one to the
    /// SAME entity — matches the pathfinder / worker_controller /
    /// command_buffer / needs_machine / caretaker / production
    /// Controllers' scene-reload path so we don't leak a stray empty
    /// entity per reload.
    pub fn setup(game: anytype) !void {
        const allocator = game.allocator;

        const st = try allocator.create(State);
        st.* = State.init();
        errdefer allocator.destroy(st);

        if (findStateEntity(game)) |existing_entity| {
            if (game.active_world.ecs_backend.getComponent(existing_entity, LabelleFsmState)) |cs| {
                if (cs.state_ptr != 0) {
                    const old: *State = @ptrFromInt(cs.state_ptr);
                    allocator.destroy(old);
                }
                cs.state_ptr = @intFromPtr(st);
            } else {
                game.active_world.ecs_backend.addComponent(existing_entity, LabelleFsmState{
                    .state_ptr = @intFromPtr(st),
                });
            }
            zlog.info("Controller setup: reused singleton entity {d}", .{existing_entity});
            return;
        }

        const entity = game.createEntity();
        game.active_world.ecs_backend.addComponent(entity, LabelleFsmState{
            .state_ptr = @intFromPtr(st),
        });

        zlog.info("Controller setup: singleton state on entity {d}", .{entity});
    }

    /// Free the singleton State and remove its component. Loop
    /// backends invoke this via `defer` at the end of the init scope;
    /// callback backends invoke it from the cleanup callback.
    pub fn deinit(game: anytype) void {
        const entity = findStateEntity(game) orelse return;
        if (game.active_world.ecs_backend.getComponent(entity, LabelleFsmState)) |cs| {
            if (cs.state_ptr != 0) {
                const st: *State = @ptrFromInt(cs.state_ptr);
                game.allocator.destroy(st);
            }
        }
        if (game.active_world.ecs_backend.hasComponent(entity, LabelleFsmState)) {
            game.active_world.ecs_backend.removeComponent(entity, LabelleFsmState);
        }
        zlog.info("Controller deinit", .{});
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    fn findStateEntity(game: anytype) ?@TypeOf(game.*).EntityType {
        var view = game.active_world.ecs_backend.view(.{LabelleFsmState}, .{});
        defer view.deinit();
        return view.next();
    }

    fn findState(game: anytype) ?*State {
        const entity = findStateEntity(game) orelse return null;
        const cs = game.active_world.ecs_backend.getComponent(entity, LabelleFsmState) orelse return null;
        if (cs.state_ptr == 0) return null;
        return @ptrFromInt(cs.state_ptr);
    }
};
