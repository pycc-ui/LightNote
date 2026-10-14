import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API Key 与用户配置的安全存储。
///
/// 设计约束：
/// 1. API Key 只存设备钥匙串（Android Keystore / Windows DPAPI / macOS Keychain），
///    **绝不写进代码或日志，也不进备份包**。
/// 2. 非敏感配置（模型名、复习参数）走 SharedPreferences 会更轻，
///    但为了少一个依赖，这里统一走安全存储。
///
/// 为什么每个方法都要包 try/catch：
///   `flutter_secure_storage_windows` 把数据存在
///   `%APPDATA%\<公司名>\<产品名>\...json`。如果那个目录建不出来
///   （企业策略收紧 AppData、漫游配置损坏、受限令牌运行），
///   它会抛 PathAccessException。**这个异常会从 `AiRepository.init()` 和
///   设置页的 `_load()` 里冒出来，直接把页面打成红屏**——用户看到的是
///   "App 坏了"，而真实原因只是"存 Key 的地方没权限"。
///
///   所以这里的原则是：**读写失败一律降级为"没有配置"，绝不把异常抛给 UI**。
///   代价是用户在那种环境下无法持久化 API Key（本次运行内仍然可用，
///   见 [_memoryFallback]），但这个代价远小于整个设置页不可用。
class SecureStore {
  SecureStore._();

  static const _kApiKey = 'deepseek_api_key';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 安全存储不可用时的会话内兜底。
  ///
  /// 只对本进程有效：App 一关就没了。写入失败时至少让用户本次能正常用 AI，
  /// 而不是每点一次都重置。UI 上不需要区分——真正需要持久化的用户在
  /// 正常环境下不会走到这里。
  static final Map<String, String> _memoryFallback = {};

  /// 安全存储是否已经确认不可用。用于避免每次都去撞同一个异常。
  static bool _unavailable = false;

  static bool get isUnavailable => _unavailable;

  static Future<String?> _read(String key) async {
    if (!_unavailable) {
      try {
        return await _storage.read(key: key);
      } catch (e) {
        // 只在第一次失败时打日志，避免刷屏
        _unavailable = true;
        debugPrint('[LightNote] 安全存储不可用，改用会话内存储：$e');
      }
    }
    return _memoryFallback[key];
  }

  static Future<void> _write(String key, String value) async {
    if (!_unavailable) {
      try {
        await _storage.write(key: key, value: value);
        return;
      } catch (e) {
        _unavailable = true;
        debugPrint('[LightNote] 安全存储写入失败，改用会话内存储：$e');
      }
    }
    _memoryFallback[key] = value;
  }

  static Future<void> _delete(String key) async {
    _memoryFallback.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // 删不掉就是删不掉，但内存里的那份必须已经清掉了
    }
  }

  // ---- API Key ----

  static Future<String?> readApiKey() async {
    final v = await _read(_kApiKey);
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  static Future<void> writeApiKey(String key) => _write(_kApiKey, key.trim());

  static Future<void> deleteApiKey() => _delete(_kApiKey);
}
