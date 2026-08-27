import 'package:meta/meta.dart';

/// Playback status as broadcast by the host (PROTOCOL.md §5.1).
enum PlaybackStatus { idle, loading, playing, paused }

/// The anchor ties a media position to an instant on the session clock:
/// while playing, `position(t) = positionUs + (t - hostTimeUs) * rate`.
@immutable
class PlaybackAnchor {
  const PlaybackAnchor({required this.hostTimeUs, required this.positionUs});

  /// Session-clock time (host monotonic clock, microseconds).
  final int hostTimeUs;

  /// Media position (microseconds) at [hostTimeUs].
  final int positionUs;

  Map<String, Object?> toJson() =>
      {'hostTime': hostTimeUs, 'positionUs': positionUs};

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
  int positionAt(int hostTimeUs) {
    final a = anchor;
    if (status != PlaybackStatus.playing || a == null) return positionUs;
    final elapsed = hostTimeUs - a.hostTimeUs;
    if (elapsed <= 0) return a.positionUs;
    return a.positionUs + (elapsed * rate).round();
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
  }) =>
      PlaybackSnapshot(
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

  factory PlaybackSnapshot.fromJson(Map<String, Object?> json) =>
      PlaybackSnapshot(
        rev: json['rev'] as int,
        status: PlaybackStatus.values.byName(json['status'] as String),
        mediaId: json['mediaId'] as String?,
        anchor: json['anchor'] == null
            ? null
            : PlaybackAnchor.fromJson(json['anchor'] as Map<String, Object?>),
        positionUs: (json['positionUs'] as int?) ?? 0,
        rate: ((json['rate'] as num?) ?? 1.0).toDouble(),
      );

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
