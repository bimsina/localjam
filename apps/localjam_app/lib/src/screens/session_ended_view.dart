/// The terminal states of a jam: the page that replaces Now Playing once the
/// session has ended, been refused, or is being rejoined.
///
/// The room decides when it shows; this page says, by name, which jam it was
/// and what happened to it, and offers the one next step that can work.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/services.dart';
import 'package:localjam_client/localjam_client.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/session_controller.dart';
import '../util/capabilities.dart';
import '../widgets/buttons.dart';
import '../widgets/empty_state.dart';
import '../widgets/jam_mark.dart';

/// Every user-facing string the ended page can show. `JamRoomStrings`
/// forwards the constant names, so either spelling finds the same copy.
///
/// The constants are the copy for a jam whose name is not known; the
/// functions of the same stem name the jam when it is (spec §10.9: "jam",
/// never "room"; plain reasons; never "check your connection").
abstract final class JamSessionEndedStrings {
  static const String hostGoneTitle = 'The Host Left';
  static const String hostGoneBody =
      'The jam stopped reaching this phone. If the host’s phone is asleep, '
      'ask them to open LocalJam.';
  static String hostGone(String? jam) => jam == null
      ? hostGoneBody
      : '$jam stopped reaching this phone. If the host’s phone is asleep, '
            'ask them to open LocalJam.';

  static const String kickedTitle = 'You Were Removed';
  static const String kickedBody = 'The host removed you from this jam.';
  static String kicked(String? jam) =>
      jam == null ? kickedBody : 'The host removed you from $jam.';

  // `rejected`, by the host's reason (JamSessionController.endRejectReason).
  // A reason this version does not know — or none — keeps the generic pair,
  // which names the likeliest cause without promising it.
  //
  // Where the page offers the new code itself ([newCode], `offersCode`),
  // the sentence stops at the reason: the button under it is the way, and
  // "ask the host" is only the advice for a page with no such button.
  static const String rejectedTitle = 'Couldn’t Get Back In';
  static const String rejectedBody =
      'The jam turned this phone away. It may have restarted, so ask the '
      'host for a new code.';
  static String rejected(String? jam, {bool offersCode = false}) {
    if (!offersCode) {
      return jam == null
          ? rejectedBody
          : '$jam turned this phone away. It may have restarted, so ask the '
                'host for a new code.';
    }
    return '${jam ?? 'The jam'} turned this phone away. It may have '
        'restarted with a new code.';
  }

  /// `bad_token`: the room restarted under a new code. The old link can
  /// never work again, so there is no "Try Again" — a new code is the way.
  static const String restartedTitle = 'The Jam Restarted';
  static const String restartedBody =
      'The code this phone joined with doesn’t work any more. Ask the host '
      'for the new one.';
  static String restarted(String? jam, {bool offersCode = false}) {
    if (jam == null) {
      return offersCode
          ? 'The code this phone joined with doesn’t work any more.'
          : restartedBody;
    }
    const why = 'has a new code, so the old one won’t work.';
    return offersCode ? '$jam $why' : '$jam $why Ask the host for it.';
  }

  /// `version`: no retry fixes this; an update does — and an update needs
  /// the internet this group does not have, so it says when.
  static const String versionTitle = 'Update Needed';
  static const String versionBody =
      'This phone and the host’s have different versions of LocalJam. '
      'Update both when you’re back online.';

  /// `full`: the one refusal that can turn into a yes on its own.
  static const String fullTitle = 'This Jam Is Full';
  static const String fullBody =
      'Someone has to leave before this phone can get back in.';
  static String full(String? jam) => jam == null
      ? fullBody
      : 'Someone has to leave $jam before this phone can get back in.';

  /// Host only: the OS took the room's listening socket while the app was
  /// away and it could not be reopened (listenerFailed).
  static const String listenerFailedTitle = 'New Guests Can’t Join';
  static const String listenerFailedBody =
      'This jam stopped letting new guests in while LocalJam was in the '
      'background. Your queue comes with you.';
  static String listenerFailed(String? jam) => jam == null
      ? listenerFailedBody
      : '$jam stopped letting new guests in while LocalJam was in the '
            'background. Your queue comes with you.';
  static const String startNew = 'Start a New Jam';

  /// The host ended it on purpose. Every jam leaves a record, so the page
  /// says where this one went.
  static const String hostEndedTitle = 'The Host Ended the Jam';
  static const String hostEndedBody =
      'This jam is over for everyone. You’ll find it in Past Jams.';
  static String hostEnded(String? jam) => jam == null
      ? hostEndedBody
      : '$jam is over for everyone. You’ll find it in Past Jams.';

  static const String endedTitle = 'Jam Ended';
  static const String endedBody = 'This jam is over.';
  static String ended(String? jam) => jam == null ? endedBody : '$jam is over.';

  /// While "Try Again" runs: the words the spinner cannot say.
  static String retrying(String? jam) =>
      jam == null ? 'Trying to reach the jam…' : 'Trying to reach $jam…';

  /// A "Try Again" that got no answer at all: the newer news, with the one
  /// thing left to check.
  static String stillUnreachable(String? jam) =>
      'Still couldn’t reach ${jam ?? 'the jam'}. Check this phone is on the '
      'host’s Wi‑Fi or hotspot, then try again.';

  static const String tryAgain = 'Try Again';
  static const String back = 'Back to Nearby';

  /// A new code for a jam that restarted: the scanner where there is a
  /// camera, the Join with Link alert where there is not.
  static const String scanNew = 'Scan New Code';
  static const String linkNew = 'Join with New Link';
  static String get newCode => canScanQrCodes ? scanNew : linkNew;

  static const String rejoinFailed = kJamRejoinFailed;
}

/// The terminal states: the immersive look is gone, and a plain page names
/// the jam, says what happened to it, and what to do about it — never "check
/// your connection", because there is no connection by design.
///
/// Getting back in is the primary action wherever it is a real possibility:
/// the room that closed was probably a host whose phone went to sleep, and
/// the sha-keyed cache means a rejoin costs nothing. A room that restarted
/// can only be got back into with its new code, so that is offered instead
/// when [onScan] is wired.
///
/// The jam's mark sits at the same height in every state — a failed retry,
/// a longer reason, a second action all grow the page downward — so nothing
/// hops when the news changes.
class JamSessionEndedView extends StatelessWidget {
  const JamSessionEndedView({
    super.key,
    required this.reason,
    this.rejectReason,
    required this.onDone,
    this.onRetry,
    this.onStartNew,
    this.onScan,
    this.retrying = false,
    this.error,
    this.jamName,
    this.covers = const [],
    this.hostName,
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

  /// Join again with a new code — offered when the jam restarted under one
  /// (`bad_token`) or turned this phone away for a reason this version does
  /// not know. The room leaves for Home and opens its scanner (Join with
  /// Link where there is no camera). Null: the page says to ask the host.
  final VoidCallback? onScan;

  /// A "Try Again" is running: its button spins in place.
  final bool retrying;

  /// Why the last "Try Again" failed, said here rather than in a notice
  /// over a screen that is about to be read anyway.
  final String? error;

  /// The jam's name, when known: its mark and the copy name it. Null keeps
  /// the unnamed copy and a glyph for the reason.
  final String? jamName;

  /// Covers for the jam's mark — the last song's, say. Empty: its monogram.
  final List<ImageProvider> covers;

  /// The host's display name, when known: a face on the mark's corner.
  final String? hostName;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    final named = jamName?.trim();
    final jam = (named == null || named.isEmpty) ? null : named;
    // A page with the new code's button under it says only why.
    final offersCode = onScan != null;
    final (icon, title, detail) = switch (reason) {
      JamSessionEndReason.hostGone => (
        CupertinoIcons.wifi_slash,
        JamSessionEndedStrings.hostGoneTitle,
        JamSessionEndedStrings.hostGone(jam),
      ),
      JamSessionEndReason.kicked => (
        CupertinoIcons.person_badge_minus,
        JamSessionEndedStrings.kickedTitle,
        JamSessionEndedStrings.kicked(jam),
      ),
      JamSessionEndReason.rejected => switch (rejectReason) {
        RejectReason.badToken => (
          CupertinoIcons.arrow_2_circlepath,
          JamSessionEndedStrings.restartedTitle,
          JamSessionEndedStrings.restarted(jam, offersCode: offersCode),
        ),
        RejectReason.version => (
          CupertinoIcons.arrow_up_circle,
          JamSessionEndedStrings.versionTitle,
          JamSessionEndedStrings.versionBody,
        ),
        RejectReason.full => (
          CupertinoIcons.person_2,
          JamSessionEndedStrings.fullTitle,
          JamSessionEndedStrings.full(jam),
        ),
        // `kicked` arrives as its own end reason; it is here only so the
        // switch is total.
        RejectReason.kicked => (
          CupertinoIcons.person_badge_minus,
          JamSessionEndedStrings.kickedTitle,
          JamSessionEndedStrings.kicked(jam),
        ),
        RejectReason.unknown || null => (
          CupertinoIcons.lock,
          JamSessionEndedStrings.rejectedTitle,
          JamSessionEndedStrings.rejected(jam, offersCode: offersCode),
        ),
      },
      // The host said goodbye on purpose (§3.4). Nothing to try again for —
      // the room they would rejoin does not exist any more.
      JamSessionEndReason.hostEnded => (
        CupertinoIcons.stop_circle,
        JamSessionEndedStrings.hostEndedTitle,
        JamSessionEndedStrings.hostEnded(jam),
      ),
      // The host's own room, gone without "End Jam" being pressed.
      JamSessionEndReason.listenerFailed => (
        CupertinoIcons.exclamationmark_circle,
        JamSessionEndedStrings.listenerFailedTitle,
        JamSessionEndedStrings.listenerFailed(jam),
      ),
      _ => (
        CupertinoIcons.checkmark_circle,
        JamSessionEndedStrings.endedTitle,
        JamSessionEndedStrings.ended(jam),
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
    // A new code is the way back into a room that restarted, and the likely
    // one into a room that turned this phone away without saying why.
    final scan =
        reason == JamSessionEndReason.rejected &&
            (rejectReason == RejectReason.badToken ||
                rejectReason == RejectReason.unknown ||
                rejectReason == null) &&
            !retrying
        ? onScan
        : null;

    // What the page says under the title: the reason, unless a retry is
    // running (say so — the spinner cannot) or just failed (the newer news).
    final failure = error;
    final String body;
    if (retrying) {
      body = JamSessionEndedStrings.retrying(jam);
    } else if (failure == null) {
      body = detail;
    } else if (failure != kJamRejoinFailed) {
      // The controller's own account of what went wrong ("Couldn't reach
      // that jam. Check you're both on…") is already specific.
      body = failure;
    } else if (reason == JamSessionEndReason.rejected) {
      // The host answered, and its answer is now the title: the reason's
      // own sentence says what to do about it.
      body = detail;
    } else {
      body = JamSessionEndedStrings.stillUnreachable(jam);
    }

    // One primary per screen: getting back in, starting again, or a new
    // code, when any is possible — with the way home as the plain second;
    // otherwise the way home alone, as a quiet grey button (leaving is not
    // the loud action on a screen that just told you something ended).
    final String actionLabel;
    final VoidCallback? action;
    final JamButtonVariant variant;
    String? secondaryLabel = JamSessionEndedStrings.back;
    VoidCallback? secondary = onDone;
    // A third, plain way out — only when a retry and a new code are both
    // real options, so home is never the one that goes missing.
    VoidCallback? home;
    if (retry != null || retrying) {
      actionLabel = JamSessionEndedStrings.tryAgain;
      // Kept non-null while the retry spins, so the button stays in place
      // (the spinner swallows taps).
      action = retry ?? _busy;
      variant = JamButtonVariant.filled;
      if (scan != null) {
        secondaryLabel = JamSessionEndedStrings.newCode;
        secondary = scan;
        home = onDone;
      }
    } else if (startNew != null) {
      actionLabel = JamSessionEndedStrings.startNew;
      action = startNew;
      variant = JamButtonVariant.filled;
    } else if (scan != null) {
      actionLabel = JamSessionEndedStrings.newCode;
      action = scan;
      variant = JamButtonVariant.filled;
    } else {
      actionLabel = JamSessionEndedStrings.back;
      action = onDone;
      variant = JamButtonVariant.gray;
      secondaryLabel = null;
      secondary = null;
    }

    final Widget mark = jam == null
        ? _ReasonMark(icon: icon)
        : JamMark(
            name: jam,
            size: JamMarkSize.ended,
            covers: covers,
            hostName: hostName,
            shadow: covers.isNotEmpty,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jamOverlayStyle(Theme.of(context).brightness),
      child: ColoredBox(
        color: colors.background,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.only(
                top: _topFor(constraints.maxHeight),
                bottom: JamSpace.xxl,
              ),
              // The retry's progress and its outcome are announced: both
              // replace the sentence a screen reader already read.
              child: Semantics(
                liveRegion: retrying || failure != null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    JamEmptyState(
                      mark: mark,
                      title: title,
                      body: body,
                      actionLabel: actionLabel,
                      onAction: action,
                      actionVariant: variant,
                      actionLoading: retrying,
                      secondaryActionLabel: secondaryLabel,
                      onSecondaryAction: secondary,
                    ),
                    if (home != null) ...[
                      const SizedBox(height: JamSpace.xs),
                      JamButton.plain(
                        label: JamSessionEndedStrings.back,
                        onPressed: home,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Where the mark sits: a touch above the middle for a typical block, and
  /// the same for every state on a window this tall — a longer sentence or
  /// one more action grows the page downward instead of re-centring it.
  static double _topFor(double height) {
    final top = (height - _kTypicalBlock) / 2 - height * 0.04;
    return top < JamSpace.xxl ? JamSpace.xxl : top;
  }

  /// The height of a typical ended block: mark, title, two lines, two
  /// actions.
  static const double _kTypicalBlock = 320;

  static void _busy() {}
}

/// The reason, when the jam has no name to mark it with: an outline glyph
/// on the same tile a jam's mark is drawn on, so a named and an unnamed end
/// are the same object at the same size.
class _ReasonMark extends StatelessWidget {
  const _ReasonMark({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.jamColors;
    const size = JamMarkSize.ended;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.fillSecondary,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(JamRadius.artwork(size)),
          ),
        ),
        child: SizedBox.square(
          dimension: size,
          // At a monogram's size, where a monogram would be.
          child: Icon(icon, size: size * 0.46, color: colors.secondaryLabel),
        ),
      ),
    );
  }
}
