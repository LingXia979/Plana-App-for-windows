import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 页面逻辑索引；入口顺序由导航栏映射，既有索引不随入口增减而移动。
const kTabCreate = 0;
const kTabGallery = 1;
const kTabAssistant = 2;
const kTabInspiration = 3;
const kTabProfile = 4;
const kTabTools = 5;

/// 当前底部 tab 索引。
/// 独立成 Provider,好让「生成完成跳图库」「缺 token 跳我的」等跨页切换。
final shellIndexProvider = NotifierProvider<ShellIndexNotifier, int>(
  ShellIndexNotifier.new,
);

class ShellIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int i) => state = i;
}
