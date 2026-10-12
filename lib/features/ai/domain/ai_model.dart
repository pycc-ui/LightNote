import '../data/deepseek_config.dart';

/// AI 助手页可选的模型。
///
/// 这里取代了原来的「工作区」：工作区被取消后，AI 助手页底部那个"选范围"的
/// 位置改成了"选模型"。范围的事不再限制 —— AI 能看见用户的**全部**笔记
/// （命令语言下就是整个笔记库根目录）。
///
/// 只两档：
///   · [flash]（默认）—— 日常问答，便宜快；
///   · [pro] —— 复杂整理/推理，贵但强。
///
/// ⚠️ 卡片流与摘要**固定用 flash**，不读这里的选择（见 `generateFeedNotes` /
/// `summarizeNote` 的默认参数），避免误选 pro 把高频成本抬三倍。
class AiModel {
  AiModel._();

  static const flash = DeepSeekConfig.modelFlash;
  static const pro = DeepSeekConfig.modelPro;

  /// 供选择器枚举。顺序即展示顺序（flash 在前 = 默认）。
  static const all = <String>[flash, pro];

  /// 解析会话记录里存的选择。
  ///
  /// 兼容老数据：改造前这一列存的是工作区 JSON（`{"mode":…}`）或空串，
  /// 解析不出 pro 就一律回 [flash]（默认档），不会因为老值而选到不存在的模型。
  static String parse(String? raw) {
    if (raw != null && raw.trim() == pro) return pro;
    return flash;
  }

  static String label(String model) =>
      model == pro ? 'DeepSeek Pro' : 'DeepSeek Flash';
}
