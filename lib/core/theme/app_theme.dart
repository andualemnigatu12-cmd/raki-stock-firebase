import 'package:flutter/material.dart';

/// Shared Raki Stock visual language for Android and the owner website.
///
/// Web tokens in web-owner/index.html:
///   canvas #080D16, panel #131C2C, raised #192438, line #2A3447,
///   action #4B94FF, text #F8FBFF, muted #8D9DB2.
abstract final class AppTheme {
  static const background = Color(0xFF080D16);
  static const surface = Color(0xFF131C2C);
  static const raised = Color(0xFF192438);
  static const ink = Color(0xFFF8FBFF);
  static const mutedInk = Color(0xFF8D9DB2);
  static const primary = Color(0xFF4B94FF);
  static const primarySoft = Color(0xFF203E68);
  static const border = Color(0xFF2A3447);
  static const success = Color(0xFF71DEB6);
  static const warning = Color(0xFFE5BC6E);
  static const danger = Color(0xFFFF9A94);

  static const double cardRadius = 16;
  static const double buttonRadius = 11;

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
      surface: surface,
    ).copyWith(
      primary: primary,
      onPrimary: background,
      secondary: const Color(0xFF63D5FF),
      onSecondary: background,
      surface: surface,
      onSurface: ink,
      outline: border,
      error: danger,
      onError: background,
    );
    const titleFont = 'Roboto';

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: scheme,
      canvasColor: background,
      dividerColor: border,
      splashFactory: InkRipple.splashFactory,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: ink,
          fontFamily: titleFont,
          fontSize: 28,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.8,
        ),
        headlineSmall: TextStyle(
          color: ink,
          fontFamily: titleFont,
          fontSize: 23,
          fontWeight: FontWeight.w800,
        ),
        titleLarge: TextStyle(
          color: ink,
          fontFamily: titleFont,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
        titleMedium: TextStyle(
          color: ink,
          fontFamily: titleFont,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        titleSmall: TextStyle(
          color: ink,
          fontFamily: titleFont,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: TextStyle(color: ink, fontSize: 15, height: 1.4),
        bodyMedium: TextStyle(color: mutedInk, fontSize: 13, height: 1.45),
        bodySmall: TextStyle(color: mutedInk, fontSize: 11, height: 1.4),
        labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: ink),
      ),
      iconTheme: const IconThemeData(color: mutedInk),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: raised,
        labelStyle: const TextStyle(color: mutedInk, fontSize: 13),
        hintStyle: const TextStyle(color: mutedInk, fontSize: 12),
        floatingLabelStyle: const TextStyle(color: primary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
          borderSide: const BorderSide(color: danger),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: background,
          backgroundColor: primary,
          disabledBackgroundColor: raised,
          disabledForegroundColor: mutedInk,
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          backgroundColor: raised,
          side: const BorderSide(color: border),
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(19),
          side: const BorderSide(color: border),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
        contentTextStyle: const TextStyle(color: mutedInk, fontSize: 13),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: raised,
        contentTextStyle: const TextStyle(color: ink),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised,
        selectedColor: primarySoft,
        side: const BorderSide(color: border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99),
        ),
        labelStyle: const TextStyle(
          color: ink,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: raised,
      ),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
      ),
    );
  }

  // Kept as a compatibility alias for legacy code that referenced light.
  static ThemeData get light => dark;
}
