# Mini

A personal web browser: tabs, real history, SSO popups — and no profile you have to clean up before a
screen share. Native chrome drawn on a Metal canvas; every tab is a webview pane the model declares.

Built on [vercel-labs/native](https://github.com/vercel-labs/native) — specifically the fork at
`~/git/native`, which carries the three webview features Mini needs (upstream PRs pending):

- **Navigation events to the Zig core** — every main-frame navigation (link clicks and redirects
  included) reaches `update` with the engine's URL and `canGoBack`/`canGoForward`, which is what keeps
  the address bar and history buttons honest.
- **Engine-native back/forward** — `back_token`/`forward_token` bumps drive WKWebView's own history, so
  scroll and form state survive, unlike a URL re-navigation.
- **Owned panes + `window.open` popups** — tabs are owned panes (presence creates, absence removes, up
  to 16, stacked by `layer`); a popup is created by the host from WebKit's handed configuration
  (preserving `window.opener`, which SSO needs), adopted as a tab with an EMPTY pane URL so its redirect
  chain is never disturbed, and dropped when the page calls `window.close`.

## Shape

- `app.zon` — the window and the `main-canvas` gpu_surface; tabs are model-created, nothing is
  scene-declared.
- `src/main.zig` — `Model` (16 `Tab` slots with per-tab URL/pending/tokens/history flags, address
  buffer), `update`, `webPanes` (one owned pane per tab, active at layer 0, background at −1), and the
  three event mappers.
- `src/app.native` — back/forward/reload + address bar, the tab strip, and the `page-pane` panel every
  tab anchors to.
- `src/tests.zig` — 7 tests: URL normalization, tab lifecycle with never-recycled labels, history
  tokens, navigation reports, popup adopt/drop.

Navigation policy is `"*"` — a browser's whole job — and stays safe because no pane ever gets
`bridge: true` and `js_window_api` is off: `window.zero` never reaches a loaded site.

## Build and run

The fork is required. `NATIVE_SDK_PATH` points the CLI's generated build at it and survives
regeneration:

```sh
NATIVE_SDK_PATH=~/git/native native test
NATIVE_SDK_PATH=~/git/native native dev -Dweb-engine=system
NATIVE_SDK_PATH=~/git/native native build -Dweb-engine=system
```

Add `-Dautomation=true` to drive the running app with the fork's `native automate` (the installed CLI
speaks an older automation protocol; use the fork-built binary from its `.zig-cache`).

## Chromium

`app.zon` still asks for Chromium (`.web_engine = "chromium"`): the CEF host builds its runtime via
`native cef install --source official --allow-build-tools`, but `cef_host.mm` does not compile against
the macOS 26.5 SDK (deprecation floods promoted to errors plus a `CGToneMapping` availability error —
upstream fix needed), and the CEF host has neither navigation events nor popups yet. Until then:
`-Dweb-engine=system` on every command, as above.

## Not built yet

Find-in-page, search-from-address-bar (addresses only), per-tab favicons/titles (tab titles are the
page host), and session restore for tabs.
