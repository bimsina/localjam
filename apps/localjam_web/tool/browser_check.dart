/// Opens the listener page in headless Chrome against a running host and
/// reports what a browser actually did (docs/design/WEB_GUEST.md D8, test
/// plan "E2E on the Mac"):
///
/// * every request the page made, and whether any left the page's origin
///   (the page must make none: the room has no internet);
/// * that the address bar still holds the invitation after Flutter started
///   (the fragment carries the token, so a reload must still work);
/// * with `--listen`, a real (trusted) click on "Tap to Listen" — Chrome's
///   input pipeline, not a script, so the page's audio unlock runs inside a
///   user gesture — and then what the page says (its accessibility text) as
///   the jam goes on.
///
/// Usage (the host started with `localjam host --web-dir build/web …`):
///
///     dart run tool/browser_check.dart [--listen] [--seconds 20] \
///         'http://127.0.0.1:47123/join#v=1&token=…&name=…'
///
/// Chrome is `$CHROME_EXECUTABLE`, else the usual macOS install. Pure
/// `dart:io` (the Chrome DevTools protocol over a WebSocket); exits 1 when
/// any request left the origin.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final listen = args.contains('--listen');
  var seconds = 15;
  final secondsAt = args.indexOf('--seconds');
  if (secondsAt >= 0) seconds = int.parse(args[secondsAt + 1]);
  final url = args.lastWhere((a) => a.startsWith('http'), orElse: () => '');
  if (url.isEmpty) {
    stderr.writeln('usage: browser_check.dart [--listen] [--seconds N] <url>');
    exit(64);
  }
  final origin = Uri.parse(url).origin;
  final chrome =
      Platform.environment['CHROME_EXECUTABLE'] ??
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  final profile = await Directory.systemTemp.createTemp('localjam_check');
  final process = await Process.start(chrome, [
    '--headless=new',
    '--remote-debugging-port=0',
    '--user-data-dir=${profile.path}',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--window-size=430,932',
    'about:blank',
  ]);
  unawaited(process.stderr.drain<void>());
  unawaited(process.stdout.drain<void>());
  var exitCode = 0;
  try {
    final port = await _devToolsPort(profile);
    final targets =
        jsonDecode(await _httpGet('http://127.0.0.1:$port/json/list')) as List;
    final page = targets.cast<Map<String, Object?>>().firstWhere(
      (t) => t['type'] == 'page',
    );
    final cdp = await _Cdp.connect(page['webSocketDebuggerUrl']! as String);
    final requests = <String>[];
    final failures = <String>[];
    final console = <String>[];
    cdp.events.listen((event) {
      final params = (event['params'] as Map?)?.cast<String, Object?>() ?? {};
      switch (event['method']) {
        case 'Network.requestWillBeSent':
          final request = (params['request']! as Map).cast<String, Object?>();
          requests.add(request['url']! as String);
        case 'Network.loadingFailed':
          failures.add('${params['errorText']} (${params['requestId']})');
        case 'Runtime.consoleAPICalled':
          final parts = [
            for (final a in (params['args'] as List? ?? const []))
              (a as Map)['value'] ?? a['description'] ?? '',
          ];
          console.add('${params['type']}: ${parts.join(' ')}');
        case 'Runtime.exceptionThrown':
          console.add('exception: ${params['exceptionDetails']}');
      }
    });
    await cdp.call('Network.enable');
    await cdp.call('Runtime.enable');
    await cdp.call('Page.enable');
    await cdp.call('Page.navigate', {'url': url});
    await Future<void>.delayed(const Duration(seconds: 5));

    final href = await cdp.evaluate('location.href');
    stdout.writeln('address bar after start: $href');
    stdout.writeln(
      href == url
          ? '  OK: the invitation (fragment) is still there'
          : '  CHANGED: was $url',
    );

    // Flutter's accessibility tree, so the page can be read and clicked.
    await cdp.evaluate(
      "document.querySelector('flt-semantics-placeholder')?.click(); true",
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('landing says: ${await _pageText(cdp)}');

    if (listen) {
      final box = await cdp.evaluate('''(() => {
        // The innermost node that says it (its ancestors' text includes it).
        const els = [...document.querySelectorAll('flt-semantics, [role=button]')]
          .filter(e => ((e.getAttribute('aria-label') || '') + e.textContent)
            .includes('Tap to Listen'));
        const el = els.find(e => e.getAttribute('role') === 'button') ||
          els[els.length - 1];
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return JSON.stringify({x: r.x + r.width / 2, y: r.y + r.height / 2});
      })()''');
      if (box == null) {
        stdout.writeln('no "Tap to Listen" button found');
        exitCode = 1;
      } else {
        final at = jsonDecode(box as String) as Map<String, Object?>;
        for (final type in ['mousePressed', 'mouseReleased']) {
          await cdp.call('Input.dispatchMouseEvent', {
            'type': type,
            'x': at['x'],
            'y': at['y'],
            'button': 'left',
            'clickCount': 1,
          });
        }
        stdout.writeln('clicked "Tap to Listen" at $at');
      }
      final until = DateTime.now().add(Duration(seconds: seconds));
      String? last;
      while (DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final text = await _pageText(cdp);
        if (text != last) {
          stdout.writeln('[${DateTime.now().toIso8601String()}] $text');
          last = text;
        }
      }
    } else {
      await Future<void>.delayed(Duration(seconds: seconds));
    }

    stdout.writeln('\n${requests.length} requests:');
    final offOrigin = <String>[];
    for (final request in requests) {
      final u = Uri.tryParse(request);
      // A `blob:` URL names bytes the page already holds; its "origin" is
      // the page's, and fetching it touches no network.
      final same =
          u != null &&
          (u.scheme == 'blob' ||
              u.scheme == 'data' ||
              ((u.scheme == 'http' || u.scheme == 'https') &&
                  u.origin == origin));
      stdout.writeln('  ${same ? '   ' : 'OFF'} $request');
      if (!same) offOrigin.add(request);
    }
    stdout.writeln(
      offOrigin.isEmpty
          ? 'OK: zero requests left $origin'
          : 'FAIL: ${offOrigin.length} request(s) left $origin',
    );
    if (offOrigin.isNotEmpty) exitCode = 1;
    if (failures.isNotEmpty) stdout.writeln('failed loads: $failures');
    if (console.isNotEmpty) {
      stdout.writeln('console:');
      for (final line in console) {
        stdout.writeln('  $line');
      }
    }
    await cdp.close();
  } finally {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );
    try {
      await profile.delete(recursive: true);
    } catch (_) {}
  }
  exit(exitCode);
}

/// The page's accessibility text, one line.
Future<String> _pageText(_Cdp cdp) async =>
    '${await cdp.evaluate('''(() => {
      const host = document.querySelector('flt-semantics-host');
      if (!host) return '(no semantics yet)';
      const parts = [];
      for (const e of host.querySelectorAll('*')) {
        const label = e.getAttribute('aria-label');
        if (label) parts.push(label);
        for (const n of e.childNodes) {
          if (n.nodeType === 3 && n.textContent.trim()) {
            parts.push(n.textContent.trim());
          }
        }
      }
      return [...new Set(parts)].join(' | ');
    })()''')}';

Future<int> _devToolsPort(Directory profile) async {
  final file = File('${profile.path}/DevToolsActivePort');
  for (var i = 0; i < 100; i++) {
    if (await file.exists()) {
      final lines = await file.readAsLines();
      if (lines.isNotEmpty) return int.parse(lines.first);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Chrome never opened its DevTools port');
}

Future<String> _httpGet(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

/// A minimal Chrome DevTools protocol client.
class _Cdp {
  _Cdp(this._ws) {
    _ws.listen((raw) {
      final message = jsonDecode(raw as String) as Map<String, Object?>;
      final id = message['id'];
      if (id is int) {
        _pending.remove(id)?.complete(message);
      } else {
        _events.add(message);
      }
    });
  }

  static Future<_Cdp> connect(String url) async =>
      _Cdp(await WebSocket.connect(url));

  final WebSocket _ws;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final StreamController<Map<String, Object?>> _events =
      StreamController.broadcast();
  int _next = 0;

  Stream<Map<String, Object?>> get events => _events.stream;

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = ++_next;
    final done = Completer<Map<String, Object?>>();
    _pending[id] = done;
    _ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return done.future.timeout(const Duration(seconds: 10));
  }

  Future<Object?> evaluate(String expression) async {
    final reply = await call('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
    });
    final result = (reply['result'] as Map?)?['result'] as Map?;
    return result?['value'];
  }

  Future<void> close() => _ws.close();
}
