import 'tool_types.dart';

/// 工具的**风险级别**。App 的工具执行器按它决定"要不要先弹确认"。
///
/// 风险级别做成数据、而不是执行器里的 if：安全确认必须由 App 强制，
/// 不能靠模型自觉。对命令语言来说，具体是**哪条命令**危险由
/// `NoteCommandHost` 在命令粒度上判定（`rm` = delete、`sed c/d/i/a` = modify……），
/// 这里只保留聚合版本给 UI 措辞用。
enum ToolRisk {
  /// 只读：直接执行。
  read,

  /// 创建：新建笔记 / 笔记库。轻确认。
  create,

  /// 修改：改、移。确认 + 可撤销。
  modify,

  /// 删除：**二次确认 + 明确"不可恢复"**。
  delete,

  /// 交互：`askUser`。**不碰数据**，不进风险表。
  interaction,
}

/// 一个可供 AI 调用的工具 = 协议定义 + 风险级别。
class AgentTool {
  const AgentTool({required this.spec, required this.risk});

  final ToolSpec spec;
  final ToolRisk risk;

  String get name => spec.name;
  String get description => spec.description;

  /// 这个工具在真正执行前是否需要用户确认。
  bool get needsConfirm =>
      risk == ToolRisk.create || risk == ToolRisk.modify || risk == ToolRisk.delete;

  /// 是否需要"二次确认"（删除类，措辞要写明不可恢复）。
  bool get needsStrongConfirm => risk == ToolRisk.delete;

  @override
  String toString() => 'AgentTool($name, ${risk.name})';
}

// ============================================================================
// 工具清单：只剩 2 个（run + askUser）
//
// 22 个 function-calling 工具收敛成 1 个「执行脚本」工具 `run`。收益见
// docs/命令语言设计.md 第 1 节：工具定义每轮固定开销从约 3000-5000 token
// 降到约 250，轮数从 O(N²) 降到 O(N)。
//
// `askUser` 是唯一保留的第二个工具：它是"挂起提问"的载体，
// AI 助手页的持久化挂起（重启后仍能接着答）全靠它，见《AI接入设计》「挂起机制」。
// ============================================================================

/// `run` 工具：参数是一段 shell 风格命令脚本。
///
/// 脚本的语言、命令清单、边界都写在 system prompt 里（`AiPrompts.agentSystem`），
/// 所以这里的 `description` 只做提纲挈领的说明，避免两处细节走样。
final kRunTool = AgentTool(
  risk: ToolRisk.read, // 单条命令的风险在 NoteCommandHost 里逐条判定
  spec: const ToolSpec(
    name: 'run',
    description: '在用户的笔记库上执行命令脚本。支持 ls/stat/sed/grep/echo/rm/mkdir/mv。'
        '可写多行，用 for/if 做简单批处理。只读命令批量执行，'
        '写命令（echo/sed 的 c·d·i·a/rm/mkdir/mv）逐条弹确认框。'
        '语法与命令清单见 system prompt。',
    parameters: {
      'type': 'object',
      'properties': {
        'script': {
          'type': 'string',
          'description': '命令脚本，每行一条命令。语法见 system prompt。',
        },
      },
      'required': ['script'],
    },
  ),
);

/// `askUser` 工具：信息不足时问用户（会挂起，用户回答后继续）。
final kAskUserTool = AgentTool(
  risk: ToolRisk.interaction,
  spec: const ToolSpec(
    name: 'askUser',
    description: '**信息不足时问用户**：不确定是哪一篇、要起什么名字、要不要继续。'
        '优先用 source 让 App 现查选项，不要把清单塞进参数里。'
        '不要问已经知道的信息，能推断的就别问。',
    parameters: {
      'type': 'object',
      'properties': {
        'question': {'type': 'string', 'description': '问题，简洁明确'},
        'type': {
          'type': 'string',
          'enum': ['text', 'singleChoice', 'multipleChoice', 'confirm'],
          'description': '提问类型',
        },
        'source': {
          'type': 'object',
          'description': '由 App 现查选项（选择题推荐用这个，而不是自己列 options）',
          'properties': {
            'kind': {
              'type': 'string',
              'enum': ['search', 'notebooks', 'recentNotes'],
            },
            'query': {'type': 'string', 'description': 'kind=search 时的关键词'},
            'notebookId': {'type': 'string'},
          },
          'required': ['kind'],
        },
        'options': {
          'type': 'array',
          'description': '自己给的选项（≤10 条）。仅当不用 source 时',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'label': {'type': 'string'},
              'description': {'type': 'string'},
            },
            'required': ['id', 'label'],
          },
        },
        'limit': {'type': 'integer', 'description': 'source 模式下最多给几条选项，默认 10'},
      },
      'required': ['question', 'type'],
    },
  ),
);

/// 全部工具（2 个）。
final kAgentTools = <AgentTool>[kRunTool, kAskUserTool];

/// 按名字查。找不到返回 null（模型可能报一个不存在的名字）。
AgentTool? toolByName(String name) {
  for (final t in kAgentTools) {
    if (t.name == name) return t;
  }
  return null;
}

/// 某次请求该发的完整定义 —— 现在就是全部（不再分层发送）。
List<ToolSpec> specsForRequest() => [for (final t in kAgentTools) t.spec];
