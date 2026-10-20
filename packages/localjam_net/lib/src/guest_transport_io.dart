/// The guest transport on native platforms (see `guest_transport.dart`):
/// `dart:io`'s [WebSocket] and [HttpClient], configured exactly as the guest
/// used them before the transport was split out — so native behaviour, and
/// the errors native callers see, are unchanged.
library;

import 'dart:async';
import 'dart:io';

import 'guest_transport.dart';

/// The `dart:io` transport.
JamGuestTransport createGuestTransport({
  required Duration timeout,
  required int maxConnections,
}) => _IoGuestTransport(timeout, maxConnections);

class _IoGuestTransport implements JamGuestTransport {
  _IoGuestTransport(this._timeout, int maxConnections)
    : _http = HttpClient()
        ..maxConnectionsPerHost = maxConnections
        ..connectionTimeout = _timeout;

  final Duration _timeout;

  /// Media, artwork and uploads share this client, and with it the bound on
  /// connections to the host (§6.2, §9.1): requests past it wait for a
  /// connection inside `getUrl`/`postUrl`, which [_timeout] bounds too.
  /// Every exchange is one request per connection as far as the guest
  /// cares — `HttpClient` copes with the host's `Connection: close`.
  final HttpClient _http;

  @override
  Future<JamControlSocket> connectControl(
    Uri uri, {
    required Duration timeout,
  }) async {
    // No permessage-deflate: control frames are small JSON (§1), and the
    // host does not offer it either (§9.1).
    final pending = WebSocket.connect(
      '$uri',
      compression: CompressionOptions.compressionOff,
    );
    try {
      return _IoControlSocket(await pending.timeout(timeout));
    } catch (_) {
      // A host that was merely asleep may still complete this upgrade
      // later; a socket nobody listens to would sit in its pre-hello slots
      // until its hello timeout. Close it if it ever arrives.
      unawaited(
        pending.then(
          (late) => late.close(JamCloseCode.goingAway),
          onError: (Object _) {},
        ),
      );
      rethrow;
    }
  }

  @override
  Future<JamMediaResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final request = await _http.getUrl(uri).timeout(_timeout);
    headers.forEach(request.headers.set);
    try {
      return _IoMediaResponse(
        await request.close().timeout(_timeout),
        request.abort,
      );
    } on TimeoutException {
      request.abort();
      rethrow;
    }
  }

  @override
  Future<JamMediaResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required int contentLength,
    required Stream<List<int>> body,
    required Duration responseTimeout,
    void Function(int sentBytes)? onSent,
  }) async {
    final request = await _http.postUrl(uri).timeout(_timeout);
    headers.forEach(request.headers.set);
    request.contentLength = contentLength;
    try {
      var sent = 0;
      await for (final chunk in body) {
        request.add(chunk);
        // Flush per chunk: backpressure keeps memory flat and makes progress
        // reflect bytes actually handed to the socket — and a host that
        // stops reading shows up here, as a flush that never completes.
        await request.flush().timeout(_timeout);
        sent += chunk.length;
        onSent?.call(sent);
      }
      return _IoMediaResponse(
        await request.close().timeout(responseTimeout),
        request.abort,
      );
    } on TimeoutException {
      request.abort();
      rethrow;
    }
  }

  @override
  void close() => _http.close(force: true);
}

class _IoControlSocket implements JamControlSocket {
  _IoControlSocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<Object?> get frames => _ws;

  @override
  bool get isOpen => _ws.readyState == WebSocket.open;

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close(int code, [String? reason]) => _ws.close(code, reason);

  @override
  int? get closeCode => _ws.closeCode;

  @override
  String? get closeReason => _ws.closeReason;
}

class _IoMediaResponse implements JamMediaResponse {
  _IoMediaResponse(this._response, this._abort);

  final HttpClientResponse _response;
  final void Function([Object? exception, StackTrace? stackTrace]) _abort;

  @override
  int get statusCode => _response.statusCode;

  @override
  int get contentLength => _response.contentLength;

  @override
  String? header(String name) => _response.headers[name]?.join(', ');

  @override
  Stream<List<int>> get body => _response;

  @override
  void abort() => _abort();
}
