//! Sleeping component — pure data, plain enum state field.
//! This is the *only* place the sleep state lives at runtime. The
//! state_machines/sleep_machine.zig file reads/writes this enum via
//! advance() and dispatch().

/// Valid states for a worker who is sleeping / waking. Plain enum so
/// it serializes trivially (survives save/load roundtrip).
pub const SleepState = enum {
    /// Curtain animating closed over the worker. Polled: curtain done
    /// → .closed. Event: .wake → .opening (interrupted mid-close).
    closing,
    /// Curtain fully closed, worker asleep. Event: .wake → .opening.
    closed,
    /// Curtain animating open. Polled: curtain done → restore floor,
    /// remove component (terminal on_enter does both).
    opening,
};

pub const Sleeping = struct {
    bed_id: u64,
    floor_x: f32,
    floor_y: f32,
    timer: f32 = 0,
    state: SleepState = .closing,
};
