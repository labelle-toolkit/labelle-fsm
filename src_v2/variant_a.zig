//! variant_a — comptime dispatch table + hand-written EnumSet legality
//! schema + accepted-event introspection.
//!
//! Compared to v1:
//!   - No `transitions` field on a value. The whole machine is a *type*
//!     generated from comptime parameters. `advance` / `dispatch` are
//!     namespaced functions on that type.
//!   - Dispatch is O(1) via a comptime `[state_count][event_count]?usize`
//!     table. The runtime loop is gone.
//!   - Polled transitions still need a guarded scan (guards are runtime),
//!     but the candidate list per state is precomputed at comptime.
//!   - `reachable_from` is a hand-written `EnumArray(State, EnumSet(State))`
//!     declaring which target states each source state is *allowed* to
//!     reach. A `@compileError` fires for any transition that escapes
//!     the schema. This is the "guard clauses to block impossible
//!     transitions" idea — a second source of truth enforced statically.
//!   - `acceptedEvents(state)` exposes the per-state `EnumSet(Event)`
//!     for UI / debug ("which signals does this state respond to?").
//!   - Duplicate (state, event) pairs and unguarded polled overlaps are
//!     detected at *comptime* instead of runtime debug panic.
//!     `overlap_allowed` still exists for intentional overlap.

const std = @import("std");

pub fn Transition(comptime State: type, comptime Event: type, comptime Context: type) type {
    return struct {
        from: State,
        to: State,
        event: ?Event = null,
        guard: ?*const fn (ctx: Context) bool = null,
        on_exit: ?*const fn (ctx: Context) void = null,
        on_enter: ?*const fn (ctx: Context) void = null,
        /// Suppress the comptime multi-match assertion when this
        /// transition intentionally overlaps with a lower-priority
        /// sibling. Declaration order still decides the winner.
        overlap_allowed: bool = false,
    };
}

pub fn Options(comptime State: type) type {
    return struct {
        /// Hand-written legality schema. For each state, the set of
        /// target states that transitions are *allowed* to reach. Any
        /// transition violating this triggers @compileError.
        reachable_from: std.EnumArray(State, std.EnumSet(State)),
    };
}

pub fn Machine(
    comptime State: type,
    comptime Event: type,
    comptime Context: type,
    comptime opts: Options(State),
    comptime transitions: []const Transition(State, Event, Context),
) type {
    const state_count = @typeInfo(State).@"enum".fields.len;
    const event_count = @typeInfo(Event).@"enum".fields.len;
    const EventSet = std.EnumSet(Event);
    const T = Transition(State, Event, Context);

    return struct {
        const Self = @This();

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

        // ---- Comptime tables -------------------------------------------------

        const Tables = struct {
            /// Per-state list of indices into `transitions` for polled
            /// transitions, in declaration order (priority preserved).
            polled: [state_count][]const usize,
            /// Dense (state × event) → transition index. `null` means
            /// no event-driven transition declared for this pair.
            event_table: [state_count][event_count]?usize,
            /// Per-state EnumSet of accepted events.
            accepted: [state_count]EventSet,
        };

        const tables: Tables = buildTables();

        // Force comptime evaluation of `tables` whenever this type is
        // realized, so schema/duplicate checks fire even if no runtime
        // function is called.
        comptime {
            _ = tables;
        }

        fn buildTables() Tables {
            @setEvalBranchQuota(1_000_000);

            var polled_lists: [state_count][]const usize = .{&.{}} ** state_count;
            var event_table: [state_count][event_count]?usize = blk: {
                var t: [state_count][event_count]?usize = undefined;
                for (&t) |*row| row.* = .{null} ** event_count;
                break :blk t;
            };
            var accepted: [state_count]EventSet = .{EventSet.initEmpty()} ** state_count;

            for (transitions, 0..) |tr, i| {
                // ---- legality schema check ----
                if (!opts.reachable_from.get(tr.from).contains(tr.to)) {
                    @compileError("illegal transition: ." ++ @tagName(tr.from) ++
                        " -> ." ++ @tagName(tr.to) ++
                        " is not in reachable_from[." ++ @tagName(tr.from) ++ "]");
                }

                const si = @intFromEnum(tr.from);

                if (tr.event) |e| {
                    const ei = @intFromEnum(e);
                    if (event_table[si][ei]) |existing| {
                        // Duplicate on (state, event): only legal if BOTH
                        // sides opt in to overlap. Otherwise it's a silent
                        // shadow.
                        const prior = transitions[existing];
                        if (!(prior.overlap_allowed and tr.overlap_allowed)) {
                            @compileError("duplicate event-driven transition: from ." ++
                                @tagName(tr.from) ++ " on event ." ++ @tagName(e));
                        }
                        // First-match wins — keep `existing`.
                    } else {
                        event_table[si][ei] = i;
                    }
                    accepted[si].insert(e);
                } else {
                    polled_lists[si] = polled_lists[si] ++ &[_]usize{i};
                }
            }

            // Comptime check: two unguarded polled transitions from the
            // same state are always ambiguous (one always shadows the
            // other). Guarded overlaps still rely on declaration order
            // + the runtime fall-through (guards aren't decidable at
            // comptime).
            for (polled_lists, 0..) |list, si| {
                var seen_unguarded: ?usize = null;
                for (list) |idx| {
                    const tr = transitions[idx];
                    if (tr.guard == null) {
                        if (seen_unguarded) |prior| {
                            if (!(transitions[prior].overlap_allowed and tr.overlap_allowed)) {
                                @compileError("two polled transitions without guards from ." ++
                                    @tagName(@as(State, @enumFromInt(si))));
                            }
                        } else {
                            seen_unguarded = idx;
                        }
                    }
                }
            }

            return .{
                .polled = polled_lists,
                .event_table = event_table,
                .accepted = accepted,
            };
        }

        // ---- Runtime API ----------------------------------------------------

        pub fn advance(state: *State, ctx: Context) AdvanceResult {
            const current = state.*;
            const si = @intFromEnum(current);
            const list = tables.polled[si];

            for (list) |idx| {
                const tr: T = transitions[idx];
                const passes = if (tr.guard) |g| g(ctx) else true;
                if (!passes) continue;

                if (tr.on_exit) |a| a(ctx);
                state.* = tr.to;
                if (tr.on_enter) |a| a(ctx);
                return .{ .fired = .{ .from = current, .to = tr.to, .index = idx } };
            }
            return .idle;
        }

        pub fn dispatch(event: Event, state: *State, ctx: Context) DispatchResult {
            const current = state.*;
            const si = @intFromEnum(current);
            const ei = @intFromEnum(event);

            const idx = tables.event_table[si][ei] orelse return .not_declared;
            const tr: T = transitions[idx];

            if (tr.guard) |g| {
                if (!g(ctx)) return .blocked_by_guard;
            }

            if (tr.on_exit) |a| a(ctx);
            state.* = tr.to;
            if (tr.on_enter) |a| a(ctx);
            return .{ .fired = .{ .from = current, .to = tr.to, .event = event, .index = idx } };
        }

        /// Run on_enter for the initial state. Call once after attaching
        /// the component.
        pub fn enter(initial: State, ctx: Context) void {
            for (transitions) |tr| {
                if (tr.to == initial) {
                    if (tr.on_enter) |a| {
                        a(ctx);
                        return;
                    }
                }
            }
        }

        // ---- Introspection --------------------------------------------------

        /// EnumSet of events that have an event-driven transition declared
        /// from `state`. Useful for "which buttons should be enabled?"
        pub fn acceptedEvents(state: State) EventSet {
            return tables.accepted[@intFromEnum(state)];
        }

        /// Slice of polled-transition indices from `state`, in declaration
        /// order. Exposed for gizmos/tests.
        pub fn polledFrom(state: State) []const usize {
            return tables.polled[@intFromEnum(state)];
        }
    };
}

// ============================================================================
// Example: sleep_machine (same shape as README) + tests
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

const SleepMachine = Machine(
    SleepState,
    SleepEvent,
    SleepCtx,
    .{
        .reachable_from = std.EnumArray(SleepState, std.EnumSet(SleepState)).init(.{
            .closing = std.EnumSet(SleepState).initMany(&.{ .closed, .opening }),
            .closed = std.EnumSet(SleepState).initMany(&.{.opening}),
            .opening = std.EnumSet(SleepState).initMany(&.{.awake}),
            .awake = std.EnumSet(SleepState).initMany(&.{.closing}),
        }),
    },
    &.{
        // polled
        .{ .from = .closing, .to = .closed, .guard = SleepGuards.curtainDone },
        .{ .from = .opening, .to = .awake, .guard = SleepGuards.openingDone },
        // event-driven
        .{ .from = .closed, .event = .wake, .to = .opening },
        .{ .from = .closing, .event = .wake, .to = .opening },
        .{ .from = .awake, .event = .force_sleep, .to = .closing },
    },
);

test "variant_a: polled transition fires when guard passes" {
    var s: SleepState = .closing;
    const r1 = SleepMachine.advance(&s, .{ .curtain_done = false, .opening_done = false });
    try testing.expect(r1 == .idle);
    try testing.expectEqual(SleepState.closing, s);

    const r2 = SleepMachine.advance(&s, .{ .curtain_done = true, .opening_done = false });
    try testing.expect(r2 == .fired);
    try testing.expectEqual(SleepState.closed, s);
}

test "variant_a: dispatch fires event-driven transition" {
    var s: SleepState = .closed;
    const r = SleepMachine.dispatch(.wake, &s, .{ .curtain_done = false, .opening_done = false });
    try testing.expect(r == .fired);
    try testing.expectEqual(SleepState.opening, s);
}

test "variant_a: dispatch returns not_declared for absent event" {
    var s: SleepState = .opening;
    // No transition declared for (opening, wake).
    const r = SleepMachine.dispatch(.wake, &s, .{ .curtain_done = false, .opening_done = false });
    try testing.expect(r == .not_declared);
    try testing.expectEqual(SleepState.opening, s);
}

test "variant_a: acceptedEvents reflects per-state event set" {
    const closed_events = SleepMachine.acceptedEvents(.closed);
    try testing.expect(closed_events.contains(.wake));
    try testing.expect(!closed_events.contains(.force_sleep));

    const awake_events = SleepMachine.acceptedEvents(.awake);
    try testing.expect(awake_events.contains(.force_sleep));
    try testing.expect(!awake_events.contains(.wake));

    const opening_events = SleepMachine.acceptedEvents(.opening);
    try testing.expect(opening_events.count() == 0);
}
