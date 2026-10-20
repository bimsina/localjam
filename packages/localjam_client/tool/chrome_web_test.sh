#!/bin/sh
# Chrome for the guest engine's browser test (tool/web_engine_test.sh):
#
# --autoplay-policy=no-user-gesture-required  Web Audio may run without a
#     tap (the page gets one; a test cannot).
# --disable-web-security  the test page is served by the test runner, not by
#     the host it joins, as the real listener page is (WEB_GUEST.md D2); the
#     host sends no CORS headers and needs none for its own page.
#
# The real binary is $LOCALJAM_CHROME, else the usual macOS install, else the
# first Chrome/Chromium on PATH.
if [ -n "$LOCALJAM_CHROME" ]; then
  chrome="$LOCALJAM_CHROME"
elif [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
else
  chrome=$(command -v google-chrome || command -v google-chrome-stable ||
    command -v chromium || command -v chromium-browser)
fi
if [ -z "$chrome" ]; then
  echo "chrome_web_test.sh: no Chrome found; set LOCALJAM_CHROME" >&2
  exit 1
fi
exec "$chrome" --autoplay-policy=no-user-gesture-required \
  --disable-web-security "$@"
