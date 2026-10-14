import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'app_notice.dart';
import 'core_bridge.dart';
import 'glass_panel.dart';
import 'live_models.dart';
import 'live_playback.dart';
import 'live_player_screen.dart';
import 'live_repository.dart';
import 'live_sources.dart';
import 'live_store.dart';
import 'player_route.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

/// 底部「直播」：主页同款卡片浏览，点击卡片进入全屏直播播放页。
/// 平台选择与收藏入口由宿主 AppBar 经 [LiveScreenState] 驱动。
class LiveScreen extends StatefulWidget {
  const LiveScreen({
    super.key,
    required this.repository,
    required this.store,
    this.greenMode = true,
    this.onExitLeft,
    this.onChanged,
  });

  final LiveRepository repository;
  final LiveStore store;
  final bool greenMode;
  final VoidCallback? onExitLeft;

  /// 当前平台 / 收藏状态变化时通知宿主刷新 AppBar。
  final VoidCallback? onChanged;

  @override
  State<LiveScreen> createState() => LiveScreenState();
}

class LiveScreenState extends State<LiveScreen> {
  static const _favouritesId = '__favourites';

  LiveSource? _source;
  List<LivePlatform> _platforms = const [];
  List<LiveChannel> _channels = const [];
  ({String group, List<LiveChannel> channels})? _lastGood;
  String _group = '';
  bool _loading = true;
  bool _more = false;
  bool _hasMore = false;
  String? _error;
  int _page = 1;
  String _groupBeforeFavourites = '';
  int _generation = 0;
  late final LivePlaybackController _playback;
  final _channelScroll = ScrollController();
  final _gridKey = GlobalKey<RemoteGridState>();

  @override
  void initState() {
    super.initState();
    _playback = LivePlaybackController(repository: widget.repository);
    widget.store.addListener(_storeChanged);
    _syncSources();
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    _playback.dispose();
    _channelScroll.dispose();
    super.dispose();
  }

  void _storeChanged() {
    if (!mounted) return;
    setState(() {
      if (_group == _favouritesId) _channels = widget.store.favourites;
    });
    widget.onChanged?.call();
    final visible = LiveSource.visible(widget.greenMode);
    if (visible.isEmpty || !visible.any((item) => item.id == _source?.id)) {
      setState(() {
        _source = visible.isEmpty ? null : visible.first;
        _platforms = const [];
        _channels = const [];
        _group = '';
        _lastGood = null;
        _error = null;
      });
      widget.onChanged?.call();
      if (_source != null) unawaited(_loadPlatforms());
    }
  }

  /// 绿色模式可能把直播源全部挡掉，此时保持空态，不能在 `.first` 上抛异常。
  @override
  void didUpdateWidget(covariant LiveScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.greenMode == widget.greenMode || _source != null) return;
    _syncSources();
  }

  void _syncSources() {
    final visible = LiveSource.visible(widget.greenMode);
    if (visible.isEmpty) {
      setState(() {
        _source = null;
        _loading = false;
        _platforms = const [];
        _channels = const [];
      });
      return;
    }
    _source = visible.first;
    unawaited(_loadPlatforms());
  }

  /// AppBar 左上角下拉按钮显示的标题：收藏视图或当前平台名。
  String get liveTitle {
    if (_group == _favouritesId) return '收藏';
    final platform = _platforms
        .where((entry) => entry.id == _group)
        .firstOrNull;
    return platform?.name ?? (_source?.name ?? '直播');
  }

  bool get viewingFavourites => _group == _favouritesId;

  List<LivePlatform> _visiblePlatforms(List<LivePlatform> platforms) => [
    for (final platform in platforms)
      if (!LiveSource.hidesCategory(platform.name, greenMode: widget.greenMode))
        platform,
  ];

  /// 宿主 AppBar 左上角按钮点击：下拉选择平台（分类）。收藏只从右上角星星进入。
  Future<void> openLiveMenu(Rect anchor) async {
    if (!mounted || _source == null) return;
    final selected = await showGlassMenu<String>(
      context: context,
      anchor: anchor,
      autofocusSelected: AppLayout.isTelevision(context),
      entries: [
        for (final platform in _platforms)
          GlassMenuEntry(
            value: platform.id,
            label: Text(platform.name),
            selected: platform.id == _group,
            trailing: platform.id == _group
                ? Icon(
                    Icons.check_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
          ),
      ],
    );
    if (selected == null || !mounted) return;
    unawaited(_loadChannels(selected));
  }

  /// 宿主 AppBar 收藏按钮点击：收藏视图与原平台之间切换。
  /// 返回时恢复进入收藏前的平台，而不是跳回第一个平台。
  void toggleLiveFavourites() {
    if (_group == _favouritesId) {
      final restore = _platforms
          .where((entry) => entry.id == _groupBeforeFavourites)
          .firstOrNull;
      final platform = restore ?? _platforms.firstOrNull;
      if (platform != null) unawaited(_loadChannels(platform.id));
      return;
    }
    if (_group.isNotEmpty) _groupBeforeFavourites = _group;
    unawaited(_loadChannels(_favouritesId));
  }

  Future<void> _loadPlatforms() async {
    final source = _source;
    if (source == null) return;
    final token = ++_generation;
    widget.repository.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _platforms = const [];
      _channels = const [];
      _group = '';
      _lastGood = null;
      _page = 1;
    });
    try {
      final platforms = _visiblePlatforms(
        await widget.repository.platforms(source),
      );
      if (!mounted || token != _generation) return;
      if (platforms.isEmpty) throw AppFailure('该直播源没有可用分类');
      setState(() {
        _platforms = platforms;
        _loading = false;
      });
      widget.onChanged?.call();
      await _loadChannels(platforms.first.id);
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
      widget.onChanged?.call();
    }
  }

  Future<void> _loadChannels(
    String id, {
    bool append = false,
    bool refresh = false,
  }) async {
    final source = _source;
    if (source == null) return;
    if (id == _favouritesId) {
      _generation++;
      widget.repository.cancel();
      final channels = widget.store.favourites;
      _lastGood = (group: id, channels: channels);
      setState(() {
        _group = id;
        _channels = channels;
        _error = null;
        _loading = false;
        _more = false;
        _hasMore = false;
      });
      widget.onChanged?.call();
      return;
    }
    final platform = _platforms.where((entry) => entry.id == id).firstOrNull;
    if (platform == null) return;
    if (append && !_hasMore) return;
    if (!append && !refresh && id == _group) return;
    if (!append) _lastGood = (group: _group, channels: _channels);
    final page = append ? _page + 1 : 1;
    setState(() {
      _group = id;
      _error = null;
      _more = append;
      if (!append) {
        _hasMore = false;
        // 下拉刷新保留当前列表，进度由刷新指示器展示。
        if (!refresh) {
          _loading = true;
          _channels = const [];
        }
      }
    });
    widget.onChanged?.call();
    final token = _generation;
    try {
      final channels = await widget.repository.channels(
        source,
        platform,
        page: page,
        force: refresh,
      );
      if (!mounted || token != _generation) return;
      if (!append) _lastGood = (group: id, channels: channels);
      setState(() {
        _page = page;
        _loading = false;
        _more = false;
        _hasMore = source.paginated && channels.length >= 24;
        _channels = append ? [..._channels, ...channels] : channels;
      });
      widget.onChanged?.call();
    } catch (error) {
      if (!mounted || token != _generation) return;
      final restore = _lastGood;
      final fallback =
          !append && restore != null && restore.channels.isNotEmpty;
      setState(() {
        _loading = false;
        _more = false;
        if (fallback) {
          _group = restore.group;
          _channels = restore.channels;
          _error = null;
        } else {
          _error = '$error';
        }
      });
      widget.onChanged?.call();
      if (fallback && mounted) {
        AppNotice.show(
          context,
          refresh
              ? '${platform.name} 刷新失败，已保留当前列表'
              : '${platform.name} 暂时不可用，已保留原分类',
        );
      }
    }
  }

  /// 下拉刷新：重新请求当前分类的频道与海报数据。
  Future<void> _refreshChannels() {
    final group = _group;
    if (group.isEmpty || group == _favouritesId) {
      return Future<void>.value();
    }
    return _loadChannels(group, refresh: true);
  }

  /// 点击主播卡片：加载播放计划并立即进入全屏播放页，返回列表时暂停。
  Future<void> _open(LiveChannel channel) async {
    final source = _source;
    if (source == null) return;
    final index = _channels.indexWhere((entry) => entry.key == channel.key);
    if (index < 0) return;
    unawaited(_playback.load(source, _channels, index: index));
    await Navigator.of(context).push(
      playerRoute(
        LivePlayerScreen(
          playback: _playback,
          source: source,
          store: widget.store,
        ),
      ),
    );
    if (mounted) unawaited(_playback.suspend());
  }

  @override
  Widget build(BuildContext context) {
    if (_source == null) {
      return StatusPanel(
        key: const ValueKey('live-green-empty'),
        title: '暂无可用直播源',
        message: '当前没有可用的直播源。',
        icon: Icons.verified_user_outlined,
      );
    }
    final error = _error;
    if (_platforms.isEmpty && error != null && !_loading) {
      return StatusPanel(
        title: '${_source!.name} 直播源暂时不可用',
        message: error,
        icon: Icons.wifi_off_rounded,
        onRetry: _loadPlatforms,
      );
    }
    if (_channels.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return StatusPanel(
        key: const ValueKey('live-empty'),
        title: _group == _favouritesId ? '还没有收藏频道' : '没有可用频道',
        message: _group == _favouritesId ? '播放时点星标即可加入收藏。' : '可以在左上角选择其他平台。',
        icon: Icons.live_tv_rounded,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final television = AppLayout.isTelevision(context);
        if (television) {
          final columns = ((constraints.maxWidth - 36) / 150).floor().clamp(
            1,
            8,
          );
          final tileWidth =
              (constraints.maxWidth - 36 - (columns - 1) * 14) / columns;
          return RemoteGrid(
            key: _gridKey,
            itemKeys: [for (final channel in _channels) channel.key],
            columns: columns,
            itemExtent: _tileExtent(context, tileWidth - 14) + 14,
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
            onExitLeft: widget.onExitLeft,
            itemBuilder: (_, index, node, onFocus) =>
                _tile(_channels[index], focusNode: node, onFocus: onFocus),
          );
        }
        final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
        final columns = constraints.maxWidth < 600
            ? 3
            : ((constraints.maxWidth - 2 * padding) / 180).floor().clamp(4, 9);
        final spacing = constraints.maxWidth < 600 ? 10.0 : 18.0;
        final tileWidth =
            (constraints.maxWidth - 2 * padding - (columns - 1) * spacing) /
            columns;
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.extentAfter < 600 &&
                !_more &&
                _hasMore &&
                _group != _favouritesId) {
              unawaited(_loadChannels(_group, append: true));
            }
            return false;
          },
          child: RefreshIndicator(
            onRefresh: _refreshChannels,
            // 此 Flutter 版本没有 enabled 参数；收藏视图是本地数据，
            // 用通知谓词关闭下拉触发，其余视图保持默认 depth==0 判定。
            notificationPredicate: (notification) =>
                _group != _favouritesId && notification.depth == 0,
            child: GridView.builder(
              key: const ValueKey('live-channel-list'),
              controller: _channelScroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(padding, 4, padding, 16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 22,
                crossAxisSpacing: spacing,
                mainAxisExtent: _tileExtent(context, tileWidth),
              ),
              itemCount: _channels.length + (_more ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _channels.length) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _tile(_channels[index]);
              },
            ),
          ),
        );
      },
    );
  }

  /// 与主页剧集卡片同款规格：2:3 圆角封面 + 单行标题（编号并入名称）。
  double _tileExtent(BuildContext context, double width) =>
      (width * 1.5 + 9 + _labelHeight(context)).ceilToDouble();

  static double _labelHeight(BuildContext context) =>
      MediaQuery.textScalerOf(
        context,
      ).scale(AppLayout.isTelevision(context) ? 17 : 14) *
      1.3;

  /// 卡片右上角菜单：暂时只有收藏 / 取消收藏。
  Future<void> _channelActions(
    BuildContext anchorContext,
    LiveChannel channel,
  ) async {
    if (!mounted) return;
    final anchor = glassMenuAnchor(anchorContext);
    if (anchor == null) return;
    final favourite = widget.store.isFavourite(channel.key);
    final choice = await showGlassMenu<String>(
      context: context,
      anchor: anchor,
      alignRight: true,
      autofocusSelected: AppLayout.isTelevision(context),
      entries: [
        GlassMenuEntry(
          value: 'favourite',
          label: Text(favourite ? '取消收藏' : '收藏'),
          leading: Icon(
            favourite ? Icons.star_rounded : Icons.star_border_rounded,
          ),
        ),
      ],
    );
    if (choice != 'favourite' || !mounted) return;
    await widget.store.toggleFavourite(channel);
  }

  Widget _tile(
    LiveChannel channel, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final theme = Theme.of(context);
    final television = AppLayout.isTelevision(context);
    final favourite = widget.store.isFavourite(channel.key);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: _channelCover(theme, channel),
              ),
              if (channel.group.isNotEmpty)
                Positioned(
                  left: 6,
                  right: 52,
                  top: 6,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .7),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        child: Text(
                          channel.group,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (favourite)
                Positioned(
                  top: 6,
                  right: 52,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.star_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 2,
                right: 2,
                child: Builder(
                  builder: (buttonContext) => IconButton(
                    key: ValueKey('live-actions-${channel.key}'),
                    tooltip: '${channel.label} · 更多操作',
                    onPressed: () =>
                        unawaited(_channelActions(buttonContext, channel)),
                    icon: const Icon(
                      Icons.more_horiz_rounded,
                      size: 20,
                      shadows: [
                        Shadow(
                          color: Color(0xB3000000),
                          blurRadius: 3,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      foregroundColor: Colors.white,
                      hoverColor: const Color(0x1FFFFFFF),
                      focusColor: const Color(0x33FFFFFF),
                      highlightColor: const Color(0x29FFFFFF),
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.all(12),
                      visualDensity: VisualDensity.standard,
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 9),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: SizedBox(
            height: _labelHeight(context),
            child: Text(
              channel.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                height: 1.3,
                fontSize: television ? 17 : 14,
              ),
            ),
          ),
        ),
      ],
    );
    if (television) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.contextMenu): () =>
              unawaited(
                _channelActions(focusNode?.context ?? context, channel),
              ),
        },
        child: RemoteTarget(
          focusNode: focusNode,
          onFocus: onFocus,
          onPressed: () => unawaited(_open(channel)),
          selected: false,
          label: channel.label,
          child: content,
        ),
      );
    }
    return Semantics(
      button: true,
      label: channel.label,
      child: PressScale(
        scale: .97,
        child: Builder(
          builder: (tileContext) => InkWell(
            key: ValueKey('live-channel-${channel.key}'),
            onTap: () => unawaited(_open(channel)),
            onSecondaryTap: () =>
                unawaited(_channelActions(tileContext, channel)),
            borderRadius: BorderRadius.circular(14),
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _channelCover(ThemeData theme, LiveChannel channel) {
    final logo = channel.logo;
    if (logo.isEmpty) return _channelAvatarFallback(theme, channel);
    return Image.network(
      logo,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _channelAvatarFallback(theme, channel),
    );
  }

  Widget _channelAvatarFallback(ThemeData theme, LiveChannel channel) =>
      Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surfaceContainerHighest,
              theme.colorScheme.surfaceContainer,
            ],
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          channel.name.isEmpty
              ? 'TV'
              : String.fromCharCode(channel.name.runes.first),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
