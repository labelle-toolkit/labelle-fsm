//! Phone component — the entire FSM (states, events, transitions,
//! guards, actions, machine) bundled inside the `Phone` struct. The
//! file has zero non-import decls at file scope; every detail lives
//! on `Phone`.

const std = @import("std");
const fsm = @import("v2");
const core = @import("labelle-core");

pub const Phone = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});

    const _fsm = fsm.Define(*@This(), .{
        .State = enum {
            idle,
            dialing,
            ringing_out, // outbound: remote phone ringing
            ringing_in, // inbound: this phone ringing
            in_call,
            on_hold,
        },
        .Event = enum {
            place_call,
            incoming_call,
            answer,
            remote_answered,
            hang_up,
            hold,
            resume_call,
        },
        .initial = .idle,
        .states = .{
            .idle = .{
                .on_entry = actions.clearFlags,
                .permit = .{
                    .{ .place_call, .dialing },
                    .{ .incoming_call, .ringing_in },
                },
            },
            .dialing = .{
                .permit = .{
                    .{ .hang_up, .idle },
                },
                .auto = .{
                    .{ guards.lineOpen, .ringing_out },
                    .{ guards.dialCancelled, .idle },
                },
            },
            .ringing_out = .{
                .permit = .{
                    .{ .hang_up, .idle },
                    .{ .remote_answered, .in_call },
                },
            },
            .ringing_in = .{
                .permit = .{
                    .{ .answer, .in_call },
                    .{ .hang_up, .idle },
                },
            },
            .in_call = .{
                .permit = .{
                    .{ .hang_up, .idle },
                    .{ .hold, .on_hold },
                },
            },
            .on_hold = .{
                .permit = .{
                    .{ .resume_call, .in_call },
                    .{ .hang_up, .idle },
                },
            },
        },
    });

    pub const State = _fsm.State;
    pub const Event = _fsm.Event;
    pub const Machine = _fsm.Machine;

    state: State = .idle,
    /// Set by the audio system when the dialed number connects.
    line_open: bool = false,
    /// Set when the caller cancels mid-dial before connect.
    dial_cancelled: bool = false,
    /// Set when the remote party drops the line.
    remote_hung_up: bool = false,

    const guards = struct {
        fn lineOpen(p: *Phone) bool {
            return p.line_open;
        }
        fn dialCancelled(p: *Phone) bool {
            return p.dial_cancelled;
        }
    };

    const actions = struct {
        fn clearFlags(p: *Phone) void {
            p.line_open = false;
            p.dial_cancelled = false;
            p.remote_hung_up = false;
        }
    };
};
