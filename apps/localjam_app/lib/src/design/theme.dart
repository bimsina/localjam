/// Builds the app's [ThemeData] from the [JamColors] tokens.
///
/// Stock Material widgets are mapped onto the same tokens as our own, so a
/// `FilledButton` or a `Slider` picks up the ember accent without a call site
/// having to say so. Chrome is flat by design: separation comes from hairlines
/// on light and from lightness steps on dark, never from drop shadows, so
/// cover art is the only thing on screen with real colour.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';
import 'typography.dart';

/// The light theme — the palette the app is designed against.
ThemeData jamLightTheme() => _build(JamColors.light, Brightness.light);

/// The dark theme — a full peer, not an inversion afterthought.
ThemeData jamDarkTheme() => _build(JamColors.dark, Brightness.dark);

ThemeData _build(JamColors c, Brightness brightness) {
  final text = buildJamTextTheme(
    primary: c.textPrimary,
    secondary: c.textSecondary,
  );

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentSoft,
    onPrimaryContainer: c.accent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    secondaryContainer: c.surfaceMuted,
    onSecondaryContainer: c.textPrimary,
    tertiary: c.warning,
    onTertiary: c.onAccent,
    error: c.danger,
    onError: c.onAccent,
    errorContainer: c.danger.withValues(alpha: 0.12),
    onErrorContainer: c.danger,
    surface: c.surface,
    onSurface: c.textPrimary,
    onSurfaceVariant: c.textSecondary,
    surfaceContainerLowest: c.canvas,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surfaceMuted,
    surfaceContainerHigh: c.surfaceMuted,
    surfaceContainerHighest: c.surfaceMuted,
    outline: c.separator,
    outlineVariant: c.separator,
    scrim: c.scrim,
    shadow: const Color(0xFF000000),
    inverseSurface: c.textPrimary,
    onInverseSurface: c.canvas,
    inversePrimary: c.accent,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    dividerColor: c.separator,
    splashFactory: InkSparkle.splashFactory,
    extensions: <ThemeExtension<dynamic>>[c],

    dividerTheme: DividerThemeData(
      color: c.separator,
      thickness: 0.5,
      space: 0.5,
    ),

    appBarTheme: AppBarTheme(
      backgroundColor: c.canvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: c.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      iconTheme: IconThemeData(color: c.textPrimary, size: 22),
    ),

    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.lg),
        side: BorderSide(color: c.separator, width: 0.5),
      ),
    ),

    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: JamSpace.page,
        vertical: JamSpace.xs,
      ),
      minVerticalPadding: JamSpace.md,
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: text.bodySmall,
      iconColor: c.textSecondary,
      selectedColor: c.accent,
      selectedTileColor: c.accentSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.surfaceMuted,
        disabledForegroundColor: c.textTertiary,
        textStyle: text.labelLarge,
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: JamSpace.lg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JamRadius.md),
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textPrimary,
        textStyle: text.labelLarge,
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: JamSpace.lg),
        side: BorderSide(color: c.separator),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JamRadius.md),
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        textStyle: text.labelLarge,
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.textPrimary),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: c.surfaceMuted,
        foregroundColor: c.textSecondary,
        selectedBackgroundColor: c.accentSoft,
        selectedForegroundColor: c.accent,
        side: BorderSide(color: c.separator),
        textStyle: text.titleSmall,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JamRadius.sm),
        ),
      ),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: c.accent,
      inactiveTrackColor: c.surfaceMuted,
      thumbColor: c.accent,
      overlayColor: c.accent.withValues(alpha: 0.12),
      trackHeight: 4,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.surfaceMuted,
      circularTrackColor: c.surfaceMuted,
      linearMinHeight: 3,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.onAccent : c.surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.surfaceMuted,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? Colors.transparent : c.separator,
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: c.surfaceMuted,
      selectedColor: c.accentSoft,
      side: BorderSide.none,
      labelStyle: text.labelMedium!,
      padding: const EdgeInsets.symmetric(
        horizontal: JamSpace.sm,
        vertical: JamSpace.xxs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.pill),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceMuted,
      hintStyle: text.bodyLarge!.copyWith(color: c.textTertiary),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: JamSpace.lg,
        vertical: JamSpace.md,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surface,
      elevation: 0,
      showDragHandle: true,
      dragHandleColor: c.textTertiary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(JamRadius.xl)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyLarge,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.lg),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.textPrimary,
      contentTextStyle: text.bodyMedium!.copyWith(color: c.canvas),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      textStyle: text.bodyLarge,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
      ),
    ),
  );
}
