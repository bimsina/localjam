/// Builds the app's [ThemeData] from the [JamColors] tokens.
///
/// Stock Material widgets are mapped onto the same tokens as our own, so a
/// `FilledButton` or a `Slider` picks up the raspberry accent without a call
/// site having to say so. Chrome is quiet by design: separation comes from
/// hairlines and the softest of [JamShadow]s on light, and from lightness
/// steps on dark, so cover art is the only thing on screen with loud colour.
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';
import 'typography.dart';

/// The status-bar and navigation-bar treatment for a surface of [brightness].
///
/// Both bars are transparent — the app draws edge to edge — so the only thing
/// this decides is which way the OS's own glyphs are tinted. Light surfaces
/// (the cream canvas) get dark glyphs; dark surfaces get light ones. Getting
/// this wrong is invisible in a widget test and unmissable on a phone: white
/// clock and battery on cream is what the review caught.
///
/// [statusBarBrightness] is iOS's spelling of the same idea, and it is the
/// *background's* brightness rather than the icons', which is why the two
/// fields look contradictory.
SystemUiOverlayStyle jamOverlayStyle(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: dark
        ? Brightness.light
        : Brightness.dark,
    systemNavigationBarContrastEnforced: false,
  );
}

/// For the two screens that are dark whatever the theme says: the camera feed
/// behind the scanner, and the raspberry→plum onboarding gradient.
final SystemUiOverlayStyle jamOverlayStyleOnDark = jamOverlayStyle(
  Brightness.dark,
);

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
    tertiaryContainer: c.highlightSoft,
    onTertiaryContainer: c.warning,
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
    surfaceContainerHigh: c.surfaceElevated,
    surfaceContainerHighest: c.surfaceMuted,
    outline: c.separator,
    outlineVariant: c.separator,
    scrim: c.scrim,
    shadow: c.shadowTint.withValues(alpha: 1),
    inverseSurface: c.textPrimary,
    onInverseSurface: c.canvas,
    inversePrimary: c.accent,
  );

  /// Every button shares a shape, a height and a label style; only the fill
  /// and the label colour differ.
  ButtonStyle buttonBase({
    Color? foreground,
    Color? background,
    BorderSide? side,
    double height = 52,
    double radius = JamRadius.md,
  }) => ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? c.textTertiary : foreground,
    ),
    backgroundColor: background == null
        ? null
        : WidgetStateProperty.resolveWith((s) {
            if (s.contains(WidgetState.disabled)) return c.surfaceMuted;
            if (s.contains(WidgetState.pressed)) return c.accentPressed;
            return background;
          }),
    overlayColor: WidgetStatePropertyAll(c.accent.withValues(alpha: 0.08)),
    side: side == null ? null : WidgetStatePropertyAll(side),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    minimumSize: WidgetStatePropertyAll(Size(0, height)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: JamSpace.xl),
    ),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
    splashFactory: InkRipple.splashFactory,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: jamFontFamily,
    textTheme: text,
    primaryTextTheme: text,
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    dividerColor: c.separator,
    // Material You's sparkle fights this palette; a plain ripple in the
    // accent at 8% reads as a press without becoming a light show.
    splashFactory: InkRipple.splashFactory,
    splashColor: c.accent.withValues(alpha: 0.08),
    highlightColor: c.accent.withValues(alpha: 0.04),
    // Comfortable targets on touch, tighter chrome on desktop.
    visualDensity: VisualDensity.adaptivePlatformDensity,
    extensions: <ThemeExtension<dynamic>>[c],

    dividerTheme: DividerThemeData(
      color: c.separator,
      thickness: 0.5,
      space: 0.5,
    ),

    // Transparent: the room supplies its own artwork-tinted ground, and every
    // other screen sits directly on the canvas.
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      foregroundColor: c.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      // Without this Material picks a style from the app bar's *own* colour,
      // which is transparent here — so it guessed, and guessed light glyphs
      // on the cream canvas.
      systemOverlayStyle: jamOverlayStyle(brightness),
      titleTextStyle: text.titleLarge,
      iconTheme: IconThemeData(color: c.textPrimary, size: 22),
      actionsIconTheme: IconThemeData(color: c.textPrimary, size: 22),
    ),

    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
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
      textColor: c.textPrimary,
      selectedColor: c.accent,
      selectedTileColor: c.accentSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
      ),
    ),

    // The primary action. Its gradient lives in `JamButton`; the flat accent
    // here is what stock `FilledButton`s fall back to.
    filledButtonTheme: FilledButtonThemeData(
      style: buttonBase(foreground: c.onAccent, background: c.accent),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: buttonBase(foreground: c.onAccent, background: c.accent),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonBase(
        foreground: c.textPrimary,
        side: BorderSide(color: c.separator),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: buttonBase(
        foreground: c.accent,
        height: 44,
        radius: JamRadius.pill,
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.textPrimary,
        disabledForegroundColor: c.textTertiary,
        highlightColor: c.accent.withValues(alpha: 0.08),
        minimumSize: const Size(44, 44),
      ),
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
      overlayColor: c.accent.withValues(alpha: 0.14),
      trackHeight: 4,
      trackShape: const RoundedRectSliderTrackShape(),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      valueIndicatorColor: c.textPrimary,
      valueIndicatorTextStyle: text.bodySmall?.copyWith(color: c.canvas),
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
      overlayColor: WidgetStatePropertyAll(c.accent.withValues(alpha: 0.08)),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(c.onAccent),
      side: BorderSide(color: c.separator, width: 1.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.xs / 2),
      ),
    ),

    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.textTertiary,
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: c.surfaceMuted,
      selectedColor: c.accentSoft,
      disabledColor: c.surfaceMuted,
      surfaceTintColor: Colors.transparent,
      side: BorderSide.none,
      labelStyle: text.labelMedium!,
      secondaryLabelStyle: text.labelMedium!.copyWith(color: c.accent),
      labelPadding: const EdgeInsets.symmetric(horizontal: JamSpace.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: JamSpace.sm,
        vertical: JamSpace.xxs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.pill),
      ),
    ),

    // Filled by default. The borderless variant below is the one the
    // editable-heading fields (a room's name, your own name) use, where the
    // text *is* the heading and a box around it would be noise.
    inputDecorationTheme: jamFilledInput(c, text),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surfaceElevated,
      modalBarrierColor: c.scrim,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      dragHandleColor: c.textTertiary.withValues(alpha: 0.4),
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(JamRadius.xl)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      barrierColor: c.scrim,
      elevation: 0,
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyLarge!.copyWith(color: c.textSecondary),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: JamSpace.xxl,
        vertical: JamSpace.xxl,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.lg),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.textPrimary,
      contentTextStyle: text.bodyMedium!.copyWith(color: c.canvas),
      actionTextColor: c.highlight,
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.all(JamSpace.lg),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: c.shadowTint,
      textStyle: text.bodyLarge,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.textPrimary,
        borderRadius: BorderRadius.circular(JamRadius.xs),
      ),
      textStyle: text.bodySmall!.copyWith(color: c.canvas),
    ),

    // Wide layouts put navigation in a rail; the compact shell has no bottom
    // bar, but both are themed so a stock one never arrives unstyled.
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.accentSoft,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 24,
          color: s.contains(WidgetState.selected) ? c.accent : c.textSecondary,
        ),
      ),
    ),

    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.accentSoft,
      elevation: 0,
      selectedLabelTextStyle: text.labelMedium!.copyWith(color: c.accent),
      unselectedLabelTextStyle: text.labelMedium,
      selectedIconTheme: IconThemeData(color: c.accent, size: 24),
      unselectedIconTheme: IconThemeData(color: c.textSecondary, size: 24),
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: c.accent,
      unselectedLabelColor: c.textSecondary,
      labelStyle: text.titleSmall,
      unselectedLabelStyle: text.titleSmall,
      indicatorColor: c.accent,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: c.separator,
      dividerHeight: 0.5,
    ),

    // Screens cross-fade rather than slide on desktop, and use the platform's
    // own gesture-aware transition on mobile; the room's slide-up is its own
    // route transition and is untouched by this.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

/// The default field: a soft [JamColors.surfaceMuted] fill with no border,
/// focused with a 1.5 dp accent ring.
InputDecorationTheme jamFilledInput(JamColors c, TextTheme text) {
  OutlineInputBorder border([BorderSide side = BorderSide.none]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(JamRadius.md),
        borderSide: side,
      );

  return InputDecorationTheme(
    filled: true,
    fillColor: c.surfaceMuted,
    hintStyle: text.bodyLarge!.copyWith(color: c.textTertiary),
    labelStyle: text.bodyMedium,
    errorStyle: text.bodySmall!.copyWith(color: c.danger),
    contentPadding: const EdgeInsets.symmetric(
      horizontal: JamSpace.lg,
      vertical: JamSpace.md,
    ),
    border: border(),
    enabledBorder: border(),
    disabledBorder: border(),
    focusedBorder: border(BorderSide(color: c.accent, width: 1.5)),
    errorBorder: border(BorderSide(color: c.danger)),
    focusedErrorBorder: border(BorderSide(color: c.danger, width: 1.5)),
  );
}

/// The editable-heading field: no box at all, so a room's name reads as the
/// title it is until you put a caret in it. Wrap the field in a
/// `Theme(data: Theme.of(context).copyWith(inputDecorationTheme: …))`, or pass
/// it straight to a `TextField.decoration`'s `applyDefaults`.
InputDecorationTheme jamBorderlessInput(JamColors c, TextTheme text) =>
    InputDecorationTheme(
      filled: false,
      isDense: true,
      hintStyle: text.headlineLarge!.copyWith(color: c.textTertiary),
      contentPadding: EdgeInsets.zero,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
      errorBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: c.danger),
      ),
      errorStyle: text.bodySmall!.copyWith(color: c.danger),
    );
