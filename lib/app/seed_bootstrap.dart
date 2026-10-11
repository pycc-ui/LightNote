import '../core/prefs/preferences_service.dart';
import '../core/seed/seed_data.dart';
import '../features/note/data/notebook_repository.dart';
import '../features/note/data/note_repository.dart';

/// 启动阶段写示例数据。
///
/// **为什么放在这里而不是某个页面**：示例数据以前只在 AI 页首次打开时写。
/// 轻笔记页改成消费流之后，它要"从库里抽出卡片"，而抽取依赖笔记库已存在——
/// 首屏是轻笔记页，那时示例数据还没写，于是：
///   · 页面看起来是空的
///   · 更糟的是"来源配置"把**空笔记库列表**记成了默认值（`[]`），
///     之后新建的笔记库要靠 [FeedRepository] 的自动补充逻辑才追回来
///
/// 示例数据是"开箱体验"的一部分，属于启动职责，不该挂在某个页面上。
///
/// 幂等由 [SeedData.ensureSeeded] 内部的 settings 标记保证，
/// 每次启动调用是安全的。
///
/// 失败不抛：示例数据写不进去不该挡住 App 启动，
/// 用户宁可看到一个空库，也不要看着启动页卡住。
class SeedBootstrap {
  SeedBootstrap._();

  static Future<void> run({
    required NoteRepository notes,
    required NotebookRepository notebooks,
    required PreferencesService prefs,
  }) async {
    try {
      await SeedData.ensureSeeded(
        notes: notes,
        notebooks: notebooks,
        prefs: prefs,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[LightNote] 示例数据写入失败（不影响启动）：$e');
    }
  }
}
