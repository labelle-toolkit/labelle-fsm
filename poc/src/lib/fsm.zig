//! labelle-fsm — POC implementation of the state-machine library proposed
//! in ../RFC.md. Everything here is load-bearing for the RFC's claims:
//! if the POC breaks, the RFC is wrong.
//!
//! Design invariants:
//!   1. Per-instance state = the caller's State enum (plain value on a
//!      component). The StateMachine struct holds only a comptime slice.
//!   2. Transitions are declared comptime. Guards and actions are
//!      *const fn pointers baked in at comptime.
//!   3. Two flavors of transition in one table:
//!        - polled      (event == null) — fired by advance()
//!        - event-driven (event != null) — fired by dispatch(event)
//!   4. Context is passed by value. Guards and actions must be pure —
//!      no mutation of Context fields will survive across calls (by
//!      design, to keep state on components).
//!   5. Multi-match safety: first-match-wins at runtime, debug build adds
//!      an exhaustive check that asserts on accidental overlap. Authors
//!      can opt out per transition with overlap_allowed = true.

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
            /// null = polled (fires on advance), non-null = event-driven
            /// (fires on dispatch(event)).
            event: ?Event = null,
            /// Must be pure if present — the debug multi-match check
            /// may call it more than once per advance/dispatch.
            guard: ?Guard = null,
            on_exit: ?Action = null,
            on_enter: ?Action = null,
            /// Suppress the debug multi-match assertion for this
            /// transition. Set when a higher-priority transition
            /// intentionally overlaps with lower-priority siblings.
            overlap_allowed: bool = false,
        };

        pub const AdvanceResult = union(enum) {
            idle,
            fired: Fired,

            pub const Fired = struct {
                from: State,
                to: State,
                index: usize,
            };
        };

        pub const DispatchResult = union(enum) {
            /// No transition declared for (current state, event).
            /// A legal runtime condition, not an error.
            not_declared,
            /// Transition exists but its guard blocked it.
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

        /// Fire the first polled transition whose guard passes.
        /// Per-frame call from the caller's tick.
        pub fn advance(self: Self, state: *State, ctx: Context) AdvanceResult {
            const current = state.*;
            var winner_idx: ?usize = null;

            for (self.transitions, 0..) |t, i| {
                if (t.from != current) continue;
                if (t.event != null) continue; // event-driven, skip during advance

                const passes = if (t.guard) |g| g(ctx) else true;
                if (!passes) continue;

                if (winner_idx == null) {
                    winner_idx = i;
                    if (!std.debug.runtime_safety) break;
                    if (t.overlap_allowed) break;
                } else {
                    // Debug-mode multi-match check.
                    const wi = winner_idx.?;
                    if (!self.transitions[wi].overlap_allowed) {
                        multiMatchPanic(
                            @tagName(current),
                            wi, self.transitions[wi],
                            i, t,
                        );
                    }
                    // winner already allowed overlap — keep it
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

        /// Dispatch an event. Fires the first matching event-driven
        /// transition from the current state whose guard passes.
        pub fn dispatch(
            self: Self,
            event: Event,
            state: *State,
            ctx: Context,
        ) DispatchResult {
            const current = state.*;
            var winner_idx: ?usize = null;
            var saw_declared = false;

            for (self.transitions, 0..) |t, i| {
                if (t.from != current) continue;
                if (t.event == null) continue; // polled, skip during dispatch
                if (t.event.? != event) continue;

                saw_declared = true;
                const passes = if (t.guard) |g| g(ctx) else true;
                if (!passes) continue;

                if (winner_idx == null) {
                    winner_idx = i;
                    if (!std.debug.runtime_safety) break;
                    if (t.overlap_allowed) break;
                } else {
                    const wi = winner_idx.?;
                    if (!self.transitions[wi].overlap_allowed) {
                        multiMatchPanic(
                            @tagName(current),
                            wi, self.transitions[wi],
                            i, t,
                        );
                    }
                }
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

        /// Run on_enter for the initial state. Call once after attaching
        /// the component so initial entry effects fire.
        pub fn enter(self: Self, initial: State, ctx: Context) void {
            for (self.transitions) |t| {
                if (t.to == initial) {
                    if (t.on_enter) |a| {
                        a(ctx);
                        return;
                    }
                }
            }
        }

        fn multiMatchPanic(
            state_name: []const u8,
            winner_idx: usize,
            winner: Transition,
            other_idx: usize,
            other: Transition,
        ) noreturn {
            std.debug.panic(
                "labelle-fsm: multiple guards matched from state .{s}\n" ++
                    "  transition[{d}]: .{s} -> .{s} MATCHED (winner, first-match)\n" ++
                    "  transition[{d}]: .{s} -> .{s} ALSO MATCHED\n" ++
                    "  if this overlap is intentional, set .overlap_allowed = true on transition[{d}]",
                .{
                    state_name,
                    winner_idx, @tagName(winner.from), @tagName(winner.to),
                    other_idx, @tagName(other.from), @tagName(other.to),
                    winner_idx,
                },
            );
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "advance: polled, single guard, fires" {
    const S = enum { a, b };
    const E = enum {};
    const Ctx = struct { ready: bool };

    const M = StateMachine(S, E, Ctx);

    const guards = struct {
        fn ready(c: Ctx) bool {
            return c.ready;
        }
    };

    const m = M{ .transitions = &.{
        .{ .from = .a, .to = .b, .guard = guards.ready },
    } };

    var s: S = .a;

    // Not ready — idle
    const r1 = m.advance(&s, .{ .ready = false });
    try testing.expect(r1 == .idle);
    try testing.expectEqual(S.a, s);

    // Ready — fires
    const r2 = m.advance(&s, .{ .ready = true });
    try testing.expect(r2 == .fired);
    try testing.expectEqual(S.b, s);
    try testing.expectEqual(S.a, r2.fired.from);
    try testing.expectEqual(S.b, r2.fired.to);
}

test "advance: on_exit and on_enter fire in order" {
    const S = enum { a, b };
    const E = enum {};
    const Ctx = struct { log: *std.array_list.Managed(u8) };

    const M = StateMachine(S, E, Ctx);

    const guards = struct {
        fn always(_: Ctx) bool {
            return true;
        }
    };
    const actions = struct {
        fn exit_a(c: Ctx) void {
            c.log.append('x') catch unreachable;
        }
        fn enter_b(c: Ctx) void {
            c.log.append('e') catch unreachable;
        }
    };

    const m = M{ .transitions = &.{
        .{
            .from = .a,
            .to = .b,
            .guard = guards.always,
            .on_exit = actions.exit_a,
            .on_enter = actions.enter_b,
        },
    } };

    var log = std.array_list.Managed(u8).init(testing.allocator);
    defer log.deinit();

    var s: S = .a;
    _ = m.advance(&s, .{ .log = &log });

    try testing.expectEqualStrings("xe", log.items);
}

test "dispatch: fires the matching event" {
    const S = enum { active, done, cancelled };
    const E = enum { finish, cancel };
    const Ctx = struct {};

    const M = StateMachine(S, E, Ctx);

    const m = M{ .transitions = &.{
        .{ .from = .active, .event = .finish, .to = .done },
        .{ .from = .active, .event = .cancel, .to = .cancelled },
    } };

    var s: S = .active;
    const r = m.dispatch(.cancel, &s, .{});
    try testing.expect(r == .fired);
    try testing.expectEqual(S.cancelled, s);
    try testing.expectEqual(E.cancel, r.fired.event);
}

test "dispatch: not_declared when no matching transition" {
    const S = enum { active, done };
    const E = enum { finish, cancel };
    const Ctx = struct {};

    const M = StateMachine(S, E, Ctx);

    // Only .finish is declared, not .cancel
    const m = M{ .transitions = &.{
        .{ .from = .active, .event = .finish, .to = .done },
    } };

    var s: S = .active;
    const r = m.dispatch(.cancel, &s, .{});
    try testing.expect(r == .not_declared);
    try testing.expectEqual(S.active, s); // state unchanged
}

test "dispatch: blocked_by_guard when guard rejects" {
    const S = enum { active, done };
    const E = enum { finish };
    const Ctx = struct { ready: bool };

    const M = StateMachine(S, E, Ctx);

    const guards = struct {
        fn ready(c: Ctx) bool {
            return c.ready;
        }
    };

    const m = M{ .transitions = &.{
        .{ .from = .active, .event = .finish, .to = .done, .guard = guards.ready },
    } };

    var s: S = .active;
    const r = m.dispatch(.finish, &s, .{ .ready = false });
    try testing.expect(r == .blocked_by_guard);
    try testing.expectEqual(S.active, s);
}

test "advance: polled and event-driven coexist without interfering" {
    const S = enum { closing, closed, opening };
    const E = enum { wake };
    const Ctx = struct { curtain_done: bool };

    const M = StateMachine(S, E, Ctx);

    const guards = struct {
        fn curtainDone(c: Ctx) bool {
            return c.curtain_done;
        }
    };

    const m = M{ .transitions = &.{
        // polled: curtain finished closing
        .{
            .from = .closing,
            .to = .closed,
            .guard = guards.curtainDone,
        },
        // event-driven: wake mid-close
        .{
            .from = .closing,
            .event = .wake,
            .to = .opening,
        },
        // event-driven: wake from asleep
        .{
            .from = .closed,
            .event = .wake,
            .to = .opening,
        },
    } };

    // Case 1: advance with curtain not done — idle
    var s1: S = .closing;
    const r1 = m.advance(&s1, .{ .curtain_done = false });
    try testing.expect(r1 == .idle);
    try testing.expectEqual(S.closing, s1);

    // Case 2: advance with curtain done — closes
    var s2: S = .closing;
    const r2 = m.advance(&s2, .{ .curtain_done = true });
    try testing.expect(r2 == .fired);
    try testing.expectEqual(S.closed, s2);

    // Case 3: dispatch wake mid-close — interrupts
    var s3: S = .closing;
    const r3 = m.dispatch(.wake, &s3, .{ .curtain_done = false });
    try testing.expect(r3 == .fired);
    try testing.expectEqual(S.opening, s3);

    // Case 4: dispatch wake from closed — opens
    var s4: S = .closed;
    const r4 = m.dispatch(.wake, &s4, .{ .curtain_done = false });
    try testing.expect(r4 == .fired);
    try testing.expectEqual(S.opening, s4);
}

test "advance: first-match-wins with overlap_allowed suppresses assert" {
    const S = enum { running, error_state, cancelled, finished };
    const E = enum {};
    const Ctx = struct {
        errored: bool,
        cancelled: bool,
        finished: bool,
    };

    const M = StateMachine(S, E, Ctx);

    const guards = struct {
        fn errored(c: Ctx) bool {
            return c.errored;
        }
        fn cancelled(c: Ctx) bool {
            return c.cancelled;
        }
        fn finished(c: Ctx) bool {
            return c.finished;
        }
    };

    // Priority order: error > cancel > finish, with intentional overlap.
    const m = M{ .transitions = &.{
        .{
            .from = .running,
            .to = .error_state,
            .guard = guards.errored,
            .overlap_allowed = true,
        },
        .{
            .from = .running,
            .to = .cancelled,
            .guard = guards.cancelled,
            .overlap_allowed = true,
        },
        .{
            .from = .running,
            .to = .finished,
            .guard = guards.finished,
        },
    } };

    // All three guards pass — error wins (declared first)
    var s: S = .running;
    const r = m.advance(&s, .{ .errored = true, .cancelled = true, .finished = true });
    try testing.expect(r == .fired);
    try testing.expectEqual(S.error_state, s);
}

test "enter: runs on_enter for the initial state" {
    const S = enum { a, b };
    const E = enum {};
    const Ctx = struct { entered: *bool };

    const M = StateMachine(S, E, Ctx);

    const actions = struct {
        fn mark(c: Ctx) void {
            c.entered.* = true;
        }
    };

    const m = M{ .transitions = &.{
        .{ .from = .b, .to = .a, .on_enter = actions.mark },
    } };

    var entered = false;
    m.enter(.a, .{ .entered = &entered });
    try testing.expect(entered);
}
