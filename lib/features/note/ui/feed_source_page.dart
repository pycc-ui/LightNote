import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/db/app_database.dart';
import '../../../../core/theme/dimens.dart';
import '../../../../core/widgets/log_bar.dart';
import '../data/feed_repository.dart';
import '../data/notebook_repository.dart';

/// 卡片流的**素材来源**选择页。
///
/// AI 从这些笔记库（外加可选的「我的轻笔记」）取素材，长出新的「轻笔记」。
///
/// 用全屏页而不是底部弹窗：要做多选 + 全选 + 一个开关，
/// 弹窗里塞这些太挤，且笔记库多了以后滚动区域会很别扭。
///
/// ## 初始勾选状态从哪来
///
/// **本页自己去问仓储要「有效来源」**（`FeedRepository.resolveSource()`），
/// 不从外面接收。原因：外层页面里那份 `_source` 可能是旧的 ——
/// 比如用户刚在笔记库页新建了一个库，外层还没刷新，传进来就会显示成
/// **"这个库没勾上"**，而它其实是生效的。用户一按保存就把这个假状态
/// 写成了"用户的选择"。
///
/// ## 返回值
///
/// `true`  = 选择**真的有变化**（外层据此丢掉旧池子重抽一批）
/// `false` = 用户没改（或按了恢复默认之前的返回键）—— **不写库**
///
/// "没改就不写"很重要：以前无条件写，于是用户只要打开这页点一下「保存」，
/// 哪怕一个字没动，也会被记成"用户接管了来源"，之后新建的笔记库
/// **永远不再自动加入**。
class FeedSourcePage extends StatefulWidget {
  const FeedSourcePage({super.key});

  @override
  State<FeedSourcePage> createState() => _FeedSourcePageState();
}

class _FeedSourcePageState extends State<FeedSourcePage> {
  Set<String> _selected = {};
  bool _includeUnfiled = true;
  bool _loading = true;
  List<Notebook> _notebooks = const [];

  /// 进来时的**有效来源**，用来判断"用户到底改没改"。
  FeedSource _initial = FeedSource.empty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final feed = context.read<FeedRepository>();
    final notebooks = context.read<NotebookRepository>();

    // 有效来源 = 当前全部笔记库 − 用户明确排除的。
    // 所以"没改过"时这里拿到的就是"全选 + 含我的轻笔记"，
    // 新建的库也已经在里面了。
    final resolved = await feed.resolveSource();
    final all = await notebooks.all();
    if (!mounted) return;

    setState(() {
      _initial = resolved;
      _selected = resolved.notebookIds.toSet();
      _includeUnfiled = resolved.includeUnfiled;
      _notebooks = all;
      _loading = false;
    });
  }

  bool get _allSelected =>
      _notebooks.isNotEmpty && _notebooks.every((f) => _selected.contains(f.id));

  /// 已经在默认状态：没排除任何笔记库，且包含「我的轻笔记」。
  bool get _atDefault =>
      _includeUnfiled && _notebooks.every((n) => _selected.contains(n.id));

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected = _notebooks.map((f) => f.id).toSet();
      }
    });
  }

  /// 两个来源是否等价。**按集合比**，别被顺序骗了。
  bool _sameAs(FeedSource a, FeedSource b) =>
      a.includeUnfiled == b.includeUnfiled &&
      setEquals(a.notebookIds.toSet(), b.notebookIds.toSet());

  Future<void> _save() async {
    final source = FeedSource(
      notebookIds: _selected.toList(growable: false),
      includeUnfiled: _includeUnfiled,
    );

    // 和进来时一致 → 用户什么都没改。**不写库**。
    // 这一点是"新建的笔记库默认勾选"能不能长期成立的关键：
    // 只要写下去，来源就从"自动"变成"用户钦定"，新库再也不会自动进来。
    if (_sameAs(source, _initial)) {
      Navigator.of(context).pop(false);
      return;
    }

    await context.read<FeedRepository>().writeSource(source);
    if (!mounted) return;
    if (source.isEmpty) {
      // 允许保存空选择——页面会显示"还没有选择素材来源"的引导。
      // 这里只提示一下，不阻止。
      LogBar.info(context, '没有选任何来源，卡片流会是空的');
    }
    Navigator.of(context).pop(true);
  }

  /// 恢复默认 = **清掉用户存的排除集**（不是"把当前全部存成用户选择"）。
  ///
  /// 两者的区别在以后才显现：后者等于用户表了态"我全都要"，
  /// 而清掉之后是"我从没表过态" —— 那才是默认态。
  Future<void> _resetToDefault() async {
    await context.read<FeedRepository>().resetSource();
    if (!mounted) return;
    LogBar.success(context, '已恢复默认来源');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('素材来源'),
        actions: [
          if (_notebooks.isNotEmpty)
            TextButton(
              onPressed: _toggleAll,
              child: Text(_allSelected ? '全不选' : '全选'),
            ),
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  child: Text(
                    '勾选作为素材的笔记库。AI 会从里面长出新内容。\n'
                    '以后新建的笔记库会**自动**加入，除非你在这里取消勾选。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),

                // ---- 未归档笔记开关 ----
                SwitchListTile(
                  value: _includeUnfiled,
                  onChanged: (v) => setState(() => _includeUnfiled = v),
                  title: const Text('包含我的轻笔记'),
                  subtitle: const Text('还没归档到任何笔记库的笔记，也拿来当素材'),
                  secondary: const Icon(Icons.bolt_outlined),
                ),

                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.xs,
                  ),
                  child: Text(
                    '笔记库',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),

                if (_notebooks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Column(
                      children: [
                        Icon(Icons.library_books_outlined,
                            size: 40, color: scheme.onSurfaceVariant),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          '还没有笔记库',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '去「笔记库」建一个笔记库，笔记就能按笔记库参与卡片流。',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                else
                  ..._buildNotebookTiles(),

                const Divider(height: 1),

                // ---- 恢复默认 ----
                //
                // 没有这个入口的话，用户只要取消勾选过任何一个库，
                // 就再也没有路回到"自动加入新库"的状态了。
                ListTile(
                  enabled: !_atDefault,
                  leading: const Icon(Icons.restart_alt),
                  title: const Text('恢复默认'),
                  subtitle: const Text('全部笔记库 + 我的轻笔记，之后新建的也会自动加入'),
                  onTap: _atDefault ? null : _resetToDefault,
                ),
              ],
            ),
    );
  }

  /// 笔记库列表。
  ///
  /// **平铺，不缩进。** 笔记库不能有子库（去掉了 `parent_id`），
  /// 所以这里不再需要递归遍历与层级缩进——原先那套"父目录勾选不级联
  /// 到子笔记库"的说明也随之作废：没有层，就不存在级联问题。
  List<Widget> _buildNotebookTiles() {
    final sorted = [..._notebooks]..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.name.compareTo(b.name);
      });

    return sorted.map((n) {
      return CheckboxListTile(
        value: _selected.contains(n.id),
        onChanged: (v) => setState(() {
          if (v == true) {
            _selected.add(n.id);
          } else {
            _selected.remove(n.id);
          }
        }),
        title: Text(n.name),
        secondary: const Icon(Icons.library_books_outlined),
        controlAffinity: ListTileControlAffinity.trailing,
      );
    }).toList(growable: false);
  }
}
