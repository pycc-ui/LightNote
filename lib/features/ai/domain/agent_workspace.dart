import 'dart:convert';

/// 工作区的三种状态。
enum WorkspaceMode {
  /// 不选择：AI **看不到任何笔记**（只能依据用户显式附上的文件）
  none,

  /// 全体空间：**全部笔记库 + 我的轻笔记**
  all,

  /// 选择目录：指定的若干笔记库，[AgentWorkspace.includeUnfiled] 另行决定
  /// 要不要带上「我的轻笔记」
  pick;

  static WorkspaceMode parse(Object? raw) {
    if (raw is! String) return WorkspaceMode.none;
    for (final m in WorkspaceMode.values) {
      if (m.name == raw) return m;
    }
    return WorkspaceMode.none;
  }
}

/// **AI 能看到哪些笔记** —— 既是提示词里的一句话，也是**工具的范围**。
///
/// 它必须同时限制工具，不能只当标签：只当标签的话，用户选了"工作"却看到 AI
/// 引用「读书笔记」里的内容，那句标签就成了假话。而 AI 有 `searchNotes` 之后，
/// **搜索是它主要的取材方式**，所以范围必须落在搜索与列笔记这两个工具上。
///
/// ## 三态
///
/// | mode | 含哪些笔记 |
/// |---|---|
/// | `none` | 什么都没有 |
/// | `all` | **全部笔记库 + 我的轻笔记** |
/// | `pick` | 指定的库；`includeUnfiled` 决定要不要再加轻笔记 |
///
/// 「轻笔记」指的是**没有归入任何笔记库**的笔记（`notebook_id IS NULL`）。
class AgentWorkspace {
  const AgentWorkspace({
    this.mode = WorkspaceMode.none,
    this.notebookIds = const [],
    this.includeUnfiled = false,
  });

  final WorkspaceMode mode;

  /// 仅 [WorkspaceMode.pick] 有意义
  final List<String> notebookIds;

  /// 仅 [WorkspaceMode.pick] 有意义：要不要带上「我的轻笔记」
  final bool includeUnfiled;

  static const none = AgentWorkspace();
  static const all = AgentWorkspace(mode: WorkspaceMode.all);

  /// **新会话的默认工作区**：全体空间。
  ///
  /// 新会话默认「全体空间」而不是「不选择」：`none` 不只是"少一句话"——
  /// `ToolExecutor._scope` 会把它变成"一个目录都不含、也不含轻笔记"的查询，
  /// 于是用户第一句问"帮我看看上周那篇"，得到的是"我一条笔记都看不到"。他只会
  /// 以为 AI 坏了，而不会想到是右上角那个**没人会主动点**的工作区入口造成的。
  ///
  /// 默认全选、想做减法的人自己去调，才是默认值该有的样子：
  /// 减法是**有意**的动作，也能一眼看出自己减了什么。
  ///
  /// 想做减法照样做得到：面板里选「不选择」或挑几个库，落库的是
  /// `{"mode":"none"}` / `{"mode":"pick",…}`，与"从没设过"（空串）分得清 ——
  /// 见 [parse]。
  static const initial = all;

  /// AI 看不到任何笔记（`none`，或选了目录但一个都没选）
  bool get isEmpty =>
      mode == WorkspaceMode.none ||
      (mode == WorkspaceMode.pick && notebookIds.isEmpty && !includeUnfiled);

  /// 解析成查询参数。
  ///
  /// [notebookIds] 为 **null 表示"不限目录"**（`all`），
  /// 空列表表示"一个目录都不含"（可能因为 `includeUnfiled` 仍能查到轻笔记）。
  ({List<String>? notebookIds, bool includeUnfiled}) resolve() {
    switch (mode) {
      case WorkspaceMode.none:
        // 空列表 + 不含轻笔记 → 一条都查不到
        return (notebookIds: const [], includeUnfiled: false);
      case WorkspaceMode.all:
        return (notebookIds: null, includeUnfiled: true);
      case WorkspaceMode.pick:
        return (notebookIds: notebookIds, includeUnfiled: includeUnfiled);
    }
  }

  /// 给用户看的标签（也是拼进提示词的那句话）。
  ///
  /// [nameOf] 把笔记库 id 翻成名字；查不到的 id 直接丢掉 ——
  /// 笔记库被删掉之后，标签里不该还留着一个 uuid。
  String label(String? Function(String id) nameOf) {
    switch (mode) {
      case WorkspaceMode.none:
        return '未选择';
      case WorkspaceMode.all:
        return '全体空间';
      case WorkspaceMode.pick:
        final names = [
          for (final id in notebookIds)
            if (nameOf(id) != null) nameOf(id)!,
        ];
        if (includeUnfiled) names.add('我的轻笔记');
        if (names.isEmpty) return '未选择';
        return names.join('、');
    }
  }

  AgentWorkspace copyWith({
    WorkspaceMode? mode,
    List<String>? notebookIds,
    bool? includeUnfiled,
  }) =>
      AgentWorkspace(
        mode: mode ?? this.mode,
        notebookIds: notebookIds ?? this.notebookIds,
        includeUnfiled: includeUnfiled ?? this.includeUnfiled,
      );

  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        // 非 pick 模式不存多余字段：读的时候也就不可能被一个陈旧的
        // `notebookIds` 影响（比如从 pick 切到 all 之后）
        if (mode == WorkspaceMode.pick) ...{
          'notebookIds': notebookIds,
          'includeUnfiled': includeUnfiled,
        },
      };

  /// 解析。三种输入三种处理：
  ///
  /// | 输入 | 结果 | 为什么 |
  /// |---|---|---|
  /// | `null`（连会话记录都没有） | [none] | 说不清是什么情况 → **保守**，别扩大可见范围 |
  /// | 空串（这一列加进来之前的老会话） | [initial] | 表达的是"用户**没做过**这个选择"，不是"选了不选择" |
  /// | 坏 JSON | [none] | 同上：读不懂就按最保守的算 |
  ///
  /// ⚠️ 空串必须等于默认值，不能等于 [none]：否则老会话与新会话的默认
  /// 不一样 —— 同一个 App 里两套默认，用户只会觉得"有时候看得见有时候看不见"。
  /// 用户**显式**选「不选择」时存的是 `{"mode":"none"}`，与空串分得清。
  static AgentWorkspace parse(String? raw) {
    if (raw == null) return none;
    if (raw.trim().isEmpty) return initial;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return none;
      final mode = WorkspaceMode.parse(v['mode']);
      if (mode != WorkspaceMode.pick) return AgentWorkspace(mode: mode);

      final rawIds = v['notebookIds'];
      final ids = <String>[
        if (rawIds is List)
          for (final x in rawIds)
            if (x is String && x.trim().isNotEmpty) x,
      ];
      return AgentWorkspace(
        mode: WorkspaceMode.pick,
        notebookIds: ids,
        includeUnfiled: v['includeUnfiled'] == true,
      );
    } catch (_) {
      return none;
    }
  }

  @override
  String toString() =>
      'AgentWorkspace(${mode.name}, ${notebookIds.length} 个目录, '
      '轻笔记=$includeUnfiled)';

  @override
  bool operator ==(Object other) =>
      other is AgentWorkspace &&
      other.mode == mode &&
      other.includeUnfiled == includeUnfiled &&
      other.notebookIds.length == notebookIds.length &&
      other.notebookIds.every(notebookIds.contains);

  @override
  int get hashCode => Object.hash(
        mode,
        includeUnfiled,
        notebookIds.length,
        // 顺序不参与相等性，所以这里按集合求和即可（同长度时够用）
        notebookIds.fold<int>(0, (a, b) => a ^ b.hashCode),
      );
}
