import 'dart:convert';

import 'app_database.dart';

export 'app_database.dart'
    show Note, Card, Tag, NoteSummary, Review, AiCall, CardDeck;

/// 解析存库的 JSON 数组字符串（如 NoteSummary.bullets）。
///
/// 集中在这里，避免每个页面各写一份 `jsonDecode` 并各自处理异常。
List<String> parseJsonStringList(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
  } catch (_) {
    // 落库时若被截断可能不是合法 JSON，降级为按分隔符切分
  }
  // 降级路径要顺手剥掉残留的 JSON 语法字符（方括号与引号），
  // 否则会得到 '["正常项"' 这种带引号的结果。
  return raw
      .replaceAll(RegExp(r'[\[\]"]'), '')
      .split(RegExp(r'[,，\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

/// AI 生成的一张卡片草稿。
///
/// 它 **不是** 数据库里的 [Card]：[Card] 带 SM-2 调度状态，
/// 而草稿只承载模型给出的内容，必须经用户确认后才落库。
class CardDraft {
  const CardDraft({
    required this.question,
    required this.answer,
    this.tags = const [],
    this.selected = true,
  });

  final String question;
  final String answer;
  final List<String> tags;

  /// UI 上的勾选框状态；默认全选，用户可取消勾选。
  final bool selected;

  CardDraft copyWith({
    String? question,
    String? answer,
    List<String>? tags,
    bool? selected,
  }) {
    return CardDraft(
      question: question ?? this.question,
      answer: answer ?? this.answer,
      tags: tags ?? this.tags,
      selected: selected ?? this.selected,
    );
  }

  Map<String, dynamic> toJson() => {
        'question': question,
        'answer': answer,
        'tags': tags,
      };

  static CardDraft fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    return CardDraft(
      question: (json['question'] ?? '').toString().trim(),
      answer: (json['answer'] ?? '').toString().trim(),
      tags: rawTags is List
          ? rawTags.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
          : const [],
    );
  }

  /// 内容不完整的草稿直接丢弃，不要让它污染复习队列。
  bool get isValid => question.isNotEmpty && answer.isNotEmpty;

  @override
  String toString() => 'CardDraft(selected: $selected, q: $question)';
}

/// AI 整理笔记的结构化结果。
class NoteAiResult {
  const NoteAiResult({
    required this.oneLine,
    this.bullets = const [],
    this.tags = const [],
    this.actionItems = const [],
    this.rawResponse,
  });

  final String oneLine;
  final List<String> bullets;
  final List<String> tags;
  final List<String> actionItems;
  final String? rawResponse;

  static NoteAiResult empty() =>
      const NoteAiResult(oneLine: '', rawResponse: null);

  bool get isEmpty =>
      oneLine.isEmpty && bullets.isEmpty && tags.isEmpty && actionItems.isEmpty;

  static NoteAiResult fromJson(Map<String, dynamic> json, {String? raw}) {
    List<String> strList(Object? v) {
      if (v is List) {
        return v
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      if (v is String && v.trim().isNotEmpty) {
        return v
            .split(RegExp(r'[,，\n]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    }

    return NoteAiResult(
      oneLine: (json['one_line'] ?? json['summary'] ?? '').toString().trim(),
      bullets: strList(json['bullets'] ?? json['key_points']),
      tags: strList(json['tags']),
      actionItems: strList(json['action_items']),
      rawResponse: raw,
    );
  }

  Map<String, dynamic> toJson() => {
        'one_line': oneLine,
        'bullets': bullets,
        'tags': tags,
        'action_items': actionItems,
      };
}

/// AI 流式事件：UI 拿到的是一个事件流，而不是一次性字符串。
sealed class AiEvent {
  const AiEvent();
}

/// 正文增量（用于打字机效果）
class AiChunk extends AiEvent {
  const AiChunk(this.text);
  final String text;
}

/// 思维链增量（思考模式下才出现，UI 上可折叠展示）
class AiReasoning extends AiEvent {
  const AiReasoning(this.text);
  final String text;
}

/// 一次调用结束，携带用量与成本
class AiDone extends AiEvent {
  const AiDone({
    this.fullText = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costCents = 0,
    this.latencyMs = 0,
  });

  final String fullText;
  final int promptTokens;
  final int completionTokens;
  final double costCents;
  final int latencyMs;
}

class AiError extends AiEvent {
  const AiError(this.message, {this.code, this.isRetryable = false});
  final String message;
  final String? code;
  final bool isRetryable;
}
