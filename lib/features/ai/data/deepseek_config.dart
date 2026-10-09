/// DeepSeek 模型与计费常量。
///
/// 价格来源：https://api-docs.deepseek.com/zh-cn/quick_start/pricing
/// 单位：元 / 百万 tokens。价格是官方 2026 年公布的档位，
/// **变动频繁**，如需精确对账请在设置页允许用户覆盖。
class DeepSeekConfig {
  DeepSeekConfig._();

  static const baseUrl = 'https://api.deepseek.com';
  static const chatPath = '/chat/completions';

  /// 官方文档明确：模型名请使用 `deepseek-flash`。
  /// 旧名 `deepseek-v4-flash` 仍可调用但对应模型已下线，请求会由新模型代答。
  static const modelFlash = 'deepseek-flash';

  /// 高价值任务（深度整理、卡片生成）才用 pro，价格约为 flash 的 3–4 倍。
  static const modelPro = 'deepseek-v4-pro';

  static const models = <String>[modelFlash, modelPro];

  /// 上下文 1M / 最大输出 384K。实际调用请留出余量，
  /// 单次请求正文建议不超过 20 万字符，超长笔记应先分段。
  static const maxContextTokens = 1000000;
  static const maxOutputTokens = 384000;

  static const connectTimeout = Duration(seconds: 20);

  /// 生成类请求（尤其是 pro + 思考模式）可能跑很久，读超时给足。
  static const readTimeout = Duration(minutes: 5);
}

/// 单次调用的用量统计
class TokenUsage {
  const TokenUsage({
    this.promptTokens = 0,
    this.cachedPromptTokens = 0,
    this.completionTokens = 0,
  });

  final int promptTokens;

  /// 命中上下文硬盘缓存的输入 token
  final int cachedPromptTokens;
  final int completionTokens;

  bool get isEmpty => promptTokens == 0 && completionTokens == 0;

  static const zero = TokenUsage();

  @override
  String toString() =>
      'TokenUsage(in: $promptTokens, cached: $cachedPromptTokens, out: $completionTokens)';
}

/// 计费：区分高峰/空闲时段，并计入缓存命中折扣。
class DeepSeekPricing {
  DeepSeekPricing._();

  /// 每百万 tokens 单价（元）: (缓存命中输入, 未命中输入, 输出)
  static const _flashPeak = (0.04, 2.0, 8.0);
  static const _flashOffPeak = (0.02, 1.0, 4.0);
  static const _proPeak = (0.30, 9.0, 27.0);
  static const _proOffPeak = (0.15, 4.5, 13.5);

  /// 高峰时段：北京时间周一至周五（不含法定节假日）9:00–12:00、14:00–18:00。
  /// 其余（含周末与节假日全天）为空闲时段，价格是高峰的一半。
  ///
  /// 注意：这里只按星期与小时判断，**不含中国法定节假日日历**。
  /// 用于成本估算足够；精确对账请以官方账单为准。
  static bool isPeakHour(DateTime local) {
    if (local.weekday == DateTime.saturday ||
        local.weekday == DateTime.sunday) {
      return false;
    }
    final h = local.hour + local.minute / 60.0;
    final morning = h >= 9.0 && h < 12.0;
    final afternoon = h >= 14.0 && h < 18.0;
    return morning || afternoon;
  }

  /// 返回估算成本，单位：分（人民币）
  static double estimateCostCents({
    required String model,
    required TokenUsage usage,
    DateTime? now,
  }) {
    final isPro = model.contains('pro');
    final peak = isPeakHour(now ?? DateTime.now());
    final (cachedPrice, inputPrice, outputPrice) = isPro
        ? (peak ? _proPeak : _proOffPeak)
        : (peak ? _flashPeak : _flashOffPeak);

    final cached = usage.cachedPromptTokens.clamp(0, usage.promptTokens);
    final uncached = usage.promptTokens - cached;

    // 价格单位是「元/百万 tokens」，结果换算成分需 *100 / 1e6
    final yuan = (cached * cachedPrice +
            uncached * inputPrice +
            usage.completionTokens * outputPrice) /
        1000000.0;
    return yuan * 100.0;
  }

  static String formatCents(double cents) {
    if (cents < 0.01) return '＜0.01 分';
    if (cents < 100) return '${cents.toStringAsFixed(2)} 分';
    return '${(cents / 100).toStringAsFixed(2)} 元';
  }
}
