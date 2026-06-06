# ClaudeUsageBar

ClaudeUsageBar shows the Claude.ai 5-hour usage limit in the macOS menu bar. It
has two parts: a native Swift menu bar app and a browser extension. The extension
reads the usage figure from your own logged-in claude.ai page and relays it to the
app over localhost. The app renders it in the menu bar.

## Disclaimer

This is an unofficial project. It is not affiliated with, endorsed by, or supported
by Anthropic.

The extension reads your own usage figure from your own logged-in claude.ai session,
entirely client side, and sends it only to `http://127.0.0.1:8787` on your own
machine. Nothing is sent anywhere else.

The figure is scraped from undocumented page markup. Anthropic can change that markup
at any time, which will stop the scraping until the matchers are updated. See "When
it stops scraping" below.

You are responsible for reviewing Anthropic's terms before using this tool.

## Install

### 1. Build and run the menu bar app

```
./build.sh
open build/ClaudeUsageBar.app
```

The app appears in the menu bar with no Dock icon. It starts showing `Claude --`
until the extension sends data. If no data arrives for ten minutes it shows
`Claude (stale)`.

The default bundle identifier is `com.claudeusagebar.app`. You can change it in
`build.sh` if you prefer your own.

### 2. Load the browser extension

The extension works in Chromium based browsers (Chrome, Edge, Brave, Arc).

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Click "Load unpacked" and select the `Extension` folder.
4. Open or reload `https://claude.ai`.

With both parts running, the menu bar updates as your usage figure changes on the
page.

## When it stops scraping

The extension does not rely on class names, because those change often. It scans the
page text against an ordered list of regular expressions in the `CONFIG` object at the
top of `Extension/content.js`.

If the menu bar stops updating:

1. Open claude.ai and inspect the element that shows your usage.
2. Note the exact wording, for example "12 messages left" or "80% of your usage".
3. Edit the `matchers` array in `Extension/content.js` so a regex matches that
   wording, or update the `resetRegex` for the reset time.
4. Reload the extension at `chrome://extensions` and reload claude.ai.

## Safari

Safari does not support loading unpacked extensions the way Chromium browsers do. To
run this in Safari you must convert it with Xcode's `safari-web-extension-converter`
and build the resulting project. That path is not covered here.

## Architecture

```
claude.ai page  ->  content.js  ->  background.js  ->  127.0.0.1:8787  ->  Swift app
   (DOM text)       (scrape)        (relay POST)        (loopback)         (menu bar)
```

- `content.js` scrapes the usage figure from the page text and deduplicates.
- `background.js` POSTs the payload as JSON to the local app.
- The Swift app runs a minimal HTTP server bound to `127.0.0.1:8787` only and renders
  the latest figure in the menu bar.

## Security

The local server is intended only for the companion extension. It applies several
guards:

- It binds to `127.0.0.1:8787` only and is never reachable off the loopback
  interface.
- CORS is locked to the `https://claude.ai` origin, so other web pages cannot drive
  it from a browser.
- It rejects requests whose `Host` header is not `127.0.0.1:8787` or
  `localhost:8787`, which blocks DNS rebinding.
- It rejects negative or oversized `Content-Length` and caps the request body at
  64 KiB.
- The `label`, `detail`, and `reset` fields are treated as untrusted: control
  characters are stripped and length is capped before they reach the menu bar.
