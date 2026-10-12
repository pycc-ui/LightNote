import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/db/models.dart';
import '../../../../core/theme/dimens.dart';
import '../../../../core/widgets/log_bar.dart';
import '../data/feed_repository.dart';
import '../data/note_repository.dart';
import 'feed_detail_page.dart';
import 'feed_source_page.dart';
import 'widgets/feed_card.dart';

/// 轻笔记页 —— **AI 生成的灵感卡片流**。
///
/// ## 这里的「轻笔记」是什么
///
/// 它是 **AI 从你的笔记库素材里长出来的新内容**——"野生的"笔记，
/// 不是你已有笔记的另一种展示。卡片上只有一句有钩子的标题，
/// 点进去看 AI 写的全文。
///
/// 看到喜欢的就点「加入我的轻笔记」把它收下，成为一条真正的笔记
/// （未归档状态，之后可以归到某个笔记库）。
///
/// 与「我的轻笔记」的区别要分清：
///   · **轻笔记**（本页）= AI 生成的内容，看完可以收下，也可以直接走掉
///   · **我的轻笔记**（笔记库页的区块）= 已经收下、但还没归档的笔记
///
/// ## 生成策略：后台备 6 张、一屏 3 张
///
/// 池子里常备 [kFeedPoolTarget] 张，一屏取 [kFeedBatchSize] 张。
/// 取完立刻在后台补，所以**下拉刷新通常是瞬间出内容**，不用等 AI。
///
/// 生成结果**不落库**：收下才写成笔记。所以杀掉进程后没收下的那批
/// 就没了，下次会重新生成（内容不同）。
class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  @override
  State<InboxPage> createState() => _InboxPageState();
}

enum _FeedPhase { loading, ready, noSource, noMaterial, error }

/// 一屏里的一张卡片。
///
/// "已加入"不存成字段，而是**按内容从数据库实时推导**：收下后我们记住写出的
/// 笔记 id（[noteId]），是否"已加入"由 [`_InboxPageState._unfiledById`] 里还能
/// 不能找到它来决定。
///
/// 不能记成 `_Card` 上的一个 `added` 布尔值：那只是本页面的内存状态，
/// 用户跑到笔记库页把那条笔记删了，卡片这边完全不知道，还显示着「已加入」，
/// 再点也没反应。按数据库推导的话数据库变了两边一起变，不存在状态不同步。
class _Card {
  const _Card({required this.draft, this.noteId});

  final FeedDraft draft;

  /// 收下后写出的那条笔记的 id。
  ///
  /// 为 null 有两种情况：还没收下；或者收下的是上次会话建的，
  /// 这次会话不知道 id（那时靠内容指纹重新认出来，见 [_fingerprint]）。
  final String? noteId;

  _Card copyWith({String? noteId}) =>
      _Card(draft: draft, noteId: noteId ?? this.noteId);
}

/// 卡片与它对应的笔记之间的**内容指纹**。
///
/// 卡片本身不落库，所以"这张卡片对应哪条笔记"只能靠内容认。
/// 用标题+正文拼指纹：这两样都由 AI 一次生成，重复概率极低；
/// 而且只要笔记没被编辑过，指纹就稳定。
///
/// 用户在笔记库里改了内容就会认不出来（卡片会退回「加入」状态）。
/// 这是**可接受的**：内容都改了，把它当成另一条来收下也说得通；
/// 换成让用户去手工关联，代价大得多。
String _fingerprint(String title, String body) =>
    '${title.trim()}\u0000${body.trim()}';


class _InboxPageState extends State<InboxPage> {
  _FeedPhase _phase = _FeedPhase.loading;
  List<_Card> _cards = const [];

  // ⚠️ 这里**故意不缓存来源**。
  //
  // 缓存的话（比如 `initState` 里解析一次存下来、`takeBatch` 一直用它）会踩一个坑：
  // 三个 tab 是 `IndexedStack` 保活的，切标签不重建页面、`initState` 不再触发 ——
  // 于是用户在笔记库页**新建的笔记库永远进不了这次会话的来源**，要重启 App 才对。
  //
  // 所以来源由 `FeedRepository.resolveSource()` **每次现算**，
  // 页面只在"判断要不要显示引导"时就地取一次，用完即弃。
  String? _error;

  /// **当前「我的轻笔记」里的笔记**，指纹 → 笔记。
  ///
  /// 这是"卡片收下没有"的**唯一事实来源**。它来自数据库的实时流，
  /// 所以无论用户在哪边操作（收下 / 在笔记库页删除 / 在编辑页清空），
  /// 卡片状态都会跟着变。
  Map<String, Note> _unfiledByFingerprint = const {};

  /// 这张卡片对应的那条笔记（认出则返回，否则 null）。
  ///
  /// 先按指纹认；认不出再看 [\_Card.noteId]（同一个会话里刚收下的，
  /// 内容可能已经被用户在编辑页改过，但 id 我们还记着）。
  Note? _noteForCard(_Card card) {
    final byPrint = _unfiledByFingerprint[
        _fingerprint(card.draft.title, card.draft.body)];
    if (byPrint != null) return byPrint;

    final id = card.noteId;
    if (id != null) {
      for (final n in _unfiledByFingerprint.values) {
        if (n.id == id) return n;
      }
    }
    return null;
  }

  /// 卡片是否处于"已加入"状态——**从数据库推导，不是记在内存里**。
  bool _isAdded(_Card card) => _noteForCard(card) != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// 收到一批未归档笔记时更新推导依据。
  ///
  /// 注意**不调 setState**：这个流就是在 build 里被订阅的，
  /// 数据变化本身会触发重建，这里只需要把最新数据存下来。
  void _onUnfiled(List<Note> notes) {
    _unfiledByFingerprint = {
      for (final n in notes) _fingerprint(n.title, n.content): n,
    };
  }

  // ==========================================================================
  // 数据
  // ==========================================================================

  Future<void> _bootstrap() async {
    final feed = context.read<FeedRepository>();
    try {
      // 来源每次**现算**（全部笔记库 − 用户排除的），所以新建的笔记库自动在内。
      // 这里取一次只是为了判断"用户一个来源都没选"时要显示引导；
      // 真正取素材时由 `takeBatch` / `warmUpIfNeeded` 自己再解析一遍，
      // 不存在"页面里那份来源过期了"的问题。
      final source = await feed.resolveSource();
      if (!mounted) return;
      if (source.isEmpty) {
        setState(() => _phase = _FeedPhase.noSource);
        return;
      }

      // 先把池子填好（含"上次留的 3 张"），再取第一屏。
      //
      // 预热内部已经把"后 3 张"存进 `feed_reserve` 表并留给下次。
      // 它失败会安静返回 false，页面照旧走 `takeBatch` 的按需生成，
      // 所以没配 Key 时不会卡住。
      await feed.warmUpIfNeeded();
      if (!mounted) return;

      // 首次进入是**替换**（first: true），下拉刷新才是前向追加
      await _loadBatch(first: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _FeedPhase.error;
        _error = '$e';
      });
    }
  }

  /// 取一屏卡片。池子有货时是瞬间的。
  ///
  /// 两种情况（`first` 区分，**这是刻意的设计**）：
  ///
  /// | 调用方 | first | 行为 |
  /// |---|---|---|
  /// | 首次进入 `_bootstrap` | `true` | **替换**：显示这一屏 3 张 |
  /// | 下拉刷新 `_refresh` | `false` | **前向追加**：新的 3 张插到列表**最前面** |
  ///
  /// 所以下拉刷新是**累积**的：3 张 → 6 张 → 9 张…，最新的一批在最上面。
  /// 这是"前向追加"的语义（来自提交 0962466），**不要改成替换**。
  ///
  /// 追加只由**下拉刷新**触发。不要再加一层"滚到底自动加载"：窗口重新布局
  /// 也会产生滚动通知，会被误当成用户滚到底，于是切后台回来卡片就自己往后追加。
  Future<void> _loadBatch({bool first = false}) async {
    final feed = context.read<FeedRepository>();
    try {
      // 不传来源：让仓储层现算，避免用到页面里那份可能过期的 `_source`
      final batch = await feed.takeBatch();
      if (!mounted) return;

      if (batch.isEmpty) {
        // 池子空且生成不出东西：多半是来源里没有可用素材
        setState(() => _phase = _FeedPhase.noMaterial);
        return;
      }
      final newCards = batch.map((d) => _Card(draft: d)).toList();
      setState(() {
        if (first) {
          _cards = newCards;                 // 首次进入：替换
        } else {
          // 下拉刷新：**前向追加**——新卡片插到最前面
          _cards = [...newCards, ..._cards];
        }
        _phase = _FeedPhase.ready;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // 已经有内容时失败不该把它清掉——那样用户会白等一场
      if (!first && _cards.isNotEmpty) {
        LogBar.error(context, '生成失败：$e');
        return;
      }
      setState(() {
        _phase = _FeedPhase.error;
        _error = '$e';
      });
    }
  }

  /// 下拉：换一批
  Future<void> _refresh() => _loadBatch();

  // ==========================================================================
  // 交互
  // ==========================================================================

  Future<void> _openDetail(_Card card, int index) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FeedDetailPage(draft: card.draft),
      ),
    );
    // 详情页里点了「加入我的轻笔记」。
    //
    // **不需要在这里改状态**：写库之后未归档笔记的流会推新数据，
    // `_isAdded` 自然变成 true。（手动置状态就会"和数据库对不上"。）
    if (result == true && mounted) {
      // 只为把 id 记下来（内容被改过时还能靠它认出这条）
      // 触发一次重建，让流的最新数据生效
      setState(() {});
    }
  }

  /// 收进「我的轻笔记」：写一条真正的未归档笔记。
  Future<void> _addToInbox(_Card card, int index) async {
    final notes = context.read<NoteRepository>();
    final note = await notes.createInbox(
      title: card.draft.title,
      content: card.draft.body,
    );
    if (!mounted) return;

    // 只记下 id。"已加入"由 [_isAdded] 从数据库推导。
    setState(() => _cards = [
          for (var i = 0; i < _cards.length; i++)
            i == index ? _cards[i].copyWith(noteId: note.id) : _cards[i],
        ]);
    LogBar.success(context, '已加入「我的轻笔记」');
  }

  /// 从「我的轻笔记」移出：删掉那张卡片对应的笔记。
  ///
  /// 这是 [`_addToInbox`] 的逆操作，也是"两边统一"的关键——
  /// 用户在这里移出之后，笔记库页的「我的轻笔记」里也会少一条。
  Future<void> _removeFromInbox(_Card card, int index) async {
    final note = _noteForCard(card);
    if (note == null) {
      // 理论上不该发生（按钮只在"已加入"时可点）。
      // 真发生了就刷新一下推导依据，让界面回到真实状态。
      if (mounted) setState(() {});
      return;
    }

    final notes = context.read<NoteRepository>();
    await notes.softDelete(note.id);
    if (!mounted) return;

    setState(() => _cards = [
          for (var i = 0; i < _cards.length; i++)
            i == index ? _cards[i].copyWith(noteId: null) : _cards[i],
        ]);
    LogBar.info(context, '已从「我的轻笔记」移出');
  }

  Future<void> _openSource() async {
    // 来源页自己会去要「有效来源」当初始勾选，所以这里不再把 `_source` 传进去 ——
    // 传进去的可能是旧值（比如刚新建的库还不在里面），
    // 会让用户看到"这个库没勾上"的假状态，一保存就把它当成用户的选择写下去。
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const FeedSourcePage()),
    );
    if (changed != true || !mounted) return;

    final feed = context.read<FeedRepository>();

    // ① 只丢掉"数据引擎里那批从旧来源生成的池子"。
    //    它留着的话，下次取卡片会拿到旧来源的内容，用户会以为选择没生效。
    feed.clearPool();

    // ② **UI 上已展示的卡片保留。**
    //    用户只是改了个设置，回来还能看到刚才那几张，不该被清空。
    //
    // ③ 重新解析一次，判断"用户是不是把来源全取消了"。
    //    取素材本身不依赖它（`takeBatch` 自己会现算），但**引导文案依赖它**：
    //    全取消时该说"还没选素材来源"，而不是"没有可用素材"。
    final after = await feed.resolveSource();
    if (!mounted) return;
    if (after.isEmpty) {
      setState(() => _phase = _FeedPhase.noSource);
      return;
    }

    // ④ 只有"本来就没卡片"时才立刻取一屏。
    //    否则用户改完来源回来面对的是一片空白：未选来源 / 无素材 / 出错
    //    这几种状态下列表是空的，没有卡片可留，也不方便下拉。
    //    有卡片时什么都不做——等用户自己下拉。
    if (_cards.isEmpty) {
      setState(() => _phase = _FeedPhase.loading);
      await _loadBatch(first: true);
    }
  }

  // ==========================================================================
  // 渲染
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('轻笔记'),
        actions: [
          IconButton(
            tooltip: '选择素材来源',
            onPressed: _openSource,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      // 订阅「我的轻笔记」，让卡片上的"已加入"始终等于数据库的真相。
      //
      // 这个流一变（收下 / 在笔记库页删除 / 编辑页清空 / 从笔记库移回），
      // 卡片状态就跟着变。状态记在页面内存里的话，从笔记库删掉之后这边还会
      // 显示「已加入」——两边对不上。
      body: StreamBuilder<List<Note>>(
        stream: context.read<NoteRepository>().watchUnfiled(),
        builder: (context, snap) {
          // 有数据就更新推导依据。**不 setState**：流变化本身会重建。
          if (snap.hasData) _onUnfiled(snap.data!);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: _buildBody(),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _FeedPhase.loading:
        return const _FeedSkeleton();
      case _FeedPhase.error:
        return _FeedMessage(
          icon: Icons.error_outline,
          title: '生成失败',
          detail: _error,
          actionLabel: '重试',
          onAction: () {
            setState(() => _phase = _FeedPhase.loading);
            _bootstrap();
          },
        );
      case _FeedPhase.noSource:
        return _FeedMessage(
          icon: Icons.filter_alt_outlined,
          title: '还没有选择素材来源',
          detail: '选几个笔记库，AI 会从里面长出新的轻笔记。',
          actionLabel: '选择笔记库',
          onAction: _openSource,
        );
      case _FeedPhase.noMaterial:
        return _FeedMessage(
          icon: Icons.description_outlined,
          title: '选中的来源没有可用素材',
          detail: 'AI 需要有正文的笔记才能生成。先去笔记库写几条，'
              '或者换一批来源。',
          actionLabel: '换个来源',
          onAction: _openSource,
        );
      case _FeedPhase.ready:
        // 列表**只替换，不追加**。下拉刷新靠 RefreshIndicator 的那个圆圈
        // （见外层），没有上拉加载，所以列表不会自己增长。
        return ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          itemCount: _cards.length,
          separatorBuilder: (_, __) => const SizedBox(height: kFeedCardGap),
          itemBuilder: (context, i) {
            final card = _cards[i];
            return _FeedCardHost(
              card: card,
              // "已加入"从数据库推导，不读内存里记的状态
              added: _isAdded(card),
              onTap: () => _openDetail(card, i),
              onAdd: () => _addToInbox(card, i),
              onRemove: () => _removeFromInbox(card, i),
            );
          },
        );
    }
  }
}

/// 把 [_Card] 适配到 [FeedCard]（避免 UI 组件依赖内部状态类）。
class _FeedCardHost extends StatelessWidget {
  const _FeedCardHost({
    required this.card,
    required this.added,
    required this.onTap,
    required this.onAdd,
    required this.onRemove,
  });

  final _Card card;
  final bool added;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return FeedCard(
      title: card.draft.title,
      tag: card.draft.displayTag,
      addedToInbox: added,
      onTap: onTap,
      onAddToInbox: onAdd,
      onRemoveFromInbox: onRemove,
    );
  }
}

/// 首次加载的骨架屏。
///
/// 不用转圈：骨架屏能提前告诉用户"这里会出现卡片"，减少跳变感。
/// 而且生成要几秒，转圈会让人以为卡住了。
class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      itemCount: kFeedBatchSize,
      separatorBuilder: (_, __) => const SizedBox(height: kFeedCardGap),
      itemBuilder: (_, __) => Container(
        height: 200,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: AppRadius.cardRadius,
        ),
      ),
    );
  }
}

/// 空 / 错误 / 未选来源的统一提示。
///
/// 四种状态都要给**下一步动作**，不能只显示一句"暂无数据"。
class _FeedMessage extends StatelessWidget {
  const _FeedMessage({
    required this.icon,
    required this.title,
    this.detail,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // 必须可滚动，否则 RefreshIndicator 拉不动
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 44, color: scheme.onSurfaceVariant),
                  const SizedBox(height: AppSpacing.md),
                  Text(title, style: text.titleMedium),
                  if (detail != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      detail!,
                      textAlign: TextAlign.center,
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton.tonal(
                    onPressed: onAction,
                    child: Text(actionLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
