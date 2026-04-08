//! Sleep state machine — all the declarative parts of the Sleeping
//! behavior live here. Nothing else in the POC declares transitions.
//!
//! Follows the mandatory-exports convention from the RFC:
//!   - pub const Event
//!   - pub const Context
//!   - pub const Machine
//!   - pub const machine
//!   - pub const guards
//!   - pub const actions

const std = @import("std");
const ecs = @import("ecs");
const fsm = @import("../lib/fsm.zig");

const sleeping_mod = @import("../components/sleeping.zig");
const SleepState = sleeping_mod.SleepState;
const Sleeping = sleeping_mod.Sleeping;

// ---------------------------------------------------------------------------
// Events this machine responds to. Dispatched externally by hooks.
// ---------------------------------------------------------------------------

pub const Event = enum { wake };

// ---------------------------------------------------------------------------
// Context — what guards and actions receive. Passed by value.
// All per-call state lives behind pointers inside this struct.
// ---------------------------------------------------------------------------

pub const Context = struct {
    reg: *ecs.Registry,
    entity: ecs.Entity,
    sleeping: *Sleeping,
    /// Set by the tick caller right before calling advance(). Irrelevant
    /// for dispatch() call sites — passed as false there.
    curtain_done: bool,
};

pub const Machine = fsm.StateMachine(SleepState, Event, Context);

// ---------------------------------------------------------------------------
// Guards — pure predicates. No mutation, no I/O, no allocation.
// ---------------------------------------------------------------------------

pub const guards = struct {
    pub fn curtainFinished(ctx: Context) bool {
        return ctx.curtain_done;
    }
};

// ---------------------------------------------------------------------------
// Actions — side effects. Fire on on_exit / on_enter.
// ---------------------------------------------------------------------------

pub const actions = struct {
    pub fn resetTimer(ctx: Context) void {
        ctx.sleeping.timer = 0;
        std.debug.print("    [on_enter] reset timer\n", .{});
    }

    pub fn restoreFloor(ctx: Context) void {
        std.debug.print(
            "    [on_enter] restore worker to floor ({d},{d}), remove Sleeping\n",
            .{ ctx.sleeping.floor_x, ctx.sleeping.floor_y },
        );
        // Real labelle hook would call ctx.game.setPosition(...) here.
        ctx.reg.remove(Sleeping, ctx.entity);
    }
};

// ---------------------------------------------------------------------------
// Transitions — the declarative graph. Read top-to-bottom for priority.
// ---------------------------------------------------------------------------

pub const machine: Machine = .{ .transitions = &.{
    // Polled: curtain finished closing naturally → asleep
    .{
        .from = .closing,
        .to = .closed,
        .guard = guards.curtainFinished,
        .on_enter = actions.resetTimer,
    },
    // Event-driven: wake requested while asleep
    .{
        .from = .closed,
        .event = .wake,
        .to = .opening,
        .on_enter = actions.resetTimer,
    },
    // Event-driven: wake interrupted mid-close
    .{
        .from = .closing,
        .event = .wake,
        .to = .opening,
        .on_enter = actions.resetTimer,
    },
    // Polled: opening animation finished → restore, remove component
    .{
        .from = .opening,
        .to = .opening, // terminal — on_enter removes the component
        .guard = guards.curtainFinished,
        .on_enter = actions.restoreFloor,
    },
} };
