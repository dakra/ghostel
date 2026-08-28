//! Custom stream handler that delegates almost everything to libghostty's
//! standard terminal handler but intercepts OSC-related actions so we can route
//! them to Elisp callbacks instead of re-parsing the same bytes ourselves.

const std = @import("std");
const Allocator = std.mem.Allocator;

const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const GhostelTerm = @import("GhostelTerm.zig");
const utils = @import("utils.zig");

const log = std.log.scoped(.GhostelHandler);

// xterm limits the title stack to 10 entries.
const title_stack_max = 10;

pub fn GhostelHandler(Context: type) type {
    return struct {
        const Self = @This();

        alloc: Allocator,
        context: Context,
        inner: gt.TerminalStream.Handler,
        // Null entries represent an unset title.
        title_stack: [title_stack_max]?[]u8,
        title_stack_len: usize,

        pub fn init(alloc: Allocator, context: Context, terminal: *gt.Terminal) Self {
            var self = Self{
                .alloc = alloc,
                .context = context,
                .inner = .init(terminal),
                .title_stack = @splat(null),
                .title_stack_len = 0,
            };
            self.inner.effects.write_pty = &writePtyCallback;
            self.inner.effects.bell = &bellCallback;
            self.inner.effects.color_scheme = &colorSchemeCallback;
            self.inner.effects.device_attributes = &deviceAttributesCallback;
            self.inner.effects.title_changed = &titleChangedCallback;
            self.inner.effects.size = &sizeCallback;
            return self;
        }

        /// Called by `gt.Stream.deinit`.
        pub fn deinit(self: *Self) void {
            self.clearTitleStack();
            self.inner.deinit();
        }

        /// Dispatcher invoked by `gt.Stream` for every parser action.  Anything
        /// outside the OSC arms below is forwarded verbatim to the standard
        /// handler so terminal state stays consistent.
        pub fn vt(
            self: *Self,
            comptime action: gt.StreamAction.Tag,
            value: gt.StreamAction.Value(action),
        ) void {
            switch (action) {
                // For `semantic_prompt` we forward FIRST so the standard
                // handler updates terminal state (per-row semantic flag),
                // then fire the Elisp callback.
                .semantic_prompt => {
                    self.inner.vt(action, value);
                    self.handleSemanticPrompt(value);
                },

                // For these, the standard handler is a no-op (see
                // `stream_terminal.zig` — they are listed in the "no
                // terminal-modifying effect" arm), so we handle them
                // entirely here.
                .report_pwd => self.handleReportPwd(value),
                .clipboard_contents => self.handleClipboardContents(value),
                .show_desktop_notification => self.handleNotification(value),
                .progress_report => self.handleProgressReport(value),

                .full_reset => {
                    const had_title = self.inner.terminal.getTitle() != null;
                    self.clearTitleStack();
                    self.inner.vt(action, value);
                    // libghostty clears the title on RIS without firing title_changed.
                    if (had_title) titleChangedCallback(&self.inner);
                    // Progress exists only in Elisp, so RIS must remove it explicitly.
                    self.handleProgressReport(.{ .state = .remove });
                },

                // The parser filters icon-title forms; indexed stacks are unsupported.
                .title_push => if (value == 0) self.titlePush(),
                .title_pop => if (value == 0) self.titlePop(),

                else => self.inner.vt(action, value),
            }
        }

        /// Called when the terminal needs to write response data back to the PTY.
        fn writePtyCallback(handler: *gt.TerminalStream.Handler, data: [:0]const u8) void {
            const self: *Self = @fieldParentPtr("inner", handler);
            if (data.len == 0) return;
            self.context.ptyWriteFromTerminal(data);
        }

        /// Called when the terminal receives BEL.
        fn bellCallback(handler: *gt.TerminalStream.Handler) void {
            const self: *Self = @fieldParentPtr("inner", handler);
            self.context.effect("ding", .{});
        }

        // `device_status.ColorScheme` is not re-exported from ghostty-vt.
        const ColorSchemeFn = @typeInfo(
            @typeInfo(
                @FieldType(gt.TerminalStream.Handler.Effects, "color_scheme"),
            ).optional.child,
        ).pointer.child;
        const ColorScheme = @typeInfo(ColorSchemeFn).@"fn".return_type.?;

        /// CSI ? 996 n — report light/dark from the protocol background color.
        fn colorSchemeCallback(handler: *gt.TerminalStream.Handler) ColorScheme {
            return if (utils.backgroundIsLight(handler.terminal.colors.background.default))
                .light
            else
                .dark;
        }

        // TODO: DeviceAttributes is not exported from ghostty-vt for some reason.
        //       We should file an issue.
        const DeviceAttributesFn = @typeInfo(
            @typeInfo(
                @FieldType(gt.TerminalStream.Handler.Effects, "device_attributes"),
            ).optional.child,
        ).pointer.child;
        const DeviceAttributes = @typeInfo(DeviceAttributesFn).@"fn".return_type.?;

        /// Called when the terminal receives a device attributes query (DA1/DA2/DA3).
        /// Reports as a VT220-compatible terminal with ANSI color support.
        fn deviceAttributesCallback(_: *gt.TerminalStream.Handler) DeviceAttributes {
            return .{
                .primary = .{
                    .conformance_level = .vt220,
                    .features = &.{.ansi_color},
                },
                .secondary = .{
                    .device_type = .vt220,
                    .firmware_version = 1,
                    .rom_cartridge = 0,
                },
                .tertiary = .{
                    .unit_id = 0,
                },
            };
        }

        /// Called for XTWINOPS size queries (CSI 14/16/18 t).
        fn sizeCallback(handler: *gt.TerminalStream.Handler) ?gt.size_report.Size {
            return .{
                .rows = handler.terminal.rows,
                .columns = handler.terminal.cols,
                .cell_width = handler.terminal.width_px / handler.terminal.cols,
                .cell_height = handler.terminal.height_px / handler.terminal.rows,
            };
        }

        /// Called when the terminal title changes.  A cleared title (empty
        /// OSC 0/2) reads back as null and is forwarded as "".
        fn titleChangedCallback(handler: *gt.TerminalStream.Handler) void {
            const self: *Self = @fieldParentPtr("inner", handler);
            const title = handler.terminal.getTitle() orelse "";
            self.context.effect("ghostel--set-title", .{title});
        }

        // ---------------------------------------------------------------------------
        // CSI 22/23 t — window title stack
        // ---------------------------------------------------------------------------

        fn titlePush(self: *Self) void {
            if (self.title_stack_len == title_stack_max) return;
            const entry: ?[]u8 = if (self.inner.terminal.getTitle()) |t|
                self.alloc.dupe(u8, t) catch {
                    log.warn("title push dropped: out of memory", .{});
                    return;
                }
            else
                null;
            self.title_stack[self.title_stack_len] = entry;
            self.title_stack_len += 1;
        }

        // Route restores through the inner handler to synchronize native and Elisp state.
        fn titlePop(self: *Self) void {
            if (self.title_stack_len == 0) return;
            self.title_stack_len -= 1;
            const entry = self.title_stack[self.title_stack_len];
            self.inner.vt(.window_title, .{ .title = entry orelse "" });
            if (entry) |e| self.alloc.free(e);
        }

        fn clearTitleStack(self: *Self) void {
            for (self.title_stack[0..self.title_stack_len]) |entry| {
                if (entry) |e| self.alloc.free(e);
            }
            self.title_stack_len = 0;
        }

        // ---------------------------------------------------------------------------
        // OSC 133 — semantic prompt
        // ---------------------------------------------------------------------------

        /// Fire `ghostel--osc133-marker` for the marker types ghostel's
        /// navigation tracks: A/N (fresh-line prompt), P (explicit prompt start),
        /// B (end of prompt prefix), C (start of output), D (end of command).
        ///
        /// PARAM is the raw options string from the OSC - elisp parses it on
        /// demand (e.g. `(string-to-number param)` for the 'D' exit code).
        fn handleSemanticPrompt(self: *Self, sp: gt.osc.Command.SemanticPrompt) void {
            const marker_char: u8 = switch (sp.action) {
                .fresh_line_new_prompt, .new_command => 'A',
                .prompt_start => 'P',
                .end_prompt_start_input => 'B',
                .end_input_start_output => 'C',
                .end_command => 'D',
                else => return,
            };
            const type_str: [1]u8 = .{marker_char};
            const param_val = if (sp.options_unvalidated.len > 0)
                sp.options_unvalidated
            else
                null;

            self.context.effect("ghostel--osc133-marker", .{ &type_str, param_val });
        }

        // ---------------------------------------------------------------------------
        // OSC 7 / OSC 9;9 — report PWD
        // ---------------------------------------------------------------------------

        /// Update Emacs from the reported PWD.
        fn handleReportPwd(self: *Self, v: gt.StreamAction.ReportPwd) void {
            if (v.url.len == 0) return;
            self.context.effect("ghostel--update-directory", .{v.url});
        }

        // ---------------------------------------------------------------------------
        // OSC 52 — clipboard contents (kind 'e' = ghostel's elisp-eval extension)
        // ---------------------------------------------------------------------------

        /// Route OSC 52 to Elisp.  `kind == 'e'` is ghostel's elisp-eval extension;
        /// the parser accepts any byte as `data[0]` and hands us the payload after the
        /// required `;` separator.  All other kinds are standard clipboard selectors
        /// (xterm: `c p q s 0-7`; kitty: `a`) and go to the clipboard handler.
        ///
        /// Queries ("?") and empty payloads carry no useful content, so they
        /// don't cross the FFI boundary regardless of kind.
        fn handleClipboardContents(self: *Self, v: gt.StreamAction.ClipboardContents) void {
            if (v.data.len == 0) return;
            if (v.data.len == 1 and v.data[0] == '?') return;

            switch (v.kind) {
                'e' => _ = self.context.effect("ghostel--osc52-eval", .{v.data}),
                else => {
                    const kind_str: [1]u8 = .{v.kind};
                    _ = self.context.effect("ghostel--osc52-handle", .{ &kind_str, v.data });
                },
            }
        }

        // ---------------------------------------------------------------------------
        // OSC 9 (iTerm) / OSC 777 — desktop notification
        // ---------------------------------------------------------------------------

        /// An entirely empty notification (`\x1b]9;\x1b\\` or
        /// `\x1b]777;notify;;\x1b\\`) carries no content; the elisp default
        /// handler would just show the buffer name with an empty body.  Drop
        /// it at the FFI boundary rather than pay the call for nothing.
        fn handleNotification(self: *Self, v: gt.StreamAction.ShowDesktopNotification) void {
            if (v.title.len == 0 and v.body.len == 0) return;
            self.context.effect("ghostel--handle-notification", .{ v.title, v.body });
        }

        // ---------------------------------------------------------------------------
        // OSC 9;4 — ConEmu progress
        // ---------------------------------------------------------------------------

        /// Forward the state and progress verbatim from ghostty's parser.
        fn handleProgressReport(self: *Self, v: gt.osc.Command.ProgressReport) void {
            const state_str: []const u8 = switch (v.state) {
                .remove => "remove",
                .set => "set",
                .@"error" => "error",
                .indeterminate => "indeterminate",
                .pause => "pause",
            };
            const progress_val = if (v.progress) |p| p else null;
            self.context.effect("ghostel--osc-progress", .{ state_str, progress_val });
        }
    };
}
