import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import '../../../core/db/models.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/text_utils.dart';
import '../../notes/data/note_repository.dart';

/// 沉浸阅读模式。
///
/// 三层设计中的 L1（沉浸）与 L2（结构化速读）：
/// - L1：隐藏 AppBar / 底部栏，纯正文，可调字号行距与日间/护眼/夜间主题
/// - L2：顶部固定 AI 摘要卡（一句话 + 要点），可折叠，离线可看
///
/// L3（TTS 朗读）列入 v1.1。
class ReaderPage extends StatefulWidget {
  const ReaderPage({required this.noteId, super.key});

  final String noteId;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final _scrollController = ScrollController();

  ReaderSettings _settings = const ReaderSettings();
  bool _chromeVisible = true;
  bool _summaryExpanded = true;

  Note? _note;
  NoteSummary? _summary;
  StreamSubscription<NoteSummary?>? _summarySub;

  /// 缓存仓储引用：dispose() 阶段不能再安全地做 context 查找
  /// （会触发 "Looking up a deactivated widget's ancestor" 断言）。
  NoteRepository? _repo;

  /// 本次阅读时长，累加到 note.readingSeconds
  final _readingStopwatch = Stopwatch();

  double _progress = 0;
  static const _progressSaveThreshold = 0.02;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _summarySub?.cancel();
    _persistProgress();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<NoteRepository>();
    _repo = repo;
    final note = await repo.byId(widget.noteId);
    if (!mounted || note == null) return;

    setState(() {
      _note = note;
      _progress = note.readingProgress;
    });
    _readingStopwatch.start();

    _summarySub = repo.watchLatestSummary(widget.noteId).listen((s) {
      if (mounted) setState(() => _summary = s);
    });

    // 恢复上次阅读位置：等首帧布局完成后再跳转，否则 maxScrollExtent 还是 0
    if (note.readingProgress > 0.01) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final target =
            _scrollController.position.maxScrollExtent * note.readingProgress;
        _scrollController.jumpTo(
          target.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      });
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final next = max <= 0 ? 1.0 : (_scrollController.offset / max).clamp(0.0, 1.0);
    if ((next - _progress).abs() > _progressSaveThreshold) {
      _progress = next;
      _persistProgress();
    }
  }

  void _persistProgress() {
    final note = _note;
    final repo = _repo;
    if (note == null || repo == null) return;

    final totalSeconds =
        note.readingSeconds + _readingStopwatch.elapsed.inSeconds;
    // 写入后重置计时，避免同一段时长被重复累加
    _readingStopwatch
      ..reset()
      ..start();

    repo.saveReadingProgress(widget.noteId, _progress, totalSeconds);
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    if (note == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final content = note.content.trim();

    return Scaffold(
      backgroundColor: _settings.background,
      body: Stack(
        children: [
          GestureDetector(
            // 点正文中间区域切换 chrome 显隐，符合阅读类 App 的通用手势
            onTap: () => setState(() => _chromeVisible = !_chromeVisible),
            behavior: HitTestBehavior.translucent,
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(20, 72, 20, 120),
              children: [
                if (_summary != null && _summary!.oneLine.isNotEmpty)
                  _SummaryHeader(
                    summary: _summary!,
                    settings: _settings,
                    expanded: _summaryExpanded,
                    onToggle: () =>
                        setState(() => _summaryExpanded = !_summaryExpanded),
                  ),
                if (_summary != null && _summary!.oneLine.isNotEmpty)
                  const SizedBox(height: 28),
                if (content.isEmpty)
                  Text(
                    '（这篇笔记还没有正文）',
                    style: TextStyle(color: _settings.secondary, fontSize: 15),
                  )
                else
                  MarkdownBody(
                    data: content,
                    selectable: true,
                    styleSheet: _markdownStyle(),
                  ),
                const SizedBox(height: 48),
                Center(
                  child: Text(
                    '—— 完 ——',
                    style: TextStyle(color: _settings.secondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (_chromeVisible) ...[
            _TopBar(
              title: note.title.trim().isEmpty ? '无标题' : note.title.trim(),
              settings: _settings,
              wordCount: note.wordCount,
              onBack: () => Navigator.pop(context),
              onChangeSettings: (s) => setState(() => _settings = s),
            ),
            _ProgressIndicator(progress: _progress),
          ],
        ],
      ),
    );
  }

  MarkdownStyleSheet _markdownStyle() {
    final fg = _settings.foreground;
    final base = TextStyle(
      color: fg,
      fontSize: _settings.fontSize,
      height: _settings.lineHeight,
    );
    return MarkdownStyleSheet(
      p: base,
      h1: base.copyWith(fontSize: _settings.fontSize + 9, fontWeight: FontWeight.w700),
      h2: base.copyWith(fontSize: _settings.fontSize + 5, fontWeight: FontWeight.w700),
      h3: base.copyWith(fontSize: _settings.fontSize + 2, fontWeight: FontWeight.w600),
      listBullet: base,
      strong: base.copyWith(fontWeight: FontWeight.w700),
      em: base.copyWith(fontStyle: FontStyle.italic),
      blockquote: base.copyWith(color: _settings.secondary),
      blockquoteDecoration: BoxDecoration(
        color: fg.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      blockquotePadding: const EdgeInsets.all(12),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: _settings.fontSize - 2,
        backgroundColor: fg.withValues(alpha: 0.07),
        color: fg,
      ),
      codeblockDecoration: BoxDecoration(
        color: fg.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: fg.withValues(alpha: 0.15))),
      ),
      a: base.copyWith(
        decoration: TextDecoration.underline,
        color: fg,
      ),
    );
  }
}

/// L2：结构化速读头部 —— AI 摘要 + 要点，可折叠
class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.summary,
    required this.settings,
    required this.expanded,
    required this.onToggle,
  });

  final NoteSummary summary;
  final ReaderSettings settings;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final bullets = parseJsonStringList(summary.bullets);
    final fg = settings.foreground;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fg.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 15, color: settings.secondary),
                const SizedBox(width: 6),
                Text(
                  'AI 摘要',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.1,
                    color: settings.secondary,
                  ),
                ),
                const Spacer(),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: settings.secondary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            summary.oneLine,
            style: TextStyle(
              color: fg,
              fontSize: settings.fontSize + 1,
              height: 1.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (expanded && bullets.isNotEmpty) ...[
            const SizedBox(height: 14),
            ...bullets.map(
              (b) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: settings.secondary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        b,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.85),
                          fontSize: settings.fontSize - 2,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.settings,
    required this.wordCount,
    required this.onBack,
    required this.onChangeSettings,
  });

  final String title;
  final ReaderSettings settings;
  final int wordCount;
  final VoidCallback onBack;
  final ValueChanged<ReaderSettings> onChangeSettings;

  @override
  Widget build(BuildContext context) {
    final fg = settings.foreground;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: settings.background.withValues(alpha: 0.94),
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
        child: Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: Icon(Icons.arrow_back, color: fg),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '$wordCount 字 · 约 ${TextUtils.formatDuration(TextUtils.estimatedReadingTime(wordCount))}',
                    style: TextStyle(color: settings.secondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '阅读设置',
              onPressed: () => _showSettings(context),
              icon: Icon(Icons.text_fields, color: fg),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ReaderSettingsSheet(
        initial: settings,
        onChanged: onChangeSettings,
      ),
    );
  }
}

class _ReaderSettingsSheet extends StatefulWidget {
  const _ReaderSettingsSheet({required this.initial, required this.onChanged});

  final ReaderSettings initial;
  final ValueChanged<ReaderSettings> onChanged;

  @override
  State<_ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<_ReaderSettingsSheet> {
  late ReaderSettings _s = widget.initial;

  void _update(ReaderSettings next) {
    setState(() => _s = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('字号', style: Theme.of(context).textTheme.titleSmall),
            Row(
              children: [
                const Icon(Icons.text_decrease, size: 18),
                Expanded(
                  child: Slider(
                    value: _s.fontSize,
                    min: 13,
                    max: 26,
                    divisions: 13,
                    label: _s.fontSize.round().toString(),
                    onChanged: (v) => _update(_s.copyWith(fontSize: v)),
                  ),
                ),
                const Icon(Icons.text_increase, size: 20),
              ],
            ),
            Text('行距', style: Theme.of(context).textTheme.titleSmall),
            Slider(
              value: _s.lineHeight,
              min: 1.3,
              max: 2.4,
              divisions: 11,
              label: _s.lineHeight.toStringAsFixed(1),
              onChanged: (v) => _update(_s.copyWith(lineHeight: v)),
            ),
            const SizedBox(height: 4),
            Text('背景', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: ReaderThemeMode.values.map((m) {
                final selected = _s.mode == m;
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ChoiceChip(
                    label: Text(switch (m) {
                      ReaderThemeMode.light => '日间',
                      ReaderThemeMode.sepia => '护眼',
                      ReaderThemeMode.dark => '夜间',
                    }),
                    selected: selected,
                    onSelected: (_) => _update(_s.copyWith(mode: m)),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressIndicator extends StatelessWidget {
  const _ProgressIndicator({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 56,
      left: 0,
      right: 0,
      child: LinearProgressIndicator(
        value: progress,
        minHeight: 2,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}
