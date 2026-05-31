# Ghostel architecture

This document is a work in progress. It is not a complete architecture guide yet, but contains the things we have found important to document.

## Renderer and buffer positions

### Renderer-owned buffer position preservation

Ghostel renders a terminal grid into an Emacs buffer. Rendering is not a normal append-only text editing workflow: rows may be replaced, buffers may be rebuilt, resizes may reflow terminal contents, and scrollback may be materialized or evicted.

Despite that, Elisp code should be able to treat the ghostel buffer like a normal Emacs buffer: if it puts point, mark, or window state somewhere, those positions should remain meaningful after the renderer updates the buffer.

The renderer is therefore responsible for preserving relevant buffer positions across the buffer mutations it performs. The exact set of saved positions and the mechanics of how they are transformed are implementation details; the code and tests are the source of truth for those specifics.

The architectural boundary is that the renderer owns the mechanical transformation of positions caused by rendering operations. This keeps Elisp code simple. Elisp should not need to wrap every redraw with ad-hoc marker capture/restore logic just to defend against renderer mutations.

### Avoid around-redraw semantic patching in Elisp

A general design principle follows from this: do not patch renderer-owned semantics with around-redraw hacks in Elisp.

Elisp should decide policy and user intent, for example:

- whether an input action should snap to the live viewport
- whether Emacs/copy/line mode should preserve navigation state
- whether a window should follow the live terminal viewport
- where a command intentionally moves point

The renderer should handle the consequences of rendering, for example:

- row replacement
- full redraws
- resize/reflow
- scrollback growth and eviction
- preserving buffer/window positions through those mutations

When Elisp tries to compensate after the fact for renderer mutations, it tends to become heuristic and fragile: it has to guess whether `window-start` moved because the user scrolled, Emacs redisplay clamped it, a resize happened, or the renderer rewrote content. The renderer has the exact edit boundaries and terminal state, so that logic belongs there.

In short: Elisp should be able to write normal Emacs code with the expectation that point is where it put it. The renderer is the compatibility layer that makes that true while the terminal grid is being rewritten underneath.
