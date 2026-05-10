# ghostel/src — Zig coding principles

## Architectural guidelines

- Updating the `RenderState` with `ghostty_render_state_update`, directly or indirectly, **consumes** dirty state from the terminal. For this reason, **only** the Renderer (in `Renderer.zig`) may do so. Any other usage of `ghostty_render_state_update` **will** break the `Renderer`.
- The viewport scroll position must always remain at the position that the `Renderer` left it at. Its position is always intentional and is used to track scrolling. Moving it and not restoring it **will** break the `Renderer`.
- With the above in mind: If you need information from the rendering process - add ways for the `Renderer` to communicate that information as output from the rendering process. This can be in the form of text properties, buffer local variables. A last resort method is also to add callbacks, but this is more fragile and harder to follow.

## Error handling

- **Errors are always errors.** Never swallow with bare `catch {}` or `catch continue` unless you can prove the specific error code means "no value" (see below). Log or propagate every real error.
- **Know your error codes before mapping them.** `GHOSTTY_INVALID_VALUE` can mean either a programmer error (null handle, bad enum) or "no value configured" depending on which data key you query. Check the libghostty header comment for the specific data key before deciding.
  - `GHOSTTY_NO_VALUE` → always means "optional absence" — map to `null` via `getOpt`.
  - `GHOSTTY_INVALID_VALUE` → usually a programmer error, but some cell-level keys use it to mean "no per-cell value, use terminal default" — check the libghostty header comment for the specific key. When it means absence, use `catch |err| switch (err) { gt.Error.InvalidValue => null, else => return err }`.

## Calling Emacs functions

Prefer `Env` convenience wrappers (`env.insert(...)`, `env.list(...)`, `env.set(...)`, etc.) over calling Emacs functions directly. When no wrapper exists, use `env.f("function-name", .{arg1, arg2})` — the function name must be in the intern cache (`sym` in `emacs.zig`). Arguments are auto-converted from Zig types.

## C ABI boundary (module.zig callbacks)

Functions with `callconv(.c)` cannot propagate Zig errors — handle them explicitly at the call site:

```zig
// For paths that can fail deep in the call stack (redraw, encode, emitPlacements):
something.deepWork() catch |err| {
    env.logStackTrace(@errorReturnTrace());
    env.signalError("deepWork failed: %s", .{@errorName(err)});
    return env.nil();
};

// For simple one-call getters:
const val = term.getSomething() catch |err| {
    env.signalError("getSomething failed: %s", .{@errorName(err)});
    return env.nil();
};

// For void C callbacks (callconv(.c) returning void), use logError instead of signalError:
const val = term.getSomething() catch |err| {
    env.logError("getSomething failed: %s", .{@errorName(err)});
    return;
};

// For per-item errors inside a loop where items are independent, log and continue:
const val = term.getSomething() catch |err| {
    env.logError("getSomething failed: %s", .{@errorName(err)});
    continue;
};
```

## Accessor pattern (ghostty.zig)

All libghostty `_get` functions that follow `(obj, key, *anyopaque) -> GhosttyResult` are wrapped by `Accessor()`:

```zig
// Returns !T — propagates all errors
const val = try gt.terminal_data.get(T, obj, KEY_CONSTANT);

// Returns !?T — maps NO_VALUE to null, propagates other errors
const opt = try gt.terminal_data.getOpt(T, obj, KEY_CONSTANT);

// Writes into an existing pointer (e.g. to repopulate an iterator in-place)
try gt.kitty_graphics_data.read(obj, KEY_CONSTANT, &existing_ptr);
```

Available Accessors (see `ghostty.zig`): `terminal_data`, `row`, `cell`, `rs`, `rs_row`, `rs_row_cells`, `kitty_graphics_data`, `kitty_placement_data`.

`ghostty_terminal_mode_get` has a different signature — use `gt.terminalModeGet(terminal, mode) !bool`.

## Out-pointers

Do not add new functions with out-pointer + bool/null return patterns. Always return `!T` or `!?T`:
- Use the `Accessor` wrappers for C getter functions.
- For `_new` constructor calls (opaque object creation), the out-pointer is inherent to the C ABI — use `try gt.toError(gt.c.ghostty_X_new(null, &handle))`.

## C ABI callbacks — do not change calling convention

Any function with `callconv(.c)` is part of a fixed ABI contract with libghostty or Emacs. Do not change its signature, calling convention, or return type without understanding the ABI contract on both sides.

## Logging

- `signalError` and `logError` automatically prepend `ghostel: ` — do not include it in the message.
- Format strings use Emacs format syntax (`%s`, `%d`) not Zig format syntax (`{s}`, `{d}`).

## Build and format workflow

After editing any `.zig` file:
1. `zig build` — must pass before moving on
2. `zig fmt <file>` — format before committing
