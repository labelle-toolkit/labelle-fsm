//! Sleep tick system — the "every frame" driver for sleeping workers.
//! This is the equivalent of sleep_hooks.frame_end in a real labelle game.
//! It owns the per-frame work (timer advance, sprite math in a real game)
//! and calls machine.advance() for polled transitions.

const std = @import("std");
const ecs = @import("ecs");

const sleeping_mod = @import("../components/sleeping.zig");
const Sleeping = sleeping_mod.Sleeping;
const sleep_machine = @import("../state_machines/sleep_machine.zig");

pub const CURTAIN_DURATION: f32 = 0.5;

/// Called once per frame. Iterates every entity with a Sleeping component,
/// advances its timer, and lets the state machine handle polled transitions.
pub fn tick(reg: *ecs.Registry, dt: f32) void {
    var view = reg.view(.{Sleeping}, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        // Single-component view's `get` drops the type parameter.
        const sleeping = view.get(entity);
        sleeping.timer += dt;

        // Per-frame work would go here in a real system:
        //   - advanceCurtainFrame(game, sleeping)
        //   - mark sprite dirty
        //   - whatever else the hook wants to do
        // The FSM doesn't know about any of that.

        const curtain_done = sleeping.timer >= CURTAIN_DURATION;
        const result = sleep_machine.machine.advance(&sleeping.state, .{
            .reg = reg,
            .entity = entity,
            .sleeping = sleeping,
            .curtain_done = curtain_done,
        });

        switch (result) {
            .idle => {},
            .fired => |f| std.debug.print(
                "  tick: entity {d} advanced {s} -> {s}\n",
                .{ entity.index, @tagName(f.from), @tagName(f.to) },
            ),
        }
    }
}
