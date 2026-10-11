import 'package:flutter/material.dart';

/// 尺寸规范常量。视觉规范见 docs/界面设计.md。
/// 集中定义，避免每个页面各写一套魔法数字。
class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
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

// ============================================================================
// 卡片流（「轻笔记」页）专用尺寸
//
// 与常规列表刻意不同：卡片要占屏幕约 2/3，文字更大、留白更多。
// 详见 docs/specs/轻笔记-AI卡片流.md。
// ============================================================================

/// 卡片内边距：上 40 / 左右 20 / 下 20。
///
/// 比常规卡片的 16 大得多——卡片变高**不等于**字号要跟着变大，
/// 靠内边距创造呼吸感才不会让 80 字占更多行反而更挤。
const EdgeInsets kFeedCardPadding = EdgeInsets.fromLTRB(20, 40, 20, 20);

/// 卡片高度占屏高的比例（约 2/3）
///
/// **这是"看起来舒服"的目标，不是硬性下限。**
/// 卡片实际高度自适应：内容少就按内容高，内容多最多到屏高 2/3。
/// 固定成 2/3 会让短笔记留一大片空白，那是"填不满"的观感问题。
const double kFeedCardHeightRatio = 2 / 3;

/// 卡片高度下限。
///
/// 给矮屏（分屏、横屏）兜底：纯按比例算在极矮的窗口里会把内容压到溢出。
/// 也保证"只有一句话"的卡片看起来仍像一张卡片，而不是一条列表项。
const double kFeedCardMinHeight = 445;

/// 卡片之间的间距
const double kFeedCardGap = 12;

/// 卡片预览字号（比常规列表的 14 大）
const double kFeedPreviewFontSize = 15.5;

/// 卡片标题字号
const double kFeedTitleFontSize = 17;

/// 卡片标题最多显示几行。
///
/// 卡片上**只有标题**（摘要已去掉，点进去看正文），所以给它 3 行。
/// 超出用省略号，但不能靠提示词让模型守字数——它不守。
const int kFeedTitleMaxLines = 3;

/// 卡片元信息字号
const double kFeedMetaFontSize = 12.5;

/// 卡片预览最多显示几行
const int kFeedPreviewMaxLines = 5;
