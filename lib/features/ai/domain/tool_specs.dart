import 'tool_types.dart';

// ============================================================================
// 工具清单：只剩 2 个（sql + askUser）
// ============================================================================
//
// 演进路线：22 个 function calling 工具 → 1 个 `run`（自定义命令脚本）→
// 1 个 `sql`（SQL + UDF）。工具定义的**每轮固定开销**只跟工具数量与描述长度有关，
// 所以工具越少越省；而能力不靠工具数量堆，靠「用 AI 的母语」——
// SQL 的训练数据海量，命令语言那套语法它没见过（这是上一版失败的原因）。
//
// `askUser` 是唯一没被 SQL 取代的：SQL 能改数据，但没法「停下来等人回答」。
// 它不碰数据，走的是对话流程（见 agent_loop.dart 与 ask_user.dart）。

/// `sql` 工具：AI 唯一的操作入口，一次执行一条 SQL。
///
/// `description` 是**给模型看的**（模型完全靠它判断何时该用），所以写的是
/// 「什么时候用它」；细则（有哪些函数、边界在哪）不写在这里，
/// 而是留在 `ai_functions` 表里让模型自己查 —— 那样加函数不用改工具定义。
final kSqlToolSpec = ToolSpec(
  name: 'sql',
  description: '在用户的笔记数据库上执行一条 SQL。可以查询 notes / notebooks / note_chunks，'
      '调用 ai_functions 里登记的扩展函数，用子查询 / CTE / JOIN / 窗口函数。'
      '扩展函数可以直接嵌在 SELECT 里（例如 SELECT id, read_preview(id, 0, 200) FROM notes）。'
      '新建 / 修改 / 删除**必须**调用扩展函数，直接写表会被拒绝。'
      '先执行 SELECT * FROM ai_functions 看有哪些函数、怎么调。',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': '一条 SQL 语句。不要写分号分隔的多条。',
      },
    },
    'required': ['query'],
  },
);

/// `askUser` 工具：信息不足时问用户（会挂起，用户回答后继续）。
final kAskUserToolSpec = ToolSpec(
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
);

/// 某次请求该发的完整定义（现在就是全部，不再分层发送）。
List<ToolSpec> specsForRequest() => [kSqlToolSpec, kAskUserToolSpec];

/// 按名字查。找不到返回 null（模型可能报一个不存在的名字）。
ToolSpec? toolByName(String name) {
  for (final t in specsForRequest()) {
    if (t.name == name) return t;
  }
  return null;
}
