import 'package:flutter/material.dart';

/// Colores base de la app. El color principal (acento) se elige en Ajustes;
/// el resto se cambia aquí.
class AppColors {
  static const background = Color(0xFF07080A); // fondo general, casi negro
  static const surface = Color(0xFF111318); // barras, tarjetas
  static const surfaceHigh = Color(0xFF1B1E25); // campos de texto, menús
  static const border = Color(0xFF242832);
  static const text = Color(0xFFECEDEF);
  static const textMuted = Color(0xFF8B91A0);
  static const danger = Color(0xFFFF4D4F);

  // Estado de cada cámara.
  static const live = Color(0xFF2EE59D);
  static const connecting = Color(0xFFFFB020);
  static const offline = Color(0xFFFF4D4F);

  // Color de cada marca.
  static const hikvision = Color(0xFFE5484D);
  static const dahua = Color(0xFFF2994A);
}

/// Colores principales que se pueden elegir en Ajustes.
const accentOptions = <Color>[
  Color(0xFF2EE59D), // verde
  Color(0xFF4C9AFF), // azul
  Color(0xFF22D3EE), // celeste
  Color(0xFF9B8CFF), // violeta
  Color(0xFFFFB020), // ámbar
  Color(0xFFFF5C7A), // rosado
];

ThemeData buildTheme(Color accent) {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: accent,
    onPrimary: Colors.black,
    secondaryContainer: accent.withValues(alpha: 0.18),
    onSecondaryContainer: accent,
    surface: AppColors.background,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.textMuted,
    surfaceContainerLowest: AppColors.background,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: AppColors.border,
    outlineVariant: AppColors.border,
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

/// Texto pequeño en mayúsculas para títulos de sección.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
