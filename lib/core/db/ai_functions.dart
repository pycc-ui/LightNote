// AI 操作数据库的**函数清单**（`ai_functions` 表的种子数据）。
//
// 一个函数一条记录：名字 / 分类 / 签名 / 说明 / 例子。这张表是**给 AI 看的**，
// 不是给人看的 —— AI 先 `SELECT * FROM ai_functions` 查一次，就知道有哪些函数、
// 怎么调、边界在哪。于是：
//
//   · system prompt 里只写「去查 ai_functions」，不用把 25 个函数抄一遍；
//   · **加一个函数 = 这里加一条 + 在 ai_udfs.dart 里注册一次**，prompt 一个字都不用改。
//
// 为什么清单在 Dart 里而不是一段 SQL 里：它要和 `createFunction` 的注册名对齐。
// 两处写名字的地方挨得越近，改名时越不容易漏（漏了的表现是 AI 照着表写 SQL，
// 却报 no such function —— 那种错很难一眼看出来）。
//
// 改清单后**必须把 kAiFunctionsVersion 加 1**，否则老库不会重写这张表
//（对齐逻辑见 AppDatabase 的 ensureAiFunctions）。
library;

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

  /// read / create / modify / delete
  final String category;
  final String name;
  final String signature;
  final String description;
  final String? example;
}

/// 清单版本。**改 kAiFunctions 就要 +1**，否则已装 App 的库不会跟着更新。
const kAiFunctionsVersion = 1;

/// 25 个函数。顺序按「读 → 建 → 改 → 删」排，与设计文档的四节一致。
const kAiFunctions = <AiFunctionSpec>[
  // ---------------------------------------------------------------- 读（11）
  AiFunctionSpec(
    name: 'list_notebooks',
    category: 'read',
    signature: 'list_notebooks()',
    description: '列出全部笔记库（不含已删）。返回 [{id, name}]。要拿笔记库 id 先调它。',
    example: 'SELECT list_notebooks();',
  ),
  AiFunctionSpec(
    name: 'list_notes',
    category: 'read',
    signature: 'list_notes(notebook_id)',
    description: '列某个笔记库里的笔记（不含已删），最近更新的在前。返回 [{id, title, updated_at}]，不含正文。',
    example: "SELECT list_notes('nb1');",
  ),
  AiFunctionSpec(
    name: 'list_unfiled',
    category: 'read',
    signature: 'list_unfiled()',
    description: '列出「我的轻笔记」（未归档）里的笔记。返回 [{id, title, updated_at}]。',
    example: 'SELECT list_unfiled();',
  ),
  AiFunctionSpec(
    name: 'stat_note',
    category: 'read',
    signature: 'stat_note(note_id)',
    description: '一篇笔记的元信息 {title, notebook_id, char_count, created_at, updated_at}。**不含正文、不含行数**：要内容用 read_around / read_preview。',
    example: "SELECT stat_note('n1');",
  ),
  AiFunctionSpec(
    name: 'read_preview',
    category: 'read',
    signature: 'read_preview(note_id, offset, chars)',
    description: '从第 offset 个字符起读 chars 个字符（offset 默认 0、chars 默认 200，上限 500）。**读不到全文**：要特定段落先 find_in_note / search_in_note 定位。',
    example: "SELECT read_preview('n1', 0, 300);",
  ),
  AiFunctionSpec(
    name: 'read_around',
    category: 'read',
    signature: 'read_around(note_id, keyword, chars)',
    description: '找 keyword 第一次出现的位置，返回它**前后各 chars 个字符**（默认 200，上限 500）。按字符不按行。找不到返回 {ok:false,error}。',
    example: "SELECT read_around('n1', '风险', 200);",
  ),
  AiFunctionSpec(
    name: 'find_in_note',
    category: 'read',
    signature: 'find_in_note(note_id, keyword)',
    description: '数 keyword 在正文里出现几次、都在哪些字符位置。返回 {count, positions}。**改之前先用它确认唯一性**。',
    example: "SELECT find_in_note('n1', '主要风险是时间紧');",
  ),
  AiFunctionSpec(
    name: 'search_notes',
    category: 'read',
    signature: 'search_notes(keyword, limit)',
    description: '全库搜标题 + 正文（不含已删），返回 [{id, title, snippet}]，snippet 是命中位置前后各 40 字。limit 默认 20、上限 50。',
    example: "SELECT search_notes('风险', 10);",
  ),
  AiFunctionSpec(
    name: 'search_in_note',
    category: 'read',
    signature: 'search_in_note(note_id, keyword, limit)',
    description: '在一篇笔记里找全部命中，返回 [{offset, snippet}]，offset 可直接喂给 read_preview。limit 默认 10、上限 20。',
    example: "SELECT search_in_note('n1', '风险', 10);",
  ),
  AiFunctionSpec(
    name: 'count_notes',
    category: 'read',
    signature: 'count_notes(notebook_id)',
    description: '数笔记条数（不含已删）。传 NULL 数全部，传笔记库 id 只数这个库。',
    example: 'SELECT count_notes(NULL);',
  ),
  AiFunctionSpec(
    name: 'recent_notes',
    category: 'read',
    signature: 'recent_notes(limit)',
    description: '最近更新的笔记 [{id, title, updated_at}]。limit 默认 10、上限 50。',
    example: 'SELECT recent_notes(10);',
  ),

  // -------------------------------------------------------------- 创建（3）
  AiFunctionSpec(
    name: 'create_note',
    category: 'create',
    signature: 'create_note(title, content, notebook_id)',
    description: '新建一篇笔记。notebook_id 传 NULL 或省略 = 进「我的轻笔记」。title 超 200 字截断，正文超 100KB 会**拒绝**（要拆成几篇）。返回 {ok, note_id}。',
    example: "SELECT create_note('会议记录', '正文…', NULL);",
  ),
  AiFunctionSpec(
    name: 'create_notebook',
    category: 'create',
    signature: 'create_notebook(name)',
    description: '新建笔记库（平铺，没有层级）。名字不能为空、超 200 字截断。返回 {ok, notebook_id}。',
    example: "SELECT create_notebook('读书笔记');",
  ),
  AiFunctionSpec(
    name: 'duplicate_note',
    category: 'create',
    signature: 'duplicate_note(note_id)',
    description: '复制一篇笔记（标题、正文、所属笔记库照抄；复制出来的不置顶）。返回 {ok, new_note_id}。',
    example: "SELECT duplicate_note('n1');",
  ),

  // -------------------------------------------------------------- 修改（9）
  AiFunctionSpec(
    name: 'replace_unique',
    category: 'modify',
    signature: 'replace_unique(note_id, old, new)',
    description: '把正文里的 old 换成 new。**old 必须在正文里唯一出现**：出现 0 次或多次都失败，返回 {ok:false,error}。锚点写长一点最稳。',
    example: "SELECT replace_unique('n1', '主要风险是时间紧', '风险已识别');",
  ),
  AiFunctionSpec(
    name: 'delete_unique',
    category: 'modify',
    signature: 'delete_unique(note_id, old)',
    description: '删掉正文里的 old（等价于 replace_unique(note_id, old, 空串)）。old 同样必须唯一出现。',
    example: "SELECT delete_unique('n1', '（待补）');",
  ),
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
    name: 'append_to_note',
    category: 'modify',
    signature: 'append_to_note(note_id, content)',
    description: '追加到正文末尾（自动补换行）。返回 {ok:true}。',
    example: "SELECT append_to_note('n1', '## 后续' || char(10) || '下周一同步。');",
  ),
  AiFunctionSpec(
    name: 'prepend_to_note',
    category: 'modify',
    signature: 'prepend_to_note(note_id, content)',
    description: '插到正文开头（自动补换行）。返回 {ok:true}。',
    example: "SELECT prepend_to_note('n1', '> 2025-01-01 补记');",
  ),
  AiFunctionSpec(
    name: 'rename_note',
    category: 'modify',
    signature: 'rename_note(note_id, new_title)',
    description: '改标题（超 200 字截断）。改正文要用 replace_unique / append_to_note。',
    example: "SELECT rename_note('n1', '项目A 风险清单');",
  ),
  AiFunctionSpec(
    name: 'move_note',
    category: 'modify',
    signature: 'move_note(note_id, notebook_id)',
    description: '把笔记移到某个笔记库；notebook_id 传 NULL = 移回「我的轻笔记」。笔记库 id 不存在则失败。',
    example: "SELECT move_note('n1', 'nb1');",
  ),
  AiFunctionSpec(
    name: 'rename_notebook',
    category: 'modify',
    signature: 'rename_notebook(notebook_id, new_name)',
    description: '改笔记库名（空名会被拒绝，超 200 字截断）。',
    example: "SELECT rename_notebook('nb1', '工作');",
  ),

  // -------------------------------------------------------------- 删除（2）
  AiFunctionSpec(
    name: 'delete_note',
    category: 'delete',
    signature: 'delete_note(note_id)',
    description: '删一篇笔记（逻辑删除 + 清掉它的切片）。**没有确认层，调用即生效**，只在用户明确要求删时才调。',
    example: "SELECT delete_note('n1');",
  ),
  AiFunctionSpec(
    name: 'delete_notebook',
    category: 'delete',
    signature: 'delete_notebook(notebook_id)',
    description: '删一个笔记库。**库里的笔记不删**，退回「我的轻笔记」。调用即生效。',
    example: "SELECT delete_notebook('nb1');",
  ),
];

/// 会改数据的函数名（category 不是 read）。
///
/// 两个用处：执行器据此决定「这次 SQL 之后要不要让界面重新查一遍」；
/// 测试与文档核对清单时也用它。
final kAiWriteFunctions = <String>{
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
