// 筛选行标签顺序:池里的按池的顺序,只挂在条目上的按字母序排在后面。
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';

TagEntry _e(String id, TagCategory c, List<String> tags) =>
    TagEntry(id: id, category: c, name: id, tags: tags);

void main() {
  test('池顺序在前,池外标签字母序在后,不重复', () {
    final lib = TagLibraryState(
      pools: const {
        TagCategory.artist: ['厚涂', '水彩', '厚涂'],
      },
      entries: [
        _e('a', TagCategory.artist, ['线稿', '水彩']),
        _e('b', TagCategory.artist, ['b-side', '厚涂']),
        _e('c', TagCategory.scene, ['室内']),
      ],
    );
    expect(lib.knownTags(TagCategory.artist), ['厚涂', '水彩', 'b-side', '线稿']);
    expect(lib.knownTags(TagCategory.scene), ['室内']);
    expect(lib.knownTags(TagCategory.other), isEmpty);
  });
}
