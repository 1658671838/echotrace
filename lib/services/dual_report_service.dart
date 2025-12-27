import 'database_service.dart';
import '../models/message.dart';
import '../models/contact_record.dart';
import '../models/contact.dart';

/// 双人报告数据服务
class DualReportService {
  final DatabaseService _databaseService;

  DualReportService(this._databaseService);

  /// 生成双人报告数据
  Future<Map<String, dynamic>> generateDualReportData({
    required String friendUsername,
    required String friendName,
    required String myName,
    int? year,
  }) async {
    // 获取第一次聊天信息
    final firstChat = await _getFirstChatInfo(friendUsername);

    // 获取今年第一次聊天信息
    final thisYearFirstChat = await _getThisYearFirstChatInfo(
      friendUsername,
      friendName,
      year ?? DateTime.now().year,
    );

    // 获取我的微信显示名称
    final myDisplayName = await _getMyDisplayName(myName);

    // 获取年度统计数据
    final actualYear = year ?? DateTime.now().year;
    final yearlyStats = await _getYearlyStats(friendUsername, actualYear);

    return {
      'myName': myDisplayName,
      'friendUsername': friendUsername,
      'friendName': friendName,
      'year': year,
      'firstChat': firstChat,
      'thisYearFirstChat': thisYearFirstChat,
      'yearlyStats': yearlyStats,
    };
  }

  /// 获取我的微信显示名称
  Future<String> _getMyDisplayName(String myWxid) async {
    try {
      // 从 contact 数据库获取所有联系人，找到自己的记录
      final contacts = await _databaseService.getAllContacts();

      // 尝试精确匹配
      final myContactRecord = contacts.firstWhere(
        (c) => c.contact.username == myWxid,
        orElse: () => contacts.firstWhere(
          (c) => c.contact.username.contains(myWxid) || myWxid.contains(c.contact.username),
          orElse: () => ContactRecord(
            contact: Contact(
              id: 0,
              username: myWxid,
              localType: 0,
              alias: '',
              encryptUsername: '',
              flag: 0,
              deleteFlag: 0,
              verifyFlag: 0,
              remark: '',
              remarkQuanPin: '',
              remarkPinYinInitial: '',
              nickName: '',
              pinYinInitial: '',
              quanPin: '',
              bigHeadUrl: '',
              smallHeadUrl: '',
              headImgMd5: '',
              chatRoomNotify: 0,
              isInChatRoom: 0,
              description: '',
              extraBuffer: [],
              chatRoomType: 0,
            ),
            source: ContactRecognitionSource.friend,
            origin: ContactDataOrigin.unknown,
          ),
        ),
      );

      // 使用 Contact 的 displayName getter（已处理 remark/nickName/alias 优先级）
      return myContactRecord.contact.displayName;
    } catch (e) {
      print('获取我的显示名称失败: $e');
      return myWxid;
    }
  }

  /// 获取第一次聊天信息
  Future<Map<String, dynamic>?> _getFirstChatInfo(String username) async {
    try {
      // 使用 getMessagesByDate 从1970年1月1日到现在，获取所有历史消息
      final now = DateTime.now();
      final startTimestamp = 0; // 1970年1月1日
      final endTimestamp = now.millisecondsSinceEpoch ~/ 1000; // 当前时间

      final allMessages = await _databaseService.getMessagesByDate(
        username,
        startTimestamp,
        endTimestamp,
      );

      if (allMessages.isEmpty) {
        return null;
      }

      // getMessagesByDate 返回的是降序（最新在前），需要按升序排序
      allMessages.sort((a, b) => a.createTime.compareTo(b.createTime));

      final firstMessage = allMessages.first;
      // createTime 是秒级时间戳，需要转换为毫秒
      final createTimeMs = firstMessage.createTime * 1000;

      return {
        'createTime': createTimeMs,  // 毫秒时间戳
        'createTimeStr': _formatDateTime(createTimeMs), // 格式化的时间字符串
        'content': firstMessage.messageContent,
        'isSentByMe': firstMessage.isSend == 1,
        'senderUsername': firstMessage.senderUsername,
      };
    } catch (e) {
      return null;
    }
  }

  /// 获取今年第一次聊天信息（包括前三句对话）
  Future<Map<String, dynamic>?> _getThisYearFirstChatInfo(
    String username,
    String friendName,
    int year,
  ) async {
    try {
      // 定义今年的时间范围
      final startOfYear = DateTime(year, 1, 1);
      final endOfYear = DateTime(year, 12, 31, 23, 59, 59);

      final startTimestamp = startOfYear.millisecondsSinceEpoch ~/ 1000;
      final endTimestamp = endOfYear.millisecondsSinceEpoch ~/ 1000;

      // 直接按日期范围查询今年的消息
      final thisYearMessages = await _databaseService.getMessagesByDate(
        username,
        startTimestamp,
        endTimestamp,
      );

      if (thisYearMessages.isEmpty) {
        return null;
      }

      // 确保按时间升序排序，第一条就是今年最早的
      thisYearMessages.sort((a, b) => a.createTime.compareTo(b.createTime));
      final firstMessage = thisYearMessages.first;
      final createTimeMs = firstMessage.createTime * 1000; // 转换为毫秒

      // 获取前三条消息（包含时间）
      final firstThreeMessages = thisYearMessages.take(3).map((msg) {
        final msgTimeMs = msg.createTime * 1000;
        return {
          'content': msg.messageContent,
          'isSentByMe': msg.isSend == 1,
          'createTime': msg.createTime,
          'createTimeStr': _formatDateTime(msgTimeMs),
        };
      }).toList();

      return {
        'createTime': createTimeMs,
        'createTimeStr': _formatDateTime(createTimeMs),
        'content': firstMessage.messageContent,
        'isSentByMe': firstMessage.isSend == 1,
        'friendName': friendName,
        'firstThreeMessages': firstThreeMessages,
      };
    } catch (e) {
      return null;
    }
  }

  /// 格式化时间（显示日期和时间）
  String _formatDateTime(int millisecondsSinceEpoch) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$month/$day $hour:$minute';
  }

  /// 获取年度统计数据
  Future<Map<String, dynamic>> _getYearlyStats(
    String username,
    int year,
  ) async {
    try {
      // 定义今年的时间范围
      final startOfYear = DateTime(year, 1, 1);
      final endOfYear = DateTime(year, 12, 31, 23, 59, 59);

      final startTimestamp = startOfYear.millisecondsSinceEpoch ~/ 1000;
      final endTimestamp = endOfYear.millisecondsSinceEpoch ~/ 1000;

      // 获取今年的所有消息
      final messages = await _databaseService.getMessagesByDate(
        username,
        startTimestamp,
        endTimestamp,
      );

      // 初始化统计
      int totalMessages = 0;
      int totalWords = 0;
      int imageCount = 0;
      int voiceCount = 0;
      int emojiCount = 0;

      for (final msg in messages) {
        totalMessages++;

        // 统计消息类型
        switch (msg.localType) {
          case 1: // 文本消息
            // 统计字数（去除空白字符）
            final content = msg.displayContent;
            final words = content.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
            totalWords += words;
            break;
          case 3: // 图片
            imageCount++;
            break;
          case 34: // 语音
            voiceCount++;
            break;
          case 47: // 动画表情
            emojiCount++;
            break;
        }
      }

      return {
        'totalMessages': totalMessages,
        'totalWords': totalWords,
        'imageCount': imageCount,
        'voiceCount': voiceCount,
        'emojiCount': emojiCount,
      };
    } catch (e) {
      print('获取年度统计数据失败: $e');
      return {
        'totalMessages': 0,
        'totalWords': 0,
        'imageCount': 0,
        'voiceCount': 0,
        'emojiCount': 0,
      };
    }
  }

  /// 生成完整的双人报告（外部接口）
  Future<Map<String, dynamic>> generateDualReport({
    required String friendUsername,
    int? filterYear,
  }) async {
    try {
      // 获取当前用户wxid
      final myWxid = _databaseService.currentAccountWxid;
      if (myWxid == null || myWxid.isEmpty) {
        throw Exception('无法获取当前用户信息');
      }

      // 获取好友显示名称
      final contacts = await _databaseService.getAllContacts();
      final friendContact = contacts.firstWhere(
        (c) => c.contact.username == friendUsername,
        orElse: () => contacts.firstWhere(
          (c) => c.contact.username.contains(friendUsername) || friendUsername.contains(c.contact.username),
          orElse: () => ContactRecord(
            contact: Contact(
              id: 0,
              username: friendUsername,
              localType: 0,
              alias: '',
              encryptUsername: '',
              flag: 0,
              deleteFlag: 0,
              verifyFlag: 0,
              remark: '',
              remarkQuanPin: '',
              remarkPinYinInitial: '',
              nickName: '',
              pinYinInitial: '',
              quanPin: '',
              bigHeadUrl: '',
              smallHeadUrl: '',
              headImgMd5: '',
              chatRoomNotify: 0,
              isInChatRoom: 0,
              description: '',
              extraBuffer: [],
              chatRoomType: 0,
            ),
            source: ContactRecognitionSource.friend,
            origin: ContactDataOrigin.unknown,
          ),
        ),
      );

      final friendName = friendContact.contact.displayName;

      // 生成报告数据
      return await generateDualReportData(
        friendUsername: friendUsername,
        friendName: friendName,
        myName: myWxid,
        year: filterYear,
      );
    } catch (e) {
      print('生成双人报告失败: $e');
      rethrow;
    }
  }
}
