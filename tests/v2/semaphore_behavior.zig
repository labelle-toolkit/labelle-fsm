//! Semaphore guards & actions. Extracted from `semaphore_component.zig`
//! to demonstrate the external pattern: a comptime generator function
//! receives the component type as a parameter, so this file does not
//! @import semaphore_component.zig and there is no cycle.
//!
//! Pair file: `semaphore_component.zig` calls
//!     const behavior = @import("semaphore_behavior.zig").make(@This());

pub fn make(comptime Semaphore: type) type {
    return struct {
        pub const guards = struct {
            pub fn redElapsed(s: *Semaphore) bool {
                return s.timer_ms >= s.red_duration_ms;
            }
            pub fn greenElapsed(s: *Semaphore) bool {
                return s.timer_ms >= s.green_duration_ms;
            }
            pub fn yellowElapsed(s: *Semaphore) bool {
                return s.timer_ms >= s.yellow_duration_ms;
            }
        };

        pub const actions = struct {
            pub fn resetTimer(s: *Semaphore) void {
                s.timer_ms = 0;
            }
        };
    };
}
