#!/usr/bin/env bash
# Renders every brand image from one definition of the LocalJam mark: two
# beamed notes whose beam is the first of three Wi-Fi arcs ("Beamed signal").
#
#   apps/localjam_app/tool/render_brand.sh
#
# Writes assets/brand/{logo.svg,icon_1024,icon_foreground,icon_monochrome,
# splash_logo*}.png and the web guest's favicon and touch icon, then the
# platform icons and launch screens still need:
#   (cd apps/localjam_app && dart run flutter_launcher_icons \
#     && dart run flutter_native_splash:create)
#
# Needs Google Chrome (headless, for anti-aliased SVG rendering) and
# ImageMagick (to drop the alpha channel the App Store rejects).
set -euo pipefail

APP="$(cd "$(dirname "$0")/.." && pwd)"
BRAND="$APP/assets/brand"
WEB="$APP/../localjam_web/web"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The mark in its own 100-unit space. Arcs share the centre (50,72); the
# beam (r 27.2) joins the stem tops at (34,50) and (66,50), and the two outer
# arcs (r 38.2, 49.2) span the same angle; each head sits flush with its
# stem's outer edge. Its ink box is x 17.5–82.5,
# y 19.3–91, centred on (50, 55.15).
mark() { # $1 colour
  cat <<SVG
<g fill="$1"><circle cx="28.5" cy="82" r="9"/><circle cx="60.5" cy="82" r="9"/></g>
<path d="M34 81V50M66 81V50M34 50A27.2 27.2 0 0 1 66 50M27.53 41.1A38.2 38.2 0 0 1 72.47 41.1M21.06 32.21A49.2 49.2 0 0 1 78.94 32.21" fill="none" stroke="$1" stroke-width="7" stroke-linecap="round"/>
SVG
}

# square <file> <px> <mark height px> <colour> [background]
# The mark centred on a square canvas, its ink box <mark height> tall.
square() {
  local out="$1" px="$2" h="$3" colour="$4" bg="${5:-}"
  local units x y
  units=$(echo "scale=4; $px * 71.7 / $h" | bc)
  x=$(echo "scale=4; 50 - $units / 2" | bc)
  y=$(echo "scale=4; 55.15 - $units / 2" | bc)
  {
    echo "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$px\" height=\"$px\" viewBox=\"$x $y $units $units\">"
    if [[ -n "$bg" ]]; then
      echo "<defs><linearGradient id=\"bg\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"#FF5A7A\"/><stop offset=\"1\" stop-color=\"#B4205A\"/></linearGradient></defs>"
      echo "<rect x=\"$x\" y=\"$y\" width=\"$units\" height=\"$units\" fill=\"url(#bg)\"/>"
    fi
    mark "$colour"
    echo "</svg>"
  } >"$WORK/$out.svg"
  render "$out" "$px" "$px"
}

# tight <file> <height px> <colour>: the ink box alone, for launch screens.
tight() {
  local out="$1" h="$2" colour="$3" w
  w=$(echo "($h * 65 / 71.7 + 0.5) / 1" | bc)
  {
    echo "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$w\" height=\"$h\" viewBox=\"17.5 19.3 65 71.7\">"
    mark "$colour"
    echo "</svg>"
  } >"$WORK/$out.svg"
  render "$out" "$w" "$h"
}

render() { # <name> <w> <h>
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --default-background-color=00000000 \
    --window-size="$2,$3" --screenshot="$WORK/$1.png" \
    "file://$WORK/$1.svg" >/dev/null 2>&1
}

# Brand symbol for the wordmark and nameless jams; the app recolours it.
{
  echo '<svg xmlns="http://www.w3.org/2000/svg" width="65" height="71.7" viewBox="17.5 19.3 65 71.7">'
  mark "#FFFFFF"
  echo '</svg>'
} >"$BRAND/logo.svg"

# App icon (iOS, macOS, Windows): white mark on the raspberry gradient.
square icon_1024 1024 600 "#FFFFFF" gradient
magick "$WORK/icon_1024.png" -alpha off "$BRAND/icon_1024.png"

# Android adaptive layers: the mark inside the 66 dp safe circle.
square icon_foreground 1024 473 "#FFFFFF"
cp "$WORK/icon_foreground.png" "$BRAND/icon_foreground.png"
cp "$WORK/icon_foreground.png" "$BRAND/icon_monochrome.png"

# Launch screens: white on black, raspberry on white.
tight splash_logo 480 "#FFFFFF"
tight splash_logo_light 480 "#D92C64"
cp "$WORK/splash_logo.png" "$WORK/splash_logo_light.png" "$BRAND/"

# Android 12 splash: 1152 canvas, the mark inside its 768 px circle.
square splash_logo_android12 1152 574 "#FFFFFF"
square splash_logo_android12_light 1152 574 "#D92C64"
cp "$WORK/splash_logo_android12.png" "$WORK/splash_logo_android12_light.png" "$BRAND/"

# Web guest: favicon and home-screen icon.
square favicon 32 22 "#FFFFFF" gradient
square Icon-192 192 113 "#FFFFFF" gradient
magick "$WORK/favicon.png" -alpha off "$WEB/favicon.png"
magick "$WORK/Icon-192.png" -alpha off "$WEB/icons/Icon-192.png"

echo "Rendered brand images into $BRAND and $WEB"
