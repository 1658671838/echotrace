import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

/// 日志级别
enum LogLevel {
  debug,
  info,
  warning,
  error,
  fatal,
}

/// 全局日志记录服务
class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal();

  File? _logFile;
  bool _isInitialized = false;
  final int _maxLogSize = 5 * 1024 * 1024; // 5MB
  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  /// 初始化日志服务
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final tempDir = await getTemporaryDirectory();
      final logDir = Directory('${tempDir.path}${Platform.pathSeparator}echotrace_logs');
      
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      _logFile = File('${logDir.path}${Platform.pathSeparator}app.log');
      
      // 检查日志文件大小，如果超过限制则归档
      if (await _logFile!.exists()) {
        final fileSize = await _logFile!.length();
        if (fileSize > _maxLogSize) {
          await _archiveLogFile();
        }
      }

      _isInitialized = true;
      await _writeLog(LogLevel.info, 'LoggerService', '日志服务初始化成功');
    } catch (e) {
      // 如果初始化失败，至少记录到控制台
      print('日志服务初始化失败: $e');
    }
  }

  /// 归档当前日志文件
  Future<void> _archiveLogFile() async {
    if (_logFile == null || !await _logFile!.exists()) return;

    try {
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final archivePath = '${_logFile!.path}.$timestamp.archive';
      await _logFile!.copy(archivePath);
      await _logFile!.delete();
      await _logFile!.create();
    } catch (e) {
      print('归档日志文件失败: $e');
    }
  }

  /// 写入日志
  Future<void> _writeLog(LogLevel level, String tag, String message, [Object? error, StackTrace? stackTrace]) async {
    if (!_isInitialized) {
      await initialize();
    }

    final timestamp = _dateFormat.format(DateTime.now());
    final levelStr = level.name.toUpperCase().padRight(7);
    final logMessage = StringBuffer();
    
    logMessage.write('[$timestamp] [$levelStr] [$tag] $message');
    
    if (error != null) {
      logMessage.write('\n错误详情: $error');
    }
    
    if (stackTrace != null) {
      logMessage.write('\n堆栈跟踪:\n$stackTrace');
    }
    
    logMessage.write('\n');

    try {
      // 写入文件
      if (_logFile != null) {
        await _logFile!.writeAsString(
          logMessage.toString(),
          mode: FileMode.append,
          flush: true,
        );
      }

      // 同时输出到控制台
      if (level == LogLevel.error || level == LogLevel.fatal) {
        print(logMessage.toString());
      }
    } catch (e) {
      print('写入日志失败: $e');
    }
  }

  /// 调试日志
  Future<void> debug(String tag, String message) async {
    await _writeLog(LogLevel.debug, tag, message);
  }

  /// 信息日志
  Future<void> info(String tag, String message) async {
    await _writeLog(LogLevel.info, tag, message);
  }

  /// 警告日志
  Future<void> warning(String tag, String message, [Object? error]) async {
    await _writeLog(LogLevel.warning, tag, message, error);
  }

  /// 错误日志
  Future<void> error(String tag, String message, [Object? error, StackTrace? stackTrace]) async {
    await _writeLog(LogLevel.error, tag, message, error, stackTrace);
  }

  /// 严重错误日志
  Future<void> fatal(String tag, String message, [Object? error, StackTrace? stackTrace]) async {
    await _writeLog(LogLevel.fatal, tag, message, error, stackTrace);
  }

  /// 获取日志文件路径
  Future<String?> getLogFilePath() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _logFile?.path;
  }

  /// 获取日志文件内容
  Future<String> getLogContent() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      return '暂无日志记录';
    }

    try {
      return await _logFile!.readAsString();
    } catch (e) {
      return '读取日志失败: $e';
    }
  }

  /// 获取日志文件大小（格式化）
  Future<String> getLogFileSize() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      return '0 KB';
    }

    try {
      final fileSize = await _logFile!.length();
      if (fileSize < 1024) {
        return '$fileSize B';
      } else if (fileSize < 1024 * 1024) {
        return '${(fileSize / 1024).toStringAsFixed(2)} KB';
      } else {
        return '${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB';
      }
    } catch (e) {
      return '未知';
    }
  }

  /// 获取日志行数
  Future<int> getLogLineCount() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      return 0;
    }

    try {
      final content = await _logFile!.readAsString();
      return content.split('\n').where((line) => line.trim().isNotEmpty).length;
    } catch (e) {
      return 0;
    }
  }

  /// 清空日志
  Future<void> clearLogs() async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.delete();
        await _logFile!.create();
        await _writeLog(LogLevel.info, 'LoggerService', '日志已清空');
      }
    } catch (e) {
      print('清空日志失败: $e');
    }
  }

  /// 导出日志到指定路径
  Future<void> exportLog(String targetPath) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_logFile == null || !await _logFile!.exists()) {
      throw Exception('日志文件不存在');
    }

    try {
      await _logFile!.copy(targetPath);
    } catch (e) {
      throw Exception('导出日志失败: $e');
    }
  }
}

/// 全局日志实例
final logger = LoggerService();

