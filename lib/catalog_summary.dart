import 'models.dart';

class CatalogSummary {
  CatalogSummary.fromJson(Map<String, dynamic> data)
    : revision = data['revision'] as String? ?? '',
      count = intValue(data['count']),
      page = intValue(data['page']).clamp(1, 1000000),
      hasMore = data['hasMore'] == true,
      fresh = data['fresh'] == true,
      warning = data['warning'] as String? ?? '',
      categories = (data['localCategories'] as List? ?? const [])
          .whereType<String>()
          .toList();

  final String revision, warning;
  final int count, page;
  final bool hasMore, fresh;
  final List<String> categories;
}
