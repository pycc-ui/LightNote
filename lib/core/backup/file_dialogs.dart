import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 导出位置（分平台结果）。
///
/// Android 上没有可用的「保存到哪」对话框（原因见 [FileDialogs.pickExportTarget]），
/// 所以那边的目标是 App 自己缓存目录里的一个文件，写完之后必须再调
/// [FileDialogs.shareArchive] 把它交给系统分享面板。
class ExportTarget {
  const ExportTarget({required this.path, required this.viaShareSheet});

  /// 备份包要写到哪里（完整文件路径，含 .zip）。
  final String path;

  /// true：路径在 App 缓存目录里，用户看不到，写完要拉分享面板让他决定去处。
  /// false：用户已经在系统保存对话框里亲自挑好了位置。
  final bool viaShareSheet;
}

/// 「选位置」这一层：把系统对话框的差异挡在这里。
///
/// 用 Flutter 官方的 file_selector（Windows 走 IFileDialog，Android 走 SAF），
/// 好处是**不需要申请任何存储权限**，用户通过系统界面亲自指定位置，
/// 这也是 Android 10+ 之后唯一被官方认可的外部文件访问方式。
///
/// 例外只有一个：**Android 没有「保存到哪」对话框**，
/// 导出那条路要分平台处理，见 [pickExportTarget]。
class FileDialogs {
  FileDialogs._();

  /// 无状态，单例即可。放进 Provider 是为了让设置页不用直接 new，
  /// 将来要用假实现替换（测试、或换别的文件选择插件）时只改装配处。
  static final FileDialogs instance = FileDialogs._();

  static const _zipGroup = XTypeGroup(
    label: 'LightNote 备份包',
    extensions: <String>['zip'],
  );

  /// 让用户挑一个导出位置；取消返回 null。
  ///
  /// 这里必须分平台，因为「让用户选保存到哪」在两个平台上的能力完全不同：
  ///
  /// * **Windows / macOS / Linux**：`getSaveLocation` 有真实现
  ///   （Windows 走 IFileDialog），用户能直接选目录和文件名，返回完整路径。
  /// * **Android**：**没有保存对话框**。`file_selector_android` 只实现了
  ///   `getDirectoryPath`，基类于是退回 `getSavePath`，那个同样没实现，
  ///   直接抛 `UnimplementedError: getSavePath() has not been implemented.`
  ///   ——用户看到的「打开保存对话框失败」就是这么来的，而且**只有 Android 会踩**。
  ///   所以 Android 改走：备份包写进 App 自己的缓存目录
  ///   （`getTemporaryDirectory()` 属于 App 私有空间，仍然不需要任何存储权限），
  ///   写完再由 [shareArchive] 拉起系统分享面板，让用户在那里选
  ///   「保存到文件 / 发微信 / 发网盘」。
  ///
  /// 返回 null 只可能来自保存对话框被取消，也就是只有桌面平台会返回 null；
  /// Android 不弹对话框，永远有目标。
  Future<ExportTarget?> pickExportTarget({String? suggestedName}) async {
    if (!saveDialogIsAvailable) {
      final dir = await getTemporaryDirectory();
      return ExportTarget(
        path: p.join(dir.path, suggestedName ?? 'LightNote-backup.zip'),
        viaShareSheet: true,
      );
    }

    final location = await getSaveLocation(
      acceptedTypeGroups: const [_zipGroup],
      suggestedName: suggestedName ?? 'LightNote-backup.zip',
      confirmButtonText: '导出到此处',
    );
    if (location == null) return null;
    var path = location.path;
    // 有些平台不会自动补扩展名，用户敲了 "我的备份" 就会存成没有后缀的文件，
    // 双击打不开、以后也认不出来。这里统一补 .zip。
    if (!path.toLowerCase().endsWith('.zip')) path = '$path.zip';
    return ExportTarget(path: path, viaShareSheet: false);
  }

  /// 拉起系统分享面板，把已经写好的备份包交给用户处理
  /// （Android 导出流程的最后一步）。用户没选去处也不算失败，见下方注释。
  ///
  /// 关于 FileProvider：**我们这边不需要做任何配置**。share_plus 12.0.2 的
  /// `android/src/main/AndroidManifest.xml` 自带
  /// `ShareFileProvider`（authority `${applicationId}.flutter.share_provider`）
  /// 和 `res/xml/flutter_share_file_paths.xml`，随 manifest 合并进 App；
  /// 分享时原生侧（`Share.kt`）先把文件复制进 `<cacheDir>/share_plus/`，
  /// 再用这个 provider 授权给接收方。所以既不用改 AndroidManifest.xml，
  /// 也不用自己加 provider_paths.xml。
  ///
  /// ⚠️ 反过来说：**不要把备份包直接写进 `<cacheDir>/share_plus/`**。
  /// `Share.kt` 每次分享前都先清空那个目录（`clearShareCacheFolder()`），
  /// 放那里的文件会被删掉，插件自己也把它当错误拒绝（抛 IOException）。
  /// 我们的落点是缓存目录本身（`getTemporaryDirectory()`），不在被清范围内。
  Future<void> shareArchive({required String path, String? title}) async {
    await SharePlus.instance.share(
      ShareParams(
        // 只发文件、不附带 text：文件+文字混着发时各家 App 的支持程度不一致
        // （有的只认文件、有的只认文字），这里不需要冒这个险。
        files: [XFile(path)],
        title: title,
      ),
    );
    // 返回的 ShareResult 故意不看：
    //   * 用户在分享面板上直接关掉（dismissed）**不等于备份失败**——
    //     包已经生成，而且还有私有目录那份留档；
    //   * Android 本来就只区分「选了某个应用 / 没选」，拿不到更细的结果。
    // 所以不根据它改写提示文案。
  }

  /// 让用户挑一个要导入的备份包，返回文件路径；取消返回 null。
  Future<String?> pickArchiveToImport() async {
    final file = await openFile(
      acceptedTypeGroups: const [_zipGroup],
      confirmButtonText: '选择这个备份',
    );
    return file?.path;
  }

  /// 让用户挑一个目录作为工作目录。
  ///
  /// 返回 null 表示取消，也包含"当前平台给不出文件系统路径"的情况
  /// （Android 的 SAF 目录可能只返回 content:// URI，Dart 的 dart:io
  /// 无法直接写这种路径）。调用方要用 [describeDirectorySupport] 给出提示。
  Future<String?> pickWorkingDirectory({String? initialDirectory}) async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: initialDirectory,
        confirmButtonText: '使用这个目录',
      );
      if (path == null) return null;
      if (!_looksLikeFilesystemPath(path)) return null;
      return p.normalize(path);
    } catch (_) {
      return null;
    }
  }

  /// 「保存到哪」对话框只有桌面三平台有实现（原因见 [pickExportTarget]）。
  static bool get saveDialogIsAvailable =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 目录选择在部分平台（Android SAF、Web）拿不到可写的文件系统路径。
  static bool get directoryPickerIsReliable =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 形如 `content://...` 或 `/document/...` 的是 SAF URI，不是文件路径。
  static bool _looksLikeFilesystemPath(String path) {
    final lower = path.toLowerCase();
    if (lower.startsWith('content://')) return false;
    if (lower.startsWith('file://')) return true;
    return p.isAbsolute(path);
  }
}
