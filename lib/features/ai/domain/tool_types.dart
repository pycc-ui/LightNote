import 'dart:convert';

import '../../../core/db/models.dart';

/// **工具定义**（发给模型的 `tools` 数组元素）。
///
/// 形状遵循 OpenAI / DeepSeek 的 function calling 协议：
///
/// ```json
/// { "type": "function",
///   "function": { "name": "...", "description": "...", "parameters": {JSON Schema} } }
/// ```
///
/// ## `description` 是给模型看的，不是给人看的
///
/// 模型**完全靠它**判断该不该调、什么时候调。所以写的是"**什么时候用它**"，
/// 而不是"它是干什么的"。反例：`"删除笔记"`（模型不知道何时该用）；
/// 正例：`"删除一条笔记。不可恢复。只在用户明确要求删除时调用。"`
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    this.parameters = const {'type': 'object', 'properties': <String, dynamic>{}},
  });

  final String name;
  final String description;

  /// 参数的 **JSON Schema**（object 类型）。
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };

  @override
  String toString() => 'ToolSpec($name)';
}

/// 一条**对话消息**（请求里 `messages` 数组的元素）。
///
/// 比 `streamChat` 的"system + user"两段式通用：tool calling 要求把
/// 历史、assistant 的工具提议、以及工具执行结果**按顺序**放进来。
class AgentMessage {
  const AgentMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const [],
    this.toolCallId,
  });

  /// `system` / `user` / `assistant` / `tool`
  final String role;

  final String content;

  /// 仅 `assistant` 会有：它这一轮提出的工具调用。
  final List<ToolCall> toolCalls;

  /// 仅 `tool` 会有：这条结果对应哪个调用。
  final String? toolCallId;

  factory AgentMessage.system(String text) =>
      AgentMessage(role: 'system', content: text);

  factory AgentMessage.user(String text) =>
      AgentMessage(role: 'user', content: text);

  factory AgentMessage.assistant(String text, {List<ToolCall> toolCalls = const []}) =>
      AgentMessage(role: 'assistant', content: text, toolCalls: toolCalls);

  /// 工具执行结果。必须带 [toolCallId]，否则协议拒绝整条请求。
  factory AgentMessage.tool({
    required String toolCallId,
    required String content,
  }) =>
      AgentMessage(role: 'tool', content: content, toolCallId: toolCallId);

  Map<String, dynamic> toJson() => {
        'role': role,
        // 只提工具、没说话时 `content` 允许为空串；协议接受。
        'content': content,
        if (toolCalls.isNotEmpty)
          'tool_calls': [for (final c in toolCalls) c.toJson()],
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };

  @override
  String toString() =>
      'AgentMessage($role, ${content.length} 字, ${toolCalls.length} 个调用)';
}

/// 工具执行结果 → 回灌给模型的 JSON 字符串。
///
/// **统一走这一个入口**，好处有两个：
///   · 模型见到的永远是同一个形状，不会因为某个工具特殊而误判；
///   · 失败也是"结果"（`ok: false` + `error`），模型据此换方案，
///     而不是让整轮请求崩掉。
class ToolResult {
  const ToolResult({
    required this.ok,
    this.data,
    this.error,
    this.description,
    this.finished = false,
    this.mutated = false,
  });

  final bool ok;

  /// 成功时的载荷（会被 JSON 序列化）。
  final Object? data;

  /// 失败时的可读原因，**写给模型看的**：它要靠这句话决定下一步。
  final String? error;

  /// 这次操作的**一句话摘要**（UDF 生成，如「删除笔记 n1「会议记录」」）。
  /// 历史压缩会把 `data` 压掉，`description` 原样保留，
  /// 是模型下一轮识别"做过什么"的锚点。
  final String? description;

  /// **这是不是一次「声明完成」**（`finish()` 这个信号函数）。
  ///
  /// 只有它会为真。`AgentLoop` 看到就**当场收尾**：不回灌结果、不再发一轮 ——
  /// 所以它不参与"工具结果"那套流程，是个控制信号。
  final bool finished;

  /// **这次调用改了笔记数据**（SqlGuard 名单里的写函数）。
  ///
  /// 用来攒「本轮执行记录」：`_drive` 把有改动的 `description` 收集起来，
  /// 追加在那条助手消息末尾 —— 用户能翻回去看 AI 到底改了哪些笔记，
  /// 而「继续」时模型也知道**哪些已经做完了，不要重复做**。
  /// 读函数不算（它们不改数据，攒起来只是噪音）。
  final bool mutated;

  factory ToolResult.success(Object? data) => ToolResult(ok: true, data: data);

  factory ToolResult.failure(String error) =>
      ToolResult(ok: false, error: error);

  /// UDF 的返回值**本身就是最终形状**（`{ok, description, data}` / `{ok:false, error}`）。
  /// 这里把它摊回字段，好让上层读到 `ok` / `error`，`encode()` 再原样发回去 ——
  /// 避免"把一段 JSON 再包进 rows 里"那种双层嵌套。
  factory ToolResult.raw(String json, {bool mutated = false}) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return ToolResult(ok: true, data: json);
    final ok = decoded['ok'] == true;
    return ToolResult(
      ok: ok,
      data: ok ? decoded['data'] : null,
      error: ok ? null : (decoded['error'] as String? ?? '未知错误'),
      description: decoded['description'] as String?,
      // `finish()` 的约定：data 里带 finished: true（见 ai_udfs.dart 的 _finish）。
      // 认这一格而不是认函数名：函数名在 SQL 文本里，可能是字符串的一部分。
      finished: ok && decoded['data'] is Map &&
          (decoded['data'] as Map)['finished'] == true,
      // 改没改数据由**调用方**（执行器）判定：它看的是 SQL 里的函数名，
      // 而 UDF 的返回值里没有这个信息（读函数也返回同样的形状）。
      mutated: mutated,
    );
  }

  String encode() => jsonEncode({
        'ok': ok,
        if (description != null) 'description': description,
        if (ok) 'data': data,
        if (!ok) 'error': error ?? '未知错误',
      });
}
