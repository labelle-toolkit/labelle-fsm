//! Sleep hooks — the event side of the Sleeping behavior. In a real
//! labelle game this file would hold HungerHooks-like struct with
//! game_ptr; here we just expose free functions for the POC.
//!
//! The key point: this file calls machine.dispatch(.wake, ...) rather
//! than writing directly to sleeping.state. That makes on_enter fire,
//! keeps the FSM in charge of transitions, and matches exactly how the
//! RFC describes event-driven transitions.

const std = @import("std");
const ecs = @import("ecs");

const sleeping_mod = @import("../components/sleeping.zig");
const Sleeping = sleeping_mod.Sleeping;
const sleep_machine = @import("../state_machines/sleep_machine.zig");

/// Equivalent of labelle's `worker_sleep_end` hook handler. Called
/// when some external system decides a worker should wake up.
pub fn workerSleepEnd(reg: *ecs.Registry, entity: ecs.Entity) void {
    if (!reg.has(Sleeping, entity)) {
        std.debug.print(
            "  workerSleepEnd: entity {d} not sleeping, ignored\n",
            .{entity.index},
        );
        return;
    }
    const sleeping = reg.get(Sleeping, entity);
    std.debug.print(
        "  workerSleepEnd: dispatch .wake to entity {d} (state = .{s})\n",
        .{ entity.index, @tagName(sleeping.state) },
    );

    const result = sleep_machine.machine.dispatch(.wake, &sleeping.state, .{
        .reg = reg,
        .entity = entity,
        .sleeping = sleeping,
        .curtain_done = false,
    });

    switch (result) {
        .not_declared => std.debug.print(
            "    dispatch: not_declared (no wake from current state)\n",
            .{},
        ),
        .blocked_by_guard => std.debug.print(
            "    dispatch: blocked_by_guard\n",
            .{},
        ),
        .fired => |f| std.debug.print(
            "    dispatch: fired {s} -> {s} on .{s}\n",
            .{ @tagName(f.from), @tagName(f.to), @tagName(f.event) },
        ),
    }
}
