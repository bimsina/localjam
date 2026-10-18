/// Diagnostics (DESIGN_SPEC v3 §6.6): the sync numbers, as a grouped list of
/// label/value rows with tabular values, a Copy action in the header, and
/// the one control that is actionable — Sound Offset, for Bluetooth latency
/// the engine cannot see past the OS.
///
/// Slew and resync *counts* stay out: a running total of corrections is not
/// something anyone can act on.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import '../state/session_controller.dart';
import '../util/format.dart';
import 'buttons.dart';
import 'list.dart';
import 'nudge_slider.dart';
import 'section.dart';
import 'sheet.dart';

/// Every user-facing string this sheet can show.
abstract final class JamDiagnosticsStrings {
  static const String title = 'Diagnostics';
  static const String copy = 'Copy';
  static const String done = 'Done';
  static const String copied = 'Diagnostics Copied';

  static const String syncHeader = 'Sync';
  static const String clockOffset = 'Clock Offset';
  static const String clockSyncing = 'Syncing…';
  static const String drift = 'Drift';
  static const String lastCorrection = 'Last Correction';
  static const String none = 'None';
  static const String slew = 'Slew';
  static const String hardResync = 'Hard resync';
  static const String empty = '—';

  static const String playerHeader = 'Player';
  static const String playerError = 'Last Error';

  static const String playbackHeader = 'Playback';
  static const String soundOffsetFooter =
      'Bluetooth adds a delay LocalJam can’t measure. Move the slider '
      'until you line up with the room.';
}

/// Opens the diagnostics sheet.
Future<void> showDiagnosticsSheet(
  BuildContext context,
  JamEngine engine, {
  int? Function()? clockOffsetUs,
}) {
  return showJamSheet<void>(
    context,
    title: JamDiagnosticsStrings.title,
    leading: Builder(
      builder: (context) => JamTextButton(
        label: JamDiagnosticsStrings.copy,
        onPressed: () => unawaited(
          copyDiagnostics(context, engine, clockOffsetUs: clockOffsetUs),
        ),
      ),
    ),
    trailing: Builder(
      builder: (context) => JamTextButton(
        label: JamDiagnosticsStrings.done,
        bold: true,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    ),
    grouped: true,
    // Sized to its content; scrolls rather than clips at large text sizes.
    scrollable: false,
    builder: (_) => SingleChildScrollView(
      child: DiagnosticsSheet(engine: engine, clockOffsetUs: clockOffsetUs),
    ),
  );
}

/// The figures, as text: what Copy puts on the clipboard.
String diagnosticsReport(JamEngine engine, {int? Function()? clockOffsetUs}) {
  final sample = engine.lastDriftSample;
  final lines = <String>[
    if (clockOffsetUs != null)
      '${JamDiagnosticsStrings.clockOffset}: '
          '${_clockOffset(clockOffsetUs())}',
    '${JamDiagnosticsStrings.drift}: ${_drift(sample)}',
    '${JamDiagnosticsStrings.lastCorrection}: ${_describe(sample?.action)}',
    '${JamNudgeStrings.title}: '
        '${JamNudgeStrings.value(engine.nudgeUs.value ~/ 1000)}',
    if (engine.lastPlayerError.value != null)
      '${JamDiagnosticsStrings.playerError}: ${engine.lastPlayerError.value}',
  ];
  return lines.join('\n');
}

/// Copies [diagnosticsReport] and says so.
Future<void> copyDiagnostics(
  BuildContext context,
  JamEngine engine, {
  int? Function()? clockOffsetUs,
}) async {
  final session = context.getInheritedWidgetOfExactType<JamSession>()?.notifier;
  await Clipboard.setData(
    ClipboardData(
      text: diagnosticsReport(engine, clockOffsetUs: clockOffsetUs),
    ),
  );
  session?.notify(JamDiagnosticsStrings.copied);
}

String _clockOffset(int? us) =>
    us == null ? JamDiagnosticsStrings.clockSyncing : formatDriftMs(us);

String _drift(DriftSample? sample) => sample == null
    ? JamDiagnosticsStrings.empty
    : formatDriftMs(sample.errorUs);

String _describe(DriftAction? action) => switch (action) {
  null => JamDiagnosticsStrings.empty,
  DriftNone() => JamDiagnosticsStrings.none,
  DriftSlew(:final rateMultiplier) =>
    '${JamDiagnosticsStrings.slew} ×${rateMultiplier.toStringAsFixed(3)}',
  DriftHardResync() => JamDiagnosticsStrings.hardResync,
};

/// The diagnostics sheet's body.
class DiagnosticsSheet extends StatefulWidget {
  const DiagnosticsSheet({super.key, required this.engine, this.clockOffsetUs});

  final JamEngine engine;

  /// Guest only: the current guest→host clock offset. Omitted on a host,
  /// whose clock *is* the session clock.
  final int? Function()? clockOffsetUs;

  @override
  State<DiagnosticsSheet> createState() => _DiagnosticsSheetState();
}

class _DiagnosticsSheetState extends State<DiagnosticsSheet> {
  StreamSubscription<DriftSample>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.engine.driftSamples.listen((_) {
      if (mounted) setState(() {});
    });
    widget.engine.lastPlayerError.addListener(_onError);
  }

  void _onError() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    widget.engine.lastPlayerError.removeListener(_onError);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final engine = widget.engine;
    final sample = engine.lastDriftSample;
    final clockOffsetUs = widget.clockOffsetUs;
    final error = engine.lastPlayerError.value;

    return Padding(
      padding: const EdgeInsets.only(top: JamSpace.sm, bottom: JamSpace.xxl),
      child: JamSectionList(
        children: [
          JamSection(
            header: JamDiagnosticsStrings.syncHeader,
            children: [
              if (clockOffsetUs != null)
                _ValueRow(
                  label: JamDiagnosticsStrings.clockOffset,
                  value: _clockOffset(clockOffsetUs()),
                ),
              _ValueRow(
                label: JamDiagnosticsStrings.drift,
                value: _drift(sample),
              ),
              _ValueRow(
                label: JamDiagnosticsStrings.lastCorrection,
                value: _describe(sample?.action),
              ),
            ],
          ),
          if (error != null)
            JamSection(
              header: JamDiagnosticsStrings.playerHeader,
              children: [
                JamRow(
                  title: JamDiagnosticsStrings.playerError,
                  subtitle: error,
                  subtitleColor: colors.danger,
                  subtitleMaxLines: 4,
                ),
              ],
            ),
          JamSection(
            header: JamDiagnosticsStrings.playbackHeader,
            footer: JamDiagnosticsStrings.soundOffsetFooter,
            children: [NudgeSlider(engine: engine)],
          ),
        ],
      ),
    );
  }
}

/// A label with a tabular value on the right.
class _ValueRow extends StatelessWidget implements JamSelfSeparatingRow {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => JamRow(
    title: label,
    trailing: Text(
      value,
      maxLines: 1,
      style: jamTabular(
        context.jamBody,
      ).copyWith(color: context.jamColors.secondaryLabel),
    ),
  );
}
