// AI 操作数据库的**函数清单**（`ai_functions` 表的种子数据）。
//
// 一个函数一条记录：名字 / 分类 / 签名 / 说明 / 例子。这张表是**给 AI 看的**，
// 不是给人看的 —— 函数详情由 `prompts.dart` 从这份清单**生成**进 system prompt，
// 所以这张表同时也是"AI 眼里有哪些工具"的单一真相。于是：
//
//   · system prompt 里不用手抄函数文档（抄了就会和实现分叉）；
//   · **加一个函数 = 这里加一条 + 在 ai_udfs.dart 里注册一次**，prompt 一个字都不用改。
//
// ⚠️ 曾经有过 `mark_functions`（让 AI 把几个函数"钉"成常驻，按需加载详情）。
// 详情改成全量常驻之后它彻底多余，已删（见下面 v4 = 5 那段历史）。
//
// 为什么清单在 Dart 里而不是一段 SQL 里：它要和 `createFunction` 的注册名对齐。
// 两处写名字的地方挨得越近，改名时越不容易漏（漏了的表现是 AI 照着表写 SQL，
// 却报 no such function —— 那种错很难一眼看出来）。
//
// 改清单后**必须把 kAiFunctionsVersion 加 1**，否则老库不会重写这张表
//（对齐逻辑见 AppDatabase 的 ensureAiFunctions）。
library;


import '../util/app_params.dart';

/// 一条函数记录。字段与 `ai_functions` 表的列一一对应。
///
/// ⚠️ 类名不能叫 `AiFunction`：drift 由表类 `AiFunctions` 生成的 row 类正是这个名字，
/// 两者同名会让任何同时用到这份清单与数据库的文件编译不过
///（`NoteChunk` / `NoteChunkRow` 当初踩过同一个坑，见 tables.dart 的说明）。
class AiFunctionSpec {
  const AiFunctionSpec({
    required this.name,
    required this.category,
    required this.signature,
    required this.description,
    this.example,
  });

  /// read / create / modify / delete / system / meta
  ///
  /// 后两类都不是「读写笔记」：`system` 改的是 app_kv（比如会话摘要那类记在
  /// app_kv 里的派生数据），`meta` 什么都不改、只给 App 一个信号（`finish`）。
  /// 分开是因为执行器要按它决定「通知哪几张表」—— 把 `finish` 归进 system
  /// 会让它白通知一次 app_kv。
  final String category;
  final String name;
  final String signature;
  final String description;
  final String? example;
}

/// 清单版本。**改 `kAiFunctions` 就要 +1**，否则已装 App 的库不会跟着更新
///（对齐逻辑见 `AppDatabase._ensureAiFunctions`：库里的版本号对不上才会重写这张表）。
///
/// ## 版本史
///
/// 下面的数字**就是常量值**（以前这里混用过"第几次内容修订"，两套编号放在一起
/// 读起来自相矛盾，已统一）。
///
/// | 版本 | 改了什么 | 条数 |
/// |---|---|---|
/// | 2 | 砍掉所有"单次"函数（`create_note` / `append_to_note` / `replace_unique` / `delete_unique` / `move_note` / `delete_note`）—— 单次也走批量函数（数组放一个元素），AI 只学一种写法 | 30 → 24 |
/// | 3 | 加 `mark_functions`（系统类）：让 AI 自己决定哪些函数的详情常驻 | 24 → 25 |
/// | 4 | 加 `finish`（信号类）：**不改任何数据**，只告诉 App「这一轮就是最终答复」—— 把"任务做完了"变成机器可读的一件事 | 25 → 26 |
/// | **5** | 函数文档**全量进 System Prompt** 之后的大整理（当前）：加 `outline_notes`（标题目录，聚合任务靠它选材）；`read_preview` 改名并扩能成 `read_note_batch`（一次读一批、返回 `next_offset`）；删 `stat_note`（字段并入 `outline_notes`）；删 `mark_functions`（详情常驻之后它彻底多余了） | 26 − 2 + 1 = **25** |
const kAiFunctionsVersion = 5;

/// 25 个函数。顺序按「读 → 建 → 改 → 删 → 信号」排，与《AI 操作数据库设计》一致。
const kAiFunctions = <AiFunctionSpec>[
  // ---------------------------------------------------------------- 读（11）
  AiFunctionSpec(
    name: 'list_notebooks',
    category: 'read',
    signature: 'list_notebooks()',
    description: '列出全部笔记库（不含已删）。要拿笔记库 id 先调它。data=[{id, name}]。',
    example: 'SELECT list_notebooks();',
  ),
  AiFunctionSpec(
    name: 'list_notes',
    category: 'read',
    signature: 'list_notes(notebook_id)',
    description: '列某个笔记库里的笔记（不含已删），最近更新的在前。data=[{id, title, updated_at}]，不含正文。',
    example: "SELECT list_notes('nb1');",
  ),
  AiFunctionSpec(
    name: 'list_unfiled',
    category: 'read',
    signature: 'list_unfiled()',
    description: '列出「我的轻笔记」（未归档）里的笔记。data=[{id, title, updated_at}]。',
    example: 'SELECT list_unfiled();',
  ),
  AiFunctionSpec(
    name: 'outline_notes',
    category: 'read',
    signature: 'outline_notes(json)',
    description: '一次拿多篇的**目录 + 摘要**（不含正文）：用来选材，以及决定「读哪一篇的哪一节」。'
        'json=["n1","n2"]，上限 50 篇。data=[{id, title, notebook_id, chars, excerpt, '
        'created_at, updated_at, sections:[{level, heading, offset, chars}]}]——'
        'sections 是**原文的标题目录**（按 Markdown 的 # 层级切），offset/chars 是这一节的字符范围。'
        '**要看内容就把这里的 offset 抄给 read_note_batch**；一节超过 1500 字会被截断，'
        '按返回的 next_offset 接着读。',
    example: 'SELECT outline_notes(\'["n1","n2"]\');',
  ),
  AiFunctionSpec(
    name: 'read_note_batch',
    category: 'read',
    signature: 'read_note_batch(json)',
    description: '读笔记正文（**单次也用它**）。两种形式：read_note_batch(\'n1\', 0, 200) 读一篇的一段；'
        'read_note_batch(\'[{"id":"n1","offset":3120,"chars":700},{"id":"n2"}]\') 读一批。'
        '不传 offset/chars = 从开头读整篇（单条上限 1500 字）。'
        'data=[{id, title, offset, chars, content, truncated, next_offset?}]：'
        '**被截断时会给出 next_offset，接着从那里读**。整批上限 15000 字 / 20 条，超了整批拒绝。',
    example: "SELECT read_note_batch('[{\"id\":\"n1\",\"offset\":3120,\"chars\":700}]');",
  ),
  AiFunctionSpec(
    name: 'read_around',
    category: 'read',
    signature: 'read_around(note_id, keyword, chars)',
    description: '找 keyword 第一次出现的位置，返回它**前后各 chars 个字符**（默认 200，上限 500）。按字符不按行。找不到返回 {ok:false, error}。',
    example: "SELECT read_around('n1', '风险', 200);",
  ),
  AiFunctionSpec(
    name: 'find_in_note',
    category: 'read',
    signature: 'find_in_note(note_id, keyword)',
    description: '数 keyword 在正文里出现几次、都在哪些字符位置。data={count, positions}。**改之前先用它确认唯一性**。',
    example: "SELECT find_in_note('n1', '主要风险是时间紧');",
  ),
  AiFunctionSpec(
    name: 'search_notes',
    category: 'read',
    signature: 'search_notes(keyword, limit)',
    description: '全库搜标题 + 正文（不含已删）。data=[{id, title, snippet}]，snippet 是命中位置前后各 40 字。limit 默认 20、上限 50。',
    example: "SELECT search_notes('风险', 10);",
  ),
  AiFunctionSpec(
    name: 'search_in_note',
    category: 'read',
    signature: 'search_in_note(note_id, keyword, limit)',
    description: '在一篇笔记里找全部命中。data=[{offset, snippet}]，offset 可直接喂给 read_preview。limit 默认 10、上限 20。',
    example: "SELECT search_in_note('n1', '风险', 10);",
  ),
  AiFunctionSpec(
    name: 'count_notes',
    category: 'read',
    signature: 'count_notes(notebook_id)',
    description: '数笔记条数（不含已删）。传 NULL 数全部，传笔记库 id 只数这个库。data 是整数。',
    example: 'SELECT count_notes(NULL);',
  ),
  AiFunctionSpec(
    name: 'recent_notes',
    category: 'read',
    signature: 'recent_notes(limit)',
    description: '最近更新的笔记。data=[{id, title, updated_at}]。limit 默认 10、上限 50。',
    example: 'SELECT recent_notes(10);',
  ),

  // -------------------------------------------------------------- 创建（3）
  AiFunctionSpec(
    name: 'create_notebook',
    category: 'create',
    signature: 'create_notebook(name)',
    description: '新建笔记库（平铺，没有层级）。名字不能为空、超 200 字截断。data={notebook_id}。',
    example: "SELECT create_notebook('读书笔记');",
  ),
  AiFunctionSpec(
    name: 'duplicate_note',
    category: 'create',
    signature: 'duplicate_note(note_id)',
    description: '复制一篇笔记（标题、正文、所属笔记库照抄；复制出来的不置顶）。data={new_note_id}。',
    example: "SELECT duplicate_note('n1');",
  ),
  AiFunctionSpec(
    name: 'create_notes_batch',
    category: 'create',
    signature: 'create_notes_batch(json)',
    description: '批量新建笔记。json=[{title, content, notebook_id?}]，≤10 条。**单次也用它**（数组放一个元素）。notebook_id 省略/null = 进「我的轻笔记」。正文超 ${AiLimits.noteHardBytes ~/ 1024}KB 会拒绝（**上限管增长不管存在**：改已有笔记时只要不变长就放行）。整批事务：任一条失败全部回滚。data={note_ids}。',
    example:
        "SELECT create_notes_batch('[{\"title\":\"复盘要点\",\"content\":\"正文…\"}]');",
  ),

  // -------------------------------------------------------------- 修改（8）
  AiFunctionSpec(
    name: 'insert_after',
    category: 'modify',
    signature: 'insert_after(note_id, anchor, content)',
    description: '在唯一锚点 anchor 之后另起一行插入 content。anchor 不唯一则失败。',
    example: "SELECT insert_after('n1', '## 风险', '时间紧是主要风险。');",
  ),
  AiFunctionSpec(
    name: 'insert_before',
    category: 'modify',
    signature: 'insert_before(note_id, anchor, content)',
    description: '在唯一锚点 anchor 之前插入 content（自带换行）。anchor 不唯一则失败。',
    example: "SELECT insert_before('n1', '## 结论', '（补充）');",
  ),
  AiFunctionSpec(
    name: 'prepend_to_note',
    category: 'modify',
    signature: 'prepend_to_note(note_id, content)',
    description: '插到正文开头（自动补换行）。',
    example: "SELECT prepend_to_note('n1', '> 2025-01-01 补记');",
  ),
  AiFunctionSpec(
    name: 'rename_note',
    category: 'modify',
    signature: 'rename_note(note_id, new_title)',
    description: '改标题（超 200 字截断）。改正文要用 update_notes_batch / append_notes_batch。',
    example: "SELECT rename_note('n1', '项目A 风险清单');",
  ),
  AiFunctionSpec(
    name: 'rename_notebook',
    category: 'modify',
    signature: 'rename_notebook(notebook_id, new_name)',
    description: '改笔记库名（空名会被拒绝，超 200 字截断）。',
    example: "SELECT rename_notebook('nb1', '工作');",
  ),
  AiFunctionSpec(
    name: 'update_notes_batch',
    category: 'modify',
    signature: 'update_notes_batch(json)',
    description:
        '批量改正文。json=[{id, old, new}]，≤10 条；new 为空串 = 删掉 old 那段。**old 必须在正文里唯一出现**：0 次或多次都失败并说明原因。**单次也用它**。整批事务。',
    example:
        "SELECT update_notes_batch('[{\"id\":\"n1\",\"old\":\"旧\",\"new\":\"新\"}]');",
  ),
  AiFunctionSpec(
    name: 'append_notes_batch',
    category: 'modify',
    signature: 'append_notes_batch(json)',
    description: '批量追加到正文末尾（自动补换行）。json=[{id, content}]，≤10 条。**单次也用它**。整批事务。',
    example:
        "SELECT append_notes_batch('[{\"id\":\"n1\",\"content\":\"补充\"}]');",
  ),
  AiFunctionSpec(
    name: 'move_notes_batch',
    category: 'modify',
    signature: 'move_notes_batch(json)',
    description:
        '批量移动笔记。json=[{id, notebook_id}]，≤10 条；notebook_id 传 null = 移回「我的轻笔记」。**单次也用它**。整批事务。笔记库 id 不存在则失败。',
    example:
        "SELECT move_notes_batch('[{\"id\":\"n1\",\"notebook_id\":\"nb2\"}]');",
  ),

  // -------------------------------------------------------------- 删除（2）
  AiFunctionSpec(
    name: 'delete_notebook',
    category: 'delete',
    signature: 'delete_notebook(notebook_id)',
    description: '删一个笔记库。**库里的笔记不删**，退回「我的轻笔记」。调用即生效。',
    example: "SELECT delete_notebook('nb1');",
  ),
  AiFunctionSpec(
    name: 'delete_notes_batch',
    category: 'delete',
    signature: 'delete_notes_batch(json)',
    description:
        '批量删笔记（逻辑删除 + 清切片）。json=["id1","id2"]，≤10 条。**没有确认层，调用即生效**，只在用户明确要求删时才调。**单次也用它**。整批事务。',
    example: "SELECT delete_notes_batch('[\"n1\",\"n2\"]');",
  ),

  // -------------------------------------------------------------- 信号（1）
  AiFunctionSpec(
    name: 'finish',
    category: 'meta',
    signature: 'finish(reason)',
    description: '**声明这一轮的任务已经做完**。不改任何数据，只给 App 一个信号：'
        '结论已经给出，可以收尾（App 收到就不再跑下一轮）。reason 一句话说明做完了什么。'
        '给最终回答时**顺手调它**——文字照常写在消息里，同一轮加上 finish(…) 即可；'
        '任务没做完就别调：要么继续调函数，要么用 askUser 问清楚。'
        '**不要**只说一句「我先看看 / 接下来我会…」就停下。',
    example: "SELECT finish('已把《项目A》的风险段落改成「风险已识别」');",
  ),
];

/// 会改**笔记数据**的函数名（category 是 create / modify / delete）。
///
/// 用处：执行器据此决定「这次 SQL 之后要不要让界面重新查一遍」；
/// 测试与文档核对清单时也用它。
///
/// 用**正向白名单**而不是"排除 read"：非读的类别会越来越多
///（`system` 只动 app_kv、`meta` 什么都不动），写死排除项的话，
/// 每加一个类别都会悄悄把它算成"写了笔记"—— 表现是每次调它都白刷一遍列表。
final kAiWriteFunctions = <String>{
  for (final f in kAiFunctions)
    if (const {'create', 'modify', 'delete'}.contains(f.category)) f.name,
};

/// **所有非 read 函数**。
///
/// `kAiWriteFunctions` 回答的是「这次改动该通知哪几张表」，
/// 而 `SqlGuard` 要回答的是另一个问题 —— 「这个函数能不能嵌在带 FROM 的查询里」。
/// 答案对**所有**非 read 函数都一样：不能。所以别拿 `kAiWriteFunctions` 去凑
///（`finish` 在 meta 里、什么都不改，但它同样不能按行调用）。
/// 也别在 Guard 里抄一份函数名清单 —— 抄了就会和这张表分叉，
/// 而分叉的表现是「新加的写函数可以按行调用」，没人会发现。
final kAiNonReadFunctions = <String>{
  for (final f in kAiFunctions)
    if (f.category != 'read') f.name,
};

/// 按名字查一条。找不到返回 null。
AiFunctionSpec? aiFunctionByName(String name) {
  for (final f in kAiFunctions) {
    if (f.name == name) return f;
  }
  return null;
}
