//! Behavior tests for `Semaphore`. The component + machine live in
//! `tests/v2/semaphore_component.zig`; guards and actions live in
//! `tests/v2/semaphore_behavior.zig`. This file just exercises the
//! resulting `Semaphore.Machine` and checks the observable outcomes.

const std = @import("std");
const semaphore = @import("semaphore_component");
const core = @import("labelle-core");

const Semaphore = semaphore.Semaphore;
const State = Semaphore.State;
const Machine = Semaphore.Machine;

const testing = std.testing;

/// Wrapper matching `serde.writeComponent`'s expected
/// `fn(type, []const u8) bool` signature. `skipFn`
/// declares its parameters `comptime`, which makes its function type
/// strictly incompatible.
fn skipFn(T: type, name: []const u8) bool {
    const skip = comptime core.save_policy.getSkipFields(T);
    inline for (skip) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

test "initial state is red" {
    const s = Semaphore{};
    try testing.expectEqual(State.red, s.state);
}

test "auto: red -> green when red timer elapsed" {
    var s = Semaphore{};

    // Below threshold: no transition.
    s.timer_ms = s.red_duration_ms - 1;
    try testing.expect(Machine.advance(&s.state, &s) == .idle);
    try testing.expectEqual(State.red, s.state);

    // At threshold: fires, timer reset by on_entry on .green.
    s.timer_ms = s.red_duration_ms;
    const r = Machine.advance(&s.state, &s);
    try testing.expect(r == .fired);
    try testing.expectEqual(State.green, s.state);
    try testing.expectEqual(@as(u32, 0), s.timer_ms);
}

test "auto: full cycle red -> green -> yellow -> red" {
    var s = Semaphore{};

    s.timer_ms = s.red_duration_ms;
    _ = Machine.advance(&s.state, &s);
    try testing.expectEqual(State.green, s.state);

    s.timer_ms = s.green_duration_ms;
    _ = Machine.advance(&s.state, &s);
    try testing.expectEqual(State.yellow, s.state);

    s.timer_ms = s.yellow_duration_ms;
    _ = Machine.advance(&s.state, &s);
    try testing.expectEqual(State.red, s.state);
}

test "emergency_on jumps to flashing_red from any color" {
    inline for ([_]State{ .red, .green, .yellow }) |initial| {
        var s = Semaphore{ .state = initial };
        _ = Machine.dispatch(.emergency_on, &s.state, &s);
        try testing.expectEqual(State.flashing_red, s.state);
    }
}

test "emergency_off returns flashing_red -> red" {
    var s = Semaphore{ .state = .flashing_red };
    _ = Machine.dispatch(.emergency_off, &s.state, &s);
    try testing.expectEqual(State.red, s.state);
}

test "manual_advance skips through colors one at a time" {
    var s = Semaphore{};
    _ = Machine.dispatch(.manual_advance, &s.state, &s);
    try testing.expectEqual(State.green, s.state);

    _ = Machine.dispatch(.manual_advance, &s.state, &s);
    try testing.expectEqual(State.yellow, s.state);

    _ = Machine.dispatch(.manual_advance, &s.state, &s);
    try testing.expectEqual(State.red, s.state);
}

test "manual_advance is not declared from flashing_red" {
    var s = Semaphore{ .state = .flashing_red };
    const r = Machine.dispatch(.manual_advance, &s.state, &s);
    try testing.expect(r == .not_declared);
    try testing.expectEqual(State.flashing_red, s.state);
}

test "on_entry resetTimer fires on every color transition" {
    var s = Semaphore{ .timer_ms = 9999 };
    // resetTimer hasn't run yet — the initial state was constructed,
    // not entered through advance/dispatch.
    try testing.expectEqual(@as(u32, 9999), s.timer_ms);

    // Manual advance into green should fire green's on_entry.
    _ = Machine.dispatch(.manual_advance, &s.state, &s);
    try testing.expectEqual(State.green, s.state);
    try testing.expectEqual(@as(u32, 0), s.timer_ms);
}

// ── Save / load ────────────────────────────────────────────────────────────

test "Saveable: Semaphore declares the .saveable policy" {
    try testing.expectEqual(core.SavePolicy.saveable, core.getSavePolicy(Semaphore).?);
}

test "Save / load: roundtrip a yellow Semaphore with custom durations" {
    const original = Semaphore{
        .state = .yellow,
        .timer_ms = 1234,
        .red_duration_ms = 8000,
        .yellow_duration_ms = 2000,
        .green_duration_ms = 6000,
    };

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try core.serde.writeComponent(
        Semaphore,
        &original,
        &aw.writer,
        skipFn,
    );

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        aw.written(),
        .{},
    );
    defer parsed.deinit();

    const restored = try core.serde.readComponent(
        Semaphore,
        parsed.value,
        skipFn,
    );

    try testing.expectEqual(original.state, restored.state);
    try testing.expectEqual(original.timer_ms, restored.timer_ms);
    try testing.expectEqual(original.red_duration_ms, restored.red_duration_ms);
    try testing.expectEqual(original.yellow_duration_ms, restored.yellow_duration_ms);
    try testing.expectEqual(original.green_duration_ms, restored.green_duration_ms);
}

test "Save: JSON output contains data fields, no FSM decls" {
    const s = Semaphore{
        .state = .yellow,
        .timer_ms = 1234,
        .red_duration_ms = 8000,
    };
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try core.serde.writeComponent(Semaphore, &s, &aw.writer, skipFn);
    const json = aw.written();

    // State enum serializes as its tag string.
    try testing.expect(std.mem.indexOf(u8, json, "\"state\": \"yellow\"") != null);

    // Integer fields appear as numbers, not quoted.
    try testing.expect(std.mem.indexOf(u8, json, "\"timer_ms\": 1234") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"red_duration_ms\": 8000") != null);

    // FSM decls and the behavior namespace must NOT appear.
    try testing.expect(std.mem.indexOf(u8, json, "Machine") == null);
    try testing.expect(std.mem.indexOf(u8, json, "_fsm") == null);
    try testing.expect(std.mem.indexOf(u8, json, "behavior") == null);
    try testing.expect(std.mem.indexOf(u8, json, "Event") == null);
}

test "Save / load: restored Semaphore continues its cycle" {
    // Save with yellow's timer just below threshold.
    const saved = Semaphore{
        .state = .yellow,
        .timer_ms = 1499,
    };

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try core.serde.writeComponent(Semaphore, &saved, &aw.writer, skipFn);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();

    var restored = try core.serde.readComponent(Semaphore, parsed.value, skipFn);

    // Tick past the yellow threshold (default 1500ms) → auto fires → red.
    restored.timer_ms = restored.yellow_duration_ms;
    const r = Machine.advance(&restored.state, &restored);
    try testing.expect(r == .fired);
    try testing.expectEqual(State.red, restored.state);
    try testing.expectEqual(@as(u32, 0), restored.timer_ms); // resetTimer on entry to red
}
