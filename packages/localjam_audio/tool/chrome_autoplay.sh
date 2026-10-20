#!/bin/sh
# Chrome for `flutter test --platform chrome` with Web Audio allowed to start
# without a user gesture, so test/localjam_audio_web_test.dart can play:
#
#   CHROME_EXECUTABLE=tool/chrome_autoplay.sh flutter test --platform chrome
#
# flutter_tools launches $CHROME_EXECUTABLE and offers no way to add browser
# flags to a test run. The real binary is $LOCALJAM_CHROME, else the usual
# install on macOS, else the first Chrome/Chromium on PATH.
if [ -n "$LOCALJAM_CHROME" ]; then
  chrome="$LOCALJAM_CHROME"
elif [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
else
  chrome=$(command -v google-chrome || command -v google-chrome-stable ||
    command -v chromium || command -v chromium-browser)
fi
if [ -z "$chrome" ]; then
  echo "chrome_autoplay.sh: no Chrome found; set LOCALJAM_CHROME" >&2
  exit 1
fi
exec "$chrome" --autoplay-policy=no-user-gesture-required "$@"
