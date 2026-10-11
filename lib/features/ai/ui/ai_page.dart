import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/dimens.dart';
import '../../../core/widgets/log_bar.dart';
import '../../note/data/notebook_repository.dart';
import 'workspace_sheet.dart';
import '../domain/ai_chat_repository.dart';
import '../domain/agent_workspace.dart';
import '../domain/ask_resolver.dart';
import '../domain/ask_user.dart';
import 'agent_dialogs.dart';

/// AI 页（设计稿 §5.6 / 线框图 4.6）。
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
  /// 工作区：AI 能看到哪些笔记（三态：不选择 / 全体空间 / 选择目录）
  AgentWorkspace _workspace = AgentWorkspace.none;

  /// 工作区的显示名。**缓存成字段**：它要从库里查笔记库名，
  /// 而 `build` 里不能 await。改动工作区时调 `_refreshWorkspaceLabel`。
  String _workspaceLabelText = '未选择';

  String get _workspaceLabel => _workspaceLabelText;

  /// 工作区名称缓存，避免每次 build 都查库

  /// 思考强度：low / medium / high
  String _effort = 'medium';

  /// 显式选中的笔记（默认空 = 不上传任何笔记内容）
  final Set<String> _selectedNoteIds = {};

  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final repo = context.read<AiChatRepository>();

    // 注意：示例数据（SeedData）**不在这里**写了。
    // 它已经挪到启动阶段（见 lib/app/seed_bootstrap.dart），
    // 原因是轻笔记页改成消费流后需要"库里已有笔记库"才能抽出卡片，
    // 而原先只有打开 AI 页才灌示例数据 —— 首屏会看起来是空的。

    if (!mounted) return;

    final conversations = await repo.watchConversations().first;
    if (!mounted) return;

    setState(() {
      if (conversations.isNotEmpty) {
        _conversationId = conversations.first.id;
    // 进页面就查一次挂起：重开 App 时要能直接看到「AI 在等你回答」
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshPendingAsk();
    });
    _workspace = AgentWorkspace.parse(conversations.first.workspaceScope);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _refreshWorkspaceLabel(); });
        _effort = conversations.first.thinkingEffort;
      }
    });
  }

  Future<String> _ensureConversation() async {
    if (_conversationId != null) return _conversationId!;
    final conv = await context.read<AiChatRepository>().createConversation(
          thinkingEffort: _effort,
        );
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
  /// ## 为什么从**数据库**查而不是看内存
  ///
  /// 挂起状态存在 `ai_messages.pendingAction` 里，所以**杀掉 App 重开之后**
  /// 也照样能接着答 —— 这正是 §9.5 选"持久化挂起"而不是"超时返回"的原因。
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
                      );
                    },
                  ),
          ),
          _ContextBar(
            selectedCount: _selectedNoteIds.length,
            onClear: () => setState(() => _selectedNoteIds.clear()),
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
            workspaceLabel: _workspaceLabel,
            effort: _effort,
            sending: _sending,
            onPickWorkspace: _pickWorkspace,
            onPickEffort: _pickEffort,
            onAttach: _showAttachMenu,
            onSend: _send,
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom > 0 ? 0 : 0),
        ],
      ),
      backgroundColor: theme.colorScheme.surface,
    );
  }


  Future<void> _newConversation() async {
    final conv = await context.read<AiChatRepository>().createConversation(
          thinkingEffort: _effort,
        );
    if (!mounted) return;
    setState(() {
      _conversationId = conv.id;
      _selectedNoteIds.clear();
    });
  }

  Future<void> _showConversations() async {
    final repo = context.read<AiChatRepository>();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
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
            return ListView(
              shrinkWrap: true,
              children: [
                for (final c in list)
                  ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(
                      c.title.trim().isEmpty ? '新会话' : c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(c.thinkingEffort),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () async {
                        await repo.deleteConversation(c.id);
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted && _conversationId == c.id) {
                          setState(() => _conversationId = null);
                        }
                      },
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _conversationId = c.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshPendingAsk();
    });
    _workspace = AgentWorkspace.parse(c.workspaceScope);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _refreshWorkspaceLabel(); });
                        _effort = c.thinkingEffort;
                        _selectedNoteIds.clear();
                      });
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 选工作区：**不选择 / 全体空间 / 选择目录**。
  ///
  /// 第三种要能多选笔记库、并且单独决定要不要带上「我的轻笔记」，
  /// 所以不走通用的单库选择器（那个只返回一个 id）。
  Future<void> _pickWorkspace() async {
    final picked = await showWorkspaceSheet(context, current: _workspace);
    if (picked == null || !mounted) return;

    setState(() => _workspace = picked);
    await _refreshWorkspaceLabel();

    if (_conversationId != null) {
      await context
          .read<AiChatRepository>()
          .setWorkspace(_conversationId!, picked);
    }
  }

  /// 刷新工作区的显示名。
  ///
  /// 名字是**现查**的：笔记库被删掉之后，标签里不该还留着一个 uuid。
  Future<void> _refreshWorkspaceLabel() async {
    final ws = _workspace;
    if (ws.mode == WorkspaceMode.none) {
      if (mounted) setState(() => _workspaceLabelText = '未选择');
      return;
    }
    final all = await context.read<NotebookRepository>().all();
    if (!mounted) return;
    final byId = {for (final n in all) n.id: n.name};
    setState(() => _workspaceLabelText = ws.label((id) => byId[id]));
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

  Future<void> _showAttachMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('选择文件'),
              subtitle: const Text('只发送你勾选的笔记内容'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.library_books_outlined),
              title: const Text('选择笔记库'),
              subtitle: const Text('把某个笔记库设为工作区'),
              onTap: () => Navigator.pop(ctx, 'folder'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'folder') {
      await _pickWorkspace();
    } else {
      await _pickFiles();
    }
  }

  Future<void> _pickFiles() async {
    final repo = context.read<AiChatRepository>();
    final candidates = await repo.candidateNotes(_workspace);
    if (!mounted) return;

    if (candidates.isEmpty) {
      LogBar.info(context, '还没有可选的笔记');
      return;
    }

    // 弹窗里维护临时勾选状态，确认后才生效
    final temp = {..._selectedNoteIds};
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选择要发送的笔记（已选 ${temp.length}）',
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: candidates.length,
                    itemBuilder: (context, i) {
                      final n = candidates[i];
                      return CheckboxListTile(
                        value: temp.contains(n.id),
                        onChanged: (v) => setSheetState(() {
                          if (v == true) {
                            temp.add(n.id);
                          } else {
                            temp.remove(n.id);
                          }
                        }),
                        title: Text(
                          n.title.trim().isEmpty ? '无标题' : n.title.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          n.excerpt,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed == true && mounted) {
      setState(() {
        _selectedNoteIds
          ..clear()
          ..addAll(temp);
      });
    }
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _inputController.clear();

    // 把「写操作要用户点头」这条通道接上。
    //
    // **必须在每次发送前设置**：它闭包住了本页的 `context`，
    // 而 AI 页是可以被重建的。没接上的话执行器会拒绝**全部**写操作
    //（fail closed，见 `ToolExecutor`）。
    context.read<AiChatRepository>().onConfirm =
        (req) => showToolConfirm(context, req);

    try {
      final convId = await _ensureConversation();

      // 先把上次没答完的问题答掉 —— 挂起是持久化的，可能已经隔了好几天
      await _answerPendingIfAny(convId);
      if (!mounted) return;

      final chat = context.read<AiChatRepository>();
      await chat.send(
            conversationId: convId,
            userInput: text,
            contextNoteIds: _selectedNoteIds.toList(growable: false),
            // 思考强度用 low/medium/high；只有「中」以上才真正开启思考模式，
            // 因为 DeepSeek 思考模式默认开启且 effort 默认 high，
            // 轻量问答开着它纯属浪费
            thinkingEffort: _effort,
            thinkingEnabled: _effort != 'low',
          );

      // AI 可能改过东西 → 给一个**可撤销**的提示条。
      //
      // ⚠️ 用 `mounted` 挡住：弹确认层之后这个页面可能已经被销毁了，
      // 那时拿 context 去显示提示条会抛。
      if (mounted && chat.undoable != null) {
        final u = chat.undoable!;
        LogBar.action(
          context,
          '已修改《${u.title.trim().isEmpty ? '无标题' : u.title}》',
          actionLabel: '撤销',
          onAction: () async {
            final id = await chat.undoLast();
            if (!mounted) return;
            LogBar.success(context, id == null ? '没有可撤销的修改' : '已撤销');
          },
        );
      }

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
              '可以先选工作区与思考强度，\n'
              '再用 + 勾选要参考的笔记，然后输入指令。',
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
  const _MessageList({required this.messages, required this.controller});

  final List<AiMessage> messages;
  final ScrollController controller;

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

        return Align(
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
                : SelectableText(
                    content,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
          ),
        );
      },
    );
  }
}

/// 已选上下文提示条
class _ContextBar extends StatelessWidget {
  const _ContextBar({required this.selectedCount, required this.onClear});

  final int selectedCount;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (selectedCount == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          const Icon(Icons.attach_file, size: 16),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '本次将发送 $selectedCount 篇笔记的内容',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('清空'),
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
    required this.workspaceLabel,
    required this.effort,
    required this.sending,
    required this.onPickWorkspace,
    required this.onPickEffort,
    required this.onAttach,
    required this.onSend,
  });

  final TextEditingController controller;
  final String workspaceLabel;
  final String effort;
  final bool sending;
  final VoidCallback onPickWorkspace;
  final VoidCallback onPickEffort;
  final VoidCallback onAttach;
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
          // 工作区与思考强度选择行（线框图 4.6 底部）
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onPickWorkspace,
                  borderRadius: AppRadius.cardRadius,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(Icons.workspaces_outline,
                            size: 16, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '工作区：$workspaceLabel',
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
              IconButton(
                tooltip: '选择文件 / 笔记库',
                onPressed: onAttach,
                icon: const Icon(Icons.add_circle_outline),
              ),
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
