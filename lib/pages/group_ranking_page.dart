import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/group_chat_service.dart';
import 'group_members_page.dart'; // 导入包含 UserAvatar 的文件

class GroupRankingPage extends StatefulWidget {
  final GroupChatInfo groupInfo;
  const GroupRankingPage({super.key, required this.groupInfo});

  @override
  State<GroupRankingPage> createState() => _GroupRankingPageState();
}

class _GroupRankingPageState extends State<GroupRankingPage> {
  late final GroupChatService _groupChatService;
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 15));
  DateTime _endDate = DateTime.now();
  List<GroupMessageRank>? _ranking;
  bool _isGenerating = false;
  bool _isGeneratingWordCloud = false; // 新增状态：词云生成中

  @override
  void initState() {
    super.initState();
    final appState = Provider.of<AppState>(context, listen: false);
    _groupChatService = GroupChatService(appState.databaseService);
  }
  
  Future<void> _selectDate(BuildContext context, bool isStart) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(1000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        if (isStart) _startDate = picked;
        else _endDate = picked;
      });
    }
  }

  Future<void> _generateRanking() async {
    setState(() { _isGenerating = true; _ranking = null; });
    try {
      final ranking = await _groupChatService.getGroupMessageRanking(
        chatroomId: widget.groupInfo.username,
        startDate: _startDate,
        endDate: _endDate,
      );
      setState(() { _ranking = ranking; _isGenerating = false; });
    } catch (e) {
      setState(() => _isGenerating = false);
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('生成排行失败: $e')));
    }
  }
  
  // 新增：生成并显示词频表格
  Future<void> _generateWordFrequencyTable(GroupMember member) async {
    setState(() => _isGeneratingWordCloud = true);

    try {
      final wordFrequencies = await _groupChatService.getMemberWordFrequency(
        chatroomId: widget.groupInfo.username,
        memberUsername: member.username,
        startDate: _startDate,
        endDate: _endDate,
      );

      setState(() => _isGeneratingWordCloud = false);

      if (mounted) {
        if (wordFrequencies.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有足够的数据生成词频统计')),
          );
        } else {
          _showWordFrequencyTableDialog(member.displayName, wordFrequencies);
        }
      }
    } catch (e) {
      setState(() => _isGeneratingWordCloud = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('生成词频统计失败: $e')));
    }
  }

  // 新增：显示词频表格对话框
  void _showWordFrequencyTableDialog(String memberName, Map<String, int> wordFrequencies) {
    // 将词频数据转换为列表并按频率排序
    final sortedWords = wordFrequencies.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    // 限制显示前50个词汇
    final topWords = sortedWords.take(50).toList();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('$memberName 的常用词汇'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Table(
                  columnWidths: const {
                    0: FlexColumnWidth(1), // 排名列
                    1: FlexColumnWidth(3), // 词汇列
                    2: FlexColumnWidth(1), // 频率列
                    3: FlexColumnWidth(2), // 频率条列
                  },
                  border: TableBorder.all(color: Colors.grey.shade300),
                  children: [
                    // 表头
                    TableRow(
                      decoration: BoxDecoration(color: Colors.grey.shade100),
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text('排名', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text('词汇', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text('频率', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text('可视化', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    // 表格内容
                    ...topWords.map((entry) {
                      // 计算频率条宽度比例（相对于最高频率）
                      final maxFrequency = topWords.first.value;
                      final widthPercentage = entry.value / maxFrequency;
                      
                      return TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text('${topWords.indexOf(entry) + 1}'),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(entry.key),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(entry.value.toString()),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Container(
                              height: 20,
                              decoration: BoxDecoration(
                                color: Colors.green.shade100,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: FractionallySizedBox(
                                widthFactor: widthPercentage,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.green,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
  
  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy-MM-dd');
    return Scaffold(
      appBar: AppBar(
        title: const Text('发言排行'),
        backgroundColor: Colors.green,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        ElevatedButton.icon(icon: const Icon(Icons.calendar_today), label: Text('开始: ${dateFormat.format(_startDate)}'), onPressed: () => _selectDate(context, true)),
                        ElevatedButton.icon(icon: const Icon(Icons.calendar_today), label: Text('结束: ${dateFormat.format(_endDate)}'), onPressed: () => _selectDate(context, false)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
                      onPressed: _isGenerating ? null : _generateRanking,
                      child: const Text('生成排行'),
                    )
                  ],
                ),
              ),
            ),
          ),
          if (_isGenerating) const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: CircularProgressIndicator())
            ),
          if (_isGeneratingWordCloud) const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: Text('正在生成词频统计...'))
            ),
          if (_ranking != null)
            Expanded(
              child: _ranking!.isEmpty
              ? const Center(child: Text('该时间段内无发言记录'))
              : ListView.builder(
                  itemCount: _ranking!.length,
                  itemBuilder: (context, index) {
                    final item = _ranking![index];
                    // 使用 InkWell + Padding + Row 手动构建列表项，以解决布局问题
                    return InkWell(
                      onTap: () {
                        // 点击生成词频表格
                        _generateWordFrequencyTable(item.member);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Row(
                          children: [
                            // 排名
                            SizedBox(
                              width: 24, // 给排名一个固定的宽度
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(fontSize: 16, color: Colors.grey),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 16),
                            // 头像
                            UserAvatar(member: item.member),
                            const SizedBox(width: 16),
                            // 昵称 (自动扩展占满剩余空间)
                            Expanded(
                              child: Text(
                                item.member.displayName,
                                style: Theme.of(context).textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 16),
                            // 消息数
                            Text(
                              '${item.messageCount} 条',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                            ),
                            const SizedBox(width: 8),
                            // 词频图标
                            const Icon(Icons.table_chart, color: Colors.grey),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            )
        ],
      ),
    );
  }
}