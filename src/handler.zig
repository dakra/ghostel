//! Custom stream handler that delegates almost everything to libghostty's
//! standard terminal handler but intercepts OSC-related actions so we can route
//! them to Elisp callbacks instead of re-parsing the same bytes ourselves.

const std = @import("std");

const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const GhostelTerm = @import("GhostelTerm.zig");

pub fn GhostelHandler(Context: type) type {
    return struct {
        const Self = @This();

        context: Context,
        inner: gt.TerminalStream.Handler,

        pub fn init(context: Context, terminal: *gt.Terminal) Self {
            var self = Self{ .context = context, .inner = .init(terminal) };
            self.inner.effects.write_pty = &writePtyCallback;
            self.inner.effects.bell = &bellCallback;
            self.inner.effects.device_attributes = &deviceAttributesCallback;
            self.inner.effects.title_changed = &titleChangedCallback;
            self.inner.effects.size = &sizeCallback;
            return self;
        }

        /// Called by `gt.Stream.deinit`.
        pub fn deinit(self: *Self) void {
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
                // For `semantic_prompt` and `color_operation` we forward FIRST
                // so the standard handler updates terminal state (per-row
                // semantic flag, palette/dynamic color sets), then fire the
                // Elisp callback / emit the query reply.
                .semantic_prompt => {
                    self.inner.vt(action, value);
                    self.handleSemanticPrompt(value);
                },
                .color_operation => {
                    self.inner.vt(action, value);
                    self.handleColorOperation(value);
                },

                // For these, the standard handler is a no-op (see
                // `stream_terminal.zig` — they are listed in the "no
                // terminal-modifying effect" arm), so we handle them
                // entirely here.
                .report_pwd => self.handleReportPwd(value),
                .clipboard_contents => self.handleClipboardContents(value),
                .show_desktop_notification => self.handleNotification(value),
                .progress_report => self.handleProgressReport(value),

                else => self.inner.vt(action, value),
            }
        }

        /// Called when the terminal needs to write response data back to the PTY.
        fn writePtyCallback(handler: *gt.TerminalStream.Handler, data: [:0]const u8) void {
            const self: *Self = @fieldParentPtr("inner", handler);
            if (data.len == 0) return;
            self.context.ptyWrite(data) catch {};
        }

        /// Called when the terminal receives BEL.
        fn bellCallback(handler: *gt.TerminalStream.Handler) void {
            const self: *Self = @fieldParentPtr("inner", handler);
            self.context.effect("ding", .{});
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

        /// Called when the terminal title changes.
        fn titleChangedCallback(handler: *gt.TerminalStream.Handler) void {
            const self: *Self = @fieldParentPtr("inner", handler);
            const title = handler.terminal.getTitle();
            if (title) |t| {
                self.context.effect("ghostel--set-title", .{t});
            }
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

        // ---------------------------------------------------------------------------
        // OSC 4 / 10 / 11 — color query reply
        // ---------------------------------------------------------------------------

        /// Walk the request list looking for `.query` entries and emit a reply for each.
        /// The standard handler has already applied any `.set` / `.reset` entries in
        /// the same list, so the colors we read are the post-update values - which
        /// matches what shells expect when a single OSC carries both a set and a query.
        ///
        /// We reply for OSC 4 (palette), OSC 10 (foreground), and OSC 11 (background).
        /// Other dynamic colors (cursor, pointer, highlight, tektronix) are queryable through
        /// this same action but ghostel doesn't track them, so their queries silently drop.
        fn handleColorOperation(self: *Self, v: gt.StreamAction.ColorOperation) void {
            var it = v.requests.constIterator(0);
            while (it.next()) |req| {
                const target = switch (req.*) {
                    .query => |t| t,
                    else => continue,
                };
                switch (target) {
                    .palette => |idx| {
                        const color = self.inner.terminal.colors.palette.current[idx];
                        self.sendPaletteColorReply(idx, color, v.terminator);
                    },
                    .dynamic => |d| switch (d) {
                        .foreground => {
                            if (self.inner.terminal.colors.foreground.get()) |color|
                                self.sendDynamicColorReply(10, color, v.terminator);
                        },
                        .background => {
                            if (self.inner.terminal.colors.background.get()) |color|
                                self.sendDynamicColorReply(11, color, v.terminator);
                        },
                        else => {}, // cursor / highlight / pointer / tektronix — drop
                    },
                    .special => {}, // OSC 5 — drop
                }
            }
        }

        /// Send `OSC N;rgb:RRRR/GGGG/BBBB <term>` for a dynamic color (OSC 10/11).
        fn sendDynamicColorReply(
            self: *Self,
            osc_num: u8,
            color: gt.color.RGB,
            terminator: gt.osc.Terminator,
        ) void {
            var buf: [64]u8 = undefined;
            const written = std.fmt.bufPrint(
                &buf,
                "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
                .{
                    osc_num,
                    color.r,
                    color.r,
                    color.g,
                    color.g,
                    color.b,
                    color.b,
                    terminator.string(),
                },
            ) catch return;
            self.context.ptyWrite(written) catch {};
        }

        /// Send `OSC 4;INDEX;rgb:RRRR/GGGG/BBBB <term>` for a palette entry.
        fn sendPaletteColorReply(
            self: *Self,
            index: u8,
            color: gt.color.RGB,
            terminator: gt.osc.Terminator,
        ) void {
            var buf: [64]u8 = undefined;
            const written = std.fmt.bufPrint(
                &buf,
                "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}",
                .{
                    index,
                    color.r,
                    color.r,
                    color.g,
                    color.g,
                    color.b,
                    color.b,
                    terminator.string(),
                },
            ) catch return;
            self.context.ptyWrite(written) catch {};
        }
    };
}
