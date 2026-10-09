import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

/// 「选位置」这一层：把系统对话框的差异挡在这里。
///
/// 用 Flutter 官方的 file_selector（Windows 走 IFileDialog，Android 走 SAF），
/// 好处是**不需要申请任何存储权限**，用户通过系统界面亲自指定位置，
/// 这也是 Android 10+ 之后唯一被官方认可的外部文件访问方式。
class FileDialogs {
  FileDialogs._();

  /// 无状态，单例即可。放进 Provider 是为了让设置页不用直接 new，
  /// 将来要用假实现替换（测试、或换别的文件选择插件）时只改装配处。
  static final FileDialogs instance = FileDialogs._();

  static const _zipGroup = XTypeGroup(
    label: 'LightNote 备份包',
    extensions: <String>['zip'],
  );

  /// 让用户挑一个导出位置，返回完整文件路径；取消返回 null。
  Future<String?> pickExportTarget({String? suggestedName}) async {
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
    return path;
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
