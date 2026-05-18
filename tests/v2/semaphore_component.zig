//! Semaphore (traffic light) component — paired with
//! `semaphore_behavior.zig`, which holds the guards and actions in a
//! comptime generator function.
//!
//! This is the *external* counterpart to `phone_component.zig`'s
//! *internal* layout. The component file holds the FSM declaration
//! (states, events, transitions) and the data fields; the behavior
//! file holds the guard predicates and action functions. Choose
//! external when guards/actions grow large enough that bundling them
//! into the component struct hurts readability.

const std = @import("std");
const fsm = @import("v2");
const core = @import("labelle-core");

pub const Semaphore = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});

    const behavior = @import("semaphore_behavior.zig").make(@This());

    const _fsm = fsm.Define(*@This(), .{
        .State = enum {
            red,
            green,
            yellow,
            flashing_red, // emergency / off-hours
        },
        .Event = enum {
            emergency_on,
            emergency_off,
            manual_advance,
        },
        .initial = .red,
        .states = .{
            .red = .{
                .on_entry = behavior.actions.resetTimer,
                .auto = .{
                    .{ behavior.guards.redElapsed, .green },
                },
                .permit = .{
                    .{ .emergency_on, .flashing_red },
                    .{ .manual_advance, .green },
                },
            },
            .green = .{
                .on_entry = behavior.actions.resetTimer,
                .auto = .{
                    .{ behavior.guards.greenElapsed, .yellow },
                },
                .permit = .{
                    .{ .emergency_on, .flashing_red },
                    .{ .manual_advance, .yellow },
                },
            },
            .yellow = .{
                .on_entry = behavior.actions.resetTimer,
                .auto = .{
                    .{ behavior.guards.yellowElapsed, .red },
                },
                .permit = .{
                    .{ .emergency_on, .flashing_red },
                    .{ .manual_advance, .red },
                },
            },
            .flashing_red = .{
                .permit = .{
                    .{ .emergency_off, .red },
                },
            },
        },
    });

    pub const State = _fsm.State;
    pub const Event = _fsm.Event;
    pub const Machine = _fsm.Machine;

    state: State = .red,
    /// Time spent in the current state. Incremented by the caller's
    /// per-frame tick; reset to 0 on every state entry.
    timer_ms: u32 = 0,

    // Per-color durations. Configurable per intersection.
    red_duration_ms: u32 = 5000,
    yellow_duration_ms: u32 = 1500,
    green_duration_ms: u32 = 4000,
};
