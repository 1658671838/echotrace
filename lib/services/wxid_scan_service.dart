import 'dart:io';

import 'package:path/path.dart' as p;

/// 微信账号候选项
class WxidCandidate {
  const WxidCandidate({
    required this.wxid,
    required this.modified,
    required this.path,
  });

  final String wxid;
  final DateTime modified;
  final String path;
}

/// 通过文件扫描 wxid
class WxidScanService {
  /// 扫描可能的微信目录，返回候选列表（按修改时间倒序）
  Future<List<WxidCandidate>> scanWxids({
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('正在从路径扫描微信账号...');
    final roots = await _candidateRoots();
    final bestByWxid = <String, WxidCandidate>{};

    for (final root in roots) {
      onProgress?.call('检查目录: $root');
      final dir = Directory(root);
      if (!await dir.exists()) continue;

      await for (final entity in dir.list()) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        final normalized = _normalizeWxid(name);
        if (normalized == null) continue;

        final keyInfo = File(p.join(entity.path, 'key_info.dat'));
        final dbStorageDir = Directory(p.join(entity.path, 'db_storage'));

        // 没有关键文件或 db_storage 的目录忽略，避免误报
        if (!await dbStorageDir.exists() && !await keyInfo.exists()) {
          continue;
        }

        DateTime modified;
        if (await keyInfo.exists()) {
          modified = (await keyInfo.stat()).modified;
        } else {
          modified = (await entity.stat()).modified;
        }
        final candidate = WxidCandidate(
          wxid: normalized,
          modified: modified,
          path: entity.path,
        );

        final prev = bestByWxid[normalized];
        if (prev == null || candidate.modified.isAfter(prev.modified)) {
          bestByWxid[normalized] = candidate;
        }
      }
    }

    final candidates = bestByWxid.values.toList();
    candidates.sort((a, b) => b.modified.compareTo(a.modified));
    if (candidates.isEmpty) {
      onProgress?.call('未在路径中找到 wxid 目录');
    } else {
      onProgress?.call('找到 ${candidates.length} 个账号候选');
    }
    return candidates;
  }

  /// 返回优先的 WeChat 目录（xwechat/login 优先，否则 xwechat_files，否则 Documents/WeChat Files）
  Future<String?> findWeChatFilesRoot() async {
    final roots = await _candidateRoots();
    for (final root in roots) {
      if (await Directory(root).exists()) return root;
    }
    return null;
  }

  /// 组合可能的根目录
  Future<List<String>> _candidateRoots() async {
    if (!Platform.isWindows) return const [];
    final roots = <String>[];
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    if (userProfile.isNotEmpty) {
      // 微信4登录信息配置路径
      roots.add(p.join(userProfile, 'AppData', 'Roaming', 'Tencent', 'xwechat', 'login'));

      // 微信4的路径
      roots.add(p.join(userProfile, 'Documents', 'xwechat_files'));

      // 微信3的路径
      roots.add(p.join(userProfile, 'Documents', 'WeChat Files'));
    }
    return roots;
  }

  /// 纠正 wxid 目录名，去掉末尾的 _数字 后缀
  String? _normalizeWxid(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;

    // 兼容旧版目录：wxid_xxx 或 wxid_xxx_123 -> wxid_xxx
    final legacyMatch = RegExp(
      r'^(wxid_[a-z0-9]+)(?:_\d+)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (legacyMatch != null) {
      return legacyMatch.group(1);
    }

    // 其他账号名称直接返回原始目录名
    return trimmed;
  }
}
