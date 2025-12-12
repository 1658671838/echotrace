import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// 消息加载骨架屏
class MessageLoadingShimmer extends StatelessWidget {
  const MessageLoadingShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // 允许在嵌套滚动场景（如加载更多占位）下测量自身高度，避免无限约束导致的异常
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: 8,
      itemBuilder: (context, index) {
        // 交替显示左右消息
        final isLeft = index % 2 == 0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            mainAxisAlignment: isLeft
                ? MainAxisAlignment.start
                : MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isLeft) ...[
                // 左侧头像
                Shimmer.fromColors(
                  baseColor: Colors.grey[300]!,
                  highlightColor: Colors.grey[100]!,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // 消息气泡
              Shimmer.fromColors(
                baseColor: Colors.grey[300]!,
                highlightColor: Colors.grey[100]!,
                child: Container(
                  width: 200 + (index % 3) * 50,
                  height: 40 + (index % 4) * 15,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              if (!isLeft) ...[
                const SizedBox(width: 8),
                // 右侧头像
                Shimmer.fromColors(
                  baseColor: Colors.grey[300]!,
                  highlightColor: Colors.grey[100]!,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
