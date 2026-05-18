# src_v2 — investigative v2 designs

Four prototype FSM libraries exploring "more comptime, more declarative" than
v1's flat transition table. All four compile and have inline tests; the
project ships `zig build test` against variant_d plus its component examples.
The other three are kept as design reference points — they document *why* we
landed on variant_d.

| File | Idea | Status |
|------|------|--------|
| `variant_a.zig` | Comptime O(1) dispatch table + hand-written `EnumSet(State)` legality schema (`@compileError` on transition drift) + accepted-event introspection. | Reference — kept for the schema-as-second-source-of-truth idea. |
| `variant_b.zig` | Same dispatch table as A, but `reachable_from` is auto-derived from the transition list (no separate schema). Loses the drift-check, gains less boilerplate. | Reference — kept to show what "no schema" costs you. |
| `variant_c.zig` | v1 verbatim + a single opt-in `validate(reachable_from)` comptime call layered on top. Smallest possible delta from v1. | Reference — kept as the minimum-risk migration path. |
| `variant_d.zig` | **Chosen design.** Stateless-flavored declarative API. Per-state config blocks with `permit` / `auto` / `on_entry` / `on_exit` / `ignore`. Exposes `Build(...)`, `BuildFor(Component, ...)` and `Define(Context, ...)`. | Production candidate. |

## variant_d in 30 seconds

```zig
const Machine = fsm.Build(MyState, MyEvent, *MyComponent, .{
    .initial = .idle,
    .states = .{
        .idle = .{
            .on_entry = actions.resetTimer,
            .permit = .{
                .{ .start, .running },
            },
        },
        .running = .{
            .permit = .{
                .{ .finish, .done },
                .{ .cancel, .idle },
            },
            .auto = .{
                .{ guards.timedOut, .idle },
            },
        },
        .done = .{},
    },
});

Machine.dispatch(.start, &my.state, &my);
Machine.advance(&my.state, &my);
```

Comptime checks: every State enum value must appear as a key in `.states`;
duplicate `(from, event)` permits fail to compile; unguarded duplicate `auto`
entries fail to compile; events that are both permitted and ignored fail to
compile.

## Component layout choices

Two canonical examples live in `tests/v2/` (also exercised by
`zig build test`):

- **`phone_component.zig`** — *internal* layout. State enum, event enum,
  machine, guards, and actions all live as decls on the `Phone` struct via
  `fsm.Define(*@This(), .{...})`. Zero file-scope decls outside `Phone`.
  Best for small / medium machines.
- **`semaphore_component.zig`** + **`semaphore_behavior.zig`** — *external*
  layout. Guards and actions live in a sibling file behind a comptime
  generator (`pub fn make(comptime Semaphore: type) type`), pulled in via
  `const behavior = @import("semaphore_behavior.zig").make(@This())`. No
  circular import because the behavior file receives the component type as
  a parameter. Best when guards/actions grow large enough to crowd the
  component file.

Both layouts use the same `fsm.Define` API. Migrating internal → external is
a mechanical move of two decls into a sibling file.

## Save / load

Components opt in to serialization with the same line they'd use in v1 game
code:

```zig
pub const save = core.Saveable(.saveable, @This(), .{});
```

`tests/v2/specs/*_spec.zig` proves the roundtrip: enum tag survives as a JSON
string, every data field survives intact, and the machine still drives the
restored instance. Negative assertions also lock in that the FSM decls
(`_fsm`, `Machine`, `State`, `Event`, `guards`, `actions`, `behavior`) do
**not** appear in the serialized payload — they're decls, not fields, so
`serde.writeComponent` (which iterates `@typeInfo` fields) ignores them by
construction; the tests make this an explicit contract.

## Status

Investigative. Not yet promoted to `src/` or wired into the public module.
See the open PR for findings, open questions, and the proposed migration path
for existing v1 machines (`sleep_machine`, candidate `HungerCarry`).
