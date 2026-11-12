/// The engine-state notice on Now Playing (DESIGN_SPEC v3 §6.3): the one
/// "something happened" shape ([JamNoticeSurface], glass on the backdrop)
/// above the cover, with one sentence and at most one inline action — never
/// a coloured full-width banner.
///
/// It is for states that want something *done*: this phone's own sound
/// stopped while the room plays on (a call, another app, headphones pulled
/// out, a native failure) — [JamOutputBanner], with the one action that
/// fixes it — or a track this phone could not fetch ("Try again"). Waits
/// that need nothing from anyone ("Reconnecting…", "The host’s phone is
/// asleep") are a footnote under the room's name instead.
///
/// The copy here is shared with the mini player, which carries the same
/// sentences when you are somewhere else in the app.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/tokens.dart';
import '../design/typography.dart';
import 'notice.dart' show JamNoticeSurface;
import 'pressable.dart';
import 'progress.dart';

/// Everything these states say out loud.
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
  static const String playbackErrorRetrying = 'Playback error. Retrying…';

  /// The action that ends any of them.
  static const String resume = 'Resume audio';

  static const String hostAsleep = 'The host’s phone is asleep';
  static const String reconnecting = 'Reconnecting…';
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

/// The glyph for a suspension.
IconData jamOutputSuspensionIcon(JamOutputSuspendReason reason) =>
    switch (reason) {
      JamOutputSuspendReason.interruption => CupertinoIcons.phone,
      JamOutputSuspendReason.focusLost => CupertinoIcons.speaker_slash,
      JamOutputSuspendReason.outputLost => CupertinoIcons.headphones,
      JamOutputSuspendReason.playbackError =>
        CupertinoIcons.exclamationmark_circle,
    };

/// "Paused for a call · Resume Audio", for as long as [engine]'s output is
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
                icon: jamOutputSuspensionIcon(suspension.reason),
                message: jamOutputSuspensionCopy(suspension),
                actionLabel: JamRoomBannerStrings.resume,
                // Local only: re-anchors this phone to wherever the room is
                // now and sends nothing to anyone. Available to every guest,
                // whatever the room lets them control.
                onAction: engine.resumeLocalOutput,
              ),
      );
}

/// One notice: a glyph (or a spinner), a sentence, at most one action.
///
/// White on glass, for the Now Playing backdrop; the action is a small
/// ivory button, the backdrop's "you can press this". It spans the width it
/// is given — the player's column — with the sentence leading and the
/// action trailing, so its edges are the cover's and the title's rather
/// than wherever its words happen to end (CR-15). The sentence is never cut
/// short — it is the whole point — so the notice wraps to a second line
/// rather than ellipsising, and at large text sizes the action moves under
/// it ([kJamBannerStackAboveScale]).
class JamRoomBanner extends StatelessWidget {
  const JamRoomBanner({
    super.key,
    required this.message,
    this.icon,
    this.busy = false,
    this.actionLabel,
    this.onAction,
    this.actionSemanticLabel,
  });

  final String message;

  /// Leading glyph. Ignored while [busy].
  final IconData? icon;

  /// A small activity indicator instead of the glyph — the engine is
  /// working on it.
  final bool busy;

  final String? actionLabel;
  final VoidCallback? onAction;

  /// What the action says to a screen reader, when the label alone would
  /// not stand on its own.
  final String? actionSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final label = actionLabel;
    final action = onAction;
    final stacked =
        MediaQuery.textScalerOf(context).scale(1) > kJamBannerStackAboveScale;
    final textStyle = context.jamFootnote.copyWith(
      color: JamNowPlayingColors.text,
    );

    final Widget? glyph = busy
        ? const JamProgressRing(color: JamNowPlayingColors.text)
        : icon == null
        ? null
        : Icon(icon, size: JamIconSize.inline, color: JamNowPlayingColors.text);

    final Widget? button = label == null || action == null
        ? null
        : Semantics(
            container: true,
            button: true,
            label: actionSemanticLabel ?? label,
            onTap: action,
            excludeSemantics: true,
            child: JamPressable(
              onTap: action,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: JamMetrics.hitTarget,
                ),
                child: Center(
                  widthFactor: 1,
                  child: Container(
                    constraints: const BoxConstraints(
                      minHeight: JamMetrics.buttonHeightSmall,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: JamSpace.md,
                      vertical: JamSpace.xs,
                    ),
                    alignment: Alignment.center,
                    decoration: const ShapeDecoration(
                      color: JamNowPlayingColors.fill,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(JamRadius.buttonSmall),
                        ),
                      ),
                    ),
                    child: Text(
                      label,
                      style: textStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: JamNowPlayingColors.selectedGlyph,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

    final sentence = Text(message, style: textStyle);
    final Widget content;
    if (!stacked) {
      content = Row(
        children: [
          if (glyph != null) ...[glyph, const SizedBox(width: JamSpace.sm)],
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: JamSpace.md),
              child: sentence,
            ),
          ),
          if (button != null) ...[const SizedBox(width: JamSpace.md), button],
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: JamSpace.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (glyph != null) ...[
                  glyph,
                  const SizedBox(width: JamSpace.sm),
                ],
                Flexible(child: sentence),
              ],
            ),
          ),
          if (button != null) button else const SizedBox(height: JamSpace.md),
        ],
      );
    }

    return Semantics(
      container: true,
      liveRegion: true,
      child: JamNoticeSurface(
        onBackdrop: true,
        child: Padding(
          // Beside the sentence, the button sits as far from the notice's
          // end as from its top and bottom.
          padding: EdgeInsetsDirectional.only(
            start: JamSpace.lg,
            end: button != null && !stacked ? _buttonInset : JamSpace.lg,
          ),
          child: content,
        ),
      ),
    );
  }

  /// The action button's distance from the notice's edges, inside a 44 pt
  /// row: (44 − 30) / 2.
  static const double _buttonInset =
      (JamMetrics.hitTarget - JamMetrics.buttonHeightSmall) / 2;
}

/// The text scale past which a capsule's action goes under its sentence.
const double kJamBannerStackAboveScale = 1.3;
