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
  //
  // The surfaces are tinted toward navy so the whole app reads as a deep
  // dark-blue workspace rather than neutral grey (Req 8.5).

  /// The base app background — the darkest navy surface (Req 8.5).
  static const Color background = Color(0xFF0A0F1E);

  /// Raised surface (cards, the Sidebar, dialogs) sitting above [background]:
  /// a dark navy blue.
  static const Color surface = Color(0xFF111A30);

  /// A slightly lighter navy surface used for selected rows, input fills, and
  /// the active-document highlight.
  static const Color surfaceVariant = Color(0xFF1B274A);

  // --- Foreground text ----------------------------------------------------

  /// Primary text: high-emphasis body and titles. A near-white with a faint
  /// cool tint so it sits naturally over the navy surfaces.
  ///
  /// Contrast: 16.59:1 on [background], 15.02:1 on [surface], 12.71:1 on
  /// [surfaceVariant] — all well above the 4.5:1 normal-text threshold.
  static const Color textPrimary = Color(0xFFECEFF6);

  /// Secondary text: medium-emphasis labels, captions, and hints.
  ///
  /// Contrast: 10.45:1 on [background], 9.47:1 on [surface], 8.01:1 on
  /// [surfaceVariant] — all above the 4.5:1 normal-text threshold.
  static const Color textSecondary = Color(0xFFB6C0D6);

  /// Disabled / lowest-emphasis text. Reserved for large text only (>= 24 px,
  /// or bold >= 18.66 px), where the 3:1 threshold applies.
  ///
  /// Contrast: 6.28:1 on [background], 5.69:1 on [surface] — above the 3:1
  /// large-text threshold.
  static const Color textDisabled = Color(0xFF8894B0);

  // --- Accent / semantic --------------------------------------------------

  /// Primary accent for interactive controls (buttons, links, focus rings):
  /// a bright dark-blue that reads clearly on the navy surfaces.
  ///
  /// Contrast: 8.00:1 on [background], 7.25:1 on [surface] as text/icon color;
  /// above the 4.5:1 normal-text threshold.
  static const Color primary = Color(0xFF7FA6FF);

  /// Foreground drawn on top of [primary] (e.g. filled-button label): a very
  /// dark navy.
  ///
  /// Contrast: 7.91:1 on [primary] — above the 4.5:1 normal-text threshold.
  static const Color onPrimary = Color(0xFF0A1024);

  /// Secondary accent: a dark-cyan used for secondary controls, toggles, and
  /// highlights so the UI has a second hue alongside the navy blue.
  ///
  /// Contrast: 11.01:1 on [background], 9.97:1 on [surface] as text/icon
  /// color; above the 4.5:1 normal-text threshold.
  static const Color secondary = Color(0xFF3FD8E0);

  /// Foreground drawn on top of [secondary] (e.g. a filled secondary control):
  /// a very dark teal.
  ///
  /// Contrast: 9.62:1 on [secondary] — above the 4.5:1 normal-text threshold.
  static const Color onSecondary = Color(0xFF042224);

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

  // --- Modern UI tints (non-text, additive) -------------------------------
  //
  // These are decorative, non-text colors used only for gradients, hairline
  // borders, and hover overlays in the modernized surfaces. They are not text
  // foreground/background pairs, so the WCAG contrast pairs in [textPairs] are
  // unaffected; all existing text still uses the verified colors above.

  /// A soft hairline border used around cards and pills — a low-alpha lift of
  /// the primary accent so edges read as a subtle glow rather than a hard grey
  /// line.
  static const Color hairline = Color(0x1F7FA6FF);

  /// A very subtle top-highlight used on raised surfaces for a soft bevel.
  static const Color sheen = Color(0x0FFFFFFF);

  /// Hover overlay tint for interactive rows / cards.
  static const Color hoverOverlay = Color(0x147FA6FF);

  /// Pressed / focused overlay tint, one step stronger than [hoverOverlay].
  static const Color pressedOverlay = Color(0x297FA6FF);

  /// The keyboard focus ring: the dark-cyan accent, so focus reads clearly
  /// and distinctly from the blue hover/selection border.
  static const Color focusRing = secondary;

  /// A deeper navy used as the bottom stop of raised-surface gradients
  /// (title bar, cards, sidebar).
  static const Color surfaceDeep = Color(0xFF0E1729);

  /// The mid stop of the ambient app-background wash.
  static const Color backgroundMid = Color(0xFF0C1226);

  /// The light tile behind the Spwrite logo, whose art is drawn for a light
  /// background. Non-text (decorative).
  static const Color logoTile = Color(0xFFFFFFFF);

  /// A translucent navy scrim laid over cover photos behind overlaid
  /// controls. Non-text on its own; any text drawn over it is textPrimary.
  static const Color coverScrim = Color(0xB30A0F1E);

  /// Scrollbar thumb tint (non-text).
  static const Color scrollbarThumb = Color(0x667FA6FF);

  /// Ambient drop-shadow color for raised cards.
  static const Color shadowAmbient = Color(0x66000000);

  /// Stronger drop-shadow color for lifted (hovered) cards and dialogs.
  static const Color shadowStrong = Color(0x80000000);

  /// The accent-tinted glow under a hovered card.
  static const Color shadowGlow = Color(0x337FA6FF);

  /// Fully transparent, for Material surfaces that must not paint.
  static const Color transparent = Color(0x00000000);

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
    secondary,
    onSecondary,
    error,
    onError,
    outline,
    hairline,
    sheen,
    hoverOverlay,
    pressedOverlay,
    surfaceDeep,
    backgroundMid,
    logoTile,
    coverScrim,
    scrollbarThumb,
    shadowAmbient,
    shadowStrong,
    shadowGlow,
    transparent,
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
    // Secondary (dark-cyan) accent used as text/icon color.
    TextColorPair(
      label: 'secondary on background',
      foreground: secondary,
      background: background,
      sizeClass: TextSizeClass.normal,
    ),
    TextColorPair(
      label: 'secondary on surface',
      foreground: secondary,
      background: surface,
      sizeClass: TextSizeClass.normal,
    ),
    // Foreground on the secondary accent (filled secondary controls).
    TextColorPair(
      label: 'onSecondary on secondary',
      foreground: onSecondary,
      background: secondary,
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

/// The spacing scale. Every padding / gap in the modernized surfaces is drawn
/// from these steps so rhythm stays consistent across the app.
class AppSpacing {
  const AppSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Motion tokens: short, consistent durations so hover/focus feedback feels
/// responsive without being showy.
class AppMotion {
  const AppMotion._();

  /// Hover / focus / press feedback.
  static const Duration fast = Duration(milliseconds: 120);

  /// Panel and content transitions.
  static const Duration medium = Duration(milliseconds: 200);

  /// The standard easing curve.
  static const Curve curve = Curves.easeOutCubic;
}

/// Modern, decorative design tokens layered on top of [AppPalette]: corner
/// radii, gradients, hairline borders, and soft shadows.
///
/// These are purely visual (shape / gradient / elevation) and never introduce a
/// new text-on-background pair, so the WCAG contrast contract in
/// [AppPalette.textPairs] is untouched — every gradient is built from existing
/// palette colors and is only ever used behind palette-verified text.
class AppStyle {
  const AppStyle._();

  /// Standard corner radius for cards, dialogs, and large surfaces.
  static const double radiusLarge = 18;

  /// Corner radius for medium controls (buttons, tiles, name fields).
  static const double radiusMedium = 12;

  /// Corner radius for small pills (status chips, badges).
  static const double radiusSmall = 10;

  /// Rounded rectangle border for cards / dialogs.
  static const BorderRadius cardRadius =
      BorderRadius.all(Radius.circular(radiusLarge));

  /// Rounded rectangle border for medium controls.
  static const BorderRadius controlRadius =
      BorderRadius.all(Radius.circular(radiusMedium));

  /// Rounded rectangle border for small pills.
  static const BorderRadius pillRadius =
      BorderRadius.all(Radius.circular(radiusSmall));

  /// The ambient app background: a deep navy diagonal wash from the darkest
  /// base into the raised surface tone, giving the flat background subtle
  /// depth rather than a single solid fill.
  static const LinearGradient appBackground = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[
      AppPalette.background,
      AppPalette.backgroundMid,
      AppPalette.surface,
    ],
    stops: <double>[0.0, 0.55, 1.0],
  );

  /// A raised-card gradient: a gentle top-to-bottom lift from the surface tone
  /// into the slightly lighter variant so cards feel dimensional.
  static const LinearGradient cardSurface = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      AppPalette.surface,
      AppPalette.surfaceDeep,
    ],
  );

  /// A vertical surface wash for sidebars and title bars.
  static const LinearGradient panelSurface = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      AppPalette.surface,
      AppPalette.surfaceDeep,
    ],
  );

  /// A bottom-up scrim over a cover photo so overlaid controls stay legible.
  static const LinearGradient coverScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: <Color>[AppPalette.coverScrim, AppPalette.transparent],
  );

  /// The brand accent gradient (blue → cyan) used for the logo chip, avatars,
  /// and primary call-to-action fills.
  static const LinearGradient accent = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[
      AppPalette.primary,
      AppPalette.secondary,
    ],
  );

  /// Soft ambient shadow for raised cards.
  static const List<BoxShadow> cardShadow = <BoxShadow>[
    BoxShadow(
      color: AppPalette.shadowAmbient,
      blurRadius: 18,
      offset: Offset(0, 8),
    ),
  ];

  /// A lifted shadow used on hover, with an accent-tinted glow.
  static const List<BoxShadow> hoverShadow = <BoxShadow>[
    BoxShadow(
      color: AppPalette.shadowStrong,
      blurRadius: 26,
      offset: Offset(0, 12),
    ),
    BoxShadow(
      color: AppPalette.shadowGlow,
      blurRadius: 30,
      spreadRadius: -6,
      offset: Offset(0, 6),
    ),
  ];

  /// A hairline border used around cards and pills.
  static const Border hairlineBorder = Border.fromBorderSide(
    BorderSide(color: AppPalette.hairline),
  );

  /// The width of the visible keyboard focus ring.
  static const double focusRingWidth = 2;

  /// The cover-photo aspect ratio (width ÷ height) used by every cover
  /// thumbnail: a portrait 1:1.6 book cover.
  static const double coverAspectRatio = 1 / 1.6;
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
    // Secondary is the dark-cyan accent (the palette's second hue).
    secondary: AppPalette.secondary,
    onSecondary: AppPalette.onSecondary,
    secondaryContainer: AppPalette.surfaceVariant,
    onSecondaryContainer: AppPalette.textPrimary,
    // Tertiary reuses the dark-cyan accent so no fourth hue is introduced.
    tertiary: AppPalette.secondary,
    onTertiary: AppPalette.onSecondary,
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

    // A text theme whose every style uses a palette foreground color, with a
    // clear desktop hierarchy: headline (screen titles) → title (panels,
    // cards) → body → label (buttons, chips, captions).
    const textTheme = TextTheme(
      displayLarge: TextStyle(color: AppPalette.textPrimary),
      displayMedium: TextStyle(color: AppPalette.textPrimary),
      displaySmall: TextStyle(color: AppPalette.textPrimary),
      headlineLarge: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      headlineMedium: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      headlineSmall: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      titleLarge: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 19,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleMedium: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: AppPalette.textPrimary, fontSize: 15),
      bodyMedium: TextStyle(color: AppPalette.textPrimary, fontSize: 14),
      bodySmall: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
      labelLarge: TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: TextStyle(
        color: AppPalette.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: TextStyle(
        color: AppPalette.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
      ),
    );

    // A visible focus ring for keyboard navigation, applied to every button
    // family so Tab focus is always obvious on desktop.
    BorderSide? focusSide(Set<WidgetState> states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(
          color: AppPalette.focusRing,
          width: AppStyle.focusRingWidth,
        );
      }
      return null;
    }

    // Shared hover / focus / press overlays for buttons.
    Color? overlay(Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return AppPalette.pressedOverlay;
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return AppPalette.hoverOverlay;
      }
      return null;
    }

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
      // Mouse + keyboard feedback colors for ink responses (cards, rows).
      hoverColor: AppPalette.hoverOverlay,
      focusColor: AppPalette.pressedOverlay,
      highlightColor: AppPalette.pressedOverlay,
      splashColor: AppPalette.hoverOverlay,
      // Desktop-visible scrollbars: always show a slim thumb so long lists
      // advertise that they scroll; the track appears on hover.
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll<bool>(true),
        trackVisibility: WidgetStateProperty.resolveWith<bool>(
          (Set<WidgetState> states) => states.contains(WidgetState.hovered),
        ),
        thickness: const WidgetStatePropertyAll<double>(6),
        radius: const Radius.circular(AppStyle.radiusSmall),
        thumbColor: const WidgetStatePropertyAll<Color>(
          AppPalette.scrollbarThumb,
        ),
        trackColor: const WidgetStatePropertyAll<Color>(AppPalette.sheen),
        trackBorderColor: const WidgetStatePropertyAll<Color>(
          AppPalette.transparent,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppPalette.surface,
        foregroundColor: AppPalette.textPrimary,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: AppPalette.surface,
        surfaceTintColor: AppPalette.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppStyle.cardRadius,
          side: BorderSide(color: AppPalette.hairline),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppPalette.surface,
        surfaceTintColor: AppPalette.surface,
        elevation: 0,
        shadowColor: AppPalette.shadowStrong,
        insetPadding: EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.xl,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: AppStyle.cardRadius,
          side: BorderSide(color: AppPalette.hairline),
        ),
        titleTextStyle: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
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
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppStyle.controlRadius,
          side: BorderSide(color: AppPalette.hairline),
        ),
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
          overlayColor: WidgetStateProperty.resolveWith<Color?>(overlay),
          side: WidgetStateProperty.resolveWith<BorderSide?>(focusSide),
          // Comfortable mouse targets on desktop without bloating toolbars.
          minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppStyle.controlRadius),
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
        waitDuration: Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: AppPalette.surfaceVariant,
          borderRadius: AppStyle.pillRadius,
          border: Border.fromBorderSide(
            BorderSide(color: AppPalette.hairline),
          ),
        ),
        textStyle: TextStyle(color: AppPalette.textPrimary),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith<BorderSide?>(focusSide),
          backgroundColor: const WidgetStatePropertyAll(AppPalette.primary),
          foregroundColor: const WidgetStatePropertyAll(AppPalette.onPrimary),
          elevation: const WidgetStatePropertyAll(0),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w600),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppStyle.controlRadius),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith<BorderSide?>(focusSide),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>(
            (Set<WidgetState> states) => states.contains(WidgetState.disabled)
                ? AppPalette.surfaceVariant
                : AppPalette.primary,
          ),
          foregroundColor: const WidgetStatePropertyAll(AppPalette.onPrimary),
          elevation: const WidgetStatePropertyAll(0),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w600),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppStyle.controlRadius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith<BorderSide?>(focusSide),
          overlayColor: WidgetStateProperty.resolveWith<Color?>(overlay),
          foregroundColor: const WidgetStatePropertyAll(AppPalette.primary),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppStyle.controlRadius),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(AppPalette.primary),
          overlayColor: WidgetStateProperty.resolveWith<Color?>(overlay),
          side: WidgetStateProperty.resolveWith<BorderSide?>(
            (Set<WidgetState> states) =>
                focusSide(states) ??
                BorderSide(
                  color: states.contains(WidgetState.hovered)
                      ? AppPalette.primary
                      : AppPalette.hairline,
                ),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppStyle.controlRadius),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.surfaceVariant,
        hintStyle: TextStyle(color: AppPalette.textSecondary),
        labelStyle: TextStyle(color: AppPalette.textSecondary),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: AppStyle.controlRadius,
          borderSide: BorderSide(color: AppPalette.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppStyle.controlRadius,
          borderSide: BorderSide(color: AppPalette.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppStyle.controlRadius,
          borderSide: BorderSide(color: AppPalette.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppStyle.controlRadius,
          borderSide: BorderSide(color: AppPalette.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppStyle.controlRadius,
          borderSide: BorderSide(color: AppPalette.error, width: 2),
        ),
        errorStyle: TextStyle(color: AppPalette.error),
      ),
    );
  }
}
