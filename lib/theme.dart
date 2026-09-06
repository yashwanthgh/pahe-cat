import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class PaheColors {
  static const bg = Color(0xFF0A0A14);
  static const surface = Color(0xFF13131F);
  static const card = Color(0xFF1A1A2E);
  static const cardHover = Color(0xFF1E1E35);
  static const border = Color(0xFF2A2A40);

  static const purple = Color(0xFF9B59FF);
  static const purpleLight = Color(0xFFBB86FC);
  static const pink = Color(0xFFFF6B9D);
  static const pinkLight = Color(0xFFFF8FB1);
  static const cyan = Color(0xFF00D9C0);

  static const textPrimary = Color(0xFFF0EEFF);
  static const textSecondary = Color(0xFFB0A8CC);
  static const textMuted = Color(0xFF6B6486);

  // Status
  static const green = Color(0xFF4ADE80);
  static const amber = Color(0xFFFFB347);
  static const red = Color(0xFFFF6B6B);
  static const blue = Color(0xFF60A5FA);

  static const gradient = LinearGradient(
    colors: [purple, pink],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const gradientCard = LinearGradient(
    colors: [Color(0xFF1A1A2E), Color(0xFF16162A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class PaheTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: PaheColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: PaheColors.purple,
        secondary: PaheColors.pink,
        surface: PaheColors.surface,
        onSurface: PaheColors.textPrimary,
        outline: PaheColors.border,
      ),
      textTheme: GoogleFonts.nunitoTextTheme(base.textTheme).copyWith(
        displayLarge: GoogleFonts.nunito(
          color: PaheColors.textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w800,
        ),
        titleLarge: GoogleFonts.nunito(
          color: PaheColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        bodyMedium: GoogleFonts.nunito(
          color: PaheColors.textSecondary,
          fontSize: 14,
        ),
        labelSmall: GoogleFonts.nunito(
          color: PaheColors.textMuted,
          fontSize: 11,
          letterSpacing: 0.8,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: PaheColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.nunito(
          color: PaheColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
        iconTheme: const IconThemeData(color: PaheColors.textSecondary),
      ),
      cardTheme: CardThemeData(
        color: PaheColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: PaheColors.border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: PaheColors.card,
        hintStyle: GoogleFonts.nunito(color: PaheColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: PaheColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: PaheColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: PaheColors.purple, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: PaheColors.surface,
        selectedItemColor: PaheColors.purple,
        unselectedItemColor: PaheColors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: PaheColors.border,
        space: 1,
        thickness: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: PaheColors.purple,
        linearTrackColor: PaheColors.border,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: PaheColors.card,
        selectedColor: PaheColors.purple.withOpacity(0.3),
        labelStyle: GoogleFonts.nunito(
          color: PaheColors.textSecondary,
          fontSize: 12,
        ),
        side: const BorderSide(color: PaheColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
