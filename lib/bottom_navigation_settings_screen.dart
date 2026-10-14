import 'package:flutter/material.dart';

import 'app_notice.dart';
import 'local_store.dart';

class BottomNavigationSettingsScreen extends StatefulWidget {
  const BottomNavigationSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<BottomNavigationSettingsScreen> createState() =>
      _BottomNavigationSettingsScreenState();
}

class _BottomNavigationSettingsScreenState
    extends State<BottomNavigationSettingsScreen> {
  static const _options = {
    'feed': ('在看', Icons.play_circle_outline_rounded),
    'follow': ('追剧', Icons.bookmark_border_rounded),
    'live': ('直播', Icons.live_tv_outlined),
    'downloads': ('下载', Icons.download_outlined),
    'settings': ('设置', Icons.settings_outlined),
  };
  late final int _epoch;
  late List<String> _order;
  late Set<String> _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _epoch = widget.store.profileEpoch;
    final current = widget.store.bottomNavigation;
    _enabled = current.toSet();
    _order = [
      ...current,
      ..._options.keys.where((id) => !current.contains(id)),
    ];
  }

  void _move(int from, int to) {
    if (_saving || from == to || to < 0 || to >= _order.length) return;
    setState(() {
      final id = _order.removeAt(from);
      _order.insert(to, id);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_epoch != widget.store.profileEpoch || widget.store.locked) {
      AppNotice.show(context, '当前用户已变更，请重新打开底栏功能设置');
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.store.setBottomNavigation([
        for (final id in _order)
          if (_enabled.contains(id)) id,
      ]);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) AppNotice.show(context, '底栏设置保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('底栏功能设置'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中' : '保存'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '主页固定保留。关闭仅隐藏导航入口，观看记录、追剧和下载任务会保留。设置关闭后，仍可从主页右上角“更多”进入。桌面和电视侧栏使用相同配置。',
                ),
                const SizedBox(height: 16),
                const ListTile(
                  leading: Icon(Icons.home_rounded),
                  title: Text('主页'),
                  subtitle: Text('固定在第一项'),
                  trailing: Icon(Icons.lock_outline),
                ),
                for (final (index, id) in _order.indexed)
                  Card(
                    key: ValueKey('navigation-setting-$id'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          SwitchListTile(
                            title: Text(_options[id]!.$1),
                            secondary: Icon(_options[id]!.$2),
                            subtitle:
                                id == 'downloads' && !widget.store.canDownload
                                ? const Text('当前用户无下载权限，导航入口不会显示')
                                : null,
                            value: _enabled.contains(id),
                            onChanged: _saving
                                ? null
                                : (value) => setState(() {
                                    if (value) {
                                      _enabled.add(id);
                                    } else {
                                      _enabled.remove(id);
                                    }
                                  }),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton.icon(
                                onPressed: _saving || index == 0
                                    ? null
                                    : () => _move(index, index - 1),
                                icon: const Icon(Icons.arrow_upward_rounded),
                                label: const Text('上移'),
                              ),
                              TextButton.icon(
                                onPressed: _saving || index == _order.length - 1
                                    ? null
                                    : () => _move(index, index + 1),
                                icon: const Icon(Icons.arrow_downward_rounded),
                                label: const Text('下移'),
                              ),
                              const SizedBox(width: 12),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _order = _options.keys.toList();
                          _enabled = _options.keys.toSet();
                        }),
                  child: const Text('恢复默认（保存后生效）'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
