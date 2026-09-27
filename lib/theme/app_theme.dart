/// Theme layer: the single centrally-defined dark-mode palette and the one
/// [ThemeData] ([AppTheme.dark]) the root `MaterialApp` applies before any
/// surface renders (Req 8.1, 8.2, 8.4, 8.5).
///
/// Every text element and interactive control color slot in [AppTheme.dark] is
/// drawn only from [AppPalette]; no slot retains a light-mode or
/// system-default color (Req 8.5). The foreground-on-background text pairs the
/// theme actually uses are enumerated in [AppPalette.textPairs] together with
/// their size class, so the WCAG contrast property test (Property 10) and the
/// palette-membership property test (Property 11) can verify them directly.
library;

import 'package:flutter/material.dart';

/// The size class of a text-on-background pair, which selects the WCAG
/// contrast threshold that applies (Req 8.3).
enum TextSizeClass {
  /// Normal text: requires a contrast ratio of at least 4.5:1 (Req 8.3).
  normal,

  /// Large text — at least 24 px, or bold at 18.66 px or larger — requires a
  /// contrast ratio of at least 3:1 (Req 8.3).
  large,
}

/// A foreground-on-background color pairing used by the theme, tagged with the
/// [TextSizeClass] that determines its required WCAG contrast ratio.
///
/// The palette exposes the full set of such pairs it uses ([AppPalette.textPairs])
/// so contrast can be verified exhaustively (Property 10).
class TextColorPair {
  /// A human-readable label identifying where this pair is used, for
  /// diagnostics in verification output.
  final String label;

  /// The text (foreground) color.
  final Color foreground;

  /// The color immediately behind the text.
  final Color background;

  /// Normal vs. large text, which selects the applicable contrast threshold.
  final TextSizeClass sizeClass;

  const TextColorPair({
    required this.label,
    required this.foreground,
    required this.background,
    required this.sizeClass,
  });

  /// The minimum WCAG contrast ratio required for this pair's size class:
  /// 4.5:1 for [TextSizeClass.normal], 3:1 for [TextSizeClass.large] (Req 8.3).
  double get requiredContrast =>
      sizeClass == TextSizeClass.large ? 3.0 : 4.5;
}

/// The dark-mode color palette. Every color the theme assigns comes from this
/// set (Req 8.5). Colors were chosen so that each foreground-on-background text
/// pair in [textPairs] meets its WCAG contrast threshold (Req 8.3); see the
/// per-color documentation for the computed ratios.
class AppPalette {
  const AppPalette._();

  // --- Backgrounds / surfaces --------------------------------------------

  /// The base app background — the darkest surface (Req 8.5).
  static const Color background = Color(0xFF121212);

  /// Raised surface (cards, the Sidebar, dialogs) sitting above [background].
  static const Color surface = Color(0xFF1E1E1E);

  /// A slightly lighter surface used for selected rows, input fills, and the
  /// active-document highlight.
  static const Color surfaceVariant = Color(0xFF2A2A2A);

  // --- Foreground text ----------------------------------------------------

  /// Primary text: high-emphasis body and titles.
  ///
  /// Contrast: 15.86:1 on [background], 14.11:1 on [surface], 12.15:1 on
  /// [surfaceVariant] — all well above the 4.5:1 normal-text threshold.
  static const Color textPrimary = Color(0xFFECECEC);

  /// Secondary text: medium-emphasis labels, captions, and hints.
  ///
  /// Contrast: 9.34:1 on [background], 8.31:1 on [surface], 7.16:1 on
  /// [surfaceVariant] — all above the 4.5:1 normal-text threshold.
  static const Color textSecondary = Color(0xFFB7B7B7);

  /// Disabled / lowest-emphasis text. Reserved for large text only (>= 24 px,
  /// or bold >= 18.66 px), where the 3:1 threshold applies.
  ///
  /// Contrast: 5.43:1 on [background], 4.83:1 on [surface] — above the 3:1
  /// large-text threshold.
  static const Color textDisabled = Color(0xFF8A8A8A);

  // --- Accent / semantic --------------------------------------------------

  /// Primary accent for interactive controls (buttons, links, focus rings).
  ///
  /// Contrast: 8.16:1 on [background], 7.26:1 on [surface] as text/icon color;
  /// above the 4.5:1 normal-text threshold.
  static const Color primary = Color(0xFF82AAFF);

  /// Foreground drawn on top of [primary] (e.g. filled-button label).
  ///
  /// Contrast: 7.57:1 on [primary] — above the 4.5:1 normal-text threshold.
  static const Color onPrimary = Color(0xFF0A1A33);

  /// Error accent for validation messages and destructive actions.
  ///
  /// Contrast: 6.75:1 on [background], 6.01:1 on [surface] as text; above the
  /// 4.5:1 normal-text threshold.
  static const Color error = Color(0xFFFF6B6B);

  /// Foreground drawn on top of [error] (e.g. error snackbar text).
  ///
  /// Contrast: 6.60:1 on [error] — above the 4.5:1 normal-text threshold.
  static const Color onError = Color(0xFF2A0A0A);

  // --- Lines --------------------------------------------------------------

  /// Border / divider / outline color. Non-text; used for input borders and
  /// list dividers, so text-contrast thresholds do not apply to it.
  static const Color outline = Color(0xFF5C5C5C);

  /// Every color defined in the palette. Property 11 asserts each themed color
  /// slot is a member of this set.
  static const List<Color> all = <Color>[
    background,
    surface,
    surfaceVariant,
    textPrimary,
    textSecondary,
    textDisabled,
    primary,
    onPrimary,
    error,
    onError,
    outline,
  ];

  /// The complete set of foreground-on-background text pairs the theme uses,
  /// each tagged with its [TextSizeClass]. Property 10 enumerates these and
  /// asserts every pair meets its WCAG contrast threshold (Req 8.3).
  static const List<TextColorPair> textPairs = <TextColorPair>[
    // Primary text over each background surface.
    TextColorPair(
      label: 'textPrimary on background',
      foreground: textPrimary,
      background: background,
      sizeClass: TextSizeClass.normal,
    ),
    TextColorPair(
      label: 'textPrimary on surface',
      foreground: textPrimary,
      background: surface,
      sizeClass: TextSizeClass.normal,
    ),
    TextColorPair(
      label: 'textPrimary on surfaceVariant',
      foreground: textPrimary,
      background: surfaceVariant,
      sizeClass: TextSizeClass.normal,
    ),
    // Secondary text over each background surface.
    TextColorPair(
      label: 'textSecondary on background',
      foreground: textSecondary,
      background: background,
      sizeClass: TextSizeClass.normal,
    ),
    TextColorPair(
      label: 'textSecondary on surface',
      foreground: textSecondary,
      background: surface,
      sizeClass: TextSizeClass.normal,
    ),
    TextColorPair(
      label: 'textSecondary on surfaceVariant',
      foreground: textSecondary,
      background: surfaceVariant,
      sizeClass: TextSizeClass.normal,
    ),
    // Disabled text is reserved for large text only (3:1 threshold).
    TextColorPair(
      label: 'textDisabled on background (large)',
      foreground: textDisabled,
      background: background,
      sizeClass: TextSizeClass.large,
    ),
    TextColorPair(
      label: 'textDisabled on surface (large)',
      foreground: textDisabled,
      background: surface,
      sizeClass: TextSizeClass.large,
    ),
    // Primary accent used as text/icon color.
    TextColorPair(
      label: 'primary on background',
      foreground: primary,
      background: background,
      sizeClass: TextSizeClass.normal,
    ),
    TextColorPair(
      label: 'primary on surface',
      foreground: primary,
      background: surface,
      sizeClass: TextSizeClass.normal,
    ),
    // Foreground on the primary accent (filled controls).
    TextColorPair(
      label: 'onPrimary on primary',
      foreground: onPrimary,
      background: primary,
      sizeClass: TextSizeClass.normal,
    ),
    // Error accent as text over surfaces.
    TextColorPair(
      label: 'error on background',
      foreground: error,
      background: background,
      sizeClass: TextSizeClass.normal,
    ),
    TextColorPair(
      label: 'error on surface',
      foreground: error,
      background: surface,
      sizeClass: TextSizeClass.normal,
    ),
    // Foreground on the error accent (error snackbar).
    TextColorPair(
      label: 'onError on error',
      foreground: onError,
      background: error,
      sizeClass: TextSizeClass.normal,
    ),
  ];
}

/// Builds and exposes the application's dark theme.
///
/// [AppTheme.dark] is the single [ThemeData] the root `MaterialApp` applies so
/// every surface — Sidebar, Editor, and all dialogs — inherits the dark
/// palette before it renders (Req 8.1, 8.2, 8.4). Every text and interactive
/// control color slot is assigned from [AppPalette] (Req 8.5).
class AppTheme {
  const AppTheme._();

  /// The dark [ColorScheme] built entirely from [AppPalette]. Exposed so
  /// verification can confirm each scheme slot is a palette member (Property 11).
  ///
  /// **Every** slot is assigned from [AppPalette] — not only the handful of
  /// slots the v1 surfaces touched. The `flutter_quill` toolbar and the new
  /// Dashboard / Project_Sidebar surfaces resolve Material defaults through a
  /// range of scheme slots (container, tint, surface-tone, and inverse slots)
  /// that would otherwise fall back to `ColorScheme.dark`'s system-default
  /// colors — colors that are not members of this palette. Assigning all of
  /// them keeps every themed slot palette-drawn (Req 18.5, Property 15).
  static const ColorScheme darkColorScheme = ColorScheme(
    brightness: Brightness.dark,
    // Primary accent family.
    primary: AppPalette.primary,
    onPrimary: AppPalette.onPrimary,
    primaryContainer: AppPalette.surfaceVariant,
    onPrimaryContainer: AppPalette.textPrimary,
    // Secondary reuses the accent (single-accent palette).
    secondary: AppPalette.primary,
    onSecondary: AppPalette.onPrimary,
    secondaryContainer: AppPalette.surfaceVariant,
    onSecondaryContainer: AppPalette.textPrimary,
    // Tertiary also reuses the accent so no third hue is introduced.
    tertiary: AppPalette.primary,
    onTertiary: AppPalette.onPrimary,
    tertiaryContainer: AppPalette.surfaceVariant,
    onTertiaryContainer: AppPalette.textPrimary,
    // Error family.
    error: AppPalette.error,
    onError: AppPalette.onError,
    errorContainer: AppPalette.surfaceVariant,
    onErrorContainer: AppPalette.error,
    // Surface / background tones. The Material 3 surface-container ramp is
    // mapped across the three palette surfaces so raised toolbar/menu
    // surfaces stay dark.
    surface: AppPalette.surface,
    onSurface: AppPalette.textPrimary,
    surfaceDim: AppPalette.background,
    surfaceBright: AppPalette.surfaceVariant,
    surfaceContainerLowest: AppPalette.background,
    surfaceContainerLow: AppPalette.surface,
    surfaceContainer: AppPalette.surface,
    surfaceContainerHigh: AppPalette.surfaceVariant,
    surfaceContainerHighest: AppPalette.surfaceVariant,
    onSurfaceVariant: AppPalette.textSecondary,
    // Lines.
    outline: AppPalette.outline,
    outlineVariant: AppPalette.outline,
    // Inverse slots (snackbars, selection handles on inverse surfaces).
    inverseSurface: AppPalette.textPrimary,
    onInverseSurface: AppPalette.background,
    inversePrimary: AppPalette.primary,
    // Overlays. The M3 surface tint is pinned to a surface color so elevated
    // surfaces are not tinted toward a non-palette hue.
    surfaceTint: AppPalette.surface,
    shadow: AppPalette.background,
    scrim: AppPalette.background,
  );

  /// The application's single dark theme. Text, icon, button, input, dialog,
  /// app-bar, and divider slots are all drawn from [AppPalette] so no surface
  /// falls back to a light-mode or system-default color (Req 8.5).
  static final ThemeData dark = _buildDark();

  static ThemeData _buildDark() {
    const scheme = darkColorScheme;

    // A text theme whose every style uses a palette foreground color.
    const textTheme = TextTheme(
      displayLarge: TextStyle(color: AppPalette.textPrimary),
      displayMedium: TextStyle(color: AppPalette.textPrimary),
      displaySmall: TextStyle(color: AppPalette.textPrimary),
      headlineLarge: TextStyle(color: AppPalette.textPrimary),
      headlineMedium: TextStyle(color: AppPalette.textPrimary),
      headlineSmall: TextStyle(color: AppPalette.textPrimary),
      titleLarge: TextStyle(color: AppPalette.textPrimary),
      titleMedium: TextStyle(color: AppPalette.textPrimary),
      titleSmall: TextStyle(color: AppPalette.textPrimary),
      bodyLarge: TextStyle(color: AppPalette.textPrimary),
      bodyMedium: TextStyle(color: AppPalette.textPrimary),
      bodySmall: TextStyle(color: AppPalette.textSecondary),
      labelLarge: TextStyle(color: AppPalette.textPrimary),
      labelMedium: TextStyle(color: AppPalette.textSecondary),
      labelSmall: TextStyle(color: AppPalette.textSecondary),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppPalette.background,
      canvasColor: AppPalette.background,
      dividerColor: AppPalette.outline,
      textTheme: textTheme,
      // Ensure the primary swatch never resolves to a Material default.
      primaryColor: AppPalette.primary,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppPalette.surface,
        foregroundColor: AppPalette.textPrimary,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: AppPalette.surface,
        surfaceTintColor: AppPalette.surface,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppPalette.surface,
        surfaceTintColor: AppPalette.surface,
        titleTextStyle: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(color: AppPalette.textPrimary),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: AppPalette.surface,
        surfaceTintColor: AppPalette.surface,
      ),
      dividerTheme: const DividerThemeData(color: AppPalette.outline),
      iconTheme: const IconThemeData(color: AppPalette.textPrimary),
      listTileTheme: const ListTileThemeData(
        textColor: AppPalette.textPrimary,
        iconColor: AppPalette.textSecondary,
        selectedColor: AppPalette.textPrimary,
        selectedTileColor: AppPalette.surfaceVariant,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppPalette.surfaceVariant,
        contentTextStyle: TextStyle(color: AppPalette.textPrimary),
        actionTextColor: AppPalette.primary,
      ),
      // The flutter_quill `EditorToolbar` renders each control as an
      // `IconButton` (unselected) or `IconButton.filled` (active/toggled),
      // and its heading control as a `MenuAnchor`. Without explicit slots
      // these fall back to Material defaults — a filled toggle would use the
      // primary/onPrimary pair (fine) but its disabled and unselected tones
      // resolve to non-palette defaults. Pin every state to a palette color so
      // the Toolbar has no light-mode/system-default fallback (Req 18.2, 18.5).
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          // Unselected control foreground.
          foregroundColor: const WidgetStatePropertyAll(
            AppPalette.textSecondary,
          ),
          // Selected/toggled (IconButton.filled) fill + foreground.
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.selected)) {
              return AppPalette.primary;
            }
            return null;
          }),
          overlayColor: const WidgetStatePropertyAll(
            AppPalette.surfaceVariant,
          ),
        ),
      ),
      // The heading control opens a `MenuAnchor`; its surface and the buttons
      // inside it must stay dark (Req 18.2, 18.5).
      menuTheme: const MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(AppPalette.surface),
          surfaceTintColor: WidgetStatePropertyAll(AppPalette.surface),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(AppPalette.textPrimary),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return AppPalette.surfaceVariant;
            }
            return AppPalette.surface;
          }),
        ),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AppPalette.surface,
        surfaceTintColor: AppPalette.surface,
        textStyle: TextStyle(color: AppPalette.textPrimary),
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(AppPalette.surface),
          surfaceTintColor: WidgetStatePropertyAll(AppPalette.surface),
        ),
        textStyle: TextStyle(color: AppPalette.textPrimary),
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(color: AppPalette.surfaceVariant),
        textStyle: TextStyle(color: AppPalette.textPrimary),
      ),
      elevatedButtonTheme: const ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(AppPalette.primary),
          foregroundColor: WidgetStatePropertyAll(AppPalette.onPrimary),
        ),
      ),
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(AppPalette.primary),
        ),
      ),
      outlinedButtonTheme: const OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(AppPalette.primary),
          side: WidgetStatePropertyAll(
            BorderSide(color: AppPalette.outline),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.surfaceVariant,
        hintStyle: TextStyle(color: AppPalette.textSecondary),
        labelStyle: TextStyle(color: AppPalette.textSecondary),
        border: OutlineInputBorder(
          borderSide: BorderSide(color: AppPalette.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppPalette.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppPalette.primary),
        ),
        errorBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppPalette.error),
        ),
        errorStyle: TextStyle(color: AppPalette.error),
      ),
    );
  }
}
