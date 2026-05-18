//! Behavior tests for `Phone`. The component, machine, guards, and
//! actions all live in `tests/v2/phone_component.zig`; this file just
//! exercises `Phone.Machine.dispatch` / `Phone.Machine.advance` and
//! asserts the outcomes.

const std = @import("std");
const phone = @import("phone_component");
const core = @import("labelle-core");

const Phone = phone.Phone;
const PhoneState = Phone.State;
const Machine = Phone.Machine;

const testing = std.testing;

/// Wrapper matching `serde.writeComponent`'s expected
/// `fn(type, []const u8) bool` signature. `core.save_policy.shouldSkipField`
/// declares its parameters `comptime`, which makes its function type
/// strictly incompatible — so we inline the same logic here against the
/// component's `save.skip_fields` declaration.
fn skipFn(T: type, name: []const u8) bool {
    const skip = comptime core.save_policy.getSkipFields(T);
    inline for (skip) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

test "place_call moves idle -> dialing" {
    var p = Phone{};
    const r = Machine.dispatch(.place_call, &p.state, &p);
    try testing.expect(r == .fired);
    try testing.expectEqual(PhoneState.dialing, p.state);
}

test "polled dialing -> ringing_out when line opens" {
    var p = Phone{ .state = .dialing };
    try testing.expect(Machine.advance(&p.state, &p) == .idle);

    p.line_open = true;
    const r = Machine.advance(&p.state, &p);
    try testing.expect(r == .fired);
    try testing.expectEqual(PhoneState.ringing_out, p.state);
}

test "incoming_call -> answer -> hang_up flow" {
    var p = Phone{};
    _ = Machine.dispatch(.incoming_call, &p.state, &p);
    try testing.expectEqual(PhoneState.ringing_in, p.state);

    _ = Machine.dispatch(.answer, &p.state, &p);
    try testing.expectEqual(PhoneState.in_call, p.state);

    _ = Machine.dispatch(.hang_up, &p.state, &p);
    try testing.expectEqual(PhoneState.idle, p.state);
}

test "outbound: ringing_out -> in_call on remote_answered" {
    var p = Phone{ .state = .ringing_out };
    const r = Machine.dispatch(.remote_answered, &p.state, &p);
    try testing.expect(r == .fired);
    try testing.expectEqual(PhoneState.in_call, p.state);
}

test "hold / resume cycle" {
    var p = Phone{ .state = .in_call };
    _ = Machine.dispatch(.hold, &p.state, &p);
    try testing.expectEqual(PhoneState.on_hold, p.state);

    _ = Machine.dispatch(.resume_call, &p.state, &p);
    try testing.expectEqual(PhoneState.in_call, p.state);
}

test "dispatch not_declared for events the state does not accept" {
    var p = Phone{};
    const r = Machine.dispatch(.answer, &p.state, &p);
    try testing.expect(r == .not_declared);
    try testing.expectEqual(PhoneState.idle, p.state);
}

test "acceptedEvents matches the declared event-driven transitions" {
    const idle_evts = Machine.acceptedEvents(.idle);
    try testing.expect(idle_evts.contains(.place_call));
    try testing.expect(idle_evts.contains(.incoming_call));
    try testing.expect(!idle_evts.contains(.answer));
    try testing.expect(!idle_evts.contains(.hold));

    const in_call_evts = Machine.acceptedEvents(.in_call);
    try testing.expect(in_call_evts.contains(.hang_up));
    try testing.expect(in_call_evts.contains(.hold));
    try testing.expect(!in_call_evts.contains(.place_call));
}

test "clearFlags fires on every entry into idle (not per-transition)" {
    var p = Phone{
        .state = .in_call,
        .line_open = true,
        .dial_cancelled = true,
        .remote_hung_up = true,
    };
    _ = Machine.dispatch(.hang_up, &p.state, &p);
    try testing.expectEqual(PhoneState.idle, p.state);
    try testing.expect(!p.line_open);
    try testing.expect(!p.dial_cancelled);
    try testing.expect(!p.remote_hung_up);

    var p2 = Phone{ .state = .on_hold, .line_open = true };
    _ = Machine.dispatch(.hang_up, &p2.state, &p2);
    try testing.expectEqual(PhoneState.idle, p2.state);
    try testing.expect(!p2.line_open);
}

// ── Save / load ────────────────────────────────────────────────────────────

test "Saveable: Phone declares the .saveable policy" {
    try testing.expectEqual(core.SavePolicy.saveable, core.getSavePolicy(Phone).?);
    try testing.expectEqual(@as(usize, 0), core.getSkipFields(Phone).len);
    try testing.expectEqual(@as(usize, 0), core.getEntityRefFields(Phone).len);
}

test "Save / load: roundtrip mid-call Phone state" {
    const original = Phone{
        .state = .in_call,
        .line_open = true,
        .dial_cancelled = false,
        .remote_hung_up = true,
    };

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try core.serde.writeComponent(
        Phone,
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
        Phone,
        parsed.value,
        skipFn,
    );

    try testing.expectEqual(original.state, restored.state);
    try testing.expectEqual(original.line_open, restored.line_open);
    try testing.expectEqual(original.dial_cancelled, restored.dial_cancelled);
    try testing.expectEqual(original.remote_hung_up, restored.remote_hung_up);
}

test "Save: JSON output contains data fields, no FSM decls" {
    const p = Phone{
        .state = .in_call,
        .line_open = true,
        .dial_cancelled = false,
        .remote_hung_up = true,
    };
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try core.serde.writeComponent(Phone, &p, &aw.writer, skipFn);
    const json = aw.written();

    // State enum serializes as its tag string, not its integer value.
    try testing.expect(std.mem.indexOf(u8, json, "\"state\": \"in_call\"") != null);

    // Booleans serialize as the JSON literals.
    try testing.expect(std.mem.indexOf(u8, json, "\"line_open\": true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"dial_cancelled\": false") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"remote_hung_up\": true") != null);

    // FSM decls must NOT appear in the payload. They're decls, not
    // fields, so serde.writeComponent (which iterates @typeInfo fields)
    // shouldn't see them — this test makes that property explicit.
    try testing.expect(std.mem.indexOf(u8, json, "Machine") == null);
    try testing.expect(std.mem.indexOf(u8, json, "_fsm") == null);
    try testing.expect(std.mem.indexOf(u8, json, "guards") == null);
    try testing.expect(std.mem.indexOf(u8, json, "actions") == null);
    try testing.expect(std.mem.indexOf(u8, json, "Event") == null);
    // `save` is a decl too — but the substring would collide with
    // something else. Skip explicit check.
}

test "Save / load: restored Phone resumes the machine cleanly" {
    // Save mid-hold.
    const saved = Phone{ .state = .on_hold };

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try core.serde.writeComponent(Phone, &saved, &aw.writer, skipFn);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();

    var restored = try core.serde.readComponent(Phone, parsed.value, skipFn);

    // After load, the machine still drives the restored component:
    // resume_call should fire and move us back to in_call.
    const r = Machine.dispatch(.resume_call, &restored.state, &restored);
    try testing.expect(r == .fired);
    try testing.expectEqual(PhoneState.in_call, restored.state);
}
