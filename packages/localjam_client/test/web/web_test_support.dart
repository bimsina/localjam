/// What the browser tests under `test/web/` share: the host helper's
/// control plane (`tool/web_test_host.dart`) and the plugin wiring the
/// page's generated registrant would do. Not a test suite itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:localjam_audio/localjam_audio_web.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

/// The host helper's one JSON line, from `tool/web_engine_test.sh`.
const String webTestHostInfo = String.fromEnvironment('LOCALJAM_WEB_TEST_HOST');

/// One request to the host helper's control plane; its JSON answer.
Future<Map<String, Object?>> webTestControl(
  String url, {
  String method = 'GET',
}) async {
  final response = await web.window
      .fetch(url.toJS, web.RequestInit(method: method))
      .toDart;
  final text = (await response.text().toDart).toDart;
  return (jsonDecode(text) as Map).cast<String, Object?>();
}

/// Polls [condition] every 20 ms until it holds, failing after [timeout].
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Routes the engine's channels through a [Registrar] with the real web
/// audio plugin on it, as the page's generated registrant does — the test
/// binding has none. A channel no web plugin answers (the OS media session,
/// the Android keep-alive) is then answered null, a
/// `MissingPluginException`, exactly as on the page; unrouted, the test
/// binding would never answer it at all.
void routeChannelsLikeThePage() {
  SharedPreferences.setMockInitialValues({});
  final registrar = Registrar();
  LocaljamAudioWeb.registerWith(registrar);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'localjam_audio',
    'localjam_audio/events',
    'localjam_audio/media_session',
    'localjam/keepalive',
  ]) {
    messenger.setMockMessageHandler(name, (data) {
      final reply = Completer<ByteData?>();
      registrar.handleFrameworkMessage(name, data, reply.complete);
      return reply.future;
    });
  }
}
