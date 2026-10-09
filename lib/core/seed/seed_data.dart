import '../../features/folders/data/folder_repository.dart';
import '../../features/notes/data/note_repository.dart';
import '../../services/preferences_service.dart';

/// 首次启动时写入一组示例数据。
///
/// 为什么需要：一个空白的笔记 App 让人不知道从何下手。
/// 有了两条示例轻笔记和一个目录，用户立刻能看懂
/// 「速记 → 加入笔记库」这条核心流程，也方便在真机上验证界面。
///
/// 用 settings 表里的标记做幂等，而不是判断「笔记数为 0」——
/// 否则用户主动清空所有笔记后重启，示例数据又会被灌回来。
///
/// 依赖**显式传入**而不是接收 BuildContext：
/// 早期版本写成 `ensureSeeded(BuildContext, ...)` 并在调用处传 `context.read()`，
/// 而不带类型参数的 `context.read()` 取的是 `BuildContext` 本身，
/// 于是运行时抛 ProviderNotFoundException。显式传依赖能从根本上避免这类错误，
/// 也让这个函数不依赖 widget 树、可被测试直接调用。
class SeedData {
  SeedData._();

  static const seedKey = 'seed_welcome_v1';

  static Future<void> ensureSeeded({
    required NoteRepository notes,
    required FolderRepository folders,
    required PreferencesService prefs,
  }) async {
    if (await prefs.isSeeded(seedKey)) return;

    // 已有数据（比如用户从旧版本升级上来）时只打标记，不灌示例
    final existing = await notes.allActive();
    if (existing.isEmpty) {
      final folder = await folders.create(name: '工作笔记');

      await notes.createInFolder(
        folder.id,
        title: '欢迎使用 LightNote',
        content: '''
## 这是什么

一个纯本地的笔记 App。数据只存在你的设备上，不会自动上传。

## 核心流程

1. 在**轻笔记**页随手记下想法（速记，不需要先想标题和分类）
2. 想清楚归属后，点卡片上的「加入笔记库」，选一个目录
3. 「笔记库」页按目录管理正式笔记

## 数据放在哪

默认存在 App 私有目录里，系统相册和文件管理器都看不到。
要备份或搬设备，去**设置 → 导出备份包**，那是一个标准 zip，
里面就是完整的 SQLite 数据库文件。

## 一个建议

速记阶段不要纠结分类，先把内容写下来；归档时再决定目录。
这样不会因为"该放哪"而卡住记录这件事本身。
''',
      );

      await notes.createInbox(
        title: '试试 AI 助手',
        content: '''
在底部「AI」页可以：

- 选择工作区（限定参考范围）
- 设置思考强度（低最省，高最准）
- 用 + 勾选要参考的笔记 —— **只有你勾选的笔记会被发送**
- 输入指令，让 AI 帮你整理、提炼要点、起标题

注意：AI 没有直接改数据库的权限。它会给出变更建议，
由你确认后执行，避免它悄悄改坏你的笔记。
''',
      );
    }

    await prefs.markSeeded(seedKey);
  }
}
