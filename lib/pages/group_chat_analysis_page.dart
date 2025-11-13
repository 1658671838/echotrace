import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/group_chat_service.dart';
import 'group_chat_detail_page.dart';

class GroupChatAnalysisPage extends StatefulWidget {
  const GroupChatAnalysisPage({super.key});

  @override
  State<GroupChatAnalysisPage> createState() => _GroupChatAnalysisPageState();
}

class _GroupChatAnalysisPageState extends State<GroupChatAnalysisPage> {
  late final GroupChatService _groupChatService;
  List<GroupChatInfo> _allGroups = [];
  List<GroupChatInfo> _filteredGroups = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  
  // 添加静态缓存变量，用于存储群聊数据
  static List<GroupChatInfo>? _cachedGroupChats;

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _groupChatService = GroupChatService(appState.databaseService);
    _loadGroupChats();
    _searchController.addListener(_filterGroups);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadGroupChats() async {
    // 首先检查缓存是否存在
    if (_cachedGroupChats != null) {
      setState(() {
        _allGroups = _cachedGroupChats!;
        _filteredGroups = _cachedGroupChats!;
        _isLoading = false;
      });
      return;
    }

    try {
      final groups = await _groupChatService.getGroupChats();
      // 保存到缓存
      _cachedGroupChats = groups;
      setState(() {
        _allGroups = groups;
        _filteredGroups = groups;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载群聊列表失败: $e')),
        );
      }
    }
  }

  // 添加刷新方法
  Future<void> _refreshGroupChats() async {
    setState(() {
      _isLoading = true;
    });
    // 清除缓存
    _cachedGroupChats = null;
    // 重新加载数据
    await _loadGroupChats();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('刷新成功')),
      );
    }
  }

  void _filterGroups() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredGroups = _allGroups
          .where((group) => group.displayName.toLowerCase().contains(query))
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('群聊分析'),
        backgroundColor: Colors.green,
        // 添加刷新按钮
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshGroupChats,
            tooltip: '刷新群聊列表',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: '搜索群聊',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredGroups.isEmpty
                    ? const Center(child: Text('未找到群聊'))
                    : ListView.builder(
                        itemCount: _filteredGroups.length,
                        itemBuilder: (context, index) {
                          final group = _filteredGroups[index];
                          return ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.group),
                            ),
                            title: Text(group.displayName),
                            subtitle: Text('成员: ${group.memberCount}人'),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => GroupChatDetailPage(groupInfo: group),
                                ),
                              );
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}