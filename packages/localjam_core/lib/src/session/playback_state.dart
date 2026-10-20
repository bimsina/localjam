import 'package:meta/meta.dart';

/// Playback status as broadcast by the host (PROTOCOL.md §5.1). The wire
/// string is the value's [name].
enum PlaybackStatus {
  idle,
  loading,
  playing,
  paused;

  /// The status [wire] names. A status from a later protocol version decodes
  /// as [loading]: the host is doing something this guest cannot follow, so
  /// it makes no sound, holds the frozen `positionUs`, and converges on the
  /// next snapshot it does understand (§2) — instead of dropping the whole
  /// `state` (or `welcome`) frame.
  static PlaybackStatus fromWire(String wire) {
    for (final status in values) {
      if (status.name == wire) return status;
    }
    return loading;
  }
}

/// The anchor ties a media position to an instant on the session clock:
/// while playing, `position(t) = positionUs + (t - hostTimeUs) * rate`.
@immutable
class PlaybackAnchor {
  const PlaybackAnchor({required this.hostTimeUs, required this.positionUs});

  /// Session-clock time (host monotonic clock, microseconds).
  final int hostTimeUs;

  /// Media position (microseconds) at [hostTimeUs].
  final int positionUs;

  Map<String, Object?> toJson() => {
    'hostTime': hostTimeUs,
    'positionUs': positionUs,
  };

  factory PlaybackAnchor.fromJson(Map<String, Object?> json) => PlaybackAnchor(
    hostTimeUs: json['hostTime'] as int,
    positionUs: json['positionUs'] as int,
  );

  @override
  bool operator ==(Object other) =>
      other is PlaybackAnchor &&
      other.hostTimeUs == hostTimeUs &&
      other.positionUs == positionUs;

  @override
  int get hashCode => Object.hash(hostTimeUs, positionUs);
}

/// Full playback state snapshot (PROTOCOL.md §5.1). Host is the only writer;
/// every mutation broadcasts a complete new snapshot with a higher [rev].
@immutable
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.rev,
    required this.status,
    this.mediaId,
    this.anchor,
    this.positionUs = 0,
    this.rate = 1.0,
  });

  static const initial = PlaybackSnapshot(rev: 0, status: PlaybackStatus.idle);

  /// The playback rates a snapshot may carry (§5.1): `[1/32, 32]`, the range
  /// every audio engine behind the protocol accepts. [PlaybackSnapshot.fromJson]
  /// refuses a rate outside it — a snapshot is the one thing every guest
  /// computes from on every tick, so a hostile or broken `rate` must not get
  /// past the decoder.
  static const double minRate = 1 / 32;
  static const double maxRate = 32;

  /// Where [positionAt] saturates: 2^53 µs (~285 years), the largest span
  /// a double still counts in whole microseconds. No real position comes
  /// near it; it only bounds what an absurd anchor can make the formula say.
  /// A literal, not `1 << 53`: compiled to JS (the browser guest, §1.1) a
  /// shift is 32-bit and that is 0, which saturated every playing position
  /// to 0.
  static const int maxPositionUs = 9007199254740992;

  final int rev;
  final PlaybackStatus status;
  final String? mediaId;

  /// Set when [status] is [PlaybackStatus.playing].
  final PlaybackAnchor? anchor;

  /// The frozen position when paused/loading; ignored while playing.
  final int positionUs;

  final double rate;

  /// Where playback should be at session-clock time [hostTimeUs].
  /// Clamps to the anchor position for times before a scheduled start.
  ///
  /// Total: saturates at ±[maxPositionUs] instead of throwing, whatever the
  /// anchor and [rate] say. Guests call this on every drift tick (§5.4), so
  /// a value that made it throw would stop every one of them at once.
  int positionAt(int hostTimeUs) {
    final a = anchor;
    if (status != PlaybackStatus.playing || a == null) return positionUs;
    final elapsed = hostTimeUs - a.hostTimeUs;
    if (elapsed <= 0) return a.positionUs;
    final delta = elapsed * rate;
    if (delta.isNaN) return a.positionUs;
    // Checked in floating point first: `round()` throws on infinities and on
    // anything past the int64 range, and an in-range delta can still
    // overflow when added to an extreme anchor position.
    final exact = a.positionUs + delta;
    if (exact.abs() >= maxPositionUs || delta.abs() >= maxPositionUs) {
      return exact.isNegative ? -maxPositionUs : maxPositionUs;
    }
    return a.positionUs + delta.round();
  }

  /// [positionAt], clamped to `[0, durationUs]` when [durationUs] is known
  /// (PROTOCOL.md §5.5). With a null [durationUs] this is plain [positionAt]:
  /// the anchor formula extrapolates forever, and without a duration there is
  /// nothing to clamp against.
  int clampedPositionAt(int hostTimeUs, {int? durationUs}) {
    final position = positionAt(hostTimeUs);
    if (durationUs == null) return position;
    if (position <= 0) return 0;
    return position >= durationUs ? durationUs : position;
  }

  PlaybackSnapshot copyWith({
    required int rev,
    PlaybackStatus? status,
    String? mediaId,
    bool clearMedia = false,
    PlaybackAnchor? anchor,
    bool clearAnchor = false,
    int? positionUs,
    double? rate,
  }) => PlaybackSnapshot(
    rev: rev,
    status: status ?? this.status,
    mediaId: clearMedia ? null : (mediaId ?? this.mediaId),
    anchor: clearAnchor ? null : (anchor ?? this.anchor),
    positionUs: positionUs ?? this.positionUs,
    rate: rate ?? this.rate,
  );

  Map<String, Object?> toJson() => {
    'rev': rev,
    'status': status.name,
    'mediaId': mediaId,
    'anchor': anchor?.toJson(),
    'positionUs': positionUs,
    'rate': rate,
  };

  /// Decodes a §5.1 snapshot. Throws [FormatException] for a `rate` that is
  /// not a finite number in [[minRate], [maxRate]] (absent means 1.0): that
  /// is not a value from a later protocol version but a broken one, and the
  /// codec drops the frame that carried it (§2.1).
  factory PlaybackSnapshot.fromJson(Map<String, Object?> json) =>
      PlaybackSnapshot(
        rev: json['rev'] as int,
        status: PlaybackStatus.fromWire(json['status'] as String),
        mediaId: json['mediaId'] as String?,
        anchor: json['anchor'] == null
            ? null
            : PlaybackAnchor.fromJson(json['anchor'] as Map<String, Object?>),
        positionUs: (json['positionUs'] as int?) ?? 0,
        rate: _rateFromJson(json['rate'] as num?),
      );

  static double _rateFromJson(num? wire) {
    final rate = (wire ?? 1.0).toDouble();
    // Negated rather than `rate < minRate || ...`: NaN fails every
    // comparison, so only this form refuses it too.
    if (!(rate >= minRate && rate <= maxRate)) {
      throw FormatException('rate must be in [$minRate, $maxRate]', wire);
    }
    return rate;
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackSnapshot &&
      other.rev == rev &&
      other.status == status &&
      other.mediaId == mediaId &&
      other.anchor == anchor &&
      other.positionUs == positionUs &&
      other.rate == rate;

  @override
  int get hashCode =>
      Object.hash(rev, status, mediaId, anchor, positionUs, rate);
}
