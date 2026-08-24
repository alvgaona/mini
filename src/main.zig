//! Mini: a personal browser. Native chrome on a Metal canvas; each tab
//! is an owned webview pane, and window.open popups become tabs.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

/// Routes panics through the SDK so a crash lands in the app's log
/// instead of the terminal Mini was never launched from.
pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const platform = native_sdk.platform;

const canvas_label = "main-canvas";
const page_anchor = "page-pane";
/// URL capacity for the address field and every stored URL. Longer
/// input truncates rather than failing.
pub const max_url_bytes = 2048;
const max_tabs = 16;
const max_closed = 8;
const max_label_bytes = 24;
const max_host_bytes = 128;

const window_width: f32 = 1180;
const window_height: f32 = 760;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Browser chrome", .accessibility_label = "Mini", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Mini",
    .width = window_width,
    .height = window_height,
    .min_width = 640,
    .min_height = 420,
    .restore_state = true,
    .titlebar = .hidden_inset,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// model

/// Everything that can change the model. The markup emits the bound
/// variants; the rest arrive from shortcuts, the engine, or effects.
pub const Msg = union(enum) {
    /// A keystroke in the address field.
    address_edit: canvas.TextInputEvent,
    /// Submit the address field, navigating the active tab.
    navigate,
    /// Step the active tab back through engine history.
    back,
    /// Step the active tab forward through engine history.
    forward,
    /// Reload the active tab.
    reload,
    /// Open a blank tab and make it active.
    new_tab,
    /// Close the tab at this index.
    close_tab: usize,
    /// Make the tab at this index active.
    select_tab: usize,
    /// Enter or leave focus mode.
    toggle_focus,
    /// Close the active tab, or quit once none remain.
    close_active_tab,
    /// Reopen the most recently closed tab.
    reopen_tab,
    /// Put the cursor in the address field.
    focus_address,
    /// Raise the active tab's zoom one step, up to 5.0.
    zoom_in,
    /// Lower the active tab's zoom one step, down to 0.25.
    zoom_out,
    /// Return the active tab to 1.0 zoom.
    zoom_reset,
    /// Copy the active tab's committed URL to the clipboard.
    copy_url,
    /// Show or hide the find bar, clearing the query on the way out.
    find_toggle,
    /// A keystroke in the find field.
    find_edit: canvas.TextInputEvent,
    /// Jump to the next match, ignored while the find bar is closed.
    find_next,
    /// Jump to the previous match, ignored while the find bar is closed.
    find_prev,
    /// Escape. Closes the find bar.
    dismiss,
    /// The engine committed a navigation in one of the panes.
    nav: platform.WebViewNavigationEvent,
    /// A page called window.open; the new pane is adopted as a tab.
    popup_opened: platform.WebViewPopupEvent,
    /// A popup pane closed itself, so its tab goes with it.
    popup_closed: platform.WebViewPopupClosedEvent,
    /// The engine's load fraction for one pane.
    load_progress: platform.WebViewLoadProgressEvent,
    /// A favicon fetch finished, hit or miss.
    favicon_loaded: native_sdk.EffectImageResult,

    /// Variants no markup element emits. The contract check would
    /// otherwise report them as dead.
    pub const view_unbound = .{ "nav", "popup_opened", "popup_closed", "toggle_focus", "close_active_tab", "reopen_tab", "favicon_loaded", "load_progress", "focus_address", "zoom_in", "zoom_out", "zoom_reset", "copy_url", "find_toggle", "find_prev", "dismiss" };
};

/// One webview pane and the chrome state that belongs to it. Every
/// string is inline storage, so a Tab is copyable and the model owns no
/// heap.
pub const Tab = struct {
    /// Pane label, `t{serial}` for a tab Mini opened or the host's own
    /// label for an adopted popup. Read it through `label()`.
    label_storage: [max_label_bytes]u8 = undefined,
    /// Bytes used in `label_storage`.
    label_len: usize = 0,
    /// The URL the engine last committed. Read it through `url()`.
    url_storage: [max_url_bytes]u8 = undefined,
    /// Bytes used in `url_storage`.
    url_len: usize = 0,
    /// The URL handed to the pane. Empty means the pane never
    /// navigates. Read it through `pendingUrl()`.
    pending_storage: [max_url_bytes]u8 = undefined,
    /// Bytes used in `pending_storage`.
    pending_len: usize = 0,
    /// Whether engine history has an entry behind this one.
    can_go_back: bool = false,
    /// Whether engine history has an entry ahead of this one.
    can_go_forward: bool = false,
    /// Bumped to ask the pane to go back; the value itself is inert.
    back_token: u64 = 0,
    /// Bumped to ask the pane to go forward; the value itself is inert.
    forward_token: u64 = 0,
    /// Bumped to ask the pane to reload; the value itself is inert.
    reload_token: u64 = 0,
    /// Whether the tab was adopted from window.open rather than opened
    /// by the user. Popups never enter the reopen stack.
    is_popup: bool = false,
    /// Page scale, clamped to 0.25 through 5.0.
    zoom: f64 = 1.0,
    /// Engine load fraction. 0 outside a load; the bar shows only
    /// strictly between 0 and 1.
    progress: f64 = 0,
    /// Favicon ImageId; 0 draws nothing. Keyed to the host, so in-site
    /// navigation never refetches.
    favicon_id: u64 = 0,
    /// Host `favicon_id` was fetched for.
    favicon_host_storage: [max_host_bytes]u8 = undefined,
    /// Bytes used in `favicon_host_storage`.
    favicon_host_len: usize = 0,

    /// The pane label, which is how engine events find their tab.
    pub fn label(tab: *const Tab) []const u8 {
        return tab.label_storage[0..tab.label_len];
    }

    /// The URL the engine last committed, which may differ from the one
    /// Mini asked for after a redirect.
    pub fn url(tab: *const Tab) []const u8 {
        return tab.url_storage[0..tab.url_len];
    }

    /// The URL the pane is asked to load. Empty leaves the pane alone.
    pub fn pendingUrl(tab: *const Tab) []const u8 {
        return tab.pending_storage[0..tab.pending_len];
    }

    fn setLabel(tab: *Tab, value: []const u8) void {
        tab.label_len = copyInto(&tab.label_storage, value).len;
    }

    fn setUrl(tab: *Tab, value: []const u8) void {
        tab.url_len = copyInto(&tab.url_storage, value).len;
    }

    fn setPending(tab: *Tab, value: []const u8) void {
        tab.pending_len = copyInto(&tab.pending_storage, value).len;
    }
};

/// One row of the tab strip, built per frame into the arena. Markup
/// binds these fields directly.
pub const TabRow = struct {
    /// Position in the strip, which is also the `select_tab` payload.
    index: usize,
    /// The page's host, or "new tab" while the tab is blank.
    title: []const u8,
    /// Whether this row is the active tab.
    active: bool,
    /// Favicon ImageId; 0 draws nothing.
    favicon: u64,
};

/// The whole application state. Fixed capacity throughout, so the
/// model never allocates and nothing here outlives the app.
pub const Model = struct {
    /// Tab storage. Only the first `tab_count` entries are live; the
    /// rest are undefined.
    tabs: [max_tabs]Tab = undefined,
    /// Live entries in `tabs`, capped at 16.
    tab_count: usize = 0,
    /// Index of the active tab, meaningless while `tab_count` is 0.
    active: usize = 0,
    /// Monotonic: closed labels never come back, so a close and a
    /// create in one frame cannot alias.
    tab_serial: u64 = 0,
    /// Monotonic; 0 means no image, so fresh content never re-keys a
    /// live id.
    favicon_serial: u64 = 1,
    /// The address field's text, which tracks the active tab except
    /// while it is being edited.
    address: canvas.TextBuffer(max_url_bytes) = .{},
    /// Hides all chrome. The pane anchor grows to the whole window and
    /// every tab re-snaps to it next frame.
    focus: bool = false,
    /// cmd+shift+T. Closed tabs' URLs, newest last, gone with the app.
    /// Blank tabs and popups never push.
    closed_storage: [max_closed][max_url_bytes]u8 = undefined,
    /// Bytes used in each `closed_storage` slot.
    closed_lens: [max_closed]usize = @splat(0),
    /// Live entries in `closed_storage`; the oldest drops at 8.
    closed_count: usize = 0,
    /// cmd+L. Autofocus edge-triggers it; typing, navigating, or
    /// switching tabs clears it. ponytail: a click into the page leaves
    /// it stale-true and the next cmd+L does nothing; a blur signal
    /// would fix it.
    address_focus_requested: bool = false,
    /// Whether the find bar is showing.
    find_open: bool = false,
    /// The find field's text, handed to the active pane as its query.
    find: canvas.TextBuffer(256) = .{},
    /// Bumped to ask the pane for the next match; inert while closed.
    find_forward_token: u64 = 0,
    /// Bumped to ask the pane for the previous match; inert while closed.
    find_backward_token: u64 = 0,

    /// Markup binds `tabRows`/`addressText` and the two disabled fns;
    /// the rest is update-only.
    pub const view_unbound = .{ "tabs", "address", "tab_serial", "favicon_serial", "tab_count", "active", "focus", "closed_storage", "closed_lens", "closed_count", "address_focus_requested", "find", "find_open", "find_forward_token", "find_backward_token" };

    /// The address field's text, bound by the markup.
    pub fn addressText(model: *const Model) []const u8 {
        return model.address.text();
    }

    /// Whether to draw the toolbar and tab strip, which focus mode hides.
    pub fn chromeVisible(model: *const Model) bool {
        return !model.focus;
    }

    /// True while the active tab is blank, at startup and on cmd+T, so
    /// the cursor lands in the address bar.
    pub fn addressWantsFocus(model: *const Model) bool {
        if (model.address_focus_requested) return true;
        if (model.tab_count == 0) return true;
        const tab = &model.tabs[model.active];
        return tab.url_len == 0 and tab.pending_len == 0;
    }

    /// Whether the find bar is showing. Also drives its autofocus.
    pub fn findOpen(model: *const Model) bool {
        return model.find_open;
    }

    /// The find field's text, bound by the markup.
    pub fn findText(model: *const Model) []const u8 {
        return model.find.text();
    }

    /// Whether the active tab is mid-load, which is when the bar shows.
    pub fn loading(model: *const Model) bool {
        if (model.tab_count == 0) return false;
        const p = model.tabs[model.active].progress;
        return p > 0.0 and p < 1.0;
    }

    /// The active tab's load fraction, for the progress bar.
    pub fn loadProgress(model: *const Model) f32 {
        if (model.tab_count == 0) return 0;
        return @floatCast(model.tabs[model.active].progress);
    }

    /// Whether the back button is dead, which it also is with no tabs.
    pub fn backDisabled(model: *const Model) bool {
        if (model.tab_count == 0) return true;
        return !model.tabs[model.active].can_go_back;
    }

    /// Whether the forward button is dead, which it also is with no tabs.
    pub fn forwardDisabled(model: *const Model) bool {
        if (model.tab_count == 0) return true;
        return !model.tabs[model.active].can_go_forward;
    }

    /// Build the tab strip into the frame arena. An allocation failure
    /// returns an empty strip rather than failing the frame.
    pub fn tabRows(model: *const Model, arena: std.mem.Allocator) []const TabRow {
        const out = arena.alloc(TabRow, model.tab_count) catch return &.{};
        for (model.tabs[0..model.tab_count], 0..) |*tab, index| {
            out[index] = .{
                .index = index,
                .title = tabTitle(tab),
                .active = index == model.active,
                .favicon = tab.favicon_id,
            };
        }
        return out;
    }

    fn activeTab(model: *Model) ?*Tab {
        if (model.tab_count == 0) return null;
        return &model.tabs[model.active];
    }

    fn findTab(model: *Model, label: []const u8) ?*Tab {
        for (model.tabs[0..model.tab_count]) |*tab| {
            if (std.mem.eql(u8, tab.label(), label)) return tab;
        }
        return null;
    }

    fn syncAddress(model: *Model) void {
        const tab = model.activeTab() orelse {
            model.address.clear();
            return;
        };
        model.address.set(tab.url());
    }

    fn appendTab(model: *Model) ?*Tab {
        if (model.tab_count == max_tabs) return null;
        const tab = &model.tabs[model.tab_count];
        tab.* = .{};
        model.tab_count += 1;
        return tab;
    }

    fn rememberClosed(model: *Model, tab: *const Tab) void {
        if (tab.is_popup) return;
        const url_text = if (tab.url_len > 0) tab.url() else tab.pendingUrl();
        if (url_text.len == 0) return;
        if (model.closed_count == max_closed) {
            std.mem.copyForwards([max_url_bytes]u8, model.closed_storage[0 .. max_closed - 1], model.closed_storage[1..]);
            std.mem.copyForwards(usize, model.closed_lens[0 .. max_closed - 1], model.closed_lens[1..]);
            model.closed_count -= 1;
        }
        @memcpy(model.closed_storage[model.closed_count][0..url_text.len], url_text);
        model.closed_lens[model.closed_count] = url_text.len;
        model.closed_count += 1;
    }

    fn removeTab(model: *Model, index: usize) void {
        if (index >= model.tab_count) return;
        std.mem.copyForwards(Tab, model.tabs[index .. model.tab_count - 1], model.tabs[index + 1 .. model.tab_count]);
        model.tab_count -= 1;
        if (model.active >= model.tab_count and model.active > 0) model.active = model.tab_count - 1;
        model.syncAddress();
    }
};

fn hostOf(url_text: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, url_text, "://")) |at| url_text[at + 3 ..] else url_text;
    const end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    return after_scheme[0..end];
}

/// One fetch per host, from the site's own /favicon.ico through the
/// image cascade; CGImageSource reads .ico. A miss leaves id 0 and no
/// icon. ponytail: 16 image slots total, so a window of distinct hosts
/// leaves later tabs iconless; raise app.zon .images if it matters.
fn ensureFavicon(model: *Model, tab: *Tab, fx: *Effects) void {
    const host = hostOf(tab.url());
    if (host.len == 0 or host.len > max_host_bytes) return;
    if (std.mem.eql(u8, host, tab.favicon_host_storage[0..tab.favicon_host_len])) return;
    @memcpy(tab.favicon_host_storage[0..host.len], host);
    tab.favicon_host_len = host.len;
    if (tab.favicon_id != 0) _ = fx.unregisterImage(tab.favicon_id);
    tab.favicon_id = model.favicon_serial;
    model.favicon_serial += 1;
    var url_buffer: [max_host_bytes + 32]u8 = undefined;
    const favicon_url = std.fmt.bufPrint(&url_buffer, "https://{s}/favicon.ico", .{host}) catch return;
    fx.loadImage(.{
        .id = tab.favicon_id,
        .url = favicon_url,
        .on_result = Effects.imageMsg(.favicon_loaded),
    });
}

fn dropFavicon(tab: *Tab, fx: *Effects) void {
    if (tab.favicon_id != 0) _ = fx.unregisterImage(tab.favicon_id);
    tab.favicon_id = 0;
    tab.favicon_host_len = 0;
}

/// A tab button carries the page's host, not the full URL.
fn tabTitle(tab: *const Tab) []const u8 {
    const full = if (tab.url_len > 0) tab.url() else tab.pendingUrl();
    if (full.len == 0) return "new tab";
    return hostOf(full);
}

/// The effect queue `update` writes to for anything outside the model:
/// image loads, the clipboard, quitting.
pub const Effects = native_sdk.Effects(Msg);

/// A bare `example.com` is an address, not a search term, so it gets a
/// scheme. Input that already carries one passes through.
pub fn normalizeUrl(input: []const u8, out: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return out[0..0];

    const schemes = [_][]const u8{ "http://", "https://", "file://", "about:", "data:" };
    const has_scheme = for (schemes) |scheme| {
        if (std.ascii.startsWithIgnoreCase(trimmed, scheme)) break true;
    } else false;
    if (has_scheme) return copyInto(out, trimmed);

    const prefix = "https://";
    if (out.len < prefix.len + trimmed.len) return copyInto(out, trimmed);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..trimmed.len], trimmed);
    return out[0 .. prefix.len + trimmed.len];
}

test normalizeUrl {
    var out: [max_url_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com", normalizeUrl("example.com", &out));
    try std.testing.expectEqualStrings("https://example.com/a?b=c", normalizeUrl("  example.com/a?b=c\n", &out));
    try std.testing.expectEqualStrings("http://localhost:5173", normalizeUrl("http://localhost:5173", &out));
    try std.testing.expectEqualStrings("about:blank", normalizeUrl("about:blank", &out));
    try std.testing.expectEqualStrings("", normalizeUrl("   ", &out));
}

fn copyInto(out: []u8, text: []const u8) []const u8 {
    const len = @min(out.len, text.len);
    @memcpy(out[0..len], text[0..len]);
    return out[0..len];
}

fn openTab(model: *Model, url: []const u8) void {
    const tab = model.appendTab() orelse return;
    var label_buffer: [max_label_bytes]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "t{d}", .{model.tab_serial}) catch return;
    model.tab_serial += 1;
    tab.setLabel(label);
    tab.setPending(url);
    tab.setUrl(url);
    model.active = model.tab_count - 1;
    model.syncAddress();
}

/// Apply one message. The only place the model changes, and the only
/// place effects are queued.
pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .address_edit => |edit| {
            model.address_focus_requested = false;
            model.address.apply(edit);
        },
        .navigate => {
            const tab = model.activeTab() orelse return;
            var scratch: [max_url_bytes]u8 = undefined;
            const url = normalizeUrl(model.address.text(), &scratch);
            if (url.len == 0) return;
            model.address_focus_requested = false;
            tab.setPending(url);
            tab.setUrl(url);
            model.address.set(url);
        },
        .back => if (model.activeTab()) |tab| {
            tab.back_token +%= 1;
        },
        .forward => if (model.activeTab()) |tab| {
            tab.forward_token +%= 1;
        },
        .reload => if (model.activeTab()) |tab| {
            tab.reload_token +%= 1;
        },
        .toggle_focus => model.focus = !model.focus,
        // Tabs absorb Cmd+W; the app only quits when none remain.
        .close_active_tab => {
            if (model.tab_count == 0) {
                fx.quitApp();
                return;
            }
            model.rememberClosed(&model.tabs[model.active]);
            dropFavicon(&model.tabs[model.active], fx);
            model.removeTab(model.active);
        },
        // A new tab has no URL, so no webview pane exists yet.
        .new_tab => openTab(model, ""),
        .reopen_tab => {
            if (model.closed_count == 0) return;
            model.closed_count -= 1;
            const len = model.closed_lens[model.closed_count];
            var url_buffer: [max_url_bytes]u8 = undefined;
            @memcpy(url_buffer[0..len], model.closed_storage[model.closed_count][0..len]);
            openTab(model, url_buffer[0..len]);
        },
        .close_tab => |index| {
            if (index >= model.tab_count) return;
            model.rememberClosed(&model.tabs[index]);
            dropFavicon(&model.tabs[index], fx);
            model.removeTab(index);
        },
        .select_tab => |index| {
            if (index >= model.tab_count) return;
            model.address_focus_requested = false;
            model.active = index;
            model.syncAddress();
        },
        .focus_address => model.address_focus_requested = true,
        .zoom_in => if (model.activeTab()) |tab| {
            tab.zoom = @min(tab.zoom + 0.25, 5.0);
        },
        .zoom_out => if (model.activeTab()) |tab| {
            tab.zoom = @max(tab.zoom - 0.25, 0.25);
        },
        .zoom_reset => if (model.activeTab()) |tab| {
            tab.zoom = 1.0;
        },
        .copy_url => if (model.activeTab()) |tab| {
            if (tab.url_len > 0) fx.writeClipboard(.{ .key = 1, .text = tab.url() });
        },
        .find_toggle => {
            model.find_open = !model.find_open;
            if (!model.find_open) model.find.clear();
        },
        .find_edit => |edit| model.find.apply(edit),
        .find_next => {
            if (!model.find_open) return;
            model.find_forward_token +%= 1;
        },
        .find_prev => {
            if (!model.find_open) return;
            model.find_backward_token +%= 1;
        },
        .dismiss => {
            model.find_open = false;
            model.find.clear();
        },
        // Event slices live for one dispatch; copy what the model keeps.
        .load_progress => |load| {
            const tab = model.findTab(load.label) orelse return;
            // 1.0 means the engine finished, so clear it and the bar hides.
            tab.progress = if (load.progress >= 0.999) 0 else load.progress;
        },
        .nav => |nav| {
            const tab = model.findTab(nav.label) orelse return;
            tab.setUrl(nav.url);
            tab.can_go_back = nav.can_go_back;
            tab.can_go_forward = nav.can_go_forward;
            if (model.activeTab() == tab) model.address.set(tab.url());
            ensureFavicon(model, tab, fx);
        },
        .popup_opened => |popup| {
            const tab = model.appendTab() orelse return;
            tab.setLabel(popup.popup_label);
            tab.setUrl(popup.url);
            tab.is_popup = true;
            model.active = model.tab_count - 1;
            model.syncAddress();
        },
        .popup_closed => |closed| {
            for (model.tabs[0..model.tab_count], 0..) |*tab, index| {
                if (std.mem.eql(u8, tab.label(), closed.popup_label)) {
                    dropFavicon(tab, fx);
                    model.removeTab(index);
                    return;
                }
            }
        },
        // Exists so newly registered pixels trigger a rebuild; a miss
        // just draws no icon.
        .favicon_loaded => {},
    }
}

// panes

const MiniApp = native_sdk.UiApp(Model, Msg);

fn webPanes(model: *const Model, out: []MiniApp.WebViewPane) usize {
    const count = @min(model.tab_count, out.len);
    for (model.tabs[0..count], 0..) |*tab, index| {
        out[index] = .{
            .label = tab.label(),
            .anchor = page_anchor,
            .owned = true,
            .allows_popups = true,
            // An empty url never navigates, so an adopted SSO popup
            // keeps its own redirect chain.
            .url = tab.pendingUrl(),
            .reload_token = tab.reload_token,
            .back_token = tab.back_token,
            .forward_token = tab.forward_token,
            // 1, not 0. The canvas sits at zPosition 0, so a webview
            // back at 0 ties with it and loses to subview order, which
            // backgrounding inverted, hiding the page behind the canvas.
            .layer = if (index == model.active) 1 else -1,
            .zoom = tab.zoom,
            .find_query = if (index == model.active and model.find_open) model.find.text() else "",
            .find_forward_token = model.find_forward_token,
            .find_backward_token = model.find_backward_token,
        };
    }
    return count;
}

/// Shortcut id for focus mode, primary+shift+F in app.zon.
pub const cmd_toggle_focus = "mini.toggle-focus";
/// Shortcut id for a new tab, primary+T in app.zon.
pub const cmd_new_tab = "mini.new-tab";
/// Shortcut id for closing a tab, primary+W in app.zon.
pub const cmd_close_tab = "mini.close-tab";
/// Shortcut id for reopening a tab, primary+shift+T in app.zon.
pub const cmd_reopen_tab = "mini.reopen-tab";

/// Whether to hide the traffic lights, which focus mode does.
pub fn windowButtonsHidden(model: *const Model) bool {
    return model.focus;
}

/// Map a shortcut id from app.zon to its message. An unknown id is
/// null, which the host drops.
pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, cmd_toggle_focus)) return .toggle_focus;
    if (std.mem.eql(u8, name, cmd_new_tab)) return .new_tab;
    if (std.mem.eql(u8, name, cmd_close_tab)) return .close_active_tab;
    if (std.mem.eql(u8, name, cmd_reopen_tab)) return .reopen_tab;
    if (std.mem.eql(u8, name, "mini.focus-address")) return .focus_address;
    if (std.mem.eql(u8, name, "mini.zoom-in")) return .zoom_in;
    if (std.mem.eql(u8, name, "mini.zoom-out")) return .zoom_out;
    if (std.mem.eql(u8, name, "mini.zoom-reset")) return .zoom_reset;
    if (std.mem.eql(u8, name, "mini.copy-url")) return .copy_url;
    if (std.mem.eql(u8, name, "mini.find")) return .find_toggle;
    if (std.mem.eql(u8, name, "mini.find-next")) return .find_next;
    if (std.mem.eql(u8, name, "mini.find-prev")) return .find_prev;
    if (std.mem.eql(u8, name, "mini.dismiss")) return .dismiss;
    if (std.mem.eql(u8, name, "mini.reload")) return .reload;
    if (std.mem.eql(u8, name, "mini.back")) return .back;
    if (std.mem.eql(u8, name, "mini.forward")) return .forward;
    // mini.tab-1..9 -> select_tab 0..8; out-of-range is already a no-op.
    if (std.mem.startsWith(u8, name, "mini.tab-") and name.len == "mini.tab-".len + 1) {
        const digit = name[name.len - 1];
        if (digit >= '1' and digit <= '9') return .{ .select_tab = digit - '1' };
    }
    return null;
}

test command {
    try std.testing.expectEqual(Msg.back, command("mini.back").?);
    try std.testing.expectEqual(Msg.forward, command("mini.forward").?);
    try std.testing.expectEqual(@as(usize, 0), command("mini.tab-1").?.select_tab);
    try std.testing.expectEqual(@as(usize, 8), command("mini.tab-9").?.select_tab);
    try std.testing.expectEqual(@as(?Msg, null), command("mini.tab-0"));
    try std.testing.expectEqual(@as(?Msg, null), command("mini.tab-10"));
    try std.testing.expectEqual(@as(?Msg, null), command("mini.unknown"));
}

fn mapNavigation(nav: platform.WebViewNavigationEvent) ?Msg {
    if (nav.phase != .committed) return null;
    return .{ .nav = nav };
}

fn mapPopup(popup: platform.WebViewPopupEvent) ?Msg {
    return .{ .popup_opened = popup };
}

fn mapPopupClosed(closed: platform.WebViewPopupClosedEvent) ?Msg {
    return .{ .popup_closed = closed };
}

fn mapLoadProgress(load: platform.WebViewLoadProgressEvent) ?Msg {
    return .{ .load_progress = load };
}

// view

/// The canvas UI bound to Mini's messages.
pub const AppUi = canvas.Ui(Msg);
/// The markup, embedded for release and re-read from disk in dev.
pub const app_markup = @embedFile("app.native");

// app

/// A model holding one blank tab, which is what startup shows.
pub fn initialModel() Model {
    var model: Model = .{};
    openTab(&model, "");
    return model;
}

/// Build the app, hand it the initial model, and run until it quits.
pub fn main(init: std.process.Init) !void {
    const app_state = try MiniApp.create(std.heap.page_allocator, .{
        .name = "mini",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .theme_accent = runner.manifestThemeAccent(),
        .update_fx = update,
        .web_panes = webPanes,
        .on_command = command,
        .window_buttons_hidden_fn = windowButtonsHidden,
        .on_web_pane_navigation = mapNavigation,
        .on_web_pane_popup = mapPopup,
        .on_web_pane_popup_closed = mapPopupClosed,
        .on_web_pane_load_progress = mapLoadProgress,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "mini",
        .window_title = "Mini",
        .bundle_id = "dev.native_sdk.mini",
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{"*"} },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
