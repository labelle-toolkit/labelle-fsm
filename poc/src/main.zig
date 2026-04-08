//! POC entry point — runs a fake game loop that exercises the sleep
//! state machine. Mirrors the split a real labelle game would have:
//!
//!   components/         — Sleeping, Worker (pure data)
//!   state_machines/     — sleep_machine.zig (Context, Event, guards, actions, transitions)
//!   systems/            — sleep_tick.zig (the per-frame advance driver)
//!   hooks/              — sleep_hooks.zig (the dispatch driver)
//!   lib/                — fsm.zig (the state-machine library itself)
//!   main.zig            — just the main() entry, wires the pieces together
//!
//! This file holds zero FSM logic. If you want to understand what the
//! sleep behavior does, read state_machines/sleep_machine.zig.

const std = @import("std");
const ecs = @import("ecs");

const Worker = @import("components/worker.zig").Worker;
const Sleeping = @import("components/sleeping.zig").Sleeping;
const sleep_tick = @import("systems/sleep_tick.zig");
const sleep_hooks = @import("hooks/sleep_hooks.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ecs.Registry.init(allocator);
    defer reg.deinit();

    // Create two workers, both going to sleep.
    const worker_a = reg.create();
    reg.add(worker_a, Worker{ .id = 1 });
    reg.add(worker_a, Sleeping{
        .bed_id = 100,
        .floor_x = 50,
        .floor_y = 0,
        .state = .closing,
    });

    const worker_b = reg.create();
    reg.add(worker_b, Worker{ .id = 2 });
    reg.add(worker_b, Sleeping{
        .bed_id = 101,
        .floor_x = 200,
        .floor_y = 0,
        .state = .closing,
    });

    std.debug.print("=== frame 1 (dt=0.2) — curtain still closing ===\n", .{});
    sleep_tick.tick(&reg, 0.2);

    std.debug.print("=== frame 2 (dt=0.2) — still closing ===\n", .{});
    sleep_tick.tick(&reg, 0.2);

    std.debug.print("=== frame 3 (dt=0.2) — worker_a curtain finishes, goes to .closed ===\n", .{});
    sleep_tick.tick(&reg, 0.2);

    std.debug.print("=== external hook: worker_b gets a wake mid-close ===\n", .{});
    sleep_hooks.workerSleepEnd(&reg, worker_b);

    std.debug.print("=== frame 4 (dt=0.2) — worker_a still sleeping, worker_b opening ===\n", .{});
    sleep_tick.tick(&reg, 0.2);

    std.debug.print("=== external hook: worker_a gets a wake while asleep ===\n", .{});
    sleep_hooks.workerSleepEnd(&reg, worker_a);

    std.debug.print("=== frame 5 (dt=0.5) — both curtains finish opening ===\n", .{});
    sleep_tick.tick(&reg, 0.5);

    std.debug.print("=== final state ===\n", .{});
    std.debug.print("  worker_a has Sleeping: {}\n", .{reg.has(Sleeping, worker_a)});
    std.debug.print("  worker_b has Sleeping: {}\n", .{reg.has(Sleeping, worker_b)});

    std.debug.print("=== trying to dispatch .wake to already-awake worker_a ===\n", .{});
    sleep_hooks.workerSleepEnd(&reg, worker_a);
}
