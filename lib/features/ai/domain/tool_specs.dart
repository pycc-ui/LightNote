import 'tool_types.dart';

/// 工具的**风险级别**。App 的工具执行器按它决定"要不要先弹确认"。
///
/// ## 为什么风险级别是数据、而不是执行器里的 if
///
/// 安全确认**必须由 App 强制**，不能靠模型自觉调用 `askUser`。
/// 而"哪些操作危险"这件事如果散落在执行器的判断里，加一个新工具时就容易漏。
/// 做成工具定义的一部分，**新工具必须显式声明风险级别**，漏了编译器会提醒。
enum ToolRisk {
  /// 只读：查询、搜索、读笔记/读片/读历史。直接执行。
  read,

  /// 创建：新建笔记 / 笔记库。轻确认。
  create,

  /// 修改：改、移。确认 + 可撤销。
  modify,

  /// 删除：删笔记 / 删笔记库 / 批量删。**二次确认 + 明确"不可恢复"**。
  delete,

  /// 交互：`askUser` / `requestTools`。**不碰数据**，不进风险表。
  interaction,
}

/// 工具的**发送层**（分层发送，省 token）。
enum ToolLayer {
  /// 完整定义每次发。
  core,

  /// 只发名称 + 一句话。
  common,

  /// 默认不发，AI 用 `requestTools` 申请后才给完整定义。
  onDemand,
}

/// 一个可供 AI 调用的工具 = 协议定义 + 风险级别 + 发送层。
class AgentTool {
  const AgentTool({
    required this.spec,
    required this.risk,
    required this.layer,
  });

  final ToolSpec spec;
  final ToolRisk risk;
  final ToolLayer layer;

  String get name => spec.name;
  String get description => spec.description;

  /// 这个工具在真正执行前是否需要用户确认。
  bool get needsConfirm =>
      risk == ToolRisk.create || risk == ToolRisk.modify || risk == ToolRisk.delete;

  /// 是否需要"二次确认"（删除类，措辞要写明不可恢复）。
  bool get needsStrongConfirm => risk == ToolRisk.delete;

  @override
  String toString() => 'AgentTool($name, ${risk.name}, ${layer.name})';
}

// ============================================================================
// 参数 schema 的小工具（写起来短，读起来也清楚）
// ============================================================================

Map<String, dynamic> _obj(
  Map<String, dynamic> props, {
  List<String> required = const [],
}) =>
    {
      'type': 'object',
      'properties': props,
      if (required.isNotEmpty) 'required': required,
    };

Map<String, dynamic> _str(String desc) => {'type': 'string', 'description': desc};

Map<String, dynamic> _int(String desc) => {'type': 'integer', 'description': desc};

Map<String, dynamic> _strList(String desc) => {
      'type': 'array',
      'items': {'type': 'string'},
      'description': desc,
    };

// ============================================================================
// 定案的工具清单（22 个：核心 7 / 常用 10 / 按需 5）
// ============================================================================

/// `requestTools` **单次最多批几个**。
///
/// 定义在这个文件里而不是 `agent_loop.dart`，是因为这个数字**要写进工具描述
/// 给模型看**：描述与执行上限必须是同一个数，否则模型会照着错的数字申请
/// （上限从 5 改成 6 的那次就漏了描述里那句，模型仍然被告知"最多 5 个"）。
///
/// 执行侧（`AgentLoop.maxRequestTools`）引用它；`tool_specs_test` 另有一条用例
/// 钉住"描述里的数字 == 这个常量"。
const kMaxRequestTools = 6;

/// **核心层（7）**：每次请求都发完整定义。
///
/// 覆盖 80% 场景，所以值得占那几百个 token。
final kCoreTools = <AgentTool>[
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.core,
    spec: ToolSpec(
      name: 'searchNotes',
      description: '按关键词搜索用户的笔记，返回标题与摘要片段。'
          '**需要知道"用户写过什么"时优先用它**，不要凭记忆猜。'
          '搜到之后用 noteId 调 listChunks / readChunk 看具体内容。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '关键词，尽量用用户原话里的词'},
          'notebookId': {'type': 'string', 'description': '限定在这个笔记库里搜（可选）'},
          'limit': {'type': 'integer', 'description': '最多返回几条，默认 20'},
        },
        'required': ['query'],
      },
    ),
  ),
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.core,
    spec: ToolSpec(
      name: 'listChunks',
      description: '列出某篇笔记的**切片目录**（每片的标题路径与字数），'
          '**不含正文**。看完目录再用 readChunk 取真正需要的那一两片。',
      parameters: _obj({'noteId': _str('笔记 id')}, required: ['noteId']),
    ),
  ),
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.core,
    spec: ToolSpec(
      name: 'readChunk',
      description: '读某篇笔记的**一片正文**。一次最多 3 片、总量不超过 1500 字。'
          '要改某一段时，取「前一片 + 目标片 + 后一片」正好 3 片。',
      parameters: _obj(
        {
          'noteId': _str('笔记 id'),
          'index': _int('片号（从 listChunks 拿）'),
        },
        required: ['noteId', 'index'],
      ),
    ),
  ),
  AgentTool(
    risk: ToolRisk.create,
    layer: ToolLayer.core,
    spec: ToolSpec(
      name: 'createNote',
      description: '新建一条笔记。**只在用户明确要求"记下来/新建"时用**，'
          '不要为了"整理"而擅自建笔记。',
      parameters: _obj(
        {
          'title': _str('标题，没有就给空串'),
          'content': _str('正文（Markdown）'),
          'notebookId': _str('放进哪个笔记库；不填就是「我的轻笔记」'),
        },
        required: ['content'],
      ),
    ),
  ),
  AgentTool(
    risk: ToolRisk.modify,
    layer: ToolLayer.core,
    spec: ToolSpec(
      name: 'updateNote',
      description: '修改一条笔记的某一段。**必须给 expectedText**（要改的那段原文），'
          'App 会先确认这段还在——不在就说明笔记变了，需要重新定位。'
          '写入前会把「改前 vs 改后」给用户确认。',
      parameters: _obj(
        {
          'noteId': _str('笔记 id'),
          'expectedText': _str('要替换掉的那段**原文**（用于确认定位没错）'),
          'newContent': _str('替换成什么'),
          'title': _str('要改标题时给新标题（可选）'),
        },
        required: ['noteId'],
      ),
    ),
  ),
  AgentTool(
    risk: ToolRisk.interaction,
    layer: ToolLayer.core,
    spec: ToolSpec(
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
          'limit': _int('source 模式下最多给几条选项，默认 10'),
        },
        'required': ['question', 'type'],
      },
    ),
  ),
  AgentTool(
    risk: ToolRisk.interaction,
    layer: ToolLayer.core,
    spec: ToolSpec(
      name: 'requestTools',
      description: '申请更多工具的完整定义。当你需要某个只在"工具目录"里见过名字的工具时用它。'
          '单次最多 $kMaxRequestTools 个，已申请过的不要重复申请。',
      parameters: _obj(
        {'names': _strList('工具名列表，最多 $kMaxRequestTools 个')},
        required: ['names'],
      ),
    ),
  ),
];

/// **常用层（10）**：只发名称 + 一句话，省 token。
final kCommonTools = <AgentTool>[
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.common,
    spec: ToolSpec(name: 'listNotebooks', description: '列出用户的所有笔记库。没有参数。'),
  ),
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'listNotes',
      description: '列出笔记，**按最近修改时间倒序**（可选只看某个笔记库）。'
          '只要 id、标题、所属库、修改时间时用它，比 searchNotes 省钱。',
      parameters: _obj({
        'notebookId': _str('只看这个笔记库；不填＝工作区内的全部（可选）'),
        'limit': _int('最多返回几条，默认 50，上限 100'),
      }),
    ),
  ),
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'getNoteMeta',
      description: '看一条笔记的**元信息**（标题、所属库、创建/修改时间、字数、'
          '切片数、有没有缓存摘要）——**不含正文**。'
          '想知道"这条笔记多大、要不要先看目录"时用它，比直接读正文省 token。',
      parameters: _obj({'noteId': _str('笔记 id')}, required: ['noteId']),
    ),
  ),
  AgentTool(
    risk: ToolRisk.modify,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'appendToNote',
      description: '在一条笔记的**末尾追加**一段内容。'
          '**追加就用它，不要用 updateNote 把整篇重写一遍**——'
          '重写要先读到全文，既贵又容易抄漏。'
          '追加前不需要先读，写入前会把「追加什么」给用户确认。',
      parameters: _obj(
        {
          'noteId': _str('笔记 id'),
          'text': _str('要追加到末尾的内容（Markdown）'),
        },
        required: ['noteId', 'text'],
      ),
    ),
  ),
  AgentTool(
    risk: ToolRisk.delete,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'deleteNote',
      description: '删除一条笔记。**不可恢复**——App 没有回收站。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.modify,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'moveNote',
      description: '把一条笔记移动到另一个笔记库。目标库不确定时先 listNotebooks 或 askUser。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.create,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'createNotebook',
      description: '新建一个笔记库。用户说「建一个/新建笔记库」时用；'
          '名字不确定就先用 askUser 问，别自己编一个。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.modify,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'replaceInNote',
      description: '把笔记里的某个字符串**全部**替换成另一个。纯机械替换，不做理解。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'listHistory',
      description: '回看本会话更早的历史片目录（只有元数据）。'
          '自动带进来的只有最近 5 轮，更早的要用它。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.common,
    spec: ToolSpec(
      name: 'readHistory',
      description: '读本会话某几片历史的正文（≤3 片、≤1500 字）。',
    ),
  ),
];

/// **按需层（5）**：默认不发定义，AI 用 `requestTools` 申请。
///
/// 放在这一层本身就是一层"额外摩擦"——这些工具要么危险、要么很少用，
/// 让模型必须先申请一次，能挡掉一部分"顺手就调了"的情况。
final kOnDemandTools = <AgentTool>[
  AgentTool(
    risk: ToolRisk.modify,
    layer: ToolLayer.onDemand,
    spec: ToolSpec(
      name: 'renameNotebook',
      description: '重命名一个笔记库。只改名字，不动里面的笔记。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.delete,
    layer: ToolLayer.onDemand,
    spec: ToolSpec(
      name: 'deleteNotebook',
      description: '删除一个笔记库。**里面的笔记不会删**，会退回「我的轻笔记」。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.modify,
    layer: ToolLayer.onDemand,
    spec: ToolSpec(name: 'batchMoveNotes', description: '批量移动笔记（最多 10 条）。'),
  ),
  AgentTool(
    risk: ToolRisk.delete,
    layer: ToolLayer.onDemand,
    spec: ToolSpec(
      name: 'batchDeleteNotes',
      description: '批量删除笔记（最多 10 条）。**不可恢复**。',
    ),
  ),
  AgentTool(
    risk: ToolRisk.read,
    layer: ToolLayer.onDemand,
    spec: ToolSpec(
      name: 'searchHistory',
      description: '在本会话更早的历史里**按关键词搜**，返回命中的是第几片'
          '（只给片号与片段，不给全文）。'
          '想找"我们之前是不是聊过 X"时用它——比 listHistory 一页页翻便宜得多。',
      parameters: _obj(
        {
          'query': {'type': 'string', 'description': '关键词，用用户原话里的词'},
          'limit': {'type': 'integer', 'description': '最多返回几片，默认 5'},
        },
        required: ['query'],
      ),
    ),
  ),
];

/// 全部 22 个工具。
final kAgentTools = <AgentTool>[
  ...kCoreTools,
  ...kCommonTools,
  ...kOnDemandTools,
];

/// 按名字查。找不到返回 null（模型可能报一个不存在的名字）。
AgentTool? toolByName(String name) {
  for (final t in kAgentTools) {
    if (t.name == name) return t;
  }
  return null;
}

/// 某次请求该发哪些**完整定义**。
///
/// [granted] 是 `requestTools` 已经批准过的工具名 —— 按需层的工具
/// 只有进了这个集合才会把完整定义发出去。
List<ToolSpec> specsForRequest({Set<String> granted = const {}}) => [
      for (final t in kAgentTools)
        if (t.layer == ToolLayer.core ||
            t.layer == ToolLayer.common ||
            granted.contains(t.name))
          t.spec,
    ];

/// 拼进 system prompt 的「工具目录」：名称 + 一句话。
///
/// 只列**没发完整定义**的那些（按需层），让模型知道"还有这些可用"，
/// 又不占 schema 的 token。
String toolCatalogText({Set<String> granted = const {}}) {
  final pending = [
    for (final t in kAgentTools)
      if (t.layer == ToolLayer.onDemand && !granted.contains(t.name)) t.spec,
  ];
  if (pending.isEmpty) return '';
  final b = StringBuffer('你还可以申请以下工具（先用 requestTools 申请，拿到定义后再调用）：\n');
  for (final s in pending) {
    b.writeln(s.toCatalogLine());
  }
  return b.toString().trimRight();
}
