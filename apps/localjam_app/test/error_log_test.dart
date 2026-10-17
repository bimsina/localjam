/// The in-memory ring the global error handlers write to.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/state/error_log.dart';

void main() {
  setUp(JamErrorLog.clear);

  test('keeps what it is given, oldest first', () {
    JamErrorLog.record('first', context: 'platform');
    JamErrorLog.record(StateError('second'));

    final entries = JamErrorLog.entries;
    expect(entries, hasLength(2));
    expect(entries.first.error, 'first');
    expect(entries.first.context, 'platform');
    expect(entries.last.error, contains('second'));
  });

  test('is bounded, so a per-frame failure costs nothing', () {
    for (var i = 0; i < JamErrorLog.capacity * 3; i++) {
      JamErrorLog.record('error $i');
    }
    expect(JamErrorLog.entries, hasLength(JamErrorLog.capacity));
    // The newest survive; the oldest are the ones dropped.
    expect(
      JamErrorLog.entries.last.error,
      'error ${JamErrorLog.capacity * 3 - 1}',
    );
    expect(
      JamErrorLog.entries.first.error,
      'error ${JamErrorLog.capacity * 2}',
    );
  });

  test('holds a trimmed stack, never the error object itself', () {
    JamErrorLog.record('boom', stack: StackTrace.current);
    final entry = JamErrorLog.entries.single;
    expect(entry.stack, isNotNull);
    expect('\n'.allMatches(entry.stack!).length, lessThan(12));
  });
}
