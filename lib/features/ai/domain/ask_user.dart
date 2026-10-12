import 'dart:convert';

import '../../../core/db/models.dart';
import 'tool_types.dart';

/// `askUser` 的**请求侧**：模型要问用户什么。
///
/// ## 它只做「信息收集」，**不承担安全职责**
///
/// 这一点是整个设计里最容易做错的地方：`askUser` 是模型**自愿**调用的，
/// 它忘了调就什么都不会发生。所以：
///
///   · **破坏性操作的确认由 App 在工具执行器里强制拦截**（按工具的风险级别），
///     模型绕不过；
///   · `askUser` 只负责"选哪一篇""叫什么名字""要不要继续"这类**信息不足**的场景。
///
/// 把安全寄托在"模型记得问一句"上，等于没有安全。
///
/// ## `type` / `options` / `source`
///
/// [AskSource] 的存在是为了**别让模型把清单塞进 prompt**：库里 200 条笔记时它
/// 既塞不下也记不住，而且那份清单会随着对话变旧（可能给出已删除的笔记 id）。
/// 模型只给筛选条件，**选项由 App 现查现填**。
class AskRequest {
  const AskRequest({
    required this.question,
    required this.type,
    this.options = const [],
    this.source,
    this.defaultValue,
    this.limit = 10,
  });

  final String question;
  final AskType type;

  /// 模型直接给的选项（≤10 条）。**仅当 [source] 为空时**才用。
  final List<AskOption> options;

  /// 由 App 现查现填的选项来源。给了它就忽略 [options]。
  final AskSource? source;

  final String? defaultValue;

  /// [source] 模式下最多给几条选项。
  final int limit;

  /// 永远允许取消。
  ///
  /// 协议里本来有个 `allowCancel`，但**我们不接受 `false`**：
  /// 一是"拒绝"本身就是一种合法回答（取消 = 拒绝），不该被禁掉；
  /// 二是禁掉之后用户直接关掉 App 就会让对话永久挂起。
  bool get allowCancel => true;

  @override
  String toString() => 'AskRequest(${type.name}, "$question")';
}

/// **挂起中的一次提问** —— 存进 `ai_messages.pendingAction`。
///
/// 为什么连 `messages` 一起存：恢复时要重建的是**提问那一刻的整段对话**
/// （含此前几轮的工具往来），因为工具的结果并不落库（见
/// `AiChatRepository.send` 的说明）。只存 `question` 的话，用户回答完只能
/// 从头再来一遍。
///
/// 存的是 JSON 字符串，所以**跨重启有效** —— 这正是"不用超时"的前提：
/// 用户三小时后才回答也行，甚至重启 App 之后也行。
class PendingAsk {
  const PendingAsk({
    required this.toolCallId,
    required this.request,
    this.messages = const [],
    this.asks = 1,
  });

  /// 要回灌结果的那次调用（`role: tool` 必须带它）
  final String toolCallId;

  final AskRequest request;

  /// 提问那一刻的对话
  final List<AgentMessage> messages;

  /// 这一轮问到第几次了。
  ///
  /// [AgentLoop.maxAsksPerTurn] 的上限必须**跨恢复累计**：挂起 → 用户回答 →
  /// 循环重新跑。只在新循环里从 0 数的话上限永远到不了，用户会被反复问。
  final int asks;

  Map<String, Object?> toJson() => {
        'kind': 'askUser',
        'toolCallId': toolCallId,
        'asks': asks,
        'request': {
          'question': request.question,
          'type': request.type.name,
          'limit': request.limit,
          if (request.defaultValue != null) 'default': request.defaultValue,
          if (request.source != null)
            'source': {
              'kind': request.source!.kind,
              'query': request.source!.query,
              if (request.source!.notebookId != null)
                'notebookId': request.source!.notebookId,
            },
          if (request.options.isNotEmpty)
            'options': [
              for (final o in request.options)
                {
                  'id': o.id,
                  'label': o.label,
                  if (o.description != null) 'description': o.description,
                },
            ],
        },
        'messages': [for (final m in messages) m.toJson()],
      };

  String encode() => jsonEncode(toJson());

  /// 解析。**坏数据一律返回 null**（当成"没有挂起"），
  /// 而不是抛错：一条损坏的记录不该让整个会话打不开。
  static PendingAsk? tryParse(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return null;
      if (v['kind'] != 'askUser') return null;
      final toolCallId = v['toolCallId'];
      if (toolCallId is! String || toolCallId.isEmpty) return null;

      final r = v['request'];
      if (r is! Map) return null;
      final question = r['question'];
      final type = AskType.parse(r['type']);
      if (question is! String || type == null) return null;

      final options = <AskOption>[];
      final rawOpts = r['options'];
      if (rawOpts is List) {
        for (final o in rawOpts) {
          final parsed = AskOption.tryParse(o);
          if (parsed != null) options.add(parsed);
        }
      }

      final messages = <AgentMessage>[];
      final rawMsgs = v['messages'];
      if (rawMsgs is List) {
        for (final m in rawMsgs) {
          if (m is! Map) continue;
          final role = m['role'];
          if (role is! String) continue;
          // ⚠️ `tool_calls` 必须一起还原：协议要求 `role: tool` 的结果
          // 必须被前面 assistant 的 `tool_calls` 引用，否则整条请求会被拒。
          // 丢掉的话用户一回答就报错（而且是接口层面的错，很难查）。
          final calls = <ToolCall>[];
          final rawCalls = m['tool_calls'];
          if (rawCalls is List) {
            for (final c in rawCalls) {
              if (c is! Map) continue;
              final id = c['id'];
              final fn = c['function'];
              if (id is! String || fn is! Map) continue;
              calls.add(ToolCall(
                id: id,
                name: '${fn['name'] ?? ''}',
                arguments: '${fn['arguments'] ?? '{}'}',
              ));
            }
          }
          messages.add(AgentMessage(
            role: role,
            content: m['content'] is String ? m['content'] as String : '',
            toolCalls: calls,
            toolCallId: m['tool_call_id'] is String
                ? m['tool_call_id'] as String
                : null,
          ));
        }
      }

      final limitRaw = r['limit'];
      return PendingAsk(
        toolCallId: toolCallId,
        request: AskRequest(
          question: question,
          type: type,
          options: options,
          source: AskSource.tryParse(r['source']),
          defaultValue: r['default'] is String ? r['default'] as String : null,
          limit: limitRaw is int ? limitRaw.clamp(1, 10) : 10,
        ),
        messages: messages,
        asks: (v['asks'] is int ? v['asks'] as int : 1).clamp(1, 99),
      );
    } catch (_) {
      return null;
    }
  }
}

enum AskType {
  text,
  singleChoice,
  multipleChoice,
  confirm;

  static AskType? parse(Object? raw) {
    if (raw is! String) return null;
    for (final t in AskType.values) {
      if (t.name == raw) return t;
    }
    return null;
  }

  /// 这个类型是不是必须要有选项。
  bool get needsOptions => this == singleChoice || this == multipleChoice;
}

/// 一个选项。
class AskOption {
  const AskOption({required this.id, required this.label, this.description});

  /// 唯一标识。用户选中后回给模型的就是它（不是 label —— label 可能重复）。
  final String id;
  final String label;
  final String? description;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        if (description != null && description!.isNotEmpty)
          'description': description,
      };

  static AskOption? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final label = raw['label'];
    if (id is! String || id.isEmpty || label is! String) return null;
    return AskOption(
      id: id,
      label: label,
      description: raw['description'] is String
          ? raw['description'] as String
          : null,
    );
  }

  @override
  String toString() => 'AskOption($id, $label)';
}

/// 选项来源：**模型给筛选条件，App 给清单**。
class AskSource {
  const AskSource({required this.kind, this.query = '', this.notebookId});

  /// `search` / `notebooks` / `recentNotes`
  final String kind;

  /// [kind] == `search` 时的关键词。
  final String query;

  /// 限定在某个笔记库里找。
  final String? notebookId;

  static AskSource? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    if (kind is! String || kind.isEmpty) return null;
    return AskSource(
      kind: kind,
      query: raw['query'] is String ? raw['query'] as String : '',
      notebookId: raw['notebookId'] is String ? raw['notebookId'] as String : null,
    );
  }

  @override
  String toString() => 'AskSource($kind, "$query")';
}

/// `askUser` 的**结果侧**：用户怎么答的。
///
/// ## 只有一种形状
///
/// 回灌给模型的 JSON 永远是这四个 key，用不到的给 `null`：
///
/// ```json
/// { "status": "answered" | "cancelled",
///   "selections": ["optionId"],
///   "text": "…",
///   "confirmed": true }
/// ```
///
/// 为什么不做成"每种类型一个形状"：工具结果是一段 JSON 字符串，
/// **形状多变最容易让模型解析出错**。固定形状 + 空值是更稳的选择。
class AskResult {
  const AskResult({
    required this.status,
    this.selections = const [],
    this.text,
    this.confirmed,
  });

  /// `answered` / `cancelled`
  final String status;

  /// 选择题的答案（单选也放这里，只有一个元素）。
  final List<String> selections;

  /// 输入题的答案。
  final String? text;

  /// 确认题的答案。
  final bool? confirmed;

  static const statusAnswered = 'answered';
  static const statusCancelled = 'cancelled';

  /// 用户答了（选择题）。
  factory AskResult.choice(List<String> ids) =>
      AskResult(status: statusAnswered, selections: List.unmodifiable(ids));

  /// 用户答了（输入题）。
  ///
  /// **空串也算答了**：模型据此判断要不要重问，而不是让 App 替它决定。
  factory AskResult.input(String value) =>
      AskResult(status: statusAnswered, text: value);

  /// 用户答了（确认题）。
  factory AskResult.confirm(bool yes) =>
      AskResult(status: statusAnswered, confirmed: yes);

  /// 用户取消 —— **等于拒绝**。
  ///
  /// 给 [confirmed] 补一个 `false`：取消一个确认框在语义上就是"不同意"，
  /// 让模型少做一次推断。
  factory AskResult.cancelled({bool fromConfirm = false}) => AskResult(
        status: statusCancelled,
        confirmed: fromConfirm ? false : null,
      );

  bool get isAnswered => status == statusAnswered;
  bool get isCancelled => status == statusCancelled;

  /// 回灌给模型的 JSON 字符串（形状固定，用不到的给 null）。
  String encode() => jsonEncode({
        'status': status,
        'selections': selections.isEmpty ? null : selections,
        'text': text,
        'confirmed': confirmed,
      });

  @override
  String toString() =>
      'AskResult($status, sel=$selections, text=$text, ok=$confirmed)';
}
