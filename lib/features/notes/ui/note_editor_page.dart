import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../../../core/db/models.dart';
import '../../../core/secure/secure_store.dart';
import '../../../core/theme/dimens.dart';
import '../../../services/markdown_export_service.dart';
import '../../../services/preferences_service.dart';
import '../../ai/domain/ai_repository.dart';
import '../../cards/ui/card_review_sheet.dart';
import '../../reader/ui/reader_page.dart';
import '../data/note_repository.dart';
import 'widgets/folder_picker.dart';

/// 保存状态（设计稿 §5.4 状态：编辑中 / 保存中 / 已保存 / 保存失败）
enum SaveState { idle, dirty, saving, saved, failed }

/// 笔记编辑页（设计稿 §5.4 / 线框图 4.4）
class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({required this.noteId, super.key});

  final String noteId;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contentFocus = FocusNode();

  Timer? _debounce;
  Note? _note;
  bool _loaded = false;
  bool _preview = false;
  bool _autoSave = true;
  double _fontScale = 1.0;
  SaveState _saveState = SaveState.idle;

  /// 防抖 500ms（设计稿 §5.4 明确要求）
  static const _debounceMs = 500;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // 退出兜底：把未落盘的改动写掉，避免用户输入后立刻返回导致丢字
    _flush();
    _titleController.dispose();
    _contentController.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<NoteRepository>();
    final prefs = context.read<PreferencesService>();

    final note = await repo.byId(widget.noteId);
    final autoSave = await prefs.readAutoSave();
    final fontScale = await prefs.readFontScale();
    if (!mounted || note == null) return;

    _titleController.text = note.title;
    _contentController.text = note.content;
    setState(() {
      _note = note;
      _autoSave = autoSave;
      _fontScale = fontScale;
      _loaded = true;
      _saveState = SaveState.saved;
    });
  }

  void _onChanged(String _) {
    if (!_autoSave) {
      setState(() => _saveState = SaveState.dirty);
      return;
    }
    setState(() => _saveState = SaveState.dirty);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: _debounceMs), _flush);
  }

  Future<void> _flush() async {
    _debounce?.cancel();
    if (_saveState != SaveState.dirty && _saveState != SaveState.failed) return;

    setState(() => _saveState = SaveState.saving);
    try {
      await context.read<NoteRepository>().saveContent(
            widget.noteId,
            title: _titleController.text,
            content: _contentController.text,
          );
      if (!mounted) return;
      setState(() => _saveState = SaveState.saved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveState = SaveState.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      // 有未保存内容时先落盘再退出，不让用户的输入消失
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _flush();
      },
      child: Scaffold(
        appBar: AppBar(
          title: _SaveStatus(state: _saveState),
          actions: [
            IconButton(
              tooltip: _preview ? '编辑' : '预览',
              icon: Icon(
                _preview ? Icons.edit_outlined : Icons.visibility_outlined,
              ),
              onPressed: () => setState(() => _preview = !_preview),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: _onMenu,
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'delete', child: Text('删除笔记')),
                const PopupMenuItem(value: 'export', child: Text('导出 Markdown')),
                const PopupMenuItem(value: 'copy', child: Text('复制全文')),
                if (_note?.isInbox == true)
                  const PopupMenuItem(
                    value: 'archive',
                    child: Text('加入笔记库 / 移动目录'),
                  )
                else
                  const PopupMenuItem(
                    value: 'move',
                    child: Text('移动目录'),
                  ),
                const PopupMenuItem(value: 'read', child: Text('阅读模式')),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _preview ? _buildPreview(theme) : _buildEditor(theme),
            ),
            if (!_preview) _formatToolbar(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Column(
        children: [
          TextField(
            controller: _titleController,
            onChanged: _onChanged,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 22 * _fontScale,
            ),
            decoration: const InputDecoration(
              hintText: '标题',
              border: InputBorder.none,
              filled: false,
            ),
            textInputAction: TextInputAction.next,
          ),
          const Divider(height: 1),
          Expanded(
            child: TextField(
              controller: _contentController,
              focusNode: _contentFocus,
              onChanged: _onChanged,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: TextStyle(fontSize: 16 * _fontScale, height: 1.7),
              decoration: const InputDecoration(
                hintText: '开始记录…\n\n支持 Markdown。写完可以让 AI 整理要点或生成记忆卡片。',
                border: InputBorder.none,
                filled: false,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    return Markdown(
      data: _contentController.text.isEmpty
          ? '_（正文为空）_'
          : _contentController.text,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xl),
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: theme.textTheme.bodyLarge
            ?.copyWith(height: 1.75, fontSize: 16 * _fontScale),
        h1: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700, fontSize: 26 * _fontScale),
        h2: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700, fontSize: 21 * _fontScale),
        h3: theme.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600, fontSize: 18 * _fontScale),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 14 * _fontScale,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        blockquoteDecoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: AppRadius.cardRadius,
        ),
      ),
    );
  }

  /// 格式工具栏（线框图 4.4 底部：B I U • ☑ # 🏷 AI）
  Widget _formatToolbar(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _toolButton(icon: Icons.format_bold, tooltip: '加粗',
                onTap: () => _wrapSelection('**', '**', '粗体')),
            _toolButton(icon: Icons.format_italic, tooltip: '斜体',
                onTap: () => _wrapSelection('*', '*', '斜体')),
            _toolButton(icon: Icons.format_underlined, tooltip: '下划线',
                onTap: () => _wrapSelection('<u>', '</u>', '下划线')),
            _toolButton(icon: Icons.format_list_bulleted, tooltip: '列表',
                onTap: () => _prefixLine('- ')),
            _toolButton(icon: Icons.check_box_outlined, tooltip: '待办',
                onTap: () => _prefixLine('- [ ] ')),
            _toolButton(icon: Icons.title, tooltip: '标题',
                onTap: () => _prefixLine('## ')),
            _toolButton(icon: Icons.label_outline, tooltip: '标签',
                onTap: _manageTags),
            _toolButton(
              icon: Icons.auto_awesome,
              tooltip: 'AI 助手',
              onTap: _showAiMenu,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Expanded(
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        icon: Icon(icon, size: 20, color: color),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// 用 Markdown 标记包裹选中文本；没有选中就插入占位文本并选中它
  void _wrapSelection(String before, String after, String placeholder) {
    final controller = _contentController;
    final text = controller.text;
    final selection = controller.selection;

    // 焦点不在正文（比如刚点了标题）时，退化为在末尾追加
    if (!selection.isValid) {
      final insert = '$before$placeholder$after';
      controller.text = text.isEmpty ? insert : '$text\n$insert';
      _onChanged('');
      return;
    }

    final selected = selection.textInside(text);
    final body = selected.isEmpty ? placeholder : selected;
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      '$before$body$after',
    );
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: selection.start + before.length,
        extentOffset: selection.start + before.length + body.length,
      ),
    );
    _onChanged('');
    _contentFocus.requestFocus();
  }

  /// 在当前行行首插入前缀（标题 / 列表 / 待办）
  void _prefixLine(String prefix) {
    final controller = _contentController;
    final text = controller.text;
    final selection = controller.selection;
    final cursor = selection.isValid ? selection.start : text.length;

    final lineStart = text.lastIndexOf('\n', cursor - 1) + 1;
    var lineEnd = text.indexOf('\n', cursor);
    if (lineEnd < 0) lineEnd = text.length;

    final line = text.substring(lineStart, lineEnd);
    // 已经带了同样的前缀就取消，实现"再点一次关掉"
    final newLine = line.startsWith(prefix)
        ? line.substring(prefix.length)
        : '$prefix$line';

    final newText = text.replaceRange(lineStart, lineEnd, newLine);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: cursor + (newLine.length - line.length),
      ),
    );
    _onChanged('');
    _contentFocus.requestFocus();
  }

  Future<void> _onMenu(String action) async {
    switch (action) {
      case 'delete':
        await _delete();
      case 'export':
        await _exportMarkdown();
      case 'copy':
        await _copyAll();
      case 'archive':
      case 'move':
        await _moveFolder();
      case 'read':
        await _openReader();
    }
  }

  Future<void> _delete() async {
    final title = _titleController.text.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('「${title.isEmpty ? '无标题' : title}」将被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<NoteRepository>().softDelete(widget.noteId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _exportMarkdown() async {
    await _flush();
    if (!mounted) return;
    final note = await context.read<NoteRepository>().byId(widget.noteId);
    if (note == null || !mounted) return;

    final tags = await context.read<NoteRepository>().tagsOf(note.id);
    final text = MarkdownExportService.renderSingle(
      note,
      tags: tags.map((t) => t.name).toList(growable: false),
    );

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('该笔记的 Markdown 已复制到剪贴板')),
    );
  }

  Future<void> _copyAll() async {
    await _flush();
    final note = await context.read<NoteRepository>().byId(widget.noteId);
    if (note == null) return;
    await Clipboard.setData(
      ClipboardData(text: MarkdownExportService.buildCopyText(note)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制全文')),
    );
  }

  Future<void> _moveFolder() async {
    await _flush();
    if (!mounted) return;
    final current = _note?.folderId;
    final folderId = await showFolderPicker(
      context,
      title: _note?.isInbox == true ? '加入笔记库' : '移动目录',
      currentFolderId: current,
      allowRemoveFromFolder: current != null,
    );
    if (folderId == null || !mounted) return;

    final repo = context.read<NoteRepository>();
    if (folderId == kRemoveFromFolder) {
      await repo.moveToInbox(widget.noteId);
    } else {
      await repo.moveToFolder(widget.noteId, folderId);
    }

    final refreshed = await repo.byId(widget.noteId);
    if (mounted) setState(() => _note = refreshed);
  }

  Future<void> _manageTags() async {
    await _flush();
    if (!mounted) return;

    final repo = context.read<NoteRepository>();
    final current = await repo.tagsOf(widget.noteId);
    if (!mounted) return;

    final controller = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('标签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (current.isEmpty)
              const Text('这篇笔记还没有标签', style: TextStyle(fontSize: 13))
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in current)
                    InputChip(
                      label: Text(t.name),
                      onDeleted: () async {
                        await repo.removeTag(widget.noteId, t.id);
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) _manageTags();
                      },
                    ),
                ],
              ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '添加标签',
                hintText: '例如：Flutter',
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('完成'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (added != null && added.isNotEmpty) {
      await repo.addTag(widget.noteId, added);
      if (mounted) _manageTags();
    }
  }

  Future<void> _openReader() async {
    await _flush();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReaderPage(noteId: widget.noteId)),
    );
  }

  Future<void> _showAiMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.summarize_outlined),
              title: const Text('AI 整理要点'),
              subtitle: const Text('生成摘要、要点与建议标签'),
              onTap: () => Navigator.pop(ctx, 'summarize'),
            ),
            ListTile(
              leading: const Icon(Icons.style_outlined),
              title: const Text('生成记忆卡片'),
              subtitle: const Text('生成后需你逐条确认才会入库'),
              onTap: () => Navigator.pop(ctx, 'cards'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('阅读模式'),
              onTap: () => Navigator.pop(ctx, 'read'),
            ),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;
    switch (action) {
      case 'summarize':
        await _runSummarize();
      case 'cards':
        await _runGenerateCards();
      case 'read':
        await _openReader();
    }
  }

  Future<void> _runSummarize() async {
    await _flush();
    if (!mounted) return;

    final content = _contentController.text.trim();
    if (content.isEmpty) {
      _toast('正文为空，先写点内容再让 AI 整理。');
      return;
    }
    if (!await SecureStore.hasApiKey()) {
      if (!mounted) return;
      _toast('还没配置 API Key，请到「设置」里填写。');
      return;
    }

    _showBusy('正在整理笔记…');
    try {
      final thinking = await SecureStore.readThinkingEnabled();
      final result = await context.read<AiRepository>().summarize(
            widget.noteId,
            deepThinking: thinking,
          );
      if (!mounted) return;
      _hideBusy();

      final refreshed = await context.read<NoteRepository>().byId(widget.noteId);
      if (mounted) setState(() => _note = refreshed);
      if (!mounted) return;

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _SummarySheet(result: result),
      );
    } catch (e) {
      if (!mounted) return;
      _hideBusy();
      _toast('整理失败：$e');
    }
  }

  Future<void> _runGenerateCards() async {
    await _flush();
    if (!mounted) return;

    if (_contentController.text.trim().isEmpty) {
      _toast('正文为空，无法生成卡片。');
      return;
    }
    if (!await SecureStore.hasApiKey()) {
      if (!mounted) return;
      _toast('还没配置 API Key，请到「设置」里填写。');
      return;
    }

    _showBusy('正在生成记忆卡片…（这一步用 pro 模型，耗时较长）');
    try {
      final drafts =
          await context.read<AiRepository>().generateCards(widget.noteId);
      if (!mounted) return;
      _hideBusy();

      if (drafts.isEmpty) {
        _toast('这篇笔记没能生成有效卡片，内容可能太短或过于零散。');
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => CardReviewSheet(
          noteId: widget.noteId,
          drafts: drafts,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _hideBusy();
      _toast('生成失败：$e');
    }
  }

  void _showBusy(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: Text(message)),
          ],
        ),
        duration: const Duration(minutes: 5),
      ),
    );
  }

  void _hideBusy() => ScaffoldMessenger.of(context).hideCurrentSnackBar();

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 顶栏的保存状态指示（设计稿 §5.4）
class _SaveStatus extends StatelessWidget {
  const _SaveStatus({required this.state});

  final SaveState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (text, icon, color) = switch (state) {
      SaveState.idle => ('', null, theme.colorScheme.onSurfaceVariant),
      SaveState.dirty => (
          '未保存',
          Icons.edit_outlined,
          theme.colorScheme.onSurfaceVariant
        ),
      SaveState.saving => (
          '保存中…',
          Icons.sync,
          theme.colorScheme.onSurfaceVariant
        ),
      SaveState.saved => (
          '已保存',
          Icons.cloud_done_outlined,
          theme.colorScheme.onSurfaceVariant
        ),
      SaveState.failed => (
          '保存失败',
          Icons.error_outline,
          theme.colorScheme.error
        ),
    };

    if (text.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
        ],
        Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
      ],
    );
  }
}

/// AI 整理结果展示：一句话摘要 + 要点 + 建议标签 + 待办
class _SummarySheet extends StatelessWidget {
  const _SummarySheet({required this.result});

  final NoteAiResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, color: theme.colorScheme.tertiary),
                const SizedBox(width: AppSpacing.sm),
                Text('AI 整理结果', style: theme.textTheme.titleLarge),
              ],
            ),
            if (result.oneLine.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer
                      .withValues(alpha: 0.5),
                  borderRadius: AppRadius.cardRadius,
                ),
                child: Text(
                  result.oneLine,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600, height: 1.5),
                ),
              ),
            ],
            if (result.bullets.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('要点', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              ...result.bullets.map((b) => _Bullet(text: b)),
            ],
            if (result.actionItems.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('待跟进', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              ...result.actionItems.map(
                (a) => _Bullet(text: a, icon: Icons.check_box_outline_blank),
              ),
            ],
            if (result.tags.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('建议标签（已自动关联）', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: result.tags
                    .map((t) => Chip(
                          label: Text(t),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              icon ?? Icons.circle,
              size: icon == null ? 6 : 18,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.65))),
        ],
      ),
    );
  }
}
