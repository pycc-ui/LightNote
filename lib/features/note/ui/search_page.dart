import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/dimens.dart';
import '../../../core/prefs/preferences_service.dart';
import '../../../core/util/text_utils.dart';
import '../data/search_service.dart';
import '../domain/search_result.dart';
import 'note_editor_page.dart';

/// 搜索页（设计稿 §5.5 / 线框图 4.5）。
///
/// 实时搜索 + 关键词高亮 + 搜索历史。
///
/// 两种范围：
///   · 不传 [notebookId] → **全局搜索**，包含「我的轻笔记」里的未归档笔记
///     （笔记库页顶栏的搜索图标用这个）
///   · 传 [notebookId] → 只在该笔记库内搜
///     （笔记库详情页顶栏的搜索图标用这个）
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.notebookId, this.notebookName});

  /// 限定搜索范围；null 表示全局
  final String? notebookId;

  /// 用于提示"正在 XX 里搜索"
  final String? notebookName;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  Timer? _debounce;

  /// 已提交的关键词（防抖后写入，用于查询与高亮）
  String _query = '';

  /// 当前那次查询。null = 还没搜（显示历史）。
  ///
  /// 存 Future 而不是结果：`FutureBuilder` 只认**当前**这个 future，
  /// 旧查询晚回来也不会覆盖新结果（省掉一个手写的序号守卫）。
  Future<List<SearchResult>>? _results;

  @override
  void initState() {
    super.initState();
    // 进页面自动聚焦，符合「打开搜索就是为了打字」的预期
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // 不需要单独保存"正在输入的原文"：TextField 自己持有它，
    // 我们只关心防抖后提交的查询词 _query。
    _debounce?.cancel();
    // 防抖 250ms：中文输入法组字过程中会连续触发 onChanged，
    // 不防抖会对数据库发起大量无效查询
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
      _run();
      _remember(value);
    });
  }

  /// 发起查询（关键词没变就不重发，避免每次 setState 都重新搜一遍）。
  void _run() {
    final q = _query;
    if (q.isEmpty) {
      _results = null;
      return;
    }
    _results = context
        .read<SearchService>()
        .search(
      q,
      // 全局搜索（未指定库）→ 不限目录且含轻笔记；
      // 库内搜索 → 只这个库，**不含轻笔记**（在库里搜却搜出库外的会很怪）
      notebookIds: widget.notebookId == null ? null : [widget.notebookId!],
      includeUnfiled: widget.notebookId == null,
    );
  }

  Future<void> _remember(String value) async {
    if (value.trim().length < 2) return;
    await context.read<PreferencesService>().pushSearchHistory(value);
  }

  void _searchNow(String keyword) {
    _controller.text = keyword;
    _controller.selection =
        TextSelection.collapsed(offset: keyword.length);
    setState(() {
      _query = keyword.trim();
      _run();
    });
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.read<PreferencesService>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: widget.notebookId == null
                ? '搜索全部笔记…'
                : '在「${widget.notebookName ?? '此笔记库'}」内搜索…',
            prefixIcon: const Icon(Icons.search),
            border: InputBorder.none,
            filled: false,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
      body: _query.isEmpty
          ? _HistoryView(
              prefs: prefs,
              onPick: _searchNow,
            )
          : FutureBuilder<List<SearchResult>>(
              future: _results,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('搜索失败：${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = snapshot.data!;
                if (all.isEmpty) {
                  return _NoResult(keyword: _query);
                }
                // 结果分两类（设计稿 §6.2）：点进去的落点不一样 ——
                // 「笔记」看整篇，「笔记内容」直接定位到命中那一片。
                final byTitle =
                    all.where((r) => r.isTitleHit).toList(growable: false);
                final byChunk =
                    all.where((r) => !r.isTitleHit).toList(growable: false);

                return ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        AppSpacing.sm,
                        AppSpacing.md,
                        AppSpacing.xs,
                      ),
                      child: Text(
                        '找到 ${all.length} 条结果',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (byTitle.isNotEmpty) ...[
                      _SectionHeader(label: '笔记', count: byTitle.length),
                      for (final r in byTitle)
                        _ResultTile(
                          result: r,
                          keyword: _query,
                          onTap: () => _open(r),
                        ),
                    ],
                    if (byChunk.isNotEmpty) ...[
                      _SectionHeader(label: '笔记内容', count: byChunk.length),
                      for (final r in byChunk)
                        _ResultTile(
                          result: r,
                          keyword: _query,
                          onTap: () => _open(r),
                        ),
                    ],
                  ],
                );
              },
            ),
    );
  }

  /// 打开一条结果。
  ///
  /// 「笔记」和「笔记内容」都进**阅读**视图（用户是来找内容的，不是来改的），
  /// 区别只在「笔记内容」要多给一个片号，让它滚动到命中那一段。
  void _open(SearchResult r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          noteId: r.noteId,
          startInReading: true,
          initialChunk: r.chunkIndex,
        ),
      ),
    );
  }
}

/// 分类小标题（「笔记（2）」/「笔记内容（5）」）
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs + 2,
        AppSpacing.md,
        AppSpacing.xs + 2,
      ),
      child: Text(
        '$label（$count）',
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.keyword,
    required this.onTap,
  });

  final SearchResult result;
  final String keyword;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = result.title.trim().isEmpty ? '无标题' : result.title.trim();
    // 「笔记内容」要显示命中那一段的摘要与所属小节；
    // 「笔记」（标题命中）整篇相关，没有"哪一段"可言。
    final showSnippet = !result.isTitleHit;

    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: kMinListItemHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Highlighted(
              text: title,
              keyword: keyword,
              baseStyle: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
              highlightStyle: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
              maxLines: 1,
            ),
            if (showSnippet && result.heading.isNotEmpty) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(
                    Icons.subdirectory_arrow_right,
                    size: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      result.heading,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (showSnippet) ...[
              const SizedBox(height: 4),
              _Highlighted(
                text: result.snippet,
                keyword: keyword,
                baseStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                highlightStyle: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 关键词高亮文本
class _Highlighted extends StatelessWidget {
  const _Highlighted({
    required this.text,
    required this.keyword,
    required this.baseStyle,
    required this.highlightStyle,
    this.maxLines = 2,
  });

  final String text;
  final String keyword;
  final TextStyle? baseStyle;
  final TextStyle? highlightStyle;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final segments = HighlightUtils.split(text, keyword);
    return Text.rich(
      TextSpan(
        children: [
          for (final (part, hit) in segments)
            TextSpan(
              text: part,
              style: hit ? highlightStyle : baseStyle,
            ),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: baseStyle,
    );
  }
}

class _HistoryView extends StatelessWidget {
  const _HistoryView({required this.prefs, required this.onPick});

  final PreferencesService prefs;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<String>>(
      stream: prefs.watchSearchHistory(),
      builder: (context, snapshot) {
        final history = snapshot.data ?? const <String>[];
        if (history.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search, size: 48, color: theme.colorScheme.outline),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '输入关键词搜索标题和正文',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.sm,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  Text(
                    '搜索历史',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('清空搜索历史'),
                          content: const Text('将删除全部搜索历史记录。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await prefs.clearSearchHistory();
                    },
                    child: const Text('清空'),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final h in history)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.md),
                    child: ActionChip(
                      label: Text(h),
                      onPressed: () => onPick(h),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _NoResult extends StatelessWidget {
  const _NoResult({required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: AppSpacing.md),
            Text('没有找到相关笔记', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '「$keyword」没有匹配到任何标题或正文。\n'
              '当前是关键词匹配，不是语义搜索。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
