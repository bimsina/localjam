# localjam_web

The browser listener page (docs/design/WEB_GUEST.md, PROTOCOL.md §1.1). The
host serves it at `/join` and its files under `/web/`; a phone camera opens
the http join URL and the page joins as a `clientKind: "web"` guest, with no
install and no internet.

## Build

```sh
flutter build web --release --base-href /web/ --no-web-resources-cdn --pwa-strategy none
```

- `--base-href /web/`: `index.html` is served at `/join`, the bundle at `/web/…`.
- `--no-web-resources-cdn`: CanvasKit comes from the host, not a CDN.
- Fonts (Manrope, the icon fonts) are bundled and the theme names its family,
  so the engine never downloads a default font. `web/flutter_bootstrap.js`
  points the engine's glyph fallback at the page's own origin as well.

What a browser loads: `index.html`, `flutter_bootstrap.js`, `main.dart.js`,
`canvaskit/canvaskit.{js,wasm}` (or `canvaskit/chromium/…` in Chrome on a
secure origin), the fonts under `assets/`, `favicon.png`. The `skwasm*`,
`wimp*`, `webparagraph/` and `*.symbols` files are only for `--wasm` builds
and debugging; a packager may leave them out.

## Serve and check

```sh
dart run ../localjam_cli/bin/localjam.dart host --web-dir build/web song.mp3 …
dart run tool/browser_check.dart --listen 'http://<lan-ip>:<port>/join#v=1&token=…'
```

`tool/browser_check.dart` drives headless Chrome over the DevTools protocol:
it lists every request (and fails if one left the origin), checks the
address bar still holds the invitation, clicks "Tap to Listen" as a real
input event and prints what the page says as the jam goes on.

## Tests

```sh
flutter test                       # the page's states against a faked room
```

The guest engine's browser test (join a real host, fetch, decode-gated
`ready`, play at the anchor) lives in `packages/localjam_client`
(`tool/web_engine_test.sh`).
