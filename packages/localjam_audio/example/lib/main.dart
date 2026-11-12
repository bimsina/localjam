// Manual verification harness for localjam_audio.
//
// Buttons: Load (copies the bundled click-tone asset to a temp file and loads
// it), "Play in 2s" (calibrates the Dart↔native clock offset, then schedules
// playAt now+2s), Pause, Stop; a rate slider (0.95–1.05) that applies live;
// and a position readout polled every 200 ms.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException, rootBundle;
import 'package:localjam_audio/localjam_audio.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _audio = LocaljamAudio();
  final _dartClock = Stopwatch()..start();

  Timer? _poll;
  int? _durationUs;
  int? _positionUs;
  int? _latencyUs;
  NativeClockCalibration? _calibration;
  double _rate = 1.0;
  String _status = 'Not loaded';

  int _dartNowUs() => _dartClock.elapsedMicroseconds;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      try {
        final position = await _audio.positionUs();
        if (mounted) setState(() => _positionUs = position);
      } on PlatformException {
        // Ignore polling errors (e.g. Android stub).
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _run(String action, Future<void> Function() body) async {
    try {
      await body();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _status = '$action failed: ${e.code} ${e.message}');
      }
    }
  }

  Future<void> _load() => _run('Load', () async {
    final bytes = await rootBundle.load('assets/click_tone.wav');
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}localjam_click_tone.wav',
    );
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    final durationUs = await _audio.load(file.path);
    final latencyUs = await _audio.outputLatencyUs();
    setState(() {
      _durationUs = durationUs;
      _latencyUs = latencyUs;
      _status = 'Loaded (${_fmtUs(durationUs)})';
    });
  });

  Future<void> _playIn2s() => _run('Play', () async {
    final calibration = await _audio.calibrate(_dartNowUs);
    final nativeTimeUs = _dartNowUs() + 2000000 + calibration.offsetUs;
    await _audio.playAt(nativeTimeUs: nativeTimeUs, positionUs: 0, rate: _rate);
    setState(() {
      _calibration = calibration;
      _status =
          'Scheduled: position 0 in 2 s '
          '(offset ${calibration.offsetUs} µs, rtt ${calibration.rttUs} µs)';
    });
  });

  Future<void> _pause() => _run('Pause', () async {
    await _audio.pause();
    setState(() => _status = 'Paused');
  });

  Future<void> _stop() => _run('Stop', () async {
    await _audio.stop();
    setState(() => _status = 'Stopped');
  });

  Future<void> _setRate(double rate) => _run('setRate', () async {
    setState(() => _rate = rate);
    await _audio.setRate(rate);
  });

  static String _fmtUs(int? us) {
    if (us == null) return '—';
    return '${(us / 1e6).toStringAsFixed(3)} s';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('localjam_audio harness')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Status: $_status'),
              const SizedBox(height: 8),
              Text(
                'Position: ${_fmtUs(_positionUs)} / ${_fmtUs(_durationUs)}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                'Output latency: ${_latencyUs ?? '—'} µs'
                '${_calibration == null ? '' : '   clock rtt: ${_calibration!.rttUs} µs'}',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(onPressed: _load, child: const Text('Load')),
                  ElevatedButton(
                    onPressed: _durationUs == null ? null : _playIn2s,
                    child: const Text('Play in 2s'),
                  ),
                  ElevatedButton(onPressed: _pause, child: const Text('Pause')),
                  ElevatedButton(onPressed: _stop, child: const Text('Stop')),
                ],
              ),
              const SizedBox(height: 24),
              Text('Rate: ${_rate.toStringAsFixed(3)}'),
              Slider(
                value: _rate,
                min: 0.95,
                max: 1.05,
                divisions: 100,
                label: _rate.toStringAsFixed(3),
                onChanged: (v) => _setRate(v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
