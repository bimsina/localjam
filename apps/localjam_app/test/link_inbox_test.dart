/// Deep links: one delivery per link, none until the intro is done, and one
/// at a time — a link that lands while another is in hand, or while a
/// session is starting, waits instead of being dropped.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/state/link_inbox.dart';

void main() {
  final link = Uri.parse(
    'localjam://join?v=1&host=192.168.1.5&port=44100&token=t&name=Van',
  );

  test('a cold-start link delivered twice is handled once', () {
    // app_links 6 hands the launch link to getInitialLink() AND replays it
    // on uriLinkStream: two confirm dialogs, two joins, before the dedupe.
    var now = DateTime(2026);
    final handled = <Uri>[];
    final inbox = JamLinkInbox(
      onLink: handled.add,
      ready: () => true,
      clock: () => now,
    );
    inbox
      ..receive(link)
      ..receive(link);
    expect(handled, [link]);

    // The same link tapped again later is a new delivery.
    now = now.add(const Duration(seconds: 30));
    inbox.receive(link);
    expect(handled, [link, link]);
  });

  test('a link before the intro is done waits for it', () {
    var seen = false;
    final handled = <Uri>[];
    final inbox = JamLinkInbox(onLink: handled.add, ready: () => seen);
    inbox.receive(link);
    expect(handled, isEmpty, reason: 'the gate would bounce /room to /welcome');
    expect(inbox.parked, link);

    inbox.readyChanged();
    expect(handled, isEmpty);

    seen = true;
    inbox
      ..readyChanged()
      // Handed over exactly once.
      ..readyChanged();
    expect(handled, [link]);
    expect(inbox.parked, isNull);
  });

  test('a link that lands while another is being handled waits its turn — '
      'newest wins — and is handed over when that one is done', () async {
    final other = Uri.parse(
      'localjam://join?v=1&host=192.168.1.9&port=44100&token=u&name=Bus',
    );
    final third = Uri.parse(
      'localjam://join?v=1&host=192.168.1.7&port=44100&token=w&name=Car',
    );
    final handled = <Uri>[];
    final inFlight = <Completer<void>>[];
    final inbox = JamLinkInbox(
      onLink: (uri) {
        handled.add(uri);
        final done = Completer<void>();
        inFlight.add(done);
        return done.future;
      },
      ready: () => true,
    );
    inbox.receive(link);
    expect(handled, [link]);
    expect(inbox.handling, isTrue);

    // The confirm dialog for the first is still up.
    inbox
      ..receive(third)
      ..receive(other);
    expect(handled, [link], reason: 'not on top of the one in hand');
    expect(inbox.parked, other);

    inFlight.single.complete();
    await pumpEventQueue();
    expect(handled, [link, other], reason: 'parked, not dropped');
    inFlight.last.complete();
    await pumpEventQueue();
    expect(inbox.handling, isFalse);
    expect(inbox.parked, isNull);
  });

  test('a link while the app is busy starting a session waits for it', () {
    var busy = true;
    final handled = <Uri>[];
    final inbox = JamLinkInbox(onLink: handled.add, ready: () => !busy);
    inbox.receive(link);
    expect(handled, isEmpty);
    busy = false;
    inbox.readyChanged();
    expect(handled, [link]);
  });

  test('anything that is not a jam link is not ours', () {
    final handled = <Uri>[];
    JamLinkInbox(
      onLink: handled.add,
      ready: () => true,
    ).receive(Uri.parse('https://example.com/join'));
    expect(handled, isEmpty);
  });
}
