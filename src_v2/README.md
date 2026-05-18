# v2 — Stateless-flavored declarative FSM

Successor to v1's flat transition table. Per-state config blocks bundle
"what this state permits, what it ignores, what runs on entry/exit" in
one place. Comptime walks the spec, builds an O(1) dispatch table, and
rejects malformed configs with `@compileError`.

Exposed publicly as a sub-namespace of the labelle-fsm module — game
code uses it via:

```zig
const fsm = @import("fsm");
const Machine = fsm.v2.Define(*MyComponent, .{ ... });
```

The library lives entirely in `v2.zig`. v1 (`fsm.StateMachine(...)`)
remains available side-by-side; the two are fully independent so a game
can migrate machines one at a time. `tests/v2/` holds two canonical
component examples and their specs, all run by `zig build test`.

## 30-second tour

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

Three entry points, same underlying machine:

| Entry point | Use when |
|-------------|----------|
| `Build(State, Event, Context, spec)` | You have explicit State / Event enum types you want to pass in. |
| `BuildFor(Component, Context, spec)` | The component has `comptime State: type` and `comptime Event: type` fields — read those instead of repeating. |
| `Define(Context, .{ .State = …, .Event = …, .initial = …, .states = … })` | Bundle State, Event, and Machine into one comptime call. Returns a wrapper exposing `.State`, `.Event`, `.Machine` decls. Best for collapsing a component's whole FSM into a single declaration. |

## Comptime-enforced rules

- **Dense State / Event enums.** State and Event must be plain
  `enum { … }` declarations (dense, zero-based tags). The dispatch
  table is a raw `[state_count][event_count]` array indexed by
  `@intFromEnum`, so custom or sparse tag values would index past the
  array. Sparse enums fail compilation with a clear message naming the
  offending variant.
- **Exhaustiveness on State.** Every variant must appear as a field of
  `.states`. Empty config `.idle = .{}` is the explicit "this state does
  nothing" marker — gaps fail compilation.
- **No duplicate permits.** Declaring `(from, event)` twice fails to
  compile.
- **Permit / ignore exclusion.** An event listed in both `.permit` and
  `.ignore` from the same state fails to compile.
- **Malformed transition opts.** The optional 3rd tuple element of a
  `permit` or `auto` entry must be a struct literal (`.{ .guard = … }`).
  Passing any non-struct (e.g., a bare function pointer) fails with a
  message naming the offending tuple position.

Note: `auto` entries always carry a guard by construction (the first
tuple element is the guard function), so there is no notion of an
"unguarded auto." Multiple guarded `auto` entries from the same state
with overlapping guard predicates are *allowed* — they're tried in
declaration order, first match wins. Static overlap detection on
runtime guards is not possible.

## Supported verbs

- `.permit = .{ .{event, dest}, .{event, dest, .{.guard = g, .on_exit = a, .on_enter = a}} }`
- `.auto = .{ .{guard, dest}, .{guard, dest, .{.on_exit = a, .on_enter = a}} }` — labelle's polled (frame-tick) transitions
- `.on_entry`, `.on_exit` — per-state, fires on every entry/exit
- `.ignore = .{ event, event }` — declared, silent no-op (different from `.not_declared`)

Exit / entry order on a fired transition:
`per-state on_exit → per-transition on_exit → state := dest → per-transition on_enter → per-state on_entry`

Stateless verbs **not** in the minimal cut: `permitReentry`,
`internalTransition`, `onEntryFrom`, `substateOf`, `permitDynamic`,
parameterized triggers. Add when a real machine needs them.

## Component layouts

Two canonical examples live in `tests/v2/`:

### Internal — `phone_component.zig`

State enum, event enum, machine, guards, and actions all live as decls
on the `Phone` struct via `fsm.Define(*@This(), .{...})`. Zero
file-scope decls outside `Phone`. Best for small / medium machines
where keeping everything in one struct aids readability.

### External — `semaphore_component.zig` + `semaphore_behavior.zig`

Guards and actions live in a sibling file behind a comptime generator
function (`pub fn make(comptime Semaphore: type) type`), pulled into
the component via:

```zig
const behavior = @import("semaphore_behavior.zig").make(@This());
```

No circular import: the behavior file never `@import`s the component;
it receives the component type as a comptime parameter. Best when
guards/actions grow large enough to crowd the component file. Migrating
internal → external is a mechanical move of two decls into a sibling
file — no machine-side changes needed.

## Save / load

Components opt in to serialization with the same line they'd use in
game code:

```zig
pub const save = core.Saveable(.saveable, @This(), .{});
```

`tests/v2/specs/*_spec.zig` proves the round-trip end to end: enum tag
survives as a JSON string, every data field survives intact, and the
machine still drives the restored instance.

Negative assertions also lock in that the FSM decls (`_fsm`, `Machine`,
`State`, `Event`, `guards`, `actions`, `behavior`) do **not** appear in
the serialized payload. They can't, by construction — they're decls,
not fields, and `serde.writeComponent` iterates `@typeInfo` fields. The
tests make this an explicit contract so future restructuring (e.g.,
exposing `Machine` as a field for some new introspection pattern)
catches a regression.

## Status

Public as `fsm.v2.*`. v1 (`fsm.StateMachine(...)`) remains the default
for existing machines (e.g. `sleep_machine`); v2 is the recommended
form for new machines and for migrations like the planned `HungerCarry`
port.
