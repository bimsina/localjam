#!/bin/sh
# The guest engine in a real browser against a real host:
#
#   tool/web_engine_test.sh
#
# Starts tool/web_test_host.dart on loopback, then runs
# test/web/guest_engine_web_test.dart under `flutter test --platform chrome`
# with Chrome wrapped by tool/chrome_web_test.sh, handing the host's join URL
# and control port in through --dart-define. (flutter test's browser
# platform has no spawnHybridUri, so the host cannot be started from the
# test itself.) Exits with the test's status.
set -e
cd "$(dirname "$0")/.."
info_file=$(mktemp)
dart run tool/web_test_host.dart > "$info_file" &
host=$!
trap 'kill $host 2>/dev/null || true; rm -f "$info_file"' EXIT
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
  --platform chrome test/web/guest_engine_web_test.dart \
  "--dart-define=LOCALJAM_WEB_TEST_HOST=$info"
