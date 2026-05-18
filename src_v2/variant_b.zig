//! variant_b — comptime dispatch table, schema auto-derived from
//! transitions.
//!
//! Same comptime O(1) dispatch as variant_a, but without the hand-written
//! `reachable_from` schema. The library walks the transitions slice and
//! builds the EnumSets itself.
//!
//! Tradeoff vs. variant_a:
//!   + Less boilerplate at machine declaration site.
//!   + No risk of schema-vs-transitions drift (there's only one source
//!     of truth).
//!   - Loses the second source of truth — typos in `to` are still
//!     accepted ("oops, I wrote .opening but meant .opened" goes through).
//!   - `reachableFrom(state)` is now pure introspection, not a contract.
//!
//! This is the "what if we just want fast dispatch + nice introspection,
//! and not the static legality check?" variant.

const std = @import("std");

pub fn Transition(comptime State: type, comptime Event: type, comptime Context: type) type {
    return struct {
        from: State,
        to: State,
        event: ?Event = null,
        guard: ?*const fn (ctx: Context) bool = null,
        on_exit: ?*const fn (ctx: Context) void = null,
        on_enter: ?*const fn (ctx: Context) void = null,
        overlap_allowed: bool = false,
    };
}

pub fn Machine(
    comptime State: type,
    comptime Event: type,
    comptime Context: type,
    comptime transitions: []const Transition(State, Event, Context),
) type {
    const state_count = @typeInfo(State).@"enum".fields.len;
    const event_count = @typeInfo(Event).@"enum".fields.len;
    const EventSet = std.EnumSet(Event);
    const StateSet = std.EnumSet(State);
    const T = Transition(State, Event, Context);

    return struct {
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

        const Tables = struct {
            polled: [state_count][]const usize,
            event_table: [state_count][event_count]?usize,
            accepted_events: [state_count]EventSet,
            /// Derived reachability: union of `to` states for all transitions
            /// from each source. Pure introspection — no legality contract.
            reachable: [state_count]StateSet,
        };

        const tables: Tables = buildTables();

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
            var reachable: [state_count]StateSet = .{StateSet.initEmpty()} ** state_count;

            for (transitions, 0..) |tr, i| {
                const si = @intFromEnum(tr.from);
                reachable[si].insert(tr.to);

                if (tr.event) |e| {
                    const ei = @intFromEnum(e);
                    if (event_table[si][ei]) |existing| {
                        const prior = transitions[existing];
                        if (!(prior.overlap_allowed and tr.overlap_allowed)) {
                            @compileError("duplicate event-driven transition: from ." ++
                                @tagName(tr.from) ++ " on event ." ++ @tagName(e));
                        }
                    } else {
                        event_table[si][ei] = i;
                    }
                    accepted[si].insert(e);
                } else {
                    polled_lists[si] = polled_lists[si] ++ &[_]usize{i};
                }
            }

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
                .accepted_events = accepted,
                .reachable = reachable,
            };
        }

        pub fn advance(state: *State, ctx: Context) AdvanceResult {
            const current = state.*;
            const si = @intFromEnum(current);
            for (tables.polled[si]) |idx| {
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
            const idx = tables.event_table[@intFromEnum(current)][@intFromEnum(event)] orelse
                return .not_declared;
            const tr: T = transitions[idx];
            if (tr.guard) |g| if (!g(ctx)) return .blocked_by_guard;
            if (tr.on_exit) |a| a(ctx);
            state.* = tr.to;
            if (tr.on_enter) |a| a(ctx);
            return .{ .fired = .{ .from = current, .to = tr.to, .event = event, .index = idx } };
        }

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

        pub fn acceptedEvents(state: State) EventSet {
            return tables.accepted_events[@intFromEnum(state)];
        }

        /// Derived set of target states reachable from `state` (union of
        /// `to` over all transitions with that `from`). Pure introspection.
        pub fn reachableFrom(state: State) StateSet {
            return tables.reachable[@intFromEnum(state)];
        }
    };
}

// ============================================================================
// Example: identical sleep_machine, no hand-written schema
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

const SleepMachine = Machine(SleepState, SleepEvent, SleepCtx, &.{
    .{ .from = .closing, .to = .closed, .guard = SleepGuards.curtainDone },
    .{ .from = .opening, .to = .awake, .guard = SleepGuards.openingDone },
    .{ .from = .closed, .event = .wake, .to = .opening },
    .{ .from = .closing, .event = .wake, .to = .opening },
    .{ .from = .awake, .event = .force_sleep, .to = .closing },
});

test "variant_b: polled fires on guard pass" {
    var s: SleepState = .closing;
    const r = SleepMachine.advance(&s, .{ .curtain_done = true, .opening_done = false });
    try testing.expect(r == .fired);
    try testing.expectEqual(SleepState.closed, s);
}

test "variant_b: dispatch fires event-driven transition" {
    var s: SleepState = .closed;
    const r = SleepMachine.dispatch(.wake, &s, .{ .curtain_done = false, .opening_done = false });
    try testing.expect(r == .fired);
    try testing.expectEqual(SleepState.opening, s);
}

test "variant_b: reachableFrom is derived" {
    const r = SleepMachine.reachableFrom(.closing);
    try testing.expect(r.contains(.closed));
    try testing.expect(r.contains(.opening));
    try testing.expect(!r.contains(.awake));
}

test "variant_b: acceptedEvents is derived" {
    try testing.expect(SleepMachine.acceptedEvents(.closed).contains(.wake));
    try testing.expect(SleepMachine.acceptedEvents(.awake).contains(.force_sleep));
    try testing.expect(SleepMachine.acceptedEvents(.opening).count() == 0);
}
