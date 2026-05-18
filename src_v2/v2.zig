//! variant_d — Stateless-flavored declarative API. Per-state config
//! blocks bundle "what this state permits, what it ignores, what runs
//! on entry/exit" in one place. Comptime walks the spec, builds the
//! same O(1) dispatch table as variant_a, rejects malformed configs
//! with @compileError.
//!
//! Minimal first cut. Supported verbs:
//!   - permit:   .{ event, dest } or .{ event, dest, .{ .guard = ... } }
//!   - auto:     .{ guard, dest } or .{ guard, dest, .{ .on_exit = ..., .on_enter = ... } }
//!                (labelle's polled transitions — no Stateless analog;
//!                 fires from advance() when the guard passes)
//!   - on_entry: action fired on every entry into this state
//!   - on_exit:  action fired on every exit from this state
//!   - ignore:   .{ event, event, ... } — silently consume the event
//!                (different from not_declared: declared as a no-op)
//!
//! Deferred (Stateless verbs we don't ship in the minimal cut):
//!   - permitReentry, internalTransition, onEntryFrom, substateOf,
//!     permitDynamic, parameterized triggers.
//!
//! Comptime-enforced rules:
//!   - Every State variant must appear as a field of `.states`. Empty
//!     config `.idle = .{}` is the explicit "this state does nothing"
//!     marker — gaps fail compilation.
//!   - The same (state, event) pair cannot be both `permit`ted and
//!     `ignore`d.
//!   - Duplicate `permit` entries on the same (state, event) fail.
//!
//! Exit / entry ordering on a successful event transition:
//!     per-state on_exit  ->  per-transition on_exit  ->  state := dest
//!     ->  per-transition on_enter  ->  new per-state on_entry

const std = @import("std");

/// Bundle State, Event, and the resulting Machine type into a single
/// declarative comptime call, so a component can collapse its whole
/// FSM block into one `const _fsm = fsm.Define(...)` decl plus three
/// `pub const … = _fsm.…` alias lines.
///
/// Usage pattern (the closest a Zig component can get to "Phone is
/// the result of a comptime FSM function"):
///
///     pub const Phone = struct {
///         const _fsm = fsm.Define(*@This(), .{
///             .State = enum { idle, dialing, … },
///             .Event = enum { place_call, … },
///             .initial = .idle,
///             .states = .{ .idle = .{ … }, … },
///         });
///         pub const State = _fsm.State;
///         pub const Event = _fsm.Event;
///         pub const Machine = _fsm.Machine;
///
///         state: State = .idle,
///         line_open: bool = false,
///         …
///     };
///
/// Context is passed as a separate parameter (typically `*@This()`)
/// because `@This()` inside an anonymous struct literal does NOT
/// resolve to the enclosing component — only at the call site does
/// it pick up the component being defined.
pub fn Define(comptime Context: type, comptime spec: anytype) type {
    return struct {
        pub const State = spec.State;
        pub const Event = spec.Event;
        pub const Machine = Build(spec.State, spec.Event, Context, .{
            .initial = spec.initial,
            .states = spec.states,
        });
    };
}

/// Build a machine using a component type's `comptime State: type` and
/// `comptime Event: type` fields as the source of truth, instead of
/// repeating those types at the machine declaration site.
///
/// Pair this with the "C1" component shape — a component that declares
/// `comptime State: type = MyStateEnum` / `comptime Event: type = MyEventEnum`
/// as fields. Missing either field is a comptime error.
///
/// The in-tree phone / semaphore components use the more cohesive
/// `Define` form (state and event declared inside the spec), not this
/// helper — `BuildFor` is kept for the component-as-introspection-source
/// pattern where some external generic system wants to walk
/// `@typeInfo(Component).@"struct".fields` to discover the State enum
/// uniformly across many component types.
pub fn BuildFor(
    comptime ComponentT: type,
    comptime Context: type,
    comptime spec: anytype,
) type {
    return Build(
        readComptimeFieldDefault(ComponentT, "State"),
        readComptimeFieldDefault(ComponentT, "Event"),
        Context,
        spec,
    );
}

/// Comptime-assert that every tag value of `EnumT` equals its
/// declaration index. The dispatch tables use raw arrays of size
/// `enum.fields.len` indexed by `@intFromEnum(...)`, so a sparse or
/// custom-valued enum would index out of bounds.
fn assertDenseEnum(comptime EnumT: type, comptime role: []const u8) void {
    inline for (@typeInfo(EnumT).@"enum".fields, 0..) |f, i| {
        if (f.value != i) {
            @compileError(role ++ " (" ++ @typeName(EnumT) ++
                ") must be a dense zero-based enum; ." ++ f.name ++
                " has tag value " ++ std.fmt.comptimePrint("{d}", .{f.value}) ++
                " but declaration index is " ++ std.fmt.comptimePrint("{d}", .{i}) ++
                ". Declare states with plain `enum { … }` (no explicit values).");
        }
    }
}

/// Read the default value of a `comptime <name>: type = ...` field on
/// the component. Unlike `ComponentT{}.<name>`, this does not require
/// the component to be default-constructible (other runtime fields may
/// lack defaults). Errors with a clear message if the field is missing
/// or has no default.
fn readComptimeFieldDefault(comptime ComponentT: type, comptime name: []const u8) type {
    inline for (@typeInfo(ComponentT).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) {
            const dp = f.default_value_ptr orelse @compileError(@typeName(ComponentT) ++
                ".\"" ++ name ++ "\" must have a default value");
            const typed: *const f.type = @ptrCast(@alignCast(dp));
            return typed.*;
        }
    }
    @compileError(@typeName(ComponentT) ++
        " is missing a `comptime " ++ name ++ ": type` field required by BuildFor");
}

pub fn Build(
    comptime State: type,
    comptime Event: type,
    comptime Context: type,
    comptime spec: anytype,
) type {
    // Variant_d uses raw `[state_count][event_count]` arrays indexed by
    // `@intFromEnum(...)`. That's only safe when tag values are dense
    // and zero-based, which is the default for plain `enum { ... }`
    // declarations. Reject sparse / custom-valued enums at comptime
    // with a clear message rather than letting them silently index
    // past the array.
    assertDenseEnum(State, "State");
    assertDenseEnum(Event, "Event");

    const state_count = @typeInfo(State).@"enum".fields.len;
    const event_count = @typeInfo(Event).@"enum".fields.len;
    const EventSet = std.EnumSet(Event);

    const Guard = *const fn (ctx: Context) bool;
    const Action = *const fn (ctx: Context) void;

    const Permit = struct {
        dest: State,
        guard: ?Guard,
        on_exit: ?Action,
        on_enter: ?Action,
    };

    const Auto = struct {
        guard: Guard,
        dest: State,
        on_exit: ?Action,
        on_enter: ?Action,
    };

    const StateActions = struct {
        on_entry: ?Action,
        on_exit: ?Action,
    };

    const Tables = struct {
        permits: [state_count][event_count]?Permit,
        autos: [state_count][]const Auto,
        actions: [state_count]StateActions,
        ignored: [state_count]EventSet,
        accepted: [state_count]EventSet,
    };

    const tables: Tables = comptime build_tables: {
        @setEvalBranchQuota(1_000_000);

        // Exhaustiveness: every State variant must have a config.
        const states_type = @TypeOf(spec.states);
        for (@typeInfo(State).@"enum".fields) |sf| {
            if (!@hasField(states_type, sf.name)) {
                @compileError("missing state config for ." ++ sf.name ++
                    " in .states (use `.{}` for an empty config)");
            }
        }

        // Reverse check: every field in spec.states must correspond to
        // a real State variant. Catches typos like `.idel = .{}` or
        // stale state names left over from a refactor — without this
        // they'd silently compile (because all real variants are also
        // present) and the typo'd block would never fire.
        for (@typeInfo(states_type).@"struct".fields) |spec_field| {
            var found = false;
            for (@typeInfo(State).@"enum".fields) |sf| {
                if (std.mem.eql(u8, spec_field.name, sf.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                @compileError("unknown state ." ++ spec_field.name ++
                    " in `.states` — not a variant of " ++ @typeName(State));
            }
        }

        var permits: [state_count][event_count]?Permit =
            .{.{null} ** event_count} ** state_count;
        var autos: [state_count][]const Auto = .{&.{}} ** state_count;
        var actions: [state_count]StateActions =
            .{StateActions{ .on_entry = null, .on_exit = null }} ** state_count;
        var ignored: [state_count]EventSet = .{EventSet.initEmpty()} ** state_count;
        var accepted: [state_count]EventSet = .{EventSet.initEmpty()} ** state_count;

        for (@typeInfo(State).@"enum".fields) |sf| {
            const si = sf.value;
            const cfg = @field(spec.states, sf.name);
            const cfg_t = @TypeOf(cfg);

            // ── on_entry / on_exit (per-state) ──
            if (@hasField(cfg_t, "on_entry")) {
                actions[si].on_entry = cfg.on_entry;
            }
            if (@hasField(cfg_t, "on_exit")) {
                actions[si].on_exit = cfg.on_exit;
            }

            // ── permit ──
            if (@hasField(cfg_t, "permit")) {
                const permit_tup = cfg.permit;
                const permit_fields = @typeInfo(@TypeOf(permit_tup)).@"struct".fields;
                for (permit_fields, 0..) |_, i| {
                    const entry = permit_tup[i];
                    const entry_fields = @typeInfo(@TypeOf(entry)).@"struct".fields;
                    if (entry_fields.len < 2 or entry_fields.len > 3) {
                        @compileError("permit entry must be `.{ event, dest }` or " ++
                            "`.{ event, dest, opts }` (2 or 3 elements), got " ++
                            std.fmt.comptimePrint("{d}", .{entry_fields.len}));
                    }
                    const event: Event = entry[0];
                    const dest: State = entry[1];
                    const ei = @intFromEnum(event);

                    if (permits[si][ei] != null) {
                        @compileError("duplicate permit for ." ++ sf.name ++
                            " on ." ++ @tagName(event));
                    }

                    var guard: ?Guard = null;
                    var tr_on_exit: ?Action = null;
                    var tr_on_enter: ?Action = null;
                    if (entry_fields.len >= 3) {
                        const extra = entry[2];
                        const ExtraT = @TypeOf(extra);
                        if (@typeInfo(ExtraT) != .@"struct") {
                            @compileError("permit opts (3rd tuple element) must be a struct literal " ++
                                "like `.{ .guard = ... }`, got " ++ @typeName(ExtraT));
                        }
                        if (@hasField(ExtraT, "guard")) guard = extra.guard;
                        if (@hasField(ExtraT, "on_exit")) tr_on_exit = extra.on_exit;
                        if (@hasField(ExtraT, "on_enter")) tr_on_enter = extra.on_enter;
                    }

                    permits[si][ei] = .{
                        .dest = dest,
                        .guard = guard,
                        .on_exit = tr_on_exit,
                        .on_enter = tr_on_enter,
                    };
                    accepted[si].insert(event);
                }
            }

            // ── auto (polled / guard-only) ──
            if (@hasField(cfg_t, "auto")) {
                const auto_tup = cfg.auto;
                const auto_fields = @typeInfo(@TypeOf(auto_tup)).@"struct".fields;
                for (auto_fields, 0..) |_, i| {
                    const entry = auto_tup[i];
                    const entry_fields = @typeInfo(@TypeOf(entry)).@"struct".fields;
                    if (entry_fields.len < 2 or entry_fields.len > 3) {
                        @compileError("auto entry must be `.{ guard, dest }` or " ++
                            "`.{ guard, dest, opts }` (2 or 3 elements), got " ++
                            std.fmt.comptimePrint("{d}", .{entry_fields.len}));
                    }
                    const guard_fn: Guard = entry[0];
                    const dest: State = entry[1];

                    var tr_on_exit: ?Action = null;
                    var tr_on_enter: ?Action = null;
                    if (entry_fields.len >= 3) {
                        const extra = entry[2];
                        const ExtraT = @TypeOf(extra);
                        if (@typeInfo(ExtraT) != .@"struct") {
                            @compileError("auto opts (3rd tuple element) must be a struct literal " ++
                                "like `.{ .on_enter = ... }`, got " ++ @typeName(ExtraT));
                        }
                        if (@hasField(ExtraT, "on_exit")) tr_on_exit = extra.on_exit;
                        if (@hasField(ExtraT, "on_enter")) tr_on_enter = extra.on_enter;
                    }

                    autos[si] = autos[si] ++ &[_]Auto{.{
                        .guard = guard_fn,
                        .dest = dest,
                        .on_exit = tr_on_exit,
                        .on_enter = tr_on_enter,
                    }};
                }
            }

            // ── ignore ──
            if (@hasField(cfg_t, "ignore")) {
                const ignore_tup = cfg.ignore;
                const ignore_fields = @typeInfo(@TypeOf(ignore_tup)).@"struct".fields;
                for (ignore_fields, 0..) |_, i| {
                    const ev: Event = ignore_tup[i];
                    if (accepted[si].contains(ev)) {
                        @compileError("event ." ++ @tagName(ev) ++ " from ." ++ sf.name ++
                            " is both permitted and ignored");
                    }
                    ignored[si].insert(ev);
                }
            }
        }

        break :build_tables .{
            .permits = permits,
            .autos = autos,
            .actions = actions,
            .ignored = ignored,
            .accepted = accepted,
        };
    };

    return struct {
        pub const AdvanceResult = union(enum) {
            idle,
            fired: Fired,
            pub const Fired = struct { from: State, to: State };
        };

        pub const DispatchResult = union(enum) {
            /// No permit declared and event not in ignore list. Stateless
            /// throws here; we return an enum tag so the caller decides.
            not_declared,
            /// Event listed in `.ignore` — silently consumed.
            ignored,
            blocked_by_guard,
            fired: Fired,
            pub const Fired = struct {
                from: State,
                to: State,
                event: Event,
            };
        };

        pub const initial: State = spec.initial;

        pub fn advance(state: *State, ctx: Context) AdvanceResult {
            const current = state.*;
            const si = @intFromEnum(current);
            for (tables.autos[si]) |a| {
                if (!a.guard(ctx)) continue;
                fireTransition(current, a.dest, a.on_exit, a.on_enter, state, ctx);
                return .{ .fired = .{ .from = current, .to = a.dest } };
            }
            return .idle;
        }

        pub fn dispatch(event: Event, state: *State, ctx: Context) DispatchResult {
            const current = state.*;
            const si = @intFromEnum(current);
            const ei = @intFromEnum(event);

            const p = tables.permits[si][ei] orelse {
                if (tables.ignored[si].contains(event)) return .ignored;
                return .not_declared;
            };

            if (p.guard) |g| {
                if (!g(ctx)) return .blocked_by_guard;
            }

            fireTransition(current, p.dest, p.on_exit, p.on_enter, state, ctx);
            return .{ .fired = .{ .from = current, .to = p.dest, .event = event } };
        }

        /// Run on_entry for the initial state. Call once after attaching
        /// the component so initial entry effects fire.
        pub fn enter(s: State, ctx: Context) void {
            if (tables.actions[@intFromEnum(s)].on_entry) |a| a(ctx);
        }

        /// EnumSet of events permitted from `state` (does not include
        /// `ignore`d events). For UI: "which buttons should be enabled?".
        pub fn acceptedEvents(s: State) EventSet {
            return tables.accepted[@intFromEnum(s)];
        }

        /// EnumSet of events that are *declared* from `state` —
        /// permitted ∪ ignored. For UI: "which buttons should NOT show
        /// a `not_declared` error if pressed?".
        pub fn declaredEvents(s: State) EventSet {
            var u = tables.accepted[@intFromEnum(s)];
            u.setUnion(tables.ignored[@intFromEnum(s)]);
            return u;
        }

        fn fireTransition(
            from: State,
            to: State,
            transition_on_exit: ?Action,
            transition_on_enter: ?Action,
            state: *State,
            ctx: Context,
        ) void {
            // Stateless order: per-state on_exit -> per-transition on_exit
            // -> state mutation -> per-transition on_enter -> new
            // per-state on_entry.
            if (tables.actions[@intFromEnum(from)].on_exit) |a| a(ctx);
            if (transition_on_exit) |a| a(ctx);
            state.* = to;
            if (transition_on_enter) |a| a(ctx);
            if (tables.actions[@intFromEnum(to)].on_entry) |a| a(ctx);
        }
    };
}

// ============================================================================
// Example: sleep_machine (same shape as variants a/b/c) + tests
// ============================================================================

const testing = std.testing;

const SleepState = enum { closing, closed, opening, awake };
const SleepEvent = enum { wake, force_sleep };

const SleepCtx = struct {
    log: ?*std.array_list.Managed(u8) = null,
    curtain_done: bool = false,
    opening_done: bool = false,
};

const sleep_guards = struct {
    fn curtainDone(c: SleepCtx) bool {
        return c.curtain_done;
    }
    fn openingDone(c: SleepCtx) bool {
        return c.opening_done;
    }
};

const sleep_actions = struct {
    fn enterClosing(c: SleepCtx) void {
        if (c.log) |l| l.append('C') catch unreachable;
    }
    fn exitClosing(c: SleepCtx) void {
        if (c.log) |l| l.append('c') catch unreachable;
    }
    fn enterAwake(c: SleepCtx) void {
        if (c.log) |l| l.append('A') catch unreachable;
    }
};

const SleepMachine = Build(SleepState, SleepEvent, SleepCtx, .{
    .initial = .closing,
    .states = .{
        .closing = .{
            .on_entry = sleep_actions.enterClosing,
            .on_exit = sleep_actions.exitClosing,
            .permit = .{
                .{ SleepEvent.wake, SleepState.opening },
            },
            .auto = .{
                .{ sleep_guards.curtainDone, SleepState.closed },
            },
        },
        .closed = .{
            .permit = .{
                .{ SleepEvent.wake, SleepState.opening },
            },
        },
        .opening = .{
            .auto = .{
                .{ sleep_guards.openingDone, SleepState.awake },
            },
            // Stateless's .Ignore: a wake event while opening is a no-op,
            // not a not_declared error.
            .ignore = .{SleepEvent.wake},
        },
        .awake = .{
            .on_entry = sleep_actions.enterAwake,
            .permit = .{
                .{ SleepEvent.force_sleep, SleepState.closing },
            },
        },
    },
});

test "variant_d: polled transition fires when guard passes" {
    var s: SleepState = .closing;
    const r1 = SleepMachine.advance(&s, .{});
    try testing.expect(r1 == .idle);

    const r2 = SleepMachine.advance(&s, .{ .curtain_done = true });
    try testing.expect(r2 == .fired);
    try testing.expectEqual(SleepState.closed, s);
}

test "variant_d: dispatch fires event-driven transition" {
    var s: SleepState = .closed;
    const r = SleepMachine.dispatch(.wake, &s, .{});
    try testing.expect(r == .fired);
    try testing.expectEqual(SleepState.opening, s);
}

test "variant_d: ignored events return .ignored, not .not_declared" {
    var s: SleepState = .opening;
    const r = SleepMachine.dispatch(.wake, &s, .{});
    try testing.expect(r == .ignored);
    try testing.expectEqual(SleepState.opening, s);
}

test "variant_d: not_declared when event has no permit and no ignore" {
    var s: SleepState = .closed;
    const r = SleepMachine.dispatch(.force_sleep, &s, .{});
    try testing.expect(r == .not_declared);
}

test "variant_d: per-state on_entry / on_exit fire in order on event" {
    var log = std.array_list.Managed(u8).init(testing.allocator);
    defer log.deinit();

    var s: SleepState = .closing;
    // wake fires: exitClosing (per-state on_exit) -> state := opening.
    // (opening has no on_entry.)
    _ = SleepMachine.dispatch(.wake, &s, .{ .log = &log });
    try testing.expectEqualStrings("c", log.items);
}

test "variant_d: per-state on_entry fires on auto transition target" {
    var log = std.array_list.Managed(u8).init(testing.allocator);
    defer log.deinit();

    var s: SleepState = .opening;
    // opening -> awake via auto (opening_done). awake has enterAwake.
    _ = SleepMachine.advance(&s, .{ .opening_done = true, .log = &log });
    try testing.expectEqual(SleepState.awake, s);
    try testing.expectEqualStrings("A", log.items);
}

test "variant_d: declaredEvents merges permitted and ignored" {
    const opening_declared = SleepMachine.declaredEvents(.opening);
    try testing.expect(opening_declared.contains(.wake)); // ignored, but declared
    try testing.expect(!opening_declared.contains(.force_sleep));

    const opening_accepted = SleepMachine.acceptedEvents(.opening);
    try testing.expect(!opening_accepted.contains(.wake)); // ignored ≠ permitted

    const awake_declared = SleepMachine.declaredEvents(.awake);
    try testing.expect(awake_declared.contains(.force_sleep));
}

test "variant_d: enter() runs on_entry for initial state" {
    var log = std.array_list.Managed(u8).init(testing.allocator);
    defer log.deinit();

    SleepMachine.enter(SleepMachine.initial, .{ .log = &log });
    try testing.expectEqualStrings("C", log.items);
}
