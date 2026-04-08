# labelle-fsm

A comptime, zero-allocation, serializable state-machine library for [labelle](https://github.com/labelle-toolkit) games.

> Per-instance state is a plain enum on a component. The library itself holds nothing at runtime — every transition, guard, and action is comptime data shared across all instances. State survives save/load via the caller's existing serialization, with no library glue.

## Status

**v0.1.0 — preview.** Depends on [labelle-cli plugin manifest support](https://github.com/labelle-toolkit/labelle-cli/pull/121) (in review). Once that lands, labelle-fsm can be declared as a plugin in any game's `project.labelle`.

## Why this exists

Every non-trivial behavior in a labelle game ends up as a small state machine living on an ECS component (`Sleeping.phase`, `HungerCarry.current_step`, `Delivering.current_step`, ...). Hand-rolled `switch` statements work but spread the transition graph across files and lose exhaustiveness. Off-the-shelf FSM libraries break the serialization invariant — see [`docs/INVESTIGATION-zigfsm.md`](https://github.com/Flying-Platform/flying-platform-labelle/blob/feat/30-eat-animation/docs/INVESTIGATION-zigfsm.md) for the full evaluation of `cryptocode/zigfsm` and why it didn't fit.

This library exists because no off-the-shelf option keeps state on a plain enum field of a component. The full design is in [`RFC.md`](RFC.md).

## Installation

Once labelle-cli with plugin manifest support is released, declare the plugin in your `project.labelle`:

```zon
.plugins = .{
    .{ .name = "fsm", .repo = "local:../labelle-fsm" },
    // or, eventually:
    // .{ .name = "fsm", .repo = "https://github.com/labelle-toolkit/labelle-fsm", .version = "0.1.0" },
},
```

The CLI will:

1. Resolve the plugin and link it into your build as `@import("labelle-fsm")`.
2. Read the bundled `plugin.labelle` manifest, which declares `state_machines/` as a convention directory.
3. Copy `state_machines/*.zig` from your game project into the generated build target so machine files are available alongside your scripts and hooks.

## Usage

Per the convention recommended in the RFC, every machine lives in its own file under `state_machines/<domain>_machine.zig`. Each file exports the same five symbols:

- `pub const Event` — discriminator for `dispatch`, or `enum {}` if the machine has none
- `pub const Context` — what guards and actions receive (passed by value)
- `pub const Machine` — type alias `fsm.StateMachine(State, Event, Context)`
- `pub const guards` — pure predicate functions
- `pub const actions` — side-effect functions for `on_exit` / `on_enter`
- `pub const machine` — the instance with the comptime `transitions` slice

Minimal example:

```zig
// state_machines/sleep_machine.zig
const fsm = @import("labelle-fsm");
const SleepState = @import("../components/sleeping.zig").SleepState;

pub const Event = enum { wake };

pub const Context = struct {
    sleeping: *@import("../components/sleeping.zig").Sleeping,
    curtain_done: bool,
};

pub const Machine = fsm.StateMachine(SleepState, Event, Context);

pub const guards = struct {
    pub fn curtainFinished(ctx: Context) bool {
        return ctx.curtain_done;
    }
};

pub const actions = struct {
    pub fn resetTimer(ctx: Context) void {
        ctx.sleeping.timer = 0;
    }
};

pub const machine: Machine = .{ .transitions = &.{
    .{ .from = .closing, .to = .closed, .guard = guards.curtainFinished, .on_enter = actions.resetTimer },
    .{ .from = .closed,  .event = .wake, .to = .opening, .on_enter = actions.resetTimer },
    .{ .from = .closing, .event = .wake, .to = .opening, .on_enter = actions.resetTimer },
} };
```

A hook or script driving the machine:

```zig
const sleep_machine = @import("../state_machines/sleep_machine.zig");

// Per-frame: poll the polled transitions
_ = sleep_machine.machine.advance(&sleeping.state, ctx);

// External event: dispatch through the FSM (no bypass)
_ = sleep_machine.machine.dispatch(.wake, &sleeping.state, ctx);
```

A working end-to-end example using `zig-ecs` lives on the [`investigate/poc-zig-ecs`](https://github.com/labelle-toolkit/labelle-fsm/tree/investigate/poc-zig-ecs) branch under `poc/`.

## Two flavors of transition

| Flavor          | `event`    | When it fires                                                                | Good for                                                  |
|-----------------|------------|------------------------------------------------------------------------------|-----------------------------------------------------------|
| **Polled**      | `null`     | During `advance(&state, ctx)` — every frame                                 | Conditions becoming true over time (arrivals, timers)     |
| **Event-driven**| non-null   | During `dispatch(event, &state, ctx)` — only when explicitly called          | Discrete external signals (wake, cancel, finish, damage)  |

Both can coexist in the same machine. See the RFC's "Polled vs. event-driven transitions" section for guidance.

## Testing

```bash
zig build test
```

The library ships with unit tests covering `advance`, `dispatch`, `on_enter` / `on_exit` ordering, polled / event coexistence, the debug-mode multi-match assertion, and `overlap_allowed` suppression.

## Design discussions

- [`RFC.md`](RFC.md) — full design rationale, all closed decisions, rejected alternatives, rollout plan
- [labelle-cli#121](https://github.com/labelle-toolkit/labelle-cli/pull/121) — plugin manifest support (prerequisite)
- [`investigate/poc-zig-ecs`](https://github.com/labelle-toolkit/labelle-fsm/tree/investigate/poc-zig-ecs) — POC validating the design against `prime31/zig-ecs`
