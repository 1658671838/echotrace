import 'package:flutter/material.dart';
import '../services/group_chat_service.dart';
import 'group_members_page.dart';
import 'group_ranking_page.dart';
import 'group_member_chart_page.dart';

class GroupChatDetailPage extends StatelessWidget {
  final GroupChatInfo groupInfo;

  const GroupChatDetailPage({super.key, required this.groupInfo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(groupInfo.displayName, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.green,
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('群成员查看'),
            subtitle: const Text('查看所有群成员并导出'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => GroupMembersPage(groupInfo: groupInfo)),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bar_chart),
            title: const Text('群聊发言排行'),
            subtitle: const Text('统计时间段内成员发言次数'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
               Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => GroupRankingPage(groupInfo: groupInfo)),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.person_search),
            title: const Text('单人发言分析'),
            subtitle: const Text('查看指定成员每日发言柱状图'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => GroupMemberChartPage(groupInfo: groupInfo)),
              );
            },
          ),
        ],
      ),
    );
  }
}