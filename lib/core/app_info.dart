/// App 身份信息的**唯一来源**。
///
/// 为什么要有这个文件：
///   窗口标题在 windows/runner/main.cpp，版本信息在 Runner.rc，
///   Android 在 AndroidManifest.xml，UI 在 settings_page.dart。
///   改一次名字要动四个地方，漏一个就会出现"任务栏叫一个名、关于页叫另一个名"。
///   把 Dart 侧收敛到这里，至少保证 UI 与提示文案不会各说各话。
///
/// 本项目的命名例外：产品名用英文 **LightNote**，其余一切（代码标识、
/// 包名、数据库文件名、目录名）保持原有的 `smart_notes` / `qing_notes` /
/// `轻笔记`，不做重命名——renaming 数据库文件或包名会让老用户的数据"消失"。
library;

/// 产品名（界面展示用）
const kAppDisplayName = 'LightNote';

/// 界面里需要中文全称时用这个
const kAppDisplayNameZh = 'LightNote 轻笔记';

/// 版本号。改这里时**必须同步改** pubspec.yaml 的 version，
/// 以及 windows/runner/Runner.rc 里的版本信息（构建脚本不会自动同步）。
const kAppVersion = '1.0.0';

/// 包名 / applicationId
const kAppPackageId = 'com.example.smart_notes';
