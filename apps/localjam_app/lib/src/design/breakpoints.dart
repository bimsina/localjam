/// Where the layout changes shape.
///
/// Not "a wider phone": on a desktop window the modal sheets and the
/// full-screen player are wrong. Wide layouts put navigation in a sidebar and
/// the queue and people in a panel that stays open beside the player, because
/// there is room for them and hiding them behind a tap is pure cost.
library;

import 'package:flutter/widgets.dart';

/// The three shapes the app takes.
enum JamBreakpoint {
  /// Phones. Bottom actions, modal sheets, a full-screen player.
  compact,

  /// Small windows and tablets in portrait. Phone chrome, but content is
  /// held to a readable column rather than stretched edge to edge.
  medium,

  /// Desktop windows and tablets in landscape. Sidebar navigation and a
  /// persistent side panel in the room.
  expanded;

  /// Whether navigation belongs in a sidebar rather than the app bar.
  bool get hasSidebar => this == JamBreakpoint.expanded;

  /// Whether the queue and people belong beside the player instead of
  /// behind a modal sheet.
  bool get hasSidePanel => this == JamBreakpoint.expanded;
}

/// Material 3's compact/medium/expanded thresholds, which line up with the
/// points where this app's chrome actually stops working.
JamBreakpoint breakpointFor(double width) {
  if (width < 600) return JamBreakpoint.compact;
  if (width < 1000) return JamBreakpoint.medium;
  return JamBreakpoint.expanded;
}

extension JamBreakpointOf on BuildContext {
  /// The current breakpoint, from the window width.
  JamBreakpoint get jamBreakpoint =>
      breakpointFor(MediaQuery.sizeOf(this).width);
}

/// Widths beyond which content stops growing and starts centring.
abstract final class JamContentWidth {
  /// Lists and forms — long lines are hard to scan.
  static const double reading = 640;

  /// The sidebar.
  static const double sidebar = 260;

  /// The room's queue/people panel.
  static const double panel = 340;

  /// The floating room bar at medium widths, where a full-bleed bar would
  /// stretch a 44 dp thumbnail across a desktop window.
  static const double floatingRoomBar = 720;
}
