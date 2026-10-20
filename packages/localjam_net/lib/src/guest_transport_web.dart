/// The guest transport in a browser (see `guest_transport.dart`): the
/// browser's `WebSocket` for the control plane and `fetch` for the media
/// plane (PROTOCOL.md §1), through `package:web`.
///
/// What a browser decides for the page, and why the protocol does not mind:
///
/// - A page cannot set headers on a WebSocket upgrade. Nothing is lost: the
///   session token travels in `hello` (§3.1), not in the upgrade.
/// - A page cannot stop the browser offering `permessage-deflate`. The host
///   never accepts it (§1, §9.1), so the socket runs uncompressed anyway.
/// - A page can only close a WebSocket with 1000 or 3000–4999; any other
///   code ([JamCloseCode.goingAway]) is sent as 1000.
/// - `Connection: close` (§6.2, §9.1) is the browser's business; `fetch`
///   copes with it.
/// - `fetch` shows no upload progress, so uploads (§6.4) go as one body.
///
/// Bounds kept from the native transport: an upgrade or a request that has
/// no answer within its timeout is aborted (an [AbortController] per
/// request) and fails with [TimeoutException]; at most `maxConnections`
/// media-plane requests are open at once, the rest wait their turn (§6.2);
/// bodies are read with `response.body.getReader()`, so the client's idle
/// bound between chunks and its progress reports work as they do natively.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'guest_errors.dart';
import 'guest_transport.dart';

/// The browser transport.
JamGuestTransport createGuestTransport({
  required Duration timeout,
  required int maxConnections,
}) => _WebGuestTransport(timeout, maxConnections);

class _WebGuestTransport implements JamGuestTransport {
  _WebGuestTransport(this._timeout, int maxConnections)
    : _slots = _Slots(maxConnections);

  final Duration _timeout;
  final _Slots _slots;

  /// Requests in flight, so [close] can abort them.
  final Set<web.AbortController> _inFlight = {};
  bool _closed = false;

  @override
  Future<JamControlSocket> connectControl(
    Uri uri, {
    required Duration timeout,
  }) {
    final web.WebSocket ws;
    try {
      ws = web.WebSocket('$uri');
    } catch (e) {
      // A malformed URL (or a blocked port) throws synchronously.
      return Future.error(
        JamTransportException('WebSocket to $uri refused: $e', cause: e),
      );
    }
    final socket = _WebControlSocket(ws, uri);
    return socket._opened.future.timeout(
      timeout,
      onTimeout: () {
        // Closing a socket that is still connecting abandons the attempt:
        // the browser never completes the upgrade, so there is nothing left
        // to sit in the host's pre-hello slots.
        socket._abandon();
        throw TimeoutException('WebSocket to $uri did not open', timeout);
      },
    );
  }

  @override
  Future<JamMediaResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) => _fetch('GET', uri, headers, null, _timeout);

  @override
  Future<JamMediaResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required int contentLength,
    required Stream<List<int>> body,
    required Duration responseTimeout,
    void Function(int sentBytes)? onSent,
  }) async {
    // `fetch` cannot stream a request body over HTTP/1.1, and would not
    // report its progress if it could: collect it (exactly contentLength
    // bytes, as a native request would insist), then send it whole.
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      if (builder.length + chunk.length > contentLength) {
        throw ArgumentError.value(
          contentLength,
          'contentLength',
          'the body is longer',
        );
      }
      builder.add(chunk);
    }
    if (builder.length != contentLength) {
      throw ArgumentError.value(
        contentLength,
        'contentLength',
        'the body is ${builder.length} bytes',
      );
    }
    // The browser sets Content-Length from the body itself (a page may not).
    final sendHeaders = {
      for (final entry in headers.entries)
        if (entry.key.toLowerCase() != 'content-length') entry.key: entry.value,
    };
    // Bounded like the host bounds it (§9.1): the body at the host's
    // progress floor of 32 KB/s, then the native wait for the answer.
    final sendTime = Duration(
      microseconds: contentLength * Duration.microsecondsPerSecond ~/ 32768,
    );
    final response = await _fetch(
      'POST',
      uri,
      sendHeaders,
      builder.takeBytes().toJS,
      sendTime + responseTimeout,
    );
    onSent?.call(contentLength);
    return response;
  }

  Future<JamMediaResponse> _fetch(
    String method,
    Uri uri,
    Map<String, String> headers,
    JSUint8Array? body,
    Duration timeout,
  ) async {
    if (_closed) throw StateError('Client is closed');
    final abort = web.AbortController();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      abort.abort();
    });
    _inFlight.add(abort);
    var slotHeld = false;
    void release() {
      _inFlight.remove(abort);
      if (slotHeld) {
        slotHeld = false;
        _slots.release();
      }
    }

    try {
      // Waiting for a free connection counts against the timeout, as it
      // does natively (`HttpClient.getUrl` waits for one).
      await _slots.acquire(abort.signal);
      slotHeld = true;
      final requestHeaders = web.Headers();
      headers.forEach((name, value) => requestHeaders.append(name, value));
      final init = web.RequestInit(
        method: method,
        headers: requestHeaders,
        signal: abort.signal,
        // Media is verified by sha256 and cached by the client, never by
        // the browser's HTTP cache (and covers are fetched with a bearer).
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
      );
      if (body != null) init.body = body;
      final response = await web.window.fetch('$uri'.toJS, init).toDart;
      timer.cancel();
      return _WebMediaResponse(response, uri, abort, release);
    } catch (e) {
      timer.cancel();
      release();
      if (timedOut) {
        throw TimeoutException('$method $uri: no response', timeout);
      }
      if (_closed) throw StateError('Client is closed');
      throw JamTransportException('$method $uri failed: $e', cause: e);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in [..._inFlight]) {
      abort.abort();
    }
    _inFlight.clear();
  }
}

/// A counting semaphore for media-plane connections (§6.2), whose waiters
/// leave the queue when their request is aborted.
class _Slots {
  _Slots(this._free);

  int _free;
  final Queue<Completer<void>> _waiters = Queue();

  Future<void> acquire(web.AbortSignal signal) {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    signal.onabort = ((web.Event _) {
      if (_waiters.remove(waiter)) {
        waiter.completeError(StateError('aborted while queued'));
      }
    }).toJS;
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _free++;
    }
  }
}

class _WebMediaResponse implements JamMediaResponse {
  _WebMediaResponse(this._response, this._uri, this._abort, this._release);

  final web.Response _response;
  final Uri _uri;
  final web.AbortController _abort;
  final void Function() _release;
  bool _bodyTaken = false;
  bool _done = false;

  @override
  int get statusCode => _response.status;

  @override
  int get contentLength =>
      int.tryParse(_response.headers.get('content-length') ?? '') ?? -1;

  @override
  String? header(String name) => _response.headers.get(name);

  @override
  Stream<List<int>> get body {
    if (_bodyTaken) throw StateError('The body has already been listened to');
    _bodyTaken = true;
    late final StreamController<List<int>> controller;
    web.ReadableStreamDefaultReader? reader;
    var cancelled = false;
    Completer<void>? resumed;

    Future<void> pump() async {
      final stream = _response.body;
      try {
        if (stream == null || _done) return; // No body (or already aborted).
        reader = stream.getReader() as web.ReadableStreamDefaultReader;
        while (!cancelled) {
          if (controller.isPaused) {
            await (resumed = Completer<void>()).future;
            continue;
          }
          final result = await reader!.read().toDart;
          if (cancelled || result.done) break;
          final value = result.value;
          if (value != null) controller.add((value as JSUint8Array).toDart);
        }
      } catch (e) {
        if (!cancelled) {
          controller.addError(
            JamTransportException('$_uri: body failed: $e', cause: e),
          );
        }
      } finally {
        _finish();
        if (!cancelled) await controller.close();
      }
    }

    controller = StreamController<List<int>>(
      onListen: () => unawaited(pump()),
      onResume: () => resumed?.complete(),
      onCancel: () {
        cancelled = true;
        resumed?.complete();
        // Aborting rejects the pending read, which [pump] swallows, and
        // drops the connection: nothing more arrives.
        abort();
      },
    );
    return controller.stream;
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _release();
  }

  @override
  void abort() {
    if (!_done) _abort.abort();
    _finish();
  }
}

class _WebControlSocket implements JamControlSocket {
  _WebControlSocket(this._ws, this._uri) {
    // Binary frames (never sent, §1) arrive as bytes, not as Blobs.
    _ws.binaryType = 'arraybuffer';
    _ws.onopen = ((web.Event _) {
      if (!_opened.isCompleted) _opened.complete(this);
    }).toJS;
    _ws.onmessage = ((web.MessageEvent event) {
      if (_frames.isClosed) return;
      final data = event.data;
      if (data.isA<JSString>()) {
        _frames.add((data as JSString).toDart);
      } else if (data.isA<JSArrayBuffer>()) {
        _frames.add((data as JSArrayBuffer).toDart.asUint8List());
      }
    }).toJS;
    _ws.onerror = ((web.Event _) {
      // A browser says nothing about why; a close event always follows.
      _fail('WebSocket to $_uri failed');
    }).toJS;
    _ws.onclose = ((web.CloseEvent event) {
      _closeCode = event.code;
      _closeReason = event.reason;
      _fail('WebSocket to $_uri closed (${event.code}) before it opened');
      if (!_frames.isClosed) unawaited(_frames.close());
      if (!_closedSignal.isCompleted) _closedSignal.complete();
    }).toJS;
  }

  final web.WebSocket _ws;
  final Uri _uri;
  final Completer<JamControlSocket> _opened = Completer();
  final StreamController<Object?> _frames = StreamController();
  final Completer<void> _closedSignal = Completer();
  int? _closeCode;
  String? _closeReason;

  void _fail(String message) {
    if (!_opened.isCompleted) {
      _opened.completeError(JamTransportException(message));
    }
  }

  /// Gives up on a socket that has not opened.
  void _abandon() {
    try {
      _ws.close();
    } catch (_) {}
  }

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  bool get isOpen => _ws.readyState == web.WebSocket.OPEN;

  @override
  void send(String text) {
    if (!isOpen) throw StateError('WebSocket is not open');
    _ws.send(text.toJS);
  }

  @override
  Future<void> close(int code, [String? reason]) {
    if (_ws.readyState != web.WebSocket.CLOSED) {
      // Pages may only send 1000 or 3000–4999.
      final allowed = code == 1000 || (code >= 3000 && code <= 4999);
      try {
        if (reason != null) {
          _ws.close(allowed ? code : 1000, reason);
        } else {
          _ws.close(allowed ? code : 1000);
        }
      } catch (_) {
        // A reason over 123 bytes is a SyntaxError: close without it.
        _ws.close(allowed ? code : 1000);
      }
    }
    return _closedSignal.future;
  }

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;
}
