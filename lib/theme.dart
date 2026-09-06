import 'package:flutter/material.dart';
import 'palette_active.dart';

/// Semantic colour roles. The values come from [palette_active.dart] so a
/// palette swap needs no changes here or at any call site.
class PaheColors {
  static const bg = kBg;
  static const surface = kSurface;
  static const card = kCard;
  static const cardHover = kCardHover;
  static const border = kBorder;

  /// Primary brand colour — buttons, active nav, progress.
  static const accent = kAccent;
  static const accentLight = kAccentLight;

  /// Secondary brand colour — the other half of the gradient.
  static const accent2 = kAccent2;
  static const accent2Light = kAccent2Light;

  /// Marks subtitled sources, paired against [accent2] for dubbed ones.
  static const info = kInfo;

  static const textPrimary = kTextPrimary;
  static const textSecondary = kTextSecondary;
  static const textMuted = kTextMuted;

  static const green = kGreen;
  static const amber = kAmber;
  static const red = kRed;
  static const blue = kBlue;

  static const gradient = LinearGradient(
    colors: [kAccent, kAccent2],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientCard = LinearGradient(
    colors: [kGradientCardA, kGradientCardB],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class PaheTheme {
  static ThemeData get theme => kIsLight ? _build(Brightness.light) : _build(Brightness.dark);

  /// Kept so existing `PaheTheme.dark` references still resolve.
  static ThemeData get dark => theme;

  static TextTheme _fontOf(TextTheme base) =>
      base.apply(fontFamily: kFontFamily);

  static TextStyle _font({
    required double size,
    required FontWeight weight,
    Color? color,
    double? spacing,
    double? height,
  }) =>
      TextStyle(
        fontFamily: kFontFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: spacing,
        height: height,
      );

  static ThemeData _build(Brightness brightness) {
    final base =
        brightness == Brightness.light ? ThemeData.light(useMaterial3: true) : ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: PaheColors.bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: PaheColors.accent,
        onPrimary: kOnAccent,
        secondary: PaheColors.accent2,
        onSecondary: kOnAccent,
        surface: PaheColors.surface,
        onSurface: PaheColors.textPrimary,
        error: PaheColors.red,
        onError: Colors.white,
        outline: PaheColors.border,
      ),
      textTheme: _fontOf(base.textTheme).copyWith(
        displayLarge: _font(size: 28, weight: FontWeight.w800, color: PaheColors.textPrimary),
        titleLarge: _font(size: 18, weight: FontWeight.w700, color: PaheColors.textPrimary),
        bodyMedium: _font(size: 14, weight: FontWeight.w500, color: PaheColors.textSecondary),
        labelSmall: _font(size: 11, weight: FontWeight.w600, color: PaheColors.textMuted, spacing: 0.8),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: PaheColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: _font(size: 20, weight: FontWeight.w800, color: PaheColors.textPrimary),
        iconTheme: const IconThemeData(color: PaheColors.textSecondary),
      ),
      cardTheme: CardThemeData(
        color: PaheColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
          side: const BorderSide(color: PaheColors.border),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: PaheColors.card,
        hintStyle: _font(size: 14, weight: FontWeight.w500, color: PaheColors.textMuted),
        border: _inputBorder(PaheColors.border),
        enabledBorder: _inputBorder(PaheColors.border),
        focusedBorder: _inputBorder(PaheColors.accent, width: 2),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: PaheColors.surface,
        selectedItemColor: PaheColors.accent,
        unselectedItemColor: PaheColors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(color: PaheColors.border, space: 1, thickness: 1),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: PaheColors.accent,
        linearTrackColor: PaheColors.border,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: PaheColors.card,
        selectedColor: PaheColors.accent.withValues(alpha: 0.3),
        labelStyle: _font(size: 12, weight: FontWeight.w600, color: PaheColors.textSecondary),
        side: const BorderSide(color: PaheColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius * 0.5)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: PaheColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: PaheColors.border),
        ),
        textStyle: _font(size: 11, weight: FontWeight.w600, color: PaheColors.textPrimary),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color c, {double width = 1}) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadius),
        borderSide: BorderSide(color: c, width: width),
      );
}
