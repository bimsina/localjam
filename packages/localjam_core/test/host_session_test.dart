import 'package:localjam_core/src/session/host_session.dart';
import 'package:localjam_core/src/session/playback_state.dart';
import 'package:test/test.dart';

void main() {
  const lead = 750_000; // default leadTimeUs (§5.3)

  group('HostSession lifecycle', () {
    test('starts at PlaybackSnapshot.initial', () {
      final s = HostSession();
      expect(s.snapshot, PlaybackSnapshot.initial);
      expect(s.snapshot.rev, 0);
      expect(s.snapshot.status, PlaybackStatus.idle);
    });

    test('setMedia -> loading, position 0, anchor cleared', () {
      final s = HostSession();
      final snap = s.setMedia('m_1', nowUs: 1_000_000);
      expect(snap, same(s.snapshot));
      expect(snap.status, PlaybackStatus.loading);
      expect(snap.mediaId, 'm_1');
      expect(snap.positionUs, 0);
      expect(snap.anchor, isNull);
      expect(snap.rev, 1);
    });

    test('play anchors leadTime in the future at the frozen position', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 1_000_000);
      final snap = s.play(nowUs: 2_000_000);
      expect(snap.status, PlaybackStatus.playing);
      expect(snap.anchor, isNotNull);
      expect(snap.anchor!.hostTimeUs, 2_000_000 + lead);
      expect(snap.anchor!.positionUs, 0);
    });

    test('custom leadTimeUs is honored', () {
      final s = HostSession(leadTimeUs: 1_500_000);
      s.setMedia('m_1', nowUs: 0);
      final snap = s.play(nowUs: 10_000_000);
      expect(snap.anchor!.hostTimeUs, 11_500_000);
    });

    test('positionAt before the anchor time clamps to the anchor position', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.seek(30_000_000, nowUs: 100); // frozen position while loading
      final snap = s.play(nowUs: 5_000_000); // anchor at 5_750_000
      expect(snap.positionAt(5_000_000), 30_000_000);
      expect(snap.positionAt(5_749_999), 30_000_000);
      expect(snap.positionAt(5_750_000), 30_000_000);
      // After the anchor time it advances.
      expect(snap.positionAt(5_750_000 + 1_000_000), 31_000_000);
    });

    test('play with no media throws StateError', () {
      final s = HostSession();
      expect(() => s.play(nowUs: 0), throwsStateError);
    });

    test('play from paused resumes at the frozen position', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.play(nowUs: 1_000_000); // anchor (1_750_000, 0)
      s.pause(nowUs: 3_750_000); // frozen at 2_000_000
      final snap = s.play(nowUs: 10_000_000);
      expect(snap.anchor!.hostTimeUs, 10_000_000 + lead);
      expect(snap.anchor!.positionUs, 2_000_000);
    });

    test('pause freezes the correctly advanced position and clears anchor', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.play(nowUs: 1_000_000); // anchor (1_750_000, 0)
      final snap = s.pause(nowUs: 6_750_000); // 5 s after the anchor
      expect(snap.status, PlaybackStatus.paused);
      expect(snap.positionUs, 5_000_000);
      expect(snap.anchor, isNull);
    });

    test('pause before the scheduled start freezes at the anchor position', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.seek(9_000_000, nowUs: 10);
      s.play(nowUs: 1_000_000); // anchor (1_750_000, 9_000_000)
      final snap = s.pause(nowUs: 1_200_000); // inside the lead window
      expect(snap.positionUs, 9_000_000);
    });

    test('pause when not playing is a no-op with the same rev', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0); // rev 1, loading
      final before = s.snapshot;
      final snap = s.pause(nowUs: 5_000_000);
      expect(snap, same(before));
      expect(snap.rev, 1);
      expect(snap.status, PlaybackStatus.loading);
    });

    test('seek while playing re-anchors with leadTime, stays playing', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.play(nowUs: 1_000_000);
      final snap = s.seek(60_000_000, nowUs: 4_000_000);
      expect(snap.status, PlaybackStatus.playing);
      expect(snap.anchor!.hostTimeUs, 4_000_000 + lead);
      expect(snap.anchor!.positionUs, 60_000_000);
      expect(snap.positionAt(4_000_000 + lead + 500_000), 60_500_000);
    });

    test('seek while paused updates the frozen position, no anchor', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.play(nowUs: 1_000_000);
      s.pause(nowUs: 3_000_000);
      final snap = s.seek(42_000_000, nowUs: 5_000_000);
      expect(snap.status, PlaybackStatus.paused);
      expect(snap.positionUs, 42_000_000);
      expect(snap.anchor, isNull);
    });

    test('seek with no media throws StateError', () {
      final s = HostSession();
      expect(() => s.seek(1, nowUs: 0), throwsStateError);
    });

    test('setRate while playing preserves position continuity', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.play(nowUs: 1_000_000); // anchor (1_750_000, 0), rate 1.0
      const now = 11_750_000; // 10 s past the anchor -> position 10 s
      final before = s.snapshot.positionAt(now);
      expect(before, 10_000_000);
      final snap = s.setRate(1.5, nowUs: now);
      expect(snap.rate, 1.5);
      // Position at the moment of the change is unchanged...
      expect(snap.positionAt(now), before);
      // ...and advances at the new rate afterwards.
      expect(snap.positionAt(now + 2_000_000), before + 3_000_000);
    });

    test('setRate while paused keeps the frozen position', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      s.play(nowUs: 1_000_000);
      s.pause(nowUs: 4_750_000); // frozen at 3_000_000
      final snap = s.setRate(2.0, nowUs: 5_000_000);
      expect(snap.rate, 2.0);
      expect(snap.status, PlaybackStatus.paused);
      expect(snap.positionUs, 3_000_000);
      expect(snap.anchor, isNull);
    });

    test('setRate rejects non-positive rates', () {
      final s = HostSession();
      expect(() => s.setRate(0, nowUs: 0), throwsArgumentError);
      expect(() => s.setRate(-1, nowUs: 0), throwsArgumentError);
    });

    test('every mutation increments rev by exactly 1', () {
      final s = HostSession();
      expect(s.snapshot.rev, 0);
      s.setMedia('m_1', nowUs: 0);
      expect(s.snapshot.rev, 1);
      s.play(nowUs: 1_000_000);
      expect(s.snapshot.rev, 2);
      s.seek(5_000_000, nowUs: 2_000_000);
      expect(s.snapshot.rev, 3);
      s.setRate(1.25, nowUs: 3_000_000);
      expect(s.snapshot.rev, 4);
      s.pause(nowUs: 4_000_000);
      expect(s.snapshot.rev, 5);
      s.pause(nowUs: 5_000_000); // no-op, not a mutation
      expect(s.snapshot.rev, 5);
      s.play(nowUs: 6_000_000);
      expect(s.snapshot.rev, 6);
    });
  });

  group('HostSession readiness (§6.3)', () {
    test('allPeersReady is vacuously true with no peers', () {
      final s = HostSession();
      expect(s.allPeersReady('m_1'), isTrue);
    });

    test('a peer with no report is not ready', () {
      final s = HostSession();
      s.upsertPeer('p1');
      expect(s.allPeersReady('m_1'), isFalse);
    });

    test('mixed states: all must be ready', () {
      final s = HostSession();
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.ready);
      s.setPeerMediaState('p2', 'm_1', MediaReadiness.fetching);
      expect(s.allPeersReady('m_1'), isFalse);
      s.setPeerMediaState('p2', 'm_1', MediaReadiness.ready);
      expect(s.allPeersReady('m_1'), isTrue);
      s.setPeerMediaState('p2', 'm_1', MediaReadiness.none);
      expect(s.allPeersReady('m_1'), isFalse);
    });

    test('readiness is per (peer, mediaId) and retained across reports', () {
      final s = HostSession();
      s.setPeerMediaState('p1', 'm_old', MediaReadiness.ready);
      expect(s.allPeersReady('m_old'), isTrue);
      expect(s.allPeersReady('m_new'), isFalse);
      s.setPeerMediaState('p1', 'm_new', MediaReadiness.ready);
      expect(s.allPeersReady('m_new'), isTrue);
      // Readiness is per-file possession: a report on m_new does not
      // supersede the peer's readiness for m_old.
      expect(s.allPeersReady('m_old'), isTrue);
      // A later downgrade only touches its own (peer, mediaId) pair.
      s.setPeerMediaState('p1', 'm_new', MediaReadiness.fetching);
      expect(s.allPeersReady('m_old'), isTrue);
      expect(s.allPeersReady('m_new'), isFalse);
    });

    test('peerMediaState defaults to none and tracks per-media reports', () {
      final s = HostSession();
      expect(s.peerMediaState('p1', 'm_1'), MediaReadiness.none);
      s.upsertPeer('p1');
      expect(s.peerMediaState('p1', 'm_1'), MediaReadiness.none);
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.fetching);
      s.setPeerMediaState('p1', 'm_2', MediaReadiness.ready);
      expect(s.peerMediaState('p1', 'm_1'), MediaReadiness.fetching);
      expect(s.peerMediaState('p1', 'm_2'), MediaReadiness.ready);
      expect(s.peerMediaState('p1', 'm_3'), MediaReadiness.none);
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.ready);
      expect(s.peerMediaState('p1', 'm_1'), MediaReadiness.ready);
    });

    test('peerMediaStates covers all known peers, defaulting to none', () {
      final s = HostSession();
      expect(s.peerMediaStates('m_1'), isEmpty);
      s.upsertPeer('p1'); // Present but silent.
      s.setPeerMediaState('p2', 'm_1', MediaReadiness.ready);
      s.setPeerMediaState('p3', 'm_1', MediaReadiness.fetching);
      s.setPeerMediaState('p3', 'm_2', MediaReadiness.ready);
      expect(s.peerMediaStates('m_1'), {
        'p1': MediaReadiness.none,
        'p2': MediaReadiness.ready,
        'p3': MediaReadiness.fetching,
      });
      expect(s.peerMediaStates('m_2'), {
        'p1': MediaReadiness.none,
        'p2': MediaReadiness.none,
        'p3': MediaReadiness.ready,
      });
    });

    test('removePeer drops the peer\'s entries for every media item', () {
      final s = HostSession();
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.ready);
      s.setPeerMediaState('p1', 'm_2', MediaReadiness.fetching);
      s.removePeer('p1');
      expect(s.peerMediaState('p1', 'm_1'), MediaReadiness.none);
      expect(s.peerMediaState('p1', 'm_2'), MediaReadiness.none);
      expect(s.peerMediaStates('m_1'), isEmpty);
      s.upsertPeer('p1');
      expect(s.peerMediaState('p1', 'm_1'), MediaReadiness.none);
      expect(s.allPeersReady('m_1'), isFalse); // No report after rejoin.
    });

    test('removing the only non-ready peer makes the rest ready', () {
      final s = HostSession();
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.ready);
      s.setPeerMediaState('p2', 'm_1', MediaReadiness.fetching);
      expect(s.allPeersReady('m_1'), isFalse);
      s.removePeer('p2');
      expect(s.allPeersReady('m_1'), isTrue);
    });

    test('removePeer forgets state; re-upsert starts fresh', () {
      final s = HostSession();
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.ready);
      s.removePeer('p1');
      expect(s.allPeersReady('m_1'), isTrue); // no peers left
      s.upsertPeer('p1');
      expect(s.allPeersReady('m_1'), isFalse); // no report after rejoin
    });

    test('upsertPeer of an existing peer keeps its reported state', () {
      final s = HostSession();
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.ready);
      s.upsertPeer('p1');
      expect(s.allPeersReady('m_1'), isTrue);
    });

    test('setPeerMediaState implicitly registers an unknown peer', () {
      final s = HostSession();
      s.setPeerMediaState('p9', 'm_1', MediaReadiness.fetching);
      expect(s.allPeersReady('m_1'), isFalse);
      s.removePeer('p9');
      expect(s.allPeersReady('m_1'), isTrue);
    });

    test('readiness bookkeeping does not touch the snapshot rev', () {
      final s = HostSession();
      s.upsertPeer('p1');
      s.setPeerMediaState('p1', 'm_1', MediaReadiness.ready);
      s.removePeer('p1');
      expect(s.snapshot.rev, 0);
    });
  });
}
