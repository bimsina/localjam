#!/bin/sh
# The guest engine in a real browser against a real host:
#
#   tool/web_engine_test.sh               # test/web/guest_engine_web_test.dart
#   tool/web_engine_test.sh --throttling  # test/web/background_throttling_web_test.dart
#
# Starts tool/web_test_host.dart on loopback, then runs the test under
# `flutter test --platform chrome` with Chrome wrapped by
# tool/chrome_web_test.sh, handing the host's join URL and control port in
# through --dart-define. (flutter test's browser platform has no
# spawnHybridUri, so the host cannot be started from the test itself.)
# Exits with the test's status.
#
# --throttling runs Chrome as a person's browser runs a background tab —
# without flutter_tools' --disable-background-timer-throttling, with
# intensive wake-up throttling after a 10 s grace instead of 5 minutes —
# and lets the host helper hide the test's tab over the DevTools protocol.
# It takes about four minutes (PROTOCOL.md §3.3, WEB_GUEST.md).
set -e
cd "$(dirname "$0")/.."
test_file=test/web/guest_engine_web_test.dart
if [ "$1" = "--throttling" ]; then
  test_file=test/web/background_throttling_web_test.dart
  devtools_file=$(mktemp)
  export LOCALJAM_CHROME_THROTTLE=1
  export LOCALJAM_CHROME_FLAGS="--enable-features=IntensiveWakeUpThrottling:grace_period_seconds/10"
  export LOCALJAM_CHROME_DEVTOOLS_FILE="$devtools_file"
  export LOCALJAM_WEB_TEST_MINUTES=10
fi
info_file=$(mktemp)
dart run tool/web_test_host.dart > "$info_file" &
host=$!
trap 'kill $host 2>/dev/null || true; rm -f "$info_file" ${devtools_file:+"$devtools_file"}' EXIT
for _ in $(seq 1 100); do
  [ -s "$info_file" ] && break
  sleep 0.2
done
info=$(head -n 1 "$info_file")
if [ -z "$info" ]; then
  echo "web_engine_test.sh: the host did not start" >&2
  exit 1
fi
echo "host: $info"
CHROME_EXECUTABLE="$PWD/tool/chrome_web_test.sh" flutter test \
  --platform chrome "$test_file" \
  "--dart-define=LOCALJAM_WEB_TEST_HOST=$info"
