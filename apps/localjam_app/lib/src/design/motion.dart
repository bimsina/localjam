/// Reduced motion, wherever the platform says it.
///
/// Android's "Remove animations" arrives as
/// [MediaQueryData.disableAnimations]. iOS's Reduce Motion does not: Flutter
/// exposes it only as `AccessibilityFeatures.reduceMotion` and leaves
/// `disableAnimations` false, so an app that read MediaQuery alone kept
/// marqueeing titles, squeezing the play square and flying the cover on an
/// iPhone set to Reduce Motion. Every place that asks "should this move?"
/// asks [jamReducedMotion], which listens to both.
library;

import 'package:flutter/widgets.dart';

/// Whether [context] should get the still version of a motion: true when the
/// platform asks for animations to be disabled (MediaQuery, which tests and
/// captures can also set) or for motion to be reduced (iOS).
///
/// Registers [context] for rebuilds when either changes.
bool jamReducedMotion(BuildContext context) {
  if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return true;
  final scope = context
      .dependOnInheritedWidgetOfExactType<_JamReducedMotionScope>();
  if (scope != null) return scope.reduceMotion;
  return View.maybeOf(
        context,
      )?.platformDispatcher.accessibilityFeatures.reduceMotion ??
      false;
}

/// Follows the platform's Reduce Motion while the app runs, so switching it
/// on (from Control Center, say) stills the app without a relaunch.
///
/// The app root places one; anything built without it (a test, a capture)
/// still reads the setting, just without live updates.
class JamReducedMotion extends StatefulWidget {
  const JamReducedMotion({super.key, required this.child});

  final Widget child;

  @override
  State<JamReducedMotion> createState() => _JamReducedMotionState();
}

class _JamReducedMotionState extends State<JamReducedMotion>
    with WidgetsBindingObserver {
  late bool _reduceMotion = _read();

  bool _read() => WidgetsBinding
      .instance
      .platformDispatcher
      .accessibilityFeatures
      .reduceMotion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAccessibilityFeatures() {
    final now = _read();
    if (now != _reduceMotion) setState(() => _reduceMotion = now);
  }

  @override
  Widget build(BuildContext context) =>
      _JamReducedMotionScope(reduceMotion: _reduceMotion, child: widget.child);
}

class _JamReducedMotionScope extends InheritedWidget {
  const _JamReducedMotionScope({
    required this.reduceMotion,
    required super.child,
  });

  final bool reduceMotion;

  @override
  bool updateShouldNotify(_JamReducedMotionScope old) =>
      old.reduceMotion != reduceMotion;
}
