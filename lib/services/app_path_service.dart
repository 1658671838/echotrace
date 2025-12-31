import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'config_service.dart';

/// 应用路径服务：统一解析可配置的文档目录
class AppPathService {
  static String? _cachedDocumentsPath;
  static String? _cachedCustomDocumentsPath;

  static Future<String> getDocumentsPath({ConfigService? configService}) async {
    final config = configService ?? ConfigService();
    final custom = (await config.getDocumentsPath())?.trim();
    if (custom != null && custom.isNotEmpty) {
      if (_cachedCustomDocumentsPath != custom) {
        _cachedCustomDocumentsPath = custom;
        _cachedDocumentsPath = custom;
      }
      return custom;
    }

    if (_cachedDocumentsPath != null && _cachedCustomDocumentsPath == null) {
      return _cachedDocumentsPath!;
    }

    final docs = await getApplicationDocumentsDirectory();
    _cachedDocumentsPath = docs.path;
    _cachedCustomDocumentsPath = null;
    return docs.path;
  }

  static Future<String> getSystemDocumentsPath() async {
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  static Future<Directory> getDocumentsDirectory({
    ConfigService? configService,
  }) async {
    final path = await getDocumentsPath(configService: configService);
    return Directory(path);
  }

  static void setCustomDocumentsPath(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      clearCache();
      return;
    }
    _cachedDocumentsPath = trimmed;
    _cachedCustomDocumentsPath = trimmed;
  }

  static void clearCache() {
    _cachedDocumentsPath = null;
    _cachedCustomDocumentsPath = null;
  }
}
