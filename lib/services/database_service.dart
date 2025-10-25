import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../models/message.dart';
import '../models/contact.dart';
import '../models/chat_session.dart';
import 'wechat_vfs_native.dart';
import 'logger_service.dart';

/// 数据库读取模式
enum DatabaseMode {
  decrypted,  // 使用解密后的数据库（备份模式）
  realtime,   // 实时读取加密数据库（VFS拦截模式）
}

/// 数据库操作服务
class DatabaseService {
  // 数据库模式
  DatabaseMode _mode = DatabaseMode.decrypted;
  
  // 独立的数据库连接：会话/联系人 和 消息
  static Database? _sessionDb;
  static Database? _messageDb;
  
  // 当前会话库路径与账号 wxid
  static String? _sessionDbPath;
  String? _currentAccountWxid;
  
  // 数据库工厂（用于 Isolate 中避免全局修改）
  DatabaseFactory? _dbFactory;
  
  // 缓存的消息数据库连接
  final Map<String, Database> _cachedMessageDbs = {};
  DateTime? _cacheLastUsed;
  static const Duration _cacheDuration = Duration(minutes: 5);

  /// 获取当前数据库路径
  String? get dbPath => _sessionDbPath;

  /// 初始化数据库
  Future<void> initialize({DatabaseFactory? factory}) async {
    sqfliteFfiInit();
    _dbFactory = factory;
    // 只在没有指定工厂时才设置全局工厂（用于主线程）
    if (factory == null) {
      databaseFactory = databaseFactoryFfi;
    }
  }

  

  /// 连接解密后的数据库（作为会话库）
  /// [factory] 可选的数据库工厂，用于 Isolate 中避免全局修改
  Future<void> connectDecryptedDatabase(String dbPath, {DatabaseFactory? factory}) async {
    try {
      await logger.info('DatabaseService', '尝试连接解密后的数据库: $dbPath');
      
      if (!File(dbPath).existsSync()) {
        await logger.error('DatabaseService', '数据库文件不存在: $dbPath');
        throw Exception('解密后的数据库文件不存在');
      }

      // 保存工厂实例供后续使用
      if (factory != null) {
        _dbFactory = factory;
      }

      // 关闭旧的会话库连接（消息库保持不动）
      if (_sessionDb != null) {
        await _sessionDb!.close();
        _sessionDb = null;
      }

      // 使用指定的工厂或已保存的工厂或默认工厂
      final dbFactory = factory ?? _dbFactory ?? databaseFactory;
      
      // 以只读模式打开数据库，不指定 version 避免写入操作
      _sessionDb = await dbFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          readOnly: true,
          singleInstance: false, // 允许多个实例，避免冲突
        ),
      );

      _mode = DatabaseMode.decrypted;
      _sessionDbPath = dbPath;
      _currentAccountWxid = _extractWxidFromPath(dbPath);
      
      await logger.info('DatabaseService', '成功连接解密数据库，模式: ${_mode.name}');
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '连接解密数据库失败', e, stackTrace);
      rethrow;
    }
  }

  /// 连接实时加密数据库（VFS拦截模式）
  /// [dbPath] 加密数据库路径
  /// [hexKey] 解密密钥（64位十六进制）
  /// [factory] 可选的数据库工厂
  Future<void> connectRealtimeDatabase(String dbPath, String hexKey, {DatabaseFactory? factory}) async {
    try {
      await logger.info('DatabaseService', '尝试连接实时加密数据库: $dbPath');
      
      if (!File(dbPath).existsSync()) {
        await logger.error('DatabaseService', '数据库文件不存在: $dbPath');
        throw Exception('数据库文件不存在');
      }

      // 保存工厂实例供后续使用
      if (factory != null) {
        _dbFactory = factory;
      }

      // 关闭旧的会话库连接
      if (_sessionDb != null) {
        await _sessionDb!.close();
        _sessionDb = null;
      }
    
      // 使用真正的VFS拦截打开加密数据库
      // 在SQLite文件系统层面拦截xRead操作，实时解密数据页
      _sessionDb = await WeChatVFSNative.openEncryptedDatabase(dbPath, hexKey);

      _mode = DatabaseMode.realtime;
      _sessionDbPath = dbPath;
      _currentAccountWxid = _extractWxidFromPath(dbPath);
      
      await logger.info('DatabaseService', '成功连接实时加密数据库，模式: ${_mode.name}');
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '连接实时加密数据库失败', e, stackTrace);
      rethrow;
    }
  }
  
  /// 获取当前使用的数据库工厂
  DatabaseFactory get _currentFactory => _dbFactory ?? databaseFactory;
  
  /// 获取当前数据库模式
  DatabaseMode get mode => _mode;

  /// 获取当前使用的数据库
  Database? get _currentDb => _sessionDb;
  
  /// 获取会话列表
  Future<List<ChatSession>> getSessions() async {
    final db = _currentDb;
    if (db == null) {
      await logger.error('DatabaseService', '获取会话列表失败：数据库未连接');
      throw Exception('数据库未连接');
    }

    try {
      await logger.info('DatabaseService', '开始获取会话列表');
      
      // 先检查表是否存在
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'"
      );
      
      final tableNames = tables.map((t) => t['name'] as String).toList();
      
      await logger.info('DatabaseService', '数据库中的表: ${tableNames.join(", ")}');
      
      // 尝试找到会话表（可能的表名）
      String? sessionTableName;
      for (final name in ['SessionTable', 'Session', 'session', 'Contact']) {
        if (tableNames.contains(name)) {
          sessionTableName = name;
          await logger.info('DatabaseService', '找到会话表: $name');
          break;
        }
      }
      
      if (sessionTableName == null) {
        await logger.warning('DatabaseService', '未找到标准会话表，尝试其他表');
        // 如果没有找到会话表，尝试从其他表获取联系人信息
        if (tableNames.contains('contact') || tableNames.contains('Contact')) {
          return await _getSessionsFromContactTable(tableNames);
        } else if (tableNames.contains('FMessageTable')) {
          return await _getSessionsFromFMessageTable();
        } else {
          // 检查是否是纯消息数据库
          final hasMsgTables = tableNames.any((t) => t.startsWith('Msg_'));
          if (hasMsgTables) {
            throw Exception('当前连接的是消息数据库（message_x.db），无法获取会话列表。请确保系统连接的是 session.db 或 contact.db。如果问题持续，请尝试重新解密数据库。');
          }
          throw Exception('数据库中未找到会话表。可用的表: ${tableNames.join(", ")}');
        }
      }

      await logger.info('DatabaseService', '从表 $sessionTableName 查询会话');
      
      final List<Map<String, dynamic>> maps = await db.query(
        sessionTableName,
        orderBy: 'sort_timestamp DESC',
      );

      await logger.info('DatabaseService', '查询到 ${maps.length} 条原始会话记录');
      
      // 获取会话列表后，尝试从 contact 数据库获取真实姓名
      final allSessions = maps.map((map) => ChatSession.fromMap(map)).toList();
      
      await logger.info('DatabaseService', '转换为 ${allSessions.length} 个ChatSession对象');
      
      // 过滤掉公众号、服务号等非正常联系人
      final filteredSessions = allSessions.where((session) {
        final username = session.username;
        
        // 过滤条件：只显示正常联系人和群聊
        final shouldKeep = username.contains('@chatroom') ||
                          (username.startsWith('wxid_') && !username.contains('@')) ||
                          (!username.contains('@kefu.openim') && 
                           !username.contains('service_') &&
                           !username.startsWith('gh_') &&
                           !username.contains('@openim'));
        
        return shouldKeep;
      }).toList();
      
      await logger.info('DatabaseService', '过滤后剩余 ${filteredSessions.length} 个会话');
      
      // 尝试连接 contact 数据库获取真实姓名
      await _enrichSessionsWithContactInfo(filteredSessions);
      
      await logger.info('DatabaseService', '成功返回 ${filteredSessions.length} 个会话');
      
      return filteredSessions;
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '获取会话列表失败', e, stackTrace);
      throw Exception('获取会话列表失败: $e');
    }
  }

  /// 获取联系人信息
  Future<Contact?> getContact(String username) async {
    final db = _currentDb;
    if (db == null) {
      throw Exception('数据库未连接');
    }

    try {
      final List<Map<String, dynamic>> maps = await db.query(
        'contact',
        where: 'username = ?',
        whereArgs: [username],
        limit: 1,
      );

      if (maps.isNotEmpty) {
        return Contact.fromMap(maps.first);
      }
      return null;
    } catch (e) {
      throw Exception('获取联系人信息失败: $e');
    }
  }

  /// 获取消息列表（支持跨多个数据库合并，智能优先级加载）
  Future<List<Message>> getMessages(String sessionId, {int limit = 50, int offset = 0}) async {
    if (_sessionDb == null) {
      await logger.error('DatabaseService', '获取消息列表失败：数据库未连接');
      throw Exception('数据库未连接');
    }

    try {
      await logger.info('DatabaseService', '开始获取消息，sessionId=$sessionId, limit=$limit, offset=$offset');
      
      // 第一步：找到所有包含该会话消息的数据库及表，并获取最新消息时间戳
      final List<_DatabaseTableInfo> dbInfos = [];
      
      // 1. 检查当前数据库
      final Database dbForMsg = await _getDbForMessages();
      final tableName = await _getMessageTableName(sessionId, dbForMsg);
      
      if (tableName != null) {
        final latestTimestamp = await _getLatestMessageTimestamp(dbForMsg, tableName);
        dbInfos.add(_DatabaseTableInfo(
          database: dbForMsg,
          tableName: tableName,
          latestTimestamp: latestTimestamp,
          needsClose: false, // 当前数据库不需要关闭
        ));
        await logger.info('DatabaseService', '当前数据库找到消息表: $tableName, 最新消息时间: $latestTimestamp');
      }
      
      // 2. 搜索所有其他消息数据库
      final allMessageDbs = await _findAllMessageDbs();
      await logger.info('DatabaseService', '搜索 ${allMessageDbs.length} 个消息数据库');
      
      for (int i = 0; i < allMessageDbs.length; i++) {
        final dbPath = allMessageDbs[i];
        
        try {
          final tempDb = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          
          try {
            final foundTableName = await _getMessageTableName(sessionId, tempDb, dbIndex: i);
            if (foundTableName != null) {
              final latestTimestamp = await _getLatestMessageTimestamp(tempDb, foundTableName);
              dbInfos.add(_DatabaseTableInfo(
                database: tempDb,
                tableName: foundTableName,
                latestTimestamp: latestTimestamp,
                needsClose: true, // 临时打开的数据库需要关闭
              ));
              await logger.info('DatabaseService', '数据库$i找到消息表: $foundTableName, 最新消息时间: $latestTimestamp');
            } else {
              await tempDb.close();
            }
          } catch (e) {
            await tempDb.close();
            rethrow;
          }
        } catch (e) {
          await logger.warning('DatabaseService', '数据库$i查询失败', e);
        }
      }
      
      if (dbInfos.isEmpty) {
        await logger.warning('DatabaseService', '未找到任何包含该会话消息的数据库');
        return [];
      }
      
      // 第二步：按最新消息时间戳降序排序数据库
      dbInfos.sort((a, b) => b.latestTimestamp.compareTo(a.latestTimestamp));
      await logger.info('DatabaseService', '找到 ${dbInfos.length} 个数据库，按最新消息排序');
      
      // 第三步：依次从数据库加载消息，直到满足需求
      final List<Message> allMessages = [];
      final targetCount = limit + offset; // 需要的总消息数
      
      try {
        for (int i = 0; i < dbInfos.length; i++) {
          final dbInfo = dbInfos[i];
          
          // 如果已经收集够了，不再继续加载
          if (allMessages.length >= targetCount * 1.2) {
            await logger.info('DatabaseService', '已收集足够消息 (${allMessages.length}条)，停止加载');
            break;
          }
          
          // 计算还需要多少条消息（留20%余量确保排序后有足够数据）
          final remainingNeeded = (targetCount * 1.5 - allMessages.length).ceil().clamp(limit, limit * 3);
          
          await logger.info('DatabaseService', '从数据库$i加载，需要约 $remainingNeeded 条');
          final messages = await _queryMessagesFromTable(dbInfo.database, dbInfo.tableName, remainingNeeded, 0);
          allMessages.addAll(messages);
          await logger.info('DatabaseService', '数据库$i加载了 ${messages.length} 条消息，累计 ${allMessages.length} 条');
        }
        
        // 第四步：按时间戳排序所有消息（降序，最新的在前）
        allMessages.sort((a, b) => b.createTime.compareTo(a.createTime));
        
        await logger.info('DatabaseService', '共收集到 ${allMessages.length} 条消息，应用分页 limit=$limit, offset=$offset');
        
        // 第五步：应用分页
        final startIndex = offset.clamp(0, allMessages.length);
        final endIndex = (offset + limit).clamp(0, allMessages.length);
        final pagedMessages = allMessages.sublist(startIndex, endIndex);
        
        await logger.info('DatabaseService', '返回 ${pagedMessages.length} 条消息');
        return pagedMessages;
      } finally {
        // 关闭临时打开的数据库
        for (final dbInfo in dbInfos) {
          if (dbInfo.needsClose) {
            try {
              await dbInfo.database.close();
            } catch (e) {
              // 忽略关闭错误
            }
          }
        }
      }
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '获取消息列表失败', e, stackTrace);
      throw Exception('获取消息列表失败: $e');
    }
  }
  
  /// 获取表中最新消息的时间戳
  Future<int> _getLatestMessageTimestamp(Database db, String tableName) async {
    try {
      final result = await db.rawQuery(
        'SELECT MAX(create_time) as latest FROM $tableName'
      );
      return (result.first['latest'] as int?) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// 根据日期查询消息（支持跨多个数据库合并）
  Future<List<Message>> getMessagesByDate(String sessionId, int begintimestamp, int endtimestamp) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 收集所有消息（可能分散在多个数据库中）
      final List<Message> allMessages = [];
      
      // 1. 先尝试当前数据库
      final Database dbForMsg = await _getDbForMessages();
      final tableName = await _getMessageTableName(sessionId, dbForMsg);

      if (tableName != null) {
        final messages = await _queryMessagesFromTable(dbForMsg, tableName, 0, 0, begintimestamp: begintimestamp, endTimestamp: endtimestamp);
        allMessages.addAll(messages);
      }

      // 2. 搜索所有其他消息数据库
      final allMessageDbs = await _findAllMessageDbs();

      for (int i = 0; i < allMessageDbs.length; i++) {
        final dbPath = allMessageDbs[i];

        try {
          final tempDb = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );

          try {
            final foundTableName = await _getMessageTableName(sessionId, tempDb, dbIndex: i);
            if (foundTableName != null) {
              final messages = await _queryMessagesFromTable(tempDb, foundTableName, 0, 0, begintimestamp: begintimestamp, endTimestamp: endtimestamp);
              allMessages.addAll(messages);
            }
          } finally {
            await tempDb.close();
          }
        } catch (e) {
          // 忽略单个数据库的错误，继续查询其他数据库
        }
      }

      // 3. 按时间戳排序（降序，最新的在前）
      allMessages.sort((a, b) => b.createTime.compareTo(a.createTime));

      return allMessages;
    } catch (e) {
      print('获取消息列表失败: $e');
      throw Exception('获取消息列表失败: $e');
    }
  }

  /// 从指定表查询消息
  Future<List<Message>> _queryMessagesFromTable(
    Database db, 
    String tableName,
    int limit,
    int offset,
    {int begintimestamp=0, int endTimestamp=0,}
  ) async {
      // 直接根据 real_sender_id 判断：1=自己发的，其他=别人发的
      // 对于群聊，需要通过 real_sender_id 查询 Name2Id 获取发送者 username

    // 构建基本 SQL
     final buffer = StringBuffer('''
      SELECT 
      m.*,
      CASE WHEN m.real_sender_id = 1 THEN 1 ELSE 0 END AS is_send,
      n.user_name AS sender_username
      FROM $tableName m 
      LEFT JOIN Name2Id n ON m.real_sender_id = n.rowid
      ''');

      // 构建 where 条件
      final whereClauses = <String>[];
      final args = <Object?>[];
      if (begintimestamp > 0) {
        whereClauses.add('m.create_time >= ?');
        args.add(begintimestamp);
      }
      if (endTimestamp > 0) {
        whereClauses.add('m.create_time <= ?');
        args.add(endTimestamp);
      }
      // 拼接 where
      if (whereClauses.isNotEmpty) {
        buffer.write(' WHERE ${whereClauses.join(' AND ')}');
      }


      //拼接排序
      buffer.write(' ORDER BY m.sort_seq DESC ');

      // 分页
      if(limit>0 || offset>0) {
        buffer.write(' LIMIT ? OFFSET ?');
        args.addAll([limit, offset]);
      }

      //执行查询
      final maps = await db.rawQuery(buffer.toString(), args);

      return maps.map((map) => Message.fromMap(map, myWxid: _currentAccountWxid)).toList();
  }

  /// 获取会话的消息总数
  Future<int> getMessageCount(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      int totalCount = 0;
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库累加计数
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('SELECT COUNT(*) as count FROM ${dbInfo.tableName}');
          totalCount += (result.first['count'] as int?) ?? 0;
        } catch (e) {
          // 忽略错误，继续下一个
        }
      }
      
      return totalCount;
    } catch (e) {
      return 0;
    }
  }

  /// 根据会话ID获取消息表名
  Future<String?> _getMessageTableName(String sessionId, Database db, {int? dbIndex}) async {
    try {
      // 查询所有消息表
      final List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );
      
      // 计算sessionId的MD5值（32位小写）
      final sessionMd5 = _md5(sessionId);
      
      // 1. 精确匹配：Msg_{md5} 格式
      final expectedTableName = 'Msg_$sessionMd5';
      for (final table in tables) {
        final tableName = table['name'] as String;
        if (tableName.toLowerCase() == expectedTableName.toLowerCase()) {
          return tableName;
        }
      }
      
      // 2. 包含匹配：表名中包含完整MD5
      for (final table in tables) {
        final tableName = table['name'] as String;
        if (tableName.toLowerCase().contains(sessionMd5.toLowerCase())) {
          return tableName;
        }
      }

      // 2.5. 部分MD5匹配（前24位）
      final partialMd5 = sessionMd5.substring(0, 24);
      for (final table in tables) {
        final tableName = table['name'] as String;
        if (tableName.toLowerCase().contains(partialMd5.toLowerCase())) {
          return tableName;
        }
      }

      // 2.6. 尝试不同的大小写组合
      final variants = [
        'Msg_$sessionMd5',
        'msg_$sessionMd5',
        'MSG_$sessionMd5',
        'Msg_${sessionMd5.toUpperCase()}',
      ];
      
      for (final variant in variants) {
        for (final table in tables) {
          final tableName = table['name'] as String;
          if (tableName == variant) {
            return tableName;
          }
        }
      }

      // 3. 检查 Name2Id 表，验证用户是否存在
      try {
        // 首先尝试精确匹配
        var name2IdRows = await db.rawQuery(
          'SELECT rowid, user_name FROM Name2Id WHERE user_name = ? LIMIT 1',
          [sessionId]
        );
        
        if (name2IdRows.isEmpty) {
          // 尝试模糊匹配（可能有前缀或后缀）
          name2IdRows = await db.rawQuery(
            "SELECT rowid, user_name FROM Name2Id WHERE user_name LIKE ? LIMIT 5",
            ['%$sessionId%']
          );
          
          if (name2IdRows.isNotEmpty) {
            for (final row in name2IdRows) {
              // 尝试使用找到的用户名计算MD5并查找表
              final altUsername = row['user_name'] as String;
              final altMd5 = _md5(altUsername);
              final altTableName = 'Msg_$altMd5';
              
              for (final table in tables) {
                final tableName = table['name'] as String;
                if (tableName.toLowerCase() == altTableName.toLowerCase()) {
                  return tableName;
                }
              }
            }
          }
        }
      } catch (e) {
        // 查询失败，继续
      }

      // 4. 检查 DeleteInfo 表，看是否有删除记录
      try {
        final deleteInfoRows = await db.rawQuery(
          'SELECT delete_table_name FROM DeleteInfo WHERE chat_name_id IN (SELECT rowid FROM Name2Id WHERE user_name = ?)',
          [sessionId]
        );
        
        if (deleteInfoRows.isNotEmpty) {
        }
      } catch (e) {
        // DeleteInfo 表可能不存在，忽略错误
      }

      // 5. 尝试通过 Name2Id 反向查找可能的表
      try {
        // 查询所有 Name2Id 记录，看看是否有相似的
        final allName2Id = await db.rawQuery('SELECT rowid, user_name FROM Name2Id LIMIT 100');
        
        for (final row in allName2Id) {
          final userName = row['user_name'] as String?;
          if (userName != null && userName.toLowerCase().contains(sessionId.toLowerCase())) {
            // 找到相似用户名
          }
        }
      } catch (e) {
        // 忽略错误
      }
      
      return null;
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '查找消息表异常', e, stackTrace);
      return null;
    }
  }

  /// 计算MD5哈希
  String _md5(String input) {
    var bytes = utf8.encode(input);
    var digest = md5.convert(bytes);
    return digest.toString();
  }

  /// 搜索消息
  Future<List<Message>> searchMessages(String keyword, {int limit = 100}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final Database dbForMsg = await _getDbForMessages();
      final List<Map<String, dynamic>> tables = await dbForMsg.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );

      final List<Message> results = [];
      
      for (final table in tables) {
        final tableName = table['name'] as String;
        
        final List<Map<String, dynamic>> maps = await dbForMsg.query(
          tableName,
          where: 'message_content LIKE ?',
          whereArgs: ['%$keyword%'],
          limit: limit,
        );

        results.addAll(maps.map((map) => Message.fromMap(map, myWxid: _currentAccountWxid)));
      }

      return results;
    } catch (e) {
      throw Exception('搜索消息失败: $e');
    }
  }

  /// 快速获取会话按日期分组的消息统计（包含第一条消息发送者）
  Future<Map<String, Map<String, dynamic>>> getSessionMessagesByDate(String sessionId, {int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final resultMap = <String, Map<String, dynamic>>{};
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库查询并合并
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              DATE(create_time, 'unixepoch', 'localtime') as date,
              COUNT(*) as count,
              (SELECT CASE WHEN real_sender_id = 1 THEN 1 ELSE 0 END FROM ${dbInfo.tableName} t2 
               WHERE DATE(t2.create_time, 'unixepoch', 'localtime') = DATE(t1.create_time, 'unixepoch', 'localtime')
               ${yearFilter ?? ''}
               ORDER BY t2.create_time ASC LIMIT 1) as first_is_send
            FROM ${dbInfo.tableName} t1
            WHERE 1=1 ${yearFilter ?? ''}
            GROUP BY date
            ORDER BY date
          ''');
          
          for (final row in result) {
            final date = row['date'] as String;
            final count = (row['count'] as int?) ?? 0;
            final firstIsSend = (row['first_is_send'] as int?) == 1;
            
            if (resultMap.containsKey(date)) {
              resultMap[date]!['count'] = (resultMap[date]!['count'] as int) + count;
            } else {
              resultMap[date] = {
                'count': count,
                'firstIsSend': firstIsSend,
              };
            }
          }
        } catch (e) {
        }
      }
      
      return resultMap;
    } catch (e) {
      return {};
    }
  }

  /// 快速获取会话消息的日期列表（用于连续打卡等分析，不加载消息内容）
  Future<List<DateTime>> getSessionMessageDates(String sessionId, {int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final allDates = <String>{};
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库查询并合并
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT DISTINCT DATE(create_time, 'unixepoch', 'localtime') as date
            FROM ${dbInfo.tableName}
            WHERE 1=1 ${yearFilter ?? ''}
          ''');
          
          for (final row in result) {
            allDates.add(row['date'] as String);
          }
        } catch (e) {
        }
      }
      
      // 排序并转换为DateTime
      final sortedDates = allDates.toList()..sort();
      return sortedDates.map((dateStr) => DateTime.parse(dateStr)).toList();
    } catch (e) {
      return [];
    }
  }

  /// 快速获取我发送的文本消息（用于长度分析，只加载必要字段）
  Future<List<Map<String, dynamic>>> getMyTextMessagesForLengthAnalysis({int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final results = <Map<String, dynamic>>[];
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final cachedDbs = await _getCachedMessageDatabases();
      
      // 从所有数据库查询
      for (int dbIdx = 0; dbIdx < cachedDbs.length; dbIdx++) {
        final dbInfo = cachedDbs[dbIdx];
        try {
          // 获取所有消息表
          final tables = await dbInfo.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
          );
          
          // 只查询我发送的文本消息（local_type = 1）
          for (final table in tables) {
            final tableName = table['name'] as String;
            try {
              final msgs = await dbInfo.database.rawQuery('''
                SELECT 
                  local_id,
                  message_content,
                  compress_content,
                  create_time,
                  LENGTH(COALESCE(message_content, '')) as content_length
                FROM $tableName
                WHERE local_type = 1 
                  AND real_sender_id = 1
                  ${yearFilter ?? ''}
                ORDER BY content_length DESC
                LIMIT 100
              ''');
              
              for (final msg in msgs) {
                results.add({
                  ...msg,
                  'table_name': tableName,
                  'db_index': dbIdx,
                });
              }
            } catch (e) {
            }
          }
        } catch (e) {
        }
      }
      
      // 按长度排序，返回前100条
      results.sort((a, b) => (b['content_length'] as int).compareTo(a['content_length'] as int));
      return results.take(100).toList();
    } catch (e) {
      return [];
    }
  }

  /// 快速获取所有会话的消息类型分布（SQL直接统计）
  Future<Map<int, int>> getAllMessageTypeDistribution({int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final typeCount = <int, int>{};
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final cachedDbs = await _getCachedMessageDatabases();
      
      // 从所有数据库查询并累加
      for (final dbInfo in cachedDbs) {
        try {
          // 获取所有消息表
          final tables = await dbInfo.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
          );
          
          // 统计每个表的消息类型
          for (final table in tables) {
            final tableName = table['name'] as String;
            try {
              final result = await dbInfo.database.rawQuery('''
                SELECT local_type, COUNT(*) as count
                FROM $tableName
                WHERE 1=1 ${yearFilter ?? ''}
                GROUP BY local_type
              ''');
              
              for (final row in result) {
                final type = row['local_type'] as int;
                final count = row['count'] as int;
                typeCount[type] = (typeCount[type] ?? 0) + count;
              }
            } catch (e) {
            }
          }
        } catch (e) {
        }
      }
      
      return typeCount;
    } catch (e) {
      return {};
    }
  }

  /// 快速获取会话消息统计（不加载所有消息，直接SQL统计）
  Future<Map<String, dynamic>> getSessionMessageStats(String sessionId, {int? filterYear}) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      int totalCount = 0;
      int sentCount = 0;
      int receivedCount = 0;
      
      // 构建年份过滤条件
      String? yearFilter;
      if (filterYear != null) {
        final startTimestamp = DateTime(filterYear, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTimestamp = DateTime(filterYear + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        yearFilter = ' AND create_time >= $startTimestamp AND create_time < $endTimestamp';
      }
      
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      // 从所有数据库查询并累加统计
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              COUNT(*) as total,
              COALESCE(SUM(CASE WHEN real_sender_id = 1 THEN 1 ELSE 0 END), 0) as sent,
              COALESCE(SUM(CASE WHEN real_sender_id != 1 THEN 1 ELSE 0 END), 0) as received
            FROM ${dbInfo.tableName}
            WHERE 1=1 ${yearFilter ?? ''}
          ''');
          
          final row = result.first;
          totalCount += (row['total'] as int?) ?? 0;
          sentCount += (row['sent'] as int?) ?? 0;
          receivedCount += (row['received'] as int?) ?? 0;
        } catch (e) {
        }
      }
      
      return {
        'total': totalCount,
        'sent': sentCount,
        'received': receivedCount,
      };
    } catch (e) {
      return {
        'total': 0,
        'sent': 0,
        'received': 0,
      };
    }
  }

  /// 获取数据库统计信息
  Future<Map<String, int>> getDatabaseStats() async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final stats = <String, int>{};

      // 获取会话数量
      final sessionResult = await _sessionDb!.rawQuery(
        'SELECT COUNT(*) as count FROM SessionTable'
      );
      final sessionCount = sessionResult.first['count'] as int? ?? 0;
      stats['sessions'] = sessionCount;

      // 获取联系人数量
      final contactResult = await _sessionDb!.rawQuery(
        'SELECT COUNT(*) as count FROM contact'
      );
      final contactCount = contactResult.first['count'] as int? ?? 0;
      stats['contacts'] = contactCount;

      // 获取消息表数量
      final Database dbForMsg = await _getDbForMessages();
      final messageTables = await dbForMsg.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
      );
      stats['message_tables'] = messageTables.length;

      return stats;
    } catch (e) {
      throw Exception('获取数据库统计信息失败: $e');
    }
  }

  /// 获取会话的消息类型分布
  Future<Map<String, int>> getSessionTypeDistribution(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      int textCount = 0;
      int imageCount = 0;
      int voiceCount = 0;
      int videoCount = 0;
      int otherCount = 0;
      
      // 从所有数据库查询并累加
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              SUM(CASE WHEN local_type IN (1, 244813135921) THEN 1 ELSE 0 END) as text,
              SUM(CASE WHEN local_type = 3 THEN 1 ELSE 0 END) as image,
              SUM(CASE WHEN local_type = 34 THEN 1 ELSE 0 END) as voice,
              SUM(CASE WHEN local_type = 43 THEN 1 ELSE 0 END) as video,
              SUM(CASE WHEN local_type NOT IN (1, 3, 34, 43, 244813135921) THEN 1 ELSE 0 END) as other
            FROM ${dbInfo.tableName}
          ''');
          
          final row = result.first;
          textCount += (row['text'] as int?) ?? 0;
          imageCount += (row['image'] as int?) ?? 0;
          voiceCount += (row['voice'] as int?) ?? 0;
          videoCount += (row['video'] as int?) ?? 0;
          otherCount += (row['other'] as int?) ?? 0;
        } catch (e) {
          // 忽略错误
        }
      }
      
      return {
        'text': textCount,
        'image': imageCount,
        'voice': voiceCount,
        'video': videoCount,
        'other': otherCount,
      };
    } catch (e) {
      return {'text': 0, 'image': 0, 'voice': 0, 'video': 0, 'other': 0};
    }
  }

  /// 获取会话的时间范围（第一条和最后一条消息时间，用于分析服务）
  Future<Map<String, int?>> getSessionTimeRange(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      int? firstTime;
      int? lastTime;
      
      // 从所有数据库查询并比较
      for (final dbInfo in dbInfos) {
        try {
          final result = await dbInfo.database.rawQuery('''
            SELECT 
              MIN(create_time) as first,
              MAX(create_time) as last
            FROM ${dbInfo.tableName}
          ''');
          
          final row = result.first;
          final dbFirst = row['first'] as int?;
          final dbLast = row['last'] as int?;
          
          if (dbFirst != null && (firstTime == null || dbFirst < firstTime)) {
            firstTime = dbFirst;
          }
          if (dbLast != null && (lastTime == null || dbLast > lastTime)) {
            lastTime = dbLast;
          }
        } catch (e) {
          // 忽略错误
        }
      }
      
      return {
        'first': firstTime,
        'last': lastTime,
      };
    } catch (e) {
      return {'first': null, 'last': null};
    }
  }

  /// 批量获取多个会话的统计数据
  Future<Map<String, Map<String, dynamic>>> getBatchSessionStats(List<String> sessionIds) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    final result = <String, Map<String, dynamic>>{};
    
    // 使用缓存的数据库连接
    final cachedDbs = await _getCachedMessageDatabases();
    
    for (final sessionId in sessionIds) {
      try {
        // 收集该会话在所有数据库的表
        final dbInfos = <_DatabaseTableInfo>[];
        final seenTables = <String>{};
        
        for (final dbInfo in cachedDbs) {
          try {
            final tableName = await _getMessageTableName(
              sessionId, 
              dbInfo.database,
            );
            
            // 避免重复的表名
            if (tableName != null && !seenTables.contains(tableName)) {
              seenTables.add(tableName);
              dbInfos.add(_DatabaseTableInfo(
                database: dbInfo.database,
                tableName: tableName,
                latestTimestamp: 0,
                needsClose: false,
              ));
            }
          } catch (e) {
            // 忽略错误
          }
        }
        
        if (dbInfos.isEmpty) continue;
        
        // 统计数据
        int totalCount = 0;
        int sentCount = 0;
        int receivedCount = 0;
        int textCount = 0;
        int imageCount = 0;
        int voiceCount = 0;
        int videoCount = 0;
        int otherCount = 0;
        int? firstTime;
        int? lastTime;
        final datesSet = <String>{};
        
        // 从所有数据库累加统计
        for (final dbInfo in dbInfos) {
          try {
            // 一次查询获取所有统计
            final statResult = await dbInfo.database.rawQuery('''
              SELECT 
                COUNT(*) as total,
                SUM(CASE WHEN real_sender_id = 1 THEN 1 ELSE 0 END) as sent,
                SUM(CASE WHEN real_sender_id != 1 THEN 1 ELSE 0 END) as received,
                SUM(CASE WHEN local_type IN (1, 244813135921) THEN 1 ELSE 0 END) as text,
                SUM(CASE WHEN local_type = 3 THEN 1 ELSE 0 END) as image,
                SUM(CASE WHEN local_type = 34 THEN 1 ELSE 0 END) as voice,
                SUM(CASE WHEN local_type = 43 THEN 1 ELSE 0 END) as video,
                SUM(CASE WHEN local_type NOT IN (1, 3, 34, 43, 244813135921) THEN 1 ELSE 0 END) as other,
                MIN(create_time) as first,
                MAX(create_time) as last
              FROM ${dbInfo.tableName}
            ''');
            
            final row = statResult.first;
            totalCount += (row['total'] as int?) ?? 0;
            sentCount += (row['sent'] as int?) ?? 0;
            receivedCount += (row['received'] as int?) ?? 0;
            textCount += (row['text'] as int?) ?? 0;
            imageCount += (row['image'] as int?) ?? 0;
            voiceCount += (row['voice'] as int?) ?? 0;
            videoCount += (row['video'] as int?) ?? 0;
            otherCount += (row['other'] as int?) ?? 0;
            
            final dbFirst = row['first'] as int?;
            final dbLast = row['last'] as int?;
            if (dbFirst != null && (firstTime == null || dbFirst < firstTime)) {
              firstTime = dbFirst;
            }
            if (dbLast != null && (lastTime == null || dbLast > lastTime)) {
              lastTime = dbLast;
            }
            
            // 获取日期列表
            final dateResult = await dbInfo.database.rawQuery('''
              SELECT DISTINCT DATE(create_time, 'unixepoch', 'localtime') as date
              FROM ${dbInfo.tableName}
            ''');
            
            for (final dateRow in dateResult) {
              datesSet.add(dateRow['date'] as String);
            }
          } catch (e) {
            // 忽略错误
          }
        }
        
        result[sessionId] = {
          'total': totalCount,
          'sent': sentCount,
          'received': receivedCount,
          'text': textCount,
          'image': imageCount,
          'voice': voiceCount,
          'video': videoCount,
          'other': otherCount,
          'first': firstTime,
          'last': lastTime,
          'activeDays': datesSet.length,
        };
      } catch (e) {
        // 该会话查询失败，跳过
      }
    }
    
    return result;
  }

  /// 获取会话的时间分布数据
  Future<Map<String, dynamic>> getSessionTimeDistribution(String sessionId) async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      // 使用缓存的数据库连接
      final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
      
      final hourlyDistribution = <int, int>{};
      final weekdayDistribution = <int, int>{};
      final monthlyDistribution = <String, int>{};
      
      // 初始化小时分布 (0-23)
      for (int i = 0; i < 24; i++) {
        hourlyDistribution[i] = 0;
      }
      
      // 初始化星期分布 (1-7)
      for (int i = 1; i <= 7; i++) {
        weekdayDistribution[i] = 0;
      }
      
      // 从所有数据库查询并累加
      for (final dbInfo in dbInfos) {
        try {
          // 小时分布
          final hourlyResult = await dbInfo.database.rawQuery('''
            SELECT 
              CAST(strftime('%H', create_time, 'unixepoch', 'localtime') AS INTEGER) as hour,
              COUNT(*) as count
            FROM ${dbInfo.tableName}
            GROUP BY hour
          ''');
          
          for (final row in hourlyResult) {
            final hour = row['hour'] as int;
            final count = row['count'] as int;
            hourlyDistribution[hour] = (hourlyDistribution[hour] ?? 0) + count;
          }
          
          // 星期分布 (strftime('%w') 返回 0-6，0是星期日)
          final weekdayResult = await dbInfo.database.rawQuery('''
            SELECT 
              CASE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER)
                WHEN 0 THEN 7
                ELSE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER)
              END as weekday,
              COUNT(*) as count
            FROM ${dbInfo.tableName}
            GROUP BY weekday
          ''');
          
          for (final row in weekdayResult) {
            final weekday = row['weekday'] as int;
            final count = row['count'] as int;
            weekdayDistribution[weekday] = (weekdayDistribution[weekday] ?? 0) + count;
          }
          
          // 月份分布
          final monthlyResult = await dbInfo.database.rawQuery('''
            SELECT 
              strftime('%Y-%m', create_time, 'unixepoch', 'localtime') as month,
              COUNT(*) as count
            FROM ${dbInfo.tableName}
            GROUP BY month
          ''');
          
          for (final row in monthlyResult) {
            final month = row['month'] as String;
            final count = row['count'] as int;
            monthlyDistribution[month] = (monthlyDistribution[month] ?? 0) + count;
          }
        } catch (e) {
          // 忽略错误
        }
      }
      
      return {
        'hourly': hourlyDistribution,
        'weekday': weekdayDistribution,
        'monthly': monthlyDistribution,
      };
    } catch (e) {
      return {
        'hourly': <int, int>{},
        'weekday': <int, int>{},
        'monthly': <String, int>{},
      };
    }
  }

  /// 关闭数据库连接
  Future<void> close() async {
    
    // 先清理缓存的数据库连接
    await clearDatabaseCache();
    
    // 如果是实时模式，需要清理VFS资源
    if (_mode == DatabaseMode.realtime && _sessionDbPath != null && _sessionDb != null) {
      try {
        await WeChatVFSNative.closeEncryptedDatabase(_sessionDb!, _sessionDbPath!);
      } catch (e) {
      }
      _sessionDb = null;
    } else if (_sessionDb != null) {
      try {
        await _sessionDb!.close();
      } catch (e) {
      }
      _sessionDb = null;
    }
    
    if (_messageDb != null) {
      try {
        await _messageDb!.close();
      } catch (e) {
      }
      _messageDb = null;
    }
    
    // 强制触发垃圾回收，帮助释放文件句柄
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// 检查数据库是否已连接
  bool get isConnected => _sessionDb != null;

  /// 当前账户 wxid
  String? get currentAccountWxid => _currentAccountWxid;

  /// 当前数据路径（从session数据库路径推导）
  String? get currentDataPath {
    if (_sessionDbPath == null) return null;
    // 获取数据库文件所在目录
    final lastSeparator = _sessionDbPath!.lastIndexOf(Platform.pathSeparator);
    if (lastSeparator == -1) return null;
    return _sessionDbPath!.substring(0, lastSeparator);
  }

  /// 批量获取联系人显示名称（remark > nick_name > username）
  Future<Map<String, String>> getDisplayNames(List<String> usernames) async {
    if (_sessionDb == null || usernames.isEmpty) {
      return {};
    }

    try {
      final contactDbPath = _sessionDbPath?.replaceAll('session.db', 'contact.db');
      if (contactDbPath == null || !await File(contactDbPath).exists()) {
        return {};
      }

      final contactDb = await _currentFactory.openDatabase(contactDbPath);
      
      try {
        final result = <String, String>{};
        final placeholders = List.filled(usernames.length, '?').join(',');
        
        // 1. 先从 contact 表查询
        try {
          var rows = await contactDb.rawQuery('''
            SELECT username, remark, nick_name 
            FROM contact 
            WHERE username IN ($placeholders)
          ''', usernames);

          for (final row in rows) {
            final username = row['username'] as String;
            final remark = row['remark'] as String?;
            final nickName = row['nick_name'] as String?;
            final displayName = remark?.isNotEmpty == true 
                ? remark! 
                : (nickName?.isNotEmpty == true ? nickName! : username);
            result[username] = displayName;
          }
        } catch (e) {
        }

        // 2. 对于没找到的，从 stranger 表查询
        var notFoundUsernames = usernames.where((u) => !result.containsKey(u)).toList();
        if (notFoundUsernames.isNotEmpty) {
          try {
            final strangerPlaceholders = List.filled(notFoundUsernames.length, '?').join(',');
            final strangerRows = await contactDb.rawQuery('''
              SELECT username, remark, nick_name 
              FROM stranger 
              WHERE username IN ($strangerPlaceholders)
            ''', notFoundUsernames);

            for (final row in strangerRows) {
              final username = row['username'] as String;
              final remark = row['remark'] as String?;
              final nickName = row['nick_name'] as String?;
              final displayName = remark?.isNotEmpty == true 
                  ? remark! 
                  : (nickName?.isNotEmpty == true ? nickName! : username);
              result[username] = displayName;
            }
          } catch (e) {
          }
        }

        // 3. 对于仍然没找到的群聊，尝试模糊匹配
        notFoundUsernames = usernames.where((u) => !result.containsKey(u)).toList();
        if (notFoundUsernames.isNotEmpty) {
          final chatroomUsernames = notFoundUsernames.where((u) => u.contains('@chatroom')).toList();
          
          for (final username in chatroomUsernames) {
            try {
              final chatroomId = username.split('@').first;
              final rows = await contactDb.rawQuery(
                'SELECT username, remark, nick_name FROM contact WHERE username LIKE ? LIMIT 1',
                ['%$chatroomId%']
              );
              
              if (rows.isNotEmpty) {
                final row = rows.first;
                final remark = row['remark'] as String?;
                final nickName = row['nick_name'] as String?;
                
                String displayName;
                if (remark?.isNotEmpty == true) {
                  displayName = remark!;
                } else if (nickName?.isNotEmpty == true) {
                  displayName = nickName!;
                } else {
                  // 群聊没有名称，使用成员列表生成（仿微信）
                  displayName = await _getChatroomDisplayName(username, contactDb);
                }
                
                result[username] = displayName;
                
              }
            } catch (e) {
              // 忽略单个查询错误
            }
          }
        }
        
        // 4. 对于还是没找到的，尝试从 Name2Id 表查询（消息数据库中）
        notFoundUsernames = usernames.where((u) => !result.containsKey(u)).toList();
        if (notFoundUsernames.isNotEmpty) {
          try {
            final Database dbForMsg = await _getDbForMessages();
            for (final username in notFoundUsernames) {
              try {
                final rows = await dbForMsg.rawQuery(
                  'SELECT user_name FROM Name2Id WHERE user_name LIKE ? LIMIT 1',
                  ['%$username%']
                );
                if (rows.isNotEmpty) {
                  final foundName = rows.first['user_name'] as String?;
                  if (foundName != null) {
                    // 使用找到的名称（可能包含更完整的信息）
                    result[username] = foundName;
                  }
                }
              } catch (e) {
                // 忽略单个查询错误
              }
            }
          } catch (e) {
          }
        }

        if (kDebugMode && result.length < usernames.length) {
          // 部分用户未找到显示名
        }

        await contactDb.close();
        return result;
      } finally {
        await contactDb.close();
      }
    } catch (e) {
      return {};
    }
  }

  /// 获取数据库中所有表名（调试用）
  Future<List<String>> getAllTableNames() async {
    if (_sessionDb == null) {
      throw Exception('数据库未连接');
    }

    try {
      final tables = await _sessionDb!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      );
      
      return tables.map((t) => t['name'] as String).toList();
    } catch (e) {
      throw Exception('获取表列表失败: $e');
    }
  }

  /// 诊断会话-消息表映射关系
  Future<Map<String, dynamic>> diagnoseSessionMessageMapping(String sessionId) async {
    final result = <String, dynamic>{
      'sessionId': sessionId,
      'md5': _md5(sessionId),
      'expectedTableName': 'Msg_${_md5(sessionId)}',
      'foundInDatabases': <Map<String, dynamic>>[],
      'name2IdExists': false,
      'allMessageTables': <String>[],
    };

    try {
      final allMessageDbs = await _findAllMessageDbs();
      
      for (final dbPath in allMessageDbs) {
        try {
          final tempDb = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          
          try {
            // 检查 Name2Id
            final name2IdRows = await tempDb.rawQuery(
              'SELECT rowid FROM Name2Id WHERE user_name = ? LIMIT 1',
              [sessionId]
            );
            
            if (name2IdRows.isNotEmpty) {
              result['name2IdExists'] = true;
              result['name2IdRowId'] = name2IdRows.first['rowid'];
            }
            
            // 获取所有消息表
            final tables = await tempDb.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'"
            );
            
            final tableNames = tables.map((t) => t['name'] as String).toList();
            (result['allMessageTables'] as List<String>).addAll(tableNames);
            
            // 查找匹配的表
            final foundTableName = await _getMessageTableName(sessionId, tempDb);
            if (foundTableName != null) {
              (result['foundInDatabases'] as List<Map<String, dynamic>>).add({
                'database': dbPath,
                'tableName': foundTableName,
              });
            }
          } finally {
            await tempDb.close();
          }
        } catch (e) {
          // 检查数据库出错
        }
      }
    } catch (e) {
      result['error'] = e.toString();
    }

    return result;
  }

  /// 从联系人表获取会话信息
  Future<List<ChatSession>> _getSessionsFromContactTable(List<String> tableNames) async {
    final db = _currentDb;
    try {
      String contactTableName = 'contact';
      if (tableNames.contains('Contact')) {
        contactTableName = 'Contact';
      }
      
      final List<Map<String, dynamic>> maps = await db!.query(
        contactTableName,
        columns: ['username', 'nick_name', 'remark', 'big_head_url'],
        where: 'local_type = ?',
        whereArgs: [1], // 只获取好友联系人
      );

      return maps.map((map) {
        return ChatSession(
          username: map['username'] as String? ?? '',
          type: 0, // 私聊
          unreadCount: 0,
          unreadFirstMsgSrvId: 0,
          isHidden: 0,
          summary: '暂无消息',
          draft: '',
          status: 0,
          lastTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          sortTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          lastClearUnreadTimestamp: 0,
          lastMsgLocalId: 0,
          lastMsgType: 1, // 文本消息
          lastMsgSubType: 0,
          lastMsgSender: '',
          lastSenderDisplayName: map['remark'] as String? ?? map['nick_name'] as String? ?? '未知联系人',
        );
      }).toList();
    } catch (e) {
      throw Exception('从联系人表获取会话失败: $e');
    }
  }

  /// 从FMessageTable获取会话信息
  Future<List<ChatSession>> _getSessionsFromFMessageTable() async {
    final db = _currentDb;
    try {
      final List<Map<String, dynamic>> maps = await db!.query(
        'FMessageTable',
        columns: ['user_name_', 'content_', 'timestamp_'],
        orderBy: 'timestamp_ DESC',
      );

      // 按用户名分组，获取每个联系人的最新消息
      final Map<String, Map<String, dynamic>> userMessages = {};
      for (final map in maps) {
        final userName = map['user_name_'] as String? ?? '';
        if (userName.isNotEmpty && !userMessages.containsKey(userName)) {
          userMessages[userName] = map;
        }
      }

      return userMessages.values.map((map) {
        final timestamp = map['timestamp_'] as int? ?? 0;
        return ChatSession(
          username: map['user_name_'] as String? ?? '',
          type: 0, // 私聊
          unreadCount: 0,
          unreadFirstMsgSrvId: 0,
          isHidden: 0,
          summary: map['content_'] as String? ?? '暂无消息',
          draft: '',
          status: 0,
          lastTimestamp: timestamp,
          sortTimestamp: timestamp,
          lastClearUnreadTimestamp: 0,
          lastMsgLocalId: 0,
          lastMsgType: 1, // 文本消息
          lastMsgSubType: 0,
          lastMsgSender: '',
          lastSenderDisplayName: map['user_name_'] as String? ?? '未知联系人',
        );
      }).toList();
    } catch (e) {
      throw Exception('从FMessageTable获取会话失败: $e');
    }
  }

  /// 获取群聊显示名称（仿微信逻辑）
  Future<String> _getChatroomDisplayName(String chatroomId, Database contactDb) async {
    try {
      // 1. 查询群聊成员
      final memberRows = await contactDb.rawQuery('''
        SELECT member_id FROM chatroom_member 
        WHERE room_id = (SELECT rowid FROM name2id WHERE username = ?) 
        LIMIT 3
      ''', [chatroomId]);
      
      if (memberRows.isEmpty) {
        return chatroomId; // 没有成员信息，返回原ID
      }
      
      // 2. 获取总成员数
      final countRows = await contactDb.rawQuery('''
        SELECT COUNT(*) as total FROM chatroom_member 
        WHERE room_id = (SELECT rowid FROM name2id WHERE username = ?)
      ''', [chatroomId]);
      final totalCount = countRows.first['total'] as int? ?? memberRows.length;
      
      // 3. 查询成员显示名称
      final memberNames = <String>[];
      for (final row in memberRows) {
        final memberId = row['member_id'] as int?;
        if (memberId == null) continue;
        
        // 从 name2id 获取 username
        final usernameRows = await contactDb.rawQuery(
          'SELECT username FROM name2id WHERE rowid = ?', 
          [memberId]
        );
        
        if (usernameRows.isNotEmpty) {
          final username = usernameRows.first['username'] as String?;
          if (username != null) {
            // 查询显示名称
            var displayName = username;
            
            // 先从 contact 查
            final contactRows = await contactDb.rawQuery(
              'SELECT remark, nick_name FROM contact WHERE username = ?',
              [username]
            );
            
            if (contactRows.isNotEmpty) {
              final remark = contactRows.first['remark'] as String?;
              final nickName = contactRows.first['nick_name'] as String?;
              displayName = remark?.isNotEmpty == true ? remark! : 
                           (nickName?.isNotEmpty == true ? nickName! : username);
            } else {
              // 再从 stranger 查
              final strangerRows = await contactDb.rawQuery(
                'SELECT remark, nick_name FROM stranger WHERE username = ?',
                [username]
              );
              if (strangerRows.isNotEmpty) {
                final remark = strangerRows.first['remark'] as String?;
                final nickName = strangerRows.first['nick_name'] as String?;
                displayName = remark?.isNotEmpty == true ? remark! : 
                             (nickName?.isNotEmpty == true ? nickName! : username);
              }
            }
            
            memberNames.add(displayName);
          }
        }
      }
      
      // 4. 格式化显示名称
      if (memberNames.isEmpty) {
        return chatroomId;
      }
      
      final displayName = memberNames.join('、');
      return totalCount > memberNames.length ? '$displayName($totalCount)' : displayName;
      
    } catch (e) {
      return chatroomId;
    }
  }

  /// 使用联系人信息丰富会话列表
  Future<void> _enrichSessionsWithContactInfo(List<ChatSession> sessions) async {
    try {
      await logger.info('DatabaseService', '开始从contact数据库加载联系人信息，会话数量: ${sessions.length}');
      
      // 尝试连接 contact 数据库（带重试机制）
      final contactDbPath = await _findContactDatabase(retryCount: 3, retryDelayMs: 500);
      if (contactDbPath == null) {
        await logger.warning('DatabaseService', '无法找到contact数据库，会话将显示原始用户名');
        return;
      }

      await logger.info('DatabaseService', '正在打开contact数据库: $contactDbPath');
      
      // 临时连接 contact 数据库
      final contactDb = await _currentFactory.openDatabase(
        contactDbPath,
        options: OpenDatabaseOptions(
          readOnly: true,
          singleInstance: false,
        ),
      );

      try {
        // 获取 contact 数据库的表结构
        final tables = await contactDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        );
        
        // 为每个会话查找对应的联系人信息
        for (final session in sessions) {
          try {
            // 尝试多个可能的表名
            List<Map<String, dynamic>> contactMaps = [];
            
            // 首先尝试 'contact' 表（包括精确匹配和模糊匹配）
            try {
              // 1. 精确匹配
              contactMaps = await contactDb.query(
                'contact',
                where: 'username = ?',
                whereArgs: [session.username],
                limit: 1,
              );
              
              // 2. 如果是群聊且精确匹配失败，尝试模糊匹配
              if (contactMaps.isEmpty && session.username.contains('@chatroom')) {
                // 提取群聊ID部分（去掉@chatroom）
                final chatroomId = session.username.split('@').first;
                contactMaps = await contactDb.rawQuery(
                  'SELECT * FROM contact WHERE username LIKE ? LIMIT 1',
                  ['%$chatroomId%']
                );
                if (contactMaps.isNotEmpty && kDebugMode) {
                  // 模糊匹配找到群聊
                }
              }
            } catch (e) {
              // contact 表查询失败
            }
            
            // 如果 contact 表找不到，尝试 stranger 表
            if (contactMaps.isEmpty) {
              try {
                contactMaps = await contactDb.query(
                  'stranger',
                  where: 'username = ?',
                  whereArgs: [session.username],
                  limit: 1,
                );
              } catch (e) {
                // stranger 表查询失败
              }
            }
            
            // 如果还是找不到，尝试其他包含 'contact' 的表
            if (contactMaps.isEmpty) {
              for (final table in tables) {
                final tableName = table['name'] as String;
                if (tableName.toLowerCase().contains('contact') && 
                    tableName != 'contact' && 
                    tableName != 'stranger') {
                  try {
                    contactMaps = await contactDb.query(
                      tableName,
                      where: 'username = ?',
                      whereArgs: [session.username],
                      limit: 1,
                    );
                    if (contactMaps.isNotEmpty) {
                      break;
                    }
                  } catch (e) {
                    // 继续尝试下一个表
                  }
                }
              }
            }

            if (contactMaps.isNotEmpty) {
              final contact = contactMaps.first;
              
              // 检查联系人类型，过滤掉公众号、服务号等
              final localType = contact['local_type'] as int? ?? 0;
              final username = contact['username'] as String? ?? session.username;
              
              // 过滤条件：只显示正常联系人和群聊
              bool shouldShow = false;
              if (username.contains('@chatroom')) {
                // 群聊
                shouldShow = true;
              } else if (localType == 0 || localType == 1) {
                // 正常联系人 (0=好友, 1=可能是好友)
                shouldShow = true;
              } else if (username.startsWith('wxid_') && !username.contains('@')) {
                // 普通微信用户
                shouldShow = true;
              }
              
              if (shouldShow) {
                // 优先显示备注，没有备注时显示昵称
                String displayName = '';
                final remark = contact['remark'] as String?;
                final nickName = contact['nick_name'] as String?;
                
                if (remark != null && remark.isNotEmpty && remark.trim().isNotEmpty) {
                  displayName = remark.trim();
                } else if (nickName != null && nickName.isNotEmpty && nickName.trim().isNotEmpty) {
                  displayName = nickName.trim();
                } else if (username.contains('@chatroom')) {
                  // 群聊没有名称，使用成员列表生成（仿微信）
                  displayName = await _getChatroomDisplayName(session.username, contactDb);
                } else {
                  displayName = session.username;
                }
                
                // 清理显示名称中的无效字符
                displayName = _cleanDisplayName(displayName);
                
                // 更新会话的显示名称
                session.displayName = displayName;
              }
            }
          } catch (e) {
            // 查找联系人失败
          }
        }
        
        await logger.info('DatabaseService', '成功加载联系人信息，已更新${sessions.where((s) => s.displayName != null && s.displayName!.isNotEmpty).length}个会话的显示名称');
      } finally {
        await contactDb.close();
      }
    } catch (e, stackTrace) {
      await logger.error('DatabaseService', '从contact数据库加载联系人信息失败', e, stackTrace);
    }
  }

  /// 清理显示名称中的无效字符
  String _cleanDisplayName(String name) {
    if (name.isEmpty) return name;
    
    try {
      // 移除控制字符和无效字符
      String cleaned = name.replaceAll(RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F-\x9F]'), '');
      
      // 处理可能的孤立代理对（UTF-16编码问题）
      final codeUnits = cleaned.codeUnits;
      final validUnits = <int>[];
      
      for (int i = 0; i < codeUnits.length; i++) {
        final unit = codeUnits[i];
        
        // 检查高代理（0xD800-0xDBFF）
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          // 高代理必须后跟低代理
          if (i + 1 < codeUnits.length) {
            final nextUnit = codeUnits[i + 1];
            if (nextUnit >= 0xDC00 && nextUnit <= 0xDFFF) {
              // 有效的代理对
              validUnits.add(unit);
              validUnits.add(nextUnit);
              i++; // 跳过下一个字符
              continue;
            }
          }
          // 孤立的高代理，跳过
          continue;
        }
        
        // 检查低代理（0xDC00-0xDFFF）
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
          // 孤立的低代理，跳过
          continue;
        }
        
        // 普通字符
        validUnits.add(unit);
      }
      
      return String.fromCharCodes(validUnits);
    } catch (e) {
      // 如果清理失败，返回一个安全的替代字符串
      return name.replaceAll(RegExp(r'[^\u0020-\u007E\u4E00-\u9FFF\u3000-\u303F]'), '');
    }
  }

  /// 查找 contact 数据库文件（带重试机制）
  Future<String?> _findContactDatabase({int retryCount = 3, int retryDelayMs = 500}) async {
    for (int attempt = 0; attempt < retryCount; attempt++) {
      try {
        final documentsDir = await getApplicationDocumentsDirectory();
        final echoTraceDir = Directory('${documentsDir.path}${Platform.pathSeparator}EchoTrace');
        
        if (!await echoTraceDir.exists()) {
          if (attempt == 0) {
            await logger.warning('DatabaseService', 'EchoTrace目录不存在: ${echoTraceDir.path}');
          }
          if (attempt < retryCount - 1) {
            await Future.delayed(Duration(milliseconds: retryDelayMs));
            continue;
          }
          return null;
        }
        
        final wxidDirs = await echoTraceDir.list().where((entity) {
          return entity is Directory && 
                 entity.path.split(Platform.pathSeparator).last.startsWith('wxid_');
        }).toList();
        
        if (wxidDirs.isEmpty) {
          if (attempt == 0) {
            await logger.warning('DatabaseService', '未找到任何wxid目录');
          }
          if (attempt < retryCount - 1) {
            await Future.delayed(Duration(milliseconds: retryDelayMs));
            continue;
          }
          return null;
        }
        
        for (final wxidDir in wxidDirs) {
          final contactDbPath = '${wxidDir.path}${Platform.pathSeparator}contact.db';
          final contactDbFile = File(contactDbPath);

          if (await contactDbFile.exists()) {
            await logger.info('DatabaseService', '找到contact数据库: $contactDbPath');
            return contactDbPath;
          }
        }
        
        if (attempt == 0) {
          await logger.warning('DatabaseService', '在所有wxid目录中都未找到contact.db');
        }
        
        if (attempt < retryCount - 1) {
          await logger.info('DatabaseService', '将在${retryDelayMs}ms后重试查找contact.db（第${attempt + 1}次尝试失败）');
          await Future.delayed(Duration(milliseconds: retryDelayMs));
        }
      } catch (e, stackTrace) {
        await logger.error('DatabaseService', '查找contact数据库失败（尝试${attempt + 1}/$retryCount）', e, stackTrace);
        if (attempt < retryCount - 1) {
          await Future.delayed(Duration(milliseconds: retryDelayMs));
        }
      }
    }
    
    await logger.warning('DatabaseService', '经过$retryCount次尝试，仍未找到contact数据库');
    return null;
  }

  /// 获取用于消息查询的数据库
  Future<dynamic> _getDbForMessages() async {
    final db = _currentDb;
    // 如果会话库本身就包含消息表，直接使用
    if (await _hasMsgTables(db)) {
      return db;
    }


    // 懒加载消息库（仅解密模式）
    if (_messageDb != null) return _messageDb!;

    final messageDbPath = await _locateMessageDbPathNearSession();
    if (messageDbPath == null) {
      throw Exception('未找到消息数据库');
    }
    _messageDb = await _currentFactory.openDatabase(
      messageDbPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    return _messageDb!;
  }

  Future<bool> _hasMsgTables(dynamic db) async {
    if (db == null) return false;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
    );
    return tables.isNotEmpty;
  }

  /// 查找所有可用的消息数据库路径
  Future<List<String>> _findAllMessageDbs() async {
    final List<String> messageDbs = [];
    
    // 优先基于会话库所在 wxid 目录
    if (_sessionDbPath != null) {
      final wxidDir = _findWxidDirFromPath(_sessionDbPath!);
      if (wxidDir != null) {
        // 查找所有 message_[0-9].db 文件
        for (int i = 0; i < 9; i++) {
          final candidate = File('${wxidDir.path}${Platform.pathSeparator}message_${i}.db');
        if (await candidate.exists()) {
            messageDbs.add(candidate.path);
          }
        }
        
        if (messageDbs.isNotEmpty) {
          return messageDbs;
        }
      }
    }

    // 兜底：扫描 EchoTrace 目录
    final documentsDir = await getApplicationDocumentsDirectory();
    final echoTraceDir = Directory('${documentsDir.path}${Platform.pathSeparator}EchoTrace');
    if (!await echoTraceDir.exists()) return messageDbs;

    final wxidDirs = await echoTraceDir.list().where((e) => e is Directory).toList();
    for (final dir in wxidDirs) {
      for (int i = 0; i < 100; i++) {
        final messageDbFile = File('${dir.path}${Platform.pathSeparator}message_${i}.db');
        if (await messageDbFile.exists()) {
          messageDbs.add(messageDbFile.path);
        }
      }
    }
    
    return messageDbs;
  }

  Future<String?> _locateMessageDbPathNearSession() async {
    final allDbs = await _findAllMessageDbs();
    if (allDbs.isEmpty) return null;
    
    // 返回第一个
    return allDbs.first;
  }

  String? _extractWxidFromPath(String path) {
    final parts = path.split(Platform.pathSeparator);
    final idx = parts.lastIndexWhere((p) => p.startsWith('wxid_'));
    if (idx != -1) return parts[idx];
    return null;
  }

  Directory? _findWxidDirFromPath(String path) {
    final dir = Directory(path).parent;
    if (dir.path.split(Platform.pathSeparator).last.startsWith('wxid_')) {
      return dir;
    }
    return null;
  }

  /// 清理缓存的数据库连接（可手动调用或自动触发）
  Future<void> clearDatabaseCache() async {
    for (final db in _cachedMessageDbs.values) {
      try {
        await db.close();
      } catch (e) {
        // 忽略关闭错误
      }
    }
    _cachedMessageDbs.clear();
    _cacheLastUsed = null;
  }

  /// 获取或打开缓存的消息数据库连接
  Future<List<_CachedDatabaseInfo>> _getCachedMessageDatabases() async {
    // 检查缓存是否过期
    if (_cacheLastUsed != null && 
        DateTime.now().difference(_cacheLastUsed!) > _cacheDuration) {
      await clearDatabaseCache();
    }

    // 更新最后使用时间
    _cacheLastUsed = DateTime.now();

    // 如果缓存为空，打开所有数据库
    if (_cachedMessageDbs.isEmpty) {
      final allMessageDbPaths = await _findAllMessageDbs();
      
      // 获取所有唯一的数据库路径（去重）
      final uniquePaths = allMessageDbPaths.toSet().toList();
      
      // 打开所有消息数据库
      for (int i = 0; i < uniquePaths.length; i++) {
        final dbPath = uniquePaths[i];
        try {
          final db = await _currentFactory.openDatabase(
            dbPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          _cachedMessageDbs[dbPath] = db;
        } catch (e) {
          // 忽略打开失败的数据库
        }
      }
      
      // 如果没有打开任何数据库，添加当前数据库作为后备
      if (_cachedMessageDbs.isEmpty) {
        try {
          final currentDb = await _getDbForMessages();
          _cachedMessageDbs['_current'] = currentDb;
        } catch (e) {
          // 忽略错误
        }
      }
    }

    // 构建缓存信息列表
    final result = <_CachedDatabaseInfo>[];
    for (final entry in _cachedMessageDbs.entries) {
      result.add(_CachedDatabaseInfo(
        database: entry.value,
        key: entry.key,
      ));
    }
    
    return result;
  }

  /// 通用的跨数据库查询辅助方法
  Future<List<_DatabaseTableInfo>> _collectTableInfosAcrossDatabases(
    String sessionId, 
    {bool includeLatestTimestamp = false}
  ) async {
    final result = <_DatabaseTableInfo>[];
    final seenTables = <String>{};
    final cachedDbs = await _getCachedMessageDatabases();

    for (final dbInfo in cachedDbs) {
      try {
        final tableName = await _getMessageTableName(
          sessionId, 
          dbInfo.database,
        );
        
        // 避免重复的表名
        if (tableName != null && !seenTables.contains(tableName)) {
          seenTables.add(tableName);
          
          int latestTimestamp = 0;
          if (includeLatestTimestamp) {
            try {
              final timeResult = await dbInfo.database.rawQuery(
                'SELECT MAX(create_time) as max_time FROM $tableName'
              );
              latestTimestamp = (timeResult.first['max_time'] as int?) ?? 0;
            } catch (e) {
              // 忽略错误
            }
          }
          
          result.add(_DatabaseTableInfo(
            database: dbInfo.database,
            tableName: tableName,
            latestTimestamp: latestTimestamp,
            needsClose: false, // 使用缓存，不需要关闭
          ));
        }
      } catch (e) {
        // 忽略错误，继续下一个数据库
      }
    }

    return result;
  }

  /// 获取活动热力图数据（24小时×7天）
  Future<Map<int, Map<int, int>>> getActivityHeatmapData({
    int? year,
    List<String>? sessionIds,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    // 初始化数据结构
    final data = <int, Map<int, int>>{};
    for (int hour = 0; hour < 24; hour++) {
      data[hour] = {};
      for (int weekday = 1; weekday <= 7; weekday++) {
        data[hour]![weekday] = 0;
      }
    }

    try {
      final cachedDbs = await _getCachedMessageDatabases();
      final seenTables = <String>{};

      for (final cachedDb in cachedDbs) {
        try {
          // 查找所有消息表
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final tableRow in tables) {
            final tableName = tableRow['name'] as String;
            if (seenTables.contains(tableName)) continue;
            seenTables.add(tableName);

            // 如果指定了sessionIds，只查询这些会话
            String whereClause = '';
            if (sessionIds != null && sessionIds.isNotEmpty) {
              // 从表名提取MD5，与sessionIds比对（需要逆向查找）
              // 这里简化处理，查询所有然后过滤
            }

            // 构建年份过滤条件
            if (year != null) {
              final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
              final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
              whereClause = 'WHERE create_time >= $startTime AND create_time < $endTime';
            }

            // 单次SQL查询获取所有时段统计
            final result = await cachedDb.database.rawQuery('''
              SELECT 
                CAST(strftime('%H', create_time, 'unixepoch', 'localtime') AS INTEGER) as hour,
                CASE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER) 
                  WHEN 0 THEN 7 
                  ELSE CAST(strftime('%w', create_time, 'unixepoch', 'localtime') AS INTEGER) 
                END as weekday,
                COUNT(*) as count
              FROM $tableName
              $whereClause
              GROUP BY hour, weekday
            ''');

            for (final row in result) {
              final hour = row['hour'] as int;
              final weekday = row['weekday'] as int;
              final count = row['count'] as int;
              data[hour]![weekday] = (data[hour]![weekday] ?? 0) + count;
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }
    } catch (e) {
      await logger.error('DatabaseService', '获取活动热力图数据失败', e);
      rethrow;
    }

    return data;
  }

  /// 获取最频繁联系人数据
  Future<List<Map<String, dynamic>>> getTopContactsData({
    required int limit,
    int? year,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    final contactStats = <String, Map<String, dynamic>>{};

    try {
      final cachedDbs = await _getCachedMessageDatabases();
      final seenTables = <String>{};

      for (final cachedDb in cachedDbs) {
        try {
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final tableRow in tables) {
            final tableName = tableRow['name'] as String;
            if (seenTables.contains(tableName)) continue;
            seenTables.add(tableName);

            // 构建年份过滤条件
            String whereClause = '';
            if (year != null) {
              final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
              final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
              whereClause = 'WHERE create_time >= $startTime AND create_time < $endTime';
            }

            // 获取该表的统计数据
            final result = await cachedDb.database.rawQuery('''
              SELECT 
                COUNT(*) as total,
                SUM(CASE WHEN real_sender_id = 1 THEN 1 ELSE 0 END) as sent,
                SUM(CASE WHEN real_sender_id != 1 THEN 1 ELSE 0 END) as received,
                MAX(create_time) as last_time
              FROM $tableName
              $whereClause
            ''');

            if (result.isNotEmpty && result[0]['total'] != null) {
              final total = result[0]['total'] as int;
              if (total > 0) {
                // 从表名提取会话ID（需要反查Name2Id表）
                // 这里简化处理，直接使用表名
                final sessionId = tableName; // 临时使用表名，实际需要反查

                if (!contactStats.containsKey(sessionId)) {
                  contactStats[sessionId] = {
                    'sessionId': sessionId,
                    'total': 0,
                    'sent': 0,
                    'received': 0,
                    'lastTime': 0,
                  };
                }

                contactStats[sessionId]!['total'] = (contactStats[sessionId]!['total'] as int) + total;
                contactStats[sessionId]!['sent'] = (contactStats[sessionId]!['sent'] as int) + (result[0]['sent'] as int? ?? 0);
                contactStats[sessionId]!['received'] = (contactStats[sessionId]!['received'] as int) + (result[0]['received'] as int? ?? 0);
                
                final lastTime = result[0]['last_time'] as int? ?? 0;
                if (lastTime > (contactStats[sessionId]!['lastTime'] as int)) {
                  contactStats[sessionId]!['lastTime'] = lastTime;
                }
              }
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }

      // 排序并返回top N
      final sortedContacts = contactStats.values.toList()
        ..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int));

      return sortedContacts.take(limit).toList();
    } catch (e) {
      await logger.error('DatabaseService', '获取最频繁联系人数据失败', e);
      rethrow;
    }
  }

  /// 获取所有私聊会话的活动数据（用于热力图等）
  Future<List<Map<String, dynamic>>> getAllPrivateSessionsActivity({
    int? year,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    try {
      // 获取所有私聊会话
      final sessions = await getSessions();
      final privateSessions = sessions.where((s) => !s.isGroup).map((s) => s.username).toList();

      // 使用批量查询获取统计
      final batchStats = await getBatchSessionStats(privateSessions);

      // 如果有年份过滤，需要重新查询（带年份条件）
      if (year != null) {
        final filteredStats = <Map<String, dynamic>>[];
        final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;

        for (final sessionId in privateSessions) {
          try {
            final dbInfos = await _collectTableInfosAcrossDatabases(sessionId);
            int totalMessages = 0;

            for (final dbInfo in dbInfos) {
              final result = await dbInfo.database.rawQuery('''
                SELECT COUNT(*) as count
                FROM ${dbInfo.tableName}
                WHERE create_time >= $startTime AND create_time < $endTime
              ''');

              if (result.isNotEmpty && result[0]['count'] != null) {
                totalMessages += result[0]['count'] as int;
              }
            }

            if (totalMessages > 0) {
              filteredStats.add({
                'sessionId': sessionId,
                'total': totalMessages,
              });
            }
          } catch (e) {
            // 忽略单个会话的错误
          }
        }

        return filteredStats;
      }

      // 无年份过滤，返回完整统计
      return batchStats.entries.map((e) => {
        'sessionId': e.key,
        ...e.value,
      }).toList();
    } catch (e) {
      await logger.error('DatabaseService', '获取所有私聊会话活动数据失败', e);
      rethrow;
    }
  }

  /// 获取文本消息长度统计
  Future<Map<String, dynamic>> getTextMessageLengthStats({
    int? year,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    try {
      final cachedDbs = await _getCachedMessageDatabases();
      final seenTables = <String>{};
      
      int totalLength = 0;
      int textMessageCount = 0;
      int longestLength = 0;
      Map<String, dynamic>? longestMessage;

      // 构建年份过滤条件
      String whereClause = 'WHERE real_sender_id = 1 AND local_type IN (1, 244813135921)';
      if (year != null) {
        final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
        final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
        whereClause += ' AND create_time >= $startTime AND create_time < $endTime';
      }

      for (final cachedDb in cachedDbs) {
        try {
          final tables = await cachedDb.database.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'",
          );

          for (final tableRow in tables) {
            final tableName = tableRow['name'] as String;
            if (seenTables.contains(tableName)) continue;
            seenTables.add(tableName);

            // 统计总长度和数量
            final statsResult = await cachedDb.database.rawQuery('''
              SELECT 
                SUM(LENGTH(display_content)) as total_length,
                COUNT(*) as count
              FROM $tableName
              $whereClause
              AND display_content IS NOT NULL 
              AND display_content != ''
              AND display_content NOT LIKE '[%'
            ''');

            if (statsResult.isNotEmpty && statsResult[0]['count'] != null) {
              final count = statsResult[0]['count'] as int;
              final length = statsResult[0]['total_length'] as int? ?? 0;
              
              totalLength += length;
              textMessageCount += count;
            }

            // 查找该表中最长的消息
            final longestResult = await cachedDb.database.rawQuery('''
              SELECT 
                display_content,
                LENGTH(display_content) as len,
                create_time
              FROM $tableName
              $whereClause
              AND display_content IS NOT NULL 
              AND display_content != ''
              AND display_content NOT LIKE '[%'
              ORDER BY len DESC
              LIMIT 1
            ''');

            if (longestResult.isNotEmpty) {
              final len = longestResult[0]['len'] as int? ?? 0;
              if (len > longestLength) {
                longestLength = len;
                longestMessage = {
                  'content': longestResult[0]['display_content'] as String,
                  'length': len,
                  'createTime': longestResult[0]['create_time'] as int,
                  'tableName': tableName,
                };
              }
            }
          }
        } catch (e) {
          // 忽略单个数据库的错误
        }
      }

      return {
        'totalLength': totalLength,
        'textMessageCount': textMessageCount,
        'averageLength': textMessageCount > 0 ? totalLength / textMessageCount : 0.0,
        'longestLength': longestLength,
        'longestMessage': longestMessage,
      };
    } catch (e) {
      await logger.error('DatabaseService', '获取文本消息长度统计失败', e);
      rethrow;
    }
  }

  /// 分析响应速度（谁回复我最快）
  Future<List<Map<String, dynamic>>> analyzeResponseSpeed({
    required bool isMyResponse, // true: 我回复对方, false: 对方回复我
    int? year,
    Function(int current, int total, String currentUser)? onProgress,
  }) async {
    if (!isConnected) {
      throw Exception('数据库未连接');
    }

    try {
      final sessions = await getSessions();
      final privateSessions = sessions.where((s) => !s.isGroup).toList();
      final displayNames = await getDisplayNames(privateSessions.map((s) => s.username).toList());
      
      final results = <Map<String, dynamic>>[];

      for (int idx = 0; idx < privateSessions.length; idx++) {
        final session = privateSessions[idx];
        
        // 报告进度
        onProgress?.call(idx + 1, privateSessions.length, displayNames[session.username] ?? session.username);
        try {
          final dbInfos = await _collectTableInfosAcrossDatabases(session.username);
          final responseTimes = <double>[];

          for (final dbInfo in dbInfos) {
            // 构建年份过滤条件
            String whereClause = '';
            if (year != null) {
              final startTime = DateTime(year, 1, 1).millisecondsSinceEpoch ~/ 1000;
              final endTime = DateTime(year + 1, 1, 1).millisecondsSinceEpoch ~/ 1000;
              whereClause = 'WHERE create_time >= $startTime AND create_time < $endTime';
            }

            // 简化方案：直接查询所有消息，在内存中处理
            // 但只查询发送者和时间，减少数据传输
            final query = '''
              SELECT create_time, real_sender_id
              FROM ${dbInfo.tableName}
              ${whereClause}
              ORDER BY create_time ASC
            ''';

            final rows = await dbInfo.database.rawQuery(query);
            
            // 在内存中快速处理相邻消息
            for (int i = 0; i < rows.length - 1; i++) {
              final current = rows[i];
              final next = rows[i + 1];
              
              final currentSenderId = current['real_sender_id'] as int;
              final nextSenderId = next['real_sender_id'] as int;
              
              // 检查是否符合响应模式
              final isMatch = isMyResponse
                  ? (currentSenderId != 1 && nextSenderId == 1)
                  : (currentSenderId == 1 && nextSenderId != 1);
              
              if (isMatch) {
                final currentTime = current['create_time'] as int;
                final nextTime = next['create_time'] as int;
                final timeDiff = (nextTime - currentTime) / 60.0; // 转换为分钟
                
                // 过滤24小时内的响应
                if (timeDiff > 0 && timeDiff <= 1440) {
                  responseTimes.add(timeDiff);
                }
              }
            }
          }

          if (responseTimes.isNotEmpty) {
            final avgTime = responseTimes.reduce((a, b) => a + b) / responseTimes.length;
            final fastest = responseTimes.reduce((a, b) => a < b ? a : b);
            final slowest = responseTimes.reduce((a, b) => a > b ? a : b);

            results.add({
              'username': session.username,
              'displayName': displayNames[session.username] ?? session.username,
              'avgResponseTimeMinutes': avgTime,
              'totalResponses': responseTimes.length,
              'fastestResponseMinutes': fastest,
              'slowestResponseMinutes': slowest,
            });
          }
        } catch (e) {
          // 忽略单个会话的错误
          continue;
        }
      }

      // 按平均响应时间排序（从快到慢）
      results.sort((a, b) => (a['avgResponseTimeMinutes'] as double)
          .compareTo(b['avgResponseTimeMinutes'] as double));

      return results;
    } catch (e) {
      await logger.error('DatabaseService', '分析响应速度失败', e);
      rethrow;
    }
  }

}

/// 数据库表信息（用于消息查询优先级排序）
class _DatabaseTableInfo {
  final Database database;
  final String tableName;
  final int latestTimestamp;
  final bool needsClose;

  _DatabaseTableInfo({
    required this.database,
    required this.tableName,
    required this.latestTimestamp,
    required this.needsClose,
  });
}

/// 缓存的数据库信息
class _CachedDatabaseInfo {
  final Database database;
  final String key;

  _CachedDatabaseInfo({
    required this.database,
    required this.key,
  });
}
