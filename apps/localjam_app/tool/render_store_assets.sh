#!/usr/bin/env bash
# Renders the Google Play listing graphics from the raw Android captures.
#
#   apps/localjam_app/tool/render_store_assets.sh
#
# Input:  docs/screenshots/android/*.png (1080x2160 raw captures, no alpha)
# Output: docs/release/play-assets/
#           01-…08-*.png    store screenshots, 1080x1920, no alpha
#           feature-graphic.png  1024x500, no alpha
#           icon-512.png         512x512 from assets/brand/icon_1024.png
#
# Each store screenshot is the raw capture in a device-less rounded card on
# the brand's raspberry gradient (the app icon's), with a short caption in
# Manrope above it. Layout is plain HTML rendered by headless Chrome, so the
# type matches the app's own Manrope; ImageMagick drops the alpha channel.
#
# Needs Google Chrome (headless) and ImageMagick, like render_brand.sh.
set -euo pipefail

APP="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP/../.." && pwd)"
RAW="$ROOT/docs/screenshots/android"
OUT="$ROOT/docs/release/play-assets"
FONT="$APP/assets/fonts/Manrope.ttf"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
cp "$FONT" "$WORK/Manrope.ttf"

# The brand: the app icon's gradient, the light-theme canvas and ink.
GRAD_TOP="#FF5A7A"
GRAD_BOTTOM="#B4205A"

# The mark (assets/brand/logo.svg), inline so it can be recoloured.
MARK_PATHS='<g fill="currentColor"><circle cx="28.5" cy="82" r="9"/><circle cx="60.5" cy="82" r="9"/></g><path d="M34 81V50M66 81V50M34 50A27.2 27.2 0 0 1 66 50M27.53 41.1A38.2 38.2 0 0 1 72.47 41.1M21.06 32.21A49.2 49.2 0 0 1 78.94 32.21" fill="none" stroke="currentColor" stroke-width="7" stroke-linecap="round"/>'

css_common() {
  cat <<CSS
@font-face { font-family: Manrope; src: url("Manrope.ttf"); font-weight: 200 800; }
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: $1px; height: $2px; overflow: hidden; }
body {
  background: linear-gradient(170deg, $GRAD_TOP 0%, $GRAD_BOTTOM 100%);
  font-family: Manrope, sans-serif; font-feature-settings: "calt" 0;
  color: #fff; -webkit-font-smoothing: antialiased;
}
CSS
}

render() { # <html file> <w> <h> <out png>
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --allow-file-access-from-files --force-device-scale-factor=1 \
    --window-size="$2,$3" --screenshot="$WORK/shot.png" \
    "file://$1" >/dev/null 2>&1
  magick "$WORK/shot.png" -crop "$2x$3+0+0" +repage \
    -background white -alpha remove -alpha off "$4"
}

# shot <nn-name> <raw capture> <caption line 1> [caption line 2]
shot() {
  local name="$1" raw="$2" l1="$3" l2="${4:-}"
  cp "$RAW/$raw" "$WORK/$raw"
  cat >"$WORK/$name.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><style>
$(css_common 1080 1920)
.glow { position: absolute; width: 1400px; height: 1400px; left: -160px; top: 760px;
  border-radius: 50%; background: radial-gradient(closest-side, rgba(255,255,255,.16), rgba(255,255,255,0)); }
h1 { position: absolute; left: 80px; right: 80px; top: 112px; text-align: center;
  font-size: 76px; line-height: 92px; font-weight: 800; letter-spacing: -1.5px; }
.card { position: absolute; left: 175px; top: 372px; width: 730px; height: 1460px;
  border-radius: 52px; overflow: hidden; background: #fff;
  box-shadow: 0 40px 90px rgba(70, 0, 30, .38), 0 0 0 10px rgba(255,255,255,.18); }
.card img { width: 100%; height: 100%; display: block; }
</style></head><body>
<div class="glow"></div>
<h1>$l1${l2:+<br>$l2}</h1>
<div class="card"><img src="$raw"></div>
</body></html>
HTML
  render "$WORK/$name.html" 1080 1920 "$OUT/$name.png"
}

shot 01-in-sync      room.png       "Everyone hears" "the same beat"
shot 02-shared-queue queue.png      "Add songs from" "any phone"
shot 03-no-internet  home.png       "No internet." "No accounts."
shot 04-browser      web-guest.png  "Guests can join" "from a browser"
shot 05-invite       invite-qr.png  "Scan the code" "and you're in"
shot 06-people       people.png     "You choose who" "runs the music"
shot 07-history      history.png    "Every jam," "remembered"
shot 08-dark         room-dark.png  "Made for late" "nights too"

# Feature graphic: 1024x500. Everything that matters sits in the middle
# ~70 % so Play's rounded corners and overlays never clip it.
cat >"$WORK/feature.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><style>
$(css_common 1024 500)
body { background: linear-gradient(160deg, $GRAD_TOP 0%, $GRAD_BOTTOM 100%); }
.arcs { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); opacity: .10; }
.row { position: absolute; left: 0; right: 0; top: 0; bottom: 0; display: flex;
  align-items: center; justify-content: center; gap: 44px; }
svg.mark { width: 150px; height: 166px; color: #fff; }
.name { font-size: 104px; line-height: 1; font-weight: 800; letter-spacing: -3px; }
.tag { margin-top: 18px; font-size: 38px; font-weight: 600; letter-spacing: -.3px; opacity: .92; }
</style></head><body>
<svg class="arcs" width="1100" height="1100" viewBox="0 0 1100 1100" fill="none" stroke="#fff" stroke-width="26">
  <circle cx="550" cy="550" r="300"/><circle cx="550" cy="550" r="420"/><circle cx="550" cy="550" r="540"/>
</svg>
<div class="row">
  <svg class="mark" viewBox="17.5 19.3 65 71.7">$MARK_PATHS</svg>
  <div><div class="name">LocalJam</div><div class="tag">Listen together, in sync.</div></div>
</div>
</body></html>
HTML
render "$WORK/feature.html" 1024 500 "$OUT/feature-graphic.png"

magick "$APP/assets/brand/icon_1024.png" -resize 512x512 -alpha off "$OUT/icon-512.png"

for f in "$OUT"/*.png; do
  printf '%-28s %s\n' "$(basename "$f")" "$(magick identify -format '%wx%h %[channels]' "$f")"
done
