// lib/utils/theme.dart
import 'package:flutter/material.dart';

// ── 颜色系统 ─────────────────────────────────────────────────────────────────
class AppColors {
  // 背景层级
  static const bg0 = Color(0xFF0D1117);   // 最深，页面底色
  static const bg1 = Color(0xFF161B22);   // 卡片底色
  static const bg2 = Color(0xFF21262D);   // 输入框、次级卡片
  static const bg3 = Color(0xFF30363D);   // 边框、分割线

  // 强调色：琥珀
  static const amber    = Color(0xFFE6A817);
  static const amberDim = Color(0xFF7D5C0A);

  // 语义色
  static const green  = Color(0xFF3FB950);
  static const red    = Color(0xFFF85149);
  static const blue   = Color(0xFF58A6FF);
  static const purple = Color(0xFFBC8CFF);

  // 文字
  static const textPrimary   = Color(0xFFE6EDF3);
  static const textSecondary = Color(0xFF8B949E);
  static const textMuted     = Color(0xFF484F58);

  // 难度色阶
  static Color difficulty(int d) => switch (d) {
    1 => const Color(0xFF3FB950),
    2 => const Color(0xFF58A6FF),
    3 => const Color(0xFFE6A817),
    4 => const Color(0xFFFF8C00),
    _ => const Color(0xFFF85149),
  };

  // 复习状态色
  static Color reviewStatus(String s) => switch (s) {
    'mastered'  => green,
    'reviewing' => amber,
    _           => textMuted,
  };
}

// ── 主题 ─────────────────────────────────────────────────────────────────────
ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg0,
    colorScheme: const ColorScheme.dark(
      surface:   AppColors.bg1,
      primary:   AppColors.amber,
      secondary: AppColors.blue,
      error:     AppColors.red,
      onSurface: AppColors.textPrimary,
      onPrimary: AppColors.bg0,
    ),
    cardTheme: const CardThemeData(
      color:       AppColors.bg1,
      elevation:   0,
      margin:      EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: AppColors.bg3, width: 1),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg0,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'monospace',
        color: AppColors.textPrimary,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
      iconTheme: IconThemeData(color: AppColors.textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.bg2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.bg3),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.bg3),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.amber, width: 1.5),
      ),
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      hintStyle: const TextStyle(color: AppColors.textMuted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.amber,
        foregroundColor: AppColors.bg0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.amber),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.bg3, space: 1),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.bg2,
      labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      side: const BorderSide(color: AppColors.bg3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.bg2,
      contentTextStyle: const TextStyle(color: AppColors.textPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

// ── 文字样式快捷 ─────────────────────────────────────────────────────────────
class AppText {
  static const heading = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );
  static const label = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.6,
  );
  static const mono = TextStyle(
    fontFamily: 'monospace',
    color: AppColors.textSecondary,
    fontSize: 12,
  );
}

// ── 常量 ─────────────────────────────────────────────────────────────────────
class AppConst {
  static const baseUrl = 'http://192.168.41.177:9000'; // ← FastAPI 中间层端口

  static const reviewLabels = {
    'pending':   '待复习',
    'reviewing': '复习中',
    'mastered':  '已掌握',
  };

  static const subjectList = [
    '数学', '语文', '英语', '物理', '化学', '生物', '历史', '地理', '政治',
  ];

  static const gradeList = [
    '初一', '初二', '初三', '高一', '高二', '高三',
  ];

  static const difficultyLabels = ['', '⭑ 简单', '⭑⭑ 较易', '⭑⭑⭑ 中等', '⭑⭑⭑⭑ 较难', '⭑⭑⭑⭑⭑ 难'];
}
