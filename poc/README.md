# labelle-fsm POC

Standalone proof-of-concept for the state-machine library proposed in
[`../RFC.md`](../RFC.md). Deliberately labelle-free: just `std` plus
`zig-ecs`, same ECS backend labelle games use. If the POC works, the
RFC's API claims survive contact with a real compiler and a real ECS.

## What this validates

1. **`StateMachine(State, Event, Context)` compiles** as a comptime generic
   with all three type parameters, and the same file can host both
   guard-only and event-driven transitions in one table.
2. **State lives as a plain enum on a component.** The machine struct
   itself holds nothing but a comptime slice — no heap, no per-instance
   bookkeeping, no pointers that would break save/load.
3. **`advance()` and `dispatch()` both work** and interact cleanly when
   applied to the same machine instance across frames.
4. **`on_enter` / `on_exit` fire at the right moment** — the terminal
   `.opening → .opening` transition removes the component from the
   registry via `on_enter`.
5. **zig-ecs integration is trivial.** The tick system iterates a view
   and passes pointers via the Context struct; nothing about the library
   needs to know it's being driven by an ECS.
6. **Caller-owned tick.** The library never calls anything on its own —
   `sleep_tick.tick()` and `sleep_hooks.workerSleepEnd()` decide when to
   advance or dispatch.

## File layout (mirrors the RFC's recommended structure)

```
poc/
├── build.zig                     # Zig build — `run` and `test` steps
├── build.zig.zon                 # declares the zig-ecs dependency
└── src/
    ├── main.zig                  # entry point, wires pieces together
    ├── lib/
    │   └── fsm.zig               # the state-machine library + unit tests
    ├── components/               # pure data, plain enums
    │   ├── sleeping.zig
    │   └── worker.zig
    ├── state_machines/           # one file per machine (RFC locality rule)
    │   └── sleep_machine.zig     # Event, Context, Machine, guards, actions, transitions
    ├── systems/                  # per-frame tick drivers → call advance()
    │   └── sleep_tick.zig
    └── hooks/                    # event-side drivers → call dispatch()
        └── sleep_hooks.zig
```

## Running

```bash
cd poc
zig build test   # 8 library unit tests
zig build run    # runnable example, prints every transition
```

## Expected output

The example simulates a few frames plus two external wake events, showing:

- Two workers tick through `.closing → .closed` from polled guards
- Worker B is woken by a dispatched `.wake` event
- Worker A is woken the same way
- Both curtain-opening animations complete and the `Sleeping` component
  is removed
- A final "no-op" dispatch to an already-awake worker returns
  `.not_declared` without error

See `src/main.zig` for the exact sequence.

## Relation to the RFC

Every file in `src/` directly maps to the RFC's "Mandatory exports" and
"Project structure" sections:

| RFC section                        | POC file                                      |
|------------------------------------|-----------------------------------------------|
| Proposed API                       | `src/lib/fsm.zig`                             |
| Polled vs. event-driven            | `src/state_machines/sleep_machine.zig` (both) |
| Mandatory exports                  | `src/state_machines/sleep_machine.zig`        |
| Per-frame work stays imperative    | `src/systems/sleep_tick.zig`                  |
| External events dispatch, no bypass| `src/hooks/sleep_hooks.zig`                   |
| Component holds plain enum         | `src/components/sleeping.zig`                 |
| Example: Sleeping rewritten        | all of `src/` together                        |

If anything in the RFC doesn't match this POC, the POC is the authority
(it compiles and runs).
