import 'dart:convert';

import 'package:meta/meta.dart';

import 'messages.dart';

/// Thrown by [MessageCodec.decode] when the input is not a well-formed
/// LocalJam envelope: malformed JSON, a non-object frame, missing/mistyped
/// envelope fields, or a known type whose payload does not fit its schema.
class ProtocolException implements Exception {
  const ProtocolException(this.message, [this.cause]);

  final String message;

  /// The underlying error, when the failure came from parsing.
  final Object? cause;

  @override
  String toString() =>
      'ProtocolException: $message${cause == null ? '' : ' ($cause)'}';
}

/// A decoded control-plane frame: envelope fields plus the typed [message].
@immutable
class DecodedMessage {
  const DecodedMessage({
    required this.v,
    required this.seq,
    required this.message,
  });

  /// Major protocol version from the envelope (§2).
  final int v;

  /// Sender-local sequence number (logging/dedup only).
  final int seq;

  /// The typed message — or, for a frame of another major version
  /// ([isSupportedVersion] false), an [UnknownMessage] carrying the raw type
  /// and payload: another major version's schema is not this codec's to
  /// guess at.
  final Message message;

  /// Whether [v] is a major version this codec speaks (§2). A host answers a
  /// `hello` that is not with `reject { reason: "version" }`; a guest treats
  /// any handshake reply that is not as a version reject.
  bool get isSupportedVersion => MessageCodec.supportsVersion(v);
}

/// Encodes/decodes the JSON envelope of PROTOCOL.md §2:
///
/// ```json
/// { "v": 1, "type": "play", "seq": 42, "payload": { ... } }
/// ```
///
/// Decoding rules (PROTOCOL.md §2):
///
/// - `v` is the MAJOR protocol version. A frame of a major version this
///   codec does not speak is not decoded beyond its envelope: it comes back
///   as an [UnknownMessage] with [DecodedMessage.isSupportedVersion] false,
///   and the caller applies the version gate. Only `v` and `type` are
///   required of such a frame — they are the part of the envelope every
///   major version keeps.
/// - Within a major version decoding is tolerant, so a later 1.x never
///   breaks a 1.0 peer: an unknown `type` decodes to an [UnknownMessage]
///   (callers log and ignore it), unknown payload fields are ignored, and
///   unknown enum values decode to a fallback or are skipped (see each
///   enum's `fromWire`, [MediaItem.tryFromJson]).
/// - Malformed input (bad JSON, wrong envelope shape, or a known type whose
///   payload does not fit its schema) throws [ProtocolException].
class MessageCodec {
  const MessageCodec();

  /// The major protocol version this codec speaks: LocalJam protocol 1.
  static const protocolVersion = 1;

  /// Whether this codec speaks major version [v].
  static bool supportsVersion(int v) => v == protocolVersion;

  /// Encodes [message] with envelope fields into a JSON string.
  String encode(Message message, {required int seq, int v = protocolVersion}) {
    return jsonEncode({
      'v': v,
      'type': message.type,
      'seq': seq,
      'payload': message.payloadToJson(),
    });
  }

  /// Decodes an incoming JSON text frame.
  ///
  /// See the class docs for unknown-type and error behavior.
  DecodedMessage decode(String text) {
    Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException catch (e) {
      throw ProtocolException('Malformed JSON frame', e);
    }
    if (root is! Map) {
      throw ProtocolException('Envelope is not a JSON object');
    }
    final envelope = root.cast<String, Object?>();

    final v = envelope['v'];
    final type = envelope['type'];
    final seq = envelope['seq'];
    if (v is! int) {
      throw ProtocolException('Envelope "v" is missing or not an int');
    }
    if (type is! String) {
      throw ProtocolException('Envelope "type" is missing or not a string');
    }

    final rawPayload = envelope['payload'];
    final payload = rawPayload is Map
        ? rawPayload.cast<String, Object?>()
        : <String, Object?>{};

    if (!supportsVersion(v)) {
      // §2 version gate: the envelope is all this codec can vouch for. The
      // caller decides (reject the hello, refuse the welcome, ignore).
      return DecodedMessage(
        v: v,
        seq: seq is int ? seq : 0,
        message: UnknownMessage(type: type, payload: payload),
      );
    }
    if (seq is! int) {
      throw ProtocolException('Envelope "seq" is missing or not an int');
    }

    final Message message;
    try {
      message = _decodePayload(type, payload);
    } on ProtocolException {
      rethrow;
    } catch (e) {
      throw ProtocolException('Invalid payload for "$type"', e);
    }
    return DecodedMessage(v: v, seq: seq, message: message);
  }

  Message _decodePayload(String type, Map<String, Object?> payload) {
    switch (type) {
      case HelloMessage.wireType:
        return HelloMessage.fromPayload(payload);
      case WelcomeMessage.wireType:
        return WelcomeMessage.fromPayload(payload);
      case RejectMessage.wireType:
        return RejectMessage.fromPayload(payload);
      case PeerJoinedMessage.wireType:
        return PeerJoinedMessage.fromPayload(payload);
      case PeerLeftMessage.wireType:
        return PeerLeftMessage.fromPayload(payload);
      case SessionEndedMessage.wireType:
        return SessionEndedMessage.fromPayload(payload);
      case HostStatusMessage.wireType:
        return HostStatusMessage.fromPayload(payload);
      case ClockPingMessage.wireType:
        return ClockPingMessage.fromPayload(payload);
      case ClockPongMessage.wireType:
        return ClockPongMessage.fromPayload(payload);
      case RequestMessage.wireType:
        return RequestMessage.fromPayload(payload);
      case StateMessage.wireType:
        return StateMessage.fromPayload(payload);
      case PlaylistMessage.wireType:
        return PlaylistMessage.fromPayload(payload);
      case PermissionsMessage.wireType:
        return PermissionsMessage.fromPayload(payload);
      case MediaStatusMessage.wireType:
        return MediaStatusMessage.fromPayload(payload);
      case ErrorMessage.wireType:
        return ErrorMessage.fromPayload(payload);
      default:
        return UnknownMessage(type: type, payload: payload);
    }
  }
}
