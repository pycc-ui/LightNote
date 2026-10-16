import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/dimens.dart';
import '../../../core/widgets/log_bar.dart';
import '../../../core/widgets/markdown_view.dart';
import '../data/rag_index_schedule.dart';
import '../domain/ai_chat_repository.dart';
import '../domain/ai_model.dart';
import '../domain/ask_resolver.dart';
import '../domain/ask_user.dart';
import 'agent_dialogs.dart';

/// AI 页（见《界面设计》的「AI 助手页」一节）。
///
/// 设计稿要求「MVP 只做界面占位、不自动上传」。这里做了两件事：
///   1. 接上真实 DeepSeek 调用（这是你最初的核心需求）；
///   2. 每次只发送用户**显式选中**的笔记，不做全库上传。
class AiPage extends StatefulWidget {
  const AiPage({super.key});

  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  String? _conversationId;

  /// 会话选的**模型**（取代原来的「工作区」）。
  ///
  /// 它同时是发送时 `streamAgent` 用的模型，所以这个字段与库里那条会话记录
  /// 必须**始终一致** —— 界面说 flash、实际发 pro（或反过来）会让用户对成本
  /// 产生完全错误的判断。
  String _model = AiModel.flash;

  /// 思考强度：low / medium / high
  String _effort = 'medium';

  /// 这次 `_send()` 还在跑（**只管页面自己发起的这一次**）。
  ///
  /// ⚠️ 它**不能**用来回答"AI 是不是还在生成" —— 见下面 [_busy]。
  bool _sending = false;

  /// 跟着仓库的"在不在跑"重建。
  ///
  /// 界面必须订阅它：一轮跑完时数据库那边**不会**写任何一行（`in_flight`
  /// 是在事务里清掉的，但清掉这个动作本身不保证触发重建），不订阅的话
  /// 转圈会一直挂着。
  StreamSubscription<void>? _runningSub;

  @override
  void initState() {
    super.initState();
    _runningSub = context
        .read<AiChatRepository>()
        .runningChanges
        .listen((_) {
      if (mounted) setState(() {});
    });
    _bootstrap();
  }

  @override
  void dispose() {
    _runningSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// **AI 现在是不是还在生成 —— 以仓库为准，不以页面为准。**
  ///
  /// 这里是这次那个 bug 的修复点。旧写法是 `busy: _sending`，而 `_sending` 属于
  /// 页面 State：用户退出 AI 页时 State 销毁、`_sending` 归 false，**可那一轮还在
  /// 正常跑**；再进来是个新 State，于是"消息上有 `in_flight` 戳 + 看起来没在生成"
  /// → 误报「App 被系统中断，要不要继续」，而点「继续」还会在同一条消息上再起一轮。
  ///
  /// 所以两个来源要合起来看：
  ///   · `_sending`：这次 `_send()` 还在路上（用户刚点发送、第一轮还没开始写库）
  ///   · `isRunning`：仓库里真有一轮在跑（**跨页面重建也有效**）
  bool get _busy {
    final convId = _conversationId;
    if (convId == null) return _sending;
    return _sending || context.read<AiChatRepository>().isRunning(convId);
  }

  Future<void> _bootstrap() async {
    final repo = context.read<AiChatRepository>();

    // 进 AI 页顺手补一批索引（fire-and-forget，**不等它**）。
    //
    // 启动时已经补过一批了（见 lib/main.dart），这里再来一批的理由是：
    // 那个补丁每次启动只推 [RagLimits.indexNotesPerRun] 篇，笔记多的时候
    // 要好几轮才补完；而"用户真的来用 AI 了"正是值得多补一点的时机。
    // 补不完也没关系 —— 索引不全是"少召回几条"，不是错误。
    //
    // 测试里 `instance` 是 null（没人调 start），所以这里一行都不执行。
    RagIndexSchedule.instance?.kickBackfill();

    // 注意：示例数据（SeedData）**不在这里**写了。
    // 它已经挪到启动阶段（见 lib/app/seed_bootstrap.dart），
    // 原因是轻笔记页改成消费流后需要"库里已有笔记库"才能抽出卡片，
    // 而原先只有打开 AI 页才灌示例数据 —— 首屏会看起来是空的。

    if (!mounted) return;

    // 回到**上次看的那条会话**，而不是「最近聊过的第一条」。
    //
    // 这两件事不一样：会话列表按 `updated_at` 排，第一条是最近聊过的；
    // 而用户上次可能在翻一条老会话。记住的是「上次看到哪」，所以它存在仓储里
    //（进程内），见 [AiChatRepository.currentConversationId]。
    //
    // 冷启动（新进程）这个值为空 → 页面停在「新会话」的空状态；
    // 页面重建（返回再进）还是同一个进程 → 回到上次那条。
    // 空状态**不建行**：行由第一次发送时创建，见 [_newConversation]。
    final remembered = repo.currentConversationId;
    if (remembered == null) return;

    final c = await repo.conversationById(remembered);
    if (!mounted) return;
    if (c == null) {
      // 那条会话已经被删了（可能在会话记录页删的）→ 忘掉它，停在空状态。
      // 不在这里做的话，下次进来还会拿着一个不存在的 id 去查。
      repo.currentConversationId = null;
      return;
    }
    _activate(
      conversationId: c.id,
      model: AiModel.parse(c.workspaceScope),
      effort: c.thinkingEffort,
    );
  }

  /// 切到某个会话（或切到"新会话"的空状态），并**同步所有跟着它走的状态**。
  ///
  /// 这三个字段是一套：会话 id、模型、思考强度，
  /// 所以必须抽成一个入口一起改。只改一部分的话，"新建会话"之后输入框旁边还写着
  /// 上一档模型，而库里那个新会话存的是默认档。**界面说的和实际发的不是一回事**，
  /// 这种不一致比功能缺失更难查。
  void _activate({
    required String? conversationId,
    required String model,
    required String effort,
  }) {
    // 记住「当前看的是哪条」：切到别的会话、以及点「新建会话」（传 null）
    // 都在这里过一遍，所以这里写一次就够，不必每个调用点各写一遍。
    context.read<AiChatRepository>().currentConversationId = conversationId;
    setState(() {
      _conversationId = conversationId;
      _model = model;
      _effort = effort;
      // 挂起提问属于**上一个**会话，换会话时先清掉，再按新 id 重查
      _pendingAsk = null;
    });
    // 挂起状态是落库的，切会话就得重新查一次（新会话没有 id → 查出来是 null）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshPendingAsk();
    });
  }

  Future<String> _ensureConversation() async {
    final id = _conversationId;
    if (id != null) return id;
    // 先拿引用再 await：`context.read` 不该在 await 之后用（页面可能已经没了）
    final repo = context.read<AiChatRepository>();
    final conv = await repo.createConversation(
          // 模型必须**在这里一起落库**：`send` / `answerAsk` 都从会话记录里
          // 读模型（那是唯一真相），不传的话"发第一句话之前选的模型"
          // 会被静默丢掉。
          model: _model,
          thinkingEffort: _effort,
        );
    // 记进仓储用的是**仓储自己的引用**，不看页面是否还在：
    // 用户发完第一句就退出、再进来时，应该回到这条会话（而不是空状态）。
    repo.currentConversationId = conv.id;
    if (mounted) setState(() => _conversationId = conv.id);
    return conv.id;
  }

  /// 会话里正在等回答的提问（null = 没有）。
  ///
  /// 存成状态是为了**显示一条提示**：光把挂起落库还不够 ——
  /// 用户重开 App 之后如果什么提示都没有，他根本不知道 AI 在等他，
  /// 得先随便发一句话才会弹出来。那就不叫"随时回答"了。
  PendingAsk? _pendingAsk;


  /// 查一次"有没有待回答的提问"。
  Future<void> _refreshPendingAsk() async {
    final id = _conversationId;
    if (id == null) {
      if (mounted) setState(() => _pendingAsk = null);
      return;
    }
    final p = await context.read<AiChatRepository>().pendingAsk(id);
    if (!mounted) return;
    setState(() => _pendingAsk = p);
  }

  /// 会话里有没有"等你回答"的提问？有就弹出来。
  ///
  /// 从**数据库**查而不是看内存：挂起状态存在 `ai_messages.pendingAction` 里，
  /// 所以**杀掉 App 重开之后**也照样能接着答 —— 这正是选"持久化挂起"而不是
  /// "超时返回"的原因（见《AI接入设计》的「挂起机制：askUser」）。
  /// 看内存的话重启就丢了，用户永远答不上那个问题。
  ///
  /// 发送**前后各调一次**：
  ///   · 之前 —— 恢复上次没答完的（可能已经隔了好几天）
  ///   · 之后 —— AI 刚问的，立刻弹出来，不用用户自己找
  Future<void> _answerPendingIfAny(String convId) async {
    final chat = context.read<AiChatRepository>();
    final pending = await chat.pendingAsk(convId);
    if (pending == null || !mounted) return;

    // 选项由 App **现查**：库里 200 条笔记时模型塞不进 prompt，
    // 而且它给的清单会变旧（可能包含已删除的 id）
    final options =
        await AskResolver(context.read<AppDatabase>()).resolve(pending.request);
    if (!mounted) return;

    final result = await showAskSheet(context, pending.request, options);
    if (!mounted) return;

    setState(() => _pendingAsk = null);
    await chat.answerAsk(
      conversationId: convId,
      result: result,
      thinkingEffort: _effort,
      thinkingEnabled: _effort != 'low',
    );
    // 回答之后可能又问了新的一句 —— 刷新提示条
    if (mounted) await _refreshPendingAsk();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AiChatRepository>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 助手'),
        actions: [
          IconButton(
            tooltip: '会话记录',
            icon: const Icon(Icons.history),
            onPressed: _showConversations,
          ),
          IconButton(
            tooltip: '新建会话',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _newConversation,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _conversationId == null
                ? const _LogoView()
                : StreamBuilder<List<AiMessage>>(
                    stream: repo.watchMessages(_conversationId!),
                    builder: (context, snapshot) {
                      final messages = snapshot.data ?? const <AiMessage>[];
                      if (messages.isEmpty) return const _LogoView();
                      return _MessageList(
                        messages: messages,
                        controller: _scrollController,
                        // 「正在生成」时最后那条不该显示成"未完成"——
                        // 它只是还没写完（气泡里已经有转圈了）。
                        busy: _busy,
                        onContinue: _continueInterrupted,
                        onDismiss: _dismissInterrupted,
                      );
                    },
                  ),
          ),
          // 「AI 在等你回答」——重启 App 之后也要看得到，
          // 否则用户不知道要回答什么，对话就永远停在那儿
          if (_pendingAsk != null)
            _PendingAskBanner(
              question: _pendingAsk!.request.question,
              onTap: () => _answerPendingIfAny(_conversationId!),
            ),
          _Composer(
            controller: _inputController,
            modelLabel: AiModel.label(_model),
            effort: _effort,
            sending: _busy,
            onPickModel: _pickModel,
            onPickEffort: _pickEffort,
            onSend: _send,
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom > 0 ? 0 : 0),
        ],
      ),
      backgroundColor: theme.colorScheme.surface,
    );
  }


  /// 新建会话：**只是切到一个空状态，不落库**。
  ///
  /// 真正的行由 [_ensureConversation] 在第一次发送时建。不能改成"点一下就建一行、
  /// 只在当前会话也没消息时跳过"：那个条件挡不住
  ///
  ///   新建 → 回看一个**有消息**的旧会话 → 再新建
  ///
  /// 这个顺序，每绕一圈就多一条空会话，会话列表里堆一串「新会话」，谁也分不清
  /// 哪条是哪条。根子在于"新建"会被实现成一次**副作用**，而它本该只是一个**状态**。
  /// 把它当状态之后，空会话根本不会存在，"多出来一条"这个失败模式不是被判断挡住，
  /// 而是**不可能发生**。
  ///
  /// 两个连带好处：会话列表里没有空条目（否则最新那条永远是刚点出来的空会话）；
  /// 重开 App 停在空状态、返回再进回到上次看的那条（由
  /// [AiChatRepository.currentConversationId] 记住，见 [_bootstrap]）。
  ///
  /// 输入框里已经打的字**不清**：切会话（包括切到旧的）都不该吃掉用户正在写的东西。
  void _newConversation() {
    _activate(
      conversationId: null,
      // 模型与思考强度都是**用户偏好**，不是会话内容，所以沿用当前档位
      model: _model,
      effort: _effort,
    );
  }

  /// 会话记录：点一条**切过去**，也可以切到**多选**批量删。
  ///
  /// 多选的三条约定照搬笔记库页（`library_page.dart` 的 `_selecting` /
  /// `_selectAppBar` / `_batchDelete`），免得同一个 App 里两种多选手感：
  ///   · 用**单独的 `selecting` 标记**判断是否在多选，不用"选中集合空不空" ——
  ///     空集既表示"没进多选"、也表示"进了但还没选"，用它判断会一进就退出；
  ///   · 「全选 / 全不选」按**当前列表里真实存在的会话**算；
  ///   · 批量删除**先确认**，而且没有撤销（撤销只覆盖"改笔记"，删会话不可逆）。
  Future<void> _showConversations() async {
    final repo = context.read<AiChatRepository>();

    // 多选状态只服务这一次弹层，所以放在这里而不是页面 state：
    // 弹层关掉它就没了，页面不需要知道用户刚才选了几条。
    var selecting = false;
    final selected = <String>{};

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // 会话多的时候要能撑高（默认弹层最高只有半屏左右）
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: StreamBuilder<List<AiConversation>>(
            stream: repo.watchConversations(),
            builder: (context, snapshot) {
              final list = snapshot.data ?? const <AiConversation>[];
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Center(child: Text('还没有会话记录')),
                );
              }

              // 只认"当前列表里还在的"选中项：删完之后 `selected` 里可能留着
              // 已经不在列表里的 id，直接拿来计数会让「已选 N 条」对不上。
              // 这里**过滤而不改写** `selected` —— 免得在 build 里做副作用。
              final visible = list.map((c) => c.id).toSet();
              final picked = selected.where(visible.contains).toSet();
              final allSelected = picked.length == list.length;

              void toggle(String id) => setSheetState(() {
                    if (!selected.remove(id)) selected.add(id);
                  });

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ---- 头部：常态「标题 + 多选」，多选态「退出 + 计数 + 全选」----
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm, 0, AppSpacing.md, AppSpacing.xs),
                    child: Row(
                      children: [
                        if (selecting)
                          IconButton(
                            tooltip: '退出多选',
                            icon: const Icon(Icons.close),
                            onPressed: () => setSheetState(() {
                              selecting = false;
                              selected.clear();
                            }),
                          ),
                        Expanded(
                          child: Text(
                            selecting ? '已选 ${picked.length} 条' : '会话记录',
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                        ),
                        if (selecting)
                          TextButton(
                            onPressed: () => setSheetState(() {
                              if (allSelected) {
                                selected.clear();
                              } else {
                                selected
                                  ..clear()
                                  ..addAll(visible);
                              }
                            }),
                            child: Text(allSelected ? '全不选' : '全选'),
                          )
                        else
                          TextButton(
                            onPressed: () => setSheetState(() {
                              selecting = true;
                              selected.clear();
                            }),
                            child: const Text('多选'),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final c = list[i];
                        return ListTile(
                          leading: selecting
                              ? Checkbox(
                                  value: picked.contains(c.id),
                                  onChanged: (_) => toggle(c.id),
                                )
                              : const Icon(Icons.chat_bubble_outline),
                          title: Text(
                            c.title.trim().isEmpty ? '新会话' : c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(c.thinkingEffort),
                          // 多选态**不给**单条删除按钮：那时"删"是底部那个批量动作，
                          // 同时摆两个删除入口最容易误点
                          trailing: selecting
                              ? null
                              : IconButton(
                                  tooltip: '删除这条会话',
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  onPressed: () =>
                                      _deleteConversations(ctx, repo, [c.id]),
                                ),
                          onTap: selecting
                              ? () => toggle(c.id)
                              : () {
                                  Navigator.pop(ctx);
                                  // 会话 id 与它的模型/思考强度**一起**生效：
                                  // 模型是从这条记录里读出来的，见 [_activate]
                                  _activate(
                                    conversationId: c.id,
                                    model: AiModel.parse(c.workspaceScope),
                                    effort: c.thinkingEffort,
                                  );
                                },
                          // 长按直接进多选并选中这条：想删一串时不用先点「多选」
                          onLongPress: selecting ? null : () {
                            setSheetState(() {
                              selecting = true;
                              selected.add(c.id);
                            });
                          },
                        );
                      },
                    ),
                  ),
                  // ---- 多选态的底部动作 ----
                  if (selecting)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                          AppSpacing.sm, AppSpacing.md, AppSpacing.md),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: picked.isEmpty
                                  ? null
                                  : () => _deleteConversations(
                                        ctx,
                                        repo,
                                        picked.toList(growable: false),
                                      ),
                              icon: const Icon(Icons.delete_outline, size: 18),
                              label: Text(picked.isEmpty
                                  ? '请选择要删除的会话'
                                  : '删除 ${picked.length} 条'),
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    Theme.of(ctx).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 删除若干会话：**先确认，再删，然后关掉弹层**。
  ///
  /// 单条与批量走**同一条路径**（单条也是 `[id]`）—— 否则"要不要确认"
  /// "删完要不要复位当前会话"这类规则会出现两套，改一处漏一处。
  ///
  /// 为什么单条也要确认：那个垃圾桶是**点一下就删**（不是左滑那种明确手势），
  /// 而删会话**没有回收站、也没有撤销**。多一步比丢一串对话便宜得多。
  Future<void> _deleteConversations(
    BuildContext sheetCtx,
    AiChatRepository repo,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return;

    final ok = await showDialog<bool>(
      context: sheetCtx,
      builder: (d) => AlertDialog(
        title: Text('删除 ${ids.length} 条会话'),
        content: const Text('这些会话将被删除（含里面的全部消息），不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(d).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final n = await repo.deleteConversations(ids);
    // 「记住的那条」被删了就一起清掉。不能只靠上面那个 `ids.contains(_conversationId)`：
    // 用户可能正停在空状态（_conversationId == null），而删掉的正是他上次看的那条。
    // 不清的话，下次进页面会拿一个不存在的 id 去查（虽然会兜住，但那是一次白查）。
    if (ids.contains(repo.currentConversationId)) {
      repo.currentConversationId = null;
    }
    if (sheetCtx.mounted) Navigator.pop(sheetCtx);

    // 删掉的里面有**当前**会话 → 回到"新会话"的空状态
    //（连模型一起复位，否则会留着那个已删会话的设置）
    if (mounted && ids.contains(_conversationId)) {
      _activate(
        conversationId: null,
        model: AiModel.flash,
        effort: _effort,
      );
    }
    if (mounted) LogBar.info(context, '已删除 $n 条会话');
  }

  /// 选模型：DeepSeek Flash / DeepSeek Pro。
  ///
  /// 取代了原来的「工作区」入口（工作区已取消，AI 能看到全部笔记）。
  Future<void> _pickModel() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择模型'),
              ),
            ),
            for (final m in AiModel.all)
              ListTile(
                leading: Icon(
                  m == _model
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(AiModel.label(m)),
                subtitle: Text(
                  m == AiModel.pro
                      ? '更强，适合复杂的整理与推理；费用更高'
                      : '默认，日常问答够用；便宜、快',
                ),
                onTap: () => Navigator.pop(ctx, m),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
              child: Text(
                '卡片流固定使用 DeepSeek Flash，不受这里影响。',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _model = picked);
    if (_conversationId != null) {
      await context.read<AiChatRepository>().setModel(_conversationId!, picked);
    }
  }

  Future<void> _pickEffort() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('思考强度'),
              ),
            ),
            for (final e in const [
              ('low', '低', '最快最省，适合简单问答'),
              ('medium', '中', '平衡，默认'),
              ('high', '高', '最慢最贵，适合复杂的结构化整理'),
            ])
              ListTile(
                leading: Icon(
                  e.$1 == _effort
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(e.$2),
                subtitle: Text(e.$3),
                onTap: () => Navigator.pop(ctx, e.$1),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _effort = picked);
    if (_conversationId != null) {
      await context
          .read<AiChatRepository>()
          .setThinkingEffort(_conversationId!, picked);
    }
  }

  /// 「继续」：把上次被打断的那一轮接着做完。
  ///
  /// 实现上就是**把一句话放进输入框再发出去** —— 复用 `_send` 的整条路径
  /// （先答待答的问题、失败有提示、发完滚到底）。这样「继续」没有自己的分支，
  /// 而这句指令用户也看得见：他有权知道 App 替他发了什么。
  ///
  /// ⚠️ 强调「不要重复做」：工具往来**不落库**，模型只看得见自己写过的那段文字，
  /// 以及消息末尾那段「本轮执行记录」—— 后者正是为了这件事才写进去的
  ///（见 AiChatRepository 的 _opsBlock）。
  Future<void> _continueInterrupted(String reasonLabel) async {
    _inputController.text = '（继续）上次的回答被中断了（$reasonLabel），请接着上面的内容继续。'
        '**已经执行过的操作不要重复做**（上一条消息末尾有执行记录）。';
    await _send();
  }

  /// 「知道了」：把这条的中断标记清掉，不再提示。
  ///
  /// 只清标记、不动内容：内容是真实产出（可能只写了一半），
  /// 删掉才是真的丢东西。
  Future<void> _dismissInterrupted(String messageId) async {
    final repo = context.read<AiChatRepository>();
    await repo.clearInterrupt(messageId);
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    // `_busy` 而不是 `_sending`：后台还有一轮在跑时也不该再发（仓库里那道闸会拒，
    // 但界面先拦住才不会弹一个"发送失败"）
    if (text.isEmpty || _busy) return;
    setState(() => _sending = true);
    _inputController.clear();

    try {
      final convId = await _ensureConversation();

      // 先把上次没答完的问题答掉 —— 挂起是持久化的，可能已经隔了好几天
      await _answerPendingIfAny(convId);
      if (!mounted) return;

      final chat = context.read<AiChatRepository>();
      await chat.send(
            conversationId: convId,
            userInput: text,
            // 思考强度用 low/medium/high；只有「中」以上才真正开启思考模式，
            // 因为 DeepSeek 思考模式默认开启且 effort 默认 high，
            // 轻量问答开着它纯属浪费
            thinkingEffort: _effort,
            thinkingEnabled: _effort != 'low',
          );

      // AI 刚问了什么 → 立刻弹出来，别让用户自己去找
      if (mounted) await _answerPendingIfAny(convId);
    } catch (e) {
      if (mounted) {
        LogBar.error(context, '发送失败：$e');
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        // 滚到底部
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    }
  }
}


class _LogoView extends StatelessWidget {
  const _LogoView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.auto_awesome,
              size: 34,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('LightNote AI', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              '可以先选模型与思考强度，然后输入指令。\n'
              '需要笔记内容时，AI 会自己去读。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.controller,
    required this.busy,
    required this.onContinue,
    required this.onDismiss,
  });

  final List<AiMessage> messages;
  final ScrollController controller;

  /// 正在生成（最后一条不算"未完成"）。
  final bool busy;

  /// 「继续」：接着上次被打断的那一轮往下做。
  final void Function(String reasonLabel) onContinue;

  /// 「知道了」：把这条的中断标记清掉（不再提示）。
  final Future<void> Function(String messageId) onDismiss;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final m = messages[i];
        final isUser = m.role == 'user';
        final theme = Theme.of(context);
        final content = m.content.trim();

        // ---- 这条回答写完了没有 ----
        //
        // `interrupt_reason != null` 表示"没写完"，但**正在生成的那条**
        // 也是这个值（每轮开始就会写上 in_flight）—— 所以要看 busy：
        // 真正在跑的最后一条不算未完成，它就是还没写完。
        final generating = busy && i == messages.length - 1;
        final interrupted = !isUser && m.interruptReason != null && !generating;

        final bubble = Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.md - 4),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            decoration: BoxDecoration(
              color: isUser
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: AppRadius.cardRadius,
            ),
            child: content.isEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text('正在生成…', style: theme.textTheme.bodySmall),
                    ],
                  )
                // AI 说的话是 Markdown（可能带公式 / 代码 / 表格），
                // 走统一渲染；**用户自己打的字不渲染**。
                //
                // 为什么不一致：用户在输入框里写的是大白话，没有 Markdown 工具栏，
                // 一句"这个 * 号是什么意思"或者"$100"会被渲染器当强调/公式吃掉 ——
                // 那是"我明明这么打的，界面却显示成别的样子"。
                // 笔记正文不同：那里用户是**有意**写 Markdown 的（编辑器带工具栏）。
                : isUser
                    ? SelectableText(
                        content,
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                      )
                    : MarkdownView(content),
          ),
        );

        if (!interrupted) return bubble;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bubble,
            _InterruptedBar(
              reason: m.interruptReason,
              onContinue: onContinue,
              onDismiss: () => onDismiss(m.id),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        );
      },
    );
  }
}

/// 「这条回答没写完」的提示条。
///
/// 内容**并没有丢**（每个 chunk 都落库了）—— 所以这里不是"重试"，而是"接着做"。
/// 两种情况下会出现：
///   · 网络 / 超时 / 限流导致这一轮失败（`interrupt_reason` 是错误码）；
///   · App 被系统杀掉或崩了：下次冷启动时残留的 `in_flight` 就是这个意思。
class _InterruptedBar extends StatelessWidget {
  const _InterruptedBar({
    required this.reason,
    required this.onContinue,
    required this.onDismiss,
  });

  final String? reason;
  final void Function(String reasonLabel) onContinue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = AiChatRepository.interruptLabel(reason);
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs, top: AppSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              '上次生成中断（$label）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () => onContinue(label),
            child: const Text('继续'),
          ),
          TextButton(
            onPressed: onDismiss,
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

/// 「AI 在等你回答」的提示条。
///
/// 为什么需要一个**常驻提示**而不是弹一次就算了：挂起是持久化的，
/// 用户可能隔一天才回来 —— 那时弹窗早没了。提示条一直在，
/// 他点一下就继续；不点也不挡着他看历史。
class _PendingAskBanner extends StatelessWidget {
  const _PendingAskBanner({required this.question, required this.onTap});

  final String question;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.help_outline,
                  size: 18, color: theme.colorScheme.onTertiaryContainer),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  question,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '回答',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.modelLabel,
    required this.effort,
    required this.sending,
    required this.onPickModel,
    required this.onPickEffort,
    required this.onSend,
  });

  final TextEditingController controller;
  final String modelLabel;
  final String effort;
  final bool sending;
  final VoidCallback onPickModel;
  final VoidCallback onPickEffort;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        children: [
          // 模型与思考强度选择行（AI 页底部）
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onPickModel,
                  borderRadius: AppRadius.cardRadius,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(Icons.memory_outlined,
                            size: 16, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '模型：$modelLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Icon(Icons.chevron_right,
                            size: 16, color: theme.colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: onPickEffort,
                borderRadius: AppRadius.cardRadius,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.psychology_outlined,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        '思考强度：${_effortLabel(effort)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      Icon(Icons.chevron_right,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: const InputDecoration(
                    hintText: '输入指令…',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton.filled(
                tooltip: '发送',
                onPressed: sending ? null : onSend,
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _effortLabel(String effort) => switch (effort) {
        'low' => '低',
        'high' => '高',
        _ => '中',
      };
}
