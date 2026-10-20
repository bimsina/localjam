/// The guest's view of the network (PROTOCOL.md §1): one control-plane
/// WebSocket and media-plane HTTP requests, behind an interface with a
/// `dart:io` implementation for native platforms and a `package:web` one
/// (browser `WebSocket` and `fetch`) for browsers, picked by conditional
/// import. `JamGuestClient` talks only to this, never to `dart:io`, which is
/// what lets it compile for the web.
///
/// What stays in the client, the same on every platform: which candidate to
/// try (§1 Discovery), the handshake and liveness (§3.1, §3.3), the idle
/// bound between body chunks (§6.2, a [Stream.timeout] on
/// [JamMediaResponse.body]), size and digest checks, and `media_status` reports (§6.3). What
/// the transport owns: opening connections, the bound up to response
/// headers, and how many media-plane connections are open at once (§6.2:
/// `JamGuestClient.maxConnectionsToHost`).
library;

import 'dart:async';

import 'guest_transport_stub.dart'
    if (dart.library.io) 'guest_transport_io.dart'
    if (dart.library.js_interop) 'guest_transport_web.dart'
    as platform;

/// WebSocket close codes the guest uses (RFC 6455 §7.4.1).
abstract final class JamCloseCode {
  /// The guest is done with the connection.
  static const int normalClosure = 1000;

  /// The guest no longer wants a connection that completed too late (a
  /// candidate that answered after its connect timeout). Browsers only let
  /// a page send 1000 or 3000–4999, so the web transport sends 1000 instead.
  static const int goingAway = 1001;
}

/// One control-plane WebSocket to the host (§1): JSON text frames both ways.
abstract interface class JamControlSocket {
  /// Frames from the host, as they arrive: a [String] for a text frame, a
  /// `List<int>` for a binary one (which the protocol never sends, §1).
  /// Single-subscription. Done when the socket closes for any reason; an
  /// error event means the connection failed (a close follows).
  Stream<Object?> get frames;

  /// Whether frames can be sent right now.
  bool get isOpen;

  /// Sends one text frame. Throws [StateError] if the socket closed under
  /// the caller — check [isOpen] first; the race is the caller's to absorb.
  void send(String text);

  /// Starts the close handshake with [code] (see [JamCloseCode]) and
  /// completes when the socket is closed. Against a host that is not there
  /// this can take the platform's own close timeout, so callers bound it.
  Future<void> close(int code, [String? reason]);

  /// The close code the connection ended with, once it has (null before,
  /// and when the peer sent none).
  int? get closeCode;

  /// The close reason the connection ended with, once it has.
  String? get closeReason;
}

/// One media-plane response (§6.2, §6.4, §6.5), headers in hand.
abstract interface class JamMediaResponse {
  /// The HTTP status.
  int get statusCode;

  /// The `Content-Length`, or -1 when the host sent none.
  int get contentLength;

  /// The value of response header [name] (case-insensitive), or null.
  String? header(String name);

  /// The body, chunk by chunk. Single-subscription, and must be listened to
  /// (or [abort]ed): the connection — and its slot against the connection
  /// bound — is held until the body ends. Cancelling the subscription
  /// abandons the transfer and closes the connection. Fails with a
  /// transport error when the connection breaks mid-body; it does not time
  /// out on its own — callers bound gaps with [Stream.timeout].
  Stream<List<int>> get body;

  /// Abandons the exchange: tears the connection down without reading
  /// another byte. Idempotent.
  void abort();
}

/// The guest's transport: one per `JamGuestClient` connection, closed with
/// it.
abstract interface class JamGuestTransport {
  /// The platform's transport: `dart:io` on native platforms, `package:web`
  /// in browsers; anywhere else every call throws [UnsupportedError].
  ///
  /// [timeout] bounds each media-plane request from its start until its
  /// response headers arrive — waiting for a free connection, connecting,
  /// and the host's answer (§6.2). [maxConnections] bounds how many
  /// media-plane connections are open to the host at once; requests past it
  /// wait their turn (§6.2, §9.1).
  factory JamGuestTransport({
    required Duration timeout,
    required int maxConnections,
  }) => platform.createGuestTransport(
    timeout: timeout,
    maxConnections: maxConnections,
  );

  /// Opens the control-plane WebSocket at [uri] (`ws://host:port/ws`, §1),
  /// without offering `permessage-deflate` where the platform lets the
  /// guest choose (§1, §9.1; browsers always offer it, and the host never
  /// accepts it). Fails with [TimeoutException] when the upgrade has not
  /// completed within [timeout] — a socket that completes later is closed
  /// with [JamCloseCode.goingAway] rather than left in the host's pre-`hello`
  /// slots — and with a transport error when the host is unreachable.
  Future<JamControlSocket> connectControl(Uri uri, {required Duration timeout});

  /// `GET [uri]` with [headers] (`Authorization: Bearer ...`, and `Range`
  /// when wanted, §6.2). Fails with [TimeoutException] when no response
  /// arrives within the transport's `timeout`.
  Future<JamMediaResponse> get(Uri uri, {Map<String, String> headers});

  /// `POST [uri]` (§6.4) with [headers] and a body of exactly
  /// [contentLength] bytes from [body], sent with that `Content-Length`.
  ///
  /// Where the platform can see the upload's progress (native), a body chunk
  /// the host does not take within `timeout` fails the request with
  /// [TimeoutException], [onSent] reports bytes handed to the connection,
  /// and [responseTimeout] bounds the wait for the host's answer once the
  /// body is sent. In a browser `fetch` shows no upload progress: the body
  /// is collected and sent whole, [onSent] reports it once the answer
  /// arrives, and the whole exchange is bounded by [responseTimeout] plus
  /// the time the body takes at the host's own progress floor (32 KB/s,
  /// §9.1).
  Future<JamMediaResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required int contentLength,
    required Stream<List<int>> body,
    required Duration responseTimeout,
    void Function(int sentBytes)? onSent,
  });

  /// Aborts every media-plane request in flight and refuses new ones.
  /// Control sockets are closed by their own [JamControlSocket.close].
  void close();
}
