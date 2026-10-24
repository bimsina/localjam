/// The host's shared music library (PROTOCOL.md §6.6) through the session
/// controller, over a real host and a real guest on the loopback interface:
/// sharing it when the jam starts and from Settings, adding from it on
/// either side, and what each side is told.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localjam_app/src/state/session_controller.dart';
import 'package:localjam_client/localjam_client.dart';

import 'fixtures.dart';
import 'harness.dart';
import 'session_controller_test.dart' show tempCache, waitFor;

/// A music library in memory: entries over real files, so an add lands.
class _FakeLibrary extends JamCatalogSource {
  _FakeLibrary(this.entries, this.files, {this.listError, this.gate});

  final List<CatalogEntry> entries;
  final Map<String, String> files;
  final Object? listError;

  /// Holds every [open] until it completes, so adds stay waiting.
  final Completer<void>? gate;

  @override
  Future<List<CatalogEntry>> list() async {
    final error = listError;
    if (error != null) throw error;
    return entries;
  }

  @override
  Future<File?> open(String catalogId) async {
    await gate?.future;
    final path = files[catalogId];
    return path == null ? null : File(path);
  }
}

_FakeLibrary _library({Object? listError, Completer<void>? gate}) {
  final paths = makeTestTracks();
  const titles = ['Low Tide', 'Night Drive', 'Paper Boats'];
  return _FakeLibrary(
    [
      for (var i = 0; i < 3; i++)
        CatalogEntry(catalogId: 'c_${i + 1}', title: titles[i]),
    ],
    {for (var i = 0; i < 3; i++) 'c_${i + 1}': paths[i]},
    listError: listError,
    gate: gate,
  );
}

/// The guest really fetches the listing and the songs: the test binding's
/// HttpClient answers everything 400.
void _realHttp() {
  final previous = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = previous);
}

void main() {
  testWidgets('a jam started with the library on shares it once the room '
      'is up', (tester) async {
    final library = _library();
    final host = testSession(librarySource: () => library);
    await tester.runAsync(() async {
      expect(
        await host.startHost(
          sessionName: 'Library Room',
          discoverable: false,
          shareLibrary: true,
        ),
        isTrue,
      );
      final engine = host.hostEngine!;
      expect(await waitFor(() => engine.catalog.value != null), isTrue);
      expect(engine.catalog.value!.count, 3);
      expect(identical(host.sharedLibrary, library), isTrue);
      await host.leave();
    });
  });

  testWidgets('a jam started with the library off shares nothing', (
    tester,
  ) async {
    final host = testSession(librarySource: _library);
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Quiet Room', discoverable: false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.hostEngine!.catalog.value, isNull);
      expect(host.sharedLibrary, isNull);
      await host.leave();
    });
  });

  testWidgets('a library that cannot be read is a notice; the jam starts '
      'anyway', (tester) async {
    final host = testSession(
      librarySource: () => _library(listError: StateError('no permission')),
    );
    await tester.runAsync(() async {
      final heard = <String>[];
      final sub = host.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);
      expect(
        await host.startHost(
          sessionName: 'Broken Library',
          discoverable: false,
          shareLibrary: true,
        ),
        isTrue,
      );
      expect(
        await waitFor(() => heard.contains(JamCatalogStrings.shareFailed)),
        isTrue,
      );
      expect(host.isLive, isTrue);
      expect(host.hostEngine!.catalog.value, isNull);
      await host.leave();
    });
  });

  testWidgets('an empty library is shared, and says there is nothing in it', (
    tester,
  ) async {
    final host = testSession(librarySource: () => _FakeLibrary(const [], {}));
    await tester.runAsync(() async {
      final heard = <String>[];
      final sub = host.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);
      await host.startHost(
        sessionName: 'Empty Library',
        discoverable: false,
        shareLibrary: true,
      );
      expect(
        await waitFor(() => heard.contains(JamCatalogStrings.shareEmpty)),
        isTrue,
      );
      expect(host.hostEngine!.catalog.value?.count, 0);
      await host.leave();
    });
  });

  testWidgets('sharing turns on and off mid-jam', (tester) async {
    final host = testSession(librarySource: _library);
    await tester.runAsync(() async {
      await host.startHost(sessionName: 'Toggle Room', discoverable: false);
      final engine = host.hostEngine!;
      expect(await host.setLibraryShared(true), isTrue);
      expect(engine.catalog.value?.count, 3);
      expect(host.sharedLibrary, isNotNull);
      expect(await host.setLibraryShared(false), isTrue);
      expect(engine.catalog.value, isNull);
      expect(host.sharedLibrary, isNull);
      await host.leave();
    });
  });

  testWidgets('a guest adds from the host’s library: the guest is told it '
      'is on its way, the host who added what', (tester) async {
    _realHttp();
    final host = testSession(librarySource: _library);
    final guest = testSession(identity: 'Ana');
    final cache = tempCache();
    await tester.runAsync(() async {
      final hostHeard = <String>[];
      final guestHeard = <String>[];
      final subs = [
        host.notices.listen((n) => hostHeard.add(n.message)),
        guest.notices.listen((n) => guestHeard.add(n.message)),
      ];
      addTearDown(() async {
        for (final sub in subs) {
          await sub.cancel();
        }
      });
      await host.startHost(
        sessionName: 'Shared Room',
        discoverable: false,
        shareLibrary: true,
      );
      expect(await waitFor(() => host.sharedLibrary != null), isTrue);
      expect(
        await guest.join(
          host.joinUri!,
          clientName: 'Ana',
          mediaCacheDir: cache,
        ),
        isTrue,
      );
      final engine = guest.guestEngine!;
      expect(await waitFor(() => engine.catalog.value != null), isTrue);
      final listing = await engine.fetchCatalog();
      expect(listing.map((e) => e.title), contains('Low Tide'));

      await guest.addFromCatalog([
        listing.firstWhere((e) => e.title == 'Low Tide'),
      ]);
      expect(
        await waitFor(
          () => guestHeard.contains(JamCatalogStrings.adding(1, 'Low Tide')),
        ),
        isTrue,
        reason: '$guestHeard',
      );
      expect(
        await waitFor(
          () => hostHeard.contains(
            JamCatalogStrings.addedFromYourLibrary('Ana', 'Low Tide'),
          ),
        ),
        isTrue,
        reason: '$hostHeard',
      );
      // Credited to the guest who asked (§6.6), on both sides.
      final item = host.hostEngine!.playlist.single;
      expect(item.addedBy, engine.selfPeerId);
      expect(await waitFor(() => engine.playlist.length == 1), isTrue);

      // The host's own add says nothing about "your library".
      hostHeard.clear();
      await host.addFromCatalog([
        host.hostEngine!.catalogEntries.firstWhere(
          (e) => e.title == 'Night Drive',
        ),
      ]);
      expect(host.hostEngine!.playlist, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hostHeard.where((m) => m.contains('from your library')), isEmpty);

      // Adding what is already queued is said, not silent.
      await host.addFromCatalog([
        host.hostEngine!.catalogEntries.firstWhere(
          (e) => e.title == 'Night Drive',
        ),
      ]);
      expect(
        await waitFor(() => hostHeard.contains(kJamAlreadyQueued)),
        isTrue,
      );

      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('a burst of adds from one guest is one notice on the host', (
    tester,
  ) async {
    _realHttp();
    final host = testSession(librarySource: _library);
    final guest = testSession(identity: 'Ana');
    final cache = tempCache();
    await tester.runAsync(() async {
      final heard = <String>[];
      final sub = host.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);
      await host.startHost(
        sessionName: 'Burst Room',
        discoverable: false,
        shareLibrary: true,
      );
      expect(await waitFor(() => host.sharedLibrary != null), isTrue);
      await guest.join(host.joinUri!, clientName: 'Ana', mediaCacheDir: cache);
      final engine = guest.guestEngine!;
      expect(await waitFor(() => engine.catalog.value != null), isTrue);
      await guest.addFromCatalog(await engine.fetchCatalog());
      expect(
        await waitFor(
          () => heard.contains(
            JamCatalogStrings.addedSongsFromYourLibrary('Ana', 3),
          ),
        ),
        isTrue,
        reason: '$heard',
      );
      expect(host.hostEngine!.playlist, hasLength(3));
      await Future<void>.delayed(JamSessionController.catalogNoticeWindow * 2);
      expect(heard.where((m) => m.contains('from your library')), hasLength(1));
      await guest.leave();
      await host.leave();
    });
  });

  testWidgets('a host past its bounds answers busy, and the guest is told '
      'some songs did not fit', (tester) async {
    final gate = Completer<void>();
    final paths = makeTestTracks(count: 1);
    // More songs than the host will hold waiting (64, §6.6).
    final library = _FakeLibrary(
      [
        for (var i = 0; i < 80; i++)
          CatalogEntry(catalogId: 'c_$i', title: 'Song $i'),
      ],
      {for (var i = 0; i < 80; i++) 'c_$i': paths.single},
      gate: gate,
    );
    _realHttp();
    final host = testSession(librarySource: () => library);
    final guest = testSession(identity: 'Ana');
    final cache = tempCache();
    await tester.runAsync(() async {
      final heard = <String>[];
      final sub = guest.notices.listen((n) => heard.add(n.message));
      addTearDown(sub.cancel);
      await host.startHost(
        sessionName: 'Busy Room',
        discoverable: false,
        shareLibrary: true,
      );
      expect(await waitFor(() => host.sharedLibrary != null), isTrue);
      await guest.join(host.joinUri!, clientName: 'Ana', mediaCacheDir: cache);
      final engine = guest.guestEngine!;
      expect(await waitFor(() => engine.catalog.value != null), isTrue);
      final listing = await engine.fetchCatalog();
      // One call carries 50 songs and says so about the other 30.
      await guest.addFromCatalog(listing);
      expect(
        await waitFor(
          () => heard.contains(JamCatalogStrings.addingSome(50, 80)),
        ),
        isTrue,
        reason: '$heard',
      );
      // Those 50 are still waiting (the library is held shut), so the
      // next pick is past this guest's bound on the host.
      await guest.addFromCatalog(listing.sublist(50));
      expect(
        await waitFor(() => heard.contains(JamCatalogStrings.busy)),
        isTrue,
        reason: '$heard',
      );
      expect(
        JamCatalogStrings.busy,
        'Some of those songs didn’t fit in the queue.',
      );
      gate.complete();
      await guest.leave();
      await host.leave();
    });
  });
}
