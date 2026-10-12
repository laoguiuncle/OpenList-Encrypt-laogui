import 'package:shared_preferences/shared_preferences.dart';

/// 「设置加密页为首页」开关的持久化（纯 Dart，使用 SharedPreferences）。
///
/// 打开 → 「网页」标签加载加密页（5344）；
/// 关闭 → 「网页」标签加载普通网页（5244）。
class EncryptHomePref {
  static const String key = 'encrypt_page_as_home';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}
