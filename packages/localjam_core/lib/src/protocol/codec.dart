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

  /// Protocol version from the envelope.
  final int v;

  /// Sender-local sequence number (logging/dedup only).
  final int seq;

  final Message message;
}

/// Encodes/decodes the JSON envelope of PROTOCOL.md §2:
///
/// ```json
/// { "v": 1, "type": "play", "seq": 42, "payload": { ... } }
/// ```
///
/// Decoding rules (forward compatibility, §2):
///
/// - An unknown `type` does NOT throw: it decodes to an [UnknownMessage]
///   carrying the raw type string and payload, so callers can log and ignore.
/// - Unknown payload fields on known types are silently ignored.
/// - Malformed input (bad JSON, wrong envelope shape, or a known type whose
///   payload is invalid) throws [ProtocolException].
class MessageCodec {
  const MessageCodec();

  /// The protocol version this codec speaks.
  static const protocolVersion = 1;

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
    if (seq is! int) {
      throw ProtocolException('Envelope "seq" is missing or not an int');
    }

    final rawPayload = envelope['payload'];
    final payload = rawPayload is Map
        ? rawPayload.cast<String, Object?>()
        : <String, Object?>{};

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
