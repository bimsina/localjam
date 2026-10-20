/// Where `localjam://` deep links (and http join links, §1) wait their
/// turn.
///
/// Two bugs lived in the app root's link handling. On a cold start the same
/// link was delivered twice — `getInitialLink()` and, since app_links 6, a
/// replay of the launch link on `uriLinkStream` — and each delivery raised
/// its own confirm dialog and its own join. And a link that opened the app
/// for the very first time was handled while the onboarding gate held every
/// route, so the join's `/room` was redirected straight back to the intro.
///
/// The inbox fixes both in one place: every delivery comes through
/// [receive], repeats inside [dedupWindow] are dropped, and a link that
/// arrives before [ready] says so is parked until [readyChanged] finds it is.
///
/// Links are also handled one at a time. A link that lands while another is
/// still being handled (its confirm dialog open, its join in flight) — or
/// while the app is busy starting a session — used to be dropped on the
/// floor; it is parked instead, and handed over once the way is clear.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:localjam_client/localjam_client.dart' show JoinLink;

class JamLinkInbox {
  JamLinkInbox({
    required this.onLink,
    required this.ready,
    this.dedupWindow = const Duration(seconds: 5),
    @visibleForTesting DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Handles one link, once. A returned future marks it in hand until it
  /// completes: links arriving meanwhile are parked behind it.
  final FutureOr<void> Function(Uri uri) onLink;

  /// Whether links can be handled now (the intro is done, nothing else is
  /// starting).
  final bool Function() ready;

  /// How long a repeat of the same link counts as the same delivery.
  final Duration dedupWindow;

  final DateTime Function() _clock;

  Uri? _last;
  DateTime? _lastAt;
  Uri? _parked;
  bool _handling = false;

  /// The link waiting for [ready] (or for the one in hand), if any.
  Uri? get parked => _parked;

  /// Whether a link is being handled right now.
  bool get handling => _handling;

  /// One delivery, from whichever source.
  void receive(Uri uri) {
    // The app's own scheme, whatever it says (the handler explains a bad
    // one); or an http join link (§1, 1.2) that an embedder routed here.
    if (uri.scheme != 'localjam' && JoinLink.fromUri(uri) == null) return;
    final now = _clock();
    final lastAt = _lastAt;
    if (uri == _last &&
        lastAt != null &&
        now.difference(lastAt) < dedupWindow) {
      return;
    }
    _last = uri;
    _lastAt = now;
    // Newest wins: two links before the way is clear means the second is
    // the one the user just tapped.
    if (_handling) {
      _parked = uri; // Behind the one in hand.
      return;
    }
    if (!ready()) {
      _parked = uri;
      return;
    }
    _hand(uri);
  }

  /// Call whenever [ready] may have changed; hands over a parked link.
  void readyChanged() {
    final parked = _parked;
    if (parked == null || _handling || !ready()) return;
    _parked = null;
    _hand(parked);
  }

  void _hand(Uri uri) {
    final FutureOr<void> result;
    _handling = true;
    try {
      result = onLink(uri);
    } catch (e) {
      _handling = false;
      debugPrint('localjam: link handling failed: $e');
      return;
    }
    if (result is! Future<void>) {
      _handling = false;
      return;
    }
    unawaited(
      result
          .catchError((Object e) => debugPrint('localjam: link failed: $e'))
          .whenComplete(() {
            _handling = false;
            readyChanged();
          }),
    );
  }
}
