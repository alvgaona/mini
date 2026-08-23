const std = @import("std");
const mini = @import("main.zig");

fn testFx() mini.Effects {
    return mini.Effects.init(std.testing.allocator);
}

test "normalizeUrl prefixes a bare host" {
    var out: [mini.max_url_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com", mini.normalizeUrl("example.com", &out));
    try std.testing.expectEqualStrings("https://example.com/a?b=c", mini.normalizeUrl("  example.com/a?b=c\n", &out));
}

test "normalizeUrl passes an explicit scheme through" {
    var out: [mini.max_url_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("http://localhost:5173", mini.normalizeUrl("http://localhost:5173", &out));
    try std.testing.expectEqualStrings("about:blank", mini.normalizeUrl("about:blank", &out));
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
    // With no tabs left the same chord asks the app to quit - the
    // fake executor absorbs the effect, the model stays untouched.
    mini.update(&model, close, &fx);
    try std.testing.expectEqual(@as(usize, 0), model.tab_count);

    const open = mini.command(mini.cmd_new_tab) orelse return error.TestUnexpectedResult;
    mini.update(&model, open, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.tab_count);
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
    try std.testing.expectEqual(@as(?mini.Msg, null), mini.command("mini.unknown"));
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

    // The pane a popup tab declares never navigates it: no pending url.
    try std.testing.expectEqual(@as(usize, 0), model.tabs[1].pending_len);

    mini.update(&model, .{ .popup_closed = .{ .popup_label = "__popup_1" } }, &fx);
    try std.testing.expectEqual(@as(usize, 1), model.tab_count);
}
