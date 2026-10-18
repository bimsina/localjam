/// Builds the app's [ThemeData] from the [JamColors] tokens and the
/// [JamTypeScale].
///
/// The app looks like iOS on every platform (D2): no Material ink ripples
/// (presses are highlights and opacity), Cupertino page transitions, a
/// Cupertino theme derived from the same tokens so `Cupertino*` widgets —
/// nav bars, alerts, switches, menus — pick up the tint and the type scale.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';
import 'typography.dart';

/// The status-bar and navigation-bar treatment for a surface of [brightness].
///
/// Both bars are transparent (the app draws edge to edge), so this only picks
/// which way the OS glyphs are tinted. [SystemUiOverlayStyle.statusBarBrightness]
/// is iOS's spelling and names the *background's* brightness.
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

/// For surfaces that are dark whatever the theme says: the camera, the Now
/// Playing backdrop.
final SystemUiOverlayStyle jamOverlayStyleOnDark = jamOverlayStyle(
  Brightness.dark,
);

/// The light theme; [highContrast] for the system's Increase Contrast.
ThemeData jamLightTheme({
  TargetPlatform? platform,
  bool highContrast = false,
}) => _build(
  highContrast ? JamColors.lightHighContrast : JamColors.light,
  Brightness.light,
  platform ?? defaultTargetPlatform,
);

/// The dark theme; [highContrast] for the system's Increase Contrast.
ThemeData jamDarkTheme({TargetPlatform? platform, bool highContrast = false}) =>
    _build(
      highContrast ? JamColors.darkHighContrast : JamColors.dark,
      Brightness.dark,
      platform ?? defaultTargetPlatform,
    );

/// The keyboard to raise over [context]: the app's appearance, not the
/// device's. Every text field passes this explicitly — `CupertinoTextField`
/// only falls back to it, and a field inside a route that resets the
/// Cupertino theme would otherwise get the system's keyboard. (On iOS the
/// window's `overrideUserInterfaceStyle` is set as well — see
/// `JamSystemAppearance` — so share sheets and pickers agree too.)
Brightness jamKeyboardAppearance(BuildContext context) =>
    Theme.of(context).brightness;

ThemeData _build(JamColors c, Brightness brightness, TargetPlatform platform) {
  final type = buildJamTypeScale(platform: platform, color: c.label);
  final text = jamTextThemeFrom(type);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.tint,
    onPrimary: c.onTint,
    primaryContainer: c.tintFill,
    onPrimaryContainer: c.tint,
    secondary: c.tint,
    onSecondary: c.onTint,
    secondaryContainer: c.fillSecondary,
    onSecondaryContainer: c.label,
    tertiary: c.warning,
    onTertiary: c.onTint,
    tertiaryContainer: c.fillSecondary,
    onTertiaryContainer: c.warning,
    error: c.danger,
    onError: c.onTint,
    errorContainer: c.danger.withValues(alpha: 0.12),
    onErrorContainer: c.danger,
    surface: c.background,
    onSurface: c.label,
    onSurfaceVariant: c.secondaryLabel,
    surfaceContainerLowest: c.background,
    surfaceContainerLow: c.groupedSurface,
    surfaceContainer: c.groupedSurface,
    surfaceContainerHigh: c.elevated,
    surfaceContainerHighest: c.elevated,
    outline: c.separator,
    outlineVariant: c.separator,
    scrim: c.scrim,
    shadow: Colors.black,
    inverseSurface: c.label,
    onInverseSurface: c.background,
    inversePrimary: c.tint,
  );

  final cupertino = CupertinoThemeData(
    brightness: brightness,
    primaryColor: c.tint,
    primaryContrastingColor: c.onTint,
    scaffoldBackgroundColor: c.background,
    barBackgroundColor: c.material,
    applyThemeToAll: true,
    textTheme: CupertinoTextThemeData(
      primaryColor: c.tint,
      textStyle: type.body,
      actionTextStyle: type.body.copyWith(color: c.tint),
      actionSmallTextStyle: type.subheadline.copyWith(color: c.tint),
      tabLabelTextStyle: type.caption2.copyWith(color: c.secondaryLabel),
      navTitleTextStyle: type.headline,
      navLargeTitleTextStyle: type.largeTitle,
      navActionTextStyle: type.body.copyWith(color: c.tint),
      pickerTextStyle: type.title3.copyWith(fontWeight: FontWeight.w400),
      dateTimePickerTextStyle: type.title3.copyWith(
        fontWeight: FontWeight.w400,
      ),
    ),
  );

  /// Every Material button that slips through gets a capsule, no ripple and
  /// no elevation.
  ButtonStyle buttonBase({Color? foreground, Color? background}) => ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? c.tertiaryLabel : foreground,
    ),
    backgroundColor: background == null
        ? null
        : WidgetStateProperty.resolveWith((s) {
            if (s.contains(WidgetState.disabled)) return c.fill;
            if (s.contains(WidgetState.pressed)) return c.tintPressed;
            return background;
          }),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    textStyle: WidgetStatePropertyAll(type.headline),
    minimumSize: const WidgetStatePropertyAll(
      Size(JamMetrics.hitTarget, JamMetrics.hitTarget),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: JamSpace.lg),
    ),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: const WidgetStatePropertyAll(StadiumBorder()),
    splashFactory: NoSplash.splashFactory,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    platform: platform,
    colorScheme: scheme,
    textTheme: text,
    primaryTextTheme: text,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    dividerColor: c.separator,
    // D2: no Material ink anywhere. Presses are highlights (rows) or opacity
    // (buttons), drawn by our own components.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: c.fillPressed,
    focusColor: c.fillPressed,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    cupertinoOverrideTheme: cupertino,
    extensions: <ThemeExtension<dynamic>>[c, type],

    dividerTheme: DividerThemeData(
      color: c.separator,
      thickness: 0.5,
      space: 0.5,
    ),

    iconTheme: IconThemeData(color: c.tint, size: JamMetrics.navIcon),

    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      foregroundColor: c.label,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      systemOverlayStyle: jamOverlayStyle(brightness),
      titleTextStyle: type.headline,
      toolbarTextStyle: type.body.copyWith(color: c.tint),
      iconTheme: IconThemeData(color: c.tint, size: JamMetrics.navIcon),
      actionsIconTheme: IconThemeData(color: c.tint, size: JamMetrics.navIcon),
    ),

    cardTheme: CardThemeData(
      color: c.groupedSurface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.section),
      ),
    ),

    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: JamSpace.lg),
      minVerticalPadding: JamSpace.md,
      titleTextStyle: type.body,
      subtitleTextStyle: type.subheadline.copyWith(color: c.secondaryLabel),
      iconColor: c.tint,
      textColor: c.label,
      selectedColor: c.tint,
      selectedTileColor: Colors.transparent,
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: buttonBase(foreground: c.onTint, background: c.tintFilled),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: buttonBase(foreground: c.onTint, background: c.tintFilled),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonBase(foreground: c.tint),
    ),
    textButtonTheme: TextButtonThemeData(style: buttonBase(foreground: c.tint)),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.tint,
        disabledForegroundColor: c.tertiaryLabel,
        highlightColor: Colors.transparent,
        minimumSize: const Size(JamMetrics.hitTarget, JamMetrics.hitTarget),
      ).copyWith(splashFactory: NoSplash.splashFactory),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: c.tint,
      inactiveTrackColor: c.fill,
      thumbColor: Colors.white,
      overlayColor: Colors.transparent,
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(
        enabledThumbRadius: 14,
        elevation: 1,
        pressedElevation: 1,
      ),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
      valueIndicatorColor: c.label,
      valueIndicatorTextStyle: type.footnote.copyWith(color: c.background),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.secondaryLabel,
      linearTrackColor: c.fill,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 4,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.success : c.fill,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.tint : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(c.onTint),
      side: BorderSide(color: c.tertiaryLabel, width: 1.5),
      shape: const CircleBorder(),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),

    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.tint : c.tertiaryLabel,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: c.fillSecondary,
      selectedColor: c.tintFill,
      disabledColor: c.fillSecondary,
      surfaceTintColor: Colors.transparent,
      side: BorderSide.none,
      labelStyle: type.footnote,
      secondaryLabelStyle: type.footnote.copyWith(color: c.tint),
      shape: const StadiumBorder(),
    ),

    inputDecorationTheme: jamFilledInput(c, text),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.tint,
      selectionColor: c.tint.withValues(alpha: 0.3),
      selectionHandleColor: c.tint,
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.elevated,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.elevated,
      modalBarrierColor: c.scrim,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      dragHandleColor: c.tertiaryLabel,
      dragHandleSize: JamMetrics.grabber,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(JamRadius.sheet),
        ),
      ),
    ),

    // Stock Material dialogs that have not moved to `JamAlert` yet at least
    // take the alert's proportions and palette.
    dialogTheme: DialogThemeData(
      backgroundColor: c.elevated,
      surfaceTintColor: Colors.transparent,
      barrierColor: c.scrim,
      elevation: 0,
      titleTextStyle: type.headline,
      contentTextStyle: type.footnote,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: JamSpace.huge,
        vertical: JamSpace.xxl,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.alert),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.material,
      contentTextStyle: type.subheadline,
      actionTextColor: c.tint,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: const StadiumBorder(),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: c.elevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      textStyle: type.body,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(JamRadius.menu),
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.label.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(JamRadius.sm),
      ),
      textStyle: type.footnote.copyWith(color: c.background),
    ),

    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.material,
      indicatorColor: c.tintFill,
      elevation: 0,
      selectedLabelTextStyle: type.footnote.copyWith(color: c.tint),
      unselectedLabelTextStyle: type.footnote,
      selectedIconTheme: IconThemeData(color: c.tint, size: 22),
      unselectedIconTheme: IconThemeData(color: c.secondaryLabel, size: 22),
    ),

    // iOS's push everywhere (D2); the room's own slide-up is its own route
    // transition and is untouched by this.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// The default field: iOS's filled rounded rect — `fillSecondary`, radius 10,
/// no border; a danger hairline when in error.
InputDecorationTheme jamFilledInput(JamColors c, TextTheme text) {
  OutlineInputBorder border([BorderSide side = BorderSide.none]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(JamRadius.field),
        borderSide: side,
      );

  return InputDecorationTheme(
    filled: true,
    fillColor: c.fillSecondary,
    hintStyle: text.bodyLarge!.copyWith(color: c.tertiaryLabel),
    labelStyle: text.bodyMedium!.copyWith(color: c.secondaryLabel),
    helperStyle: text.bodySmall!.copyWith(color: c.secondaryLabel),
    errorStyle: text.bodySmall!.copyWith(color: c.danger),
    contentPadding: const EdgeInsets.symmetric(
      horizontal: JamSpace.md,
      vertical: 11,
    ),
    border: border(),
    enabledBorder: border(),
    disabledBorder: border(),
    focusedBorder: border(),
    errorBorder: border(BorderSide(color: c.danger, width: 0.5)),
    focusedErrorBorder: border(BorderSide(color: c.danger, width: 0.5)),
  );
}

/// The editable-heading field: no box at all, so a room's name reads as the
/// title it is. Hint in `tertiaryLabel` at the field's own style.
InputDecorationTheme jamBorderlessInput(JamColors c, TextTheme text) =>
    InputDecorationTheme(
      filled: false,
      isDense: true,
      hintStyle: text.displaySmall!.copyWith(color: c.tertiaryLabel),
      contentPadding: EdgeInsets.zero,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      errorStyle: text.bodySmall!.copyWith(color: c.danger),
    );
