import 'dart:async';
import 'dart:isolate';

import 'catalog_browser.dart';
import 'catalog_sort.dart';
import 'models.dart';

class CatalogViewCache {
  List<Drama>? _rows;
  Object? _key;
  List<Drama> _visible = [];
  final Map<Drama, String> _searchText = {};
  int _generation = 0;
  bool _running = false;
  bool computing = false;
  bool _backgroundFailed = false;
  ({
    List<Drama> rows,
    String query,
    String category,
    bool onlineSearch,
    bool hideVip,
    Set<String> allowedSources,
    int profileEpoch,
    CatalogView view,
    int generation,
    void Function()? onReady,
  })?
  _pending;

  List<Drama> select(
    List<Drama> rows, {
    required String query,
    required String category,
    required bool onlineSearch,
    required bool hideVip,
    required Set<String> allowedSources,
    required int profileEpoch,
    required CatalogView view,
    void Function()? onReady,
  }) {
    final permissionKey = allowedSources.toList()..sort();
    final key = (
      query,
      category,
      onlineSearch,
      hideVip,
      permissionKey.join('\u0000'),
      profileEpoch,
      view.sort,
      view.release,
    );
    if (identical(rows, _rows) && key == _key) return _visible;
    final terms = query
        .trim()
        .split(RegExp(r'\s+'))
        .map(normalizedSearchText)
        .where((word) => word.isNotEmpty)
        .toList();
    final trivialView =
        terms.isEmpty &&
        !category.startsWith('local:') &&
        view.release.isEmpty &&
        view.sort == CatalogSort.source;
    if (rows.length >= 2000 &&
        onReady != null &&
        !_backgroundFailed &&
        !trivialView) {
      final generation = ++_generation;
      final sameView = key == _key;
      computing = true;
      _rows = rows;
      _key = key;
      if (!sameView) _visible = [];
      _searchText.clear();
      _pending = (
        rows: rows,
        query: query,
        category: category,
        onlineSearch: onlineSearch,
        hideVip: hideVip,
        allowedSources: allowedSources,
        profileEpoch: profileEpoch,
        view: view,
        generation: generation,
        onReady: onReady,
      );
      unawaited(_runPending());
      return _visible;
    }
    _generation++;
    _pending = null;
    computing = false;
    if (!identical(rows, _rows)) {
      _searchText.clear();
      _rows = rows;
    }
    final visible = sortCatalog(
      rows.where((drama) {
        if (!allowedSources.contains(drama.source)) return false;
        if (category.startsWith('local:') &&
            categoryName(drama.category) != category.substring(6)) {
          return false;
        }
        if (hideVip && drama.source == 'huangdou' && drama.vip) return false;
        if (onlineSearch || terms.isEmpty) return true;
        final text = _searchText.putIfAbsent(
          drama,
          () => normalizedSearchText(
            '${drama.title} ${drama.description} ${drama.tags.join(' ')}',
          ),
        );
        return terms.every(text.contains);
      }),
      view,
    );
    _key = key;
    _visible = visible;
    return visible;
  }

  Future<void> _runPending() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending != null) {
        final task = _pending!;
        _pending = null;
        try {
          final result = await _selectCatalogInBackground(
            task.rows,
            task.query,
            task.category,
            task.onlineSearch,
            task.hideVip,
            task.allowedSources,
            task.profileEpoch,
            task.view,
          );
          if (task.generation != _generation) continue;
          _visible = result;
          computing = false;
          task.onReady?.call();
        } catch (_) {
          if (task.generation == _generation) {
            computing = false;
            _backgroundFailed = true;
            _key = null;
            task.onReady?.call();
          }
        }
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _generation++;
    computing = false;
    _pending = null;
    _rows = null;
    _visible = [];
    _searchText.clear();
  }
}

Future<List<Drama>> _selectCatalogInBackground(
  List<Drama> rows,
  String query,
  String category,
  bool onlineSearch,
  bool hideVip,
  Set<String> allowedSources,
  int profileEpoch,
  CatalogView view,
) => Isolate.run(
  () => CatalogViewCache().select(
    rows,
    query: query,
    category: category,
    onlineSearch: onlineSearch,
    hideVip: hideVip,
    allowedSources: allowedSources,
    profileEpoch: profileEpoch,
    view: view,
  ),
);
