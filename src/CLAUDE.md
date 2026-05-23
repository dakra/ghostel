# ghostel/src — Zig coding principles

## Architectural guidelines

- Calling `render_state.update(...)`, directly or indirectly, **consumes** dirty state from the terminal. For this reason, **only** the Renderer (in `Renderer.zig`) may do so. Any other usage of `render_state.update` **will** break the `Renderer`.
- With the above in mind: If you need information from the rendering process - add ways for the `Renderer` to communicate that information as output from the rendering process. This can be in the form of text properties, buffer local variables. A last resort method is also to add callbacks, but this is more fragile and harder to follow.

## Error handling

- **Errors are always errors.** Never swallow with bare `catch {}` or `catch continue`. Log or propagate every real error.

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

## C ABI callbacks — do not change calling convention

Any function with `callconv(.c)` is part of a fixed ABI contract with libghostty or Emacs. Do not change its signature, calling convention, or return type without understanding the ABI contract on both sides.

## Logging

- `signalError` and `logError` automatically prepend `ghostel: ` — do not include it in the message.
- Format strings use Emacs format syntax (`%s`, `%d`) not Zig format syntax (`{s}`, `{d}`).

## Build and format workflow

After editing any `.zig` file:
1. `zig build` — must pass before moving on
2. `zig fmt <file>` — format before committing
