/// Admission control for the host's one listening port (PROTOCOL.md §9.1):
/// how many TCP connections it holds, from whom, and how many bytes a
/// connection may send before it has proved it holds the session token.
///
/// This exists because `dart:io` bounds too little of it. Its HTTP parser
/// keeps a request's header block in growable integer lists — eight bytes
/// of host memory per byte received — up to a 1 MiB limit per connection,
/// with no limit on connections; its WebSocket reassembles a whole message,
/// of any size, before anyone can look at it. A hundred unauthenticated
/// sockets each sending just under a megabyte of "header" cost the host
/// ~900 MB (measured); eight pre-`hello` sockets each streaming a 100 MB
/// frame, ~540 MB. The guard sits between the listening socket and
/// `HttpServer` and counts raw bytes, the only place the count is honest.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Counts and admits connections; see the library comment.
class ConnectionGuard {
  ConnectionGuard({
    required this.maxConnections,
    required this.maxConnectionsPerRemote,
    required this.maxHeaderBytes,
    required this.headerTimeout,
    required this.admitRemote,
    this.admitLocal,
  });

  /// Upper bound on TCP connections open at once, of every kind.
  final int maxConnections;

  /// Upper bound on TCP connections open at once from one remote address.
  final int maxConnectionsPerRemote;

  /// Upper bound on the bytes of a connection's request line and headers.
  final int maxHeaderBytes;

  /// How long a connection may take to deliver its complete header block.
  final Duration headerTimeout;

  /// Whether a remote may connect at all (§9: on-LAN only). Asked once per
  /// connection, before a single byte of it is parsed.
  final bool Function(InternetAddress remote) admitRemote;

  /// Whether a connection that arrived on local address `local` may be
  /// served at all — a wildcard bind listens on every interface, cellular
  /// and tunnels included (§9). Asked once per connection, like
  /// [admitRemote]; null admits every local address.
  final bool Function(InternetAddress local)? admitLocal;

  int _open = 0;
  final Map<String, int> _perRemote = {};

  /// Live guarded sockets by `address:port`, so a request handler can find
  /// the connection an [HttpRequest] arrived on (see [socketFor]).
  final Map<String, GuardedSocket> _byEndpoint = {};

  /// Connections currently admitted and not yet closed.
  int get openConnections => _open;

  /// [server], with every accepted socket admitted (or refused) here first.
  ServerSocket wrap(ServerSocket server) => _GuardedServerSocket(server, this);

  /// The guarded socket [info] describes, if it is still open.
  GuardedSocket? socketFor(HttpConnectionInfo? info) {
    if (info == null) return null;
    return _byEndpoint[_endpointKey(info.remoteAddress, info.remotePort)];
  }

  static String _endpointKey(InternetAddress address, int port) =>
      '${address.address}:$port';

  /// Admits [socket] as a [GuardedSocket], or refuses it and returns null.
  GuardedSocket? _admit(Socket socket) {
    final InternetAddress remote;
    final int remotePort;
    final InternetAddress local;
    try {
      remote = socket.remoteAddress;
      remotePort = socket.remotePort;
      local = socket.address;
    } catch (_) {
      socket.destroy(); // Already gone.
      return null;
    }
    if (!admitRemote(remote) || !(admitLocal?.call(local) ?? true)) {
      _refuse(socket, HttpStatus.forbidden, 'Forbidden');
      return null;
    }
    final key = remote.address;
    final fromRemote = _perRemote[key] ?? 0;
    if (_open >= maxConnections || fromRemote >= maxConnectionsPerRemote) {
      _refuse(socket, HttpStatus.serviceUnavailable, 'Service Unavailable');
      return null;
    }
    _open++;
    _perRemote[key] = fromRemote + 1;
    final endpoint = _endpointKey(remote, remotePort);
    final guarded = GuardedSocket._(socket, this, key, endpoint);
    _byEndpoint[endpoint] = guarded;
    return guarded;
  }

  void _release(GuardedSocket socket) {
    _open--;
    final left = (_perRemote[socket._remoteKey] ?? 1) - 1;
    if (left <= 0) {
      _perRemote.remove(socket._remoteKey);
    } else {
      _perRemote[socket._remoteKey] = left;
    }
    if (identical(_byEndpoint[socket._endpoint], socket)) {
      _byEndpoint.remove(socket._endpoint);
    }
  }

  /// Answers a connection that will not be served with a bare HTTP status
  /// and closes it. Nothing it sends is parsed or kept: the input is drained
  /// into nothing until the close goes out (or a short deadline passes), so
  /// an honest client reads a status instead of a reset.
  static void _refuse(Socket socket, int status, String reason) {
    try {
      socket.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
      socket.add(
        ascii.encode(
          'HTTP/1.1 $status $reason\r\n'
          'Connection: close\r\n'
          'Content-Length: 0\r\n\r\n',
        ),
      );
      final deadline = Timer(const Duration(seconds: 2), socket.destroy);
      unawaited(
        socket.close().then<void>((_) {}, onError: (Object _) {}).whenComplete(
          () {
            deadline.cancel();
            socket.destroy();
          },
        ),
      );
    } catch (_) {
      socket.destroy();
    }
  }
}

/// Where a [GuardedSocket] is in its life, for byte accounting.
enum _Phase {
  /// Receiving the request line and headers: every byte counts against
  /// [ConnectionGuard.maxHeaderBytes].
  headers,

  /// Headers are complete; the request handler owns the connection and its
  /// body (which it streams, never buffers). Nothing is counted.
  request,

  /// An upgraded WebSocket that has not authenticated yet: every byte
  /// counts against the budget given to [GuardedSocket.limitUntilTrusted].
  preAuth,

  /// Proved the token. Nothing is counted.
  trusted,
}

/// One admitted connection: the [Socket] `HttpServer` (and, after an
/// upgrade, the WebSocket) actually reads, with bytes counted per phase.
class GuardedSocket extends Stream<Uint8List> implements Socket {
  GuardedSocket._(this._socket, this._guard, this._remoteKey, this._endpoint) {
    _headerClock = Timer(_guard.headerTimeout, () {
      if (_phase == _Phase.headers) destroy();
    });
    // `done` completes when the WRITE side has closed, which is half of the
    // connection: the descriptor lives until the read side has ended too
    // (see [_readEnded]). A write error, though, means it is gone.
    unawaited(
      _socket.done.then<void>((_) {
        _writeClosed = true;
        _releaseIfGone();
      }, onError: (Object _) => destroy()),
    );
  }

  /// How long a connection this side has closed may wait for the peer to
  /// close its side before it is destroyed (see [close]).
  static const Duration closeLinger = Duration(seconds: 2);

  final Socket _socket;
  final ConnectionGuard _guard;
  final String _remoteKey;
  final String _endpoint;

  _Phase _phase = _Phase.headers;
  int _counted = 0;
  int _budget = 0;
  Timer? _headerClock;
  Timer? _closeClock;
  bool _released = false;

  /// The two halves of the connection. The slot is held until both have
  /// closed, or the socket is destroyed: that is when `dart:io` gives the
  /// descriptor back. A slot freed any earlier lets descriptors pile up
  /// behind a cap that no longer counts them (review 2026-10-17: 14k open
  /// descriptors while the guard counted 13, and a host under a 256
  /// descriptor limit that nobody could reach).
  bool _writeClosed = false;
  bool _readClosed = false;

  /// Bytes that arrived in the same read as the end of the header block.
  /// For an upgrade they are WebSocket frames, which `dart:io` hands to the
  /// WebSocket as they are — so [limitUntilTrusted] has to count them.
  int _afterHeaders = 0;

  /// Set once a budget is blown: input is dropped from then on.
  bool _discarding = false;
  void Function()? _onExceeded;
  Duration _closeGrace = Duration.zero;

  /// Non-CR bytes since the last LF, and whether a non-empty line has been
  /// seen: the header block ends at the first empty line after one. This
  /// matches `dart:io`'s parser, which takes LF as the line terminator and
  /// ignores a CR before it.
  int _lineLength = 0;
  bool _sawLine = false;

  /// From now until [trust], at most [budget] bytes may arrive — counting
  /// those that came in the same read as the end of the request's headers.
  /// For an upgraded control socket that has not said `hello` yet (§3.1).
  ///
  /// Past the budget nothing more is passed on — the bytes are dropped as
  /// they arrive, so whatever was being reassembled stops growing — and
  /// [onExceeded] is called so the owner can say why (a WebSocket close
  /// frame); the connection is destroyed [closeGrace] later regardless.
  /// Without [onExceeded] it is destroyed at once.
  ///
  /// Returns false, having destroyed the connection, when the bytes that
  /// came with the headers are over [budget] by themselves: `dart:io`
  /// already holds them for the WebSocket, so the only way to keep them
  /// from it is not to upgrade at all.
  bool limitUntilTrusted(
    int budget, {
    void Function()? onExceeded,
    Duration closeGrace = const Duration(seconds: 2),
  }) {
    if (_phase == _Phase.trusted) return true;
    _phase = _Phase.preAuth;
    _counted = _afterHeaders;
    _budget = budget;
    _onExceeded = onExceeded;
    _closeGrace = closeGrace;
    if (_counted > budget) {
      _discarding = true;
      destroy();
      return false;
    }
    return true;
  }

  /// The connection proved the token: stop counting.
  void trust() {
    _phase = _Phase.trusted;
    _headerClock?.cancel();
  }

  /// Accounts [chunk]; returns false (having destroyed the connection) when
  /// it breaks the current phase's budget.
  bool _accept(Uint8List chunk) {
    if (_discarding) return false;
    switch (_phase) {
      case _Phase.request:
      case _Phase.trusted:
        return true;
      case _Phase.preAuth:
        _counted += chunk.length;
        if (_counted > _budget) {
          _discarding = true;
          final onExceeded = _onExceeded;
          if (onExceeded == null) {
            destroy();
          } else {
            Timer(_closeGrace, destroy);
            onExceeded();
          }
          return false;
        }
        return true;
      case _Phase.headers:
        for (var i = 0; i < chunk.length; i++) {
          _counted++;
          final byte = chunk[i];
          if (byte == 0x0a) {
            if (_lineLength == 0 && _sawLine) {
              // End of the header block; what follows is the body (or, for
              // an upgrade, WebSocket frames), which is not ours to count.
              _phase = _Phase.request;
              _headerClock?.cancel();
              _afterHeaders = chunk.length - i - 1;
              break;
            }
            if (_lineLength > 0) _sawLine = true;
            _lineLength = 0;
          } else if (byte != 0x0d) {
            _lineLength++;
          }
          if (_counted > _guard.maxHeaderBytes) {
            destroy();
            return false;
          }
        }
        return true;
    }
  }

  void _release() {
    if (_released) return;
    _released = true;
    _headerClock?.cancel();
    _closeClock?.cancel();
    _guard._release(this);
  }

  /// The read side ended: the peer closed its side, or the reader stopped
  /// listening (which makes `dart:io` shut reading down).
  void _readEnded() {
    _readClosed = true;
    _releaseIfGone();
  }

  void _releaseIfGone() {
    if (_readClosed && _writeClosed) _release();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _socket
        .transform(
          StreamTransformer<Uint8List, Uint8List>.fromHandlers(
            handleData: (chunk, sink) {
              if (_accept(chunk)) sink.add(chunk);
            },
            handleError: (error, stackTrace, sink) {
              // A read error is a connection that is gone; make sure of it
              // once the error has been delivered.
              scheduleMicrotask(destroy);
              sink.addError(error, stackTrace);
            },
            handleDone: (sink) {
              _readEnded();
              sink.close();
            },
          ),
        )
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
    return _ReadSubscription(subscription, _readEnded);
  }

  // --- Socket, by delegation -------------------------------------------------

  @override
  void destroy() {
    _release();
    _socket.destroy();
  }

  /// Closes the write side only. The slot stays taken until the read side
  /// has ended too: a WebSocket close handshake leaves it open for as long
  /// as the peer takes to answer (`dart:io` waits up to 5 s), and one that
  /// never answers would otherwise hold a descriptor nothing counts. Past
  /// [closeLinger] the connection is destroyed.
  @override
  Future close() {
    _closeClock ??= Timer(closeLinger, destroy);
    return _socket.close();
  }

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  Future flush() => _socket.flush();

  @override
  Future get done => _socket.done;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}

/// A [GuardedSocket]'s read subscription, reporting when its reader stops
/// listening: `dart:io` shuts the read side down then, and a socket whose
/// write side is closed as well is gone.
class _ReadSubscription implements StreamSubscription<Uint8List> {
  _ReadSubscription(this._inner, this._onCancel);

  final StreamSubscription<Uint8List> _inner;
  final void Function() _onCancel;

  @override
  Future<void> cancel() {
    final cancelled = _inner.cancel();
    _onCancel();
    return cancelled;
  }

  @override
  void onData(void Function(Uint8List data)? handleData) =>
      _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}

/// The listening socket `HttpServer.listenOn` is given: the real one, with
/// every accepted connection passed through [ConnectionGuard._admit].
class _GuardedServerSocket extends Stream<Socket> implements ServerSocket {
  _GuardedServerSocket(this._server, this._guard);

  final ServerSocket _server;
  final ConnectionGuard _guard;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _server
        .transform(
          StreamTransformer<Socket, Socket>.fromHandlers(
            handleData: (socket, sink) {
              final admitted = _guard._admit(socket);
              if (admitted != null) sink.add(admitted);
            },
          ),
        )
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
  }

  @override
  int get port => _server.port;

  @override
  InternetAddress get address => _server.address;

  @override
  Future<ServerSocket> close() async {
    await _server.close();
    return this;
  }
}
