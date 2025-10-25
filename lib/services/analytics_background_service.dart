import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../services/database_service.dart';
import '../services/advanced_analytics_service.dart';
import '../services/response_time_analyzer.dart';
import '../models/advanced_analytics_data.dart';

/// Isolate 通信消息
class _AnalyticsMessage {
  final String type; // 'progress' | 'error' | 'done'
  final String? stage; // 当前分析阶段
  final int? current;
  final int? total;
  final String? detail; // 详细信息
  final int? elapsedSeconds; // 已用时间（秒）
  final int? estimatedRemainingSeconds; // 预估剩余时间（秒）
  final dynamic result;
  final String? error;

  _AnalyticsMessage({
    required this.type,
    this.stage,
    this.current,
    this.total,
    this.detail,
    this.elapsedSeconds,
    this.estimatedRemainingSeconds,
    this.result,
    this.error,
  });
}

/// 分析任务参数
class _AnalyticsTask {
  final String dbPath;
  final String? filterUsername; // 如果指定，只分析特定用户
  final int? filterYear;
  final String analysisType;
  final SendPort sendPort;
  final RootIsolateToken rootIsolateToken;

  _AnalyticsTask({
    required this.dbPath,
    this.filterUsername,
    this.filterYear,
    required this.analysisType,
    required this.sendPort,
    required this.rootIsolateToken,
  });
}

/// 分析进度回调函数类型
/// 用来实时报告分析进度和状态信息
///
/// 参数说明：
/// - [stage]: 当前分析阶段的描述（如"加载数据"、"处理用户"等）
/// - [current]: 当前进度值
/// - [total]: 总进度值
/// - [detail]: 详细信息，比如当前正在处理哪个用户
/// - [elapsedSeconds]: 已经用去的时间（秒）
/// - [estimatedRemainingSeconds]: 预计还需的时间（秒）
typedef AnalyticsProgressCallback = void Function(
  String stage,
  int current,
  int total, {
  String? detail,
  int? elapsedSeconds,
  int? estimatedRemainingSeconds,
});

/// 后台分析服务（使用独立Isolate）
/// 通过独立的Isolate执行数据库操作，避免阻塞主线程
/// 所有分析任务都在后台运行，只返回最终结果
class AnalyticsBackgroundService {
  final String dbPath;

  AnalyticsBackgroundService(this.dbPath);
  /// 在后台分析作息规律
  Future<ActivityHeatmap> analyzeActivityPatternInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'activity',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return ActivityHeatmap.fromJson(result);
  }

  /// 在后台分析语言风格
  Future<LinguisticStyle> analyzeLinguisticStyleInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'linguistic',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return LinguisticStyle.fromJson(result);
  }

  /// 在后台分析哈哈哈报告
  Future<Map<String, dynamic>> analyzeHahaReportInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    return await _runAnalysisInIsolate(
      analysisType: 'haha',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
  }

  /// 在后台查找深夜密谈之王
  Future<Map<String, dynamic>> findMidnightChatKingInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    return await _runAnalysisInIsolate(
      analysisType: 'midnight',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
  }

  /// 在后台生成亲密度日历
  Future<IntimacyCalendar> generateIntimacyCalendarInBackground(
    String username,
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'intimacy',
      filterUsername: username,
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    
    // 反序列化 DateTime
    final dailyMessages = <DateTime, int>{};
    final dailyMessagesRaw = result['dailyMessages'] as Map<String, dynamic>;
    dailyMessagesRaw.forEach((key, value) {
      dailyMessages[DateTime.parse(key)] = value as int;
    });
    
    return IntimacyCalendar(
      username: result['username'] as String,
      dailyMessages: dailyMessages,
      startDate: DateTime.parse(result['startDate'] as String),
      endDate: DateTime.parse(result['endDate'] as String),
      maxDailyCount: result['maxDailyCount'] as int,
    );
  }

  /// 在后台分析对话天平
  Future<ConversationBalance> analyzeConversationBalanceInBackground(
    String username,
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'balance',
      filterUsername: username,
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    
    return ConversationBalance(
      username: result['username'] as String,
      sentCount: result['sentCount'] as int,
      receivedCount: result['receivedCount'] as int,
      sentWords: result['sentWords'] as int,
      receivedWords: result['receivedWords'] as int,
      initiatedByMe: result['initiatedByMe'] as int,
      initiatedByOther: result['initiatedByOther'] as int,
      conversationSegments: result['conversationSegments'] as int,
      segmentsInitiatedByMe: result['segmentsInitiatedByMe'] as int,
      segmentsInitiatedByOther: result['segmentsInitiatedByOther'] as int,
    );
  }

  /// 在后台分析谁回复我最快
  Future<List<Map<String, dynamic>>> analyzeWhoRepliesFastestInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'who_replies_fastest',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    
    return (result['results'] as List).cast<Map<String, dynamic>>();
  }

  /// 在后台分析我回复谁最快
  Future<List<Map<String, dynamic>>> analyzeMyFastestRepliesInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'my_fastest_replies',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    
    return (result['results'] as List).cast<Map<String, dynamic>>();
  }

  /// 通用 Isolate 分析执行器
  Future<dynamic> _runAnalysisInIsolate({
    required String analysisType,
    String? filterUsername,
    int? filterYear,
    required AnalyticsProgressCallback progressCallback,
  }) async {
    try {
      final receivePort = ReceivePort();
      final task = _AnalyticsTask(
        dbPath: dbPath,
        filterUsername: filterUsername,
        filterYear: filterYear,
        analysisType: analysisType,
        sendPort: receivePort.sendPort,
        rootIsolateToken: ServicesBinding.rootIsolateToken!,
      );

      // 启动 Isolate
      await Isolate.spawn(_analyzeInIsolate, task);

      // 监听进度消息
      dynamic result;
      await for (final message in receivePort) {
        if (message is _AnalyticsMessage) {
          if (message.type == 'progress') {
            progressCallback(
              message.stage ?? '', 
              message.current ?? 0, 
              message.total ?? 100,
              detail: message.detail,
              elapsedSeconds: message.elapsedSeconds,
              estimatedRemainingSeconds: message.estimatedRemainingSeconds,
            );
          } else if (message.type == 'done') {
            result = message.result;
            receivePort.close();
            break;
          } else if (message.type == 'error') {
            receivePort.close();
            throw Exception(message.error);
          }
        }
      }

      return result;
    } catch (e) {
      rethrow;
    }
  }

  /// 后台 Isolate 分析入口函数
  static Future<void> _analyzeInIsolate(_AnalyticsTask task) async {
    try {
      // 初始化 BackgroundIsolateBinaryMessenger（在 Isolate 中必须先初始化）
      BackgroundIsolateBinaryMessenger.ensureInitialized(task.rootIsolateToken);
      
      // 初始化 sqflite_ffi（在 Isolate 中必须重新初始化）
      sqfliteFfiInit();
      // 不全局修改 databaseFactory，而是显式传递给每个操作
      
      final startTime = DateTime.now();

      // 发送初始进度
      task.sendPort.send(_AnalyticsMessage(
        type: 'progress',
        stage: '正在打开数据库...',
        current: 0,
        total: 100,
        elapsedSeconds: 0,
        estimatedRemainingSeconds: 60,
      ));

      // 在 Isolate 中创建数据库服务，显式使用 databaseFactoryFfi
      final dbService = DatabaseService();
      await dbService.initialize(factory: databaseFactoryFfi);
      await dbService.connectDecryptedDatabase(task.dbPath, factory: databaseFactoryFfi);

      // 发送进度更新
      task.sendPort.send(_AnalyticsMessage(
        type: 'progress',
        stage: '正在分析数据...',
        current: 30,
        total: 100,
        elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
        estimatedRemainingSeconds: _estimateRemainingTime(30, 100, startTime),
      ));

      final analyticsService = AdvancedAnalyticsService(dbService);
      if (task.filterYear != null) {
        analyticsService.setYearFilter(task.filterYear);
      }

      dynamic result;

      // 执行不同类型的分析
      switch (task.analysisType) {
        case 'activity':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在分析作息规律...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final data = await analyticsService.analyzeActivityPattern();
          result = data.toJson();
          break;

        case 'linguistic':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在分析语言风格...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final data = await analyticsService.analyzeLinguisticStyle();
          result = data.toJson();
          break;

        case 'haha':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计快乐指数...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          result = await analyticsService.analyzeHahaReport();
          break;

        case 'midnight':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在寻找深夜密谈之王...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          result = await analyticsService.findMidnightChatKing();
          break;

        case 'intimacy':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在生成亲密度日历...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final data = await analyticsService.generateIntimacyCalendar(task.filterUsername!);
          // 转换 DateTime 为 String 以便传递
          result = {
            'username': data.username,
            'dailyMessages': data.dailyMessages.map((k, v) => MapEntry(k.toIso8601String(), v)),
            'startDate': data.startDate.toIso8601String(),
            'endDate': data.endDate.toIso8601String(),
            'maxDailyCount': data.maxDailyCount,
          };
          break;

        case 'balance':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在分析对话天平...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final data = await analyticsService.analyzeConversationBalance(task.filterUsername!);
          result = {
            'username': data.username,
            'sentCount': data.sentCount,
            'receivedCount': data.receivedCount,
            'sentWords': data.sentWords,
            'receivedWords': data.receivedWords,
            'initiatedByMe': data.initiatedByMe,
            'initiatedByOther': data.initiatedByOther,
            'conversationSegments': data.conversationSegments,
            'segmentsInitiatedByMe': data.segmentsInitiatedByMe,
            'segmentsInitiatedByOther': data.segmentsInitiatedByOther,
          };
          break;

        case 'who_replies_fastest':
          final analyzer = ResponseTimeAnalyzer(dbService);
          if (task.filterYear != null) {
            analyzer.setYearFilter(task.filterYear);
          }
          
          final results = await analyzer.analyzeWhoRepliesFastest(
            onProgress: (current, total, username) {
              final elapsed = DateTime.now().difference(startTime).inSeconds;
              task.sendPort.send(_AnalyticsMessage(
                type: 'progress',
                stage: '正在分析响应速度...',
                current: current,
                total: total,
                detail: username,
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: _estimateRemainingTime(current, total, startTime),
              ));
            },
          );
          
          result = {
            'results': results.map((r) => r.toJson()).toList(),
          };
          break;

        case 'my_fastest_replies':
          final analyzer = ResponseTimeAnalyzer(dbService);
          if (task.filterYear != null) {
            analyzer.setYearFilter(task.filterYear);
          }
          
          final results = await analyzer.analyzeMyFastestReplies(
            onProgress: (current, total, username) {
              final elapsed = DateTime.now().difference(startTime).inSeconds;
              task.sendPort.send(_AnalyticsMessage(
                type: 'progress',
                stage: '正在分析我的响应速度...',
                current: current,
                total: total,
                detail: username,
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: _estimateRemainingTime(current, total, startTime),
              ));
            },
          );
          
          result = {
            'results': results.map((r) => r.toJson()).toList(),
          };
          break;

        case 'absoluteCoreFriends':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计绝对核心好友...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          // 获取所有好友统计以计算总数
          final allCoreFriends = await analyticsService.getAbsoluteCoreFriends(999999);
          // 只取前3名用于展示
          final top3 = allCoreFriends.take(3).toList();
          // 计算总消息数和总好友数
          int totalMessages = 0;
          for (var friend in allCoreFriends) {
            totalMessages += friend.count;
          }
          result = {
            'top3': top3.map((e) => e.toJson()).toList(),
            'totalMessages': totalMessages,
            'totalFriends': allCoreFriends.length,
          };
          break;

        case 'confidantObjects':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计年度倾诉对象...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final confidants = await analyticsService.getConfidantObjects(3);
          result = confidants.map((e) => e.toJson()).toList();
          break;

        case 'bestListeners':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计年度最佳听众...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final listeners = await analyticsService.getBestListeners(3);
          result = listeners.map((e) => e.toJson()).toList();
          break;

        case 'mutualFriends':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计双向奔赴好友...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final mutual = await analyticsService.getMutualFriendsRanking(3);
          result = mutual.map((e) => e.toJson()).toList();
          break;

        case 'socialInitiative':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在分析主动社交指数...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final socialStyle = await analyticsService.analyzeSocialInitiativeRate();
          result = socialStyle.toJson();
          break;

        case 'peakChatDay':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计聊天巅峰日...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final peakDay = await analyticsService.analyzePeakChatDay();
          result = peakDay.toJson();
          break;

        case 'longestCheckIn':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计连续打卡记录...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final checkIn = await analyticsService.findLongestCheckInRecord();
          result = {
            'username': checkIn['username'],
            'displayName': checkIn['displayName'],
            'days': checkIn['days'],
            'startDate': (checkIn['startDate'] as DateTime?)?.toIso8601String(),
            'endDate': (checkIn['endDate'] as DateTime?)?.toIso8601String(),
          };
          break;

        case 'messageTypes':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在统计消息类型分布...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final typeStats = await analyticsService.analyzeMessageTypeDistribution();
          result = typeStats.map((e) => e.toJson()).toList();
          break;

        case 'messageLength':
          task.sendPort.send(_AnalyticsMessage(
            type: 'progress',
            stage: '正在分析消息长度...',
            current: 50,
            total: 100,
            elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
            estimatedRemainingSeconds: _estimateRemainingTime(50, 100, startTime),
          ));
          final lengthData = await analyticsService.analyzeMessageLength();
          result = lengthData.toJson();
          break;

        default:
          throw Exception('未知的分析类型: ${task.analysisType}');
      }

      // 发送完成进度
      task.sendPort.send(_AnalyticsMessage(
        type: 'progress',
        stage: '分析完成',
        current: 100,
        total: 100,
        elapsedSeconds: DateTime.now().difference(startTime).inSeconds,
        estimatedRemainingSeconds: 0,
      ));

      // 发送完成消息
      task.sendPort.send(_AnalyticsMessage(
        type: 'done',
        result: result,
      ));

      // 关闭数据库
      // dbService.dispose(); // This line was removed as per the edit hint.
    } catch (e) {
      task.sendPort.send(_AnalyticsMessage(
        type: 'error',
        error: e.toString(),
      ));
    }
  }

  /// 估计剩余时间（秒）
  static int _estimateRemainingTime(int current, int total, DateTime startTime) {
    if (current == 0) return 60;
    final elapsed = DateTime.now().difference(startTime).inSeconds;
    if (elapsed == 0) return 60;
    final totalEstimated = (elapsed * total) ~/ current;
    final remaining = totalEstimated - elapsed;
    return remaining.clamp(1, 3600); // 最少1秒，最多1小时
  }

  /// 绝对核心好友（后台版本）
  Future<Map<String, dynamic>> getAbsoluteCoreFriendsInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'absoluteCoreFriends',
      filterYear: filterYear,
      progressCallback: progressCallback,
    ) as Map<String, dynamic>;
    
    return {
      'top3': (result['top3'] as List).cast<Map<String, dynamic>>()
          .map((e) => FriendshipRanking.fromJson(e))
          .toList(),
      'totalMessages': result['totalMessages'],
      'totalFriends': result['totalFriends'],
    };
  }

  /// 年度倾诉对象（后台版本）
  Future<List<FriendshipRanking>> getConfidantObjectsInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'confidantObjects',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List).cast<Map<String, dynamic>>()
        .map((e) => FriendshipRanking.fromJson(e))
        .toList();
  }

  /// 年度最佳听众（后台版本）
  Future<List<FriendshipRanking>> getBestListenersInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'bestListeners',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List).cast<Map<String, dynamic>>()
        .map((e) => FriendshipRanking.fromJson(e))
        .toList();
  }

  /// 双向奔赴好友（后台版本）
  Future<List<FriendshipRanking>> getMutualFriendsRankingInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'mutualFriends',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List).cast<Map<String, dynamic>>()
        .map((e) => FriendshipRanking.fromJson(e))
        .toList();
  }

  /// 主动社交指数（后台版本）
  Future<SocialStyleData> analyzeSocialInitiativeRateInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'socialInitiative',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return SocialStyleData.fromJson(result);
  }

  /// 年度聊天巅峰日（后台版本）
  Future<ChatPeakDay> analyzePeakChatDayInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'peakChatDay',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return ChatPeakDay.fromJson(result);
  }

  /// 连续打卡记录（后台版本）
  Future<Map<String, dynamic>> findLongestCheckInRecordInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'longestCheckIn',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return result;
  }

  /// 消息类型分布（后台版本）
  Future<List<MessageTypeStats>> analyzeMessageTypeDistributionInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'messageTypes',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return (result as List).cast<Map<String, dynamic>>()
        .map((e) => MessageTypeStats.fromJson(e))
        .toList();
  }

  /// 消息长度分析（后台版本）
  Future<MessageLengthData> analyzeMessageLengthInBackground(
    int? filterYear,
    AnalyticsProgressCallback progressCallback,
  ) async {
    final result = await _runAnalysisInIsolate(
      analysisType: 'messageLength',
      filterYear: filterYear,
      progressCallback: progressCallback,
    );
    return MessageLengthData.fromJson(result);
  }

  /// 生成完整年度报告（并行执行所有任务）
  Future<Map<String, dynamic>> generateFullAnnualReport(
    int? filterYear,
    void Function(String taskName, String status, int progress) progressCallback,
  ) async {
    final taskProgress = <String, int>{};
    final taskStatus = <String, String>{};
    
    // 初始化任务状态
    final taskNames = [
      '绝对核心好友',
      '年度倾诉对象',
      '年度最佳听众',
      '双向奔赴好友',
      '主动社交指数',
      '聊天巅峰日',
      '连续打卡记录',
      '消息类型分布',
      '表达欲分析',
      '作息图谱',
      '深夜密友',
      '最快响应好友',
      '我回复最快',
    ];
    
    for (final name in taskNames) {
      taskProgress[name] = 0;
      taskStatus[name] = '等待中';
    }
    
    // 创建进度回调包装器
    AnalyticsProgressCallback createProgressCallback(String taskName) {
      return (
        String stage,
        int current,
        int total, {
        String? detail,
        int? elapsedSeconds,
        int? estimatedRemainingSeconds,
      }) {
        taskProgress[taskName] = (current / total * 100).toInt();
        taskStatus[taskName] = current >= total ? '已完成' : '进行中';
        
        // 计算总体进度
        final totalProgress = taskProgress.values.reduce((a, b) => a + b) ~/ taskNames.length;
        progressCallback(taskName, taskStatus[taskName]!, totalProgress);
      };
    }
    
    // 串行执行所有任务，避免数据库锁定（一次只执行一个Isolate）
    final coreFriendsData = await getAbsoluteCoreFriendsInBackground(
      filterYear,
      createProgressCallback('绝对核心好友'),
    );
    
    final confidant = await getConfidantObjectsInBackground(
      filterYear,
      createProgressCallback('年度倾诉对象'),
    );
    
    final listeners = await getBestListenersInBackground(
      filterYear,
      createProgressCallback('年度最佳听众'),
    );
    
    final mutualFriends = await getMutualFriendsRankingInBackground(
      filterYear,
      createProgressCallback('双向奔赴好友'),
    );
    
    final socialInitiative = await analyzeSocialInitiativeRateInBackground(
      filterYear,
      createProgressCallback('主动社交指数'),
    );
    
    final peakDay = await analyzePeakChatDayInBackground(
      filterYear,
      createProgressCallback('聊天巅峰日'),
    );
    
    final checkIn = await findLongestCheckInRecordInBackground(
      filterYear,
      createProgressCallback('连续打卡记录'),
    );
    
    final messageTypes = await analyzeMessageTypeDistributionInBackground(
      filterYear,
      createProgressCallback('消息类型分布'),
    );
    
    final messageLength = await analyzeMessageLengthInBackground(
      filterYear,
      createProgressCallback('表达欲分析'),
    );
    
    final activityPattern = await analyzeActivityPatternInBackground(
      filterYear,
      createProgressCallback('作息图谱'),
    );
    
    final midnightKing = await findMidnightChatKingInBackground(
      filterYear,
      createProgressCallback('深夜密友'),
    );
    
    final whoRepliesFastest = await analyzeWhoRepliesFastestInBackground(
      filterYear,
      createProgressCallback('最快响应好友'),
    );
    
    final myFastestReplies = await analyzeMyFastestRepliesInBackground(
      filterYear,
      createProgressCallback('我回复最快'),
    );
    
    // 组装结果
    return {
      'coreFriends': (coreFriendsData['top3'] as List<FriendshipRanking>).map((e) => e.toJson()).toList(),
      'totalMessages': coreFriendsData['totalMessages'],
      'totalFriends': coreFriendsData['totalFriends'],
      'confidant': confidant.map((e) => e.toJson()).toList(),
      'listeners': listeners.map((e) => e.toJson()).toList(),
      'mutualFriends': mutualFriends.map((e) => e.toJson()).toList(),
      'socialInitiative': socialInitiative.toJson(),
      'peakDay': peakDay.toJson(),
      'checkIn': checkIn,
      'messageTypes': messageTypes.map((e) => e.toJson()).toList(),
      'messageLength': messageLength.toJson(),
      'activityPattern': activityPattern.toJson(),
      'midnightKing': midnightKing,
      'whoRepliesFastest': whoRepliesFastest,
      'myFastestReplies': myFastestReplies,
    };
  }
}

