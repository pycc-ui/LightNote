// AI 操作数据库的**函数清单**（`ai_functions` 表的种子数据）。
//
// 一个函数一条记录：名字 / 分类 / 签名 / 说明 / 例子。这张表是**给 AI 看的**，
// 不是给人看的 —— AI 需要的函数没在 system prompt 的「已加载详情」里时，
// 查一次 `SELECT name, signature FROM ai_functions` 拿到目录，再用
// `mark_functions` 把常用的几个标记为常驻（见本文件末尾与 ai_udfs.dart）。于是：
//
//   · system prompt 里只写「去查 ai_functions」，不用把 26 个函数抄一遍；
//   · **加一个函数 = 这里加一条 + 在 ai_udfs.dart 里注册一次**，prompt 一个字都不用改。
//
// 为什么清单在 Dart 里而不是一段 SQL 里：它要和 `createFunction` 的注册名对齐。
// 两处写名字的地方挨得越近，改名时越不容易漏（漏了的表现是 AI 照着表写 SQL，
// 却报 no such function —— 那种错很难一眼看出来）。
//
// 改清单后**必须把 kAiFunctionsVersion 加 1**，否则老库不会重写这张表
//（对齐逻辑见 AppDatabase 的 ensureAiFunctions）。
library;

import 'dart:convert';

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
  /// 后两类都不是「读写笔记」：`system` 改的是 app_kv（`mark_functions` 钉住函数详情），
  /// `meta` 什么都不改、只给 App 一个信号（`finish`）。分开是因为执行器要按它决定
  /// 「通知哪几张表」——把 `finish` 归进 system 会让它白通知一次 app_kv。
  final String category;
  final String name;
  final String signature;
  final String description;
  final String? example;
}

/// 清单版本。**改 kAiFunctions 就要 +1**，否则已装 App 的库不会跟着更新。
///
/// v4（=3）：加了 `mark_functions`（第 25 个）。
/// v5（=4）：加了 `finish`（第 26 个，信号类）—— 让「任务做完了」变成机器可读的一件事。
const kAiFunctionsVersion = 4;

/// 26 个函数。顺序按「读 → 建 → 改 → 删 → 系统 → 信号」排，与《AI 操作数据库设计》一致。
///
/// v3 的重要变化：**有批量版的单次函数全部砍掉**（create_note / append_to_note /
/// replace_unique / delete_unique / move_note / delete_note）——单次也走批量函数
/// （数组放一个元素）。所以从 30 变成 24，AI 只学一种写法。
///
/// v4：加回"系统"类里的 `mark_functions`，25 个 —— 它不读写笔记，
/// 而是让 AI **自己决定哪些函数的详情常驻**（见文件末尾的说明）。

/// v5（本版）：加第 26 个 —— `finish`（信号类）。**不改任何数据**，
/// 只告诉 App「这一轮就是最终答复，可以收尾了」。
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
    name: 'stat_note',
    category: 'read',
    signature: 'stat_note(note_id)',
    description: '一篇笔记的元信息。data={title, notebook_id, char_count, created_at, updated_at}。**不含正文**：要内容用 read_around / read_preview。',
    example: "SELECT stat_note('n1');",
  ),
  AiFunctionSpec(
    name: 'read_preview',
    category: 'read',
    signature: 'read_preview(note_id, offset, chars)',
    description: '从第 offset 个字符起读 chars 个字符（offset 默认 0、chars 默认 200，上限 500）。data 是这段文本。**读不到全文**：要特定段落先 find_in_note / search_in_note 定位。',
    example: "SELECT read_preview('n1', 0, 300);",
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
    description: '批量新建笔记。json=[{title, content, notebook_id?}]，≤10 条。**单次也用它**（数组放一个元素）。notebook_id 省略/null = 进「我的轻笔记」。正文超 100KB 会拒绝。整批事务：任一条失败全部回滚。data={note_ids}。',
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

  // -------------------------------------------------------------- 系统（1）
  AiFunctionSpec(
    name: 'mark_functions',
    category: 'system',
    signature: 'mark_functions(json)',
    description: '把这次任务**会反复用**的函数标记为常驻：它们的详情（签名 / 说明 / 例子）'
        '立刻拼进 System Prompt 末尾，本轮下一轮起、以及之后所有会话都直接可用，'
        '不用再查 ai_functions。json=["search_notes","read_preview"]。'
        '只增不减（没有取消标记），最多 ${SqlLimits.maxPinnedFunctions} 个。'
        '需要的函数已经在「已加载函数详情」里时**不要重复标记**。',
    example: "SELECT mark_functions('[\"search_notes\",\"read_preview\"]');",
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
/// ⚠️ `system` 类不算写笔记（`mark_functions` 只动 app_kv，见 [kAiKvFunctions]）——
/// 混进来会让"读是 11 个，其余都是写"这个不变量失去意义。
final kAiWriteFunctions = <String>{
  for (final f in kAiFunctions)
    if (f.category != 'read' && f.category != 'system') f.name,
};

/// 只改 `app_kv`（不动笔记）的函数名。执行器据此通知对应的表变了。
final kAiKvFunctions = <String>{
  for (final f in kAiFunctions)
    if (f.category == 'system') f.name,
};

/// **所有非 read 函数**（写笔记的 + 只动 app_kv 的）。
///
/// 第三个集合的理由：上面两个集合回答的是「这次改动该通知哪几张表」，
/// 而 `SqlGuard` 要回答的是另一个问题 —— 「这个函数能不能嵌在带 FROM 的查询里」。
/// 答案对**所有**非 read 函数都一样：不能。所以别拿上面两个集合去凑
///（`mark_functions` 在 system 里，只取 `kAiWriteFunctions` 会漏掉它），
/// 也别在 Guard 里抄一份函数名清单 —— 抄了就会和这张表分叉，
/// 而分叉的表现是「新加的写函数可以按行调用」，没人会发现。
final kAiNonReadFunctions = <String>{
  for (final f in kAiFunctions)
    if (f.category != 'read') f.name,
};

// ============================================================================
// 「已加载函数」——AI 用 mark_functions 标记的那几个
// ============================================================================

/// `app_kv` 里存已标记函数名的 key（JSON 数组字符串）。
///
/// **唯一的写者是 UDF `mark_functions`**（见 ai_udfs.dart）：它和写笔记走同一条
/// 原始连接，所以 app_kv 就是唯一真相，App 侧只读、不另存一份状态。
/// （这也是这里不放 `appendPinnedFunctions` 的原因：多一个写者就多一份可能不一致的副本。）
const kAiPinnedFunctionsKey = 'ai_pinned_functions';

/// 解析 [kAiPinnedFunctionsKey] 的值。
///
/// 两道过滤，都是为了让**坏数据不至于毁掉整个 prompt**：
///   · 非数组 / 坏 JSON → 当空；
///   · 名字已经不在清单里（函数被删或改名）→ 丢掉 —— 否则详情段渲染不出内容，
///     而计数还占着那 15 个名额。
/// 顺序与去重都保持，重复标记不该让同一个函数出现两次。
List<String> parsePinnedFunctions(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <String>[];
    for (final e in decoded) {
      if (e is! String) continue;
      final name = e.trim();
      if (name.isEmpty || out.contains(name)) continue;
      if (aiFunctionByName(name) == null) continue;
      out.add(name);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 按名字查一条。找不到返回 null。
AiFunctionSpec? aiFunctionByName(String name) {
  for (final f in kAiFunctions) {
    if (f.name == name) return f;
  }
  return null;
}
