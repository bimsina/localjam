/// The last few things that went wrong, kept in memory.
///
/// LocalJam ships no crash SDK — there is no server in this product and no
/// account to attach a report to — so in a release build an uncaught error
/// went to `debugPrint` and, for all practical purposes, nowhere. This is the
/// smallest thing that is not nowhere: a bounded ring the error handlers
/// write to, which a future "Report a problem" can read back and put in front
/// of the one person who can actually describe what they were doing.
///
/// Deliberately tiny and lossy. It is diagnostics, not telemetry: it never
/// leaves the device, it is never persisted, and it holds [capacity] entries
/// so a per-frame failure cannot eat a jam's worth of memory.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

/// One recorded error.
@immutable
class JamLoggedError {
  JamLoggedError(this.error, {this.stack, this.context}) : at = DateTime.now();

  /// `error.toString()` — the object itself is not held, so nothing keeps a
  /// widget tree or a socket alive by being in the log.
  final String error;
  final String? stack;

  /// Where it came from: `flutter`, `platform`, or a caller's own label.
  final String? context;
  final DateTime at;

  @override
  String toString() => '${at.toIso8601String()} ${context ?? 'error'}: $error';
}

/// A bounded in-memory ring of recent errors.
abstract final class JamErrorLog {
  /// How many entries are kept. Enough to cover the run-up to a crash, few
  /// enough that a failure firing every frame costs nothing that matters.
  static const int capacity = 50;

  static final Queue<JamLoggedError> _entries = ListQueue<JamLoggedError>();

  /// Oldest first.
  static List<JamLoggedError> get entries => List.unmodifiable(_entries);

  /// Records [error], dropping the oldest entry when full.
  static void record(Object error, {StackTrace? stack, String? context}) {
    _entries.addLast(
      JamLoggedError(
        '$error',
        // Stacks are the bulk of an entry; one screenful is enough to tell
        // two failures apart, and nobody reads more in a bug report.
        stack: stack == null ? null : _head(stack),
        context: context,
      ),
    );
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  static String _head(StackTrace stack) {
    final lines = '$stack'.split('\n');
    return lines.take(12).join('\n');
  }

  /// Empties the ring (tests, and a future "report sent").
  static void clear() => _entries.clear();
}
