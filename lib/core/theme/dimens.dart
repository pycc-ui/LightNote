import 'package:flutter/material.dart';

/// 设计规范常量（对应 docs/界面设计.md §7 视觉规范）。
/// 集中定义，避免每个页面各写一套魔法数字。
class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

class AppRadius {
  AppRadius._();
  static const card = 12.0;
  static const sheet = 16.0;
  static const chip = 8.0;

  static BorderRadius get cardRadius => BorderRadius.circular(card);
  static BorderRadius get sheetRadius => BorderRadius.circular(sheet);
}

/// 列表项最小高度（设计稿：列表项高度自适应，最小 72）
const double kMinListItemHeight = 72;
