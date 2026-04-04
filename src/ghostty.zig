/// Zig bindings for the libghostty-vt C API.
pub const c = @cImport({
    @cInclude("ghostty/vt.h");
});

// Re-export commonly used types
pub const Terminal = c.GhosttyTerminal;
pub const TerminalOptions = c.GhosttyTerminalOptions;
pub const TerminalOption = c.GhosttyTerminalOption;
pub const TerminalData = c.GhosttyTerminalData;
pub const TerminalScrollViewport = c.GhosttyTerminalScrollViewport;
pub const TerminalScrollViewportTag = c.GhosttyTerminalScrollViewportTag;

pub const RenderState = c.GhosttyRenderState;
pub const RenderStateRowIterator = c.GhosttyRenderStateRowIterator;
pub const RenderStateRowCells = c.GhosttyRenderStateRowCells;
pub const RenderStateDirty = c.GhosttyRenderStateDirty;
pub const RenderStateData = c.GhosttyRenderStateData;
pub const RenderStateRowData = c.GhosttyRenderStateRowData;
pub const RenderStateRowCellsData = c.GhosttyRenderStateRowCellsData;
pub const RenderStateOption = c.GhosttyRenderStateOption;
pub const RenderStateRowOption = c.GhosttyRenderStateRowOption;
pub const RenderStateColors = c.GhosttyRenderStateColors;
pub const RenderStateCursorVisualStyle = c.GhosttyRenderStateCursorVisualStyle;

pub const Style = c.GhosttyStyle;
pub const StyleColor = c.GhosttyStyleColor;
pub const ColorRgb = c.GhosttyColorRgb;
pub const GhosttyString = c.GhosttyString;
pub const Result = c.GhosttyResult;

pub const WritePtyFn = c.GhosttyTerminalWritePtyFn;
pub const BellFn = c.GhosttyTerminalBellFn;
pub const TitleChangedFn = c.GhosttyTerminalTitleChangedFn;
pub const DeviceAttributesFn = c.GhosttyTerminalDeviceAttributesFn;
pub const DeviceAttributes = c.GhosttyDeviceAttributes;

// Result constants
pub const SUCCESS = c.GHOSTTY_SUCCESS;
pub const OUT_OF_MEMORY = c.GHOSTTY_OUT_OF_MEMORY;
pub const INVALID_VALUE = c.GHOSTTY_INVALID_VALUE;
pub const NO_VALUE = c.GHOSTTY_NO_VALUE;

// Terminal option constants
pub const OPT_USERDATA = c.GHOSTTY_TERMINAL_OPT_USERDATA;
pub const OPT_WRITE_PTY = c.GHOSTTY_TERMINAL_OPT_WRITE_PTY;
pub const OPT_BELL = c.GHOSTTY_TERMINAL_OPT_BELL;
pub const OPT_TITLE_CHANGED = c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED;
pub const OPT_DEVICE_ATTRIBUTES = c.GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES;
pub const OPT_XTVERSION = c.GHOSTTY_TERMINAL_OPT_XTVERSION;
pub const OPT_PWD = c.GHOSTTY_TERMINAL_OPT_PWD;
pub const OPT_COLOR_FOREGROUND = c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND;
pub const OPT_COLOR_BACKGROUND = c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND;
pub const OPT_COLOR_PALETTE = c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE;
pub const DATA_COLOR_PALETTE = c.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE;

// Terminal data constants
pub const DATA_COLS = c.GHOSTTY_TERMINAL_DATA_COLS;
pub const DATA_ROWS = c.GHOSTTY_TERMINAL_DATA_ROWS;
pub const DATA_TITLE = c.GHOSTTY_TERMINAL_DATA_TITLE;
pub const DATA_PWD = c.GHOSTTY_TERMINAL_DATA_PWD;
pub const DATA_MOUSE_TRACKING = c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING;

// Render state data constants
pub const RS_DATA_DIRTY = c.GHOSTTY_RENDER_STATE_DATA_DIRTY;
pub const RS_DATA_COLS = c.GHOSTTY_RENDER_STATE_DATA_COLS;
pub const RS_DATA_ROWS = c.GHOSTTY_RENDER_STATE_DATA_ROWS;
pub const RS_DATA_ROW_ITERATOR = c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR;
pub const RS_DATA_COLOR_BACKGROUND = c.GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND;
pub const RS_DATA_COLOR_FOREGROUND = c.GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND;
pub const RS_DATA_CURSOR_VISUAL_STYLE = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE;
pub const RS_DATA_CURSOR_VISIBLE = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE;
pub const RS_DATA_CURSOR_BLINKING = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING;
pub const RS_DATA_CURSOR_VIEWPORT_HAS_VALUE = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE;
pub const RS_DATA_CURSOR_VIEWPORT_X = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X;
pub const RS_DATA_CURSOR_VIEWPORT_Y = c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y;

// Render state row data constants
pub const RS_ROW_DATA_DIRTY = c.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY;
pub const RS_ROW_DATA_CELLS = c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS;

// Raw row data constants (from screen API, via ROW_DATA_RAW)
pub const ROW_DATA_WRAP = c.GHOSTTY_ROW_DATA_WRAP;
pub const ROW_DATA_SEMANTIC_PROMPT = c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT;
pub const ROW_DATA_HYPERLINK = c.GHOSTTY_ROW_DATA_HYPERLINK;

// Render state row cells data constants
pub const RS_CELLS_DATA_STYLE = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE;
pub const RS_CELLS_DATA_GRAPHEMES_LEN = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN;
pub const RS_CELLS_DATA_GRAPHEMES_BUF = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF;
pub const RS_CELLS_DATA_BG_COLOR = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR;
pub const RS_CELLS_DATA_FG_COLOR = c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR;

// Render state option constants
pub const RS_OPT_DIRTY = c.GHOSTTY_RENDER_STATE_OPTION_DIRTY;
pub const RS_ROW_OPT_DIRTY = c.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY;

// Dirty constants
pub const DIRTY_FALSE: c_int = c.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
pub const DIRTY_PARTIAL: c_int = c.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL;
pub const DIRTY_FULL: c_int = c.GHOSTTY_RENDER_STATE_DIRTY_FULL;

// Cursor visual style constants
pub const CURSOR_BAR: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR;
pub const CURSOR_BLOCK: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
pub const CURSOR_UNDERLINE: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE;
pub const CURSOR_BLOCK_HOLLOW: c_int = c.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW;

// Scroll viewport constants
pub const SCROLL_TOP: c_int = c.GHOSTTY_SCROLL_VIEWPORT_TOP;
pub const SCROLL_BOTTOM: c_int = c.GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
pub const SCROLL_DELTA: c_int = c.GHOSTTY_SCROLL_VIEWPORT_DELTA;

// Formatter types and constants
pub const Formatter = c.GhosttyFormatter;
pub const FormatterTerminalOptions = c.GhosttyFormatterTerminalOptions;
pub const FormatterTerminalExtra = c.GhosttyFormatterTerminalExtra;
pub const FormatterScreenExtra = c.GhosttyFormatterScreenExtra;
pub const FORMATTER_FORMAT_HTML: c_int = c.GHOSTTY_FORMATTER_FORMAT_HTML;
