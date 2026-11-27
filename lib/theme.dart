import 'package:flutter/material.dart';

/// Colores de la app. Cambia estos valores para dejarla a tu gusto:
/// todo el resto de la app los toma de aquí.
class AppColors {
  static const background = Color(0xFF0E0F12); // fondo general
  static const surface = Color(0xFF181A20); // tarjetas y listas
  static const surfaceHigh = Color(0xFF22252D); // campos de texto, diálogos
  static const accent = Color(0xFF3DDC97); // color principal (botones, íconos activos)
  static const text = Color(0xFFECEDEF);
  static const textMuted = Color(0xFF9096A3);
  static const danger = Color(0xFFFF5C5C);

  // Color de cada marca (insignias en listas y cuadrícula).
  static const hikvision = Color(0xFFE5484D);
  static const dahua = Color(0xFFF2994A);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    onPrimary: Colors.black,
    surface: AppColors.background,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.textMuted,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
  );
}

/// Estilo común para los campos de texto de los formularios.
InputDecoration fieldDecoration(
  String label, {
  String? hint,
  String? helper,
  Widget? suffix,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    suffixIcon: suffix,
    filled: true,
    fillColor: AppColors.surfaceHigh,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  );
}
