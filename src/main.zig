//! Mini: a personal browser. Native chrome on a Metal canvas; each tab
//! is an owned webview pane the model declares, with engine history and
//! window.open popups (SSO) adopted as tabs.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

const canvas_label = "main-canvas";
const page_anchor = "page-pane";
pub const max_url_bytes = 2048;
pub const max_tabs = 16;
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

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    address_edit: canvas.TextInputEvent,
    navigate,
    back,
    forward,
    reload,
    new_tab,
    close_tab: usize,
    select_tab: usize,
    toggle_focus,
    close_active_tab,
    nav: platform.WebViewNavigationEvent,
    popup_opened: platform.WebViewPopupEvent,
    popup_closed: platform.WebViewPopupClosedEvent,
    favicon_loaded: native_sdk.EffectImageResult,

    pub const view_unbound = .{ "nav", "popup_opened", "popup_closed", "toggle_focus", "close_active_tab", "favicon_loaded" };
};

pub const Tab = struct {
    label_storage: [max_label_bytes]u8 = undefined,
    label_len: usize = 0,
    url_storage: [max_url_bytes]u8 = undefined,
    url_len: usize = 0,
    pending_storage: [max_url_bytes]u8 = undefined,
    pending_len: usize = 0,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    back_token: u64 = 0,
    forward_token: u64 = 0,
    reload_token: u64 = 0,
    is_popup: bool = false,
    /// Registered favicon ImageId; 0 draws nothing while loading or on
    /// a miss. Keyed to the host so in-site navigation never refetches.
    favicon_id: u64 = 0,
    favicon_host_storage: [max_host_bytes]u8 = undefined,
    favicon_host_len: usize = 0,

    pub fn label(tab: *const Tab) []const u8 {
        return tab.label_storage[0..tab.label_len];
    }

    pub fn url(tab: *const Tab) []const u8 {
        return tab.url_storage[0..tab.url_len];
    }

    pub fn pendingUrl(tab: *const Tab) []const u8 {
        return tab.pending_storage[0..tab.pending_len];
    }

    fn setLabel(tab: *Tab, value: []const u8) void {
        const len = @min(value.len, tab.label_storage.len);
        @memcpy(tab.label_storage[0..len], value[0..len]);
        tab.label_len = len;
    }

    fn setUrl(tab: *Tab, value: []const u8) void {
        const len = @min(value.len, tab.url_storage.len);
        @memcpy(tab.url_storage[0..len], value[0..len]);
        tab.url_len = len;
    }

    fn setPending(tab: *Tab, value: []const u8) void {
        const len = @min(value.len, tab.pending_storage.len);
        @memcpy(tab.pending_storage[0..len], value[0..len]);
        tab.pending_len = len;
    }
};

pub const TabRow = struct {
    index: usize,
    title: []const u8,
    active: bool,
    favicon: u64,
};

pub const Model = struct {
    tabs: [max_tabs]Tab = undefined,
    tab_count: usize = 0,
    active: usize = 0,
    /// Monotonic label serial: closed labels are never reused, so a
    /// close and a create in the same frame can never alias.
    tab_serial: u64 = 0,
    /// Monotonic favicon ImageId (0 is the no-image sentinel): fresh
    /// content never re-keys a live id.
    favicon_serial: u64 = 1,
    address: canvas.TextBuffer(max_url_bytes) = .{},
    /// Focus mode hides all chrome; the pane anchor grows to the whole
    /// window and every tab re-snaps to it on the next frame.
    focus: bool = false,

    /// Markup binds `tabRows`/`addressText` and the two disabled fns;
    /// the backing stores and selection bookkeeping are update-only.
    pub const view_unbound = .{ "tabs", "address", "tab_serial", "favicon_serial", "tab_count", "active", "focus" };

    pub fn addressText(model: *const Model) []const u8 {
        return model.address.text();
    }

    pub fn chromeVisible(model: *const Model) bool {
        return !model.focus;
    }

    /// Edge-triggered by the markup's autofocus: turns true when the
    /// active tab is blank (startup, cmd+T), so the cursor lands in the
    /// address bar ready to type.
    pub fn addressWantsFocus(model: *const Model) bool {
        if (model.tab_count == 0) return true;
        const tab = &model.tabs[model.active];
        return tab.url_len == 0 and tab.pending_len == 0;
    }

    pub fn backDisabled(model: *const Model) bool {
        if (model.tab_count == 0) return true;
        return !model.tabs[model.active].can_go_back;
    }

    pub fn forwardDisabled(model: *const Model) bool {
        if (model.tab_count == 0) return true;
        return !model.tabs[model.active].can_go_forward;
    }

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

    fn removeTab(model: *Model, index: usize) void {
        if (index >= model.tab_count) return;
        var cursor = index;
        while (cursor + 1 < model.tab_count) : (cursor += 1) {
            model.tabs[cursor] = model.tabs[cursor + 1];
        }
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

/// Load the tab's favicon when its host changes: the site's own
/// /favicon.ico through the one-call image cascade (fetch, platform
/// decode - CGImageSource reads .ico - register, cache). A miss leaves
/// id 0 and the row simply shows no icon; no third-party icon service.
/// ponytail: 16 image slots total, so a full window of distinct hosts
/// fills the registry and later tabs go iconless - raise
/// app.zon .images if that ever matters.
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
    const after_scheme = if (std.mem.indexOf(u8, full, "://")) |at| full[at + 3 ..] else full;
    const end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    return after_scheme[0..end];
}

pub const Effects = native_sdk.Effects(Msg);

/// `example.com` is an address, not a search term: Mini prefixes a
/// scheme and navigates. Anything already carrying one passes through.
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

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .address_edit => |edit| model.address.apply(edit),
        .navigate => {
            const tab = model.activeTab() orelse return;
            var scratch: [max_url_bytes]u8 = undefined;
            const url = normalizeUrl(model.address.text(), &scratch);
            if (url.len == 0) return;
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
        // Tabs absorb Cmd+W; the app itself only goes when none remain.
        .close_active_tab => {
            if (model.tab_count == 0) {
                fx.quitApp();
                return;
            }
            dropFavicon(&model.tabs[model.active], fx);
            model.removeTab(model.active);
        },
        // A new tab is nothing at all - no webview until an address is
        // typed; the empty pane URL never creates.
        .new_tab => openTab(model, ""),
        .close_tab => |index| {
            if (index < model.tab_count) dropFavicon(&model.tabs[index], fx);
            model.removeTab(index);
        },
        .select_tab => |index| {
            if (index >= model.tab_count) return;
            model.active = index;
            model.syncAddress();
        },
        // Event slices are borrowed for this dispatch: copy everything
        // the model keeps.
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
        // The Msg exists so the loaded pixels trigger a rebuild; a miss
        // or failure leaves the id skipped at draw, which renders as no
        // icon - nothing to clear.
        // The Msg exists so freshly registered pixels trigger a rebuild;
        // a miss leaves the id skipped at draw - no icon, nothing to
        // clear.
        .favicon_loaded => {},
    }
}

// ------------------------------------------------------------------ panes

const MiniApp = native_sdk.UiApp(Model, Msg);

fn webPanes(model: *const Model, out: []MiniApp.WebViewPane) usize {
    const count = @min(model.tab_count, out.len);
    for (model.tabs[0..count], 0..) |*tab, index| {
        out[index] = .{
            .label = tab.label(),
            .anchor = page_anchor,
            .owned = true,
            .allows_popups = true,
            // The popup adoption contract: an empty url never navigates,
            // so an adopted SSO popup keeps its own redirect chain. A
            // popup the user explicitly navigates gets a pending url and
            // behaves like any tab from then on.
            .url = tab.pendingUrl(),
            .reload_token = tab.reload_token,
            .back_token = tab.back_token,
            .forward_token = tab.forward_token,
            .layer = if (index == model.active) 0 else -1,
        };
    }
    return count;
}

pub const cmd_toggle_focus = "mini.toggle-focus"; // primary+shift+F
pub const cmd_new_tab = "mini.new-tab"; // primary+T
pub const cmd_close_tab = "mini.close-tab"; // primary+W

pub fn windowButtonsHidden(model: *const Model) bool {
    return model.focus;
}

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, cmd_toggle_focus)) return .toggle_focus;
    if (std.mem.eql(u8, name, cmd_new_tab)) return .new_tab;
    if (std.mem.eql(u8, name, cmd_close_tab)) return .close_active_tab;
    if (std.mem.eql(u8, name, "mini.back")) return .back;
    if (std.mem.eql(u8, name, "mini.forward")) return .forward;
    // mini.tab-1 .. mini.tab-9 -> select_tab 0..8; out-of-range
    // indices are already a select_tab no-op.
    if (std.mem.startsWith(u8, name, "mini.tab-") and name.len == "mini.tab-".len + 1) {
        const digit = name[name.len - 1];
        if (digit >= '1' and digit <= '9') return .{ .select_tab = digit - '1' };
    }
    return null;
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

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

pub fn initialModel() Model {
    var model: Model = .{};
    openTab(&model, "");
    return model;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try MiniApp.create(std.heap.page_allocator, .{
        .name = "mini",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .web_panes = webPanes,
        .on_command = command,
        .window_buttons_hidden_fn = windowButtonsHidden,
        .on_web_pane_navigation = mapNavigation,
        .on_web_pane_popup = mapPopup,
        .on_web_pane_popup_closed = mapPopupClosed,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "mini",
        .window_title = "Mini",
        .bundle_id = "dev.native_sdk.mini",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = true,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{"*"} },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
