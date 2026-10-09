import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/seed/seed_data.dart';
import '../../../core/theme/dimens.dart';
import '../../../services/preferences_service.dart';
import '../../folders/data/folder_repository.dart';
import '../../notes/data/note_repository.dart';
import '../../notes/ui/widgets/folder_picker.dart';
import '../domain/ai_chat_repository.dart';

/// AI 页（设计稿 §5.6 / 线框图 4.6）。
///
/// 设计稿要求「MVP 只做界面占位、不自动上传」。这里做了两件事：
///   1. 接上真实 DeepSeek 调用（这是你最初的核心需求）；
///   2. 保留设计稿的隐私约束——首次使用必须显式授权，
///      且每次只发送用户**显式选中**的笔记，不做全库上传。
class AiPage extends StatefulWidget {
  const AiPage({super.key});

  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  String? _conversationId;
  String? _workspaceFolderId;

  /// 工作区名称缓存，避免每次 build 都查库
  String? _workspaceName;

  /// 思考强度：low / medium / high
  String _effort = 'medium';

  /// 显式选中的笔记（默认空 = 不上传任何笔记内容）
  final Set<String> _selectedNoteIds = {};

  bool _sending = false;
  bool _privacyAccepted = true; // 先假设已授权，读取后修正，避免闪一下弹窗
  bool _privacyChecked = false;

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

    // 依赖显式取出后再传，不要写 `SeedData.ensureSeeded(context.read())`：
    // 不带类型参数的 context.read() 返回的是 BuildContext 本身，
    // 会抛 ProviderNotFoundException（这个 bug 已在真机启动时暴露过一次）。
    await SeedData.ensureSeeded(
      notes: context.read<NoteRepository>(),
      folders: context.read<FolderRepository>(),
      prefs: context.read<PreferencesService>(),
    );
    if (!mounted) return;

    final accepted = await repo.hasPrivacyConsent();
    if (!mounted) return;

    final conversations = await repo.watchConversations().first;
    if (!mounted) return;

    setState(() {
      _privacyAccepted = accepted;
      _privacyChecked = true;
      if (conversations.isNotEmpty) {
        _conversationId = conversations.first.id;
        _workspaceFolderId = conversations.first.workspaceFolderId;
        _effort = conversations.first.thinkingEffort;
      }
    });
  }

  Future<String> _ensureConversation() async {
    if (_conversationId != null) return _conversationId!;
    final conv = await context.read<AiChatRepository>().createConversation(
          workspaceFolderId: _workspaceFolderId,
          thinkingEffort: _effort,
        );
    if (mounted) setState(() => _conversationId = conv.id);
    return conv.id;
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<AiChatRepository>();
    final theme = Theme.of(context);

    if (!_privacyChecked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

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
          if (!_privacyAccepted) _PrivacyBanner(onAccept: _acceptPrivacy),
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
          _Composer(
            controller: _inputController,
            workspaceLabel: _workspaceLabel,
            effort: _effort,
            sending: _sending,
            enabled: _privacyAccepted,
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

  String get _workspaceLabel {
    if (_workspaceFolderId == null) return '未选择';
    return _workspaceName ?? '已选择';
  }

  Future<void> _acceptPrivacy() async {
    await context.read<AiChatRepository>().acceptPrivacy();
    if (mounted) setState(() => _privacyAccepted = true);
  }

  Future<void> _newConversation() async {
    final conv = await context.read<AiChatRepository>().createConversation(
          workspaceFolderId: _workspaceFolderId,
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
                        _workspaceFolderId = c.workspaceFolderId;
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

  Future<void> _pickWorkspace() async {
    final folderId = await showFolderPicker(
      context,
      title: '选择工作区',
      currentFolderId: _workspaceFolderId,
      allowRemoveFromFolder: true,
    );
    if (folderId == null || !mounted) return;

    final next = folderId == kRemoveFromFolder ? null : folderId;
    String? name;
    if (next != null) {
      name = (await context.read<FolderRepository>().byId(next))?.name;
    }
    if (!mounted) return;

    setState(() {
      _workspaceFolderId = next;
      _workspaceName = name;
    });

    if (_conversationId != null) {
      await context.read<AiChatRepository>().setWorkspace(_conversationId!, next);
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
              leading: const Icon(Icons.folder_outlined),
              title: const Text('选择目录'),
              subtitle: const Text('把某个目录设为工作区'),
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
    final candidates = await repo.candidateNotes(_workspaceFolderId);
    if (!mounted) return;

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有可选的笔记')),
      );
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
    if (!_privacyAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先阅读并同意上方的数据说明')),
      );
      return;
    }

    setState(() => _sending = true);
    _inputController.clear();

    try {
      final convId = await _ensureConversation();
      await context.read<AiChatRepository>().send(
            conversationId: convId,
            userInput: text,
            contextNoteIds: _selectedNoteIds.toList(growable: false),
            workspaceFolderId: _workspaceFolderId ?? '',
            // 思考强度用 low/medium/high；只有「中」以上才真正开启思考模式，
            // 因为 DeepSeek 思考模式默认开启且 effort 默认 high，
            // 轻量问答开着它纯属浪费
            thinkingEffort: _effort,
            thinkingEnabled: _effort != 'low',
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：$e')));
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

class _PrivacyBanner extends StatelessWidget {
  const _PrivacyBanner({required this.onAccept});

  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.privacy_tip_outlined, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '数据说明',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '笔记默认只存在本机。当你在这里发送指令时：\n'
            '· 只会发送你**显式勾选**的笔记内容，不会上传整个笔记库；\n'
            '· 未勾选任何笔记时，只发送你输入的指令本身；\n'
            '· 内容会发送给 DeepSeek 用于生成回复，需在设置中配置你自己的 API Key。',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: onAccept,
              child: const Text('我已了解，开始使用'),
            ),
          ),
        ],
      ),
    );
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.workspaceLabel,
    required this.effort,
    required this.sending,
    required this.enabled,
    required this.onPickWorkspace,
    required this.onPickEffort,
    required this.onAttach,
    required this.onSend,
  });

  final TextEditingController controller;
  final String workspaceLabel;
  final String effort;
  final bool sending;
  final bool enabled;
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
                tooltip: '选择文件 / 目录',
                onPressed: onAttach,
                icon: const Icon(Icons.add_circle_outline),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  enabled: enabled,
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
                onPressed: (sending || !enabled) ? null : onSend,
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
