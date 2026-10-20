import 'package:meta/meta.dart';

/// The join parameters a QR code, a shared link, a deep link or a nearby
/// room carries (PROTOCOL.md §1 Discovery / join), in either of its two
/// spellings:
///
/// ```
/// localjam://join?v=1&host=192.168.1.7,192.168.43.1&port=44100&token=<t>&name=RoadTrip
/// http://192.168.1.7:44100/join#v=1&token=<t>&name=RoadTrip&host=192.168.1.7,192.168.43.1
/// ```
///
/// The `localjam://` form is protocol 1.0 and is what "Open in app" deep
/// links use. The http form is 1.2: a phone camera opens it with no app
/// installed, and the host serves its browser player at that very URL
/// (§1.1). Its fragment is a query string with the `localjam://` query's
/// keys and encoding; the fragment never travels in a request or a
/// `Referer`, so the token stays on the device that scanned it.
///
/// This is the one parser for both. It decides what a link *says* and
/// nothing about whether to trust it: the on-LAN rule (§9) is the joiner's
/// to apply to every one of [hosts], whichever form the link came in.
@immutable
class JoinLink {
  JoinLink({
    this.v,
    required this.token,
    this.name,
    required List<String> hosts,
    required this.port,
  }) : hosts = List.unmodifiable(hosts) {
    if (token.isEmpty) throw ArgumentError.value(token, 'token', 'is empty');
    if (this.hosts.isEmpty) {
      throw ArgumentError.value(hosts, 'hosts', 'has no candidates');
    }
    for (final host in this.hosts) {
      if (!_isPlausibleHost(host)) {
        throw ArgumentError.value(host, 'hosts', 'is not a host');
      }
    }
    if (port < 1 || port > 65535) {
      throw RangeError.range(port, 1, 65535, 'port');
    }
    if (v != null && v! < 1) throw RangeError.value(v!, 'v');
  }

  /// The host's major protocol version (§1: a joiner MAY flag rooms it
  /// cannot join; the handshake, §2.1, is authoritative). Null when the
  /// link carries none.
  final int? v;

  /// The session token (§9) — the invitation itself.
  final String token;

  /// The room's display name, as the link carries it (null when absent).
  /// Display text only.
  final String? name;

  /// The candidate addresses a joiner tries in order (§1), never empty. IPv6
  /// literals are bare (`fe80::1`, never `[fe80::1]`); a zone id stays
  /// attached (`fe80::1%en0`).
  final List<String> hosts;

  /// The host's port — one port for every candidate.
  final int port;

  /// The candidate the http form names in its authority: the first one.
  String get primaryHost => hosts.first;

  /// [name] trimmed, or null when it is absent or blank.
  String? get displayName {
    final trimmed = name?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Parses [text] as either join form, or returns null when it is neither.
  ///
  /// Tolerates surrounding whitespace and the `<…>` some chat apps wrap
  /// links in. Everything else must be exact:
  ///
  /// - `localjam://join?…` needs `host` (comma-separated candidates), `port`
  ///   (1–65535) and a non-empty `token`; `v` and `name` are optional.
  /// - `http://host[:port]/join#…` reads `v`, `token`, `name` and `host` from
  ///   the fragment. The port is the URL's (80 when it names none) for every
  ///   candidate; a `port` in the fragment is ignored. Without `host` the
  ///   URL's own host is the sole candidate (an IPv6 literal in brackets
  ///   comes out bare); with it, that list is the whole candidate list. The
  ///   URL's query, if any, is not read. Only `http`: a browser on an `https`
  ///   page could not reach a plain LAN host anyway (§9).
  ///
  /// A `v` that is not a positive integer, a malformed percent-escape, an
  /// empty candidate list or a candidate that cannot be a host makes the
  /// whole link invalid.
  static JoinLink? parse(String text) {
    var raw = text.trim();
    if (raw.length >= 2 && raw.startsWith('<') && raw.endsWith('>')) {
      raw = raw.substring(1, raw.length - 1).trim();
    }
    if (raw.isEmpty) return null;
    // `Uri.parse` quietly re-escapes a stray `%` (`%zz` → `%25zz`), which
    // would turn a mangled token into a different, wrong one.
    if (_badEscape.hasMatch(raw)) return null;
    final uri = Uri.tryParse(raw);
    return uri == null ? null : fromUri(uri);
  }

  static final RegExp _badEscape = RegExp(r'%(?![0-9A-Fa-f]{2})');

  /// [parse] for an already-parsed [uri] (a deep link, a scanned code).
  static JoinLink? fromUri(Uri uri) {
    try {
      switch (uri.scheme.toLowerCase()) {
        case 'localjam':
          return _fromLocaljam(uri);
        case 'http':
          return _fromHttp(uri);
        default:
          return null;
      }
    } on FormatException {
      return null; // Bad percent-encoding somewhere.
    } on ArgumentError {
      return null; // Uri's decoders throw these for bad escapes too.
    }
  }

  static JoinLink? _fromLocaljam(Uri uri) {
    if (uri.host.toLowerCase() != 'join') return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    final params = uri.queryParameters;
    final port = _port(params['port']);
    if (port == null) return null;
    return _build(params, port: port, fallbackHost: null);
  }

  static JoinLink? _fromHttp(Uri uri) {
    if (uri.path != '/join') return null;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    final port = uri.port;
    if (port < 1 || port > 65535) return null;
    // `Uri.host` keeps a zone id's `%25` escaped and lowercases names.
    final own = Uri.decodeComponent(uri.host);
    return _build(
      Uri.splitQueryString(uri.fragment),
      port: port,
      fallbackHost: own,
    );
  }

  static JoinLink? _build(
    Map<String, String> params, {
    required int port,
    required String? fallbackHost,
  }) {
    final token = params['token'];
    if (token == null || token.isEmpty) return null;
    final vText = params['v'];
    int? v;
    if (vText != null) {
      v = int.tryParse(vText.trim());
      if (v == null || v < 1) return null;
    }
    final hostParam = params['host'];
    final List<String> hosts;
    if (hostParam == null) {
      if (fallbackHost == null) return null;
      hosts = [fallbackHost];
    } else {
      hosts = [
        for (final h in hostParam.split(','))
          if (h.trim().isNotEmpty) _unbracket(h.trim()),
      ];
    }
    if (hosts.isEmpty || !hosts.every(_isPlausibleHost)) return null;
    return JoinLink(
      v: v,
      token: token,
      name: params['name'],
      hosts: hosts,
      port: port,
    );
  }

  static int? _port(String? text) {
    final port = int.tryParse(text?.trim() ?? '');
    return (port == null || port < 1 || port > 65535) ? null : port;
  }

  static String _unbracket(String host) =>
      host.length > 2 && host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;

  /// A candidate is an IP literal or a DNS name: no whitespace, nothing that
  /// would change what a URL built from it means (`/`, `?`, `#`, `@`,
  /// brackets). Whether it is on the LAN is the joiner's question (§9).
  static bool _isPlausibleHost(String host) =>
      host.isNotEmpty && !_notInHost.hasMatch(host);

  static final RegExp _notInHost = RegExp(r'[\s/?#@\[\]\\,<>"]');

  /// The `localjam://join?…` form (§1), for "Open in app" deep links and
  /// for joiners that predate 1.2. Keys in the order hosts have always
  /// written them: `v`, `host`, `port`, `token`, `name`.
  Uri toLocaljamUri() => Uri(
    scheme: 'localjam',
    host: 'join',
    queryParameters: {
      if (v != null) 'v': '$v',
      'host': hosts.join(','),
      'port': '$port',
      'token': token,
      'name': ?name,
    },
  );

  /// The http form (§1, 1.2): `http://<primaryHost>:<port>/join#…`, the
  /// fragment carrying `v`, `token`, `name` and — unless the URL's own host
  /// is the only candidate — `host`. What QR codes and share text carry.
  Uri toHttpUri() {
    final fragment = [
      if (v != null) 'v=$v',
      'token=${_encode(token)}',
      if (name != null) 'name=${_encode(name!)}',
      if (hosts.length != 1) 'host=${hosts.map(_encode).join(',')}',
    ].join('&');
    return Uri(
      scheme: 'http',
      host: primaryHost,
      port: port,
      path: '/join',
      fragment: fragment,
    );
  }

  /// Query-component encoding, as `Uri.queryParameters` writes it.
  static String _encode(String value) => Uri.encodeQueryComponent(value);

  /// A copy with other [hosts] and/or [port] — a test proxy, a re-scan.
  JoinLink copyWith({List<String>? hosts, int? port}) => JoinLink(
    v: v,
    token: token,
    name: name,
    hosts: hosts ?? this.hosts,
    port: port ?? this.port,
  );

  @override
  bool operator ==(Object other) =>
      other is JoinLink &&
      other.v == v &&
      other.token == token &&
      other.name == name &&
      other.port == port &&
      _listEquals(other.hosts, hosts);

  @override
  int get hashCode => Object.hash(v, token, name, port, Object.hashAll(hosts));

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Leaves the token out: links end up in logs.
  @override
  String toString() =>
      'JoinLink(${hosts.join(',')}:$port'
      '${name == null ? '' : ', "$name"'}${v == null ? '' : ', v$v'})';
}
