/// App 身份信息的唯一来源。
///
/// 为什么要有这个文件：窗口标题在 windows/runner/main.cpp，版本信息在
/// Runner.rc，Android 在 AndroidManifest.xml，UI 在 settings_page.dart。
/// 改一次名字要动四个地方，漏一个就会出现"任务栏叫一个名、关于页叫另一个名"。
/// 把 Dart 侧收敛到这里，至少保证 UI 与提示文案不会各说各话。
///
/// 命名现状：产品名（界面展示）用英文 LightNote，代码标识已统一为
/// `lightnote` —— Dart 包名 `lightnote`、Android 包名 / applicationId
/// `com.lightnote.app`、数据库文件名 `lightnote.sqlite`
/// （`core/db/database_location.dart` 的 `kDatabaseFileName`）。
///
/// 唯一仍然保留原名的是 Windows 可执行文件名 `smart_notes.exe`
/// （`windows/CMakeLists.txt` 的 `BINARY_NAME`）：本机构建脚手架与 `bin\`
/// 下的 shim 按这个名字找它，改名会断开编译通道，另案处理。
///
/// 注意：数据库文件名现在还没发布过正式版，改了没事；一旦发布就不能再改——
/// 老用户的库会留在旧名下变成孤儿。
library;

/// 产品名（界面展示用）
const kAppDisplayName = 'LightNote';

/// 界面里需要中文全称时用这个
const kAppDisplayNameZh = 'LightNote 轻笔记';

/// 版本号。改这里时必须同步改 pubspec.yaml 的 version，
/// 以及 windows/runner/Runner.rc 里的版本信息（构建脚本不会自动同步）。
const kAppVersion = '1.0.0';

/// 包名 / applicationId
const kAppPackageId = 'com.lightnote.app';
