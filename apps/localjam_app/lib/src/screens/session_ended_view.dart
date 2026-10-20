/// The terminal states of a jam: the page that replaces Now Playing once the
/// session has ended, been refused, or is being rejoined.
///
/// Moved out of `room_screen.dart` unchanged so the player and this page can
/// be worked on separately; the room still decides when it shows.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/session_controller.dart';
import '../widgets/buttons.dart';
import '../widgets/empty_state.dart';

/// Every user-facing string the ended page can show. `JamRoomStrings`
/// forwards the same names, so either spelling finds the same copy.
abstract final class JamSessionEndedStrings {
  // Terminal states (spec §10.9: "jam", never "room"; plain reasons).
  static const String hostGoneTitle = 'The Host Left';
  static const String hostGoneBody = 'Their phone may have gone to sleep.';

  static const String kickedTitle = 'You Were Removed';
  static const String kickedBody = 'The host removed you from this jam.';
  // `rejected`, by the host's reason (JamSessionController.endRejectReason).
  // A reason this version does not know — or none — keeps the generic pair,
  // which names the likeliest cause without promising it.
  static const String rejectedTitle = 'Couldn’t Get Back In';
  static const String rejectedBody =
      'The jam turned this phone away. It may have restarted, so ask the '
      'host for a new code.';

  /// `bad_token`: the room restarted under a new code. The old link can
  /// never work again, so there is no "Try Again".
  static const String restartedTitle = 'The Jam Restarted';
  static const String restartedBody =
      'The code this phone joined with doesn’t work any more. Ask the host '
      'for the new one.';

  /// `version`: no retry fixes this; an update does.
  static const String versionTitle = 'Update Needed';
  static const String versionBody = kJamVersionMismatch;

  /// `full`: the one refusal that can turn into a yes on its own.
  static const String fullTitle = 'This Jam Is Full';
  static const String fullBody =
      'Someone has to leave before this phone can get back in.';

  /// Host only: the OS took the room's listening socket while the app was
  /// away and it could not be reopened (listenerFailed).
  static const String listenerFailedTitle = 'New Guests Can’t Join';
  static const String listenerFailedBody =
      'Start a new jam to keep going. Your queue comes with you.';
  static const String startNew = 'Start a New Jam';
  static const String hostEndedTitle = 'The Host Ended the Jam';
  static const String hostEndedBody = 'This jam is over for everyone.';
  static const String endedTitle = 'Jam Ended';
  static const String endedBody = 'This jam is over.';
  static const String tryAgain = 'Try Again';
  static const String back = 'Back to Nearby';
  static const String rejoinFailed = kJamRejoinFailed;
}

/// The terminal states: the immersive look is gone, and a plain page says
/// what happened and what to do about it — never "check your connection",
/// because there is no connection by design.
///
/// Getting back in is the primary action wherever it is a real possibility:
/// the room that closed was probably a host whose phone went to sleep, and
/// the sha-keyed cache means a rejoin costs nothing.
class JamSessionEndedView extends StatelessWidget {
  const JamSessionEndedView({
    super.key,
    required this.reason,
    this.rejectReason,
    required this.onDone,
    this.onRetry,
    this.onStartNew,
    this.retrying = false,
    this.error,
  });

  final JamSessionEndReason? reason;

  /// For [JamSessionEndReason.rejected]: what the host said (§3.1), which
  /// picks the copy and whether a retry is offered ([jamRejectIsRetryable]).
  final RejectReason? rejectReason;

  /// Back to Nearby. Null while a retry is in flight.
  final VoidCallback? onDone;

  /// Rejoin the room this device came from, when there is one to rejoin.
  final VoidCallback? onRetry;

  /// Host only: open host setup again on the room the OS took away.
  final VoidCallback? onStartNew;

  /// A "Try Again" is running: its button spins in place.
  final bool retrying;

  /// Why the last "Try Again" failed, said here rather than in a notice
  /// over a screen that is about to be read anyway.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final (icon, title, detail) = switch (reason) {
      JamSessionEndReason.hostGone => (
        CupertinoIcons.wifi_slash,
        JamSessionEndedStrings.hostGoneTitle,
        JamSessionEndedStrings.hostGoneBody,
      ),
      JamSessionEndReason.kicked => (
        CupertinoIcons.person_crop_circle_badge_xmark,
        JamSessionEndedStrings.kickedTitle,
        JamSessionEndedStrings.kickedBody,
      ),
      JamSessionEndReason.rejected => switch (rejectReason) {
        RejectReason.badToken => (
          CupertinoIcons.lock_rotation,
          JamSessionEndedStrings.restartedTitle,
          JamSessionEndedStrings.restartedBody,
        ),
        RejectReason.version => (
          CupertinoIcons.arrow_up_circle,
          JamSessionEndedStrings.versionTitle,
          JamSessionEndedStrings.versionBody,
        ),
        RejectReason.full => (
          CupertinoIcons.person_3,
          JamSessionEndedStrings.fullTitle,
          JamSessionEndedStrings.fullBody,
        ),
        // `kicked` arrives as its own end reason; it is here only so the
        // switch is total.
        RejectReason.kicked => (
          CupertinoIcons.person_crop_circle_badge_xmark,
          JamSessionEndedStrings.kickedTitle,
          JamSessionEndedStrings.kickedBody,
        ),
        RejectReason.unknown || null => (
          CupertinoIcons.lock,
          JamSessionEndedStrings.rejectedTitle,
          JamSessionEndedStrings.rejectedBody,
        ),
      },
      // The host said goodbye on purpose (§3.4). Nothing to try again for —
      // the room they would rejoin does not exist any more.
      JamSessionEndReason.hostEnded => (
        CupertinoIcons.stop_circle,
        JamSessionEndedStrings.hostEndedTitle,
        JamSessionEndedStrings.hostEndedBody,
      ),
      // The host's own room, gone without "End Jam" being pressed.
      JamSessionEndReason.listenerFailed => (
        CupertinoIcons.antenna_radiowaves_left_right,
        JamSessionEndedStrings.listenerFailedTitle,
        JamSessionEndedStrings.listenerFailedBody,
      ),
      _ => (
        CupertinoIcons.checkmark_circle,
        JamSessionEndedStrings.endedTitle,
        JamSessionEndedStrings.endedBody,
      ),
    };
    // Only a room that might still let you in is worth offering a way back
    // into: hostGone (a phone that slept) and a refusal a retry could turn
    // around (a full room). A restarted room or a version mismatch never
    // lets the same link back in; a kick must never be undoable (§5.6); and
    // a host who ended the jam deliberately has no room left to rejoin.
    final retry = switch (reason) {
      JamSessionEndReason.hostGone => onRetry,
      JamSessionEndReason.rejected when jamRejectIsRetryable(rejectReason) =>
        onRetry,
      _ => null,
    };
    final startNew = reason == JamSessionEndReason.listenerFailed
        ? onStartNew
        : null;
    final message = error;

    // One primary per screen: getting back in, or starting again, when
    // either is possible — with the way home as the plain second; otherwise
    // the way home alone, as a quiet grey button (leaving is not the loud
    // action on a screen that just told you something ended).
    final String actionLabel;
    final VoidCallback? action;
    final JamButtonVariant variant;
    String? secondaryLabel = JamSessionEndedStrings.back;
    if (retry != null || retrying) {
      actionLabel = JamSessionEndedStrings.tryAgain;
      // Kept non-null while the retry spins, so the button stays in place
      // (the spinner swallows taps).
      action = retry ?? _busy;
      variant = JamButtonVariant.filled;
    } else if (startNew != null) {
      actionLabel = JamSessionEndedStrings.startNew;
      action = startNew;
      variant = JamButtonVariant.filled;
    } else {
      actionLabel = JamSessionEndedStrings.back;
      action = onDone;
      variant = JamButtonVariant.gray;
      secondaryLabel = null;
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jamOverlayStyle(Theme.of(context).brightness),
      child: ColoredBox(
        color: colors.background,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: JamSpace.xxl),
              // Why a "Try Again" failed replaces the reason it was offered
              // for: it is the newer news, and said out loud.
              child: Semantics(
                liveRegion: message != null,
                child: JamEmptyState(
                  icon: icon,
                  title: title,
                  body: message ?? detail,
                  actionLabel: actionLabel,
                  onAction: action,
                  actionVariant: variant,
                  actionLoading: retrying,
                  secondaryActionLabel: secondaryLabel,
                  onSecondaryAction: secondaryLabel == null ? null : onDone,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static void _busy() {}
}
