#!/bin/sh
# Builds the listener page the way the host serves it (PROTOCOL.md §1.1,
# docs/design/WEB_GUEST.md D8) and checks it can make no off-origin request:
#
#   tool/build.sh [--keep-all]
#
# 1. `flutter build web --release --base-href /web/ --no-web-resources-cdn
#    --pwa-strategy none` into build/web.
# 2. Scrubs the two internet defaults Flutter's own code still carries
#    although this build never uses them: the CanvasKit CDN in the loader
#    (unused: the build config says useLocalCanvasKit) and the font-fallback
#    CDN in the engine (unused: web/flutter_bootstrap.js sets
#    fontFallbackBaseUrl to this origin). Both are replaced by same-origin
#    paths, so even a code path we did not foresee cannot reach the
#    internet.
# 3. Unless --keep-all: removes what a dart2js CanvasKit build never loads —
#    the skwasm/wimp renderers (`--wasm` builds only), the webparagraph
#    CanvasKit (opt-in config), and the *.symbols debug files — about 25 MB
#    the host app would otherwise carry in its APK. A browser loads
#    canvaskit/canvaskit.* (Safari, Firefox, Chrome on a plain-http LAN page)
#    or canvaskit/chromium/* (Chrome on a secure origin such as localhost).
# 4. Fails if anything in build/web still names gstatic or googleapis.
set -e
cd "$(dirname "$0")/.."
flutter build web --release --base-href /web/ --no-web-resources-cdn \
  --pwa-strategy none
out=build/web

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
  rm -f "$out/flutter_service_worker.js"
fi

if grep -rlE 'gstatic|googleapis' "$out"; then
  echo "build.sh: the files above still name an internet host" >&2
  exit 1
fi
echo "build.sh: $(du -sh "$out" | cut -f1) in $out, no internet hosts named"
