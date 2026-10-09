import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dimens.dart';

/// 应用主题：Material 3，跟随系统深浅色。
class AppTheme {
  AppTheme._();

  /// 种子色：棕色，与 App 图标的棕色羽毛笔同源。
  ///
  /// 原始设计稿 §7 给的是蓝灰 #4A6FA5。改成棕色是产品决定：
  /// 图标已经确定用棕色羽毛笔，界面主色若还是蓝色会出现明显的割裂感。
  /// 记在这里以免以后有人以为是手误。
  static const seed = Color(0xFF7C522C);

  /// 图标里的米白，用于浅色模式下的卡片/分区底色，让界面与图标同调
  static const iconCanvas = Color(0xFFFAF6F0);

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.cardRadius,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        margin: EdgeInsets.zero,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        side: BorderSide.none,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
        space: 1,
      ),
    );
  }
}

/// 阅读器主题：与 App 主题解耦，因为阅读页需要独立的字体与背景控制。
enum ReaderThemeMode { light, sepia, dark }

class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 17.0,
    this.lineHeight = 1.75,
    this.mode = ReaderThemeMode.light,
  });

  final double fontSize;
  final double lineHeight;
  final ReaderThemeMode mode;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    ReaderThemeMode? mode,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      mode: mode ?? this.mode,
    );
  }

  Color get background => switch (mode) {
        ReaderThemeMode.light => const Color(0xFFFFFFFF),
        ReaderThemeMode.sepia => const Color(0xFFF6EFE3),
        ReaderThemeMode.dark => const Color(0xFF121212),
      };

  Color get foreground => switch (mode) {
        ReaderThemeMode.light => const Color(0xFF1A1A1A),
        ReaderThemeMode.sepia => const Color(0xFF43382B),
        ReaderThemeMode.dark => const Color(0xFFD8D8D8),
      };

  Color get secondary => foreground.withValues(alpha: 0.55);
}
