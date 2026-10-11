import '../../features/note/data/notebook_repository.dart';
import '../../features/note/data/note_repository.dart';
import '../prefs/preferences_service.dart';

/// 首次启动时写入一组示例数据。
///
/// 为什么需要：一个空白的笔记 App 让人不知道从何下手。
/// 有了两条示例轻笔记和一个笔记库，用户立刻能看懂
/// 「速记 → 加入笔记库」这条核心流程，也方便在真机上验证界面。
///
/// 用 app_kv 表里的标记做幂等，而不是判断「笔记数为 0」——
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
    required NotebookRepository notebooks,
    required PreferencesService prefs,
  }) async {
    if (await prefs.isSeeded(seedKey)) return;

    // 已有数据（比如用户从旧版本升级上来）时只打标记，不灌示例
    final existing = await notes.allActive();
    if (existing.isEmpty) {
      final folder = await notebooks.create(name: '工作笔记');

      await notes.createInNotebook(
        folder.id,
        title: '欢迎使用 LightNote',
        content: '''
## 这是什么

一个纯本地的笔记 App。数据只存在你的设备上，不会自动上传。

## 三个地方

- **轻笔记**（第一个页签）：卡片流。从你选定的笔记库里抽笔记出来回顾，
  下拉换一批。适合碎片时间刷两眼，不用先想"我要找哪篇"。
  看到喜欢的卡片，点「加入我的轻笔记」收下；
  之后在编辑页把它归档到你想要的笔记库。
- **笔记库**：笔记库 + 未归档的轻笔记。点右下角 + 随手记一句，之后归档到笔记库。
  同一个位置**上方**还有个 AI 按钮，进去是对话式的 AI 助手：
  可以选工作区（限定参考范围）、按笔记提问，也可以直接下指令让它整理。
  只有你显式勾选的笔记会被发送。

## 数据放在哪

默认存在 App 私有目录里，系统相册和文件管理器都看不到。
要备份或搬设备，去**设置 → 存储与备份 → 导出备份包**，
那是一个标准 zip，里面就是完整的 SQLite 数据库文件。

## 一个建议

记的时候不要纠结分类，先把内容写下来；归档时再决定笔记库。
这样不会因为"该放哪"而卡住记录这件事本身。
''',
      );

      await notes.createInbox(
        title: '试试 AI 助手',
        content: '''
在「笔记库」页右下角、新建 `+` **上方**的 AI 按钮里可以：

- 选择工作区（限定参考范围）
- 设置思考强度（低最省，高最准）
- 用 + 勾选要参考的笔记 —— **只有你勾选的笔记会被发送**
- 输入指令，让它整理、提炼要点、起标题

它**也能改你的笔记**（新增、修改、删除），但每一步都会先弹一个确认层
让你看清"改前 / 改后"，你点了同意它才动。删除类的措辞是明确的
"删了就找不回来"。

## 卡片流会怎么用它

这条笔记还没归档，所以它会以「轻笔记」的身份出现在卡片流里。
点「轻笔记」页右上角的调节图标，可以决定哪些笔记库参与卡片流。

卡片上只有一个「加入 / 移出」开关；点开卡片能看全文。
同一段素材不会连着重复出现 —— 每次刷新取的是它的另一段。
''',
      );
    }

    await prefs.markSeeded(seedKey);
  }
}
