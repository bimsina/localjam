/// Diagnostics (DESIGN_SPEC v3 §6.6, §10.1, §10.2, §10.5): the sync
/// numbers, as a grouped list of label/value rows with tabular values.
///
/// Sound Offset has one home — its own sheet. Here it is a read-only row
/// showing the current value that opens that sheet, not a second slider.
/// Copy lives in the content (the header's leading slot is for Cancel
/// only) and confirms in place: "Copied" with a checkmark for a moment,
/// no toast.
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
import '../util/format.dart';
import 'buttons.dart';
import 'list.dart';
import 'nudge_slider.dart';
import 'section.dart';
import 'sheet.dart';

/// Every user-facing string this sheet can show.
abstract final class JamDiagnosticsStrings {
  static const String title = 'Diagnostics';
  static const String copy = 'Copy diagnostics';
  static const String done = 'Done';

  /// Copy's label for a moment after it worked.
  static const String copied = 'Copied';

  static const String syncHeader = 'Sync';
  static const String clockOffset = 'Clock offset';
  static const String clockSyncing = 'Syncing…';
  static const String drift = 'Drift';
  static const String lastCorrection = 'Last correction';
  static const String none = 'None';
  static const String slew = 'Slew';
  static const String hardResync = 'Resync';
  static const String empty = '—';

  static const String playerHeader = 'Player';
  static const String playerError = 'Last error';

  static const String playbackHeader = 'Playback';
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
    // Shows figures and changes nothing: close-only (§10.2).
    actions: const JamSheetActions.done(),
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

/// Copies [diagnosticsReport]. The caller confirms it in place.
Future<void> copyDiagnostics(
  BuildContext context,
  JamEngine engine, {
  int? Function()? clockOffsetUs,
}) => Clipboard.setData(
  ClipboardData(text: diagnosticsReport(engine, clockOffsetUs: clockOffsetUs)),
);

/// A signed duration from µs for the diagnostics rows: a real minus sign
/// (U+2212), milliseconds with one decimal below a second, seconds with
/// one decimal and grouped thousands above — "−272.4 s", not
/// "-272391.4 ms". Anything that rounds to zero is unsigned, as in
/// [formatSignedMs].
String formatDiagnosticsDuration(int us) {
  final ms = us / 1000;
  if (ms.abs() < kJamZeroMs) return '0.0 ms';
  final sign = ms > 0 ? '+' : '−';
  final abs = ms.abs();
  if (abs < 1000) return '$sign${abs.toStringAsFixed(1)} ms';
  final fixed = (abs / 1000).toStringAsFixed(1);
  final dot = fixed.indexOf('.');
  final grouped = fixed
      .substring(0, dot)
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '$sign$grouped${fixed.substring(dot)} s';
}

String _clockOffset(int? us) => us == null
    ? JamDiagnosticsStrings.clockSyncing
    : formatDiagnosticsDuration(us);

String _drift(DriftSample? sample) => sample == null
    ? JamDiagnosticsStrings.empty
    : formatDiagnosticsDuration(sample.errorUs);

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

  Future<void> _copy() async {
    await copyDiagnostics(
      context,
      widget.engine,
      clockOffsetUs: widget.clockOffsetUs,
    );
    JamHaptics.selection();
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
            children: [
              // Read-only here: the one place to change it is its own sheet.
              ValueListenableBuilder<int>(
                valueListenable: engine.nudgeUs,
                builder: (context, us, _) => JamRow(
                  title: JamNudgeStrings.title,
                  value: JamNudgeStrings.value(us ~/ 1000),
                  chevron: true,
                  onTap: () => unawaited(showSoundOffsetSheet(context, engine)),
                ),
              ),
            ],
          ),
          JamSection(
            children: [
              // Confirms in place, the way every copy does (§10.5).
              JamInPlaceConfirmation(
                builder: (context, copied, confirm) => Semantics(
                  liveRegion: copied,
                  child: JamRow(
                    title: copied
                        ? JamDiagnosticsStrings.copied
                        : JamDiagnosticsStrings.copy,
                    icon: copied
                        ? CupertinoIcons.checkmark
                        : CupertinoIcons.doc_on_doc,
                    tinted: true,
                    onTap: () => confirm(_copy),
                  ),
                ),
              ),
            ],
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
