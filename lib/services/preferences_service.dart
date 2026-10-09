import 'dart:convert';

import '../core/db/app_database.dart';

/// 搜索历史与轻量偏好。
///
/// 用数据库里的 key-value `settings` 表存，而不是引入 shared_preferences：
/// 少一个依赖、少一套异步初始化，且能和笔记数据一起进同一个备份/导出流程。
class PreferencesService {
  PreferencesService(this._db);

  final AppDatabase _db;

  static const _kSearchHistory = 'search_history';
  static const _kThemeMode = 'theme_mode';
  static const _kFontScale = 'editor_font_scale';
  static const _kAutoSave = 'editor_auto_save';
  static const _kExportMarkdownRecall = 'export_recall';

  static const maxSearchHistory = 20;

  // ---- 搜索历史 ----

  Future<List<String>> readSearchHistory() async {
    final raw = await _db.readSetting(_kSearchHistory);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList(growable: false);
      }
    } catch (_) {
      // 数据损坏时当作空历史，不要让搜索页直接崩掉
    }
    return const [];
  }

  Stream<List<String>> watchSearchHistory() {
    return _db.watchSetting(_kSearchHistory).map((raw) {
      if (raw == null || raw.trim().isEmpty) return const <String>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.map((e) => e.toString()).toList(growable: false);
        }
      } catch (_) {}
      return const <String>[];
    });
  }

  /// 写入一条历史：去重后置顶，超出上限截断
  Future<void> pushSearchHistory(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    final list = [...await readSearchHistory()];
    list.removeWhere((e) => e.toLowerCase() == k.toLowerCase());
    list.insert(0, k);
    if (list.length > maxSearchHistory) {
      list.removeRange(maxSearchHistory, list.length);
    }
    await _db.writeSetting(_kSearchHistory, jsonEncode(list));
  }

  Future<void> clearSearchHistory() => _db.deleteSetting(_kSearchHistory);

  // ---- 偏好 ----

  /// 主题：system / light / dark
  Future<String> readThemeMode() async =>
      (await _db.readSetting(_kThemeMode)) ?? 'system';

  Stream<String> watchThemeMode() =>
      _db.watchSetting(_kThemeMode).map((v) => v ?? 'system');

  Future<void> writeThemeMode(String mode) =>
      _db.writeSetting(_kThemeMode, mode);

  /// 编辑器字号倍数，1.0 为基准
  Future<double> readFontScale() async {
    final raw = await _db.readSetting(_kFontScale);
    return double.tryParse(raw ?? '') ?? 1.0;
  }

  Stream<double> watchFontScale() => _db
      .watchSetting(_kFontScale)
      .map((v) => double.tryParse(v ?? '') ?? 1.0);

  Future<void> writeFontScale(double scale) =>
      _db.writeSetting(_kFontScale, scale.toStringAsFixed(2));

  /// 自动保存开关
  Future<bool> readAutoSave() async =>
      (await _db.readSetting(_kAutoSave)) != 'false';

  Stream<bool> watchAutoSave() =>
      _db.watchSetting(_kAutoSave).map((v) => v != 'false');

  Future<void> writeAutoSave(bool enabled) =>
      _db.writeSetting(_kAutoSave, enabled.toString());

  /// 「导出 Markdown」是否需要提示一次位置说明
  Future<bool> readExportRecall() async =>
      (await _db.readSetting(_kExportMarkdownRecall)) != 'seen';

  Future<void> markExportRecallSeen() =>
      _db.writeSetting(_kExportMarkdownRecall, 'seen');

  // ---- 一次性任务的幂等标记 ----

  /// 判断某个一次性任务（如灌入示例数据）是否已执行过
  Future<bool> isSeeded(String key) async =>
      (await _db.readSetting('seeded_$key')) == 'true';

  Future<void> markSeeded(String key) =>
      _db.writeSetting('seeded_$key', 'true');
}
