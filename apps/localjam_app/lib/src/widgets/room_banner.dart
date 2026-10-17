/// The thin strips that sit under the room's app bar and say what is going
/// on with *this phone's* connection to the room — never the room itself.
///
/// Three things can put one there, and they are deliberately different
/// sentences:
///
/// * the phone's own sound stopped while the room plays on (a call, another
///   app, headphones pulled out, a native failure) — [JamOutputBanner], with
///   the one action that fixes it, "Resume audio";
/// * the host said it is going to sleep (§3.5) — "The host's phone is
///   asleep", calm, because nothing is broken and nothing needs doing;
/// * the link to the host dropped — "Lost the host", with a spinner, because
///   the engine is actively getting it back.
///
/// Non-blocking by design: apricot, not red, and the player stays usable
/// underneath. Each clears itself when its cause does.
library;

import 'package:flutter/material.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';

/// Everything these banners say out loud.
abstract final class JamRoomBannerStrings {
  /// [JamOutputSuspendReason.interruption] — auto-resumes when the call ends.
  static const String interruption = 'Paused for a call';

  /// [JamOutputSuspendReason.focusLost] — waits for the user.
  static const String focusLost = 'Another app is playing';

  /// [JamOutputSuspendReason.outputLost] — clears itself if the same
  /// headphones come back.
  static const String outputLost = 'Headphones disconnected';

  /// [JamOutputSuspendReason.playbackError].
  static const String playbackError = 'Playback error';
  static const String playbackErrorRetrying = 'Playback error — retrying…';

  /// The action that ends any of them.
  static const String resume = 'Resume audio';

  static const String hostAsleep = 'The host’s phone is asleep';
  static const String reconnecting =
      'Lost the host — still playing what you have.';
}

/// What [suspension] is called on screen.
String jamOutputSuspensionCopy(JamOutputSuspension suspension) =>
    switch (suspension.reason) {
      JamOutputSuspendReason.interruption => JamRoomBannerStrings.interruption,
      JamOutputSuspendReason.focusLost => JamRoomBannerStrings.focusLost,
      JamOutputSuspendReason.outputLost => JamRoomBannerStrings.outputLost,
      JamOutputSuspendReason.playbackError =>
        suspension.willRetry
            ? JamRoomBannerStrings.playbackErrorRetrying
            : JamRoomBannerStrings.playbackError,
    };

IconData _iconFor(JamOutputSuspendReason reason) => switch (reason) {
  JamOutputSuspendReason.interruption => Icons.phone_in_talk_rounded,
  JamOutputSuspendReason.focusLost => Icons.music_off_rounded,
  JamOutputSuspendReason.outputLost => Icons.headset_off_rounded,
  JamOutputSuspendReason.playbackError => Icons.error_outline_rounded,
};

/// "Paused for a call · Resume audio", for as long as [engine]'s output is
/// suspended. Builds nothing otherwise, so it can sit in a column
/// unconditionally.
class JamOutputBanner extends StatelessWidget {
  const JamOutputBanner({super.key, required this.engine});

  final JamEngine engine;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<JamOutputSuspension?>(
        valueListenable: engine.outputSuspension,
        builder: (context, suspension, _) => suspension == null
            ? const SizedBox.shrink()
            : JamRoomBanner(
                icon: _iconFor(suspension.reason),
                message: jamOutputSuspensionCopy(suspension),
                actionLabel: JamRoomBannerStrings.resume,
                // Local only: re-anchors this phone to wherever the room is
                // now and sends nothing to anyone. Available to every guest,
                // whatever the room lets them control.
                onAction: engine.resumeLocalOutput,
              ),
      );
}

/// One strip: a glyph (or a spinner), a sentence, at most one action.
///
/// The sentence is never cut short — it is the whole point of the strip —
/// and at large text sizes the action moves under it rather than squeezing
/// it ([kJamBannerStackAboveScale]).
class JamRoomBanner extends StatelessWidget {
  const JamRoomBanner({
    super.key,
    required this.message,
    this.icon,
    this.busy = false,
    this.actionLabel,
    this.onAction,
  });

  final String message;

  /// Leading glyph. Ignored while [busy].
  final IconData? icon;

  /// A 14 dp spinner instead of the glyph — the engine is working on it.
  final bool busy;

  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final label = actionLabel;
    final action = onAction;
    // One row at ordinary sizes. Past ~130% text the action took most of a
    // phone's width and the sentence went to "Playback err…" — and with no
    // room left at all, overflowed: the button goes on a line of its own.
    final stacked =
        MediaQuery.textScalerOf(context).scale(1) > kJamBannerStackAboveScale;

    final Widget? glyph = busy
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.warning,
            ),
          )
        : icon == null
        ? null
        : Icon(icon, size: 16, color: colors.warning);
    final text = Padding(
      padding: const EdgeInsets.symmetric(vertical: JamSpace.sm),
      child: Text(
        message,
        style: context.jamFootnote.copyWith(color: colors.warning),
      ),
    );
    final button = label == null || action == null
        ? null
        : TextButton(
            onPressed: action,
            style: TextButton.styleFrom(
              foregroundColor: colors.accent,
              minimumSize: const Size(44, 40),
              padding: const EdgeInsets.symmetric(horizontal: JamSpace.md),
              textStyle: context.jamFootnote.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            child: Text(label, textAlign: TextAlign.end),
          );

    final Widget content;
    if (!stacked) {
      content = Row(
        children: [
          ?glyph,
          const SizedBox(width: JamSpace.md),
          Expanded(child: text),
          button ?? const SizedBox(width: JamSpace.md),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (glyph != null)
                Padding(
                  // Level with the first line rather than the paragraph.
                  padding: const EdgeInsets.only(top: JamSpace.sm),
                  child: glyph,
                ),
              const SizedBox(width: JamSpace.md),
              Expanded(child: text),
              const SizedBox(width: JamSpace.md),
            ],
          ),
          if (button != null)
            Align(alignment: AlignmentDirectional.centerEnd, child: button),
        ],
      );
    }

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 40),
        color: colors.highlightSoft,
        padding: const EdgeInsets.only(left: JamSpace.page, right: JamSpace.sm),
        child: content,
      ),
    );
  }
}

/// The text scale past which a banner's action goes under its sentence.
const double kJamBannerStackAboveScale = 1.3;
