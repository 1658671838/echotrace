import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_saver/file_saver.dart';
import '../providers/app_state.dart';
import '../services/group_chat_service.dart';

// 我们可以创建一个可复用的头像 Widget
class UserAvatar extends StatelessWidget {
  final GroupMember member;
  const UserAvatar({super.key, required this.member});

  @override
  Widget build(BuildContext context) {
    final hasAvatar = member.avatarUrl != null && member.avatarUrl!.isNotEmpty;
    return CircleAvatar(
      // 如果有头像 URL，则使用 NetworkImage 作为背景
      backgroundImage: hasAvatar ? NetworkImage(member.avatarUrl!) : null,
      // 如果 NetworkImage 加载失败或 URL 为空，则显示备用内容
      child: hasAvatar
          ? null // 有背景图时，child 为 null
          : Text(member.displayName.isNotEmpty ? member.displayName[0].toUpperCase() : '?'),
    );
  }
}

class GroupMembersPage extends StatefulWidget {
  final GroupChatInfo groupInfo;
  const GroupMembersPage({super.key, required this.groupInfo});

  @override
  State<GroupMembersPage> createState() => _GroupMembersPageState();
}

class _GroupMembersPageState extends State<GroupMembersPage> {
  late final GroupChatService _groupChatService;
  List<GroupMember> _members = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _groupChatService = GroupChatService(appState.databaseService);
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final members = await _groupChatService.getGroupMembers(widget.groupInfo.username);
      setState(() {
        _members = members;
        _isLoading = false;
      });
    } catch(e) {
      setState(() => _isLoading = false);
      // error handling
    }
  }

  Future<void> _exportToJson() async {
    // ... 导出逻辑保持不变
    if (_members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有成员数据可以导出')));
      return;
    }
    final jsonString = jsonEncode(_members.map((m) => m.toJson()).toList());
    try {
      final fileName = 'group_members_${widget.groupInfo.displayName}.json';
      await FileSaver.instance.saveFile(name: fileName, bytes: utf8.encode(jsonString), mimeType: MimeType.json);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('成功导出到下载目录: $fileName')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.groupInfo.displayName}成员 (${_members.length})'),
        backgroundColor: Colors.green,
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            onPressed: _exportToJson,
            tooltip: '导出为JSON',
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _members.length,
              itemBuilder: (context, index) {
                final member = _members[index];
                return ListTile(
                  // ############ 使用新的头像 Widget ############
                  leading: UserAvatar(member: member),
                  title: Text(member.displayName),
                  subtitle: Text(member.username, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                );
              },
            ),
    );
  }
}