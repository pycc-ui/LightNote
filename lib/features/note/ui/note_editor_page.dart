import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/db/models.dart';
import '../../../core/theme/dimens.dart';
import '../../../core/util/ai_limits.dart';
import '../../../core/util/text_utils.dart';
import '../../../core/widgets/log_bar.dart';
import '../../../core/widgets/markdown_view.dart';
import '../../../core/prefs/preferences_service.dart';
import '../data/note_repository.dart';
import '../domain/note_chunk.dart';
import '../domain/note_chunker.dart';
import 'widgets/notebook_picker.dart';

/// 保存状态（编辑中 / 保存中 / 已保存 / 保存失败）
enum SaveState { idle, dirty, saving, saved, failed }

/// 笔记编辑页（见《界面设计》的「笔记编辑页：编辑 / 阅读两态」）。
///
/// 两种模式：**编辑** 与 **阅读**。
///
/// 「阅读」就是 Markdown 渲染后的只读视图。独立的「沉浸阅读模式」页面
/// （隐藏 AppBar、可调字号行距、日间/护眼/夜间三套配色、记录阅读进度）
/// 与它功能重叠，却要多维护一套主题与进度逻辑，所以只保留阅读视图。
/// 新建笔记时用的一组初始参数。
///
/// 为什么要有这个东西：「新建笔记」走的是**延迟创建**：带上这组参数打开编辑页，
/// 只有用户真的输入了内容、第一次落盘时才 `INSERT` 出这条笔记。
/// 什么都没写就返回 → 库里从头到尾没有过它。
///
/// 反过来不行：先把空笔记写进库、再用它的 id 打开编辑页的话，用户什么都没写
/// 就返回，库里就留下一条空白笔记。
///
/// 代价是 [NoteEditorPage.noteId] 在新建时还不存在（为 null），
/// 由编辑页在创建后自己补上。
class NoteDraftParams {
  const NoteDraftParams({this.notebookId, this.asInbox = true});

  /// 归到哪个笔记库；null 表示未归档（「我的轻笔记」）
  final String? notebookId;

  /// 落到哪个区块。true = 我的轻笔记；false = 已归档
  final bool asInbox;
}

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    this.noteId,
    this.draft,
    this.startInReading = false,
    this.initialChunk,
    super.key,
  }) : assert(noteId != null || draft != null,
            '要么打开已有笔记（noteId），要么新建（draft）');

  /// 已有笔记的 id。新建时为 null。
  final String? noteId;

  /// 新建参数。打开已有笔记时为 null。
  final NoteDraftParams? draft;

  /// 打开时是否直接进阅读视图（列表页点进来是阅读，从"编辑"入口进来是编辑）
  final bool startInReading;

  /// 打开后**滚动到第几片**（搜索结果点"笔记内容"时用）。
  ///
  /// 片号来自 `SearchService`（它把命中位置映射到了片），与阅读视图按同一套
  /// 切片规则算出来的片号**必然一致** —— 两边都是 `NoteChunker.chunk`。
  final int? initialChunk;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _contentFocus = FocusNode();

  Note? _note;

  /// 当前笔记 id。新建时先为 null，第一次落盘后补上。
  String? _noteId;

  bool _loaded = false;
  late bool _reading;
  double _fontScale = 1.0;
  SaveState _saveState = SaveState.idle;

  // ---- 阅读视图的"按片渲染" ----

  /// 待滚动到的片号（滚动只做一次，做完置空）。
  int? _pendingScrollChunk;

  /// 阅读视图里每一片外面套的 key，滚到某一片靠它。
  final List<GlobalKey> _chunkKeys = [];

  /// 上一次切片的输入，用来避免每帧都重切一遍。
  String? _chunkCacheKey;
  List<NoteChunk> _chunkCache = const [];


  /// 当前笔记 id，**已确保非空**。
  ///
  /// 新建时 [_noteId] 一开始是 null（笔记还没创建）。所有用到 id 的地方
  /// （删除、移动、导出……）都只在**已经有内容**的前提下
  /// 才可能被触发——"打开编辑页就立刻创建笔记"的旧流程已经去掉了，
  /// 菜单在还没创建时也没有可操作的对象。
  ///
  /// 所以这里断言并在失败时给出可读信息，而不是把 null 一路传下去。
  /// 真出现"没有 id 却调用了"说明流程有 bug，应当尽早暴露。
  String get _id {
    final id = _noteId;
    assert(id != null, '笔记尚未创建，不该在这里用到 id');
    return id!;
  }

  @override
  void initState() {
    super.initState();
    _noteId = widget.noteId;
    _reading = widget.startInReading;
    _pendingScrollChunk = widget.initialChunk;
    _load();
  }

  @override
  void dispose() {
    // **不再有"退出时偷偷写盘"**。
    //
    // 改成手动保存之后，偷偷写盘等于把自动保存换个说法留着 ——
    // 用户以为没保存，其实已经存了；切片的"什么时候切"也跟着变得不可预期。
    // 退出前会**问用户**（见 `_confirmLeave`），由他决定。
    _titleController.dispose();
    _contentController.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<NoteRepository>();
    final prefs = context.read<PreferencesService>();

    final fontScale = await prefs.readFontScale();

    if (_noteId == null) {
      // 新建：库里还没有这条笔记，等第一次落盘才创建
      if (!mounted) return;
      setState(() {
        _fontScale = fontScale;
        _loaded = true;
        _saveState = SaveState.idle;
      });
      return;
    }

    final note = await repo.byId(_noteId!);
    if (!mounted || note == null) return;

    _titleController.text = note.title;
    _contentController.text = note.content;
    setState(() {
      _note = note;
      _fontScale = fontScale;
      _loaded = true;
      _saveState = SaveState.saved;
    });
  }

  /// 内容变了：只把状态标成"未保存"，**不排任何后台写盘**。
  ///
  /// 保存只发生在两个地方：右上角的 ✓，以及退出时用户在询问里选「保存」。
  void _onChanged(String _) {
    if (_saveState == SaveState.dirty) return;
    setState(() => _saveState = SaveState.dirty);
  }

  // ==========================================================================
  // 篇幅上限
  //
  // 产品要求分三级（见 AiLimits）：
  //   80KB  轻提示"注意编辑流畅度"
  //   90KB  强警告"建议拆分"，仍允许保存
  //   100KB 拒绝保存，提示拆分
  //
  // **为什么硬上限是"拒绝保存"而不是"阻止继续输入"**：
  // 在 TextField 里拦输入要处理输入法组字、粘贴、撤销，
  // 任何一处漏掉都会让用户丢掉已敲进去的字。
  // 而"允许写、但不落盘 + 明确告知 + 一键裁剪"不会丢数据——
  // 内容始终在编辑器里，用户可以自己复制走。
  // ==========================================================================

  /// 当前正文的 UTF-8 字节数。
  ///
  /// 用字节而不是字符数：中文一个字 3 字节，按字符算会**低估三倍**，
  /// 而数据库与 token 成本都跟字节更相关。
  int get _contentBytes => utf8ByteLength(_contentController.text);

  /// 把字节数映射成档位（判定逻辑在 [noteSizeLevel]，可单测）。
  NoteSizeLevel get _sizeLevel => noteSizeLevel(_contentController.text);

  /// 人类可读的字节显示（如 "92.3 KB"）。
  String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  /// 把正文裁到刚好不超过软上限，并提示用户。
  ///
  /// 给"拒绝保存"一个**出路**：否则用户面对一条写得太长的笔记
  /// 除了自己一段段删没有别的办法。
  Future<void> _trimToSoftLimit() async {
    final text = _contentController.text;
    final keep = charsForBytes(text, AiLimits.noteSoftBytes);
    final trimmed = text.substring(0, keep);
    final dropped = utf8ByteLength(text) - utf8ByteLength(trimmed);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('裁剪到 80 KB？'),
        content: Text(
          '会删掉末尾约 ${_kb(dropped)} 的内容。\n\n'
          '**这个操作不能撤销**。如果末尾还有要留的东西，'
          '先手动选中复制到别处备份一下。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('裁剪'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    _contentController.text = trimmed;
    _onChanged(trimmed);
    if (mounted) LogBar.info(context, '已裁剪到 ${_kb(utf8ByteLength(trimmed))}');
  }

  /// 落盘时用的标题：先按硬上限截断。
  ///
  /// 为什么标题也要限：它会被拼进摘要的 prompt，
  /// 一个几万字的"标题"能直接把一次请求撑爆。
  /// 截断而不是拒绝——标题过长是异常情况，但没必要为此挡住整篇笔记的保存。
  String get _titleForSave =>
      safeTruncate(_titleController.text, AiLimits.titleHardMax);

  /// 点右上角那个勾：**保存 → 进阅读态**。
  ///
  /// 切片就是在这一步之后切的（`saveContent` 是唯一的写入口，
  /// 它在正文变了时按 20% 阈值决定要不要重切）。所以"什么时候切"现在
  /// 完全由用户按下的那一下决定，不再受输入节奏影响。
  Future<void> _saveAndRead() async {
    await _flush();
    if (!mounted) return;
    // 保存失败（比如超硬上限）就别跳走 —— 让用户看到失败状态并处理
    if (_saveState == SaveState.failed) return;
    setState(() => _reading = true);
  }

  /// 退出前问一句。返回 true 表示可以退出。
  ///
  /// 没有未保存改动时直接放行（不打扰）。
  Future<bool> _confirmLeave() async {
    if (!_hasUnsavedChanges) return true;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('有未保存的改动'),
        content: const Text('要保存之后再退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('放弃改动'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存并退出'),
          ),
        ],
      ),
    );

    switch (choice) {
      case 'save':
        await _flush();
        // 保存失败（超硬上限）就**别退出** —— 否则用户以为存了，其实丢了
        return mounted && _saveState != SaveState.failed;
      case 'discard':
        return true;
      default: // 取消 / 点外面
        return false;
    }
  }

  /// 有没有还没落盘的改动。
  ///
  /// 用 `_saveState` 判断而不是比较文本：`_saveState` 由 `onChanged` 维护，
  /// 而"内容被改回原样"这种情况**不值得**再算一遍差异（那是白费功夫，
  /// 还容易因为换行/空白归一化算错）。
  bool get _hasUnsavedChanges =>
      _saveState == SaveState.dirty || _saveState == SaveState.failed;

  /// 落盘当前编辑内容。
  ///
  /// ## 空草稿不会被写进库
  ///
  /// 标题与正文都是空白时**直接返回**，连笔记都不创建。
  /// 不能把"新建笔记"做成"先把空笔记写进库、再用它的 id 打开编辑页"，再让
  /// `dispose()` 无条件调 `_flush()` → `saveContent`：那样"打开新建页 → 什么都不
  /// 写 → 返回"会留下一条空白笔记。
  ///
  /// 现在配合 [NoteDraftParams] 的**延迟创建**：没内容 → 库里边从来没有过它。
  ///
  /// 判断放在 `_flush` 而不是 `dispose`：`dispose` 有三个调用方
  /// （返回键、页面被替换、测试），把规则放在唯一的落盘入口就不会漏。
  ///
  /// 用**控制器的当前文本**判断而不是 `_saveState`：用户可能先写了几句
  /// （触发过自动保存）、又全删掉再退出，那时 `_saveState` 是 dirty
  /// 但内容确实已经空了。
  Future<void> _flush() async {
    if (_isEmptyDraft()) return;

    // 超过硬上限：**不落盘**。
    //
    // 注意这里不抛错也不清空内容——用户的字还在编辑器里，
    // 只是没进数据库。保存状态会显示为失败，横幅里有裁剪入口。
    if (_sizeLevel == NoteSizeLevel.hard) {
      setState(() => _saveState = SaveState.failed);
      return;
    }

    // 新建的笔记：内容非空才真正创建
    if (_noteId == null) {
      await _createNow();
      return;
    }

    if (_saveState != SaveState.dirty && _saveState != SaveState.failed) return;

    setState(() => _saveState = SaveState.saving);
    try {
      await context.read<NoteRepository>().saveContent(
            _noteId!,
            title: _titleForSave,
            content: _contentController.text,
          );
      if (!mounted) return;
      setState(() => _saveState = SaveState.saved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveState = SaveState.failed);
    }
  }

  /// 第一次落盘：把草稿真正创建成一条笔记。
  ///
  /// 失败时**不抛出**：最坏是没保存上，但用户还能继续编辑、
  /// 下次防抖会再试一次。
  Future<void> _createNow() async {
    final repo = context.read<NoteRepository>();
    final draft = widget.draft;
    if (draft == null) return; // 已有笔记不该走到这里

    setState(() => _saveState = SaveState.saving);
    try {
      final note = draft.asInbox
          ? await repo.createInbox(
              title: _titleForSave,
              content: _contentController.text,
            )
          : await repo.createInNotebook(
              draft.notebookId!,
              title: _titleForSave,
              content: _contentController.text,
            );
      if (!mounted) return;
      setState(() {
        _note = note;
        _noteId = note.id;
        _saveState = SaveState.saved;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveState = SaveState.failed);
    }
  }

  /// 标题与正文**都**为空白。
  ///
  /// 只有标题空、或只有正文空，都不算——用户可能只写了一半。
  /// 两者都空才是"什么都没写"。
  bool _isEmptyDraft() =>
      _titleController.text.trim().isEmpty &&
      _contentController.text.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      // 必须显式 `canPop: false`，否则 `didPop` 恒为 true、
      // 下面那个回调根本不会执行（上一版就白写在这里）。
      //
      // 有未保存的改动时**问用户**：保存并退出 / 放弃改动 / 取消。
      // 这是"手动保存"必须配的那一半 —— 只去掉自动保存而不给询问，
      // 用户按一下返回就静静丢掉内容，那比自动保存更糟。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmLeave();
        if (!leave || !mounted) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: _SaveStatus(state: _saveState),
          actions: _reading
              // ---- 阅读态：回编辑 + 菜单 ----
              ? [
                  TextButton.icon(
                    onPressed: () => setState(() => _reading = false),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑'),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    onSelected: _onMenu,
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline),
                          title: Text('删除笔记'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'copy',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.copy_outlined),
                          title: Text('复制全文'),
                        ),
                      ),
                      if (_note?.isInbox == true)
                        const PopupMenuItem(
                          value: 'archive',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.archive_outlined),
                            title: Text('加入到笔记库'),
                          ),
                        )
                      else
                        const PopupMenuItem(
                          value: 'move',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.drive_file_move_outlined),
                            title: Text('移动到笔记库'),
                          ),
                        ),
                    ],
                  ),
                ]
              // ---- 编辑态：一个勾，点了就保存并进阅读态 ----
              //
              // 为什么编辑时不放菜单：菜单里是删除/移动这类**对已存内容**的操作，
              // 而此刻屏幕上还有没保存的改动。先保存、进阅读态、再动菜单，
              // 顺序上不会出现"删了却发现刚才的改动压根没存"。
              : [
                  IconButton(
                    tooltip: '保存',
                    onPressed: _saveState == SaveState.saving ? null : _saveAndRead,
                    icon: const Icon(Icons.check),
                  ),
                ],
        ),
        // 阅读态右下角是「目录」入口（形状与笔记库页的「AI 助手」按钮一致）；
        // 编辑态不给：那里右手边是输入框与格式工具栏，浮一个按钮上去会压住正文
        floatingActionButton: _reading ? _tocButton() : null,
        body: Column(
          children: [
            // 篇幅提示横幅：只在软上限以上才出现，所以正常写笔记看不见它。
            _sizeBanner(theme),
            Expanded(
              child: _reading
                  ? _withScrollTarget(_buildReading(theme))
                  : _buildEditor(theme),
            ),
            if (!_reading) _formatToolbar(theme),
          ],
        ),
      ),
    );
  }

  /// 按篇幅档位给提示；[ok] 档返回零高度，不占空间。
  ///
  /// 三档的**视觉强度递进**是有意的：轻提示用中性色、强警告用 tertiary、
  /// 硬上限用 error。用户扫一眼颜色就知道严重程度，不用读文字。
  Widget _sizeBanner(ThemeData theme) {
    final level = _sizeLevel;
    if (level == NoteSizeLevel.ok) return const SizedBox.shrink();

    final scheme = theme.colorScheme;
    final bytes = _contentBytes;

    final (IconData icon, Color color, String title, String detail) =
        switch (level) {
      NoteSizeLevel.soft => (
          Icons.info_outline,
          scheme.onSurfaceVariant,
          '笔记较长（${_kb(bytes)}）',
          '继续变长可能影响编辑流畅度。',
        ),
      NoteSizeLevel.warn => (
          Icons.warning_amber_outlined,
          scheme.tertiary,
          '笔记偏长（${_kb(bytes)}）',
          '建议拆成多篇。还能继续编辑，超过 100 KB 就无法保存了。',
        ),
      NoteSizeLevel.hard => (
          Icons.error_outline,
          scheme.error,
          '超出上限（${_kb(bytes)}），无法保存',
          '上限 100 KB。内容还在编辑器里，请拆分成多篇，'
              '或裁剪到 80 KB 后再保存。',
        ),
      NoteSizeLevel.ok => (Icons.info_outline, scheme.onSurfaceVariant, '', ''),
    };

    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.10),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          // 只有硬上限才给裁剪按钮：软/强档用户自己知道怎么处理，
          // 多一个按钮反而增加误触风险（裁剪不可撤销）
          if (level == NoteSizeLevel.hard)
            TextButton(
              onPressed: _trimToSoftLimit,
              child: const Text('裁剪'),
            ),
        ],
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
                hintText: '开始记录…\n\n支持 Markdown。',
                border: InputBorder.none,
                filled: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildReading(ThemeData theme) {
    final title = _titleController.text.trim();
    final content = _contentController.text;
    // 按片渲染：**每片一个 Markdown widget**，各自套一个 GlobalKey。
    //
    // 为什么必须这样：搜索结果要给到"命中哪一片"，用户点进去得能滚到那一段。
    // 整篇一个 Markdown 的话内部没有"片"的概念，`ensureVisible` 无从下手。
    // 附带好处是长文分片渲染，首屏只量可见的那几片。
    //
    // 分片用的是与搜索**同一个** `NoteChunker.chunk`，所以片号必然对得上
    // （不用查库：切片是纯函数，同输入同输出）。
    //
    // Markdown 的样式与"图片不加载"的策略都不在这里：统一走 [MarkdownView]
    // （`core/widgets/markdown_view.dart`）。这里只传字体倍率。
    final pieces = _piecesOf(content);

    return SingleChildScrollView(
      // 底部留白要比别处多一格：右下角浮着「目录」FAB（40 高 + 16 边距），
      // 留 48 的话最后一行正文会被它压住。
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xxl + AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: 26 * _fontScale,
                ),
              ),
            ),
          if (pieces.isEmpty)
            MarkdownView('_（正文为空）_', fontScale: _fontScale)
          else
            for (var i = 0; i < pieces.length; i++)
              Container(
                key: _keyAt(i),
                // 命中那一片给一层淡淡的底色：只滚动不标记的话，用户滚到那儿
                // 也看不出"到底哪一段被搜到了"。
                decoration: i == widget.initialChunk
                    ? BoxDecoration(
                        color: theme.colorScheme.primaryContainer
                            .withValues(alpha: 0.35),
                        borderRadius: AppRadius.cardRadius,
                      )
                    : null,
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs, vertical: 2),
                child: MarkdownView(
                  // 片正文从 content 现取（片只存偏移，不存正文）
                  pieces[i].textOf(content),
                  fontScale: _fontScale,
                ),
              ),
        ],
      ),
    );
  }

  /// 阅读态的「目录」入口：**右下角一个小号 FAB**。
  ///
  /// 它和笔记库页右下角的「AI 助手」按钮**是同一个形状**（`FloatingActionButton.small`
  /// + `heroTag` + tooltip + 一个 16~24 的图标）：那两个都是"点开还有一层"的动作入口，
  /// 又都不属于主流程（主流程是读、是新建），所以都不该占顶栏或底部一整行。
  /// 用户在这两处看到的是同一种东西，不用重新认。
  ///
  /// 只在**阅读态**出现：编辑态右手边要留给输入与工具栏，一个浮起来的按钮
  /// 会压在正文输入框上。
  ///
  /// 没有小标题时**照样显示** —— 点开是一句"怎么才有目录"的说明；
  /// 藏起来的话用户永远不会知道有这个功能（这与"点开是空列表"是两回事）。
  Widget _tocButton() {
    return FloatingActionButton.small(
      // heroTag 必须显式给：同一条路由上若有第二个 FAB 且都用默认 tag，
      // Hero 动画会直接抛异常。这里的 tag 与库里另外两个（ai / create）都不同。
      heroTag: 'toc',
      tooltip: '目录',
      onPressed: _showToc,
      child: const Icon(Icons.toc),
    );
  }

  /// 目录项：**每个小节的第一片**。
  ///
  /// 为什么按"片"列目录，而不是自己再解析一遍 Markdown 标题：
  /// 阅读视图本来就是**按片渲染**、每片一个 `GlobalKey`（见 [_buildReading]），
  /// 而片的分界正是标题层级（`NoteChunker` 保证不跨标题合并）。所以
  /// "目录里的一行" 与 "能滚到的那一片" 天然是同一个东西，不需要两套定位。
  ///
  /// 同一标题被拆成多片时只留第一片 —— 否则目录里会出现三行一模一样的标题。
  List<({int index, String heading, int level})> _sections() {
    final pieces = _piecesOf(_contentController.text);
    final out = <({int index, String heading, int level})>[];
    String? last;
    for (final p in pieces) {
      final heading = p.heading.trim();
      // 空标题是"开头那段没有小标题的正文"，不进目录
      if (heading.isEmpty || heading == last) continue;
      last = heading;
      out.add((index: p.index, heading: heading, level: p.level));
    }
    return out;
  }

  /// 弹出目录，点一条**滚到那一节**。
  ///
  /// 滚动复用 [_pendingScrollChunk] + [_withScrollTarget]（与"搜索结果点进来
  /// 定位到命中片"走的是同一条路径），所以"怎么滚、滚到哪个位置"只有一处实现。
  ///
  /// 顺序上先关弹层、再滚：让用户**看见**页面滚过去了，而不是在弹层背后偷偷滚完。
  Future<void> _showToc() async {
    final sections = _sections();
    final theme = Theme.of(context);

    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: sections.isEmpty
            // 没有小标题时说清楚"怎么才有"，而不是给一个空列表
            ? Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
                child: Text(
                  '这篇笔记还没有小标题，所以没有可跳转的位置。\n\n'
                  '在正文里用「## 小节名」起头，目录里就会出现它们。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('目录', style: theme.textTheme.titleMedium),
                        ),
                        Text(
                          '共 ${sections.length} 节',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: sections.length,
                      itemBuilder: (context, i) {
                        final s = sections[i];
                        // 层级用缩进表达：比画树线安静，长标题也不会被挤掉
                        final indent =
                            (s.level - 1).clamp(0, 3).toDouble() * AppSpacing.md;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.only(
                            left: AppSpacing.md + indent,
                            right: AppSpacing.md,
                          ),
                          title: Text(
                            s.heading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              // 顶层小节加一点分量，扫目录时先看到它
                              fontWeight: s.level <= 1
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          onTap: () => Navigator.pop(ctx, s.index),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );

    if (picked == null || !mounted) return;
    setState(() => _pendingScrollChunk = picked);
  }

  /// 取（并缓存）正文的分片。
  ///
  /// 缓存以**正文本身**为键：阅读视图每次 setState 都会重建，不缓存的话
  /// 一篇长文每帧都要重切一遍。正文变了自然就重切。
  List<NoteChunk> _piecesOf(String content) {
    if (_chunkCacheKey == content) return _chunkCache;
    _chunkCacheKey = content;
    _chunkCache = content.trim().isEmpty
        ? const []
        : NoteChunker.chunk(content);
    return _chunkCache;
  }

  /// 第 [i] 片的 key（按需生成，列表变短时不丢已有的 key）。
  GlobalKey _keyAt(int i) {
    while (_chunkKeys.length <= i) {
      _chunkKeys.add(GlobalKey(debugLabel: 'chunk${_chunkKeys.length}'));
    }
    return _chunkKeys[i];
  }

  /// 包一层"滚动到目标片"的副作用。
  ///
  /// 包在这里而不是塞进 `_buildReading`：`_buildReading` 是纯渲染，
  /// 而滚动是**布局之后**才能做的事，混在一起容易写成"在 build 里做副作用"。
  Widget _withScrollTarget(Widget child) {
    if (_pendingScrollChunk != null) _scrollToPendingChunk();
    return child;
  }

  /// 滚到 [initialChunk]，滚动后把待办清掉（只滚一次）。
  ///
  /// 放在 `addPostFrameCallback` 里：要等这一帧布局完成，那一篇的 widget
  /// 才有 `RenderObject`，`ensureVisible` 才有东西可滚。
  void _scrollToPendingChunk() {
    final want = _pendingScrollChunk;
    if (want == null) return;
    _pendingScrollChunk = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keyAt(want).currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        // 稍微靠上一点：完全贴顶会让人以为这就是文章开头
        alignment: 0.06,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// 格式工具栏（编辑页底部，6 个按钮：加粗 / 斜体 / 下划线 / 列表 /
  /// 待办 / 标题。原先还有一个「标签」，随手动标签功能一起在 schema v9 删除）
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
      case 'copy':
        await _copyAll();
      case 'archive':
      case 'move':
        await _moveFolder();
    }
  }

  /// 把这条笔记的**纯文本**（标题 + 正文）复制到剪贴板。
  ///
  /// 不是 Markdown 导出——`> 元信息` / `> 标签` 那一套已随导出功能一起移除，
  /// 这里只给"把内容拿走"这个最基础的用途。
  Future<void> _copyAll() async {
    if (!await _ensureExists()) return;
    final note = await context.read<NoteRepository>().byId(_id);
    if (note == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: TextUtils.noteCopyText(
          title: note.title,
          content: note.content,
        ),
      ),
    );
    if (!mounted) return;
    LogBar.success(context, '已复制全文');
  }

  /// 菜单动作的统一入口守卫：确保笔记**已经存在**，不存在就提示并放弃。
  ///
  /// 为什么需要：新建笔记时 [_noteId] 一开始是 null（延迟创建）。
  /// 用户还没写任何东西就点「删除 / 移动」，那些动作都要
  /// 一个真实 id——直接 `_id!` 会断言失败。
  ///
  /// 返回 true 表示可以继续。空草稿时**先落盘再判断**：
  /// 用户可能刚打了字、防抖还没触发，这时不该被当成"空"。
  Future<bool> _ensureExists() async {
    if (_noteId != null) return true;
    await _flush();
    if (!mounted) return false;
    if (_noteId != null) return true;
    LogBar.info(context, '先写点内容，再操作这条笔记');
    return false;
  }

  Future<void> _delete() async {
    if (!await _ensureExists()) return;
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
    await context.read<NoteRepository>().softDelete(_id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _moveFolder() async {
    if (!await _ensureExists()) return;
    final current = _note?.notebookId;
    final notebookId = await showNotebookPicker(
      context,
      title: _note?.isInbox == true ? '加入笔记库' : '移动到笔记库',
      currentNotebookId: current,
      allowUnfile: current != null,
    );
    if (notebookId == null || !mounted) return;

    final repo = context.read<NoteRepository>();
    if (notebookId == kUnfileNotebook) {
      await repo.moveToInbox(_id);
    } else {
      await repo.moveToNotebook(_id, notebookId);
    }

    final refreshed = await repo.byId(_id);
    if (mounted) setState(() => _note = refreshed);
  }
}

/// 顶栏的保存状态指示（见《界面设计》的「笔记编辑页」一节）
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
