//! Behavior tests for the model and `update`. The doctests attached to
//! `normalizeUrl` and `command` live beside them in main.zig.

const std = @import("std");
const mini = @import("main.zig");

fn testFx() mini.Effects {
    return mini.Effects.init(std.testing.allocator);
}

test "tabs open blank and the address bar wants focus" {
    var fx = testFx();
    defer fx.deinit();
    var model = mini.initialModel();
    // No URL means no webview pane, and the address bar takes the cursor.
    try std.testing.expectEqual(@as(usize, 0), model.tabs[0].url_len);
    try std.testing.expect(model.addressWantsFocus());

    model.address.set("example.com");
    mini.update(&model, .navigate, &fx);
    try std.testing.expectEqualStrings("https://example.com", model.tabs[0].pendingUrl());
    try std.testing.expect(!model.addressWantsFocus());

    mini.update(&model, .new_tab, &fx);
    model.address.clear();
    mini.update(&model, .navigate, &fx);
    try std.testing.expectEqual(@as(usize, 0), model.tabs[1].pending_len);
    try std.testing.expect(model.addressWantsFocus());
}

test "tabs open, select, and close with unique labels" {
    var fx = testFx();
    defer fx.deinit();
    var model = mini.initialModel();
    try std.testing.expectEqual(@as(usize, 1), model.tab_count);

    mini.update(&model, .new_tab, &fx);
    mini.update(&model, .new_tab, &fx);
    try std.testing.expectEqual(@as(usize, 3), model.tab_count);
    try std.testing.expectEqual(@as(usize, 2), model.active);
    try std.testing.expect(!std.mem.eql(u8, model.tabs[0].label(), model.tabs[1].label()));

    // Closing the first shifts the rest; labels never recycle.
    const second_label_before = model.tabs[1].label_len;
    mini.update(&model, .{ .close_tab = 0 }, &fx);
    try std.testing.expectEqual(@as(usize, 2), model.tab_count);
    try std.testing.expectEqual(second_label_before, model.tabs[0].label_len);
    mini.update(&model, .new_tab, &fx);
    try std.testing.expect(!std.mem.eql(u8, model.tabs[2].label(), model.tabs[0].label()));
}

test "navigate targets the active tab and history tokens bump" {
    var fx = testFx();
    defer fx.deinit();
    var model = mini.initialModel();
    model.address.set("vercel.com");
    mini.update(&model, .navigate, &fx);
    try std.testing.expectEqualStrings("https://vercel.com", model.tabs[0].pendingUrl());
    try std.testing.expectEqualStrings("https://vercel.com", model.addressText());

    const back_before = model.tabs[0].back_token;
    mini.update(&model, .back, &fx);
    try std.testing.expect(model.tabs[0].back_token != back_before);
}

test "navigation reports update the tab and the address bar" {
    var fx = testFx();
    defer fx.deinit();
    var model = mini.initialModel();
    const label = model.tabs[0].label();
    mini.update(&model, .{ .nav = .{
        .label = label,
        .url = "https://example.com/deep",
        .can_go_back = true,
        .can_go_forward = false,
    } }, &fx);
    try std.testing.expectEqualStrings("https://example.com/deep", model.tabs[0].url());
    try std.testing.expect(model.tabs[0].can_go_back);
    try std.testing.expect(model.backDisabled() == false);
    try std.testing.expectEqualStrings("https://example.com/deep", model.addressText());
}

test "cmd+w closes the active tab, then the app" {
    var fx = testFx();
    defer fx.deinit();
    fx.executor = .fake;
    var model = mini.initialModel();
    mini.update(&model, .new_tab, &fx);
    try std.testing.expectEqual(@as(usize, 2), model.tab_count);

    const close = mini.command(mini.cmd_close_tab) orelse return error.TestUnexpectedResult;
    mini.update(&model, close, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.tab_count);
    mini.update(&model, close, &fx);
    try std.testing.expectEqual(@as(usize, 0), model.tab_count);
    // With no tabs left the chord quits the app; the fake executor
    // absorbs the effect.
    mini.update(&model, close, &fx);
    try std.testing.expectEqual(@as(usize, 0), model.tab_count);

    const open = mini.command(mini.cmd_new_tab) orelse return error.TestUnexpectedResult;
    mini.update(&model, open, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.tab_count);
}

test "cmd+shift+t reopens closed tabs, newest first, session only" {
    var fx = testFx();
    defer fx.deinit();
    fx.executor = .fake;
    var model = mini.initialModel();
    model.address.set("example.com");
    mini.update(&model, .navigate, &fx);
    mini.update(&model, .new_tab, &fx);
    model.address.set("rewire.run");
    mini.update(&model, .navigate, &fx);

    const close = mini.command(mini.cmd_close_tab) orelse return error.TestUnexpectedResult;
    mini.update(&model, close, &fx); // closes rewire.run
    mini.update(&model, close, &fx); // closes example.com
    try std.testing.expectEqual(@as(usize, 0), model.tab_count);

    const reopen = mini.command(mini.cmd_reopen_tab) orelse return error.TestUnexpectedResult;
    mini.update(&model, reopen, &fx);
    try std.testing.expectEqualStrings("https://example.com", model.tabs[0].pendingUrl());
    mini.update(&model, reopen, &fx);
    try std.testing.expectEqualStrings("https://rewire.run", model.tabs[1].pendingUrl());

    // A closed blank tab never pushed, so reopen has nothing left.
    mini.update(&model, reopen, &fx);
    try std.testing.expectEqual(@as(usize, 2), model.tab_count);
    mini.update(&model, .new_tab, &fx);
    mini.update(&model, close, &fx);
    mini.update(&model, reopen, &fx);
    try std.testing.expectEqual(@as(usize, 2), model.tab_count);
}

test "zoom clamps per tab and find tokens bump only while open" {
    var fx = testFx();
    defer fx.deinit();
    fx.executor = .fake;
    var model = mini.initialModel();
    mini.update(&model, .zoom_out, &fx);
    mini.update(&model, .zoom_out, &fx);
    mini.update(&model, .zoom_out, &fx);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), model.tabs[0].zoom, 0.001);
    mini.update(&model, .zoom_reset, &fx);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), model.tabs[0].zoom, 0.001);

    // find_next outside an open find bar is inert; inside it bumps.
    const token_before = model.find_forward_token;
    mini.update(&model, .find_next, &fx);
    try std.testing.expectEqual(token_before, model.find_forward_token);
    mini.update(&model, .find_toggle, &fx);
    mini.update(&model, .find_next, &fx);
    try std.testing.expectEqual(token_before + 1, model.find_forward_token);
    mini.update(&model, .dismiss, &fx);
    try std.testing.expect(!model.findOpen());
    try std.testing.expectEqual(@as(usize, 0), model.find.text().len);

    mini.update(&model, .focus_address, &fx);
    try std.testing.expect(model.addressWantsFocus());
}

test "load progress follows the active tab and clears at done" {
    var fx = testFx();
    defer fx.deinit();
    var model = mini.initialModel();
    const label = model.tabs[0].label();
    try std.testing.expect(!model.loading());
    mini.update(&model, .{ .load_progress = .{ .label = label, .progress = 0.4 } }, &fx);
    try std.testing.expect(model.loading());
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), model.loadProgress(), 0.001);
    mini.update(&model, .{ .load_progress = .{ .label = label, .progress = 1.0 } }, &fx);
    try std.testing.expect(!model.loading());

    // A background tab's load never shows on the active tab's bar.
    mini.update(&model, .new_tab, &fx);
    mini.update(&model, .{ .load_progress = .{ .label = label, .progress = 0.5 } }, &fx);
    try std.testing.expect(!model.loading());
}

test "focus mode toggles through the shortcut command" {
    var fx = testFx();
    defer fx.deinit();
    var model = mini.initialModel();
    try std.testing.expect(model.chromeVisible());
    const msg = mini.command(mini.cmd_toggle_focus) orelse return error.TestUnexpectedResult;
    mini.update(&model, msg, &fx);
    try std.testing.expect(!model.chromeVisible());
    mini.update(&model, msg, &fx);
    try std.testing.expect(model.chromeVisible());
}

test "popups adopt as tabs with an empty pane url and drop on close" {
    var fx = testFx();
    defer fx.deinit();
    var model = mini.initialModel();
    mini.update(&model, .{ .popup_opened = .{
        .opener_label = model.tabs[0].label(),
        .popup_label = "__popup_1",
        .url = "https://idp.example.com/auth",
    } }, &fx);
    try std.testing.expectEqual(@as(usize, 2), model.tab_count);
    try std.testing.expect(model.tabs[1].is_popup);
    try std.testing.expectEqualStrings("__popup_1", model.tabs[1].label());

    // The pane a popup tab declares never navigates it, so no pending url.
    try std.testing.expectEqual(@as(usize, 0), model.tabs[1].pending_len);

    mini.update(&model, .{ .popup_closed = .{ .popup_label = "__popup_1" } }, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.tab_count);
}
