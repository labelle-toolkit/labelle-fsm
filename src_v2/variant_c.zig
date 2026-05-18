//! variant_c — v1 shape preserved, with hand-written legality schema
//! layered on top as a comptime validation step.
//!
//! Smallest possible delta from v1:
//!   - `StateMachine(State, Event, Context)` still returns a type whose
//!     value carries `transitions: []const Transition`. Lookup is still
//!     a runtime linear scan, multi-match still runtime-debug.
//!   - The *only* addition is `validate(reachable_from)` — a comptime
//!     function that walks the transitions and @compileErrors if any
//!     transition's (from, to) pair escapes the schema.
//!   - Authors opt in by calling `validate` at machine-declaration site:
//!         pub const machine: Machine = .{ .transitions = &.{ ... } };
//!         comptime { machine.validate(reachable_from); }
//!
//! Tradeoff:
//!   + Tiny code change in the library; no API churn for existing v1
//!     consumers. Existing sleep_machine / hunger_machine code continues
//!     to work unmodified.
//!   + Authors get the schema-drift check at the cost of one extra
//!     declaration.
//!   - No dispatch-table speedup; no introspection helpers.
//!   - Schema check is opt-in per machine, so easy to forget.

const std = @import("std");

pub fn StateMachine(
    comptime State: type,
    comptime Event: type,
    comptime Context: type,
) type {
    return struct {
        const Self = @This();

        pub const Guard = *const fn (ctx: Context) bool;
        pub const Action = *const fn (ctx: Context) void;

        pub const Transition = struct {
            from: State,
            to: State,
            event: ?Event = null,
            guard: ?Guard = null,
            on_exit: ?Action = null,
            on_enter: ?Action = null,
            overlap_allowed: bool = false,
        };

        pub const AdvanceResult = union(enum) {
            idle,
            fired: Fired,
            pub const Fired = struct { from: State, to: State, index: usize };
        };

        pub const DispatchResult = union(enum) {
            not_declared,
            blocked_by_guard,
            fired: Fired,
            pub const Fired = struct {
                from: State,
                to: State,
                event: Event,
                index: usize,
            };
        };

        transitions: []const Transition,

        pub fn advance(self: Self, state: *State, ctx: Context) AdvanceResult {
            const current = state.*;
            var winner_idx: ?usize = null;
            for (self.transitions, 0..) |t, i| {
                if (t.from != current) continue;
                if (t.event != null) continue;
                const passes = if (t.guard) |g| g(ctx) else true;
                if (!passes) continue;
                if (winner_idx == null) {
                    winner_idx = i;
                    if (!std.debug.runtime_safety) break;
                    if (t.overlap_allowed) break;
                } else {
                    const wi = winner_idx.?;
                    if (!self.transitions[wi].overlap_allowed) {
                        std.debug.panic("labelle-fsm: multi-match from .{s}", .{@tagName(current)});
                    }
                }
            }
            if (winner_idx) |idx| {
                const t = self.transitions[idx];
                if (t.on_exit) |a| a(ctx);
                state.* = t.to;
                if (t.on_enter) |a| a(ctx);
                return .{ .fired = .{ .from = current, .to = t.to, .index = idx } };
            }
            return .idle;
        }

        pub fn dispatch(self: Self, event: Event, state: *State, ctx: Context) DispatchResult {
            const current = state.*;
            var winner_idx: ?usize = null;
            var saw_declared = false;
            for (self.transitions, 0..) |t, i| {
                if (t.from != current) continue;
                if (t.event == null) continue;
                if (t.event.? != event) continue;
                saw_declared = true;
                const passes = if (t.guard) |g| g(ctx) else true;
                if (!passes) continue;
                if (winner_idx == null) winner_idx = i;
            }
            if (winner_idx) |idx| {
                const t = self.transitions[idx];
                if (t.on_exit) |a| a(ctx);
                state.* = t.to;
                if (t.on_enter) |a| a(ctx);
                return .{ .fired = .{
                    .from = current,
                    .to = t.to,
                    .event = event,
                    .index = idx,
                } };
            }
            if (saw_declared) return .blocked_by_guard;
            return .not_declared;
        }

        /// Comptime legality check. Pass the hand-written schema; the
        /// function @compileErrors if any transition declares a `to`
        /// that isn't in `reachable_from[from]`.
        pub fn validate(
            self: Self,
            comptime reachable_from: std.EnumArray(State, std.EnumSet(State)),
        ) void {
            comptime {
                for (self.transitions) |t| {
                    if (!reachable_from.get(t.from).contains(t.to)) {
                        @compileError("illegal transition: ." ++ @tagName(t.from) ++
                            " -> ." ++ @tagName(t.to) ++
                            " not in reachable_from[." ++ @tagName(t.from) ++ "]");
                    }
                }
            }
        }
    };
}

// ============================================================================
// Example
// ============================================================================

const testing = std.testing;

const SleepState = enum { closing, closed, opening, awake };
const SleepEvent = enum { wake, force_sleep };
const SleepCtx = struct {
    curtain_done: bool,
    opening_done: bool,
};

const SleepGuards = struct {
    fn curtainDone(c: SleepCtx) bool {
        return c.curtain_done;
    }
    fn openingDone(c: SleepCtx) bool {
        return c.opening_done;
    }
};

const SleepMachineT = StateMachine(SleepState, SleepEvent, SleepCtx);

const sleep_reachable = std.EnumArray(SleepState, std.EnumSet(SleepState)).init(.{
    .closing = std.EnumSet(SleepState).initMany(&.{ .closed, .opening }),
    .closed = std.EnumSet(SleepState).initMany(&.{.opening}),
    .opening = std.EnumSet(SleepState).initMany(&.{.awake}),
    .awake = std.EnumSet(SleepState).initMany(&.{.closing}),
});

const sleep_machine: SleepMachineT = .{ .transitions = &.{
    .{ .from = .closing, .to = .closed, .guard = SleepGuards.curtainDone },
    .{ .from = .opening, .to = .awake, .guard = SleepGuards.openingDone },
    .{ .from = .closed, .event = .wake, .to = .opening },
    .{ .from = .closing, .event = .wake, .to = .opening },
    .{ .from = .awake, .event = .force_sleep, .to = .closing },
} };

comptime {
    sleep_machine.validate(sleep_reachable);
}

test "variant_c: polled and dispatch still work" {
    var s: SleepState = .closing;
    const r1 = sleep_machine.advance(&s, .{ .curtain_done = true, .opening_done = false });
    try testing.expect(r1 == .fired);
    try testing.expectEqual(SleepState.closed, s);

    var s2: SleepState = .awake;
    const r2 = sleep_machine.dispatch(.force_sleep, &s2, .{ .curtain_done = false, .opening_done = false });
    try testing.expect(r2 == .fired);
    try testing.expectEqual(SleepState.closing, s2);
}
