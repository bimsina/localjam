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

    test('setRate accepts exactly the rates a guest will decode', () {
      // Review 2026-10-17 (N4): the host took any positive rate while
      // guests refuse a snapshot outside [1/32, 32] — one setRate(64) and
      // every state frame after it was dropped, and nobody could join.
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0);
      for (final rate in [
        PlaybackSnapshot.maxRate * 2,
        PlaybackSnapshot.minRate / 2,
        double.infinity,
        double.nan,
      ]) {
        expect(
          () => s.setRate(rate, nowUs: 0),
          throwsArgumentError,
          reason: '$rate',
        );
      }
      expect(s.snapshot.rate, 1.0, reason: 'a refused rate changes nothing');
      for (final rate in [PlaybackSnapshot.minRate, PlaybackSnapshot.maxRate]) {
        final snap = s.setRate(rate, nowUs: 0);
        // What every guest does with it (§5.1): it must round-trip.
        expect(PlaybackSnapshot.fromJson(snap.toJson()).rate, rate);
      }
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

  group('PlaybackSnapshot.clampedPositionAt (§5.5)', () {
    PlaybackSnapshot playingFrom(int anchorTimeUs) => PlaybackSnapshot(
      rev: 1,
      status: PlaybackStatus.playing,
      mediaId: 'm_1',
      anchor: PlaybackAnchor(hostTimeUs: anchorTimeUs, positionUs: 0),
    );

    test('is plain positionAt when durationUs is null', () {
      final snap = playingFrom(0);
      expect(snap.clampedPositionAt(99_000_000), 99_000_000);
      expect(snap.clampedPositionAt(99_000_000), snap.positionAt(99_000_000));
    });

    test('clamps past-the-end positions to the duration', () {
      final snap = playingFrom(0);
      expect(
        snap.clampedPositionAt(10_000_000, durationUs: 3_000_000),
        3_000_000,
      );
    });

    test('position exactly == duration stays at the duration', () {
      final snap = playingFrom(0);
      expect(
        snap.clampedPositionAt(3_000_000, durationUs: 3_000_000),
        3_000_000,
      );
    });

    test('in-range positions pass through unchanged', () {
      final snap = playingFrom(0);
      expect(
        snap.clampedPositionAt(1_500_000, durationUs: 3_000_000),
        1_500_000,
      );
      expect(snap.clampedPositionAt(0, durationUs: 3_000_000), 0);
    });

    test('clamps below zero to 0 when a duration is given', () {
      // A frozen snapshot can carry a negative position only if it was
      // constructed that way; clamping still bounds it.
      const snap = PlaybackSnapshot(
        rev: 1,
        status: PlaybackStatus.paused,
        mediaId: 'm_1',
        positionUs: -5,
      );
      expect(snap.clampedPositionAt(0, durationUs: 3_000_000), 0);
      expect(snap.clampedPositionAt(0), -5); // No duration: plain positionAt.
    });

    test('when paused, clamps the frozen position', () {
      const snap = PlaybackSnapshot(
        rev: 1,
        status: PlaybackStatus.paused,
        mediaId: 'm_1',
        positionUs: 9_000_000,
      );
      expect(snap.clampedPositionAt(0, durationUs: 3_000_000), 3_000_000);
    });
  });

  group('HostSession end of media (§5.5)', () {
    const dur = 3_000_000; // 3 s track

    HostSession playing({int? durationUs = dur}) {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0, durationUs: durationUs);
      s.play(nowUs: 0); // anchor (lead, 0)
      return s;
    }

    test('setMedia stores the duration as currentDurationUs', () {
      final s = HostSession();
      expect(s.currentDurationUs, isNull);
      s.setMedia('m_1', nowUs: 0, durationUs: dur);
      expect(s.currentDurationUs, dur);
    });

    test('setMedia without a duration clears the previous one', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0, durationUs: dur);
      s.setMedia('m_2', nowUs: 1);
      expect(s.currentDurationUs, isNull);
    });

    test('hasEnded is false while the track is still going', () {
      final s = playing();
      expect(s.hasEnded(lead + dur - 1), isFalse);
    });

    test('hasEnded at position exactly == duration (boundary)', () {
      final s = playing();
      expect(s.hasEnded(lead + dur), isTrue);
    });

    test('hasEnded past the duration', () {
      final s = playing();
      expect(s.hasEnded(lead + dur + 60_000_000), isTrue);
    });

    test('hasEnded is false when the duration is unknown', () {
      final s = playing(durationUs: null);
      expect(s.hasEnded(lead + 3_600_000_000), isFalse);
    });

    test('hasEnded is false while loading or idle', () {
      final s = HostSession();
      expect(s.hasEnded(0), isFalse); // idle
      s.setMedia('m_1', nowUs: 0, durationUs: dur);
      expect(s.hasEnded(1_000_000_000), isFalse); // loading
    });

    test('hasEnded when paused exactly at the duration', () {
      final s = playing();
      s.seek(dur, nowUs: lead + 1);
      s.pause(nowUs: lead + 2);
      expect(s.snapshot.positionUs, dur);
      expect(s.hasEnded(lead + 3), isTrue);
    });

    test('hasEnded does not mutate state or rev', () {
      final s = playing();
      final before = s.snapshot;
      s.hasEnded(lead + dur + 1);
      expect(s.snapshot, same(before));
    });

    test('pause after the end freezes at exactly the duration', () {
      final s = playing();
      final snap = s.pause(nowUs: lead + dur + 5_000_000);
      expect(snap.status, PlaybackStatus.paused);
      expect(snap.positionUs, dur);
      expect(snap.anchor, isNull);
    });

    test('play after the end re-anchors at the clamped duration', () {
      final s = playing();
      final snap = s.play(nowUs: lead + dur + 5_000_000);
      expect(snap.anchor!.positionUs, dur);
    });

    test('seek beyond the duration clamps to it (playing and paused)', () {
      final s = playing();
      var snap = s.seek(dur + 10_000_000, nowUs: lead + 1);
      expect(snap.anchor!.positionUs, dur);
      expect(snap.positionUs, dur);
      s.pause(nowUs: lead + 2);
      snap = s.seek(dur + 1, nowUs: lead + 3);
      expect(snap.positionUs, dur);
    });

    test('seek below zero clamps to 0 when the duration is known', () {
      final s = playing();
      final snap = s.seek(-1, nowUs: lead + 1);
      expect(snap.anchor!.positionUs, 0);
    });

    test('a non-positive duration is unknown, never "ended at once" '
        '(§5.5)', () {
      for (final bogus in [0, -1, -60000000]) {
        final s = HostSession();
        s.setMedia('m_1', nowUs: 0, durationUs: bogus);
        expect(s.currentDurationUs, isNull, reason: '$bogus');
        s.play(nowUs: 0);
        expect(s.hasEnded(10_000_000), isFalse, reason: '$bogus');
        // Clamping against a negative bound used to throw here.
        expect(() => s.seek(5_000_000, nowUs: 0), returnsNormally);
      }
    });

    test('seek is unclamped when the duration is unknown', () {
      final s = playing(durationUs: null);
      final snap = s.seek(7_200_000_000, nowUs: lead + 1);
      expect(snap.anchor!.positionUs, 7_200_000_000);
    });

    test('stop returns to idle, clears media/anchor/duration, bumps rev', () {
      final s = playing();
      final rev = s.snapshot.rev;
      final snap = s.stop(nowUs: lead + dur + 1);
      expect(snap.status, PlaybackStatus.idle);
      expect(snap.mediaId, isNull);
      expect(snap.anchor, isNull);
      expect(snap.positionUs, 0);
      expect(snap.rev, rev + 1);
      expect(s.currentDurationUs, isNull);
      expect(s.hasEnded(lead + dur + 2), isFalse);
    });

    test('stop when already idle with no media is a no-op', () {
      final s = HostSession();
      final before = s.snapshot;
      expect(s.stop(nowUs: 0), same(before));
      expect(s.snapshot.rev, 0);
    });

    test('rev/anchor semantics are unchanged by an in-range duration', () {
      final s = HostSession();
      s.setMedia('m_1', nowUs: 0, durationUs: dur);
      expect(s.snapshot.rev, 1);
      final snap = s.play(nowUs: 1_000_000);
      expect(snap.rev, 2);
      expect(snap.anchor!.hostTimeUs, 1_000_000 + lead);
      expect(snap.anchor!.positionUs, 0);
      final paused = s.pause(nowUs: 1_750_000 + 1_000_000);
      expect(paused.rev, 3);
      expect(paused.positionUs, 1_000_000);
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

    test('peersFetching lists only peers mid-transfer of that item', () {
      final s = HostSession()
        ..upsertPeer('quiet')
        ..setPeerMediaState('busy', 'm_1', MediaReadiness.fetching)
        ..setPeerMediaState('done', 'm_1', MediaReadiness.ready)
        ..setPeerMediaState('gaveUp', 'm_1', MediaReadiness.none)
        ..setPeerMediaState('other', 'm_2', MediaReadiness.fetching);
      expect(s.peersFetching('m_1'), {'busy'});
      s.setPeerMediaState('busy', 'm_1', MediaReadiness.ready);
      expect(s.peersFetching('m_1'), isEmpty);
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
