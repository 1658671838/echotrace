import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/image_service.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/image_decrypt_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/logger_service.dart';


/// 图片消息组件 - 显示聊天中的图片
class ImageMessageWidget extends StatefulWidget {
  final Message message;
  final String sessionUsername;
  final bool isFromMe;

  const ImageMessageWidget({
    super.key,
    required this.message,
    required this.sessionUsername,
    this.isFromMe = false,
  });

  @override
  State<ImageMessageWidget> createState() => _ImageMessageWidgetState();
}

class _ImageMessageWidgetState extends State<ImageMessageWidget> {
  String? _imagePath;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isDecrypting = false;
  String? _statusMessage;
  String? _datName;
  String? _displayName;

  static final Map<String, String> _decryptedIndex = {};
  static bool _indexed = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    if (!mounted) return;

    try {
      _datName = widget.message.imageDatName;
      final appState = context.read<AppState>();
      final imageService = ImageService();
      // 预取会话展示名用于路径美化
      await _loadDisplayName(appState);

      // 每次加载都刷新索引，避免缓存不到新解密的图片（含 cache）
      _indexed = false;
      _decryptedIndex.clear();

      // 初始化图片服务
      final dataPath = appState.databaseService.currentDataPath;
      if (dataPath != null) {
        await imageService.init(dataPath);

        // 获取图片路径
        if (widget.message.imageMd5 != null) {
          final path = await imageService.getImagePath(
            widget.message.imageMd5!,
            widget.sessionUsername,
          );

          // 如果硬链表未命中，尝试已解密文件
          if (path == null) {
            final decodedPath =
                await _findDecryptedImageByName(_datName, refresh: true);
            _logDebugPaths(decodedPath);
            if (mounted) {
              setState(() {
                _imagePath = decodedPath;
                _isLoading = false;
                _hasError = decodedPath == null;
              });
            }
          } else if (mounted) {
            _logDebugPaths(path);
            setState(() {
              _imagePath = path;
              _isLoading = false;
              _hasError = false;
            });
          }
        } else {
          // 仅 packed_info_data 的情况
          final decodedPath =
              await _findDecryptedImageByName(_datName, refresh: true);
          _logDebugPaths(decodedPath);
          if (mounted) {
            setState(() {
              _imagePath = decodedPath;
              _isLoading = false;
              _hasError = decodedPath == null;
            });
          }
        }

        await imageService.dispose();
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
            _statusMessage = '未获取到数据目录，无法加载图片';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _statusMessage ??= '加载图片出错: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: 150,
        height: 150,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_hasError || _imagePath == null) {
      return _buildErrorPlaceholder(context);
    }

    // 显示图片，带点击查看大图功能
    return GestureDetector(
      onTap: () => _showFullImage(context),
      child: Hero(
        tag: 'image_${widget.message.localId}',
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: 300,
            maxHeight: 300,
            minWidth: 100,
            minHeight: 100,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(
              File(_imagePath!),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 150,
                  height: 150,
                  color: Colors.grey[300],
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image, size: 48, color: Colors.grey),
                      SizedBox(height: 8),
                      Text(
                        '[图片格式错误]',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorPlaceholder(BuildContext context) {
    final theme = Theme.of(context);
    final isFromMe = widget.isFromMe || widget.message.isSend == 1;
    final bubbleColor = isFromMe
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isFromMe ? Colors.white : theme.colorScheme.onSurface;
    final title = _isDecrypting ? '解密中…' : '解密并显示图片';
    final status = _statusMessage;

    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 110,
        minHeight: 32,
        maxWidth: 220,
      ),
      child: Material(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _isDecrypting ? null : _decryptOnDemand,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (_isDecrypting)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(textColor),
                    ),
                  )
                else
                  Icon(
                    Icons.lock_open_rounded,
                    size: 18,
                    color: isFromMe
                        ? Colors.white.withValues(alpha: 0.9)
                        : textColor.withValues(alpha: 0.9),
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (status != null && status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            status,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isFromMe
                                  ? Colors.white.withValues(alpha: 0.9)
                                  : theme.colorScheme.onSurface
                                      .withValues(alpha: 0.65),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 显示全屏图片
  void _showFullImage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: Hero(
              tag: 'image_${widget.message.localId}',
              child: InteractiveViewer(
                panEnabled: true,
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(
                  File(_imagePath!),
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.broken_image,
                            size: 64,
                            color: Colors.white,
                          ),
                          SizedBox(height: 16),
                          Text(
                            '无法显示图片',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _findDecryptedImageByName(String? baseName,
      {bool refresh = false}) async {
    if (baseName == null || baseName.isEmpty) return null;
    final key = baseName.toLowerCase();
    if (!refresh && _decryptedIndex.containsKey(key)) {
      return _decryptedIndex[key];
    }

    if (!_indexed) {
      await _buildDecryptedIndex();
    }
    return _decryptedIndex[key];
  }

  Future<void> _buildDecryptedIndex() async {
    _indexed = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final imagesRoot =
          Directory(p.join(docs.path, 'EchoTrace', 'Images'));
      if (!await imagesRoot.exists()) return;

      await for (final entity
          in imagesRoot.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        final base = name.split('.').first;
        _decryptedIndex[base] = entity.path;
        // 兼容缩略图/缓存文件名结尾的 _b/_c，映射去掉后缀以便匹配
        for (final suffix in ['_b', '_c']) {
          if (base.endsWith(suffix)) {
            final trimmed = base.substring(0, base.length - suffix.length);
            _decryptedIndex[trimmed] = entity.path;
          }
        }
      }
    } catch (_) {
      // 忽略索引失败
    }
  }

  Future<void> _decryptOnDemand() async {
    if (_datName == null || _datName!.isEmpty) {
      setState(() {
        _statusMessage = '未获取到图片名，无法解密';
      });
      return;
    }

    setState(() {
      _isDecrypting = true;
      _statusMessage = null;
    });

    try {
      final appState = context.read<AppState>();
      final config = appState.configService;
      final basePath = (await config.getDatabasePath()) ?? '';
      final rawWxid = await config.getManualWxid();

      if (basePath.isEmpty || rawWxid == null || rawWxid.isEmpty) {
        setState(() {
          _statusMessage = '未配置数据库路径或账号wxid，无法定位图片文件';
        });
        return;
      }

      final accountDir = Directory(p.join(basePath, rawWxid));
      if (!await accountDir.exists()) {
        setState(() {
          _statusMessage = '账号目录不存在，无法定位图片文件';
        });
        return;
      }

      final datPath =
          await _searchDatFile(accountDir, _datName!.toLowerCase());
      if (datPath == null) {
        setState(() {
          _statusMessage = '未找到对应的图片文件（*.dat），请先在数据管理中扫描/解密';
        });
        return;
      }

      final xorKeyHex = await config.getImageXorKey();
      if (xorKeyHex == null || xorKeyHex.isEmpty) {
        setState(() {
          _statusMessage = '未配置图片 XOR 密钥，无法解密';
        });
        return;
      }
      final aesKeyHex = await config.getImageAesKey();
      final xorKey = ImageDecryptService.hexToXorKey(xorKeyHex);
      Uint8List? aesKey;
      if (aesKeyHex != null && aesKeyHex.isNotEmpty) {
        try {
          aesKey = ImageDecryptService.hexToBytes16(aesKeyHex);
        } catch (_) {
          // 保持 null，V3/V1 可能不需要
        }
      }

      final decryptService = ImageDecryptService();
      final docs = await getApplicationDocumentsDirectory();
      final imagesRoot = Directory(p.join(docs.path, 'EchoTrace', 'Images'));
      if (!await imagesRoot.exists()) {
        await imagesRoot.create(recursive: true);
      }

      // 输出路径保持与原始相对路径一致，便于与“数据管理”页面统一
      String relative =
          p.relative(datPath, from: accountDir.path).replaceAll('\\', p.separator);
      if (relative.startsWith('..')) {
        // 防御：相对路径异常时退化为根级文件
        relative = '${_datName!}.jpg';
      } else {
        if (relative.toLowerCase().endsWith('.t.dat')) {
          relative = relative.substring(0, relative.length - 6) + '.jpg';
        } else if (relative.toLowerCase().endsWith('.dat')) {
          relative = relative.substring(0, relative.length - 4) + '.jpg';
        } else if (!relative.toLowerCase().endsWith('.jpg')) {
          relative = '$relative.jpg';
        }
        relative = _applyDisplayNameToRelative(relative);
      }

      final outPath = p.join(imagesRoot.path, relative);
      final outParent = Directory(p.dirname(outPath));
      if (!await outParent.exists()) {
        await outParent.create(recursive: true);
      }

      await decryptService.decryptDatAutoAsync(
        datPath,
        outPath,
        xorKey,
        aesKey,
      );

      _decryptedIndex[_datName!.toLowerCase()] = outPath;

      if (mounted) {
        setState(() {
          _imagePath = outPath;
          _hasError = false;
          _statusMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = '解密失败: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDecrypting = false;
        });
      }
    }
  }

  Future<String?> _searchDatFile(
    Directory accountDir,
    String targetBase,
  ) async {
    String? result;
    // 优先原图，再回退多种缩略图后缀 (_b/_h/_t 等)
    final candidates = <String>[
      '$targetBase.dat',
      '${targetBase}_b.dat',
      '${targetBase}_h.dat',
      '${targetBase}_t.dat',
    ];
    try {
      await for (final entity
          in accountDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.endsWith('.dat')) continue;
        if (candidates.contains(name)) {
          result = entity.path;
          // 若找到原图可直接返回；否则继续寻找原图
          if (name.endsWith('.dat') &&
              !name.endsWith('_b.dat') &&
              !name.endsWith('_h.dat') &&
              !name.endsWith('_t.dat')) return result;
        }
      }
    } catch (_) {}
    return result;
  }

  void _logDebugPaths(String? resolved) {
    assert(() {
      logger.debug(
        'ChatImage',
        '查找解密图片: datName=$_datName, displayName=$_displayName, 解析到=$resolved',
      );
      if (_decryptedIndex.isNotEmpty) {
        final sample = _decryptedIndex.entries
            .take(5)
            .map((e) => '${e.key}:${e.value}')
            .join(', ');
        logger.debug('ChatImage', '当前已索引解密文件(部分): $sample');
      }
      return true;
    }());
  }

  Future<void> _loadDisplayName(AppState appState) async {
    try {
      final names = await appState.databaseService
          .getDisplayNames([widget.sessionUsername]);
      final name = names[widget.sessionUsername];
      if (name != null && name.trim().isNotEmpty) {
        _displayName = _sanitizeSegment(name);
      }
    } catch (_) {}
  }

  String _sanitizeSegment(String name) {
    var sanitized = name.replaceAll(RegExp(r'[<>:"/\\\\|?*]'), '_').trim();
    if (sanitized.isEmpty) return '未知联系人';
    if (sanitized.length > 60) sanitized = sanitized.substring(0, 60);
    return sanitized;
  }

  String _applyDisplayNameToRelative(String relativePath) {
    if (_displayName == null) return relativePath;
    final sep = Platform.pathSeparator;
    final parts = relativePath.split(sep).where((p) => p.isNotEmpty).toList();
    final attachIdx = parts.indexWhere((p) => p.toLowerCase() == 'attach');
    if (attachIdx != -1 && attachIdx + 1 < parts.length) {
      parts[attachIdx + 1] = _displayName!;
      return (relativePath.startsWith(sep) ? sep : '') + parts.join(sep);
    }
    // 若没有 attach 段，则在最前添加展示名
    parts.insert(0, _displayName!);
    return (relativePath.startsWith(sep) ? sep : '') + parts.join(sep);
  }
}
