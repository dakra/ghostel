# ghostel/src — Zig coding principles

## Architectural guidelines

- Calling `render_state.update(...)`, directly or indirectly, **consumes** dirty state from the terminal. For this reason, **only** the Renderer (in `Renderer.zig`) may do so. Any other usage of `render_state.update` **will** break the Renderer.
- If you need information from the rendering process, add a way for the Renderer to communicate it as render output: text properties, buffer-local variables, or, as a last resort, callbacks.

## Emacs module function entries

- Functions registered through `emacs.FunctionEntry` should implement `pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value`.
- Prefer `try` and `return error.SomeError` inside those functions. `Env.registerFunction` is the boundary that catches errors, logs the stack trace in debug builds, signals an Emacs error, and returns `nil`. This intentionally trades bespoke user-facing messages for lower boilerplate; debug builds provide the developer detail.
- Do not add repetitive `catch |err| { env.logStackTrace(...); env.signalError(...); return env.nil(); }` boilerplate in each registered function.
- Catch locally only when the local semantics really differ: clearing/handling a module non-local exit, intentionally returning `nil`, or continuing independent items in a loop.

## Error handling

- **Errors are always errors.** Never swallow with bare `catch {}` or `catch continue`. Log, propagate, or make the intentional ignore/continue semantics obvious.
- Prefer error unions for invalid input or parse failures that are real errors. Use optionals for absence, not for failures that should be reported.
- Use precise error names (`error.InvalidTerminalHandle`, `error.OutOfRange`, etc.) so centralized module error reporting remains useful.

## Calling Emacs functions

- Use `env.f("function-name", .{arg1, arg2})` for ordinary Elisp calls. The function name must be present in `interned_symbols` in `emacs.zig`.
- Use existing `Env` helpers when they add conversion or module-API value beyond a trivial Elisp call (`env.list`, `env.cons`, `env.set`, `env.symbolValue`, constructors, extraction helpers, etc.). Do not add one-line wrappers like `env.point()` or `env.insert()` just to shorten `env.f`.
- When passing symbol arguments, use the intern cache (`emacs.sym.foo`). In code with several symbols, prefer `const s = emacs.sym;`.
- Keep `interned_symbols` minimal: add symbols when needed by `env.f` or symbol arguments, and remove unused symbols.

## Value conversion

- Prefer `env.cast(T, value)` over `env.extractInteger`/`env.extractFloat` plus manual `@intCast`/`@floatCast`. It supports integers, floats, and booleans.
- When narrowing to a smaller integer where out-of-range input is possible, use `std.math.cast` after `env.cast(i64, value)` and return an explicit error on failure.
- Zig values passed to `env.f`, `env.list`, `env.cons`, and similar helpers are auto-converted with `env.makeValue`.

## C ABI callbacks — do not change calling convention

Any function with `callconv(.c)` is part of a fixed ABI contract with Emacs. Do not change its signature, calling convention, or return type without understanding the ABI contract on both sides.

Functions that truly are `callconv(.c)` cannot propagate Zig errors. Handle errors explicitly at that boundary:

```zig
const val = term.getSomething() catch |err| {
    env.logError("getSomething failed: %s", .{@errorName(err)});
    return;
};
```

For Emacs functions registered through `FunctionEntry`, prefer the error-union `call` pattern described above instead; the generated C wrapper handles the ABI boundary.

## Logging

- `signalError` and `logError` automatically prepend `ghostel: ` — do not include it in the message.
- Format strings use Emacs format syntax (`%s`, `%d`) not Zig format syntax (`{s}`, `{d}`).

## Build and format workflow

After editing any `.zig` file:
1. `zig build` — must pass before moving on
2. `zig fmt <file>` — format before committing
