import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_state.dart';
import '../models/chat_session.dart';
import '../models/contact_record.dart';
import '../models/message.dart';
import '../services/chat_export_service.dart';
import '../services/database_service.dart';
import '../widgets/common/shimmer_loading.dart';
import '../utils/string_utils.dart';

/// 聊天记录导出页面
class ChatExportPage extends StatefulWidget {
  const ChatExportPage({super.key});

  @override
  State<ChatExportPage> createState() => _ChatExportPageState();
}

class _ChatExportPageState extends State<ChatExportPage> {
  List<ChatSession> _allSessions = [];
  Set<String> _selectedSessions = {};
  bool _isLoadingSessions = false;
  bool _selectAll = false;
  String _searchQuery = '';
  String _selectedFormat = 'json';
  DateTimeRange? _selectedRange;
  String? _exportFolder;
  bool _isAutoConnecting = false;
  bool _autoLoadScheduled = false;
  bool _hasAttemptedRefreshAfterConnect = false;
  bool _useAllTime = false;
  bool _isExportingContacts = false;

  // 添加静态缓存变量，用于存储会话列表
  static List<ChatSession>? _cachedSessions;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _loadExportFolder();
    // 默认选择最近7天
    _selectedRange = DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 7)),
      end: DateTime.now(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureConnected();
    });
  }

  Future<void> _loadExportFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final folder = prefs.getString('export_folder');
    if (!mounted || folder == null) return;

    setState(() {
      _exportFolder = folder;
    });
  }

  Future<void> _selectExportFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出文件夹',
    );

    if (!mounted || result == null) {
      return;
    }

    setState(() {
      _exportFolder = result;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('export_folder', result);

    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已设置导出文件夹: $result')));
  }

  Future<void> _exportContacts() async {
    final appState = context.read<AppState>();
    if (!appState.databaseService.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先连接数据库后再导出通讯录')));
      }
      return;
    }

    setState(() {
      _isExportingContacts = true;
    });

    try {
      final databaseService = appState.databaseService;
      final allRecords = await databaseService.getAllContacts(
        includeStrangers: true,
        includeChatroomParticipants: true,
      );

      final friendRecords = allRecords
          .where(
            (record) =>
                record.source == ContactRecognitionSource.friend &&
                record.contact.localType == 1,
          )
          .toList();
      final groupOnlyRecords = allRecords
          .where(
            (record) =>
                record.source == ContactRecognitionSource.chatroomParticipant,
          )
          .toList();
      final strangerRecords = allRecords
          .where((record) => record.source == ContactRecognitionSource.stranger)
          .toList();

      final exportService = ChatExportService(databaseService);
      final success = await exportService.exportContactsToExcel(
        directoryPath: _exportFolder,
        contacts: friendRecords,
      );

      if (!mounted) return;

      final summary = StringBuffer(success ? '通讯录导出成功' : '没有可导出的联系人或导出被取消')
        ..write('（好友 ')
        ..write(friendRecords.length)
        ..write(' 人');

      if (groupOnlyRecords.isNotEmpty) {
        summary
          ..write('，群聊成员未导出 ')
          ..write(groupOnlyRecords.length)
          ..write(' 人');
      }

      if (strangerRecords.isNotEmpty) {
        summary
          ..write('，陌生人未导出 ')
          ..write(strangerRecords.length)
          ..write(' 人');
      }

      summary.write('）');

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(summary.toString())));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出通讯录失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExportingContacts = false;
        });
      }
    }
  }

  Future<void> _ensureConnected() async {
    final appState = context.read<AppState>();
    if (!appState.isConfigured) return;
    if (appState.databaseService.isConnected || appState.isLoading) return;
    if (_isAutoConnecting) return;

    setState(() {
      _isAutoConnecting = true;
      _hasAttemptedRefreshAfterConnect = false;
    });
    try {
      await appState.reconnectDatabase();
      if (mounted) {
        await _loadSessions();
        _hasAttemptedRefreshAfterConnect = true;
      }
    } catch (_) {
      // 失败交给 UI 提示
    } finally {
      if (mounted) {
        setState(() {
          _isAutoConnecting = false;
        });
        // 若仍未连接，再尝试一次刷新会话列表以防遗漏
        if (!_hasAttemptedRefreshAfterConnect &&
            appState.databaseService.isConnected) {
          _hasAttemptedRefreshAfterConnect = true;
          unawaited(_loadSessions());
        }
      }
    }
  }

  Future<void> _loadSessions() async {
    // 首先检查缓存是否存在
    if (_cachedSessions != null) {
      setState(() {
        _allSessions = _cachedSessions!;
        _isLoadingSessions = false;
      });
      return;
    }

    setState(() {
      _isLoadingSessions = true;
    });

    try {
      final appState = context.read<AppState>();

      if (!appState.databaseService.isConnected) {
        if (mounted) {
          setState(() {
            _isLoadingSessions = false;
          });
        }
        return;
      }

      final sessions = await appState.databaseService.getSessions();

      // 过滤掉公众号/服务号
      final filteredSessions = sessions.where((session) {
        return ChatSession.shouldKeep(session.username);
      }).toList(); // 保存到缓存
      _cachedSessions = filteredSessions;

      if (mounted) {
        setState(() {
          _allSessions = filteredSessions;
          _isLoadingSessions = false;
        });
      }

      // 异步加载头像（使用全局缓存）
      try {
        await appState.fetchAndCacheAvatars(
          filteredSessions.map((s) => s.username).toList(),
        );
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSessions = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载会话列表失败: $e')));
      }
    }
  }

  // 修改刷新方法，清除缓存后重新加载
  Future<void> _refreshSessions() async {
    // 清除缓存
    _cachedSessions = null;
    // 清除已选会话，避免刷新后选中状态与新列表不匹配
    setState(() {
      _selectedSessions.clear();
      _selectAll = false;
    });
    // 重新加载数据
    await _loadSessions();

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('会话列表已刷新')));
    }
  }

  List<ChatSession> get _filteredSessions {
    if (_searchQuery.isEmpty) return _allSessions;

    return _allSessions.where((session) {
      final displayName = session.displayName ?? session.username;
      return displayName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          session.username.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();
  }

  void _toggleSelectAll() {
    setState(() {
      _selectAll = !_selectAll;
      if (_selectAll) {
        _selectedSessions = _filteredSessions.map((s) => s.username).toSet();
      } else {
        _selectedSessions.clear();
      }
    });
  }

  void _toggleSession(String username) {
    setState(() {
      if (_selectedSessions.contains(username)) {
        _selectedSessions.remove(username);
        _selectAll = false;
      } else {
        _selectedSessions.add(username);
        if (_selectedSessions.length == _filteredSessions.length) {
          _selectAll = true;
        }
      }
    });
  }

  Future<void> _selectDateRange() async {
    if (_useAllTime) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已选择全部时间，无需设置日期范围')));
      return;
    }

    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _selectedRange,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: Theme.of(context).colorScheme.primary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedRange = picked;
      });
    }
  }

  Future<void> _startExport() async {
    if (_selectedSessions.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请至少选择一个会话')));
      return;
    }

    if (_exportFolder == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择导出文件夹')));
      return;
    }

    // 显示确认对话框
    final dateRangeText = _useAllTime
        ? '全部时间'
        : '${_selectedRange!.start.toLocal().toString().split(' ')[0]} 至 ${_selectedRange!.end.toLocal().toString().split(' ')[0]}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认导出'),
        content: Text(
          '将导出 ${_selectedSessions.length} 个会话的聊天记录\n'
          '日期范围: $dateRangeText\n'
          '导出格式: ${_getFormatName(_selectedFormat)}\n'
          '导出位置: $_exportFolder\n\n'
          '此操作可能需要一些时间，请耐心等待。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始导出'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // 显示进度对话框
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ExportProgressDialog(
        sessions: _selectedSessions.toList(),
        allSessions: _allSessions,
        format: _selectedFormat,
        dateRange: _selectedRange!,
        exportFolder: _exportFolder!,
        useAllTime: _useAllTime,
      ),
    );
  }

  String _getFormatName(String format) {
    switch (format) {
      case 'json':
        return 'JSON';
      case 'html':
        return 'HTML';
      case 'xlsx':
        return 'Excel';
      case 'sql':
        return 'SQL';
      default:
        return format.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final hasError = appState.errorMessage != null;
    final isConnecting =
        appState.isLoading ||
        _isAutoConnecting ||
        (!appState.databaseService.isConnected && !hasError);
    final showErrorOverlay =
        !appState.isLoading &&
        !appState.databaseService.isConnected &&
        hasError;

    if (!isConnecting &&
        !_isLoadingSessions &&
        _allSessions.isEmpty &&
        !_autoLoadScheduled &&
        appState.databaseService.isConnected) {
      _autoLoadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        _autoLoadScheduled = false;
        await _loadSessions();
      });
    }

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      body: Stack(
        children: [
          // 主内容
          Column(
            children: [
              _buildHeader(),
              _buildFilterBar(),
              Expanded(
                child: Row(
                  children: [
                    Expanded(flex: 2, child: _buildSessionList()),
                    Container(
                      width: 1,
                      color: Colors.grey.withValues(alpha: 0.2),
                    ),
                    Expanded(flex: 1, child: _buildExportSettings()),
                  ],
                ),
              ),
            ],
          ),

          // 遮罩层 (加载/错误)
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              transitionBuilder: (child, animation) {
                // 出入场动画
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: animation.drive(
                      Tween<double>(
                        begin: 0.96,
                        end: 1.0,
                      ).chain(CurveTween(curve: Curves.easeOutCubic)),
                    ),
                    child: child,
                  ),
                );
              },
              child: showErrorOverlay
                  ? Container(
                      key: const ValueKey('error_overlay'),
                      color: Colors.white,
                      child: Center(
                        child: _buildErrorOverlay(
                          context,
                          appState,
                          appState.errorMessage ?? '未能连接数据库',
                        ),
                      ),
                    )
                  : isConnecting
                  ? Container(
                      key: const ValueKey('loading_overlay'),
                      color: Colors.white.withValues(alpha: 0.98),
                      child: Center(child: _buildFancyLoader(context)),
                    )
                  : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFancyLoader(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: Curves.elasticOut,
      builder: (context, value, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 80,
              height: 40,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(4, (index) {
                  return _AnimatedBar(
                    index: index,
                    color: color,
                    baseHeight: 12,
                    maxExtraHeight: 24,
                  );
                }),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '正在建立连接...',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildErrorOverlay(
    BuildContext context,
    AppState appState,
    String message,
  ) {
    final theme = Theme.of(context);
    final lower = message.toLowerCase();
    bool isMissingDb =
        lower.contains('未找到') ||
        lower.contains('不存在') ||
        lower.contains('no such file') ||
        lower.contains('not found');

    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            isMissingDb ? '未找到数据库文件' : '数据库连接异常',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isMissingDb ? '请先在「数据管理」页面解密对应账号的数据库。' : message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () =>
                    context.read<AppState>().setCurrentPage('data_management'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('前往管理'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _ensureConnected,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('重试'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.file_download_outlined,
            size: 28,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Text(
            '导出聊天记录',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshSessions, // 修改为使用新的刷新方法
            tooltip: '刷新列表',
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: Colors.grey.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索会话...',
                prefixIcon: const Icon(Icons.search),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.grey),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.grey, width: 1.5),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.grey),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                  _selectAll = false;
                });
              },
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            onPressed: _toggleSelectAll,
            icon: Icon(
              _selectAll ? Icons.check_box : Icons.check_box_outline_blank,
            ),
            label: Text(_selectAll ? '取消全选' : '全选'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '已选择: ${_selectedSessions.length}',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionList() {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (!appState.databaseService.isConnected) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.storage_rounded,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  '数据库未连接',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '请先在「数据管理」页面解密数据库文件',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          );
        }

        if (_isLoadingSessions) {
          return ShimmerLoading(
            isLoading: true,
            child: ListView.builder(
              itemCount: 6,
              physics: const NeverScrollableScrollPhysics(),
              itemBuilder: (context, index) => const ListItemShimmer(),
            ),
          );
        }

        final sessions = _filteredSessions;

        if (sessions.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  _searchQuery.isEmpty ? '暂无会话' : '未找到匹配的会话',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          itemCount: sessions.length,
          padding: const EdgeInsets.all(8),
          itemBuilder: (context, index) {
            final session = sessions[index];
            final isSelected = _selectedSessions.contains(session.username);
            final avatarUrl = appState.getAvatarUrl(session.username);

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              elevation: isSelected ? 2 : 0,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                  : null,
              child: ListTile(
                leading: (avatarUrl != null && avatarUrl.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: avatarUrl,
                        imageBuilder: (context, imageProvider) => CircleAvatar(
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          backgroundImage: imageProvider,
                        ),
                        placeholder: (context, url) => CircleAvatar(
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          child: Text(
                            StringUtils.getFirstChar(
                              session.displayName ?? session.username,
                            ),
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => CircleAvatar(
                          backgroundColor: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          child: Text(
                            StringUtils.getFirstChar(
                              session.displayName ?? session.username,
                            ),
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      )
                    : CircleAvatar(
                        backgroundColor: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade300,
                        child: Text(
                          StringUtils.getFirstChar(
                            session.displayName ?? session.username,
                          ),
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : Colors.grey.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                title: Text(
                  session.displayName ?? session.username,
                  style: TextStyle(
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                subtitle: Text(session.typeDescription),
                trailing: Checkbox(
                  value: isSelected,
                  onChanged: (value) => _toggleSession(session.username),
                ),
                onTap: () => _toggleSession(session.username),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildExportSettings() {
    return Container(
      color: Colors.grey.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '导出设置',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 导出文件夹设置
                  Text(
                    '导出位置',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _selectExportFolder,
                    icon: const Icon(Icons.folder_open),
                    label: Text(
                      _exportFolder ?? '选择导出文件夹',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                  const SizedBox(height: 24),

                  Text(
                    '通讯录导出',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '将当前账号的通讯录导出为 Excel 表格',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _isExportingContacts ? null : _exportContacts,
                    icon: _isExportingContacts
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.contacts),
                    label: Text(
                      _isExportingContacts ? '正在导出通讯录...' : '导出通讯录 (Excel)',
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 日期范围选择
                  Text(
                    '日期范围',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    value: _useAllTime,
                    onChanged: (value) {
                      setState(() {
                        _useAllTime = value ?? false;
                      });
                    },
                    title: const Text('导出全部时间'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _useAllTime ? null : _selectDateRange,
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                      _useAllTime
                          ? '全部时间'
                          : (_selectedRange != null
                                ? '${_selectedRange!.start.toLocal().toString().split(' ')[0]} 至\n${_selectedRange!.end.toLocal().toString().split(' ')[0]}'
                                : '选择日期范围'),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 导出格式选择
                  Text(
                    '导出格式',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildFormatOption('json', 'JSON', '结构化数据格式，便于程序处理'),
                  _buildFormatOption('html', 'HTML', '网页格式，便于浏览和分享'),
                  _buildFormatOption('xlsx', 'Excel', '表格格式，便于数据分析'),
                  _buildFormatOption(
                    'sql',
                    'PostgreSQL',
                    '数据库格式，便于导入到 PostgreSQL 数据库中',
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // 导出按钮
          Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _selectedSessions.isEmpty ? null : _startExport,
                icon: const Icon(Icons.download),
                label: const Text('开始导出'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatOption(String value, String label, String description) {
    final isSelected = _selectedFormat == value;

    return InkWell(
      onTap: () => setState(() => _selectedFormat = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : Colors.white,
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 导出状态枚举
enum _ExportStatus { idle, initializing, exporting, completed, error }

class _ExportProgressDialog extends StatefulWidget {
  final List<String> sessions;
  final List<ChatSession> allSessions;
  final String format;
  final DateTimeRange dateRange;
  final String exportFolder;
  final bool useAllTime;

  const _ExportProgressDialog({
    required this.sessions,
    required this.allSessions,
    required this.format,
    required this.dateRange,
    required this.exportFolder,
    required this.useAllTime,
  });

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  int _successCount = 0;
  int _failedCount = 0;
  int _totalMessagesProcessed = 0;
  int _currentExportedCount = 0;
  String _currentSessionName = '';
  double _progress = 0.0;
  _ExportStatus _status = _ExportStatus.idle;
  String? _errorMessage;
  late int _totalSessions;

  @override
  void initState() {
    super.initState();
    _totalSessions = widget.sessions.length;
    _startExport();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _startExport() async {
    try {
      final appState = context.read<AppState>();
      final dbService = appState.databaseService;
      final exportService = ChatExportService(dbService);

      if (dbService.mode == DatabaseMode.realtime) {
        throw Exception('实时模式暂不支持导出功能，切换至备份模式后重试。');
      }

      setState(() {
        _status = _ExportStatus.initializing;
      });

      final startTime = widget.useAllTime
          ? null
          : widget.dateRange.start.millisecondsSinceEpoch ~/ 1000;
      final endTime = widget.useAllTime
          ? null
          : widget.dateRange.end.millisecondsSinceEpoch ~/ 1000;

      // 提前获取所有会话，避免循环中重复调用
      final sessions = await dbService.getSessions();

      for (int i = 0; i < _totalSessions; i++) {
        final username = widget.sessions[i];

        // 尝试获取显示名称：Map(UI传入) > rcontact(数据库) > chat_session(数据库) > username
        final sFromAll = widget.allSessions
            .where((s) => s.username == username)
            .firstOrNull;
        String displayName = sFromAll?.displayName ?? username;

        try {
          final contact = await dbService.getContact(username);
          if (contact != null) {
            displayName = contact.displayName;
          } else if (displayName == username) {
            final s = sessions.where((s) => s.username == username).firstOrNull;
            if (s != null &&
                s.displayName != null &&
                s.displayName != username &&
                s.displayName!.isNotEmpty) {
              displayName = s.displayName!;
            }
          }
        } catch (_) {}

        if (!mounted) return;
        setState(() {
          _status = _ExportStatus.exporting;
          _progress = -1.0; // 扫描阶段显示不确定进度条
          _currentSessionName = displayName;
          _currentExportedCount = 0;
        });

        // 1. 扫描阶段
        List<Message> allMessages = [];
        int offset = 0;
        const int batchSize = 5000;
        bool hasMore = true;
        int batchCount = 0;

        while (hasMore) {
          final batch = await dbService.getMessages(
            username,
            limit: batchSize,
            offset: offset,
          );

          if (batch.isEmpty) {
            hasMore = false;
          } else {
            final latestInBatch = batch.first.createTime;
            final earliestInBatch = batch.last.createTime;

            // 智能早停
            if (startTime != null && latestInBatch < startTime) {
              hasMore = false;
              break;
            }

            final filteredBatch = batch.where((m) {
              if (startTime != null && m.createTime < startTime) return false;
              if (endTime != null && m.createTime > endTime) return false;
              return true;
            }).toList();

            allMessages.addAll(filteredBatch);

            if (startTime != null && earliestInBatch < startTime) {
              hasMore = false;
            }

            if (batch.length < batchSize) {
              hasMore = false;
            }
            offset += batch.length;

            if (!mounted) return;

            // 每处理 2 个大批次刷新一次 UI
            batchCount++;
            if (batchCount % 2 == 0 || !hasMore) {
              setState(() {
                _currentExportedCount = allMessages.length;
              });
              // 出让主线程控制权，防止 UI 卡死
              await Future.delayed(Duration.zero);
            }
          }
        }

        // 构建或获取会话实体对象，用于导出服务
        ChatSession? targetSession = sessions
            .where((s) => s.username == username)
            .firstOrNull;
        targetSession ??= widget.allSessions
            .where((s) => s.username == username)
            .firstOrNull;

        if (targetSession == null) {
          // 如果实在找不到，记录失败并跳过
          _failedCount++;
          continue;
        }

        // 2. 写入阶段
        if (!mounted) return;
        setState(() {
          _progress = (i + 0.1) / _totalSessions;
          _currentSessionName =
              "正在写入 $displayName (${allMessages.length} 条消息)...";
        });

        // 排序
        allMessages.sort((a, b) => a.createTime.compareTo(b.createTime));
        await Future.delayed(Duration.zero);

        bool result = false;
        final safeName = displayName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final savePath =
            '${widget.exportFolder}/${safeName}_$timestamp.${widget.format}';

        // 设置较接近完成的进度
        setState(() {
          _progress = (i + 0.9) / _totalSessions;
        });

        switch (widget.format) {
          case 'json':
            result = await exportService.exportToJson(
              targetSession,
              allMessages,
              filePath: savePath,
            );
            break;
          case 'html':
            result = await exportService.exportToHtml(
              targetSession,
              allMessages,
              filePath: savePath,
            );
            break;
          case 'xlsx':
            result = await exportService.exportToExcel(
              targetSession,
              allMessages,
              filePath: savePath,
            );
            break;
          case 'sql':
            result = await exportService.exportToPostgreSQL(
              targetSession,
              allMessages,
              filePath: savePath,
            );
            break;
        }

        if (!mounted) return;
        setState(() {
          if (result) {
            _successCount++;
            _totalMessagesProcessed += allMessages.length;
          } else {
            _failedCount++;
          }
          _progress = (i + 1.0) / _totalSessions;
        });
      }

      if (!mounted) return;
      setState(() {
        _status = _ExportStatus.completed;
        _progress = 1.0;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _ExportStatus.error;
          _errorMessage = e.toString();
        });
      }
    }
  }

  // 辅助方法：打开文件夹
  Future<void> _openFolder() async {
    final path = widget.exportFolder;
    final uri = Uri.directory(path);
    try {
      if (!await launchUrl(uri)) {
        throw '无法打开文件夹';
      }
    } catch (e) {
      // 平台特定的回退处理
      try {
        if (Platform.isWindows) {
          await Process.run('explorer', [path]);
        } else if (Platform.isMacOS) {
          await Process.run('open', [path]);
        } else if (Platform.isLinux) {
          await Process.run('xdg-open', [path]);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompleted = _status == _ExportStatus.completed;
    final isError = _status == _ExportStatus.error;

    // 对话框尺寸及形状
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: Colors.white,
      elevation: 8,
      child: Container(
        width: 500, // 为桌面端设计的固定宽度
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white,
        ),
        child: isCompleted
            ? _buildCompletedUI()
            : (isError ? _buildErrorUI() : _buildProgressUI()),
      ),
    );
  }

  Widget _buildProgressUI() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        Text(
          '正在导出',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),

        // 当前会话名称
        Text(
          _currentSessionName.isEmpty ? '准备中...' : _currentSessionName,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 16),

        // 状态文字：扫描中/写入中
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _currentSessionName.contains('正在写入') ? '正在导出资源...' : '正在扫描会话...',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            if (_progress > 0 && _progress <= 1.0)
              Text(
                '${(_progress * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                  color: Color(0xFF07C160),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // 进度条
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _progress <= 0 ? null : _progress,
            minHeight: 8,
            backgroundColor: Colors.grey.shade100,
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF07C160)),
          ),
        ),
        const SizedBox(height: 12),

        // 详情统计
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            _currentSessionName.contains('正在写入')
                ? '正在写入数据: $_currentExportedCount 条'
                : '已扫描消息: $_currentExportedCount 条',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
        ),
        const SizedBox(height: 24),

        // 统计行：已导出消息 | 剩余会话
        Row(
          children: [
            _buildStatItem('已导出消息', '$_totalMessagesProcessed'),
            Container(
              height: 30,
              width: 1,
              color: Colors.grey.shade300,
              margin: const EdgeInsets.symmetric(horizontal: 24),
            ),
            _buildStatItem(
              '剩余会话',
              '${_totalSessions - (_successCount + _failedCount)}',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCompletedUI() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '导出完成',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 32),

        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF07C160), width: 2),
              ),
              child: const Icon(
                Icons.check,
                color: Color(0xFF07C160),
                size: 32,
              ),
            ),
            const SizedBox(width: 16),
            const Text(
              '导出已完成',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 32),

        // 统计行
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildStatItem(
              '成功',
              '$_successCount',
              valueColor: const Color(0xFF07C160),
            ),
            Container(height: 30, width: 1, color: Colors.grey.shade300),
            _buildStatItem(
              '失败',
              '$_failedCount',
              valueColor: _failedCount > 0 ? Colors.red : null,
            ),
            Container(height: 30, width: 1, color: Colors.grey.shade300),
            _buildStatItem('总消息', '$_totalMessagesProcessed'),
          ],
        ),
        const SizedBox(height: 24),

        // 文件路径
        Text(
          '文件位置',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
        const SizedBox(height: 4),
        Text(
          widget.exportFolder,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
        ),

        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _openFolder,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF07C160),
              ),
              child: const Text(
                '打开所在文件夹',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 16),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF07C160),
              ),
              child: const Text(
                '关闭',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorUI() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '导出失败',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.red,
          ),
        ),
        const SizedBox(height: 24),
        Text(_errorMessage ?? '未知错误'),
        const SizedBox(height: 32),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ),
      ],
    );
  }

  Widget _buildStatItem(String label, String value, {Color? valueColor}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w500,
            color: valueColor ?? Colors.black87,
          ),
        ),
      ],
    );
  }
}

/// 内部辅助组件：带动画的条形图
class _AnimatedBar extends StatefulWidget {
  final int index;
  final Color color;
  final double baseHeight;
  final double maxExtraHeight;

  const _AnimatedBar({
    required this.index,
    required this.color,
    required this.baseHeight,
    required this.maxExtraHeight,
  });

  @override
  State<_AnimatedBar> createState() => _AnimatedBarState();
}

class _AnimatedBarState extends State<_AnimatedBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    Future.delayed(Duration(milliseconds: widget.index * 150), () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 8,
          height:
              widget.baseHeight + (widget.maxExtraHeight * _animation.value),
          decoration: BoxDecoration(
            color: widget.color.withValues(
              alpha: 0.3 + (0.7 * _animation.value),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      },
    );
  }
}
