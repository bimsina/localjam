#!/bin/sh
# Chrome for the guest engine's browser tests (tool/web_engine_test.sh):
#
# --autoplay-policy=no-user-gesture-required  Web Audio may run without a
#     tap (the page gets one; a test cannot).
# --disable-web-security  the test page is served by the test runner, not by
#     the host it joins, as the real listener page is (WEB_GUEST.md D2); the
#     host sends no CORS headers and needs none for its own page.
#
# For the background-throttling test (tool/web_engine_test.sh --throttling):
#
# $LOCALJAM_CHROME_THROTTLE (non-empty)  drops the
#     --disable-background-timer-throttling flutter_tools always passes, so
#     a hidden page is throttled the way a person's browser throttles it.
# $LOCALJAM_CHROME_FLAGS  extra flags, split on spaces (e.g. a shorter
#     intensive-throttling grace period).
# $LOCALJAM_CHROME_DEVTOOLS_FILE  where to write the DevTools port
#     flutter_tools picked (--remote-debugging-port), for the host helper
#     that hides the test's tab over the DevTools protocol.
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
for arg in "$@"; do
  shift
  case "$arg" in
    --remote-debugging-port=*)
      if [ -n "$LOCALJAM_CHROME_DEVTOOLS_FILE" ]; then
        echo "${arg#--remote-debugging-port=}" > "$LOCALJAM_CHROME_DEVTOOLS_FILE"
      fi
      ;;
    --disable-background-timer-throttling)
      [ -n "$LOCALJAM_CHROME_THROTTLE" ] && continue
      ;;
  esac
  set -- "$@" "$arg"
done
# shellcheck disable=SC2086 # $LOCALJAM_CHROME_FLAGS is split on purpose.
exec "$chrome" --autoplay-policy=no-user-gesture-required \
  --disable-web-security $LOCALJAM_CHROME_FLAGS "$@"
