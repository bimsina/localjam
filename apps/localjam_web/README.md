# localjam_web

The browser listener page (docs/design/WEB_GUEST.md, PROTOCOL.md §1.1). The
host serves it at `/join` and its files under `/web/`; a phone camera opens
the http join URL and the page joins as a `clientKind: "web"` guest, with no
install and no internet.

## Build

```sh
tool/build.sh          # what the host should bundle (17 MB)
```

which is

```sh
flutter build web --release --base-href /web/ --no-web-resources-cdn --pwa-strategy none
```

plus two scrubs and a prune: the CanvasKit-CDN and font-CDN defaults that
Flutter's loader and engine still carry (unused by this build) are replaced
by same-origin paths, the renderers a dart2js build never loads (`skwasm*`,
`wimp*`, `webparagraph/`) and the `*.symbols` files are removed, and the
script fails if anything still names `gstatic` or `googleapis`. The plain
`flutter build web` output (40 MB) works too; it just carries those strings
and the unused files.

- `--base-href /web/`: `index.html` is served at `/join`, the bundle at `/web/…`.
- `--no-web-resources-cdn`: CanvasKit comes from the host, not a CDN.
- Fonts (Manrope, the icon fonts) are bundled and the theme names its family,
  so the engine never downloads a default font. `web/flutter_bootstrap.js`
  points the engine's glyph fallback at the page's own origin as well.

`tool/build.sh` relies on two exact strings in Flutter's output (the CDN URLs it
scrubs) and on `preferWebParagraph` staying opt-in (it deletes
`canvaskit/webparagraph/`); its header says what, and it fails loudly if
either assumption breaks.

### Fonts

Manrope has Latin only. Song titles and guest names are often Nepali, so the
page bundles **Noto Sans Devanagari** (regular and bold, ~270 KB, SIL OFL 1.1,
`assets/fonts/NotoSansDevanagari-OFL.txt`) as the theme's
`fontFamilyFallback`: Devanagari draws from the bundle, with no request.
Other scripts Manrope lacks (CJK, Arabic, Thai, …) are **not** bundled — a CJK
face alone is several MB. For those the engine asks the page's own origin for
its Noto fallback fonts (`assets/font-fallback/…`), which the host does not
serve: each font is tried once, the 404 is permanent for the session (the
engine gives up on a script after a few fonts, and on fallback altogether
after 10 failures), and the glyphs draw as boxes. Never an off-origin request.

What a browser loads: `index.html`, `flutter_bootstrap.js`, `main.dart.js`,
`canvaskit/canvaskit.{js,wasm}` (or `canvaskit/chromium/…` in Chrome on a
secure origin such as localhost), the fonts under `assets/` (Flutter's own
bundled Roboto fallback included), `favicon.png`.

## Serve and check

```sh
dart run ../localjam_cli/bin/localjam.dart host --web-dir build/web song.mp3 …
dart run tool/browser_check.dart --listen 'http://<lan-ip>:<port>/join#v=1&token=…'
```

`tool/browser_check.dart` drives headless Chrome over the DevTools protocol:
it lists every request (and fails if one left the origin), checks the token
left the address bar (the page keeps the invitation in the tab's
`sessionStorage` and drops the fragment with `history.replaceState`, so the
token is not in the browser's history) and that a reload still finds it,
clicks "Tap to Listen" as a real input event and prints what the page says as
the jam goes on.

## Tests

```sh
flutter test                       # the page's states against a faked room
```

The guest engine's browser test (join a real host, fetch, decode-gated
`ready`, play at the anchor) lives in `packages/localjam_client`
(`tool/web_engine_test.sh`).
