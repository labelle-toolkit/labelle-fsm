# RFC: labelle-fsm — a serializable, comptime state-machine library

**Status:** Draft for discussion
**Scope:** New `labelle-fsm` plugin, sibling to `labelle-core`, `labelle-engine`, `labelle-gfx`, `labelle-imgui`, `labelle-cli`
**Related:** [flying-platform-labelle#51](https://github.com/Flying-Platform/flying-platform-labelle/issues/51), `flying-platform-labelle/docs/INVESTIGATION-zigfsm.md`, `flying-platform-labelle/docs/RFC-hunger-manager.md`
**Depends on:** `labelle-cli/docs/RFC-plugin-manifest.md` — labelle-fsm ships a `plugin.labelle` declaring `state_machines/` as a convention directory, and the CLI needs to understand that manifest

---

## Problem

Every non-trivial behavior in a labelle game ends up as a small state machine living on an ECS component:

| Component / field                | States                                  | Driver                                |
|----------------------------------|-----------------------------------------|---------------------------------------|
| `HungerCarry.current_step`       | walk-to-source, carry-to-seat           | `16_hunger_manager.tick`              |
| `Sleeping.phase`                 | closing, closed, opening                | `sleep_hooks.frame_end`               |
| `Delivering.current_step`        | walk-to-source, carry-to-dest           | `07_production_system.tick`           |
| Bandit fight phase (planned)     | approaching, stealing, fleeing          | `11_bandit_ai.tick`                   |
| Raid lifecycle (planned)         | requested, approved, active, departed   | `raid_hooks` + bandit scripts         |

These machines share four properties that every off-the-shelf library we've looked at breaks at least one of:

1. **The state value must be a plain enum stored on a component.** Save/load marshals the whole ECS world to JSON via `Saveable`; any pointer, slice, or opaque bit-buffer the library smuggles into the component is a bug waiting to happen.
2. **The tick loop belongs to the game system, not the library.** Sprite frame advancement, timer countdowns, navigation checks, and transitions interleave freely inside one `switch` arm. A library that owns the event loop forces that work to be carved up awkwardly.
3. **Guards read ECS world state**, not internal machine state. "Transition from seeking to carrying iff the worker has no `NavigationIntent` and no `MovementTarget`" is not something you can express against the FSM's own variables.
4. **Instances are cheap and ubiquitous.** One per worker, potentially dozens live at once, created and destroyed freely. No heap, no init ceremony, no per-instance table copying.

zigfsm fails on (1) because its `StateMachine` struct contains bitsets and a `[]const *Handler` slice, and on (3) because guards are `Handler` structs with function pointers closing over state via `@fieldParentPtr`. See the full investigation in `flying-platform-labelle/docs/INVESTIGATION-zigfsm.md`.

Today we hand-roll each machine as a `switch` over a `u8` phase field. This works and is perfectly serializable, but it spreads the transition graph across if/else branches, loses exhaustiveness when new states are added without updating every site, and makes `OnEnter` / `OnExit` semantics implicit ("I put this code right before the assignment that changes the phase — you'll notice, right?"). We want to keep the upsides of the hand-rolled pattern and close those three specific gaps.

## Requirements

### Must-have

- **R1.** The only per-instance state is a plain enum field on the caller's component. No hidden bookkeeping, no allocation, no runtime-initialized tables.
- **R2.** Transitions are declared comptime as a `[]const Transition` attached to a machine type. The transition list lives in `.rodata` and is shared across all instances.
- **R3.** Each transition supports an optional **event** (discriminator for `dispatch`), an optional **guard** (`*const fn(ctx) bool`), **on_exit** (`*const fn(ctx) void`), and **on_enter** (`*const fn(ctx) void`). All function pointers are `*const` baked in at comptime.
- **R4.** The machine is driven imperatively. The caller owns the tick and picks between two call sites: `advance(&state, ctx)` for polled (condition-driven) transitions, and `dispatch(event, &state, ctx)` for event-driven (signal-driven) transitions. Both can coexist on the same machine; per-frame work still lives in the caller.
- **R5.** `Context` is a caller-defined struct. `Event` is a caller-defined enum. The library is generic over `(State, Event, Context)`. Machines with no events use an empty enum (`enum {}`).
- **R6.** Zero external dependencies beyond the Zig standard library. Same stance as every other labelle-\* package.
- **R7.** Works on Zig 0.15.2 (the version everything else in the tree targets).

### Nice-to-have

- **N1.** A `Graphviz` export — walk `transitions` at comptime or runtime and spit out DOT. Useful for RFC diagrams and onboarding docs.
- **N2.** A `validate` helper that comptime-checks properties (no unreachable states, no transitions from a non-enum value, optionally a "every state is reachable from the initial state" assertion).
- **N3.** An `advanceAll(&state, ctx, max_iter)` helper that keeps calling `advance` until no transition fires, bounded by `max_iter` so a misconfigured machine can't hang a frame.
- **N4.** A `transitionsFrom(state) []const Transition` helper for writing tests and gizmos that want to query the shape of the machine.

### Explicit non-goals

- **NG1.** No hierarchical state machines. Flat FSMs only.
- **NG2.** No event bus / pub-sub / queue / deferred delivery. Events are first-class (see NG2a for nuance) — `dispatch(event, ...)` is synchronous and processes one event at a time against one machine instance. If a game needs queued events or broadcast semantics, it builds that at the caller level. The library does not own any queues.
- **NG2a.** No automatic subscription to labelle's hook event system. Machine events are their own enum declared per-machine. If you want a labelle hook event to trigger an FSM event, the hook handler calls `dispatch` explicitly. This keeps labelle-fsm standalone (no dependency on labelle-engine's hook types).
- **NG3.** No runtime transition registration. Everything comptime. If a game needs data-driven state machines loaded from JSON, that is a separate library with a different shape.
- **NG4.** No async / coroutine integration.
- **NG5.** No "history" states or automatic undo. If you need to remember where you came from, store it as a separate component field.
- **NG6.** No events with payloads. The `Event` type is a plain enum. If a transition needs additional data (e.g., a cancel reason), the caller places it in the `Context` struct before calling `dispatch`. Events are discriminators; Context carries data.

## Proposed API

```zig
const std = @import("std");

pub fn StateMachine(
    comptime State: type,
    comptime Event: type,       // use `enum {}` for guard-only machines
    comptime Context: type,
) type {
    return struct {
        const Self = @This();

        /// A pure predicate evaluated against a Context. **Must be side-effect
        /// free** — it may be called more than once per advance/dispatch call
        /// by the debug-mode multi-match check.
        pub const Guard = *const fn (ctx: Context) bool;

        /// A side-effect function run on transition entry or exit. Actions
        /// may mutate the world through pointer fields in Context
        /// (`ctx.game.setPosition(...)`, `ctx.sleeping.*`, etc).
        pub const Action = *const fn (ctx: Context) void;

        pub const Transition = struct {
            from: State,
            to: State,

            /// Discriminator for `dispatch`. `null` means this transition
            /// is *polled* — it's evaluated during `advance(...)`. Non-null
            /// means this transition is *event-driven* — it's only evaluated
            /// during `dispatch(event, ...)` when `event == this.event`.
            event: ?Event = null,

            /// Optional guard. For polled transitions, advance fires the
            /// first transition whose guard passes. For event-driven
            /// transitions, dispatch fires the first matching transition
            /// whose guard passes (if a guard is declared).
            guard: ?Guard = null,

            on_exit: ?Action = null,
            on_enter: ?Action = null,

            /// Opt-out for the debug-mode multi-match safety check (Q3).
            /// Set to true if this transition may intentionally overlap
            /// with lower-priority transitions from the same state — e.g.,
            /// higher-priority "error" transition that might fire alongside
            /// a "finish" transition. Declaration order still decides which
            /// one wins; this flag only suppresses the assertion.
            overlap_allowed: bool = false,
        };

        /// Result of a single advance() call. Polled-only.
        pub const AdvanceResult = union(enum) {
            /// No polled transition's guard passed this frame. Normal state
            /// between transitions — not an error.
            idle,
            fired: struct {
                from: State,
                to: State,
                index: usize, // index into transitions[] for logging
            },
        };

        /// Result of a dispatch() call. Event-driven.
        pub const DispatchResult = union(enum) {
            /// No transition exists for (current_state, event). This is a
            /// legal runtime condition, not an error — "the wake event was
            /// dispatched but the worker is already awake" just does
            /// nothing.
            not_declared,
            /// A matching transition exists but its guard blocked it.
            blocked_by_guard,
            fired: struct {
                from: State,
                to: State,
                event: Event,
                index: usize,
            },
        };

        transitions: []const Transition,

        /// Evaluate *polled* transitions (`event == null`) from the current
        /// state. Runs guards in declaration order; the first guard that
        /// passes fires its on_exit, updates *state, then fires on_enter.
        ///
        /// Never errors. "No guard passed" returns `.idle`.
        pub fn advance(
            comptime self: Self,
            state: *State,
            ctx: Context,
        ) AdvanceResult { ... }

        /// Dispatch an event. Looks up transitions where
        /// `from == state.*` AND `event == e`, runs their guards in
        /// declaration order, fires the first matching one.
        ///
        /// `.not_declared` means no matching transition exists — it is a
        /// normal runtime condition (caller decides to ignore, log, or
        /// retry later), not an error.
        pub fn dispatch(
            comptime self: Self,
            e: Event,
            state: *State,
            ctx: Context,
        ) DispatchResult { ... }

        /// Run on_enter for the initial state. Call once after attaching
        /// the component so the initial entry effects fire.
        pub fn enter(
            comptime self: Self,
            initial: State,
            ctx: Context,
        ) void { ... }

        /// (N3) Advance repeatedly until no polled transition fires.
        /// Bounded to prevent infinite loops from misconfigured machines.
        /// Returns the number of transitions that actually fired.
        pub fn advanceAll(
            comptime self: Self,
            state: *State,
            ctx: Context,
            max_iter: u8,
        ) u8 { ... }
    };
}
```

### Polled vs. event-driven transitions

The two flavors coexist in the same `transitions` slice; the `event` field is the discriminator:

| Flavor         | `event`    | When it fires                                | Good for                                             |
|----------------|------------|----------------------------------------------|------------------------------------------------------|
| **Polled**     | `null`     | During `advance(&state, ctx)` — every frame  | Conditions that become true over time (arrivals, timer expiration, animation completion, ECS state checks) |
| **Event-driven** | non-null | During `dispatch(event, &state, ctx)` — only when explicitly called | Discrete external signals (wake, cancel, finish, damage_taken, key_press) |

**Guidance:**

- If a transition should fire because "something is now true", use a polled guard. Example: `closing → closed` when the curtain animation finishes. The tick polls every frame.
- If a transition should fire because "something happened", use an event. Example: `closed → opening` when a `worker_sleep_end` hook runs. Nothing is polling — the hook calls `dispatch(.wake, ...)` once and that's it.
- Event-driven transitions **can still have a guard** — used as a filter on top of the event ("on cancel event, only cancel if the task was abortable").
- A single state can have both kinds of outgoing transitions. They don't conflict because they're triggered by different call sites.

### Error model

| Situation                                           | Call site                     | Return / behavior                                  |
|-----------------------------------------------------|-------------------------------|----------------------------------------------------|
| **A.** No polled guard passed (normal between-transitions) | `advance(&state, ctx)`   | `AdvanceResult.idle` — not an error                |
| **B.** No transition declared for `(state, event)`  | `dispatch(event, ...)`        | `DispatchResult.not_declared` — not an error       |
| **C.** Matching transition exists but guard blocked | `dispatch(event, ...)`        | `DispatchResult.blocked_by_guard` — not an error   |
| **D.** Debug-mode multi-match without `overlap_allowed` | `advance` or `dispatch`   | `std.debug.panic` — programmer bug, debug-only     |

**Rationale:**

- Case A happens every frame between transitions — the worker hasn't arrived yet, the curtain is still animating. Returning an error here would force every tick site to `try` on something that isn't a bug.
- Case B is the event-driven equivalent of "nothing to do" — e.g., "wake was dispatched but the worker is already awake." The caller decides whether to ignore, log, or act on it. Not an error.
- Case C is "the event is valid but the conditions aren't right" — e.g., "cancel was dispatched but the task isn't abortable." Caller decides what to do. Not an error.
- Case D is caught by the debug multi-match check. In release builds it falls through to first-match-wins semantics. See Q3 for the full argument.

**Consequence:** `StateMachine` has no `error{...}` union. Nothing returns a Zig error. Every runtime condition is either a `.idle` / `.not_declared` / `.blocked_by_guard` / `.fired` variant, or it's a programmer bug caught by a debug assertion.

## Locality — where transitions live

**Every machine lives in its own file under a `state_machines/` directory**, sibling to `components/`, `hooks/`, `events/`, etc. No size threshold, no "small machines inline, big machines extracted" carve-out. One file per machine, named `<domain>_machine.zig`.

### Project structure

```
flying-platform-labelle/
├── components/
│   ├── sleeping.zig           # State enum + component (data only)
│   ├── hunger_carry.zig       # State enum + component (data only)
│   └── delivering.zig         # State enum + component (data only)
├── state_machines/
│   ├── sleep_machine.zig      # Context, guards, actions, transitions
│   ├── hunger_machine.zig
│   └── delivery_machine.zig
├── hooks/
│   └── sleep_hooks.zig        # imports state_machines/sleep_machine, drives the tick
└── scripts/debug/
    └── 16_hunger_manager.zig  # imports state_machines/hunger_machine, drives the tick
```

### Why a dedicated directory (rejecting the alternatives)

- **Inline at the point of use:** reconstructing the machine value inside the tick every frame is noisy and buries the most declarative part of the system inside an imperative function.
- **At module scope in the system file:** works for small machines but mixes data (transitions table) with drive logic. Anything that wants to query the transitions (gizmos, tests, Graphviz export) has to import the whole system file with its hook struct.
- **In the component file next to the State enum:** components are data — they already get imported from everywhere. If the component file starts pulling in game state so actions can mutate it, the import graph inverts. Components must stay import-clean.
- **In a dedicated `state_machines/` file:** answers all the above. Transitions are discoverable (`ls state_machines/`), self-contained, imported by hooks/scripts/tests/gizmos with no baggage, and don't get relocated as a machine grows.

### Mandatory exports from every `state_machines/<domain>_machine.zig`

| Export            | Type                                       | Purpose                                               |
|-------------------|--------------------------------------------|-------------------------------------------------------|
| `pub const Event` | enum (may be empty `enum {}`)              | Event type for event-driven transitions               |
| `pub const Context` | struct                                   | The caller-defined context passed to guards/actions   |
| `pub const Machine` | `fsm.StateMachine(State, Event, Context)`| Type alias so the caller doesn't repeat generic args  |
| `pub const machine` | `Machine` value                          | The instance with the transitions table               |
| `pub const guards`  | nested struct                            | Guard functions — `pub` so tests can call directly    |
| `pub const actions` | nested struct                            | Action functions — `pub` so tests can call directly   |

The State enum stays in the component file because it's data that gets serialized. The machine file imports it. The Event enum lives in the machine file because only the machine and its callers need to know about it — it is not serialized.

## Example: `Sleeping.phase` rewritten

This example shows **both kinds of transitions at work**. The curtain-animation completion is a polled condition (`advance` detects it every frame). The wake-from-sleep signal is an event (`dispatch(.wake)` fired from the `worker_sleep_end` hook).

```zig
// components/sleeping.zig
pub const SleepState = enum { closing, closed, opening };

pub const Sleeping = struct {
    bed_id: u64,
    floor_x: f32,
    floor_y: f32,
    timer: f32 = 0,
    state: SleepState = .closing, // plain enum — serializes trivially
};
```

```zig
// state_machines/sleep_machine.zig
const fsm = @import("labelle-fsm");

const Game = @import("root").Game;
const Entity = Game.EntityType;
const Sleeping = @import("../components/sleeping.zig").Sleeping;
const SleepState = @import("../components/sleeping.zig").SleepState;

/// Events this machine responds to. Dispatched externally by hooks.
pub const Event = enum { wake };

pub const Context = struct {
    game: *Game,
    worker: Entity,
    sleeping: *Sleeping,
    curtain_duration_reached: bool,
};

pub const Machine = fsm.StateMachine(SleepState, Event, Context);

pub const guards = struct {
    pub fn curtainFinished(ctx: Context) bool {
        return ctx.curtain_duration_reached;
    }
};

pub const actions = struct {
    pub fn resetTimer(ctx: Context) void {
        ctx.sleeping.timer = 0;
    }
    pub fn restoreFloor(ctx: Context) void {
        ctx.game.setPosition(ctx.worker, .{
            .x = ctx.sleeping.floor_x,
            .y = ctx.sleeping.floor_y,
        });
        ctx.game.active_world.ecs_backend.removeComponent(ctx.worker, Sleeping);
    }
};

pub const machine: Machine = .{ .transitions = &.{
    // Polled: curtain finished closing naturally → asleep
    .{
        .from = .closing,
        .to = .closed,
        .guard = guards.curtainFinished,
        .on_enter = actions.resetTimer,
    },
    // Event-driven: wake was requested while already asleep
    .{
        .from = .closed,
        .event = .wake,
        .to = .opening,
        .on_enter = actions.resetTimer,
    },
    // Event-driven: wake interrupted us mid-close
    .{
        .from = .closing,
        .event = .wake,
        .to = .opening,
        .on_enter = actions.resetTimer,
    },
    // Polled: curtain finished opening → restore, remove component
    .{
        .from = .opening,
        .to = .opening, // terminal — component removed by on_enter
        .guard = guards.curtainFinished,
        .on_enter = actions.restoreFloor,
    },
} };
```

```zig
// hooks/sleep_hooks.zig
const sleep_machine = @import("../state_machines/sleep_machine.zig");
const Sleeping = @import("../components/sleeping.zig").Sleeping;

pub fn frame_end(self: *SleepHooks, payload: anytype) void {
    const dt = payload.dt;
    const game = getGame(self.game_ptr);

    var view = game.active_world.ecs_backend.view(.{Sleeping}, .{});
    while (view.next()) |worker| {
        const sleeping = game.active_world.ecs_backend.getComponent(worker, Sleeping) orelse continue;
        sleeping.timer += dt;
        advanceCurtainFrame(game, sleeping); // per-frame sprite math stays here

        // Polled transitions only — event-driven ones fire via dispatch elsewhere
        _ = sleep_machine.machine.advance(&sleeping.state, .{
            .game = game,
            .worker = worker,
            .sleeping = sleeping,
            .curtain_duration_reached = sleeping.timer >= CURTAIN_ANIM_DURATION,
        });
    }
    view.deinit();
}

// worker_sleep_end hook handler — dispatch the wake event.
// The FSM fires the correct transition (closed→opening or closing→opening),
// runs its on_enter (resetTimer), no hand-written state field writes.
pub fn worker_sleep_end(self: *SleepHooks, payload: anytype) void {
    const game = getGame(self.game_ptr);
    const worker_entity: @import("root").Game.EntityType = @intCast(payload.worker_id);
    const sleeping = game.active_world.ecs_backend.getComponent(worker_entity, Sleeping) orelse return;

    _ = sleep_machine.machine.dispatch(.wake, &sleeping.state, .{
        .game = game,
        .worker = worker_entity,
        .sleeping = sleeping,
        .curtain_duration_reached = false, // not used for event transitions
    });
}
```

Notice the division of labor:

- **Per-frame sprite work** (`advanceCurtainFrame`) stays inline in the hook. The FSM doesn't know about curtains.
- **Polled transitions** (curtain-finished checks) fire from `frame_end`'s `advance` call.
- **Event-driven transitions** (wake-from-sleep) fire from `worker_sleep_end`'s `dispatch(.wake)` call. The FSM handles the closing→opening vs. closed→opening choice by looking at the current state — the hook doesn't need to know.
- **No bypass of the FSM.** The hook never writes directly to `sleeping.state` — every transition runs through the machine, so `on_enter` / `on_exit` are guaranteed to fire.
- **The hook file has zero FSM types.** It imports `sleep_machine` and calls `advance` / `dispatch`. All declarative logic lives in `state_machines/sleep_machine.zig`.

This is the sweet spot: **transitions are declarative and in one place, per-frame work stays imperative, and discrete signals dispatch through the FSM rather than bypass it.**

## Alternatives considered

### A1. Keep hand-rolling `switch` statements

We've shipped three of these already. It works. The cost is that every new state machine re-invents the same "where do the side effects go" convention, and exhaustiveness checks only fire when you remember to add the new state to every `switch` site. The intent of this RFC is to keep doing this *for the per-frame work* but lift the transition graph into a reusable shape.

### A2. Adopt zigfsm

Blocked on requirement R1 (serialization). See `flying-platform-labelle/docs/INVESTIGATION-zigfsm.md`. The workaround ("store the enum on the component, reconstruct the FSM struct each tick") loses all the value of having the library.

### A3. Build labelle-fsm as proposed

~120 lines of Zig, zero deps, answers every requirement above, and the one ugly bit (`*const fn` actions can't close over locals, so `Context` gets fat) is the same ugly bit zigfsm has, plus all the other off-the-shelf libraries we looked at, plus the hand-rolled version when we pass state around as a tuple.

### A4. Go further — a "behavior" abstraction that also owns per-frame work

Reify per-frame work as `on_tick: *const fn(ctx, dt) TickResult` on each state. The result encodes "stay" vs. "go to state X". This is more declarative but forces every per-frame concern through a function pointer, which hurts when the per-frame work needs heterogeneous ECS access that's awkward to funnel through a single `Context`. Rejected for this RFC — can be revisited later if we find the split becoming annoying.

## Open questions

### Q1. Where should labelle-fsm live in the package graph?

**Decision:** labelle-fsm is a **plugin** declared in games' `project.labelle` `.plugins` list, living as a sibling directory to `labelle-core`, `labelle-engine`, `labelle-imgui`, etc. **Closed.**

Rationale:

- **"Plugin" is labelle's canonical word for optional packages.** `labelle-pathfinder`, `labelle-imgui`, and the `debug` plugin are all declared the same way — an entry in the game's `.plugins` list. The CLI auto-resolves, hardlinks, and generates the `labelle-<name>` import alias. labelle-fsm fits this pattern exactly.
- **`labelle-core` is reserved for type-level primitives** (`Position`, `Saveable`, serialization machinery). FSM is a behavior pattern, one layer up.
- **`labelle-engine` is ECS-aware; labelle-fsm is ECS-agnostic.** Putting an ECS-agnostic library inside the ECS runtime would make it unreachable from tools, tests, and validators that don't want the engine.
- **Independent release cadence.** Iterating on the FSM API in the first few releases is expected. As a plugin, labelle-fsm bumps on its own schedule without dragging `labelle-core` or `labelle-engine` along.

#### Physical location

`/home/alexandre/prj/labelle/labelle-fsm/` — sibling to the other labelle packages. Matches how `labelle-imgui` is laid out.

#### Declaration in a game's `project.labelle`

```zon
.plugins = .{
    .{ .name = "fsm", .repo = "local:../labelle-fsm" },
    .{ .name = "pathfinder", .repo = "@libs/pathfinder" },
    // ... existing plugins ...
},
```

Published version (eventually):

```zon
.plugins = .{
    .{
        .name = "fsm",
        .repo = "https://github.com/Flying-Platform/labelle-fsm",
        .version = "0.1.0",
    },
},
```

#### Usage

```zig
const fsm = @import("labelle-fsm");
const SleepMachine = fsm.StateMachine(SleepState, SleepContext);
```

The CLI's `deps_linker` auto-generates the `labelle-fsm` → `labelle_fsm` mapping as it does for every plugin. No custom build-zig wiring.

#### Plugin manifest

Because labelle-fsm introduces a new convention directory (`state_machines/`), it ships a `plugin.labelle` manifest declaring that directory so the CLI knows to copy and scan it. See `labelle-cli/docs/RFC-plugin-manifest.md` for the manifest system design. labelle-fsm's manifest:

```zon
// labelle-fsm/plugin.labelle
.{
    .name = "fsm",
    .manifest_version = 1,
    .convention_dirs = .{
        .{
            .name = "state_machines",
            .extension = ".zig",
            .mode = .copy_and_scan,
            .optional = true,
        },
    },
}
```

**This is a hard dependency on the plugin-manifest RFC.** labelle-fsm cannot ship before `labelle-cli` understands `plugin.labelle`. The rollout section below reflects this.

### Q2. Should `Context` be passed by value, by const pointer, or be explicitly left to the caller?

**Decision:** by value. `Guard` and `Action` are declared as `*const fn(ctx: Context) bool` / `*const fn(ctx: Context) void`. **Closed.**

Rationale:

- **Contexts are shallow.** Every real Context is pointer fields (`*Game`, `*Sleeping`, ...) plus small scalars (`Entity`, `bool`, `f32`). Total ~24–40 bytes. Copy cost is one SIMD move per call — negligible.
- **Actions still mutate the world** through pointer fields inside the copy: `ctx.sleeping.*`, `ctx.game.setPosition(...)`. The copied Context is a view, not owned data.
- **No transient state in Context.** Because actions receive a fresh copy every call, anything an action writes to `ctx.some_field` evaporates as soon as the call returns. This enforces the "all state lives on the component" rule at the type level — you physically cannot accumulate state in Context between transitions. By-pointer variants would allow this footgun.
- **Aliasing-friendly codegen.** The compiler knows the Context value can't alias anything in the caller's frame, giving it more optimization latitude than `*const Context` would.
- **Matches existing labelle conventions.** Hook payloads and event payloads are already passed by value. Using by-value here keeps the mental model consistent across the codebase.

**Escape hatch for large Contexts:** machines with genuinely large state put a single pointer inside their Context (e.g., `view: *BigView`) rather than embedding the data. The library API stays by-value, the user decides how much state lives behind their pointers. Same pattern as the `*Game` field every Context already has.

**Rejected alternatives:**
- **By const pointer (`*const Context`):** doesn't actually prevent mutation of the things that matter (the pointer fields inside the Context are still usable as mutable pointers), allows the transient-state footgun, and the "const" is purely cosmetic. Saves a ~32-byte copy that isn't worth measuring.
- **Comptime-configurable mode:** doubles the testing surface and invites per-machine inconsistency for no real use case. Every planned machine fits by-value.
- **`anytype` function pointer:** not supported by the Zig language. Function pointers must have a concrete type.

### Q3. What happens when multiple guards from the same state pass simultaneously?

**Decision:** first-match-wins at runtime (declaration order is priority), with a **debug-mode exhaustive check** that asserts on accidental multi-match, and an **`overlap_allowed` opt-out flag** on `Transition` for transitions that intentionally overlap with lower-priority ones. **Closed.**

#### Why the problem mostly disappears with events

Early drafts of this RFC modeled everything as polled guards, which meant distinct events like "cancel" and "finish" looked like overlapping transitions that all needed to be sorted out at `advance` time. That was wrong — those aren't conditions that become true simultaneously, they are discrete events that arrive independently. With first-class events (see Proposed API), the common case becomes:

```zig
.{ .from = .active, .event = .finish, .to = .finished },
.{ .from = .active, .event = .cancel, .to = .cancelled },
.{ .from = .active, .event = .fail,   .to = .error_state },
```

These three transitions cannot race each other. `dispatch(.finish, ...)` only looks at transitions with `event == .finish`; it will never consider the `cancel` or `fail` transitions. Events are the natural discriminator for "which branch did the external world choose", so the multi-match problem Q3 was originally asking about **doesn't exist for event-driven transitions between distinct events**.

#### What's left to worry about

Two scenarios still have multi-match potential:

1. **Two polled transitions from the same state, both with guards that can simultaneously pass.** Example: `HungerCarry.seeking_source → carrying_to_seat` (guard: arrived at source) vs. `HungerCarry.seeking_source → gave_up` (guard: source storage was destroyed). Rare but legitimate — both could be true on the same frame.
2. **Two transitions for the same event from the same state, with different guards.** Example: `.{ .from = .active, .event = .finish, .to = .finished_clean, .guard = guards.wasPerfect }` and `.{ .from = .active, .event = .finish, .to = .finished_partial }` (fallback, no guard). Legitimate — "on finish, go to clean if perfect, otherwise partial."

For both, the answer is: **first-match-wins at runtime, debug check during development, `overlap_allowed` flag for intentional overlap.**

#### Mechanism

**Runtime (release and debug):** iterate in declaration order, fire the first matching transition, stop.

**Debug builds only:** before firing, evaluate every remaining candidate guard from the current state (polled transitions for `advance`, matching-event transitions for `dispatch`). If any of them ALSO passed, check whether the winner was marked `overlap_allowed = true`. If yes, suppress the assertion — the author declared the overlap intentional. If no, panic:

```
thread panic: labelle-fsm: multiple guards matched from state .choosing
  transition[0]: .choosing -> .red_path    (guard: urgencyBelow20)   MATCHED
  transition[1]: .choosing -> .yellow_path (guard: urgencyBelow50)   MATCHED
  first-match-wins picked transition[0], but transition[1] also passed.
  if this is intentional, declare the higher-priority transition first and
  add `.overlap_allowed = true` to transition[0].
```

#### Intentional overlap example (polled)

```zig
pub const machine: Machine = .{ .transitions = &.{
    // Priority order: source destroyed > arrived at source
    .{
        .from = .seeking_source,
        .to = .gave_up,
        .guard = guards.sourceDestroyed,
        .overlap_allowed = true,   // may also match `arrivedAtSource` same frame
    },
    .{
        .from = .seeking_source,
        .to = .carrying_to_seat,
        .guard = guards.arrivedAtSource,
        .on_enter = actions.pickUp,
    },
} };
```

Read top-to-bottom: `gave_up` takes precedence over `carrying_to_seat`. The flag says "I know these can overlap, it's by design."

#### Why not an explicit priority field

Priority fields (`priority: i8 = 0`) sound cleaner but:

- **Tax every machine.** Most machines have no overlap; they'd all carry a meaningless `.priority = 0` field for the rare case.
- **Break vertical reading.** With explicit priorities, source order conveys nothing, so readers have to scan every transition to find the highest-priority one.
- **Don't catch accidental overlap** — if two guards both pass and the author gave them the same priority, the silent-wrong-answer bug is back.

Declaration order + opt-out flag is cheaper, more readable, and safer (the debug check catches accidents that a priority field couldn't).

#### Guards must be pure

The debug-mode exhaustive check requires that guards be idempotent and side-effect-free. A guard that increments a counter or logs something would produce wrong results when called twice (once to decide, once to check). The library's `Guard` doc comment states this as a hard requirement:

```zig
/// A guard predicate. **Must be pure** — no mutation, no I/O, no event
/// emission, no allocation. Guards may be called more than once per
/// advance()/dispatch() in debug builds as part of the multi-match safety
/// check. Side effects belong in on_exit and on_enter actions.
pub const Guard = *const fn (ctx: Context) bool;
```

### Q4. Should `enter()` be called automatically when the component is attached, or left to the caller?

If we can hook into `Saveable.postLoad`, we could call `enter()` automatically after load. But that only runs on load, not on initial attach. Doing it automatically on every write to the state field is also tempting but requires a setter pattern that doesn't fit Zig naturally.

**Decision:** caller-explicit. Requires discipline but keeps the library's surface area small and predictable. **Closed.**

### Q5. Graphviz export — nice-to-have now or defer?

Walking the transitions array and printing DOT is ~20 lines. The real cost is documenting how to run it and integrating it with a docs build. Low value right now; high value if we start drawing gameplay flow diagrams for designer conversations.

**Preference:** defer. Stub out the function signature (`pub fn toDot(writer: anytype) !void`) but leave it unimplemented until someone actually wants the diagram.

### Q6. Should we migrate `HungerCarry` / `Sleeping` / `Delivering` all at once, or one at a time?

Migrating one first gives us feedback before committing the other two. `Sleeping` is the best candidate: three states, clean transitions, per-frame work (curtain animation) is clearly separable from transitions (entering `.closed`, entering the terminal). `HungerCarry` is more involved because it interacts with the delivery carry pattern. `Delivering` is risky because production is load-bearing.

**Decision:** one-at-a-time, `Sleeping` → `state_machines/sleep_machine.zig` first. If that reveals an awkward corner of the API, fix the API before the second migration. **Closed.**

### Q7. Does this interact with the planned save system changes?

`Saveable` already handles plain enum fields, so R1 is met by default. As long as the state field on the component is a plain enum the existing serialization path just works. No changes to `labelle-core` save machinery expected.

## Risks

- **R_1. The `Context` struct grows unbounded** as machines gain more dependencies. Mitigation: allow per-machine sub-contexts; it's just a type parameter.
- **R_2. Action function pointers cannot capture locals.** Every bit of state an action needs must be reachable through `Context`. This is by design (serializable, comptime) but will feel verbose at first. Mitigation: a small style guide showing the "bundle everything into ctx" pattern.
- **R_3. Inline-for over transitions bloats the binary** at each `advance` site. Mitigation: for ≤20 transitions per machine this is negligible; if a machine grows past that, revisit the impl (maybe a comptime-built dispatch table).
- **R_4. First-match-wins is subtle.** If two guards pass and you meant the other one to fire, the bug is silent. Mitigation: debug-mode exhaustive multi-match check that panics with the offending indices, plus an `overlap_allowed` opt-out flag on `Transition` for intentional precedence. See Q3.
- **R_5. We never actually migrate the existing machines.** The library exists but gets bypassed in new code. Mitigation: migrate `Sleeping` as part of the same PR that introduces the library, so there's at least one consumer from day one.

## Proposed rollout

This rollout has an **upstream dependency on the labelle-cli plugin-manifest RFC**. Steps 1–2 happen in `labelle-cli`, steps 3–7 happen in `labelle-fsm`, steps 8–11 happen in `flying-platform-labelle`.

### Upstream (`labelle-cli`)

1. **Land `labelle-cli/docs/RFC-plugin-manifest.md`** — design review, decisions on its open questions.
2. **Implement the plugin manifest system** — `plugin_manifest.zig` module, generator integration, tests, docs, minor version bump. This unblocks every plugin that wants to introduce a new convention directory, not just labelle-fsm.

### The plugin (`labelle-fsm`)

3. **Create `labelle-fsm` plugin** with `build.zig`, `build.zig.zon`, `src/root.zig`, `test/fsm_test.zig`, and `plugin.labelle`. Match the shape of `labelle-pathfinder` with the manifest addition.
4. **Write the library** — ~150 lines of code plus tests covering: advance (polled), dispatch (event-driven), enter, guards (pure), on_exit, on_enter, first-match semantics, `AdvanceResult`, `DispatchResult` variants (idle, not_declared, blocked_by_guard, fired), debug-mode multi-match assertion, `overlap_allowed` suppression, empty-Event (`enum {}`) machines compiling without dispatch call sites.
5. **Validate against a fake game project** — create an integration test where the generator is run on a minimal game with `labelle-fsm` in its `.plugins` list and a `state_machines/` directory. Confirm the directory is copied to `.labelle/<backend>_<platform>/state_machines/` and imports resolve.
6. **Tag v0.1.0**.
7. **Publish** or keep as local-only (`local:../labelle-fsm`) for now.

### Consumer migration (`flying-platform-labelle`)

8. **Add the plugin** to `project.labelle`'s `.plugins` list. Run `labelle generate` to verify the manifest is read and the directory is wired up.
9. **Create `flying-platform-labelle/state_machines/`** and add `state_machines/sleep_machine.zig` as the first consumer.
10. **Migrate `Sleeping.phase`** on a branch: the `hooks/sleep_hooks.zig` file loses its transition logic and imports `state_machines/sleep_machine`. Run the existing regression (`debug/sleep_animation_test`). If the migration is clean, merge it.
11. **Write an ADR** in the game repo at `docs/ADR-fsm-conventions.md` capturing the naming/structure conventions (State enum in the component file, full machine in `state_machines/<domain>_machine.zig`, mandatory exports, driver in the hook or script).
12. **Migrate `HungerCarry` → `state_machines/hunger_machine.zig` and `Delivering` → `state_machines/delivery_machine.zig`** in separate PRs once the pattern is proven.

## Next steps for this RFC

Open questions that still need a decision:

- [ ] **Q5** — Graphviz export in v1 or deferred?

Closed:

- [x] **Q1** — labelle-fsm is a plugin, sibling to labelle-core, ships a `plugin.labelle` manifest declaring `state_machines/`. Depends on `labelle-cli/docs/RFC-plugin-manifest.md`. (closed)
- [x] **Q2** — Context passed by value. Enforces "no transient state in Context" at the type level. (closed)
- [x] **Q3** — first-match-wins at runtime + debug-mode exhaustive multi-match assertion + `overlap_allowed` opt-out. Most of the problem dissolves once events are first-class (see Proposed API). (closed)
- [x] **Q4** — caller-explicit `enter()` (closed in discussion)
- [x] **Q6** — migrate `Sleeping` → `state_machines/sleep_machine.zig` first, others follow (closed in discussion)
- [x] **Locality** — every machine lives in its own file under `state_machines/`, no size threshold (closed in discussion)
- [x] **Error model** — no runtime error union. `advance` returns `AdvanceResult`, `dispatch` returns `DispatchResult`, `.not_declared` / `.blocked_by_guard` are normal runtime conditions, debug multi-match asserts. (closed)
- [x] **Events as first-class** — NG2 walked back. Transitions have an optional `event` field; `dispatch(event, ...)` handles discrete signals alongside `advance(...)` for polled conditions. (closed)

Once Q5 lands, and once the `labelle-cli` plugin-manifest RFC is approved and implemented, I can open a PR that creates the `labelle-fsm` plugin and migrates the first consumer.
