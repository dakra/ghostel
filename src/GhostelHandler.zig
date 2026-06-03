//! Custom stream handler that delegates almost everything to libghostty's
//! standard terminal handler but intercepts OSC-related actions so we can route
//! them to Elisp callbacks instead of re-parsing the same bytes ourselves.

const std = @import("std");

const emacs = @import("emacs.zig");
const gt = @import("ghostty-vt");
const GhostelTerm = @import("GhostelTerm.zig");

const Self = @This();

inner: gt.TerminalStream.Handler,

/// True iff the previous VT parser action was `carriage_return`.
///
/// Used by the `.linefeed` arm below for primary-screen bare-LF
/// normalization: a bare LF first gets a synthetic CR, while a real
/// CRLF pair is left alone. Since this lives on the stream handler,
/// the state carries across `vtWrite` chunks, so a CR at the end of
/// one chunk and an LF at the start of the next still count as CRLF.
prev_was_cr: bool = false,

pub fn init(terminal: *gt.Terminal) Self {
    return .{ .inner = .init(terminal) };
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
        .linefeed => {
            if (!self.prev_was_cr and
                self.inner.terminal.screens.active_key != .alternate)
            {
                self.inner.vt(.carriage_return, {});
            }
            self.inner.vt(action, value);
        },
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

    self.prev_was_cr = action == .carriage_return;
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
fn handleSemanticPrompt(_: *Self, sp: gt.osc.Command.SemanticPrompt) void {
    const marker_char: u8 = switch (sp.action) {
        .fresh_line_new_prompt, .new_command => 'A',
        .prompt_start => 'P',
        .end_prompt_start_input => 'B',
        .end_input_start_output => 'C',
        .end_command => 'D',
        else => return,
    };
    const e = emacs.current_env orelse return;
    const type_str: [1]u8 = .{marker_char};
    const param_val = if (sp.options_unvalidated.len > 0)
        e.makeString(sp.options_unvalidated)
    else
        e.nil();
    _ = e.f("ghostel--osc133-marker", .{ &type_str, param_val });
}

// ---------------------------------------------------------------------------
// OSC 7 / OSC 9;9 — report PWD
// ---------------------------------------------------------------------------

/// Save the reported PWD on the terminal and update it in Emacs.
fn handleReportPwd(self: *Self, v: gt.StreamAction.ReportPwd) void {
    if (v.url.len == 0) return;
    self.inner.terminal.setPwd(v.url) catch |err| {
        if (emacs.current_env) |e|
            e.logError("setPwd failed: %s", .{@errorName(err)});
    };

    const env = emacs.current_env orelse return;
    _ = env.f("ghostel--update-directory", .{v.url});
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
fn handleClipboardContents(_: *Self, v: gt.StreamAction.ClipboardContents) void {
    if (v.data.len == 0) return;
    if (v.data.len == 1 and v.data[0] == '?') return;
    const e = emacs.current_env orelse return;
    switch (v.kind) {
        'e' => _ = e.f("ghostel--osc52-eval", .{v.data}),
        else => {
            const kind_str: [1]u8 = .{v.kind};
            _ = e.f("ghostel--osc52-handle", .{ &kind_str, v.data });
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
fn handleNotification(_: *Self, v: gt.StreamAction.ShowDesktopNotification) void {
    if (v.title.len == 0 and v.body.len == 0) return;
    const e = emacs.current_env orelse return;
    _ = e.f("ghostel--handle-notification", .{ v.title, v.body });
}

// ---------------------------------------------------------------------------
// OSC 9;4 — ConEmu progress
// ---------------------------------------------------------------------------

/// Forward the state and progress verbatim from ghostty's parser.
fn handleProgressReport(_: *Self, v: gt.osc.Command.ProgressReport) void {
    const e = emacs.current_env orelse return;
    const state_str: []const u8 = switch (v.state) {
        .remove => "remove",
        .set => "set",
        .@"error" => "error",
        .indeterminate => "indeterminate",
        .pause => "pause",
    };
    const progress_val = if (v.progress) |p|
        e.makeInteger(@intCast(p))
    else
        e.nil();
    _ = e.f("ghostel--osc-progress", .{ state_str, progress_val });
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
    const e = emacs.current_env orelse return;

    var it = v.requests.constIterator(0);
    while (it.next()) |req| {
        const target = switch (req.*) {
            .query => |t| t,
            else => continue,
        };
        switch (target) {
            .palette => |idx| {
                const color = self.inner.terminal.colors.palette.current[idx];
                sendPaletteColorReply(e, idx, color, v.terminator);
            },
            .dynamic => |d| switch (d) {
                .foreground => {
                    if (self.inner.terminal.colors.foreground.get()) |color|
                        sendDynamicColorReply(e, 10, color, v.terminator);
                },
                .background => {
                    if (self.inner.terminal.colors.background.get()) |color|
                        sendDynamicColorReply(e, 11, color, v.terminator);
                },
                else => {}, // cursor / highlight / pointer / tektronix — drop
            },
            .special => {}, // OSC 5 — drop
        }
    }
}

/// Send `OSC N;rgb:RRRR/GGGG/BBBB <term>` for a dynamic color (OSC 10/11).
fn sendDynamicColorReply(
    e: emacs.Env,
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
    _ = e.f("ghostel--flush-output", .{written});
}

/// Send `OSC 4;INDEX;rgb:RRRR/GGGG/BBBB <term>` for a palette entry.
fn sendPaletteColorReply(
    e: emacs.Env,
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
    _ = e.f("ghostel--flush-output", .{written});
}
