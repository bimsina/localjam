#!/bin/sh
# Builds the listener page the way the host serves it (PROTOCOL.md §1.1,
# docs/design/WEB_GUEST.md D8) and checks it can make no off-origin request:
#
#   tool/build.sh [--keep-all]
#
# 1. `flutter build web --release --base-href /web/ --no-web-resources-cdn`
#    into build/web, then deletes flutter_service_worker.js: the page
#    registers no service worker (D8). `--pwa-strategy none` used to empty
#    it; the flag is deprecated with no replacement (flutter/flutter#156910),
#    and without it Flutter writes a worker that only unregisters itself.
#    Nothing registers it: web/flutter_bootstrap.js passes the loader no
#    serviceWorkerSettings. Step 4 checks both.
# 2. Scrubs the two internet defaults Flutter's own code still carries
#    although this build never uses them: the CanvasKit CDN in the loader
#    (unused: the build config says useLocalCanvasKit) and the font-fallback
#    CDN in the engine (unused: web/flutter_bootstrap.js sets
#    fontFallbackBaseUrl to this origin). Both are replaced by same-origin
#    paths, so even a code path we did not foresee cannot reach the
#    internet.
# 3. Unless --keep-all: removes what a dart2js CanvasKit build never loads —
#    the skwasm/wimp renderers (`--wasm` builds only), the webparagraph
#    CanvasKit (opt-in config, see 5), and the *.symbols debug files — about
#    25 MB the host app would otherwise carry in its APK. A browser loads
#    canvaskit/canvaskit.* (Safari, Firefox, Chrome on a plain-http LAN page)
#    or canvaskit/chromium/* (Chrome on a secure origin such as localhost).
# 4. Fails if anything in build/web still names gstatic or googleapis, or
#    if a service worker file or registration is left in the build.
# 5. Fails if the loader or the engine would ever turn `preferWebParagraph`
#    on by default (it would then load canvaskit/webparagraph/, deleted in 3).
#
# What this depends on in Flutter's own output (checked with Flutter 3.50;
# re-check on an upgrade — a change shows up as a failure of 4 or 5, never
# as a silently broken page):
#  * The exact CDN strings scrubbed in 2: `https://fonts.gstatic.com/s/` (the
#    engine's default fontFallbackBaseUrl, in main.dart.js) and
#    `https://www.gstatic.com/flutter-canvaskit` (the loader's CanvasKit
#    base, in flutter.js and flutter_bootstrap.js). If Flutter renames or
#    moves them, the sed matches nothing and step 4 fails on the new spelling.
#  * `preferWebParagraph` staying opt-in. The loader picks the webparagraph
#    CanvasKit only on `…&&config.preferWebParagraph&&…` (minified:
#    `&&e.preferWebParagraph&&`), and the engine reads it as
#    `….preferWebParagraph` then `return s==null?!1:s` (false when unset).
#    Step 5 requires every occurrence in the loader and the engine to have
#    exactly those shapes, at least one occurrence in the loader, and no
#    config (Flutter's build config or web/flutter_bootstrap.js) setting it.
set -e
cd "$(dirname "$0")/.."
flutter build web --release --base-href /web/ --no-web-resources-cdn
out=build/web
rm -f "$out/flutter_service_worker.js"

for file in "$out/main.dart.js" "$out/flutter.js" "$out/flutter_bootstrap.js"; do
  sed -i.bak \
    -e 's#https://fonts\.gstatic\.com/s/#assets/font-fallback/#g' \
    -e 's#https://www\.gstatic\.com/flutter-canvaskit#canvaskit#g' \
    "$file"
  rm -f "$file.bak"
done

if [ "$1" != "--keep-all" ]; then
  rm -rf "$out/canvaskit/webparagraph"
  rm -f "$out"/canvaskit/skwasm* "$out"/canvaskit/wimp*
  find "$out/canvaskit" -name '*.symbols' -delete
  # Source maps are not fetched by a guest, and from Flutter 3.50 the SDK
  # ships flutter.js.map, whose embedded sources name the CanvasKit CDN.
  find "$out" -name '*.js.map' -delete
fi

if grep -rlE 'gstatic|googleapis' "$out"; then
  echo "build.sh: the files above still name an internet host" >&2
  exit 1
fi

# No service worker: none in the output, and neither the page's bootstrap
# nor index.html asks for one (Flutter's loader registers a worker only when
# load() is given serviceWorkerSettings).
if [ -e "$out/flutter_service_worker.js" ] ||
  grep -q 'serviceWorker' web/flutter_bootstrap.js "$out/index.html"; then
  echo "build.sh: the build would register a service worker" >&2
  exit 1
fi

# 5. preferWebParagraph must stay opt-in (see the header).
web_paragraph_fail() {
  echo "build.sh: $1 — preferWebParagraph may now default on, and" \
    "canvaskit/webparagraph/ was deleted; re-check Flutter's loader" >&2
  exit 1
}
count() { grep -oE "$1" "$2" | wc -l | tr -d ' '; }
id='[A-Za-z_$][A-Za-z0-9_$]*'
for file in "$out/flutter.js" "$out/flutter_bootstrap.js"; do
  all=$(count 'preferWebParagraph' "$file")
  opt_in=$(count "&&$id\\.preferWebParagraph&&" "$file")
  [ "$all" -gt 0 ] || web_paragraph_fail "no preferWebParagraph in $file"
  [ "$all" = "$opt_in" ] ||
    web_paragraph_fail "$file reads preferWebParagraph other than as an opt-in"
done
if grep -qE 'preferWebParagraph"?[[:space:]]*:' "$out/flutter_bootstrap.js"; then
  web_paragraph_fail "a config in flutter_bootstrap.js sets preferWebParagraph"
fi
engine=$(tr '\n' ' ' < "$out/main.dart.js")
all=$(printf '%s' "$engine" | grep -oE 'preferWebParagraph' | wc -l | tr -d ' ')
off=$(printf '%s' "$engine" |
  grep -oE "\\.preferWebParagraph[[:space:]]*return $id==null\\?!1:$id" |
  wc -l | tr -d ' ')
[ "$all" = "$off" ] ||
  web_paragraph_fail "the engine reads preferWebParagraph with another default"

echo "build.sh: $(du -sh "$out" | cut -f1) in $out, no internet hosts named," \
  "preferWebParagraph opt-in"
